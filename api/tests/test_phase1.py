import io
import uuid
import pytest
from httpx import AsyncClient, ASGITransport
from app.main import app
from app.config import settings
from app.routers.auth import create_jwt_token
from app.deps import get_current_user, get_db

@pytest.fixture
def anyio_backend():
    return "asyncio"

# 1. Signup with role=admin must be rejected
@pytest.mark.asyncio
async def test_signup_admin_rejected():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        res = await client.post("/api/auth/signup", json={
            "email": "intruder_admin@imd.demo",
            "password": "Password123!",
            "full_name": "Intruder",
            "role": "admin"
        })
        assert res.status_code in (400, 422)
        assert "role" in res.text.lower() or "trainee" in res.text.lower()

# 2. Unauthenticated request to /api/admin/users returns 401
@pytest.mark.asyncio
async def test_unauthenticated_cannot_access_admin():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        res = await client.get("/api/admin/users")
        assert res.status_code == 401

# 3. Trainee role cannot access /api/admin/users (403)
@pytest.mark.asyncio
async def test_trainee_cannot_access_admin_routes():
    trainee_id = uuid.uuid4()
    trainee_user = {
        "id": trainee_id,
        "email": "trainee_test@imd.demo",
        "full_name": "Test Trainee",
        "role": "trainee",
        "status": "approved",
        "token_version": 0,
        "department": "RMC Mumbai"
    }

    # Override get_current_user with trainee
    app.dependency_overrides[get_current_user] = lambda: trainee_user
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            res = await client.get("/api/admin/users")
            assert res.status_code == 403
            assert "forbidden" in res.text.lower() or "permission" in res.text.lower()

            # Trainee cannot PATCH role through admin endpoint
            patch_res = await client.patch(f"/api/admin/users/{trainee_id}/role", json={"role": "admin"})
            assert patch_res.status_code == 403
    finally:
        app.dependency_overrides.pop(get_current_user, None)

# 4. Uploading an executable (.exe) renamed to .pdf must be rejected
@pytest.mark.asyncio
async def test_disguised_executable_upload_rejected():
    trainer_id = uuid.uuid4()
    trainer_user = {
        "id": trainer_id,
        "email": "trainer_test@imd.demo",
        "full_name": "Test Trainer",
        "role": "trainer",
        "status": "approved",
        "token_version": 0,
        "department": "Satellite Division"
    }

    app.dependency_overrides[get_current_user] = lambda: trainer_user
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            # File starting with MZ executable magic bytes but named fake.pdf
            fake_exe = b"MZ\x90\x00\x03\x00\x00\x00\x04\x00\x00\x00\xff\xff\x00\x00" + b"\x00" * 128
            files = {"file": ("fake.pdf", io.BytesIO(fake_exe), "application/pdf")}
            res = await client.post("/api/files", files=files)
            assert res.status_code == 400
            assert "executable" in res.text.lower() or "format" in res.text.lower()
    finally:
        app.dependency_overrides.pop(get_current_user, None)

# 5. Course ownership check: Trainer A cannot modify or publish course owned by Trainer B
@pytest.mark.asyncio
async def test_trainer_ownership_check():
    trainer_a_id = uuid.uuid4()
    trainer_b_id = uuid.uuid4()
    course_id = uuid.uuid4()

    trainer_a = {
        "id": trainer_a_id,
        "email": "trainer_a@imd.demo",
        "full_name": "Trainer A",
        "role": "trainer",
        "status": "approved",
        "token_version": 0
    }

    # Mock DB execute returning trainer_b as the course owner
    class MockResult:
        def mappings(self):
            return self
        def first(self):
            return {"trainer_id": trainer_b_id, "title": "Trainer B Course", "id": course_id}

    class MockSession:
        async def execute(self, query, params=None):
            return MockResult()
        async def commit(self):
            pass

    async def override_db():
        yield MockSession()

    app.dependency_overrides[get_current_user] = lambda: trainer_a
    app.dependency_overrides[get_db] = override_db

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            # Trainer A tries to PATCH Trainer B's course
            patch_res = await client.patch(f"/api/courses/{course_id}", json={"title": "Hacked Title"})
            assert patch_res.status_code == 403

            # Trainer A tries to publish Trainer B's course
            pub_res = await client.post(f"/api/courses/{course_id}/publish")
            assert pub_res.status_code == 403
    finally:
        app.dependency_overrides.pop(get_current_user, None)
        app.dependency_overrides.pop(get_db, None)

# 6. Token version invalidation on suspend
@pytest.mark.asyncio
async def test_token_version_invalidation():
    user_id = uuid.uuid4()
    # Token created with token_version = 0
    token = create_jwt_token(user_id, "trainee", token_version=0)

    # When user in database has token_version = 1 (after suspension or role change)
    class MockUserResult:
        def mappings(self):
            return self
        def first(self):
            return {
                "id": user_id,
                "email": "user@imd.demo",
                "full_name": "Test User",
                "role": "trainee",
                "status": "approved",
                "token_version": 1  # version bumped!
            }

    class MockSession:
        async def execute(self, query, params=None):
            return MockUserResult()

    async def override_db():
        yield MockSession()

    app.dependency_overrides[get_db] = override_db
    try:
        headers = {"Authorization": f"Bearer {token}"}
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            res = await client.get("/api/me", headers=headers)
            # Must be rejected because token_version in JWT (0) != DB (1)
            assert res.status_code == 401
    finally:
        app.dependency_overrides.pop(get_db, None)

# 7. Status check: pending user cannot access protected endpoints
@pytest.mark.asyncio
async def test_pending_status_rejected():
    user_id = uuid.uuid4()
    token = create_jwt_token(user_id, "trainee", token_version=0)

    class MockUserResult:
        def mappings(self):
            return self
        def first(self):
            return {
                "id": user_id,
                "email": "pending@imd.demo",
                "full_name": "Pending User",
                "role": "trainee",
                "status": "pending",  # Not approved!
                "token_version": 0
            }

    class MockSession:
        async def execute(self, query, params=None):
            return MockUserResult()

    async def override_db():
        yield MockSession()

    app.dependency_overrides[get_db] = override_db
    try:
        headers = {"Authorization": f"Bearer {token}"}
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            res = await client.get("/api/me", headers=headers)
            assert res.status_code == 401
    finally:
        app.dependency_overrides.pop(get_db, None)
