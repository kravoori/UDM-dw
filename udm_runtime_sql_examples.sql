-- ============================================================================
-- UDM ENGINE — RUNTIME SQL EXAMPLES
-- Domain  : EMISSIONS
-- Sources : VENDOR_A (COLUMNAR) and VENDOR_B (EAV)
-- Purpose : Shows exactly what INSERT statements the harmonisation engine
--           builds and executes from the catalog at runtime.
--
-- Structure of this file:
--   SECTION 1  — Catalog seed data (source_registry + attribute_map)
--   SECTION 2  — Sample source data (what vendor tables contain)
--   SECTION 3  — Engine-generated SQL: COLUMNAR path
--   SECTION 4  — Engine-generated SQL: EAV path
--   SECTION 5  — Engine-generated SQL: quarantine path (both sources)
--   SECTION 6  — Expected stack output after both loads
-- ============================================================================


-- ============================================================================
-- SECTION 1 — CATALOG SEED DATA
-- This is what the catalog team inserts during source onboarding.
-- The engine reads these rows at runtime to generate the SQL in Sections 3–5.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1A. Source Registry — VENDOR_A  (COLUMNAR)
-- ----------------------------------------------------------------------------
INSERT INTO udm_source_registry (
  source_id,   vendor_id,   domain_id,   source_schema,  source_table,
  source_format, currency_mechanism, current_flag_column,
  entity_id_col, time_col,  source_role, subject_type,
  domain_grain,  governance_status, effective_from, created_by
) VALUES (
  'SRC-E-001', 'VENDOR_A',  'EMISSIONS',  'RDM',          'V_EMISSIONS_VA',
  'COLUMNAR',   'CURRENT_FLAG',     'IS_CURRENT',
  'COMPANY_CD',  'FISCAL_YR', 'DATA_SOURCE', 'ENTITY',
  'COMPANY-FISCAL_YEAR', 'UDM_CATALOGED', DATE '2024-01-01', 'CATALOG_TEAM'
);

-- ----------------------------------------------------------------------------
-- 1B. Attribute Map — VENDOR_A (COLUMNAR)
--
-- Source columns in RDM.V_EMISSIONS_VA:
--   COMPANY_CD      VARCHAR2   company identifier
--   FISCAL_YR       VARCHAR2   e.g. '2023', '2024'
--   SC1_TONNE       NUMBER     Scope 1 in metric tonnes CO2e
--   SC2_TONNE       NUMBER     Scope 2 (market-based) in metric tonnes CO2e
--   SC3_TONNE       NUMBER     Scope 3 total — may be NULL if vendor omits
--   SC3_UPSTREAM    NUMBER     Upstream estimate used when SC3_TONNE is NULL
--   REVENUE_MUSD    NUMBER     Revenue in millions USD (denominator for intensity)
--   ASSURANCE_CD    VARCHAR2   Vendor assurance code e.g. 'LTD', 'REAS', 'NONE'
--   IS_CURRENT      CHAR(1)    'Y' = current row (currency_mechanism)
-- ----------------------------------------------------------------------------

-- Subject key (entity identifier)
INSERT INTO udm_attribute_map (
  map_id,      source_id,    source_attribute, canonical_name,
  transform_rule,  data_type,  is_subject_key, is_time_key, is_mandatory,
  map_status, effective_from, created_by
) VALUES (
  'MAP-E-001', 'SRC-E-001',  'COMPANY_CD',     'company_external_id',
  'direct',        'VARCHAR',  'Y',            'N',         'Y',
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM'
);

-- Time key (coverage period)
INSERT INTO udm_attribute_map VALUES (
  'MAP-E-002', 'SRC-E-001',  'FISCAL_YR',      'coverage_period_src',
  'direct',        'VARCHAR',  'N',            'Y',         'Y',
  NULL, NULL, NULL, NULL, 'N', NULL, NULL,
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM', NULL, NULL
);

-- Scope 1: direct copy. Mandatory — vendor must always provide this.
INSERT INTO udm_attribute_map (
  map_id,      source_id,    source_attribute, canonical_name,
  transform_rule,  data_type,  is_subject_key, is_time_key, is_mandatory,
  map_status, effective_from, created_by
) VALUES (
  'MAP-E-003', 'SRC-E-001',  'SC1_TONNE',      'scope1_mtco2',
  'direct',        'NUMBER',   'N',            'N',         'Y',
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM'
);

-- Scope 2: direct copy.
INSERT INTO udm_attribute_map (
  map_id,      source_id,    source_attribute, canonical_name,
  transform_rule,  data_type,  is_subject_key, is_time_key, is_mandatory,
  map_status, effective_from, created_by
) VALUES (
  'MAP-E-004', 'SRC-E-001',  'SC2_TONNE',      'scope2_mtco2',
  'direct',        'NUMBER',   'N',            'N',         'N',
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM'
);

-- Scope 3 total: coalesce — fall back to upstream estimate if total is NULL.
-- primary = SC3_TONNE; fallback canonical_name = scope3_upstream_mtco2
INSERT INTO udm_attribute_map (
  map_id,      source_id,    source_attribute, canonical_name,
  transform_rule,             data_type,  is_subject_key, is_time_key, is_mandatory,
  map_status, effective_from, created_by
) VALUES (
  'MAP-E-005', 'SRC-E-001',  'SC3_TONNE',      'scope3_mtco2',
  'coalesce:scope3_upstream_mtco2', 'NUMBER', 'N',  'N',         'N',
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM'
);

-- Scope 3 upstream estimate: direct. Always loaded regardless.
INSERT INTO udm_attribute_map (
  map_id,      source_id,    source_attribute, canonical_name,
  transform_rule,  data_type,  is_subject_key, is_time_key, is_mandatory,
  map_status, effective_from, created_by
) VALUES (
  'MAP-E-006', 'SRC-E-001',  'SC3_UPSTREAM',   'scope3_upstream_mtco2',
  'direct',        'NUMBER',   'N',            'N',         'N',
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM'
);

-- Scope 1 source flag: DIRECT if SC1_TONNE provided, else ESTIMATED.
-- flag:primary_canonical,fallback_canonical
INSERT INTO udm_attribute_map (
  map_id,      source_id,    source_attribute, canonical_name,
  transform_rule,                          data_type,  is_subject_key, is_time_key, is_mandatory,
  map_status, effective_from, created_by
) VALUES (
  'MAP-E-007', 'SRC-E-001',  'SC1_TONNE',      'scope1_source_flag',
  'flag:scope1_mtco2,scope3_upstream_mtco2', 'VARCHAR',  'N',            'N',         'N',
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM'
);

-- Revenue in millions USD: direct. Used as denominator for intensity metric.
INSERT INTO udm_attribute_map (
  map_id,      source_id,    source_attribute, canonical_name,
  transform_rule,  data_type,  is_subject_key, is_time_key, is_mandatory,
  map_status, effective_from, created_by
) VALUES (
  'MAP-E-008', 'SRC-E-001',  'REVENUE_MUSD',   'revenue_musd',
  'direct',        'NUMBER',   'N',            'N',         'N',
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM'
);

-- Carbon intensity = Scope1 / Revenue. divide: uses canonical_name of divisor.
-- Engine finds source_attribute for 'revenue_musd' = REVENUE_MUSD at build time.
INSERT INTO udm_attribute_map (
  map_id,      source_id,    source_attribute, canonical_name,
  transform_rule,       data_type,  is_subject_key, is_time_key, is_mandatory,
  map_status, effective_from, created_by
) VALUES (
  'MAP-E-009', 'SRC-E-001',  'SC1_TONNE',      'carbon_intensity_revenue',
  'divide:revenue_musd', 'NUMBER',   'N',            'N',         'N',
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM'
);

-- Assurance level: lookup — resolve vendor code to canonical label.
-- lookup:schema.table.return_col — scalar subquery embedded in SELECT.
INSERT INTO udm_attribute_map (
  map_id,      source_id,    source_attribute, canonical_name,
  transform_rule,                                data_type,  is_subject_key, is_time_key, is_mandatory,
  map_status, effective_from, created_by
) VALUES (
  'MAP-E-010', 'SRC-E-001',  'ASSURANCE_CD',   'assurance_level',
  'lookup:UDM.udm_ref_assurance.assurance_label', 'VARCHAR', 'N',  'N',         'N',
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM'
);


-- ----------------------------------------------------------------------------
-- 1C. Source Registry — VENDOR_B  (EAV)
-- Same domain, same canonical metrics. Different delivery format.
-- ----------------------------------------------------------------------------
INSERT INTO udm_source_registry (
  source_id,   vendor_id,   domain_id,   source_schema,  source_table,
  source_format, currency_mechanism, effective_to_column,
  entity_id_col, time_col,     source_role, subject_type,
  domain_grain,  governance_status, effective_from, created_by
) VALUES (
  'SRC-E-002', 'VENDOR_B',  'EMISSIONS',  'RDM',          'EAV_EMISSIONS_VB',
  'EAV',        'EFFECTIVE_DATES',  'ROW_EFF_TO',
  'ENTITY_REF',  'REPORT_PERIOD', 'DATA_SOURCE', 'ENTITY',
  'COMPANY-FISCAL_YEAR', 'UDM_CATALOGED', DATE '2024-01-01', 'CATALOG_TEAM'
);

-- ----------------------------------------------------------------------------
-- 1D. Attribute Map — VENDOR_B (EAV)
--
-- Source columns in RDM.EAV_EMISSIONS_VB:
--   ENTITY_REF      VARCHAR2   company identifier
--   REPORT_PERIOD   VARCHAR2   e.g. '2023', '2024'
--   ATTR_CODE       VARCHAR2   metric name e.g. 'SC1_GROSS', 'SC2_MKT'
--   ATTR_VAL        VARCHAR2   always VARCHAR — engine casts per data_type
--   ATTR_UNIT       VARCHAR2   unit code (separate EAV row, same ENTITY_REF+period)
--   ROW_EFF_TO      DATE       NULL = current (currency_mechanism = EFFECTIVE_DATES)
--
-- EAV columns (attribute_name_column, attribute_name_value, attribute_value_column)
-- must all be populated for EAV sources (constraint chk_attrmap_eav_columns).
-- ----------------------------------------------------------------------------

-- Scope 1
INSERT INTO udm_attribute_map (
  map_id,      source_id,    source_attribute, canonical_name,
  transform_rule, data_type, is_subject_key, is_time_key, is_mandatory,
  attribute_name_column, attribute_name_value, attribute_value_column, attribute_value_data_type,
  map_status, effective_from, created_by
) VALUES (
  'MAP-E-011', 'SRC-E-002',  'ATTR_VAL',       'scope1_mtco2',
  'direct',       'NUMBER',  'N',            'N',         'Y',
  'ATTR_CODE',           'SC1_GROSS',          'ATTR_VAL',            'NUMBER',
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM'
);

-- Scope 2
INSERT INTO udm_attribute_map (
  map_id,      source_id,    source_attribute, canonical_name,
  transform_rule, data_type, is_subject_key, is_time_key, is_mandatory,
  attribute_name_column, attribute_name_value, attribute_value_column, attribute_value_data_type,
  map_status, effective_from, created_by
) VALUES (
  'MAP-E-012', 'SRC-E-002',  'ATTR_VAL',       'scope2_mtco2',
  'direct',       'NUMBER',  'N',            'N',         'N',
  'ATTR_CODE',           'SC2_MKT',            'ATTR_VAL',            'NUMBER',
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM'
);

-- Scope 3 total
INSERT INTO udm_attribute_map (
  map_id,      source_id,    source_attribute, canonical_name,
  transform_rule, data_type, is_subject_key, is_time_key, is_mandatory,
  attribute_name_column, attribute_name_value, attribute_value_column, attribute_value_data_type,
  map_status, effective_from, created_by
) VALUES (
  'MAP-E-013', 'SRC-E-002',  'ATTR_VAL',       'scope3_mtco2',
  'direct',       'NUMBER',  'N',            'N',         'N',
  'ATTR_CODE',           'SC3_TOT',            'ATTR_VAL',            'NUMBER',
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM'
);

-- Revenue
INSERT INTO udm_attribute_map (
  map_id,      source_id,    source_attribute, canonical_name,
  transform_rule, data_type, is_subject_key, is_time_key, is_mandatory,
  attribute_name_column, attribute_name_value, attribute_value_column, attribute_value_data_type,
  map_status, effective_from, created_by
) VALUES (
  'MAP-E-014', 'SRC-E-002',  'ATTR_VAL',       'revenue_musd',
  'direct',       'NUMBER',  'N',            'N',         'N',
  'ATTR_CODE',           'REVENUE_M',          'ATTR_VAL',            'NUMBER',
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM'
);

-- Assurance level (EAV — value is a VARCHAR code, no cast needed)
INSERT INTO udm_attribute_map (
  map_id,      source_id,    source_attribute, canonical_name,
  transform_rule, data_type, is_subject_key, is_time_key, is_mandatory,
  attribute_name_column, attribute_name_value, attribute_value_column, attribute_value_data_type,
  map_status, effective_from, created_by
) VALUES (
  'MAP-E-015', 'SRC-E-002',  'ATTR_VAL',       'assurance_level',
  'direct',       'VARCHAR', 'N',            'N',         'N',
  'ATTR_CODE',           'ASSUR_LVL',          'ATTR_VAL',            'VARCHAR',
  'ACTIVE',   DATE '2024-01-01', 'CATALOG_TEAM'
);

COMMIT;


-- ============================================================================
-- SECTION 2 — SAMPLE SOURCE DATA
-- What actually exists in the vendor source tables at engine run time.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 2A. RDM.V_EMISSIONS_VA  — VENDOR_A COLUMNAR snapshot
-- IS_CURRENT = 'Y' rows are the current view (CURRENT_FLAG mechanism).
-- Two companies, two periods, one company missing SC3_TONNE (will use upstream).
-- One company (ZZZ-9999) has no xref entry → will go to quarantine.
-- ----------------------------------------------------------------------------

/*
COMPANY_CD   FISCAL_YR  SC1_TONNE   SC2_TONNE   SC3_TONNE  SC3_UPSTREAM  REVENUE_MUSD  ASSURANCE_CD  IS_CURRENT
-----------  ---------  ----------  ----------  ---------  ------------  ------------  ------------  ----------
ABC-0001     2024       12500.00    8300.00     45200.00   NULL          2850.00       LTD           Y
ABC-0001     2023       11900.00    8100.00     43100.00   NULL          2710.00       LTD           N   ← excluded
DEF-0002     2024       88200.00    31400.00    NULL       312000.00     14200.00      REAS          Y   ← SC3 NULL → coalesce fires
ZZZ-9999     2024       5100.00     2200.00     9800.00    NULL          980.00        NONE          Y   ← no xref → quarantine
*/

-- ----------------------------------------------------------------------------
-- 2B. RDM.EAV_EMISSIONS_VB  — VENDOR_B EAV rows
-- ROW_EFF_TO IS NULL = current (EFFECTIVE_DATES mechanism).
-- Same two companies but VENDOR_B uses different codes for metrics.
-- GHI-0003 is a company only VENDOR_B covers — xref exists, VENDOR_A does not have it.
-- ----------------------------------------------------------------------------

/*
ENTITY_REF   REPORT_PERIOD  ATTR_CODE   ATTR_VAL      ATTR_UNIT   ROW_EFF_TO
-----------  -------------  ----------  ------------  ----------  ----------
ABC-VA-001   2024           SC1_GROSS   12650.00      TONNE       NULL        ← ABC-0001 different vendor code
ABC-VA-001   2024           SC2_MKT     8100.00       TONNE       NULL
ABC-VA-001   2024           SC3_TOT     44800.00      TONNE       NULL
ABC-VA-001   2024           REVENUE_M   2850.00       MUSD        NULL
ABC-VA-001   2024           ASSUR_LVL   Limited       -           NULL
DEF-VA-002   2024           SC1_GROSS   89100.00      TONNE       NULL
DEF-VA-002   2024           SC2_MKT     30800.00      TONNE       NULL
DEF-VA-002   2024           SC3_TOT     NULL          TONNE       NULL        ← NULL value in EAV
DEF-VA-002   2024           REVENUE_M   14200.00      MUSD        NULL
DEF-VA-002   2024           ASSUR_LVL   Reasonable    -           NULL
GHI-VB-003   2024           SC1_GROSS   3200.00       TONNE       NULL        ← VENDOR_B only company
GHI-VB-003   2024           SC2_MKT     1100.00       TONNE       NULL
GHI-VB-003   2024           SC3_TOT     8900.00       TONNE       NULL
GHI-VB-003   2024           REVENUE_M   620.00        MUSD        NULL
ABC-VA-001   2023           SC1_GROSS   11800.00      TONNE       2024-01-15  ← old row excluded (ROW_EFF_TO NOT NULL)
*/


-- ============================================================================
-- SECTION 3 — ENGINE-GENERATED SQL: COLUMNAR PATH (SRC-E-001, VENDOR_A)
--
-- The engine calls p_build_columnar_insert_sql(p_src, p_attrs, l_currency, 1)
-- and executes this exact SQL via EXECUTE IMMEDIATE ... USING :b_lineage_id
--
-- HOW EACH LINE IS BUILT:
--   entity_key            ← p_entity_key_expr()      → xref.entity_key
--   coverage_period       ← hard-coded from time_col  → TO_CHAR(src.FISCAL_YR)
--   measurement_grain     ← domain_grain literal       → 'COMPANY-FISCAL_YEAR'
--   source_vendor         ← vendor_id literal          → 'VENDOR_A'
--   data_version          ← computed before INSERT     → 1
--   is_current / delivery ← literals                   → 'Y', SYSDATE
--   lineage_id            ← bind variable              → :b_lineage_id
--   scope1_mtco2          ← MAP-E-003, rule=direct     → src.SC1_TONNE
--   scope2_mtco2          ← MAP-E-004, rule=direct     → src.SC2_TONNE
--   scope3_mtco2          ← MAP-E-005, rule=coalesce   → COALESCE(src.SC3_TONNE, src.SC3_UPSTREAM)
--   scope3_upstream_mtco2 ← MAP-E-006, rule=direct     → src.SC3_UPSTREAM
--   scope1_source_flag    ← MAP-E-007, rule=flag       → CASE WHEN src.SC1_TONNE IS NOT NULL...
--   revenue_musd          ← MAP-E-008, rule=direct     → src.REVENUE_MUSD
--   carbon_intensity      ← MAP-E-009, rule=divide     → CASE WHEN NVL(src.REVENUE_MUSD,0)=0...
--   assurance_level       ← MAP-E-010, rule=lookup     → (SELECT ... FROM udm_ref_assurance ...)
--   JOIN to xref          ← p_build_entity_join()      → JOIN udm_entity_xref ON vendor_id+external_id
--   WHERE clause          ← p_build_currency_filter()  → src.IS_CURRENT = 'Y'
-- ============================================================================

-- Step A: flip prior rows to NOT current (set-based UPDATE before INSERT)
UPDATE udm.udm_emissions_stk
SET    is_current   = 'N'
WHERE  source_vendor = 'VENDOR_A'
AND    is_current    = 'Y';
-- Rows affected: however many VENDOR_A rows were previously is_current = 'Y'


-- Step B: main INSERT...SELECT  ← THIS IS WHAT p_build_columnar_insert_sql PRODUCES
INSERT /*+ APPEND */ INTO udm.udm_emissions_stk (
  entity_key,
  coverage_period,
  measurement_grain,
  source_vendor,
  data_version,
  is_current,
  delivery_date,
  lineage_id,
  -- metric columns (non-key, non-time attributes from attribute_map, ORDER BY canonical_name)
  assurance_level,
  carbon_intensity_revenue,
  revenue_musd,
  scope1_mtco2,
  scope1_source_flag,
  scope2_mtco2,
  scope3_mtco2,
  scope3_upstream_mtco2
)
SELECT
  xref.entity_key,                                              -- entity resolved via JOIN
  TO_CHAR(src.FISCAL_YR),                                       -- period from data, not a parameter
  'COMPANY-FISCAL_YEAR',                                        -- domain_grain stamped
  'VENDOR_A',                                                   -- source_vendor stamped
  1,                                                            -- data_version (first load)
  'Y',                                                          -- is_current
  SYSDATE,                                                      -- delivery_date
  :b_lineage_id,                                                -- lineage bind

  -- MAP-E-010: assurance_level — rule=lookup:UDM.udm_ref_assurance.assurance_label
  (SELECT assurance_label
   FROM   UDM.udm_ref_assurance
   WHERE  id = src.ASSURANCE_CD
   AND    ROWNUM = 1),

  -- MAP-E-009: carbon_intensity_revenue — rule=divide:revenue_musd
  -- Engine resolved canonical_name 'revenue_musd' → source_attribute REVENUE_MUSD
  CASE WHEN NVL(src.REVENUE_MUSD, 0) = 0
       THEN NULL
       ELSE src.SC1_TONNE / src.REVENUE_MUSD
  END,

  -- MAP-E-008: revenue_musd — rule=direct
  src.REVENUE_MUSD,

  -- MAP-E-003: scope1_mtco2 — rule=direct, is_mandatory=Y
  src.SC1_TONNE,

  -- MAP-E-007: scope1_source_flag — rule=flag:scope1_mtco2,scope3_upstream_mtco2
  -- Engine resolved 'scope1_mtco2' → SC1_TONNE (the primary column to test)
  CASE WHEN src.SC1_TONNE IS NOT NULL THEN 'DIRECT' ELSE 'ESTIMATED' END,

  -- MAP-E-004: scope2_mtco2 — rule=direct
  src.SC2_TONNE,

  -- MAP-E-005: scope3_mtco2 — rule=coalesce:scope3_upstream_mtco2
  -- Engine resolved 'scope3_upstream_mtco2' → SC3_UPSTREAM (the fallback column)
  COALESCE(src.SC3_TONNE, src.SC3_UPSTREAM),

  -- MAP-E-006: scope3_upstream_mtco2 — rule=direct
  src.SC3_UPSTREAM

FROM rdm.V_EMISSIONS_VA src

-- Entity resolution: JOIN replaces per-row PL/SQL xref lookup
JOIN udm_entity_xref xref
  ON  xref.vendor_id    = 'VENDOR_A'          -- vendor_id from source_registry
  AND xref.external_id  = src.COMPANY_CD       -- entity_id_col from source_registry
  AND xref.effective_to IS NULL                -- current xref mapping only

-- Currency filter: p_build_currency_filter() → CURRENT_FLAG mechanism
WHERE src.IS_CURRENT = 'Y';                    -- current_flag_column from source_registry

-- ROWS LOADED: 2  (ABC-0001 and DEF-0002 — both have IS_CURRENT='Y' and xref entries)
-- ZZZ-9999 excluded by JOIN — handled by quarantine INSERT below
-- ABC-0001 2023: excluded by WHERE IS_CURRENT='Y'
--
-- Note for DEF-0002: SC3_TONNE is NULL → COALESCE fires → scope3_mtco2 = 312000.00
-- Note for DEF-0002: carbon_intensity_revenue = 88200 / 14200 = 6.2113...


-- ============================================================================
-- SECTION 4 — ENGINE-GENERATED SQL: EAV PATH (SRC-E-002, VENDOR_B)
--
-- The engine calls p_build_eav_insert_sql(p_src, p_attrs, l_currency, 2)
-- data_version=2 because VENDOR_A was loaded first in the same domain run.
--
-- HOW THE EAV PATH DIFFERS FROM COLUMNAR:
--   - No per-attribute source_attribute columns in SELECT.
--   - Each metric becomes MAX(CASE WHEN ATTR_CODE = 'X' THEN TO_NUMBER(ATTR_VAL) END)
--   - GROUP BY xref.entity_key to collapse multiple EAV rows → one stack row
--   - The entity JOIN is on ENTITY_REF (entity_id_col), same join structure
--   - currency filter: ROW_EFF_TO IS NULL  (EFFECTIVE_DATES mechanism)
--
-- ATTRIBUTE_VALUE_DATA_TYPE drives the cast inside the CASE expression:
--   NUMBER  → TO_NUMBER(src.ATTR_VAL)
--   DATE    → TO_DATE(src.ATTR_VAL, 'YYYY-MM-DD')
--   VARCHAR → src.ATTR_VAL  (no cast)
-- ============================================================================

-- Step A: flip prior VENDOR_B rows to NOT current
UPDATE udm.udm_emissions_stk
SET    is_current   = 'N'
WHERE  source_vendor = 'VENDOR_B'
AND    is_current    = 'Y';


-- Step B: EAV INSERT...SELECT with pivot  ← THIS IS WHAT p_build_eav_insert_sql PRODUCES
INSERT /*+ APPEND */ INTO udm.udm_emissions_stk (
  entity_key,
  coverage_period,
  measurement_grain,
  source_vendor,
  data_version,
  is_current,
  delivery_date,
  lineage_id,
  -- metric columns in canonical_name alpha order
  assurance_level,
  revenue_musd,
  scope1_mtco2,
  scope2_mtco2,
  scope3_mtco2
)
SELECT
  xref.entity_key,
  TO_CHAR(MAX(src.REPORT_PERIOD)),              -- period from data (MAX = one value per group)
  'COMPANY-FISCAL_YEAR',
  'VENDOR_B',
  2,                                            -- data_version: VENDOR_B loaded second
  'Y',
  SYSDATE,
  :b_lineage_id,

  -- MAP-E-015: assurance_level — ATTR_CODE='ASSUR_LVL', data_type=VARCHAR (no cast)
  MAX(CASE WHEN src.ATTR_CODE = 'ASSUR_LVL'  THEN src.ATTR_VAL               END),

  -- MAP-E-014: revenue_musd — ATTR_CODE='REVENUE_M', data_type=NUMBER
  MAX(CASE WHEN src.ATTR_CODE = 'REVENUE_M'  THEN TO_NUMBER(src.ATTR_VAL)    END),

  -- MAP-E-011: scope1_mtco2 — ATTR_CODE='SC1_GROSS', data_type=NUMBER
  MAX(CASE WHEN src.ATTR_CODE = 'SC1_GROSS'  THEN TO_NUMBER(src.ATTR_VAL)    END),

  -- MAP-E-012: scope2_mtco2 — ATTR_CODE='SC2_MKT', data_type=NUMBER
  MAX(CASE WHEN src.ATTR_CODE = 'SC2_MKT'   THEN TO_NUMBER(src.ATTR_VAL)    END),

  -- MAP-E-013: scope3_mtco2 — ATTR_CODE='SC3_TOT', data_type=NUMBER
  -- DEF-VA-002 row: ATTR_VAL=NULL → TO_NUMBER(NULL) = NULL → pivot returns NULL
  MAX(CASE WHEN src.ATTR_CODE = 'SC3_TOT'   THEN TO_NUMBER(src.ATTR_VAL)    END)

FROM rdm.EAV_EMISSIONS_VB src

JOIN udm_entity_xref xref
  ON  xref.vendor_id    = 'VENDOR_B'
  AND xref.external_id  = src.ENTITY_REF          -- entity_id_col
  AND xref.effective_to IS NULL

-- Currency filter: EFFECTIVE_DATES mechanism → effective_to_column IS NULL
WHERE src.ROW_EFF_TO IS NULL

-- GROUP BY collapses all EAV rows for one entity into a single wide stack row
GROUP BY xref.entity_key;

-- ROWS LOADED: 3  (ABC-VA-001, DEF-VA-002, GHI-VB-003)
-- ABC-0001 2023 row excluded: ROW_EFF_TO IS NOT NULL
-- DEF-VA-002: scope3_mtco2 = NULL (ATTR_VAL was NULL in source)
-- GHI-VB-003: loaded — VENDOR_A does not cover this company; stk has its row


-- ============================================================================
-- SECTION 5 — ENGINE-GENERATED SQL: QUARANTINE PATH
-- Rows that failed entity resolution (no xref match).
-- INSERT...SELECT WHERE NOT EXISTS — same set-based approach.
-- ============================================================================

-- 5A. VENDOR_A quarantine (ZZZ-9999 has no entry in udm_entity_xref)
INSERT INTO udm_quarantine (
  quarantine_id, lineage_id, source_id, domain_id, vendor_id,
  coverage_period, entity_id_raw, attribute_name,
  raw_value, check_type, rejection_reason,
  quarantined_at, resolved_flag
)
SELECT
  'QUA-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' || LPAD(udm_quarantine_seq.NEXTVAL, 8, '0'),
  :b_lineage_id,
  'SRC-E-001',
  'EMISSIONS',
  'VENDOR_A',
  TO_CHAR(src.FISCAL_YR),
  src.COMPANY_CD,                -- entity_id_raw: the vendor identifier that failed
  'entity_key',
  NULL,
  'ENTITY_NOT_FOUND',
  'No xref: vendor=VENDOR_A',
  SYSDATE,
  'N'
FROM rdm.V_EMISSIONS_VA src
WHERE src.IS_CURRENT = 'Y'                        -- same currency filter as main INSERT
AND NOT EXISTS (
  SELECT 1
  FROM   udm_entity_xref
  WHERE  vendor_id    = 'VENDOR_A'
  AND    external_id  = src.COMPANY_CD
  AND    effective_to IS NULL
);
-- ROWS QUARANTINED: 1  (ZZZ-9999)

-- 5B. VENDOR_B quarantine — none in this example (all ENTITY_REF values have xref entries)
-- The NOT EXISTS subquery returns 0 rows → 0 quarantine rows inserted.


-- ============================================================================
-- SECTION 6 — EXPECTED STACK OUTPUT AFTER BOTH LOADS
--
-- udm.udm_emissions_stk after VENDOR_A load (data_version=1) then VENDOR_B (data_version=2).
-- Both sets have is_current='Y' — they are different source_vendor rows, not competing.
-- Arbitration (Module 7) picks the winner per metric from these rows.
-- ============================================================================

/*
ENTITY_KEY    COVERAGE_  MEASUREMENT_GRAIN    SOURCE_  DATA_  IS_  SCOPE1_   SCOPE2_   SCOPE3_     SCOPE3_      SCOPE1_       CARBON_INT_  REVENUE_  ASSURANCE_
              PERIOD     (domain_grain)       VENDOR   VER    CUR  MTCO2     MTCO2     MTCO2       UPSTREAM_    SOURCE_FLAG   REVENUE      MUSD      LEVEL
------------  ---------  -------------------  -------  -----  ---  --------  --------  ----------  -----------  ------------  -----------  --------  ----------
ENT-000441    2024       COMPANY-FISCAL_YEAR  VENDOR_A 1      Y    12500.00  8300.00   45200.00    NULL         DIRECT        4.3860       2850.00   Limited Assurance
ENT-000441    2024       COMPANY-FISCAL_YEAR  VENDOR_B 2      Y    12650.00  8100.00   44800.00    NULL         [no flag col] NULL         2850.00   Limited

ENT-000442    2024       COMPANY-FISCAL_YEAR  VENDOR_A 1      Y    88200.00  31400.00  312000.00*  312000.00    DIRECT        6.2113       14200.00  Reasonable Assurance
ENT-000442    2024       COMPANY-FISCAL_YEAR  VENDOR_B 2      Y    89100.00  30800.00  NULL        NULL         [no flag col] NULL         14200.00  Reasonable

ENT-000891    2024       COMPANY-FISCAL_YEAR  VENDOR_B 2      Y    3200.00   1100.00   8900.00     NULL         [no flag col] NULL         620.00    NULL

* DEF-0002 scope3_mtco2: COALESCE fired — SC3_TONNE was NULL, value comes from SC3_UPSTREAM=312000.

Notes:
  ENT-000441 = ABC-0001 (VENDOR_A xref) = ABC-VA-001 (VENDOR_B xref) — same entity, two rows
  ENT-000442 = DEF-0002 (VENDOR_A xref) = DEF-VA-002 (VENDOR_B xref) — same entity, two rows
  ENT-000891 = GHI-VB-003 (VENDOR_B only) — one row, no VENDOR_A coverage
  ZZZ-9999   = in udm_quarantine, resolved_flag='N', check_type=ENTITY_NOT_FOUND

Arbitration input: two rows per entity (where both vendors cover it).
Module 7 (udm_pkg_arbitration.run_domain) reads udm_precedence_rules,
picks winner per metric, writes one row to udm_emissions_arb per entity.
*/
