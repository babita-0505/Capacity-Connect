from typing import Optional, List, Literal
from pydantic import BaseModel, Field, ConfigDict
from datetime import date, datetime
import uuid

class ProfileUpdate(BaseModel):
    headline: Optional[str] = None
    bio: Optional[str] = None
    date_of_joining: Optional[date] = None
    total_experience_months: Optional[int] = Field(default=0, ge=0)
    location: Optional[str] = None
    expertise_summary: Optional[str] = None
    is_available: Optional[bool] = True

class ProfileResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    user_id: uuid.UUID
    headline: Optional[str] = None
    bio: Optional[str] = None
    date_of_joining: Optional[date] = None
    total_experience_months: int = 0
    location: Optional[str] = None
    expertise_summary: Optional[str] = None
    is_available: bool = True
    updated_at: datetime

class QualificationCreate(BaseModel):
    degree: str
    specialization: Optional[str] = None
    institution: str
    year_completed: Optional[int] = Field(default=None, ge=1950, le=2100)
    proof_file_id: Optional[uuid.UUID] = None

class QualificationResponse(QualificationCreate):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID

class WorkExperienceCreate(BaseModel):
    organization: str
    designation: str
    start_date: date
    end_date: Optional[date] = None
    description: Optional[str] = None

class WorkExperienceResponse(WorkExperienceCreate):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID

class UserSkillCreate(BaseModel):
    skill_id: int
    kind: Literal["skill", "interest"] = "skill"
    proficiency: Optional[int] = Field(default=None, ge=1, le=5)
    years: Optional[float] = Field(default=None, ge=0)

class UserSkillResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    user_id: uuid.UUID
    skill_id: int
    skill_name: Optional[str] = None
    kind: str
    proficiency: Optional[int] = None
    years: Optional[float] = None
    source: str
    updated_at: datetime

class ExternalCertCreate(BaseModel):
    title: str
    issuer: str
    issue_date: Optional[date] = None
    credential_id: Optional[str] = None
    file_id: Optional[uuid.UUID] = None
    skill_id: Optional[int] = None

class ExternalCertResponse(ExternalCertCreate):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    created_at: datetime

class SkillTreeNode(BaseModel):
    id: int
    name: str
    slug: str
    parent_id: Optional[int] = None
    description: Optional[str] = None
    keywords: List[str] = []
    children: List["SkillTreeNode"] = []

class ProfileCompletionResponse(BaseModel):
    completion_pct: int
    missing_sections: List[str]
    has_profile: bool
    has_qualifications: bool
    has_experience: bool
    has_skills: bool
    has_certificates: bool
