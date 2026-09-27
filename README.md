# CAPACITY CONNECT

**Digital Capacity Building & LMS Portal**  
*Smart India Hackathon 2026 · Problem Statement SIH26075*  
*Ministry of Earth Sciences (MoES) / India Meteorological Department (IMD)*

---

## 1. Quick Start

### Using Docker Compose (Recommended)

```bash
# 1. Clone the repository and navigate to root
cd capacity-connect-kit

# 2. Copy environment file
cp .env.example .env

# 3. Start all services (nginx, web, api, db)
docker compose up --build

# 4. Open the application in your browser:
# Frontend & API Gateway: http://localhost
# Direct API & Swagger Docs: http://localhost:8000/docs
```

To reset the database at any time with clean seed demo data:
```bash
make reset-db
```

---

## 2. Deterministic Demo Logins

All demo accounts use the standard password: **`Demo@1234`**

| Role | Email | Status | Notes |
|---|---|---|---|
| **Admin** | `admin@imd.demo` | Approved | Full management, approvals, competency analytics |
| **Trainer** | `trainer01@imd.demo` | Approved | Scientist-D, Doppler Weather Radar specialist |
| **Trainer** | `trainer02@imd.demo` | Approved | Specialist in Numerical Weather Prediction (NWP) |
| **Trainer** | `trainer03..30@imd.demo` | Approved | Other IMD meteorological disciplines |
| **Trainee** | `trainee001..192@imd.demo` | Approved | Trainees with course progress and test attempts |
| **Trainee** | `trainee193..200@imd.demo` | **Pending** | Pending approval queue for Admin testing |

---

## 3. Architecture Overview (Lean v2)

- **Frontend (`web/`)**: Next.js 14+ (App Router), TypeScript, Tailwind CSS, TanStack Query, Lucide React icons.
- **Backend (`api/`)**: FastAPI (Python 3.11+), Pydantic v2, SQLAlchemy 2 Async / asyncpg, PyJWT (HS256), bcrypt.
- **Database (`db/`)**: PostgreSQL 16+ with `citext` extension. 25 tables, 17 enums, automated jobs table, pure SQL competency scoring (`refresh_competency_scores()`), and 8 analytical views.
- **Reverse Proxy (`nginx/`)**: Nginx routing `/api/*` to FastAPI, `/uploads/*` to local disk with HTTP byte-range video streaming, and all other routes to Next.js.
- **Storage**: Streamed to local disk (`/data/uploads`) with magic-byte validation, MIME allow-listing, and SHA-256 deduplication.

---

## 4. Phase 1 Features

- **Authentication & Security**:
  - Secure bcrypt password hashing.
  - 10-hour JWT access tokens in `httpOnly, SameSite=Lax` cookies.
  - Brute-force protection: 15-minute lock after 5 failed login attempts.
  - Instant token invalidation via `users.token_version` on suspension or role change.
  - Server-side role gating (`trainee`, `trainer`, `admin`) and ownership verification (`require_owner`).
- **User Management & Admin Gate**:
  - New signups default to `pending` status.
  - Admin approval/rejection workflow with audit logging (`audit_logs`) and system notifications.
  - Suspend and activate users.
- **User Profiles**:
  - Profile completion scoring computed on the server.
  - Qualifications, work experience, skill declarations, and external certificates.
  - Shared meteorological skills taxonomy tree (`GET /api/skills`).
- **Course & Learning Resource Management**:
  - Trainers create and edit courses with modules and resources.
  - Multi-file uploads (MP4, PDF, PPTX, DOCX) with magic-byte safety verification.

## 5. Demo walkthrough

The exact seeded-account walkthrough and validation commands are in [docs/DEMO.md](docs/DEMO.md).
  - Trainee course catalogue with search and skill filters.
