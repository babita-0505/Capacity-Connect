import asyncio
import logging
import hashlib
import hmac
import json
import os
import re
import uuid
from datetime import datetime, timedelta, timezone
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
                            today_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
                            score_val = float(row["score"] or 100.0)
                            payload = {"name": row["full_name"], "course": row["title"], "score": score_val, "date": today_str}
                            canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
                            signature = hmac.new(settings.CERT_HMAC_SECRET.encode(), canonical.encode(), hashlib.sha256).hexdigest()

                            # Generate verifiable PDF with QR code
                            pdf_file_id = None
                            try:
                                import qrcode
                                from reportlab.lib.pagesizes import letter, landscape
                                from reportlab.pdfgen import canvas

                                cert_dir = os.path.join(settings.UPLOAD_DIR, "certificates")
                                os.makedirs(cert_dir, exist_ok=True)
                                pdf_filename = f"{certificate_no}.pdf"
                                pdf_path = os.path.join(cert_dir, pdf_filename)

                                qr = qrcode.QRCode(box_size=4, border=1)
                                qr.add_data(f"https://capacityconnect.moes.gov.in/verify/{certificate_no}")
                                qr.make(fit=True)
                                qr_img = qr.make_image(fill_color="black", back_color="white")
                                qr_path = os.path.join(cert_dir, f"{certificate_no}_qr.png")
                                qr_img.save(qr_path)

                                c_pdf = canvas.Canvas(pdf_path, pagesize=landscape(letter))
                                width, height = landscape(letter)

                                # Outer and Inner Gold Borders
                                c_pdf.setStrokeColorRGB(0.06, 0.09, 0.16) # Navy 900
                                c_pdf.setLineWidth(4)
                                c_pdf.rect(20, 20, width - 40, height - 40)
                                c_pdf.setStrokeColorRGB(0.15, 0.39, 0.92) # Primary Blue
                                c_pdf.setLineWidth(1.5)
                                c_pdf.rect(26, 26, width - 52, height - 52)

                                # Header
                                c_pdf.setFont("Helvetica-Bold", 24)
                                c_pdf.setFillColorRGB(0.06, 0.09, 0.16)
                                c_pdf.drawCentredString(width / 2, height - 80, "INDIA METEOROLOGICAL DEPARTMENT")
                                c_pdf.setFont("Helvetica", 12)
                                c_pdf.setFillColorRGB(0.3, 0.4, 0.5)
                                c_pdf.drawCentredString(width / 2, height - 105, "Ministry of Earth Sciences · Government of India")

                                c_pdf.setFont("Helvetica-Bold", 16)
                                c_pdf.setFillColorRGB(0.15, 0.39, 0.92)
                                c_pdf.drawCentredString(width / 2, height - 150, "CERTIFICATE OF TECHNICAL PROFICIENCY")

                                c_pdf.setFont("Helvetica", 12)
                                c_pdf.setFillColorRGB(0.2, 0.2, 0.2)
                                c_pdf.drawCentredString(width / 2, height - 190, "This is to certify that")

                                # Recipient Name
                                c_pdf.setFont("Helvetica-Bold", 22)
                                c_pdf.setFillColorRGB(0.06, 0.09, 0.16)
                                c_pdf.drawCentredString(width / 2, height - 225, row["full_name"])

                                # Description
                                c_pdf.setFont("Helvetica", 12)
                                c_pdf.setFillColorRGB(0.2, 0.2, 0.2)
                                c_pdf.drawCentredString(width / 2, height - 260, f"has successfully completed all modules and rigorous competency evaluations for")
                                c_pdf.setFont("Helvetica-Bold", 15)
                                c_pdf.drawCentredString(width / 2, height - 285, f"\"{row['title']}\"")
                                c_pdf.setFont("Helvetica", 11)
                                c_pdf.drawCentredString(width / 2, height - 310, f"Achieved Evaluation Score: {score_val:.1f}% · Issued on {today_str}")

                                # QR Code and Verification Metadata
                                c_pdf.drawImage(qr_path, 50, 45, width=80, height=80)
                                c_pdf.setFont("Helvetica", 8)
                                c_pdf.setFillColorRGB(0.4, 0.4, 0.4)
                                c_pdf.drawString(140, 95, f"Certificate No: {certificate_no}")
                                c_pdf.drawString(140, 80, f"Cryptographic SHA-256: {hashlib.sha256(canonical.encode()).hexdigest()[:32]}...")
                                c_pdf.drawString(140, 65, "Scan QR to verify authenticity on the Capacity Connect portal")

                                # Signature line
                                c_pdf.setStrokeColorRGB(0.5, 0.5, 0.5)
                                c_pdf.line(width - 220, 75, width - 60, 75)
                                c_pdf.setFont("Helvetica-Bold", 10)
                                c_pdf.drawCentredString(width - 140, 60, "Director General of Meteorology")
                                c_pdf.setFont("Helvetica", 8)
                                c_pdf.drawCentredString(width - 140, 48, "India Meteorological Department")

                                c_pdf.showPage()
                                c_pdf.save()

                                if os.path.exists(qr_path):
                                    os.remove(qr_path)

                                # Register in files table
                                pdf_file_id = uuid.uuid4()
                                file_sha = hashlib.sha256(open(pdf_path, "rb").read()).hexdigest()
                                file_size = os.path.getsize(pdf_path)
                                await session.execute(text("""INSERT INTO files(id,original_name,storage_path,mime_type,size_bytes,sha256,uploaded_by)
                                    VALUES(:id,:orig,:path,'application/pdf',:size,:sha,:uid) ON CONFLICT DO NOTHING"""),
                                    {"id": pdf_file_id, "orig": pdf_filename, "path": pdf_path, "size": file_size, "sha": file_sha, "uid": row["user_id"]})
                            except Exception as pdf_err:
                                logger.error(f"Failed to generate certificate PDF: {pdf_err}")

                            await session.execute(text("""INSERT INTO certificates(certificate_no,user_id,course_id,enrollment_id,final_score_pct,payload,sha256,signature,file_id)
                                VALUES(:no,:user,:course,:enrollment,:score,:payload,:sha,:signature,:file_id) ON CONFLICT(enrollment_id) DO NOTHING"""),
                                {"no": certificate_no, "user": row["user_id"], "course": row["course_id"], "enrollment": row["id"], "score": score_val, "payload": json.dumps(payload), "sha": hashlib.sha256(canonical.encode()).hexdigest(), "signature": signature, "file_id": pdf_file_id})
                            await session.execute(text("INSERT INTO notifications(user_id,type,title,body,link) VALUES(:user,'certificate_issued','Certificate issued',:body,:link)"), {"user": row["user_id"], "body": f"Your certificate for {row['title']} is ready.", "link": f"/verify/{certificate_no}"})
                            await session.execute(text("UPDATE jobs SET status='done', result=:result, finished_at=now() WHERE id=:id"), {"id": job["id"], "result": json.dumps({"certificate_no": certificate_no})})
                        elif job_type == "mcq_generate":
                            await generate_rule_based_questions(session, job)
                        elif job_type == "deadline_reminders":
                            now_utc = datetime.now(timezone.utc)
                            # Deadlines in next 24 hours
                            d24 = await session.execute(text("""
                                SELECT a.id, a.title, e.user_id
                                FROM assessments a
                                JOIN enrollments e ON e.course_id = a.course_id
                                LEFT JOIN attempts att ON att.assessment_id = a.id AND att.user_id = e.user_id AND att.status != 'in_progress'
                                WHERE a.status = 'open'
                                  AND a.deadline_at IS NOT NULL
                                  AND a.deadline_at BETWEEN :now AND :in24
                                  AND att.id IS NULL
                            """), {"now": now_utc, "in24": now_utc + timedelta(hours=24)})
                            for r in d24.mappings().all():
                                await session.execute(text("""
                                    INSERT INTO notifications(user_id, type, title, body, link, dedupe_key)
                                    VALUES(:user, 'deadline_24h', 'Test Deadline Approaching (24h)', :body, :link, :key)
                                    ON CONFLICT DO NOTHING
                                """), {"user": r["user_id"], "body": f"Assessment \"{r['title']}\" is due within 24 hours.", "link": f"/assessments/{r['id']}", "key": f"deadline_24h:{r['id']}:{r['user_id']}"})
                            await session.execute(text("UPDATE jobs SET status='done', finished_at=now() WHERE id=:id"), {"id": job["id"]})
                        else:
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

