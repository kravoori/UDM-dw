-- ============================================================================
-- MODULE 6 — HARMONISATION ENGINE  (v2 — set-based rewrite)
-- Package  : UDM.UDM_PKG_HARMONISATION
--
-- KEY CHANGES FROM v1
-- ─────────────────────────────────────────────────────────────────────────
-- 1. run_source(p_source_id) — no coverage_period parameter.
--    Engine finds the latest COMPLETE unprocessed manifest internally.
--    Source rows are filtered via currency_mechanism only — the engine
--    does not impose a period WHERE clause on the source table.
--    coverage_period stamped on stack rows is read FROM the source data
--    (time_col value), not passed as a parameter.
--
-- 2. Transforms are embedded as SQL expressions in the SELECT clause.
--    p_build_transform_expr() returns a SQL fragment for each rule:
--      direct          → src.col
--      multiply:N      → src.col * N
--      divide:cn       → CASE WHEN divisor=0 THEN NULL ELSE src.col/div END
--      coalesce:a,b    → COALESCE(src.col_a, src.col_b)
--      flag:a,b        → CASE WHEN src.col_a IS NOT NULL THEN 'DIRECT'…
--      lookup:s.t.c    → (SELECT c FROM s.t WHERE id=src.col AND ROWNUM=1)
--      rule_ref:NAME   → resolution_sql from udm_transform_rules with
--                        {vendor_value} substituted for src.col inline
--    No PL/SQL row loop for transforms. One INSERT…SELECT per source.
--
-- 3. Entity resolution is a SQL JOIN, not a per-row PL/SQL lookup.
--    Main INSERT…SELECT JOINs udm_entity_xref. Unmatched rows are caught
--    by a second INSERT…SELECT (NOT EXISTS) into udm_quarantine.
--
-- 4. COMPANY_SECTOR pre-pass runs BEFORE the main INSERT.
--    New composite entities are created via FORALL (not row-by-row).
--    Sequence values pre-generated in bulk. MV committed once.
--
-- 5. IDENTITY_SOURCE: new entities created with FORALL INSERT on
--    pre-collected arrays. One BULK COLLECT + two FORALL per batch.
--
-- Depends  : udm_pkg_lineage (Module 9)
-- Compile  : After udm_pkg_lineage.
-- ============================================================================

-- ============================================================================
-- PACKAGE SPEC
-- ============================================================================
CREATE OR REPLACE PACKAGE udm.udm_pkg_harmonisation AS

  -- Session-level COMPANY_SECTOR key cache.
  -- Key   : company_entity_key || '|' || sector_entity_key
  -- Value : resolved COMPANY_SECTOR entity_key
  -- Populated during pre-pass; reused by main INSERT…SELECT JOIN.
  TYPE t_cs_cache IS TABLE OF VARCHAR2(20) INDEX BY VARCHAR2(41);
  g_cs_cache t_cs_cache;

  -- -------------------------------------------------------------------------
  -- run_source
  -- Processes one source against its current data snapshot.
  -- No coverage_period — the engine filters via currency_mechanism and reads
  -- the period from the source's time_col.
  -- -------------------------------------------------------------------------
  PROCEDURE run_source (p_source_id IN VARCHAR2);

  -- -------------------------------------------------------------------------
  -- run_domain
  -- Processes all UDM_CATALOGED sources for a domain in role order:
  -- IDENTITY_SOURCE first, REFERENCE_SOURCE second, DATA_SOURCE last.
  -- -------------------------------------------------------------------------
  PROCEDURE run_domain (p_domain_id IN VARCHAR2);

  -- Clears the session-level COMPANY_SECTOR cache.
  PROCEDURE flush_cs_cache;

END udm_pkg_harmonisation;
/


-- ============================================================================
-- PACKAGE BODY
-- ============================================================================
CREATE OR REPLACE PACKAGE BODY udm.udm_pkg_harmonisation AS

  -- --------------------------------------------------------------------------
  -- Private: source registry record
  -- --------------------------------------------------------------------------
  TYPE t_src_rec IS RECORD (
    source_id           udm_source_registry.source_id%TYPE,
    vendor_id           udm_source_registry.vendor_id%TYPE,
    domain_id           udm_source_registry.domain_id%TYPE,
    source_schema       udm_source_registry.source_schema%TYPE,
    source_table        udm_source_registry.source_table%TYPE,
    source_format       udm_source_registry.source_format%TYPE,
    currency_mechanism  udm_source_registry.currency_mechanism%TYPE,
    current_flag_column udm_source_registry.current_flag_column%TYPE,
    effective_to_column udm_source_registry.effective_to_column%TYPE,
    time_key_column     udm_source_registry.time_key_column%TYPE,
    entity_id_col       udm_source_registry.entity_id_col%TYPE,
    time_col            udm_source_registry.time_col%TYPE,
    source_role         udm_source_registry.source_role%TYPE,
    subject_type        udm_source_registry.subject_type%TYPE,
    domain_grain        udm_source_registry.domain_grain%TYPE,
    governance_status   udm_source_registry.governance_status%TYPE
  );

  -- --------------------------------------------------------------------------
  -- Private: attribute map row — BULK COLLECTed once per source
  -- --------------------------------------------------------------------------
  TYPE t_attr_rec IS RECORD (
    map_id                    udm_attribute_map.map_id%TYPE,
    source_attribute          udm_attribute_map.source_attribute%TYPE,
    canonical_name            udm_attribute_map.canonical_name%TYPE,
    transform_rule            udm_attribute_map.transform_rule%TYPE,
    data_type                 udm_attribute_map.data_type%TYPE,
    unit_from                 udm_attribute_map.unit_from%TYPE,
    unit_from_eav_key         udm_attribute_map.unit_from_eav_key%TYPE,
    unit_to                   udm_attribute_map.unit_to%TYPE,
    is_subject_key            udm_attribute_map.is_subject_key%TYPE,
    is_time_key               udm_attribute_map.is_time_key%TYPE,
    is_mandatory              udm_attribute_map.is_mandatory%TYPE,
    attribute_name_column     udm_attribute_map.attribute_name_column%TYPE,
    attribute_name_value      udm_attribute_map.attribute_name_value%TYPE,
    attribute_value_column    udm_attribute_map.attribute_value_column%TYPE,
    attribute_value_data_type udm_attribute_map.attribute_value_data_type%TYPE
  );
  TYPE t_attr_tab IS TABLE OF t_attr_rec INDEX BY PLS_INTEGER;

  -- Typed arrays for FORALL / BULK COLLECT operations
  TYPE t_varchar20_tab  IS TABLE OF VARCHAR2(20)  INDEX BY PLS_INTEGER;
  TYPE t_varchar50_tab  IS TABLE OF VARCHAR2(50)  INDEX BY PLS_INTEGER;
  TYPE t_varchar200_tab IS TABLE OF VARCHAR2(200) INDEX BY PLS_INTEGER;
  TYPE t_number_tab     IS TABLE OF NUMBER        INDEX BY PLS_INTEGER;
  TYPE t_date_tab       IS TABLE OF DATE          INDEX BY PLS_INTEGER;
  TYPE t_char1_tab      IS TABLE OF CHAR(1)       INDEX BY PLS_INTEGER;

  -- ==========================================================================
  -- PRIVATE: METADATA HELPERS
  -- ==========================================================================

  PROCEDURE p_load_source_rec (p_source_id IN VARCHAR2, p_src OUT t_src_rec) IS
  BEGIN
    SELECT source_id, vendor_id, domain_id, source_schema, source_table,
           source_format, currency_mechanism, current_flag_column,
           effective_to_column, time_key_column, entity_id_col, time_col,
           source_role, subject_type, domain_grain, governance_status
    INTO   p_src.source_id,      p_src.vendor_id,        p_src.domain_id,
           p_src.source_schema,  p_src.source_table,     p_src.source_format,
           p_src.currency_mechanism, p_src.current_flag_column,
           p_src.effective_to_column, p_src.time_key_column,
           p_src.entity_id_col,  p_src.time_col,
           p_src.source_role,    p_src.subject_type,
           p_src.domain_grain,   p_src.governance_status
    FROM   udm_source_registry
    WHERE  source_id = p_source_id AND effective_to IS NULL;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20200, 'Source not found or not active: ' || p_source_id);
  END p_load_source_rec;

  -- --------------------------------------------------------------------------
  -- BULK COLLECT the attribute map — no cursor loop
  -- --------------------------------------------------------------------------
  PROCEDURE p_load_attr_map (p_source_id IN VARCHAR2, p_attrs OUT t_attr_tab) IS
  BEGIN
    SELECT map_id, source_attribute, canonical_name, transform_rule,
           data_type, unit_from, unit_from_eav_key, unit_to,
           is_subject_key, is_time_key, is_mandatory,
           attribute_name_column, attribute_name_value,
           attribute_value_column, attribute_value_data_type
    BULK COLLECT INTO p_attrs
    FROM  udm_attribute_map
    WHERE source_id   = p_source_id
    AND   map_status  = 'ACTIVE'
    AND   (effective_to IS NULL OR effective_to > SYSDATE)
    ORDER BY is_subject_key DESC, is_time_key DESC, canonical_name;
  END p_load_attr_map;

  -- --------------------------------------------------------------------------
  -- Check for blocked columns — raises before any DML is attempted
  -- --------------------------------------------------------------------------
  PROCEDURE p_check_pending_retirement (p_source_id IN VARCHAR2) IS
    l_count NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_count
    FROM   udm_attribute_map
    WHERE  source_id = p_source_id AND map_status = 'PENDING_RETIREMENT';
    IF l_count > 0 THEN
      RAISE_APPLICATION_ERROR(-20201,
        'Source ' || p_source_id || ': ' || l_count
        || ' attribute(s) PENDING_RETIREMENT. Resolve column drop first.');
    END IF;
  END p_check_pending_retirement;

  -- --------------------------------------------------------------------------
  -- Find the latest COMPLETE manifest that has not yet been successfully loaded.
  -- Engine is self-discovering — no period passed from caller.
  -- --------------------------------------------------------------------------
  PROCEDURE p_find_pending_manifest (
    p_source_id   IN  VARCHAR2,
    p_vendor_id   IN  VARCHAR2,
    p_manifest_id OUT VARCHAR2,
    p_hint_period OUT VARCHAR2   -- informational only; not used as filter
  ) IS
  BEGIN
    SELECT manifest_id, coverage_period
    INTO   p_manifest_id, p_hint_period
    FROM   (
      SELECT dm.manifest_id, dm.coverage_period
      FROM   udm_delivery_manifest dm
      WHERE  dm.source_id = p_source_id
      AND    dm.status    = 'COMPLETE'
      AND    NOT EXISTS (
               SELECT 1 FROM udm_lineage l
               WHERE  l.manifest_id = dm.manifest_id
               AND    l.lineage_type = 'LOAD'
               AND    l.status IN ('RUNNING', 'COMPLETE')
             )
      ORDER  BY dm.completed_at DESC
    )
    WHERE ROWNUM = 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20202,
        'No COMPLETE unprocessed manifest for source=' || p_source_id
        || '. Nothing to do.');
  END p_find_pending_manifest;

  -- ==========================================================================
  -- PRIVATE: SQL EXPRESSION BUILDERS
  -- All transforms are resolved here as SQL text — no PL/SQL row processing.
  -- ==========================================================================

  -- --------------------------------------------------------------------------
  -- p_build_transform_expr
  -- Returns a SQL expression for one attribute, ready to embed in SELECT.
  -- The expression references the source table alias "src".
  -- --------------------------------------------------------------------------
  FUNCTION p_build_transform_expr (
    p_rule      IN VARCHAR2,
    p_src_col   IN VARCHAR2,    -- source_attribute (physical column)
    p_attrs     IN t_attr_tab,  -- full attr tab for cross-column transforms
    p_vendor_id IN VARCHAR2
  ) RETURN VARCHAR2
  IS
    l_rule   VARCHAR2(200) := NVL(p_rule, 'direct');
    l_prefix VARCHAR2(30);
    l_param  VARCHAR2(200);
    l_sep    PLS_INTEGER;
    l_expr   VARCHAR2(4000);

    -- Helper: find source_attribute for a canonical_name in the attr map
    FUNCTION find_src_attr (p_canon IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
      FOR i IN 1 .. p_attrs.COUNT LOOP
        IF p_attrs(i).canonical_name = p_canon THEN
          RETURN p_attrs(i).source_attribute;
        END IF;
      END LOOP;
      RETURN NULL;
    END;

    -- Helper: split comma-list, return SQL coalesce args
    FUNCTION coalesce_expr (p_list IN VARCHAR2) RETURN VARCHAR2 IS
      l_args   VARCHAR2(4000) := 'src.' || p_src_col;
      l_cn     VARCHAR2(200);
      l_sa     VARCHAR2(128);
      l_start  PLS_INTEGER := 1;
      l_end    PLS_INTEGER;
    BEGIN
      LOOP
        l_end := INSTR(p_list || ',', ',', l_start);
        EXIT WHEN l_end = 0;
        l_cn  := TRIM(SUBSTR(p_list, l_start, l_end - l_start));
        l_sa  := find_src_attr(l_cn);
        IF l_sa IS NOT NULL THEN
          l_args := l_args || ', src.' || l_sa;
        END IF;
        l_start := l_end + 1;
      END LOOP;
      RETURN 'COALESCE(' || l_args || ')';
    END;

  BEGIN
    l_sep    := INSTR(l_rule, ':');
    l_prefix := CASE WHEN l_sep > 0 THEN SUBSTR(l_rule, 1, l_sep-1) ELSE l_rule END;
    l_param  := CASE WHEN l_sep > 0 THEN SUBSTR(l_rule, l_sep+1)    ELSE NULL  END;

    CASE l_prefix

      WHEN 'direct' THEN
        l_expr := 'src.' || p_src_col;

      WHEN 'multiply' THEN
        l_expr := 'src.' || p_src_col || ' * ' || l_param;

      WHEN 'divide' THEN
        -- l_param = canonical_name of the divisor column
        DECLARE l_div_src VARCHAR2(128) := find_src_attr(l_param);
        BEGIN
          IF l_div_src IS NOT NULL THEN
            l_expr := 'CASE WHEN NVL(src.' || l_div_src || ', 0) = 0'
                   || ' THEN NULL'
                   || ' ELSE src.' || p_src_col || ' / src.' || l_div_src
                   || ' END';
          ELSE
            l_expr := 'src.' || p_src_col;  -- safe fallback
          END IF;
        END;

      WHEN 'coalesce' THEN
        -- l_param = comma-separated canonical_names (fallback order after primary)
        l_expr := coalesce_expr(l_param);

      WHEN 'flag' THEN
        -- flag:primary_cn,fallback_cn — writes DIRECT|ESTIMATED
        DECLARE
          l_primary_cn  VARCHAR2(200) := REGEXP_SUBSTR(l_param, '[^,]+', 1, 1);
          l_primary_src VARCHAR2(128) := find_src_attr(l_primary_cn);
        BEGIN
          IF l_primary_src IS NOT NULL THEN
            l_expr := 'CASE WHEN src.' || l_primary_src
                   || ' IS NOT NULL THEN ''DIRECT'' ELSE ''ESTIMATED'' END';
          ELSE
            l_expr := '''DIRECT''';
          END IF;
        END;

      WHEN 'lookup' THEN
        -- lookup:schema.table.val_col — inline scalar subquery in SELECT
        -- Natural key = the source column value. Assumes a single natural key.
        DECLARE
          l_s VARCHAR2(30); l_t VARCHAR2(128); l_c VARCHAR2(128);
          l_n PLS_INTEGER := INSTR(l_param, '.');
          l_m PLS_INTEGER;
        BEGIN
          IF INSTR(l_param, '.', l_n+1) > 0 THEN
            -- schema.table.col
            l_m  := INSTR(l_param, '.', l_n+1);
            l_s  := SUBSTR(l_param, 1, l_n-1);
            l_t  := SUBSTR(l_param, l_n+1, l_m-l_n-1);
            l_c  := SUBSTR(l_param, l_m+1);
          ELSE
            -- table.col (default schema = UDM)
            l_s  := 'UDM';
            l_t  := SUBSTR(l_param, 1, l_n-1);
            l_c  := SUBSTR(l_param, l_n+1);
          END IF;
          l_expr := '(SELECT ' || l_c
                 || ' FROM '  || l_s || '.' || l_t
                 || ' WHERE id = src.' || p_src_col
                 || ' AND ROWNUM = 1)';
        END;

      WHEN 'rule_ref' THEN
        -- Fetch resolution_sql from catalog; substitute placeholder inline.
        -- resolution_sql must be a valid SQL expression (not a statement).
        DECLARE
          l_sql VARCHAR2(2000);
        BEGIN
          SELECT resolution_sql INTO l_sql
          FROM   udm_transform_rules
          WHERE  rule_name    = l_param
          AND    is_active    = 'Y'
          AND    (effective_to IS NULL OR effective_to > SYSDATE)
          AND    ROWNUM = 1;

          -- Standard placeholders → column references / literals
          l_sql := REPLACE(l_sql, '{vendor_value}', 'src.' || p_src_col);
          l_sql := REPLACE(l_sql, '{vendor_id}',    '''' || p_vendor_id || '''');
          l_expr := '(' || l_sql || ')';
        EXCEPTION
          WHEN NO_DATA_FOUND THEN l_expr := 'src.' || p_src_col;
        END;

      ELSE
        l_expr := 'src.' || p_src_col;   -- unknown rule: pass through

    END CASE;

    RETURN l_expr;
  EXCEPTION
    WHEN OTHERS THEN
      -- Log and fall back to direct — never abort SQL build on transform error
      DBMS_OUTPUT.PUT_LINE('WARN p_build_transform_expr rule=' || l_rule
        || ' col=' || p_src_col || ': ' || SQLERRM);
      RETURN 'src.' || p_src_col;
  END p_build_transform_expr;

  -- --------------------------------------------------------------------------
  -- p_build_currency_filter
  -- Returns the WHERE predicate for current rows — uses currency_mechanism.
  -- This is the ONLY filter applied to the source table. No period filter.
  -- --------------------------------------------------------------------------
  FUNCTION p_build_currency_filter (p_src IN t_src_rec) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE p_src.currency_mechanism
      WHEN 'CURRENT_FLAG'      THEN 'src.' || p_src.current_flag_column || ' = ''Y'''
      WHEN 'EFFECTIVE_DATES'   THEN 'src.' || p_src.effective_to_column || ' IS NULL'
      WHEN 'MAX_SNAPSHOT_DATE' THEN
           'src.' || p_src.time_key_column || ' = ('
           || 'SELECT MAX(' || p_src.time_key_column || ')'
           || ' FROM '  || p_src.source_schema || '.' || p_src.source_table || ')'
      WHEN 'LOAD_DATE'         THEN
           'src.load_date = ('
           || 'SELECT MAX(load_date)'
           || ' FROM '  || p_src.source_schema || '.' || p_src.source_table || ')'
      WHEN 'ALWAYS_CURRENT'    THEN '1=1'
      ELSE '1=1'
    END;
  END p_build_currency_filter;

  -- ==========================================================================
  -- PRIVATE: MAIN INSERT…SELECT BUILDERS
  -- ==========================================================================

  -- --------------------------------------------------------------------------
  -- p_build_entity_join
  -- Returns the JOIN fragment for standard ENTITY subject_type.
  -- For INTERNAL_ID, returns a cross-join on dual (entity_key = entity_id_col).
  -- --------------------------------------------------------------------------
  FUNCTION p_build_entity_join (p_src IN t_src_rec) RETURN VARCHAR2 IS
  BEGIN
    CASE p_src.subject_type
      WHEN 'ENTITY' THEN
        RETURN
          'JOIN udm_entity_xref xref'               || CHR(10)
          || '  ON xref.vendor_id   = ''' || p_src.vendor_id || '''' || CHR(10)
          || ' AND xref.external_id = src.' || p_src.entity_id_col   || CHR(10)
          || ' AND xref.effective_to IS NULL';

      WHEN 'SPATIAL' THEN
        RETURN
          'JOIN udm_spatial_asset_registry sar'     || CHR(10)
          || '  ON sar.source_id       = ''' || p_src.source_id || '''' || CHR(10)
          || ' AND sar.vendor_asset_id = src.' || p_src.entity_id_col  || CHR(10)
          || ' AND sar.effective_to IS NULL';

      WHEN 'INTERNAL_ID' THEN
        -- No join needed — entity_id_col IS the key
        RETURN NULL;

      ELSE RETURN NULL;
    END CASE;
  END p_build_entity_join;

  -- --------------------------------------------------------------------------
  -- p_entity_key_expr
  -- Returns the SQL expression for entity_key in the SELECT list.
  -- --------------------------------------------------------------------------
  FUNCTION p_entity_key_expr (p_src IN t_src_rec) RETURN VARCHAR2 IS
  BEGIN
    CASE p_src.subject_type
      WHEN 'ENTITY'      THEN RETURN 'xref.entity_key';
      WHEN 'SPATIAL'     THEN RETURN 'sar.spatial_asset_key';
      WHEN 'INTERNAL_ID' THEN RETURN 'src.' || p_src.entity_id_col;
      ELSE                    RETURN 'src.' || p_src.entity_id_col;
    END CASE;
  END p_entity_key_expr;

  -- --------------------------------------------------------------------------
  -- p_build_columnar_insert_sql
  -- Full INSERT…SELECT for a COLUMNAR DATA_SOURCE.
  -- Transforms are SQL expressions in the SELECT list.
  -- Entity resolution is a JOIN — not a PL/SQL lookup.
  -- One SQL statement loads the entire current snapshot.
  -- --------------------------------------------------------------------------
  FUNCTION p_build_columnar_insert_sql (
    p_src             IN t_src_rec,
    p_attrs           IN t_attr_tab,
    p_currency_filter IN VARCHAR2,
    p_data_version    IN NUMBER
  ) RETURN VARCHAR2
  IS
    l_col_list  VARCHAR2(32767);
    l_sel_list  VARCHAR2(32767);
    l_entity_join VARCHAR2(1000) := p_build_entity_join(p_src);
    l_sql         VARCHAR2(32767);
    l_stk_table   VARCHAR2(128)  :=
      'udm.' || 'udm_' || LOWER(REPLACE(p_src.domain_id, '-', '_')) || '_stk';
  BEGIN
    -- Standard header columns (always present on every stack table)
    l_col_list :=
      'entity_key, coverage_period, measurement_grain, source_vendor, '
      || 'data_version, is_current, delivery_date, lineage_id';

    l_sel_list :=
      p_entity_key_expr(p_src)                              || ', '
      || 'TO_CHAR(src.' || p_src.time_col || ')'           || ', '
      || '''' || p_src.domain_grain || ''''                 || ', '
      || '''' || p_src.vendor_id    || ''''                 || ', '
      || TO_CHAR(p_data_version)                            || ', '
      || '''Y'''                                            || ', '
      || 'SYSDATE'                                          || ', '
      || ':b_lineage_id';

    -- Metric columns — transform expression embedded per attribute
    FOR i IN 1 .. p_attrs.COUNT LOOP
      IF p_attrs(i).is_subject_key = 'N' AND p_attrs(i).is_time_key = 'N' THEN
        l_col_list := l_col_list || ', ' || p_attrs(i).canonical_name;
        l_sel_list := l_sel_list || ', '
          || p_build_transform_expr(
               p_attrs(i).transform_rule,
               p_attrs(i).source_attribute,
               p_attrs,
               p_src.vendor_id
             );
      END IF;
    END LOOP;

    -- Assemble: APPEND hint drives direct-path insert for bulk performance
    l_sql :=
      'INSERT /*+ APPEND */ INTO ' || l_stk_table                   || CHR(10)
      || '  (' || l_col_list || ')'                                 || CHR(10)
      || 'SELECT'                                                    || CHR(10)
      || '  ' || l_sel_list                                         || CHR(10)
      || 'FROM ' || p_src.source_schema || '.' || p_src.source_table || ' src' || CHR(10)
      || NVL(l_entity_join, '')                                      || CHR(10)
      || 'WHERE ' || p_currency_filter;

    RETURN l_sql;
  END p_build_columnar_insert_sql;

  -- --------------------------------------------------------------------------
  -- p_build_eav_insert_sql
  -- INSERT…SELECT with conditional aggregation pivot (GROUP BY entity + period).
  -- The entire EAV pivot is expressed in SQL — no PL/SQL row iteration.
  -- --------------------------------------------------------------------------
  FUNCTION p_build_eav_insert_sql (
    p_src             IN t_src_rec,
    p_attrs           IN t_attr_tab,
    p_currency_filter IN VARCHAR2,
    p_data_version    IN NUMBER
  ) RETURN VARCHAR2
  IS
    l_col_list   VARCHAR2(32767);
    l_sel_list   VARCHAR2(32767);
    l_pivot_cols VARCHAR2(32767);
    l_entity_join VARCHAR2(1000) := p_build_entity_join(p_src);
    l_sql         VARCHAR2(32767);
    l_stk_table   VARCHAR2(128)  :=
      'udm.' || 'udm_' || LOWER(REPLACE(p_src.domain_id, '-', '_')) || '_stk';
    l_attr_name_col  VARCHAR2(128);
    l_attr_val_col   VARCHAR2(128);
    l_cast_expr      VARCHAR2(200);
  BEGIN
    -- EAV column names are the same across all attrs for this source
    IF p_attrs.COUNT > 0 THEN
      l_attr_name_col := p_attrs(1).attribute_name_column;
      l_attr_val_col  := p_attrs(1).attribute_value_column;
    END IF;

    -- Header
    l_col_list :=
      'entity_key, coverage_period, measurement_grain, source_vendor, '
      || 'data_version, is_current, delivery_date, lineage_id';

    l_sel_list :=
      p_entity_key_expr(p_src)                              || ', '
      || 'TO_CHAR(MAX(src.' || p_src.time_col || '))'      || ', '
      || '''' || p_src.domain_grain || ''''                 || ', '
      || '''' || p_src.vendor_id    || ''''                 || ', '
      || TO_CHAR(p_data_version)                            || ', '
      || '''Y'''                                            || ', '
      || 'SYSDATE'                                          || ', '
      || ':b_lineage_id';

    -- Pivot: MAX(CASE WHEN attr_name = 'X' THEN CAST(attr_value AS type) END)
    FOR i IN 1 .. p_attrs.COUNT LOOP
      IF p_attrs(i).attribute_name_value IS NOT NULL THEN
        -- Determine cast for the EAV value column
        l_cast_expr := CASE p_attrs(i).attribute_value_data_type
          WHEN 'NUMBER'  THEN 'TO_NUMBER(src.' || l_attr_val_col || ')'
          WHEN 'DATE'    THEN 'TO_DATE(src.'   || l_attr_val_col || ', ''YYYY-MM-DD'')'
          ELSE                'src.' || l_attr_val_col
        END;

        l_pivot_cols := l_pivot_cols
          || ', MAX(CASE WHEN src.' || l_attr_name_col
          || ' = ''' || p_attrs(i).attribute_name_value || ''''
          || ' THEN ' || l_cast_expr || ' END)';

        l_col_list := l_col_list || ', ' || p_attrs(i).canonical_name;
      END IF;
    END LOOP;

    l_sel_list := l_sel_list || l_pivot_cols;

    l_sql :=
      'INSERT /*+ APPEND */ INTO ' || l_stk_table                   || CHR(10)
      || '  (' || l_col_list || ')'                                 || CHR(10)
      || 'SELECT'                                                    || CHR(10)
      || '  ' || l_sel_list                                         || CHR(10)
      || 'FROM ' || p_src.source_schema || '.' || p_src.source_table || ' src' || CHR(10)
      || NVL(l_entity_join, '')                                      || CHR(10)
      || 'WHERE '  || p_currency_filter                              || CHR(10)
      || 'GROUP BY ' || p_entity_key_expr(p_src);

    RETURN l_sql;
  END p_build_eav_insert_sql;

  -- --------------------------------------------------------------------------
  -- p_build_entity_quarantine_sql
  -- INSERT…SELECT for rows that could NOT be resolved (NOT EXISTS in xref).
  -- Set-based — no PL/SQL loop.
  -- --------------------------------------------------------------------------
  FUNCTION p_build_entity_quarantine_sql (
    p_src             IN t_src_rec,
    p_currency_filter IN VARCHAR2
  ) RETURN VARCHAR2
  IS
    l_sql VARCHAR2(4000);
  BEGIN
    -- Only applicable for ENTITY subject_type; other types have no xref
    IF p_src.subject_type != 'ENTITY' THEN RETURN NULL; END IF;

    l_sql :=
      'INSERT INTO udm_quarantine ('                                          || CHR(10)
      || '  quarantine_id, lineage_id, source_id, domain_id, vendor_id,'     || CHR(10)
      || '  coverage_period, entity_id_raw, attribute_name,'                  || CHR(10)
      || '  raw_value, check_type, rejection_reason,'                         || CHR(10)
      || '  quarantined_at, resolved_flag)'                                   || CHR(10)
      || 'SELECT'                                                              || CHR(10)
      || '  ''QUA-'' || TO_CHAR(SYSDATE,''YYYYMMDD'') || ''-'''              || CHR(10)
      || '  || LPAD(udm_quarantine_seq.NEXTVAL, 8, ''0''),'                  || CHR(10)
      || '  :b_lineage_id,'                                                   || CHR(10)
      || '  ''' || p_src.source_id  || ''','                                  || CHR(10)
      || '  ''' || p_src.domain_id  || ''','                                  || CHR(10)
      || '  ''' || p_src.vendor_id  || ''','                                  || CHR(10)
      || '  TO_CHAR(src.' || p_src.time_col || '),'                          || CHR(10)
      || '  src.' || p_src.entity_id_col || ','                              || CHR(10)
      || '  ''entity_key'','                                                   || CHR(10)
      || '  NULL,'                                                             || CHR(10)
      || '  ''ENTITY_NOT_FOUND'','                                            || CHR(10)
      || '  ''No xref: vendor=' || p_src.vendor_id || ''','                   || CHR(10)
      || '  SYSDATE, ''N'''                                                   || CHR(10)
      || 'FROM ' || p_src.source_schema || '.' || p_src.source_table || ' src' || CHR(10)
      || 'WHERE ' || p_currency_filter                                        || CHR(10)
      || 'AND NOT EXISTS ('                                                    || CHR(10)
      || '  SELECT 1 FROM udm_entity_xref'                                   || CHR(10)
      || '  WHERE vendor_id   = ''' || p_src.vendor_id || ''''               || CHR(10)
      || '  AND   external_id = src.' || p_src.entity_id_col                 || CHR(10)
      || '  AND   effective_to IS NULL)';

    RETURN l_sql;
  END p_build_entity_quarantine_sql;

  -- ==========================================================================
  -- PRIVATE: COMPANY_SECTOR PRE-PASS
  -- Creates missing composite entities in bulk BEFORE the main INSERT.
  -- Uses FORALL for all collection inserts — no row-by-row entity creation.
  -- ==========================================================================
  PROCEDURE p_bulk_create_cs_entities (
    p_src             IN t_src_rec,
    p_company_col     IN VARCHAR2,   -- source column for company external_id
    p_sector_col      IN VARCHAR2,   -- source column for sector external_id
    p_currency_filter IN VARCHAR2
  ) IS
    -- Collections for new CS entities to create
    l_co_ext_ids   t_varchar200_tab;
    l_sec_ext_ids  t_varchar200_tab;
    l_co_keys      t_varchar20_tab;
    l_sec_keys     t_varchar20_tab;
    l_cs_keys      t_varchar20_tab;
    l_mem_ids_co   t_varchar20_tab;  -- membership IDs for COMPANY_COMPONENT rows
    l_mem_ids_sec  t_varchar20_tab;  -- membership IDs for SECTOR_COMPONENT rows
    l_cs_names     t_varchar200_tab;
    l_seqs         t_number_tab;

    l_n        PLS_INTEGER;
    l_cache_key VARCHAR2(41);
  BEGIN
    -- Step 1: BULK COLLECT distinct (company, sector) pairs not yet in MV
    EXECUTE IMMEDIATE
      'SELECT DISTINCT src.' || p_company_col || ', src.' || p_sector_col
      || ' FROM ' || p_src.source_schema || '.' || p_src.source_table || ' src'
      || ' WHERE ' || p_currency_filter
      || ' AND NOT EXISTS ('
      || '   SELECT 1 FROM udm_company_sector_mv mv'
      || '   JOIN udm_entity_xref xc'
      || '     ON xc.entity_key = mv.company_entity_key'
      || '    AND xc.vendor_id  = ''' || p_src.vendor_id || ''''
      || '    AND xc.external_id = src.' || p_company_col
      || '    AND xc.effective_to IS NULL'
      || '   JOIN udm_entity_xref xs'
      || '     ON xs.entity_key = mv.sector_entity_key'
      || '    AND xs.vendor_id  = ''' || p_src.vendor_id || ''''
      || '    AND xs.external_id = src.' || p_sector_col
      || '    AND xs.effective_to IS NULL)'
    BULK COLLECT INTO l_co_ext_ids, l_sec_ext_ids;

    l_n := NVL(l_co_ext_ids.COUNT, 0);
    IF l_n = 0 THEN RETURN; END IF;  -- nothing to create

    -- Step 2: Resolve component entity_keys (loop is over distinct pairs — small)
    l_co_keys.DELETE; l_sec_keys.DELETE;
    l_co_keys.EXTEND(l_n); l_sec_keys.EXTEND(l_n);

    FOR i IN 1 .. l_n LOOP
      BEGIN
        SELECT entity_key INTO l_co_keys(i)
        FROM   udm_entity_xref
        WHERE  vendor_id = p_src.vendor_id AND external_id = l_co_ext_ids(i)
        AND    effective_to IS NULL;
      EXCEPTION WHEN NO_DATA_FOUND THEN l_co_keys(i) := NULL;
      END;
      BEGIN
        SELECT entity_key INTO l_sec_keys(i)
        FROM   udm_entity_xref
        WHERE  vendor_id = p_src.vendor_id AND external_id = l_sec_ext_ids(i)
        AND    effective_to IS NULL;
      EXCEPTION WHEN NO_DATA_FOUND THEN l_sec_keys(i) := NULL;
      END;
    END LOOP;

    -- Step 3: Pre-generate entity_key sequence values in one SELECT
    SELECT udm_entity_seq.NEXTVAL
    BULK COLLECT INTO l_seqs
    FROM dual CONNECT BY ROWNUM <= l_n;

    -- Pre-generate two sets of membership IDs (one per component type)
    l_cs_keys.EXTEND(l_n);
    l_cs_names.EXTEND(l_n);
    l_mem_ids_co.EXTEND(l_n);
    l_mem_ids_sec.EXTEND(l_n);

    FOR i IN 1 .. l_n LOOP
      l_cs_keys(i)   := 'ENT-CS-' || LPAD(l_seqs(i), 6, '0');
      l_cs_names(i)  := 'CS:' || NVL(l_co_keys(i),'?') || '/' || NVL(l_sec_keys(i),'?');
    END LOOP;

    -- Pre-generate membership sequence values (2 rows per entity)
    DECLARE l_mem_seqs t_number_tab;
    BEGIN
      SELECT udm_membership_seq.NEXTVAL
      BULK COLLECT INTO l_mem_seqs
      FROM dual CONNECT BY ROWNUM <= l_n * 2;

      FOR i IN 1 .. l_n LOOP
        l_mem_ids_co(i)  := 'MEM-' || LPAD(l_mem_seqs(i),        8, '0');
        l_mem_ids_sec(i) := 'MEM-' || LPAD(l_mem_seqs(l_n + i),  8, '0');
      END LOOP;
    END;

    -- Step 4: FORALL INSERT into udm_entity_registry
    FORALL i IN 1 .. l_n
      INSERT INTO udm_entity_registry
        (entity_key, entity_type, canonical_name, is_active, effective_from, created_date)
      VALUES
        (l_cs_keys(i), 'COMPANY_SECTOR', l_cs_names(i), 'Y', TRUNC(SYSDATE), SYSDATE);

    -- Step 5: FORALL INSERT COMPANY_COMPONENT membership rows
    FORALL i IN 1 .. l_n
      INSERT INTO udm_entity_membership
        (membership_id, entity_key, parent_entity_key, relationship_type,
         effective_from, created_date, created_by)
      VALUES
        (l_mem_ids_co(i), l_cs_keys(i), l_co_keys(i), 'COMPANY_COMPONENT',
         TRUNC(SYSDATE), SYSDATE, 'UDM_ENGINE');

    -- Step 6: FORALL INSERT SECTOR_COMPONENT membership rows
    FORALL i IN 1 .. l_n
      INSERT INTO udm_entity_membership
        (membership_id, entity_key, parent_entity_key, relationship_type,
         effective_from, created_date, created_by)
      VALUES
        (l_mem_ids_sec(i), l_cs_keys(i), l_sec_keys(i), 'SECTOR_COMPONENT',
         TRUNC(SYSDATE), SYSDATE, 'UDM_ENGINE');

    -- Step 7: Single COMMIT — triggers udm_company_sector_mv refresh
    COMMIT;

    -- Step 8: Populate session cache so the main INSERT JOIN finds them
    FOR i IN 1 .. l_n LOOP
      IF l_co_keys(i) IS NOT NULL AND l_sec_keys(i) IS NOT NULL THEN
        l_cache_key := l_co_keys(i) || '|' || l_sec_keys(i);
        g_cs_cache(l_cache_key) := l_cs_keys(i);
      END IF;
    END LOOP;

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RAISE_APPLICATION_ERROR(-20210,
        'p_bulk_create_cs_entities failed: ' || SQLERRM);
  END p_bulk_create_cs_entities;

  -- ==========================================================================
  -- PRIVATE: SOURCE ROLE PROCESSORS
  -- ==========================================================================

  -- --------------------------------------------------------------------------
  -- DATA_SOURCE path
  -- --------------------------------------------------------------------------
  PROCEDURE p_process_data_source (
    p_src        IN  t_src_rec,
    p_attrs      IN  t_attr_tab,
    p_lineage_id IN  VARCHAR2
  ) IS
    l_currency     VARCHAR2(500);
    l_insert_sql   VARCHAR2(32767);
    l_quarantine_sql VARCHAR2(4000);
    l_data_version NUMBER := 1;
    l_rows_written NUMBER := 0;
    l_rows_q       NUMBER := 0;
    l_stk_table    VARCHAR2(128) :=
      'udm.udm_' || LOWER(REPLACE(p_src.domain_id, '-', '_')) || '_stk';

    -- Company/sector column names for COMPANY_SECTOR pre-pass
    l_co_col   VARCHAR2(128);
    l_sec_col  VARCHAR2(128);
  BEGIN
    l_currency := p_build_currency_filter(p_src);

    -- -----------------------------------------------------------------------
    -- COMPANY_SECTOR pre-pass: create missing composite entities in bulk
    -- Must run before the main INSERT so the xref JOIN in the main SQL finds them.
    -- -----------------------------------------------------------------------
    IF p_src.domain_grain LIKE '%COMPANY_SECTOR%'
       AND p_src.subject_type = 'ENTITY' THEN
      -- Identify the company and sector source columns from the attr map
      FOR i IN 1 .. p_attrs.COUNT LOOP
        IF LOWER(p_attrs(i).canonical_name) LIKE '%company%'
           AND p_attrs(i).is_subject_key = 'Y' THEN
          l_co_col := p_attrs(i).source_attribute;
        END IF;
        IF LOWER(p_attrs(i).canonical_name) LIKE '%sector%'
           AND p_attrs(i).is_subject_key = 'Y' THEN
          l_sec_col := p_attrs(i).source_attribute;
        END IF;
      END LOOP;
      IF l_co_col IS NOT NULL AND l_sec_col IS NOT NULL THEN
        p_bulk_create_cs_entities(p_src, l_co_col, l_sec_col, l_currency);
      END IF;
    END IF;

    -- -----------------------------------------------------------------------
    -- Compute data_version: how many deliveries already loaded for this vendor
    -- (period-agnostic — counts distinct delivery events in lineage)
    -- -----------------------------------------------------------------------
    BEGIN
      EXECUTE IMMEDIATE
        'SELECT NVL(MAX(data_version), 0) + 1'
        || ' FROM ' || l_stk_table
        || ' WHERE source_vendor = :v'
        INTO l_data_version USING p_src.vendor_id;
    EXCEPTION WHEN OTHERS THEN l_data_version := 1;
    END;

    -- -----------------------------------------------------------------------
    -- Mark prior rows for this vendor as NOT current (set-based UPDATE)
    -- Runs before the INSERT so is_current = 'Y' identifies this load only.
    -- -----------------------------------------------------------------------
    EXECUTE IMMEDIATE
      'UPDATE ' || l_stk_table
      || ' SET is_current = ''N'''
      || ' WHERE source_vendor = :v AND is_current = ''Y'''
      USING p_src.vendor_id;

    -- -----------------------------------------------------------------------
    -- Main INSERT…SELECT — transforms embedded, entity resolution via JOIN
    -- -----------------------------------------------------------------------
    l_insert_sql := CASE p_src.source_format
      WHEN 'EAV'      THEN p_build_eav_insert_sql     (p_src, p_attrs, l_currency, l_data_version)
      WHEN 'COLUMNAR' THEN p_build_columnar_insert_sql (p_src, p_attrs, l_currency, l_data_version)
      ELSE                 p_build_columnar_insert_sql (p_src, p_attrs, l_currency, l_data_version)
    END;

    EXECUTE IMMEDIATE l_insert_sql USING p_lineage_id;
    l_rows_written := SQL%ROWCOUNT;

    -- -----------------------------------------------------------------------
    -- Quarantine INSERT…SELECT — rows that failed entity resolution (NOT EXISTS)
    -- Only for ENTITY subject_type; INTERNAL_ID and SPATIAL have no xref
    -- -----------------------------------------------------------------------
    l_quarantine_sql := p_build_entity_quarantine_sql(p_src, l_currency);
    IF l_quarantine_sql IS NOT NULL THEN
      EXECUTE IMMEDIATE l_quarantine_sql USING p_lineage_id;
      l_rows_q := SQL%ROWCOUNT;
    END IF;

    COMMIT;

    udm_pkg_lineage.close_batch(
      p_lineage_id, 'COMPLETE',
      p_rows_written     => l_rows_written + l_rows_q,
      p_rows_written     => l_rows_written,
      p_rows_quarantined => l_rows_q);

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      udm_pkg_lineage.close_batch(p_lineage_id, 'FAILED',
        p_error_message => SQLERRM);
      RAISE;
  END p_process_data_source;

  -- --------------------------------------------------------------------------
  -- IDENTITY_SOURCE path
  -- BULK COLLECT new entities → FORALL INSERT (no row-by-row)
  -- --------------------------------------------------------------------------
  PROCEDURE p_process_identity_source (
    p_src        IN t_src_rec,
    p_attrs      IN t_attr_tab,
    p_lineage_id IN VARCHAR2
  ) IS
    l_id_map    udm_identity_source_map%ROWTYPE;
    l_currency  VARCHAR2(500) := p_build_currency_filter(p_src);

    -- Arrays for new entities (those not already in xref)
    l_ext_ids    t_varchar200_tab;
    l_canon_nms  t_varchar200_tab;
    l_ent_keys   t_varchar20_tab;
    l_xref_ids   t_varchar20_tab;
    l_seqs       t_number_tab;
    l_xref_seqs  t_number_tab;
    l_rows_written NUMBER := 0;
    l_rows_q       NUMBER := 0;
    l_n            PLS_INTEGER;
  BEGIN
    SELECT * INTO l_id_map
    FROM   udm_identity_source_map
    WHERE  source_id = p_src.source_id AND is_active = 'Y' AND ROWNUM = 1;

    -- Step 1: BULK COLLECT only the NEW external_ids (not already in xref)
    EXECUTE IMMEDIATE
      'SELECT src.' || l_id_map.external_id_col
      || ', '
      || CASE WHEN l_id_map.canonical_name_col IS NOT NULL
              THEN 'src.' || l_id_map.canonical_name_col
              ELSE 'src.' || l_id_map.external_id_col END
      || ' FROM ' || p_src.source_schema || '.' || p_src.source_table || ' src'
      || ' WHERE ' || l_currency
      || ' AND NOT EXISTS ('
      || '   SELECT 1 FROM udm_entity_xref'
      || '   WHERE vendor_id   = ''' || p_src.vendor_id || ''''
      || '   AND   external_id = src.' || l_id_map.external_id_col
      || '   AND   effective_to IS NULL)'
    BULK COLLECT INTO l_ext_ids, l_canon_nms;

    l_n := NVL(l_ext_ids.COUNT, 0);

    IF l_n > 0 THEN
      IF l_id_map.resolution_target = 'REGISTRY_AND_XREF' THEN
        -- Pre-generate entity_key sequence values in bulk
        SELECT udm_entity_seq.NEXTVAL
        BULK COLLECT INTO l_seqs
        FROM dual CONNECT BY ROWNUM <= l_n;

        SELECT udm_xref_seq.NEXTVAL
        BULK COLLECT INTO l_xref_seqs
        FROM dual CONNECT BY ROWNUM <= l_n;

        l_ent_keys.EXTEND(l_n);
        l_xref_ids.EXTEND(l_n);
        FOR i IN 1 .. l_n LOOP
          l_ent_keys(i) := 'ENT-' || LPAD(l_seqs(i), 6, '0');
          l_xref_ids(i) := 'XRF-' || LPAD(l_xref_seqs(i), 8, '0');
        END LOOP;

        -- FORALL INSERT into udm_entity_registry
        FORALL i IN 1 .. l_n
          INSERT INTO udm_entity_registry
            (entity_key, entity_type, canonical_name, is_active,
             effective_from, created_date)
          VALUES
            (l_ent_keys(i), l_id_map.entity_type, l_canon_nms(i),
             'Y', TRUNC(SYSDATE), SYSDATE);

        -- FORALL INSERT into udm_entity_xref
        FORALL i IN 1 .. l_n
          INSERT INTO udm_entity_xref
            (xref_id, entity_key, vendor_id, external_id,
             effective_from, created_date)
          VALUES
            (l_xref_ids(i), l_ent_keys(i), p_src.vendor_id, l_ext_ids(i),
             TRUNC(SYSDATE), SYSDATE);

        l_rows_written := l_n;

      ELSIF l_id_map.resolution_target = 'XREF_ONLY' THEN
        -- Entity must pre-exist — quarantine all unresolved via INSERT…SELECT
        EXECUTE IMMEDIATE
          'INSERT INTO udm_quarantine'
          || ' (quarantine_id, lineage_id, source_id, domain_id, vendor_id,'
          || '  coverage_period, entity_id_raw, attribute_name,'
          || '  check_type, rejection_reason, quarantined_at, resolved_flag)'
          || ' SELECT ''QUA-'' || TO_CHAR(SYSDATE,''YYYYMMDD'') || ''-'''
          || '   || LPAD(udm_quarantine_seq.NEXTVAL,8,''0''),'
          || '  :lin, :src, :dom, :vid,'
          || '  NULL, src.' || l_id_map.external_id_col || ', ''entity_key'','
          || '  ''ENTITY_NOT_FOUND'','
          || '  ''XREF_ONLY: no registry entry for external_id='' || src.' || l_id_map.external_id_col || ','
          || '  SYSDATE, ''N'''
          || ' FROM ' || p_src.source_schema || '.' || p_src.source_table || ' src'
          || ' WHERE ' || l_currency
          || ' AND NOT EXISTS (SELECT 1 FROM udm_entity_xref'
          || '   WHERE vendor_id = ''' || p_src.vendor_id || ''''
          || '   AND external_id = src.' || l_id_map.external_id_col
          || '   AND effective_to IS NULL)'
          USING p_lineage_id, p_src.source_id, p_src.domain_id, p_src.vendor_id;
        l_rows_q := SQL%ROWCOUNT;
      END IF;
    END IF;

    COMMIT;
    udm_pkg_lineage.close_batch(
      p_lineage_id, 'COMPLETE',
      p_rows_read        => l_n,
      p_rows_written     => l_rows_written,
      p_rows_quarantined => l_rows_q);

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      udm_pkg_lineage.close_batch(p_lineage_id, 'FAILED',
        p_error_message => SQLERRM);
      RAISE;
  END p_process_identity_source;

  -- --------------------------------------------------------------------------
  -- REFERENCE_SOURCE path — already set-based; unchanged structurally
  -- --------------------------------------------------------------------------
  PROCEDURE p_process_reference_source (
    p_src        IN t_src_rec,
    p_lineage_id IN VARCHAR2
  ) IS
    l_ref_map    udm_ref_source_map%ROWTYPE;
    l_currency   VARCHAR2(500) := p_build_currency_filter(p_src);
    l_rows       NUMBER := 0;
  BEGIN
    SELECT * INTO l_ref_map
    FROM   udm_ref_source_map
    WHERE  source_id = p_src.source_id AND is_active = 'Y' AND ROWNUM = 1;

    CASE l_ref_map.refresh_strategy
      WHEN 'FULL_REPLACE' THEN
        EXECUTE IMMEDIATE 'TRUNCATE TABLE udm.' || l_ref_map.ref_table_name;
        EXECUTE IMMEDIATE
          'INSERT /*+ APPEND */ INTO udm.' || l_ref_map.ref_table_name
          || ' SELECT * FROM ' || p_src.source_schema || '.' || p_src.source_table || ' src'
          || ' WHERE ' || l_currency;
        l_rows := SQL%ROWCOUNT;

      WHEN 'EFFECTIVE_DATE_MERGE' THEN
        -- Close current rows, insert new effective_from rows in two statements
        EXECUTE IMMEDIATE
          'UPDATE udm.' || l_ref_map.ref_table_name
          || ' SET effective_to = TRUNC(SYSDATE)'
          || ' WHERE effective_to IS NULL'
          || ' AND entity_key IN ('
          || '   SELECT entity_key FROM ' || p_src.source_schema
          || '   .' || p_src.source_table || ' src WHERE ' || l_currency || ')';

        EXECUTE IMMEDIATE
          'INSERT /*+ APPEND */ INTO udm.' || l_ref_map.ref_table_name
          || ' SELECT * FROM ' || p_src.source_schema || '.' || p_src.source_table || ' src'
          || ' WHERE ' || l_currency;
        l_rows := SQL%ROWCOUNT;

      WHEN 'INCREMENTAL' THEN
        EXECUTE IMMEDIATE
          'MERGE INTO udm.' || l_ref_map.ref_table_name || ' tgt'
          || ' USING (SELECT * FROM ' || p_src.source_schema || '.' || p_src.source_table
          || ' WHERE ' || l_currency || ') src'
          || ' ON (' || l_ref_map.ref_natural_key_cols || ')'
          || ' WHEN MATCHED    THEN UPDATE SET tgt.modified_date = SYSDATE'
          || ' WHEN NOT MATCHED THEN INSERT VALUES (src.*)';
        l_rows := SQL%ROWCOUNT;
    END CASE;

    COMMIT;
    udm_pkg_lineage.close_batch(p_lineage_id, 'COMPLETE', NULL, l_rows);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      udm_pkg_lineage.close_batch(p_lineage_id, 'FAILED',
        p_error_message => SQLERRM);
      RAISE;
  END p_process_reference_source;

  -- ==========================================================================
  -- PUBLIC
  -- ==========================================================================

  PROCEDURE flush_cs_cache IS
  BEGIN g_cs_cache.DELETE; END;

  -- --------------------------------------------------------------------------
  PROCEDURE run_source (p_source_id IN VARCHAR2) IS
    l_src         t_src_rec;
    l_attrs       t_attr_tab;
    l_lineage_id  VARCHAR2(30);
    l_manifest_id VARCHAR2(30);
    l_hint_period VARCHAR2(20);
  BEGIN
    -- Gate 1: load and validate source registration
    p_load_source_rec(p_source_id, l_src);

    IF l_src.governance_status NOT IN ('UDM_CATALOGED', 'MIGRATING') THEN
      RAISE_APPLICATION_ERROR(-20203,
        'Source ' || p_source_id || ' governance_status='
        || l_src.governance_status || '. Engine skips non-UDM sources.');
    END IF;

    -- Gate 2: column retirement block
    p_check_pending_retirement(p_source_id);

    -- Gate 3: find the pending COMPLETE manifest (self-discovering — no caller input)
    p_find_pending_manifest(p_source_id, l_src.vendor_id,
                            l_manifest_id, l_hint_period);

    -- BULK COLLECT attribute map
    p_load_attr_map(p_source_id, l_attrs);
    IF l_attrs.COUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20204,
        'No ACTIVE attribute mappings for source=' || p_source_id);
    END IF;

    -- Open lineage
    l_lineage_id := udm_pkg_lineage.open_batch(
      p_lineage_type    => 'LOAD',
      p_source_id       => l_src.source_id,
      p_domain_id       => l_src.domain_id,
      p_vendor_id       => l_src.vendor_id,
      p_coverage_period => l_hint_period,   -- informational; not used as filter
      p_manifest_id     => l_manifest_id
    );

    -- Route on source_role
    CASE l_src.source_role
      WHEN 'DATA_SOURCE' THEN
        p_process_data_source(l_src, l_attrs, l_lineage_id);
      WHEN 'IDENTITY_SOURCE' THEN
        p_process_identity_source(l_src, l_attrs, l_lineage_id);
      WHEN 'REFERENCE_SOURCE' THEN
        p_process_reference_source(l_src, l_lineage_id);
      ELSE
        RAISE_APPLICATION_ERROR(-20205, 'Unknown source_role: ' || l_src.source_role);
    END CASE;

    flush_cs_cache;

  EXCEPTION
    WHEN OTHERS THEN
      flush_cs_cache;
      IF l_lineage_id IS NOT NULL THEN
        udm_pkg_lineage.close_batch(l_lineage_id, 'FAILED',
          p_error_message => SQLERRM);
      END IF;
      RAISE;
  END run_source;

  -- --------------------------------------------------------------------------
  PROCEDURE run_domain (p_domain_id IN VARCHAR2) IS
    CURSOR c IS
      SELECT source_id
      FROM   udm_source_registry
      WHERE  domain_id         = p_domain_id
      AND    governance_status IN ('UDM_CATALOGED', 'MIGRATING')
      AND    effective_to IS NULL
      ORDER  BY CASE source_role
                  WHEN 'IDENTITY_SOURCE'  THEN 1
                  WHEN 'REFERENCE_SOURCE' THEN 2
                  WHEN 'DATA_SOURCE'      THEN 3
                  ELSE 4
                END;
  BEGIN
    FOR src IN c LOOP
      BEGIN
        run_source(src.source_id);
      EXCEPTION
        WHEN OTHERS THEN
          DBMS_OUTPUT.PUT_LINE(
            'ERROR: run_domain skipping ' || src.source_id || ': ' || SQLERRM);
      END;
    END LOOP;
  END run_domain;

END udm_pkg_harmonisation;
/
