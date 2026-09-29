import uuid
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, status, Query, Request
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import get_current_user, get_current_user_optional, require_role, write_audit_log
from app.schemas.courses import (
    CourseCreate, CourseUpdate, CourseResponse, ResourceCreate, ResourceResponse
)

router = APIRouter(prefix="/courses", tags=["Courses"])

@router.get("/my/enrollments")
async def get_my_enrollments(
    current_user: dict = Depends(require_role("trainee")),
    db: AsyncSession = Depends(get_db)
):
    rows = await db.execute(text("""
        SELECT e.id AS enrollment_id, e.course_id, e.status, e.progress_pct,
               e.completed_resource_ids, e.enrolled_at, e.completed_at, e.last_activity_at,
               c.code, c.title, c.summary, c.level, c.duration_hours, c.issues_certificate,
               s.name AS skill_name, u.full_name AS trainer_name,
               (SELECT cert.certificate_no FROM certificates cert WHERE cert.enrollment_id = e.id) AS certificate_no,
               (SELECT a.id FROM assessments a WHERE a.course_id = c.id AND a.status = 'open' LIMIT 1) AS assessment_id
        FROM enrollments e
        JOIN courses c ON c.id = e.course_id
        LEFT JOIN skills s ON s.id = c.skill_id
        LEFT JOIN users u ON u.id = c.trainer_id
        WHERE e.user_id = :uid
        ORDER BY e.last_activity_at DESC NULLS LAST, e.enrolled_at DESC
    """), {"uid": current_user["id"]})
    return {"items": [dict(r) for r in rows.mappings().all()]}

@router.get("/{course_id}/enrollment")
async def get_course_enrollment(
    course_id: uuid.UUID,
    current_user: dict = Depends(require_role("trainee")),
    db: AsyncSession = Depends(get_db)
):
    row = (await db.execute(text("""
        SELECT e.id, e.course_id, e.status, e.progress_pct, e.completed_resource_ids,
               e.enrolled_at, e.completed_at, e.last_activity_at,
               (SELECT cert.certificate_no FROM certificates cert WHERE cert.enrollment_id = e.id) AS certificate_no,
               (SELECT a.id FROM assessments a WHERE a.course_id = :cid AND a.status = 'open' LIMIT 1) AS assessment_id
        FROM enrollments e
        WHERE e.course_id = :cid AND e.user_id = :uid
    """), {"cid": course_id, "uid": current_user["id"]})).mappings().first()
    if not row:
        return {"enrolled": False, "enrollment": None}
    return {"enrolled": True, "enrollment": dict(row)}

@router.post("/{course_id}/enroll", status_code=status.HTTP_201_CREATED)
async def enroll_course(
    course_id: uuid.UUID,
    current_user: dict = Depends(require_role("trainee")),
    db: AsyncSession = Depends(get_db)
):
    course = (await db.execute(text("SELECT id FROM courses WHERE id=:id AND status='published'"), {"id": course_id})).first()
    if not course:
        raise HTTPException(404, "Published course not found")
    existing = (await db.execute(text("SELECT id FROM enrollments WHERE user_id=:user AND course_id=:course"), {"user": current_user["id"], "course": course_id})).scalar()
    if existing:
        raise HTTPException(409, "You are already enrolled in this course")
    enrollment_id = uuid.uuid4()
    await db.execute(text("INSERT INTO enrollments(id,user_id,course_id,last_activity_at) VALUES(:id,:user,:course,now())"), {"id": enrollment_id, "user": current_user["id"], "course": course_id})
    await db.commit()
    return {"id": enrollment_id, "course_id": course_id, "status": "enrolled", "progress_pct": 0}

@router.post("/enrollments/{enrollment_id}/complete-resource")
async def complete_resource(
    enrollment_id: uuid.UUID,
    resource_id: uuid.UUID,
    current_user: dict = Depends(require_role("trainee")),
    db: AsyncSession = Depends(get_db)
):
    enrollment = (await db.execute(text("SELECT * FROM enrollments WHERE id=:id AND user_id=:user"), {"id": enrollment_id, "user": current_user["id"]})).mappings().first()
    if not enrollment:
        raise HTTPException(404, "Enrollment not found")
    valid = (await db.execute(text("SELECT 1 FROM course_resources WHERE course_id=:course AND resource_id=:resource"), {"course": enrollment["course_id"], "resource": resource_id})).first()
    if not valid:
        raise HTTPException(422, "Resource is not part of this course")
    mandatory = (await db.execute(text("SELECT count(*) FROM course_resources WHERE course_id=:course AND is_mandatory"), {"course": enrollment["course_id"]})).scalar() or 0
    completed = (await db.execute(text("SELECT count(*) FROM course_resources WHERE course_id=:course AND is_mandatory AND resource_id = ANY(:resources)"), {"course": enrollment["course_id"], "resources": list(set((enrollment["completed_resource_ids"] or []) + [resource_id]))})).scalar() or 0
    progress = round(100.0 * completed / mandatory, 2) if mandatory else 100.0

    await db.execute(text("""UPDATE enrollments SET
        completed_resource_ids=CASE WHEN :resource = ANY(completed_resource_ids) THEN completed_resource_ids ELSE array_append(completed_resource_ids,:resource) END,
        progress_pct=:progress, status=CASE WHEN :progress > 0 AND status='enrolled' THEN 'in_progress'::enrollment_status ELSE status END,
        last_activity_at=now() WHERE id=:id"""), {"resource": resource_id, "progress": progress, "id": enrollment_id})

    # Check if completion condition satisfied
    if progress >= 100.0:
        course_test = (await db.execute(text("""
            SELECT id, pass_pct FROM assessments WHERE course_id = :cid AND status = 'open'
        """), {"cid": enrollment["course_id"]})).mappings().first()

        can_complete = True
        if course_test:
            passed_test = (await db.execute(text("""
                SELECT 1 FROM attempts WHERE assessment_id = :aid AND user_id = :uid AND passed = true
            """), {"aid": course_test["id"], "uid": current_user["id"]})).first()
            if not passed_test:
                can_complete = False

        if can_complete:
            await db.execute(text("""
                UPDATE enrollments SET status = 'completed', completed_at = now() WHERE id = :id
            """), {"id": enrollment_id})

            course_row = (await db.execute(text("SELECT issues_certificate FROM courses WHERE id=:id"), {"id": enrollment["course_id"]})).mappings().first()
            if course_row and course_row["issues_certificate"]:
                await db.execute(text("""
                    INSERT INTO jobs(type, payload, dedupe_key)
                    VALUES('certificate_issue', json_build_object('enrollment_id', :eid), :key)
                    ON CONFLICT DO NOTHING
                """), {"eid": str(enrollment_id), "key": f"cert:{enrollment_id}"})

    await db.commit()
    return {"id": enrollment_id, "progress_pct": progress, "completed_resources": completed, "mandatory_resources": mandatory}

@router.get("", response_model=dict)
async def list_courses(
    q: Optional[str] = None,
    skill_id: Optional[int] = None,
    level: Optional[str] = None,
    trainer_id: Optional[uuid.UUID] = None,
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=100),
    current_user: Optional[dict] = Depends(get_current_user_optional),
    db: AsyncSession = Depends(get_db)
):
    offset = (page - 1) * page_size
    params = {"limit": page_size, "offset": offset}
    where_clauses = ["1=1"]

    # Role visibility filter:
    # If unauthenticated or trainee: only published
    # If trainer: published OR owned by trainer
    # If admin: all
    if not current_user or current_user["role"] == "trainee":
        where_clauses.append("c.status = 'published'")
    elif current_user["role"] == "trainer":
        where_clauses.append("(c.status = 'published' OR c.trainer_id = :current_trainer_id)")
        params["current_trainer_id"] = current_user["id"]
    # Admin sees all

    if q:
        where_clauses.append("(c.title ILIKE :q OR c.code ILIKE :q OR c.summary ILIKE :q)")
        params["q"] = f"%{q}%"
    if skill_id:
        where_clauses.append("c.skill_id = :skill_id")
        params["skill_id"] = skill_id
    if level:
        where_clauses.append("c.level = :level")
        params["level"] = level
    if trainer_id:
        where_clauses.append("c.trainer_id = :trainer_id")
        params["trainer_id"] = trainer_id

    where_sql = " AND ".join(where_clauses)

    count_res = await db.execute(
        text(f"SELECT count(*) FROM courses c WHERE {where_sql}"),
        params
    )
    total = count_res.scalar() or 0

    items_res = await db.execute(
        text(f"""
            SELECT c.id, c.code, c.title, c.summary, c.skill_id, c.tags, c.level,
                   c.duration_hours, c.trainer_id, c.thumbnail_file_id, c.status,
                   c.pass_criteria_pct, c.issues_certificate, c.published_at, c.created_at,
                   s.name AS skill_name, u.full_name AS trainer_name
            FROM courses c
            LEFT JOIN skills s ON s.id = c.skill_id
            LEFT JOIN users u ON u.id = c.trainer_id
            WHERE {where_sql}
            ORDER BY c.created_at DESC
            LIMIT :limit OFFSET :offset
        """),
        params
    )
    items = [dict(r) for r in items_res.mappings().all()]

    return {
        "items": items,
        "total": total,
        "page": page,
        "page_size": page_size
    }

@router.get("/{course_id}", response_model=CourseResponse)
async def get_course(
    course_id: uuid.UUID,
    current_user: Optional[dict] = Depends(get_current_user_optional),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("""
            SELECT c.id, c.code, c.title, c.summary, c.skill_id, c.tags, c.level,
                   c.duration_hours, c.trainer_id, c.thumbnail_file_id, c.status,
                   c.pass_criteria_pct, c.issues_certificate, c.published_at, c.created_at,
                   s.name AS skill_name, u.full_name AS trainer_name
            FROM courses c
            LEFT JOIN skills s ON s.id = c.skill_id
            LEFT JOIN users u ON u.id = c.trainer_id
            WHERE c.id = :id
        """),
        {"id": course_id}
    )
    course = result.mappings().first()
    if not course:
        raise HTTPException(status_code=404, detail="Course not found")

    # Access control: If draft, must be trainer owner or admin
    if course["status"] != "published":
        if not current_user:
            raise HTTPException(status_code=404, detail="Course not found")
        if current_user["role"] != "admin" and course["trainer_id"] != current_user["id"]:
            raise HTTPException(status_code=404, detail="Course not found")

    # Load resources
    res_query = await db.execute(
        text("""
            SELECT lr.id, lr.trainer_id, lr.title, lr.description, lr.type,
                   lr.file_id, lr.external_url, lr.duration_seconds, lr.page_count,
                   lr.skill_id, lr.in_library, cr.module_title, cr.position,
                   cr.is_mandatory, lr.created_at, f.storage_path
            FROM course_resources cr
            JOIN learning_resources lr ON lr.id = cr.resource_id
            LEFT JOIN files f ON f.id = lr.file_id
            WHERE cr.course_id = :id
            ORDER BY cr.position ASC
        """),
        {"id": course_id}
    )
    resources = []
    for r in res_query.mappings().all():
        r_dict = dict(r)
        if r_dict.get("storage_path"):
            r_dict["file_path"] = f"/uploads/{r_dict['storage_path']}"
        resources.append(r_dict)

    res_data = dict(course)
    res_data["resources"] = resources
    return res_data

@router.post("", response_model=CourseResponse, status_code=status.HTTP_201_CREATED)
async def create_course(
    req: CourseCreate,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    course_id = uuid.uuid4()
    # Check duplicate code
    existing = await db.execute(
        text("SELECT id FROM courses WHERE code = :code"),
        {"code": req.code}
    )
    if existing.first():
        raise HTTPException(status_code=400, detail=f"Course code '{req.code}' already exists")

    await db.execute(
        text("""
            INSERT INTO courses (id, code, title, summary, skill_id, tags, level, duration_hours,
                                trainer_id, thumbnail_file_id, status, pass_criteria_pct,
                                issues_certificate, created_by, created_at, updated_at)
            VALUES (:id, :code, :title, :summary, :skill_id, :tags, :level, :duration_hours,
                    :trainer_id, :thumb, 'draft', :pass_pct, :cert, :created_by, now(), now())
        """),
        {
            "id": course_id,
            "code": req.code,
            "title": req.title,
            "summary": req.summary,
            "skill_id": req.skill_id,
            "tags": req.tags,
            "level": req.level,
            "duration_hours": req.duration_hours,
            "trainer_id": current_user["id"],
            "thumb": req.thumbnail_file_id,
            "pass_pct": req.pass_criteria_pct,
            "cert": req.issues_certificate,
            "created_by": current_user["id"]
        }
    )
    await db.commit()

    return await get_course(course_id=course_id, current_user=current_user, db=db)

@router.patch("/{course_id}", response_model=CourseResponse)
async def update_course(
    course_id: uuid.UUID,
    req: CourseUpdate,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("SELECT trainer_id FROM courses WHERE id = :id"),
        {"id": course_id}
    )
    course = result.mappings().first()
    if not course:
        raise HTTPException(status_code=404, detail="Course not found")

    # Ownership check: trainer must own the course
    if current_user["role"] != "admin" and course["trainer_id"] != current_user["id"]:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Forbidden: you do not own this course"
        )

    updates = []
    params = {"id": course_id}
    for field, val in req.model_dump(exclude_unset=True).items():
        updates.append(f"{field} = :{field}")
        params[field] = val

    if updates:
        updates.append("updated_at = now()")
        set_sql = ", ".join(updates)
        await db.execute(
            text(f"UPDATE courses SET {set_sql} WHERE id = :id"),
            params
        )
        await db.commit()

    return await get_course(course_id=course_id, current_user=current_user, db=db)

@router.post("/{course_id}/publish", response_model=CourseResponse)
async def publish_course(
    course_id: uuid.UUID,
    request: Request,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("SELECT trainer_id, title FROM courses WHERE id = :id"),
        {"id": course_id}
    )
    course = result.mappings().first()
    if not course:
        raise HTTPException(status_code=404, detail="Course not found")

    # Ownership check
    if current_user["role"] != "admin" and course["trainer_id"] != current_user["id"]:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Forbidden: you do not own this course"
        )

    await db.execute(
        text("""
            UPDATE courses 
            SET status = 'published', published_at = now(), updated_at = now()
            WHERE id = :id
        """),
        {"id": course_id}
    )

    # Insert announcement (type='new_content')
    await db.execute(
        text("""
            INSERT INTO announcements (type, title, body, related_course_id, created_by, publish_at, created_at)
            VALUES ('new_content', :title, 'A new course has been published in the catalogue.', :cid, :uid, now(), now())
        """),
        {
            "title": f"New Course: {course['title']}",
            "cid": course_id,
            "uid": current_user["id"]
        }
    )

    await write_audit_log(
        session=db,
        actor_id=current_user["id"],
        action="course.publish",
        entity_type="course",
        entity_id=str(course_id),
        ip_address=request.client.host if request.client else None
    )
    await db.commit()

    return await get_course(course_id=course_id, current_user=current_user, db=db)

@router.post("/{course_id}/resources", status_code=status.HTTP_201_CREATED)
async def add_course_resource(
    course_id: uuid.UUID,
    req: ResourceCreate,
    current_user: dict = Depends(require_role("trainer", "admin")),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("SELECT trainer_id, skill_id FROM courses WHERE id = :id"),
        {"id": course_id}
    )
    course = result.mappings().first()
    if not course:
        raise HTTPException(status_code=404, detail="Course not found")

    # Ownership check
    if current_user["role"] != "admin" and course["trainer_id"] != current_user["id"]:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Forbidden: you do not own this course"
        )

    res_id = uuid.uuid4()
    # 1. Insert into learning_resources
    await db.execute(
        text("""
            INSERT INTO learning_resources (id, trainer_id, title, description, type, file_id,
                                           external_url, duration_seconds, page_count, skill_id,
                                           in_library, is_published, created_at)
            VALUES (:id, :trainer_id, :title, :desc, :type, :file_id, :ext_url, :duration,
                    :pages, :skill_id, :in_lib, true, now())
        """),
        {
            "id": res_id,
            "trainer_id": current_user["id"],
            "title": req.title,
            "desc": req.description,
            "type": req.type,
            "file_id": req.file_id,
            "ext_url": req.external_url,
            "duration": req.duration_seconds,
            "pages": req.page_count,
            "skill_id": req.skill_id or course["skill_id"],
            "in_lib": req.in_library
        }
    )

    # 2. Insert into course_resources link
    await db.execute(
        text("""
            INSERT INTO course_resources (course_id, resource_id, module_title, position, is_mandatory)
            VALUES (:cid, :rid, :module_title, :position, :is_mandatory)
            ON CONFLICT (course_id, resource_id) DO UPDATE SET
                module_title = EXCLUDED.module_title,
                position = EXCLUDED.position,
                is_mandatory = EXCLUDED.is_mandatory
        """),
        {
            "cid": course_id,
            "rid": res_id,
            "module_title": req.module_title,
            "position": req.position,
            "is_mandatory": req.is_mandatory
        }
    )
    await db.commit()

    return {"message": "Resource added to course", "resource_id": str(res_id)}
