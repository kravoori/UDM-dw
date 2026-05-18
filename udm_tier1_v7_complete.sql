-- =============================================================================
-- UDM TIER 1 DDL — COMPLETE FINAL v7
-- Schema  : UDM
-- Version : 7.0
-- =============================================================================
--
-- OBJECT INVENTORY
-- ─────────────────────────────────────────────────────────────────────────────
-- 33 tables, 33 sequences, 2 views
--
-- CATALOG
--   01 udm_source_system
--   02 udm_source_registry
--   03 udm_data_item              SCD2 — metric registry, one physical home
--   04 udm_data_item_taxonomy     axis+node classification, drives view generation
--   05 udm_data_item_src_map      source mapping, one row per (data item × source)
--   06 udm_transform_rules        named SQL for rule_ref: transforms
--   07 udm_precedence_rules       ★ EXTENDED — entity_scope, period_scope, rule_label
--   08 udm_grain_alignment_rules
--   09 udm_dq_rules
--
-- ENTITY RESOLUTION
--   10 udm_entity_registry
--   11 udm_company_xref           MDM-maintained, UDM reads only
--   12 udm_entity_membership
--   13 udm_spatial_asset_registry
--
-- SOURCE ROUTING
--   14 udm_ref_source_map
--
-- REFERENCE TABLES (natural keys only)
--   15 udm_ref_company
--   16 udm_ref_counterparty
--   17 udm_ref_supplier
--   18 udm_ref_sector
--   19 udm_ref_region
--   20 udm_ref_country
--   21 udm_ref_product
--   22 udm_ref_time
--
-- PIPELINE SUPPORT
--   23 udm_delivery_manifest
--   24 udm_lineage                partitioned monthly
--   25 udm_quarantine             partitioned monthly
--   26 udm_dq_results             partitioned monthly
--   27 udm_detection_suppressions
--
-- ARBITRATION SUPPORT (★ NEW in v7)
--   28 udm_arb_review_queue       unresolved arbitration cases for PO review
--
-- SEMANTIC / BI CATALOG
--   29 udm_metric_catalog
--   30 udm_domain_join_map
--   31 udm_grain_compatibility
--
-- ARBITRATION GTTs (★ NEW in v7 — session-scoped, ON COMMIT DELETE ROWS)
--   32 udm_arb_candidates_gtt     all qualified candidates for current arb run
--   33 udm_arb_resolved_gtt       one winner per entity per metric after ranking
--
-- VIEWS
--   udm_data_item_lineage         column lineage — data item + source map
--   udm_arb_waterfall_v           ★ NEW — human-readable waterfall rule display
--
-- ─────────────────────────────────────────────────────────────────────────────
-- KEY CHANGES FROM v6
--
--   udm_precedence_rules EXTENDED (3 new columns):
--     entity_scope  VARCHAR2(15) DEFAULT 'CLIENT' — CLIENT | PARENT
--     period_scope  VARCHAR2(15) DEFAULT 'CURRENT' — CURRENT | PRIOR_YEAR
--     rule_label    VARCHAR2(200) — human-readable label stamped on arb row
--   These three columns replace the dropped udm_arb_waterfall_rule table.
--   One table governs all three precedence modes:
--     SIMPLE:        entity_scope=CLIENT, period_scope=CURRENT (default)
--     METRIC GROUP:  mtrc_grp_tx IS NOT NULL — group-level override
--     ENTITY SCOPE:  entity_scope=PARENT and/or period_scope=PRIOR_YEAR
--
--   udm_arb_review_queue NEW:
--     Captures unresolved arbitration cases (all waterfall levels exhausted).
--     PO reviews and either resolves (triggers reprocessing) or suppresses.
--
--   udm_arb_candidates_gtt NEW (GTT):
--     Staged candidates for current arbitration run. ON COMMIT DELETE ROWS.
--
--   udm_arb_resolved_gtt NEW (GTT):
--     One winner per entity per metric after ROW_NUMBER ranking.
--     ON COMMIT DELETE ROWS.
--
--   udm_arb_waterfall_v NEW (VIEW):
--     Joins udm_precedence_rules to udm_data_item for human-readable display
--     of the full waterfall configuration for any domain.
--
--   udm_review_seq NEW:
--     Sequence for udm_arb_review_queue primary keys.
-- =============================================================================


-- =============================================================================
-- SECTION 1 — SEQUENCES (33 total)
-- =============================================================================

CREATE SEQUENCE udm_src_sys_seq       START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_source_seq        START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_data_itm_scd2_seq START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_data_itm_scd1_seq START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_di_tax_seq        START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_di_src_map_seq    START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_transform_seq     START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_prec_rule_seq     START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_grain_rule_seq    START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_dq_rule_seq       START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_entity_seq        START WITH 1000000 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_co_xref_seq       START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_membership_seq    START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_spatial_seq       START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_map_seq       START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_co_seq        START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_cpty_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_sup_seq       START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_sec_seq       START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_reg_seq       START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_cty_seq       START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_prod_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_ref_time_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_manifest_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_lineage_seq       START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_quarantine_seq    START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_dq_result_seq     START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_suppress_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_review_seq        START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
-- ★ NEW — for udm_arb_review_queue primary keys
CREATE SEQUENCE udm_metric_seq        START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_join_map_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_grain_compat_seq  START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;


-- =============================================================================
-- SECTION 2 — SOURCE SYSTEM CATALOG
-- =============================================================================

CREATE TABLE udm_source_system (
    source_system_cd    VARCHAR2(50)    NOT NULL,
    source_system_name  VARCHAR2(200)   NOT NULL,
    source_system_type  VARCHAR2(20)    NOT NULL,
    owner_team          VARCHAR2(100),
    data_domain         VARCHAR2(100),
    is_active           CHAR(1)         DEFAULT 'Y' NOT NULL,
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_source_system  PRIMARY KEY (source_system_cd),
    CONSTRAINT chk_src_sys_type      CHECK (source_system_type IN ('VENDOR','INTERNAL','RDM','UDM_DERIVED')),
    CONSTRAINT chk_src_sys_active    CHECK (is_active IN ('Y','N'))
);
CREATE INDEX idx_src_sys_type ON udm_source_system (source_system_type, is_active);
COMMENT ON TABLE  udm_source_system IS 'Governed source system catalog. vendor_id throughout UDM FKs here.';
COMMENT ON COLUMN udm_source_system.source_system_cd IS 'Matches vendor_id in all UDM tables.';


-- =============================================================================
-- SECTION 3 — SOURCE REGISTRY
-- =============================================================================

CREATE TABLE udm_source_registry (
    source_id                   VARCHAR2(20)    NOT NULL,
    vendor_id                   VARCHAR2(50)    NOT NULL,
    domain_id                   VARCHAR2(50)    NOT NULL,
    sub_domain_id               VARCHAR2(50),
    source_schema               VARCHAR2(30)    NOT NULL,
    source_table                VARCHAR2(128)   NOT NULL,
    source_format               VARCHAR2(20)    NOT NULL,
    currency_mechanism          VARCHAR2(20)    NOT NULL,
    current_flag_column         VARCHAR2(128),
    effective_to_column         VARCHAR2(128),
    time_key_column             VARCHAR2(128),
    entity_id_col               VARCHAR2(128)   NOT NULL,
    time_col                    VARCHAR2(128)   NOT NULL,
    storage_pattern             VARCHAR2(20)    NOT NULL,
    source_role                 VARCHAR2(20)    DEFAULT 'DATA_SOURCE' NOT NULL,
    subject_type                VARCHAR2(20)    DEFAULT 'ENTITY'      NOT NULL,
    domain_grain                VARCHAR2(100),
    governance_status           VARCHAR2(20)    NOT NULL,
    superseded_by_source_id     VARCHAR2(20),
    effective_from              DATE            NOT NULL,
    effective_to                DATE,
    created_by                  VARCHAR2(50)    NOT NULL,
    created_date                DATE            DEFAULT SYSDATE NOT NULL,
    modified_by                 VARCHAR2(50),
    modified_date               DATE,
    notes                       VARCHAR2(500),
    CONSTRAINT pk_udm_source_registry      PRIMARY KEY (source_id),
    CONSTRAINT fk_src_reg_src_sys          FOREIGN KEY (vendor_id) REFERENCES udm_source_system (source_system_cd),
    CONSTRAINT fk_source_superseded_by     FOREIGN KEY (superseded_by_source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_source_registry_natural  UNIQUE (vendor_id, domain_id, sub_domain_id, source_table, effective_from),
    CONSTRAINT chk_source_format           CHECK (source_format IN ('COLUMNAR','EAV')),
    CONSTRAINT chk_currency_mechanism      CHECK (currency_mechanism IN ('CURRENT_FLAG','EFFECTIVE_DATES','MAX_SNAPSHOT_DATE','ALWAYS_CURRENT','LOAD_DATE')),
    CONSTRAINT chk_storage_pattern         CHECK (storage_pattern IN ('MATERIALISED','VIRTUAL')),
    CONSTRAINT chk_source_role             CHECK (source_role IN ('DATA_SOURCE','REFERENCE_SOURCE')),
    CONSTRAINT chk_subject_type            CHECK (subject_type IN ('ENTITY','SPATIAL','INTERNAL_ID')),
    CONSTRAINT chk_governance_status       CHECK (governance_status IN ('STAGE_ONLY','RDM_ONLY','MIGRATING','UDM_CATALOGED','DEPRECATED','RETIRED')),
    CONSTRAINT chk_superseded_retired      CHECK (superseded_by_source_id IS NULL OR governance_status = 'RETIRED'),
    CONSTRAINT chk_currency_flag_col       CHECK (currency_mechanism != 'CURRENT_FLAG'      OR current_flag_column IS NOT NULL),
    CONSTRAINT chk_currency_eff_col        CHECK (currency_mechanism != 'EFFECTIVE_DATES'   OR effective_to_column  IS NOT NULL),
    CONSTRAINT chk_currency_time_col       CHECK (currency_mechanism != 'MAX_SNAPSHOT_DATE' OR time_key_column      IS NOT NULL)
);
CREATE INDEX idx_source_reg_vendor ON udm_source_registry (vendor_id, domain_id);
CREATE INDEX idx_source_reg_gov    ON udm_source_registry (governance_status, source_role);
COMMENT ON TABLE udm_source_registry IS 'Single inventory of entire data estate. physical_target on udm_data_item.';


-- =============================================================================
-- SECTION 4 — DATA ITEM (SCD2 — metric registry)
-- =============================================================================

CREATE TABLE udm_data_item (
    data_itm_scd_2_ky       NUMBER(32)      NOT NULL,
    data_itm_scd_1_ky       NUMBER(32)      NOT NULL,
    data_itm_id             VARCHAR2(100),
    data_itm_nm             VARCHAR2(128)   NOT NULL,
    data_itm_de_tx          VARCHAR2(500),
    cncl_nm                 VARCHAR2(128),
    domn_ky                 VARCHAR2(50)    NOT NULL,
    mtrc_grp_tx             VARCHAR2(100),
    -- Matches udm_precedence_rules.mtrc_grp_tx for metric group overrides
    mtrc_txnmy_cd           VARCHAR2(128),
    mtrc_typ_cd             VARCHAR2(10),
    -- QNTT | QLTT | INDC
    phy_trgt_tbl_nm         VARCHAR2(128)   NOT NULL,
    -- ONE stack table per data item — never duplicated
    data_typ_cd             VARCHAR2(20)    NOT NULL,
    data_itm_trgt_unit_tx   VARCHAR2(50),
    is_subj_ky              VARCHAR2(1)     DEFAULT 'N' NOT NULL,
    is_time_ky              VARCHAR2(1)     DEFAULT 'N' NOT NULL,
    is_mndty_fl             VARCHAR2(1)     DEFAULT 'N' NOT NULL,
    bgn_tran_dt             DATE            NOT NULL,
    end_tran_dt             DATE            NOT NULL,
    cur_fl                  NUMBER(1)       NOT NULL,
    row_stat_cd             VARCHAR2(30)    NOT NULL,
    creat_tran_dt           DATE            NOT NULL,
    creat_usr_tx            VARCHAR2(1024)  NOT NULL,
    mod_usr_tx              VARCHAR2(1024),
    src_cd                  VARCHAR2(30),
    creat_job_run_ky        NUMBER(32),
    mod_job_run_ky          NUMBER(32),
    row_chk_sum_tx          VARCHAR2(1024)
        GENERATED ALWAYS AS (
            RAWTOHEX(STANDARD_HASH(
                data_itm_nm || '|' || domn_ky || '|' ||
                NVL(phy_trgt_tbl_nm,'') || '|' ||
                data_typ_cd || '|' || NVL(mtrc_typ_cd,''),
            'SHA256'))
        ) VIRTUAL,
    CONSTRAINT pk_udm_data_item          PRIMARY KEY (data_itm_scd_2_ky),
    CONSTRAINT uq_data_item_id           UNIQUE (data_itm_id),
    CONSTRAINT uq_data_item_nm_tgt_eff   UNIQUE (data_itm_nm, phy_trgt_tbl_nm, bgn_tran_dt),
    CONSTRAINT chk_data_typ_cd           CHECK (data_typ_cd IN ('VARCHAR','NUMBER','DATE','TIMESTAMP','BOOLEAN')),
    CONSTRAINT chk_mtrc_typ_cd           CHECK (mtrc_typ_cd IS NULL OR mtrc_typ_cd IN ('QNTT','QLTT','INDC')),
    CONSTRAINT chk_is_subj_ky            CHECK (is_subj_ky IN ('Y','N')),
    CONSTRAINT chk_is_time_ky            CHECK (is_time_ky IN ('Y','N')),
    CONSTRAINT chk_is_mndty_fl           CHECK (is_mndty_fl IN ('Y','N')),
    CONSTRAINT chk_cur_fl                CHECK (cur_fl IN (0,1)),
    CONSTRAINT chk_row_stat_cd           CHECK (row_stat_cd IN ('ACTIVE','PENDING_RETIREMENT','RETIRED'))
);
CREATE INDEX idx_data_item_scd1   ON udm_data_item (data_itm_scd_1_ky, cur_fl);
CREATE INDEX idx_data_item_domain ON udm_data_item (domn_ky, cur_fl);
CREATE INDEX idx_data_item_target ON udm_data_item (phy_trgt_tbl_nm, cur_fl);
CREATE INDEX idx_data_item_id     ON udm_data_item (data_itm_id);
COMMENT ON TABLE  udm_data_item IS 'DATA ITEM registry. SCD2. ONE physical home per item. mtrc_grp_tx matches precedence_rules.mtrc_grp_tx.';
COMMENT ON COLUMN udm_data_item.data_itm_scd_1_ky IS 'Concept identity. All child FKs use this (logical — SCD2 not unique per row).';
COMMENT ON COLUMN udm_data_item.data_itm_id IS 'Business code for display/API only. NOT a FK target anywhere.';
COMMENT ON COLUMN udm_data_item.mtrc_grp_tx IS 'Matches udm_precedence_rules.mtrc_grp_tx. Enables metric group overrides in arbitration.';
COMMENT ON COLUMN udm_data_item.row_chk_sum_tx IS 'Virtual. Change detection hash. Zero storage cost.';


-- =============================================================================
-- SECTION 5 — DATA ITEM TAXONOMY
-- =============================================================================

CREATE TABLE udm_data_item_taxonomy (
    taxonomy_id             NUMBER(32)      NOT NULL,
    data_itm_scd_1_ky       NUMBER(32)      NOT NULL,
    -- LOGICAL FK → udm_data_item.data_itm_scd_1_ky (SCD2 — not physical)
    axis                    VARCHAR2(20)    NOT NULL,
    node                    VARCHAR2(100)   NOT NULL,
    display_order           NUMBER(3),
    creat_usr_tx            VARCHAR2(1024)  NOT NULL,
    creat_tran_dt           DATE            NOT NULL,
    CONSTRAINT pk_udm_data_item_taxonomy   PRIMARY KEY (taxonomy_id),
    CONSTRAINT uq_taxonomy_item_axis_node  UNIQUE (data_itm_scd_1_ky, axis, node),
    CONSTRAINT chk_taxonomy_axis           CHECK (axis IN ('DOMAIN','SUB_DOMAIN','THEME','SCOPE','CATEGORY','METRIC_TYPE'))
);
CREATE INDEX idx_di_tax_scd1      ON udm_data_item_taxonomy (data_itm_scd_1_ky, axis);
CREATE INDEX idx_di_tax_axis_node ON udm_data_item_taxonomy (axis, node);
CREATE INDEX idx_di_tax_node      ON udm_data_item_taxonomy (node, axis, data_itm_scd_1_ky);
COMMENT ON TABLE udm_data_item_taxonomy IS 'Axis+node per data item. Logical FK to SCD1_KY. Drives VIEW generation — not physical writes.';


-- =============================================================================
-- SECTION 6 — DATA ITEM SOURCE MAP
-- =============================================================================

CREATE TABLE udm_data_item_src_map (
    map_id                  NUMBER(32)      NOT NULL,
    data_itm_scd_1_ky       NUMBER(32)      NOT NULL,
    -- LOGICAL FK → udm_data_item.data_itm_scd_1_ky (SCD2 — not physical)
    source_id               VARCHAR2(20),
    attr_src_nm             VARCHAR2(128),
    is_derived_fl           VARCHAR2(1)     DEFAULT 'N' NOT NULL,
    attr_xfrm_ru_tx         VARCHAR2(200),
    attr_unit_from_tx       VARCHAR2(140),
    attr_unit_eav_ky        VARCHAR2(200),
    attr_nm_col_tx          VARCHAR2(128),
    attr_nm_val_tx          VARCHAR2(200),
    attr_val_col_tx         VARCHAR2(128),
    attr_val_typ_cd         VARCHAR2(20),
    map_stat_cd             VARCHAR2(30)    DEFAULT 'ACTIVE' NOT NULL,
    bgn_tran_dt             DATE            NOT NULL,
    end_tran_dt             DATE,
    creat_usr_tx            VARCHAR2(1024)  NOT NULL,
    creat_tran_dt           DATE            NOT NULL,
    mod_usr_tx              VARCHAR2(1024),
    CONSTRAINT pk_udm_data_item_src_map  PRIMARY KEY (map_id),
    CONSTRAINT fk_di_src_map_source      FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_di_src_map_natural     UNIQUE (data_itm_scd_1_ky, source_id, bgn_tran_dt),
    CONSTRAINT chk_di_src_derived_fl     CHECK (is_derived_fl IN ('Y','N')),
    CONSTRAINT chk_di_src_derived_nulls  CHECK (
        (is_derived_fl='N' AND source_id IS NOT NULL AND attr_src_nm IS NOT NULL)
        OR (is_derived_fl='Y' AND source_id IS NULL AND attr_src_nm IS NULL)
    ),
    CONSTRAINT chk_di_src_derived_rule   CHECK (
        is_derived_fl = 'N'
        OR attr_xfrm_ru_tx LIKE 'coalesce:%'
        OR attr_xfrm_ru_tx LIKE 'rule_ref:%'
        OR attr_xfrm_ru_tx LIKE 'flag:%'
        OR attr_xfrm_ru_tx LIKE 'derive_cs:%'
    ),
    CONSTRAINT chk_di_src_map_stat       CHECK (map_stat_cd IN ('ACTIVE','PENDING_RETIREMENT','RETIRED')),
    CONSTRAINT chk_di_src_eav_cols       CHECK (
        (attr_nm_col_tx IS NULL AND attr_nm_val_tx IS NULL AND attr_val_col_tx IS NULL)
        OR (attr_nm_col_tx IS NOT NULL AND attr_nm_val_tx IS NOT NULL AND attr_val_col_tx IS NOT NULL)
    ),
    CONSTRAINT chk_di_src_eav_key_eav    CHECK (attr_unit_eav_ky IS NULL OR attr_nm_col_tx IS NOT NULL),
    CONSTRAINT chk_di_src_col_prefix     CHECK (SUBSTR(attr_unit_from_tx,1,4) != 'col:' OR attr_nm_col_tx IS NULL),
    CONSTRAINT chk_di_src_unit_excl      CHECK (NOT (attr_unit_eav_ky IS NOT NULL AND SUBSTR(attr_unit_from_tx,1,4)='col:'))
);
CREATE INDEX idx_di_src_scd1   ON udm_data_item_src_map (data_itm_scd_1_ky, map_stat_cd);
CREATE INDEX idx_di_src_source ON udm_data_item_src_map (source_id, map_stat_cd);
CREATE INDEX idx_di_src_deriv  ON udm_data_item_src_map (source_id, is_derived_fl);
COMMENT ON TABLE udm_data_item_src_map IS 'Source mapping. Logical FK to SCD1_KY. is_derived_fl=N: Pass 1. Y: Pass 2.';


-- =============================================================================
-- SECTION 7 — TRANSFORM RULES
-- =============================================================================

CREATE TABLE udm_transform_rules (
    rule_id             VARCHAR2(20)    NOT NULL,
    rule_name           VARCHAR2(100)   NOT NULL,
    resolution_sql      VARCHAR2(2000)  NOT NULL,
    description         VARCHAR2(500),
    is_active           CHAR(1)         DEFAULT 'Y' NOT NULL,
    created_by          VARCHAR2(50)    NOT NULL,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    modified_by         VARCHAR2(50),
    modified_date       DATE,
    CONSTRAINT pk_udm_transform_rules  PRIMARY KEY (rule_id),
    CONSTRAINT uq_transform_rule_name  UNIQUE (rule_name),
    CONSTRAINT chk_transform_active    CHECK (is_active IN ('Y','N'))
);
COMMENT ON TABLE udm_transform_rules IS 'Named SQL for rule_ref: transforms. Rule change = one UPDATE, no code deploy.';


-- =============================================================================
-- SECTION 8 — PRECEDENCE RULES (★ EXTENDED in v7)
-- =============================================================================
-- Three new columns replace the dropped udm_arb_waterfall_rule table.
-- One table now governs all three arbitration precedence modes:
--
-- MODE 1 — SIMPLE VENDOR PRECEDENCE (default)
--   entity_scope = CLIENT  (default)
--   period_scope = CURRENT (default)
--   mtrc_grp_tx  = NULL   (applies to all metrics in domain)
--   Example: Vendor 1 priority 1, Vendor 2 priority 2 — same entity, same period.
--
-- MODE 2 — METRIC GROUP OVERRIDE
--   mtrc_grp_tx  = 'SCOPE3' (matches udm_data_item.mtrc_grp_tx)
--   entity_scope = CLIENT, period_scope = CURRENT
--   Group rules use lower priority numbers than domain rules for the same vendor.
--   Group rule wins in ROW_NUMBER ranking — no special engine branching.
--
-- MODE 3 — ENTITY SCOPE / TIME FALLBACK
--   entity_scope = PARENT      : use parent entity's stack row
--   period_scope = PRIOR_YEAR  : use prior year stack row
--   Higher priority numbers (later in waterfall) than CLIENT/CURRENT rules.
--
-- ENGINE BEHAVIOUR:
--   Arbitration engine reads ALL active rules for domain in one query.
--   ROW_NUMBER() OVER (PARTITION BY entity ORDER BY priority ASC) selects winner.
--   PARENT rules skipped when no parent exists (WHERE guard in engine).
--   PRIOR_YEAR rules skipped when prior period not in udm_ref_time.
--   NEVER DELETE rules — close with end_tran_dt on retirement.
-- =============================================================================

CREATE TABLE udm_precedence_rules (
    rule_id             VARCHAR2(20)    NOT NULL,
    domain_id           VARCHAR2(50)    NOT NULL,
    mtrc_grp_tx         VARCHAR2(100),
    -- NULL = applies to all metrics in domain
    -- Specific value (e.g. SCOPE3) = group-level override
    -- Matches udm_data_item.mtrc_grp_tx for group rule activation
    vendor_id           VARCHAR2(50)    NOT NULL,
    priority            NUMBER(3)       NOT NULL,
    -- 1 = highest. Unique per (domain, mtrc_grp_tx, entity_scope, period_scope).
    -- Group rules use lower priority numbers than domain rules for same vendor.
    condition_type      VARCHAR2(20)    NOT NULL,
    -- ALWAYS | CONDITIONAL
    condition_sql       VARCHAR2(500),
    -- Evaluated against stack row context for CONDITIONAL rules.
    -- e.g. 'scope1_source_flag = ''DIRECT'''
    entity_scope        VARCHAR2(15)    DEFAULT 'CLIENT'  NOT NULL,
    -- ★ NEW — CLIENT | PARENT
    -- CLIENT: use the entity being arbitrated (original client)
    -- PARENT: use the entity's parent from udm_entity_membership
    --         Engine skips PARENT rules when no parent exists.
    period_scope        VARCHAR2(15)    DEFAULT 'CURRENT' NOT NULL,
    -- ★ NEW — CURRENT | PRIOR_YEAR
    -- CURRENT:    use the target coverage period
    -- PRIOR_YEAR: use coverage period - 1 year (from udm_ref_time)
    --             Engine skips PRIOR_YEAR rules when prior period absent.
    rule_label          VARCHAR2(200),
    -- ★ NEW — Human-readable label stamped on arb row metadata.
    -- e.g. 'Level 3 — Parent / Current Period / Vendor 1'
    -- Also displayed in udm_arb_waterfall_v for PO configuration review.
    bgn_tran_dt         DATE            NOT NULL,
    end_tran_dt         DATE,
    -- NEVER DELETE — close with end_tran_dt on vendor retirement.
    -- Arb rows reference rule_id — deleting breaks audit trail.
    created_by          VARCHAR2(50)    NOT NULL,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    modified_by         VARCHAR2(50),
    modified_date       DATE,
    CONSTRAINT pk_udm_precedence_rules    PRIMARY KEY (rule_id),
    CONSTRAINT uq_prec_priority           UNIQUE (domain_id, mtrc_grp_tx, entity_scope, period_scope, vendor_id, bgn_tran_dt),
    CONSTRAINT chk_prec_condition_type    CHECK (condition_type IN ('ALWAYS','CONDITIONAL')),
    CONSTRAINT chk_prec_condition_sql     CHECK (condition_type != 'CONDITIONAL' OR condition_sql IS NOT NULL),
    CONSTRAINT chk_prec_priority          CHECK (priority BETWEEN 1 AND 999),
    CONSTRAINT chk_prec_entity_scope      CHECK (entity_scope IN ('CLIENT','PARENT')),
    CONSTRAINT chk_prec_period_scope      CHECK (period_scope IN ('CURRENT','PRIOR_YEAR'))
);
CREATE INDEX idx_prec_domain_active ON udm_precedence_rules (domain_id, bgn_tran_dt, end_tran_dt);
CREATE INDEX idx_prec_group         ON udm_precedence_rules (domain_id, mtrc_grp_tx, entity_scope, period_scope);

COMMENT ON TABLE  udm_precedence_rules IS
    'Governs all three arbitration precedence modes. '
    'SIMPLE: entity_scope=CLIENT, period_scope=CURRENT (defaults). '
    'METRIC GROUP: mtrc_grp_tx IS NOT NULL — group-level override wins in ROW_NUMBER ranking. '
    'ENTITY SCOPE: entity_scope=PARENT and/or period_scope=PRIOR_YEAR — hierarchy+time fallback. '
    'NEVER DELETE — close with end_tran_dt. Arb rows reference rule_id.';
COMMENT ON COLUMN udm_precedence_rules.entity_scope IS
    'CLIENT: arbitrate against the entity itself. '
    'PARENT: arbitrate against the entity''s parent (from udm_entity_membership). '
    'Engine skips PARENT rules when no parent exists.';
COMMENT ON COLUMN udm_precedence_rules.period_scope IS
    'CURRENT: use target coverage period. '
    'PRIOR_YEAR: use target period - 1 year (from udm_ref_time ADD_MONTHS -12). '
    'Engine skips PRIOR_YEAR rules when prior period absent from udm_ref_time.';
COMMENT ON COLUMN udm_precedence_rules.rule_label IS
    'Stamped on arb row metadata columns (scope1_arb_lvl_tx etc.). '
    'e.g. ''Level 3 — Parent / Current Period / Vendor 1''. '
    'Displayed in udm_arb_waterfall_v for PO configuration review.';
COMMENT ON COLUMN udm_precedence_rules.mtrc_grp_tx IS
    'NULL = domain-level rule (applies to all metrics). '
    'Specific value = group override (matches udm_data_item.mtrc_grp_tx). '
    'Group rule wins over domain rule for the same vendor at the same priority tier.';


-- =============================================================================
-- SECTION 9 — GRAIN ALIGNMENT RULES
-- =============================================================================

CREATE TABLE udm_grain_alignment_rules (
    alignment_id        VARCHAR2(20)    NOT NULL,
    domain_id           VARCHAR2(50)    NOT NULL,
    canonical_grain     VARCHAR2(100)   NOT NULL,
    source_vendor       VARCHAR2(50)    NOT NULL,
    source_grain        VARCHAR2(100)   NOT NULL,
    alignment_method    VARCHAR2(20)    NOT NULL,
    resolution_sql      VARCHAR2(1000),
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    created_by          VARCHAR2(50)    NOT NULL,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_grain_alignment  PRIMARY KEY (alignment_id),
    CONSTRAINT uq_grain_domain_vendor  UNIQUE (domain_id, source_vendor, canonical_grain, effective_from),
    CONSTRAINT chk_alignment_method    CHECK (alignment_method IN ('DIRECT','LAST_VALUE','FIRST_VALUE','AVERAGE','SUM','EXCLUDE','DISAGGREGATE')),
    CONSTRAINT chk_disaggregate_sql    CHECK (alignment_method != 'DISAGGREGATE' OR resolution_sql IS NOT NULL)
);
COMMENT ON TABLE udm_grain_alignment_rules IS 'Grain collapsing before arbitration. SUM reads entity_membership. EXCLUDE: stack only.';


-- =============================================================================
-- SECTION 10 — DQ RULES
-- =============================================================================

CREATE TABLE udm_dq_rules (
    rule_id             VARCHAR2(20)    NOT NULL,
    domain_id           VARCHAR2(50)    NOT NULL,
    data_itm_nm         VARCHAR2(128)   NOT NULL,
    check_type          VARCHAR2(20)    NOT NULL,
    threshold           NUMBER,
    min_value           NUMBER,
    max_value           NUMBER,
    action              VARCHAR2(20)    NOT NULL,
    is_active           CHAR(1)         DEFAULT 'Y' NOT NULL,
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    created_by          VARCHAR2(50)    NOT NULL,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    modified_by         VARCHAR2(50),
    modified_date       DATE,
    CONSTRAINT pk_udm_dq_rules         PRIMARY KEY (rule_id),
    CONSTRAINT uq_dq_domain_item_type  UNIQUE (domain_id, data_itm_nm, check_type, effective_from),
    CONSTRAINT chk_dq_check_type       CHECK (check_type IN ('DRIFT','BOUNDS','COMPLETENESS','CROSS_VENDOR')),
    CONSTRAINT chk_dq_action           CHECK (action IN ('ALERT','QUARANTINE','REJECT')),
    CONSTRAINT chk_dq_active           CHECK (is_active IN ('Y','N')),
    CONSTRAINT chk_dq_bounds_present   CHECK (check_type != 'BOUNDS' OR (min_value IS NOT NULL AND max_value IS NOT NULL))
);
COMMENT ON TABLE udm_dq_rules IS 'Threshold DQ checks only. Auto-derived checks derive from data_item + src_map at runtime.';


-- =============================================================================
-- SECTION 11 — ENTITY REGISTRY
-- =============================================================================

CREATE TABLE udm_entity_registry (
    entity_key          VARCHAR2(20)    NOT NULL,
    entity_type         VARCHAR2(20)    NOT NULL,
    canonical_name      VARCHAR2(200)   NOT NULL,
    source_key          VARCHAR2(100),
    is_active           CHAR(1)         DEFAULT 'Y' NOT NULL,
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    modified_date       DATE,
    notes               VARCHAR2(500),
    CONSTRAINT pk_udm_entity_registry  PRIMARY KEY (entity_key),
    CONSTRAINT chk_entity_type         CHECK (entity_type IN ('COMPANY','SUPPLIER','COUNTERPARTY','PRODUCT','SECTOR','REGION','COUNTRY','COMPANY_SECTOR')),
    CONSTRAINT chk_entity_active       CHECK (is_active IN ('Y','N'))
);
CREATE INDEX idx_entity_type_active ON udm_entity_registry (entity_type, is_active);
CREATE INDEX idx_entity_source_key  ON udm_entity_registry (entity_type, source_key);
COMMENT ON COLUMN udm_entity_registry.source_key IS 'Join: entity_registry.source_key = ref_table.natural_key. NOT entity_key.';


-- =============================================================================
-- SECTION 12 — COMPANY CROSS-REFERENCE (MDM-maintained)
-- =============================================================================

CREATE TABLE udm_company_xref (
    xref_id             VARCHAR2(20)    NOT NULL,
    entity_key          VARCHAR2(20)    NOT NULL,
    vendor_id           VARCHAR2(50)    NOT NULL,
    external_id         VARCHAR2(100)   NOT NULL,
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_company_xref        PRIMARY KEY (xref_id),
    CONSTRAINT fk_co_xref_entity          FOREIGN KEY (entity_key) REFERENCES udm_entity_registry (entity_key),
    CONSTRAINT fk_co_xref_src_sys         FOREIGN KEY (vendor_id)  REFERENCES udm_source_system (source_system_cd),
    CONSTRAINT uq_co_xref_vendor_external UNIQUE (vendor_id, external_id, effective_from)
);
CREATE INDEX idx_co_xref_lookup ON udm_company_xref (vendor_id, external_id, effective_to);
COMMENT ON TABLE udm_company_xref IS 'MAINTAINED BY EXTERNAL MDM — UDM reads only. Pre-populate before first vendor fact load.';


-- =============================================================================
-- SECTION 13 — ENTITY MEMBERSHIP
-- =============================================================================

CREATE TABLE udm_entity_membership (
    membership_id       VARCHAR2(20)    NOT NULL,
    entity_key          VARCHAR2(20)    NOT NULL,
    parent_entity_key   VARCHAR2(20)    NOT NULL,
    relationship_type   VARCHAR2(30)    NOT NULL,
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    created_by          VARCHAR2(50)    NOT NULL,
    CONSTRAINT pk_udm_entity_membership  PRIMARY KEY (membership_id),
    CONSTRAINT fk_membership_entity      FOREIGN KEY (entity_key)        REFERENCES udm_entity_registry (entity_key),
    CONSTRAINT fk_membership_parent      FOREIGN KEY (parent_entity_key) REFERENCES udm_entity_registry (entity_key),
    CONSTRAINT uq_membership_natural     UNIQUE (entity_key, parent_entity_key, relationship_type, effective_from),
    CONSTRAINT chk_membership_rel_type   CHECK (relationship_type IN ('COMPANY_COMPONENT','SECTOR_COMPONENT','SECTOR_MEMBERSHIP','REGION_MEMBERSHIP'))
);
CREATE INDEX idx_membership_entity ON udm_entity_membership (entity_key, relationship_type, effective_to);
CREATE INDEX idx_membership_parent ON udm_entity_membership (parent_entity_key, relationship_type, effective_to);
COMMENT ON TABLE udm_entity_membership IS 'Grain alignment reads COMPANY_COMPONENT. Arbitration engine reads PARENT scope rules via this table.';


-- =============================================================================
-- SECTION 14 — SPATIAL ASSET REGISTRY
-- =============================================================================

CREATE TABLE udm_spatial_asset_registry (
    spatial_asset_key   VARCHAR2(20)    NOT NULL,
    source_id           VARCHAR2(20)    NOT NULL,
    vendor_asset_id     VARCHAR2(100)   NOT NULL,
    latitude            NUMBER(10,7)    NOT NULL,
    longitude           NUMBER(10,7)    NOT NULL,
    geohash             VARCHAR2(12)    NOT NULL,
    region_cd           VARCHAR2(10)    NOT NULL,
    asset_type          VARCHAR2(50),
    linked_entity_key   VARCHAR2(20),
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_spatial_registry  PRIMARY KEY (spatial_asset_key),
    CONSTRAINT fk_spatial_source        FOREIGN KEY (source_id)         REFERENCES udm_source_registry (source_id),
    CONSTRAINT fk_spatial_entity        FOREIGN KEY (linked_entity_key) REFERENCES udm_entity_registry (entity_key),
    CONSTRAINT chk_spatial_region       CHECK (region_cd IN ('EMEA','APAC','AMER','ROW')),
    CONSTRAINT uq_spatial_vendor_asset  UNIQUE (source_id, vendor_asset_id, effective_from)
);
CREATE INDEX idx_spatial_geohash ON udm_spatial_asset_registry (geohash);
CREATE INDEX idx_spatial_region  ON udm_spatial_asset_registry (region_cd, effective_to);


-- =============================================================================
-- SECTION 15 — SOURCE ROUTING MAP
-- =============================================================================

CREATE TABLE udm_ref_source_map (
    ref_map_id              VARCHAR2(20)    NOT NULL,
    source_id               VARCHAR2(20)    NOT NULL,
    ref_table_name          VARCHAR2(128)   NOT NULL,
    refresh_strategy        VARCHAR2(25)    NOT NULL,
    ref_natural_key_cols    VARCHAR2(200)   NOT NULL,
    creates_entity          CHAR(1)         DEFAULT 'N' NOT NULL,
    entity_type             VARCHAR2(20),
    is_active               CHAR(1)         DEFAULT 'Y' NOT NULL,
    effective_from          DATE            NOT NULL,
    created_by              VARCHAR2(50)    NOT NULL,
    created_date            DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_ref_source_map        PRIMARY KEY (ref_map_id),
    CONSTRAINT fk_refsrcmap_source          FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_refsrcmap_source_table    UNIQUE (source_id, ref_table_name),
    CONSTRAINT chk_ref_refresh              CHECK (refresh_strategy IN ('FULL_REPLACE','INCREMENTAL','EFFECTIVE_DATE_MERGE')),
    CONSTRAINT chk_ref_creates_entity       CHECK (creates_entity IN ('Y','N')),
    CONSTRAINT chk_ref_entity_type_required CHECK (creates_entity = 'N' OR entity_type IS NOT NULL),
    CONSTRAINT chk_ref_entity_type_valid    CHECK (entity_type IS NULL OR entity_type IN ('COMPANY','SUPPLIER','COUNTERPARTY','PRODUCT','SECTOR','REGION','COUNTRY','COMPANY_SECTOR')),
    CONSTRAINT chk_ref_active               CHECK (is_active IN ('Y','N'))
);
COMMENT ON TABLE udm_ref_source_map IS 'REFERENCE_SOURCE routing. creates_entity=Y seeds entity_registry as side effect.';


-- =============================================================================
-- SECTION 16 — REFERENCE TABLES (natural keys only — no entity_key FK)
-- =============================================================================

CREATE TABLE udm_ref_company (
    ref_company_key     VARCHAR2(20)    NOT NULL,
    company_source_key  VARCHAR2(100)   NOT NULL,
    legal_name          VARCHAR2(200)   NOT NULL,
    jurisdiction_cd     VARCHAR2(10),
    entity_status       VARCHAR2(30),
    primary_naics_code  VARCHAR2(20),
    lei_code            VARCHAR2(20),
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    source_id           VARCHAR2(20),
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_ref_company      PRIMARY KEY (ref_company_key),
    CONSTRAINT fk_ref_company_source   FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_company_key_eff  UNIQUE (company_source_key, effective_from)
);
CREATE INDEX idx_ref_company_lookup ON udm_ref_company (company_source_key, effective_to);
COMMENT ON TABLE udm_ref_company IS 'Natural key: company_source_key. Join: entity_registry.source_key = company_source_key.';

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
    CONSTRAINT pk_udm_ref_counterparty  PRIMARY KEY (ref_cpty_key),
    CONSTRAINT fk_ref_cpty_source       FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_cpty_key_eff      UNIQUE (counterparty_source_key, effective_from),
    CONSTRAINT chk_ref_cpty_netting     CHECK (netting_agreement_flag IN ('Y','N'))
);
CREATE INDEX idx_ref_cpty_lookup ON udm_ref_counterparty (counterparty_source_key, effective_to);

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
    CONSTRAINT pk_udm_ref_supplier      PRIMARY KEY (ref_supplier_key),
    CONSTRAINT fk_ref_supplier_source   FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_supplier_key_eff  UNIQUE (supplier_source_key, effective_from),
    CONSTRAINT chk_ref_supplier_appr    CHECK (approved_flag IN ('Y','N'))
);
CREATE INDEX idx_ref_supplier_lookup ON udm_ref_supplier (supplier_source_key, effective_to);

CREATE TABLE udm_ref_sector (
    ref_sector_key          VARCHAR2(20)    NOT NULL,
    classification_system   VARCHAR2(50)    NOT NULL,
    class_code              VARCHAR2(50)    NOT NULL,
    class_name              VARCHAR2(200)   NOT NULL,
    class_level             NUMBER(2),
    parent_class_code       VARCHAR2(50),
    effective_from          DATE            NOT NULL,
    effective_to            DATE,
    source_id               VARCHAR2(20),
    created_date            DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_ref_sector          PRIMARY KEY (ref_sector_key),
    CONSTRAINT fk_ref_sector_source       FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_sector_natural_eff  UNIQUE (classification_system, class_code, effective_from)
);
CREATE INDEX idx_ref_sector_lookup ON udm_ref_sector (classification_system, class_code, effective_to);
CREATE INDEX idx_ref_sector_parent ON udm_ref_sector (classification_system, parent_class_code);

CREATE TABLE udm_ref_region (
    ref_region_key      VARCHAR2(20)    NOT NULL,
    region_cd           VARCHAR2(10)    NOT NULL,
    region_name         VARCHAR2(200)   NOT NULL,
    parent_region_cd    VARCHAR2(10),
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    source_id           VARCHAR2(20),
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_ref_region     PRIMARY KEY (ref_region_key),
    CONSTRAINT fk_ref_region_source  FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_region_cd_eff  UNIQUE (region_cd, effective_from)
);
CREATE INDEX idx_ref_region_lookup ON udm_ref_region (region_cd, effective_to);

CREATE TABLE udm_ref_country (
    ref_country_key     VARCHAR2(20)    NOT NULL,
    iso_country_cd      VARCHAR2(3)     NOT NULL,
    country_name        VARCHAR2(200)   NOT NULL,
    region_cd           VARCHAR2(10),
    sovereignty_status  VARCHAR2(30),
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    source_id           VARCHAR2(20),
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_ref_country      PRIMARY KEY (ref_country_key),
    CONSTRAINT fk_ref_country_source   FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_country_iso_eff  UNIQUE (iso_country_cd, effective_from)
);
CREATE INDEX idx_ref_country_lookup ON udm_ref_country (iso_country_cd, effective_to);
CREATE INDEX idx_ref_country_region ON udm_ref_country (region_cd);

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
    CONSTRAINT pk_udm_ref_product       PRIMARY KEY (ref_product_key),
    CONSTRAINT fk_ref_product_source    FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_product_code_eff  UNIQUE (product_code, effective_from)
);

CREATE TABLE udm_ref_time (
    ref_time_key        VARCHAR2(20)    NOT NULL,
    period_value        VARCHAR2(20)    NOT NULL,
    period_grain        VARCHAR2(10)    NOT NULL,
    calendar_type       VARCHAR2(20)    NOT NULL,
    year_number         NUMBER(4),
    quarter_number      NUMBER(1),
    month_number        NUMBER(2),
    period_start_date   DATE            NOT NULL,
    period_end_date     DATE            NOT NULL,
    fiscal_year         VARCHAR2(10),
    is_current_period   CHAR(1)         DEFAULT 'N' NOT NULL,
    source_id           VARCHAR2(20),
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_ref_time              PRIMARY KEY (ref_time_key),
    CONSTRAINT fk_ref_time_source           FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT uq_ref_time_period_calendar  UNIQUE (period_value, calendar_type),
    CONSTRAINT chk_ref_period_grain         CHECK (period_grain IN ('DAY','WEEK','MONTH','QTR','ANNUAL')),
    CONSTRAINT chk_ref_calendar_type        CHECK (calendar_type IN ('GREGORIAN','FISCAL','REGULATORY')),
    CONSTRAINT chk_ref_time_current         CHECK (is_current_period IN ('Y','N'))
);
CREATE INDEX idx_ref_time_grain      ON udm_ref_time (period_grain, year_number, calendar_type);
CREATE INDEX idx_ref_time_start_date ON udm_ref_time (period_start_date, calendar_type, period_grain);
-- ★ NEW — supports ADD_MONTHS(-12) prior period join in arbitration engine
COMMENT ON TABLE udm_ref_time IS 'Standalone fiscal calendar. idx_ref_time_start_date supports arbitration prior period lookup.';


-- =============================================================================
-- SECTION 17 — DELIVERY MANIFEST
-- =============================================================================

CREATE TABLE udm_delivery_manifest (
    manifest_id         VARCHAR2(30)    NOT NULL,
    source_id           VARCHAR2(20)    NOT NULL,
    vendor_id           VARCHAR2(50)    NOT NULL,
    coverage_period     VARCHAR2(20)    NOT NULL,
    expected_files      NUMBER(5)       NOT NULL,
    files_received      NUMBER(5)       DEFAULT 0  NOT NULL,
    status              VARCHAR2(20)    DEFAULT 'PARTIAL' NOT NULL,
    received_at         DATE            DEFAULT SYSDATE NOT NULL,
    completed_at        DATE,
    lineage_id          VARCHAR2(30),
    notes               VARCHAR2(500),
    CONSTRAINT pk_udm_delivery_manifest  PRIMARY KEY (manifest_id),
    CONSTRAINT fk_manifest_source        FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT chk_manifest_status       CHECK (status IN ('PARTIAL','COMPLETE','FAILED','SUPERSEDED')),
    CONSTRAINT chk_manifest_files        CHECK (files_received <= expected_files OR status = 'FAILED')
);
CREATE INDEX idx_manifest_vendor_period ON udm_delivery_manifest (vendor_id, coverage_period, status);


-- =============================================================================
-- SECTION 18 — LINEAGE (partitioned monthly)
-- =============================================================================

CREATE TABLE udm_lineage (
    lineage_id          VARCHAR2(30)    NOT NULL,
    lineage_type        VARCHAR2(20)    NOT NULL,
    source_id           VARCHAR2(20),
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
    duration_secs       NUMBER GENERATED ALWAYS AS (ROUND((completed_at - started_at) * 86400)) VIRTUAL,
    status              VARCHAR2(20)    NOT NULL,
    error_message       VARCHAR2(2000),
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_lineage     PRIMARY KEY (lineage_id),
    CONSTRAINT chk_lineage_type   CHECK (lineage_type IN ('LOAD','ARBITRATION','DI_CHECK','MANIFEST')),
    CONSTRAINT chk_lineage_status CHECK (status IN ('RUNNING','COMPLETE','FAILED','PARTIAL'))
)
PARTITION BY RANGE (created_date)
INTERVAL (NUMTOYMINTERVAL(1,'MONTH'))
( PARTITION p_lineage_initial VALUES LESS THAN (DATE '2024-01-01') );

CREATE INDEX idx_lineage_domain  ON udm_lineage (domain_id, coverage_period, lineage_type) LOCAL;
CREATE INDEX idx_lineage_vendor  ON udm_lineage (vendor_id, created_date) LOCAL;
CREATE INDEX idx_lineage_status  ON udm_lineage (status, created_date) LOCAL;


-- =============================================================================
-- SECTION 19 — QUARANTINE (partitioned monthly)
-- =============================================================================

CREATE TABLE udm_quarantine (
    quarantine_id       VARCHAR2(30)    NOT NULL,
    lineage_id          VARCHAR2(30)    NOT NULL,
    source_id           VARCHAR2(20)    NOT NULL,
    domain_id           VARCHAR2(50)    NOT NULL,
    vendor_id           VARCHAR2(50)    NOT NULL,
    coverage_period     VARCHAR2(20),
    entity_id_raw       VARCHAR2(200),
    data_itm_nm         VARCHAR2(128),
    raw_value           VARCHAR2(2000),
    check_type          VARCHAR2(30)    NOT NULL,
    rejection_reason    VARCHAR2(500)   NOT NULL,
    quarantined_at      DATE            DEFAULT SYSDATE NOT NULL,
    resolved_flag       CHAR(1)         DEFAULT 'N' NOT NULL,
    resolved_at         DATE,
    resolved_by         VARCHAR2(50),
    resolution_notes    VARCHAR2(500),
    CONSTRAINT pk_udm_quarantine        PRIMARY KEY (quarantine_id),
    CONSTRAINT fk_quarantine_lineage    FOREIGN KEY (lineage_id) REFERENCES udm_lineage (lineage_id),
    CONSTRAINT fk_quarantine_source     FOREIGN KEY (source_id)  REFERENCES udm_source_registry (source_id),
    CONSTRAINT chk_quarantine_type      CHECK (check_type IN ('DATA_TYPE','NOT_NULL','BOUNDS','UNMAPPED_ATTRIBUTE','REFERENTIAL','ENTITY_NOT_FOUND')),
    CONSTRAINT chk_quarantine_resolved  CHECK (resolved_flag IN ('Y','N'))
)
PARTITION BY RANGE (quarantined_at)
INTERVAL (NUMTOYMINTERVAL(1,'MONTH'))
( PARTITION p_quarantine_initial VALUES LESS THAN (DATE '2024-01-01') );

CREATE INDEX idx_quarantine_source     ON udm_quarantine (source_id, coverage_period, resolved_flag) LOCAL;
CREATE INDEX idx_quarantine_unresolved ON udm_quarantine (resolved_flag, quarantined_at) LOCAL;
-- ★ NEW — supports arbitration quarantine exclusion subquery
CREATE INDEX idx_qrn_lineage_entity    ON udm_quarantine (lineage_id, entity_id_raw, resolved_flag) LOCAL;


-- =============================================================================
-- SECTION 20 — DQ RESULTS (partitioned monthly)
-- =============================================================================

CREATE TABLE udm_dq_results (
    result_id           VARCHAR2(30)    NOT NULL,
    lineage_id          VARCHAR2(30)    NOT NULL,
    rule_id             VARCHAR2(20),
    check_type          VARCHAR2(30)    NOT NULL,
    check_source        VARCHAR2(20)    NOT NULL,
    domain_id           VARCHAR2(50)    NOT NULL,
    source_id           VARCHAR2(20),
    data_itm_nm         VARCHAR2(128),
    movement_point      VARCHAR2(20)    NOT NULL,
    check_result        VARCHAR2(10)    NOT NULL,
    actual_value        NUMBER,
    expected_value      NUMBER,
    entity_key          VARCHAR2(20),
    coverage_period     VARCHAR2(20),
    action_taken        VARCHAR2(20)    NOT NULL,
    checked_at          DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_dq_results         PRIMARY KEY (result_id),
    CONSTRAINT fk_dqresult_lineage       FOREIGN KEY (lineage_id) REFERENCES udm_lineage (lineage_id),
    CONSTRAINT chk_dqresult_check_source CHECK (check_source IN ('AUTO_DERIVED','CONFIGURED')),
    CONSTRAINT chk_dqresult_movement     CHECK (movement_point IN ('STAGE_TO_VS','VS_TO_ARB','ARB_TO_DIST')),
    CONSTRAINT chk_dqresult_result       CHECK (check_result IN ('PASS','FAIL','WARNING')),
    CONSTRAINT chk_dqresult_action       CHECK (action_taken IN ('ALERT','QUARANTINE','REJECT','NONE'))
)
PARTITION BY RANGE (checked_at)
INTERVAL (NUMTOYMINTERVAL(1,'MONTH'))
( PARTITION p_dqresult_initial VALUES LESS THAN (DATE '2024-01-01') );

CREATE INDEX idx_dqresult_lineage  ON udm_dq_results (lineage_id) LOCAL;
CREATE INDEX idx_dqresult_domain   ON udm_dq_results (domain_id, coverage_period, check_result) LOCAL;
CREATE INDEX idx_dqresult_failures ON udm_dq_results (check_result, domain_id, checked_at) LOCAL;


-- =============================================================================
-- SECTION 21 — DETECTION SUPPRESSIONS
-- =============================================================================

CREATE TABLE udm_detection_suppressions (
    suppression_id      VARCHAR2(20)    NOT NULL,
    suppression_type    VARCHAR2(30)    NOT NULL,
    source_schema       VARCHAR2(30)    NOT NULL,
    source_table        VARCHAR2(128)   NOT NULL,
    column_name         VARCHAR2(128),
    attribute_value     VARCHAR2(200),
    suppression_reason  VARCHAR2(100)   NOT NULL,
    suppressed_by       VARCHAR2(50)    NOT NULL,
    suppressed_date     DATE            NOT NULL,
    effective_from_env  VARCHAR2(10)    NOT NULL,
    release_version     VARCHAR2(20),
    notes               VARCHAR2(500),
    CONSTRAINT pk_udm_detect_suppress  PRIMARY KEY (suppression_id),
    CONSTRAINT chk_suppress_type       CHECK (suppression_type IN ('COLUMN_IGNORE','TABLE_NOT_APPLICABLE','EAV_VALUE_REJECTED','ALREADY_MAPPED')),
    CONSTRAINT chk_suppress_env        CHECK (effective_from_env IN ('DEV','TEST','PROD')),
    CONSTRAINT uq_suppress_natural     UNIQUE (suppression_type, source_schema, source_table, column_name, attribute_value)
);
CREATE INDEX idx_suppress_table ON udm_detection_suppressions (source_schema, source_table);


-- =============================================================================
-- SECTION 22 — ARBITRATION REVIEW QUEUE (★ NEW in v7)
-- Captures all unresolved arbitration cases (all waterfall levels exhausted).
-- PO reviews each case and either resolves or suppresses.
-- On resolution: PO fixes root cause (e.g. adds xref mapping or loads data).
-- Reprocessing: engine run() called with specific entity_key.
-- On suppression: arb row remains UNRESLVD but is acknowledged.
-- =============================================================================

CREATE TABLE udm_arb_review_queue (
    review_id           VARCHAR2(30)    NOT NULL,
    -- Format: REV-YYYYMMDD-NNNNN
    domain_id           VARCHAR2(50)    NOT NULL,
    entity_key          VARCHAR2(20)    NOT NULL,
    coverage_period     VARCHAR2(20)    NOT NULL,
    data_itm_scd_1_ky   NUMBER(32)      NOT NULL,
    -- Logical FK → udm_data_item.data_itm_scd_1_ky
    review_reason       VARCHAR2(500)   NOT NULL,
    -- Plain-English explanation: how many levels exhausted, what was tried.
    review_stat_cd      VARCHAR2(20)    DEFAULT 'PENDING' NOT NULL,
    -- PENDING    : awaiting PO review
    -- IN_REVIEW  : PO actively investigating
    -- RESOLVED   : root cause fixed, reprocessing triggered
    -- SUPPRESSED : acknowledged as unavoidable, no further action
    parent_entity_key   VARCHAR2(20),
    -- Populated even when parent exists but had no qualifying data.
    -- NULL means no parent exists for this entity.
    prior_period        VARCHAR2(20),
    -- Populated even when prior period exists but had no qualifying data.
    -- NULL means prior period not in udm_ref_time.
    resolution_action   VARCHAR2(500),
    -- What the PO did to resolve: 'Added xref mapping', 'Loaded vendor data', etc.
    resolved_by         VARCHAR2(100),
    resolved_date       DATE,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    lineage_id          VARCHAR2(30),
    -- FK → udm_lineage for the arbitration run that created this queue entry.
    CONSTRAINT pk_arb_review_queue    PRIMARY KEY (review_id),
    CONSTRAINT uq_review_entity_item  UNIQUE (entity_key, coverage_period, data_itm_scd_1_ky),
    -- One open review per entity per period per data item.
    -- MERGE in engine updates on re-run rather than duplicating.
    CONSTRAINT chk_review_stat        CHECK (review_stat_cd IN ('PENDING','IN_REVIEW','RESOLVED','SUPPRESSED'))
);

CREATE INDEX idx_review_pending ON udm_arb_review_queue (review_stat_cd, domain_id, coverage_period);
CREATE INDEX idx_review_entity  ON udm_arb_review_queue (entity_key, coverage_period);

COMMENT ON TABLE  udm_arb_review_queue IS
    'Unresolved arbitration cases. All waterfall levels exhausted. '
    'PO reviews and either resolves (triggers reprocessing) or suppresses. '
    'MERGE on re-run updates existing PENDING items — no duplicates.';
COMMENT ON COLUMN udm_arb_review_queue.parent_entity_key IS
    'NULL = entity has no parent. Populated even when parent had no qualifying data.';
COMMENT ON COLUMN udm_arb_review_queue.prior_period IS
    'NULL = prior period not in udm_ref_time. Populated even when prior period had no data.';


-- =============================================================================
-- SECTION 23 — SEMANTIC / BI CATALOG
-- =============================================================================

CREATE TABLE udm_metric_catalog (
    metric_id               VARCHAR2(20)    NOT NULL,
    domain_id               VARCHAR2(50)    NOT NULL,
    data_itm_scd_1_ky       NUMBER(32),
    metric_name             VARCHAR2(200)   NOT NULL,
    physical_table          VARCHAR2(128)   NOT NULL,
    physical_column         VARCHAR2(128)   NOT NULL,
    canonical_key_col       VARCHAR2(128)   NOT NULL,
    canonical_time_col      VARCHAR2(128)   NOT NULL,
    aggregation             VARCHAR2(20)    NOT NULL,
    domain_grain            VARCHAR2(100)   NOT NULL,
    is_active               CHAR(1)         DEFAULT 'Y' NOT NULL,
    CONSTRAINT pk_udm_metric_catalog  PRIMARY KEY (metric_id),
    CONSTRAINT chk_metric_aggregation CHECK (aggregation IN ('SUM','AVG','MAX','MIN','LAST','COUNT')),
    CONSTRAINT chk_metric_active      CHECK (is_active IN ('Y','N'))
);
CREATE INDEX idx_metric_cat_scd1 ON udm_metric_catalog (data_itm_scd_1_ky);

CREATE TABLE udm_domain_join_map (
    join_id                 VARCHAR2(20)    NOT NULL,
    domain_a                VARCHAR2(50)    NOT NULL,
    domain_b                VARCHAR2(50)    NOT NULL,
    join_type               VARCHAR2(10)    NOT NULL,
    domain_a_key            VARCHAR2(128)   NOT NULL,
    domain_b_key            VARCHAR2(128)   NOT NULL,
    domain_a_time_col       VARCHAR2(128),
    domain_b_time_col       VARCHAR2(128),
    time_alignment          VARCHAR2(20),
    grain_compatible        CHAR(1)         NOT NULL,
    CONSTRAINT pk_udm_domain_join_map  PRIMARY KEY (join_id),
    CONSTRAINT uq_domain_join_pair     UNIQUE (domain_a, domain_b),
    CONSTRAINT chk_join_type           CHECK (join_type IN ('INNER','LEFT','FULL')),
    CONSTRAINT chk_join_grain_compat   CHECK (grain_compatible IN ('Y','N'))
);

CREATE TABLE udm_grain_compatibility (
    compat_id               VARCHAR2(20)    NOT NULL,
    domain_a_grain          VARCHAR2(100)   NOT NULL,
    domain_b_grain          VARCHAR2(100)   NOT NULL,
    resolution              VARCHAR2(20)    NOT NULL,
    resolution_sql          VARCHAR2(500),
    user_warning            VARCHAR2(200),
    CONSTRAINT pk_udm_grain_compat   PRIMARY KEY (compat_id),
    CONSTRAINT uq_grain_compat_pair  UNIQUE (domain_a_grain, domain_b_grain)
);


-- =============================================================================
-- SECTION 24 — ARBITRATION GTTs (★ NEW in v7)
-- Global Temporary Tables for the set-based arbitration engine.
-- ON COMMIT DELETE ROWS — session-scoped, no cleanup required between runs.
-- Created once in schema. Each session/run uses its own private copy of data.
-- =============================================================================

-- GTT 1: All qualified candidates for current arbitration run.
-- Populated by step_fetch_candidates() — one INSERT...SELECT.
CREATE GLOBAL TEMPORARY TABLE udm_arb_candidates_gtt (
    target_entity_key   VARCHAR2(20)    NOT NULL,
    -- The CLIENT entity being arbitrated (always original key).
    data_itm_nm         VARCHAR2(128)   NOT NULL,
    data_itm_scd_1_ky   NUMBER(32)      NOT NULL,
    candidate_value     NUMBER,
    -- Numeric value from stack. NULL excluded by quality gate before insert.
    source_vendor       VARCHAR2(50)    NOT NULL,
    stack_entity_key    VARCHAR2(20)    NOT NULL,
    -- May differ from target_entity_key when entity_scope=PARENT.
    stack_period        VARCHAR2(20)    NOT NULL,
    -- May differ from target period when period_scope=PRIOR_YEAR.
    rule_id             VARCHAR2(20)    NOT NULL,
    -- FK → udm_precedence_rules.rule_id
    effective_priority  NUMBER(3)       NOT NULL,
    -- From udm_precedence_rules.priority after group override resolution.
    entity_scope        VARCHAR2(15)    NOT NULL,
    period_scope        VARCHAR2(15)    NOT NULL,
    rule_label          VARCHAR2(200),
    dq_score            NUMBER(5,2)     NOT NULL,
    -- 100=clean, 80=near boundary, 0=excluded (never inserted)
    stk_lineage_id      VARCHAR2(30)
) ON COMMIT DELETE ROWS;

CREATE INDEX idx_arb_cand_gtt ON udm_arb_candidates_gtt
    (target_entity_key, data_itm_nm, effective_priority);

COMMENT ON TABLE udm_arb_candidates_gtt IS
    'GTT: session-scoped candidates for current arb run. '
    'Populated by step_fetch_candidates() — one INSERT...SELECT. '
    'Quality gate applied inline — bad rows never inserted. ON COMMIT DELETE ROWS.';

-- GTT 2: One winning row per entity per metric after ROW_NUMBER ranking.
-- Populated by step_rank_and_resolve() — one INSERT...SELECT with analytic.
CREATE GLOBAL TEMPORARY TABLE udm_arb_resolved_gtt (
    target_entity_key   VARCHAR2(20)    NOT NULL,
    data_itm_nm         VARCHAR2(128)   NOT NULL,
    data_itm_scd_1_ky   NUMBER(32)      NOT NULL,
    resolved_value      NUMBER,
    -- NULL = UNRESLVD (all levels exhausted or no candidates in GTT 1).
    source_vendor       VARCHAR2(50),
    stack_entity_key    VARCHAR2(20),
    stack_period        VARCHAR2(20),
    rule_id             VARCHAR2(20),
    effective_priority  NUMBER(3),
    entity_scope        VARCHAR2(15),
    period_scope        VARCHAR2(15),
    rule_label          VARCHAR2(200),
    dq_score            NUMBER(5,2),
    resolution_stat_cd  VARCHAR2(20)    NOT NULL
    -- RESOLVED    : value found, quality gate passed, current period
    -- CARRIED_FWD : value found from prior year (period_scope=PRIOR_YEAR)
    -- UNRESLVD    : all waterfall levels exhausted
) ON COMMIT DELETE ROWS;

CREATE INDEX idx_arb_res_gtt ON udm_arb_resolved_gtt
    (target_entity_key, data_itm_nm);

COMMENT ON TABLE udm_arb_resolved_gtt IS
    'GTT: one winner per entity per metric after ROW_NUMBER ranking. '
    'UNRESLVD rows have NULL resolved_value and are queued in review_queue. '
    'ON COMMIT DELETE ROWS.';


-- =============================================================================
-- SECTION 25 — VIEWS
-- =============================================================================

-- Data item lineage view
CREATE OR REPLACE VIEW udm_data_item_lineage AS
SELECT
    di.domn_ky                      AS domain_id,
    di.data_itm_scd_1_ky,
    di.data_itm_id,
    di.data_itm_nm,
    di.data_itm_de_tx               AS data_item_label,
    di.data_typ_cd,
    di.data_itm_trgt_unit_tx        AS canonical_unit,
    di.mtrc_typ_cd,
    di.mtrc_grp_tx,
    di.phy_trgt_tbl_nm,
    di.is_subj_ky,
    di.is_time_ky,
    di.is_mndty_fl,
    sr.vendor_id,
    sr.source_schema,
    sr.source_table,
    sm.attr_src_nm                  AS source_attribute,
    sm.is_derived_fl,
    sm.attr_xfrm_ru_tx              AS transform_rule,
    sm.attr_unit_from_tx            AS unit_from,
    sm.attr_unit_eav_ky             AS unit_from_eav_key,
    sm.map_stat_cd,
    sr.governance_status            AS source_status,
    sm.bgn_tran_dt,
    sm.end_tran_dt
FROM    udm_data_item               di
JOIN    udm_data_item_src_map       sm  ON  sm.data_itm_scd_1_ky = di.data_itm_scd_1_ky
                                        AND sm.map_stat_cd IN ('ACTIVE','PENDING_RETIREMENT')
LEFT JOIN udm_source_registry       sr  ON  sr.source_id = sm.source_id
WHERE   di.cur_fl = 1;

COMMENT ON TABLE udm_data_item_lineage IS
    'Data item lineage. Joins current SCD2 version to all source mappings. '
    'Auditor: source attribute X → data item Y, and reverse.';


-- ★ NEW — Waterfall configuration display view
-- Human-readable display of the complete waterfall for any domain.
-- Used by PO to review and validate rule configuration before arbitration runs.
CREATE OR REPLACE VIEW udm_arb_waterfall_v AS
SELECT
    pr.domain_id,
    pr.rule_id,
    pr.priority,
    pr.entity_scope,
    pr.period_scope,
    pr.vendor_id,
    pr.mtrc_grp_tx,
    CASE
        WHEN pr.mtrc_grp_tx IS NULL THEN 'DOMAIN-LEVEL'
        ELSE 'GROUP: ' || pr.mtrc_grp_tx
    END                             AS rule_scope,
    pr.condition_type,
    pr.condition_sql,
    pr.rule_label,
    pr.bgn_tran_dt,
    pr.end_tran_dt,
    CASE
        WHEN pr.end_tran_dt IS NULL OR pr.end_tran_dt >= SYSDATE
        THEN 'ACTIVE'
        ELSE 'EXPIRED'
    END                             AS rule_status,
    -- How many data items this rule applies to in this domain
    ( SELECT COUNT(*)
      FROM   udm_data_item di
      WHERE  di.domn_ky  = pr.domain_id
      AND    di.cur_fl   = 1
      AND    (pr.mtrc_grp_tx IS NULL OR di.mtrc_grp_tx = pr.mtrc_grp_tx)
    )                               AS applicable_item_count
FROM    udm_precedence_rules pr
ORDER BY
    pr.domain_id,
    pr.mtrc_grp_tx NULLS FIRST,
    pr.entity_scope,
    pr.period_scope,
    pr.priority;

COMMENT ON TABLE udm_arb_waterfall_v IS
    'Human-readable waterfall configuration per domain. '
    'PO uses this to review rule setup before arbitration runs. '
    'Shows all three precedence modes: SIMPLE, METRIC GROUP, ENTITY SCOPE.';


-- =============================================================================
-- SECTION 26 — ROLE-BASED GRANTS (uncomment and adjust role names)
-- =============================================================================

-- udm_engine_role (harmonisation + arbitration)
-- GRANT SELECT         ON udm_source_system           TO udm_engine_role;
-- GRANT SELECT         ON udm_source_registry         TO udm_engine_role;
-- GRANT SELECT         ON udm_data_item               TO udm_engine_role;
-- GRANT SELECT         ON udm_data_item_taxonomy      TO udm_engine_role;
-- GRANT SELECT         ON udm_data_item_src_map       TO udm_engine_role;
-- GRANT SELECT         ON udm_transform_rules         TO udm_engine_role;
-- GRANT SELECT         ON udm_precedence_rules        TO udm_engine_role;
-- GRANT SELECT         ON udm_grain_alignment_rules   TO udm_engine_role;
-- GRANT SELECT         ON udm_dq_rules                TO udm_engine_role;
-- GRANT SELECT         ON udm_entity_registry         TO udm_engine_role;
-- GRANT SELECT         ON udm_company_xref            TO udm_engine_role;
-- GRANT SELECT         ON udm_entity_membership       TO udm_engine_role;
-- GRANT SELECT         ON udm_ref_source_map          TO udm_engine_role;
-- GRANT SELECT         ON udm_ref_time                TO udm_engine_role;
-- GRANT SELECT         ON udm_delivery_manifest       TO udm_engine_role;
-- GRANT SELECT         ON udm_quarantine              TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_entity_registry         TO udm_engine_role;
-- GRANT INSERT         ON udm_entity_membership       TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_company             TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_counterparty        TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_supplier            TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_sector              TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_region              TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_country             TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_product             TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_time                TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_delivery_manifest       TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_lineage                 TO udm_engine_role;
-- GRANT INSERT         ON udm_quarantine              TO udm_engine_role;
-- GRANT INSERT         ON udm_dq_results              TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_arb_review_queue        TO udm_engine_role;

-- udm_catalog_admin_role (PO + architecture)
-- GRANT SELECT, INSERT, UPDATE ON udm_data_item              TO udm_catalog_admin_role;
-- GRANT SELECT, INSERT, UPDATE ON udm_data_item_taxonomy     TO udm_catalog_admin_role;
-- GRANT SELECT, INSERT, UPDATE ON udm_data_item_src_map      TO udm_catalog_admin_role;
-- GRANT SELECT, INSERT, UPDATE ON udm_source_registry        TO udm_catalog_admin_role;
-- GRANT SELECT, INSERT, UPDATE ON udm_precedence_rules       TO udm_catalog_admin_role;
-- GRANT SELECT, INSERT, UPDATE ON udm_detection_suppressions TO udm_catalog_admin_role;
-- GRANT SELECT, UPDATE         ON udm_arb_review_queue       TO udm_catalog_admin_role;

-- udm_consumer_role (distribution + downstream)
-- GRANT SELECT ON udm_data_item_lineage   TO udm_consumer_role;
-- GRANT SELECT ON udm_arb_waterfall_v     TO udm_consumer_role;
-- GRANT SELECT ON udm_metric_catalog      TO udm_consumer_role;
-- GRANT SELECT ON udm_domain_join_map     TO udm_consumer_role;
-- GRANT SELECT ON udm_grain_compatibility TO udm_consumer_role;
-- (add SELECT on each udm_{sub_domain}_arb and udm_{sub_domain}_v as created)


-- =============================================================================
-- END — UDM TIER 1 DDL COMPLETE FINAL v7
-- ─────────────────────────────────────────────────────────────────────────────
-- OBJECT COUNTS
--   Sequences : 33  (udm_review_seq ★ NEW)
--   Tables    : 33  (udm_arb_review_queue ★ NEW; 2 GTTs ★ NEW)
--   Views     : 2   (udm_data_item_lineage; udm_arb_waterfall_v ★ NEW)
-- ─────────────────────────────────────────────────────────────────────────────
-- KEY CHANGES FROM v6
--   udm_precedence_rules  : +entity_scope +period_scope +rule_label
--                           +idx_prec_domain_active +idx_prec_group
--   udm_ref_time          : +idx_ref_time_start_date (prior period lookup)
--   udm_quarantine        : +idx_qrn_lineage_entity (arb exclusion subquery)
--   udm_arb_review_queue  : NEW — unresolved arb cases for PO review
--   udm_arb_candidates_gtt: NEW GTT — staged candidates, session-scoped
--   udm_arb_resolved_gtt  : NEW GTT — one winner per entity per metric
--   udm_arb_waterfall_v   : NEW VIEW — waterfall config display for PO
--   udm_review_seq        : NEW
-- ─────────────────────────────────────────────────────────────────────────────
-- NOT IN TIER 1 (created at domain onboarding)
--   udm_company_sector_mv    materialised view for COMPANY_SECTOR lookup
--   udm_{sub_domain}_stk     vendor stack (12 — one per sub-domain)
--   udm_{sub_domain}_arb     arbitration output (12) including arb metadata cols
--   udm_{sub_domain}_v       reporting views (12 — generated from taxonomy)
-- NOT IN TIER 1 (Module 2 — detection layer)
--   dsc_*  (10 tables)
-- NOT IN TIER 1 (Module 6 — harmonisation engine package)
--   udm_hrm_engine  PL/SQL package
-- NOT IN TIER 1 (Module 7 — arbitration engine package)
--   udm_arb_engine  PL/SQL package  (udm_arb_engine_v1.sql)
-- ─────────────────────────────────────────────────────────────────────────────
-- SEED DATA TASKS (mandatory before engine work)
--   1.  Seed udm_source_system from DW.src_sys_dim
--   2.  Register all Option A sources in udm_source_registry
--   3.  Extract Option A precedence rules → INSERT udm_precedence_rules
--       with entity_scope='CLIENT', period_scope='CURRENT', rule_label populated
--   4.  Add waterfall fallback rules (PARENT/PRIOR_YEAR) to udm_precedence_rules
--   5.  REFERENCE_SOURCE loads with creates_entity=Y
--   6.  Load udm_company_xref from external MDM
--   7.  Seed udm_ref_time for all periods (critical for prior period lookup)
--   8.  Categorise 274 data items → INSERT udm_data_item (SCD1+SCD2)
--   9.  INSERT udm_data_item_taxonomy (axis+node per item; SCD1_KY)
--  10.  INSERT udm_data_item_src_map (source attribute → data item; SCD1_KY)
--  11.  Build view generation script (taxonomy → UNION ALL view DDL)
--  12.  First DATA_SOURCE harmonisation load
--  13.  First arbitration run: udm_arb_engine.run(domain, period, lineage_id)
-- =============================================================================
