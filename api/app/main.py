import os
from contextlib import asynccontextmanager
from fastapi import FastAPI, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app.config import settings
from app.deps import get_current_user
from app.routers import auth, admin, profile, files, courses, competency, assessments, community, generation, dashboard
from app.worker.runner import start_worker, stop_worker

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Ensure upload directory exists
    os.makedirs(settings.UPLOAD_DIR, exist_ok=True)
    # Start background job worker
    start_worker()
    yield
    # Stop background worker
    stop_worker()

app = FastAPI(
    title="CAPACITY CONNECT API",
    description="Digital Capacity Building & LMS Portal for MoES / India Meteorological Department (SIH 2026)",
    version="2.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
    openapi_url="/openapi.json",
    lifespan=lifespan
)

# CORS middleware for Next.js frontend
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost", "http://localhost:3000", "http://127.0.0.1:3000"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include API Routers under /api
app.include_router(auth.router, prefix="/api")
app.include_router(admin.router, prefix="/api")
app.include_router(profile.router, prefix="/api")
app.include_router(files.router, prefix="/api")
app.include_router(courses.router, prefix="/api")
app.include_router(competency.router, prefix="/api")
app.include_router(assessments.router, prefix="/api")
app.include_router(community.router, prefix="/api")
app.include_router(generation.router, prefix="/api")
app.include_router(dashboard.router, prefix="/api")

@app.get("/api/me", tags=["Authentication"])
async def current_user_me(current_user: dict = Depends(get_current_user)):
    """Canonical current-user endpoint used by the browser client."""
    return current_user

# Serve uploads directly in development if Nginx is not proxying
if os.path.exists(settings.UPLOAD_DIR):
    app.mount("/uploads", StaticFiles(directory=settings.UPLOAD_DIR), name="uploads")

@app.get("/api/health", tags=["Health"])
async def health_check():
    return {"status": "ok", "app": "Capacity Connect", "version": "2.0.0"}
