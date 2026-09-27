import uuid
from datetime import datetime, timedelta, timezone
from fastapi import APIRouter, Depends, HTTPException, status, Response, Request
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession
import bcrypt
import jwt

from app.config import settings
from app.db import get_db
from app.deps import get_current_user, write_audit_log
from app.schemas.auth import SignupRequest, LoginRequest, UserResponse

router = APIRouter(prefix="/auth", tags=["Authentication"])

def hash_password(password: str) -> str:
    salt = bcrypt.gensalt(rounds=12)
    return bcrypt.hashpw(password.encode("utf-8"), salt).decode("utf-8")

def verify_password(plain_password: str, hashed_password: str) -> bool:
    try:
        return bcrypt.checkpw(plain_password.encode("utf-8"), hashed_password.encode("utf-8"))
    except Exception:
        return False

def create_jwt_token(user_id: uuid.UUID, role: str, token_version: int) -> str:
    expires = datetime.now(timezone.utc) + timedelta(hours=settings.JWT_EXPIRE_HOURS)
    payload = {
        "sub": str(user_id),
        "role": role,
        "token_version": token_version,
        "exp": int(expires.timestamp())
    }
    return jwt.encode(payload, settings.JWT_SECRET, algorithm=settings.JWT_ALGORITHM)

@router.post("/signup", status_code=status.HTTP_201_CREATED)
async def signup(
    req: SignupRequest,
    request: Request,
    db: AsyncSession = Depends(get_db)
):
    # Enforce role: only trainee or trainer
    if req.role not in ("trainee", "trainer"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Role must be either 'trainee' or 'trainer'"
        )

    # Check existing user
    existing = await db.execute(
        text("SELECT id FROM users WHERE email = :email"),
        {"email": req.email.lower()}
    )
    if existing.first():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="A user with this email already exists"
        )

    pw_hash = hash_password(req.password)
    user_id = uuid.uuid4()

    # Insert user with status = 'pending'
    await db.execute(
        text("""
            INSERT INTO users (id, email, password_hash, full_name, employee_code, designation, department, role, status, token_version, created_at, updated_at)
            VALUES (:id, :email, :pw_hash, :full_name, :employee_code, :designation, :department, :role, 'pending', 0, now(), now())
        """),
        {
            "id": user_id,
            "email": req.email.lower(),
            "pw_hash": pw_hash,
            "full_name": req.full_name,
            "employee_code": req.employee_code,
            "designation": req.designation,
            "department": req.department,
            "role": req.role
        }
    )

    # Initialize empty profile row
    await db.execute(
        text("""
            INSERT INTO profiles (user_id, updated_at)
            VALUES (:user_id, now())
        """),
        {"user_id": user_id}
    )

    # Audit log
    await write_audit_log(
        session=db,
        actor_id=user_id,
        action="user.signup",
        entity_type="user",
        entity_id=str(user_id),
        details={"email": req.email.lower(), "role": req.role},
        ip_address=request.client.host if request.client else None
    )

    await db.commit()

    return {
        "message": "Registration successful. Your account is pending administrator approval.",
        "user_id": str(user_id),
        "status": "pending"
    }

@router.post("/login")
async def login(
    req: LoginRequest,
    response: Response,
    request: Request,
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("""
            SELECT id, email, password_hash, full_name, role, status, token_version,
                   failed_logins, locked_until, employee_code, designation, department,
                   preferred_lang, avatar_file_id, created_at
            FROM users WHERE email = :email
        """),
        {"email": req.email.lower()}
    )
    user = result.mappings().first()

    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password"
        )

    # Check lock out
    now = datetime.now(timezone.utc)
    if user["locked_until"] and user["locked_until"] > now:
        minutes_left = int((user["locked_until"] - now).total_seconds() / 60) + 1
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"Account is locked due to too many failed attempts. Try again in {minutes_left} minutes."
        )

    # Check password
    if not verify_password(req.password, user["password_hash"]):
        failed_count = user["failed_logins"] + 1
        lock_until = None
        if failed_count >= 5:
            lock_until = now + timedelta(minutes=15)

        await db.execute(
            text("""
                UPDATE users 
                SET failed_logins = :failed, locked_until = :locked, updated_at = now()
                WHERE id = :id
            """),
            {"failed": failed_count, "locked": lock_until, "id": user["id"]}
        )
        await write_audit_log(
            session=db,
            actor_id=user["id"],
            action="login.failed",
            entity_type="user",
            entity_id=str(user["id"]),
            details={"failed_logins": failed_count},
            ip_address=request.client.host if request.client else None
        )
        await db.commit()
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password"
        )

    # Check status == 'approved'
    if user["status"] != "approved":
        if user["status"] == "pending":
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Your account is pending administrator approval."
            )
        elif user["status"] == "rejected":
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Your account registration has been rejected."
            )
        elif user["status"] == "suspended":
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Your account has been suspended by an administrator."
            )
        else:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Account is not active."
            )

    # Reset failure counters and record last_login
    await db.execute(
        text("""
            UPDATE users 
            SET failed_logins = 0, locked_until = NULL, last_login_at = now(), updated_at = now()
            WHERE id = :id
        """),
        {"id": user["id"]}
    )
    await write_audit_log(
        session=db,
        actor_id=user["id"],
        action="login.success",
        entity_type="user",
        entity_id=str(user["id"]),
        ip_address=request.client.host if request.client else None
    )
    await db.commit()

    token = create_jwt_token(user["id"], user["role"], user["token_version"])

    # Set httpOnly cookie
    response.set_cookie(
        key=settings.COOKIE_NAME,
        value=token,
        max_age=settings.JWT_EXPIRE_HOURS * 3600,
        httponly=True,
        samesite=settings.COOKIE_SAMESITE,
        secure=settings.COOKIE_SECURE
    )

    return {
        "access_token": token,
        "token_type": "bearer",
        "user": {
            "id": str(user["id"]),
            "email": user["email"],
            "full_name": user["full_name"],
            "role": user["role"],
            "status": user["status"],
            "department": user["department"],
            "designation": user["designation"],
            "employee_code": user["employee_code"],
            "preferred_lang": user["preferred_lang"],
            "token_version": user["token_version"]
        }
    }

@router.post("/logout")
async def logout(response: Response):
    response.delete_cookie(key=settings.COOKIE_NAME)
    return {"message": "Logged out successfully"}

@router.get("/me")
async def get_me(current_user: dict = Depends(get_current_user)):
    return current_user
