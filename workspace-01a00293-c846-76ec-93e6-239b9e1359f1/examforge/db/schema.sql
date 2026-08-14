-- =============================================================================
-- ExamForge — PostgreSQL 16 schema (pgvector)
-- Scope: curriculum KB, generation, exercises, exams, assets, exports, AI audit.
-- Auth/identity intentionally OUT OF SCOPE: `teacher` is a minimal stub table so
-- foreign keys exist today and an identity provider can attach later [AUTH-LATER].
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "vector";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "btree_gin";

-- =============================================================================
-- 1. ENUMS
-- =============================================================================
CREATE TYPE node_type        AS ENUM ('year','subject','unit','chapter','lesson');
CREATE TYPE publish_status   AS ENUM ('draft','in_review','published','archived');
CREATE TYPE chunk_type       AS ENUM ('exposition','example','exercise','summary','glossary','figure_caption');
CREATE TYPE bloom_level      AS ENUM ('remember','understand','apply','analyze','evaluate','create');
CREATE TYPE difficulty_level AS ENUM ('easy','medium','hard');
CREATE TYPE exercise_type    AS ENUM ('mcq','multi_select','true_false','fill_blank','matching',
                                      'ordering','short_answer','open_ended','problem_solving','label_diagram');
CREATE TYPE exercise_status  AS ENUM ('draft','accepted','needs_review','rejected','archived');
CREATE TYPE origin_type      AS ENUM ('ai_generated','ai_edited','teacher_authored','textbook_adapted');
CREATE TYPE job_state        AS ENUM ('queued','resolving','retrieving','planning','synthesizing',
                                      'validating','imaging','ready','partial','failed','cancelled');
CREATE TYPE grounding_mode   AS ENUM ('official_curriculum','custom_source','mixed');
CREATE TYPE asset_kind       AS ENUM ('generated_image','svg_figure','library_asset','uploaded_image');
CREATE TYPE asset_status     AS ENUM ('pending','generating','ready','failed','moderation_blocked');
CREATE TYPE export_format    AS ENUM ('pdf','docx','html');
CREATE TYPE export_status    AS ENUM ('queued','rendering','ready','failed');
CREATE TYPE exam_status      AS ENUM ('building','finalised','exported','archived');
CREATE TYPE ai_task_kind     AS ENUM ('plan','synthesize','critic','classify','embed','image','ocr','moderation');
CREATE TYPE source_kind      AS ENUM ('ministry_textbook','ministry_syllabus','teacher_upload','teacher_paste');

-- =============================================================================
-- 2. IDENTITY STUB  [AUTH-LATER]
-- =============================================================================
CREATE TABLE teacher (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    display_name text        NOT NULL DEFAULT 'Teacher',
    school_name  text,
    -- preferences the generator reads as defaults
    default_language  text   NOT NULL DEFAULT 'fr',
    default_year_level smallint CHECK (default_year_level BETWEEN 1 AND 6),
    settings     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE teacher IS
  'Stub owner entity. No credentials by design; identity provider attaches later.';

-- =============================================================================
-- 3. CURRICULUM KNOWLEDGE BASE
-- =============================================================================
CREATE TABLE subject (
    code        text PRIMARY KEY,                    -- 'MATH','ARA','FRA','ENG','SCI','HIST','GEO','CIV','ART'
    name_i18n   jsonb       NOT NULL,                -- {"fr":"Mathématiques","ar":"الرياضيات"}
    default_language text   NOT NULL DEFAULT 'fr',
    is_rtl      boolean     NOT NULL DEFAULT false,
    icon        text,
    sort_order  smallint    NOT NULL DEFAULT 0
);

CREATE TABLE curriculum_framework (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    country_code text        NOT NULL,               -- 'TN'
    authority    text        NOT NULL,               -- 'Ministry of Education'
    name         text        NOT NULL,
    school_year  text        NOT NULL,               -- '2025-2026'
    status       publish_status NOT NULL DEFAULT 'draft',
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (country_code, name, school_year)
);

-- The curriculum tree: year > subject > unit > chapter > lesson
CREATE TABLE curriculum_node (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    framework_id  uuid NOT NULL REFERENCES curriculum_framework(id) ON DELETE CASCADE,
    parent_id     uuid REFERENCES curriculum_node(id) ON DELETE CASCADE,
    node_type     node_type   NOT NULL,
    subject_code  text REFERENCES subject(code),
    year_level    smallint CHECK (year_level BETWEEN 1 AND 6),
    code          text,                              -- official code if printed
    title         text        NOT NULL,
    summary       text,
    path_label    text        NOT NULL,              -- 'Y4 / Sciences / Unit 2 / Photosynthesis'
    materialized_path text    NOT NULL,              -- '/uuid/uuid/uuid' for subtree queries
    depth         smallint    NOT NULL DEFAULT 0,
    ordinal       integer     NOT NULL DEFAULT 0,
    estimated_hours numeric(5,2),
    language      text        NOT NULL DEFAULT 'fr',
    status        publish_status NOT NULL DEFAULT 'draft',
    metadata      jsonb       NOT NULL DEFAULT '{}'::jsonb,
    tsv           tsvector,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_year_required CHECK (node_type = 'year' OR year_level IS NOT NULL OR parent_id IS NOT NULL)
);
CREATE INDEX idx_node_parent      ON curriculum_node(parent_id);
CREATE INDEX idx_node_framework   ON curriculum_node(framework_id, status);
CREATE INDEX idx_node_lookup      ON curriculum_node(year_level, subject_code, status);
CREATE INDEX idx_node_path        ON curriculum_node USING gin (materialized_path gin_trgm_ops);
CREATE INDEX idx_node_tsv         ON curriculum_node USING gin (tsv);

-- Prerequisite DAG between nodes (avoid testing untaught prerequisites)
CREATE TABLE node_prerequisite (
    node_id         uuid NOT NULL REFERENCES curriculum_node(id) ON DELETE CASCADE,
    prerequisite_id uuid NOT NULL REFERENCES curriculum_node(id) ON DELETE CASCADE,
    strength        text NOT NULL DEFAULT 'required',  -- required | helpful
    PRIMARY KEY (node_id, prerequisite_id),
    CONSTRAINT chk_no_self_prereq CHECK (node_id <> prerequisite_id)
);

CREATE TABLE learning_objective (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id      uuid NOT NULL REFERENCES curriculum_node(id) ON DELETE CASCADE,
    code         text,                                -- 'SC.4.2.3'
    statement    text        NOT NULL,
    bloom_level  bloom_level NOT NULL DEFAULT 'understand',
    action_verbs text[]      NOT NULL DEFAULT '{}',
    is_terminal  boolean     NOT NULL DEFAULT false,
    language     text        NOT NULL DEFAULT 'fr',
    embedding    vector(1536),
    status       publish_status NOT NULL DEFAULT 'draft',
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_objective_node  ON learning_objective(node_id, status);
CREATE INDEX idx_objective_vec   ON learning_objective USING hnsw (embedding vector_cosine_ops);

CREATE TABLE vocabulary_term (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id     uuid NOT NULL REFERENCES curriculum_node(id) ON DELETE CASCADE,
    term        text        NOT NULL,
    language    text        NOT NULL DEFAULT 'fr',
    definition  text,
    year_introduced smallint CHECK (year_introduced BETWEEN 1 AND 6),
    UNIQUE (node_id, term, language)
);
CREATE INDEX idx_vocab_lookup ON vocabulary_term(language, year_introduced);

-- Age-appropriateness policy per year level (hard constraints for synthesis)
CREATE TABLE year_policy (
    year_level        smallint PRIMARY KEY CHECK (year_level BETWEEN 1 AND 6),
    max_sentence_words smallint NOT NULL,
    max_stem_words     smallint NOT NULL,
    allowed_operations text[]   NOT NULL DEFAULT '{}',   -- ['add','sub'] ...
    number_range_max   integer,
    vocabulary_tier    smallint NOT NULL DEFAULT 1,
    image_recommended  boolean  NOT NULL DEFAULT false,
    rules              jsonb    NOT NULL DEFAULT '{}'::jsonb
);

-- =============================================================================
-- 4. SOURCE MATERIAL & CHUNKS
-- =============================================================================
CREATE TABLE source_book (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    framework_id  uuid REFERENCES curriculum_framework(id) ON DELETE SET NULL,
    kind          source_kind NOT NULL DEFAULT 'ministry_textbook',
    title         text        NOT NULL,
    subject_code  text REFERENCES subject(code),
    year_level    smallint CHECK (year_level BETWEEN 1 AND 6),
    edition       text,
    isbn          text,
    language      text        NOT NULL DEFAULT 'fr',
    storage_uri   text        NOT NULL,               -- s3://bucket/key
    content_hash  text        NOT NULL,               -- dedupe re-uploads
    page_count    integer,
    status        publish_status NOT NULL DEFAULT 'draft',
    uploaded_by   uuid REFERENCES teacher(id) ON DELETE SET NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (content_hash)
);

-- Teacher-provided custom material (session-scoped grounding)
CREATE TABLE custom_source (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    teacher_id   uuid NOT NULL REFERENCES teacher(id) ON DELETE CASCADE,
    kind         source_kind NOT NULL DEFAULT 'teacher_upload',
    title        text,
    language     text,
    storage_uri  text,                                -- null when pasted text
    raw_text     text,
    detected_topics text[] NOT NULL DEFAULT '{}',
    year_level   smallint CHECK (year_level BETWEEN 1 AND 6),
    subject_code text REFERENCES subject(code),
    chunk_count  integer NOT NULL DEFAULT 0,
    warnings     jsonb   NOT NULL DEFAULT '[]'::jsonb,
    expires_at   timestamptz,                         -- GC for one-off uploads
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_custom_source_teacher ON custom_source(teacher_id, created_at DESC);

-- Unified chunk store: official book chunks AND custom source chunks
CREATE TABLE source_chunk (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    book_id        uuid REFERENCES source_book(id) ON DELETE CASCADE,
    custom_source_id uuid REFERENCES custom_source(id) ON DELETE CASCADE,
    node_id        uuid REFERENCES curriculum_node(id) ON DELETE CASCADE,
    chunk_type     chunk_type  NOT NULL DEFAULT 'exposition',
    ordinal        integer     NOT NULL DEFAULT 0,
    content        text        NOT NULL,
    token_count    integer,
    page_number    integer,
    bbox           jsonb,                             -- {x,y,w,h} for page-image linking
    language       text        NOT NULL DEFAULT 'fr',
    embedding      vector(1536),
    tsv            tsvector,
    status         publish_status NOT NULL DEFAULT 'draft',
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_chunk_origin CHECK (
        (book_id IS NOT NULL AND custom_source_id IS NULL) OR
        (book_id IS NULL AND custom_source_id IS NOT NULL)
    )
);
CREATE INDEX idx_chunk_node      ON source_chunk(node_id, status, ordinal);
CREATE INDEX idx_chunk_custom    ON source_chunk(custom_source_id);
CREATE INDEX idx_chunk_tsv       ON source_chunk USING gin (tsv);
CREATE INDEX idx_chunk_vec       ON source_chunk USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
CREATE INDEX idx_chunk_type_node ON source_chunk(node_id, chunk_type) WHERE status = 'published';

-- Figures extracted from the book: reference material for image generation
CREATE TABLE source_figure (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id     uuid NOT NULL REFERENCES curriculum_node(id) ON DELETE CASCADE,
    book_id     uuid REFERENCES source_book(id) ON DELETE CASCADE,
    caption     text,
    description text,
    page_number integer,
    storage_uri text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- =============================================================================
-- 5. EXERCISE TEMPLATES (data-driven type registry)
-- =============================================================================
CREATE TABLE exercise_template (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    type_code      exercise_type NOT NULL,
    version        integer     NOT NULL DEFAULT 1,
    json_schema    jsonb       NOT NULL,   -- validates generated content
    rendering_rules jsonb      NOT NULL DEFAULT '{}'::jsonb,
    worked_example jsonb       NOT NULL,
    is_active      boolean     NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (type_code, version)
);

-- subject_code '' = applies to every subject at this year level; a row with a real
-- subject code overrides it. Empty string (not NULL) keeps the PK usable.
CREATE TABLE type_constraint (
    type_code    exercise_type NOT NULL,
    year_level   smallint NOT NULL CHECK (year_level BETWEEN 1 AND 6),
    subject_code text     NOT NULL DEFAULT '',
    applicable   boolean  NOT NULL DEFAULT true,
    min_options  smallint,
    max_options  smallint,
    max_stem_words smallint NOT NULL DEFAULT 40,
    answer_format text     NOT NULL DEFAULT 'text',
    marks_min    numeric(4,2) NOT NULL DEFAULT 0.5,
    marks_max    numeric(4,2) NOT NULL DEFAULT 2,
    image_allowed     boolean NOT NULL DEFAULT true,
    image_recommended boolean NOT NULL DEFAULT false,
    PRIMARY KEY (type_code, year_level, subject_code)
);

-- Versioned prompt templates served through MCP
CREATE TABLE prompt_template (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text        NOT NULL,
    version    integer     NOT NULL DEFAULT 1,
    body       text        NOT NULL,
    variables  text[]      NOT NULL DEFAULT '{}',
    model_hint text,
    is_active  boolean     NOT NULL DEFAULT false,
    notes      text,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (name, version)
);
CREATE UNIQUE INDEX idx_prompt_active ON prompt_template(name) WHERE is_active;

-- =============================================================================
-- 6. GENERATION JOBS
-- =============================================================================
CREATE TABLE generation_job (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    teacher_id      uuid NOT NULL REFERENCES teacher(id) ON DELETE CASCADE,
    exam_id         uuid,                              -- FK added after exam table
    state           job_state   NOT NULL DEFAULT 'queued',
    grounding_mode  grounding_mode NOT NULL DEFAULT 'official_curriculum',
    -- scope
    framework_id    uuid REFERENCES curriculum_framework(id) ON DELETE SET NULL,
    year_level      smallint CHECK (year_level BETWEEN 1 AND 6),
    subject_code    text REFERENCES subject(code),
    node_ids        uuid[]      NOT NULL DEFAULT '{}',
    custom_source_id uuid REFERENCES custom_source(id) ON DELETE SET NULL,
    -- preferences (validated against a json schema in the app layer)
    preferences     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    /* preferences shape:
       { "question_count": 12,
         "pool_multiplier": 2.5,
         "difficulty_mix": {"easy":0.2,"medium":0.6,"hard":0.2},
         "type_mix": {"mcq":0.3,"fill_blank":0.2,"matching":0.2,"problem_solving":0.3},
         "language": "fr",
         "pedagogical_focus": "comprehension and application, avoid pure recall",
         "allow_images": true,
         "bloom_target": {"remember":0.2,"understand":0.4,"apply":0.4},
         "time_limit_minutes": 45 }                                            */
    blueprint       jsonb,                             -- planner output
    scope_signature text,
    -- results / diagnostics
    pool_size       integer     NOT NULL DEFAULT 0,
    accepted_count  integer     NOT NULL DEFAULT 0,
    rejected_count  integer     NOT NULL DEFAULT 0,
    warnings        jsonb       NOT NULL DEFAULT '[]'::jsonb,
    error_code      text,
    error_detail    text,
    -- accounting
    total_tokens    integer     NOT NULL DEFAULT 0,
    total_cost_usd  numeric(10,5) NOT NULL DEFAULT 0,
    trace_id        text,
    idempotency_key text,
    started_at      timestamptz,
    finished_at     timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_job_teacher ON generation_job(teacher_id, created_at DESC);
CREATE INDEX idx_job_state   ON generation_job(state) WHERE state NOT IN ('ready','failed','cancelled');
CREATE UNIQUE INDEX idx_job_idem ON generation_job(teacher_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE TABLE generation_event (
    id         bigserial PRIMARY KEY,
    job_id     uuid NOT NULL REFERENCES generation_job(id) ON DELETE CASCADE,
    state      job_state NOT NULL,
    message    text,
    progress   numeric(5,2),
    payload    jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_gen_event_job ON generation_event(job_id, id);

-- =============================================================================
-- 7. EXERCISES (versioned, reusable bank)
-- =============================================================================
CREATE TABLE exercise (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    teacher_id      uuid REFERENCES teacher(id) ON DELETE SET NULL,   -- owner; null = system bank
    job_id          uuid REFERENCES generation_job(id) ON DELETE SET NULL,
    type_code       exercise_type NOT NULL,
    subject_code    text REFERENCES subject(code),
    year_level      smallint CHECK (year_level BETWEEN 1 AND 6),
    difficulty      difficulty_level NOT NULL DEFAULT 'medium',
    bloom_level     bloom_level,
    language        text        NOT NULL DEFAULT 'fr',
    status          exercise_status NOT NULL DEFAULT 'draft',
    origin          origin_type NOT NULL DEFAULT 'ai_generated',
    grounding_mode  grounding_mode NOT NULL DEFAULT 'official_curriculum',
    current_version integer     NOT NULL DEFAULT 1,
    is_shared       boolean     NOT NULL DEFAULT false,
    tags            text[]      NOT NULL DEFAULT '{}',
    embedding       vector(1536),                       -- dedupe + "more like this"
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_exercise_bank ON exercise(teacher_id, subject_code, year_level, status);
CREATE INDEX idx_exercise_job  ON exercise(job_id);
CREATE INDEX idx_exercise_vec  ON exercise USING hnsw (embedding vector_cosine_ops);
CREATE INDEX idx_exercise_tags ON exercise USING gin (tags);

-- Immutable versions: teacher edits create a new version, never overwrite
CREATE TABLE exercise_version (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    exercise_id   uuid NOT NULL REFERENCES exercise(id) ON DELETE CASCADE,
    version       integer     NOT NULL,
    content       jsonb       NOT NULL,
    /* content shape (validated against exercise_template.json_schema), e.g. MCQ:
       { "instruction": "Choisis la bonne réponse.",
         "stem": "Quelle partie de la plante absorbe l'eau ?",
         "options": [{"key":"A","text":"La racine"},{"key":"B","text":"La fleur"},
                     {"key":"C","text":"La feuille"}],
         "media": {"asset_id":"...","position":"above_stem"} }                */
    answer_key    jsonb       NOT NULL,
    /* { "correct":["A"], "explanation":"...", "marking_scheme":[{"step":"...","marks":1}],
         "accepted_variants":["la racine","racine"] }                          */
    marks         numeric(4,2) NOT NULL DEFAULT 1,
    estimated_minutes numeric(4,1),
    asset_id      uuid,                                  -- FK added after asset table
    prompt_version text,
    model_used    text,
    edited_by     uuid REFERENCES teacher(id) ON DELETE SET NULL,
    edit_note     text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (exercise_id, version)
);
CREATE INDEX idx_ex_version ON exercise_version(exercise_id, version DESC);

-- Grounding provenance: which chunks/objectives produced this exercise
CREATE TABLE exercise_citation (
    exercise_version_id uuid NOT NULL REFERENCES exercise_version(id) ON DELETE CASCADE,
    chunk_id            uuid REFERENCES source_chunk(id) ON DELETE SET NULL,
    node_id             uuid REFERENCES curriculum_node(id) ON DELETE SET NULL,
    page_number         integer,
    relevance           numeric(4,3),
    PRIMARY KEY (exercise_version_id, chunk_id)
);

CREATE TABLE exercise_objective (
    exercise_id  uuid NOT NULL REFERENCES exercise(id) ON DELETE CASCADE,
    objective_id uuid NOT NULL REFERENCES learning_objective(id) ON DELETE CASCADE,
    weight       numeric(4,3) NOT NULL DEFAULT 1,
    PRIMARY KEY (exercise_id, objective_id)
);
CREATE INDEX idx_ex_obj_objective ON exercise_objective(objective_id);

-- Validation verdicts (both deterministic and critic tracks)
CREATE TABLE exercise_validation (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    exercise_version_id uuid NOT NULL REFERENCES exercise_version(id) ON DELETE CASCADE,
    track        text        NOT NULL,                  -- 'deterministic' | 'critic'
    passed       boolean     NOT NULL,
    verdict      exercise_status NOT NULL,
    checks       jsonb       NOT NULL DEFAULT '{}'::jsonb,
    /* {"schema_ok":true,"single_answer":true,"vocabulary_ok":true,
        "ngram_overlap":6,"alignment_confidence":0.88,"critic_agrees":true} */
    issues       jsonb       NOT NULL DEFAULT '[]'::jsonb,
    model_used   text,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_validation_version ON exercise_validation(exercise_version_id);

-- Teacher feedback loop (drives quality metrics)
CREATE TABLE exercise_feedback (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    exercise_id uuid NOT NULL REFERENCES exercise(id) ON DELETE CASCADE,
    teacher_id  uuid REFERENCES teacher(id) ON DELETE SET NULL,
    rating      smallint CHECK (rating BETWEEN 1 AND 5),
    flag        text,                                   -- 'wrong_answer','off_syllabus','too_hard',...
    comment     text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- =============================================================================
-- 8. MEDIA ASSETS
-- =============================================================================
CREATE TABLE asset (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind         asset_kind  NOT NULL DEFAULT 'generated_image',
    status       asset_status NOT NULL DEFAULT 'pending',
    spec         jsonb       NOT NULL DEFAULT '{}'::jsonb,   -- structured image spec
    spec_hash    text,                                       -- cache key / dedupe
    prompt_used  text,
    provider     text,
    model        text,
    storage_uri  text,
    thumbnail_uri text,
    width        integer,
    height       integer,
    mime_type    text,
    perceptual_hash text,
    moderation   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    verification jsonb       NOT NULL DEFAULT '{}'::jsonb,   -- e.g. vision count check
    cost_usd     numeric(10,5) NOT NULL DEFAULT 0,
    error_detail text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_asset_spec_hash ON asset(spec_hash) WHERE spec_hash IS NOT NULL AND status = 'ready';
CREATE INDEX idx_asset_status ON asset(status) WHERE status IN ('pending','generating');

ALTER TABLE exercise_version
    ADD CONSTRAINT fk_ex_version_asset FOREIGN KEY (asset_id) REFERENCES asset(id) ON DELETE SET NULL;

-- =============================================================================
-- 9. EXAMS (ordered selection of exercise versions)
-- =============================================================================
CREATE TABLE exam (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    teacher_id      uuid NOT NULL REFERENCES teacher(id) ON DELETE CASCADE,
    title           text        NOT NULL,
    subtitle        text,
    school_name     text,
    class_label     text,                               -- '4ème B'
    subject_code    text REFERENCES subject(code),
    year_level      smallint CHECK (year_level BETWEEN 1 AND 6),
    language        text        NOT NULL DEFAULT 'fr',
    is_rtl          boolean     NOT NULL DEFAULT false,
    exam_date       date,
    duration_minutes integer,
    total_marks     numeric(6,2) NOT NULL DEFAULT 0,     -- maintained by trigger
    status          exam_status NOT NULL DEFAULT 'building',
    grounding_mode  grounding_mode NOT NULL DEFAULT 'official_curriculum',
    node_ids        uuid[]      NOT NULL DEFAULT '{}',
    instructions    text,
    layout_options  jsonb       NOT NULL DEFAULT '{}'::jsonb,
    /* {"paper":"A4","columns":1,"font_size":12,"show_marks":true,
        "answer_space":"lines","header_logo":true,"section_numbering":"roman"} */
    version         integer     NOT NULL DEFAULT 1,      -- optimistic concurrency
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_exam_teacher ON exam(teacher_id, created_at DESC);

ALTER TABLE generation_job
    ADD CONSTRAINT fk_job_exam FOREIGN KEY (exam_id) REFERENCES exam(id) ON DELETE SET NULL;

CREATE TABLE exam_section (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    exam_id     uuid NOT NULL REFERENCES exam(id) ON DELETE CASCADE,
    ordinal     integer     NOT NULL,
    title       text,
    instructions text,
    marks       numeric(6,2),
    UNIQUE (exam_id, ordinal)
);

CREATE TABLE exam_item (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    exam_id       uuid NOT NULL REFERENCES exam(id) ON DELETE CASCADE,
    section_id    uuid REFERENCES exam_section(id) ON DELETE SET NULL,
    exercise_version_id uuid NOT NULL REFERENCES exercise_version(id) ON DELETE RESTRICT,
    ordinal       integer     NOT NULL,
    display_number text,                                -- computed: '1', '2.a'
    marks_override numeric(4,2),
    content_override jsonb,                             -- inline teacher edit for THIS exam
    page_break_before boolean NOT NULL DEFAULT false,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (exam_id, ordinal)
);
CREATE INDEX idx_exam_item_exam ON exam_item(exam_id, ordinal);

-- =============================================================================
-- 10. EXPORTS
-- =============================================================================
CREATE TABLE export_job (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    exam_id       uuid NOT NULL REFERENCES exam(id) ON DELETE CASCADE,
    teacher_id    uuid REFERENCES teacher(id) ON DELETE SET NULL,
    format        export_format NOT NULL DEFAULT 'pdf',
    include_answer_key boolean NOT NULL DEFAULT true,
    answer_key_mode text      NOT NULL DEFAULT 'separate_document', -- separate|appended|inline
    options       jsonb       NOT NULL DEFAULT '{}'::jsonb,
    status        export_status NOT NULL DEFAULT 'queued',
    paper_uri     text,
    answer_key_uri text,
    page_count    integer,
    error_detail  text,
    trace_id      text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz
);
CREATE INDEX idx_export_exam ON export_job(exam_id, created_at DESC);

-- =============================================================================
-- 11. AI + MCP AUDIT (provenance, cost, debugging)
-- =============================================================================
CREATE TABLE ai_call_log (
    id           bigserial PRIMARY KEY,
    job_id       uuid REFERENCES generation_job(id) ON DELETE CASCADE,
    exam_id      uuid REFERENCES exam(id) ON DELETE SET NULL,
    task_kind    ai_task_kind NOT NULL,
    provider     text        NOT NULL,
    model        text        NOT NULL,
    prompt_name  text,
    prompt_version text,
    prompt_hash  text,
    input_tokens integer,
    output_tokens integer,
    latency_ms   integer,
    cost_usd     numeric(10,5),
    cache_hit    boolean     NOT NULL DEFAULT false,
    success      boolean     NOT NULL DEFAULT true,
    error_code   text,
    trace_id     text,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_ai_log_job   ON ai_call_log(job_id, created_at);
CREATE INDEX idx_ai_log_cost  ON ai_call_log(created_at, task_kind);

CREATE TABLE mcp_call_log (
    id           bigserial PRIMARY KEY,
    job_id       uuid REFERENCES generation_job(id) ON DELETE CASCADE,
    method       text        NOT NULL,                  -- tools/call, resources/read
    tool_name    text,
    resource_uri text,
    args_hash    text,
    scope_ok     boolean     NOT NULL DEFAULT true,
    latency_ms   integer,
    result_bytes integer,
    citation_ids uuid[]      NOT NULL DEFAULT '{}',
    error_code   text,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_mcp_log_job ON mcp_call_log(job_id, created_at);
CREATE INDEX idx_mcp_scope_violation ON mcp_call_log(created_at) WHERE NOT scope_ok;

-- =============================================================================
-- 12. TRIGGERS
-- =============================================================================
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_touch_node     BEFORE UPDATE ON curriculum_node
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_exercise BEFORE UPDATE ON exercise
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_exam     BEFORE UPDATE ON exam
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_asset    BEFORE UPDATE ON asset
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_touch_job      BEFORE UPDATE ON generation_job
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- full-text vectors
CREATE OR REPLACE FUNCTION node_tsv_update() RETURNS trigger AS $$
BEGIN
    NEW.tsv := to_tsvector('simple',
        coalesce(NEW.title,'') || ' ' || coalesce(NEW.summary,'') || ' ' || coalesce(NEW.code,''));
    RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_node_tsv BEFORE INSERT OR UPDATE ON curriculum_node
    FOR EACH ROW EXECUTE FUNCTION node_tsv_update();

CREATE OR REPLACE FUNCTION chunk_tsv_update() RETURNS trigger AS $$
BEGIN
    NEW.tsv := to_tsvector('simple', coalesce(NEW.content,''));
    RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_chunk_tsv BEFORE INSERT OR UPDATE ON source_chunk
    FOR EACH ROW EXECUTE FUNCTION chunk_tsv_update();

-- keep exam.total_marks correct at all times
CREATE OR REPLACE FUNCTION recalc_exam_marks() RETURNS trigger AS $$
DECLARE target_exam uuid;
BEGIN
    target_exam := COALESCE(NEW.exam_id, OLD.exam_id);
    UPDATE exam e SET total_marks = (
        SELECT COALESCE(SUM(COALESCE(ei.marks_override, ev.marks)), 0)
          FROM exam_item ei
          JOIN exercise_version ev ON ev.id = ei.exercise_version_id
         WHERE ei.exam_id = target_exam
    ) WHERE e.id = target_exam;
    RETURN NULL;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_exam_marks AFTER INSERT OR UPDATE OR DELETE ON exam_item
    FOR EACH ROW EXECUTE FUNCTION recalc_exam_marks();

-- =============================================================================
-- 13. VIEWS
-- =============================================================================
-- Current version of every exercise (the bank view)
CREATE VIEW v_exercise_current AS
SELECT e.id, e.teacher_id, e.type_code, e.subject_code, e.year_level, e.difficulty,
       e.bloom_level, e.language, e.status, e.origin, e.grounding_mode, e.tags,
       ev.id AS version_id, ev.version, ev.content, ev.answer_key, ev.marks,
       ev.asset_id, e.created_at, e.updated_at
  FROM exercise e
  JOIN exercise_version ev
    ON ev.exercise_id = e.id AND ev.version = e.current_version;

-- Objective coverage report for an exam (the coordinator's sign-off view)
CREATE VIEW v_exam_coverage AS
SELECT ei.exam_id,
       lo.id   AS objective_id,
       lo.code AS objective_code,
       lo.statement,
       lo.bloom_level,
       COUNT(DISTINCT ei.id) AS item_count,
       SUM(COALESCE(ei.marks_override, ev.marks)) AS marks
  FROM exam_item ei
  JOIN exercise_version ev  ON ev.id = ei.exercise_version_id
  JOIN exercise e           ON e.id = ev.exercise_id
  JOIN exercise_objective eo ON eo.exercise_id = e.id
  JOIN learning_objective lo ON lo.id = eo.objective_id
 GROUP BY ei.exam_id, lo.id, lo.code, lo.statement, lo.bloom_level;

-- Per-job quality + cost rollup (ops dashboard)
CREATE VIEW v_job_quality AS
SELECT gj.id AS job_id, gj.teacher_id, gj.state, gj.pool_size,
       gj.accepted_count, gj.rejected_count,
       CASE WHEN gj.pool_size > 0
            THEN ROUND(gj.accepted_count::numeric / gj.pool_size, 3) END AS accept_rate,
       gj.total_tokens, gj.total_cost_usd,
       EXTRACT(EPOCH FROM (gj.finished_at - gj.started_at)) AS duration_seconds
  FROM generation_job gj;

-- =============================================================================
-- 14. SEED: subjects, year policies, exercise types
-- =============================================================================
INSERT INTO subject (code, name_i18n, default_language, is_rtl, sort_order) VALUES
 ('ARA', '{"ar":"العربية","fr":"Arabe","en":"Arabic"}',            'ar', true,  1),
 ('FRA', '{"ar":"الفرنسية","fr":"Français","en":"French"}',        'fr', false, 2),
 ('ENG', '{"ar":"الإنجليزية","fr":"Anglais","en":"English"}',      'en', false, 3),
 ('MATH','{"ar":"الرياضيات","fr":"Mathématiques","en":"Maths"}',   'fr', false, 4),
 ('SCI', '{"ar":"الإيقاظ العلمي","fr":"Éveil scientifique","en":"Science"}','fr', false, 5),
 ('HIST','{"ar":"التاريخ","fr":"Histoire","en":"History"}',        'ar', true,  6),
 ('GEO', '{"ar":"الجغرافيا","fr":"Géographie","en":"Geography"}',  'ar', true,  7),
 ('CIV', '{"ar":"التربية المدنية","fr":"Éducation civique","en":"Civics"}','ar', true, 8);

INSERT INTO year_policy (year_level, max_sentence_words, max_stem_words, allowed_operations,
                         number_range_max, vocabulary_tier, image_recommended, rules) VALUES
 (1,  8, 10, '{add,sub}',                 20,   1, true,
  '{"no_multi_step":true,"require_image_for_counting":true,"max_options":3}'),
 (2, 10, 12, '{add,sub}',                 100,  1, true,
  '{"no_multi_step":true,"max_options":3}'),
 (3, 12, 16, '{add,sub,mul}',             1000, 2, true,
  '{"max_steps":2,"max_options":4}'),
 (4, 15, 20, '{add,sub,mul,div}',         10000,2, false,
  '{"max_steps":2,"max_options":4}'),
 (5, 18, 26, '{add,sub,mul,div,fraction}',100000,3, false,
  '{"max_steps":3,"max_options":4}'),
 (6, 22, 32, '{add,sub,mul,div,fraction,decimal,percent}', 1000000, 3, false,
  '{"max_steps":4,"max_options":5}');

-- Type applicability defaults (subject-agnostic rows; subject overrides added per framework)
INSERT INTO type_constraint (type_code, year_level, subject_code, applicable, min_options,
                             max_options, max_stem_words, answer_format, marks_min, marks_max,
                             image_allowed, image_recommended)
SELECT t.type_code, y.year_level, '',   -- '' = default row for all subjects
       CASE
         WHEN t.type_code = 'problem_solving' AND y.year_level <= 2 THEN false
         WHEN t.type_code = 'open_ended'      AND y.year_level <= 2 THEN false
         WHEN t.type_code = 'ordering'        AND y.year_level = 1  THEN false
         ELSE true
       END,
       CASE WHEN t.type_code IN ('mcq','multi_select') THEN 2 END,
       CASE WHEN t.type_code IN ('mcq','multi_select')
            THEN (SELECT (rules->>'max_options')::smallint FROM year_policy WHERE year_level = y.year_level) END,
       (SELECT max_stem_words FROM year_policy WHERE year_level = y.year_level),
       CASE t.type_code
         WHEN 'mcq' THEN 'single_choice' WHEN 'multi_select' THEN 'multi_choice'
         WHEN 'true_false' THEN 'boolean' WHEN 'matching' THEN 'pairs'
         WHEN 'ordering' THEN 'sequence'  WHEN 'fill_blank' THEN 'text_list'
         ELSE 'text' END,
       CASE WHEN t.type_code IN ('open_ended','problem_solving') THEN 2 ELSE 0.5 END,
       CASE WHEN t.type_code IN ('open_ended','problem_solving') THEN 6 ELSE 2 END,
       true,
       (SELECT image_recommended FROM year_policy WHERE year_level = y.year_level)
  FROM (SELECT unnest(enum_range(NULL::exercise_type)) AS type_code) t
 CROSS JOIN (SELECT generate_series(1,6) AS year_level) y;

-- =============================================================================
-- 15. ROLES  (MCP server is physically read-only)
-- =============================================================================
-- CREATE ROLE examforge_ro LOGIN PASSWORD '***';
-- GRANT USAGE ON SCHEMA public TO examforge_ro;
-- GRANT SELECT ON ALL TABLES IN SCHEMA public TO examforge_ro;
-- GRANT INSERT ON custom_source, source_chunk TO examforge_ro;  -- session-scoped only
-- CREATE ROLE examforge_app LOGIN PASSWORD '***';
-- GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO examforge_app;
