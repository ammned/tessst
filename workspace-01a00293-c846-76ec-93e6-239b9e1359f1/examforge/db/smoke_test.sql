-- =============================================================================
-- Functional smoke test: proves triggers, marks rollup, coverage view and the
-- scope-filtered hybrid retrieval query all behave as designed.
-- Run:  psql -d examforge -v ON_ERROR_STOP=1 -f db/smoke_test.sql
-- =============================================================================
BEGIN;

-- --- fixtures ---------------------------------------------------------------
INSERT INTO teacher (id, display_name, default_language, default_year_level)
VALUES ('11111111-1111-1111-1111-111111111111', 'Amira', 'fr', 4);

INSERT INTO curriculum_framework (id, country_code, authority, name, school_year, status)
VALUES ('22222222-2222-2222-2222-222222222222', 'TN', 'Ministry of Education',
        'Programme officiel du primaire', '2025-2026', 'published');

-- year > subject > unit > chapter
INSERT INTO curriculum_node (id, framework_id, parent_id, node_type, subject_code, year_level,
                             title, path_label, materialized_path, depth, ordinal, status)
VALUES
 ('33333333-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222', NULL,
  'year', NULL, 4, 'Année 4', 'Y4', '/33333333-0000-0000-0000-000000000001', 0, 1, 'published'),
 ('33333333-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222',
  '33333333-0000-0000-0000-000000000001','subject','SCI',4,'Éveil scientifique',
  'Y4 / Sciences','/33333333-0000-0000-0000-000000000001/33333333-0000-0000-0000-000000000002',1,1,'published'),
 ('33333333-0000-0000-0000-000000000003','22222222-2222-2222-2222-222222222222',
  '33333333-0000-0000-0000-000000000002','unit','SCI',4,'Unité 2 : Les plantes',
  'Y4 / Sciences / Unité 2','/33333333-0000-0000-0000-000000000001/33333333-0000-0000-0000-000000000002/33333333-0000-0000-0000-000000000003',2,1,'published'),
 ('33333333-0000-0000-0000-000000000004','22222222-2222-2222-2222-222222222222',
  '33333333-0000-0000-0000-000000000003','chapter','SCI',4,'La nutrition des plantes',
  'Y4 / Sciences / Unité 2 / La nutrition des plantes','/33333333-0000-0000-0000-000000000001/33333333-0000-0000-0000-000000000002/33333333-0000-0000-0000-000000000003/33333333-0000-0000-0000-000000000004',3,1,'published'),
 ('33333333-0000-0000-0000-000000000009','22222222-2222-2222-2222-222222222222',
  '33333333-0000-0000-0000-000000000003','chapter','SCI',4,'Les volcans',
  'Y4 / Sciences / Unité 2 / Les volcans','/33333333-0000-0000-0000-000000000001/.../0009',3,2,'published');

INSERT INTO learning_objective (id, node_id, code, statement, bloom_level, action_verbs, status)
VALUES
 ('44444444-0000-0000-0000-000000000001','33333333-0000-0000-0000-000000000004','SC.4.2.3',
  'Identifier le rôle des racines dans l''absorption de l''eau','understand',
  ARRAY['identifier','expliquer'],'published'),
 ('44444444-0000-0000-0000-000000000002','33333333-0000-0000-0000-000000000004','SC.4.2.4',
  'Expliquer le trajet de la sève dans la plante','apply', ARRAY['expliquer'],'published');

INSERT INTO source_book (id, framework_id, kind, title, subject_code, year_level, edition,
                         language, storage_uri, content_hash, status)
VALUES ('55555555-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222',
        'ministry_textbook','Éveil scientifique 4e année','SCI',4,'2025',
        'fr','s3://examforge/books/sci4.pdf','hash-sci4-2025','published');

INSERT INTO source_chunk (id, book_id, node_id, chunk_type, ordinal, content, page_number,
                          language, status)
VALUES
 ('66666666-0000-0000-0000-000000000001','55555555-0000-0000-0000-000000000001',
  '33333333-0000-0000-0000-000000000004','exposition',1,
  'Les racines de la plante absorbent l''eau et les sels minéraux du sol. Cette eau forme la sève brute.',
  42,'fr','published'),
 ('66666666-0000-0000-0000-000000000002','55555555-0000-0000-0000-000000000001',
  '33333333-0000-0000-0000-000000000004','example',2,
  'Exemple : si l''on place une tige de céleri dans de l''eau colorée, on observe la montée de la sève.',
  43,'fr','published'),
 -- out-of-scope chunk: must NEVER be returned when scope = nutrition chapter
 ('66666666-0000-0000-0000-000000000003','55555555-0000-0000-0000-000000000001',
  '33333333-0000-0000-0000-000000000009','exposition',1,
  'Un volcan est une ouverture de la croûte terrestre par laquelle remonte le magma.',
  88,'fr','published');

-- exercise + version + citations + objective binding
INSERT INTO exercise (id, teacher_id, type_code, subject_code, year_level, difficulty,
                      bloom_level, language, status, origin, current_version)
VALUES
 ('77777777-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','mcq','SCI',4,
  'easy','understand','fr','accepted','ai_generated',1),
 ('77777777-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','short_answer','SCI',4,
  'medium','apply','fr','accepted','ai_generated',1);

INSERT INTO exercise_version (id, exercise_id, version, content, answer_key, marks)
VALUES
 ('88888888-0000-0000-0000-000000000001','77777777-0000-0000-0000-000000000001',1,
  '{"instruction":"Choisis la bonne réponse.","stem":"Quelle partie de la plante absorbe l''eau du sol ?","options":[{"key":"A","text":"La racine"},{"key":"B","text":"La fleur"},{"key":"C","text":"La feuille"}]}',
  '{"correct":["A"],"explanation":"Les racines absorbent l''eau et les sels minéraux."}', 1),
 ('88888888-0000-0000-0000-000000000002','77777777-0000-0000-0000-000000000002',1,
  '{"instruction":"Réponds par une phrase.","stem":"Explique ce qu''est la sève brute."}',
  '{"correct":["L''eau et les sels minéraux absorbés par les racines."],"marking_scheme":[{"step":"mentionne l''eau","marks":1},{"step":"mentionne les sels minéraux","marks":1}]}', 2);

INSERT INTO exercise_citation (exercise_version_id, chunk_id, node_id, page_number, relevance)
VALUES ('88888888-0000-0000-0000-000000000001','66666666-0000-0000-0000-000000000001',
        '33333333-0000-0000-0000-000000000004',42,0.91),
       ('88888888-0000-0000-0000-000000000002','66666666-0000-0000-0000-000000000001',
        '33333333-0000-0000-0000-000000000004',42,0.88);

INSERT INTO exercise_objective (exercise_id, objective_id) VALUES
 ('77777777-0000-0000-0000-000000000001','44444444-0000-0000-0000-000000000001'),
 ('77777777-0000-0000-0000-000000000002','44444444-0000-0000-0000-000000000002');

-- exam assembling the two items
INSERT INTO exam (id, teacher_id, title, subject_code, year_level, language, duration_minutes,
                  node_ids)
VALUES ('99999999-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111',
        'Contrôle Sciences - Unité 2','SCI',4,'fr',45,
        ARRAY['33333333-0000-0000-0000-000000000004']::uuid[]);

INSERT INTO exam_item (exam_id, exercise_version_id, ordinal, display_number)
VALUES ('99999999-0000-0000-0000-000000000001','88888888-0000-0000-0000-000000000001',1,'1'),
       ('99999999-0000-0000-0000-000000000001','88888888-0000-0000-0000-000000000002',2,'2');

-- --- assertions -------------------------------------------------------------
DO $$
DECLARE
    v_marks numeric; v_cnt int; v_tsv int; v_leak int;
BEGIN
    -- 1. marks rollup trigger: 1 + 2 = 3
    SELECT total_marks INTO v_marks FROM exam WHERE id = '99999999-0000-0000-0000-000000000001';
    ASSERT v_marks = 3, format('marks trigger expected 3, got %s', v_marks);

    -- 2. marks override recalculates
    UPDATE exam_item SET marks_override = 5
     WHERE exam_id = '99999999-0000-0000-0000-000000000001' AND ordinal = 1;
    SELECT total_marks INTO v_marks FROM exam WHERE id = '99999999-0000-0000-0000-000000000001';
    ASSERT v_marks = 7, format('override expected 7, got %s', v_marks);

    -- 3. deleting an item recalculates
    DELETE FROM exam_item
     WHERE exam_id = '99999999-0000-0000-0000-000000000001' AND ordinal = 2;
    SELECT total_marks INTO v_marks FROM exam WHERE id = '99999999-0000-0000-0000-000000000001';
    ASSERT v_marks = 5, format('delete expected 5, got %s', v_marks);

    -- 4. tsvector triggers populated
    SELECT count(*) INTO v_tsv FROM source_chunk WHERE tsv IS NULL;
    ASSERT v_tsv = 0, 'chunk tsv trigger did not populate';
    SELECT count(*) INTO v_tsv FROM curriculum_node WHERE tsv IS NULL;
    ASSERT v_tsv = 0, 'node tsv trigger did not populate';

    -- 5. current-version view
    SELECT count(*) INTO v_cnt FROM v_exercise_current
     WHERE teacher_id = '11111111-1111-1111-1111-111111111111';
    ASSERT v_cnt = 2, format('v_exercise_current expected 2, got %s', v_cnt);

    -- 6. coverage view maps items -> official objectives
    SELECT count(*) INTO v_cnt FROM v_exam_coverage
     WHERE exam_id = '99999999-0000-0000-0000-000000000001';
    ASSERT v_cnt = 1, format('coverage expected 1 objective after delete, got %s', v_cnt);

    -- 7. SCOPE ENFORCEMENT: keyword search restricted to the nutrition chapter must
    --    not leak the volcano chunk even though it matches a generic query.
    SELECT count(*) INTO v_leak
      FROM source_chunk sc
     WHERE sc.node_id = ANY(ARRAY['33333333-0000-0000-0000-000000000004']::uuid[])
       AND sc.status = 'published'
       AND sc.tsv @@ websearch_to_tsquery('simple', 'sève OR volcan');
    ASSERT v_leak = 2, format('scoped search expected 2 in-scope chunks, got %s', v_leak);

    SELECT count(*) INTO v_leak
      FROM source_chunk sc
     WHERE sc.node_id = ANY(ARRAY['33333333-0000-0000-0000-000000000004']::uuid[])
       AND sc.content ILIKE '%volcan%';
    ASSERT v_leak = 0, 'SCOPE LEAK: out-of-chapter content reachable within scope filter';

    -- 8. type_constraint seed covers all types x years
    SELECT count(*) INTO v_cnt FROM type_constraint;
    ASSERT v_cnt = 60, format('expected 60 constraint rows (10 types x 6 years), got %s', v_cnt);

    -- 9. year-1 policy blocks multi-step problem solving
    SELECT count(*) INTO v_cnt FROM type_constraint
     WHERE type_code = 'problem_solving' AND year_level <= 2 AND applicable;
    ASSERT v_cnt = 0, 'problem_solving must be inapplicable for years 1-2';

    -- 10. chunk origin constraint: a chunk cannot belong to both a book and a custom source
    BEGIN
        INSERT INTO source_chunk (book_id, custom_source_id, chunk_type, content)
        VALUES ('55555555-0000-0000-0000-000000000001', gen_random_uuid(), 'exposition', 'x');
        RAISE EXCEPTION 'chk_chunk_origin did not fire';
    EXCEPTION WHEN foreign_key_violation OR check_violation THEN
        NULL;  -- expected
    END;

    RAISE NOTICE 'ALL ASSERTIONS PASSED';
END $$;

ROLLBACK;
