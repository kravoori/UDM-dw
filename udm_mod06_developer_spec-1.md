# Module 6 — Harmonisation Engine
## Developer Specification

**Document status:** For development  
**Module:** 6 of 11  
**Package:** `UDM.UDM_PKG_HARMONISATION`  

---

## 1. Purpose and Scope

This specification covers everything a developer needs to build, test, and deploy the harmonisation engine. No other document is required.

The harmonisation engine is the first processing stage in the UDM pipeline. Its job is to read current data from a registered source, resolve entity identifiers, apply attribute-level transforms, and write clean rows to the domain stack table. It does not arbitrate between vendors — that is Module 7.

One `run_source` call processes one source end-to-end. One `run_domain` call processes all sources for a domain in the correct order.

**What this module writes:**

| Target | Written by |
|---|---|
| `udm_{domain}_stk` | DATA_SOURCE path |
| `udm_entity_registry` | IDENTITY_SOURCE path (REGISTRY_AND_XREF only) |
| `udm_entity_xref` | IDENTITY_SOURCE path |
| `udm_entity_membership` | COMPANY_SECTOR pre-pass |
| `udm_ref_*` | REFERENCE_SOURCE path |
| `udm_quarantine` | All paths — failed entity resolution rows |
| `udm_lineage` | All paths — via `udm_pkg_lineage` (Module 9) |

**What this module does NOT do:**

- Arbitrate between vendors (Module 7)
- Run DI threshold checks (Module 8)
- Detect schema changes (Modules 3–5)
- Write to distribution layer (consumer responsibility)

---

## 2. Prerequisites

Before the engine can run, the following must be in place. The engine will raise a specific error for each missing dependency — it does not fail silently.

| Prerequisite | Where | Error if missing |
|---|---|---|
| Tier 1 DDL deployed | All `udm_*` tables exist | Compile error |
| Module 9 (Lineage Recorder) compiled | `udm_pkg_lineage` package exists | Compile error |
| Source registered | `udm_source_registry` | ORA-20200 |
| Attribute map populated | `udm_attribute_map` | ORA-20204 |
| Manifest COMPLETE | `udm_delivery_manifest` | ORA-20202 |
| No PENDING_RETIREMENT columns | `udm_attribute_map` | ORA-20201 |
| Entity xref seeded | `udm_entity_xref` | Rows go to quarantine |

---

## 3. Package Structure

```
UDM_PKG_HARMONISATION
│
├─ PUBLIC
│   ├─ run_source(p_source_id)          ← main entry point
│   ├─ run_domain(p_domain_id)          ← domain-level orchestration
│   └─ flush_cs_cache                   ← clears session COMPANY_SECTOR cache
│
├─ PRIVATE — METADATA LAYER (6A)
│   ├─ p_load_source_rec
│   ├─ p_load_attr_map
│   ├─ p_check_pending_retirement
│   ├─ p_find_pending_manifest
│   └─ p_build_currency_filter
│
├─ PRIVATE — SQL BUILDER LAYER (6B)
│   ├─ p_parse_lookup_rule
│   ├─ p_collect_lookup_joins
│   ├─ p_build_transform_expr
│   ├─ p_build_entity_join
│   ├─ p_entity_key_expr
│   ├─ p_build_columnar_insert_sql
│   ├─ p_build_eav_insert_sql
│   └─ p_build_entity_quarantine_sql
│
├─ PRIVATE — COMPANY_SECTOR PRE-PASS (6C)
│   └─ p_bulk_create_cs_entities
│
└─ PRIVATE — SOURCE ROLE PROCESSORS (6D)
    ├─ p_process_data_source
    ├─ p_process_identity_source
    └─ p_process_reference_source
```

Developer B is responsible for the **SQL Builder Layer (6B)**. This document covers all four layers because the developer needs to understand the full context to build 6B correctly.

---

## 4. Catalog Tables — Read Contract

The engine reads these tables at runtime. Do not hardcode any value that lives in these tables.

### 4.1 `udm_source_registry`

One row per registered source. Engine reads once at start of `run_source`.

| Column | Type | Used for |
|---|---|---|
| `source_id` | VARCHAR2(20) | Lookup key |
| `vendor_id` | VARCHAR2(50) | Stamped on stack rows as `source_vendor`; used in xref joins |
| `domain_id` | VARCHAR2(50) | Determines target stack table: `udm_{domain}_stk` |
| `source_schema` | VARCHAR2(30) | Source table schema in FROM clause |
| `source_table` | VARCHAR2(128) | Source table name in FROM clause |
| `source_format` | VARCHAR2(20) | `COLUMNAR` or `EAV` — determines SQL builder path |
| `currency_mechanism` | VARCHAR2(20) | Determines WHERE clause — see Section 7.1 |
| `current_flag_column` | VARCHAR2(128) | Used when `currency_mechanism = CURRENT_FLAG` |
| `effective_to_column` | VARCHAR2(128) | Used when `currency_mechanism = EFFECTIVE_DATES` |
| `time_key_column` | VARCHAR2(128) | Used when `currency_mechanism = MAX_SNAPSHOT_DATE` |
| `entity_id_col` | VARCHAR2(128) | Column holding vendor entity identifier |
| `time_col` | VARCHAR2(128) | Column holding coverage period value — stamped on stack row |
| `source_role` | VARCHAR2(20) | `DATA_SOURCE` / `IDENTITY_SOURCE` / `REFERENCE_SOURCE` |
| `subject_type` | VARCHAR2(20) | `ENTITY` / `SPATIAL` / `INTERNAL_ID` |
| `domain_grain` | VARCHAR2(100) | Stamped as `measurement_grain` on stack rows |
| `governance_status` | VARCHAR2(20) | Engine only processes `UDM_CATALOGED` and `MIGRATING` |

**Key constraint:** `governance_status` must be `UDM_CATALOGED` or `MIGRATING`. Any other value — `RDM_ONLY`, `STAGE_ONLY`, `DEPRECATED`, `RETIRED` — causes the engine to raise ORA-20203 and stop.

---

### 4.2 `udm_attribute_map`

One row per attribute per source. Engine BULK COLLECTs all ACTIVE rows for the source at start of processing.

| Column | Type | Used for |
|---|---|---|
| `source_attribute` | VARCHAR2(128) | Physical column name (COLUMNAR) or value column name (EAV) |
| `canonical_name` | VARCHAR2(128) | Target column name in `udm_{domain}_stk` |
| `transform_rule` | VARCHAR2(200) | Determines SQL expression emitted — see Section 8 |
| `data_type` | VARCHAR2(20) | Cast type for EAV attributes; validation for DI |
| `is_subject_key` | CHAR(1) | `Y` = this is the entity identifier column — excluded from metric SELECT |
| `is_time_key` | CHAR(1) | `Y` = this is the coverage period column — excluded from metric SELECT |
| `is_mandatory` | CHAR(1) | `Y` = NULL value causes row quarantine |
| `attribute_name_column` | VARCHAR2(128) | **EAV only.** Column holding attribute code (e.g. `ATTR_CODE`) |
| `attribute_name_value` | VARCHAR2(200) | **EAV only.** Attribute code to match (e.g. `SC1_GROSS`) |
| `attribute_value_column` | VARCHAR2(128) | **EAV only.** Column holding value (e.g. `ATTR_VAL`) |
| `attribute_value_data_type` | VARCHAR2(20) | **EAV only.** Cast type: `NUMBER`, `DATE`, or `VARCHAR` |
| `map_status` | VARCHAR2(20) | Only `ACTIVE` rows are loaded. `PENDING_RETIREMENT` blocks the source entirely |
| `effective_to` | DATE | Engine only reads rows where `effective_to IS NULL OR effective_to > SYSDATE` |

**BULK COLLECT order:** `is_subject_key DESC, is_time_key DESC, canonical_name ASC`. Subject key and time key come first — this is important because transform rules like `divide:` and `coalesce:` reference other canonical names by index position when building SQL.

---

### 4.3 `udm_transform_rules`

Referenced by `rule_ref:RULE_NAME` transform pattern only. Engine queries once per `rule_ref:` attribute encountered during SQL build.

| Column | Used for |
|---|---|
| `rule_name` | Matched against the `RULE_NAME` part of `rule_ref:RULE_NAME` |
| `resolution_sql` | SQL expression substituted inline into the SELECT clause. May contain `{vendor_value}` placeholder (replaced with `src.source_attribute`) and `{vendor_id}` placeholder (replaced with literal vendor_id string) |
| `is_active` | Only `Y` rows are used |
| `effective_to` | Only current rows (`IS NULL OR > SYSDATE`) |

---

### 4.4 `udm_delivery_manifest`

Engine looks up the latest COMPLETE manifest not yet linked to a successful LOAD lineage row. This is the currency gate — the engine will not process a source if no new complete delivery exists.

| Column | Used for |
|---|---|
| `manifest_id` | Written to `udm_lineage.manifest_id` for traceability |
| `source_id` | Filter |
| `status` | Must be `COMPLETE` |
| `coverage_period` | Informational — written to `udm_lineage.coverage_period`. NOT used as a filter on the source data |
| `completed_at` | Used in NOT EXISTS subquery to detect already-processed manifests |

**Critical:** `coverage_period` from the manifest is informational only. The engine filters source rows using `currency_mechanism` — not by matching a period column value. The period stamped on stack rows comes from reading the source's `time_col` value.

---

### 4.5 `udm_entity_xref`

Queried as a JOIN in the main INSERT…SELECT for `ENTITY` subject_type sources.

| Column | Used for |
|---|---|
| `vendor_id` | Matched against `source_registry.vendor_id` |
| `external_id` | Matched against `src.{entity_id_col}` |
| `entity_key` | Selected as the canonical entity identifier for the stack row |
| `effective_to` | Must be NULL (current mapping only) |

---

### 4.6 `udm_identity_source_map`

Queried for `IDENTITY_SOURCE` sources only.

| Column | Used for |
|---|---|
| `external_id_col` | Column in source holding vendor identifier |
| `canonical_name_col` | Column in source holding entity display name (nullable) |
| `entity_type` | Written to `udm_entity_registry.entity_type` for new entities |
| `resolution_target` | `REGISTRY_AND_XREF` = create entity + xref; `XREF_ONLY` = xref only (entity must pre-exist) |

---

### 4.7 `udm_ref_source_map`

Queried for `REFERENCE_SOURCE` sources only.

| Column | Used for |
|---|---|
| `ref_table_name` | Target `udm_ref_*` table name |
| `refresh_strategy` | `FULL_REPLACE`, `INCREMENTAL`, or `EFFECTIVE_DATE_MERGE` |
| `ref_natural_key_cols` | Column list for MERGE ON clause |

---

## 5. Output Tables — Write Contract

### 5.1 `udm_{domain}_stk`

One row per vendor × entity × delivery. The `domain_id` from `udm_source_registry` determines the table name: `udm_` + `LOWER(REPLACE(domain_id, '-', '_'))` + `_stk`.

**Standard header columns** (present on every stack table):

| Column | Value written by engine |
|---|---|
| `entity_key` | Resolved from xref JOIN (ENTITY), spatial registry JOIN (SPATIAL), or raw `entity_id_col` value (INTERNAL_ID) |
| `coverage_period` | `TO_CHAR(src.{time_col})` — read from source data |
| `measurement_grain` | `source_registry.domain_grain` literal |
| `source_vendor` | `source_registry.vendor_id` literal |
| `data_version` | `MAX(data_version) + 1` from existing stack rows for this vendor |
| `is_current` | `'Y'` for the new load. Prior rows for this vendor set to `'N'` by UPDATE before INSERT |
| `delivery_date` | `SYSDATE` |
| `lineage_id` | Bind variable — the lineage_id opened for this batch |

**Metric columns:** One column per `udm_attribute_map` row where `is_subject_key = 'N'` AND `is_time_key = 'N'`. Column name = `canonical_name`.

---

### 5.2 `udm_quarantine`

Rows that could not be entity-resolved. Written by a second INSERT…SELECT with NOT EXISTS on the xref join. Never lost silently — every source row either lands in the stack or lands in quarantine.

| Column | Value written |
|---|---|
| `quarantine_id` | `'QUA-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' || LPAD(udm_quarantine_seq.NEXTVAL, 8, '0')` |
| `lineage_id` | Same lineage_id as the main INSERT |
| `source_id` | From source_registry |
| `domain_id` | From source_registry |
| `vendor_id` | From source_registry |
| `coverage_period` | `TO_CHAR(src.{time_col})` |
| `entity_id_raw` | `src.{entity_id_col}` — the identifier that failed resolution |
| `attribute_name` | `'entity_key'` |
| `check_type` | `'ENTITY_NOT_FOUND'` |
| `rejection_reason` | `'No xref: vendor={vendor_id}'` |
| `resolved_flag` | `'N'` |

---

### 5.3 `udm_lineage`

Written via `udm_pkg_lineage.open_batch` at start and `close_batch` at end. Developer B does not write to this table directly — call the lineage package procedures.

---

## 6. Processing Flow

```
run_source(p_source_id)
       │
       ├─ 1. p_load_source_rec          → load source_registry row
       │
       ├─ 2. governance_status check    → raise ORA-20203 if not UDM_CATALOGED/MIGRATING
       │
       ├─ 3. p_check_pending_retirement → raise ORA-20201 if any PENDING_RETIREMENT attrs
       │
       ├─ 4. p_find_pending_manifest    → find latest COMPLETE manifest, not yet processed
       │                                  raise ORA-20202 if none found
       │
       ├─ 5. p_load_attr_map            → BULK COLLECT attribute map into PL/SQL table
       │                                  raise ORA-20204 if no ACTIVE rows found
       │
       ├─ 6. udm_pkg_lineage.open_batch → open LOAD lineage row; get lineage_id
       │
       ├─ 7. Route on source_role:
       │
       │      DATA_SOURCE ──────────────► p_process_data_source
       │                                      │
       │                                      ├─ IF COMPANY_SECTOR grain:
       │                                      │    p_bulk_create_cs_entities (pre-pass)
       │                                      │
       │                                      ├─ UPDATE stk: prior rows → is_current='N'
       │                                      │
       │                                      ├─ Build INSERT SQL:
       │                                      │    COLUMNAR → p_build_columnar_insert_sql
       │                                      │    EAV      → p_build_eav_insert_sql
       │                                      │
       │                                      ├─ EXECUTE IMMEDIATE insert SQL
       │                                      │
       │                                      └─ EXECUTE IMMEDIATE quarantine SQL
       │                                           (NOT EXISTS — unresolved entities)
       │
       │      IDENTITY_SOURCE ──────────► p_process_identity_source
       │                                      │
       │                                      ├─ BULK COLLECT new external_ids
       │                                      │    (NOT EXISTS in xref)
       │                                      │
       │                                      ├─ IF REGISTRY_AND_XREF:
       │                                      │    bulk generate sequences
       │                                      │    FORALL INSERT entity_registry
       │                                      │    FORALL INSERT entity_xref
       │                                      │
       │                                      └─ IF XREF_ONLY:
       │                                           INSERT...SELECT quarantine
       │
       │      REFERENCE_SOURCE ──────────► p_process_reference_source
       │                                      │
       │                                      ├─ FULL_REPLACE: TRUNCATE + INSERT SELECT
       │                                      ├─ INCREMENTAL: MERGE
       │                                      └─ EFFECTIVE_DATE_MERGE: UPDATE + INSERT
       │
       └─ 8. flush_cs_cache             → clear COMPANY_SECTOR session cache
              udm_pkg_lineage.close_batch → write final row counts + status
```

---

## 7. Private Procedures — Metadata Layer (6A)

These are provided as reference. Developer B's work depends on outputs from these procedures.

### 7.1 `p_build_currency_filter(p_src IN t_src_rec) RETURN VARCHAR2`

Returns a SQL WHERE predicate string. This is the **only** filter applied to the source table. No period filter is added.

| `currency_mechanism` | WHERE predicate returned |
|---|---|
| `CURRENT_FLAG` | `src.{current_flag_column} = 'Y'` |
| `EFFECTIVE_DATES` | `src.{effective_to_column} IS NULL` |
| `MAX_SNAPSHOT_DATE` | `src.{time_key_column} = (SELECT MAX({time_key_column}) FROM {schema}.{table})` |
| `LOAD_DATE` | `src.load_date = (SELECT MAX(load_date) FROM {schema}.{table})` |
| `ALWAYS_CURRENT` | `1=1` |

The returned string is embedded directly in the FROM clause of both the main INSERT and the quarantine INSERT. Both must use the same filter string — the quarantine catches exactly the rows the main INSERT excluded due to the JOIN, not a different set.

---

## 8. Private Procedures — SQL Builder Layer (6B)

This is the primary responsibility of Developer B. Each function returns a SQL string fragment. No DML is executed here — these are pure string builders.

### 8.1 `p_parse_lookup_rule`

**Signature:**
```plsql
PROCEDURE p_parse_lookup_rule (
  p_rule        IN  VARCHAR2,   -- everything after 'lookup:'
  p_schema      OUT VARCHAR2,
  p_table       OUT VARCHAR2,
  p_join_col    OUT VARCHAR2,
  p_return_col  OUT VARCHAR2
);
```

**Purpose:** Parses the `transform_rule` string for `lookup:` attributes into its four components.

**Input format variants:**

| Segments | Example input | Schema | Table | Join col | Return col |
|---|---|---|---|---|---|
| 4 (preferred) | `UDM.udm_ref_assurance.assurance_code.assurance_label` | `UDM` | `udm_ref_assurance` | `assurance_code` | `assurance_label` |
| 3 (backward compat) | `UDM.udm_ref_assurance.assurance_label` | `UDM` | `udm_ref_assurance` | `id` | `assurance_label` |
| 2 (minimal) | `udm_ref_assurance.assurance_label` | `UDM` | `udm_ref_assurance` | `id` | `assurance_label` |

**Error:** If fewer than 2 segments, raise ORA-20220 with the malformed rule string.

**Implementation note:** Split on `.` using `REGEXP_SUBSTR` with `BULK COLLECT` into a local collection. Do not use `INSTR` loops — they break on schema names containing dots (unlikely but possible).

---

### 8.2 `p_collect_lookup_joins`

**Signature:**
```plsql
PROCEDURE p_collect_lookup_joins (
  p_attrs        IN  t_attr_tab,
  p_join_sql     OUT VARCHAR2,
  p_alias_map    OUT SYS.ODCIVarchar2List  -- parallel to p_attrs: alias.col or NULL
);
```

**Purpose:** First pass over the attribute map. Finds all `lookup:` transform rules, deduplicates by target table, assigns join aliases, builds the `LEFT JOIN` SQL fragment.

**Algorithm:**
1. Initialise `p_alias_map` with `p_attrs.COUNT` NULL slots.
2. Maintain a `t_dedup` associative array keyed by `UPPER(schema) || '.' || UPPER(table)`.
3. For each attribute in `p_attrs`:
   - If `transform_rule LIKE 'lookup:%'`: call `p_parse_lookup_rule` to get schema, table, join_col, return_col.
   - Check dedup map. If table already seen → reuse existing alias. If new → increment alias counter, assign `lkp_{n}`, build LEFT JOIN clause, add to dedup map.
   - Write `alias.return_col` into `p_alias_map(i)`.
   - Non-`lookup:` attributes → `p_alias_map(i) := NULL`.
4. `p_join_sql` is the concatenation of all LEFT JOIN clauses.

**Output format for `p_join_sql`:**
```sql
LEFT JOIN UDM.udm_ref_assurance lkp_1
  ON lkp_1.assurance_code = src.ASSURANCE_CD
LEFT JOIN UDM.udm_ref_sector lkp_2
  ON lkp_2.sector_code = src.SECTOR_CD
```

**Why LEFT JOIN, not INNER JOIN:** An INNER JOIN on a lookup table drops the entire source row silently when the reference value has no match. A LEFT JOIN returns NULL for the unmatched column. The DI COMPLETENESS check then flags it in `udm_dq_results` and the data owner investigates. Silent row loss is a worse outcome than a NULL in a non-mandatory column.

**Deduplication:** If two attributes both reference `UDM.udm_ref_sector`, only one LEFT JOIN is emitted. Both `p_alias_map` slots get the same alias but different return columns: `lkp_2.sector_name` and `lkp_2.sector_code`.

---

### 8.3 `p_build_transform_expr`

**Signature:**
```plsql
FUNCTION p_build_transform_expr (
  p_rule      IN VARCHAR2,    -- transform_rule value from attribute_map
  p_src_col   IN VARCHAR2,    -- source_attribute (physical column name)
  p_attrs     IN t_attr_tab,  -- full attribute map (for cross-column rules)
  p_vendor_id IN VARCHAR2     -- for rule_ref: placeholder substitution
) RETURN VARCHAR2;
```

**Purpose:** Returns a SQL expression string for one attribute. The expression references the source table alias `src`. No DML, no database calls except for `rule_ref:` rules.

**`lookup:` case is NOT handled here.** If called with a `lookup:` rule, emit the scalar subquery fallback and log a WARNING to `DBMS_OUTPUT`. Under normal operation this code path is never reached — `p_collect_lookup_joins` handles lookup: attributes in pass 1.

**Transform rule logic:**

#### `direct`
```sql
src.{source_attribute}
```

#### `multiply:N`
```sql
src.{source_attribute} * {N}
```
Where `N` is the numeric constant after the colon.

#### `divide:canonical_name`
```plsql
-- Find source_attribute for the given canonical_name in p_attrs
-- Use inner function find_src_attr(p_canon) → loops p_attrs, returns source_attribute
```
```sql
CASE WHEN NVL(src.{divisor_source_col}, 0) = 0
     THEN NULL
     ELSE src.{source_attribute} / src.{divisor_source_col}
END
```
If `canonical_name` not found in p_attrs → fallback to `src.{source_attribute}` and log WARNING.

#### `coalesce:canonical_name_1,canonical_name_2,...`
The primary column is `p_src_col`. The `p_param` after the colon is a comma-separated list of **fallback** canonical names. Find each one's `source_attribute` using `find_src_attr`.
```sql
COALESCE(src.{primary_col}, src.{fallback_col_1}, src.{fallback_col_2})
```
Skip any canonical_name in the list that is not found in p_attrs — do not raise an error, log WARNING.

#### `flag:primary_canonical,fallback_canonical`
Only the **first** canonical_name matters — it is the one tested for NOT NULL.
```sql
CASE WHEN src.{primary_source_col} IS NOT NULL
     THEN 'DIRECT'
     ELSE 'ESTIMATED'
END
```
If primary canonical_name not found → return `'''DIRECT'''` (literal string, always DIRECT).

#### `lookup:...` (fallback only)
```sql
(SELECT {return_col} FROM {schema}.{table}
 WHERE {join_col} = src.{source_attribute} AND ROWNUM = 1)
```
Log: `WARN: p_build_transform_expr called for lookup: rule — use p_collect_lookup_joins + two-pass build instead.`

#### `rule_ref:RULE_NAME`
1. Query `udm_transform_rules` for the named rule (`is_active = 'Y'`, `effective_to IS NULL OR effective_to > SYSDATE`).
2. Replace `{vendor_value}` with `src.{source_attribute}`.
3. Replace `{vendor_id}` with `'{vendor_id_literal}'`.
4. Wrap: `({modified_resolution_sql})`.
5. If no rule found → fallback to `src.{source_attribute}`, log WARNING.

#### Unknown rule
```sql
src.{source_attribute}
```
Log WARNING with rule name. Do not raise — a broken transform must not abort the entire load.

**Error handling:** All errors inside this function are caught, logged to `DBMS_OUTPUT`, and the function returns `src.{source_attribute}` as a safe fallback. A broken transform expression must not cause the SQL build to fail — the engine will write the raw value, and the DI checks will catch any anomalies.

---

### 8.4 `p_build_entity_join`

**Signature:**
```plsql
FUNCTION p_build_entity_join(p_src IN t_src_rec) RETURN VARCHAR2;
```

Returns the JOIN clause(s) for entity resolution. Returns `NULL` for `INTERNAL_ID` (no join needed).

| `subject_type` | JOIN returned |
|---|---|
| `ENTITY` | `JOIN udm_entity_xref xref ON xref.vendor_id = '{vendor_id}' AND xref.external_id = src.{entity_id_col} AND xref.effective_to IS NULL` |
| `SPATIAL` | `JOIN udm_spatial_asset_registry sar ON sar.source_id = '{source_id}' AND sar.vendor_asset_id = src.{entity_id_col} AND sar.effective_to IS NULL` |
| `INTERNAL_ID` | `NULL` |

---

### 8.5 `p_entity_key_expr`

**Signature:**
```plsql
FUNCTION p_entity_key_expr(p_src IN t_src_rec) RETURN VARCHAR2;
```

Returns the SELECT expression for the `entity_key` column. Must align with the JOIN returned by `p_build_entity_join`.

| `subject_type` | Expression returned |
|---|---|
| `ENTITY` | `xref.entity_key` |
| `SPATIAL` | `sar.spatial_asset_key` |
| `INTERNAL_ID` | `src.{entity_id_col}` |

---

### 8.6 `p_build_columnar_insert_sql`

**Signature:**
```plsql
FUNCTION p_build_columnar_insert_sql (
  p_src             IN t_src_rec,
  p_attrs           IN t_attr_tab,
  p_currency_filter IN VARCHAR2,
  p_data_version    IN NUMBER
) RETURN VARCHAR2;
```

**Purpose:** Builds the complete `INSERT /*+ APPEND */` statement for a COLUMNAR source. This is a two-pass build.

**Pass 1 — collect lookup joins:**
Call `p_collect_lookup_joins(p_attrs, l_join_sql, l_alias_map)`. This produces the LEFT JOIN clauses and the alias map.

**Pass 2 — build SELECT list:**

Standard header (always present, in this order):
```
entity_key        ← p_entity_key_expr(p_src)
coverage_period   ← TO_CHAR(src.{time_col})
measurement_grain ← '{domain_grain}' literal
source_vendor     ← '{vendor_id}' literal
data_version      ← {p_data_version} numeric literal
is_current        ← 'Y' literal
delivery_date     ← SYSDATE
lineage_id        ← :b_lineage_id bind variable
```

Metric columns — iterate `p_attrs` in order, skipping `is_subject_key = 'Y'` and `is_time_key = 'Y'`:
- If `l_alias_map(i) IS NOT NULL` → emit `l_alias_map(i)` (e.g. `lkp_1.assurance_label`)
- Else → call `p_build_transform_expr(p_attrs(i).transform_rule, p_attrs(i).source_attribute, p_attrs, p_src.vendor_id)`

**Assembled SQL structure:**
```sql
INSERT /*+ APPEND */ INTO udm.udm_{domain}_stk (
  entity_key, coverage_period, measurement_grain, source_vendor,
  data_version, is_current, delivery_date, lineage_id,
  {canonical_name_1}, {canonical_name_2}, ...
)
SELECT
  {entity_key_expr},
  TO_CHAR(src.{time_col}),
  '{domain_grain}',
  '{vendor_id}',
  {data_version},
  'Y',
  SYSDATE,
  :b_lineage_id,
  {transform_expr_1},
  {transform_expr_2}, ...
FROM {source_schema}.{source_table} src
{entity_join_clause}
{lookup_join_clauses}
WHERE {currency_filter}
```

**Stack table name derivation:** `'udm.' || 'udm_' || LOWER(REPLACE(p_src.domain_id, '-', '_')) || '_stk'`

---

### 8.7 `p_build_eav_insert_sql`

**Signature:**
```plsql
FUNCTION p_build_eav_insert_sql (
  p_src             IN t_src_rec,
  p_attrs           IN t_attr_tab,
  p_currency_filter IN VARCHAR2,
  p_data_version    IN NUMBER
) RETURN VARCHAR2;
```

**Purpose:** Builds the INSERT for an EAV source. The key difference from COLUMNAR: every metric column becomes a `MAX(CASE WHEN attr_code = '…' THEN cast(attr_val) END)` expression, and the query has a `GROUP BY entity_key`.

**EAV pivot expression per attribute:**

The cast applied depends on `attribute_value_data_type`:

| `attribute_value_data_type` | Cast in CASE expression |
|---|---|
| `NUMBER` | `TO_NUMBER(src.{attribute_value_column})` |
| `DATE` | `TO_DATE(src.{attribute_value_column}, 'YYYY-MM-DD')` |
| `VARCHAR` | `src.{attribute_value_column}` (no cast) |

Full pivot expression:
```sql
MAX(CASE WHEN src.{attribute_name_column} = '{attribute_name_value}'
         THEN {cast_expression}
    END)
```

For `lookup:` attributes in EAV: the cast is replaced by the join alias column:
```sql
MAX(CASE WHEN src.{attribute_name_column} = '{attribute_name_value}'
         THEN {lkp_n.return_col}
    END)
```

**Coverage period in EAV:** `TO_CHAR(MAX(src.{time_col}))` — uses MAX because multiple EAV rows for the same entity are collapsed by GROUP BY. The MAX is safe because all rows for the same entity share the same period value.

**GROUP BY:** `{p_entity_key_expr}` — the same expression as in the SELECT.

**Assembled SQL structure:**
```sql
INSERT /*+ APPEND */ INTO udm.udm_{domain}_stk (
  entity_key, coverage_period, measurement_grain, source_vendor,
  data_version, is_current, delivery_date, lineage_id,
  {canonical_name_1}, {canonical_name_2}, ...
)
SELECT
  {entity_key_expr},
  TO_CHAR(MAX(src.{time_col})),
  '{domain_grain}',
  '{vendor_id}',
  {data_version},
  'Y',
  SYSDATE,
  :b_lineage_id,
  MAX(CASE WHEN src.{attr_name_col} = '{attr_name_val_1}' THEN {cast_1} END),
  MAX(CASE WHEN src.{attr_name_col} = '{attr_name_val_2}' THEN {cast_2} END), ...
FROM {source_schema}.{source_table} src
{entity_join_clause}
{lookup_join_clauses}
WHERE {currency_filter}
GROUP BY {entity_key_expr}
```

---

### 8.8 `p_build_entity_quarantine_sql`

**Signature:**
```plsql
FUNCTION p_build_entity_quarantine_sql (
  p_src             IN t_src_rec,
  p_currency_filter IN VARCHAR2
) RETURN VARCHAR2;
```

**Purpose:** Builds the INSERT into `udm_quarantine` for source rows that could not be entity-resolved. Returns `NULL` for `INTERNAL_ID` and `SPATIAL` subject types — quarantine only applies to `ENTITY`.

**Algorithm:** Same source table, same currency filter as the main INSERT. The WHERE clause adds `AND NOT EXISTS (SELECT 1 FROM udm_entity_xref WHERE vendor_id = '{vendor_id}' AND external_id = src.{entity_id_col} AND effective_to IS NULL)`.

This NOT EXISTS is the exact inverse of the INNER JOIN in the main INSERT. Between the two statements, every source row is accounted for: either it matches the JOIN and lands in the stack, or it fails the JOIN and lands in quarantine.

**Assembled SQL structure:**
```sql
INSERT INTO udm_quarantine (
  quarantine_id, lineage_id, source_id, domain_id, vendor_id,
  coverage_period, entity_id_raw, attribute_name,
  raw_value, check_type, rejection_reason,
  quarantined_at, resolved_flag
)
SELECT
  'QUA-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-'
       || LPAD(udm_quarantine_seq.NEXTVAL, 8, '0'),
  :b_lineage_id,
  '{source_id}',
  '{domain_id}',
  '{vendor_id}',
  TO_CHAR(src.{time_col}),
  src.{entity_id_col},
  'entity_key',
  NULL,
  'ENTITY_NOT_FOUND',
  'No xref: vendor={vendor_id}',
  SYSDATE,
  'N'
FROM {source_schema}.{source_table} src
WHERE {currency_filter}
AND NOT EXISTS (
  SELECT 1 FROM udm_entity_xref
  WHERE  vendor_id    = '{vendor_id}'
  AND    external_id  = src.{entity_id_col}
  AND    effective_to IS NULL
)
```

---

## 9. COMPANY_SECTOR Pre-Pass (6C)

Relevant to Developer B because `p_build_columnar_insert_sql` and `p_build_eav_insert_sql` are called after this pre-pass runs. By the time the main INSERT executes, all COMPANY_SECTOR entities exist in `udm_entity_xref` and the MV is refreshed. The entity JOIN in the main INSERT will find them.

Developer B does not implement `p_bulk_create_cs_entities` — that is 6C. Developer B only needs to know:
- The pre-pass runs when `domain_grain LIKE '%COMPANY_SECTOR%'` AND `subject_type = 'ENTITY'`.
- After it runs, the xref has all new CS entities. The main INSERT SQL does not need to handle the CS creation case.
- The pre-pass COMMITs (triggers MV refresh) before the main INSERT executes.

---

## 10. Performance Requirements

| Requirement | Constraint |
|---|---|
| Generated SQL string length | Must not exceed 30KB (Oracle `VARCHAR2` max in dynamic SQL is 32KB) |
| `lookup:` transforms | Must be LEFT JOINs in FROM clause. Scalar subqueries in SELECT are not acceptable above 1,000 source rows |
| Source row iteration | No PL/SQL `FETCH` loop over source rows. All row processing must be set-based inside the INSERT…SELECT |
| Sequence generation | Pre-generate all sequences in one `SELECT … CONNECT BY ROWNUM <=` call per batch. No per-row sequence fetch |
| Main INSERT hint | Always `INSERT /*+ APPEND */` — direct-path insert, bypasses buffer cache for bulk loads |

**SQL string length guard:** After building the SQL string, check `LENGTH(l_sql)`. If > 30,000 characters, log a WARNING with the source_id and attribute count. This is a signal that the domain should be decomposed into subdomains (see architecture note on 250+ attribute EAV sources).

---

## 11. Error Handling Rules

| Situation | Behaviour |
|---|---|
| `p_build_transform_expr` fails for one attribute | Catch, log WARNING, return `src.{source_attribute}` as fallback. Never abort SQL build. |
| `rule_ref:` rule not found in `udm_transform_rules` | Fallback to `direct`, log WARNING |
| `lookup:` canonical in `divide:` or `coalesce:` not found in attr map | Fallback per rule (see Section 8.3), log WARNING |
| Main INSERT fails | ROLLBACK, call `udm_pkg_lineage.close_batch(status='FAILED')`, re-RAISE |
| Quarantine INSERT fails | Log WARNING only — do not abort. Row counts will show discrepancy |
| `p_load_source_rec` not found | Raise ORA-20200 |
| PENDING_RETIREMENT detected | Raise ORA-20201 |
| No COMPLETE manifest | Raise ORA-20202 |
| governance_status invalid | Raise ORA-20203 |
| No ACTIVE attribute map rows | Raise ORA-20204 |

**COMMIT discipline:** One COMMIT after the main INSERT and quarantine INSERT complete. Never commit mid-batch. The lineage package uses `AUTONOMOUS_TRANSACTION` for its own commits.

---

## 12. Type Definitions

These types must be declared in the package spec or body before use.

```plsql
-- Source registry row
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

-- Attribute map collection
TYPE t_attr_rec IS RECORD (
  map_id                    udm_attribute_map.map_id%TYPE,
  source_attribute          udm_attribute_map.source_attribute%TYPE,
  canonical_name            udm_attribute_map.canonical_name%TYPE,
  transform_rule            udm_attribute_map.transform_rule%TYPE,
  data_type                 udm_attribute_map.data_type%TYPE,
  is_subject_key            udm_attribute_map.is_subject_key%TYPE,
  is_time_key               udm_attribute_map.is_time_key%TYPE,
  is_mandatory              udm_attribute_map.is_mandatory%TYPE,
  attribute_name_column     udm_attribute_map.attribute_name_column%TYPE,
  attribute_name_value      udm_attribute_map.attribute_name_value%TYPE,
  attribute_value_column    udm_attribute_map.attribute_value_column%TYPE,
  attribute_value_data_type udm_attribute_map.attribute_value_data_type%TYPE
);
TYPE t_attr_tab IS TABLE OF t_attr_rec INDEX BY PLS_INTEGER;

-- Session-level COMPANY_SECTOR key cache
TYPE t_cs_cache IS TABLE OF VARCHAR2(20) INDEX BY VARCHAR2(41);
g_cs_cache t_cs_cache;   -- declared in package spec
```

---

## 13. Sample Dataset and Expected SQL Output

This section defines the exact catalog rows and source data used in all tests. Copy these directly — do not reference any external file.

### 13.1 Sample Catalog Rows

#### Source Registry

**SRC-E-001 — VENDOR_A, COLUMNAR**

| Column | Value |
|---|---|
| source_id | `SRC-E-001` |
| vendor_id | `VENDOR_A` |
| domain_id | `EMISSIONS` |
| source_schema | `RDM` |
| source_table | `V_EMISSIONS_VA` |
| source_format | `COLUMNAR` |
| currency_mechanism | `CURRENT_FLAG` |
| current_flag_column | `IS_CURRENT` |
| entity_id_col | `COMPANY_CD` |
| time_col | `FISCAL_YR` |
| source_role | `DATA_SOURCE` |
| subject_type | `ENTITY` |
| domain_grain | `COMPANY-FISCAL_YEAR` |
| governance_status | `UDM_CATALOGED` |

**SRC-E-002 — VENDOR_B, EAV**

| Column | Value |
|---|---|
| source_id | `SRC-E-002` |
| vendor_id | `VENDOR_B` |
| domain_id | `EMISSIONS` |
| source_schema | `RDM` |
| source_table | `EAV_EMISSIONS_VB` |
| source_format | `EAV` |
| currency_mechanism | `EFFECTIVE_DATES` |
| effective_to_column | `ROW_EFF_TO` |
| entity_id_col | `ENTITY_REF` |
| time_col | `REPORT_PERIOD` |
| source_role | `DATA_SOURCE` |
| subject_type | `ENTITY` |
| domain_grain | `COMPANY-FISCAL_YEAR` |
| governance_status | `UDM_CATALOGED` |

---

#### Attribute Map — SRC-E-001 (COLUMNAR)

Loaded by `p_load_attr_map` in order: `is_subject_key DESC, is_time_key DESC, canonical_name ASC`.

| # | map_id | source_attribute | canonical_name | transform_rule | data_type | is_subject_key | is_time_key | is_mandatory |
|---|---|---|---|---|---|---|---|---|
| 1 | MAP-E-001 | COMPANY_CD | company_external_id | direct | VARCHAR | Y | N | Y |
| 2 | MAP-E-002 | FISCAL_YR | coverage_period_src | direct | VARCHAR | N | Y | Y |
| 3 | MAP-E-010 | ASSURANCE_CD | assurance_level | `lookup:UDM.udm_ref_assurance.assurance_code.assurance_label` | VARCHAR | N | N | N |
| 4 | MAP-E-009 | SC1_TONNE | carbon_intensity_revenue | `divide:revenue_musd` | NUMBER | N | N | N |
| 5 | MAP-E-008 | REVENUE_MUSD | revenue_musd | direct | NUMBER | N | N | N |
| 6 | MAP-E-003 | SC1_TONNE | scope1_mtco2 | direct | NUMBER | N | N | Y |
| 7 | MAP-E-007 | SC1_TONNE | scope1_source_flag | `flag:scope1_mtco2,scope3_upstream_mtco2` | VARCHAR | N | N | N |
| 8 | MAP-E-004 | SC2_TONNE | scope2_mtco2 | direct | NUMBER | N | N | N |
| 9 | MAP-E-005 | SC3_TONNE | scope3_mtco2 | `coalesce:scope3_upstream_mtco2` | NUMBER | N | N | N |
| 10 | MAP-E-006 | SC3_UPSTREAM | scope3_upstream_mtco2 | direct | NUMBER | N | N | N |

> Note: rows 1–2 are subject/time keys and are excluded from the metric SELECT list. Rows 3–10 become metric columns.

---

#### Attribute Map — SRC-E-002 (EAV)

All rows have `attribute_name_column = 'ATTR_CODE'`, `attribute_value_column = 'ATTR_VAL'`.

| # | map_id | canonical_name | attribute_name_value | attribute_value_data_type | is_mandatory |
|---|---|---|---|---|---|
| 1 | MAP-E-015 | assurance_level | `ASSUR_LVL` | VARCHAR | N |
| 2 | MAP-E-014 | revenue_musd | `REVENUE_M` | NUMBER | N |
| 3 | MAP-E-011 | scope1_mtco2 | `SC1_GROSS` | NUMBER | Y |
| 4 | MAP-E-012 | scope2_mtco2 | `SC2_MKT` | NUMBER | N |
| 5 | MAP-E-013 | scope3_mtco2 | `SC3_TOT` | NUMBER | N |

---

#### Entity Xref — VENDOR_A

| vendor_id | external_id | entity_key | effective_to |
|---|---|---|---|
| VENDOR_A | ABC-0001 | ENT-000441 | NULL |
| VENDOR_A | DEF-0002 | ENT-000442 | NULL |
| — | ZZZ-9999 | — | — (no row — triggers quarantine) |

#### Entity Xref — VENDOR_B

| vendor_id | external_id | entity_key | effective_to |
|---|---|---|---|
| VENDOR_B | ABC-VA-001 | ENT-000441 | NULL |
| VENDOR_B | DEF-VA-002 | ENT-000442 | NULL |
| VENDOR_B | GHI-VB-003 | ENT-000891 | NULL |

---

#### Source Data — RDM.V_EMISSIONS_VA (VENDOR_A)

Only rows with `IS_CURRENT = 'Y'` are processed.

| COMPANY_CD | FISCAL_YR | SC1_TONNE | SC2_TONNE | SC3_TONNE | SC3_UPSTREAM | REVENUE_MUSD | ASSURANCE_CD | IS_CURRENT |
|---|---|---|---|---|---|---|---|---|
| ABC-0001 | 2024 | 12500.00 | 8300.00 | 45200.00 | NULL | 2850.00 | LTD | Y |
| DEF-0002 | 2024 | 88200.00 | 31400.00 | NULL | 312000.00 | 14200.00 | REAS | Y |
| ZZZ-9999 | 2024 | 5100.00 | 2200.00 | 9800.00 | NULL | 980.00 | NONE | Y |
| ABC-0001 | 2023 | 11900.00 | 8100.00 | 43100.00 | NULL | 2710.00 | LTD | N |

> DEF-0002: SC3_TONNE is NULL — coalesce rule fires, scope3_mtco2 gets SC3_UPSTREAM value.
> ZZZ-9999: No xref entry — goes to quarantine.
> ABC-0001 2023: IS_CURRENT = 'N' — excluded by currency filter.

#### Source Data — RDM.EAV_EMISSIONS_VB (VENDOR_B)

Only rows with `ROW_EFF_TO IS NULL` are processed.

| ENTITY_REF | REPORT_PERIOD | ATTR_CODE | ATTR_VAL | ROW_EFF_TO |
|---|---|---|---|---|
| ABC-VA-001 | 2024 | SC1_GROSS | 12650.00 | NULL |
| ABC-VA-001 | 2024 | SC2_MKT | 8100.00 | NULL |
| ABC-VA-001 | 2024 | SC3_TOT | 44800.00 | NULL |
| ABC-VA-001 | 2024 | REVENUE_M | 2850.00 | NULL |
| ABC-VA-001 | 2024 | ASSUR_LVL | Limited | NULL |
| DEF-VA-002 | 2024 | SC1_GROSS | 89100.00 | NULL |
| DEF-VA-002 | 2024 | SC2_MKT | 30800.00 | NULL |
| DEF-VA-002 | 2024 | SC3_TOT | NULL | NULL |
| DEF-VA-002 | 2024 | REVENUE_M | 14200.00 | NULL |
| DEF-VA-002 | 2024 | ASSUR_LVL | Reasonable | NULL |
| GHI-VB-003 | 2024 | SC1_GROSS | 3200.00 | NULL |
| GHI-VB-003 | 2024 | SC2_MKT | 1100.00 | NULL |
| GHI-VB-003 | 2024 | SC3_TOT | 8900.00 | NULL |
| GHI-VB-003 | 2024 | REVENUE_M | 620.00 | NULL |
| ABC-VA-001 | 2023 | SC1_GROSS | 11800.00 | 2024-01-15 |

> DEF-VA-002 SC3_TOT: ATTR_VAL is NULL — TO_NUMBER(NULL) = NULL — scope3_mtco2 will be NULL in stack.
> ABC-VA-001 2023 row: ROW_EFF_TO IS NOT NULL — excluded by currency filter.

---

### 13.2 Expected SQL Output — COLUMNAR Path (SRC-E-001)

This is the exact string that `p_build_columnar_insert_sql` must produce for SRC-E-001 with `data_version=1`. The developer verifies by printing the returned string and comparing character by character (normalise consecutive whitespace before comparing).

**Prior-row UPDATE** (built and executed by 6D, not 6B — shown here for context):
```sql
UPDATE udm.udm_emissions_stk
SET    is_current   = 'N'
WHERE  source_vendor = 'VENDOR_A'
AND    is_current    = 'Y'
```

**Main INSERT** — what `p_build_columnar_insert_sql` returns:
```sql
INSERT /*+ APPEND */ INTO udm.udm_emissions_stk (
  entity_key,
  coverage_period,
  measurement_grain,
  source_vendor,
  data_version,
  is_current,
  delivery_date,
  lineage_id,
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
  xref.entity_key,
  TO_CHAR(src.FISCAL_YR),
  'COMPANY-FISCAL_YEAR',
  'VENDOR_A',
  1,
  'Y',
  SYSDATE,
  :b_lineage_id,
  lkp_1.assurance_label,
  CASE WHEN NVL(src.REVENUE_MUSD, 0) = 0
       THEN NULL
       ELSE src.SC1_TONNE / src.REVENUE_MUSD
  END,
  src.REVENUE_MUSD,
  src.SC1_TONNE,
  CASE WHEN src.SC1_TONNE IS NOT NULL THEN 'DIRECT' ELSE 'ESTIMATED' END,
  src.SC2_TONNE,
  COALESCE(src.SC3_TONNE, src.SC3_UPSTREAM),
  src.SC3_UPSTREAM
FROM RDM.V_EMISSIONS_VA src
JOIN udm_entity_xref xref
  ON  xref.vendor_id   = 'VENDOR_A'
  AND xref.external_id = src.COMPANY_CD
  AND xref.effective_to IS NULL
LEFT JOIN UDM.udm_ref_assurance lkp_1
  ON lkp_1.assurance_code = src.ASSURANCE_CD
WHERE src.IS_CURRENT = 'Y'
```

**What this produces from the sample data:**

| entity_key | coverage_period | scope1_mtco2 | scope3_mtco2 | carbon_intensity_revenue | assurance_level |
|---|---|---|---|---|---|
| ENT-000441 | 2024 | 12500.00 | 45200.00 | 4.3860 | Limited Assurance |
| ENT-000442 | 2024 | 88200.00 | 312000.00 *(coalesce)* | 6.2113 | Reasonable Assurance |

ZZZ-9999: excluded by the xref JOIN → goes to quarantine INSERT below.

---

### 13.3 Expected SQL Output — Quarantine Path (SRC-E-001)

What `p_build_entity_quarantine_sql` returns for SRC-E-001:

```sql
INSERT INTO udm_quarantine (
  quarantine_id,
  lineage_id,
  source_id,
  domain_id,
  vendor_id,
  coverage_period,
  entity_id_raw,
  attribute_name,
  raw_value,
  check_type,
  rejection_reason,
  quarantined_at,
  resolved_flag
)
SELECT
  'QUA-' || TO_CHAR(SYSDATE, 'YYYYMMDD') || '-'
       || LPAD(udm_quarantine_seq.NEXTVAL, 8, '0'),
  :b_lineage_id,
  'SRC-E-001',
  'EMISSIONS',
  'VENDOR_A',
  TO_CHAR(src.FISCAL_YR),
  src.COMPANY_CD,
  'entity_key',
  NULL,
  'ENTITY_NOT_FOUND',
  'No xref: vendor=VENDOR_A',
  SYSDATE,
  'N'
FROM RDM.V_EMISSIONS_VA src
WHERE src.IS_CURRENT = 'Y'
AND NOT EXISTS (
  SELECT 1
  FROM   udm_entity_xref
  WHERE  vendor_id    = 'VENDOR_A'
  AND    external_id  = src.COMPANY_CD
  AND    effective_to IS NULL
)
```

**What this produces from the sample data:**

| entity_id_raw | check_type | rejection_reason |
|---|---|---|
| ZZZ-9999 | ENTITY_NOT_FOUND | No xref: vendor=VENDOR_A |

ABC-0001 and DEF-0002 were matched by the main INSERT JOIN so they are excluded here by the NOT EXISTS. The two statements are complementary — every IS_CURRENT='Y' row lands in exactly one of them.

---

### 13.4 Expected SQL Output — EAV Path (SRC-E-002)

What `p_build_eav_insert_sql` returns for SRC-E-002 with `data_version=2`:

```sql
INSERT /*+ APPEND */ INTO udm.udm_emissions_stk (
  entity_key,
  coverage_period,
  measurement_grain,
  source_vendor,
  data_version,
  is_current,
  delivery_date,
  lineage_id,
  assurance_level,
  revenue_musd,
  scope1_mtco2,
  scope2_mtco2,
  scope3_mtco2
)
SELECT
  xref.entity_key,
  TO_CHAR(MAX(src.REPORT_PERIOD)),
  'COMPANY-FISCAL_YEAR',
  'VENDOR_B',
  2,
  'Y',
  SYSDATE,
  :b_lineage_id,
  MAX(CASE WHEN src.ATTR_CODE = 'ASSUR_LVL' THEN src.ATTR_VAL END),
  MAX(CASE WHEN src.ATTR_CODE = 'REVENUE_M' THEN TO_NUMBER(src.ATTR_VAL) END),
  MAX(CASE WHEN src.ATTR_CODE = 'SC1_GROSS' THEN TO_NUMBER(src.ATTR_VAL) END),
  MAX(CASE WHEN src.ATTR_CODE = 'SC2_MKT'   THEN TO_NUMBER(src.ATTR_VAL) END),
  MAX(CASE WHEN src.ATTR_CODE = 'SC3_TOT'   THEN TO_NUMBER(src.ATTR_VAL) END)
FROM RDM.EAV_EMISSIONS_VB src
JOIN udm_entity_xref xref
  ON  xref.vendor_id   = 'VENDOR_B'
  AND xref.external_id = src.ENTITY_REF
  AND xref.effective_to IS NULL
WHERE src.ROW_EFF_TO IS NULL
GROUP BY xref.entity_key
```

**What this produces from the sample data:**

| entity_key | coverage_period | scope1_mtco2 | scope2_mtco2 | scope3_mtco2 | revenue_musd | assurance_level |
|---|---|---|---|---|---|---|
| ENT-000441 | 2024 | 12650.00 | 8100.00 | 44800.00 | 2850.00 | Limited |
| ENT-000442 | 2024 | 89100.00 | 30800.00 | NULL *(ATTR_VAL was NULL)* | 14200.00 | Reasonable |
| ENT-000891 | 2024 | 3200.00 | 1100.00 | 8900.00 | 620.00 | NULL |

> `data_version = 2` because VENDOR_A (data_version=1) loaded first in `run_domain`.
> DEF-VA-002 scope3_mtco2 is NULL: the source row had ATTR_VAL = NULL, so TO_NUMBER(NULL) = NULL, and MAX(NULL) = NULL.
> No quarantine rows for VENDOR_B — all three ENTITY_REF values have xref entries.

---

### 13.5 Expected Stack Output — Both Loads Combined

After `run_domain('EMISSIONS')` runs both sources, `udm_emissions_stk` contains:

| entity_key | source_vendor | data_version | is_current | scope1_mtco2 | scope3_mtco2 | carbon_intensity_revenue |
|---|---|---|---|---|---|---|
| ENT-000441 | VENDOR_A | 1 | Y | 12500.00 | 45200.00 | 4.3860 |
| ENT-000442 | VENDOR_A | 1 | Y | 88200.00 | 312000.00 | 6.2113 |
| ENT-000441 | VENDOR_B | 2 | Y | 12650.00 | 44800.00 | NULL |
| ENT-000442 | VENDOR_B | 2 | Y | 89100.00 | NULL | NULL |
| ENT-000891 | VENDOR_B | 2 | Y | 3200.00 | 8900.00 | NULL |

Two rows per entity where both vendors cover it. Module 7 (Arbitration) reads these rows and writes one winner per entity to `udm_emissions_arb`. `carbon_intensity_revenue` is NULL for VENDOR_B because that transform rule is not registered in SRC-E-002's attribute map — VENDOR_B does not supply revenue data in the same source.

---

## 14. Unit Tests

These tests do not execute DML. Each test calls the builder function, captures the returned string with `DBMS_OUTPUT.PUT_LINE`, and compares against the expected output in Section 13.

**Test 6B-01 — `p_build_currency_filter`: CURRENT_FLAG**
```
Setup:   p_src.currency_mechanism = 'CURRENT_FLAG'
         p_src.current_flag_column = 'IS_CURRENT'
Call:    p_build_currency_filter(p_src)
Expect:  src.IS_CURRENT = 'Y'
```

**Test 6B-02 — `p_build_currency_filter`: EFFECTIVE_DATES**
```
Setup:   p_src.currency_mechanism = 'EFFECTIVE_DATES'
         p_src.effective_to_column = 'ROW_EFF_TO'
Call:    p_build_currency_filter(p_src)
Expect:  src.ROW_EFF_TO IS NULL
```

**Test 6B-03 — `p_build_currency_filter`: MAX_SNAPSHOT_DATE**
```
Setup:   p_src.currency_mechanism  = 'MAX_SNAPSHOT_DATE'
         p_src.time_key_column     = 'SNAP_DT'
         p_src.source_schema       = 'RDM'
         p_src.source_table        = 'V_SNAP'
Call:    p_build_currency_filter(p_src)
Expect:  src.SNAP_DT = (SELECT MAX(SNAP_DT) FROM RDM.V_SNAP)
```

**Test 6B-04 — `p_build_transform_expr`: direct**
```
Call:    p_build_transform_expr('direct', 'SC1_TONNE', p_attrs, 'VENDOR_A')
Expect:  src.SC1_TONNE
```

**Test 6B-05 — `p_build_transform_expr`: multiply**
```
Call:    p_build_transform_expr('multiply:1000', 'SC1_KT', p_attrs, 'VENDOR_A')
Expect:  src.SC1_KT * 1000
```

**Test 6B-06 — `p_build_transform_expr`: divide — divisor found**
```
Setup:   p_attrs contains canonical_name='revenue_musd', source_attribute='REVENUE_MUSD'
Call:    p_build_transform_expr('divide:revenue_musd', 'SC1_TONNE', p_attrs, 'VENDOR_A')
Expect:  CASE WHEN NVL(src.REVENUE_MUSD, 0) = 0
              THEN NULL
              ELSE src.SC1_TONNE / src.REVENUE_MUSD
         END
```

**Test 6B-07 — `p_build_transform_expr`: divide — divisor NOT found**
```
Setup:   p_attrs does NOT contain canonical_name='nonexistent'
Call:    p_build_transform_expr('divide:nonexistent', 'SC1_TONNE', p_attrs, 'VENDOR_A')
Expect:  src.SC1_TONNE
         DBMS_OUTPUT contains 'WARN'
```

**Test 6B-08 — `p_build_transform_expr`: coalesce**
```
Setup:   p_attrs contains canonical_name='scope3_upstream_mtco2', source_attribute='SC3_UPSTREAM'
Call:    p_build_transform_expr('coalesce:scope3_upstream_mtco2', 'SC3_TONNE', p_attrs, 'VENDOR_A')
Expect:  COALESCE(src.SC3_TONNE, src.SC3_UPSTREAM)
```

**Test 6B-09 — `p_build_transform_expr`: coalesce — multiple fallbacks**
```
Setup:   p_attrs contains scope3_upstream_mtco2→SC3_UPSTREAM and scope3_estimated→SC3_EST
Call:    p_build_transform_expr('coalesce:scope3_upstream_mtco2,scope3_estimated', 'SC3_TONNE', p_attrs, 'VENDOR_A')
Expect:  COALESCE(src.SC3_TONNE, src.SC3_UPSTREAM, src.SC3_EST)
```

**Test 6B-10 — `p_build_transform_expr`: flag**
```
Setup:   p_attrs contains canonical_name='scope1_mtco2', source_attribute='SC1_TONNE'
Call:    p_build_transform_expr('flag:scope1_mtco2,scope3_upstream_mtco2', 'SC1_TONNE', p_attrs, 'VENDOR_A')
Expect:  CASE WHEN src.SC1_TONNE IS NOT NULL THEN 'DIRECT' ELSE 'ESTIMATED' END
```

**Test 6B-11 — `p_build_transform_expr`: flag — primary not found**
```
Setup:   p_attrs does NOT contain canonical_name='missing_col'
Call:    p_build_transform_expr('flag:missing_col,other_col', 'SC1_TONNE', p_attrs, 'VENDOR_A')
Expect:  'DIRECT'
         DBMS_OUTPUT contains 'WARN'
```

**Test 6B-12 — `p_build_transform_expr`: unknown rule**
```
Call:    p_build_transform_expr('explode:xyz', 'SC1_TONNE', p_attrs, 'VENDOR_A')
Expect:  src.SC1_TONNE
         DBMS_OUTPUT contains 'WARN'
```

**Test 6B-13 — `p_parse_lookup_rule`: 4-segment**
```
Call:    p_parse_lookup_rule(
           'UDM.udm_ref_assurance.assurance_code.assurance_label',
           l_schema, l_table, l_join_col, l_return_col)
Expect:  l_schema     = 'UDM'
         l_table      = 'udm_ref_assurance'
         l_join_col   = 'assurance_code'
         l_return_col = 'assurance_label'
```

**Test 6B-14 — `p_parse_lookup_rule`: 3-segment (join key defaults to id)**
```
Call:    p_parse_lookup_rule(
           'UDM.udm_ref_assurance.assurance_label',
           l_schema, l_table, l_join_col, l_return_col)
Expect:  l_schema     = 'UDM'
         l_table      = 'udm_ref_assurance'
         l_join_col   = 'id'
         l_return_col = 'assurance_label'
```

**Test 6B-15 — `p_parse_lookup_rule`: 2-segment (schema defaults to UDM)**
```
Call:    p_parse_lookup_rule(
           'udm_ref_assurance.assurance_label',
           l_schema, l_table, l_join_col, l_return_col)
Expect:  l_schema     = 'UDM'
         l_table      = 'udm_ref_assurance'
         l_join_col   = 'id'
         l_return_col = 'assurance_label'
```

**Test 6B-16 — `p_parse_lookup_rule`: malformed (1 segment)**
```
Call:    p_parse_lookup_rule('assurance_label', l_schema, l_table, l_join_col, l_return_col)
Expect:  ORA-20220 raised
```

**Test 6B-17 — `p_collect_lookup_joins`: single lookup attribute**
```
Setup:   p_attrs has one attribute with transform_rule =
           'lookup:UDM.udm_ref_assurance.assurance_code.assurance_label'
         source_attribute = 'ASSURANCE_CD'
Call:    p_collect_lookup_joins(p_attrs, l_join_sql, l_alias_map)
Expect:
  l_join_sql =
    LEFT JOIN UDM.udm_ref_assurance lkp_1
      ON lkp_1.assurance_code = src.ASSURANCE_CD
  l_alias_map(n) = 'lkp_1.assurance_label'   (where n = that attribute's index)
  All other l_alias_map slots = NULL
```

**Test 6B-18 — `p_collect_lookup_joins`: two attributes, same table (deduplication)**
```
Setup:   attr i: transform_rule = 'lookup:UDM.udm_ref_sector.sector_code.sector_name'
                 source_attribute = 'SECTOR_CD'
         attr j: transform_rule = 'lookup:UDM.udm_ref_sector.sector_code.sector_level'
                 source_attribute = 'SECTOR_CD'
Call:    p_collect_lookup_joins(p_attrs, l_join_sql, l_alias_map)
Expect:
  l_join_sql contains exactly ONE LEFT JOIN to udm_ref_sector
  l_alias_map(i) = 'lkp_1.sector_name'
  l_alias_map(j) = 'lkp_1.sector_level'
```

**Test 6B-19 — `p_collect_lookup_joins`: two attributes, different tables**
```
Setup:   attr i: 'lookup:UDM.udm_ref_assurance.assurance_code.assurance_label', src col ASSURANCE_CD
         attr j: 'lookup:UDM.udm_ref_sector.sector_code.sector_name', src col SECTOR_CD
Call:    p_collect_lookup_joins(p_attrs, l_join_sql, l_alias_map)
Expect:
  l_join_sql =
    LEFT JOIN UDM.udm_ref_assurance lkp_1
      ON lkp_1.assurance_code = src.ASSURANCE_CD
    LEFT JOIN UDM.udm_ref_sector lkp_2
      ON lkp_2.sector_code = src.SECTOR_CD
  l_alias_map(i) = 'lkp_1.assurance_label'
  l_alias_map(j) = 'lkp_2.sector_name'
```

**Test 6B-20 — `p_collect_lookup_joins`: no lookup attributes**
```
Setup:   p_attrs has only direct, multiply, divide rules
Call:    p_collect_lookup_joins(p_attrs, l_join_sql, l_alias_map)
Expect:  l_join_sql = '' (empty string)
         all l_alias_map slots = NULL
```

**Test 6B-21 — `p_build_entity_join`: ENTITY subject_type**
```
Setup:   p_src.subject_type = 'ENTITY'
         p_src.vendor_id    = 'VENDOR_A'
         p_src.entity_id_col = 'COMPANY_CD'
Call:    p_build_entity_join(p_src)
Expect:
  JOIN udm_entity_xref xref
    ON  xref.vendor_id   = 'VENDOR_A'
    AND xref.external_id = src.COMPANY_CD
    AND xref.effective_to IS NULL
```

**Test 6B-22 — `p_build_entity_join`: SPATIAL**
```
Setup:   p_src.subject_type = 'SPATIAL'
         p_src.source_id    = 'SRC-S-001'
         p_src.entity_id_col = 'ASSET_REF'
Call:    p_build_entity_join(p_src)
Expect:
  JOIN udm_spatial_asset_registry sar
    ON  sar.source_id       = 'SRC-S-001'
    AND sar.vendor_asset_id = src.ASSET_REF
    AND sar.effective_to IS NULL
```

**Test 6B-23 — `p_build_entity_join`: INTERNAL_ID**
```
Setup:   p_src.subject_type = 'INTERNAL_ID'
Call:    p_build_entity_join(p_src)
Expect:  NULL
```

**Test 6B-24 — `p_entity_key_expr`: all three subject types**
```
ENTITY:       p_entity_key_expr(p_src) → xref.entity_key
SPATIAL:      p_entity_key_expr(p_src) → sar.spatial_asset_key
INTERNAL_ID:  p_entity_key_expr(p_src) → src.{entity_id_col}
```

**Test 6B-25 — `p_build_columnar_insert_sql`: full output (SRC-E-001)**
```
Setup:   p_src  = SRC-E-001 values from Section 13.1
         p_attrs = attribute map from Section 13.1 (10 rows, order as shown)
         p_currency_filter = "src.IS_CURRENT = 'Y'"
         p_data_version = 1
Call:    p_build_columnar_insert_sql(p_src, p_attrs, p_currency_filter, 1)
Expect:  Exact SQL from Section 13.2
```

**Test 6B-26 — `p_build_eav_insert_sql`: full output (SRC-E-002)**
```
Setup:   p_src  = SRC-E-002 values from Section 13.1
         p_attrs = attribute map from Section 13.1 (5 EAV rows)
         p_currency_filter = 'src.ROW_EFF_TO IS NULL'
         p_data_version = 2
Call:    p_build_eav_insert_sql(p_src, p_attrs, p_currency_filter, 2)
Expect:  Exact SQL from Section 13.4
```

**Test 6B-27 — `p_build_entity_quarantine_sql`: ENTITY subject_type**
```
Setup:   p_src = SRC-E-001 (subject_type = 'ENTITY')
         p_currency_filter = "src.IS_CURRENT = 'Y'"
Call:    p_build_entity_quarantine_sql(p_src, p_currency_filter)
Expect:  Exact SQL from Section 13.3
```

**Test 6B-28 — `p_build_entity_quarantine_sql`: INTERNAL_ID returns NULL**
```
Setup:   p_src.subject_type = 'INTERNAL_ID'
Call:    p_build_entity_quarantine_sql(p_src, '1=1')
Expect:  NULL  (no quarantine for INTERNAL_ID — raw key passes through)
```

---

## 15. Integration Tests

These require the catalog seed data from Section 13.1 inserted into a DEV schema, and the test source tables (`RDM.V_EMISSIONS_VA`, `RDM.EAV_EMISSIONS_VB`) populated with data from Section 13.1.

**Test INT-01 — COLUMNAR source, happy path**
```
1. Seed all catalog rows (Section 13.1)
2. Populate RDM.V_EMISSIONS_VA with sample data (Section 13.1)
3. Insert udm_delivery_manifest row: source_id='SRC-E-001', status='COMPLETE'
4. Execute: udm_pkg_harmonisation.run_source('SRC-E-001')
5. Assert — stack:
   SELECT COUNT(*) FROM udm_emissions_stk
   WHERE source_vendor = 'VENDOR_A' AND is_current = 'Y'
   → 2 rows (ENT-000441, ENT-000442)
6. Assert — coalesce fired for DEF-0002:
   SELECT scope3_mtco2 FROM udm_emissions_stk
   WHERE entity_key = 'ENT-000442' AND source_vendor = 'VENDOR_A'
   → 312000.00
7. Assert — intensity calculated:
   SELECT ROUND(carbon_intensity_revenue, 4) FROM udm_emissions_stk
   WHERE entity_key = 'ENT-000442' AND source_vendor = 'VENDOR_A'
   → 6.2113
8. Assert — quarantine:
   SELECT entity_id_raw, check_type FROM udm_quarantine
   WHERE lineage_id = (last lineage_id)
   → 1 row: ZZZ-9999, ENTITY_NOT_FOUND
9. Assert — lineage:
   SELECT status, rows_written, rows_quarantined FROM udm_lineage
   WHERE source_id = 'SRC-E-001' AND lineage_type = 'LOAD'
   → status=COMPLETE, rows_written=2, rows_quarantined=1
```

**Test INT-02 — EAV source, GROUP BY collapse**
```
1. Seed catalog rows, populate RDM.EAV_EMISSIONS_VB (Section 13.1)
2. Insert manifest: source_id='SRC-E-002', status='COMPLETE'
3. Execute: udm_pkg_harmonisation.run_source('SRC-E-002')
4. Assert — 3 rows written:
   SELECT COUNT(*) FROM udm_emissions_stk
   WHERE source_vendor = 'VENDOR_B' AND is_current = 'Y'
   → 3
5. Assert — DEF-VA-002 scope3 is NULL:
   SELECT scope3_mtco2 FROM udm_emissions_stk
   WHERE entity_key = 'ENT-000442' AND source_vendor = 'VENDOR_B'
   → NULL
6. Assert — no quarantine rows:
   SELECT COUNT(*) FROM udm_quarantine WHERE source_id = 'SRC-E-002'
   → 0
7. Assert — data_version = 2 (VENDOR_A loaded first):
   SELECT data_version FROM udm_emissions_stk
   WHERE source_vendor = 'VENDOR_B' AND is_current = 'Y' AND ROWNUM = 1
   → 2
```

**Test INT-03 — Manifest gate blocks processing**
```
1. Seed catalog rows
2. Do NOT insert manifest (or insert with status='PARTIAL')
3. Execute: udm_pkg_harmonisation.run_source('SRC-E-001')
4. Assert — exception raised:
   → ORA-20202
5. Assert — no stack rows written:
   SELECT COUNT(*) FROM udm_emissions_stk WHERE source_vendor = 'VENDOR_A'
   → 0
6. Assert — lineage recorded as FAILED:
   SELECT status FROM udm_lineage WHERE source_id = 'SRC-E-001'
   → FAILED  (if lineage was opened before the manifest check — depends on gate order)
   OR no lineage row exists (if manifest check runs before open_batch)
```

**Test INT-04 — PENDING_RETIREMENT gate blocks processing**
```
1. Seed catalog rows, set one attribute to map_status='PENDING_RETIREMENT'
2. Insert manifest: status='COMPLETE'
3. Execute: udm_pkg_harmonisation.run_source('SRC-E-001')
4. Assert:
   → ORA-20201 raised
   SELECT COUNT(*) FROM udm_emissions_stk WHERE source_vendor = 'VENDOR_A' → 0
```

**Test INT-05 — Idempotent run (manifest already processed)**
```
1. Run INT-01 successfully
2. Execute: udm_pkg_harmonisation.run_source('SRC-E-001') again without inserting new manifest
3. Assert:
   → ORA-20202 raised  (no new COMPLETE unprocessed manifest)
   SELECT COUNT(*) FROM udm_emissions_stk WHERE source_vendor = 'VENDOR_A' AND is_current = 'Y'
   → still 2 (prior rows unchanged)
```

**Test INT-06 — run_domain processes in role order**
```
1. Register: IDENTITY_SOURCE (ISR-E-001), DATA_SOURCE (SRC-E-001), REFERENCE_SOURCE (RSR-E-001)
   all for domain_id = 'EMISSIONS'
2. Insert COMPLETE manifest for all three
3. Execute: udm_pkg_harmonisation.run_domain('EMISSIONS')
4. Assert — lineage timestamps:
   SELECT source_id, started_at FROM udm_lineage
   WHERE domain_id = 'EMISSIONS' AND lineage_type = 'LOAD'
   ORDER BY started_at
   → row 1: ISR-E-001 (IDENTITY_SOURCE)
   → row 2: RSR-E-001 (REFERENCE_SOURCE)
   → row 3: SRC-E-001 (DATA_SOURCE)
5. Assert — all three COMPLETE:
   SELECT COUNT(*) FROM udm_lineage
   WHERE domain_id = 'EMISSIONS' AND status = 'COMPLETE'
   → 3
```

---

## 16. Acceptance Criteria

- [ ] All unit tests 6B-01 through 6B-28 pass with exact string match on returned SQL
- [ ] All integration tests INT-01 through INT-06 pass
- [ ] No scalar subqueries in SELECT clause for `lookup:` attributes — inspect generated SQL in DBMS_OUTPUT
- [ ] Every source row with valid xref lands in stack; every row without lands in quarantine — no row silently absent from both
- [ ] `udm_lineage` has a COMPLETE or FAILED row for every `run_source` call
- [ ] Generated SQL is under 30,000 characters for a 20-attribute source
- [ ] DBMS_OUTPUT produces no WARN messages when catalog data is clean and complete
- [ ] Package compiles in Oracle 19c with zero errors and zero warnings

---

## 17. Build Order and Handover Notes

You are building the **SQL Builder Layer (6B)**: the eight functions listed in Section 3.

**Build in this order — each step depends on the previous:**

1. `p_parse_lookup_rule` — no dependencies, pure string parsing
2. `p_build_transform_expr` — uses `p_parse_lookup_rule` for the `lookup:` fallback guard only
3. `p_collect_lookup_joins` — uses `p_parse_lookup_rule`
4. `p_build_entity_join` and `p_entity_key_expr` — no dependencies, small
5. `p_build_columnar_insert_sql` — uses steps 2, 3, 4
6. `p_build_eav_insert_sql` — uses steps 2, 3, 4
7. `p_build_entity_quarantine_sql` — uses step 4 only; simplest

**Test as you go.** After each function, write a test harness that prints the return value to DBMS_OUTPUT and compare against the expected output in Sections 13.2–13.4 of this document. Do not wait until all functions are built before testing.

**Interfaces with other sub-tasks:**

| What you need | Provided by | When |
|---|---|---|
| `t_src_rec` and `t_attr_tab` type definitions | Sub-task 6A | Before you start. Use Section 12 of this spec if 6A is not ready. |
| Package compiles in same body as 6A procedures | Sub-task 6A | Agree file ownership before coding — one developer owns the package body file at any time |
| `EXECUTE IMMEDIATE` of strings you build | Sub-task 6D | You return strings only. 6D calls your functions and executes them. |
| `udm_pkg_lineage` calls | Sub-task 6D | You never call the lineage package directly. |

**Rules that cannot be broken:**

- Return strings only. No DML inside any function in 6B.
- `p_build_transform_expr` must never raise an unhandled exception. Catch everything, fall back to `src.{source_attribute}`, log to DBMS_OUTPUT.
- `lookup:` transforms must always produce a LEFT JOIN in the FROM clause via `p_collect_lookup_joins`. The scalar subquery fallback in `p_build_transform_expr` exists only as a safety net — it must never appear in normal operation.
- `INSERT /*+ APPEND */` must appear in every INSERT SQL string you build.
- The `p_alias_map` output from `p_collect_lookup_joins` is a parallel array: index `i` corresponds to `p_attrs(i)`. Do not shift indices.
