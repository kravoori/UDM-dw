# UDM Structured Data Item — Implementation Specification
## Emission Intensities, Emissions Assurance, and Reduction / Net-Zero Targets

**Audience:** UDM development team
**Status:** Build specification — v2
**Reference sources:** ESGbook (65100, 66100–66500, 67100–67400), CDP 2024
**Concepts in scope:** Emission Intensities, Scope Assurance (×4), Renewable Energy Target,
SBTi Commitment, Net Zero Targets, Emissions Reduction Targets

---

## 1. Purpose

Some data items are not scalars. ESGbook delivers emission intensities as an array (one record per
scope × denominator combination), assurance data as a fixed map (three named fields per scope), and
targets as either a single map or an array depending on concept. CDP delivers the same business
concepts in equivalent structures.

This spec defines how to store and load all of these using the **simplest possible mechanism** that
still gives UDM its three guarantees: bi-temporal history, single golden value per cell, and full
lineage to source.

---

## 2. Core Design Principle (read this first)

> **One normalized view per target table. The view's output columns match the target table columns
> by name. The framework loads insert-only. No post-load updates to business columns. No procedural
> row-routing logic.**

Everything in this spec is an application of that one rule.

The complexity of each source's physical layout — relational rows, pipe-delimited strings, or a
JSON column — is absorbed **inside the view**. The framework never sees it.

**Table naming rule:** tables are named after the business concept they hold, not the storage
pattern. No table name contains the word "struct".

---

## 3. Two Structural Shapes

Every structured data item is one of two shapes. This drives the load path.

| Shape | Meaning | Child list rows? | `obs_id` |
|---|---|---|---|
| **MAP** | One observation per entity per period — fixed named fields | No | Defaulted to `'1'` |
| **ARRAY_OF_MAP** | Many observations per entity per period | Yes — `udm_obs_scope` and/or `udm_obs_category` | Source-assigned id |

`struct_shape_cd` on `udm_data_item_src_map` tells the framework which path to take. The target
tables are the same regardless of shape — MAP items simply always have one row with `obs_id = '1'`.

---

## 4. The Pattern in One Picture

```
ESGbook RDM              CDP RDM
(relational or JSON)     (relational or JSON)
        │                      │
        ▼                      ▼
 ┌──────────────────────────────────────┐
 │  SOURCE VIEWS (one per source × table)│  ← all canonicalization here
 │  output column names = target columns │    label mapping, scope combo, typing
 └──────────────────────────────────────┘
        │
        │  framework: insert-only with bi-temporal envelope
        │  order: list tables first (load_seq_nb=1), header second (load_seq_nb=2)
        ▼
 ┌────────────────────┐   ┌──────────────────────────────┐
 │  HEADER TABLE       │◄──│  SHARED OBSERVATION LISTS    │
 │  1 row per obs      │   │  udm_obs_scope               │
 │  scalar payload     │   │  udm_obs_category            │
 │  resolved cell key  │   │  N rows per obs (ARRAY only) │
 │  is_golden_fl       │   │  data_item_cd discriminates  │
 └────────────────────┘   └──────────────────────────────┘
        │
        ▼  cell-level arbitration → is_golden_fl
  consumer views  (filter: is_golden_fl = 1 AND cur_fl = 1)
```

---

## 5. Physical Tables

### 5.1 Naming — five tables cover all ten ESGbook concepts

| Table | Concepts | Shape |
|---|---|---|
| `udm_emissions_intensity` | 65100 Emission Intensities | ARRAY_OF_MAP |
| `udm_emissions_assurance` | 66100 / 66200 / 66300 / 66400 / 66500 | MAP |
| `udm_emissions_target` | 67100 / 67200 / 67300 / 67400 | MAP or ARRAY_OF_MAP |
| `udm_obs_scope` | Any concept with a scope array | shared child |
| `udm_obs_category` | Any concept with a category array | shared child |

`data_item_cd` on the header tables and shared list tables is the discriminator that separates
concepts stored in the same physical table.

### 5.2 Shared observation list tables

These tables hold the raw array elements, in canonical form, for any structured data item that
delivers scopes or categories as arrays. A future concept reuses them — no new list tables.

```sql
-- Scope elements for any ARRAY_OF_MAP concept
CREATE TABLE udm_obs_scope (
    data_item_cd        VARCHAR2(30)  NOT NULL,   -- e.g. '65100', '67300', '67400'
    entity_key          VARCHAR2(20)  NOT NULL,
    source_id           VARCHAR2(20)  NOT NULL,
    coverage_period     VARCHAR2(20)  NOT NULL,
    obs_id              VARCHAR2(40)  NOT NULL,
    item_no             NUMBER(4)     NOT NULL,   -- position in the source array (1-based)
    scope_cd            VARCHAR2(10)  NOT NULL,   -- canonical single scope: S1 | S2 | S3
    -- bi-temporal envelope
    src_bgn_tran_dt     DATE          NOT NULL,
    src_end_tran_dt     DATE          NOT NULL,
    bgn_tran_dt         DATE          NOT NULL,
    end_tran_dt         DATE DEFAULT  DATE '9999-12-31' NOT NULL,
    cur_fl              NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id          VARCHAR2(30)  NOT NULL,
    CONSTRAINT pk_obs_scope PRIMARY KEY
        (data_item_cd, entity_key, source_id, coverage_period,
         obs_id, item_no, src_bgn_tran_dt, bgn_tran_dt)
);

-- Category elements for any ARRAY_OF_MAP concept
CREATE TABLE udm_obs_category (
    data_item_cd        VARCHAR2(30)  NOT NULL,
    entity_key          VARCHAR2(20)  NOT NULL,
    source_id           VARCHAR2(20)  NOT NULL,
    coverage_period     VARCHAR2(20)  NOT NULL,
    obs_id              VARCHAR2(40)  NOT NULL,
    item_no             NUMBER(4)     NOT NULL,
    category_cd         VARCHAR2(40)  NOT NULL,   -- canonical denominator: REVENUE | MWH_GENERATED ...
    -- bi-temporal envelope
    src_bgn_tran_dt     DATE          NOT NULL,
    src_end_tran_dt     DATE          NOT NULL,
    bgn_tran_dt         DATE          NOT NULL,
    end_tran_dt         DATE DEFAULT  DATE '9999-12-31' NOT NULL,
    cur_fl              NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id          VARCHAR2(30)  NOT NULL,
    CONSTRAINT pk_obs_category PRIMARY KEY
        (data_item_cd, entity_key, source_id, coverage_period,
         obs_id, item_no, src_bgn_tran_dt, bgn_tran_dt)
);
```

### 5.3 Emission Intensities — `udm_emissions_intensity` (ARRAY_OF_MAP)

One row per intensity observation. The cell key is `scope_cd + category_cd`.
`scope_cd` is the ordered concatenation of canonical scopes from `udm_obs_scope` (e.g. `S1+S2`),
computed in the header view — not updated after insert.

```sql
CREATE TABLE udm_emissions_intensity (
    data_item_cd        VARCHAR2(30)  DEFAULT '65100' NOT NULL,
    entity_key          VARCHAR2(20)  NOT NULL,
    source_id           VARCHAR2(20)  NOT NULL,
    coverage_period     VARCHAR2(20)  NOT NULL,
    obs_id              VARCHAR2(40)  NOT NULL,   -- source-assigned observation id
    -- cell key (resolved in view, written once)
    scope_cd            VARCHAR2(40)  NOT NULL,   -- combo e.g. 'S1+S2', 'S1+S2+S3'
    category_cd         VARCHAR2(40)  NOT NULL,   -- e.g. 'REVENUE', 'MWH_GENERATED'
    -- payload
    value_nb            NUMBER        NOT NULL,
    value_unit_cd       VARCHAR2(40),
    -- bi-temporal envelope
    src_bgn_tran_dt     DATE          NOT NULL,
    src_end_tran_dt     DATE          NOT NULL,
    bgn_tran_dt         DATE          NOT NULL,
    end_tran_dt         DATE DEFAULT  DATE '9999-12-31' NOT NULL,
    cur_fl              NUMBER(1)     DEFAULT 1 NOT NULL,
    is_golden_fl        NUMBER(1)     DEFAULT 0 NOT NULL,
    lineage_id          VARCHAR2(30)  NOT NULL,
    CONSTRAINT pk_emissions_intensity PRIMARY KEY
        (data_item_cd, entity_key, source_id, coverage_period,
         obs_id, src_bgn_tran_dt, bgn_tran_dt)
);
```

### 5.4 Emissions Assurance — `udm_emissions_assurance` (MAP)

One row per scope per entity per period per source. Covers all five assurance concepts — `data_item_cd`
discriminates. No child list rows — scope is a direct column (not an array for assurance).

```sql
CREATE TABLE udm_emissions_assurance (
    data_item_cd            VARCHAR2(30)  NOT NULL,  -- '66100'|'66200'|'66300'|'66400'|'66500'
    entity_key              VARCHAR2(20)  NOT NULL,
    source_id               VARCHAR2(20)  NOT NULL,
    coverage_period         VARCHAR2(20)  NOT NULL,
    obs_id                  VARCHAR2(40)  DEFAULT '1' NOT NULL,  -- always '1' for MAP
    -- payload (sub-fields _a, _b, _c)
    is_assured_fl           NUMBER(1),               -- _a: verified or assured? 1=Yes 0=No
    assurance_provider_nm   VARCHAR2(200),           -- _b: who performed the verification
    covers_figure_fl        NUMBER(1),               -- _c: covers the reported figure? 1=Yes 0=No
    assurance_level_cd      VARCHAR2(30),            -- limited | reasonable
    methodology_tx          VARCHAR2(1000),          -- 66500 Scope 3 detail field
    -- bi-temporal envelope
    src_bgn_tran_dt         DATE          NOT NULL,
    src_end_tran_dt         DATE          NOT NULL,
    bgn_tran_dt             DATE          NOT NULL,
    end_tran_dt             DATE DEFAULT  DATE '9999-12-31' NOT NULL,
    cur_fl                  NUMBER(1)     DEFAULT 1 NOT NULL,
    is_golden_fl            NUMBER(1)     DEFAULT 0 NOT NULL,
    lineage_id              VARCHAR2(30)  NOT NULL,
    CONSTRAINT pk_emissions_assurance PRIMARY KEY
        (data_item_cd, entity_key, source_id, coverage_period,
         obs_id, src_bgn_tran_dt, bgn_tran_dt)
);
```

### 5.5 Emissions Target — `udm_emissions_target` (MAP or ARRAY_OF_MAP)

One row per target per entity per period per source. Covers all four target concepts.
MAP concepts (67100, 67200) have `obs_id = '1'`. ARRAY_OF_MAP concepts (67300, 67400) have
source-assigned `obs_id`. The cell key is `target_type_cd + scope_cd + target_year_nb`.
`scope_cd` is resolved from `udm_obs_scope` for ARRAY_OF_MAP, or a direct column in the view for MAP.

```sql
CREATE TABLE udm_emissions_target (
    data_item_cd            VARCHAR2(30)  NOT NULL,  -- '67100'|'67200'|'67300'|'67400'
    entity_key              VARCHAR2(20)  NOT NULL,
    source_id               VARCHAR2(20)  NOT NULL,
    coverage_period         VARCHAR2(20)  NOT NULL,
    obs_id                  VARCHAR2(40)  DEFAULT '1' NOT NULL,
    -- cell key
    target_type_cd          VARCHAR2(30)  NOT NULL,  -- RENEWABLE_ENERGY | SBTI | NET_ZERO |
                                                     -- ABSOLUTE_REDUCTION | INTENSITY_REDUCTION
    scope_cd                VARCHAR2(40)  NOT NULL,  -- combo e.g. 'S1+S2+S3'; or 'ALL' for MAP items
    target_year_nb          NUMBER(4),
    -- payload
    base_year_nb            NUMBER(4),
    base_value_nb           NUMBER,
    target_value_nb         NUMBER,
    pct_reduction_nb        NUMBER,
    pct_achieved_nb         NUMBER,
    target_status_cd        VARCHAR2(30),            -- UNDERWAY | ACHIEVED | EXPIRED | RETIRED
    is_science_based_fl     NUMBER(1),
    is_net_zero_fl          NUMBER(1),
    temperature_align_cd    VARCHAR2(20),            -- 1_5C | WB2C | 2C
    commitment_dt           DATE,                    -- 67200 SBTi commitment date
    detail_tx               VARCHAR2(4000),
    -- bi-temporal envelope
    src_bgn_tran_dt         DATE          NOT NULL,
    src_end_tran_dt         DATE          NOT NULL,
    bgn_tran_dt             DATE          NOT NULL,
    end_tran_dt             DATE DEFAULT  DATE '9999-12-31' NOT NULL,
    cur_fl                  NUMBER(1)     DEFAULT 1 NOT NULL,
    is_golden_fl            NUMBER(1)     DEFAULT 0 NOT NULL,
    lineage_id              VARCHAR2(30)  NOT NULL,
    CONSTRAINT pk_emissions_target PRIMARY KEY
        (data_item_cd, entity_key, source_id, coverage_period,
         obs_id, src_bgn_tran_dt, bgn_tran_dt)
);
```

### 5.6 Bi-temporal envelope (defined once, identical on every table)

| Column | Meaning |
|---|---|
| `src_bgn_tran_dt` / `src_end_tran_dt` | When the source asserted / superseded this version |
| `bgn_tran_dt` / `end_tran_dt` | When UDM loaded / closed this version |
| `cur_fl = 1` | Current version |
| `lineage_id` | FK to `udm_lineage` |

---

## 6. Catalog Configuration

### 6.1 `udm_data_item` (existing — records the concept and its parent table)

| data_item_cd | data_item_nm | storage_pattern_cd | target_table_nm |
|---|---|---|---|
| 65100 | Emission Intensities | STRUCT | udm_emissions_intensity |
| 66100 | Scope 1 Assurance | STRUCT | udm_emissions_assurance |
| 66200 | Scope 2 Location Assurance | STRUCT | udm_emissions_assurance |
| 66300 | Scope 2 Market Assurance | STRUCT | udm_emissions_assurance |
| 66400 | Scope 3 Assurance | STRUCT | udm_emissions_assurance |
| 66500 | Scope 3 Assurance Details | STRUCT | udm_emissions_assurance |
| 67100 | Renewable Energy Target | STRUCT | udm_emissions_target |
| 67200 | SBTi Target Commitment | STRUCT | udm_emissions_target |
| 67300 | Net Zero Targets | STRUCT | udm_emissions_target |
| 67400 | Emissions Reduction Targets | STRUCT | udm_emissions_target |

### 6.2 `udm_data_item_src_map` (existing — one row per source per target table)

`struct_shape_cd` tells the framework whether to load child list rows before the header.
Column mapping is implicit: view column names match target table column names.

| data_item_cd | source_id | struct_shape_cd | target_table_nm | src_object_nm | load_seq_nb |
|---|---|---|---|---|---|
| 65100 | ESGBOOK | ARRAY_OF_MAP | udm_obs_scope | VW_ESGBOOK_65100_SCOPE | 1 |
| 65100 | ESGBOOK | ARRAY_OF_MAP | udm_obs_category | VW_ESGBOOK_65100_CATEGORY | 1 |
| 65100 | ESGBOOK | ARRAY_OF_MAP | udm_emissions_intensity | VW_ESGBOOK_65100_HDR | 2 |
| 65100 | CDP_2024 | ARRAY_OF_MAP | udm_obs_scope | VW_CDP_65100_SCOPE | 1 |
| 65100 | CDP_2024 | ARRAY_OF_MAP | udm_obs_category | VW_CDP_65100_CATEGORY | 1 |
| 65100 | CDP_2024 | ARRAY_OF_MAP | udm_emissions_intensity | VW_CDP_65100_HDR | 2 |
| 66100 | ESGBOOK | MAP | udm_emissions_assurance | VW_ESGBOOK_66100_HDR | 1 |
| 66200 | ESGBOOK | MAP | udm_emissions_assurance | VW_ESGBOOK_66200_HDR | 1 |
| 66300 | ESGBOOK | MAP | udm_emissions_assurance | VW_ESGBOOK_66300_HDR | 1 |
| 66400 | ESGBOOK | MAP | udm_emissions_assurance | VW_ESGBOOK_66400_HDR | 1 |
| 66500 | ESGBOOK | MAP | udm_emissions_assurance | VW_ESGBOOK_66500_HDR | 1 |
| 67100 | ESGBOOK | MAP | udm_emissions_target | VW_ESGBOOK_67100_HDR | 1 |
| 67200 | ESGBOOK | MAP | udm_emissions_target | VW_ESGBOOK_67200_HDR | 1 |
| 67300 | ESGBOOK | ARRAY_OF_MAP | udm_obs_scope | VW_ESGBOOK_67300_SCOPE | 1 |
| 67300 | ESGBOOK | ARRAY_OF_MAP | udm_emissions_target | VW_ESGBOOK_67300_HDR | 2 |
| 67400 | ESGBOOK | ARRAY_OF_MAP | udm_obs_scope | VW_ESGBOOK_67400_SCOPE | 1 |
| 67400 | ESGBOOK | ARRAY_OF_MAP | udm_emissions_target | VW_ESGBOOK_67400_HDR | 2 |

### 6.3 `udm_data_item_constituent` (new — makes the catalog self-describing)

Registers what dimensions define a cell for each concept. A consumer understands the structure
from the catalog without reading DDL.

```sql
CREATE TABLE udm_data_item_constituent (
    data_item_cd        VARCHAR2(30)  NOT NULL,
    constituent_cd      VARCHAR2(30)  NOT NULL,   -- SCOPE | CATEGORY | TARGET_TYPE | TARGET_YEAR
    constituent_nm      VARCHAR2(200) NOT NULL,
    list_table_nm       VARCHAR2(80),             -- child table when constituent is an array; NULL for MAP
    hdr_column_nm       VARCHAR2(80)  NOT NULL,   -- resolved column on the header table
    is_cell_key_fl      NUMBER(1)     DEFAULT 0,  -- 1 = part of the cell identity
    code_type_cd        VARCHAR2(30),             -- vocabulary in udm_src_code_map
    constituent_seq_nb  NUMBER(2)     NOT NULL,
    CONSTRAINT pk_data_item_constituent PRIMARY KEY (data_item_cd, constituent_cd)
);
```

| data_item_cd | constituent_cd | list_table_nm | hdr_column_nm | is_cell_key_fl | code_type_cd |
|---|---|---|---|---|---|
| 65100 | SCOPE | udm_obs_scope | scope_cd | 1 | SCOPE |
| 65100 | CATEGORY | udm_obs_category | category_cd | 1 | DENOMINATOR |
| 66100 | SCOPE | (null — MAP, direct column) | data_item_cd | 1 | (null) |
| 67100 | TARGET_TYPE | (null) | target_type_cd | 1 | TARGET_TYPE |
| 67300 | TARGET_TYPE | (null) | target_type_cd | 1 | TARGET_TYPE |
| 67300 | SCOPE | udm_obs_scope | scope_cd | 1 | SCOPE |
| 67300 | TARGET_YEAR | (null) | target_year_nb | 1 | (null) |
| 67400 | TARGET_TYPE | (null) | target_type_cd | 1 | TARGET_TYPE |
| 67400 | SCOPE | udm_obs_scope | scope_cd | 1 | SCOPE |
| 67400 | TARGET_YEAR | (null) | target_year_nb | 1 | (null) |

### 6.4 `udm_src_code_map` (new — label to canonical, used only inside views)

```sql
CREATE TABLE udm_src_code_map (
    source_id       VARCHAR2(20)  NOT NULL,
    code_type_cd    VARCHAR2(30)  NOT NULL,   -- SCOPE | DENOMINATOR | TARGET_TYPE | ASSURANCE_LEVEL
    src_label_tx    VARCHAR2(200) NOT NULL,   -- exactly as the source delivers it
    canonical_cd    VARCHAR2(40)  NOT NULL,
    is_active_fl    NUMBER(1)     DEFAULT 1 NOT NULL,
    CONSTRAINT pk_src_code_map PRIMARY KEY (source_id, code_type_cd, src_label_tx)
);
```

Sample seed rows:

| source_id | code_type_cd | src_label_tx | canonical_cd |
|---|---|---|---|
| ESGBOOK | SCOPE | Scope1 | S1 |
| ESGBOOK | SCOPE | Scope2 | S2 |
| ESGBOOK | SCOPE | Scope3 | S3 |
| ESGBOOK | DENOMINATOR | Revenue | REVENUE |
| ESGBOOK | DENOMINATOR | MWhGenerated | MWH_GENERATED |
| ESGBOOK | TARGET_TYPE | NetZero | NET_ZERO |
| ESGBOOK | TARGET_TYPE | AbsoluteReduction | ABSOLUTE_REDUCTION |
| ESGBOOK | ASSURANCE_LEVEL | Limited | LIMITED |
| ESGBOOK | ASSURANCE_LEVEL | Reasonable | REASONABLE |
| CDP_2024 | SCOPE | Scope 1 | S1 |
| CDP_2024 | SCOPE | Scope 2 (location-based) | S2 |
| CDP_2024 | DENOMINATOR | unit total revenue | REVENUE |
| CDP_2024 | TARGET_TYPE | Absolute | ABSOLUTE_REDUCTION |
| CDP_2024 | TARGET_TYPE | Net-zero | NET_ZERO |

**Quarantine rule:** a label with no row here yields NULL on a NOT NULL cell-key column and fails
the load. It is written to `udm_load_reject_log`. Adding a missing label is an INSERT — no code change.

---

## 7. Source View Contract

### 7.1 Rules

1. View projected column names **match the target table's business columns exactly**.
2. All canonicalization happens inside the view — canonical codes out, raw labels never reach a fact table.
3. Plain `SELECT` only. No procedural code, no DML.
4. Handle whichever RDM physical shape exists (§7.2).

### 7.2 Two RDM shapes — identical output

**Shape A — array stored as relational rows:**
```sql
CREATE OR REPLACE VIEW vw_esgbook_65100_scope AS
SELECT  '65100'              AS data_item_cd,
        r.entity_key,
        r.coverage_period,
        r.observation_id     AS obs_id,
        r.scope_position     AS item_no,
        m.canonical_cd       AS scope_cd
FROM    rdm_esgbook_ei_scope r
JOIN    udm_src_code_map m
          ON  m.source_id     = 'ESGBOOK'
          AND m.code_type_cd  = 'SCOPE'
          AND m.src_label_tx  = r.scope_label;
```

**Shape B — array stored as JSON column:**
```sql
CREATE OR REPLACE VIEW vw_esgbook_65100_scope AS
SELECT  '65100'              AS data_item_cd,
        r.entity_key,
        r.coverage_period,
        j.obs_id,
        j.item_no,
        m.canonical_cd       AS scope_cd
FROM    rdm_esgbook_ei_raw r
CROSS JOIN JSON_TABLE(
            r.payload_json, '$.intensities[*]'
            COLUMNS (
                obs_id  VARCHAR2(40)  PATH '$.id',
                NESTED PATH '$.scopes[*]'
                    COLUMNS (
                        item_no   FOR ORDINALITY,
                        scope_lbl VARCHAR2(80) PATH '$'
                    )
            )
        ) j
JOIN    udm_src_code_map m
          ON  m.source_id     = 'ESGBOOK'
          AND m.code_type_cd  = 'SCOPE'
          AND m.src_label_tx  = j.scope_lbl;
```

Both produce the same output. The framework cannot tell which shape was used.

### 7.3 Header view — ARRAY_OF_MAP (emission intensity, 65100)

The `scope_cd` combo is computed by ordered concatenation of canonical scope elements
already loaded into `udm_obs_scope`. No update required — computed at SELECT time, inserted once.

```sql
CREATE OR REPLACE VIEW vw_esgbook_65100_hdr AS
SELECT  '65100'                                                   AS data_item_cd,
        h.entity_key,
        h.coverage_period,
        h.observation_id                                          AS obs_id,
        -- scope combo: ordered concat of canonical scope elements
        ( SELECT LISTAGG(s.scope_cd, '+') WITHIN GROUP (ORDER BY s.scope_cd)
          FROM   udm_obs_scope s
          WHERE  s.data_item_cd    = '65100'
          AND    s.entity_key      = h.entity_key
          AND    s.source_id       = 'ESGBOOK'
          AND    s.coverage_period = h.coverage_period
          AND    s.obs_id          = h.observation_id
          AND    s.cur_fl          = 1 )                          AS scope_cd,
        cat.canonical_cd                                          AS category_cd,
        h.intensity_value                                         AS value_nb,
        h.intensity_unit                                          AS value_unit_cd
FROM    rdm_esgbook_ei h
JOIN    udm_src_code_map cat
          ON  cat.source_id    = 'ESGBOOK'
          AND cat.code_type_cd = 'DENOMINATOR'
          AND cat.src_label_tx = h.denominator_label;
```

### 7.4 Header view — MAP (assurance, 66100–66500)

No child list rows. Scope is the concept itself (`data_item_cd`). All fields are direct columns.
`obs_id` is hardcoded `'1'` — there is only one assurance record per concept per entity per period.

```sql
CREATE OR REPLACE VIEW vw_esgbook_66100_hdr AS
SELECT  '66100'                       AS data_item_cd,
        r.entity_key,
        r.coverage_period,
        '1'                           AS obs_id,
        r.is_verified                 AS is_assured_fl,
        r.verifier_name               AS assurance_provider_nm,
        r.covers_figure               AS covers_figure_fl,
        al.canonical_cd               AS assurance_level_cd,
        NULL                          AS methodology_tx
FROM    rdm_esgbook_assurance r
JOIN    udm_src_code_map al
          ON  al.source_id    = 'ESGBOOK'
          AND al.code_type_cd = 'ASSURANCE_LEVEL'
          AND al.src_label_tx = r.assurance_level
WHERE   r.scope_type = 'Scope1';
```

Views for 66200–66500 follow the same pattern, differing only in `data_item_cd` value and the
`WHERE r.scope_type` filter.

### 7.5 Header view — ARRAY_OF_MAP (net zero targets, 67300)

Same pattern as intensity — `LISTAGG` from `udm_obs_scope` for the scope combo.

```sql
CREATE OR REPLACE VIEW vw_esgbook_67300_hdr AS
SELECT  '67300'                                                   AS data_item_cd,
        t.entity_key,
        t.coverage_period,
        t.target_id                                               AS obs_id,
        tt.canonical_cd                                           AS target_type_cd,
        ( SELECT LISTAGG(s.scope_cd, '+') WITHIN GROUP (ORDER BY s.scope_cd)
          FROM   udm_obs_scope s
          WHERE  s.data_item_cd    = '67300'
          AND    s.entity_key      = t.entity_key
          AND    s.source_id       = 'ESGBOOK'
          AND    s.coverage_period = t.coverage_period
          AND    s.obs_id          = t.target_id
          AND    s.cur_fl          = 1 )                          AS scope_cd,
        t.target_year                                             AS target_year_nb,
        t.base_year                                               AS base_year_nb,
        t.base_emissions                                          AS base_value_nb,
        t.target_emissions                                        AS target_value_nb,
        t.pct_reduction                                           AS pct_reduction_nb,
        t.pct_achieved                                            AS pct_achieved_nb,
        t.status                                                  AS target_status_cd,
        t.sbti_flag                                               AS is_science_based_fl,
        1                                                         AS is_net_zero_fl,
        t.temp_alignment                                          AS temperature_align_cd,
        NULL                                                      AS commitment_dt,
        t.description                                             AS detail_tx
FROM    rdm_esgbook_target t
JOIN    udm_src_code_map tt
          ON  tt.source_id    = 'ESGBOOK'
          AND tt.code_type_cd = 'TARGET_TYPE'
          AND tt.src_label_tx = t.target_type_label
WHERE   t.target_category = 'NetZero';
```

### 7.6 Header view — MAP (SBTi commitment, 67200)

MAP variant — `obs_id = '1'`, scope as a direct column, no `LISTAGG`.

```sql
CREATE OR REPLACE VIEW vw_esgbook_67200_hdr AS
SELECT  '67200'                       AS data_item_cd,
        r.entity_key,
        r.coverage_period,
        '1'                           AS obs_id,
        'SBTI'                        AS target_type_cd,
        'S1+S2+S3'                    AS scope_cd,    -- SBTi always covers all scopes
        r.target_year                 AS target_year_nb,
        r.base_year                   AS base_year_nb,
        NULL                          AS base_value_nb,
        NULL                          AS target_value_nb,
        r.pct_reduction               AS pct_reduction_nb,
        NULL                          AS pct_achieved_nb,
        r.status                      AS target_status_cd,
        1                             AS is_science_based_fl,
        0                             AS is_net_zero_fl,
        r.temperature_alignment       AS temperature_align_cd,
        r.commitment_date             AS commitment_dt,
        r.description                 AS detail_tx
FROM    rdm_esgbook_sbti r;
```

---

## 8. Load Mechanics (Framework)

The framework executes the same routine for every STRUCT data item, driven by `udm_data_item_src_map`.

```
FOR each (data_item_cd, source_id) WHERE storage_pattern_cd = 'STRUCT':
    FOR each map row ORDER BY load_seq_nb:
        -- list tables load first (seq 1), header loads second (seq 2)

        IF struct_shape_cd = 'MAP' AND target is a list table → SKIP (no list rows for MAP)

        target_table = map.target_table_nm
        source_view  = map.src_object_nm

        -- Step 1: SCD2 close — version out rows whose business columns changed
        --         (this is a versioning operation, not a business-data update)
        UPDATE {target_table}
        SET    end_tran_dt = :run_dt,
               cur_fl      = 0
        WHERE  cur_fl = 1
        AND    (data_item_cd, entity_key, source_id, coverage_period, obs_id [, item_no])
               IN ( rows present in live table but changed vs {source_view} )

        -- Step 2: Insert new and changed rows
        INSERT INTO {target_table} (data_item_cd, business columns, bi-temporal envelope)
        SELECT v.*,
               :src_bgn_dt,  DATE '9999-12-31',
               :run_dt,      DATE '9999-12-31',
               1,            :lineage_id
        FROM   {source_view} v
        WHERE  row is new or changed

        -- Step 3: Reject rows with NULL on any NOT NULL cell-key column
        INSERT INTO udm_load_reject_log (...)
        SELECT ..., 'UNMAPPED_LABEL' AS reject_reason_cd
        FROM   {source_view}
        WHERE  scope_cd IS NULL OR category_cd IS NULL OR target_type_cd IS NULL
```

**Rules for the implementer:**
- The only `UPDATE` is the SCD2 close of `end_tran_dt` and `cur_fl`. Business columns are never
  patched after insert. Reuse the existing UDM SCD2 close routine.
- All processing is **set-based**. No cursors or row loops.
- "Changed row" detection compares the view's current output to live (`cur_fl = 1`) rows on
  business columns — reuse the existing UDM change-detection routine.
- For ARRAY_OF_MAP headers: the `LISTAGG` in the header view reads the already-loaded list rows
  (`cur_fl = 1`). This is why list tables must load first (`load_seq_nb = 1`).

---

## 9. Arbitration

Runs after all sources are loaded for a data item. Operates **at cell level on the header only**.
List rows inherit golden status from their header via join — they have no `is_golden_fl` of their own.

Cell keys by concept:

| Table | Cell key columns |
|---|---|
| `udm_emissions_intensity` | `data_item_cd, entity_key, coverage_period, scope_cd, category_cd` |
| `udm_emissions_assurance` | `data_item_cd, entity_key, coverage_period` (one per concept per period) |
| `udm_emissions_target` | `data_item_cd, entity_key, coverage_period, target_type_cd, scope_cd, target_year_nb` |

```sql
-- Example: intensity arbitration
MERGE INTO udm_emissions_intensity h
USING (
    SELECT  ROWID AS rid,
            RANK() OVER (
                PARTITION BY data_item_cd, entity_key, coverage_period, scope_cd, category_cd
                ORDER BY p.priority_nb
            ) AS rnk
    FROM    udm_emissions_intensity x
    JOIN    udm_precedence_rules p
              ON  p.data_item_cd = x.data_item_cd
              AND p.source_id    = x.source_id
    WHERE   x.cur_fl = 1
) r ON (h.ROWID = r.rid)
WHEN MATCHED THEN UPDATE
    SET h.is_golden_fl = CASE WHEN r.rnk = 1 THEN 1 ELSE 0 END;
```

`is_golden_fl` is the **only** column arbitration touches. Each cell is arbitrated independently —
ESGbook may win `S1+S2 / REVENUE` while CDP wins `S1+S2+S3 / REVENUE`.

Consumer views always filter: `is_golden_fl = 1 AND cur_fl = 1`.

---

## 10. Adding a New Source — Developer Checklist

Zero framework or DDL changes required:

1. Register in `udm_source_registry`.
2. Insert label rows into `udm_src_code_map` for the source's scope, denominator, and target-type labels.
3. Create source views (one per target table) following the §7 contract.
4. Insert rows into `udm_data_item_src_map` — one row per target table, pointing to its view.
5. Insert precedence rule into `udm_precedence_rules`.

---

## 11. Complete Object Summary

### Physical tables (fact)

| Table | Concepts | Shape handled |
|---|---|---|
| `udm_emissions_intensity` | 65100 | ARRAY_OF_MAP |
| `udm_emissions_assurance` | 66100, 66200, 66300, 66400, 66500 | MAP |
| `udm_emissions_target` | 67100, 67200, 67300, 67400 | MAP and ARRAY_OF_MAP |
| `udm_obs_scope` | Any concept with scope array | Shared child |
| `udm_obs_category` | Any concept with category array | Shared child |

### Catalog tables

| Table | New / Existing | Role |
|---|---|---|
| `udm_data_item` | Existing | Concept, storage pattern, parent header table |
| `udm_data_item_src_map` | Existing + `struct_shape_cd` column | Source → target table → view → shape |
| `udm_data_item_constituent` | New | Self-describing cell dimensions per concept |
| `udm_src_code_map` | New | Source label → canonical code (used in views only) |

### Source views

| View naming pattern | Count | Role |
|---|---|---|
| `VW_{SOURCE}_{DATA_ITEM_CD}_SCOPE` | Per ARRAY_OF_MAP source | Feeds `udm_obs_scope` |
| `VW_{SOURCE}_{DATA_ITEM_CD}_CATEGORY` | Per ARRAY_OF_MAP source with categories | Feeds `udm_obs_category` |
| `VW_{SOURCE}_{DATA_ITEM_CD}_HDR` | Per source per concept | Feeds header table |

### Design guarantees

| Guarantee | How met |
|---|---|
| Insert-only for business data | No UPDATE on business columns; only SCD2 versioning close |
| Bi-temporal history | Full envelope on every table including list tables |
| Single golden value per cell | Cell-level arbitration sets `is_golden_fl` on header |
| Full source lineage | List tables hold canonical array elements as received |
| Catalog self-describes structure | `udm_data_item_constituent` registers cell dimensions |
| New source = config only | Insert into `udm_src_code_map` + `udm_data_item_src_map`; create views |
| No table proliferation | Payload shape drives table assignment; `data_item_cd` discriminates |
