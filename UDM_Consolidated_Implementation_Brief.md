# UDM Data Item Cataloging & Harmonisation — Consolidated Implementation Brief

## Purpose
Binding reference for extending the UDM with new ESG/climate Data Items,
across **two distinct source shapes** now finalized: repeating structured
targets (CDP/ESGBook) and flat questionnaire responses resolved from
multiple raw columns. Reference implementation:
**`udm_business_catalog_complete_v1.sql`** — treat it as the ground truth;
extend it, do not redesign it.

## Overall model — two patterns, one registry

Every Data Item is governed in `UDM_DATA_ITM_RGSTR` (`SCD1_KY` is the FK
target). `STRUCTURE_TYPE` on the registry sends it down one of two paths:

```
UDM_DATA_ITM_RGSTR (SCD1_KY, STRUCTURE_TYPE, PHY_STORAGE_TX, ...)
         |
         +-- STRUCTURE_TYPE = 'STRUCTURE'  (repeating scope/category/method)
         |     -> UDM_DATA_ITM_ELMT            business catalog
         |     -> UDM_STRUCT_STORAGE_MAP       zone -> physical table routing
         |     -> UDM_DATA_ITM_SRC_COL_MAP     element <-> source label (HEADER/CATEGORY)
         |     -> UDM_TRGT_MTRC_DOMAIN         governed metric codes
         |     -> physical: OBS/STRUCT spine (UDM_STD_EMSN_TRGT_SNPSHT_FCT +
         |                  UDM_STD_EMSN_TRGT_MTRC_SNPSHT, normalized peers,
         |                  NOT parent/child, sharing one instance key)
         |
         +-- STRUCTURE_TYPE = 'STACK'  (flat scalar, one row per entity/period)
               -> UDM_DATA_ITM_SRC_MAP          header: (source,item) -> derivation_rule_cd
               -> UDM_DATA_ITM_SRC_COMPONENT_MAP  child: raw components under a header
               -> UDM_STD_RESP_EVID              evidence sidecar (no resolved value)
               -> physical: resolved value writes DIRECTLY to the EXISTING flat
                             subdomain column (target_table/target_column on
                             the registry) — no new spine, no new fact
```

**Choosing the path is mechanical, not a judgment call:** if the source data
repeats over scope / Scope-3 category / method for one instance, it's
STRUCTURE. If it's one answer per `(entity, period, item)` with no such
repetition — even if that one answer is assembled from several raw source
columns (value, numerator, denominator, unit, page, comment) — it's STACK.
Repetition axis present or absent is the entire test.

## Naming convention (binding — do not deviate)

| Table | Applies to | Purpose |
|---|---|---|
| `UDM_DATA_ITM_RGSTR` | both | governed registry; `SCD1_KY` is the FK target |
| `UDM_DATA_ITM_ELMT` | STRUCTURE only | business catalog of composing elements |
| `UDM_STRUCT_STORAGE_MAP` | STRUCTURE only | logical zone → physical table |
| `UDM_DATA_ITM_SRC_COL_MAP` | STRUCTURE only | element ↔ source label mapping |
| `UDM_TRGT_MTRC_DOMAIN` | STRUCTURE only | governed metric code vocabulary |
| `UDM_DATA_ITM_SRC_MAP` | STACK only | header: `(source, item) → derivation_rule_cd` |
| `UDM_DATA_ITM_SRC_COMPONENT_MAP` | STACK only | child: raw components under a `SRC_MAP` header |
| `UDM_STD_RESP_EVID` | STACK only | evidence sidecar (components, page, comment) |

**Do not use `SRC_COL_MAP` for STACK items and do not use `SRC_MAP` alone
for STACK items resolved from more than one raw column.** This distinction
was established specifically to prevent the two patterns' engine metadata
from colliding under the same table.

## Standard 1 — STRUCTURE items (repeating targets)

1. Data item = business concept. Constituents are **elements**, never data
   items.
2. A structure item normalizes into co-equal relations sharing one instance
   key — `INSTANCE_COL` (singular scalars) and `INSTANCE_MTRC`
   (scope/category/method-repeating, governed `TRGT_MTRC_CD`, typed
   `BASE_VAL_NO/TRGT_VAL_NO/RPT_YR_VAL_NO` buckets) — **not** parent/child.
   Codified narrow fact, not EAV: the row axis is closed and catalogued, the
   value columns are typed.
3. `src_key_type`: `HEADER` (CDP — identity is the column header) vs.
   `CATEGORY` (ESGBook — identity is a data value). Preserve verbatim.
4. Narrative/volatile content → `ATTR_KV` → `UDM_STD_OBS_ATTR`, never
   flattened. Multi-valued qualifiers → list bridges. Net-zero linkage →
   `NZ_LINK`, instance-to-instance, never a concept-relationship table.
5. Metric codes are governed (`UDM_TRGT_MTRC_DOMAIN`, FK-enforced), never
   free text.
6. Adapters are metadata-driven (`generate_target_adapters`): `src_key_type`
   selects HEADER-alias vs. CATEGORY-pivot; `val_bucket_cd` drives the
   metric reshape. Adding a source is a metadata change, never an engine
   change.

## Standard 2 — STACK items (flat responses, single or multi-column)

1. **The resolved value is written to its existing flat subdomain column**
   via the registry's `WIDE` routing. Never create a new fact to hold a
   value that already has a governed home.
2. **`derivation_rule_cd` (`DIRECT | RATIO | PCT_CHANGE | DELTA`) is
   source-scoped**, on `UDM_DATA_ITM_SRC_MAP` — never on the registry. The
   registry is business-governed and source-neutral; the same item can be
   `DIRECT` from one source and derived from another.
3. Raw components (value/numerator/denominator/uom/page/comment) are
   governed slots (`UDM_RESP_SLOT_DOMAIN`) attached as `SRC_COMPONENT_MAP`
   children of the `SRC_MAP` header — not per-item catalog entries, not a
   parallel mapping mechanism.
4. Only evidence with no existing home is new (`UDM_STD_RESP_EVID`): raw
   components if given that way, unit-as-reported, `is_derived_fl`, page,
   comment. It **never** duplicates the resolved value.
5. Long-to-wide harmonisation is a **generated, fixed-statement-count
   pivot**: `pivot_stack_to_target` builds one `MERGE` per physical target
   table by walking the registry for that table's `(item, target_column)`
   pairs. Column count scales with item count; statement count does not —
   same principle as the Module 8 DI framework's fixed-SQL-count checks.
6. Cross-source arbitration happens **before** the wide pivot, on
   already-resolved per-source scalars (`v_stg_resp_arbitrated`) — the
   arbitration priority table here is a minimal stand-in; production must
   call the existing Module 7 Arbitration package instead.
7. Business explorability for STACK items does **not** get a new catalog
   table — `V_UDM_STACK_COMPONENT_CATALOG` exposes `SRC_MAP` +
   `SRC_COMPONENT_MAP` directly. The engine metadata is the source of
   truth; don't duplicate it into a business-only table.

## Conventions inherited from the existing Tier 1 model — preserve these
- `SCD1_KY` is the logical FK target for data item references.
- Bi-temporal versioning (`src_bgn/end_tran_dt`, `bgn/end_tran_dt`,
  `cur_fl`) applies to all new domain stack and evidence tables.
- Wide flat tables are the default; the STRUCTURE metric relation's
  row-per-qualifier shape and the STACK evidence sidecar are the only
  established exceptions — both deliberate and governed, not EAV drift.
- `phy_storage_tx` (`WIDE | OVERFLOW | VIRTUAL | PENDING`) on the registry
  is the single source of truth for physical routing. `UDM_STRUCT_STORAGE_MAP`
  is its STRUCTURE-specific extension.
- **Complete file always**: every DDL change ships as one self-contained,
  re-runnable consolidated file — never an amendment-only patch.

## Explicit anti-patterns — reject if produced
- Routing a flat, non-repeating STACK response through the OBS/STRUCT spine.
- Storing a resolved STACK value a second time in `UDM_STD_RESP_EVID`.
- Placing `derivation_rule_cd` on the registry instead of `UDM_DATA_ITM_SRC_MAP`.
- Using `UDM_DATA_ITM_SRC_COL_MAP` for a STACK item, or `UDM_DATA_ITM_SRC_MAP`
  alone (without `SRC_COMPONENT_MAP`) for a STACK item resolved from more
  than one raw column.
- Framing `INSTANCE_MTRC` as a child/detail of `INSTANCE_COL` (normalized
  peers sharing one instance key, not master/detail).
- A generic `attr_name/attr_value` EAV table standing in for either the
  STRUCTURE metric relation or the STACK component set (both are governed,
  typed, closed-vocabulary — not open EAV).
- Hard-coding a derivation formula or a pivot column list in application
  code instead of reading it from `SRC_MAP`/registry metadata.
- One evidence or mapping table per item instead of the shared, governed
  tables above.
- Amendment-only DDL patches instead of a complete consolidated file.

## What to build next
Using `udm_business_catalog_complete_v1.sql` as the pattern to replicate:
1. Register `RENEWABLE_ENERGY_TARGET` and `NET_ZERO_TARGET`
   (`STRUCTURE_TYPE='STRUCTURE'`) and populate their `UDM_DATA_ITM_ELMT` +
   `UDM_DATA_ITM_SRC_COL_MAP` rows from CDP 7.54.1–5 and the corresponding
   ESGBook tables. Decide shared-vs-bespoke `INSTANCE_MTRC` fact family via
   `UDM_STRUCT_STORAGE_MAP` data, not code.
2. Register the remaining STACK questionnaire items
   (`STRUCTURE_TYPE='STACK'`), populate `UDM_DATA_ITM_SRC_MAP` +
   `UDM_DATA_ITM_SRC_COMPONENT_MAP` per source, confirming whether the
   587-key naming convention is regular enough for the generator to derive
   `resp_slot_cd` by pattern or needs per-key enumeration.
3. Validate every new row against the existing `CHECK` constraints
   (`chk_elmt_placement`, `chk_elmt_listcard` for STRUCTURE;
   `chk_srcmap_deriv`, `uq_scpm` for STACK) before delivery.
4. Run `generate_target_adapters` (STRUCTURE) and `pivot_stack_to_target`
   (STACK) against the new items and confirm output compiles/executes.
5. Deliver as one consolidated, self-contained file incorporating every
   object in `udm_business_catalog_complete_v1.sql`.

## Attachments to provide alongside this brief
- `udm_business_catalog_complete_v1.sql` — binding reference implementation
- Current Tier 1 canonical DDL (`udm_tier1_v{N}_complete.sql`)
- CDP questionnaire module 7 column definitions (7.54.1–5, and the 117-item
  flat questionnaire's full column set)
- ESGBook renewable-energy, net-zero, and flat-response table/category
  definitions
- The 117-item feed's key-naming convention (needed to confirm
  pattern-derivable vs. enumerated `resp_slot_cd` mapping)
