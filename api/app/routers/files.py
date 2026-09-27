import os
import uuid
import hashlib
from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, status
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_db
from app.deps import get_current_user

router = APIRouter(prefix="/files", tags=["Files"])

# Limits in bytes
MAX_IMAGE_SIZE = 5 * 1024 * 1024       # 5 MB
MAX_DOC_SIZE = 25 * 1024 * 1024        # 25 MB
MAX_VIDEO_SIZE = 500 * 1024 * 1024     # 500 MB

ALLOWED_EXTENSIONS = {
    "jpg": ("image/jpeg", MAX_IMAGE_SIZE),
    "jpeg": ("image/jpeg", MAX_IMAGE_SIZE),
    "png": ("image/png", MAX_IMAGE_SIZE),
    "webp": ("image/webp", MAX_IMAGE_SIZE),
    "pdf": ("application/pdf", MAX_DOC_SIZE),
    "docx": ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", MAX_DOC_SIZE),
    "pptx": ("application/vnd.openxmlformats-officedocument.presentationml.presentation", MAX_DOC_SIZE),
    "mp4": ("video/mp4", MAX_VIDEO_SIZE)
}

def check_magic_bytes(header: bytes, ext: str) -> bool:
    # Reject windows executables immediately
    if header.startswith(b"MZ"):
        return False

    if ext in ("jpg", "jpeg"):
        return header.startswith(b"\xff\xd8\xff")
    elif ext == "png":
        return header.startswith(b"\x89PNG\r\n\x1a\n")
    elif ext == "pdf":
        return header.startswith(b"%PDF")
    elif ext == "mp4":
        return b"ftyp" in header[:20]
    elif ext in ("docx", "pptx"):
        # Zip header (PK\x03\x04)
        return header.startswith(b"PK\x03\x04")
    elif ext == "webp":
        return header.startswith(b"RIFF") and b"WEBP" in header[:16]
    return True

@router.post("", status_code=status.HTTP_201_CREATED)
async def upload_file(
    file: UploadFile = File(...),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    original_name = file.filename or "unknown"
    ext = original_name.split(".")[-1].lower() if "." in original_name else ""

    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported file extension '.{ext}'. Allowed: {', '.join(ALLOWED_EXTENSIONS.keys())}"
        )

    expected_mime, max_size = ALLOWED_EXTENSIONS[ext]

    # Read first 1024 bytes for magic bytes check
    header = await file.read(1024)
    if not check_magic_bytes(header, ext):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="File content does not match expected format or is an executable."
        )

    # Prepare storage directory
    now = datetime.now(timezone.utc)
    rel_dir = os.path.join(now.strftime("%Y"), now.strftime("%m"))
    full_dir = os.path.join(settings.UPLOAD_DIR, rel_dir)
    os.makedirs(full_dir, exist_ok=True)

    file_uuid = uuid.uuid4()
    filename = f"{file_uuid}.{ext}"
    rel_path = os.path.join(rel_dir, filename).replace("\\", "/")
    full_path = os.path.join(full_dir, filename)

    sha256_hash = hashlib.sha256()
    sha256_hash.update(header)
    total_size = len(header)

    with open(full_path, "wb") as out_f:
        out_f.write(header)
        while True:
            chunk = await file.read(1024 * 1024)  # 1 MB chunks
            if not chunk:
                break
            total_size += len(chunk)
            if total_size > max_size:
                out_f.close()
                if os.path.exists(full_path):
                    os.remove(full_path)
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"File exceeds maximum allowed size of {max_size // (1024*1024)} MB"
                )
            sha256_hash.update(chunk)
            out_f.write(chunk)

    file_sha256 = sha256_hash.hexdigest()

    # Save to files table
    await db.execute(
        text("""
            INSERT INTO files (id, owner_id, storage_path, original_name, mime_type, size_bytes, sha256, created_at)
            VALUES (:id, :owner_id, :path, :orig_name, :mime, :size, :sha256, now())
        """),
        {
            "id": file_uuid,
            "owner_id": current_user["id"],
            "path": rel_path,
            "orig_name": original_name,
            "mime": expected_mime,
            "size": total_size,
            "sha256": file_sha256
        }
    )
    await db.commit()

    return {
        "id": str(file_uuid),
        "original_name": original_name,
        "mime_type": expected_mime,
        "size_bytes": total_size,
        "sha256": file_sha256,
        "url": f"/uploads/{rel_path}"
    }
