-- =====================================================================
-- CAPACITY CONNECT: Digital Capacity Building & LMS Portal
-- SIH 2026 · PS SIH26075 · MoES / India Meteorological Department
--
-- LEAN HACKATHON EDITION (v2)
--   * 25 tables (was 38). No Redis, no MinIO, no pgvector, no CASL tables.
--   * Plain PostgreSQL 14+ with one contrib extension (citext).
--   * Background work runs from the `jobs` table (polled by an in-process
--     worker using FOR UPDATE SKIP LOCKED), not a queue server.
--   * Competency mapping works in pure SQL (tag + keyword matching).
--     Embedding similarity is an optional add-on column filled by Python.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS citext;     -- case-insensitive email

-- ---------------------------------------------------------------------
-- ENUM TYPES
-- ---------------------------------------------------------------------
CREATE TYPE user_status        AS ENUM ('pending', 'approved', 'rejected', 'suspended');
CREATE TYPE role_name          AS ENUM ('trainee', 'trainer', 'admin');
CREATE TYPE skill_kind         AS ENUM ('skill', 'interest');
CREATE TYPE skill_source       AS ENUM ('self_declared', 'assessment', 'admin_verified', 'course_completion');
CREATE TYPE course_status      AS ENUM ('draft', 'published', 'archived');
CREATE TYPE course_level       AS ENUM ('beginner', 'intermediate', 'advanced');
CREATE TYPE enrollment_status  AS ENUM ('enrolled', 'in_progress', 'completed', 'dropped');
CREATE TYPE resource_type      AS ENUM ('video', 'pdf', 'presentation', 'document', 'link');
CREATE TYPE assessment_type    AS ENUM ('mcq_test', 'questionnaire');
CREATE TYPE assessment_status  AS ENUM ('draft', 'open', 'closed');
CREATE TYPE question_type      AS ENUM ('mcq_single', 'mcq_multi', 'true_false', 'short_text', 'rating');
CREATE TYPE question_status    AS ENUM ('draft', 'approved', 'retired');
CREATE TYPE generation_method  AS ENUM ('manual', 'llm', 'rule_based');
CREATE TYPE attempt_status     AS ENUM ('in_progress', 'submitted', 'auto_submitted');
CREATE TYPE announcement_type  AS ENUM ('notification', 'announcement', 'achievement', 'new_content');
CREATE TYPE job_type           AS ENUM ('mcq_generate', 'competency_refresh', 'deadline_reminders', 'certificate_issue', 'email');
CREATE TYPE job_status         AS ENUM ('pending', 'running', 'done', 'failed');

-- Shared trigger to maintain updated_at
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$ LANGUAGE plpgsql;

-- =====================================================================
-- 1. IDENTITY & FILES  (2 tables)
--    One role per user, stored on the row. Role checks are hardcoded in
--    middleware: requireRole('admin'), requireOwner(resource.trainer_id).
-- =====================================================================
CREATE TABLE users (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email            CITEXT NOT NULL UNIQUE,
    password_hash    TEXT NOT NULL,                  -- bcrypt (cost 12)
    full_name        TEXT NOT NULL,
    employee_code    TEXT UNIQUE,
    designation      TEXT,                           -- e.g. "Scientist-C", "Meteorologist Gr-II"
    department       TEXT,                           -- e.g. "RMC Mumbai", "Satellite Division"
    role             role_name NOT NULL DEFAULT 'trainee',
    status           user_status NOT NULL DEFAULT 'pending',   -- admin approval gate
    token_version    INT NOT NULL DEFAULT 0,          -- bump to invalidate all JWTs (suspend / role change)
    approved_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    approved_at      TIMESTAMPTZ,
    rejection_reason TEXT,
    failed_logins    SMALLINT NOT NULL DEFAULT 0,     -- lock for 15 min after 5 failures
    locked_until     TIMESTAMPTZ,
    last_login_at    TIMESTAMPTZ,
    preferred_lang   TEXT NOT NULL DEFAULT 'en' CHECK (preferred_lang IN ('en', 'hi')),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_users_role_status ON users(role, status);
CREATE TRIGGER trg_users_updated BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE files (                                  -- stored on local disk under UPLOAD_DIR
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id      UUID REFERENCES users(id) ON DELETE SET NULL,
    storage_path  TEXT NOT NULL UNIQUE,              -- relative, e.g. 2026/10/3f2a...e1.mp4
    original_name TEXT NOT NULL,
    mime_type     TEXT NOT NULL,                     -- checked against allow-list + magic bytes
    size_bytes    BIGINT NOT NULL CHECK (size_bytes >= 0),
    sha256        CHAR(64) NOT NULL,                 -- also the cache key for MCQ generation
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_files_sha ON files(sha256);
ALTER TABLE users ADD COLUMN avatar_file_id UUID REFERENCES files(id) ON DELETE SET NULL;

-- =====================================================================
-- 2. PROFILES & COMPETENCY  (7 tables)
-- =====================================================================
CREATE TABLE skills (                                 -- one shared subject taxonomy for the whole platform
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    slug        TEXT NOT NULL UNIQUE,
    parent_id   INT REFERENCES skills(id) ON DELETE SET NULL,  -- Observations > Doppler Weather Radar
    description TEXT,
    keywords    TEXT[] NOT NULL DEFAULT '{}',         -- used by keyword matching (fallback / baseline)
    embedding   REAL[],                               -- OPTIONAL 384-d sentence-transformer vector
    is_active   BOOLEAN NOT NULL DEFAULT true,
    UNIQUE (parent_id, name)
);

CREATE TABLE profiles (                               -- one per user; trainer-only fields are NULL for trainees
    user_id                 UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    headline                TEXT,
    bio                     TEXT,
    date_of_joining         DATE,
    total_experience_months INT NOT NULL DEFAULT 0 CHECK (total_experience_months >= 0),
    location                TEXT,
    expertise_summary       TEXT,                     -- trainer: free-text expertise (keyword + embedding input)
    is_available            BOOLEAN NOT NULL DEFAULT true,   -- trainer: can take new courses
    embedding               REAL[],                   -- OPTIONAL profile vector
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_profiles_updated BEFORE UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE qualifications (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    degree         TEXT NOT NULL,                    -- B.Sc, M.Tech, PhD ...
    specialization TEXT,
    institution    TEXT NOT NULL,
    year_completed SMALLINT CHECK (year_completed BETWEEN 1950 AND 2100),
    proof_file_id  UUID REFERENCES files(id) ON DELETE SET NULL
);
CREATE INDEX idx_qual_user ON qualifications(user_id);

CREATE TABLE work_experiences (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    organization TEXT NOT NULL,
    designation  TEXT NOT NULL,
    start_date   DATE NOT NULL,
    end_date     DATE,                               -- NULL = current
    description  TEXT,
    CHECK (end_date IS NULL OR end_date >= start_date)
);
CREATE INDEX idx_workexp_user ON work_experiences(user_id);

CREATE TABLE user_skills (                            -- skills AND interests (kind column)
    user_id     UUID REFERENCES users(id) ON DELETE CASCADE,
    skill_id    INT  REFERENCES skills(id) ON DELETE CASCADE,
    kind        skill_kind NOT NULL DEFAULT 'skill',
    proficiency SMALLINT CHECK (proficiency BETWEEN 1 AND 5),   -- NULL for interests
    years       NUMERIC(4,1),
    source      skill_source NOT NULL DEFAULT 'self_declared',
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, skill_id, kind),
    CHECK (kind = 'interest' OR proficiency IS NOT NULL)
);
CREATE INDEX idx_user_skills_skill ON user_skills(skill_id, kind);

CREATE TABLE external_certificates (                  -- certificates the user uploads to their profile
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title         TEXT NOT NULL,
    issuer        TEXT NOT NULL,
    issue_date    DATE,
    credential_id TEXT,
    file_id       UUID REFERENCES files(id) ON DELETE SET NULL,
    skill_id      INT REFERENCES skills(id) ON DELETE SET NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE trainer_competency_scores (              -- recomputed by refresh_competency_scores()
    trainer_id         UUID REFERENCES users(id) ON DELETE CASCADE,
    skill_id           INT  REFERENCES skills(id) ON DELETE CASCADE,
    -- explainability: raw evidence shown in the "why this trainer?" panel
    declared_proficiency SMALLINT,
    courses_taught     INT NOT NULL DEFAULT 0,
    resources_uploaded INT NOT NULL DEFAULT 0,
    keyword_hits       INT NOT NULL DEFAULT 0,
    attempts_count     INT NOT NULL DEFAULT 0,
    feedback_count     INT NOT NULL DEFAULT 0,
    -- component scores (0..1)
    tag_match          NUMERIC(5,4) NOT NULL,         -- rule-based: taxonomy + keywords (always available)
    embedding_match    NUMERIC(5,4),                  -- OPTIONAL: cosine similarity from Python, NULL = not used
    pass_rate          NUMERIC(5,4) NOT NULL DEFAULT 0.5,
    rating_score       NUMERIC(5,4) NOT NULL DEFAULT 0.6,
    experience_score   NUMERIC(5,4) NOT NULL DEFAULT 0,
    skill_match        NUMERIC(5,4) GENERATED ALWAYS AS
                       (COALESCE((tag_match + embedding_match) / 2, tag_match)) STORED,
    total_score        NUMERIC(5,4) GENERATED ALWAYS AS
                       (0.40 * COALESCE((tag_match + embedding_match) / 2, tag_match)
                      + 0.25 * pass_rate + 0.20 * rating_score + 0.15 * experience_score) STORED,
    computed_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (trainer_id, skill_id)
);
CREATE INDEX idx_tcs_skill_score ON trainer_competency_scores(skill_id, total_score DESC);

-- =====================================================================
-- 3. COURSES & CONTENT  (4 tables)
--    Modules are a plain text label on course_resources: no module table.
--    Progress is tracked on the enrolment row: no per-resource table.
-- =====================================================================
CREATE TABLE courses (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code                TEXT NOT NULL UNIQUE,         -- e.g. IMD-DWR-101
    title               TEXT NOT NULL,
    summary             TEXT,
    skill_id            INT REFERENCES skills(id) ON DELETE SET NULL,   -- primary subject
    tags                TEXT[] NOT NULL DEFAULT '{}',
    level               course_level NOT NULL DEFAULT 'beginner',
    duration_hours      NUMERIC(5,1),
    trainer_id          UUID REFERENCES users(id) ON DELETE SET NULL,   -- lead trainer (owner)
    thumbnail_file_id   UUID REFERENCES files(id) ON DELETE SET NULL,
    status              course_status NOT NULL DEFAULT 'draft',
    pass_criteria_pct   SMALLINT NOT NULL DEFAULT 60 CHECK (pass_criteria_pct BETWEEN 0 AND 100),
    issues_certificate  BOOLEAN NOT NULL DEFAULT true,
    created_by          UUID NOT NULL REFERENCES users(id),
    published_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_courses_status ON courses(status);
CREATE INDEX idx_courses_trainer ON courses(trainer_id);
CREATE INDEX idx_courses_skill ON courses(skill_id) WHERE status = 'published';
CREATE TRIGGER trg_courses_updated BEFORE UPDATE ON courses FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE learning_resources (                     -- trainer library + course content
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trainer_id        UUID NOT NULL REFERENCES users(id),
    title             TEXT NOT NULL,
    description       TEXT,
    type              resource_type NOT NULL,
    file_id           UUID REFERENCES files(id) ON DELETE SET NULL,  -- MP4 (+faststart) / PDF / PPTX
    external_url      TEXT,
    duration_seconds  INT,
    page_count        INT,
    skill_id          INT REFERENCES skills(id) ON DELETE SET NULL,
    in_library        BOOLEAN NOT NULL DEFAULT true,   -- visible in the shared trainer library
    is_published      BOOLEAN NOT NULL DEFAULT false,
    view_count        INT NOT NULL DEFAULT 0,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (file_id IS NOT NULL OR external_url IS NOT NULL)
);
CREATE INDEX idx_resources_trainer ON learning_resources(trainer_id);
CREATE INDEX idx_resources_library ON learning_resources(skill_id) WHERE in_library AND is_published;

CREATE TABLE course_resources (                       -- a library item can be reused in many courses
    course_id    UUID REFERENCES courses(id) ON DELETE CASCADE,
    resource_id  UUID REFERENCES learning_resources(id) ON DELETE CASCADE,
    module_title TEXT NOT NULL DEFAULT 'Module 1',    -- simple grouping label
    position     SMALLINT NOT NULL,
    is_mandatory BOOLEAN NOT NULL DEFAULT true,
    PRIMARY KEY (course_id, resource_id)
);

CREATE TABLE enrollments (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    course_id              UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    status                 enrollment_status NOT NULL DEFAULT 'enrolled',
    completed_resource_ids UUID[] NOT NULL DEFAULT '{}',  -- progress without a join table
    progress_pct           NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (progress_pct BETWEEN 0 AND 100),
    enrolled_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at           TIMESTAMPTZ,
    last_activity_at       TIMESTAMPTZ,
    UNIQUE (user_id, course_id)
);
CREATE INDEX idx_enroll_course_status ON enrollments(course_id, status);

-- =====================================================================
-- 4. ASSESSMENTS  (6 tables)
--    Assignees = everyone enrolled in assessments.course_id
--    (or all approved trainees for a standalone subject test).
-- =====================================================================
CREATE TABLE questions (                              -- reusable subject-wise question bank
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    skill_id           INT NOT NULL REFERENCES skills(id),
    type               question_type NOT NULL DEFAULT 'mcq_single',
    text               TEXT NOT NULL,
    explanation        TEXT,
    difficulty         SMALLINT NOT NULL DEFAULT 2 CHECK (difficulty BETWEEN 1 AND 5),
    status             question_status NOT NULL DEFAULT 'draft',   -- AI output stays draft until reviewed
    generation_method  generation_method NOT NULL DEFAULT 'manual',
    source_resource_id UUID REFERENCES learning_resources(id) ON DELETE SET NULL,  -- PDF it came from
    source_page        INT,                             -- page the question was drawn from
    source_job_id      UUID,                            -- FK added after jobs
    created_by         UUID NOT NULL REFERENCES users(id),
    reviewed_by        UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_questions_skill ON questions(skill_id, status);

CREATE TABLE question_options (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    question_id UUID NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
    text        TEXT NOT NULL,
    is_correct  BOOLEAN NOT NULL DEFAULT false,       -- never sent to the client before submit
    position    SMALLINT NOT NULL,
    UNIQUE (question_id, position)
);

CREATE TABLE assessments (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title             TEXT NOT NULL,
    instructions      TEXT,
    type              assessment_type NOT NULL DEFAULT 'mcq_test',
    course_id         UUID REFERENCES courses(id) ON DELETE CASCADE,   -- NULL = standalone subject test
    skill_id          INT REFERENCES skills(id) ON DELETE SET NULL,
    created_by        UUID NOT NULL REFERENCES users(id),
    status            assessment_status NOT NULL DEFAULT 'draft',
    opens_at          TIMESTAMPTZ,
    deadline_at       TIMESTAMPTZ,
    duration_minutes  SMALLINT CHECK (duration_minutes > 0),
    pass_pct          SMALLINT NOT NULL DEFAULT 60 CHECK (pass_pct BETWEEN 0 AND 100),
    max_attempts      SMALLINT NOT NULL DEFAULT 1 CHECK (max_attempts > 0),
    shuffle_questions BOOLEAN NOT NULL DEFAULT true,
    show_results      BOOLEAN NOT NULL DEFAULT true,
    lockdown_enabled  BOOLEAN NOT NULL DEFAULT true,   -- tab-switch / fullscreen / copy-paste detection
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (deadline_at IS NULL OR opens_at IS NULL OR deadline_at > opens_at)
);
CREATE INDEX idx_assess_course ON assessments(course_id);
CREATE INDEX idx_assess_deadline ON assessments(deadline_at) WHERE status = 'open';

CREATE TABLE assessment_questions (
    assessment_id UUID REFERENCES assessments(id) ON DELETE CASCADE,
    question_id   UUID REFERENCES questions(id)   ON DELETE RESTRICT,
    position      SMALLINT NOT NULL,
    marks         NUMERIC(5,2) NOT NULL DEFAULT 1,
    PRIMARY KEY (assessment_id, question_id)
);

CREATE TABLE attempts (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assessment_id       UUID NOT NULL REFERENCES assessments(id) ON DELETE CASCADE,
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    attempt_no          SMALLINT NOT NULL DEFAULT 1,
    status              attempt_status NOT NULL DEFAULT 'in_progress',
    started_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at          TIMESTAMPTZ,                   -- started_at + duration; server auto-submits after
    submitted_at        TIMESTAMPTZ,
    score               NUMERIC(6,2),
    max_score           NUMERIC(6,2),
    percentage          NUMERIC(5,2),
    passed              BOOLEAN,
    -- lightweight proctoring signals (browser events only; webcam = future scope)
    tab_switch_count    SMALLINT NOT NULL DEFAULT 0,
    fullscreen_exits    SMALLINT NOT NULL DEFAULT 0,
    copy_paste_attempts SMALLINT NOT NULL DEFAULT 0,
    proctor_events      JSONB NOT NULL DEFAULT '[]',   -- [{t:"2026-..", type:"blur"}]
    UNIQUE (assessment_id, user_id, attempt_no)
);
CREATE INDEX idx_attempts_user ON attempts(user_id);
CREATE INDEX idx_attempts_open ON attempts(expires_at) WHERE status = 'in_progress';

CREATE TABLE attempt_answers (
    attempt_id          UUID REFERENCES attempts(id) ON DELETE CASCADE,
    question_id         UUID REFERENCES questions(id) ON DELETE RESTRICT,
    selected_option_ids UUID[] NOT NULL DEFAULT '{}',
    text_answer         TEXT,                          -- questionnaire / short answer
    rating_value        SMALLINT,
    is_correct          BOOLEAN,
    marks_awarded       NUMERIC(5,2),
    answered_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (attempt_id, question_id)
);

-- =====================================================================
-- 5. FEEDBACK, CERTIFICATES & COMMUNICATION  (5 tables)
-- =====================================================================
CREATE TABLE feedback (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    course_id        UUID REFERENCES courses(id) ON DELETE CASCADE,
    resource_id      UUID REFERENCES learning_resources(id) ON DELETE CASCADE,
    trainer_id       UUID REFERENCES users(id) ON DELETE SET NULL,
    content_rating   SMALLINT CHECK (content_rating BETWEEN 1 AND 5),
    trainer_rating   SMALLINT CHECK (trainer_rating BETWEEN 1 AND 5),
    comment          TEXT,
    is_anonymous     BOOLEAN NOT NULL DEFAULT false,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (course_id IS NOT NULL OR resource_id IS NOT NULL)
);
CREATE UNIQUE INDEX uq_feedback_course ON feedback(user_id, course_id) WHERE course_id IS NOT NULL AND resource_id IS NULL;
CREATE INDEX idx_feedback_trainer ON feedback(trainer_id);

CREATE TABLE certificates (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    certificate_no  TEXT NOT NULL UNIQUE,              -- IMD-CC-2026-000123 (encoded in the QR)
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    course_id       UUID NOT NULL REFERENCES courses(id),
    enrollment_id   UUID UNIQUE REFERENCES enrollments(id) ON DELETE SET NULL,
    final_score_pct NUMERIC(5,2),
    payload         JSONB NOT NULL,                    -- canonical JSON: name, course, date, score
    sha256          CHAR(64) NOT NULL,                 -- hash of canonical payload
    signature       TEXT NOT NULL,                     -- HMAC-SHA256 (or Ed25519) with server secret
    file_id         UUID REFERENCES files(id) ON DELETE SET NULL,   -- optional rendered PDF
    issued_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at      TIMESTAMPTZ,
    revoke_reason   TEXT
);
CREATE INDEX idx_cert_user ON certificates(user_id);

CREATE TABLE announcements (                          -- homepage feed (polled)
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    type              announcement_type NOT NULL,
    title             TEXT NOT NULL,
    title_hi          TEXT,                            -- optional Hindi title for the EN/HI toggle
    body              TEXT,
    link_url          TEXT,
    related_course_id UUID REFERENCES courses(id) ON DELETE SET NULL,
    related_user_id   UUID REFERENCES users(id) ON DELETE SET NULL,   -- for achievements
    audience          role_name,                        -- NULL = everyone
    is_pinned         BOOLEAN NOT NULL DEFAULT false,
    publish_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at        TIMESTAMPTZ,
    created_by        UUID NOT NULL REFERENCES users(id),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_announcements_feed ON announcements(publish_at DESC);

CREATE TABLE notifications (                          -- per-user inbox; client polls ?after_id=
    id         BIGSERIAL PRIMARY KEY,                  -- monotonic id makes polling cheap
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type       TEXT NOT NULL,                         -- 'deadline_24h', 'account_approved', 'mcq_ready' ...
    title      TEXT NOT NULL,
    body       TEXT,
    link       TEXT,
    dedupe_key TEXT,                                  -- e.g. 'deadline_24h:<assessment_id>' (prevents repeat reminders)
    read_at    TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_notif_poll ON notifications(user_id, id DESC);
CREATE UNIQUE INDEX uq_notif_dedupe ON notifications(user_id, dedupe_key) WHERE dedupe_key IS NOT NULL;

CREATE TABLE audit_logs (
    id          BIGSERIAL PRIMARY KEY,
    actor_id    UUID REFERENCES users(id) ON DELETE SET NULL,
    action      TEXT NOT NULL,                        -- 'user.approve', 'course.publish', 'login.failed'
    entity_type TEXT NOT NULL,
    entity_id   TEXT,
    details     JSONB,
    ip_address  INET,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_time ON audit_logs(created_at DESC);

-- =====================================================================
-- 6. BACKGROUND JOBS  (1 table, replaces Redis + BullMQ/Celery)
--    API inserts a row and returns 202 {job_id}. An in-process worker loop
--    calls claim_next_job() every 2 s. Frontend polls GET /jobs/:id.
-- =====================================================================
CREATE TABLE jobs (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    type         job_type NOT NULL,
    status       job_status NOT NULL DEFAULT 'pending',
    payload      JSONB NOT NULL DEFAULT '{}',          -- {resource_id, count, difficulty}
    result       JSONB,                                -- {question_ids:[...], method:"llm"|"rule_based"}
    error        TEXT,
    dedupe_key   TEXT,                                 -- 'mcq:<file sha256>:<count>' -> cached result reuse
    attempts     SMALLINT NOT NULL DEFAULT 0,
    max_attempts SMALLINT NOT NULL DEFAULT 2,
    run_after    TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_at    TIMESTAMPTZ,
    locked_by    TEXT,
    created_by   UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at  TIMESTAMPTZ
);
CREATE INDEX idx_jobs_ready ON jobs(run_after) WHERE status = 'pending';
CREATE UNIQUE INDEX uq_jobs_dedupe ON jobs(type, dedupe_key) WHERE dedupe_key IS NOT NULL AND status <> 'failed';
ALTER TABLE questions ADD CONSTRAINT questions_job_fk FOREIGN KEY (source_job_id) REFERENCES jobs(id) ON DELETE SET NULL;

-- Claim one job atomically. Safe even if two workers run.
CREATE OR REPLACE FUNCTION claim_next_job(p_worker TEXT) RETURNS SETOF jobs AS $$
    UPDATE jobs j SET status = 'running', locked_at = now(), locked_by = p_worker, attempts = j.attempts + 1
    WHERE j.id = (
        SELECT id FROM jobs
        WHERE (status = 'pending' AND run_after <= now())
           OR (status = 'running' AND locked_at < now() - interval '5 minutes'
               AND attempts < max_attempts)                                   -- recover crashed jobs
        ORDER BY run_after
        FOR UPDATE SKIP LOCKED
        LIMIT 1)
    RETURNING j.*;
$$ LANGUAGE sql;

-- =====================================================================
-- 7. COMPETENCY MAPPING ENGINE (pure SQL, rule-based baseline)
--
--   tag_match   = 0.55 * taxonomy proficiency (exact skill, or 0.5 x parent/child)
--               + 0.25 * teaching evidence (courses taught, resources uploaded)
--               + 0.20 * keyword hits in profile, qualifications and content titles
--   pass_rate   = Bayesian-smoothed pass rate of trainees in this trainer's
--                 assessments for this skill: (passed + 1) / (n + 2)
--   rating      = smoothed trainer rating: (sum + 3*2) / (n + 2) / 5
--   experience  = 0.5 * min(1, total months / 240) + 0.5 * min(1, skill years / 10)
--   total       = 0.40 * skill_match + 0.25 * pass_rate + 0.20 * rating + 0.15 * experience
--
--   embedding_match is preserved across refreshes; when present,
--   skill_match = average of tag_match and embedding_match.
-- =====================================================================
CREATE OR REPLACE FUNCTION refresh_competency_scores() RETURNS INT AS $$
DECLARE n INT;
BEGIN
    WITH trainers AS (
        SELECT u.id FROM users u WHERE u.role = 'trainer' AND u.status = 'approved'
    ),
    trainer_text AS (                                   -- everything we know about a trainer, as lowercase text
        SELECT t.id,
               lower(concat_ws(' ', p.headline, p.bio, p.expertise_summary,
                   (SELECT string_agg(concat_ws(' ', q.degree, q.specialization), ' ') FROM qualifications q WHERE q.user_id = t.id),
                   (SELECT string_agg(concat_ws(' ', w.designation, w.description), ' ') FROM work_experiences w WHERE w.user_id = t.id),
                   (SELECT string_agg(concat_ws(' ', c.title, array_to_string(c.tags, ' ')), ' ') FROM courses c WHERE c.trainer_id = t.id),
                   (SELECT string_agg(r.title, ' ') FROM learning_resources r WHERE r.trainer_id = t.id))) AS txt,
               COALESCE(p.total_experience_months, 0) AS exp_months
        FROM trainers t LEFT JOIN profiles p ON p.user_id = t.id
    ),
    pairs AS (
        SELECT tt.id AS trainer_id, s.id AS skill_id, s.parent_id, s.keywords, tt.txt, tt.exp_months
        FROM trainer_text tt CROSS JOIN skills s
        WHERE s.is_active
    ),
    evidence AS (
        SELECT p.trainer_id, p.skill_id, p.exp_months,
            (SELECT us.proficiency FROM user_skills us
               WHERE us.user_id = p.trainer_id AND us.skill_id = p.skill_id AND us.kind = 'skill') AS direct_prof,
            (SELECT max(us.proficiency) FROM user_skills us JOIN skills s2 ON s2.id = us.skill_id
               WHERE us.user_id = p.trainer_id AND us.kind = 'skill'
                 AND (s2.id = p.parent_id OR s2.parent_id = p.skill_id)) AS related_prof,
            (SELECT us.years FROM user_skills us
               WHERE us.user_id = p.trainer_id AND us.skill_id = p.skill_id AND us.kind = 'skill') AS skill_years,
            (SELECT count(*) FROM courses c
               WHERE c.trainer_id = p.trainer_id AND c.skill_id = p.skill_id AND c.status = 'published') AS n_courses,
            (SELECT count(*) FROM learning_resources r
               WHERE r.trainer_id = p.trainer_id AND r.skill_id = p.skill_id AND r.is_published) AS n_resources,
            (SELECT count(*) FROM unnest(p.keywords) k WHERE p.txt LIKE '%' || lower(k) || '%') AS kw_hits,
            (SELECT count(*) FILTER (WHERE a2.passed) FROM attempts a2 JOIN assessments a ON a.id = a2.assessment_id
               LEFT JOIN courses c ON c.id = a.course_id
               WHERE a.skill_id = p.skill_id AND a2.status <> 'in_progress'
                 AND (c.trainer_id = p.trainer_id OR a.created_by = p.trainer_id)) AS n_passed,
            (SELECT count(*) FROM attempts a2 JOIN assessments a ON a.id = a2.assessment_id
               LEFT JOIN courses c ON c.id = a.course_id
               WHERE a.skill_id = p.skill_id AND a2.status <> 'in_progress'
                 AND (c.trainer_id = p.trainer_id OR a.created_by = p.trainer_id)) AS n_attempts,
            (SELECT count(f.trainer_rating) FROM feedback f WHERE f.trainer_id = p.trainer_id) AS n_fb,
            (SELECT COALESCE(sum(f.trainer_rating), 0) FROM feedback f WHERE f.trainer_id = p.trainer_id) AS sum_fb
        FROM pairs p
    ),
    scored AS (
        SELECT e.*,
            LEAST(1.0,
                  0.55 * GREATEST(COALESCE(e.direct_prof, 0) / 5.0, 0.5 * COALESCE(e.related_prof, 0) / 5.0)
                + 0.25 * LEAST(1.0, 0.5 * e.n_courses + 0.25 * e.n_resources)
                + 0.20 * LEAST(1.0, e.kw_hits / 3.0)) AS tag_match
        FROM evidence e
    )
    INSERT INTO trainer_competency_scores AS tcs
        (trainer_id, skill_id, declared_proficiency, courses_taught, resources_uploaded, keyword_hits,
         attempts_count, feedback_count, tag_match, pass_rate, rating_score, experience_score, computed_at)
    SELECT trainer_id, skill_id, direct_prof, n_courses, n_resources, kw_hits,
           n_attempts, n_fb,
           round(tag_match, 4),
           round((n_passed + 1.0) / (n_attempts + 2.0), 4),
           round(((sum_fb + 6.0) / (n_fb + 2.0)) / 5.0, 4),
           round(0.5 * LEAST(1.0, exp_months / 240.0) + 0.5 * LEAST(1.0, COALESCE(skill_years, 0) / 10.0), 4),
           now()
    FROM scored
    WHERE tag_match > 0.10                               -- keep only trainers with real evidence
    ON CONFLICT (trainer_id, skill_id) DO UPDATE SET
        declared_proficiency = EXCLUDED.declared_proficiency,
        courses_taught       = EXCLUDED.courses_taught,
        resources_uploaded   = EXCLUDED.resources_uploaded,
        keyword_hits         = EXCLUDED.keyword_hits,
        attempts_count       = EXCLUDED.attempts_count,
        feedback_count       = EXCLUDED.feedback_count,
        tag_match            = EXCLUDED.tag_match,
        pass_rate            = EXCLUDED.pass_rate,
        rating_score         = EXCLUDED.rating_score,
        experience_score     = EXCLUDED.experience_score,
        computed_at          = EXCLUDED.computed_at;   -- embedding_match intentionally untouched
    GET DIAGNOSTICS n = ROW_COUNT;

    -- remove pairs that no longer have evidence
    DELETE FROM trainer_competency_scores t
    WHERE t.computed_at < now() AND t.embedding_match IS NULL;   -- now() = transaction start
    RETURN n;
END; $$ LANGUAGE plpgsql;

-- =====================================================================
-- 8. VIEWS: competency, learning path, dashboards
-- =====================================================================

-- Ranked trainers per subject, with the evidence for the "why?" tooltip
CREATE VIEW v_trainer_recommendations AS
SELECT s.id AS skill_id, s.name AS skill, u.id AS trainer_id, u.full_name, u.department,
       tcs.total_score, tcs.skill_match, tcs.tag_match, tcs.embedding_match,
       tcs.pass_rate, tcs.rating_score, tcs.experience_score,
       tcs.declared_proficiency, tcs.courses_taught, tcs.resources_uploaded, tcs.keyword_hits,
       RANK() OVER (PARTITION BY s.id ORDER BY tcs.total_score DESC) AS rank_in_skill
FROM trainer_competency_scores tcs
JOIN skills   s ON s.id = tcs.skill_id
JOIN users    u ON u.id = tcs.trainer_id AND u.status = 'approved'
JOIN profiles p ON p.user_id = u.id AND p.is_available;

-- Supply vs demand per skill -> skill-gap list
CREATE VIEW v_skill_gaps AS
WITH supply AS (
    SELECT skill_id, max(total_score) AS best_score,
           count(*) FILTER (WHERE total_score >= 0.60) AS strong_trainers
    FROM trainer_competency_scores GROUP BY skill_id
),
weak AS (                                              -- trainees averaging below 60% in this skill
    SELECT a.skill_id, count(DISTINCT t.user_id) AS weak_trainees
    FROM attempts t JOIN assessments a ON a.id = t.assessment_id
    WHERE t.status <> 'in_progress'
    GROUP BY a.skill_id, t.user_id HAVING avg(t.percentage) < 60
),
weak_agg AS (SELECT skill_id, sum(weak_trainees) AS weak_trainees FROM weak GROUP BY skill_id),
interest AS (
    SELECT skill_id, count(*) AS interested FROM user_skills us JOIN users u ON u.id = us.user_id
    WHERE us.kind = 'interest' AND u.role = 'trainee' GROUP BY skill_id
)
SELECT s.id AS skill_id, s.name AS skill, ps.name AS category,
       COALESCE(sp.best_score, 0)        AS best_trainer_score,
       COALESCE(sp.strong_trainers, 0)   AS strong_trainers,
       COALESCE(i.interested, 0)         AS interested_trainees,
       COALESCE(w.weak_trainees, 0)      AS weak_trainees,
       COALESCE(i.interested, 0) + COALESCE(w.weak_trainees, 0) AS demand,
       CASE WHEN COALESCE(sp.strong_trainers, 0) = 0 AND COALESCE(i.interested, 0) + COALESCE(w.weak_trainees, 0) > 0
                 THEN 'critical gap'
            WHEN COALESCE(sp.best_score, 0) < 0.60 THEN 'weak coverage'
            ELSE 'covered' END AS gap_status
FROM skills s
LEFT JOIN skills ps  ON ps.id = s.parent_id
LEFT JOIN supply sp  ON sp.skill_id = s.id
LEFT JOIN weak_agg w ON w.skill_id = s.id
LEFT JOIN interest i ON i.skill_id = s.id
WHERE s.parent_id IS NOT NULL AND s.is_active;

-- Heatmap: department x skill, average trainee assessment score
CREATE VIEW v_skill_heatmap AS
SELECT u.department, s.name AS skill, ps.name AS category,
       round(avg(t.percentage), 1)   AS avg_pct,
       count(DISTINCT t.user_id)     AS trainees
FROM attempts t
JOIN assessments a ON a.id = t.assessment_id
JOIN skills s      ON s.id = a.skill_id
LEFT JOIN skills ps ON ps.id = s.parent_id
JOIN users u       ON u.id = t.user_id AND u.role = 'trainee'
WHERE t.status <> 'in_progress' AND u.department IS NOT NULL
GROUP BY u.department, s.name, ps.name;

-- Personalised learning path: weak topics -> published courses not yet completed
CREATE VIEW v_learning_path AS
WITH weak AS (
    SELECT t.user_id, a.skill_id, round(avg(t.percentage), 1) AS avg_pct
    FROM attempts t JOIN assessments a ON a.id = t.assessment_id
    WHERE t.status <> 'in_progress' AND a.skill_id IS NOT NULL
    GROUP BY t.user_id, a.skill_id HAVING avg(t.percentage) < 60
)
SELECT w.user_id, w.skill_id, s.name AS weak_skill, w.avg_pct,
       c.id AS course_id, c.code, c.title, c.level
FROM weak w
JOIN skills  s ON s.id = w.skill_id
JOIN courses c ON c.skill_id = w.skill_id AND c.status = 'published'
WHERE NOT EXISTS (SELECT 1 FROM enrollments e
                  WHERE e.user_id = w.user_id AND e.course_id = c.id AND e.status = 'completed');

-- Dashboard chart 1: KPI tiles
CREATE VIEW v_platform_kpis AS
SELECT
  (SELECT count(*) FROM users WHERE status = 'approved')                    AS active_users,
  (SELECT count(*) FROM users WHERE status = 'pending')                     AS pending_approvals,
  (SELECT count(*) FROM courses WHERE status = 'published')                 AS published_courses,
  (SELECT count(*) FROM enrollments)                                        AS total_enrollments,
  (SELECT count(*) FROM certificates WHERE revoked_at IS NULL)              AS certificates_issued,
  (SELECT count(*) FROM attempts WHERE status <> 'in_progress')             AS assessments_taken;

-- Dashboard chart 2: enrolments and completions per course
CREATE VIEW v_course_stats AS
SELECT c.id AS course_id, c.code, c.title, c.trainer_id,
       e.enrollments, e.completions,
       round(100.0 * e.completions / NULLIF(e.enrollments, 0), 1) AS completion_rate_pct,
       (SELECT count(*) FROM certificates ce WHERE ce.course_id = c.id AND ce.revoked_at IS NULL) AS certificates_issued,
       (SELECT round(avg(f.content_rating), 2) FROM feedback f WHERE f.course_id = c.id)         AS avg_content_rating
FROM courses c
CROSS JOIN LATERAL (
    SELECT count(*) AS enrollments, count(*) FILTER (WHERE status = 'completed') AS completions
    FROM enrollments en WHERE en.course_id = c.id) e;

-- Dashboard chart 3: participation and pass rate per assessment
CREATE VIEW v_assessment_stats AS
SELECT a.id AS assessment_id, a.title, a.deadline_at, a.created_by,
       CASE WHEN a.course_id IS NOT NULL
            THEN (SELECT count(*) FROM enrollments e WHERE e.course_id = a.course_id AND e.status <> 'dropped')
            ELSE (SELECT count(*) FROM users u WHERE u.role = 'trainee' AND u.status = 'approved') END AS assigned,
       count(DISTINCT t.user_id) FILTER (WHERE t.status <> 'in_progress') AS submitted,
       round(avg(t.percentage), 1)                                        AS avg_pct,
       round(100.0 * count(*) FILTER (WHERE t.passed)
             / NULLIF(count(*) FILTER (WHERE t.passed IS NOT NULL), 0), 1) AS pass_rate_pct,
       round(avg(t.tab_switch_count), 1)                                  AS avg_tab_switches
FROM assessments a
LEFT JOIN attempts t ON t.assessment_id = a.id
GROUP BY a.id;

-- Dashboard chart 4: monthly activity trend
CREATE VIEW v_monthly_activity AS
SELECT m.month,
       (SELECT count(*) FROM enrollments e WHERE date_trunc('month', e.enrolled_at) = m.month) AS enrollments,
       (SELECT count(*) FROM attempts t WHERE date_trunc('month', t.started_at) = m.month)     AS attempts,
       (SELECT count(*) FROM certificates c WHERE date_trunc('month', c.issued_at) = m.month)  AS certificates
FROM (SELECT generate_series(date_trunc('month', now()) - interval '11 months',
                             date_trunc('month', now()), interval '1 month') AS month) m;

-- =====================================================================
-- 9. REFERENCE SEED: IMD-style skill taxonomy
--    (demo users, courses, attempts and feedback live in seed_demo.sql)
-- =====================================================================
INSERT INTO skills (name, slug, parent_id, keywords) VALUES
 ('Weather Forecasting',        'forecasting',     NULL, '{forecast,forecasting,synoptic}'),
 ('Observations & Instruments', 'observations',    NULL, '{observation,instrument,sensor}'),
 ('Climate Services',           'climate',         NULL, '{climate,climatology}'),
 ('Hydromet & Hazards',         'hazards',         NULL, '{hazard,disaster,warning}'),
 ('Data & IT Skills',           'data-it',         NULL, '{python,data,gis}');

INSERT INTO skills (name, slug, parent_id, keywords)
SELECT v.name, v.slug, p.id, v.keywords::text[] FROM (VALUES
 ('Nowcasting',                   'nowcasting',        'forecasting',  '{nowcast,nowcasting,short-range,convective}'),
 ('NWP Modelling',                'nwp',               'forecasting',  '{nwp,wrf,gfs,numerical weather,ensemble,data assimilation}'),
 ('Tropical Cyclone Forecasting', 'tropical-cyclone',  'forecasting',  '{cyclone,tropical cyclone,storm surge,track}'),
 ('Monsoon Forecasting',          'monsoon',           'forecasting',  '{monsoon,rainfall,southwest monsoon,onset}'),
 ('Doppler Weather Radar',        'dwr',               'observations', '{radar,doppler,dwr,reflectivity}'),
 ('Satellite Meteorology',        'satellite',         'observations', '{satellite,insat,remote sensing,imagery}'),
 ('Automatic Weather Stations',   'aws',               'observations', '{aws,automatic weather station,surface observation}'),
 ('Upper-Air Observations',       'upper-air',         'observations', '{radiosonde,upper air,pilot balloon}'),
 ('Climate Data Analysis',        'climate-data',      'climate',      '{climate data,trend,reanalysis,era5}'),
 ('Agromet Advisory',             'agromet',           'climate',      '{agromet,agriculture,crop,advisory}'),
 ('Flood Meteorology',            'flood-met',         'hazards',      '{flood,hydrology,qpf,river}'),
 ('Heatwave & Cold Wave',         'heatwave',          'hazards',      '{heatwave,heat wave,cold wave,temperature}'),
 ('Thunderstorm & Lightning',     'thunderstorm',      'hazards',      '{thunderstorm,lightning,squall,hail}'),
 ('Python for Meteorology',       'python-met',        'data-it',      '{python,xarray,metpy,netcdf}'),
 ('GIS & Mapping',                'gis',               'data-it',      '{gis,qgis,mapping,shapefile}')
) AS v(name, slug, parent_slug, keywords)
JOIN skills p ON p.slug = v.parent_slug;
