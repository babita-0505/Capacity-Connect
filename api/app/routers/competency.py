import uuid
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import get_current_user, require_role

router = APIRouter(tags=["Competency"])

@router.get("/competency/trainers")
async def trainer_recommendations(skill_id: int = Query(...), page: int = Query(1, ge=1), page_size: int = Query(20, ge=1, le=100), current_user: dict = Depends(require_role("admin", "trainer")), db: AsyncSession = Depends(get_db)):
    offset = (page - 1) * page_size
    rows = await db.execute(text("SELECT * FROM v_trainer_recommendations WHERE skill_id=:skill_id ORDER BY rank_in_skill LIMIT :limit OFFSET :offset"), {"skill_id": skill_id, "limit": page_size, "offset": offset})
    total = await db.execute(text("SELECT count(*) FROM v_trainer_recommendations WHERE skill_id=:skill_id"), {"skill_id": skill_id})
    return {"items": [dict(x) for x in rows.mappings().all()], "total": total.scalar() or 0, "page": page, "page_size": page_size}

@router.get("/competency/trainers/{trainer_id}/why")
async def trainer_why(trainer_id: uuid.UUID, skill_id: int = Query(...), current_user: dict = Depends(require_role("admin", "trainer")), db: AsyncSession = Depends(get_db)):
    row = (await db.execute(text("SELECT * FROM v_trainer_recommendations WHERE trainer_id=:trainer_id AND skill_id=:skill_id"), {"trainer_id": trainer_id, "skill_id": skill_id})).mappings().first()
    if not row:
        raise HTTPException(404, "No competency evidence found")
    item = dict(row)
    item["weights"] = {"skill_match": .40, "pass_rate": .25, "rating": .20, "experience": .15}
    return item

@router.get("/competency/gaps")
async def skill_gaps(page: int = Query(1, ge=1), page_size: int = Query(100, ge=1, le=100), current_user: dict = Depends(require_role("admin", "trainer")), db: AsyncSession = Depends(get_db)):
    rows = await db.execute(text("SELECT * FROM v_skill_gaps ORDER BY CASE gap_status WHEN 'critical gap' THEN 0 WHEN 'weak coverage' THEN 1 ELSE 2 END, demand DESC LIMIT :limit OFFSET :offset"), {"limit": page_size, "offset": (page-1)*page_size})
    return {"items": [dict(x) for x in rows.mappings().all()], "page": page, "page_size": page_size}

@router.get("/competency/heatmap")
async def heatmap(department: Optional[str] = None, category: Optional[str] = None, current_user: dict = Depends(require_role("admin", "trainer")), db: AsyncSession = Depends(get_db)):
    rows = await db.execute(text("SELECT * FROM v_skill_heatmap WHERE (:department IS NULL OR department=:department) AND (:category IS NULL OR category=:category) ORDER BY department, skill"), {"department": department, "category": category})
    return {"items": [dict(x) for x in rows.mappings().all()]}

@router.post("/admin/competency/refresh", status_code=status.HTTP_202_ACCEPTED)
async def refresh_competency(current_user: dict = Depends(require_role("admin")), db: AsyncSession = Depends(get_db)):
    job = (await db.execute(text("INSERT INTO jobs (type, payload, dedupe_key, created_by) VALUES ('competency_refresh', '{}', :key, :user) ON CONFLICT (type, dedupe_key) WHERE status <> 'failed' DO UPDATE SET run_after=now() RETURNING id"), {"key": "competency:manual", "user": current_user["id"]})).scalar()
    await db.commit()
    return {"job_id": job}

@router.get("/jobs/{job_id}")
async def get_job(job_id: uuid.UUID, current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    row = (await db.execute(text("SELECT id,type,status,payload,result,error,created_by,created_at,finished_at FROM jobs WHERE id=:id"), {"id": job_id})).mappings().first()
    if not row or (current_user["role"] != "admin" and row["created_by"] != current_user["id"]):
        raise HTTPException(404, "Job not found")
    return dict(row)

@router.get("/me/competency")
async def my_competency(current_user: dict = Depends(require_role("trainee")), db: AsyncSession = Depends(get_db)):
    skills = await db.execute(text("""SELECT a.skill_id, s.name AS skill, round(avg(t.percentage),1) AS average_pct
        FROM attempts t JOIN assessments a ON a.id=t.assessment_id JOIN skills s ON s.id=a.skill_id
        WHERE t.user_id=:user AND t.status <> 'in_progress' GROUP BY a.skill_id,s.name ORDER BY s.name"""), {"user": current_user["id"]})
    items=[]
    for row in skills.mappings().all():
        item=dict(row); pct=float(item["average_pct"]); item["level"] = "Beginner" if pct < 40 else "Basic" if pct < 60 else "Intermediate" if pct < 75 else "Advanced" if pct < 90 else "Expert"; item["weak"] = pct < 60; items.append(item)
    paths = await db.execute(text("SELECT * FROM v_learning_path WHERE user_id=:user ORDER BY weak_skill,title"), {"user": current_user["id"]})
    return {"skills": items, "weak_skills": [x for x in items if x["weak"]], "recommended_courses": [dict(x) for x in paths.mappings().all()]}
