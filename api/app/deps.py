import uuid
from typing import Optional, List, Callable
from datetime import datetime, timezone
import jwt
from fastapi import Request, Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_db

bearer_scheme = HTTPBearer(auto_error=False)

async def write_audit_log(
    session: AsyncSession,
    actor_id: Optional[uuid.UUID],
    action: str,
    entity_type: str,
    entity_id: Optional[str] = None,
    details: Optional[dict] = None,
    ip_address: Optional[str] = None
):
    import json
    await session.execute(
        text("""
            INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details, ip_address, created_at)
            VALUES (:actor_id, :action, :entity_type, :entity_id, :details, :ip_address, now())
        """),
        {
            "actor_id": actor_id,
            "action": action,
            "entity_type": entity_type,
            "entity_id": str(entity_id) if entity_id else None,
            "details": json.dumps(details) if details else None,
            "ip_address": ip_address
        }
    )

async def get_current_user_optional(
    request: Request,
    bearer: Optional[HTTPAuthorizationCredentials] = Depends(bearer_scheme),
    db: AsyncSession = Depends(get_db)
) -> Optional[dict]:
    token = None
    # 1. Check httpOnly cookie
    if settings.COOKIE_NAME in request.cookies:
        token = request.cookies[settings.COOKIE_NAME]
    # 2. Check Authorization Bearer header
    elif bearer:
        token = bearer.credentials

    if not token:
        return None

    try:
        payload = jwt.decode(
            token,
            settings.JWT_SECRET,
            algorithms=[settings.JWT_ALGORITHM]
        )
    except jwt.PyJWTError:
        return None

    user_id = payload.get("sub")
    token_version = payload.get("token_version")
    if not user_id or token_version is None:
        return None

    try:
        user_uuid = uuid.UUID(user_id)
    except ValueError:
        return None

    result = await db.execute(
        text("""
            SELECT id, email, full_name, role, status, token_version, 
                   employee_code, designation, department, preferred_lang,
                   avatar_file_id, created_at
            FROM users WHERE id = :id
        """),
        {"id": user_uuid}
    )
    user = result.mappings().first()
    if not user:
        return None

    # Check status == 'approved' and token_version match
    if user["status"] != "approved":
        return None

    if user["token_version"] != token_version:
        return None

    return dict(user)

async def get_current_user(
    user: Optional[dict] = Depends(get_current_user_optional)
) -> dict:
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required or token expired / revoked"
        )
    return user

def require_role(*allowed_roles: str) -> Callable:
    async def role_checker(current_user: dict = Depends(get_current_user)) -> dict:
        if current_user["role"] not in allowed_roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Forbidden: role '{current_user['role']}' does not have permission"
            )
        return current_user
    return role_checker
