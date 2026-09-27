import os
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql+asyncpg://postgres:postgrespassword@localhost:5432/capacity_connect"
    JWT_SECRET: str = "hackathon_jwt_secret_key_sih2026_imd_moes_lean_v2"
    JWT_ALGORITHM: str = "HS256"
    JWT_EXPIRE_HOURS: int = 10
    CERT_HMAC_SECRET: str = "hackathon_cert_hmac_secret_key_sih2026_imd"
    UPLOAD_DIR: str = os.getenv("UPLOAD_DIR", "./data/uploads")
    LLM_PROVIDER: str = "gemini"
    LLM_API_KEY: str = ""
    COOKIE_NAME: str = "cc_token"
    COOKIE_SECURE: bool = False
    COOKIE_SAMESITE: str = "lax"

    model_config = SettingsConfigDict(
        env_file=(".env", "../.env"),
        env_file_encoding="utf-8",
        extra="ignore"
    )

settings = Settings()
