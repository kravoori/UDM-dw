# UDM Engine — Implementation Guide

## Files in This Delivery

| File | Version | Module | Purpose |
|---|---|---|---|
| `udm_mod09_lineage.sql` | v1 | Module 9 | Lineage Recorder — shared utility, compile first |
| `udm_mod06_harmonisation.sql` | v1 | Module 6 | Harmonisation Engine — initial version (superseded) |
| `udm_mod06_harmonisation_v2.sql` | **v2** | Module 6 | Harmonisation Engine — set-based rewrite, current version |
| `udm_mod06_patch_lookup_join.sql` | patch | Module 6 | lookup: transform refactor — LEFT JOIN in FROM clause |
| `udm_mod07_arbitration.sql` | v1 | Module 7 | Arbitration Engine — precedence + grain alignment |
| `udm_mod08_di_framework.sql` | v1 | Module 8 | DI Framework — Tier A auto-derived + Tier B threshold checks |
| `udm_scheduler_jobs.sql` | v1 | Scheduler | Oracle Scheduler programs and job definitions |
| `udm_runtime_sql_examples.sql` | — | Reference | Worked COLUMNAR + EAV runtime SQL examples with sample data |

> **Active Module 6 file is `udm_mod06_harmonisation_v2.sql` with the patch from `udm_mod06_patch_lookup_join.sql` applied. Do not deploy v1.**

---

## Compile Order

Run files in this exact order. FK dependencies and cross-package calls require it.

```sql
-- 1. Prerequisite: Tier 1 DDL must already be deployed
@udm_tier1_final_v2.sql

-- 2. Engine packages (Module 9 first — others depend on it)
@udm_mod09_lineage.sql
@udm_mod06_harmonisation_v2.sql   -- v2: set-based rewrite with lookup: patch applied
@udm_mod07_arbitration.sql
@udm_mod08_di_framework.sql

-- 3. Scheduler (after all packages compile clean)
@udm_scheduler_jobs.sql
```

> `udm_mod06_patch_lookup_join.sql` is not a standalone deployment file — it contains only the changed procedures. Apply it by replacing the corresponding sections in `udm_mod06_harmonisation_v2.sql` before compiling. The patch is documented separately for review traceability.

---

## Pre-Engine Data Tasks (must complete before first run)

These are the pending data tasks from the architecture context. Engine will fail without them.

```
1. INSERT into udm_source_registry    — all Option A sources
2. INSERT into udm_precedence_rules   — extracted from Option A stored procedure
3. INSERT into udm_entity_registry    — seeded from RDM DIM_CLIENT
4. INSERT into udm_entity_xref        — seeded from RDM dimension joins
5. INSERT into udm_ref_*              — seeded from RDM reference dimensions
6. INSERT into udm_ref_time           — all coverage periods in current estate
7. INSERT into udm_entity_membership  — COMPANY_SECTOR composite entities
```

---

## Engine Routing — Decision Tree

```
run_source(source_id)                      ← no coverage_period parameter (v2)
  │
  ├─ governance_status = UDM_CATALOGED?        → ELSE raise error
  ├─ PENDING_RETIREMENT attributes?            → raise error (blocked)
  ├─ p_find_pending_manifest()                 → finds latest COMPLETE manifest
  │     not yet linked to a LOAD lineage row   → ELSE raise error (nothing to do)
  │
  ├─ source_role = IDENTITY_SOURCE
  │     └─ resolution_target = REGISTRY_AND_XREF → create entity_registry + xref
  │     └─ resolution_target = XREF_ONLY         → add xref only; quarantine if missing
  │
  ├─ source_role = REFERENCE_SOURCE
  │     └─ refresh_strategy = FULL_REPLACE        → truncate + reload
  │     └─ refresh_strategy = INCREMENTAL         → MERGE on natural key
  │     └─ refresh_strategy = EFFECTIVE_DATE_MERGE→ close + insert
  │
  └─ source_role = DATA_SOURCE
        ├─ source_format = EAV      → pivot via MAX(CASE WHEN) GROUP BY
        └─ source_format = COLUMNAR
              │
              ├─ subject_type = ENTITY
              │     ├─ domain_grain has COMPANY_SECTOR → 3-step resolution + cache
              │     └─ standard entity              → xref JOIN in FROM clause
              ├─ subject_type = SPATIAL             → spatial_asset_registry JOIN
              └─ subject_type = INTERNAL_ID         → raw ID passes through
              │
              → transforms embedded as SQL expressions in SELECT list (not PL/SQL loop)
              → lookup: attributes resolved as LEFT JOINs in FROM clause
              → INSERT /*+ APPEND */ INTO udm_{domain}_stk
              → quarantine INSERT...SELECT NOT EXISTS (same currency filter, inverted join)
```

---

## COMPANY_SECTOR Entity Resolution

Three-step process per source row. Session-level PL/SQL cache avoids repeated MV lookups within a batch.

```
STEP 1  resolve company_entity_key  via udm_entity_xref
STEP 2  resolve sector_entity_key   via udm_entity_xref
STEP 3  derive COMPANY_SECTOR key:
          → check g_cs_cache (session array)
          → check udm_company_sector_mv
          → if not found and REGISTRY_AND_XREF: create entity + membership rows, COMMIT, populate cache
          → if not found and XREF_ONLY: quarantine row, PO investigates
```

Cache is cleared at the end of every `run_source` call via `flush_cs_cache`.

---

## Module 6 — v2 Rewrite Summary

v2 (`udm_mod06_harmonisation_v2.sql`) replaces v1 wholesale. Key differences:

**`run_source` signature** — `coverage_period` parameter removed. The engine finds the latest COMPLETE manifest with no corresponding LOAD lineage row via `p_find_pending_manifest`. The period stamped on stack rows comes from the source data (`time_col`), not the caller. This means the engine always processes current data as defined by `currency_mechanism`, with no risk of a caller passing a stale or incorrect period.

**Transforms in SQL, not PL/SQL** — `p_build_transform_expr` returns a SQL fragment for each attribute (e.g. `COALESCE(src.SC3_TONNE, src.SC3_UPSTREAM)`). The entire SELECT list is assembled as a string and executed as one `INSERT /*+ APPEND */ INTO … SELECT`. No row-by-row PL/SQL transform loop.

**Entity resolution via JOIN** — the main INSERT…SELECT joins `udm_entity_xref` directly. Unresolved rows are caught by a second `INSERT … SELECT … WHERE NOT EXISTS` into `udm_quarantine`. No per-row `p_resolve_entity` calls.

**COMPANY_SECTOR pre-pass uses FORALL** — `p_bulk_create_cs_entities` finds all distinct new `(company, sector)` pairs with one `BULK COLLECT`, pre-generates all sequence values in bulk, then three `FORALL INSERT` statements cover `entity_registry`, `COMPANY_COMPONENT` membership, and `SECTOR_COMPONENT` membership. One COMMIT refreshes the MV before the main INSERT runs.

**IDENTITY_SOURCE uses FORALL** — `BULK COLLECT` for new external IDs, sequence values pre-generated, two `FORALL INSERT` statements for `entity_registry` and `entity_xref`.

---

## lookup: Transform — LEFT JOIN Refactor

**File:** `udm_mod06_patch_lookup_join.sql`

### Problem

The original `lookup:` rule emitted a correlated scalar subquery in the SELECT clause:

```sql
(SELECT assurance_label
 FROM   UDM.udm_ref_assurance
 WHERE  id = src.ASSURANCE_CD AND ROWNUM = 1)
```

Oracle executes this once per source row. With 50k rows and three `lookup:` columns that is 150k single-row index fetches — each with its own parse, execute and fetch overhead.

### Fix

`lookup:` targets are moved to the FROM clause as `LEFT JOIN`s. The SELECT list emits a plain column reference instead of a subquery.

```sql
-- FROM clause (built by p_collect_lookup_joins)
LEFT JOIN UDM.udm_ref_assurance lkp_1
  ON lkp_1.assurance_code = src.ASSURANCE_CD

-- SELECT list (built by p_build_columnar_insert_sql pass 2)
lkp_1.assurance_label
```

Oracle executes the join once across all rows using a hash or nested-loop join.

### Why LEFT JOIN, not INNER JOIN

An INNER JOIN would silently drop any source row whose lookup value has no match in the reference table — the row disappears with no quarantine entry. A LEFT JOIN returns NULL for the unmatched column. The DI framework's COMPLETENESS check then surfaces it in `udm_dq_results` and the data owner decides whether to enrich the reference table or reject the value. Silent data loss is a worse outcome than a NULL in a non-mandatory column.

### New functions

`p_collect_lookup_joins(p_attrs, p_join_sql OUT, p_alias_map OUT)` — pass 1. Iterates the attribute map, extracts all `lookup:` rules, deduplicates by target table (one `LEFT JOIN` per unique table regardless of how many attributes reference it), assigns aliases (`lkp_1`, `lkp_2`, …), and returns the JOIN SQL fragment and a parallel alias map array.

`p_parse_lookup_rule(p_rule, p_schema OUT, p_table OUT, p_join_col OUT, p_return_col OUT)` — parses the transform_rule string into its components.

`p_build_columnar_insert_sql` and `p_build_eav_insert_sql` — both updated to two-pass. Pass 1 calls `p_collect_lookup_joins`. Pass 2 builds the SELECT list, reading `alias_map(i)` for `lookup:` attributes and calling `p_build_transform_expr` for all others.

### Syntax change to `attribute_map.transform_rule`

The `lookup:` rule now accepts a four-segment form with an explicit join column in the reference table. The three-segment form remains valid for backward compatibility (join column defaults to `id`).

| Form | Example | Join condition |
|---|---|---|
| `lookup:schema.table.return_col` *(3-segment, backward compatible)* | `lookup:UDM.udm_ref_assurance.assurance_label` | `lkp_N.id = src.source_col` |
| `lookup:schema.table.join_col.return_col` *(4-segment, preferred)* | `lookup:UDM.udm_ref_assurance.assurance_code.assurance_label` | `lkp_N.assurance_code = src.source_col` |

New catalog entries should use the 4-segment form. Existing 3-segment entries do not need to be migrated unless the reference table does not have an `id` column.

---

## Transform Rules Reference

| Pattern | Example | Behaviour | SQL emitted |
|---|---|---|---|
| `direct` | `direct` | Copy value as-is | `src.col` |
| `multiply:N` | `multiply:1000` | Multiply by constant | `src.col * 1000` |
| `divide:canon` | `divide:revenue_musd` | Divide by another column's value; NULL if divisor is zero | `CASE WHEN NVL(src.div_col,0)=0 THEN NULL ELSE src.col/src.div_col END` |
| `coalesce:a,b` | `coalesce:scope3_upstream_mtco2` | First non-null value across primary + fallback columns | `COALESCE(src.col, src.fallback_col)` |
| `flag:a,b` | `flag:scope1_mtco2,scope3_upstream_mtco2` | Writes `DIRECT` if primary column non-null, else `ESTIMATED` | `CASE WHEN src.primary IS NOT NULL THEN 'DIRECT' ELSE 'ESTIMATED' END` |
| `lookup:s.t.jc.rc` | `lookup:UDM.udm_ref_assurance.assurance_code.assurance_label` | Reference table lookup via LEFT JOIN in FROM clause; NULL if no match | `lkp_N.return_col` (JOIN built by `p_collect_lookup_joins`) |
| `rule_ref:NAME` | `rule_ref:CURRENCY_CONVERT` | Executes `resolution_sql` from `udm_transform_rules`; supports `{vendor_value}` and `{vendor_id}` placeholders | `(resolution_sql with placeholders substituted)` |

---

## Arbitration Engine — How Winning Vendor Is Selected

For each entity × coverage_period × metric column:

1. Walk `udm_precedence_rules` in priority order (1 = highest, NULL metric_group = applies to all)
2. Skip vendors whose `alignment_method = EXCLUDE` (grain mismatch)
3. Apply grain alignment for non-canonical grain vendors:
   - `DIRECT` — use stack row as-is
   - `LAST_VALUE` / `FIRST_VALUE` — windowed row pick within period
   - `AVERAGE` / `SUM` — aggregate (SUM joins via `udm_entity_membership`)
   - `DISAGGREGATE` — custom SQL from `udm_grain_alignment_rules.resolution_sql`
4. Take first vendor with a non-null value that satisfies `condition_sql` (if CONDITIONAL rule)
5. Write to `udm_{domain}_arb` via MERGE (UPSERT)

---

## DI Framework — Check Inventory

### Tier A — Auto-derived (no `udm_dq_rules` entry needed)

| Check | Trigger | Action |
|---|---|---|
| `NOT_NULL` | `is_mandatory = 'Y'` in attribute_map | ALERT (count of nulls) |
| `DATA_TYPE` | `data_type IN ('NUMBER','DATE')` | ALERT (count of cast failures) |

### Tier B — Threshold-driven (`udm_dq_rules` entry required)

| Check | Logic | Configured via |
|---|---|---|
| `BOUNDS` | Value outside `[min_value, max_value]` | `udm_dq_rules.min_value / max_value` |
| `DRIFT` | Avg value drifts > threshold% from prior period | `udm_dq_rules.threshold` |
| `COMPLETENESS` | Non-null rate below threshold% | `udm_dq_rules.threshold` |

All results written to `udm_dq_results`. External DQ tool consumes this table for alerting and dashboards.

---

## Scheduler Pipeline Flow

```
Manifest COMPLETE
  → udm_job_manifest_watcher (every 15 min)
      → fires udm_pkg_harmonisation.run_domain   (IDENTITY_SOURCE first, then DATA_SOURCE)
          → udm_pkg_di.run_domain_checks          (after harmonisation completes)
              → udm_pkg_arbitration.run_domain     (after all sources for domain loaded)

Nightly fallback jobs (safety net):
  02:00  udm_job_nightly_arbitration
  03:00  udm_job_nightly_di
```

---

## Known Extension Points

| Area | What to add |
|---|---|
| New domain | Create `udm_{domain}_stk` and `udm_{domain}_arb` DDL. Register sources in `udm_source_registry`. Insert attribute mappings in `udm_attribute_map`. Insert precedence rules. Engine requires no code change. |
| New transform | Add row to `udm_transform_rules` with `rule_name` and `resolution_sql`. Reference as `rule_ref:RULE_NAME` in attribute_map. No code deployment. |
| New lookup target | Add `lookup:schema.table.join_col.return_col` in `attribute_map.transform_rule`. Engine builds the LEFT JOIN at runtime from the catalog entry. No code deployment. |
| New DQ threshold | INSERT into `udm_dq_rules`. Active immediately on next DI run. No code deployment. |
| CROSS_VENDOR check | Add to `udm_dq_rules.check_type = CROSS_VENDOR`. Implement handler in `udm_pkg_di` `p_run_cross_vendor_checks` (stub — not yet in Module 8). |
| Detection layer | Module 2 (Tier 2 DDL) and Module 3/4/5 (structural + EAV detection) — next sprint. |

---

## Change Log

| Version | File | Change | Reason |
|---|---|---|---|
| v1 | `udm_mod06_harmonisation.sql` | Initial version | Baseline |
| v2 | `udm_mod06_harmonisation_v2.sql` | Removed `coverage_period` from `run_source`. Engine discovers pending manifest internally via `p_find_pending_manifest`. Period stamped on stack rows read from source `time_col`. | Engine should process current data via `currency_mechanism`, not filter by a caller-supplied period. |
| v2 | `udm_mod06_harmonisation_v2.sql` | All transforms moved into SQL SELECT expressions (`p_build_transform_expr`). Single `INSERT /*+ APPEND */ INTO … SELECT` per source. | Eliminated row-by-row PL/SQL transform loop. |
| v2 | `udm_mod06_harmonisation_v2.sql` | Entity resolution via JOIN in FROM clause. Quarantine via `INSERT … SELECT NOT EXISTS`. | Eliminated per-row `p_resolve_entity` PL/SQL calls. |
| v2 | `udm_mod06_harmonisation_v2.sql` | COMPANY_SECTOR pre-pass uses `FORALL INSERT` (3 statements). Sequence values pre-generated in bulk via `CONNECT BY`. | Eliminated per-entity autonomous transaction loop. |
| v2 | `udm_mod06_harmonisation_v2.sql` | IDENTITY_SOURCE uses `BULK COLLECT` + two `FORALL INSERT` statements. | Eliminated row-by-row identity creation loop. |
| patch | `udm_mod06_patch_lookup_join.sql` | `lookup:` transform moved from correlated scalar subquery in SELECT to `LEFT JOIN` in FROM clause. New functions: `p_parse_lookup_rule`, `p_collect_lookup_joins`. Both INSERT builders updated to two-pass. Four-segment `lookup:` syntax added; three-segment retained for backward compatibility. | Correlated scalar subquery executes once per source row (N × M index fetches). LEFT JOIN executes once across all rows. LEFT JOIN chosen over INNER JOIN to avoid silent data loss on unmatched reference values. |
