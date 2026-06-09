# UDM Structured Data Item Spec v2
**Audience:** UDM dev team | **Sources:** ESGbook (65100,66100–66500,67100–67400), CDP 2024
**Concepts:** Emission Intensities · Scope Assurance ×5 · Renewable Energy Target · SBTi Commitment · Net Zero Targets · Emissions Reduction Targets

---

## CONVENTIONS USED IN THIS DOCUMENT
```
[ENV]   = bi-temporal envelope columns (defined once in §5.E — never repeated in seed data)
[PK]    = primary key constraint
[FK→X]  = foreign key to table X
DRV     = derivation_cd shorthand: D=DIRECT C=CONSTANT L=CANONICAL_LOOKUP S=SCOPE_COMBO F=DERIVED_FLAG N=NULL_PLACEHOLDER
REPEAT(x,cols) = apply same col-map block as concept x, substituting only listed cols
```

---

## 1. CORE RULES

1. One normalized view per target table. Column mapping is **explicit and catalogued** (`udm_data_item_src_col_map`). Name-equality between view and target column is a **convention**, not a load dependency.
2. Framework loads insert-only. No post-load updates to business columns.
3. No procedural row-routing logic in the framework.
4. Source complexity (relational rows / pipe-delimited / JSON) absorbed **inside the view**. Framework never sees it.
5. Table names reflect business concept, never storage pattern. No table name contains "struct".
6. Mapping rows are **mandatory and complete** — no implicit fallback. No row = column not loaded.
7. Bi-temporal envelope columns are **never** in `udm_data_item_src_col_map`. Framework appends them universally.

---

## 2. TWO SHAPES

| shape_cd | meaning | child list rows? | obs_id |
|---|---|---|---|
| MAP | 1 obs per entity/period — fixed fields | none | hardcoded `'1'` |
| ARRAY_OF_MAP | N obs per entity/period | udm_obs_scope / udm_obs_category (seq=1) | source-assigned |

`struct_shape_cd` on `udm_data_item_src_map` drives path. List tables always load before header (`load_seq_nb` 1 → 2). This is why LISTAGG in the header view can read already-loaded scope rows.

---

## 3. LOAD FLOW
```
RDM (relational or JSON)
  └─► SOURCE VIEWS [all canonicalization: label→canonical, scope combo, typing]
        └─► FRAMEWORK [insert-only, bi-temporal envelope appended]
              order: load_seq_nb=1 (list tables) → load_seq_nb=2 (header)
              column order: col_seq_nb from udm_data_item_src_col_map
                  └─► FACT TABLES ──► ARBITRATION (is_golden_fl, header only)
                                            └─► CONSUMER VIEWS [cur_fl=1 AND is_golden_fl=1]
```

---

## 4. BI-TEMPORAL ENVELOPE [ENV] — identical on every table

| column | type | meaning |
|---|---|---|
| src_bgn_tran_dt | DATE NOT NULL | source asserted this version |
| src_end_tran_dt | DATE NOT NULL | source superseded this version |
| bgn_tran_dt | DATE NOT NULL | UDM loaded this version |
| end_tran_dt | DATE DEFAULT DATE '9999-12-31' NOT NULL | UDM closed this version |
| cur_fl | NUMBER(1) DEFAULT 1 NOT NULL | current version flag |
| lineage_id | VARCHAR2(30) NOT NULL | FK → udm_lineage |

Header tables also carry: `is_golden_fl NUMBER(1) DEFAULT 0 NOT NULL`
List tables do NOT carry `is_golden_fl` — they inherit golden status from header via join.

---

## 5. DDL — PHYSICAL TABLES

### 5.1 udm_obs_scope
```sql
CREATE TABLE udm_obs_scope (
    data_item_cd    VARCHAR2(30)  NOT NULL,  -- '65100'|'67300'|'67400'
    entity_key      VARCHAR2(20)  NOT NULL,
    source_id       VARCHAR2(20)  NOT NULL,
    coverage_period VARCHAR2(20)  NOT NULL,
    obs_id          VARCHAR2(40)  NOT NULL,
    item_no         NUMBER(4)     NOT NULL,  -- 1-based array position
    scope_cd        VARCHAR2(10)  NOT NULL,  -- S1|S2|S3
    [ENV],
    [PK](data_item_cd,entity_key,source_id,coverage_period,obs_id,item_no,src_bgn_tran_dt,bgn_tran_dt)
);
```

### 5.2 udm_obs_category
```sql
CREATE TABLE udm_obs_category (
    data_item_cd    VARCHAR2(30)  NOT NULL,
    entity_key      VARCHAR2(20)  NOT NULL,
    source_id       VARCHAR2(20)  NOT NULL,
    coverage_period VARCHAR2(20)  NOT NULL,
    obs_id          VARCHAR2(40)  NOT NULL,
    item_no         NUMBER(4)     NOT NULL,
    category_cd     VARCHAR2(40)  NOT NULL,  -- REVENUE|MWH_GENERATED|...
    [ENV],
    [PK](data_item_cd,entity_key,source_id,coverage_period,obs_id,item_no,src_bgn_tran_dt,bgn_tran_dt)
);
```

### 5.3 udm_emissions_intensity  [ARRAY_OF_MAP | cell key: scope_cd+category_cd]
```sql
CREATE TABLE udm_emissions_intensity (
    data_item_cd    VARCHAR2(30)  DEFAULT '65100' NOT NULL,
    entity_key      VARCHAR2(20)  NOT NULL,
    source_id       VARCHAR2(20)  NOT NULL,
    coverage_period VARCHAR2(20)  NOT NULL,
    obs_id          VARCHAR2(40)  NOT NULL,
    scope_cd        VARCHAR2(40)  NOT NULL,  -- combo e.g. 'S1+S2' — resolved via LISTAGG in view
    category_cd     VARCHAR2(40)  NOT NULL,  -- e.g. REVENUE|MWH_GENERATED
    value_nb        NUMBER        NOT NULL,
    value_unit_cd   VARCHAR2(40),
    [ENV + is_golden_fl],
    [PK](data_item_cd,entity_key,source_id,coverage_period,obs_id,src_bgn_tran_dt,bgn_tran_dt)
);
```

### 5.4 udm_emissions_assurance  [MAP | cell key: data_item_cd+entity_key+coverage_period]
```sql
CREATE TABLE udm_emissions_assurance (
    data_item_cd            VARCHAR2(30)  NOT NULL,  -- '66100'|'66200'|'66300'|'66400'|'66500'
    entity_key              VARCHAR2(20)  NOT NULL,
    source_id               VARCHAR2(20)  NOT NULL,
    coverage_period         VARCHAR2(20)  NOT NULL,
    obs_id                  VARCHAR2(40)  DEFAULT '1' NOT NULL,
    is_assured_fl           NUMBER(1),       -- _a
    assurance_provider_nm   VARCHAR2(200),   -- _b
    covers_figure_fl        NUMBER(1),       -- _c
    assurance_level_cd      VARCHAR2(30),    -- LIMITED|REASONABLE
    methodology_tx          VARCHAR2(1000),  -- populated for 66500 only
    [ENV + is_golden_fl],
    [PK](data_item_cd,entity_key,source_id,coverage_period,obs_id,src_bgn_tran_dt,bgn_tran_dt)
);
```

### 5.5 udm_emissions_target  [MAP(67100,67200) or ARRAY_OF_MAP(67300,67400) | cell key: target_type_cd+scope_cd+target_year_nb]
```sql
CREATE TABLE udm_emissions_target (
    data_item_cd         VARCHAR2(30)  NOT NULL,  -- '67100'|'67200'|'67300'|'67400'
    entity_key           VARCHAR2(20)  NOT NULL,
    source_id            VARCHAR2(20)  NOT NULL,
    coverage_period      VARCHAR2(20)  NOT NULL,
    obs_id               VARCHAR2(40)  DEFAULT '1' NOT NULL,
    target_type_cd       VARCHAR2(30)  NOT NULL,  -- RENEWABLE_ENERGY|SBTI|NET_ZERO|ABSOLUTE_REDUCTION|INTENSITY_REDUCTION
    scope_cd             VARCHAR2(40)  NOT NULL,  -- combo 'S1+S2+S3'; 'ALL' for MAP
    target_year_nb       NUMBER(4),
    base_year_nb         NUMBER(4),
    base_value_nb        NUMBER,
    target_value_nb      NUMBER,
    pct_reduction_nb     NUMBER,
    pct_achieved_nb      NUMBER,
    target_status_cd     VARCHAR2(30),  -- UNDERWAY|ACHIEVED|EXPIRED|RETIRED
    is_science_based_fl  NUMBER(1),
    is_net_zero_fl       NUMBER(1),
    temperature_align_cd VARCHAR2(20),  -- 1_5C|WB2C|2C
    commitment_dt        DATE,          -- 67200 only
    detail_tx            VARCHAR2(4000),
    [ENV + is_golden_fl],
    [PK](data_item_cd,entity_key,source_id,coverage_period,obs_id,src_bgn_tran_dt,bgn_tran_dt)
);
```

---

## 6. DDL — CATALOG TABLES

### 6.1 udm_data_item (existing)
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

### 6.2 udm_data_item_src_map (existing + struct_shape_cd)
> Column mapping is **explicit via udm_data_item_src_col_map** (§6.5). Name-equality between view and target is convention only.

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

### 6.3 udm_data_item_constituent (new)
```sql
CREATE TABLE udm_data_item_constituent (
    data_item_cd       VARCHAR2(30)  NOT NULL,
    constituent_cd     VARCHAR2(30)  NOT NULL,  -- SCOPE|CATEGORY|TARGET_TYPE|TARGET_YEAR
    constituent_nm     VARCHAR2(200) NOT NULL,
    list_table_nm      VARCHAR2(80),            -- NULL for MAP constituents
    hdr_column_nm      VARCHAR2(80)  NOT NULL,
    is_cell_key_fl     NUMBER(1)     DEFAULT 0,
    code_type_cd       VARCHAR2(30),            -- vocabulary in udm_src_code_map
    constituent_seq_nb NUMBER(2)     NOT NULL,
    [PK](data_item_cd,constituent_cd)
);
```

| data_item_cd | constituent_cd | list_table_nm | hdr_column_nm | is_cell_key_fl | code_type_cd |
|---|---|---|---|---|---|
| 65100 | SCOPE | udm_obs_scope | scope_cd | 1 | SCOPE |
| 65100 | CATEGORY | udm_obs_category | category_cd | 1 | DENOMINATOR |
| 66100 | SCOPE | null | data_item_cd | 1 | null |
| 67100 | TARGET_TYPE | null | target_type_cd | 1 | TARGET_TYPE |
| 67300 | TARGET_TYPE | null | target_type_cd | 1 | TARGET_TYPE |
| 67300 | SCOPE | udm_obs_scope | scope_cd | 1 | SCOPE |
| 67300 | TARGET_YEAR | null | target_year_nb | 1 | null |
| 67400 | TARGET_TYPE | null | target_type_cd | 1 | TARGET_TYPE |
| 67400 | SCOPE | udm_obs_scope | scope_cd | 1 | SCOPE |
| 67400 | TARGET_YEAR | null | target_year_nb | 1 | null |

### 6.4 udm_src_code_map (new)
```sql
CREATE TABLE udm_src_code_map (
    source_id      VARCHAR2(20)  NOT NULL,
    code_type_cd   VARCHAR2(30)  NOT NULL,  -- SCOPE|DENOMINATOR|TARGET_TYPE|ASSURANCE_LEVEL
    src_label_tx   VARCHAR2(200) NOT NULL,  -- exactly as source delivers it
    canonical_cd   VARCHAR2(40)  NOT NULL,
    is_active_fl   NUMBER(1)     DEFAULT 1 NOT NULL,
    [PK](source_id,code_type_cd,src_label_tx)
);
```

**Quarantine rule:** label with no row → NULL on NOT NULL cell-key column → load rejected to `udm_load_reject_log`. Fix = INSERT, no code change.

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

### 6.5 udm_col_derivation (new — governed vocabulary for col-map lineage)
```sql
CREATE TABLE udm_col_derivation (
    derivation_cd  VARCHAR2(30)  NOT NULL,
    derivation_nm  VARCHAR2(120) NOT NULL,
    description_tx VARCHAR2(400) NOT NULL,
    is_active_fl   NUMBER(1)     DEFAULT 1 NOT NULL,
    [PK](derivation_cd)
);
```

| derivation_cd | derivation_nm | description_tx |
|---|---|---|
| DIRECT | Direct copy | Straight copy, no transform. Default convention (name-equal). |
| CONSTANT | Literal constant | Hardcoded literal in view (e.g. `'65100'`, `'1'`). |
| CANONICAL_LOOKUP | Canonical code lookup | Source label resolved via udm_src_code_map join. |
| SCOPE_COMBO | Scope concatenation | Ordered LISTAGG of canonical scopes from udm_obs_scope. |
| DERIVED_FLAG | Derived flag | Boolean derived in view from concept branch (e.g. `1 AS is_net_zero_fl`). |
| NULL_PLACEHOLDER | Not supplied | Source does not carry this column for this concept; view projects NULL. |

### 6.6 udm_data_item_src_col_map (new — explicit col-level load contract + lineage register)
```sql
CREATE TABLE udm_data_item_src_col_map (
    data_item_cd      VARCHAR2(30)  NOT NULL,
    source_id         VARCHAR2(20)  NOT NULL,
    target_table_nm   VARCHAR2(80)  NOT NULL,
    target_col_nm     VARCHAR2(80)  NOT NULL,  -- named business column on target table
    view_col_nm       VARCHAR2(80)  NOT NULL,  -- projected element from source view
    col_seq_nb        NUMBER(3)     NOT NULL,  -- deterministic INSERT column order
    derivation_cd     VARCHAR2(30)  NOT NULL,
    transform_note_tx VARCHAR2(400),           -- required for non-DIRECT rows
    is_active_fl      NUMBER(1)     DEFAULT 1 NOT NULL,
    [PK](data_item_cd,source_id,target_table_nm,target_col_nm),
    [FK→udm_data_item_src_map](data_item_cd,source_id,target_table_nm),
    [FK→udm_col_derivation](derivation_cd)
);
```

**Rules:**
- One row per business column per (data_item_cd, source_id, target_table_nm). No row = column not loaded.
- Envelope columns (`src_bgn_tran_dt` … `lineage_id`) never appear here — framework appends them.
- `col_seq_nb` governs column order within INSERT. Independent of `load_seq_nb` (table order).

**Deploy-time validation (run before any load):**
```sql
-- (1) Every mapped target_col_nm must physically exist on the table
SELECT m.* FROM udm_data_item_src_col_map m
LEFT JOIN all_tab_columns c
  ON c.table_name=UPPER(m.target_table_nm) AND c.column_name=UPPER(m.target_col_nm)
WHERE m.is_active_fl=1 AND c.column_name IS NULL;  -- any row = FAIL

-- (2) Impact analysis: which target columns does a renamed source element affect?
SELECT target_table_nm,target_col_nm,derivation_cd
FROM udm_data_item_src_col_map
WHERE source_id=:src AND view_col_nm=:renamed_element;
```

---

## 7. SEED DATA — udm_data_item_src_col_map

**Notation:** `seq | target_col | view_col | DRV | note`
Envelope columns omitted. Where `view_col = target_col` and note is empty, only differences shown.
DRV codes: D=DIRECT C=CONSTANT L=CANONICAL_LOOKUP S=SCOPE_COMBO F=DERIVED_FLAG N=NULL_PLACEHOLDER

### 7.A List table column map — template (7 cols, used by all ARRAY_OF_MAP scope feeds)

Target: `udm_obs_scope` | Apply to: 65100/ESGBOOK · 65100/CDP_2024 · 67300/ESGBOOK · 67400/ESGBOOK
(substitute data_item_cd literal and source_id literal per feed)

| seq | target_col | view_col | DRV | note |
|---|---|---|---|---|
| 1 | data_item_cd | data_item_cd | C | literal per concept |
| 2 | entity_key | entity_key | D | |
| 3 | source_id | source_id | C | literal per source |
| 4 | coverage_period | coverage_period | D | |
| 5 | obs_id | obs_id | D | |
| 6 | item_no | item_no | D | 1-based array position |
| 7 | scope_cd | scope_cd | L | udm_src_code_map SCOPE |

Target: `udm_obs_category` | Apply to: 65100/ESGBOOK · 65100/CDP_2024

| seq | target_col | view_col | DRV | note |
|---|---|---|---|---|
| 1 | data_item_cd | data_item_cd | C | literal per concept |
| 2 | entity_key | entity_key | D | |
| 3 | source_id | source_id | C | literal per source |
| 4 | coverage_period | coverage_period | D | |
| 5 | obs_id | obs_id | D | |
| 6 | item_no | item_no | D | 1-based array position |
| 7 | category_cd | category_cd | L | udm_src_code_map DENOMINATOR |

### 7.B 65100 / ESGBOOK + CDP_2024 → udm_emissions_intensity

| seq | target_col | view_col | DRV | note |
|---|---|---|---|---|
| 1 | data_item_cd | data_item_cd | C | literal '65100' |
| 2 | entity_key | entity_key | D | |
| 3 | source_id | source_id | C | literal per source |
| 4 | coverage_period | coverage_period | D | |
| 5 | obs_id | obs_id | D | |
| 6 | scope_cd | scope_cd | S | LISTAGG udm_obs_scope cur_fl=1 |
| 7 | category_cd | category_cd | L | udm_src_code_map DENOMINATOR |
| 8 | value_nb | value_nb | D | |
| 9 | value_unit_cd | value_unit_cd | D | |

### 7.C 66100–66500 / ESGBOOK → udm_emissions_assurance

Base block (apply to 66100,66200,66300,66400 — methodology_tx=N):

| seq | target_col | view_col | DRV | note |
|---|---|---|---|---|
| 1 | data_item_cd | data_item_cd | C | literal per concept |
| 2 | entity_key | entity_key | D | |
| 3 | source_id | source_id | C | literal 'ESGBOOK' |
| 4 | coverage_period | coverage_period | D | |
| 5 | obs_id | obs_id | C | literal '1' (MAP) |
| 6 | is_assured_fl | is_assured_fl | D | sub-field _a |
| 7 | assurance_provider_nm | assurance_provider_nm | D | sub-field _b |
| 8 | covers_figure_fl | covers_figure_fl | D | sub-field _c |
| 9 | assurance_level_cd | assurance_level_cd | L | udm_src_code_map ASSURANCE_LEVEL |
| 10 | methodology_tx | methodology_tx | N | NULL for 66100–66400 |

66500 override: row 10 → DRV=D (Scope 3 detail field is supplied by source).

### 7.D 67100 / ESGBOOK → udm_emissions_target  [MAP — RENEWABLE_ENERGY]

| seq | target_col | view_col | DRV | note |
|---|---|---|---|---|
| 1 | data_item_cd | data_item_cd | C | '67100' |
| 2 | entity_key | entity_key | D | |
| 3 | source_id | source_id | C | 'ESGBOOK' |
| 4 | coverage_period | coverage_period | D | |
| 5 | obs_id | obs_id | C | '1' |
| 6 | target_type_cd | target_type_cd | C | 'RENEWABLE_ENERGY' |
| 7 | scope_cd | scope_cd | C | 'ALL' |
| 8 | target_year_nb | target_year_nb | D | |
| 9 | base_year_nb | base_year_nb | D | |
| 10 | base_value_nb | base_value_nb | D | |
| 11 | target_value_nb | target_value_nb | D | |
| 12 | pct_reduction_nb | pct_reduction_nb | D | |
| 13 | pct_achieved_nb | pct_achieved_nb | D | |
| 14 | target_status_cd | target_status_cd | D | |
| 15 | is_science_based_fl | is_science_based_fl | F | 0 |
| 16 | is_net_zero_fl | is_net_zero_fl | F | 0 |
| 17 | temperature_align_cd | temperature_align_cd | N | |
| 18 | commitment_dt | commitment_dt | N | |
| 19 | detail_tx | detail_tx | D | |

### 7.E 67200 / ESGBOOK → udm_emissions_target  [MAP — SBTI]

REPEAT(67100) with these overrides:

| seq | target_col | DRV | note |
|---|---|---|---|
| 1 | data_item_cd | C | '67200' |
| 6 | target_type_cd | C | 'SBTI' |
| 7 | scope_cd | C | 'S1+S2+S3' |
| 10 | base_value_nb | N | not supplied |
| 11 | target_value_nb | N | not supplied |
| 13 | pct_achieved_nb | N | not supplied |
| 15 | is_science_based_fl | F | 1 |
| 17 | temperature_align_cd | D | source: temperature_alignment |
| 18 | commitment_dt | D | source: commitment_date |

### 7.F 67300 / ESGBOOK → udm_emissions_target  [ARRAY_OF_MAP — NET_ZERO]

REPEAT(67100) with these overrides:

| seq | target_col | DRV | note |
|---|---|---|---|
| 1 | data_item_cd | C | '67300' |
| 5 | obs_id | D | source: target_id |
| 6 | target_type_cd | L | udm_src_code_map TARGET_TYPE |
| 7 | scope_cd | S | LISTAGG udm_obs_scope cur_fl=1 |
| 10 | base_value_nb | D | source: base_emissions |
| 11 | target_value_nb | D | source: target_emissions |
| 15 | is_science_based_fl | D | source: sbti_flag |
| 16 | is_net_zero_fl | F | 1 |
| 17 | temperature_align_cd | D | source: temp_alignment |
| 18 | commitment_dt | N | |
| 19 | detail_tx | D | source: description |

### 7.G 67400 / ESGBOOK → udm_emissions_target  [ARRAY_OF_MAP — EMISSIONS_REDUCTION]

REPEAT(67300) with these overrides:

| seq | target_col | DRV | note |
|---|---|---|---|
| 1 | data_item_cd | C | '67400' |
| 16 | is_net_zero_fl | F | 0 |

---

## 8. SOURCE VIEW CONTRACT

### 8.1 Rules
1. View column names should match target column names by convention (name-equality). The catalog map is authoritative.
2. All canonicalization inside the view — canonical codes out, raw labels never reach a fact table.
3. Plain SELECT only. No procedural code, no DML.
4. Handle whichever RDM shape exists (§8.2).

### 8.2 RDM shapes — both produce identical output

**Shape A — relational rows:**
```sql
CREATE OR REPLACE VIEW vw_esgbook_65100_scope AS
SELECT '65100' AS data_item_cd, r.entity_key, r.coverage_period,
       r.observation_id AS obs_id, r.scope_position AS item_no,
       m.canonical_cd   AS scope_cd
FROM   rdm_esgbook_ei_scope r
JOIN   udm_src_code_map m ON m.source_id='ESGBOOK' AND m.code_type_cd='SCOPE' AND m.src_label_tx=r.scope_label;
```

**Shape B — JSON column:**
```sql
CREATE OR REPLACE VIEW vw_esgbook_65100_scope AS
SELECT '65100' AS data_item_cd, r.entity_key, r.coverage_period,
       j.obs_id, j.item_no, m.canonical_cd AS scope_cd
FROM   rdm_esgbook_ei_raw r
CROSS JOIN JSON_TABLE(r.payload_json,'$.intensities[*]'
    COLUMNS(obs_id VARCHAR2(40) PATH '$.id',
            NESTED PATH '$.scopes[*]' COLUMNS(item_no FOR ORDINALITY, scope_lbl VARCHAR2(80) PATH '$'))
) j
JOIN   udm_src_code_map m ON m.source_id='ESGBOOK' AND m.code_type_cd='SCOPE' AND m.src_label_tx=j.scope_lbl;
```

### 8.3 Header view — ARRAY_OF_MAP (65100 intensity)
`scope_cd` resolved via LISTAGG from already-loaded `udm_obs_scope` (seq=1 loaded first).
```sql
CREATE OR REPLACE VIEW vw_esgbook_65100_hdr AS
SELECT '65100' AS data_item_cd, h.entity_key, h.coverage_period, h.observation_id AS obs_id,
       (SELECT LISTAGG(s.scope_cd,'+') WITHIN GROUP (ORDER BY s.scope_cd)
        FROM udm_obs_scope s
        WHERE s.data_item_cd='65100' AND s.entity_key=h.entity_key AND s.source_id='ESGBOOK'
          AND s.coverage_period=h.coverage_period AND s.obs_id=h.observation_id AND s.cur_fl=1) AS scope_cd,
       cat.canonical_cd AS category_cd, h.intensity_value AS value_nb, h.intensity_unit AS value_unit_cd
FROM   rdm_esgbook_ei h
JOIN   udm_src_code_map cat ON cat.source_id='ESGBOOK' AND cat.code_type_cd='DENOMINATOR' AND cat.src_label_tx=h.denominator_label;
```

### 8.4 Header view — MAP (66100–66500 assurance)
`obs_id='1'`. Views 66200–66500 identical except `data_item_cd` literal and `WHERE scope_type` filter.
```sql
CREATE OR REPLACE VIEW vw_esgbook_66100_hdr AS
SELECT '66100' AS data_item_cd, r.entity_key, r.coverage_period, '1' AS obs_id,
       r.is_verified AS is_assured_fl, r.verifier_name AS assurance_provider_nm,
       r.covers_figure AS covers_figure_fl, al.canonical_cd AS assurance_level_cd, NULL AS methodology_tx
FROM   rdm_esgbook_assurance r
JOIN   udm_src_code_map al ON al.source_id='ESGBOOK' AND al.code_type_cd='ASSURANCE_LEVEL' AND al.src_label_tx=r.assurance_level
WHERE  r.scope_type='Scope1';
```

### 8.5 Header view — ARRAY_OF_MAP (67300 net zero targets)
Same LISTAGG pattern as §8.3.
```sql
CREATE OR REPLACE VIEW vw_esgbook_67300_hdr AS
SELECT '67300' AS data_item_cd, t.entity_key, t.coverage_period, t.target_id AS obs_id,
       tt.canonical_cd AS target_type_cd,
       (SELECT LISTAGG(s.scope_cd,'+') WITHIN GROUP (ORDER BY s.scope_cd)
        FROM udm_obs_scope s
        WHERE s.data_item_cd='67300' AND s.entity_key=t.entity_key AND s.source_id='ESGBOOK'
          AND s.coverage_period=t.coverage_period AND s.obs_id=t.target_id AND s.cur_fl=1) AS scope_cd,
       t.target_year AS target_year_nb, t.base_year AS base_year_nb,
       t.base_emissions AS base_value_nb, t.target_emissions AS target_value_nb,
       t.pct_reduction AS pct_reduction_nb, t.pct_achieved AS pct_achieved_nb,
       t.status AS target_status_cd, t.sbti_flag AS is_science_based_fl,
       1 AS is_net_zero_fl, t.temp_alignment AS temperature_align_cd,
       NULL AS commitment_dt, t.description AS detail_tx
FROM   rdm_esgbook_target t
JOIN   udm_src_code_map tt ON tt.source_id='ESGBOOK' AND tt.code_type_cd='TARGET_TYPE' AND tt.src_label_tx=t.target_type_label
WHERE  t.target_category='NetZero';
```

### 8.6 Header view — MAP (67200 SBTi commitment)
```sql
CREATE OR REPLACE VIEW vw_esgbook_67200_hdr AS
SELECT '67200' AS data_item_cd, r.entity_key, r.coverage_period, '1' AS obs_id,
       'SBTI' AS target_type_cd, 'S1+S2+S3' AS scope_cd,
       r.target_year AS target_year_nb, r.base_year AS base_year_nb,
       NULL AS base_value_nb, NULL AS target_value_nb,
       r.pct_reduction AS pct_reduction_nb, NULL AS pct_achieved_nb,
       r.status AS target_status_cd, 1 AS is_science_based_fl, 0 AS is_net_zero_fl,
       r.temperature_alignment AS temperature_align_cd, r.commitment_date AS commitment_dt,
       r.description AS detail_tx
FROM   rdm_esgbook_sbti r;
```

---

## 9. LOAD MECHANICS (FRAMEWORK)

```
FOR each (data_item_cd, source_id) WHERE storage_pattern_cd='STRUCT':
  FOR each src_map row ORDER BY load_seq_nb:
    IF struct_shape_cd='MAP' AND target is a list table → SKIP

    -- Step 1: SCD2 close (versioning only — never touches business columns)
    UPDATE {target_table} SET end_tran_dt=:run_dt, cur_fl=0
    WHERE cur_fl=1
    AND (data_item_cd,entity_key,source_id,coverage_period,obs_id[,item_no])
        IN (rows present in live table but changed vs {source_view})

    -- Step 2: Insert new and changed rows
    -- col list and view col list rendered from udm_data_item_src_col_map ORDER BY col_seq_nb
    -- envelope appended by framework (not from the map)
    INSERT INTO {target_table}
      ({col_seq ordered target_col_nm list}, src_bgn_tran_dt,src_end_tran_dt,bgn_tran_dt,end_tran_dt,cur_fl,is_golden_fl,lineage_id)
    SELECT
      {col_seq ordered v.view_col_nm list}, :src_bgn_dt,DATE'9999-12-31',:run_dt,DATE'9999-12-31',1,0,:lineage_id
    FROM {src_object_nm} v
    WHERE row is new or changed

    -- Step 3: Reject unmapped labels (NULL on NOT NULL cell-key column)
    INSERT INTO udm_load_reject_log SELECT ...,'UNMAPPED_LABEL' AS reject_reason_cd
    FROM {source_view} WHERE scope_cd IS NULL OR category_cd IS NULL OR target_type_cd IS NULL
```

**Implementer rules:**
- Only UPDATE = SCD2 close of `end_tran_dt`/`cur_fl`. Reuse existing UDM SCD2 close routine.
- All processing set-based. No cursors or row loops.
- Change detection compares view output to live (`cur_fl=1`) rows on business columns. Reuse existing UDM change-detection routine.
- ARRAY_OF_MAP header LISTAGG reads already-loaded list rows (`cur_fl=1`). List tables must be `load_seq_nb=1`.

---

## 10. ARBITRATION

Runs after all sources loaded for a data item. Cell-level on header only. List rows inherit golden status via header join — no `is_golden_fl` on list tables.

| table | cell key |
|---|---|
| udm_emissions_intensity | data_item_cd, entity_key, coverage_period, scope_cd, category_cd |
| udm_emissions_assurance | data_item_cd, entity_key, coverage_period |
| udm_emissions_target | data_item_cd, entity_key, coverage_period, target_type_cd, scope_cd, target_year_nb |

```sql
-- Example: intensity (pattern identical for assurance and target, change PARTITION BY)
MERGE INTO udm_emissions_intensity h
USING (
    SELECT ROWID AS rid,
           RANK() OVER (PARTITION BY data_item_cd,entity_key,coverage_period,scope_cd,category_cd
                        ORDER BY p.priority_nb) AS rnk
    FROM   udm_emissions_intensity x
    JOIN   udm_precedence_rules p ON p.data_item_cd=x.data_item_cd AND p.source_id=x.source_id
    WHERE  x.cur_fl=1
) r ON (h.ROWID=r.rid)
WHEN MATCHED THEN UPDATE SET h.is_golden_fl=CASE WHEN r.rnk=1 THEN 1 ELSE 0 END;
```

ESGbook may win `S1+S2/REVENUE` while CDP wins `S1+S2+S3/REVENUE` — each cell arbitrated independently.

---

## 11. ADDING A NEW SOURCE (zero framework or DDL changes)

1. Register in `udm_source_registry`.
2. INSERT label rows into `udm_src_code_map`.
3. CREATE source views (one per target table) per §8 contract.
4. INSERT rows into `udm_data_item_src_map`.
5. INSERT column-map rows into `udm_data_item_src_col_map` (one per business column per target table).
6. INSERT precedence rule into `udm_precedence_rules`.

---

## 12. OBJECT SUMMARY

### Fact tables
| table | concepts | shape |
|---|---|---|
| udm_emissions_intensity | 65100 | ARRAY_OF_MAP |
| udm_emissions_assurance | 66100–66500 | MAP |
| udm_emissions_target | 67100–67400 | MAP + ARRAY_OF_MAP |
| udm_obs_scope | any concept with scope array | shared child |
| udm_obs_category | any concept with category array | shared child |

### Catalog tables
| table | status | role |
|---|---|---|
| udm_data_item | existing | concept → storage pattern → parent table |
| udm_data_item_src_map | existing + struct_shape_cd | source → target table → view → shape → row order |
| udm_data_item_constituent | new | self-describing cell dimensions per concept |
| udm_src_code_map | new | source label → canonical code (view-only) |
| udm_col_derivation | new | governed vocabulary for derivation_cd |
| udm_data_item_src_col_map | new | explicit col-level load contract + lineage register |

### View naming
| pattern | feeds |
|---|---|
| VW_{SOURCE}_{CD}_SCOPE | udm_obs_scope |
| VW_{SOURCE}_{CD}_CATEGORY | udm_obs_category |
| VW_{SOURCE}_{CD}_HDR | header table |

### Design guarantees
| guarantee | mechanism |
|---|---|
| Insert-only for business data | No UPDATE on business columns; SCD2 close only |
| Bi-temporal history | Full envelope on every table |
| Single golden value per cell | Cell-level arbitration, is_golden_fl on header |
| Full source lineage (row) | lineage_id → udm_lineage on every row |
| Full source lineage (column) | udm_data_item_src_col_map — source element → target column as queryable data |
| Catalog self-describes structure | udm_data_item_constituent registers cell dimensions |
| Explicit column mapping | udm_data_item_src_col_map mandatory and complete; no implicit fallback |
| New source = config only | Insert into src_code_map + src_map + col_map; create views |
| No table proliferation | data_item_cd discriminates within shared physical tables |
