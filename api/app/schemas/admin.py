from typing import Optional, Generic, TypeVar, List, Literal
from pydantic import BaseModel, ConfigDict
from datetime import datetime
import uuid

T = TypeVar("T")

class UserAdminResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: str
    full_name: str
    role: str
    status: str
    department: Optional[str] = None
    designation: Optional[str] = None
    employee_code: Optional[str] = None
    token_version: int
    approved_at: Optional[datetime] = None
    rejection_reason: Optional[str] = None
    created_at: datetime

class RejectRequest(BaseModel):
    reason: str

class RoleChangeRequest(BaseModel):
    role: Literal["trainee", "trainer", "admin"]

class PaginatedResponse(BaseModel, Generic[T]):
    items: List[T]
    total: int
    page: int
    page_size: int
