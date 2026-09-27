from typing import Optional
from pydantic import BaseModel, ConfigDict
from datetime import datetime
import uuid

class FileResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    original_name: str
    mime_type: str
    size_bytes: int
    sha256: str
    url: str
    created_at: datetime
