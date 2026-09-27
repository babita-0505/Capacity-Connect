from typing import Optional, Literal
from pydantic import BaseModel, EmailStr, Field, ConfigDict
from datetime import datetime
import uuid

class SignupRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=6)
    full_name: str = Field(min_length=2)
    role: Literal["trainee", "trainer"] = "trainee"
    employee_code: Optional[str] = None
    designation: Optional[str] = None
    department: Optional[str] = None

class LoginRequest(BaseModel):
    email: EmailStr
    password: str

class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: str
    full_name: str
    role: str
    status: str
    employee_code: Optional[str] = None
    designation: Optional[str] = None
    department: Optional[str] = None
    token_version: int
    preferred_lang: str = "en"
    avatar_file_id: Optional[uuid.UUID] = None
    created_at: datetime

class TokenPayload(BaseModel):
    sub: str
    role: str
    token_version: int
    exp: int
