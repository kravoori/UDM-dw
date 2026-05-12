# Module 8 — Data Integrity Framework
## Developer Specification

**Document status:** For development  
**Module:** 8 of 11  
**Package:** `UDM.UDM_PKG_DI`  

---

## 1. Purpose and Scope

This specification covers everything a developer needs to build, test, and deploy the data integrity framework. No other document is required.

The DI framework evaluates data quality checks against the domain stack table after each harmonisation load. It writes check results to `udm_dq_results` for consumption by the external DQ tool. It does not alert, reject rows from the stack, or trigger workflow — it writes results only.

**What this module writes:**

| Target | Written by |
|---|---|
| `udm_dq_results` | All check types |
| `udm_lineage` | Via `udm_pkg_lineage` (Module 9) — one DI_CHECK row per run |

**What this module does NOT do:**

- Remove or modify rows in the stack table
- Alert or trigger workflow (external DQ tool responsibility)
- Run before harmonisation completes (Module 6 runs first)
- Check data in Federated or Standardized layers

---

## 2. The Core Performance Problem This Design Solves

The naive implementation of DQ checks runs one SQL statement per attribute per check type:

```
250 attributes × NOT_NULL check  = 250 SQL executions
250 attributes × DATA_TYPE check = 250 SQL executions
N rules × BOUNDS check           = N SQL executions
N rules × DRIFT check            = N × 2 SQL executions  (two AVG queries each)
N rules × COMPLETENESS check     = N SQL executions
```

This scales linearly with attribute count. At 250 attributes it is already slow. At 500 it becomes a batch timing risk. At multiple domains it compounds.

**This implementation runs one SQL statement per check type per batch run, regardless of how many attributes or rules are configured.** The number of database round trips is constant:

```
5 check types = 5 SQL executions per source per run
```

The mechanism: SQL builder functions iterate the attribute map and rules in PL/SQL (fast, in-memory), build one SQL string per check type using conditional aggregation and `UNPIVOT`, execute it once, `BULK COLLECT` the results, and `FORALL INSERT` into `udm_dq_results`.

---

## 3. Prerequisites

| Prerequisite | Error if missing |
|---|---|
| Module 9 (Lineage Recorder) compiled | Compile error |
| Tier 1 DDL deployed (`udm_dq_results`, `udm_dq_rules`, `udm_attribute_map`) | Compile error |
| Source registered in `udm_source_registry` | ORA-20300 |
| Stack table exists for domain | ORA-20301 (raised when SQL executes) |
| At least one COMPLETE LOAD lineage row exists for the source | ORA-20302 |

---

## 4. Package Structure

```
UDM_PKG_DI
│
├─ PUBLIC
│   ├─ run_checks(p_source_id, p_lineage_id)
│   └─ run_domain_checks(p_domain_id)
│
├─ PRIVATE — METADATA LAYER
│   ├─ p_load_tier_a_attrs       BULK COLLECT attribute map rows for Tier A checks
│   ├─ p_load_tier_b_rules       BULK COLLECT dq_rules for one check_type
│   └─ p_get_prior_period        Finds prior coverage_period for DRIFT check
│
├─ PRIVATE — SQL BUILDER LAYER   ← primary development target
│   ├─ p_build_not_null_sql      One SQL for all mandatory attributes
│   ├─ p_build_datatype_sql      One SQL for all typed VARCHAR attributes
│   ├─ p_build_bounds_sql        One SQL for all BOUNDS rules
│   ├─ p_build_drift_sql         One SQL for all DRIFT rules (two periods)
│   └─ p_build_completeness_sql  One SQL for all COMPLETENESS rules
│
└─ PRIVATE — EXECUTOR
    └─ p_execute_and_write       Runs built SQL, BULK COLLECTs, FORALL INSERTs
```

---

## 5. Catalog Tables — Read Contract

### 5.1 `udm_attribute_map`

Tier A checks derive from this table. No entry in `udm_dq_rules` needed.

| Column | Tier A usage |
|---|---|
| `canonical_name` | Column name to check in stack table; written as `metric_name` in `udm_dq_results` |
| `data_type` | `NOT_NULL`: filter `is_mandatory = 'Y'`. `DATA_TYPE`: filter `data_type = 'VARCHAR'` only |
| `is_mandatory` | `NOT_NULL` check: only rows where `is_mandatory = 'Y'` |
| `is_subject_key` | Exclude from all checks — entity key is never a metric |
| `is_time_key` | Exclude from all checks — time key is never a metric |
| `map_status` | Only `ACTIVE` rows |

### 5.2 `udm_dq_rules`

Tier B checks derive from this table. One row per metric per check type.

| Column | Used for |
|---|---|
| `rule_id` | Written to `udm_dq_results.rule_id` |
| `domain_id` | Filter — engine loads rules for the source's domain |
| `metric_name` | Column name in the stack table to check |
| `check_type` | `DRIFT`, `BOUNDS`, or `COMPLETENESS` |
| `threshold` | Used by DRIFT and COMPLETENESS — percentage |
| `min_value` | Used by BOUNDS only |
| `max_value` | Used by BOUNDS only |
| `action` | Written to `udm_dq_results.action_taken` on FAIL |
| `is_active` | Only `'Y'` rows loaded |
| `effective_to` | Only current rows (`IS NULL OR effective_to > SYSDATE`) |

### 5.3 `udm_source_registry`

Read at start of `run_checks` to get `vendor_id`, `domain_id`, `source_schema`, `source_table`.

### 5.4 `udm_lineage`

Queried in `p_get_prior_period` to find the coverage_period of the previous successful LOAD run for the same source. This determines which period the DRIFT check compares against.

---

## 6. Output Table — Write Contract

### `udm_dq_results`

One row per attribute per check type per run. Written via `FORALL INSERT` — one statement for all results from each check type.

| Column | Value |
|---|---|
| `result_id` | `'DQR-' \|\| TO_CHAR(SYSDATE,'YYYYMMDD') \|\| '-' \|\| LPAD(seq,8,'0')` |
| `lineage_id` | The DI_CHECK lineage_id opened by this run |
| `rule_id` | NULL for Tier A checks; rule_id from `udm_dq_rules` for Tier B |
| `check_type` | `NOT_NULL`, `DATA_TYPE`, `BOUNDS`, `DRIFT`, or `COMPLETENESS` |
| `check_source` | `AUTO_DERIVED` for Tier A; `CONFIGURED` for Tier B |
| `domain_id` | From source_registry |
| `source_id` | From source_registry |
| `metric_name` | `canonical_name` from attribute_map (Tier A) or `metric_name` from dq_rules (Tier B) |
| `movement_point` | Always `STAGE_TO_VS` (stack checks run after load to stack) |
| `check_result` | `PASS`, `FAIL`, or `WARNING` |
| `actual_value` | Numeric check result — null count, drift %, out-of-bounds count, completeness % |
| `expected_value` | Threshold or bound — NULL for NOT_NULL; threshold for others |
| `entity_key` | NULL — these are batch-level checks, not row-level |
| `coverage_period` | Coverage period being checked |
| `action_taken` | `NONE` on PASS; rule's `action` value on FAIL; `ALERT` on WARNING |
| `checked_at` | SYSDATE |

---

## 7. Processing Flow

```
run_checks(p_source_id, p_lineage_id)
  │
  ├─ Load source_registry row (domain_id, vendor_id, stk_table)
  ├─ Derive stk_table: 'udm.' || 'udm_' || LOWER(REPLACE(domain_id,'-','_')) || '_stk'
  ├─ Get coverage_period from parent LOAD lineage row (p_lineage_id)
  ├─ Open DI_CHECK lineage row via udm_pkg_lineage.open_batch
  │
  ├─ TIER A — AUTO_DERIVED checks
  │   ├─ p_load_tier_a_attrs(source_id, 'NOT_NULL')   → l_nn_attrs
  │   │   p_build_not_null_sql(l_nn_attrs, stk_table, vendor_id, coverage_period)
  │   │   p_execute_and_write(sql, 'NOT_NULL', 'AUTO_DERIVED', ...)
  │   │
  │   └─ p_load_tier_a_attrs(source_id, 'DATA_TYPE')  → l_dt_attrs
  │       p_build_datatype_sql(l_dt_attrs, stk_table, vendor_id, coverage_period)
  │       p_execute_and_write(sql, 'DATA_TYPE', 'AUTO_DERIVED', ...)
  │
  ├─ TIER B — CONFIGURED checks
  │   ├─ p_load_tier_b_rules(domain_id, 'BOUNDS')     → l_bounds_rules
  │   │   p_build_bounds_sql(l_bounds_rules, stk_table, vendor_id, coverage_period)
  │   │   p_execute_and_write(sql, 'BOUNDS', 'CONFIGURED', ...)
  │   │
  │   ├─ p_load_tier_b_rules(domain_id, 'DRIFT')      → l_drift_rules
  │   │   p_get_prior_period(source_id, coverage_period) → prior_period
  │   │   p_build_drift_sql(l_drift_rules, stk_table, vendor_id, coverage_period, prior_period)
  │   │   p_execute_and_write(sql, 'DRIFT', 'CONFIGURED', ...)
  │   │
  │   └─ p_load_tier_b_rules(domain_id, 'COMPLETENESS') → l_comp_rules
  │       p_build_completeness_sql(l_comp_rules, stk_table, vendor_id, coverage_period)
  │       p_execute_and_write(sql, 'COMPLETENESS', 'CONFIGURED', ...)
  │
  ├─ COMMIT
  └─ udm_pkg_lineage.close_batch (COMPLETE or PARTIAL)
```

If any builder returns NULL (no attributes or rules of that type), skip that check — do not execute.

---

## 8. Type Definitions

Declare in package body before all procedures.

```plsql
-- Attribute record for Tier A checks
TYPE t_dq_attr_rec IS RECORD (
  canonical_name  udm_attribute_map.canonical_name%TYPE,
  data_type       udm_attribute_map.data_type%TYPE,
  is_mandatory    udm_attribute_map.is_mandatory%TYPE
);
TYPE t_dq_attr_tab IS TABLE OF t_dq_attr_rec INDEX BY PLS_INTEGER;

-- Rule record for Tier B checks
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

-- Result collections — parallel arrays, BULK COLLECT targets
TYPE t_metric_tab   IS TABLE OF VARCHAR2(128) INDEX BY PLS_INTEGER;
TYPE t_ruleid_tab   IS TABLE OF VARCHAR2(20)  INDEX BY PLS_INTEGER;
TYPE t_status_tab   IS TABLE OF VARCHAR2(10)  INDEX BY PLS_INTEGER;
TYPE t_number_tab   IS TABLE OF NUMBER        INDEX BY PLS_INTEGER;
TYPE t_details_tab  IS TABLE OF VARCHAR2(500) INDEX BY PLS_INTEGER;
TYPE t_action_tab   IS TABLE OF VARCHAR2(20)  INDEX BY PLS_INTEGER;
TYPE t_varchar30_tab IS TABLE OF VARCHAR2(30) INDEX BY PLS_INTEGER;
```

---

## 9. Private Procedures — Metadata Layer

### 9.1 `p_load_tier_a_attrs`

```plsql
PROCEDURE p_load_tier_a_attrs (
  p_source_id  IN  VARCHAR2,
  p_check_type IN  VARCHAR2,   -- 'NOT_NULL' or 'DATA_TYPE'
  p_attrs      OUT t_dq_attr_tab
);
```

For `NOT_NULL`: BULK COLLECT `canonical_name`, `data_type`, `is_mandatory` where `is_mandatory = 'Y'` AND `is_subject_key = 'N'` AND `is_time_key = 'N'` AND `map_status = 'ACTIVE'`.

For `DATA_TYPE`: BULK COLLECT where `data_type = 'VARCHAR'` AND `is_subject_key = 'N'` AND `is_time_key = 'N'` AND `map_status = 'ACTIVE'`. Only VARCHAR typed columns are checked — NUMBER and DATE typed stack columns enforce type at INSERT time.

### 9.2 `p_load_tier_b_rules`

```plsql
PROCEDURE p_load_tier_b_rules (
  p_domain_id  IN  VARCHAR2,
  p_check_type IN  VARCHAR2,
  p_rules      OUT t_dq_rule_tab
);
```

BULK COLLECT from `udm_dq_rules` where `domain_id = p_domain_id` AND `check_type = p_check_type` AND `is_active = 'Y'` AND `(effective_to IS NULL OR effective_to > SYSDATE)`.

### 9.3 `p_get_prior_period`

```plsql
FUNCTION p_get_prior_period (
  p_source_id      IN VARCHAR2,
  p_curr_period    IN VARCHAR2
) RETURN VARCHAR2;
```

Queries `udm_lineage` for the most recent COMPLETE LOAD lineage row for `p_source_id` where `coverage_period < p_curr_period`. Returns that `coverage_period`. Returns NULL if no prior period found — DRIFT check emits WARNING for all attributes when NULL.

---

## 10. Private Procedures — SQL Builder Layer

These are the core development task. Each function:
- Takes metadata collections as input (in-memory, already loaded)
- Iterates them in PL/SQL to build a SQL string
- Returns the SQL string
- Executes no DML
- Returns NULL if the input collection is empty (caller skips the check)

### The UNPIVOT Pattern

All five builders use the same structural pattern:

```sql
WITH agg AS (
  SELECT
    COUNT(*) AS total_rows,
    {aggregate_expression_1} AS c_1,
    {aggregate_expression_2} AS c_2,
    ...
  FROM {stk_table}
  WHERE source_vendor   = :v
  AND   coverage_period = :p     -- or lineage_id = :l for NOT_NULL/DATA_TYPE
  AND   is_current      = 'Y'
)
SELECT
  {extract canonical_name from alias}     AS metric_name,
  {extract rule_id from alias}            AS rule_id,
  {check_result expression}              AS check_result,
  {actual_value expression}              AS actual_value,
  {expected_value expression}            AS expected_value,
  {action expression}                    AS action_taken,
  {details string}                       AS details
FROM agg
UNPIVOT INCLUDE NULLS (
  check_value FOR alias_enc IN (
    c_1 AS '{encoded_metadata_1}',
    c_2 AS '{encoded_metadata_2}',
    ...
  )
)
```

The UNPIVOT alias carries the metadata for each attribute/rule. The alias is a pipe-delimited string parsed in the outer SELECT using `REGEXP_SUBSTR`. This means metadata travels through the UNPIVOT without extra joins.

**Alias naming:** Use positional aliases `c_1`, `c_2`, `c_3`, ... in the aggregation CTE. Oracle column aliases in CTEs must be valid identifiers. The UNPIVOT alias strings (the literals after `AS`) can be any VARCHAR2 value.

**Column alias length limit:** Oracle 19c column aliases in queries are limited to 128 characters. The `c_N` positional alias pattern keeps all aliases within this limit.

**UNPIVOT string limit:** The pipe-delimited string in the UNPIVOT `AS` clause is a string literal. Oracle 19c supports literals up to 4000 characters. Maximum content per entry: 128 (canonical_name) + 1 + 20 (rule_id) + 1 + 20 (threshold as string) = 170 characters. Well within limit.

---

### 10.1 `p_build_not_null_sql`

**Signature:**
```plsql
FUNCTION p_build_not_null_sql (
  p_attrs      IN t_dq_attr_tab,
  p_stk_table  IN VARCHAR2,
  p_vendor_id  IN VARCHAR2,
  p_lineage_id IN VARCHAR2
) RETURN VARCHAR2;
```

**Returns:** NULL if `p_attrs.COUNT = 0`.

**UNPIVOT alias encoding:** `'{canonical_name}'` — just the name (no rule_id or threshold for Tier A checks).

**Aggregate expression per attribute:**
```sql
SUM(CASE WHEN {canonical_name} IS NULL THEN 1 ELSE 0 END) AS c_{i}
```

**Generated SQL structure:**
```sql
WITH agg AS (
  SELECT
    COUNT(*) AS total_rows,
    SUM(CASE WHEN scope1_mtco2 IS NULL THEN 1 ELSE 0 END) AS c_1,
    SUM(CASE WHEN scope2_mtco2 IS NULL THEN 1 ELSE 0 END) AS c_2,
    SUM(CASE WHEN revenue_musd IS NULL THEN 1 ELSE 0 END) AS c_3
  FROM udm.udm_emissions_stk
  WHERE source_vendor = :v
  AND   lineage_id    = :l         -- scoped to this exact load batch
  AND   is_current    = 'Y'
)
SELECT
  alias_enc                                            AS metric_name,
  NULL                                                 AS rule_id,
  CASE WHEN null_count > 0 THEN 'FAIL' ELSE 'PASS' END AS check_result,
  null_count                                           AS actual_value,
  0                                                    AS expected_value,
  CASE WHEN null_count > 0 THEN 'ALERT' ELSE 'NONE' END AS action_taken,
  null_count || ' of ' || total_rows || ' rows null'  AS details
FROM agg
UNPIVOT INCLUDE NULLS (null_count FOR alias_enc IN (
  c_1 AS 'scope1_mtco2',
  c_2 AS 'scope2_mtco2',
  c_3 AS 'revenue_musd'
))
```

**Bind variables at execution:** `:v` = vendor_id, `:l` = lineage_id.

**Scoped to lineage_id (not coverage_period):** NOT_NULL checks the rows written by this specific load batch. Using lineage_id ensures that if the same period has been loaded multiple times (restatements), the check applies to the current load only.

---

### 10.2 `p_build_datatype_sql`

**Signature:**
```plsql
FUNCTION p_build_datatype_sql (
  p_attrs      IN t_dq_attr_tab,
  p_stk_table  IN VARCHAR2,
  p_vendor_id  IN VARCHAR2,
  p_lineage_id IN VARCHAR2
) RETURN VARCHAR2;
```

**Scope:** VARCHAR2-typed canonical columns only (loaded by `p_load_tier_a_attrs` with `data_type = 'VARCHAR'` filter). NUMBER and DATE typed stack columns are enforced at INSERT time by Oracle — checking them here is redundant.

**Returns:** NULL if no VARCHAR-typed metric attributes exist for this source.

**What is being checked:** VARCHAR metric columns that represent coded or structured values — assurance level codes, classification strings, date-as-string columns. The check flags any value that contains characters outside the expected pattern.

**UNPIVOT alias encoding:** `'{canonical_name}'`

**Aggregate expression per attribute:**
```sql
SUM(CASE WHEN {canonical_name} IS NOT NULL
         AND NOT REGEXP_LIKE({canonical_name}, '^[A-Za-z0-9 \-_/\.]+$')
         THEN 1 ELSE 0 END) AS c_{i}
```

The REGEXP pattern `^[A-Za-z0-9 \-_/\.]+$` allows alphanumeric characters, spaces, hyphens, underscores, forward slashes, and periods. This covers the vast majority of valid coded values. If a domain needs a stricter or different pattern for a specific attribute, register a COMPLETENESS rule with a custom threshold instead.

**Generated SQL structure:**
```sql
WITH agg AS (
  SELECT
    COUNT(*) AS total_rows,
    SUM(CASE WHEN assurance_level IS NOT NULL
             AND NOT REGEXP_LIKE(assurance_level, '^[A-Za-z0-9 \-_/\.]+$')
             THEN 1 ELSE 0 END) AS c_1
  FROM udm.udm_emissions_stk
  WHERE source_vendor = :v
  AND   lineage_id    = :l
  AND   is_current    = 'Y'
)
SELECT
  alias_enc                                              AS metric_name,
  NULL                                                   AS rule_id,
  CASE WHEN bad_count > 0 THEN 'FAIL' ELSE 'PASS' END   AS check_result,
  bad_count                                              AS actual_value,
  0                                                      AS expected_value,
  CASE WHEN bad_count > 0 THEN 'ALERT' ELSE 'NONE' END  AS action_taken,
  bad_count || ' of ' || total_rows || ' rows fail pattern check' AS details
FROM agg
UNPIVOT INCLUDE NULLS (bad_count FOR alias_enc IN (
  c_1 AS 'assurance_level'
))
```

---

### 10.3 `p_build_bounds_sql`

**Signature:**
```plsql
FUNCTION p_build_bounds_sql (
  p_rules      IN t_dq_rule_tab,
  p_stk_table  IN VARCHAR2,
  p_vendor_id  IN VARCHAR2,
  p_period     IN VARCHAR2
) RETURN VARCHAR2;
```

**Returns:** NULL if `p_rules.COUNT = 0`.

**UNPIVOT alias encoding:** `'{metric_name}|{rule_id}'`

**Aggregate expression per rule:**
```sql
SUM(CASE WHEN TO_NUMBER({metric_name}) NOT BETWEEN {min_value} AND {max_value}
         THEN 1 ELSE 0 END) AS c_{i}
```

The min and max values are embedded as numeric literals in the SQL — they come from a governed configuration table (`udm_dq_rules`), not user input. Embedding them as literals avoids the complexity of binding a variable number of min/max pairs and is safe because the values are owned by the platform configuration team.

**Generated SQL structure:**
```sql
WITH agg AS (
  SELECT
    COUNT(*) AS total_rows,
    SUM(CASE WHEN TO_NUMBER(scope1_mtco2) NOT BETWEEN 0 AND 1000000
             THEN 1 ELSE 0 END) AS c_1,
    SUM(CASE WHEN TO_NUMBER(revenue_musd) NOT BETWEEN 0 AND 50000
             THEN 1 ELSE 0 END) AS c_2
  FROM udm.udm_emissions_stk
  WHERE source_vendor   = :v
  AND   coverage_period = :p
  AND   is_current      = 'Y'
)
SELECT
  REGEXP_SUBSTR(alias_enc, '[^|]+', 1, 1)              AS metric_name,
  REGEXP_SUBSTR(alias_enc, '[^|]+', 1, 2)              AS rule_id,
  CASE WHEN fail_count > 0 THEN 'FAIL' ELSE 'PASS' END AS check_result,
  fail_count                                            AS actual_value,
  NULL                                                  AS expected_value,
  CASE WHEN fail_count > 0 THEN action_col ELSE 'NONE' END AS action_taken,
  fail_count || ' row(s) outside bounds'               AS details
FROM agg
UNPIVOT INCLUDE NULLS (fail_count FOR alias_enc IN (
  c_1 AS 'scope1_mtco2|DQ-BOUNDS-001',
  c_2 AS 'revenue_musd|DQ-BOUNDS-002'
))
```

**Note on action column:** The UNPIVOT pattern cannot carry the `action` value through the alias string cleanly alongside numeric check values. Resolve the action in `p_execute_and_write` by looking it up from the pre-loaded rules collection using the rule_id extracted from the result row.

---

### 10.4 `p_build_drift_sql`

**Signature:**
```plsql
FUNCTION p_build_drift_sql (
  p_rules        IN t_dq_rule_tab,
  p_stk_table    IN VARCHAR2,
  p_vendor_id    IN VARCHAR2,
  p_curr_period  IN VARCHAR2,
  p_prior_period IN VARCHAR2
) RETURN VARCHAR2;
```

**Returns:** NULL if `p_rules.COUNT = 0` OR `p_prior_period IS NULL`.

If `p_prior_period IS NULL`, the executor must write a WARNING row for each rule without executing the SQL (no prior period to compare against).

**UNPIVOT alias encoding:** `'{metric_name}|{rule_id}|{threshold}'`

The threshold is embedded as a string in the alias so the outer SELECT can parse it and apply the FAIL/PASS logic without a join back to the rules table.

**Pattern:** One scan covering both periods using conditional aggregation. Two AVG expressions per rule attribute — one for current, one for prior. The scan filters `coverage_period IN (:curr, :prior)`. The drift percentage is calculated in a derived table before UNPIVOT.

**Generated SQL structure:**
```sql
WITH two_period AS (
  SELECT
    AVG(CASE WHEN coverage_period = :curr  THEN TO_NUMBER(scope1_mtco2) END) AS curr_1,
    AVG(CASE WHEN coverage_period = :prior THEN TO_NUMBER(scope1_mtco2) END) AS prior_1,
    AVG(CASE WHEN coverage_period = :curr  THEN TO_NUMBER(scope2_mtco2) END) AS curr_2,
    AVG(CASE WHEN coverage_period = :prior THEN TO_NUMBER(scope2_mtco2) END) AS prior_2
  FROM udm.udm_emissions_stk
  WHERE source_vendor   = :v
  AND   is_current      = 'Y'
  AND   coverage_period IN (:curr, :prior)
),
drift_pct AS (
  SELECT
    CASE WHEN NVL(prior_1, 0) = 0 THEN NULL
         ELSE ABS((curr_1 - prior_1) / prior_1) * 100
    END AS dp_1,
    CASE WHEN NVL(prior_2, 0) = 0 THEN NULL
         ELSE ABS((curr_2 - prior_2) / prior_2) * 100
    END AS dp_2,
    curr_1, prior_1, curr_2, prior_2
  FROM two_period
)
SELECT
  REGEXP_SUBSTR(alias_enc,'[^|]+',1,1)              AS metric_name,
  REGEXP_SUBSTR(alias_enc,'[^|]+',1,2)              AS rule_id,
  TO_NUMBER(REGEXP_SUBSTR(alias_enc,'[^|]+',1,3))   AS threshold_val,
  CASE
    WHEN drift_val IS NULL                                   THEN 'WARNING'
    WHEN drift_val > TO_NUMBER(REGEXP_SUBSTR(alias_enc,'[^|]+',1,3)) THEN 'FAIL'
    ELSE 'PASS'
  END                                               AS check_result,
  ROUND(drift_val, 4)                               AS actual_value,
  TO_NUMBER(REGEXP_SUBSTR(alias_enc,'[^|]+',1,3))   AS expected_value,
  ROUND(drift_val, 2) || '% drift vs prior period'  AS details
FROM drift_pct
UNPIVOT INCLUDE NULLS (drift_val FOR alias_enc IN (
  dp_1 AS 'scope1_mtco2|DQ-DRIFT-001|15',
  dp_2 AS 'scope2_mtco2|DQ-DRIFT-002|20'
))
```

**Bind variables at execution:** `:v` = vendor_id, `:curr` = current period, `:prior` = prior period (bound twice in USING clause — once for each reference).

**Why single scan covers both periods:** The WHERE clause filters `coverage_period IN (:curr, :prior)`. The conditional aggregation (`CASE WHEN coverage_period = :curr THEN ...`) separates the two periods within the single scan. One table access produces all averages for all attributes across both periods.

---

### 10.5 `p_build_completeness_sql`

**Signature:**
```plsql
FUNCTION p_build_completeness_sql (
  p_rules      IN t_dq_rule_tab,
  p_stk_table  IN VARCHAR2,
  p_vendor_id  IN VARCHAR2,
  p_period     IN VARCHAR2
) RETURN VARCHAR2;
```

**Returns:** NULL if `p_rules.COUNT = 0`.

**UNPIVOT alias encoding:** `'{metric_name}|{rule_id}|{threshold}'`

**Aggregate expression per rule:** `COUNT({metric_name}) AS c_{i}` — Oracle's `COUNT(col)` ignores NULLs, giving the count of non-null values directly.

**Generated SQL structure:**
```sql
WITH agg AS (
  SELECT
    COUNT(*) AS total_rows,
    COUNT(scope1_mtco2) AS c_1,
    COUNT(scope3_mtco2) AS c_2
  FROM udm.udm_emissions_stk
  WHERE source_vendor   = :v
  AND   coverage_period = :p
  AND   is_current      = 'Y'
),
pct AS (
  SELECT
    total_rows,
    CASE WHEN total_rows = 0 THEN 100
         ELSE ROUND(c_1 * 100.0 / total_rows, 2) END AS cp_1,
    CASE WHEN total_rows = 0 THEN 100
         ELSE ROUND(c_2 * 100.0 / total_rows, 2) END AS cp_2
  FROM agg
)
SELECT
  REGEXP_SUBSTR(alias_enc,'[^|]+',1,1)               AS metric_name,
  REGEXP_SUBSTR(alias_enc,'[^|]+',1,2)               AS rule_id,
  TO_NUMBER(REGEXP_SUBSTR(alias_enc,'[^|]+',1,3))    AS threshold_val,
  CASE WHEN complete_pct >= TO_NUMBER(REGEXP_SUBSTR(alias_enc,'[^|]+',1,3))
       THEN 'PASS' ELSE 'FAIL' END                   AS check_result,
  complete_pct                                        AS actual_value,
  TO_NUMBER(REGEXP_SUBSTR(alias_enc,'[^|]+',1,3))    AS expected_value,
  ROUND(complete_pct,1) || '% non-null (threshold='
    || REGEXP_SUBSTR(alias_enc,'[^|]+',1,3) || '%)'  AS details
FROM pct
UNPIVOT INCLUDE NULLS (complete_pct FOR alias_enc IN (
  cp_1 AS 'scope1_mtco2|DQ-COMP-001|95',
  cp_2 AS 'scope3_mtco2|DQ-COMP-002|80'
))
```

---

## 11. Private Procedure — Executor

### `p_execute_and_write`

```plsql
PROCEDURE p_execute_and_write (
  p_sql          IN VARCHAR2,         -- built by one of the p_build_* functions
  p_check_type   IN VARCHAR2,
  p_check_source IN VARCHAR2,         -- AUTO_DERIVED or CONFIGURED
  p_rules        IN t_dq_rule_tab,    -- for action lookup by rule_id; pass empty for Tier A
  p_source_id    IN VARCHAR2,
  p_domain_id    IN VARCHAR2,
  p_vendor_id    IN VARCHAR2,
  p_period       IN VARCHAR2,
  p_lineage_id   IN VARCHAR2,         -- the DI_CHECK lineage_id
  p_load_lin_id  IN VARCHAR2 DEFAULT NULL,  -- for NOT_NULL/DATA_TYPE lineage_id bind
  p_curr_period  IN VARCHAR2 DEFAULT NULL,  -- for DRIFT curr period bind
  p_prior_period IN VARCHAR2 DEFAULT NULL,  -- for DRIFT prior period bind
  p_rows_written OUT NUMBER
);
```

**Algorithm:**

**Step 1 — BULK COLLECT results.**

Each builder function produces a SELECT with exactly these columns in this order:
```
metric_name VARCHAR2(128)
rule_id     VARCHAR2(20)
check_result VARCHAR2(10)
actual_value NUMBER
expected_value NUMBER
action_taken VARCHAR2(20)   ← for Tier A only; Tier B resolves in step 2
details     VARCHAR2(500)
```

Execute with the appropriate USING clause per check type:
- NOT_NULL / DATA_TYPE: `USING p_vendor_id, p_load_lin_id`
- BOUNDS / COMPLETENESS: `USING p_vendor_id, p_period`
- DRIFT: `USING p_vendor_id, p_curr_period, p_prior_period, p_curr_period, p_prior_period`
  (`:v`, `:curr`, `:prior` appear twice in the SQL — the USING clause must list them in the order they appear)

```plsql
EXECUTE IMMEDIATE p_sql
BULK COLLECT INTO
  l_metric, l_rule_id, l_result,
  l_actual, l_expected, l_action_raw, l_details
USING ...;
```

**Step 2 — Resolve action for Tier B checks.**

For Tier B check types, the action comes from `udm_dq_rules.action` via the loaded rules collection. The UNPIVOT result gives back the rule_id — look up the action from `p_rules` for FAIL rows. For PASS and WARNING, action is always `'NONE'` or `'ALERT'` respectively.

```plsql
FOR i IN 1 .. l_result.COUNT LOOP
  IF p_check_source = 'CONFIGURED' THEN
    IF l_result(i) = 'FAIL' THEN
      -- find action from p_rules where rule_id matches
      FOR j IN 1 .. p_rules.COUNT LOOP
        IF p_rules(j).rule_id = l_rule_id(i) THEN
          l_action(i) := p_rules(j).action;
          EXIT;
        END IF;
      END LOOP;
    ELSIF l_result(i) = 'WARNING' THEN
      l_action(i) := 'ALERT';
    ELSE
      l_action(i) := 'NONE';
    END IF;
  ELSE
    l_action(i) := l_action_raw(i);  -- Tier A action already set in builder SQL
  END IF;
END LOOP;
```

**Step 3 — Pre-generate result IDs in bulk.**

```plsql
l_n := l_metric.COUNT;
IF l_n = 0 THEN p_rows_written := 0; RETURN; END IF;

SELECT udm_dq_result_seq.NEXTVAL
BULK COLLECT INTO l_seqs
FROM dual CONNECT BY ROWNUM <= l_n;

FOR i IN 1 .. l_n LOOP
  l_result_ids(i) := 'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD')
                   || '-' || LPAD(l_seqs(i), 8, '0');
END LOOP;
```

**Step 4 — FORALL INSERT.**

```plsql
FORALL i IN 1 .. l_n
  INSERT INTO udm_dq_results (
    result_id, lineage_id, rule_id, check_type, check_source,
    domain_id, source_id, metric_name, movement_point,
    check_result, actual_value, expected_value,
    entity_key, coverage_period, action_taken, checked_at
  ) VALUES (
    l_result_ids(i), p_lineage_id, l_rule_id(i), p_check_type, p_check_source,
    p_domain_id, p_source_id, l_metric(i), 'STAGE_TO_VS',
    l_result(i), l_actual(i), l_expected(i),
    NULL, p_period, l_action(i), SYSDATE
  );

p_rows_written := l_n;
```

---

## 12. Performance Requirements

| Requirement | Constraint |
|---|---|
| SQL executions per check type | Exactly 1, regardless of attribute or rule count |
| Total SQL executions per `run_checks` call | Maximum 5 (one per check type) |
| `p_execute_and_write` DML | One `FORALL INSERT` per call — no row-by-row INSERT |
| Sequence generation | One `SELECT … CONNECT BY ROWNUM <=` per executor call |
| SQL string length | If > 30,000 characters, log WARNING — domain should be decomposed |
| Empty collection guard | Return NULL from builder if input collection is empty — executor skips |

---

## 13. Error Handling

| Situation | Behaviour |
|---|---|
| Builder returns NULL (no attrs/rules) | Executor skips that check type — no error |
| `p_prior_period` is NULL for DRIFT | Write WARNING rows for all drift rules with `actual_value = NULL`, `details = 'No prior period found'`. Do not execute the DRIFT SQL. |
| SQL execution error in executor | Catch, log to DBMS_OUTPUT with check_type and first 200 chars of SQL. Continue to next check type — do not abort entire run. Increment a failure counter. |
| Total rows = 0 in stack | All Tier B checks emit PASS with `details = 'No rows in scope'`. Tier A checks emit PASS with null_count = 0. |
| FORALL INSERT failure | Catch, log, re-raise. A failed INSERT to dq_results is a system error — do not silently discard results. |
| `run_checks` exception (outer) | Call `udm_pkg_lineage.close_batch(status='FAILED')`. Never suppress. |

---

## 14. Test Data

Use this exact catalog seed for all unit and integration tests. Copy directly — no external reference needed.

### Source
```
source_id    = 'SRC-TEST-001'
vendor_id    = 'VENDOR_T'
domain_id    = 'EMISSIONS'
stk_table    = 'udm.udm_emissions_stk'
```

### Attribute map (Tier A test attributes)

| canonical_name | data_type | is_mandatory | is_subject_key | is_time_key |
|---|---|---|---|---|
| `scope1_mtco2` | NUMBER | Y | N | N |
| `scope2_mtco2` | NUMBER | N | N | N |
| `scope3_mtco2` | NUMBER | N | N | N |
| `assurance_level` | VARCHAR | N | N | N |

### DQ Rules (Tier B)

| rule_id | metric_name | check_type | min_value | max_value | threshold | action |
|---|---|---|---|---|---|---|
| `DQ-BOUNDS-001` | `scope1_mtco2` | BOUNDS | 0 | 1000000 | NULL | ALERT |
| `DQ-BOUNDS-002` | `revenue_musd` | BOUNDS | 0 | 50000 | NULL | ALERT |
| `DQ-DRIFT-001` | `scope1_mtco2` | DRIFT | NULL | NULL | 15 | ALERT |
| `DQ-DRIFT-002` | `scope2_mtco2` | DRIFT | NULL | NULL | 20 | ALERT |
| `DQ-COMP-001` | `scope1_mtco2` | COMPLETENESS | NULL | NULL | 95 | ALERT |
| `DQ-COMP-002` | `scope3_mtco2` | COMPLETENESS | NULL | NULL | 80 | ALERT |

### Stack rows for testing

| entity_key | coverage_period | source_vendor | is_current | lineage_id | scope1_mtco2 | scope2_mtco2 | scope3_mtco2 | assurance_level |
|---|---|---|---|---|---|---|---|---|
| ENT-001 | 2024 | VENDOR_T | Y | LIN-TEST-001 | 12500 | 8300 | NULL | `Limited` |
| ENT-002 | 2024 | VENDOR_T | Y | LIN-TEST-001 | 88200 | 31400 | 312000 | `Reasonable` |
| ENT-003 | 2024 | VENDOR_T | Y | LIN-TEST-001 | NULL | 5100 | 9800 | `INVALID#CODE!` |
| ENT-001 | 2023 | VENDOR_T | N | LIN-TEST-000 | 11900 | 8100 | 43100 | `Limited` |
| ENT-002 | 2023 | VENDOR_T | N | LIN-TEST-000 | 85000 | 30000 | 290000 | `Reasonable` |

---

## 15. Unit Tests — SQL Builder Functions

Each test: call the builder function, `DBMS_OUTPUT.PUT_LINE` the result, compare against expected output. No DML executed during unit tests.

### Test 8B-01 — `p_build_not_null_sql`: standard output

```
Setup:   p_attrs contains scope1_mtco2 (is_mandatory=Y) only
         p_stk_table = 'udm.udm_emissions_stk'
         p_vendor_id = 'VENDOR_T'
         p_lineage_id = 'LIN-TEST-001'
Call:    p_build_not_null_sql(p_attrs, 'udm.udm_emissions_stk', 'VENDOR_T', 'LIN-TEST-001')
Expect:  SQL contains:
         - 'WITH agg AS'
         - 'SUM(CASE WHEN scope1_mtco2 IS NULL THEN 1 ELSE 0 END) AS c_1'
         - 'UNPIVOT INCLUDE NULLS'
         - "c_1 AS 'scope1_mtco2'"
         - 'WHERE source_vendor = :v'
         - 'AND   lineage_id    = :l'
         - No 'UNION ALL' (single scan)
```

### Test 8B-02 — `p_build_not_null_sql`: empty collection returns NULL

```
Setup:   p_attrs.COUNT = 0
Call:    p_build_not_null_sql(p_attrs, ...)
Expect:  NULL
```

### Test 8B-03 — `p_build_not_null_sql`: multiple mandatory attributes

```
Setup:   p_attrs has 3 mandatory attributes: scope1_mtco2, scope2_mtco2, revenue_musd
Call:    p_build_not_null_sql(p_attrs, ...)
Expect:  SQL contains c_1, c_2, c_3 in the aggregation CTE
         UNPIVOT clause has 3 entries: c_1, c_2, c_3
         Exactly one FROM clause (no UNION ALL)
```

### Test 8B-04 — `p_build_bounds_sql`: alias encoding

```
Setup:   p_rules has DQ-BOUNDS-001 (scope1_mtco2, 0, 1000000) only
Call:    p_build_bounds_sql(p_rules, 'udm.udm_emissions_stk', 'VENDOR_T', '2024')
Expect:  SQL contains:
         - 'BETWEEN 0 AND 1000000'
         - "c_1 AS 'scope1_mtco2|DQ-BOUNDS-001'"
         - "REGEXP_SUBSTR(alias_enc,'[^|]+',1,1)" for metric_name
         - "REGEXP_SUBSTR(alias_enc,'[^|]+',1,2)" for rule_id
```

### Test 8B-05 — `p_build_drift_sql`: two-period single scan

```
Setup:   p_rules has DQ-DRIFT-001 (scope1_mtco2, threshold=15) only
         p_curr_period = '2024', p_prior_period = '2023'
Call:    p_build_drift_sql(p_rules, ...)
Expect:  SQL contains:
         - 'WITH two_period AS'
         - 'WITH drift_pct AS' (or equivalent derived table)
         - 'AVG(CASE WHEN coverage_period = :curr THEN TO_NUMBER(scope1_mtco2) END)'
         - 'AVG(CASE WHEN coverage_period = :prior THEN TO_NUMBER(scope1_mtco2) END)'
         - 'IN (:curr, :prior)' in WHERE clause
         - Exactly ONE FROM clause referencing the stack table
         - "dp_1 AS 'scope1_mtco2|DQ-DRIFT-001|15'"
         - No UNION ALL
```

### Test 8B-06 — `p_build_drift_sql`: NULL prior period returns NULL

```
Setup:   p_prior_period = NULL
Call:    p_build_drift_sql(p_rules, stk, 'VENDOR_T', '2024', NULL)
Expect:  NULL
```

### Test 8B-07 — `p_build_completeness_sql`: COUNT pattern

```
Setup:   p_rules has DQ-COMP-001 (scope1_mtco2, threshold=95) and
                     DQ-COMP-002 (scope3_mtco2, threshold=80)
Call:    p_build_completeness_sql(p_rules, ...)
Expect:  SQL contains:
         - 'COUNT(scope1_mtco2) AS c_1'    (COUNT ignores NULLs)
         - 'COUNT(scope3_mtco2) AS c_2'
         - 'pct AS' CTE calculating percentage
         - UNPIVOT with 2 entries
         - "cp_1 AS 'scope1_mtco2|DQ-COMP-001|95'"
         - "cp_2 AS 'scope3_mtco2|DQ-COMP-002|80'"
```

### Test 8B-08 — `p_build_datatype_sql`: VARCHAR only

```
Setup:   p_attrs has assurance_level (data_type=VARCHAR) only
Call:    p_build_datatype_sql(p_attrs, ...)
Expect:  SQL contains:
         - 'REGEXP_LIKE' check
         - 'NOT REGEXP_LIKE(assurance_level'
         - c_1 alias with UNPIVOT entry for assurance_level
```

---

## 16. Integration Tests

### Test INT-08-01 — NOT_NULL: one null in mandatory attribute

```
Setup:   Insert test rows from Section 14 (ENT-003 has scope1_mtco2 = NULL)
         Attribute map: scope1_mtco2 is_mandatory = 'Y'
Call:    run_checks('SRC-TEST-001', 'LIN-TEST-001')
Assert:
  - udm_dq_results has one NOT_NULL row for scope1_mtco2
  - check_result = 'FAIL'
  - actual_value = 1
  - action_taken = 'ALERT'
  - check_source = 'AUTO_DERIVED'
  - rule_id IS NULL
  - Exactly ONE SQL executed for NOT_NULL (verify via DBMS_XPLAN or test harness counter)
```

### Test INT-08-02 — BOUNDS: value exceeds max

```
Setup:   Insert a row with scope1_mtco2 = 1500000 (exceeds DQ-BOUNDS-001 max of 1000000)
         DQ-BOUNDS-001 rule active
Call:    run_checks('SRC-TEST-001', 'LIN-TEST-001')
Assert:
  - udm_dq_results has one BOUNDS row for scope1_mtco2
  - check_result = 'FAIL'
  - actual_value = 1 (one row out of bounds)
  - rule_id = 'DQ-BOUNDS-001'
  - check_source = 'CONFIGURED'
```

### Test INT-08-03 — DRIFT: within threshold

```
Setup:   2023 rows: scope1_mtco2 avg = 11900, scope2_mtco2 avg = 8100
         2024 rows: scope1_mtco2 avg = 12500 (+5.0%), scope2_mtco2 avg = 8300 (+2.5%)
         DQ-DRIFT-001 threshold = 15%, DQ-DRIFT-002 threshold = 20%
Call:    run_checks('SRC-TEST-001', 'LIN-TEST-001')
Assert:
  - DRIFT row for scope1_mtco2: check_result = 'PASS', actual_value ≈ 5.04
  - DRIFT row for scope2_mtco2: check_result = 'PASS', actual_value ≈ 2.47
  - Exactly ONE SQL executed for DRIFT
```

### Test INT-08-04 — DRIFT: no prior period

```
Setup:   Only 2024 rows exist (no 2023 lineage row for this source)
Call:    run_checks('SRC-TEST-001', 'LIN-TEST-001')
Assert:
  - DRIFT rows for all configured metrics exist
  - check_result = 'WARNING'
  - actual_value IS NULL
  - details contains 'No prior period found'
  - No SQL executed against stack table for DRIFT check
```

### Test INT-08-05 — COMPLETENESS: below threshold

```
Setup:   3 rows total, 2 have scope3_mtco2 populated (67% complete)
         DQ-COMP-002 threshold = 80%
Call:    run_checks('SRC-TEST-001', 'LIN-TEST-001')
Assert:
  - COMPLETENESS row for scope3_mtco2: check_result = 'FAIL'
  - actual_value ≈ 66.67
  - expected_value = 80
```

### Test INT-08-06 — Scaling: 50 attributes, check execution count

```
Setup:   50 mandatory attributes in attribute_map for SRC-TEST-001
         50 BOUNDS rules, 50 DRIFT rules, 50 COMPLETENESS rules in udm_dq_rules
Call:    run_checks('SRC-TEST-001', 'LIN-TEST-001')
Assert:
  - udm_dq_results has rows for all 50 attributes × each applicable check type
  - Total distinct SQL executions = 5 (one per check type)
    (Verify via V$SQL count or test harness instrumentation)
  - Run completes in < 10 seconds for 10,000 stack rows
```

---

## 17. Acceptance Criteria

- [ ] All unit tests 8B-01 through 8B-08 pass — SQL strings match expected patterns
- [ ] All integration tests INT-08-01 through INT-08-06 pass
- [ ] Test INT-08-06 confirms exactly 5 SQL executions for 50 attributes across 5 check types
- [ ] No `UNION ALL` in any generated SQL — each check type is a single table scan
- [ ] DRIFT check produces exactly one FROM clause referencing the stack table
- [ ] Empty attribute collection or rule collection causes the check type to be skipped — no error, no empty result rows
- [ ] NULL prior period for DRIFT produces WARNING rows without executing SQL against the stack
- [ ] `udm_lineage` has a DI_CHECK row with status COMPLETE or FAILED for every `run_checks` call
- [ ] `FORALL INSERT` is used in `p_execute_and_write` — no row-by-row INSERT loop
- [ ] Package compiles in Oracle 19c with zero errors and zero warnings

---

## 18. Build Order and Handover Notes

**Build in this order:**

1. Type definitions — all collection types declared first
2. `p_load_tier_a_attrs` and `p_load_tier_b_rules` — simple BULK COLLECTs, no logic
3. `p_get_prior_period` — simple lineage query
4. `p_build_not_null_sql` — simplest builder, establishes the UNPIVOT pattern
5. `p_build_datatype_sql` — same pattern, adds REGEXP
6. `p_build_completeness_sql` — same pattern, COUNT variant
7. `p_build_bounds_sql` — adds pipe-encoded alias
8. `p_build_drift_sql` — most complex: two CTEs, two-period scan
9. `p_execute_and_write` — the executor; test it first with the NOT_NULL SQL
10. `run_checks` — assembles all of the above
11. `run_domain_checks` — thin orchestration wrapper

**Test as you build.** After each builder, write a standalone anonymous PL/SQL block that calls the builder and prints the SQL to DBMS_OUTPUT. Verify the SQL structure by running it manually against the test stack table before wiring it into the executor.

**Key rules that cannot be broken:**
- One SQL execution per check type. No loops over attributes or rules in the executor.
- `FORALL INSERT` only in `p_execute_and_write`. No individual INSERT statements.
- Builder functions return strings only — no DML, no database writes.
- Never suppress exceptions in `run_checks` — failed checks must be visible in lineage.
- If a builder returns NULL, the executor skips — this is normal and expected, not an error.
