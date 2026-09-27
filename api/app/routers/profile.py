import uuid
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import get_current_user
from app.schemas.profile import (
    ProfileResponse, ProfileUpdate, QualificationCreate, QualificationResponse,
    WorkExperienceCreate, WorkExperienceResponse, UserSkillCreate, UserSkillResponse,
    ExternalCertCreate, ExternalCertResponse, SkillTreeNode, ProfileCompletionResponse
)

router = APIRouter(tags=["Profile"])

async def calculate_profile_completion(user_id: uuid.UUID, db: AsyncSession) -> ProfileCompletionResponse:
    # 1. Profile basics
    p_res = await db.execute(
        text("SELECT headline, bio, location, total_experience_months FROM profiles WHERE user_id = :id"),
        {"id": user_id}
    )
    p_row = p_res.mappings().first()
    has_profile = bool(p_row and (p_row.get("headline") or p_row.get("bio") or p_row.get("location")))

    # 2. Qualifications
    q_res = await db.execute(
        text("SELECT count(*) FROM qualifications WHERE user_id = :id"),
        {"id": user_id}
    )
    has_qual = (q_res.scalar() or 0) > 0

    # 3. Work experience
    w_res = await db.execute(
        text("SELECT count(*) FROM work_experiences WHERE user_id = :id"),
        {"id": user_id}
    )
    has_exp = (w_res.scalar() or 0) > 0

    # 4. User skills
    s_res = await db.execute(
        text("SELECT count(*) FROM user_skills WHERE user_id = :id AND kind = 'skill'"),
        {"id": user_id}
    )
    has_skills = (s_res.scalar() or 0) > 0

    # 5. External certificates
    c_res = await db.execute(
        text("SELECT count(*) FROM external_certificates WHERE user_id = :id"),
        {"id": user_id}
    )
    has_certs = (c_res.scalar() or 0) > 0

    score = 0
    missing = []
    if has_profile:
        score += 20
    else:
        missing.append("Profile Bio & Headline")

    if has_qual:
        score += 20
    else:
        missing.append("Educational Qualifications")

    if has_exp:
        score += 20
    else:
        missing.append("Work Experience")

    if has_skills:
        score += 20
    else:
        missing.append("Skills & Proficiencies")

    if has_certs:
        score += 20
    else:
        missing.append("Certifications")

    return ProfileCompletionResponse(
        completion_pct=score,
        missing_sections=missing,
        has_profile=has_profile,
        has_qualifications=has_qual,
        has_experience=has_exp,
        has_skills=has_skills,
        has_certificates=has_certs
    )

@router.get("/me/profile", response_model=ProfileResponse)
async def get_my_profile(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("SELECT * FROM profiles WHERE user_id = :id"),
        {"id": current_user["id"]}
    )
    row = result.mappings().first()
    if not row:
        # Create empty profile
        await db.execute(
            text("INSERT INTO profiles (user_id, updated_at) VALUES (:id, now()) ON CONFLICT DO NOTHING"),
            {"id": current_user["id"]}
        )
        await db.commit()
        result = await db.execute(
            text("SELECT * FROM profiles WHERE user_id = :id"),
            {"id": current_user["id"]}
        )
        row = result.mappings().first()

    return dict(row)

@router.put("/me/profile", response_model=ProfileResponse)
async def update_my_profile(
    req: ProfileUpdate,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    await db.execute(
        text("""
            INSERT INTO profiles (user_id, headline, bio, date_of_joining, total_experience_months, location, expertise_summary, is_available, updated_at)
            VALUES (:id, :headline, :bio, :date_of_joining, :total_experience_months, :location, :expertise_summary, :is_available, now())
            ON CONFLICT (user_id) DO UPDATE SET
                headline = COALESCE(:headline, profiles.headline),
                bio = COALESCE(:bio, profiles.bio),
                date_of_joining = COALESCE(:date_of_joining, profiles.date_of_joining),
                total_experience_months = COALESCE(:total_experience_months, profiles.total_experience_months),
                location = COALESCE(:location, profiles.location),
                expertise_summary = COALESCE(:expertise_summary, profiles.expertise_summary),
                is_available = COALESCE(:is_available, profiles.is_available),
                updated_at = now()
        """),
        {
            "id": current_user["id"],
            "headline": req.headline,
            "bio": req.bio,
            "date_of_joining": req.date_of_joining,
            "total_experience_months": req.total_experience_months if req.total_experience_months is not None else 0,
            "location": req.location,
            "expertise_summary": req.expertise_summary,
            "is_available": req.is_available if req.is_available is not None else True
        }
    )
    await db.commit()

    result = await db.execute(
        text("SELECT * FROM profiles WHERE user_id = :id"),
        {"id": current_user["id"]}
    )
    return dict(result.mappings().first())

@router.get("/me/profile-completion", response_model=ProfileCompletionResponse)
async def get_profile_completion(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    return await calculate_profile_completion(current_user["id"], db)

# Qualifications CRUD
@router.get("/me/qualifications", response_model=List[QualificationResponse])
async def list_my_qualifications(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("SELECT * FROM qualifications WHERE user_id = :id ORDER BY year_completed DESC NULLS LAST"),
        {"id": current_user["id"]}
    )
    return [dict(r) for r in result.mappings().all()]

@router.post("/me/qualifications", response_model=QualificationResponse, status_code=status.HTTP_201_CREATED)
async def add_my_qualification(
    req: QualificationCreate,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    qual_id = uuid.uuid4()
    await db.execute(
        text("""
            INSERT INTO qualifications (id, user_id, degree, specialization, institution, year_completed, proof_file_id)
            VALUES (:id, :user_id, :degree, :spec, :inst, :year, :proof)
        """),
        {
            "id": qual_id,
            "user_id": current_user["id"],
            "degree": req.degree,
            "spec": req.specialization,
            "inst": req.institution,
            "year": req.year_completed,
            "proof": req.proof_file_id
        }
    )
    await db.commit()
    return QualificationResponse(
        id=qual_id,
        user_id=current_user["id"],
        **req.model_dump()
    )

@router.delete("/me/qualifications/{id}")
async def delete_my_qualification(
    id: uuid.UUID,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("DELETE FROM qualifications WHERE id = :id AND user_id = :user_id RETURNING id"),
        {"id": id, "user_id": current_user["id"]}
    )
    if not result.first():
        raise HTTPException(status_code=404, detail="Qualification not found or unauthorized")
    await db.commit()
    return {"message": "Qualification deleted"}

# Experience CRUD
@router.get("/me/experience", response_model=List[WorkExperienceResponse])
async def list_my_experience(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("SELECT * FROM work_experiences WHERE user_id = :id ORDER BY start_date DESC"),
        {"id": current_user["id"]}
    )
    return [dict(r) for r in result.mappings().all()]

@router.post("/me/experience", response_model=WorkExperienceResponse, status_code=status.HTTP_201_CREATED)
async def add_my_experience(
    req: WorkExperienceCreate,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    exp_id = uuid.uuid4()
    await db.execute(
        text("""
            INSERT INTO work_experiences (id, user_id, organization, designation, start_date, end_date, description)
            VALUES (:id, :user_id, :org, :desig, :start, :end, :desc)
        """),
        {
            "id": exp_id,
            "user_id": current_user["id"],
            "org": req.organization,
            "desig": req.designation,
            "start": req.start_date,
            "end": req.end_date,
            "desc": req.description
        }
    )
    await db.commit()
    return WorkExperienceResponse(
        id=exp_id,
        user_id=current_user["id"],
        **req.model_dump()
    )

@router.delete("/me/experience/{id}")
async def delete_my_experience(
    id: uuid.UUID,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("DELETE FROM work_experiences WHERE id = :id AND user_id = :user_id RETURNING id"),
        {"id": id, "user_id": current_user["id"]}
    )
    if not result.first():
        raise HTTPException(status_code=404, detail="Experience record not found or unauthorized")
    await db.commit()
    return {"message": "Experience record deleted"}

# Skills & Interests CRUD
@router.get("/me/skills", response_model=List[UserSkillResponse])
async def list_my_skills(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("""
            SELECT us.user_id, us.skill_id, us.kind, us.proficiency, us.years, us.source, us.updated_at,
                   s.name AS skill_name
            FROM user_skills us
            JOIN skills s ON s.id = us.skill_id
            WHERE us.user_id = :id
            ORDER BY us.kind, s.name
        """),
        {"id": current_user["id"]}
    )
    return [dict(r) for r in result.mappings().all()]

@router.post("/me/skills", response_model=UserSkillResponse, status_code=status.HTTP_201_CREATED)
async def add_my_skill(
    req: UserSkillCreate,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    if req.kind == "skill" and req.proficiency is None:
        raise HTTPException(status_code=400, detail="Proficiency (1-5) is required for skills")

    # verify skill exists
    s_check = await db.execute(text("SELECT name FROM skills WHERE id = :id"), {"id": req.skill_id})
    s_row = s_check.first()
    if not s_row:
        raise HTTPException(status_code=404, detail="Skill not found in taxonomy")

    await db.execute(
        text("""
            INSERT INTO user_skills (user_id, skill_id, kind, proficiency, years, source, updated_at)
            VALUES (:user_id, :skill_id, :kind, :proficiency, :years, 'self_declared', now())
            ON CONFLICT (user_id, skill_id, kind) DO UPDATE SET
                proficiency = EXCLUDED.proficiency,
                years = EXCLUDED.years,
                updated_at = now()
        """),
        {
            "user_id": current_user["id"],
            "skill_id": req.skill_id,
            "kind": req.kind,
            "proficiency": req.proficiency,
            "years": req.years
        }
    )
    await db.commit()

    return UserSkillResponse(
        user_id=current_user["id"],
        skill_id=req.skill_id,
        skill_name=s_row[0],
        kind=req.kind,
        proficiency=req.proficiency,
        years=req.years,
        source="self_declared",
        updated_at=datetime.now()
    )

@router.delete("/me/skills/{skill_id}")
async def delete_my_skill(
    skill_id: int,
    kind: str = "skill",
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("DELETE FROM user_skills WHERE user_id = :user_id AND skill_id = :skill_id AND kind = :kind RETURNING skill_id"),
        {"user_id": current_user["id"], "skill_id": skill_id, "kind": kind}
    )
    if not result.first():
        raise HTTPException(status_code=404, detail="Skill/interest not found")
    await db.commit()
    return {"message": "Skill removed"}

# External Certificates CRUD
@router.get("/me/certificates", response_model=List[ExternalCertResponse])
async def list_my_certificates(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("SELECT * FROM external_certificates WHERE user_id = :id ORDER BY created_at DESC"),
        {"id": current_user["id"]}
    )
    return [dict(r) for r in result.mappings().all()]

@router.post("/me/certificates", response_model=ExternalCertResponse, status_code=status.HTTP_201_CREATED)
async def add_my_certificate(
    req: ExternalCertCreate,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    cert_id = uuid.uuid4()
    await db.execute(
        text("""
            INSERT INTO external_certificates (id, user_id, title, issuer, issue_date, credential_id, file_id, skill_id, created_at)
            VALUES (:id, :user_id, :title, :issuer, :issue_date, :cred_id, :file_id, :skill_id, now())
        """),
        {
            "id": cert_id,
            "user_id": current_user["id"],
            "title": req.title,
            "issuer": req.issuer,
            "issue_date": req.issue_date,
            "cred_id": req.credential_id,
            "file_id": req.file_id,
            "skill_id": req.skill_id
        }
    )
    await db.commit()
    return ExternalCertResponse(
        id=cert_id,
        user_id=current_user["id"],
        created_at=datetime.now(),
        **req.model_dump()
    )

@router.delete("/me/certificates/{id}")
async def delete_my_certificate(
    id: uuid.UUID,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(
        text("DELETE FROM external_certificates WHERE id = :id AND user_id = :user_id RETURNING id"),
        {"id": id, "user_id": current_user["id"]}
    )
    if not result.first():
        raise HTTPException(status_code=404, detail="Certificate not found or unauthorized")
    await db.commit()
    return {"message": "Certificate deleted"}

# Taxonomy tree
@router.get("/skills", response_model=List[SkillTreeNode])
async def get_skills_tree(db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        text("SELECT id, name, slug, parent_id, description, keywords FROM skills WHERE is_active = true ORDER BY name")
    )
    rows = [dict(r) for r in result.mappings().all()]

    # Build tree
    node_map = {}
    roots = []
    for r in rows:
        node = SkillTreeNode(
            id=r["id"],
            name=r["name"],
            slug=r["slug"],
            parent_id=r["parent_id"],
            description=r["description"],
            keywords=r["keywords"] or [],
            children=[]
        )
        node_map[r["id"]] = node

    for node in node_map.values():
        if node.parent_id and node.parent_id in node_map:
            node_map[node.parent_id].children.append(node)
        else:
            roots.append(node)

    return roots
