-- =============================================================================
-- UDM TIER 1 DDL — COMPLETE FINAL CONSOLIDATED
-- Schema  : UDM
-- Version : 4.0 Final
-- Sessions: 3 through 8 — all decisions incorporated
-- =============================================================================
--
-- OBJECT INVENTORY
-- ─────────────────────────────────────────────────────────────────────────────
-- 28 tables, 28 sequences
--
-- CATALOG (engine reads these to drive all processing)
--   01 udm_source_system          governed source system catalog
--   02 udm_source_registry        front door — one row per source per domain
--   03 udm_attribute_map          one row per attribute per source — IS the DI spec
--   04 udm_transform_rules        named SQL for rule_ref: transforms
--   05 udm_precedence_rules       vendor priority per domain
--   06 udm_grain_alignment_rules  grain collapsing rules per domain/vendor
--   07 udm_dq_rules               threshold-dependent checks only
--
-- ENTITY RESOLUTION
--   08 udm_entity_registry        UDM permanent entity keys + source_key
--   09 udm_company_xref           vendor ID → entity_key (MDM-maintained)
--   10 udm_entity_membership      composite entity construct definitions
--   11 udm_spatial_asset_registry 40M+ lat/long spatial assets
--
-- SOURCE ROUTING
--   12 udm_ref_source_map         REFERENCE_SOURCE → ref table + creates_entity
--
-- REFERENCE TABLES (natural keys only — no entity_key FK)
--   13 udm_ref_company            company descriptive profile
--   14 udm_ref_counterparty       counterparty descriptive profile
--   15 udm_ref_supplier           supplier descriptive profile
--   16 udm_ref_sector             sector classification + hierarchy
--   17 udm_ref_region             region hierarchy
--   18 udm_ref_country            country reference
--   19 udm_ref_product            product reference — standalone
--   20 udm_ref_time               fiscal calendar — standalone
--
-- PIPELINE SUPPORT
--   21 udm_delivery_manifest      bundle validation gate
--   22 udm_lineage                batch-level processing audit trail (partitioned)
--   23 udm_quarantine             rejected rows for resolution (partitioned)
--   24 udm_dq_results             all DI check results (partitioned)
--   25 udm_detection_suppressions negative PO decisions
--
-- SEMANTIC / BI CATALOG
--   26 udm_metric_catalog         metric registry for catalog-driven BI
--   27 udm_domain_join_map        valid cross-domain join paths
--   28 udm_grain_compatibility    grain resolution rules
--
-- ─────────────────────────────────────────────────────────────────────────────
-- KEY DESIGN DECISIONS REFLECTED IN THIS DDL
--
--   source_role         Two values only: DATA_SOURCE | REFERENCE_SOURCE
--                       IDENTITY_SOURCE dropped — entity creation is a side
--                       effect of REFERENCE_SOURCE load (creates_entity flag)
--
--   udm_identity_source_map   DROPPED. udm_ref_source_map handles both routing
--                             and entity creation via creates_entity column.
--
--   udm_source_system   Governs vendor_id throughout. All vendor_id columns
--                       FK here. Seeded from DW.src_sys_dim.
--
--   udm_entity_registry entity_key = UDM-generated sequence starting at
--                       1,000,000 to avoid collision with source system PKs.
--                       source_key carries original source PK (e.g. customer_bk).
--                       Join to ref tables uses source_key, not entity_key.
--
--   udm_company_xref    Renamed from udm_entity_xref. Maintained by external
--                       MDM process. UDM engine reads — does not write.
--
--   udm_ref_* tables    Natural keys only. No entity_key FK to entity_registry.
--                       Ref tables are independent of whether the entity is
--                       also a measurement subject.
--
--   udm_attribute_map   is_derived column: Y = computed from other canonical
--                       columns, source_attribute NULL.
--                       Engine processes is_derived=N first, is_derived=Y second.
--                       unit_from VARCHAR2(140): supports col: prefix + col name.
--                       Constituent columns preserved as real stack table columns.
--                       metric_group: links to udm_precedence_rules overrides.
--
--   unit_from patterns  static constant | col:column_name | NULL
--                       unit_from_eav_key for EAV sibling row resolution
--                       Mutually exclusive: col: and eav_key cannot both be set
--
-- ─────────────────────────────────────────────────────────────────────────────
-- OPTION A COMPATIBILITY
--   Existing EAV pipeline tables are NOT modified.
--   Registered in udm_source_registry (governance_status = UDM_CATALOGED).
--   RDM-only objects registered as governance_status = RDM_ONLY.
--   Engine ignores RDM_ONLY and RETIRED sources.
--   Precedence rules hardcoded in Option A stored procedure must be
--   extracted and INSERTed into udm_precedence_rules post-DDL.
--
-- EXECUTION ORDER
--   Run sections in order. FK constraints require parent tables first.
--   All sequences before all tables.
--   udm_source_system must exist before any table that carries vendor_id FK.
-- =============================================================================


-- =============================================================================
-- SECTION 1 — SEQUENCES
-- ─────────────────────────────────────────────────────────────────────────────
-- Naming: udm_{object}_seq
-- All surrogate keys: 'PREFIX-' || LPAD(seq.NEXTVAL, 5, '0')
-- Entity sequence starts at 1,000,000 — avoids collision with source PKs
-- which are typically small integers from source system sequences.
-- =============================================================================

CREATE SEQUENCE udm_src_sys_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_source_seq       START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_map_seq          START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_transform_seq    START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_prec_rule_seq    START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_grain_rule_seq   START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_dq_rule_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_entity_seq       START WITH 1000000 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_co_xref_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_membership_seq   START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_spatial_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_map_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_co_seq       START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_cpty_seq     START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_sup_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_sec_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_reg_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_cty_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_prod_seq     START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_time_seq     START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_manifest_seq     START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_lineage_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_quarantine_seq   START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_dq_result_seq    START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_suppress_seq     START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_metric_seq       START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_join_map_seq     START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_grain_compat_seq START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;


-- =============================================================================
-- SECTION 2 — SOURCE SYSTEM CATALOG
-- Must be created first — vendor_id throughout all UDM tables FKs here.
-- Seeded from DW.src_sys_dim via REFERENCE_SOURCE load.
-- UDM becomes the governed master after seeding — src_sys_dim becomes the seed.
-- Unknown source systems cannot be registered in udm_source_registry.
-- =============================================================================

CREATE TABLE udm_source_system (
    source_system_cd    VARCHAR2(50)    NOT NULL,
    -- Matches vendor_id in source_registry, company_xref, lineage, manifest.
    -- Format mirrors DW.src_sys_dim.source_system_cd.
    source_system_name  VARCHAR2(200)   NOT NULL,
    source_system_type  VARCHAR2(20)    NOT NULL,
    -- VENDOR       external data vendor
    -- INTERNAL     internal operational or analytical system
    -- RDM          internal reference data master (DW/RDM schema)
    -- UDM_DERIVED  data generated within UDM itself
    owner_team          VARCHAR2(100),
    data_domain         VARCHAR2(100),
    is_active           CHAR(1)         DEFAULT 'Y' NOT NULL,
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_source_system
        PRIMARY KEY (source_system_cd),
    CONSTRAINT chk_src_sys_type
        CHECK (source_system_type IN ('VENDOR','INTERNAL','RDM','UDM_DERIVED')),
    CONSTRAINT chk_src_sys_active
        CHECK (is_active IN ('Y','N'))
);

CREATE INDEX idx_src_sys_type_active
    ON udm_source_system (source_system_type, is_active);

COMMENT ON TABLE  udm_source_system IS
    'Governed source system catalog. Seeded from DW.src_sys_dim. '
    'vendor_id throughout all UDM tables FKs to source_system_cd here. '
    'Unknown source systems cannot be registered.';
COMMENT ON COLUMN udm_source_system.source_system_cd IS
    'PK. Matches vendor_id in udm_source_registry, udm_company_xref, '
    'udm_lineage, udm_delivery_manifest throughout.';


-- =============================================================================
-- SECTION 3 — SOURCE REGISTRY
-- One row per source (vendor, internal, RDM object) per domain.
-- Every source must be registered here before the engine will process it.
-- This is the single inventory of the entire data estate.
--
-- source_role drives which engine path handles this source:
--   DATA_SOURCE      staging → udm_{domain}_stk → udm_{domain}_arb
--   REFERENCE_SOURCE → udm_ref_* tables
--                      if creates_entity=Y on ref_source_map → also seeds entity_registry
--   (IDENTITY_SOURCE was dropped — entity creation is a side effect of
--    REFERENCE_SOURCE load via creates_entity on udm_ref_source_map)
--
-- subject_type drives identity resolution:
--   ENTITY      entity resolution via udm_company_xref applies (COMPANY types)
--               or direct registry lookup on standard code (SECTOR/REGION/COUNTRY)
--   SPATIAL     spatial registry applies
--   INTERNAL_ID no entity resolution — raw identifier passes through as natural key
--
-- domain_grain declares the natural key grain of this source.
-- Stamped as measurement_grain on every fact row the engine writes.
-- e.g. COMPANY-FISCAL_YEAR | COMPANY_SECTOR-FISCAL_YEAR | SECTOR-QTR
--
-- governance_status tracks organic migration from Option A:
--   STAGE_ONLY    detected, not yet approved for processing
--   RDM_ONLY      pre-UDM; RDM pipeline serves it; engine ignores
--   MIGRATING     parallel run active alongside RDM; engine processes
--   UDM_CATALOGED fully governed through UDM; permanent end state
--   DEPRECATED    winding down, no replacement; engine still processes
--   RETIRED       historical audit only; superseded_by_source_id set; engine ignores
--
-- superseded_by_source_id is set on RETIRED sources only.
-- Points to the UDM_CATALOGED source that replaced the retired RDM source.
-- Provides full audit trail through migration without tribal knowledge.
-- =============================================================================

CREATE TABLE udm_source_registry (
    source_id                   VARCHAR2(20)    NOT NULL,
    vendor_id                   VARCHAR2(50)    NOT NULL,
    -- FK to udm_source_system.source_system_cd
    domain_id                   VARCHAR2(50)    NOT NULL,
    sub_domain_id               VARCHAR2(50),
    source_schema               VARCHAR2(30)    NOT NULL,
    source_table                VARCHAR2(128)   NOT NULL,
    source_format               VARCHAR2(20)    NOT NULL,
    -- COLUMNAR | EAV
    --
    -- currency_mechanism — how to identify current rows in this source
    --   CURRENT_FLAG      WHERE {current_flag_column} = 'Y'
    --   EFFECTIVE_DATES   WHERE {effective_to_column} IS NULL  (SCD Type 2)
    --   MAX_SNAPSHOT_DATE MAX({time_key_column}) per entity  (periodic snapshots)
    --   ALWAYS_CURRENT    no history — every row is current
    --   LOAD_DATE         MAX(load_date) per entity
    currency_mechanism          VARCHAR2(20)    NOT NULL,
    current_flag_column         VARCHAR2(128),
    effective_to_column         VARCHAR2(128),
    time_key_column             VARCHAR2(128),
    entity_id_col               VARCHAR2(128)   NOT NULL,
    time_col                    VARCHAR2(128)   NOT NULL,
    storage_pattern             VARCHAR2(20)    NOT NULL,
    -- MATERIALISED | VIRTUAL
    physical_target             VARCHAR2(128),
    -- target table or view written by engine; NULL for IDENTITY route
    source_role                 VARCHAR2(20)    DEFAULT 'DATA_SOURCE' NOT NULL,
    -- DATA_SOURCE | REFERENCE_SOURCE
    subject_type                VARCHAR2(20)    DEFAULT 'ENTITY'      NOT NULL,
    -- ENTITY | SPATIAL | INTERNAL_ID
    domain_grain                VARCHAR2(100),
    -- e.g. COMPANY-FISCAL_YEAR; stamped as measurement_grain on fact rows
    governance_status           VARCHAR2(20)    NOT NULL,
    superseded_by_source_id     VARCHAR2(20),
    -- self-referencing FK; set on RETIRED sources only
    effective_from              DATE            NOT NULL,
    effective_to                DATE,
    created_by                  VARCHAR2(50)    NOT NULL,
    created_date                DATE            DEFAULT SYSDATE NOT NULL,
    modified_by                 VARCHAR2(50),
    modified_date               DATE,
    notes                       VARCHAR2(500),
    --
    CONSTRAINT pk_udm_source_registry
        PRIMARY KEY (source_id),
    CONSTRAINT fk_src_reg_src_sys
        FOREIGN KEY (vendor_id)
        REFERENCES udm_source_system (source_system_cd),
    CONSTRAINT fk_source_superseded_by
        FOREIGN KEY (superseded_by_source_id)
        REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_source_registry_natural
        UNIQUE (vendor_id, domain_id, sub_domain_id, source_table, effective_from),
    CONSTRAINT chk_source_format
        CHECK (source_format IN ('COLUMNAR', 'EAV')),
    CONSTRAINT chk_currency_mechanism
        CHECK (currency_mechanism IN ('CURRENT_FLAG','EFFECTIVE_DATES',
                                      'MAX_SNAPSHOT_DATE','ALWAYS_CURRENT','LOAD_DATE')),
    CONSTRAINT chk_storage_pattern
        CHECK (storage_pattern IN ('MATERIALISED','VIRTUAL')),
    CONSTRAINT chk_source_role
        CHECK (source_role IN ('DATA_SOURCE','REFERENCE_SOURCE')),
    CONSTRAINT chk_subject_type
        CHECK (subject_type IN ('ENTITY','SPATIAL','INTERNAL_ID')),
    CONSTRAINT chk_governance_status
        CHECK (governance_status IN ('STAGE_ONLY','RDM_ONLY','MIGRATING',
                                     'UDM_CATALOGED','DEPRECATED','RETIRED')),
    CONSTRAINT chk_superseded_only_on_retired
        CHECK (superseded_by_source_id IS NULL OR governance_status = 'RETIRED'),
    CONSTRAINT chk_currency_flag_col
        CHECK (currency_mechanism != 'CURRENT_FLAG'      OR current_flag_column IS NOT NULL),
    CONSTRAINT chk_currency_eff_col
        CHECK (currency_mechanism != 'EFFECTIVE_DATES'   OR effective_to_column  IS NOT NULL),
    CONSTRAINT chk_currency_time_col
        CHECK (currency_mechanism != 'MAX_SNAPSHOT_DATE' OR time_key_column      IS NOT NULL)
);

CREATE INDEX idx_source_reg_vendor_domain
    ON udm_source_registry (vendor_id, domain_id);
CREATE INDEX idx_source_reg_governance
    ON udm_source_registry (governance_status, source_role);

COMMENT ON TABLE  udm_source_registry IS
    'Single inventory of the entire data estate. '
    'Every source registered here before engine processes it. '
    'Tracks organic migration from Option A (RDM_ONLY) to full UDM (UDM_CATALOGED).';
COMMENT ON COLUMN udm_source_registry.source_role IS
    'DATA_SOURCE: vendor stack + arbitration. '
    'REFERENCE_SOURCE: udm_ref_* tables; if creates_entity=Y on '
    'udm_ref_source_map → also seeds entity_registry as side effect.';
COMMENT ON COLUMN udm_source_registry.domain_grain IS
    'Declares natural key grain of this source e.g. COMPANY-FISCAL_YEAR. '
    'Stamped as measurement_grain on every stack row the engine writes.';
COMMENT ON COLUMN udm_source_registry.superseded_by_source_id IS
    'Set on RETIRED sources only. Points to the UDM_CATALOGED source '
    'that replaced this one. Full audit trail through migration.';


-- =============================================================================
-- SECTION 4 — ATTRIBUTE MAP
-- One row per attribute per source. Same shape for COLUMNAR and EAV sources.
--
-- IS the DI specification — auto-derived checks derive from this table:
--   type conformance (data_type)
--   not-null on subject keys and time keys (is_mandatory)
--   unit transform verification (unit_from/to)
--   unmapped attribute detection
--   referential integrity on lookup transforms
--
-- transform_rule patterns (processed in this order per row):
--   direct                   copy value as-is
--   lookup:schema.table.col  resolve via lookup; engine validates FK
--   divide:col_name          divide by another non-derived column in same row
--   multiply:constant        multiply by constant
--   derive:schema.table.col  fetch value from related table
--   coalesce:col1,col2       first non-null wins; col1 and col2 must be
--                            non-derived canonical names in same source
--   rule_ref:RULE_NAME       complex SQL in udm_transform_rules
--   flag:col1,col2           writes DIRECT|ESTIMATED; pairs with coalesce:
--   derive_cs:col1,col2      COMPANY_SECTOR composite key derivation;
--                            takes resolved company_key and sector_key;
--                            looks up or creates composite entity_key
--
-- is_derived = Y: this row has no physical source column — its value is
-- computed from other canonical columns already resolved in Pass 1.
-- source_attribute is NULL for derived rows.
-- Engine processes is_derived=N rows first (Pass 1), is_derived=Y second (Pass 2).
--
-- metric_group: links this attribute to a group-specific precedence rule
-- override. NULL = attribute follows the domain-level default precedence.
-- Matches metric_group on udm_precedence_rules for SCOPE3 etc.
--
-- unit_from patterns (mutually exclusive with unit_from_eav_key):
--   'tCO2'              static constant — applies to all rows
--   'col:column_name'   read unit from named column in source row (COLUMNAR only)
--   NULL                no unit conversion
-- unit_from_eav_key: for EAV sources — attribute_name_value of the sibling
-- row that holds the unit for this metric. Takes priority over unit_from.
--
-- EAV columns: all NULL for COLUMNAR sources.
-- Constraint chk_attrmap_eav_columns enforces all-or-nothing population.
--
-- map_status = PENDING_RETIREMENT set automatically when detection layer
-- finds the mapped source column has been dropped. Engine blocks that source
-- until the status is resolved and a DDL change is released.
-- =============================================================================

CREATE TABLE udm_attribute_map (
    map_id                      VARCHAR2(20)    NOT NULL,
    source_id                   VARCHAR2(20)    NOT NULL,
    source_attribute            VARCHAR2(128),
    -- physical column name (COLUMNAR) or value column name (EAV)
    -- NULL when is_derived = Y
    canonical_name              VARCHAR2(128)   NOT NULL,
    -- target column name in udm_{domain}_stk and udm_{domain}_arb
    is_derived                  CHAR(1)         DEFAULT 'N' NOT NULL,
    -- Y = computed from other canonical columns; source_attribute is NULL
    -- engine processes is_derived=N (Pass 1) then is_derived=Y (Pass 2)
    metric_group                VARCHAR2(100),
    -- NULL = follows domain-level precedence rule
    -- populated e.g. 'SCOPE3' to link to SCOPE3-specific precedence override
    transform_rule              VARCHAR2(200),
    data_type                   VARCHAR2(20)    NOT NULL,
    -- VARCHAR | NUMBER | DATE | TIMESTAMP | BOOLEAN
    unit_from                   VARCHAR2(140),
    -- static constant: 'tCO2'
    -- column reference: 'col:SCOPE1_UNIT' (COLUMNAR sources only)
    -- NULL: no unit conversion
    unit_from_eav_key           VARCHAR2(200),
    -- EAV sources only: attribute_name_value of the sibling row holding the unit
    -- e.g. 'SCOPE1_EMISSION_UNIT'. Takes priority over unit_from when populated.
    unit_to                     VARCHAR2(50),
    -- canonical unit applied to all rows after conversion
    is_subject_key              CHAR(1)         DEFAULT 'N' NOT NULL,
    -- Y = this attribute is the primary subject identifier
    is_time_key                 CHAR(1)         DEFAULT 'N' NOT NULL,
    -- Y = this attribute maps to coverage_period
    is_mandatory                CHAR(1)         DEFAULT 'N' NOT NULL,
    -- Y = NULL value triggers REJECT to udm_quarantine
    --
    -- EAV-only columns — all NULL for COLUMNAR sources
    attribute_name_column       VARCHAR2(128),
    attribute_name_value        VARCHAR2(200),
    attribute_value_column      VARCHAR2(128),
    attribute_value_data_type   VARCHAR2(20),
    -- NUMBER | DATE | VARCHAR | BOOLEAN — cast target for EAV value column
    map_status                  VARCHAR2(20)    DEFAULT 'ACTIVE' NOT NULL,
    -- ACTIVE | PENDING_RETIREMENT | RETIRED
    effective_from              DATE            NOT NULL,
    effective_to                DATE,
    created_by                  VARCHAR2(50)    NOT NULL,
    created_date                DATE            DEFAULT SYSDATE NOT NULL,
    modified_by                 VARCHAR2(50),
    modified_date               DATE,
    --
    CONSTRAINT pk_udm_attribute_map
        PRIMARY KEY (map_id),
    CONSTRAINT fk_attrmap_source
        FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_attrmap_source_canonical
        UNIQUE (source_id, canonical_name, effective_from),
    CONSTRAINT chk_attrmap_is_derived
        CHECK (is_derived IN ('Y','N')),
    CONSTRAINT chk_attrmap_derived_source_null
        CHECK (
            (is_derived = 'N' AND source_attribute IS NOT NULL)
            OR
            (is_derived = 'Y' AND source_attribute IS NULL)
        ),
    CONSTRAINT chk_attrmap_derived_needs_rule
        CHECK (
            is_derived = 'N'
            OR transform_rule LIKE 'coalesce:%'
            OR transform_rule LIKE 'rule_ref:%'
            OR transform_rule LIKE 'flag:%'
            OR transform_rule LIKE 'derive_cs:%'
        ),
    CONSTRAINT chk_attrmap_data_type
        CHECK (data_type IN ('VARCHAR','NUMBER','DATE','TIMESTAMP','BOOLEAN')),
    CONSTRAINT chk_attrmap_subject_key
        CHECK (is_subject_key IN ('Y','N')),
    CONSTRAINT chk_attrmap_time_key
        CHECK (is_time_key IN ('Y','N')),
    CONSTRAINT chk_attrmap_mandatory
        CHECK (is_mandatory IN ('Y','N')),
    CONSTRAINT chk_attrmap_status
        CHECK (map_status IN ('ACTIVE','PENDING_RETIREMENT','RETIRED')),
    -- EAV columns: all three populated or all three NULL
    CONSTRAINT chk_attrmap_eav_columns
        CHECK (
            (    attribute_name_column IS NULL
             AND attribute_name_value  IS NULL
             AND attribute_value_column IS NULL)
            OR
            (    attribute_name_column IS NOT NULL
             AND attribute_name_value  IS NOT NULL
             AND attribute_value_column IS NOT NULL)
        ),
    -- unit_from_eav_key only valid for EAV source rows
    CONSTRAINT chk_attrmap_eav_key_only_for_eav
        CHECK (unit_from_eav_key IS NULL OR attribute_name_column IS NOT NULL),
    -- col: prefix on unit_from only valid for COLUMNAR sources (no EAV columns set)
    CONSTRAINT chk_attrmap_col_prefix_columnar_only
        CHECK (
            SUBSTR(unit_from, 1, 4) != 'col:'
            OR attribute_name_column IS NULL
        ),
    -- unit_from col: and unit_from_eav_key are mutually exclusive
    CONSTRAINT chk_attrmap_unit_mutual_exclusion
        CHECK (
            NOT (
                unit_from_eav_key IS NOT NULL
                AND SUBSTR(unit_from, 1, 4) = 'col:'
            )
        )
);

CREATE INDEX idx_attrmap_source_status
    ON udm_attribute_map (source_id, map_status);
CREATE INDEX idx_attrmap_canonical
    ON udm_attribute_map (canonical_name);
CREATE INDEX idx_attrmap_derived
    ON udm_attribute_map (source_id, is_derived);
-- supports engine two-pass: ORDER BY is_derived ASC processes N before Y

COMMENT ON TABLE  udm_attribute_map IS
    'One row per attribute per source. Same shape for COLUMNAR and EAV. '
    'IS the DI specification. is_derived=N rows processed first (Pass 1); '
    'is_derived=Y rows processed second (Pass 2). '
    'Constituent source columns preserved as real columns in stack table.';
COMMENT ON COLUMN udm_attribute_map.is_derived IS
    'Y = computed from other canonical columns already resolved in Pass 1. '
    'source_attribute is NULL. Engine processes N first, Y second. '
    'Valid transforms for Y rows: coalesce: / rule_ref: / flag: / derive_cs:';
COMMENT ON COLUMN udm_attribute_map.source_attribute IS
    'Physical column name for COLUMNAR; value column for EAV. '
    'NULL when is_derived = Y — no physical source column exists.';
COMMENT ON COLUMN udm_attribute_map.metric_group IS
    'Links attribute to group-level precedence rule override. '
    'NULL = domain default rules apply. '
    'e.g. SCOPE3 links to SCOPE3-specific entry in udm_precedence_rules.';
COMMENT ON COLUMN udm_attribute_map.unit_from IS
    'Static: ''tCO2'' applies to all rows. '
    'Column ref: ''col:SCOPE1_UNIT'' reads unit from named source column '
    '(COLUMNAR only; col: and unit_from_eav_key are mutually exclusive). '
    'NULL: no unit conversion applied.';
COMMENT ON COLUMN udm_attribute_map.unit_from_eav_key IS
    'EAV only. attribute_name_value of sibling row that holds the unit. '
    'e.g. SCOPE1_EMISSION_UNIT. Takes priority over unit_from when set.';
COMMENT ON COLUMN udm_attribute_map.map_status IS
    'PENDING_RETIREMENT: source column dropped — engine blocks until resolved.';


-- =============================================================================
-- SECTION 5 — TRANSFORM RULES
-- Named SQL expressions for complex transforms that cannot be expressed
-- as simple patterns in udm_attribute_map.transform_rule.
-- Referenced by: transform_rule = rule_ref:RULE_NAME
-- Changing a rule = one UPDATE row, no code deployment.
-- resolution_sql uses {canonical_name} placeholder notation — engine
-- substitutes the already-resolved value of that canonical column.
-- =============================================================================

CREATE TABLE udm_transform_rules (
    rule_id             VARCHAR2(20)    NOT NULL,
    rule_name           VARCHAR2(100)   NOT NULL,
    -- matched by transform_rule = rule_ref:{rule_name}
    resolution_sql      VARCHAR2(2000)  NOT NULL,
    -- SQL expression; {canonical_name} placeholders substituted by engine
    -- Constituents must be resolved in Pass 1 before this rule executes in Pass 2
    description         VARCHAR2(500),
    is_active           CHAR(1)         DEFAULT 'Y' NOT NULL,
    created_by          VARCHAR2(50)    NOT NULL,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    modified_by         VARCHAR2(50),
    modified_date       DATE,
    --
    CONSTRAINT pk_udm_transform_rules
        PRIMARY KEY (rule_id),
    CONSTRAINT uq_transform_rule_name
        UNIQUE (rule_name),
    CONSTRAINT chk_transform_active
        CHECK (is_active IN ('Y','N'))
);

COMMENT ON TABLE  udm_transform_rules IS
    'Named SQL expressions for rule_ref: transforms. '
    'Rule change = one UPDATE row, no code deployment required.';
COMMENT ON COLUMN udm_transform_rules.resolution_sql IS
    'SQL evaluated in stack row context. '
    '{canonical_name} placeholders replaced by engine with resolved values. '
    'Constituent columns must be is_derived=N and processed in Pass 1.';


-- =============================================================================
-- SECTION 6 — PRECEDENCE RULES
-- Externalises vendor priority logic currently hardcoded in the Option A
-- rules engine stored procedure. Post-DDL task: extract those rules and
-- INSERT here. Procedure then reads this table — config change = one UPDATE.
--
-- priority:    1 = highest. Engine selects lowest priority number with a
--              non-null value in the vendor stack for the relevant period.
-- metric_group: NULL = applies to all metrics in domain.
--              Specific value overrides the NULL-group rule for that group.
--              Matched against udm_attribute_map.metric_group.
-- condition_sql: evaluated against the vendor stack row context for
--              CONDITIONAL rules. Can reference measurement_grain,
--              source_flag columns, or any stack table column.
--              Example: 'scope1_source_flag = ''DIRECT'''
-- =============================================================================

CREATE TABLE udm_precedence_rules (
    rule_id             VARCHAR2(20)    NOT NULL,
    domain_id           VARCHAR2(50)    NOT NULL,
    metric_group        VARCHAR2(100),
    -- NULL = applies to all metrics; specific value overrides for that group
    vendor_id           VARCHAR2(50)    NOT NULL,
    priority            NUMBER(3)       NOT NULL,
    -- 1 = highest priority. Must be unique per domain+metric_group combination.
    condition_type      VARCHAR2(20)    NOT NULL,
    -- ALWAYS      unconditional
    -- CONDITIONAL apply only when condition_sql evaluates TRUE
    condition_sql       VARCHAR2(500),
    -- required when condition_type = CONDITIONAL
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    -- close with effective_to on vendor retirement; NEVER DELETE
    -- arbitration rows reference rule_id for audit trail
    created_by          VARCHAR2(50)    NOT NULL,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    modified_by         VARCHAR2(50),
    modified_date       DATE,
    --
    CONSTRAINT pk_udm_precedence_rules
        PRIMARY KEY (rule_id),
    CONSTRAINT uq_prec_domain_vendor_eff
        UNIQUE (domain_id, metric_group, vendor_id, effective_from),
    CONSTRAINT chk_prec_condition_type
        CHECK (condition_type IN ('ALWAYS','CONDITIONAL')),
    CONSTRAINT chk_prec_condition_sql
        CHECK (condition_type != 'CONDITIONAL' OR condition_sql IS NOT NULL),
    CONSTRAINT chk_prec_priority
        CHECK (priority BETWEEN 1 AND 999)
);

CREATE INDEX idx_prec_rules_domain
    ON udm_precedence_rules (domain_id, metric_group, effective_to);

COMMENT ON TABLE  udm_precedence_rules IS
    'Vendor priority per domain. Externalises logic hardcoded in '
    'Option A rules engine stored procedure. Config change = one UPDATE row.';
COMMENT ON COLUMN udm_precedence_rules.metric_group IS
    'NULL = all metrics in domain. Specific value (e.g. SCOPE3) overrides '
    'NULL-group rule for that group only. Matched against '
    'udm_attribute_map.metric_group.';
COMMENT ON COLUMN udm_precedence_rules.effective_to IS
    'Set when vendor is retired. NEVER DELETE — arbitration rows reference '
    'rule_id and must remain resolvable for audit.';


-- =============================================================================
-- SECTION 7 — GRAIN ALIGNMENT RULES
-- Governs how vendor data at non-canonical grain is brought to canonical
-- grain before arbitration compares vendor values.
--
-- alignment_method values:
--   DIRECT        vendor already at canonical grain — no collapsing needed
--   LAST_VALUE    take the last row within the canonical period
--   FIRST_VALUE   take the first row within the canonical period
--   AVERAGE       arithmetic mean of all rows within the period
--   SUM           sum of all rows — used for COMPANY_SECTOR → COMPANY roll-up
--                 reads udm_entity_membership COMPANY_COMPONENT rows to group
--   EXCLUDE       vendor cannot be aligned to canonical grain — excluded from
--                 arbitration. Data preserved in stack for other grain queries.
--                 e.g. SECTOR grain vendor when canonical grain = COMPANY
--   DISAGGREGATE  apply governed weight table to disaggregate coarser grain
--                 to finer grain. resolution_sql required. Only with explicit
--                 business approval and a governed weight table in place.
-- =============================================================================

CREATE TABLE udm_grain_alignment_rules (
    alignment_id        VARCHAR2(20)    NOT NULL,
    domain_id           VARCHAR2(50)    NOT NULL,
    canonical_grain     VARCHAR2(100)   NOT NULL,
    -- grain of the arb layer e.g. COMPANY-FISCAL_YEAR
    source_vendor       VARCHAR2(50)    NOT NULL,
    source_grain        VARCHAR2(100)   NOT NULL,
    -- grain this vendor delivers e.g. COMPANY_SECTOR-FISCAL_YEAR
    alignment_method    VARCHAR2(20)    NOT NULL,
    resolution_sql      VARCHAR2(1000),
    -- required for DISAGGREGATE; optional for non-standard methods
    -- SUM method reads udm_entity_membership — no SQL needed
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    created_by          VARCHAR2(50)    NOT NULL,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_grain_alignment_rules
        PRIMARY KEY (alignment_id),
    CONSTRAINT uq_grain_domain_vendor_eff
        UNIQUE (domain_id, source_vendor, canonical_grain, effective_from),
    CONSTRAINT chk_alignment_method
        CHECK (alignment_method IN ('DIRECT','LAST_VALUE','FIRST_VALUE',
                                    'AVERAGE','SUM','EXCLUDE','DISAGGREGATE')),
    CONSTRAINT chk_disaggregate_sql
        CHECK (alignment_method != 'DISAGGREGATE' OR resolution_sql IS NOT NULL)
);

COMMENT ON TABLE  udm_grain_alignment_rules IS
    'Brings vendor data to canonical grain before arbitration. '
    'EXCLUDE: vendor cannot participate — data preserved in stack only. '
    'SUM: reads udm_entity_membership COMPANY_COMPONENT to group rows.';
COMMENT ON COLUMN udm_grain_alignment_rules.canonical_grain IS
    'The grain of the arb layer for this domain. e.g. COMPANY-FISCAL_YEAR. '
    'Must match domain_grain on the primary DATA_SOURCE registration.';


-- =============================================================================
-- SECTION 8 — DQ RULES
-- Threshold-dependent checks only.
-- Auto-derived checks (type conformance, not-null, unmapped attribute,
-- referential integrity) require no entry here — they derive from
-- udm_attribute_map at engine runtime.
--
-- check_type values:
--   DRIFT        period-over-period variance (threshold = allowed % change)
--   BOUNDS       absolute min/max bounds (min_value / max_value columns)
--   COMPLETENESS expected entity population coverage (threshold = required %)
--   CROSS_VENDOR tolerance between vendor values before arbitration
-- =============================================================================

CREATE TABLE udm_dq_rules (
    rule_id             VARCHAR2(20)    NOT NULL,
    domain_id           VARCHAR2(50)    NOT NULL,
    metric_name         VARCHAR2(128)   NOT NULL,
    -- canonical_name from udm_attribute_map
    check_type          VARCHAR2(20)    NOT NULL,
    threshold           NUMBER,
    -- % for DRIFT / COMPLETENESS / CROSS_VENDOR; not used for BOUNDS
    min_value           NUMBER,
    -- BOUNDS: lower bound
    max_value           NUMBER,
    -- BOUNDS: upper bound
    action              VARCHAR2(20)    NOT NULL,
    -- ALERT | QUARANTINE | REJECT
    is_active           CHAR(1)         DEFAULT 'Y' NOT NULL,
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    created_by          VARCHAR2(50)    NOT NULL,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    modified_by         VARCHAR2(50),
    modified_date       DATE,
    --
    CONSTRAINT pk_udm_dq_rules
        PRIMARY KEY (rule_id),
    CONSTRAINT uq_dq_rules_domain_metric_type
        UNIQUE (domain_id, metric_name, check_type, effective_from),
    CONSTRAINT chk_dq_check_type
        CHECK (check_type IN ('DRIFT','BOUNDS','COMPLETENESS','CROSS_VENDOR')),
    CONSTRAINT chk_dq_action
        CHECK (action IN ('ALERT','QUARANTINE','REJECT')),
    CONSTRAINT chk_dq_active
        CHECK (is_active IN ('Y','N')),
    CONSTRAINT chk_dq_bounds_present
        CHECK (check_type != 'BOUNDS' OR (min_value IS NOT NULL AND max_value IS NOT NULL))
);

COMMENT ON TABLE udm_dq_rules IS
    'Threshold-dependent DQ checks only. '
    'Auto-derived checks derive from udm_attribute_map at engine runtime.';


-- =============================================================================
-- SECTION 9 — ENTITY REGISTRY
-- Identity only. No metrics. No vendor attributes. No descriptive profile.
-- entity_key = UDM-owned sequence starting at 1,000,000.
-- source_key = original source system PK (e.g. customer_bk from CST_DIM).
--   Used to join to udm_ref_* tables during migration.
--   NULL for UDM-generated entities (COMPANY_SECTOR) with no source PK.
--
-- entity_type values:
--   COMPANY        a business organisation
--   SUPPLIER       a supply chain participant
--   COUNTERPARTY   a trading counterparty
--   PRODUCT        an instrument, product, or security
--   SECTOR         an industry classification group
--   REGION         a geographic region (EMEA, APAC etc.)
--   COUNTRY        a sovereign country
--   COMPANY_SECTOR composite — one company operating in one sector
--                  decomposed via udm_entity_membership
--
-- How entities are created:
--   COMPANY/SUPPLIER/COUNTERPARTY: side effect of REFERENCE_SOURCE load
--     (creates_entity=Y on udm_ref_source_map); NOT by the engine directly
--   SECTOR/REGION/COUNTRY: auto-created on first DATA_SOURCE encounter
--     using canonical_name from ref table lookup on standard code
--   COMPANY_SECTOR: auto-created by derive_cs: transform during fact ingest
-- =============================================================================

CREATE TABLE udm_entity_registry (
    entity_key          VARCHAR2(20)    NOT NULL,
    -- UDM-generated. Format: {type_prefix}-{LPAD(seq,6,'0')}
    -- e.g. ENT-1000001 (COMPANY), SEC-1000045 (SECTOR)
    -- Sequence starts at 1,000,000 — avoids collision with source PKs
    entity_type         VARCHAR2(20)    NOT NULL,
    canonical_name      VARCHAR2(200)   NOT NULL,
    source_key          VARCHAR2(100),
    -- Original source system PK (e.g. customer_bk from CST_DIM).
    -- Join to ref tables: WHERE ref_table.natural_key = entity_registry.source_key
    -- NULL for UDM-generated entities (COMPANY_SECTOR etc.)
    is_active           CHAR(1)         DEFAULT 'Y' NOT NULL,
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    modified_date       DATE,
    notes               VARCHAR2(500),
    --
    CONSTRAINT pk_udm_entity_registry
        PRIMARY KEY (entity_key),
    CONSTRAINT chk_entity_type
        CHECK (entity_type IN ('COMPANY','SUPPLIER','COUNTERPARTY','PRODUCT',
                               'SECTOR','REGION','COUNTRY','COMPANY_SECTOR')),
    CONSTRAINT chk_entity_active
        CHECK (is_active IN ('Y','N'))
);

CREATE INDEX idx_entity_reg_type_active
    ON udm_entity_registry (entity_type, is_active);
CREATE INDEX idx_entity_reg_type_sourcekey
    ON udm_entity_registry (entity_type, source_key);
-- hot path: ref table join via source_key during migration period

COMMENT ON TABLE  udm_entity_registry IS
    'Identity only. No metrics. Keys never change or recycled. '
    'entity_key = UDM sequence from 1,000,000. '
    'source_key = original source PK for ref table joins.';
COMMENT ON COLUMN udm_entity_registry.source_key IS
    'Original source PK (e.g. customer_bk from CST_DIM). '
    'Join to ref tables: ref_table.natural_key = entity_registry.source_key. '
    'NOT entity_key — ref tables do not carry entity_key FK. '
    'NULL for UDM-generated entities (COMPANY_SECTOR).';
COMMENT ON COLUMN udm_entity_registry.entity_type IS
    'COMPANY_SECTOR: composite entity — one company in one sector. '
    'Decomposed via udm_entity_membership (COMPANY_COMPONENT + SECTOR_COMPONENT).';


-- =============================================================================
-- SECTION 10 — COMPANY CROSS-REFERENCE
-- Maps vendor-specific company identifiers to UDM entity_key.
-- Renamed from udm_entity_xref — company/counterparty/supplier xref only.
-- Sectors, regions, countries use universal standard codes — no xref needed.
-- COMPANY_SECTOR keys are UDM-generated — no vendor supplies composite key.
--
-- CRITICAL: This table is maintained by an EXTERNAL MDM process.
-- UDM engine reads it — does not write to it.
-- Must be pre-populated before the first vendor DATA_SOURCE fact load runs.
-- Without this table populated, all vendor COMPANY rows are rejected
-- to udm_quarantine with check_type = ENTITY_NOT_FOUND.
-- =============================================================================

CREATE TABLE udm_company_xref (
    xref_id             VARCHAR2(20)    NOT NULL,
    entity_key          VARCHAR2(20)    NOT NULL,
    vendor_id           VARCHAR2(50)    NOT NULL,
    -- FK to udm_source_system.source_system_cd
    -- For internal systems: vendor_id = 'INT_RDM', external_id = customer_bk
    external_id         VARCHAR2(100)   NOT NULL,
    -- the vendor's raw identifier for this entity
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    -- NULL = currently active mapping
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_company_xref
        PRIMARY KEY (xref_id),
    CONSTRAINT fk_co_xref_entity
        FOREIGN KEY (entity_key) REFERENCES udm_entity_registry (entity_key),
    CONSTRAINT fk_co_xref_src_sys
        FOREIGN KEY (vendor_id)  REFERENCES udm_source_system (source_system_cd),
    CONSTRAINT uq_co_xref_vendor_external_eff
        UNIQUE (vendor_id, external_id, effective_from)
);

CREATE INDEX idx_co_xref_lookup
    ON udm_company_xref (vendor_id, external_id, effective_to);
-- hot path at ingest: WHERE vendor_id = :v AND external_id = :e AND effective_to IS NULL

COMMENT ON TABLE  udm_company_xref IS
    'Maps vendor company identifiers to UDM entity_key. '
    'MAINTAINED BY EXTERNAL MDM PROCESS — UDM engine reads only. '
    'Must be pre-populated before first vendor fact load. '
    'Internal system: vendor_id = INT_RDM, external_id = customer_bk.';


-- =============================================================================
-- SECTION 11 — ENTITY MEMBERSHIP
-- Defines what composite entities are made of and entity relationships.
-- Three use cases:
--
-- USE 1 — GRAIN ALIGNMENT ENGINE (critical)
--   Rolls COMPANY_SECTOR rows to COMPANY canonical grain.
--   Engine reads COMPANY_COMPONENT rows to find the company entity_key.
--   GROUP BY parent_entity_key → SUM metrics → one COMPANY row per company.
--
-- USE 2 — BI CONSUMER LAYER
--   Forward lookup: COMPANY_SECTOR entity_key → company + sector keys.
--   Reverse lookup: company key + sector key → COMPANY_SECTOR entity_key.
--   Served by udm_company_sector_mv (created at domain onboarding — not Tier 1).
--
-- USE 3 — SECTOR HIERARCHY TRAVERSAL
--   SECTOR_MEMBERSHIP: which sectors does a company belong to?
--   REGION_MEMBERSHIP: which region does a country belong to?
--
-- Two rows per COMPANY_SECTOR entity:
--   entity_key=ENT-CS-001, parent_entity_key=ENT-1000001, COMPANY_COMPONENT
--   entity_key=ENT-CS-001, parent_entity_key=ENT-S-001,   SECTOR_COMPONENT
-- =============================================================================

CREATE TABLE udm_entity_membership (
    membership_id       VARCHAR2(20)    NOT NULL,
    entity_key          VARCHAR2(20)    NOT NULL,
    -- child / member entity (e.g. ENT-CS-001 COMPANY_SECTOR)
    parent_entity_key   VARCHAR2(20)    NOT NULL,
    -- parent / owning entity (e.g. ENT-1000001 COMPANY or ENT-S-001 SECTOR)
    relationship_type   VARCHAR2(30)    NOT NULL,
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    created_by          VARCHAR2(50)    NOT NULL,
    --
    CONSTRAINT pk_udm_entity_membership
        PRIMARY KEY (membership_id),
    CONSTRAINT fk_membership_entity
        FOREIGN KEY (entity_key)        REFERENCES udm_entity_registry (entity_key),
    CONSTRAINT fk_membership_parent
        FOREIGN KEY (parent_entity_key) REFERENCES udm_entity_registry (entity_key),
    CONSTRAINT uq_membership_natural
        UNIQUE (entity_key, parent_entity_key, relationship_type, effective_from),
    CONSTRAINT chk_membership_rel_type
        CHECK (relationship_type IN ('COMPANY_COMPONENT','SECTOR_COMPONENT',
                                     'SECTOR_MEMBERSHIP','REGION_MEMBERSHIP'))
);

CREATE INDEX idx_membership_entity
    ON udm_entity_membership (entity_key, relationship_type, effective_to);
-- grain alignment: WHERE entity_key = stk.entity_key AND type = COMPANY_COMPONENT

CREATE INDEX idx_membership_parent
    ON udm_entity_membership (parent_entity_key, relationship_type, effective_to);
-- reverse lookup: WHERE parent_entity_key = :company AND type = COMPANY_COMPONENT

COMMENT ON TABLE  udm_entity_membership IS
    'Defines composite entity constructs and entity relationships. '
    'Primary use: grain alignment engine reads COMPANY_COMPONENT rows '
    'to roll COMPANY_SECTOR measurements up to COMPANY canonical grain.';
COMMENT ON COLUMN udm_entity_membership.entity_key IS
    'Child/member entity e.g. ENT-CS-001 (COMPANY_SECTOR).';
COMMENT ON COLUMN udm_entity_membership.parent_entity_key IS
    'Parent/owning entity e.g. ENT-1000001 (COMPANY) or ENT-S-001 (SECTOR).';


-- =============================================================================
-- SECTION 12 — SPATIAL ASSET REGISTRY
-- 40M+ lat/long assets. Separate from entity_registry —
-- different entity type, different scale, different query patterns.
-- geohash pre-computed at ingest from lat/long.
-- Prefix locality enables fast regional filtering without spatial computation:
--   WHERE geohash LIKE 'gcpv%'  ← all assets in a geographic cell
-- region_cd derived from geohash prefix at ingest.
-- Aligns with partition key in physical risk canonical tables.
-- linked_entity_key is nullable — not all assets belong to a known entity.
-- =============================================================================

CREATE TABLE udm_spatial_asset_registry (
    spatial_asset_key   VARCHAR2(20)    NOT NULL,
    -- Format: SAK-NNNNNNN
    source_id           VARCHAR2(20)    NOT NULL,
    vendor_asset_id     VARCHAR2(100)   NOT NULL,
    latitude            NUMBER(10,7)    NOT NULL,
    longitude           NUMBER(10,7)    NOT NULL,
    geohash             VARCHAR2(12)    NOT NULL,
    -- precision 7 ≈ 153m cell; longer prefix = more precise location
    region_cd           VARCHAR2(10)    NOT NULL,
    -- EMEA | APAC | AMER | ROW; derived from geohash prefix at ingest
    asset_type          VARCHAR2(50),
    -- BUILDING | PORT | FACILITY | VESSEL | INFRASTRUCTURE
    linked_entity_key   VARCHAR2(20),
    -- nullable FK — asset may or may not belong to a known business entity
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_spatial_asset_registry
        PRIMARY KEY (spatial_asset_key),
    CONSTRAINT fk_spatial_source
        FOREIGN KEY (source_id)         REFERENCES udm_source_registry (source_id),
    CONSTRAINT fk_spatial_entity
        FOREIGN KEY (linked_entity_key) REFERENCES udm_entity_registry (entity_key),
    CONSTRAINT chk_spatial_region
        CHECK (region_cd IN ('EMEA','APAC','AMER','ROW')),
    CONSTRAINT uq_spatial_vendor_asset
        UNIQUE (source_id, vendor_asset_id, effective_from)
);

CREATE INDEX idx_spatial_geohash
    ON udm_spatial_asset_registry (geohash);
CREATE INDEX idx_spatial_region_active
    ON udm_spatial_asset_registry (region_cd, effective_to);
CREATE INDEX idx_spatial_entity_link
    ON udm_spatial_asset_registry (linked_entity_key);

COMMENT ON TABLE  udm_spatial_asset_registry IS
    '40M+ lat/long spatial assets. Separate from entity_registry — '
    'different scale and query patterns (geohash spatial indexing).';
COMMENT ON COLUMN udm_spatial_asset_registry.geohash IS
    'Pre-computed at ingest. WHERE geohash LIKE ''gcpv%'' gives '
    'all assets in a geographic cell without spatial computation.';


-- =============================================================================
-- SECTION 13 — SOURCE ROUTING MAP
-- Satellite table for REFERENCE_SOURCE registrations.
-- Consulted by the engine when source_role = REFERENCE_SOURCE.
-- Declares target udm_ref_* table and how to refresh it.
-- creates_entity = Y: REFERENCE_SOURCE load also seeds udm_entity_registry
-- as a side effect — entity creation is not a separate process.
-- =============================================================================

CREATE TABLE udm_ref_source_map (
    ref_map_id              VARCHAR2(20)    NOT NULL,
    source_id               VARCHAR2(20)    NOT NULL,
    -- must reference a source with source_role = REFERENCE_SOURCE
    ref_table_name          VARCHAR2(128)   NOT NULL,
    -- target udm_ref_* table e.g. udm_ref_company
    refresh_strategy        VARCHAR2(25)    NOT NULL,
    -- FULL_REPLACE         truncate and reload; for small stable lookups
    -- INCREMENTAL          insert/update using ref_natural_key_cols; for larger tables
    -- EFFECTIVE_DATE_MERGE insert new effective_from row; close previous with effective_to
    ref_natural_key_cols    VARCHAR2(200)   NOT NULL,
    -- comma-separated column list; used as dedup key for INCREMENTAL
    -- and as match key for EFFECTIVE_DATE_MERGE
    creates_entity          CHAR(1)         DEFAULT 'N' NOT NULL,
    -- Y = engine also seeds udm_entity_registry as side effect of ref load
    -- source_key on entity_registry = natural key of the ref table
    entity_type             VARCHAR2(20),
    -- required when creates_entity = Y
    -- written to udm_entity_registry.entity_type
    is_active               CHAR(1)         DEFAULT 'Y' NOT NULL,
    effective_from          DATE            NOT NULL,
    created_by              VARCHAR2(50)    NOT NULL,
    created_date            DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_ref_source_map
        PRIMARY KEY (ref_map_id),
    CONSTRAINT fk_refsrcmap_source
        FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_refsrcmap_source_table
        UNIQUE (source_id, ref_table_name),
    CONSTRAINT chk_ref_refresh
        CHECK (refresh_strategy IN ('FULL_REPLACE','INCREMENTAL','EFFECTIVE_DATE_MERGE')),
    CONSTRAINT chk_ref_creates_entity
        CHECK (creates_entity IN ('Y','N')),
    CONSTRAINT chk_ref_entity_type_required
        CHECK (creates_entity = 'N' OR entity_type IS NOT NULL),
    CONSTRAINT chk_ref_entity_type_valid
        CHECK (entity_type IS NULL OR entity_type IN
               ('COMPANY','SUPPLIER','COUNTERPARTY','PRODUCT',
                'SECTOR','REGION','COUNTRY','COMPANY_SECTOR')),
    CONSTRAINT chk_ref_active
        CHECK (is_active IN ('Y','N'))
);

COMMENT ON TABLE  udm_ref_source_map IS
    'Maps REFERENCE_SOURCE entries to target udm_ref_* table and refresh strategy. '
    'creates_entity=Y: engine seeds udm_entity_registry as side effect. '
    'This replaces udm_identity_source_map — entity creation is now '
    'a side effect of reference data loading, not a separate process.';
COMMENT ON COLUMN udm_ref_source_map.creates_entity IS
    'Y = engine INSERTs into udm_entity_registry for each new natural key found. '
    'entity_type declared here is written to entity_registry.entity_type. '
    'source_key on entity_registry receives the ref table natural key value.';


-- =============================================================================
-- SECTION 14 — REFERENCE TABLES (TYPED BY ENTITY TYPE)
-- One udm_ref_* table per entity type.
-- Natural keys only — NO entity_key FK to udm_entity_registry.
-- Ref tables are independent of whether the entity is a measurement subject.
-- A sector in udm_ref_sector does not require an entity_registry entry.
--
-- Joins from entity_registry to ref tables:
--   entity_registry.source_key = ref_table.natural_key_column
--   NOT entity_key — there is no entity_key on ref tables.
--
-- All ref tables follow consistent structure:
--   {ref_key}        surrogate PK
--   {natural_key}    business identifier from source system
--   {descriptors}    type-specific governed attributes
--   effective_from / effective_to   temporal governance
--   source_id        which registered source last updated this row
--
-- Governance: ref table data stays under source system governance (e.g. CST_DIM)
-- until an explicit business decision makes UDM the master.
-- governance_status on udm_source_registry tracks the transition.
-- =============================================================================

-- Company descriptive profile
-- Natural key: company_source_key (customer_bk from CST_DIM)
-- Seeded from CST_DIM via REFERENCE_SOURCE load with creates_entity = Y
CREATE TABLE udm_ref_company (
    ref_company_key     VARCHAR2(20)    NOT NULL,
    company_source_key  VARCHAR2(100)   NOT NULL,
    -- natural key from source system (e.g. customer_bk from CST_DIM)
    -- matches udm_entity_registry.source_key for COMPANY entities
    legal_name          VARCHAR2(200)   NOT NULL,
    jurisdiction_cd     VARCHAR2(10),
    entity_status       VARCHAR2(30),
    primary_naics_code  VARCHAR2(20),
    -- links to udm_ref_sector.class_code for sector classification context
    -- used at query time for JOIN enrichment — not a FK constraint
    lei_code            VARCHAR2(20),
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    source_id           VARCHAR2(20),
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_ref_company
        PRIMARY KEY (ref_company_key),
    CONSTRAINT fk_ref_company_source
        FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_company_sourcekey_eff
        UNIQUE (company_source_key, effective_from)
);

CREATE INDEX idx_ref_company_lookup
    ON udm_ref_company (company_source_key, effective_to);

COMMENT ON TABLE  udm_ref_company IS
    'Company descriptive profile. Natural key: company_source_key. '
    'No entity_key FK — independent of entity_registry. '
    'Join to entity_registry: entity_registry.source_key = company_source_key.';
COMMENT ON COLUMN udm_ref_company.company_source_key IS
    'Natural key from source system (e.g. customer_bk from CST_DIM). '
    'Matches udm_entity_registry.source_key for COMPANY entities.';


-- Counterparty descriptive profile
-- Natural key: counterparty_source_key
CREATE TABLE udm_ref_counterparty (
    ref_cpty_key            VARCHAR2(20)    NOT NULL,
    counterparty_source_key VARCHAR2(100)   NOT NULL,
    legal_name              VARCHAR2(200)   NOT NULL,
    counterparty_type       VARCHAR2(50),
    credit_rating           VARCHAR2(10),
    jurisdiction_cd         VARCHAR2(10),
    netting_agreement_flag  CHAR(1),
    effective_from          DATE            NOT NULL,
    effective_to            DATE,
    source_id               VARCHAR2(20),
    created_date            DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_ref_counterparty
        PRIMARY KEY (ref_cpty_key),
    CONSTRAINT fk_ref_cpty_source
        FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_cpty_sourcekey_eff
        UNIQUE (counterparty_source_key, effective_from),
    CONSTRAINT chk_ref_cpty_netting
        CHECK (netting_agreement_flag IN ('Y','N'))
);

CREATE INDEX idx_ref_cpty_lookup
    ON udm_ref_counterparty (counterparty_source_key, effective_to);


-- Supplier descriptive profile
-- Natural key: supplier_source_key
CREATE TABLE udm_ref_supplier (
    ref_supplier_key    VARCHAR2(20)    NOT NULL,
    supplier_source_key VARCHAR2(100)   NOT NULL,
    legal_name          VARCHAR2(200)   NOT NULL,
    supplier_tier       VARCHAR2(20),
    primary_commodity   VARCHAR2(100),
    country_of_origin   VARCHAR2(3),
    approved_flag       CHAR(1),
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    source_id           VARCHAR2(20),
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_ref_supplier
        PRIMARY KEY (ref_supplier_key),
    CONSTRAINT fk_ref_supplier_source
        FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_supplier_sourcekey_eff
        UNIQUE (supplier_source_key, effective_from),
    CONSTRAINT chk_ref_supplier_approved
        CHECK (approved_flag IN ('Y','N'))
);

CREATE INDEX idx_ref_supplier_lookup
    ON udm_ref_supplier (supplier_source_key, effective_to);


-- Sector classification reference + hierarchy
-- Natural key: classification_system + class_code
-- Supports multiple classification systems (NAICS, GICS, SIC, NACE, INTERNAL)
-- in one table — distinguished by classification_system column.
-- Hierarchy via parent_class_code (self-referencing natural key, no FK
-- constraint to avoid lock contention on bulk hierarchy loads).
-- Engine resolves SECTOR entity_key via:
--   SELECT entity_key FROM udm_entity_registry
--   WHERE entity_type = 'SECTOR' AND source_key = class_code
CREATE TABLE udm_ref_sector (
    ref_sector_key          VARCHAR2(20)    NOT NULL,
    classification_system   VARCHAR2(50)    NOT NULL,
    -- NAICS | GICS | SIC | NACE | INTERNAL | BASEL_ASSET_CLASS
    class_code              VARCHAR2(50)    NOT NULL,
    class_name              VARCHAR2(200)   NOT NULL,
    class_level             NUMBER(2),
    -- 1 = top level (e.g. GICS Sector), higher = more granular
    parent_class_code       VARCHAR2(50),
    -- self-referencing natural key hierarchy traversal
    -- no FK constraint — avoids lock contention on bulk loads
    effective_from          DATE            NOT NULL,
    effective_to            DATE,
    source_id               VARCHAR2(20),
    created_date            DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_ref_sector
        PRIMARY KEY (ref_sector_key),
    CONSTRAINT fk_ref_sector_source
        FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_sector_natural_eff
        UNIQUE (classification_system, class_code, effective_from)
);

CREATE INDEX idx_ref_sector_lookup
    ON udm_ref_sector (classification_system, class_code, effective_to);
CREATE INDEX idx_ref_sector_parent
    ON udm_ref_sector (classification_system, parent_class_code);

COMMENT ON TABLE  udm_ref_sector IS
    'Sector classification reference. Natural key: classification_system + class_code. '
    'No entity_key FK — independent of entity_registry. '
    'Engine resolves SECTOR entity_key via entity_registry.source_key = class_code.';
COMMENT ON COLUMN udm_ref_sector.parent_class_code IS
    'Self-referencing natural key hierarchy. No FK constraint — '
    'avoids lock contention on bulk hierarchy loads.';


-- Region hierarchy
-- Natural key: region_cd
CREATE TABLE udm_ref_region (
    ref_region_key      VARCHAR2(20)    NOT NULL,
    region_cd           VARCHAR2(10)    NOT NULL,
    -- EMEA | APAC | AMER | ROW; aligns with partition key in spatial tables
    region_name         VARCHAR2(200)   NOT NULL,
    parent_region_cd    VARCHAR2(10),
    -- natural key reference to parent region or continent; no FK constraint
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    source_id           VARCHAR2(20),
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_ref_region
        PRIMARY KEY (ref_region_key),
    CONSTRAINT fk_ref_region_source
        FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_region_cd_eff
        UNIQUE (region_cd, effective_from)
);

CREATE INDEX idx_ref_region_lookup
    ON udm_ref_region (region_cd, effective_to);


-- Country reference
-- Natural key: iso_country_cd (ISO 3166 alpha-3)
-- region_cd references udm_ref_region.region_cd — natural key, no FK constraint
CREATE TABLE udm_ref_country (
    ref_country_key     VARCHAR2(20)    NOT NULL,
    iso_country_cd      VARCHAR2(3)     NOT NULL,
    -- ISO 3166 alpha-3; universal code — no competing vendor identifiers
    country_name        VARCHAR2(200)   NOT NULL,
    region_cd           VARCHAR2(10),
    -- natural key reference to udm_ref_region.region_cd; no FK constraint
    sovereignty_status  VARCHAR2(30),
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    source_id           VARCHAR2(20),
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_ref_country
        PRIMARY KEY (ref_country_key),
    CONSTRAINT fk_ref_country_source
        FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_country_iso_eff
        UNIQUE (iso_country_cd, effective_from)
);

CREATE INDEX idx_ref_country_lookup
    ON udm_ref_country (iso_country_cd, effective_to);
CREATE INDEX idx_ref_country_region
    ON udm_ref_country (region_cd);


-- Product reference — standalone
-- No entity_key. Used when products appear as attributes of measurements
-- rather than as measurement subjects.
-- If products ARE measurement subjects, register as PRODUCT entity_type
-- in udm_entity_registry instead.
CREATE TABLE udm_ref_product (
    ref_product_key     VARCHAR2(20)    NOT NULL,
    product_code        VARCHAR2(50)    NOT NULL,
    product_name        VARCHAR2(200)   NOT NULL,
    product_type        VARCHAR2(50),
    asset_class         VARCHAR2(50),
    currency_cd         VARCHAR2(3),
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    source_id           VARCHAR2(20),
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_ref_product
        PRIMARY KEY (ref_product_key),
    CONSTRAINT fk_ref_product_source
        FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_product_code_eff
        UNIQUE (product_code, effective_from)
);

COMMENT ON TABLE udm_ref_product IS
    'Standalone. No entity_key. Used when products are attributes of other '
    'measurements. If products are measurement subjects, register as PRODUCT '
    'entity type in udm_entity_registry.';


-- Fiscal calendar and period reference — standalone
-- Maps coverage_period strings stored in domain tables to date ranges.
-- Domain tables store period as VARCHAR2 (e.g. 2024-Q1, FY2024).
CREATE TABLE udm_ref_time (
    ref_time_key        VARCHAR2(20)    NOT NULL,
    period_value        VARCHAR2(20)    NOT NULL,
    -- the coverage_period string as stored in domain stack/arb tables
    period_grain        VARCHAR2(10)    NOT NULL,
    -- DAY | WEEK | MONTH | QTR | ANNUAL
    calendar_type       VARCHAR2(20)    NOT NULL,
    -- GREGORIAN | FISCAL | REGULATORY
    year_number         NUMBER(4),
    quarter_number      NUMBER(1),
    month_number        NUMBER(2),
    period_start_date   DATE            NOT NULL,
    period_end_date     DATE            NOT NULL,
    fiscal_year         VARCHAR2(10),
    is_current_period   CHAR(1)         DEFAULT 'N' NOT NULL,
    source_id           VARCHAR2(20),
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_ref_time
        PRIMARY KEY (ref_time_key),
    CONSTRAINT fk_ref_time_source
        FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_time_period_calendar
        UNIQUE (period_value, calendar_type),
    CONSTRAINT chk_ref_period_grain
        CHECK (period_grain IN ('DAY','WEEK','MONTH','QTR','ANNUAL')),
    CONSTRAINT chk_ref_calendar_type
        CHECK (calendar_type IN ('GREGORIAN','FISCAL','REGULATORY')),
    CONSTRAINT chk_ref_time_current
        CHECK (is_current_period IN ('Y','N'))
);

CREATE INDEX idx_ref_time_grain_year
    ON udm_ref_time (period_grain, year_number, calendar_type);

COMMENT ON TABLE udm_ref_time IS
    'Standalone fiscal calendar. No entity_key. '
    'Maps coverage_period strings in domain tables to date ranges.';


-- =============================================================================
-- SECTION 15 — DELIVERY MANIFEST
-- Bundle validation gate. Engine blocked until status = COMPLETE.
-- A delivery may arrive as multiple files (header + detail + corrections).
-- Manifest tracks completeness. Single-file sources use expected_files = 1.
-- SUPERSEDED: a later delivery arrived for the same period — prior manifest
-- retained for audit; engine processes the new one.
-- =============================================================================

CREATE TABLE udm_delivery_manifest (
    manifest_id         VARCHAR2(30)    NOT NULL,
    -- Format: MAN-YYYYMMDD-NNNNN
    source_id           VARCHAR2(20)    NOT NULL,
    vendor_id           VARCHAR2(50)    NOT NULL,
    coverage_period     VARCHAR2(20)    NOT NULL,
    -- e.g. 2024-Q1 | FY2024 | 2024-03
    expected_files      NUMBER(5)       NOT NULL,
    files_received      NUMBER(5)       DEFAULT 0  NOT NULL,
    status              VARCHAR2(20)    DEFAULT 'PARTIAL' NOT NULL,
    -- PARTIAL | COMPLETE | FAILED | SUPERSEDED
    received_at         DATE            DEFAULT SYSDATE NOT NULL,
    completed_at        DATE,
    lineage_id          VARCHAR2(30),
    -- set when COMPLETE manifest triggers harmonisation run
    notes               VARCHAR2(500),
    --
    CONSTRAINT pk_udm_delivery_manifest
        PRIMARY KEY (manifest_id),
    CONSTRAINT fk_manifest_source
        FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT chk_manifest_status
        CHECK (status IN ('PARTIAL','COMPLETE','FAILED','SUPERSEDED')),
    CONSTRAINT chk_manifest_files
        CHECK (files_received <= expected_files OR status = 'FAILED')
);

CREATE INDEX idx_manifest_vendor_period_status
    ON udm_delivery_manifest (vendor_id, coverage_period, status);

COMMENT ON TABLE udm_delivery_manifest IS
    'Bundle validation gate. Engine blocked until status = COMPLETE. '
    'Single-file sources: expected_files = 1. '
    'SUPERSEDED: later delivery for same period — prior retained for audit.';


-- =============================================================================
-- SECTION 16 — LINEAGE
-- Batch-level processing audit trail. One row per processing event.
-- lineage_type: LOAD | ARBITRATION | DI_CHECK | MANIFEST
-- Row-level failures: udm_quarantine and udm_dq_results — NOT lineage.
-- duration_secs: virtual column — no storage cost; available for SLA queries.
-- Partitioned monthly to manage continuous growth.
--
-- FK chain from lineage to all downstream tables:
--   udm_delivery_manifest.lineage_id  set when manifest triggers harmonisation
--   udm_{domain}_stk.lineage_id       set by engine per batch
--   udm_dq_results.lineage_id         set by DI framework per check run
--   udm_quarantine.lineage_id         set by engine per rejected row batch
-- This chain supports the full audit query: arb value → stk → lineage → manifest
-- =============================================================================

CREATE TABLE udm_lineage (
    lineage_id          VARCHAR2(30)    NOT NULL,
    -- Format: LIN-YYYYMMDD-NNNNN
    lineage_type        VARCHAR2(20)    NOT NULL,
    source_id           VARCHAR2(20),
    -- NULL for ARBITRATION type — reads multiple sources
    domain_id           VARCHAR2(50),
    vendor_id           VARCHAR2(50),
    coverage_period     VARCHAR2(20),
    manifest_id         VARCHAR2(30),
    rows_read           NUMBER,
    rows_written        NUMBER,
    rows_rejected       NUMBER,
    rows_quarantined    NUMBER,
    started_at          DATE,
    completed_at        DATE,
    duration_secs       NUMBER
        GENERATED ALWAYS AS (ROUND((completed_at - started_at) * 86400)) VIRTUAL,
    -- virtual: zero storage; computed from started_at/completed_at
    status              VARCHAR2(20)    NOT NULL,
    -- RUNNING | COMPLETE | FAILED | PARTIAL
    error_message       VARCHAR2(2000),
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_lineage
        PRIMARY KEY (lineage_id),
    CONSTRAINT chk_lineage_type
        CHECK (lineage_type IN ('LOAD','ARBITRATION','DI_CHECK','MANIFEST')),
    CONSTRAINT chk_lineage_status
        CHECK (status IN ('RUNNING','COMPLETE','FAILED','PARTIAL'))
)
PARTITION BY RANGE (created_date)
INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
(
    PARTITION p_lineage_initial VALUES LESS THAN (DATE '2024-01-01')
);

CREATE INDEX idx_lineage_domain_period
    ON udm_lineage (domain_id, coverage_period, lineage_type) LOCAL;
CREATE INDEX idx_lineage_vendor_date
    ON udm_lineage (vendor_id, created_date) LOCAL;
CREATE INDEX idx_lineage_status
    ON udm_lineage (status, created_date) LOCAL;

COMMENT ON TABLE  udm_lineage IS
    'Batch-level audit trail. One row per processing event. '
    'Row-level failures in udm_quarantine + udm_dq_results. '
    'Partitioned monthly. FK chain: manifest → stk → arb value.';
COMMENT ON COLUMN udm_lineage.duration_secs IS
    'Virtual column. Zero storage. Computed from started_at/completed_at.';


-- =============================================================================
-- SECTION 17 — QUARANTINE
-- Rows rejected at staging — full row data retained for vendor contact
-- and reprocessing. Separate from udm_dq_results which records batch-level
-- check outcomes only. This table holds actual failing row data.
-- resolved_flag tracks whether the row was eventually reprocessed.
-- Partitioned monthly.
--
-- check_type values:
--   DATA_TYPE          value could not be cast to declared data_type
--   NOT_NULL           mandatory attribute was NULL
--   BOUNDS             value outside declared min/max bounds
--   UNMAPPED_ATTRIBUTE EAV attribute_name not in attribute_map
--   REFERENTIAL        lookup transform returned no result
--   ENTITY_NOT_FOUND   vendor entity ID not in udm_company_xref
--                      (only for XREF_ONLY resolution — engine cannot create)
-- =============================================================================

CREATE TABLE udm_quarantine (
    quarantine_id       VARCHAR2(30)    NOT NULL,
    -- Format: QRN-YYYYMMDD-NNNNN
    lineage_id          VARCHAR2(30)    NOT NULL,
    source_id           VARCHAR2(20)    NOT NULL,
    domain_id           VARCHAR2(50)    NOT NULL,
    vendor_id           VARCHAR2(50)    NOT NULL,
    coverage_period     VARCHAR2(20),
    entity_id_raw       VARCHAR2(200),
    -- raw vendor identifier before resolution was attempted
    attribute_name      VARCHAR2(128),
    -- canonical_name from attribute_map that triggered rejection
    raw_value           VARCHAR2(2000),
    -- actual failing value cast to VARCHAR2 for storage
    -- enables exact reproduction of vendor row for reprocessing
    check_type          VARCHAR2(30)    NOT NULL,
    rejection_reason    VARCHAR2(500)   NOT NULL,
    quarantined_at      DATE            DEFAULT SYSDATE NOT NULL,
    resolved_flag       CHAR(1)         DEFAULT 'N' NOT NULL,
    resolved_at         DATE,
    resolved_by         VARCHAR2(50),
    resolution_notes    VARCHAR2(500),
    --
    CONSTRAINT pk_udm_quarantine
        PRIMARY KEY (quarantine_id),
    CONSTRAINT fk_quarantine_lineage
        FOREIGN KEY (lineage_id) REFERENCES udm_lineage (lineage_id),
    CONSTRAINT fk_quarantine_source
        FOREIGN KEY (source_id)  REFERENCES udm_source_registry (source_id),
    CONSTRAINT chk_quarantine_check_type
        CHECK (check_type IN ('DATA_TYPE','NOT_NULL','BOUNDS',
                              'UNMAPPED_ATTRIBUTE','REFERENTIAL','ENTITY_NOT_FOUND')),
    CONSTRAINT chk_quarantine_resolved
        CHECK (resolved_flag IN ('Y','N'))
)
PARTITION BY RANGE (quarantined_at)
INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
(
    PARTITION p_quarantine_initial VALUES LESS THAN (DATE '2024-01-01')
);

CREATE INDEX idx_quarantine_source_period
    ON udm_quarantine (source_id, coverage_period, resolved_flag) LOCAL;
CREATE INDEX idx_quarantine_unresolved
    ON udm_quarantine (resolved_flag, quarantined_at) LOCAL;

COMMENT ON COLUMN udm_quarantine.check_type IS
    'ENTITY_NOT_FOUND: vendor entity ID not in udm_company_xref. '
    'PO investigates — new entity or data quality issue? '
    'Catalog team adds to xref; engine re-runs for quarantined rows.';


-- =============================================================================
-- SECTION 18 — DQ RESULTS
-- All DI check results — auto-derived and configured.
-- Written by harmonisation engine (auto-derived) and DI framework (configured).
-- External DQ tool reads this for alerting, dashboarding, and workflow.
-- UDM owns the schema and write contract only — not the alerting logic.
-- Partitioned monthly.
--
-- movement_point: where in the pipeline was the check run?
--   STAGE_TO_VS   staging → vendor stack (auto-derived checks fire here)
--   VS_TO_ARB     vendor stack → arbitration (consistency, value checks)
--   ARB_TO_DIST   arbitration → distribution (completeness checks)
-- =============================================================================

CREATE TABLE udm_dq_results (
    result_id           VARCHAR2(30)    NOT NULL,
    -- Format: DQR-YYYYMMDD-NNNNN
    lineage_id          VARCHAR2(30)    NOT NULL,
    rule_id             VARCHAR2(20),
    -- NULL for AUTO_DERIVED checks — those derive from attribute_map
    check_type          VARCHAR2(30)    NOT NULL,
    check_source        VARCHAR2(20)    NOT NULL,
    -- AUTO_DERIVED | CONFIGURED
    domain_id           VARCHAR2(50)    NOT NULL,
    source_id           VARCHAR2(20),
    metric_name         VARCHAR2(128),
    movement_point      VARCHAR2(20)    NOT NULL,
    check_result        VARCHAR2(10)    NOT NULL,
    -- PASS | FAIL | WARNING
    actual_value        NUMBER,
    expected_value      NUMBER,
    -- threshold or bound evaluated against actual_value
    entity_key          VARCHAR2(20),
    -- populated for row-level failures (BOUNDS, DRIFT per entity)
    -- NULL for batch-level checks (COMPLETENESS)
    coverage_period     VARCHAR2(20),
    action_taken        VARCHAR2(20)    NOT NULL,
    -- ALERT | QUARANTINE | REJECT | NONE
    checked_at          DATE            DEFAULT SYSDATE NOT NULL,
    --
    CONSTRAINT pk_udm_dq_results
        PRIMARY KEY (result_id),
    CONSTRAINT fk_dqresult_lineage
        FOREIGN KEY (lineage_id) REFERENCES udm_lineage (lineage_id),
    CONSTRAINT chk_dqresult_check_source
        CHECK (check_source IN ('AUTO_DERIVED','CONFIGURED')),
    CONSTRAINT chk_dqresult_movement
        CHECK (movement_point IN ('STAGE_TO_VS','VS_TO_ARB','ARB_TO_DIST')),
    CONSTRAINT chk_dqresult_result
        CHECK (check_result IN ('PASS','FAIL','WARNING')),
    CONSTRAINT chk_dqresult_action
        CHECK (action_taken IN ('ALERT','QUARANTINE','REJECT','NONE'))
)
PARTITION BY RANGE (checked_at)
INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
(
    PARTITION p_dqresult_initial VALUES LESS THAN (DATE '2024-01-01')
);

CREATE INDEX idx_dqresult_lineage
    ON udm_dq_results (lineage_id) LOCAL;
CREATE INDEX idx_dqresult_domain_period
    ON udm_dq_results (domain_id, coverage_period, check_result) LOCAL;
CREATE INDEX idx_dqresult_failures
    ON udm_dq_results (check_result, domain_id, checked_at) LOCAL;

COMMENT ON TABLE  udm_dq_results IS
    'All DI check results. External DQ tool reads for alerting. '
    'UDM owns schema and write contract only.';
COMMENT ON COLUMN udm_dq_results.rule_id IS
    'NULL for AUTO_DERIVED checks — those derive from udm_attribute_map.';


-- =============================================================================
-- SECTION 19 — DETECTION SUPPRESSIONS
-- Carries negative PO decisions through the release pipeline.
-- Prevents the same question being asked twice across environments.
-- Structural suppressions: originate in DEV/TEST, travel to all environments.
-- EAV suppressions: originate in any lane, travel per lane promotion rules.
-- =============================================================================

CREATE TABLE udm_detection_suppressions (
    suppression_id      VARCHAR2(20)    NOT NULL,
    suppression_type    VARCHAR2(30)    NOT NULL,
    -- COLUMN_IGNORE       column exists but not catalogued (noise, internal key)
    -- TABLE_NOT_APPLICABLE table found but not a UDM source (temp, audit log)
    -- EAV_VALUE_REJECTED  EAV attribute_name is noise/typo/deprecated
    -- ALREADY_MAPPED      value discovered but already in attribute_map
    source_schema       VARCHAR2(30)    NOT NULL,
    source_table        VARCHAR2(128)   NOT NULL,
    column_name         VARCHAR2(128),
    -- NULL for TABLE_NOT_APPLICABLE suppressions
    attribute_value     VARCHAR2(200),
    -- populated for EAV_VALUE_REJECTED only
    suppression_reason  VARCHAR2(100)   NOT NULL,
    -- TYPO | VENDOR_NOISE | DEPRECATED_METRIC | NOT_APPLICABLE
    -- DUPLICATE_METRIC | INTERNAL_KEY
    suppressed_by       VARCHAR2(50)    NOT NULL,
    suppressed_date     DATE            NOT NULL,
    effective_from_env  VARCHAR2(10)    NOT NULL,
    -- DEV | TEST | PROD — environment where this decision was made
    release_version     VARCHAR2(20),
    -- NULL for PROD-direct suppressions applied via Change Request
    notes               VARCHAR2(500),
    --
    CONSTRAINT pk_udm_detection_suppressions
        PRIMARY KEY (suppression_id),
    CONSTRAINT chk_suppress_type
        CHECK (suppression_type IN ('COLUMN_IGNORE','TABLE_NOT_APPLICABLE',
                                    'EAV_VALUE_REJECTED','ALREADY_MAPPED')),
    CONSTRAINT chk_suppress_env
        CHECK (effective_from_env IN ('DEV','TEST','PROD')),
    CONSTRAINT uq_suppress_natural
        UNIQUE (suppression_type, source_schema, source_table,
                column_name, attribute_value)
);

CREATE INDEX idx_suppress_table
    ON udm_detection_suppressions (source_schema, source_table);

COMMENT ON TABLE  udm_detection_suppressions IS
    'Negative PO decisions — travel via release pipeline. '
    'Prevents re-asking the same question across environments.';


-- =============================================================================
-- SECTION 20 — SEMANTIC / BI CATALOG
-- Enables catalog-driven cross-domain analytics without bespoke SQL.
-- NOT required for pipeline operation.
-- Populate per domain when a BI consumer is onboarded.
-- udm_column_lineage VIEW (not a table) should also be created here —
-- see post-DDL tasks.
-- =============================================================================

CREATE TABLE udm_metric_catalog (
    metric_id               VARCHAR2(20)    NOT NULL,
    domain_id               VARCHAR2(50)    NOT NULL,
    metric_name             VARCHAR2(200)   NOT NULL,
    -- user-facing label displayed in BI tool
    physical_table          VARCHAR2(128)   NOT NULL,
    -- udm_{domain}_arb table name
    physical_column         VARCHAR2(128)   NOT NULL,
    -- canonical column name in the arb table
    canonical_key_col       VARCHAR2(128)   NOT NULL,
    -- entity_key column name
    canonical_time_col      VARCHAR2(128)   NOT NULL,
    -- coverage_period column name
    aggregation             VARCHAR2(20)    NOT NULL,
    -- SUM | AVG | MAX | MIN | LAST | COUNT
    domain_grain            VARCHAR2(100)   NOT NULL,
    -- human-readable grain description e.g. 'COMPANY per FISCAL_YEAR'
    is_active               CHAR(1)         DEFAULT 'Y' NOT NULL,
    --
    CONSTRAINT pk_udm_metric_catalog
        PRIMARY KEY (metric_id),
    CONSTRAINT chk_metric_aggregation
        CHECK (aggregation IN ('SUM','AVG','MAX','MIN','LAST','COUNT')),
    CONSTRAINT chk_metric_active
        CHECK (is_active IN ('Y','N'))
);

COMMENT ON TABLE udm_metric_catalog IS
    'Metric registry for catalog-driven BI. '
    'Maps user-facing metric names to physical columns in arb tables. '
    'Not required for pipeline operation.';


CREATE TABLE udm_domain_join_map (
    join_id                 VARCHAR2(20)    NOT NULL,
    domain_a                VARCHAR2(50)    NOT NULL,
    domain_b                VARCHAR2(50)    NOT NULL,
    join_type               VARCHAR2(10)    NOT NULL,
    -- INNER | LEFT | FULL
    domain_a_key            VARCHAR2(128)   NOT NULL,
    -- join column in domain_a arb table
    domain_b_key            VARCHAR2(128)   NOT NULL,
    -- join column in domain_b arb table
    domain_a_time_col       VARCHAR2(128),
    domain_b_time_col       VARCHAR2(128),
    time_alignment          VARCHAR2(20),
    -- EXACT | ROLL_UP_A | ROLL_UP_B
    grain_compatible        CHAR(1)         NOT NULL,
    -- Y = grains align directly; N = grain_compatibility consulted
    --
    CONSTRAINT pk_udm_domain_join_map
        PRIMARY KEY (join_id),
    CONSTRAINT uq_domain_join_pair
        UNIQUE (domain_a, domain_b),
    CONSTRAINT chk_join_type
        CHECK (join_type IN ('INNER','LEFT','FULL')),
    CONSTRAINT chk_join_grain_compat
        CHECK (grain_compatible IN ('Y','N'))
);

COMMENT ON TABLE udm_domain_join_map IS
    'Valid cross-domain join paths. BI tool reads to auto-generate SQL.';


CREATE TABLE udm_grain_compatibility (
    compat_id               VARCHAR2(20)    NOT NULL,
    domain_a_grain          VARCHAR2(100)   NOT NULL,
    domain_b_grain          VARCHAR2(100)   NOT NULL,
    resolution              VARCHAR2(20)    NOT NULL,
    -- EXACT | ROLL_UP_A | ROLL_UP_B
    resolution_sql          VARCHAR2(500),
    user_warning            VARCHAR2(200),
    -- surfaced in BI tool when consumer joins incompatible grains
    --
    CONSTRAINT pk_udm_grain_compatibility
        PRIMARY KEY (compat_id),
    CONSTRAINT uq_grain_compat_pair
        UNIQUE (domain_a_grain, domain_b_grain)
);

COMMENT ON TABLE udm_grain_compatibility IS
    'Grain resolution rules for cross-domain joins. '
    'user_warning surfaced in BI tool when grains differ.';


-- =============================================================================
-- SECTION 21 — VIEWS
-- Created after all base tables. Not counted in the 28-table inventory.
-- =============================================================================

-- Column lineage view — surfaces udm_attribute_map as a lineage graph.
-- Auditors query this instead of joining attribute_map + source_registry manually.
-- Answers: where does source column X end up? where did canonical column Y come from?
CREATE OR REPLACE VIEW udm_column_lineage AS
SELECT
    sr.domain_id,
    sr.vendor_id,
    sr.source_schema,
    sr.source_table,
    am.source_attribute             AS source_column,
    -- NULL for is_derived=Y rows; the canonical_name IS the column in that case
    am.canonical_name               AS canonical_column,
    am.is_derived,
    am.metric_group,
    am.transform_rule,
    am.unit_from,
    am.unit_from_eav_key,
    am.unit_to,
    am.is_subject_key,
    am.is_time_key,
    am.is_mandatory,
    am.map_status,
    sr.governance_status            AS source_status,
    sr.physical_target              AS target_stack_table,
    sr.domain_grain,
    am.effective_from,
    am.effective_to
FROM    udm_attribute_map       am
JOIN    udm_source_registry     sr  ON sr.source_id = am.source_id
WHERE   am.map_status IN ('ACTIVE','PENDING_RETIREMENT');

COMMENT ON TABLE udm_column_lineage IS
    'Column-level lineage view. Surfaces udm_attribute_map as a lineage graph. '
    'Auditors use this to answer: where does source column X end up? '
    'And: where did canonical column Y come from? '
    'No additional table needed — attribute_map IS the column lineage.';


-- =============================================================================
-- SECTION 22 — ROLE-BASED GRANTS
-- Four roles cover all access patterns.
-- Adjust role names to match your Oracle security model.
-- Add grants to udm_consumer_role for each udm_{domain}_arb table created.
-- =============================================================================

-- udm_engine_role: harmonisation + arbitration + DI engine service accounts
-- GRANT SELECT         ON udm_source_system            TO udm_engine_role;
-- GRANT SELECT         ON udm_source_registry          TO udm_engine_role;
-- GRANT SELECT         ON udm_attribute_map            TO udm_engine_role;
-- GRANT SELECT         ON udm_transform_rules          TO udm_engine_role;
-- GRANT SELECT         ON udm_precedence_rules         TO udm_engine_role;
-- GRANT SELECT         ON udm_grain_alignment_rules    TO udm_engine_role;
-- GRANT SELECT         ON udm_dq_rules                 TO udm_engine_role;
-- GRANT SELECT         ON udm_entity_registry          TO udm_engine_role;
-- GRANT SELECT         ON udm_company_xref             TO udm_engine_role;
-- GRANT SELECT         ON udm_entity_membership        TO udm_engine_role;
-- GRANT SELECT         ON udm_ref_source_map           TO udm_engine_role;
-- GRANT SELECT         ON udm_ref_company              TO udm_engine_role;
-- GRANT SELECT         ON udm_ref_sector               TO udm_engine_role;
-- GRANT SELECT         ON udm_ref_region               TO udm_engine_role;
-- GRANT SELECT         ON udm_ref_country              TO udm_engine_role;
-- GRANT SELECT         ON udm_ref_time                 TO udm_engine_role;
-- GRANT SELECT         ON udm_delivery_manifest        TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_entity_registry          TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_entity_membership        TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_company              TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_counterparty         TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_supplier             TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_sector               TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_region               TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_country              TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_product              TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_time                 TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_delivery_manifest        TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_lineage                  TO udm_engine_role;
-- GRANT INSERT         ON udm_quarantine               TO udm_engine_role;
-- GRANT INSERT         ON udm_dq_results               TO udm_engine_role;

-- udm_catalog_admin_role: PO and architecture team — catalog DML via change request
-- GRANT SELECT, INSERT, UPDATE ON udm_source_system            TO udm_catalog_admin_role;
-- GRANT SELECT, INSERT, UPDATE ON udm_source_registry          TO udm_catalog_admin_role;
-- GRANT SELECT, INSERT, UPDATE ON udm_attribute_map            TO udm_catalog_admin_role;
-- GRANT SELECT, INSERT, UPDATE ON udm_transform_rules          TO udm_catalog_admin_role;
-- GRANT SELECT, INSERT, UPDATE ON udm_precedence_rules         TO udm_catalog_admin_role;
-- GRANT SELECT, INSERT, UPDATE ON udm_grain_alignment_rules    TO udm_catalog_admin_role;
-- GRANT SELECT, INSERT, UPDATE ON udm_dq_rules                 TO udm_catalog_admin_role;
-- GRANT SELECT, INSERT, UPDATE ON udm_ref_source_map           TO udm_catalog_admin_role;
-- GRANT SELECT, INSERT, UPDATE ON udm_detection_suppressions   TO udm_catalog_admin_role;
-- GRANT UPDATE                 ON udm_quarantine               TO udm_catalog_admin_role;
-- (resolved_flag, resolved_at, resolved_by, resolution_notes only)

-- udm_ref_reader: consumers needing reference data only (no domain data)
-- GRANT SELECT ON udm_ref_company        TO udm_ref_reader;
-- GRANT SELECT ON udm_ref_counterparty   TO udm_ref_reader;
-- GRANT SELECT ON udm_ref_supplier       TO udm_ref_reader;
-- GRANT SELECT ON udm_ref_sector         TO udm_ref_reader;
-- GRANT SELECT ON udm_ref_region         TO udm_ref_reader;
-- GRANT SELECT ON udm_ref_country        TO udm_ref_reader;
-- GRANT SELECT ON udm_ref_product        TO udm_ref_reader;
-- GRANT SELECT ON udm_ref_time           TO udm_ref_reader;
-- GRANT SELECT ON udm_column_lineage     TO udm_ref_reader;

-- udm_consumer_role: distribution layer + downstream applications
-- GRANT SELECT ON udm_metric_catalog      TO udm_consumer_role;
-- GRANT SELECT ON udm_domain_join_map     TO udm_consumer_role;
-- GRANT SELECT ON udm_grain_compatibility TO udm_consumer_role;
-- GRANT SELECT ON udm_column_lineage      TO udm_consumer_role;
-- (add SELECT on each udm_{domain}_arb and udm_{domain}_stk as created)

-- udm_dq_tool_role: external DQ tool service account
-- GRANT SELECT ON udm_dq_results  TO udm_dq_tool_role;
-- GRANT SELECT ON udm_lineage     TO udm_dq_tool_role;
-- GRANT SELECT ON udm_quarantine  TO udm_dq_tool_role;


-- =============================================================================
-- END — UDM TIER 1 DDL COMPLETE FINAL v4
-- ─────────────────────────────────────────────────────────────────────────────
-- OBJECT COUNTS
--   Sequences : 28
--   Tables    : 28
--   Views     : 1  (udm_column_lineage)
-- ─────────────────────────────────────────────────────────────────────────────
-- TABLE CREATION ORDER
--   CATALOG    : 01-07  source_system, source_registry, attribute_map,
--                       transform_rules, precedence_rules,
--                       grain_alignment_rules, dq_rules
--   ENTITY     : 08-12  entity_registry, company_xref, entity_membership,
--                       spatial_asset_registry
--   ROUTING    : 12     ref_source_map
--   REFERENCE  : 13-20  ref_company, ref_counterparty, ref_supplier,
--                       ref_sector, ref_region, ref_country,
--                       ref_product, ref_time
--   PIPELINE   : 21-25  delivery_manifest, lineage, quarantine,
--                       dq_results, detection_suppressions
--   SEMANTIC   : 26-28  metric_catalog, domain_join_map, grain_compatibility
--   VIEWS      :        column_lineage
-- ─────────────────────────────────────────────────────────────────────────────
-- NOT IN TIER 1 (created at domain onboarding — Module 10)
--   udm_company_sector_mv    materialised view; created when first
--                            COMPANY_SECTOR domain goes live
--   udm_{domain}_stk         vendor stack — one per domain
--   udm_{domain}_arb         arbitration — one per domain
-- ─────────────────────────────────────────────────────────────────────────────
-- NOT IN TIER 1 (created by detection layer — Module 2)
--   dsc_*                    10 detection layer tables
-- ─────────────────────────────────────────────────────────────────────────────
-- POST-DDL DATA TASKS (mandatory before engine work begins)
--   1.  Seed udm_source_system       from DW.src_sys_dim (REFERENCE_SOURCE)
--   2.  Register all Option A sources in udm_source_registry
--   3.  Extract precedence rules from Option A stored proc → udm_precedence_rules
--   4.  REFERENCE_SOURCE loads with creates_entity=Y:
--       udm_ref_sector   + entity_registry SECTOR rows (side effect)
--       udm_ref_region   + entity_registry REGION rows (side effect)
--       udm_ref_country  + entity_registry COUNTRY rows (side effect)
--       udm_ref_company  + entity_registry COMPANY rows (side effect)
--   5.  Load udm_company_xref from external MDM process
--       (must be done BEFORE first vendor DATA_SOURCE fact load)
--   6.  Seed udm_ref_time for all coverage periods in current data estate
--   7.  Run first DATA_SOURCE fact load
--       → COMPANY_SECTOR entities auto-created by derive_cs: transform
-- =============================================================================
