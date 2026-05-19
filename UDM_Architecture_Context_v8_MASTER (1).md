# UDM Platform — Master Architecture Context Document
**Version:** v8 | **Date:** May 2026 | **Status:** Authoritative

This document is the sole context-setter for all future sessions on the UDM platform.
It is written as a standalone architectural record. A reader with no prior context
should be able to understand the full platform from this document alone.

---

## Table of Contents

1. Architecture Overview
2. Harmonisation Layer — Processing Logic
3. Entity Registry
4. DDL Specifications
5. Process-Level Lineage
6. DI Performance Considerations
7. RDM As-Of-Date Request Pattern
8. Open Items and Decisions Deferred
9. Glossary

---

# 1. Architecture Overview

## 1.1 Business Mandate

The business has mandated a single governed platform for all data entering the system — regardless of source (vendor, internal, re-provisioned). The platform must be able to answer for any metric, from any source: what it is, where it came from, when it arrived, and whether it passed integrity checks. The key architectural quality is: one governed version of the truth per entity per period, produced deterministically from a catalogued ruleset.

## 1.2 Strategic State

Two options are in play. Option A is the current live state. Option B is the target.

**Option A — Selective UDM (current live state)**

Arbitrated attributes only flow through UDM. Non-arbitrated objects continue through the existing RDM pipeline. Option A is forward-compatible with Option B by design — migration is organic, domain by domain.

```
PATH 1 — Non-arbitrated objects:
  Staging → RDM → Distribution → Downstream

PATH 2 — Arbitrated attributes:
  Staging → RDM → EAV Federated → EAV Standardized → UDM (Arbitrated) → Distribution → Downstream
```

Known tensions in Option A: tribal knowledge of which system holds which attribute; triple EAV storage of every fact value; DI at object level only; precedence rules hardcoded in stored procedure.

**Option B — Full UDM (target)**

All data flows through the UDM pipeline. RDM becomes a registered source. Wide columnar stack replaces EAV throughout the processing layer.

```
Staging (permanent — raw source preserved)
  → udm_{domain}_stk   (vendor stack — wide columnar per domain)
  → udm_{domain}_arb   (arbitration golden copy — wide columnar per domain)
  → Distribution Layer
  → Downstream
```

## 1.3 End-to-End Platform Architecture

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  SOURCES                                                                     ║
║  ┌────────────┐  ┌────────────┐  ┌─────────────────┐                        ║
║  │  Vendor A  │  │  Vendor B  │  │ Internal Systems │                        ║
║  │ (COLUMNAR) │  │   (EAV)    │  │   CST_DIM / RDM  │                        ║
║  └─────┬──────┘  └─────┬──────┘  └────────┬────────┘                        ║
╚════════╪═══════════════╪═════════════════╪═════════════════════════════════╝
         │               │                 │
╔════════╪═══════════════╪═════════════════╪═════════════════════════════════╗
║  ENTITY & REFERENCE LAYER                                                    ║
║  ┌─────────────────────────────────────────────────────────────────────┐     ║
║  │  udm_company_xref  (vendor external_id → entity_key)                │     ║
║  │  udm_entity_registry  (INTERNAL | VENDOR_ONLY | MERGED)             │     ║
║  │  udm_entity_membership  (hierarchy — COMPANY_COMPONENT etc.)        │     ║
║  │  udm_ref_company / sector / region / country / time  (natural keys) │     ║
║  └─────────────────────────────────────────────────────────────────────┘     ║
╚══════════════════════════════════════════════════════════════════════════════╝
         │
╔════════╪═══════════════════════════════════════════════════════════════════╗
║  CATALOG LAYER  (engine reads — config-driven behaviour)                    ║
║  ┌────────────────────┐  ┌───────────────────────┐  ┌────────────────────┐  ║
║  │  udm_source_system │  │  udm_source_registry  │  │  udm_data_item     │  ║
║  │  udm_transform_    │  │  udm_data_item_       │  │  udm_data_item_    │  ║
║  │  rules             │  │  taxonomy             │  │  src_map           │  ║
║  │  udm_precedence_   │  │  udm_grain_alignment_ │  │  udm_dq_rules      │  ║
║  │  rules             │  │  rules                │  │                    │  ║
║  └────────────────────┘  └───────────────────────┘  └────────────────────┘  ║
╚══════════════════════════════════════════════════════════════════════════════╝
         │
╔════════╪═══════════════════════════════════════════════════════════════════╗
║  HARMONISATION ENGINE  (udm_hrm_engine PL/SQL package)                      ║
║                                                                             ║
║  Step 1: Entity resolution (xref lookup → entity_key)                      ║
║  Step 2: Pass 1 — physical source attributes → constituent columns          ║
║  Step 3: Pass 2 — derived canonical data items                              ║
║  Step 4: Unit conversion, grain alignment                                   ║
║  Output: udm_{domain}_stk  (bi-temporal wide columnar)                     ║
╚══════════════════════════════════════════════════════════════════════════════╝
         │
╔════════╪═══════════════════════════════════════════════════════════════════╗
║  ARBITRATION ENGINE  (udm_arb_engine PL/SQL package)                        ║
║                                                                             ║
║  Step 1: Fetch all qualified candidates (GTT — one INSERT…SELECT)           ║
║  Step 2: Rank by ROW_NUMBER() OVER (PARTITION BY entity ORDER BY priority)  ║
║  Step 3: MERGE golden copy to udm_{domain}_arb                             ║
║  Step 4: Queue unresolved to udm_arb_review_queue                          ║
║  Output: udm_{domain}_arb  (one governed value per entity per period)      ║
╚══════════════════════════════════════════════════════════════════════════════╝
         │
╔════════╪═══════════════════════════════════════════════════════════════════╗
║  CONSUMER LAYER                                                             ║
║  ┌──────────────────────────────────────────────────────────────────┐       ║
║  │  udm_{domain}_v  (reporting views — UNION ALL from taxonomy)     │       ║
║  │  udm_stk_current_v  (convenience — current stack rows only)      │       ║
║  │  RDM synonym swap views  (backward compatibility on cutover)     │       ║
║  └──────────────────────────────────────────────────────────────────┘       ║
╚══════════════════════════════════════════════════════════════════════════════╝
         │
╔════════╪═══════════════════════════════════════════════════════════════════╗
║  PIPELINE / LINEAGE                                                         ║
║  udm_process_run → udm_delivery_manifest → udm_lineage (steps 1–5)         ║
║  → udm_quarantine / udm_dq_results / udm_detection_suppressions             ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

## 1.4 Core Architectural Principles

These principles govern every design decision. They are non-negotiable.

**Set-based over procedural.** All engine processing is expressed as SQL. No entity-by-entity loops. Every operation that could be done in a cursor loop must be rewritten as a bulk INSERT…SELECT, MERGE, or analytic function.

**Catalog-driven behaviour.** Engine behaviour is determined by reading tables — not by code branches. Adding a new vendor, a new precedence rule, or a new waterfall fallback level is an INSERT, not a code change.

**Single physical home per metric.** Every data item lives in exactly one stack table (`phy_trgt_tbl_nm`). Reporting views for multiple sub-domains are generated from the taxonomy as UNION ALL — the metric is never duplicated across physical tables.

**Entity_key is the only identity on fact tables.** Vendor raw IDs, source keys, and CST_IDs never appear on stack or arb tables. All identity resolution happens before the fact row is written.

**Nothing is ever hard-deleted.** All lifecycle transitions are status changes. Superseded rows, merged entities, closed xref entries, and old arb results are retained for audit.

**Self-contained deliverables.** Developer specifications, DDL files, and context documents must be fully buildable without referencing external files. No filename references in specifications.

**Status:** ✅ Decided

---

# 2. Harmonisation Layer — Processing Logic

## 2.1 Source Format Handling

Sources arrive in two formats, registered on `udm_source_registry.source_format`:

**COLUMNAR** — standard relational table. One row per entity per period. Attributes are columns. Engine reads them by column name from `udm_data_item_src_map.attr_src_nm`.

**EAV (Entity-Attribute-Value)** — one row per attribute value. Engine reads the attribute name column (`attr_nm_col_tx`), matches the expected value (`attr_nm_val_tx`), and reads the value column (`attr_val_col_tx`). Unit is in a sibling row identified by `attr_unit_eav_ky`.

The Federated layer holds source-as-is EAV data. The Standardised layer functions as the domain stack — wide columnar, one row per entity per period per vendor. EAV is never written to the domain stack. The harmonisation engine is responsible for the EAV-to-columnar transformation.

## 2.2 Two-Pass Processing

The harmonisation engine processes each source row in two ordered passes driven by `udm_data_item_src_map.is_derived_fl`:

**Pass 1 — Physical source attributes (is_derived_fl = N)**
Reads source columns and writes constituent columns to the stack. Unit conversion is applied at this stage. For the Scope 1 example:
- `scope1_direct` ← physical source column for the direct measurement value
- `scope1_estimated` ← physical source column for the estimated value
- Unit conversion: `attr_unit_from_tx = 'col:SCOPE1_UNIT'` reads unit from the source row; engine converts to canonical unit `data_itm_trgt_unit_tx = 'mtCO2'`

**Pass 2 — Derived canonical data items (is_derived_fl = Y)**
Computes derived values from Pass 1 columns already in scope. No source column is read. For the Scope 1 example:
- `scope1_mtco2` ← `coalesce:scope1_direct,scope1_estimated` (first non-null wins)
- `scope1_source_flag` ← `flag:scope1_direct,scope1_estimated` (writes DIRECT or ESTIMATED)

## 2.3 Transform Rule Patterns

All transforms are declared in `udm_data_item_src_map.attr_xfrm_ru_tx`:

| Pattern | Meaning | Example |
|---|---|---|
| `direct` | Copy value as-is | Direct copy of source column |
| `lookup:sch.tbl.col` | Resolve via lookup table | Translate sector code to canonical code |
| `multiply:N` | Multiply by constant | Convert tonnes to metric tonnes |
| `divide:col_name` | Divide by another resolved column | Intensity calculation |
| `coalesce:col1,col2` | First non-null wins | Preferred value with fallback |
| `flag:col1,col2` | Write DIRECT or ESTIMATED | Source flag for coalesced column |
| `rule_ref:RULE_NAME` | Complex SQL in `udm_transform_rules` | Multi-step lookup |
| `derive_cs:col1,col2` | COMPANY_SECTOR composite key derivation | Grid aggregation |

Complex SQL patterns reference `udm_transform_rules` by name. A rule change is one UPDATE on `udm_transform_rules` — no code deployment required.

## 2.4 Unit Conversion

Unit conversion is engine metadata only. Unit values never appear in domain tables.

Three patterns declared on `udm_data_item_src_map`:

```
attr_unit_from_tx = 'tCO2'          Static constant applied to all rows
attr_unit_from_tx = 'col:UNIT_COL'  Read unit from named source column (COLUMNAR only)
attr_unit_eav_ky  = 'SCOPE1_UNIT'   EAV sibling row: attribute_name_value = 'SCOPE1_UNIT'
```

`attr_unit_from_tx` and `attr_unit_eav_ky` are mutually exclusive. The canonical unit after conversion is declared on `udm_data_item.data_itm_trgt_unit_tx` — it is an implicit contract on all rows in `phy_trgt_tbl_nm`.

## 2.5 Golden Copy Resolution — Arbitration Waterfall

The arbitration engine resolves a golden copy per entity per metric using a cascading fallback waterfall declared in `udm_precedence_rules`. Three precedence modes are supported and can coexist within the same domain.

**Mode 1 — Simple vendor precedence (defaults)**
Same entity, same period, multiple vendors. Vendor with lower priority number wins.

**Mode 2 — Metric group override**
Some metrics need different vendor priority than the domain default. Group rules have lower priority numbers than domain-level rules for the same vendor position. The ROW_NUMBER analytic picks the group rule first with no special engine branching.

**Mode 3 — Entity scope / time fallback**
The waterfall can fall back to the entity's parent or to the prior year when no qualifying current-period client-level value exists.

| Column | Values | Meaning |
|---|---|---|
| `entity_scope` | CLIENT (default) | Use the entity being arbitrated |
| | PARENT | Use entity's parent from `udm_entity_membership` — skipped when no parent exists |
| `period_scope` | CURRENT (default) | Use the target coverage period |
| | PRIOR_YEAR | Use ADD_MONTHS(target, -12) via `udm_ref_time` — skipped when absent |

**Eight-level waterfall example (Scope 1 Emissions):**

```
Priority  entity_scope  period_scope  vendor   rule_label
1         CLIENT        CURRENT       VND_A    Level 1 — Client / Current / Vendor A
2         CLIENT        CURRENT       VND_B    Level 2 — Client / Current / Vendor B
3         PARENT        CURRENT       VND_A    Level 3 — Parent / Current / Vendor A
4         PARENT        CURRENT       VND_B    Level 4 — Parent / Current / Vendor B
5         CLIENT        PRIOR_YEAR    VND_A    Level 5 — Client / Prior Year / Vendor A
6         CLIENT        PRIOR_YEAR    VND_B    Level 6 — Client / Prior Year / Vendor B
7         PARENT        PRIOR_YEAR    VND_A    Level 7 — Parent / Prior Year / Vendor A
8         PARENT        PRIOR_YEAR    VND_B    Level 8 — Parent / Prior Year / Vendor B
9         (none)        (none)        —        UNRESLVD — queued for PO review
```

Adding a new fallback level is a single INSERT into `udm_precedence_rules` — no code change.

The `rule_label` from the winning rule is stamped directly on the arb row metadata column (`scope1_arb_lvl_tx`). Consumers can read the exact waterfall level without joining back to rules.

`CARRIED_FWD` is distinct from `RESOLVED` in `scope1_arb_stat_cd` — it flags that a prior-year value was used, allowing consumers and POs to distinguish current-period values from time-fallback values.

## 2.6 Arbitration Engine — Set-Based Architecture

The engine (`udm_arb_engine` PL/SQL package) performs all processing in four set-based steps with no entity-by-entity loops.

```
STEP 0  Two scalar lookups only (not loops):
        get_prior_period()   — one ref_time ADD_MONTHS(-12) join
        bounds threshold     — one dq_rules lookup

STEP 1  step_fetch_candidates()
        One INSERT…SELECT into udm_arb_candidates_gtt.
        Fetches ALL candidates for ALL entities in one pass.
        Quality gate applied inline — failing rows excluded at fetch.
        PARENT guard: WHERE clause excludes PARENT rules when no parent.
        PRIOR_YEAR guard: stk JOIN returns no rows when prior period NULL.
        Quarantine exclusion via NOT EXISTS on idx_qrn_lineage_entity.

STEP 2  step_rank_and_resolve()
        One INSERT…SELECT with ROW_NUMBER() into udm_arb_resolved_gtt.
        ROW_NUMBER OVER (PARTITION BY entity, metric ORDER BY priority ASC).
        UNRESLVD rows produced via LEFT JOIN anti-pattern for entities
        with no qualifying candidates.

STEP 3  step_merge_to_arb()
        Single MERGE into udm_{domain}_arb.
        Handles first run (INSERT branch) and re-runs (UPDATE branch).

STEP 4  step_queue_unresolved()
        Single MERGE into udm_arb_review_queue.
        UNIQUE constraint on (entity_key, coverage_period, data_itm_scd_1_ky)
        means re-runs update existing PENDING items — no duplicates.
```

## 2.7 Quality Gate

A candidate row is included in the GTT only if ALL of the following hold:

1. Row exists in stack for (entity_key, coverage_period, vendor_id)
2. Metric value IS NOT NULL
3. Metric value >= 0 (negative Scope 1 is invalid without explicit exception)
4. Metric value <= bounds threshold from `udm_dq_rules` (check_type=BOUNDS)
5. No open quarantine entry (NOT EXISTS on quarantine)
6. `cur_fl = 1` (current UDM version)
7. `src_end_tran_dt = DATE '9999-12-31'` (currently active source version)

DQ score: 100 = clean, 80 = within 10% of bounds limit, 0 = excluded.

## 2.8 Wide Columnar vs EAV — Which Layer Uses Which

| Layer | Format | Rationale |
|---|---|---|
| Federated | EAV | Preserves source-as-is without schema commitment |
| Standardised (domain stack) | Wide columnar | One metric = one named typed column. Query performance, type safety, no EAV pivot overhead |
| Arbitration (arb table) | Wide columnar | Same schema as stack. Per-metric metadata columns sit alongside metric value |
| Reference tables | Columnar | Standard relational — no EAV needed |
| Reporting views | Columnar (UNION ALL) | Generated from taxonomy — no EAV |

EAV is an ingestion-layer format only. It never propagates beyond the harmonisation step.

## 2.9 Data Quality Gates and Quarantine Handling

Two categories of DQ check:

**Auto-derived checks** — generated at engine runtime from `udm_data_item` + `udm_data_item_src_map`. No row in `udm_dq_rules` required.

| Check | Source |
|---|---|
| DATA_TYPE | Derived from `data_itm.data_typ_cd` — engine casts and validates |
| NOT_NULL | Derived from `data_itm.is_mndty_fl = 'Y'` |
| UNMAPPED_ATTRIBUTE | Source attribute not in `udm_data_item_src_map` |
| REFERENTIAL | Entity ID not resolvable via xref — triggers VENDOR_ONLY creation, not quarantine |

**Configured checks** — declared in `udm_dq_rules`. Threshold-dependent.

| check_type | Meaning |
|---|---|
| BOUNDS | min_value ≤ value ≤ max_value |
| DRIFT | % change from prior period exceeds threshold |
| COMPLETENESS | Required metric missing for entity × period |
| CROSS_VENDOR | Vendor A and Vendor B diverge beyond threshold (pre-arb check) |

`ENTITY_NOT_FOUND` has been **removed** from quarantine check_type. The engine now creates a `VENDOR_ONLY` entity rather than quarantining the row. Data is never lost due to missing xref.

Unresolved arbitration cases (all waterfall levels exhausted) go to `udm_arb_review_queue` — not to quarantine. The review queue carries `parent_entity_key` and `prior_period` even when they are structurally absent (NULL = absent, populated = present but had no qualifying data). This distinction matters for the PO's diagnosis.

**Status:** ✅ Decided

---

# 3. Entity Registry

## 3.1 Role in the Platform

`udm_entity_registry` is the identity authority. It holds one row per governed business entity — company, sector, region, country, supplier, counterparty, product, or composite COMPANY_SECTOR. It carries identity only — no metrics, no vendor attributes.

Every stack and arb table row carries exactly one `entity_key`. All identity resolution happens before the fact row is written. Vendor raw IDs never appear on stack or arb tables.

## 3.2 Entity Key Generation

```
Sequence:  udm_entity_seq   starts at 1,000,000
Format:    'ENT-' || LPAD(seq.NEXTVAL, 7, '0')
Example:   ENT-1000001
```

Starting at 1,000,000 avoids collision with source PKs such as CST_ID, which may be numeric integers in the same range as low sequence values.

## 3.3 Three Entity Lifecycle States

`match_status` on `udm_entity_registry` has three values:

**INTERNAL** — seeded from internal systems (CST_DIM, RDM). This is an entity the organisation knows about natively. Has or may have CONFIRMED xref mappings to vendor external IDs. `source_key` carries the original source PK (e.g. CST_ID).

**VENDOR_ONLY** — created by the harmonisation engine when a vendor sends an entity ID that has no existing xref entry. Gets its own governed `entity_key`. `vendor_id` records which vendor first reported it. May be linked to an INTERNAL entity later when MDM confirms the mapping (→ MERGED). May remain VENDOR_ONLY permanently for entities the organisation does not track internally (e.g. public companies in a climate data vendor's universe).

**MERGED** — was VENDOR_ONLY. MDM has confirmed it maps to an INTERNAL entity. `merged_into_key` points to the surviving INTERNAL entity_key. `is_active = N`. Retained for audit trail only. Stack and arb rows are reprocessed to the surviving entity_key.

## 3.4 Company Cross-Reference Lifecycle

`udm_company_xref` maps vendor external IDs to entity_keys. Three `match_status` values:

**CONFIRMED** — MDM validated. May point to INTERNAL or VENDOR_ONLY entity_key. Created by the MDM process, not by the engine.

**ENGINE** — auto-created by the harmonisation engine when a vendor sends an unknown entity ID. Points to a newly-created VENDOR_ONLY entity_key. Upgraded to CONFIRMED when MDM validates. Closed (SUPERSEDED) when MDM redirects to a different entity_key.

**SUPERSEDED** — closed entry. `effective_to` is set. Retained for audit. Never deleted.

Engine xref lookup sequence at ingest time:

```sql
-- Step 1: look for active xref
SELECT entity_key
FROM   udm_company_xref
WHERE  vendor_id    = :v_vendor
AND    external_id  = :v_external_id
AND    match_status IN ('CONFIRMED','ENGINE')
AND    effective_to IS NULL;

-- FOUND → use entity_key → write stack row

-- NOT FOUND → Step 2: create VENDOR_ONLY entity
INSERT INTO udm_entity_registry (match_status='VENDOR_ONLY', vendor_id=:v_vendor, ...)
INSERT INTO udm_company_xref    (match_status='ENGINE', entity_key=new_key, ...)
-- use new entity_key → write stack row
```

## 3.5 Two Vendors, Same Unknown Entity

When Vendor A sends VA-8821 and Vendor B sends VB-0042 for the same real-world company, and neither has an xref entry:

- Engine creates `ENT-2000001` (VENDOR_ONLY, Vendor A) and ENGINE xref for VA-8821
- Engine creates `ENT-2000002` (VENDOR_ONLY, Vendor B) and ENGINE xref for VB-0042
- Both get their own stack rows and arb rows. Each arbitration runs with a single vendor only.
- This is correct — the engine cannot confirm they are the same company.

When MDM later confirms both map to internal entity ENT-1000001:

1. SUPERSEDE ENGINE xref entries for VA-8821 and VB-0042
2. INSERT CONFIRMED xref entries → ENT-1000001 for both vendor IDs
3. UPDATE `entity_registry` for ENT-2000001 and ENT-2000002: `match_status=MERGED`, `merged_into_key=ENT-1000001`, `is_active=N`
4. UPDATE stack rows: `entity_key = ENT-1000001` for all rows previously filed under VENDOR_ONLY keys
5. Re-run arbitration for ENT-1000001 — now sees both Vendor A and Vendor B data and applies the waterfall correctly

## 3.6 Reference Tables — Natural Key Pattern

All `udm_ref_*` tables carry natural keys only. There is no entity_key FK on any reference table. The join is always:

```sql
entity_registry.source_key = udm_ref_company.company_source_key
entity_registry.source_key = udm_ref_sector.class_code
```

Reference table governance remains with the source system until a formal decision transfers it to UDM. This independence is intentional — entity_registry and reference tables are decoupled and can evolve separately.

## 3.7 Parent-Child Hierarchy

`udm_entity_membership` records composite entity relationships. It has three uses:

1. **Grain alignment** — SUM reads COMPANY_COMPONENT rows to roll COMPANY_SECTOR up to COMPANY grain before arbitration.
2. **Arbitration PARENT scope** — the engine reads COMPANY_COMPONENT to find `parent_entity_key` for PARENT-scope precedence rules.
3. **BI enrichment** — SECTOR_MEMBERSHIP and REGION_MEMBERSHIP traversal for hierarchy-aware reporting.

Two rows are created for each COMPANY_SECTOR entity: one COMPANY_COMPONENT (child = COMPANY_SECTOR, parent = COMPANY) and one SECTOR_COMPONENT (child = COMPANY_SECTOR, parent = SECTOR).

Migration of existing `CST_PTFOL_REF` → `udm_entity_membership` as `SECTOR_MEMBERSHIP` rows.

## 3.8 Existing Source Objects — Migration Mapping

| Existing Object | UDM Target | Notes |
|---|---|---|
| INTERNAL CUSTOMER REF (CST_ID) | `udm_entity_registry` source_key=CST_ID + `udm_ref_company` company_source_key=CST_ID | Seed from CST_DIM full history |
| INTERNAL_SECTOR_REF (PTFOL_ID) | `udm_entity_registry` source_key=PTFOL_ID + `udm_ref_sector` class_code=PTFOL_ID | Seed from portfolio reference |
| CST_XREF | `udm_company_xref` match_status=CONFIRMED | Direct migration — same concept |
| CST_PTFOL_REF | `udm_entity_membership` SECTOR_MEMBERSHIP | Direct migration |
| Vendor A unmatched rows | `udm_entity_registry` VENDOR_ONLY + ENGINE xref | Net-new from vendor data |
| Vendor B unmatched rows | Same | Net-new from vendor data |

Execution order is mandatory: entity_registry must be seeded before xref migration (FK dependency), and xref migration must complete before the first vendor DATA_SOURCE fact load.

**Status:** ✅ Decided

---

# 4. DDL Specifications

## 4.1 Authoritative DDL File

File: `udm_tier1_v8_complete.sql`

Contains: 35 tables, 33 sequences, 3 views. This is the complete Tier 1 schema. No amendments file exists — every change produces a new complete consolidated file with a bumped version number.

## 4.2 Table Inventory

### CATALOG GROUP (01–09)

| Table | Key Columns | Notes |
|---|---|---|
| `udm_source_system` | PK: `source_system_cd` | Seeded from DW.src_sys_dim. vendor_id throughout FKs. |
| `udm_source_registry` | PK: `source_id` | Front door. `currency_mechanism` declares how engine reads currency. |
| `udm_data_item` | PK: `data_itm_scd_2_ky` UK: `data_itm_scd_1_ky` UK: `data_itm_id` | SCD2. `phy_trgt_tbl_nm` = ONE stack table. `mtrc_grp_tx` links to precedence group overrides. |
| `udm_data_item_taxonomy` | PK: `taxonomy_id` LK: `data_itm_scd_1_ky` | Drives reporting VIEW generation. Multiple SUB_DOMAIN rows per overlapping metric. |
| `udm_data_item_src_map` | PK: `map_id` LK: `data_itm_scd_1_ky` FK: `source_id` | Pass 1 (N) then Pass 2 (Y). Unit columns mutually exclusive. |
| `udm_transform_rules` | PK: `rule_id` UK: `rule_name` | Complex SQL referenced by `rule_ref:RULE_NAME`. |
| `udm_precedence_rules` | PK: `rule_id` | entity_scope + period_scope + rule_label. NEVER DELETE. |
| `udm_grain_alignment_rules` | PK: `alignment_id` | SUM reads entity_membership. EXCLUDE = stack-only. |
| `udm_dq_rules` | PK: `rule_id` | Threshold checks only. Auto-derived at engine runtime. |

### ENTITY RESOLUTION GROUP (10–13)

| Table | Key Columns | Notes |
|---|---|---|
| `udm_entity_registry` | PK: `entity_key` FK(self): `merged_into_key` | match_status: INTERNAL / VENDOR_ONLY / MERGED. seq from 1,000,000. |
| `udm_company_xref` | PK: `xref_id` FK: `entity_key` FK: `vendor_id` | match_status: CONFIRMED / ENGINE / SUPERSEDED. Hot path index on (vendor_id, external_id, effective_to). |
| `udm_entity_membership` | PK: `membership_id` FK: `entity_key` FK: `parent_entity_key` | relationship_type: COMPANY_COMPONENT / SECTOR_COMPONENT / SECTOR_MEMBERSHIP / REGION_MEMBERSHIP. |
| `udm_spatial_asset_registry` | PK: `spatial_asset_key` | 40M+ assets. geohash prefix for regional filter. |

### REFERENCE GROUP (15–22) — all natural keys, no entity_key FK

### PIPELINE GROUP (23–28)

| Table | Key Columns | Notes |
|---|---|---|
| `udm_process_run` | PK: `process_run_id` | Parent record. All pipeline objects FK here. |
| `udm_delivery_manifest` | PK: `manifest_id` FK: `process_run_id` FK: `source_id` | Step 1. Gates load on COMPLETE. |
| `udm_lineage` | PK: `lineage_id` FK: `process_run_id` | `step_sequence` 1–5. Partitioned monthly. |
| `udm_quarantine` | PK: `quarantine_id` FK: `lineage_id` | ENTITY_NOT_FOUND removed. idx_qrn_lineage_entity for arb exclusion. |
| `udm_dq_results` | PK: `result_id` FK: `lineage_id` | Partitioned monthly. |
| `udm_detection_suppressions` | PK: `suppression_id` | Negative PO decisions via release pipeline. |

### ARBITRATION SUPPORT (29)

| Table | Key Columns | Notes |
|---|---|---|
| `udm_arb_review_queue` | PK: `review_id` UNIQUE: (entity_key, coverage_period, data_itm_scd_1_ky) | MERGE on re-run — no duplicates. parent_entity_key NULL = structurally absent. |

### GTTs (33–34)

| Table | Notes |
|---|---|
| `udm_arb_candidates_gtt` | ON COMMIT DELETE ROWS. Populated by step_fetch_candidates(). |
| `udm_arb_resolved_gtt` | ON COMMIT DELETE ROWS. One winner per entity per metric. |

## 4.3 Domain Stack Table DDL — Bi-temporal Design

Domain stack tables are created at domain onboarding. They are not in Tier 1. The template DDL is:

```sql
CREATE TABLE udm_{sub_domain}_stk (

    -- Identity
    entity_key          VARCHAR2(20)    NOT NULL,   -- → udm_entity_registry
    source_id           VARCHAR2(20)    NOT NULL,   -- → udm_source_registry
    coverage_period     VARCHAR2(20)    NOT NULL,   -- business reporting period

    -- SOURCE TRANSACTION TIME (from the source system — NEVER changes after INSERT)
    src_bgn_tran_dt     DATE            NOT NULL,
    src_end_tran_dt     DATE            NOT NULL,
    -- For SCD2 sources: carry rdm.bgn_tran_dt / rdm.end_tran_dt exactly
    -- For SNAPSHOT sources: snapshot_date / LEAD(next_snapshot) - 1

    -- UDM TRANSACTION TIME (UDM's own version tracking)
    bgn_tran_dt         DATE            NOT NULL,   -- SYSDATE at INSERT
    end_tran_dt         DATE            DEFAULT DATE '9999-12-31' NOT NULL,
    cur_fl              NUMBER(1)       DEFAULT 1 NOT NULL,

    -- Load audit
    load_dt             DATE            NOT NULL,   -- SYSDATE at physical INSERT
    migration_fl        CHAR(1)         NOT NULL,   -- Y=migrated, N=live
    data_version        NUMBER(5)       NOT NULL,   -- 1,2,3… on re-delivery

    -- Constituent data items (Pass 1 — is_derived_fl=N)
    scope1_direct       NUMBER,
    scope1_estimated    NUMBER,

    -- Derived canonical data items (Pass 2 — is_derived_fl=Y)
    scope1_mtco2        NUMBER,
    scope1_source_flag  VARCHAR2(20),

    -- ...all other domain metrics

    -- Lineage
    lineage_id          VARCHAR2(30)    NOT NULL,   -- → udm_lineage (LOAD step)

    CONSTRAINT pk_{sub_domain}_stk  PRIMARY KEY (entity_key, source_id,
                                    coverage_period, src_bgn_tran_dt, bgn_tran_dt),
    CONSTRAINT chk_stk_cur_fl       CHECK (cur_fl IN (0,1)),
    CONSTRAINT chk_stk_migration_fl CHECK (migration_fl IN ('Y','N'))
)
PARTITION BY RANGE (coverage_period) ...;

-- Indexes (mandatory at domain onboarding)
CREATE INDEX idx_{domain}_stk_entity  ON udm_{domain}_stk (entity_key, coverage_period, cur_fl) COMPRESS 2;
CREATE INDEX idx_{domain}_stk_src_blt ON udm_{domain}_stk (entity_key, coverage_period, src_bgn_tran_dt, src_end_tran_dt);
CREATE INDEX idx_{domain}_stk_udm_blt ON udm_{domain}_stk (entity_key, coverage_period, bgn_tran_dt, end_tran_dt);
```

## 4.4 RDM As-Of-Date Pattern — Option A vs Option B

The stack table must support point-in-time queries that answer: "what was the value for entity X, period Y, as known on date Z?" This requires bi-temporal design with both source and UDM transaction time.

### Option A — Separate Bridge Table Design (REJECTED)

A separate `udm_stk_version` table holds all temporal metadata, with the fact table carrying only a FK.

```sql
CREATE TABLE udm_stk_version (
    stk_version_id      VARCHAR2(20)    NOT NULL,
    entity_key          VARCHAR2(20)    NOT NULL,
    source_id           VARCHAR2(20)    NOT NULL,
    coverage_period     VARCHAR2(20)    NOT NULL,
    source_type         VARCHAR2(10)    NOT NULL,   -- SNAPSHOT | SCD2
    snapshot_dt         DATE,                       -- SNAPSHOT only
    source_bgn_dt       DATE,                       -- SCD2 only
    source_end_dt       DATE,                       -- SCD2 only
    bgn_tran_dt         DATE            NOT NULL,
    end_tran_dt         DATE            NOT NULL,
    cur_fl              NUMBER(1)       NOT NULL,
    load_dt             DATE            NOT NULL,
    migration_fl        CHAR(1)         NOT NULL,
    data_version        NUMBER(5)       NOT NULL,
    lineage_id          VARCHAR2(30),
    CONSTRAINT pk_udm_stk_version PRIMARY KEY (stk_version_id)
);
```

**Rationale for Option A:** Temporal metadata is shared across all metrics from the same load. Normalising it into one row per version avoids repetition. A single bridge row update closes all metrics when re-delivery arrives.

**Why Option A was rejected:** The bridge table has the same cardinality as the fact table — one row per entity per period per vendor per version. Same data volume, mandatory join on every query, and no material benefit. For a wide columnar table with 274 metric columns, four date columns at the row level is negligible overhead compared to the cost of an additional join on every consumer query.

### Option B — Four Dates on the Stack Row Directly (ADOPTED)

```sql
src_bgn_tran_dt     DATE    NOT NULL   -- SOURCE: when effective in source
src_end_tran_dt     DATE    NOT NULL   -- SOURCE: when superseded in source
bgn_tran_dt         DATE    NOT NULL   -- UDM:    when became current in UDM
end_tran_dt         DATE    NOT NULL   -- UDM:    when superseded in UDM
cur_fl              NUMBER(1)          -- UDM:    1=current, 0=superseded
```

**Why Option B is correct:** These four date columns are row-level metadata, not metric-level. In a wide columnar table (one row per entity per period per vendor per version), every metric on that row shares the same temporal context. Adding four date columns to a 274-column wide table is four columns, not 274. The cost is minimal. The benefit is: no additional join on any consumer query, and the query pattern is identical to the RDM source BETWEEN pattern — intentional compatibility.

**Recommendation:** Option B. Adopted in v8.

## 4.5 Provisional DDL Items

| Item | Status | Note |
|---|---|---|
| Domain stack partition strategy | ⚠️ Provisional | Partition by `coverage_period` (RANGE) recommended. Partition granularity (annual vs quarterly) depends on data volume per domain. DBA review required before first domain onboarding. |
| `udm_company_sector_mv` | 🔲 Not yet produced | Created at first COMPANY_SECTOR domain onboarding. DDL to be generated at that time. |
| dsc_* detection layer tables (10) | 🔲 Not yet produced | Tier 2 DDL. Detection layer tables for structural schema detection, EAV value discovery, PO review workflow. |
| Domain arb table template | ⚠️ Provisional | Template shown in v8 DDL header comments. Per-metric arb metadata columns follow `{metric}_arb_{suffix}` naming. Full template to be codified at first domain onboarding. |

**Status:** ✅ Decided (Option B adopted) | ⚠️ Provisional (partition strategy, arb template)

---

# 5. Process-Level Lineage

## 5.1 Two-Level Lineage Architecture

Lineage is captured at two levels:

**Level 1 — Process Run (`udm_process_run`):** One row per end-to-end delivery or processing cycle. This is the parent record. All pipeline objects FK to it. A single `process_run_id` traces the complete lifecycle of one vendor delivery.

**Level 2 — Lineage Step (`udm_lineage`):** One row per processing step within a run. `step_sequence` orders steps within a run.

```
udm_process_run
  process_run_id = RUN-20240315-00001
  process_type   = VENDOR_DELIVERY
  vendor_id      = VENDOR_A
  coverage_period = FY2024
  run_status     = COMPLETE
    │
    ├── udm_delivery_manifest  (step 1 — file arrival gate)
    │     manifest_id = MAN-20240315-00001
    │     status = COMPLETE  → triggers step 2
    │
    ├── udm_lineage  step_sequence=2  lineage_type=LOAD
    │     lineage_id = LIN-20240315-00002
    │     rows_written=15380  rows_quarantined=15
    │     → udm_{domain}_stk rows carry this lineage_id
    │     → udm_quarantine rows carry this lineage_id
    │
    ├── udm_lineage  step_sequence=3  lineage_type=GRAIN_ALIGN
    │     lineage_id = LIN-20240315-00003
    │
    ├── udm_lineage  step_sequence=4  lineage_type=ARBITRATION
    │     lineage_id = LIN-20240315-00004
    │     → udm_{domain}_arb rows carry this lineage_id
    │
    └── udm_lineage  step_sequence=5  lineage_type=DI_CHECK
          lineage_id = LIN-20240315-00005
          → udm_dq_results rows carry this lineage_id
```

## 5.2 Stage-by-Stage Lineage Map

| Step | seq | Input | Logic Applied | Output | Owner |
|---|---|---|---|---|---|
| File arrival | 1 | Vendor file delivery | Manifest validation — expected vs received file count | `udm_delivery_manifest` COMPLETE | Pipeline operations |
| Harmonisation load | 2 | Source staging table | Entity resolution, transform rules, unit conversion, two-pass processing | `udm_{domain}_stk` rows (bi-temporal) | `udm_hrm_engine` |
| Grain alignment | 3 | Stack rows at vendor grain | SUM / EXCLUDE / disaggregate per `udm_grain_alignment_rules` | Stack rows at canonical grain | `udm_hrm_engine` |
| Arbitration | 4 | Stack rows (all vendors, all entities) | Waterfall precedence via ROW_NUMBER analytic | `udm_{domain}_arb` golden copy | `udm_arb_engine` |
| DI check | 5 | Arb output | Threshold checks from `udm_dq_rules`, auto-derived checks | `udm_dq_results` pass/fail rows | `udm_arb_engine` |

## 5.3 Attribute-Level Lineage

Column-level lineage is captured by the `udm_data_item_lineage` view. It joins `udm_data_item` (what the metric IS) to `udm_data_item_src_map` (how it ARRIVES). No separate lineage table is needed — the data item and source map together ARE the column lineage.

Auditor query patterns:

```sql
-- Where does source column SCOPE1_DIRECT from VENDOR_A end up?
SELECT di.data_itm_nm, di.phy_trgt_tbl_nm, sm.attr_xfrm_ru_tx
FROM   udm_data_item_lineage
WHERE  sr.vendor_id    = 'VENDOR_A'
AND    sm.attr_src_nm  = 'SCOPE1_DIRECT';

-- Where did canonical data item scope1_mtco2 come from?
SELECT sr.vendor_id, sr.source_table, sm.attr_src_nm, sm.attr_xfrm_ru_tx
FROM   udm_data_item_lineage
WHERE  di.data_itm_nm = 'scope1_mtco2';
```

## 5.4 Arb Row — Built-In Provenance

Every resolved arb row carries full provenance without any additional join:

```
scope1_arb_rule_id     → rule that resolved this value
scope1_arb_lvl_nb      waterfall level number (1–8)
scope1_arb_lvl_tx      human-readable label ('Level 3 — Parent / Current / Vendor A')
scope1_arb_vendor_id   which vendor supplied the resolved value
scope1_arb_entity_ky   which entity's data was used (may be parent)
scope1_arb_period_tx   which period was used (may be prior year)
scope1_arb_stat_cd     RESOLVED / CARRIED_FWD / UNRESLVD / SUPPRESSED
scope1_arb_dq_score_nb quality score of the winning candidate (0–100)
```

**Status:** ✅ Decided

---

# 6. DI Performance Considerations

## 6.1 Set-Based Processing — Non-Negotiable

Row-by-row PL/SQL processing is a hard anti-pattern in this codebase. Every data operation must be expressible as set-based SQL. This applies equally to the harmonisation engine, arbitration engine, and any migration scripts.

The arbitration engine processes 10,000+ entities in a single pass through three SQL statements (GTT fetch, GTT rank, MERGE). No cursor loops.

## 6.2 Global Temporary Tables

Two GTTs stage intermediate arbitration results:

```
udm_arb_candidates_gtt    all qualified candidates — ON COMMIT DELETE ROWS
udm_arb_resolved_gtt      one winner per entity per metric — ON COMMIT DELETE ROWS
```

`ON COMMIT DELETE ROWS` means no cleanup between runs. APPEND hint on the GTT INSERT avoids undo generation. Indexes on GTTs are populated after INSERT completes.

GTTs avoid repeated scans of the large stack table — the stack is read once in `step_fetch_candidates`, staged to the GTT, and all subsequent steps read the GTT.

## 6.3 Partitioning Strategy

| Table | Partition Key | Interval |
|---|---|---|
| `udm_lineage` | `created_date` | Monthly (NUMTOYMINTERVAL(1,'MONTH')) |
| `udm_quarantine` | `quarantined_at` | Monthly |
| `udm_dq_results` | `checked_at` | Monthly |
| `udm_{domain}_stk` | `coverage_period` | Annual or quarterly — DBA review required |

All partitioned table indexes are created LOCAL unless noted otherwise.

## 6.4 Index Design

**Stack table (mandatory — created at domain onboarding):**

```sql
-- Hot path: entity + period + currency (most consumer queries)
CREATE INDEX idx_{domain}_stk_entity
    ON udm_{domain}_stk (entity_key, coverage_period, cur_fl)
    COMPRESS 2;
-- COMPRESS 2: compresses first two columns — high repetition in vendor stack

-- Point-in-time source queries (BETWEEN src_bgn AND src_end)
CREATE INDEX idx_{domain}_stk_src_blt
    ON udm_{domain}_stk (entity_key, coverage_period, src_bgn_tran_dt, src_end_tran_dt);

-- UDM version queries (BETWEEN bgn AND end)
CREATE INDEX idx_{domain}_stk_udm_blt
    ON udm_{domain}_stk (entity_key, coverage_period, bgn_tran_dt, end_tran_dt);
```

**Tier 1 indexes already in place:**

```
udm_company_xref         (vendor_id, external_id, effective_to, match_status)  — hot path
udm_entity_registry      (match_status, vendor_id)                             — VENDOR_ONLY lookup
udm_quarantine           (lineage_id, entity_id_raw, resolved_flag)            — arb exclusion
udm_ref_time             (period_start_date, calendar_type, period_grain)       — prior period join
udm_precedence_rules     (domain_id, bgn_tran_dt, end_tran_dt)                 — rule fetch
udm_precedence_rules     (domain_id, mtrc_grp_tx, entity_scope, period_scope)  — group lookup
udm_data_item            (data_itm_scd_1_ky, cur_fl)                           — SCD2 current version
udm_data_item            (phy_trgt_tbl_nm, cur_fl)                             — engine target lookup
```

## 6.5 BULK COLLECT and FORALL

Where PL/SQL must process rows (e.g. entity creation side effects during REFERENCE_SOURCE load), BULK COLLECT + FORALL is used. Row-by-row INSERT is not permitted. Typical bulk collection size: 500–1000 rows per fetch.

## 6.6 Deferred Performance Concerns

| Concern | Status | Note |
|---|---|---|
| Stack partition granularity | ⚠️ Deferred | Annual vs quarterly by domain — depends on row volume. Confirm before first domain onboarding. |
| `udm_company_sector_mv` refresh strategy | ⚠️ Deferred | Created at COMPANY_SECTOR onboarding. Refresh timing to be agreed based on frequency of membership changes. |
| Cross-vendor DQ (CROSS_VENDOR check) | ⚠️ Deferred | Runs before arbitration to surface divergence. Exact timing within pipeline step sequence to be confirmed. |
| Historical migration parallelism | 🔲 Open | Period-parallel migration (multiple coverage periods simultaneously) is technically possible. Sequencing rules (oldest-first) may constrain parallelism. To be confirmed with DBA. |

**Status:** ✅ Decided (core patterns) | ⚠️ Provisional (partition granularity, MV refresh) | 🔲 Open (migration parallelism)

---

# 7. RDM As-Of-Date Request Pattern

## 7.1 The Business Requirement

A downstream consumer wants to ask: "What was the Scope 1 value for entity X, coverage period 2020, as the source system knew it on November 22 2022?" And separately: "What was that same value as of January 2024?" — after a restatement had arrived.

Both queries have `coverage_period = 2020`. `coverage_period` alone cannot distinguish them. A second time axis is required.

## 7.2 The Bi-Temporal Mechanism

The stack table carries two independent temporal axes at the row level:

**SOURCE TRANSACTION TIME** — when this data was effective in the source system. Carried from the source unchanged and never modified after INSERT.

```
src_bgn_tran_dt    = rdm.bgn_tran_dt     (for SCD2 sources)
src_end_tran_dt    = rdm.end_tran_dt     (for SCD2 sources)

src_bgn_tran_dt    = snapshot_date       (for SNAPSHOT sources)
src_end_tran_dt    = LEAD(next_snapshot) - 1    (calculated via LEAD() at migration)
                   = DATE '9999-12-31'   if no next snapshot
```

**UDM TRANSACTION TIME** — when this version of the data was current in UDM. Changes when a re-delivery supersedes a row.

```
bgn_tran_dt        = SYSDATE at INSERT         (when UDM loaded this row)
end_tran_dt        = DATE '9999-12-31' initially
                   = SYSDATE-1 when superseded by re-delivery
cur_fl             = 1 (current) or 0 (superseded)
```

These axes are completely independent. A row can be current in UDM (`cur_fl=1`) while representing a historical source version (`src_end_tran_dt = 2022-06-30`). Both situations are valid and expected during and after migration.

## 7.3 Answering the Restatement Scenario

Data timeline:

```
Nov 22 2022: RDM receives original data for entity X, periods 2018/2019/2020
             src_bgn_tran_dt = 2022-11-22, src_end_tran_dt = 2024-01-14

Jan 15 2024: RDM receives restatement for 2019 and 2020
             src_bgn_tran_dt = 2024-01-15, src_end_tran_dt = 9999-12-31
```

After full historical migration to UDM, both versions exist in the stack:

```
Row A: coverage_period=2020  src_bgn=2022-11-22  src_end=2024-01-14  scope1_mtco2=X
Row B: coverage_period=2020  src_bgn=2024-01-15  src_end=9999-12-31  scope1_mtco2=Y
```

Query "as of Nov 22 2022":

```sql
WHERE coverage_period  = '2020'
AND   DATE '2022-11-22' BETWEEN src_bgn_tran_dt AND src_end_tran_dt
AND   cur_fl = 1;
-- Returns Row A: scope1_mtco2 = X  ✓
```

Query "as of Jan 15 2024" (post-restatement):

```sql
WHERE coverage_period  = '2020'
AND   DATE '2024-01-15' BETWEEN src_bgn_tran_dt AND src_end_tran_dt
AND   cur_fl = 1;
-- Returns Row B: scope1_mtco2 = Y  ✓
```

Query "what is the current value":

```sql
WHERE coverage_period  = '2020'
AND   src_end_tran_dt  = DATE '9999-12-31'
AND   cur_fl           = 1;
-- Returns Row B: the restated value Y  ✓
```

The BETWEEN pattern on `src_bgn_tran_dt / src_end_tran_dt` is identical to the existing RDM query pattern using `bgn_tran_dt / end_tran_dt`. This is intentional — consumer queries require only a column name change, not a pattern change.

## 7.4 How This Interacts with the Two DDL Options

**With Option A (bridge table — rejected):** The BETWEEN condition would apply to `udm_stk_version.source_bgn_dt / source_end_dt`. Every consumer query requires an additional JOIN to the bridge table. The query pattern is the same but the join is unavoidable.

**With Option B (dates on stack — adopted):** The BETWEEN condition applies directly to `stk.src_bgn_tran_dt / stk.src_end_tran_dt`. No additional join. The query pattern is identical to the RDM source pattern.

## 7.5 Source Type Handling for Snapshot Sources

Snapshot sources have no explicit end date — each snapshot is a complete replacement. The engine derives `src_end_tran_dt` during migration using LEAD():

```sql
src_end_tran_dt = LEAD(snapshot_date) OVER (
    PARTITION BY entity_key, coverage_period
    ORDER BY snapshot_date ASC
) - 1
-- For the last snapshot: src_end_tran_dt = DATE '9999-12-31'
```

This converts snapshot history into a BETWEEN-queryable range — the same query pattern works regardless of whether the source was SCD2 or snapshot.

## 7.6 Migration Rule — All SCD2 Versions Required

**The most critical migration constraint:** all SCD2 versions must be migrated from RDM, not just the current row.

If only the current RDM row is migrated, a BETWEEN query for any date before that row's `bgn_tran_dt` returns no results — because the prior versions were never loaded. Historical restatement queries fail silently. The migration script must extract every historical SCD2 row, not filter to `WHERE is_current_row = 'Y'`.

**Status:** ✅ Decided

---

# 8. Open Items and Decisions Deferred

## 8.1 Open — Requires Decision Before Next Phase

| ID | Item | Decision Required | Priority |
|---|---|---|---|
| OPN-001 | Domain stack partition granularity | Annual vs quarterly per domain. Depends on data volume. DBA review required before first domain onboarding. | HIGH — blocks domain onboarding |
| OPN-002 | 12 sub-domain names | Final list determines physical stack table names, taxonomy node values, and view names. Cannot change without data migration. | HIGH — blocks domain onboarding |
| OPN-003 | 274 metric primary sub-domain assignment | Each metric must have `phy_trgt_tbl_nm` assigned. Assignment requires categorisation by primary business domain. Overlapping metrics identified and secondary taxonomy rows added. | HIGH — blocks data item seeding |
| OPN-004 | Migration parallelism rules | Can multiple coverage periods be migrated simultaneously? Oldest-first sequencing may constrain parallelism. DBA confirmation required. | MEDIUM — affects migration timeline |
| OPN-005 | `udm_company_sector_mv` refresh strategy | Refresh timing depends on frequency of portfolio membership changes. Options: ON COMMIT, ON DEMAND, scheduled. | MEDIUM — needed at COMPANY_SECTOR onboarding |
| OPN-006 | MDM team engagement | udm_company_xref depends on MDM providing CONFIRMED mappings. MDM engagement is the critical path for cross-vendor arbitration. Without CONFIRMED xref, all vendor entities remain VENDOR_ONLY and cannot be arbitrated across vendors. | CRITICAL — blocks cross-vendor arbitration |

## 8.2 Provisional — Agreed but Pending Confirmation

| ID | Item | Current State | Confirmation Needed From |
|---|---|---|---|
| PRV-001 | Arb table DDL template | Template shown in v8 DDL comments. Per-metric suffix pattern `{metric}_arb_{suffix}` agreed. | DBA review of column count implications for 274-metric wide table |
| PRV-002 | Detection layer (dsc_* tables) | Logical design complete. Canonical name matching algorithm agreed. DDL not yet produced. | Architecture sign-off before Tier 2 DDL generation |
| PRV-003 | View generation script | Approach agreed (reads taxonomy, generates UNION ALL DDL per sub-domain). Script not yet written. | n/a — produces at first domain onboarding |
| PRV-004 | Historical migration strategy | Strategy A (replay from staging) preferred. Strategy B (from RDM) if staging transient. Strategy C (snapshot) last resort. | Confirm which strategy applies per domain based on staging availability |
| PRV-005 | Cross-vendor DQ timing | CROSS_VENDOR check type agreed. Exact position in pipeline step sequence not confirmed. | Architecture confirmation — before or after grain alignment? |

## 8.3 Design Choices Not Yet Made

| Item | Options | Note |
|---|---|---|
| Consumer backward-compat view column mapping | Need RDM column names → UDM canonical names per domain | Required before Phase 5 cutover. Produces per-domain synonym swap views. |
| Seed data scripts | Entity seeding, xref migration, data item population | Required before first live load. Not yet scripted. |
| Option A precedence rule extraction | Existing stored procedure contains hardcoded rules that must become INSERT statements into udm_precedence_rules | Highest-value quick win — unblocks config-driven arbitration immediately |

**Status:** 🔲 Open (OPN items) | ⚠️ Provisional (PRV items)

---

# 9. Glossary

## 9.1 Domain Terms

| Term | Definition |
|---|---|
| **Data Item** | A governed, source-agnostic business concept. Self-standing — exists independently of any source. E.g. "Scope 1 Emissions in metric tonnes CO2". Replaces the term "canonical attribute" used in earlier design sessions. |
| **Attribute** | A property of a source table. A physical column in a source system. Mapped to a Data Item via `udm_data_item_src_map`. |
| **Golden Copy** | The single governed value produced by the arbitration engine for a given entity, metric, and coverage period. Stored in `udm_{domain}_arb`. |
| **Coverage Period** | The business reporting period a measurement covers. E.g. FY2024, Q3-2023. Declared by the source or vendor. Distinct from the date the data arrived. |
| **Entity Key** | UDM-generated surrogate key (from udm_entity_seq, starting at 1,000,000) identifying one governed business entity. The only identity column on stack and arb tables. |
| **Source Key** | The original source PK (e.g. CST_ID from CST_DIM). Preserved on `udm_entity_registry.source_key` and on ref table natural key columns. Never on stack or arb tables. |
| **Vendor Only** | An entity known only from vendor data, with no confirmed internal counterpart. A first-class governed entity in UDM. May remain VENDOR_ONLY permanently or be merged into INTERNAL when MDM confirms the link. |
| **Merge (entity)** | The process by which a VENDOR_ONLY entity is confirmed by MDM to be the same as an INTERNAL entity. The VENDOR_ONLY entity is marked MERGED, its stack rows are reprocessed to the INTERNAL entity_key, and arbitration is re-run. |
| **Waterfall** | The ordered set of fallback rules that determine which vendor, entity scope, and time scope to try in sequence when resolving a golden copy. Declared in `udm_precedence_rules`. |
| **Grain** | The business key combination at which a measurement is expressed. E.g. COMPANY-FISCAL_YEAR, COMPANY_SECTOR-FISCAL_YEAR. |
| **Constituent Column** | A source attribute preserved in the stack table (e.g. scope1_direct, scope1_estimated). Written in Pass 1. |
| **Derived Canonical** | A data item computed from constituent columns (e.g. scope1_mtco2 = coalesce(scope1_direct, scope1_estimated)). Written in Pass 2. |
| **Logical FK** | A foreign key relationship declared in comments and enforced by the engine, but not as a physical Oracle constraint. Used for SCD1_KY references because SCD1_KY is not unique per row in the parent SCD2 table. |
| **Bi-temporal** | A design pattern carrying two independent time axes on a fact row: source transaction time (when effective in the source) and UDM transaction time (when current in UDM). |
| **PO** | Product Owner. The business owner responsible for governed decisions on entity matching, suppression, and unresolved arbitration cases. |
| **MDM** | Master Data Management. The external process that confirms vendor entity IDs map to internal entity IDs. UDM reads from MDM output — does not write to it. |

## 9.2 Table Abbreviations and Class Names

| Abbreviation | Meaning | Example |
|---|---|---|
| `udm_` | UDM schema prefix — all platform objects | `udm_data_item` |
| `_stk` | Domain vendor stack table | `udm_transition_risk_stk` |
| `_arb` | Domain arbitration (golden copy) table | `udm_transition_risk_arb` |
| `_v` | Reporting view generated from taxonomy | `udm_transition_risk_v` |
| `_gtt` | Global temporary table | `udm_arb_candidates_gtt` |
| `_mv` | Materialised view | `udm_company_sector_mv` |
| `dsc_` | Detection layer tables (Tier 2) | `dsc_column_profile` |
| `ref_` | Reference table (governed descriptive data) | `udm_ref_company` |

## 9.3 Column Naming Conventions

| Suffix | Meaning | Examples |
|---|---|---|
| `_KY` | Key / identifier | `data_itm_scd_1_ky`, `entity_key`, `parent_entity_key` |
| `_NM` | Name (short label) | `data_itm_nm`, `canonical_name` |
| `_TX` | Text / long description | `data_itm_de_tx`, `creat_usr_tx`, `attr_xfrm_ru_tx` |
| `_CD` | Short code / enumerated value | `row_stat_cd`, `source_system_cd`, `match_status` |
| `_FL` | Boolean flag (Y/N or 0/1) | `cur_fl`, `is_active`, `migration_fl`, `is_mndty_fl` |
| `_DT` | Date | `bgn_tran_dt`, `src_bgn_tran_dt`, `load_dt`, `creat_tran_dt` |
| `_NB` | Number / count | `scope1_arb_lvl_nb`, `data_version` |
| `_ID` | External business identifier (display only) | `data_itm_id` (NOT a FK target) |

## 9.4 Key Column Formats

| Column / Object | Format | Example |
|---|---|---|
| `entity_key` | Numeric from seq starting 1,000,000 | ENT-1000001 |
| `process_run_id` | RUN-YYYYMMDD-NNNNN | RUN-20240315-00001 |
| `lineage_id` | LIN-YYYYMMDD-NNNNN | LIN-20240315-00002 |
| `manifest_id` | MAN-YYYYMMDD-NNNNN | MAN-20240315-00001 |
| `quarantine_id` | QRN-YYYYMMDD-NNNNN | QRN-20240315-00001 |
| `review_id` | REV-YYYYMMDD-NNNNN | REV-20240315-00001 |
| `data_itm_scd_1_ky` | Integer from udm_data_itm_scd1_seq (stable) | 10025 |
| `data_itm_scd_2_ky` | Integer from udm_data_itm_scd2_seq (per version) | 10025001 |
| `data_itm_id` | Business code — no FK target | CLM_TR_EMISS_SCOPE3_CAT11_RPT_IND |

## 9.5 Status Tags Used in This Document

| Tag | Meaning |
|---|---|
| ✅ Decided | Design decision is locked. Do not reopen without a formal change request. |
| ⚠️ Provisional | Direction agreed but detail pending confirmation (e.g. DBA review, data volume analysis). |
| 🔲 Open | Not yet decided. Must be resolved before the next phase proceeds. |

---

## Document Change Log

| Version | Date | Changes |
|---|---|---|
| v8 | May 2026 | Complete rewrite as standalone architectural record. All sections added per specification. Entity lifecycle (INTERNAL/VENDOR_ONLY/MERGED). Bi-temporal stack (four date columns). Process run / lineage architecture. Option A vs B bridge table analysis. Open items formalised. |
| v7 | May 2026 | Precedence rules extended (entity_scope, period_scope, rule_label). Arb review queue. GTTs. Waterfall view. |
| v6 | May 2026 | Data Item concept adopted. SCD2 key pattern. SCD1_KY logical FK. Naming convention applied. |
| v5 | May 2026 | Metric taxonomy. View generation from taxonomy. metric_code role clarified. |
| v4 | May 2026 | Attribute map split. Source role simplified. Physical target on canonical attribute. |
