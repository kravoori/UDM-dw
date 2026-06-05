# CDP Corporate Questionnaire → UDM
## Complete Data Model & Metric Classification
### v2 — supersedes UDM_CDP_EnvRisk_Ingestion_Design_v1.md

**Sources used:**
- CDP Full Corporate Questionnaire Guidance — Module 1–6 (368 pp, May 2024)
- CDP Full Corporate Questionnaire Guidance — Module 7 (426 pp, May 2024)
- CDP 2024 Climate Change Scoring Category Weightings (17 categories)
- UDM Architecture Context v8 MASTER
- CMS Energy 2024 CDP Corporate Questionnaire export (answered questions reference)

---

## Part 1 — Information Architecture: Metric Classification Taxonomy

Before touching tables, establish what kind of thing each CDP data point *is*.
Five orthogonal classification dimensions drive every downstream storage and routing decision.

### 1.1 Dimension 1 — UDM Storage Pattern (the routing decision)

| Code | Pattern | Grain | Description |
|---|---|---|---|
| **STACK** | Domain stack data item | entity × period | Scalar, point-in-time, arbitrable across vendors. Lands as a named column on `udm_environmental_risk_stk`. Governed by `udm_data_item` + `udm_precedence_rules`. |
| **EMI_BRK** | Emissions breakdown | entity × period × scope × dim_type × dim_member | tCO2e values disaggregated by GHG type, country, division, facility, activity, subsidiary, Scope 3 category. |
| **ENE_BRK** | Energy breakdown | entity × period × energy_type × dim_type × dim_member | MWh values disaggregated by fuel type, energy form, country. |
| **GEN_BRK** | Generation breakdown | entity × period × power_source | Nameplate capacity (MW) + net generation (GWh) by power source. Electric utilities only. |
| **FIN_BRK** | Financial breakdown | entity × period × flow × dim_type × dim_member | CAPEX/OPEX amounts and % alignment by source or taxonomy category. |
| **WTR_BRK** | Water breakdown | entity × period × aspect × dim_type × dim_member | Volume (ML) disaggregated by withdrawal source, discharge destination, pollutant. |
| **TARGET** | Target & commitment | entity × period × target_id | Trajectory record with base_year, target_year, % achieved. MSCI and CDP share this table. |
| **RISK_OPP** | Risk / opportunity | entity × period × risk_id | Identified environmental risk or opportunity with drivers and financial effect. |
| **QTF_ITEM** | Quantified item | entity × period × item_type × item_id | Repeating items with quantified measures: emission reduction initiatives, low-carbon products, carbon credits. |
| **QUAL** | Qualitative disclosure | entity × period × question_cd × seq | Coded single/multi-select + narrative. Vocabulary governed by question catalog. |
| **PROVENANCE** | Provenance / methodology | Run / source level | Reporting boundary, consolidation approach, methodology standard, exclusion justification. Lives on `udm_process_run` or source registry — never on a fact table. |
| **ENT_ATTR** | Entity attribute | Entity registry | Identifiers (ISIN, LEI, Ticker, CUSIP). Feeds `udm_company_xref`. Not a metric. |

### 1.2 Dimension 2 — Environmental Domain

| Code | Description | Primary module |
|---|---|---|
| ENV_CLIMATE | Climate change, GHG emissions, energy | C7 + climate dims of C1–C6 |
| ENV_WATER | Water withdrawal, discharge, consumption, quality | C9 |
| ENV_BIODIVERSITY | Ecosystem, species, land-use impacts | C11 |
| ENV_PLASTICS | Plastic production, waste, circularity | C10 |
| ENV_FORESTS | Deforestation, commodity supply chains | C8 |
| CROSS_DOMAIN | Integrated modules — applies to all active domains | C1–C6, C13 |

### 1.3 Dimension 3 — Arbitration Eligibility

| Code | Meaning | Implication |
|---|---|---|
| ARBITRABLE | CDP competes against MSCI, vendor estimates, internal calc | Register CDP as a vendor in `udm_precedence_rules`; full waterfall applies |
| SINGLE_SOURCE | Only CDP provides this disclosure | Bi-temporal and lineage-tracked but no multi-vendor waterfall |
| DERIVED | Computed from other data items | `is_derived_fl = 1` in `udm_data_item`; no direct load |

### 1.4 Dimension 4 — Measure Type

`ABSOLUTE` | `INTENSITY` | `PERCENTAGE` | `COUNT` | `BINARY_FLAG` | `CODED_VALUE` | `FREE_TEXT`

### 1.5 Dimension 5 — Banking Model Relevance

`FINANCED_EMISSIONS` | `TRANSITION_RISK` | `CREDIT_RISK` | `ESG_SCORING` | `DISCLOSURE_ONLY`

---

## Part 2 — CDP Category → UDM Classification Matrix

CDP's 17 scored categories mapped across all five dimensions.
"Q codes" = representative question codes from the guidance ToC.

| # | CDP Category | Rep. Q Codes | Storage Pattern | Domain | Arbitrable | Measure Type | Banking |
|---|---|---|---|---|---|---|---|
| 1 | **Context** | 1.1–1.9, 1.22–1.24 | ENT_ATTR / PROVENANCE | CROSS_DOMAIN | N | CODED / TEXT | DISCLOSURE_ONLY |
| 2 | **Dependencies, Impacts, Risks & Opps Process** | 2.1–2.4 | QUAL | CROSS_DOMAIN | N | CODED / TEXT | CREDIT_RISK |
| 3 | **Risk Disclosure** | 3.1, 3.1.1, 3.1.2 | RISK_OPP / QUAL | CROSS_DOMAIN | SINGLE | TEXT / CODED | TRANSITION_RISK, CREDIT_RISK |
| 4 | **Opportunity Disclosure** | 3.6, 3.6.1, 3.6.2 | RISK_OPP | CROSS_DOMAIN | SINGLE | TEXT / CODED | TRANSITION_RISK |
| 5 | **Pricing Env. Externalities** | 3.5.1–3.5.4, 5.10.1 | STACK (carbon price) / QUAL (ETS strategy) | ENV_CLIMATE | ARBITRABLE (price) / SINGLE (strategy) | ABSOLUTE / CODED | TRANSITION_RISK |
| 6 | **Governance** | 4.1–4.12 | QUAL | CROSS_DOMAIN | N | BINARY / CODED / TEXT | CREDIT_RISK |
| 7 | **Environmental Policies** | 4.6–4.6.1, 4.7–4.9 | QUAL | CROSS_DOMAIN | N | CODED / TEXT | CREDIT_RISK |
| 8 | **Business Strategy** | 5.1–5.3.2, 5.4–5.4.3, 5.5, 5.7, 5.9 | QUAL (scenario/transition plan) + STACK (CAPEX alignment scalars) + FIN_BRK (CAPEX by source) | ENV_CLIMATE | PARTIAL | CODED / ABSOLUTE / PERCENTAGE | TRANSITION_RISK |
| 9 | **Targets** | 7.53–7.54.5 | TARGET | ENV_CLIMATE | ARBITRABLE | ABSOLUTE / PERCENTAGE | FINANCED_EMISSIONS, TRANSITION_RISK |
| 10 | **Scope 1 & 2 Emissions** | 7.5–7.7, 7.9–7.10.2 | STACK | ENV_CLIMATE | ARBITRABLE | ABSOLUTE | FINANCED_EMISSIONS, TRANSITION_RISK |
| 11 | **Scope 3 Emissions** | 7.8, 7.8.1, 7.11, 7.11.1 | STACK (total) + EMI_BRK (by category) | ENV_CLIMATE | ARBITRABLE | ABSOLUTE | FINANCED_EMISSIONS, TRANSITION_RISK |
| 12 | **Emissions Breakdown** | 7.12–7.28 | EMI_BRK (most) + STACK (biogenic scalar) | ENV_CLIMATE | PARTIAL | ABSOLUTE | TRANSITION_RISK |
| 13 | **Energy** | 7.29–7.36 | STACK (total consumption scalar) + ENE_BRK (by fuel, country, form) + GEN_BRK (utilities) | ENV_CLIMATE | PARTIAL | ABSOLUTE | TRANSITION_RISK |
| 14 | **Emission Reduction Initiatives** | 7.55–7.55.4 | STACK (7.55.1 totals) + QTF_ITEM (7.55.2 detail) | ENV_CLIMATE | SINGLE | ABSOLUTE / COUNT | ESG_SCORING |
| 15 | **Low-carbon Products & Services** | 7.74.1 | QTF_ITEM | ENV_CLIMATE | SINGLE | ABSOLUTE / PERCENTAGE | TRANSITION_RISK, ESG_SCORING |
| 16 | **Carbon Credits** | 7.79.1 | QTF_ITEM | ENV_CLIMATE | SINGLE | COUNT / ABSOLUTE | ESG_SCORING |
| 17 | **Sign-off & Communications** | 4.12, 13.1, 13.3 | PROVENANCE | CROSS_DOMAIN | N | CODED | DISCLOSURE_ONLY |

**Sector-specific production data (unscored but data-rich):**
7.37–7.44 (coal reserves, hydrocarbon production, refinery throughput, chemical outputs, steel production) →
STACK data items in a **physical asset / production sub-domain**, not environmental risk.
These are arbitrable against S&P Commodity Insights, Wood Mackenzie, etc.
They require a separate sub-domain scope decision (OPN-002 dependent) — flag as CDP-08.

---

## Part 3 — Scalar Data Items for the Domain Stack

These are the questions whose output becomes a **named column** on `udm_environmental_risk_stk`.
All are entity × period grain, all flow through the harmonisation → arbitration engine.

| Data Item (canonical name) | Unit | CDP Q Code | Arbitrable against | `is_derived_fl` |
|---|---|---|---|---|
| `scope1_mtco2e` | mtCO2e | 7.6 | MSCI, vendor estimate | 0 |
| `scope2_location_mtco2e` | mtCO2e | 7.7 (location) | MSCI, vendor estimate | 0 |
| `scope2_market_mtco2e` | mtCO2e | 7.7 (market) | MSCI | 0 |
| `scope3_total_mtco2e` | mtCO2e | 7.8 | MSCI | 0 |
| `scope1_scope2_combined_mtco2e` | mtCO2e | derived | — | 1 |
| `base_year_scope1_mtco2e` | mtCO2e | 7.5 | MSCI | 0 |
| `base_year_nb` | YYYY | 7.5 | MSCI | 0 |
| `biogenic_co2_mtco2` | mtCO2 | 7.12.1 | — | 0 |
| `scope1_scope2_intensity_per_rev` | mtCO2e / USD | 7.45 | MSCI | 0 |
| `total_energy_consumption_mwh` | MWh | 7.30.1 | — | 0 |
| `total_nameplate_capacity_mw` | MW | 1.16.1 (Total) | Wood Mac, S&P | 0 |
| `total_net_generation_gwh` | GWh | 1.16.1 (Total) | — | 0 |
| `internal_carbon_price_low` | USD/tCO2e | 5.10.1 | — | 0 |
| `internal_carbon_price_high` | USD/tCO2e | 5.10.1 | — | 0 |
| `capex_climate_aligned_pct` | % | 5.4.1 | — | 0 |
| `capex_taxonomy_aligned_pct` | % | 5.4.2 | — | 0 |
| `total_water_withdrawal_ml` | ML | 9.2.2 | — | 0 |
| `total_water_discharge_ml` | ML | 9.2.2 | — | 0 |
| `total_water_consumption_ml` | ML | 9.2.2 | — | 0 |
| `water_withdrawal_efficiency` | revenue/ML | 9.5 | — | 0 |
| `scope1_yoy_change_pct` | % | 7.10 | — | 1 |
| `verified_scope1_fl` | 0/1 | 7.9.1 | — | 0 |
| `verified_scope2_fl` | 0/1 | 7.9.2 | — | 0 |

> **New vs v1:** Added `capex_climate_aligned_pct` and `capex_taxonomy_aligned_pct` from 5.4.x
> (new IFRS S2-aligned questions in 2024 not present in the CMS Energy export but visible in the
> guidance ToC). Added verification flags — these affect PCAF data quality tier assignment and
> must travel with the emissions values.

---

## Part 4 — Physical Data Model

### 4.1 Entity-Relationship Overview

```
udm_entity_registry ──────────────────────────────────────────────────────────┐
       │ entity_key                                                            │
       │                                                                       │
       ├──► udm_environmental_risk_stk   (scalar metrics, one row/entity/period/vendor)
       │
       ├──► udm_env_emissions_breakdown  (tCO2e by scope + dim)
       ├──► udm_env_energy_breakdown     (MWh by energy_type + dim)
       ├──► udm_env_generation_breakdown (MW/GWh by power_source)
       ├──► udm_env_financial_breakdown  ($ by flow + dim)
       ├──► udm_env_water_breakdown      (ML by aspect + dim)
       │
       ├──► udm_env_target               (base→target trajectory)
       ├──► udm_env_risk_opportunity     (identified risk/opp per entity/period)
       ├──► udm_env_quantified_item      (initiatives / low-carbon products / credits)
       └──► udm_env_qual_disclosure      (coded + narrative disclosures)

Catalog / reference (no entity_key):
       udm_cdp_question_catalog ──► udm_cdp_question_option
       udm_env_breakdown_member_ref
```

All nine fact tables share the **same bi-temporal envelope** (§4.2). This is the
architectural invariant — deviating from it breaks every as-of query across the platform.

### 4.2 Shared Bi-temporal Envelope (copy exactly across all tables)

```sql
entity_key          VARCHAR2(20)  NOT NULL,   -- FK -> udm_entity_registry; NO vendor raw id
source_id           VARCHAR2(20)  NOT NULL,   -- FK -> udm_source_registry (e.g. CDP_2024)
coverage_period     VARCHAR2(20)  NOT NULL,   -- reporting year e.g. '2023' or '2023-12-31'
src_bgn_tran_dt     DATE          NOT NULL,   -- when vendor first reported this version
src_end_tran_dt     DATE          NOT NULL,   -- when vendor superseded it (9999-12-31 if current)
bgn_tran_dt         DATE          NOT NULL,   -- when UDM first loaded
end_tran_dt         DATE          DEFAULT DATE '9999-12-31' NOT NULL,
cur_fl              NUMBER(1)     DEFAULT 1   NOT NULL,
lineage_id          VARCHAR2(30)  NOT NULL    -- FK -> udm_lineage
```

---

## Part 5 — Full DDL

### 5.1 Catalog: CDP Question Classification

This table is the **routing engine**. Adding a new CDP year is an INSERT + UPDATE here —
zero pipeline code changes.

```sql
CREATE TABLE udm_cdp_question_catalog (
    question_cd          VARCHAR2(20)  NOT NULL,   -- e.g. '7.6', '7.15.1', '4.6.1'
    question_yr_nb       NUMBER(4)     NOT NULL,   -- CDP questionnaire year
    module_nb            NUMBER(2)     NOT NULL,   -- 1-13
    section_tx           VARCHAR2(100),
    question_short_nm    VARCHAR2(400) NOT NULL,
    datatype_cd          VARCHAR2(20)  NOT NULL,   -- TEXT | NUMBER | DATE | CODED | MULTI_CODED
    cardinality_cd       VARCHAR2(20)  NOT NULL,   -- SINGLE | MULTI_SELECT | ADD_ROW | FIXED_ROW
    -- Classification dimensions (the five axes)
    storage_pattern_cd   VARCHAR2(20)  NOT NULL,   -- STACK | EMI_BRK | ENE_BRK | GEN_BRK |
                                                   -- FIN_BRK | WTR_BRK | TARGET | RISK_OPP |
                                                   -- QTF_ITEM | QUAL | PROVENANCE | ENT_ATTR
    env_domain_cd        VARCHAR2(20)  NOT NULL,   -- ENV_CLIMATE | ENV_WATER | ENV_BIODIVERSITY |
                                                   -- ENV_PLASTICS | ENV_FORESTS | CROSS_DOMAIN
    arbitration_cd       VARCHAR2(20)  NOT NULL,   -- ARBITRABLE | SINGLE_SOURCE | DERIVED | N_A
    measure_type_cd      VARCHAR2(20)  NOT NULL,   -- ABSOLUTE | INTENSITY | PERCENTAGE | COUNT |
                                                   -- BINARY_FLAG | CODED_VALUE | FREE_TEXT
    banking_relevance_cd VARCHAR2(100),            -- pipe-delimited e.g. FINANCED_EMISSIONS|TRANSITION_RISK
    -- Routing targets
    target_table_nm      VARCHAR2(80),             -- physical table name when storage_pattern != QUAL
    target_column_nm     VARCHAR2(80),             -- column name when storage_pattern = STACK
    breakdown_dim_cd     VARCHAR2(30),             -- dim_type_cd when storage_pattern in (*_BRK)
    -- Applicability
    is_universal_fl      NUMBER(1)     DEFAULT 1,  -- 0 = sector-specific or conditional
    sector_cd            VARCHAR2(200),            -- pipe-delimited sectors if not universal
    is_new_2024_fl       NUMBER(1)     DEFAULT 0,  -- questions added in 2024 integration
    is_scored_fl         NUMBER(1)     DEFAULT 0,  -- 0 = unscored (biodiversity, plastics 2024)
    CONSTRAINT pk_cdp_qn_catalog PRIMARY KEY (question_cd, question_yr_nb)
);

CREATE TABLE udm_cdp_question_option (
    question_cd       VARCHAR2(20)  NOT NULL,
    question_yr_nb    NUMBER(4)     NOT NULL,
    option_cd         VARCHAR2(80)  NOT NULL,
    option_display_nm VARCHAR2(400) NOT NULL,
    is_active_fl      NUMBER(1)     DEFAULT 1,
    CONSTRAINT pk_cdp_qn_option PRIMARY KEY (question_cd, question_yr_nb, option_cd),
    CONSTRAINT fk_cdp_qn_option FOREIGN KEY (question_cd, question_yr_nb)
        REFERENCES udm_cdp_question_catalog (question_cd, question_yr_nb)
);

CREATE TABLE udm_env_breakdown_member_ref (
    dim_type_cd       VARCHAR2(30)  NOT NULL,   -- GHG_TYPE | POWER_SOURCE | COUNTRY | DIVISION |
                                                -- FUEL_TYPE | WITHDRAWAL_SRC | DISCHARGE_DEST |
                                                -- S3_CATEGORY | WATER_ASPECT | POLLUTANT |
                                                -- ITEM_TYPE | TAXONOMY_ACTIVITY
    dim_member_cd     VARCHAR2(60)  NOT NULL,
    dim_member_nm     VARCHAR2(200) NOT NULL,
    cdp_label_tx      VARCHAR2(400),            -- exact CDP picklist label for ingest matching
    parent_member_cd  VARCHAR2(60),             -- for hierarchical dims (e.g. S3 cat under scope)
    is_active_fl      NUMBER(1)     DEFAULT 1,
    CONSTRAINT pk_env_breakdown_member PRIMARY KEY (dim_type_cd, dim_member_cd)
);
```

**Sample seed rows — `udm_cdp_question_catalog`:**

| question_cd | storage_pattern_cd | target_table_nm | target_column_nm | is_universal_fl | banking_relevance_cd |
|---|---|---|---|---|---|
| 7.6 | STACK | udm_environmental_risk_stk | scope1_mtco2e | 1 | FINANCED_EMISSIONS\|TRANSITION_RISK |
| 7.7 | STACK | udm_environmental_risk_stk | scope2_location_mtco2e | 1 | FINANCED_EMISSIONS |
| 7.15.1 | EMI_BRK | udm_env_emissions_breakdown | — | 1 | TRANSITION_RISK |
| 7.15.3 | EMI_BRK | udm_env_emissions_breakdown | — | 0 | TRANSITION_RISK |
| 7.30.1 | STACK | udm_environmental_risk_stk | total_energy_consumption_mwh | 1 | TRANSITION_RISK |
| 7.30.7 | ENE_BRK | udm_env_energy_breakdown | — | 1 | TRANSITION_RISK |
| 7.53.1 | TARGET | udm_env_target | — | 1 | FINANCED_EMISSIONS\|TRANSITION_RISK |
| 5.10.1 | STACK | udm_environmental_risk_stk | internal_carbon_price_low | 1 | TRANSITION_RISK |
| 5.4.2 | STACK | udm_environmental_risk_stk | capex_taxonomy_aligned_pct | 1 | TRANSITION_RISK |
| 4.1.1 | QUAL | udm_env_qual_disclosure | — | 1 | CREDIT_RISK |
| 3.1.1 | RISK_OPP | udm_env_risk_opportunity | — | 1 | TRANSITION_RISK\|CREDIT_RISK |
| 7.55.2 | QTF_ITEM | udm_env_quantified_item | — | 1 | ESG_SCORING |
| 1.6 | ENT_ATTR | udm_company_xref | — | 1 | — |
| 7.2 | PROVENANCE | udm_process_run | — | 1 | — |

---

### 5.2 Breakdown Fact Tables (Tier B)

**Design principle:** `dim_type_cd` + `dim_member_cd` are always FKs to
`udm_env_breakdown_member_ref`. The dimension member is *data*, never schema.

```sql
-- B1: Emissions breakdown — covers 7.8(by S3 cat), 7.15.1-7.15.4, 7.16, 7.17.1-7.17.3,
--     7.18.2, 7.19, 7.20.1-7.20.3, 7.21, 7.22, 7.23.1, 7.24, 7.25, 7.26
CREATE TABLE udm_env_emissions_breakdown (
    -- Bi-temporal envelope (§4.2)
    entity_key          VARCHAR2(20)  NOT NULL,
    source_id           VARCHAR2(20)  NOT NULL,
    coverage_period     VARCHAR2(20)  NOT NULL,
    src_bgn_tran_dt     DATE          NOT NULL,
    src_end_tran_dt     DATE          NOT NULL,
    bgn_tran_dt         DATE          NOT NULL,
    end_tran_dt         DATE          DEFAULT DATE '9999-12-31' NOT NULL,
    cur_fl              NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id          VARCHAR2(30)  NOT NULL,
    -- Breakdown identity
    scope_cd            VARCHAR2(10)  NOT NULL,   -- S1 | S2_LOC | S2_MKT | S3 | S1S2
    dim_type_cd         VARCHAR2(30)  NOT NULL,   -- GHG_TYPE | COUNTRY | DIVISION | FACILITY |
                                                  -- ACTIVITY | SUBSIDIARY | S3_CATEGORY |
                                                  -- SECTOR_PROD | ALLOCATION_CUSTOMER
    dim_member_cd       VARCHAR2(60)  NOT NULL,   -- FK -> udm_env_breakdown_member_ref
    -- Measures (tCO2e — unit consistent across all rows)
    gross_emissions_mtco2e   NUMBER,
    net_emissions_mtco2e     NUMBER,              -- after removals, where applicable
    gwp_source_tx            VARCHAR2(200),       -- AR5/AR6/IPCC source used for GHG conversion
    intensity_nb             NUMBER,              -- where CDP provides an intensity alongside
    intensity_unit_tx        VARCHAR2(80),
    comparison_prior_yr_cd   VARCHAR2(30),        -- HIGHER | LOWER | SAME | FIRST_YEAR
    pct_change_prior_yr_nb   NUMBER,
    comment_tx               VARCHAR2(4000),
    CONSTRAINT pk_env_emi_brk PRIMARY KEY
        (entity_key, source_id, coverage_period, scope_cd, dim_type_cd, dim_member_cd,
         src_bgn_tran_dt, bgn_tran_dt)
);

-- B2: Energy breakdown — covers 7.30.6, 7.30.7 (by fuel), 7.30.9 (by form),
--     7.30.14 (zero-emission factor), 7.30.16 (by country), 7.30.17-7.30.19 (renewable by country)
CREATE TABLE udm_env_energy_breakdown (
    entity_key          VARCHAR2(20)  NOT NULL,
    source_id           VARCHAR2(20)  NOT NULL,
    coverage_period     VARCHAR2(20)  NOT NULL,
    src_bgn_tran_dt     DATE          NOT NULL,
    src_end_tran_dt     DATE          NOT NULL,
    bgn_tran_dt         DATE          NOT NULL,
    end_tran_dt         DATE          DEFAULT DATE '9999-12-31' NOT NULL,
    cur_fl              NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id          VARCHAR2(30)  NOT NULL,
    -- Breakdown identity
    energy_form_cd      VARCHAR2(30)  NOT NULL,   -- FUEL | ELECTRICITY | HEAT | STEAM | COOLING |
                                                  -- RENEWABLE_ELEC | LOW_CARBON_HEAT
    dim_type_cd         VARCHAR2(30)  NOT NULL,   -- FUEL_TYPE | COUNTRY | APPLICATION | FORM
    dim_member_cd       VARCHAR2(60)  NOT NULL,   -- FK -> udm_env_breakdown_member_ref
    -- Measures
    consumption_mwh     NUMBER,
    generated_mwh       NUMBER,
    self_consumed_mwh   NUMBER,
    exported_mwh        NUMBER,
    pct_of_total_nb     NUMBER,
    emission_factor_nb  NUMBER,                   -- for 7.30.14 zero/near-zero factor
    comment_tx          VARCHAR2(4000),
    CONSTRAINT pk_env_ene_brk PRIMARY KEY
        (entity_key, source_id, coverage_period, energy_form_cd, dim_type_cd, dim_member_cd,
         src_bgn_tran_dt, bgn_tran_dt)
);

-- B3: Generation breakdown — covers 1.16.1, 7.46 (electric utilities only)
CREATE TABLE udm_env_generation_breakdown (
    entity_key              VARCHAR2(20)  NOT NULL,
    source_id               VARCHAR2(20)  NOT NULL,
    coverage_period         VARCHAR2(20)  NOT NULL,
    src_bgn_tran_dt         DATE          NOT NULL,
    src_end_tran_dt         DATE          NOT NULL,
    bgn_tran_dt             DATE          NOT NULL,
    end_tran_dt             DATE          DEFAULT DATE '9999-12-31' NOT NULL,
    cur_fl                  NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id              VARCHAR2(30)  NOT NULL,
    -- Breakdown identity
    power_source_cd         VARCHAR2(40)  NOT NULL,   -- FK -> udm_env_breakdown_member_ref (POWER_SOURCE)
    -- Measures
    nameplate_capacity_mw   NUMBER,
    net_generation_gwh      NUMBER,
    scope1_emissions_mtco2e NUMBER,                   -- 7.46 provides this alongside generation
    scope1_intensity_nb     NUMBER,                   -- tCO2e per MWh generated
    own_use_fl              NUMBER(1),                -- self-owned vs contracted
    comment_tx              VARCHAR2(4000),
    CONSTRAINT pk_env_gen_brk PRIMARY KEY
        (entity_key, source_id, coverage_period, power_source_cd, src_bgn_tran_dt, bgn_tran_dt)
);

-- B4: Financial breakdown — covers 5.7 (CAPEX by power source), 5.4.1 (taxonomy alignment detail),
--     5.9 (OPEX trends) — NOTE: 5.4.1/5.4.2 taxonomy % scalar goes to STACK; this table
--     holds the BY-ACTIVITY breakdown of aligned spend
CREATE TABLE udm_env_financial_breakdown (
    entity_key              VARCHAR2(20)  NOT NULL,
    source_id               VARCHAR2(20)  NOT NULL,
    coverage_period         VARCHAR2(20)  NOT NULL,
    src_bgn_tran_dt         DATE          NOT NULL,
    src_end_tran_dt         DATE          NOT NULL,
    bgn_tran_dt             DATE          NOT NULL,
    end_tran_dt             DATE          DEFAULT DATE '9999-12-31' NOT NULL,
    cur_fl                  NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id              VARCHAR2(30)  NOT NULL,
    -- Breakdown identity
    flow_cd                 VARCHAR2(20)  NOT NULL,   -- CAPEX | OPEX | REVENUE
    dim_type_cd             VARCHAR2(30)  NOT NULL,   -- POWER_SOURCE | TAXONOMY_ACTIVITY | BUSINESS_UNIT
    dim_member_cd           VARCHAR2(60)  NOT NULL,
    -- Measures
    amount_nb               NUMBER,
    amount_currency_cd      VARCHAR2(10),
    pct_of_total_current_nb NUMBER,
    pct_of_total_planned_nb NUMBER,
    taxonomy_eligible_pct_nb NUMBER,
    taxonomy_aligned_pct_nb  NUMBER,
    trend_vs_prior_yr_cd    VARCHAR2(30),             -- INCREASED | DECREASED | SAME
    comment_tx              VARCHAR2(4000),
    CONSTRAINT pk_env_fin_brk PRIMARY KEY
        (entity_key, source_id, coverage_period, flow_cd, dim_type_cd, dim_member_cd,
         src_bgn_tran_dt, bgn_tran_dt)
);

-- B5: Water breakdown — covers 9.2.2, 9.2.7 (by withdrawal source), 9.2.8 (by discharge dest),
--     9.2.9 (operational water stress), 9.2.10 (pollutants to water), 9.3.1 (facility level — see note)
CREATE TABLE udm_env_water_breakdown (
    entity_key              VARCHAR2(20)  NOT NULL,
    source_id               VARCHAR2(20)  NOT NULL,
    coverage_period         VARCHAR2(20)  NOT NULL,
    src_bgn_tran_dt         DATE          NOT NULL,
    src_end_tran_dt         DATE          NOT NULL,
    bgn_tran_dt             DATE          NOT NULL,
    end_tran_dt             DATE          DEFAULT DATE '9999-12-31' NOT NULL,
    cur_fl                  NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id              VARCHAR2(30)  NOT NULL,
    -- Breakdown identity
    aspect_cd               VARCHAR2(20)  NOT NULL,   -- WITHDRAWAL | DISCHARGE | CONSUMPTION | POLLUTANT
    dim_type_cd             VARCHAR2(30)  NOT NULL,   -- WITHDRAWAL_SRC | DISCHARGE_DEST | POLLUTANT |
                                                      -- STRESS_CATEGORY | WATER_TYPE
    dim_member_cd           VARCHAR2(60)  NOT NULL,
    spatial_asset_key       VARCHAR2(20),             -- FK -> udm_spatial_asset_registry (facility rows)
    -- Measures
    volume_ml               NUMBER,
    pct_of_total_nb         NUMBER,
    comparison_prior_yr_cd  VARCHAR2(30),
    stress_level_cd         VARCHAR2(30),             -- HIGH | MEDIUM | LOW (9.2.9)
    comment_tx              VARCHAR2(4000),
    CONSTRAINT pk_env_wtr_brk PRIMARY KEY
        (entity_key, source_id, coverage_period, aspect_cd, dim_type_cd, dim_member_cd,
         src_bgn_tran_dt, bgn_tran_dt)
);
-- NOTE: 9.3.1 facility-level water rows use spatial_asset_key to reference the facility
-- in udm_spatial_asset_registry (already in Tier 1 v8). The facility coordinates from CDP
-- also enrich that registry.
```

---

### 5.3 Target Table (Tier C)

```sql
-- Covers 7.53.1 (absolute), 7.53.2 (intensity), 7.53.4 (portfolio/FS),
--        7.54.1 (low-carbon energy), 7.54.2 (methane/other), 7.54.3 (net-zero),
--        9.15.2 (water), 10.1 (plastics)
-- SAME TABLE as MSCI Climate Targets — source_id distinguishes CDP vs MSCI rows

CREATE TABLE udm_env_target (
    -- Bi-temporal envelope
    entity_key              VARCHAR2(20)  NOT NULL,
    source_id               VARCHAR2(20)  NOT NULL,
    coverage_period         VARCHAR2(20)  NOT NULL,
    src_bgn_tran_dt         DATE          NOT NULL,
    src_end_tran_dt         DATE          NOT NULL,
    bgn_tran_dt             DATE          NOT NULL,
    end_tran_dt             DATE          DEFAULT DATE '9999-12-31' NOT NULL,
    cur_fl                  NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id              VARCHAR2(30)  NOT NULL,
    -- Target identity
    target_id_cd            VARCHAR2(40)  NOT NULL,   -- CDP row id: Abs1, Int1, NZ1, W1 etc.
    target_type_cd          VARCHAR2(30)  NOT NULL,   -- ABSOLUTE | INTENSITY | NET_ZERO |
                                                      -- LOW_CARBON_ENERGY | METHANE | WATER |
                                                      -- PLASTICS | PORTFOLIO
    env_domain_cd           VARCHAR2(20)  NOT NULL,   -- ENV_CLIMATE | ENV_WATER | ENV_PLASTICS
    scope_coverage_cd       VARCHAR2(50),             -- S1 | S1S2 | S1S2S3 | S3_CAT_X | ...
    -- Trajectory (the window lives here, NOT in coverage_period)
    base_year_nb            NUMBER(4),
    base_year_value_nb      NUMBER,
    base_year_unit_tx       VARCHAR2(40),
    target_year_nb          NUMBER(4),
    target_value_nb         NUMBER,
    pct_reduction_nb        NUMBER,
    pct_achieved_nb         NUMBER,
    -- Qualification
    is_science_based_fl     NUMBER(1),
    sbti_status_cd          VARCHAR2(40),             -- COMMITTED | APPROVED | ACHIEVED
    temperature_alignment_tx VARCHAR2(20),            -- 1.5C | WELL_BELOW_2C | 2C
    target_status_cd        VARCHAR2(30),             -- UNDERWAY | ACHIEVED | EXPIRED | RETIRED
    includes_methane_fl     NUMBER(1),                -- 7.54.4/7.54.5 flag
    -- Portfolio dimension (FS-specific 7.53.4)
    portfolio_scope_cd      VARCHAR2(30),             -- FINANCED | FACILITATED | INSURED
    detail_tx               VARCHAR2(4000),
    CONSTRAINT pk_env_target PRIMARY KEY
        (entity_key, source_id, coverage_period, target_id_cd, src_bgn_tran_dt, bgn_tran_dt)
);
```

---

### 5.4 Risk / Opportunity Table (Tier D)

```sql
-- Covers 3.1 / 3.1.1 / 3.1.2 (risks with substantive effect)
--         3.6 / 3.6.1 / 3.6.2 (opportunities with substantive effect)
--         5.3.1 / 5.3.2 (strategy and financial planning effects)

CREATE TABLE udm_env_risk_opportunity (
    entity_key              VARCHAR2(20)  NOT NULL,
    source_id               VARCHAR2(20)  NOT NULL,
    coverage_period         VARCHAR2(20)  NOT NULL,
    src_bgn_tran_dt         DATE          NOT NULL,
    src_end_tran_dt         DATE          NOT NULL,
    bgn_tran_dt             DATE          NOT NULL,
    end_tran_dt             DATE          DEFAULT DATE '9999-12-31' NOT NULL,
    cur_fl                  NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id              VARCHAR2(30)  NOT NULL,
    -- Risk/opp identity
    risk_opp_id_cd          VARCHAR2(40)  NOT NULL,   -- CDP row id: Risk1, Opp1 etc.
    effect_type_cd          VARCHAR2(10)  NOT NULL,   -- RISK | OPPORTUNITY
    env_domain_cd           VARCHAR2(20)  NOT NULL,   -- ENV_CLIMATE | ENV_WATER | ...
    -- Classification
    risk_category_cd        VARCHAR2(40),             -- ACUTE_PHYSICAL | CHRONIC_PHYSICAL |
                                                      -- POLICY_LEGAL | MARKET | TECHNOLOGY |
                                                      -- LIABILITY | REPUTATION | RESOURCE_EFF |
                                                      -- PRODUCTS_SERVICES | MARKETS | RESILIENCE
    primary_driver_cd       VARCHAR2(80),
    value_chain_stage_cd    VARCHAR2(40),             -- DIRECT_OPS | UPSTREAM | DOWNSTREAM | BOTH
    country_cd              VARCHAR2(10),
    time_horizon_cd         VARCHAR2(20),             -- SHORT | MEDIUM | LONG
    -- Financial effect
    financial_impact_low_nb  NUMBER,
    financial_impact_high_nb NUMBER,
    impact_currency_cd      VARCHAR2(10),
    pct_revenue_vulnerable_nb NUMBER,                 -- 3.1.2
    pct_revenue_aligned_nb    NUMBER,                 -- 3.6.2
    -- Qualitative payload
    description_tx          VARCHAR2(4000),
    strategy_influence_tx   VARCHAR2(4000),           -- 5.3.1
    financial_planning_tx   VARCHAR2(4000),           -- 5.3.2
    CONSTRAINT pk_env_risk_opp PRIMARY KEY
        (entity_key, source_id, coverage_period, risk_opp_id_cd, src_bgn_tran_dt, bgn_tran_dt)
);
```

---

### 5.5 Quantified Item Table (Tier E-adjacent)

The shared pattern for initiatives, low-carbon products, and carbon credits — all repeating
groups with at least one quantified measure alongside descriptive attributes.

```sql
-- Covers 7.55.1 / 7.55.2 (emission reduction initiatives)
--         7.74.1 (low-carbon products and services)
--         7.79.1 (carbon credits retired/canceled)

CREATE TABLE udm_env_quantified_item (
    entity_key              VARCHAR2(20)  NOT NULL,
    source_id               VARCHAR2(20)  NOT NULL,
    coverage_period         VARCHAR2(20)  NOT NULL,
    src_bgn_tran_dt         DATE          NOT NULL,
    src_end_tran_dt         DATE          NOT NULL,
    bgn_tran_dt             DATE          NOT NULL,
    end_tran_dt             DATE          DEFAULT DATE '9999-12-31' NOT NULL,
    cur_fl                  NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id              VARCHAR2(30)  NOT NULL,
    -- Item identity
    item_type_cd            VARCHAR2(30)  NOT NULL,   -- INITIATIVE | LOW_CARBON_PRODUCT | CARBON_CREDIT
    item_seq_nb             NUMBER(6)     NOT NULL,   -- row sequence within entity/period/type
    -- Classification (shared — not all populated for all item types)
    activity_type_cd        VARCHAR2(80),             -- initiative type / product category / credit type
    stage_cd                VARCHAR2(30),             -- PLANNING | IMPLEMENTATION | COMPLETE (initiatives)
    -- Quantified measures
    primary_measure_nb      NUMBER,                   -- CO2e savings (initiative) / revenue (product) / credits (credit)
    primary_measure_unit_tx VARCHAR2(40),
    secondary_measure_nb    NUMBER,                   -- investment req (initiative) / % of revenue (product)
    secondary_measure_unit_tx VARCHAR2(40),
    payback_period_yr_nb    NUMBER,                   -- initiatives
    -- Qualitative payload
    item_nm_tx              VARCHAR2(400),
    description_tx          VARCHAR2(4000),
    CONSTRAINT pk_env_qtf_item PRIMARY KEY
        (entity_key, source_id, coverage_period, item_type_cd, item_seq_nb,
         src_bgn_tran_dt, bgn_tran_dt)
);
```

---

### 5.6 Qualitative Disclosure Table (Tier F — catalog-governed, not open EAV)

```sql
-- Covers everything in storage_pattern_cd = QUAL in udm_cdp_question_catalog:
-- C2 process questions, C4 governance, C5 strategy (scenario text, transition plan),
-- carbon pricing strategy (3.5.4), pollutant management (2.5.1), public policy (4.11.x),
-- and any coded question not mapped to a dedicated table above.

CREATE TABLE udm_env_qual_disclosure (
    entity_key              VARCHAR2(20)  NOT NULL,
    source_id               VARCHAR2(20)  NOT NULL,
    coverage_period         VARCHAR2(20)  NOT NULL,
    src_bgn_tran_dt         DATE          NOT NULL,
    src_end_tran_dt         DATE          NOT NULL,
    bgn_tran_dt             DATE          NOT NULL,
    end_tran_dt             DATE          DEFAULT DATE '9999-12-31' NOT NULL,
    cur_fl                  NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id              VARCHAR2(30)  NOT NULL,
    -- Disclosure identity
    question_cd             VARCHAR2(20)  NOT NULL,   -- FK -> udm_cdp_question_catalog
    question_yr_nb          NUMBER(4)     NOT NULL,
    env_issue_cd            VARCHAR2(20),             -- CLIMATE | WATER | BIODIVERSITY | ALL
                                                      -- (for integrated questions asked per-issue)
    response_seq_nb         NUMBER(4)     DEFAULT 1 NOT NULL,
                                                      -- row counter for [Add Row] groups
    -- Response
    selected_value_cd       VARCHAR2(80),             -- FK -> udm_cdp_question_option
    free_text_tx            VARCHAR2(4000),
    attachment_ref_tx       VARCHAR2(400),            -- document store reference
    CONSTRAINT pk_env_qual PRIMARY KEY
        (entity_key, source_id, coverage_period, question_cd, question_yr_nb,
         env_issue_cd, response_seq_nb, NVL(selected_value_cd,'NULL'),
         src_bgn_tran_dt, bgn_tran_dt),
    CONSTRAINT fk_env_qual_qn FOREIGN KEY (question_cd, question_yr_nb)
        REFERENCES udm_cdp_question_catalog (question_cd, question_yr_nb)
);
```

---

## Part 6 — Routing Decision Rules

The harmonisation engine applies these rules in order to route each source row:

```
1. Look up question_cd in udm_cdp_question_catalog WHERE question_yr_nb = :load_year
2. CASE storage_pattern_cd
     WHEN 'PROVENANCE'  → write to udm_process_run / source metadata; skip fact load
     WHEN 'ENT_ATTR'    → route to udm_company_xref enrichment job; skip fact load
     WHEN 'STACK'       → write target_column_nm value on udm_environmental_risk_stk row
     WHEN 'EMI_BRK'     → write to udm_env_emissions_breakdown
     WHEN 'ENE_BRK'     → write to udm_env_energy_breakdown
     WHEN 'GEN_BRK'     → write to udm_env_generation_breakdown
     WHEN 'FIN_BRK'     → write to udm_env_financial_breakdown
     WHEN 'WTR_BRK'     → write to udm_env_water_breakdown
     WHEN 'TARGET'      → write to udm_env_target
     WHEN 'RISK_OPP'    → write to udm_env_risk_opportunity
     WHEN 'QTF_ITEM'    → write to udm_env_quantified_item
     WHEN 'QUAL'        → write to udm_env_qual_disclosure
     WHEN 'DERIVED'     → skip; computed post-load by derivation engine
   END
3. For STACK rows: pass to udm_arb_engine IF arbitration_cd = 'ARBITRABLE'
4. For all others: bi-temporal close + insert (same as stack, no arbitration waterfall)
```

Adding a new CDP year = **UPDATE udm_cdp_question_catalog** for changed questions +
**INSERT** for new questions. No pipeline code changes.

---

## Part 7 — Table Inventory Summary

| Layer | Table | Rows contain | Arbitrated |
|---|---|---|---|
| Stack | `udm_environmental_risk_stk` | 23 scalar data items (CDP columns) | Yes (emissions scalars) |
| Breakdown | `udm_env_emissions_breakdown` | ~15 question codes → rows by scope+dim | No |
| Breakdown | `udm_env_energy_breakdown` | ~12 question codes → rows by form+dim | No |
| Breakdown | `udm_env_generation_breakdown` | 1.16.1, 7.46 → rows by power_source | No |
| Breakdown | `udm_env_financial_breakdown` | 5.4.1, 5.7, 5.9 → rows by flow+dim | No |
| Breakdown | `udm_env_water_breakdown` | 9.2.7, 9.2.8, 9.2.10, 9.3.1 → rows by aspect+dim | No |
| Commitment | `udm_env_target` | 7.53.x, 7.54.x, 9.15.2, 10.1 — same table as MSCI | Partial |
| Assessment | `udm_env_risk_opportunity` | 3.1.1, 3.6.1, 5.3.1/5.3.2 | No |
| Quantified | `udm_env_quantified_item` | 7.55.2, 7.74.1, 7.79.1 | No |
| Qualitative | `udm_env_qual_disclosure` | ~80 QUAL-pattern question codes | No |
| Catalog | `udm_cdp_question_catalog` | ~350-400 question codes classified | — |
| Catalog | `udm_cdp_question_option` | coded picklist values per question | — |
| Reference | `udm_env_breakdown_member_ref` | GHG types, power sources, fuel types, countries | — |

**Net: 9 fact/commitment tables + 3 catalog/reference tables. All ~350-400 CDP question codes
routed without DDL changes.**

---

## Part 8 — What Changed From v1

| Item | v1 | v2 |
|---|---|---|
| Energy questions | Bundled into financial_breakdown | Separate `udm_env_energy_breakdown` — MWh ≠ $ |
| Initiatives, low-carbon products, carbon credits | Mentioned but unmodelled | `udm_env_quantified_item` with `item_type_cd` discriminator |
| CAPEX alignment (5.4.x) | Not modelled (missed in fetch) | Added as STACK scalar data items (new 2024, IFRS S2-driven) |
| Verification flags (7.9.x) | Not modelled | `verified_scope1_fl` / `verified_scope2_fl` on stack (PCAF tier impact) |
| CDP question catalog | Conceptual only | Full DDL with all 5 classification dimensions |
| Routing decision | Narrative | Explicit CASE rules tied to `storage_pattern_cd` |
| Sector-specific questions | Noted but not classified | `is_universal_fl` + `sector_cd` columns on catalog |

---

## Part 9 — Open Items (additions to v8 §8)

| ID | Item | Decision needed |
|---|---|---|
| CDP-01 | Environmental risk sub-domain name (OPN-002) | Confirms physical table names |
| CDP-06 | 5.4.x CAPEX taxonomy alignment — columns on env_risk_stk or separate sub-domain? | Might suit a finance/strategy sub-domain better than environmental risk |
| CDP-07 | 7.37–7.44 production data (coal reserves, hydrocarbon, refinery) — physical asset sub-domain? | Needs sub-domain scope decision |
| CDP-08 | 7.52 "additional metrics" — company-defined open field | Cannot normalise into stack without bespoke per-company mapping; recommend qual_disclosure with numeric extension column |
| CDP-09 | CDP as precedence rule vendor — at which priority level vs MSCI? | Affects waterfall for scope 1/2 scalars |
| CDP-10 | Carbon pricing ETS data (3.5.2, 3.5.3) — financial materiality warrants STACK items? | ETS allowance price, tons regulated — potentially arbitrable against Refinitiv carbon pricing data |

---

*v2 — June 2026. Derived from full CDP 2024 guidance documents (primary source),
not from a single company export.*
