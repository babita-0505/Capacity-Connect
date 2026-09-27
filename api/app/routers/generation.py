import uuid
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import require_role

router = APIRouter(prefix="/resources", tags=["MCQ generation"])

class GenerateRequest(BaseModel):
    count: int = Field(ge=1, le=20, default=5)
    difficulty: int = Field(ge=1, le=5, default=2)

@router.post("/{resource_id}/generate-mcqs", status_code=status.HTTP_202_ACCEPTED)
async def generate_mcqs(resource_id: uuid.UUID, data: GenerateRequest, current_user: dict = Depends(require_role("trainer", "admin")), db: AsyncSession = Depends(get_db)):
    resource = (await db.execute(text("""SELECT r.id,r.trainer_id,r.file_id,r.skill_id,f.sha256,f.storage_path
        FROM learning_resources r JOIN files f ON f.id=r.file_id WHERE r.id=:id"""), {"id": resource_id})).mappings().first()
    if not resource or (current_user["role"] != "admin" and resource["trainer_id"] != current_user["id"]):
        raise HTTPException(404, "PDF resource not found")
    if not resource["storage_path"].lower().endswith(".pdf"):
        raise HTTPException(422, "Only PDF resources can generate MCQs")
    key = f"mcq:{resource['sha256']}:{data.count}"
    cached = (await db.execute(text("SELECT id,status,result FROM jobs WHERE type='mcq_generate' AND dedupe_key=:key AND status='done'"), {"key": key})).mappings().first()
    if cached:
        return {"job_id": cached["id"], "status": "done", "result": cached["result"], "cached": True}
    job_id = (await db.execute(text("""INSERT INTO jobs(type,payload,dedupe_key,created_by) VALUES
        ('mcq_generate',json_build_object('resource_id',:resource,'count',:count,'difficulty',:difficulty),:key,:user)
        ON CONFLICT(type,dedupe_key) WHERE status <> 'failed' DO UPDATE SET run_after=now() RETURNING id"""), {"resource": resource_id, "count": data.count, "difficulty": data.difficulty, "key": key, "user": current_user["id"]})).scalar()
    await db.commit()
    return {"job_id": job_id, "cached": False}
