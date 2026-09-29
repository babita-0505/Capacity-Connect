--
-- PostgreSQL database dump
--

\restrict pQtk7uDkkJHXfiWEcvHN7rFemNhma3bi02JbYhFuX5nYcfhHEREcWznzyqUzq8d

-- Dumped from database version 16.15
-- Dumped by pg_dump version 16.15

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


--
-- Name: announcement_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.announcement_type AS ENUM (
    'notification',
    'announcement',
    'achievement',
    'new_content'
);


ALTER TYPE public.announcement_type OWNER TO postgres;

--
-- Name: assessment_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.assessment_status AS ENUM (
    'draft',
    'open',
    'closed'
);


ALTER TYPE public.assessment_status OWNER TO postgres;

--
-- Name: assessment_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.assessment_type AS ENUM (
    'mcq_test',
    'questionnaire'
);


ALTER TYPE public.assessment_type OWNER TO postgres;

--
-- Name: attempt_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.attempt_status AS ENUM (
    'in_progress',
    'submitted',
    'auto_submitted'
);


ALTER TYPE public.attempt_status OWNER TO postgres;

--
-- Name: course_level; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.course_level AS ENUM (
    'beginner',
    'intermediate',
    'advanced'
);


ALTER TYPE public.course_level OWNER TO postgres;

--
-- Name: course_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.course_status AS ENUM (
    'draft',
    'published',
    'archived'
);


ALTER TYPE public.course_status OWNER TO postgres;

--
-- Name: enrollment_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.enrollment_status AS ENUM (
    'enrolled',
    'in_progress',
    'completed',
    'dropped'
);


ALTER TYPE public.enrollment_status OWNER TO postgres;

--
-- Name: generation_method; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.generation_method AS ENUM (
    'manual',
    'llm',
    'rule_based'
);


ALTER TYPE public.generation_method OWNER TO postgres;

--
-- Name: job_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.job_status AS ENUM (
    'pending',
    'running',
    'done',
    'failed'
);


ALTER TYPE public.job_status OWNER TO postgres;

--
-- Name: job_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.job_type AS ENUM (
    'mcq_generate',
    'competency_refresh',
    'deadline_reminders',
    'certificate_issue',
    'email'
);


ALTER TYPE public.job_type OWNER TO postgres;

--
-- Name: question_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.question_status AS ENUM (
    'draft',
    'approved',
    'retired'
);


ALTER TYPE public.question_status OWNER TO postgres;

--
-- Name: question_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.question_type AS ENUM (
    'mcq_single',
    'mcq_multi',
    'true_false',
    'short_text',
    'rating'
);


ALTER TYPE public.question_type OWNER TO postgres;

--
-- Name: resource_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.resource_type AS ENUM (
    'video',
    'pdf',
    'presentation',
    'document',
    'link'
);


ALTER TYPE public.resource_type OWNER TO postgres;

--
-- Name: role_name; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.role_name AS ENUM (
    'trainee',
    'trainer',
    'admin'
);


ALTER TYPE public.role_name OWNER TO postgres;

--
-- Name: skill_kind; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.skill_kind AS ENUM (
    'skill',
    'interest'
);


ALTER TYPE public.skill_kind OWNER TO postgres;

--
-- Name: skill_source; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.skill_source AS ENUM (
    'self_declared',
    'assessment',
    'admin_verified',
    'course_completion'
);


ALTER TYPE public.skill_source OWNER TO postgres;

--
-- Name: user_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.user_status AS ENUM (
    'pending',
    'approved',
    'rejected',
    'suspended'
);


ALTER TYPE public.user_status OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: jobs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    type public.job_type NOT NULL,
    status public.job_status DEFAULT 'pending'::public.job_status NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    result jsonb,
    error text,
    dedupe_key text,
    attempts smallint DEFAULT 0 NOT NULL,
    max_attempts smallint DEFAULT 2 NOT NULL,
    run_after timestamp with time zone DEFAULT now() NOT NULL,
    locked_at timestamp with time zone,
    locked_by text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone
);


ALTER TABLE public.jobs OWNER TO postgres;

--
-- Name: claim_next_job(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.claim_next_job(p_worker text) RETURNS SETOF public.jobs
    LANGUAGE sql
    AS $$
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
$$;


ALTER FUNCTION public.claim_next_job(p_worker text) OWNER TO postgres;

--
-- Name: refresh_competency_scores(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.refresh_competency_scores() RETURNS integer
    LANGUAGE plpgsql
    AS $$
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
END; $$;


ALTER FUNCTION public.refresh_competency_scores() OWNER TO postgres;

--
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;


ALTER FUNCTION public.set_updated_at() OWNER TO postgres;

--
-- Name: announcements; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.announcements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    type public.announcement_type NOT NULL,
    title text NOT NULL,
    title_hi text,
    body text,
    link_url text,
    related_course_id uuid,
    related_user_id uuid,
    audience public.role_name,
    is_pinned boolean DEFAULT false NOT NULL,
    publish_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone,
    created_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.announcements OWNER TO postgres;

--
-- Name: assessment_questions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.assessment_questions (
    assessment_id uuid NOT NULL,
    question_id uuid NOT NULL,
    "position" smallint NOT NULL,
    marks numeric(5,2) DEFAULT 1 NOT NULL
);


ALTER TABLE public.assessment_questions OWNER TO postgres;

--
-- Name: assessments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.assessments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text NOT NULL,
    instructions text,
    type public.assessment_type DEFAULT 'mcq_test'::public.assessment_type NOT NULL,
    course_id uuid,
    skill_id integer,
    created_by uuid NOT NULL,
    status public.assessment_status DEFAULT 'draft'::public.assessment_status NOT NULL,
    opens_at timestamp with time zone,
    deadline_at timestamp with time zone,
    duration_minutes smallint,
    pass_pct smallint DEFAULT 60 NOT NULL,
    max_attempts smallint DEFAULT 1 NOT NULL,
    shuffle_questions boolean DEFAULT true NOT NULL,
    show_results boolean DEFAULT true NOT NULL,
    lockdown_enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT assessments_check CHECK (((deadline_at IS NULL) OR (opens_at IS NULL) OR (deadline_at > opens_at))),
    CONSTRAINT assessments_duration_minutes_check CHECK ((duration_minutes > 0)),
    CONSTRAINT assessments_max_attempts_check CHECK ((max_attempts > 0)),
    CONSTRAINT assessments_pass_pct_check CHECK (((pass_pct >= 0) AND (pass_pct <= 100)))
);


ALTER TABLE public.assessments OWNER TO postgres;

--
-- Name: attempt_answers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.attempt_answers (
    attempt_id uuid NOT NULL,
    question_id uuid NOT NULL,
    selected_option_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    text_answer text,
    rating_value smallint,
    is_correct boolean,
    marks_awarded numeric(5,2),
    answered_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.attempt_answers OWNER TO postgres;

--
-- Name: attempts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    assessment_id uuid NOT NULL,
    user_id uuid NOT NULL,
    attempt_no smallint DEFAULT 1 NOT NULL,
    status public.attempt_status DEFAULT 'in_progress'::public.attempt_status NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone,
    submitted_at timestamp with time zone,
    score numeric(6,2),
    max_score numeric(6,2),
    percentage numeric(5,2),
    passed boolean,
    tab_switch_count smallint DEFAULT 0 NOT NULL,
    fullscreen_exits smallint DEFAULT 0 NOT NULL,
    copy_paste_attempts smallint DEFAULT 0 NOT NULL,
    proctor_events jsonb DEFAULT '[]'::jsonb NOT NULL
);


ALTER TABLE public.attempts OWNER TO postgres;

--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.audit_logs (
    id bigint NOT NULL,
    actor_id uuid,
    action text NOT NULL,
    entity_type text NOT NULL,
    entity_id text,
    details jsonb,
    ip_address inet,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.audit_logs OWNER TO postgres;

--
-- Name: audit_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.audit_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.audit_logs_id_seq OWNER TO postgres;

--
-- Name: audit_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.audit_logs_id_seq OWNED BY public.audit_logs.id;


--
-- Name: certificates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.certificates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    certificate_no text NOT NULL,
    user_id uuid NOT NULL,
    course_id uuid NOT NULL,
    enrollment_id uuid,
    final_score_pct numeric(5,2),
    payload jsonb NOT NULL,
    sha256 character(64) NOT NULL,
    signature text NOT NULL,
    file_id uuid,
    issued_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    revoke_reason text
);


ALTER TABLE public.certificates OWNER TO postgres;

--
-- Name: course_resources; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.course_resources (
    course_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    module_title text DEFAULT 'Module 1'::text NOT NULL,
    "position" smallint NOT NULL,
    is_mandatory boolean DEFAULT true NOT NULL
);


ALTER TABLE public.course_resources OWNER TO postgres;

--
-- Name: courses; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.courses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    title text NOT NULL,
    summary text,
    skill_id integer,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    level public.course_level DEFAULT 'beginner'::public.course_level NOT NULL,
    duration_hours numeric(5,1),
    trainer_id uuid,
    thumbnail_file_id uuid,
    status public.course_status DEFAULT 'draft'::public.course_status NOT NULL,
    pass_criteria_pct smallint DEFAULT 60 NOT NULL,
    issues_certificate boolean DEFAULT true NOT NULL,
    created_by uuid NOT NULL,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT courses_pass_criteria_pct_check CHECK (((pass_criteria_pct >= 0) AND (pass_criteria_pct <= 100)))
);


ALTER TABLE public.courses OWNER TO postgres;

--
-- Name: enrollments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.enrollments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    course_id uuid NOT NULL,
    status public.enrollment_status DEFAULT 'enrolled'::public.enrollment_status NOT NULL,
    completed_resource_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    progress_pct numeric(5,2) DEFAULT 0 NOT NULL,
    enrolled_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    last_activity_at timestamp with time zone,
    CONSTRAINT enrollments_progress_pct_check CHECK (((progress_pct >= (0)::numeric) AND (progress_pct <= (100)::numeric)))
);


ALTER TABLE public.enrollments OWNER TO postgres;

--
-- Name: external_certificates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.external_certificates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    title text NOT NULL,
    issuer text NOT NULL,
    issue_date date,
    credential_id text,
    file_id uuid,
    skill_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.external_certificates OWNER TO postgres;

--
-- Name: feedback; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.feedback (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    course_id uuid,
    resource_id uuid,
    trainer_id uuid,
    content_rating smallint,
    trainer_rating smallint,
    comment text,
    is_anonymous boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT feedback_check CHECK (((course_id IS NOT NULL) OR (resource_id IS NOT NULL))),
    CONSTRAINT feedback_content_rating_check CHECK (((content_rating >= 1) AND (content_rating <= 5))),
    CONSTRAINT feedback_trainer_rating_check CHECK (((trainer_rating >= 1) AND (trainer_rating <= 5)))
);


ALTER TABLE public.feedback OWNER TO postgres;

--
-- Name: files; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.files (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    owner_id uuid,
    storage_path text NOT NULL,
    original_name text NOT NULL,
    mime_type text NOT NULL,
    size_bytes bigint NOT NULL,
    sha256 character(64) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT files_size_bytes_check CHECK ((size_bytes >= 0))
);


ALTER TABLE public.files OWNER TO postgres;

--
-- Name: learning_resources; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.learning_resources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    trainer_id uuid NOT NULL,
    title text NOT NULL,
    description text,
    type public.resource_type NOT NULL,
    file_id uuid,
    external_url text,
    duration_seconds integer,
    page_count integer,
    skill_id integer,
    in_library boolean DEFAULT true NOT NULL,
    is_published boolean DEFAULT false NOT NULL,
    view_count integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT learning_resources_check CHECK (((file_id IS NOT NULL) OR (external_url IS NOT NULL)))
);


ALTER TABLE public.learning_resources OWNER TO postgres;

--
-- Name: notifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notifications (
    id bigint NOT NULL,
    user_id uuid NOT NULL,
    type text NOT NULL,
    title text NOT NULL,
    body text,
    link text,
    dedupe_key text,
    read_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.notifications OWNER TO postgres;

--
-- Name: notifications_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.notifications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.notifications_id_seq OWNER TO postgres;

--
-- Name: notifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.notifications_id_seq OWNED BY public.notifications.id;


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.profiles (
    user_id uuid NOT NULL,
    headline text,
    bio text,
    date_of_joining date,
    total_experience_months integer DEFAULT 0 NOT NULL,
    location text,
    expertise_summary text,
    is_available boolean DEFAULT true NOT NULL,
    embedding real[],
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT profiles_total_experience_months_check CHECK ((total_experience_months >= 0))
);


ALTER TABLE public.profiles OWNER TO postgres;

--
-- Name: qualifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.qualifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    degree text NOT NULL,
    specialization text,
    institution text NOT NULL,
    year_completed smallint,
    proof_file_id uuid,
    CONSTRAINT qualifications_year_completed_check CHECK (((year_completed >= 1950) AND (year_completed <= 2100)))
);


ALTER TABLE public.qualifications OWNER TO postgres;

--
-- Name: question_options; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.question_options (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    question_id uuid NOT NULL,
    text text NOT NULL,
    is_correct boolean DEFAULT false NOT NULL,
    "position" smallint NOT NULL
);


ALTER TABLE public.question_options OWNER TO postgres;

--
-- Name: questions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.questions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    skill_id integer NOT NULL,
    type public.question_type DEFAULT 'mcq_single'::public.question_type NOT NULL,
    text text NOT NULL,
    explanation text,
    difficulty smallint DEFAULT 2 NOT NULL,
    status public.question_status DEFAULT 'draft'::public.question_status NOT NULL,
    generation_method public.generation_method DEFAULT 'manual'::public.generation_method NOT NULL,
    source_resource_id uuid,
    source_page integer,
    source_job_id uuid,
    created_by uuid NOT NULL,
    reviewed_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT questions_difficulty_check CHECK (((difficulty >= 1) AND (difficulty <= 5)))
);


ALTER TABLE public.questions OWNER TO postgres;

--
-- Name: skills; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.skills (
    id integer NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    parent_id integer,
    description text,
    keywords text[] DEFAULT '{}'::text[] NOT NULL,
    embedding real[],
    is_active boolean DEFAULT true NOT NULL
);


ALTER TABLE public.skills OWNER TO postgres;

--
-- Name: skills_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.skills_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.skills_id_seq OWNER TO postgres;

--
-- Name: skills_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.skills_id_seq OWNED BY public.skills.id;


--
-- Name: trainer_competency_scores; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.trainer_competency_scores (
    trainer_id uuid NOT NULL,
    skill_id integer NOT NULL,
    declared_proficiency smallint,
    courses_taught integer DEFAULT 0 NOT NULL,
    resources_uploaded integer DEFAULT 0 NOT NULL,
    keyword_hits integer DEFAULT 0 NOT NULL,
    attempts_count integer DEFAULT 0 NOT NULL,
    feedback_count integer DEFAULT 0 NOT NULL,
    tag_match numeric(5,4) NOT NULL,
    embedding_match numeric(5,4),
    pass_rate numeric(5,4) DEFAULT 0.5 NOT NULL,
    rating_score numeric(5,4) DEFAULT 0.6 NOT NULL,
    experience_score numeric(5,4) DEFAULT 0 NOT NULL,
    skill_match numeric(5,4) GENERATED ALWAYS AS (COALESCE(((tag_match + embedding_match) / (2)::numeric), tag_match)) STORED,
    total_score numeric(5,4) GENERATED ALWAYS AS (((((0.40 * COALESCE(((tag_match + embedding_match) / (2)::numeric), tag_match)) + (0.25 * pass_rate)) + (0.20 * rating_score)) + (0.15 * experience_score))) STORED,
    computed_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.trainer_competency_scores OWNER TO postgres;

--
-- Name: user_skills; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_skills (
    user_id uuid NOT NULL,
    skill_id integer NOT NULL,
    kind public.skill_kind DEFAULT 'skill'::public.skill_kind NOT NULL,
    proficiency smallint,
    years numeric(4,1),
    source public.skill_source DEFAULT 'self_declared'::public.skill_source NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_skills_check CHECK (((kind = 'interest'::public.skill_kind) OR (proficiency IS NOT NULL))),
    CONSTRAINT user_skills_proficiency_check CHECK (((proficiency >= 1) AND (proficiency <= 5)))
);


ALTER TABLE public.user_skills OWNER TO postgres;

--
-- Name: users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email public.citext NOT NULL,
    password_hash text NOT NULL,
    full_name text NOT NULL,
    employee_code text,
    designation text,
    department text,
    role public.role_name DEFAULT 'trainee'::public.role_name NOT NULL,
    status public.user_status DEFAULT 'pending'::public.user_status NOT NULL,
    token_version integer DEFAULT 0 NOT NULL,
    approved_by uuid,
    approved_at timestamp with time zone,
    rejection_reason text,
    failed_logins smallint DEFAULT 0 NOT NULL,
    locked_until timestamp with time zone,
    last_login_at timestamp with time zone,
    preferred_lang text DEFAULT 'en'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    avatar_file_id uuid,
    CONSTRAINT users_preferred_lang_check CHECK ((preferred_lang = ANY (ARRAY['en'::text, 'hi'::text])))
);


ALTER TABLE public.users OWNER TO postgres;

--
-- Name: v_assessment_stats; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_assessment_stats AS
SELECT
    NULL::uuid AS assessment_id,
    NULL::text AS title,
    NULL::timestamp with time zone AS deadline_at,
    NULL::uuid AS created_by,
    NULL::bigint AS assigned,
    NULL::bigint AS submitted,
    NULL::numeric AS avg_pct,
    NULL::numeric AS pass_rate_pct,
    NULL::numeric AS avg_tab_switches;


ALTER VIEW public.v_assessment_stats OWNER TO postgres;

--
-- Name: v_course_stats; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_course_stats AS
 SELECT c.id AS course_id,
    c.code,
    c.title,
    c.trainer_id,
    e.enrollments,
    e.completions,
    round(((100.0 * (e.completions)::numeric) / (NULLIF(e.enrollments, 0))::numeric), 1) AS completion_rate_pct,
    ( SELECT count(*) AS count
           FROM public.certificates ce
          WHERE ((ce.course_id = c.id) AND (ce.revoked_at IS NULL))) AS certificates_issued,
    ( SELECT round(avg(f.content_rating), 2) AS round
           FROM public.feedback f
          WHERE (f.course_id = c.id)) AS avg_content_rating
   FROM (public.courses c
     CROSS JOIN LATERAL ( SELECT count(*) AS enrollments,
            count(*) FILTER (WHERE (en.status = 'completed'::public.enrollment_status)) AS completions
           FROM public.enrollments en
          WHERE (en.course_id = c.id)) e);


ALTER VIEW public.v_course_stats OWNER TO postgres;

--
-- Name: v_learning_path; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_learning_path AS
 WITH weak AS (
         SELECT t.user_id,
            a.skill_id,
            round(avg(t.percentage), 1) AS avg_pct
           FROM (public.attempts t
             JOIN public.assessments a ON ((a.id = t.assessment_id)))
          WHERE ((t.status <> 'in_progress'::public.attempt_status) AND (a.skill_id IS NOT NULL))
          GROUP BY t.user_id, a.skill_id
         HAVING (avg(t.percentage) < (60)::numeric)
        )
 SELECT w.user_id,
    w.skill_id,
    s.name AS weak_skill,
    w.avg_pct,
    c.id AS course_id,
    c.code,
    c.title,
    c.level
   FROM ((weak w
     JOIN public.skills s ON ((s.id = w.skill_id)))
     JOIN public.courses c ON (((c.skill_id = w.skill_id) AND (c.status = 'published'::public.course_status))))
  WHERE (NOT (EXISTS ( SELECT 1
           FROM public.enrollments e
          WHERE ((e.user_id = w.user_id) AND (e.course_id = c.id) AND (e.status = 'completed'::public.enrollment_status)))));


ALTER VIEW public.v_learning_path OWNER TO postgres;

--
-- Name: v_monthly_activity; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_monthly_activity AS
 SELECT month,
    ( SELECT count(*) AS count
           FROM public.enrollments e
          WHERE (date_trunc('month'::text, e.enrolled_at) = m.month)) AS enrollments,
    ( SELECT count(*) AS count
           FROM public.attempts t
          WHERE (date_trunc('month'::text, t.started_at) = m.month)) AS attempts,
    ( SELECT count(*) AS count
           FROM public.certificates c
          WHERE (date_trunc('month'::text, c.issued_at) = m.month)) AS certificates
   FROM ( SELECT generate_series((date_trunc('month'::text, now()) - '11 mons'::interval), date_trunc('month'::text, now()), '1 mon'::interval) AS month) m;


ALTER VIEW public.v_monthly_activity OWNER TO postgres;

--
-- Name: v_platform_kpis; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_platform_kpis AS
 SELECT ( SELECT count(*) AS count
           FROM public.users
          WHERE (users.status = 'approved'::public.user_status)) AS active_users,
    ( SELECT count(*) AS count
           FROM public.users
          WHERE (users.status = 'pending'::public.user_status)) AS pending_approvals,
    ( SELECT count(*) AS count
           FROM public.courses
          WHERE (courses.status = 'published'::public.course_status)) AS published_courses,
    ( SELECT count(*) AS count
           FROM public.enrollments) AS total_enrollments,
    ( SELECT count(*) AS count
           FROM public.certificates
          WHERE (certificates.revoked_at IS NULL)) AS certificates_issued,
    ( SELECT count(*) AS count
           FROM public.attempts
          WHERE (attempts.status <> 'in_progress'::public.attempt_status)) AS assessments_taken;


ALTER VIEW public.v_platform_kpis OWNER TO postgres;

--
-- Name: v_skill_gaps; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_skill_gaps AS
 WITH supply AS (
         SELECT trainer_competency_scores.skill_id,
            max(trainer_competency_scores.total_score) AS best_score,
            count(*) FILTER (WHERE (trainer_competency_scores.total_score >= 0.60)) AS strong_trainers
           FROM public.trainer_competency_scores
          GROUP BY trainer_competency_scores.skill_id
        ), weak AS (
         SELECT a.skill_id,
            count(DISTINCT t.user_id) AS weak_trainees
           FROM (public.attempts t
             JOIN public.assessments a ON ((a.id = t.assessment_id)))
          WHERE (t.status <> 'in_progress'::public.attempt_status)
          GROUP BY a.skill_id, t.user_id
         HAVING (avg(t.percentage) < (60)::numeric)
        ), weak_agg AS (
         SELECT weak.skill_id,
            sum(weak.weak_trainees) AS weak_trainees
           FROM weak
          GROUP BY weak.skill_id
        ), interest AS (
         SELECT us.skill_id,
            count(*) AS interested
           FROM (public.user_skills us
             JOIN public.users u ON ((u.id = us.user_id)))
          WHERE ((us.kind = 'interest'::public.skill_kind) AND (u.role = 'trainee'::public.role_name))
          GROUP BY us.skill_id
        )
 SELECT s.id AS skill_id,
    s.name AS skill,
    ps.name AS category,
    COALESCE(sp.best_score, (0)::numeric) AS best_trainer_score,
    COALESCE(sp.strong_trainers, (0)::bigint) AS strong_trainers,
    COALESCE(i.interested, (0)::bigint) AS interested_trainees,
    COALESCE(w.weak_trainees, (0)::numeric) AS weak_trainees,
    ((COALESCE(i.interested, (0)::bigint))::numeric + COALESCE(w.weak_trainees, (0)::numeric)) AS demand,
        CASE
            WHEN ((COALESCE(sp.strong_trainers, (0)::bigint) = 0) AND (((COALESCE(i.interested, (0)::bigint))::numeric + COALESCE(w.weak_trainees, (0)::numeric)) > (0)::numeric)) THEN 'critical gap'::text
            WHEN (COALESCE(sp.best_score, (0)::numeric) < 0.60) THEN 'weak coverage'::text
            ELSE 'covered'::text
        END AS gap_status
   FROM ((((public.skills s
     LEFT JOIN public.skills ps ON ((ps.id = s.parent_id)))
     LEFT JOIN supply sp ON ((sp.skill_id = s.id)))
     LEFT JOIN weak_agg w ON ((w.skill_id = s.id)))
     LEFT JOIN interest i ON ((i.skill_id = s.id)))
  WHERE ((s.parent_id IS NOT NULL) AND s.is_active);


ALTER VIEW public.v_skill_gaps OWNER TO postgres;

--
-- Name: v_skill_heatmap; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_skill_heatmap AS
 SELECT u.department,
    s.name AS skill,
    ps.name AS category,
    round(avg(t.percentage), 1) AS avg_pct,
    count(DISTINCT t.user_id) AS trainees
   FROM ((((public.attempts t
     JOIN public.assessments a ON ((a.id = t.assessment_id)))
     JOIN public.skills s ON ((s.id = a.skill_id)))
     LEFT JOIN public.skills ps ON ((ps.id = s.parent_id)))
     JOIN public.users u ON (((u.id = t.user_id) AND (u.role = 'trainee'::public.role_name))))
  WHERE ((t.status <> 'in_progress'::public.attempt_status) AND (u.department IS NOT NULL))
  GROUP BY u.department, s.name, ps.name;


ALTER VIEW public.v_skill_heatmap OWNER TO postgres;

--
-- Name: v_trainer_recommendations; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_trainer_recommendations AS
 SELECT s.id AS skill_id,
    s.name AS skill,
    u.id AS trainer_id,
    u.full_name,
    u.department,
    tcs.total_score,
    tcs.skill_match,
    tcs.tag_match,
    tcs.embedding_match,
    tcs.pass_rate,
    tcs.rating_score,
    tcs.experience_score,
    tcs.declared_proficiency,
    tcs.courses_taught,
    tcs.resources_uploaded,
    tcs.keyword_hits,
    rank() OVER (PARTITION BY s.id ORDER BY tcs.total_score DESC) AS rank_in_skill
   FROM (((public.trainer_competency_scores tcs
     JOIN public.skills s ON ((s.id = tcs.skill_id)))
     JOIN public.users u ON (((u.id = tcs.trainer_id) AND (u.status = 'approved'::public.user_status))))
     JOIN public.profiles p ON (((p.user_id = u.id) AND p.is_available)));


ALTER VIEW public.v_trainer_recommendations OWNER TO postgres;

--
-- Name: work_experiences; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.work_experiences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    organization text NOT NULL,
    designation text NOT NULL,
    start_date date NOT NULL,
    end_date date,
    description text,
    CONSTRAINT work_experiences_check CHECK (((end_date IS NULL) OR (end_date >= start_date)))
);


ALTER TABLE public.work_experiences OWNER TO postgres;

--
-- Name: audit_logs id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_logs ALTER COLUMN id SET DEFAULT nextval('public.audit_logs_id_seq'::regclass);


--
-- Name: notifications id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications ALTER COLUMN id SET DEFAULT nextval('public.notifications_id_seq'::regclass);


--
-- Name: skills id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.skills ALTER COLUMN id SET DEFAULT nextval('public.skills_id_seq'::regclass);


--
-- Data for Name: announcements; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.announcements (id, type, title, title_hi, body, link_url, related_course_id, related_user_id, audience, is_pinned, publish_at, expires_at, created_by, created_at) FROM stdin;
4c1b3fa5-0468-4b10-9f68-e440a9ba2902	announcement	Pre-monsoon training calendar is live	αñ¬αÑìαñ░αÑÇ-αñ«αñ╛αñ¿αñ╕αÑéαñ¿ αñ¬αÑìαñ░αñ╢αñ┐αñòαÑìαñ╖αñú αñòαÑêαñ▓αÑçαñéαñíαñ░ αñ£αñ╛αñ░αÑÇ	Enrol before 15 October for the pre-monsoon batch.	\N	\N	\N	\N	t	2026-09-24 18:31:45.462661+00	\N	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-26 18:31:45.462661+00
7966ff0e-f935-4e85-a5e5-5d6f2bfe3bb7	new_content	New lecture: Doppler Weather Radar products	αñ¿αñ»αñ╛ αñ╡αÑìαñ»αñ╛αñûαÑìαñ»αñ╛αñ¿: αñíαÑëαñ¬αÑìαñ▓αñ░ αñ«αÑîαñ╕αñ« αñ░αñíαñ╛αñ░ αñëαññαÑìαñ¬αñ╛αñª	Recorded session added to the trainer library.	\N	\N	\N	\N	f	2026-09-25 18:31:45.462661+00	\N	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-26 18:31:45.462661+00
9942dd1c-0274-4295-b78f-f60ff700e8c2	achievement	100 certificates issued this quarter	αñçαñ╕ αññαñ┐αñ«αñ╛αñ╣αÑÇ 100 αñ¬αÑìαñ░αñ«αñ╛αñúαñ¬αññαÑìαñ░ αñ£αñ╛αñ░αÑÇ	Congratulations to all trainees.	\N	\N	\N	\N	f	2026-09-26 13:31:45.462661+00	\N	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-26 18:31:45.462661+00
d0b2c49d-36aa-4a48-af0e-031b497da664	notification	Portal maintenance on Sunday 02:00ΓÇô03:00 IST	αñ░αñ╡αñ┐αñ╡αñ╛αñ░ 02:00ΓÇô03:00 IST αñ░αñûαñ░αñûαñ╛αñ╡	\N	\N	\N	\N	\N	f	2026-09-26 17:31:45.462661+00	\N	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-26 18:31:45.462661+00
\.


--
-- Data for Name: assessment_questions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.assessment_questions (assessment_id, question_id, "position", marks) FROM stdin;
c057b2ee-a8ac-4653-aca5-ec460ebc76b5	d9a7ed8d-0efb-42f4-91a0-78bdc550ba52	1	1.00
c057b2ee-a8ac-4653-aca5-ec460ebc76b5	da111a44-1bc7-4313-8d49-000d17b0e908	2	1.00
c057b2ee-a8ac-4653-aca5-ec460ebc76b5	c62fc8fd-203c-4951-8ca4-b4e9900c19f0	3	1.00
c057b2ee-a8ac-4653-aca5-ec460ebc76b5	55e092b5-7f15-4069-adc6-dd5b03252c0d	4	1.00
c057b2ee-a8ac-4653-aca5-ec460ebc76b5	2311cfcc-9214-467a-94a1-844f62b2b8fc	5	1.00
ebe2b9de-402c-446c-b22f-966c429d436d	0567f1c1-bbf2-4e4a-b7db-6befd81352b9	1	1.00
ebe2b9de-402c-446c-b22f-966c429d436d	a0bfeaef-e235-4212-ac4d-7f7ab3ae5ba0	2	1.00
ebe2b9de-402c-446c-b22f-966c429d436d	0501294b-c3f9-4624-b504-cb88972b277f	3	1.00
ebe2b9de-402c-446c-b22f-966c429d436d	321be7de-e911-4765-8fdf-d4bfecf116ae	4	1.00
ebe2b9de-402c-446c-b22f-966c429d436d	7e2d2b5c-62af-4f87-9adf-ddbe7c7be9e2	5	1.00
4c71123b-497d-4a50-9432-135ceb262ad2	e39fbfde-2a2e-481e-841c-29678be88938	1	1.00
4c71123b-497d-4a50-9432-135ceb262ad2	3c479adb-b6c9-4096-9ec1-fccbbf4d5a16	2	1.00
4c71123b-497d-4a50-9432-135ceb262ad2	6d8ec450-e25c-48bf-9709-9acd70197d1b	3	1.00
4c71123b-497d-4a50-9432-135ceb262ad2	c022f12d-04fd-41c9-a421-41863d673eeb	4	1.00
4c71123b-497d-4a50-9432-135ceb262ad2	0b2e1d11-24b7-4147-ad94-d4c0ad39a51f	5	1.00
b350ebbf-22fa-473a-b662-0519728d759d	842d3611-ab31-4f65-9d2b-a0546b1db981	1	1.00
b350ebbf-22fa-473a-b662-0519728d759d	3712c7d2-064b-41bf-afc4-209ba638ad38	2	1.00
b350ebbf-22fa-473a-b662-0519728d759d	dddf7001-2e03-4db3-80f2-ac3b8eb43044	3	1.00
b350ebbf-22fa-473a-b662-0519728d759d	dda73b09-c7af-4bdf-b308-14c0518c3cbd	4	1.00
b350ebbf-22fa-473a-b662-0519728d759d	ae36ca61-ad6e-44c4-b3a0-ea0644f6cd56	5	1.00
dee701a4-116d-4f39-8d83-0df5ea4898d0	276f4198-3410-4b9a-9bef-8d972380df31	1	1.00
dee701a4-116d-4f39-8d83-0df5ea4898d0	ada55e48-e425-4bb0-b5ce-62df4efe7a59	2	1.00
dee701a4-116d-4f39-8d83-0df5ea4898d0	1618e633-7082-4fb8-b5ee-c0cab2a891da	3	1.00
dee701a4-116d-4f39-8d83-0df5ea4898d0	fdd5557e-35cd-4786-8af2-5dbe641d4078	4	1.00
dee701a4-116d-4f39-8d83-0df5ea4898d0	cf3b477d-5c66-4ff9-9869-4d6414876655	5	1.00
3aea70dc-c6f5-4321-ab2b-c968da395f65	a6f81972-5233-4fb7-8336-bdfab28de722	1	1.00
3aea70dc-c6f5-4321-ab2b-c968da395f65	df87edf7-91a0-416a-a138-c6974ad4b26c	2	1.00
3aea70dc-c6f5-4321-ab2b-c968da395f65	481e800e-c390-452e-941b-8ba404541de2	3	1.00
3aea70dc-c6f5-4321-ab2b-c968da395f65	54092566-73c2-412f-b707-977e9d51421f	4	1.00
3aea70dc-c6f5-4321-ab2b-c968da395f65	723f7e35-d502-4ce2-9bc5-c48a9f981dcb	5	1.00
934345d0-839a-4e05-a13c-a84a3ebd984f	a0939e3f-23c9-4c7d-a493-3b18f8e31f08	1	1.00
934345d0-839a-4e05-a13c-a84a3ebd984f	9e166d0d-b6d3-4a62-8dbf-e636f0f83f8f	2	1.00
934345d0-839a-4e05-a13c-a84a3ebd984f	de5ec0f7-b0ad-48c7-9868-50d672f7f0c3	3	1.00
934345d0-839a-4e05-a13c-a84a3ebd984f	f20a235d-8e11-443b-98db-a9b42f2af4cc	4	1.00
934345d0-839a-4e05-a13c-a84a3ebd984f	6e03d4c9-da55-4d28-a229-6b27cd0af353	5	1.00
f3ac8fa1-7de7-40af-9179-894da3581f1c	e758450e-85ed-4e7e-a180-f3ad775095ca	1	1.00
f3ac8fa1-7de7-40af-9179-894da3581f1c	22ef0e6f-422f-41a9-9672-fedf62dce991	2	1.00
f3ac8fa1-7de7-40af-9179-894da3581f1c	85c159e3-fd28-4167-9d60-9d43b3c12fcc	3	1.00
f3ac8fa1-7de7-40af-9179-894da3581f1c	482e3171-7c3f-4c58-ad47-a9c05311ec37	4	1.00
f3ac8fa1-7de7-40af-9179-894da3581f1c	ea861331-71bf-493e-8789-467ba7167e55	5	1.00
79d25777-2b26-4a78-997d-828781d8180a	4ba0a281-f461-47f5-b680-d2250d31b6f5	1	1.00
79d25777-2b26-4a78-997d-828781d8180a	c45b1fb6-e1ec-4f8a-b452-853d64a619c1	2	1.00
79d25777-2b26-4a78-997d-828781d8180a	e4df6ba2-d87e-43d4-b6ca-938e8c96b418	3	1.00
79d25777-2b26-4a78-997d-828781d8180a	5d249fde-4b7a-4e1d-bba3-a32fcc09b680	4	1.00
79d25777-2b26-4a78-997d-828781d8180a	deca4865-7301-4479-924d-4b0566bac65d	5	1.00
10462a15-e99c-4a81-88db-80dd3b42299f	5bd7e0eb-5835-479b-a5bd-f00f13b4e540	1	1.00
10462a15-e99c-4a81-88db-80dd3b42299f	a0644737-8a5e-437c-a193-f4813cbdfa7c	2	1.00
10462a15-e99c-4a81-88db-80dd3b42299f	528049ed-aa3f-45d0-acc2-34c04a8ec5fe	3	1.00
10462a15-e99c-4a81-88db-80dd3b42299f	622a682e-3d90-4e5c-be31-62fa0b87660e	4	1.00
10462a15-e99c-4a81-88db-80dd3b42299f	bf89a8a0-39da-4bb5-ad65-693441dee031	5	1.00
e3215cf1-5eb2-44de-8ce1-d94482eb2d19	95e84b8c-febc-4a42-ac60-551d14417313	1	1.00
e3215cf1-5eb2-44de-8ce1-d94482eb2d19	faf9fcc8-6bbf-4618-90dc-6d7a40d6eca6	2	1.00
e3215cf1-5eb2-44de-8ce1-d94482eb2d19	7e8ae0c4-bc98-4629-9779-87785bec5474	3	1.00
e3215cf1-5eb2-44de-8ce1-d94482eb2d19	80a3a503-4ae5-4da0-ab98-f5fd59dc0be8	4	1.00
e3215cf1-5eb2-44de-8ce1-d94482eb2d19	7237393e-d5f4-4e2e-9dce-f7deb59204e4	5	1.00
28fbb3e6-1704-458c-a88b-1f5c3a06c404	437b8adc-8675-4043-aba0-f6b6a92f46b0	1	1.00
28fbb3e6-1704-458c-a88b-1f5c3a06c404	23021390-93b2-40c7-92f9-cfc73690b17a	2	1.00
28fbb3e6-1704-458c-a88b-1f5c3a06c404	7ec974f7-8ffd-4e10-90ce-fc783afd3155	3	1.00
28fbb3e6-1704-458c-a88b-1f5c3a06c404	5ea04a37-889b-4520-8648-7884e8d54922	4	1.00
28fbb3e6-1704-458c-a88b-1f5c3a06c404	fdc4311c-c458-40ef-9238-cb9683368482	5	1.00
db3f10f5-1c12-444f-992f-9c841f18fecc	6e98727a-edba-4619-a163-b394595b23c7	1	1.00
db3f10f5-1c12-444f-992f-9c841f18fecc	aaf61416-b013-490b-bdd9-d4f0aaa3bc96	2	1.00
db3f10f5-1c12-444f-992f-9c841f18fecc	4be8599a-6dc6-45af-9fec-4535ad2b93bf	3	1.00
db3f10f5-1c12-444f-992f-9c841f18fecc	bf1b246a-4c6f-4cc4-9e54-aed352f1a9bd	4	1.00
db3f10f5-1c12-444f-992f-9c841f18fecc	cc3a69f6-6b27-40d3-9a58-b3ea913119f2	5	1.00
c8072c7c-ce50-4a0d-8d8d-e12fb914512c	a0b03234-1d94-4e18-8ee6-d195a36dffe7	1	1.00
c8072c7c-ce50-4a0d-8d8d-e12fb914512c	202fdea7-c937-4073-99f1-f83430861d91	2	1.00
c8072c7c-ce50-4a0d-8d8d-e12fb914512c	a04a3b3c-ac59-47b2-8225-e17e1f112f91	3	1.00
c8072c7c-ce50-4a0d-8d8d-e12fb914512c	bca4bd80-7324-4585-91e4-9bcd75e20b34	4	1.00
c8072c7c-ce50-4a0d-8d8d-e12fb914512c	9051ccf3-c419-44d2-ad06-aa49c3f5d545	5	1.00
ad278eec-06a1-4b88-b81c-5f9fd019b465	c51a7ea7-8aea-47b7-9211-adc3ebd80fd2	1	1.00
ad278eec-06a1-4b88-b81c-5f9fd019b465	dd08aad7-a607-414a-ae3c-ec3e910277d1	2	1.00
ad278eec-06a1-4b88-b81c-5f9fd019b465	fd46de5f-099b-4dcb-a464-b299a4ecedfb	3	1.00
ad278eec-06a1-4b88-b81c-5f9fd019b465	78be014b-69a1-413a-be48-571e435770bd	4	1.00
ad278eec-06a1-4b88-b81c-5f9fd019b465	c897b8cd-5b9e-48bc-b8c6-a4eb51770b48	5	1.00
bd368b22-da64-4cfe-8e36-499e5f4ba544	da4b511c-10f3-464d-8fa0-af0e99ef931f	1	1.00
bd368b22-da64-4cfe-8e36-499e5f4ba544	655f352f-f301-46db-b4bc-567243efa169	2	1.00
bd368b22-da64-4cfe-8e36-499e5f4ba544	80d0fd9c-6e68-4186-8e8b-8614880ffe4d	3	1.00
bd368b22-da64-4cfe-8e36-499e5f4ba544	0e002015-f663-455b-bcce-4b22827dc05c	4	1.00
bd368b22-da64-4cfe-8e36-499e5f4ba544	a0b0ac84-1629-4fdd-94bf-fdd9a82a9229	5	1.00
52723147-451b-4271-a35b-762a768624bd	02c574fb-b58a-4321-8baf-b300a132a8f7	1	1.00
52723147-451b-4271-a35b-762a768624bd	ed36e338-f74f-493d-8c22-097cb87a5561	2	1.00
52723147-451b-4271-a35b-762a768624bd	5849b610-2faf-449f-9f02-9ddd26f0f7fe	3	1.00
52723147-451b-4271-a35b-762a768624bd	6e838f4e-b4b2-45be-8a0e-acb930a37d8a	4	1.00
52723147-451b-4271-a35b-762a768624bd	8a7ef50e-c059-4ae9-a120-f4b3456373a9	5	1.00
614db995-5b9a-418f-a799-6ef6753b242a	afb23585-8bdd-497a-aa38-2d3c581b6769	1	1.00
614db995-5b9a-418f-a799-6ef6753b242a	57212654-5f73-4a37-96ec-b167f3fbeecf	2	1.00
614db995-5b9a-418f-a799-6ef6753b242a	4f6f917b-d616-4092-b0ac-39e53ad98de5	3	1.00
614db995-5b9a-418f-a799-6ef6753b242a	dbdf0ad2-cf95-4adb-ad09-b3a173932006	4	1.00
614db995-5b9a-418f-a799-6ef6753b242a	c9820e75-e39b-40d1-8c8d-4c06569123a2	5	1.00
5b8e9be4-2660-4118-950d-6b6aff6c5136	c2cd4463-9d41-425b-9393-fdb04cfe2f63	1	1.00
5b8e9be4-2660-4118-950d-6b6aff6c5136	41f43d5d-ac0b-4d2c-be8c-c0fe84c0acf9	2	1.00
5b8e9be4-2660-4118-950d-6b6aff6c5136	3384b0df-33e7-4505-bd23-eacbcd2af28f	3	1.00
5b8e9be4-2660-4118-950d-6b6aff6c5136	2f226e14-f34a-4af0-a013-9ba072e4b762	4	1.00
5b8e9be4-2660-4118-950d-6b6aff6c5136	f64aae7f-54a6-46b1-a387-17f1b728bfcd	5	1.00
76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	805a4a40-b130-4825-ba2a-11b0d9d3b5ba	1	1.00
76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	182849cb-885c-4c10-bad7-6a0bda93b83f	2	1.00
76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	0ff32538-862f-4b19-b7d8-13cecbe3fbf4	3	1.00
76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	342ac555-702d-4419-a8a7-7d2659a8a005	4	1.00
76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	9e7cd74e-e5d7-4f5c-9237-7d64bfc72805	5	1.00
f9563acd-17e6-4ac9-90cb-98090139e03e	22178d2a-1cb7-4729-8e22-fd6bc0061466	1	1.00
f9563acd-17e6-4ac9-90cb-98090139e03e	765a0d20-25ad-4f78-a6e4-3731681299c3	2	1.00
f9563acd-17e6-4ac9-90cb-98090139e03e	03c2877f-df89-4f46-9313-39b20f3140f3	3	1.00
f9563acd-17e6-4ac9-90cb-98090139e03e	df5aae4c-db9e-41cf-87be-26e716f5d1a4	4	1.00
f9563acd-17e6-4ac9-90cb-98090139e03e	efd59e02-686a-4701-8df4-72bdabb0841f	5	1.00
d7490d75-c4ca-4762-90f5-d6115f4d2eb1	b7d6d94f-fe21-42a0-a6bf-d80cb2d9c64b	1	1.00
d7490d75-c4ca-4762-90f5-d6115f4d2eb1	cadb3ee0-9ede-4693-a848-f5ef3e0d9a7c	2	1.00
d7490d75-c4ca-4762-90f5-d6115f4d2eb1	65b16f63-c8df-4f6f-8002-36277e3305eb	3	1.00
d7490d75-c4ca-4762-90f5-d6115f4d2eb1	8fd56efa-7cfc-49b2-b76c-3215133153e7	4	1.00
d7490d75-c4ca-4762-90f5-d6115f4d2eb1	5a16fb16-0834-4820-9f46-8b9f73a4bcc7	5	1.00
835ba329-fadf-44c5-a8a3-5740e64f95ba	d0d39025-7813-433d-8583-ef5cf872a22b	1	1.00
835ba329-fadf-44c5-a8a3-5740e64f95ba	5b94a8c1-a147-4446-9c4c-45772a47bb34	2	1.00
835ba329-fadf-44c5-a8a3-5740e64f95ba	aedfe7ce-a52c-47a8-9443-fbc187c342b6	3	1.00
835ba329-fadf-44c5-a8a3-5740e64f95ba	b110754e-b4b2-4800-a273-fbc50d318c28	4	1.00
835ba329-fadf-44c5-a8a3-5740e64f95ba	1321f389-037b-4141-bae7-0a66b10b0575	5	1.00
212c6d86-5801-4c91-a7ac-d83d34ed24b7	b090dc4b-837d-425c-b37b-be844cf627d7	1	1.00
212c6d86-5801-4c91-a7ac-d83d34ed24b7	dc29bae1-e97b-4cc3-82b8-96a68ca1ad92	2	1.00
212c6d86-5801-4c91-a7ac-d83d34ed24b7	90c7e828-24f0-4051-9573-68c31ebbe637	3	1.00
212c6d86-5801-4c91-a7ac-d83d34ed24b7	8bf3f0ea-051d-4aad-b17c-5755ba6de07c	4	1.00
212c6d86-5801-4c91-a7ac-d83d34ed24b7	4c251056-9802-490a-91a6-2c608fab3cfe	5	1.00
21b80a0e-ac78-42bd-bcde-0249bedb0fe6	acf60aee-d036-47ae-94e8-2023492c8494	1	1.00
21b80a0e-ac78-42bd-bcde-0249bedb0fe6	fb2f7fc0-b18f-4012-a702-9d6edc655b81	2	1.00
21b80a0e-ac78-42bd-bcde-0249bedb0fe6	1dca2d0a-1df3-4500-8ad0-c7ac7112cea0	3	1.00
21b80a0e-ac78-42bd-bcde-0249bedb0fe6	0bf63b2b-d59e-4003-9b58-f86b5931b0f8	4	1.00
21b80a0e-ac78-42bd-bcde-0249bedb0fe6	7edbf11b-b851-4b25-a20f-f6ce2ba9d387	5	1.00
6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	f54ac6ae-d9c9-4269-83aa-c992f3cda491	1	1.00
6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	d1df1da4-4588-4f95-959f-82e0b8a4c6d0	2	1.00
6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	343442d5-4c8a-4b59-86ec-7b107b9cbc4c	3	1.00
6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	3932caed-6cbc-4e02-88c2-ac78a2709141	4	1.00
6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	21907a58-525f-49b6-ace8-83b80ff8db2c	5	1.00
\.


--
-- Data for Name: assessments; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.assessments (id, title, instructions, type, course_id, skill_id, created_by, status, opens_at, deadline_at, duration_minutes, pass_pct, max_attempts, shuffle_questions, show_results, lockdown_enabled, created_at) FROM stdin;
ebe2b9de-402c-446c-b22f-966c429d436d	NWP Modelling ┬╖ End-of-course test	\N	mcq_test	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	8	ff73e90e-1654-4bfd-8c73-43ad75a07f21	open	2026-03-10 18:31:45.462661+00	2026-09-28 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
4c71123b-497d-4a50-9432-135ceb262ad2	Automatic Weather Stations ┬╖ End-of-course test	\N	mcq_test	ad72951b-6768-4887-8063-287ff8f51bf1	11	ff73e90e-1654-4bfd-8c73-43ad75a07f21	open	2026-03-10 18:31:45.462661+00	2026-09-29 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
b350ebbf-22fa-473a-b662-0519728d759d	Tropical Cyclone Forecasting ┬╖ End-of-course test	\N	mcq_test	5317862f-92fe-4e22-ae0a-a244abce364c	7	ff38df49-9e3b-4df5-92a2-4852f8b79c74	open	2026-03-10 18:31:45.462661+00	2026-09-30 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
dee701a4-116d-4f39-8d83-0df5ea4898d0	Monsoon Forecasting ┬╖ End-of-course test	\N	mcq_test	32ab414d-cb9f-48ed-b3b5-97537b736196	6	2ae7d31a-ec05-402a-8104-ba433a1644eb	open	2026-03-10 18:31:45.462661+00	2026-10-01 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
3aea70dc-c6f5-4321-ab2b-c968da395f65	Doppler Weather Radar ┬╖ End-of-course test	\N	mcq_test	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	13	5db62bba-e3f6-4551-81f7-9d9237055aa3	open	2026-03-10 18:31:45.462661+00	2026-10-02 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
934345d0-839a-4e05-a13c-a84a3ebd984f	Satellite Meteorology ┬╖ End-of-course test	\N	mcq_test	33add9da-29ab-4a45-90b2-f5b8f4723f3d	12	9894043b-3b29-45e0-9abd-9b61597bf09a	open	2026-03-10 18:31:45.462661+00	2026-10-03 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
f3ac8fa1-7de7-40af-9179-894da3581f1c	Automatic Weather Stations ┬╖ End-of-course test	\N	mcq_test	8db3d256-cbbd-4863-b45a-d035bffdba03	11	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	open	2026-03-10 18:31:45.462661+00	2026-10-04 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
79d25777-2b26-4a78-997d-828781d8180a	Thunderstorm & Lightning ┬╖ End-of-course test	\N	mcq_test	c4985880-e557-407c-8f90-5c1f5b564695	16	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	open	2026-03-10 18:31:45.462661+00	2026-10-05 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
10462a15-e99c-4a81-88db-80dd3b42299f	Climate Data Analysis ┬╖ End-of-course test	\N	mcq_test	0724a689-d500-4969-b7fb-72e37232b31f	15	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	open	2026-03-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
e3215cf1-5eb2-44de-8ce1-d94482eb2d19	Agromet Advisory ┬╖ End-of-course test	\N	mcq_test	ce43f7f3-92cb-4d62-b40a-149bdd13b745	14	954754ab-6ecc-4d9a-a614-8cc84ffb3348	open	2026-03-10 18:31:45.462661+00	2026-09-27 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
28fbb3e6-1704-458c-a88b-1f5c3a06c404	NWP Modelling ┬╖ End-of-course test	\N	mcq_test	97b1727b-e525-4ee5-b01f-28b15a8101b5	8	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	open	2026-03-10 18:31:45.462661+00	2026-09-28 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
db3f10f5-1c12-444f-992f-9c841f18fecc	Flood Meteorology ┬╖ End-of-course test	\N	mcq_test	e930bc9e-26fc-4a34-89bc-012457df980e	18	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	open	2026-03-10 18:31:45.462661+00	2026-09-29 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
c8072c7c-ce50-4a0d-8d8d-e12fb914512c	Heatwave & Cold Wave ┬╖ End-of-course test	\N	mcq_test	290cedcf-37a4-4271-ae6c-2172115f0acb	17	e9178b69-2339-4a64-857f-5ad0630325a5	open	2026-03-10 18:31:45.462661+00	2026-09-30 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
ad278eec-06a1-4b88-b81c-5f9fd019b465	Thunderstorm & Lightning ┬╖ End-of-course test	\N	mcq_test	57e0bcdd-75f2-4ba6-b987-befe07d147c8	16	82556fbd-47bf-44ac-aae9-3499c844ea75	open	2026-03-10 18:31:45.462661+00	2026-10-01 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
bd368b22-da64-4cfe-8e36-499e5f4ba544	Python for Meteorology ┬╖ End-of-course test	\N	mcq_test	42f00c79-df57-400e-a313-a585d6a36404	20	fa5ba122-30c1-4e56-bc6b-b761794b1528	open	2026-03-10 18:31:45.462661+00	2026-10-02 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
52723147-451b-4271-a35b-762a768624bd	Nowcasting ┬╖ End-of-course test	\N	mcq_test	486ae347-6271-439f-9865-ebaf1e4d93cd	9	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	open	2026-03-10 18:31:45.462661+00	2026-10-03 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
614db995-5b9a-418f-a799-6ef6753b242a	Satellite Meteorology ┬╖ End-of-course test	\N	mcq_test	377c54d8-88d8-4698-a98c-27a42d2dae92	12	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	open	2026-03-10 18:31:45.462661+00	2026-10-04 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
5b8e9be4-2660-4118-950d-6b6aff6c5136	NWP Modelling ┬╖ End-of-course test	\N	mcq_test	1b09caa2-5a18-4f05-9a17-18d849ee499f	8	dab8c835-d264-43fb-9b10-7482bacf6b99	open	2026-03-10 18:31:45.462661+00	2026-10-05 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	Tropical Cyclone Forecasting ┬╖ End-of-course test	\N	mcq_test	614b89b9-ad9a-4481-9970-4691dd4e45dc	7	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	open	2026-03-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
f9563acd-17e6-4ac9-90cb-98090139e03e	Climate Data Analysis ┬╖ End-of-course test	\N	mcq_test	6be0b4cc-255a-4372-be78-8bd23dee561b	15	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	open	2026-03-10 18:31:45.462661+00	2026-09-27 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
d7490d75-c4ca-4762-90f5-d6115f4d2eb1	Monsoon Forecasting ┬╖ End-of-course test	\N	mcq_test	eec7cc46-3395-4f21-8c7f-cb99bee58b55	6	d6196926-78e5-4750-9dda-c802473b00e2	open	2026-03-10 18:31:45.462661+00	2026-09-28 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
835ba329-fadf-44c5-a8a3-5740e64f95ba	Doppler Weather Radar ┬╖ End-of-course test	\N	mcq_test	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	13	66a88386-7c29-44ae-805a-fd51d782743b	open	2026-03-10 18:31:45.462661+00	2026-09-29 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
212c6d86-5801-4c91-a7ac-d83d34ed24b7	Flood Meteorology ┬╖ End-of-course test	\N	mcq_test	3d04c87e-b5ec-45e8-951e-4bb279977080	18	66a88386-7c29-44ae-805a-fd51d782743b	open	2026-03-10 18:31:45.462661+00	2026-09-30 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
21b80a0e-ac78-42bd-bcde-0249bedb0fe6	Satellite Meteorology ┬╖ End-of-course test	\N	mcq_test	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	12	49992467-6281-4454-9a23-aa2dd4c74a95	open	2026-03-10 18:31:45.462661+00	2026-10-01 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	Heatwave & Cold Wave ┬╖ End-of-course test	\N	mcq_test	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	17	49992467-6281-4454-9a23-aa2dd4c74a95	open	2026-03-10 18:31:45.462661+00	2026-10-02 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
c057b2ee-a8ac-4653-aca5-ec460ebc76b5	Nowcasting ┬╖ End-of-course test	\N	mcq_test	55a4d643-f01f-4d75-8109-ff60798f1e9b	9	2e42c806-48d6-422a-b282-2b30f0484c3c	closed	2026-03-10 18:31:45.462661+00	2026-09-27 18:31:45.462661+00	20	60	2	t	t	t	2026-09-26 18:31:45.462661+00
\.


--
-- Data for Name: attempt_answers; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.attempt_answers (attempt_id, question_id, selected_option_ids, text_answer, rating_value, is_correct, marks_awarded, answered_at) FROM stdin;
\.


--
-- Data for Name: attempts; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.attempts (id, assessment_id, user_id, attempt_no, status, started_at, expires_at, submitted_at, score, max_score, percentage, passed, tab_switch_count, fullscreen_exits, copy_paste_attempts, proctor_events) FROM stdin;
96ed946f-9605-46c1-beec-23b1b100bdfa	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	15a2f413-02d0-4624-9468-3a8bec2ba6b8	1	submitted	2026-05-30 18:31:45.462661+00	2026-05-30 18:51:45.462661+00	2026-05-30 18:46:45.462661+00	2.00	5.00	43.00	f	0	0	0	[]
2ec8fd22-a714-4502-ab13-c6cc982477a0	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	30e16278-0ca1-4efa-a03b-7168658bb2c2	1	submitted	2026-07-19 18:31:45.462661+00	2026-07-19 18:51:45.462661+00	2026-07-19 18:46:45.462661+00	2.00	5.00	31.00	f	2	0	0	[]
76fee9b9-8636-4db0-ad06-12cb0b387d86	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	edc1993b-5333-4d99-bae2-9e80266978e0	1	submitted	2026-02-21 18:31:45.462661+00	2026-02-21 18:51:45.462661+00	2026-02-21 18:46:45.462661+00	3.00	5.00	52.00	f	1	0	0	[]
b3995f4a-8379-4aa9-952f-d14068bc20ef	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	2af59a77-c993-46c3-a686-b91217814d48	1	submitted	2026-08-30 18:31:45.462661+00	2026-08-30 18:51:45.462661+00	2026-08-30 18:46:45.462661+00	2.00	5.00	45.00	f	2	0	0	[]
1354fc1a-303e-4871-a7d1-fbc07024cb3f	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	7e426fed-4c2e-46f4-866a-7b8aa048cf06	1	submitted	2026-07-15 18:31:45.462661+00	2026-07-15 18:51:45.462661+00	2026-07-15 18:46:45.462661+00	2.00	5.00	36.00	f	0	0	0	[]
2edbbba0-76ab-41df-9d8a-d9bddb5cb0bb	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	b8541832-74c6-404f-90d0-5fb6d3df7663	1	submitted	2026-09-11 18:31:45.462661+00	2026-09-11 18:51:45.462661+00	2026-09-11 18:46:45.462661+00	2.00	5.00	45.00	f	1	0	0	[]
f1f0ac66-97c1-4e97-8ec2-d51328dcb067	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	3ed88e99-cb0d-423f-ae37-92b93c67d881	1	submitted	2026-08-03 18:31:45.462661+00	2026-08-03 18:51:45.462661+00	2026-08-03 18:46:45.462661+00	3.00	5.00	62.00	t	3	0	0	[]
56535692-870c-4688-b69f-b167c06df1fe	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	5d9905c7-91e8-4bd9-b187-b1b8772e0f63	1	submitted	2026-03-21 18:31:45.462661+00	2026-03-21 18:51:45.462661+00	2026-03-21 18:46:45.462661+00	2.00	5.00	48.00	f	1	0	0	[]
cd67fe8a-db18-4034-a9d4-3b2af5478925	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	fba30b27-7555-43f7-8c74-b84e722ebbc8	1	submitted	2026-07-12 18:31:45.462661+00	2026-07-12 18:51:45.462661+00	2026-07-12 18:46:45.462661+00	3.00	5.00	60.00	t	0	0	0	[]
b56a0ac5-eb72-4908-8138-202b67e5928c	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	732e74cf-b9b7-4adc-a43a-794430d7fe49	1	submitted	2026-03-25 18:31:45.462661+00	2026-03-25 18:51:45.462661+00	2026-03-25 18:46:45.462661+00	1.00	5.00	26.00	f	1	0	0	[]
4a4d35e5-f3e1-4e54-bca0-c1454f4b2efd	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	9e08ecc2-e291-4516-bae3-07b43abc2620	1	submitted	2026-04-21 18:31:45.462661+00	2026-04-21 18:51:45.462661+00	2026-04-21 18:46:45.462661+00	3.00	5.00	51.00	f	3	0	0	[]
a7c69dbf-9b1e-4682-93ec-ea40095ccb0f	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	df216767-1cda-46b6-874f-845e41051203	1	submitted	2026-04-17 18:31:45.462661+00	2026-04-17 18:51:45.462661+00	2026-04-17 18:46:45.462661+00	3.00	5.00	62.00	t	2	0	0	[]
4ca015e9-74d7-44fe-8f0a-6834968ec223	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	6b116d7e-84ed-47de-81ea-2bd42ea50968	1	submitted	2026-08-02 18:31:45.462661+00	2026-08-02 18:51:45.462661+00	2026-08-02 18:46:45.462661+00	1.00	5.00	29.00	f	1	0	0	[]
fc0fba84-d5ff-43c9-aac8-9c543aff86ef	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	b28e0245-9390-4127-ad3f-80ace4775f43	1	submitted	2026-05-12 18:31:45.462661+00	2026-05-12 18:51:45.462661+00	2026-05-12 18:46:45.462661+00	2.00	5.00	42.00	f	3	0	0	[]
1d7a0d60-51cb-455c-87cf-aa18aab5a542	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	72a5ceb8-6b68-433d-9b99-d62b8c9f1375	1	submitted	2026-03-04 18:31:45.462661+00	2026-03-04 18:51:45.462661+00	2026-03-04 18:46:45.462661+00	2.00	5.00	33.00	f	0	0	0	[]
e2a9c0f4-931a-411f-a2a1-ae864fd7bf7d	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	6f9f3af8-fa88-4804-aa9b-5680afa4c1ba	1	submitted	2026-04-30 18:31:45.462661+00	2026-04-30 18:51:45.462661+00	2026-04-30 18:46:45.462661+00	1.00	5.00	27.00	f	2	0	0	[]
e322fd4a-6275-4b29-848e-8436179eaf6a	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	4135122d-a240-499c-8de4-3db650d7acc9	1	submitted	2026-06-23 18:31:45.462661+00	2026-06-23 18:51:45.462661+00	2026-06-23 18:46:45.462661+00	3.00	5.00	59.00	f	2	0	0	[]
8e5aa1a2-64d5-4afe-bdb3-bfc2e97c9ba6	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	d22f23cf-8a58-499a-8dba-92806f1622ef	1	submitted	2026-07-21 18:31:45.462661+00	2026-07-21 18:51:45.462661+00	2026-07-21 18:46:45.462661+00	2.00	5.00	41.00	f	3	0	0	[]
197da81e-45f2-4e49-b288-9dd71395996b	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	a6afe850-9547-4fac-892c-00558ad8f725	1	submitted	2026-05-07 18:31:45.462661+00	2026-05-07 18:51:45.462661+00	2026-05-07 18:46:45.462661+00	2.00	5.00	47.00	f	0	0	0	[]
c5775923-817a-4fb7-84be-7fc8490722ff	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	1	submitted	2026-02-26 18:31:45.462661+00	2026-02-26 18:51:45.462661+00	2026-02-26 18:46:45.462661+00	2.00	5.00	42.00	f	2	0	0	[]
0b8be924-e48f-41b9-9fbe-72c76b29fe4e	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	5af34829-4d6f-425c-9f78-525896ea0526	1	submitted	2026-04-28 18:31:45.462661+00	2026-04-28 18:51:45.462661+00	2026-04-28 18:46:45.462661+00	3.00	5.00	57.00	f	1	0	0	[]
d16fe528-085b-47ce-b44f-c0381f20b6a9	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	d072273b-7a6f-4fa4-9195-1697050cfab1	1	submitted	2026-03-03 18:31:45.462661+00	2026-03-03 18:51:45.462661+00	2026-03-03 18:46:45.462661+00	3.00	5.00	61.00	t	2	0	0	[]
61e43a2b-d417-47d9-bf7c-935250dd6d7e	c057b2ee-a8ac-4653-aca5-ec460ebc76b5	65ef229b-117d-4946-b5bb-301e3f828fc2	1	submitted	2026-04-08 18:31:45.462661+00	2026-04-08 18:51:45.462661+00	2026-04-08 18:46:45.462661+00	2.00	5.00	34.00	f	2	0	0	[]
36776af6-906a-41cd-8251-92edc9e8920e	ebe2b9de-402c-446c-b22f-966c429d436d	6f9f3af8-fa88-4804-aa9b-5680afa4c1ba	1	submitted	2026-06-02 18:31:45.462661+00	2026-06-02 18:51:45.462661+00	2026-06-02 18:46:45.462661+00	4.00	5.00	83.00	t	1	0	0	[]
98e895a2-faa8-4f62-ad72-086e31c73d9a	ebe2b9de-402c-446c-b22f-966c429d436d	cf4749a6-6127-4d97-b2a0-17a11eabc216	1	submitted	2026-09-12 18:31:45.462661+00	2026-09-12 18:51:45.462661+00	2026-09-12 18:46:45.462661+00	5.00	5.00	98.00	t	2	0	0	[]
a2413615-b680-47e1-ab70-5267ebf12bb7	ebe2b9de-402c-446c-b22f-966c429d436d	a5fd318c-feeb-4b1b-b739-3e40a59dde18	1	submitted	2026-07-02 18:31:45.462661+00	2026-07-02 18:51:45.462661+00	2026-07-02 18:46:45.462661+00	5.00	5.00	99.00	t	2	0	0	[]
11fdda53-755a-4512-af31-c1132d621e15	ebe2b9de-402c-446c-b22f-966c429d436d	72a14ee8-79a9-41a0-8fb1-ac0dfac5bfa2	1	submitted	2026-04-22 18:31:45.462661+00	2026-04-22 18:51:45.462661+00	2026-04-22 18:46:45.462661+00	5.00	5.00	92.00	t	2	0	0	[]
2614367e-d872-47f1-b46e-1578a882f186	ebe2b9de-402c-446c-b22f-966c429d436d	625944b1-2b9b-433b-9af5-e72894aa7a58	1	submitted	2026-06-09 18:31:45.462661+00	2026-06-09 18:51:45.462661+00	2026-06-09 18:46:45.462661+00	5.00	5.00	100.00	t	1	0	0	[]
6a3e8d9a-e0c1-4417-8f1f-cb9cf86a40e7	ebe2b9de-402c-446c-b22f-966c429d436d	fda17094-1c9f-45de-a42c-aa815d09bc2a	1	submitted	2026-04-25 18:31:45.462661+00	2026-04-25 18:51:45.462661+00	2026-04-25 18:46:45.462661+00	5.00	5.00	100.00	t	0	0	0	[]
a39decff-8bcc-4972-9991-b401482f8f56	ebe2b9de-402c-446c-b22f-966c429d436d	9897dc81-824b-4829-9fda-76c3f3c3e38f	1	submitted	2026-04-27 18:31:45.462661+00	2026-04-27 18:51:45.462661+00	2026-04-27 18:46:45.462661+00	4.00	5.00	74.00	t	1	0	0	[]
258c4812-da64-427e-8c8e-f52fea4cf7d0	ebe2b9de-402c-446c-b22f-966c429d436d	30e16278-0ca1-4efa-a03b-7168658bb2c2	1	submitted	2026-04-19 18:31:45.462661+00	2026-04-19 18:51:45.462661+00	2026-04-19 18:46:45.462661+00	4.00	5.00	74.00	t	0	0	0	[]
dc2438e4-96d0-40f9-bd30-513c0dfe0510	ebe2b9de-402c-446c-b22f-966c429d436d	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	1	submitted	2026-08-16 18:31:45.462661+00	2026-08-16 18:51:45.462661+00	2026-08-16 18:46:45.462661+00	4.00	5.00	88.00	t	2	0	0	[]
ef8b1276-9bdd-414b-8e67-f57767be8dbb	ebe2b9de-402c-446c-b22f-966c429d436d	a6afe850-9547-4fac-892c-00558ad8f725	1	submitted	2026-05-13 18:31:45.462661+00	2026-05-13 18:51:45.462661+00	2026-05-13 18:46:45.462661+00	5.00	5.00	100.00	t	2	0	0	[]
44634927-9896-416e-98c6-c9a83ad87dab	ebe2b9de-402c-446c-b22f-966c429d436d	b28e0245-9390-4127-ad3f-80ace4775f43	1	submitted	2026-05-30 18:31:45.462661+00	2026-05-30 18:51:45.462661+00	2026-05-30 18:46:45.462661+00	4.00	5.00	79.00	t	0	0	0	[]
00f17b6d-2582-4d75-96c0-8b91841d2879	ebe2b9de-402c-446c-b22f-966c429d436d	a5e41a1c-9682-4873-8924-f11edf9b3fce	1	submitted	2026-08-11 18:31:45.462661+00	2026-08-11 18:51:45.462661+00	2026-08-11 18:46:45.462661+00	4.00	5.00	75.00	t	1	0	0	[]
160036b2-365e-4813-8f9e-57b3fe6b6342	ebe2b9de-402c-446c-b22f-966c429d436d	2994671f-607f-4cdc-a2bc-22ab97456b28	1	submitted	2026-05-05 18:31:45.462661+00	2026-05-05 18:51:45.462661+00	2026-05-05 18:46:45.462661+00	4.00	5.00	87.00	t	2	0	0	[]
9cf6a885-8c91-43c7-8932-753f5afbc781	ebe2b9de-402c-446c-b22f-966c429d436d	b8541832-74c6-404f-90d0-5fb6d3df7663	1	submitted	2026-09-01 18:31:45.462661+00	2026-09-01 18:51:45.462661+00	2026-09-01 18:46:45.462661+00	5.00	5.00	99.00	t	2	0	0	[]
f292d556-a837-4b2d-80b9-14f52e9948bd	ebe2b9de-402c-446c-b22f-966c429d436d	24cbfa5b-7114-43b8-957c-fe0efa420c25	1	submitted	2026-07-05 18:31:45.462661+00	2026-07-05 18:51:45.462661+00	2026-07-05 18:46:45.462661+00	5.00	5.00	98.00	t	3	0	0	[]
6eaeaa8f-54e7-496f-b33a-c40d3d2a0c5a	ebe2b9de-402c-446c-b22f-966c429d436d	8b09383e-447b-4fa0-b605-8d8cf4f3f527	1	submitted	2026-05-31 18:31:45.462661+00	2026-05-31 18:51:45.462661+00	2026-05-31 18:46:45.462661+00	5.00	5.00	93.00	t	1	0	0	[]
8403ae17-6f6d-4453-87bb-3930d78cf84e	ebe2b9de-402c-446c-b22f-966c429d436d	a7bae3c0-0e2c-42db-8e35-79114d5dfe80	1	submitted	2026-03-08 18:31:45.462661+00	2026-03-08 18:51:45.462661+00	2026-03-08 18:46:45.462661+00	4.00	5.00	74.00	t	1	0	0	[]
d343d60f-8b89-48e6-82cc-84c7f2eba684	ebe2b9de-402c-446c-b22f-966c429d436d	09cc88c9-6251-413b-9873-df6f5bb8b24d	1	submitted	2026-03-19 18:31:45.462661+00	2026-03-19 18:51:45.462661+00	2026-03-19 18:46:45.462661+00	4.00	5.00	82.00	t	1	0	0	[]
0fb69063-14ba-4d39-b5cc-7a1cf8dd4a5b	ebe2b9de-402c-446c-b22f-966c429d436d	c43722c6-7e70-49e0-acb4-ba4f953e36a8	1	submitted	2026-06-04 18:31:45.462661+00	2026-06-04 18:51:45.462661+00	2026-06-04 18:46:45.462661+00	3.00	5.00	67.00	t	2	0	0	[]
20eafed5-c229-4f5d-8288-069ced9fc064	ebe2b9de-402c-446c-b22f-966c429d436d	5a97c9d9-87c7-445c-9dc8-860fb29edb16	1	submitted	2026-05-19 18:31:45.462661+00	2026-05-19 18:51:45.462661+00	2026-05-19 18:46:45.462661+00	4.00	5.00	79.00	t	1	0	0	[]
9e216ab1-bbe6-4bda-87e0-c1c622a85c04	ebe2b9de-402c-446c-b22f-966c429d436d	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	1	submitted	2026-04-29 18:31:45.462661+00	2026-04-29 18:51:45.462661+00	2026-04-29 18:46:45.462661+00	5.00	5.00	100.00	t	1	0	0	[]
2498a1ed-787e-425c-9faa-b4f33c2c3ca4	ebe2b9de-402c-446c-b22f-966c429d436d	b875f05c-64bb-41c8-b501-04ef26d03cb3	1	submitted	2026-07-23 18:31:45.462661+00	2026-07-23 18:51:45.462661+00	2026-07-23 18:46:45.462661+00	5.00	5.00	100.00	t	3	0	0	[]
5c2864c3-f239-4bdd-befb-9d4f58267e00	ebe2b9de-402c-446c-b22f-966c429d436d	78313b75-0494-43a4-b199-ff1928254f44	1	submitted	2026-04-14 18:31:45.462661+00	2026-04-14 18:51:45.462661+00	2026-04-14 18:46:45.462661+00	3.00	5.00	69.00	t	1	0	0	[]
bdbf0de4-c3c2-43b3-840b-27b8f9490c62	4c71123b-497d-4a50-9432-135ceb262ad2	2af59a77-c993-46c3-a686-b91217814d48	1	submitted	2026-04-21 18:31:45.462661+00	2026-04-21 18:51:45.462661+00	2026-04-21 18:46:45.462661+00	2.00	5.00	45.00	f	2	0	0	[]
270f466b-1210-453f-976d-4b8f6d1b7964	4c71123b-497d-4a50-9432-135ceb262ad2	1f511b5e-1292-4202-860e-b54f11eda21e	1	submitted	2026-04-05 18:31:45.462661+00	2026-04-05 18:51:45.462661+00	2026-04-05 18:46:45.462661+00	2.00	5.00	35.00	f	3	0	0	[]
bee791c8-f86c-4783-9e6f-01a1210a98f5	4c71123b-497d-4a50-9432-135ceb262ad2	7acc259e-1231-481b-ab79-59821fd46534	1	submitted	2026-04-15 18:31:45.462661+00	2026-04-15 18:51:45.462661+00	2026-04-15 18:46:45.462661+00	4.00	5.00	71.00	t	1	0	0	[]
9c2fdad0-a3fb-47c9-a7c6-c10911e80e7b	4c71123b-497d-4a50-9432-135ceb262ad2	2c310487-b2d2-4f8a-bdc3-0fcd75eff4a9	1	submitted	2026-03-21 18:31:45.462661+00	2026-03-21 18:51:45.462661+00	2026-03-21 18:46:45.462661+00	2.00	5.00	36.00	f	1	0	0	[]
ff50d1a0-ba05-41ab-9b43-e7cd8e3a7e67	4c71123b-497d-4a50-9432-135ceb262ad2	729fd30e-9cfb-4751-bbdb-935fbbb7f994	1	submitted	2026-03-16 18:31:45.462661+00	2026-03-16 18:51:45.462661+00	2026-03-16 18:46:45.462661+00	3.00	5.00	68.00	t	2	0	0	[]
e4181eb3-3bc6-4fdb-a301-d67adfddf2af	4c71123b-497d-4a50-9432-135ceb262ad2	48f33e15-f87f-4629-ab82-4123ada4bdc4	1	submitted	2026-02-18 18:31:45.462661+00	2026-02-18 18:51:45.462661+00	2026-02-18 18:46:45.462661+00	3.00	5.00	50.00	f	2	0	0	[]
ff9a2b51-1aa6-4157-9665-458719601c03	4c71123b-497d-4a50-9432-135ceb262ad2	dbccc807-eaba-41f6-aabc-14c515010185	1	submitted	2026-05-30 18:31:45.462661+00	2026-05-30 18:51:45.462661+00	2026-05-30 18:46:45.462661+00	2.00	5.00	38.00	f	2	0	0	[]
c8621b86-6c81-413b-924e-3598c9e16d0e	4c71123b-497d-4a50-9432-135ceb262ad2	625944b1-2b9b-433b-9af5-e72894aa7a58	1	submitted	2026-07-20 18:31:45.462661+00	2026-07-20 18:51:45.462661+00	2026-07-20 18:46:45.462661+00	3.00	5.00	66.00	t	1	0	0	[]
032ee352-95a9-43f3-874c-269b7ee6054d	4c71123b-497d-4a50-9432-135ceb262ad2	7ea450f4-3442-46d0-a08b-19c1e7308bde	1	submitted	2026-03-24 18:31:45.462661+00	2026-03-24 18:51:45.462661+00	2026-03-24 18:46:45.462661+00	2.00	5.00	49.00	f	0	0	0	[]
9c73df28-5bfb-400a-9e17-cf19da303d56	4c71123b-497d-4a50-9432-135ceb262ad2	9bab5f84-a53e-49d6-91f8-eef87bf5960c	1	submitted	2026-05-07 18:31:45.462661+00	2026-05-07 18:51:45.462661+00	2026-05-07 18:46:45.462661+00	4.00	5.00	70.00	t	1	0	0	[]
8b548334-9c3e-46a0-8f1e-3218fd2bc78a	4c71123b-497d-4a50-9432-135ceb262ad2	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	1	submitted	2026-07-12 18:31:45.462661+00	2026-07-12 18:51:45.462661+00	2026-07-12 18:46:45.462661+00	4.00	5.00	73.00	t	3	0	0	[]
36cd5df7-4a30-4de4-bdaa-68907d870ae8	4c71123b-497d-4a50-9432-135ceb262ad2	8b09383e-447b-4fa0-b605-8d8cf4f3f527	1	submitted	2026-05-02 18:31:45.462661+00	2026-05-02 18:51:45.462661+00	2026-05-02 18:46:45.462661+00	2.00	5.00	47.00	f	2	0	0	[]
b5a7623e-266b-403a-856f-d71b5db55753	4c71123b-497d-4a50-9432-135ceb262ad2	732e74cf-b9b7-4adc-a43a-794430d7fe49	1	submitted	2026-04-25 18:31:45.462661+00	2026-04-25 18:51:45.462661+00	2026-04-25 18:46:45.462661+00	3.00	5.00	63.00	t	0	0	0	[]
5a825ee4-34f3-48e2-a0a8-ea34066fe420	4c71123b-497d-4a50-9432-135ceb262ad2	e44fe06d-6034-4f79-a75c-79ab0f2b58df	1	submitted	2026-08-04 18:31:45.462661+00	2026-08-04 18:51:45.462661+00	2026-08-04 18:46:45.462661+00	3.00	5.00	57.00	f	3	0	0	[]
88b191aa-11b9-4d17-98a3-866f1d5c16bc	4c71123b-497d-4a50-9432-135ceb262ad2	76e808de-304b-44e5-b793-8516b5fec7bb	1	submitted	2026-08-26 18:31:45.462661+00	2026-08-26 18:51:45.462661+00	2026-08-26 18:46:45.462661+00	3.00	5.00	50.00	f	3	0	0	[]
d0f37cae-73c8-4a9c-8437-ea761bf588a1	4c71123b-497d-4a50-9432-135ceb262ad2	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	1	submitted	2026-06-08 18:31:45.462661+00	2026-06-08 18:51:45.462661+00	2026-06-08 18:46:45.462661+00	2.00	5.00	36.00	f	3	0	0	[]
a967f557-bcca-4cf7-8f18-9bdd015326c0	4c71123b-497d-4a50-9432-135ceb262ad2	78313b75-0494-43a4-b199-ff1928254f44	1	submitted	2026-04-29 18:31:45.462661+00	2026-04-29 18:51:45.462661+00	2026-04-29 18:46:45.462661+00	3.00	5.00	61.00	t	0	0	0	[]
bc61f01e-8764-42cd-bc40-604d7809c1a7	4c71123b-497d-4a50-9432-135ceb262ad2	b97db5e7-dca3-4f88-8318-6d457e09be91	1	submitted	2026-07-25 18:31:45.462661+00	2026-07-25 18:51:45.462661+00	2026-07-25 18:46:45.462661+00	4.00	5.00	70.00	t	2	0	0	[]
e41ac1d6-c6ec-4bb8-baa1-fd1e754456ff	4c71123b-497d-4a50-9432-135ceb262ad2	33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	1	submitted	2026-03-10 18:31:45.462661+00	2026-03-10 18:51:45.462661+00	2026-03-10 18:46:45.462661+00	2.00	5.00	42.00	f	3	0	0	[]
da07e19f-beb9-4cce-b3c0-a3de1b26707e	4c71123b-497d-4a50-9432-135ceb262ad2	db9ec5a1-d0be-490d-91a6-bf32127bba75	1	submitted	2026-04-22 18:31:45.462661+00	2026-04-22 18:51:45.462661+00	2026-04-22 18:46:45.462661+00	3.00	5.00	68.00	t	1	0	0	[]
106dcf33-1e5c-4ae3-a65d-0620d6aedf50	4c71123b-497d-4a50-9432-135ceb262ad2	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	1	submitted	2026-05-05 18:31:45.462661+00	2026-05-05 18:51:45.462661+00	2026-05-05 18:46:45.462661+00	2.00	5.00	45.00	f	2	0	0	[]
381a517a-98e3-40c1-8a74-9a9588cdf9a7	4c71123b-497d-4a50-9432-135ceb262ad2	c43722c6-7e70-49e0-acb4-ba4f953e36a8	1	submitted	2026-03-19 18:31:45.462661+00	2026-03-19 18:51:45.462661+00	2026-03-19 18:46:45.462661+00	2.00	5.00	45.00	f	2	0	0	[]
05c9ab11-e406-4cc2-8749-ba1ee7b4db0e	b350ebbf-22fa-473a-b662-0519728d759d	1f511b5e-1292-4202-860e-b54f11eda21e	1	submitted	2026-09-04 18:31:45.462661+00	2026-09-04 18:51:45.462661+00	2026-09-04 18:46:45.462661+00	3.00	5.00	68.00	t	2	0	0	[]
4ec349ea-480b-4b06-888f-ecbb085728df	b350ebbf-22fa-473a-b662-0519728d759d	ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	1	submitted	2026-02-16 18:31:45.462661+00	2026-02-16 18:51:45.462661+00	2026-02-16 18:46:45.462661+00	3.00	5.00	65.00	t	3	0	0	[]
6491796d-c557-440e-b97b-5216fec1c0db	b350ebbf-22fa-473a-b662-0519728d759d	c41a5544-af25-44ec-9fab-26fa3a4e08a5	1	submitted	2026-09-09 18:31:45.462661+00	2026-09-09 18:51:45.462661+00	2026-09-09 18:46:45.462661+00	4.00	5.00	74.00	t	3	0	0	[]
1b58fda6-9a97-40b3-be1d-78a4e6433467	b350ebbf-22fa-473a-b662-0519728d759d	707e086b-3312-442d-ac6d-9776ebe73deb	1	submitted	2026-02-26 18:31:45.462661+00	2026-02-26 18:51:45.462661+00	2026-02-26 18:46:45.462661+00	4.00	5.00	73.00	t	2	0	0	[]
38d42ec2-e632-47cc-9177-7cefa1c2e54c	b350ebbf-22fa-473a-b662-0519728d759d	09cc88c9-6251-413b-9873-df6f5bb8b24d	1	submitted	2026-05-14 18:31:45.462661+00	2026-05-14 18:51:45.462661+00	2026-05-14 18:46:45.462661+00	3.00	5.00	67.00	t	2	0	0	[]
d7711111-589f-4e0d-8c95-c5697e00d5f0	b350ebbf-22fa-473a-b662-0519728d759d	db9ec5a1-d0be-490d-91a6-bf32127bba75	1	submitted	2026-05-10 18:31:45.462661+00	2026-05-10 18:51:45.462661+00	2026-05-10 18:46:45.462661+00	2.00	5.00	47.00	f	2	0	0	[]
17994b77-6b5f-4346-bf15-302ee7490f8e	b350ebbf-22fa-473a-b662-0519728d759d	562af427-bd16-4c30-940b-5d6121d738c8	1	submitted	2026-09-18 18:31:45.462661+00	2026-09-18 18:51:45.462661+00	2026-09-18 18:46:45.462661+00	3.00	5.00	53.00	f	2	0	0	[]
5cfff310-d4cd-49a8-bd73-5b35863bcbf6	b350ebbf-22fa-473a-b662-0519728d759d	15a2f413-02d0-4624-9468-3a8bec2ba6b8	1	submitted	2026-08-04 18:31:45.462661+00	2026-08-04 18:51:45.462661+00	2026-08-04 18:46:45.462661+00	2.00	5.00	45.00	f	3	0	0	[]
c9538473-ad9b-4b85-9e05-065efabe9588	b350ebbf-22fa-473a-b662-0519728d759d	7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	1	submitted	2026-02-25 18:31:45.462661+00	2026-02-25 18:51:45.462661+00	2026-02-25 18:46:45.462661+00	4.00	5.00	73.00	t	0	0	0	[]
fe0b5bc5-cfe8-44cb-b5aa-3baeb9f71a7a	b350ebbf-22fa-473a-b662-0519728d759d	862f76a0-443e-4a80-8644-ef4922c5f38a	1	submitted	2026-08-20 18:31:45.462661+00	2026-08-20 18:51:45.462661+00	2026-08-20 18:46:45.462661+00	3.00	5.00	58.00	f	1	0	0	[]
0ec27d21-12f9-4b0c-b1a3-be273c64f094	b350ebbf-22fa-473a-b662-0519728d759d	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	1	submitted	2026-03-10 18:31:45.462661+00	2026-03-10 18:51:45.462661+00	2026-03-10 18:46:45.462661+00	2.00	5.00	43.00	f	2	0	0	[]
d2c1efaf-7831-4ba5-a9f9-d44ed945c4b2	b350ebbf-22fa-473a-b662-0519728d759d	77c70aa0-ddd9-4445-be30-4817de1cbfd0	1	submitted	2026-05-30 18:31:45.462661+00	2026-05-30 18:51:45.462661+00	2026-05-30 18:46:45.462661+00	2.00	5.00	46.00	f	2	0	0	[]
e87184f0-d504-4b58-acf9-c0fba1009537	b350ebbf-22fa-473a-b662-0519728d759d	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	1	submitted	2026-06-17 18:31:45.462661+00	2026-06-17 18:51:45.462661+00	2026-06-17 18:46:45.462661+00	2.00	5.00	42.00	f	0	0	0	[]
7eeb1adb-a431-42de-bdf0-58fb496c7f40	b350ebbf-22fa-473a-b662-0519728d759d	caf34c22-6898-4c15-bde0-08f3d2634d41	1	submitted	2026-08-04 18:31:45.462661+00	2026-08-04 18:51:45.462661+00	2026-08-04 18:46:45.462661+00	2.00	5.00	45.00	f	2	0	0	[]
7b1a6c54-4820-4bae-9e42-8906d094b2f4	b350ebbf-22fa-473a-b662-0519728d759d	2e35b549-e1b5-4e61-a221-b0799208258c	1	submitted	2026-03-06 18:31:45.462661+00	2026-03-06 18:51:45.462661+00	2026-03-06 18:46:45.462661+00	2.00	5.00	37.00	f	1	0	0	[]
a5eccdf4-0f74-4ee3-a4f3-b2d46cf7b7e6	b350ebbf-22fa-473a-b662-0519728d759d	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	1	submitted	2026-07-14 18:31:45.462661+00	2026-07-14 18:51:45.462661+00	2026-07-14 18:46:45.462661+00	4.00	5.00	70.00	t	1	0	0	[]
3f69dfeb-c78f-4439-a938-9aded8f23671	b350ebbf-22fa-473a-b662-0519728d759d	b8541832-74c6-404f-90d0-5fb6d3df7663	1	submitted	2026-06-30 18:31:45.462661+00	2026-06-30 18:51:45.462661+00	2026-06-30 18:46:45.462661+00	3.00	5.00	54.00	f	2	0	0	[]
8b729082-91d9-4a0d-9850-9571245700bc	b350ebbf-22fa-473a-b662-0519728d759d	7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	1	submitted	2026-05-05 18:31:45.462661+00	2026-05-05 18:51:45.462661+00	2026-05-05 18:46:45.462661+00	4.00	5.00	73.00	t	2	0	0	[]
b9581770-ffa3-4805-bda6-3ab3775820ce	b350ebbf-22fa-473a-b662-0519728d759d	a8c5b60b-8763-4325-900d-07d7540e6015	1	submitted	2026-08-07 18:31:45.462661+00	2026-08-07 18:51:45.462661+00	2026-08-07 18:46:45.462661+00	4.00	5.00	73.00	t	1	0	0	[]
a938f243-3077-4e5d-9b17-33df55d49410	b350ebbf-22fa-473a-b662-0519728d759d	7f53c53d-3323-4146-8cea-01d6c38b4f77	1	submitted	2026-07-17 18:31:45.462661+00	2026-07-17 18:51:45.462661+00	2026-07-17 18:46:45.462661+00	3.00	5.00	51.00	f	2	0	0	[]
3b8b2585-5f80-4579-98f2-507e3d0c1ff8	b350ebbf-22fa-473a-b662-0519728d759d	a6afe850-9547-4fac-892c-00558ad8f725	1	submitted	2026-03-13 18:31:45.462661+00	2026-03-13 18:51:45.462661+00	2026-03-13 18:46:45.462661+00	3.00	5.00	69.00	t	0	0	0	[]
c441a0f0-a084-4c0d-8296-53d0a1a35c4c	dee701a4-116d-4f39-8d83-0df5ea4898d0	152f1a01-df4b-4828-bf72-c1616f324c38	1	submitted	2026-03-17 18:31:45.462661+00	2026-03-17 18:51:45.462661+00	2026-03-17 18:46:45.462661+00	4.00	5.00	80.00	t	0	0	0	[]
dfaac666-c833-40e3-a6fe-c381d4c08a3b	dee701a4-116d-4f39-8d83-0df5ea4898d0	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	1	submitted	2026-03-18 18:31:45.462661+00	2026-03-18 18:51:45.462661+00	2026-03-18 18:46:45.462661+00	4.00	5.00	72.00	t	2	0	0	[]
521f95f6-4f02-4b64-8466-f4116efbe625	dee701a4-116d-4f39-8d83-0df5ea4898d0	b4c20820-6710-46e1-b3cf-939b8bc00f93	1	submitted	2026-07-02 18:31:45.462661+00	2026-07-02 18:51:45.462661+00	2026-07-02 18:46:45.462661+00	4.00	5.00	75.00	t	2	0	0	[]
e8a2d8d4-34a5-4815-8406-df99fbffd3b5	dee701a4-116d-4f39-8d83-0df5ea4898d0	032c01d5-4b5e-44f6-821d-2ba4342c938f	1	submitted	2026-03-24 18:31:45.462661+00	2026-03-24 18:51:45.462661+00	2026-03-24 18:46:45.462661+00	4.00	5.00	83.00	t	0	0	0	[]
43276421-13c5-41df-9d78-c88db97ed6a3	dee701a4-116d-4f39-8d83-0df5ea4898d0	fbc637df-19cd-4ec5-b08d-49ce15747076	1	submitted	2026-04-06 18:31:45.462661+00	2026-04-06 18:51:45.462661+00	2026-04-06 18:46:45.462661+00	5.00	5.00	92.00	t	3	0	0	[]
3c67ac1c-a106-4bea-8ca4-641025bd1fca	dee701a4-116d-4f39-8d83-0df5ea4898d0	77c70aa0-ddd9-4445-be30-4817de1cbfd0	1	submitted	2026-08-21 18:31:45.462661+00	2026-08-21 18:51:45.462661+00	2026-08-21 18:46:45.462661+00	4.00	5.00	79.00	t	3	0	0	[]
4b0500d3-1204-4a4b-b87e-087ab13be96e	dee701a4-116d-4f39-8d83-0df5ea4898d0	2e35b549-e1b5-4e61-a221-b0799208258c	1	submitted	2026-06-29 18:31:45.462661+00	2026-06-29 18:51:45.462661+00	2026-06-29 18:46:45.462661+00	5.00	5.00	94.00	t	1	0	0	[]
8d8e2c69-af05-48d5-bab6-7270d253b419	dee701a4-116d-4f39-8d83-0df5ea4898d0	4ace2ecd-317e-494c-ad50-71e2794fb907	1	submitted	2026-06-24 18:31:45.462661+00	2026-06-24 18:51:45.462661+00	2026-06-24 18:46:45.462661+00	3.00	5.00	68.00	t	2	0	0	[]
d35a3f81-e929-4c4c-a9c1-bb3e88ca0669	dee701a4-116d-4f39-8d83-0df5ea4898d0	7ea450f4-3442-46d0-a08b-19c1e7308bde	1	submitted	2026-07-03 18:31:45.462661+00	2026-07-03 18:51:45.462661+00	2026-07-03 18:46:45.462661+00	3.00	5.00	64.00	t	2	0	0	[]
266698a9-e8b6-4e2d-b83a-9febda410985	dee701a4-116d-4f39-8d83-0df5ea4898d0	0d37acee-70ea-4604-8bd7-c995941443fd	1	submitted	2026-07-26 18:31:45.462661+00	2026-07-26 18:51:45.462661+00	2026-07-26 18:46:45.462661+00	3.00	5.00	60.00	t	1	0	0	[]
2280ceb5-8d02-4b7a-82f5-242d14083072	dee701a4-116d-4f39-8d83-0df5ea4898d0	a6d5837e-0df4-4cf0-9c98-8f0da7e4a1f1	1	submitted	2026-07-29 18:31:45.462661+00	2026-07-29 18:51:45.462661+00	2026-07-29 18:46:45.462661+00	3.00	5.00	63.00	t	3	0	0	[]
1cffa070-d95f-48c3-9d2b-5d48824fff66	dee701a4-116d-4f39-8d83-0df5ea4898d0	60e67627-9116-4358-a94b-89c0416805f0	1	submitted	2026-08-04 18:31:45.462661+00	2026-08-04 18:51:45.462661+00	2026-08-04 18:46:45.462661+00	4.00	5.00	80.00	t	1	0	0	[]
14c7c9a2-1038-4996-b33f-8494dd3a4e69	dee701a4-116d-4f39-8d83-0df5ea4898d0	cbd81a81-1d5a-4273-8494-11efdd5fd354	1	submitted	2026-06-25 18:31:45.462661+00	2026-06-25 18:51:45.462661+00	2026-06-25 18:46:45.462661+00	5.00	5.00	93.00	t	2	0	0	[]
cb081bed-e08e-4b7b-b5a3-c07987a81172	dee701a4-116d-4f39-8d83-0df5ea4898d0	3ded69a7-290c-47f6-bd29-7369f6f8e3c8	1	submitted	2026-07-04 18:31:45.462661+00	2026-07-04 18:51:45.462661+00	2026-07-04 18:46:45.462661+00	4.00	5.00	77.00	t	1	0	0	[]
b1b89450-9c8a-44a2-abed-e49ee49472bc	dee701a4-116d-4f39-8d83-0df5ea4898d0	1e418187-2717-4b94-934c-e5ca025993d8	1	submitted	2026-06-22 18:31:45.462661+00	2026-06-22 18:51:45.462661+00	2026-06-22 18:46:45.462661+00	4.00	5.00	71.00	t	2	0	0	[]
73011606-f871-4352-ad06-c074fae718c2	dee701a4-116d-4f39-8d83-0df5ea4898d0	4135122d-a240-499c-8de4-3db650d7acc9	1	submitted	2026-03-30 18:31:45.462661+00	2026-03-30 18:51:45.462661+00	2026-03-30 18:46:45.462661+00	3.00	5.00	66.00	t	1	0	0	[]
d66aa3c7-d3c9-4bf9-9756-6dbb8fe847fc	dee701a4-116d-4f39-8d83-0df5ea4898d0	48ae8c9d-e783-46c2-abf3-cc9d31e16d81	1	submitted	2026-07-05 18:31:45.462661+00	2026-07-05 18:51:45.462661+00	2026-07-05 18:46:45.462661+00	4.00	5.00	81.00	t	2	0	0	[]
fec0c9ce-eba8-40a0-ac60-01d954c96db6	dee701a4-116d-4f39-8d83-0df5ea4898d0	312e5b6a-024a-4a5d-9389-357b73426d42	1	submitted	2026-07-27 18:31:45.462661+00	2026-07-27 18:51:45.462661+00	2026-07-27 18:46:45.462661+00	3.00	5.00	56.00	f	3	0	0	[]
81716e7e-78a4-4eda-9b05-ddd37bd7db78	dee701a4-116d-4f39-8d83-0df5ea4898d0	d05292f5-3e9f-4e51-bb50-05a6534dc9b8	1	submitted	2026-03-29 18:31:45.462661+00	2026-03-29 18:51:45.462661+00	2026-03-29 18:46:45.462661+00	3.00	5.00	60.00	t	1	0	0	[]
5f0d3599-57a2-4d18-ae7a-a51c6d73a818	dee701a4-116d-4f39-8d83-0df5ea4898d0	6f1d6dd6-daa9-4660-a06f-527bf32f663e	1	submitted	2026-08-08 18:31:45.462661+00	2026-08-08 18:51:45.462661+00	2026-08-08 18:46:45.462661+00	3.00	5.00	68.00	t	1	0	0	[]
483176dd-59e1-461d-a4ad-f04a007a5b38	3aea70dc-c6f5-4321-ab2b-c968da395f65	8a83194a-d3bc-49dd-8594-ed05a26d23a0	1	submitted	2026-04-25 18:31:45.462661+00	2026-04-25 18:51:45.462661+00	2026-04-25 18:46:45.462661+00	4.00	5.00	76.00	t	1	0	0	[]
6d4e9a97-f0de-41b3-bdbd-87900f9702eb	3aea70dc-c6f5-4321-ab2b-c968da395f65	cd441b90-ef66-411c-b22e-4e046c29677f	1	submitted	2026-07-31 18:31:45.462661+00	2026-07-31 18:51:45.462661+00	2026-07-31 18:46:45.462661+00	4.00	5.00	81.00	t	1	0	0	[]
1a1850b7-e12b-4b47-9509-04519ec76025	3aea70dc-c6f5-4321-ab2b-c968da395f65	eee6bbaa-75eb-44f4-9892-d46194b720a9	1	submitted	2026-03-15 18:31:45.462661+00	2026-03-15 18:51:45.462661+00	2026-03-15 18:46:45.462661+00	5.00	5.00	97.00	t	1	0	0	[]
add472d1-4db5-4685-86f1-a8925360e009	3aea70dc-c6f5-4321-ab2b-c968da395f65	9389e5a2-816f-4e52-950b-a9af117c7ad1	1	submitted	2026-07-18 18:31:45.462661+00	2026-07-18 18:51:45.462661+00	2026-07-18 18:46:45.462661+00	4.00	5.00	83.00	t	2	0	0	[]
b687507d-a0e1-4214-af1d-ef828a3269fe	3aea70dc-c6f5-4321-ab2b-c968da395f65	ae420db9-d867-40d1-8d1a-01ee5d62e270	1	submitted	2026-09-04 18:31:45.462661+00	2026-09-04 18:51:45.462661+00	2026-09-04 18:46:45.462661+00	5.00	5.00	90.00	t	2	0	0	[]
ac1a5a4b-e1a4-4cb5-bb32-9cf73dbebbd6	3aea70dc-c6f5-4321-ab2b-c968da395f65	7f53c53d-3323-4146-8cea-01d6c38b4f77	1	submitted	2026-04-23 18:31:45.462661+00	2026-04-23 18:51:45.462661+00	2026-04-23 18:46:45.462661+00	4.00	5.00	74.00	t	1	0	0	[]
d9c76b80-9ba9-461b-80b2-6d2ded3b0255	3aea70dc-c6f5-4321-ab2b-c968da395f65	4d5fd264-452f-4436-8eca-5c6c62afb143	1	submitted	2026-03-12 18:31:45.462661+00	2026-03-12 18:51:45.462661+00	2026-03-12 18:46:45.462661+00	5.00	5.00	100.00	t	1	0	0	[]
fb29bfad-e11b-4965-8dd2-fd7676936b7b	3aea70dc-c6f5-4321-ab2b-c968da395f65	306af47d-26b6-4dc3-96ae-eb178609c1f6	1	submitted	2026-03-02 18:31:45.462661+00	2026-03-02 18:51:45.462661+00	2026-03-02 18:46:45.462661+00	3.00	5.00	62.00	t	1	0	0	[]
09973808-f7fb-453c-93d4-70b3c85e97ad	3aea70dc-c6f5-4321-ab2b-c968da395f65	fbc637df-19cd-4ec5-b08d-49ce15747076	1	submitted	2026-06-06 18:31:45.462661+00	2026-06-06 18:51:45.462661+00	2026-06-06 18:46:45.462661+00	4.00	5.00	76.00	t	1	0	0	[]
744a049d-e128-4be7-ac15-9b6165ea6885	3aea70dc-c6f5-4321-ab2b-c968da395f65	78313b75-0494-43a4-b199-ff1928254f44	1	submitted	2026-08-09 18:31:45.462661+00	2026-08-09 18:51:45.462661+00	2026-08-09 18:46:45.462661+00	4.00	5.00	83.00	t	2	0	0	[]
b7fd850d-d2a9-4aac-911d-4a482139ae83	3aea70dc-c6f5-4321-ab2b-c968da395f65	1e9340db-2cfd-419f-8894-9448da0bbc19	1	submitted	2026-09-10 18:31:45.462661+00	2026-09-10 18:51:45.462661+00	2026-09-10 18:46:45.462661+00	4.00	5.00	75.00	t	2	0	0	[]
1435a5bb-477e-45d3-81fa-539fd4d74b06	3aea70dc-c6f5-4321-ab2b-c968da395f65	f1bc49b2-13bf-4cd2-a5ac-6aa2c12e8f95	1	submitted	2026-04-27 18:31:45.462661+00	2026-04-27 18:51:45.462661+00	2026-04-27 18:46:45.462661+00	5.00	5.00	98.00	t	2	0	0	[]
a245addd-56c0-422f-a7ad-b07ca5c8bf83	3aea70dc-c6f5-4321-ab2b-c968da395f65	1f511b5e-1292-4202-860e-b54f11eda21e	1	submitted	2026-09-17 18:31:45.462661+00	2026-09-17 18:51:45.462661+00	2026-09-17 18:46:45.462661+00	5.00	5.00	96.00	t	1	0	0	[]
9ece99f6-5b57-41be-8e16-f9c5223ab798	3aea70dc-c6f5-4321-ab2b-c968da395f65	88b2de0e-fb93-4402-98ef-3c1bd149f61d	1	submitted	2026-08-09 18:31:45.462661+00	2026-08-09 18:51:45.462661+00	2026-08-09 18:46:45.462661+00	4.00	5.00	71.00	t	0	0	0	[]
c68b7984-ae45-49d1-b379-321e4dbd5a9c	3aea70dc-c6f5-4321-ab2b-c968da395f65	0d37acee-70ea-4604-8bd7-c995941443fd	1	submitted	2026-04-11 18:31:45.462661+00	2026-04-11 18:51:45.462661+00	2026-04-11 18:46:45.462661+00	4.00	5.00	80.00	t	0	0	0	[]
02985f5d-f966-4d67-93b8-6b2a3cbd9533	3aea70dc-c6f5-4321-ab2b-c968da395f65	ab65843a-c349-4b21-b43b-9302ed8231b4	1	submitted	2026-07-21 18:31:45.462661+00	2026-07-21 18:51:45.462661+00	2026-07-21 18:46:45.462661+00	4.00	5.00	88.00	t	2	0	0	[]
86a899aa-90ed-4719-ac0c-5e2a478ac192	3aea70dc-c6f5-4321-ab2b-c968da395f65	8a1eab45-738c-41b6-b35d-7737f5e2f64e	1	submitted	2026-05-21 18:31:45.462661+00	2026-05-21 18:51:45.462661+00	2026-05-21 18:46:45.462661+00	4.00	5.00	76.00	t	0	0	0	[]
575d5b63-5009-4793-b591-033e2517a0e1	3aea70dc-c6f5-4321-ab2b-c968da395f65	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	1	submitted	2026-06-17 18:31:45.462661+00	2026-06-17 18:51:45.462661+00	2026-06-17 18:46:45.462661+00	3.00	5.00	54.00	f	1	0	0	[]
757c1db0-9fb7-4df4-897e-0917863e2955	3aea70dc-c6f5-4321-ab2b-c968da395f65	3b6030a2-3993-4389-8c6c-d3427e0e680b	1	submitted	2026-05-21 18:31:45.462661+00	2026-05-21 18:51:45.462661+00	2026-05-21 18:46:45.462661+00	4.00	5.00	70.00	t	1	0	0	[]
69338e1a-354a-4176-8656-dd12630789c2	3aea70dc-c6f5-4321-ab2b-c968da395f65	15a2f413-02d0-4624-9468-3a8bec2ba6b8	1	submitted	2026-05-18 18:31:45.462661+00	2026-05-18 18:51:45.462661+00	2026-05-18 18:46:45.462661+00	5.00	5.00	100.00	t	1	0	0	[]
04021ea2-2b8d-49d4-b4cc-3ba6b7bd4d00	3aea70dc-c6f5-4321-ab2b-c968da395f65	5d1e34b1-8861-4358-96e3-f5ed89f5c9d2	1	submitted	2026-07-04 18:31:45.462661+00	2026-07-04 18:51:45.462661+00	2026-07-04 18:46:45.462661+00	5.00	5.00	92.00	t	2	0	0	[]
076fdeb0-6c6a-4dc4-ae38-75217abd69f7	3aea70dc-c6f5-4321-ab2b-c968da395f65	d22f23cf-8a58-499a-8dba-92806f1622ef	1	submitted	2026-07-31 18:31:45.462661+00	2026-07-31 18:51:45.462661+00	2026-07-31 18:46:45.462661+00	3.00	5.00	66.00	t	3	0	0	[]
62890e17-5cc1-4bd5-b025-3244c0515c04	3aea70dc-c6f5-4321-ab2b-c968da395f65	ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	1	submitted	2026-07-24 18:31:45.462661+00	2026-07-24 18:51:45.462661+00	2026-07-24 18:46:45.462661+00	4.00	5.00	84.00	t	3	0	0	[]
100ab099-644c-44b7-97c5-b20433197486	3aea70dc-c6f5-4321-ab2b-c968da395f65	a7bae3c0-0e2c-42db-8e35-79114d5dfe80	1	submitted	2026-06-03 18:31:45.462661+00	2026-06-03 18:51:45.462661+00	2026-06-03 18:46:45.462661+00	3.00	5.00	62.00	t	2	0	0	[]
3b384956-ebc1-4156-ad3a-63fa8212c31c	934345d0-839a-4e05-a13c-a84a3ebd984f	ec4cdace-5f9a-4198-9518-7c59753a1127	1	submitted	2026-06-30 18:31:45.462661+00	2026-06-30 18:51:45.462661+00	2026-06-30 18:46:45.462661+00	1.00	5.00	28.00	f	2	0	0	[]
efaa1640-80b1-44fd-bac6-017f662c79be	934345d0-839a-4e05-a13c-a84a3ebd984f	3e1e22ae-3497-44dc-bb66-1a3c24a5af91	1	submitted	2026-06-28 18:31:45.462661+00	2026-06-28 18:51:45.462661+00	2026-06-28 18:46:45.462661+00	4.00	5.00	72.00	t	2	0	0	[]
8ddd1f06-95a1-401a-b2e2-ceed95bff647	934345d0-839a-4e05-a13c-a84a3ebd984f	3260915b-2633-418b-997d-2beabd07ed2b	1	submitted	2026-07-28 18:31:45.462661+00	2026-07-28 18:51:45.462661+00	2026-07-28 18:46:45.462661+00	2.00	5.00	30.00	f	2	0	0	[]
9713d16b-4a2c-4132-be04-ff7923c77e53	934345d0-839a-4e05-a13c-a84a3ebd984f	8be014b0-ed46-43db-89e2-91a301c618db	1	submitted	2026-08-17 18:31:45.462661+00	2026-08-17 18:51:45.462661+00	2026-08-17 18:46:45.462661+00	3.00	5.00	69.00	t	3	0	0	[]
9883e03e-3043-4917-9cc1-09d222ee698c	934345d0-839a-4e05-a13c-a84a3ebd984f	2d970758-319c-400f-b2ba-93057f16a33e	1	submitted	2026-08-21 18:31:45.462661+00	2026-08-21 18:51:45.462661+00	2026-08-21 18:46:45.462661+00	2.00	5.00	36.00	f	2	0	0	[]
b717cc81-8892-4117-8464-74f7f7838baf	934345d0-839a-4e05-a13c-a84a3ebd984f	a17abc66-209e-405f-bcd6-c39e54cbce66	1	submitted	2026-05-15 18:31:45.462661+00	2026-05-15 18:51:45.462661+00	2026-05-15 18:46:45.462661+00	3.00	5.00	67.00	t	2	0	0	[]
90c594db-459b-4ab9-af07-186ec10ae0b8	934345d0-839a-4e05-a13c-a84a3ebd984f	8ffbd0cf-b807-4193-af37-3a61482c76eb	1	submitted	2026-06-23 18:31:45.462661+00	2026-06-23 18:51:45.462661+00	2026-06-23 18:46:45.462661+00	3.00	5.00	62.00	t	3	0	0	[]
f9e4ce06-e02f-4bec-a35d-b040c1801aa7	934345d0-839a-4e05-a13c-a84a3ebd984f	7acc259e-1231-481b-ab79-59821fd46534	1	submitted	2026-03-12 18:31:45.462661+00	2026-03-12 18:51:45.462661+00	2026-03-12 18:46:45.462661+00	2.00	5.00	48.00	f	1	0	0	[]
34ca6efd-074c-4fff-961f-2ef11f97390f	934345d0-839a-4e05-a13c-a84a3ebd984f	fed72080-2568-4892-8047-0b3c72ff7fad	1	submitted	2026-04-13 18:31:45.462661+00	2026-04-13 18:51:45.462661+00	2026-04-13 18:46:45.462661+00	3.00	5.00	54.00	f	3	0	0	[]
113860cc-8fd4-42b7-bfcf-9fc98915d858	934345d0-839a-4e05-a13c-a84a3ebd984f	c41a5544-af25-44ec-9fab-26fa3a4e08a5	1	submitted	2026-06-06 18:31:45.462661+00	2026-06-06 18:51:45.462661+00	2026-06-06 18:46:45.462661+00	3.00	5.00	60.00	t	2	0	0	[]
1dda7559-427f-44b8-bbbc-89b39d1da74e	934345d0-839a-4e05-a13c-a84a3ebd984f	f1bc49b2-13bf-4cd2-a5ac-6aa2c12e8f95	1	submitted	2026-05-10 18:31:45.462661+00	2026-05-10 18:51:45.462661+00	2026-05-10 18:46:45.462661+00	4.00	5.00	76.00	t	2	0	0	[]
5ac96eee-7de5-474c-9175-2dc9bf05054b	934345d0-839a-4e05-a13c-a84a3ebd984f	1f511b5e-1292-4202-860e-b54f11eda21e	1	submitted	2026-04-23 18:31:45.462661+00	2026-04-23 18:51:45.462661+00	2026-04-23 18:46:45.462661+00	3.00	5.00	53.00	f	1	0	0	[]
dd468982-c659-44c9-9189-6f2c17884a3e	934345d0-839a-4e05-a13c-a84a3ebd984f	2c310487-b2d2-4f8a-bdc3-0fcd75eff4a9	1	submitted	2026-06-23 18:31:45.462661+00	2026-06-23 18:51:45.462661+00	2026-06-23 18:46:45.462661+00	3.00	5.00	53.00	f	3	0	0	[]
fafc475d-fa67-4b67-8470-0a8b311d41f4	934345d0-839a-4e05-a13c-a84a3ebd984f	5abfd2bf-a622-4ac2-8867-2be6525ec0e8	1	submitted	2026-07-06 18:31:45.462661+00	2026-07-06 18:51:45.462661+00	2026-07-06 18:46:45.462661+00	2.00	5.00	36.00	f	2	0	0	[]
718dcd46-aecd-44c7-a592-2a659876f3d7	934345d0-839a-4e05-a13c-a84a3ebd984f	889560c5-9238-4463-82d8-b65d7fdba4bc	1	submitted	2026-07-18 18:31:45.462661+00	2026-07-18 18:51:45.462661+00	2026-07-18 18:46:45.462661+00	3.00	5.00	55.00	f	0	0	0	[]
07080256-5f80-4677-80ce-0d44bf011edd	934345d0-839a-4e05-a13c-a84a3ebd984f	3d87692f-06c1-4403-95ff-c70d1598700a	1	submitted	2026-04-27 18:31:45.462661+00	2026-04-27 18:51:45.462661+00	2026-04-27 18:46:45.462661+00	3.00	5.00	55.00	f	2	0	0	[]
08f1f4b9-d4f1-4893-9a88-df022d4128d5	934345d0-839a-4e05-a13c-a84a3ebd984f	7b1099fc-7596-4be6-9ab4-990d535c39a5	1	submitted	2026-08-24 18:31:45.462661+00	2026-08-24 18:51:45.462661+00	2026-08-24 18:46:45.462661+00	3.00	5.00	61.00	t	1	0	0	[]
0b5c4414-f9a2-43aa-b874-df99ecbfd5a5	f3ac8fa1-7de7-40af-9179-894da3581f1c	032c01d5-4b5e-44f6-821d-2ba4342c938f	1	submitted	2026-08-17 18:31:45.462661+00	2026-08-17 18:51:45.462661+00	2026-08-17 18:46:45.462661+00	2.00	5.00	40.00	f	1	0	0	[]
4be7549e-9314-4b43-bb6d-28ca387ed8a9	f3ac8fa1-7de7-40af-9179-894da3581f1c	33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	1	submitted	2026-02-20 18:31:45.462661+00	2026-02-20 18:51:45.462661+00	2026-02-20 18:46:45.462661+00	3.00	5.00	51.00	f	1	0	0	[]
bdd6c6eb-fd82-4aaa-9264-3e37ce05b07c	f3ac8fa1-7de7-40af-9179-894da3581f1c	8b09383e-447b-4fa0-b605-8d8cf4f3f527	1	submitted	2026-04-09 18:31:45.462661+00	2026-04-09 18:51:45.462661+00	2026-04-09 18:46:45.462661+00	2.00	5.00	45.00	f	0	0	0	[]
2a2c7c40-b0d7-4d74-9abf-acf92e7f6b4f	f3ac8fa1-7de7-40af-9179-894da3581f1c	bd78a83d-5740-4d0d-9000-cdf29d332f27	1	submitted	2026-07-08 18:31:45.462661+00	2026-07-08 18:51:45.462661+00	2026-07-08 18:46:45.462661+00	3.00	5.00	62.00	t	1	0	0	[]
5130672d-6d85-4283-b8db-287c9eb262b8	f3ac8fa1-7de7-40af-9179-894da3581f1c	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	1	submitted	2026-05-17 18:31:45.462661+00	2026-05-17 18:51:45.462661+00	2026-05-17 18:46:45.462661+00	3.00	5.00	63.00	t	1	0	0	[]
484b60fe-9bf0-486d-addd-3aded289c8f2	f3ac8fa1-7de7-40af-9179-894da3581f1c	8a0a7128-e6e6-4b49-8395-52723dda0b7c	1	submitted	2026-05-25 18:31:45.462661+00	2026-05-25 18:51:45.462661+00	2026-05-25 18:46:45.462661+00	3.00	5.00	52.00	f	2	0	0	[]
1aa3b600-3ea0-42f0-a235-ba6ebb8d66d3	f3ac8fa1-7de7-40af-9179-894da3581f1c	6f1d6dd6-daa9-4660-a06f-527bf32f663e	1	submitted	2026-09-14 18:31:45.462661+00	2026-09-14 18:51:45.462661+00	2026-09-14 18:46:45.462661+00	3.00	5.00	58.00	f	1	0	0	[]
c80dbec3-60fe-4d5f-90ee-79c6559f7a7b	f3ac8fa1-7de7-40af-9179-894da3581f1c	6a389990-e259-43a4-a9a2-7575b00029e0	1	submitted	2026-08-08 18:31:45.462661+00	2026-08-08 18:51:45.462661+00	2026-08-08 18:46:45.462661+00	2.00	5.00	33.00	f	2	0	0	[]
266f7f5f-5726-460d-ad4c-d8452177a44b	f3ac8fa1-7de7-40af-9179-894da3581f1c	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	1	submitted	2026-09-03 18:31:45.462661+00	2026-09-03 18:51:45.462661+00	2026-09-03 18:46:45.462661+00	2.00	5.00	40.00	f	0	0	0	[]
5ae41eb9-3261-41d6-a1e4-cf6a843635ef	f3ac8fa1-7de7-40af-9179-894da3581f1c	eee6bbaa-75eb-44f4-9892-d46194b720a9	1	submitted	2026-09-12 18:31:45.462661+00	2026-09-12 18:51:45.462661+00	2026-09-12 18:46:45.462661+00	2.00	5.00	34.00	f	3	0	0	[]
73a3504b-647f-4407-800d-35bf8b72b5d1	f3ac8fa1-7de7-40af-9179-894da3581f1c	4d5fd264-452f-4436-8eca-5c6c62afb143	1	submitted	2026-05-12 18:31:45.462661+00	2026-05-12 18:51:45.462661+00	2026-05-12 18:46:45.462661+00	4.00	5.00	70.00	t	0	0	0	[]
3ea9c169-4dab-4c0a-8a39-9007b0647226	f3ac8fa1-7de7-40af-9179-894da3581f1c	2994671f-607f-4cdc-a2bc-22ab97456b28	1	submitted	2026-07-24 18:31:45.462661+00	2026-07-24 18:51:45.462661+00	2026-07-24 18:46:45.462661+00	2.00	5.00	42.00	f	3	0	0	[]
ac9193a7-2c7a-4f74-9aac-c4d836490bfd	f3ac8fa1-7de7-40af-9179-894da3581f1c	3af00a36-1f7b-4846-a52a-b1871416c5b1	1	submitted	2026-07-30 18:31:45.462661+00	2026-07-30 18:51:45.462661+00	2026-07-30 18:46:45.462661+00	3.00	5.00	65.00	t	2	0	0	[]
50aab750-bd17-497f-9dc8-4ba85fc5a09a	f3ac8fa1-7de7-40af-9179-894da3581f1c	5af34829-4d6f-425c-9f78-525896ea0526	1	submitted	2026-08-04 18:31:45.462661+00	2026-08-04 18:51:45.462661+00	2026-08-04 18:46:45.462661+00	3.00	5.00	60.00	t	3	0	0	[]
9930fd06-7de0-479f-90ce-02a6a5c84668	f3ac8fa1-7de7-40af-9179-894da3581f1c	b2734396-c5d2-4b05-99d0-986a180a98a6	1	submitted	2026-08-01 18:31:45.462661+00	2026-08-01 18:51:45.462661+00	2026-08-01 18:46:45.462661+00	3.00	5.00	69.00	t	1	0	0	[]
5aa93d7f-1727-4945-abe7-d871e73a900a	f3ac8fa1-7de7-40af-9179-894da3581f1c	0f80298a-f569-4c55-88aa-a57625e20751	1	submitted	2026-05-31 18:31:45.462661+00	2026-05-31 18:51:45.462661+00	2026-05-31 18:46:45.462661+00	2.00	5.00	42.00	f	1	0	0	[]
379b1742-ce8d-46a8-9c7f-5f1e4476d90f	f3ac8fa1-7de7-40af-9179-894da3581f1c	c41a5544-af25-44ec-9fab-26fa3a4e08a5	1	submitted	2026-04-18 18:31:45.462661+00	2026-04-18 18:51:45.462661+00	2026-04-18 18:46:45.462661+00	3.00	5.00	65.00	t	1	0	0	[]
725dbe34-eed0-4f27-b169-dfaf6974bbbb	79d25777-2b26-4a78-997d-828781d8180a	fba30b27-7555-43f7-8c74-b84e722ebbc8	1	submitted	2026-09-11 18:31:45.462661+00	2026-09-11 18:51:45.462661+00	2026-09-11 18:46:45.462661+00	5.00	5.00	100.00	t	1	0	0	[]
ec028ef8-0f6e-4a4c-94c6-b92d4e99754f	79d25777-2b26-4a78-997d-828781d8180a	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	1	submitted	2026-03-29 18:31:45.462661+00	2026-03-29 18:51:45.462661+00	2026-03-29 18:46:45.462661+00	4.00	5.00	78.00	t	3	0	0	[]
e5cf6c64-4b9d-4383-84ed-e023805406a9	79d25777-2b26-4a78-997d-828781d8180a	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	1	submitted	2026-06-03 18:31:45.462661+00	2026-06-03 18:51:45.462661+00	2026-06-03 18:46:45.462661+00	5.00	5.00	97.00	t	3	0	0	[]
8df6f07e-9acc-4191-b6de-c072ece59866	79d25777-2b26-4a78-997d-828781d8180a	17231857-2d57-46f3-aecc-cb26a0865adb	1	submitted	2026-03-02 18:31:45.462661+00	2026-03-02 18:51:45.462661+00	2026-03-02 18:46:45.462661+00	5.00	5.00	100.00	t	3	0	0	[]
87ac6a8f-d363-4ae3-9019-ad7c28ff9c77	79d25777-2b26-4a78-997d-828781d8180a	6b116d7e-84ed-47de-81ea-2bd42ea50968	1	submitted	2026-08-21 18:31:45.462661+00	2026-08-21 18:51:45.462661+00	2026-08-21 18:46:45.462661+00	5.00	5.00	100.00	t	0	0	0	[]
31516d5c-db3e-4d17-afeb-7261e40a4d6e	79d25777-2b26-4a78-997d-828781d8180a	a5102b13-4107-4fe5-b7a0-064dd07042ee	1	submitted	2026-06-18 18:31:45.462661+00	2026-06-18 18:51:45.462661+00	2026-06-18 18:46:45.462661+00	5.00	5.00	100.00	t	0	0	0	[]
48b80c23-d0e3-46ef-bdcc-f7f31bdb6beb	79d25777-2b26-4a78-997d-828781d8180a	28fe79f0-6207-4e0c-8bae-1eb02eed759b	1	submitted	2026-07-11 18:31:45.462661+00	2026-07-11 18:51:45.462661+00	2026-07-11 18:46:45.462661+00	5.00	5.00	100.00	t	0	0	0	[]
dc6a846b-0906-413d-a93e-b72b7ade98c9	79d25777-2b26-4a78-997d-828781d8180a	889560c5-9238-4463-82d8-b65d7fdba4bc	1	submitted	2026-06-23 18:31:45.462661+00	2026-06-23 18:51:45.462661+00	2026-06-23 18:46:45.462661+00	5.00	5.00	100.00	t	1	0	0	[]
08ea1d59-f2f5-4a3f-8769-9578d2cc197d	79d25777-2b26-4a78-997d-828781d8180a	b97db5e7-dca3-4f88-8318-6d457e09be91	1	submitted	2026-08-14 18:31:45.462661+00	2026-08-14 18:51:45.462661+00	2026-08-14 18:46:45.462661+00	4.00	5.00	84.00	t	1	0	0	[]
0a87e660-de33-4891-8d73-ea654803943e	79d25777-2b26-4a78-997d-828781d8180a	2731bad6-8e73-4106-8def-3df5df76b6ea	1	submitted	2026-08-18 18:31:45.462661+00	2026-08-18 18:51:45.462661+00	2026-08-18 18:46:45.462661+00	5.00	5.00	93.00	t	2	0	0	[]
a56c49e5-b4dd-49b3-b3ba-91cb1f0c82e9	79d25777-2b26-4a78-997d-828781d8180a	37609501-b2cd-4810-a1d5-b2a10f0405fd	1	submitted	2026-05-11 18:31:45.462661+00	2026-05-11 18:51:45.462661+00	2026-05-11 18:46:45.462661+00	4.00	5.00	85.00	t	1	0	0	[]
9f9c4092-01c5-4164-95b6-bf5057250691	79d25777-2b26-4a78-997d-828781d8180a	7fe9d01e-9282-4b4d-9377-b8b5d4c7f7d2	1	submitted	2026-08-24 18:31:45.462661+00	2026-08-24 18:51:45.462661+00	2026-08-24 18:46:45.462661+00	4.00	5.00	84.00	t	2	0	0	[]
44310a8d-6f6f-4150-9a8f-d14a9a1a6cc0	79d25777-2b26-4a78-997d-828781d8180a	216136af-8b6b-44ae-a787-59506613a618	1	submitted	2026-07-22 18:31:45.462661+00	2026-07-22 18:51:45.462661+00	2026-07-22 18:46:45.462661+00	5.00	5.00	100.00	t	1	0	0	[]
0262d0d3-09e4-4d20-ad26-5483fd8dccf2	79d25777-2b26-4a78-997d-828781d8180a	fda17094-1c9f-45de-a42c-aa815d09bc2a	1	submitted	2026-04-27 18:31:45.462661+00	2026-04-27 18:51:45.462661+00	2026-04-27 18:46:45.462661+00	5.00	5.00	94.00	t	1	0	0	[]
0104a75b-41e8-4dbe-91f0-43fb285bcae6	79d25777-2b26-4a78-997d-828781d8180a	5d9905c7-91e8-4bd9-b187-b1b8772e0f63	1	submitted	2026-05-06 18:31:45.462661+00	2026-05-06 18:51:45.462661+00	2026-05-06 18:46:45.462661+00	4.00	5.00	79.00	t	1	0	0	[]
4aeffd7a-d848-4afa-9b40-457cae723b0f	79d25777-2b26-4a78-997d-828781d8180a	feb2fb92-ce04-48c5-8a5f-9d2e832d1644	1	submitted	2026-08-07 18:31:45.462661+00	2026-08-07 18:51:45.462661+00	2026-08-07 18:46:45.462661+00	4.00	5.00	87.00	t	2	0	0	[]
74b56705-1230-4bec-bb0f-3dc98141c0a5	79d25777-2b26-4a78-997d-828781d8180a	7acc259e-1231-481b-ab79-59821fd46534	1	submitted	2026-06-18 18:31:45.462661+00	2026-06-18 18:51:45.462661+00	2026-06-18 18:46:45.462661+00	4.00	5.00	79.00	t	1	0	0	[]
789df989-166f-4caf-8bc9-0eef5e591920	79d25777-2b26-4a78-997d-828781d8180a	db9ec5a1-d0be-490d-91a6-bf32127bba75	1	submitted	2026-05-08 18:31:45.462661+00	2026-05-08 18:51:45.462661+00	2026-05-08 18:46:45.462661+00	4.00	5.00	85.00	t	0	0	0	[]
95bebb4d-b185-4f94-a13d-3b9b3247423e	79d25777-2b26-4a78-997d-828781d8180a	a6f0ed93-9d6b-4592-a13e-5435550b4db2	1	submitted	2026-03-13 18:31:45.462661+00	2026-03-13 18:51:45.462661+00	2026-03-13 18:46:45.462661+00	5.00	5.00	100.00	t	0	0	0	[]
f9df667d-c7f1-4f12-ab44-dd38cda600fc	79d25777-2b26-4a78-997d-828781d8180a	8be014b0-ed46-43db-89e2-91a301c618db	1	submitted	2026-06-15 18:31:45.462661+00	2026-06-15 18:51:45.462661+00	2026-06-15 18:46:45.462661+00	4.00	5.00	76.00	t	0	0	0	[]
bbb39624-2da1-42c3-b3d5-5627520510c9	79d25777-2b26-4a78-997d-828781d8180a	ab65843a-c349-4b21-b43b-9302ed8231b4	1	submitted	2026-08-12 18:31:45.462661+00	2026-08-12 18:51:45.462661+00	2026-08-12 18:46:45.462661+00	5.00	5.00	100.00	t	1	0	0	[]
373c00dc-c604-4ddb-acab-6d659f4efb27	79d25777-2b26-4a78-997d-828781d8180a	46e6d439-49ab-4001-b576-7df03d3babee	1	submitted	2026-08-19 18:31:45.462661+00	2026-08-19 18:51:45.462661+00	2026-08-19 18:46:45.462661+00	5.00	5.00	92.00	t	1	0	0	[]
5e302b66-b440-4403-b479-197949b8110a	10462a15-e99c-4a81-88db-80dd3b42299f	a5102b13-4107-4fe5-b7a0-064dd07042ee	1	submitted	2026-04-25 18:31:45.462661+00	2026-04-25 18:51:45.462661+00	2026-04-25 18:46:45.462661+00	4.00	5.00	83.00	t	2	0	0	[]
8a6bd218-9aa1-4518-adc7-bdccd73411ab	10462a15-e99c-4a81-88db-80dd3b42299f	a17abc66-209e-405f-bcd6-c39e54cbce66	1	submitted	2026-04-04 18:31:45.462661+00	2026-04-04 18:51:45.462661+00	2026-04-04 18:46:45.462661+00	4.00	5.00	70.00	t	3	0	0	[]
191ac445-f650-40a1-b1e1-6e35bb457dd0	10462a15-e99c-4a81-88db-80dd3b42299f	1f511b5e-1292-4202-860e-b54f11eda21e	1	submitted	2026-05-25 18:31:45.462661+00	2026-05-25 18:51:45.462661+00	2026-05-25 18:46:45.462661+00	4.00	5.00	82.00	t	0	0	0	[]
1c5664c1-7b10-4159-8b48-915c25aed8e7	10462a15-e99c-4a81-88db-80dd3b42299f	46e6d439-49ab-4001-b576-7df03d3babee	1	submitted	2026-07-27 18:31:45.462661+00	2026-07-27 18:51:45.462661+00	2026-07-27 18:46:45.462661+00	5.00	5.00	100.00	t	3	0	0	[]
ff490cce-c7c8-4504-81ea-2b9cd69982c2	10462a15-e99c-4a81-88db-80dd3b42299f	562af427-bd16-4c30-940b-5d6121d738c8	1	submitted	2026-06-24 18:31:45.462661+00	2026-06-24 18:51:45.462661+00	2026-06-24 18:46:45.462661+00	4.00	5.00	79.00	t	2	0	0	[]
3969462b-a063-4236-bc7f-67c59ed8ae1b	10462a15-e99c-4a81-88db-80dd3b42299f	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	1	submitted	2026-07-23 18:31:45.462661+00	2026-07-23 18:51:45.462661+00	2026-07-23 18:46:45.462661+00	5.00	5.00	90.00	t	1	0	0	[]
a90d066d-3a96-4ef2-bde7-81593d8b32f0	10462a15-e99c-4a81-88db-80dd3b42299f	caf34c22-6898-4c15-bde0-08f3d2634d41	1	submitted	2026-09-10 18:31:45.462661+00	2026-09-10 18:51:45.462661+00	2026-09-10 18:46:45.462661+00	4.00	5.00	84.00	t	3	0	0	[]
3a7a79ee-9d0d-414b-a195-09570836f321	10462a15-e99c-4a81-88db-80dd3b42299f	032c01d5-4b5e-44f6-821d-2ba4342c938f	1	submitted	2026-08-03 18:31:45.462661+00	2026-08-03 18:51:45.462661+00	2026-08-03 18:46:45.462661+00	5.00	5.00	91.00	t	1	0	0	[]
2bbf2063-d979-4042-94a2-2b5658ceacf8	10462a15-e99c-4a81-88db-80dd3b42299f	3e1e22ae-3497-44dc-bb66-1a3c24a5af91	1	submitted	2026-05-02 18:31:45.462661+00	2026-05-02 18:51:45.462661+00	2026-05-02 18:46:45.462661+00	4.00	5.00	88.00	t	1	0	0	[]
24c372fe-07c5-4f01-a72d-52f0c7ee09e2	10462a15-e99c-4a81-88db-80dd3b42299f	1eb0cec9-a12f-4f42-9d77-bf6e343e9a75	1	submitted	2026-07-14 18:31:45.462661+00	2026-07-14 18:51:45.462661+00	2026-07-14 18:46:45.462661+00	4.00	5.00	82.00	t	0	0	0	[]
2576b8dc-0d0b-45bf-92af-21c1a684e5b7	10462a15-e99c-4a81-88db-80dd3b42299f	e6ef6d8e-87f0-4c3d-8ac9-dccb12f222f1	1	submitted	2026-03-29 18:31:45.462661+00	2026-03-29 18:51:45.462661+00	2026-03-29 18:46:45.462661+00	5.00	5.00	100.00	t	2	0	0	[]
66aa57ba-3351-4499-8219-af5fc1b497cc	10462a15-e99c-4a81-88db-80dd3b42299f	88b2de0e-fb93-4402-98ef-3c1bd149f61d	1	submitted	2026-09-15 18:31:45.462661+00	2026-09-15 18:51:45.462661+00	2026-09-15 18:46:45.462661+00	5.00	5.00	100.00	t	1	0	0	[]
bf9d2393-a566-449f-9ca0-6a6ff1662538	10462a15-e99c-4a81-88db-80dd3b42299f	c41e7852-875f-411b-93f1-7171f9871f9f	1	submitted	2026-08-17 18:31:45.462661+00	2026-08-17 18:51:45.462661+00	2026-08-17 18:46:45.462661+00	5.00	5.00	90.00	t	1	0	0	[]
76140016-67d7-4280-8617-b993a815ce1f	10462a15-e99c-4a81-88db-80dd3b42299f	c2900748-9036-4804-b4f0-feb22ac5b4fb	1	submitted	2026-04-02 18:31:45.462661+00	2026-04-02 18:51:45.462661+00	2026-04-02 18:46:45.462661+00	5.00	5.00	94.00	t	2	0	0	[]
80e3fb12-1309-4da3-a2a3-bef65dac4328	10462a15-e99c-4a81-88db-80dd3b42299f	a8c5b60b-8763-4325-900d-07d7540e6015	1	submitted	2026-07-22 18:31:45.462661+00	2026-07-22 18:51:45.462661+00	2026-07-22 18:46:45.462661+00	5.00	5.00	92.00	t	3	0	0	[]
3d9d60c7-12e1-49ee-a482-bb10f20cd30d	10462a15-e99c-4a81-88db-80dd3b42299f	8be014b0-ed46-43db-89e2-91a301c618db	1	submitted	2026-02-27 18:31:45.462661+00	2026-02-27 18:51:45.462661+00	2026-02-27 18:46:45.462661+00	5.00	5.00	98.00	t	2	0	0	[]
8fccce9e-05d4-4c5e-84bb-c92be9e89408	10462a15-e99c-4a81-88db-80dd3b42299f	fed72080-2568-4892-8047-0b3c72ff7fad	1	submitted	2026-03-12 18:31:45.462661+00	2026-03-12 18:51:45.462661+00	2026-03-12 18:46:45.462661+00	4.00	5.00	87.00	t	1	0	0	[]
cc55a9e1-977a-4b16-b4d1-e7aa2a7cb6e7	10462a15-e99c-4a81-88db-80dd3b42299f	17231857-2d57-46f3-aecc-cb26a0865adb	1	submitted	2026-03-20 18:31:45.462661+00	2026-03-20 18:51:45.462661+00	2026-03-20 18:46:45.462661+00	4.00	5.00	83.00	t	3	0	0	[]
f3583c9f-9e53-4743-981f-9be9b407a68b	10462a15-e99c-4a81-88db-80dd3b42299f	d05292f5-3e9f-4e51-bb50-05a6534dc9b8	1	submitted	2026-06-08 18:31:45.462661+00	2026-06-08 18:51:45.462661+00	2026-06-08 18:46:45.462661+00	4.00	5.00	85.00	t	1	0	0	[]
d828e0f3-b2fc-4871-b2ec-9e4cf9f09628	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	4acb1924-e6ec-428c-8401-ac05f87e2bbf	1	submitted	2026-06-25 18:31:45.462661+00	2026-06-25 18:51:45.462661+00	2026-06-25 18:46:45.462661+00	4.00	5.00	80.00	t	3	0	0	[]
fec60973-6666-4b45-83d2-ec0f7c52e690	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	862f76a0-443e-4a80-8644-ef4922c5f38a	1	submitted	2026-03-01 18:31:45.462661+00	2026-03-01 18:51:45.462661+00	2026-03-01 18:46:45.462661+00	3.00	5.00	63.00	t	1	0	0	[]
e3e68904-793c-46e6-ab46-cc3ac6148a38	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	fed72080-2568-4892-8047-0b3c72ff7fad	1	submitted	2026-06-20 18:31:45.462661+00	2026-06-20 18:51:45.462661+00	2026-06-20 18:46:45.462661+00	4.00	5.00	85.00	t	2	0	0	[]
201a9735-8907-4c22-ba95-c8ce17881b64	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	7acc259e-1231-481b-ab79-59821fd46534	1	submitted	2026-06-30 18:31:45.462661+00	2026-06-30 18:51:45.462661+00	2026-06-30 18:46:45.462661+00	5.00	5.00	92.00	t	1	0	0	[]
cb6b9706-ca05-4e30-a3e3-3afa94fb10dc	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	8be014b0-ed46-43db-89e2-91a301c618db	1	submitted	2026-06-15 18:31:45.462661+00	2026-06-15 18:51:45.462661+00	2026-06-15 18:46:45.462661+00	5.00	5.00	92.00	t	3	0	0	[]
62cda2b1-8725-49cd-a64d-2c318db89215	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	2e35b549-e1b5-4e61-a221-b0799208258c	1	submitted	2026-09-10 18:31:45.462661+00	2026-09-10 18:51:45.462661+00	2026-09-10 18:46:45.462661+00	4.00	5.00	70.00	t	2	0	0	[]
6809517b-de9a-41a1-839c-c5d34acc845d	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	28fe79f0-6207-4e0c-8bae-1eb02eed759b	1	submitted	2026-05-07 18:31:45.462661+00	2026-05-07 18:51:45.462661+00	2026-05-07 18:46:45.462661+00	4.00	5.00	82.00	t	0	0	0	[]
d0af4548-4e38-4217-98ab-10321289263a	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	77c70aa0-ddd9-4445-be30-4817de1cbfd0	1	submitted	2026-08-10 18:31:45.462661+00	2026-08-10 18:51:45.462661+00	2026-08-10 18:46:45.462661+00	4.00	5.00	88.00	t	1	0	0	[]
d9e85669-be6a-44ea-a7fe-1f47857c464a	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	cf4749a6-6127-4d97-b2a0-17a11eabc216	1	submitted	2026-05-02 18:31:45.462661+00	2026-05-02 18:51:45.462661+00	2026-05-02 18:46:45.462661+00	3.00	5.00	69.00	t	1	0	0	[]
ce480911-55cc-4cf9-a4e1-0d00d0d15474	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	65ef229b-117d-4946-b5bb-301e3f828fc2	1	submitted	2026-09-12 18:31:45.462661+00	2026-09-12 18:51:45.462661+00	2026-09-12 18:46:45.462661+00	5.00	5.00	100.00	t	1	0	0	[]
583c283c-aefb-4d26-84d5-7b323fef330c	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	1	submitted	2026-03-05 18:31:45.462661+00	2026-03-05 18:51:45.462661+00	2026-03-05 18:46:45.462661+00	5.00	5.00	100.00	t	1	0	0	[]
48025eda-3700-4f97-9007-42e27b0293d3	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	152f1a01-df4b-4828-bf72-c1616f324c38	1	submitted	2026-06-16 18:31:45.462661+00	2026-06-16 18:51:45.462661+00	2026-06-16 18:46:45.462661+00	4.00	5.00	82.00	t	1	0	0	[]
07e59543-edf7-49d8-a99b-0335daff864b	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	293f638f-6b5e-4c5a-9282-533cc1c97688	1	submitted	2026-09-02 18:31:45.462661+00	2026-09-02 18:51:45.462661+00	2026-09-02 18:46:45.462661+00	4.00	5.00	71.00	t	0	0	0	[]
dc88cb69-c436-4984-b7a8-17961dfcd4c5	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	a17abc66-209e-405f-bcd6-c39e54cbce66	1	submitted	2026-09-12 18:31:45.462661+00	2026-09-12 18:51:45.462661+00	2026-09-12 18:46:45.462661+00	3.00	5.00	66.00	t	2	0	0	[]
067d96cb-678c-44d8-af87-86a99f4a9cf5	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	7e426fed-4c2e-46f4-866a-7b8aa048cf06	1	submitted	2026-04-02 18:31:45.462661+00	2026-04-02 18:51:45.462661+00	2026-04-02 18:46:45.462661+00	4.00	5.00	79.00	t	1	0	0	[]
6c8f5cd9-cd73-4ba0-a603-501079572a0c	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	625944b1-2b9b-433b-9af5-e72894aa7a58	1	submitted	2026-08-31 18:31:45.462661+00	2026-08-31 18:51:45.462661+00	2026-08-31 18:46:45.462661+00	4.00	5.00	70.00	t	2	0	0	[]
745427cc-7dd8-40d4-b169-49df47398bac	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	889560c5-9238-4463-82d8-b65d7fdba4bc	1	submitted	2026-08-24 18:31:45.462661+00	2026-08-24 18:51:45.462661+00	2026-08-24 18:46:45.462661+00	4.00	5.00	76.00	t	1	0	0	[]
4bdeda2a-6b39-4cff-910d-ce79bc74986c	e3215cf1-5eb2-44de-8ce1-d94482eb2d19	732e74cf-b9b7-4adc-a43a-794430d7fe49	1	submitted	2026-07-15 18:31:45.462661+00	2026-07-15 18:51:45.462661+00	2026-07-15 18:46:45.462661+00	4.00	5.00	80.00	t	0	0	0	[]
7ebbbfe4-9336-4175-864f-c68fb8b56fe1	28fbb3e6-1704-458c-a88b-1f5c3a06c404	55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	1	submitted	2026-04-05 18:31:45.462661+00	2026-04-05 18:51:45.462661+00	2026-04-05 18:46:45.462661+00	3.00	5.00	66.00	t	2	0	0	[]
2433b0b1-f891-428d-8cfa-55b3c4fc2285	28fbb3e6-1704-458c-a88b-1f5c3a06c404	ab903484-298e-4415-93b0-8f5ea844bf31	1	submitted	2026-07-05 18:31:45.462661+00	2026-07-05 18:51:45.462661+00	2026-07-05 18:46:45.462661+00	2.00	5.00	44.00	f	1	0	0	[]
1ef0f8e7-2d9b-455f-9660-cec10354841e	28fbb3e6-1704-458c-a88b-1f5c3a06c404	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	1	submitted	2026-07-27 18:31:45.462661+00	2026-07-27 18:51:45.462661+00	2026-07-27 18:46:45.462661+00	2.00	5.00	39.00	f	1	0	0	[]
1cd14285-2603-4ba7-982d-73d4c58eec63	28fbb3e6-1704-458c-a88b-1f5c3a06c404	889560c5-9238-4463-82d8-b65d7fdba4bc	1	submitted	2026-08-20 18:31:45.462661+00	2026-08-20 18:51:45.462661+00	2026-08-20 18:46:45.462661+00	3.00	5.00	51.00	f	2	0	0	[]
73b250e4-3b5d-4661-8292-f2b7348b225c	28fbb3e6-1704-458c-a88b-1f5c3a06c404	5d1e34b1-8861-4358-96e3-f5ed89f5c9d2	1	submitted	2026-04-15 18:31:45.462661+00	2026-04-15 18:51:45.462661+00	2026-04-15 18:46:45.462661+00	3.00	5.00	58.00	f	2	0	0	[]
794bee5c-04f9-440b-a0c4-4c3b830a1d40	28fbb3e6-1704-458c-a88b-1f5c3a06c404	cf4749a6-6127-4d97-b2a0-17a11eabc216	1	submitted	2026-03-14 18:31:45.462661+00	2026-03-14 18:51:45.462661+00	2026-03-14 18:46:45.462661+00	3.00	5.00	60.00	t	0	0	0	[]
5a803275-6f20-443a-af94-c86537d9913e	28fbb3e6-1704-458c-a88b-1f5c3a06c404	1e9340db-2cfd-419f-8894-9448da0bbc19	1	submitted	2026-08-10 18:31:45.462661+00	2026-08-10 18:51:45.462661+00	2026-08-10 18:46:45.462661+00	2.00	5.00	49.00	f	3	0	0	[]
85753ed3-950b-4717-bf7f-633dd1bfcda6	28fbb3e6-1704-458c-a88b-1f5c3a06c404	9bab5f84-a53e-49d6-91f8-eef87bf5960c	1	submitted	2026-03-08 18:31:45.462661+00	2026-03-08 18:51:45.462661+00	2026-03-08 18:46:45.462661+00	2.00	5.00	40.00	f	2	0	0	[]
ab2c1efb-ad2e-401f-a414-215616ef6951	28fbb3e6-1704-458c-a88b-1f5c3a06c404	350093ae-4f68-46a9-a0af-c33a9b87c340	1	submitted	2026-03-22 18:31:45.462661+00	2026-03-22 18:51:45.462661+00	2026-03-22 18:46:45.462661+00	4.00	5.00	74.00	t	2	0	0	[]
9c221bc4-7484-4386-94b8-9172004746dd	28fbb3e6-1704-458c-a88b-1f5c3a06c404	5d9905c7-91e8-4bd9-b187-b1b8772e0f63	1	submitted	2026-06-21 18:31:45.462661+00	2026-06-21 18:51:45.462661+00	2026-06-21 18:46:45.462661+00	3.00	5.00	53.00	f	0	0	0	[]
fe44957c-cf50-48c1-807d-36a703b8afe4	28fbb3e6-1704-458c-a88b-1f5c3a06c404	fda17094-1c9f-45de-a42c-aa815d09bc2a	1	submitted	2026-04-15 18:31:45.462661+00	2026-04-15 18:51:45.462661+00	2026-04-15 18:46:45.462661+00	2.00	5.00	48.00	f	2	0	0	[]
d1e741c7-41c9-4c0a-b6d9-fda2a029e8fc	28fbb3e6-1704-458c-a88b-1f5c3a06c404	d072273b-7a6f-4fa4-9195-1697050cfab1	1	submitted	2026-04-20 18:31:45.462661+00	2026-04-20 18:51:45.462661+00	2026-04-20 18:46:45.462661+00	3.00	5.00	62.00	t	2	0	0	[]
a570ab2f-9ffd-4b4b-9afc-158ff9a7e59c	28fbb3e6-1704-458c-a88b-1f5c3a06c404	b2c7b829-9669-4258-ab45-acc4445b9d6d	1	submitted	2026-07-06 18:31:45.462661+00	2026-07-06 18:51:45.462661+00	2026-07-06 18:46:45.462661+00	3.00	5.00	54.00	f	3	0	0	[]
fb4b0b1b-c525-4935-ad27-53030a2fbd4c	28fbb3e6-1704-458c-a88b-1f5c3a06c404	d2298ed0-2515-4232-b70f-845a98dac595	1	submitted	2026-02-27 18:31:45.462661+00	2026-02-27 18:51:45.462661+00	2026-02-27 18:46:45.462661+00	2.00	5.00	39.00	f	2	0	0	[]
6664e9e2-f277-4e9e-8008-2743b161bfca	28fbb3e6-1704-458c-a88b-1f5c3a06c404	2af59a77-c993-46c3-a686-b91217814d48	1	submitted	2026-05-07 18:31:45.462661+00	2026-05-07 18:51:45.462661+00	2026-05-07 18:46:45.462661+00	4.00	5.00	72.00	t	2	0	0	[]
880c7a22-215c-4bcb-9ca3-362f6c7cfbb2	28fbb3e6-1704-458c-a88b-1f5c3a06c404	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	1	submitted	2026-03-06 18:31:45.462661+00	2026-03-06 18:51:45.462661+00	2026-03-06 18:46:45.462661+00	3.00	5.00	64.00	t	1	0	0	[]
5c89b994-6c60-466e-afaa-e495d3aca025	28fbb3e6-1704-458c-a88b-1f5c3a06c404	9897dc81-824b-4829-9fda-76c3f3c3e38f	1	submitted	2026-07-17 18:31:45.462661+00	2026-07-17 18:51:45.462661+00	2026-07-17 18:46:45.462661+00	2.00	5.00	41.00	f	1	0	0	[]
d6e8e384-f8a3-4265-8b2c-1d9202690833	db3f10f5-1c12-444f-992f-9c841f18fecc	f75210c9-faa1-45c8-9314-a65724983502	1	submitted	2026-07-26 18:31:45.462661+00	2026-07-26 18:51:45.462661+00	2026-07-26 18:46:45.462661+00	5.00	5.00	100.00	t	2	0	0	[]
9d37cc94-fbc4-4e4d-9450-1c2899b4495b	db3f10f5-1c12-444f-992f-9c841f18fecc	889560c5-9238-4463-82d8-b65d7fdba4bc	1	submitted	2026-07-15 18:31:45.462661+00	2026-07-15 18:51:45.462661+00	2026-07-15 18:46:45.462661+00	5.00	5.00	98.00	t	2	0	0	[]
b051505d-8f96-4a92-877e-0ad616311145	db3f10f5-1c12-444f-992f-9c841f18fecc	fed72080-2568-4892-8047-0b3c72ff7fad	1	submitted	2026-02-25 18:31:45.462661+00	2026-02-25 18:51:45.462661+00	2026-02-25 18:46:45.462661+00	4.00	5.00	85.00	t	1	0	0	[]
7bbb7010-6410-4ca8-bed6-e83b1679378f	db3f10f5-1c12-444f-992f-9c841f18fecc	48f33e15-f87f-4629-ab82-4123ada4bdc4	1	submitted	2026-07-11 18:31:45.462661+00	2026-07-11 18:51:45.462661+00	2026-07-11 18:46:45.462661+00	4.00	5.00	78.00	t	2	0	0	[]
234c2568-589b-4d41-a9e8-fe7e05a5b7ea	db3f10f5-1c12-444f-992f-9c841f18fecc	18c4a035-c0ad-48f3-8628-30fee5e16970	1	submitted	2026-02-15 18:31:45.462661+00	2026-02-15 18:51:45.462661+00	2026-02-15 18:46:45.462661+00	5.00	5.00	100.00	t	0	0	0	[]
3b780fe4-73f9-4298-86b1-5dcea488f9b5	db3f10f5-1c12-444f-992f-9c841f18fecc	0f80298a-f569-4c55-88aa-a57625e20751	1	submitted	2026-06-20 18:31:45.462661+00	2026-06-20 18:51:45.462661+00	2026-06-20 18:46:45.462661+00	4.00	5.00	85.00	t	1	0	0	[]
99a7ffcf-add4-4b21-8e04-c6ceecda8963	db3f10f5-1c12-444f-992f-9c841f18fecc	625944b1-2b9b-433b-9af5-e72894aa7a58	1	submitted	2026-06-15 18:31:45.462661+00	2026-06-15 18:51:45.462661+00	2026-06-15 18:46:45.462661+00	5.00	5.00	100.00	t	2	0	0	[]
2064ac06-83d3-4ca2-bb5f-2d819b98905f	db3f10f5-1c12-444f-992f-9c841f18fecc	dbccc807-eaba-41f6-aabc-14c515010185	1	submitted	2026-09-09 18:31:45.462661+00	2026-09-09 18:51:45.462661+00	2026-09-09 18:46:45.462661+00	4.00	5.00	83.00	t	1	0	0	[]
5b01cd29-43ad-4547-bddb-7c02ff5af691	db3f10f5-1c12-444f-992f-9c841f18fecc	24cbfa5b-7114-43b8-957c-fe0efa420c25	1	submitted	2026-04-22 18:31:45.462661+00	2026-04-22 18:51:45.462661+00	2026-04-22 18:46:45.462661+00	5.00	5.00	91.00	t	2	0	0	[]
8d4874cb-600a-47c9-91b3-5c58b6098ba2	db3f10f5-1c12-444f-992f-9c841f18fecc	3af00a36-1f7b-4846-a52a-b1871416c5b1	1	submitted	2026-09-04 18:31:45.462661+00	2026-09-04 18:51:45.462661+00	2026-09-04 18:46:45.462661+00	4.00	5.00	86.00	t	3	0	0	[]
fafce8e6-a46f-4440-88a8-55c5a3d93ae3	db3f10f5-1c12-444f-992f-9c841f18fecc	d2298ed0-2515-4232-b70f-845a98dac595	1	submitted	2026-07-16 18:31:45.462661+00	2026-07-16 18:51:45.462661+00	2026-07-16 18:46:45.462661+00	5.00	5.00	91.00	t	2	0	0	[]
54daf771-9724-494c-bfdf-700a65c1b4af	db3f10f5-1c12-444f-992f-9c841f18fecc	d072273b-7a6f-4fa4-9195-1697050cfab1	1	submitted	2026-08-26 18:31:45.462661+00	2026-08-26 18:51:45.462661+00	2026-08-26 18:46:45.462661+00	5.00	5.00	90.00	t	2	0	0	[]
bb722768-0c36-4b3b-afc1-b267b2a126f8	db3f10f5-1c12-444f-992f-9c841f18fecc	b8541832-74c6-404f-90d0-5fb6d3df7663	1	submitted	2026-05-08 18:31:45.462661+00	2026-05-08 18:51:45.462661+00	2026-05-08 18:46:45.462661+00	5.00	5.00	100.00	t	2	0	0	[]
e18c8332-7599-49de-b6dd-7faca19b58c4	db3f10f5-1c12-444f-992f-9c841f18fecc	1e9340db-2cfd-419f-8894-9448da0bbc19	1	submitted	2026-07-24 18:31:45.462661+00	2026-07-24 18:51:45.462661+00	2026-07-24 18:46:45.462661+00	4.00	5.00	84.00	t	2	0	0	[]
7e2464ed-8db7-441a-906e-c139076a6ee2	db3f10f5-1c12-444f-992f-9c841f18fecc	fda17094-1c9f-45de-a42c-aa815d09bc2a	1	submitted	2026-02-26 18:31:45.462661+00	2026-02-26 18:51:45.462661+00	2026-02-26 18:46:45.462661+00	4.00	5.00	88.00	t	3	0	0	[]
39c95869-d319-40cf-ae2f-eb04a06b660f	db3f10f5-1c12-444f-992f-9c841f18fecc	eee6bbaa-75eb-44f4-9892-d46194b720a9	1	submitted	2026-08-27 18:31:45.462661+00	2026-08-27 18:51:45.462661+00	2026-08-27 18:46:45.462661+00	5.00	5.00	100.00	t	0	0	0	[]
86218f75-171b-4978-b015-2b325e8859c2	db3f10f5-1c12-444f-992f-9c841f18fecc	2e35b549-e1b5-4e61-a221-b0799208258c	1	submitted	2026-04-04 18:31:45.462661+00	2026-04-04 18:51:45.462661+00	2026-04-04 18:46:45.462661+00	5.00	5.00	98.00	t	3	0	0	[]
d25a7642-4c17-48a4-939f-c6f5ea643ef2	db3f10f5-1c12-444f-992f-9c841f18fecc	b0ba69f7-69ce-411c-a22d-c449785d11e9	1	submitted	2026-04-06 18:31:45.462661+00	2026-04-06 18:51:45.462661+00	2026-04-06 18:46:45.462661+00	4.00	5.00	83.00	t	1	0	0	[]
2c96387e-934e-46bf-bfd9-d42c451331c9	db3f10f5-1c12-444f-992f-9c841f18fecc	33f73596-75e6-435e-94f5-d5b111a6aaf5	1	submitted	2026-02-22 18:31:45.462661+00	2026-02-22 18:51:45.462661+00	2026-02-22 18:46:45.462661+00	4.00	5.00	89.00	t	1	0	0	[]
416509bf-eb81-4cb5-b4ef-5c1dec0fa24a	db3f10f5-1c12-444f-992f-9c841f18fecc	4ace2ecd-317e-494c-ad50-71e2794fb907	1	submitted	2026-07-15 18:31:45.462661+00	2026-07-15 18:51:45.462661+00	2026-07-15 18:46:45.462661+00	4.00	5.00	85.00	t	3	0	0	[]
367d5b80-e9e1-4ad4-83f2-4767b86cc596	db3f10f5-1c12-444f-992f-9c841f18fecc	696886f6-a4bf-44a6-9ba9-c939abb52137	1	submitted	2026-06-02 18:31:45.462661+00	2026-06-02 18:51:45.462661+00	2026-06-02 18:46:45.462661+00	4.00	5.00	84.00	t	0	0	0	[]
0377fcc1-c541-4002-b76d-d2c485edd3ff	db3f10f5-1c12-444f-992f-9c841f18fecc	f74aaa72-56ba-476d-9aed-ffbe2e41dd50	1	submitted	2026-04-13 18:31:45.462661+00	2026-04-13 18:51:45.462661+00	2026-04-13 18:46:45.462661+00	4.00	5.00	88.00	t	0	0	0	[]
0215320c-35d0-44f8-80a0-7b3fe8bfdfd6	db3f10f5-1c12-444f-992f-9c841f18fecc	60e67627-9116-4358-a94b-89c0416805f0	1	submitted	2026-09-08 18:31:45.462661+00	2026-09-08 18:51:45.462661+00	2026-09-08 18:46:45.462661+00	5.00	5.00	100.00	t	2	0	0	[]
9a4601c2-0237-4d08-9f50-0f7397139859	db3f10f5-1c12-444f-992f-9c841f18fecc	9e08ecc2-e291-4516-bae3-07b43abc2620	1	submitted	2026-03-21 18:31:45.462661+00	2026-03-21 18:51:45.462661+00	2026-03-21 18:46:45.462661+00	5.00	5.00	100.00	t	1	0	0	[]
736284d0-9584-4bcf-a11e-ef8c5893501e	db3f10f5-1c12-444f-992f-9c841f18fecc	08758984-558b-4323-bc35-2a202203d87b	1	submitted	2026-05-05 18:31:45.462661+00	2026-05-05 18:51:45.462661+00	2026-05-05 18:46:45.462661+00	4.00	5.00	80.00	t	1	0	0	[]
aa595ab9-ce8b-41aa-9b79-ce19f5def982	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	dbccc807-eaba-41f6-aabc-14c515010185	1	submitted	2026-03-05 18:31:45.462661+00	2026-03-05 18:51:45.462661+00	2026-03-05 18:46:45.462661+00	2.00	5.00	46.00	f	3	0	0	[]
c0df9db4-7cc2-40d1-8163-29cdd4c02b29	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	edc1993b-5333-4d99-bae2-9e80266978e0	1	submitted	2026-09-18 18:31:45.462661+00	2026-09-18 18:51:45.462661+00	2026-09-18 18:46:45.462661+00	3.00	5.00	53.00	f	1	0	0	[]
01402f43-451e-4713-9fb9-254db0430603	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	72a5ceb8-6b68-433d-9b99-d62b8c9f1375	1	submitted	2026-05-17 18:31:45.462661+00	2026-05-17 18:51:45.462661+00	2026-05-17 18:46:45.462661+00	2.00	5.00	48.00	f	1	0	0	[]
3e7f0746-fc88-4576-b839-504a68a365cd	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	5abfd2bf-a622-4ac2-8867-2be6525ec0e8	1	submitted	2026-03-10 18:31:45.462661+00	2026-03-10 18:51:45.462661+00	2026-03-10 18:46:45.462661+00	3.00	5.00	63.00	t	2	0	0	[]
b1452d0e-2baf-4364-83cb-708fc86508e8	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	3a18a01e-89f7-474e-abf1-964581203793	1	submitted	2026-04-21 18:31:45.462661+00	2026-04-21 18:51:45.462661+00	2026-04-21 18:46:45.462661+00	2.00	5.00	44.00	f	0	0	0	[]
2aef6b22-72bc-4639-81e7-136eb49217ae	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	8ffbd0cf-b807-4193-af37-3a61482c76eb	1	submitted	2026-06-06 18:31:45.462661+00	2026-06-06 18:51:45.462661+00	2026-06-06 18:46:45.462661+00	2.00	5.00	39.00	f	1	0	0	[]
843ba1f2-d685-4c22-baab-474439214d15	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	caf34c22-6898-4c15-bde0-08f3d2634d41	1	submitted	2026-07-23 18:31:45.462661+00	2026-07-23 18:51:45.462661+00	2026-07-23 18:46:45.462661+00	2.00	5.00	39.00	f	1	0	0	[]
d381d60a-6747-43fd-b82e-64bbd7f573df	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	b28e0245-9390-4127-ad3f-80ace4775f43	1	submitted	2026-02-20 18:31:45.462661+00	2026-02-20 18:51:45.462661+00	2026-02-20 18:46:45.462661+00	3.00	5.00	58.00	f	0	0	0	[]
0dba6e6f-a730-4309-9ad0-d5f7a34f806a	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	88b2de0e-fb93-4402-98ef-3c1bd149f61d	1	submitted	2026-03-20 18:31:45.462661+00	2026-03-20 18:51:45.462661+00	2026-03-20 18:46:45.462661+00	3.00	5.00	68.00	t	2	0	0	[]
06221b27-c766-4f46-abd6-dda31b13ed77	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	05a922f4-7a9b-427c-bd4f-34ee3bdcfcf6	1	submitted	2026-07-28 18:31:45.462661+00	2026-07-28 18:51:45.462661+00	2026-07-28 18:46:45.462661+00	2.00	5.00	35.00	f	2	0	0	[]
28caca1b-f360-4f58-ac37-893a58c4e9d5	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	a6f0ed93-9d6b-4592-a13e-5435550b4db2	1	submitted	2026-02-26 18:31:45.462661+00	2026-02-26 18:51:45.462661+00	2026-02-26 18:46:45.462661+00	2.00	5.00	41.00	f	1	0	0	[]
75f72cbe-4a25-4e90-b90c-0b469930a858	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	1f511b5e-1292-4202-860e-b54f11eda21e	1	submitted	2026-03-04 18:31:45.462661+00	2026-03-04 18:51:45.462661+00	2026-03-04 18:46:45.462661+00	3.00	5.00	50.00	f	2	0	0	[]
f1ffd969-c113-4d35-b564-8d1d74f391bb	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	bea31be8-3a44-4869-9c56-dce2da936f51	1	submitted	2026-08-25 18:31:45.462661+00	2026-08-25 18:51:45.462661+00	2026-08-25 18:46:45.462661+00	2.00	5.00	49.00	f	3	0	0	[]
5f6fa6ff-3198-44c1-bb8d-9cb4095d9bdb	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	1	submitted	2026-08-08 18:31:45.462661+00	2026-08-08 18:51:45.462661+00	2026-08-08 18:46:45.462661+00	4.00	5.00	71.00	t	0	0	0	[]
09fb3c1b-422e-4b88-96ee-6cd8f4fe8849	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	cd441b90-ef66-411c-b22e-4e046c29677f	1	submitted	2026-02-22 18:31:45.462661+00	2026-02-22 18:51:45.462661+00	2026-02-22 18:46:45.462661+00	2.00	5.00	39.00	f	1	0	0	[]
9b5c3d18-c522-436d-b85b-9dfa086ff28a	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	fbc637df-19cd-4ec5-b08d-49ce15747076	1	submitted	2026-03-06 18:31:45.462661+00	2026-03-06 18:51:45.462661+00	2026-03-06 18:46:45.462661+00	2.00	5.00	36.00	f	1	0	0	[]
7cdf79e8-930e-4bdf-9bc3-586d2e0643f5	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	0d37acee-70ea-4604-8bd7-c995941443fd	1	submitted	2026-05-07 18:31:45.462661+00	2026-05-07 18:51:45.462661+00	2026-05-07 18:46:45.462661+00	3.00	5.00	66.00	t	1	0	0	[]
5c428587-d472-4c18-a2a3-cfca872ebfbb	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	1	submitted	2026-02-19 18:31:45.462661+00	2026-02-19 18:51:45.462661+00	2026-02-19 18:46:45.462661+00	2.00	5.00	49.00	f	1	0	0	[]
fa6bcf85-9943-41ec-b82e-3f2ebb2d6bcf	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	9e08ecc2-e291-4516-bae3-07b43abc2620	1	submitted	2026-06-29 18:31:45.462661+00	2026-06-29 18:51:45.462661+00	2026-06-29 18:46:45.462661+00	3.00	5.00	69.00	t	1	0	0	[]
c36ba5c6-0271-4a8c-af85-b4b4b8e204f5	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	216136af-8b6b-44ae-a787-59506613a618	1	submitted	2026-07-04 18:31:45.462661+00	2026-07-04 18:51:45.462661+00	2026-07-04 18:46:45.462661+00	2.00	5.00	42.00	f	0	0	0	[]
76b60f30-c387-46dd-a5e4-1d5b898cb94e	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	ab903484-298e-4415-93b0-8f5ea844bf31	1	submitted	2026-02-21 18:31:45.462661+00	2026-02-21 18:51:45.462661+00	2026-02-21 18:46:45.462661+00	3.00	5.00	64.00	t	3	0	0	[]
d6635397-db4b-4ef1-80da-b02878065a9a	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	2af59a77-c993-46c3-a686-b91217814d48	1	submitted	2026-06-20 18:31:45.462661+00	2026-06-20 18:51:45.462661+00	2026-06-20 18:46:45.462661+00	2.00	5.00	43.00	f	2	0	0	[]
08505e74-aab4-4ee5-83b8-125cba5ac094	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	c41a5544-af25-44ec-9fab-26fa3a4e08a5	1	submitted	2026-06-27 18:31:45.462661+00	2026-06-27 18:51:45.462661+00	2026-06-27 18:46:45.462661+00	3.00	5.00	59.00	f	2	0	0	[]
d3aa8101-18b0-487e-809d-5179b4189f43	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	17231857-2d57-46f3-aecc-cb26a0865adb	1	submitted	2026-09-04 18:31:45.462661+00	2026-09-04 18:51:45.462661+00	2026-09-04 18:46:45.462661+00	3.00	5.00	62.00	t	1	0	0	[]
72cc8d47-d339-4168-b939-d337e7b40cc0	c8072c7c-ce50-4a0d-8d8d-e12fb914512c	fc08ec35-be50-46ec-8acb-0ddb68b16b22	1	submitted	2026-08-12 18:31:45.462661+00	2026-08-12 18:51:45.462661+00	2026-08-12 18:46:45.462661+00	3.00	5.00	69.00	t	1	0	0	[]
ec709f5d-e7e6-4be0-a1e6-918de9782395	ad278eec-06a1-4b88-b81c-5f9fd019b465	a6f0ed93-9d6b-4592-a13e-5435550b4db2	1	submitted	2026-04-28 18:31:45.462661+00	2026-04-28 18:51:45.462661+00	2026-04-28 18:46:45.462661+00	3.00	5.00	59.00	f	2	0	0	[]
d2347005-883b-41b2-b7c0-86f2a1174e33	ad278eec-06a1-4b88-b81c-5f9fd019b465	ea8fa5c6-6833-4701-9073-dd4ff3f78cb8	1	submitted	2026-04-13 18:31:45.462661+00	2026-04-13 18:51:45.462661+00	2026-04-13 18:46:45.462661+00	3.00	5.00	65.00	t	0	0	0	[]
0c70273c-7011-440a-aeca-0b4bbe2762ae	ad278eec-06a1-4b88-b81c-5f9fd019b465	72a5ceb8-6b68-433d-9b99-d62b8c9f1375	1	submitted	2026-08-30 18:31:45.462661+00	2026-08-30 18:51:45.462661+00	2026-08-30 18:46:45.462661+00	2.00	5.00	43.00	f	2	0	0	[]
2df80c56-47ae-403c-984d-ea883756cbe1	ad278eec-06a1-4b88-b81c-5f9fd019b465	30e16278-0ca1-4efa-a03b-7168658bb2c2	1	submitted	2026-04-01 18:31:45.462661+00	2026-04-01 18:51:45.462661+00	2026-04-01 18:46:45.462661+00	2.00	5.00	49.00	f	1	0	0	[]
241ceeab-d5d2-496b-80e6-0ecb7af08d3d	ad278eec-06a1-4b88-b81c-5f9fd019b465	b2734396-c5d2-4b05-99d0-986a180a98a6	1	submitted	2026-08-16 18:31:45.462661+00	2026-08-16 18:51:45.462661+00	2026-08-16 18:46:45.462661+00	3.00	5.00	51.00	f	2	0	0	[]
219e20fb-38e4-4b24-9b28-7cd05dd143fd	ad278eec-06a1-4b88-b81c-5f9fd019b465	8a1eab45-738c-41b6-b35d-7737f5e2f64e	1	submitted	2026-05-21 18:31:45.462661+00	2026-05-21 18:51:45.462661+00	2026-05-21 18:46:45.462661+00	2.00	5.00	39.00	f	2	0	0	[]
78563f46-7029-42fa-9445-7b717679c191	ad278eec-06a1-4b88-b81c-5f9fd019b465	152f1a01-df4b-4828-bf72-c1616f324c38	1	submitted	2026-02-24 18:31:45.462661+00	2026-02-24 18:51:45.462661+00	2026-02-24 18:46:45.462661+00	3.00	5.00	50.00	f	1	0	0	[]
79faed68-b745-4b9f-8d65-8c92645df4b5	ad278eec-06a1-4b88-b81c-5f9fd019b465	1f511b5e-1292-4202-860e-b54f11eda21e	1	submitted	2026-05-23 18:31:45.462661+00	2026-05-23 18:51:45.462661+00	2026-05-23 18:46:45.462661+00	3.00	5.00	61.00	t	0	0	0	[]
736837d4-cfcb-4caa-8759-efdf07f35203	ad278eec-06a1-4b88-b81c-5f9fd019b465	e44fe06d-6034-4f79-a75c-79ab0f2b58df	1	submitted	2026-08-23 18:31:45.462661+00	2026-08-23 18:51:45.462661+00	2026-08-23 18:46:45.462661+00	2.00	5.00	48.00	f	2	0	0	[]
529dfd22-3723-40d4-955d-ee728a0e37b9	ad278eec-06a1-4b88-b81c-5f9fd019b465	9e08ecc2-e291-4516-bae3-07b43abc2620	1	submitted	2026-07-18 18:31:45.462661+00	2026-07-18 18:51:45.462661+00	2026-07-18 18:46:45.462661+00	2.00	5.00	46.00	f	2	0	0	[]
a7dc4d05-5fe5-47b5-af3c-486cf66ea719	ad278eec-06a1-4b88-b81c-5f9fd019b465	d22f23cf-8a58-499a-8dba-92806f1622ef	1	submitted	2026-03-01 18:31:45.462661+00	2026-03-01 18:51:45.462661+00	2026-03-01 18:46:45.462661+00	2.00	5.00	35.00	f	3	0	0	[]
51462a62-7036-4d41-8e18-f36cd56db3af	ad278eec-06a1-4b88-b81c-5f9fd019b465	cc9e83f0-d177-4454-8ba5-f7581c6da639	1	submitted	2026-07-08 18:31:45.462661+00	2026-07-08 18:51:45.462661+00	2026-07-08 18:46:45.462661+00	3.00	5.00	66.00	t	1	0	0	[]
9d6c789f-e577-4ed4-94aa-66c31d4914a1	ad278eec-06a1-4b88-b81c-5f9fd019b465	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	1	submitted	2026-04-21 18:31:45.462661+00	2026-04-21 18:51:45.462661+00	2026-04-21 18:46:45.462661+00	3.00	5.00	65.00	t	1	0	0	[]
8c0255ad-5a91-4c60-b0fe-2e580ef33b8c	ad278eec-06a1-4b88-b81c-5f9fd019b465	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	1	submitted	2026-05-15 18:31:45.462661+00	2026-05-15 18:51:45.462661+00	2026-05-15 18:46:45.462661+00	2.00	5.00	49.00	f	3	0	0	[]
5202e286-b414-4f16-aeb1-1420e32324f3	ad278eec-06a1-4b88-b81c-5f9fd019b465	77c70aa0-ddd9-4445-be30-4817de1cbfd0	1	submitted	2026-07-27 18:31:45.462661+00	2026-07-27 18:51:45.462661+00	2026-07-27 18:46:45.462661+00	2.00	5.00	43.00	f	1	0	0	[]
ab581ef9-c42c-4c26-b217-d231ee747926	ad278eec-06a1-4b88-b81c-5f9fd019b465	4acb1924-e6ec-428c-8401-ac05f87e2bbf	1	submitted	2026-05-24 18:31:45.462661+00	2026-05-24 18:51:45.462661+00	2026-05-24 18:46:45.462661+00	3.00	5.00	56.00	f	1	0	0	[]
15017b79-57ee-48af-9785-a67aa10afb37	ad278eec-06a1-4b88-b81c-5f9fd019b465	c43722c6-7e70-49e0-acb4-ba4f953e36a8	1	submitted	2026-06-05 18:31:45.462661+00	2026-06-05 18:51:45.462661+00	2026-06-05 18:46:45.462661+00	2.00	5.00	37.00	f	2	0	0	[]
d5210b98-fddb-4668-8917-b31a4e8dac90	ad278eec-06a1-4b88-b81c-5f9fd019b465	a5102b13-4107-4fe5-b7a0-064dd07042ee	1	submitted	2026-07-25 18:31:45.462661+00	2026-07-25 18:51:45.462661+00	2026-07-25 18:46:45.462661+00	3.00	5.00	59.00	f	2	0	0	[]
b7693ce9-638d-4227-a182-152c555076b1	bd368b22-da64-4cfe-8e36-499e5f4ba544	cf4749a6-6127-4d97-b2a0-17a11eabc216	1	submitted	2026-05-05 18:31:45.462661+00	2026-05-05 18:51:45.462661+00	2026-05-05 18:46:45.462661+00	4.00	5.00	74.00	t	1	0	0	[]
d6e01ee6-6946-4ca9-8ffe-8a3b576f6794	bd368b22-da64-4cfe-8e36-499e5f4ba544	357f9f29-063f-4ff8-bdc9-6df1d8cb15b4	1	submitted	2026-09-04 18:31:45.462661+00	2026-09-04 18:51:45.462661+00	2026-09-04 18:46:45.462661+00	4.00	5.00	70.00	t	0	0	0	[]
58178ff9-2fcb-49ee-a1ab-e82b69e20945	bd368b22-da64-4cfe-8e36-499e5f4ba544	2af59a77-c993-46c3-a686-b91217814d48	1	submitted	2026-04-27 18:31:45.462661+00	2026-04-27 18:51:45.462661+00	2026-04-27 18:46:45.462661+00	5.00	5.00	90.00	t	0	0	0	[]
53150941-02af-4ac1-9edc-33c2cfe01ca1	bd368b22-da64-4cfe-8e36-499e5f4ba544	90a570b4-9441-4d8b-981d-a7fa379054d3	1	submitted	2026-09-02 18:31:45.462661+00	2026-09-02 18:51:45.462661+00	2026-09-02 18:46:45.462661+00	3.00	5.00	69.00	t	1	0	0	[]
91d3f17b-b254-4381-b91d-0a12c2318a98	bd368b22-da64-4cfe-8e36-499e5f4ba544	b28e0245-9390-4127-ad3f-80ace4775f43	1	submitted	2026-06-10 18:31:45.462661+00	2026-06-10 18:51:45.462661+00	2026-06-10 18:46:45.462661+00	3.00	5.00	66.00	t	2	0	0	[]
7ac65c96-5f0b-4c4e-bb60-f08a3e119b65	bd368b22-da64-4cfe-8e36-499e5f4ba544	4c6d827e-f3db-47d8-be22-4dc4a611c63f	1	submitted	2026-03-25 18:31:45.462661+00	2026-03-25 18:51:45.462661+00	2026-03-25 18:46:45.462661+00	3.00	5.00	61.00	t	2	0	0	[]
faa76001-6594-4eac-8d3f-7370f2248ba6	bd368b22-da64-4cfe-8e36-499e5f4ba544	2731bad6-8e73-4106-8def-3df5df76b6ea	1	submitted	2026-02-19 18:31:45.462661+00	2026-02-19 18:51:45.462661+00	2026-02-19 18:46:45.462661+00	3.00	5.00	64.00	t	1	0	0	[]
c3086a18-7a03-4b05-aae8-fb90defa5505	bd368b22-da64-4cfe-8e36-499e5f4ba544	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	1	submitted	2026-05-31 18:31:45.462661+00	2026-05-31 18:51:45.462661+00	2026-05-31 18:46:45.462661+00	4.00	5.00	89.00	t	0	0	0	[]
df300733-54c1-4d04-ada0-cfc2aa750e44	bd368b22-da64-4cfe-8e36-499e5f4ba544	4d5fd264-452f-4436-8eca-5c6c62afb143	1	submitted	2026-09-15 18:31:45.462661+00	2026-09-15 18:51:45.462661+00	2026-09-15 18:46:45.462661+00	3.00	5.00	69.00	t	3	0	0	[]
065c2c31-406d-4b06-b9ed-76cfbfc45e59	bd368b22-da64-4cfe-8e36-499e5f4ba544	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	1	submitted	2026-06-26 18:31:45.462661+00	2026-06-26 18:51:45.462661+00	2026-06-26 18:46:45.462661+00	4.00	5.00	79.00	t	1	0	0	[]
bb2ef91c-154f-4008-882a-3f9a9ded1fdd	bd368b22-da64-4cfe-8e36-499e5f4ba544	350093ae-4f68-46a9-a0af-c33a9b87c340	1	submitted	2026-09-15 18:31:45.462661+00	2026-09-15 18:51:45.462661+00	2026-09-15 18:46:45.462661+00	4.00	5.00	76.00	t	0	0	0	[]
44135787-b462-40b1-96f2-7d3ca3da0baf	bd368b22-da64-4cfe-8e36-499e5f4ba544	7f53c53d-3323-4146-8cea-01d6c38b4f77	1	submitted	2026-06-14 18:31:45.462661+00	2026-06-14 18:51:45.462661+00	2026-06-14 18:46:45.462661+00	4.00	5.00	86.00	t	1	0	0	[]
6b8ee003-8636-4d98-83e0-6405ba221a56	bd368b22-da64-4cfe-8e36-499e5f4ba544	69f12a27-893c-4791-987c-14fb10cbede4	1	submitted	2026-08-18 18:31:45.462661+00	2026-08-18 18:51:45.462661+00	2026-08-18 18:46:45.462661+00	4.00	5.00	82.00	t	2	0	0	[]
e1a48ed0-e18e-4109-90f8-50f660ddbece	bd368b22-da64-4cfe-8e36-499e5f4ba544	46e6d439-49ab-4001-b576-7df03d3babee	1	submitted	2026-09-06 18:31:45.462661+00	2026-09-06 18:51:45.462661+00	2026-09-06 18:46:45.462661+00	3.00	5.00	61.00	t	0	0	0	[]
43726335-5e84-4783-bb8b-875442e6a66f	bd368b22-da64-4cfe-8e36-499e5f4ba544	7e426fed-4c2e-46f4-866a-7b8aa048cf06	1	submitted	2026-06-24 18:31:45.462661+00	2026-06-24 18:51:45.462661+00	2026-06-24 18:46:45.462661+00	3.00	5.00	67.00	t	1	0	0	[]
ab65f6d0-6736-4c60-8bbf-094211cdd3b0	bd368b22-da64-4cfe-8e36-499e5f4ba544	9e08ecc2-e291-4516-bae3-07b43abc2620	1	submitted	2026-02-13 18:31:45.462661+00	2026-02-13 18:51:45.462661+00	2026-02-13 18:46:45.462661+00	5.00	5.00	96.00	t	2	0	0	[]
cc806ce6-7e86-446d-8641-2a97054f5aaa	bd368b22-da64-4cfe-8e36-499e5f4ba544	3a7984bc-e386-48e4-b988-7d8e086b5317	1	submitted	2026-07-26 18:31:45.462661+00	2026-07-26 18:51:45.462661+00	2026-07-26 18:46:45.462661+00	4.00	5.00	87.00	t	0	0	0	[]
ca850d41-b6f1-4dfa-a79f-4ef81783f3cc	bd368b22-da64-4cfe-8e36-499e5f4ba544	05a922f4-7a9b-427c-bd4f-34ee3bdcfcf6	1	submitted	2026-05-04 18:31:45.462661+00	2026-05-04 18:51:45.462661+00	2026-05-04 18:46:45.462661+00	5.00	5.00	94.00	t	3	0	0	[]
21da151b-bbb2-44d7-9de2-c593a70b538a	52723147-451b-4271-a35b-762a768624bd	729fd30e-9cfb-4751-bbdb-935fbbb7f994	1	submitted	2026-07-28 18:31:45.462661+00	2026-07-28 18:51:45.462661+00	2026-07-28 18:46:45.462661+00	4.00	5.00	81.00	t	1	0	0	[]
60a2d25e-2ee8-4bdf-9fa2-e16eda99be9f	52723147-451b-4271-a35b-762a768624bd	c41e7852-875f-411b-93f1-7171f9871f9f	1	submitted	2026-08-18 18:31:45.462661+00	2026-08-18 18:51:45.462661+00	2026-08-18 18:46:45.462661+00	4.00	5.00	79.00	t	1	0	0	[]
2d0d9db2-c3f4-4620-9d8c-139e132cdf13	52723147-451b-4271-a35b-762a768624bd	d072273b-7a6f-4fa4-9195-1697050cfab1	1	submitted	2026-02-16 18:31:45.462661+00	2026-02-16 18:51:45.462661+00	2026-02-16 18:46:45.462661+00	5.00	5.00	95.00	t	1	0	0	[]
71d5a2bf-9fc6-4ed0-8d09-78b125e805ba	52723147-451b-4271-a35b-762a768624bd	77c70aa0-ddd9-4445-be30-4817de1cbfd0	1	submitted	2026-05-28 18:31:45.462661+00	2026-05-28 18:51:45.462661+00	2026-05-28 18:46:45.462661+00	4.00	5.00	73.00	t	1	0	0	[]
890db292-4f29-41e7-87d5-6d6c8e3d673c	52723147-451b-4271-a35b-762a768624bd	ec4cdace-5f9a-4198-9518-7c59753a1127	1	submitted	2026-02-21 18:31:45.462661+00	2026-02-21 18:51:45.462661+00	2026-02-21 18:46:45.462661+00	5.00	5.00	100.00	t	2	0	0	[]
94632276-d71d-426a-a1e1-e6923641eec0	52723147-451b-4271-a35b-762a768624bd	8a0a7128-e6e6-4b49-8395-52723dda0b7c	1	submitted	2026-05-22 18:31:45.462661+00	2026-05-22 18:51:45.462661+00	2026-05-22 18:46:45.462661+00	4.00	5.00	87.00	t	1	0	0	[]
32ec440b-3707-42e0-b373-b4f1c2ba81c0	52723147-451b-4271-a35b-762a768624bd	216136af-8b6b-44ae-a787-59506613a618	1	submitted	2026-03-28 18:31:45.462661+00	2026-03-28 18:51:45.462661+00	2026-03-28 18:46:45.462661+00	4.00	5.00	80.00	t	1	0	0	[]
a032f0cc-6695-46df-8f2c-7ccc98ab074b	52723147-451b-4271-a35b-762a768624bd	7f53c53d-3323-4146-8cea-01d6c38b4f77	1	submitted	2026-03-23 18:31:45.462661+00	2026-03-23 18:51:45.462661+00	2026-03-23 18:46:45.462661+00	5.00	5.00	100.00	t	1	0	0	[]
7803b6bf-573f-44c5-9e0e-e0c4eb38e8b5	52723147-451b-4271-a35b-762a768624bd	8a1eab45-738c-41b6-b35d-7737f5e2f64e	1	submitted	2026-06-21 18:31:45.462661+00	2026-06-21 18:51:45.462661+00	2026-06-21 18:46:45.462661+00	5.00	5.00	100.00	t	1	0	0	[]
76f6f7fc-184a-44e7-b2d7-10bd6b48bf83	52723147-451b-4271-a35b-762a768624bd	28fe79f0-6207-4e0c-8bae-1eb02eed759b	1	submitted	2026-07-27 18:31:45.462661+00	2026-07-27 18:51:45.462661+00	2026-07-27 18:46:45.462661+00	4.00	5.00	86.00	t	0	0	0	[]
2f88d791-8319-4bfd-b644-4a8fb8741656	52723147-451b-4271-a35b-762a768624bd	3d87692f-06c1-4403-95ff-c70d1598700a	1	submitted	2026-04-14 18:31:45.462661+00	2026-04-14 18:51:45.462661+00	2026-04-14 18:46:45.462661+00	4.00	5.00	81.00	t	1	0	0	[]
277d995c-fcdd-46b9-909d-3548e7b319ed	52723147-451b-4271-a35b-762a768624bd	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	1	submitted	2026-07-31 18:31:45.462661+00	2026-07-31 18:51:45.462661+00	2026-07-31 18:46:45.462661+00	5.00	5.00	100.00	t	3	0	0	[]
0d7492b0-cd8b-45a8-89ff-b637fdca982c	52723147-451b-4271-a35b-762a768624bd	ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	1	submitted	2026-07-04 18:31:45.462661+00	2026-07-04 18:51:45.462661+00	2026-07-04 18:46:45.462661+00	4.00	5.00	83.00	t	1	0	0	[]
0eaf4648-abf8-4434-a7d4-989845b74bea	52723147-451b-4271-a35b-762a768624bd	c43722c6-7e70-49e0-acb4-ba4f953e36a8	1	submitted	2026-05-11 18:31:45.462661+00	2026-05-11 18:51:45.462661+00	2026-05-11 18:46:45.462661+00	5.00	5.00	91.00	t	2	0	0	[]
029a3472-a9ee-4ff2-9690-651f05b596ef	52723147-451b-4271-a35b-762a768624bd	7e426fed-4c2e-46f4-866a-7b8aa048cf06	1	submitted	2026-05-13 18:31:45.462661+00	2026-05-13 18:51:45.462661+00	2026-05-13 18:46:45.462661+00	4.00	5.00	78.00	t	1	0	0	[]
a5f79720-0a11-4864-aaeb-12ba7c773aac	52723147-451b-4271-a35b-762a768624bd	cbd81a81-1d5a-4273-8494-11efdd5fd354	1	submitted	2026-06-01 18:31:45.462661+00	2026-06-01 18:51:45.462661+00	2026-06-01 18:46:45.462661+00	5.00	5.00	90.00	t	1	0	0	[]
ac3d755c-f1e7-43bf-a2e0-7987178c874e	52723147-451b-4271-a35b-762a768624bd	e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	1	submitted	2026-03-16 18:31:45.462661+00	2026-03-16 18:51:45.462661+00	2026-03-16 18:46:45.462661+00	5.00	5.00	100.00	t	2	0	0	[]
e738b95a-17a6-4666-b53b-56876f97b565	52723147-451b-4271-a35b-762a768624bd	fafec148-becc-4918-b1e0-08794a94f6de	1	submitted	2026-06-04 18:31:45.462661+00	2026-06-04 18:51:45.462661+00	2026-06-04 18:46:45.462661+00	5.00	5.00	97.00	t	2	0	0	[]
cd46d047-1dee-4d08-957d-4920e722fe6f	52723147-451b-4271-a35b-762a768624bd	0d37acee-70ea-4604-8bd7-c995941443fd	1	submitted	2026-09-20 18:31:45.462661+00	2026-09-20 18:51:45.462661+00	2026-09-20 18:46:45.462661+00	5.00	5.00	100.00	t	0	0	0	[]
960f81ab-1573-4bb1-a76d-7f8da6122b35	52723147-451b-4271-a35b-762a768624bd	625944b1-2b9b-433b-9af5-e72894aa7a58	1	submitted	2026-05-02 18:31:45.462661+00	2026-05-02 18:51:45.462661+00	2026-05-02 18:46:45.462661+00	4.00	5.00	73.00	t	2	0	0	[]
3d77b52b-6bff-4bda-b730-b39244f985c5	52723147-451b-4271-a35b-762a768624bd	4ead5d1f-209d-4c0f-950b-80d8668a696b	1	submitted	2026-02-19 18:31:45.462661+00	2026-02-19 18:51:45.462661+00	2026-02-19 18:46:45.462661+00	5.00	5.00	96.00	t	3	0	0	[]
5d4ae948-cc4f-4bf4-a72b-83088a8f3d4a	52723147-451b-4271-a35b-762a768624bd	4135122d-a240-499c-8de4-3db650d7acc9	1	submitted	2026-06-30 18:31:45.462661+00	2026-06-30 18:51:45.462661+00	2026-06-30 18:46:45.462661+00	5.00	5.00	100.00	t	3	0	0	[]
3d07f592-4f20-4458-a0fb-38f3d0dcb695	52723147-451b-4271-a35b-762a768624bd	9389e5a2-816f-4e52-950b-a9af117c7ad1	1	submitted	2026-06-25 18:31:45.462661+00	2026-06-25 18:51:45.462661+00	2026-06-25 18:46:45.462661+00	5.00	5.00	100.00	t	2	0	0	[]
af5ca0ca-9886-4bf7-b630-b5c62b9d6417	52723147-451b-4271-a35b-762a768624bd	d2298ed0-2515-4232-b70f-845a98dac595	1	submitted	2026-02-13 18:31:45.462661+00	2026-02-13 18:51:45.462661+00	2026-02-13 18:46:45.462661+00	4.00	5.00	84.00	t	3	0	0	[]
570f8538-7110-45a5-93e0-6f0b5e243526	614db995-5b9a-418f-a799-6ef6753b242a	286bd41d-35d4-4b43-b05b-8548dab978ab	1	submitted	2026-03-19 18:31:45.462661+00	2026-03-19 18:51:45.462661+00	2026-03-19 18:46:45.462661+00	2.00	5.00	49.00	f	1	0	0	[]
c2245fb0-ea89-42a0-a75e-a3ead9d7432f	614db995-5b9a-418f-a799-6ef6753b242a	3a7984bc-e386-48e4-b988-7d8e086b5317	1	submitted	2026-06-26 18:31:45.462661+00	2026-06-26 18:51:45.462661+00	2026-06-26 18:46:45.462661+00	2.00	5.00	34.00	f	2	0	0	[]
3afa1611-d2f7-40bd-bb59-a57c500591b7	614db995-5b9a-418f-a799-6ef6753b242a	feb2fb92-ce04-48c5-8a5f-9d2e832d1644	1	submitted	2026-03-17 18:31:45.462661+00	2026-03-17 18:51:45.462661+00	2026-03-17 18:46:45.462661+00	2.00	5.00	48.00	f	3	0	0	[]
4de157d2-0251-400c-9349-fc8c6d3b00fd	614db995-5b9a-418f-a799-6ef6753b242a	7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	1	submitted	2026-08-20 18:31:45.462661+00	2026-08-20 18:51:45.462661+00	2026-08-20 18:46:45.462661+00	3.00	5.00	62.00	t	2	0	0	[]
eff5de9a-0155-4b17-94b3-960031e772ae	614db995-5b9a-418f-a799-6ef6753b242a	032c01d5-4b5e-44f6-821d-2ba4342c938f	1	submitted	2026-04-12 18:31:45.462661+00	2026-04-12 18:51:45.462661+00	2026-04-12 18:46:45.462661+00	2.00	5.00	45.00	f	0	0	0	[]
07db4ee9-d99f-42e5-bfd3-2bdd52592b22	614db995-5b9a-418f-a799-6ef6753b242a	55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	1	submitted	2026-03-02 18:31:45.462661+00	2026-03-02 18:51:45.462661+00	2026-03-02 18:46:45.462661+00	1.00	5.00	11.00	f	3	0	0	[]
757fe09f-ba6d-4cec-b23e-ffda9a6efb8c	614db995-5b9a-418f-a799-6ef6753b242a	1f511b5e-1292-4202-860e-b54f11eda21e	1	submitted	2026-09-20 18:31:45.462661+00	2026-09-20 18:51:45.462661+00	2026-09-20 18:46:45.462661+00	3.00	5.00	63.00	t	2	0	0	[]
21a40070-ab0b-48db-abe3-ba75ac79efcc	614db995-5b9a-418f-a799-6ef6753b242a	6d6f1209-693c-409d-9587-ed4e04d77930	1	submitted	2026-06-05 18:31:45.462661+00	2026-06-05 18:51:45.462661+00	2026-06-05 18:46:45.462661+00	1.00	5.00	14.00	f	2	0	0	[]
0604c45c-49f8-4889-a9d8-6ec038599211	614db995-5b9a-418f-a799-6ef6753b242a	b2c7b829-9669-4258-ab45-acc4445b9d6d	1	submitted	2026-04-11 18:31:45.462661+00	2026-04-11 18:51:45.462661+00	2026-04-11 18:46:45.462661+00	3.00	5.00	52.00	f	1	0	0	[]
f8b3bcbc-e323-43a5-8c55-b5febc228219	614db995-5b9a-418f-a799-6ef6753b242a	2731bad6-8e73-4106-8def-3df5df76b6ea	1	submitted	2026-07-23 18:31:45.462661+00	2026-07-23 18:51:45.462661+00	2026-07-23 18:46:45.462661+00	1.00	5.00	16.00	f	1	0	0	[]
4df1eba3-6ed6-4a06-881a-0e5dc084a931	614db995-5b9a-418f-a799-6ef6753b242a	cd441b90-ef66-411c-b22e-4e046c29677f	1	submitted	2026-05-06 18:31:45.462661+00	2026-05-06 18:51:45.462661+00	2026-05-06 18:46:45.462661+00	3.00	5.00	50.00	f	3	0	0	[]
635c2527-d414-4185-8444-ea9a7b02f9a4	614db995-5b9a-418f-a799-6ef6753b242a	8a83194a-d3bc-49dd-8594-ed05a26d23a0	1	submitted	2026-04-03 18:31:45.462661+00	2026-04-03 18:51:45.462661+00	2026-04-03 18:46:45.462661+00	2.00	5.00	43.00	f	0	0	0	[]
09f7880b-504f-4f43-9ae1-a11e072107aa	614db995-5b9a-418f-a799-6ef6753b242a	90a570b4-9441-4d8b-981d-a7fa379054d3	1	submitted	2026-03-04 18:31:45.462661+00	2026-03-04 18:51:45.462661+00	2026-03-04 18:46:45.462661+00	1.00	5.00	26.00	f	0	0	0	[]
f103a2ff-faef-43a0-9755-26ae6f2a9ae0	614db995-5b9a-418f-a799-6ef6753b242a	f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d	1	submitted	2026-04-05 18:31:45.462661+00	2026-04-05 18:51:45.462661+00	2026-04-05 18:46:45.462661+00	3.00	5.00	65.00	t	2	0	0	[]
94c41096-b48f-4433-b56c-7a02f65f44e2	614db995-5b9a-418f-a799-6ef6753b242a	8a1eab45-738c-41b6-b35d-7737f5e2f64e	1	submitted	2026-09-09 18:31:45.462661+00	2026-09-09 18:51:45.462661+00	2026-09-09 18:46:45.462661+00	3.00	5.00	59.00	f	2	0	0	[]
531c5338-6f5a-4194-a4a1-6226340bea1d	614db995-5b9a-418f-a799-6ef6753b242a	6f9f3af8-fa88-4804-aa9b-5680afa4c1ba	1	submitted	2026-04-02 18:31:45.462661+00	2026-04-02 18:51:45.462661+00	2026-04-02 18:46:45.462661+00	2.00	5.00	42.00	f	2	0	0	[]
656e515e-1a49-4850-b9b7-3ce97c57c38b	614db995-5b9a-418f-a799-6ef6753b242a	7b68a9ad-6ab1-4164-89e4-b13eea948a92	1	submitted	2026-05-11 18:31:45.462661+00	2026-05-11 18:51:45.462661+00	2026-05-11 18:46:45.462661+00	3.00	5.00	55.00	f	1	0	0	[]
87ff4b60-8b72-4af7-9f72-c1926f9b2201	614db995-5b9a-418f-a799-6ef6753b242a	edc1993b-5333-4d99-bae2-9e80266978e0	1	submitted	2026-02-25 18:31:45.462661+00	2026-02-25 18:51:45.462661+00	2026-02-25 18:46:45.462661+00	1.00	5.00	10.00	f	2	0	0	[]
7c08e239-71e2-4705-8ab4-42877dfb5aa5	614db995-5b9a-418f-a799-6ef6753b242a	a17abc66-209e-405f-bcd6-c39e54cbce66	1	submitted	2026-09-03 18:31:45.462661+00	2026-09-03 18:51:45.462661+00	2026-09-03 18:46:45.462661+00	3.00	5.00	50.00	f	2	0	0	[]
e3dd4691-b26d-43b3-ae71-9f978e5c4d8f	614db995-5b9a-418f-a799-6ef6753b242a	bd78a83d-5740-4d0d-9000-cdf29d332f27	1	submitted	2026-06-12 18:31:45.462661+00	2026-06-12 18:51:45.462661+00	2026-06-12 18:46:45.462661+00	1.00	5.00	29.00	f	1	0	0	[]
2c9a76db-3479-458c-a6e3-b4cdf9c9d22e	614db995-5b9a-418f-a799-6ef6753b242a	62868b88-e860-457b-8605-04153588489b	1	submitted	2026-07-13 18:31:45.462661+00	2026-07-13 18:51:45.462661+00	2026-07-13 18:46:45.462661+00	2.00	5.00	44.00	f	0	0	0	[]
01358672-a90d-4d77-bd30-bedba218fa45	5b8e9be4-2660-4118-950d-6b6aff6c5136	9bab5f84-a53e-49d6-91f8-eef87bf5960c	1	submitted	2026-05-12 18:31:45.462661+00	2026-05-12 18:51:45.462661+00	2026-05-12 18:46:45.462661+00	4.00	5.00	70.00	t	1	0	0	[]
60492017-9eb5-4ed7-a2fc-dfb20740d2e2	5b8e9be4-2660-4118-950d-6b6aff6c5136	3b6030a2-3993-4389-8c6c-d3427e0e680b	1	submitted	2026-08-10 18:31:45.462661+00	2026-08-10 18:51:45.462661+00	2026-08-10 18:46:45.462661+00	5.00	5.00	96.00	t	0	0	0	[]
18ed7214-8371-47f4-81d0-619abc7d8e4c	5b8e9be4-2660-4118-950d-6b6aff6c5136	3d87692f-06c1-4403-95ff-c70d1598700a	1	submitted	2026-04-10 18:31:45.462661+00	2026-04-10 18:51:45.462661+00	2026-04-10 18:46:45.462661+00	4.00	5.00	75.00	t	2	0	0	[]
d566881d-65f5-4ed8-adf5-6e362e858623	5b8e9be4-2660-4118-950d-6b6aff6c5136	a17abc66-209e-405f-bcd6-c39e54cbce66	1	submitted	2026-05-17 18:31:45.462661+00	2026-05-17 18:51:45.462661+00	2026-05-17 18:46:45.462661+00	4.00	5.00	86.00	t	1	0	0	[]
f95171ff-82f0-417b-b616-7ac5fb12f949	5b8e9be4-2660-4118-950d-6b6aff6c5136	9389e5a2-816f-4e52-950b-a9af117c7ad1	1	submitted	2026-05-19 18:31:45.462661+00	2026-05-19 18:51:45.462661+00	2026-05-19 18:46:45.462661+00	5.00	5.00	100.00	t	0	0	0	[]
38ea06cb-46ea-40f1-afab-8c8a0e4c07ef	5b8e9be4-2660-4118-950d-6b6aff6c5136	a5e41a1c-9682-4873-8924-f11edf9b3fce	1	submitted	2026-03-03 18:31:45.462661+00	2026-03-03 18:51:45.462661+00	2026-03-03 18:46:45.462661+00	4.00	5.00	70.00	t	1	0	0	[]
5ba9f6d3-aade-44cd-ba42-ea1882b5afe0	5b8e9be4-2660-4118-950d-6b6aff6c5136	4acb1924-e6ec-428c-8401-ac05f87e2bbf	1	submitted	2026-08-12 18:31:45.462661+00	2026-08-12 18:51:45.462661+00	2026-08-12 18:46:45.462661+00	5.00	5.00	97.00	t	0	0	0	[]
673a7e56-db8c-4c65-95e0-849a2ae75195	5b8e9be4-2660-4118-950d-6b6aff6c5136	d05292f5-3e9f-4e51-bb50-05a6534dc9b8	1	submitted	2026-07-04 18:31:45.462661+00	2026-07-04 18:51:45.462661+00	2026-07-04 18:46:45.462661+00	4.00	5.00	78.00	t	0	0	0	[]
7d243c80-8117-4029-a02d-b7abd437b2ff	5b8e9be4-2660-4118-950d-6b6aff6c5136	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	1	submitted	2026-02-13 18:31:45.462661+00	2026-02-13 18:51:45.462661+00	2026-02-13 18:46:45.462661+00	4.00	5.00	73.00	t	1	0	0	[]
8c6e2524-986d-48e0-9490-3615a819a12c	5b8e9be4-2660-4118-950d-6b6aff6c5136	30e16278-0ca1-4efa-a03b-7168658bb2c2	1	submitted	2026-08-17 18:31:45.462661+00	2026-08-17 18:51:45.462661+00	2026-08-17 18:46:45.462661+00	4.00	5.00	86.00	t	1	0	0	[]
6e7c7247-7edb-4943-bd08-0032afff753d	5b8e9be4-2660-4118-950d-6b6aff6c5136	b010ad34-1872-4015-9120-b4d6e175bda3	1	submitted	2026-09-06 18:31:45.462661+00	2026-09-06 18:51:45.462661+00	2026-09-06 18:46:45.462661+00	5.00	5.00	99.00	t	2	0	0	[]
65e98fbb-0e19-4c60-8f85-400bc593914c	5b8e9be4-2660-4118-950d-6b6aff6c5136	88b2de0e-fb93-4402-98ef-3c1bd149f61d	1	submitted	2026-06-03 18:31:45.462661+00	2026-06-03 18:51:45.462661+00	2026-06-03 18:46:45.462661+00	4.00	5.00	70.00	t	1	0	0	[]
86d81f68-7fcf-4ae7-98d7-c556e85cb52c	5b8e9be4-2660-4118-950d-6b6aff6c5136	f1831789-130e-485d-bc67-67fe3b5fc6af	1	submitted	2026-05-21 18:31:45.462661+00	2026-05-21 18:51:45.462661+00	2026-05-21 18:46:45.462661+00	4.00	5.00	72.00	t	2	0	0	[]
0c20b62e-1c47-4cc4-a587-d0c6bd46a3eb	5b8e9be4-2660-4118-950d-6b6aff6c5136	a5fd318c-feeb-4b1b-b739-3e40a59dde18	1	submitted	2026-06-30 18:31:45.462661+00	2026-06-30 18:51:45.462661+00	2026-06-30 18:46:45.462661+00	3.00	5.00	69.00	t	1	0	0	[]
c3f53a25-2b43-44a8-a3f3-6e91ac1a1a00	5b8e9be4-2660-4118-950d-6b6aff6c5136	ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	1	submitted	2026-06-10 18:31:45.462661+00	2026-06-10 18:51:45.462661+00	2026-06-10 18:46:45.462661+00	5.00	5.00	95.00	t	1	0	0	[]
c9078127-77c3-4871-b97f-e22a01ef15fc	5b8e9be4-2660-4118-950d-6b6aff6c5136	286bd41d-35d4-4b43-b05b-8548dab978ab	1	submitted	2026-09-03 18:31:45.462661+00	2026-09-03 18:51:45.462661+00	2026-09-03 18:46:45.462661+00	4.00	5.00	83.00	t	3	0	0	[]
e5fd9086-86ca-49e2-b888-ad853965863a	5b8e9be4-2660-4118-950d-6b6aff6c5136	6b116d7e-84ed-47de-81ea-2bd42ea50968	1	submitted	2026-04-27 18:31:45.462661+00	2026-04-27 18:51:45.462661+00	2026-04-27 18:46:45.462661+00	4.00	5.00	82.00	t	1	0	0	[]
1643ae8b-f048-424c-8ba4-b3ce00ce9b0a	5b8e9be4-2660-4118-950d-6b6aff6c5136	312e5b6a-024a-4a5d-9389-357b73426d42	1	submitted	2026-03-22 18:31:45.462661+00	2026-03-22 18:51:45.462661+00	2026-03-22 18:46:45.462661+00	4.00	5.00	82.00	t	2	0	0	[]
59a049dc-ea7c-4683-942c-cea0d38755e0	5b8e9be4-2660-4118-950d-6b6aff6c5136	732e74cf-b9b7-4adc-a43a-794430d7fe49	1	submitted	2026-02-17 18:31:45.462661+00	2026-02-17 18:51:45.462661+00	2026-02-17 18:46:45.462661+00	5.00	5.00	96.00	t	1	0	0	[]
1fc84261-301c-4bf9-af07-c550453b47b8	5b8e9be4-2660-4118-950d-6b6aff6c5136	cc7120df-7364-4284-a971-893f524d1a25	1	submitted	2026-08-04 18:31:45.462661+00	2026-08-04 18:51:45.462661+00	2026-08-04 18:46:45.462661+00	4.00	5.00	72.00	t	3	0	0	[]
73e1197a-bcc7-4172-a176-9af1206e4831	5b8e9be4-2660-4118-950d-6b6aff6c5136	c41a5544-af25-44ec-9fab-26fa3a4e08a5	1	submitted	2026-08-27 18:31:45.462661+00	2026-08-27 18:51:45.462661+00	2026-08-27 18:46:45.462661+00	4.00	5.00	79.00	t	0	0	0	[]
62c94333-5900-425f-b22e-2911c484fd4a	5b8e9be4-2660-4118-950d-6b6aff6c5136	f51dbbc6-5c8a-487d-b785-786417797dc8	1	submitted	2026-03-18 18:31:45.462661+00	2026-03-18 18:51:45.462661+00	2026-03-18 18:46:45.462661+00	3.00	5.00	68.00	t	0	0	0	[]
0981c831-05cc-4961-aefb-2be0cd0edc7d	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	a8c5b60b-8763-4325-900d-07d7540e6015	1	submitted	2026-08-05 18:31:45.462661+00	2026-08-05 18:51:45.462661+00	2026-08-05 18:46:45.462661+00	2.00	5.00	43.00	f	0	0	0	[]
72cc20de-2e5c-46d5-bedd-b2bf82a85942	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	1	submitted	2026-08-25 18:31:45.462661+00	2026-08-25 18:51:45.462661+00	2026-08-25 18:46:45.462661+00	2.00	5.00	48.00	f	1	0	0	[]
728d825c-84a3-4be9-bfa7-b0063661c673	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	8ffbd0cf-b807-4193-af37-3a61482c76eb	1	submitted	2026-09-12 18:31:45.462661+00	2026-09-12 18:51:45.462661+00	2026-09-12 18:46:45.462661+00	4.00	5.00	70.00	t	2	0	0	[]
630dff74-d72c-4b09-8d2d-7a77d337bb84	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	f74aaa72-56ba-476d-9aed-ffbe2e41dd50	1	submitted	2026-03-04 18:31:45.462661+00	2026-03-04 18:51:45.462661+00	2026-03-04 18:46:45.462661+00	3.00	5.00	61.00	t	2	0	0	[]
548a394e-4162-406a-9fc9-6cf1f1a4267a	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	6f1d6dd6-daa9-4660-a06f-527bf32f663e	1	submitted	2026-05-17 18:31:45.462661+00	2026-05-17 18:51:45.462661+00	2026-05-17 18:46:45.462661+00	2.00	5.00	45.00	f	1	0	0	[]
6c7720ee-1449-4763-9464-4f0426744ed9	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	8be014b0-ed46-43db-89e2-91a301c618db	1	submitted	2026-08-07 18:31:45.462661+00	2026-08-07 18:51:45.462661+00	2026-08-07 18:46:45.462661+00	4.00	5.00	73.00	t	2	0	0	[]
b56e1988-d704-4f12-acdc-ebb26336fae5	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	b0ba69f7-69ce-411c-a22d-c449785d11e9	1	submitted	2026-06-12 18:31:45.462661+00	2026-06-12 18:51:45.462661+00	2026-06-12 18:46:45.462661+00	4.00	5.00	73.00	t	2	0	0	[]
65cb1c86-81d2-45ec-aa3e-cfc07c3d6f6a	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	7b68a9ad-6ab1-4164-89e4-b13eea948a92	1	submitted	2026-03-03 18:31:45.462661+00	2026-03-03 18:51:45.462661+00	2026-03-03 18:46:45.462661+00	2.00	5.00	44.00	f	2	0	0	[]
bccf4cfb-581d-4930-b376-d619c985b2e1	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	62868b88-e860-457b-8605-04153588489b	1	submitted	2026-03-02 18:31:45.462661+00	2026-03-02 18:51:45.462661+00	2026-03-02 18:46:45.462661+00	3.00	5.00	55.00	f	1	0	0	[]
2f3f23f9-05e5-4400-9cdc-580d0994160b	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	4135122d-a240-499c-8de4-3db650d7acc9	1	submitted	2026-08-09 18:31:45.462661+00	2026-08-09 18:51:45.462661+00	2026-08-09 18:46:45.462661+00	2.00	5.00	45.00	f	1	0	0	[]
5d81e0cd-2457-4222-968e-66d98988efe9	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	76e808de-304b-44e5-b793-8516b5fec7bb	1	submitted	2026-06-13 18:31:45.462661+00	2026-06-13 18:51:45.462661+00	2026-06-13 18:46:45.462661+00	3.00	5.00	53.00	f	0	0	0	[]
d989a005-854f-4312-8af5-eb1a90823606	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	e6ef6d8e-87f0-4c3d-8ac9-dccb12f222f1	1	submitted	2026-08-18 18:31:45.462661+00	2026-08-18 18:51:45.462661+00	2026-08-18 18:46:45.462661+00	3.00	5.00	64.00	t	2	0	0	[]
e91c0d27-070c-4a75-8ca8-024a3cb3b187	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	cc9e83f0-d177-4454-8ba5-f7581c6da639	1	submitted	2026-06-27 18:31:45.462661+00	2026-06-27 18:51:45.462661+00	2026-06-27 18:46:45.462661+00	3.00	5.00	69.00	t	2	0	0	[]
d7e7101d-ffe3-4350-ab2a-1c057eea1485	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	5d1e34b1-8861-4358-96e3-f5ed89f5c9d2	1	submitted	2026-03-19 18:31:45.462661+00	2026-03-19 18:51:45.462661+00	2026-03-19 18:46:45.462661+00	2.00	5.00	43.00	f	3	0	0	[]
11be6a18-e4aa-46c7-9359-3bdb3c93a36d	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	3260915b-2633-418b-997d-2beabd07ed2b	1	submitted	2026-07-20 18:31:45.462661+00	2026-07-20 18:51:45.462661+00	2026-07-20 18:46:45.462661+00	4.00	5.00	72.00	t	2	0	0	[]
5d7dd423-db43-4154-b8a2-18d445341560	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	8b09383e-447b-4fa0-b605-8d8cf4f3f527	1	submitted	2026-07-05 18:31:45.462661+00	2026-07-05 18:51:45.462661+00	2026-07-05 18:46:45.462661+00	3.00	5.00	57.00	f	3	0	0	[]
254fe28f-842b-4642-884b-8ac723958f4d	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	4c6d827e-f3db-47d8-be22-4dc4a611c63f	1	submitted	2026-06-24 18:31:45.462661+00	2026-06-24 18:51:45.462661+00	2026-06-24 18:46:45.462661+00	4.00	5.00	78.00	t	1	0	0	[]
7dd26752-8900-4880-a2a3-bb51cffc5bfc	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	1	submitted	2026-07-08 18:31:45.462661+00	2026-07-08 18:51:45.462661+00	2026-07-08 18:46:45.462661+00	4.00	5.00	78.00	t	0	0	0	[]
1a39c4b0-fa08-4382-abfe-76648a846fd8	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	4ace2ecd-317e-494c-ad50-71e2794fb907	1	submitted	2026-04-26 18:31:45.462661+00	2026-04-26 18:51:45.462661+00	2026-04-26 18:46:45.462661+00	2.00	5.00	48.00	f	2	0	0	[]
9ad92a7f-5c56-4a45-a3a8-de309269396e	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	d072273b-7a6f-4fa4-9195-1697050cfab1	1	submitted	2026-09-19 18:31:45.462661+00	2026-09-19 18:51:45.462661+00	2026-09-19 18:46:45.462661+00	3.00	5.00	50.00	f	3	0	0	[]
836ee17d-f4a1-4017-84ee-eb299d14d6d0	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	696886f6-a4bf-44a6-9ba9-c939abb52137	1	submitted	2026-08-23 18:31:45.462661+00	2026-08-23 18:51:45.462661+00	2026-08-23 18:46:45.462661+00	2.00	5.00	44.00	f	1	0	0	[]
7f5b16af-d1f2-4e20-9464-c8cca2a24706	76f1bb98-1c74-4ce7-acd7-e430cf6e75ef	6ec3f843-359c-4b5b-bc41-b3bd56c6e134	1	submitted	2026-02-22 18:31:45.462661+00	2026-02-22 18:51:45.462661+00	2026-02-22 18:46:45.462661+00	3.00	5.00	63.00	t	0	0	0	[]
aa08953f-c084-494c-81ba-bbcb1b7752e6	f9563acd-17e6-4ac9-90cb-98090139e03e	f75210c9-faa1-45c8-9314-a65724983502	1	submitted	2026-04-10 18:31:45.462661+00	2026-04-10 18:51:45.462661+00	2026-04-10 18:46:45.462661+00	4.00	5.00	80.00	t	1	0	0	[]
dad80211-b5ab-47c9-9c18-938fca9f1adc	f9563acd-17e6-4ac9-90cb-98090139e03e	cf4749a6-6127-4d97-b2a0-17a11eabc216	1	submitted	2026-09-13 18:31:45.462661+00	2026-09-13 18:51:45.462661+00	2026-09-13 18:46:45.462661+00	3.00	5.00	57.00	f	2	0	0	[]
bff25bdd-4842-434d-847d-e42139c190fc	f9563acd-17e6-4ac9-90cb-98090139e03e	a5fd318c-feeb-4b1b-b739-3e40a59dde18	1	submitted	2026-05-12 18:31:45.462661+00	2026-05-12 18:51:45.462661+00	2026-05-12 18:46:45.462661+00	3.00	5.00	66.00	t	2	0	0	[]
7c51e9de-ebfb-49b9-8e06-6c4fdff17098	f9563acd-17e6-4ac9-90cb-98090139e03e	a6afe850-9547-4fac-892c-00558ad8f725	1	submitted	2026-06-18 18:31:45.462661+00	2026-06-18 18:51:45.462661+00	2026-06-18 18:46:45.462661+00	4.00	5.00	75.00	t	3	0	0	[]
2900909f-2ade-4884-bb83-5ab4223c25e0	f9563acd-17e6-4ac9-90cb-98090139e03e	b97db5e7-dca3-4f88-8318-6d457e09be91	1	submitted	2026-05-12 18:31:45.462661+00	2026-05-12 18:51:45.462661+00	2026-05-12 18:46:45.462661+00	4.00	5.00	80.00	t	3	0	0	[]
d00d533a-d601-4c1a-9e89-68014d0ea39e	f9563acd-17e6-4ac9-90cb-98090139e03e	48ae8c9d-e783-46c2-abf3-cc9d31e16d81	1	submitted	2026-04-22 18:31:45.462661+00	2026-04-22 18:51:45.462661+00	2026-04-22 18:46:45.462661+00	3.00	5.00	57.00	f	1	0	0	[]
876c1b23-f31d-4640-b1f2-8e91b4c33fd7	f9563acd-17e6-4ac9-90cb-98090139e03e	ec4cdace-5f9a-4198-9518-7c59753a1127	1	submitted	2026-09-12 18:31:45.462661+00	2026-09-12 18:51:45.462661+00	2026-09-12 18:46:45.462661+00	3.00	5.00	59.00	f	3	0	0	[]
3c46567c-8406-46c1-b31b-592c0d1569fb	f9563acd-17e6-4ac9-90cb-98090139e03e	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	1	submitted	2026-08-06 18:31:45.462661+00	2026-08-06 18:51:45.462661+00	2026-08-06 18:46:45.462661+00	3.00	5.00	60.00	t	2	0	0	[]
11131817-1236-4bf7-bfcb-8b51b4fd152e	f9563acd-17e6-4ac9-90cb-98090139e03e	625944b1-2b9b-433b-9af5-e72894aa7a58	1	submitted	2026-07-26 18:31:45.462661+00	2026-07-26 18:51:45.462661+00	2026-07-26 18:46:45.462661+00	3.00	5.00	55.00	f	1	0	0	[]
b0a22fae-d907-4096-8cc8-b9daa794f4cf	f9563acd-17e6-4ac9-90cb-98090139e03e	b2734396-c5d2-4b05-99d0-986a180a98a6	1	submitted	2026-06-06 18:31:45.462661+00	2026-06-06 18:51:45.462661+00	2026-06-06 18:46:45.462661+00	4.00	5.00	75.00	t	2	0	0	[]
32675f3d-f4b8-4415-b249-1406b5f6a9e0	f9563acd-17e6-4ac9-90cb-98090139e03e	3d04f1c2-2486-4f53-bde5-76ba389ec266	1	submitted	2026-03-31 18:31:45.462661+00	2026-03-31 18:51:45.462661+00	2026-03-31 18:46:45.462661+00	3.00	5.00	60.00	t	2	0	0	[]
ca731e08-f080-4119-b0e2-fbea16f8d5c7	f9563acd-17e6-4ac9-90cb-98090139e03e	e44fe06d-6034-4f79-a75c-79ab0f2b58df	1	submitted	2026-02-16 18:31:45.462661+00	2026-02-16 18:51:45.462661+00	2026-02-16 18:46:45.462661+00	3.00	5.00	51.00	f	3	0	0	[]
894f7001-bfbd-4c68-a197-bba205774444	f9563acd-17e6-4ac9-90cb-98090139e03e	3a18a01e-89f7-474e-abf1-964581203793	1	submitted	2026-09-03 18:31:45.462661+00	2026-09-03 18:51:45.462661+00	2026-09-03 18:46:45.462661+00	3.00	5.00	65.00	t	1	0	0	[]
c3e548df-0746-4843-a7e0-0c3edebbd186	f9563acd-17e6-4ac9-90cb-98090139e03e	08758984-558b-4323-bc35-2a202203d87b	1	submitted	2026-08-02 18:31:45.462661+00	2026-08-02 18:51:45.462661+00	2026-08-02 18:46:45.462661+00	3.00	5.00	59.00	f	1	0	0	[]
1dfb7562-4eb8-46f5-9dd7-835c77876ec7	f9563acd-17e6-4ac9-90cb-98090139e03e	78313b75-0494-43a4-b199-ff1928254f44	1	submitted	2026-05-09 18:31:45.462661+00	2026-05-09 18:51:45.462661+00	2026-05-09 18:46:45.462661+00	4.00	5.00	70.00	t	2	0	0	[]
d73094ee-3313-46a5-aae1-3482b10b7105	f9563acd-17e6-4ac9-90cb-98090139e03e	10e55ead-3752-4108-a6b5-5a48ee709f03	1	submitted	2026-04-29 18:31:45.462661+00	2026-04-29 18:51:45.462661+00	2026-04-29 18:46:45.462661+00	4.00	5.00	78.00	t	1	0	0	[]
122368c9-a36b-417f-8d3f-cc696ca82b3f	f9563acd-17e6-4ac9-90cb-98090139e03e	f8cb8b17-b65c-4df2-baab-62604c96a8c0	1	submitted	2026-07-09 18:31:45.462661+00	2026-07-09 18:51:45.462661+00	2026-07-09 18:46:45.462661+00	4.00	5.00	80.00	t	1	0	0	[]
ce9dda29-d00d-4636-b295-63e852c37290	f9563acd-17e6-4ac9-90cb-98090139e03e	76e808de-304b-44e5-b793-8516b5fec7bb	1	submitted	2026-07-13 18:31:45.462661+00	2026-07-13 18:51:45.462661+00	2026-07-13 18:46:45.462661+00	3.00	5.00	57.00	f	1	0	0	[]
1e72343c-f472-420f-96ff-3e9703fac5a9	f9563acd-17e6-4ac9-90cb-98090139e03e	e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	1	submitted	2026-03-24 18:31:45.462661+00	2026-03-24 18:51:45.462661+00	2026-03-24 18:46:45.462661+00	3.00	5.00	62.00	t	3	0	0	[]
4084b639-1db2-4cf9-beb0-c5997328f455	f9563acd-17e6-4ac9-90cb-98090139e03e	ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	1	submitted	2026-07-07 18:31:45.462661+00	2026-07-07 18:51:45.462661+00	2026-07-07 18:46:45.462661+00	4.00	5.00	79.00	t	0	0	0	[]
cb97e8b2-b170-4644-956f-35573f0fc449	f9563acd-17e6-4ac9-90cb-98090139e03e	18407190-2219-4190-9b20-ee775b0094ef	1	submitted	2026-04-05 18:31:45.462661+00	2026-04-05 18:51:45.462661+00	2026-04-05 18:46:45.462661+00	3.00	5.00	63.00	t	1	0	0	[]
942396e3-1736-4189-90e1-c9175f76785c	f9563acd-17e6-4ac9-90cb-98090139e03e	28fe79f0-6207-4e0c-8bae-1eb02eed759b	1	submitted	2026-06-27 18:31:45.462661+00	2026-06-27 18:51:45.462661+00	2026-06-27 18:46:45.462661+00	4.00	5.00	87.00	t	3	0	0	[]
efa1727b-4906-40d5-b6c3-5a5ec0ae529c	f9563acd-17e6-4ac9-90cb-98090139e03e	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	1	submitted	2026-06-12 18:31:45.462661+00	2026-06-12 18:51:45.462661+00	2026-06-12 18:46:45.462661+00	4.00	5.00	81.00	t	1	0	0	[]
f5734b58-2a4e-4a83-a837-e9db777d550b	f9563acd-17e6-4ac9-90cb-98090139e03e	55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	1	submitted	2026-05-31 18:31:45.462661+00	2026-05-31 18:51:45.462661+00	2026-05-31 18:46:45.462661+00	4.00	5.00	87.00	t	2	0	0	[]
19294956-bf7a-4728-a12c-73abf957d798	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	1	submitted	2026-03-03 18:31:45.462661+00	2026-03-03 18:51:45.462661+00	2026-03-03 18:46:45.462661+00	4.00	5.00	79.00	t	3	0	0	[]
4fd701e7-3700-479d-9332-673aa4a847ae	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	78313b75-0494-43a4-b199-ff1928254f44	1	submitted	2026-08-03 18:31:45.462661+00	2026-08-03 18:51:45.462661+00	2026-08-03 18:46:45.462661+00	3.00	5.00	68.00	t	2	0	0	[]
df8c53d5-a6de-4ef6-809d-a1d89acfe589	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d	1	submitted	2026-08-22 18:31:45.462661+00	2026-08-22 18:51:45.462661+00	2026-08-22 18:46:45.462661+00	3.00	5.00	64.00	t	1	0	0	[]
fe2484a1-863d-46ff-8500-c5748d184aab	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	62868b88-e860-457b-8605-04153588489b	1	submitted	2026-03-13 18:31:45.462661+00	2026-03-13 18:51:45.462661+00	2026-03-13 18:46:45.462661+00	5.00	5.00	92.00	t	2	0	0	[]
9e90e0a7-799b-4672-8716-6c7584d02ce8	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	c43722c6-7e70-49e0-acb4-ba4f953e36a8	1	submitted	2026-08-10 18:31:45.462661+00	2026-08-10 18:51:45.462661+00	2026-08-10 18:46:45.462661+00	3.00	5.00	67.00	t	1	0	0	[]
15915807-055d-40a6-86d0-cf99c2a4b806	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	3ded69a7-290c-47f6-bd29-7369f6f8e3c8	1	submitted	2026-07-14 18:31:45.462661+00	2026-07-14 18:51:45.462661+00	2026-07-14 18:46:45.462661+00	4.00	5.00	88.00	t	3	0	0	[]
70ccfc8a-4887-483e-8dbd-925a7c708612	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	3af00a36-1f7b-4846-a52a-b1871416c5b1	1	submitted	2026-08-06 18:31:45.462661+00	2026-08-06 18:51:45.462661+00	2026-08-06 18:46:45.462661+00	4.00	5.00	71.00	t	3	0	0	[]
d49c06f0-7989-473a-9465-ef9ca5dd9649	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	fbc637df-19cd-4ec5-b08d-49ce15747076	1	submitted	2026-06-13 18:31:45.462661+00	2026-06-13 18:51:45.462661+00	2026-06-13 18:46:45.462661+00	4.00	5.00	76.00	t	1	0	0	[]
1652db3c-9a4b-43bf-801d-136cf0151c59	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	b2c7b829-9669-4258-ab45-acc4445b9d6d	1	submitted	2026-05-29 18:31:45.462661+00	2026-05-29 18:51:45.462661+00	2026-05-29 18:46:45.462661+00	5.00	5.00	100.00	t	2	0	0	[]
32ec1947-946e-4405-9f73-c3db974665bc	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	216136af-8b6b-44ae-a787-59506613a618	1	submitted	2026-02-14 18:31:45.462661+00	2026-02-14 18:51:45.462661+00	2026-02-14 18:46:45.462661+00	3.00	5.00	65.00	t	1	0	0	[]
66537d0d-3446-4659-aff7-d4074f2f2233	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	caf34c22-6898-4c15-bde0-08f3d2634d41	1	submitted	2026-03-02 18:31:45.462661+00	2026-03-02 18:51:45.462661+00	2026-03-02 18:46:45.462661+00	4.00	5.00	80.00	t	0	0	0	[]
7087f1d8-104b-442b-9470-753bb0d29a7f	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	72a5ceb8-6b68-433d-9b99-d62b8c9f1375	1	submitted	2026-05-29 18:31:45.462661+00	2026-05-29 18:51:45.462661+00	2026-05-29 18:46:45.462661+00	4.00	5.00	75.00	t	2	0	0	[]
83369ed7-c210-40d3-94c3-990963396ad9	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	a17abc66-209e-405f-bcd6-c39e54cbce66	1	submitted	2026-06-08 18:31:45.462661+00	2026-06-08 18:51:45.462661+00	2026-06-08 18:46:45.462661+00	4.00	5.00	82.00	t	0	0	0	[]
60cb4885-b25f-40cc-9f85-636ad05d2643	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	10e55ead-3752-4108-a6b5-5a48ee709f03	1	submitted	2026-07-22 18:31:45.462661+00	2026-07-22 18:51:45.462661+00	2026-07-22 18:46:45.462661+00	4.00	5.00	87.00	t	3	0	0	[]
88d8a8b7-72be-4d4c-8c58-774b7bd0e7eb	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	fda17094-1c9f-45de-a42c-aa815d09bc2a	1	submitted	2026-08-05 18:31:45.462661+00	2026-08-05 18:51:45.462661+00	2026-08-05 18:46:45.462661+00	4.00	5.00	82.00	t	1	0	0	[]
35c69413-fe17-406d-89e1-6aebcf5faa8d	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	2d970758-319c-400f-b2ba-93057f16a33e	1	submitted	2026-04-03 18:31:45.462661+00	2026-04-03 18:51:45.462661+00	2026-04-03 18:46:45.462661+00	4.00	5.00	70.00	t	3	0	0	[]
70c1311e-709f-4e3e-83c0-c6abbd2662d4	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	48ae8c9d-e783-46c2-abf3-cc9d31e16d81	1	submitted	2026-08-24 18:31:45.462661+00	2026-08-24 18:51:45.462661+00	2026-08-24 18:46:45.462661+00	4.00	5.00	86.00	t	2	0	0	[]
a1aaf9c3-a800-41d3-9e9e-702a1b48f353	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	fc08ec35-be50-46ec-8acb-0ddb68b16b22	1	submitted	2026-04-08 18:31:45.462661+00	2026-04-08 18:51:45.462661+00	2026-04-08 18:46:45.462661+00	5.00	5.00	95.00	t	2	0	0	[]
f989bb90-47c3-4d05-857c-f3836c5a2ed0	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	33f73596-75e6-435e-94f5-d5b111a6aaf5	1	submitted	2026-06-29 18:31:45.462661+00	2026-06-29 18:51:45.462661+00	2026-06-29 18:46:45.462661+00	4.00	5.00	82.00	t	2	0	0	[]
43a987fc-dc22-4182-ab5b-96ffcb3b2532	d7490d75-c4ca-4762-90f5-d6115f4d2eb1	3ecf9082-92fa-49e4-a15f-87acb5504803	1	submitted	2026-06-02 18:31:45.462661+00	2026-06-02 18:51:45.462661+00	2026-06-02 18:46:45.462661+00	3.00	5.00	67.00	t	2	0	0	[]
c8312db5-9ca6-490e-b2f2-3ddbb686e4e4	835ba329-fadf-44c5-a8a3-5740e64f95ba	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	1	submitted	2026-02-22 18:31:45.462661+00	2026-02-22 18:51:45.462661+00	2026-02-22 18:46:45.462661+00	4.00	5.00	85.00	t	2	0	0	[]
68d90812-9eaf-419a-9d3b-e39e22a5187b	835ba329-fadf-44c5-a8a3-5740e64f95ba	62868b88-e860-457b-8605-04153588489b	1	submitted	2026-07-09 18:31:45.462661+00	2026-07-09 18:51:45.462661+00	2026-07-09 18:46:45.462661+00	3.00	5.00	63.00	t	1	0	0	[]
560ed242-6fce-4714-967f-11f930fd379e	835ba329-fadf-44c5-a8a3-5740e64f95ba	0f80298a-f569-4c55-88aa-a57625e20751	1	submitted	2026-08-24 18:31:45.462661+00	2026-08-24 18:51:45.462661+00	2026-08-24 18:46:45.462661+00	2.00	5.00	35.00	f	2	0	0	[]
c70423de-8604-4812-b61b-98eefaedf632	835ba329-fadf-44c5-a8a3-5740e64f95ba	306af47d-26b6-4dc3-96ae-eb178609c1f6	1	submitted	2026-04-18 18:31:45.462661+00	2026-04-18 18:51:45.462661+00	2026-04-18 18:46:45.462661+00	2.00	5.00	38.00	f	1	0	0	[]
7a80ff06-4430-466e-af9c-1f22c177b7a0	835ba329-fadf-44c5-a8a3-5740e64f95ba	ab903484-298e-4415-93b0-8f5ea844bf31	1	submitted	2026-08-09 18:31:45.462661+00	2026-08-09 18:51:45.462661+00	2026-08-09 18:46:45.462661+00	3.00	5.00	59.00	f	1	0	0	[]
9c16814c-2dde-4e14-a5ae-c7a38932fb59	835ba329-fadf-44c5-a8a3-5740e64f95ba	77c70aa0-ddd9-4445-be30-4817de1cbfd0	1	submitted	2026-08-20 18:31:45.462661+00	2026-08-20 18:51:45.462661+00	2026-08-20 18:46:45.462661+00	4.00	5.00	77.00	t	1	0	0	[]
cb0a3c0f-0ce9-411f-86ad-bef2c236e94d	835ba329-fadf-44c5-a8a3-5740e64f95ba	f04f9044-cd22-4a29-8d93-333047a95f6a	1	submitted	2026-06-17 18:31:45.462661+00	2026-06-17 18:51:45.462661+00	2026-06-17 18:46:45.462661+00	3.00	5.00	68.00	t	1	0	0	[]
ac5be9c1-eab4-4632-b442-097ad2949cb9	835ba329-fadf-44c5-a8a3-5740e64f95ba	2af59a77-c993-46c3-a686-b91217814d48	1	submitted	2026-05-26 18:31:45.462661+00	2026-05-26 18:51:45.462661+00	2026-05-26 18:46:45.462661+00	4.00	5.00	84.00	t	0	0	0	[]
1ecf28d4-075d-46f6-acb3-e04ef9352f33	835ba329-fadf-44c5-a8a3-5740e64f95ba	5abfd2bf-a622-4ac2-8867-2be6525ec0e8	1	submitted	2026-05-25 18:31:45.462661+00	2026-05-25 18:51:45.462661+00	2026-05-25 18:46:45.462661+00	4.00	5.00	70.00	t	1	0	0	[]
95ca24fe-228a-42b4-b161-8548ff80fc80	835ba329-fadf-44c5-a8a3-5740e64f95ba	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	1	submitted	2026-02-20 18:31:45.462661+00	2026-02-20 18:51:45.462661+00	2026-02-20 18:46:45.462661+00	4.00	5.00	71.00	t	2	0	0	[]
9ca934a9-3f6a-439a-ba7d-ce0faac0e595	835ba329-fadf-44c5-a8a3-5740e64f95ba	3d87692f-06c1-4403-95ff-c70d1598700a	1	submitted	2026-03-30 18:31:45.462661+00	2026-03-30 18:51:45.462661+00	2026-03-30 18:46:45.462661+00	3.00	5.00	60.00	t	2	0	0	[]
ea4ba2fb-094a-465b-a8d3-6141c40429ee	835ba329-fadf-44c5-a8a3-5740e64f95ba	1eb0cec9-a12f-4f42-9d77-bf6e343e9a75	1	submitted	2026-08-24 18:31:45.462661+00	2026-08-24 18:51:45.462661+00	2026-08-24 18:46:45.462661+00	4.00	5.00	74.00	t	2	0	0	[]
ad5f7a9a-7977-4b4d-9eaf-7aa7dd418c62	835ba329-fadf-44c5-a8a3-5740e64f95ba	2d970758-319c-400f-b2ba-93057f16a33e	1	submitted	2026-06-04 18:31:45.462661+00	2026-06-04 18:51:45.462661+00	2026-06-04 18:46:45.462661+00	2.00	5.00	37.00	f	2	0	0	[]
ed9863d1-0894-4516-9e92-03e85d4fce71	835ba329-fadf-44c5-a8a3-5740e64f95ba	9389e5a2-816f-4e52-950b-a9af117c7ad1	1	submitted	2026-08-11 18:31:45.462661+00	2026-08-11 18:51:45.462661+00	2026-08-11 18:46:45.462661+00	3.00	5.00	57.00	f	0	0	0	[]
1d4ccfda-7681-445b-bd43-b7b1d537160d	212c6d86-5801-4c91-a7ac-d83d34ed24b7	33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	1	submitted	2026-05-01 18:31:45.462661+00	2026-05-01 18:51:45.462661+00	2026-05-01 18:46:45.462661+00	2.00	5.00	44.00	f	2	0	0	[]
5a2edeb1-e079-474a-86ca-c9dcef46c98b	212c6d86-5801-4c91-a7ac-d83d34ed24b7	0d37acee-70ea-4604-8bd7-c995941443fd	1	submitted	2026-08-22 18:31:45.462661+00	2026-08-22 18:51:45.462661+00	2026-08-22 18:46:45.462661+00	3.00	5.00	67.00	t	2	0	0	[]
9a227015-bf89-40ca-b7a5-be2bea548e86	212c6d86-5801-4c91-a7ac-d83d34ed24b7	2731bad6-8e73-4106-8def-3df5df76b6ea	1	submitted	2026-07-27 18:31:45.462661+00	2026-07-27 18:51:45.462661+00	2026-07-27 18:46:45.462661+00	3.00	5.00	57.00	f	1	0	0	[]
f369294b-a7bc-4b61-8835-9d62fb1e94db	212c6d86-5801-4c91-a7ac-d83d34ed24b7	8be014b0-ed46-43db-89e2-91a301c618db	1	submitted	2026-03-13 18:31:45.462661+00	2026-03-13 18:51:45.462661+00	2026-03-13 18:46:45.462661+00	2.00	5.00	42.00	f	2	0	0	[]
4f9e4736-4855-434a-9b4d-085d983b12ff	212c6d86-5801-4c91-a7ac-d83d34ed24b7	8a83194a-d3bc-49dd-8594-ed05a26d23a0	1	submitted	2026-06-20 18:31:45.462661+00	2026-06-20 18:51:45.462661+00	2026-06-20 18:46:45.462661+00	2.00	5.00	45.00	f	0	0	0	[]
e65ded22-b3f0-4707-a346-a2e25bda94ed	212c6d86-5801-4c91-a7ac-d83d34ed24b7	9bab5f84-a53e-49d6-91f8-eef87bf5960c	1	submitted	2026-04-17 18:31:45.462661+00	2026-04-17 18:51:45.462661+00	2026-04-17 18:46:45.462661+00	2.00	5.00	49.00	f	2	0	0	[]
83002d63-9d83-4f90-965c-3ebc215ed436	212c6d86-5801-4c91-a7ac-d83d34ed24b7	8b09383e-447b-4fa0-b605-8d8cf4f3f527	1	submitted	2026-03-22 18:31:45.462661+00	2026-03-22 18:51:45.462661+00	2026-03-22 18:46:45.462661+00	3.00	5.00	65.00	t	1	0	0	[]
539c4fea-f074-4f70-940a-9c16c719910e	212c6d86-5801-4c91-a7ac-d83d34ed24b7	b8541832-74c6-404f-90d0-5fb6d3df7663	1	submitted	2026-02-26 18:31:45.462661+00	2026-02-26 18:51:45.462661+00	2026-02-26 18:46:45.462661+00	3.00	5.00	69.00	t	1	0	0	[]
63feb3eb-ec4d-488e-a711-29dfe28b1eb0	212c6d86-5801-4c91-a7ac-d83d34ed24b7	032c01d5-4b5e-44f6-821d-2ba4342c938f	1	submitted	2026-04-22 18:31:45.462661+00	2026-04-22 18:51:45.462661+00	2026-04-22 18:46:45.462661+00	2.00	5.00	30.00	f	2	0	0	[]
e0b06357-37df-4093-99f0-f4e5f789e2b5	212c6d86-5801-4c91-a7ac-d83d34ed24b7	48f33e15-f87f-4629-ab82-4123ada4bdc4	1	submitted	2026-03-14 18:31:45.462661+00	2026-03-14 18:51:45.462661+00	2026-03-14 18:46:45.462661+00	2.00	5.00	36.00	f	2	0	0	[]
af75ff5f-5123-4d62-9557-533c20015bf2	212c6d86-5801-4c91-a7ac-d83d34ed24b7	d2298ed0-2515-4232-b70f-845a98dac595	1	submitted	2026-07-30 18:31:45.462661+00	2026-07-30 18:51:45.462661+00	2026-07-30 18:46:45.462661+00	2.00	5.00	33.00	f	3	0	0	[]
acd13aae-e7c4-4d09-b53f-ec319966f98d	212c6d86-5801-4c91-a7ac-d83d34ed24b7	7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	1	submitted	2026-03-06 18:31:45.462661+00	2026-03-06 18:51:45.462661+00	2026-03-06 18:46:45.462661+00	2.00	5.00	46.00	f	2	0	0	[]
32a30ee1-74c2-4a3a-ab11-5648838ea25b	212c6d86-5801-4c91-a7ac-d83d34ed24b7	55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	1	submitted	2026-04-17 18:31:45.462661+00	2026-04-17 18:51:45.462661+00	2026-04-17 18:46:45.462661+00	2.00	5.00	32.00	f	1	0	0	[]
a17ecac9-5c09-4038-98fa-77a132ed6df6	212c6d86-5801-4c91-a7ac-d83d34ed24b7	65ef229b-117d-4946-b5bb-301e3f828fc2	1	submitted	2026-05-02 18:31:45.462661+00	2026-05-02 18:51:45.462661+00	2026-05-02 18:46:45.462661+00	2.00	5.00	35.00	f	0	0	0	[]
81853c1c-e7d8-4355-803c-712674fea689	212c6d86-5801-4c91-a7ac-d83d34ed24b7	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	1	submitted	2026-06-14 18:31:45.462661+00	2026-06-14 18:51:45.462661+00	2026-06-14 18:46:45.462661+00	3.00	5.00	68.00	t	0	0	0	[]
1bd50f30-c54f-4768-8941-05073a45b08a	212c6d86-5801-4c91-a7ac-d83d34ed24b7	3b6030a2-3993-4389-8c6c-d3427e0e680b	1	submitted	2026-07-17 18:31:45.462661+00	2026-07-17 18:51:45.462661+00	2026-07-17 18:46:45.462661+00	2.00	5.00	42.00	f	1	0	0	[]
e656010e-b70a-4241-a889-ff7fc2cad1a9	212c6d86-5801-4c91-a7ac-d83d34ed24b7	6f3917b0-87b7-417f-a382-c38278a3d485	1	submitted	2026-06-20 18:31:45.462661+00	2026-06-20 18:51:45.462661+00	2026-06-20 18:46:45.462661+00	3.00	5.00	59.00	f	1	0	0	[]
a2f54fda-be9e-426c-b6c4-ede4d5632ca3	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	c43722c6-7e70-49e0-acb4-ba4f953e36a8	1	submitted	2026-08-08 18:31:45.462661+00	2026-08-08 18:51:45.462661+00	2026-08-08 18:46:45.462661+00	2.00	5.00	39.00	f	2	0	0	[]
4c50aa0a-868f-47df-92b0-dd809d405667	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	312e5b6a-024a-4a5d-9389-357b73426d42	1	submitted	2026-05-07 18:31:45.462661+00	2026-05-07 18:51:45.462661+00	2026-05-07 18:46:45.462661+00	3.00	5.00	69.00	t	1	0	0	[]
dea424b2-372a-4d14-be87-e7f84e3c8527	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	4c6d827e-f3db-47d8-be22-4dc4a611c63f	1	submitted	2026-04-23 18:31:45.462661+00	2026-04-23 18:51:45.462661+00	2026-04-23 18:46:45.462661+00	2.00	5.00	38.00	f	0	0	0	[]
6b1158b0-f0f7-4cf4-9245-d39c94915415	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	3d87692f-06c1-4403-95ff-c70d1598700a	1	submitted	2026-06-12 18:31:45.462661+00	2026-06-12 18:51:45.462661+00	2026-06-12 18:46:45.462661+00	3.00	5.00	54.00	f	0	0	0	[]
75982a9e-ee56-44b7-9f39-6a54989c10bc	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	ae420db9-d867-40d1-8d1a-01ee5d62e270	1	submitted	2026-04-16 18:31:45.462661+00	2026-04-16 18:51:45.462661+00	2026-04-16 18:46:45.462661+00	3.00	5.00	67.00	t	2	0	0	[]
7e9344ba-a2ea-4685-ad29-51cd41a97bb6	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	8b09383e-447b-4fa0-b605-8d8cf4f3f527	1	submitted	2026-05-23 18:31:45.462661+00	2026-05-23 18:51:45.462661+00	2026-05-23 18:46:45.462661+00	3.00	5.00	52.00	f	2	0	0	[]
062f1b57-1f2f-4495-bbdb-97f9dbc6907e	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	37609501-b2cd-4810-a1d5-b2a10f0405fd	1	submitted	2026-05-20 18:31:45.462661+00	2026-05-20 18:51:45.462661+00	2026-05-20 18:46:45.462661+00	2.00	5.00	44.00	f	1	0	0	[]
6ffdfa41-fbd4-433e-b387-d9fd1ca252d3	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	8ffbd0cf-b807-4193-af37-3a61482c76eb	1	submitted	2026-07-21 18:31:45.462661+00	2026-07-21 18:51:45.462661+00	2026-07-21 18:46:45.462661+00	3.00	5.00	66.00	t	1	0	0	[]
01e69bc7-6101-4dc9-a844-d1442a11063d	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	1	submitted	2026-03-05 18:31:45.462661+00	2026-03-05 18:51:45.462661+00	2026-03-05 18:46:45.462661+00	2.00	5.00	36.00	f	2	0	0	[]
88f13d63-d166-4200-b93a-00f07a06f75c	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	1eb0cec9-a12f-4f42-9d77-bf6e343e9a75	1	submitted	2026-08-27 18:31:45.462661+00	2026-08-27 18:51:45.462661+00	2026-08-27 18:46:45.462661+00	1.00	5.00	20.00	f	1	0	0	[]
81320266-1a40-4484-b4b0-95c0e158b089	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	573a471b-8236-4977-b94b-80b530b27e7c	1	submitted	2026-05-07 18:31:45.462661+00	2026-05-07 18:51:45.462661+00	2026-05-07 18:46:45.462661+00	2.00	5.00	43.00	f	2	0	0	[]
090f802f-4794-4c3e-8f53-14f6cba8f102	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	6bb2ccef-6c0b-4baa-bc82-d037a1c93af1	1	submitted	2026-07-06 18:31:45.462661+00	2026-07-06 18:51:45.462661+00	2026-07-06 18:46:45.462661+00	3.00	5.00	50.00	f	3	0	0	[]
a89f48e5-f042-4131-82c2-52e13eba9449	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	1	submitted	2026-07-29 18:31:45.462661+00	2026-07-29 18:51:45.462661+00	2026-07-29 18:46:45.462661+00	4.00	5.00	75.00	t	0	0	0	[]
a47d9bb9-8bea-43ad-9d3b-04077ac51d40	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	1	submitted	2026-05-21 18:31:45.462661+00	2026-05-21 18:51:45.462661+00	2026-05-21 18:46:45.462661+00	3.00	5.00	60.00	t	1	0	0	[]
b2f0a22a-cfe5-41f9-9dfe-3af70c3714d9	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	2731bad6-8e73-4106-8def-3df5df76b6ea	1	submitted	2026-03-11 18:31:45.462661+00	2026-03-11 18:51:45.462661+00	2026-03-11 18:46:45.462661+00	2.00	5.00	42.00	f	2	0	0	[]
1f3b6401-642f-4358-9c9a-03bf5c1ecb1a	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	8a1eab45-738c-41b6-b35d-7737f5e2f64e	1	submitted	2026-07-21 18:31:45.462661+00	2026-07-21 18:51:45.462661+00	2026-07-21 18:46:45.462661+00	3.00	5.00	61.00	t	2	0	0	[]
f360e6c8-1c66-41e2-a730-68e5f998cb02	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	a8c5b60b-8763-4325-900d-07d7540e6015	1	submitted	2026-06-08 18:31:45.462661+00	2026-06-08 18:51:45.462661+00	2026-06-08 18:46:45.462661+00	3.00	5.00	68.00	t	1	0	0	[]
5593dfda-ccca-422e-9e9b-9854bff23c6a	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	db9ec5a1-d0be-490d-91a6-bf32127bba75	1	submitted	2026-04-30 18:31:45.462661+00	2026-04-30 18:51:45.462661+00	2026-04-30 18:46:45.462661+00	2.00	5.00	34.00	f	3	0	0	[]
5e175c13-e3d4-4713-b712-410a1a94918a	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	bd78a83d-5740-4d0d-9000-cdf29d332f27	1	submitted	2026-09-09 18:31:45.462661+00	2026-09-09 18:51:45.462661+00	2026-09-09 18:46:45.462661+00	2.00	5.00	44.00	f	2	0	0	[]
c29e4437-f958-45d1-a983-7f523c20af97	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	4ace2ecd-317e-494c-ad50-71e2794fb907	1	submitted	2026-05-23 18:31:45.462661+00	2026-05-23 18:51:45.462661+00	2026-05-23 18:46:45.462661+00	1.00	5.00	25.00	f	3	0	0	[]
ac709189-8a55-481f-a065-5846a0585597	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	3e1e22ae-3497-44dc-bb66-1a3c24a5af91	1	submitted	2026-05-21 18:31:45.462661+00	2026-05-21 18:51:45.462661+00	2026-05-21 18:46:45.462661+00	2.00	5.00	45.00	f	2	0	0	[]
bcf97b7f-03f7-4397-839b-0872662b3f62	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	1	submitted	2026-05-04 18:31:45.462661+00	2026-05-04 18:51:45.462661+00	2026-05-04 18:46:45.462661+00	2.00	5.00	37.00	f	0	0	0	[]
16aba863-c6b3-41e9-92b4-895ca2818e70	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	c2900748-9036-4804-b4f0-feb22ac5b4fb	1	submitted	2026-03-29 18:31:45.462661+00	2026-03-29 18:51:45.462661+00	2026-03-29 18:46:45.462661+00	3.00	5.00	58.00	f	1	0	0	[]
c0dd4300-e85e-46a2-8030-d923b6fd094f	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	48f33e15-f87f-4629-ab82-4123ada4bdc4	1	submitted	2026-05-30 18:31:45.462661+00	2026-05-30 18:51:45.462661+00	2026-05-30 18:46:45.462661+00	3.00	5.00	64.00	t	1	0	0	[]
311362c1-14e0-4491-990b-932bdb38cb74	21b80a0e-ac78-42bd-bcde-0249bedb0fe6	33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	1	submitted	2026-04-05 18:31:45.462661+00	2026-04-05 18:51:45.462661+00	2026-04-05 18:46:45.462661+00	2.00	5.00	49.00	f	0	0	0	[]
93bfe200-bbb4-476b-b8b4-38f05270c192	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	fc08ec35-be50-46ec-8acb-0ddb68b16b22	1	submitted	2026-09-07 18:31:45.462661+00	2026-09-07 18:51:45.462661+00	2026-09-07 18:46:45.462661+00	4.00	5.00	71.00	t	3	0	0	[]
aa7beed1-6e6d-4d5b-af40-e57a38854f02	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	2c310487-b2d2-4f8a-bdc3-0fcd75eff4a9	1	submitted	2026-05-23 18:31:45.462661+00	2026-05-23 18:51:45.462661+00	2026-05-23 18:46:45.462661+00	3.00	5.00	54.00	f	1	0	0	[]
0bdc3b3c-0ade-4bb0-a4ec-334e2056bd2e	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	90a570b4-9441-4d8b-981d-a7fa379054d3	1	submitted	2026-03-09 18:31:45.462661+00	2026-03-09 18:51:45.462661+00	2026-03-09 18:46:45.462661+00	3.00	5.00	52.00	f	2	0	0	[]
af7df40b-6653-4e7a-8a3f-9d1ffa35002a	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	3ecf9082-92fa-49e4-a15f-87acb5504803	1	submitted	2026-05-10 18:31:45.462661+00	2026-05-10 18:51:45.462661+00	2026-05-10 18:46:45.462661+00	4.00	5.00	87.00	t	0	0	0	[]
f27c808c-b4c0-4256-862d-bed9a470cec2	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	707e086b-3312-442d-ac6d-9776ebe73deb	1	submitted	2026-04-29 18:31:45.462661+00	2026-04-29 18:51:45.462661+00	2026-04-29 18:46:45.462661+00	2.00	5.00	49.00	f	2	0	0	[]
1cd2184b-6f67-4ca2-917c-60343190e41e	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	6a389990-e259-43a4-a9a2-7575b00029e0	1	submitted	2026-06-20 18:31:45.462661+00	2026-06-20 18:51:45.462661+00	2026-06-20 18:46:45.462661+00	4.00	5.00	74.00	t	3	0	0	[]
232f56a0-3e68-44d3-9b5a-9f1e25b9d2a6	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	cc9e83f0-d177-4454-8ba5-f7581c6da639	1	submitted	2026-07-16 18:31:45.462661+00	2026-07-16 18:51:45.462661+00	2026-07-16 18:46:45.462661+00	3.00	5.00	50.00	f	2	0	0	[]
3dd33bdb-aad8-421e-8143-2dac23f71303	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	e888ad9f-c064-4d24-8143-eec67fac7c1c	1	submitted	2026-05-17 18:31:45.462661+00	2026-05-17 18:51:45.462661+00	2026-05-17 18:46:45.462661+00	4.00	5.00	74.00	t	3	0	0	[]
dbefccc4-73e8-4edb-9feb-4d0e0ce85261	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	eee6bbaa-75eb-44f4-9892-d46194b720a9	1	submitted	2026-08-11 18:31:45.462661+00	2026-08-11 18:51:45.462661+00	2026-08-11 18:46:45.462661+00	3.00	5.00	68.00	t	2	0	0	[]
ffa8d784-b8bc-4daf-aa7b-24b59aafda21	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	306af47d-26b6-4dc3-96ae-eb178609c1f6	1	submitted	2026-03-20 18:31:45.462661+00	2026-03-20 18:51:45.462661+00	2026-03-20 18:46:45.462661+00	4.00	5.00	75.00	t	2	0	0	[]
6ecd86f3-40bd-4ba3-b95a-9513da1eecd6	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	a8c5b60b-8763-4325-900d-07d7540e6015	1	submitted	2026-09-14 18:31:45.462661+00	2026-09-14 18:51:45.462661+00	2026-09-14 18:46:45.462661+00	3.00	5.00	67.00	t	3	0	0	[]
d5f547d3-22ee-4fad-ac55-0ad38293a2e3	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	24cbfa5b-7114-43b8-957c-fe0efa420c25	1	submitted	2026-06-12 18:31:45.462661+00	2026-06-12 18:51:45.462661+00	2026-06-12 18:46:45.462661+00	3.00	5.00	64.00	t	1	0	0	[]
6f634741-fbde-4511-8bc5-78119983b914	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	15a2f413-02d0-4624-9468-3a8bec2ba6b8	1	submitted	2026-04-06 18:31:45.462661+00	2026-04-06 18:51:45.462661+00	2026-04-06 18:46:45.462661+00	4.00	5.00	76.00	t	2	0	0	[]
8f89569c-607b-48b0-8298-501229ebae20	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	4135122d-a240-499c-8de4-3db650d7acc9	1	submitted	2026-09-01 18:31:45.462661+00	2026-09-01 18:51:45.462661+00	2026-09-01 18:46:45.462661+00	3.00	5.00	52.00	f	1	0	0	[]
5f791fa0-0890-4968-9a24-e0d4b33feee7	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	696886f6-a4bf-44a6-9ba9-c939abb52137	1	submitted	2026-07-18 18:31:45.462661+00	2026-07-18 18:51:45.462661+00	2026-07-18 18:46:45.462661+00	4.00	5.00	78.00	t	0	0	0	[]
928ecd6e-2d1a-4ba2-94a5-75a498406a04	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	1	submitted	2026-09-21 18:31:45.462661+00	2026-09-21 18:51:45.462661+00	2026-09-21 18:46:45.462661+00	3.00	5.00	66.00	t	2	0	0	[]
16d6d2ed-7b7b-4f4c-9ef5-9efc4143cdb7	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	6f1d6dd6-daa9-4660-a06f-527bf32f663e	1	submitted	2026-03-01 18:31:45.462661+00	2026-03-01 18:51:45.462661+00	2026-03-01 18:46:45.462661+00	2.00	5.00	49.00	f	3	0	0	[]
f6e8e456-d3d3-4db6-b2b3-8959a2041b37	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	9897dc81-824b-4829-9fda-76c3f3c3e38f	1	submitted	2026-03-20 18:31:45.462661+00	2026-03-20 18:51:45.462661+00	2026-03-20 18:46:45.462661+00	4.00	5.00	71.00	t	1	0	0	[]
10a5d864-fdbf-46ba-9d6d-49a0bcf8d114	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	fed72080-2568-4892-8047-0b3c72ff7fad	1	submitted	2026-03-04 18:31:45.462661+00	2026-03-04 18:51:45.462661+00	2026-03-04 18:46:45.462661+00	3.00	5.00	62.00	t	2	0	0	[]
eca74cc9-361a-4d0f-9329-5ca0d2578f67	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	1	submitted	2026-09-08 18:31:45.462661+00	2026-09-08 18:51:45.462661+00	2026-09-08 18:46:45.462661+00	3.00	5.00	69.00	t	1	0	0	[]
9de191bf-9fa0-4eeb-89f7-e88a9cd6d512	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	9bab5f84-a53e-49d6-91f8-eef87bf5960c	1	submitted	2026-06-19 18:31:45.462661+00	2026-06-19 18:51:45.462661+00	2026-06-19 18:46:45.462661+00	3.00	5.00	56.00	f	3	0	0	[]
868e3fa4-4c4d-4d0f-ab7c-0aff97e9d547	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	bea31be8-3a44-4869-9c56-dce2da936f51	1	submitted	2026-05-18 18:31:45.462661+00	2026-05-18 18:51:45.462661+00	2026-05-18 18:46:45.462661+00	4.00	5.00	85.00	t	3	0	0	[]
ce86d190-ff4e-44a7-b167-b25a4079c31f	6f0c2973-95f4-4afe-9d5f-1d409cbbb54f	3af00a36-1f7b-4846-a52a-b1871416c5b1	1	submitted	2026-07-26 18:31:45.462661+00	2026-07-26 18:51:45.462661+00	2026-07-26 18:46:45.462661+00	4.00	5.00	74.00	t	1	0	0	[]
\.


--
-- Data for Name: audit_logs; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.audit_logs (id, actor_id, action, entity_type, entity_id, details, ip_address, created_at) FROM stdin;
1	2e42c806-48d6-422a-b282-2b30f0484c3c	login.success	user	2e42c806-48d6-422a-b282-2b30f0484c3c	\N	172.18.0.5	2026-09-27 18:13:03.710298+00
2	78313b75-0494-43a4-b199-ff1928254f44	login.success	user	78313b75-0494-43a4-b199-ff1928254f44	\N	172.18.0.5	2026-09-27 18:14:31.0033+00
3	85e9f6c3-f766-43d5-8fa9-17faa945a923	login.success	user	85e9f6c3-f766-43d5-8fa9-17faa945a923	\N	172.18.0.5	2026-09-27 19:05:49.152954+00
4	78313b75-0494-43a4-b199-ff1928254f44	login.success	user	78313b75-0494-43a4-b199-ff1928254f44	\N	172.18.0.5	2026-09-27 19:06:56.054321+00
5	85e9f6c3-f766-43d5-8fa9-17faa945a923	login.success	user	85e9f6c3-f766-43d5-8fa9-17faa945a923	\N	172.18.0.5	2026-09-28 06:39:58.961803+00
6	2e42c806-48d6-422a-b282-2b30f0484c3c	login.success	user	2e42c806-48d6-422a-b282-2b30f0484c3c	\N	172.18.0.5	2026-09-28 06:40:35.345913+00
7	2e42c806-48d6-422a-b282-2b30f0484c3c	login.success	user	2e42c806-48d6-422a-b282-2b30f0484c3c	\N	172.18.0.5	2026-09-28 11:21:36.668229+00
8	2e42c806-48d6-422a-b282-2b30f0484c3c	login.success	user	2e42c806-48d6-422a-b282-2b30f0484c3c	\N	172.18.0.5	2026-09-28 16:43:11.29449+00
9	78313b75-0494-43a4-b199-ff1928254f44	login.success	user	78313b75-0494-43a4-b199-ff1928254f44	\N	172.18.0.5	2026-09-28 16:46:11.502555+00
10	2e42c806-48d6-422a-b282-2b30f0484c3c	login.success	user	2e42c806-48d6-422a-b282-2b30f0484c3c	\N	172.18.0.5	2026-09-28 16:56:12.125579+00
\.


--
-- Data for Name: certificates; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.certificates (id, certificate_no, user_id, course_id, enrollment_id, final_score_pct, payload, sha256, signature, file_id, issued_at, revoked_at, revoke_reason) FROM stdin;
2454e270-9b82-4078-8377-6f694da5ce8b	IMD-CC-2026-000001	3ed88e99-cb0d-423f-ae37-92b93c67d881	55a4d643-f01f-4d75-8109-ff60798f1e9b	a6209498-4628-465b-a800-8886f48ff19f	62.00	{"user": "3ed88e99-cb0d-423f-ae37-92b93c67d881", "score": 62, "course": "55a4d643-f01f-4d75-8109-ff60798f1e9b"}	193ffdc18a89b3b500ee74aaa7f79fc3a9ba7b8adc275e1f5602f1986cb282dd	demo-signature	\N	2026-08-04 18:31:45.462661+00	\N	\N
752e69fd-9282-49a3-931d-e1d57bbc9572	IMD-CC-2026-000002	fba30b27-7555-43f7-8c74-b84e722ebbc8	55a4d643-f01f-4d75-8109-ff60798f1e9b	26586d96-c5b1-442d-948e-163c2d213851	60.00	{"user": "fba30b27-7555-43f7-8c74-b84e722ebbc8", "score": 60, "course": "55a4d643-f01f-4d75-8109-ff60798f1e9b"}	5db3b2ab9792829038fecf870d720a54a9ba7b8adc275e1f5602f1986cb282dd	demo-signature	\N	2026-07-13 18:31:45.462661+00	\N	\N
36da340d-92d9-456c-b9c6-bd9a8ce78f24	IMD-CC-2026-000003	df216767-1cda-46b6-874f-845e41051203	55a4d643-f01f-4d75-8109-ff60798f1e9b	781657d2-cb7c-4068-86a7-afbfb172241a	62.00	{"user": "df216767-1cda-46b6-874f-845e41051203", "score": 62, "course": "55a4d643-f01f-4d75-8109-ff60798f1e9b"}	91254c89496072591e98ae3cfdf2d9aba9ba7b8adc275e1f5602f1986cb282dd	demo-signature	\N	2026-04-18 18:31:45.462661+00	\N	\N
8d96a828-4cca-40ff-9cef-429167efce08	IMD-CC-2026-000004	d072273b-7a6f-4fa4-9195-1697050cfab1	55a4d643-f01f-4d75-8109-ff60798f1e9b	1e4641cb-f4b3-49a8-93d5-cfed6109d544	61.00	{"user": "d072273b-7a6f-4fa4-9195-1697050cfab1", "score": 61, "course": "55a4d643-f01f-4d75-8109-ff60798f1e9b"}	1ec67ef465d114e112cae0a540c8a372a9ba7b8adc275e1f5602f1986cb282dd	demo-signature	\N	2026-03-04 18:31:45.462661+00	\N	\N
4128e784-703c-4aad-b800-2b2698d94479	IMD-CC-2026-000005	6f9f3af8-fa88-4804-aa9b-5680afa4c1ba	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	c7f556f5-6abd-4092-90eb-f6ae89f42de2	83.00	{"user": "6f9f3af8-fa88-4804-aa9b-5680afa4c1ba", "score": 83, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	b3676e1432de78bb707b2d6c6efdcbeadad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-06-03 18:31:45.462661+00	\N	\N
e17dcffd-708c-4686-8821-7a9f7058af3b	IMD-CC-2026-000006	cf4749a6-6127-4d97-b2a0-17a11eabc216	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	d7c04a9b-a449-43d0-9c08-a36ec60a7144	98.00	{"user": "cf4749a6-6127-4d97-b2a0-17a11eabc216", "score": 98, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	e62d1dbcc4b815f93474399df4d3202edad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-09-13 18:31:45.462661+00	\N	\N
df8f0f34-038a-4f6c-a4ac-9bcd6291e2be	IMD-CC-2026-000007	a5fd318c-feeb-4b1b-b739-3e40a59dde18	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	1e3f3386-b0e7-49bc-a95d-0e822f6caa56	99.00	{"user": "a5fd318c-feeb-4b1b-b739-3e40a59dde18", "score": 99, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	23706c127e5b85b879605c94ac06b642dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-07-03 18:31:45.462661+00	\N	\N
50f42ae8-b8a5-4958-ab7b-0e8e9ae43292	IMD-CC-2026-000008	72a14ee8-79a9-41a0-8fb1-ac0dfac5bfa2	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	2a0dfd86-ac6d-4c14-960a-f90d145f4c08	92.00	{"user": "72a14ee8-79a9-41a0-8fb1-ac0dfac5bfa2", "score": 92, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	6b79c9a69ea455fef25f7d0058e17455dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-04-23 18:31:45.462661+00	\N	\N
0e7be8a1-0eed-4643-bc57-38d4d1eb3de6	IMD-CC-2026-000009	625944b1-2b9b-433b-9af5-e72894aa7a58	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	408e08e2-5535-4da7-81c2-ab36fb887a7a	100.00	{"user": "625944b1-2b9b-433b-9af5-e72894aa7a58", "score": 100, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	470e7b85e5d48bfe9eb98aebcc33f475dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-06-10 18:31:45.462661+00	\N	\N
49e5be35-2278-4ee4-a1d8-f1612163e5a1	IMD-CC-2026-000010	fda17094-1c9f-45de-a42c-aa815d09bc2a	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	826d37c2-4a74-45cc-a34b-96b6c2bcad30	100.00	{"user": "fda17094-1c9f-45de-a42c-aa815d09bc2a", "score": 100, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	86522137a91569ae95ca6f54960e3054dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-04-26 18:31:45.462661+00	\N	\N
2e07d18f-b166-4872-a391-093f4e53f727	IMD-CC-2026-000011	9897dc81-824b-4829-9fda-76c3f3c3e38f	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	d6d72580-4a35-4dff-87b0-b06319b5d503	74.00	{"user": "9897dc81-824b-4829-9fda-76c3f3c3e38f", "score": 74, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	c79993e208a00767d277b79c33d4ebb3dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-04-28 18:31:45.462661+00	\N	\N
4379cc77-2e22-4b6e-8fff-a0518379f9bc	IMD-CC-2026-000012	30e16278-0ca1-4efa-a03b-7168658bb2c2	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	e8ab45c4-c63d-4e98-a3cd-e6a9dac68f50	74.00	{"user": "30e16278-0ca1-4efa-a03b-7168658bb2c2", "score": 74, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	3c9cd71e01fb6c840259fd1f934f39fcdad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-04-20 18:31:45.462661+00	\N	\N
4b0e6872-4731-40a2-a51c-74c21cb46c51	IMD-CC-2026-000013	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	6f511495-95c1-4a7b-b444-bfb89bfc8797	88.00	{"user": "0369edbf-d1ba-47c9-b17c-e67c29bf27fc", "score": 88, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	fd41fdca32ad5b7f4b247eb0b812a68edad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-08-17 18:31:45.462661+00	\N	\N
02630de8-6e92-413d-8751-e103802c17a1	IMD-CC-2026-000014	a6afe850-9547-4fac-892c-00558ad8f725	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	da27530e-8235-4da0-97db-33b0c47569b7	100.00	{"user": "a6afe850-9547-4fac-892c-00558ad8f725", "score": 100, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	f7971548ee038d0076e28363f03f1192dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-05-14 18:31:45.462661+00	\N	\N
5ecc19ef-ae53-481e-9ceb-94b7f8ac1ffc	IMD-CC-2026-000015	b28e0245-9390-4127-ad3f-80ace4775f43	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	cdb4c117-8d2d-475e-9ce6-8d5d3cc8c7b8	79.00	{"user": "b28e0245-9390-4127-ad3f-80ace4775f43", "score": 79, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	b4f37fa7988959e77bdc16b787965aa5dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-05-31 18:31:45.462661+00	\N	\N
b17b7b22-72b5-493c-86b9-f15c50c4819a	IMD-CC-2026-000016	a5e41a1c-9682-4873-8924-f11edf9b3fce	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	99e4914a-c038-4bee-b8f9-1b54f9701738	75.00	{"user": "a5e41a1c-9682-4873-8924-f11edf9b3fce", "score": 75, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	2b4f144f2bcd6389f66b431b3b5f1bd0dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-08-12 18:31:45.462661+00	\N	\N
b1403f8f-12a2-4ae0-8ec6-4ed7126d96b4	IMD-CC-2026-000017	2994671f-607f-4cdc-a2bc-22ab97456b28	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	6cf3fac4-3c32-4530-895a-084d25e75952	87.00	{"user": "2994671f-607f-4cdc-a2bc-22ab97456b28", "score": 87, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	a8f0b8f57f24bd35c032fdfbe4209cb7dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-05-06 18:31:45.462661+00	\N	\N
39bcba52-e7b6-4045-aa1a-2491038cdffe	IMD-CC-2026-000018	b8541832-74c6-404f-90d0-5fb6d3df7663	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	4a800eb8-3cf0-4dc1-97fd-fbfada99a955	99.00	{"user": "b8541832-74c6-404f-90d0-5fb6d3df7663", "score": 99, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	cdf5aded1aeb31915945ce085ffff803dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-09-02 18:31:45.462661+00	\N	\N
b72b1d66-720c-49ac-825c-a08274bb783c	IMD-CC-2026-000019	24cbfa5b-7114-43b8-957c-fe0efa420c25	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	7cb99338-ce74-47db-9555-bc53b3655a38	98.00	{"user": "24cbfa5b-7114-43b8-957c-fe0efa420c25", "score": 98, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	e41c70cee1609f059273fcfc203040c5dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-07-06 18:31:45.462661+00	\N	\N
130150b2-85fb-4e2b-9b27-b9908f627e55	IMD-CC-2026-000020	8b09383e-447b-4fa0-b605-8d8cf4f3f527	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	9102c79a-44ba-48a6-893f-b72eb8230f0d	93.00	{"user": "8b09383e-447b-4fa0-b605-8d8cf4f3f527", "score": 93, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	9578dfb021ac838cc870e5665c1317e1dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-06-01 18:31:45.462661+00	\N	\N
5f360e22-b59c-4ded-9d4c-e33ca6eabf01	IMD-CC-2026-000021	a7bae3c0-0e2c-42db-8e35-79114d5dfe80	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	24a03e87-5231-417c-ae3c-e92e2a934615	74.00	{"user": "a7bae3c0-0e2c-42db-8e35-79114d5dfe80", "score": 74, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	796ac9c78b0b0b7da95b85c01c1f976cdad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-03-09 18:31:45.462661+00	\N	\N
789bb60a-d0a5-4650-a2a0-d7c185e97bc7	IMD-CC-2026-000022	09cc88c9-6251-413b-9873-df6f5bb8b24d	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	53a0a260-1b29-47e9-aa9a-b68b7d5155ab	82.00	{"user": "09cc88c9-6251-413b-9873-df6f5bb8b24d", "score": 82, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	f49e0db8460a63abca396a783be781c8dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-03-20 18:31:45.462661+00	\N	\N
5f1b6e55-c29d-41eb-86ca-85d166bf5394	IMD-CC-2026-000023	c43722c6-7e70-49e0-acb4-ba4f953e36a8	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	60b045fc-8fd9-484e-8fcb-0f4fe80d4e2d	67.00	{"user": "c43722c6-7e70-49e0-acb4-ba4f953e36a8", "score": 67, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	d3bf9854d7a6467a4ef95c12c1d65c3bdad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-06-05 18:31:45.462661+00	\N	\N
ab83aaf7-3838-4ed6-8c89-e69e7efe5411	IMD-CC-2026-000024	5a97c9d9-87c7-445c-9dc8-860fb29edb16	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	e5047c3c-4fa5-44e6-947c-4513ca9d6f46	79.00	{"user": "5a97c9d9-87c7-445c-9dc8-860fb29edb16", "score": 79, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	e0465cfdb1435d29dd905f31827a46ffdad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-05-20 18:31:45.462661+00	\N	\N
5697b00b-bdc1-4775-a958-36f0b231c5dc	IMD-CC-2026-000025	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	d4f15fa2-b184-490e-af5e-76e42340445d	100.00	{"user": "5e2de4dd-f65c-43ae-9ab6-363fe303ab1e", "score": 100, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	ea5d3e0c453ae30b48cf5a90dfb692e5dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-04-30 18:31:45.462661+00	\N	\N
f994c9fc-2827-4069-9cb5-7ca8a260b9f3	IMD-CC-2026-000026	b875f05c-64bb-41c8-b501-04ef26d03cb3	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	947e4aaf-edad-444f-816e-74e5169a2490	100.00	{"user": "b875f05c-64bb-41c8-b501-04ef26d03cb3", "score": 100, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	a0827adbf13877416fffac8e830e72e5dad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-07-24 18:31:45.462661+00	\N	\N
cc56caa1-f2ef-4406-85da-fa46c93d9efc	IMD-CC-2026-000027	78313b75-0494-43a4-b199-ff1928254f44	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	3fbb55b2-688e-4d84-9f9b-d83740123583	69.00	{"user": "78313b75-0494-43a4-b199-ff1928254f44", "score": 69, "course": "9e873c8c-811f-4ff5-8d3a-6c858ad65aa6"}	0ac8b77bcc82622cb255871ec8e6961cdad41584584b56e8c66c6ae0980ae50a	demo-signature	\N	2026-04-15 18:31:45.462661+00	\N	\N
757ca106-8d6c-4d83-800d-2b9b13cc0652	IMD-CC-2026-000028	7acc259e-1231-481b-ab79-59821fd46534	ad72951b-6768-4887-8063-287ff8f51bf1	69e00543-2f5f-4b57-8849-6ccc2357ae4e	71.00	{"user": "7acc259e-1231-481b-ab79-59821fd46534", "score": 71, "course": "ad72951b-6768-4887-8063-287ff8f51bf1"}	dd0d83b2fd07375465ff5c84d1536cab05d7c291e65104666d469268db745fdc	demo-signature	\N	2026-04-16 18:31:45.462661+00	\N	\N
8fd043ff-6d6f-43af-839b-14df56c9e898	IMD-CC-2026-000029	729fd30e-9cfb-4751-bbdb-935fbbb7f994	ad72951b-6768-4887-8063-287ff8f51bf1	a1abd333-f3f5-4297-9329-f7993537bf68	68.00	{"user": "729fd30e-9cfb-4751-bbdb-935fbbb7f994", "score": 68, "course": "ad72951b-6768-4887-8063-287ff8f51bf1"}	29f5fadbafd2707ee821cd9c9a6b2b6405d7c291e65104666d469268db745fdc	demo-signature	\N	2026-03-17 18:31:45.462661+00	\N	\N
f6365ea0-61f2-48b1-8369-67757c365a9d	IMD-CC-2026-000030	625944b1-2b9b-433b-9af5-e72894aa7a58	ad72951b-6768-4887-8063-287ff8f51bf1	e14b92be-7550-4e36-833f-966a474bcc57	66.00	{"user": "625944b1-2b9b-433b-9af5-e72894aa7a58", "score": 66, "course": "ad72951b-6768-4887-8063-287ff8f51bf1"}	4501e2cf6b5252b87a7f3b9155934f8905d7c291e65104666d469268db745fdc	demo-signature	\N	2026-07-21 18:31:45.462661+00	\N	\N
35cb02b8-393e-4f79-b2b0-b7ddd5b33e2f	IMD-CC-2026-000031	9bab5f84-a53e-49d6-91f8-eef87bf5960c	ad72951b-6768-4887-8063-287ff8f51bf1	c3932a21-5edc-4996-a5dc-90fb4ee49daa	70.00	{"user": "9bab5f84-a53e-49d6-91f8-eef87bf5960c", "score": 70, "course": "ad72951b-6768-4887-8063-287ff8f51bf1"}	cae1250b2c7e5d7f9180764f9a406a3e05d7c291e65104666d469268db745fdc	demo-signature	\N	2026-05-08 18:31:45.462661+00	\N	\N
60ebac05-a24d-41f3-b1b4-586edf4a6c50	IMD-CC-2026-000032	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	ad72951b-6768-4887-8063-287ff8f51bf1	a0a11efe-7185-4acd-aa9b-1d89c14d6602	73.00	{"user": "f32344cc-9180-4953-b2cd-ba0f4bdb2eea", "score": 73, "course": "ad72951b-6768-4887-8063-287ff8f51bf1"}	98a17efba20de5d31c254ca540b657c805d7c291e65104666d469268db745fdc	demo-signature	\N	2026-07-13 18:31:45.462661+00	\N	\N
191fa7fd-16d1-4017-a20c-4ebc99469ded	IMD-CC-2026-000033	732e74cf-b9b7-4adc-a43a-794430d7fe49	ad72951b-6768-4887-8063-287ff8f51bf1	fb31eefe-509f-4945-8679-922c940b0245	63.00	{"user": "732e74cf-b9b7-4adc-a43a-794430d7fe49", "score": 63, "course": "ad72951b-6768-4887-8063-287ff8f51bf1"}	0fa35ff742b691a8efccc2196820bafd05d7c291e65104666d469268db745fdc	demo-signature	\N	2026-04-26 18:31:45.462661+00	\N	\N
ab83f905-5104-47dd-b6fd-73982df0238c	IMD-CC-2026-000034	78313b75-0494-43a4-b199-ff1928254f44	ad72951b-6768-4887-8063-287ff8f51bf1	cfa204b1-18d8-46b1-9f87-76e0c3644669	61.00	{"user": "78313b75-0494-43a4-b199-ff1928254f44", "score": 61, "course": "ad72951b-6768-4887-8063-287ff8f51bf1"}	1923ffd9444e4e02427cd58dee68b6d805d7c291e65104666d469268db745fdc	demo-signature	\N	2026-04-30 18:31:45.462661+00	\N	\N
3ae34f0e-9c4f-49ea-8cb4-da6ab9c7cfeb	IMD-CC-2026-000035	b97db5e7-dca3-4f88-8318-6d457e09be91	ad72951b-6768-4887-8063-287ff8f51bf1	01dbe279-7881-4b98-ae49-c39e97a25a82	70.00	{"user": "b97db5e7-dca3-4f88-8318-6d457e09be91", "score": 70, "course": "ad72951b-6768-4887-8063-287ff8f51bf1"}	1db98410be7ef1aeda486043b8db5cee05d7c291e65104666d469268db745fdc	demo-signature	\N	2026-07-26 18:31:45.462661+00	\N	\N
d07d5b60-4cc6-476b-ad41-1e35fc83fb7e	IMD-CC-2026-000036	db9ec5a1-d0be-490d-91a6-bf32127bba75	ad72951b-6768-4887-8063-287ff8f51bf1	decfc19a-c741-4f1c-94bf-af872efd6353	68.00	{"user": "db9ec5a1-d0be-490d-91a6-bf32127bba75", "score": 68, "course": "ad72951b-6768-4887-8063-287ff8f51bf1"}	e4b15d4cb3984b2c87787b736cde4f2605d7c291e65104666d469268db745fdc	demo-signature	\N	2026-04-23 18:31:45.462661+00	\N	\N
9fe6c08b-cf76-4418-b00e-76f188a078b1	IMD-CC-2026-000037	1f511b5e-1292-4202-860e-b54f11eda21e	5317862f-92fe-4e22-ae0a-a244abce364c	d41dc7c6-bd1e-4318-884a-edaab8973f7d	68.00	{"user": "1f511b5e-1292-4202-860e-b54f11eda21e", "score": 68, "course": "5317862f-92fe-4e22-ae0a-a244abce364c"}	f5f7f7350e98d2c795c81746f6122fc6ccacdcd37865dd85a25df34820edb5bd	demo-signature	\N	2026-09-05 18:31:45.462661+00	\N	\N
5d48b4ab-9d8c-43b4-92aa-8ff43ff5b765	IMD-CC-2026-000038	ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	5317862f-92fe-4e22-ae0a-a244abce364c	3d93c093-7eee-4a49-84be-d423d85f7145	65.00	{"user": "ee225bc3-ea1f-4dcc-9f2b-500f66e47b52", "score": 65, "course": "5317862f-92fe-4e22-ae0a-a244abce364c"}	62a4cb627018532a21d11a1364df38c0ccacdcd37865dd85a25df34820edb5bd	demo-signature	\N	2026-02-17 18:31:45.462661+00	\N	\N
bea220d2-5770-4288-bb27-7f9c7b346478	IMD-CC-2026-000039	c41a5544-af25-44ec-9fab-26fa3a4e08a5	5317862f-92fe-4e22-ae0a-a244abce364c	85db4cf1-3782-4a3f-b696-73ac79db8e9f	74.00	{"user": "c41a5544-af25-44ec-9fab-26fa3a4e08a5", "score": 74, "course": "5317862f-92fe-4e22-ae0a-a244abce364c"}	a895fbc00af508509156ac217fcd1fd3ccacdcd37865dd85a25df34820edb5bd	demo-signature	\N	2026-09-10 18:31:45.462661+00	\N	\N
32ade1fd-7511-4353-b7de-14aa8adcc0a5	IMD-CC-2026-000040	707e086b-3312-442d-ac6d-9776ebe73deb	5317862f-92fe-4e22-ae0a-a244abce364c	d96df2e9-f7ba-48c8-a5b5-43779dadeddd	73.00	{"user": "707e086b-3312-442d-ac6d-9776ebe73deb", "score": 73, "course": "5317862f-92fe-4e22-ae0a-a244abce364c"}	7953fe96777a776db3607cc709fcd339ccacdcd37865dd85a25df34820edb5bd	demo-signature	\N	2026-02-27 18:31:45.462661+00	\N	\N
1e5d5e86-a46a-4f7b-92ee-d3a747cea6c5	IMD-CC-2026-000041	09cc88c9-6251-413b-9873-df6f5bb8b24d	5317862f-92fe-4e22-ae0a-a244abce364c	f1b4fe92-2e5f-449d-acde-d2bf48b7edc3	67.00	{"user": "09cc88c9-6251-413b-9873-df6f5bb8b24d", "score": 67, "course": "5317862f-92fe-4e22-ae0a-a244abce364c"}	0791beab58f4ecb07b902123e226f1d7ccacdcd37865dd85a25df34820edb5bd	demo-signature	\N	2026-05-15 18:31:45.462661+00	\N	\N
702724f7-e54d-4a4e-9770-60049cde97a0	IMD-CC-2026-000042	7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	5317862f-92fe-4e22-ae0a-a244abce364c	9bdb5eb3-968d-4824-a46f-996e42418972	73.00	{"user": "7d98c1dd-e2b5-4fb6-aa2a-68849c41f058", "score": 73, "course": "5317862f-92fe-4e22-ae0a-a244abce364c"}	5e0bd868915690c342b2a9ea57ff69b3ccacdcd37865dd85a25df34820edb5bd	demo-signature	\N	2026-02-26 18:31:45.462661+00	\N	\N
a2fcc231-89b1-4b24-a728-5398223b67d6	IMD-CC-2026-000043	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	5317862f-92fe-4e22-ae0a-a244abce364c	badf5341-c638-4188-be52-0a2070b3cc7d	70.00	{"user": "89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f", "score": 70, "course": "5317862f-92fe-4e22-ae0a-a244abce364c"}	868f1fc63454f6175c40036484ecf084ccacdcd37865dd85a25df34820edb5bd	demo-signature	\N	2026-07-15 18:31:45.462661+00	\N	\N
694aefc4-8ff7-4c97-8207-ebe16886d93d	IMD-CC-2026-000044	7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	5317862f-92fe-4e22-ae0a-a244abce364c	8de94a19-ca5d-4acd-adc7-270f01f6b304	73.00	{"user": "7bf1a0d2-b293-4feb-b3d9-a07cf3db5249", "score": 73, "course": "5317862f-92fe-4e22-ae0a-a244abce364c"}	6ef4fc9b8f8ba8745fc84788dedd2677ccacdcd37865dd85a25df34820edb5bd	demo-signature	\N	2026-05-06 18:31:45.462661+00	\N	\N
cdfb610d-3423-4480-a347-bac8f891631d	IMD-CC-2026-000045	a8c5b60b-8763-4325-900d-07d7540e6015	5317862f-92fe-4e22-ae0a-a244abce364c	c65598a6-72fd-4b1f-b63c-25c7bd80abaa	73.00	{"user": "a8c5b60b-8763-4325-900d-07d7540e6015", "score": 73, "course": "5317862f-92fe-4e22-ae0a-a244abce364c"}	db6fe2688288c286440f15ad0c46330fccacdcd37865dd85a25df34820edb5bd	demo-signature	\N	2026-08-08 18:31:45.462661+00	\N	\N
41756903-b37e-4cb5-b71f-2fb9d296a269	IMD-CC-2026-000046	a6afe850-9547-4fac-892c-00558ad8f725	5317862f-92fe-4e22-ae0a-a244abce364c	fe2409ea-b402-49e1-92ef-110183549ae4	69.00	{"user": "a6afe850-9547-4fac-892c-00558ad8f725", "score": 69, "course": "5317862f-92fe-4e22-ae0a-a244abce364c"}	cb4e4829f9ccebf7b65f194cc8dfa2b2ccacdcd37865dd85a25df34820edb5bd	demo-signature	\N	2026-03-14 18:31:45.462661+00	\N	\N
454b2700-3856-423f-8de7-eea7a4659202	IMD-CC-2026-000047	152f1a01-df4b-4828-bf72-c1616f324c38	32ab414d-cb9f-48ed-b3b5-97537b736196	39043f98-9059-4d57-97fc-f34a09211d13	80.00	{"user": "152f1a01-df4b-4828-bf72-c1616f324c38", "score": 80, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	fde8a86206b8d0ca326a2fc7443f7efc6a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-03-18 18:31:45.462661+00	\N	\N
d8227056-918a-400b-8e87-5e609265f7cf	IMD-CC-2026-000048	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	32ab414d-cb9f-48ed-b3b5-97537b736196	ff65f9c7-26a6-49d3-83da-9aa99760afef	72.00	{"user": "89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f", "score": 72, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	21a48d928489aa3db57429c976e27a176a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-03-19 18:31:45.462661+00	\N	\N
9e272ac1-07ed-4e25-836f-fe91e31eaeb1	IMD-CC-2026-000049	b4c20820-6710-46e1-b3cf-939b8bc00f93	32ab414d-cb9f-48ed-b3b5-97537b736196	71f848ad-3fce-4e0c-a301-284c9836d1ba	75.00	{"user": "b4c20820-6710-46e1-b3cf-939b8bc00f93", "score": 75, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	6bc167a449e0f0ec31a19c312866064b6a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-07-03 18:31:45.462661+00	\N	\N
353d79f6-d589-40b9-8507-9560fb432485	IMD-CC-2026-000050	032c01d5-4b5e-44f6-821d-2ba4342c938f	32ab414d-cb9f-48ed-b3b5-97537b736196	c9e46c3a-6b59-4754-b0f8-5c25605c0f3c	83.00	{"user": "032c01d5-4b5e-44f6-821d-2ba4342c938f", "score": 83, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	c625ffd38586af66e4618c297821f2f26a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-03-25 18:31:45.462661+00	\N	\N
d9848822-def3-407d-a942-57ebb536ef59	IMD-CC-2026-000051	fbc637df-19cd-4ec5-b08d-49ce15747076	32ab414d-cb9f-48ed-b3b5-97537b736196	73ead45e-b337-4eb0-8be0-e5bc896b7b17	92.00	{"user": "fbc637df-19cd-4ec5-b08d-49ce15747076", "score": 92, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	0412f4dbf46313431cd10b5c29b2583d6a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-04-07 18:31:45.462661+00	\N	\N
2424eff7-0635-469c-849e-510949e4e0ab	IMD-CC-2026-000052	77c70aa0-ddd9-4445-be30-4817de1cbfd0	32ab414d-cb9f-48ed-b3b5-97537b736196	7993edd6-1373-4205-9993-d4f727c61714	79.00	{"user": "77c70aa0-ddd9-4445-be30-4817de1cbfd0", "score": 79, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	d3aacd5bfcf26a77cb4dd931410b0f456a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-08-22 18:31:45.462661+00	\N	\N
03909232-da47-4b92-ae82-d63e2312b1d4	IMD-CC-2026-000053	2e35b549-e1b5-4e61-a221-b0799208258c	32ab414d-cb9f-48ed-b3b5-97537b736196	010c8d40-86df-47ae-8639-4c7c1f459859	94.00	{"user": "2e35b549-e1b5-4e61-a221-b0799208258c", "score": 94, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	fd436a4129a051c30118dfd35e8dc3c26a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-06-30 18:31:45.462661+00	\N	\N
71f8db0d-e35e-49b4-b217-fbfbdd325185	IMD-CC-2026-000054	4ace2ecd-317e-494c-ad50-71e2794fb907	32ab414d-cb9f-48ed-b3b5-97537b736196	f3c29d3d-5b65-47ac-aea0-2d7c3504ef67	68.00	{"user": "4ace2ecd-317e-494c-ad50-71e2794fb907", "score": 68, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	a75d61d9416eb07382990072e394fb826a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-06-25 18:31:45.462661+00	\N	\N
87bbe4c1-3d33-4036-9c63-d91188639ee0	IMD-CC-2026-000055	7ea450f4-3442-46d0-a08b-19c1e7308bde	32ab414d-cb9f-48ed-b3b5-97537b736196	7fd69d79-59c6-4667-ab04-b4284985f21b	64.00	{"user": "7ea450f4-3442-46d0-a08b-19c1e7308bde", "score": 64, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	4ac550613130f844ae06c1fbc7a8ea5a6a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-07-04 18:31:45.462661+00	\N	\N
fa43acf3-0592-4c84-965c-af62d5b7364f	IMD-CC-2026-000056	0d37acee-70ea-4604-8bd7-c995941443fd	32ab414d-cb9f-48ed-b3b5-97537b736196	94d80b83-56eb-4764-8e76-181164809f03	60.00	{"user": "0d37acee-70ea-4604-8bd7-c995941443fd", "score": 60, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	4249ff5f913ca557a09f7482c16eb4036a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-07-27 18:31:45.462661+00	\N	\N
875c9fd0-a5b3-446e-8ac8-8d5af8a026e2	IMD-CC-2026-000057	a6d5837e-0df4-4cf0-9c98-8f0da7e4a1f1	32ab414d-cb9f-48ed-b3b5-97537b736196	18a2dc89-2cca-4ffb-b45b-db95526ecf32	63.00	{"user": "a6d5837e-0df4-4cf0-9c98-8f0da7e4a1f1", "score": 63, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	ac7c4e1d439303fd5d2c494a597d7a276a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-07-30 18:31:45.462661+00	\N	\N
d2805e52-5e3c-44de-b16e-f5355f6a42ff	IMD-CC-2026-000058	60e67627-9116-4358-a94b-89c0416805f0	32ab414d-cb9f-48ed-b3b5-97537b736196	d53f0d11-24d4-4d26-850d-8298a7063918	80.00	{"user": "60e67627-9116-4358-a94b-89c0416805f0", "score": 80, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	634deaa073d9f30139094ae1763748bc6a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-08-05 18:31:45.462661+00	\N	\N
de4dbae1-a61b-4fde-a910-a8611fdc8692	IMD-CC-2026-000059	cbd81a81-1d5a-4273-8494-11efdd5fd354	32ab414d-cb9f-48ed-b3b5-97537b736196	308bd86e-ee02-4a02-9073-8b5dad9f41e7	93.00	{"user": "cbd81a81-1d5a-4273-8494-11efdd5fd354", "score": 93, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	988b11a4dcff38afab396807f62ba5476a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-06-26 18:31:45.462661+00	\N	\N
abf26f25-9cfe-4ace-91e7-80c2ab3798de	IMD-CC-2026-000060	3ded69a7-290c-47f6-bd29-7369f6f8e3c8	32ab414d-cb9f-48ed-b3b5-97537b736196	cacad3fb-a3cc-4daf-b4f4-c3a92faf16d9	77.00	{"user": "3ded69a7-290c-47f6-bd29-7369f6f8e3c8", "score": 77, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	1f6f0857e88ecfc182979cfc3227120c6a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-07-05 18:31:45.462661+00	\N	\N
6c182c29-cc84-4444-be2a-5e25a82dce66	IMD-CC-2026-000061	1e418187-2717-4b94-934c-e5ca025993d8	32ab414d-cb9f-48ed-b3b5-97537b736196	7d85e913-aa63-404e-9143-e9e230f6bbfb	71.00	{"user": "1e418187-2717-4b94-934c-e5ca025993d8", "score": 71, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	0247fbbae8bc977da8b154e031c265de6a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-06-23 18:31:45.462661+00	\N	\N
04d48eea-0dd5-4b63-9c29-0f2b3268de44	IMD-CC-2026-000062	4135122d-a240-499c-8de4-3db650d7acc9	32ab414d-cb9f-48ed-b3b5-97537b736196	b07e25d7-9fab-475d-a84d-e9793f9e1a22	66.00	{"user": "4135122d-a240-499c-8de4-3db650d7acc9", "score": 66, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	728f3ec5d57aca4d72a9264f8c3971906a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-03-31 18:31:45.462661+00	\N	\N
1f40d6c0-6a54-4331-b584-10ed09198bb9	IMD-CC-2026-000063	48ae8c9d-e783-46c2-abf3-cc9d31e16d81	32ab414d-cb9f-48ed-b3b5-97537b736196	18274278-e95a-4cce-a2a9-963d56aae819	81.00	{"user": "48ae8c9d-e783-46c2-abf3-cc9d31e16d81", "score": 81, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	6f27e529a2907010adfb5c803024d7126a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-07-06 18:31:45.462661+00	\N	\N
c0d9e480-5d9b-4618-9e08-f15e0c464856	IMD-CC-2026-000064	d05292f5-3e9f-4e51-bb50-05a6534dc9b8	32ab414d-cb9f-48ed-b3b5-97537b736196	4d7cc908-82de-47d3-8c74-37772cc70195	60.00	{"user": "d05292f5-3e9f-4e51-bb50-05a6534dc9b8", "score": 60, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	4a5effee5eb949af9ebc4c346e63253e6a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-03-30 18:31:45.462661+00	\N	\N
066260e1-9526-428e-a077-310dfdee66ff	IMD-CC-2026-000065	6f1d6dd6-daa9-4660-a06f-527bf32f663e	32ab414d-cb9f-48ed-b3b5-97537b736196	848e6636-1e80-4df5-8628-7882864fd62c	68.00	{"user": "6f1d6dd6-daa9-4660-a06f-527bf32f663e", "score": 68, "course": "32ab414d-cb9f-48ed-b3b5-97537b736196"}	21a6c8c0a88203885cc222def029a17a6a38ea7befa244d06aa304736e2e8385	demo-signature	\N	2026-08-09 18:31:45.462661+00	\N	\N
7cd42f74-6881-4b9b-bd51-7b1951acb11a	IMD-CC-2026-000066	8a83194a-d3bc-49dd-8594-ed05a26d23a0	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	3a3b9ffa-d2e7-47df-9416-74c595598b87	76.00	{"user": "8a83194a-d3bc-49dd-8594-ed05a26d23a0", "score": 76, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	e9ec0780a414ecb587a3177fb90ecf7658ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-04-26 18:31:45.462661+00	\N	\N
4e9999e1-b7d9-4d01-b70d-0fb42a212bb4	IMD-CC-2026-000067	cd441b90-ef66-411c-b22e-4e046c29677f	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	c2a240ae-3933-4a99-95dc-7f93a1e95b29	81.00	{"user": "cd441b90-ef66-411c-b22e-4e046c29677f", "score": 81, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	dcab81f230b0000911b769208027f08258ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-08-01 18:31:45.462661+00	\N	\N
a0cb9584-2727-4288-b84c-fd6f3a0210cf	IMD-CC-2026-000068	eee6bbaa-75eb-44f4-9892-d46194b720a9	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	c8178caa-06cc-4a13-b8f5-6d08f4b67575	97.00	{"user": "eee6bbaa-75eb-44f4-9892-d46194b720a9", "score": 97, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	27df41e53f1e3a01ec156fbe8c1781ad58ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-03-16 18:31:45.462661+00	\N	\N
9e12c806-344d-48dd-9b99-78d56bf1e753	IMD-CC-2026-000069	9389e5a2-816f-4e52-950b-a9af117c7ad1	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	0e7149ed-a292-441e-aacc-be1ce19ac9f9	83.00	{"user": "9389e5a2-816f-4e52-950b-a9af117c7ad1", "score": 83, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	fcc6ac1fdefa68a07ea28c6fd88205e758ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-07-19 18:31:45.462661+00	\N	\N
6db6c010-4355-4347-a3ad-d34348a3e554	IMD-CC-2026-000070	ae420db9-d867-40d1-8d1a-01ee5d62e270	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	b95f53a6-3e04-44d1-8125-85702056aff4	90.00	{"user": "ae420db9-d867-40d1-8d1a-01ee5d62e270", "score": 90, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	ee965f492ca68b945c0dc27036b4b41358ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-09-05 18:31:45.462661+00	\N	\N
f5ed370f-291f-4e5b-b1a2-e9747f940816	IMD-CC-2026-000071	7f53c53d-3323-4146-8cea-01d6c38b4f77	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	a06ebac7-4b52-4209-9e16-4d9dd0efce3e	74.00	{"user": "7f53c53d-3323-4146-8cea-01d6c38b4f77", "score": 74, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	1317e0400bc846ce7316bc3b49c00b0058ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-04-24 18:31:45.462661+00	\N	\N
e7c6a1e1-a571-4330-b964-5e53736516c2	IMD-CC-2026-000072	4d5fd264-452f-4436-8eca-5c6c62afb143	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	9541ac5a-06c1-4c59-97e7-510eb9cf4a2b	100.00	{"user": "4d5fd264-452f-4436-8eca-5c6c62afb143", "score": 100, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	7d4b5cf70e75dd1647b65e9ab9799df058ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-03-13 18:31:45.462661+00	\N	\N
dffc4aca-3af6-41f1-84e0-bae5941c7553	IMD-CC-2026-000073	306af47d-26b6-4dc3-96ae-eb178609c1f6	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	b5d655b3-7e4b-4a06-86fd-11cba3bcf198	62.00	{"user": "306af47d-26b6-4dc3-96ae-eb178609c1f6", "score": 62, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	5d13e3ea0ca5866e1a8af29ff6faf3f358ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-03-03 18:31:45.462661+00	\N	\N
91a9c216-b47a-4f27-9738-471b7bfa4985	IMD-CC-2026-000074	fbc637df-19cd-4ec5-b08d-49ce15747076	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	de2c53ba-d563-4c9c-ac50-e9b2f8982152	76.00	{"user": "fbc637df-19cd-4ec5-b08d-49ce15747076", "score": 76, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	0bd9104215b7680efd9e63b2eaf0ce8758ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-06-07 18:31:45.462661+00	\N	\N
ef04238a-da36-4457-be81-c5c4e6294ba6	IMD-CC-2026-000075	78313b75-0494-43a4-b199-ff1928254f44	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	ab8eeef0-039b-43df-ad50-b6bef66fbe9b	83.00	{"user": "78313b75-0494-43a4-b199-ff1928254f44", "score": 83, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	a1e1a8b26b6a67c8f046f75f2e37074858ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-08-10 18:31:45.462661+00	\N	\N
a6fa00b5-3cd1-4218-963f-5d0f35c9ad94	IMD-CC-2026-000076	1e9340db-2cfd-419f-8894-9448da0bbc19	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	ad9d0cd2-f535-4dfc-b0d5-0bdee25f2b81	75.00	{"user": "1e9340db-2cfd-419f-8894-9448da0bbc19", "score": 75, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	27b8a4799e2344755a4010f9ed3b5cf858ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-09-11 18:31:45.462661+00	\N	\N
ee69d47f-b1eb-4957-b140-9316df8aa428	IMD-CC-2026-000077	f1bc49b2-13bf-4cd2-a5ac-6aa2c12e8f95	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	b61e063d-8736-406c-8110-a12d73abeb1b	98.00	{"user": "f1bc49b2-13bf-4cd2-a5ac-6aa2c12e8f95", "score": 98, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	897481e13fd6050a216ad002e78b189758ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-04-28 18:31:45.462661+00	\N	\N
ff5168ca-e362-4888-88fc-fe56912c1d4d	IMD-CC-2026-000078	1f511b5e-1292-4202-860e-b54f11eda21e	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	6e50cecd-1ad3-4d8f-b7fe-cbafde9eb0c5	96.00	{"user": "1f511b5e-1292-4202-860e-b54f11eda21e", "score": 96, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	4b72c2b32dae17e155421cafb9ccd79858ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-09-18 18:31:45.462661+00	\N	\N
43fb8ccf-cf27-4fd5-bc96-6e5f02f0794b	IMD-CC-2026-000079	88b2de0e-fb93-4402-98ef-3c1bd149f61d	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	795abb93-0039-4bea-bda3-20af432a2413	71.00	{"user": "88b2de0e-fb93-4402-98ef-3c1bd149f61d", "score": 71, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	5ad1694770c26865a75d829dd0c743ba58ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-08-10 18:31:45.462661+00	\N	\N
ea4016d7-0c50-40a9-8eb5-acb66a856210	IMD-CC-2026-000080	0d37acee-70ea-4604-8bd7-c995941443fd	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	d0c940de-0255-48af-91fb-23f20ba7b370	80.00	{"user": "0d37acee-70ea-4604-8bd7-c995941443fd", "score": 80, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	72e7b8e44217b819dfd442d9d219cfa458ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-04-12 18:31:45.462661+00	\N	\N
a7dd7f95-de9f-46fc-9035-ea914fe25d8e	IMD-CC-2026-000081	ab65843a-c349-4b21-b43b-9302ed8231b4	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	72e2bcdc-c808-474c-8e14-1946aa3a2a12	88.00	{"user": "ab65843a-c349-4b21-b43b-9302ed8231b4", "score": 88, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	effe49fc1c8fa085894f9ed7bdc4a2cc58ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-07-22 18:31:45.462661+00	\N	\N
791d0b16-a5dd-4f3e-9892-81d17880319f	IMD-CC-2026-000082	8a1eab45-738c-41b6-b35d-7737f5e2f64e	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	24abdc83-fe29-4efc-826d-ed4a64f548bd	76.00	{"user": "8a1eab45-738c-41b6-b35d-7737f5e2f64e", "score": 76, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	264b58797d4c05d05ffba6a55f961d3058ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-05-22 18:31:45.462661+00	\N	\N
8968a224-1784-4301-ad65-3277adc54728	IMD-CC-2026-000083	3b6030a2-3993-4389-8c6c-d3427e0e680b	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	42069d14-efa2-4a20-90ba-4a419deb875e	70.00	{"user": "3b6030a2-3993-4389-8c6c-d3427e0e680b", "score": 70, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	9a5c223c1d1a04e34a54cd6d3248159f58ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-05-22 18:31:45.462661+00	\N	\N
b85b9f48-967b-43a6-a9ee-7a60cd113cba	IMD-CC-2026-000084	15a2f413-02d0-4624-9468-3a8bec2ba6b8	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	404b6f3d-89f2-43f6-a9ec-b5e83c17d88d	100.00	{"user": "15a2f413-02d0-4624-9468-3a8bec2ba6b8", "score": 100, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	b58bd3f30c6ddc0078c796b72b35179458ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-05-19 18:31:45.462661+00	\N	\N
ccf77507-b556-4fab-acb4-6311bc5359c1	IMD-CC-2026-000085	5d1e34b1-8861-4358-96e3-f5ed89f5c9d2	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	227e2ec6-0bb9-4514-bd66-902476ae4131	92.00	{"user": "5d1e34b1-8861-4358-96e3-f5ed89f5c9d2", "score": 92, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	9b72799d0cf2cb9a8b022831c5d67cc258ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-07-05 18:31:45.462661+00	\N	\N
285ba59d-4852-4d09-879e-7c67690d2bdd	IMD-CC-2026-000086	d22f23cf-8a58-499a-8dba-92806f1622ef	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	0d687657-6208-4b8c-8b5c-df6b063e4c01	66.00	{"user": "d22f23cf-8a58-499a-8dba-92806f1622ef", "score": 66, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	44561634b5f69c7c70f7c085a64ba0fb58ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-08-01 18:31:45.462661+00	\N	\N
6de78b1e-0957-4d51-817e-28f71d8f5b42	IMD-CC-2026-000087	ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	a5d84991-876e-4275-98ae-4054a6e116eb	84.00	{"user": "ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5", "score": 84, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	ca2cf779132655de8782a8dc5f874cad58ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-07-25 18:31:45.462661+00	\N	\N
da93a705-51ba-4e68-9e26-2d13f05ebf2d	IMD-CC-2026-000088	a7bae3c0-0e2c-42db-8e35-79114d5dfe80	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	602e6f9c-d2dc-416f-9505-f1ee41949ecb	62.00	{"user": "a7bae3c0-0e2c-42db-8e35-79114d5dfe80", "score": 62, "course": "19b09698-d481-4bdf-95c3-6dd7b1aa8afa"}	e118568f18af3db23067616544279aa558ffd162e8b9f102e7b121d5237fdc16	demo-signature	\N	2026-06-04 18:31:45.462661+00	\N	\N
6b9b3bf7-2459-479e-a4df-8e4593b2ca96	IMD-CC-2026-000089	3e1e22ae-3497-44dc-bb66-1a3c24a5af91	33add9da-29ab-4a45-90b2-f5b8f4723f3d	c94acd89-e7e8-441b-b2a2-2327e55ef25b	72.00	{"user": "3e1e22ae-3497-44dc-bb66-1a3c24a5af91", "score": 72, "course": "33add9da-29ab-4a45-90b2-f5b8f4723f3d"}	f2bd74c76ba25f32970267fead190afc872d26725bd63a543a05f1bddfdb7e04	demo-signature	\N	2026-06-29 18:31:45.462661+00	\N	\N
a544a342-0d68-4522-b2ec-94e43fd7d6ec	IMD-CC-2026-000090	8be014b0-ed46-43db-89e2-91a301c618db	33add9da-29ab-4a45-90b2-f5b8f4723f3d	1b2029c4-460c-474f-a183-b64d52e8202c	69.00	{"user": "8be014b0-ed46-43db-89e2-91a301c618db", "score": 69, "course": "33add9da-29ab-4a45-90b2-f5b8f4723f3d"}	df6bd4fd4cf94ddfbb7c3d41c0eaaef4872d26725bd63a543a05f1bddfdb7e04	demo-signature	\N	2026-08-18 18:31:45.462661+00	\N	\N
ca4aeaee-b579-4a4d-8f36-1312a3cedf70	IMD-CC-2026-000091	a17abc66-209e-405f-bcd6-c39e54cbce66	33add9da-29ab-4a45-90b2-f5b8f4723f3d	c1ab95ec-4306-4492-8064-93e74ec1df71	67.00	{"user": "a17abc66-209e-405f-bcd6-c39e54cbce66", "score": 67, "course": "33add9da-29ab-4a45-90b2-f5b8f4723f3d"}	389fd22ff2a217fcde97bffde006ff65872d26725bd63a543a05f1bddfdb7e04	demo-signature	\N	2026-05-16 18:31:45.462661+00	\N	\N
21c230c1-c505-48f5-91f9-27c0ebd0c912	IMD-CC-2026-000092	8ffbd0cf-b807-4193-af37-3a61482c76eb	33add9da-29ab-4a45-90b2-f5b8f4723f3d	1e9473a7-a27c-4c8d-bec0-0bc69ced5258	62.00	{"user": "8ffbd0cf-b807-4193-af37-3a61482c76eb", "score": 62, "course": "33add9da-29ab-4a45-90b2-f5b8f4723f3d"}	c0850881d203dbbc862e8a55f6a795c7872d26725bd63a543a05f1bddfdb7e04	demo-signature	\N	2026-06-24 18:31:45.462661+00	\N	\N
56aae0c7-317e-4c30-ad47-46f314459b89	IMD-CC-2026-000093	c41a5544-af25-44ec-9fab-26fa3a4e08a5	33add9da-29ab-4a45-90b2-f5b8f4723f3d	cc30cab4-89a4-4f5e-8521-2c1661e20a2d	60.00	{"user": "c41a5544-af25-44ec-9fab-26fa3a4e08a5", "score": 60, "course": "33add9da-29ab-4a45-90b2-f5b8f4723f3d"}	8b84dcdf3c90143fe2adfa42250616ed872d26725bd63a543a05f1bddfdb7e04	demo-signature	\N	2026-06-07 18:31:45.462661+00	\N	\N
b380102f-26c0-47ab-b7a3-edf24c47ceb7	IMD-CC-2026-000094	f1bc49b2-13bf-4cd2-a5ac-6aa2c12e8f95	33add9da-29ab-4a45-90b2-f5b8f4723f3d	95396777-6313-4661-a0b6-8eb6b824a900	76.00	{"user": "f1bc49b2-13bf-4cd2-a5ac-6aa2c12e8f95", "score": 76, "course": "33add9da-29ab-4a45-90b2-f5b8f4723f3d"}	8c984f908e264dc444c857d9bac47148872d26725bd63a543a05f1bddfdb7e04	demo-signature	\N	2026-05-11 18:31:45.462661+00	\N	\N
ab97fd43-ece1-450d-9a49-4e1e9654d768	IMD-CC-2026-000095	7b1099fc-7596-4be6-9ab4-990d535c39a5	33add9da-29ab-4a45-90b2-f5b8f4723f3d	4c98bab5-bf15-453b-b1fb-2594e555696c	61.00	{"user": "7b1099fc-7596-4be6-9ab4-990d535c39a5", "score": 61, "course": "33add9da-29ab-4a45-90b2-f5b8f4723f3d"}	a2a2e252d5fd5a8bf9d8370a914178b7872d26725bd63a543a05f1bddfdb7e04	demo-signature	\N	2026-08-25 18:31:45.462661+00	\N	\N
f6a67f4e-0e3b-4372-99e6-5ca22c142c8c	IMD-CC-2026-000096	bd78a83d-5740-4d0d-9000-cdf29d332f27	8db3d256-cbbd-4863-b45a-d035bffdba03	dd062822-69b9-4dbe-bd7c-aa94c5b9231c	62.00	{"user": "bd78a83d-5740-4d0d-9000-cdf29d332f27", "score": 62, "course": "8db3d256-cbbd-4863-b45a-d035bffdba03"}	f13ca7e19f252f58945fe74b5a9884fc239fd37287b706574f7de0496fa992b1	demo-signature	\N	2026-07-09 18:31:45.462661+00	\N	\N
2f3a4755-ff71-453c-8ea7-f4c5b983afd5	IMD-CC-2026-000097	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	8db3d256-cbbd-4863-b45a-d035bffdba03	24b10d1e-344e-4f74-b73e-6861b8891af6	63.00	{"user": "89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f", "score": 63, "course": "8db3d256-cbbd-4863-b45a-d035bffdba03"}	06c7c41a8929fd43c9c05aca07c5ff93239fd37287b706574f7de0496fa992b1	demo-signature	\N	2026-05-18 18:31:45.462661+00	\N	\N
cc801dd9-bdad-4165-af86-2d21acb8c647	IMD-CC-2026-000098	4d5fd264-452f-4436-8eca-5c6c62afb143	8db3d256-cbbd-4863-b45a-d035bffdba03	a6c5ca28-5a03-419a-a4b5-8a02b18dc93f	70.00	{"user": "4d5fd264-452f-4436-8eca-5c6c62afb143", "score": 70, "course": "8db3d256-cbbd-4863-b45a-d035bffdba03"}	c869cdff0e3784f54025b88cf000eef1239fd37287b706574f7de0496fa992b1	demo-signature	\N	2026-05-13 18:31:45.462661+00	\N	\N
1f289e98-e8a8-4da9-a89b-2e0dab1bd7c1	IMD-CC-2026-000099	3af00a36-1f7b-4846-a52a-b1871416c5b1	8db3d256-cbbd-4863-b45a-d035bffdba03	8077aa42-ac5d-4ae6-a4ea-d75d4835c6c6	65.00	{"user": "3af00a36-1f7b-4846-a52a-b1871416c5b1", "score": 65, "course": "8db3d256-cbbd-4863-b45a-d035bffdba03"}	3f24b756c640e187f0fe247f619144de239fd37287b706574f7de0496fa992b1	demo-signature	\N	2026-07-31 18:31:45.462661+00	\N	\N
1ffa241f-ef04-4196-990a-5c237d4cf567	IMD-CC-2026-000100	5af34829-4d6f-425c-9f78-525896ea0526	8db3d256-cbbd-4863-b45a-d035bffdba03	f8bffd29-2578-4cdc-9498-f94aed4ec6c6	60.00	{"user": "5af34829-4d6f-425c-9f78-525896ea0526", "score": 60, "course": "8db3d256-cbbd-4863-b45a-d035bffdba03"}	dab03ecdb66b47dd6a65a51e6897e266239fd37287b706574f7de0496fa992b1	demo-signature	\N	2026-08-05 18:31:45.462661+00	\N	\N
3522d977-79d5-4333-91d9-26c9dfa55be7	IMD-CC-2026-000101	b2734396-c5d2-4b05-99d0-986a180a98a6	8db3d256-cbbd-4863-b45a-d035bffdba03	311320ca-5100-49c5-a35d-ce8aea9126d9	69.00	{"user": "b2734396-c5d2-4b05-99d0-986a180a98a6", "score": 69, "course": "8db3d256-cbbd-4863-b45a-d035bffdba03"}	0c3bee1d69a0ccafe3ad63d8bbc0f941239fd37287b706574f7de0496fa992b1	demo-signature	\N	2026-08-02 18:31:45.462661+00	\N	\N
dc257cd8-ca7f-4cee-84ce-769c0cc2bf01	IMD-CC-2026-000102	c41a5544-af25-44ec-9fab-26fa3a4e08a5	8db3d256-cbbd-4863-b45a-d035bffdba03	69bf3d9f-1751-4cb4-bc9d-c75a0562b47e	65.00	{"user": "c41a5544-af25-44ec-9fab-26fa3a4e08a5", "score": 65, "course": "8db3d256-cbbd-4863-b45a-d035bffdba03"}	df479bf9ae408f03b99cd584e85adab8239fd37287b706574f7de0496fa992b1	demo-signature	\N	2026-04-19 18:31:45.462661+00	\N	\N
18f07121-e1b2-4e77-b52b-822c3e3a274b	IMD-CC-2026-000103	fba30b27-7555-43f7-8c74-b84e722ebbc8	c4985880-e557-407c-8f90-5c1f5b564695	5d0cd4c3-5a25-4fa8-a72c-b960e23c3eb6	100.00	{"user": "fba30b27-7555-43f7-8c74-b84e722ebbc8", "score": 100, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	6a70742e43e08dd1d1715be9e2f3e5afc0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-09-12 18:31:45.462661+00	\N	\N
43f8a5a0-f794-4d5e-8330-a4d1ce4e6503	IMD-CC-2026-000104	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	c4985880-e557-407c-8f90-5c1f5b564695	005e6307-6b05-4e6b-8956-8140d1f80578	78.00	{"user": "0369edbf-d1ba-47c9-b17c-e67c29bf27fc", "score": 78, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	0005822f46f1002877eae414a9ad9121c0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-03-30 18:31:45.462661+00	\N	\N
c533ff0c-ea2b-4a48-8370-0c10e80bbec3	IMD-CC-2026-000105	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	c4985880-e557-407c-8f90-5c1f5b564695	158283e9-4cc3-4fef-81ee-737691d6dd4c	97.00	{"user": "89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f", "score": 97, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	e225b89c5e0350e71587616548055539c0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-06-04 18:31:45.462661+00	\N	\N
6b8a809e-839b-45f1-b30d-c44f822726e5	IMD-CC-2026-000106	17231857-2d57-46f3-aecc-cb26a0865adb	c4985880-e557-407c-8f90-5c1f5b564695	21bf957d-d4d8-47c9-b5ff-74d441097362	100.00	{"user": "17231857-2d57-46f3-aecc-cb26a0865adb", "score": 100, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	c8f47cb0450b99f46f00e0845bbe3dcec0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-03-03 18:31:45.462661+00	\N	\N
4d4cd4fb-ff77-4767-9c8f-0b7ec8508d8a	IMD-CC-2026-000107	6b116d7e-84ed-47de-81ea-2bd42ea50968	c4985880-e557-407c-8f90-5c1f5b564695	7c03259b-50d9-47f5-9502-8890a963b104	100.00	{"user": "6b116d7e-84ed-47de-81ea-2bd42ea50968", "score": 100, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	18ccf6c2ae683fdbcf68091c8ef20683c0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-08-22 18:31:45.462661+00	\N	\N
b4a2c84e-ff34-4da1-bc36-014d07275f55	IMD-CC-2026-000108	a5102b13-4107-4fe5-b7a0-064dd07042ee	c4985880-e557-407c-8f90-5c1f5b564695	656026a4-e902-4d47-9898-ab6d2bbcf07b	100.00	{"user": "a5102b13-4107-4fe5-b7a0-064dd07042ee", "score": 100, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	cce3522736ed3a076b291abe6c66acfbc0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-06-19 18:31:45.462661+00	\N	\N
fd3283e2-c8f0-4abf-a639-63e38c12c94f	IMD-CC-2026-000109	28fe79f0-6207-4e0c-8bae-1eb02eed759b	c4985880-e557-407c-8f90-5c1f5b564695	666cd898-aea8-4828-aca2-51731e0378ff	100.00	{"user": "28fe79f0-6207-4e0c-8bae-1eb02eed759b", "score": 100, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	0032c64db2f2948db4b02dfc656e7a97c0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-07-12 18:31:45.462661+00	\N	\N
6b668958-9089-4851-aab6-45330959f60e	IMD-CC-2026-000110	889560c5-9238-4463-82d8-b65d7fdba4bc	c4985880-e557-407c-8f90-5c1f5b564695	dc0aafc3-48ec-4621-9107-62cdf5105056	100.00	{"user": "889560c5-9238-4463-82d8-b65d7fdba4bc", "score": 100, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	9e08dddb624243396bd4608091aebe2ac0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-06-24 18:31:45.462661+00	\N	\N
cd579011-3e15-466e-88a4-90277f6a2596	IMD-CC-2026-000111	b97db5e7-dca3-4f88-8318-6d457e09be91	c4985880-e557-407c-8f90-5c1f5b564695	ef503045-5d49-4ae9-afb6-cf97e7d69b7f	84.00	{"user": "b97db5e7-dca3-4f88-8318-6d457e09be91", "score": 84, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	b966aa9c4b27d06ed316641ebc9b42f9c0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-08-15 18:31:45.462661+00	\N	\N
73842bcd-2442-4940-8b56-fb97297bdf45	IMD-CC-2026-000112	2731bad6-8e73-4106-8def-3df5df76b6ea	c4985880-e557-407c-8f90-5c1f5b564695	17f227d6-117d-4900-bb8f-2c4d0c1e2e5f	93.00	{"user": "2731bad6-8e73-4106-8def-3df5df76b6ea", "score": 93, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	2c75d51685dfcf21a3f40191943bf230c0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-08-19 18:31:45.462661+00	\N	\N
8fe14d47-db70-48fc-82fb-91d22db45c50	IMD-CC-2026-000113	37609501-b2cd-4810-a1d5-b2a10f0405fd	c4985880-e557-407c-8f90-5c1f5b564695	6981d67a-7c44-4d8e-bd8a-8e2f757feea0	85.00	{"user": "37609501-b2cd-4810-a1d5-b2a10f0405fd", "score": 85, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	47d9e5346d0841603dbe054dd85f2ceac0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-05-12 18:31:45.462661+00	\N	\N
ea112099-0727-44a6-a34b-ee296f8314a8	IMD-CC-2026-000114	7fe9d01e-9282-4b4d-9377-b8b5d4c7f7d2	c4985880-e557-407c-8f90-5c1f5b564695	345b9429-ff2b-4182-b5b4-a4ffffe946b8	84.00	{"user": "7fe9d01e-9282-4b4d-9377-b8b5d4c7f7d2", "score": 84, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	fb17f08cd5a410cd64e3dbca59f2ad59c0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-08-25 18:31:45.462661+00	\N	\N
b58979f0-e30d-4d09-bf5c-ab2bd1e64495	IMD-CC-2026-000115	216136af-8b6b-44ae-a787-59506613a618	c4985880-e557-407c-8f90-5c1f5b564695	036fc059-9edb-4032-ae08-1208f4a04212	100.00	{"user": "216136af-8b6b-44ae-a787-59506613a618", "score": 100, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	43b526c3f01bde7e2399f7f70a26641fc0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-07-23 18:31:45.462661+00	\N	\N
dd45630a-b53b-4756-a45e-9ad18caa87c8	IMD-CC-2026-000116	fda17094-1c9f-45de-a42c-aa815d09bc2a	c4985880-e557-407c-8f90-5c1f5b564695	216c2c72-300e-40bc-acfd-be4aaa5a0b8f	94.00	{"user": "fda17094-1c9f-45de-a42c-aa815d09bc2a", "score": 94, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	1b69a497e7893d2ae1f47dde9c48e834c0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-04-28 18:31:45.462661+00	\N	\N
ca2afc1a-e291-4477-bde2-c8930753a469	IMD-CC-2026-000117	5d9905c7-91e8-4bd9-b187-b1b8772e0f63	c4985880-e557-407c-8f90-5c1f5b564695	d669d5d9-0c45-428b-b210-43b4f3e62fe2	79.00	{"user": "5d9905c7-91e8-4bd9-b187-b1b8772e0f63", "score": 79, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	6a68006b626beb762986a1186794fe96c0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-05-07 18:31:45.462661+00	\N	\N
a453c9fc-9680-413e-84a0-a73b107e6a48	IMD-CC-2026-000118	feb2fb92-ce04-48c5-8a5f-9d2e832d1644	c4985880-e557-407c-8f90-5c1f5b564695	06a3cdd1-1006-459b-be68-90586112f9ac	87.00	{"user": "feb2fb92-ce04-48c5-8a5f-9d2e832d1644", "score": 87, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	01fb8489fd6019c0f9be1da9c61b268bc0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-08-08 18:31:45.462661+00	\N	\N
3127ed53-688d-4c81-9d0a-11016ff7acbb	IMD-CC-2026-000119	7acc259e-1231-481b-ab79-59821fd46534	c4985880-e557-407c-8f90-5c1f5b564695	ed8f969d-d44b-4468-852a-23126525502b	79.00	{"user": "7acc259e-1231-481b-ab79-59821fd46534", "score": 79, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	9735aa37f97c0a726f861071404234d5c0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-06-19 18:31:45.462661+00	\N	\N
eda47852-73c7-479b-9e32-c099f99f97df	IMD-CC-2026-000120	db9ec5a1-d0be-490d-91a6-bf32127bba75	c4985880-e557-407c-8f90-5c1f5b564695	219cf33c-4bde-49fd-831b-92866846c9e8	85.00	{"user": "db9ec5a1-d0be-490d-91a6-bf32127bba75", "score": 85, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	94a24ca87d9d0d918af19f6bea5e58e6c0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-05-09 18:31:45.462661+00	\N	\N
aa361d0e-e461-4be3-9eff-55a2ddb6df8f	IMD-CC-2026-000121	a6f0ed93-9d6b-4592-a13e-5435550b4db2	c4985880-e557-407c-8f90-5c1f5b564695	5c5e336c-282a-4709-bfe7-d861547ff89c	100.00	{"user": "a6f0ed93-9d6b-4592-a13e-5435550b4db2", "score": 100, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	35a81fbe33cd114fea5c865efe7a3b0dc0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-03-14 18:31:45.462661+00	\N	\N
edbafd75-6f7f-46d2-8dfb-932af4bbad06	IMD-CC-2026-000122	8be014b0-ed46-43db-89e2-91a301c618db	c4985880-e557-407c-8f90-5c1f5b564695	985b4e6b-19f9-4d4b-b308-3533545618a8	76.00	{"user": "8be014b0-ed46-43db-89e2-91a301c618db", "score": 76, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	f263a3d12c0102dab03aa2f67648a54cc0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-06-16 18:31:45.462661+00	\N	\N
2169229a-e02d-464d-bf55-3fd8fdad0595	IMD-CC-2026-000123	ab65843a-c349-4b21-b43b-9302ed8231b4	c4985880-e557-407c-8f90-5c1f5b564695	8df00cd9-1485-4cc5-b0cf-6cea37f50556	100.00	{"user": "ab65843a-c349-4b21-b43b-9302ed8231b4", "score": 100, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	bd584eefcda05e4fe0a49787d8d7bea6c0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-08-13 18:31:45.462661+00	\N	\N
82afd53a-ed41-4700-a966-f3c83674b827	IMD-CC-2026-000124	46e6d439-49ab-4001-b576-7df03d3babee	c4985880-e557-407c-8f90-5c1f5b564695	88a871cf-ffda-4030-b707-5c18616b0510	92.00	{"user": "46e6d439-49ab-4001-b576-7df03d3babee", "score": 92, "course": "c4985880-e557-407c-8f90-5c1f5b564695"}	5cfc127f71ef22491d4048ff9341cc0dc0f43754f46b68c7949b56b39d89ce6b	demo-signature	\N	2026-08-20 18:31:45.462661+00	\N	\N
f372ed8c-fd5e-4121-a4b1-9cb5c930219b	IMD-CC-2026-000125	a5102b13-4107-4fe5-b7a0-064dd07042ee	0724a689-d500-4969-b7fb-72e37232b31f	5fae8216-c8f1-4569-9965-9ab4c96d3f7c	83.00	{"user": "a5102b13-4107-4fe5-b7a0-064dd07042ee", "score": 83, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	fc3e16209d8f96bcd5aaf1842eadf448a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-04-26 18:31:45.462661+00	\N	\N
24e25b14-cf72-47ef-a3a0-41198a2ff235	IMD-CC-2026-000126	a17abc66-209e-405f-bcd6-c39e54cbce66	0724a689-d500-4969-b7fb-72e37232b31f	10b0a44e-4d3f-448b-969c-6c7b522fcb2c	70.00	{"user": "a17abc66-209e-405f-bcd6-c39e54cbce66", "score": 70, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	d1d5296c1429dd29e97b28683b63f4c5a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-04-05 18:31:45.462661+00	\N	\N
542bd29e-995b-4fb9-b146-be5631e5af94	IMD-CC-2026-000127	1f511b5e-1292-4202-860e-b54f11eda21e	0724a689-d500-4969-b7fb-72e37232b31f	010b9981-b387-492e-b164-540e827f509b	82.00	{"user": "1f511b5e-1292-4202-860e-b54f11eda21e", "score": 82, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	af04c13d61783dd8dc874a190423e16ea57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-05-26 18:31:45.462661+00	\N	\N
402f56fe-a655-409d-95bf-e4ab284085df	IMD-CC-2026-000128	46e6d439-49ab-4001-b576-7df03d3babee	0724a689-d500-4969-b7fb-72e37232b31f	533a24fc-699f-485e-9410-e6b7ff30b9c2	100.00	{"user": "46e6d439-49ab-4001-b576-7df03d3babee", "score": 100, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	46007c0cf7cbb8a6fc253b75cfde9592a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-07-28 18:31:45.462661+00	\N	\N
6cedf4b0-a7c4-4a46-b7b7-af4375854d2b	IMD-CC-2026-000129	562af427-bd16-4c30-940b-5d6121d738c8	0724a689-d500-4969-b7fb-72e37232b31f	0e4aa15e-46b8-4b57-84be-f75aea92a7ed	79.00	{"user": "562af427-bd16-4c30-940b-5d6121d738c8", "score": 79, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	d755c1e5d47c071519c75b7b2ecfd1e8a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-06-25 18:31:45.462661+00	\N	\N
b20d5ee0-1758-4f20-8142-d310cd89f75d	IMD-CC-2026-000130	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	0724a689-d500-4969-b7fb-72e37232b31f	77ba9a84-2be3-4107-a27e-69e654086e9b	90.00	{"user": "89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f", "score": 90, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	d29e2019de29174dc14d180856684b5ca57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-07-24 18:31:45.462661+00	\N	\N
6485262d-6ea6-46de-baf6-b536d2906315	IMD-CC-2026-000131	caf34c22-6898-4c15-bde0-08f3d2634d41	0724a689-d500-4969-b7fb-72e37232b31f	170873cb-7302-4b5a-8236-b79ae9dccd76	84.00	{"user": "caf34c22-6898-4c15-bde0-08f3d2634d41", "score": 84, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	b8afe6146909dda0a755ea7dc2358c12a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-09-11 18:31:45.462661+00	\N	\N
d8dcf9dc-8d9f-4bd6-a60f-8de1a08792a5	IMD-CC-2026-000132	032c01d5-4b5e-44f6-821d-2ba4342c938f	0724a689-d500-4969-b7fb-72e37232b31f	b2ee9ee7-b11b-42a0-b38e-f8082fdbf5dd	91.00	{"user": "032c01d5-4b5e-44f6-821d-2ba4342c938f", "score": 91, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	15b1dae50b24aba40c46f07153b54946a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-08-04 18:31:45.462661+00	\N	\N
2b373ec1-221c-40b3-b059-8e7419838155	IMD-CC-2026-000133	3e1e22ae-3497-44dc-bb66-1a3c24a5af91	0724a689-d500-4969-b7fb-72e37232b31f	7c6c46cf-3d39-4ce8-953f-a5f8cf5d4252	88.00	{"user": "3e1e22ae-3497-44dc-bb66-1a3c24a5af91", "score": 88, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	f76bbaad55c93abca92d90a182801392a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-05-03 18:31:45.462661+00	\N	\N
ea24883e-b4c6-4e99-b902-9c5c54f2ec65	IMD-CC-2026-000134	1eb0cec9-a12f-4f42-9d77-bf6e343e9a75	0724a689-d500-4969-b7fb-72e37232b31f	36e4aeae-9cd0-4b50-a351-b4a37d3ed07b	82.00	{"user": "1eb0cec9-a12f-4f42-9d77-bf6e343e9a75", "score": 82, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	985f73157376ae4a9e202dafc894a559a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-07-15 18:31:45.462661+00	\N	\N
6b3f5817-146b-4cdd-8c0f-57ca055c6d05	IMD-CC-2026-000135	e6ef6d8e-87f0-4c3d-8ac9-dccb12f222f1	0724a689-d500-4969-b7fb-72e37232b31f	20c1a9b4-b1e7-40dc-a4ca-e0612e9168b1	100.00	{"user": "e6ef6d8e-87f0-4c3d-8ac9-dccb12f222f1", "score": 100, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	b54c5b9138f28bd19e27f1dd404a59c2a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-03-30 18:31:45.462661+00	\N	\N
73b84db0-3565-4557-99ac-08a2b86cdca7	IMD-CC-2026-000136	88b2de0e-fb93-4402-98ef-3c1bd149f61d	0724a689-d500-4969-b7fb-72e37232b31f	b70d150e-2d9d-475a-9970-3f5d47d38ec9	100.00	{"user": "88b2de0e-fb93-4402-98ef-3c1bd149f61d", "score": 100, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	c3880e840d2ee0c5cc3374ed9302d4bfa57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-09-16 18:31:45.462661+00	\N	\N
db54b2d2-4225-4df7-99f6-9b0e66deacfd	IMD-CC-2026-000137	c41e7852-875f-411b-93f1-7171f9871f9f	0724a689-d500-4969-b7fb-72e37232b31f	2bbe7a53-2aeb-4a7c-9f80-e9102cc54f34	90.00	{"user": "c41e7852-875f-411b-93f1-7171f9871f9f", "score": 90, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	a030995b4a69079b75067752e4920db6a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-08-18 18:31:45.462661+00	\N	\N
f8bfb8d4-4ebc-4c93-aee5-834d4c91f4c2	IMD-CC-2026-000138	c2900748-9036-4804-b4f0-feb22ac5b4fb	0724a689-d500-4969-b7fb-72e37232b31f	c065350d-3315-4839-9cac-7883e3b7c53d	94.00	{"user": "c2900748-9036-4804-b4f0-feb22ac5b4fb", "score": 94, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	d87a5f0b886fcb011ae25f91030711e7a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-04-03 18:31:45.462661+00	\N	\N
80740add-a03c-46f1-a3db-37f7a58728a4	IMD-CC-2026-000139	a8c5b60b-8763-4325-900d-07d7540e6015	0724a689-d500-4969-b7fb-72e37232b31f	dc06d5f4-0551-4232-b753-2b451cee9df2	92.00	{"user": "a8c5b60b-8763-4325-900d-07d7540e6015", "score": 92, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	8601d85b9011dfdb9fbe8121c7d7a974a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-07-23 18:31:45.462661+00	\N	\N
0ab0970b-7457-4679-9446-748bfb81f615	IMD-CC-2026-000140	8be014b0-ed46-43db-89e2-91a301c618db	0724a689-d500-4969-b7fb-72e37232b31f	1bcb8563-5e0d-4ed8-bed5-bcbd6baa1961	98.00	{"user": "8be014b0-ed46-43db-89e2-91a301c618db", "score": 98, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	4bd77becfe431c4e4483cae1c1f86d38a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-02-28 18:31:45.462661+00	\N	\N
c2563c99-79b0-4cd1-b412-cfab9a077848	IMD-CC-2026-000141	fed72080-2568-4892-8047-0b3c72ff7fad	0724a689-d500-4969-b7fb-72e37232b31f	17d187b4-a880-438f-95bc-898468b10055	87.00	{"user": "fed72080-2568-4892-8047-0b3c72ff7fad", "score": 87, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	37e18518e94df409646ae0be89aff065a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-03-13 18:31:45.462661+00	\N	\N
35e47ee4-ddcb-4228-a87b-3ff9eedcbcd5	IMD-CC-2026-000142	17231857-2d57-46f3-aecc-cb26a0865adb	0724a689-d500-4969-b7fb-72e37232b31f	3424efac-c10f-4142-a99d-b7f297670d04	83.00	{"user": "17231857-2d57-46f3-aecc-cb26a0865adb", "score": 83, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	ed540a11590cfd5f346bea26f5d74e99a57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-03-21 18:31:45.462661+00	\N	\N
2f4f84d5-30dd-4bed-8ec2-bbf727f0bb15	IMD-CC-2026-000143	d05292f5-3e9f-4e51-bb50-05a6534dc9b8	0724a689-d500-4969-b7fb-72e37232b31f	8fb8031e-e3ba-48c1-b314-50f7c12c55d2	85.00	{"user": "d05292f5-3e9f-4e51-bb50-05a6534dc9b8", "score": 85, "course": "0724a689-d500-4969-b7fb-72e37232b31f"}	6cf44668ee998b234e31791646407c6da57b9208a8ea7038c16d23413884eade	demo-signature	\N	2026-06-09 18:31:45.462661+00	\N	\N
3f99e59d-9cc3-4a22-becf-fc9375b63ddc	IMD-CC-2026-000144	4acb1924-e6ec-428c-8401-ac05f87e2bbf	ce43f7f3-92cb-4d62-b40a-149bdd13b745	a880ba6f-8e40-42dd-a94b-ac8088b2a0a2	80.00	{"user": "4acb1924-e6ec-428c-8401-ac05f87e2bbf", "score": 80, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	ac8bba00def628d866a80fdb821de91cff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-06-26 18:31:45.462661+00	\N	\N
5a7d8648-c7bb-4995-8d89-75e1b8565acb	IMD-CC-2026-000145	862f76a0-443e-4a80-8644-ef4922c5f38a	ce43f7f3-92cb-4d62-b40a-149bdd13b745	e0cc63d6-d2e0-42c7-8e08-8c7cf39dbcc0	63.00	{"user": "862f76a0-443e-4a80-8644-ef4922c5f38a", "score": 63, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	5201a582545776080804b57a790726b0ff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-03-02 18:31:45.462661+00	\N	\N
f1632c00-0f5c-4e8c-a857-6467e23d825a	IMD-CC-2026-000146	fed72080-2568-4892-8047-0b3c72ff7fad	ce43f7f3-92cb-4d62-b40a-149bdd13b745	89954676-7215-4ff1-ab01-ed364feb965c	85.00	{"user": "fed72080-2568-4892-8047-0b3c72ff7fad", "score": 85, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	8000e5f1310da28e7e4aa73640fde035ff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-06-21 18:31:45.462661+00	\N	\N
a3bf0ae7-4e8b-4cfb-8106-04457e20d308	IMD-CC-2026-000147	7acc259e-1231-481b-ab79-59821fd46534	ce43f7f3-92cb-4d62-b40a-149bdd13b745	832a8d87-671f-43fc-a3f9-536cb4394008	92.00	{"user": "7acc259e-1231-481b-ab79-59821fd46534", "score": 92, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	52256ad264025034acbf27a9caec8ca2ff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-07-01 18:31:45.462661+00	\N	\N
bee7599f-9727-447a-9ecb-7b09c7d791e0	IMD-CC-2026-000148	8be014b0-ed46-43db-89e2-91a301c618db	ce43f7f3-92cb-4d62-b40a-149bdd13b745	3b6b147f-91f3-421f-8c19-b166c92a6a32	92.00	{"user": "8be014b0-ed46-43db-89e2-91a301c618db", "score": 92, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	3cc816201d466ddd8f2fd18e7c133e05ff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-06-16 18:31:45.462661+00	\N	\N
3c10df6c-5cd2-418c-b8db-d3659c4fa978	IMD-CC-2026-000149	2e35b549-e1b5-4e61-a221-b0799208258c	ce43f7f3-92cb-4d62-b40a-149bdd13b745	ea6a55fe-1e2f-4289-9a0d-13437e5761b3	70.00	{"user": "2e35b549-e1b5-4e61-a221-b0799208258c", "score": 70, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	1bc28786a89892adb5e4d873d24dc8f1ff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-09-11 18:31:45.462661+00	\N	\N
b6639737-4e1b-43e1-accf-7f97c7bf338a	IMD-CC-2026-000150	28fe79f0-6207-4e0c-8bae-1eb02eed759b	ce43f7f3-92cb-4d62-b40a-149bdd13b745	b9f47667-72dc-474b-a440-e4f88ba13d22	82.00	{"user": "28fe79f0-6207-4e0c-8bae-1eb02eed759b", "score": 82, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	432402ca723e447f118b39a8003df493ff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-05-08 18:31:45.462661+00	\N	\N
f51f64de-3080-436d-98b2-00e881885049	IMD-CC-2026-000151	77c70aa0-ddd9-4445-be30-4817de1cbfd0	ce43f7f3-92cb-4d62-b40a-149bdd13b745	dfeb44a1-ae04-45e3-888f-5a715ca54dfc	88.00	{"user": "77c70aa0-ddd9-4445-be30-4817de1cbfd0", "score": 88, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	7ba03b88bc926ede6791d6dd166c176eff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-08-11 18:31:45.462661+00	\N	\N
6a7fbcf1-5c5c-46b7-807b-a8f8f58fcc65	IMD-CC-2026-000152	cf4749a6-6127-4d97-b2a0-17a11eabc216	ce43f7f3-92cb-4d62-b40a-149bdd13b745	9bb2037a-8b72-4cf5-b212-feb8677c50d4	69.00	{"user": "cf4749a6-6127-4d97-b2a0-17a11eabc216", "score": 69, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	3936ec76b6c4c3550b98319f4db9a2bbff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-05-03 18:31:45.462661+00	\N	\N
2b6491bc-2f7d-4010-8ac5-d55a35d6bc42	IMD-CC-2026-000153	65ef229b-117d-4946-b5bb-301e3f828fc2	ce43f7f3-92cb-4d62-b40a-149bdd13b745	44414842-ca38-4a94-bd2a-1a3446a734e8	100.00	{"user": "65ef229b-117d-4946-b5bb-301e3f828fc2", "score": 100, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	534bdc5e3ab30a300b2aae9771f247c3ff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-09-13 18:31:45.462661+00	\N	\N
ebcfe03b-c8fa-4a5e-b452-64dfd7ed3273	IMD-CC-2026-000154	7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	ce43f7f3-92cb-4d62-b40a-149bdd13b745	ad27237d-cfdf-462f-86bd-b07e783f89b2	100.00	{"user": "7d98c1dd-e2b5-4fb6-aa2a-68849c41f058", "score": 100, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	483569de012b845f6b4263cad763fb0fff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-03-06 18:31:45.462661+00	\N	\N
93652e30-06e5-4107-81da-ea87d2b01bb2	IMD-CC-2026-000155	152f1a01-df4b-4828-bf72-c1616f324c38	ce43f7f3-92cb-4d62-b40a-149bdd13b745	b9fa8b07-052a-416f-a2c5-095eba94f5dd	82.00	{"user": "152f1a01-df4b-4828-bf72-c1616f324c38", "score": 82, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	b28fc5a5024dd78da896b202fb21f309ff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-06-17 18:31:45.462661+00	\N	\N
6e84d1fd-1568-4fbb-948d-c00cbfb1f4f1	IMD-CC-2026-000156	293f638f-6b5e-4c5a-9282-533cc1c97688	ce43f7f3-92cb-4d62-b40a-149bdd13b745	0bdb6c59-f55d-4f3a-a61b-608a348e93d1	71.00	{"user": "293f638f-6b5e-4c5a-9282-533cc1c97688", "score": 71, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	652d04ba7e9e93fb1d80981a501906bfff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-09-03 18:31:45.462661+00	\N	\N
e195deb0-2856-4fa1-a17e-0fa5b8918dff	IMD-CC-2026-000157	a17abc66-209e-405f-bcd6-c39e54cbce66	ce43f7f3-92cb-4d62-b40a-149bdd13b745	a62cb793-dd3b-4d45-bc44-b1a6c4f75f14	66.00	{"user": "a17abc66-209e-405f-bcd6-c39e54cbce66", "score": 66, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	2278c00b89cfd3b7b821295050cfa59dff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-09-13 18:31:45.462661+00	\N	\N
bb8e5968-1ee3-4271-9f31-6106bb016763	IMD-CC-2026-000158	7e426fed-4c2e-46f4-866a-7b8aa048cf06	ce43f7f3-92cb-4d62-b40a-149bdd13b745	9e033cf7-3666-40b8-9c31-de362295e81e	79.00	{"user": "7e426fed-4c2e-46f4-866a-7b8aa048cf06", "score": 79, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	50084cf35e6e539cb611bb83f75ccf2fff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-04-03 18:31:45.462661+00	\N	\N
f47c5126-d938-46a6-8cd4-1c4dc60ee392	IMD-CC-2026-000159	625944b1-2b9b-433b-9af5-e72894aa7a58	ce43f7f3-92cb-4d62-b40a-149bdd13b745	457e7516-1b98-45d2-bbac-6077f8de91d8	70.00	{"user": "625944b1-2b9b-433b-9af5-e72894aa7a58", "score": 70, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	9fa1351d538bf38d8aceb33ba70b6c0aff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-09-01 18:31:45.462661+00	\N	\N
0b9e7754-caa1-4f05-8b21-b8acf715f465	IMD-CC-2026-000160	889560c5-9238-4463-82d8-b65d7fdba4bc	ce43f7f3-92cb-4d62-b40a-149bdd13b745	8fdd884d-17b6-4779-ab14-b7bae80751cb	76.00	{"user": "889560c5-9238-4463-82d8-b65d7fdba4bc", "score": 76, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	c50f7d5d4460937320869a39b2b89951ff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-08-25 18:31:45.462661+00	\N	\N
af8b7803-35a6-4a97-b63b-61aed39f7c19	IMD-CC-2026-000161	732e74cf-b9b7-4adc-a43a-794430d7fe49	ce43f7f3-92cb-4d62-b40a-149bdd13b745	d534428d-a93e-4024-873f-e6dda29d65eb	80.00	{"user": "732e74cf-b9b7-4adc-a43a-794430d7fe49", "score": 80, "course": "ce43f7f3-92cb-4d62-b40a-149bdd13b745"}	53c14fb5b5d3d8d481ee188b9e63b6f0ff360f03fdc1d23458e3b8ffc043d03c	demo-signature	\N	2026-07-16 18:31:45.462661+00	\N	\N
6501105a-a758-4777-a258-3c42efdc9140	IMD-CC-2026-000162	55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	97b1727b-e525-4ee5-b01f-28b15a8101b5	82634c44-2fad-43f1-a8f4-c0db0586a0fd	66.00	{"user": "55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f", "score": 66, "course": "97b1727b-e525-4ee5-b01f-28b15a8101b5"}	557ac31e0c77b449b6c9fe73d0166ebabe08cf79cf41750fbca80a92f572ee64	demo-signature	\N	2026-04-06 18:31:45.462661+00	\N	\N
6edb0c51-4c2e-4b62-8d01-a73023490542	IMD-CC-2026-000163	cf4749a6-6127-4d97-b2a0-17a11eabc216	97b1727b-e525-4ee5-b01f-28b15a8101b5	11fd7554-fc43-498f-861f-bed223d012f0	60.00	{"user": "cf4749a6-6127-4d97-b2a0-17a11eabc216", "score": 60, "course": "97b1727b-e525-4ee5-b01f-28b15a8101b5"}	1c8ad3942a450b12568c8bb031c795ddbe08cf79cf41750fbca80a92f572ee64	demo-signature	\N	2026-03-15 18:31:45.462661+00	\N	\N
37c000a7-fa13-4b91-a559-3e838d3a83f9	IMD-CC-2026-000164	350093ae-4f68-46a9-a0af-c33a9b87c340	97b1727b-e525-4ee5-b01f-28b15a8101b5	5dc79fd2-8a8d-4d3a-99f7-cf0f1d7c1b7b	74.00	{"user": "350093ae-4f68-46a9-a0af-c33a9b87c340", "score": 74, "course": "97b1727b-e525-4ee5-b01f-28b15a8101b5"}	54d76c0a9a1e6ccae8f0d4fb32aff329be08cf79cf41750fbca80a92f572ee64	demo-signature	\N	2026-03-23 18:31:45.462661+00	\N	\N
d154e422-9541-4561-b23b-e1e4263a5dcf	IMD-CC-2026-000165	d072273b-7a6f-4fa4-9195-1697050cfab1	97b1727b-e525-4ee5-b01f-28b15a8101b5	3e4a702d-12d9-410d-a828-ae74ec920f75	62.00	{"user": "d072273b-7a6f-4fa4-9195-1697050cfab1", "score": 62, "course": "97b1727b-e525-4ee5-b01f-28b15a8101b5"}	1916c953fa6d6a762655c81c15077df5be08cf79cf41750fbca80a92f572ee64	demo-signature	\N	2026-04-21 18:31:45.462661+00	\N	\N
0201ceb5-2471-4f2c-ab82-c78f8791150c	IMD-CC-2026-000166	2af59a77-c993-46c3-a686-b91217814d48	97b1727b-e525-4ee5-b01f-28b15a8101b5	1d909fca-6294-45c6-b84a-94b2f7294caa	72.00	{"user": "2af59a77-c993-46c3-a686-b91217814d48", "score": 72, "course": "97b1727b-e525-4ee5-b01f-28b15a8101b5"}	e5ddb861358c251ce53156d3442b992fbe08cf79cf41750fbca80a92f572ee64	demo-signature	\N	2026-05-08 18:31:45.462661+00	\N	\N
9bc50688-f279-46f8-9b52-ab31aa44448d	IMD-CC-2026-000167	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	97b1727b-e525-4ee5-b01f-28b15a8101b5	ec179c00-e2d8-453b-b768-c340f56ad93e	64.00	{"user": "0369edbf-d1ba-47c9-b17c-e67c29bf27fc", "score": 64, "course": "97b1727b-e525-4ee5-b01f-28b15a8101b5"}	df6a17756153f3df5e4c61204ee829efbe08cf79cf41750fbca80a92f572ee64	demo-signature	\N	2026-03-07 18:31:45.462661+00	\N	\N
9e1c0595-b8bd-4e18-a840-c14378ae2eb5	IMD-CC-2026-000168	f75210c9-faa1-45c8-9314-a65724983502	e930bc9e-26fc-4a34-89bc-012457df980e	3a2b00ed-f682-4d06-9d2d-b915228caf8b	100.00	{"user": "f75210c9-faa1-45c8-9314-a65724983502", "score": 100, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	f04c81be850c2f90b91c96fe7c18a3ba38dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-07-27 18:31:45.462661+00	\N	\N
996be058-c83b-4bd7-881d-697cad40b0f9	IMD-CC-2026-000169	889560c5-9238-4463-82d8-b65d7fdba4bc	e930bc9e-26fc-4a34-89bc-012457df980e	02566c67-52d0-4e8a-91e6-3c35a54d110f	98.00	{"user": "889560c5-9238-4463-82d8-b65d7fdba4bc", "score": 98, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	61ac211a91f36637f719ae0aacd9f81238dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-07-16 18:31:45.462661+00	\N	\N
ed7c56d3-d716-45bf-8b17-18ad6ef0410e	IMD-CC-2026-000170	fed72080-2568-4892-8047-0b3c72ff7fad	e930bc9e-26fc-4a34-89bc-012457df980e	77a722d0-4416-451d-b770-2f39c855d7a0	85.00	{"user": "fed72080-2568-4892-8047-0b3c72ff7fad", "score": 85, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	1b9c74743442ced18950a52354f5540538dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-02-26 18:31:45.462661+00	\N	\N
b34607b1-4abb-47e5-ab6e-5b783c1bccd8	IMD-CC-2026-000171	48f33e15-f87f-4629-ab82-4123ada4bdc4	e930bc9e-26fc-4a34-89bc-012457df980e	2e759107-b839-40a7-b18d-ac13b02fca89	78.00	{"user": "48f33e15-f87f-4629-ab82-4123ada4bdc4", "score": 78, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	4ff6f0494bf21f85b14d66b7ca3a5db338dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-07-12 18:31:45.462661+00	\N	\N
e89cdca2-05b6-4de4-a9a0-826c6874bd82	IMD-CC-2026-000172	18c4a035-c0ad-48f3-8628-30fee5e16970	e930bc9e-26fc-4a34-89bc-012457df980e	2f7e47c6-2fea-48bb-971b-77bd93d7d7a3	100.00	{"user": "18c4a035-c0ad-48f3-8628-30fee5e16970", "score": 100, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	936782d71739a7bb093e81ad047f5fbd38dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-02-16 18:31:45.462661+00	\N	\N
6cdf9063-817f-476a-a5e5-bf34fb7c3dab	IMD-CC-2026-000173	0f80298a-f569-4c55-88aa-a57625e20751	e930bc9e-26fc-4a34-89bc-012457df980e	4bf76d3a-ca6a-4087-84a0-c9ee6ed49183	85.00	{"user": "0f80298a-f569-4c55-88aa-a57625e20751", "score": 85, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	efdb039f6812ff7f93a21a6dce263f3c38dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-06-21 18:31:45.462661+00	\N	\N
ed8db023-45e3-4213-bbf2-bc346992d3a5	IMD-CC-2026-000174	625944b1-2b9b-433b-9af5-e72894aa7a58	e930bc9e-26fc-4a34-89bc-012457df980e	47678f23-a49e-43fc-a818-c1b9676039d9	100.00	{"user": "625944b1-2b9b-433b-9af5-e72894aa7a58", "score": 100, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	dad8e2f8c54352353f2e0babbfbaf78f38dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-06-16 18:31:45.462661+00	\N	\N
ca3c8efa-f9a3-4f83-a2b1-c9cf6dc4bfbf	IMD-CC-2026-000175	dbccc807-eaba-41f6-aabc-14c515010185	e930bc9e-26fc-4a34-89bc-012457df980e	7fd18145-0be5-465c-ad46-3d4a1be35139	83.00	{"user": "dbccc807-eaba-41f6-aabc-14c515010185", "score": 83, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	3f9dad4c455f5bb0b661b272ae50f59938dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-09-10 18:31:45.462661+00	\N	\N
a88e7aa8-0eab-4a5b-a16d-1f9abaf67967	IMD-CC-2026-000176	24cbfa5b-7114-43b8-957c-fe0efa420c25	e930bc9e-26fc-4a34-89bc-012457df980e	39290458-17a9-44e7-87cd-7a2cacb1c1ef	91.00	{"user": "24cbfa5b-7114-43b8-957c-fe0efa420c25", "score": 91, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	8efe12895384a57833f46aa785146c7438dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-04-23 18:31:45.462661+00	\N	\N
b2a6f6d5-08e7-4be0-bdc0-a45471305ffb	IMD-CC-2026-000177	3af00a36-1f7b-4846-a52a-b1871416c5b1	e930bc9e-26fc-4a34-89bc-012457df980e	8471d443-2dea-4d0e-b4e1-a2bd351a63a0	86.00	{"user": "3af00a36-1f7b-4846-a52a-b1871416c5b1", "score": 86, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	30a9ac626c0c29477256cb579761690e38dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-09-05 18:31:45.462661+00	\N	\N
0a75c564-6f9d-482c-84ba-9251c9c3af34	IMD-CC-2026-000178	d2298ed0-2515-4232-b70f-845a98dac595	e930bc9e-26fc-4a34-89bc-012457df980e	bcf19465-063c-40e8-9181-e98a294a9093	91.00	{"user": "d2298ed0-2515-4232-b70f-845a98dac595", "score": 91, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	4b13b9454d762fbbf3a7b5a3bcd78e4338dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-07-17 18:31:45.462661+00	\N	\N
5e3e2181-b628-4d47-8cdd-5d775168e8ca	IMD-CC-2026-000179	d072273b-7a6f-4fa4-9195-1697050cfab1	e930bc9e-26fc-4a34-89bc-012457df980e	8e2b7569-7753-4af7-972d-76aa6d3d3e24	90.00	{"user": "d072273b-7a6f-4fa4-9195-1697050cfab1", "score": 90, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	7b5b04e48de54e0f20554539b887adf838dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-08-27 18:31:45.462661+00	\N	\N
b512b682-db2a-416c-89f7-fc932284b98c	IMD-CC-2026-000180	b8541832-74c6-404f-90d0-5fb6d3df7663	e930bc9e-26fc-4a34-89bc-012457df980e	1746c31c-a492-4637-8bd4-57001b93853a	100.00	{"user": "b8541832-74c6-404f-90d0-5fb6d3df7663", "score": 100, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	e5dd3020abbbf6aab71bd576f23de80338dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-05-09 18:31:45.462661+00	\N	\N
d5c13b6d-9aa2-4d42-92e0-48308872212d	IMD-CC-2026-000181	1e9340db-2cfd-419f-8894-9448da0bbc19	e930bc9e-26fc-4a34-89bc-012457df980e	dff36d30-69ef-4c93-9ba4-ef406c690bea	84.00	{"user": "1e9340db-2cfd-419f-8894-9448da0bbc19", "score": 84, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	acb054586f484a4d782e5485d2bc9eff38dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-07-25 18:31:45.462661+00	\N	\N
ff19c341-d4ce-47bf-93b5-f0518e68d691	IMD-CC-2026-000182	fda17094-1c9f-45de-a42c-aa815d09bc2a	e930bc9e-26fc-4a34-89bc-012457df980e	9e7774fe-852b-4e3b-945b-25064ddcea21	88.00	{"user": "fda17094-1c9f-45de-a42c-aa815d09bc2a", "score": 88, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	3bdcdc123a541823f9858899c83dca8d38dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-02-27 18:31:45.462661+00	\N	\N
9d9b78f5-a27b-4dbd-b411-514cc97e92f6	IMD-CC-2026-000183	eee6bbaa-75eb-44f4-9892-d46194b720a9	e930bc9e-26fc-4a34-89bc-012457df980e	3576b4be-3ad8-4896-81e5-387890c96dc5	100.00	{"user": "eee6bbaa-75eb-44f4-9892-d46194b720a9", "score": 100, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	8cf177562fc7110fcf66ac05e6a3f5e738dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-08-28 18:31:45.462661+00	\N	\N
63108d2c-e933-45da-b1ca-8bd036727030	IMD-CC-2026-000184	2e35b549-e1b5-4e61-a221-b0799208258c	e930bc9e-26fc-4a34-89bc-012457df980e	b786b49c-e472-4169-8f8b-7d49f3c1cea4	98.00	{"user": "2e35b549-e1b5-4e61-a221-b0799208258c", "score": 98, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	22888ddd198753ea091b603e7ca4f38a38dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-04-05 18:31:45.462661+00	\N	\N
defc77d5-01de-490e-bf1d-f49620475d59	IMD-CC-2026-000185	b0ba69f7-69ce-411c-a22d-c449785d11e9	e930bc9e-26fc-4a34-89bc-012457df980e	b190b89e-65a0-4fb6-b74a-09b739df952a	83.00	{"user": "b0ba69f7-69ce-411c-a22d-c449785d11e9", "score": 83, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	52281f376cca39f8750b47d3b7b83b2438dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-04-07 18:31:45.462661+00	\N	\N
70cce7de-4f2e-4452-85a8-d218134be950	IMD-CC-2026-000186	33f73596-75e6-435e-94f5-d5b111a6aaf5	e930bc9e-26fc-4a34-89bc-012457df980e	a51c2e0c-a48c-412b-a78e-8f5dd3fd2d9f	89.00	{"user": "33f73596-75e6-435e-94f5-d5b111a6aaf5", "score": 89, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	327d07064e527e424981d465c4a5534f38dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-02-23 18:31:45.462661+00	\N	\N
6361aef9-a554-43be-a295-f69cd0731c75	IMD-CC-2026-000187	4ace2ecd-317e-494c-ad50-71e2794fb907	e930bc9e-26fc-4a34-89bc-012457df980e	38020fe8-50d6-40cd-8e2b-29845acc54d7	85.00	{"user": "4ace2ecd-317e-494c-ad50-71e2794fb907", "score": 85, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	b21af04f71d8a0c7f1b3274d51fde42b38dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-07-16 18:31:45.462661+00	\N	\N
bdc8a429-8f01-44a8-85c6-aa5418207b03	IMD-CC-2026-000188	696886f6-a4bf-44a6-9ba9-c939abb52137	e930bc9e-26fc-4a34-89bc-012457df980e	8348d5c7-7f77-4333-8280-e6252df4318b	84.00	{"user": "696886f6-a4bf-44a6-9ba9-c939abb52137", "score": 84, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	9680417d101ec934f0a25551c6f82c8538dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-06-03 18:31:45.462661+00	\N	\N
9be7a41e-3286-485f-aef1-a3f91d28752a	IMD-CC-2026-000189	f74aaa72-56ba-476d-9aed-ffbe2e41dd50	e930bc9e-26fc-4a34-89bc-012457df980e	2f055eaf-74d8-44f3-9ddb-3855135ce012	88.00	{"user": "f74aaa72-56ba-476d-9aed-ffbe2e41dd50", "score": 88, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	77aa7134779502f68bf96a2876c14f8b38dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-04-14 18:31:45.462661+00	\N	\N
248b5a13-5eed-44c2-8971-bb4d5035e236	IMD-CC-2026-000190	60e67627-9116-4358-a94b-89c0416805f0	e930bc9e-26fc-4a34-89bc-012457df980e	d6ecf552-7c95-4ae8-a6ff-62aa6d00a435	100.00	{"user": "60e67627-9116-4358-a94b-89c0416805f0", "score": 100, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	02733ee064ac44dd6f19f884d04f001238dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-09-09 18:31:45.462661+00	\N	\N
85339c92-602d-4377-9a44-fb36000c4f85	IMD-CC-2026-000191	9e08ecc2-e291-4516-bae3-07b43abc2620	e930bc9e-26fc-4a34-89bc-012457df980e	c3148a82-947c-4dae-a13c-e922a92a4fd5	100.00	{"user": "9e08ecc2-e291-4516-bae3-07b43abc2620", "score": 100, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	0efa00dc31fcfaa8de399659f8388a0938dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-03-22 18:31:45.462661+00	\N	\N
5a9ffa10-765f-448e-9111-c2c08cc02c37	IMD-CC-2026-000192	08758984-558b-4323-bc35-2a202203d87b	e930bc9e-26fc-4a34-89bc-012457df980e	80dec3c5-aec0-4291-9062-38d9e5afedec	80.00	{"user": "08758984-558b-4323-bc35-2a202203d87b", "score": 80, "course": "e930bc9e-26fc-4a34-89bc-012457df980e"}	f7f9156d5acbea88eb722b8530a95b6038dffa6c553b0064953e84eb50fe7abd	demo-signature	\N	2026-05-06 18:31:45.462661+00	\N	\N
a8fc01f2-0bba-456f-8a6c-ec679fcb929a	IMD-CC-2026-000193	5abfd2bf-a622-4ac2-8867-2be6525ec0e8	290cedcf-37a4-4271-ae6c-2172115f0acb	4dec8997-72dc-4511-994b-2e7dcd8e6da2	63.00	{"user": "5abfd2bf-a622-4ac2-8867-2be6525ec0e8", "score": 63, "course": "290cedcf-37a4-4271-ae6c-2172115f0acb"}	f69616f34def5445de178b9f48c348630c873af8d658ae41a3435a0add84232a	demo-signature	\N	2026-03-11 18:31:45.462661+00	\N	\N
87e225b5-2adc-42ab-973c-1ca63dea4f8a	IMD-CC-2026-000194	88b2de0e-fb93-4402-98ef-3c1bd149f61d	290cedcf-37a4-4271-ae6c-2172115f0acb	9f3bada1-6365-4ccd-a940-f36fc5f1c35a	68.00	{"user": "88b2de0e-fb93-4402-98ef-3c1bd149f61d", "score": 68, "course": "290cedcf-37a4-4271-ae6c-2172115f0acb"}	ced7550ecafcac6e0af7df54ef7b403a0c873af8d658ae41a3435a0add84232a	demo-signature	\N	2026-03-21 18:31:45.462661+00	\N	\N
d87bf726-2f2f-4025-9065-113740cab950	IMD-CC-2026-000195	e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	290cedcf-37a4-4271-ae6c-2172115f0acb	273adfa2-ff18-480f-aa70-3dbdbb958e29	71.00	{"user": "e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a", "score": 71, "course": "290cedcf-37a4-4271-ae6c-2172115f0acb"}	496a08ca2480902df4d3384c5deb54130c873af8d658ae41a3435a0add84232a	demo-signature	\N	2026-08-09 18:31:45.462661+00	\N	\N
19420413-6cc7-416d-95b3-ae5e2a536644	IMD-CC-2026-000196	0d37acee-70ea-4604-8bd7-c995941443fd	290cedcf-37a4-4271-ae6c-2172115f0acb	163e7f3c-9de8-41bd-8469-6726656427c9	66.00	{"user": "0d37acee-70ea-4604-8bd7-c995941443fd", "score": 66, "course": "290cedcf-37a4-4271-ae6c-2172115f0acb"}	65035e0cf9bfdf14df701f10a1ab72ef0c873af8d658ae41a3435a0add84232a	demo-signature	\N	2026-05-08 18:31:45.462661+00	\N	\N
5dd2923f-8a98-4cbb-8603-4107b6f577e3	IMD-CC-2026-000197	9e08ecc2-e291-4516-bae3-07b43abc2620	290cedcf-37a4-4271-ae6c-2172115f0acb	85143ba8-9f2d-4ca0-b728-6bf23aa61a4d	69.00	{"user": "9e08ecc2-e291-4516-bae3-07b43abc2620", "score": 69, "course": "290cedcf-37a4-4271-ae6c-2172115f0acb"}	cebcaa6e1edd5d633f85c9fbd745af030c873af8d658ae41a3435a0add84232a	demo-signature	\N	2026-06-30 18:31:45.462661+00	\N	\N
80afe25b-fa8f-4389-bcc8-6aa1375155cc	IMD-CC-2026-000198	ab903484-298e-4415-93b0-8f5ea844bf31	290cedcf-37a4-4271-ae6c-2172115f0acb	c084b48f-f085-4a43-9b8c-260c5100807e	64.00	{"user": "ab903484-298e-4415-93b0-8f5ea844bf31", "score": 64, "course": "290cedcf-37a4-4271-ae6c-2172115f0acb"}	6ca0f86b7207e8fee034c2ff701ce1700c873af8d658ae41a3435a0add84232a	demo-signature	\N	2026-02-22 18:31:45.462661+00	\N	\N
881dbb07-742c-45e5-ad5a-d912fc247b7a	IMD-CC-2026-000199	17231857-2d57-46f3-aecc-cb26a0865adb	290cedcf-37a4-4271-ae6c-2172115f0acb	de927c52-9c55-45a7-8d47-e3a554d5ac7b	62.00	{"user": "17231857-2d57-46f3-aecc-cb26a0865adb", "score": 62, "course": "290cedcf-37a4-4271-ae6c-2172115f0acb"}	4c66e40a46ffc91fa537b745a7e4604f0c873af8d658ae41a3435a0add84232a	demo-signature	\N	2026-09-05 18:31:45.462661+00	\N	\N
bfd111b2-92f1-44bf-b462-b3b0a8e069f2	IMD-CC-2026-000200	fc08ec35-be50-46ec-8acb-0ddb68b16b22	290cedcf-37a4-4271-ae6c-2172115f0acb	142179ce-c12f-4ebc-bcc2-1953ee8bd118	69.00	{"user": "fc08ec35-be50-46ec-8acb-0ddb68b16b22", "score": 69, "course": "290cedcf-37a4-4271-ae6c-2172115f0acb"}	f29eba8c78d27605322cbf86b39fa7e30c873af8d658ae41a3435a0add84232a	demo-signature	\N	2026-08-13 18:31:45.462661+00	\N	\N
23b7b06b-87b1-4fb0-9ce1-b24a97b9825c	IMD-CC-2026-000201	ea8fa5c6-6833-4701-9073-dd4ff3f78cb8	57e0bcdd-75f2-4ba6-b987-befe07d147c8	4fe08c9b-c7e8-4607-b33a-fac638464aa0	65.00	{"user": "ea8fa5c6-6833-4701-9073-dd4ff3f78cb8", "score": 65, "course": "57e0bcdd-75f2-4ba6-b987-befe07d147c8"}	6647ac4d689552da36d6ee729a8f2ee855db976398548b55f147863e241eb1cb	demo-signature	\N	2026-04-14 18:31:45.462661+00	\N	\N
66a4594b-368a-4eb4-8072-dbc56423acc3	IMD-CC-2026-000202	1f511b5e-1292-4202-860e-b54f11eda21e	57e0bcdd-75f2-4ba6-b987-befe07d147c8	ccc5bc51-fbb5-478a-b945-05abd3426806	61.00	{"user": "1f511b5e-1292-4202-860e-b54f11eda21e", "score": 61, "course": "57e0bcdd-75f2-4ba6-b987-befe07d147c8"}	28cdc1b909ecab20a5e2c18a0434db4155db976398548b55f147863e241eb1cb	demo-signature	\N	2026-05-24 18:31:45.462661+00	\N	\N
6a1ea103-d9ce-4732-8a04-54a4262893d7	IMD-CC-2026-000203	cc9e83f0-d177-4454-8ba5-f7581c6da639	57e0bcdd-75f2-4ba6-b987-befe07d147c8	abec2e97-23d7-4b37-8f82-b12fa3231095	66.00	{"user": "cc9e83f0-d177-4454-8ba5-f7581c6da639", "score": 66, "course": "57e0bcdd-75f2-4ba6-b987-befe07d147c8"}	2a679d84d7d2bf8c16f997a7bbb120f655db976398548b55f147863e241eb1cb	demo-signature	\N	2026-07-09 18:31:45.462661+00	\N	\N
7699555c-c119-4039-8c38-b81c6de7c24b	IMD-CC-2026-000204	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	57e0bcdd-75f2-4ba6-b987-befe07d147c8	560d97be-028b-46e7-91d7-277773529ac0	65.00	{"user": "f32344cc-9180-4953-b2cd-ba0f4bdb2eea", "score": 65, "course": "57e0bcdd-75f2-4ba6-b987-befe07d147c8"}	9b9ce19a6567b09e1f61e4afab03ab4955db976398548b55f147863e241eb1cb	demo-signature	\N	2026-04-22 18:31:45.462661+00	\N	\N
ff15cd97-252a-4a07-b65a-52682a532859	IMD-CC-2026-000205	cf4749a6-6127-4d97-b2a0-17a11eabc216	42f00c79-df57-400e-a313-a585d6a36404	899ab84a-c761-431b-b115-77abb0c25262	74.00	{"user": "cf4749a6-6127-4d97-b2a0-17a11eabc216", "score": 74, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	4a8fd8e01f0060bc8c52511436378f0b06ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-05-06 18:31:45.462661+00	\N	\N
25e77a5b-7ad2-4004-ae5e-e063ee651d5f	IMD-CC-2026-000206	357f9f29-063f-4ff8-bdc9-6df1d8cb15b4	42f00c79-df57-400e-a313-a585d6a36404	67678c27-9445-4b91-a74f-e87427044723	70.00	{"user": "357f9f29-063f-4ff8-bdc9-6df1d8cb15b4", "score": 70, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	b23b7dd649fcd9865bf7eba07655a48a06ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-09-05 18:31:45.462661+00	\N	\N
f7746d98-1a46-4f37-a21c-d8e880400a70	IMD-CC-2026-000207	2af59a77-c993-46c3-a686-b91217814d48	42f00c79-df57-400e-a313-a585d6a36404	56dd7b52-7fb2-49c9-8c7c-6f5d4ef7a97d	90.00	{"user": "2af59a77-c993-46c3-a686-b91217814d48", "score": 90, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	99fce71ffb42e6bb22a42f9305aa0ce906ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-04-28 18:31:45.462661+00	\N	\N
e44a831a-29d7-4710-bc23-c19f9a5ad544	IMD-CC-2026-000208	90a570b4-9441-4d8b-981d-a7fa379054d3	42f00c79-df57-400e-a313-a585d6a36404	adfd0914-a263-4de4-b0d6-e4d310150816	69.00	{"user": "90a570b4-9441-4d8b-981d-a7fa379054d3", "score": 69, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	bd586c172c9499022ebcedf3a90d171406ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-09-03 18:31:45.462661+00	\N	\N
b54b321f-8b66-460d-b49e-f84bfdb2b9d0	IMD-CC-2026-000209	b28e0245-9390-4127-ad3f-80ace4775f43	42f00c79-df57-400e-a313-a585d6a36404	365c0df9-208d-4ca7-b19f-f4594472a80e	66.00	{"user": "b28e0245-9390-4127-ad3f-80ace4775f43", "score": 66, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	1e3ea5666a4dbe3a538087a563fdf51206ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-06-11 18:31:45.462661+00	\N	\N
9d45ca07-bf5a-48dc-85c6-e4048e1045ab	IMD-CC-2026-000210	4c6d827e-f3db-47d8-be22-4dc4a611c63f	42f00c79-df57-400e-a313-a585d6a36404	f34f2734-12cd-4278-9a05-02a5fa197ce4	61.00	{"user": "4c6d827e-f3db-47d8-be22-4dc4a611c63f", "score": 61, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	441e4e647c77ae9120b7c1c2f90c3e2206ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-03-26 18:31:45.462661+00	\N	\N
f6c114a4-e460-4b76-882b-e1988ca388f9	IMD-CC-2026-000211	2731bad6-8e73-4106-8def-3df5df76b6ea	42f00c79-df57-400e-a313-a585d6a36404	e6dc5762-57b2-4317-9da1-a7319ec0e3ef	64.00	{"user": "2731bad6-8e73-4106-8def-3df5df76b6ea", "score": 64, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	9f21961fc6beaf00999a50c580d4250706ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-02-20 18:31:45.462661+00	\N	\N
fa4e3465-7d77-4467-a051-3f5395e8a9da	IMD-CC-2026-000212	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	42f00c79-df57-400e-a313-a585d6a36404	8b311ed4-207f-44fa-a0f1-84e818cc73fb	89.00	{"user": "f32344cc-9180-4953-b2cd-ba0f4bdb2eea", "score": 89, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	004e9c6c0bc62829d6dfd2a104f2aafe06ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-06-01 18:31:45.462661+00	\N	\N
7d2c5827-8348-4e58-ada5-83f23a5c73ca	IMD-CC-2026-000213	4d5fd264-452f-4436-8eca-5c6c62afb143	42f00c79-df57-400e-a313-a585d6a36404	ba597be6-6542-4a9c-9db5-0926806d7902	69.00	{"user": "4d5fd264-452f-4436-8eca-5c6c62afb143", "score": 69, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	d81f4d1cf711a32170d0ddc1f62f1a1606ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-09-16 18:31:45.462661+00	\N	\N
cee4369d-957c-4619-a7e2-2a066a7c82c9	IMD-CC-2026-000214	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	42f00c79-df57-400e-a313-a585d6a36404	ff2864db-8927-44e0-aed8-cdec31f4d3c3	79.00	{"user": "fc6668ea-582e-4fa2-a17f-eb264a39e1a2", "score": 79, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	1e643fc693c7d93cae5cf235cc9b6e0a06ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-06-27 18:31:45.462661+00	\N	\N
3099bb02-648f-4742-90fc-1c1547384f14	IMD-CC-2026-000215	350093ae-4f68-46a9-a0af-c33a9b87c340	42f00c79-df57-400e-a313-a585d6a36404	7d03da8d-a2ea-4f83-aac9-5224d3cfa493	76.00	{"user": "350093ae-4f68-46a9-a0af-c33a9b87c340", "score": 76, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	7f78dd18b3854bab5484734f81d1860806ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-09-16 18:31:45.462661+00	\N	\N
22cf1120-bde4-4cd9-ae84-391d85f77ab9	IMD-CC-2026-000216	7f53c53d-3323-4146-8cea-01d6c38b4f77	42f00c79-df57-400e-a313-a585d6a36404	a20af338-2eb2-4e6d-87d7-347e6019fff2	86.00	{"user": "7f53c53d-3323-4146-8cea-01d6c38b4f77", "score": 86, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	f0ef05fbe5d6ead10279b71a5ee853d306ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-06-15 18:31:45.462661+00	\N	\N
1ff3161a-3865-44b4-b511-15fd112a81bb	IMD-CC-2026-000217	69f12a27-893c-4791-987c-14fb10cbede4	42f00c79-df57-400e-a313-a585d6a36404	e24ac918-bbea-4f6a-8c5b-4f5f7fab1a7e	82.00	{"user": "69f12a27-893c-4791-987c-14fb10cbede4", "score": 82, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	016d5648f9edec79808a93bff6fb318006ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-08-19 18:31:45.462661+00	\N	\N
3e7ab9f2-d17f-4a71-b942-566301f7213a	IMD-CC-2026-000218	46e6d439-49ab-4001-b576-7df03d3babee	42f00c79-df57-400e-a313-a585d6a36404	c375fa54-70b3-45ce-9709-3eb8a1f46010	61.00	{"user": "46e6d439-49ab-4001-b576-7df03d3babee", "score": 61, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	44ec051a7f2418b11fda72b6646ff13d06ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-09-07 18:31:45.462661+00	\N	\N
ac8f97a3-6819-4fb5-923f-fb6e99fdde2d	IMD-CC-2026-000219	7e426fed-4c2e-46f4-866a-7b8aa048cf06	42f00c79-df57-400e-a313-a585d6a36404	455148b2-21db-4a0b-939a-65badec90f9a	67.00	{"user": "7e426fed-4c2e-46f4-866a-7b8aa048cf06", "score": 67, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	d8e2312aa7fc7ce97feb6b97d508907d06ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-06-25 18:31:45.462661+00	\N	\N
ea9b4ce7-2b0a-4d67-9be5-69af99f2733f	IMD-CC-2026-000220	9e08ecc2-e291-4516-bae3-07b43abc2620	42f00c79-df57-400e-a313-a585d6a36404	8114c672-f7c7-4fb8-808f-fa150c828529	96.00	{"user": "9e08ecc2-e291-4516-bae3-07b43abc2620", "score": 96, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	233f64ff595bd870c1b24c53aa1e527b06ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-02-14 18:31:45.462661+00	\N	\N
f1a8a6be-dd4a-46a6-a5d1-a7c0f9c7a6eb	IMD-CC-2026-000221	3a7984bc-e386-48e4-b988-7d8e086b5317	42f00c79-df57-400e-a313-a585d6a36404	daecdb53-d3d2-46ce-952f-126960283697	87.00	{"user": "3a7984bc-e386-48e4-b988-7d8e086b5317", "score": 87, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	e24465e1e0cca1ecd4660fc84f7a107a06ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-07-27 18:31:45.462661+00	\N	\N
10431347-505d-447a-a8e5-2967d07c76b8	IMD-CC-2026-000222	05a922f4-7a9b-427c-bd4f-34ee3bdcfcf6	42f00c79-df57-400e-a313-a585d6a36404	642acfd3-a594-41da-b156-e0b93bc647a8	94.00	{"user": "05a922f4-7a9b-427c-bd4f-34ee3bdcfcf6", "score": 94, "course": "42f00c79-df57-400e-a313-a585d6a36404"}	aa7efb0e95633956379a4f68120fe66006ae9853f44d5e3cdc7b4a62435013b0	demo-signature	\N	2026-05-05 18:31:45.462661+00	\N	\N
9118292c-4540-4a47-bac1-61a4e594471b	IMD-CC-2026-000223	729fd30e-9cfb-4751-bbdb-935fbbb7f994	486ae347-6271-439f-9865-ebaf1e4d93cd	7b6ea5a8-b096-414d-ad0c-79591b1c39e5	81.00	{"user": "729fd30e-9cfb-4751-bbdb-935fbbb7f994", "score": 81, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	172e682576f59da62b6662e6650664477daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-07-29 18:31:45.462661+00	\N	\N
1e1f10d0-89a9-4304-b859-69e02b7928d6	IMD-CC-2026-000224	c41e7852-875f-411b-93f1-7171f9871f9f	486ae347-6271-439f-9865-ebaf1e4d93cd	7b71ffc7-5d67-4320-ab66-9267cc5be524	79.00	{"user": "c41e7852-875f-411b-93f1-7171f9871f9f", "score": 79, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	a67a6021fab92526b8e2f2bd486034f37daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-08-19 18:31:45.462661+00	\N	\N
928a2169-967e-4028-a60d-bff822fb3b02	IMD-CC-2026-000225	d072273b-7a6f-4fa4-9195-1697050cfab1	486ae347-6271-439f-9865-ebaf1e4d93cd	e0a39788-b9b5-4c73-aaa6-d5110ae54ed8	95.00	{"user": "d072273b-7a6f-4fa4-9195-1697050cfab1", "score": 95, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	4e06c5351bb3a2b7229eb483bc8d2b757daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-02-17 18:31:45.462661+00	\N	\N
70a535a7-5539-4172-8ee3-934f0c129600	IMD-CC-2026-000226	77c70aa0-ddd9-4445-be30-4817de1cbfd0	486ae347-6271-439f-9865-ebaf1e4d93cd	0af00eef-e3af-4141-bd75-3987b986cbd0	73.00	{"user": "77c70aa0-ddd9-4445-be30-4817de1cbfd0", "score": 73, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	c2a01d289a4240ff47386a8fb06c90437daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-05-29 18:31:45.462661+00	\N	\N
5e41d409-51ec-44d4-a191-5bb41565afae	IMD-CC-2026-000227	ec4cdace-5f9a-4198-9518-7c59753a1127	486ae347-6271-439f-9865-ebaf1e4d93cd	2f1f20a7-d1da-4fe8-a27c-e0a04b6a523a	100.00	{"user": "ec4cdace-5f9a-4198-9518-7c59753a1127", "score": 100, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	8e61ae6a1b45e5226f54cf774154f9107daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-02-22 18:31:45.462661+00	\N	\N
915d05e5-d326-4809-ada5-9c5f8cb50a67	IMD-CC-2026-000228	8a0a7128-e6e6-4b49-8395-52723dda0b7c	486ae347-6271-439f-9865-ebaf1e4d93cd	073d703f-4350-4bd7-8bda-8cfcd7ec8332	87.00	{"user": "8a0a7128-e6e6-4b49-8395-52723dda0b7c", "score": 87, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	29a8e13bdb25b8af2e212c027b8a56aa7daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-05-23 18:31:45.462661+00	\N	\N
9b6ab2b9-8f3e-413a-b175-585f1c53fb25	IMD-CC-2026-000229	216136af-8b6b-44ae-a787-59506613a618	486ae347-6271-439f-9865-ebaf1e4d93cd	7eec12b9-51c2-4523-b812-0f2ae475a5d8	80.00	{"user": "216136af-8b6b-44ae-a787-59506613a618", "score": 80, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	b5fa6935c808e29c009eeb4291bc59f47daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-03-29 18:31:45.462661+00	\N	\N
e9735908-9e9f-404a-b17a-de8cab6d252e	IMD-CC-2026-000230	7f53c53d-3323-4146-8cea-01d6c38b4f77	486ae347-6271-439f-9865-ebaf1e4d93cd	4a5a338b-dc27-445d-8f15-f8465c364e48	100.00	{"user": "7f53c53d-3323-4146-8cea-01d6c38b4f77", "score": 100, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	04ca7ddc3cb2dca4421a79c17b8c17a77daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-03-24 18:31:45.462661+00	\N	\N
cba60398-27b2-429a-957a-78511d46b1f3	IMD-CC-2026-000231	8a1eab45-738c-41b6-b35d-7737f5e2f64e	486ae347-6271-439f-9865-ebaf1e4d93cd	b00a152a-991e-4643-ac1c-e738ae3d3d73	100.00	{"user": "8a1eab45-738c-41b6-b35d-7737f5e2f64e", "score": 100, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	5c46059d6639207dcc63fdb7b944f3ef7daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-06-22 18:31:45.462661+00	\N	\N
6719ec00-226f-494b-8f35-248a9fbc57a7	IMD-CC-2026-000232	28fe79f0-6207-4e0c-8bae-1eb02eed759b	486ae347-6271-439f-9865-ebaf1e4d93cd	fda410a1-9e83-4c20-9b03-d1acc1730636	86.00	{"user": "28fe79f0-6207-4e0c-8bae-1eb02eed759b", "score": 86, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	1aec3a566f2ff11191a047d7950b32947daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-07-28 18:31:45.462661+00	\N	\N
d50be106-99ad-4ef9-bd1f-0056e4677a68	IMD-CC-2026-000233	3d87692f-06c1-4403-95ff-c70d1598700a	486ae347-6271-439f-9865-ebaf1e4d93cd	e064db09-b4af-4ab0-b92c-b948cc2082d1	81.00	{"user": "3d87692f-06c1-4403-95ff-c70d1598700a", "score": 81, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	c7c1e0e55f16425671cef5f071c4a14a7daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-04-15 18:31:45.462661+00	\N	\N
4b02b95f-57a7-4592-a76c-01de6de0e36a	IMD-CC-2026-000234	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	486ae347-6271-439f-9865-ebaf1e4d93cd	799a6e30-13c3-49d7-b9cb-e17c1e50e40c	100.00	{"user": "5e2de4dd-f65c-43ae-9ab6-363fe303ab1e", "score": 100, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	72cf6e867396bac722de93f499c7036e7daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-08-01 18:31:45.462661+00	\N	\N
cf923d32-252c-485a-a222-82146cb89260	IMD-CC-2026-000235	ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	486ae347-6271-439f-9865-ebaf1e4d93cd	22137d58-bb6e-4684-ac71-af5834fa91b8	83.00	{"user": "ee225bc3-ea1f-4dcc-9f2b-500f66e47b52", "score": 83, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	7808bb257bc6b943a4ab36343b2483817daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-07-05 18:31:45.462661+00	\N	\N
bb39ca88-11e5-40b4-a61c-43c320d63ba3	IMD-CC-2026-000236	c43722c6-7e70-49e0-acb4-ba4f953e36a8	486ae347-6271-439f-9865-ebaf1e4d93cd	46371ecb-ab8d-48cb-9551-ce4e65e40d49	91.00	{"user": "c43722c6-7e70-49e0-acb4-ba4f953e36a8", "score": 91, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	ce6b185472420083a47ab626cf9745647daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-05-12 18:31:45.462661+00	\N	\N
e2e703a8-ccb8-40be-9d0a-afde36aeae84	IMD-CC-2026-000237	7e426fed-4c2e-46f4-866a-7b8aa048cf06	486ae347-6271-439f-9865-ebaf1e4d93cd	84653a4b-a983-41ef-a5e2-63952c4d3c8c	78.00	{"user": "7e426fed-4c2e-46f4-866a-7b8aa048cf06", "score": 78, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	41a5c4f1110cda42342e1330116290887daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-05-14 18:31:45.462661+00	\N	\N
fa234d09-f6a3-4236-a8f6-9ab1f2588ea4	IMD-CC-2026-000238	cbd81a81-1d5a-4273-8494-11efdd5fd354	486ae347-6271-439f-9865-ebaf1e4d93cd	92f3efa8-5520-4669-865b-911e9acb8bf4	90.00	{"user": "cbd81a81-1d5a-4273-8494-11efdd5fd354", "score": 90, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	778e2502859869da0e9b0c93b34b84ed7daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-06-02 18:31:45.462661+00	\N	\N
8d0f4a51-8b6d-485b-a694-58a7b9151836	IMD-CC-2026-000239	e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	486ae347-6271-439f-9865-ebaf1e4d93cd	6685b5c2-c445-437f-8982-088acbb2aaf6	100.00	{"user": "e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a", "score": 100, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	1200c33bfb0ddaf94738dd4f076a19bc7daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-03-17 18:31:45.462661+00	\N	\N
9b7e6e50-af63-4dcc-820a-790eaaa11f03	IMD-CC-2026-000240	fafec148-becc-4918-b1e0-08794a94f6de	486ae347-6271-439f-9865-ebaf1e4d93cd	6d9ef8ce-4516-477d-a377-d9378e3e706d	97.00	{"user": "fafec148-becc-4918-b1e0-08794a94f6de", "score": 97, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	b546f419cce89e40a45a1e3efe73df157daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-06-05 18:31:45.462661+00	\N	\N
8e5f3d61-9844-4bf5-a879-d3d2b8445e4a	IMD-CC-2026-000241	0d37acee-70ea-4604-8bd7-c995941443fd	486ae347-6271-439f-9865-ebaf1e4d93cd	64b43b10-758e-42ba-801c-ddc879155c24	100.00	{"user": "0d37acee-70ea-4604-8bd7-c995941443fd", "score": 100, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	55d6e90c965027c4cbb8f8b4ec3fdff77daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-09-21 18:31:45.462661+00	\N	\N
fb545906-bfd7-40cc-9de6-ca02d6c03c28	IMD-CC-2026-000242	625944b1-2b9b-433b-9af5-e72894aa7a58	486ae347-6271-439f-9865-ebaf1e4d93cd	b71a1063-1a8a-47f3-b9aa-d80b034c1ef4	73.00	{"user": "625944b1-2b9b-433b-9af5-e72894aa7a58", "score": 73, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	b681196ee457b67ef83b45a92db68e557daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-05-03 18:31:45.462661+00	\N	\N
dc7156e4-3824-4c70-a517-ac913f602be6	IMD-CC-2026-000243	4ead5d1f-209d-4c0f-950b-80d8668a696b	486ae347-6271-439f-9865-ebaf1e4d93cd	fc61ec7a-1ed9-4cea-a089-193b931f37f1	96.00	{"user": "4ead5d1f-209d-4c0f-950b-80d8668a696b", "score": 96, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	bce0c8fca0405013cdc7c1957cb45b757daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-02-20 18:31:45.462661+00	\N	\N
8a821ced-ff34-48d1-8113-8e77d24ac486	IMD-CC-2026-000244	4135122d-a240-499c-8de4-3db650d7acc9	486ae347-6271-439f-9865-ebaf1e4d93cd	35624d3f-0860-4653-95f6-31889b1146ed	100.00	{"user": "4135122d-a240-499c-8de4-3db650d7acc9", "score": 100, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	b16876d13685bf7eb776f0e8998585bb7daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-07-01 18:31:45.462661+00	\N	\N
452f21a4-ff44-48e9-a09b-1950711a4b93	IMD-CC-2026-000245	9389e5a2-816f-4e52-950b-a9af117c7ad1	486ae347-6271-439f-9865-ebaf1e4d93cd	ac1768e2-844c-4518-941b-f421bc6011dd	100.00	{"user": "9389e5a2-816f-4e52-950b-a9af117c7ad1", "score": 100, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	62130071cf77ca0f5974143df80986857daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-06-26 18:31:45.462661+00	\N	\N
6fabbff0-5a38-4cdb-8c3b-b567b3ddc27f	IMD-CC-2026-000246	d2298ed0-2515-4232-b70f-845a98dac595	486ae347-6271-439f-9865-ebaf1e4d93cd	d7355fc7-c701-4728-9c74-982a8a2841ce	84.00	{"user": "d2298ed0-2515-4232-b70f-845a98dac595", "score": 84, "course": "486ae347-6271-439f-9865-ebaf1e4d93cd"}	9b1fb39c3fc82f1dc869f4fbd7f160f77daff371a7e7c9e9f9c6d3fcb5911b56	demo-signature	\N	2026-02-14 18:31:45.462661+00	\N	\N
3205b78a-9eb4-4234-bcac-032ee5eb6835	IMD-CC-2026-000247	7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	377c54d8-88d8-4698-a98c-27a42d2dae92	4af9bcad-a065-43a1-8903-c705dca537c7	62.00	{"user": "7bf1a0d2-b293-4feb-b3d9-a07cf3db5249", "score": 62, "course": "377c54d8-88d8-4698-a98c-27a42d2dae92"}	086efbcf202007edd42bcae752390e598da6e196a4bdeb63dff54d237ac197b2	demo-signature	\N	2026-08-21 18:31:45.462661+00	\N	\N
e0cb7f93-7c47-4337-9a87-4e3ad438b0c1	IMD-CC-2026-000248	1f511b5e-1292-4202-860e-b54f11eda21e	377c54d8-88d8-4698-a98c-27a42d2dae92	ec0d67ba-05e4-49ad-bdfc-fe058f822d4d	63.00	{"user": "1f511b5e-1292-4202-860e-b54f11eda21e", "score": 63, "course": "377c54d8-88d8-4698-a98c-27a42d2dae92"}	8de3c28d3728be8cb3459989fc8248838da6e196a4bdeb63dff54d237ac197b2	demo-signature	\N	2026-09-21 18:31:45.462661+00	\N	\N
3f1bf9ef-ae4e-43b5-833a-314bf3fcf34d	IMD-CC-2026-000249	f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d	377c54d8-88d8-4698-a98c-27a42d2dae92	bf586382-90e2-47f0-a6e2-66cc899fc11d	65.00	{"user": "f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d", "score": 65, "course": "377c54d8-88d8-4698-a98c-27a42d2dae92"}	e16abb8a535b68322ef9c854d46f13558da6e196a4bdeb63dff54d237ac197b2	demo-signature	\N	2026-04-06 18:31:45.462661+00	\N	\N
ec941a0a-bdc3-4815-b3b6-41bdf515501a	IMD-CC-2026-000250	9bab5f84-a53e-49d6-91f8-eef87bf5960c	1b09caa2-5a18-4f05-9a17-18d849ee499f	331a226c-04ee-46da-ad87-7713df6f5c39	70.00	{"user": "9bab5f84-a53e-49d6-91f8-eef87bf5960c", "score": 70, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	c59cb8d601f26f4c01395fd6760fb7040e043e416b65224e371f56d849839303	demo-signature	\N	2026-05-13 18:31:45.462661+00	\N	\N
811d4ee8-5b3a-4397-815c-74118e5715cf	IMD-CC-2026-000251	3b6030a2-3993-4389-8c6c-d3427e0e680b	1b09caa2-5a18-4f05-9a17-18d849ee499f	0cad093c-d94d-44e6-8c2a-a425174f68af	96.00	{"user": "3b6030a2-3993-4389-8c6c-d3427e0e680b", "score": 96, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	6b9ea5225ae57c95f755dc3a9d0777800e043e416b65224e371f56d849839303	demo-signature	\N	2026-08-11 18:31:45.462661+00	\N	\N
5ec95baf-96d6-480e-aa7a-98223e7b3a8a	IMD-CC-2026-000252	3d87692f-06c1-4403-95ff-c70d1598700a	1b09caa2-5a18-4f05-9a17-18d849ee499f	1e123daf-856a-444a-a8fb-440731a235dc	75.00	{"user": "3d87692f-06c1-4403-95ff-c70d1598700a", "score": 75, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	9f8cd4da5dc32f67691dc08c609a70dc0e043e416b65224e371f56d849839303	demo-signature	\N	2026-04-11 18:31:45.462661+00	\N	\N
1b1f6804-74b2-4359-a9b9-21ca09296861	IMD-CC-2026-000253	a17abc66-209e-405f-bcd6-c39e54cbce66	1b09caa2-5a18-4f05-9a17-18d849ee499f	9bd1efd2-d395-4c8d-943e-ce8731fc61db	86.00	{"user": "a17abc66-209e-405f-bcd6-c39e54cbce66", "score": 86, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	1c20d94f1673423d6e7e4b689ff4fea80e043e416b65224e371f56d849839303	demo-signature	\N	2026-05-18 18:31:45.462661+00	\N	\N
55012332-f21a-4495-b640-7c338d339bb4	IMD-CC-2026-000254	9389e5a2-816f-4e52-950b-a9af117c7ad1	1b09caa2-5a18-4f05-9a17-18d849ee499f	f2d20381-dae2-4187-87c3-f79bcad3a29c	100.00	{"user": "9389e5a2-816f-4e52-950b-a9af117c7ad1", "score": 100, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	0c2385edbc7852c7a4d4ecc1a46f685d0e043e416b65224e371f56d849839303	demo-signature	\N	2026-05-20 18:31:45.462661+00	\N	\N
636603e8-7ef7-4e16-95af-3e33d63ef73c	IMD-CC-2026-000255	a5e41a1c-9682-4873-8924-f11edf9b3fce	1b09caa2-5a18-4f05-9a17-18d849ee499f	082de00e-c610-4ad9-b886-024543f17607	70.00	{"user": "a5e41a1c-9682-4873-8924-f11edf9b3fce", "score": 70, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	17b95baeb436468d888326069dbc7c610e043e416b65224e371f56d849839303	demo-signature	\N	2026-03-04 18:31:45.462661+00	\N	\N
00f00ae9-74a7-41c2-86f3-223b3ff407ef	IMD-CC-2026-000256	4acb1924-e6ec-428c-8401-ac05f87e2bbf	1b09caa2-5a18-4f05-9a17-18d849ee499f	9d85f483-fe80-40cc-8bb6-e52ec7853651	97.00	{"user": "4acb1924-e6ec-428c-8401-ac05f87e2bbf", "score": 97, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	87e1ce95a0fb70324213db21514e2f360e043e416b65224e371f56d849839303	demo-signature	\N	2026-08-13 18:31:45.462661+00	\N	\N
1be25c8c-4ba7-4bf9-90c0-5e53648bb7d5	IMD-CC-2026-000257	d05292f5-3e9f-4e51-bb50-05a6534dc9b8	1b09caa2-5a18-4f05-9a17-18d849ee499f	6045805b-b8e4-4c2a-91ff-d2849fe8e8e8	78.00	{"user": "d05292f5-3e9f-4e51-bb50-05a6534dc9b8", "score": 78, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	eafa6ad2460527f9d2c4083484a0ffbd0e043e416b65224e371f56d849839303	demo-signature	\N	2026-07-05 18:31:45.462661+00	\N	\N
a892ac54-4522-4220-b69a-a9b5737c4096	IMD-CC-2026-000258	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	1b09caa2-5a18-4f05-9a17-18d849ee499f	13c8e727-23af-4466-9e2a-f4ad1084ee9b	73.00	{"user": "89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f", "score": 73, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	6d69e101b8a9780602a2fe34f753c9a60e043e416b65224e371f56d849839303	demo-signature	\N	2026-02-14 18:31:45.462661+00	\N	\N
9dfb0882-e706-446a-872a-7beb483909d5	IMD-CC-2026-000259	30e16278-0ca1-4efa-a03b-7168658bb2c2	1b09caa2-5a18-4f05-9a17-18d849ee499f	634b463d-f4d5-41d5-9b46-c592c84e07e1	86.00	{"user": "30e16278-0ca1-4efa-a03b-7168658bb2c2", "score": 86, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	266ef6798f848ce97dc76dfba67376ba0e043e416b65224e371f56d849839303	demo-signature	\N	2026-08-18 18:31:45.462661+00	\N	\N
3e8ecbd9-ddfb-427d-9f02-3911753feeba	IMD-CC-2026-000260	b010ad34-1872-4015-9120-b4d6e175bda3	1b09caa2-5a18-4f05-9a17-18d849ee499f	f47e1eb9-1e5d-43b5-8e5f-d1f165ee1ce7	99.00	{"user": "b010ad34-1872-4015-9120-b4d6e175bda3", "score": 99, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	accd8981b20270d2f982b666225784ca0e043e416b65224e371f56d849839303	demo-signature	\N	2026-09-07 18:31:45.462661+00	\N	\N
c446acf0-4b9a-430d-830d-76a7c1d95116	IMD-CC-2026-000261	88b2de0e-fb93-4402-98ef-3c1bd149f61d	1b09caa2-5a18-4f05-9a17-18d849ee499f	96927b62-755a-4feb-bacd-fb966d58a9f7	70.00	{"user": "88b2de0e-fb93-4402-98ef-3c1bd149f61d", "score": 70, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	7e484d58f8052475a6f8d1fdac07f2cc0e043e416b65224e371f56d849839303	demo-signature	\N	2026-06-04 18:31:45.462661+00	\N	\N
803f42d0-e38a-49c1-943f-a61f12a9b8cd	IMD-CC-2026-000262	f1831789-130e-485d-bc67-67fe3b5fc6af	1b09caa2-5a18-4f05-9a17-18d849ee499f	0d2134d9-2320-4ad9-9379-a22f7621e43f	72.00	{"user": "f1831789-130e-485d-bc67-67fe3b5fc6af", "score": 72, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	9f2865f8384f53bb64ab9d65663bc50a0e043e416b65224e371f56d849839303	demo-signature	\N	2026-05-22 18:31:45.462661+00	\N	\N
58580afb-f1f6-4ece-9cf9-042a23c6f281	IMD-CC-2026-000263	a5fd318c-feeb-4b1b-b739-3e40a59dde18	1b09caa2-5a18-4f05-9a17-18d849ee499f	315b2a02-97fe-48d9-8f74-b66e4b6f1cde	69.00	{"user": "a5fd318c-feeb-4b1b-b739-3e40a59dde18", "score": 69, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	901de177b51e8d30bf6ecfaffe352ca30e043e416b65224e371f56d849839303	demo-signature	\N	2026-07-01 18:31:45.462661+00	\N	\N
51cb0e95-653a-407d-b8c4-e1d0d212c095	IMD-CC-2026-000264	ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	1b09caa2-5a18-4f05-9a17-18d849ee499f	787fd8fe-71a4-46c2-acca-76fc9e72b1d2	95.00	{"user": "ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5", "score": 95, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	5016c35a04d8814c77c2cc82031410580e043e416b65224e371f56d849839303	demo-signature	\N	2026-06-11 18:31:45.462661+00	\N	\N
fe818a6b-47c5-448d-9bf5-1f4cce3830c2	IMD-CC-2026-000265	286bd41d-35d4-4b43-b05b-8548dab978ab	1b09caa2-5a18-4f05-9a17-18d849ee499f	12548d66-253b-45e2-8aae-b501d574ee45	83.00	{"user": "286bd41d-35d4-4b43-b05b-8548dab978ab", "score": 83, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	a1799933d2ad8228be73cbf6ba6dfa230e043e416b65224e371f56d849839303	demo-signature	\N	2026-09-04 18:31:45.462661+00	\N	\N
696044da-acb4-4f00-9689-466f47dfd7bb	IMD-CC-2026-000266	6b116d7e-84ed-47de-81ea-2bd42ea50968	1b09caa2-5a18-4f05-9a17-18d849ee499f	dcdb7bac-9754-4a16-9c72-a0a29bf0ee08	82.00	{"user": "6b116d7e-84ed-47de-81ea-2bd42ea50968", "score": 82, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	64d14691a474f4f4d26aa3faddfecfba0e043e416b65224e371f56d849839303	demo-signature	\N	2026-04-28 18:31:45.462661+00	\N	\N
fcb395a8-8dcd-4f75-8d87-cabf59d6fb39	IMD-CC-2026-000267	312e5b6a-024a-4a5d-9389-357b73426d42	1b09caa2-5a18-4f05-9a17-18d849ee499f	b2b9a177-03ae-4a4f-9a92-8bbe877e3b85	82.00	{"user": "312e5b6a-024a-4a5d-9389-357b73426d42", "score": 82, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	787cf130d4ae3e5f74be03ef1113e27c0e043e416b65224e371f56d849839303	demo-signature	\N	2026-03-23 18:31:45.462661+00	\N	\N
ef29a3c3-5029-491f-8c5e-847df4c5c709	IMD-CC-2026-000268	732e74cf-b9b7-4adc-a43a-794430d7fe49	1b09caa2-5a18-4f05-9a17-18d849ee499f	8f527347-6e47-4660-a036-41a143c235bd	96.00	{"user": "732e74cf-b9b7-4adc-a43a-794430d7fe49", "score": 96, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	b5eb01e6eba9034bf04427b67ebe43e20e043e416b65224e371f56d849839303	demo-signature	\N	2026-02-18 18:31:45.462661+00	\N	\N
ec668c26-b1bf-4079-8dfd-67e65c739010	IMD-CC-2026-000269	cc7120df-7364-4284-a971-893f524d1a25	1b09caa2-5a18-4f05-9a17-18d849ee499f	6df0e517-9b3f-4c94-8444-a3ea8f094413	72.00	{"user": "cc7120df-7364-4284-a971-893f524d1a25", "score": 72, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	ad39b008906e2ebc46ccc32d10809bd50e043e416b65224e371f56d849839303	demo-signature	\N	2026-08-05 18:31:45.462661+00	\N	\N
369cf59e-d7c2-4d2b-909b-10d7d14f04ed	IMD-CC-2026-000270	c41a5544-af25-44ec-9fab-26fa3a4e08a5	1b09caa2-5a18-4f05-9a17-18d849ee499f	f5cbd04e-96fa-4170-ac8a-e9d58cad23d7	79.00	{"user": "c41a5544-af25-44ec-9fab-26fa3a4e08a5", "score": 79, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	3989db3a4954d50c29844cdca63af8420e043e416b65224e371f56d849839303	demo-signature	\N	2026-08-28 18:31:45.462661+00	\N	\N
fa8e2e04-d292-4d21-9fc4-7e7913d7a6e1	IMD-CC-2026-000271	f51dbbc6-5c8a-487d-b785-786417797dc8	1b09caa2-5a18-4f05-9a17-18d849ee499f	2b0c4c7d-8e57-44a6-9091-f1a2a599695f	68.00	{"user": "f51dbbc6-5c8a-487d-b785-786417797dc8", "score": 68, "course": "1b09caa2-5a18-4f05-9a17-18d849ee499f"}	c0d472a7a596bc47657e6a60060672880e043e416b65224e371f56d849839303	demo-signature	\N	2026-03-19 18:31:45.462661+00	\N	\N
50fb1145-a241-4c5c-87fc-c04e97eb3217	IMD-CC-2026-000272	8ffbd0cf-b807-4193-af37-3a61482c76eb	614b89b9-ad9a-4481-9970-4691dd4e45dc	8d9b92e1-3080-44d3-8e0c-64595280cdf0	70.00	{"user": "8ffbd0cf-b807-4193-af37-3a61482c76eb", "score": 70, "course": "614b89b9-ad9a-4481-9970-4691dd4e45dc"}	4d02e501decfdc022521d9df51c1a4b714f343e65a1c64790ca0212355a8548d	demo-signature	\N	2026-09-13 18:31:45.462661+00	\N	\N
999369c9-62a1-4f0e-bdb0-d2bfadbe65ca	IMD-CC-2026-000273	f74aaa72-56ba-476d-9aed-ffbe2e41dd50	614b89b9-ad9a-4481-9970-4691dd4e45dc	d08beaf1-9026-4550-8079-a675cf118333	61.00	{"user": "f74aaa72-56ba-476d-9aed-ffbe2e41dd50", "score": 61, "course": "614b89b9-ad9a-4481-9970-4691dd4e45dc"}	a330d4c00886ce250f449003b71f9cee14f343e65a1c64790ca0212355a8548d	demo-signature	\N	2026-03-05 18:31:45.462661+00	\N	\N
ac5a35ce-2b03-4843-8a09-b562a67b51f9	IMD-CC-2026-000274	8be014b0-ed46-43db-89e2-91a301c618db	614b89b9-ad9a-4481-9970-4691dd4e45dc	b3d3cd9b-77e3-4424-99a7-c4a8a72899f4	73.00	{"user": "8be014b0-ed46-43db-89e2-91a301c618db", "score": 73, "course": "614b89b9-ad9a-4481-9970-4691dd4e45dc"}	12ab46529b22bfc251e0e1e3213be09e14f343e65a1c64790ca0212355a8548d	demo-signature	\N	2026-08-08 18:31:45.462661+00	\N	\N
d6684a44-cf91-4e2d-8e8b-07fd58a64cf3	IMD-CC-2026-000275	b0ba69f7-69ce-411c-a22d-c449785d11e9	614b89b9-ad9a-4481-9970-4691dd4e45dc	1287250a-1285-45dd-bec8-232a630c5287	73.00	{"user": "b0ba69f7-69ce-411c-a22d-c449785d11e9", "score": 73, "course": "614b89b9-ad9a-4481-9970-4691dd4e45dc"}	412adb9ffe56d25d540d798b99cabd7a14f343e65a1c64790ca0212355a8548d	demo-signature	\N	2026-06-13 18:31:45.462661+00	\N	\N
1dd91146-c7d0-4981-b439-f09b2ee17737	IMD-CC-2026-000276	e6ef6d8e-87f0-4c3d-8ac9-dccb12f222f1	614b89b9-ad9a-4481-9970-4691dd4e45dc	0acaa4f6-a0bb-47bf-9268-02104d0bea5b	64.00	{"user": "e6ef6d8e-87f0-4c3d-8ac9-dccb12f222f1", "score": 64, "course": "614b89b9-ad9a-4481-9970-4691dd4e45dc"}	3f55d5d73acbafa07c8ed49a39eaf0aa14f343e65a1c64790ca0212355a8548d	demo-signature	\N	2026-08-19 18:31:45.462661+00	\N	\N
824f3c3e-0bb7-437e-9523-c5931508d514	IMD-CC-2026-000277	cc9e83f0-d177-4454-8ba5-f7581c6da639	614b89b9-ad9a-4481-9970-4691dd4e45dc	64eff6d8-0e3f-4275-8b9e-e77eaf6eb9e2	69.00	{"user": "cc9e83f0-d177-4454-8ba5-f7581c6da639", "score": 69, "course": "614b89b9-ad9a-4481-9970-4691dd4e45dc"}	d996579c4072dadc01c4edc7fa4e290a14f343e65a1c64790ca0212355a8548d	demo-signature	\N	2026-06-28 18:31:45.462661+00	\N	\N
bd35b4a7-a7c7-40e7-b7a7-4176800a9b35	IMD-CC-2026-000278	3260915b-2633-418b-997d-2beabd07ed2b	614b89b9-ad9a-4481-9970-4691dd4e45dc	aac5213a-c549-4138-a1db-86692e0197aa	72.00	{"user": "3260915b-2633-418b-997d-2beabd07ed2b", "score": 72, "course": "614b89b9-ad9a-4481-9970-4691dd4e45dc"}	d5f26fa9bc75cff4a3834e18473aa0ac14f343e65a1c64790ca0212355a8548d	demo-signature	\N	2026-07-21 18:31:45.462661+00	\N	\N
dcde2bbd-5c3d-46eb-914c-7eb29e9bed08	IMD-CC-2026-000279	4c6d827e-f3db-47d8-be22-4dc4a611c63f	614b89b9-ad9a-4481-9970-4691dd4e45dc	4b18e720-c770-4cf1-b3ba-3aa6e1c0d735	78.00	{"user": "4c6d827e-f3db-47d8-be22-4dc4a611c63f", "score": 78, "course": "614b89b9-ad9a-4481-9970-4691dd4e45dc"}	7ee2eb379e44d87c22124639993fa08014f343e65a1c64790ca0212355a8548d	demo-signature	\N	2026-06-25 18:31:45.462661+00	\N	\N
4251ee8a-ec47-49c8-bc29-fff8583062ba	IMD-CC-2026-000280	ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	614b89b9-ad9a-4481-9970-4691dd4e45dc	cc86626b-2676-4815-a467-a773fdbb6190	78.00	{"user": "ee225bc3-ea1f-4dcc-9f2b-500f66e47b52", "score": 78, "course": "614b89b9-ad9a-4481-9970-4691dd4e45dc"}	d869283b25edd49a25102a23c536b0a214f343e65a1c64790ca0212355a8548d	demo-signature	\N	2026-07-09 18:31:45.462661+00	\N	\N
2b2d6038-1dc1-49f6-89ba-a2e4e903a23e	IMD-CC-2026-000281	6ec3f843-359c-4b5b-bc41-b3bd56c6e134	614b89b9-ad9a-4481-9970-4691dd4e45dc	e84872c6-0c83-4d81-b957-6dcd7c4c4d13	63.00	{"user": "6ec3f843-359c-4b5b-bc41-b3bd56c6e134", "score": 63, "course": "614b89b9-ad9a-4481-9970-4691dd4e45dc"}	725de018b19c02555512ad43d1d3565614f343e65a1c64790ca0212355a8548d	demo-signature	\N	2026-02-23 18:31:45.462661+00	\N	\N
84fbc26f-751f-4236-863f-648f8f313dc5	IMD-CC-2026-000282	f75210c9-faa1-45c8-9314-a65724983502	6be0b4cc-255a-4372-be78-8bd23dee561b	9498b0cf-27eb-4f74-873b-5a4d92340d4c	80.00	{"user": "f75210c9-faa1-45c8-9314-a65724983502", "score": 80, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	60f32c57aab9848737322b44248028c2483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-04-11 18:31:45.462661+00	\N	\N
43a8934b-7a42-418a-bbe8-56cb76bf5d94	IMD-CC-2026-000283	a5fd318c-feeb-4b1b-b739-3e40a59dde18	6be0b4cc-255a-4372-be78-8bd23dee561b	8ade1740-10cd-4771-9fe8-18f599882543	66.00	{"user": "a5fd318c-feeb-4b1b-b739-3e40a59dde18", "score": 66, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	8c9f5f76e913fdc493f495e55daa4cdf483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-05-13 18:31:45.462661+00	\N	\N
751b458c-d52b-44cf-91ba-4fb064e4625d	IMD-CC-2026-000284	a6afe850-9547-4fac-892c-00558ad8f725	6be0b4cc-255a-4372-be78-8bd23dee561b	62a44d5e-f950-4a89-a85f-4234d849e521	75.00	{"user": "a6afe850-9547-4fac-892c-00558ad8f725", "score": 75, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	b7898b1fb9f99eacea60a92d3657dc6d483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-06-19 18:31:45.462661+00	\N	\N
e94267aa-0cbd-4354-a22b-586c2d63cedc	IMD-CC-2026-000285	b97db5e7-dca3-4f88-8318-6d457e09be91	6be0b4cc-255a-4372-be78-8bd23dee561b	c1a8999e-e0c8-4430-a308-2b7d588904bf	80.00	{"user": "b97db5e7-dca3-4f88-8318-6d457e09be91", "score": 80, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	513eb63018f14f7e557d5b2bcc521dde483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-05-13 18:31:45.462661+00	\N	\N
415a7ad2-2e46-4e16-9d54-8f82a43f50cc	IMD-CC-2026-000286	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	6be0b4cc-255a-4372-be78-8bd23dee561b	aee21e84-d56c-4ba3-bdaf-761c85addbb6	60.00	{"user": "f32344cc-9180-4953-b2cd-ba0f4bdb2eea", "score": 60, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	0b4093f80e6f9236269dcde6db7a7fa6483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-08-07 18:31:45.462661+00	\N	\N
4bbcfc21-d797-4ad6-8ed8-178404b62f42	IMD-CC-2026-000287	b2734396-c5d2-4b05-99d0-986a180a98a6	6be0b4cc-255a-4372-be78-8bd23dee561b	0f1d8cb1-ca68-4651-8ef5-577f2d4ce3d9	75.00	{"user": "b2734396-c5d2-4b05-99d0-986a180a98a6", "score": 75, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	8ca86bdf1670933ae57780cf30e96536483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-06-07 18:31:45.462661+00	\N	\N
568ea5f4-8b3c-48c8-8313-d988598ff404	IMD-CC-2026-000288	3d04f1c2-2486-4f53-bde5-76ba389ec266	6be0b4cc-255a-4372-be78-8bd23dee561b	429db28d-617b-472a-9af3-e0cf6802fb71	60.00	{"user": "3d04f1c2-2486-4f53-bde5-76ba389ec266", "score": 60, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	4d6860d3d0b91da45255e3abaa0c012a483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-04-01 18:31:45.462661+00	\N	\N
738d1812-427b-4b42-9141-17a7282f19e5	IMD-CC-2026-000289	3a18a01e-89f7-474e-abf1-964581203793	6be0b4cc-255a-4372-be78-8bd23dee561b	5d9c894a-1c44-42c1-aeef-f3124dfbc0fb	65.00	{"user": "3a18a01e-89f7-474e-abf1-964581203793", "score": 65, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	a83c0c288bfead76710884c14b73b1fd483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-09-04 18:31:45.462661+00	\N	\N
0e8565f8-c034-4698-bf2a-157548c2b526	IMD-CC-2026-000290	78313b75-0494-43a4-b199-ff1928254f44	6be0b4cc-255a-4372-be78-8bd23dee561b	1887d5d8-9896-4daa-817d-647301b36be4	70.00	{"user": "78313b75-0494-43a4-b199-ff1928254f44", "score": 70, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	0341339a59aac16d0930a54daaefca6e483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-05-10 18:31:45.462661+00	\N	\N
3fec0dbc-baf2-48a7-b9b1-65175a41681d	IMD-CC-2026-000291	10e55ead-3752-4108-a6b5-5a48ee709f03	6be0b4cc-255a-4372-be78-8bd23dee561b	681df2cc-4c58-46f1-bd8a-977ce803d6c6	78.00	{"user": "10e55ead-3752-4108-a6b5-5a48ee709f03", "score": 78, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	9c36cccb039f600eb75567d3f055d866483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-04-30 18:31:45.462661+00	\N	\N
aa367fbf-2857-41d4-998e-750ef0dadd48	IMD-CC-2026-000292	f8cb8b17-b65c-4df2-baab-62604c96a8c0	6be0b4cc-255a-4372-be78-8bd23dee561b	c16af279-c576-405f-b975-fb76ce4a7393	80.00	{"user": "f8cb8b17-b65c-4df2-baab-62604c96a8c0", "score": 80, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	71d65e1646e9f1f188abc56d67f0ba53483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-07-10 18:31:45.462661+00	\N	\N
1dd34520-b462-4700-bd34-98fbbd47b9da	IMD-CC-2026-000293	e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	6be0b4cc-255a-4372-be78-8bd23dee561b	ca0239e6-0043-4952-9161-33a6f8edb4bb	62.00	{"user": "e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a", "score": 62, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	b3f4a2f8959f465d8d2fcf07eaefc5f9483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-03-25 18:31:45.462661+00	\N	\N
2bf1d51d-924a-4f66-81fa-9dbe8bd38ba9	IMD-CC-2026-000294	ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	6be0b4cc-255a-4372-be78-8bd23dee561b	bc965598-2b5c-45c8-9860-ce19fc8706a8	79.00	{"user": "ee225bc3-ea1f-4dcc-9f2b-500f66e47b52", "score": 79, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	35eb1859e2d345eeb6f710d4d01e6959483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-07-08 18:31:45.462661+00	\N	\N
7cff621f-d8cb-4e28-bc21-6b8977372d80	IMD-CC-2026-000295	18407190-2219-4190-9b20-ee775b0094ef	6be0b4cc-255a-4372-be78-8bd23dee561b	a00b5e78-dc85-4b78-91b3-7da74026613c	63.00	{"user": "18407190-2219-4190-9b20-ee775b0094ef", "score": 63, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	f179dafb4205d32ffcd2561797e4423a483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-04-06 18:31:45.462661+00	\N	\N
b2c99179-0db2-4b09-8884-ad8ab37aef2e	IMD-CC-2026-000296	28fe79f0-6207-4e0c-8bae-1eb02eed759b	6be0b4cc-255a-4372-be78-8bd23dee561b	cfb220ae-a8d8-4f41-a4e7-0804ee5c80d1	87.00	{"user": "28fe79f0-6207-4e0c-8bae-1eb02eed759b", "score": 87, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	77679087324cf4d43557ba0c98f03e0b483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-06-28 18:31:45.462661+00	\N	\N
a5d0e934-22f9-4e0a-97d1-cc1270557555	IMD-CC-2026-000297	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	6be0b4cc-255a-4372-be78-8bd23dee561b	ce59f071-0a5e-4a75-b9bc-a9c18b38ee51	81.00	{"user": "b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e", "score": 81, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	11272230380d6bc165e83c1ff7f6e346483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-06-13 18:31:45.462661+00	\N	\N
a20dbcee-cb47-40b0-9f6f-02cffea7eeaf	IMD-CC-2026-000298	55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	6be0b4cc-255a-4372-be78-8bd23dee561b	fdbce967-d5ca-4651-9514-be1e0d0f7a09	87.00	{"user": "55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f", "score": 87, "course": "6be0b4cc-255a-4372-be78-8bd23dee561b"}	3ce285cca490837203cac71d5ce693f1483a626936d3c4b59d739552e9e24b12	demo-signature	\N	2026-06-01 18:31:45.462661+00	\N	\N
e723738b-a391-46fc-9001-5af5e81cd8d0	IMD-CC-2026-000299	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	eec7cc46-3395-4f21-8c7f-cb99bee58b55	5273cfbe-de5f-4f84-985b-a90970501d19	79.00	{"user": "0369edbf-d1ba-47c9-b17c-e67c29bf27fc", "score": 79, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	67c3ef1542ca9ae976e68d87bc2e8889e40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-03-04 18:31:45.462661+00	\N	\N
f3a74b52-439d-4f4e-9376-4b551488c3fc	IMD-CC-2026-000300	78313b75-0494-43a4-b199-ff1928254f44	eec7cc46-3395-4f21-8c7f-cb99bee58b55	024d7c57-f181-4492-88fb-e2eb31622529	68.00	{"user": "78313b75-0494-43a4-b199-ff1928254f44", "score": 68, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	693dcaca7940b6156a26d7ccf7f5fa66e40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-08-04 18:31:45.462661+00	\N	\N
79f19c60-92a3-4c13-8225-b399c3fe63ad	IMD-CC-2026-000301	f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d	eec7cc46-3395-4f21-8c7f-cb99bee58b55	669663f8-1a7c-45e7-916a-275e746e56cc	64.00	{"user": "f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d", "score": 64, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	4568b26bdcf846ac33863674dba6c32ee40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-08-23 18:31:45.462661+00	\N	\N
5f0ebd40-cd1a-4e2a-8003-f4dddece7057	IMD-CC-2026-000302	62868b88-e860-457b-8605-04153588489b	eec7cc46-3395-4f21-8c7f-cb99bee58b55	b46a12e9-d4b3-498a-96b3-56e3cd784292	92.00	{"user": "62868b88-e860-457b-8605-04153588489b", "score": 92, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	40978199cf881e2bdf7590c941262b0ae40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-03-14 18:31:45.462661+00	\N	\N
86528ac2-b69e-4cd4-bff4-6f0f23812c55	IMD-CC-2026-000303	c43722c6-7e70-49e0-acb4-ba4f953e36a8	eec7cc46-3395-4f21-8c7f-cb99bee58b55	996a79dd-6e64-4727-864c-9d21bce49ad1	67.00	{"user": "c43722c6-7e70-49e0-acb4-ba4f953e36a8", "score": 67, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	53ac918f25b1eca39d66b658b35fc9f0e40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-08-11 18:31:45.462661+00	\N	\N
f09bc3db-7bcf-4094-b31b-00d134dd60d2	IMD-CC-2026-000304	3ded69a7-290c-47f6-bd29-7369f6f8e3c8	eec7cc46-3395-4f21-8c7f-cb99bee58b55	6512a51c-6b77-43e6-a80b-67046f0b165d	88.00	{"user": "3ded69a7-290c-47f6-bd29-7369f6f8e3c8", "score": 88, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	2765e18a12dc8ccfca6c6bba98c77179e40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-07-15 18:31:45.462661+00	\N	\N
1da4a4c2-8081-4402-bc25-b77f6f9ea9ef	IMD-CC-2026-000305	3af00a36-1f7b-4846-a52a-b1871416c5b1	eec7cc46-3395-4f21-8c7f-cb99bee58b55	ba812071-aa59-409a-8e0c-987c7addea18	71.00	{"user": "3af00a36-1f7b-4846-a52a-b1871416c5b1", "score": 71, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	06b39b0739cf2f4d4d1351fbdf3da836e40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-08-07 18:31:45.462661+00	\N	\N
e5aed4b4-6622-4207-8d43-2cfb8b1f35c2	IMD-CC-2026-000306	fbc637df-19cd-4ec5-b08d-49ce15747076	eec7cc46-3395-4f21-8c7f-cb99bee58b55	dd26475e-bd6f-4c71-8675-ec788f496856	76.00	{"user": "fbc637df-19cd-4ec5-b08d-49ce15747076", "score": 76, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	5c3f97d2529133ac60e3e47707ebf555e40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-06-14 18:31:45.462661+00	\N	\N
79f2013a-916c-4884-aa86-351b2c286214	IMD-CC-2026-000307	b2c7b829-9669-4258-ab45-acc4445b9d6d	eec7cc46-3395-4f21-8c7f-cb99bee58b55	df0456c9-0468-4a1e-8efa-735277743de1	100.00	{"user": "b2c7b829-9669-4258-ab45-acc4445b9d6d", "score": 100, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	2beca8feed0e0a318ee28f1973a1b909e40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-05-30 18:31:45.462661+00	\N	\N
b884d8c7-3547-4341-882f-4f5f969fcb26	IMD-CC-2026-000308	216136af-8b6b-44ae-a787-59506613a618	eec7cc46-3395-4f21-8c7f-cb99bee58b55	551e1cb8-9d92-4961-ad43-9c6ada81b06a	65.00	{"user": "216136af-8b6b-44ae-a787-59506613a618", "score": 65, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	6b50a6797005dd4dc85ea804f0ed1c84e40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-02-15 18:31:45.462661+00	\N	\N
1970c056-6d2c-48d9-99a6-ea9b59124985	IMD-CC-2026-000309	caf34c22-6898-4c15-bde0-08f3d2634d41	eec7cc46-3395-4f21-8c7f-cb99bee58b55	589135bf-8566-4d54-abc3-7d2fd87ea6d9	80.00	{"user": "caf34c22-6898-4c15-bde0-08f3d2634d41", "score": 80, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	a0b557fcc087c1b31ad7f9606ef78612e40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-03-03 18:31:45.462661+00	\N	\N
8004f461-1440-48f8-8325-18e8106a257d	IMD-CC-2026-000310	72a5ceb8-6b68-433d-9b99-d62b8c9f1375	eec7cc46-3395-4f21-8c7f-cb99bee58b55	1ef21f06-72bb-4431-86c4-cc3f53418259	75.00	{"user": "72a5ceb8-6b68-433d-9b99-d62b8c9f1375", "score": 75, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	3e1343ae06630094911abbb15dce8fcde40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-05-30 18:31:45.462661+00	\N	\N
010f9c02-1f84-4fc3-902a-e146fe0912d4	IMD-CC-2026-000311	a17abc66-209e-405f-bcd6-c39e54cbce66	eec7cc46-3395-4f21-8c7f-cb99bee58b55	fd3e89cc-0ae0-4c37-a91f-ab64042cf658	82.00	{"user": "a17abc66-209e-405f-bcd6-c39e54cbce66", "score": 82, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	bf4618dc451edc84d29e14206585e695e40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-06-09 18:31:45.462661+00	\N	\N
395c6c99-d477-4307-826c-22ad2d0e5565	IMD-CC-2026-000312	10e55ead-3752-4108-a6b5-5a48ee709f03	eec7cc46-3395-4f21-8c7f-cb99bee58b55	992f4518-bf25-4811-8d45-42dc2c2c5ace	87.00	{"user": "10e55ead-3752-4108-a6b5-5a48ee709f03", "score": 87, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	79589fbd06a07f242f3a3190c7d5fafae40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-07-23 18:31:45.462661+00	\N	\N
a76d9c73-5725-4c55-b7a4-547b09fa99d8	IMD-CC-2026-000313	fda17094-1c9f-45de-a42c-aa815d09bc2a	eec7cc46-3395-4f21-8c7f-cb99bee58b55	326f8cb2-fcf3-48d8-9e92-a69df039b876	82.00	{"user": "fda17094-1c9f-45de-a42c-aa815d09bc2a", "score": 82, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	90883d026c86e72d83f7944032e21ecfe40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-08-06 18:31:45.462661+00	\N	\N
20dabe2c-52bb-4dd2-bf66-b3110ba5b50d	IMD-CC-2026-000314	2d970758-319c-400f-b2ba-93057f16a33e	eec7cc46-3395-4f21-8c7f-cb99bee58b55	c90f0faf-7282-4ab2-bd4b-428081c8bf08	70.00	{"user": "2d970758-319c-400f-b2ba-93057f16a33e", "score": 70, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	dc170caabf9750a5bc93047ba741b522e40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-04-04 18:31:45.462661+00	\N	\N
20db970c-9a19-4a13-85c2-a70a1c395d59	IMD-CC-2026-000315	48ae8c9d-e783-46c2-abf3-cc9d31e16d81	eec7cc46-3395-4f21-8c7f-cb99bee58b55	2c9a020a-98e5-41f9-989e-8baca397d70c	86.00	{"user": "48ae8c9d-e783-46c2-abf3-cc9d31e16d81", "score": 86, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	9f266ff376695aed4bf99c022d132108e40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-08-25 18:31:45.462661+00	\N	\N
d725a875-1f7a-4b47-89dc-43befd1a968d	IMD-CC-2026-000316	fc08ec35-be50-46ec-8acb-0ddb68b16b22	eec7cc46-3395-4f21-8c7f-cb99bee58b55	f2dd16c7-7057-4c8d-a3e0-2932115f3ec0	95.00	{"user": "fc08ec35-be50-46ec-8acb-0ddb68b16b22", "score": 95, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	87a92857b5adec272c6ae6dd59049eb7e40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-04-09 18:31:45.462661+00	\N	\N
5499b226-3ee3-4c23-a630-ecc8487f2604	IMD-CC-2026-000317	33f73596-75e6-435e-94f5-d5b111a6aaf5	eec7cc46-3395-4f21-8c7f-cb99bee58b55	de47e4cc-062d-4813-b9bf-67fef41b6c81	82.00	{"user": "33f73596-75e6-435e-94f5-d5b111a6aaf5", "score": 82, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	46d905d667c2718aa323a7bda848b06de40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-06-30 18:31:45.462661+00	\N	\N
8dc2a23a-0cc3-48fe-b7ff-a1526a325521	IMD-CC-2026-000318	3ecf9082-92fa-49e4-a15f-87acb5504803	eec7cc46-3395-4f21-8c7f-cb99bee58b55	f825cd09-ae68-4639-9f4b-302ef5ff49dc	67.00	{"user": "3ecf9082-92fa-49e4-a15f-87acb5504803", "score": 67, "course": "eec7cc46-3395-4f21-8c7f-cb99bee58b55"}	66062835183489e9340a820c323bdcb8e40c90cea1ed79cf9cf7ca2b58aa4306	demo-signature	\N	2026-06-03 18:31:45.462661+00	\N	\N
30b34e7c-94de-472b-bc87-fcd54bef2de3	IMD-CC-2026-000319	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	16ffe8b6-0ea5-4f14-9519-98b80a8a26b0	85.00	{"user": "5e2de4dd-f65c-43ae-9ab6-363fe303ab1e", "score": 85, "course": "a0fd8c4d-bcdd-4580-9968-fa32c45bac11"}	430892e2068b992c5cb0698737aadadc404c09d168c85b013b110cca897e5504	demo-signature	\N	2026-02-23 18:31:45.462661+00	\N	\N
de395d14-b0d2-4e8d-9404-323db2860911	IMD-CC-2026-000320	62868b88-e860-457b-8605-04153588489b	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	24bcf3bf-8458-475c-b4e9-23e1f98e6bf4	63.00	{"user": "62868b88-e860-457b-8605-04153588489b", "score": 63, "course": "a0fd8c4d-bcdd-4580-9968-fa32c45bac11"}	f06fcfcff0efac7385eecdcd7afb552b404c09d168c85b013b110cca897e5504	demo-signature	\N	2026-07-10 18:31:45.462661+00	\N	\N
7189a740-28a8-4e3c-8705-06ccee18c314	IMD-CC-2026-000321	77c70aa0-ddd9-4445-be30-4817de1cbfd0	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	88526893-179c-4dca-bf5a-b345e73c3c38	77.00	{"user": "77c70aa0-ddd9-4445-be30-4817de1cbfd0", "score": 77, "course": "a0fd8c4d-bcdd-4580-9968-fa32c45bac11"}	1519cf91afb4d9df7d5d0b64872e02d4404c09d168c85b013b110cca897e5504	demo-signature	\N	2026-08-21 18:31:45.462661+00	\N	\N
98468c86-717c-4c38-941a-dd64fc6b4609	IMD-CC-2026-000322	f04f9044-cd22-4a29-8d93-333047a95f6a	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	3e7b3fe7-e513-48c8-975f-3367bfea154e	68.00	{"user": "f04f9044-cd22-4a29-8d93-333047a95f6a", "score": 68, "course": "a0fd8c4d-bcdd-4580-9968-fa32c45bac11"}	441d16ef7a009e38c6f582d6a20c4d02404c09d168c85b013b110cca897e5504	demo-signature	\N	2026-06-18 18:31:45.462661+00	\N	\N
af54f03f-3c1e-4664-a390-5ee1d3c6ace0	IMD-CC-2026-000323	2af59a77-c993-46c3-a686-b91217814d48	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	fa40651d-314b-4103-8183-9b109c607dd5	84.00	{"user": "2af59a77-c993-46c3-a686-b91217814d48", "score": 84, "course": "a0fd8c4d-bcdd-4580-9968-fa32c45bac11"}	f0a39b8f46d470536e26c7a0be4b9c42404c09d168c85b013b110cca897e5504	demo-signature	\N	2026-05-27 18:31:45.462661+00	\N	\N
86a343ec-ec3f-4ecd-9e54-82a38063258d	IMD-CC-2026-000324	5abfd2bf-a622-4ac2-8867-2be6525ec0e8	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	9bc06dc4-9258-4b11-8187-f58eb3123c4d	70.00	{"user": "5abfd2bf-a622-4ac2-8867-2be6525ec0e8", "score": 70, "course": "a0fd8c4d-bcdd-4580-9968-fa32c45bac11"}	329ac105fc6eb3e3791fdef62760172a404c09d168c85b013b110cca897e5504	demo-signature	\N	2026-05-26 18:31:45.462661+00	\N	\N
13a7a6e8-6c62-418b-aa23-c39f1432511c	IMD-CC-2026-000325	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	6ed427dc-d145-4ffa-92ea-e17b462ac7c8	71.00	{"user": "b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e", "score": 71, "course": "a0fd8c4d-bcdd-4580-9968-fa32c45bac11"}	a2571fd963b89d56d77cba0b0a8f47d9404c09d168c85b013b110cca897e5504	demo-signature	\N	2026-02-21 18:31:45.462661+00	\N	\N
c6f4904f-8e05-44a2-92ed-5a0fdf48ab61	IMD-CC-2026-000326	3d87692f-06c1-4403-95ff-c70d1598700a	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	c6d592f3-75cc-40fd-bbd5-99a64a74e050	60.00	{"user": "3d87692f-06c1-4403-95ff-c70d1598700a", "score": 60, "course": "a0fd8c4d-bcdd-4580-9968-fa32c45bac11"}	cf27553fd3c2aed7ef1d03ece1c3b4f8404c09d168c85b013b110cca897e5504	demo-signature	\N	2026-03-31 18:31:45.462661+00	\N	\N
d82834f9-9874-4f0e-9243-d6ed795213ec	IMD-CC-2026-000327	1eb0cec9-a12f-4f42-9d77-bf6e343e9a75	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	d0ba9281-7c5f-4fca-84f5-0890e8e8c65c	74.00	{"user": "1eb0cec9-a12f-4f42-9d77-bf6e343e9a75", "score": 74, "course": "a0fd8c4d-bcdd-4580-9968-fa32c45bac11"}	c4340f215659b071ea13f2ef2244b66b404c09d168c85b013b110cca897e5504	demo-signature	\N	2026-08-25 18:31:45.462661+00	\N	\N
bfdfde6b-af0d-4618-9146-46615e5ca9ce	IMD-CC-2026-000328	0d37acee-70ea-4604-8bd7-c995941443fd	3d04c87e-b5ec-45e8-951e-4bb279977080	6f19b46c-8baf-4a00-8f92-dc11cd3f1693	67.00	{"user": "0d37acee-70ea-4604-8bd7-c995941443fd", "score": 67, "course": "3d04c87e-b5ec-45e8-951e-4bb279977080"}	6fae62134b86571d914785ff661e9ef02167150cf5cb5ac0130d0d7d94b52255	demo-signature	\N	2026-08-23 18:31:45.462661+00	\N	\N
34c38055-af7b-4dae-adae-59f8f957e742	IMD-CC-2026-000329	8b09383e-447b-4fa0-b605-8d8cf4f3f527	3d04c87e-b5ec-45e8-951e-4bb279977080	c1700524-cd5e-43a9-a720-5d7cab4345ba	65.00	{"user": "8b09383e-447b-4fa0-b605-8d8cf4f3f527", "score": 65, "course": "3d04c87e-b5ec-45e8-951e-4bb279977080"}	d0cd7afbad3ed608750d8d3186b992492167150cf5cb5ac0130d0d7d94b52255	demo-signature	\N	2026-03-23 18:31:45.462661+00	\N	\N
c0679041-0f78-4f20-a626-e0ef40c5a261	IMD-CC-2026-000330	b8541832-74c6-404f-90d0-5fb6d3df7663	3d04c87e-b5ec-45e8-951e-4bb279977080	e5b91786-5da9-4ecd-8c73-1515832eea2f	69.00	{"user": "b8541832-74c6-404f-90d0-5fb6d3df7663", "score": 69, "course": "3d04c87e-b5ec-45e8-951e-4bb279977080"}	59b4621fc33268bc7f041f96a492167a2167150cf5cb5ac0130d0d7d94b52255	demo-signature	\N	2026-02-27 18:31:45.462661+00	\N	\N
5e8c5152-06b4-42a0-bb4a-e85351639d31	IMD-CC-2026-000331	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	3d04c87e-b5ec-45e8-951e-4bb279977080	a221983f-9633-438a-a653-cb6bc775cf25	68.00	{"user": "b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e", "score": 68, "course": "3d04c87e-b5ec-45e8-951e-4bb279977080"}	3f75ad6fe9f675594c6854177e4dd2322167150cf5cb5ac0130d0d7d94b52255	demo-signature	\N	2026-06-15 18:31:45.462661+00	\N	\N
32269471-8518-4481-a486-ccd37cd984f2	IMD-CC-2026-000332	312e5b6a-024a-4a5d-9389-357b73426d42	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	5217b088-53ce-4328-a390-ea6e43fdb9ea	69.00	{"user": "312e5b6a-024a-4a5d-9389-357b73426d42", "score": 69, "course": "6ede44f5-cacb-4f50-9ed5-e6155ad64bb7"}	93f033f6a75defc310f827adcb7295469bd8214bbb73a4e32614fd11f90e3b7c	demo-signature	\N	2026-05-08 18:31:45.462661+00	\N	\N
31a7d1da-c158-4718-aa5c-642121454d1f	IMD-CC-2026-000333	ae420db9-d867-40d1-8d1a-01ee5d62e270	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	2bddba39-9c45-47d1-9da8-1055fa29bdc4	67.00	{"user": "ae420db9-d867-40d1-8d1a-01ee5d62e270", "score": 67, "course": "6ede44f5-cacb-4f50-9ed5-e6155ad64bb7"}	1ae716832a4fc8758771a0493906ab719bd8214bbb73a4e32614fd11f90e3b7c	demo-signature	\N	2026-04-17 18:31:45.462661+00	\N	\N
79e41e88-5b8b-4825-828c-604d1dccf347	IMD-CC-2026-000334	8ffbd0cf-b807-4193-af37-3a61482c76eb	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	78429dcc-f136-46b7-b0e0-0f244fef4381	66.00	{"user": "8ffbd0cf-b807-4193-af37-3a61482c76eb", "score": 66, "course": "6ede44f5-cacb-4f50-9ed5-e6155ad64bb7"}	e885759b8495262b3e9dafa05e95fa909bd8214bbb73a4e32614fd11f90e3b7c	demo-signature	\N	2026-07-22 18:31:45.462661+00	\N	\N
4118ad65-4b00-456a-90b6-a87ec03825bc	IMD-CC-2026-000335	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	314946f3-0bf8-48a0-84c9-05d3bf2f13fc	75.00	{"user": "b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e", "score": 75, "course": "6ede44f5-cacb-4f50-9ed5-e6155ad64bb7"}	6d18cd69c782f39e61f404c4d86c9db59bd8214bbb73a4e32614fd11f90e3b7c	demo-signature	\N	2026-07-30 18:31:45.462661+00	\N	\N
cb7230dd-2660-4d54-b518-7e342ec39b1f	IMD-CC-2026-000336	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	c2bea441-68d1-4c85-ab1c-48537dc1e1cd	60.00	{"user": "fc6668ea-582e-4fa2-a17f-eb264a39e1a2", "score": 60, "course": "6ede44f5-cacb-4f50-9ed5-e6155ad64bb7"}	321f581e613b22e59c5f0c3fa9a268769bd8214bbb73a4e32614fd11f90e3b7c	demo-signature	\N	2026-05-22 18:31:45.462661+00	\N	\N
a8fe5a37-ba37-4ae4-8c9e-dd123ca784ae	IMD-CC-2026-000337	8a1eab45-738c-41b6-b35d-7737f5e2f64e	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	81fd249a-87c0-48b9-b14d-a89824f0efa4	61.00	{"user": "8a1eab45-738c-41b6-b35d-7737f5e2f64e", "score": 61, "course": "6ede44f5-cacb-4f50-9ed5-e6155ad64bb7"}	901014cf7cc5ab24f05137e7f2a1746b9bd8214bbb73a4e32614fd11f90e3b7c	demo-signature	\N	2026-07-22 18:31:45.462661+00	\N	\N
93abc08a-3a9a-429b-829a-d9315ad02366	IMD-CC-2026-000338	a8c5b60b-8763-4325-900d-07d7540e6015	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	2819a9ec-294b-4639-be74-78d05bb99393	68.00	{"user": "a8c5b60b-8763-4325-900d-07d7540e6015", "score": 68, "course": "6ede44f5-cacb-4f50-9ed5-e6155ad64bb7"}	1c8dd74b6bc76c8be60de5177dd3776e9bd8214bbb73a4e32614fd11f90e3b7c	demo-signature	\N	2026-06-09 18:31:45.462661+00	\N	\N
7b94b19d-0bf6-4645-b0fc-320daca02cef	IMD-CC-2026-000339	48f33e15-f87f-4629-ab82-4123ada4bdc4	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	cdc828d2-7057-42fe-83ab-425a6891e321	64.00	{"user": "48f33e15-f87f-4629-ab82-4123ada4bdc4", "score": 64, "course": "6ede44f5-cacb-4f50-9ed5-e6155ad64bb7"}	fe8716cd8a5e50d20446cc97ca71f15b9bd8214bbb73a4e32614fd11f90e3b7c	demo-signature	\N	2026-05-31 18:31:45.462661+00	\N	\N
a3f6ddda-d4ac-456b-b4f3-0203e514c055	IMD-CC-2026-000340	fc08ec35-be50-46ec-8acb-0ddb68b16b22	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	91f676e6-ae6e-449c-8b8b-40984a37098f	71.00	{"user": "fc08ec35-be50-46ec-8acb-0ddb68b16b22", "score": 71, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	8a53b2b7a757ca77c8df4452346b78098eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-09-08 18:31:45.462661+00	\N	\N
e3c9ffdf-bbf4-4429-b06a-850eb2ce4ac5	IMD-CC-2026-000341	3ecf9082-92fa-49e4-a15f-87acb5504803	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	2b3ec1de-83d2-4148-85fb-5c3c811ef967	87.00	{"user": "3ecf9082-92fa-49e4-a15f-87acb5504803", "score": 87, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	0457325d19389eb72de4a204cbe6061a8eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-05-11 18:31:45.462661+00	\N	\N
fd59d6cb-bbe4-4431-9214-1553ab2136cc	IMD-CC-2026-000342	6a389990-e259-43a4-a9a2-7575b00029e0	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	347321fc-8404-4632-ad7e-dcbd8df1117c	74.00	{"user": "6a389990-e259-43a4-a9a2-7575b00029e0", "score": 74, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	30005c95668537df627df0ffc666ee438eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-06-21 18:31:45.462661+00	\N	\N
39f9a111-92e2-4758-b879-13650c22200f	IMD-CC-2026-000343	e888ad9f-c064-4d24-8143-eec67fac7c1c	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	fdf9893c-2ec1-4c95-b464-8cea499be6f8	74.00	{"user": "e888ad9f-c064-4d24-8143-eec67fac7c1c", "score": 74, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	33ce6217463ff90f77110aeb90f92b8c8eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-05-18 18:31:45.462661+00	\N	\N
5b507d10-bed9-4c78-ac62-682c4d4fedef	IMD-CC-2026-000344	eee6bbaa-75eb-44f4-9892-d46194b720a9	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	10d5efd5-cdb0-44dd-896c-73bb0b51d6cc	68.00	{"user": "eee6bbaa-75eb-44f4-9892-d46194b720a9", "score": 68, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	a4cdfe051496760a2c3c1869edc4426e8eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-08-12 18:31:45.462661+00	\N	\N
2ad6bdaa-7aa2-4ed7-8307-dd92baa7adb8	IMD-CC-2026-000345	306af47d-26b6-4dc3-96ae-eb178609c1f6	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	c7bcf2a1-a2b3-4a03-95ca-1e593d29979f	75.00	{"user": "306af47d-26b6-4dc3-96ae-eb178609c1f6", "score": 75, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	63bf6a1a01cb143402104973e1f6a8cb8eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-03-21 18:31:45.462661+00	\N	\N
a555ccb0-bd6c-4beb-8932-b8780dd4c125	IMD-CC-2026-000346	a8c5b60b-8763-4325-900d-07d7540e6015	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	b87e1981-d235-4352-a09e-d11faa69e86f	67.00	{"user": "a8c5b60b-8763-4325-900d-07d7540e6015", "score": 67, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	f40db05d6eebe1614313157a91d750d98eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-09-15 18:31:45.462661+00	\N	\N
b56e668e-4492-4112-a13b-44a54a1d97f7	IMD-CC-2026-000347	24cbfa5b-7114-43b8-957c-fe0efa420c25	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	c8c109eb-4fc8-4b22-a47b-91f827cd0936	64.00	{"user": "24cbfa5b-7114-43b8-957c-fe0efa420c25", "score": 64, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	e0949d282d891c5ade66dc692b477b278eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-06-13 18:31:45.462661+00	\N	\N
ca794a42-4836-475e-b5dc-3dc68892ab60	IMD-CC-2026-000348	15a2f413-02d0-4624-9468-3a8bec2ba6b8	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	eeca6cb2-a951-40c6-a0f8-5c1de73ce290	76.00	{"user": "15a2f413-02d0-4624-9468-3a8bec2ba6b8", "score": 76, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	ce3ac9985aa7d7f2f9c06fc99c66df008eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-04-07 18:31:45.462661+00	\N	\N
f65d2cb3-4caf-45e4-8542-32872cb83ab1	IMD-CC-2026-000349	696886f6-a4bf-44a6-9ba9-c939abb52137	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	85eef87c-8d33-4ffb-991f-42c9bb403c31	78.00	{"user": "696886f6-a4bf-44a6-9ba9-c939abb52137", "score": 78, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	1893ffccff8a001a36ec37727bd74a468eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-07-19 18:31:45.462661+00	\N	\N
888f2e67-9a99-4e3e-a30a-8fcd47681461	IMD-CC-2026-000350	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	ab189809-0278-4fb1-a186-013f84ea9102	66.00	{"user": "fc6668ea-582e-4fa2-a17f-eb264a39e1a2", "score": 66, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	ab286cffbe87b0e21c519ca953c20ebc8eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-09-22 18:31:45.462661+00	\N	\N
48263a88-e31d-4914-8712-20ed05d3cfb8	IMD-CC-2026-000351	9897dc81-824b-4829-9fda-76c3f3c3e38f	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	7cad7659-c86f-4deb-9fc5-f4f943891c3a	71.00	{"user": "9897dc81-824b-4829-9fda-76c3f3c3e38f", "score": 71, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	7b7cce34542a1cc21d0037da94df4b5c8eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-03-21 18:31:45.462661+00	\N	\N
830ea368-39f2-4e92-aa02-a605dbf0e635	IMD-CC-2026-000352	fed72080-2568-4892-8047-0b3c72ff7fad	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	9c7efcb6-0e31-4447-97f0-e793b888e169	62.00	{"user": "fed72080-2568-4892-8047-0b3c72ff7fad", "score": 62, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	6c3daab437641102d19e3f8ab79e439f8eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-03-05 18:31:45.462661+00	\N	\N
0aa84acd-6756-49c5-9857-57fc2b2ab64d	IMD-CC-2026-000353	7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	2a641087-efee-4aee-a034-d20f6150212e	69.00	{"user": "7d98c1dd-e2b5-4fb6-aa2a-68849c41f058", "score": 69, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	69f05ce5e34ab218178081abff6892968eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-09-09 18:31:45.462661+00	\N	\N
79002edc-3123-4150-97ac-74d9159138f8	IMD-CC-2026-000354	bea31be8-3a44-4869-9c56-dce2da936f51	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	55ea2b14-f36c-4628-87b0-e14b4f227f10	85.00	{"user": "bea31be8-3a44-4869-9c56-dce2da936f51", "score": 85, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	32a24a0f4399836d8f188e0228ab941d8eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-05-19 18:31:45.462661+00	\N	\N
04394ef1-96a7-40f6-91bf-0a5090eac1d5	IMD-CC-2026-000355	3af00a36-1f7b-4846-a52a-b1871416c5b1	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	f1c29bf2-fea1-4d89-bee4-4d92c9582167	74.00	{"user": "3af00a36-1f7b-4846-a52a-b1871416c5b1", "score": 74, "course": "b31c1fd4-c6e0-435e-888f-8aee7e684fb6"}	613f8c5509ecd7f23660026d9d69c8da8eae719142e4742b644bc2117ec35bfc	demo-signature	\N	2026-07-27 18:31:45.462661+00	\N	\N
\.


--
-- Data for Name: course_resources; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.course_resources (course_id, resource_id, module_title, "position", is_mandatory) FROM stdin;
55a4d643-f01f-4d75-8109-ff60798f1e9b	b9318e74-17b4-4cd5-9f62-9cec1e2c574e	Module 1	1	t
55a4d643-f01f-4d75-8109-ff60798f1e9b	04411396-da62-4fe6-9753-e8ab0f80d68e	Module 2	2	t
9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	8f5ddc1b-23a9-4c76-a322-718d2bc559ab	Module 1	1	t
9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	b4670946-a115-49d8-9950-1e73c9a2b967	Module 2	2	t
ad72951b-6768-4887-8063-287ff8f51bf1	8ca76a5a-c0d4-4c35-b5a3-acd01b146f14	Module 1	1	t
ad72951b-6768-4887-8063-287ff8f51bf1	6c9b1523-7070-44d5-95e0-b96a8c6eff10	Module 2	2	t
5317862f-92fe-4e22-ae0a-a244abce364c	266ad7f5-acda-4bd7-aeca-38b9ae346e16	Module 1	1	t
5317862f-92fe-4e22-ae0a-a244abce364c	11c8ac3d-eb64-4145-981c-1b4c2340e38e	Module 2	2	t
32ab414d-cb9f-48ed-b3b5-97537b736196	12cef298-79fc-4d3a-a71a-55679636dbfd	Module 1	1	t
32ab414d-cb9f-48ed-b3b5-97537b736196	9ebf48f2-d169-4adf-bbe7-27a1281ed2fc	Module 2	2	t
19b09698-d481-4bdf-95c3-6dd7b1aa8afa	bf4a94dc-e220-4410-b069-860e73ee3abd	Module 1	1	t
19b09698-d481-4bdf-95c3-6dd7b1aa8afa	b2a7f555-e7a1-4931-bbf4-00dd8f21d884	Module 2	2	t
33add9da-29ab-4a45-90b2-f5b8f4723f3d	a523890b-7cd6-4c01-bb94-3dd64b46965f	Module 1	1	t
33add9da-29ab-4a45-90b2-f5b8f4723f3d	8cbbd15f-62cd-4b0a-beec-fbe1a40792b9	Module 2	2	t
8db3d256-cbbd-4863-b45a-d035bffdba03	970cafb0-3fa8-4de6-93ac-8c796f293508	Module 1	1	t
8db3d256-cbbd-4863-b45a-d035bffdba03	528e9d28-b772-4bb4-b148-104a940d50dc	Module 2	2	t
c4985880-e557-407c-8f90-5c1f5b564695	63c74bba-3732-48a4-8a27-64a586612470	Module 1	1	t
c4985880-e557-407c-8f90-5c1f5b564695	266397d0-4346-4f2a-a21e-0c1a7192e62e	Module 2	2	t
0724a689-d500-4969-b7fb-72e37232b31f	9c8840fb-31fa-4ab8-81d0-9fae24516545	Module 1	1	t
0724a689-d500-4969-b7fb-72e37232b31f	222cc68e-b6df-40ab-a659-4fdb20e5850a	Module 2	2	t
ce43f7f3-92cb-4d62-b40a-149bdd13b745	065361df-8e29-4131-a842-778f2c87f10d	Module 1	1	t
ce43f7f3-92cb-4d62-b40a-149bdd13b745	aeeb0db5-fe2a-41e2-89fe-337adee17a60	Module 2	2	t
97b1727b-e525-4ee5-b01f-28b15a8101b5	d92e1b18-30c5-4b72-8e04-229e87f882b6	Module 1	1	t
97b1727b-e525-4ee5-b01f-28b15a8101b5	e1f2e85d-ab0d-47dc-9c3e-860ca43231ce	Module 2	2	t
e930bc9e-26fc-4a34-89bc-012457df980e	e18148dd-a97d-489b-8873-6f8e67ad3278	Module 1	1	t
e930bc9e-26fc-4a34-89bc-012457df980e	ba90bdd4-e63d-4ce3-a14c-7a159d7927a6	Module 2	2	t
290cedcf-37a4-4271-ae6c-2172115f0acb	696449d2-e675-4e3a-8ae0-5e1942fe40f3	Module 1	1	t
290cedcf-37a4-4271-ae6c-2172115f0acb	22a1ecbe-c779-416d-960c-18a138fd3d8b	Module 2	2	t
57e0bcdd-75f2-4ba6-b987-befe07d147c8	eb2b07e3-64da-44ec-aaf4-71b77be14021	Module 1	1	t
57e0bcdd-75f2-4ba6-b987-befe07d147c8	190ed27d-6847-4411-a680-7b42de447332	Module 2	2	t
42f00c79-df57-400e-a313-a585d6a36404	12edd791-13fa-4e39-8379-e876a8a51171	Module 1	1	t
42f00c79-df57-400e-a313-a585d6a36404	24ab3f59-41ec-4d42-80f6-52c9aed376d3	Module 2	2	t
486ae347-6271-439f-9865-ebaf1e4d93cd	f62ccb37-27fd-49ba-86b3-0fbc9f46f8a9	Module 1	1	t
486ae347-6271-439f-9865-ebaf1e4d93cd	59e7d935-17c4-43fc-b274-8624a339adfb	Module 2	2	t
377c54d8-88d8-4698-a98c-27a42d2dae92	33a53d0b-4f4a-4899-913e-a9cf8209a2a1	Module 1	1	t
377c54d8-88d8-4698-a98c-27a42d2dae92	1c3c3009-d638-48f9-ba7c-1f2fd737e9dc	Module 2	2	t
1b09caa2-5a18-4f05-9a17-18d849ee499f	5c666d46-e9ff-4b3c-bc2f-d477a8b2941f	Module 1	1	t
1b09caa2-5a18-4f05-9a17-18d849ee499f	a863dc9a-2924-4568-90f7-492c15cec216	Module 2	2	t
614b89b9-ad9a-4481-9970-4691dd4e45dc	5b82eaf6-650c-425d-993e-b62f6150d543	Module 1	1	t
614b89b9-ad9a-4481-9970-4691dd4e45dc	c8706732-af64-4787-8ee4-aaa42b352a66	Module 2	2	t
6be0b4cc-255a-4372-be78-8bd23dee561b	a2df678d-7aa0-4d97-a85c-b85dd54225c6	Module 1	1	t
6be0b4cc-255a-4372-be78-8bd23dee561b	dae3326e-bddb-4f59-9a2d-5e37dc1eb95a	Module 2	2	t
eec7cc46-3395-4f21-8c7f-cb99bee58b55	6684bc27-7ee6-431a-bbce-0b43da4e4cfb	Module 1	1	t
eec7cc46-3395-4f21-8c7f-cb99bee58b55	17d2bd3a-902b-434b-b82e-700fc08561b0	Module 2	2	t
a0fd8c4d-bcdd-4580-9968-fa32c45bac11	490663ce-ffc2-4ca0-83e8-e5d317d52260	Module 1	1	t
a0fd8c4d-bcdd-4580-9968-fa32c45bac11	b239ce57-38ba-4980-84b8-77663070f329	Module 2	2	t
3d04c87e-b5ec-45e8-951e-4bb279977080	e4ded3e1-1c93-4a2f-a63c-c48712f322ff	Module 1	1	t
3d04c87e-b5ec-45e8-951e-4bb279977080	cb2c0c39-bed3-434a-82a8-89657a422d8e	Module 2	2	t
6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	d4c23cf9-a29d-48f9-9f97-f6a502db63dc	Module 1	1	t
6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	dcfd66c3-a0d5-4f1e-9b32-831f72c13fc8	Module 2	2	t
b31c1fd4-c6e0-435e-888f-8aee7e684fb6	f00ff310-7daf-477b-8b9f-839b3d022e57	Module 1	1	t
b31c1fd4-c6e0-435e-888f-8aee7e684fb6	07598617-736b-49cd-8177-aca103292d24	Module 2	2	t
\.


--
-- Data for Name: courses; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.courses (id, code, title, summary, skill_id, tags, level, duration_hours, trainer_id, thumbnail_file_id, status, pass_criteria_pct, issues_certificate, created_by, published_at, created_at, updated_at) FROM stdin;
55a4d643-f01f-4d75-8109-ff60798f1e9b	IMD-NOWC-101	Nowcasting: Operational Practice	Hands-on training on Nowcasting for IMD operational staff.	9	{nowcast,nowcasting,short-range,convective}	intermediate	10.0	2e42c806-48d6-422a-b282-2b30f0484c3c	\N	published	60	t	2e42c806-48d6-422a-b282-2b30f0484c3c	2026-01-30 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	IMD-NWP-102	NWP Modelling: Advanced Techniques	Hands-on training on NWP Modelling for IMD operational staff.	8	{nwp,wrf,gfs,"numerical weather",ensemble,"data assimilation"}	advanced	14.0	ff73e90e-1654-4bfd-8c73-43ad75a07f21	\N	published	60	t	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2026-01-31 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
ad72951b-6768-4887-8063-287ff8f51bf1	IMD-AWS-103	Automatic Weather Stations: Fundamentals	Hands-on training on Automatic Weather Stations for IMD operational staff.	11	{aws,"automatic weather station","surface observation"}	beginner	18.0	ff73e90e-1654-4bfd-8c73-43ad75a07f21	\N	published	60	t	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2026-02-01 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
5317862f-92fe-4e22-ae0a-a244abce364c	IMD-TROP-104	Tropical Cyclone Forecasting: Operational Practice	Hands-on training on Tropical Cyclone Forecasting for IMD operational staff.	7	{cyclone,"tropical cyclone","storm surge",track}	intermediate	22.0	ff38df49-9e3b-4df5-92a2-4852f8b79c74	\N	published	60	t	ff38df49-9e3b-4df5-92a2-4852f8b79c74	2026-02-02 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
32ab414d-cb9f-48ed-b3b5-97537b736196	IMD-MONS-105	Monsoon Forecasting: Advanced Techniques	Hands-on training on Monsoon Forecasting for IMD operational staff.	6	{monsoon,rainfall,"southwest monsoon",onset}	advanced	6.0	2ae7d31a-ec05-402a-8104-ba433a1644eb	\N	published	60	t	2ae7d31a-ec05-402a-8104-ba433a1644eb	2026-02-03 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
19b09698-d481-4bdf-95c3-6dd7b1aa8afa	IMD-DWR-106	Doppler Weather Radar: Fundamentals	Hands-on training on Doppler Weather Radar for IMD operational staff.	13	{radar,doppler,dwr,reflectivity}	beginner	10.0	5db62bba-e3f6-4551-81f7-9d9237055aa3	\N	published	60	t	5db62bba-e3f6-4551-81f7-9d9237055aa3	2026-02-04 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
33add9da-29ab-4a45-90b2-f5b8f4723f3d	IMD-SATE-107	Satellite Meteorology: Operational Practice	Hands-on training on Satellite Meteorology for IMD operational staff.	12	{satellite,insat,"remote sensing",imagery}	intermediate	14.0	9894043b-3b29-45e0-9abd-9b61597bf09a	\N	published	60	t	9894043b-3b29-45e0-9abd-9b61597bf09a	2026-02-05 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
8db3d256-cbbd-4863-b45a-d035bffdba03	IMD-AWS-108	Automatic Weather Stations: Advanced Techniques	Hands-on training on Automatic Weather Stations for IMD operational staff.	11	{aws,"automatic weather station","surface observation"}	advanced	18.0	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	\N	published	60	t	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2026-02-06 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
c4985880-e557-407c-8f90-5c1f5b564695	IMD-THUN-109	Thunderstorm & Lightning: Fundamentals	Hands-on training on Thunderstorm & Lightning for IMD operational staff.	16	{thunderstorm,lightning,squall,hail}	beginner	22.0	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	\N	published	60	t	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2026-02-07 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
0724a689-d500-4969-b7fb-72e37232b31f	IMD-CLIM-110	Climate Data Analysis: Operational Practice	Hands-on training on Climate Data Analysis for IMD operational staff.	15	{"climate data",trend,reanalysis,era5}	intermediate	6.0	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	\N	published	60	t	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	2026-02-08 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
ce43f7f3-92cb-4d62-b40a-149bdd13b745	IMD-AGRO-111	Agromet Advisory: Advanced Techniques	Hands-on training on Agromet Advisory for IMD operational staff.	14	{agromet,agriculture,crop,advisory}	advanced	10.0	954754ab-6ecc-4d9a-a614-8cc84ffb3348	\N	published	60	t	954754ab-6ecc-4d9a-a614-8cc84ffb3348	2026-02-09 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
97b1727b-e525-4ee5-b01f-28b15a8101b5	IMD-NWP-112	NWP Modelling: Fundamentals	Hands-on training on NWP Modelling for IMD operational staff.	8	{nwp,wrf,gfs,"numerical weather",ensemble,"data assimilation"}	beginner	14.0	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	\N	published	60	t	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2026-02-10 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
e930bc9e-26fc-4a34-89bc-012457df980e	IMD-FLOO-113	Flood Meteorology: Operational Practice	Hands-on training on Flood Meteorology for IMD operational staff.	18	{flood,hydrology,qpf,river}	intermediate	18.0	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	\N	published	60	t	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2026-02-11 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
290cedcf-37a4-4271-ae6c-2172115f0acb	IMD-HEAT-114	Heatwave & Cold Wave: Advanced Techniques	Hands-on training on Heatwave & Cold Wave for IMD operational staff.	17	{heatwave,"heat wave","cold wave",temperature}	advanced	22.0	e9178b69-2339-4a64-857f-5ad0630325a5	\N	published	60	t	e9178b69-2339-4a64-857f-5ad0630325a5	2026-02-12 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
57e0bcdd-75f2-4ba6-b987-befe07d147c8	IMD-THUN-115	Thunderstorm & Lightning: Fundamentals	Hands-on training on Thunderstorm & Lightning for IMD operational staff.	16	{thunderstorm,lightning,squall,hail}	beginner	6.0	82556fbd-47bf-44ac-aae9-3499c844ea75	\N	published	60	t	82556fbd-47bf-44ac-aae9-3499c844ea75	2026-02-13 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
42f00c79-df57-400e-a313-a585d6a36404	IMD-PYTH-116	Python for Meteorology: Operational Practice	Hands-on training on Python for Meteorology for IMD operational staff.	20	{python,xarray,metpy,netcdf}	intermediate	10.0	fa5ba122-30c1-4e56-bc6b-b761794b1528	\N	published	60	t	fa5ba122-30c1-4e56-bc6b-b761794b1528	2026-02-14 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
486ae347-6271-439f-9865-ebaf1e4d93cd	IMD-NOWC-117	Nowcasting: Advanced Techniques	Hands-on training on Nowcasting for IMD operational staff.	9	{nowcast,nowcasting,short-range,convective}	advanced	14.0	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	\N	published	60	t	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2026-02-15 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
377c54d8-88d8-4698-a98c-27a42d2dae92	IMD-SATE-118	Satellite Meteorology: Fundamentals	Hands-on training on Satellite Meteorology for IMD operational staff.	12	{satellite,insat,"remote sensing",imagery}	beginner	18.0	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	\N	published	60	t	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2026-02-16 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
1b09caa2-5a18-4f05-9a17-18d849ee499f	IMD-NWP-119	NWP Modelling: Operational Practice	Hands-on training on NWP Modelling for IMD operational staff.	8	{nwp,wrf,gfs,"numerical weather",ensemble,"data assimilation"}	intermediate	22.0	dab8c835-d264-43fb-9b10-7482bacf6b99	\N	published	60	t	dab8c835-d264-43fb-9b10-7482bacf6b99	2026-02-17 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
614b89b9-ad9a-4481-9970-4691dd4e45dc	IMD-TROP-120	Tropical Cyclone Forecasting: Advanced Techniques	Hands-on training on Tropical Cyclone Forecasting for IMD operational staff.	7	{cyclone,"tropical cyclone","storm surge",track}	advanced	6.0	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	\N	published	60	t	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2026-02-18 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
6be0b4cc-255a-4372-be78-8bd23dee561b	IMD-CLIM-121	Climate Data Analysis: Fundamentals	Hands-on training on Climate Data Analysis for IMD operational staff.	15	{"climate data",trend,reanalysis,era5}	beginner	10.0	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	\N	published	60	t	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2026-02-19 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
eec7cc46-3395-4f21-8c7f-cb99bee58b55	IMD-MONS-122	Monsoon Forecasting: Operational Practice	Hands-on training on Monsoon Forecasting for IMD operational staff.	6	{monsoon,rainfall,"southwest monsoon",onset}	intermediate	14.0	d6196926-78e5-4750-9dda-c802473b00e2	\N	published	60	t	d6196926-78e5-4750-9dda-c802473b00e2	2026-02-20 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
a0fd8c4d-bcdd-4580-9968-fa32c45bac11	IMD-DWR-123	Doppler Weather Radar: Advanced Techniques	Hands-on training on Doppler Weather Radar for IMD operational staff.	13	{radar,doppler,dwr,reflectivity}	advanced	18.0	66a88386-7c29-44ae-805a-fd51d782743b	\N	published	60	t	66a88386-7c29-44ae-805a-fd51d782743b	2026-02-21 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
3d04c87e-b5ec-45e8-951e-4bb279977080	IMD-FLOO-124	Flood Meteorology: Fundamentals	Hands-on training on Flood Meteorology for IMD operational staff.	18	{flood,hydrology,qpf,river}	beginner	22.0	66a88386-7c29-44ae-805a-fd51d782743b	\N	published	60	t	66a88386-7c29-44ae-805a-fd51d782743b	2026-02-22 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	IMD-SATE-125	Satellite Meteorology: Operational Practice	Hands-on training on Satellite Meteorology for IMD operational staff.	12	{satellite,insat,"remote sensing",imagery}	intermediate	6.0	49992467-6281-4454-9a23-aa2dd4c74a95	\N	published	60	t	49992467-6281-4454-9a23-aa2dd4c74a95	2026-02-23 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
b31c1fd4-c6e0-435e-888f-8aee7e684fb6	IMD-HEAT-126	Heatwave & Cold Wave: Advanced Techniques	Hands-on training on Heatwave & Cold Wave for IMD operational staff.	17	{heatwave,"heat wave","cold wave",temperature}	advanced	10.0	49992467-6281-4454-9a23-aa2dd4c74a95	\N	published	60	t	49992467-6281-4454-9a23-aa2dd4c74a95	2026-02-24 18:31:45.462661+00	2026-01-19 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
\.


--
-- Data for Name: enrollments; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.enrollments (id, user_id, course_id, status, completed_resource_ids, progress_pct, enrolled_at, completed_at, last_activity_at) FROM stdin;
f04d2d43-ca90-406b-92dd-6eef6d08344b	15a2f413-02d0-4624-9468-3a8bec2ba6b8	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	76.00	2026-05-25 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
79809167-07fb-4c23-a9ab-b1a1dda598aa	3ded69a7-290c-47f6-bd29-7369f6f8e3c8	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	61.00	2026-05-31 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
04142b06-059b-4ac6-a51c-7b51ca53c31b	30e16278-0ca1-4efa-a03b-7168658bb2c2	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	85.00	2026-07-14 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
936d9e4a-f9e6-4b47-91fa-5777e5db3940	edc1993b-5333-4d99-bae2-9e80266978e0	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	69.00	2026-02-16 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
85f189e2-2e8f-4496-9c43-d35aab894b71	2af59a77-c993-46c3-a686-b91217814d48	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	46.00	2026-08-25 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
44585733-9ec6-4ed6-b2bd-b24601c4f314	7e426fed-4c2e-46f4-866a-7b8aa048cf06	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	98.00	2026-07-10 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
d6de7c87-a343-4527-b850-9656f8ba7823	b8541832-74c6-404f-90d0-5fb6d3df7663	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	74.00	2026-09-06 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
a6209498-4628-465b-a800-8886f48ff19f	3ed88e99-cb0d-423f-ae37-92b93c67d881	55a4d643-f01f-4d75-8109-ff60798f1e9b	completed	{}	100.00	2026-07-29 18:31:45.462661+00	2026-08-04 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
37d22aa2-7592-4466-99a5-f56095a43b9b	fda17094-1c9f-45de-a42c-aa815d09bc2a	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	82.00	2026-08-18 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
f9878de0-d927-492d-a0fa-c74aaa34c01b	5d9905c7-91e8-4bd9-b187-b1b8772e0f63	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	99.00	2026-03-16 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
26586d96-c5b1-442d-948e-163c2d213851	fba30b27-7555-43f7-8c74-b84e722ebbc8	55a4d643-f01f-4d75-8109-ff60798f1e9b	completed	{}	100.00	2026-07-07 18:31:45.462661+00	2026-07-13 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
e39d27b7-5c43-4e5f-906d-51153d0eb3ef	732e74cf-b9b7-4adc-a43a-794430d7fe49	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	80.00	2026-03-20 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
b5725db8-1a1e-4e66-aab2-e9a07a3f8602	9e08ecc2-e291-4516-bae3-07b43abc2620	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	55.00	2026-04-16 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
767a20ce-99df-4ea1-a2d9-4b64c28cf05a	a5102b13-4107-4fe5-b7a0-064dd07042ee	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	43.00	2026-05-08 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
781657d2-cb7c-4068-86a7-afbfb172241a	df216767-1cda-46b6-874f-845e41051203	55a4d643-f01f-4d75-8109-ff60798f1e9b	completed	{}	100.00	2026-04-12 18:31:45.462661+00	2026-04-18 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
6dab46ab-089a-4013-b4cd-6f625c8d0acd	6b116d7e-84ed-47de-81ea-2bd42ea50968	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	61.00	2026-07-28 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
268af7cc-6b2a-4027-8df4-f39dde313bc9	b28e0245-9390-4127-ad3f-80ace4775f43	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	67.00	2026-05-07 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
d72acce5-ab9c-4524-8413-134110e727eb	72a5ceb8-6b68-433d-9b99-d62b8c9f1375	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	85.00	2026-02-27 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
7ac1e7d1-af04-4cae-8b92-2c394526c7a4	6f9f3af8-fa88-4804-aa9b-5680afa4c1ba	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	73.00	2026-04-25 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
ec9ac05c-bd78-44d0-ab8d-5043f2ae5bbc	4135122d-a240-499c-8de4-3db650d7acc9	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	88.00	2026-06-18 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
cd4f0999-87d5-4c0e-a46f-377f35907b1b	d22f23cf-8a58-499a-8dba-92806f1622ef	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	78.00	2026-07-16 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
a1fc4a40-5213-4707-8dae-4625c3438a2b	a6afe850-9547-4fac-892c-00558ad8f725	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	74.00	2026-05-02 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
c2ab50a2-1adb-46cb-8615-9a1795cf0e16	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	81.00	2026-02-21 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
1302808f-504c-44da-a045-33eff3164ab2	5af34829-4d6f-425c-9f78-525896ea0526	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	83.00	2026-04-23 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
1e4641cb-f4b3-49a8-93d5-cfed6109d544	d072273b-7a6f-4fa4-9195-1697050cfab1	55a4d643-f01f-4d75-8109-ff60798f1e9b	completed	{}	100.00	2026-02-26 18:31:45.462661+00	2026-03-04 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
81fd0824-a795-415d-b9c8-67bfd451b213	65ef229b-117d-4946-b5bb-301e3f828fc2	55a4d643-f01f-4d75-8109-ff60798f1e9b	in_progress	{}	54.00	2026-04-03 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
c7f556f5-6abd-4092-90eb-f6ae89f42de2	6f9f3af8-fa88-4804-aa9b-5680afa4c1ba	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-05-28 18:31:45.462661+00	2026-06-03 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
d7c04a9b-a449-43d0-9c08-a36ec60a7144	cf4749a6-6127-4d97-b2a0-17a11eabc216	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-09-07 18:31:45.462661+00	2026-09-13 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
1e3f3386-b0e7-49bc-a95d-0e822f6caa56	a5fd318c-feeb-4b1b-b739-3e40a59dde18	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-06-27 18:31:45.462661+00	2026-07-03 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
2a0dfd86-ac6d-4c14-960a-f90d145f4c08	72a14ee8-79a9-41a0-8fb1-ac0dfac5bfa2	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-04-17 18:31:45.462661+00	2026-04-23 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
408e08e2-5535-4da7-81c2-ab36fb887a7a	625944b1-2b9b-433b-9af5-e72894aa7a58	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-06-04 18:31:45.462661+00	2026-06-10 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
826d37c2-4a74-45cc-a34b-96b6c2bcad30	fda17094-1c9f-45de-a42c-aa815d09bc2a	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-04-20 18:31:45.462661+00	2026-04-26 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
3c290ad2-53da-4e2a-8d4f-ec332b6f876a	293f638f-6b5e-4c5a-9282-533cc1c97688	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	in_progress	{}	63.00	2026-08-09 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
8cd6c3d1-9163-4826-b41d-cbdcb46c1184	4ace2ecd-317e-494c-ad50-71e2794fb907	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	in_progress	{}	88.00	2026-07-16 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
d6d72580-4a35-4dff-87b0-b06319b5d503	9897dc81-824b-4829-9fda-76c3f3c3e38f	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-04-22 18:31:45.462661+00	2026-04-28 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
e8ab45c4-c63d-4e98-a3cd-e6a9dac68f50	30e16278-0ca1-4efa-a03b-7168658bb2c2	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-04-14 18:31:45.462661+00	2026-04-20 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
6f511495-95c1-4a7b-b444-bfb89bfc8797	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-08-11 18:31:45.462661+00	2026-08-17 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
da27530e-8235-4da0-97db-33b0c47569b7	a6afe850-9547-4fac-892c-00558ad8f725	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-05-08 18:31:45.462661+00	2026-05-14 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
cdb4c117-8d2d-475e-9ce6-8d5d3cc8c7b8	b28e0245-9390-4127-ad3f-80ace4775f43	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-05-25 18:31:45.462661+00	2026-05-31 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
99e4914a-c038-4bee-b8f9-1b54f9701738	a5e41a1c-9682-4873-8924-f11edf9b3fce	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-08-06 18:31:45.462661+00	2026-08-12 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
6402aa89-e202-4bd6-9cdc-713498d525d0	202e1651-21c8-45c8-80d1-f326b27aec05	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	in_progress	{}	82.00	2026-03-30 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
5cc64737-02d3-4ee8-ab4b-903894c600af	306af47d-26b6-4dc3-96ae-eb178609c1f6	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	in_progress	{}	66.00	2026-09-05 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
6cf3fac4-3c32-4530-895a-084d25e75952	2994671f-607f-4cdc-a2bc-22ab97456b28	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-04-30 18:31:45.462661+00	2026-05-06 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
4a800eb8-3cf0-4dc1-97fd-fbfada99a955	b8541832-74c6-404f-90d0-5fb6d3df7663	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-08-27 18:31:45.462661+00	2026-09-02 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
7cb99338-ce74-47db-9555-bc53b3655a38	24cbfa5b-7114-43b8-957c-fe0efa420c25	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-06-30 18:31:45.462661+00	2026-07-06 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
9102c79a-44ba-48a6-893f-b72eb8230f0d	8b09383e-447b-4fa0-b605-8d8cf4f3f527	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-05-26 18:31:45.462661+00	2026-06-01 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
99851dd0-743e-4310-9e46-ab867ef61f0e	a8c5b60b-8763-4325-900d-07d7540e6015	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	in_progress	{}	47.00	2026-08-08 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
24a03e87-5231-417c-ae3c-e92e2a934615	a7bae3c0-0e2c-42db-8e35-79114d5dfe80	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-03-03 18:31:45.462661+00	2026-03-09 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
53a0a260-1b29-47e9-aa9a-b68b7d5155ab	09cc88c9-6251-413b-9873-df6f5bb8b24d	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-03-14 18:31:45.462661+00	2026-03-20 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
60b045fc-8fd9-484e-8fcb-0f4fe80d4e2d	c43722c6-7e70-49e0-acb4-ba4f953e36a8	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-05-30 18:31:45.462661+00	2026-06-05 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
e5047c3c-4fa5-44e6-947c-4513ca9d6f46	5a97c9d9-87c7-445c-9dc8-860fb29edb16	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-05-14 18:31:45.462661+00	2026-05-20 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
d4f15fa2-b184-490e-af5e-76e42340445d	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-04-24 18:31:45.462661+00	2026-04-30 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
947e4aaf-edad-444f-816e-74e5169a2490	b875f05c-64bb-41c8-b501-04ef26d03cb3	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-07-18 18:31:45.462661+00	2026-07-24 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
3fbb55b2-688e-4d84-9f9b-d83740123583	78313b75-0494-43a4-b199-ff1928254f44	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	completed	{}	100.00	2026-04-09 18:31:45.462661+00	2026-04-15 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
e9baa575-f423-4a4c-b929-fcc9edaebe85	2af59a77-c993-46c3-a686-b91217814d48	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	84.00	2026-04-16 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
15bb13e5-4551-44d1-832e-074404d809a4	1f511b5e-1292-4202-860e-b54f11eda21e	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	72.00	2026-03-31 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
81282dc6-cf4b-4ed3-af91-a149cfb4b7af	18407190-2219-4190-9b20-ee775b0094ef	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	51.00	2026-09-04 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
69e00543-2f5f-4b57-8849-6ccc2357ae4e	7acc259e-1231-481b-ab79-59821fd46534	ad72951b-6768-4887-8063-287ff8f51bf1	completed	{}	100.00	2026-04-10 18:31:45.462661+00	2026-04-16 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
c345b75b-444b-40b1-a162-52195e797a6c	2c310487-b2d2-4f8a-bdc3-0fcd75eff4a9	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	52.00	2026-03-16 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
a1abd333-f3f5-4297-9329-f7993537bf68	729fd30e-9cfb-4751-bbdb-935fbbb7f994	ad72951b-6768-4887-8063-287ff8f51bf1	completed	{}	100.00	2026-03-11 18:31:45.462661+00	2026-03-17 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
e6271338-ee8d-423f-a47a-8cbd356e7353	48f33e15-f87f-4629-ab82-4123ada4bdc4	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	87.00	2026-02-13 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
ce06b4ac-3883-4696-a2a7-6d67992c3bd2	dbccc807-eaba-41f6-aabc-14c515010185	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	85.00	2026-05-25 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
e14b92be-7550-4e36-833f-966a474bcc57	625944b1-2b9b-433b-9af5-e72894aa7a58	ad72951b-6768-4887-8063-287ff8f51bf1	completed	{}	100.00	2026-07-15 18:31:45.462661+00	2026-07-21 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
41df5b8b-70db-44f3-864d-b3c309cd6ae9	c5c94cb5-5272-498b-b30a-d81279c22e12	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	90.00	2026-07-28 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
e55636a7-d41d-44f5-bf22-ee5ffdda61f4	7ea450f4-3442-46d0-a08b-19c1e7308bde	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	65.00	2026-03-19 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
c3932a21-5edc-4996-a5dc-90fb4ee49daa	9bab5f84-a53e-49d6-91f8-eef87bf5960c	ad72951b-6768-4887-8063-287ff8f51bf1	completed	{}	100.00	2026-05-02 18:31:45.462661+00	2026-05-08 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
a0a11efe-7185-4acd-aa9b-1d89c14d6602	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	ad72951b-6768-4887-8063-287ff8f51bf1	completed	{}	100.00	2026-07-07 18:31:45.462661+00	2026-07-13 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
5fc657bf-2874-4278-9e56-b1f2794b1b6b	8b09383e-447b-4fa0-b605-8d8cf4f3f527	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	55.00	2026-04-27 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
fb31eefe-509f-4945-8679-922c940b0245	732e74cf-b9b7-4adc-a43a-794430d7fe49	ad72951b-6768-4887-8063-287ff8f51bf1	completed	{}	100.00	2026-04-20 18:31:45.462661+00	2026-04-26 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
b975105e-c27a-4a9d-b305-48433b9e654d	fda17094-1c9f-45de-a42c-aa815d09bc2a	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	63.00	2026-04-16 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
25035c92-a969-40f7-affd-d9638b6dd42e	e44fe06d-6034-4f79-a75c-79ab0f2b58df	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	84.00	2026-07-30 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
dfa76452-e4bc-44dc-8867-f8200b18c1ef	76e808de-304b-44e5-b793-8516b5fec7bb	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	97.00	2026-08-21 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
96ef3a42-313d-409d-b551-aad54f8ae06e	889560c5-9238-4463-82d8-b65d7fdba4bc	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	41.00	2026-08-29 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
af27d306-ab42-48f2-900e-ba48d283cfba	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	85.00	2026-06-03 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
cfa204b1-18d8-46b1-9f87-76e0c3644669	78313b75-0494-43a4-b199-ff1928254f44	ad72951b-6768-4887-8063-287ff8f51bf1	completed	{}	100.00	2026-04-24 18:31:45.462661+00	2026-04-30 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
01dbe279-7881-4b98-ae49-c39e97a25a82	b97db5e7-dca3-4f88-8318-6d457e09be91	ad72951b-6768-4887-8063-287ff8f51bf1	completed	{}	100.00	2026-07-20 18:31:45.462661+00	2026-07-26 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
259d3fb3-b411-437e-bce7-9071c8f7f3f0	33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	97.00	2026-03-05 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
decfc19a-c741-4f1c-94bf-af872efd6353	db9ec5a1-d0be-490d-91a6-bf32127bba75	ad72951b-6768-4887-8063-287ff8f51bf1	completed	{}	100.00	2026-04-17 18:31:45.462661+00	2026-04-23 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
5a8c2368-48e5-4f8d-8f28-ef52651139d3	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	53.00	2026-04-30 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
0dc7f2e0-f16a-431c-bcb5-2807268f6a2e	c43722c6-7e70-49e0-acb4-ba4f953e36a8	ad72951b-6768-4887-8063-287ff8f51bf1	in_progress	{}	74.00	2026-03-14 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
d41dc7c6-bd1e-4318-884a-edaab8973f7d	1f511b5e-1292-4202-860e-b54f11eda21e	5317862f-92fe-4e22-ae0a-a244abce364c	completed	{}	100.00	2026-08-30 18:31:45.462661+00	2026-09-05 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
3d93c093-7eee-4a49-84be-d423d85f7145	ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	5317862f-92fe-4e22-ae0a-a244abce364c	completed	{}	100.00	2026-02-11 18:31:45.462661+00	2026-02-17 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
85db4cf1-3782-4a3f-b696-73ac79db8e9f	c41a5544-af25-44ec-9fab-26fa3a4e08a5	5317862f-92fe-4e22-ae0a-a244abce364c	completed	{}	100.00	2026-09-04 18:31:45.462661+00	2026-09-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
d96df2e9-f7ba-48c8-a5b5-43779dadeddd	707e086b-3312-442d-ac6d-9776ebe73deb	5317862f-92fe-4e22-ae0a-a244abce364c	completed	{}	100.00	2026-02-21 18:31:45.462661+00	2026-02-27 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
f1b4fe92-2e5f-449d-acde-d2bf48b7edc3	09cc88c9-6251-413b-9873-df6f5bb8b24d	5317862f-92fe-4e22-ae0a-a244abce364c	completed	{}	100.00	2026-05-09 18:31:45.462661+00	2026-05-15 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
ae8b4a8c-e493-48dc-bb49-42f954197007	db9ec5a1-d0be-490d-91a6-bf32127bba75	5317862f-92fe-4e22-ae0a-a244abce364c	in_progress	{}	78.00	2026-05-05 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
ce133e77-7450-4c5b-8d06-f4cc29bb17c1	562af427-bd16-4c30-940b-5d6121d738c8	5317862f-92fe-4e22-ae0a-a244abce364c	in_progress	{}	49.00	2026-09-13 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
557ad132-e522-43d9-b481-440b47c9cb1a	15a2f413-02d0-4624-9468-3a8bec2ba6b8	5317862f-92fe-4e22-ae0a-a244abce364c	in_progress	{}	96.00	2026-07-30 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
0ae28124-129b-46e2-b552-c6ec221445f3	306af47d-26b6-4dc3-96ae-eb178609c1f6	5317862f-92fe-4e22-ae0a-a244abce364c	in_progress	{}	63.00	2026-04-15 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
4a840919-5cdf-4500-9551-813cb44ad7a2	eee6bbaa-75eb-44f4-9892-d46194b720a9	5317862f-92fe-4e22-ae0a-a244abce364c	in_progress	{}	77.00	2026-09-14 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
9bdb5eb3-968d-4824-a46f-996e42418972	7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	5317862f-92fe-4e22-ae0a-a244abce364c	completed	{}	100.00	2026-02-20 18:31:45.462661+00	2026-02-26 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
1dd47949-e1af-4959-8f34-deb7fa2a74a7	862f76a0-443e-4a80-8644-ef4922c5f38a	5317862f-92fe-4e22-ae0a-a244abce364c	in_progress	{}	44.00	2026-08-15 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
c4d44e33-afab-4526-8f66-a387529fe48d	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	5317862f-92fe-4e22-ae0a-a244abce364c	in_progress	{}	56.00	2026-03-05 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
b5d4457f-5f59-40bb-9309-43b19119c659	77c70aa0-ddd9-4445-be30-4817de1cbfd0	5317862f-92fe-4e22-ae0a-a244abce364c	in_progress	{}	96.00	2026-05-25 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
c360bd39-d659-4105-864e-82469cd697c3	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	5317862f-92fe-4e22-ae0a-a244abce364c	in_progress	{}	45.00	2026-06-12 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
83611f80-38af-4bac-8eac-b03c5a8e77bc	caf34c22-6898-4c15-bde0-08f3d2634d41	5317862f-92fe-4e22-ae0a-a244abce364c	in_progress	{}	49.00	2026-07-30 18:31:45.462661+00	\N	2026-09-16 18:31:45.462661+00
8a38ec8a-8ef7-4e70-9f32-07a45fe1e1d3	f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d	5317862f-92fe-4e22-ae0a-a244abce364c	in_progress	{}	62.00	2026-06-24 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
7f7c0092-a441-4463-87c2-fdf0c00269ac	2e35b549-e1b5-4e61-a221-b0799208258c	5317862f-92fe-4e22-ae0a-a244abce364c	in_progress	{}	99.00	2026-03-01 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
badf5341-c638-4188-be52-0a2070b3cc7d	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	5317862f-92fe-4e22-ae0a-a244abce364c	completed	{}	100.00	2026-07-09 18:31:45.462661+00	2026-07-15 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
8fe4cf6c-0cf9-489e-b96e-630b1a2fa176	b8541832-74c6-404f-90d0-5fb6d3df7663	5317862f-92fe-4e22-ae0a-a244abce364c	in_progress	{}	76.00	2026-06-25 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
8de94a19-ca5d-4acd-adc7-270f01f6b304	7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	5317862f-92fe-4e22-ae0a-a244abce364c	completed	{}	100.00	2026-04-30 18:31:45.462661+00	2026-05-06 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
c65598a6-72fd-4b1f-b63c-25c7bd80abaa	a8c5b60b-8763-4325-900d-07d7540e6015	5317862f-92fe-4e22-ae0a-a244abce364c	completed	{}	100.00	2026-08-02 18:31:45.462661+00	2026-08-08 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
21c60757-09b1-4891-8f06-d3d3dab58d3a	7f53c53d-3323-4146-8cea-01d6c38b4f77	5317862f-92fe-4e22-ae0a-a244abce364c	in_progress	{}	94.00	2026-07-12 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
fe2409ea-b402-49e1-92ef-110183549ae4	a6afe850-9547-4fac-892c-00558ad8f725	5317862f-92fe-4e22-ae0a-a244abce364c	completed	{}	100.00	2026-03-08 18:31:45.462661+00	2026-03-14 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
39043f98-9059-4d57-97fc-f34a09211d13	152f1a01-df4b-4828-bf72-c1616f324c38	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-03-12 18:31:45.462661+00	2026-03-18 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
ff65f9c7-26a6-49d3-83da-9aa99760afef	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-03-13 18:31:45.462661+00	2026-03-19 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
71f848ad-3fce-4e0c-a301-284c9836d1ba	b4c20820-6710-46e1-b3cf-939b8bc00f93	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-06-27 18:31:45.462661+00	2026-07-03 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
c18506d5-2c43-4274-94cb-3cf4714eeca6	d072273b-7a6f-4fa4-9195-1697050cfab1	32ab414d-cb9f-48ed-b3b5-97537b736196	in_progress	{}	41.00	2026-03-07 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
c9e46c3a-6b59-4754-b0f8-5c25605c0f3c	032c01d5-4b5e-44f6-821d-2ba4342c938f	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-03-19 18:31:45.462661+00	2026-03-25 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
73ead45e-b337-4eb0-8be0-e5bc896b7b17	fbc637df-19cd-4ec5-b08d-49ce15747076	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-04-01 18:31:45.462661+00	2026-04-07 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
7993edd6-1373-4205-9993-d4f727c61714	77c70aa0-ddd9-4445-be30-4817de1cbfd0	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-08-16 18:31:45.462661+00	2026-08-22 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
2957445f-8bc4-4eb0-983d-e8390cf605c7	24cbfa5b-7114-43b8-957c-fe0efa420c25	32ab414d-cb9f-48ed-b3b5-97537b736196	in_progress	{}	55.00	2026-03-31 18:31:45.462661+00	\N	2026-09-16 18:31:45.462661+00
010c8d40-86df-47ae-8639-4c7c1f459859	2e35b549-e1b5-4e61-a221-b0799208258c	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-06-24 18:31:45.462661+00	2026-06-30 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
aeaaee25-02b4-496c-b24a-36f20b366cd6	9389e5a2-816f-4e52-950b-a9af117c7ad1	32ab414d-cb9f-48ed-b3b5-97537b736196	in_progress	{}	98.00	2026-08-03 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
f3c29d3d-5b65-47ac-aea0-2d7c3504ef67	4ace2ecd-317e-494c-ad50-71e2794fb907	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-06-19 18:31:45.462661+00	2026-06-25 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
7fd69d79-59c6-4667-ab04-b4284985f21b	7ea450f4-3442-46d0-a08b-19c1e7308bde	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-06-28 18:31:45.462661+00	2026-07-04 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
94d80b83-56eb-4764-8e76-181164809f03	0d37acee-70ea-4604-8bd7-c995941443fd	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-07-21 18:31:45.462661+00	2026-07-27 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
4e81b784-8920-40d7-986c-72e2f5d092d3	625944b1-2b9b-433b-9af5-e72894aa7a58	32ab414d-cb9f-48ed-b3b5-97537b736196	in_progress	{}	74.00	2026-02-26 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
aea6ac5e-58c6-4b26-aebc-5b7b01540ac2	8be014b0-ed46-43db-89e2-91a301c618db	32ab414d-cb9f-48ed-b3b5-97537b736196	in_progress	{}	77.00	2026-02-23 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
18a2dc89-2cca-4ffb-b45b-db95526ecf32	a6d5837e-0df4-4cf0-9c98-8f0da7e4a1f1	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-07-24 18:31:45.462661+00	2026-07-30 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
d53f0d11-24d4-4d26-850d-8298a7063918	60e67627-9116-4358-a94b-89c0416805f0	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-07-30 18:31:45.462661+00	2026-08-05 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
308bd86e-ee02-4a02-9073-8b5dad9f41e7	cbd81a81-1d5a-4273-8494-11efdd5fd354	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-06-20 18:31:45.462661+00	2026-06-26 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
cacad3fb-a3cc-4daf-b4f4-c3a92faf16d9	3ded69a7-290c-47f6-bd29-7369f6f8e3c8	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-06-29 18:31:45.462661+00	2026-07-05 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
7d85e913-aa63-404e-9143-e9e230f6bbfb	1e418187-2717-4b94-934c-e5ca025993d8	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-06-17 18:31:45.462661+00	2026-06-23 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
b07e25d7-9fab-475d-a84d-e9793f9e1a22	4135122d-a240-499c-8de4-3db650d7acc9	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-03-25 18:31:45.462661+00	2026-03-31 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
18274278-e95a-4cce-a2a9-963d56aae819	48ae8c9d-e783-46c2-abf3-cc9d31e16d81	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-06-30 18:31:45.462661+00	2026-07-06 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
99941667-085a-4fb4-a155-54cb4e614b08	3260915b-2633-418b-997d-2beabd07ed2b	32ab414d-cb9f-48ed-b3b5-97537b736196	in_progress	{}	76.00	2026-03-20 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
2089609b-cb20-4b49-896f-790089fa4ca9	312e5b6a-024a-4a5d-9389-357b73426d42	32ab414d-cb9f-48ed-b3b5-97537b736196	in_progress	{}	98.00	2026-07-22 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
b873304b-2642-473f-883e-f371c95ee26f	30e16278-0ca1-4efa-a03b-7168658bb2c2	32ab414d-cb9f-48ed-b3b5-97537b736196	in_progress	{}	49.00	2026-05-30 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
4d7cc908-82de-47d3-8c74-37772cc70195	d05292f5-3e9f-4e51-bb50-05a6534dc9b8	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-03-24 18:31:45.462661+00	2026-03-30 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
0427cd77-e639-40da-b368-ab882563a79e	c2900748-9036-4804-b4f0-feb22ac5b4fb	32ab414d-cb9f-48ed-b3b5-97537b736196	in_progress	{}	52.00	2026-09-04 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
848e6636-1e80-4df5-8628-7882864fd62c	6f1d6dd6-daa9-4660-a06f-527bf32f663e	32ab414d-cb9f-48ed-b3b5-97537b736196	completed	{}	100.00	2026-08-03 18:31:45.462661+00	2026-08-09 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
3a3b9ffa-d2e7-47df-9416-74c595598b87	8a83194a-d3bc-49dd-8594-ed05a26d23a0	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-04-20 18:31:45.462661+00	2026-04-26 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
c2a240ae-3933-4a99-95dc-7f93a1e95b29	cd441b90-ef66-411c-b22e-4e046c29677f	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-07-26 18:31:45.462661+00	2026-08-01 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
c8178caa-06cc-4a13-b8f5-6d08f4b67575	eee6bbaa-75eb-44f4-9892-d46194b720a9	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-03-10 18:31:45.462661+00	2026-03-16 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
2ac21176-54b5-46c9-adf2-1268d8ad60fa	602031bb-35f7-4efc-9f2c-f0bcf7d5ef3b	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	in_progress	{}	56.00	2026-04-03 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
0e7149ed-a292-441e-aacc-be1ce19ac9f9	9389e5a2-816f-4e52-950b-a9af117c7ad1	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-07-13 18:31:45.462661+00	2026-07-19 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
b95f53a6-3e04-44d1-8125-85702056aff4	ae420db9-d867-40d1-8d1a-01ee5d62e270	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-08-30 18:31:45.462661+00	2026-09-05 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
a06ebac7-4b52-4209-9e16-4d9dd0efce3e	7f53c53d-3323-4146-8cea-01d6c38b4f77	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-04-18 18:31:45.462661+00	2026-04-24 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
9541ac5a-06c1-4c59-97e7-510eb9cf4a2b	4d5fd264-452f-4436-8eca-5c6c62afb143	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-03-07 18:31:45.462661+00	2026-03-13 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
b5d655b3-7e4b-4a06-86fd-11cba3bcf198	306af47d-26b6-4dc3-96ae-eb178609c1f6	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-02-25 18:31:45.462661+00	2026-03-03 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
de2c53ba-d563-4c9c-ac50-e9b2f8982152	fbc637df-19cd-4ec5-b08d-49ce15747076	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-06-01 18:31:45.462661+00	2026-06-07 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
ab8eeef0-039b-43df-ad50-b6bef66fbe9b	78313b75-0494-43a4-b199-ff1928254f44	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-08-04 18:31:45.462661+00	2026-08-10 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
2847ba39-13a3-4b1b-8dd3-b1a7641e385e	edc1993b-5333-4d99-bae2-9e80266978e0	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	in_progress	{}	90.00	2026-08-18 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
ad9d0cd2-f535-4dfc-b0d5-0bdee25f2b81	1e9340db-2cfd-419f-8894-9448da0bbc19	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-09-05 18:31:45.462661+00	2026-09-11 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
0011bf89-eb80-42ce-8246-bbb4f2f52f2f	729fd30e-9cfb-4751-bbdb-935fbbb7f994	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	in_progress	{}	87.00	2026-05-03 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
a22c3ae3-45a5-4b85-8e8d-f6bee7c5150a	b0ba69f7-69ce-411c-a22d-c449785d11e9	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	in_progress	{}	96.00	2026-03-16 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
b61e063d-8736-406c-8110-a12d73abeb1b	f1bc49b2-13bf-4cd2-a5ac-6aa2c12e8f95	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-04-22 18:31:45.462661+00	2026-04-28 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
6e50cecd-1ad3-4d8f-b7fe-cbafde9eb0c5	1f511b5e-1292-4202-860e-b54f11eda21e	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-09-12 18:31:45.462661+00	2026-09-18 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
795abb93-0039-4bea-bda3-20af432a2413	88b2de0e-fb93-4402-98ef-3c1bd149f61d	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-08-04 18:31:45.462661+00	2026-08-10 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
d0c940de-0255-48af-91fb-23f20ba7b370	0d37acee-70ea-4604-8bd7-c995941443fd	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-04-06 18:31:45.462661+00	2026-04-12 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
72e2bcdc-c808-474c-8e14-1946aa3a2a12	ab65843a-c349-4b21-b43b-9302ed8231b4	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-07-16 18:31:45.462661+00	2026-07-22 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
cf362cf3-69c9-4080-8671-ed8dbbcbc64f	7fe9d01e-9282-4b4d-9377-b8b5d4c7f7d2	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	in_progress	{}	72.00	2026-02-16 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
24abdc83-fe29-4efc-826d-ed4a64f548bd	8a1eab45-738c-41b6-b35d-7737f5e2f64e	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-05-16 18:31:45.462661+00	2026-05-22 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
c80e2b8f-70f8-461b-9bc8-a3dda6cad8a7	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	in_progress	{}	48.00	2026-06-12 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
42069d14-efa2-4a20-90ba-4a419deb875e	3b6030a2-3993-4389-8c6c-d3427e0e680b	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-05-16 18:31:45.462661+00	2026-05-22 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
404b6f3d-89f2-43f6-a9ec-b5e83c17d88d	15a2f413-02d0-4624-9468-3a8bec2ba6b8	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-05-13 18:31:45.462661+00	2026-05-19 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
227e2ec6-0bb9-4514-bd66-902476ae4131	5d1e34b1-8861-4358-96e3-f5ed89f5c9d2	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-06-29 18:31:45.462661+00	2026-07-05 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
0d687657-6208-4b8c-8b5c-df6b063e4c01	d22f23cf-8a58-499a-8dba-92806f1622ef	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-07-26 18:31:45.462661+00	2026-08-01 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
a5d84991-876e-4275-98ae-4054a6e116eb	ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-07-19 18:31:45.462661+00	2026-07-25 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
602e6f9c-d2dc-416f-9505-f1ee41949ecb	a7bae3c0-0e2c-42db-8e35-79114d5dfe80	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	completed	{}	100.00	2026-05-29 18:31:45.462661+00	2026-06-04 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
8c1ecb78-bedd-47ab-b173-f528e5a9d4eb	ec4cdace-5f9a-4198-9518-7c59753a1127	33add9da-29ab-4a45-90b2-f5b8f4723f3d	in_progress	{}	42.00	2026-06-25 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
c94acd89-e7e8-441b-b2a2-2327e55ef25b	3e1e22ae-3497-44dc-bb66-1a3c24a5af91	33add9da-29ab-4a45-90b2-f5b8f4723f3d	completed	{}	100.00	2026-06-23 18:31:45.462661+00	2026-06-29 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
79ef9cd6-7aa0-4dc0-bb69-f48e8eb0d60e	3260915b-2633-418b-997d-2beabd07ed2b	33add9da-29ab-4a45-90b2-f5b8f4723f3d	in_progress	{}	83.00	2026-07-23 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
1b2029c4-460c-474f-a183-b64d52e8202c	8be014b0-ed46-43db-89e2-91a301c618db	33add9da-29ab-4a45-90b2-f5b8f4723f3d	completed	{}	100.00	2026-08-12 18:31:45.462661+00	2026-08-18 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
75dc3075-6ee9-468e-9aff-3c196daff309	2d970758-319c-400f-b2ba-93057f16a33e	33add9da-29ab-4a45-90b2-f5b8f4723f3d	in_progress	{}	61.00	2026-08-16 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
c1ab95ec-4306-4492-8064-93e74ec1df71	a17abc66-209e-405f-bcd6-c39e54cbce66	33add9da-29ab-4a45-90b2-f5b8f4723f3d	completed	{}	100.00	2026-05-10 18:31:45.462661+00	2026-05-16 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
1e9473a7-a27c-4c8d-bec0-0bc69ced5258	8ffbd0cf-b807-4193-af37-3a61482c76eb	33add9da-29ab-4a45-90b2-f5b8f4723f3d	completed	{}	100.00	2026-06-18 18:31:45.462661+00	2026-06-24 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
23f5c668-89bc-4b10-9760-fa4c444cc48b	7acc259e-1231-481b-ab79-59821fd46534	33add9da-29ab-4a45-90b2-f5b8f4723f3d	in_progress	{}	91.00	2026-03-07 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
6c01d888-7b5d-4463-a6df-746827218301	fed72080-2568-4892-8047-0b3c72ff7fad	33add9da-29ab-4a45-90b2-f5b8f4723f3d	in_progress	{}	44.00	2026-04-08 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
cc30cab4-89a4-4f5e-8521-2c1661e20a2d	c41a5544-af25-44ec-9fab-26fa3a4e08a5	33add9da-29ab-4a45-90b2-f5b8f4723f3d	completed	{}	100.00	2026-06-01 18:31:45.462661+00	2026-06-07 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
c3492ab4-e45d-4a10-bb9c-c0f7d3ff1d54	d2298ed0-2515-4232-b70f-845a98dac595	33add9da-29ab-4a45-90b2-f5b8f4723f3d	in_progress	{}	61.00	2026-09-15 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
95396777-6313-4661-a0b6-8eb6b824a900	f1bc49b2-13bf-4cd2-a5ac-6aa2c12e8f95	33add9da-29ab-4a45-90b2-f5b8f4723f3d	completed	{}	100.00	2026-05-05 18:31:45.462661+00	2026-05-11 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
acea68db-2545-45dd-81a6-52347bcc8196	1f511b5e-1292-4202-860e-b54f11eda21e	33add9da-29ab-4a45-90b2-f5b8f4723f3d	in_progress	{}	48.00	2026-04-18 18:31:45.462661+00	\N	2026-09-16 18:31:45.462661+00
22357acd-9c15-4e71-bc12-b5c979dcf015	3b6030a2-3993-4389-8c6c-d3427e0e680b	33add9da-29ab-4a45-90b2-f5b8f4723f3d	in_progress	{}	82.00	2026-02-12 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
704712ec-446a-4779-90b3-ed9075b5ddbe	2c310487-b2d2-4f8a-bdc3-0fcd75eff4a9	33add9da-29ab-4a45-90b2-f5b8f4723f3d	in_progress	{}	73.00	2026-06-18 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
28bf2ed6-4437-4c08-8638-afaaf5626219	5abfd2bf-a622-4ac2-8867-2be6525ec0e8	33add9da-29ab-4a45-90b2-f5b8f4723f3d	in_progress	{}	74.00	2026-07-01 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
4c68d3a8-71d2-407e-b2d9-85c19db19896	889560c5-9238-4463-82d8-b65d7fdba4bc	33add9da-29ab-4a45-90b2-f5b8f4723f3d	in_progress	{}	42.00	2026-07-13 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
0304e0eb-13d0-46c4-ad97-a77cf798b545	3d87692f-06c1-4403-95ff-c70d1598700a	33add9da-29ab-4a45-90b2-f5b8f4723f3d	in_progress	{}	44.00	2026-04-22 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
4c98bab5-bf15-453b-b1fb-2594e555696c	7b1099fc-7596-4be6-9ab4-990d535c39a5	33add9da-29ab-4a45-90b2-f5b8f4723f3d	completed	{}	100.00	2026-08-19 18:31:45.462661+00	2026-08-25 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
84a5a090-38de-4e7f-87e8-cd7a4781ebac	032c01d5-4b5e-44f6-821d-2ba4342c938f	8db3d256-cbbd-4863-b45a-d035bffdba03	in_progress	{}	84.00	2026-08-12 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
94147a3a-884f-41dc-ba0b-699c2e9095cf	33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	8db3d256-cbbd-4863-b45a-d035bffdba03	in_progress	{}	64.00	2026-02-15 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
c48f9407-7522-4d34-8aae-1577d4a36f49	8b09383e-447b-4fa0-b605-8d8cf4f3f527	8db3d256-cbbd-4863-b45a-d035bffdba03	in_progress	{}	98.00	2026-04-04 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
dd062822-69b9-4dbe-bd7c-aa94c5b9231c	bd78a83d-5740-4d0d-9000-cdf29d332f27	8db3d256-cbbd-4863-b45a-d035bffdba03	completed	{}	100.00	2026-07-03 18:31:45.462661+00	2026-07-09 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
24b10d1e-344e-4f74-b73e-6861b8891af6	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	8db3d256-cbbd-4863-b45a-d035bffdba03	completed	{}	100.00	2026-05-12 18:31:45.462661+00	2026-05-18 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
ce76d9b2-d70a-4d46-90f1-22beae6af625	8a0a7128-e6e6-4b49-8395-52723dda0b7c	8db3d256-cbbd-4863-b45a-d035bffdba03	in_progress	{}	76.00	2026-05-20 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
29a719c7-d42e-40f0-8890-a14d0143dc8f	625944b1-2b9b-433b-9af5-e72894aa7a58	8db3d256-cbbd-4863-b45a-d035bffdba03	in_progress	{}	74.00	2026-04-24 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
61c4331f-b7c9-46fc-ab8f-994eb11d3147	6f1d6dd6-daa9-4660-a06f-527bf32f663e	8db3d256-cbbd-4863-b45a-d035bffdba03	in_progress	{}	81.00	2026-09-09 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
aba52e89-30be-4f1c-9baa-c1dd75ae2232	6a389990-e259-43a4-a9a2-7575b00029e0	8db3d256-cbbd-4863-b45a-d035bffdba03	in_progress	{}	99.00	2026-08-03 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
ecbb970a-2ffc-4bd9-8473-ca979c9f82a6	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	8db3d256-cbbd-4863-b45a-d035bffdba03	in_progress	{}	51.00	2026-08-29 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
1ae116b6-332f-41f6-9abf-c166c50e6887	eee6bbaa-75eb-44f4-9892-d46194b720a9	8db3d256-cbbd-4863-b45a-d035bffdba03	in_progress	{}	90.00	2026-09-07 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
a6c5ca28-5a03-419a-a4b5-8a02b18dc93f	4d5fd264-452f-4436-8eca-5c6c62afb143	8db3d256-cbbd-4863-b45a-d035bffdba03	completed	{}	100.00	2026-05-07 18:31:45.462661+00	2026-05-13 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
f7cd7239-35e3-41f4-8a7c-81c99eac792f	2994671f-607f-4cdc-a2bc-22ab97456b28	8db3d256-cbbd-4863-b45a-d035bffdba03	in_progress	{}	70.00	2026-07-19 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
8077aa42-ac5d-4ae6-a4ea-d75d4835c6c6	3af00a36-1f7b-4846-a52a-b1871416c5b1	8db3d256-cbbd-4863-b45a-d035bffdba03	completed	{}	100.00	2026-07-25 18:31:45.462661+00	2026-07-31 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
f8bffd29-2578-4cdc-9498-f94aed4ec6c6	5af34829-4d6f-425c-9f78-525896ea0526	8db3d256-cbbd-4863-b45a-d035bffdba03	completed	{}	100.00	2026-07-30 18:31:45.462661+00	2026-08-05 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
311320ca-5100-49c5-a35d-ce8aea9126d9	b2734396-c5d2-4b05-99d0-986a180a98a6	8db3d256-cbbd-4863-b45a-d035bffdba03	completed	{}	100.00	2026-07-27 18:31:45.462661+00	2026-08-02 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
83b32e6a-662d-4feb-afb9-8d564f732d60	0f80298a-f569-4c55-88aa-a57625e20751	8db3d256-cbbd-4863-b45a-d035bffdba03	in_progress	{}	92.00	2026-05-26 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
69bf3d9f-1751-4cb4-bc9d-c75a0562b47e	c41a5544-af25-44ec-9fab-26fa3a4e08a5	8db3d256-cbbd-4863-b45a-d035bffdba03	completed	{}	100.00	2026-04-13 18:31:45.462661+00	2026-04-19 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
5d0cd4c3-5a25-4fa8-a72c-b960e23c3eb6	fba30b27-7555-43f7-8c74-b84e722ebbc8	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-09-06 18:31:45.462661+00	2026-09-12 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
005e6307-6b05-4e6b-8956-8140d1f80578	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-03-24 18:31:45.462661+00	2026-03-30 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
158283e9-4cc3-4fef-81ee-737691d6dd4c	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-05-29 18:31:45.462661+00	2026-06-04 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
21bf957d-d4d8-47c9-b5ff-74d441097362	17231857-2d57-46f3-aecc-cb26a0865adb	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-02-25 18:31:45.462661+00	2026-03-03 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
7c03259b-50d9-47f5-9502-8890a963b104	6b116d7e-84ed-47de-81ea-2bd42ea50968	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-08-16 18:31:45.462661+00	2026-08-22 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
656026a4-e902-4d47-9898-ab6d2bbcf07b	a5102b13-4107-4fe5-b7a0-064dd07042ee	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-06-13 18:31:45.462661+00	2026-06-19 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
666cd898-aea8-4828-aca2-51731e0378ff	28fe79f0-6207-4e0c-8bae-1eb02eed759b	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-07-06 18:31:45.462661+00	2026-07-12 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
dc0aafc3-48ec-4621-9107-62cdf5105056	889560c5-9238-4463-82d8-b65d7fdba4bc	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-06-18 18:31:45.462661+00	2026-06-24 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
ef503045-5d49-4ae9-afb6-cf97e7d69b7f	b97db5e7-dca3-4f88-8318-6d457e09be91	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-08-09 18:31:45.462661+00	2026-08-15 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
17f227d6-117d-4900-bb8f-2c4d0c1e2e5f	2731bad6-8e73-4106-8def-3df5df76b6ea	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-08-13 18:31:45.462661+00	2026-08-19 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
6981d67a-7c44-4d8e-bd8a-8e2f757feea0	37609501-b2cd-4810-a1d5-b2a10f0405fd	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-05-06 18:31:45.462661+00	2026-05-12 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
345b9429-ff2b-4182-b5b4-a4ffffe946b8	7fe9d01e-9282-4b4d-9377-b8b5d4c7f7d2	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-08-19 18:31:45.462661+00	2026-08-25 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
036fc059-9edb-4032-ae08-1208f4a04212	216136af-8b6b-44ae-a787-59506613a618	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-07-17 18:31:45.462661+00	2026-07-23 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
216c2c72-300e-40bc-acfd-be4aaa5a0b8f	fda17094-1c9f-45de-a42c-aa815d09bc2a	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-04-22 18:31:45.462661+00	2026-04-28 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
c29b9ca2-2661-4d4b-865d-3210ed255131	77c70aa0-ddd9-4445-be30-4817de1cbfd0	c4985880-e557-407c-8f90-5c1f5b564695	in_progress	{}	77.00	2026-04-19 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
d669d5d9-0c45-428b-b210-43b4f3e62fe2	5d9905c7-91e8-4bd9-b187-b1b8772e0f63	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-05-01 18:31:45.462661+00	2026-05-07 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
06a3cdd1-1006-459b-be68-90586112f9ac	feb2fb92-ce04-48c5-8a5f-9d2e832d1644	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-08-02 18:31:45.462661+00	2026-08-08 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
ed8f969d-d44b-4468-852a-23126525502b	7acc259e-1231-481b-ab79-59821fd46534	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-06-13 18:31:45.462661+00	2026-06-19 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
219cf33c-4bde-49fd-831b-92866846c9e8	db9ec5a1-d0be-490d-91a6-bf32127bba75	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-05-03 18:31:45.462661+00	2026-05-09 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
5c5e336c-282a-4709-bfe7-d861547ff89c	a6f0ed93-9d6b-4592-a13e-5435550b4db2	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-03-08 18:31:45.462661+00	2026-03-14 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
985b4e6b-19f9-4d4b-b308-3533545618a8	8be014b0-ed46-43db-89e2-91a301c618db	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-06-10 18:31:45.462661+00	2026-06-16 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
8df00cd9-1485-4cc5-b0cf-6cea37f50556	ab65843a-c349-4b21-b43b-9302ed8231b4	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-08-07 18:31:45.462661+00	2026-08-13 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
88a871cf-ffda-4030-b707-5c18616b0510	46e6d439-49ab-4001-b576-7df03d3babee	c4985880-e557-407c-8f90-5c1f5b564695	completed	{}	100.00	2026-08-14 18:31:45.462661+00	2026-08-20 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
5fae8216-c8f1-4569-9965-9ab4c96d3f7c	a5102b13-4107-4fe5-b7a0-064dd07042ee	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-04-20 18:31:45.462661+00	2026-04-26 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
10b0a44e-4d3f-448b-969c-6c7b522fcb2c	a17abc66-209e-405f-bcd6-c39e54cbce66	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-03-30 18:31:45.462661+00	2026-04-05 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
010b9981-b387-492e-b164-540e827f509b	1f511b5e-1292-4202-860e-b54f11eda21e	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-05-20 18:31:45.462661+00	2026-05-26 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
533a24fc-699f-485e-9410-e6b7ff30b9c2	46e6d439-49ab-4001-b576-7df03d3babee	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-07-22 18:31:45.462661+00	2026-07-28 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
0e4aa15e-46b8-4b57-84be-f75aea92a7ed	562af427-bd16-4c30-940b-5d6121d738c8	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-06-19 18:31:45.462661+00	2026-06-25 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
77ba9a84-2be3-4107-a27e-69e654086e9b	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-07-18 18:31:45.462661+00	2026-07-24 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
170873cb-7302-4b5a-8236-b79ae9dccd76	caf34c22-6898-4c15-bde0-08f3d2634d41	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-09-05 18:31:45.462661+00	2026-09-11 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
41cae6d0-82a9-49d0-9968-effc68840f5b	2731bad6-8e73-4106-8def-3df5df76b6ea	0724a689-d500-4969-b7fb-72e37232b31f	in_progress	{}	83.00	2026-05-29 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
b2ee9ee7-b11b-42a0-b38e-f8082fdbf5dd	032c01d5-4b5e-44f6-821d-2ba4342c938f	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-07-29 18:31:45.462661+00	2026-08-04 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
7c6c46cf-3d39-4ce8-953f-a5f8cf5d4252	3e1e22ae-3497-44dc-bb66-1a3c24a5af91	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-04-27 18:31:45.462661+00	2026-05-03 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
36e4aeae-9cd0-4b50-a351-b4a37d3ed07b	1eb0cec9-a12f-4f42-9d77-bf6e343e9a75	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-07-09 18:31:45.462661+00	2026-07-15 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
20c1a9b4-b1e7-40dc-a4ca-e0612e9168b1	e6ef6d8e-87f0-4c3d-8ac9-dccb12f222f1	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-03-24 18:31:45.462661+00	2026-03-30 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
b70d150e-2d9d-475a-9970-3f5d47d38ec9	88b2de0e-fb93-4402-98ef-3c1bd149f61d	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-09-10 18:31:45.462661+00	2026-09-16 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
2bbe7a53-2aeb-4a7c-9f80-e9102cc54f34	c41e7852-875f-411b-93f1-7171f9871f9f	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-08-12 18:31:45.462661+00	2026-08-18 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
771bc142-aed6-4196-858c-e0386f542c26	4ace2ecd-317e-494c-ad50-71e2794fb907	0724a689-d500-4969-b7fb-72e37232b31f	in_progress	{}	61.00	2026-07-24 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
c065350d-3315-4839-9cac-7883e3b7c53d	c2900748-9036-4804-b4f0-feb22ac5b4fb	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-03-28 18:31:45.462661+00	2026-04-03 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
dc06d5f4-0551-4232-b753-2b451cee9df2	a8c5b60b-8763-4325-900d-07d7540e6015	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-07-17 18:31:45.462661+00	2026-07-23 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
1bcb8563-5e0d-4ed8-bed5-bcbd6baa1961	8be014b0-ed46-43db-89e2-91a301c618db	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-02-22 18:31:45.462661+00	2026-02-28 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
17d187b4-a880-438f-95bc-898468b10055	fed72080-2568-4892-8047-0b3c72ff7fad	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-03-07 18:31:45.462661+00	2026-03-13 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
3424efac-c10f-4142-a99d-b7f297670d04	17231857-2d57-46f3-aecc-cb26a0865adb	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-03-15 18:31:45.462661+00	2026-03-21 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
8fb8031e-e3ba-48c1-b314-50f7c12c55d2	d05292f5-3e9f-4e51-bb50-05a6534dc9b8	0724a689-d500-4969-b7fb-72e37232b31f	completed	{}	100.00	2026-06-03 18:31:45.462661+00	2026-06-09 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
a880ba6f-8e40-42dd-a94b-ac8088b2a0a2	4acb1924-e6ec-428c-8401-ac05f87e2bbf	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-06-20 18:31:45.462661+00	2026-06-26 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
e0cc63d6-d2e0-42c7-8e08-8c7cf39dbcc0	862f76a0-443e-4a80-8644-ef4922c5f38a	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-02-24 18:31:45.462661+00	2026-03-02 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
89954676-7215-4ff1-ab01-ed364feb965c	fed72080-2568-4892-8047-0b3c72ff7fad	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-06-15 18:31:45.462661+00	2026-06-21 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
832a8d87-671f-43fc-a3f9-536cb4394008	7acc259e-1231-481b-ab79-59821fd46534	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-06-25 18:31:45.462661+00	2026-07-01 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
3b6b147f-91f3-421f-8c19-b166c92a6a32	8be014b0-ed46-43db-89e2-91a301c618db	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-06-10 18:31:45.462661+00	2026-06-16 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
ea6a55fe-1e2f-4289-9a0d-13437e5761b3	2e35b549-e1b5-4e61-a221-b0799208258c	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-09-05 18:31:45.462661+00	2026-09-11 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
b9f47667-72dc-474b-a440-e4f88ba13d22	28fe79f0-6207-4e0c-8bae-1eb02eed759b	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-05-02 18:31:45.462661+00	2026-05-08 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
dfeb44a1-ae04-45e3-888f-5a715ca54dfc	77c70aa0-ddd9-4445-be30-4817de1cbfd0	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-08-05 18:31:45.462661+00	2026-08-11 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
9bb2037a-8b72-4cf5-b212-feb8677c50d4	cf4749a6-6127-4d97-b2a0-17a11eabc216	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-04-27 18:31:45.462661+00	2026-05-03 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
44414842-ca38-4a94-bd2a-1a3446a734e8	65ef229b-117d-4946-b5bb-301e3f828fc2	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-09-07 18:31:45.462661+00	2026-09-13 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
ad27237d-cfdf-462f-86bd-b07e783f89b2	7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-02-28 18:31:45.462661+00	2026-03-06 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
b9fa8b07-052a-416f-a2c5-095eba94f5dd	152f1a01-df4b-4828-bf72-c1616f324c38	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-06-11 18:31:45.462661+00	2026-06-17 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
0bdb6c59-f55d-4f3a-a61b-608a348e93d1	293f638f-6b5e-4c5a-9282-533cc1c97688	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-08-28 18:31:45.462661+00	2026-09-03 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
a62cb793-dd3b-4d45-bc44-b1a6c4f75f14	a17abc66-209e-405f-bcd6-c39e54cbce66	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-09-07 18:31:45.462661+00	2026-09-13 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
9e033cf7-3666-40b8-9c31-de362295e81e	7e426fed-4c2e-46f4-866a-7b8aa048cf06	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-03-28 18:31:45.462661+00	2026-04-03 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
457e7516-1b98-45d2-bbac-6077f8de91d8	625944b1-2b9b-433b-9af5-e72894aa7a58	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-08-26 18:31:45.462661+00	2026-09-01 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
8fdd884d-17b6-4779-ab14-b7bae80751cb	889560c5-9238-4463-82d8-b65d7fdba4bc	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-08-19 18:31:45.462661+00	2026-08-25 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
b9f5d656-0637-4b1a-88c5-4a7d9eb35c9c	6f9f3af8-fa88-4804-aa9b-5680afa4c1ba	ce43f7f3-92cb-4d62-b40a-149bdd13b745	in_progress	{}	61.00	2026-09-10 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
cb456500-1f15-4be5-b65f-53ece90d01f0	df216767-1cda-46b6-874f-845e41051203	ce43f7f3-92cb-4d62-b40a-149bdd13b745	in_progress	{}	48.00	2026-07-06 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
d534428d-a93e-4024-873f-e6dda29d65eb	732e74cf-b9b7-4adc-a43a-794430d7fe49	ce43f7f3-92cb-4d62-b40a-149bdd13b745	completed	{}	100.00	2026-07-10 18:31:45.462661+00	2026-07-16 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
82634c44-2fad-43f1-a8f4-c0db0586a0fd	55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	97b1727b-e525-4ee5-b01f-28b15a8101b5	completed	{}	100.00	2026-03-31 18:31:45.462661+00	2026-04-06 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
cfdea3e4-c958-466b-9fdc-05887bd22157	ab903484-298e-4415-93b0-8f5ea844bf31	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	67.00	2026-06-30 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
41ed110e-f10c-4bdb-b91f-72c04abbe330	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	74.00	2026-07-22 18:31:45.462661+00	\N	2026-09-16 18:31:45.462661+00
d16a05b6-8f4b-4985-9536-207f0b3f9b91	889560c5-9238-4463-82d8-b65d7fdba4bc	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	78.00	2026-08-15 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
26abaca9-a19e-43f6-9b0b-153b7092fe68	48ae8c9d-e783-46c2-abf3-cc9d31e16d81	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	83.00	2026-07-31 18:31:45.462661+00	\N	2026-09-16 18:31:45.462661+00
4872565e-27ac-4dd5-a240-92dd0c7a35ba	5d1e34b1-8861-4358-96e3-f5ed89f5c9d2	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	47.00	2026-04-10 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
9c9b12c8-debe-4df9-93fa-06ac8e33112b	152f1a01-df4b-4828-bf72-c1616f324c38	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	43.00	2026-08-04 18:31:45.462661+00	\N	2026-09-16 18:31:45.462661+00
65d4cb2f-5392-4189-8529-a4c4d340863f	b8541832-74c6-404f-90d0-5fb6d3df7663	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	77.00	2026-02-09 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
b03c04fb-ee23-4f72-a335-56f75157f06b	2c310487-b2d2-4f8a-bdc3-0fcd75eff4a9	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	92.00	2026-07-25 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
11fd7554-fc43-498f-861f-bed223d012f0	cf4749a6-6127-4d97-b2a0-17a11eabc216	97b1727b-e525-4ee5-b01f-28b15a8101b5	completed	{}	100.00	2026-03-09 18:31:45.462661+00	2026-03-15 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
713d36f8-389f-475f-8c6a-c58336d3c7c3	a7bae3c0-0e2c-42db-8e35-79114d5dfe80	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	86.00	2026-05-14 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
611bec75-7318-4f78-be13-cded2d1d7718	62868b88-e860-457b-8605-04153588489b	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	98.00	2026-05-14 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
ea086acf-e11d-4aef-8ee0-b40a2c321a5a	1e9340db-2cfd-419f-8894-9448da0bbc19	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	89.00	2026-08-05 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
78e0e2ba-a161-43a9-8910-f383178df4d0	9bab5f84-a53e-49d6-91f8-eef87bf5960c	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	67.00	2026-03-03 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
5dc79fd2-8a8d-4d3a-99f7-cf0f1d7c1b7b	350093ae-4f68-46a9-a0af-c33a9b87c340	97b1727b-e525-4ee5-b01f-28b15a8101b5	completed	{}	100.00	2026-03-17 18:31:45.462661+00	2026-03-23 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
b2ed8060-fbd2-44db-966b-a1e7479e2184	5d9905c7-91e8-4bd9-b187-b1b8772e0f63	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	59.00	2026-06-16 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
35c10df4-4fc3-4aac-89b1-0e6717caae43	fda17094-1c9f-45de-a42c-aa815d09bc2a	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	89.00	2026-04-10 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
3e4a702d-12d9-410d-a828-ae74ec920f75	d072273b-7a6f-4fa4-9195-1697050cfab1	97b1727b-e525-4ee5-b01f-28b15a8101b5	completed	{}	100.00	2026-04-15 18:31:45.462661+00	2026-04-21 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
f84b7e92-1a77-4e14-b65c-801293fa19e4	b2c7b829-9669-4258-ab45-acc4445b9d6d	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	94.00	2026-07-01 18:31:45.462661+00	\N	2026-09-16 18:31:45.462661+00
62b3cd01-45b5-435c-b535-abba73a43fd5	d2298ed0-2515-4232-b70f-845a98dac595	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	58.00	2026-02-22 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
1d909fca-6294-45c6-b84a-94b2f7294caa	2af59a77-c993-46c3-a686-b91217814d48	97b1727b-e525-4ee5-b01f-28b15a8101b5	completed	{}	100.00	2026-05-02 18:31:45.462661+00	2026-05-08 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
ec179c00-e2d8-453b-b768-c340f56ad93e	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	97b1727b-e525-4ee5-b01f-28b15a8101b5	completed	{}	100.00	2026-03-01 18:31:45.462661+00	2026-03-07 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
cf06c14e-3ce5-4118-8188-d257cd83f395	9897dc81-824b-4829-9fda-76c3f3c3e38f	97b1727b-e525-4ee5-b01f-28b15a8101b5	in_progress	{}	82.00	2026-07-12 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
3a2b00ed-f682-4d06-9d2d-b915228caf8b	f75210c9-faa1-45c8-9314-a65724983502	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-07-21 18:31:45.462661+00	2026-07-27 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
02566c67-52d0-4e8a-91e6-3c35a54d110f	889560c5-9238-4463-82d8-b65d7fdba4bc	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-07-10 18:31:45.462661+00	2026-07-16 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
77a722d0-4416-451d-b770-2f39c855d7a0	fed72080-2568-4892-8047-0b3c72ff7fad	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-02-20 18:31:45.462661+00	2026-02-26 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
2e759107-b839-40a7-b18d-ac13b02fca89	48f33e15-f87f-4629-ab82-4123ada4bdc4	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-07-06 18:31:45.462661+00	2026-07-12 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
2f7e47c6-2fea-48bb-971b-77bd93d7d7a3	18c4a035-c0ad-48f3-8628-30fee5e16970	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-02-10 18:31:45.462661+00	2026-02-16 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
4bf76d3a-ca6a-4087-84a0-c9ee6ed49183	0f80298a-f569-4c55-88aa-a57625e20751	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-06-15 18:31:45.462661+00	2026-06-21 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
47678f23-a49e-43fc-a818-c1b9676039d9	625944b1-2b9b-433b-9af5-e72894aa7a58	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-06-10 18:31:45.462661+00	2026-06-16 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
7fd18145-0be5-465c-ad46-3d4a1be35139	dbccc807-eaba-41f6-aabc-14c515010185	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-09-04 18:31:45.462661+00	2026-09-10 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
39290458-17a9-44e7-87cd-7a2cacb1c1ef	24cbfa5b-7114-43b8-957c-fe0efa420c25	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-04-17 18:31:45.462661+00	2026-04-23 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
8471d443-2dea-4d0e-b4e1-a2bd351a63a0	3af00a36-1f7b-4846-a52a-b1871416c5b1	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-08-30 18:31:45.462661+00	2026-09-05 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
bcf19465-063c-40e8-9181-e98a294a9093	d2298ed0-2515-4232-b70f-845a98dac595	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-07-11 18:31:45.462661+00	2026-07-17 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
8e2b7569-7753-4af7-972d-76aa6d3d3e24	d072273b-7a6f-4fa4-9195-1697050cfab1	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-08-21 18:31:45.462661+00	2026-08-27 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
1746c31c-a492-4637-8bd4-57001b93853a	b8541832-74c6-404f-90d0-5fb6d3df7663	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-05-03 18:31:45.462661+00	2026-05-09 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
dff36d30-69ef-4c93-9ba4-ef406c690bea	1e9340db-2cfd-419f-8894-9448da0bbc19	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-07-19 18:31:45.462661+00	2026-07-25 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
9e7774fe-852b-4e3b-945b-25064ddcea21	fda17094-1c9f-45de-a42c-aa815d09bc2a	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-02-21 18:31:45.462661+00	2026-02-27 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
3576b4be-3ad8-4896-81e5-387890c96dc5	eee6bbaa-75eb-44f4-9892-d46194b720a9	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-08-22 18:31:45.462661+00	2026-08-28 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
b786b49c-e472-4169-8f8b-7d49f3c1cea4	2e35b549-e1b5-4e61-a221-b0799208258c	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-03-30 18:31:45.462661+00	2026-04-05 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
b190b89e-65a0-4fb6-b74a-09b739df952a	b0ba69f7-69ce-411c-a22d-c449785d11e9	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-04-01 18:31:45.462661+00	2026-04-07 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
a51c2e0c-a48c-412b-a78e-8f5dd3fd2d9f	33f73596-75e6-435e-94f5-d5b111a6aaf5	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-02-17 18:31:45.462661+00	2026-02-23 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
38020fe8-50d6-40cd-8e2b-29845acc54d7	4ace2ecd-317e-494c-ad50-71e2794fb907	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-07-10 18:31:45.462661+00	2026-07-16 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
8348d5c7-7f77-4333-8280-e6252df4318b	696886f6-a4bf-44a6-9ba9-c939abb52137	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-05-28 18:31:45.462661+00	2026-06-03 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
2f055eaf-74d8-44f3-9ddb-3855135ce012	f74aaa72-56ba-476d-9aed-ffbe2e41dd50	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-04-08 18:31:45.462661+00	2026-04-14 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
d6ecf552-7c95-4ae8-a6ff-62aa6d00a435	60e67627-9116-4358-a94b-89c0416805f0	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-09-03 18:31:45.462661+00	2026-09-09 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
c3148a82-947c-4dae-a13c-e922a92a4fd5	9e08ecc2-e291-4516-bae3-07b43abc2620	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-03-16 18:31:45.462661+00	2026-03-22 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
80dec3c5-aec0-4291-9062-38d9e5afedec	08758984-558b-4323-bc35-2a202203d87b	e930bc9e-26fc-4a34-89bc-012457df980e	completed	{}	100.00	2026-04-30 18:31:45.462661+00	2026-05-06 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
f41e325c-e1ec-468d-8861-371f759fcd83	dbccc807-eaba-41f6-aabc-14c515010185	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	75.00	2026-02-28 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
8598698e-4739-4631-bc9a-107c2ed6bc9c	edc1993b-5333-4d99-bae2-9e80266978e0	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	89.00	2026-09-13 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
cb50ba6a-80c6-4dee-9daf-2579a4677272	72a5ceb8-6b68-433d-9b99-d62b8c9f1375	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	74.00	2026-05-12 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
4dec8997-72dc-4511-994b-2e7dcd8e6da2	5abfd2bf-a622-4ac2-8867-2be6525ec0e8	290cedcf-37a4-4271-ae6c-2172115f0acb	completed	{}	100.00	2026-03-05 18:31:45.462661+00	2026-03-11 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
632b8d75-f468-4298-8b0b-486d8844f468	3a18a01e-89f7-474e-abf1-964581203793	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	91.00	2026-04-16 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
4da20b6b-71d5-4c88-a98e-7fc67012ad27	8ffbd0cf-b807-4193-af37-3a61482c76eb	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	83.00	2026-06-01 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
2b1400a0-81f0-4584-97da-81601588ad56	caf34c22-6898-4c15-bde0-08f3d2634d41	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	64.00	2026-07-18 18:31:45.462661+00	\N	2026-09-16 18:31:45.462661+00
4a3e90a6-1706-4988-9c06-0b663f448fd1	fba30b27-7555-43f7-8c74-b84e722ebbc8	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	67.00	2026-07-17 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
18ac0157-4fe4-4bc5-bd82-0c9a9db4d38f	a5102b13-4107-4fe5-b7a0-064dd07042ee	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	65.00	2026-09-14 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
7e4b50f1-4212-4730-81dd-f6b03f231066	b28e0245-9390-4127-ad3f-80ace4775f43	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	73.00	2026-02-15 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
9f3bada1-6365-4ccd-a940-f36fc5f1c35a	88b2de0e-fb93-4402-98ef-3c1bd149f61d	290cedcf-37a4-4271-ae6c-2172115f0acb	completed	{}	100.00	2026-03-15 18:31:45.462661+00	2026-03-21 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
8a948f55-8219-4792-a45c-7d3b4d10cfe1	05a922f4-7a9b-427c-bd4f-34ee3bdcfcf6	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	84.00	2026-07-23 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
1fe2e3f5-1245-4b31-bc93-a03a60973e7f	a6f0ed93-9d6b-4592-a13e-5435550b4db2	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	89.00	2026-02-21 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
c173e00e-b5df-40f4-9cb9-a05165961c38	1f511b5e-1292-4202-860e-b54f11eda21e	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	43.00	2026-02-27 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
f9cdedaa-2ae1-453c-ba22-7220807238b3	bea31be8-3a44-4869-9c56-dce2da936f51	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	67.00	2026-08-20 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
273adfa2-ff18-480f-aa70-3dbdbb958e29	e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	290cedcf-37a4-4271-ae6c-2172115f0acb	completed	{}	100.00	2026-08-03 18:31:45.462661+00	2026-08-09 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
d2d41961-352c-48c1-bd55-05a55e4a65ea	cd441b90-ef66-411c-b22e-4e046c29677f	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	88.00	2026-02-17 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
19efa412-4342-4f59-bbb8-1e19e17c9d11	fbc637df-19cd-4ec5-b08d-49ce15747076	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	88.00	2026-03-01 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
163e7f3c-9de8-41bd-8469-6726656427c9	0d37acee-70ea-4604-8bd7-c995941443fd	290cedcf-37a4-4271-ae6c-2172115f0acb	completed	{}	100.00	2026-05-02 18:31:45.462661+00	2026-05-08 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
36da8aec-dd07-46c2-9017-14b5ea747fd8	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	49.00	2026-02-14 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
85143ba8-9f2d-4ca0-b728-6bf23aa61a4d	9e08ecc2-e291-4516-bae3-07b43abc2620	290cedcf-37a4-4271-ae6c-2172115f0acb	completed	{}	100.00	2026-06-24 18:31:45.462661+00	2026-06-30 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
a3c35d22-8743-4715-8398-f86b62590dfd	216136af-8b6b-44ae-a787-59506613a618	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	83.00	2026-06-29 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
c084b48f-f085-4a43-9b8c-260c5100807e	ab903484-298e-4415-93b0-8f5ea844bf31	290cedcf-37a4-4271-ae6c-2172115f0acb	completed	{}	100.00	2026-02-16 18:31:45.462661+00	2026-02-22 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
c5af4586-f630-4df5-8c65-f2449343be04	2af59a77-c993-46c3-a686-b91217814d48	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	89.00	2026-06-15 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
16cf4032-0238-4a76-bb37-1b492fd9742b	c41a5544-af25-44ec-9fab-26fa3a4e08a5	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	77.00	2026-06-22 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
1c8df0a2-fc01-47ca-aaf3-8376af409b6f	6cf3f90d-5b2f-422b-98a5-3df74a5bcbad	290cedcf-37a4-4271-ae6c-2172115f0acb	in_progress	{}	88.00	2026-05-04 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
de927c52-9c55-45a7-8d47-e3a554d5ac7b	17231857-2d57-46f3-aecc-cb26a0865adb	290cedcf-37a4-4271-ae6c-2172115f0acb	completed	{}	100.00	2026-08-30 18:31:45.462661+00	2026-09-05 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
142179ce-c12f-4ebc-bcc2-1953ee8bd118	fc08ec35-be50-46ec-8acb-0ddb68b16b22	290cedcf-37a4-4271-ae6c-2172115f0acb	completed	{}	100.00	2026-08-07 18:31:45.462661+00	2026-08-13 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
e19e7d79-2ea4-4ded-8a14-478f285007a6	a6f0ed93-9d6b-4592-a13e-5435550b4db2	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	44.00	2026-04-23 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
4fe08c9b-c7e8-4607-b33a-fac638464aa0	ea8fa5c6-6833-4701-9073-dd4ff3f78cb8	57e0bcdd-75f2-4ba6-b987-befe07d147c8	completed	{}	100.00	2026-04-08 18:31:45.462661+00	2026-04-14 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
26e0ca4c-f45b-4245-b7fc-168a9338e367	72a5ceb8-6b68-433d-9b99-d62b8c9f1375	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	82.00	2026-08-25 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
788f0b57-4fa1-45e8-8e30-950364da6176	30e16278-0ca1-4efa-a03b-7168658bb2c2	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	61.00	2026-03-27 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
ca511c2b-38e2-4e52-95a2-73c27820061a	b2734396-c5d2-4b05-99d0-986a180a98a6	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	73.00	2026-08-11 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
5170abb3-5c28-491a-a92e-759aad7196a2	8a1eab45-738c-41b6-b35d-7737f5e2f64e	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	69.00	2026-05-16 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
2a7d5182-8e6b-4b70-ab2f-afde9b6dccac	152f1a01-df4b-4828-bf72-c1616f324c38	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	63.00	2026-02-19 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
ccc5bc51-fbb5-478a-b945-05abd3426806	1f511b5e-1292-4202-860e-b54f11eda21e	57e0bcdd-75f2-4ba6-b987-befe07d147c8	completed	{}	100.00	2026-05-18 18:31:45.462661+00	2026-05-24 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
c35b396a-6f16-44e1-8325-28342fcfd1f6	e44fe06d-6034-4f79-a75c-79ab0f2b58df	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	55.00	2026-08-18 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
5d4b0dd6-08fb-41b6-a127-bd7f0d2f5ae8	9e08ecc2-e291-4516-bae3-07b43abc2620	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	53.00	2026-07-13 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
45648ca5-2ad6-40f4-adf8-b08593e1ddb4	f75210c9-faa1-45c8-9314-a65724983502	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	85.00	2026-07-13 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
62af5c76-1bf5-46f1-bec8-aea282ec240b	d22f23cf-8a58-499a-8dba-92806f1622ef	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	73.00	2026-02-24 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
abec2e97-23d7-4b37-8f82-b12fa3231095	cc9e83f0-d177-4454-8ba5-f7581c6da639	57e0bcdd-75f2-4ba6-b987-befe07d147c8	completed	{}	100.00	2026-07-03 18:31:45.462661+00	2026-07-09 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
560d97be-028b-46e7-91d7-277773529ac0	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	57e0bcdd-75f2-4ba6-b987-befe07d147c8	completed	{}	100.00	2026-04-16 18:31:45.462661+00	2026-04-22 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
8c3c7b9e-79ed-4e4e-816e-f3b85af79ae7	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	91.00	2026-05-10 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
e0f4826b-1038-4421-b7bf-3fc65cedb93f	77c70aa0-ddd9-4445-be30-4817de1cbfd0	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	49.00	2026-07-22 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
5d924b16-946d-43d0-8b7b-500fda09f856	4acb1924-e6ec-428c-8401-ac05f87e2bbf	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	59.00	2026-05-19 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
6bccc537-1f9e-4e25-938e-e24d8d831431	c43722c6-7e70-49e0-acb4-ba4f953e36a8	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	99.00	2026-05-31 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
7a42f068-9cd8-4496-90fa-37a1d5d5f719	a5102b13-4107-4fe5-b7a0-064dd07042ee	57e0bcdd-75f2-4ba6-b987-befe07d147c8	in_progress	{}	62.00	2026-07-20 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
899ab84a-c761-431b-b115-77abb0c25262	cf4749a6-6127-4d97-b2a0-17a11eabc216	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-04-30 18:31:45.462661+00	2026-05-06 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
67678c27-9445-4b91-a74f-e87427044723	357f9f29-063f-4ff8-bdc9-6df1d8cb15b4	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-08-30 18:31:45.462661+00	2026-09-05 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
56dd7b52-7fb2-49c9-8c7c-6f5d4ef7a97d	2af59a77-c993-46c3-a686-b91217814d48	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-04-22 18:31:45.462661+00	2026-04-28 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
adfd0914-a263-4de4-b0d6-e4d310150816	90a570b4-9441-4d8b-981d-a7fa379054d3	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-08-28 18:31:45.462661+00	2026-09-03 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
365c0df9-208d-4ca7-b19f-f4594472a80e	b28e0245-9390-4127-ad3f-80ace4775f43	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-06-05 18:31:45.462661+00	2026-06-11 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
28ba181f-c811-46fa-a24c-dcfec9760359	3b6030a2-3993-4389-8c6c-d3427e0e680b	42f00c79-df57-400e-a313-a585d6a36404	in_progress	{}	44.00	2026-05-25 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
f34f2734-12cd-4278-9a05-02a5fa197ce4	4c6d827e-f3db-47d8-be22-4dc4a611c63f	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-03-20 18:31:45.462661+00	2026-03-26 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
b59721a1-b36f-403d-817d-3b08159adf91	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	42f00c79-df57-400e-a313-a585d6a36404	in_progress	{}	72.00	2026-04-07 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
e6dc5762-57b2-4317-9da1-a7319ec0e3ef	2731bad6-8e73-4106-8def-3df5df76b6ea	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-02-14 18:31:45.462661+00	2026-02-20 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
8b311ed4-207f-44fa-a0f1-84e818cc73fb	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-05-26 18:31:45.462661+00	2026-06-01 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
ba597be6-6542-4a9c-9db5-0926806d7902	4d5fd264-452f-4436-8eca-5c6c62afb143	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-09-10 18:31:45.462661+00	2026-09-16 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
ff2864db-8927-44e0-aed8-cdec31f4d3c3	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-06-21 18:31:45.462661+00	2026-06-27 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
7d03da8d-a2ea-4f83-aac9-5224d3cfa493	350093ae-4f68-46a9-a0af-c33a9b87c340	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-09-10 18:31:45.462661+00	2026-09-16 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
a20af338-2eb2-4e6d-87d7-347e6019fff2	7f53c53d-3323-4146-8cea-01d6c38b4f77	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-06-09 18:31:45.462661+00	2026-06-15 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
e24ac918-bbea-4f6a-8c5b-4f5f7fab1a7e	69f12a27-893c-4791-987c-14fb10cbede4	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-08-13 18:31:45.462661+00	2026-08-19 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
c375fa54-70b3-45ce-9709-3eb8a1f46010	46e6d439-49ab-4001-b576-7df03d3babee	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-09-01 18:31:45.462661+00	2026-09-07 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
455148b2-21db-4a0b-939a-65badec90f9a	7e426fed-4c2e-46f4-866a-7b8aa048cf06	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-06-19 18:31:45.462661+00	2026-06-25 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
8114c672-f7c7-4fb8-808f-fa150c828529	9e08ecc2-e291-4516-bae3-07b43abc2620	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-02-08 18:31:45.462661+00	2026-02-14 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
daecdb53-d3d2-46ce-952f-126960283697	3a7984bc-e386-48e4-b988-7d8e086b5317	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-07-21 18:31:45.462661+00	2026-07-27 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
642acfd3-a594-41da-b156-e0b93bc647a8	05a922f4-7a9b-427c-bd4f-34ee3bdcfcf6	42f00c79-df57-400e-a313-a585d6a36404	completed	{}	100.00	2026-04-29 18:31:45.462661+00	2026-05-05 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
cfa67dbf-292c-40b7-ae5d-619a0716da40	e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	42f00c79-df57-400e-a313-a585d6a36404	in_progress	{}	60.00	2026-07-21 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
7b6ea5a8-b096-414d-ad0c-79591b1c39e5	729fd30e-9cfb-4751-bbdb-935fbbb7f994	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-07-23 18:31:45.462661+00	2026-07-29 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
7b71ffc7-5d67-4320-ab66-9267cc5be524	c41e7852-875f-411b-93f1-7171f9871f9f	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-08-13 18:31:45.462661+00	2026-08-19 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
e0a39788-b9b5-4c73-aaa6-d5110ae54ed8	d072273b-7a6f-4fa4-9195-1697050cfab1	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-02-11 18:31:45.462661+00	2026-02-17 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
0af00eef-e3af-4141-bd75-3987b986cbd0	77c70aa0-ddd9-4445-be30-4817de1cbfd0	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-05-23 18:31:45.462661+00	2026-05-29 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
c09a51c1-d8a4-4515-a62e-99b0f2a0b460	a6d5837e-0df4-4cf0-9c98-8f0da7e4a1f1	486ae347-6271-439f-9865-ebaf1e4d93cd	in_progress	{}	70.00	2026-08-28 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
c4e2c974-f016-4ef4-bff5-310af8588685	d22f23cf-8a58-499a-8dba-92806f1622ef	486ae347-6271-439f-9865-ebaf1e4d93cd	in_progress	{}	66.00	2026-08-29 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
2f1f20a7-d1da-4fe8-a27c-e0a04b6a523a	ec4cdace-5f9a-4198-9518-7c59753a1127	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-02-16 18:31:45.462661+00	2026-02-22 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
073d703f-4350-4bd7-8bda-8cfcd7ec8332	8a0a7128-e6e6-4b49-8395-52723dda0b7c	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-05-17 18:31:45.462661+00	2026-05-23 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
7eec12b9-51c2-4523-b812-0f2ae475a5d8	216136af-8b6b-44ae-a787-59506613a618	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-03-23 18:31:45.462661+00	2026-03-29 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
4a5a338b-dc27-445d-8f15-f8465c364e48	7f53c53d-3323-4146-8cea-01d6c38b4f77	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-03-18 18:31:45.462661+00	2026-03-24 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
b00a152a-991e-4643-ac1c-e738ae3d3d73	8a1eab45-738c-41b6-b35d-7737f5e2f64e	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-06-16 18:31:45.462661+00	2026-06-22 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
fda410a1-9e83-4c20-9b03-d1acc1730636	28fe79f0-6207-4e0c-8bae-1eb02eed759b	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-07-22 18:31:45.462661+00	2026-07-28 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
e064db09-b4af-4ab0-b92c-b948cc2082d1	3d87692f-06c1-4403-95ff-c70d1598700a	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-04-09 18:31:45.462661+00	2026-04-15 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
799a6e30-13c3-49d7-b9cb-e17c1e50e40c	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-07-26 18:31:45.462661+00	2026-08-01 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
22137d58-bb6e-4684-ac71-af5834fa91b8	ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-06-29 18:31:45.462661+00	2026-07-05 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
46371ecb-ab8d-48cb-9551-ce4e65e40d49	c43722c6-7e70-49e0-acb4-ba4f953e36a8	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-05-06 18:31:45.462661+00	2026-05-12 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
84653a4b-a983-41ef-a5e2-63952c4d3c8c	7e426fed-4c2e-46f4-866a-7b8aa048cf06	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-05-08 18:31:45.462661+00	2026-05-14 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
92f3efa8-5520-4669-865b-911e9acb8bf4	cbd81a81-1d5a-4273-8494-11efdd5fd354	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-05-27 18:31:45.462661+00	2026-06-02 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
6685b5c2-c445-437f-8982-088acbb2aaf6	e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-03-11 18:31:45.462661+00	2026-03-17 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
6d9ef8ce-4516-477d-a377-d9378e3e706d	fafec148-becc-4918-b1e0-08794a94f6de	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-05-30 18:31:45.462661+00	2026-06-05 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
1b23ac5e-6cfa-4a85-af45-31156ae0a0d4	357f9f29-063f-4ff8-bdc9-6df1d8cb15b4	486ae347-6271-439f-9865-ebaf1e4d93cd	in_progress	{}	61.00	2026-07-02 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
544df9a3-32b5-4e47-b4d7-78496bc2d2f5	c41a5544-af25-44ec-9fab-26fa3a4e08a5	486ae347-6271-439f-9865-ebaf1e4d93cd	in_progress	{}	45.00	2026-02-19 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
64b43b10-758e-42ba-801c-ddc879155c24	0d37acee-70ea-4604-8bd7-c995941443fd	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-09-15 18:31:45.462661+00	2026-09-21 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
b71a1063-1a8a-47f3-b9aa-d80b034c1ef4	625944b1-2b9b-433b-9af5-e72894aa7a58	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-04-27 18:31:45.462661+00	2026-05-03 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
4ec14f17-b5da-42fa-a1ba-68a31ed24914	3af00a36-1f7b-4846-a52a-b1871416c5b1	486ae347-6271-439f-9865-ebaf1e4d93cd	in_progress	{}	86.00	2026-08-14 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
fc61ec7a-1ed9-4cea-a089-193b931f37f1	4ead5d1f-209d-4c0f-950b-80d8668a696b	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-02-14 18:31:45.462661+00	2026-02-20 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
35624d3f-0860-4653-95f6-31889b1146ed	4135122d-a240-499c-8de4-3db650d7acc9	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-06-25 18:31:45.462661+00	2026-07-01 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
ac1768e2-844c-4518-941b-f421bc6011dd	9389e5a2-816f-4e52-950b-a9af117c7ad1	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-06-20 18:31:45.462661+00	2026-06-26 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
d7355fc7-c701-4728-9c74-982a8a2841ce	d2298ed0-2515-4232-b70f-845a98dac595	486ae347-6271-439f-9865-ebaf1e4d93cd	completed	{}	100.00	2026-02-08 18:31:45.462661+00	2026-02-14 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
784cfb85-58ed-43d3-8623-2e0c437dd3bc	286bd41d-35d4-4b43-b05b-8548dab978ab	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	64.00	2026-03-14 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
adfef54a-a432-4193-b690-8a1d64972414	3a7984bc-e386-48e4-b988-7d8e086b5317	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	81.00	2026-06-21 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
e19df9f0-e323-4a83-8a4b-024f240c0794	feb2fb92-ce04-48c5-8a5f-9d2e832d1644	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	69.00	2026-03-12 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
ba4b9b31-5e84-4753-93a6-5c2e04ddb92e	428cfba8-2dbb-45f6-844d-a309e2cdbd40	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	58.00	2026-04-30 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
4af9bcad-a065-43a1-8903-c705dca537c7	7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	377c54d8-88d8-4698-a98c-27a42d2dae92	completed	{}	100.00	2026-08-15 18:31:45.462661+00	2026-08-21 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
63a3f7ea-8b78-4800-ae70-036377ffd068	032c01d5-4b5e-44f6-821d-2ba4342c938f	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	75.00	2026-04-07 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
3d651e61-53de-4da6-936a-51c88c2241fb	55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	73.00	2026-02-25 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
ec0d67ba-05e4-49ad-bdfc-fe058f822d4d	1f511b5e-1292-4202-860e-b54f11eda21e	377c54d8-88d8-4698-a98c-27a42d2dae92	completed	{}	100.00	2026-09-15 18:31:45.462661+00	2026-09-21 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
031428f8-7efb-456d-b928-c05f3937432f	6d6f1209-693c-409d-9587-ed4e04d77930	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	55.00	2026-05-31 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
36c311ea-2875-4017-adb0-7718c3246aba	b2c7b829-9669-4258-ab45-acc4445b9d6d	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	65.00	2026-04-06 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
6a7295f8-50d8-481d-8728-5f75399a65f6	2731bad6-8e73-4106-8def-3df5df76b6ea	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	89.00	2026-07-18 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
ca1f1ff0-be6f-4c82-9001-c8f06e580d5a	cd441b90-ef66-411c-b22e-4e046c29677f	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	70.00	2026-05-01 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
0e9c9a6c-6069-4472-beb9-33de88cdc57c	8a83194a-d3bc-49dd-8594-ed05a26d23a0	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	71.00	2026-03-29 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
93914260-4bff-4925-95a7-efc07ed297f2	90a570b4-9441-4d8b-981d-a7fa379054d3	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	79.00	2026-02-27 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
bf586382-90e2-47f0-a6e2-66cc899fc11d	f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d	377c54d8-88d8-4698-a98c-27a42d2dae92	completed	{}	100.00	2026-03-31 18:31:45.462661+00	2026-04-06 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
68f47311-0964-4086-a303-8644c22dfb93	8a1eab45-738c-41b6-b35d-7737f5e2f64e	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	71.00	2026-09-04 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
399d53da-f77c-4a3d-a909-a7c714d7a720	f74aaa72-56ba-476d-9aed-ffbe2e41dd50	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	62.00	2026-05-05 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
f307fd22-b9b7-4f92-8976-c50ec53a4b79	6f9f3af8-fa88-4804-aa9b-5680afa4c1ba	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	51.00	2026-03-28 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
52b60876-3022-41ba-9dd4-82a7e3badbcb	7b68a9ad-6ab1-4164-89e4-b13eea948a92	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	43.00	2026-05-06 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
bdf67c50-1e09-4e67-a00f-2e12d8057784	edc1993b-5333-4d99-bae2-9e80266978e0	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	62.00	2026-02-20 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
02cc4f0a-23cf-4168-81b6-0f04da3366e5	a17abc66-209e-405f-bcd6-c39e54cbce66	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	77.00	2026-08-29 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
28080ed9-f006-420c-93f4-4b16eac3c542	bd78a83d-5740-4d0d-9000-cdf29d332f27	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	73.00	2026-06-07 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
958efdf5-64d8-46f5-878d-fe837ab0fc84	62868b88-e860-457b-8605-04153588489b	377c54d8-88d8-4698-a98c-27a42d2dae92	in_progress	{}	88.00	2026-07-08 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
331a226c-04ee-46da-ad87-7713df6f5c39	9bab5f84-a53e-49d6-91f8-eef87bf5960c	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-05-07 18:31:45.462661+00	2026-05-13 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
0cad093c-d94d-44e6-8c2a-a425174f68af	3b6030a2-3993-4389-8c6c-d3427e0e680b	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-08-05 18:31:45.462661+00	2026-08-11 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
38632a5e-327f-4f9b-8d4e-9bbf8ba05586	a8c5b60b-8763-4325-900d-07d7540e6015	1b09caa2-5a18-4f05-9a17-18d849ee499f	in_progress	{}	55.00	2026-05-19 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
1e6c0168-dfa9-4976-bf77-cbb861edad4c	707e086b-3312-442d-ac6d-9776ebe73deb	1b09caa2-5a18-4f05-9a17-18d849ee499f	in_progress	{}	78.00	2026-09-14 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
1e123daf-856a-444a-a8fb-440731a235dc	3d87692f-06c1-4403-95ff-c70d1598700a	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-04-05 18:31:45.462661+00	2026-04-11 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
9bd1efd2-d395-4c8d-943e-ce8731fc61db	a17abc66-209e-405f-bcd6-c39e54cbce66	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-05-12 18:31:45.462661+00	2026-05-18 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
f2d20381-dae2-4187-87c3-f79bcad3a29c	9389e5a2-816f-4e52-950b-a9af117c7ad1	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-05-14 18:31:45.462661+00	2026-05-20 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
082de00e-c610-4ad9-b886-024543f17607	a5e41a1c-9682-4873-8924-f11edf9b3fce	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-02-26 18:31:45.462661+00	2026-03-04 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
4639d846-4c72-49ed-ba4a-55cdde1515d6	b2734396-c5d2-4b05-99d0-986a180a98a6	1b09caa2-5a18-4f05-9a17-18d849ee499f	in_progress	{}	59.00	2026-03-16 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
f77c73d8-1423-4a03-b580-cb2cf2131da0	2c310487-b2d2-4f8a-bdc3-0fcd75eff4a9	1b09caa2-5a18-4f05-9a17-18d849ee499f	in_progress	{}	55.00	2026-09-14 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
9d85f483-fe80-40cc-8bb6-e52ec7853651	4acb1924-e6ec-428c-8401-ac05f87e2bbf	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-08-07 18:31:45.462661+00	2026-08-13 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
6045805b-b8e4-4c2a-91ff-d2849fe8e8e8	d05292f5-3e9f-4e51-bb50-05a6534dc9b8	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-06-29 18:31:45.462661+00	2026-07-05 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
13c8e727-23af-4466-9e2a-f4ad1084ee9b	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-02-08 18:31:45.462661+00	2026-02-14 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
634b463d-f4d5-41d5-9b46-c592c84e07e1	30e16278-0ca1-4efa-a03b-7168658bb2c2	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-08-12 18:31:45.462661+00	2026-08-18 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
f47e1eb9-1e5d-43b5-8e5f-d1f165ee1ce7	b010ad34-1872-4015-9120-b4d6e175bda3	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-09-01 18:31:45.462661+00	2026-09-07 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
a91b0f53-7171-4022-a2ef-915d95e09d7e	e44fe06d-6034-4f79-a75c-79ab0f2b58df	1b09caa2-5a18-4f05-9a17-18d849ee499f	in_progress	{}	73.00	2026-05-10 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
96927b62-755a-4feb-bacd-fb966d58a9f7	88b2de0e-fb93-4402-98ef-3c1bd149f61d	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-05-29 18:31:45.462661+00	2026-06-04 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
0d2134d9-2320-4ad9-9379-a22f7621e43f	f1831789-130e-485d-bc67-67fe3b5fc6af	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-05-16 18:31:45.462661+00	2026-05-22 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
315b2a02-97fe-48d9-8f74-b66e4b6f1cde	a5fd318c-feeb-4b1b-b739-3e40a59dde18	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-06-25 18:31:45.462661+00	2026-07-01 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
787fd8fe-71a4-46c2-acca-76fc9e72b1d2	ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-06-05 18:31:45.462661+00	2026-06-11 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
12548d66-253b-45e2-8aae-b501d574ee45	286bd41d-35d4-4b43-b05b-8548dab978ab	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-08-29 18:31:45.462661+00	2026-09-04 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
dcdb7bac-9754-4a16-9c72-a0a29bf0ee08	6b116d7e-84ed-47de-81ea-2bd42ea50968	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-04-22 18:31:45.462661+00	2026-04-28 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
b2b9a177-03ae-4a4f-9a92-8bbe877e3b85	312e5b6a-024a-4a5d-9389-357b73426d42	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-03-17 18:31:45.462661+00	2026-03-23 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
8f527347-6e47-4660-a036-41a143c235bd	732e74cf-b9b7-4adc-a43a-794430d7fe49	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-02-12 18:31:45.462661+00	2026-02-18 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
ab8ac965-2d86-4050-a92b-e871ca0a692b	4135122d-a240-499c-8de4-3db650d7acc9	1b09caa2-5a18-4f05-9a17-18d849ee499f	in_progress	{}	43.00	2026-03-04 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
6df0e517-9b3f-4c94-8444-a3ea8f094413	cc7120df-7364-4284-a971-893f524d1a25	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-07-30 18:31:45.462661+00	2026-08-05 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
0508d6c6-58f3-476b-894c-05acd6ff13d2	a4e9e21f-10e4-4c84-b4d0-9f420cf171c0	1b09caa2-5a18-4f05-9a17-18d849ee499f	in_progress	{}	73.00	2026-07-12 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
f5cbd04e-96fa-4170-ac8a-e9d58cad23d7	c41a5544-af25-44ec-9fab-26fa3a4e08a5	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-08-22 18:31:45.462661+00	2026-08-28 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
2b0c4c7d-8e57-44a6-9091-f1a2a599695f	f51dbbc6-5c8a-487d-b785-786417797dc8	1b09caa2-5a18-4f05-9a17-18d849ee499f	completed	{}	100.00	2026-03-13 18:31:45.462661+00	2026-03-19 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
3fe32710-d493-464c-a014-4668cfc33109	a8c5b60b-8763-4325-900d-07d7540e6015	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	55.00	2026-07-31 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
781d9170-8fde-4920-86b2-84942db8faae	7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	41.00	2026-08-20 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
8d9b92e1-3080-44d3-8e0c-64595280cdf0	8ffbd0cf-b807-4193-af37-3a61482c76eb	614b89b9-ad9a-4481-9970-4691dd4e45dc	completed	{}	100.00	2026-09-07 18:31:45.462661+00	2026-09-13 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
d08beaf1-9026-4550-8079-a675cf118333	f74aaa72-56ba-476d-9aed-ffbe2e41dd50	614b89b9-ad9a-4481-9970-4691dd4e45dc	completed	{}	100.00	2026-02-27 18:31:45.462661+00	2026-03-05 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
656f5a59-294c-42d4-bf4c-734a74c6231c	6f1d6dd6-daa9-4660-a06f-527bf32f663e	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	50.00	2026-05-12 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
2bcc7c39-6836-4e04-939e-cd26717cd77c	d05292f5-3e9f-4e51-bb50-05a6534dc9b8	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	59.00	2026-05-20 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
b3d3cd9b-77e3-4424-99a7-c4a8a72899f4	8be014b0-ed46-43db-89e2-91a301c618db	614b89b9-ad9a-4481-9970-4691dd4e45dc	completed	{}	100.00	2026-08-02 18:31:45.462661+00	2026-08-08 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
c5e2ce20-584a-436c-98eb-a8a7c2df173f	1e418187-2717-4b94-934c-e5ca025993d8	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	77.00	2026-08-14 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
1287250a-1285-45dd-bec8-232a630c5287	b0ba69f7-69ce-411c-a22d-c449785d11e9	614b89b9-ad9a-4481-9970-4691dd4e45dc	completed	{}	100.00	2026-06-07 18:31:45.462661+00	2026-06-13 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
93b57788-0088-429a-892d-a836e5d85155	48ae8c9d-e783-46c2-abf3-cc9d31e16d81	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	78.00	2026-04-14 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
137a2cb2-b4cc-4831-9823-b6bfab8b5535	7b68a9ad-6ab1-4164-89e4-b13eea948a92	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	62.00	2026-02-26 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
39cc4453-c387-4f86-87ae-354e695cebcc	62868b88-e860-457b-8605-04153588489b	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	43.00	2026-02-25 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
d4c62c73-74ff-436a-a09f-a69c7f53887b	4135122d-a240-499c-8de4-3db650d7acc9	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	82.00	2026-08-04 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
67d0578d-7043-44d2-b92c-2cf7c04de5c3	76e808de-304b-44e5-b793-8516b5fec7bb	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	80.00	2026-06-08 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
0acaa4f6-a0bb-47bf-9268-02104d0bea5b	e6ef6d8e-87f0-4c3d-8ac9-dccb12f222f1	614b89b9-ad9a-4481-9970-4691dd4e45dc	completed	{}	100.00	2026-08-13 18:31:45.462661+00	2026-08-19 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
64eff6d8-0e3f-4275-8b9e-e77eaf6eb9e2	cc9e83f0-d177-4454-8ba5-f7581c6da639	614b89b9-ad9a-4481-9970-4691dd4e45dc	completed	{}	100.00	2026-06-22 18:31:45.462661+00	2026-06-28 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
3b4c68cd-6cee-4f97-8e5f-5b8c6a341660	5d1e34b1-8861-4358-96e3-f5ed89f5c9d2	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	81.00	2026-03-14 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
aac5213a-c549-4138-a1db-86692e0197aa	3260915b-2633-418b-997d-2beabd07ed2b	614b89b9-ad9a-4481-9970-4691dd4e45dc	completed	{}	100.00	2026-07-15 18:31:45.462661+00	2026-07-21 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
0958ff37-f958-4052-89e2-d707d1672db1	fba30b27-7555-43f7-8c74-b84e722ebbc8	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	82.00	2026-08-09 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
58b6fd10-7b76-412d-b644-07ea1105feb9	8b09383e-447b-4fa0-b605-8d8cf4f3f527	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	68.00	2026-06-30 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
4b18e720-c770-4cf1-b3ba-3aa6e1c0d735	4c6d827e-f3db-47d8-be22-4dc4a611c63f	614b89b9-ad9a-4481-9970-4691dd4e45dc	completed	{}	100.00	2026-06-19 18:31:45.462661+00	2026-06-25 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
cc86626b-2676-4815-a467-a773fdbb6190	ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	614b89b9-ad9a-4481-9970-4691dd4e45dc	completed	{}	100.00	2026-07-03 18:31:45.462661+00	2026-07-09 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
192ddc9c-229c-4783-bb81-8522af62e43e	4ace2ecd-317e-494c-ad50-71e2794fb907	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	44.00	2026-04-21 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
49650e12-9c07-4381-bdaf-852c1c15f323	d072273b-7a6f-4fa4-9195-1697050cfab1	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	61.00	2026-09-14 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
2180b412-4326-4458-8ee0-012152792ec4	696886f6-a4bf-44a6-9ba9-c939abb52137	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	97.00	2026-08-18 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
8f0ee274-87f3-4339-991a-e533dfc67318	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	79.00	2026-07-12 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
e84872c6-0c83-4d81-b957-6dcd7c4c4d13	6ec3f843-359c-4b5b-bc41-b3bd56c6e134	614b89b9-ad9a-4481-9970-4691dd4e45dc	completed	{}	100.00	2026-02-17 18:31:45.462661+00	2026-02-23 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
7e98fa7a-0804-427b-a6df-e795ed320fda	a6d5837e-0df4-4cf0-9c98-8f0da7e4a1f1	614b89b9-ad9a-4481-9970-4691dd4e45dc	in_progress	{}	60.00	2026-02-27 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
9498b0cf-27eb-4f74-873b-5a4d92340d4c	f75210c9-faa1-45c8-9314-a65724983502	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-04-05 18:31:45.462661+00	2026-04-11 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
01dddaf8-d94c-4f56-8567-81c4d4a8f646	cf4749a6-6127-4d97-b2a0-17a11eabc216	6be0b4cc-255a-4372-be78-8bd23dee561b	in_progress	{}	50.00	2026-09-08 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
8ade1740-10cd-4771-9fe8-18f599882543	a5fd318c-feeb-4b1b-b739-3e40a59dde18	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-05-07 18:31:45.462661+00	2026-05-13 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
62a44d5e-f950-4a89-a85f-4234d849e521	a6afe850-9547-4fac-892c-00558ad8f725	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-06-13 18:31:45.462661+00	2026-06-19 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
c1a8999e-e0c8-4430-a308-2b7d588904bf	b97db5e7-dca3-4f88-8318-6d457e09be91	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-05-07 18:31:45.462661+00	2026-05-13 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
2e3a4f7b-f81f-4e21-a73e-c4110ae00d26	48ae8c9d-e783-46c2-abf3-cc9d31e16d81	6be0b4cc-255a-4372-be78-8bd23dee561b	in_progress	{}	58.00	2026-04-17 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
ef653898-4165-4bca-89d6-1d996360a4ed	ec4cdace-5f9a-4198-9518-7c59753a1127	6be0b4cc-255a-4372-be78-8bd23dee561b	in_progress	{}	44.00	2026-09-07 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
aee21e84-d56c-4ba3-bdaf-761c85addbb6	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-08-01 18:31:45.462661+00	2026-08-07 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
5f2879c4-d13e-4529-bdcb-31f6ed738e31	625944b1-2b9b-433b-9af5-e72894aa7a58	6be0b4cc-255a-4372-be78-8bd23dee561b	in_progress	{}	43.00	2026-07-21 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
8f9ff438-dcc7-4d48-8cca-d388e82fa574	e888ad9f-c064-4d24-8143-eec67fac7c1c	6be0b4cc-255a-4372-be78-8bd23dee561b	in_progress	{}	82.00	2026-06-06 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
470cd3ee-f64f-4d47-a17c-859708f87ac7	8a0a7128-e6e6-4b49-8395-52723dda0b7c	6be0b4cc-255a-4372-be78-8bd23dee561b	in_progress	{}	66.00	2026-04-10 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
0f1d8cb1-ca68-4651-8ef5-577f2d4ce3d9	b2734396-c5d2-4b05-99d0-986a180a98a6	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-06-01 18:31:45.462661+00	2026-06-07 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
429db28d-617b-472a-9af3-e0cf6802fb71	3d04f1c2-2486-4f53-bde5-76ba389ec266	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-03-26 18:31:45.462661+00	2026-04-01 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
09a44e37-05b2-47d9-95f0-1660b09b5304	e44fe06d-6034-4f79-a75c-79ab0f2b58df	6be0b4cc-255a-4372-be78-8bd23dee561b	in_progress	{}	81.00	2026-02-11 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
5d9c894a-1c44-42c1-aeef-f3124dfbc0fb	3a18a01e-89f7-474e-abf1-964581203793	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-08-29 18:31:45.462661+00	2026-09-04 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
063268f7-ec3a-48d2-aa92-5e80c666297d	08758984-558b-4323-bc35-2a202203d87b	6be0b4cc-255a-4372-be78-8bd23dee561b	in_progress	{}	43.00	2026-07-28 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
1887d5d8-9896-4daa-817d-647301b36be4	78313b75-0494-43a4-b199-ff1928254f44	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-05-04 18:31:45.462661+00	2026-05-10 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
681df2cc-4c58-46f1-bd8a-977ce803d6c6	10e55ead-3752-4108-a6b5-5a48ee709f03	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-04-24 18:31:45.462661+00	2026-04-30 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
c16af279-c576-405f-b975-fb76ce4a7393	f8cb8b17-b65c-4df2-baab-62604c96a8c0	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-07-04 18:31:45.462661+00	2026-07-10 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
99ae11f2-9c5a-425c-9e92-63bf4a711186	76e808de-304b-44e5-b793-8516b5fec7bb	6be0b4cc-255a-4372-be78-8bd23dee561b	in_progress	{}	77.00	2026-07-08 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
deea9de5-fa7c-42b2-81e9-d61f792874fc	a5e41a1c-9682-4873-8924-f11edf9b3fce	6be0b4cc-255a-4372-be78-8bd23dee561b	in_progress	{}	76.00	2026-05-14 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
ca0239e6-0043-4952-9161-33a6f8edb4bb	e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-03-19 18:31:45.462661+00	2026-03-25 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
bc965598-2b5c-45c8-9860-ce19fc8706a8	ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-07-02 18:31:45.462661+00	2026-07-08 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
a00b5e78-dc85-4b78-91b3-7da74026613c	18407190-2219-4190-9b20-ee775b0094ef	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-03-31 18:31:45.462661+00	2026-04-06 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
cfb220ae-a8d8-4f41-a4e7-0804ee5c80d1	28fe79f0-6207-4e0c-8bae-1eb02eed759b	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-06-22 18:31:45.462661+00	2026-06-28 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
ce59f071-0a5e-4a75-b9bc-a9c18b38ee51	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-06-07 18:31:45.462661+00	2026-06-13 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
fdbce967-d5ca-4651-9514-be1e0d0f7a09	55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	6be0b4cc-255a-4372-be78-8bd23dee561b	completed	{}	100.00	2026-05-26 18:31:45.462661+00	2026-06-01 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
5ed7581f-a3aa-4dfd-9373-2625d625c77c	a7bae3c0-0e2c-42db-8e35-79114d5dfe80	eec7cc46-3395-4f21-8c7f-cb99bee58b55	in_progress	{}	49.00	2026-08-04 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
5273cfbe-de5f-4f84-985b-a90970501d19	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-02-26 18:31:45.462661+00	2026-03-04 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
024d7c57-f181-4492-88fb-e2eb31622529	78313b75-0494-43a4-b199-ff1928254f44	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-07-29 18:31:45.462661+00	2026-08-04 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
669663f8-1a7c-45e7-916a-275e746e56cc	f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-08-17 18:31:45.462661+00	2026-08-23 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
b46a12e9-d4b3-498a-96b3-56e3cd784292	62868b88-e860-457b-8605-04153588489b	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-03-08 18:31:45.462661+00	2026-03-14 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
996a79dd-6e64-4727-864c-9d21bce49ad1	c43722c6-7e70-49e0-acb4-ba4f953e36a8	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-08-05 18:31:45.462661+00	2026-08-11 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
6512a51c-6b77-43e6-a80b-67046f0b165d	3ded69a7-290c-47f6-bd29-7369f6f8e3c8	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-07-09 18:31:45.462661+00	2026-07-15 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
ba812071-aa59-409a-8e0c-987c7addea18	3af00a36-1f7b-4846-a52a-b1871416c5b1	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-08-01 18:31:45.462661+00	2026-08-07 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
dd26475e-bd6f-4c71-8675-ec788f496856	fbc637df-19cd-4ec5-b08d-49ce15747076	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-06-08 18:31:45.462661+00	2026-06-14 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
df0456c9-0468-4a1e-8efa-735277743de1	b2c7b829-9669-4258-ab45-acc4445b9d6d	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-05-24 18:31:45.462661+00	2026-05-30 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
a86bb307-106f-418f-aa44-338b331ef33b	a5102b13-4107-4fe5-b7a0-064dd07042ee	eec7cc46-3395-4f21-8c7f-cb99bee58b55	in_progress	{}	66.00	2026-08-21 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
a0b57f0b-9ddf-4c68-b1c8-1fa6a97b4fa7	6ec3f843-359c-4b5b-bc41-b3bd56c6e134	eec7cc46-3395-4f21-8c7f-cb99bee58b55	in_progress	{}	99.00	2026-07-07 18:31:45.462661+00	\N	2026-09-16 18:31:45.462661+00
551e1cb8-9d92-4961-ad43-9c6ada81b06a	216136af-8b6b-44ae-a787-59506613a618	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-02-09 18:31:45.462661+00	2026-02-15 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
589135bf-8566-4d54-abc3-7d2fd87ea6d9	caf34c22-6898-4c15-bde0-08f3d2634d41	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-02-25 18:31:45.462661+00	2026-03-03 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
aa26717a-a560-48be-ad99-2e31b3f10662	a6f0ed93-9d6b-4592-a13e-5435550b4db2	eec7cc46-3395-4f21-8c7f-cb99bee58b55	in_progress	{}	95.00	2026-07-25 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
1ef21f06-72bb-4431-86c4-cc3f53418259	72a5ceb8-6b68-433d-9b99-d62b8c9f1375	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-05-24 18:31:45.462661+00	2026-05-30 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
fd3e89cc-0ae0-4c37-a91f-ab64042cf658	a17abc66-209e-405f-bcd6-c39e54cbce66	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-06-03 18:31:45.462661+00	2026-06-09 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
992f4518-bf25-4811-8d45-42dc2c2c5ace	10e55ead-3752-4108-a6b5-5a48ee709f03	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-07-17 18:31:45.462661+00	2026-07-23 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
326f8cb2-fcf3-48d8-9e92-a69df039b876	fda17094-1c9f-45de-a42c-aa815d09bc2a	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-07-31 18:31:45.462661+00	2026-08-06 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
39ecdeaf-ee06-41bf-aff8-b6033a52b787	cc7120df-7364-4284-a971-893f524d1a25	eec7cc46-3395-4f21-8c7f-cb99bee58b55	in_progress	{}	40.00	2026-02-26 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
c90f0faf-7282-4ab2-bd4b-428081c8bf08	2d970758-319c-400f-b2ba-93057f16a33e	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-03-29 18:31:45.462661+00	2026-04-04 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
2c9a020a-98e5-41f9-989e-8baca397d70c	48ae8c9d-e783-46c2-abf3-cc9d31e16d81	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-08-19 18:31:45.462661+00	2026-08-25 18:31:45.462661+00	2026-09-21 18:31:45.462661+00
ec15b829-ec8c-45ca-a40b-4dd01926d0b2	db9ec5a1-d0be-490d-91a6-bf32127bba75	eec7cc46-3395-4f21-8c7f-cb99bee58b55	in_progress	{}	40.00	2026-09-05 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
80c0aecc-fc44-4441-9138-f3e0ba6742e9	b28e0245-9390-4127-ad3f-80ace4775f43	eec7cc46-3395-4f21-8c7f-cb99bee58b55	in_progress	{}	72.00	2026-07-05 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
f2dd16c7-7057-4c8d-a3e0-2932115f3ec0	fc08ec35-be50-46ec-8acb-0ddb68b16b22	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-04-03 18:31:45.462661+00	2026-04-09 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
de47e4cc-062d-4813-b9bf-67fef41b6c81	33f73596-75e6-435e-94f5-d5b111a6aaf5	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-06-24 18:31:45.462661+00	2026-06-30 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
f825cd09-ae68-4639-9f4b-302ef5ff49dc	3ecf9082-92fa-49e4-a15f-87acb5504803	eec7cc46-3395-4f21-8c7f-cb99bee58b55	completed	{}	100.00	2026-05-28 18:31:45.462661+00	2026-06-03 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
7aa416ed-7e8c-4801-9bb1-c2fe24a1c024	69f12a27-893c-4791-987c-14fb10cbede4	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	in_progress	{}	87.00	2026-03-06 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
16ffe8b6-0ea5-4f14-9519-98b80a8a26b0	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	completed	{}	100.00	2026-02-17 18:31:45.462661+00	2026-02-23 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
0d40bb20-2940-4a05-b826-82f07ca4f475	2731bad6-8e73-4106-8def-3df5df76b6ea	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	in_progress	{}	47.00	2026-05-13 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
24bcf3bf-8458-475c-b4e9-23e1f98e6bf4	62868b88-e860-457b-8605-04153588489b	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	completed	{}	100.00	2026-07-04 18:31:45.462661+00	2026-07-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
e986d8ee-43e8-4a42-b150-a3948033d83d	0f80298a-f569-4c55-88aa-a57625e20751	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	in_progress	{}	90.00	2026-08-19 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
90397aab-61f7-4f04-8b0e-d689878a9811	306af47d-26b6-4dc3-96ae-eb178609c1f6	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	in_progress	{}	47.00	2026-04-13 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
8334776e-c326-4fa5-8bb9-cbf3eab62c5b	ab903484-298e-4415-93b0-8f5ea844bf31	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	in_progress	{}	76.00	2026-08-04 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
88526893-179c-4dca-bf5a-b345e73c3c38	77c70aa0-ddd9-4445-be30-4817de1cbfd0	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	completed	{}	100.00	2026-08-15 18:31:45.462661+00	2026-08-21 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
a6b13fb6-632c-42e0-9528-6a43f2434dbd	216136af-8b6b-44ae-a787-59506613a618	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	in_progress	{}	86.00	2026-04-10 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
3e7b3fe7-e513-48c8-975f-3367bfea154e	f04f9044-cd22-4a29-8d93-333047a95f6a	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	completed	{}	100.00	2026-06-12 18:31:45.462661+00	2026-06-18 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
8d7e0f07-449e-4b49-9cf9-f9adf686643a	4ace2ecd-317e-494c-ad50-71e2794fb907	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	in_progress	{}	96.00	2026-07-12 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
fa40651d-314b-4103-8183-9b109c607dd5	2af59a77-c993-46c3-a686-b91217814d48	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	completed	{}	100.00	2026-05-21 18:31:45.462661+00	2026-05-27 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
9bc06dc4-9258-4b11-8187-f58eb3123c4d	5abfd2bf-a622-4ac2-8867-2be6525ec0e8	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	completed	{}	100.00	2026-05-20 18:31:45.462661+00	2026-05-26 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
6ed427dc-d145-4ffa-92ea-e17b462ac7c8	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	completed	{}	100.00	2026-02-15 18:31:45.462661+00	2026-02-21 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
6c5225b4-7ec9-4489-9ee4-f20410cd1ac5	4d5fd264-452f-4436-8eca-5c6c62afb143	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	in_progress	{}	66.00	2026-09-10 18:31:45.462661+00	\N	2026-09-16 18:31:45.462661+00
c6d592f3-75cc-40fd-bbd5-99a64a74e050	3d87692f-06c1-4403-95ff-c70d1598700a	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	completed	{}	100.00	2026-03-25 18:31:45.462661+00	2026-03-31 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
d0ba9281-7c5f-4fca-84f5-0890e8e8c65c	1eb0cec9-a12f-4f42-9d77-bf6e343e9a75	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	completed	{}	100.00	2026-08-19 18:31:45.462661+00	2026-08-25 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
9827d949-50c4-4ea6-af10-5967e25b2633	2d970758-319c-400f-b2ba-93057f16a33e	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	in_progress	{}	96.00	2026-05-30 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
803b37af-71e9-474c-8457-5f1d5ebdb457	9389e5a2-816f-4e52-950b-a9af117c7ad1	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	in_progress	{}	97.00	2026-08-06 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
cc06ab77-4a1c-46e9-ad9c-8d9aa1b0a460	10e55ead-3752-4108-a6b5-5a48ee709f03	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	in_progress	{}	64.00	2026-04-09 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
f31fdada-512e-42fe-ad6e-724e0b9916e8	b0ba69f7-69ce-411c-a22d-c449785d11e9	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	in_progress	{}	47.00	2026-08-04 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
c86290bc-5990-4e5d-9a8c-bc5eff5f67e6	33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	80.00	2026-04-26 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
6f19b46c-8baf-4a00-8f92-dc11cd3f1693	0d37acee-70ea-4604-8bd7-c995941443fd	3d04c87e-b5ec-45e8-951e-4bb279977080	completed	{}	100.00	2026-08-17 18:31:45.462661+00	2026-08-23 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
b00bf708-3758-4235-a728-54554f8c97cc	2731bad6-8e73-4106-8def-3df5df76b6ea	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	74.00	2026-07-22 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
0b2b51cd-5d38-4e2e-baa4-7953fc1bfc05	8be014b0-ed46-43db-89e2-91a301c618db	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	93.00	2026-03-08 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
b57eeccf-ea68-4b8a-bc57-d4598821eab3	8a83194a-d3bc-49dd-8594-ed05a26d23a0	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	51.00	2026-06-15 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
c537a4b7-6ed2-47d6-92ca-9a363c309769	9bab5f84-a53e-49d6-91f8-eef87bf5960c	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	95.00	2026-04-12 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
c1700524-cd5e-43a9-a720-5d7cab4345ba	8b09383e-447b-4fa0-b605-8d8cf4f3f527	3d04c87e-b5ec-45e8-951e-4bb279977080	completed	{}	100.00	2026-03-17 18:31:45.462661+00	2026-03-23 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
e5b91786-5da9-4ecd-8c73-1515832eea2f	b8541832-74c6-404f-90d0-5fb6d3df7663	3d04c87e-b5ec-45e8-951e-4bb279977080	completed	{}	100.00	2026-02-21 18:31:45.462661+00	2026-02-27 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
022863cf-570d-4a3a-8f26-2f30a2eac82b	032c01d5-4b5e-44f6-821d-2ba4342c938f	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	43.00	2026-04-17 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
3ddfcecf-c0c4-4abe-9836-4acf05762ae4	48f33e15-f87f-4629-ab82-4123ada4bdc4	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	88.00	2026-03-09 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
2d33274c-70da-43f9-af43-34a59e2fa324	28fe79f0-6207-4e0c-8bae-1eb02eed759b	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	96.00	2026-08-24 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
4e675719-111b-4be0-ae82-ea02cd42bbee	d2298ed0-2515-4232-b70f-845a98dac595	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	54.00	2026-07-25 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
cee854b8-9bf4-4691-ba3c-8942e500a42c	7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	88.00	2026-03-01 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
d498fe5e-7755-4ef4-b4dc-8039c9421607	55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	98.00	2026-04-12 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
804c62b9-ba87-4aa2-a727-84e8421b233b	60e67627-9116-4358-a94b-89c0416805f0	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	58.00	2026-04-21 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
dea6064f-6b26-4e97-9943-82be46cfdc41	65ef229b-117d-4946-b5bb-301e3f828fc2	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	67.00	2026-04-27 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
a221983f-9633-438a-a653-cb6bc775cf25	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	3d04c87e-b5ec-45e8-951e-4bb279977080	completed	{}	100.00	2026-06-09 18:31:45.462661+00	2026-06-15 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
3f7b3c6c-234c-447a-86dc-56ffb8b7ef6d	3b6030a2-3993-4389-8c6c-d3427e0e680b	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	62.00	2026-07-12 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
8ef3e69e-c512-4993-abdb-4c2becc2745c	6f3917b0-87b7-417f-a382-c38278a3d485	3d04c87e-b5ec-45e8-951e-4bb279977080	in_progress	{}	50.00	2026-06-15 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
d6fdc217-b14e-4af7-993c-d8aa1da1ba5f	c43722c6-7e70-49e0-acb4-ba4f953e36a8	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	49.00	2026-08-03 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
5217b088-53ce-4328-a390-ea6e43fdb9ea	312e5b6a-024a-4a5d-9389-357b73426d42	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	completed	{}	100.00	2026-05-02 18:31:45.462661+00	2026-05-08 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
9ca79446-a063-44b9-899a-9449aa533f10	4c6d827e-f3db-47d8-be22-4dc4a611c63f	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	42.00	2026-04-18 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
3c0e1878-225c-4e92-8744-55e93b020df6	3d87692f-06c1-4403-95ff-c70d1598700a	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	56.00	2026-06-07 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
2bddba39-9c45-47d1-9da8-1055fa29bdc4	ae420db9-d867-40d1-8d1a-01ee5d62e270	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	completed	{}	100.00	2026-04-11 18:31:45.462661+00	2026-04-17 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
9ac260c8-999b-4e86-90e5-9ab1c79c18be	8b09383e-447b-4fa0-b605-8d8cf4f3f527	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	60.00	2026-05-18 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
1c0d7cf8-d69c-4d84-8e9f-cbe28023954d	37609501-b2cd-4810-a1d5-b2a10f0405fd	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	55.00	2026-05-15 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
78429dcc-f136-46b7-b0e0-0f244fef4381	8ffbd0cf-b807-4193-af37-3a61482c76eb	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	completed	{}	100.00	2026-07-16 18:31:45.462661+00	2026-07-22 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
30cdcb9d-8aac-4e67-8fef-3439126e9ee2	ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	70.00	2026-02-28 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
a8abeec2-51f7-4779-91d3-3b69c645e706	46e6d439-49ab-4001-b576-7df03d3babee	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	43.00	2026-03-16 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
78a1f4d0-d03b-496b-9918-e3daec071652	1eb0cec9-a12f-4f42-9d77-bf6e343e9a75	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	47.00	2026-08-22 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
cbe812fe-82e9-4965-9015-cd77e0963c5d	573a471b-8236-4977-b94b-80b530b27e7c	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	89.00	2026-05-02 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
59550ea2-5864-4ec0-8ccd-049e08116be7	6bb2ccef-6c0b-4baa-bc82-d037a1c93af1	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	57.00	2026-07-01 18:31:45.462661+00	\N	2026-09-16 18:31:45.462661+00
6b255fd0-dc3a-4252-87a8-11aa3a93d2a9	333f633a-a466-43e6-9c02-cf743b327694	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	69.00	2026-08-09 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
314946f3-0bf8-48a0-84c9-05d3bf2f13fc	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	completed	{}	100.00	2026-07-24 18:31:45.462661+00	2026-07-30 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
c2bea441-68d1-4c85-ab1c-48537dc1e1cd	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	completed	{}	100.00	2026-05-16 18:31:45.462661+00	2026-05-22 18:31:45.462661+00	2026-09-17 18:31:45.462661+00
1ba31957-04a0-45a1-990c-f4b6e3d9b8b5	2731bad6-8e73-4106-8def-3df5df76b6ea	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	89.00	2026-03-06 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
81fd249a-87c0-48b9-b14d-a89824f0efa4	8a1eab45-738c-41b6-b35d-7737f5e2f64e	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	completed	{}	100.00	2026-07-16 18:31:45.462661+00	2026-07-22 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
2819a9ec-294b-4639-be74-78d05bb99393	a8c5b60b-8763-4325-900d-07d7540e6015	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	completed	{}	100.00	2026-06-03 18:31:45.462661+00	2026-06-09 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
82030266-e301-4f54-bc20-5114c40a83e5	db9ec5a1-d0be-490d-91a6-bf32127bba75	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	91.00	2026-04-25 18:31:45.462661+00	\N	2026-09-25 18:31:45.462661+00
818b6dbc-9f46-4e9d-a839-e72690eee076	bd78a83d-5740-4d0d-9000-cdf29d332f27	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	56.00	2026-09-04 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
8b1b7ac8-25ee-43bd-a69d-cba01b9edc13	4ace2ecd-317e-494c-ad50-71e2794fb907	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	99.00	2026-05-18 18:31:45.462661+00	\N	2026-09-20 18:31:45.462661+00
e7f29db3-fb1b-4562-8646-f7591dd50ffc	3e1e22ae-3497-44dc-bb66-1a3c24a5af91	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	93.00	2026-05-16 18:31:45.462661+00	\N	2026-09-19 18:31:45.462661+00
c57706b9-69f3-4be2-970d-1d8ac5ffa9f6	30e16278-0ca1-4efa-a03b-7168658bb2c2	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	61.00	2026-05-24 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
34a1aa43-f72e-4108-8375-dc218509e5cc	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	68.00	2026-04-29 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
2453d426-229a-4622-872e-9c32dce0fa71	c2900748-9036-4804-b4f0-feb22ac5b4fb	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	79.00	2026-03-24 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
cdc828d2-7057-42fe-83ab-425a6891e321	48f33e15-f87f-4629-ab82-4123ada4bdc4	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	completed	{}	100.00	2026-05-25 18:31:45.462661+00	2026-05-31 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
ad63b2ef-8f6e-41f7-98e3-939b83c5bb71	33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	in_progress	{}	82.00	2026-03-31 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
91f676e6-ae6e-449c-8b8b-40984a37098f	fc08ec35-be50-46ec-8acb-0ddb68b16b22	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-09-02 18:31:45.462661+00	2026-09-08 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
c3ca8f5b-41fd-48a2-95ae-933a56fbbdb4	2c310487-b2d2-4f8a-bdc3-0fcd75eff4a9	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	in_progress	{}	70.00	2026-05-18 18:31:45.462661+00	\N	2026-09-26 18:31:45.462661+00
abf647f7-f571-4c51-8ca7-3af79bdd0751	90a570b4-9441-4d8b-981d-a7fa379054d3	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	in_progress	{}	80.00	2026-03-04 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
2b3ec1de-83d2-4148-85fb-5c3c811ef967	3ecf9082-92fa-49e4-a15f-87acb5504803	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-05-05 18:31:45.462661+00	2026-05-11 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
fa66b1d1-fc56-4feb-896d-db27db75b786	707e086b-3312-442d-ac6d-9776ebe73deb	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	in_progress	{}	58.00	2026-04-24 18:31:45.462661+00	\N	2026-09-18 18:31:45.462661+00
347321fc-8404-4632-ad7e-dcbd8df1117c	6a389990-e259-43a4-a9a2-7575b00029e0	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-06-15 18:31:45.462661+00	2026-06-21 18:31:45.462661+00	2026-09-22 18:31:45.462661+00
3b0071e6-b0c1-45ce-af51-88e1b7e97da6	55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	in_progress	{}	86.00	2026-06-14 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
ce62f917-6179-4436-a582-669c51c7844b	cc9e83f0-d177-4454-8ba5-f7581c6da639	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	in_progress	{}	41.00	2026-07-11 18:31:45.462661+00	\N	2026-09-22 18:31:45.462661+00
fdf9893c-2ec1-4c95-b464-8cea499be6f8	e888ad9f-c064-4d24-8143-eec67fac7c1c	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-05-12 18:31:45.462661+00	2026-05-18 18:31:45.462661+00	2026-09-23 18:31:45.462661+00
10d5efd5-cdb0-44dd-896c-73bb0b51d6cc	eee6bbaa-75eb-44f4-9892-d46194b720a9	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-08-06 18:31:45.462661+00	2026-08-12 18:31:45.462661+00	2026-09-19 18:31:45.462661+00
c7bcf2a1-a2b3-4a03-95ca-1e593d29979f	306af47d-26b6-4dc3-96ae-eb178609c1f6	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-03-15 18:31:45.462661+00	2026-03-21 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
b87e1981-d235-4352-a09e-d11faa69e86f	a8c5b60b-8763-4325-900d-07d7540e6015	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-09-09 18:31:45.462661+00	2026-09-15 18:31:45.462661+00	2026-09-26 18:31:45.462661+00
ea84bc9d-dd8e-41ae-b145-c0e2bc6aa408	33f73596-75e6-435e-94f5-d5b111a6aaf5	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	in_progress	{}	64.00	2026-05-27 18:31:45.462661+00	\N	2026-09-17 18:31:45.462661+00
c8c109eb-4fc8-4b22-a47b-91f827cd0936	24cbfa5b-7114-43b8-957c-fe0efa420c25	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-06-07 18:31:45.462661+00	2026-06-13 18:31:45.462661+00	2026-09-25 18:31:45.462661+00
eeca6cb2-a951-40c6-a0f8-5c1de73ce290	15a2f413-02d0-4624-9468-3a8bec2ba6b8	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-04-01 18:31:45.462661+00	2026-04-07 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
04b989d9-b2c5-4c72-8a41-2fbd691d5f1b	4135122d-a240-499c-8de4-3db650d7acc9	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	in_progress	{}	56.00	2026-08-27 18:31:45.462661+00	\N	2026-09-23 18:31:45.462661+00
85eef87c-8d33-4ffb-991f-42c9bb403c31	696886f6-a4bf-44a6-9ba9-c939abb52137	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-07-13 18:31:45.462661+00	2026-07-19 18:31:45.462661+00	2026-09-16 18:31:45.462661+00
ab189809-0278-4fb1-a186-013f84ea9102	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-09-16 18:31:45.462661+00	2026-09-22 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
a22002fd-64c9-4477-a801-8ad7af95da0a	6f1d6dd6-daa9-4660-a06f-527bf32f663e	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	in_progress	{}	47.00	2026-02-24 18:31:45.462661+00	\N	2026-09-21 18:31:45.462661+00
7cad7659-c86f-4deb-9fc5-f4f943891c3a	9897dc81-824b-4829-9fda-76c3f3c3e38f	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-03-15 18:31:45.462661+00	2026-03-21 18:31:45.462661+00	2026-09-18 18:31:45.462661+00
9c7efcb6-0e31-4447-97f0-e793b888e169	fed72080-2568-4892-8047-0b3c72ff7fad	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-02-27 18:31:45.462661+00	2026-03-05 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
2a641087-efee-4aee-a034-d20f6150212e	7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-09-03 18:31:45.462661+00	2026-09-09 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
651f53f0-aea2-4250-b0f9-6f645b85fe8d	9bab5f84-a53e-49d6-91f8-eef87bf5960c	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	in_progress	{}	45.00	2026-06-14 18:31:45.462661+00	\N	2026-09-24 18:31:45.462661+00
55ea2b14-f36c-4628-87b0-e14b4f227f10	bea31be8-3a44-4869-9c56-dce2da936f51	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-05-13 18:31:45.462661+00	2026-05-19 18:31:45.462661+00	2026-09-20 18:31:45.462661+00
f1c29bf2-fea1-4d89-bee4-4d92c9582167	3af00a36-1f7b-4846-a52a-b1871416c5b1	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	completed	{}	100.00	2026-07-21 18:31:45.462661+00	2026-07-27 18:31:45.462661+00	2026-09-24 18:31:45.462661+00
\.


--
-- Data for Name: external_certificates; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.external_certificates (id, user_id, title, issuer, issue_date, credential_id, file_id, skill_id, created_at) FROM stdin;
\.


--
-- Data for Name: feedback; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.feedback (id, user_id, course_id, resource_id, trainer_id, content_rating, trainer_rating, comment, is_anonymous, created_at) FROM stdin;
ed4890bb-a276-4897-88b0-582a4dafdc10	15a2f413-02d0-4624-9468-3a8bec2ba6b8	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2	1	Very practical session.	f	2026-09-26 18:31:45.462661+00
8e4693a8-e4e1-4bed-8f85-621456c35465	30e16278-0ca1-4efa-a03b-7168658bb2c2	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
e3d3e61b-6002-479e-9803-776b578f7999	edc1993b-5333-4d99-bae2-9e80266978e0	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	3	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
138ba886-93eb-4f6a-8935-8f7b30fff09a	7e426fed-4c2e-46f4-866a-7b8aa048cf06	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2	1	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
b9acf1b4-86df-4988-afe2-6ff1c8b342a2	b8541832-74c6-404f-90d0-5fb6d3df7663	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	3	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
6d20b172-7ce7-4482-8063-40bfa17b20d0	3ed88e99-cb0d-423f-ae37-92b93c67d881	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
9f3b5e08-e7f9-4934-976d-1a4547a80552	5d9905c7-91e8-4bd9-b187-b1b8772e0f63	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	3	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
ff69303d-cf9c-4031-8cf4-e0c75032a503	732e74cf-b9b7-4adc-a43a-794430d7fe49	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	1	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
d6eebe7c-3f7f-4396-83ef-7ec81786d751	9e08ecc2-e291-4516-bae3-07b43abc2620	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	3	2	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
5d20614c-6b51-464f-8dd4-1eb65b15b773	a5102b13-4107-4fe5-b7a0-064dd07042ee	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
0f976f50-f296-496a-b6b4-12e71c36808e	df216767-1cda-46b6-874f-845e41051203	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2	1	Clear explanations.	f	2026-09-26 18:31:45.462661+00
6c328486-c3ad-48df-82dc-411fa202096d	6b116d7e-84ed-47de-81ea-2bd42ea50968	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	3	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
eb98a954-4423-4f3a-a10c-633383a681ec	b28e0245-9390-4127-ad3f-80ace4775f43	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2	3	Very practical session.	f	2026-09-26 18:31:45.462661+00
60af6f4e-8498-49f2-81ff-130bef0b6d76	4135122d-a240-499c-8de4-3db650d7acc9	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
0937c272-f2c4-43fb-af4d-c8311348d40c	d22f23cf-8a58-499a-8dba-92806f1622ef	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2	1	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
f3c8e33d-f7f0-4bde-84fa-94326492045c	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	3	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
109fcda7-2f4f-4b7b-9b84-0ec932bbd306	d072273b-7a6f-4fa4-9195-1697050cfab1	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	3	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
68a1cdfe-89f6-4f49-976b-8d505f2347dc	65ef229b-117d-4946-b5bb-301e3f828fc2	55a4d643-f01f-4d75-8109-ff60798f1e9b	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2	1	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
24ef1720-7a8c-4195-90a3-ad9f773e6cc9	6f9f3af8-fa88-4804-aa9b-5680afa4c1ba	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
96a65adb-7ea2-4251-b9cc-55a4905a0144	cf4749a6-6127-4d97-b2a0-17a11eabc216	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	4	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
84b1acdd-7a45-4ef4-9594-0da93130b819	a5fd318c-feeb-4b1b-b739-3e40a59dde18	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	4	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
59cb03c6-1b55-44dc-bdc0-e08d2fdaf4af	72a14ee8-79a9-41a0-8fb1-ac0dfac5bfa2	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	5	4	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
cda59ab1-8e04-4462-bd8c-27e3efad9433	625944b1-2b9b-433b-9af5-e72894aa7a58	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
11d9e38e-b5fd-4636-aa96-98bb293992f7	293f638f-6b5e-4c5a-9282-533cc1c97688	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	5	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
40115719-8f08-43d5-ad33-832ca094ef82	4ace2ecd-317e-494c-ad50-71e2794fb907	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	5	5	Very practical session.	f	2026-09-26 18:31:45.462661+00
83706b9f-dc5a-4ee0-be1a-99d1e90c30b6	30e16278-0ca1-4efa-a03b-7168658bb2c2	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
be506364-8718-4a0e-ad92-3c248579cf39	a6afe850-9547-4fac-892c-00558ad8f725	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
d5ba66c1-c755-4eb7-82db-5733e0c8f9c0	b28e0245-9390-4127-ad3f-80ace4775f43	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	5	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
84556d05-6455-4ab6-b25e-441da476fb45	a5e41a1c-9682-4873-8924-f11edf9b3fce	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
08e48d9e-3a1a-42e5-ae9f-526d101fdbad	2994671f-607f-4cdc-a2bc-22ab97456b28	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	4	3	Very practical session.	f	2026-09-26 18:31:45.462661+00
48b1995d-7aaa-41eb-ad00-8c9b93fb6227	b8541832-74c6-404f-90d0-5fb6d3df7663	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	5	5	Very practical session.	f	2026-09-26 18:31:45.462661+00
41f628e4-1ef8-453d-bd38-75fdb3e11179	a7bae3c0-0e2c-42db-8e35-79114d5dfe80	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	5	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
5bd834ae-ae48-4a29-bedc-ddbd09fc045d	5a97c9d9-87c7-445c-9dc8-860fb29edb16	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
9a0e484f-f418-410b-a53d-96401f629904	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
7a076a83-8b92-4e35-a5ee-8670d1374ede	b875f05c-64bb-41c8-b501-04ef26d03cb3	9e873c8c-811f-4ff5-8d3a-6c858ad65aa6	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
de65ed06-74de-4d67-a611-0ce2e80fca47	48f33e15-f87f-4629-ab82-4123ada4bdc4	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	4	2	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
37d00e32-bffc-490b-be69-6c66fca21cde	dbccc807-eaba-41f6-aabc-14c515010185	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
4c92ecab-bfdb-4855-97ba-ae6c985fae1e	625944b1-2b9b-433b-9af5-e72894aa7a58	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	4	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
c4369558-592d-4c15-a03a-013ebcc962f4	c5c94cb5-5272-498b-b30a-d81279c22e12	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
db62a185-8bb4-4ca1-8b7d-02971f0b740d	7ea450f4-3442-46d0-a08b-19c1e7308bde	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2	2	Very practical session.	f	2026-09-26 18:31:45.462661+00
cbdfb657-12e8-442e-9457-d51c79c4b0c2	9bab5f84-a53e-49d6-91f8-eef87bf5960c	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
09229084-ae1a-4939-b3d8-ace91d02e258	8b09383e-447b-4fa0-b605-8d8cf4f3f527	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
8ebabcd6-bb23-46c7-97c1-9f11bd6044ac	fda17094-1c9f-45de-a42c-aa815d09bc2a	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
eeb6c9b0-da9e-4997-a46d-f8ec03ce23cd	889560c5-9238-4463-82d8-b65d7fdba4bc	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
65594303-50c7-41dc-89af-e8e6e02ecdf2	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
f7f191eb-b673-4d9d-8b76-3d845b77d279	78313b75-0494-43a4-b199-ff1928254f44	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
fcfe1a9c-c1cd-4fab-994b-402a490ad4c7	b97db5e7-dca3-4f88-8318-6d457e09be91	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2	2	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
a20370a1-8174-4ba2-91d6-51560baa9c51	db9ec5a1-d0be-490d-91a6-bf32127bba75	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
2423c05c-fdb3-404e-be98-96f5f97b56e0	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	4	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
c040ae04-f70e-4991-93a5-eade5e25d604	c43722c6-7e70-49e0-acb4-ba4f953e36a8	ad72951b-6768-4887-8063-287ff8f51bf1	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	3	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
194cb10c-e6b7-461f-8d2f-0c80d162ef27	15a2f413-02d0-4624-9468-3a8bec2ba6b8	5317862f-92fe-4e22-ae0a-a244abce364c	\N	ff38df49-9e3b-4df5-92a2-4852f8b79c74	2	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
985846db-80ff-4e55-bf4a-5c703712db97	306af47d-26b6-4dc3-96ae-eb178609c1f6	5317862f-92fe-4e22-ae0a-a244abce364c	\N	ff38df49-9e3b-4df5-92a2-4852f8b79c74	2	2	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
e32eb7f1-5a8e-46a7-9170-80841bc17674	eee6bbaa-75eb-44f4-9892-d46194b720a9	5317862f-92fe-4e22-ae0a-a244abce364c	\N	ff38df49-9e3b-4df5-92a2-4852f8b79c74	3	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
c73e5093-5583-4863-9340-b6c90f0e0102	7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	5317862f-92fe-4e22-ae0a-a244abce364c	\N	ff38df49-9e3b-4df5-92a2-4852f8b79c74	3	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
099ef9f0-b193-4048-b862-0d916645c4c8	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	5317862f-92fe-4e22-ae0a-a244abce364c	\N	ff38df49-9e3b-4df5-92a2-4852f8b79c74	2	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
6c4cebc3-5eea-4efc-a64c-1fa45feea25c	f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d	5317862f-92fe-4e22-ae0a-a244abce364c	\N	ff38df49-9e3b-4df5-92a2-4852f8b79c74	2	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
68e92dd6-8478-45ec-bca0-b5ba684962df	2e35b549-e1b5-4e61-a221-b0799208258c	5317862f-92fe-4e22-ae0a-a244abce364c	\N	ff38df49-9e3b-4df5-92a2-4852f8b79c74	3	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
9462bec6-38a5-45be-adcc-d71732374c94	b8541832-74c6-404f-90d0-5fb6d3df7663	5317862f-92fe-4e22-ae0a-a244abce364c	\N	ff38df49-9e3b-4df5-92a2-4852f8b79c74	4	2	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
04648e8c-789a-49b3-a4c7-e151df2f6c79	152f1a01-df4b-4828-bf72-c1616f324c38	32ab414d-cb9f-48ed-b3b5-97537b736196	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	3	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
585db889-5638-43a9-b64e-6227491786f5	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	32ab414d-cb9f-48ed-b3b5-97537b736196	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	4	4	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
a65f8436-4a85-44b6-b522-76010a5116d5	b4c20820-6710-46e1-b3cf-939b8bc00f93	32ab414d-cb9f-48ed-b3b5-97537b736196	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	4	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
12c45e69-2397-4644-9703-37a62d23c0b9	77c70aa0-ddd9-4445-be30-4817de1cbfd0	32ab414d-cb9f-48ed-b3b5-97537b736196	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	4	3	Very practical session.	f	2026-09-26 18:31:45.462661+00
2a2426ae-fd17-4c1d-b52f-53af5de85f6c	24cbfa5b-7114-43b8-957c-fe0efa420c25	32ab414d-cb9f-48ed-b3b5-97537b736196	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	4	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
de557b1a-b6b7-4958-94a0-65ec39b5dd60	2e35b549-e1b5-4e61-a221-b0799208258c	32ab414d-cb9f-48ed-b3b5-97537b736196	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	3	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
095f7f9f-6f92-414f-9915-ee560fc21f2c	7ea450f4-3442-46d0-a08b-19c1e7308bde	32ab414d-cb9f-48ed-b3b5-97537b736196	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	4	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
f2469051-fb52-4b55-90b9-3fe714847104	0d37acee-70ea-4604-8bd7-c995941443fd	32ab414d-cb9f-48ed-b3b5-97537b736196	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	4	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
cf4998a5-f38f-485b-a7c8-bc0d0fefcb9f	a6d5837e-0df4-4cf0-9c98-8f0da7e4a1f1	32ab414d-cb9f-48ed-b3b5-97537b736196	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	4	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
a6921d39-86d2-4ec7-a18c-be98b840e227	3ded69a7-290c-47f6-bd29-7369f6f8e3c8	32ab414d-cb9f-48ed-b3b5-97537b736196	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	3	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
ffc59e0c-60df-4ac9-93b4-9fb5f77f97f9	312e5b6a-024a-4a5d-9389-357b73426d42	32ab414d-cb9f-48ed-b3b5-97537b736196	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	3	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
95e60a67-6409-4ad0-92c2-b9ec66a1964d	30e16278-0ca1-4efa-a03b-7168658bb2c2	32ab414d-cb9f-48ed-b3b5-97537b736196	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	3	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
8bebe1fd-ec56-4667-bd4c-e264e8501251	d05292f5-3e9f-4e51-bb50-05a6534dc9b8	32ab414d-cb9f-48ed-b3b5-97537b736196	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	4	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
3cd5b9da-4de2-415e-90fd-173477b5bb46	6f1d6dd6-daa9-4660-a06f-527bf32f663e	32ab414d-cb9f-48ed-b3b5-97537b736196	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
74e5ea72-374f-489d-8840-e20ce7aaa7c3	8a83194a-d3bc-49dd-8594-ed05a26d23a0	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
ac0c859c-723f-430e-987f-2849386b32be	cd441b90-ef66-411c-b22e-4e046c29677f	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	4	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
c2ecec54-7900-4c88-b162-d246c1b758bd	9389e5a2-816f-4e52-950b-a9af117c7ad1	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	4	5	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
faed45e2-883a-4103-b537-b0165cb8eeee	ae420db9-d867-40d1-8d1a-01ee5d62e270	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	4	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
eb7a423d-8f9e-4a03-afcd-5643c70b68ed	7f53c53d-3323-4146-8cea-01d6c38b4f77	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
4f2b9742-6c93-4b85-80a7-c602b75df36a	306af47d-26b6-4dc3-96ae-eb178609c1f6	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
0ea66041-b0cb-4498-aa9d-8186a18e3d38	fbc637df-19cd-4ec5-b08d-49ce15747076	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
a130dc46-5a6d-4dcc-870b-a5046c406a2e	78313b75-0494-43a4-b199-ff1928254f44	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5	5	Very practical session.	f	2026-09-26 18:31:45.462661+00
2e33f120-5f80-4825-88da-5a2c817659cb	edc1993b-5333-4d99-bae2-9e80266978e0	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
c0e7f931-7e6d-495c-a255-3322cc6a28f8	1e9340db-2cfd-419f-8894-9448da0bbc19	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	4	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
2b8d00f4-ffe0-42bf-b9f8-de33016602b7	729fd30e-9cfb-4751-bbdb-935fbbb7f994	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5	5	Very practical session.	f	2026-09-26 18:31:45.462661+00
f77ea10f-cdc5-4975-9f3e-0b9ee78d9687	b0ba69f7-69ce-411c-a22d-c449785d11e9	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
7884e592-ba02-49e9-9048-8d83f3a51231	f1bc49b2-13bf-4cd2-a5ac-6aa2c12e8f95	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
0ee8cf24-e114-4487-b3fd-705b85fc6ddc	88b2de0e-fb93-4402-98ef-3c1bd149f61d	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
df3789d6-64d7-40de-bc08-733024f54e9d	ab65843a-c349-4b21-b43b-9302ed8231b4	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
866027f4-5ab5-4229-b96b-d096138726f6	7fe9d01e-9282-4b4d-9377-b8b5d4c7f7d2	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
4fe2f9cc-6a6b-4f95-8200-973b507ef6a1	8a1eab45-738c-41b6-b35d-7737f5e2f64e	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5	5	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
911b4267-5e8d-4f58-a9bf-d81ad93d650c	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
5bf2d71e-7fa7-4640-be7d-bea3810ff572	3b6030a2-3993-4389-8c6c-d3427e0e680b	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	4	4	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
c57ec07a-b690-49f1-b6be-dfc5bea19f6d	15a2f413-02d0-4624-9468-3a8bec2ba6b8	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
0530092b-6e65-410f-bfbb-a7f48c30d7e6	d22f23cf-8a58-499a-8dba-92806f1622ef	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
037734d9-a0e2-4847-ab7f-e540fdf71551	ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	19b09698-d481-4bdf-95c3-6dd7b1aa8afa	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	4	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
a460b1e5-efa4-43ff-acd3-386e6e9b9fea	3e1e22ae-3497-44dc-bb66-1a3c24a5af91	33add9da-29ab-4a45-90b2-f5b8f4723f3d	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	4	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
edcee888-899a-4844-9861-7682fd58aecb	3260915b-2633-418b-997d-2beabd07ed2b	33add9da-29ab-4a45-90b2-f5b8f4723f3d	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
ae6bed6e-ebbf-41a8-8696-e1de0790484d	8be014b0-ed46-43db-89e2-91a301c618db	33add9da-29ab-4a45-90b2-f5b8f4723f3d	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
2587f8dc-d1fe-4b35-a509-76e9d0a1ee6d	a17abc66-209e-405f-bcd6-c39e54cbce66	33add9da-29ab-4a45-90b2-f5b8f4723f3d	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	3	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
19a5baff-5fc8-46f1-9ff9-7ad261553195	8ffbd0cf-b807-4193-af37-3a61482c76eb	33add9da-29ab-4a45-90b2-f5b8f4723f3d	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	3	2	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
c2207d2c-e298-4059-9c07-4ac24a0e0b0c	7acc259e-1231-481b-ab79-59821fd46534	33add9da-29ab-4a45-90b2-f5b8f4723f3d	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	4	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
d697df24-a788-439e-a198-3980847e6947	c41a5544-af25-44ec-9fab-26fa3a4e08a5	33add9da-29ab-4a45-90b2-f5b8f4723f3d	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	4	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
81bbed30-455b-41c0-9328-c0df2d437243	2c310487-b2d2-4f8a-bdc3-0fcd75eff4a9	33add9da-29ab-4a45-90b2-f5b8f4723f3d	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	4	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
0edd47ef-3d89-434e-8b36-e937dc7ad0ee	889560c5-9238-4463-82d8-b65d7fdba4bc	33add9da-29ab-4a45-90b2-f5b8f4723f3d	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	4	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
5684dd37-0435-4e34-a845-4a5630272dde	3d87692f-06c1-4403-95ff-c70d1598700a	33add9da-29ab-4a45-90b2-f5b8f4723f3d	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
047156df-a903-422c-87c8-4e4946c96999	33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	8db3d256-cbbd-4863-b45a-d035bffdba03	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	3	2	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
5d3b161d-a5d0-4235-8665-d0eae44f6c21	8b09383e-447b-4fa0-b605-8d8cf4f3f527	8db3d256-cbbd-4863-b45a-d035bffdba03	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
467ecaa6-ba80-4b64-a536-a25fe3214199	bd78a83d-5740-4d0d-9000-cdf29d332f27	8db3d256-cbbd-4863-b45a-d035bffdba03	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	3	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
46e8860e-4d81-4c3f-9a55-cf8da59f4a29	8a0a7128-e6e6-4b49-8395-52723dda0b7c	8db3d256-cbbd-4863-b45a-d035bffdba03	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
7ebfd233-a13f-4f56-aaf2-062b8565adca	6a389990-e259-43a4-a9a2-7575b00029e0	8db3d256-cbbd-4863-b45a-d035bffdba03	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2	2	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
1f2c54d4-e54e-45ec-a2ea-ec79e8eb6ee4	5af34829-4d6f-425c-9f78-525896ea0526	8db3d256-cbbd-4863-b45a-d035bffdba03	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
4a9446be-ca70-4ea1-911d-2e6b7d155eb6	b2734396-c5d2-4b05-99d0-986a180a98a6	8db3d256-cbbd-4863-b45a-d035bffdba03	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	3	2	Very practical session.	f	2026-09-26 18:31:45.462661+00
fee96e6f-c33b-472b-be5c-d7f576bdf4e4	c41a5544-af25-44ec-9fab-26fa3a4e08a5	8db3d256-cbbd-4863-b45a-d035bffdba03	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
7ceea0fa-6ca4-4090-bfae-71ca578c2572	fba30b27-7555-43f7-8c74-b84e722ebbc8	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	4	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
feb4d910-9378-4449-b01d-b96c8b3c23c7	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	5	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
9cf05bca-bc02-49ba-8ea0-027097286272	6b116d7e-84ed-47de-81ea-2bd42ea50968	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	5	5	Very practical session.	f	2026-09-26 18:31:45.462661+00
8ba844db-e121-4849-96f9-181d9ac7dc8e	28fe79f0-6207-4e0c-8bae-1eb02eed759b	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	5	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
f2f1d6bf-5acc-49b8-bfa8-b7c4d99d7879	889560c5-9238-4463-82d8-b65d7fdba4bc	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	5	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
b06b81b6-cab2-4f88-8a2d-78a400d1d3fd	2731bad6-8e73-4106-8def-3df5df76b6ea	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	5	5	Very practical session.	f	2026-09-26 18:31:45.462661+00
8a06b32f-4aae-483c-9661-40a330c55cc2	37609501-b2cd-4810-a1d5-b2a10f0405fd	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
07bf31f7-f7a1-4879-8c5f-ea4cfe276593	7fe9d01e-9282-4b4d-9377-b8b5d4c7f7d2	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	5	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
d13fcb35-a80d-46bd-8a16-245a8579c15e	216136af-8b6b-44ae-a787-59506613a618	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	5	5	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
4ce0dd2d-3724-4bb7-8d82-b56b0eb44944	77c70aa0-ddd9-4445-be30-4817de1cbfd0	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
637e0e79-8d36-4309-b0ac-b961e8ff6551	5d9905c7-91e8-4bd9-b187-b1b8772e0f63	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	4	5	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
37209d25-40ad-4c38-b813-4cf5a1d9c0a8	feb2fb92-ce04-48c5-8a5f-9d2e832d1644	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	4	5	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
982ed9ae-cfd5-4520-8ece-75f39e822c5c	7acc259e-1231-481b-ab79-59821fd46534	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	4	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
24b267ec-6ce4-4894-b5f3-199449ffcb44	db9ec5a1-d0be-490d-91a6-bf32127bba75	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	4	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
86ee05bc-2dc7-4dac-bbb0-146b9bcf9673	a6f0ed93-9d6b-4592-a13e-5435550b4db2	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	4	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
2ee98abe-18c3-4542-b718-22e42cd3badd	8be014b0-ed46-43db-89e2-91a301c618db	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	5	5	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
6229fe78-b158-4673-9d2b-311dd13065e6	ab65843a-c349-4b21-b43b-9302ed8231b4	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	4	5	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
23e0a149-3f7a-4c7f-a5b0-eb5eb9c83af0	46e6d439-49ab-4001-b576-7df03d3babee	c4985880-e557-407c-8f90-5c1f5b564695	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	4	5	Very practical session.	f	2026-09-26 18:31:45.462661+00
21e1ca09-d417-4ede-a76f-3d5d09a4be05	a5102b13-4107-4fe5-b7a0-064dd07042ee	0724a689-d500-4969-b7fb-72e37232b31f	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	5	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
5d989ebb-5236-47ad-ac0b-f11c13393d0b	a17abc66-209e-405f-bcd6-c39e54cbce66	0724a689-d500-4969-b7fb-72e37232b31f	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	4	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
b1261e96-b627-4591-a07c-5e65f6ea7709	1f511b5e-1292-4202-860e-b54f11eda21e	0724a689-d500-4969-b7fb-72e37232b31f	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	5	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
59645f0d-67b6-4cef-8f77-bc18ce969f0a	032c01d5-4b5e-44f6-821d-2ba4342c938f	0724a689-d500-4969-b7fb-72e37232b31f	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	4	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
8252e9d3-39a5-4bcc-adce-1e62dad796f6	1eb0cec9-a12f-4f42-9d77-bf6e343e9a75	0724a689-d500-4969-b7fb-72e37232b31f	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	5	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
75ca96a9-d017-49aa-bc4a-fc785180dd84	c41e7852-875f-411b-93f1-7171f9871f9f	0724a689-d500-4969-b7fb-72e37232b31f	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	4	5	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
448e2576-f50b-4a24-9b40-8e385186e0c1	4ace2ecd-317e-494c-ad50-71e2794fb907	0724a689-d500-4969-b7fb-72e37232b31f	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	5	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
595334e9-0bbf-4e7f-afb7-aa5b59da6946	c2900748-9036-4804-b4f0-feb22ac5b4fb	0724a689-d500-4969-b7fb-72e37232b31f	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	5	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
39ac5f19-10d2-4d4b-b73a-d0ab9e0acae2	a8c5b60b-8763-4325-900d-07d7540e6015	0724a689-d500-4969-b7fb-72e37232b31f	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	4	5	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
c29ae2a9-efbd-4f9f-84bd-b9b6535848c3	fed72080-2568-4892-8047-0b3c72ff7fad	0724a689-d500-4969-b7fb-72e37232b31f	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	5	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
e2f060eb-46d6-42ff-be45-128952c442de	17231857-2d57-46f3-aecc-cb26a0865adb	0724a689-d500-4969-b7fb-72e37232b31f	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	5	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
775a672a-3184-4cbb-9b06-4d87f94065b0	d05292f5-3e9f-4e51-bb50-05a6534dc9b8	0724a689-d500-4969-b7fb-72e37232b31f	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	4	4	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
2a0d933c-d27f-476b-b86a-166dbaf90efd	862f76a0-443e-4a80-8644-ef4922c5f38a	ce43f7f3-92cb-4d62-b40a-149bdd13b745	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	4	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
d42e5aa3-4527-437c-a6ab-0cd708d34c4f	7acc259e-1231-481b-ab79-59821fd46534	ce43f7f3-92cb-4d62-b40a-149bdd13b745	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	4	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
fc4914eb-a015-427b-abc3-0832fabeb111	2e35b549-e1b5-4e61-a221-b0799208258c	ce43f7f3-92cb-4d62-b40a-149bdd13b745	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
fd39ea82-7d3f-4f37-a011-6348b231f4ac	28fe79f0-6207-4e0c-8bae-1eb02eed759b	ce43f7f3-92cb-4d62-b40a-149bdd13b745	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
a2e70c50-a4dd-4b5e-9877-1eff831bc3c1	cf4749a6-6127-4d97-b2a0-17a11eabc216	ce43f7f3-92cb-4d62-b40a-149bdd13b745	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	5	5	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
cf7740a0-9e3a-4a25-acb0-17159693aca1	65ef229b-117d-4946-b5bb-301e3f828fc2	ce43f7f3-92cb-4d62-b40a-149bdd13b745	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	4	4	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
38b8d318-29ad-44b9-91b7-2b8418152cac	152f1a01-df4b-4828-bf72-c1616f324c38	ce43f7f3-92cb-4d62-b40a-149bdd13b745	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	4	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
c32d6ba7-587d-4bde-847c-fe1dc8b7914a	293f638f-6b5e-4c5a-9282-533cc1c97688	ce43f7f3-92cb-4d62-b40a-149bdd13b745	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
69298926-6c60-4402-a78a-5269a4da277b	a17abc66-209e-405f-bcd6-c39e54cbce66	ce43f7f3-92cb-4d62-b40a-149bdd13b745	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
21a4208b-22bd-469a-b0fd-c608bd9639d7	7e426fed-4c2e-46f4-866a-7b8aa048cf06	ce43f7f3-92cb-4d62-b40a-149bdd13b745	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	4	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
e8eb05d7-9342-4129-85b7-0ae0fcd89522	625944b1-2b9b-433b-9af5-e72894aa7a58	ce43f7f3-92cb-4d62-b40a-149bdd13b745	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	5	4	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
533bdf10-ea0a-4b61-984c-941d7d9bb478	6f9f3af8-fa88-4804-aa9b-5680afa4c1ba	ce43f7f3-92cb-4d62-b40a-149bdd13b745	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	3	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
43f8dc4e-2a4a-4909-a311-5bacd6da4b25	732e74cf-b9b7-4adc-a43a-794430d7fe49	ce43f7f3-92cb-4d62-b40a-149bdd13b745	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	5	5	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
df1a1722-07b0-4337-9876-020a269560d2	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	97b1727b-e525-4ee5-b01f-28b15a8101b5	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2	2	Very practical session.	f	2026-09-26 18:31:45.462661+00
709dbb88-a7e0-4aad-8d8f-cb76fed48e23	48ae8c9d-e783-46c2-abf3-cc9d31e16d81	97b1727b-e525-4ee5-b01f-28b15a8101b5	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	4	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
79496001-ba05-4fb7-8e4c-7b7f5bb8673b	5d1e34b1-8861-4358-96e3-f5ed89f5c9d2	97b1727b-e525-4ee5-b01f-28b15a8101b5	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	3	2	Very practical session.	f	2026-09-26 18:31:45.462661+00
5b965a96-4e6a-4165-bc9d-8fbfb2c7491c	152f1a01-df4b-4828-bf72-c1616f324c38	97b1727b-e525-4ee5-b01f-28b15a8101b5	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
f033488c-b163-4985-a08d-8eedcdc98080	1e9340db-2cfd-419f-8894-9448da0bbc19	97b1727b-e525-4ee5-b01f-28b15a8101b5	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
06b9483a-257e-4702-aa9b-09c3ee3864bf	9bab5f84-a53e-49d6-91f8-eef87bf5960c	97b1727b-e525-4ee5-b01f-28b15a8101b5	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
6f72794b-e791-4875-901e-25e7e3b93e79	5d9905c7-91e8-4bd9-b187-b1b8772e0f63	97b1727b-e525-4ee5-b01f-28b15a8101b5	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2	2	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
afde4970-e2e3-4e6d-829e-2ae0f2c6a683	fda17094-1c9f-45de-a42c-aa815d09bc2a	97b1727b-e525-4ee5-b01f-28b15a8101b5	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2	3	Very practical session.	f	2026-09-26 18:31:45.462661+00
80961eeb-3255-4e3d-8f31-bfae009a02da	b2c7b829-9669-4258-ab45-acc4445b9d6d	97b1727b-e525-4ee5-b01f-28b15a8101b5	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	3	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
b195ee6f-240b-49a9-a558-b10233bd97db	2af59a77-c993-46c3-a686-b91217814d48	97b1727b-e525-4ee5-b01f-28b15a8101b5	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
cf3fe22a-289b-42a2-be01-8d8450731049	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	97b1727b-e525-4ee5-b01f-28b15a8101b5	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	3	2	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
25dcb6f4-c52c-4b54-9b3f-b4ce1caf6455	889560c5-9238-4463-82d8-b65d7fdba4bc	e930bc9e-26fc-4a34-89bc-012457df980e	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	4	5	Very practical session.	f	2026-09-26 18:31:45.462661+00
b008e55e-a89d-4e82-960a-d73d088eaf60	48f33e15-f87f-4629-ab82-4123ada4bdc4	e930bc9e-26fc-4a34-89bc-012457df980e	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	4	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
ef47c429-52c2-447f-82f8-47caf25f1993	dbccc807-eaba-41f6-aabc-14c515010185	e930bc9e-26fc-4a34-89bc-012457df980e	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	5	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
bd3265f3-e297-4afd-a34c-598fa3725454	3af00a36-1f7b-4846-a52a-b1871416c5b1	e930bc9e-26fc-4a34-89bc-012457df980e	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	5	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
bfcf6167-babb-48a6-854f-6c38bcb21f3a	b8541832-74c6-404f-90d0-5fb6d3df7663	e930bc9e-26fc-4a34-89bc-012457df980e	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	5	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
876d0dcf-f5dc-42e9-9c6c-6457fa25f53b	1e9340db-2cfd-419f-8894-9448da0bbc19	e930bc9e-26fc-4a34-89bc-012457df980e	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	4	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
2a6bbf0a-5e6a-41c1-8b2b-408948a6feac	eee6bbaa-75eb-44f4-9892-d46194b720a9	e930bc9e-26fc-4a34-89bc-012457df980e	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	5	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
0b6073db-9321-4111-8a85-e1f86f6a219e	2e35b549-e1b5-4e61-a221-b0799208258c	e930bc9e-26fc-4a34-89bc-012457df980e	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	4	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
fef96c35-197e-4d0a-807a-2a5f9d4562c2	b0ba69f7-69ce-411c-a22d-c449785d11e9	e930bc9e-26fc-4a34-89bc-012457df980e	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	4	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
dc41fd24-7e2a-4ed1-b967-6d0101425d3c	4ace2ecd-317e-494c-ad50-71e2794fb907	e930bc9e-26fc-4a34-89bc-012457df980e	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	5	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
b3101e6a-9275-4951-a4a1-f27f1262a69c	696886f6-a4bf-44a6-9ba9-c939abb52137	e930bc9e-26fc-4a34-89bc-012457df980e	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	5	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
7b34bb20-4159-42b5-8803-d314472040b6	f74aaa72-56ba-476d-9aed-ffbe2e41dd50	e930bc9e-26fc-4a34-89bc-012457df980e	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	5	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
f9a1d1ba-0987-46d1-9e13-f48e5e329892	60e67627-9116-4358-a94b-89c0416805f0	e930bc9e-26fc-4a34-89bc-012457df980e	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
2c30fd40-a2ea-4e50-9090-28c7519102c9	9e08ecc2-e291-4516-bae3-07b43abc2620	e930bc9e-26fc-4a34-89bc-012457df980e	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	5	5	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
a8aa27c3-be48-463b-ab00-515cd873d567	dbccc807-eaba-41f6-aabc-14c515010185	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	2	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
44dbfc19-caf7-4a79-9d68-cb6781489bc4	8ffbd0cf-b807-4193-af37-3a61482c76eb	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	3	3	Very practical session.	f	2026-09-26 18:31:45.462661+00
1f2bf119-a987-4ada-a05a-54f65791a7d0	caf34c22-6898-4c15-bde0-08f3d2634d41	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	4	3	Very practical session.	f	2026-09-26 18:31:45.462661+00
6c7a56f0-ca55-46e5-8e23-aee060595e4d	fba30b27-7555-43f7-8c74-b84e722ebbc8	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	3	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
6e51ee92-80b2-4c70-a7a2-0b70ceda8df0	a5102b13-4107-4fe5-b7a0-064dd07042ee	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	3	2	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
4b599b9f-a5cc-420b-906c-9d44ac7d93bb	b28e0245-9390-4127-ad3f-80ace4775f43	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	3	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
715c6c19-cb0c-4ec8-a03c-4142138aca45	05a922f4-7a9b-427c-bd4f-34ee3bdcfcf6	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	3	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
8ee3bd3f-3a95-4675-baf9-30909adaa642	a6f0ed93-9d6b-4592-a13e-5435550b4db2	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	3	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
234c7456-b471-4ebc-8501-2e0e1f7069d7	e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	4	2	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
a1641c59-feca-4305-880b-d8eaecbbe985	cd441b90-ef66-411c-b22e-4e046c29677f	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	3	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
8e4480a2-9d72-482f-bc45-73a458429028	fbc637df-19cd-4ec5-b08d-49ce15747076	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	3	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
177faa76-dbb8-4e2e-99d7-322912dbab3c	9e08ecc2-e291-4516-bae3-07b43abc2620	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	2	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
19d2e144-949c-49f4-8225-4108d358dfa6	216136af-8b6b-44ae-a787-59506613a618	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	2	2	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
40c4faf1-5333-419b-8bbf-e6b3c371bd33	ab903484-298e-4415-93b0-8f5ea844bf31	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
cac90561-92dd-440e-adc4-6959819f168c	6cf3f90d-5b2f-422b-98a5-3df74a5bcbad	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	4	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
b9369756-391a-4323-b3b5-91aaaf2c1352	17231857-2d57-46f3-aecc-cb26a0865adb	290cedcf-37a4-4271-ae6c-2172115f0acb	\N	e9178b69-2339-4a64-857f-5ad0630325a5	2	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
c622425d-8ad7-4ca2-bc83-1f1207e734ca	ea8fa5c6-6833-4701-9073-dd4ff3f78cb8	57e0bcdd-75f2-4ba6-b987-befe07d147c8	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	2	2	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
21299553-9274-4cdb-b5dc-ad325b44dc7d	72a5ceb8-6b68-433d-9b99-d62b8c9f1375	57e0bcdd-75f2-4ba6-b987-befe07d147c8	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	3	2	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
3fff27af-4051-4374-a959-c568d9376c5c	30e16278-0ca1-4efa-a03b-7168658bb2c2	57e0bcdd-75f2-4ba6-b987-befe07d147c8	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	3	2	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
b0975d96-9c34-4729-a646-97584cde41d4	8a1eab45-738c-41b6-b35d-7737f5e2f64e	57e0bcdd-75f2-4ba6-b987-befe07d147c8	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	3	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
a6bfd8ff-8772-4c29-a1ae-a4af6d45cc5b	1f511b5e-1292-4202-860e-b54f11eda21e	57e0bcdd-75f2-4ba6-b987-befe07d147c8	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	4	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
5d31b971-eaaf-4d26-b1e8-a637732dbc98	9e08ecc2-e291-4516-bae3-07b43abc2620	57e0bcdd-75f2-4ba6-b987-befe07d147c8	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	4	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
92eb6173-c58c-4300-98f6-69acd38c832f	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	57e0bcdd-75f2-4ba6-b987-befe07d147c8	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	2	2	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
9eab8788-f812-4919-aceb-9ee65a5bd227	77c70aa0-ddd9-4445-be30-4817de1cbfd0	57e0bcdd-75f2-4ba6-b987-befe07d147c8	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	3	2	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
1efc0421-e339-4b06-8a12-83ad28191a4b	4acb1924-e6ec-428c-8401-ac05f87e2bbf	57e0bcdd-75f2-4ba6-b987-befe07d147c8	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	3	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
2e066582-29e1-4235-b2e0-03cd7b91f3b2	c43722c6-7e70-49e0-acb4-ba4f953e36a8	57e0bcdd-75f2-4ba6-b987-befe07d147c8	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	2	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
ec18d4ff-b979-4df7-9f1c-e5b1696424f0	cf4749a6-6127-4d97-b2a0-17a11eabc216	42f00c79-df57-400e-a313-a585d6a36404	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	3	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
58801080-8c82-482c-a163-d680e1a322bc	357f9f29-063f-4ff8-bdc9-6df1d8cb15b4	42f00c79-df57-400e-a313-a585d6a36404	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	4	5	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
d51ef3b8-a6be-4e03-9235-0768042f48d3	2af59a77-c993-46c3-a686-b91217814d48	42f00c79-df57-400e-a313-a585d6a36404	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
bf0d720f-3011-4f42-951c-75b3a114ff94	90a570b4-9441-4d8b-981d-a7fa379054d3	42f00c79-df57-400e-a313-a585d6a36404	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	5	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
cbb9e20c-ccce-4bcc-bbbb-a08477cc310f	3b6030a2-3993-4389-8c6c-d3427e0e680b	42f00c79-df57-400e-a313-a585d6a36404	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	4	5	Very practical session.	f	2026-09-26 18:31:45.462661+00
f0517720-da23-4bdd-a1d5-5328509f369d	4c6d827e-f3db-47d8-be22-4dc4a611c63f	42f00c79-df57-400e-a313-a585d6a36404	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	4	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
9a5b7c10-3a17-4f02-a321-bddeca6c7cf6	2731bad6-8e73-4106-8def-3df5df76b6ea	42f00c79-df57-400e-a313-a585d6a36404	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	5	3	Very practical session.	f	2026-09-26 18:31:45.462661+00
92259dba-676a-4235-a2df-c36076523550	f32344cc-9180-4953-b2cd-ba0f4bdb2eea	42f00c79-df57-400e-a313-a585d6a36404	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
23e3bb5e-e0f0-47ce-90dd-ddd0e7217702	4d5fd264-452f-4436-8eca-5c6c62afb143	42f00c79-df57-400e-a313-a585d6a36404	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	3	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
5a99dae8-0c3e-40aa-9afb-7d42feaaae0f	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	42f00c79-df57-400e-a313-a585d6a36404	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	3	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
ffee3f1f-e886-4658-94d2-d52f00dcdc05	7f53c53d-3323-4146-8cea-01d6c38b4f77	42f00c79-df57-400e-a313-a585d6a36404	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	3	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
23ac7919-5785-42dc-a018-f36891fcfeb0	46e6d439-49ab-4001-b576-7df03d3babee	42f00c79-df57-400e-a313-a585d6a36404	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	5	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
4e285938-0b61-4487-8f35-fd4526d727bc	9e08ecc2-e291-4516-bae3-07b43abc2620	42f00c79-df57-400e-a313-a585d6a36404	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	3	4	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
bbd7e749-0d17-466d-9459-eb0c674f7f86	729fd30e-9cfb-4751-bbdb-935fbbb7f994	486ae347-6271-439f-9865-ebaf1e4d93cd	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	5	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
5aaa6f36-4f35-4bec-86f1-93d45d6318af	d072273b-7a6f-4fa4-9195-1697050cfab1	486ae347-6271-439f-9865-ebaf1e4d93cd	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	5	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
89180fd2-1fac-4d29-96a3-22e118397aad	77c70aa0-ddd9-4445-be30-4817de1cbfd0	486ae347-6271-439f-9865-ebaf1e4d93cd	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	5	5	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
4b102c80-dd5f-448e-ae5c-10cbfdf2139f	7f53c53d-3323-4146-8cea-01d6c38b4f77	486ae347-6271-439f-9865-ebaf1e4d93cd	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	5	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
61da89b4-b823-4515-ad3f-ebe26784a727	3d87692f-06c1-4403-95ff-c70d1598700a	486ae347-6271-439f-9865-ebaf1e4d93cd	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	4	4	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
cd771ebf-c0ae-4021-837e-ed6a60ab07ea	7e426fed-4c2e-46f4-866a-7b8aa048cf06	486ae347-6271-439f-9865-ebaf1e4d93cd	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	4	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
29a8876e-a1f6-497d-b8c7-ae3cca031c68	fafec148-becc-4918-b1e0-08794a94f6de	486ae347-6271-439f-9865-ebaf1e4d93cd	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
92d84e50-f052-4374-b618-4c42fbff6652	625944b1-2b9b-433b-9af5-e72894aa7a58	486ae347-6271-439f-9865-ebaf1e4d93cd	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	4	5	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
db6a2bf9-edae-4dbe-a207-ae4339413b25	3af00a36-1f7b-4846-a52a-b1871416c5b1	486ae347-6271-439f-9865-ebaf1e4d93cd	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	5	3	Very practical session.	f	2026-09-26 18:31:45.462661+00
28dedce0-1920-40fe-9ecb-2813c8d62b01	9389e5a2-816f-4e52-950b-a9af117c7ad1	486ae347-6271-439f-9865-ebaf1e4d93cd	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	5	4	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
36b87332-0652-401a-882a-926bee29b126	d2298ed0-2515-4232-b70f-845a98dac595	486ae347-6271-439f-9865-ebaf1e4d93cd	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	4	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
cb349b46-4c05-4d83-86cd-ea86fe1f2b54	286bd41d-35d4-4b43-b05b-8548dab978ab	377c54d8-88d8-4698-a98c-27a42d2dae92	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2	2	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
293c44ca-a353-46bb-a376-19f10d11591f	7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	377c54d8-88d8-4698-a98c-27a42d2dae92	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2	2	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
6e8d35ec-ab7c-4edf-9374-ad890106ae49	1f511b5e-1292-4202-860e-b54f11eda21e	377c54d8-88d8-4698-a98c-27a42d2dae92	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2	2	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
1c3cd4b6-2f01-4cee-bef4-31fbbdeac1b6	6d6f1209-693c-409d-9587-ed4e04d77930	377c54d8-88d8-4698-a98c-27a42d2dae92	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	3	1	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
e43638f6-1387-4fce-ac6d-40a41b070243	b2c7b829-9669-4258-ab45-acc4445b9d6d	377c54d8-88d8-4698-a98c-27a42d2dae92	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	3	1	Clear explanations.	f	2026-09-26 18:31:45.462661+00
2316edec-e12a-45e9-8f70-2cb58a15564e	cd441b90-ef66-411c-b22e-4e046c29677f	377c54d8-88d8-4698-a98c-27a42d2dae92	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	3	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
1bb5e138-b83e-4158-9ef7-4b2bdd758d5e	8a83194a-d3bc-49dd-8594-ed05a26d23a0	377c54d8-88d8-4698-a98c-27a42d2dae92	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2	3	Very practical session.	f	2026-09-26 18:31:45.462661+00
762374e4-6057-4be1-93a6-c8c670ff3979	90a570b4-9441-4d8b-981d-a7fa379054d3	377c54d8-88d8-4698-a98c-27a42d2dae92	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	3	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
b969a9fb-9942-4589-8c25-1a799916f132	8a1eab45-738c-41b6-b35d-7737f5e2f64e	377c54d8-88d8-4698-a98c-27a42d2dae92	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2	2	Very practical session.	f	2026-09-26 18:31:45.462661+00
1b742e37-c5cf-48e5-bda9-8e73766f4363	bd78a83d-5740-4d0d-9000-cdf29d332f27	377c54d8-88d8-4698-a98c-27a42d2dae92	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	1	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
71278106-2342-442c-a3fd-fd79661b8bf5	9bab5f84-a53e-49d6-91f8-eef87bf5960c	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	3	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
b987758b-87aa-4185-8132-4fcf637f212e	3b6030a2-3993-4389-8c6c-d3427e0e680b	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	5	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
90b1b65d-b2ea-42b7-809b-72563e940415	a8c5b60b-8763-4325-900d-07d7540e6015	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	5	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
4471c037-b237-4660-90cf-ee2a844a980b	3d87692f-06c1-4403-95ff-c70d1598700a	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	4	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
2153c5e4-d6a6-4ebf-a7de-06ee6c24c5e0	9389e5a2-816f-4e52-950b-a9af117c7ad1	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	5	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
39b83558-09f0-418e-86d0-a3e0c97d07e8	a5e41a1c-9682-4873-8924-f11edf9b3fce	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	5	5	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
6cf2e054-5a79-4574-97d7-34700106e081	b2734396-c5d2-4b05-99d0-986a180a98a6	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	5	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
40bce486-48da-44db-959f-4c39238e1785	2c310487-b2d2-4f8a-bdc3-0fcd75eff4a9	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
8a6334f3-1b6f-456a-901b-f879c34631d7	d05292f5-3e9f-4e51-bb50-05a6534dc9b8	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	5	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
e6c2e391-cddb-4f7d-8b6a-a0686bba84fd	89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	5	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
b19fe3f3-6385-4b11-b345-01689d9fce0e	30e16278-0ca1-4efa-a03b-7168658bb2c2	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	4	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
014fb3f2-f409-42ec-825f-9e7e7f3b624f	b010ad34-1872-4015-9120-b4d6e175bda3	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	5	5	Very practical session.	f	2026-09-26 18:31:45.462661+00
c6fa8341-8ccb-4884-b659-8e7ee302864a	88b2de0e-fb93-4402-98ef-3c1bd149f61d	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	5	4	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
3c357d27-4674-45dc-9455-d2fcf82b79ba	f1831789-130e-485d-bc67-67fe3b5fc6af	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	4	5	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
4b29bdb6-6f2d-46aa-9678-4a33c918e92f	a5fd318c-feeb-4b1b-b739-3e40a59dde18	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	4	5	Very practical session.	f	2026-09-26 18:31:45.462661+00
1d8e8894-62c2-4416-9c97-ad901bb07874	ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	5	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
839cbf22-2516-414c-b302-aa7a52d2792c	312e5b6a-024a-4a5d-9389-357b73426d42	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	5	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
566fcb3f-4a00-49e5-b25c-439891b1013d	732e74cf-b9b7-4adc-a43a-794430d7fe49	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
71c205a3-fbb8-4ed0-80e6-0e1df195c0f0	4135122d-a240-499c-8de4-3db650d7acc9	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	3	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
d1835f2a-e6ef-40b5-a74c-892257bf09d8	a4e9e21f-10e4-4c84-b4d0-9f420cf171c0	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	5	5	Clear explanations.	f	2026-09-26 18:31:45.462661+00
60687719-2ee3-43eb-ba69-51d68e7bfa2a	f51dbbc6-5c8a-487d-b785-786417797dc8	1b09caa2-5a18-4f05-9a17-18d849ee499f	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	5	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
9847aa3e-ef6f-4447-afa6-72a53fadd9ce	a8c5b60b-8763-4325-900d-07d7540e6015	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
16e1304a-6b6e-435e-9345-3107d95d2464	7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
daa00ee6-3601-4754-ad8c-dbe0229b57ee	f74aaa72-56ba-476d-9aed-ffbe2e41dd50	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
f3f6da2f-7352-4ecd-a851-637502c245f7	d05292f5-3e9f-4e51-bb50-05a6534dc9b8	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	4	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
311e25c2-3753-4f54-a95a-80d0aa66a057	8be014b0-ed46-43db-89e2-91a301c618db	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
5b82640e-8df6-4263-939b-3340419cb074	1e418187-2717-4b94-934c-e5ca025993d8	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
823fe628-591b-40af-8517-f7353d3da2cb	48ae8c9d-e783-46c2-abf3-cc9d31e16d81	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
4fbd5dd8-ab76-4dac-b19b-6cd508fb973e	62868b88-e860-457b-8605-04153588489b	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	4	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
a4759a56-706b-4e3e-a41e-e983e5b7b5ee	4135122d-a240-499c-8de4-3db650d7acc9	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
0f598aa0-0857-45c2-a188-6928abc972bc	76e808de-304b-44e5-b793-8516b5fec7bb	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
3c8f4867-b5aa-4994-8bb7-bfc91f0ae4ee	e6ef6d8e-87f0-4c3d-8ac9-dccb12f222f1	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
0619fba5-1d44-49b2-813a-f4ac0df8ec06	8b09383e-447b-4fa0-b605-8d8cf4f3f527	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
b0d850a9-e3fb-4056-bfa6-d745a9da3784	ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2	2	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
c03eda25-b0d3-4806-a688-77b56fe680d9	4ace2ecd-317e-494c-ad50-71e2794fb907	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
1a84382e-14e6-4a5b-a78d-fc892af38127	d072273b-7a6f-4fa4-9195-1697050cfab1	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
404ac545-d247-4c1c-b683-44ab16019681	696886f6-a4bf-44a6-9ba9-c939abb52137	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	2	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
a152a930-c21f-44ac-96bc-33b3384fa046	5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	614b89b9-ad9a-4481-9970-4691dd4e45dc	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	2	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
57be4e72-921a-4f73-99a2-403769ceb1e2	a6afe850-9547-4fac-892c-00558ad8f725	6be0b4cc-255a-4372-be78-8bd23dee561b	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	4	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
57a8938d-3cb2-4fd1-af80-d70b1facbeff	b97db5e7-dca3-4f88-8318-6d457e09be91	6be0b4cc-255a-4372-be78-8bd23dee561b	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
4aa7bc44-8628-4bfb-a3d1-3e743a57426b	ec4cdace-5f9a-4198-9518-7c59753a1127	6be0b4cc-255a-4372-be78-8bd23dee561b	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	4	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
16ec205e-dff3-46c1-a628-d7e2bcea4977	625944b1-2b9b-433b-9af5-e72894aa7a58	6be0b4cc-255a-4372-be78-8bd23dee561b	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	4	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
4b131fe0-d5c5-4a93-984c-77b54af7ecd1	8a0a7128-e6e6-4b49-8395-52723dda0b7c	6be0b4cc-255a-4372-be78-8bd23dee561b	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
50ff1b20-2a58-480d-91a3-64c6243ac305	b2734396-c5d2-4b05-99d0-986a180a98a6	6be0b4cc-255a-4372-be78-8bd23dee561b	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	4	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
e8f4e323-bcde-4d00-a72f-13c9612e0319	08758984-558b-4323-bc35-2a202203d87b	6be0b4cc-255a-4372-be78-8bd23dee561b	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
1d9f1c06-c664-4347-8ff6-2c06404f70fc	78313b75-0494-43a4-b199-ff1928254f44	6be0b4cc-255a-4372-be78-8bd23dee561b	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	4	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
0e6fb88d-7e79-4d6c-8592-2b8be2cbf27f	10e55ead-3752-4108-a6b5-5a48ee709f03	6be0b4cc-255a-4372-be78-8bd23dee561b	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
18a95a1a-eb33-4694-8948-b2a0179ee55d	f8cb8b17-b65c-4df2-baab-62604c96a8c0	6be0b4cc-255a-4372-be78-8bd23dee561b	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
4676e37d-af83-492d-a1a0-e34ac9ec3035	e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	6be0b4cc-255a-4372-be78-8bd23dee561b	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	4	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
0b5483d0-e3b9-4109-9a18-11cfb54462e0	ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	6be0b4cc-255a-4372-be78-8bd23dee561b	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
7e7982da-1d78-4d61-b5cc-044f5625b80f	18407190-2219-4190-9b20-ee775b0094ef	6be0b4cc-255a-4372-be78-8bd23dee561b	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
41d24d83-73e4-4097-8a63-6e4a5d5b59ce	28fe79f0-6207-4e0c-8bae-1eb02eed759b	6be0b4cc-255a-4372-be78-8bd23dee561b	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
4b1c4e47-aaa2-41f5-8ff0-f00c31c0af1a	a7bae3c0-0e2c-42db-8e35-79114d5dfe80	eec7cc46-3395-4f21-8c7f-cb99bee58b55	\N	d6196926-78e5-4750-9dda-c802473b00e2	3	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
397e54f6-bbad-479b-a61f-5ff89010a7e3	78313b75-0494-43a4-b199-ff1928254f44	eec7cc46-3395-4f21-8c7f-cb99bee58b55	\N	d6196926-78e5-4750-9dda-c802473b00e2	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
1e4db6f3-76db-410f-87b8-c8b93cfdd60c	f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d	eec7cc46-3395-4f21-8c7f-cb99bee58b55	\N	d6196926-78e5-4750-9dda-c802473b00e2	4	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
1b3c76a8-41eb-43ad-80de-9be96e508b04	62868b88-e860-457b-8605-04153588489b	eec7cc46-3395-4f21-8c7f-cb99bee58b55	\N	d6196926-78e5-4750-9dda-c802473b00e2	3	5	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
7bfe424a-5ebb-4f30-97a8-a2e16b4f7307	3ded69a7-290c-47f6-bd29-7369f6f8e3c8	eec7cc46-3395-4f21-8c7f-cb99bee58b55	\N	d6196926-78e5-4750-9dda-c802473b00e2	4	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
d8dc9cfd-a8f1-4641-a8d7-3a38714ee509	3af00a36-1f7b-4846-a52a-b1871416c5b1	eec7cc46-3395-4f21-8c7f-cb99bee58b55	\N	d6196926-78e5-4750-9dda-c802473b00e2	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
e9ababdb-32c6-41d4-b015-4a686a816463	b2c7b829-9669-4258-ab45-acc4445b9d6d	eec7cc46-3395-4f21-8c7f-cb99bee58b55	\N	d6196926-78e5-4750-9dda-c802473b00e2	4	5	Very practical session.	f	2026-09-26 18:31:45.462661+00
ac125546-9f91-4387-b46f-ed158aa8cca8	6ec3f843-359c-4b5b-bc41-b3bd56c6e134	eec7cc46-3395-4f21-8c7f-cb99bee58b55	\N	d6196926-78e5-4750-9dda-c802473b00e2	4	3	Very practical session.	f	2026-09-26 18:31:45.462661+00
2380aa4d-7b57-4378-941f-93178ce11d8b	216136af-8b6b-44ae-a787-59506613a618	eec7cc46-3395-4f21-8c7f-cb99bee58b55	\N	d6196926-78e5-4750-9dda-c802473b00e2	4	4	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
ecb67ecc-784b-46c3-b9d2-6dea341de1ac	fda17094-1c9f-45de-a42c-aa815d09bc2a	eec7cc46-3395-4f21-8c7f-cb99bee58b55	\N	d6196926-78e5-4750-9dda-c802473b00e2	5	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
e763c66d-a164-42e8-883b-55702a9e205a	cc7120df-7364-4284-a971-893f524d1a25	eec7cc46-3395-4f21-8c7f-cb99bee58b55	\N	d6196926-78e5-4750-9dda-c802473b00e2	5	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
630260e9-2fe6-4910-a556-ac3d66dd99c1	fc08ec35-be50-46ec-8acb-0ddb68b16b22	eec7cc46-3395-4f21-8c7f-cb99bee58b55	\N	d6196926-78e5-4750-9dda-c802473b00e2	5	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
cc2be991-984d-4fd8-8a8b-a8fb9202a7fc	3ecf9082-92fa-49e4-a15f-87acb5504803	eec7cc46-3395-4f21-8c7f-cb99bee58b55	\N	d6196926-78e5-4750-9dda-c802473b00e2	5	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
35e8d750-6624-46e7-abda-b556de25fe07	69f12a27-893c-4791-987c-14fb10cbede4	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	\N	66a88386-7c29-44ae-805a-fd51d782743b	4	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
7e5dca53-5e0b-4baa-b5aa-5480db56bf2e	2731bad6-8e73-4106-8def-3df5df76b6ea	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	\N	66a88386-7c29-44ae-805a-fd51d782743b	4	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
3803b057-0bb6-48e9-8936-9144ce3dd2dd	62868b88-e860-457b-8605-04153588489b	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	\N	66a88386-7c29-44ae-805a-fd51d782743b	3	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
518e5084-dbf1-4780-9d24-f75ee6e361e0	0f80298a-f569-4c55-88aa-a57625e20751	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	\N	66a88386-7c29-44ae-805a-fd51d782743b	4	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
b9809ba5-063e-4e32-8444-93943ca83399	306af47d-26b6-4dc3-96ae-eb178609c1f6	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	\N	66a88386-7c29-44ae-805a-fd51d782743b	4	5	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
639d13ec-78a3-4ca9-93a4-9952fb7b4aff	f04f9044-cd22-4a29-8d93-333047a95f6a	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	\N	66a88386-7c29-44ae-805a-fd51d782743b	4	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
62872155-b487-434a-982a-e27ed6c2cd5c	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	\N	66a88386-7c29-44ae-805a-fd51d782743b	5	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
38d786ac-8320-4a9d-acee-7ce001148cb4	1eb0cec9-a12f-4f42-9d77-bf6e343e9a75	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	\N	66a88386-7c29-44ae-805a-fd51d782743b	3	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
4ed5f5e5-efe6-4dbb-9c2b-eff0ca87149f	2d970758-319c-400f-b2ba-93057f16a33e	a0fd8c4d-bcdd-4580-9968-fa32c45bac11	\N	66a88386-7c29-44ae-805a-fd51d782743b	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
c3a428c8-6e4f-47d4-a0c7-c2f3cc26d727	33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	3d04c87e-b5ec-45e8-951e-4bb279977080	\N	66a88386-7c29-44ae-805a-fd51d782743b	2	2	Clear explanations.	f	2026-09-26 18:31:45.462661+00
c3f84ebf-af16-4edb-bdad-0f33e7051c31	0d37acee-70ea-4604-8bd7-c995941443fd	3d04c87e-b5ec-45e8-951e-4bb279977080	\N	66a88386-7c29-44ae-805a-fd51d782743b	2	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
ec41a0e6-e1a6-4e62-91a9-0b5c589fdfb2	8a83194a-d3bc-49dd-8594-ed05a26d23a0	3d04c87e-b5ec-45e8-951e-4bb279977080	\N	66a88386-7c29-44ae-805a-fd51d782743b	3	2	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
f5c3f65f-b821-42bc-95af-427b576fc650	b8541832-74c6-404f-90d0-5fb6d3df7663	3d04c87e-b5ec-45e8-951e-4bb279977080	\N	66a88386-7c29-44ae-805a-fd51d782743b	2	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
b530ba60-f76f-4731-b9c0-6cfea59da025	032c01d5-4b5e-44f6-821d-2ba4342c938f	3d04c87e-b5ec-45e8-951e-4bb279977080	\N	66a88386-7c29-44ae-805a-fd51d782743b	2	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
9c2c388e-8805-4ba2-af67-a40513e47453	48f33e15-f87f-4629-ab82-4123ada4bdc4	3d04c87e-b5ec-45e8-951e-4bb279977080	\N	66a88386-7c29-44ae-805a-fd51d782743b	2	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
d54a06f3-97db-43a0-94d7-20edf8bf6645	28fe79f0-6207-4e0c-8bae-1eb02eed759b	3d04c87e-b5ec-45e8-951e-4bb279977080	\N	66a88386-7c29-44ae-805a-fd51d782743b	3	2	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
fa93dc76-69b1-491c-b51c-65ef5cc9215e	d2298ed0-2515-4232-b70f-845a98dac595	3d04c87e-b5ec-45e8-951e-4bb279977080	\N	66a88386-7c29-44ae-805a-fd51d782743b	3	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
ca1decd4-fdff-49ff-ab7b-75d88cf676f6	7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	3d04c87e-b5ec-45e8-951e-4bb279977080	\N	66a88386-7c29-44ae-805a-fd51d782743b	3	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
1eac4b06-b2a9-4a20-be49-b90edfb79117	65ef229b-117d-4946-b5bb-301e3f828fc2	3d04c87e-b5ec-45e8-951e-4bb279977080	\N	66a88386-7c29-44ae-805a-fd51d782743b	2	2	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
09aac7e1-7723-4544-8a85-85bcced113c3	ae420db9-d867-40d1-8d1a-01ee5d62e270	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	3	Clear explanations.	f	2026-09-26 18:31:45.462661+00
46949924-a225-43ef-a41b-eb992280869f	8b09383e-447b-4fa0-b605-8d8cf4f3f527	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	3	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
90c615eb-1dd8-4106-a103-6011e752374f	8ffbd0cf-b807-4193-af37-3a61482c76eb	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
8e35baad-da4a-473f-922a-6a4383a2e2b3	46e6d439-49ab-4001-b576-7df03d3babee	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
582c356b-7d72-445f-8d32-2a28f39d1c8c	6bb2ccef-6c0b-4baa-bc82-d037a1c93af1	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
d6a49232-e176-4a6c-a13f-cba24c7e1394	b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	2	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
4aa73868-4e06-4744-aa87-c0f194763e19	a8c5b60b-8763-4325-900d-07d7540e6015	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	2	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
6543ede9-e6b5-43d3-9e5d-925242c5b6fd	db9ec5a1-d0be-490d-91a6-bf32127bba75	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	4	2	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
f12136da-ecf0-4668-a5c5-bd6c21617e0a	bd78a83d-5740-4d0d-9000-cdf29d332f27	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
ac527e72-49e2-4181-a06c-e060fc7d34e5	4ace2ecd-317e-494c-ad50-71e2794fb907	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	4	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
7538b1c7-4db7-44b6-b86b-ad59ee01d5c7	3e1e22ae-3497-44dc-bb66-1a3c24a5af91	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	2	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
796b91f6-e885-42e4-80e5-d7f1aae3cee7	30e16278-0ca1-4efa-a03b-7168658bb2c2	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	3	Slides could be improved.	f	2026-09-26 18:31:45.462661+00
ae6fc873-bb19-40d5-9767-a0f157447cf8	0369edbf-d1ba-47c9-b17c-e67c29bf27fc	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
29e60fca-4312-4d6f-bd42-47ffa0b96cb1	c2900748-9036-4804-b4f0-feb22ac5b4fb	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	4	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
a28362b6-1232-4d87-8605-5f60868581f3	48f33e15-f87f-4629-ab82-4123ada4bdc4	6ede44f5-cacb-4f50-9ed5-e6155ad64bb7	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
e0d73ebe-386d-423d-8fb3-42fdc6a88940	fc08ec35-be50-46ec-8acb-0ddb68b16b22	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	\N	49992467-6281-4454-9a23-aa2dd4c74a95	4	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
caf6e39d-d3ec-45c4-84bc-01a1c284d3ba	90a570b4-9441-4d8b-981d-a7fa379054d3	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	\N	49992467-6281-4454-9a23-aa2dd4c74a95	4	3	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
1d87ed27-19ac-4d4f-980b-040a5501670b	3ecf9082-92fa-49e4-a15f-87acb5504803	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	\N	49992467-6281-4454-9a23-aa2dd4c74a95	4	4	Clear explanations.	f	2026-09-26 18:31:45.462661+00
9a3a839e-a5bb-4b8a-9d4c-98072188a582	707e086b-3312-442d-ac6d-9776ebe73deb	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	3	Very practical session.	f	2026-09-26 18:31:45.462661+00
6e82a179-e453-4fd5-94f2-09a963b11983	6a389990-e259-43a4-a9a2-7575b00029e0	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	\N	49992467-6281-4454-9a23-aa2dd4c74a95	4	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
43df2920-2b78-4407-89c9-c4de7e71dfc8	a8c5b60b-8763-4325-900d-07d7540e6015	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	4	Very practical session.	f	2026-09-26 18:31:45.462661+00
d5256f4c-3861-48fc-9230-8dca7c7a3d29	24cbfa5b-7114-43b8-957c-fe0efa420c25	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
d78f3566-f58e-4f3e-8e54-e30846778a28	696886f6-a4bf-44a6-9ba9-c939abb52137	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	4	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
6c37eabf-d891-48bb-ae73-a7486309f5a0	fc6668ea-582e-4fa2-a17f-eb264a39e1a2	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	\N	49992467-6281-4454-9a23-aa2dd4c74a95	4	3	Very practical session.	f	2026-09-26 18:31:45.462661+00
3fe09cc5-30c8-4423-8505-b4c96658786b	9897dc81-824b-4829-9fda-76c3f3c3e38f	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	2	Good examples from operations.	f	2026-09-26 18:31:45.462661+00
5ceead7f-4f74-4a39-9eda-465a535a49b9	7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	3	Very practical session.	f	2026-09-26 18:31:45.462661+00
ccdd18ab-aea2-45f3-815b-5541761b29b3	bea31be8-3a44-4869-9c56-dce2da936f51	b31c1fd4-c6e0-435e-888f-8aee7e684fb6	\N	49992467-6281-4454-9a23-aa2dd4c74a95	3	4	Needed more hands-on time.	f	2026-09-26 18:31:45.462661+00
\.


--
-- Data for Name: files; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.files (id, owner_id, storage_path, original_name, mime_type, size_bytes, sha256, created_at) FROM stdin;
\.


--
-- Data for Name: jobs; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.jobs (id, type, status, payload, result, error, dedupe_key, attempts, max_attempts, run_after, locked_at, locked_by, created_by, created_at, finished_at) FROM stdin;
\.


--
-- Data for Name: learning_resources; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.learning_resources (id, trainer_id, title, description, type, file_id, external_url, duration_seconds, page_count, skill_id, in_library, is_published, view_count, created_at) FROM stdin;
b9318e74-17b4-4cd5-9f62-9cec1e2c574e	2e42c806-48d6-422a-b282-2b30f0484c3c	Lecture: Nowcasting	\N	video	\N	/uploads/demo/nowcasting.mp4	1907	\N	9	t	t	130	2026-09-26 18:31:45.462661+00
04411396-da62-4fe6-9753-e8ab0f80d68e	2e42c806-48d6-422a-b282-2b30f0484c3c	Reading notes: Nowcasting	\N	pdf	\N	/uploads/demo/nowcasting.pdf	\N	28	9	t	t	367	2026-09-26 18:31:45.462661+00
8f5ddc1b-23a9-4c76-a322-718d2bc559ab	ff73e90e-1654-4bfd-8c73-43ad75a07f21	Lecture: NWP Modelling	\N	video	\N	/uploads/demo/nwp.mp4	3231	\N	8	t	t	182	2026-09-26 18:31:45.462661+00
b4670946-a115-49d8-9950-1e73c9a2b967	ff73e90e-1654-4bfd-8c73-43ad75a07f21	Reading notes: NWP Modelling	\N	pdf	\N	/uploads/demo/nwp.pdf	\N	17	8	t	t	267	2026-09-26 18:31:45.462661+00
8ca76a5a-c0d4-4c35-b5a3-acd01b146f14	ff73e90e-1654-4bfd-8c73-43ad75a07f21	Lecture: Automatic Weather Stations	\N	video	\N	/uploads/demo/aws.mp4	3170	\N	11	t	t	65	2026-09-26 18:31:45.462661+00
6c9b1523-7070-44d5-95e0-b96a8c6eff10	ff73e90e-1654-4bfd-8c73-43ad75a07f21	Reading notes: Automatic Weather Stations	\N	pdf	\N	/uploads/demo/aws.pdf	\N	20	11	t	t	98	2026-09-26 18:31:45.462661+00
266ad7f5-acda-4bd7-aeca-38b9ae346e16	ff38df49-9e3b-4df5-92a2-4852f8b79c74	Lecture: Tropical Cyclone Forecasting	\N	video	\N	/uploads/demo/tropical-cyclone.mp4	2267	\N	7	t	t	251	2026-09-26 18:31:45.462661+00
11c8ac3d-eb64-4145-981c-1b4c2340e38e	ff38df49-9e3b-4df5-92a2-4852f8b79c74	Reading notes: Tropical Cyclone Forecasting	\N	pdf	\N	/uploads/demo/tropical-cyclone.pdf	\N	40	7	t	t	367	2026-09-26 18:31:45.462661+00
12cef298-79fc-4d3a-a71a-55679636dbfd	2ae7d31a-ec05-402a-8104-ba433a1644eb	Lecture: Monsoon Forecasting	\N	video	\N	/uploads/demo/monsoon.mp4	3238	\N	6	t	t	313	2026-09-26 18:31:45.462661+00
9ebf48f2-d169-4adf-bbe7-27a1281ed2fc	2ae7d31a-ec05-402a-8104-ba433a1644eb	Reading notes: Monsoon Forecasting	\N	pdf	\N	/uploads/demo/monsoon.pdf	\N	33	6	t	t	186	2026-09-26 18:31:45.462661+00
bf4a94dc-e220-4410-b069-860e73ee3abd	5db62bba-e3f6-4551-81f7-9d9237055aa3	Lecture: Doppler Weather Radar	\N	video	\N	/uploads/demo/dwr.mp4	3087	\N	13	t	t	375	2026-09-26 18:31:45.462661+00
b2a7f555-e7a1-4931-bbf4-00dd8f21d884	5db62bba-e3f6-4551-81f7-9d9237055aa3	Reading notes: Doppler Weather Radar	\N	pdf	\N	/uploads/demo/dwr.pdf	\N	16	13	t	t	9	2026-09-26 18:31:45.462661+00
a523890b-7cd6-4c01-bb94-3dd64b46965f	9894043b-3b29-45e0-9abd-9b61597bf09a	Lecture: Satellite Meteorology	\N	video	\N	/uploads/demo/satellite.mp4	3150	\N	12	t	t	80	2026-09-26 18:31:45.462661+00
8cbbd15f-62cd-4b0a-beec-fbe1a40792b9	9894043b-3b29-45e0-9abd-9b61597bf09a	Reading notes: Satellite Meteorology	\N	pdf	\N	/uploads/demo/satellite.pdf	\N	37	12	t	t	375	2026-09-26 18:31:45.462661+00
970cafb0-3fa8-4de6-93ac-8c796f293508	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	Lecture: Automatic Weather Stations	\N	video	\N	/uploads/demo/aws.mp4	2736	\N	11	t	t	144	2026-09-26 18:31:45.462661+00
528e9d28-b772-4bb4-b148-104a940d50dc	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	Reading notes: Automatic Weather Stations	\N	pdf	\N	/uploads/demo/aws.pdf	\N	24	11	t	t	152	2026-09-26 18:31:45.462661+00
63c74bba-3732-48a4-8a27-64a586612470	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	Lecture: Thunderstorm & Lightning	\N	video	\N	/uploads/demo/thunderstorm.mp4	2588	\N	16	t	t	95	2026-09-26 18:31:45.462661+00
266397d0-4346-4f2a-a21e-0c1a7192e62e	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	Reading notes: Thunderstorm & Lightning	\N	pdf	\N	/uploads/demo/thunderstorm.pdf	\N	36	16	t	t	333	2026-09-26 18:31:45.462661+00
9c8840fb-31fa-4ab8-81d0-9fae24516545	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	Lecture: Climate Data Analysis	\N	video	\N	/uploads/demo/climate-data.mp4	1977	\N	15	t	t	195	2026-09-26 18:31:45.462661+00
222cc68e-b6df-40ab-a659-4fdb20e5850a	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	Reading notes: Climate Data Analysis	\N	pdf	\N	/uploads/demo/climate-data.pdf	\N	41	15	t	t	359	2026-09-26 18:31:45.462661+00
065361df-8e29-4131-a842-778f2c87f10d	954754ab-6ecc-4d9a-a614-8cc84ffb3348	Lecture: Agromet Advisory	\N	video	\N	/uploads/demo/agromet.mp4	3254	\N	14	t	t	220	2026-09-26 18:31:45.462661+00
aeeb0db5-fe2a-41e2-89fe-337adee17a60	954754ab-6ecc-4d9a-a614-8cc84ffb3348	Reading notes: Agromet Advisory	\N	pdf	\N	/uploads/demo/agromet.pdf	\N	29	14	t	t	198	2026-09-26 18:31:45.462661+00
d92e1b18-30c5-4b72-8e04-229e87f882b6	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	Lecture: NWP Modelling	\N	video	\N	/uploads/demo/nwp.mp4	1866	\N	8	t	t	296	2026-09-26 18:31:45.462661+00
e1f2e85d-ab0d-47dc-9c3e-860ca43231ce	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	Reading notes: NWP Modelling	\N	pdf	\N	/uploads/demo/nwp.pdf	\N	33	8	t	t	33	2026-09-26 18:31:45.462661+00
e18148dd-a97d-489b-8873-6f8e67ad3278	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	Lecture: Flood Meteorology	\N	video	\N	/uploads/demo/flood-met.mp4	2190	\N	18	t	t	297	2026-09-26 18:31:45.462661+00
ba90bdd4-e63d-4ce3-a14c-7a159d7927a6	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	Reading notes: Flood Meteorology	\N	pdf	\N	/uploads/demo/flood-met.pdf	\N	17	18	t	t	315	2026-09-26 18:31:45.462661+00
696449d2-e675-4e3a-8ae0-5e1942fe40f3	e9178b69-2339-4a64-857f-5ad0630325a5	Lecture: Heatwave & Cold Wave	\N	video	\N	/uploads/demo/heatwave.mp4	3272	\N	17	t	t	258	2026-09-26 18:31:45.462661+00
22a1ecbe-c779-416d-960c-18a138fd3d8b	e9178b69-2339-4a64-857f-5ad0630325a5	Reading notes: Heatwave & Cold Wave	\N	pdf	\N	/uploads/demo/heatwave.pdf	\N	14	17	t	t	81	2026-09-26 18:31:45.462661+00
eb2b07e3-64da-44ec-aaf4-71b77be14021	82556fbd-47bf-44ac-aae9-3499c844ea75	Lecture: Thunderstorm & Lightning	\N	video	\N	/uploads/demo/thunderstorm.mp4	1961	\N	16	t	t	281	2026-09-26 18:31:45.462661+00
190ed27d-6847-4411-a680-7b42de447332	82556fbd-47bf-44ac-aae9-3499c844ea75	Reading notes: Thunderstorm & Lightning	\N	pdf	\N	/uploads/demo/thunderstorm.pdf	\N	38	16	t	t	103	2026-09-26 18:31:45.462661+00
12edd791-13fa-4e39-8379-e876a8a51171	fa5ba122-30c1-4e56-bc6b-b761794b1528	Lecture: Python for Meteorology	\N	video	\N	/uploads/demo/python-met.mp4	3383	\N	20	t	t	231	2026-09-26 18:31:45.462661+00
24ab3f59-41ec-4d42-80f6-52c9aed376d3	fa5ba122-30c1-4e56-bc6b-b761794b1528	Reading notes: Python for Meteorology	\N	pdf	\N	/uploads/demo/python-met.pdf	\N	15	20	t	t	157	2026-09-26 18:31:45.462661+00
f62ccb37-27fd-49ba-86b3-0fbc9f46f8a9	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	Lecture: Nowcasting	\N	video	\N	/uploads/demo/nowcasting.mp4	2159	\N	9	t	t	335	2026-09-26 18:31:45.462661+00
59e7d935-17c4-43fc-b274-8624a339adfb	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	Reading notes: Nowcasting	\N	pdf	\N	/uploads/demo/nowcasting.pdf	\N	19	9	t	t	19	2026-09-26 18:31:45.462661+00
33a53d0b-4f4a-4899-913e-a9cf8209a2a1	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	Lecture: Satellite Meteorology	\N	video	\N	/uploads/demo/satellite.mp4	3437	\N	12	t	t	107	2026-09-26 18:31:45.462661+00
1c3c3009-d638-48f9-ba7c-1f2fd737e9dc	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	Reading notes: Satellite Meteorology	\N	pdf	\N	/uploads/demo/satellite.pdf	\N	19	12	t	t	118	2026-09-26 18:31:45.462661+00
5c666d46-e9ff-4b3c-bc2f-d477a8b2941f	dab8c835-d264-43fb-9b10-7482bacf6b99	Lecture: NWP Modelling	\N	video	\N	/uploads/demo/nwp.mp4	3199	\N	8	t	t	16	2026-09-26 18:31:45.462661+00
a863dc9a-2924-4568-90f7-492c15cec216	dab8c835-d264-43fb-9b10-7482bacf6b99	Reading notes: NWP Modelling	\N	pdf	\N	/uploads/demo/nwp.pdf	\N	37	8	t	t	206	2026-09-26 18:31:45.462661+00
5b82eaf6-650c-425d-993e-b62f6150d543	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	Lecture: Tropical Cyclone Forecasting	\N	video	\N	/uploads/demo/tropical-cyclone.mp4	2690	\N	7	t	t	79	2026-09-26 18:31:45.462661+00
c8706732-af64-4787-8ee4-aaa42b352a66	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	Reading notes: Tropical Cyclone Forecasting	\N	pdf	\N	/uploads/demo/tropical-cyclone.pdf	\N	23	7	t	t	126	2026-09-26 18:31:45.462661+00
a2df678d-7aa0-4d97-a85c-b85dd54225c6	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	Lecture: Climate Data Analysis	\N	video	\N	/uploads/demo/climate-data.mp4	2248	\N	15	t	t	33	2026-09-26 18:31:45.462661+00
dae3326e-bddb-4f59-9a2d-5e37dc1eb95a	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	Reading notes: Climate Data Analysis	\N	pdf	\N	/uploads/demo/climate-data.pdf	\N	26	15	t	t	372	2026-09-26 18:31:45.462661+00
6684bc27-7ee6-431a-bbce-0b43da4e4cfb	d6196926-78e5-4750-9dda-c802473b00e2	Lecture: Monsoon Forecasting	\N	video	\N	/uploads/demo/monsoon.mp4	2374	\N	6	t	t	337	2026-09-26 18:31:45.462661+00
17d2bd3a-902b-434b-b82e-700fc08561b0	d6196926-78e5-4750-9dda-c802473b00e2	Reading notes: Monsoon Forecasting	\N	pdf	\N	/uploads/demo/monsoon.pdf	\N	13	6	t	t	28	2026-09-26 18:31:45.462661+00
490663ce-ffc2-4ca0-83e8-e5d317d52260	66a88386-7c29-44ae-805a-fd51d782743b	Lecture: Doppler Weather Radar	\N	video	\N	/uploads/demo/dwr.mp4	1812	\N	13	t	t	386	2026-09-26 18:31:45.462661+00
b239ce57-38ba-4980-84b8-77663070f329	66a88386-7c29-44ae-805a-fd51d782743b	Reading notes: Doppler Weather Radar	\N	pdf	\N	/uploads/demo/dwr.pdf	\N	20	13	t	t	207	2026-09-26 18:31:45.462661+00
e4ded3e1-1c93-4a2f-a63c-c48712f322ff	66a88386-7c29-44ae-805a-fd51d782743b	Lecture: Flood Meteorology	\N	video	\N	/uploads/demo/flood-met.mp4	1918	\N	18	t	t	185	2026-09-26 18:31:45.462661+00
cb2c0c39-bed3-434a-82a8-89657a422d8e	66a88386-7c29-44ae-805a-fd51d782743b	Reading notes: Flood Meteorology	\N	pdf	\N	/uploads/demo/flood-met.pdf	\N	19	18	t	t	389	2026-09-26 18:31:45.462661+00
d4c23cf9-a29d-48f9-9f97-f6a502db63dc	49992467-6281-4454-9a23-aa2dd4c74a95	Lecture: Satellite Meteorology	\N	video	\N	/uploads/demo/satellite.mp4	3329	\N	12	t	t	374	2026-09-26 18:31:45.462661+00
dcfd66c3-a0d5-4f1e-9b32-831f72c13fc8	49992467-6281-4454-9a23-aa2dd4c74a95	Reading notes: Satellite Meteorology	\N	pdf	\N	/uploads/demo/satellite.pdf	\N	28	12	t	t	126	2026-09-26 18:31:45.462661+00
f00ff310-7daf-477b-8b9f-839b3d022e57	49992467-6281-4454-9a23-aa2dd4c74a95	Lecture: Heatwave & Cold Wave	\N	video	\N	/uploads/demo/heatwave.mp4	3294	\N	17	t	t	160	2026-09-26 18:31:45.462661+00
07598617-736b-49cd-8177-aca103292d24	49992467-6281-4454-9a23-aa2dd4c74a95	Reading notes: Heatwave & Cold Wave	\N	pdf	\N	/uploads/demo/heatwave.pdf	\N	21	17	t	t	268	2026-09-26 18:31:45.462661+00
\.


--
-- Data for Name: notifications; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.notifications (id, user_id, type, title, body, link, dedupe_key, read_at, created_at) FROM stdin;
\.


--
-- Data for Name: profiles; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.profiles (user_id, headline, bio, date_of_joining, total_experience_months, location, expertise_summary, is_available, embedding, updated_at) FROM stdin;
85e9f6c3-f766-43d5-8fa9-17faa945a923	Capacity Building Cell, IMD HQ	\N	\N	0	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
ff73e90e-1654-4bfd-8c73-43ad75a07f21	Specialist in NWP Modelling	\N	2015-09-29	154	\N	Works on nwp, wrf, gfs, numerical weather, ensemble, data assimilation. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
ff38df49-9e3b-4df5-92a2-4852f8b79c74	Specialist in Tropical Cyclone Forecasting	\N	2006-10-01	237	\N	Works on cyclone, tropical cyclone, storm surge, track. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
2ae7d31a-ec05-402a-8104-ba433a1644eb	Specialist in Monsoon Forecasting	\N	2007-10-01	56	\N	Works on monsoon, rainfall, southwest monsoon, onset. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
5db62bba-e3f6-4551-81f7-9d9237055aa3	Specialist in Doppler Weather Radar	\N	2005-10-01	270	\N	Works on radar, doppler, dwr, reflectivity. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
9894043b-3b29-45e0-9abd-9b61597bf09a	Specialist in Satellite Meteorology	\N	2010-09-30	85	\N	Works on satellite, insat, remote sensing, imagery. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	Specialist in Climate Data Analysis	\N	2010-09-30	92	\N	Works on climate data, trend, reanalysis, era5. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
954754ab-6ecc-4d9a-a614-8cc84ffb3348	Specialist in Agromet Advisory	\N	2019-09-28	111	\N	Works on agromet, agriculture, crop, advisory. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
62f1ad05-4a27-46cd-93f8-7a570f80f4f3	Specialist in Flood Meteorology	\N	2020-09-27	188	\N	Works on flood, hydrology, qpf, river. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
e9178b69-2339-4a64-857f-5ad0630325a5	Specialist in Heatwave & Cold Wave	\N	2017-09-28	149	\N	Works on heatwave, heat wave, cold wave, temperature. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
82556fbd-47bf-44ac-aae9-3499c844ea75	Specialist in Thunderstorm & Lightning	\N	2012-09-29	100	\N	Works on thunderstorm, lightning, squall, hail. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
fa5ba122-30c1-4e56-bc6b-b761794b1528	Specialist in Python for Meteorology	\N	2007-10-01	269	\N	Works on python, xarray, metpy, netcdf. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	Specialist in Nowcasting	\N	2010-09-30	113	\N	Works on nowcast, nowcasting, short-range, convective. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
dab8c835-d264-43fb-9b10-7482bacf6b99	Specialist in NWP Modelling	\N	2005-10-01	99	\N	Works on nwp, wrf, gfs, numerical weather, ensemble, data assimilation. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
a22b9cb3-9b82-4d48-a453-6deeb2e9f273	Specialist in Tropical Cyclone Forecasting	\N	2021-09-27	273	\N	Works on cyclone, tropical cyclone, storm surge, track. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
d6196926-78e5-4750-9dda-c802473b00e2	Specialist in Monsoon Forecasting	\N	2005-10-01	174	\N	Works on monsoon, rainfall, southwest monsoon, onset. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
66a88386-7c29-44ae-805a-fd51d782743b	Specialist in Doppler Weather Radar	\N	2018-09-28	108	\N	Works on radar, doppler, dwr, reflectivity. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
49992467-6281-4454-9a23-aa2dd4c74a95	Specialist in Satellite Meteorology	\N	2008-09-30	253	\N	Works on satellite, insat, remote sensing, imagery. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
006ddbd1-35cc-4010-9363-d8234dae479e	Specialist in Automatic Weather Stations	\N	2003-10-02	133	\N	Works on aws, automatic weather station, surface observation. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
a2e26d13-6f79-43d6-9749-2676a39be455	Specialist in Climate Data Analysis	\N	2021-09-27	193	\N	Works on climate data, trend, reanalysis, era5. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
e9f6bde5-9ab9-477d-8669-134bdc4ad9ed	Specialist in Agromet Advisory	\N	2006-10-01	141	\N	Works on agromet, agriculture, crop, advisory. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
9a3e7d30-cc90-4d84-8fad-fc7d979156c3	Specialist in Flood Meteorology	\N	2010-09-30	171	\N	Works on flood, hydrology, qpf, river. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
7108643a-28fb-4548-8b93-ed349eab59f3	Specialist in Heatwave & Cold Wave	\N	2022-09-27	81	\N	Works on heatwave, heat wave, cold wave, temperature. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
39496ad1-eecc-4826-8899-1dc4f0d96f73	Specialist in Thunderstorm & Lightning	\N	2009-09-30	184	\N	Works on thunderstorm, lightning, squall, hail. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
87214765-f9ce-468a-a0f1-98e208a690ec	Specialist in Python for Meteorology	\N	2012-09-29	275	\N	Works on python, xarray, metpy, netcdf. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
bb9ed2a7-08bf-40bf-9125-220f11e3b138	Specialist in Nowcasting	\N	2016-09-28	264	\N	Works on nowcast, nowcasting, short-range, convective. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
2042a866-172d-42f9-96e4-7dc22771dc04	Specialist in NWP Modelling	\N	2005-10-01	221	\N	Works on nwp, wrf, gfs, numerical weather, ensemble, data assimilation. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
7102ca49-b74d-4460-847e-ce4e91f8c048	Specialist in Tropical Cyclone Forecasting	\N	2004-10-01	136	\N	Works on cyclone, tropical cyclone, storm surge, track. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
798470a9-6675-4483-8cd4-d1af4302c5af	Specialist in Monsoon Forecasting	\N	2020-09-27	249	\N	Works on monsoon, rainfall, southwest monsoon, onset. Trains forecasters and observers.	t	\N	2026-09-26 18:31:45.462661+00
bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	Specialist in Automatic Weather Stations	\N	2004-10-01	241	\N	Works on aws, automatic weather station, surface observation. Trains forecasters and observers. Some radiosonde exposure.	t	\N	2026-09-26 18:31:45.462661+00
78313b75-0494-43a4-b199-ff1928254f44	IMD staff	\N	\N	77	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
43e91850-0b48-4bcd-be9d-c38742b91841	IMD staff	\N	\N	5	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
72a5ceb8-6b68-433d-9b99-d62b8c9f1375	IMD staff	\N	\N	7	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
2e35b549-e1b5-4e61-a221-b0799208258c	IMD staff	\N	\N	33	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
f8db984c-e990-4ead-b69f-74d50fa951dc	IMD staff	\N	\N	150	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
7f53c53d-3323-4146-8cea-01d6c38b4f77	IMD staff	\N	\N	70	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
3e1e22ae-3497-44dc-bb66-1a3c24a5af91	IMD staff	\N	\N	54	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
fbc637df-19cd-4ec5-b08d-49ce15747076	IMD staff	\N	\N	12	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
7b68a9ad-6ab1-4164-89e4-b13eea948a92	IMD staff	\N	\N	119	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
6f1d6dd6-daa9-4660-a06f-527bf32f663e	IMD staff	\N	\N	1	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
fc08ec35-be50-46ec-8acb-0ddb68b16b22	IMD staff	\N	\N	170	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
2731bad6-8e73-4106-8def-3df5df76b6ea	IMD staff	\N	\N	175	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
ab65843a-c349-4b21-b43b-9302ed8231b4	IMD staff	\N	\N	174	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
ab903484-298e-4415-93b0-8f5ea844bf31	IMD staff	\N	\N	156	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
9389e5a2-816f-4e52-950b-a9af117c7ad1	IMD staff	\N	\N	27	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
602031bb-35f7-4efc-9f2c-f0bcf7d5ef3b	IMD staff	\N	\N	140	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
b28e0245-9390-4127-ad3f-80ace4775f43	IMD staff	\N	\N	132	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
3d04f1c2-2486-4f53-bde5-76ba389ec266	IMD staff	\N	\N	128	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
2af59a77-c993-46c3-a686-b91217814d48	IMD staff	\N	\N	41	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
c43722c6-7e70-49e0-acb4-ba4f953e36a8	IMD staff	\N	\N	40	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
7b1099fc-7596-4be6-9ab4-990d535c39a5	IMD staff	\N	\N	95	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
732e74cf-b9b7-4adc-a43a-794430d7fe49	IMD staff	\N	\N	168	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
48f33e15-f87f-4629-ab82-4123ada4bdc4	IMD staff	\N	\N	172	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
2e42c806-48d6-422a-b282-2b30f0484c3c	Specialist in Nowcasting	\N	2016-09-28	214	\N	Works on nowcast, nowcasting, short-range, convective. Trains forecasters and observers.	t	\N	2026-09-28 16:43:47.66024+00
3af00a36-1f7b-4846-a52a-b1871416c5b1	IMD staff	\N	\N	176	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
7acc259e-1231-481b-ab79-59821fd46534	IMD staff	\N	\N	162	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
05a922f4-7a9b-427c-bd4f-34ee3bdcfcf6	IMD staff	\N	\N	135	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
286bd41d-35d4-4b43-b05b-8548dab978ab	IMD staff	\N	\N	89	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	IMD staff	\N	\N	142	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
1eb0cec9-a12f-4f42-9d77-bf6e343e9a75	IMD staff	\N	\N	149	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
f51dbbc6-5c8a-487d-b785-786417797dc8	IMD staff	\N	\N	19	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
562af427-bd16-4c30-940b-5d6121d738c8	IMD staff	\N	\N	166	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
696886f6-a4bf-44a6-9ba9-c939abb52137	IMD staff	\N	\N	13	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
a4e9e21f-10e4-4c84-b4d0-9f420cf171c0	IMD staff	\N	\N	176	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
b8541832-74c6-404f-90d0-5fb6d3df7663	IMD staff	\N	\N	132	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
7e426fed-4c2e-46f4-866a-7b8aa048cf06	IMD staff	\N	\N	127	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
9bab5f84-a53e-49d6-91f8-eef87bf5960c	IMD staff	\N	\N	2	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
202e1651-21c8-45c8-80d1-f326b27aec05	IMD staff	\N	\N	33	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
28fe79f0-6207-4e0c-8bae-1eb02eed759b	IMD staff	\N	\N	95	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
dbccc807-eaba-41f6-aabc-14c515010185	IMD staff	\N	\N	157	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	IMD staff	\N	\N	114	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
3ded69a7-290c-47f6-bd29-7369f6f8e3c8	IMD staff	\N	\N	106	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
48ae8c9d-e783-46c2-abf3-cc9d31e16d81	IMD staff	\N	\N	119	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
350093ae-4f68-46a9-a0af-c33a9b87c340	IMD staff	\N	\N	25	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
a596803e-b844-4f79-9db8-48d4b3d5abb7	IMD staff	\N	\N	36	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
24cbfa5b-7114-43b8-957c-fe0efa420c25	IMD staff	\N	\N	88	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
f74aaa72-56ba-476d-9aed-ffbe2e41dd50	IMD staff	\N	\N	166	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
69f12a27-893c-4791-987c-14fb10cbede4	IMD staff	\N	\N	102	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
a17abc66-209e-405f-bcd6-c39e54cbce66	IMD staff	\N	\N	143	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
cbd81a81-1d5a-4273-8494-11efdd5fd354	IMD staff	\N	\N	155	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
d05292f5-3e9f-4e51-bb50-05a6534dc9b8	IMD staff	\N	\N	94	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
ea8fa5c6-6833-4701-9073-dd4ff3f78cb8	IMD staff	\N	\N	106	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
4ace2ecd-317e-494c-ad50-71e2794fb907	IMD staff	\N	\N	71	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
d22f23cf-8a58-499a-8dba-92806f1622ef	IMD staff	\N	\N	100	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
8ffbd0cf-b807-4193-af37-3a61482c76eb	IMD staff	\N	\N	61	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
bea31be8-3a44-4869-9c56-dce2da936f51	IMD staff	\N	\N	177	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
3d87692f-06c1-4403-95ff-c70d1598700a	IMD staff	\N	\N	57	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
60e67627-9116-4358-a94b-89c0416805f0	IMD staff	\N	\N	168	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
3b6030a2-3993-4389-8c6c-d3427e0e680b	IMD staff	\N	\N	170	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
f75210c9-faa1-45c8-9314-a65724983502	IMD staff	\N	\N	29	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
306af47d-26b6-4dc3-96ae-eb178609c1f6	IMD staff	\N	\N	92	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
0f80298a-f569-4c55-88aa-a57625e20751	IMD staff	\N	\N	27	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
0d37acee-70ea-4604-8bd7-c995941443fd	IMD staff	\N	\N	143	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
b2c7b829-9669-4258-ab45-acc4445b9d6d	IMD staff	\N	\N	62	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
333f633a-a466-43e6-9c02-cf743b327694	IMD staff	\N	\N	42	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
5d9905c7-91e8-4bd9-b187-b1b8772e0f63	IMD staff	\N	\N	14	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
b010ad34-1872-4015-9120-b4d6e175bda3	IMD staff	\N	\N	179	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
4d5fd264-452f-4436-8eca-5c6c62afb143	IMD staff	\N	\N	76	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	IMD staff	\N	\N	168	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
9b9ade46-b30d-4a4c-ba6c-a66c454125e3	IMD staff	\N	\N	28	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
fafec148-becc-4918-b1e0-08794a94f6de	IMD staff	\N	\N	51	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
bd78a83d-5740-4d0d-9000-cdf29d332f27	IMD staff	\N	\N	83	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
76e808de-304b-44e5-b793-8516b5fec7bb	IMD staff	\N	\N	85	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
65ef229b-117d-4946-b5bb-301e3f828fc2	IMD staff	\N	\N	24	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
17231857-2d57-46f3-aecc-cb26a0865adb	IMD staff	\N	\N	9	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
6a389990-e259-43a4-a9a2-7575b00029e0	IMD staff	\N	\N	79	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
a6afe850-9547-4fac-892c-00558ad8f725	IMD staff	\N	\N	99	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
2d970758-319c-400f-b2ba-93057f16a33e	IMD staff	\N	\N	119	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
77c70aa0-ddd9-4445-be30-4817de1cbfd0	IMD staff	\N	\N	156	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
a5102b13-4107-4fe5-b7a0-064dd07042ee	IMD staff	\N	\N	8	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
5a97c9d9-87c7-445c-9dc8-860fb29edb16	IMD staff	\N	\N	44	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
6cf3f90d-5b2f-422b-98a5-3df74a5bcbad	IMD staff	\N	\N	79	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
3a18a01e-89f7-474e-abf1-964581203793	IMD staff	\N	\N	78	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
f15de25e-7244-417b-a4b1-83fe58cb8cd8	IMD staff	\N	\N	133	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
5abfd2bf-a622-4ac2-8867-2be6525ec0e8	IMD staff	\N	\N	155	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
8a0a7128-e6e6-4b49-8395-52723dda0b7c	IMD staff	\N	\N	3	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	IMD staff	\N	\N	129	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
09cc88c9-6251-413b-9873-df6f5bb8b24d	IMD staff	\N	\N	176	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
e888ad9f-c064-4d24-8143-eec67fac7c1c	IMD staff	\N	\N	80	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
0369edbf-d1ba-47c9-b17c-e67c29bf27fc	IMD staff	\N	\N	142	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
fed72080-2568-4892-8047-0b3c72ff7fad	IMD staff	\N	\N	108	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
6ec3f843-359c-4b5b-bc41-b3bd56c6e134	IMD staff	\N	\N	131	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
90a570b4-9441-4d8b-981d-a7fa379054d3	IMD staff	\N	\N	147	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
a7bae3c0-0e2c-42db-8e35-79114d5dfe80	IMD staff	\N	\N	79	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
357f9f29-063f-4ff8-bdc9-6df1d8cb15b4	IMD staff	\N	\N	13	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
c2900748-9036-4804-b4f0-feb22ac5b4fb	IMD staff	\N	\N	118	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
152f1a01-df4b-4828-bf72-c1616f324c38	IMD staff	\N	\N	149	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	IMD staff	\N	\N	165	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
08758984-558b-4323-bc35-2a202203d87b	IMD staff	\N	\N	36	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
1e418187-2717-4b94-934c-e5ca025993d8	IMD staff	\N	\N	155	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
db9ec5a1-d0be-490d-91a6-bf32127bba75	IMD staff	\N	\N	110	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
f32344cc-9180-4953-b2cd-ba0f4bdb2eea	IMD staff	\N	\N	108	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
cc9e83f0-d177-4454-8ba5-f7581c6da639	IMD staff	\N	\N	89	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d	IMD staff	\N	\N	26	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
a8c5b60b-8763-4325-900d-07d7540e6015	IMD staff	\N	\N	7	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
6f3917b0-87b7-417f-a382-c38278a3d485	IMD staff	\N	\N	106	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
eee6bbaa-75eb-44f4-9892-d46194b720a9	IMD staff	\N	\N	13	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
ae420db9-d867-40d1-8d1a-01ee5d62e270	IMD staff	\N	\N	11	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
edc1993b-5333-4d99-bae2-9e80266978e0	IMD staff	\N	\N	106	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
707e086b-3312-442d-ac6d-9776ebe73deb	IMD staff	\N	\N	8	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
f1bc49b2-13bf-4cd2-a5ac-6aa2c12e8f95	IMD staff	\N	\N	23	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
46e6d439-49ab-4001-b576-7df03d3babee	IMD staff	\N	\N	1	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
8a83194a-d3bc-49dd-8594-ed05a26d23a0	IMD staff	\N	\N	148	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
862f76a0-443e-4a80-8644-ef4922c5f38a	IMD staff	\N	\N	56	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
9e08ecc2-e291-4516-bae3-07b43abc2620	IMD staff	\N	\N	108	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
62868b88-e860-457b-8605-04153588489b	IMD staff	\N	\N	124	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
c5c94cb5-5272-498b-b30a-d81279c22e12	IMD staff	\N	\N	72	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
5af34829-4d6f-425c-9f78-525896ea0526	IMD staff	\N	\N	49	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
573a471b-8236-4977-b94b-80b530b27e7c	IMD staff	\N	\N	3	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
6f9f3af8-fa88-4804-aa9b-5680afa4c1ba	IMD staff	\N	\N	156	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	IMD staff	\N	\N	122	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
88b2de0e-fb93-4402-98ef-3c1bd149f61d	IMD staff	\N	\N	140	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
f1831789-130e-485d-bc67-67fe3b5fc6af	IMD staff	\N	\N	107	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
a5fd318c-feeb-4b1b-b739-3e40a59dde18	IMD staff	\N	\N	149	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
2994671f-607f-4cdc-a2bc-22ab97456b28	IMD staff	\N	\N	113	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
729fd30e-9cfb-4751-bbdb-935fbbb7f994	IMD staff	\N	\N	85	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
b0ba69f7-69ce-411c-a22d-c449785d11e9	IMD staff	\N	\N	87	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	IMD staff	\N	\N	82	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
d072273b-7a6f-4fa4-9195-1697050cfab1	IMD staff	\N	\N	119	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
cf4749a6-6127-4d97-b2a0-17a11eabc216	IMD staff	\N	\N	126	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
f04f9044-cd22-4a29-8d93-333047a95f6a	IMD staff	\N	\N	94	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
4135122d-a240-499c-8de4-3db650d7acc9	IMD staff	\N	\N	47	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
293f638f-6b5e-4c5a-9282-533cc1c97688	IMD staff	\N	\N	138	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
889560c5-9238-4463-82d8-b65d7fdba4bc	IMD staff	\N	\N	83	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
10e55ead-3752-4108-a6b5-5a48ee709f03	IMD staff	\N	\N	78	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
c41e7852-875f-411b-93f1-7171f9871f9f	IMD staff	\N	\N	124	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
1f511b5e-1292-4202-860e-b54f11eda21e	IMD staff	\N	\N	161	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
312e5b6a-024a-4a5d-9389-357b73426d42	IMD staff	\N	\N	113	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
e6ef6d8e-87f0-4c3d-8ac9-dccb12f222f1	IMD staff	\N	\N	160	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
8a1eab45-738c-41b6-b35d-7737f5e2f64e	IMD staff	\N	\N	89	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
3260915b-2633-418b-997d-2beabd07ed2b	IMD staff	\N	\N	129	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
6d6f1209-693c-409d-9587-ed4e04d77930	IMD staff	\N	\N	111	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
18c4a035-c0ad-48f3-8628-30fee5e16970	IMD staff	\N	\N	95	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
c41a5544-af25-44ec-9fab-26fa3a4e08a5	IMD staff	\N	\N	62	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
07a988ec-6626-4d30-818e-4bc17de2c7ac	IMD staff	\N	\N	73	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
f8cb8b17-b65c-4df2-baab-62604c96a8c0	IMD staff	\N	\N	73	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	IMD staff	\N	\N	137	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
7fe9d01e-9282-4b4d-9377-b8b5d4c7f7d2	IMD staff	\N	\N	102	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
9897dc81-824b-4829-9fda-76c3f3c3e38f	IMD staff	\N	\N	101	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
a6f0ed93-9d6b-4592-a13e-5435550b4db2	IMD staff	\N	\N	165	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
4ead5d1f-209d-4c0f-950b-80d8668a696b	IMD staff	\N	\N	53	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
15a2f413-02d0-4624-9468-3a8bec2ba6b8	IMD staff	\N	\N	73	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
3ecf9082-92fa-49e4-a15f-87acb5504803	IMD staff	\N	\N	36	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
8be014b0-ed46-43db-89e2-91a301c618db	IMD staff	\N	\N	158	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
4c6d827e-f3db-47d8-be22-4dc4a611c63f	IMD staff	\N	\N	165	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
37609501-b2cd-4810-a1d5-b2a10f0405fd	IMD staff	\N	\N	92	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	IMD staff	\N	\N	87	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
b875f05c-64bb-41c8-b501-04ef26d03cb3	IMD staff	\N	\N	175	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
6bb2ccef-6c0b-4baa-bc82-d037a1c93af1	IMD staff	\N	\N	29	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
a6d5837e-0df4-4cf0-9c98-8f0da7e4a1f1	IMD staff	\N	\N	22	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
428cfba8-2dbb-45f6-844d-a309e2cdbd40	IMD staff	\N	\N	141	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
fc6668ea-582e-4fa2-a17f-eb264a39e1a2	IMD staff	\N	\N	166	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
6b116d7e-84ed-47de-81ea-2bd42ea50968	IMD staff	\N	\N	42	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	IMD staff	\N	\N	131	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
1e9340db-2cfd-419f-8894-9448da0bbc19	IMD staff	\N	\N	132	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
3a7984bc-e386-48e4-b988-7d8e086b5317	IMD staff	\N	\N	158	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
e44fe06d-6034-4f79-a75c-79ab0f2b58df	IMD staff	\N	\N	40	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
cd441b90-ef66-411c-b22e-4e046c29677f	IMD staff	\N	\N	172	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
d2298ed0-2515-4232-b70f-845a98dac595	IMD staff	\N	\N	18	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
feb2fb92-ce04-48c5-8a5f-9d2e832d1644	IMD staff	\N	\N	37	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
b4c20820-6710-46e1-b3cf-939b8bc00f93	IMD staff	\N	\N	78	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
032c01d5-4b5e-44f6-821d-2ba4342c938f	IMD staff	\N	\N	158	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
30e16278-0ca1-4efa-a03b-7168658bb2c2	IMD staff	\N	\N	5	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
8b09383e-447b-4fa0-b605-8d8cf4f3f527	IMD staff	\N	\N	138	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
33f73596-75e6-435e-94f5-d5b111a6aaf5	IMD staff	\N	\N	125	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
caf34c22-6898-4c15-bde0-08f3d2634d41	IMD staff	\N	\N	67	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
625944b1-2b9b-433b-9af5-e72894aa7a58	IMD staff	\N	\N	130	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
72a14ee8-79a9-41a0-8fb1-ac0dfac5bfa2	IMD staff	\N	\N	131	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
cc7120df-7364-4284-a971-893f524d1a25	IMD staff	\N	\N	25	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
b2734396-c5d2-4b05-99d0-986a180a98a6	IMD staff	\N	\N	52	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
ec4cdace-5f9a-4198-9518-7c59753a1127	IMD staff	\N	\N	12	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
3ed88e99-cb0d-423f-ae37-92b93c67d881	IMD staff	\N	\N	58	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
4acb1924-e6ec-428c-8401-ac05f87e2bbf	IMD staff	\N	\N	121	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
fda17094-1c9f-45de-a42c-aa815d09bc2a	IMD staff	\N	\N	150	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
b97db5e7-dca3-4f88-8318-6d457e09be91	IMD staff	\N	\N	142	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
2c310487-b2d2-4f8a-bdc3-0fcd75eff4a9	IMD staff	\N	\N	95	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
5d1e34b1-8861-4358-96e3-f5ed89f5c9d2	IMD staff	\N	\N	50	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
18407190-2219-4190-9b20-ee775b0094ef	IMD staff	\N	\N	142	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
fba30b27-7555-43f7-8c74-b84e722ebbc8	IMD staff	\N	\N	55	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
a5e41a1c-9682-4873-8924-f11edf9b3fce	IMD staff	\N	\N	134	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
df216767-1cda-46b6-874f-845e41051203	IMD staff	\N	\N	45	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
216136af-8b6b-44ae-a787-59506613a618	IMD staff	\N	\N	58	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
7ea450f4-3442-46d0-a08b-19c1e7308bde	IMD staff	\N	\N	78	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
3e1b170a-1554-4395-bc30-9bf8e6456a01	IMD staff	\N	\N	86	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
a74795a2-009c-433d-83b5-951f7b9bbfeb	IMD staff	\N	\N	43	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
9d94933f-74fd-4060-8400-53f4f570936b	IMD staff	\N	\N	152	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
c6eabfc7-6dc9-446d-82ba-5f5c1ccee7c3	IMD staff	\N	\N	5	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
5f4a001a-6a1c-4d94-ac62-a46048382386	IMD staff	\N	\N	131	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
7b70cf75-8a25-4a97-a3e3-d537f8fc85b3	IMD staff	\N	\N	154	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
31a87f04-ef6b-471d-af3c-c9aa342e7df7	IMD staff	\N	\N	77	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
91e4c5aa-2513-4817-a472-91da3e3813b1	IMD staff	\N	\N	112	\N	\N	t	\N	2026-09-26 18:31:45.462661+00
\.


--
-- Data for Name: qualifications; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.qualifications (id, user_id, degree, specialization, institution, year_completed, proof_file_id) FROM stdin;
f23e7834-d358-4351-9672-f9b347b96423	2e42c806-48d6-422a-b282-2b30f0484c3c	M.Tech	Nowcasting	Andhra University	1996	\N
fcd75d67-818f-4ef1-9495-49c1c3df8cc7	ff73e90e-1654-4bfd-8c73-43ad75a07f21	PhD	NWP Modelling	Cochin University (CUSAT)	1997	\N
d722d2c4-d971-4cce-bc78-f9a8469eca38	ff38df49-9e3b-4df5-92a2-4852f8b79c74	M.Sc	Tropical Cyclone Forecasting	IISc Bengaluru	1998	\N
bf2125be-0625-43c3-b6fa-f47c541e1985	2ae7d31a-ec05-402a-8104-ba433a1644eb	M.Tech	Monsoon Forecasting	Savitribai Phule Pune University	1999	\N
1afa6cb9-5763-47be-a4c8-179e69d60c1e	5db62bba-e3f6-4551-81f7-9d9237055aa3	PhD	Doppler Weather Radar	IIT Delhi	2000	\N
37eb9074-1971-49ec-ba70-93bea79274d4	9894043b-3b29-45e0-9abd-9b61597bf09a	M.Sc	Satellite Meteorology	Andhra University	2001	\N
953e6d0c-bfde-42d9-ab01-9f71f5ccac86	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	M.Tech	Automatic Weather Stations	Cochin University (CUSAT)	2002	\N
2af00174-d600-46a9-8d22-63aadb9fc06a	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	PhD	Climate Data Analysis	IISc Bengaluru	2003	\N
b85d3e0f-2661-42bf-98cc-38d12ba716cc	954754ab-6ecc-4d9a-a614-8cc84ffb3348	M.Sc	Agromet Advisory	Savitribai Phule Pune University	2004	\N
d07f5c32-1d35-4c25-8107-2962bc64aff3	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	M.Tech	Flood Meteorology	IIT Delhi	2005	\N
fb460b71-8c57-42aa-9990-8a4a1bf7deb0	e9178b69-2339-4a64-857f-5ad0630325a5	PhD	Heatwave & Cold Wave	Andhra University	2006	\N
448c343c-21ad-4727-af72-ba1983839391	82556fbd-47bf-44ac-aae9-3499c844ea75	M.Sc	Thunderstorm & Lightning	Cochin University (CUSAT)	2007	\N
108db794-311d-4543-b382-b5325d0dcf6f	fa5ba122-30c1-4e56-bc6b-b761794b1528	M.Tech	Python for Meteorology	IISc Bengaluru	2008	\N
fe677859-a3aa-4c22-8be9-d58168acd082	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	PhD	Nowcasting	Savitribai Phule Pune University	2009	\N
f72c63b7-07f1-45a3-9f68-e8f3fcafd27b	dab8c835-d264-43fb-9b10-7482bacf6b99	M.Sc	NWP Modelling	IIT Delhi	2010	\N
0f730ddf-3258-438c-8efa-29f8b01a0697	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	M.Tech	Tropical Cyclone Forecasting	Andhra University	2011	\N
f9c989a4-62e5-4a6f-8f72-40bb76cb0a5f	d6196926-78e5-4750-9dda-c802473b00e2	PhD	Monsoon Forecasting	Cochin University (CUSAT)	2012	\N
3c3fe492-e42a-4b89-8dfa-ba747f2d381d	66a88386-7c29-44ae-805a-fd51d782743b	M.Sc	Doppler Weather Radar	IISc Bengaluru	2013	\N
d08e7302-378c-4ab1-9767-7b9e1ea4699a	49992467-6281-4454-9a23-aa2dd4c74a95	M.Tech	Satellite Meteorology	Savitribai Phule Pune University	2014	\N
fc822d3c-fbf1-475f-9edf-58287cb15134	006ddbd1-35cc-4010-9363-d8234dae479e	PhD	Automatic Weather Stations	IIT Delhi	2015	\N
dc091141-6fc2-4804-9714-b74bcf5a6695	a2e26d13-6f79-43d6-9749-2676a39be455	M.Sc	Climate Data Analysis	Andhra University	2016	\N
f29b4ca4-fb9d-4e2c-a3fd-931166fa3686	e9f6bde5-9ab9-477d-8669-134bdc4ad9ed	M.Tech	Agromet Advisory	Cochin University (CUSAT)	2017	\N
8e0d2a70-f32f-4b85-ab04-47f5c83d45b0	9a3e7d30-cc90-4d84-8fad-fc7d979156c3	PhD	Flood Meteorology	IISc Bengaluru	2018	\N
baaf4e41-6160-4059-b10f-e925f4c4d20e	7108643a-28fb-4548-8b93-ed349eab59f3	M.Sc	Heatwave & Cold Wave	Savitribai Phule Pune University	2019	\N
6940940e-af18-4ae3-b5f4-e317d5049687	39496ad1-eecc-4826-8899-1dc4f0d96f73	M.Tech	Thunderstorm & Lightning	IIT Delhi	1995	\N
770c0a7e-081e-4ded-b013-7478a11af626	87214765-f9ce-468a-a0f1-98e208a690ec	PhD	Python for Meteorology	Andhra University	1996	\N
72686d9c-e4e2-4975-b36c-fd9482a4a31c	bb9ed2a7-08bf-40bf-9125-220f11e3b138	M.Sc	Nowcasting	Cochin University (CUSAT)	1997	\N
b0c1b5ca-ff48-4763-956f-74550c067eb3	2042a866-172d-42f9-96e4-7dc22771dc04	M.Tech	NWP Modelling	IISc Bengaluru	1998	\N
eb4ba9fb-ee73-4a0e-9c75-b09f89e552d1	7102ca49-b74d-4460-847e-ce4e91f8c048	PhD	Tropical Cyclone Forecasting	Savitribai Phule Pune University	1999	\N
0483dfb2-74c8-49e8-bfde-0977cf50df20	798470a9-6675-4483-8cd4-d1af4302c5af	M.Sc	Monsoon Forecasting	IIT Delhi	2000	\N
\.


--
-- Data for Name: question_options; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.question_options (id, question_id, text, is_correct, "position") FROM stdin;
4457872b-f134-44cc-a826-b8922503042e	d9a7ed8d-0efb-42f4-91a0-78bdc550ba52	Option A	f	1
0a66d06e-6b7e-46a2-ab2b-ac34584f5fb1	d9a7ed8d-0efb-42f4-91a0-78bdc550ba52	Option B	t	2
3f6b1ae2-e96b-4f89-973e-004aa91b5f91	d9a7ed8d-0efb-42f4-91a0-78bdc550ba52	Option C	f	3
7b59c401-54d8-4e0d-80bf-e1af9548f4bd	d9a7ed8d-0efb-42f4-91a0-78bdc550ba52	Option D	f	4
603086fe-9525-4da9-946e-5c87d123bcf1	da111a44-1bc7-4313-8d49-000d17b0e908	Option A	f	1
496fcea2-9ea6-4df8-9e91-0b3cb11982b8	da111a44-1bc7-4313-8d49-000d17b0e908	Option B	f	2
548484e5-4078-4f65-b068-a165be7d4b58	da111a44-1bc7-4313-8d49-000d17b0e908	Option C	t	3
89d44407-13e1-4c2f-8192-9853bfb3fa73	da111a44-1bc7-4313-8d49-000d17b0e908	Option D	f	4
d892fe49-3385-48a8-8c66-62041b1b0f84	c62fc8fd-203c-4951-8ca4-b4e9900c19f0	Option A	f	1
550012e0-b729-4a1c-8833-25cc0ee1ff00	c62fc8fd-203c-4951-8ca4-b4e9900c19f0	Option B	f	2
65cf0d22-4861-49a7-b615-1c11704dbaf9	c62fc8fd-203c-4951-8ca4-b4e9900c19f0	Option C	f	3
c2b57671-1c2a-4ac6-b52e-ca5d83284266	c62fc8fd-203c-4951-8ca4-b4e9900c19f0	Option D	t	4
cae5bf2b-250d-49f3-aea5-fe2cf98314ef	55e092b5-7f15-4069-adc6-dd5b03252c0d	Option A	t	1
9223e3ff-8133-464f-acf4-3dee9dd8fb6f	55e092b5-7f15-4069-adc6-dd5b03252c0d	Option B	f	2
3f0adaa0-792f-4668-9fcf-46fd2b7005a6	55e092b5-7f15-4069-adc6-dd5b03252c0d	Option C	f	3
43606fef-e9ea-4afb-9379-7a0deeecf733	55e092b5-7f15-4069-adc6-dd5b03252c0d	Option D	f	4
356056e7-913d-4c4b-8887-dbfe493fbe62	2311cfcc-9214-467a-94a1-844f62b2b8fc	Option A	f	1
2a7466ef-42fc-4011-9937-f647739e4c63	2311cfcc-9214-467a-94a1-844f62b2b8fc	Option B	t	2
d42cb88b-f33c-46aa-9d49-8af06bdff49a	2311cfcc-9214-467a-94a1-844f62b2b8fc	Option C	f	3
cf415688-4de8-448e-aed1-c497801f1ac8	2311cfcc-9214-467a-94a1-844f62b2b8fc	Option D	f	4
1c00b897-ba2e-42da-8ad2-5710cbf09f64	0567f1c1-bbf2-4e4a-b7db-6befd81352b9	Option A	f	1
9ca5eb73-94ed-42be-acec-c14e73e67662	0567f1c1-bbf2-4e4a-b7db-6befd81352b9	Option B	t	2
ce2328ab-b919-4c14-b5b0-7eb2c321437e	0567f1c1-bbf2-4e4a-b7db-6befd81352b9	Option C	f	3
81c45ebd-e1da-4813-8cbc-a57b8a0be5e0	0567f1c1-bbf2-4e4a-b7db-6befd81352b9	Option D	f	4
9fd165fe-5c1d-4aaf-9493-0c82d1c3e340	a0bfeaef-e235-4212-ac4d-7f7ab3ae5ba0	Option A	f	1
eff3e18d-9164-4aa1-b64f-7f150cd6ee28	a0bfeaef-e235-4212-ac4d-7f7ab3ae5ba0	Option B	f	2
4f5c17e6-6f12-4cb3-8f61-dc2f10396674	a0bfeaef-e235-4212-ac4d-7f7ab3ae5ba0	Option C	t	3
6b143022-c1a6-40c7-9276-188a0180038e	a0bfeaef-e235-4212-ac4d-7f7ab3ae5ba0	Option D	f	4
de7f9cac-4587-4b73-89f7-4c308b8502b3	0501294b-c3f9-4624-b504-cb88972b277f	Option A	f	1
7f8ac9c3-1e4d-44d5-a043-042aedd7de55	0501294b-c3f9-4624-b504-cb88972b277f	Option B	f	2
54920659-f62a-4536-bd79-0de727b23eb4	0501294b-c3f9-4624-b504-cb88972b277f	Option C	f	3
ffddce69-0bee-45dd-b2a1-884fd09b4c9e	0501294b-c3f9-4624-b504-cb88972b277f	Option D	t	4
2a975f54-74fb-4c3e-b492-f689f355b6f8	321be7de-e911-4765-8fdf-d4bfecf116ae	Option A	t	1
bf7e65a0-51a6-483b-80e6-0d7dec9b11b4	321be7de-e911-4765-8fdf-d4bfecf116ae	Option B	f	2
9fc5e98c-12a8-4662-9bc8-e2fd35934c2f	321be7de-e911-4765-8fdf-d4bfecf116ae	Option C	f	3
28a0f876-d439-443b-a201-5ea4fde34883	321be7de-e911-4765-8fdf-d4bfecf116ae	Option D	f	4
3a5f51a4-81dd-419a-9df2-352693e29eff	7e2d2b5c-62af-4f87-9adf-ddbe7c7be9e2	Option A	f	1
72fe681a-802e-41e1-bc53-40369108c667	7e2d2b5c-62af-4f87-9adf-ddbe7c7be9e2	Option B	t	2
31841511-5b98-4f11-b15a-45b25e81727c	7e2d2b5c-62af-4f87-9adf-ddbe7c7be9e2	Option C	f	3
e078ff48-6a43-4d8a-8b4b-6333479c3875	7e2d2b5c-62af-4f87-9adf-ddbe7c7be9e2	Option D	f	4
249fe8c6-907b-41d1-85b7-2a17b95efe40	e39fbfde-2a2e-481e-841c-29678be88938	Option A	f	1
99660fb9-bd04-4e58-81a1-ff07ac4b8f82	e39fbfde-2a2e-481e-841c-29678be88938	Option B	t	2
e76dc096-3e61-4ca8-9d83-3d74d5cd0300	e39fbfde-2a2e-481e-841c-29678be88938	Option C	f	3
ab2e26aa-7860-4d8d-b16b-bb537a22e6b2	e39fbfde-2a2e-481e-841c-29678be88938	Option D	f	4
404c2524-5284-4ccd-a665-742446f12d85	3c479adb-b6c9-4096-9ec1-fccbbf4d5a16	Option A	f	1
220a07f4-5e03-43fb-8946-b85282b6bed0	3c479adb-b6c9-4096-9ec1-fccbbf4d5a16	Option B	f	2
2e13fb14-f710-4cb8-969e-20e1e7e5c038	3c479adb-b6c9-4096-9ec1-fccbbf4d5a16	Option C	t	3
2c133f9c-2671-4ab8-be37-011006fbb033	3c479adb-b6c9-4096-9ec1-fccbbf4d5a16	Option D	f	4
0c565f97-28dd-488e-beab-0d59c320e265	6d8ec450-e25c-48bf-9709-9acd70197d1b	Option A	f	1
e640e263-f77e-47cd-badd-300d53c3ffdf	6d8ec450-e25c-48bf-9709-9acd70197d1b	Option B	f	2
12e3d6ed-9084-479a-bafd-9cffcb63e329	6d8ec450-e25c-48bf-9709-9acd70197d1b	Option C	f	3
e748edb1-40ad-42b5-8a2e-a9d4fe4426b1	6d8ec450-e25c-48bf-9709-9acd70197d1b	Option D	t	4
8779cccf-7c43-44f4-9e4b-6d18f5a80b27	c022f12d-04fd-41c9-a421-41863d673eeb	Option A	t	1
00142d2b-1d09-4141-b79b-b109251b8e06	c022f12d-04fd-41c9-a421-41863d673eeb	Option B	f	2
5fa4006d-ec21-40ea-8141-b90cc812627b	c022f12d-04fd-41c9-a421-41863d673eeb	Option C	f	3
3ce50acd-ff26-41f0-91dc-153e7d362b35	c022f12d-04fd-41c9-a421-41863d673eeb	Option D	f	4
7011bbaa-31ae-4898-83fc-948998886cff	0b2e1d11-24b7-4147-ad94-d4c0ad39a51f	Option A	f	1
4b3b985d-a7a6-4576-9eaf-1da3baed8889	0b2e1d11-24b7-4147-ad94-d4c0ad39a51f	Option B	t	2
3c6e50a3-06f4-4cc3-8a28-09c3e1ac144f	0b2e1d11-24b7-4147-ad94-d4c0ad39a51f	Option C	f	3
2d3b6dc3-b825-459e-a4d5-4426c375964a	0b2e1d11-24b7-4147-ad94-d4c0ad39a51f	Option D	f	4
71d5f230-24f3-4777-aff0-c421bef9d439	842d3611-ab31-4f65-9d2b-a0546b1db981	Option A	f	1
df140e0e-4fc5-4ea7-8b57-d719758dcb53	842d3611-ab31-4f65-9d2b-a0546b1db981	Option B	t	2
928517c5-3fe8-4b86-9647-3d4b10bed6eb	842d3611-ab31-4f65-9d2b-a0546b1db981	Option C	f	3
28e3f49f-475c-42ff-84d6-ab6fd0287b6b	842d3611-ab31-4f65-9d2b-a0546b1db981	Option D	f	4
bd9cd74d-90cb-4389-8a8a-5124cab64f40	3712c7d2-064b-41bf-afc4-209ba638ad38	Option A	f	1
011c3200-15d2-43d4-bdb9-57ff1b547b72	3712c7d2-064b-41bf-afc4-209ba638ad38	Option B	f	2
4911d7ce-4800-4b9a-a145-923af8b646dc	3712c7d2-064b-41bf-afc4-209ba638ad38	Option C	t	3
e653f3c4-d99a-4a7d-9bc7-bc7746dfca64	3712c7d2-064b-41bf-afc4-209ba638ad38	Option D	f	4
802666a0-d6f6-41e0-adda-76e90c99c9ab	dddf7001-2e03-4db3-80f2-ac3b8eb43044	Option A	f	1
5690fdd5-1323-4faf-acee-9aabbab690a7	dddf7001-2e03-4db3-80f2-ac3b8eb43044	Option B	f	2
1df89624-9c52-4745-8c7a-602cad5d588e	dddf7001-2e03-4db3-80f2-ac3b8eb43044	Option C	f	3
0ed3b47f-5b31-4ebf-bd55-bde8c7d23296	dddf7001-2e03-4db3-80f2-ac3b8eb43044	Option D	t	4
cd27aaff-ff3d-4fcf-a8b5-99681aad0c56	dda73b09-c7af-4bdf-b308-14c0518c3cbd	Option A	t	1
a0f2b783-d048-489e-a05b-f568593e72d4	dda73b09-c7af-4bdf-b308-14c0518c3cbd	Option B	f	2
14722890-2006-4682-9092-20d32d18b7c1	dda73b09-c7af-4bdf-b308-14c0518c3cbd	Option C	f	3
4b3e4d72-447c-4024-8a80-fb481082edfe	dda73b09-c7af-4bdf-b308-14c0518c3cbd	Option D	f	4
e4a760b2-8441-4aa4-a93b-2fd98f72c8ef	ae36ca61-ad6e-44c4-b3a0-ea0644f6cd56	Option A	f	1
265390d9-2a13-49f5-a38c-984c8429fc14	ae36ca61-ad6e-44c4-b3a0-ea0644f6cd56	Option B	t	2
71f0f1e0-e106-4cc4-a030-bd64354f9890	ae36ca61-ad6e-44c4-b3a0-ea0644f6cd56	Option C	f	3
d22db006-4611-4767-b69b-e1c02b3dba29	ae36ca61-ad6e-44c4-b3a0-ea0644f6cd56	Option D	f	4
9016cc11-9f41-4a08-a359-109b28aaf469	276f4198-3410-4b9a-9bef-8d972380df31	Option A	f	1
89a63e8e-0b41-426e-aa92-ba5d49ebc1ba	276f4198-3410-4b9a-9bef-8d972380df31	Option B	t	2
22d9af06-02d4-4de4-9cf9-d0e2beaebdda	276f4198-3410-4b9a-9bef-8d972380df31	Option C	f	3
e03b4ef0-e6f9-4cec-8a99-91e7df80871a	276f4198-3410-4b9a-9bef-8d972380df31	Option D	f	4
af28340f-515e-4db5-9a6c-65be1c54a755	ada55e48-e425-4bb0-b5ce-62df4efe7a59	Option A	f	1
c65d18a1-f823-45f7-84dc-f17044b55421	ada55e48-e425-4bb0-b5ce-62df4efe7a59	Option B	f	2
8f3d1410-bc5c-419c-9cdf-65e64f13ab1f	ada55e48-e425-4bb0-b5ce-62df4efe7a59	Option C	t	3
4dbd843d-ac6f-442b-a068-f3c47ea695d8	ada55e48-e425-4bb0-b5ce-62df4efe7a59	Option D	f	4
9115db3a-41af-4017-ac1b-c84fcb7fa57d	1618e633-7082-4fb8-b5ee-c0cab2a891da	Option A	f	1
bb4030cf-f76a-41ea-ab18-97beb3d8ce8e	1618e633-7082-4fb8-b5ee-c0cab2a891da	Option B	f	2
3248fc3e-1351-43b4-a185-cdf8e9a4cbdf	1618e633-7082-4fb8-b5ee-c0cab2a891da	Option C	f	3
88303d3b-c887-4413-8d29-49cb0b7f446c	1618e633-7082-4fb8-b5ee-c0cab2a891da	Option D	t	4
5f7f75f2-ac09-42e4-9aee-d845b55490b4	fdd5557e-35cd-4786-8af2-5dbe641d4078	Option A	t	1
a8130d75-5c91-46aa-9583-f5025520d0eb	fdd5557e-35cd-4786-8af2-5dbe641d4078	Option B	f	2
c1f7364c-61b7-45b8-a1b5-909b73ee0e77	fdd5557e-35cd-4786-8af2-5dbe641d4078	Option C	f	3
666305c3-72ef-43df-965e-7013486e57c4	fdd5557e-35cd-4786-8af2-5dbe641d4078	Option D	f	4
d9675e53-9b82-4923-8f12-2812dc0406c6	cf3b477d-5c66-4ff9-9869-4d6414876655	Option A	f	1
8564c2eb-a16a-4d44-910a-799c23ea1f22	cf3b477d-5c66-4ff9-9869-4d6414876655	Option B	t	2
cc491681-7693-43f0-9dbe-4fcb5af4b3dd	cf3b477d-5c66-4ff9-9869-4d6414876655	Option C	f	3
52c789e3-c4bc-4efe-a5f5-3362ff9c0236	cf3b477d-5c66-4ff9-9869-4d6414876655	Option D	f	4
cba1759b-a086-4809-8831-b876fa649e39	a6f81972-5233-4fb7-8336-bdfab28de722	Option A	f	1
3feeaeb1-920d-4cf0-b625-2417416900c3	a6f81972-5233-4fb7-8336-bdfab28de722	Option B	t	2
44b1dd44-445e-4e2b-bcf1-56b84ccd6617	a6f81972-5233-4fb7-8336-bdfab28de722	Option C	f	3
c148137d-3b93-4406-b20e-427881ea7992	a6f81972-5233-4fb7-8336-bdfab28de722	Option D	f	4
6748ce93-49e9-4e5f-b0ce-295e7b8971fc	df87edf7-91a0-416a-a138-c6974ad4b26c	Option A	f	1
d495a28c-8cac-4de2-b759-3ec9682315ad	df87edf7-91a0-416a-a138-c6974ad4b26c	Option B	f	2
f8ed28f2-99d4-44f9-9ab0-cedb0c3477ae	df87edf7-91a0-416a-a138-c6974ad4b26c	Option C	t	3
22e4106a-fb63-46d8-a186-bbf582166214	df87edf7-91a0-416a-a138-c6974ad4b26c	Option D	f	4
49aca9ef-0cbf-4dd6-a353-d787d2ca7e29	481e800e-c390-452e-941b-8ba404541de2	Option A	f	1
b659b23f-57e8-4504-9e02-b9f6a82aa62a	481e800e-c390-452e-941b-8ba404541de2	Option B	f	2
72fd5ac6-1f15-402a-8702-5950cda174f1	481e800e-c390-452e-941b-8ba404541de2	Option C	f	3
b8a266ba-5de0-4071-98cb-c8ec17a98f87	481e800e-c390-452e-941b-8ba404541de2	Option D	t	4
198a3c74-5b87-40cd-b030-e5ea67950537	54092566-73c2-412f-b707-977e9d51421f	Option A	t	1
d2e62568-d77e-4ad3-ac97-7d78d503e638	54092566-73c2-412f-b707-977e9d51421f	Option B	f	2
415feba9-5804-45c8-990b-cf0078c58bde	54092566-73c2-412f-b707-977e9d51421f	Option C	f	3
041ffe45-5f41-4741-836b-ab3e6d5de022	54092566-73c2-412f-b707-977e9d51421f	Option D	f	4
5956e022-1a3e-482f-bc1d-6e2d429cf77f	723f7e35-d502-4ce2-9bc5-c48a9f981dcb	Option A	f	1
fc9229b1-9787-44b3-9e97-381b2260cfa9	723f7e35-d502-4ce2-9bc5-c48a9f981dcb	Option B	t	2
f2f3fe86-b913-438d-b5dd-c7d0ce418784	723f7e35-d502-4ce2-9bc5-c48a9f981dcb	Option C	f	3
b862a37b-f5c8-4a61-ac71-513abc21d38d	723f7e35-d502-4ce2-9bc5-c48a9f981dcb	Option D	f	4
f87d58c1-9c9e-4fb7-bfc4-5b094da2fded	a0939e3f-23c9-4c7d-a493-3b18f8e31f08	Option A	f	1
ec76aac8-66cf-440f-8f8e-835e6ea70c49	a0939e3f-23c9-4c7d-a493-3b18f8e31f08	Option B	t	2
f958490f-a5bf-457c-a241-b6fb515d6fcd	a0939e3f-23c9-4c7d-a493-3b18f8e31f08	Option C	f	3
509be6ed-a81c-4f55-99ff-e25a71d7ac12	a0939e3f-23c9-4c7d-a493-3b18f8e31f08	Option D	f	4
44188349-7e18-4b8d-bc1c-a735ac0bf68a	9e166d0d-b6d3-4a62-8dbf-e636f0f83f8f	Option A	f	1
2d9f0cc9-cc16-4d78-9cbc-39014d57a1bd	9e166d0d-b6d3-4a62-8dbf-e636f0f83f8f	Option B	f	2
24fd555f-3b9f-4eec-a354-42f8ddcf1f16	9e166d0d-b6d3-4a62-8dbf-e636f0f83f8f	Option C	t	3
d79bcd9b-940b-472d-bc7c-e74bbdaf307d	9e166d0d-b6d3-4a62-8dbf-e636f0f83f8f	Option D	f	4
2e2f9690-1865-4f63-9066-475e00b3d62b	de5ec0f7-b0ad-48c7-9868-50d672f7f0c3	Option A	f	1
b38133f0-ab62-439e-8d09-ba56c91d6272	de5ec0f7-b0ad-48c7-9868-50d672f7f0c3	Option B	f	2
e2a4004d-e074-47d1-aaaf-d133db8ee6f0	de5ec0f7-b0ad-48c7-9868-50d672f7f0c3	Option C	f	3
6c1c9190-795a-43a5-afd5-ee75383f2271	de5ec0f7-b0ad-48c7-9868-50d672f7f0c3	Option D	t	4
d5d348e0-3674-41db-9fe2-d051b6d83758	f20a235d-8e11-443b-98db-a9b42f2af4cc	Option A	t	1
d2a192d8-8af7-40b4-9ba6-f125645cd447	f20a235d-8e11-443b-98db-a9b42f2af4cc	Option B	f	2
a12c0e2d-c225-4f2f-9c7a-a7099698f23f	f20a235d-8e11-443b-98db-a9b42f2af4cc	Option C	f	3
493798d6-8324-4472-84eb-14e21d6d1ca6	f20a235d-8e11-443b-98db-a9b42f2af4cc	Option D	f	4
0155c626-eee3-44e1-8851-b0c3259eab25	6e03d4c9-da55-4d28-a229-6b27cd0af353	Option A	f	1
3aaa4fcd-72e8-40d6-98e4-7f865ef8efa7	6e03d4c9-da55-4d28-a229-6b27cd0af353	Option B	t	2
eb6b99ee-78d3-400e-bf2d-44eda7934c9b	6e03d4c9-da55-4d28-a229-6b27cd0af353	Option C	f	3
aef28779-7a1f-4b66-8e28-0affe7458f68	6e03d4c9-da55-4d28-a229-6b27cd0af353	Option D	f	4
39e1a83e-ff13-4e06-8db8-7da97e2cf42a	e758450e-85ed-4e7e-a180-f3ad775095ca	Option A	f	1
c77e464b-3bb6-4c50-9122-9cea9d8b9ba1	e758450e-85ed-4e7e-a180-f3ad775095ca	Option B	t	2
1885a1b8-e2ac-4288-89bb-801307a61cbc	e758450e-85ed-4e7e-a180-f3ad775095ca	Option C	f	3
518029cf-6928-4030-b853-adc94adafabb	e758450e-85ed-4e7e-a180-f3ad775095ca	Option D	f	4
dc5b5791-ab88-4d3d-9502-339acd645ef6	22ef0e6f-422f-41a9-9672-fedf62dce991	Option A	f	1
3a9e0d5d-2655-4344-b44c-f7a5adbca69a	22ef0e6f-422f-41a9-9672-fedf62dce991	Option B	f	2
c4e256c7-b5c1-489e-a2ac-955a751db501	22ef0e6f-422f-41a9-9672-fedf62dce991	Option C	t	3
afea0534-0c2d-449f-b6a3-cf20551fcc0f	22ef0e6f-422f-41a9-9672-fedf62dce991	Option D	f	4
ade4253e-c5cf-4e98-8808-9e18763e128f	85c159e3-fd28-4167-9d60-9d43b3c12fcc	Option A	f	1
0c5ebf13-f1ae-4342-b178-a6c274f80f5c	85c159e3-fd28-4167-9d60-9d43b3c12fcc	Option B	f	2
53007fe5-5092-4dea-b14b-490cc51e942f	85c159e3-fd28-4167-9d60-9d43b3c12fcc	Option C	f	3
69d95b6d-4a88-4ead-b228-4c7947f80079	85c159e3-fd28-4167-9d60-9d43b3c12fcc	Option D	t	4
65634fe8-1d52-4cf7-84e5-fc71f67e8f30	482e3171-7c3f-4c58-ad47-a9c05311ec37	Option A	t	1
ba24749a-b4fb-4d6c-9908-c3a238f8f2bf	482e3171-7c3f-4c58-ad47-a9c05311ec37	Option B	f	2
621ca31e-bbca-46ca-b9a2-28e6137e515f	482e3171-7c3f-4c58-ad47-a9c05311ec37	Option C	f	3
fabbedcf-2435-4873-831f-e142c90ed342	482e3171-7c3f-4c58-ad47-a9c05311ec37	Option D	f	4
268bf7ae-5436-4001-9459-3500ebd90d1f	ea861331-71bf-493e-8789-467ba7167e55	Option A	f	1
78894a97-cc32-43aa-a12c-e2d6cd32ccfb	ea861331-71bf-493e-8789-467ba7167e55	Option B	t	2
7c8d928e-ea58-4d3e-92a5-3be6c6f2e089	ea861331-71bf-493e-8789-467ba7167e55	Option C	f	3
0ee2ed2c-42be-4150-8ba4-fe0701e2a57c	ea861331-71bf-493e-8789-467ba7167e55	Option D	f	4
c639da90-27ca-4c67-a1d7-1d092f7e3f87	4ba0a281-f461-47f5-b680-d2250d31b6f5	Option A	f	1
c1b95c23-439d-4a8e-88e5-a0f58a9c187b	4ba0a281-f461-47f5-b680-d2250d31b6f5	Option B	t	2
8ae6c307-5aa5-4a46-8d4d-b349318c7ba7	4ba0a281-f461-47f5-b680-d2250d31b6f5	Option C	f	3
859cdd8b-9737-42f1-9492-ad57062ae642	4ba0a281-f461-47f5-b680-d2250d31b6f5	Option D	f	4
9513cb2f-648c-4eaf-81c7-f4af80500ee5	c45b1fb6-e1ec-4f8a-b452-853d64a619c1	Option A	f	1
28e4b914-4a03-43a8-a31a-759b8faf0ab8	c45b1fb6-e1ec-4f8a-b452-853d64a619c1	Option B	f	2
6f4c194c-d8af-4bef-8ffb-f012e39e4768	c45b1fb6-e1ec-4f8a-b452-853d64a619c1	Option C	t	3
4c017f25-9774-413a-a0f7-80aa57f3415f	c45b1fb6-e1ec-4f8a-b452-853d64a619c1	Option D	f	4
8d8be5bf-0b9a-414f-8727-822deec51ed6	e4df6ba2-d87e-43d4-b6ca-938e8c96b418	Option A	f	1
61afb557-eb4f-4962-8073-3a4e744f6e7c	e4df6ba2-d87e-43d4-b6ca-938e8c96b418	Option B	f	2
fe684ebc-9782-4642-a1aa-b7fa3ff36e85	e4df6ba2-d87e-43d4-b6ca-938e8c96b418	Option C	f	3
bf96ed3c-61df-49b6-b5e5-db3a1fa83e43	e4df6ba2-d87e-43d4-b6ca-938e8c96b418	Option D	t	4
f2136618-00d2-4fb3-a5f4-50976e25857f	5d249fde-4b7a-4e1d-bba3-a32fcc09b680	Option A	t	1
282a79f7-134b-40f6-866a-d63af39168dd	5d249fde-4b7a-4e1d-bba3-a32fcc09b680	Option B	f	2
a11cb261-4311-4fd4-9d3b-f82809ce4f2b	5d249fde-4b7a-4e1d-bba3-a32fcc09b680	Option C	f	3
afb4861a-1c3f-4b68-bf3d-090eff79ae41	5d249fde-4b7a-4e1d-bba3-a32fcc09b680	Option D	f	4
1d0478d7-6f95-4406-8d23-7fa1b47b500e	deca4865-7301-4479-924d-4b0566bac65d	Option A	f	1
ef282a70-4f41-4e48-8f38-796f53b6defa	deca4865-7301-4479-924d-4b0566bac65d	Option B	t	2
a534ae50-864c-49fd-a001-eb822f2f123d	deca4865-7301-4479-924d-4b0566bac65d	Option C	f	3
096e0ffd-d224-49d7-aca7-f347351fc3b1	deca4865-7301-4479-924d-4b0566bac65d	Option D	f	4
4ee34aae-17e6-443c-965a-208d3950d934	5bd7e0eb-5835-479b-a5bd-f00f13b4e540	Option A	f	1
2e8a9124-596f-491b-b3dd-2c30bbeba2dd	5bd7e0eb-5835-479b-a5bd-f00f13b4e540	Option B	t	2
f16363eb-b54c-43b2-84dd-921f6750a6db	5bd7e0eb-5835-479b-a5bd-f00f13b4e540	Option C	f	3
45132322-cf4d-4059-8a5e-00ad862c7d09	5bd7e0eb-5835-479b-a5bd-f00f13b4e540	Option D	f	4
385e8b9c-e99b-4471-94b5-00b6ada57fe7	a0644737-8a5e-437c-a193-f4813cbdfa7c	Option A	f	1
40265d1a-c042-4998-b320-36e853ee0f76	a0644737-8a5e-437c-a193-f4813cbdfa7c	Option B	f	2
0d0b3a49-9e16-44f6-8a22-4d4666f26434	a0644737-8a5e-437c-a193-f4813cbdfa7c	Option C	t	3
e267ad65-4349-4196-aa23-80e0f135b1cf	a0644737-8a5e-437c-a193-f4813cbdfa7c	Option D	f	4
ae4bcb6a-b6b4-4423-a7d1-a4331c20df3a	528049ed-aa3f-45d0-acc2-34c04a8ec5fe	Option A	f	1
6fd8d732-22eb-461f-9c1f-481c997ef297	528049ed-aa3f-45d0-acc2-34c04a8ec5fe	Option B	f	2
21fd0060-33d2-4695-a54b-6523d3fd9ad6	528049ed-aa3f-45d0-acc2-34c04a8ec5fe	Option C	f	3
e5d691ea-c247-44ce-bb75-a84475eb946c	528049ed-aa3f-45d0-acc2-34c04a8ec5fe	Option D	t	4
6c100f5b-68cf-4c4c-8f2f-d87eb722d3af	622a682e-3d90-4e5c-be31-62fa0b87660e	Option A	t	1
a1a96e15-f7d5-4057-9aac-d7182a1cf696	622a682e-3d90-4e5c-be31-62fa0b87660e	Option B	f	2
e526adbd-e098-48ea-a3db-c01334272cc0	622a682e-3d90-4e5c-be31-62fa0b87660e	Option C	f	3
623571ca-6b9a-417b-b176-04ed18b85005	622a682e-3d90-4e5c-be31-62fa0b87660e	Option D	f	4
1943d418-c3cf-4ac7-b61c-ee5bc2f8c815	bf89a8a0-39da-4bb5-ad65-693441dee031	Option A	f	1
e298634f-67cf-4b02-874e-b6c4990b7c28	bf89a8a0-39da-4bb5-ad65-693441dee031	Option B	t	2
f5f149b5-111e-44dd-bbf9-fe91eed7022f	bf89a8a0-39da-4bb5-ad65-693441dee031	Option C	f	3
665bf842-590b-42cf-827d-57277cadd4c9	bf89a8a0-39da-4bb5-ad65-693441dee031	Option D	f	4
c29af7a5-3b0f-441d-a73b-6dcf5929e596	95e84b8c-febc-4a42-ac60-551d14417313	Option A	f	1
405c4582-429c-4efb-866a-f0355fdf06f5	95e84b8c-febc-4a42-ac60-551d14417313	Option B	t	2
80ac2f99-cb9e-4fd2-9068-5f79c9c8c1a8	95e84b8c-febc-4a42-ac60-551d14417313	Option C	f	3
46be8592-1a44-4c40-b930-59637f11596b	95e84b8c-febc-4a42-ac60-551d14417313	Option D	f	4
94fe0f58-2bce-4bd5-9a15-9f8960845c25	faf9fcc8-6bbf-4618-90dc-6d7a40d6eca6	Option A	f	1
0748cc82-2893-4cc9-9705-44863f0f0f39	faf9fcc8-6bbf-4618-90dc-6d7a40d6eca6	Option B	f	2
f63973cc-9add-46a4-9114-d607e0a1236b	faf9fcc8-6bbf-4618-90dc-6d7a40d6eca6	Option C	t	3
667f0f88-2a33-40a8-b558-0d5fa04f8c0f	faf9fcc8-6bbf-4618-90dc-6d7a40d6eca6	Option D	f	4
e2812558-63e6-4212-a027-826ef3412284	7e8ae0c4-bc98-4629-9779-87785bec5474	Option A	f	1
ab9ea10b-e826-4738-9037-8f015486270a	7e8ae0c4-bc98-4629-9779-87785bec5474	Option B	f	2
b7d0049c-8e46-429f-beae-daba604ef588	7e8ae0c4-bc98-4629-9779-87785bec5474	Option C	f	3
3b9194b9-8d55-4157-b9a7-1c37dc6f6339	7e8ae0c4-bc98-4629-9779-87785bec5474	Option D	t	4
a75ce49f-dac7-4559-8efa-ccca9e45d206	80a3a503-4ae5-4da0-ab98-f5fd59dc0be8	Option A	t	1
d0f81220-7e25-4a60-9c1d-2342befd118f	80a3a503-4ae5-4da0-ab98-f5fd59dc0be8	Option B	f	2
46c64138-5d2a-4696-8a92-a56024b95f93	80a3a503-4ae5-4da0-ab98-f5fd59dc0be8	Option C	f	3
acefffec-fdd8-474b-a277-dad232a5ba87	80a3a503-4ae5-4da0-ab98-f5fd59dc0be8	Option D	f	4
5aeda4cd-ee58-4ffa-89fc-3dc97174a323	7237393e-d5f4-4e2e-9dce-f7deb59204e4	Option A	f	1
47a39c5c-adc4-4cd8-99a3-cc3e5a79d915	7237393e-d5f4-4e2e-9dce-f7deb59204e4	Option B	t	2
44fae39f-af62-41cb-83cf-3f18f08bedef	7237393e-d5f4-4e2e-9dce-f7deb59204e4	Option C	f	3
bc9f205e-1643-4a87-aaa6-6c3e94b1dae0	7237393e-d5f4-4e2e-9dce-f7deb59204e4	Option D	f	4
9b425c65-83dd-4d04-99cf-2d7e749fc4c6	437b8adc-8675-4043-aba0-f6b6a92f46b0	Option A	f	1
8777cee1-d7b5-44ec-b21f-6f84d5118563	437b8adc-8675-4043-aba0-f6b6a92f46b0	Option B	t	2
85caafd9-b30b-4385-bc5e-2ef3c2cde275	437b8adc-8675-4043-aba0-f6b6a92f46b0	Option C	f	3
59607848-471d-409c-87a8-63a159ef9c62	437b8adc-8675-4043-aba0-f6b6a92f46b0	Option D	f	4
ddf0bd3e-43b2-4f8e-acf9-99da75d4108d	23021390-93b2-40c7-92f9-cfc73690b17a	Option A	f	1
6c28aac2-ef71-4389-98a6-74578c489f61	23021390-93b2-40c7-92f9-cfc73690b17a	Option B	f	2
2036dbc6-aeae-4fae-b602-efa037ef2496	23021390-93b2-40c7-92f9-cfc73690b17a	Option C	t	3
41216031-27e4-47ca-b9c3-01803145eaa0	23021390-93b2-40c7-92f9-cfc73690b17a	Option D	f	4
3b0e946f-c30c-4f91-84c6-fb0a1113b5fb	7ec974f7-8ffd-4e10-90ce-fc783afd3155	Option A	f	1
3a0797c0-a519-4229-98c6-d1301312106a	7ec974f7-8ffd-4e10-90ce-fc783afd3155	Option B	f	2
513d63f0-e3bd-43e2-80b2-6952a237aa91	7ec974f7-8ffd-4e10-90ce-fc783afd3155	Option C	f	3
26cc1fd2-c52e-4f4a-838c-a158e17884b3	7ec974f7-8ffd-4e10-90ce-fc783afd3155	Option D	t	4
3cef2355-7e9a-4e71-a9bf-bbe112f85d8f	5ea04a37-889b-4520-8648-7884e8d54922	Option A	t	1
11d2786f-31db-4453-be5d-8e11ce32dfa5	5ea04a37-889b-4520-8648-7884e8d54922	Option B	f	2
4c037ab2-9ace-4e3b-8609-f78a836fc028	5ea04a37-889b-4520-8648-7884e8d54922	Option C	f	3
c3af2b3c-dded-4ec2-842e-1e7d239396b1	5ea04a37-889b-4520-8648-7884e8d54922	Option D	f	4
df448b69-eab2-40ca-a515-c1f8bd338a84	fdc4311c-c458-40ef-9238-cb9683368482	Option A	f	1
8f88b354-330a-44d2-8a71-e47749df532c	fdc4311c-c458-40ef-9238-cb9683368482	Option B	t	2
3c3c764b-4ab8-4b52-a838-448336cf2b66	fdc4311c-c458-40ef-9238-cb9683368482	Option C	f	3
b8aeb4e4-2a3d-4c07-86a0-94aac10b855e	fdc4311c-c458-40ef-9238-cb9683368482	Option D	f	4
f7e15695-ec3c-4ce9-9364-1caaa598189c	6e98727a-edba-4619-a163-b394595b23c7	Option A	f	1
daa8e7c9-9990-46d6-af6f-3144f5b299eb	6e98727a-edba-4619-a163-b394595b23c7	Option B	t	2
8290cdb1-6bbc-40e9-87c9-f96126e9d32f	6e98727a-edba-4619-a163-b394595b23c7	Option C	f	3
1ad87c66-abf8-4a4e-9770-16aba8e44b4a	6e98727a-edba-4619-a163-b394595b23c7	Option D	f	4
fe800b9b-1b32-43f4-8bcd-c5d610979cf3	aaf61416-b013-490b-bdd9-d4f0aaa3bc96	Option A	f	1
f395bf37-fac3-4ae6-8cde-e9e2c6d76ace	aaf61416-b013-490b-bdd9-d4f0aaa3bc96	Option B	f	2
74fd3ee9-58d0-40ca-ad86-83833947f14a	aaf61416-b013-490b-bdd9-d4f0aaa3bc96	Option C	t	3
83512d11-28c2-4577-a315-332764ee1190	aaf61416-b013-490b-bdd9-d4f0aaa3bc96	Option D	f	4
99496fad-71a8-4627-9bb8-5afbf87fc6aa	4be8599a-6dc6-45af-9fec-4535ad2b93bf	Option A	f	1
cfa5124d-b835-4c9c-8f4c-968e142f57fa	4be8599a-6dc6-45af-9fec-4535ad2b93bf	Option B	f	2
b8fee33a-1103-4685-9313-e6a35143d962	4be8599a-6dc6-45af-9fec-4535ad2b93bf	Option C	f	3
3e7fdfa4-1bc7-4e4a-a88c-69d8d1a80c3a	4be8599a-6dc6-45af-9fec-4535ad2b93bf	Option D	t	4
b4dc6fa0-f985-48b1-873b-7904193c8229	bf1b246a-4c6f-4cc4-9e54-aed352f1a9bd	Option A	t	1
9e08e2fe-02bb-4eaa-9b3a-b293b03e441a	bf1b246a-4c6f-4cc4-9e54-aed352f1a9bd	Option B	f	2
74e44d97-12a6-4bdb-a159-1532cca086cf	bf1b246a-4c6f-4cc4-9e54-aed352f1a9bd	Option C	f	3
3b3e8f34-bd31-4713-8a39-8322d567262e	bf1b246a-4c6f-4cc4-9e54-aed352f1a9bd	Option D	f	4
770a5ae5-7da1-4677-a55e-a45e9534f65c	cc3a69f6-6b27-40d3-9a58-b3ea913119f2	Option A	f	1
a00e33d2-0e53-4e10-a980-16a43af94d41	cc3a69f6-6b27-40d3-9a58-b3ea913119f2	Option B	t	2
5dcd6246-e813-451b-9f7e-57af4b8487ed	cc3a69f6-6b27-40d3-9a58-b3ea913119f2	Option C	f	3
fb82d3c6-cede-4760-8c14-4973cddce162	cc3a69f6-6b27-40d3-9a58-b3ea913119f2	Option D	f	4
bb37a284-9b5c-4df2-bf42-ee1e43e4739f	a0b03234-1d94-4e18-8ee6-d195a36dffe7	Option A	f	1
bc8ebc76-16bf-419a-9613-a1a156246cc2	a0b03234-1d94-4e18-8ee6-d195a36dffe7	Option B	t	2
79c7af8d-fb84-4c12-84eb-c81a21d9292e	a0b03234-1d94-4e18-8ee6-d195a36dffe7	Option C	f	3
69f5ff72-81e8-4ecc-896f-7bfd10008519	a0b03234-1d94-4e18-8ee6-d195a36dffe7	Option D	f	4
faf08c1d-1571-406e-b2ea-4c77812be760	202fdea7-c937-4073-99f1-f83430861d91	Option A	f	1
0033755e-58c8-4bf5-8258-bf57590d5f72	202fdea7-c937-4073-99f1-f83430861d91	Option B	f	2
a855b87e-c73b-4c08-ab5d-b3cd5efcddab	202fdea7-c937-4073-99f1-f83430861d91	Option C	t	3
82df4e16-6a13-430a-8bd7-d53d4cb91b51	202fdea7-c937-4073-99f1-f83430861d91	Option D	f	4
5d0d4b57-c800-4605-9125-64a5f37c4455	a04a3b3c-ac59-47b2-8225-e17e1f112f91	Option A	f	1
e1f74d98-7253-4911-ad75-235181ab94f6	a04a3b3c-ac59-47b2-8225-e17e1f112f91	Option B	f	2
28e89e15-7280-4374-b8be-284af79836b1	a04a3b3c-ac59-47b2-8225-e17e1f112f91	Option C	f	3
3a86a996-ba2f-4fc2-befb-2b9064241535	a04a3b3c-ac59-47b2-8225-e17e1f112f91	Option D	t	4
0ff4d383-0928-438a-a4f9-a9482bb718a9	bca4bd80-7324-4585-91e4-9bcd75e20b34	Option A	t	1
998de53d-fd02-42b5-be90-e1ec25cebe51	bca4bd80-7324-4585-91e4-9bcd75e20b34	Option B	f	2
ee460d85-1591-44da-b445-47bb16904080	bca4bd80-7324-4585-91e4-9bcd75e20b34	Option C	f	3
c96108e6-3400-4bf1-bb88-0f6f094de6ee	bca4bd80-7324-4585-91e4-9bcd75e20b34	Option D	f	4
a349041b-fc55-4368-91b9-01ee419ac173	9051ccf3-c419-44d2-ad06-aa49c3f5d545	Option A	f	1
4724c742-2685-4aa5-8d55-917eaaa8c7db	9051ccf3-c419-44d2-ad06-aa49c3f5d545	Option B	t	2
7e1e6424-4b61-42ee-862e-c7376fada664	9051ccf3-c419-44d2-ad06-aa49c3f5d545	Option C	f	3
0b6a448a-da1f-4e08-a109-4ab903d2595d	9051ccf3-c419-44d2-ad06-aa49c3f5d545	Option D	f	4
c4eaacff-32f3-4fa1-807a-79eedfbd338d	c51a7ea7-8aea-47b7-9211-adc3ebd80fd2	Option A	f	1
e5a5c223-50dc-4764-a5ea-8365feeeef07	c51a7ea7-8aea-47b7-9211-adc3ebd80fd2	Option B	t	2
6fc62c75-b1df-49b9-ac7a-6754c15d1a90	c51a7ea7-8aea-47b7-9211-adc3ebd80fd2	Option C	f	3
abe54445-f3c1-4fc9-99b3-dd5032ff36ec	c51a7ea7-8aea-47b7-9211-adc3ebd80fd2	Option D	f	4
f0adc51e-ade3-416e-953c-017ddea29b3c	dd08aad7-a607-414a-ae3c-ec3e910277d1	Option A	f	1
e3b354ac-536a-42bb-ac9b-6a1a128058a4	dd08aad7-a607-414a-ae3c-ec3e910277d1	Option B	f	2
80a9bdac-cac4-4b8d-bf10-903acf27a42d	dd08aad7-a607-414a-ae3c-ec3e910277d1	Option C	t	3
204e7446-3f77-4829-a945-2ed04f82e68b	dd08aad7-a607-414a-ae3c-ec3e910277d1	Option D	f	4
8e277e6f-db71-4a9f-98b9-15155aeac1b2	fd46de5f-099b-4dcb-a464-b299a4ecedfb	Option A	f	1
701cbba6-70ad-4013-aeb3-f3c74ff89624	fd46de5f-099b-4dcb-a464-b299a4ecedfb	Option B	f	2
d7ba22a5-c246-4431-a85b-dc64e0d8d533	fd46de5f-099b-4dcb-a464-b299a4ecedfb	Option C	f	3
f6aa6f01-bf61-45a6-94dc-aedc61efb443	fd46de5f-099b-4dcb-a464-b299a4ecedfb	Option D	t	4
23e84f0c-e254-48f4-b716-730644a959e9	78be014b-69a1-413a-be48-571e435770bd	Option A	t	1
b53d0d96-5d79-4571-8438-a9ec9f6c857a	78be014b-69a1-413a-be48-571e435770bd	Option B	f	2
b6d734e7-431a-4580-81be-861073b2c0f9	78be014b-69a1-413a-be48-571e435770bd	Option C	f	3
372f978a-bdf4-4582-bb34-b4724d36fe26	78be014b-69a1-413a-be48-571e435770bd	Option D	f	4
920c28b7-5dda-4a36-afa3-c9ccf5a6fdb4	c897b8cd-5b9e-48bc-b8c6-a4eb51770b48	Option A	f	1
38618001-61b9-4655-86f6-e556e9d9b4e4	c897b8cd-5b9e-48bc-b8c6-a4eb51770b48	Option B	t	2
4170e4f1-2fef-4cb0-a190-1d03c46b83a0	c897b8cd-5b9e-48bc-b8c6-a4eb51770b48	Option C	f	3
999b3954-aed2-4268-a824-002875c7f7c9	c897b8cd-5b9e-48bc-b8c6-a4eb51770b48	Option D	f	4
76487a71-f58e-414d-b1f5-040923190040	da4b511c-10f3-464d-8fa0-af0e99ef931f	Option A	f	1
53185ca7-1b72-4753-85fd-70c94046aa54	da4b511c-10f3-464d-8fa0-af0e99ef931f	Option B	t	2
e4997f9d-7024-4d3f-b275-f49a23c2fb53	da4b511c-10f3-464d-8fa0-af0e99ef931f	Option C	f	3
4c20a9c4-177c-4b78-b942-1bf12104eced	da4b511c-10f3-464d-8fa0-af0e99ef931f	Option D	f	4
8f2d1dff-0d1a-49f0-92ee-c39bff36743e	655f352f-f301-46db-b4bc-567243efa169	Option A	f	1
6398a3cf-159b-4eaa-b293-b6ffd6d826ef	655f352f-f301-46db-b4bc-567243efa169	Option B	f	2
fd26944e-f4c3-4178-96ec-e98c2443057e	655f352f-f301-46db-b4bc-567243efa169	Option C	t	3
2b77ae99-425f-4d36-99e4-b3f4eb6ccc29	655f352f-f301-46db-b4bc-567243efa169	Option D	f	4
90bcf87f-542c-4359-8c23-53fd9d6cf6b6	80d0fd9c-6e68-4186-8e8b-8614880ffe4d	Option A	f	1
a0e4a701-cab9-4284-ab1d-03c8235935bd	80d0fd9c-6e68-4186-8e8b-8614880ffe4d	Option B	f	2
5880e27e-8fc2-4bf3-9800-6e802d616878	80d0fd9c-6e68-4186-8e8b-8614880ffe4d	Option C	f	3
09140bc8-4719-4695-8d3e-0636730d6fc3	80d0fd9c-6e68-4186-8e8b-8614880ffe4d	Option D	t	4
cabbb35c-4b6d-45fb-8105-40e1fe997fa8	0e002015-f663-455b-bcce-4b22827dc05c	Option A	t	1
9528ebf3-9f19-45a8-bf8e-dae476913426	0e002015-f663-455b-bcce-4b22827dc05c	Option B	f	2
a7c1ecae-a4b3-4d1a-bf60-e671ec011bdc	0e002015-f663-455b-bcce-4b22827dc05c	Option C	f	3
bb6f8d3b-5e81-4b89-88e1-542523d05793	0e002015-f663-455b-bcce-4b22827dc05c	Option D	f	4
2ebb2e74-5146-4872-8d8b-37339441e7ea	a0b0ac84-1629-4fdd-94bf-fdd9a82a9229	Option A	f	1
db3cd77e-62d5-4959-b47c-eb0a04b5f021	a0b0ac84-1629-4fdd-94bf-fdd9a82a9229	Option B	t	2
8e467cb0-eddf-4d70-9c06-ba0e3627ffa9	a0b0ac84-1629-4fdd-94bf-fdd9a82a9229	Option C	f	3
0e6388d8-c349-4389-98d1-fe4c40347114	a0b0ac84-1629-4fdd-94bf-fdd9a82a9229	Option D	f	4
edc28b7f-2691-4b38-b3f6-4c0f88015591	02c574fb-b58a-4321-8baf-b300a132a8f7	Option A	f	1
e9f33f15-bb44-42cc-be8e-ecc8b7fb61f7	02c574fb-b58a-4321-8baf-b300a132a8f7	Option B	t	2
04637b2b-9d84-4895-a2f9-6cfbb8138a8b	02c574fb-b58a-4321-8baf-b300a132a8f7	Option C	f	3
e62ce160-cc5f-439f-9384-9fbeef1ac29f	02c574fb-b58a-4321-8baf-b300a132a8f7	Option D	f	4
7a43209d-026c-497e-bdfe-677963a5476b	ed36e338-f74f-493d-8c22-097cb87a5561	Option A	f	1
07568078-148e-4444-83db-a0ffc36226c7	ed36e338-f74f-493d-8c22-097cb87a5561	Option B	f	2
c73343f8-c86b-4f32-85ae-42d28857cd71	ed36e338-f74f-493d-8c22-097cb87a5561	Option C	t	3
9e4e993b-14a6-4703-8d70-96ef0fcecf92	ed36e338-f74f-493d-8c22-097cb87a5561	Option D	f	4
d8916872-dd5f-4341-92f2-df81593fd4d8	5849b610-2faf-449f-9f02-9ddd26f0f7fe	Option A	f	1
fcf556a4-53e5-48ec-b65d-cb3e6dc059b4	5849b610-2faf-449f-9f02-9ddd26f0f7fe	Option B	f	2
d3956385-8a48-489e-9c10-6d6d60df2e50	5849b610-2faf-449f-9f02-9ddd26f0f7fe	Option C	f	3
8b498d5a-4d61-4044-b7f8-1ced2efc039d	5849b610-2faf-449f-9f02-9ddd26f0f7fe	Option D	t	4
959da321-71ed-43a7-b8e4-8848f8a185ba	6e838f4e-b4b2-45be-8a0e-acb930a37d8a	Option A	t	1
bb4b5600-174d-4375-8286-095c998587b1	6e838f4e-b4b2-45be-8a0e-acb930a37d8a	Option B	f	2
514f6e87-56fb-41ce-8e8b-1fc5891730f8	6e838f4e-b4b2-45be-8a0e-acb930a37d8a	Option C	f	3
72100849-3bae-41c7-aa47-349647c431f2	6e838f4e-b4b2-45be-8a0e-acb930a37d8a	Option D	f	4
d647ba7b-fd6c-46a5-914e-3e58b099c601	8a7ef50e-c059-4ae9-a120-f4b3456373a9	Option A	f	1
a92975bb-bf2d-47bb-9b8c-9dc16a4e5691	8a7ef50e-c059-4ae9-a120-f4b3456373a9	Option B	t	2
2a1d090c-f43c-49ee-a427-89574844114b	8a7ef50e-c059-4ae9-a120-f4b3456373a9	Option C	f	3
fa246384-9196-4c4d-be3d-63cfc9512b95	8a7ef50e-c059-4ae9-a120-f4b3456373a9	Option D	f	4
57de0e05-82b7-4569-b069-9c226ab9f99d	afb23585-8bdd-497a-aa38-2d3c581b6769	Option A	f	1
795e29ab-9836-41dc-8540-9ceba7fd8e5a	afb23585-8bdd-497a-aa38-2d3c581b6769	Option B	t	2
c80c91fa-918a-4d86-bc6c-9271206469ea	afb23585-8bdd-497a-aa38-2d3c581b6769	Option C	f	3
07258226-d588-4f7a-80b2-0afb272909cb	afb23585-8bdd-497a-aa38-2d3c581b6769	Option D	f	4
03f39f24-3258-4128-a795-c349254f0350	57212654-5f73-4a37-96ec-b167f3fbeecf	Option A	f	1
56b20d8c-f367-4f2f-9d12-a3cb36d61534	57212654-5f73-4a37-96ec-b167f3fbeecf	Option B	f	2
1b12377b-35c7-4f9e-a893-c9a82f926077	57212654-5f73-4a37-96ec-b167f3fbeecf	Option C	t	3
9cfce574-4c10-4d8b-9463-4898750edce1	57212654-5f73-4a37-96ec-b167f3fbeecf	Option D	f	4
472ff882-e6e8-42e9-804a-4ca9c709a37e	4f6f917b-d616-4092-b0ac-39e53ad98de5	Option A	f	1
e0021aca-e01e-48a3-8462-dec6d38cea17	4f6f917b-d616-4092-b0ac-39e53ad98de5	Option B	f	2
669a8b27-d276-4b8f-b0a5-f355653dc9a8	4f6f917b-d616-4092-b0ac-39e53ad98de5	Option C	f	3
b36ac46c-fe94-45a0-8e80-23be4d0a8b2a	4f6f917b-d616-4092-b0ac-39e53ad98de5	Option D	t	4
42dc802f-e43d-4f93-8299-2afe7dc6f444	dbdf0ad2-cf95-4adb-ad09-b3a173932006	Option A	t	1
9dabbbce-3f8c-4ac3-9f4c-eeb69a8a69b2	dbdf0ad2-cf95-4adb-ad09-b3a173932006	Option B	f	2
70e489d8-f649-493e-bf6f-453b5aea607b	dbdf0ad2-cf95-4adb-ad09-b3a173932006	Option C	f	3
26798e8b-7467-4650-8f8f-9b7b75d08b90	dbdf0ad2-cf95-4adb-ad09-b3a173932006	Option D	f	4
5a181a3b-42cc-4bc7-990d-e9a09a80764a	c9820e75-e39b-40d1-8c8d-4c06569123a2	Option A	f	1
03f8c07e-866b-402d-a10d-f0fc700f8fba	c9820e75-e39b-40d1-8c8d-4c06569123a2	Option B	t	2
897d66fc-cb16-4d39-824c-f40815f161f0	c9820e75-e39b-40d1-8c8d-4c06569123a2	Option C	f	3
d82f7e74-4f5b-498a-9dde-27860b883204	c9820e75-e39b-40d1-8c8d-4c06569123a2	Option D	f	4
7695609c-7871-4420-b29e-63ad16c4a4ee	c2cd4463-9d41-425b-9393-fdb04cfe2f63	Option A	f	1
2ffc97d8-aee2-4760-9f42-36aac550d650	c2cd4463-9d41-425b-9393-fdb04cfe2f63	Option B	t	2
c01edfea-17e4-4097-9696-3084863a4e23	c2cd4463-9d41-425b-9393-fdb04cfe2f63	Option C	f	3
7b5cb1d9-e3e7-4b7a-bd85-b9566d61ef2e	c2cd4463-9d41-425b-9393-fdb04cfe2f63	Option D	f	4
14989288-8d53-49ad-b62d-dabb699e54d4	41f43d5d-ac0b-4d2c-be8c-c0fe84c0acf9	Option A	f	1
28e88308-1db9-4fc2-93ee-ecd8bfdce1a7	41f43d5d-ac0b-4d2c-be8c-c0fe84c0acf9	Option B	f	2
bcd0ec6a-6d8e-439b-a306-93c536b8f62c	41f43d5d-ac0b-4d2c-be8c-c0fe84c0acf9	Option C	t	3
a3c5f9e0-c879-44a5-b7b6-9a4eaa0bf115	41f43d5d-ac0b-4d2c-be8c-c0fe84c0acf9	Option D	f	4
633034d8-84f8-4d4f-9c00-7193604731ab	3384b0df-33e7-4505-bd23-eacbcd2af28f	Option A	f	1
534f427d-b347-4e8b-8a2c-786baa1838ab	3384b0df-33e7-4505-bd23-eacbcd2af28f	Option B	f	2
e0171733-2bca-4f56-984f-36c96c6a9a5a	3384b0df-33e7-4505-bd23-eacbcd2af28f	Option C	f	3
96da6eb6-a12b-4e03-888c-b7e38931788e	3384b0df-33e7-4505-bd23-eacbcd2af28f	Option D	t	4
a297ba8c-0a68-4f90-b5d3-03c530e584c1	2f226e14-f34a-4af0-a013-9ba072e4b762	Option A	t	1
4c675f37-e40a-4651-b3e9-ff459f83ac66	2f226e14-f34a-4af0-a013-9ba072e4b762	Option B	f	2
4a8cb193-ec19-465d-a8bd-cea3b2db403a	2f226e14-f34a-4af0-a013-9ba072e4b762	Option C	f	3
b0836608-44d3-41bc-83f9-0da0ca8354b1	2f226e14-f34a-4af0-a013-9ba072e4b762	Option D	f	4
dc784d57-2d95-4579-adf7-ae938c5a05f3	f64aae7f-54a6-46b1-a387-17f1b728bfcd	Option A	f	1
29e47c9d-7afc-4510-91fd-e1c561e312d9	f64aae7f-54a6-46b1-a387-17f1b728bfcd	Option B	t	2
92d88867-7414-4164-8d3b-5770cf580244	f64aae7f-54a6-46b1-a387-17f1b728bfcd	Option C	f	3
6fda25b0-e7fa-4651-9443-12a6b8a73ff7	f64aae7f-54a6-46b1-a387-17f1b728bfcd	Option D	f	4
71845839-a403-4859-a1d9-25a2b5a753d6	805a4a40-b130-4825-ba2a-11b0d9d3b5ba	Option A	f	1
b48741a0-dc5e-415f-8d7e-816a4d6ae022	805a4a40-b130-4825-ba2a-11b0d9d3b5ba	Option B	t	2
5626f42f-0fb0-4753-995b-8ac12841c88e	805a4a40-b130-4825-ba2a-11b0d9d3b5ba	Option C	f	3
d90fc8b1-6df6-45b2-b9d3-f08f00bddace	805a4a40-b130-4825-ba2a-11b0d9d3b5ba	Option D	f	4
275c8c80-b51a-4ee4-8380-9879fe1f757a	182849cb-885c-4c10-bad7-6a0bda93b83f	Option A	f	1
cd5001f7-3a8e-4bef-8ed2-c6a9cc17029c	182849cb-885c-4c10-bad7-6a0bda93b83f	Option B	f	2
dbd92c86-bb24-40e2-a173-24f916998381	182849cb-885c-4c10-bad7-6a0bda93b83f	Option C	t	3
ff1c2c3f-1576-4c67-b39c-fa3c95a517d4	182849cb-885c-4c10-bad7-6a0bda93b83f	Option D	f	4
b8fc3392-3d20-414c-8dbc-e0b28547ff73	0ff32538-862f-4b19-b7d8-13cecbe3fbf4	Option A	f	1
b342ca1f-612a-4776-bff9-4ba954d647e6	0ff32538-862f-4b19-b7d8-13cecbe3fbf4	Option B	f	2
d4bc2d56-07a6-4f90-9d79-1dae36751dc1	0ff32538-862f-4b19-b7d8-13cecbe3fbf4	Option C	f	3
a6cf56bd-8cff-40b7-ae7a-b33d807b66cf	0ff32538-862f-4b19-b7d8-13cecbe3fbf4	Option D	t	4
a65da553-49dc-4bdd-9336-69c740f5bd12	342ac555-702d-4419-a8a7-7d2659a8a005	Option A	t	1
0366a746-19e3-4bc5-b099-3f50b504e677	342ac555-702d-4419-a8a7-7d2659a8a005	Option B	f	2
aacbb4fc-8470-4ff8-965b-8ec8983c7ea7	342ac555-702d-4419-a8a7-7d2659a8a005	Option C	f	3
6a4d882e-19c9-4ca5-a4d6-30526054bab1	342ac555-702d-4419-a8a7-7d2659a8a005	Option D	f	4
3985aa5f-dcda-4c20-bfad-bd29dfe9f5a0	9e7cd74e-e5d7-4f5c-9237-7d64bfc72805	Option A	f	1
af4c2f18-53e2-4ef0-8bd5-4564b4a83134	9e7cd74e-e5d7-4f5c-9237-7d64bfc72805	Option B	t	2
1260059f-53f0-4454-8e78-bbd3a9ccb709	9e7cd74e-e5d7-4f5c-9237-7d64bfc72805	Option C	f	3
d8aaa2e0-4507-404d-99c2-af28ba93b831	9e7cd74e-e5d7-4f5c-9237-7d64bfc72805	Option D	f	4
6fe31eb3-cbaf-422b-b365-44287c3630fc	22178d2a-1cb7-4729-8e22-fd6bc0061466	Option A	f	1
51482b2c-c9cc-4dd2-b836-fb3fb33835ef	22178d2a-1cb7-4729-8e22-fd6bc0061466	Option B	t	2
b4602315-93dc-41ba-a453-aa5ac9ff1c00	22178d2a-1cb7-4729-8e22-fd6bc0061466	Option C	f	3
99884fa2-fbce-42d1-b31a-466fc8afa437	22178d2a-1cb7-4729-8e22-fd6bc0061466	Option D	f	4
ede52843-e79c-43f1-b551-c7081020047d	765a0d20-25ad-4f78-a6e4-3731681299c3	Option A	f	1
35a6234c-5730-46ac-9578-7b8942f2a1ac	765a0d20-25ad-4f78-a6e4-3731681299c3	Option B	f	2
8151896e-7701-40c0-bd81-bd620f4c15ff	765a0d20-25ad-4f78-a6e4-3731681299c3	Option C	t	3
9c058232-ec1b-4a9c-8eb4-03e4c1f2159f	765a0d20-25ad-4f78-a6e4-3731681299c3	Option D	f	4
896991e5-09c6-4bb5-bdfb-17e503267342	03c2877f-df89-4f46-9313-39b20f3140f3	Option A	f	1
6ad2101a-6f87-487e-8964-e9caa7520b41	03c2877f-df89-4f46-9313-39b20f3140f3	Option B	f	2
21b948b1-eef0-4af0-aed8-23a0634a5666	03c2877f-df89-4f46-9313-39b20f3140f3	Option C	f	3
1a8ccc36-31d1-4c5c-97de-b212e9775b92	03c2877f-df89-4f46-9313-39b20f3140f3	Option D	t	4
579a75c0-b6a9-47c1-8a1f-bd9a25ae48ae	df5aae4c-db9e-41cf-87be-26e716f5d1a4	Option A	t	1
752f91d7-c0e1-4ead-94b5-b8299868c2bd	df5aae4c-db9e-41cf-87be-26e716f5d1a4	Option B	f	2
dfc978c8-c7bb-478c-8212-b72a7c8c3063	df5aae4c-db9e-41cf-87be-26e716f5d1a4	Option C	f	3
51ff2622-60bf-44a7-b35c-9d78db66bf5d	df5aae4c-db9e-41cf-87be-26e716f5d1a4	Option D	f	4
54b04ad6-367a-4526-8609-09efbb563fdc	efd59e02-686a-4701-8df4-72bdabb0841f	Option A	f	1
735f2236-08fc-4fc2-9c03-6a2c5e92f72e	efd59e02-686a-4701-8df4-72bdabb0841f	Option B	t	2
3344aad0-5d95-416a-b9fc-33a9f80bccef	efd59e02-686a-4701-8df4-72bdabb0841f	Option C	f	3
efe5ae94-d0df-4cd6-877d-657b0ea24e26	efd59e02-686a-4701-8df4-72bdabb0841f	Option D	f	4
9e4b539d-3b0e-473b-a7f9-5df52828129b	b7d6d94f-fe21-42a0-a6bf-d80cb2d9c64b	Option A	f	1
4dcaa70d-9ffb-4189-beb0-f2b2d401f48f	b7d6d94f-fe21-42a0-a6bf-d80cb2d9c64b	Option B	t	2
1c201341-f6fa-433c-993e-f0fb4cddfd85	b7d6d94f-fe21-42a0-a6bf-d80cb2d9c64b	Option C	f	3
15b981b3-0221-4f60-84fc-7c91f19f64f3	b7d6d94f-fe21-42a0-a6bf-d80cb2d9c64b	Option D	f	4
74490bf7-9333-4b22-9f61-a4bc847c74f2	cadb3ee0-9ede-4693-a848-f5ef3e0d9a7c	Option A	f	1
43100fef-acc8-4a1c-8b70-71ccd2028f1e	cadb3ee0-9ede-4693-a848-f5ef3e0d9a7c	Option B	f	2
a92607b3-2871-4ea1-bd6a-a7f6efc34d43	cadb3ee0-9ede-4693-a848-f5ef3e0d9a7c	Option C	t	3
a3747200-b91a-4323-8e32-47624c059db6	cadb3ee0-9ede-4693-a848-f5ef3e0d9a7c	Option D	f	4
c0cfa388-7400-4eee-abfe-eaef0647f39a	65b16f63-c8df-4f6f-8002-36277e3305eb	Option A	f	1
e41288ff-955b-4afe-9f03-ec8d7cb1da57	65b16f63-c8df-4f6f-8002-36277e3305eb	Option B	f	2
643cf462-121f-4543-be3f-eada60a6818f	65b16f63-c8df-4f6f-8002-36277e3305eb	Option C	f	3
03e8f25f-60c4-463f-924a-82aea4858088	65b16f63-c8df-4f6f-8002-36277e3305eb	Option D	t	4
e840ca10-1402-46f1-9919-32efef39e962	8fd56efa-7cfc-49b2-b76c-3215133153e7	Option A	t	1
40a3eaa5-d2e7-4a3f-8758-bf0a37aeea1b	8fd56efa-7cfc-49b2-b76c-3215133153e7	Option B	f	2
9ce8ad74-9733-4712-b168-93302efd66de	8fd56efa-7cfc-49b2-b76c-3215133153e7	Option C	f	3
c5a8d47d-3fec-480d-ae45-655ce4498439	8fd56efa-7cfc-49b2-b76c-3215133153e7	Option D	f	4
1c37df8c-57ee-4d5c-8dac-1fcf02b9a8cc	5a16fb16-0834-4820-9f46-8b9f73a4bcc7	Option A	f	1
d394f4ce-58d0-4c01-a27f-1cee7d8d5469	5a16fb16-0834-4820-9f46-8b9f73a4bcc7	Option B	t	2
0fa88e1e-3943-45ae-a886-70f4916e8984	5a16fb16-0834-4820-9f46-8b9f73a4bcc7	Option C	f	3
66a1130d-b416-4b4d-b730-63ff94821f33	5a16fb16-0834-4820-9f46-8b9f73a4bcc7	Option D	f	4
73680589-68f9-46d4-bc5f-e59550cd75ea	d0d39025-7813-433d-8583-ef5cf872a22b	Option A	f	1
7f54b244-e0ec-4cc2-be9f-33ef0ac75667	d0d39025-7813-433d-8583-ef5cf872a22b	Option B	t	2
0f381e44-cc75-4ff4-87c9-c4ec4c91f8a8	d0d39025-7813-433d-8583-ef5cf872a22b	Option C	f	3
f9f7efac-a462-4164-b85a-4876e0dbb736	d0d39025-7813-433d-8583-ef5cf872a22b	Option D	f	4
edc30fe1-5d68-4c17-af73-9c4c2d2b59b4	5b94a8c1-a147-4446-9c4c-45772a47bb34	Option A	f	1
28ef5395-a4a6-4c17-9622-174c60a6131e	5b94a8c1-a147-4446-9c4c-45772a47bb34	Option B	f	2
a401c956-eb0c-48d7-bef2-7f0f7e106165	5b94a8c1-a147-4446-9c4c-45772a47bb34	Option C	t	3
45025491-57cb-4118-899f-667bf84a2f8f	5b94a8c1-a147-4446-9c4c-45772a47bb34	Option D	f	4
af421050-b73b-4285-b976-5febc2aaa878	aedfe7ce-a52c-47a8-9443-fbc187c342b6	Option A	f	1
0c2f267f-14e7-412c-8a7b-10ff3ee4df9d	aedfe7ce-a52c-47a8-9443-fbc187c342b6	Option B	f	2
dd517adb-8d6f-415b-aa8e-05a011e376f3	aedfe7ce-a52c-47a8-9443-fbc187c342b6	Option C	f	3
ad09cf2c-7c23-4c33-9632-73ac7be2ef92	aedfe7ce-a52c-47a8-9443-fbc187c342b6	Option D	t	4
153981dc-e859-43e1-86d0-47abc85d2b93	b110754e-b4b2-4800-a273-fbc50d318c28	Option A	t	1
33f6bb1c-69e1-4dce-b9cb-d934b6c44da7	b110754e-b4b2-4800-a273-fbc50d318c28	Option B	f	2
7e550dd5-ea7b-4220-bd69-b5349c144c80	b110754e-b4b2-4800-a273-fbc50d318c28	Option C	f	3
2c3394bd-70c1-4b95-90aa-da778f0ae307	b110754e-b4b2-4800-a273-fbc50d318c28	Option D	f	4
20d3a53d-2c00-4735-94f3-1d3e333cd93e	1321f389-037b-4141-bae7-0a66b10b0575	Option A	f	1
f9570950-150c-482b-abc9-1af5c08ed439	1321f389-037b-4141-bae7-0a66b10b0575	Option B	t	2
59226087-78f9-4e87-a4b7-12d23b9d7025	1321f389-037b-4141-bae7-0a66b10b0575	Option C	f	3
c7bc1f81-70ff-45f4-b787-577a901fb0c3	1321f389-037b-4141-bae7-0a66b10b0575	Option D	f	4
2be7f5a9-4f41-4d70-8c50-b5660f3eb417	b090dc4b-837d-425c-b37b-be844cf627d7	Option A	f	1
46d27d6d-8b25-4344-880d-06f2c85408ad	b090dc4b-837d-425c-b37b-be844cf627d7	Option B	t	2
9b1f181f-f43c-4970-812d-218eae7b561f	b090dc4b-837d-425c-b37b-be844cf627d7	Option C	f	3
4feba5a5-fe4f-4e4e-bb48-6774b44c5b19	b090dc4b-837d-425c-b37b-be844cf627d7	Option D	f	4
e77418cb-d3bd-4b4a-b4f2-c6851efbc13b	dc29bae1-e97b-4cc3-82b8-96a68ca1ad92	Option A	f	1
dd80d401-45af-420b-a631-80d4952bad8f	dc29bae1-e97b-4cc3-82b8-96a68ca1ad92	Option B	f	2
0acab87f-2a87-4e50-a3fd-53e75b24b616	dc29bae1-e97b-4cc3-82b8-96a68ca1ad92	Option C	t	3
e141c80f-287c-4994-9e21-856dd7bf9410	dc29bae1-e97b-4cc3-82b8-96a68ca1ad92	Option D	f	4
2367d2d3-de3a-4aa8-99ff-72f0180fd6e9	90c7e828-24f0-4051-9573-68c31ebbe637	Option A	f	1
24ea6556-be8c-4bf2-909a-a9c7768d45f7	90c7e828-24f0-4051-9573-68c31ebbe637	Option B	f	2
fb54e270-ad53-4d49-89ed-bfc53739ac41	90c7e828-24f0-4051-9573-68c31ebbe637	Option C	f	3
240458c2-c09d-49f7-a897-e2f7d4523504	90c7e828-24f0-4051-9573-68c31ebbe637	Option D	t	4
a59402d3-2b15-47cd-afb6-81c2870d3053	8bf3f0ea-051d-4aad-b17c-5755ba6de07c	Option A	t	1
a36f02ac-88a7-4b8d-948b-bccd62ce81db	8bf3f0ea-051d-4aad-b17c-5755ba6de07c	Option B	f	2
89a4fdad-c5f8-42d9-885b-a1d3a114cb26	8bf3f0ea-051d-4aad-b17c-5755ba6de07c	Option C	f	3
d514ce7b-1440-471f-adbe-e31446f61f5e	8bf3f0ea-051d-4aad-b17c-5755ba6de07c	Option D	f	4
331a1250-f208-4437-a7eb-4289b2ab4a7c	4c251056-9802-490a-91a6-2c608fab3cfe	Option A	f	1
7014bd8d-3a8b-40dd-b85a-6c60dc280ecf	4c251056-9802-490a-91a6-2c608fab3cfe	Option B	t	2
afa2b125-bbf6-4f8e-b073-1456df05ae2a	4c251056-9802-490a-91a6-2c608fab3cfe	Option C	f	3
f7416f03-d694-4154-9ae7-b9b1dba852c2	4c251056-9802-490a-91a6-2c608fab3cfe	Option D	f	4
fb702621-e0fc-4520-8ada-a23c17da0512	acf60aee-d036-47ae-94e8-2023492c8494	Option A	f	1
3c6361b6-338d-43c6-af6d-5a80cb903496	acf60aee-d036-47ae-94e8-2023492c8494	Option B	t	2
5e50874f-34c2-4e0e-bb80-b174b8237fa1	acf60aee-d036-47ae-94e8-2023492c8494	Option C	f	3
d478d513-a966-4ebd-96ab-e5ecc858d055	acf60aee-d036-47ae-94e8-2023492c8494	Option D	f	4
a485b3ad-a03c-4d4e-99ac-102191726fc1	fb2f7fc0-b18f-4012-a702-9d6edc655b81	Option A	f	1
0ddc40de-7e10-4aff-9de0-41348fb21e5e	fb2f7fc0-b18f-4012-a702-9d6edc655b81	Option B	f	2
15496cf3-7192-4b99-b6fd-5911c4581917	fb2f7fc0-b18f-4012-a702-9d6edc655b81	Option C	t	3
efcbf9ba-1719-44cb-9d28-df2db561c394	fb2f7fc0-b18f-4012-a702-9d6edc655b81	Option D	f	4
aa8204f2-61fc-4e8f-943f-5581c9110dcd	1dca2d0a-1df3-4500-8ad0-c7ac7112cea0	Option A	f	1
90a789eb-39a9-4583-a7d5-0a012fc48216	1dca2d0a-1df3-4500-8ad0-c7ac7112cea0	Option B	f	2
d408c108-3907-489f-a037-441b6d1e0938	1dca2d0a-1df3-4500-8ad0-c7ac7112cea0	Option C	f	3
2c15c9ac-d4db-4429-b583-167987321e71	1dca2d0a-1df3-4500-8ad0-c7ac7112cea0	Option D	t	4
3a735759-8f16-407e-aadc-e72abc3119e3	0bf63b2b-d59e-4003-9b58-f86b5931b0f8	Option A	t	1
cf467639-359c-493e-a27c-0c57dcf394ce	0bf63b2b-d59e-4003-9b58-f86b5931b0f8	Option B	f	2
42f9c7f5-6701-4fd2-b207-9251648bf793	0bf63b2b-d59e-4003-9b58-f86b5931b0f8	Option C	f	3
510d0fcc-0655-443d-badd-193832f53aad	0bf63b2b-d59e-4003-9b58-f86b5931b0f8	Option D	f	4
159e0dc7-4b81-44f4-a293-ed21f8401fd4	7edbf11b-b851-4b25-a20f-f6ce2ba9d387	Option A	f	1
c7e5e974-3848-4c41-abe3-4c04df55a5d6	7edbf11b-b851-4b25-a20f-f6ce2ba9d387	Option B	t	2
174bf2fc-8f7c-4e97-813b-9b1fda762b16	7edbf11b-b851-4b25-a20f-f6ce2ba9d387	Option C	f	3
ff9fd33c-3dbe-4940-90b4-5147af82d74c	7edbf11b-b851-4b25-a20f-f6ce2ba9d387	Option D	f	4
5e2becd6-6d84-4b78-92ad-b9d7e2a9ead3	f54ac6ae-d9c9-4269-83aa-c992f3cda491	Option A	f	1
0cd4a59f-0e69-4590-ab1c-c03aa2071f3d	f54ac6ae-d9c9-4269-83aa-c992f3cda491	Option B	t	2
dd98d368-2c99-4f56-9dd2-0c43d08a0019	f54ac6ae-d9c9-4269-83aa-c992f3cda491	Option C	f	3
4e24064c-dd2a-4ad8-af7a-427b7603852e	f54ac6ae-d9c9-4269-83aa-c992f3cda491	Option D	f	4
392c0aad-4a29-430b-8114-c617c4a832b0	d1df1da4-4588-4f95-959f-82e0b8a4c6d0	Option A	f	1
943bfe96-cd0c-412a-8721-3996cfc62f3c	d1df1da4-4588-4f95-959f-82e0b8a4c6d0	Option B	f	2
535a17b2-7f0e-4b21-bd78-8b3e54a14c4b	d1df1da4-4588-4f95-959f-82e0b8a4c6d0	Option C	t	3
2e3dab0f-183b-4b40-81a3-0397ac6a1e7f	d1df1da4-4588-4f95-959f-82e0b8a4c6d0	Option D	f	4
96bad766-fe07-4306-b9e3-d6a4ebf49d83	343442d5-4c8a-4b59-86ec-7b107b9cbc4c	Option A	f	1
24e950a7-ff1d-4901-a527-88d5181333eb	343442d5-4c8a-4b59-86ec-7b107b9cbc4c	Option B	f	2
ff72d9fa-a463-4bf6-bcf0-efca3623158c	343442d5-4c8a-4b59-86ec-7b107b9cbc4c	Option C	f	3
ce69fa24-5acf-4599-8592-20295df229c6	343442d5-4c8a-4b59-86ec-7b107b9cbc4c	Option D	t	4
3d17980a-c65a-47c9-9ff0-2d9122d1c337	3932caed-6cbc-4e02-88c2-ac78a2709141	Option A	t	1
b593ba6a-4a0d-4301-8ba2-c2862598690e	3932caed-6cbc-4e02-88c2-ac78a2709141	Option B	f	2
3ee5f285-3d8a-44a3-8c48-2d717b61c13e	3932caed-6cbc-4e02-88c2-ac78a2709141	Option C	f	3
c693bbe4-d498-44b3-8629-5356323a358a	3932caed-6cbc-4e02-88c2-ac78a2709141	Option D	f	4
59d57930-c058-4d5b-97d4-00e69ce01b89	21907a58-525f-49b6-ace8-83b80ff8db2c	Option A	f	1
c422fc65-40fe-40d0-b427-94cfd5db248a	21907a58-525f-49b6-ace8-83b80ff8db2c	Option B	t	2
cdf1756f-73da-4ffe-930e-4060cd19d4d4	21907a58-525f-49b6-ace8-83b80ff8db2c	Option C	f	3
f8a131d1-7df4-425b-94a5-6368d4df32d7	21907a58-525f-49b6-ace8-83b80ff8db2c	Option D	f	4
\.


--
-- Data for Name: questions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.questions (id, skill_id, type, text, explanation, difficulty, status, generation_method, source_resource_id, source_page, source_job_id, created_by, reviewed_by, created_at) FROM stdin;
d9a7ed8d-0efb-42f4-91a0-78bdc550ba52	9	mcq_single	Nowcasting: sample question 1	\N	2	approved	llm	\N	\N	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2e42c806-48d6-422a-b282-2b30f0484c3c	2026-09-26 18:31:45.462661+00
da111a44-1bc7-4313-8d49-000d17b0e908	9	mcq_single	Nowcasting: sample question 2	\N	3	approved	llm	\N	\N	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2e42c806-48d6-422a-b282-2b30f0484c3c	2026-09-26 18:31:45.462661+00
c62fc8fd-203c-4951-8ca4-b4e9900c19f0	9	mcq_single	Nowcasting: sample question 3	\N	4	approved	manual	\N	\N	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2e42c806-48d6-422a-b282-2b30f0484c3c	2026-09-26 18:31:45.462661+00
55e092b5-7f15-4069-adc6-dd5b03252c0d	9	mcq_single	Nowcasting: sample question 4	\N	1	approved	manual	\N	\N	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2e42c806-48d6-422a-b282-2b30f0484c3c	2026-09-26 18:31:45.462661+00
2311cfcc-9214-467a-94a1-844f62b2b8fc	9	mcq_single	Nowcasting: sample question 5	\N	2	approved	manual	\N	\N	\N	2e42c806-48d6-422a-b282-2b30f0484c3c	2e42c806-48d6-422a-b282-2b30f0484c3c	2026-09-26 18:31:45.462661+00
0567f1c1-bbf2-4e4a-b7db-6befd81352b9	8	mcq_single	NWP Modelling: sample question 1	\N	2	approved	llm	\N	\N	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2026-09-26 18:31:45.462661+00
a0bfeaef-e235-4212-ac4d-7f7ab3ae5ba0	8	mcq_single	NWP Modelling: sample question 2	\N	3	approved	llm	\N	\N	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2026-09-26 18:31:45.462661+00
0501294b-c3f9-4624-b504-cb88972b277f	8	mcq_single	NWP Modelling: sample question 3	\N	4	approved	manual	\N	\N	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2026-09-26 18:31:45.462661+00
321be7de-e911-4765-8fdf-d4bfecf116ae	8	mcq_single	NWP Modelling: sample question 4	\N	1	approved	manual	\N	\N	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2026-09-26 18:31:45.462661+00
7e2d2b5c-62af-4f87-9adf-ddbe7c7be9e2	8	mcq_single	NWP Modelling: sample question 5	\N	2	approved	manual	\N	\N	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2026-09-26 18:31:45.462661+00
e39fbfde-2a2e-481e-841c-29678be88938	11	mcq_single	Automatic Weather Stations: sample question 1	\N	2	approved	llm	\N	\N	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2026-09-26 18:31:45.462661+00
3c479adb-b6c9-4096-9ec1-fccbbf4d5a16	11	mcq_single	Automatic Weather Stations: sample question 2	\N	3	approved	llm	\N	\N	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2026-09-26 18:31:45.462661+00
6d8ec450-e25c-48bf-9709-9acd70197d1b	11	mcq_single	Automatic Weather Stations: sample question 3	\N	4	approved	manual	\N	\N	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2026-09-26 18:31:45.462661+00
c022f12d-04fd-41c9-a421-41863d673eeb	11	mcq_single	Automatic Weather Stations: sample question 4	\N	1	approved	manual	\N	\N	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2026-09-26 18:31:45.462661+00
0b2e1d11-24b7-4147-ad94-d4c0ad39a51f	11	mcq_single	Automatic Weather Stations: sample question 5	\N	2	approved	manual	\N	\N	\N	ff73e90e-1654-4bfd-8c73-43ad75a07f21	ff73e90e-1654-4bfd-8c73-43ad75a07f21	2026-09-26 18:31:45.462661+00
842d3611-ab31-4f65-9d2b-a0546b1db981	7	mcq_single	Tropical Cyclone Forecasting: sample question 1	\N	2	approved	llm	\N	\N	\N	ff38df49-9e3b-4df5-92a2-4852f8b79c74	ff38df49-9e3b-4df5-92a2-4852f8b79c74	2026-09-26 18:31:45.462661+00
3712c7d2-064b-41bf-afc4-209ba638ad38	7	mcq_single	Tropical Cyclone Forecasting: sample question 2	\N	3	approved	llm	\N	\N	\N	ff38df49-9e3b-4df5-92a2-4852f8b79c74	ff38df49-9e3b-4df5-92a2-4852f8b79c74	2026-09-26 18:31:45.462661+00
dddf7001-2e03-4db3-80f2-ac3b8eb43044	7	mcq_single	Tropical Cyclone Forecasting: sample question 3	\N	4	approved	manual	\N	\N	\N	ff38df49-9e3b-4df5-92a2-4852f8b79c74	ff38df49-9e3b-4df5-92a2-4852f8b79c74	2026-09-26 18:31:45.462661+00
dda73b09-c7af-4bdf-b308-14c0518c3cbd	7	mcq_single	Tropical Cyclone Forecasting: sample question 4	\N	1	approved	manual	\N	\N	\N	ff38df49-9e3b-4df5-92a2-4852f8b79c74	ff38df49-9e3b-4df5-92a2-4852f8b79c74	2026-09-26 18:31:45.462661+00
ae36ca61-ad6e-44c4-b3a0-ea0644f6cd56	7	mcq_single	Tropical Cyclone Forecasting: sample question 5	\N	2	approved	manual	\N	\N	\N	ff38df49-9e3b-4df5-92a2-4852f8b79c74	ff38df49-9e3b-4df5-92a2-4852f8b79c74	2026-09-26 18:31:45.462661+00
276f4198-3410-4b9a-9bef-8d972380df31	6	mcq_single	Monsoon Forecasting: sample question 1	\N	2	approved	llm	\N	\N	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	2ae7d31a-ec05-402a-8104-ba433a1644eb	2026-09-26 18:31:45.462661+00
ada55e48-e425-4bb0-b5ce-62df4efe7a59	6	mcq_single	Monsoon Forecasting: sample question 2	\N	3	approved	llm	\N	\N	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	2ae7d31a-ec05-402a-8104-ba433a1644eb	2026-09-26 18:31:45.462661+00
1618e633-7082-4fb8-b5ee-c0cab2a891da	6	mcq_single	Monsoon Forecasting: sample question 3	\N	4	approved	manual	\N	\N	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	2ae7d31a-ec05-402a-8104-ba433a1644eb	2026-09-26 18:31:45.462661+00
fdd5557e-35cd-4786-8af2-5dbe641d4078	6	mcq_single	Monsoon Forecasting: sample question 4	\N	1	approved	manual	\N	\N	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	2ae7d31a-ec05-402a-8104-ba433a1644eb	2026-09-26 18:31:45.462661+00
cf3b477d-5c66-4ff9-9869-4d6414876655	6	mcq_single	Monsoon Forecasting: sample question 5	\N	2	approved	manual	\N	\N	\N	2ae7d31a-ec05-402a-8104-ba433a1644eb	2ae7d31a-ec05-402a-8104-ba433a1644eb	2026-09-26 18:31:45.462661+00
a6f81972-5233-4fb7-8336-bdfab28de722	13	mcq_single	Doppler Weather Radar: sample question 1	\N	2	approved	llm	\N	\N	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5db62bba-e3f6-4551-81f7-9d9237055aa3	2026-09-26 18:31:45.462661+00
df87edf7-91a0-416a-a138-c6974ad4b26c	13	mcq_single	Doppler Weather Radar: sample question 2	\N	3	approved	llm	\N	\N	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5db62bba-e3f6-4551-81f7-9d9237055aa3	2026-09-26 18:31:45.462661+00
481e800e-c390-452e-941b-8ba404541de2	13	mcq_single	Doppler Weather Radar: sample question 3	\N	4	approved	manual	\N	\N	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5db62bba-e3f6-4551-81f7-9d9237055aa3	2026-09-26 18:31:45.462661+00
54092566-73c2-412f-b707-977e9d51421f	13	mcq_single	Doppler Weather Radar: sample question 4	\N	1	approved	manual	\N	\N	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5db62bba-e3f6-4551-81f7-9d9237055aa3	2026-09-26 18:31:45.462661+00
723f7e35-d502-4ce2-9bc5-c48a9f981dcb	13	mcq_single	Doppler Weather Radar: sample question 5	\N	2	approved	manual	\N	\N	\N	5db62bba-e3f6-4551-81f7-9d9237055aa3	5db62bba-e3f6-4551-81f7-9d9237055aa3	2026-09-26 18:31:45.462661+00
a0939e3f-23c9-4c7d-a493-3b18f8e31f08	12	mcq_single	Satellite Meteorology: sample question 1	\N	2	approved	llm	\N	\N	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	9894043b-3b29-45e0-9abd-9b61597bf09a	2026-09-26 18:31:45.462661+00
9e166d0d-b6d3-4a62-8dbf-e636f0f83f8f	12	mcq_single	Satellite Meteorology: sample question 2	\N	3	approved	llm	\N	\N	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	9894043b-3b29-45e0-9abd-9b61597bf09a	2026-09-26 18:31:45.462661+00
de5ec0f7-b0ad-48c7-9868-50d672f7f0c3	12	mcq_single	Satellite Meteorology: sample question 3	\N	4	approved	manual	\N	\N	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	9894043b-3b29-45e0-9abd-9b61597bf09a	2026-09-26 18:31:45.462661+00
f20a235d-8e11-443b-98db-a9b42f2af4cc	12	mcq_single	Satellite Meteorology: sample question 4	\N	1	approved	manual	\N	\N	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	9894043b-3b29-45e0-9abd-9b61597bf09a	2026-09-26 18:31:45.462661+00
6e03d4c9-da55-4d28-a229-6b27cd0af353	12	mcq_single	Satellite Meteorology: sample question 5	\N	2	approved	manual	\N	\N	\N	9894043b-3b29-45e0-9abd-9b61597bf09a	9894043b-3b29-45e0-9abd-9b61597bf09a	2026-09-26 18:31:45.462661+00
e758450e-85ed-4e7e-a180-f3ad775095ca	11	mcq_single	Automatic Weather Stations: sample question 1	\N	2	approved	llm	\N	\N	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2026-09-26 18:31:45.462661+00
22ef0e6f-422f-41a9-9672-fedf62dce991	11	mcq_single	Automatic Weather Stations: sample question 2	\N	3	approved	llm	\N	\N	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2026-09-26 18:31:45.462661+00
85c159e3-fd28-4167-9d60-9d43b3c12fcc	11	mcq_single	Automatic Weather Stations: sample question 3	\N	4	approved	manual	\N	\N	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2026-09-26 18:31:45.462661+00
482e3171-7c3f-4c58-ad47-a9c05311ec37	11	mcq_single	Automatic Weather Stations: sample question 4	\N	1	approved	manual	\N	\N	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2026-09-26 18:31:45.462661+00
ea861331-71bf-493e-8789-467ba7167e55	11	mcq_single	Automatic Weather Stations: sample question 5	\N	2	approved	manual	\N	\N	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2026-09-26 18:31:45.462661+00
4ba0a281-f461-47f5-b680-d2250d31b6f5	16	mcq_single	Thunderstorm & Lightning: sample question 1	\N	2	approved	llm	\N	\N	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2026-09-26 18:31:45.462661+00
c45b1fb6-e1ec-4f8a-b452-853d64a619c1	16	mcq_single	Thunderstorm & Lightning: sample question 2	\N	3	approved	llm	\N	\N	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2026-09-26 18:31:45.462661+00
e4df6ba2-d87e-43d4-b6ca-938e8c96b418	16	mcq_single	Thunderstorm & Lightning: sample question 3	\N	4	approved	manual	\N	\N	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2026-09-26 18:31:45.462661+00
5d249fde-4b7a-4e1d-bba3-a32fcc09b680	16	mcq_single	Thunderstorm & Lightning: sample question 4	\N	1	approved	manual	\N	\N	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2026-09-26 18:31:45.462661+00
deca4865-7301-4479-924d-4b0566bac65d	16	mcq_single	Thunderstorm & Lightning: sample question 5	\N	2	approved	manual	\N	\N	\N	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2026-09-26 18:31:45.462661+00
5bd7e0eb-5835-479b-a5bd-f00f13b4e540	15	mcq_single	Climate Data Analysis: sample question 1	\N	2	approved	llm	\N	\N	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	2026-09-26 18:31:45.462661+00
a0644737-8a5e-437c-a193-f4813cbdfa7c	15	mcq_single	Climate Data Analysis: sample question 2	\N	3	approved	llm	\N	\N	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	2026-09-26 18:31:45.462661+00
528049ed-aa3f-45d0-acc2-34c04a8ec5fe	15	mcq_single	Climate Data Analysis: sample question 3	\N	4	approved	manual	\N	\N	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	2026-09-26 18:31:45.462661+00
622a682e-3d90-4e5c-be31-62fa0b87660e	15	mcq_single	Climate Data Analysis: sample question 4	\N	1	approved	manual	\N	\N	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	2026-09-26 18:31:45.462661+00
bf89a8a0-39da-4bb5-ad65-693441dee031	15	mcq_single	Climate Data Analysis: sample question 5	\N	2	approved	manual	\N	\N	\N	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	2026-09-26 18:31:45.462661+00
95e84b8c-febc-4a42-ac60-551d14417313	14	mcq_single	Agromet Advisory: sample question 1	\N	2	approved	llm	\N	\N	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	954754ab-6ecc-4d9a-a614-8cc84ffb3348	2026-09-26 18:31:45.462661+00
faf9fcc8-6bbf-4618-90dc-6d7a40d6eca6	14	mcq_single	Agromet Advisory: sample question 2	\N	3	approved	llm	\N	\N	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	954754ab-6ecc-4d9a-a614-8cc84ffb3348	2026-09-26 18:31:45.462661+00
7e8ae0c4-bc98-4629-9779-87785bec5474	14	mcq_single	Agromet Advisory: sample question 3	\N	4	approved	manual	\N	\N	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	954754ab-6ecc-4d9a-a614-8cc84ffb3348	2026-09-26 18:31:45.462661+00
80a3a503-4ae5-4da0-ab98-f5fd59dc0be8	14	mcq_single	Agromet Advisory: sample question 4	\N	1	approved	manual	\N	\N	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	954754ab-6ecc-4d9a-a614-8cc84ffb3348	2026-09-26 18:31:45.462661+00
7237393e-d5f4-4e2e-9dce-f7deb59204e4	14	mcq_single	Agromet Advisory: sample question 5	\N	2	approved	manual	\N	\N	\N	954754ab-6ecc-4d9a-a614-8cc84ffb3348	954754ab-6ecc-4d9a-a614-8cc84ffb3348	2026-09-26 18:31:45.462661+00
437b8adc-8675-4043-aba0-f6b6a92f46b0	8	mcq_single	NWP Modelling: sample question 1	\N	2	approved	llm	\N	\N	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2026-09-26 18:31:45.462661+00
23021390-93b2-40c7-92f9-cfc73690b17a	8	mcq_single	NWP Modelling: sample question 2	\N	3	approved	llm	\N	\N	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2026-09-26 18:31:45.462661+00
7ec974f7-8ffd-4e10-90ce-fc783afd3155	8	mcq_single	NWP Modelling: sample question 3	\N	4	approved	manual	\N	\N	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2026-09-26 18:31:45.462661+00
5ea04a37-889b-4520-8648-7884e8d54922	8	mcq_single	NWP Modelling: sample question 4	\N	1	approved	manual	\N	\N	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2026-09-26 18:31:45.462661+00
fdc4311c-c458-40ef-9238-cb9683368482	8	mcq_single	NWP Modelling: sample question 5	\N	2	approved	manual	\N	\N	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2026-09-26 18:31:45.462661+00
6e98727a-edba-4619-a163-b394595b23c7	18	mcq_single	Flood Meteorology: sample question 1	\N	2	approved	llm	\N	\N	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2026-09-26 18:31:45.462661+00
aaf61416-b013-490b-bdd9-d4f0aaa3bc96	18	mcq_single	Flood Meteorology: sample question 2	\N	3	approved	llm	\N	\N	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2026-09-26 18:31:45.462661+00
4be8599a-6dc6-45af-9fec-4535ad2b93bf	18	mcq_single	Flood Meteorology: sample question 3	\N	4	approved	manual	\N	\N	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2026-09-26 18:31:45.462661+00
bf1b246a-4c6f-4cc4-9e54-aed352f1a9bd	18	mcq_single	Flood Meteorology: sample question 4	\N	1	approved	manual	\N	\N	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2026-09-26 18:31:45.462661+00
cc3a69f6-6b27-40d3-9a58-b3ea913119f2	18	mcq_single	Flood Meteorology: sample question 5	\N	2	approved	manual	\N	\N	\N	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	2026-09-26 18:31:45.462661+00
a0b03234-1d94-4e18-8ee6-d195a36dffe7	17	mcq_single	Heatwave & Cold Wave: sample question 1	\N	2	approved	llm	\N	\N	\N	e9178b69-2339-4a64-857f-5ad0630325a5	e9178b69-2339-4a64-857f-5ad0630325a5	2026-09-26 18:31:45.462661+00
202fdea7-c937-4073-99f1-f83430861d91	17	mcq_single	Heatwave & Cold Wave: sample question 2	\N	3	approved	llm	\N	\N	\N	e9178b69-2339-4a64-857f-5ad0630325a5	e9178b69-2339-4a64-857f-5ad0630325a5	2026-09-26 18:31:45.462661+00
a04a3b3c-ac59-47b2-8225-e17e1f112f91	17	mcq_single	Heatwave & Cold Wave: sample question 3	\N	4	approved	manual	\N	\N	\N	e9178b69-2339-4a64-857f-5ad0630325a5	e9178b69-2339-4a64-857f-5ad0630325a5	2026-09-26 18:31:45.462661+00
bca4bd80-7324-4585-91e4-9bcd75e20b34	17	mcq_single	Heatwave & Cold Wave: sample question 4	\N	1	approved	manual	\N	\N	\N	e9178b69-2339-4a64-857f-5ad0630325a5	e9178b69-2339-4a64-857f-5ad0630325a5	2026-09-26 18:31:45.462661+00
9051ccf3-c419-44d2-ad06-aa49c3f5d545	17	mcq_single	Heatwave & Cold Wave: sample question 5	\N	2	approved	manual	\N	\N	\N	e9178b69-2339-4a64-857f-5ad0630325a5	e9178b69-2339-4a64-857f-5ad0630325a5	2026-09-26 18:31:45.462661+00
c51a7ea7-8aea-47b7-9211-adc3ebd80fd2	16	mcq_single	Thunderstorm & Lightning: sample question 1	\N	2	approved	llm	\N	\N	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	82556fbd-47bf-44ac-aae9-3499c844ea75	2026-09-26 18:31:45.462661+00
dd08aad7-a607-414a-ae3c-ec3e910277d1	16	mcq_single	Thunderstorm & Lightning: sample question 2	\N	3	approved	llm	\N	\N	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	82556fbd-47bf-44ac-aae9-3499c844ea75	2026-09-26 18:31:45.462661+00
fd46de5f-099b-4dcb-a464-b299a4ecedfb	16	mcq_single	Thunderstorm & Lightning: sample question 3	\N	4	approved	manual	\N	\N	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	82556fbd-47bf-44ac-aae9-3499c844ea75	2026-09-26 18:31:45.462661+00
78be014b-69a1-413a-be48-571e435770bd	16	mcq_single	Thunderstorm & Lightning: sample question 4	\N	1	approved	manual	\N	\N	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	82556fbd-47bf-44ac-aae9-3499c844ea75	2026-09-26 18:31:45.462661+00
c897b8cd-5b9e-48bc-b8c6-a4eb51770b48	16	mcq_single	Thunderstorm & Lightning: sample question 5	\N	2	approved	manual	\N	\N	\N	82556fbd-47bf-44ac-aae9-3499c844ea75	82556fbd-47bf-44ac-aae9-3499c844ea75	2026-09-26 18:31:45.462661+00
da4b511c-10f3-464d-8fa0-af0e99ef931f	20	mcq_single	Python for Meteorology: sample question 1	\N	2	approved	llm	\N	\N	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	fa5ba122-30c1-4e56-bc6b-b761794b1528	2026-09-26 18:31:45.462661+00
655f352f-f301-46db-b4bc-567243efa169	20	mcq_single	Python for Meteorology: sample question 2	\N	3	approved	llm	\N	\N	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	fa5ba122-30c1-4e56-bc6b-b761794b1528	2026-09-26 18:31:45.462661+00
80d0fd9c-6e68-4186-8e8b-8614880ffe4d	20	mcq_single	Python for Meteorology: sample question 3	\N	4	approved	manual	\N	\N	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	fa5ba122-30c1-4e56-bc6b-b761794b1528	2026-09-26 18:31:45.462661+00
0e002015-f663-455b-bcce-4b22827dc05c	20	mcq_single	Python for Meteorology: sample question 4	\N	1	approved	manual	\N	\N	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	fa5ba122-30c1-4e56-bc6b-b761794b1528	2026-09-26 18:31:45.462661+00
a0b0ac84-1629-4fdd-94bf-fdd9a82a9229	20	mcq_single	Python for Meteorology: sample question 5	\N	2	approved	manual	\N	\N	\N	fa5ba122-30c1-4e56-bc6b-b761794b1528	fa5ba122-30c1-4e56-bc6b-b761794b1528	2026-09-26 18:31:45.462661+00
02c574fb-b58a-4321-8baf-b300a132a8f7	9	mcq_single	Nowcasting: sample question 1	\N	2	approved	llm	\N	\N	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2026-09-26 18:31:45.462661+00
ed36e338-f74f-493d-8c22-097cb87a5561	9	mcq_single	Nowcasting: sample question 2	\N	3	approved	llm	\N	\N	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2026-09-26 18:31:45.462661+00
5849b610-2faf-449f-9f02-9ddd26f0f7fe	9	mcq_single	Nowcasting: sample question 3	\N	4	approved	manual	\N	\N	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2026-09-26 18:31:45.462661+00
6e838f4e-b4b2-45be-8a0e-acb930a37d8a	9	mcq_single	Nowcasting: sample question 4	\N	1	approved	manual	\N	\N	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2026-09-26 18:31:45.462661+00
8a7ef50e-c059-4ae9-a120-f4b3456373a9	9	mcq_single	Nowcasting: sample question 5	\N	2	approved	manual	\N	\N	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2026-09-26 18:31:45.462661+00
afb23585-8bdd-497a-aa38-2d3c581b6769	12	mcq_single	Satellite Meteorology: sample question 1	\N	2	approved	llm	\N	\N	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2026-09-26 18:31:45.462661+00
57212654-5f73-4a37-96ec-b167f3fbeecf	12	mcq_single	Satellite Meteorology: sample question 2	\N	3	approved	llm	\N	\N	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2026-09-26 18:31:45.462661+00
4f6f917b-d616-4092-b0ac-39e53ad98de5	12	mcq_single	Satellite Meteorology: sample question 3	\N	4	approved	manual	\N	\N	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2026-09-26 18:31:45.462661+00
dbdf0ad2-cf95-4adb-ad09-b3a173932006	12	mcq_single	Satellite Meteorology: sample question 4	\N	1	approved	manual	\N	\N	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2026-09-26 18:31:45.462661+00
c9820e75-e39b-40d1-8c8d-4c06569123a2	12	mcq_single	Satellite Meteorology: sample question 5	\N	2	approved	manual	\N	\N	\N	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2026-09-26 18:31:45.462661+00
c2cd4463-9d41-425b-9393-fdb04cfe2f63	8	mcq_single	NWP Modelling: sample question 1	\N	2	approved	llm	\N	\N	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	dab8c835-d264-43fb-9b10-7482bacf6b99	2026-09-26 18:31:45.462661+00
41f43d5d-ac0b-4d2c-be8c-c0fe84c0acf9	8	mcq_single	NWP Modelling: sample question 2	\N	3	approved	llm	\N	\N	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	dab8c835-d264-43fb-9b10-7482bacf6b99	2026-09-26 18:31:45.462661+00
3384b0df-33e7-4505-bd23-eacbcd2af28f	8	mcq_single	NWP Modelling: sample question 3	\N	4	approved	manual	\N	\N	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	dab8c835-d264-43fb-9b10-7482bacf6b99	2026-09-26 18:31:45.462661+00
2f226e14-f34a-4af0-a013-9ba072e4b762	8	mcq_single	NWP Modelling: sample question 4	\N	1	approved	manual	\N	\N	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	dab8c835-d264-43fb-9b10-7482bacf6b99	2026-09-26 18:31:45.462661+00
f64aae7f-54a6-46b1-a387-17f1b728bfcd	8	mcq_single	NWP Modelling: sample question 5	\N	2	approved	manual	\N	\N	\N	dab8c835-d264-43fb-9b10-7482bacf6b99	dab8c835-d264-43fb-9b10-7482bacf6b99	2026-09-26 18:31:45.462661+00
805a4a40-b130-4825-ba2a-11b0d9d3b5ba	7	mcq_single	Tropical Cyclone Forecasting: sample question 1	\N	2	approved	llm	\N	\N	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2026-09-26 18:31:45.462661+00
182849cb-885c-4c10-bad7-6a0bda93b83f	7	mcq_single	Tropical Cyclone Forecasting: sample question 2	\N	3	approved	llm	\N	\N	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2026-09-26 18:31:45.462661+00
0ff32538-862f-4b19-b7d8-13cecbe3fbf4	7	mcq_single	Tropical Cyclone Forecasting: sample question 3	\N	4	approved	manual	\N	\N	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2026-09-26 18:31:45.462661+00
342ac555-702d-4419-a8a7-7d2659a8a005	7	mcq_single	Tropical Cyclone Forecasting: sample question 4	\N	1	approved	manual	\N	\N	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2026-09-26 18:31:45.462661+00
9e7cd74e-e5d7-4f5c-9237-7d64bfc72805	7	mcq_single	Tropical Cyclone Forecasting: sample question 5	\N	2	approved	manual	\N	\N	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2026-09-26 18:31:45.462661+00
22178d2a-1cb7-4729-8e22-fd6bc0061466	15	mcq_single	Climate Data Analysis: sample question 1	\N	2	approved	llm	\N	\N	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2026-09-26 18:31:45.462661+00
765a0d20-25ad-4f78-a6e4-3731681299c3	15	mcq_single	Climate Data Analysis: sample question 2	\N	3	approved	llm	\N	\N	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2026-09-26 18:31:45.462661+00
03c2877f-df89-4f46-9313-39b20f3140f3	15	mcq_single	Climate Data Analysis: sample question 3	\N	4	approved	manual	\N	\N	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2026-09-26 18:31:45.462661+00
df5aae4c-db9e-41cf-87be-26e716f5d1a4	15	mcq_single	Climate Data Analysis: sample question 4	\N	1	approved	manual	\N	\N	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2026-09-26 18:31:45.462661+00
efd59e02-686a-4701-8df4-72bdabb0841f	15	mcq_single	Climate Data Analysis: sample question 5	\N	2	approved	manual	\N	\N	\N	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	2026-09-26 18:31:45.462661+00
b7d6d94f-fe21-42a0-a6bf-d80cb2d9c64b	6	mcq_single	Monsoon Forecasting: sample question 1	\N	2	approved	llm	\N	\N	\N	d6196926-78e5-4750-9dda-c802473b00e2	d6196926-78e5-4750-9dda-c802473b00e2	2026-09-26 18:31:45.462661+00
cadb3ee0-9ede-4693-a848-f5ef3e0d9a7c	6	mcq_single	Monsoon Forecasting: sample question 2	\N	3	approved	llm	\N	\N	\N	d6196926-78e5-4750-9dda-c802473b00e2	d6196926-78e5-4750-9dda-c802473b00e2	2026-09-26 18:31:45.462661+00
65b16f63-c8df-4f6f-8002-36277e3305eb	6	mcq_single	Monsoon Forecasting: sample question 3	\N	4	approved	manual	\N	\N	\N	d6196926-78e5-4750-9dda-c802473b00e2	d6196926-78e5-4750-9dda-c802473b00e2	2026-09-26 18:31:45.462661+00
8fd56efa-7cfc-49b2-b76c-3215133153e7	6	mcq_single	Monsoon Forecasting: sample question 4	\N	1	approved	manual	\N	\N	\N	d6196926-78e5-4750-9dda-c802473b00e2	d6196926-78e5-4750-9dda-c802473b00e2	2026-09-26 18:31:45.462661+00
5a16fb16-0834-4820-9f46-8b9f73a4bcc7	6	mcq_single	Monsoon Forecasting: sample question 5	\N	2	approved	manual	\N	\N	\N	d6196926-78e5-4750-9dda-c802473b00e2	d6196926-78e5-4750-9dda-c802473b00e2	2026-09-26 18:31:45.462661+00
d0d39025-7813-433d-8583-ef5cf872a22b	13	mcq_single	Doppler Weather Radar: sample question 1	\N	2	approved	llm	\N	\N	\N	66a88386-7c29-44ae-805a-fd51d782743b	66a88386-7c29-44ae-805a-fd51d782743b	2026-09-26 18:31:45.462661+00
5b94a8c1-a147-4446-9c4c-45772a47bb34	13	mcq_single	Doppler Weather Radar: sample question 2	\N	3	approved	llm	\N	\N	\N	66a88386-7c29-44ae-805a-fd51d782743b	66a88386-7c29-44ae-805a-fd51d782743b	2026-09-26 18:31:45.462661+00
aedfe7ce-a52c-47a8-9443-fbc187c342b6	13	mcq_single	Doppler Weather Radar: sample question 3	\N	4	approved	manual	\N	\N	\N	66a88386-7c29-44ae-805a-fd51d782743b	66a88386-7c29-44ae-805a-fd51d782743b	2026-09-26 18:31:45.462661+00
b110754e-b4b2-4800-a273-fbc50d318c28	13	mcq_single	Doppler Weather Radar: sample question 4	\N	1	approved	manual	\N	\N	\N	66a88386-7c29-44ae-805a-fd51d782743b	66a88386-7c29-44ae-805a-fd51d782743b	2026-09-26 18:31:45.462661+00
1321f389-037b-4141-bae7-0a66b10b0575	13	mcq_single	Doppler Weather Radar: sample question 5	\N	2	approved	manual	\N	\N	\N	66a88386-7c29-44ae-805a-fd51d782743b	66a88386-7c29-44ae-805a-fd51d782743b	2026-09-26 18:31:45.462661+00
b090dc4b-837d-425c-b37b-be844cf627d7	18	mcq_single	Flood Meteorology: sample question 1	\N	2	approved	llm	\N	\N	\N	66a88386-7c29-44ae-805a-fd51d782743b	66a88386-7c29-44ae-805a-fd51d782743b	2026-09-26 18:31:45.462661+00
dc29bae1-e97b-4cc3-82b8-96a68ca1ad92	18	mcq_single	Flood Meteorology: sample question 2	\N	3	approved	llm	\N	\N	\N	66a88386-7c29-44ae-805a-fd51d782743b	66a88386-7c29-44ae-805a-fd51d782743b	2026-09-26 18:31:45.462661+00
90c7e828-24f0-4051-9573-68c31ebbe637	18	mcq_single	Flood Meteorology: sample question 3	\N	4	approved	manual	\N	\N	\N	66a88386-7c29-44ae-805a-fd51d782743b	66a88386-7c29-44ae-805a-fd51d782743b	2026-09-26 18:31:45.462661+00
8bf3f0ea-051d-4aad-b17c-5755ba6de07c	18	mcq_single	Flood Meteorology: sample question 4	\N	1	approved	manual	\N	\N	\N	66a88386-7c29-44ae-805a-fd51d782743b	66a88386-7c29-44ae-805a-fd51d782743b	2026-09-26 18:31:45.462661+00
4c251056-9802-490a-91a6-2c608fab3cfe	18	mcq_single	Flood Meteorology: sample question 5	\N	2	approved	manual	\N	\N	\N	66a88386-7c29-44ae-805a-fd51d782743b	66a88386-7c29-44ae-805a-fd51d782743b	2026-09-26 18:31:45.462661+00
acf60aee-d036-47ae-94e8-2023492c8494	12	mcq_single	Satellite Meteorology: sample question 1	\N	2	approved	llm	\N	\N	\N	49992467-6281-4454-9a23-aa2dd4c74a95	49992467-6281-4454-9a23-aa2dd4c74a95	2026-09-26 18:31:45.462661+00
fb2f7fc0-b18f-4012-a702-9d6edc655b81	12	mcq_single	Satellite Meteorology: sample question 2	\N	3	approved	llm	\N	\N	\N	49992467-6281-4454-9a23-aa2dd4c74a95	49992467-6281-4454-9a23-aa2dd4c74a95	2026-09-26 18:31:45.462661+00
1dca2d0a-1df3-4500-8ad0-c7ac7112cea0	12	mcq_single	Satellite Meteorology: sample question 3	\N	4	approved	manual	\N	\N	\N	49992467-6281-4454-9a23-aa2dd4c74a95	49992467-6281-4454-9a23-aa2dd4c74a95	2026-09-26 18:31:45.462661+00
0bf63b2b-d59e-4003-9b58-f86b5931b0f8	12	mcq_single	Satellite Meteorology: sample question 4	\N	1	approved	manual	\N	\N	\N	49992467-6281-4454-9a23-aa2dd4c74a95	49992467-6281-4454-9a23-aa2dd4c74a95	2026-09-26 18:31:45.462661+00
7edbf11b-b851-4b25-a20f-f6ce2ba9d387	12	mcq_single	Satellite Meteorology: sample question 5	\N	2	approved	manual	\N	\N	\N	49992467-6281-4454-9a23-aa2dd4c74a95	49992467-6281-4454-9a23-aa2dd4c74a95	2026-09-26 18:31:45.462661+00
f54ac6ae-d9c9-4269-83aa-c992f3cda491	17	mcq_single	Heatwave & Cold Wave: sample question 1	\N	2	approved	llm	\N	\N	\N	49992467-6281-4454-9a23-aa2dd4c74a95	49992467-6281-4454-9a23-aa2dd4c74a95	2026-09-26 18:31:45.462661+00
d1df1da4-4588-4f95-959f-82e0b8a4c6d0	17	mcq_single	Heatwave & Cold Wave: sample question 2	\N	3	approved	llm	\N	\N	\N	49992467-6281-4454-9a23-aa2dd4c74a95	49992467-6281-4454-9a23-aa2dd4c74a95	2026-09-26 18:31:45.462661+00
343442d5-4c8a-4b59-86ec-7b107b9cbc4c	17	mcq_single	Heatwave & Cold Wave: sample question 3	\N	4	approved	manual	\N	\N	\N	49992467-6281-4454-9a23-aa2dd4c74a95	49992467-6281-4454-9a23-aa2dd4c74a95	2026-09-26 18:31:45.462661+00
3932caed-6cbc-4e02-88c2-ac78a2709141	17	mcq_single	Heatwave & Cold Wave: sample question 4	\N	1	approved	manual	\N	\N	\N	49992467-6281-4454-9a23-aa2dd4c74a95	49992467-6281-4454-9a23-aa2dd4c74a95	2026-09-26 18:31:45.462661+00
21907a58-525f-49b6-ace8-83b80ff8db2c	17	mcq_single	Heatwave & Cold Wave: sample question 5	\N	2	approved	manual	\N	\N	\N	49992467-6281-4454-9a23-aa2dd4c74a95	49992467-6281-4454-9a23-aa2dd4c74a95	2026-09-26 18:31:45.462661+00
\.


--
-- Data for Name: skills; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.skills (id, name, slug, parent_id, description, keywords, embedding, is_active) FROM stdin;
1	Weather Forecasting	forecasting	\N	\N	{forecast,forecasting,synoptic}	\N	t
2	Observations & Instruments	observations	\N	\N	{observation,instrument,sensor}	\N	t
3	Climate Services	climate	\N	\N	{climate,climatology}	\N	t
4	Hydromet & Hazards	hazards	\N	\N	{hazard,disaster,warning}	\N	t
5	Data & IT Skills	data-it	\N	\N	{python,data,gis}	\N	t
6	Monsoon Forecasting	monsoon	1	\N	{monsoon,rainfall,"southwest monsoon",onset}	\N	t
7	Tropical Cyclone Forecasting	tropical-cyclone	1	\N	{cyclone,"tropical cyclone","storm surge",track}	\N	t
8	NWP Modelling	nwp	1	\N	{nwp,wrf,gfs,"numerical weather",ensemble,"data assimilation"}	\N	t
9	Nowcasting	nowcasting	1	\N	{nowcast,nowcasting,short-range,convective}	\N	t
10	Upper-Air Observations	upper-air	2	\N	{radiosonde,"upper air","pilot balloon"}	\N	t
11	Automatic Weather Stations	aws	2	\N	{aws,"automatic weather station","surface observation"}	\N	t
12	Satellite Meteorology	satellite	2	\N	{satellite,insat,"remote sensing",imagery}	\N	t
13	Doppler Weather Radar	dwr	2	\N	{radar,doppler,dwr,reflectivity}	\N	t
14	Agromet Advisory	agromet	3	\N	{agromet,agriculture,crop,advisory}	\N	t
15	Climate Data Analysis	climate-data	3	\N	{"climate data",trend,reanalysis,era5}	\N	t
16	Thunderstorm & Lightning	thunderstorm	4	\N	{thunderstorm,lightning,squall,hail}	\N	t
17	Heatwave & Cold Wave	heatwave	4	\N	{heatwave,"heat wave","cold wave",temperature}	\N	t
18	Flood Meteorology	flood-met	4	\N	{flood,hydrology,qpf,river}	\N	t
19	GIS & Mapping	gis	5	\N	{gis,qgis,mapping,shapefile}	\N	t
20	Python for Meteorology	python-met	5	\N	{python,xarray,metpy,netcdf}	\N	t
\.


--
-- Data for Name: trainer_competency_scores; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.trainer_competency_scores (trainer_id, skill_id, declared_proficiency, courses_taught, resources_uploaded, keyword_hits, attempts_count, feedback_count, tag_match, embedding_match, pass_rate, rating_score, experience_score, computed_at) FROM stdin;
2e42c806-48d6-422a-b282-2b30f0484c3c	1	\N	0	0	1	0	18	0.3417	\N	0.5000	0.4500	0.4458	2026-09-26 18:31:46.234084+00
2e42c806-48d6-422a-b282-2b30f0484c3c	2	\N	0	0	0	0	18	0.1100	\N	0.5000	0.4500	0.4458	2026-09-26 18:31:46.234084+00
2e42c806-48d6-422a-b282-2b30f0484c3c	9	5	1	2	4	23	18	1.0000	\N	0.2000	0.4500	0.5858	2026-09-26 18:31:46.234084+00
2e42c806-48d6-422a-b282-2b30f0484c3c	12	2	0	0	0	0	18	0.2200	\N	0.5000	0.4500	0.5508	2026-09-26 18:31:46.234084+00
ff73e90e-1654-4bfd-8c73-43ad75a07f21	1	\N	0	0	1	0	32	0.2867	\N	0.5000	0.7235	0.3208	2026-09-26 18:31:46.234084+00
ff73e90e-1654-4bfd-8c73-43ad75a07f21	2	\N	0	0	1	0	32	0.2317	\N	0.5000	0.7235	0.3208	2026-09-26 18:31:46.234084+00
ff73e90e-1654-4bfd-8c73-43ad75a07f21	8	4	1	2	6	23	32	0.8900	\N	0.9600	0.7235	0.8208	2026-09-26 18:31:46.234084+00
ff73e90e-1654-4bfd-8c73-43ad75a07f21	11	3	1	2	3	22	32	0.7800	\N	0.4167	0.7235	0.6108	2026-09-26 18:31:46.234084+00
ff38df49-9e3b-4df5-92a2-4852f8b79c74	1	\N	0	0	2	0	8	0.2983	\N	0.5000	0.5800	0.4938	2026-09-26 18:31:46.234084+00
ff38df49-9e3b-4df5-92a2-4852f8b79c74	3	\N	0	0	0	0	8	0.1100	\N	0.5000	0.5800	0.4938	2026-09-26 18:31:46.234084+00
ff38df49-9e3b-4df5-92a2-4852f8b79c74	7	3	1	2	4	21	8	0.7800	\N	0.4783	0.5800	0.7088	2026-09-26 18:31:46.234084+00
ff38df49-9e3b-4df5-92a2-4852f8b79c74	15	2	0	0	0	0	8	0.2200	\N	0.5000	0.5800	0.7638	2026-09-26 18:31:46.234084+00
2ae7d31a-ec05-402a-8104-ba433a1644eb	1	\N	0	0	2	0	14	0.3533	\N	0.5000	0.7750	0.1167	2026-09-26 18:31:46.234084+00
2ae7d31a-ec05-402a-8104-ba433a1644eb	3	\N	0	0	0	0	14	0.1100	\N	0.5000	0.7750	0.1167	2026-09-26 18:31:46.234084+00
2ae7d31a-ec05-402a-8104-ba433a1644eb	6	4	1	2	4	20	14	0.8900	\N	0.9091	0.7750	0.4067	2026-09-26 18:31:46.234084+00
2ae7d31a-ec05-402a-8104-ba433a1644eb	14	2	0	0	0	0	14	0.2200	\N	0.5000	0.7750	0.2817	2026-09-26 18:31:46.234084+00
5db62bba-e3f6-4551-81f7-9d9237055aa3	2	\N	0	0	0	0	22	0.2750	\N	0.5000	0.8500	0.5000	2026-09-26 18:31:46.234084+00
5db62bba-e3f6-4551-81f7-9d9237055aa3	4	\N	0	0	0	0	22	0.1100	\N	0.5000	0.8500	0.5000	2026-09-26 18:31:46.234084+00
5db62bba-e3f6-4551-81f7-9d9237055aa3	13	5	1	2	4	24	22	1.0000	\N	0.9231	0.8500	0.8150	2026-09-26 18:31:46.234084+00
5db62bba-e3f6-4551-81f7-9d9237055aa3	18	2	0	0	0	0	22	0.2200	\N	0.5000	0.8500	0.7100	2026-09-26 18:31:46.234084+00
9894043b-3b29-45e0-9abd-9b61597bf09a	2	\N	0	0	0	0	10	0.2200	\N	0.5000	0.6667	0.1771	2026-09-26 18:31:46.234084+00
9894043b-3b29-45e0-9abd-9b61597bf09a	4	\N	0	0	0	0	10	0.1100	\N	0.5000	0.6667	0.1771	2026-09-26 18:31:46.234084+00
9894043b-3b29-45e0-9abd-9b61597bf09a	12	4	1	2	4	17	10	0.8900	\N	0.4211	0.6667	0.5121	2026-09-26 18:31:46.234084+00
9894043b-3b29-45e0-9abd-9b61597bf09a	17	2	0	0	0	0	10	0.2200	\N	0.5000	0.6667	0.2571	2026-09-26 18:31:46.234084+00
bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	2	\N	0	0	1	0	26	0.3417	\N	0.5000	0.7786	0.5000	2026-09-26 18:31:46.234084+00
bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	4	\N	0	0	0	0	26	0.1650	\N	0.5000	0.7786	0.5000	2026-09-26 18:31:46.234084+00
bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	10	2	0	0	1	0	26	0.2867	\N	0.5000	0.7786	0.5500	2026-09-26 18:31:46.234084+00
bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	11	5	1	2	3	17	26	1.0000	\N	0.4211	0.7786	0.7100	2026-09-26 18:31:46.234084+00
bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	16	3	1	2	4	22	26	0.7800	\N	0.9583	0.7786	0.5550	2026-09-26 18:31:46.234084+00
4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	3	\N	0	0	1	0	12	0.3417	\N	0.5000	0.8571	0.1917	2026-09-26 18:31:46.234084+00
4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	5	\N	0	0	1	0	12	0.1767	\N	0.5000	0.8571	0.1917	2026-09-26 18:31:46.234084+00
4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	15	5	1	2	4	19	12	1.0000	\N	0.9524	0.8571	0.3017	2026-09-26 18:31:46.234084+00
4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	20	2	0	0	0	0	12	0.2200	\N	0.5000	0.8571	0.2717	2026-09-26 18:31:46.234084+00
954754ab-6ecc-4d9a-a614-8cc84ffb3348	1	\N	0	0	1	0	13	0.1767	\N	0.5000	0.8267	0.2313	2026-09-26 18:31:46.234084+00
954754ab-6ecc-4d9a-a614-8cc84ffb3348	3	\N	0	0	0	0	13	0.1650	\N	0.5000	0.8267	0.2313	2026-09-26 18:31:46.234084+00
954754ab-6ecc-4d9a-a614-8cc84ffb3348	9	2	0	0	0	0	13	0.2200	\N	0.5000	0.8267	0.3713	2026-09-26 18:31:46.234084+00
954754ab-6ecc-4d9a-a614-8cc84ffb3348	14	3	1	2	4	18	13	0.7800	\N	0.9500	0.8267	0.7313	2026-09-26 18:31:46.234084+00
62f1ad05-4a27-46cd-93f8-7a570f80f4f3	1	\N	0	0	1	0	25	0.2317	\N	0.5000	0.7111	0.3917	2026-09-26 18:31:46.234084+00
62f1ad05-4a27-46cd-93f8-7a570f80f4f3	4	\N	0	0	0	0	25	0.1650	\N	0.5000	0.7111	0.3917	2026-09-26 18:31:46.234084+00
62f1ad05-4a27-46cd-93f8-7a570f80f4f3	8	3	1	2	6	17	25	0.7800	\N	0.3684	0.7111	0.6317	2026-09-26 18:31:46.234084+00
62f1ad05-4a27-46cd-93f8-7a570f80f4f3	18	3	1	2	4	25	25	0.7800	\N	0.9630	0.7111	0.7917	2026-09-26 18:31:46.234084+00
e9178b69-2339-4a64-857f-5ad0630325a5	1	\N	0	0	1	0	16	0.1767	\N	0.5000	0.5889	0.3104	2026-09-26 18:31:46.234084+00
e9178b69-2339-4a64-857f-5ad0630325a5	4	\N	0	0	0	0	16	0.1650	\N	0.5000	0.5889	0.3104	2026-09-26 18:31:46.234084+00
e9178b69-2339-4a64-857f-5ad0630325a5	7	2	0	0	0	0	16	0.2200	\N	0.5000	0.5889	0.4504	2026-09-26 18:31:46.234084+00
e9178b69-2339-4a64-857f-5ad0630325a5	17	3	1	2	4	25	16	0.7800	\N	0.3333	0.5889	0.8104	2026-09-26 18:31:46.234084+00
82556fbd-47bf-44ac-aae9-3499c844ea75	1	\N	0	0	1	0	10	0.1767	\N	0.5000	0.5167	0.2083	2026-09-26 18:31:46.234084+00
82556fbd-47bf-44ac-aae9-3499c844ea75	4	\N	0	0	0	0	10	0.2750	\N	0.5000	0.5167	0.2083	2026-09-26 18:31:46.234084+00
82556fbd-47bf-44ac-aae9-3499c844ea75	6	2	0	0	0	0	10	0.2200	\N	0.5000	0.5167	0.3583	2026-09-26 18:31:46.234084+00
82556fbd-47bf-44ac-aae9-3499c844ea75	16	5	1	2	4	18	10	1.0000	\N	0.2500	0.5167	0.3733	2026-09-26 18:31:46.234084+00
fa5ba122-30c1-4e56-bc6b-b761794b1528	2	\N	0	0	0	0	13	0.1100	\N	0.5000	0.7867	0.5000	2026-09-26 18:31:46.234084+00
fa5ba122-30c1-4e56-bc6b-b761794b1528	5	\N	0	0	1	0	13	0.2867	\N	0.5000	0.7867	0.5000	2026-09-26 18:31:46.234084+00
fa5ba122-30c1-4e56-bc6b-b761794b1528	13	2	0	0	0	0	13	0.2200	\N	0.5000	0.7867	0.5900	2026-09-26 18:31:46.234084+00
fa5ba122-30c1-4e56-bc6b-b761794b1528	20	4	1	2	4	18	13	0.8900	\N	0.9500	0.7867	0.8000	2026-09-26 18:31:46.234084+00
cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	1	\N	0	0	1	0	21	0.3417	\N	0.5000	0.6261	0.2354	2026-09-26 18:31:46.234084+00
cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	2	\N	0	0	0	0	21	0.1650	\N	0.5000	0.6261	0.2354	2026-09-26 18:31:46.234084+00
cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	9	5	1	2	4	24	21	1.0000	\N	0.9615	0.6261	0.7204	2026-09-26 18:31:46.234084+00
cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	12	3	1	2	4	21	21	0.7800	\N	0.1739	0.6261	0.4354	2026-09-26 18:31:46.234084+00
dab8c835-d264-43fb-9b10-7482bacf6b99	1	\N	0	0	1	0	21	0.2867	\N	0.5000	0.8348	0.2063	2026-09-26 18:31:46.234084+00
dab8c835-d264-43fb-9b10-7482bacf6b99	2	\N	0	0	0	0	21	0.1100	\N	0.5000	0.8348	0.2063	2026-09-26 18:31:46.234084+00
dab8c835-d264-43fb-9b10-7482bacf6b99	8	4	1	2	6	22	21	0.8900	\N	0.9583	0.8348	0.6963	2026-09-26 18:31:46.234084+00
dab8c835-d264-43fb-9b10-7482bacf6b99	11	2	0	0	0	0	21	0.2200	\N	0.5000	0.8348	0.3763	2026-09-26 18:31:46.234084+00
a22b9cb3-9b82-4d48-a453-6deeb2e9f273	1	\N	0	0	2	0	31	0.2983	\N	0.5000	0.6364	0.5000	2026-09-26 18:31:46.234084+00
a22b9cb3-9b82-4d48-a453-6deeb2e9f273	3	\N	0	0	1	0	31	0.2317	\N	0.5000	0.6364	0.5000	2026-09-26 18:31:46.234084+00
a22b9cb3-9b82-4d48-a453-6deeb2e9f273	7	3	1	2	4	22	31	0.7800	\N	0.4583	0.6364	0.9950	2026-09-26 18:31:46.234084+00
a22b9cb3-9b82-4d48-a453-6deeb2e9f273	15	3	1	2	4	24	31	0.7800	\N	0.6923	0.6364	0.7400	2026-09-26 18:31:46.234084+00
d6196926-78e5-4750-9dda-c802473b00e2	1	\N	0	0	2	0	13	0.4083	\N	0.5000	0.7867	0.3625	2026-09-26 18:31:46.234084+00
d6196926-78e5-4750-9dda-c802473b00e2	3	\N	0	0	0	0	13	0.1100	\N	0.5000	0.7867	0.3625	2026-09-26 18:31:46.234084+00
d6196926-78e5-4750-9dda-c802473b00e2	6	5	1	2	4	20	13	1.0000	\N	0.9545	0.7867	0.5525	2026-09-26 18:31:46.234084+00
d6196926-78e5-4750-9dda-c802473b00e2	14	2	0	0	0	0	13	0.2200	\N	0.5000	0.7867	0.4475	2026-09-26 18:31:46.234084+00
66a88386-7c29-44ae-805a-fd51d782743b	2	\N	0	0	0	0	19	0.1650	\N	0.5000	0.6381	0.2250	2026-09-26 18:31:46.234084+00
66a88386-7c29-44ae-805a-fd51d782743b	4	\N	0	0	0	0	19	0.1650	\N	0.5000	0.6381	0.2250	2026-09-26 18:31:46.234084+00
66a88386-7c29-44ae-805a-fd51d782743b	13	3	1	2	4	14	19	0.7800	\N	0.6250	0.6381	0.6950	2026-09-26 18:31:46.234084+00
66a88386-7c29-44ae-805a-fd51d782743b	18	3	1	2	4	17	19	0.7800	\N	0.2632	0.6381	0.3650	2026-09-26 18:31:46.234084+00
49992467-6281-4454-9a23-aa2dd4c74a95	2	\N	0	0	0	0	27	0.2750	\N	0.5000	0.6690	0.5000	2026-09-26 18:31:46.234084+00
49992467-6281-4454-9a23-aa2dd4c74a95	4	\N	0	0	0	0	27	0.1650	\N	0.5000	0.6690	0.5000	2026-09-26 18:31:46.234084+00
49992467-6281-4454-9a23-aa2dd4c74a95	12	5	1	2	4	25	27	1.0000	\N	0.3333	0.6690	1.0000	2026-09-26 18:31:46.234084+00
49992467-6281-4454-9a23-aa2dd4c74a95	17	3	1	2	4	23	27	0.7800	\N	0.6800	0.6690	0.6050	2026-09-26 18:31:46.234084+00
006ddbd1-35cc-4010-9363-d8234dae479e	2	\N	0	0	1	0	0	0.3417	\N	0.5000	0.6000	0.2771	2026-09-26 18:31:46.234084+00
006ddbd1-35cc-4010-9363-d8234dae479e	4	\N	0	0	0	0	0	0.1650	\N	0.5000	0.6000	0.2771	2026-09-26 18:31:46.234084+00
006ddbd1-35cc-4010-9363-d8234dae479e	11	5	0	0	3	0	0	0.7500	\N	0.5000	0.6000	0.7121	2026-09-26 18:31:46.234084+00
006ddbd1-35cc-4010-9363-d8234dae479e	16	3	0	0	0	0	0	0.3300	\N	0.5000	0.6000	0.4721	2026-09-26 18:31:46.234084+00
a2e26d13-6f79-43d6-9749-2676a39be455	3	\N	0	0	1	0	0	0.3417	\N	0.5000	0.6000	0.4021	2026-09-26 18:31:46.234084+00
a2e26d13-6f79-43d6-9749-2676a39be455	5	\N	0	0	1	0	0	0.2317	\N	0.5000	0.6000	0.4021	2026-09-26 18:31:46.234084+00
a2e26d13-6f79-43d6-9749-2676a39be455	15	5	0	0	4	0	0	0.7500	\N	0.5000	0.6000	0.7871	2026-09-26 18:31:46.234084+00
a2e26d13-6f79-43d6-9749-2676a39be455	20	3	0	0	0	0	0	0.3300	\N	0.5000	0.6000	0.6071	2026-09-26 18:31:46.234084+00
e9f6bde5-9ab9-477d-8669-134bdc4ad9ed	1	\N	0	0	1	0	0	0.1767	\N	0.5000	0.6000	0.2938	2026-09-26 18:31:46.234084+00
e9f6bde5-9ab9-477d-8669-134bdc4ad9ed	3	\N	0	0	0	0	0	0.1650	\N	0.5000	0.6000	0.2938	2026-09-26 18:31:46.234084+00
e9f6bde5-9ab9-477d-8669-134bdc4ad9ed	9	2	0	0	0	0	0	0.2200	\N	0.5000	0.6000	0.4588	2026-09-26 18:31:46.234084+00
e9f6bde5-9ab9-477d-8669-134bdc4ad9ed	14	3	0	0	4	0	0	0.5300	\N	0.5000	0.6000	0.7938	2026-09-26 18:31:46.234084+00
9a3e7d30-cc90-4d84-8fad-fc7d979156c3	1	\N	0	0	1	0	0	0.2317	\N	0.5000	0.6000	0.3563	2026-09-26 18:31:46.234084+00
9a3e7d30-cc90-4d84-8fad-fc7d979156c3	4	\N	0	0	0	0	0	0.2750	\N	0.5000	0.6000	0.3563	2026-09-26 18:31:46.234084+00
9a3e7d30-cc90-4d84-8fad-fc7d979156c3	8	3	0	0	0	0	0	0.3300	\N	0.5000	0.6000	0.6013	2026-09-26 18:31:46.234084+00
9a3e7d30-cc90-4d84-8fad-fc7d979156c3	18	5	0	0	4	0	0	0.7500	\N	0.5000	0.6000	0.8563	2026-09-26 18:31:46.234084+00
7108643a-28fb-4548-8b93-ed349eab59f3	1	\N	0	0	1	0	0	0.2317	\N	0.5000	0.6000	0.1688	2026-09-26 18:31:46.234084+00
7108643a-28fb-4548-8b93-ed349eab59f3	4	\N	0	0	0	0	0	0.2200	\N	0.5000	0.6000	0.1688	2026-09-26 18:31:46.234084+00
7108643a-28fb-4548-8b93-ed349eab59f3	7	3	0	0	0	0	0	0.3300	\N	0.5000	0.6000	0.3888	2026-09-26 18:31:46.234084+00
7108643a-28fb-4548-8b93-ed349eab59f3	17	4	0	0	4	0	0	0.6400	\N	0.5000	0.6000	0.6688	2026-09-26 18:31:46.234084+00
39496ad1-eecc-4826-8899-1dc4f0d96f73	1	\N	0	0	1	0	0	0.1767	\N	0.5000	0.6000	0.3833	2026-09-26 18:31:46.234084+00
39496ad1-eecc-4826-8899-1dc4f0d96f73	4	\N	0	0	0	0	0	0.2750	\N	0.5000	0.6000	0.3833	2026-09-26 18:31:46.234084+00
39496ad1-eecc-4826-8899-1dc4f0d96f73	6	2	0	0	0	0	0	0.2200	\N	0.5000	0.6000	0.6583	2026-09-26 18:31:46.234084+00
39496ad1-eecc-4826-8899-1dc4f0d96f73	16	5	0	0	4	0	0	0.7500	\N	0.5000	0.6000	0.8833	2026-09-26 18:31:46.234084+00
87214765-f9ce-468a-a0f1-98e208a690ec	2	\N	0	0	0	0	0	0.1650	\N	0.5000	0.6000	0.5000	2026-09-26 18:31:46.234084+00
87214765-f9ce-468a-a0f1-98e208a690ec	5	\N	0	0	1	0	0	0.2867	\N	0.5000	0.6000	0.5000	2026-09-26 18:31:46.234084+00
87214765-f9ce-468a-a0f1-98e208a690ec	13	3	0	0	0	0	0	0.3300	\N	0.5000	0.6000	0.6800	2026-09-26 18:31:46.234084+00
87214765-f9ce-468a-a0f1-98e208a690ec	20	4	0	0	4	0	0	0.6400	\N	0.5000	0.6000	0.8600	2026-09-26 18:31:46.234084+00
bb9ed2a7-08bf-40bf-9125-220f11e3b138	1	\N	0	0	1	0	0	0.2867	\N	0.5000	0.6000	0.5000	2026-09-26 18:31:46.234084+00
bb9ed2a7-08bf-40bf-9125-220f11e3b138	2	\N	0	0	0	0	0	0.1100	\N	0.5000	0.6000	0.5000	2026-09-26 18:31:46.234084+00
bb9ed2a7-08bf-40bf-9125-220f11e3b138	9	4	0	0	4	0	0	0.6400	\N	0.5000	0.6000	0.9800	2026-09-26 18:31:46.234084+00
bb9ed2a7-08bf-40bf-9125-220f11e3b138	12	2	0	0	0	0	0	0.2200	\N	0.5000	0.6000	0.6550	2026-09-26 18:31:46.234084+00
2042a866-172d-42f9-96e4-7dc22771dc04	1	\N	0	0	1	0	0	0.2317	\N	0.5000	0.6000	0.4604	2026-09-26 18:31:46.234084+00
2042a866-172d-42f9-96e4-7dc22771dc04	2	\N	0	0	0	0	0	0.1100	\N	0.5000	0.6000	0.4604	2026-09-26 18:31:46.234084+00
2042a866-172d-42f9-96e4-7dc22771dc04	8	3	0	0	6	0	0	0.5300	\N	0.5000	0.6000	0.8004	2026-09-26 18:31:46.234084+00
2042a866-172d-42f9-96e4-7dc22771dc04	11	2	0	0	0	0	0	0.2200	\N	0.5000	0.6000	0.6204	2026-09-26 18:31:46.234084+00
7102ca49-b74d-4460-847e-ce4e91f8c048	1	\N	0	0	2	0	0	0.4083	\N	0.5000	0.6000	0.2833	2026-09-26 18:31:46.234084+00
7102ca49-b74d-4460-847e-ce4e91f8c048	3	\N	0	0	0	0	0	0.1100	\N	0.5000	0.6000	0.2833	2026-09-26 18:31:46.234084+00
7102ca49-b74d-4460-847e-ce4e91f8c048	7	5	0	0	4	0	0	0.7500	\N	0.5000	0.6000	0.4533	2026-09-26 18:31:46.234084+00
7102ca49-b74d-4460-847e-ce4e91f8c048	15	2	0	0	0	0	0	0.2200	\N	0.5000	0.6000	0.4733	2026-09-26 18:31:46.234084+00
798470a9-6675-4483-8cd4-d1af4302c5af	1	\N	0	0	2	0	0	0.3533	\N	0.5000	0.6000	0.5000	2026-09-26 18:31:46.234084+00
798470a9-6675-4483-8cd4-d1af4302c5af	3	\N	0	0	0	0	0	0.1650	\N	0.5000	0.6000	0.5000	2026-09-26 18:31:46.234084+00
798470a9-6675-4483-8cd4-d1af4302c5af	6	4	0	0	4	0	0	0.6400	\N	0.5000	0.6000	1.0000	2026-09-26 18:31:46.234084+00
798470a9-6675-4483-8cd4-d1af4302c5af	14	3	0	0	0	0	0	0.3300	\N	0.5000	0.6000	0.7400	2026-09-26 18:31:46.234084+00
\.


--
-- Data for Name: user_skills; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.user_skills (user_id, skill_id, kind, proficiency, years, source, updated_at) FROM stdin;
2e42c806-48d6-422a-b282-2b30f0484c3c	9	skill	5	2.8	admin_verified	2026-09-26 18:31:45.462661+00
2e42c806-48d6-422a-b282-2b30f0484c3c	12	skill	2	2.1	self_declared	2026-09-26 18:31:45.462661+00
ff73e90e-1654-4bfd-8c73-43ad75a07f21	8	skill	4	11.0	admin_verified	2026-09-26 18:31:45.462661+00
ff73e90e-1654-4bfd-8c73-43ad75a07f21	11	skill	3	5.8	self_declared	2026-09-26 18:31:45.462661+00
ff38df49-9e3b-4df5-92a2-4852f8b79c74	7	skill	3	4.3	admin_verified	2026-09-26 18:31:45.462661+00
ff38df49-9e3b-4df5-92a2-4852f8b79c74	15	skill	2	5.4	self_declared	2026-09-26 18:31:45.462661+00
2ae7d31a-ec05-402a-8104-ba433a1644eb	6	skill	4	5.8	admin_verified	2026-09-26 18:31:45.462661+00
2ae7d31a-ec05-402a-8104-ba433a1644eb	14	skill	2	3.3	self_declared	2026-09-26 18:31:45.462661+00
5db62bba-e3f6-4551-81f7-9d9237055aa3	13	skill	5	6.3	admin_verified	2026-09-26 18:31:45.462661+00
5db62bba-e3f6-4551-81f7-9d9237055aa3	18	skill	2	4.2	self_declared	2026-09-26 18:31:45.462661+00
9894043b-3b29-45e0-9abd-9b61597bf09a	12	skill	4	6.7	admin_verified	2026-09-26 18:31:45.462661+00
9894043b-3b29-45e0-9abd-9b61597bf09a	17	skill	2	1.6	self_declared	2026-09-26 18:31:45.462661+00
bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	11	skill	5	4.2	admin_verified	2026-09-26 18:31:45.462661+00
bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	16	skill	3	1.1	self_declared	2026-09-26 18:31:45.462661+00
4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	15	skill	5	2.2	admin_verified	2026-09-26 18:31:45.462661+00
4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	20	skill	2	1.6	self_declared	2026-09-26 18:31:45.462661+00
954754ab-6ecc-4d9a-a614-8cc84ffb3348	14	skill	3	13.3	admin_verified	2026-09-26 18:31:45.462661+00
954754ab-6ecc-4d9a-a614-8cc84ffb3348	9	skill	2	2.8	self_declared	2026-09-26 18:31:45.462661+00
62f1ad05-4a27-46cd-93f8-7a570f80f4f3	18	skill	3	8.0	admin_verified	2026-09-26 18:31:45.462661+00
62f1ad05-4a27-46cd-93f8-7a570f80f4f3	8	skill	3	4.8	self_declared	2026-09-26 18:31:45.462661+00
e9178b69-2339-4a64-857f-5ad0630325a5	17	skill	3	12.7	admin_verified	2026-09-26 18:31:45.462661+00
e9178b69-2339-4a64-857f-5ad0630325a5	7	skill	2	2.8	self_declared	2026-09-26 18:31:45.462661+00
82556fbd-47bf-44ac-aae9-3499c844ea75	16	skill	5	3.3	admin_verified	2026-09-26 18:31:45.462661+00
82556fbd-47bf-44ac-aae9-3499c844ea75	6	skill	2	3.0	self_declared	2026-09-26 18:31:45.462661+00
fa5ba122-30c1-4e56-bc6b-b761794b1528	20	skill	4	6.0	admin_verified	2026-09-26 18:31:45.462661+00
fa5ba122-30c1-4e56-bc6b-b761794b1528	13	skill	2	1.8	self_declared	2026-09-26 18:31:45.462661+00
cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	9	skill	5	9.7	admin_verified	2026-09-26 18:31:45.462661+00
cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	12	skill	3	4.0	self_declared	2026-09-26 18:31:45.462661+00
dab8c835-d264-43fb-9b10-7482bacf6b99	8	skill	4	9.8	admin_verified	2026-09-26 18:31:45.462661+00
dab8c835-d264-43fb-9b10-7482bacf6b99	11	skill	2	3.4	self_declared	2026-09-26 18:31:45.462661+00
a22b9cb3-9b82-4d48-a453-6deeb2e9f273	7	skill	3	9.9	admin_verified	2026-09-26 18:31:45.462661+00
a22b9cb3-9b82-4d48-a453-6deeb2e9f273	15	skill	3	4.8	self_declared	2026-09-26 18:31:45.462661+00
d6196926-78e5-4750-9dda-c802473b00e2	6	skill	5	3.8	admin_verified	2026-09-26 18:31:45.462661+00
d6196926-78e5-4750-9dda-c802473b00e2	14	skill	2	1.7	self_declared	2026-09-26 18:31:45.462661+00
66a88386-7c29-44ae-805a-fd51d782743b	13	skill	3	9.4	admin_verified	2026-09-26 18:31:45.462661+00
66a88386-7c29-44ae-805a-fd51d782743b	18	skill	3	2.8	self_declared	2026-09-26 18:31:45.462661+00
49992467-6281-4454-9a23-aa2dd4c74a95	12	skill	5	13.3	admin_verified	2026-09-26 18:31:45.462661+00
49992467-6281-4454-9a23-aa2dd4c74a95	17	skill	3	2.1	self_declared	2026-09-26 18:31:45.462661+00
006ddbd1-35cc-4010-9363-d8234dae479e	11	skill	5	8.7	admin_verified	2026-09-26 18:31:45.462661+00
006ddbd1-35cc-4010-9363-d8234dae479e	16	skill	3	3.9	self_declared	2026-09-26 18:31:45.462661+00
a2e26d13-6f79-43d6-9749-2676a39be455	15	skill	5	7.7	admin_verified	2026-09-26 18:31:45.462661+00
a2e26d13-6f79-43d6-9749-2676a39be455	20	skill	3	4.1	self_declared	2026-09-26 18:31:45.462661+00
e9f6bde5-9ab9-477d-8669-134bdc4ad9ed	14	skill	3	14.0	admin_verified	2026-09-26 18:31:45.462661+00
e9f6bde5-9ab9-477d-8669-134bdc4ad9ed	9	skill	2	3.3	self_declared	2026-09-26 18:31:45.462661+00
9a3e7d30-cc90-4d84-8fad-fc7d979156c3	18	skill	5	12.5	admin_verified	2026-09-26 18:31:45.462661+00
9a3e7d30-cc90-4d84-8fad-fc7d979156c3	8	skill	3	4.9	self_declared	2026-09-26 18:31:45.462661+00
7108643a-28fb-4548-8b93-ed349eab59f3	17	skill	4	14.0	admin_verified	2026-09-26 18:31:45.462661+00
7108643a-28fb-4548-8b93-ed349eab59f3	7	skill	3	4.4	self_declared	2026-09-26 18:31:45.462661+00
39496ad1-eecc-4826-8899-1dc4f0d96f73	16	skill	5	13.0	admin_verified	2026-09-26 18:31:45.462661+00
39496ad1-eecc-4826-8899-1dc4f0d96f73	6	skill	2	5.5	self_declared	2026-09-26 18:31:45.462661+00
87214765-f9ce-468a-a0f1-98e208a690ec	20	skill	4	7.2	admin_verified	2026-09-26 18:31:45.462661+00
87214765-f9ce-468a-a0f1-98e208a690ec	13	skill	3	3.6	self_declared	2026-09-26 18:31:45.462661+00
bb9ed2a7-08bf-40bf-9125-220f11e3b138	9	skill	4	9.6	admin_verified	2026-09-26 18:31:45.462661+00
bb9ed2a7-08bf-40bf-9125-220f11e3b138	12	skill	2	3.1	self_declared	2026-09-26 18:31:45.462661+00
2042a866-172d-42f9-96e4-7dc22771dc04	8	skill	3	6.8	admin_verified	2026-09-26 18:31:45.462661+00
2042a866-172d-42f9-96e4-7dc22771dc04	11	skill	2	3.2	self_declared	2026-09-26 18:31:45.462661+00
7102ca49-b74d-4460-847e-ce4e91f8c048	7	skill	5	3.4	admin_verified	2026-09-26 18:31:45.462661+00
7102ca49-b74d-4460-847e-ce4e91f8c048	15	skill	2	3.8	self_declared	2026-09-26 18:31:45.462661+00
798470a9-6675-4483-8cd4-d1af4302c5af	6	skill	4	11.9	admin_verified	2026-09-26 18:31:45.462661+00
798470a9-6675-4483-8cd4-d1af4302c5af	14	skill	3	4.8	self_declared	2026-09-26 18:31:45.462661+00
bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	10	skill	2	1.0	self_declared	2026-09-26 18:31:45.462661+00
78313b75-0494-43a4-b199-ff1928254f44	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
78313b75-0494-43a4-b199-ff1928254f44	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
43e91850-0b48-4bcd-be9d-c38742b91841	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
43e91850-0b48-4bcd-be9d-c38742b91841	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
72a5ceb8-6b68-433d-9b99-d62b8c9f1375	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
72a5ceb8-6b68-433d-9b99-d62b8c9f1375	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2e35b549-e1b5-4e61-a221-b0799208258c	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2e35b549-e1b5-4e61-a221-b0799208258c	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2e35b549-e1b5-4e61-a221-b0799208258c	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2e35b549-e1b5-4e61-a221-b0799208258c	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f8db984c-e990-4ead-b69f-74d50fa951dc	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f8db984c-e990-4ead-b69f-74d50fa951dc	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7f53c53d-3323-4146-8cea-01d6c38b4f77	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7f53c53d-3323-4146-8cea-01d6c38b4f77	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3e1e22ae-3497-44dc-bb66-1a3c24a5af91	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3e1e22ae-3497-44dc-bb66-1a3c24a5af91	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fbc637df-19cd-4ec5-b08d-49ce15747076	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fbc637df-19cd-4ec5-b08d-49ce15747076	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fbc637df-19cd-4ec5-b08d-49ce15747076	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fbc637df-19cd-4ec5-b08d-49ce15747076	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7b68a9ad-6ab1-4164-89e4-b13eea948a92	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7b68a9ad-6ab1-4164-89e4-b13eea948a92	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6f1d6dd6-daa9-4660-a06f-527bf32f663e	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6f1d6dd6-daa9-4660-a06f-527bf32f663e	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fc08ec35-be50-46ec-8acb-0ddb68b16b22	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fc08ec35-be50-46ec-8acb-0ddb68b16b22	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2731bad6-8e73-4106-8def-3df5df76b6ea	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2731bad6-8e73-4106-8def-3df5df76b6ea	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2731bad6-8e73-4106-8def-3df5df76b6ea	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2731bad6-8e73-4106-8def-3df5df76b6ea	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ab65843a-c349-4b21-b43b-9302ed8231b4	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ab65843a-c349-4b21-b43b-9302ed8231b4	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ab903484-298e-4415-93b0-8f5ea844bf31	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ab903484-298e-4415-93b0-8f5ea844bf31	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9389e5a2-816f-4e52-950b-a9af117c7ad1	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9389e5a2-816f-4e52-950b-a9af117c7ad1	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
602031bb-35f7-4efc-9f2c-f0bcf7d5ef3b	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
602031bb-35f7-4efc-9f2c-f0bcf7d5ef3b	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
602031bb-35f7-4efc-9f2c-f0bcf7d5ef3b	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
602031bb-35f7-4efc-9f2c-f0bcf7d5ef3b	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b28e0245-9390-4127-ad3f-80ace4775f43	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b28e0245-9390-4127-ad3f-80ace4775f43	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3d04f1c2-2486-4f53-bde5-76ba389ec266	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3d04f1c2-2486-4f53-bde5-76ba389ec266	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2af59a77-c993-46c3-a686-b91217814d48	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2af59a77-c993-46c3-a686-b91217814d48	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c43722c6-7e70-49e0-acb4-ba4f953e36a8	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c43722c6-7e70-49e0-acb4-ba4f953e36a8	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c43722c6-7e70-49e0-acb4-ba4f953e36a8	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c43722c6-7e70-49e0-acb4-ba4f953e36a8	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7b1099fc-7596-4be6-9ab4-990d535c39a5	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7b1099fc-7596-4be6-9ab4-990d535c39a5	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
732e74cf-b9b7-4adc-a43a-794430d7fe49	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
732e74cf-b9b7-4adc-a43a-794430d7fe49	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
48f33e15-f87f-4629-ab82-4123ada4bdc4	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
48f33e15-f87f-4629-ab82-4123ada4bdc4	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3af00a36-1f7b-4846-a52a-b1871416c5b1	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3af00a36-1f7b-4846-a52a-b1871416c5b1	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3af00a36-1f7b-4846-a52a-b1871416c5b1	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7acc259e-1231-481b-ab79-59821fd46534	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7acc259e-1231-481b-ab79-59821fd46534	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
05a922f4-7a9b-427c-bd4f-34ee3bdcfcf6	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
05a922f4-7a9b-427c-bd4f-34ee3bdcfcf6	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
286bd41d-35d4-4b43-b05b-8548dab978ab	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
286bd41d-35d4-4b43-b05b-8548dab978ab	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
1eb0cec9-a12f-4f42-9d77-bf6e343e9a75	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
1eb0cec9-a12f-4f42-9d77-bf6e343e9a75	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f51dbbc6-5c8a-487d-b785-786417797dc8	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f51dbbc6-5c8a-487d-b785-786417797dc8	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
562af427-bd16-4c30-940b-5d6121d738c8	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
562af427-bd16-4c30-940b-5d6121d738c8	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
696886f6-a4bf-44a6-9ba9-c939abb52137	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
696886f6-a4bf-44a6-9ba9-c939abb52137	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
696886f6-a4bf-44a6-9ba9-c939abb52137	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
696886f6-a4bf-44a6-9ba9-c939abb52137	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a4e9e21f-10e4-4c84-b4d0-9f420cf171c0	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a4e9e21f-10e4-4c84-b4d0-9f420cf171c0	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b8541832-74c6-404f-90d0-5fb6d3df7663	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b8541832-74c6-404f-90d0-5fb6d3df7663	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7e426fed-4c2e-46f4-866a-7b8aa048cf06	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7e426fed-4c2e-46f4-866a-7b8aa048cf06	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9bab5f84-a53e-49d6-91f8-eef87bf5960c	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9bab5f84-a53e-49d6-91f8-eef87bf5960c	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9bab5f84-a53e-49d6-91f8-eef87bf5960c	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9bab5f84-a53e-49d6-91f8-eef87bf5960c	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
202e1651-21c8-45c8-80d1-f326b27aec05	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
202e1651-21c8-45c8-80d1-f326b27aec05	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
28fe79f0-6207-4e0c-8bae-1eb02eed759b	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
28fe79f0-6207-4e0c-8bae-1eb02eed759b	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
dbccc807-eaba-41f6-aabc-14c515010185	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
dbccc807-eaba-41f6-aabc-14c515010185	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3ded69a7-290c-47f6-bd29-7369f6f8e3c8	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3ded69a7-290c-47f6-bd29-7369f6f8e3c8	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
48ae8c9d-e783-46c2-abf3-cc9d31e16d81	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
48ae8c9d-e783-46c2-abf3-cc9d31e16d81	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
350093ae-4f68-46a9-a0af-c33a9b87c340	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
350093ae-4f68-46a9-a0af-c33a9b87c340	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a596803e-b844-4f79-9db8-48d4b3d5abb7	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a596803e-b844-4f79-9db8-48d4b3d5abb7	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a596803e-b844-4f79-9db8-48d4b3d5abb7	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a596803e-b844-4f79-9db8-48d4b3d5abb7	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
24cbfa5b-7114-43b8-957c-fe0efa420c25	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
24cbfa5b-7114-43b8-957c-fe0efa420c25	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f74aaa72-56ba-476d-9aed-ffbe2e41dd50	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f74aaa72-56ba-476d-9aed-ffbe2e41dd50	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
69f12a27-893c-4791-987c-14fb10cbede4	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
69f12a27-893c-4791-987c-14fb10cbede4	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a17abc66-209e-405f-bcd6-c39e54cbce66	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a17abc66-209e-405f-bcd6-c39e54cbce66	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a17abc66-209e-405f-bcd6-c39e54cbce66	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a17abc66-209e-405f-bcd6-c39e54cbce66	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
cbd81a81-1d5a-4273-8494-11efdd5fd354	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
cbd81a81-1d5a-4273-8494-11efdd5fd354	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
d05292f5-3e9f-4e51-bb50-05a6534dc9b8	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
d05292f5-3e9f-4e51-bb50-05a6534dc9b8	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ea8fa5c6-6833-4701-9073-dd4ff3f78cb8	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ea8fa5c6-6833-4701-9073-dd4ff3f78cb8	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
4ace2ecd-317e-494c-ad50-71e2794fb907	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
4ace2ecd-317e-494c-ad50-71e2794fb907	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
4ace2ecd-317e-494c-ad50-71e2794fb907	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
4ace2ecd-317e-494c-ad50-71e2794fb907	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
d22f23cf-8a58-499a-8dba-92806f1622ef	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
d22f23cf-8a58-499a-8dba-92806f1622ef	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
8ffbd0cf-b807-4193-af37-3a61482c76eb	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
8ffbd0cf-b807-4193-af37-3a61482c76eb	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
bea31be8-3a44-4869-9c56-dce2da936f51	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
bea31be8-3a44-4869-9c56-dce2da936f51	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3d87692f-06c1-4403-95ff-c70d1598700a	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3d87692f-06c1-4403-95ff-c70d1598700a	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3d87692f-06c1-4403-95ff-c70d1598700a	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3d87692f-06c1-4403-95ff-c70d1598700a	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
60e67627-9116-4358-a94b-89c0416805f0	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
60e67627-9116-4358-a94b-89c0416805f0	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3b6030a2-3993-4389-8c6c-d3427e0e680b	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3b6030a2-3993-4389-8c6c-d3427e0e680b	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f75210c9-faa1-45c8-9314-a65724983502	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f75210c9-faa1-45c8-9314-a65724983502	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
306af47d-26b6-4dc3-96ae-eb178609c1f6	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
306af47d-26b6-4dc3-96ae-eb178609c1f6	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
306af47d-26b6-4dc3-96ae-eb178609c1f6	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
306af47d-26b6-4dc3-96ae-eb178609c1f6	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
0f80298a-f569-4c55-88aa-a57625e20751	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
0f80298a-f569-4c55-88aa-a57625e20751	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
0d37acee-70ea-4604-8bd7-c995941443fd	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
0d37acee-70ea-4604-8bd7-c995941443fd	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b2c7b829-9669-4258-ab45-acc4445b9d6d	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b2c7b829-9669-4258-ab45-acc4445b9d6d	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
333f633a-a466-43e6-9c02-cf743b327694	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
333f633a-a466-43e6-9c02-cf743b327694	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
333f633a-a466-43e6-9c02-cf743b327694	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5d9905c7-91e8-4bd9-b187-b1b8772e0f63	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5d9905c7-91e8-4bd9-b187-b1b8772e0f63	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b010ad34-1872-4015-9120-b4d6e175bda3	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b010ad34-1872-4015-9120-b4d6e175bda3	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
4d5fd264-452f-4436-8eca-5c6c62afb143	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
4d5fd264-452f-4436-8eca-5c6c62afb143	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9b9ade46-b30d-4a4c-ba6c-a66c454125e3	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9b9ade46-b30d-4a4c-ba6c-a66c454125e3	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fafec148-becc-4918-b1e0-08794a94f6de	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fafec148-becc-4918-b1e0-08794a94f6de	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
bd78a83d-5740-4d0d-9000-cdf29d332f27	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
bd78a83d-5740-4d0d-9000-cdf29d332f27	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
76e808de-304b-44e5-b793-8516b5fec7bb	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
76e808de-304b-44e5-b793-8516b5fec7bb	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
76e808de-304b-44e5-b793-8516b5fec7bb	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
76e808de-304b-44e5-b793-8516b5fec7bb	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
65ef229b-117d-4946-b5bb-301e3f828fc2	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
65ef229b-117d-4946-b5bb-301e3f828fc2	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
17231857-2d57-46f3-aecc-cb26a0865adb	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
17231857-2d57-46f3-aecc-cb26a0865adb	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6a389990-e259-43a4-a9a2-7575b00029e0	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6a389990-e259-43a4-a9a2-7575b00029e0	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a6afe850-9547-4fac-892c-00558ad8f725	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a6afe850-9547-4fac-892c-00558ad8f725	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a6afe850-9547-4fac-892c-00558ad8f725	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a6afe850-9547-4fac-892c-00558ad8f725	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2d970758-319c-400f-b2ba-93057f16a33e	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2d970758-319c-400f-b2ba-93057f16a33e	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
77c70aa0-ddd9-4445-be30-4817de1cbfd0	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
77c70aa0-ddd9-4445-be30-4817de1cbfd0	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a5102b13-4107-4fe5-b7a0-064dd07042ee	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a5102b13-4107-4fe5-b7a0-064dd07042ee	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5a97c9d9-87c7-445c-9dc8-860fb29edb16	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5a97c9d9-87c7-445c-9dc8-860fb29edb16	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5a97c9d9-87c7-445c-9dc8-860fb29edb16	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6cf3f90d-5b2f-422b-98a5-3df74a5bcbad	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6cf3f90d-5b2f-422b-98a5-3df74a5bcbad	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3a18a01e-89f7-474e-abf1-964581203793	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3a18a01e-89f7-474e-abf1-964581203793	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f15de25e-7244-417b-a4b1-83fe58cb8cd8	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f15de25e-7244-417b-a4b1-83fe58cb8cd8	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5abfd2bf-a622-4ac2-8867-2be6525ec0e8	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5abfd2bf-a622-4ac2-8867-2be6525ec0e8	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5abfd2bf-a622-4ac2-8867-2be6525ec0e8	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5abfd2bf-a622-4ac2-8867-2be6525ec0e8	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
8a0a7128-e6e6-4b49-8395-52723dda0b7c	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
8a0a7128-e6e6-4b49-8395-52723dda0b7c	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
09cc88c9-6251-413b-9873-df6f5bb8b24d	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
09cc88c9-6251-413b-9873-df6f5bb8b24d	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
e888ad9f-c064-4d24-8143-eec67fac7c1c	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
e888ad9f-c064-4d24-8143-eec67fac7c1c	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
e888ad9f-c064-4d24-8143-eec67fac7c1c	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
e888ad9f-c064-4d24-8143-eec67fac7c1c	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
0369edbf-d1ba-47c9-b17c-e67c29bf27fc	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
0369edbf-d1ba-47c9-b17c-e67c29bf27fc	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fed72080-2568-4892-8047-0b3c72ff7fad	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fed72080-2568-4892-8047-0b3c72ff7fad	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6ec3f843-359c-4b5b-bc41-b3bd56c6e134	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6ec3f843-359c-4b5b-bc41-b3bd56c6e134	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
90a570b4-9441-4d8b-981d-a7fa379054d3	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
90a570b4-9441-4d8b-981d-a7fa379054d3	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
90a570b4-9441-4d8b-981d-a7fa379054d3	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a7bae3c0-0e2c-42db-8e35-79114d5dfe80	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a7bae3c0-0e2c-42db-8e35-79114d5dfe80	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
357f9f29-063f-4ff8-bdc9-6df1d8cb15b4	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
357f9f29-063f-4ff8-bdc9-6df1d8cb15b4	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c2900748-9036-4804-b4f0-feb22ac5b4fb	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c2900748-9036-4804-b4f0-feb22ac5b4fb	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
152f1a01-df4b-4828-bf72-c1616f324c38	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
152f1a01-df4b-4828-bf72-c1616f324c38	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
152f1a01-df4b-4828-bf72-c1616f324c38	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
08758984-558b-4323-bc35-2a202203d87b	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
08758984-558b-4323-bc35-2a202203d87b	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
1e418187-2717-4b94-934c-e5ca025993d8	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
1e418187-2717-4b94-934c-e5ca025993d8	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
db9ec5a1-d0be-490d-91a6-bf32127bba75	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
db9ec5a1-d0be-490d-91a6-bf32127bba75	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
db9ec5a1-d0be-490d-91a6-bf32127bba75	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
db9ec5a1-d0be-490d-91a6-bf32127bba75	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f32344cc-9180-4953-b2cd-ba0f4bdb2eea	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f32344cc-9180-4953-b2cd-ba0f4bdb2eea	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
cc9e83f0-d177-4454-8ba5-f7581c6da639	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
cc9e83f0-d177-4454-8ba5-f7581c6da639	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a8c5b60b-8763-4325-900d-07d7540e6015	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a8c5b60b-8763-4325-900d-07d7540e6015	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a8c5b60b-8763-4325-900d-07d7540e6015	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6f3917b0-87b7-417f-a382-c38278a3d485	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6f3917b0-87b7-417f-a382-c38278a3d485	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
eee6bbaa-75eb-44f4-9892-d46194b720a9	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
eee6bbaa-75eb-44f4-9892-d46194b720a9	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ae420db9-d867-40d1-8d1a-01ee5d62e270	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ae420db9-d867-40d1-8d1a-01ee5d62e270	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
edc1993b-5333-4d99-bae2-9e80266978e0	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
edc1993b-5333-4d99-bae2-9e80266978e0	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
707e086b-3312-442d-ac6d-9776ebe73deb	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
707e086b-3312-442d-ac6d-9776ebe73deb	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f1bc49b2-13bf-4cd2-a5ac-6aa2c12e8f95	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f1bc49b2-13bf-4cd2-a5ac-6aa2c12e8f95	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
46e6d439-49ab-4001-b576-7df03d3babee	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
46e6d439-49ab-4001-b576-7df03d3babee	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
8a83194a-d3bc-49dd-8594-ed05a26d23a0	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
8a83194a-d3bc-49dd-8594-ed05a26d23a0	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
8a83194a-d3bc-49dd-8594-ed05a26d23a0	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
8a83194a-d3bc-49dd-8594-ed05a26d23a0	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
862f76a0-443e-4a80-8644-ef4922c5f38a	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
862f76a0-443e-4a80-8644-ef4922c5f38a	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9e08ecc2-e291-4516-bae3-07b43abc2620	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9e08ecc2-e291-4516-bae3-07b43abc2620	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
62868b88-e860-457b-8605-04153588489b	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
62868b88-e860-457b-8605-04153588489b	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c5c94cb5-5272-498b-b30a-d81279c22e12	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c5c94cb5-5272-498b-b30a-d81279c22e12	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c5c94cb5-5272-498b-b30a-d81279c22e12	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5af34829-4d6f-425c-9f78-525896ea0526	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5af34829-4d6f-425c-9f78-525896ea0526	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
573a471b-8236-4977-b94b-80b530b27e7c	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
573a471b-8236-4977-b94b-80b530b27e7c	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6f9f3af8-fa88-4804-aa9b-5680afa4c1ba	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6f9f3af8-fa88-4804-aa9b-5680afa4c1ba	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
88b2de0e-fb93-4402-98ef-3c1bd149f61d	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
88b2de0e-fb93-4402-98ef-3c1bd149f61d	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f1831789-130e-485d-bc67-67fe3b5fc6af	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f1831789-130e-485d-bc67-67fe3b5fc6af	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a5fd318c-feeb-4b1b-b739-3e40a59dde18	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a5fd318c-feeb-4b1b-b739-3e40a59dde18	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2994671f-607f-4cdc-a2bc-22ab97456b28	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2994671f-607f-4cdc-a2bc-22ab97456b28	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2994671f-607f-4cdc-a2bc-22ab97456b28	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2994671f-607f-4cdc-a2bc-22ab97456b28	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
729fd30e-9cfb-4751-bbdb-935fbbb7f994	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
729fd30e-9cfb-4751-bbdb-935fbbb7f994	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b0ba69f7-69ce-411c-a22d-c449785d11e9	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b0ba69f7-69ce-411c-a22d-c449785d11e9	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
d072273b-7a6f-4fa4-9195-1697050cfab1	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
d072273b-7a6f-4fa4-9195-1697050cfab1	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
d072273b-7a6f-4fa4-9195-1697050cfab1	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
d072273b-7a6f-4fa4-9195-1697050cfab1	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
cf4749a6-6127-4d97-b2a0-17a11eabc216	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
cf4749a6-6127-4d97-b2a0-17a11eabc216	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f04f9044-cd22-4a29-8d93-333047a95f6a	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f04f9044-cd22-4a29-8d93-333047a95f6a	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
4135122d-a240-499c-8de4-3db650d7acc9	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
4135122d-a240-499c-8de4-3db650d7acc9	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
293f638f-6b5e-4c5a-9282-533cc1c97688	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
293f638f-6b5e-4c5a-9282-533cc1c97688	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
293f638f-6b5e-4c5a-9282-533cc1c97688	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
889560c5-9238-4463-82d8-b65d7fdba4bc	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
889560c5-9238-4463-82d8-b65d7fdba4bc	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
10e55ead-3752-4108-a6b5-5a48ee709f03	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
10e55ead-3752-4108-a6b5-5a48ee709f03	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c41e7852-875f-411b-93f1-7171f9871f9f	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c41e7852-875f-411b-93f1-7171f9871f9f	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
1f511b5e-1292-4202-860e-b54f11eda21e	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
1f511b5e-1292-4202-860e-b54f11eda21e	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
1f511b5e-1292-4202-860e-b54f11eda21e	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
1f511b5e-1292-4202-860e-b54f11eda21e	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
312e5b6a-024a-4a5d-9389-357b73426d42	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
312e5b6a-024a-4a5d-9389-357b73426d42	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
e6ef6d8e-87f0-4c3d-8ac9-dccb12f222f1	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
e6ef6d8e-87f0-4c3d-8ac9-dccb12f222f1	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
8a1eab45-738c-41b6-b35d-7737f5e2f64e	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
8a1eab45-738c-41b6-b35d-7737f5e2f64e	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3260915b-2633-418b-997d-2beabd07ed2b	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3260915b-2633-418b-997d-2beabd07ed2b	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3260915b-2633-418b-997d-2beabd07ed2b	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3260915b-2633-418b-997d-2beabd07ed2b	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6d6f1209-693c-409d-9587-ed4e04d77930	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6d6f1209-693c-409d-9587-ed4e04d77930	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
18c4a035-c0ad-48f3-8628-30fee5e16970	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
18c4a035-c0ad-48f3-8628-30fee5e16970	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c41a5544-af25-44ec-9fab-26fa3a4e08a5	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c41a5544-af25-44ec-9fab-26fa3a4e08a5	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
07a988ec-6626-4d30-818e-4bc17de2c7ac	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
07a988ec-6626-4d30-818e-4bc17de2c7ac	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
07a988ec-6626-4d30-818e-4bc17de2c7ac	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
07a988ec-6626-4d30-818e-4bc17de2c7ac	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f8cb8b17-b65c-4df2-baab-62604c96a8c0	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
f8cb8b17-b65c-4df2-baab-62604c96a8c0	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7fe9d01e-9282-4b4d-9377-b8b5d4c7f7d2	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7fe9d01e-9282-4b4d-9377-b8b5d4c7f7d2	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9897dc81-824b-4829-9fda-76c3f3c3e38f	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9897dc81-824b-4829-9fda-76c3f3c3e38f	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9897dc81-824b-4829-9fda-76c3f3c3e38f	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a6f0ed93-9d6b-4592-a13e-5435550b4db2	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a6f0ed93-9d6b-4592-a13e-5435550b4db2	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
4ead5d1f-209d-4c0f-950b-80d8668a696b	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
4ead5d1f-209d-4c0f-950b-80d8668a696b	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
15a2f413-02d0-4624-9468-3a8bec2ba6b8	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
15a2f413-02d0-4624-9468-3a8bec2ba6b8	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3ecf9082-92fa-49e4-a15f-87acb5504803	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3ecf9082-92fa-49e4-a15f-87acb5504803	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3ecf9082-92fa-49e4-a15f-87acb5504803	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3ecf9082-92fa-49e4-a15f-87acb5504803	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
8be014b0-ed46-43db-89e2-91a301c618db	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
8be014b0-ed46-43db-89e2-91a301c618db	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
4c6d827e-f3db-47d8-be22-4dc4a611c63f	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
4c6d827e-f3db-47d8-be22-4dc4a611c63f	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
37609501-b2cd-4810-a1d5-b2a10f0405fd	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
37609501-b2cd-4810-a1d5-b2a10f0405fd	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b875f05c-64bb-41c8-b501-04ef26d03cb3	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b875f05c-64bb-41c8-b501-04ef26d03cb3	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6bb2ccef-6c0b-4baa-bc82-d037a1c93af1	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6bb2ccef-6c0b-4baa-bc82-d037a1c93af1	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a6d5837e-0df4-4cf0-9c98-8f0da7e4a1f1	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a6d5837e-0df4-4cf0-9c98-8f0da7e4a1f1	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
428cfba8-2dbb-45f6-844d-a309e2cdbd40	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
428cfba8-2dbb-45f6-844d-a309e2cdbd40	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
428cfba8-2dbb-45f6-844d-a309e2cdbd40	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
428cfba8-2dbb-45f6-844d-a309e2cdbd40	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fc6668ea-582e-4fa2-a17f-eb264a39e1a2	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fc6668ea-582e-4fa2-a17f-eb264a39e1a2	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6b116d7e-84ed-47de-81ea-2bd42ea50968	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
6b116d7e-84ed-47de-81ea-2bd42ea50968	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
1e9340db-2cfd-419f-8894-9448da0bbc19	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
1e9340db-2cfd-419f-8894-9448da0bbc19	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
1e9340db-2cfd-419f-8894-9448da0bbc19	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
1e9340db-2cfd-419f-8894-9448da0bbc19	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3a7984bc-e386-48e4-b988-7d8e086b5317	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3a7984bc-e386-48e4-b988-7d8e086b5317	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
e44fe06d-6034-4f79-a75c-79ab0f2b58df	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
e44fe06d-6034-4f79-a75c-79ab0f2b58df	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
cd441b90-ef66-411c-b22e-4e046c29677f	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
cd441b90-ef66-411c-b22e-4e046c29677f	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
d2298ed0-2515-4232-b70f-845a98dac595	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
d2298ed0-2515-4232-b70f-845a98dac595	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
d2298ed0-2515-4232-b70f-845a98dac595	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
feb2fb92-ce04-48c5-8a5f-9d2e832d1644	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
feb2fb92-ce04-48c5-8a5f-9d2e832d1644	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b4c20820-6710-46e1-b3cf-939b8bc00f93	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b4c20820-6710-46e1-b3cf-939b8bc00f93	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
032c01d5-4b5e-44f6-821d-2ba4342c938f	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
032c01d5-4b5e-44f6-821d-2ba4342c938f	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
30e16278-0ca1-4efa-a03b-7168658bb2c2	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
30e16278-0ca1-4efa-a03b-7168658bb2c2	17	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
30e16278-0ca1-4efa-a03b-7168658bb2c2	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
30e16278-0ca1-4efa-a03b-7168658bb2c2	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
8b09383e-447b-4fa0-b605-8d8cf4f3f527	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
8b09383e-447b-4fa0-b605-8d8cf4f3f527	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
33f73596-75e6-435e-94f5-d5b111a6aaf5	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
33f73596-75e6-435e-94f5-d5b111a6aaf5	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
caf34c22-6898-4c15-bde0-08f3d2634d41	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
caf34c22-6898-4c15-bde0-08f3d2634d41	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
625944b1-2b9b-433b-9af5-e72894aa7a58	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
625944b1-2b9b-433b-9af5-e72894aa7a58	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
625944b1-2b9b-433b-9af5-e72894aa7a58	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
625944b1-2b9b-433b-9af5-e72894aa7a58	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
72a14ee8-79a9-41a0-8fb1-ac0dfac5bfa2	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
72a14ee8-79a9-41a0-8fb1-ac0dfac5bfa2	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
cc7120df-7364-4284-a971-893f524d1a25	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
cc7120df-7364-4284-a971-893f524d1a25	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b2734396-c5d2-4b05-99d0-986a180a98a6	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b2734396-c5d2-4b05-99d0-986a180a98a6	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ec4cdace-5f9a-4198-9518-7c59753a1127	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ec4cdace-5f9a-4198-9518-7c59753a1127	6	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ec4cdace-5f9a-4198-9518-7c59753a1127	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
ec4cdace-5f9a-4198-9518-7c59753a1127	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3ed88e99-cb0d-423f-ae37-92b93c67d881	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3ed88e99-cb0d-423f-ae37-92b93c67d881	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
4acb1924-e6ec-428c-8401-ac05f87e2bbf	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
4acb1924-e6ec-428c-8401-ac05f87e2bbf	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fda17094-1c9f-45de-a42c-aa815d09bc2a	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fda17094-1c9f-45de-a42c-aa815d09bc2a	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b97db5e7-dca3-4f88-8318-6d457e09be91	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b97db5e7-dca3-4f88-8318-6d457e09be91	15	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b97db5e7-dca3-4f88-8318-6d457e09be91	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
b97db5e7-dca3-4f88-8318-6d457e09be91	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2c310487-b2d2-4f8a-bdc3-0fcd75eff4a9	8	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2c310487-b2d2-4f8a-bdc3-0fcd75eff4a9	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5d1e34b1-8861-4358-96e3-f5ed89f5c9d2	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5d1e34b1-8861-4358-96e3-f5ed89f5c9d2	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
18407190-2219-4190-9b20-ee775b0094ef	9	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
18407190-2219-4190-9b20-ee775b0094ef	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fba30b27-7555-43f7-8c74-b84e722ebbc8	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fba30b27-7555-43f7-8c74-b84e722ebbc8	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fba30b27-7555-43f7-8c74-b84e722ebbc8	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
fba30b27-7555-43f7-8c74-b84e722ebbc8	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a5e41a1c-9682-4873-8924-f11edf9b3fce	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a5e41a1c-9682-4873-8924-f11edf9b3fce	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
df216767-1cda-46b6-874f-845e41051203	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
df216767-1cda-46b6-874f-845e41051203	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
216136af-8b6b-44ae-a787-59506613a618	12	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
216136af-8b6b-44ae-a787-59506613a618	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7ea450f4-3442-46d0-a08b-19c1e7308bde	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7ea450f4-3442-46d0-a08b-19c1e7308bde	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7ea450f4-3442-46d0-a08b-19c1e7308bde	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3e1b170a-1554-4395-bc30-9bf8e6456a01	20	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
3e1b170a-1554-4395-bc30-9bf8e6456a01	7	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a74795a2-009c-433d-83b5-951f7b9bbfeb	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
a74795a2-009c-433d-83b5-951f7b9bbfeb	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9d94933f-74fd-4060-8400-53f4f570936b	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
9d94933f-74fd-4060-8400-53f4f570936b	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c6eabfc7-6dc9-446d-82ba-5f5c1ccee7c3	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c6eabfc7-6dc9-446d-82ba-5f5c1ccee7c3	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
c6eabfc7-6dc9-446d-82ba-5f5c1ccee7c3	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5f4a001a-6a1c-4d94-ac62-a46048382386	16	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
5f4a001a-6a1c-4d94-ac62-a46048382386	13	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7b70cf75-8a25-4a97-a3e3-d537f8fc85b3	11	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
7b70cf75-8a25-4a97-a3e3-d537f8fc85b3	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
31a87f04-ef6b-471d-af3c-c9aa342e7df7	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
31a87f04-ef6b-471d-af3c-c9aa342e7df7	18	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
91e4c5aa-2513-4817-a472-91da3e3813b1	10	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
91e4c5aa-2513-4817-a472-91da3e3813b1	14	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
91e4c5aa-2513-4817-a472-91da3e3813b1	19	interest	\N	\N	self_declared	2026-09-26 18:31:45.462661+00
2e42c806-48d6-422a-b282-2b30f0484c3c	19	interest	\N	\N	self_declared	2026-09-28 11:20:46.290119+00
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.users (id, email, password_hash, full_name, employee_code, designation, department, role, status, token_version, approved_by, approved_at, rejection_reason, failed_logins, locked_until, last_login_at, preferred_lang, created_at, updated_at, avatar_file_id) FROM stdin;
ff73e90e-1654-4bfd-8c73-43ad75a07f21	trainer02@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Aditya Singh	\N	Scientist-E	RMC Kolkata	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
ff38df49-9e3b-4df5-92a2-4852f8b79c74	trainer03@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Priya Menon	\N	Scientist-F	RMC New Delhi	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
2ae7d31a-ec05-402a-8104-ba433a1644eb	trainer04@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Arjun Joshi	\N	Scientist-C	RMC Guwahati	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
5db62bba-e3f6-4551-81f7-9d9237055aa3	trainer05@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Neha Sharma	\N	Scientist-D	RMC Nagpur	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
9894043b-3b29-45e0-9abd-9b61597bf09a	trainer06@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Rohan Patil	\N	Scientist-E	Satellite Division	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	trainer07@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Divya Singh	\N	Scientist-F	NWP Division	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	trainer08@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Manish Menon	\N	Scientist-C	RMC Mumbai	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
954754ab-6ecc-4d9a-a614-8cc84ffb3348	trainer09@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Sneha Joshi	\N	Scientist-D	RMC Chennai	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
62f1ad05-4a27-46cd-93f8-7a570f80f4f3	trainer10@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Rahul Sharma	\N	Scientist-E	RMC Kolkata	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
e9178b69-2339-4a64-857f-5ad0630325a5	trainer11@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Isha Patil	\N	Scientist-F	RMC New Delhi	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
82556fbd-47bf-44ac-aae9-3499c844ea75	trainer12@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Vikram Singh	\N	Scientist-C	RMC Guwahati	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
fa5ba122-30c1-4e56-bc6b-b761794b1528	trainer13@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Kavya Menon	\N	Scientist-D	RMC Nagpur	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	trainer14@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Suresh Joshi	\N	Scientist-E	Satellite Division	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
dab8c835-d264-43fb-9b10-7482bacf6b99	trainer15@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Ananya Sharma	\N	Scientist-F	NWP Division	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
a22b9cb3-9b82-4d48-a453-6deeb2e9f273	trainer16@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Siddharth Patil	\N	Scientist-C	RMC Mumbai	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
d6196926-78e5-4750-9dda-c802473b00e2	trainer17@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Lakshmi Singh	\N	Scientist-D	RMC Chennai	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
66a88386-7c29-44ae-805a-fd51d782743b	trainer18@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Karthik Menon	\N	Scientist-E	RMC Kolkata	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
49992467-6281-4454-9a23-aa2dd4c74a95	trainer19@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Pooja Joshi	\N	Scientist-F	RMC New Delhi	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
006ddbd1-35cc-4010-9363-d8234dae479e	trainer20@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Aarav Sharma	\N	Scientist-C	RMC Guwahati	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
a2e26d13-6f79-43d6-9749-2676a39be455	trainer21@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Meera Patil	\N	Scientist-D	RMC Nagpur	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
e9f6bde5-9ab9-477d-8669-134bdc4ad9ed	trainer22@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Aditya Singh	\N	Scientist-E	Satellite Division	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
9a3e7d30-cc90-4d84-8fad-fc7d979156c3	trainer23@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Priya Menon	\N	Scientist-F	NWP Division	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
7108643a-28fb-4548-8b93-ed349eab59f3	trainer24@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Arjun Joshi	\N	Scientist-C	RMC Mumbai	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
39496ad1-eecc-4826-8899-1dc4f0d96f73	trainer25@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Neha Sharma	\N	Scientist-D	RMC Chennai	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
87214765-f9ce-468a-a0f1-98e208a690ec	trainer26@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Rohan Patil	\N	Scientist-E	RMC Kolkata	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
bb9ed2a7-08bf-40bf-9125-220f11e3b138	trainer27@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Divya Singh	\N	Scientist-F	RMC New Delhi	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
2042a866-172d-42f9-96e4-7dc22771dc04	trainer28@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Manish Menon	\N	Scientist-C	RMC Guwahati	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
7102ca49-b74d-4460-847e-ce4e91f8c048	trainer29@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Sneha Joshi	\N	Scientist-D	RMC Nagpur	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
798470a9-6675-4483-8cd4-d1af4302c5af	trainer30@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Rahul Sharma	\N	Scientist-E	Satellite Division	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	\N	en	2025-11-10 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
43e91850-0b48-4bcd-be9d-c38742b91841	trainee002@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rohan Gupta	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-07 20:53:16.952641+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
72a5ceb8-6b68-433d-9b99-d62b8c9f1375	trainee003@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Pooja Sharma	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-15 00:24:32.715952+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
85e9f6c3-f766-43d5-8fa9-17faa945a923	admin@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Training Cell Admin	\N	Director (Training)	IMD HQ New Delhi	admin	approved	0	\N	2026-09-26 18:31:45.462661+00	\N	0	\N	2026-09-28 06:39:58.961803+00	en	2026-09-26 18:31:45.462661+00	2026-09-28 06:39:58.961803+00	\N
78313b75-0494-43a4-b199-ff1928254f44	trainee001@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Kavya Nair	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-07 02:15:20.22985+00	\N	0	\N	2026-09-28 16:46:11.502555+00	en	2025-12-20 18:31:45.462661+00	2026-09-28 16:46:11.502555+00	\N
2e35b549-e1b5-4e61-a221-b0799208258c	trainee004@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Vikram Nair	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-14 01:17:32.542998+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
f8db984c-e990-4ead-b69f-74d50fa951dc	trainee005@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Neha Gupta	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-05 13:24:33.299498+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
7f53c53d-3323-4146-8cea-01d6c38b4f77	trainee006@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Karthik Sharma	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-02 11:02:49.116145+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
3e1e22ae-3497-44dc-bb66-1a3c24a5af91	trainee007@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Isha Nair	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-12 21:00:48.855681+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
fbc637df-19cd-4ec5-b08d-49ce15747076	trainee008@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Arjun Gupta	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-04 01:10:59.044426+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
7b68a9ad-6ab1-4164-89e4-b13eea948a92	trainee009@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Lakshmi Sharma	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-01-21 03:20:10.181433+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
6f1d6dd6-daa9-4660-a06f-527bf32f663e	trainee010@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rahul Nair	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-22 00:51:19.770049+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
fc08ec35-be50-46ec-8acb-0ddb68b16b22	trainee011@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Priya Gupta	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-30 13:33:00.683488+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
2731bad6-8e73-4106-8def-3df5df76b6ea	trainee012@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Siddharth Sharma	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-29 20:55:54.980059+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
ab65843a-c349-4b21-b43b-9302ed8231b4	trainee013@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Sneha Nair	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-25 15:55:00.26929+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
ab903484-298e-4415-93b0-8f5ea844bf31	trainee014@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aditya Gupta	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-05 09:53:10.251228+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
9389e5a2-816f-4e52-950b-a9af117c7ad1	trainee015@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Ananya Sharma	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-25 17:05:25.738669+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
602031bb-35f7-4efc-9f2c-f0bcf7d5ef3b	trainee016@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Manish Nair	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-28 06:45:54.871252+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
b28e0245-9390-4127-ad3f-80ace4775f43	trainee017@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Meera Gupta	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-29 02:30:09.792436+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
3d04f1c2-2486-4f53-bde5-76ba389ec266	trainee018@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Suresh Sharma	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-23 21:32:12.657079+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
2af59a77-c993-46c3-a686-b91217814d48	trainee019@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Divya Nair	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-08 12:48:21.108002+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
c43722c6-7e70-49e0-acb4-ba4f953e36a8	trainee020@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aarav Gupta	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-06 23:29:42.711836+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
7b1099fc-7596-4be6-9ab4-990d535c39a5	trainee021@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Kavya Sharma	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-17 03:32:13.696216+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
732e74cf-b9b7-4adc-a43a-794430d7fe49	trainee022@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rohan Nair	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-07 15:40:54.579678+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
48f33e15-f87f-4629-ab82-4123ada4bdc4	trainee023@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Pooja Gupta	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-13 10:04:37.458714+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
3af00a36-1f7b-4846-a52a-b1871416c5b1	trainee024@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Vikram Sharma	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-22 00:05:53.257847+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
7acc259e-1231-481b-ab79-59821fd46534	trainee025@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Neha Nair	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-26 23:55:36.989097+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
05a922f4-7a9b-427c-bd4f-34ee3bdcfcf6	trainee026@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Karthik Gupta	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-06 09:47:12.74163+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
286bd41d-35d4-4b43-b05b-8548dab978ab	trainee027@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Isha Sharma	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-05 02:50:21.885498+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
33cb22eb-745e-4b09-ac2b-82ed8cb0a46b	trainee028@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Arjun Nair	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-20 01:28:13.246308+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
1eb0cec9-a12f-4f42-9d77-bf6e343e9a75	trainee029@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Lakshmi Gupta	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-16 12:21:38.062001+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
f51dbbc6-5c8a-487d-b785-786417797dc8	trainee030@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rahul Sharma	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-01 20:30:50.785868+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
562af427-bd16-4c30-940b-5d6121d738c8	trainee031@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Priya Nair	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-20 15:01:48.489017+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
696886f6-a4bf-44a6-9ba9-c939abb52137	trainee032@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Siddharth Gupta	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-11 05:25:25.51096+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
a4e9e21f-10e4-4c84-b4d0-9f420cf171c0	trainee033@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Sneha Sharma	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-12 08:20:53.275549+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
b8541832-74c6-404f-90d0-5fb6d3df7663	trainee034@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aditya Nair	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-06 13:10:43.29761+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
7e426fed-4c2e-46f4-866a-7b8aa048cf06	trainee035@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Ananya Gupta	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-07 04:10:48.488968+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
9bab5f84-a53e-49d6-91f8-eef87bf5960c	trainee036@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Manish Sharma	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-23 13:43:54.818231+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
202e1651-21c8-45c8-80d1-f326b27aec05	trainee037@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Meera Nair	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-03 23:39:33.683622+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
28fe79f0-6207-4e0c-8bae-1eb02eed759b	trainee038@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Suresh Gupta	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-11 16:52:32.53192+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
dbccc807-eaba-41f6-aabc-14c515010185	trainee039@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Divya Sharma	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-13 08:32:11.177198+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
b033e769-b8a9-4e50-bde8-f8a3cd8fdd0e	trainee040@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aarav Nair	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-24 16:44:56.788887+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
3ded69a7-290c-47f6-bd29-7369f6f8e3c8	trainee041@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Kavya Gupta	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-06 13:55:05.096102+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
48ae8c9d-e783-46c2-abf3-cc9d31e16d81	trainee042@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rohan Sharma	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-03 20:50:42.031677+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
350093ae-4f68-46a9-a0af-c33a9b87c340	trainee043@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Pooja Nair	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-04 08:58:37.200775+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
a596803e-b844-4f79-9db8-48d4b3d5abb7	trainee044@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Vikram Gupta	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-30 12:08:59.767045+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
24cbfa5b-7114-43b8-957c-fe0efa420c25	trainee045@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Neha Sharma	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-21 21:52:33.433952+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
f74aaa72-56ba-476d-9aed-ffbe2e41dd50	trainee046@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Karthik Nair	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-01 06:49:23.344786+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
69f12a27-893c-4791-987c-14fb10cbede4	trainee047@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Isha Gupta	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-03 03:33:44.627815+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
a17abc66-209e-405f-bcd6-c39e54cbce66	trainee048@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Arjun Sharma	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-04 03:58:14.776564+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
cbd81a81-1d5a-4273-8494-11efdd5fd354	trainee049@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Lakshmi Nair	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-11 10:09:42.913088+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
d05292f5-3e9f-4e51-bb50-05a6534dc9b8	trainee050@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rahul Gupta	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-17 09:46:38.656612+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
ea8fa5c6-6833-4701-9073-dd4ff3f78cb8	trainee051@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Priya Sharma	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-01 15:52:15.278357+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
4ace2ecd-317e-494c-ad50-71e2794fb907	trainee052@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Siddharth Nair	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-29 04:38:55.335266+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
d22f23cf-8a58-499a-8dba-92806f1622ef	trainee053@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Sneha Gupta	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-12 18:39:44.299786+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
8ffbd0cf-b807-4193-af37-3a61482c76eb	trainee054@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aditya Sharma	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-21 05:22:30.656535+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
bea31be8-3a44-4869-9c56-dce2da936f51	trainee055@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Ananya Nair	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-16 16:27:45.753687+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
3d87692f-06c1-4403-95ff-c70d1598700a	trainee056@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Manish Gupta	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-19 01:29:26.237984+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
60e67627-9116-4358-a94b-89c0416805f0	trainee057@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Meera Sharma	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-25 00:49:31.218629+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
3b6030a2-3993-4389-8c6c-d3427e0e680b	trainee058@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Suresh Nair	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-07 03:27:02.100399+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
f75210c9-faa1-45c8-9314-a65724983502	trainee059@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Divya Gupta	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-03 10:44:44.564463+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
306af47d-26b6-4dc3-96ae-eb178609c1f6	trainee060@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aarav Sharma	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-13 02:35:10.701469+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
0f80298a-f569-4c55-88aa-a57625e20751	trainee061@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Kavya Nair	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-07 15:01:29.801673+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
0d37acee-70ea-4604-8bd7-c995941443fd	trainee062@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rohan Gupta	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-13 18:51:47.383207+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
b2c7b829-9669-4258-ab45-acc4445b9d6d	trainee063@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Pooja Sharma	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-26 07:18:55.000091+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
333f633a-a466-43e6-9c02-cf743b327694	trainee064@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Vikram Nair	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-27 12:28:05.955936+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
5d9905c7-91e8-4bd9-b187-b1b8772e0f63	trainee065@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Neha Gupta	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-17 22:53:13.471496+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
b010ad34-1872-4015-9120-b4d6e175bda3	trainee066@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Karthik Sharma	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-25 12:46:08.134503+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
4d5fd264-452f-4436-8eca-5c6c62afb143	trainee067@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Isha Nair	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-03 15:16:28.724105+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
55a66a4f-35b9-442c-b8d1-bf6b8bda7e3f	trainee068@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Arjun Gupta	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-07 01:04:06.435611+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
9b9ade46-b30d-4a4c-ba6c-a66c454125e3	trainee069@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Lakshmi Sharma	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-01-23 20:54:46.836297+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
fafec148-becc-4918-b1e0-08794a94f6de	trainee070@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rahul Nair	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-26 03:30:44.155194+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
bd78a83d-5740-4d0d-9000-cdf29d332f27	trainee071@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Priya Gupta	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-20 10:04:54.557119+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
76e808de-304b-44e5-b793-8516b5fec7bb	trainee072@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Siddharth Sharma	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-27 12:41:10.197061+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
65ef229b-117d-4946-b5bb-301e3f828fc2	trainee073@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Sneha Nair	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-08 16:20:04.575453+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
17231857-2d57-46f3-aecc-cb26a0865adb	trainee074@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aditya Gupta	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-13 18:45:11.100786+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
6a389990-e259-43a4-a9a2-7575b00029e0	trainee075@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Ananya Sharma	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-21 11:46:49.67064+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
a6afe850-9547-4fac-892c-00558ad8f725	trainee076@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Manish Nair	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-06 00:02:59.753281+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
2d970758-319c-400f-b2ba-93057f16a33e	trainee077@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Meera Gupta	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-28 07:29:51.987895+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
77c70aa0-ddd9-4445-be30-4817de1cbfd0	trainee078@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Suresh Sharma	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-16 01:25:38.764108+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
a5102b13-4107-4fe5-b7a0-064dd07042ee	trainee079@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Divya Nair	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-07 11:29:23.119077+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
5a97c9d9-87c7-445c-9dc8-860fb29edb16	trainee080@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aarav Gupta	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-05 03:43:53.97885+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
6cf3f90d-5b2f-422b-98a5-3df74a5bcbad	trainee081@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Kavya Sharma	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-08 15:29:18.284469+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
3a18a01e-89f7-474e-abf1-964581203793	trainee082@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rohan Nair	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-15 04:18:46.894309+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
f15de25e-7244-417b-a4b1-83fe58cb8cd8	trainee083@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Pooja Gupta	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-03 07:32:34.104069+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
5abfd2bf-a622-4ac2-8867-2be6525ec0e8	trainee084@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Vikram Sharma	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-14 13:39:23.211555+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
8a0a7128-e6e6-4b49-8395-52723dda0b7c	trainee085@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Neha Nair	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-18 10:15:18.88097+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
e0fe8ae0-8d5d-4957-a2d5-b20417cffb7a	trainee086@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Karthik Gupta	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-16 13:26:16.084604+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
09cc88c9-6251-413b-9873-df6f5bb8b24d	trainee087@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Isha Sharma	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-20 22:19:56.184144+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
e888ad9f-c064-4d24-8143-eec67fac7c1c	trainee088@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Arjun Nair	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-30 02:10:47.172896+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
0369edbf-d1ba-47c9-b17c-e67c29bf27fc	trainee089@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Lakshmi Gupta	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-20 07:46:10.22554+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
fed72080-2568-4892-8047-0b3c72ff7fad	trainee090@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rahul Sharma	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-02 23:47:30.653723+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
6ec3f843-359c-4b5b-bc41-b3bd56c6e134	trainee091@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Priya Nair	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-16 09:44:18.129593+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
90a570b4-9441-4d8b-981d-a7fa379054d3	trainee092@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Siddharth Gupta	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-20 15:28:23.251067+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
a7bae3c0-0e2c-42db-8e35-79114d5dfe80	trainee093@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Sneha Sharma	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-13 02:20:29.025505+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
357f9f29-063f-4ff8-bdc9-6df1d8cb15b4	trainee094@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aditya Nair	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-02 10:18:51.188759+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
c2900748-9036-4804-b4f0-feb22ac5b4fb	trainee095@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Ananya Gupta	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-30 06:18:29.884869+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
152f1a01-df4b-4828-bf72-c1616f324c38	trainee096@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Manish Sharma	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-19 03:13:20.713631+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
5e2de4dd-f65c-43ae-9ab6-363fe303ab1e	trainee097@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Meera Nair	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-11 18:07:38.189121+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
08758984-558b-4323-bc35-2a202203d87b	trainee098@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Suresh Gupta	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-16 06:07:16.185493+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
1e418187-2717-4b94-934c-e5ca025993d8	trainee099@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Divya Sharma	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-05 08:41:29.132452+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
db9ec5a1-d0be-490d-91a6-bf32127bba75	trainee100@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aarav Nair	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-14 14:26:48.650485+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
f32344cc-9180-4953-b2cd-ba0f4bdb2eea	trainee101@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Kavya Gupta	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-15 06:37:08.938485+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
cc9e83f0-d177-4454-8ba5-f7581c6da639	trainee102@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rohan Sharma	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-13 10:59:22.136384+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
f1ad768a-4d4c-45c7-8ee2-d84fab61bd1d	trainee103@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Pooja Nair	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-09 03:03:56.543403+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
a8c5b60b-8763-4325-900d-07d7540e6015	trainee104@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Vikram Gupta	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-01-28 03:07:27.869921+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
6f3917b0-87b7-417f-a382-c38278a3d485	trainee105@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Neha Sharma	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-01-20 18:43:07.77474+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
eee6bbaa-75eb-44f4-9892-d46194b720a9	trainee106@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Karthik Nair	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-17 09:01:56.983868+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
ae420db9-d867-40d1-8d1a-01ee5d62e270	trainee107@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Isha Gupta	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-26 01:41:15.462059+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
edc1993b-5333-4d99-bae2-9e80266978e0	trainee108@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Arjun Sharma	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-20 08:57:29.137196+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
707e086b-3312-442d-ac6d-9776ebe73deb	trainee109@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Lakshmi Nair	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-21 08:33:37.340005+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
f1bc49b2-13bf-4cd2-a5ac-6aa2c12e8f95	trainee110@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rahul Gupta	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-13 12:41:45.004147+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
46e6d439-49ab-4001-b576-7df03d3babee	trainee111@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Priya Sharma	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-01-25 10:49:33.141832+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
8a83194a-d3bc-49dd-8594-ed05a26d23a0	trainee112@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Siddharth Nair	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-22 14:34:28.911741+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
862f76a0-443e-4a80-8644-ef4922c5f38a	trainee113@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Sneha Gupta	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-22 12:25:25.022236+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
9e08ecc2-e291-4516-bae3-07b43abc2620	trainee114@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aditya Sharma	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-06 18:34:01.869645+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
62868b88-e860-457b-8605-04153588489b	trainee115@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Ananya Nair	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-05 06:19:28.061152+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
c5c94cb5-5272-498b-b30a-d81279c22e12	trainee116@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Manish Gupta	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-01-29 01:18:27.137719+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
5af34829-4d6f-425c-9f78-525896ea0526	trainee117@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Meera Sharma	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-28 10:52:20.755121+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
573a471b-8236-4977-b94b-80b530b27e7c	trainee118@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Suresh Nair	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-06 08:05:35.181475+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
6f9f3af8-fa88-4804-aa9b-5680afa4c1ba	trainee119@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Divya Gupta	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-09 16:20:06.873282+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
7bf1a0d2-b293-4feb-b3d9-a07cf3db5249	trainee120@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aarav Sharma	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-12 15:45:43.662914+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
88b2de0e-fb93-4402-98ef-3c1bd149f61d	trainee121@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Kavya Nair	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-05 17:12:32.122835+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
f1831789-130e-485d-bc67-67fe3b5fc6af	trainee122@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rohan Gupta	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-07 03:42:32.231289+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
a5fd318c-feeb-4b1b-b739-3e40a59dde18	trainee123@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Pooja Sharma	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-12 04:51:14.521855+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
2994671f-607f-4cdc-a2bc-22ab97456b28	trainee124@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Vikram Nair	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-05 20:52:46.03035+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
729fd30e-9cfb-4751-bbdb-935fbbb7f994	trainee125@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Neha Gupta	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-24 07:55:54.053272+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
b0ba69f7-69ce-411c-a22d-c449785d11e9	trainee126@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Karthik Sharma	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-01-25 16:02:40.345232+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
89cdd3bf-09fc-4e75-88dd-1bfcc5bc101f	trainee127@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Isha Nair	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-21 00:57:47.126109+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
d072273b-7a6f-4fa4-9195-1697050cfab1	trainee128@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Arjun Gupta	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-07 21:13:58.570449+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
cf4749a6-6127-4d97-b2a0-17a11eabc216	trainee129@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Lakshmi Sharma	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-31 18:48:50.308828+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
f04f9044-cd22-4a29-8d93-333047a95f6a	trainee130@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rahul Nair	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-05 03:14:37.666551+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
4135122d-a240-499c-8de4-3db650d7acc9	trainee131@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Priya Gupta	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-03 02:37:05.370761+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
293f638f-6b5e-4c5a-9282-533cc1c97688	trainee132@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Siddharth Sharma	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-01-24 14:46:36.932445+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
889560c5-9238-4463-82d8-b65d7fdba4bc	trainee133@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Sneha Nair	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-01 22:52:37.805403+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
10e55ead-3752-4108-a6b5-5a48ee709f03	trainee134@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aditya Gupta	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-11 02:28:53.932859+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
c41e7852-875f-411b-93f1-7171f9871f9f	trainee135@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Ananya Sharma	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-12 02:51:45.609899+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
1f511b5e-1292-4202-860e-b54f11eda21e	trainee136@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Manish Nair	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-18 10:52:41.3306+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
312e5b6a-024a-4a5d-9389-357b73426d42	trainee137@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Meera Gupta	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-14 11:55:50.755726+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
e6ef6d8e-87f0-4c3d-8ac9-dccb12f222f1	trainee138@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Suresh Sharma	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-05 03:09:37.503611+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
8a1eab45-738c-41b6-b35d-7737f5e2f64e	trainee139@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Divya Nair	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-14 11:38:11.320703+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
3260915b-2633-418b-997d-2beabd07ed2b	trainee140@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aarav Gupta	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-14 20:30:00.569698+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
6d6f1209-693c-409d-9587-ed4e04d77930	trainee141@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Kavya Sharma	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-12 23:28:00.921302+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
18c4a035-c0ad-48f3-8628-30fee5e16970	trainee142@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rohan Nair	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-30 16:13:13.920198+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
c41a5544-af25-44ec-9fab-26fa3a4e08a5	trainee143@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Pooja Gupta	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-27 13:49:11.149223+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
07a988ec-6626-4d30-818e-4bc17de2c7ac	trainee144@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Vikram Sharma	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-20 17:22:57.290563+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
f8cb8b17-b65c-4df2-baab-62604c96a8c0	trainee145@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Neha Nair	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-09 09:56:44.165006+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
ee225bc3-ea1f-4dcc-9f2b-500f66e47b52	trainee146@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Karthik Gupta	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-23 06:34:46.320333+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
7fe9d01e-9282-4b4d-9377-b8b5d4c7f7d2	trainee147@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Isha Sharma	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-10 00:51:50.458977+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
9897dc81-824b-4829-9fda-76c3f3c3e38f	trainee148@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Arjun Nair	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-01 04:54:32.381907+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
a6f0ed93-9d6b-4592-a13e-5435550b4db2	trainee149@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Lakshmi Gupta	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-23 16:45:56.679787+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
4ead5d1f-209d-4c0f-950b-80d8668a696b	trainee150@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rahul Sharma	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-16 02:21:21.835663+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
15a2f413-02d0-4624-9468-3a8bec2ba6b8	trainee151@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Priya Nair	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-02 23:30:06.593109+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
3ecf9082-92fa-49e4-a15f-87acb5504803	trainee152@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Siddharth Gupta	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-19 16:31:44.957656+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
8be014b0-ed46-43db-89e2-91a301c618db	trainee153@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Sneha Sharma	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-18 22:08:26.376488+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
4c6d827e-f3db-47d8-be22-4dc4a611c63f	trainee154@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aditya Nair	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-10 18:45:34.882919+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
37609501-b2cd-4810-a1d5-b2a10f0405fd	trainee155@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Ananya Gupta	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-17 15:20:13.728192+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
ccabd4b4-49fe-4476-b1d5-4b2eeaabecd5	trainee156@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Manish Sharma	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-01 11:35:47.849435+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
b875f05c-64bb-41c8-b501-04ef26d03cb3	trainee157@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Meera Nair	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-01-27 05:04:46.496937+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
6bb2ccef-6c0b-4baa-bc82-d037a1c93af1	trainee158@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Suresh Gupta	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-26 04:39:02.901214+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
a6d5837e-0df4-4cf0-9c98-8f0da7e4a1f1	trainee159@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Divya Sharma	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-29 23:45:10.666008+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
428cfba8-2dbb-45f6-844d-a309e2cdbd40	trainee160@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aarav Nair	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-05 15:03:09.623289+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
fc6668ea-582e-4fa2-a17f-eb264a39e1a2	trainee161@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Kavya Gupta	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-09 21:31:50.3386+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
6b116d7e-84ed-47de-81ea-2bd42ea50968	trainee162@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rohan Sharma	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-20 09:33:22.77865+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
7d98c1dd-e2b5-4fb6-aa2a-68849c41f058	trainee163@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Pooja Nair	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-17 23:05:28.4818+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
1e9340db-2cfd-419f-8894-9448da0bbc19	trainee164@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Vikram Gupta	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-23 06:44:29.195612+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
3a7984bc-e386-48e4-b988-7d8e086b5317	trainee165@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Neha Sharma	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-16 14:33:44.407142+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
e44fe06d-6034-4f79-a75c-79ab0f2b58df	trainee166@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Karthik Nair	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-22 10:16:47.882852+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
cd441b90-ef66-411c-b22e-4e046c29677f	trainee167@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Isha Gupta	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-13 12:18:05.190178+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
d2298ed0-2515-4232-b70f-845a98dac595	trainee168@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Arjun Sharma	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-10 04:57:58.171921+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
feb2fb92-ce04-48c5-8a5f-9d2e832d1644	trainee169@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Lakshmi Nair	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-18 04:02:29.456737+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
b4c20820-6710-46e1-b3cf-939b8bc00f93	trainee170@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rahul Gupta	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-07 20:49:25.405257+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
032c01d5-4b5e-44f6-821d-2ba4342c938f	trainee171@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Priya Sharma	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-22 01:53:32.268978+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
30e16278-0ca1-4efa-a03b-7168658bb2c2	trainee172@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Siddharth Nair	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-06-08 16:05:04.970411+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
8b09383e-447b-4fa0-b605-8d8cf4f3f527	trainee173@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Sneha Gupta	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-27 13:59:13.745327+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
33f73596-75e6-435e-94f5-d5b111a6aaf5	trainee174@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aditya Sharma	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-03 03:23:33.442701+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
caf34c22-6898-4c15-bde0-08f3d2634d41	trainee175@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Ananya Nair	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-10 23:26:58.509693+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
625944b1-2b9b-433b-9af5-e72894aa7a58	trainee176@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Manish Gupta	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-20 16:07:47.978373+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
72a14ee8-79a9-41a0-8fb1-ac0dfac5bfa2	trainee177@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Meera Sharma	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-05 06:29:33.032781+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
cc7120df-7364-4284-a971-893f524d1a25	trainee178@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Suresh Nair	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-04-10 05:27:18.247395+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
b2734396-c5d2-4b05-99d0-986a180a98a6	trainee179@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Divya Gupta	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-24 09:31:00.11518+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
ec4cdace-5f9a-4198-9518-7c59753a1127	trainee180@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aarav Sharma	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-15 12:01:29.913133+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
3ed88e99-cb0d-423f-ae37-92b93c67d881	trainee181@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Kavya Nair	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-07 19:59:50.534551+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
4acb1924-e6ec-428c-8401-ac05f87e2bbf	trainee182@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rohan Gupta	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-11 19:08:08.266028+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
fda17094-1c9f-45de-a42c-aa815d09bc2a	trainee183@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Pooja Sharma	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-05-25 00:25:46.205571+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
b97db5e7-dca3-4f88-8318-6d457e09be91	trainee184@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Vikram Nair	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-03-17 08:59:38.398781+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
2c310487-b2d2-4f8a-bdc3-0fcd75eff4a9	trainee185@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Neha Gupta	\N	Scientific Assistant	RMC Chennai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-04 18:28:09.508877+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
5d1e34b1-8861-4358-96e3-f5ed89f5c9d2	trainee186@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Karthik Sharma	\N	Scientist-B	RMC Kolkata	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-25 11:56:25.263413+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
18407190-2219-4190-9b20-ee775b0094ef	trainee187@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Isha Nair	\N	Meteorologist Gr-I	RMC New Delhi	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-16 14:22:16.66267+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
fba30b27-7555-43f7-8c74-b84e722ebbc8	trainee188@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Arjun Gupta	\N	Meteorologist Gr-II	RMC Guwahati	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-07-20 15:29:44.071428+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
a5e41a1c-9682-4873-8924-f11edf9b3fce	trainee189@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Lakshmi Sharma	\N	Scientific Assistant	RMC Nagpur	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-02-09 08:25:23.983148+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
df216767-1cda-46b6-874f-845e41051203	trainee190@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Rahul Nair	\N	Scientist-B	Satellite Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-12 19:57:02.021501+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
216136af-8b6b-44ae-a787-59506613a618	trainee191@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Priya Gupta	\N	Meteorologist Gr-I	NWP Division	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-09-15 05:24:19.83763+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
7ea450f4-3442-46d0-a08b-19c1e7308bde	trainee192@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Siddharth Sharma	\N	Meteorologist Gr-II	RMC Mumbai	trainee	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2026-08-19 09:19:14.182227+00	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
3e1b170a-1554-4395-bc30-9bf8e6456a01	trainee193@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Sneha Nair	\N	Scientific Assistant	RMC Chennai	trainee	pending	0	\N	\N	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
a74795a2-009c-433d-83b5-951f7b9bbfeb	trainee194@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aditya Gupta	\N	Scientist-B	RMC Kolkata	trainee	pending	0	\N	\N	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
9d94933f-74fd-4060-8400-53f4f570936b	trainee195@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Ananya Sharma	\N	Meteorologist Gr-I	RMC New Delhi	trainee	pending	0	\N	\N	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
c6eabfc7-6dc9-446d-82ba-5f5c1ccee7c3	trainee196@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Manish Nair	\N	Meteorologist Gr-II	RMC Guwahati	trainee	pending	0	\N	\N	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
5f4a001a-6a1c-4d94-ac62-a46048382386	trainee197@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Meera Gupta	\N	Scientific Assistant	RMC Nagpur	trainee	pending	0	\N	\N	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
7b70cf75-8a25-4a97-a3e3-d537f8fc85b3	trainee198@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Suresh Sharma	\N	Scientist-B	Satellite Division	trainee	pending	0	\N	\N	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
31a87f04-ef6b-471d-af3c-c9aa342e7df7	trainee199@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Divya Nair	\N	Meteorologist Gr-I	NWP Division	trainee	pending	0	\N	\N	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
91e4c5aa-2513-4817-a472-91da3e3813b1	trainee200@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Aarav Gupta	\N	Meteorologist Gr-II	RMC Mumbai	trainee	pending	0	\N	\N	\N	0	\N	\N	en	2025-12-20 18:31:45.462661+00	2026-09-26 18:31:45.462661+00	\N
2e42c806-48d6-422a-b282-2b30f0484c3c	trainer01@imd.demo	$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu	Dr. Meera Patil	\N	Scientist-D	RMC Chennai	trainer	approved	0	85e9f6c3-f766-43d5-8fa9-17faa945a923	2025-11-30 18:31:45.462661+00	\N	0	\N	2026-09-28 16:56:12.125579+00	en	2025-11-10 18:31:45.462661+00	2026-09-28 16:56:12.125579+00	\N
\.


--
-- Data for Name: work_experiences; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.work_experiences (id, user_id, organization, designation, start_date, end_date, description) FROM stdin;
f1f36e7f-df23-4cba-86e6-37ad23f9e6e5	2e42c806-48d6-422a-b282-2b30f0484c3c	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Nowcasting
10e81ebe-aa44-4e8f-84e2-02d799b3c776	ff73e90e-1654-4bfd-8c73-43ad75a07f21	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in NWP Modelling
2c2d05f8-4baa-45b0-bc38-19b8d7506cbf	ff38df49-9e3b-4df5-92a2-4852f8b79c74	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Tropical Cyclone Forecasting
257e3b8a-7d3d-4972-bf54-5f174f3d76e5	2ae7d31a-ec05-402a-8104-ba433a1644eb	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Monsoon Forecasting
4a73ed43-6f05-42e6-a7da-3dccb5b5f38a	5db62bba-e3f6-4551-81f7-9d9237055aa3	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Doppler Weather Radar
7f7582f6-103f-41ea-8218-a50c2e198990	9894043b-3b29-45e0-9abd-9b61597bf09a	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Satellite Meteorology
06b701e7-2de1-4b10-92ac-a234cb080dfe	bf5108ec-8f74-41d6-ad9f-5ebbb04e2546	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Automatic Weather Stations
6462154e-768f-4ae5-b43d-f980914c0a81	4ac9c33b-6cc6-45fc-9cd8-dcdc6d602394	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Climate Data Analysis
dfd5c7b8-e8d8-4852-92bf-132fb4f20062	954754ab-6ecc-4d9a-a614-8cc84ffb3348	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Agromet Advisory
245510dd-c9a7-4418-b2c8-af03be0088ba	62f1ad05-4a27-46cd-93f8-7a570f80f4f3	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Flood Meteorology
c299f4df-94c2-4a69-a8f0-0ef4c6506023	e9178b69-2339-4a64-857f-5ad0630325a5	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Heatwave & Cold Wave
ba311364-b0cb-499c-85e3-9239c96722db	82556fbd-47bf-44ac-aae9-3499c844ea75	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Thunderstorm & Lightning
f3af3d5c-6818-4c97-b8b6-89aca95f4064	fa5ba122-30c1-4e56-bc6b-b761794b1528	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Python for Meteorology
61e1256b-70c8-43db-aa48-6888e0b93458	cf3b1f13-f4ec-458d-9dbc-e8f0e6324240	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Nowcasting
8dd62a9a-aa63-4f94-844a-09f179efaa16	dab8c835-d264-43fb-9b10-7482bacf6b99	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in NWP Modelling
471ce8e4-9d0f-4658-af85-b75b04320d85	a22b9cb3-9b82-4d48-a453-6deeb2e9f273	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Tropical Cyclone Forecasting
6dc2c565-2cf4-4e73-bc0a-9e0fd4de2362	d6196926-78e5-4750-9dda-c802473b00e2	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Monsoon Forecasting
97e6bd59-3877-43ec-8a7c-e1f91e92b7f4	66a88386-7c29-44ae-805a-fd51d782743b	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Doppler Weather Radar
06f39e28-3ace-4d4a-ac20-ca65bc68853b	49992467-6281-4454-9a23-aa2dd4c74a95	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Satellite Meteorology
e8c0884a-c02f-474d-9e69-a50deb2009aa	006ddbd1-35cc-4010-9363-d8234dae479e	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Automatic Weather Stations
a0c3ba8f-a924-4e9b-a4dd-66873ba5790e	a2e26d13-6f79-43d6-9749-2676a39be455	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Climate Data Analysis
829735ff-fc59-4cca-9a45-ceb76a8cbba0	e9f6bde5-9ab9-477d-8669-134bdc4ad9ed	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Agromet Advisory
e67e6f51-fe81-40e9-a5d4-3374660f66fc	9a3e7d30-cc90-4d84-8fad-fc7d979156c3	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Flood Meteorology
41b14f2d-fa97-474f-abfa-b42ebf7f021b	7108643a-28fb-4548-8b93-ed349eab59f3	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Heatwave & Cold Wave
68e3a7b5-bb7c-4c5a-8cbc-be62bd28ea1d	39496ad1-eecc-4826-8899-1dc4f0d96f73	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Thunderstorm & Lightning
60495d50-9abb-4db3-a13f-d2874f31fca8	87214765-f9ce-468a-a0f1-98e208a690ec	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Python for Meteorology
18065c31-3ef1-44f0-bfb0-298f7ed1dec2	bb9ed2a7-08bf-40bf-9125-220f11e3b138	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Nowcasting
ee7ec675-7ea9-45ac-8305-c5b013cfd25c	2042a866-172d-42f9-96e4-7dc22771dc04	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in NWP Modelling
d2c84e8a-834b-489f-903a-19c28f4f5a42	7102ca49-b74d-4460-847e-ce4e91f8c048	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Tropical Cyclone Forecasting
0dfbcc79-6fc7-4871-b7ca-30634645ca96	798470a9-6675-4483-8cd4-d1af4302c5af	India Meteorological Department	Scientist	2016-09-28	\N	Operational duties in Monsoon Forecasting
\.


--
-- Name: audit_logs_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.audit_logs_id_seq', 10, true);


--
-- Name: notifications_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.notifications_id_seq', 1, false);


--
-- Name: skills_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.skills_id_seq', 20, true);


--
-- Name: announcements announcements_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.announcements
    ADD CONSTRAINT announcements_pkey PRIMARY KEY (id);


--
-- Name: assessment_questions assessment_questions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assessment_questions
    ADD CONSTRAINT assessment_questions_pkey PRIMARY KEY (assessment_id, question_id);


--
-- Name: assessments assessments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assessments
    ADD CONSTRAINT assessments_pkey PRIMARY KEY (id);


--
-- Name: attempt_answers attempt_answers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.attempt_answers
    ADD CONSTRAINT attempt_answers_pkey PRIMARY KEY (attempt_id, question_id);


--
-- Name: attempts attempts_assessment_id_user_id_attempt_no_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.attempts
    ADD CONSTRAINT attempts_assessment_id_user_id_attempt_no_key UNIQUE (assessment_id, user_id, attempt_no);


--
-- Name: attempts attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.attempts
    ADD CONSTRAINT attempts_pkey PRIMARY KEY (id);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: certificates certificates_certificate_no_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_certificate_no_key UNIQUE (certificate_no);


--
-- Name: certificates certificates_enrollment_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_enrollment_id_key UNIQUE (enrollment_id);


--
-- Name: certificates certificates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_pkey PRIMARY KEY (id);


--
-- Name: course_resources course_resources_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.course_resources
    ADD CONSTRAINT course_resources_pkey PRIMARY KEY (course_id, resource_id);


--
-- Name: courses courses_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_code_key UNIQUE (code);


--
-- Name: courses courses_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_pkey PRIMARY KEY (id);


--
-- Name: enrollments enrollments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_pkey PRIMARY KEY (id);


--
-- Name: enrollments enrollments_user_id_course_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_user_id_course_id_key UNIQUE (user_id, course_id);


--
-- Name: external_certificates external_certificates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.external_certificates
    ADD CONSTRAINT external_certificates_pkey PRIMARY KEY (id);


--
-- Name: feedback feedback_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.feedback
    ADD CONSTRAINT feedback_pkey PRIMARY KEY (id);


--
-- Name: files files_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT files_pkey PRIMARY KEY (id);


--
-- Name: files files_storage_path_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT files_storage_path_key UNIQUE (storage_path);


--
-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);


--
-- Name: learning_resources learning_resources_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.learning_resources
    ADD CONSTRAINT learning_resources_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (user_id);


--
-- Name: qualifications qualifications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.qualifications
    ADD CONSTRAINT qualifications_pkey PRIMARY KEY (id);


--
-- Name: question_options question_options_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.question_options
    ADD CONSTRAINT question_options_pkey PRIMARY KEY (id);


--
-- Name: question_options question_options_question_id_position_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.question_options
    ADD CONSTRAINT question_options_question_id_position_key UNIQUE (question_id, "position");


--
-- Name: questions questions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.questions
    ADD CONSTRAINT questions_pkey PRIMARY KEY (id);


--
-- Name: skills skills_parent_id_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.skills
    ADD CONSTRAINT skills_parent_id_name_key UNIQUE (parent_id, name);


--
-- Name: skills skills_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.skills
    ADD CONSTRAINT skills_pkey PRIMARY KEY (id);


--
-- Name: skills skills_slug_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.skills
    ADD CONSTRAINT skills_slug_key UNIQUE (slug);


--
-- Name: trainer_competency_scores trainer_competency_scores_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.trainer_competency_scores
    ADD CONSTRAINT trainer_competency_scores_pkey PRIMARY KEY (trainer_id, skill_id);


--
-- Name: user_skills user_skills_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_skills
    ADD CONSTRAINT user_skills_pkey PRIMARY KEY (user_id, skill_id, kind);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_employee_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_employee_code_key UNIQUE (employee_code);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: work_experiences work_experiences_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.work_experiences
    ADD CONSTRAINT work_experiences_pkey PRIMARY KEY (id);


--
-- Name: idx_announcements_feed; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_announcements_feed ON public.announcements USING btree (publish_at DESC);


--
-- Name: idx_assess_course; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_assess_course ON public.assessments USING btree (course_id);


--
-- Name: idx_assess_deadline; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_assess_deadline ON public.assessments USING btree (deadline_at) WHERE (status = 'open'::public.assessment_status);


--
-- Name: idx_attempts_open; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_attempts_open ON public.attempts USING btree (expires_at) WHERE (status = 'in_progress'::public.attempt_status);


--
-- Name: idx_attempts_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_attempts_user ON public.attempts USING btree (user_id);


--
-- Name: idx_audit_entity; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_entity ON public.audit_logs USING btree (entity_type, entity_id);


--
-- Name: idx_audit_time; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_audit_time ON public.audit_logs USING btree (created_at DESC);


--
-- Name: idx_cert_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_cert_user ON public.certificates USING btree (user_id);


--
-- Name: idx_courses_skill; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_courses_skill ON public.courses USING btree (skill_id) WHERE (status = 'published'::public.course_status);


--
-- Name: idx_courses_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_courses_status ON public.courses USING btree (status);


--
-- Name: idx_courses_trainer; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_courses_trainer ON public.courses USING btree (trainer_id);


--
-- Name: idx_enroll_course_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_enroll_course_status ON public.enrollments USING btree (course_id, status);


--
-- Name: idx_feedback_trainer; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_feedback_trainer ON public.feedback USING btree (trainer_id);


--
-- Name: idx_files_sha; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_files_sha ON public.files USING btree (sha256);


--
-- Name: idx_jobs_ready; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_jobs_ready ON public.jobs USING btree (run_after) WHERE (status = 'pending'::public.job_status);


--
-- Name: idx_notif_poll; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notif_poll ON public.notifications USING btree (user_id, id DESC);


--
-- Name: idx_qual_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_qual_user ON public.qualifications USING btree (user_id);


--
-- Name: idx_questions_skill; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_questions_skill ON public.questions USING btree (skill_id, status);


--
-- Name: idx_resources_library; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_resources_library ON public.learning_resources USING btree (skill_id) WHERE (in_library AND is_published);


--
-- Name: idx_resources_trainer; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_resources_trainer ON public.learning_resources USING btree (trainer_id);


--
-- Name: idx_tcs_skill_score; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tcs_skill_score ON public.trainer_competency_scores USING btree (skill_id, total_score DESC);


--
-- Name: idx_user_skills_skill; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_skills_skill ON public.user_skills USING btree (skill_id, kind);


--
-- Name: idx_users_role_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_users_role_status ON public.users USING btree (role, status);


--
-- Name: idx_workexp_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_workexp_user ON public.work_experiences USING btree (user_id);


--
-- Name: uq_feedback_course; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uq_feedback_course ON public.feedback USING btree (user_id, course_id) WHERE ((course_id IS NOT NULL) AND (resource_id IS NULL));


--
-- Name: uq_jobs_dedupe; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uq_jobs_dedupe ON public.jobs USING btree (type, dedupe_key) WHERE ((dedupe_key IS NOT NULL) AND (status <> 'failed'::public.job_status));


--
-- Name: uq_notif_dedupe; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uq_notif_dedupe ON public.notifications USING btree (user_id, dedupe_key) WHERE (dedupe_key IS NOT NULL);


--
-- Name: v_assessment_stats _RETURN; Type: RULE; Schema: public; Owner: postgres
--

CREATE OR REPLACE VIEW public.v_assessment_stats AS
 SELECT a.id AS assessment_id,
    a.title,
    a.deadline_at,
    a.created_by,
        CASE
            WHEN (a.course_id IS NOT NULL) THEN ( SELECT count(*) AS count
               FROM public.enrollments e
              WHERE ((e.course_id = a.course_id) AND (e.status <> 'dropped'::public.enrollment_status)))
            ELSE ( SELECT count(*) AS count
               FROM public.users u
              WHERE ((u.role = 'trainee'::public.role_name) AND (u.status = 'approved'::public.user_status)))
        END AS assigned,
    count(DISTINCT t.user_id) FILTER (WHERE (t.status <> 'in_progress'::public.attempt_status)) AS submitted,
    round(avg(t.percentage), 1) AS avg_pct,
    round(((100.0 * (count(*) FILTER (WHERE t.passed))::numeric) / (NULLIF(count(*) FILTER (WHERE (t.passed IS NOT NULL)), 0))::numeric), 1) AS pass_rate_pct,
    round(avg(t.tab_switch_count), 1) AS avg_tab_switches
   FROM (public.assessments a
     LEFT JOIN public.attempts t ON ((t.assessment_id = a.id)))
  GROUP BY a.id;


--
-- Name: courses trg_courses_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_courses_updated BEFORE UPDATE ON public.courses FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: profiles trg_profiles_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_profiles_updated BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: users trg_users_updated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_users_updated BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: announcements announcements_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.announcements
    ADD CONSTRAINT announcements_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: announcements announcements_related_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.announcements
    ADD CONSTRAINT announcements_related_course_id_fkey FOREIGN KEY (related_course_id) REFERENCES public.courses(id) ON DELETE SET NULL;


--
-- Name: announcements announcements_related_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.announcements
    ADD CONSTRAINT announcements_related_user_id_fkey FOREIGN KEY (related_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: assessment_questions assessment_questions_assessment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assessment_questions
    ADD CONSTRAINT assessment_questions_assessment_id_fkey FOREIGN KEY (assessment_id) REFERENCES public.assessments(id) ON DELETE CASCADE;


--
-- Name: assessment_questions assessment_questions_question_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assessment_questions
    ADD CONSTRAINT assessment_questions_question_id_fkey FOREIGN KEY (question_id) REFERENCES public.questions(id) ON DELETE RESTRICT;


--
-- Name: assessments assessments_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assessments
    ADD CONSTRAINT assessments_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: assessments assessments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assessments
    ADD CONSTRAINT assessments_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: assessments assessments_skill_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.assessments
    ADD CONSTRAINT assessments_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES public.skills(id) ON DELETE SET NULL;


--
-- Name: attempt_answers attempt_answers_attempt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.attempt_answers
    ADD CONSTRAINT attempt_answers_attempt_id_fkey FOREIGN KEY (attempt_id) REFERENCES public.attempts(id) ON DELETE CASCADE;


--
-- Name: attempt_answers attempt_answers_question_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.attempt_answers
    ADD CONSTRAINT attempt_answers_question_id_fkey FOREIGN KEY (question_id) REFERENCES public.questions(id) ON DELETE RESTRICT;


--
-- Name: attempts attempts_assessment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.attempts
    ADD CONSTRAINT attempts_assessment_id_fkey FOREIGN KEY (assessment_id) REFERENCES public.assessments(id) ON DELETE CASCADE;


--
-- Name: attempts attempts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.attempts
    ADD CONSTRAINT attempts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: audit_logs audit_logs_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: certificates certificates_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id);


--
-- Name: certificates certificates_enrollment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_enrollment_id_fkey FOREIGN KEY (enrollment_id) REFERENCES public.enrollments(id) ON DELETE SET NULL;


--
-- Name: certificates certificates_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.files(id) ON DELETE SET NULL;


--
-- Name: certificates certificates_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.certificates
    ADD CONSTRAINT certificates_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: course_resources course_resources_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.course_resources
    ADD CONSTRAINT course_resources_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: course_resources course_resources_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.course_resources
    ADD CONSTRAINT course_resources_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.learning_resources(id) ON DELETE CASCADE;


--
-- Name: courses courses_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: courses courses_skill_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES public.skills(id) ON DELETE SET NULL;


--
-- Name: courses courses_thumbnail_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_thumbnail_file_id_fkey FOREIGN KEY (thumbnail_file_id) REFERENCES public.files(id) ON DELETE SET NULL;


--
-- Name: courses courses_trainer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.courses
    ADD CONSTRAINT courses_trainer_id_fkey FOREIGN KEY (trainer_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: enrollments enrollments_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: enrollments enrollments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: external_certificates external_certificates_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.external_certificates
    ADD CONSTRAINT external_certificates_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.files(id) ON DELETE SET NULL;


--
-- Name: external_certificates external_certificates_skill_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.external_certificates
    ADD CONSTRAINT external_certificates_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES public.skills(id) ON DELETE SET NULL;


--
-- Name: external_certificates external_certificates_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.external_certificates
    ADD CONSTRAINT external_certificates_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: feedback feedback_course_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.feedback
    ADD CONSTRAINT feedback_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE;


--
-- Name: feedback feedback_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.feedback
    ADD CONSTRAINT feedback_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.learning_resources(id) ON DELETE CASCADE;


--
-- Name: feedback feedback_trainer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.feedback
    ADD CONSTRAINT feedback_trainer_id_fkey FOREIGN KEY (trainer_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: feedback feedback_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.feedback
    ADD CONSTRAINT feedback_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: files files_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT files_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: jobs jobs_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: learning_resources learning_resources_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.learning_resources
    ADD CONSTRAINT learning_resources_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.files(id) ON DELETE SET NULL;


--
-- Name: learning_resources learning_resources_skill_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.learning_resources
    ADD CONSTRAINT learning_resources_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES public.skills(id) ON DELETE SET NULL;


--
-- Name: learning_resources learning_resources_trainer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.learning_resources
    ADD CONSTRAINT learning_resources_trainer_id_fkey FOREIGN KEY (trainer_id) REFERENCES public.users(id);


--
-- Name: notifications notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: qualifications qualifications_proof_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.qualifications
    ADD CONSTRAINT qualifications_proof_file_id_fkey FOREIGN KEY (proof_file_id) REFERENCES public.files(id) ON DELETE SET NULL;


--
-- Name: qualifications qualifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.qualifications
    ADD CONSTRAINT qualifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: question_options question_options_question_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.question_options
    ADD CONSTRAINT question_options_question_id_fkey FOREIGN KEY (question_id) REFERENCES public.questions(id) ON DELETE CASCADE;


--
-- Name: questions questions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.questions
    ADD CONSTRAINT questions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: questions questions_job_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.questions
    ADD CONSTRAINT questions_job_fk FOREIGN KEY (source_job_id) REFERENCES public.jobs(id) ON DELETE SET NULL;


--
-- Name: questions questions_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.questions
    ADD CONSTRAINT questions_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: questions questions_skill_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.questions
    ADD CONSTRAINT questions_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES public.skills(id);


--
-- Name: questions questions_source_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.questions
    ADD CONSTRAINT questions_source_resource_id_fkey FOREIGN KEY (source_resource_id) REFERENCES public.learning_resources(id) ON DELETE SET NULL;


--
-- Name: skills skills_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.skills
    ADD CONSTRAINT skills_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.skills(id) ON DELETE SET NULL;


--
-- Name: trainer_competency_scores trainer_competency_scores_skill_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.trainer_competency_scores
    ADD CONSTRAINT trainer_competency_scores_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES public.skills(id) ON DELETE CASCADE;


--
-- Name: trainer_competency_scores trainer_competency_scores_trainer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.trainer_competency_scores
    ADD CONSTRAINT trainer_competency_scores_trainer_id_fkey FOREIGN KEY (trainer_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_skills user_skills_skill_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_skills
    ADD CONSTRAINT user_skills_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES public.skills(id) ON DELETE CASCADE;


--
-- Name: user_skills user_skills_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_skills
    ADD CONSTRAINT user_skills_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: users users_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: users users_avatar_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_avatar_file_id_fkey FOREIGN KEY (avatar_file_id) REFERENCES public.files(id) ON DELETE SET NULL;


--
-- Name: work_experiences work_experiences_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.work_experiences
    ADD CONSTRAINT work_experiences_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict pQtk7uDkkJHXfiWEcvHN7rFemNhma3bi02JbYhFuX5nYcfhHEREcWznzyqUzq8d

