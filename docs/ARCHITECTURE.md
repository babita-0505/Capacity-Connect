# CAPACITY CONNECT: System Architecture and Database Design (Lean v2)

**SIH 2026 · PS SIH26075 · Ministry of Earth Sciences (MoES) / India Meteorological Department (IMD) · Theme: Smart Education**

This version is cut down for a hackathon build. The rule is simple: build the differentiators for real, keep the plumbing boring, and put everything else on a roadmap slide.

| File | What it is |
|---|---|
| `architecture.png` / `architecture.html` | Layered system architecture diagram (lean v2) |
| `er_overview.png` | Domain-level ER diagram (25 tables, grouped by module) |
| `er_diagram.png` / `er_diagram.svg` | Full ER diagram with every column, PK/FK marker and data type |
| `schema.sql` | PostgreSQL DDL: 25 tables, 17 enums, indexes, jobs queue function, competency engine function, 8 views, skill taxonomy seed |
| `seed_demo.sql` | Deterministic demo data: 1 admin, 30 trainers, 200 trainees, 26 courses, ~540 test attempts, feedback, certificates |
| `tools/gen_er.py` | Regenerates both ER diagrams from a live database |

---

## 1. What Changed From v1

| Area | v1 (full design) | v2 (hackathon build) |
|---|---|---|
| Services | NestJS API + separate FastAPI AI service | **One FastAPI service**. All AI code is Python, so it runs in the same process |
| Queues | Redis + BullMQ | **`jobs` table** in Postgres, polled by an in-process worker (`FOR UPDATE SKIP LOCKED`) |
| File storage | MinIO / S3 with pre-signed URLs | **Local disk** (`/data/uploads` Docker volume), served by Nginx |
| Video | FFmpeg → HLS, Video.js | **Plain MP4** (re-encoded once with `-movflags +faststart`), native `<video>` |
| Permissions | CASL + roles/permissions tables | **`users.role` column** + hardcoded `requireRole()` / `requireOwner()` |
| Auth | Access + rotating refresh tokens, email OTP, TOTP 2FA | **Access token only** (8–12 h), bcrypt, admin approval, `token_version` revoke |
| Real-time | WebSockets / Socket.IO + Redis adapter | **Polling** every 20 s (`?after_id=`) |
| Certificates | Signed hash + optional blockchain anchor | **Signed hash (HMAC-SHA256) + QR + public verify page** |
| Proctoring | Tab-switch + webcam (MediaPipe) | **Tab-switch, fullscreen-exit and copy-paste counters only** |
| Language / accessibility | Bhashini translation, GIGW / WCAG | **EN / हिन्दी toggle for UI text only** (`next-intl`); the rest goes on the roadmap |
| Competency matching | pgvector embeddings (primary) | **SQL tag + keyword engine (primary)**, embeddings as an optional extra column |
| Database | 38 tables, pgvector, pg_trgm | **25 tables**, plain Postgres + `citext` |
| Ops | Prometheus, Grafana, Loki, Sentry, K8s | `docker compose up`, one VM, nightly `pg_dump` |

Tables removed or merged: `roles`, `permissions`, `role_permissions`, `user_roles`, `refresh_tokens`, `auth_tokens`, `departments` (now a text column), `trainer_profiles` (merged into `profiles`), `user_interests` (merged into `user_skills.kind`), `course_modules` and `module_resources` (now `course_resources.module_title`), `course_trainers` (now `courses.trainer_id`), `course_skills` (now `courses.skill_id` + `tags`), `resource_progress` (now `enrollments.completed_resource_ids`), `assessment_assignees` (derived from enrolments). Added: `jobs`.

---

## 2. Stack

| Layer | Choice | Notes |
|---|---|---|
| Frontend | Next.js, TypeScript, Tailwind, shadcn/ui, TanStack Query, Recharts | 4 charts max + KPI tiles; `next-intl` for EN/HI UI text |
| Backend | FastAPI + SQLAlchemy (or plain `asyncpg`), Pydantic | Auto-generated OpenAPI docs at `/docs` make a good "show the API" moment |
| Auth | PyJWT (HS256), `bcrypt`, `slowapi` or Nginx `limit_req` | Access token in memory + httpOnly cookie; 8–12 h expiry so no one is logged out mid-demo |
| Background work | `asyncio` task started on app startup, polls `claim_next_job()` every 2 s | APScheduler-style timers insert `deadline_reminders` every 15 min and `competency_refresh` nightly |
| AI / ML | `pypdf`, any LLM API with JSON output, optional `sentence-transformers` (`all-MiniLM-L6-v2`) + numpy | Embeddings are optional and stored as `REAL[]`; cosine is computed in Python |
| Database | PostgreSQL 14+ (tested on 18) | Only extension: `citext` |
| Files | Local disk volume, Nginx serves `/uploads` with byte-range support | MIME allow-list + magic-byte check + size cap on upload |
| Certificates | HMAC-SHA256 over canonical JSON, `qrcode` lib, optional PDF (`reportlab` / HTML print) | Verify page recomputes the signature |
| Deploy | Docker Compose: `nginx`, `web`, `api`, `db` | One 4 vCPU / 8 GB VM is plenty |

---

## 3. Backend Modules and Endpoints

All routes sit behind one middleware chain: **verify JWT → check `token_version` → `requireRole(...)` → `requireOwner(...)` where relevant → write `audit_logs` for privileged actions.** Ownership checks, not role checks, are where bugs usually hide: a trainer must only edit their own courses, resources and assessments.

| Module | Key endpoints | Role check | Tables |
|---|---|---|---|
| Auth & Users | `POST /auth/signup`, `POST /auth/login`, `GET /admin/users?status=pending`, `PATCH /admin/users/:id/approve`, `PATCH /admin/users/:id/role` | public / admin | users, audit_logs |
| Profiles | `GET/PUT /me/profile`, `POST /me/qualifications`, `/me/experience`, `/me/skills`, `/me/certificates` | self | profiles, qualifications, work_experiences, user_skills, external_certificates |
| Courses & Library | `GET /courses`, `POST /courses`, `POST /courses/:id/enroll`, `POST /enrollments/:id/complete-resource`, `POST /library/upload` (multipart), `GET /library?skill=` | trainer owns course | courses, learning_resources, course_resources, enrollments, files |
| Assessment engine | `POST /questions`, `POST /assessments`, `POST /assessments/:id/start`, `PUT /attempts/:id/answers`, `POST /attempts/:id/events` (tab-switch etc.), `POST /attempts/:id/submit` | trainer owns / trainee enrolled | questions, question_options, assessments, assessment_questions, attempts, attempt_answers |
| AI MCQ generator | `POST /resources/:id/generate-mcqs` → `202 {job_id}`, `GET /jobs/:id`, `PATCH /questions/:id` (approve / edit) | trainer owns resource | jobs, questions, question_options |
| Feedback | `POST /courses/:id/feedback`, `GET /trainers/:id/feedback` | enrolled trainee | feedback |
| Certificates | `POST /enrollments/:id/certificate`, `GET /verify/:certificateNo` (public) | system / public | certificates |
| Home & notifications | `GET /feed`, `POST /admin/announcements`, `GET /me/notifications?after_id=`, `POST /me/notifications/read` | any / admin | announcements, notifications |
| Dashboards | `GET /admin/kpis`, `/admin/stats/courses`, `/admin/stats/activity`, `/trainer/assessments/:id/stats` | admin / trainer | 8 views |
| Competency mapping | `GET /competency/trainers?skill=`, `GET /competency/trainers/:id/why?skill=`, `GET /competency/gaps`, `GET /competency/heatmap`, `GET /me/learning-path`, `POST /admin/competency/refresh` | admin / trainee (own path) | trainer_competency_scores, views |

---

## 4. Key Flows

**Signup and approval**
1. User signs up with a requested role. `users.status = pending`, no email OTP.
2. Admin sees the pending list, approves (sets `status`, `approved_by`, `approved_at`, optionally changes `role`), which writes an audit log row and an `account_approved` notification.
3. Login checks bcrypt, the lockout counters and `status = approved`, then issues one JWT containing `sub`, `role` and `token_version`. Suspending a user or changing their role bumps `token_version`, which kills old tokens immediately.

**Upload to the trainer library**
1. Trainer uploads through `POST /library/upload` (multipart, streamed to disk).
2. API checks the extension, MIME type and magic bytes, enforces the size cap, computes SHA-256, and saves to `/data/uploads/YYYY/MM/<uuid>.<ext>`.
3. Creates `files` and `learning_resources` rows. Publishing a resource creates a `new_content` announcement.
4. Videos: prepare demo lectures ahead of time with `ffmpeg -i in.mp4 -c copy -movflags +faststart out.mp4` so seeking works instantly. No transcoding pipeline.

**Timed MCQ test with a deadline**
1. Trainer picks approved questions for a subject from the bank, sets `opens_at`, `deadline_at`, `duration_minutes` and opens the test.
2. Worker runs `deadline_reminders` every 15 min and inserts `deadline_24h:<id>` / `deadline_1h:<id>` notifications. The unique `dedupe_key` index means repeats are harmless.
3. `start` creates an attempt with `expires_at`, shuffles questions and returns them **without** `is_correct`.
4. Browser sends `blur`, `fullscreenchange` and `copy` events to `/attempts/:id/events`; the counters are shown to the trainer.
5. `submit` (or the first request after `expires_at`) grades on the server, stores score, percentage and `passed`, and queues `competency_refresh`.

**AI MCQ generation (with fallbacks)**
1. Trainer clicks "Generate questions" on a PDF. The API inserts a `mcq_generate` job with `dedupe_key = 'mcq:<file sha256>:<count>'` and returns `202 {job_id}` straight away.
2. If a finished job already exists for that key, the API returns its result instantly. **Pre-generate the demo PDF so the live demo always hits this cache.**
3. Worker extracts text with `pypdf` (first ~15 pages), asks the LLM for JSON matching a fixed schema (question, 4 options, correct index, explanation, page), validates it with Pydantic and saves the questions as `status = draft`, `generation_method = llm`.
4. If the LLM call fails, times out (30 s) or returns invalid JSON: **rule-based fallback**. Pick sentences containing taxonomy keywords, blank the keyword, and use other keywords from the same PDF as distractors (`generation_method = rule_based`).
5. The frontend polls `GET /jobs/:id` every 2 s and shows a review screen. Nothing reaches trainees until the trainer approves it.

**Course completion and certificate**
1. When all mandatory resources are complete and the course test is passed, the enrolment becomes `completed`.
2. `certificate_issue` job builds a canonical JSON payload (name, course, score, date), stores `sha256` and `HMAC-SHA256(secret, payload)`, and renders a QR code linking to `/verify/IMD-CC-2026-000123`.
3. The public verify page recomputes the signature and shows "Valid", "Revoked" or "Not found".

**Notifications**
- The client polls `GET /me/notifications?after_id=<last id>` every 20 s. `notifications.id` is a `BIGSERIAL`, so the query is a single index range scan.

---

## 5. Competency Mapping Engine

This is the main differentiator, so it is built to work in pure SQL (`refresh_competency_scores()`), with embeddings as an optional upgrade.

| Component | Weight | How it is computed |
|---|---|---|
| Skill match | 0.40 | `tag_match` = 0.55 × taxonomy proficiency (exact skill, or 0.5 × parent/child skill) + 0.25 × teaching evidence (courses taught, resources uploaded) + 0.20 × keyword hits in profile, qualifications, experience and content titles. If `embedding_match` is filled, skill match = average of the two |
| Trainee pass rate | 0.25 | Bayesian-smoothed: (passed + 1) / (attempts + 2), so a new trainer starts at 0.5, not 0 |
| Feedback rating | 0.20 | Smoothed: (sum of ratings + 3 × 2) / (count + 2) / 5 |
| Experience | 0.15 | 0.5 × min(1, total months / 240) + 0.5 × min(1, years in this skill / 10) |

- `total_score` and `skill_match` are generated columns, so the formula lives in exactly one place.
- Evidence columns (`declared_proficiency`, `courses_taught`, `resources_uploaded`, `keyword_hits`, `attempts_count`, `feedback_count`) power a **"Why this trainer?"** panel. Judges like explainable AI.
- `v_skill_gaps` compares supply (best trainer score, number of trainers ≥ 0.60) with demand (interested trainees + trainees averaging below 60%) and flags `critical gap` / `weak coverage` / `covered`.
- `v_skill_heatmap` gives department × skill average test scores for the heatmap chart.
- `v_learning_path` recommends published courses for each trainee's weak subjects.
- Refresh runs nightly and after new results or feedback. On the demo seed it produces 121 trainer-skill scores in well under a second.

**Optional embeddings layer.** A Python job encodes each trainer's text and each skill's description with `all-MiniLM-L6-v2`, computes cosine similarity in numpy, and writes `embedding_match`. A refresh never overwrites it. If embeddings are not ready, the engine still ranks trainers on tag match alone, so the demo does not depend on them.

On the seed data the views show two deliberate gaps: **GIS & Mapping** (no trainer, 63 interested trainees) and **Upper-Air Observations** (one weak trainer, 79 interested). RMC Nagpur and RMC Guwahati score lower on radar and satellite subjects, which shows up on the heatmap.

---

## 6. Database Design

**Engine:** PostgreSQL 14+ (tested on PostgreSQL 18). Only extension: `citext`. `gen_random_uuid()` is built in.

**Conventions:**
- UUID primary keys, except log and notification tables (`BIGSERIAL`)
- `TIMESTAMPTZ` everywhere, `updated_at` kept by triggers
- Enums for every state machine, CHECK constraints for ratings, percentages and dates
- Arrays (`TEXT[]`, `UUID[]`, `REAL[]`) where a join table would add no value for the demo

### Tables (25)

**Identity & Files (2):** `users` (role, status, lockout, `token_version`), `files` (local path, SHA-256)

**Profiles & Competency (7):** `skills` (nested taxonomy, keywords, optional embedding), `profiles` (incl. trainer fields), `qualifications`, `work_experiences`, `user_skills` (skills and interests), `external_certificates`, `trainer_competency_scores`

**Courses & Content (4):** `courses` (lead trainer, primary skill, tags), `learning_resources`, `course_resources` (with module label), `enrollments` (progress array)

**Assessments (6):** `questions` (generation method, source PDF page, source job), `question_options`, `assessments` (deadline, duration, lockdown), `assessment_questions`, `attempts` (proctoring counters), `attempt_answers`

**Feedback, Certificates & Comms (5):** `feedback`, `certificates` (payload, hash, signature), `announcements` (with optional Hindi title), `notifications` (dedupe key), `audit_logs`

**Background Jobs (1):** `jobs` (type, status, payload, result, dedupe key, retries) + `claim_next_job()`

### Views (8)

`v_trainer_recommendations`, `v_skill_gaps`, `v_skill_heatmap`, `v_learning_path`, `v_platform_kpis`, `v_course_stats`, `v_assessment_stats`, `v_monthly_activity`

The four dashboard charts map to: monthly activity (line), course enrolments vs completions (bar), assessment pass rate (bar), skill heatmap (grid). KPI tiles come from `v_platform_kpis`.

### Requirement coverage

| Requirement in the problem statement | Where it lives |
|---|---|
| Secure signup/login, 3 roles | users (bcrypt, role, status, lockout, token_version), middleware |
| Trainee profile: qualifications, experience, interests, skills, certificates | qualifications, work_experiences, user_skills (skill / interest), external_certificates |
| Enrol and access resources | enrollments, course_resources, learning_resources, files |
| Subject-wise MCQ assessments | questions.skill_id, assessments.skill_id, attempts |
| Feedback on courses and content | feedback |
| Trainer questionnaires with deadlines | assessments.type = questionnaire, deadline_at, deadline reminders |
| Monitor participation and performance | attempts, v_assessment_stats, proctoring counters |
| Trainer library of lectures, slides, material | learning_resources.in_library, files |
| Admin approval and role management | users.status / role / approved_by, audit_logs |
| Dashboards | v_platform_kpis, v_course_stats, v_assessment_stats, v_monthly_activity |
| Homepage notifications, announcements, achievements, new content | announcements.type, notifications |
| Competency mapping for trainers | refresh_competency_scores(), v_trainer_recommendations, v_skill_gaps, v_skill_heatmap |
| Scalable, secure, easy to use | Stateless API, indexed views, audit log, clear upgrade path (section 9) |

---

## 7. Build Plan

Plumbing is squeezed into day 1 so competency mapping gets the most iteration time. Adjust the day count to your real schedule, but keep the order.

| Day | Build | Done when |
|---|---|---|
| **1 · Plumbing** | Repo, Docker Compose, schema + seed loaded, signup/login/approval, role + owner middleware, profile forms, course CRUD, upload to disk | Admin approves a new user; a trainer creates a course with an MP4 and a PDF |
| **2 · Competency v1** | Run `refresh_competency_scores()`, ranked trainer list per subject, "Why this trainer?" panel, skill-gap list, heatmap | Admin picks "Doppler Weather Radar" and sees a ranked, explained list; GIS & Mapping shows as a critical gap |
| **3 · MCQ engine** | Question bank, create a test with a deadline, timed attempt, auto-grading, results page, tab-switch counters | A trainee takes a 20-minute test and sees the score; the trainer sees participation |
| **4 · AI MCQ generator** | PDF → job → LLM JSON → draft questions → review screen; rule-based fallback; demo PDF cached | Generation works with the LLM switched off (fallback) and with it on |
| **5 · Dashboards and feed** | 4 charts + KPI tiles, feedback form, homepage feed, polled notifications, certificate + verify page, deadline reminders | Full path from signup to verified certificate works end to end |
| **6 · Competency v2 and polish** | Tune weights on seed data, learning path for trainees, optional embeddings, EN/HI toggle, mobile layout check | Recommendations still work with embeddings switched off |
| **7 · Freeze** | Bug fixes only, demo script rehearsal ×3, backup video, deck | Demo runs from a fresh `docker compose up` on the demo laptop |

---

## 8. Demo Live vs Slides Only

| Demo live | Slides only (roadmap) |
|---|---|
| Signup → admin approval → login as each role | Refresh-token rotation, 2FA |
| Trainer uploads lecture (MP4) and notes (PDF) to the library | HLS streaming + CDN, MinIO / S3 |
| **AI MCQ generator:** PDF → draft questions → trainer approves | Redis job queue and horizontal worker scaling |
| Timed MCQ test with deadline, auto-grading, tab-switch counter | Webcam proctoring (face-api.js / MediaPipe) |
| **Competency mapping:** ranked trainers + "why?" + skill-gap heatmap | Blockchain anchoring of certificate hashes |
| Trainee learning path from weak topics | Bhashini translation of course content |
| Admin dashboard (KPI tiles + 4 charts), homepage feed, notifications | Full GIGW / WCAG 2.1 audit |
| Certificate with QR → public verify page | WebSockets / SSE live alerts |
| EN / हिन्दी UI toggle | Parichay SSO, NIC MeghRaj deployment |

**Suggested 5-minute demo script**
1. Admin: approve a pending trainer (30 s).
2. Trainer: upload the demo PDF, click "Generate questions", approve 5, publish a timed test (90 s).
3. Trainee: take the test, switch tabs once, submit, see the score and a recommended course (60 s).
4. Admin: open competency mapping for "Doppler Weather Radar", open "Why this trainer?", then show the GIS & Mapping gap on the heatmap (90 s).
5. Scan the certificate QR from a phone and show "Valid" (30 s).

---

## 9. Risks and Fallbacks

| Risk | Fallback |
|---|---|
| LLM API slow, down or rate-limited during the demo | Demo PDF result cached by file hash; rule-based fill-in-the-blank generator |
| Embeddings not ready or giving odd rankings | Tag + keyword score is the primary engine; embeddings are only averaged in when present |
| Venue Wi-Fi fails | Everything runs locally in Docker; LLM cache covers MCQs; recorded backup video |
| Video will not seek | Re-encode with `+faststart`; Nginx serves byte ranges |
| Dashboards look empty | `seed_demo.sql` fills every view with realistic, deterministic data |
| Judge asks "why no blockchain?" | Signed hash + public verify page gives the same tamper-evidence without a chain; anchoring is on the roadmap |

**Upgrade path after the hackathon:** move `jobs` to Redis + a worker pool, move files to S3/MinIO, add refresh tokens and 2FA, add SSE for notifications, and switch `REAL[]` embeddings to pgvector. The table layout does not need to change for any of these.

---

## 10. Run It

```bash
createdb capacity_connect
psql -d capacity_connect -f schema.sql
psql -d capacity_connect -f seed_demo.sql      # optional demo data; all passwords: Demo@1234

# try the engine
psql -d capacity_connect -c "SELECT skill, full_name, total_score, rank_in_skill
                             FROM v_trainer_recommendations
                             WHERE skill = 'Doppler Weather Radar' ORDER BY rank_in_skill LIMIT 5;"
psql -d capacity_connect -c "SELECT skill, strong_trainers, demand, gap_status FROM v_skill_gaps ORDER BY best_trainer_score;"
```

Demo logins: `admin@imd.demo`, `trainer01@imd.demo` … `trainer30@imd.demo`, `trainee001@imd.demo` … `trainee200@imd.demo` (193–200 are pending approval).
