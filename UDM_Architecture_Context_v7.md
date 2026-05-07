# UDM Architecture — Full Context & Decisions Log
*Last updated: session 7*

---

## 1. Background & Strategic Context

### The Business Directive
The business has mandated a single governed platform for all data entering the system — regardless of source (vendor, internal, re-provisioned). The platform must be able to answer for any attribute, from any source: what it is, where it came from, when it arrived, and whether it passed integrity checks at the attribute level.

### Management Decision
Management has decided to proceed with **Option A (Selective UDM)** as the current state. Option B (Full UDM) remains the proposed evolution and the PO/architecture team's recommendation. The strategy is to make Option A forward-compatible with Option B through organic growth.

---

## 2. Option A — Current State (Selective UDM)

**PATH 1 — Non-arbitrated objects:**
```
Staging (transient) → RDM → Distribution Layer → Downstream
```

**PATH 2 — Arbitrated attributes:**
```
Staging (transient) → RDM → EAV Federated → EAV Standardized → UDM EAV (Arbitrated) → Distribution → Downstream
```

### Known tensions in Option A:
- Tribal knowledge of which system holds which attribute
- Triple EAV storage of every fact value
- No single platform inventory
- DI at object level only — no attribute-level anomaly detection
- Precedence rules hardcoded in stored procedure — not config-driven
- No raw vendor delivery preserved anywhere

---

## 3. Option B — Proposed Evolution (Full UDM)

### Pipeline:
```
Staging (permanent, raw preserved)
  → udm_{domain}_stk  (vendor stack, wide columnar per domain)
  → udm_{domain}_arb  (arbitration output, wide columnar per domain)
  → Distribution Layer → Downstream
```

### Key architectural decisions:
- Permanent staging — raw source preserved, enables full restatement
- One stack table per domain: `udm_{domain}_stk`
- One arb table per domain: `udm_{domain}_arb`
- No `vs_` prefix — naming is source-neutral
- entity_key always defined at the grain/subject of the measurement
- One entity_key column on all fact tables — no exceptions
- entity_type stamped on fact rows — consumers filter without joining registry
- measurement_grain stamped on fact rows — distinguishes coexisting grain types
- Business rules stay in distribution layer — UDM provides clean governed data only

---

## 4. Low-Level Design — Module Breakdown

### TIER 1 — Empty Schema (DDL shells)

**Module 1 — Tier 1 DDL** ✅ COMPLETE (session 7 final)
File: `udm_tier1_final_v3.sql`
Session 7 amendments incorporated:
- `source_role` reduced to two values: `DATA_SOURCE` and `REFERENCE_SOURCE`
- `IDENTITY_SOURCE` dropped — entity creation is a side effect of REFERENCE_SOURCE load
- `udm_identity_source_map` dropped entirely
- `udm_ref_source_map` extended: `creates_entity` + `entity_type` columns added
- `udm_entity_xref` → renamed `udm_company_xref`. Maintained externally (MDM process)
- `udm_source_system` → new governed source system catalog (seeded from `DW.src_sys_dim`)
- All `udm_ref_*` tables → `entity_key` FK removed; natural keys only
- `udm_entity_registry` → `source_key` column added (original source PK)
- `vendor_id` throughout → FK to `udm_source_system.source_system_cd`
Note: `udm_company_sector_mv` materialised view is NOT part of Tier 1 DDL.
It is created at domain onboarding time as part of Module 10 (Consumer Contracts).

**Module 2 — Tier 2 DDL** ← next
All `dsc_*` detection layer tables.

### TIER 2 — Detection Layer
Modules 3, 4, 5 — structural detection, EAV value detection, PO review queue.

### TIER 3 — Processing Engines
Modules 6, 7, 8, 9 — harmonisation, arbitration, DI framework, lineage recorder.

### TIER 4 — Consumer Layer
Modules 10, 11 — consumer contracts, semantic/BI catalog.

### Recommended First Sprint:
Module 1 (done) → Module 2 → seed data → Module 6 (one domain) → Module 8 (auto-derived checks).

---

## 5. Entity Model — Core Design Principles

### entity_key is always defined at the grain/subject of the measurement

The entity_key represents whatever entity IS the subject of that measurement row. It is not always a company. It can be a sector, a region, a country, or a composite entity (COMPANY_SECTOR).

```
entity_key    entity_type       canonical_name
ENT-00441     COMPANY           Acme Manufacturing Ltd
ENT-00442     COMPANY           Global Logistics Inc
ENT-S-001     SECTOR            Fabricated Metals
ENT-R-001     REGION            EMEA
ENT-CS-001    COMPANY_SECTOR    Acme Manufacturing / Fabricated Metals
ENT-CS-002    COMPANY_SECTOR    Acme Manufacturing / Industrial Machinery
```

### One entity_key column on all fact tables — no exceptions

Two key columns (entity_key + sector_entity_key) were considered and rejected. The grain is captured by registering the composite subject as its own entity type in udm_entity_registry.

### entity_type on fact table rows

`entity_type` is stamped on every stack and arb row at ingest from the source registration. Consumers can filter by entity_type without joining back to entity_registry.

### measurement_grain on fact table rows

`measurement_grain` is stamped from `udm_source_registry.domain_grain` at load time. Makes the grain of each row explicit. Part of the natural key of the stack table.

```
entity_key    entity_type       measurement_grain    fiscal_year    scope1_mtco2
ENT-00441     COMPANY           COMPANY              FY2023         12400
ENT-CS-001    COMPANY_SECTOR    COMPANY_SECTOR       FY2023         5200
ENT-CS-002    COMPANY_SECTOR    COMPANY_SECTOR       FY2023         4100
```

### udm_entity_membership — three use cases

The membership table serves three distinct consumers. It is a central table — not just an engine utility.

**Structure — two rows per COMPANY_SECTOR entity:**

```
membership_id   entity_key    parent_entity_key    relationship_type
MBR-001         ENT-CS-001    ENT-00441            COMPANY_COMPONENT
MBR-002         ENT-CS-001    ENT-S-001            SECTOR_COMPONENT
MBR-003         ENT-CS-002    ENT-00441            COMPANY_COMPONENT
MBR-004         ENT-CS-002    ENT-S-003            SECTOR_COMPONENT
```

**Use 1 — Grain alignment engine (ingest time)**

Rolls COMPANY_SECTOR measurements up to COMPANY canonical grain during arbitration. Reads COMPANY_COMPONENT rows only. Groups by parent_entity_key (the company) and sums metrics:

```sql
SELECT  mb.parent_entity_key    AS entity_key,
        'COMPANY'               AS entity_type,
        stk.fiscal_year,
        SUM(stk.scope1_mtco2)   AS scope1_mtco2
FROM    udm_transition_risk_stk   stk
JOIN    udm_entity_membership     mb
    ON  mb.entity_key          = stk.entity_key
    AND mb.relationship_type   = 'COMPANY_COMPONENT'
    AND mb.effective_to        IS NULL
WHERE   stk.entity_type    = 'COMPANY_SECTOR'
AND     stk.source_vendor  = 'INT_SYSTEM'
AND     stk.is_current     = 'Y'
GROUP BY mb.parent_entity_key, stk.fiscal_year
```

**Use 2 — BI / consumer layer enrichment (query time)**

Resolves a COMPANY_SECTOR entity_key back to its constituent company and sector for display. Requires two joins on the membership table — one per component. Mitigated by the `udm_company_sector_mv` materialised view (see Section 5a).

**Use 3 — Entity key reverse lookup (load time and query time)**

Given a company entity_key and a sector entity_key — find the COMPANY_SECTOR entity_key. Used by the harmonisation engine during ingest to check whether a COMPANY_SECTOR entity already exists before creating a new one. Also used by downstream systems that hold component keys and need the composite key.

Direct query (two joins):

```sql
SELECT  co.entity_key
FROM    udm_entity_membership   co
JOIN    udm_entity_membership   se
    ON  se.entity_key          = co.entity_key
    AND se.relationship_type   = 'SECTOR_COMPONENT'
    AND se.parent_entity_key   = 'ENT-S-001'
    AND se.effective_to        IS NULL
WHERE   co.relationship_type   = 'COMPANY_COMPONENT'
AND     co.parent_entity_key   = 'ENT-00441'
AND     co.effective_to        IS NULL
-- returns ENT-CS-001
```

Mitigated by `udm_company_sector_mv` (see Section 5a).

---

## 5a. udm_company_sector_mv — Materialised View

Centralises all three membership use cases into a single pre-resolved structure. Created at domain onboarding time as part of Module 10 — not part of Tier 1 DDL.

### Definition

```sql
CREATE MATERIALIZED VIEW udm_company_sector_mv
REFRESH ON COMMIT AS
SELECT  cs.entity_key              AS company_sector_key,
        cs.canonical_name          AS company_sector_name,
        co.parent_entity_key       AS company_entity_key,
        co_reg.canonical_name      AS company_name,
        se.parent_entity_key       AS sector_entity_key,
        se_reg.canonical_name      AS sector_name
FROM    udm_entity_registry        cs
JOIN    udm_entity_membership      co
    ON  co.entity_key          = cs.entity_key
    AND co.relationship_type   = 'COMPANY_COMPONENT'
    AND co.effective_to        IS NULL
JOIN    udm_entity_membership      se
    ON  se.entity_key          = cs.entity_key
    AND se.relationship_type   = 'SECTOR_COMPONENT'
    AND se.effective_to        IS NULL
JOIN    udm_entity_registry        co_reg
    ON  co_reg.entity_key      = co.parent_entity_key
JOIN    udm_entity_registry        se_reg
    ON  se_reg.entity_key      = se.parent_entity_key
WHERE   cs.entity_type = 'COMPANY_SECTOR'
AND     cs.is_active   = 'Y';
```

### Indexes (support all three access patterns)

```sql
-- Forward lookup: composite key → both components (Use 1 and Use 2)
CREATE INDEX idx_cs_mv_csk  ON udm_company_sector_mv (company_sector_key);

-- Reverse lookup: component keys → composite key (Use 3)
CREATE INDEX idx_cs_mv_co   ON udm_company_sector_mv (company_entity_key);
CREATE INDEX idx_cs_mv_se   ON udm_company_sector_mv (sector_entity_key);
CREATE INDEX idx_cs_mv_both ON udm_company_sector_mv (company_entity_key, sector_entity_key);
```

### Access patterns against the MV

**Use 1 — Grain alignment (forward):**
```sql
JOIN udm_company_sector_mv mv ON mv.company_sector_key = stk.entity_key
-- returns company_entity_key for GROUP BY
```

**Use 2 — BI enrichment (forward):**
```sql
SELECT company_name, sector_name
FROM   udm_company_sector_mv
WHERE  company_sector_key = :key
```

**Use 3 — Entity key reverse lookup:**
```sql
SELECT company_sector_key
FROM   udm_company_sector_mv
WHERE  company_entity_key = 'ENT-00441'
AND    sector_entity_key  = 'ENT-S-001'
```

### Refresh behaviour

REFRESH ON COMMIT. When the harmonisation engine creates a new COMPANY_SECTOR entity and commits the membership rows, the MV refreshes automatically. The next row in the same batch that needs the same key will find it in the MV — provided the engine commits between rows or uses a session-level cache (see Section 5b).

---

## 5b. COMPANY_SECTOR Entity Resolution at Load Time

### The three steps the harmonisation engine executes per source row

For a COMPANY_SECTOR grain source, each source row carries two identifiers — company and sector. The engine must resolve both and derive the composite entity_key before writing to the stack.

```
Source row: company_id = VA-8821, sector_code = 332110, scope1 = 5200

STEP 1 — Resolve company entity_key
  SELECT entity_key FROM udm_entity_xref
  WHERE  vendor_id = 'INT_SYSTEM' AND external_id = 'VA-8821'
  AND    effective_to IS NULL
  → ENT-00441

STEP 2 — Resolve sector entity_key
  SELECT entity_key FROM udm_entity_xref
  WHERE  vendor_id = 'INT_SYSTEM' AND external_id = '332110'
  AND    effective_to IS NULL
  → ENT-S-001

STEP 3 — Derive COMPANY_SECTOR entity_key
  SELECT company_sector_key FROM udm_company_sector_mv
  WHERE  company_entity_key = 'ENT-00441'
  AND    sector_entity_key  = 'ENT-S-001'

  FOUND → entity_key = ENT-CS-001 → write stack row → done

  NOT FOUND → check resolution_target on source registration:

    REGISTRY_AND_XREF:
      → generate new entity_key e.g. ENT-CS-099
      → INSERT into udm_entity_registry (entity_type = COMPANY_SECTOR)
      → INSERT into udm_entity_membership (COMPANY_COMPONENT row)
      → INSERT into udm_entity_membership (SECTOR_COMPONENT row)
      → COMMIT → MV refreshes
      → write stack row with entity_key = ENT-CS-099

    XREF_ONLY:
      → reject to udm_quarantine
      → check_type = ENTITY_NOT_FOUND
      → stop — PO investigates
```

### Batch-level session cache

When multiple rows in the same batch create or reference the same new COMPANY_SECTOR key, the MV has not yet refreshed (it refreshes on commit, not within a transaction). The engine uses a PL/SQL associative array as a session-level cache within the batch:

```
TYPE t_cs_cache IS TABLE OF VARCHAR2(20)
  INDEX BY VARCHAR2(40);  -- key = company_entity_key || '|' || sector_entity_key

cs_cache   t_cs_cache;

-- Before MV lookup, check cache:
l_cs_key := cs_cache(l_company_key || '|' || l_sector_key);

-- On new entity creation, populate cache immediately:
cs_cache(l_company_key || '|' || l_sector_key) := l_new_cs_key;
```

Cache is session-scoped — cleared at end of each batch run. No cross-batch state.

### Attribute map declaration for COMPANY_SECTOR sources

Three subject key rows in udm_attribute_map — one for company, one for sector, one derived composite:

```
source_attribute    canonical_name         is_subject_key    transform_rule
company_id          company_entity_key     Y                 lookup:UDM.udm_entity_xref.entity_key
sector_code         sector_entity_key      Y                 lookup:UDM.udm_entity_xref.entity_key
[derived]           entity_key             Y                 derive_cs:company_entity_key,sector_entity_key
fiscal_period       fiscal_year            N                 direct
scope1              scope1_mtco2           N                 direct
```

`derive_cs:` is a reserved transform type for COMPANY_SECTOR key derivation. It takes two already-resolved canonical names as inputs — the company key and sector key — executes the MV reverse lookup, and creates the entity if not found (subject to resolution_target). This keeps the derivation declarative and config-driven — not hardcoded in the engine procedure.

### Who populates udm_entity_membership

| Situation | Who | How |
|---|---|---|
| New COMPANY_SECTOR from authorised source | Harmonisation engine | Auto-creates at ingest — REGISTRY_AND_XREF |
| New vendor being onboarded — entities known | Catalog team | INSERT via change request before first load |
| Seed from existing RDM data | Catalog team | One-time seed script from RDM dimension joins |
| Not authorised source | Nobody | Row rejected to quarantine — PO decides |

---

## 5c. Reference Data vs Entity Data — Finalised Design

### The Core Distinction

**IDENTITY_SOURCE** answers: who is this entity across different systems?
Maps vendor identifiers to UDM permanent keys. Used at ingest only. Never seen by consumers.

**REFERENCE_SOURCE** answers: what is this thing?
Descriptive, classificatory data. Used as JOIN enrichment at query time. No arbitration.

**DATA_SOURCE** answers: what happened? What was measured?
Facts. Goes through vendor stack and arbitration. What consumers analyse.

The same dimension table can be registered under more than one role — different columns serving different purposes.

---

### udm_ref_* Tables — No entity_key

All `udm_ref_*` tables use **natural keys only**. No `entity_key` FK to `udm_entity_registry`. These are pure reference tables — independent of whether the thing they describe is also a measurement subject.

| Table | Natural key |
|---|---|
| `udm_ref_sector` | `classification_system + class_code` |
| `udm_ref_region` | `region_cd` |
| `udm_ref_country` | `iso_country_cd` |
| `udm_ref_company` | `lei_code` or internal `company_cd` |
| `udm_ref_counterparty` | `counterparty_cd` |
| `udm_ref_supplier` | `supplier_cd` |
| `udm_ref_product` | `product_code` |
| `udm_ref_time` | `period_value + calendar_type` |

The `entity_key` FK on all ref tables from session 5 was wrong and is now removed. A sector exists in `udm_ref_sector` regardless of whether it is ever registered as a measurement subject in `udm_entity_registry`.

---

### udm_entity_registry — Sector/Region/Country Entries

A SECTOR, REGION, or COUNTRY entity exists in `udm_entity_registry` **only** when that entity type is the **subject of a measurement** in a domain. It is not pre-populated from the ref table.

```
udm_ref_sector contains 500 sector codes    ← always — reference data
udm_entity_registry (SECTOR type) may have  ← only if sector-grain measurements exist
  10 rows for sectors that vendors measure
```

The two are independent. The link between them when both exist is the `class_code` on `udm_ref_sector` matching a lookup during entity creation — a data relationship, not a schema FK.

---

### Sector as Classifier vs Sector as Subject

**Sector as classifier** — sector_code is a descriptor on a company measurement row:

```
Source row: company_id=VA-8821, sector_code=332110, scope1=12400

Attribute map:
  sector_code → canonical_name=sector_code, is_subject_key=N, transform_rule=direct

Fact table row:
  entity_key=ENT-00441, entity_type=COMPANY, sector_code='332110', scope1=12400

Consumer enrichment at query time:
  JOIN udm_ref_sector ON class_code = stk.sector_code
  AND  classification_system = 'NAICS'
  AND  effective_to IS NULL
```

No entity resolution for sector. Raw code copied direct. No entity_key for sector in fact row.

**Sector as subject** — sector IS the entity being measured:

```
Source row: sector_code=332110, scope1=4200000

Attribute map:
  sector_code → canonical_name=entity_key, is_subject_key=Y
  transform_rule = lookup:UDM.udm_entity_registry WHERE entity_type=SECTOR
                   + canonical_name from udm_ref_sector.class_name

Fact table row:
  entity_key=ENT-S-001, entity_type=SECTOR, scope1=4200000
```

Entity resolution applies. Sector entity_key in fact row. Entry exists in `udm_entity_registry`.

---

### Sector/Region/Country Resolution — No xref Needed

Standard classification codes (NAICS, GICS, ISO 3166) are universal. Two vendors using `332110` mean the same sector. No competing identifiers. Resolution goes directly to `udm_ref_sector` using the natural key:

```
transform_rule = lookup:UDM.udm_ref_sector.entity_key  ← WRONG (session 5)

Correct:
  Engine reads class_code from source row
  Looks up udm_entity_registry WHERE entity_type = SECTOR
  AND canonical_name resolved from udm_ref_sector.class_name
  Creates entity if not found (REGISTRY_AND_XREF source)
```

No xref table for sectors, regions, or countries.

---

### Only One xref Table Needed — udm_company_xref

The xref problem exists only when the same real-world entity arrives under different identifiers from different vendors. This is predominantly a company/customer problem.

| Entity type | Needs xref? | Why |
|---|---|---|
| COMPANY | Yes | Vendor A calls Acme "VA-8821", Vendor B calls it "GB-441-X" |
| COUNTERPARTY | Yes | Separate vendor contracts, separate identifiers |
| SUPPLIER | Yes | Supply chain systems have own identifiers |
| SECTOR | No | Standard codes (NAICS, GICS) are universal |
| REGION | No | UDM-defined — no vendor competing identifiers |
| COUNTRY | No | ISO 3166 is universal |
| COMPANY_SECTOR | No | UDM-generated key — no vendor supplies composite identifier |

`udm_entity_xref` is replaced by typed tables only where needed:

```
udm_company_xref      ← replaces udm_entity_xref for COMPANY entities
udm_counterparty_xref ← if counterparties arrive under competing vendor IDs
udm_supplier_xref     ← if suppliers arrive under competing vendor IDs
```

The attribute map `lookup:` transform references the correct typed table:

```
source_attribute    canonical_name       transform_rule
company_id          entity_key           lookup:UDM.udm_company_xref.entity_key
```

---

### udm_source_system — Governed Source System Catalog

`vendor_id` throughout UDM is currently free text. The RDM schema already has `DW.src_sys_dim` which governs source systems. This is the correct reference.

**New table `udm_source_system`:**

```sql
CREATE TABLE udm_source_system (
    source_system_cd    VARCHAR2(50)    NOT NULL,  -- PK. Matches vendor_id throughout UDM.
    source_system_name  VARCHAR2(200)   NOT NULL,
    source_system_type  VARCHAR2(30)    NOT NULL,  -- VENDOR|INTERNAL|RDM|UDM_DERIVED
    owner_team          VARCHAR2(100),
    data_domain         VARCHAR2(100),
    is_active           CHAR(1)         DEFAULT 'Y' NOT NULL,
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    source_id           VARCHAR2(20),              -- FK → udm_source_registry (seeded from src_sys_dim)
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_source_system PRIMARY KEY (source_system_cd),
    CONSTRAINT chk_src_sys_type CHECK (source_system_type IN ('VENDOR','INTERNAL','RDM','UDM_DERIVED')),
    CONSTRAINT chk_src_sys_active CHECK (is_active IN ('Y','N'))
);
```

**Migration from DW.src_sys_dim:**
- Register `DW.src_sys_dim` as REFERENCE_SOURCE in `udm_source_registry`
- `udm_ref_source_map` points to `udm_source_system` as target
- Engine seeds `udm_source_system` from `src_sys_dim` on first load
- UDM becomes the master — RDM `src_sys_dim` becomes the seed, not the ongoing master

**FK impact:**
`vendor_id` on `udm_source_registry`, `udm_company_xref`, and `udm_identity_source_map` all gain a FK to `udm_source_system.source_system_cd`. Unknown source systems cannot be registered.

---

### How Reference Data is Populated

Exactly like a dimension in a typical warehouse. The flow is identical to any other source:

```
Source dim (e.g. DIM_NAICS_CODE in RDM or vendor lookup file)
  registered in udm_source_registry  (source_role = REFERENCE_SOURCE)
  udm_attribute_map declares columns
  udm_ref_source_map declares target + refresh strategy
  harmonisation engine reads → transforms → writes to udm_ref_*
```

Refresh strategies:

| Strategy | When to use | Example |
|---|---|---|
| `FULL_REPLACE` | Small, stable lookups | Country codes, regions |
| `INCREMENTAL` | Larger tables — insert new, update changed | Sector codes, product codes |
| `EFFECTIVE_DATE_MERGE` | Temporally governed data | Entity profiles, rate tables |

No entity resolution, no arbitration, no grain alignment. Simpler than fact population.

---

### How Subject Entities are Populated

Entity creation is now a **side effect of the REFERENCE_SOURCE load** — not a separate process. `IDENTITY_SOURCE` as a source_role is dropped. The engine creates entity_registry rows during the REFERENCE_SOURCE pass when `creates_entity = Y` on `udm_ref_source_map`.

**Path 1 — Company entities (REFERENCE_SOURCE with creates_entity = Y)**

```
CST_DIM registered as REFERENCE_SOURCE
  udm_ref_source_map: ref_table_name = udm_ref_company
                      creates_entity  = Y
                      entity_type     = COMPANY

  Engine for each row:
    1. Write descriptive columns to udm_ref_company (natural key = customer_bk)
    2. Check udm_entity_registry WHERE entity_type = COMPANY
                                   AND source_key  = customer_bk
       IF found    → no action — entity already exists
       IF not found → generate entity_key via udm_entity_seq
                      INSERT into udm_entity_registry
                      (entity_type = COMPANY, source_key = customer_bk,
                       canonical_name from legal_name column)
```

**Path 2 — Sector / Region / Country entities (REFERENCE_SOURCE with creates_entity = Y)**

Same pattern. Seeded from classification dimension tables. Entity_registry entry uses
`source_key = class_code` for sectors, `iso_country_cd` for countries, `region_cd` for regions.

**Path 3 — COMPANY_SECTOR entities (derive_cs: transform at DATA_SOURCE ingest)**

Auto-created at ingest. Fully documented in Section 5b.

**udm_company_xref — maintained externally**

Matching vendor IDs to internal entity_keys is an MDM problem requiring fuzzy matching,
business rules, and human review. UDM does not build this table. It is maintained by an
external MDM process and loaded into UDM as governed reference data before fact loads run.
UDM engine reads it — does not write to it.

```
External MDM process
  (existing matching tool or RDM process)
          ↓
  udm_company_xref pre-populated
          ↓
  UDM engine reads at ingest for vendor ID resolution
```

---

### Seeding Order — Critical

For a new domain the seeding order must be:

```
1. Seed udm_source_system        from DW.src_sys_dim  (REFERENCE_SOURCE, creates_entity=N)
2. Seed udm_ref_sector           from DIM_NAICS or equivalent  (creates_entity=Y, entity_type=SECTOR)
3. Seed udm_ref_region           from DIM_GEOGRAPHY  (creates_entity=Y, entity_type=REGION)
4. Seed udm_ref_country          from DIM_COUNTRY  (creates_entity=Y, entity_type=COUNTRY)
5. Seed udm_ref_company          from CST_DIM  (creates_entity=Y, entity_type=COMPANY)
   → entity_registry COMPANY rows created as side effect
6. Load udm_company_xref         from external MDM process  (pre-populated, not engine-driven)
7. Run first DATA_SOURCE load    facts — all lookups have data to resolve against
8. COMPANY_SECTOR entities       auto-created by derive_cs: during step 7
```

If steps 2-5 are skipped, entity canonical_name falls back to raw code on first fact load.
If step 6 is skipped, all vendor fact rows are rejected (ENTITY_NOT_FOUND) to udm_quarantine.
udm_company_xref must be loaded before any vendor DATA_SOURCE fact load runs.

**File:** `udm_tier1_final_v3.sql`
**Schema:** UDM
**Objects:** 27 tables, 27 sequences
(udm_identity_source_map dropped; udm_source_system added; udm_entity_xref → udm_company_xref)

### Table List in Creation Order

| # | Table | Group | Role |
|---|---|---|---|
| 01 | udm_source_system | CATALOG | Governed source system catalog — seeded from DW.src_sys_dim |
| 02 | udm_source_registry | CATALOG | Front door — one row per source per domain |
| 03 | udm_attribute_map | CATALOG | One row per attribute per source — IS the DI spec |
| 04 | udm_transform_rules | CATALOG | Named SQL expressions for rule_ref: transforms |
| 05 | udm_precedence_rules | CATALOG | Vendor priority per domain |
| 06 | udm_grain_alignment_rules | CATALOG | Grain collapsing rules per domain/vendor |
| 07 | udm_dq_rules | CATALOG | Threshold-dependent DQ checks only |
| 08 | udm_entity_registry | ENTITY | UDM permanent entity keys + source_key |
| 09 | udm_company_xref | ENTITY | Vendor ID → entity_key. Maintained by external MDM. |
| 10 | udm_entity_membership | ENTITY | Composite entity construct definitions |
| 11 | udm_spatial_asset_registry | ENTITY | 40M+ lat/long spatial assets |
| 12 | udm_ref_source_map | ROUTING | REFERENCE_SOURCE → udm_ref_* target + creates_entity |
| 13 | udm_ref_company | REFERENCE | Customer/company descriptive profile. Natural key only. |
| 14 | udm_ref_counterparty | REFERENCE | Counterparty descriptive profile. Natural key only. |
| 15 | udm_ref_supplier | REFERENCE | Supplier descriptive profile. Natural key only. |
| 16 | udm_ref_sector | REFERENCE | Sector classification. Natural key only. |
| 17 | udm_ref_region | REFERENCE | Region hierarchy. Natural key only. |
| 18 | udm_ref_country | REFERENCE | Country reference. Natural key only. |
| 19 | udm_ref_product | REFERENCE | Product reference — standalone |
| 20 | udm_ref_time | REFERENCE | Fiscal calendar — standalone |
| 21 | udm_delivery_manifest | PIPELINE | Bundle validation gate |
| 22 | udm_lineage | PIPELINE | Batch-level processing audit trail |
| 23 | udm_quarantine | PIPELINE | Rejected rows retained for resolution |
| 24 | udm_dq_results | PIPELINE | All DI check results |
| 25 | udm_detection_suppressions | PIPELINE | Negative PO decisions |
| 26 | udm_metric_catalog | SEMANTIC | Metric registry for catalog-driven BI |
| 27 | udm_domain_join_map | SEMANTIC | Valid cross-domain join paths |
| 28 | udm_grain_compatibility | SEMANTIC | Grain resolution rules |

---

## 7. Key Design Decisions — Sessions 3 & 4

### source_role on udm_source_registry (simplified session 7)

Three values reduced to two. `IDENTITY_SOURCE` is dropped — entity creation is now
a side effect of the REFERENCE_SOURCE load controlled by `creates_entity` on `udm_ref_source_map`.

| source_role | Engine path |
|---|---|
| DATA_SOURCE | staging → udm_{domain}_stk → udm_{domain}_arb |
| REFERENCE_SOURCE | → udm_ref_* tables. If creates_entity=Y → also seeds udm_entity_registry |

### subject_type on udm_source_registry
| subject_type | Meaning |
|---|---|
| ENTITY | Subject is a business entity — entity resolution applies |
| SPATIAL | Subject is a physical location — spatial registry applies |
| INTERNAL_ID | Subject is an internal system identifier — no entity resolution |

### governance_status full lifecycle
| Status | Engine processes? | Meaning |
|---|---|---|
| STAGE_ONLY | No | Detected, not yet approved |
| RDM_ONLY | No — RDM pipeline handles | Pre-UDM source |
| MIGRATING | Yes — parallel with RDM | Parallel run active |
| UDM_CATALOGED | Yes | Permanent end state |
| DEPRECATED | Yes — until effective_to | Winding down |
| RETIRED | No | Audit only — superseded_by_source_id set |

### superseded_by_source_id
Self-referencing FK on udm_source_registry. Set on RETIRED sources only. Points to the UDM_CATALOGED source that replaced it.

### entity_type values (extended in session 4)
`COMPANY | SUPPLIER | COUNTERPARTY | PRODUCT | SECTOR | REGION | COUNTRY | COMPANY_SECTOR`

COMPANY_SECTOR is a composite entity — one company operating in one sector. Registered as its own entity in udm_entity_registry. Decomposed via udm_entity_membership.

### udm_entity_membership (reinstated session 4)
Defines what composite entities are made of. Used by:
- Grain alignment engine — rolls COMPANY_SECTOR up to COMPANY
- Consumer queries — traverses entity relationships at report time

relationship_type values: `COMPANY_COMPONENT | SECTOR_COMPONENT | SECTOR_MEMBERSHIP | REGION_MEMBERSHIP`

### udm_ref_* typed tables (session 4)
One ref table per entity type. Replaces the generic udm_ref_entity table which was dropped.
- `udm_ref_company` — for COMPANY entities
- `udm_ref_counterparty` — for COUNTERPARTY entities
- `udm_ref_supplier` — for SUPPLIER entities
- `udm_ref_sector` — for SECTOR entities (includes hierarchy)
- `udm_ref_region` — for REGION entities
- `udm_ref_country` — for COUNTRY entities
- `udm_ref_product` — standalone (no entity_key if product is not a measurement subject)
- `udm_ref_time` — standalone fiscal calendar

Engine routes to correct ref table based on entity_type from udm_entity_registry. No additional config needed.

### udm_transform_rules (new in session 4)
Holds named SQL expressions for complex transforms that cannot be expressed as simple coalesce. Referenced by `transform_rule = rule_ref:RULE_NAME`.

### transform_rule patterns (extended session 5)
```
direct                   copy value as-is
lookup:schema.table.col  resolve via lookup; engine validates FK
divide:col_name          divide by another column in same row
multiply:constant        multiply by constant factor
derive:schema.table.col  fetch value from related table using source value as key
coalesce:col1,col2       first non-null wins — primary then fallback
rule_ref:RULE_NAME       complex logic in udm_transform_rules.resolution_sql
flag:col1,col2           writes DIRECT|ESTIMATED etc. — pairs with coalesce:
derive_cs:col1,col2      COMPANY_SECTOR specific — takes resolved company_entity_key
                         and sector_entity_key, looks up or creates composite
                         entity_key via udm_company_sector_mv reverse lookup.
                         Subject to resolution_target on source registration.
```

### source_attribute (renamed from vendor_attribute)
`vendor_attribute` renamed to `source_attribute` throughout udm_attribute_map.
Rationale: source-neutral naming — applies to vendor, internal, RDM, and derived sources.

### is_subject_key (renamed from is_entity_key)
`is_entity_key` renamed to `is_subject_key` throughout udm_attribute_map.
Rationale: the subject key is not always an entity (SPATIAL and INTERNAL_ID sources).

### unit_from extensions (session 4)
Three ways to declare the unit of a source attribute:
```
unit_from = 'tCO2'           static constant — applies to all rows
unit_from = 'col:unit'       read unit from named column in source row (COLUMNAR)
unit_from_eav_key = 'scope1_emission_unit'  read unit from sibling EAV row (EAV)
```

### grain_alignment_rules — new alignment methods (session 4)
```
DIRECT      vendor already at canonical grain
LAST_VALUE  take last row within canonical period
FIRST_VALUE take first row within canonical period
AVERAGE     arithmetic mean within period
SUM         sum within period — used for COMPANY_SECTOR → COMPANY roll-up
EXCLUDE     vendor cannot be aligned to canonical grain — excluded from arbitration
DISAGGREGATE apply governed weight table to disaggregate — only if business approved
```

### Intra-source conditional mapping (session 4)
When two attributes from the same source must be combined or selected to produce one canonical value:
- Both source attributes catalogued in udm_attribute_map with their own canonical names
- Canonical derived column uses `coalesce:` transform
- `flag:` transform writes which source attribute was selected
- Both the derived canonical value and the flag flow through to arb layer
- Arbitration can use flag in conditional precedence rules

### Manifest flow
Manifest is a PRE-HARMONISATION gate. Flow:
```
File arrives → manifest updated (files_received + 1)
  → if files_received = expected_files → status = COMPLETE
  → Oracle Scheduler fires → harmonisation engine runs
  → arbitration engine runs
  → DQ checks run
  → distribution layer queries arb table
```

### Domain table naming
`udm_{domain}_stk` and `udm_{domain}_arb` — no `vs_` prefix.
Rationale: vs_ implied vendor stack — not source-neutral.

### Sector data cannot be disaggregated
If a vendor provides SECTOR grain data and canonical grain is COMPANY — the vendor is excluded from arbitration via `alignment_method = EXCLUDE`. Sector data preserved in stack for sector-level reporting only.

### udm_entity_xref not registered in source_registry
UDM-owned infrastructure — registering it would create a circular reference.

### udm_ref_* schema placement
All udm_ref_* tables stay in UDM schema. Naming convention (`udm_ref_` prefix) provides namespace separation. Oracle role `udm_ref_reader` handles grant granularity.

### RDM dimension roles
| Role | source_role | Engine target |
|---|---|---|
| Identity resolution (DIM_CLIENT) | IDENTITY_SOURCE | entity_registry + entity_xref |
| Governed attribute source | DATA_SOURCE | udm_{domain}_stk → arb |
| Pure reference (DIM_GEOGRAPHY) | REFERENCE_SOURCE | udm_ref_* tables |

### Entity embedded in fact file — no separate master
Same source table registered twice:
- Once as IDENTITY_SOURCE (identity pass — entity resolution)
- Once as DATA_SOURCE (metrics pass — stack population)
Engine processes identity pass first, metrics pass second.

### DI ownership
UDM owns: rules definition (attribute_map + udm_dq_rules) and results (udm_dq_results).
External DQ tool owns: scheduling, alerting, dashboarding, workflow.

### Lineage granularity
Batch-level only. Row-level failures go to udm_dq_results and udm_quarantine.
duration_secs is a virtual column — no storage cost.

---

## 8. Source Registry & Engine Branching

### Engine branching logic
```
Read source_format:
  IF EAV → pivot using attribute_map + eav_filter → proceed as COLUMNAR
  IF COLUMNAR → read attribute_map, apply transforms, filter current rows

Read source_role:
  DATA_SOURCE      → write to udm_{domain}_stk → arbitration
  REFERENCE_SOURCE → read udm_ref_source_map:
                       write to ref_table_name (e.g. udm_ref_company)
                       IF creates_entity = Y:
                         check udm_entity_registry by entity_type + source_key
                         IF not found → INSERT new entity_key (via sequence)

Read subject_type (DATA_SOURCE only):
  ENTITY      → entity resolution applies (see below)
  SPATIAL     → spatial registry applies
  INTERNAL_ID → no resolution; raw identifier passes through as natural key

For ENTITY subject_type — resolution by entity_type:

  COMPANY / COUNTERPARTY / SUPPLIER:
    1. Lookup udm_company_xref by vendor_id + external_id  (pre-populated externally)
    2. If found → use entity_key
    3. If not found → reject to quarantine (ENTITY_NOT_FOUND)
    NOTE: UDM engine never auto-creates COMPANY entities. xref is pre-populated by MDM.

  SECTOR / REGION / COUNTRY (standard codes — no xref):
    1. Lookup udm_entity_registry by entity_type + source_key (= standard code)
    2. If found → use entity_key
    3. If not found → auto-create entity_key (seeded from ref table canonical_name)

  COMPANY_SECTOR (composite — derive_cs: transform):
    1. Resolve company key (step above)
    2. Resolve sector key (step above)
    3. Lookup udm_company_sector_mv by company_entity_key + sector_entity_key
    4. If found → use company_sector entity_key
    5. If not found → auto-create entity + 2 membership rows
    6. Use session-level PL/SQL cache for repeat lookups within same batch
```

### currency_mechanism values
```
CURRENT_FLAG        WHERE {current_flag_column} = 'Y'
EFFECTIVE_DATES     WHERE {effective_to_column} IS NULL
MAX_SNAPSHOT_DATE   MAX({time_key_column}) per entity
ALWAYS_CURRENT      no history — every row is current
LOAD_DATE           MAX(load_date) per entity
```

---

## 9. Detection Layer Design

### Two-layer model
```
dsc_* (detection, environment-local) → PO review → udm_* (governed, travels via pipeline)
```

### Two detection processes
- Structural: DEV and TEST only, schema dictionary, no data access
- EAV value: all lanes, actual EAV data, multi-lane promotion paths

### Detection layer tables (dsc_*)
```
dsc_table_inventory, dsc_column_inventory, dsc_profiling_results,
dsc_eav_value_inventory, dsc_schema_change_log, dsc_classification_results,
dsc_po_review_queue, dsc_po_corrections, dsc_promoted_baseline, dsc_promotion_log
```

### Column drop handling
Detection flags HIGH urgency → udm_attribute_map.map_status = PENDING_RETIREMENT →
engine blocks that source → column drop DDL and metadata retirement travel together in same release bundle.

---

## 10. Pending Data Tasks (before engine work begins)

1. Seed `udm_source_system` from `DW.src_sys_dim` (registered as REFERENCE_SOURCE, creates_entity=N)
2. Register all Option A sources in `udm_source_registry`
3. Extract hardcoded precedence rules from Option A stored procedure → INSERT into `udm_precedence_rules`
4. Seed `udm_ref_sector` from DIM_NAICS or equivalent (creates_entity=Y, entity_type=SECTOR)
5. Seed `udm_ref_region` from DIM_GEOGRAPHY (creates_entity=Y, entity_type=REGION)
6. Seed `udm_ref_country` from DIM_COUNTRY (creates_entity=Y, entity_type=COUNTRY)
7. Seed `udm_ref_company` from CST_DIM (creates_entity=Y, entity_type=COMPANY)
   → entity_registry COMPANY rows created as side effect
8. Load `udm_company_xref` from external MDM process (pre-populated, not engine-driven)
9. Seed `udm_ref_time` for all coverage periods in current data estate
10. COMPANY_SECTOR entities auto-created during first DATA_SOURCE fact load
11. Create `udm_company_sector_mv` at first COMPANY_SECTOR domain onboarding (Module 10)

---

## 11. Open Items / Next Steps

- [ ] **Tier 1 DDL v3** — produce final consolidated DDL incorporating all session 7 changes
- [ ] Module 2 — Tier 2 DDL for `dsc_*` detection layer tables ← next
- [ ] Seed data scripts for Option A sources into `udm_source_registry`
- [ ] Harmonisation engine — PL/SQL framework, one domain first (Module 6)
  - [ ] REFERENCE_SOURCE load with `creates_entity` side effect
  - [ ] Session-level PL/SQL cache for COMPANY_SECTOR key resolution
  - [ ] `derive_cs:` transform implementation
  - [ ] Sector/Region/Country entity auto-creation on first encounter
- [ ] Arbitration engine — PL/SQL procedure (Module 7)
- [ ] DI framework — auto-derived checks (Module 8)
- [ ] Lineage recorder — shared insert procedure (Module 9)
- [ ] Module 10 — `udm_company_sector_mv` DDL + indexes (created at domain onboarding)
- [ ] Oracle Scheduler job definitions
- [ ] Promotion script generator — `dsc_*` findings to `udm_*` release artifacts
- [ ] Column drop handling — automated block + paired release bundle logic

---

## 12. Full Decisions Log

| Decision | Outcome |
|---|---|
| Strategic direction | Option A current, Option B proposed evolution |
| Management decision | Proceed with Option A |
| EAV → Wide Columnar | Good to have, not a prerequisite |
| Permanent staging | Recommended for Option B |
| Domain stack naming | udm_{domain}_stk — no vs_ prefix |
| Domain arb naming | udm_{domain}_arb |
| Entity registry | All entity types including COMPANY_SECTOR in one table |
| entity_key definition | Always at grain/subject of measurement — one column only |
| COMPANY_SECTOR entity | Registered as own entity type in entity_registry |
| entity_type on fact rows | Stamped at ingest — consumers filter without join |
| measurement_grain on fact rows | Stamped from domain_grain — part of natural key |
| udm_entity_membership | Reinstated — defines composite entity constructs; used by grain alignment engine |
| udm_ref_* typed tables | One per entity type — replaces generic udm_ref_entity |
| udm_ref_entity | Dropped — replaced by typed tables |
| udm_ref_location | Dropped — replaced by udm_ref_region + udm_ref_country |
| udm_ref_classification | Dropped — replaced by udm_ref_sector |
| udm_ref_product | Retained standalone |
| udm_ref_time | Retained standalone |
| udm_transform_rules | New table for rule_ref: complex transforms |
| transform_rule patterns | direct, lookup, divide, multiply, derive, coalesce, rule_ref, flag |
| vendor_attribute renamed | source_attribute — source-neutral naming |
| is_entity_key renamed | is_subject_key — applies to all subject types |
| unit_from_eav_key | New column on attribute_map for EAV sibling row unit lookup |
| subject_type | ENTITY|SPATIAL|INTERNAL_ID on source_registry |
| domain_grain | Declared on source_registry — stamped as measurement_grain on fact rows |
| EXCLUDE alignment method | Vendor cannot align to canonical grain — excluded from arbitration |
| DISAGGREGATE alignment method | Only with governed weight table and explicit business approval |
| Sector data disaggregation | Not permitted — sector total cannot be split to company level |
| Intra-source conditional mapping | coalesce: + flag: pattern — both attributes catalogued |
| udm_ref_* schema placement | UDM schema — udm_ref_ prefix sufficient |
| udm_entity_xref not registered | UDM infrastructure — not an external data source |
| Entity embedded in fact file | Two registrations of same source table — IDENTITY then DATA pass |
| governance_status lifecycle | STAGE_ONLY→RDM_ONLY→MIGRATING→UDM_CATALOGED/DEPRECATED/RETIRED |
| superseded_by_source_id | Self-referencing FK — RETIRED sources only |
| DI ownership | UDM owns rules + results; external DQ tool owns workflow |
| Lineage granularity | Batch-level only |
| Detection tier placement | Tier 2 — upstream of catalog population |
| dsc_* promotion | Environment-local only |
| udm_* promotion | Standard release pipeline |
| map_status PENDING_RETIREMENT | Set on column drop detection — engine blocks source |

| udm_entity_membership — three use cases | Grain alignment engine + BI consumer enrichment + entity key reverse lookup |
| udm_company_sector_mv | Materialised view pre-resolving all three membership access patterns. REFRESH ON COMMIT. Created at domain onboarding (Module 10) — not Tier 1 DDL. |
| udm_company_sector_mv indexes | Forward: company_sector_key. Reverse: company_entity_key, sector_entity_key, combined both. |
| COMPANY_SECTOR resolution at load time | Three steps: resolve company key, resolve sector key, derive composite key via MV reverse lookup |
| New COMPANY_SECTOR entity at ingest | Engine auto-creates. Session-level cache handles repeat lookups within batch. |
| derive_cs: transform type | New reserved transform type for COMPANY_SECTOR key derivation. Declarative — not hardcoded in engine. |
| Attribute map for COMPANY_SECTOR | Three is_subject_key rows: company lookup, sector lookup, derive_cs: composite derivation. |
| Entity not found at ingest | check_type = ENTITY_NOT_FOUND in udm_quarantine. |
| udm_entity_xref replaced | Renamed udm_company_xref. One xref table only — company/counterparty/supplier. |
| Only company needs xref | Sectors/regions/countries use universal standard codes — direct registry lookup. |
| udm_ref_* entity_key FK removed | All ref tables use natural keys only. Independent of entity_registry. |
| udm_entity_registry source_key | New column storing original source PK (e.g. customer_bk). Enables join back to source during migration. |
| entity_key uniqueness | UDM-owned sequence starting at 1000000. Source PKs never used as entity_key — collision risk. |
| entity_registry join to ref tables | Join on source_key = natural_key (e.g. customer_bk). Not entity_key. |
| udm_ref_company maintenance | Owned by CST_DIM / source system during migration. UDM reads via REFERENCE_SOURCE load. Governance stays outside UDM until explicit decision to make UDM master. |
| Ref table ownership migration | Phase 1: external master → UDM projection. Phase 2: UDM master → source consumes from UDM. governance_status tracks transition. |
| IDENTITY_SOURCE dropped | Entity creation is side effect of REFERENCE_SOURCE load. IDENTITY_SOURCE role no longer needed. |
| udm_identity_source_map dropped | No longer needed — entity creation controlled by creates_entity on udm_ref_source_map. |
| udm_ref_source_map extended | creates_entity CHAR(1) + entity_type VARCHAR2(20) columns added. |
| udm_company_xref maintained externally | MDM problem — fuzzy matching, business rules, human review. UDM reads but does not build. Pre-populated before first fact load. |
| COMPANY entity auto-creation | NOT done by engine. Only via REFERENCE_SOURCE load of CST_DIM with creates_entity=Y. |
| source_role values | Reduced to two: DATA_SOURCE and REFERENCE_SOURCE. |
| udm_source_system | New governed source system catalog. Seeded from DW.src_sys_dim. vendor_id throughout UDM FKs to this. |

---

*End of context v7. Paste this document at the start of a new conversation to resume.*
