-- ============================================================================
-- MODULE 6 — PATCH: lookup: transform → FROM clause LEFT JOIN
-- File    : udm_mod06_patch_lookup_join.sql
--
-- PROBLEM
-- -------
-- The original p_build_transform_expr() for rule = 'lookup:' emits:
--
--   (SELECT assurance_label
--    FROM   UDM.udm_ref_assurance
--    WHERE  id = src.ASSURANCE_CD AND ROWNUM = 1)
--
-- This is a correlated scalar subquery in the SELECT clause. Oracle
-- re-executes it once per source row. 50,000 rows × 3 lookup columns
-- = 150,000 single-row index lookups — each carrying its own parse,
-- execute and fetch cycle overhead.
--
-- FIX
-- ---
-- Push every lookup: target to the FROM clause as a LEFT JOIN. The join
-- executes once across all rows (one hash or nested-loop join per table).
-- The SELECT list references the join alias column instead of a subquery.
--
--   FROM rdm.V_EMISSIONS_VA src
--   JOIN udm_entity_xref xref  ON ...
--   LEFT JOIN UDM.udm_ref_assurance lkp_1    -- ← join, not subquery
--     ON lkp_1.assurance_code = src.ASSURANCE_CD
--
-- SYNTAX EXTENSION
-- ----------------
-- lookup: rule now takes four dot-separated segments:
--
--   lookup: schema . table . join_col . return_col
--
-- Example (attribute_map.transform_rule):
--   lookup:UDM.udm_ref_assurance.assurance_code.assurance_label
--            │         │               │               │
--            schema    table           join column     column to return
--                                      in ref table
--
-- The engine joins on:  lkp_N.join_col = src.source_attribute
-- The SELECT emits:     lkp_N.return_col
--
-- Existing three-segment form (schema.table.col) is still accepted for
-- backward compatibility — the engine assumes the join key is 'id'.
--
-- DEDUPLICATION
-- -------------
-- Multiple attributes can reference the same lookup table. The engine
-- detects this in the first pass (keyed by schema||table) and emits only
-- one LEFT JOIN per unique table, regardless of how many attributes use it.
--
-- LEFT JOIN, NOT INNER JOIN
-- -------------------------
-- Always LEFT JOIN so that a missing reference value returns NULL rather
-- than silently dropping the source row. A dropped row would bypass the
-- quarantine path and create invisible data loss. NULL in the metric column
-- is detected by the DI framework (COMPLETENESS check).
-- ============================================================================


-- ============================================================================
-- REPLACEMENT: p_build_transform_expr
-- lookup: case removed — handled upstream by p_collect_lookup_joins.
-- All other rules unchanged.
-- ============================================================================
CREATE OR REPLACE PACKAGE BODY udm.udm_pkg_harmonisation AS

  -- ... (all type declarations and other private procedures unchanged) ...

  -- --------------------------------------------------------------------------
  -- p_parse_lookup_rule
  -- Splits a lookup: rule string into its components.
  -- Four-segment: schema.table.join_col.return_col
  -- Three-segment: schema.table.return_col  (join_col defaults to 'id')
  -- --------------------------------------------------------------------------
  PROCEDURE p_parse_lookup_rule (
    p_rule        IN  VARCHAR2,   -- everything after 'lookup:'
    p_schema      OUT VARCHAR2,
    p_table       OUT VARCHAR2,
    p_join_col    OUT VARCHAR2,   -- column in ref table to match join key
    p_return_col  OUT VARCHAR2    -- column in ref table to fetch
  ) IS
    l_parts   SYS.ODCIVARCHAR2LIST;
  BEGIN
    SELECT TRIM(REGEXP_SUBSTR(p_rule, '[^.]+', 1, LEVEL))
    BULK COLLECT INTO l_parts
    FROM   dual
    CONNECT BY REGEXP_SUBSTR(p_rule, '[^.]+', 1, LEVEL) IS NOT NULL;

    IF l_parts.COUNT = 4 THEN
      -- schema.table.join_col.return_col
      p_schema     := l_parts(1);
      p_table      := l_parts(2);
      p_join_col   := l_parts(3);
      p_return_col := l_parts(4);

    ELSIF l_parts.COUNT = 3 THEN
      -- schema.table.return_col  (backward compatible — join on 'id')
      p_schema     := l_parts(1);
      p_table      := l_parts(2);
      p_join_col   := 'id';
      p_return_col := l_parts(3);

    ELSIF l_parts.COUNT = 2 THEN
      -- table.return_col — default schema = UDM
      p_schema     := 'UDM';
      p_table      := l_parts(1);
      p_join_col   := 'id';
      p_return_col := l_parts(2);

    ELSE
      RAISE_APPLICATION_ERROR(-20220,
        'Malformed lookup: rule — expected schema.table.join_col.return_col, got: '
        || p_rule);
    END IF;
  END p_parse_lookup_rule;


  -- --------------------------------------------------------------------------
  -- p_collect_lookup_joins
  -- PASS 1 over the attribute map.
  -- Finds all lookup: rules, deduplicates by target table, assigns aliases,
  -- builds the LEFT JOIN SQL fragment for the FROM clause.
  --
  -- Returns:
  --   p_join_sql     — zero or more LEFT JOIN clauses, ready to append to FROM
  --   p_alias_map    — keyed by transform_rule string → alias assigned
  --                    used by p_build_transform_expr to emit alias.col
  -- --------------------------------------------------------------------------
  PROCEDURE p_collect_lookup_joins (
    p_attrs        IN  t_attr_tab,
    p_join_sql     OUT VARCHAR2,
    p_alias_map    OUT SYS.ODCIVarchar2List  -- parallel to p_attrs: alias or NULL
  ) IS
    -- Dedup map: keyed by "schema.table" → alias already assigned
    TYPE t_dedup IS TABLE OF VARCHAR2(20) INDEX BY VARCHAR2(200);
    l_dedup      t_dedup;
    l_alias_n    PLS_INTEGER := 0;
    l_alias      VARCHAR2(20);
    l_dedup_key  VARCHAR2(200);
    l_schema     VARCHAR2(30);
    l_table      VARCHAR2(128);
    l_join_col   VARCHAR2(128);
    l_return_col VARCHAR2(128);
    l_rule_param VARCHAR2(200);
  BEGIN
    p_join_sql  := '';
    p_alias_map := SYS.ODCIVarchar2List();
    p_alias_map.EXTEND(p_attrs.COUNT);   -- one slot per attr (NULL if not lookup:)

    FOR i IN 1 .. p_attrs.COUNT LOOP
      IF p_attrs(i).transform_rule LIKE 'lookup:%' THEN
        l_rule_param := SUBSTR(p_attrs(i).transform_rule, 8);  -- strip 'lookup:'

        p_parse_lookup_rule(l_rule_param,
          l_schema, l_table, l_join_col, l_return_col);

        l_dedup_key := UPPER(l_schema) || '.' || UPPER(l_table);

        IF l_dedup.EXISTS(l_dedup_key) THEN
          -- Same table already joined — reuse alias
          l_alias := l_dedup(l_dedup_key);
        ELSE
          -- New table: assign alias, build LEFT JOIN clause
          l_alias_n := l_alias_n + 1;
          l_alias   := 'lkp_' || l_alias_n;
          l_dedup(l_dedup_key) := l_alias;

          p_join_sql := p_join_sql
            || 'LEFT JOIN ' || l_schema || '.' || l_table || ' ' || l_alias || CHR(10)
            || '  ON ' || l_alias || '.' || l_join_col
            || ' = src.' || p_attrs(i).source_attribute || CHR(10);
          -- Note: always LEFT JOIN — a NULL return is captured by DI completeness
          --       checks; an INNER JOIN would silently drop the entire source row.
        END IF;

        -- Store "alias.return_col" in alias_map slot for this attribute
        p_alias_map(i) := l_alias || '.' || l_return_col;
      ELSE
        p_alias_map(i) := NULL;   -- not a lookup: attribute
      END IF;
    END LOOP;
  END p_collect_lookup_joins;


  -- --------------------------------------------------------------------------
  -- p_build_transform_expr  (revised)
  -- lookup: case REMOVED — callers that use p_collect_lookup_joins
  -- pass the pre-resolved alias.col reference for lookup: attributes.
  -- All other rules identical to v2.
  -- --------------------------------------------------------------------------
  FUNCTION p_build_transform_expr (
    p_rule      IN VARCHAR2,
    p_src_col   IN VARCHAR2,
    p_attrs     IN t_attr_tab,
    p_vendor_id IN VARCHAR2
  ) RETURN VARCHAR2
  IS
    l_rule   VARCHAR2(200) := NVL(p_rule, 'direct');
    l_prefix VARCHAR2(30);
    l_param  VARCHAR2(200);
    l_sep    PLS_INTEGER;
    l_expr   VARCHAR2(4000);

    FUNCTION find_src_attr (p_canon IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
      FOR i IN 1 .. p_attrs.COUNT LOOP
        IF p_attrs(i).canonical_name = p_canon THEN
          RETURN p_attrs(i).source_attribute;
        END IF;
      END LOOP;
      RETURN NULL;
    END;

    FUNCTION coalesce_expr (p_list IN VARCHAR2) RETURN VARCHAR2 IS
      l_args  VARCHAR2(4000) := 'src.' || p_src_col;
      l_cn    VARCHAR2(200);
      l_sa    VARCHAR2(128);
      l_s     PLS_INTEGER := 1;
      l_e     PLS_INTEGER;
    BEGIN
      LOOP
        l_e  := INSTR(p_list || ',', ',', l_s);
        EXIT WHEN l_e = 0;
        l_cn := TRIM(SUBSTR(p_list, l_s, l_e - l_s));
        l_sa := find_src_attr(l_cn);
        IF l_sa IS NOT NULL THEN
          l_args := l_args || ', src.' || l_sa;
        END IF;
        l_s  := l_e + 1;
      END LOOP;
      RETURN 'COALESCE(' || l_args || ')';
    END;

  BEGIN
    l_sep    := INSTR(l_rule, ':');
    l_prefix := CASE WHEN l_sep > 0 THEN SUBSTR(l_rule, 1, l_sep-1) ELSE l_rule END;
    l_param  := CASE WHEN l_sep > 0 THEN SUBSTR(l_rule, l_sep+1)    ELSE NULL  END;

    CASE l_prefix
      WHEN 'direct'   THEN l_expr := 'src.' || p_src_col;
      WHEN 'multiply' THEN l_expr := 'src.' || p_src_col || ' * ' || l_param;

      WHEN 'divide' THEN
        DECLARE l_div VARCHAR2(128) := find_src_attr(l_param);
        BEGIN
          l_expr := CASE WHEN l_div IS NOT NULL
            THEN 'CASE WHEN NVL(src.' || l_div || ',0) = 0'
              || ' THEN NULL ELSE src.' || p_src_col || ' / src.' || l_div || ' END'
            ELSE 'src.' || p_src_col
          END;
        END;

      WHEN 'coalesce' THEN l_expr := coalesce_expr(l_param);

      WHEN 'flag' THEN
        DECLARE l_ps VARCHAR2(128) := find_src_attr(REGEXP_SUBSTR(l_param,'[^,]+',1,1));
        BEGIN
          l_expr := CASE WHEN l_ps IS NOT NULL
            THEN 'CASE WHEN src.' || l_ps || ' IS NOT NULL THEN ''DIRECT'' ELSE ''ESTIMATED'' END'
            ELSE '''DIRECT'''
          END;
        END;

      WHEN 'lookup' THEN
        -- Should not reach here — lookup: is resolved by p_collect_lookup_joins.
        -- Guard: emit a scalar subquery as a safe fallback so the SQL is still valid,
        -- but log a warning so the developer knows to call the two-pass builder.
        DBMS_OUTPUT.PUT_LINE('WARN: p_build_transform_expr called for lookup: rule "'
          || l_rule || '" — use p_collect_lookup_joins + two-pass build instead.');
        DECLARE
          l_s VARCHAR2(30); l_t VARCHAR2(128); l_j VARCHAR2(128); l_c VARCHAR2(128);
        BEGIN
          p_parse_lookup_rule(l_param, l_s, l_t, l_j, l_c);
          l_expr := '(SELECT ' || l_c || ' FROM ' || l_s || '.' || l_t
                 || ' WHERE ' || l_j || ' = src.' || p_src_col || ' AND ROWNUM=1)';
        END;

      WHEN 'rule_ref' THEN
        DECLARE l_rsql VARCHAR2(2000);
        BEGIN
          SELECT resolution_sql INTO l_rsql
          FROM   udm_transform_rules
          WHERE  rule_name = l_param AND is_active = 'Y'
          AND    (effective_to IS NULL OR effective_to > SYSDATE) AND ROWNUM=1;
          l_rsql := REPLACE(l_rsql, '{vendor_value}', 'src.' || p_src_col);
          l_rsql := REPLACE(l_rsql, '{vendor_id}',    '''' || p_vendor_id || '''');
          l_expr := '(' || l_rsql || ')';
        EXCEPTION WHEN NO_DATA_FOUND THEN l_expr := 'src.' || p_src_col;
        END;

      ELSE l_expr := 'src.' || p_src_col;
    END CASE;

    RETURN l_expr;
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('WARN transform rule=' || l_rule || ': ' || SQLERRM);
      RETURN 'src.' || p_src_col;
  END p_build_transform_expr;


  -- --------------------------------------------------------------------------
  -- p_build_columnar_insert_sql  (revised — two-pass, lookup: → LEFT JOIN)
  -- --------------------------------------------------------------------------
  FUNCTION p_build_columnar_insert_sql (
    p_src             IN t_src_rec,
    p_attrs           IN t_attr_tab,
    p_currency_filter IN VARCHAR2,
    p_data_version    IN NUMBER
  ) RETURN VARCHAR2
  IS
    l_join_sql    VARCHAR2(32767);
    l_alias_map   SYS.ODCIVarchar2List;
    l_col_list    VARCHAR2(32767);
    l_sel_list    VARCHAR2(32767);
    l_entity_join VARCHAR2(1000) := p_build_entity_join(p_src);
    l_stk_table   VARCHAR2(128)  :=
      'udm.udm_' || LOWER(REPLACE(p_src.domain_id,'-','_')) || '_stk';
    l_sel_expr    VARCHAR2(4000);
  BEGIN
    -- -------------------------------------------------------------------------
    -- PASS 1: collect lookup: targets → build LEFT JOIN clauses + alias map
    -- -------------------------------------------------------------------------
    p_collect_lookup_joins(p_attrs, l_join_sql, l_alias_map);

    -- -------------------------------------------------------------------------
    -- Standard header
    -- -------------------------------------------------------------------------
    l_col_list :=
      'entity_key, coverage_period, measurement_grain, source_vendor, '
      || 'data_version, is_current, delivery_date, lineage_id';

    l_sel_list :=
      p_entity_key_expr(p_src)                         || ', '
      || 'TO_CHAR(src.' || p_src.time_col || ')'       || ', '
      || '''' || p_src.domain_grain  || ''''            || ', '
      || '''' || p_src.vendor_id     || ''''            || ', '
      || TO_CHAR(p_data_version)                        || ', '
      || '''Y'''                                        || ', '
      || 'SYSDATE'                                      || ', '
      || ':b_lineage_id';

    -- -------------------------------------------------------------------------
    -- PASS 2: build SELECT expressions for each metric attribute
    -- lookup: attrs → alias_map(i) (e.g. lkp_1.assurance_label)
    -- all others  → inline expression from p_build_transform_expr
    -- -------------------------------------------------------------------------
    FOR i IN 1 .. p_attrs.COUNT LOOP
      IF p_attrs(i).is_subject_key = 'N' AND p_attrs(i).is_time_key = 'N' THEN
        l_col_list := l_col_list || ', ' || p_attrs(i).canonical_name;

        IF l_alias_map(i) IS NOT NULL THEN
          -- lookup: resolved to FROM-clause alias → reference directly
          l_sel_expr := l_alias_map(i);
        ELSE
          l_sel_expr := p_build_transform_expr(
            p_attrs(i).transform_rule,
            p_attrs(i).source_attribute,
            p_attrs,
            p_src.vendor_id
          );
        END IF;

        l_sel_list := l_sel_list || ', ' || l_sel_expr;
      END IF;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- Assemble: entity JOIN first, then any lookup LEFT JOINs
    -- -------------------------------------------------------------------------
    RETURN
      'INSERT /*+ APPEND */ INTO ' || l_stk_table || CHR(10)
      || '  (' || l_col_list || ')'  || CHR(10)
      || 'SELECT'                    || CHR(10)
      || '  ' || l_sel_list          || CHR(10)
      || 'FROM ' || p_src.source_schema || '.' || p_src.source_table || ' src' || CHR(10)
      || NVL(l_entity_join, '')      || CHR(10)
      || l_join_sql                  || CHR(10)   -- LEFT JOINs for lookup: attrs
      || 'WHERE ' || p_currency_filter;

  END p_build_columnar_insert_sql;


  -- --------------------------------------------------------------------------
  -- p_build_eav_insert_sql  (same two-pass change applied)
  -- EAV sources can also carry lookup: attributes on the value column.
  -- --------------------------------------------------------------------------
  FUNCTION p_build_eav_insert_sql (
    p_src             IN t_src_rec,
    p_attrs           IN t_attr_tab,
    p_currency_filter IN VARCHAR2,
    p_data_version    IN NUMBER
  ) RETURN VARCHAR2
  IS
    l_join_sql       VARCHAR2(32767);
    l_alias_map      SYS.ODCIVarchar2List;
    l_col_list       VARCHAR2(32767);
    l_sel_list       VARCHAR2(32767);
    l_pivot_cols     VARCHAR2(32767);
    l_entity_join    VARCHAR2(1000) := p_build_entity_join(p_src);
    l_stk_table      VARCHAR2(128)  :=
      'udm.udm_' || LOWER(REPLACE(p_src.domain_id,'-','_')) || '_stk';
    l_attr_name_col  VARCHAR2(128);
    l_attr_val_col   VARCHAR2(128);
    l_cast_expr      VARCHAR2(200);
  BEGIN
    p_collect_lookup_joins(p_attrs, l_join_sql, l_alias_map);

    IF p_attrs.COUNT > 0 THEN
      l_attr_name_col := p_attrs(1).attribute_name_column;
      l_attr_val_col  := p_attrs(1).attribute_value_column;
    END IF;

    l_col_list :=
      'entity_key, coverage_period, measurement_grain, source_vendor, '
      || 'data_version, is_current, delivery_date, lineage_id';

    l_sel_list :=
      p_entity_key_expr(p_src)                              || ', '
      || 'TO_CHAR(MAX(src.' || p_src.time_col || '))'      || ', '
      || '''' || p_src.domain_grain  || ''''                || ', '
      || '''' || p_src.vendor_id     || ''''                || ', '
      || TO_CHAR(p_data_version)                            || ', '
      || '''Y''';

    FOR i IN 1 .. p_attrs.COUNT LOOP
      IF p_attrs(i).attribute_name_value IS NOT NULL THEN

        IF l_alias_map(i) IS NOT NULL THEN
          -- lookup: on an EAV attribute — join alias inside the CASE expression
          -- The alias resolves across the GROUP BY via MAX()
          l_pivot_cols := l_pivot_cols
            || ', MAX(CASE WHEN src.' || l_attr_name_col
            || ' = ''' || p_attrs(i).attribute_name_value || ''''
            || ' THEN ' || l_alias_map(i) || ' END)';
        ELSE
          l_cast_expr := CASE p_attrs(i).attribute_value_data_type
            WHEN 'NUMBER' THEN 'TO_NUMBER(src.' || l_attr_val_col || ')'
            WHEN 'DATE'   THEN 'TO_DATE(src.'   || l_attr_val_col || ',''YYYY-MM-DD'')'
            ELSE               'src.' || l_attr_val_col
          END;
          l_pivot_cols := l_pivot_cols
            || ', MAX(CASE WHEN src.' || l_attr_name_col
            || ' = ''' || p_attrs(i).attribute_name_value || ''''
            || ' THEN ' || l_cast_expr || ' END)';
        END IF;

        l_col_list := l_col_list || ', ' || p_attrs(i).canonical_name;
      END IF;
    END LOOP;

    l_sel_list := l_sel_list
      || ', SYSDATE, :b_lineage_id'
      || l_pivot_cols;

    RETURN
      'INSERT /*+ APPEND */ INTO ' || l_stk_table           || CHR(10)
      || '  (' || l_col_list || ')'                         || CHR(10)
      || 'SELECT'                                           || CHR(10)
      || '  ' || l_sel_list                                 || CHR(10)
      || 'FROM ' || p_src.source_schema || '.' || p_src.source_table || ' src' || CHR(10)
      || NVL(l_entity_join, '')                             || CHR(10)
      || l_join_sql                                         || CHR(10)
      || 'WHERE '  || p_currency_filter                     || CHR(10)
      || 'GROUP BY ' || p_entity_key_expr(p_src);

  END p_build_eav_insert_sql;

  -- ... remaining procedures (run_source, run_domain, etc.) unchanged ...

END udm_pkg_harmonisation;
/
