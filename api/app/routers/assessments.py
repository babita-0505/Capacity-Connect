import json
import uuid
from datetime import datetime, timedelta, timezone
from typing import Optional, Literal
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import get_current_user, require_role

router = APIRouter(tags=["Assessments"])

class OptionIn(BaseModel):
    text: str
    is_correct: bool = False

class QuestionIn(BaseModel):
    skill_id: int
    text: str
    explanation: Optional[str] = None
    difficulty: int = Field(2, ge=1, le=5)
    options: list[OptionIn] = []

class AssessmentIn(BaseModel):
    title: str
    instructions: Optional[str] = None
    course_id: Optional[uuid.UUID] = None
    skill_id: Optional[int] = None
    opens_at: Optional[datetime] = None
    deadline_at: Optional[datetime] = None
    duration_minutes: Optional[int] = Field(None, gt=0)
    pass_pct: int = Field(60, ge=0, le=100)
    max_attempts: int = Field(1, gt=0)
    shuffle_questions: bool = True
    lockdown_enabled: bool = True

class AnswerIn(BaseModel):
    selected_option_ids: list[uuid.UUID] = []
    text_answer: Optional[str] = None
    rating_value: Optional[int] = None

class ProctorEventIn(BaseModel):
    event_type: Literal["blur", "fullscreen_exit", "copy"]

async def owned(db: AsyncSession, table: str, ident: uuid.UUID, user: dict):
    row = (await db.execute(text(f"SELECT created_by FROM {table} WHERE id=:id"), {"id": ident})).mappings().first()
    if not row:
        raise HTTPException(404, "Not found")
    if user["role"] != "admin" and row["created_by"] != user["id"]:
        raise HTTPException(403, "Forbidden: you do not own this resource")
    return row

# ---------------------------------------------------------------------------
# QUESTION BANK (Trainer / Admin)
# ---------------------------------------------------------------------------

@router.get("/questions")
async def list_questions(
    skill_id: Optional[int] = None,
    status_filter: Optional[str] = Query(None, alias="status"),
    q: Optional[str] = None,
    difficulty: Optional[int] = None,
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    where = ["1=1"]
    params = {"limit": page_size, "offset": (page - 1) * page_size}

    if current_user["role"] != "admin":
        where.append("q.created_by = :user_id")
        params["user_id"] = current_user["id"]

    if skill_id:
        where.append("q.skill_id = :skill_id")
        params["skill_id"] = skill_id
    if status_filter:
        where.append("q.status = :status")
        params["status"] = status_filter
    if difficulty:
        where.append("q.difficulty = :difficulty")
        params["difficulty"] = difficulty
    if q:
        where.append("(q.text ILIKE :q OR q.explanation ILIKE :q)")
        params["q"] = f"%{q}%"

    where_sql = " AND ".join(where)

    total = (await db.execute(text(f"SELECT count(*) FROM questions q WHERE {where_sql}"), params)).scalar() or 0

    rows = await db.execute(text(f"""
        SELECT q.id, q.skill_id, s.name AS skill_name, q.type, q.text, q.explanation,
               q.difficulty, q.status, q.generation_method, q.source_page,
               q.created_by, q.created_at,
               json_agg(json_build_object('id', o.id, 'text', o.text, 'is_correct', o.is_correct, 'position', o.position) ORDER BY o.position) AS options
        FROM questions q
        LEFT JOIN skills s ON s.id = q.skill_id
        LEFT JOIN question_options o ON o.question_id = q.id
        WHERE {where_sql}
        GROUP BY q.id, s.name
        ORDER BY q.created_at DESC
        LIMIT :limit OFFSET :offset
    """), params)

    return {
        "items": [dict(r) for r in rows.mappings().all()],
        "total": total,
        "page": page,
        "page_size": page_size
    }

@router.post("/questions", status_code=201)
async def create_question(
    data: QuestionIn,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    if len(data.options) != 4 or sum(o.is_correct for o in data.options) != 1:
        raise HTTPException(422, "MCQ questions require exactly four options and one correct answer")

    qid = uuid.uuid4()
    await db.execute(text("""
        INSERT INTO questions(id, skill_id, text, explanation, difficulty, status, created_by)
        VALUES(:id, :skill, :text, :explanation, :difficulty, 'draft', :user)
    """), {
        "id": qid,
        "skill": data.skill_id,
        "text": data.text,
        "explanation": data.explanation,
        "difficulty": data.difficulty,
        "user": current_user["id"]
    })

    for pos, opt in enumerate(data.options, 1):
        await db.execute(text("""
            INSERT INTO question_options(id, question_id, text, is_correct, position)
            VALUES(:id, :qid, :text, :correct, :pos)
        """), {
            "id": uuid.uuid4(),
            "qid": qid,
            "text": opt.text,
            "correct": opt.is_correct,
            "pos": pos
        })

    await db.commit()
    return {"id": qid, "status": "draft"}

@router.patch("/questions/{question_id}")
async def update_question(
    question_id: uuid.UUID,
    data: QuestionIn,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    await owned(db, "questions", question_id, current_user)
    if len(data.options) == 4:
        if sum(o.is_correct for o in data.options) != 1:
            raise HTTPException(422, "MCQ questions require exactly four options and one correct answer")
        await db.execute(text("DELETE FROM question_options WHERE question_id=:qid"), {"qid": question_id})
        for pos, opt in enumerate(data.options, 1):
            await db.execute(text("""
                INSERT INTO question_options(id, question_id, text, is_correct, position)
                VALUES(:id, :qid, :text, :correct, :pos)
            """), {
                "id": uuid.uuid4(),
                "qid": question_id,
                "text": opt.text,
                "correct": opt.is_correct,
                "pos": pos
            })

    await db.execute(text("""
        UPDATE questions
        SET skill_id=:skill, text=:text, explanation=:explanation, difficulty=:difficulty
        WHERE id=:id
    """), {
        "id": question_id,
        "skill": data.skill_id,
        "text": data.text,
        "explanation": data.explanation,
        "difficulty": data.difficulty
    })
    await db.commit()
    return {"id": question_id}

@router.post("/questions/{question_id}/approve")
async def approve_question(
    question_id: uuid.UUID,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    await owned(db, "questions", question_id, current_user)
    await db.execute(text("""
        UPDATE questions SET status='approved', reviewed_by=:user WHERE id=:id
    """), {"id": question_id, "user": current_user["id"]})
    await db.commit()
    return {"id": question_id, "status": "approved"}

@router.delete("/questions/{question_id}")
async def delete_question(
    question_id: uuid.UUID,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    await owned(db, "questions", question_id, current_user)
    # Check if used in assessments
    used = (await db.execute(text("SELECT 1 FROM assessment_questions WHERE question_id=:id"), {"id": question_id})).first()
    if used:
        # Mark as retired instead of deleting
        await db.execute(text("UPDATE questions SET status='retired' WHERE id=:id"), {"id": question_id})
    else:
        await db.execute(text("DELETE FROM questions WHERE id=:id"), {"id": question_id})
    await db.commit()
    return {"ok": True}

# ---------------------------------------------------------------------------
# ASSESSMENTS (Trainer / Admin)
# ---------------------------------------------------------------------------

@router.get("/assessments")
async def list_assessments(
    course_id: Optional[uuid.UUID] = None,
    skill_id: Optional[int] = None,
    status_filter: Optional[str] = Query(None, alias="status"),
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    where = ["1=1"]
    params = {"limit": page_size, "offset": (page - 1) * page_size}

    if current_user["role"] != "admin":
        where.append("a.created_by = :user_id")
        params["user_id"] = current_user["id"]

    if course_id:
        where.append("a.course_id = :course_id")
        params["course_id"] = course_id
    if skill_id:
        where.append("a.skill_id = :skill_id")
        params["skill_id"] = skill_id
    if status_filter:
        where.append("a.status = :status")
        params["status"] = status_filter

    where_sql = " AND ".join(where)

    total = (await db.execute(text(f"SELECT count(*) FROM assessments a WHERE {where_sql}"), params)).scalar() or 0

    rows = await db.execute(text(f"""
        SELECT a.id, a.title, a.instructions, a.type, a.course_id, a.skill_id,
               c.title AS course_title, s.name AS skill_name,
               a.status, a.opens_at, a.deadline_at, a.duration_minutes,
               a.pass_pct, a.max_attempts, a.shuffle_questions, a.show_results,
               a.lockdown_enabled, a.created_at,
               (SELECT count(*) FROM assessment_questions aq WHERE aq.assessment_id = a.id) AS question_count,
               (SELECT count(*) FROM attempts at WHERE at.assessment_id = a.id AND at.status != 'in_progress') AS completed_attempts
        FROM assessments a
        LEFT JOIN courses c ON c.id = a.course_id
        LEFT JOIN skills s ON s.id = a.skill_id
        WHERE {where_sql}
        ORDER BY a.created_at DESC
        LIMIT :limit OFFSET :offset
    """), params)

    return {
        "items": [dict(r) for r in rows.mappings().all()],
        "total": total,
        "page": page,
        "page_size": page_size
    }

@router.get("/assessments/{assessment_id}")
async def get_assessment_detail(
    assessment_id: uuid.UUID,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    row = (await db.execute(text("""
        SELECT a.*, c.title AS course_title, s.name AS skill_name,
               (SELECT count(*) FROM assessment_questions aq WHERE aq.assessment_id = a.id) AS question_count
        FROM assessments a
        LEFT JOIN courses c ON c.id = a.course_id
        LEFT JOIN skills s ON s.id = a.skill_id
        WHERE a.id = :id
    """), {"id": assessment_id})).mappings().first()

    if not row:
        raise HTTPException(404, "Assessment not found")

    detail = dict(row)

    # If trainer/admin, return questions included
    if current_user["role"] in ("trainer", "admin"):
        qs = await db.execute(text("""
            SELECT q.id, q.text, q.difficulty, q.status, aq.position, aq.marks,
                   json_agg(json_build_object('id', o.id, 'text', o.text, 'is_correct', o.is_correct, 'position', o.position) ORDER BY o.position) AS options
            FROM assessment_questions aq
            JOIN questions q ON q.id = aq.question_id
            LEFT JOIN question_options o ON o.question_id = q.id
            WHERE aq.assessment_id = :id
            GROUP BY q.id, aq.position, aq.marks
            ORDER BY aq.position
        """), {"id": assessment_id})
        detail["questions"] = [dict(x) for x in qs.mappings().all()]

    return detail

@router.post("/assessments", status_code=201)
async def create_assessment(
    data: AssessmentIn,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    aid = uuid.uuid4()
    await db.execute(text("""
        INSERT INTO assessments(id, title, instructions, course_id, skill_id, created_by,
                                opens_at, deadline_at, duration_minutes, pass_pct, max_attempts,
                                shuffle_questions, lockdown_enabled)
        VALUES(:id, :title, :instructions, :course, :skill, :user,
               :opens, :deadline, :duration, :pass, :max, :shuffle, :lockdown)
    """), {
        "id": aid,
        "title": data.title,
        "instructions": data.instructions,
        "course": data.course_id,
        "skill": data.skill_id,
        "user": current_user["id"],
        "opens": data.opens_at,
        "deadline": data.deadline_at,
        "duration": data.duration_minutes,
        "pass": data.pass_pct,
        "max": data.max_attempts,
        "shuffle": data.shuffle_questions,
        "lockdown": data.lockdown_enabled
    })
    await db.commit()
    return {"id": aid, "status": "draft"}

@router.patch("/assessments/{assessment_id}")
async def update_assessment(
    assessment_id: uuid.UUID,
    data: AssessmentIn,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    await owned(db, "assessments", assessment_id, current_user)
    await db.execute(text("""
        UPDATE assessments
        SET title=:title, instructions=:instructions, course_id=:course, skill_id=:skill,
            opens_at=:opens, deadline_at=:deadline, duration_minutes=:duration,
            pass_pct=:pass, max_attempts=:max, shuffle_questions=:shuffle,
            lockdown_enabled=:lockdown
        WHERE id=:id
    """), {
        "id": assessment_id,
        "title": data.title,
        "instructions": data.instructions,
        "course": data.course_id,
        "skill": data.skill_id,
        "opens": data.opens_at,
        "deadline": data.deadline_at,
        "duration": data.duration_minutes,
        "pass": data.pass_pct,
        "max": data.max_attempts,
        "shuffle": data.shuffle_questions,
        "lockdown": data.lockdown_enabled
    })
    await db.commit()
    return {"id": assessment_id}

@router.post("/assessments/{assessment_id}/questions")
async def add_question(
    assessment_id: uuid.UUID,
    question_id: uuid.UUID,
    position: int = 1,
    marks: float = 1,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    await owned(db, "assessments", assessment_id, current_user)
    q = (await db.execute(text("SELECT status FROM questions WHERE id=:id"), {"id": question_id})).mappings().first()
    if not q or q["status"] != "approved":
        raise HTTPException(422, "Only approved questions can be added")
    await db.execute(text("""
        INSERT INTO assessment_questions(assessment_id, question_id, position, marks)
        VALUES(:a, :q, :p, :m)
        ON CONFLICT(assessment_id, question_id) DO UPDATE SET position=:p, marks=:m
    """), {"a": assessment_id, "q": question_id, "p": position, "m": marks})
    await db.commit()
    return {"ok": True}

@router.delete("/assessments/{assessment_id}/questions/{question_id}")
async def remove_question(
    assessment_id: uuid.UUID,
    question_id: uuid.UUID,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    await owned(db, "assessments", assessment_id, current_user)
    await db.execute(text("DELETE FROM assessment_questions WHERE assessment_id=:a AND question_id=:q"), {"a": assessment_id, "q": question_id})
    await db.commit()
    return {"ok": True}

@router.post("/assessments/{assessment_id}/open")
async def open_assessment(
    assessment_id: uuid.UUID,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    await owned(db, "assessments", assessment_id, current_user)
    await db.execute(text("UPDATE assessments SET status='open' WHERE id=:id"), {"id": assessment_id})
    await db.commit()
    return {"id": assessment_id, "status": "open"}

@router.post("/assessments/{assessment_id}/close")
async def close_assessment(
    assessment_id: uuid.UUID,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    await owned(db, "assessments", assessment_id, current_user)
    await db.execute(text("UPDATE assessments SET status='closed' WHERE id=:id"), {"id": assessment_id})
    await db.commit()
    return {"id": assessment_id, "status": "closed"}

@router.get("/assessments/{assessment_id}/participation")
async def assessment_participation(
    assessment_id: uuid.UUID,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    await owned(db, "assessments", assessment_id, current_user)

    stats = (await db.execute(text("SELECT * FROM v_assessment_stats WHERE assessment_id = :id"), {"id": assessment_id})).mappings().first()

    attempts = await db.execute(text("""
        SELECT at.id, at.attempt_no, at.status, at.started_at, at.submitted_at,
               at.score, at.max_score, at.percentage, at.passed,
               at.tab_switch_count, at.fullscreen_exits, at.copy_paste_attempts,
               u.id AS user_id, u.full_name, u.email, u.department
        FROM attempts at
        JOIN users u ON u.id = at.user_id
        WHERE at.assessment_id = :id
        ORDER BY at.submitted_at DESC NULLS LAST, at.started_at DESC
    """), {"id": assessment_id})

    return {
        "stats": dict(stats) if stats else {},
        "attempts": [dict(r) for r in attempts.mappings().all()]
    }

# ---------------------------------------------------------------------------
# TRAINEE ASSESSMENTS & ATTEMPTS
# ---------------------------------------------------------------------------

@router.get("/me/assessments")
async def my_assessments(
    current_user: dict = Depends(require_role("trainee")),
    db: AsyncSession = Depends(get_db)
):
    """List open and available tests for the trainee (course-based or standalone)."""
    rows = await db.execute(text("""
        SELECT a.id, a.title, a.instructions, a.type, a.course_id, a.skill_id,
               c.title AS course_title, s.name AS skill_name,
               a.status, a.opens_at, a.deadline_at, a.duration_minutes,
               a.pass_pct, a.max_attempts, a.lockdown_enabled,
               (SELECT count(*) FROM assessment_questions aq WHERE aq.assessment_id = a.id) AS question_count,
               (SELECT count(*) FROM attempts at WHERE at.assessment_id = a.id AND at.user_id = :user) AS my_attempts_count,
               (SELECT at.id FROM attempts at WHERE at.assessment_id = a.id AND at.user_id = :user ORDER BY at.attempt_no DESC LIMIT 1) AS last_attempt_id,
               (SELECT at.status FROM attempts at WHERE at.assessment_id = a.id AND at.user_id = :user ORDER BY at.attempt_no DESC LIMIT 1) AS last_attempt_status,
               (SELECT at.percentage FROM attempts at WHERE at.assessment_id = a.id AND at.user_id = :user ORDER BY at.attempt_no DESC LIMIT 1) AS last_percentage,
               (SELECT at.passed FROM attempts at WHERE at.assessment_id = a.id AND at.user_id = :user ORDER BY at.attempt_no DESC LIMIT 1) AS last_passed
        FROM assessments a
        LEFT JOIN courses c ON c.id = a.course_id
        LEFT JOIN skills s ON s.id = a.skill_id
        WHERE a.status = 'open'
          AND (
            a.course_id IS NULL
            OR a.course_id IN (SELECT course_id FROM enrollments WHERE user_id = :user)
          )
        ORDER BY a.deadline_at ASC NULLS LAST, a.created_at DESC
    """), {"user": current_user["id"]})

    now = datetime.now(timezone.utc)
    items = []
    for r in rows.mappings().all():
        d = dict(r)
        opens_ok = d["opens_at"] is None or d["opens_at"] <= now
        deadline_ok = d["deadline_at"] is None or d["deadline_at"] >= now
        attempts_left = d["my_attempts_count"] < d["max_attempts"]
        in_progress = d["last_attempt_status"] == "in_progress"

        d["can_start"] = (opens_ok and deadline_ok and attempts_left) or in_progress
        items.append(d)

    return {"items": items}

async def auto_submit(db: AsyncSession, attempt_id: uuid.UUID):
    attempt = (await db.execute(text("SELECT assessment_id FROM attempts WHERE id=:id"), {"id": attempt_id})).mappings().first()
    if attempt:
        await grade(db, attempt_id, attempt["assessment_id"], "auto_submitted")

async def grade(db: AsyncSession, attempt_id: uuid.UUID, assessment_id: uuid.UUID, final_status: str = "submitted"):
    rows = await db.execute(text("""
        SELECT aq.question_id, aq.marks, qo.id AS correct_id
        FROM assessment_questions aq
        JOIN question_options qo ON qo.question_id = aq.question_id AND qo.is_correct
        WHERE aq.assessment_id = :aid
    """), {"aid": assessment_id})

    total = 0.0
    score = 0.0
    for r in rows.mappings().all():
        total += float(r["marks"])
        ans = (await db.execute(text("""
            SELECT selected_option_ids FROM attempt_answers
            WHERE attempt_id = :a AND question_id = :q
        """), {"a": attempt_id, "q": r["question_id"]})).mappings().first()

        correct = bool(ans and ans["selected_option_ids"] and str(r["correct_id"]) in [str(x) for x in ans["selected_option_ids"]])
        earned = float(r["marks"]) if correct else 0.0
        score += earned

        await db.execute(text("""
            UPDATE attempt_answers
            SET is_correct = :correct, marks_awarded = :earned
            WHERE attempt_id = :a AND question_id = :q
        """), {"correct": correct, "earned": earned, "a": attempt_id, "q": r["question_id"]})

    assessment = (await db.execute(text("SELECT pass_pct, course_id FROM assessments WHERE id=:id"), {"id": assessment_id})).mappings().first()
    pct = round(100.0 * score / total, 2) if total else 0.0
    passed = bool(pct >= (assessment["pass_pct"] if assessment else 60))

    await db.execute(text("""
        UPDATE attempts
        SET status = :status, submitted_at = now(), score = :score, max_score = :total,
            percentage = :pct, passed = :passed
        WHERE id = :id
    """), {"status": final_status, "score": score, "total": total, "pct": pct, "passed": passed, "id": attempt_id})

    # Queue competency recalculation
    await db.execute(text("""
        INSERT INTO jobs(type, payload, dedupe_key)
        VALUES('competency_refresh', '{}', :key)
        ON CONFLICT DO NOTHING
    """), {"key": "competency:assessment"})

    # Check enrollment completion & certificate issuing if passed and linked to course
    if passed and assessment and assessment["course_id"]:
        user_row = (await db.execute(text("SELECT user_id FROM attempts WHERE id=:id"), {"id": attempt_id})).mappings().first()
        if user_row:
            uid = user_row["user_id"]
            cid = assessment["course_id"]
            enroll_row = (await db.execute(text("""
                SELECT id, progress_pct, status FROM enrollments WHERE course_id = :cid AND user_id = :uid
            """), {"cid": cid, "uid": uid})).mappings().first()

            if enroll_row and float(enroll_row["progress_pct"] or 0) >= 100.0:
                await db.execute(text("""
                    UPDATE enrollments SET status = 'completed', completed_at = now() WHERE id = :id
                """), {"id": enroll_row["id"]})

                # Check if course issues certificates
                course_row = (await db.execute(text("SELECT issues_certificate FROM courses WHERE id=:id"), {"id": cid})).mappings().first()
                if course_row and course_row["issues_certificate"]:
                    await db.execute(text("""
                        INSERT INTO jobs(type, payload, dedupe_key)
                        VALUES('certificate_issue', json_build_object('enrollment_id', :eid), :key)
                        ON CONFLICT DO NOTHING
                    """), {"eid": str(enroll_row["id"]), "key": f"cert:{enroll_row['id']}"})

@router.post("/assessments/{assessment_id}/start")
async def start_attempt(
    assessment_id: uuid.UUID,
    current_user: dict = Depends(require_role("trainee")),
    db: AsyncSession = Depends(get_db)
):
    a = (await db.execute(text("SELECT * FROM assessments WHERE id=:id"), {"id": assessment_id})).mappings().first()
    if not a or a["status"] != "open":
        raise HTTPException(404, "Assessment is not open")

    now = datetime.now(timezone.utc)
    if (a["opens_at"] and a["opens_at"] > now) or (a["deadline_at"] and a["deadline_at"] < now):
        raise HTTPException(422, "Assessment is outside its available window")

    if a["course_id"] and not (await db.execute(text("SELECT 1 FROM enrollments WHERE course_id=:course AND user_id=:user"), {"course": a["course_id"], "user": current_user["id"]})).first():
        raise HTTPException(403, "Enroll in the course before starting this assessment")

    # Check if there is an in-progress attempt to resume
    in_prog = (await db.execute(text("""
        SELECT id, expires_at FROM attempts
        WHERE assessment_id = :a AND user_id = :u AND status = 'in_progress'
    """), {"a": assessment_id, "u": current_user["id"]})).mappings().first()

    if in_prog:
        if in_prog["expires_at"] and in_prog["expires_at"] < now:
            await auto_submit(db, in_prog["id"])
            await db.commit()
        else:
            # Resume attempt
            qs = await db.execute(text("""
                SELECT q.id, q.text, q.type, q.difficulty, aq.position, aq.marks,
                       json_agg(json_build_object('id', o.id, 'text', o.text, 'position', o.position) ORDER BY o.position) AS options
                FROM assessment_questions aq
                JOIN questions q ON q.id = aq.question_id
                JOIN question_options o ON o.question_id = q.id
                WHERE aq.assessment_id = :id
                GROUP BY q.id, aq.position, aq.marks
                ORDER BY aq.position
            """), {"id": assessment_id})

            saved_answers = await db.execute(text("""
                SELECT question_id, selected_option_ids, text_answer FROM attempt_answers WHERE attempt_id = :id
            """), {"id": in_prog["id"]})

            return {
                "attempt_id": in_prog["id"],
                "expires_at": in_prog["expires_at"],
                "duration_minutes": a["duration_minutes"],
                "lockdown_enabled": a["lockdown_enabled"],
                "questions": [dict(x) for x in qs.mappings().all()],
                "saved_answers": {str(x["question_id"]): [str(opt) for opt in (x["selected_option_ids"] or [])] for x in saved_answers.mappings().all()}
            }

    number = (await db.execute(text("SELECT count(*) FROM attempts WHERE assessment_id=:a AND user_id=:u"), {"a": assessment_id, "u": current_user["id"]})).scalar() or 0
    if number >= a["max_attempts"]:
        raise HTTPException(422, "Maximum attempts reached")

    aid = uuid.uuid4()
    expires = now + timedelta(minutes=a["duration_minutes"]) if a["duration_minutes"] else a["deadline_at"]
    await db.execute(text("""
        INSERT INTO attempts(id, assessment_id, user_id, attempt_no, expires_at)
        VALUES(:id, :assessment, :user, :number, :expires)
    """), {"id": aid, "assessment": assessment_id, "user": current_user["id"], "number": number + 1, "expires": expires})

    order_clause = "RANDOM()" if a["shuffle_questions"] else "aq.position"
    qs = await db.execute(text(f"""
        SELECT q.id, q.text, q.type, q.difficulty, aq.position, aq.marks,
               json_agg(json_build_object('id', o.id, 'text', o.text, 'position', o.position) ORDER BY o.position) AS options
        FROM assessment_questions aq
        JOIN questions q ON q.id = aq.question_id
        JOIN question_options o ON o.question_id = q.id
        WHERE aq.assessment_id = :id
        GROUP BY q.id, aq.position, aq.marks
        ORDER BY {order_clause}
    """), {"id": assessment_id})

    await db.commit()
    return {
        "attempt_id": aid,
        "expires_at": expires,
        "duration_minutes": a["duration_minutes"],
        "lockdown_enabled": a["lockdown_enabled"],
        "questions": [dict(x) for x in qs.mappings().all()],
        "saved_answers": {}
    }

@router.put("/attempts/{attempt_id}/answers")
async def save_answer(
    attempt_id: uuid.UUID,
    question_id: uuid.UUID,
    data: AnswerIn,
    current_user: dict = Depends(require_role("trainee")),
    db: AsyncSession = Depends(get_db)
):
    at = (await db.execute(text("SELECT * FROM attempts WHERE id=:id AND user_id=:user"), {"id": attempt_id, "user": current_user["id"]})).mappings().first()
    if not at:
        raise HTTPException(404, "Attempt not found")
    if at["status"] != "in_progress":
        raise HTTPException(409, "Attempt is not in progress")

    if at["expires_at"] and at["expires_at"] < datetime.now(timezone.utc):
        await auto_submit(db, attempt_id)
        await db.commit()
        raise HTTPException(409, "Time expired; your attempt was submitted")

    await db.execute(text("""
        INSERT INTO attempt_answers(attempt_id, question_id, selected_option_ids, text_answer, rating_value)
        VALUES(:a, :q, :options, :text, :rating)
        ON CONFLICT(attempt_id, question_id) DO UPDATE SET
            selected_option_ids = :options,
            text_answer = :text,
            rating_value = :rating,
            answered_at = now()
    """), {
        "a": attempt_id,
        "q": question_id,
        "options": data.selected_option_ids,
        "text": data.text_answer,
        "rating": data.rating_value
    })
    await db.commit()
    return {"saved": True}

@router.post("/attempts/{attempt_id}/events")
async def record_proctor_event(
    attempt_id: uuid.UUID,
    data: ProctorEventIn,
    current_user: dict = Depends(require_role("trainee")),
    db: AsyncSession = Depends(get_db)
):
    at = (await db.execute(text("""
        SELECT id, status, expires_at FROM attempts WHERE id=:id AND user_id=:user
    """), {"id": attempt_id, "user": current_user["id"]})).mappings().first()

    if not at:
        raise HTTPException(404, "Attempt not found")
    if at["status"] != "in_progress":
        raise HTTPException(409, "Attempt is not in progress")

    event_obj = json.dumps({"type": data.event_type, "timestamp": datetime.now(timezone.utc).isoformat()})

    counter_update = ""
    if data.event_type == "blur":
        counter_update = "tab_switch_count = tab_switch_count + 1"
    elif data.event_type == "fullscreen_exit":
        counter_update = "fullscreen_exits = fullscreen_exits + 1"
    elif data.event_type == "copy":
        counter_update = "copy_paste_attempts = copy_paste_attempts + 1"

    await db.execute(text(f"""
        UPDATE attempts
        SET {counter_update},
            proctor_events = proctor_events || :event::jsonb
        WHERE id = :id
    """), {"id": attempt_id, "event": f"[{event_obj}]"})
    await db.commit()

    res = (await db.execute(text("""
        SELECT tab_switch_count, fullscreen_exits, copy_paste_attempts FROM attempts WHERE id=:id
    """), {"id": attempt_id})).mappings().first()

    return dict(res)

@router.post("/attempts/{attempt_id}/submit")
async def submit(
    attempt_id: uuid.UUID,
    current_user: dict = Depends(require_role("trainee")),
    db: AsyncSession = Depends(get_db)
):
    at = (await db.execute(text("SELECT * FROM attempts WHERE id=:id AND user_id=:user"), {"id": attempt_id, "user": current_user["id"]})).mappings().first()
    if not at:
        raise HTTPException(404, "Attempt not found")
    if at["status"] != "in_progress":
        raise HTTPException(409, "Attempt already submitted")

    await grade(db, attempt_id, at["assessment_id"])
    await db.commit()
    return {"attempt_id": attempt_id, "submitted": True}

@router.get("/attempts/{attempt_id}/result")
async def result(
    attempt_id: uuid.UUID,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    at = (await db.execute(text("""
        SELECT a.*, s.title, s.pass_pct AS required_pass_pct, s.show_results, c.id AS course_id, c.title AS course_title
        FROM attempts a
        JOIN assessments s ON s.id = a.assessment_id
        LEFT JOIN courses c ON c.id = s.course_id
        WHERE a.id = :id
    """), {"id": attempt_id})).mappings().first()

    if not at or (current_user["role"] != "admin" and at["user_id"] != current_user["id"]):
        raise HTTPException(404, "Attempt not found")
    if at["status"] == "in_progress" or not at["show_results"]:
        raise HTTPException(403, "Results are not available")

    answers = await db.execute(text("""
        SELECT q.id AS question_id, q.text, q.explanation, aa.is_correct, aa.marks_awarded,
               aa.selected_option_ids,
               qo_user.text AS user_answer,
               qo_correct.text AS correct_answer
        FROM attempt_answers aa
        JOIN questions q ON q.id = aa.question_id
        LEFT JOIN question_options qo_user ON qo_user.id = aa.selected_option_ids[1]
        LEFT JOIN question_options qo_correct ON qo_correct.question_id = q.id AND qo_correct.is_correct
        WHERE aa.attempt_id = :id
    """), {"id": attempt_id})

    return {
        "attempt": dict(at),
        "answers": [dict(x) for x in answers.mappings().all()]
    }
