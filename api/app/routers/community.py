import hashlib
import hmac
import json
import uuid
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_db
from app.deps import get_current_user, get_current_user_optional, require_role

router = APIRouter(tags=["Communication"])

class FeedbackIn(BaseModel):
    content_rating: int = Field(ge=1, le=5)
    trainer_rating: int = Field(ge=1, le=5)
    comment: Optional[str] = Field(None, max_length=2000)
    is_anonymous: bool = False

class AnnouncementIn(BaseModel):
    type: str = "announcement"; title: str; title_hi: Optional[str] = None; body: Optional[str] = None
    link_url: Optional[str] = None; audience: Optional[str] = None; is_pinned: bool = False

@router.post("/courses/{course_id}/feedback", status_code=status.HTTP_201_CREATED)
async def leave_feedback(course_id: uuid.UUID, data: FeedbackIn, current_user: dict = Depends(require_role("trainee")), db: AsyncSession = Depends(get_db)):
    course = (await db.execute(text("SELECT trainer_id FROM courses WHERE id=:id"), {"id": course_id})).mappings().first()
    enrolled = (await db.execute(text("SELECT 1 FROM enrollments WHERE course_id=:course AND user_id=:user"), {"course": course_id, "user": current_user["id"]})).first()
    if not course or not enrolled: raise HTTPException(403, "Enroll in this course before submitting feedback")
    try:
        await db.execute(text("INSERT INTO feedback(id,user_id,course_id,trainer_id,content_rating,trainer_rating,comment,is_anonymous) VALUES(:id,:user,:course,:trainer,:content,:rating,:comment,:anonymous)"), {"id": uuid.uuid4(), "user": current_user["id"], "course": course_id, "trainer": course["trainer_id"], "content": data.content_rating, "rating": data.trainer_rating, "comment": data.comment, "anonymous": data.is_anonymous})
    except Exception:
        await db.rollback(); raise HTTPException(409, "Feedback has already been submitted for this course")
    await db.execute(text("INSERT INTO jobs(type,payload,dedupe_key) VALUES('competency_refresh','{}','competency:feedback') ON CONFLICT DO NOTHING")); await db.commit()
    return {"message": "Feedback submitted"}

@router.get("/me/notifications")
async def notifications(after_id: int = Query(0, ge=0), limit: int = Query(30, ge=1, le=100), current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    rows = await db.execute(text("SELECT id,type,title,body,link,read_at,created_at FROM notifications WHERE user_id=:user AND id>:after ORDER BY id DESC LIMIT :limit"), {"user": current_user["id"], "after": after_id, "limit": limit})
    unread = await db.execute(text("SELECT count(*) FROM notifications WHERE user_id=:user AND read_at IS NULL"), {"user": current_user["id"]})
    return {"items": [dict(x) for x in rows.mappings().all()], "unread_count": unread.scalar() or 0}

@router.post("/me/notifications/{notification_id}/read")
async def mark_read(notification_id: int, current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    await db.execute(text("UPDATE notifications SET read_at=now() WHERE id=:id AND user_id=:user"), {"id": notification_id, "user": current_user["id"]}); await db.commit(); return {"ok": True}

@router.post("/me/notifications/read-all")
async def mark_all_read(current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    await db.execute(text("UPDATE notifications SET read_at=now() WHERE user_id=:user AND read_at IS NULL"), {"user": current_user["id"]}); await db.commit(); return {"ok": True}

@router.get("/feed")
async def feed(limit: int = Query(30, ge=1, le=100), current_user: Optional[dict] = Depends(get_current_user_optional), db: AsyncSession = Depends(get_db)):
    role = current_user["role"] if current_user else None
    rows = await db.execute(text("SELECT id,type,title,title_hi,body,link_url,related_course_id,is_pinned,publish_at FROM announcements WHERE publish_at<=now() AND (expires_at IS NULL OR expires_at>now()) AND (audience IS NULL OR audience=:role) ORDER BY is_pinned DESC,publish_at DESC LIMIT :limit"), {"role": role, "limit": limit})
    return {"items": [dict(x) for x in rows.mappings().all()]}

@router.post("/admin/announcements", status_code=201)
async def create_announcement(data: AnnouncementIn, current_user: dict = Depends(require_role("admin")), db: AsyncSession = Depends(get_db)):
    if data.type not in {"notification", "announcement", "achievement", "new_content"}: raise HTTPException(422, "Invalid announcement type")
    aid=uuid.uuid4(); await db.execute(text("INSERT INTO announcements(id,type,title,title_hi,body,link_url,audience,is_pinned,created_by) VALUES(:id,:type,:title,:hi,:body,:link,:audience,:pinned,:user)"), {"id":aid,"type":data.type,"title":data.title,"hi":data.title_hi,"body":data.body,"link":data.link_url,"audience":data.audience,"pinned":data.is_pinned,"user":current_user["id"]});await db.commit();return {"id":aid}

@router.get("/verify/{certificate_no}")
async def verify_certificate(certificate_no: str, db: AsyncSession = Depends(get_db)):
    cert=(await db.execute(text("SELECT c.certificate_no,c.payload,c.signature,c.revoked_at,c.revoke_reason,u.full_name,co.title,c.issued_at FROM certificates c JOIN users u ON u.id=c.user_id JOIN courses co ON co.id=c.course_id WHERE c.certificate_no=:no"),{"no":certificate_no})).mappings().first()
    if not cert: return {"status":"Not found"}
    canonical=json.dumps(cert["payload"],sort_keys=True,separators=(",",":")); signature=hmac.new(settings.CERT_HMAC_SECRET.encode(),canonical.encode(),hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature,cert["signature"]): return {"status":"Invalid"}
    return {"status":"Revoked" if cert["revoked_at"] else "Valid","name":cert["full_name"],"course":cert["title"],"issue_date":cert["issued_at"],"revocation_reason":cert["revoke_reason"] if cert["revoked_at"] else None}

class RevokeIn(BaseModel):
    reason: str

@router.patch("/admin/certificates/{certificate_no}/revoke")
async def revoke_certificate(certificate_no: str, data: RevokeIn, current_user: dict = Depends(require_role("admin")), db: AsyncSession = Depends(get_db)):
    cert = (await db.execute(text("SELECT id, user_id FROM certificates WHERE certificate_no=:no"), {"no": certificate_no})).mappings().first()
    if not cert:
        raise HTTPException(404, "Certificate not found")
    await db.execute(text("UPDATE certificates SET revoked_at=now(), revoke_reason=:reason WHERE certificate_no=:no"), {"no": certificate_no, "reason": data.reason})
    await db.commit()
    return {"certificate_no": certificate_no, "status": "revoked"}

