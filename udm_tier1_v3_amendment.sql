-- =============================================================================
-- UDM TIER 1 DDL — v3 AMENDMENT
-- Apply on top of udm_tier1_final_v2.sql
-- Version : 3.0
-- Session : 7
-- =============================================================================
--
-- CHANGE SUMMARY FROM v2
-- ─────────────────────────────────────────────────────────────────────────────
--  NEW    udm_source_system       governed source system catalog
--  DROP   udm_identity_source_map no longer needed
--  RENAME udm_entity_xref         → udm_company_xref (MDM-maintained, engine reads)
--  MODIFY udm_source_registry     source_role CHECK: IDENTITY_SOURCE removed
--                                 vendor_id FK → udm_source_system
--  MODIFY udm_entity_registry     + source_key VARCHAR2(100) (original source PK)
--  MODIFY udm_entity_seq          START WITH 1000000 (avoid collision with source PKs)
--  MODIFY udm_ref_source_map      + creates_entity CHAR(1)
--                                 + entity_type    VARCHAR2(20)
--                                 vendor_id FK → udm_source_system (removed —
--                                   udm_ref_source_map does not carry vendor_id)
--  MODIFY udm_ref_company         entity_key FK removed; source_key replaces entity_key
--  MODIFY udm_ref_counterparty    entity_key FK removed; source_key added
--  MODIFY udm_ref_supplier        entity_key FK removed; source_key added
--  MODIFY udm_ref_sector          entity_key FK removed; natural key only
--  MODIFY udm_ref_region          entity_key FK removed; natural key only
--  MODIFY udm_ref_country         entity_key FK removed; natural key only
--  MODIFY udm_company_xref        vendor_id FK → udm_source_system
-- ─────────────────────────────────────────────────────────────────────────────
-- EXECUTION ORDER
--   1. Drop dependent objects first (in reverse dependency order)
--   2. Create new objects
--   3. Alter existing objects
--   Run in a single transaction where possible.
-- =============================================================================


-- =============================================================================
-- STEP 1 — DROP OBJECTS NO LONGER NEEDED
-- =============================================================================

-- Drop udm_identity_source_map (no longer needed — entity creation is a
-- side effect of REFERENCE_SOURCE load via creates_entity on udm_ref_source_map)
DROP TABLE udm_identity_source_map;
DROP SEQUENCE udm_id_map_seq;


-- =============================================================================
-- STEP 2 — NEW SEQUENCE FOR udm_source_system
-- =============================================================================

CREATE SEQUENCE udm_src_sys_seq  START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- Rebuild entity sequence starting at 1000000
-- This prevents collision between UDM-generated entity_keys and any
-- source system PKs which are typically small integers.
-- NOTE: Only drop and recreate if udm_entity_registry is empty.
-- If it already has rows, set the new start value to MAX(entity_key) + 1.
DROP SEQUENCE udm_entity_seq;
CREATE SEQUENCE udm_entity_seq START WITH 1000000 INCREMENT BY 1 NOCACHE NOCYCLE;


-- =============================================================================
-- STEP 3 — NEW TABLE: udm_source_system
-- Governed source system catalog. Seeded from DW.src_sys_dim via REFERENCE_SOURCE.
-- Must be created BEFORE altering vendor_id FKs on other tables.
-- vendor_id throughout UDM matches source_system_cd here.
-- =============================================================================

CREATE TABLE udm_source_system (
    source_system_cd    VARCHAR2(50)    NOT NULL,
    -- PK. Matches vendor_id throughout all UDM tables.
    -- Values must match those in DW.src_sys_dim.source_system_cd.
    source_system_name  VARCHAR2(200)   NOT NULL,
    source_system_type  VARCHAR2(30)    NOT NULL,
    -- VENDOR    : external data vendor
    -- INTERNAL  : internal operational system
    -- RDM       : internal reference data master (RDM schema)
    -- UDM_DERIVED : data derived within UDM itself
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
        CHECK (source_system_type IN ('VENDOR', 'INTERNAL', 'RDM', 'UDM_DERIVED')),
    CONSTRAINT chk_src_sys_active
        CHECK (is_active IN ('Y', 'N'))
);

CREATE INDEX idx_src_sys_type_active
    ON udm_source_system (source_system_type, is_active);

COMMENT ON TABLE  udm_source_system IS
    'Governed source system catalog. Seeded from DW.src_sys_dim via REFERENCE_SOURCE load. '
    'vendor_id throughout all UDM tables FKs to source_system_cd here. '
    'Unknown source systems cannot be registered in udm_source_registry.';
COMMENT ON COLUMN udm_source_system.source_system_cd IS
    'Matches vendor_id in udm_source_registry, udm_company_xref, udm_lineage etc.';


-- =============================================================================
-- STEP 4 — RENAME udm_entity_xref → udm_company_xref
-- AND add vendor_id FK to udm_source_system
-- udm_company_xref is maintained by an external MDM process.
-- UDM engine reads it — does not build or maintain it.
-- =============================================================================

-- Oracle does not support RENAME TABLE in all versions.
-- Use: CREATE TABLE ... AS SELECT ... then DROP, or ALTER TABLE RENAME.
-- Using ALTER TABLE RENAME (Oracle 10g+):
ALTER TABLE udm_entity_xref RENAME TO udm_company_xref;

-- Add FK to udm_source_system once it exists
ALTER TABLE udm_company_xref
    ADD CONSTRAINT fk_co_xref_src_sys
        FOREIGN KEY (vendor_id) REFERENCES udm_source_system (source_system_cd);

COMMENT ON TABLE  udm_company_xref IS
    'Maps vendor-specific company identifiers to UDM entity_key. '
    'Maintained by external MDM process — UDM engine reads only. '
    'Must be pre-populated before first vendor DATA_SOURCE fact load.';
COMMENT ON COLUMN udm_company_xref.vendor_id IS
    'Matches source_system_cd in udm_source_system.';
COMMENT ON COLUMN udm_company_xref.external_id IS
    'The vendor''s raw identifier for this company entity.';


-- =============================================================================
-- STEP 5 — ALTER udm_source_registry
-- 1. Update source_role CHECK — remove IDENTITY_SOURCE
-- 2. Add FK from vendor_id to udm_source_system
-- =============================================================================

-- Drop existing source_role constraint (name from v2 DDL)
ALTER TABLE udm_source_registry
    DROP CONSTRAINT chk_source_role;

-- Recreate with two values only
ALTER TABLE udm_source_registry
    ADD CONSTRAINT chk_source_role
        CHECK (source_role IN ('DATA_SOURCE', 'REFERENCE_SOURCE'));

-- Add FK from vendor_id to udm_source_system
-- NOTE: Populate udm_source_system BEFORE enabling this constraint.
--       Disable the constraint if running migration scripts on existing data:
--       ALTER TABLE udm_source_registry DISABLE CONSTRAINT fk_src_reg_src_sys;
ALTER TABLE udm_source_registry
    ADD CONSTRAINT fk_src_reg_src_sys
        FOREIGN KEY (vendor_id) REFERENCES udm_source_system (source_system_cd);

COMMENT ON COLUMN udm_source_registry.source_role IS
    'ENGINE ROUTING: DATA_SOURCE → vendor stack + arbitration. '
    'REFERENCE_SOURCE → udm_ref_* tables. '
    'If creates_entity=Y on udm_ref_source_map → also seeds udm_entity_registry. '
    'IDENTITY_SOURCE removed — entity creation is a side effect of REFERENCE_SOURCE load.';


-- =============================================================================
-- STEP 6 — ALTER udm_entity_registry
-- Add source_key to carry original source PK (e.g. customer_bk from CST_DIM).
-- This is the join key back to ref tables and source systems during migration.
-- NULL for UDM-generated entities (COMPANY_SECTOR) that have no source PK.
-- =============================================================================

ALTER TABLE udm_entity_registry
    ADD source_key VARCHAR2(100);

CREATE INDEX idx_entity_reg_type_sourcekey
    ON udm_entity_registry (entity_type, source_key);

COMMENT ON COLUMN udm_entity_registry.source_key IS
    'Original source system PK (e.g. customer_bk from CST_DIM). '
    'Used as join key to udm_ref_* tables during migration. '
    'NULL for UDM-generated entities (COMPANY_SECTOR etc.). '
    'NOT the entity_key — entity_key is always UDM-owned sequence.';


-- =============================================================================
-- STEP 7 — ALTER udm_ref_source_map
-- Add creates_entity and entity_type columns.
-- When creates_entity = Y, the REFERENCE_SOURCE load also seeds
-- udm_entity_registry as a side effect.
-- =============================================================================

ALTER TABLE udm_ref_source_map
    ADD creates_entity  CHAR(1)         DEFAULT 'N' NOT NULL;

ALTER TABLE udm_ref_source_map
    ADD entity_type     VARCHAR2(20);
    -- populated when creates_entity = Y
    -- must match entity_type values on udm_entity_registry

ALTER TABLE udm_ref_source_map
    ADD CONSTRAINT chk_ref_map_creates_entity
        CHECK (creates_entity IN ('Y', 'N'));

ALTER TABLE udm_ref_source_map
    ADD CONSTRAINT chk_ref_map_entity_type
        CHECK (entity_type IS NULL OR entity_type IN
               ('COMPANY', 'SUPPLIER', 'COUNTERPARTY', 'PRODUCT',
                'SECTOR', 'REGION', 'COUNTRY', 'COMPANY_SECTOR'));

ALTER TABLE udm_ref_source_map
    ADD CONSTRAINT chk_ref_map_entity_type_required
        CHECK (creates_entity = 'N' OR entity_type IS NOT NULL);

COMMENT ON COLUMN udm_ref_source_map.creates_entity IS
    'Y = engine also seeds udm_entity_registry as side effect of this ref load. '
    'Entity creation uses source_key = natural key of the ref table. '
    'N = pure reference load only.';
COMMENT ON COLUMN udm_ref_source_map.entity_type IS
    'Required when creates_entity = Y. Written to udm_entity_registry.entity_type.';


-- =============================================================================
-- STEP 8 — REMOVE entity_key FK FROM ALL udm_ref_* TABLES
-- Ref tables use natural keys only. They are independent of udm_entity_registry.
-- A ref entry does not require an entity_registry entry.
-- Joins from entity_registry to ref tables use source_key = natural_key.
-- =============================================================================

-- udm_ref_company: remove entity_key FK, rename to source_key pattern
-- (entity_key was the FK in v2 — we replace with a plain source column)
ALTER TABLE udm_ref_company  DROP CONSTRAINT fk_ref_company_entity;
ALTER TABLE udm_ref_company  RENAME COLUMN entity_key TO company_source_key;

COMMENT ON COLUMN udm_ref_company.company_source_key IS
    'Natural key from source system (e.g. customer_bk from CST_DIM). '
    'Matches udm_entity_registry.source_key for companies. '
    'NOT a FK to entity_registry — ref table is independent.';

-- udm_ref_counterparty
ALTER TABLE udm_ref_counterparty  DROP CONSTRAINT fk_ref_cpty_entity;
ALTER TABLE udm_ref_counterparty  RENAME COLUMN entity_key TO counterparty_source_key;

-- udm_ref_supplier
ALTER TABLE udm_ref_supplier  DROP CONSTRAINT fk_ref_supplier_entity;
ALTER TABLE udm_ref_supplier  RENAME COLUMN entity_key TO supplier_source_key;

-- udm_ref_sector: remove entity_key FK. Natural key = classification_system + class_code.
ALTER TABLE udm_ref_sector  DROP CONSTRAINT fk_ref_sector_entity;
ALTER TABLE udm_ref_sector  DROP CONSTRAINT fk_ref_sector_parent;
ALTER TABLE udm_ref_sector  DROP COLUMN entity_key;
-- parent_entity_key → parent_class_code (natural key hierarchy)
ALTER TABLE udm_ref_sector  RENAME COLUMN parent_entity_key TO parent_class_code;

COMMENT ON COLUMN udm_ref_sector.parent_class_code IS
    'Natural key reference to parent sector in the same classification system. '
    'Hierarchy traversal uses classification_system + parent_class_code. '
    'No FK constraint — avoids lock contention on bulk hierarchy loads.';

-- udm_ref_region: remove entity_key FK. Natural key = region_cd.
ALTER TABLE udm_ref_region  DROP CONSTRAINT fk_ref_region_entity;
ALTER TABLE udm_ref_region  DROP CONSTRAINT fk_ref_region_parent;
ALTER TABLE udm_ref_region  DROP COLUMN entity_key;
ALTER TABLE udm_ref_region  RENAME COLUMN parent_entity_key TO parent_region_cd;

-- udm_ref_country: remove entity_key FK. Natural key = iso_country_cd.
ALTER TABLE udm_ref_country  DROP CONSTRAINT fk_ref_country_entity;
ALTER TABLE udm_ref_country  DROP CONSTRAINT fk_ref_country_region;
ALTER TABLE udm_ref_country  DROP COLUMN entity_key;
ALTER TABLE udm_ref_country  RENAME COLUMN region_entity_key TO region_cd;
-- region_cd is the natural key reference to udm_ref_region

COMMENT ON COLUMN udm_ref_country.region_cd IS
    'Natural key reference to udm_ref_region.region_cd. '
    'No FK constraint — ref tables are independent.';


-- =============================================================================
-- STEP 9 — REBUILD INDEXES ON REF TABLES (natural key lookups)
-- Drop entity_key-based indexes, rebuild on natural keys.
-- =============================================================================

-- udm_ref_company
DROP INDEX idx_ref_company_current;
CREATE INDEX idx_ref_company_sourcekey
    ON udm_ref_company (company_source_key, effective_to);

-- udm_ref_counterparty
DROP INDEX idx_ref_cpty_current;
CREATE INDEX idx_ref_cpty_sourcekey
    ON udm_ref_counterparty (counterparty_source_key, effective_to);

-- udm_ref_supplier
DROP INDEX idx_ref_supplier_current;
CREATE INDEX idx_ref_supplier_sourcekey
    ON udm_ref_supplier (supplier_source_key, effective_to);

-- udm_ref_sector (natural key = classification_system + class_code)
-- idx_ref_sector_class already correct — retained
-- idx_ref_sector_current was entity_key-based — drop and rebuild
DROP INDEX idx_ref_sector_current;
CREATE INDEX idx_ref_sector_parent
    ON udm_ref_sector (classification_system, parent_class_code);

-- udm_ref_region
DROP INDEX idx_ref_region_current;
CREATE INDEX idx_ref_region_lookup
    ON udm_ref_region (region_cd, effective_to);

-- udm_ref_country
DROP INDEX idx_ref_country_current;
CREATE INDEX idx_ref_country_lookup
    ON udm_ref_country (iso_country_cd, effective_to);
CREATE INDEX idx_ref_country_region
    ON udm_ref_country (region_cd);


-- =============================================================================
-- STEP 10 — EXAMPLE SEED DATA PATTERN
-- Shows how to register DW.src_sys_dim as REFERENCE_SOURCE
-- and CST_DIM as REFERENCE_SOURCE with creates_entity = Y.
-- (Uncomment and adjust to match your actual source system codes and columns.)
-- =============================================================================

/*
-- Register DW.src_sys_dim as REFERENCE_SOURCE feeding udm_source_system
INSERT INTO udm_source_registry (
    source_id, vendor_id, domain_id, source_schema, source_table,
    source_format, currency_mechanism,
    entity_id_col, time_col,
    storage_pattern, physical_target,
    source_role, subject_type, domain_grain,
    governance_status, effective_from, created_by
) VALUES (
    'SRC-00001', 'INT_RDM', 'REFERENCE', 'DW', 'SRC_SYS_DIM',
    'COLUMNAR', 'ALWAYS_CURRENT',
    'SOURCE_SYSTEM_CD', 'LOAD_DATE',
    'MATERIALISED', 'udm_source_system',
    'REFERENCE_SOURCE', 'INTERNAL_ID', NULL,
    'RDM_ONLY', DATE '2024-01-01', 'SYSTEM'
);

INSERT INTO udm_ref_source_map (
    ref_map_id, source_id, ref_table_name, refresh_strategy,
    ref_natural_key_cols, creates_entity, entity_type,
    is_active, effective_from, created_by
) VALUES (
    'RSM-00001', 'SRC-00001', 'udm_source_system', 'INCREMENTAL',
    'source_system_cd', 'N', NULL,
    'Y', DATE '2024-01-01', 'SYSTEM'
);

-- Register CST_DIM as REFERENCE_SOURCE with creates_entity = Y
-- Engine will seed udm_entity_registry (COMPANY) as a side effect.
INSERT INTO udm_source_registry (
    source_id, vendor_id, domain_id, source_schema, source_table,
    source_format, currency_mechanism, current_flag_column,
    entity_id_col, time_col,
    storage_pattern, physical_target,
    source_role, subject_type, domain_grain,
    governance_status, effective_from, created_by
) VALUES (
    'SRC-00002', 'INT_RDM', 'REFERENCE', 'DW', 'CST_DIM',
    'COLUMNAR', 'CURRENT_FLAG', 'IS_CURRENT_ROW',
    'CUSTOMER_BK', 'EFFECTIVE_FROM',
    'MATERIALISED', 'udm_ref_company',
    'REFERENCE_SOURCE', 'ENTITY', 'COMPANY',
    'RDM_ONLY', DATE '2024-01-01', 'SYSTEM'
);

INSERT INTO udm_ref_source_map (
    ref_map_id, source_id, ref_table_name, refresh_strategy,
    ref_natural_key_cols, creates_entity, entity_type,
    is_active, effective_from, created_by
) VALUES (
    'RSM-00002', 'SRC-00002', 'udm_ref_company', 'EFFECTIVE_DATE_MERGE',
    'company_source_key', 'Y', 'COMPANY',
    'Y', DATE '2024-01-01', 'SYSTEM'
);
*/


-- =============================================================================
-- END OF v3 AMENDMENT
-- ─────────────────────────────────────────────────────────────────────────────
-- TABLES AFTER AMENDMENT (27 tables)
-- ─────────────────────────────────────────────────────────────────────────────
--   CATALOG  : udm_source_system (NEW), udm_source_registry, udm_attribute_map,
--              udm_transform_rules, udm_precedence_rules, udm_grain_alignment_rules,
--              udm_dq_rules
--   ENTITY   : udm_entity_registry (+source_key), udm_company_xref (renamed),
--              udm_entity_membership, udm_spatial_asset_registry
--   ROUTING  : udm_ref_source_map (+creates_entity, +entity_type)
--              udm_identity_source_map DROPPED
--   REFERENCE: udm_ref_company (natural key), udm_ref_counterparty (natural key),
--              udm_ref_supplier (natural key), udm_ref_sector (natural key),
--              udm_ref_region (natural key), udm_ref_country (natural key),
--              udm_ref_product, udm_ref_time
--   PIPELINE : udm_delivery_manifest, udm_lineage, udm_quarantine,
--              udm_dq_results, udm_detection_suppressions
--   SEMANTIC : udm_metric_catalog, udm_domain_join_map, udm_grain_compatibility
-- ─────────────────────────────────────────────────────────────────────────────
-- SEQUENCES AFTER AMENDMENT (27 sequences — udm_id_map_seq dropped)
--   udm_src_sys_seq (NEW)
--   udm_entity_seq  (RECREATED — starts at 1000000)
--   all others unchanged from v2
-- ─────────────────────────────────────────────────────────────────────────────
-- POST-AMENDMENT DATA TASKS (before engine work begins)
--   1.  Seed udm_source_system from DW.src_sys_dim
--   2.  Register all Option A sources in udm_source_registry
--   3.  Extract precedence rules from Option A stored proc → udm_precedence_rules
--   4.  REFERENCE_SOURCE loads (creates_entity=Y):
--       udm_ref_sector   → entity_registry SECTOR rows created as side effect
--       udm_ref_region   → entity_registry REGION rows created as side effect
--       udm_ref_country  → entity_registry COUNTRY rows created as side effect
--       udm_ref_company  → entity_registry COMPANY rows created as side effect
--   5.  Load udm_company_xref from external MDM process (pre-populated)
--   6.  Seed udm_ref_time for all coverage periods
--   7.  Run first DATA_SOURCE fact load
--       → COMPANY_SECTOR entities auto-created by derive_cs: at step 7
-- =============================================================================
