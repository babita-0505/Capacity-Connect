import asyncio
import logging
import hashlib
import hmac
import json
import os
import re
import uuid
from sqlalchemy import text
from app.db import async_session
from app.config import settings

logger = logging.getLogger("worker")
worker_task = None
is_running = False

async def generate_rule_based_questions(session, job):
    """Safe fallback: turn taxonomy-keyword sentences into editable draft MCQs."""
    payload = job["payload"]
    resource = (await session.execute(text("""SELECT r.id,r.skill_id,r.trainer_id,f.storage_path
        FROM learning_resources r JOIN files f ON f.id=r.file_id WHERE r.id=:id"""), {"id": payload["resource_id"]})).mappings().first()
    if not resource:
        raise ValueError("Source resource no longer exists")
    try:
        from pypdf import PdfReader
        reader = PdfReader(os.path.join(settings.UPLOAD_DIR, resource["storage_path"]))
        pages = [(index + 1, page.extract_text() or "") for index, page in enumerate(reader.pages[:15])]
    except Exception as exc:
        raise ValueError(f"Unable to read source PDF: {exc}")
    skill = (await session.execute(text("SELECT keywords FROM skills WHERE id=:id"), {"id": resource["skill_id"]})).mappings().first()
    keywords = list(skill["keywords"] if skill else [])
    if not keywords:
        keywords = ["weather", "forecast", "observation", "climate"]
    created = []
    for page_no, content in pages:
        sentences = re.split(r"(?<=[.!?])\s+", re.sub(r"\s+", " ", content))
        for sentence in sentences:
            match = next((word for word in keywords if re.search(rf"\b{re.escape(word)}\b", sentence, re.I)), None)
            if not match or len(sentence) < 35:
                continue
            prompt = re.sub(rf"\b{re.escape(match)}\b", "_____", sentence, count=1, flags=re.I)
            distractors = [word for word in keywords if word.lower() != match.lower()][:3]
            while len(distractors) < 3:
                distractors.append(f"Concept {len(distractors) + 1}")
            qid = uuid.uuid4()
            await session.execute(text("""INSERT INTO questions(id,skill_id,type,text,explanation,difficulty,status,generation_method,source_resource_id,source_page,source_job_id,created_by)
                VALUES(:id,:skill,'mcq_single',:text,:explanation,:difficulty,'draft','rule_based',:resource,:page,:job,:user)"""), {"id": qid, "skill": resource["skill_id"], "text": f"Complete the statement: {prompt}", "explanation": sentence, "difficulty": payload.get("difficulty", 2), "resource": resource["id"], "page": page_no, "job": job["id"], "user": resource["trainer_id"]})
            choices = [match, *distractors]
            for pos, choice in enumerate(choices, 1):
                await session.execute(text("INSERT INTO question_options(id,question_id,text,is_correct,position) VALUES(:id,:question,:text,:correct,:position)"), {"id": uuid.uuid4(), "question": qid, "text": choice, "correct": pos == 1, "position": pos})
            created.append(str(qid))
            if len(created) >= payload["count"]:
                break
        if len(created) >= payload["count"]:
            break
    if not created:
        raise ValueError("No keyword-backed sentences found in this PDF")
    await session.execute(text("UPDATE jobs SET status='done',result=:result,finished_at=now() WHERE id=:id"), {"id": job["id"], "result": json.dumps({"question_ids": created, "method": "rule_based"})})
    await session.execute(text("INSERT INTO notifications(user_id,type,title,body,link) VALUES(:user,'mcq_ready','Draft questions are ready',:body,:link)"), {"user": resource["trainer_id"], "body": f"{len(created)} rule-based draft questions are ready for review.", "link": "/trainer/questions"})

async def worker_loop():
    global is_running
    is_running = True
    logger.info("Background worker loop started (polling claim_next_job every 2s)")
    while is_running:
        try:
            async with async_session() as session:
                # Call claim_next_job('api_worker_1')
                result = await session.execute(
                    text("SELECT * FROM claim_next_job('api_worker_1')")
                )
                job = result.mappings().first()
                if job:
                    logger.info(f"Claimed job {job['id']} of type {job['type']}")
                    # Process job based on type
                    job_type = job["type"]
                    try:
                        if job_type == "competency_refresh":
                            await session.execute(text("SELECT refresh_competency_scores()"))
                            await session.execute(
                                text("UPDATE jobs SET status = 'done', finished_at = now() WHERE id = :id"),
                                {"id": job["id"]}
                            )
                        elif job_type == "certificate_issue":
                            enrollment_id = job["payload"].get("enrollment_id")
                            row = (await session.execute(text("""SELECT e.id,e.user_id,e.course_id,u.full_name,c.title,
                                (SELECT max(a.percentage) FROM attempts a JOIN assessments s ON s.id=a.assessment_id WHERE a.user_id=e.user_id AND s.course_id=e.course_id AND a.passed) score
                                FROM enrollments e JOIN users u ON u.id=e.user_id JOIN courses c ON c.id=e.course_id WHERE e.id=:id"""), {"id": enrollment_id})).mappings().first()
                            if not row:
                                raise ValueError("Enrollment not found for certificate")
                            number = (await session.execute(text("SELECT count(*) FROM certificates"))).scalar() + 1
                            certificate_no = f"IMD-CC-2026-{number:06d}"
                            payload = {"name": row["full_name"], "course": row["title"], "score": float(row["score"] or 0), "date": "2026-09-26"}
                            canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
                            signature = hmac.new(settings.CERT_HMAC_SECRET.encode(), canonical.encode(), hashlib.sha256).hexdigest()
                            await session.execute(text("""INSERT INTO certificates(certificate_no,user_id,course_id,enrollment_id,final_score_pct,payload,sha256,signature)
                                VALUES(:no,:user,:course,:enrollment,:score,:payload,:sha,:signature) ON CONFLICT(enrollment_id) DO NOTHING"""), {"no": certificate_no, "user": row["user_id"], "course": row["course_id"], "enrollment": row["id"], "score": row["score"], "payload": json.dumps(payload), "sha": hashlib.sha256(canonical.encode()).hexdigest(), "signature": signature})
                            await session.execute(text("INSERT INTO notifications(user_id,type,title,body,link) VALUES(:user,'certificate_issued','Certificate issued',:body,:link)"), {"user": row["user_id"], "body": f"Your certificate for {row['title']} is ready.", "link": f"/verify/{certificate_no}"})
                            await session.execute(text("UPDATE jobs SET status='done', result=:result, finished_at=now() WHERE id=:id"), {"id": job["id"], "result": json.dumps({"certificate_no": certificate_no})})
                        elif job_type == "mcq_generate":
                            await generate_rule_based_questions(session, job)
                        else:
                            # Other jobs will be handled in later phases
                            await session.execute(
                                text("UPDATE jobs SET status = 'done', finished_at = now() WHERE id = :id"),
                                {"id": job["id"]}
                            )
                        await session.commit()
                    except Exception as e:
                        logger.error(f"Job {job['id']} failed: {e}")
                        await session.rollback()
                        await session.execute(
                            text("UPDATE jobs SET status = 'failed', error = :err, finished_at = now() WHERE id = :id"),
                            {"id": job["id"], "err": str(e)}
                        )
                        await session.commit()
        except Exception as e:
            # Database might not be ready or network blip
            logger.debug(f"Worker polling iteration: {e}")

        await asyncio.sleep(2)

def start_worker():
    global worker_task
    worker_task = asyncio.create_task(worker_loop())

def stop_worker():
    global is_running, worker_task
    is_running = False
    if worker_task:
        worker_task.cancel()
