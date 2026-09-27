import uuid
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, status, Query, Request
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import require_role, write_audit_log
from app.schemas.admin import UserAdminResponse, RejectRequest, RoleChangeRequest

router = APIRouter(prefix="/admin", tags=["Admin"], dependencies=[Depends(require_role("admin"))])

@router.get("/users")
async def list_users(
    status: Optional[str] = None,
    role: Optional[str] = None,
    q: Optional[str] = None,
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=100),
    db: AsyncSession = Depends(get_db)
):
    offset = (page - 1) * page_size
    where_clauses = ["1=1"]
    params = {"limit": page_size, "offset": offset}

    if status:
        where_clauses.append("status = :status")
        params["status"] = status
    if role:
        where_clauses.append("role = :role")
        params["role"] = role
    if q:
        where_clauses.append("(full_name ILIKE :q OR email ILIKE :q OR employee_code ILIKE :q)")
        params["q"] = f"%{q}%"

    where_sql = " AND ".join(where_clauses)

    count_result = await db.execute(
        text(f"SELECT count(*) FROM users WHERE {where_sql}"),
        params
    )
    total = count_result.scalar() or 0

    items_result = await db.execute(
        text(f"""
            SELECT id, email, full_name, role, status, department, designation,
                   employee_code, token_version, approved_at, rejection_reason, created_at
            FROM users
            WHERE {where_sql}
            ORDER BY created_at DESC
            LIMIT :limit OFFSET :offset
        """),
        params
    )
    items = [dict(row) for row in items_result.mappings().all()]

    return {
        "items": items,
        "total": total,
        "page": page,
        "page_size": page_size
    }

@router.patch("/users/{user_id}/approve")
async def approve_user(
    user_id: uuid.UUID,
    request: Request,
    current_user: dict = Depends(require_role("admin")),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("SELECT id, status, full_name FROM users WHERE id = :id"),
        {"id": user_id}
    )
    user = result.mappings().first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    await db.execute(
        text("""
            UPDATE users 
            SET status = 'approved', approved_by = :admin_id, approved_at = now(), updated_at = now()
            WHERE id = :id
        """),
        {"admin_id": current_user["id"], "id": user_id}
    )

    # Insert account_approved notification
    await db.execute(
        text("""
            INSERT INTO notifications (user_id, type, title, body, created_at)
            VALUES (:user_id, 'account_approved', 'Account Approved', 
                    'Your Capacity Connect account has been approved by the training cell administrator.', now())
        """),
        {"user_id": user_id}
    )

    await write_audit_log(
        session=db,
        actor_id=current_user["id"],
        action="user.approve",
        entity_type="user",
        entity_id=str(user_id),
        details={"approved_by": str(current_user["id"])},
        ip_address=request.client.host if request.client else None
    )
    await db.commit()

    return {"message": "User approved successfully", "user_id": str(user_id)}

@router.patch("/users/{user_id}/reject")
async def reject_user(
    user_id: uuid.UUID,
    body: RejectRequest,
    request: Request,
    current_user: dict = Depends(require_role("admin")),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("SELECT id FROM users WHERE id = :id"),
        {"id": user_id}
    )
    if not result.first():
        raise HTTPException(status_code=404, detail="User not found")

    await db.execute(
        text("""
            UPDATE users 
            SET status = 'rejected', rejection_reason = :reason, 
                token_version = token_version + 1, updated_at = now()
            WHERE id = :id
        """),
        {"reason": body.reason, "id": user_id}
    )

    await write_audit_log(
        session=db,
        actor_id=current_user["id"],
        action="user.reject",
        entity_type="user",
        entity_id=str(user_id),
        details={"reason": body.reason},
        ip_address=request.client.host if request.client else None
    )
    await db.commit()

    return {"message": "User rejected", "user_id": str(user_id)}

@router.patch("/users/{user_id}/suspend")
async def suspend_user(
    user_id: uuid.UUID,
    request: Request,
    current_user: dict = Depends(require_role("admin")),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("SELECT id FROM users WHERE id = :id"),
        {"id": user_id}
    )
    if not result.first():
        raise HTTPException(status_code=404, detail="User not found")

    # Invalidate tokens immediately by bumping token_version
    await db.execute(
        text("""
            UPDATE users 
            SET status = 'suspended', token_version = token_version + 1, updated_at = now()
            WHERE id = :id
        """),
        {"id": user_id}
    )

    await write_audit_log(
        session=db,
        actor_id=current_user["id"],
        action="user.suspend",
        entity_type="user",
        entity_id=str(user_id),
        ip_address=request.client.host if request.client else None
    )
    await db.commit()

    return {"message": "User suspended and sessions invalidated", "user_id": str(user_id)}

@router.patch("/users/{user_id}/activate")
async def activate_user(
    user_id: uuid.UUID,
    request: Request,
    current_user: dict = Depends(require_role("admin")),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("SELECT id FROM users WHERE id = :id"),
        {"id": user_id}
    )
    if not result.first():
        raise HTTPException(status_code=404, detail="User not found")

    await db.execute(
        text("""
            UPDATE users 
            SET status = 'approved', updated_at = now()
            WHERE id = :id
        """),
        {"id": user_id}
    )

    await write_audit_log(
        session=db,
        actor_id=current_user["id"],
        action="user.activate",
        entity_type="user",
        entity_id=str(user_id),
        ip_address=request.client.host if request.client else None
    )
    await db.commit()

    return {"message": "User activated", "user_id": str(user_id)}

@router.patch("/users/{user_id}/role")
async def change_user_role(
    user_id: uuid.UUID,
    body: RoleChangeRequest,
    request: Request,
    current_user: dict = Depends(require_role("admin")),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("SELECT id, role FROM users WHERE id = :id"),
        {"id": user_id}
    )
    user = result.mappings().first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    # Invalidate existing tokens when role changes
    await db.execute(
        text("""
            UPDATE users 
            SET role = :role, token_version = token_version + 1, updated_at = now()
            WHERE id = :id
        """),
        {"role": body.role, "id": user_id}
    )

    await write_audit_log(
        session=db,
        actor_id=current_user["id"],
        action="user.role_change",
        entity_type="user",
        entity_id=str(user_id),
        details={"old_role": user["role"], "new_role": body.role},
        ip_address=request.client.host if request.client else None
    )
    await db.commit()

    return {"message": f"User role changed to {body.role}", "user_id": str(user_id)}
