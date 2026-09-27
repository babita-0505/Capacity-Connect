from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession
from app.db import get_db
from app.deps import require_role

router = APIRouter(prefix="/admin/dashboard", tags=["Dashboards"])

@router.get("")
async def admin_dashboard(current_user: dict = Depends(require_role("admin")), db: AsyncSession = Depends(get_db)):
    kpis = (await db.execute(text("SELECT * FROM v_platform_kpis"))).mappings().first()
    courses = await db.execute(text("SELECT * FROM v_course_stats ORDER BY enrollments DESC LIMIT 12"))
    assessments = await db.execute(text("SELECT * FROM v_assessment_stats ORDER BY deadline_at DESC NULLS LAST LIMIT 12"))
    activity = await db.execute(text("SELECT * FROM v_monthly_activity ORDER BY month"))
    pending = await db.execute(text("SELECT id,full_name,email,role,department,created_at FROM users WHERE status='pending' ORDER BY created_at LIMIT 8"))
    return {"kpis": dict(kpis) if kpis else {}, "courses": [dict(x) for x in courses.mappings().all()], "assessments": [dict(x) for x in assessments.mappings().all()], "activity": [dict(x) for x in activity.mappings().all()], "pending_users": [dict(x) for x in pending.mappings().all()]}
