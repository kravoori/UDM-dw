-- ============================================================================
-- MODULE 8 — DATA INTEGRITY FRAMEWORK  (v2 — set-based rewrite)
-- Package  : UDM.UDM_PKG_DI
--
-- CORE DESIGN PRINCIPLE
-- ─────────────────────────────────────────────────────────────────────────
-- One SQL statement per check type per batch run, regardless of attribute
-- count or rule count. Round trips to the stack table = constant (5).
--
-- Each check type has a dedicated SQL builder function that:
--   1. Iterates the attribute map or rules collection IN PLSQL (in-memory)
--   2. Generates one SQL string using conditional aggregation + UNPIVOT
--   3. Returns the string — executes no DML
--
-- The executor (p_execute_and_write):
--   1. Runs the built SQL via EXECUTE IMMEDIATE
--   2. BULK COLLECTs the result set into typed collections
--   3. Pre-generates all sequence values in one SELECT ... CONNECT BY
--   4. FORALL INSERTs all rows into udm_dq_results in one statement
--
-- CHECK INVENTORY
-- ─────────────────────────────────────────────────────────────────────────
-- Tier A — AUTO_DERIVED (derive from udm_attribute_map, no dq_rules entry):
--   NOT_NULL    : mandatory attributes (is_mandatory = 'Y')
--   DATA_TYPE   : VARCHAR typed columns — pattern conformance check
--
-- Tier B — CONFIGURED (require udm_dq_rules entry):
--   BOUNDS      : value outside [min_value, max_value]
--   DRIFT       : avg deviates > threshold % from prior period (single scan)
--   COMPLETENESS: non-null rate below threshold %
--
-- Depends  : udm_pkg_lineage (Module 9)
-- Compile  : After udm_pkg_lineage.
-- ============================================================================


-- ============================================================================
-- PACKAGE SPEC
-- ============================================================================
CREATE OR REPLACE PACKAGE udm.udm_pkg_di AS

  PROCEDURE run_checks (
    p_source_id  IN VARCHAR2,
    p_lineage_id IN VARCHAR2   -- parent LOAD lineage_id from Module 6
  );

  PROCEDURE run_domain_checks (p_domain_id IN VARCHAR2);

END udm_pkg_di;
/


-- ============================================================================
-- PACKAGE BODY
-- ============================================================================
CREATE OR REPLACE PACKAGE BODY udm.udm_pkg_di AS

  -- ==========================================================================
  -- SECTION 1 — TYPE DEFINITIONS
  -- ==========================================================================

  TYPE t_dq_attr_rec IS RECORD (
    canonical_name  udm_attribute_map.canonical_name%TYPE,
    data_type       udm_attribute_map.data_type%TYPE,
    is_mandatory    udm_attribute_map.is_mandatory%TYPE
  );
  TYPE t_dq_attr_tab IS TABLE OF t_dq_attr_rec INDEX BY PLS_INTEGER;

  TYPE t_dq_rule_rec IS RECORD (
    rule_id     udm_dq_rules.rule_id%TYPE,
    metric_name udm_dq_rules.metric_name%TYPE,
    check_type  udm_dq_rules.check_type%TYPE,
    threshold   udm_dq_rules.threshold%TYPE,
    min_value   udm_dq_rules.min_value%TYPE,
    max_value   udm_dq_rules.max_value%TYPE,
    action      udm_dq_rules.action%TYPE
  );
  TYPE t_dq_rule_tab IS TABLE OF t_dq_rule_rec INDEX BY PLS_INTEGER;

  -- Parallel collection types for BULK COLLECT in executor
  TYPE t_metric_tab    IS TABLE OF VARCHAR2(128) INDEX BY PLS_INTEGER;
  TYPE t_ruleid_tab    IS TABLE OF VARCHAR2(20)  INDEX BY PLS_INTEGER;
  TYPE t_status_tab    IS TABLE OF VARCHAR2(10)  INDEX BY PLS_INTEGER;
  TYPE t_number_tab    IS TABLE OF NUMBER        INDEX BY PLS_INTEGER;
  TYPE t_details_tab   IS TABLE OF VARCHAR2(500) INDEX BY PLS_INTEGER;
  TYPE t_action_tab    IS TABLE OF VARCHAR2(20)  INDEX BY PLS_INTEGER;
  TYPE t_varchar30_tab IS TABLE OF VARCHAR2(30)  INDEX BY PLS_INTEGER;


  -- ==========================================================================
  -- SECTION 2 — METADATA LAYER
  -- ==========================================================================

  -- --------------------------------------------------------------------------
  -- p_load_tier_a_attrs
  -- BULK COLLECTs attribute map rows for Tier A checks.
  --   p_check_type = 'NOT_NULL'  : loads is_mandatory = 'Y' attributes
  --   p_check_type = 'DATA_TYPE' : loads data_type = 'VARCHAR' attributes
  -- Excludes is_subject_key = 'Y' and is_time_key = 'Y' in both cases.
  -- --------------------------------------------------------------------------
  PROCEDURE p_load_tier_a_attrs (
    p_source_id  IN  VARCHAR2,
    p_check_type IN  VARCHAR2,
    p_attrs      OUT t_dq_attr_tab
  ) IS
  BEGIN
    IF p_check_type = 'NOT_NULL' THEN
      SELECT canonical_name, data_type, is_mandatory
      BULK COLLECT INTO p_attrs
      FROM   udm_attribute_map
      WHERE  source_id      = p_source_id
      AND    is_mandatory   = 'Y'
      AND    is_subject_key = 'N'
      AND    is_time_key    = 'N'
      AND    map_status     = 'ACTIVE'
      AND    (effective_to IS NULL OR effective_to > SYSDATE)
      ORDER  BY canonical_name;

    ELSIF p_check_type = 'DATA_TYPE' THEN
      SELECT canonical_name, data_type, is_mandatory
      BULK COLLECT INTO p_attrs
      FROM   udm_attribute_map
      WHERE  source_id      = p_source_id
      AND    data_type      = 'VARCHAR'
      AND    is_subject_key = 'N'
      AND    is_time_key    = 'N'
      AND    map_status     = 'ACTIVE'
      AND    (effective_to IS NULL OR effective_to > SYSDATE)
      ORDER  BY canonical_name;
    END IF;
  END p_load_tier_a_attrs;


  -- --------------------------------------------------------------------------
  -- p_load_tier_b_rules
  -- BULK COLLECTs dq_rules for one check_type.
  -- --------------------------------------------------------------------------
  PROCEDURE p_load_tier_b_rules (
    p_domain_id  IN  VARCHAR2,
    p_check_type IN  VARCHAR2,
    p_rules      OUT t_dq_rule_tab
  ) IS
  BEGIN
    SELECT rule_id, metric_name, check_type,
           threshold, min_value, max_value, action
    BULK COLLECT INTO p_rules
    FROM   udm_dq_rules
    WHERE  domain_id   = p_domain_id
    AND    check_type  = p_check_type
    AND    is_active   = 'Y'
    AND    (effective_to IS NULL OR effective_to > SYSDATE)
    ORDER  BY metric_name;
  END p_load_tier_b_rules;


  -- --------------------------------------------------------------------------
  -- p_get_prior_period
  -- Finds the coverage_period of the most recent successful LOAD before
  -- p_curr_period for this source. Used by DRIFT check.
  -- Returns NULL if no prior period found — caller emits WARNING rows.
  -- --------------------------------------------------------------------------
  FUNCTION p_get_prior_period (
    p_source_id   IN VARCHAR2,
    p_curr_period IN VARCHAR2
  ) RETURN VARCHAR2 IS
    l_prior VARCHAR2(20);
  BEGIN
    SELECT coverage_period INTO l_prior
    FROM   (
      SELECT coverage_period
      FROM   udm_lineage
      WHERE  source_id       = p_source_id
      AND    lineage_type    = 'LOAD'
      AND    status          = 'COMPLETE'
      AND    coverage_period < p_curr_period
      ORDER  BY coverage_period DESC
    )
    WHERE ROWNUM = 1;
    RETURN l_prior;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END p_get_prior_period;


  -- ==========================================================================
  -- SECTION 3 — SQL BUILDER LAYER
  -- Pure string builders. No DML. Returns NULL if input collection is empty.
  -- All generated SQL uses UNPIVOT to return one row per attribute/rule
  -- from a single aggregation scan of the stack table.
  -- ==========================================================================

  -- --------------------------------------------------------------------------
  -- p_build_not_null_sql
  -- One SQL covering all mandatory attributes.
  -- Single stack table scan. UNPIVOT returns one row per attribute.
  -- Scoped to lineage_id (this load batch) — not coverage_period.
  -- Bind variables at execution: :v (vendor_id), :l (lineage_id)
  -- --------------------------------------------------------------------------
  FUNCTION p_build_not_null_sql (
    p_attrs      IN t_dq_attr_tab,
    p_stk_table  IN VARCHAR2,
    p_vendor_id  IN VARCHAR2,
    p_lineage_id IN VARCHAR2
  ) RETURN VARCHAR2 IS
    l_agg_cols   VARCHAR2(32767);
    l_unpivot    VARCHAR2(32767);
    l_sql        VARCHAR2(32767);
  BEGIN
    IF p_attrs.COUNT = 0 THEN RETURN NULL; END IF;

    -- Build aggregation columns and UNPIVOT entries in one pass (in-memory)
    FOR i IN 1 .. p_attrs.COUNT LOOP
      -- SUM(CASE WHEN col IS NULL THEN 1 ELSE 0 END) AS c_N
      l_agg_cols := l_agg_cols
        || '  SUM(CASE WHEN ' || p_attrs(i).canonical_name
        || ' IS NULL THEN 1 ELSE 0 END) AS c_' || i || ',' || CHR(10);

      -- UNPIVOT entry: c_N AS 'canonical_name'
      l_unpivot  := l_unpivot
        || '  c_' || i || ' AS ''' || p_attrs(i).canonical_name || ''''
        || CASE WHEN i < p_attrs.COUNT THEN ',' ELSE '' END || CHR(10);
    END LOOP;

    -- Remove trailing comma from agg_cols
    l_agg_cols := RTRIM(TRIM(l_agg_cols), ',' || CHR(10));

    l_sql :=
      'WITH agg AS ('                                                    || CHR(10)
      || '  SELECT COUNT(*) AS total_rows,'                             || CHR(10)
      || l_agg_cols                                                      || CHR(10)
      || '  FROM ' || p_stk_table                                        || CHR(10)
      || '  WHERE source_vendor = :v'                                    || CHR(10)
      || '  AND   lineage_id   = :l'                                    || CHR(10)
      || '  AND   is_current   = ''Y'''                                 || CHR(10)
      || ')'                                                             || CHR(10)
      || 'SELECT'                                                        || CHR(10)
      || '  alias_enc                                         AS metric_name,'  || CHR(10)
      || '  NULL                                              AS rule_id,'      || CHR(10)
      || '  CASE WHEN null_count > 0 THEN ''FAIL'' ELSE ''PASS'' END AS check_result,' || CHR(10)
      || '  null_count                                        AS actual_value,' || CHR(10)
      || '  0                                                 AS expected_value,' || CHR(10)
      || '  CASE WHEN null_count > 0 THEN ''ALERT'' ELSE ''NONE'' END AS action_taken,' || CHR(10)
      || '  null_count || '' of '' || total_rows || '' rows null'' AS details' || CHR(10)
      || 'FROM agg'                                                      || CHR(10)
      || 'UNPIVOT INCLUDE NULLS (null_count FOR alias_enc IN ('          || CHR(10)
      || l_unpivot
      || '))';

    RETURN l_sql;
  END p_build_not_null_sql;


  -- --------------------------------------------------------------------------
  -- p_build_datatype_sql
  -- One SQL for all VARCHAR-typed metric attributes.
  -- Checks that values conform to the standard coded-value character set:
  -- alphanumeric, space, hyphen, underscore, forward slash, period.
  -- Bind variables: :v (vendor_id), :l (lineage_id)
  -- --------------------------------------------------------------------------
  FUNCTION p_build_datatype_sql (
    p_attrs      IN t_dq_attr_tab,
    p_stk_table  IN VARCHAR2,
    p_vendor_id  IN VARCHAR2,
    p_lineage_id IN VARCHAR2
  ) RETURN VARCHAR2 IS
    l_agg_cols VARCHAR2(32767);
    l_unpivot  VARCHAR2(32767);
    l_sql      VARCHAR2(32767);
  BEGIN
    IF p_attrs.COUNT = 0 THEN RETURN NULL; END IF;

    FOR i IN 1 .. p_attrs.COUNT LOOP
      l_agg_cols := l_agg_cols
        || '  SUM(CASE WHEN ' || p_attrs(i).canonical_name
        || ' IS NOT NULL'
        || ' AND NOT REGEXP_LIKE(' || p_attrs(i).canonical_name
        || ', ''^[A-Za-z0-9 \-_/\.]+$'')'
        || ' THEN 1 ELSE 0 END) AS c_' || i || ',' || CHR(10);

      l_unpivot := l_unpivot
        || '  c_' || i || ' AS ''' || p_attrs(i).canonical_name || ''''
        || CASE WHEN i < p_attrs.COUNT THEN ',' ELSE '' END || CHR(10);
    END LOOP;

    l_agg_cols := RTRIM(TRIM(l_agg_cols), ',' || CHR(10));

    l_sql :=
      'WITH agg AS ('                                                    || CHR(10)
      || '  SELECT COUNT(*) AS total_rows,'                             || CHR(10)
      || l_agg_cols                                                      || CHR(10)
      || '  FROM ' || p_stk_table                                        || CHR(10)
      || '  WHERE source_vendor = :v'                                    || CHR(10)
      || '  AND   lineage_id   = :l'                                    || CHR(10)
      || '  AND   is_current   = ''Y'''                                 || CHR(10)
      || ')'                                                             || CHR(10)
      || 'SELECT'                                                        || CHR(10)
      || '  alias_enc                                           AS metric_name,'  || CHR(10)
      || '  NULL                                                AS rule_id,'      || CHR(10)
      || '  CASE WHEN bad_count > 0 THEN ''FAIL'' ELSE ''PASS'' END AS check_result,' || CHR(10)
      || '  bad_count                                           AS actual_value,' || CHR(10)
      || '  0                                                   AS expected_value,' || CHR(10)
      || '  CASE WHEN bad_count > 0 THEN ''ALERT'' ELSE ''NONE'' END AS action_taken,' || CHR(10)
      || '  bad_count || '' of '' || total_rows || '' rows fail pattern check'' AS details' || CHR(10)
      || 'FROM agg'                                                      || CHR(10)
      || 'UNPIVOT INCLUDE NULLS (bad_count FOR alias_enc IN ('          || CHR(10)
      || l_unpivot
      || '))';

    RETURN l_sql;
  END p_build_datatype_sql;


  -- --------------------------------------------------------------------------
  -- p_build_bounds_sql
  -- One SQL for all BOUNDS rules. Single scan of the stack table.
  -- min_value and max_value embedded as numeric literals from dq_rules
  -- (governed config table — not user input, embedding is safe).
  -- UNPIVOT alias encodes: metric_name|rule_id (pipe-delimited)
  -- Bind variables: :v (vendor_id), :p (coverage_period)
  -- --------------------------------------------------------------------------
  FUNCTION p_build_bounds_sql (
    p_rules     IN t_dq_rule_tab,
    p_stk_table IN VARCHAR2,
    p_vendor_id IN VARCHAR2,
    p_period    IN VARCHAR2
  ) RETURN VARCHAR2 IS
    l_agg_cols VARCHAR2(32767);
    l_unpivot  VARCHAR2(32767);
    l_sql      VARCHAR2(32767);
  BEGIN
    IF p_rules.COUNT = 0 THEN RETURN NULL; END IF;

    FOR i IN 1 .. p_rules.COUNT LOOP
      -- Embed min/max literals; wrap in TO_NUMBER for safety on stored metrics
      l_agg_cols := l_agg_cols
        || '  SUM(CASE WHEN TO_NUMBER(' || p_rules(i).metric_name
        || ') NOT BETWEEN ' || TO_CHAR(p_rules(i).min_value)
        || ' AND ' || TO_CHAR(p_rules(i).max_value)
        || ' THEN 1 ELSE 0 END) AS c_' || i || ',' || CHR(10);

      -- Encode metric_name|rule_id into the UNPIVOT alias
      l_unpivot := l_unpivot
        || '  c_' || i || ' AS '''
        || p_rules(i).metric_name || '|' || p_rules(i).rule_id || ''''
        || CASE WHEN i < p_rules.COUNT THEN ',' ELSE '' END || CHR(10);
    END LOOP;

    l_agg_cols := RTRIM(TRIM(l_agg_cols), ',' || CHR(10));

    l_sql :=
      'WITH agg AS ('                                                    || CHR(10)
      || '  SELECT COUNT(*) AS total_rows,'                             || CHR(10)
      || l_agg_cols                                                      || CHR(10)
      || '  FROM ' || p_stk_table                                        || CHR(10)
      || '  WHERE source_vendor   = :v'                                  || CHR(10)
      || '  AND   coverage_period = :p'                                  || CHR(10)
      || '  AND   is_current      = ''Y'''                              || CHR(10)
      || ')'                                                             || CHR(10)
      || 'SELECT'                                                        || CHR(10)
      || '  REGEXP_SUBSTR(alias_enc,''[^|]+'',1,1)  AS metric_name,'   || CHR(10)
      || '  REGEXP_SUBSTR(alias_enc,''[^|]+'',1,2)  AS rule_id,'       || CHR(10)
      || '  CASE WHEN fail_count > 0 THEN ''FAIL'' ELSE ''PASS'' END AS check_result,' || CHR(10)
      || '  fail_count                               AS actual_value,'  || CHR(10)
      || '  NULL                                     AS expected_value,' || CHR(10)
      || '  NULL                                     AS action_taken,'  || CHR(10)
      || '  fail_count || '' row(s) outside bounds'' AS details'        || CHR(10)
      || 'FROM agg'                                                      || CHR(10)
      || 'UNPIVOT INCLUDE NULLS (fail_count FOR alias_enc IN ('         || CHR(10)
      || l_unpivot
      || '))';

    RETURN l_sql;
  END p_build_bounds_sql;


  -- --------------------------------------------------------------------------
  -- p_build_drift_sql
  -- One SQL covering all DRIFT rules across two coverage periods.
  -- Single stack table scan using conditional aggregation — no UNION ALL.
  -- UNPIVOT alias encodes: metric_name|rule_id|threshold (pipe-delimited)
  -- Bind variables (in order of appearance): :v, :curr, :prior
  -- Both :curr and :prior appear twice — USING clause must list them twice.
  -- --------------------------------------------------------------------------
  FUNCTION p_build_drift_sql (
    p_rules        IN t_dq_rule_tab,
    p_stk_table    IN VARCHAR2,
    p_vendor_id    IN VARCHAR2,
    p_curr_period  IN VARCHAR2,
    p_prior_period IN VARCHAR2
  ) RETURN VARCHAR2 IS
    l_curr_avgs  VARCHAR2(32767);  -- AVG(CASE WHEN period=:curr ...) columns
    l_prior_avgs VARCHAR2(32767);  -- AVG(CASE WHEN period=:prior ...) columns
    l_drift_calcs VARCHAR2(32767); -- drift % calculation per rule
    l_unpivot    VARCHAR2(32767);
    l_sql        VARCHAR2(32767);
  BEGIN
    IF p_rules.COUNT = 0 OR p_prior_period IS NULL THEN RETURN NULL; END IF;

    FOR i IN 1 .. p_rules.COUNT LOOP
      -- Current period AVG
      l_curr_avgs := l_curr_avgs
        || '  AVG(CASE WHEN coverage_period = :curr'
        || '  THEN TO_NUMBER(' || p_rules(i).metric_name || ') END) AS curr_' || i || ',' || CHR(10);

      -- Prior period AVG
      l_prior_avgs := l_prior_avgs
        || '  AVG(CASE WHEN coverage_period = :prior'
        || '  THEN TO_NUMBER(' || p_rules(i).metric_name || ') END) AS prior_' || i || ',' || CHR(10);

      -- Drift % calculation
      l_drift_calcs := l_drift_calcs
        || '  CASE WHEN NVL(prior_' || i || ', 0) = 0 THEN NULL'                    || CHR(10)
        || '       ELSE ABS((curr_' || i || ' - prior_' || i || ')'                 || CHR(10)
        || '                / prior_' || i || ') * 100'                              || CHR(10)
        || '  END AS dp_' || i || ','                                                 || CHR(10);

      -- UNPIVOT alias: metric_name|rule_id|threshold
      l_unpivot := l_unpivot
        || '  dp_' || i || ' AS '''
        || p_rules(i).metric_name || '|'
        || p_rules(i).rule_id     || '|'
        || TO_CHAR(p_rules(i).threshold) || ''''
        || CASE WHEN i < p_rules.COUNT THEN ',' ELSE '' END || CHR(10);
    END LOOP;

    -- Remove trailing commas
    l_curr_avgs   := RTRIM(TRIM(l_curr_avgs),   ',' || CHR(10));
    l_prior_avgs  := RTRIM(TRIM(l_prior_avgs),  ',' || CHR(10));
    l_drift_calcs := RTRIM(TRIM(l_drift_calcs), ',' || CHR(10));

    l_sql :=
      'WITH two_period AS ('                                             || CHR(10)
      || '  SELECT'                                                      || CHR(10)
      || l_curr_avgs                                                     || CHR(10)
      || ','                                                             || CHR(10)
      || l_prior_avgs                                                    || CHR(10)
      || '  FROM ' || p_stk_table                                        || CHR(10)
      || '  WHERE source_vendor   = :v'                                  || CHR(10)
      || '  AND   is_current      = ''Y'''                              || CHR(10)
      || '  AND   coverage_period IN (:curr, :prior)'                   || CHR(10)
      || '),'                                                            || CHR(10)
      || 'drift_pct AS ('                                               || CHR(10)
      || '  SELECT'                                                      || CHR(10)
      || l_drift_calcs                                                   || CHR(10)
      || '  FROM two_period'                                             || CHR(10)
      || ')'                                                             || CHR(10)
      || 'SELECT'                                                        || CHR(10)
      || '  REGEXP_SUBSTR(alias_enc,''[^|]+'',1,1)                       AS metric_name,' || CHR(10)
      || '  REGEXP_SUBSTR(alias_enc,''[^|]+'',1,2)                       AS rule_id,'     || CHR(10)
      || '  CASE WHEN drift_val IS NULL'                                 || CHR(10)
      || '            THEN ''WARNING'''                                   || CHR(10)
      || '       WHEN drift_val > TO_NUMBER(REGEXP_SUBSTR(alias_enc,''[^|]+'',1,3))'      || CHR(10)
      || '            THEN ''FAIL'''                                      || CHR(10)
      || '       ELSE ''PASS'''                                          || CHR(10)
      || '  END                                                          AS check_result,' || CHR(10)
      || '  ROUND(drift_val, 4)                                          AS actual_value,' || CHR(10)
      || '  TO_NUMBER(REGEXP_SUBSTR(alias_enc,''[^|]+'',1,3))            AS expected_value,' || CHR(10)
      || '  NULL                                                          AS action_taken,' || CHR(10)
      || '  ROUND(drift_val, 2) || ''% drift vs prior period''           AS details'       || CHR(10)
      || 'FROM drift_pct'                                                || CHR(10)
      || 'UNPIVOT INCLUDE NULLS (drift_val FOR alias_enc IN ('          || CHR(10)
      || l_unpivot
      || '))';

    RETURN l_sql;
  END p_build_drift_sql;


  -- --------------------------------------------------------------------------
  -- p_build_completeness_sql
  -- One SQL for all COMPLETENESS rules. Single scan.
  -- Uses COUNT(col) which ignores NULLs natively — no CASE expression needed.
  -- UNPIVOT alias encodes: metric_name|rule_id|threshold
  -- Bind variables: :v (vendor_id), :p (coverage_period)
  -- --------------------------------------------------------------------------
  FUNCTION p_build_completeness_sql (
    p_rules     IN t_dq_rule_tab,
    p_stk_table IN VARCHAR2,
    p_vendor_id IN VARCHAR2,
    p_period    IN VARCHAR2
  ) RETURN VARCHAR2 IS
    l_count_cols VARCHAR2(32767);
    l_pct_cols   VARCHAR2(32767);
    l_unpivot    VARCHAR2(32767);
    l_sql        VARCHAR2(32767);
  BEGIN
    IF p_rules.COUNT = 0 THEN RETURN NULL; END IF;

    FOR i IN 1 .. p_rules.COUNT LOOP
      -- COUNT(col) ignores NULLs — gives non-null count directly
      l_count_cols := l_count_cols
        || '  COUNT(' || p_rules(i).metric_name || ') AS c_' || i || ','  || CHR(10);

      -- Percentage in derived table
      l_pct_cols := l_pct_cols
        || '  CASE WHEN total_rows = 0 THEN 100'                           || CHR(10)
        || '       ELSE ROUND(c_' || i || ' * 100.0 / total_rows, 2)'    || CHR(10)
        || '  END AS cp_' || i || ','                                       || CHR(10);

      -- UNPIVOT alias: metric_name|rule_id|threshold
      l_unpivot := l_unpivot
        || '  cp_' || i || ' AS '''
        || p_rules(i).metric_name || '|'
        || p_rules(i).rule_id     || '|'
        || TO_CHAR(p_rules(i).threshold) || ''''
        || CASE WHEN i < p_rules.COUNT THEN ',' ELSE '' END || CHR(10);
    END LOOP;

    l_count_cols  := RTRIM(TRIM(l_count_cols),  ',' || CHR(10));
    l_pct_cols    := RTRIM(TRIM(l_pct_cols),    ',' || CHR(10));

    l_sql :=
      'WITH agg AS ('                                                    || CHR(10)
      || '  SELECT COUNT(*) AS total_rows,'                             || CHR(10)
      || l_count_cols                                                    || CHR(10)
      || '  FROM ' || p_stk_table                                        || CHR(10)
      || '  WHERE source_vendor   = :v'                                  || CHR(10)
      || '  AND   coverage_period = :p'                                  || CHR(10)
      || '  AND   is_current      = ''Y'''                              || CHR(10)
      || '),'                                                            || CHR(10)
      || 'pct AS ('                                                     || CHR(10)
      || '  SELECT total_rows,'                                         || CHR(10)
      || l_pct_cols                                                     || CHR(10)
      || '  FROM agg'                                                   || CHR(10)
      || ')'                                                            || CHR(10)
      || 'SELECT'                                                        || CHR(10)
      || '  REGEXP_SUBSTR(alias_enc,''[^|]+'',1,1)  AS metric_name,'   || CHR(10)
      || '  REGEXP_SUBSTR(alias_enc,''[^|]+'',1,2)  AS rule_id,'       || CHR(10)
      || '  CASE WHEN complete_pct >= TO_NUMBER(REGEXP_SUBSTR(alias_enc,''[^|]+'',1,3))' || CHR(10)
      || '       THEN ''PASS'' ELSE ''FAIL'' END     AS check_result,'  || CHR(10)
      || '  complete_pct                             AS actual_value,'  || CHR(10)
      || '  TO_NUMBER(REGEXP_SUBSTR(alias_enc,''[^|]+'',1,3)) AS expected_value,' || CHR(10)
      || '  NULL                                     AS action_taken,'  || CHR(10)
      || '  ROUND(complete_pct,1) || ''% non-null (threshold='''        || CHR(10)
      || '  || REGEXP_SUBSTR(alias_enc,''[^|]+'',1,3) || ''%)'' AS details' || CHR(10)
      || 'FROM pct'                                                      || CHR(10)
      || 'UNPIVOT INCLUDE NULLS (complete_pct FOR alias_enc IN ('       || CHR(10)
      || l_unpivot
      || '))';

    RETURN l_sql;
  END p_build_completeness_sql;


  -- ==========================================================================
  -- SECTION 4 — EXECUTOR
  -- Runs the built SQL, BULK COLLECTs results, resolves actions, FORALL INSERTs.
  -- ==========================================================================

  PROCEDURE p_execute_and_write (
    p_sql          IN  VARCHAR2,
    p_check_type   IN  VARCHAR2,
    p_check_source IN  VARCHAR2,      -- AUTO_DERIVED or CONFIGURED
    p_rules        IN  t_dq_rule_tab, -- for Tier B action lookup; pass empty for Tier A
    p_source_id    IN  VARCHAR2,
    p_domain_id    IN  VARCHAR2,
    p_vendor_id    IN  VARCHAR2,
    p_period       IN  VARCHAR2,
    p_di_lin_id    IN  VARCHAR2,      -- DI_CHECK lineage_id
    p_load_lin_id  IN  VARCHAR2 DEFAULT NULL,   -- for NOT_NULL / DATA_TYPE
    p_curr_period  IN  VARCHAR2 DEFAULT NULL,   -- for DRIFT
    p_prior_period IN  VARCHAR2 DEFAULT NULL,   -- for DRIFT
    p_rows_written OUT NUMBER
  ) IS
    -- BULK COLLECT targets
    l_metric    t_metric_tab;
    l_rule_id   t_ruleid_tab;
    l_result    t_status_tab;
    l_actual    t_number_tab;
    l_expected  t_number_tab;
    l_action_raw t_action_tab;
    l_details   t_details_tab;

    -- Working collections
    l_action    t_action_tab;
    l_seqs      t_number_tab;
    l_result_ids t_varchar30_tab;
    l_n         PLS_INTEGER;
  BEGIN
    p_rows_written := 0;
    IF p_sql IS NULL THEN RETURN; END IF;

    -- -------------------------------------------------------------------------
    -- STEP 1: BULK COLLECT results from the check SQL
    -- USING clause varies by check type — bind variable sequence must match
    -- the order they appear in the SQL string.
    -- -------------------------------------------------------------------------
    BEGIN
      IF p_check_type IN ('NOT_NULL', 'DATA_TYPE') THEN
        -- Binds: :v (vendor_id), :l (lineage_id)
        EXECUTE IMMEDIATE p_sql
        BULK COLLECT INTO l_metric, l_rule_id, l_result,
                          l_actual, l_expected, l_action_raw, l_details
        USING p_vendor_id, p_load_lin_id;

      ELSIF p_check_type = 'DRIFT' THEN
        -- Binds (in order of appearance in SQL):
        -- :v, :curr, :prior  (in two_period CTE)
        -- :curr, :prior       (in WHERE clause)
        EXECUTE IMMEDIATE p_sql
        BULK COLLECT INTO l_metric, l_rule_id, l_result,
                          l_actual, l_expected, l_action_raw, l_details
        USING p_vendor_id, p_curr_period, p_prior_period,
              p_curr_period, p_prior_period;

      ELSE
        -- BOUNDS and COMPLETENESS: :v (vendor_id), :p (period)
        EXECUTE IMMEDIATE p_sql
        BULK COLLECT INTO l_metric, l_rule_id, l_result,
                          l_actual, l_expected, l_action_raw, l_details
        USING p_vendor_id, p_period;
      END IF;

    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE(
          'ERROR p_execute_and_write check_type=' || p_check_type
          || ': ' || SQLERRM || CHR(10)
          || 'SQL: ' || SUBSTR(p_sql, 1, 500));
        RETURN;  -- Skip this check type; continue to next
    END;

    l_n := NVL(l_metric.COUNT, 0);
    IF l_n = 0 THEN RETURN; END IF;

    -- -------------------------------------------------------------------------
    -- STEP 2: Resolve action column for Tier B checks
    -- Tier A action is already set inline in the builder SQL.
    -- Tier B action comes from dq_rules.action (loaded in p_rules collection).
    -- -------------------------------------------------------------------------
    l_action.DELETE;
    FOR i IN 1 .. l_n LOOP
      IF p_check_source = 'AUTO_DERIVED' THEN
        l_action(i) := l_action_raw(i);

      ELSE  -- CONFIGURED (Tier B)
        IF l_result(i) = 'PASS' THEN
          l_action(i) := 'NONE';
        ELSIF l_result(i) = 'WARNING' THEN
          l_action(i) := 'ALERT';
        ELSE  -- FAIL: look up action from rules collection
          l_action(i) := 'ALERT';  -- default if not found
          FOR j IN 1 .. p_rules.COUNT LOOP
            IF p_rules(j).rule_id = l_rule_id(i) THEN
              l_action(i) := p_rules(j).action;
              EXIT;
            END IF;
          END LOOP;
        END IF;
      END IF;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- STEP 3: Pre-generate all result_id sequence values in one SELECT
    -- -------------------------------------------------------------------------
    SELECT udm_dq_result_seq.NEXTVAL
    BULK COLLECT INTO l_seqs
    FROM dual CONNECT BY ROWNUM <= l_n;

    l_result_ids.DELETE;
    FOR i IN 1 .. l_n LOOP
      l_result_ids(i) := 'DQR-' || TO_CHAR(SYSDATE, 'YYYYMMDD')
                        || '-' || LPAD(l_seqs(i), 8, '0');
    END LOOP;

    -- -------------------------------------------------------------------------
    -- STEP 4: FORALL INSERT — one statement for all results
    -- -------------------------------------------------------------------------
    FORALL i IN 1 .. l_n
      INSERT INTO udm_dq_results (
        result_id,   lineage_id,    rule_id,
        check_type,  check_source,  domain_id,
        source_id,   metric_name,   movement_point,
        check_result, actual_value, expected_value,
        entity_key,  coverage_period, action_taken, checked_at
      ) VALUES (
        l_result_ids(i), p_di_lin_id,  l_rule_id(i),
        p_check_type,    p_check_source, p_domain_id,
        p_source_id,     l_metric(i),    'STAGE_TO_VS',
        l_result(i),     l_actual(i),    l_expected(i),
        NULL,            p_period,        l_action(i),    SYSDATE
      );

    p_rows_written := l_n;

  EXCEPTION
    WHEN OTHERS THEN
      RAISE_APPLICATION_ERROR(-20310,
        'p_execute_and_write FORALL INSERT failed for check_type='
        || p_check_type || ': ' || SQLERRM);
  END p_execute_and_write;


  -- ==========================================================================
  -- SECTION 5 — DRIFT NO-PRIOR-PERIOD HANDLER
  -- When no prior period found, write WARNING rows without executing SQL.
  -- Uses FORALL INSERT on pre-collected rule data.
  -- ==========================================================================

  PROCEDURE p_write_drift_warnings (
    p_rules     IN t_dq_rule_tab,
    p_source_id IN VARCHAR2,
    p_domain_id IN VARCHAR2,
    p_vendor_id IN VARCHAR2,
    p_period    IN VARCHAR2,
    p_di_lin_id IN VARCHAR2,
    p_rows_written OUT NUMBER
  ) IS
    l_n          PLS_INTEGER := p_rules.COUNT;
    l_seqs       t_number_tab;
    l_result_ids t_varchar30_tab;
    l_metrics    t_metric_tab;
    l_rule_ids   t_ruleid_tab;
    l_expected   t_number_tab;
  BEGIN
    p_rows_written := 0;
    IF l_n = 0 THEN RETURN; END IF;

    -- Pre-collect rule data into indexed arrays for FORALL
    FOR i IN 1 .. l_n LOOP
      l_metrics(i)  := p_rules(i).metric_name;
      l_rule_ids(i) := p_rules(i).rule_id;
      l_expected(i) := p_rules(i).threshold;
    END LOOP;

    SELECT udm_dq_result_seq.NEXTVAL
    BULK COLLECT INTO l_seqs
    FROM dual CONNECT BY ROWNUM <= l_n;

    FOR i IN 1 .. l_n LOOP
      l_result_ids(i) := 'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD')
                        || '-' || LPAD(l_seqs(i), 8, '0');
    END LOOP;

    FORALL i IN 1 .. l_n
      INSERT INTO udm_dq_results (
        result_id,    lineage_id,    rule_id,
        check_type,   check_source,  domain_id,
        source_id,    metric_name,   movement_point,
        check_result, actual_value,  expected_value,
        entity_key,   coverage_period, action_taken, checked_at
      ) VALUES (
        l_result_ids(i), p_di_lin_id,  l_rule_ids(i),
        'DRIFT',          'CONFIGURED', p_domain_id,
        p_source_id,      l_metrics(i), 'STAGE_TO_VS',
        'WARNING',        NULL,          l_expected(i),
        NULL,             p_period,     'ALERT',          SYSDATE
      );

    p_rows_written := l_n;
  END p_write_drift_warnings;


  -- ==========================================================================
  -- SECTION 6 — PUBLIC PROCEDURES
  -- ==========================================================================

  PROCEDURE run_checks (
    p_source_id  IN VARCHAR2,
    p_lineage_id IN VARCHAR2
  ) IS
    -- Source metadata
    l_src_rec       udm_source_registry%ROWTYPE;
    l_stk_table     VARCHAR2(128);
    l_period        VARCHAR2(20);
    l_prior_period  VARCHAR2(20);

    -- Metadata collections
    l_nn_attrs    t_dq_attr_tab;
    l_dt_attrs    t_dq_attr_tab;
    l_bounds_rules t_dq_rule_tab;
    l_drift_rules  t_dq_rule_tab;
    l_comp_rules   t_dq_rule_tab;

    -- Built SQL strings
    l_sql        VARCHAR2(32767);

    -- Lineage
    l_di_lin_id  VARCHAR2(30);
    l_rows       NUMBER := 0;
    l_total_rows NUMBER := 0;

    -- Empty rule table for Tier A calls
    l_empty_rules t_dq_rule_tab;

  BEGIN
    -- -------------------------------------------------------------------------
    -- STEP 1: Load source metadata
    -- -------------------------------------------------------------------------
    BEGIN
      SELECT * INTO l_src_rec
      FROM   udm_source_registry
      WHERE  source_id = p_source_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20300,
          'Source not found in source_registry: ' || p_source_id);
    END;

    l_stk_table := 'udm.udm_'
      || LOWER(REPLACE(l_src_rec.domain_id, '-', '_')) || '_stk';

    -- Get coverage_period from the parent LOAD lineage row
    BEGIN
      SELECT coverage_period INTO l_period
      FROM   udm_lineage
      WHERE  lineage_id = p_lineage_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20302,
          'Parent LOAD lineage_id not found: ' || p_lineage_id);
    END;

    -- -------------------------------------------------------------------------
    -- STEP 2: Open DI_CHECK lineage row
    -- -------------------------------------------------------------------------
    l_di_lin_id := udm_pkg_lineage.open_batch(
      p_lineage_type    => 'DI_CHECK',
      p_source_id       => p_source_id,
      p_domain_id       => l_src_rec.domain_id,
      p_vendor_id       => l_src_rec.vendor_id,
      p_coverage_period => l_period
    );

    -- -------------------------------------------------------------------------
    -- STEP 3: TIER A — NOT_NULL
    -- -------------------------------------------------------------------------
    p_load_tier_a_attrs(p_source_id, 'NOT_NULL', l_nn_attrs);
    l_sql := p_build_not_null_sql(
      l_nn_attrs, l_stk_table, l_src_rec.vendor_id, p_lineage_id);
    p_execute_and_write(
      l_sql, 'NOT_NULL', 'AUTO_DERIVED', l_empty_rules,
      p_source_id, l_src_rec.domain_id, l_src_rec.vendor_id,
      l_period, l_di_lin_id,
      p_load_lin_id => p_lineage_id,
      p_rows_written => l_rows);
    l_total_rows := l_total_rows + l_rows;

    -- -------------------------------------------------------------------------
    -- STEP 4: TIER A — DATA_TYPE
    -- -------------------------------------------------------------------------
    p_load_tier_a_attrs(p_source_id, 'DATA_TYPE', l_dt_attrs);
    l_sql := p_build_datatype_sql(
      l_dt_attrs, l_stk_table, l_src_rec.vendor_id, p_lineage_id);
    p_execute_and_write(
      l_sql, 'DATA_TYPE', 'AUTO_DERIVED', l_empty_rules,
      p_source_id, l_src_rec.domain_id, l_src_rec.vendor_id,
      l_period, l_di_lin_id,
      p_load_lin_id => p_lineage_id,
      p_rows_written => l_rows);
    l_total_rows := l_total_rows + l_rows;

    -- -------------------------------------------------------------------------
    -- STEP 5: TIER B — BOUNDS
    -- -------------------------------------------------------------------------
    p_load_tier_b_rules(l_src_rec.domain_id, 'BOUNDS', l_bounds_rules);
    l_sql := p_build_bounds_sql(
      l_bounds_rules, l_stk_table, l_src_rec.vendor_id, l_period);
    p_execute_and_write(
      l_sql, 'BOUNDS', 'CONFIGURED', l_bounds_rules,
      p_source_id, l_src_rec.domain_id, l_src_rec.vendor_id,
      l_period, l_di_lin_id,
      p_rows_written => l_rows);
    l_total_rows := l_total_rows + l_rows;

    -- -------------------------------------------------------------------------
    -- STEP 6: TIER B — DRIFT
    -- -------------------------------------------------------------------------
    p_load_tier_b_rules(l_src_rec.domain_id, 'DRIFT', l_drift_rules);
    l_prior_period := p_get_prior_period(p_source_id, l_period);

    IF l_drift_rules.COUNT > 0 AND l_prior_period IS NULL THEN
      -- No prior period — write WARNING rows without hitting the stack table
      p_write_drift_warnings(
        l_drift_rules, p_source_id, l_src_rec.domain_id,
        l_src_rec.vendor_id, l_period, l_di_lin_id, l_rows);
      l_total_rows := l_total_rows + l_rows;
    ELSE
      l_sql := p_build_drift_sql(
        l_drift_rules, l_stk_table, l_src_rec.vendor_id,
        l_period, l_prior_period);
      p_execute_and_write(
        l_sql, 'DRIFT', 'CONFIGURED', l_drift_rules,
        p_source_id, l_src_rec.domain_id, l_src_rec.vendor_id,
        l_period, l_di_lin_id,
        p_curr_period  => l_period,
        p_prior_period => l_prior_period,
        p_rows_written => l_rows);
      l_total_rows := l_total_rows + l_rows;
    END IF;

    -- -------------------------------------------------------------------------
    -- STEP 7: TIER B — COMPLETENESS
    -- -------------------------------------------------------------------------
    p_load_tier_b_rules(l_src_rec.domain_id, 'COMPLETENESS', l_comp_rules);
    l_sql := p_build_completeness_sql(
      l_comp_rules, l_stk_table, l_src_rec.vendor_id, l_period);
    p_execute_and_write(
      l_sql, 'COMPLETENESS', 'CONFIGURED', l_comp_rules,
      p_source_id, l_src_rec.domain_id, l_src_rec.vendor_id,
      l_period, l_di_lin_id,
      p_rows_written => l_rows);
    l_total_rows := l_total_rows + l_rows;

    -- -------------------------------------------------------------------------
    -- STEP 8: Commit and close lineage
    -- -------------------------------------------------------------------------
    COMMIT;
    udm_pkg_lineage.close_batch(
      l_di_lin_id, 'COMPLETE',
      p_rows_written => l_total_rows);

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      IF l_di_lin_id IS NOT NULL THEN
        udm_pkg_lineage.close_batch(l_di_lin_id, 'FAILED',
          p_error_message => SQLERRM);
      END IF;
      RAISE;
  END run_checks;


  -- --------------------------------------------------------------------------
  -- run_domain_checks
  -- Iterates all sources for a domain that have a COMPLETE LOAD lineage row.
  -- Skips any source with no COMPLETE load — nothing to check.
  -- --------------------------------------------------------------------------
  PROCEDURE run_domain_checks (p_domain_id IN VARCHAR2) IS
    CURSOR c_sources IS
      SELECT DISTINCT sr.source_id, l.lineage_id, l.coverage_period
      FROM   udm_source_registry sr
      JOIN   udm_lineage          l  ON l.source_id   = sr.source_id
                                    AND l.lineage_type = 'LOAD'
                                    AND l.status       = 'COMPLETE'
      WHERE  sr.domain_id         = p_domain_id
      AND    sr.governance_status IN ('UDM_CATALOGED', 'MIGRATING')
      AND    sr.source_role       = 'DATA_SOURCE'
      AND    sr.effective_to IS NULL
      -- Get only the most recent COMPLETE LOAD per source
      AND    l.lineage_id = (
               SELECT lineage_id FROM udm_lineage l2
               WHERE  l2.source_id    = sr.source_id
               AND    l2.lineage_type = 'LOAD'
               AND    l2.status       = 'COMPLETE'
               AND    l2.lineage_id   NOT IN (
                        SELECT NVL(lineage_id,'~')
                        FROM   udm_dq_results
                        WHERE  source_id = sr.source_id
                        AND    ROWNUM    = 1
                      )
               AND    ROWNUM = 1
               ORDER  BY l2.started_at DESC
             );
  BEGIN
    FOR src IN c_sources LOOP
      BEGIN
        run_checks(src.source_id, src.lineage_id);
      EXCEPTION
        WHEN OTHERS THEN
          DBMS_OUTPUT.PUT_LINE(
            'ERROR run_domain_checks: skipping source '
            || src.source_id || ': ' || SQLERRM);
      END;
    END LOOP;
  END run_domain_checks;

END udm_pkg_di;
/
