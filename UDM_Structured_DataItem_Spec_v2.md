# UDM Structured Data Item — Implementation Specification v2
## ESG Structured Data: Storage, Cataloguing & Harmonisation

**Audience:** UDM development team
**Status:** Build specification — v2 (supersedes v1)
**Sources:** ESGbook, CDP 2024
**Oracle version:** 19c+

---

## 1. Design Summary

### 1.1 Two layers, two load paths

All structured ESG data splits into two layers based on one question:
**can this cell be arbitrated across multiple vendors?**

```
                    is_arbitrable_fl = 1          is_arbitrable_fl = 0
                    ┌─────────────────────┐        ┌─────────────────────┐
                    │  GOVERNED LAYER      │        │  DISCLOSURE LAYER   │
                    │                      │        │                     │
                    │  udm_env_risk_stk    │        │  udm_esg_disclosure │
                    │  udm_emissions_target│        │                     │
                    │  udm_production      │        │                     │
                    └─────────────────────┘        └─────────────────────┘
                    Full bi-temporal +              Bi-temporal only.
                    arbitration waterfall.          No golden copy.
                    is_golden_fl set by arb         Consumer sees all sources.
                    engine (separate process).      is_golden_fl not used.
```

Harmonisation **only stacks** — it writes rows to the target table with the bi-temporal
envelope. Arbitration is a separate downstream process. The harmonisation engine does not
need to know which layer a data item belongs to — it reads the catalog and writes where it
is told.

### 1.2 Two load paths in the harmonisation engine

```
SCALAR   source attribute → named column on udm_env_risk_stk
STRUCT   source array/map → one row per dimensional cell on the target table
```

`load_path_cd` on `udm_data_item_src_map` drives the branch. No other logic.

### 1.3 Final fact table inventory

| Table | Layer | Pattern | Grain |
|---|---|---|---|
| `udm_env_risk_stk` | Governed | SCALAR | entity × period × source |
| `udm_emissions_target` | Governed | STRUCT | entity × period × source × target_id |
| `udm_production` | Governed | STRUCT | entity × period × source × asset × measure |
| `udm_esg_disclosure` | Disclosure | STRUCT | entity × period × source × data_item × dimension |

---

## 2. Physical Tables

### 2.1 `udm_env_risk_stk` — scalar governed metrics

One wide row per entity × source × period. Each scalar data item is a named column.
New data items = DDL (ALTER TABLE ADD COLUMN). Columns shown are the ESG-relevant subset;
full stack includes all UDM domains.

```sql
CREATE TABLE udm_env_risk_stk (
    entity_key                  VARCHAR2(20)  NOT NULL,
    source_id                   VARCHAR2(20)  NOT NULL,
    coverage_period             VARCHAR2(20)  NOT NULL,
    -- Emissions scalars
    scope1_mtco2e               NUMBER,
    scope2_location_mtco2e      NUMBER,
    scope2_market_mtco2e        NUMBER,
    scope3_total_mtco2e         NUMBER,
    scope1_scope2_mtco2e        NUMBER,       -- combined
    base_year_scope1_mtco2e     NUMBER,
    base_year_nb                NUMBER(4),
    biogenic_co2_mtco2          NUMBER,
    -- Intensity scalars
    scope1_scope2_intensity_rev NUMBER,       -- tCO2e per USD M revenue
    -- Energy scalars
    total_energy_mwh            NUMBER,
    -- Financial scalars
    evic_usd_nb                 NUMBER,
    internal_carbon_price_low   NUMBER,
    internal_carbon_price_high  NUMBER,
    capex_climate_aligned_pct   NUMBER,
    -- Water scalars
    total_water_withdrawal_ml   NUMBER,
    total_water_discharge_ml    NUMBER,
    total_water_consumption_ml  NUMBER,
    -- Verification flags
    scope1_verified_fl          NUMBER(1),
    scope2_verified_fl          NUMBER(1),
    -- Bi-temporal envelope
    src_bgn_tran_dt             DATE          NOT NULL,
    src_end_tran_dt             DATE          NOT NULL,
    bgn_tran_dt                 DATE          NOT NULL,
    end_tran_dt                 DATE DEFAULT  DATE '9999-12-31' NOT NULL,
    cur_fl                      NUMBER(1)     DEFAULT 1 NOT NULL,
    is_golden_fl                NUMBER(1)     DEFAULT 0 NOT NULL,
    lineage_id                  VARCHAR2(30)  NOT NULL,
    CONSTRAINT pk_env_risk_stk PRIMARY KEY
        (entity_key, source_id, coverage_period, src_bgn_tran_dt, bgn_tran_dt)
)
PARTITION BY LIST (coverage_period) AUTOMATIC;
```

### 2.2 `udm_emissions_target` — governed targets

```sql
CREATE TABLE udm_emissions_target (
    entity_key              VARCHAR2(20)  NOT NULL,
    source_id               VARCHAR2(20)  NOT NULL,
    coverage_period         VARCHAR2(20)  NOT NULL,
    data_item_cd            VARCHAR2(30)  NOT NULL,   -- 67100|67200|67300|67400
    obs_id                  VARCHAR2(40)  DEFAULT '1' NOT NULL,
    target_type_cd          VARCHAR2(30)  NOT NULL,
    scope_cd                VARCHAR2(40)  NOT NULL,   -- combo e.g. S1+S2+S3
    target_year_nb          NUMBER(4),
    base_year_nb            NUMBER(4),
    base_value_nb           NUMBER,
    target_value_nb         NUMBER,
    pct_reduction_nb        NUMBER,
    pct_achieved_nb         NUMBER,
    target_status_cd        VARCHAR2(30),
    is_science_based_fl     NUMBER(1),
    is_net_zero_fl          NUMBER(1),
    temperature_align_cd    VARCHAR2(20),
    commitment_dt           DATE,
    detail_tx               VARCHAR2(4000),
    src_bgn_tran_dt         DATE          NOT NULL,
    src_end_tran_dt         DATE          NOT NULL,
    bgn_tran_dt             DATE          NOT NULL,
    end_tran_dt             DATE DEFAULT  DATE '9999-12-31' NOT NULL,
    cur_fl                  NUMBER(1)     DEFAULT 1 NOT NULL,
    is_golden_fl            NUMBER(1)     DEFAULT 0 NOT NULL,
    lineage_id              VARCHAR2(30)  NOT NULL,
    CONSTRAINT pk_emissions_target PRIMARY KEY
        (entity_key, source_id, coverage_period,
         data_item_cd, obs_id, src_bgn_tran_dt, bgn_tran_dt)
)
PARTITION BY LIST (coverage_period) AUTOMATIC;
```

### 2.3 `udm_production` — physical production metrics

```sql
CREATE TABLE udm_production (
    entity_key              VARCHAR2(20)  NOT NULL,
    source_id               VARCHAR2(20)  NOT NULL,
    coverage_period         VARCHAR2(20)  NOT NULL,
    asset_type_cd           VARCHAR2(40)  NOT NULL,   -- COAL|BIOMASS|WIND|SOLAR|GAS|NUCLEAR|OIL
    measure_type_cd         VARCHAR2(30)  NOT NULL,   -- CAPACITY|NET_GENERATION|FUEL_CONSUMPTION
    value_nb                NUMBER        NOT NULL,
    unit_cd                 VARCHAR2(20)  NOT NULL,   -- MW|GWH|MWH|TONNES
    is_combined_fl          NUMBER(1)     DEFAULT 0,
    reported_combo_tx       VARCHAR2(200),
    src_bgn_tran_dt         DATE          NOT NULL,
    src_end_tran_dt         DATE          NOT NULL,
    bgn_tran_dt             DATE          NOT NULL,
    end_tran_dt             DATE DEFAULT  DATE '9999-12-31' NOT NULL,
    cur_fl                  NUMBER(1)     DEFAULT 1 NOT NULL,
    is_golden_fl            NUMBER(1)     DEFAULT 0 NOT NULL,
    lineage_id              VARCHAR2(30)  NOT NULL,
    CONSTRAINT pk_production PRIMARY KEY
        (entity_key, source_id, coverage_period,
         asset_type_cd, measure_type_cd, src_bgn_tran_dt, bgn_tran_dt)
)
PARTITION BY LIST (coverage_period) AUTOMATIC;
```

### 2.4 `udm_esg_disclosure` — all non-arbitrated structured disclosures

One flat table. `data_item_cd + breakdown_type_cd + dimension_cd` define the cell.
Covers: emission intensities, emissions by fuel/GHG/country/S3-category, assurance,
water breakdowns, production where single-source.

```sql
CREATE TABLE udm_esg_disclosure (
    entity_key              VARCHAR2(20)  NOT NULL,
    source_id               VARCHAR2(20)  NOT NULL,
    coverage_period         VARCHAR2(20)  NOT NULL,
    data_item_cd            VARCHAR2(30)  NOT NULL,   -- 65100|66100|66200|SCOPE3_BY_CAT|...
    obs_id                  VARCHAR2(40)  DEFAULT '1' NOT NULL,
    breakdown_type_cd       VARCHAR2(30)  NOT NULL,   -- TOTAL|S3_CATEGORY|GHG_TYPE|FUEL_TYPE|
                                                      -- COUNTRY|SCOPE_CATEGORY|ASSURANCE|
                                                      -- INTENSITY|PRODUCTION
    dimension_cd            VARCHAR2(100) NOT NULL,   -- S3_CAT_1|GHG_CO2|FUEL_COAL|S1+S2/REVENUE
                                                      -- or composite: scope_cd/category_cd
    value_nb                NUMBER,                   -- numeric value; NULL for coded responses
    value_tx                VARCHAR2(400),            -- coded or text value; NULL for numeric
    unit_cd                 VARCHAR2(40),
    is_combined_fl          NUMBER(1)     DEFAULT 0,  -- 1 = value covers multiple dimensions
    reported_combo_tx       VARCHAR2(200),            -- what the source actually sent
    src_bgn_tran_dt         DATE          NOT NULL,
    src_end_tran_dt         DATE          NOT NULL,
    bgn_tran_dt             DATE          NOT NULL,
    end_tran_dt             DATE DEFAULT  DATE '9999-12-31' NOT NULL,
    cur_fl                  NUMBER(1)     DEFAULT 1 NOT NULL,
    lineage_id              VARCHAR2(30)  NOT NULL,
    CONSTRAINT pk_esg_disclosure PRIMARY KEY
        (entity_key, source_id, coverage_period,
         data_item_cd, obs_id, breakdown_type_cd, dimension_cd,
         src_bgn_tran_dt, bgn_tran_dt)
)
PARTITION BY LIST (coverage_period) AUTOMATIC;
```

**Consumer query — Scope 3 Cat 1 and Cat 4:**
```sql
SELECT entity_key, coverage_period, dimension_cd, value_nb, unit_cd
FROM   udm_esg_disclosure
WHERE  data_item_cd      = 'SCOPE3_EMISSIONS'
AND    breakdown_type_cd = 'S3_CATEGORY'
AND    dimension_cd      IN ('S3_CAT_1','S3_CAT_4')
AND    coverage_period   = '2023'
AND    cur_fl            = 1;
```

---

## 3. Catalog Tables

### 3.1 `udm_data_item`

```sql
CREATE TABLE udm_data_item (
    data_item_cd        VARCHAR2(30)  NOT NULL,
    data_item_nm        VARCHAR2(200) NOT NULL,
    domain_cd           VARCHAR2(20)  NOT NULL,       -- ENV_CLIMATE|ENV_WATER|...
    storage_pattern_cd  VARCHAR2(10)  NOT NULL,       -- STACK|STRUCT
    is_arbitrable_fl    NUMBER(1)     DEFAULT 0,      -- 1 = governed layer
    target_table_nm     VARCHAR2(80)  NOT NULL,       -- physical table
    target_column_nm    VARCHAR2(80),                 -- STACK only; NULL for STRUCT
    unit_cd             VARCHAR2(40),
    description_tx      VARCHAR2(400),
    CONSTRAINT pk_data_item PRIMARY KEY (data_item_cd)
);
```

### 3.2 `udm_data_item_src_map`

One row per (data_item, source). For STRUCT items, also carries the dimensional
routing columns that tell the engine what breakdown_type and dimension to write.

```sql
CREATE TABLE udm_data_item_src_map (
    data_item_cd        VARCHAR2(30)  NOT NULL,
    source_id           VARCHAR2(20)  NOT NULL,
    src_object_nm       VARCHAR2(80)  NOT NULL,       -- source view name
    load_path_cd        VARCHAR2(10)  NOT NULL,       -- SCALAR|STRUCT
    -- STRUCT routing
    target_table_nm     VARCHAR2(80),
    breakdown_type_cd   VARCHAR2(30),
    struct_shape_cd     VARCHAR2(15),                 -- MAP|ARRAY_OF_MAP
    -- SCALAR routing (if different from data_item default)
    target_column_nm    VARCHAR2(80),
    CONSTRAINT pk_data_item_src_map PRIMARY KEY (data_item_cd, source_id)
);
```

### 3.3 `udm_src_code_map` — label to canonical translation

Used **only inside source views**. Never queried by the engine.

```sql
CREATE TABLE udm_src_code_map (
    source_id       VARCHAR2(20)  NOT NULL,
    code_type_cd    VARCHAR2(30)  NOT NULL,
    src_label_tx    VARCHAR2(200) NOT NULL,
    canonical_cd    VARCHAR2(40)  NOT NULL,
    CONSTRAINT pk_src_code_map PRIMARY KEY (source_id, code_type_cd, src_label_tx)
);
```

### 3.4 `udm_src_attribute_map` — for encoded-column-name sources

Maps a source column name to its canonical cell definition. Used for sources that
encode dimensional information in the column name rather than a separate field.
See §6 for full detail.

```sql
CREATE TABLE udm_src_attribute_map (
    source_id           VARCHAR2(20)  NOT NULL,
    src_column_nm       VARCHAR2(200) NOT NULL,
    data_item_cd        VARCHAR2(30)  NOT NULL,
    load_path_cd        VARCHAR2(10)  NOT NULL,       -- SCALAR|STRUCT
    target_table_nm     VARCHAR2(80)  NOT NULL,
    target_column_nm    VARCHAR2(80),                 -- SCALAR only
    breakdown_type_cd   VARCHAR2(30),                 -- STRUCT only
    dimension_cd        VARCHAR2(100),                -- STRUCT only; the canonical cell dimension
    scope_cd            VARCHAR2(40),                 -- if scope is encoded
    unit_cd             VARCHAR2(40),
    CONSTRAINT pk_src_attribute_map PRIMARY KEY (source_id, src_column_nm)
);
```

---

## 4. Seed Data

### 4.1 `udm_data_item` — scalar data items (STACK)

```sql
INSERT ALL
  INTO udm_data_item VALUES ('SCOPE1_MTCO2E','Scope 1 GHG Emissions','ENV_CLIMATE','STACK',1,'udm_env_risk_stk','scope1_mtco2e','mtCO2e',NULL)
  INTO udm_data_item VALUES ('SCOPE2_LOC_MTCO2E','Scope 2 Location-Based','ENV_CLIMATE','STACK',1,'udm_env_risk_stk','scope2_location_mtco2e','mtCO2e',NULL)
  INTO udm_data_item VALUES ('SCOPE2_MKT_MTCO2E','Scope 2 Market-Based','ENV_CLIMATE','STACK',1,'udm_env_risk_stk','scope2_market_mtco2e','mtCO2e',NULL)
  INTO udm_data_item VALUES ('SCOPE3_TOTAL_MTCO2E','Scope 3 Total Emissions','ENV_CLIMATE','STACK',1,'udm_env_risk_stk','scope3_total_mtco2e','mtCO2e',NULL)
  INTO udm_data_item VALUES ('SCOPE1_SCOPE2_MTCO2E','Scope 1+2 Combined','ENV_CLIMATE','STACK',1,'udm_env_risk_stk','scope1_scope2_mtco2e','mtCO2e',NULL)
  INTO udm_data_item VALUES ('BASE_YR_SCOPE1','Base Year Scope 1','ENV_CLIMATE','STACK',1,'udm_env_risk_stk','base_year_scope1_mtco2e','mtCO2e',NULL)
  INTO udm_data_item VALUES ('BASE_YEAR_NB','Base Year','ENV_CLIMATE','STACK',1,'udm_env_risk_stk','base_year_nb',NULL,NULL)
  INTO udm_data_item VALUES ('BIOGENIC_CO2','Biogenic CO2','ENV_CLIMATE','STACK',0,'udm_env_risk_stk','biogenic_co2_mtco2','mtCO2',NULL)
  INTO udm_data_item VALUES ('S1S2_INTENSITY_REV','Scope 1+2 Intensity per Revenue','ENV_CLIMATE','STACK',1,'udm_env_risk_stk','scope1_scope2_intensity_rev','tCO2e/USDM',NULL)
  INTO udm_data_item VALUES ('TOTAL_ENERGY_MWH','Total Energy Consumption','ENV_CLIMATE','STACK',0,'udm_env_risk_stk','total_energy_mwh','MWh',NULL)
  INTO udm_data_item VALUES ('EVIC_USD','Enterprise Value Inc Cash','FINANCIAL','STACK',1,'udm_env_risk_stk','evic_usd_nb','USD',NULL)
  INTO udm_data_item VALUES ('INT_CARBON_PRICE_LOW','Internal Carbon Price Low','ENV_CLIMATE','STACK',0,'udm_env_risk_stk','internal_carbon_price_low','USD/tCO2e',NULL)
  INTO udm_data_item VALUES ('INT_CARBON_PRICE_HIGH','Internal Carbon Price High','ENV_CLIMATE','STACK',0,'udm_env_risk_stk','internal_carbon_price_high','USD/tCO2e',NULL)
  INTO udm_data_item VALUES ('CAPEX_CLIMATE_PCT','CAPEX Climate Aligned %','ENV_CLIMATE','STACK',0,'udm_env_risk_stk','capex_climate_aligned_pct','%',NULL)
  INTO udm_data_item VALUES ('WATER_WITHDRAWAL_ML','Total Water Withdrawal','ENV_WATER','STACK',0,'udm_env_risk_stk','total_water_withdrawal_ml','ML',NULL)
  INTO udm_data_item VALUES ('WATER_DISCHARGE_ML','Total Water Discharge','ENV_WATER','STACK',0,'udm_env_risk_stk','total_water_discharge_ml','ML',NULL)
  INTO udm_data_item VALUES ('SCOPE1_VERIFIED_FL','Scope 1 Verification Flag','ENV_CLIMATE','STACK',0,'udm_env_risk_stk','scope1_verified_fl',NULL,NULL)
SELECT 1 FROM DUAL;
```

### 4.2 `udm_data_item` — struct data items

```sql
INSERT ALL
  -- Emission Intensities
  INTO udm_data_item VALUES ('65100','Emission Intensities','ENV_CLIMATE','STRUCT',0,'udm_esg_disclosure',NULL,'tCO2e/unit','Array of scope+category intensity values')
  -- Assurance
  INTO udm_data_item VALUES ('66100','Scope 1 Assurance','ENV_CLIMATE','STRUCT',0,'udm_esg_disclosure',NULL,NULL,'Scope 1 emissions assurance metadata')
  INTO udm_data_item VALUES ('66200','Scope 2 Location Assurance','ENV_CLIMATE','STRUCT',0,'udm_esg_disclosure',NULL,NULL,NULL)
  INTO udm_data_item VALUES ('66300','Scope 2 Market Assurance','ENV_CLIMATE','STRUCT',0,'udm_esg_disclosure',NULL,NULL,NULL)
  INTO udm_data_item VALUES ('66400','Scope 3 Assurance','ENV_CLIMATE','STRUCT',0,'udm_esg_disclosure',NULL,NULL,NULL)
  INTO udm_data_item VALUES ('66500','Scope 3 Assurance Details','ENV_CLIMATE','STRUCT',0,'udm_esg_disclosure',NULL,NULL,NULL)
  -- Targets
  INTO udm_data_item VALUES ('67100','Renewable Energy Target','ENV_CLIMATE','STRUCT',0,'udm_esg_disclosure',NULL,NULL,'MAP — single target')
  INTO udm_data_item VALUES ('67200','SBTi Target Commitment','ENV_CLIMATE','STRUCT',1,'udm_emissions_target',NULL,NULL,'MAP — single SBTi')
  INTO udm_data_item VALUES ('67300','Net Zero Targets','ENV_CLIMATE','STRUCT',1,'udm_emissions_target',NULL,NULL,'ARRAY — multiple targets')
  INTO udm_data_item VALUES ('67400','Emissions Reduction Targets','ENV_CLIMATE','STRUCT',1,'udm_emissions_target',NULL,NULL,'ARRAY — multiple targets')
  -- Emissions breakdowns (disclosure)
  INTO udm_data_item VALUES ('SCOPE3_BY_CAT','Scope 3 by Category','ENV_CLIMATE','STRUCT',0,'udm_esg_disclosure',NULL,'mtCO2e','S3 emissions per GHG Protocol category')
  INTO udm_data_item VALUES ('SCOPE1_BY_GHG','Scope 1 by GHG Type','ENV_CLIMATE','STRUCT',0,'udm_esg_disclosure',NULL,'mtCO2e',NULL)
  INTO udm_data_item VALUES ('SCOPE1_BY_FUEL','Scope 1 by Fuel Type','ENV_CLIMATE','STRUCT',0,'udm_esg_disclosure',NULL,'mtCO2e',NULL)
  INTO udm_data_item VALUES ('SCOPE1_BY_COUNTRY','Scope 1+2 by Country','ENV_CLIMATE','STRUCT',0,'udm_esg_disclosure',NULL,'mtCO2e',NULL)
  -- Production
  INTO udm_data_item VALUES ('POWER_PRODUCTION','Power Generation & Capacity','ENV_CLIMATE','STRUCT',1,'udm_production',NULL,NULL,'Capacity MW and generation GWh by asset type')
SELECT 1 FROM DUAL;
```

### 4.3 `udm_data_item_src_map` — ESGbook and CDP sources

```sql
INSERT ALL
  -- SCALAR: ESGbook
  INTO udm_data_item_src_map VALUES ('SCOPE1_MTCO2E','ESGBOOK','VW_ESGBOOK_SCALAR','SCALAR','udm_env_risk_stk',NULL,'scope1_mtco2e',NULL)
  INTO udm_data_item_src_map VALUES ('SCOPE2_LOC_MTCO2E','ESGBOOK','VW_ESGBOOK_SCALAR','SCALAR','udm_env_risk_stk',NULL,'scope2_location_mtco2e',NULL)
  INTO udm_data_item_src_map VALUES ('SCOPE2_MKT_MTCO2E','ESGBOOK','VW_ESGBOOK_SCALAR','SCALAR','udm_env_risk_stk',NULL,'scope2_market_mtco2e',NULL)
  INTO udm_data_item_src_map VALUES ('SCOPE3_TOTAL_MTCO2E','ESGBOOK','VW_ESGBOOK_SCALAR','SCALAR','udm_env_risk_stk',NULL,'scope3_total_mtco2e',NULL)
  INTO udm_data_item_src_map VALUES ('EVIC_USD','ESGBOOK','VW_ESGBOOK_SCALAR','SCALAR','udm_env_risk_stk',NULL,'evic_usd_nb',NULL)
  -- SCALAR: CDP
  INTO udm_data_item_src_map VALUES ('SCOPE1_MTCO2E','CDP_2024','VW_CDP_SCALAR','SCALAR','udm_env_risk_stk',NULL,'scope1_mtco2e',NULL)
  INTO udm_data_item_src_map VALUES ('SCOPE2_LOC_MTCO2E','CDP_2024','VW_CDP_SCALAR','SCALAR','udm_env_risk_stk',NULL,'scope2_location_mtco2e',NULL)
  INTO udm_data_item_src_map VALUES ('SCOPE3_TOTAL_MTCO2E','CDP_2024','VW_CDP_SCALAR','SCALAR','udm_env_risk_stk',NULL,'scope3_total_mtco2e',NULL)
  INTO udm_data_item_src_map VALUES ('INT_CARBON_PRICE_LOW','CDP_2024','VW_CDP_SCALAR','SCALAR','udm_env_risk_stk',NULL,'internal_carbon_price_low',NULL)
  -- STRUCT: ESGbook disclosure
  INTO udm_data_item_src_map VALUES ('65100','ESGBOOK','VW_ESGBOOK_65100','STRUCT','udm_esg_disclosure','INTENSITY','ARRAY_OF_MAP',NULL)
  INTO udm_data_item_src_map VALUES ('66100','ESGBOOK','VW_ESGBOOK_66100','STRUCT','udm_esg_disclosure','ASSURANCE','MAP',NULL)
  INTO udm_data_item_src_map VALUES ('66200','ESGBOOK','VW_ESGBOOK_66200','STRUCT','udm_esg_disclosure','ASSURANCE','MAP',NULL)
  INTO udm_data_item_src_map VALUES ('66300','ESGBOOK','VW_ESGBOOK_66300','STRUCT','udm_esg_disclosure','ASSURANCE','MAP',NULL)
  INTO udm_data_item_src_map VALUES ('66400','ESGBOOK','VW_ESGBOOK_66400','STRUCT','udm_esg_disclosure','ASSURANCE','MAP',NULL)
  INTO udm_data_item_src_map VALUES ('SCOPE3_BY_CAT','ESGBOOK','VW_ESGBOOK_S3CAT','STRUCT','udm_esg_disclosure','S3_CATEGORY','ARRAY_OF_MAP',NULL)
  INTO udm_data_item_src_map VALUES ('SCOPE1_BY_GHG','ESGBOOK','VW_ESGBOOK_GHG','STRUCT','udm_esg_disclosure','GHG_TYPE','ARRAY_OF_MAP',NULL)
  INTO udm_data_item_src_map VALUES ('SCOPE1_BY_FUEL','ESGBOOK','VW_ESGBOOK_FUEL','STRUCT','udm_esg_disclosure','FUEL_TYPE','ARRAY_OF_MAP',NULL)
  -- STRUCT: ESGbook governed
  INTO udm_data_item_src_map VALUES ('67300','ESGBOOK','VW_ESGBOOK_67300','STRUCT','udm_emissions_target','TARGET','ARRAY_OF_MAP',NULL)
  INTO udm_data_item_src_map VALUES ('67400','ESGBOOK','VW_ESGBOOK_67400','STRUCT','udm_emissions_target','TARGET','ARRAY_OF_MAP',NULL)
  INTO udm_data_item_src_map VALUES ('67200','ESGBOOK','VW_ESGBOOK_67200','STRUCT','udm_emissions_target','TARGET','MAP',NULL)
  INTO udm_data_item_src_map VALUES ('POWER_PRODUCTION','ESGBOOK','VW_ESGBOOK_PROD','STRUCT','udm_production','PRODUCTION','ARRAY_OF_MAP',NULL)
  -- STRUCT: CDP
  INTO udm_data_item_src_map VALUES ('SCOPE3_BY_CAT','CDP_2024','VW_CDP_S3CAT','STRUCT','udm_esg_disclosure','S3_CATEGORY','ARRAY_OF_MAP',NULL)
  INTO udm_data_item_src_map VALUES ('67300','CDP_2024','VW_CDP_67300','STRUCT','udm_emissions_target','TARGET','ARRAY_OF_MAP',NULL)
  INTO udm_data_item_src_map VALUES ('67400','CDP_2024','VW_CDP_67400','STRUCT','udm_emissions_target','TARGET','ARRAY_OF_MAP',NULL)
  INTO udm_data_item_src_map VALUES ('POWER_PRODUCTION','CDP_2024','VW_CDP_PROD','STRUCT','udm_production','PRODUCTION','ARRAY_OF_MAP',NULL)
SELECT 1 FROM DUAL;
```

### 4.4 `udm_src_code_map` — label translations

```sql
INSERT ALL
  -- ESGbook scope labels
  INTO udm_src_code_map VALUES ('ESGBOOK','SCOPE','Scope1','S1')
  INTO udm_src_code_map VALUES ('ESGBOOK','SCOPE','Scope2','S2')
  INTO udm_src_code_map VALUES ('ESGBOOK','SCOPE','Scope3','S3')
  INTO udm_src_code_map VALUES ('ESGBOOK','SCOPE','Scope1+2','S1+S2')
  INTO udm_src_code_map VALUES ('ESGBOOK','SCOPE','Scope1+2+3','S1+S2+S3')
  -- ESGbook category/denominator
  INTO udm_src_code_map VALUES ('ESGBOOK','DENOMINATOR','Revenue','REVENUE')
  INTO udm_src_code_map VALUES ('ESGBOOK','DENOMINATOR','MWhGenerated','MWH_GENERATED')
  INTO udm_src_code_map VALUES ('ESGBOOK','DENOMINATOR','MWhConsumed','MWH_CONSUMED')
  INTO udm_src_code_map VALUES ('ESGBOOK','DENOMINATOR','EmployeeCount','EMPLOYEES')
  -- ESGbook GHG types
  INTO udm_src_code_map VALUES ('ESGBOOK','GHG_TYPE','CO2','GHG_CO2')
  INTO udm_src_code_map VALUES ('ESGBOOK','GHG_TYPE','CH4','GHG_CH4')
  INTO udm_src_code_map VALUES ('ESGBOOK','GHG_TYPE','N2O','GHG_N2O')
  INTO udm_src_code_map VALUES ('ESGBOOK','GHG_TYPE','HFCs','GHG_HFC')
  -- ESGbook fuel types
  INTO udm_src_code_map VALUES ('ESGBOOK','FUEL_TYPE','Coal','FUEL_COAL')
  INTO udm_src_code_map VALUES ('ESGBOOK','FUEL_TYPE','Oil','FUEL_OIL')
  INTO udm_src_code_map VALUES ('ESGBOOK','FUEL_TYPE','NaturalGas','FUEL_GAS')
  INTO udm_src_code_map VALUES ('ESGBOOK','FUEL_TYPE','Biomass','FUEL_BIOMASS')
  -- ESGbook target types
  INTO udm_src_code_map VALUES ('ESGBOOK','TARGET_TYPE','NetZero','NET_ZERO')
  INTO udm_src_code_map VALUES ('ESGBOOK','TARGET_TYPE','AbsoluteReduction','ABSOLUTE_REDUCTION')
  INTO udm_src_code_map VALUES ('ESGBOOK','TARGET_TYPE','IntensityReduction','INTENSITY_REDUCTION')
  INTO udm_src_code_map VALUES ('ESGBOOK','TARGET_TYPE','RenewableEnergy','RENEWABLE_ENERGY')
  -- ESGbook asset types (production)
  INTO udm_src_code_map VALUES ('ESGBOOK','ASSET_TYPE','Coal','COAL')
  INTO udm_src_code_map VALUES ('ESGBOOK','ASSET_TYPE','Biomass','BIOMASS')
  INTO udm_src_code_map VALUES ('ESGBOOK','ASSET_TYPE','Wind','WIND')
  INTO udm_src_code_map VALUES ('ESGBOOK','ASSET_TYPE','Solar','SOLAR')
  INTO udm_src_code_map VALUES ('ESGBOOK','ASSET_TYPE','Gas','GAS')
  INTO udm_src_code_map VALUES ('ESGBOOK','ASSET_TYPE','Nuclear','NUCLEAR')
  INTO udm_src_code_map VALUES ('ESGBOOK','ASSET_TYPE','Hydro','HYDRO')
  -- CDP scope labels
  INTO udm_src_code_map VALUES ('CDP_2024','SCOPE','Scope 1','S1')
  INTO udm_src_code_map VALUES ('CDP_2024','SCOPE','Scope 2 (location-based)','S2')
  INTO udm_src_code_map VALUES ('CDP_2024','SCOPE','Scope 2 (market-based)','S2_MKT')
  INTO udm_src_code_map VALUES ('CDP_2024','SCOPE','Scope 3','S3')
  INTO udm_src_code_map VALUES ('CDP_2024','SCOPE','Combined Scope 1 and 2','S1+S2')
  -- CDP denominators
  INTO udm_src_code_map VALUES ('CDP_2024','DENOMINATOR','unit total revenue','REVENUE')
  INTO udm_src_code_map VALUES ('CDP_2024','DENOMINATOR','per MWh generated','MWH_GENERATED')
  -- CDP target types
  INTO udm_src_code_map VALUES ('CDP_2024','TARGET_TYPE','Absolute','ABSOLUTE_REDUCTION')
  INTO udm_src_code_map VALUES ('CDP_2024','TARGET_TYPE','Net-zero','NET_ZERO')
  INTO udm_src_code_map VALUES ('CDP_2024','TARGET_TYPE','Intensity','INTENSITY_REDUCTION')
SELECT 1 FROM DUAL;
```

---

## 5. Harmonisation Engine

### 5.1 Global Temporary Tables (GTTs)

GTTs hold intermediate results per session. No redo log overhead. Automatically cleared
after each commit. All processing happens in GTT — permanent tables are touched only for
the final SCD2 close and insert operations.

```sql
-- Stage 1: raw rows from source view, before entity resolution
CREATE GLOBAL TEMPORARY TABLE gtt_hrm_inbound (
    row_id              NUMBER         GENERATED ALWAYS AS IDENTITY,
    src_entity_id       VARCHAR2(100)  NOT NULL,
    coverage_period     VARCHAR2(20)   NOT NULL,
    data_item_cd        VARCHAR2(30)   NOT NULL,
    load_path_cd        VARCHAR2(10)   NOT NULL,
    target_table_nm     VARCHAR2(80)   NOT NULL,
    target_column_nm    VARCHAR2(80),
    obs_id              VARCHAR2(40),
    breakdown_type_cd   VARCHAR2(30),
    dimension_cd        VARCHAR2(100),
    value_nb            NUMBER,
    value_tx            VARCHAR2(4000),
    unit_cd             VARCHAR2(40),
    is_combined_fl      NUMBER(1),
    reported_combo_tx   VARCHAR2(200)
) ON COMMIT DELETE ROWS;

-- Stage 2: entity-resolved rows
CREATE GLOBAL TEMPORARY TABLE gtt_hrm_resolved (
    row_id              NUMBER,
    entity_key          VARCHAR2(20),
    coverage_period     VARCHAR2(20),
    data_item_cd        VARCHAR2(30),
    load_path_cd        VARCHAR2(10),
    target_table_nm     VARCHAR2(80),
    target_column_nm    VARCHAR2(80),
    obs_id              VARCHAR2(40),
    breakdown_type_cd   VARCHAR2(30),
    dimension_cd        VARCHAR2(100),
    value_nb            NUMBER,
    value_tx            VARCHAR2(4000),
    unit_cd             VARCHAR2(40),
    is_combined_fl      NUMBER(1),
    reported_combo_tx   VARCHAR2(200),
    resolve_status_cd   VARCHAR2(20)   -- RESOLVED|VENDOR_ONLY|UNRESOLVED
) ON COMMIT DELETE ROWS;

-- Stage 3: rows confirmed as new or changed vs live stack
CREATE GLOBAL TEMPORARY TABLE gtt_hrm_delta (
    row_id              NUMBER,
    entity_key          VARCHAR2(20),
    coverage_period     VARCHAR2(20),
    data_item_cd        VARCHAR2(30),
    load_path_cd        VARCHAR2(10),
    target_table_nm     VARCHAR2(80),
    target_column_nm    VARCHAR2(80),
    obs_id              VARCHAR2(40),
    breakdown_type_cd   VARCHAR2(30),
    dimension_cd        VARCHAR2(100),
    value_nb            NUMBER,
    value_tx            VARCHAR2(4000),
    unit_cd             VARCHAR2(40),
    is_combined_fl      NUMBER(1),
    reported_combo_tx   VARCHAR2(200),
    delta_type_cd       VARCHAR2(10)   -- NEW|CHANGED
) ON COMMIT DELETE ROWS;

-- Reject log staging
CREATE GLOBAL TEMPORARY TABLE gtt_hrm_reject (
    row_id              NUMBER,
    src_entity_id       VARCHAR2(100),
    data_item_cd        VARCHAR2(30),
    reject_reason_cd    VARCHAR2(40),  -- ENTITY_UNRESOLVED|UNMAPPED_LABEL|NULL_CELL_KEY
    reject_detail_tx    VARCHAR2(400)
) ON COMMIT DELETE ROWS;
```

### 5.2 Main harmonisation procedure

One procedure call per (source, load run). All steps are set-based.

```sql
CREATE OR REPLACE PROCEDURE prc_harmonise (
    p_source_id       IN VARCHAR2,
    p_coverage_period IN VARCHAR2,
    p_load_id         IN VARCHAR2,
    p_src_bgn_dt      IN DATE DEFAULT SYSDATE
) AS
    v_lineage_id VARCHAR2(30) := p_load_id || '_' || p_source_id;
BEGIN

    -- ----------------------------------------------------------------
    -- STEP 1: Load GTT_HRM_INBOUND from all source views for this source
    -- One INSERT per data_item registered in src_map for p_source_id.
    -- Dynamic SQL executes: INSERT INTO gtt_hrm_inbound SELECT * FROM {src_object_nm}
    -- The view contract guarantees column names match GTT columns.
    -- ----------------------------------------------------------------
    FOR r IN (SELECT data_item_cd, src_object_nm, load_path_cd,
                     target_table_nm, target_column_nm, breakdown_type_cd
              FROM   udm_data_item_src_map
              WHERE  source_id = p_source_id) LOOP

        EXECUTE IMMEDIATE
            'INSERT /*+ APPEND */ INTO gtt_hrm_inbound
             SELECT data_item_cd, load_path_cd, target_table_nm,
                    target_column_nm, obs_id, breakdown_type_cd,
                    dimension_cd, src_entity_id, coverage_period,
                    value_nb, value_tx, unit_cd,
                    is_combined_fl, reported_combo_tx
             FROM   ' || r.src_object_nm ||
            ' WHERE coverage_period = :1'
        USING p_coverage_period;

    END LOOP;
    COMMIT; -- flush GTT inbound

    -- ----------------------------------------------------------------
    -- STEP 2: Entity resolution — single bulk JOIN to xref
    -- VENDOR_ONLY created inline for unmatched entities (no cursor).
    -- ----------------------------------------------------------------
    INSERT INTO gtt_hrm_resolved
    SELECT  i.row_id,
            NVL(x.entity_key, 'VO_' || i.src_entity_id),  -- VENDOR_ONLY fallback
            i.coverage_period,
            i.data_item_cd,
            i.load_path_cd,
            i.target_table_nm,
            i.target_column_nm,
            i.obs_id,
            i.breakdown_type_cd,
            i.dimension_cd,
            i.value_nb,
            i.value_tx,
            i.unit_cd,
            i.is_combined_fl,
            i.reported_combo_tx,
            CASE WHEN x.entity_key IS NOT NULL THEN 'RESOLVED'
                 ELSE 'VENDOR_ONLY' END
    FROM    gtt_hrm_inbound i
    LEFT JOIN udm_company_xref x
                ON  x.src_entity_id  = i.src_entity_id
                AND x.source_id      = p_source_id
                AND x.match_status_cd IN ('CONFIRMED','ENGINE');
    COMMIT;

    -- Quarantine NULL cell-key rows (unmapped labels left NULL by view join)
    INSERT INTO gtt_hrm_reject
    SELECT row_id, NULL, data_item_cd, 'UNMAPPED_LABEL',
           'NULL dimension_cd for breakdown_type: ' || breakdown_type_cd
    FROM   gtt_hrm_resolved
    WHERE  load_path_cd = 'STRUCT'
    AND    dimension_cd IS NULL;
    COMMIT;

    -- ----------------------------------------------------------------
    -- STEP 3: Change detection
    -- Compare resolved rows to live (cur_fl=1) rows on target tables.
    -- Rows that are new or whose value changed go to GTT_HRM_DELTA.
    -- Unchanged rows are silently dropped — no write to permanent tables.
    -- ----------------------------------------------------------------

    -- SCALAR path change detection: compare against stack
    INSERT INTO gtt_hrm_delta
    SELECT  r.row_id, r.entity_key, r.coverage_period,
            r.data_item_cd, r.load_path_cd, r.target_table_nm,
            r.target_column_nm, r.obs_id, r.breakdown_type_cd,
            r.dimension_cd, r.value_nb, r.value_tx, r.unit_cd,
            r.is_combined_fl, r.reported_combo_tx,
            CASE WHEN s.entity_key IS NULL THEN 'NEW' ELSE 'CHANGED' END
    FROM    gtt_hrm_resolved r
    -- Join to live stack row for this source/entity/period to detect change
    LEFT JOIN udm_env_risk_stk s
                ON  s.entity_key      = r.entity_key
                AND s.source_id       = p_source_id
                AND s.coverage_period = r.coverage_period
                AND s.cur_fl          = 1
    WHERE   r.load_path_cd    = 'SCALAR'
    AND     r.resolve_status_cd IN ('RESOLVED','VENDOR_ONLY')
    -- Only include if new or the value actually changed (use NVL to handle NULLs)
    AND     (s.entity_key IS NULL OR
             NVL(TO_CHAR(r.value_nb), '~') !=
             NVL(prc_get_stack_value(s.rowid, r.target_column_nm), '~'));

    -- STRUCT path change detection (applies per target table)
    -- Same pattern: LEFT JOIN to live row on the dimensional key.
    -- Simplified here; implementer repeats per target table or uses dynamic SQL.
    INSERT INTO gtt_hrm_delta
    SELECT  r.row_id, r.entity_key, r.coverage_period,
            r.data_item_cd, r.load_path_cd, r.target_table_nm,
            r.target_column_nm, r.obs_id, r.breakdown_type_cd,
            r.dimension_cd, r.value_nb, r.value_tx, r.unit_cd,
            r.is_combined_fl, r.reported_combo_tx,
            CASE WHEN t.entity_key IS NULL THEN 'NEW' ELSE 'CHANGED' END
    FROM    gtt_hrm_resolved r
    LEFT JOIN udm_esg_disclosure t
                ON  t.entity_key       = r.entity_key
                AND t.source_id        = p_source_id
                AND t.coverage_period  = r.coverage_period
                AND t.data_item_cd     = r.data_item_cd
                AND t.breakdown_type_cd = r.breakdown_type_cd
                AND t.dimension_cd     = r.dimension_cd
                AND NVL(t.obs_id,'1')  = NVL(r.obs_id,'1')
                AND t.cur_fl           = 1
    WHERE   r.load_path_cd    = 'STRUCT'
    AND     r.target_table_nm = 'udm_esg_disclosure'
    AND     r.resolve_status_cd IN ('RESOLVED','VENDOR_ONLY')
    AND     (t.entity_key IS NULL
             OR NVL(t.value_nb,-9e30) != NVL(r.value_nb,-9e30)
             OR NVL(t.value_tx,'~')   != NVL(r.value_tx,'~'));
    COMMIT;

    -- ----------------------------------------------------------------
    -- STEP 4: SCD2 CLOSE — version out rows that changed
    -- Partition pruning on coverage_period keeps this fast.
    -- ----------------------------------------------------------------
    UPDATE /*+ PARALLEL(s,4) */ udm_env_risk_stk s
    SET    s.end_tran_dt = p_src_bgn_dt,
           s.cur_fl      = 0
    WHERE  s.source_id       = p_source_id
    AND    s.coverage_period  = p_coverage_period
    AND    s.cur_fl           = 1
    AND    s.entity_key IN (SELECT entity_key FROM gtt_hrm_delta
                            WHERE load_path_cd = 'SCALAR'
                            AND   delta_type_cd = 'CHANGED');

    UPDATE /*+ PARALLEL(t,4) */ udm_esg_disclosure t
    SET    t.end_tran_dt = p_src_bgn_dt,
           t.cur_fl      = 0
    WHERE  t.source_id        = p_source_id
    AND    t.coverage_period   = p_coverage_period
    AND    t.cur_fl            = 1
    AND    (t.entity_key, t.data_item_cd, t.breakdown_type_cd, t.dimension_cd)
           IN (SELECT entity_key, data_item_cd, breakdown_type_cd, dimension_cd
               FROM   gtt_hrm_delta
               WHERE  target_table_nm = 'udm_esg_disclosure'
               AND    delta_type_cd   = 'CHANGED');
    -- Repeat close for udm_emissions_target and udm_production similarly.
    COMMIT;

    -- ----------------------------------------------------------------
    -- STEP 5: INSERT new and changed rows (SCALAR path)
    -- All scalar attributes for entity+source+period merge into ONE wide row.
    -- Dynamic MERGE updates individual columns from delta rows.
    -- APPEND hint bypasses buffer cache for bulk insert performance.
    -- ----------------------------------------------------------------
    MERGE /*+ APPEND PARALLEL(t,4) */ INTO udm_env_risk_stk t
    USING (
        SELECT  entity_key, p_source_id AS source_id, coverage_period,
                p_src_bgn_dt AS src_bgn_tran_dt,
                DATE '9999-12-31' AS src_end_tran_dt,
                SYSDATE AS bgn_tran_dt,
                DATE '9999-12-31' AS end_tran_dt,
                1 AS cur_fl, 0 AS is_golden_fl, v_lineage_id AS lineage_id,
                -- pivot scalar values into columns using conditional aggregation
                MAX(CASE WHEN target_column_nm='scope1_mtco2e' THEN value_nb END)            AS scope1_mtco2e,
                MAX(CASE WHEN target_column_nm='scope2_location_mtco2e' THEN value_nb END)   AS scope2_location_mtco2e,
                MAX(CASE WHEN target_column_nm='scope2_market_mtco2e' THEN value_nb END)     AS scope2_market_mtco2e,
                MAX(CASE WHEN target_column_nm='scope3_total_mtco2e' THEN value_nb END)      AS scope3_total_mtco2e,
                MAX(CASE WHEN target_column_nm='scope1_scope2_mtco2e' THEN value_nb END)     AS scope1_scope2_mtco2e,
                MAX(CASE WHEN target_column_nm='base_year_scope1_mtco2e' THEN value_nb END)  AS base_year_scope1_mtco2e,
                MAX(CASE WHEN target_column_nm='evic_usd_nb' THEN value_nb END)              AS evic_usd_nb,
                MAX(CASE WHEN target_column_nm='total_energy_mwh' THEN value_nb END)         AS total_energy_mwh,
                MAX(CASE WHEN target_column_nm='scope1_verified_fl' THEN value_nb END)       AS scope1_verified_fl
                -- extend for all stack columns
        FROM    gtt_hrm_delta
        WHERE   load_path_cd = 'SCALAR'
        GROUP BY entity_key, coverage_period
    ) src
    ON (t.entity_key      = src.entity_key
        AND t.source_id   = src.source_id
        AND t.coverage_period = src.coverage_period
        AND t.src_bgn_tran_dt = src.src_bgn_tran_dt
        AND t.bgn_tran_dt     = src.bgn_tran_dt)
    WHEN NOT MATCHED THEN INSERT VALUES (
        src.entity_key, src.source_id, src.coverage_period,
        src.scope1_mtco2e, src.scope2_location_mtco2e,
        src.scope2_market_mtco2e, src.scope3_total_mtco2e,
        src.scope1_scope2_mtco2e, src.base_year_scope1_mtco2e,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,  -- remaining columns
        src.evic_usd_nb, NULL, NULL, NULL,
        src.total_energy_mwh, src.scope1_verified_fl, NULL,
        src.src_bgn_tran_dt, DATE '9999-12-31',
        src.bgn_tran_dt, DATE '9999-12-31',
        1, 0, src.lineage_id
    );
    COMMIT;

    -- ----------------------------------------------------------------
    -- STEP 6: INSERT new and changed rows (STRUCT path — udm_esg_disclosure)
    -- One row per delta row — no pivoting needed for STRUCT.
    -- ----------------------------------------------------------------
    INSERT /*+ APPEND PARALLEL(t,4) */ INTO udm_esg_disclosure t (
        entity_key, source_id, coverage_period,
        data_item_cd, obs_id, breakdown_type_cd, dimension_cd,
        value_nb, value_tx, unit_cd,
        is_combined_fl, reported_combo_tx,
        src_bgn_tran_dt, src_end_tran_dt,
        bgn_tran_dt, end_tran_dt,
        cur_fl, lineage_id
    )
    SELECT  d.entity_key, p_source_id, d.coverage_period,
            d.data_item_cd, NVL(d.obs_id,'1'),
            d.breakdown_type_cd, d.dimension_cd,
            d.value_nb, d.value_tx, d.unit_cd,
            NVL(d.is_combined_fl,0), d.reported_combo_tx,
            p_src_bgn_dt, DATE '9999-12-31',
            SYSDATE, DATE '9999-12-31',
            1, v_lineage_id
    FROM    gtt_hrm_delta d
    WHERE   d.target_table_nm = 'udm_esg_disclosure';
    COMMIT;
    -- Repeat equivalent INSERT blocks for udm_emissions_target and udm_production.

    -- ----------------------------------------------------------------
    -- STEP 7: Write rejects to permanent reject log
    -- ----------------------------------------------------------------
    INSERT INTO udm_load_reject_log (
        load_id, source_id, coverage_period,
        src_entity_id, data_item_cd,
        reject_reason_cd, reject_detail_tx, rejected_dt)
    SELECT  p_load_id, p_source_id, p_coverage_period,
            r.src_entity_id, r.data_item_cd,
            r.reject_reason_cd, r.reject_detail_tx, SYSDATE
    FROM    gtt_hrm_reject r;
    COMMIT;

END prc_harmonise;
```

### 5.3 Performance guide

| Concern | Approach |
|---|---|
| Bulk load from views | `INSERT /*+ APPEND */` into GTT bypasses buffer cache |
| Entity resolution | Single bulk `LEFT JOIN` — never row-by-row lookup |
| Change detection | Set-based `LEFT JOIN` with value comparison; NVL handles NULLs |
| SCD2 close | `WHERE IN (SELECT ...)` from GTT; partition pruning on `coverage_period` keeps range tight |
| Stack insert | `MERGE` with conditional aggregation pivot; one pass over GTT |
| Disclosure insert | `INSERT /*+ APPEND PARALLEL */` — one row per delta row, no pivot |
| Parallelism | `PARALLEL(t,4)` hint on all permanent table operations; tune degree to instance |
| Partitioning | All permanent tables partition by `LIST (coverage_period) AUTOMATIC`; each period is one partition segment — close and insert touch only that segment |
| GTT indexes | Add on `(load_path_cd, target_table_nm)` and `(entity_key, data_item_cd)` on `gtt_hrm_delta` to avoid full GTT scans in steps 4–6 |
| Statistics | Gather GTT stats with `DBMS_STATS.GATHER_TABLE_STATS` after step 2 before the optimizer sees the resolved rows |

---

## 6. Encoded Column Name Sources

Some sources encode dimensional information in the column name rather than delivering it
as a separate field. Example: a source delivers one wide row per entity:

```
entity_id | period | s1_emissions_mt | s2_loc_emissions_mt | s3_cat1_intensity_rev | s3_cat1_cat2_emissions_mt
```

Each column name encodes: data item + scope + category. The source cannot be loaded via
the standard STRUCT view because there is no dimensional field to read — the dimension IS
the column name.

### 6.1 Approach — UNPIVOT + attribute map

The source view uses Oracle `UNPIVOT` to rotate columns into rows, then joins to
`udm_src_attribute_map` to translate each column name to its canonical cell definition.

```sql
-- Step 1: Seed udm_src_attribute_map with the column-to-cell mapping
INSERT ALL
  INTO udm_src_attribute_map VALUES ('SOURCE_C','s1_emissions_mt','SCOPE1_MTCO2E','SCALAR','udm_env_risk_stk','scope1_mtco2e',NULL,NULL,NULL,'mtCO2e')
  INTO udm_src_attribute_map VALUES ('SOURCE_C','s2_loc_emissions_mt','SCOPE2_LOC_MTCO2E','SCALAR','udm_env_risk_stk','scope2_location_mtco2e',NULL,NULL,NULL,'mtCO2e')
  INTO udm_src_attribute_map VALUES ('SOURCE_C','s3_cat1_intensity_rev','65100','STRUCT','udm_esg_disclosure',NULL,'INTENSITY','S3/S3_CAT_1/REVENUE','S3','tCO2e/USDM')
  INTO udm_src_attribute_map VALUES ('SOURCE_C','s3_cat1_cat2_emissions_mt','SCOPE3_BY_CAT','STRUCT','udm_esg_disclosure',NULL,'S3_CATEGORY','S3_CAT_1+S3_CAT_2','S3','mtCO2e')
SELECT 1 FROM DUAL;
-- is_combined_fl = 1 implied when dimension_cd contains '+' (multi-category combo)
```

```sql
-- Step 2: Source view — UNPIVOT then join to attribute map
CREATE OR REPLACE VIEW vw_sourcec_hrm AS
SELECT  m.data_item_cd,
        m.load_path_cd,
        m.target_table_nm,
        m.target_column_nm,
        m.breakdown_type_cd,
        m.dimension_cd,
        m.scope_cd,
        m.unit_cd,
        CASE WHEN INSTR(m.dimension_cd,'+') > 0 THEN 1 ELSE 0 END  AS is_combined_fl,
        m.dimension_cd                                               AS reported_combo_tx,
        u.entity_id                                                  AS src_entity_id,
        u.period                                                     AS coverage_period,
        TO_NUMBER(u.col_value)                                       AS value_nb,
        NULL                                                         AS value_tx
FROM   (
    -- UNPIVOT: rotate wide columns into (col_name, col_value) rows
    SELECT entity_id, period, col_name, col_value
    FROM   rdm_sourcec_wide
    UNPIVOT (col_value FOR col_name IN (
        s1_emissions_mt          AS 's1_emissions_mt',
        s2_loc_emissions_mt      AS 's2_loc_emissions_mt',
        s3_cat1_intensity_rev    AS 's3_cat1_intensity_rev',
        s3_cat1_cat2_emissions_mt AS 's3_cat1_cat2_emissions_mt'
        -- extend as source adds columns
    ))
) u
JOIN  udm_src_attribute_map m
        ON  m.source_id    = 'SOURCE_C'
        AND m.src_column_nm = u.col_name
WHERE  u.col_value IS NOT NULL;  -- skip columns the source left blank
```

This view plugs into the standard harmonisation engine unchanged. The engine reads
`vw_sourcec_hrm` exactly as it reads any other source view — the UNPIVOT and map join
are invisible to the engine.

### 6.2 Adding a new encoded column

1. Add the column to the `UNPIVOT` list in the source view.
2. Insert one row into `udm_src_attribute_map` with the canonical cell definition.

No engine code changes. No new tables.

### 6.3 Combined-dimension handling for encoded columns

When a source column encodes a combination (e.g. `s3_cat1_cat2_emissions_mt`):

- `dimension_cd` in the attribute map is set to the canonical combo: `S3_CAT_1+S3_CAT_2`
- `is_combined_fl = 1` — the view derives this from the presence of `+` in `dimension_cd`
- `reported_combo_tx = dimension_cd` — preserves what the source actually delivered

One row lands in `udm_esg_disclosure` with `dimension_cd = 'S3_CAT_1+S3_CAT_2'`.
The consumer sees `is_combined_fl = 1` and knows this value covers both categories.

---

## 7. Source View Contract (summary)

Every source view — whether it reads relational rows, JSON columns, or an unpivoted wide
table — must output these columns matching the GTT:

| Column | Required | Notes |
|---|---|---|
| `src_entity_id` | Yes | Source's own entity identifier |
| `coverage_period` | Yes | Reporting year e.g. '2023' |
| `data_item_cd` | Yes | From udm_data_item |
| `load_path_cd` | Yes | SCALAR or STRUCT |
| `target_table_nm` | Yes | Physical target table |
| `target_column_nm` | SCALAR only | Stack column name |
| `obs_id` | STRUCT only | Source observation id; '1' for MAP |
| `breakdown_type_cd` | STRUCT only | GHG_TYPE, S3_CATEGORY, FUEL_TYPE, INTENSITY... |
| `dimension_cd` | STRUCT only | Canonical cell dimension value |
| `value_nb` | When numeric | NULL for coded/text responses |
| `value_tx` | When coded/text | NULL for numeric |
| `unit_cd` | Recommended | |
| `is_combined_fl` | Recommended | 1 when value covers multiple dimensions |
| `reported_combo_tx` | Recommended | Raw label from source for lineage |

All canonicalization (label → code) happens inside the view.
NULL on `dimension_cd` or any required column causes the row to be quarantined.

---

## 8. Adding a New Source — Checklist

**Zero engine or DDL changes required.**

1. Register in `udm_source_registry`.
2. Insert label rows into `udm_src_code_map`.
3. If the source uses encoded column names:
   - Insert rows into `udm_src_attribute_map`.
   - Create an UNPIVOT source view per §6.
4. Otherwise create standard source views per §7 contract.
5. Insert rows into `udm_data_item_src_map` for each data item the source provides.
6. Insert a precedence rule into `udm_precedence_rules` for governed data items.
7. Run `prc_harmonise(p_source_id, p_coverage_period, p_load_id)`.
