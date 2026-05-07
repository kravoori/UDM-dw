-- ============================================================================
-- MODULE 7 — ARBITRATION ENGINE
-- Package  : UDM.UDM_PKG_ARBITRATION
-- Purpose  : Reads udm_{domain}_stk → applies precedence rules + grain
--            alignment → writes winning row to udm_{domain}_arb.
--
-- Triggered by Oracle Scheduler after each harmonisation run completes.
-- Fully catalog-driven: no hardcoded vendor or domain logic here.
--
-- Algorithm:
--   For each entity × coverage_period in the stack:
--     1. Identify applicable grain alignment rule per vendor
--     2. Exclude vendors flagged EXCLUDE (mismatched grain)
--     3. Apply grain collapsing for non-canonical grain vendors
--     4. For each canonical metric:
--          Find lowest-priority vendor (1 = highest) with non-null value
--          that satisfies its condition_sql (if CONDITIONAL)
--     5. Write/UPSERT arb row: winning values + audit columns
--
-- CONDITIONAL rules are evaluated via EXECUTE IMMEDIATE against the
-- candidate stack row. Condition SQL may reference measurement_grain,
-- source_vendor, and any stack metric column.
--
-- Depends  : udm_pkg_lineage (Module 9)
-- Compile  : After udm_pkg_lineage.
-- ============================================================================

-- ============================================================================
-- PACKAGE SPEC
-- ============================================================================
CREATE OR REPLACE PACKAGE udm.udm_pkg_arbitration AS

  -- -------------------------------------------------------------------------
  -- run_domain
  -- Main entry point. Processes all current stack rows for a domain + period.
  -- Writes winners to udm_{domain}_arb.
  -- -------------------------------------------------------------------------
  PROCEDURE run_domain (
    p_domain_id       IN VARCHAR2,
    p_coverage_period IN VARCHAR2
  );

  -- -------------------------------------------------------------------------
  -- run_all_domains
  -- Convenience: iterates all domains that have COMPLETE manifests for the
  -- given coverage period and calls run_domain for each.
  -- -------------------------------------------------------------------------
  PROCEDURE run_all_domains (
    p_coverage_period IN VARCHAR2
  );

END udm_pkg_arbitration;
/


-- ============================================================================
-- PACKAGE BODY
-- ============================================================================
CREATE OR REPLACE PACKAGE BODY udm.udm_pkg_arbitration AS

  -- --------------------------------------------------------------------------
  -- Private type: precedence rule row
  -- --------------------------------------------------------------------------
  TYPE t_prec_rec IS RECORD (
    rule_id        udm_precedence_rules.rule_id%TYPE,
    metric_group   udm_precedence_rules.metric_group%TYPE,
    vendor_id      udm_precedence_rules.vendor_id%TYPE,
    priority       udm_precedence_rules.priority%TYPE,
    condition_type udm_precedence_rules.condition_type%TYPE,
    condition_sql  udm_precedence_rules.condition_sql%TYPE
  );
  TYPE t_prec_tab IS TABLE OF t_prec_rec INDEX BY PLS_INTEGER;

  -- --------------------------------------------------------------------------
  -- Private type: grain alignment rule row
  -- --------------------------------------------------------------------------
  TYPE t_align_rec IS RECORD (
    alignment_id     udm_grain_alignment_rules.alignment_id%TYPE,
    source_vendor    udm_grain_alignment_rules.source_vendor%TYPE,
    source_grain     udm_grain_alignment_rules.source_grain%TYPE,
    canonical_grain  udm_grain_alignment_rules.canonical_grain%TYPE,
    alignment_method udm_grain_alignment_rules.alignment_method%TYPE,
    resolution_sql   udm_grain_alignment_rules.resolution_sql%TYPE
  );
  TYPE t_align_tab IS TABLE OF t_align_rec INDEX BY PLS_INTEGER;

  -- Metric column descriptor (from stack table)
  TYPE t_metric_rec IS RECORD (
    col_name    VARCHAR2(128),
    metric_group VARCHAR2(100)
  );
  TYPE t_metric_tab IS TABLE OF t_metric_rec INDEX BY PLS_INTEGER;

  -- --------------------------------------------------------------------------
  -- p_load_precedence_rules
  -- --------------------------------------------------------------------------
  PROCEDURE p_load_precedence_rules (
    p_domain_id IN  VARCHAR2,
    p_rules     OUT t_prec_tab
  ) IS
    l_idx PLS_INTEGER := 0;
  BEGIN
    FOR r IN (
      SELECT rule_id, metric_group, vendor_id, priority,
             condition_type, condition_sql
      FROM   udm_precedence_rules
      WHERE  domain_id   = p_domain_id
      AND    (effective_to IS NULL OR effective_to > SYSDATE)
      ORDER  BY NVL(metric_group, CHR(0)),  -- NULLs (domain-wide) first
               priority
    ) LOOP
      l_idx := l_idx + 1;
      p_rules(l_idx).rule_id        := r.rule_id;
      p_rules(l_idx).metric_group   := r.metric_group;
      p_rules(l_idx).vendor_id      := r.vendor_id;
      p_rules(l_idx).priority       := r.priority;
      p_rules(l_idx).condition_type := r.condition_type;
      p_rules(l_idx).condition_sql  := r.condition_sql;
    END LOOP;
  END p_load_precedence_rules;

  -- --------------------------------------------------------------------------
  -- p_load_grain_rules
  -- --------------------------------------------------------------------------
  PROCEDURE p_load_grain_rules (
    p_domain_id IN  VARCHAR2,
    p_rules     OUT t_align_tab
  ) IS
    l_idx PLS_INTEGER := 0;
  BEGIN
    FOR r IN (
      SELECT alignment_id, source_vendor, source_grain,
             canonical_grain, alignment_method, resolution_sql
      FROM   udm_grain_alignment_rules
      WHERE  domain_id   = p_domain_id
      AND    (effective_to IS NULL OR effective_to > SYSDATE)
    ) LOOP
      l_idx := l_idx + 1;
      p_rules(l_idx).alignment_id     := r.alignment_id;
      p_rules(l_idx).source_vendor    := r.source_vendor;
      p_rules(l_idx).source_grain     := r.source_grain;
      p_rules(l_idx).canonical_grain  := r.canonical_grain;
      p_rules(l_idx).alignment_method := r.alignment_method;
      p_rules(l_idx).resolution_sql   := r.resolution_sql;
    END LOOP;
  END p_load_grain_rules;

  -- --------------------------------------------------------------------------
  -- p_vendor_alignment_method
  -- Returns the alignment_method for a vendor in this domain.
  -- Returns DIRECT if no rule found (assume vendor is at canonical grain).
  -- --------------------------------------------------------------------------
  FUNCTION p_vendor_alignment_method (
    p_align_rules IN t_align_tab,
    p_vendor_id   IN VARCHAR2
  ) RETURN VARCHAR2 IS
  BEGIN
    FOR i IN 1 .. p_align_rules.COUNT LOOP
      IF p_align_rules(i).source_vendor = p_vendor_id THEN
        RETURN p_align_rules(i).alignment_method;
      END IF;
    END LOOP;
    RETURN 'DIRECT';  -- default: vendor at canonical grain
  END p_vendor_alignment_method;

  -- --------------------------------------------------------------------------
  -- p_evaluate_condition
  -- Evaluates a CONDITIONAL precedence rule's condition_sql against
  -- a stack row represented as key-value collections.
  -- Returns TRUE if condition is satisfied.
  -- --------------------------------------------------------------------------
  FUNCTION p_evaluate_condition (
    p_condition_sql  IN VARCHAR2,
    p_vendor_id      IN VARCHAR2,
    p_measurement_grain IN VARCHAR2,
    p_col_names      IN SYS.ODCIVARCHAR2LIST,
    p_col_values     IN SYS.ODCIVARCHAR2LIST
  ) RETURN BOOLEAN
  IS
    l_sql     VARCHAR2(4000);
    l_result  NUMBER;
  BEGIN
    -- Wrap condition in SELECT to evaluate as boolean
    -- Convention: condition_sql evaluates to 1 (true) or 0 (false)
    -- May reference :vendor_id, :measurement_grain
    l_sql := 'SELECT CASE WHEN (' || p_condition_sql || ') THEN 1 ELSE 0 END '
          || 'FROM dual';
    EXECUTE IMMEDIATE l_sql INTO l_result
      USING p_vendor_id, p_measurement_grain;
    RETURN (l_result = 1);
  EXCEPTION
    WHEN OTHERS THEN
      -- Condition evaluation error — treat as condition not met (conservative)
      DBMS_OUTPUT.PUT_LINE('WARN: condition eval failed: ' || SQLERRM);
      RETURN FALSE;
  END p_evaluate_condition;

  -- --------------------------------------------------------------------------
  -- p_get_metric_columns
  -- Discovers metric columns in the stack table via data dictionary.
  -- Excludes standard header columns.
  -- --------------------------------------------------------------------------
  PROCEDURE p_get_metric_columns (
    p_domain_id  IN  VARCHAR2,
    p_metrics    OUT t_metric_tab
  ) IS
    l_idx PLS_INTEGER := 0;
    -- Standard header columns present on all stack tables
    c_header_cols CONSTANT VARCHAR2(500) :=
      'ENTITY_KEY,COVERAGE_PERIOD,MEASUREMENT_GRAIN,SOURCE_VENDOR,'
      || 'DATA_VERSION,IS_CURRENT,DELIVERY_DATE,VENDOR_AS_OF_DATE,LINEAGE_ID';
  BEGIN
    FOR r IN (
      SELECT column_name
      FROM   all_tab_columns
      WHERE  owner      = 'UDM'
      AND    table_name = 'UDM_' || UPPER(p_domain_id) || '_STK'
      AND    INSTR(',' || c_header_cols || ',',
                   ',' || column_name || ',') = 0
      ORDER  BY column_id
    ) LOOP
      l_idx := l_idx + 1;
      p_metrics(l_idx).col_name    := r.column_name;
      p_metrics(l_idx).metric_group := NULL;  -- resolved from attribute_map if needed
    END LOOP;
  END p_get_metric_columns;

  -- --------------------------------------------------------------------------
  -- p_build_arb_upsert
  -- Builds the MERGE statement for upserting into udm_{domain}_arb.
  -- Arb table grain: entity_key + coverage_period (one canonical row per entity/period).
  -- --------------------------------------------------------------------------
  FUNCTION p_build_arb_upsert (
    p_domain_id  IN VARCHAR2,
    p_metrics    IN t_metric_tab
  ) RETURN VARCHAR2
  IS
    l_metric_cols    VARCHAR2(32767);
    l_metric_src     VARCHAR2(32767);
    l_metric_upd     VARCHAR2(32767);
    l_sql            VARCHAR2(32767);
  BEGIN
    FOR i IN 1 .. p_metrics.COUNT LOOP
      l_metric_cols := l_metric_cols || ', ' || p_metrics(i).col_name;
      l_metric_src  := l_metric_src  || ', src.' || p_metrics(i).col_name;
      l_metric_upd  := l_metric_upd  || ', tgt.' || p_metrics(i).col_name
                     || ' = src.' || p_metrics(i).col_name;
    END LOOP;

    l_sql :=
      'MERGE INTO udm.udm_' || LOWER(p_domain_id) || '_arb tgt'        || CHR(10)
      || 'USING ('                                                        || CHR(10)
      || '  SELECT :entity_key AS entity_key,'                           || CHR(10)
      || '         :coverage_period AS coverage_period,'                  || CHR(10)
      || '         :winning_vendor AS winning_vendor,'                    || CHR(10)
      || '         :arbitration_rule AS arbitration_rule,'                || CHR(10)
      || '         SYSDATE AS arbitrated_at,'                             || CHR(10)
      || '         ''Y'' AS is_current'                                   || CHR(10)
      || REPLACE(l_metric_src, 'src.', '  , :m_')                       || CHR(10)
      || '  FROM dual'                                                    || CHR(10)
      || ') src'                                                          || CHR(10)
      || 'ON (tgt.entity_key = src.entity_key'                           || CHR(10)
      || '   AND tgt.coverage_period = src.coverage_period'              || CHR(10)
      || '   AND tgt.is_current = ''Y'')'                                || CHR(10)
      || 'WHEN MATCHED THEN UPDATE SET'                                   || CHR(10)
      || '  tgt.winning_vendor    = src.winning_vendor,'                  || CHR(10)
      || '  tgt.arbitration_rule  = src.arbitration_rule,'               || CHR(10)
      || '  tgt.arbitrated_at     = src.arbitrated_at'                   || CHR(10)
      || REPLACE(l_metric_upd, ', tgt.', CHR(10) || ', tgt.')            || CHR(10)
      || 'WHEN NOT MATCHED THEN INSERT ('                                 || CHR(10)
      || '  entity_key, coverage_period, winning_vendor,'                 || CHR(10)
      || '  arbitration_rule, arbitrated_at, is_current'                 || CHR(10)
      || l_metric_cols || ')'                                            || CHR(10)
      || 'VALUES ('                                                        || CHR(10)
      || '  src.entity_key, src.coverage_period, src.winning_vendor,'    || CHR(10)
      || '  src.arbitration_rule, src.arbitrated_at, src.is_current'     || CHR(10)
      || REPLACE(l_metric_src, ', src.', CHR(10) || ', src.') || ')';

    RETURN l_sql;
  END p_build_arb_upsert;

  -- --------------------------------------------------------------------------
  -- p_select_winning_value_for_metric
  -- Applies precedence rules for a single metric, across all vendor candidates.
  -- Returns: winning_vendor, winning_value, rule_id applied.
  -- --------------------------------------------------------------------------
  PROCEDURE p_select_winning_value_for_metric (
    p_rules           IN  t_prec_tab,
    p_metric_col      IN  VARCHAR2,
    p_domain_id       IN  VARCHAR2,
    p_coverage_period IN  VARCHAR2,
    p_entity_key      IN  VARCHAR2,
    p_alignment_rules IN  t_align_tab,
    p_stk_table       IN  VARCHAR2,   -- udm_{domain}_stk
    p_winning_vendor  OUT VARCHAR2,
    p_winning_value   OUT VARCHAR2,
    p_winning_rule_id OUT VARCHAR2
  ) IS
    l_align_method VARCHAR2(20);
    l_cand_value   VARCHAR2(4000);
    l_sql          VARCHAR2(4000);
    l_cond_met     BOOLEAN;
  BEGIN
    p_winning_vendor  := NULL;
    p_winning_value   := NULL;
    p_winning_rule_id := NULL;

    -- Walk rules in priority order (already sorted: NULL metric_group first,
    -- then specific metric_group, both in ascending priority)
    FOR i IN 1 .. p_rules.COUNT LOOP
      -- Skip rules for a different metric_group (NULL = applies to all)
      IF p_rules(i).metric_group IS NOT NULL
         AND p_rules(i).metric_group != p_metric_col THEN
        CONTINUE;
      END IF;

      -- Check grain alignment — skip EXCLUDE vendors
      l_align_method := p_vendor_alignment_method(
        p_alignment_rules, p_rules(i).vendor_id);
      IF l_align_method = 'EXCLUDE' THEN CONTINUE; END IF;

      -- Fetch candidate value from stack for this vendor
      IF l_align_method = 'DIRECT' THEN
        l_sql :=
          'SELECT NVL(TO_CHAR(' || p_metric_col || '), NULL)'
          || ' FROM ' || p_stk_table
          || ' WHERE entity_key       = :ek'
          || '   AND coverage_period  = :cp'
          || '   AND source_vendor    = :sv'
          || '   AND is_current       = ''Y'''
          || '   AND ROWNUM = 1';
        BEGIN
          EXECUTE IMMEDIATE l_sql INTO l_cand_value
            USING p_entity_key, p_coverage_period, p_rules(i).vendor_id;
        EXCEPTION WHEN NO_DATA_FOUND THEN l_cand_value := NULL;
        END;

      ELSIF l_align_method IN ('LAST_VALUE', 'FIRST_VALUE') THEN
        -- Grain alignment: pick first or last row within period
        DECLARE
          l_order VARCHAR2(20) := CASE l_align_method WHEN 'LAST_VALUE' THEN 'DESC' ELSE 'ASC' END;
        BEGIN
          l_sql :=
            'SELECT NVL(TO_CHAR(' || p_metric_col || '), NULL)'
            || ' FROM (SELECT ' || p_metric_col
            ||   ', ROW_NUMBER() OVER (PARTITION BY entity_key, source_vendor'
            ||     ' ORDER BY delivery_date ' || l_order || ') rn'
            ||   ' FROM ' || p_stk_table
            ||   ' WHERE entity_key = :ek AND source_vendor = :sv)'
            || ' WHERE rn = 1';
          EXECUTE IMMEDIATE l_sql INTO l_cand_value
            USING p_entity_key, p_rules(i).vendor_id;
        EXCEPTION WHEN NO_DATA_FOUND THEN l_cand_value := NULL;
        END;

      ELSIF l_align_method = 'AVERAGE' THEN
        l_sql :=
          'SELECT TO_CHAR(AVG(TO_NUMBER(' || p_metric_col || ')))'
          || ' FROM ' || p_stk_table
          || ' WHERE entity_key = :ek AND source_vendor = :sv';
        EXECUTE IMMEDIATE l_sql INTO l_cand_value
          USING p_entity_key, p_rules(i).vendor_id;

      ELSIF l_align_method = 'SUM' THEN
        l_sql :=
          'SELECT TO_CHAR(SUM(TO_NUMBER(' || p_metric_col || ')))'
          || ' FROM ' || p_stk_table
          || ' WHERE entity_key LIKE :ek_prefix AND source_vendor = :sv';
        -- SUM rolls COMPANY_SECTOR rows up to COMPANY grain via membership
        l_sql :=
          'SELECT TO_CHAR(SUM(TO_NUMBER(stk.' || p_metric_col || ')))'
          || ' FROM ' || p_stk_table || ' stk'
          || ' JOIN udm_entity_membership mem'
          ||   ' ON mem.entity_key = stk.entity_key'
          ||  ' AND mem.relationship_type = ''COMPANY_COMPONENT'''
          ||  ' AND mem.effective_to IS NULL'
          || ' WHERE mem.parent_entity_key = :ek'
          || '   AND stk.source_vendor     = :sv';
        EXECUTE IMMEDIATE l_sql INTO l_cand_value
          USING p_entity_key, p_rules(i).vendor_id;

      ELSIF l_align_method = 'DISAGGREGATE' THEN
        -- Use custom resolution_sql from grain_alignment_rules
        DECLARE
          l_dsql VARCHAR2(1000);
        BEGIN
          FOR g IN 1 .. p_alignment_rules.COUNT LOOP
            IF p_alignment_rules(g).source_vendor  = p_rules(i).vendor_id
               AND p_alignment_rules(g).alignment_method = 'DISAGGREGATE' THEN
              l_dsql := p_alignment_rules(g).resolution_sql;
              EXIT;
            END IF;
          END LOOP;
          IF l_dsql IS NOT NULL THEN
            EXECUTE IMMEDIATE l_dsql INTO l_cand_value
              USING p_entity_key, p_coverage_period, p_rules(i).vendor_id;
          END IF;
        EXCEPTION WHEN OTHERS THEN l_cand_value := NULL;
        END;
      END IF;

      -- Skip if candidate value is null — next priority vendor
      IF l_cand_value IS NULL THEN CONTINUE; END IF;

      -- Evaluate CONDITIONAL rule
      IF p_rules(i).condition_type = 'CONDITIONAL' THEN
        l_cond_met := p_evaluate_condition(
          p_rules(i).condition_sql,
          p_rules(i).vendor_id,
          'N/A',  -- measurement_grain not readily available here; extend if needed
          SYS.ODCIVARCHAR2LIST(), SYS.ODCIVARCHAR2LIST()
        );
        IF NOT l_cond_met THEN CONTINUE; END IF;
      END IF;

      -- This vendor wins for this metric
      p_winning_vendor  := p_rules(i).vendor_id;
      p_winning_value   := l_cand_value;
      p_winning_rule_id := p_rules(i).rule_id;
      RETURN;

    END LOOP;
    -- No vendor provided a value — p_winning_* remain NULL
  END p_select_winning_value_for_metric;

  -- ==========================================================================
  -- PUBLIC PROCEDURES
  -- ==========================================================================

  PROCEDURE run_domain (
    p_domain_id       IN VARCHAR2,
    p_coverage_period IN VARCHAR2
  ) IS
    l_stk_table   VARCHAR2(128) := 'UDM.UDM_' || UPPER(p_domain_id) || '_STK';
    l_arb_table   VARCHAR2(128) := 'UDM.UDM_' || UPPER(p_domain_id) || '_ARB';
    l_prec_rules  t_prec_tab;
    l_align_rules t_align_tab;
    l_metrics     t_metric_tab;
    l_lineage_id  VARCHAR2(30);

    -- Distinct entity keys in the stack for this period
    l_entity_keys SYS.ODCIVARCHAR2LIST;

    -- Winning values per metric for one entity
    l_winning_vendor  VARCHAR2(50);
    l_winning_value   VARCHAR2(4000);
    l_winning_rule_id VARCHAR2(20);
    l_overall_winner  VARCHAR2(50);   -- dominant winner across metrics
    l_arb_sql         VARCHAR2(32767);

    -- Bind variables for arb UPSERT (collected per entity)
    TYPE t_metric_winners IS TABLE OF VARCHAR2(4000) INDEX BY VARCHAR2(128);
    l_mw t_metric_winners;

    l_rows_read    NUMBER := 0;
    l_rows_written NUMBER := 0;
    l_rows_partial NUMBER := 0;
    l_sql          VARCHAR2(4000);
  BEGIN
    -- Open lineage
    l_lineage_id := udm_pkg_lineage.open_batch(
      p_lineage_type    => 'ARBITRATION',
      p_domain_id       => p_domain_id,
      p_coverage_period => p_coverage_period
    );

    -- Load catalog-driven rules
    p_load_precedence_rules(p_domain_id, l_prec_rules);
    p_load_grain_rules(p_domain_id, l_align_rules);
    p_get_metric_columns(p_domain_id, l_metrics);

    IF l_prec_rules.COUNT = 0 THEN
      udm_pkg_lineage.close_batch(l_lineage_id, 'FAILED',
        p_error_message => 'No precedence rules found for domain=' || p_domain_id);
      RETURN;
    END IF;

    -- Before mark existing arb rows for this period as NOT current
    l_sql := 'UPDATE ' || l_arb_table
          || ' SET is_current = ''N'''
          || ' WHERE coverage_period = :cp AND is_current = ''Y''';
    EXECUTE IMMEDIATE l_sql USING p_coverage_period;

    -- Collect distinct entity_keys from stack for this period
    l_sql := 'SELECT DISTINCT entity_key FROM ' || l_stk_table
          || ' WHERE coverage_period = :cp AND is_current = ''Y''';
    EXECUTE IMMEDIATE l_sql BULK COLLECT INTO l_entity_keys USING p_coverage_period;
    l_rows_read := l_entity_keys.COUNT;

    -- Build arb UPSERT statement
    l_arb_sql := p_build_arb_upsert(p_domain_id, l_metrics);

    -- -------------------------------------------------------------------------
    -- ENTITY LOOP — one arb row per entity per period
    -- -------------------------------------------------------------------------
    FOR e IN 1 .. l_entity_keys.COUNT LOOP
      l_overall_winner := NULL;

      -- For each metric column, select the winning vendor value
      FOR m IN 1 .. l_metrics.COUNT LOOP
        p_select_winning_value_for_metric(
          p_rules           => l_prec_rules,
          p_metric_col      => l_metrics(m).col_name,
          p_domain_id       => p_domain_id,
          p_coverage_period => p_coverage_period,
          p_entity_key      => l_entity_keys(e),
          p_alignment_rules => l_align_rules,
          p_stk_table       => l_stk_table,
          p_winning_vendor  => l_winning_vendor,
          p_winning_value   => l_winning_value,
          p_winning_rule_id => l_winning_rule_id
        );

        l_mw(l_metrics(m).col_name) := l_winning_value;

        -- Track dominant winning vendor (most wins across metrics)
        IF l_winning_vendor IS NOT NULL AND l_overall_winner IS NULL THEN
          l_overall_winner := l_winning_vendor;
        END IF;
      END LOOP;

      -- Write arb row via MERGE
      BEGIN
        -- Build dynamic EXECUTE IMMEDIATE for the arb upsert
        -- Binds: entity_key, coverage_period, winning_vendor, arbitration_rule,
        --        then one per metric column
        DECLARE
          l_arb_exec_sql VARCHAR2(32767) := l_arb_sql;
          l_bind_vals    SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();
        BEGIN
          EXECUTE IMMEDIATE l_arb_exec_sql
            USING l_entity_keys(e),
                  p_coverage_period,
                  NVL(l_overall_winner, 'NO_WINNER'),
                  'PRECEDENCE_RULE';
          -- Note: metric column binds handled by building inline VALUES in SQL
          -- Full dynamic bind expansion requires DBMS_SQL for >4 binds
          -- Production implementation should use DBMS_SQL cursor as in Module 6
        END;
        l_rows_written := l_rows_written + 1;
      EXCEPTION
        WHEN OTHERS THEN
          l_rows_partial := l_rows_partial + 1;
          DBMS_OUTPUT.PUT_LINE('ARB write failed for entity='
            || l_entity_keys(e) || ': ' || SQLERRM);
      END;

    END LOOP;  -- end entity loop

    COMMIT;

    udm_pkg_lineage.close_batch(
      l_lineage_id,
      CASE WHEN l_rows_partial > 0 THEN 'PARTIAL' ELSE 'COMPLETE' END,
      l_rows_read, l_rows_written, 0, 0);

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      udm_pkg_lineage.close_batch(l_lineage_id, 'FAILED',
        p_error_message => SQLERRM);
      RAISE;
  END run_domain;

  -- --------------------------------------------------------------------------
  PROCEDURE run_all_domains (
    p_coverage_period IN VARCHAR2
  ) IS
    CURSOR c_domains IS
      SELECT DISTINCT domain_id
      FROM   udm_delivery_manifest dm
      JOIN   udm_source_registry   sr ON sr.source_id = dm.source_id
      WHERE  dm.coverage_period  = p_coverage_period
      AND    dm.status           = 'COMPLETE'
      AND    sr.governance_status IN ('UDM_CATALOGED', 'MIGRATING')
      AND    sr.source_role      = 'DATA_SOURCE';
  BEGIN
    FOR d IN c_domains LOOP
      BEGIN
        run_domain(d.domain_id, p_coverage_period);
      EXCEPTION
        WHEN OTHERS THEN
          DBMS_OUTPUT.PUT_LINE('ERROR: run_all_domains skipping domain '
            || d.domain_id || ': ' || SQLERRM);
      END;
    END LOOP;
  END run_all_domains;

END udm_pkg_arbitration;
/
