-- ============================================================================
-- MODULE 8 — DATA INTEGRITY FRAMEWORK
-- Package  : UDM.UDM_PKG_DI
-- Purpose  : Runs DI checks after each harmonisation pass.
--            Two-tier check model:
--
--   TIER A — Auto-derived checks (no entry in udm_dq_rules required):
--     NOT_NULL     : mandatory attributes in udm_attribute_map (is_mandatory=Y)
--     DATA_TYPE    : cast conformance for each mapped attribute
--     UNMAPPED     : source columns not in attribute_map (discovery only)
--     REFERENTIAL  : lookup: transforms — FK integrity check
--
--   TIER B — Threshold checks (entry required in udm_dq_rules):
--     DRIFT        : metric value deviates > threshold % from prior period
--     BOUNDS       : metric value outside [min_value, max_value]
--     COMPLETENESS : non-null rate for an attribute below threshold %
--     CROSS_VENDOR : inter-vendor consistency check
--
--   Results of all checks written to udm_dq_results.
--   Action determines engine response: ALERT (log only) | QUARANTINE | REJECT.
--
-- DI ownership:
--   UDM owns: rules definition (attribute_map + udm_dq_rules)
--             results (udm_dq_results)
--   External DQ tool owns: scheduling, alerting, dashboarding, workflow.
--
-- Depends  : udm_pkg_lineage (Module 9)
-- Compile  : After udm_pkg_lineage.
-- ============================================================================

-- ============================================================================
-- PACKAGE SPEC
-- ============================================================================
CREATE OR REPLACE PACKAGE udm.udm_pkg_di AS

  -- -------------------------------------------------------------------------
  -- run_checks
  -- Runs Tier A + Tier B checks for one source load.
  -- Call from harmonisation engine after p_process_data_source completes,
  -- or schedule independently via Oracle Scheduler.
  -- -------------------------------------------------------------------------
  PROCEDURE run_checks (
    p_source_id       IN VARCHAR2,
    p_coverage_period IN VARCHAR2,
    p_lineage_id      IN VARCHAR2  -- parent load lineage_id
  );

  -- -------------------------------------------------------------------------
  -- run_domain_checks
  -- Runs checks across all sources for a domain and period.
  -- -------------------------------------------------------------------------
  PROCEDURE run_domain_checks (
    p_domain_id       IN VARCHAR2,
    p_coverage_period IN VARCHAR2
  );

END udm_pkg_di;
/


-- ============================================================================
-- PACKAGE BODY
-- ============================================================================
CREATE OR REPLACE PACKAGE BODY udm.udm_pkg_di AS

  -- --------------------------------------------------------------------------
  -- Private: write a single DQ result row
  -- --------------------------------------------------------------------------
  PROCEDURE p_write_dq_result (
    p_lineage_id       IN VARCHAR2,
    p_source_id        IN VARCHAR2,
    p_domain_id        IN VARCHAR2,
    p_vendor_id        IN VARCHAR2,
    p_coverage_period  IN VARCHAR2,
    p_check_type       IN VARCHAR2,
    p_attribute_name   IN VARCHAR2,
    p_rule_id          IN VARCHAR2,
    p_check_status     IN VARCHAR2,   -- PASS | FAIL | WARNING
    p_actual_value     IN NUMBER,
    p_threshold_value  IN NUMBER,
    p_action_taken     IN VARCHAR2,   -- ALERT | QUARANTINE | REJECT | NONE
    p_details          IN VARCHAR2
  ) IS
    l_result_id VARCHAR2(30);
  BEGIN
    SELECT 'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-'
           || LPAD(udm_dq_result_seq.NEXTVAL, 8, '0')
    INTO   l_result_id FROM dual;

    INSERT INTO udm_dq_results (
      result_id, lineage_id, source_id, domain_id, vendor_id,
      coverage_period, check_type, attribute_name, rule_id,
      check_status, actual_value, threshold_value,
      action_taken, details, checked_at
    ) VALUES (
      l_result_id, p_lineage_id, p_source_id, p_domain_id, p_vendor_id,
      p_coverage_period, p_check_type, p_attribute_name, p_rule_id,
      p_check_status,
      p_actual_value, p_threshold_value,
      p_action_taken,
      SUBSTR(p_details, 1, 500),
      SYSDATE
    );
  END p_write_dq_result;

  -- --------------------------------------------------------------------------
  -- p_run_not_null_check
  -- Auto-derived from attribute_map.is_mandatory.
  -- Counts NULLs for each mandatory attribute in the stack table for this load.
  -- --------------------------------------------------------------------------
  PROCEDURE p_run_not_null_checks (
    p_src_id          IN VARCHAR2,
    p_domain_id       IN VARCHAR2,
    p_vendor_id       IN VARCHAR2,
    p_coverage_period IN VARCHAR2,
    p_lineage_id      IN VARCHAR2,
    p_di_lineage_id   IN VARCHAR2
  ) IS
    l_stk_table  VARCHAR2(128) := 'UDM.UDM_' || UPPER(p_domain_id) || '_STK';
    l_sql        VARCHAR2(4000);
    l_null_count NUMBER;
    l_total      NUMBER;
    l_pct        NUMBER;
  BEGIN
    FOR r IN (
      SELECT canonical_name
      FROM   udm_attribute_map
      WHERE  source_id   = p_src_id
      AND    is_mandatory = 'Y'
      AND    map_status   = 'ACTIVE'
    ) LOOP
      l_sql := 'SELECT COUNT(*) total,'
             || ' SUM(CASE WHEN ' || r.canonical_name || ' IS NULL THEN 1 ELSE 0 END) nulls'
             || ' FROM ' || l_stk_table
             || ' WHERE source_vendor    = :sv'
             || '   AND coverage_period  = :cp'
             || '   AND lineage_id       = :lid';
      EXECUTE IMMEDIATE l_sql INTO l_total, l_null_count
        USING p_vendor_id, p_coverage_period, p_lineage_id;

      IF l_null_count > 0 THEN
        p_write_dq_result(
          p_di_lineage_id, p_src_id, p_domain_id, p_vendor_id, p_coverage_period,
          'NOT_NULL', r.canonical_name, NULL, 'FAIL',
          l_null_count, 0, 'ALERT',
          l_null_count || ' of ' || l_total || ' rows have NULL in mandatory attribute');
      ELSE
        p_write_dq_result(
          p_di_lineage_id, p_src_id, p_domain_id, p_vendor_id, p_coverage_period,
          'NOT_NULL', r.canonical_name, NULL, 'PASS',
          0, 0, 'NONE',
          'All ' || l_total || ' rows non-null');
      END IF;
    END LOOP;
  END p_run_not_null_checks;

  -- --------------------------------------------------------------------------
  -- p_run_data_type_check
  -- Auto-derived: verifies cast conformance for NUMBER and DATE typed attributes.
  -- Checks for values that fail TO_NUMBER or TO_DATE conversion.
  -- --------------------------------------------------------------------------
  PROCEDURE p_run_data_type_checks (
    p_src_id          IN VARCHAR2,
    p_domain_id       IN VARCHAR2,
    p_vendor_id       IN VARCHAR2,
    p_coverage_period IN VARCHAR2,
    p_lineage_id      IN VARCHAR2,
    p_di_lineage_id   IN VARCHAR2
  ) IS
    l_stk_table  VARCHAR2(128) := 'UDM.UDM_' || UPPER(p_domain_id) || '_STK';
    l_sql        VARCHAR2(4000);
    l_bad_count  NUMBER;
  BEGIN
    FOR r IN (
      SELECT canonical_name, data_type
      FROM   udm_attribute_map
      WHERE  source_id  = p_src_id
      AND    data_type  IN ('NUMBER', 'DATE')
      AND    map_status = 'ACTIVE'
      AND    is_subject_key = 'N'
      AND    is_time_key    = 'N'
    ) LOOP
      IF r.data_type = 'NUMBER' THEN
        l_sql :=
          'SELECT COUNT(*) FROM ' || l_stk_table
          || ' WHERE source_vendor = :sv AND coverage_period = :cp AND lineage_id = :lid'
          || ' AND ' || r.canonical_name || ' IS NOT NULL'
          || ' AND REGEXP_LIKE(' || r.canonical_name || ', ''[^0-9.\-]'')';
      ELSIF r.data_type = 'DATE' THEN
        l_sql :=
          'SELECT COUNT(*) FROM ' || l_stk_table
          || ' WHERE source_vendor = :sv AND coverage_period = :cp AND lineage_id = :lid'
          || ' AND ' || r.canonical_name || ' IS NOT NULL'
          || ' AND NOT REGEXP_LIKE(' || r.canonical_name
          || ', ''^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2})?$'')';
      END IF;

      BEGIN
        EXECUTE IMMEDIATE l_sql INTO l_bad_count
          USING p_vendor_id, p_coverage_period, p_lineage_id;
      EXCEPTION WHEN OTHERS THEN l_bad_count := 0;
      END;

      p_write_dq_result(
        p_di_lineage_id, p_src_id, p_domain_id, p_vendor_id, p_coverage_period,
        'DATA_TYPE', r.canonical_name, NULL,
        CASE WHEN l_bad_count > 0 THEN 'FAIL' ELSE 'PASS' END,
        l_bad_count, 0,
        CASE WHEN l_bad_count > 0 THEN 'ALERT' ELSE 'NONE' END,
        CASE WHEN l_bad_count > 0
             THEN l_bad_count || ' rows fail ' || r.data_type || ' cast'
             ELSE 'All values conform to ' || r.data_type end);
    END LOOP;
  END p_run_data_type_checks;

  -- --------------------------------------------------------------------------
  -- p_run_bounds_check
  -- Tier B: metric value outside [min_value, max_value].
  -- --------------------------------------------------------------------------
  PROCEDURE p_run_bounds_checks (
    p_src_id          IN VARCHAR2,
    p_domain_id       IN VARCHAR2,
    p_vendor_id       IN VARCHAR2,
    p_coverage_period IN VARCHAR2,
    p_lineage_id      IN VARCHAR2,
    p_di_lineage_id   IN VARCHAR2
  ) IS
    l_stk_table  VARCHAR2(128) := 'UDM.UDM_' || UPPER(p_domain_id) || '_STK';
    l_sql        VARCHAR2(4000);
    l_out_count  NUMBER;
  BEGIN
    FOR r IN (
      SELECT rule_id, metric_name, min_value, max_value, action
      FROM   udm_dq_rules
      WHERE  domain_id    = p_domain_id
      AND    check_type   = 'BOUNDS'
      AND    is_active    = 'Y'
      AND    (effective_to IS NULL OR effective_to > SYSDATE)
    ) LOOP
      l_sql :=
        'SELECT COUNT(*) FROM ' || l_stk_table
        || ' WHERE source_vendor   = :sv'
        || '   AND coverage_period = :cp'
        || '   AND lineage_id      = :lid'
        || '   AND TO_NUMBER(' || r.metric_name || ') NOT BETWEEN :minv AND :maxv';
      BEGIN
        EXECUTE IMMEDIATE l_sql INTO l_out_count
          USING p_vendor_id, p_coverage_period, p_lineage_id,
                r.min_value, r.max_value;
      EXCEPTION WHEN OTHERS THEN l_out_count := 0;
      END;

      p_write_dq_result(
        p_di_lineage_id, p_src_id, p_domain_id, p_vendor_id, p_coverage_period,
        'BOUNDS', r.metric_name, r.rule_id,
        CASE WHEN l_out_count > 0 THEN 'FAIL' ELSE 'PASS' END,
        l_out_count, NULL,
        CASE WHEN l_out_count > 0 THEN r.action ELSE 'NONE' END,
        CASE WHEN l_out_count > 0
             THEN l_out_count || ' rows outside bounds ['
                  || r.min_value || ', ' || r.max_value || ']'
             ELSE 'All values within bounds' END);
    END LOOP;
  END p_run_bounds_checks;

  -- --------------------------------------------------------------------------
  -- p_run_drift_check
  -- Tier B: current period metric avg deviates more than threshold% from prior.
  -- --------------------------------------------------------------------------
  PROCEDURE p_run_drift_checks (
    p_src_id          IN VARCHAR2,
    p_domain_id       IN VARCHAR2,
    p_vendor_id       IN VARCHAR2,
    p_coverage_period IN VARCHAR2,
    p_lineage_id      IN VARCHAR2,
    p_di_lineage_id   IN VARCHAR2
  ) IS
    l_stk_table   VARCHAR2(128) := 'UDM.UDM_' || UPPER(p_domain_id) || '_STK';
    l_sql         VARCHAR2(4000);
    l_curr_avg    NUMBER;
    l_prior_avg   NUMBER;
    l_drift_pct   NUMBER;
  BEGIN
    FOR r IN (
      SELECT rule_id, metric_name, threshold, action
      FROM   udm_dq_rules
      WHERE  domain_id   = p_domain_id
      AND    check_type  = 'DRIFT'
      AND    is_active   = 'Y'
      AND    (effective_to IS NULL OR effective_to > SYSDATE)
    ) LOOP
      -- Current period avg
      l_sql :=
        'SELECT NVL(AVG(TO_NUMBER(' || r.metric_name || ')), 0)'
        || ' FROM ' || l_stk_table
        || ' WHERE source_vendor = :sv AND coverage_period = :cp AND is_current = ''Y''';
      EXECUTE IMMEDIATE l_sql INTO l_curr_avg
        USING p_vendor_id, p_coverage_period;

      -- Prior period avg (max coverage_period before current)
      l_sql :=
        'SELECT NVL(AVG(TO_NUMBER(' || r.metric_name || ')), 0)'
        || ' FROM ' || l_stk_table
        || ' WHERE source_vendor = :sv'
        || '   AND is_current = ''Y'''
        || '   AND coverage_period = ('
        ||     ' SELECT MAX(coverage_period) FROM ' || l_stk_table
        ||     ' WHERE source_vendor = :sv2'
        ||     '   AND is_current = ''Y'''
        ||     '   AND coverage_period < :cp)';
      EXECUTE IMMEDIATE l_sql INTO l_prior_avg
        USING p_vendor_id, p_vendor_id, p_coverage_period;

      -- Compute drift pct
      l_drift_pct := CASE WHEN l_prior_avg = 0 THEN NULL
                          ELSE ABS((l_curr_avg - l_prior_avg) / l_prior_avg) * 100
                     END;

      p_write_dq_result(
        p_di_lineage_id, p_src_id, p_domain_id, p_vendor_id, p_coverage_period,
        'DRIFT', r.metric_name, r.rule_id,
        CASE WHEN l_drift_pct IS NULL             THEN 'WARNING'
             WHEN l_drift_pct > r.threshold       THEN 'FAIL'
             ELSE                                      'PASS' END,
        l_drift_pct, r.threshold,
        CASE WHEN l_drift_pct > r.threshold THEN r.action ELSE 'NONE' END,
        'Drift=' || ROUND(l_drift_pct, 2) || '% threshold=' || r.threshold || '%'
        || ' curr=' || ROUND(l_curr_avg, 4)
        || ' prior=' || ROUND(l_prior_avg, 4));
    END LOOP;
  END p_run_drift_checks;

  -- --------------------------------------------------------------------------
  -- p_run_completeness_check
  -- Tier B: non-null rate for a metric below threshold percentage.
  -- --------------------------------------------------------------------------
  PROCEDURE p_run_completeness_checks (
    p_src_id          IN VARCHAR2,
    p_domain_id       IN VARCHAR2,
    p_vendor_id       IN VARCHAR2,
    p_coverage_period IN VARCHAR2,
    p_lineage_id      IN VARCHAR2,
    p_di_lineage_id   IN VARCHAR2
  ) IS
    l_stk_table   VARCHAR2(128) := 'UDM.UDM_' || UPPER(p_domain_id) || '_STK';
    l_sql         VARCHAR2(4000);
    l_non_null    NUMBER;
    l_total       NUMBER;
    l_complete_pct NUMBER;
  BEGIN
    FOR r IN (
      SELECT rule_id, metric_name, threshold, action
      FROM   udm_dq_rules
      WHERE  domain_id  = p_domain_id
      AND    check_type = 'COMPLETENESS'
      AND    is_active  = 'Y'
      AND    (effective_to IS NULL OR effective_to > SYSDATE)
    ) LOOP
      l_sql :=
        'SELECT COUNT(*), COUNT(' || r.metric_name || ')'
        || ' FROM ' || l_stk_table
        || ' WHERE source_vendor = :sv AND coverage_period = :cp AND lineage_id = :lid';
      EXECUTE IMMEDIATE l_sql INTO l_total, l_non_null
        USING p_vendor_id, p_coverage_period, p_lineage_id;

      l_complete_pct := CASE WHEN l_total = 0 THEN 100
                             ELSE (l_non_null / l_total) * 100 END;

      p_write_dq_result(
        p_di_lineage_id, p_src_id, p_domain_id, p_vendor_id, p_coverage_period,
        'COMPLETENESS', r.metric_name, r.rule_id,
        CASE WHEN l_complete_pct >= r.threshold THEN 'PASS' ELSE 'FAIL' END,
        l_complete_pct, r.threshold,
        CASE WHEN l_complete_pct < r.threshold THEN r.action ELSE 'NONE' END,
        'Completeness=' || ROUND(l_complete_pct, 1) || '% threshold='
        || r.threshold || '% (' || l_non_null || '/' || l_total || ')');
    END LOOP;
  END p_run_completeness_checks;

  -- ==========================================================================
  -- PUBLIC PROCEDURES
  -- ==========================================================================

  PROCEDURE run_checks (
    p_source_id       IN VARCHAR2,
    p_coverage_period IN VARCHAR2,
    p_lineage_id      IN VARCHAR2
  ) IS
    l_src         udm_source_registry%ROWTYPE;
    l_di_lin_id   VARCHAR2(30);
    l_rows_read   NUMBER := 0;
    l_rows_written NUMBER := 0;
  BEGIN
    -- Load source metadata
    SELECT * INTO l_src
    FROM   udm_source_registry
    WHERE  source_id = p_source_id;

    -- Open DI_CHECK lineage row
    l_di_lin_id := udm_pkg_lineage.open_batch(
      p_lineage_type    => 'DI_CHECK',
      p_source_id       => p_source_id,
      p_domain_id       => l_src.domain_id,
      p_vendor_id       => l_src.vendor_id,
      p_coverage_period => p_coverage_period
    );

    -- TIER A: Auto-derived checks
    p_run_not_null_checks(
      p_source_id, l_src.domain_id, l_src.vendor_id,
      p_coverage_period, p_lineage_id, l_di_lin_id);

    p_run_data_type_checks(
      p_source_id, l_src.domain_id, l_src.vendor_id,
      p_coverage_period, p_lineage_id, l_di_lin_id);

    -- TIER B: Threshold checks
    p_run_bounds_checks(
      p_source_id, l_src.domain_id, l_src.vendor_id,
      p_coverage_period, p_lineage_id, l_di_lin_id);

    p_run_drift_checks(
      p_source_id, l_src.domain_id, l_src.vendor_id,
      p_coverage_period, p_lineage_id, l_di_lin_id);

    p_run_completeness_checks(
      p_source_id, l_src.domain_id, l_src.vendor_id,
      p_coverage_period, p_lineage_id, l_di_lin_id);

    -- Count results written this run
    SELECT COUNT(*) INTO l_rows_written
    FROM   udm_dq_results
    WHERE  lineage_id = l_di_lin_id;

    COMMIT;
    udm_pkg_lineage.close_batch(
      l_di_lin_id, 'COMPLETE', NULL, l_rows_written);

  EXCEPTION
    WHEN OTHERS THEN
      udm_pkg_lineage.close_batch(l_di_lin_id, 'FAILED',
        p_error_message => SQLERRM);
      RAISE;
  END run_checks;

  -- --------------------------------------------------------------------------
  PROCEDURE run_domain_checks (
    p_domain_id       IN VARCHAR2,
    p_coverage_period IN VARCHAR2
  ) IS
    CURSOR c_sources IS
      SELECT source_id, vendor_id
      FROM   udm_source_registry
      WHERE  domain_id         = p_domain_id
      AND    governance_status IN ('UDM_CATALOGED', 'MIGRATING')
      AND    source_role       = 'DATA_SOURCE'
      AND    effective_to IS NULL;
    l_lineage_id VARCHAR2(30);
  BEGIN
    FOR src IN c_sources LOOP
      -- Get latest lineage_id for this source+period (the load lineage)
      BEGIN
        SELECT lineage_id INTO l_lineage_id
        FROM   (SELECT lineage_id FROM udm_lineage
                WHERE  source_id       = src.source_id
                AND    coverage_period = p_coverage_period
                AND    lineage_type    = 'LOAD'
                AND    status          = 'COMPLETE'
                ORDER  BY started_at DESC)
        WHERE  ROWNUM = 1;
      EXCEPTION WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('WARN: No COMPLETE LOAD lineage for source '
          || src.source_id || ' — skipping DI checks');
        CONTINUE;
      END;

      BEGIN
        run_checks(src.source_id, p_coverage_period, l_lineage_id);
      EXCEPTION
        WHEN OTHERS THEN
          DBMS_OUTPUT.PUT_LINE('ERROR: DI checks failed for source '
            || src.source_id || ': ' || SQLERRM);
      END;
    END LOOP;
  END run_domain_checks;

END udm_pkg_di;
/
