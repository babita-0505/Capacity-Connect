-- =====================================================================
-- CAPACITY CONNECT: deterministic demo data (run AFTER schema.sql)
--   1 admin · 30 trainers · 200 trainees · 8 departments
--   ~26 courses · ~52 library items · ~130 questions · ~600 enrolments
--   attempts, feedback, certificates, announcements
-- Deliberate gaps so the skill-gap heatmap has something to show:
--   * Upper-Air Observations: only one weak trainer, high trainee demand
--   * GIS & Mapping: no trainer at all, trainees interested
-- All demo passwords: Demo@1234   (bcrypt hash below)
-- =====================================================================
SELECT setseed(0.42);
CREATE TEMP SEQUENCE cert_seq;

DO $$
DECLARE
    pw        CONSTANT TEXT := '$2b$12$ukpuK6O.amTaCCIcYLmB..nJ/hKdYEyrfhrFPIbTOSN6yxxrK0Jnu';
    depts     CONSTANT TEXT[] := ARRAY['RMC Mumbai','RMC Chennai','RMC Kolkata','RMC New Delhi',
                                       'RMC Guwahati','RMC Nagpur','Satellite Division','NWP Division'];
    -- leaf skills that have trainers (upper-air handled separately, gis has none)
    staffed   CONSTANT TEXT[] := ARRAY['nowcasting','nwp','tropical-cyclone','monsoon','dwr','satellite',
                                       'aws','climate-data','agromet','flood-met','heatwave','thunderstorm','python-met'];
    first_n   CONSTANT TEXT[] := ARRAY['Aarav','Priya','Rohan','Sneha','Vikram','Ananya','Karthik','Meera','Arjun','Divya',
                                       'Rahul','Kavya','Siddharth','Pooja','Aditya','Neha','Manish','Isha','Suresh','Lakshmi'];
    last_n    CONSTANT TEXT[] := ARRAY['Sharma','Iyer','Das','Patil','Reddy','Nair','Singh','Mukherjee','Kulkarni','Menon',
                                       'Gupta','Bora','Joshi','Rao','Verma'];
    admin_id  UUID;
    tid       UUID;
    uid       UUID;
    cid       UUID;
    aid       UUID;
    qid       UUID;
    rid       UUID;
    eid       UUID;
    sk        RECORD;
    i INT; j INT; k INT;
    quality   NUMERIC;
    pct       NUMERIC;
    s_primary INT; s_second INT;
BEGIN
    -- ---------- admin ----------
    INSERT INTO users (email, password_hash, full_name, role, status, department, designation, approved_at)
    VALUES ('admin@imd.demo', pw, 'Training Cell Admin', 'admin', 'approved', 'IMD HQ New Delhi', 'Director (Training)', now())
    RETURNING id INTO admin_id;
    INSERT INTO profiles (user_id, headline) VALUES (admin_id, 'Capacity Building Cell, IMD HQ');

    -- ---------- 30 trainers ----------
    FOR i IN 1..30 LOOP
        INSERT INTO users (email, password_hash, full_name, role, status, department, designation, approved_by, approved_at, created_at)
        VALUES (format('trainer%s@imd.demo', lpad(i::text, 2, '0')), pw,
                'Dr. ' || first_n[1 + (i * 7) % 20] || ' ' || last_n[1 + (i * 3) % 15],
                'trainer', 'approved', depts[1 + i % 8],
                (ARRAY['Scientist-C','Scientist-D','Scientist-E','Scientist-F'])[1 + i % 4],
                admin_id, now() - interval '300 days', now() - interval '320 days')
        RETURNING id INTO tid;

        s_primary := (SELECT id FROM skills WHERE slug = staffed[1 + (i - 1) % 13]);
        s_second  := (SELECT id FROM skills WHERE slug = staffed[1 + (i + 4) % 13]);

        INSERT INTO profiles (user_id, headline, total_experience_months, expertise_summary, date_of_joining)
        SELECT tid,
               'Specialist in ' || s.name,
               36 + (random() * 240)::int,
               'Works on ' || array_to_string(s.keywords, ', ') || '. Trains forecasters and observers.',
               current_date - (365 * (3 + (random() * 20)::int))
        FROM skills s WHERE s.id = s_primary;

        INSERT INTO qualifications (user_id, degree, specialization, institution, year_completed)
        VALUES (tid, (ARRAY['M.Sc','M.Tech','PhD'])[1 + i % 3],
                (SELECT name FROM skills WHERE id = s_primary),
                (ARRAY['IIT Delhi','Andhra University','Cochin University (CUSAT)','IISc Bengaluru','Savitribai Phule Pune University'])[1 + i % 5],
                1995 + i % 25);

        INSERT INTO work_experiences (user_id, organization, designation, start_date, description)
        VALUES (tid, 'India Meteorological Department', 'Scientist', current_date - 3650,
                'Operational duties in ' || (SELECT name FROM skills WHERE id = s_primary));

        INSERT INTO user_skills (user_id, skill_id, kind, proficiency, years, source)
        VALUES (tid, s_primary, 'skill', 3 + (random() * 2)::int, 2 + round((random() * 12)::numeric, 1), 'admin_verified'),
               (tid, s_second,  'skill', 2 + (random() * 1)::int, 1 + round((random() * 5)::numeric, 1), 'self_declared')
        ON CONFLICT DO NOTHING;
    END LOOP;

    -- the single, weak upper-air trainer (still a gap: no trainer scores >= 0.60)
    UPDATE profiles SET expertise_summary = expertise_summary || ' Some radiosonde exposure.'
    WHERE user_id = (SELECT id FROM users WHERE email = 'trainer07@imd.demo');
    INSERT INTO user_skills (user_id, skill_id, kind, proficiency, years)
    SELECT id, (SELECT id FROM skills WHERE slug = 'upper-air'), 'skill', 2, 1
    FROM users WHERE email = 'trainer07@imd.demo';

    -- ---------- 200 trainees ----------
    FOR i IN 1..200 LOOP
        INSERT INTO users (email, password_hash, full_name, role, status, department, designation, approved_by, approved_at, created_at)
        VALUES (format('trainee%s@imd.demo', lpad(i::text, 3, '0')), pw,
                first_n[1 + (i * 11) % 20] || ' ' || last_n[1 + (i * 5) % 15],
                'trainee',
                CASE WHEN i > 192 THEN 'pending'::user_status ELSE 'approved' END,   -- 8 waiting for approval
                depts[1 + i % 8],
                (ARRAY['Meteorologist Gr-II','Scientific Assistant','Scientist-B','Meteorologist Gr-I'])[1 + i % 4],
                CASE WHEN i > 192 THEN NULL ELSE admin_id END,
                CASE WHEN i > 192 THEN NULL ELSE now() - (random() * 250 || ' days')::interval END,
                now() - interval '280 days')
        RETURNING id INTO uid;
        INSERT INTO profiles (user_id, headline, total_experience_months)
        VALUES (uid, 'IMD staff', (random() * 180)::int);

        -- interests: 2 random leaf skills, plus extra demand for gap skills
        INSERT INTO user_skills (user_id, skill_id, kind)
        SELECT uid, id, 'interest' FROM skills WHERE parent_id IS NOT NULL ORDER BY random() LIMIT 2
        ON CONFLICT DO NOTHING;
        IF i % 4 = 0 THEN
            INSERT INTO user_skills (user_id, skill_id, kind)
            SELECT uid, id, 'interest' FROM skills WHERE slug IN ('upper-air', 'gis') ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;

    -- ---------- courses (1 per trainer primary skill, a few with none) ----------
    FOR sk IN
        SELECT u.id AS trainer_id, us.skill_id, s.name, s.slug, s.keywords, row_number() OVER () AS rn
        FROM users u
        JOIN user_skills us ON us.user_id = u.id AND us.kind = 'skill' AND us.proficiency >= 3
        JOIN skills s ON s.id = us.skill_id
        WHERE u.role = 'trainer'
        ORDER BY u.email
        LIMIT 26
    LOOP
        -- hidden per-trainer "teaching quality" drives pass rates and ratings
        quality := 0.45 + random() * 0.5;

        INSERT INTO courses (code, title, summary, skill_id, tags, level, duration_hours, trainer_id,
                             status, created_by, published_at, created_at)
        VALUES (format('IMD-%s-%s', upper(left(replace(sk.slug, '-', ''), 4)), 100 + sk.rn),
                sk.name || (ARRAY[': Fundamentals',': Operational Practice',': Advanced Techniques'])[1 + sk.rn::int % 3],
                'Hands-on training on ' || sk.name || ' for IMD operational staff.',
                sk.skill_id, sk.keywords, (ARRAY['beginner','intermediate','advanced'])[1 + sk.rn::int % 3]::course_level,
                6 + (sk.rn % 5) * 4, sk.trainer_id, 'published', sk.trainer_id,
                now() - interval '240 days' + (sk.rn || ' days')::interval, now() - interval '250 days')
        RETURNING id INTO cid;

        -- 2 library resources per course (MP4 lecture + PDF notes), stored as external demo URLs
        FOR j IN 1..2 LOOP
            INSERT INTO learning_resources (trainer_id, title, type, external_url, skill_id, is_published,
                                            duration_seconds, page_count, view_count)
            VALUES (sk.trainer_id,
                    CASE j WHEN 1 THEN 'Lecture: ' || sk.name ELSE 'Reading notes: ' || sk.name END,
                    CASE j WHEN 1 THEN 'video'::resource_type ELSE 'pdf'::resource_type END,
                    '/uploads/demo/' || sk.slug || CASE j WHEN 1 THEN '.mp4' ELSE '.pdf' END,
                    sk.skill_id, true,
                    CASE j WHEN 1 THEN 1800 + (random() * 1800)::int END,
                    CASE j WHEN 2 THEN 12 + (random() * 30)::int END,
                    (random() * 400)::int)
            RETURNING id INTO rid;
            INSERT INTO course_resources (course_id, resource_id, module_title, position)
            VALUES (cid, rid, 'Module ' || j, j);
        END LOOP;

        -- assessment + 5 questions with 4 options each
        INSERT INTO assessments (title, type, course_id, skill_id, created_by, status, opens_at, deadline_at,
                                 duration_minutes, pass_pct, max_attempts)
        VALUES (sk.name || ' · End-of-course test', 'mcq_test', cid, sk.skill_id, sk.trainer_id, 'open',
                now() - interval '200 days', now() + ((sk.rn % 10) || ' days')::interval, 20, 60, 2)
        RETURNING id INTO aid;

        FOR j IN 1..5 LOOP
            INSERT INTO questions (skill_id, text, difficulty, status, generation_method, created_by, reviewed_by)
            VALUES (sk.skill_id, format('%s: sample question %s', sk.name, j), 1 + j % 4, 'approved',
                    CASE WHEN j <= 2 THEN 'llm'::generation_method ELSE 'manual' END, sk.trainer_id, sk.trainer_id)
            RETURNING id INTO qid;
            INSERT INTO question_options (question_id, text, is_correct, position)
            SELECT qid, 'Option ' || chr(64 + g.n), g.n = 1 + j % 4, g.n FROM generate_series(1, 4) AS g(n);
            INSERT INTO assessment_questions (assessment_id, question_id, position) VALUES (aid, qid, j);
        END LOOP;

        -- enrol ~24 random approved trainees, with attempts, feedback and certificates
        FOR uid, i IN
            SELECT u.id, (row_number() OVER ())::int FROM users u
            WHERE u.role = 'trainee' AND u.status = 'approved' ORDER BY random() LIMIT 18 + (random() * 12)::int
        LOOP
            INSERT INTO enrollments (user_id, course_id, status, progress_pct, enrolled_at, last_activity_at)
            VALUES (uid, cid, 'in_progress', round((40 + random() * 60)::numeric, 0),
                    now() - ((10 + random() * 220)::int || ' days')::interval, now() - ((random() * 10)::int || ' days')::interval)
            ON CONFLICT DO NOTHING
            RETURNING id INTO eid;
            CONTINUE WHEN eid IS NULL;

            IF random() < 0.85 THEN
                -- department effect: Guwahati & Nagpur weaker on radar/satellite (heatmap signal)
                pct := LEAST(100, GREATEST(10, round((quality * 100 + (random() - 0.5) * 40
                        - CASE WHEN (SELECT department FROM users WHERE id = uid) IN ('RMC Guwahati','RMC Nagpur')
                                    AND sk.slug IN ('dwr','satellite') THEN 20 ELSE 0 END)::numeric, 0)));
                INSERT INTO attempts (assessment_id, user_id, attempt_no, status, started_at, expires_at, submitted_at,
                                      score, max_score, percentage, passed, tab_switch_count)
                SELECT aid, uid, 1, 'submitted', e.enrolled_at + interval '5 days',
                       e.enrolled_at + interval '5 days 20 minutes', e.enrolled_at + interval '5 days 15 minutes',
                       round(pct / 20, 0), 5, pct, pct >= 60, (random() * 3)::int
                FROM enrollments e WHERE e.id = eid;

                IF pct >= 60 THEN
                    UPDATE enrollments SET status = 'completed', progress_pct = 100,
                           completed_at = enrolled_at + interval '6 days' WHERE id = eid;
                    INSERT INTO certificates (certificate_no, user_id, course_id, enrollment_id, final_score_pct,
                                              payload, sha256, signature, issued_at)
                    SELECT format('IMD-CC-2026-%s', lpad(nextval('cert_seq')::text, 6, '0')),
                           uid, cid, eid, pct,
                           jsonb_build_object('user', uid, 'course', cid, 'score', pct),
                           md5(eid::text) || md5(cid::text), 'demo-signature',
                           e.enrolled_at + interval '6 days'
                    FROM enrollments e WHERE e.id = eid;
                END IF;
            END IF;

            IF random() < 0.6 THEN
                INSERT INTO feedback (user_id, course_id, trainer_id, content_rating, trainer_rating, comment)
                VALUES (uid, cid, sk.trainer_id,
                        LEAST(5, GREATEST(1, round(quality * 5 + (random() - 0.5) * 2)))::smallint,
                        LEAST(5, GREATEST(1, round(quality * 5 + (random() - 0.5) * 2)))::smallint,
                        (ARRAY['Very practical session.','Good examples from operations.','Needed more hands-on time.',
                               'Clear explanations.','Slides could be improved.'])[1 + (random() * 4)::int]);
            END IF;
        END LOOP;
    END LOOP;

    -- ---------- homepage feed ----------
    INSERT INTO announcements (type, title, title_hi, body, created_by, is_pinned, publish_at) VALUES
     ('announcement', 'Pre-monsoon training calendar is live', 'प्री-मानसून प्रशिक्षण कैलेंडर जारी',
      'Enrol before 15 October for the pre-monsoon batch.', admin_id, true, now() - interval '2 days'),
     ('new_content',  'New lecture: Doppler Weather Radar products', 'नया व्याख्यान: डॉप्लर मौसम रडार उत्पाद',
      'Recorded session added to the trainer library.', admin_id, false, now() - interval '1 day'),
     ('achievement',  '100 certificates issued this quarter', 'इस तिमाही 100 प्रमाणपत्र जारी',
      'Congratulations to all trainees.', admin_id, false, now() - interval '5 hours'),
     ('notification', 'Portal maintenance on Sunday 02:00–03:00 IST', 'रविवार 02:00–03:00 IST रखरखाव',
      NULL, admin_id, false, now() - interval '1 hour');
END $$;

-- compute competency scores from the seeded evidence
SELECT refresh_competency_scores() AS competency_rows;
