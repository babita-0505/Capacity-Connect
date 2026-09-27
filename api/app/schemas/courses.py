from typing import Optional, List, Literal
from pydantic import BaseModel, Field, ConfigDict
from datetime import datetime
import uuid

class ResourceCreate(BaseModel):
    title: str = Field(min_length=2)
    description: Optional[str] = None
    type: Literal["video", "pdf", "presentation", "document", "link"]
    file_id: Optional[uuid.UUID] = None
    external_url: Optional[str] = None
    duration_seconds: Optional[int] = None
    page_count: Optional[int] = None
    skill_id: Optional[int] = None
    in_library: bool = True
    module_title: str = "Module 1"
    position: int = 1
    is_mandatory: bool = True

class ResourceResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    trainer_id: uuid.UUID
    title: str
    description: Optional[str] = None
    type: str
    file_id: Optional[uuid.UUID] = None
    external_url: Optional[str] = None
    duration_seconds: Optional[int] = None
    page_count: Optional[int] = None
    skill_id: Optional[int] = None
    in_library: bool
    module_title: str = "Module 1"
    position: int = 1
    is_mandatory: bool = True
    created_at: datetime
    file_path: Optional[str] = None

class CourseCreate(BaseModel):
    code: str = Field(min_length=3)
    title: str = Field(min_length=3)
    summary: Optional[str] = None
    skill_id: Optional[int] = None
    tags: List[str] = []
    level: Literal["beginner", "intermediate", "advanced"] = "beginner"
    duration_hours: Optional[float] = None
    thumbnail_file_id: Optional[uuid.UUID] = None
    pass_criteria_pct: int = Field(default=60, ge=0, le=100)
    issues_certificate: bool = True

class CourseUpdate(BaseModel):
    title: Optional[str] = None
    summary: Optional[str] = None
    skill_id: Optional[int] = None
    tags: Optional[List[str]] = None
    level: Optional[Literal["beginner", "intermediate", "advanced"]] = None
    duration_hours: Optional[float] = None
    thumbnail_file_id: Optional[uuid.UUID] = None
    pass_criteria_pct: Optional[int] = Field(default=None, ge=0, le=100)
    issues_certificate: Optional[bool] = None

class CourseResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    code: str
    title: str
    summary: Optional[str] = None
    skill_id: Optional[int] = None
    skill_name: Optional[str] = None
    tags: List[str] = []
    level: str
    duration_hours: Optional[float] = None
    trainer_id: Optional[uuid.UUID] = None
    trainer_name: Optional[str] = None
    thumbnail_file_id: Optional[uuid.UUID] = None
    status: str
    pass_criteria_pct: int
    issues_certificate: bool
    published_at: Optional[datetime] = None
    created_at: datetime
    resources: List[ResourceResponse] = []
