# UDM Structured Data Item — Implementation Specification
## Emission Intensities (by scope & category) and Reduction / Net-Zero Targets

**Audience:** UDM development team
**Status:** Build specification — v1
**Reference sources:** ESGbook, CDP 2024
**Concepts in scope:** `EMISSION_INTENSITY`, `ENV_TARGET`

---

## 1. Purpose

Some data items are not scalars. A company reports **many** emission intensities (one per
scope-coverage × denominator combination) and **many** targets (absolute reduction, intensity
reduction, net-zero), each covering a set of scopes. These arrive as arrays from ESGbook and CDP.

This spec defines how to store and load these structured data items using the **simplest possible
mechanism** that still gives UDM its three guarantees: bi-temporal history, single golden value per
cell, and full lineage to source.

---

## 2. Core Design Principle (read this first)

> **One normalized view per target table. The view's output columns match the target table's
> columns by name. The framework loads it insert-only. No post-load updates. No row-routing logic.**

Everything below is an application of this one rule. If a developer is ever writing procedural
row-routing code or an `UPDATE` against a business column, they have departed from the spec.

The complexity of each source's physical layout (relational rows, pipe-delimited strings, or a JSON
column) is absorbed **inside the view**. The framework never sees it. Every view, regardless of
source, presents the same clean shape as its target table.

---

## 3. The Pattern in One Picture

```
ESGbook RDM           CDP RDM
(relational or JSON)  (relational or JSON)
      │                    │
      ▼                    ▼
  ┌─────────────────────────────────┐
  │  SOURCE VIEWS                    │   ← all canonicalization happens here
  │  one per (source, target table)  │     (label mapping, scope combo, typing)
  │  output columns = target columns │
  └─────────────────────────────────┘
      │   (insert-only, bi-temporal wrapper applied by framework)
      ▼
  ┌──────────────────┐  ┌──────────────────┐
  │  HEADER TABLE     │  │  LIST TABLES      │
  │  1 row / obs      │◄─┤  N rows / obs     │
  │  scalar values +  │  │  scope elements   │
  │  resolved cell key│  │  category elements│
  └──────────────────┘  └──────────────────┘
      │
      ▼  cell-level arbitration → is_golden_fl
  consumer views
```

A "cell" = one uniquely identified intensity or target. For intensity the cell key is
`scope_cd + category_cd`. For targets it is `target_type_cd + scope_cd + target_year_nb`.

---

## 4. Physical Tables

All tables carry the standard UDM **bi-temporal envelope** (§4.3). Header tables additionally carry
`is_golden_fl`. List tables do not — they are children of the header and inherit its golden status.

### 4.1 Emission Intensity

```sql
-- HEADER: one row per intensity observation, per source, per version
CREATE TABLE udm_ei_hdr (
    entity_key          VARCHAR2(20)  NOT NULL,
    source_id           VARCHAR2(20)  NOT NULL,
    coverage_period     VARCHAR2(20)  NOT NULL,
    obs_id              VARCHAR2(40)  NOT NULL,   -- stable id of the observation within the source feed
    -- resolved cell key (computed in the view, written once)
    scope_cd            VARCHAR2(40)  NOT NULL,   -- canonical combo, e.g. 'S1+S2' (see §6.3)
    category_cd         VARCHAR2(40)  NOT NULL,   -- canonical denominator, e.g. 'REVENUE'
    -- scalar payload
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
    CONSTRAINT pk_ei_hdr PRIMARY KEY
        (entity_key, source_id, coverage_period, obs_id, src_bgn_tran_dt, bgn_tran_dt)
);

-- LIST: scope elements as received (lineage of what the source actually sent)
CREATE TABLE udm_ei_scope (
    entity_key          VARCHAR2(20)  NOT NULL,
    source_id           VARCHAR2(20)  NOT NULL,
    coverage_period     VARCHAR2(20)  NOT NULL,
    obs_id              VARCHAR2(40)  NOT NULL,
    item_no             NUMBER(4)     NOT NULL,   -- position in the source array
    scope_cd            VARCHAR2(10)  NOT NULL,   -- canonical single scope, e.g. 'S1'
    -- bi-temporal envelope
    src_bgn_tran_dt     DATE          NOT NULL,
    src_end_tran_dt     DATE          NOT NULL,
    bgn_tran_dt         DATE          NOT NULL,
    end_tran_dt         DATE DEFAULT  DATE '9999-12-31' NOT NULL,
    cur_fl              NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id          VARCHAR2(30)  NOT NULL,
    CONSTRAINT pk_ei_scope PRIMARY KEY
        (entity_key, source_id, coverage_period, obs_id, item_no, src_bgn_tran_dt, bgn_tran_dt)
);

-- LIST: category (denominator) elements as received
CREATE TABLE udm_ei_category (
    entity_key          VARCHAR2(20)  NOT NULL,
    source_id           VARCHAR2(20)  NOT NULL,
    coverage_period     VARCHAR2(20)  NOT NULL,
    obs_id              VARCHAR2(40)  NOT NULL,
    item_no             NUMBER(4)     NOT NULL,
    category_cd         VARCHAR2(40)  NOT NULL,   -- canonical denominator
    -- bi-temporal envelope
    src_bgn_tran_dt     DATE          NOT NULL,
    src_end_tran_dt     DATE          NOT NULL,
    bgn_tran_dt         DATE          NOT NULL,
    end_tran_dt         DATE DEFAULT  DATE '9999-12-31' NOT NULL,
    cur_fl              NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id          VARCHAR2(30)  NOT NULL,
    CONSTRAINT pk_ei_category PRIMARY KEY
        (entity_key, source_id, coverage_period, obs_id, item_no, src_bgn_tran_dt, bgn_tran_dt)
);
```

### 4.2 Reduction / Net-Zero Targets

```sql
-- HEADER: one row per target, per source, per version
CREATE TABLE udm_tgt_hdr (
    entity_key            VARCHAR2(20)  NOT NULL,
    source_id             VARCHAR2(20)  NOT NULL,
    coverage_period       VARCHAR2(20)  NOT NULL,
    obs_id                VARCHAR2(40)  NOT NULL,   -- source target id
    -- resolved cell key
    target_type_cd        VARCHAR2(30)  NOT NULL,   -- ABSOLUTE_REDUCTION | INTENSITY_REDUCTION | NET_ZERO
    scope_cd              VARCHAR2(40)  NOT NULL,   -- canonical combo, e.g. 'S1+S2+S3'
    target_year_nb        NUMBER(4),
    -- scalar payload
    base_year_nb          NUMBER(4),
    base_value_nb         NUMBER,
    target_value_nb       NUMBER,
    pct_reduction_nb      NUMBER,
    pct_achieved_nb       NUMBER,
    target_status_cd      VARCHAR2(30),             -- UNDERWAY | ACHIEVED | EXPIRED | RETIRED
    is_science_based_fl   NUMBER(1),
    is_net_zero_fl        NUMBER(1),
    temperature_align_cd  VARCHAR2(20),             -- 1_5C | WB2C | 2C
    detail_tx             VARCHAR2(4000),
    -- bi-temporal envelope
    src_bgn_tran_dt       DATE          NOT NULL,
    src_end_tran_dt       DATE          NOT NULL,
    bgn_tran_dt           DATE          NOT NULL,
    end_tran_dt           DATE DEFAULT  DATE '9999-12-31' NOT NULL,
    cur_fl                NUMBER(1)     DEFAULT 1 NOT NULL,
    is_golden_fl          NUMBER(1)     DEFAULT 0 NOT NULL,
    lineage_id            VARCHAR2(30)  NOT NULL,
    CONSTRAINT pk_tgt_hdr PRIMARY KEY
        (entity_key, source_id, coverage_period, obs_id, src_bgn_tran_dt, bgn_tran_dt)
);

-- LIST: scope elements covered by the target, as received
CREATE TABLE udm_tgt_scope (
    entity_key            VARCHAR2(20)  NOT NULL,
    source_id             VARCHAR2(20)  NOT NULL,
    coverage_period       VARCHAR2(20)  NOT NULL,
    obs_id                VARCHAR2(40)  NOT NULL,
    item_no               NUMBER(4)     NOT NULL,
    scope_cd              VARCHAR2(10)  NOT NULL,
    -- bi-temporal envelope
    src_bgn_tran_dt       DATE          NOT NULL,
    src_end_tran_dt       DATE          NOT NULL,
    bgn_tran_dt           DATE          NOT NULL,
    end_tran_dt           DATE DEFAULT  DATE '9999-12-31' NOT NULL,
    cur_fl                NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id            VARCHAR2(30)  NOT NULL,
    CONSTRAINT pk_tgt_scope PRIMARY KEY
        (entity_key, source_id, coverage_period, obs_id, item_no, src_bgn_tran_dt, bgn_tran_dt)
);
```

### 4.3 Bi-temporal envelope (defined once, identical on every table)

| Column | Meaning |
|---|---|
| `src_bgn_tran_dt` / `src_end_tran_dt` | When the source asserted / superseded this version |
| `bgn_tran_dt` / `end_tran_dt` | When UDM loaded / closed this version |
| `cur_fl` | 1 = current version |
| `lineage_id` | FK to `udm_lineage` |

---

## 5. Catalog Configuration

Three catalog tables. Two you already have; one is new.

### 5.1 `udm_data_item` (existing — add the parent header table)

| data_item_cd | storage_pattern_cd | target_table_nm | target_column_nm |
|---|---|---|---|
| EMISSION_INTENSITY | STRUCT | udm_ei_hdr | value_nb |
| ENV_TARGET | STRUCT | udm_tgt_hdr | (n/a — multi-column) |

`storage_pattern_cd = STRUCT` tells the framework to use the view-per-table loader (§7) instead of
the scalar column loader.

### 5.2 `udm_data_item_src_map` (existing — one row per source per target table)

Your map already carries `target_table_nm` and `target_column_nm`. For STRUCT items, add one row per
**target table** (not per column). `src_object_nm` is the view. Column mapping is implicit: **the
view projects columns with the same names as the target table**, so no per-column rows are needed.

| data_item_cd | source_id | target_table_nm | src_object_nm | load_seq_nb |
|---|---|---|---|---|
| EMISSION_INTENSITY | ESGBOOK | udm_ei_hdr | VW_ESGBOOK_EI_HDR | 2 |
| EMISSION_INTENSITY | ESGBOOK | udm_ei_scope | VW_ESGBOOK_EI_SCOPE | 1 |
| EMISSION_INTENSITY | ESGBOOK | udm_ei_category | VW_ESGBOOK_EI_CATEGORY | 1 |
| EMISSION_INTENSITY | CDP_2024 | udm_ei_hdr | VW_CDP_EI_HDR | 2 |
| EMISSION_INTENSITY | CDP_2024 | udm_ei_scope | VW_CDP_EI_SCOPE | 1 |
| EMISSION_INTENSITY | CDP_2024 | udm_ei_category | VW_CDP_EI_CATEGORY | 1 |
| ENV_TARGET | ESGBOOK | udm_tgt_hdr | VW_ESGBOOK_TGT_HDR | 2 |
| ENV_TARGET | ESGBOOK | udm_tgt_scope | VW_ESGBOOK_TGT_SCOPE | 1 |
| ENV_TARGET | CDP_2024 | udm_tgt_hdr | VW_CDP_TGT_HDR | 2 |
| ENV_TARGET | CDP_2024 | udm_tgt_scope | VW_CDP_TGT_SCOPE | 1 |

`load_seq_nb` ensures list tables load before the header, because the header view derives its
`scope_cd` combo from the canonical scope elements (see §6.3). Lower sequence loads first.

### 5.3 `udm_data_item_constituent` (NEW — registers the cell dimensions)

This makes the catalog self-describing: a consumer can learn what defines an intensity or target
cell without reading physical DDL. (This closes the gap where the catalog knew the *concept* but not
its internal structure.)

```sql
CREATE TABLE udm_data_item_constituent (
    data_item_cd       VARCHAR2(30)  NOT NULL,
    constituent_cd     VARCHAR2(30)  NOT NULL,   -- SCOPE | CATEGORY | TARGET_TYPE | TARGET_YEAR
    constituent_nm     VARCHAR2(200) NOT NULL,
    list_table_nm      VARCHAR2(80),             -- child table, if the constituent is an array
    hdr_column_nm      VARCHAR2(80)  NOT NULL,   -- resolved column on the header
    is_cell_key_fl     NUMBER(1)     DEFAULT 0,  -- 1 = part of the cell identity
    code_type_cd       VARCHAR2(30),             -- vocabulary key in udm_src_code_map
    constituent_seq_nb NUMBER(2)     NOT NULL,
    CONSTRAINT pk_data_item_constituent PRIMARY KEY (data_item_cd, constituent_cd)
);
```

| data_item_cd | constituent_cd | list_table_nm | hdr_column_nm | is_cell_key_fl | code_type_cd |
|---|---|---|---|---|---|
| EMISSION_INTENSITY | SCOPE | udm_ei_scope | scope_cd | 1 | SCOPE |
| EMISSION_INTENSITY | CATEGORY | udm_ei_category | category_cd | 1 | DENOMINATOR |
| ENV_TARGET | TARGET_TYPE | (null) | target_type_cd | 1 | TARGET_TYPE |
| ENV_TARGET | SCOPE | udm_tgt_scope | scope_cd | 1 | SCOPE |
| ENV_TARGET | TARGET_YEAR | (null) | target_year_nb | 1 | (null) |

### 5.4 `udm_src_code_map` (NEW — generic label → canonical lookup)

One small reference table, used **only inside the views**, never by the framework. It is the single
home for "this source's label means this canonical code". Data-driven, insert-only, no DDL churn.

```sql
CREATE TABLE udm_src_code_map (
    source_id       VARCHAR2(20)  NOT NULL,
    code_type_cd    VARCHAR2(30)  NOT NULL,   -- SCOPE | DENOMINATOR | TARGET_TYPE
    src_label_tx    VARCHAR2(200) NOT NULL,   -- exactly as the source delivers it
    canonical_cd    VARCHAR2(40)  NOT NULL,
    is_active_fl    NUMBER(1)     DEFAULT 1 NOT NULL,
    CONSTRAINT pk_src_code_map PRIMARY KEY (source_id, code_type_cd, src_label_tx)
);
```

Seed (reference data):

| source_id | code_type_cd | src_label_tx | canonical_cd |
|---|---|---|---|
| ESGBOOK | SCOPE | Scope1 | S1 |
| ESGBOOK | SCOPE | Scope2 | S2 |
| ESGBOOK | SCOPE | Scope3 | S3 |
| ESGBOOK | DENOMINATOR | Revenue | REVENUE |
| ESGBOOK | DENOMINATOR | MWhGenerated | MWH_GENERATED |
| ESGBOOK | TARGET_TYPE | AbsoluteReduction | ABSOLUTE_REDUCTION |
| ESGBOOK | TARGET_TYPE | NetZero | NET_ZERO |
| CDP_2024 | SCOPE | Scope 1 | S1 |
| CDP_2024 | SCOPE | Scope 2 (location-based) | S2 |
| CDP_2024 | DENOMINATOR | unit total revenue | REVENUE |
| CDP_2024 | TARGET_TYPE | Absolute | ABSOLUTE_REDUCTION |
| CDP_2024 | TARGET_TYPE | Net-zero | NET_ZERO |

**Quarantine rule:** if a source label has no row here, the view's join yields NULL on a
NOT NULL target column and the row fails the load — it is written to the reject log, not the table.
Adding a missing label is an INSERT here. No code change.

---

## 6. Source View Contract

This is where developers spend their time. Every view obeys the same contract.

### 6.1 Contract rules

1. The view's projected columns **must be named exactly** as the target table's loadable columns
   (the business columns — not the bi-temporal envelope, which the framework adds).
2. The view outputs **canonical, typed** values. All label→code mapping is done here via
   `udm_src_code_map`. All scope-combo resolution is done here (§6.3).
3. The view is a plain `SELECT`. No procedural code.
4. The view reads from RDM. It handles whichever physical shape RDM uses (§6.2).

### 6.2 Two RDM shapes — same output

**Shape A — RDM stores the array already normalized (relational rows):**

```sql
CREATE OR REPLACE VIEW vw_esgbook_ei_scope AS
SELECT  r.entity_key,
        r.coverage_period,
        r.observation_id          AS obs_id,
        r.scope_position          AS item_no,
        m.canonical_cd            AS scope_cd
FROM    rdm_esgbook_ei_scope r
JOIN    udm_src_code_map m
          ON  m.source_id     = 'ESGBOOK'
          AND m.code_type_cd  = 'SCOPE'
          AND m.src_label_tx  = r.scope_label;
```

**Shape B — RDM stores the array as a JSON column:**

```sql
CREATE OR REPLACE VIEW vw_esgbook_ei_scope AS
SELECT  r.entity_key,
        r.coverage_period,
        j.obs_id,
        j.item_no,
        m.canonical_cd            AS scope_cd
FROM    rdm_esgbook_ei_raw r
CROSS JOIN JSON_TABLE(
            r.payload_json, '$.intensities[*]'
            COLUMNS (
                obs_id   VARCHAR2(40) PATH '$.id',
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

Both produce identical output: `(entity_key, coverage_period, obs_id, item_no, scope_cd)`.
The framework cannot tell which RDM shape was used — and does not need to.

### 6.3 The header view derives the scope combo (no reference table, no update)

The header's `scope_cd` is the **ordered concatenation of its canonical scope elements**. This is
deterministic and comparable across sources: ESGbook `{Scope1, Scope2}` and CDP `{Scope 1, Scope 2}`
both resolve to `S1+S2`. No combination reference table is needed.

```sql
CREATE OR REPLACE VIEW vw_esgbook_ei_hdr AS
SELECT  h.entity_key,
        h.coverage_period,
        h.observation_id                                          AS obs_id,
        -- cell key part 1: scope combo, derived by ordered concat of canonical scopes
        ( SELECT LISTAGG(s.scope_cd, '+') WITHIN GROUP (ORDER BY s.scope_cd)
          FROM   vw_esgbook_ei_scope s
          WHERE  s.entity_key      = h.entity_key
          AND    s.coverage_period = h.coverage_period
          AND    s.obs_id          = h.observation_id )           AS scope_cd,
        -- cell key part 2: canonical denominator (single value)
        cat.canonical_cd                                          AS category_cd,
        -- scalar payload
        h.intensity_value                                         AS value_nb,
        h.intensity_unit                                          AS value_unit_cd
FROM    rdm_esgbook_ei h
JOIN    udm_src_code_map cat
          ON  cat.source_id    = 'ESGBOOK'
          AND cat.code_type_cd = 'DENOMINATOR'
          AND cat.src_label_tx = h.denominator_label;
```

Because the scope list loads first (`load_seq_nb = 1`), the header view's subquery reads the already
canonical scope view. The combo is computed at SELECT time and inserted once. **Nothing is updated
after insert.**

### 6.4 Target header view (same pattern)

```sql
CREATE OR REPLACE VIEW vw_cdp_tgt_hdr AS
SELECT  t.entity_key,
        t.coverage_period,
        t.target_id                                               AS obs_id,
        tt.canonical_cd                                           AS target_type_cd,
        ( SELECT LISTAGG(s.scope_cd, '+') WITHIN GROUP (ORDER BY s.scope_cd)
          FROM   vw_cdp_tgt_scope s
          WHERE  s.entity_key = t.entity_key
          AND    s.coverage_period = t.coverage_period
          AND    s.obs_id = t.target_id )                         AS scope_cd,
        t.target_year                                             AS target_year_nb,
        t.base_year                                               AS base_year_nb,
        t.base_emissions                                          AS base_value_nb,
        t.target_emissions                                        AS target_value_nb,
        t.pct_reduction                                           AS pct_reduction_nb,
        t.pct_achieved                                            AS pct_achieved_nb,
        t.status                                                  AS target_status_cd,
        t.sbti_flag                                               AS is_science_based_fl,
        CASE WHEN tt.canonical_cd = 'NET_ZERO' THEN 1 ELSE 0 END  AS is_net_zero_fl,
        t.temp_alignment                                          AS temperature_align_cd,
        t.description                                             AS detail_tx
FROM    rdm_cdp_target t
JOIN    udm_src_code_map tt
          ON  tt.source_id    = 'CDP_2024'
          AND tt.code_type_cd = 'TARGET_TYPE'
          AND tt.src_label_tx = t.target_type_label;
```

---

## 7. Load Mechanics (Framework)

The framework does the **same thing for every STRUCT data item**, driven entirely by
`udm_data_item_src_map`. Pseudocode:

```
FOR each (data_item_cd, source_id) WHERE storage_pattern_cd = 'STRUCT':
    FOR each map row ORDER BY load_seq_nb:        -- list tables (seq 1) before header (seq 2)

        target  = map.target_table_nm
        view    = map.src_object_nm

        -- 1. CLOSE versions that changed (SCD Type 2 close — versioning, not a business update)
        UPDATE {target}
        SET    end_tran_dt = :run_dt, cur_fl = 0
        WHERE  cur_fl = 1
        AND    (entity_key, source_id, coverage_period, obs_id [, item_no])
               IN ( changed-key set, computed by comparing live rows to {view} )

        -- 2. INSERT new versions (insert-only for all business columns)
        INSERT INTO {target} ( business columns, bi-temporal envelope )
        SELECT v.*,                               -- column names align by contract (§6.1)
               :src_bgn_dt, DATE '9999-12-31',
               :run_dt,     DATE '9999-12-31',
               1, :lineage_id
        FROM   {view} v
        WHERE  (new or changed rows only)

        -- 3. REJECT rows that failed canonical mapping (NULL in a NOT NULL cell-key column)
        INSERT INTO udm_struct_reject_log (...)
        SELECT ... FROM {view} WHERE scope_cd IS NULL OR category_cd IS NULL
```

Notes for the implementer:
- The only `UPDATE` is the SCD2 **close** (`end_tran_dt`, `cur_fl`). Business columns are never
  updated. This is the existing platform versioning pattern — keep it identical.
- The load is **set-based**. No cursors, no row loops.
- "Changed row" detection: compare the view's current output to the live (`cur_fl = 1`) rows on the
  business columns. Standard UDM change-detection — reuse the existing routine.

---

## 8. Arbitration (Header only)

After all sources for a data item are loaded, arbitrate **at cell level** on the header table.

- **Intensity cell key:** `entity_key, coverage_period, scope_cd, category_cd`
- **Target cell key:** `entity_key, coverage_period, target_type_cd, scope_cd, target_year_nb`

```sql
MERGE INTO udm_ei_hdr h
USING (
    SELECT  rowid AS rid,
            RANK() OVER (
              PARTITION BY entity_key, coverage_period, scope_cd, category_cd
              ORDER BY    p.priority_nb
            ) AS rnk
    FROM    udm_ei_hdr x
    JOIN    udm_precedence_rules p
              ON p.data_item_cd = 'EMISSION_INTENSITY'
             AND p.source_id    = x.source_id
    WHERE   x.cur_fl = 1
) r ON (h.rowid = r.rid)
WHEN MATCHED THEN UPDATE SET h.is_golden_fl = CASE WHEN r.rnk = 1 THEN 1 ELSE 0 END;
```

`is_golden_fl` is the **only** column arbitration touches — it is platform state, not source
business data. Each cell is arbitrated independently, so ESGbook may win `S1+S2 / REVENUE` while CDP
wins `S1+S2+S3 / REVENUE`. List rows inherit golden status from their header (join on header key).

Consumer views always filter `is_golden_fl = 1 AND cur_fl = 1`.

---

## 9. Adding a New Source — Developer Checklist

To onboard a new source (e.g. a third intensity vendor), with **zero framework code change**:

1. Register the source in `udm_source_registry`.
2. Insert label rows into `udm_src_code_map` for the source's scope / denominator / target-type labels.
3. Create the source views (one per target table) per the §6 contract — relational or JSON shape.
4. Insert rows into `udm_data_item_src_map` (one per target table, with `src_object_nm` = view,
   `load_seq_nb` = 1 for lists, 2 for header).
5. Insert a precedence rule into `udm_precedence_rules` for the source.

Done. No new tables, no engine changes.

---

## 10. Summary of Objects

| Object | New / Existing | Role |
|---|---|---|
| `udm_ei_hdr`, `udm_ei_scope`, `udm_ei_category` | New | Intensity storage |
| `udm_tgt_hdr`, `udm_tgt_scope` | New | Target storage |
| `udm_data_item` | Existing | Concept + parent header table |
| `udm_data_item_src_map` | Existing | Source → target table → view |
| `udm_data_item_constituent` | New | Self-describing cell dimensions |
| `udm_src_code_map` | New | Label → canonical (used in views only) |
| `VW_{SOURCE}_{CONCEPT}_{TABLE}` | New per source | Shape + canonicalization adapter |

**Design guarantees met:** insert-only business data (no post-load patching); bi-temporal history on
every table; one golden value per cell; full lineage (list tables hold the source array verbatim in
canonical form); catalog self-describes the structure; new sources added by configuration only.
