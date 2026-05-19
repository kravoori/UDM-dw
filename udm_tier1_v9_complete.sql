-- =============================================================================
-- UDM TIER 1 DDL — COMPLETE FINAL v9
-- Schema  : UDM
-- Version : 9.0
-- =============================================================================
--
-- OBJECT INVENTORY
-- ─────────────────────────────────────────────────────────────────────────────
-- 36 tables, 34 sequences, 3 views
--
-- CATALOG
--   01 udm_source_system
--   02 udm_source_registry
--   03 udm_data_item              SCD2 — metric registry, one physical home per item
--   04 udm_data_item_taxonomy     axis+node classification — drives view generation
--   05 udm_data_item_src_map      source mapping — one row per (data item × source)
--   06 udm_transform_rules        named SQL for rule_ref: transforms
--   07 udm_precedence_rules       extended: entity_scope, period_scope, rule_label
--   08 udm_grain_alignment_rules
--   09 udm_dq_rules
--
-- ENTITY RESOLUTION
--   10 udm_entity_registry        ★ extended: match_status, vendor_id, merged_into_key
--   11 udm_company_xref           ★ extended: match_status (CONFIRMED/ENGINE/SUPERSEDED)
--   12 udm_entity_membership
--   13 udm_spatial_asset_registry
--
-- SOURCE ROUTING
--   14 udm_ref_source_map
--
-- REFERENCE TABLES (natural keys only — no entity_key FK)
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
--   23 udm_process_run            ★ NEW — parent record per end-to-end delivery run
--   24 udm_delivery_manifest      step 1 of every process run
--   25 udm_lineage                ★ revised — step-level, FK to process_run
--   26 udm_quarantine             partitioned monthly
--   27 udm_dq_results             partitioned monthly
--   28 udm_detection_suppressions
--
-- ARBITRATION SUPPORT
--   29 udm_arb_review_queue       unresolved arb cases for PO review
--
-- SEMANTIC / BI CATALOG
--   30 udm_metric_catalog
--   31 udm_domain_join_map
--   32 udm_grain_compatibility
--
-- GLOBAL TEMPORARY TABLES (session-scoped, ON COMMIT DELETE ROWS)
--   33 udm_arb_candidates_gtt     all qualified candidates for current arb run
--   34 udm_arb_resolved_gtt       one winner per entity per metric after ranking
--
-- DOMAIN STACK TEMPORAL — OPTION A (alternative design, available at onboarding)
--   35 udm_stk_version            ★ NEW — bridge table for source + UDM temporal metadata
--
-- VIEWS
--   udm_data_item_lineage         data item + source map as column lineage graph
--   udm_arb_waterfall_v           waterfall rule config display for PO review
--   udm_stk_current_v             convenience — current stack rows with entity context
--
-- ─────────────────────────────────────────────────────────────────────────────
-- DOMAIN STACK TEMPORAL DESIGN — TWO OPTIONS
-- ─────────────────────────────────────────────────────────────────────────────
-- Both options are provided as governed DDL. Teams choose one at domain
-- onboarding and document the choice in udm_source_registry.notes.
-- Mixing options across domains creates a heterogeneous consumer experience
-- and is strongly discouraged. Choose once, apply consistently.
--
-- OPTION A — Bridge Table (udm_stk_version) ← available, NOT adopted as default
--   A separate table holds all temporal metadata per load version.
--   The stack fact table carries stk_version_id as the only temporal FK.
--   Temporal metadata is normalised: one version row shared across all metrics.
--   Re-delivery closes ONE bridge row — all metrics superseded atomically.
--   Advantage: simpler fact table — no date columns on wide metric rows.
--   Disadvantage: mandatory JOIN on every consumer query. Same cardinality
--   as the stack (one row per entity × period × vendor × version = same volume).
--   Queries on source type (SNAPSHOT vs SCD2) require checking bridge.source_type.
--   Best suited to: narrow stack tables, teams comfortable with the join cost.
--
-- OPTION B — Dates on Stack Row ← ADOPTED as platform default
--   Four date columns directly on every stack row:
--   src_bgn_tran_dt / src_end_tran_dt (source time — never changes after INSERT)
--   bgn_tran_dt / end_tran_dt + cur_fl (UDM time — changes on re-delivery)
--   BETWEEN pattern identical to RDM source tables — intentional compatibility.
--   No bridge join required on any consumer query.
--   Overhead: 4 DATE columns per row on a wide columnar table — negligible.
--   Best suited to: all domains where consumer query simplicity is the priority.
--
-- KEY CHANGES FROM v8
--
-- ENTITY LIFECYCLE (v8)
--   udm_entity_registry:
--     match_status  INTERNAL | VENDOR_ONLY | MERGED
--     vendor_id     populated for VENDOR_ONLY entities
--     merged_into_key populated when MERGED — points to surviving entity_key
--   Engine behaviour:
--     CONFIRMED xref found → use entity_key
--     ENGINE xref found    → use entity_key (VENDOR_ONLY)
--     No xref found        → create VENDOR_ONLY entity + ENGINE xref entry
--                            (replaces ENTITY_NOT_FOUND quarantine)
--   udm_company_xref:
--     match_status  CONFIRMED | ENGINE | SUPERSEDED
--     CONFIRMED = MDM validated
--     ENGINE    = auto-created by harmonisation engine for unknown vendor entity
--     SUPERSEDED = closed when MDM redirects to different entity_key
--
-- PROCESS RUN / LINEAGE (v8)
--   udm_process_run: NEW — one row per end-to-end delivery cycle
--     All steps (manifest, load, arb, DQ) FK to process_run_id
--   udm_lineage: revised
--     process_run_id FK → udm_process_run
--     step_sequence: 1=MANIFEST 2=LOAD 3=GRAIN_ALIGN 4=ARBITRATION 5=DI_CHECK
--
-- BI-TEMPORAL STACK (v8)
--   udm_{domain}_stk template carries FOUR date columns:
--   SOURCE TRANSACTION TIME (from source system):
--     src_bgn_tran_dt  when this data became effective IN THE SOURCE
--     src_end_tran_dt  when superseded in source; 9999-12-31 if still current
--   UDM TRANSACTION TIME (UDM's own version tracking):
--     bgn_tran_dt      when this row became current IN UDM
--     end_tran_dt      when superseded in UDM; 9999-12-31 if still current
--     cur_fl           1=current in UDM, 0=superseded
--   Both axes are needed for restatement queries:
--     "As of Nov 2022" → DATE '2022-11-22' BETWEEN src_bgn_tran_dt AND src_end_tran_dt
--     "As of Jan 2024" → DATE '2024-01-15' BETWEEN src_bgn_tran_dt AND src_end_tran_dt
--   These are the same BETWEEN pattern as RDM source tables — intentional.
--
-- udm_stk_current_v: NEW view — convenience for consumers wanting current data
-- =============================================================================


-- =============================================================================
-- SECTION 1 — SEQUENCES (35)
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
CREATE SEQUENCE udm_process_run_seq   START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_manifest_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_lineage_seq       START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_quarantine_seq    START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_dq_result_seq     START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_suppress_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_review_seq        START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_metric_seq        START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_join_map_seq      START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_grain_compat_seq  START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE udm_stk_version_seq   START WITH 1       INCREMENT BY 1 NOCACHE NOCYCLE;
-- ★ NEW v9 — for udm_stk_version (Option A bridge table)
-- GTT sequences: no sequence needed (rows deleted on commit)
-- 2 GTT objects counted in table inventory, 0 sequences


-- =============================================================================
-- SECTION 2 — SOURCE SYSTEM CATALOG
-- =============================================================================

CREATE TABLE udm_source_system (
    source_system_cd    VARCHAR2(50)    NOT NULL,
    source_system_name  VARCHAR2(200)   NOT NULL,
    source_system_type  VARCHAR2(20)    NOT NULL,
    -- VENDOR | INTERNAL | RDM | UDM_DERIVED
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
COMMENT ON TABLE  udm_source_system IS 'Governed source system catalog. vendor_id throughout UDM FKs here. Seeded from DW.src_sys_dim.';
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
    -- COLUMNAR | EAV
    currency_mechanism          VARCHAR2(20)    NOT NULL,
    -- CURRENT_FLAG | EFFECTIVE_DATES | MAX_SNAPSHOT_DATE | ALWAYS_CURRENT | LOAD_DATE
    current_flag_column         VARCHAR2(128),
    effective_to_column         VARCHAR2(128),
    time_key_column             VARCHAR2(128),
    entity_id_col               VARCHAR2(128)   NOT NULL,
    time_col                    VARCHAR2(128)   NOT NULL,
    storage_pattern             VARCHAR2(20)    NOT NULL,
    -- MATERIALISED | VIRTUAL
    source_role                 VARCHAR2(20)    DEFAULT 'DATA_SOURCE' NOT NULL,
    -- DATA_SOURCE | REFERENCE_SOURCE
    subject_type                VARCHAR2(20)    DEFAULT 'ENTITY'      NOT NULL,
    -- ENTITY | SPATIAL | INTERNAL_ID
    domain_grain                VARCHAR2(100),
    governance_status           VARCHAR2(20)    NOT NULL,
    -- STAGE_ONLY | RDM_ONLY | MIGRATING | UDM_CATALOGED | DEPRECATED | RETIRED
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
COMMENT ON TABLE  udm_source_registry IS 'Single inventory of entire data estate.';
COMMENT ON COLUMN udm_source_registry.currency_mechanism IS
    'CURRENT_FLAG: filter by current_flag_column=Y. '
    'EFFECTIVE_DATES: SCD2 effective_to_column IS NULL. '
    'MAX_SNAPSHOT_DATE: MAX(time_key_column) per entity. '
    'ALWAYS_CURRENT: no history tracking. '
    'LOAD_DATE: MAX(load_date) per entity.';


-- =============================================================================
-- SECTION 4 — DATA ITEM (metric registry, SCD2)
-- Governed dictionary of every business data concept UDM manages.
-- Source-agnostic — exists independently of any delivery mechanism.
-- ONE physical home per data item (phy_trgt_tbl_nm). Never duplicated.
-- mtrc_grp_tx matches udm_precedence_rules.mtrc_grp_tx for group overrides.
-- SCD2: scd_2_ky = row PK (changes each version)
--        scd_1_ky = concept identity (stable — all child FKs use this)
-- =============================================================================

CREATE TABLE udm_data_item (
    data_itm_scd_2_ky       NUMBER(32)      NOT NULL,
    data_itm_scd_1_ky       NUMBER(32)      NOT NULL,
    data_itm_id             VARCHAR2(100),
    -- Business code for display/API/cross-system reference only. NOT a FK target.
    data_itm_nm             VARCHAR2(128)   NOT NULL,
    -- Oracle column name in stack/arb. e.g. scope1_mtco2
    data_itm_de_tx          VARCHAR2(500),
    cncl_nm                 VARCHAR2(128),
    domn_ky                 VARCHAR2(50)    NOT NULL,
    mtrc_grp_tx             VARCHAR2(100),
    -- Matches udm_precedence_rules.mtrc_grp_tx for group-level overrides
    mtrc_txnmy_cd           VARCHAR2(128),
    mtrc_typ_cd             VARCHAR2(10),
    -- QNTT=sum it | QLTT=rank/categorise | INDC=boolean flag
    phy_trgt_tbl_nm         VARCHAR2(128)   NOT NULL,
    -- ONE stack table per data item. Engine writes here only.
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
                data_itm_nm||'|'||domn_ky||'|'||NVL(phy_trgt_tbl_nm,'')||'|'||
                data_typ_cd||'|'||NVL(mtrc_typ_cd,''),'SHA256'))
        ) VIRTUAL,
    CONSTRAINT pk_udm_data_item         PRIMARY KEY (data_itm_scd_2_ky),
    CONSTRAINT uq_data_item_id          UNIQUE (data_itm_id),
    CONSTRAINT uq_data_item_nm_tgt_eff  UNIQUE (data_itm_nm, phy_trgt_tbl_nm, bgn_tran_dt),
    CONSTRAINT chk_data_typ_cd          CHECK (data_typ_cd IN ('VARCHAR','NUMBER','DATE','TIMESTAMP','BOOLEAN')),
    CONSTRAINT chk_mtrc_typ_cd          CHECK (mtrc_typ_cd IS NULL OR mtrc_typ_cd IN ('QNTT','QLTT','INDC')),
    CONSTRAINT chk_di_is_subj_ky        CHECK (is_subj_ky IN ('Y','N')),
    CONSTRAINT chk_di_is_time_ky        CHECK (is_time_ky IN ('Y','N')),
    CONSTRAINT chk_di_is_mndty          CHECK (is_mndty_fl IN ('Y','N')),
    CONSTRAINT chk_di_cur_fl            CHECK (cur_fl IN (0,1)),
    CONSTRAINT chk_di_row_stat          CHECK (row_stat_cd IN ('ACTIVE','PENDING_RETIREMENT','RETIRED'))
);
CREATE INDEX idx_data_item_scd1   ON udm_data_item (data_itm_scd_1_ky, cur_fl);
CREATE INDEX idx_data_item_domain ON udm_data_item (domn_ky, cur_fl);
CREATE INDEX idx_data_item_target ON udm_data_item (phy_trgt_tbl_nm, cur_fl);
CREATE INDEX idx_data_item_id     ON udm_data_item (data_itm_id);

COMMENT ON TABLE  udm_data_item IS 'DATA ITEM registry. Governed business concept. SCD2. ONE physical home per item.';
COMMENT ON COLUMN udm_data_item.data_itm_scd_1_ky IS 'Concept identity. Stable forever. ALL child table FKs use this (logical — not physical due to SCD2).';
COMMENT ON COLUMN udm_data_item.data_itm_id IS 'Business code for display/API only. NOT a FK target anywhere. Database always joins on scd_1_ky.';
COMMENT ON COLUMN udm_data_item.mtrc_grp_tx IS 'Matches udm_precedence_rules.mtrc_grp_tx. Activates group-level precedence overrides in arbitration.';
COMMENT ON COLUMN udm_data_item.mtrc_typ_cd IS 'QNTT=can be summed. QLTT=ordinal/categorical. INDC=boolean flag. Orthogonal to data_typ_cd. BI layer reads to determine aggregation.';
COMMENT ON COLUMN udm_data_item.row_chk_sum_tx IS 'Virtual. SHA256 change detection hash. Zero storage cost.';


-- =============================================================================
-- SECTION 5 — DATA ITEM TAXONOMY
-- Axis+node classification per data item. Many-to-many.
-- Logical FK to data_itm_scd_1_ky (not physical — SCD2 not unique per row).
-- Drives reporting VIEW generation — not physical storage routing.
-- One metric can have multiple SUB_DOMAIN rows (overlapping metrics).
-- =============================================================================

CREATE TABLE udm_data_item_taxonomy (
    taxonomy_id             NUMBER(32)      NOT NULL,
    data_itm_scd_1_ky       NUMBER(32)      NOT NULL,
    -- LOGICAL FK → udm_data_item.data_itm_scd_1_ky
    axis                    VARCHAR2(20)    NOT NULL,
    -- DOMAIN | SUB_DOMAIN | THEME | SCOPE | CATEGORY | METRIC_TYPE
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

COMMENT ON TABLE udm_data_item_taxonomy IS 'Axis+node classification. Logical FK to SCD1_KY. Drives VIEW generation. Overlapping metrics have multiple SUB_DOMAIN rows.';


-- =============================================================================
-- SECTION 6 — DATA ITEM SOURCE MAP
-- One row per (data item × source).
-- Logical FK to data_itm_scd_1_ky.
-- Engine processes is_derived_fl=N first (Pass 1), then Y (Pass 2).
-- =============================================================================

CREATE TABLE udm_data_item_src_map (
    map_id                  NUMBER(32)      NOT NULL,
    data_itm_scd_1_ky       NUMBER(32)      NOT NULL,
    -- LOGICAL FK → udm_data_item.data_itm_scd_1_ky
    source_id               VARCHAR2(20),
    -- FK → udm_source_registry. NULL when is_derived_fl=Y
    attr_src_nm             VARCHAR2(128),
    -- Physical source column. NULL when is_derived_fl=Y
    is_derived_fl           VARCHAR2(1)     DEFAULT 'N' NOT NULL,
    -- Y = computed from other data items. Engine: N first (Pass 1), Y second (Pass 2).
    attr_xfrm_ru_tx         VARCHAR2(200),
    -- direct|lookup|coalesce|rule_ref|derive_cs|flag|multiply|divide
    attr_unit_from_tx       VARCHAR2(140),
    -- static 'tCO2' | 'col:UNIT_COL' (COLUMNAR only) | NULL
    attr_unit_eav_ky        VARCHAR2(200),
    -- EAV sibling row key. Mutually exclusive with col: prefix.
    attr_nm_col_tx          VARCHAR2(128),
    attr_nm_val_tx          VARCHAR2(200),
    attr_val_col_tx         VARCHAR2(128),
    attr_val_typ_cd         VARCHAR2(20),
    -- EAV value cast: NUMBER|DATE|VARCHAR|BOOLEAN
    map_stat_cd             VARCHAR2(30)    DEFAULT 'ACTIVE' NOT NULL,
    -- ACTIVE | PENDING_RETIREMENT | RETIRED
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
        OR (is_derived_fl='Y' AND source_id IS NULL AND attr_src_nm IS NULL)),
    CONSTRAINT chk_di_src_derived_rule   CHECK (
        is_derived_fl='N'
        OR attr_xfrm_ru_tx LIKE 'coalesce:%'
        OR attr_xfrm_ru_tx LIKE 'rule_ref:%'
        OR attr_xfrm_ru_tx LIKE 'flag:%'
        OR attr_xfrm_ru_tx LIKE 'derive_cs:%'),
    CONSTRAINT chk_di_src_map_stat       CHECK (map_stat_cd IN ('ACTIVE','PENDING_RETIREMENT','RETIRED')),
    CONSTRAINT chk_di_src_eav_cols       CHECK (
        (attr_nm_col_tx IS NULL AND attr_nm_val_tx IS NULL AND attr_val_col_tx IS NULL)
        OR (attr_nm_col_tx IS NOT NULL AND attr_nm_val_tx IS NOT NULL AND attr_val_col_tx IS NOT NULL)),
    CONSTRAINT chk_di_src_eav_key_eav    CHECK (attr_unit_eav_ky IS NULL OR attr_nm_col_tx IS NOT NULL),
    CONSTRAINT chk_di_src_col_prefix     CHECK (SUBSTR(attr_unit_from_tx,1,4) != 'col:' OR attr_nm_col_tx IS NULL),
    CONSTRAINT chk_di_src_unit_excl      CHECK (NOT (attr_unit_eav_ky IS NOT NULL AND SUBSTR(attr_unit_from_tx,1,4)='col:'))
);
CREATE INDEX idx_di_src_scd1   ON udm_data_item_src_map (data_itm_scd_1_ky, map_stat_cd);
CREATE INDEX idx_di_src_source ON udm_data_item_src_map (source_id, map_stat_cd);
CREATE INDEX idx_di_src_deriv  ON udm_data_item_src_map (source_id, is_derived_fl);

COMMENT ON TABLE udm_data_item_src_map IS 'Source mapping. Logical FK to SCD1_KY. is_derived_fl=N: Pass 1 (source attributes). Y: Pass 2 (derived canonical items).';
COMMENT ON COLUMN udm_data_item_src_map.attr_unit_from_tx IS 'Static: tCO2. Column ref: col:SCOPE1_UNIT (COLUMNAR only). NULL: no conversion. Unit metadata — never in domain tables.';


-- =============================================================================
-- SECTION 7 — TRANSFORM RULES
-- =============================================================================

CREATE TABLE udm_transform_rules (
    rule_id             VARCHAR2(20)    NOT NULL,
    rule_name           VARCHAR2(100)   NOT NULL,
    resolution_sql      VARCHAR2(2000)  NOT NULL,
    -- {data_itm_nm} placeholders substituted by engine
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
-- SECTION 8 — PRECEDENCE RULES (all three arbitration modes)
-- MODE 1 SIMPLE:        entity_scope=CLIENT, period_scope=CURRENT (defaults)
-- MODE 2 METRIC GROUP:  mtrc_grp_tx IS NOT NULL — group overrides domain level
-- MODE 3 ENTITY SCOPE:  entity_scope=PARENT / period_scope=PRIOR_YEAR
-- Engine reads all active rules per domain in one query.
-- ROW_NUMBER() OVER (PARTITION BY entity ORDER BY priority ASC) selects winner.
-- NEVER DELETE rows — close with end_tran_dt. Arb rows reference rule_id.
-- =============================================================================

CREATE TABLE udm_precedence_rules (
    rule_id             VARCHAR2(20)    NOT NULL,
    domain_id           VARCHAR2(50)    NOT NULL,
    mtrc_grp_tx         VARCHAR2(100),
    -- NULL = all metrics in domain. Value = group override (matches data_item.mtrc_grp_tx)
    vendor_id           VARCHAR2(50)    NOT NULL,
    priority            NUMBER(3)       NOT NULL,
    -- 1 = highest. Group rules use lower numbers than domain rules for same vendor.
    condition_type      VARCHAR2(20)    NOT NULL,
    -- ALWAYS | CONDITIONAL
    condition_sql       VARCHAR2(500),
    entity_scope        VARCHAR2(15)    DEFAULT 'CLIENT'  NOT NULL,
    -- CLIENT: use the entity being arbitrated
    -- PARENT: use entity's parent from udm_entity_membership
    period_scope        VARCHAR2(15)    DEFAULT 'CURRENT' NOT NULL,
    -- CURRENT: target coverage period
    -- PRIOR_YEAR: ADD_MONTHS(target, -12) via udm_ref_time
    rule_label          VARCHAR2(200),
    -- Stamped on arb row. e.g. 'Level 3 — Parent / Current Period / Vendor 1'
    bgn_tran_dt         DATE            NOT NULL,
    end_tran_dt         DATE,
    -- NEVER DELETE — close with end_tran_dt
    created_by          VARCHAR2(50)    NOT NULL,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    modified_by         VARCHAR2(50),
    modified_date       DATE,
    CONSTRAINT pk_udm_precedence_rules   PRIMARY KEY (rule_id),
    CONSTRAINT uq_prec_priority          UNIQUE (domain_id, mtrc_grp_tx, entity_scope, period_scope, vendor_id, bgn_tran_dt),
    CONSTRAINT chk_prec_condition_type   CHECK (condition_type IN ('ALWAYS','CONDITIONAL')),
    CONSTRAINT chk_prec_condition_sql    CHECK (condition_type != 'CONDITIONAL' OR condition_sql IS NOT NULL),
    CONSTRAINT chk_prec_priority         CHECK (priority BETWEEN 1 AND 999),
    CONSTRAINT chk_prec_entity_scope     CHECK (entity_scope IN ('CLIENT','PARENT')),
    CONSTRAINT chk_prec_period_scope     CHECK (period_scope IN ('CURRENT','PRIOR_YEAR'))
);
CREATE INDEX idx_prec_domain_active ON udm_precedence_rules (domain_id, bgn_tran_dt, end_tran_dt);
CREATE INDEX idx_prec_group         ON udm_precedence_rules (domain_id, mtrc_grp_tx, entity_scope, period_scope);

COMMENT ON TABLE  udm_precedence_rules IS 'All three arb modes in one table. NEVER DELETE — close with end_tran_dt.';
COMMENT ON COLUMN udm_precedence_rules.entity_scope IS 'PARENT rules skipped by engine when no parent in entity_membership.';
COMMENT ON COLUMN udm_precedence_rules.period_scope IS 'PRIOR_YEAR rules skipped when prior period absent from udm_ref_time.';
COMMENT ON COLUMN udm_precedence_rules.rule_label IS 'Stamped on arb row metadata. Displayed in udm_arb_waterfall_v for PO review.';


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
    -- DIRECT|LAST_VALUE|FIRST_VALUE|AVERAGE|SUM|EXCLUDE|DISAGGREGATE
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
COMMENT ON TABLE udm_grain_alignment_rules IS 'SUM reads entity_membership COMPANY_COMPONENT. EXCLUDE: data preserved in stack, excluded from arbitration.';


-- =============================================================================
-- SECTION 10 — DQ RULES
-- =============================================================================

CREATE TABLE udm_dq_rules (
    rule_id             VARCHAR2(20)    NOT NULL,
    domain_id           VARCHAR2(50)    NOT NULL,
    data_itm_nm         VARCHAR2(128)   NOT NULL,
    check_type          VARCHAR2(20)    NOT NULL,
    -- DRIFT | BOUNDS | COMPLETENESS | CROSS_VENDOR
    threshold           NUMBER,
    min_value           NUMBER,
    max_value           NUMBER,
    action              VARCHAR2(20)    NOT NULL,
    -- ALERT | QUARANTINE | REJECT
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
COMMENT ON TABLE udm_dq_rules IS 'Threshold DQ checks only. Auto-derived checks generate from data_item + src_map at engine runtime.';


-- =============================================================================
-- SECTION 11 — ENTITY REGISTRY (★ EXTENDED in v8)
-- Identity only. No metrics. No vendor attributes.
-- entity_key = UDM sequence from 1,000,000 (avoids source PK collision).
-- source_key = original source PK (e.g. customer_bk) for ref table joins.
--
-- match_status lifecycle:
--   INTERNAL     Seeded from internal systems (CST_DIM, RDM). Has or may have
--                MDM-confirmed xref mappings to vendor IDs.
--   VENDOR_ONLY  Created by engine when vendor sends unknown entity ID with
--                no existing xref. Gets its own governed entity_key.
--                May be linked to INTERNAL entity later by MDM.
--                May remain VENDOR_ONLY permanently (e.g. public companies
--                not tracked internally).
--   MERGED       Was VENDOR_ONLY. MDM confirmed it maps to an INTERNAL entity.
--                merged_into_key points to the surviving INTERNAL entity_key.
--                is_active set to N. Retained for audit trail only.
--                Stack/arb rows reprocessed to merged_into_key.
--
-- vendor_id: populated for VENDOR_ONLY entities — which vendor first reported it.
-- merged_into_key: populated for MERGED entities — the surviving entity_key.
-- =============================================================================

CREATE TABLE udm_entity_registry (
    entity_key          VARCHAR2(20)    NOT NULL,
    -- UDM-generated from udm_entity_seq (starts 1,000,000)
    entity_type         VARCHAR2(20)    NOT NULL,
    -- COMPANY|SUPPLIER|COUNTERPARTY|PRODUCT|SECTOR|REGION|COUNTRY|COMPANY_SECTOR
    canonical_name      VARCHAR2(200)   NOT NULL,
    source_key          VARCHAR2(100),
    -- Original source PK (e.g. customer_bk from CST_DIM)
    -- Join: entity_registry.source_key = ref_table.natural_key
    -- NULL for VENDOR_ONLY and COMPANY_SECTOR entities
    match_status        VARCHAR2(15)    DEFAULT 'INTERNAL' NOT NULL,
    -- INTERNAL | VENDOR_ONLY | MERGED
    vendor_id           VARCHAR2(50),
    -- Populated for VENDOR_ONLY — which vendor first reported this entity
    merged_into_key     VARCHAR2(20),
    -- Populated for MERGED — points to surviving INTERNAL entity_key
    is_active           CHAR(1)         DEFAULT 'Y' NOT NULL,
    -- N for MERGED entities (audit trail only)
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    modified_date       DATE,
    notes               VARCHAR2(500),
    CONSTRAINT pk_udm_entity_registry   PRIMARY KEY (entity_key),
    CONSTRAINT fk_entity_merged_into    FOREIGN KEY (merged_into_key) REFERENCES udm_entity_registry (entity_key),
    CONSTRAINT chk_entity_type          CHECK (entity_type IN ('COMPANY','SUPPLIER','COUNTERPARTY','PRODUCT','SECTOR','REGION','COUNTRY','COMPANY_SECTOR')),
    CONSTRAINT chk_entity_match_status  CHECK (match_status IN ('INTERNAL','VENDOR_ONLY','MERGED')),
    CONSTRAINT chk_entity_merged_key    CHECK (match_status != 'MERGED' OR merged_into_key IS NOT NULL),
    CONSTRAINT chk_entity_active        CHECK (is_active IN ('Y','N'))
);
CREATE INDEX idx_entity_type_active  ON udm_entity_registry (entity_type, is_active, match_status);
CREATE INDEX idx_entity_source_key   ON udm_entity_registry (entity_type, source_key);
CREATE INDEX idx_entity_match_status ON udm_entity_registry (match_status, vendor_id);
-- supports: find all VENDOR_ONLY entities for a given vendor

COMMENT ON TABLE  udm_entity_registry IS 'Identity only. entity_key = UDM seq from 1,000,000. Three lifecycle states: INTERNAL/VENDOR_ONLY/MERGED.';
COMMENT ON COLUMN udm_entity_registry.match_status IS 'INTERNAL: from internal systems. VENDOR_ONLY: engine-created, unknown to MDM. MERGED: was VENDOR_ONLY, now linked to INTERNAL.';
COMMENT ON COLUMN udm_entity_registry.source_key IS 'Join: entity_registry.source_key = ref_table.natural_key. NOT entity_key — ref tables carry no entity_key FK.';
COMMENT ON COLUMN udm_entity_registry.vendor_id IS 'Populated for VENDOR_ONLY entities. Which vendor first reported this entity.';
COMMENT ON COLUMN udm_entity_registry.merged_into_key IS 'Populated for MERGED. Points to surviving INTERNAL entity_key. Stack rows reprocessed to this key.';


-- =============================================================================
-- SECTION 12 — COMPANY CROSS-REFERENCE (★ EXTENDED in v8)
-- Maps vendor entity identifiers to UDM entity_key.
-- Three match_status values track the full lifecycle:
--   CONFIRMED    MDM validated. May point to INTERNAL or VENDOR_ONLY entity_key.
--   ENGINE       Auto-created by harmonisation engine when vendor sends unknown
--                entity ID. Points to a VENDOR_ONLY entity_key.
--                Upgraded to CONFIRMED when MDM validates.
--                Closed (SUPERSEDED) when MDM redirects to different entity_key.
--   SUPERSEDED   Closed entry. effective_to set. Retained for audit.
-- Engine lookup priority:
--   1. CONFIRMED xref effective_to IS NULL → use entity_key
--   2. ENGINE xref effective_to IS NULL    → use entity_key (VENDOR_ONLY)
--   3. No active xref                      → create VENDOR_ONLY entity + ENGINE xref
-- =============================================================================

CREATE TABLE udm_company_xref (
    xref_id             VARCHAR2(20)    NOT NULL,
    entity_key          VARCHAR2(20)    NOT NULL,
    vendor_id           VARCHAR2(50)    NOT NULL,
    external_id         VARCHAR2(100)   NOT NULL,
    -- The vendor's raw identifier for this entity
    match_status        VARCHAR2(15)    DEFAULT 'CONFIRMED' NOT NULL,
    -- CONFIRMED | ENGINE | SUPERSEDED
    effective_from      DATE            NOT NULL,
    effective_to        DATE,
    -- NULL = currently active. Set when SUPERSEDED.
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_company_xref          PRIMARY KEY (xref_id),
    CONSTRAINT fk_co_xref_entity            FOREIGN KEY (entity_key) REFERENCES udm_entity_registry (entity_key),
    CONSTRAINT fk_co_xref_src_sys           FOREIGN KEY (vendor_id)  REFERENCES udm_source_system (source_system_cd),
    CONSTRAINT uq_co_xref_vendor_external   UNIQUE (vendor_id, external_id, effective_from),
    CONSTRAINT chk_xref_match_status        CHECK (match_status IN ('CONFIRMED','ENGINE','SUPERSEDED'))
);
CREATE INDEX idx_co_xref_lookup ON udm_company_xref (vendor_id, external_id, effective_to, match_status);
-- Hot path: WHERE vendor_id=:v AND external_id=:e AND effective_to IS NULL
-- AND match_status IN ('CONFIRMED','ENGINE') — finds active entries in one seek

COMMENT ON TABLE  udm_company_xref IS 'Maps vendor entity IDs to UDM entity_key. ENGINE entries auto-created for unknown vendors. Upgraded to CONFIRMED by MDM.';
COMMENT ON COLUMN udm_company_xref.match_status IS 'CONFIRMED: MDM validated. ENGINE: auto-created by harmonisation engine. SUPERSEDED: closed, retained for audit.';
COMMENT ON COLUMN udm_company_xref.effective_to IS 'NULL = currently active. Set when entry is SUPERSEDED by MDM redirect.';


-- =============================================================================
-- SECTION 13 — ENTITY MEMBERSHIP
-- =============================================================================

CREATE TABLE udm_entity_membership (
    membership_id       VARCHAR2(20)    NOT NULL,
    entity_key          VARCHAR2(20)    NOT NULL,
    parent_entity_key   VARCHAR2(20)    NOT NULL,
    relationship_type   VARCHAR2(30)    NOT NULL,
    -- COMPANY_COMPONENT|SECTOR_COMPONENT|SECTOR_MEMBERSHIP|REGION_MEMBERSHIP
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

COMMENT ON TABLE udm_entity_membership IS
    'Three uses: (1) Grain alignment — SUM reads COMPANY_COMPONENT to roll COMPANY_SECTOR→COMPANY. '
    '(2) Arbitration PARENT scope rules — engine reads COMPANY_COMPONENT to find parent_entity_key. '
    '(3) BI enrichment — sector/region hierarchy traversal.';


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
COMMENT ON TABLE udm_spatial_asset_registry IS '40M+ assets. geohash LIKE prefix enables regional filter without spatial computation.';


-- =============================================================================
-- SECTION 15 — SOURCE ROUTING MAP
-- =============================================================================

CREATE TABLE udm_ref_source_map (
    ref_map_id              VARCHAR2(20)    NOT NULL,
    source_id               VARCHAR2(20)    NOT NULL,
    ref_table_name          VARCHAR2(128)   NOT NULL,
    refresh_strategy        VARCHAR2(25)    NOT NULL,
    -- FULL_REPLACE | INCREMENTAL | EFFECTIVE_DATE_MERGE
    ref_natural_key_cols    VARCHAR2(200)   NOT NULL,
    creates_entity          CHAR(1)         DEFAULT 'N' NOT NULL,
    -- Y = engine seeds entity_registry as side effect of REFERENCE_SOURCE load
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
    CONSTRAINT chk_ref_entity_type_valid    CHECK (entity_type IS NULL OR entity_type IN
        ('COMPANY','SUPPLIER','COUNTERPARTY','PRODUCT','SECTOR','REGION','COUNTRY','COMPANY_SECTOR')),
    CONSTRAINT chk_ref_active               CHECK (is_active IN ('Y','N'))
);
COMMENT ON TABLE udm_ref_source_map IS 'REFERENCE_SOURCE routing. creates_entity=Y seeds entity_registry as side effect. Replaces udm_identity_source_map.';


-- =============================================================================
-- SECTION 16 — REFERENCE TABLES (natural keys only — no entity_key FK)
-- Join pattern: entity_registry.source_key = ref_table.natural_key
-- =============================================================================

CREATE TABLE udm_ref_company (
    ref_company_key     VARCHAR2(20)    NOT NULL,
    company_source_key  VARCHAR2(100)   NOT NULL,  -- natural key = CST_ID from CST_DIM
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
COMMENT ON TABLE udm_ref_company IS 'Natural key: company_source_key (=CST_ID). Join: entity_registry.source_key = company_source_key.';

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
    classification_system   VARCHAR2(50)    NOT NULL,  -- NAICS|GICS|SIC|NACE|INTERNAL
    class_code              VARCHAR2(50)    NOT NULL,
    class_name              VARCHAR2(200)   NOT NULL,
    class_level             NUMBER(2),
    parent_class_code       VARCHAR2(50),   -- self-ref natural key; no FK — avoids bulk load locks
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
    region_cd           VARCHAR2(10)    NOT NULL,  -- EMEA|APAC|AMER|ROW
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
    iso_country_cd      VARCHAR2(3)     NOT NULL,  -- ISO 3166 alpha-3
    country_name        VARCHAR2(200)   NOT NULL,
    region_cd           VARCHAR2(10),   -- natural key ref to udm_ref_region; no FK
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
    period_value        VARCHAR2(20)    NOT NULL,  -- coverage_period string e.g. FY2024
    period_grain        VARCHAR2(10)    NOT NULL,  -- DAY|WEEK|MONTH|QTR|ANNUAL
    calendar_type       VARCHAR2(20)    NOT NULL,  -- GREGORIAN|FISCAL|REGULATORY
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
-- idx_ref_time_start_date: supports ADD_MONTHS(-12) prior period join in arb engine
COMMENT ON TABLE udm_ref_time IS 'Standalone fiscal calendar. idx_ref_time_start_date supports arbitration prior period lookup.';


-- =============================================================================
-- SECTION 17 — PROCESS RUN (★ NEW in v8)
-- Parent record for every end-to-end delivery or processing cycle.
-- All pipeline steps (manifest, load, arb, DQ) are child records via lineage.
-- One process_run_id ties together the full lifecycle of one delivery.
-- =============================================================================

CREATE TABLE udm_process_run (
    process_run_id      VARCHAR2(30)    NOT NULL,
    -- Format: RUN-YYYYMMDD-NNNNN
    domain_id           VARCHAR2(50)    NOT NULL,
    coverage_period     VARCHAR2(20)    NOT NULL,
    vendor_id           VARCHAR2(50),
    -- NULL for multi-vendor processes (arbitration covers all vendors)
    process_type        VARCHAR2(20)    NOT NULL,
    -- VENDOR_DELIVERY   full cycle: manifest → load → arb → DQ
    -- REPROCESSING      triggered by PO review queue resolution
    -- MIGRATION         historical period load during migration phase
    -- ARBITRATION_ONLY  arb re-run without new data
    run_status          VARCHAR2(20)    NOT NULL,
    -- RUNNING | COMPLETE | FAILED | PARTIAL
    initiated_by        VARCHAR2(100)   NOT NULL,
    -- SCHEDULER | PO_REPROCESS | MIGRATION_JOB | MANUAL
    started_at          DATE,
    completed_at        DATE,
    duration_secs       NUMBER GENERATED ALWAYS AS
                            (ROUND((completed_at - started_at) * 86400)) VIRTUAL,
    total_entities      NUMBER,
    entities_resolved   NUMBER,
    entities_unresolved NUMBER,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_process_run   PRIMARY KEY (process_run_id),
    CONSTRAINT chk_process_type     CHECK (process_type IN ('VENDOR_DELIVERY','REPROCESSING','MIGRATION','ARBITRATION_ONLY')),
    CONSTRAINT chk_process_run_stat CHECK (run_status IN ('RUNNING','COMPLETE','FAILED','PARTIAL'))
);
CREATE INDEX idx_process_run_domain ON udm_process_run (domain_id, coverage_period, run_status);
CREATE INDEX idx_process_run_vendor ON udm_process_run (vendor_id, coverage_period);

COMMENT ON TABLE  udm_process_run IS 'Parent record per end-to-end delivery. All pipeline steps FK here via process_run_id. Single identifier to trace full lifecycle of one delivery.';
COMMENT ON COLUMN udm_process_run.duration_secs IS 'Virtual. Zero storage. For SLA monitoring.';


-- =============================================================================
-- SECTION 18 — DELIVERY MANIFEST
-- Step 1 of every VENDOR_DELIVERY process run.
-- Gates step 2 (load) on status = COMPLETE.
-- =============================================================================

CREATE TABLE udm_delivery_manifest (
    manifest_id         VARCHAR2(30)    NOT NULL,
    -- Format: MAN-YYYYMMDD-NNNNN
    process_run_id      VARCHAR2(30)    NOT NULL,
    -- FK → udm_process_run — ties manifest to its parent run
    source_id           VARCHAR2(20)    NOT NULL,
    vendor_id           VARCHAR2(50)    NOT NULL,
    coverage_period     VARCHAR2(20)    NOT NULL,
    expected_files      NUMBER(5)       NOT NULL,
    files_received      NUMBER(5)       DEFAULT 0  NOT NULL,
    status              VARCHAR2(20)    DEFAULT 'PARTIAL' NOT NULL,
    -- PARTIAL | COMPLETE | FAILED | SUPERSEDED
    received_at         DATE            DEFAULT SYSDATE NOT NULL,
    completed_at        DATE,
    notes               VARCHAR2(500),
    CONSTRAINT pk_udm_delivery_manifest   PRIMARY KEY (manifest_id),
    CONSTRAINT fk_manifest_process_run    FOREIGN KEY (process_run_id) REFERENCES udm_process_run (process_run_id),
    CONSTRAINT fk_manifest_source         FOREIGN KEY (source_id) REFERENCES udm_source_registry (source_id),
    CONSTRAINT chk_manifest_status        CHECK (status IN ('PARTIAL','COMPLETE','FAILED','SUPERSEDED')),
    CONSTRAINT chk_manifest_files         CHECK (files_received <= expected_files OR status = 'FAILED')
);
CREATE INDEX idx_manifest_vendor_period ON udm_delivery_manifest (vendor_id, coverage_period, status);
CREATE INDEX idx_manifest_process_run   ON udm_delivery_manifest (process_run_id);

COMMENT ON TABLE udm_delivery_manifest IS 'Step 1 of VENDOR_DELIVERY run. Gates step 2 (load) on COMPLETE. FK to udm_process_run.';


-- =============================================================================
-- SECTION 19 — LINEAGE (★ REVISED in v8 — step-level, FK to process_run)
-- One row per processing STEP within a process run.
-- step_sequence: 1=MANIFEST 2=LOAD 3=GRAIN_ALIGN 4=ARBITRATION 5=DI_CHECK
-- All domain table rows (stk, arb, quarantine, dq_results) carry lineage_id
-- which traces them to their specific processing step.
-- Partitioned monthly.
-- =============================================================================

CREATE TABLE udm_lineage (
    lineage_id          VARCHAR2(30)    NOT NULL,
    -- Format: LIN-YYYYMMDD-NNNNN
    process_run_id      VARCHAR2(30)    NOT NULL,
    -- FK → udm_process_run — parent end-to-end run
    step_sequence       NUMBER(3)       NOT NULL,
    -- 1=MANIFEST 2=LOAD 3=GRAIN_ALIGN 4=ARBITRATION 5=DI_CHECK
    lineage_type        VARCHAR2(20)    NOT NULL,
    -- MANIFEST | LOAD | GRAIN_ALIGN | ARBITRATION | DI_CHECK
    source_id           VARCHAR2(20),
    -- FK → udm_source_registry. NULL for ARBITRATION (covers multiple sources)
    domain_id           VARCHAR2(50),
    vendor_id           VARCHAR2(50),
    coverage_period     VARCHAR2(20),
    rows_read           NUMBER,
    rows_written        NUMBER,
    rows_rejected       NUMBER,
    rows_quarantined    NUMBER,
    started_at          DATE,
    completed_at        DATE,
    duration_secs       NUMBER GENERATED ALWAYS AS
                            (ROUND((completed_at - started_at) * 86400)) VIRTUAL,
    step_status         VARCHAR2(20)    NOT NULL,
    -- RUNNING | COMPLETE | FAILED | SKIPPED
    error_message       VARCHAR2(2000),
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_lineage            PRIMARY KEY (lineage_id),
    CONSTRAINT fk_lineage_process_run    FOREIGN KEY (process_run_id) REFERENCES udm_process_run (process_run_id),
    CONSTRAINT chk_lineage_type          CHECK (lineage_type IN ('MANIFEST','LOAD','GRAIN_ALIGN','ARBITRATION','DI_CHECK')),
    CONSTRAINT chk_lineage_step_status   CHECK (step_status IN ('RUNNING','COMPLETE','FAILED','SKIPPED'))
)
PARTITION BY RANGE (created_date)
INTERVAL (NUMTOYMINTERVAL(1,'MONTH'))
( PARTITION p_lineage_initial VALUES LESS THAN (DATE '2024-01-01') );

CREATE INDEX idx_lineage_run     ON udm_lineage (process_run_id, step_sequence) LOCAL;
CREATE INDEX idx_lineage_domain  ON udm_lineage (domain_id, coverage_period, lineage_type) LOCAL;
CREATE INDEX idx_lineage_status  ON udm_lineage (step_status, created_date) LOCAL;

COMMENT ON TABLE  udm_lineage IS 'Step-level audit. One row per processing step within a process_run. FK to udm_process_run. All domain rows carry lineage_id.';
COMMENT ON COLUMN udm_lineage.step_sequence IS '1=MANIFEST 2=LOAD 3=GRAIN_ALIGN 4=ARBITRATION 5=DI_CHECK. Ordered within a run.';


-- =============================================================================
-- SECTION 20 — QUARANTINE (partitioned monthly)
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
    -- DATA_TYPE|NOT_NULL|BOUNDS|UNMAPPED_ATTRIBUTE|REFERENTIAL
    -- NOTE: ENTITY_NOT_FOUND no longer applies — engine creates VENDOR_ONLY entity
    rejection_reason    VARCHAR2(500)   NOT NULL,
    quarantined_at      DATE            DEFAULT SYSDATE NOT NULL,
    resolved_flag       CHAR(1)         DEFAULT 'N' NOT NULL,
    resolved_at         DATE,
    resolved_by         VARCHAR2(50),
    resolution_notes    VARCHAR2(500),
    CONSTRAINT pk_udm_quarantine        PRIMARY KEY (quarantine_id),
    CONSTRAINT fk_quarantine_lineage    FOREIGN KEY (lineage_id) REFERENCES udm_lineage (lineage_id),
    CONSTRAINT fk_quarantine_source     FOREIGN KEY (source_id)  REFERENCES udm_source_registry (source_id),
    CONSTRAINT chk_quarantine_type      CHECK (check_type IN ('DATA_TYPE','NOT_NULL','BOUNDS','UNMAPPED_ATTRIBUTE','REFERENTIAL')),
    CONSTRAINT chk_quarantine_resolved  CHECK (resolved_flag IN ('Y','N'))
)
PARTITION BY RANGE (quarantined_at)
INTERVAL (NUMTOYMINTERVAL(1,'MONTH'))
( PARTITION p_quarantine_initial VALUES LESS THAN (DATE '2024-01-01') );

CREATE INDEX idx_quarantine_source     ON udm_quarantine (source_id, coverage_period, resolved_flag) LOCAL;
CREATE INDEX idx_quarantine_unresolved ON udm_quarantine (resolved_flag, quarantined_at) LOCAL;
CREATE INDEX idx_qrn_lineage_entity    ON udm_quarantine (lineage_id, entity_id_raw, resolved_flag) LOCAL;
-- idx_qrn_lineage_entity: supports arbitration quarantine exclusion subquery

COMMENT ON COLUMN udm_quarantine.check_type IS 'ENTITY_NOT_FOUND removed — engine creates VENDOR_ONLY entity instead of quarantining.';


-- =============================================================================
-- SECTION 21 — DQ RESULTS (partitioned monthly)
-- =============================================================================

CREATE TABLE udm_dq_results (
    result_id           VARCHAR2(30)    NOT NULL,
    lineage_id          VARCHAR2(30)    NOT NULL,
    rule_id             VARCHAR2(20),
    check_type          VARCHAR2(30)    NOT NULL,
    check_source        VARCHAR2(20)    NOT NULL,  -- AUTO_DERIVED | CONFIGURED
    domain_id           VARCHAR2(50)    NOT NULL,
    source_id           VARCHAR2(20),
    data_itm_nm         VARCHAR2(128),
    movement_point      VARCHAR2(20)    NOT NULL,
    -- STAGE_TO_VS | VS_TO_ARB | ARB_TO_DIST
    check_result        VARCHAR2(10)    NOT NULL,  -- PASS | FAIL | WARNING
    actual_value        NUMBER,
    expected_value      NUMBER,
    entity_key          VARCHAR2(20),
    coverage_period     VARCHAR2(20),
    action_taken        VARCHAR2(20)    NOT NULL,  -- ALERT | QUARANTINE | REJECT | NONE
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
-- SECTION 22 — DETECTION SUPPRESSIONS
-- =============================================================================

CREATE TABLE udm_detection_suppressions (
    suppression_id      VARCHAR2(20)    NOT NULL,
    suppression_type    VARCHAR2(30)    NOT NULL,
    -- COLUMN_IGNORE | TABLE_NOT_APPLICABLE | EAV_VALUE_REJECTED | ALREADY_MAPPED
    source_schema       VARCHAR2(30)    NOT NULL,
    source_table        VARCHAR2(128)   NOT NULL,
    column_name         VARCHAR2(128),
    attribute_value     VARCHAR2(200),
    suppression_reason  VARCHAR2(100)   NOT NULL,
    suppressed_by       VARCHAR2(50)    NOT NULL,
    suppressed_date     DATE            NOT NULL,
    effective_from_env  VARCHAR2(10)    NOT NULL,  -- DEV | TEST | PROD
    release_version     VARCHAR2(20),
    notes               VARCHAR2(500),
    CONSTRAINT pk_udm_detect_suppress  PRIMARY KEY (suppression_id),
    CONSTRAINT chk_suppress_type       CHECK (suppression_type IN ('COLUMN_IGNORE','TABLE_NOT_APPLICABLE','EAV_VALUE_REJECTED','ALREADY_MAPPED')),
    CONSTRAINT chk_suppress_env        CHECK (effective_from_env IN ('DEV','TEST','PROD')),
    CONSTRAINT uq_suppress_natural     UNIQUE (suppression_type, source_schema, source_table, column_name, attribute_value)
);
CREATE INDEX idx_suppress_table ON udm_detection_suppressions (source_schema, source_table);


-- =============================================================================
-- SECTION 23 — ARBITRATION REVIEW QUEUE
-- =============================================================================

CREATE TABLE udm_arb_review_queue (
    review_id           VARCHAR2(30)    NOT NULL,
    -- Format: REV-YYYYMMDD-NNNNN
    domain_id           VARCHAR2(50)    NOT NULL,
    entity_key          VARCHAR2(20)    NOT NULL,
    coverage_period     VARCHAR2(20)    NOT NULL,
    data_itm_scd_1_ky   NUMBER(32)      NOT NULL,
    -- LOGICAL FK → udm_data_item.data_itm_scd_1_ky
    review_reason       VARCHAR2(500)   NOT NULL,
    review_stat_cd      VARCHAR2(20)    DEFAULT 'PENDING' NOT NULL,
    -- PENDING | IN_REVIEW | RESOLVED | SUPPRESSED
    parent_entity_key   VARCHAR2(20),
    -- NULL = entity structurally has no parent
    prior_period        VARCHAR2(20),
    -- NULL = prior period not in udm_ref_time
    resolution_action   VARCHAR2(500),
    resolved_by         VARCHAR2(100),
    resolved_date       DATE,
    created_date        DATE            DEFAULT SYSDATE NOT NULL,
    lineage_id          VARCHAR2(30),
    CONSTRAINT pk_arb_review_queue    PRIMARY KEY (review_id),
    CONSTRAINT uq_review_entity_item  UNIQUE (entity_key, coverage_period, data_itm_scd_1_ky),
    CONSTRAINT chk_review_stat        CHECK (review_stat_cd IN ('PENDING','IN_REVIEW','RESOLVED','SUPPRESSED'))
);
CREATE INDEX idx_review_pending ON udm_arb_review_queue (review_stat_cd, domain_id, coverage_period);
CREATE INDEX idx_review_entity  ON udm_arb_review_queue (entity_key, coverage_period);

COMMENT ON TABLE udm_arb_review_queue IS 'Unresolved arb cases. MERGE on re-run prevents duplicates. PO resolves → triggers reprocessing.';


-- =============================================================================
-- SECTION 24 — SEMANTIC / BI CATALOG
-- =============================================================================

CREATE TABLE udm_metric_catalog (
    metric_id               VARCHAR2(20)    NOT NULL,
    domain_id               VARCHAR2(50)    NOT NULL,
    data_itm_scd_1_ky       NUMBER(32),
    -- LOGICAL FK → udm_data_item.data_itm_scd_1_ky
    metric_name             VARCHAR2(200)   NOT NULL,
    physical_table          VARCHAR2(128)   NOT NULL,
    physical_column         VARCHAR2(128)   NOT NULL,
    canonical_key_col       VARCHAR2(128)   NOT NULL,
    canonical_time_col      VARCHAR2(128)   NOT NULL,
    aggregation             VARCHAR2(20)    NOT NULL,
    -- SUM | AVG | MAX | MIN | LAST | COUNT
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
    join_type               VARCHAR2(10)    NOT NULL,  -- INNER | LEFT | FULL
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
-- SECTION 25 — GLOBAL TEMPORARY TABLES (arbitration engine)
-- ON COMMIT DELETE ROWS — session-scoped. No cleanup between runs.
-- Created once in schema. Each session has private copy of data.
-- =============================================================================

CREATE GLOBAL TEMPORARY TABLE udm_arb_candidates_gtt (
    target_entity_key   VARCHAR2(20)    NOT NULL,
    data_itm_nm         VARCHAR2(128)   NOT NULL,
    data_itm_scd_1_ky   NUMBER(32)      NOT NULL,
    candidate_value     NUMBER,
    source_vendor       VARCHAR2(50)    NOT NULL,
    stack_entity_key    VARCHAR2(20)    NOT NULL,
    stack_period        VARCHAR2(20)    NOT NULL,
    rule_id             VARCHAR2(20)    NOT NULL,
    effective_priority  NUMBER(3)       NOT NULL,
    entity_scope        VARCHAR2(15)    NOT NULL,
    period_scope        VARCHAR2(15)    NOT NULL,
    rule_label          VARCHAR2(200),
    dq_score            NUMBER(5,2)     NOT NULL,
    stk_lineage_id      VARCHAR2(30)
) ON COMMIT DELETE ROWS;
CREATE INDEX idx_arb_cand_gtt ON udm_arb_candidates_gtt (target_entity_key, data_itm_nm, effective_priority);

COMMENT ON TABLE udm_arb_candidates_gtt IS 'GTT: all qualified candidates for current arb run. Populated by step_fetch_candidates() — one INSERT...SELECT. Quality gate inline.';

CREATE GLOBAL TEMPORARY TABLE udm_arb_resolved_gtt (
    target_entity_key   VARCHAR2(20)    NOT NULL,
    data_itm_nm         VARCHAR2(128)   NOT NULL,
    data_itm_scd_1_ky   NUMBER(32)      NOT NULL,
    resolved_value      NUMBER,
    -- NULL = UNRESLVD
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
    -- RESOLVED | CARRIED_FWD | UNRESLVD
) ON COMMIT DELETE ROWS;
CREATE INDEX idx_arb_res_gtt ON udm_arb_resolved_gtt (target_entity_key, data_itm_nm);

COMMENT ON TABLE udm_arb_resolved_gtt IS 'GTT: one winner per entity per metric after ROW_NUMBER ranking. UNRESLVD rows queued in arb_review_queue.';


-- =============================================================================
-- SECTION 26 — VIEWS
-- =============================================================================

-- Data item lineage — surfaces data item + source map as column lineage graph
CREATE OR REPLACE VIEW udm_data_item_lineage AS
SELECT
    di.domn_ky              AS domain_id,
    di.data_itm_scd_1_ky,
    di.data_itm_id,
    di.data_itm_nm,
    di.data_itm_de_tx       AS data_item_label,
    di.data_typ_cd,
    di.data_itm_trgt_unit_tx AS canonical_unit,
    di.mtrc_typ_cd,
    di.mtrc_grp_tx,
    di.phy_trgt_tbl_nm,
    di.is_subj_ky,
    di.is_time_ky,
    di.is_mndty_fl,
    sr.vendor_id,
    sr.source_schema,
    sr.source_table,
    sm.attr_src_nm          AS source_attribute,
    sm.is_derived_fl,
    sm.attr_xfrm_ru_tx      AS transform_rule,
    sm.attr_unit_from_tx    AS unit_from,
    sm.attr_unit_eav_ky     AS unit_from_eav_key,
    sm.map_stat_cd,
    sr.governance_status    AS source_status,
    sm.bgn_tran_dt,
    sm.end_tran_dt
FROM    udm_data_item            di
JOIN    udm_data_item_src_map    sm  ON sm.data_itm_scd_1_ky = di.data_itm_scd_1_ky
                                    AND sm.map_stat_cd IN ('ACTIVE','PENDING_RETIREMENT')
LEFT JOIN udm_source_registry    sr  ON sr.source_id = sm.source_id
WHERE   di.cur_fl = 1;

COMMENT ON TABLE udm_data_item_lineage IS 'Column lineage. Joins current data item to all source mappings. Auditor: source attribute X → data item Y and reverse.';


-- Arbitration waterfall configuration display
CREATE OR REPLACE VIEW udm_arb_waterfall_v AS
SELECT
    pr.domain_id,
    pr.rule_id,
    pr.priority,
    pr.entity_scope,
    pr.period_scope,
    pr.vendor_id,
    pr.mtrc_grp_tx,
    CASE WHEN pr.mtrc_grp_tx IS NULL THEN 'DOMAIN-LEVEL'
         ELSE 'GROUP: '||pr.mtrc_grp_tx END AS rule_scope,
    pr.condition_type,
    pr.condition_sql,
    pr.rule_label,
    pr.bgn_tran_dt,
    pr.end_tran_dt,
    CASE WHEN pr.end_tran_dt IS NULL OR pr.end_tran_dt >= SYSDATE
         THEN 'ACTIVE' ELSE 'EXPIRED' END   AS rule_status,
    (SELECT COUNT(*) FROM udm_data_item di
     WHERE  di.domn_ky = pr.domain_id AND di.cur_fl = 1
     AND    (pr.mtrc_grp_tx IS NULL OR di.mtrc_grp_tx = pr.mtrc_grp_tx)
    ) AS applicable_item_count
FROM    udm_precedence_rules pr
ORDER BY pr.domain_id, pr.mtrc_grp_tx NULLS FIRST,
         pr.entity_scope, pr.period_scope, pr.priority;

COMMENT ON TABLE udm_arb_waterfall_v IS 'Waterfall config per domain. PO reviews before arb runs. Shows all three precedence modes and applicable item count per rule.';


-- Stack current convenience view — bi-temporal current rows with entity context
-- Used by consumers who want current data without managing four date columns.
-- Replace {domain} with actual sub-domain name at domain onboarding.
-- Template only — instantiated per sub-domain as udm_{sub_domain}_stk_current_v
CREATE OR REPLACE VIEW udm_stk_current_v AS
SELECT
    stk.*,
    er.canonical_name       AS entity_name,
    er.entity_type,
    er.match_status         AS entity_match_status
-- FROM   udm_{sub_domain}_stk  stk          ← replace at onboarding
-- JOIN   udm_entity_registry    er ON er.entity_key = stk.entity_key
-- WHERE  stk.cur_fl = 1                      ← current UDM version
-- AND    stk.src_end_tran_dt = DATE '9999-12-31'  ← current source version
FROM   dual
WHERE  1 = 0;  -- placeholder — replaced at domain onboarding

COMMENT ON TABLE udm_stk_current_v IS 'Template. Instantiated per sub-domain at onboarding. Returns current stack rows with entity context. Filter: cur_fl=1 AND src_end_tran_dt=9999-12-31.';


-- =============================================================================
-- SECTION 27 — DOMAIN TABLE TEMPLATES
-- Created at domain onboarding — NOT part of Tier 1.
-- Shown here as DDL templates for reference.
-- Replace {sub_domain} with actual sub-domain name.
-- =============================================================================

/*
-- ─────────────────────────────────────────────────────────────────────────────
-- udm_{sub_domain}_stk  — VENDOR STACK TABLE (bi-temporal)
-- ─────────────────────────────────────────────────────────────────────────────
-- BI-TEMPORAL DESIGN:
-- SOURCE TRANSACTION TIME (from source system):
--   src_bgn_tran_dt  when this data became effective in the SOURCE
--   src_end_tran_dt  when superseded in source; 9999-12-31 if still current
-- UDM TRANSACTION TIME (UDM's own version tracking):
--   bgn_tran_dt      when this row became current IN UDM
--   end_tran_dt      when superseded in UDM; 9999-12-31 if current
--   cur_fl           1=current in UDM, 0=superseded
--
-- POINT-IN-TIME QUERIES:
--   "Value as of Nov 2022 in source":
--     WHERE DATE '2022-11-22' BETWEEN src_bgn_tran_dt AND src_end_tran_dt
--     AND   cur_fl = 1
--   "What UDM held before a redelivery":
--     WHERE coverage_period = 'FY2022'
--     AND   DATE '2024-06-01' BETWEEN bgn_tran_dt AND end_tran_dt
--
-- MIGRATION:
--   src_bgn_tran_dt  = rdm.bgn_tran_dt (carry exactly from RDM SCD2)
--   src_end_tran_dt  = rdm.end_tran_dt (carry exactly from RDM SCD2)
--   For SNAPSHOT sources: src_end_tran_dt = next_snapshot_date - 1
--   Migrate ALL SCD2 versions, not just current — historical BETWEEN queries
--   require all versions to be present.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE udm_{sub_domain}_stk (

    -- ── Identity ──────────────────────────────────────────────────────────────
    entity_key          VARCHAR2(20)    NOT NULL,   -- → udm_entity_registry
    source_id           VARCHAR2(20)    NOT NULL,   -- → udm_source_registry
    coverage_period     VARCHAR2(20)    NOT NULL,   -- business reporting period

    -- ── SOURCE TRANSACTION TIME ────────────────────────────────────────────────
    src_bgn_tran_dt     DATE            NOT NULL,
    -- When effective in source. Carry rdm.bgn_tran_dt for RDM sources.
    -- For SNAPSHOT: the snapshot date.
    src_end_tran_dt     DATE            NOT NULL,
    -- When superseded in source. Carry rdm.end_tran_dt for RDM SCD2.
    -- For SNAPSHOT: next snapshot date - 1 (LEAD function during migration).
    -- 9999-12-31 = still current in source.

    -- ── UDM TRANSACTION TIME ──────────────────────────────────────────────────
    bgn_tran_dt         DATE            NOT NULL,
    -- SYSDATE at INSERT. When this row became current in UDM.
    end_tran_dt         DATE            DEFAULT DATE '9999-12-31' NOT NULL,
    -- 9999-12-31 = currently active. Set to SYSDATE-1 on re-delivery.
    cur_fl              NUMBER(1)       DEFAULT 1 NOT NULL,
    -- 1=current, 0=superseded by re-delivery or correction.

    -- ── Load audit ────────────────────────────────────────────────────────────
    load_dt             DATE            NOT NULL,   -- SYSDATE at physical INSERT
    migration_fl        CHAR(1)         NOT NULL,   -- Y=migrated, N=live delivery
    data_version        NUMBER(5)       NOT NULL,   -- 1,2,3... increments on re-delivery

    -- ── Constituent data items (is_derived_fl=N — Pass 1) ────────────────────
    scope1_direct       NUMBER,                     -- primary source attribute
    scope1_estimated    NUMBER,                     -- fallback source attribute

    -- ── Derived canonical data items (is_derived_fl=Y — Pass 2) ─────────────
    scope1_mtco2        NUMBER,                     -- coalesced canonical (unit converted)
    scope1_source_flag  VARCHAR2(20),               -- DIRECT|ESTIMATED — flag: transform
    scope2_mtco2        NUMBER,
    -- ... all other domain metrics

    -- ── Lineage ───────────────────────────────────────────────────────────────
    lineage_id          VARCHAR2(30)    NOT NULL,   -- → udm_lineage (LOAD step)

    CONSTRAINT pk_{sub_domain}_stk  PRIMARY KEY (entity_key, source_id, coverage_period, src_bgn_tran_dt, bgn_tran_dt),
    CONSTRAINT chk_stk_cur_fl       CHECK (cur_fl IN (0,1)),
    CONSTRAINT chk_stk_migration_fl CHECK (migration_fl IN ('Y','N'))
)
PARTITION BY RANGE (coverage_period)
( PARTITION p_stk_pre2020 VALUES LESS THAN ('2020')
  ... -- partitions by year
);

CREATE INDEX idx_{sub_domain}_stk_entity  ON udm_{sub_domain}_stk (entity_key, coverage_period, cur_fl);
CREATE INDEX idx_{sub_domain}_stk_src_blt ON udm_{sub_domain}_stk (entity_key, coverage_period, src_bgn_tran_dt, src_end_tran_dt);
-- Supports: DATE :p BETWEEN src_bgn_tran_dt AND src_end_tran_dt
CREATE INDEX idx_{sub_domain}_stk_udm_blt ON udm_{sub_domain}_stk (entity_key, coverage_period, bgn_tran_dt, end_tran_dt);
-- Supports: DATE :p BETWEEN bgn_tran_dt AND end_tran_dt


-- ─────────────────────────────────────────────────────────────────────────────
-- udm_{sub_domain}_arb  — ARBITRATION / GOLDEN SOURCE TABLE
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE udm_{sub_domain}_arb (

    entity_key              VARCHAR2(20)    NOT NULL,
    coverage_period         VARCHAR2(20)    NOT NULL,
    entity_type             VARCHAR2(20)    NOT NULL,
    measurement_grain       VARCHAR2(100)   NOT NULL,

    -- ── Golden copy metric ────────────────────────────────────────────────────
    scope1_mtco2            NUMBER,         -- NULL when arb_stat_cd = UNRESLVD

    -- ── Per-metric arbitration metadata ──────────────────────────────────────
    scope1_arb_rule_id      VARCHAR2(20),   -- → udm_precedence_rules
    scope1_arb_lvl_nb       NUMBER(3),      -- waterfall level number (priority)
    scope1_arb_lvl_tx       VARCHAR2(200),  -- rule_label from precedence_rules
    scope1_arb_vendor_id    VARCHAR2(50),   -- winning vendor
    scope1_arb_entity_ky    VARCHAR2(20),   -- entity whose data resolved (client or parent)
    scope1_arb_period_tx    VARCHAR2(20),   -- period used (current or prior year)
    scope1_arb_src_val      NUMBER,         -- raw value before any post-arb transform
    scope1_arb_dq_score_nb  NUMBER(5,2),    -- quality score of resolved candidate (0-100)
    scope1_arb_stat_cd      VARCHAR2(20),
    -- RESOLVED    current period value found
    -- CARRIED_FWD prior year value used (period_scope=PRIOR_YEAR)
    -- UNRESLVD    all waterfall levels exhausted
    -- SUPPRESSED  PO acknowledged as unavoidable

    -- ── Row governance ────────────────────────────────────────────────────────
    is_current              CHAR(1)         NOT NULL,
    arbitrated_at           DATE            NOT NULL,
    lineage_id              VARCHAR2(30),   -- → udm_lineage (ARBITRATION step)

    CONSTRAINT pk_{sub_domain}_arb  PRIMARY KEY (entity_key, coverage_period),
    CONSTRAINT chk_arb_stat CHECK (scope1_arb_stat_cd IN ('RESOLVED','CARRIED_FWD','UNRESLVD','SUPPRESSED'))
);
*/


-- =============================================================================
-- SECTION 27 — DOMAIN STACK TEMPORAL — OPTION A: BRIDGE TABLE (★ NEW in v9)
-- =============================================================================
-- udm_stk_version — source and UDM temporal metadata per load version
-- ─────────────────────────────────────────────────────────────────────────────
-- STATUS: OPTION A — Available as an alternative design at domain onboarding.
--         Not the adopted platform default. Option B (dates on stack) is
--         the default. Teams may choose this design where the mandatory join
--         cost is acceptable and a simpler fact table schema is preferred.
--
-- DESIGN INTENT:
--   Normalises all temporal metadata into one row per load version.
--   The stack fact table carries only stk_version_id (FK here).
--   All point-in-time and version queries join to this table.
--
-- ONE ROW PER:
--   entity_key × source_id × coverage_period × source_version
--   where source_version increments when the same entity+period is redelivered
--   from the same source, or when a new SCD2 version arrives from the source.
--
-- SOURCE_TYPE handling:
--   SCD2      source has explicit bgn/end dates. Carry from source exactly.
--             src_bgn_dt = rdm.bgn_tran_dt, src_end_dt = rdm.end_tran_dt
--   SNAPSHOT  source is a point-in-time cut. Derive end from next snapshot.
--             src_bgn_dt = snapshot_date
--             src_end_dt = LEAD(next_snapshot_date) - 1 via LEAD() at load time
--                          DATE '9999-12-31' if no next snapshot exists
--   Registered on udm_source_registry.currency_mechanism — not on this table.
--   source_type here is a copy for consumer convenience only.
--
-- UDM TRANSACTION TIME:
--   bgn_tran_dt   SYSDATE at INSERT — when UDM held this version
--   end_tran_dt   DATE '9999-12-31' initially
--                 Set to SYSDATE-1 when re-delivery supersedes this version
--   cur_fl        1=current in UDM, 0=superseded
--
-- RE-DELIVERY PATTERN (one UPDATE closes all metrics atomically):
--   UPDATE udm_stk_version
--   SET    end_tran_dt = SYSDATE - (1/86400),
--          cur_fl      = 0
--   WHERE  entity_key      = :v_entity_key
--   AND    source_id       = :v_source_id
--   AND    coverage_period = :v_period
--   AND    cur_fl          = 1;
--   -- Then INSERT new version row
--   -- Then INSERT new stack metric rows pointing to new stk_version_id
--
-- POINT-IN-TIME QUERY PATTERN (Option A — requires JOIN):
--   "Value as of Nov 22 2022 in source":
--   SELECT stk.*
--   FROM   udm_{domain}_stk  stk
--   JOIN   udm_stk_version    v ON v.stk_version_id = stk.stk_version_id
--   WHERE  DATE '2022-11-22' BETWEEN v.src_bgn_dt AND v.src_end_dt
--   AND    v.cur_fl = 1;
--
-- COMPARISON WITH OPTION B (dates on stack):
--   Option A: JOIN required. Bridge has same cardinality as stack.
--             One UPDATE closes version for all metrics simultaneously.
--             Fact table is simpler — no date columns on metric rows.
--   Option B: No JOIN for temporal queries. Four dates on every stack row.
--             UPDATE closes per entity per vendor per period — still set-based.
--             Query pattern identical to RDM BETWEEN pattern.
-- =============================================================================

CREATE TABLE udm_stk_version (
    stk_version_id      VARCHAR2(20)    NOT NULL,
    -- Format: STV-NNNNN from udm_stk_version_seq
    -- Unique per load version. FK target for stack fact tables (Option A only).

    -- ── Subject identity ─────────────────────────────────────────────────────
    entity_key          VARCHAR2(20)    NOT NULL,
    -- FK → udm_entity_registry
    source_id           VARCHAR2(20)    NOT NULL,
    -- FK → udm_source_registry
    coverage_period     VARCHAR2(20)    NOT NULL,
    -- Business reporting period. e.g. FY2024

    -- ── Source type (convenience copy — authoritative value on source_registry)
    source_type         VARCHAR2(10)    NOT NULL,
    -- SCD2      source has explicit effective dates
    -- SNAPSHOT  source is a point-in-time cut
    -- Used by consumers to know which temporal columns apply for this version.

    -- ── SOURCE TRANSACTION TIME (from source system — NEVER changes after INSERT)
    src_bgn_dt          DATE            NOT NULL,
    -- SCD2:     rdm.bgn_tran_dt carried exactly
    -- SNAPSHOT: the snapshot cut date
    src_end_dt          DATE            NOT NULL,
    -- SCD2:     rdm.end_tran_dt carried exactly
    -- SNAPSHOT: LEAD(next_snapshot_date) - 1; DATE '9999-12-31' if last snapshot
    -- Query pattern: DATE :as_of BETWEEN src_bgn_dt AND src_end_dt

    -- ── UDM TRANSACTION TIME (UDM's own version tracking)
    bgn_tran_dt         DATE            NOT NULL,
    -- SYSDATE at INSERT. When this version became current in UDM.
    -- NEVER changes after INSERT.
    end_tran_dt         DATE            DEFAULT DATE '9999-12-31' NOT NULL,
    -- DATE '9999-12-31' when inserted (open — currently active).
    -- Set to SYSDATE - (1/86400) when a re-delivery supersedes this version.
    cur_fl              NUMBER(1)       DEFAULT 1 NOT NULL,
    -- 1 = currently active in UDM. 0 = superseded by a later delivery.
    -- Updated atomically with end_tran_dt on re-delivery.

    -- ── Load audit ────────────────────────────────────────────────────────────
    load_dt             DATE            NOT NULL,
    -- SYSDATE at physical INSERT. Separate from bgn_tran_dt — bgn_tran_dt
    -- may be set to a business date in correction scenarios; load_dt
    -- is always the physical clock time of the INSERT.
    migration_fl        CHAR(1)         NOT NULL,
    -- Y = loaded during historical migration from RDM
    -- N = loaded via live vendor delivery
    data_version        NUMBER(5)       NOT NULL,
    -- 1 on first load. Increments on each re-delivery for this
    -- entity × source × coverage_period combination.
    -- Enables: SELECT MAX(data_version) to find latest delivery.

    -- ── Lineage ───────────────────────────────────────────────────────────────
    lineage_id          VARCHAR2(30),
    -- FK → udm_lineage (LOAD step lineage_id)

    CONSTRAINT pk_udm_stk_version       PRIMARY KEY (stk_version_id),
    CONSTRAINT fk_stk_ver_entity        FOREIGN KEY (entity_key)
        REFERENCES udm_entity_registry (entity_key),
    CONSTRAINT fk_stk_ver_source        FOREIGN KEY (source_id)
        REFERENCES udm_source_registry (source_id),
    CONSTRAINT chk_stk_ver_source_type  CHECK (source_type IN ('SCD2','SNAPSHOT')),
    CONSTRAINT chk_stk_ver_cur_fl       CHECK (cur_fl IN (0,1)),
    CONSTRAINT chk_stk_ver_mig_fl       CHECK (migration_fl IN ('Y','N')),
    CONSTRAINT chk_stk_ver_src_end      CHECK (src_end_dt >= src_bgn_dt),
    CONSTRAINT chk_stk_ver_udm_end      CHECK (end_tran_dt >= bgn_tran_dt)
);

-- ── Primary lookup: entity + period + currency ─────────────────────────────
-- Hot path for harmonisation engine: find active version on load.
CREATE INDEX idx_stk_ver_entity_period ON udm_stk_version
    (entity_key, source_id, coverage_period, cur_fl);

-- ── Point-in-time source query: DATE :as_of BETWEEN src_bgn_dt AND src_end_dt
CREATE INDEX idx_stk_ver_src_blt ON udm_stk_version
    (entity_key, coverage_period, src_bgn_dt, src_end_dt, cur_fl);

-- ── UDM version query: DATE :as_of BETWEEN bgn_tran_dt AND end_tran_dt
CREATE INDEX idx_stk_ver_udm_blt ON udm_stk_version
    (entity_key, coverage_period, bgn_tran_dt, end_tran_dt);

-- ── Migration audit: find all migrated versions for a domain
CREATE INDEX idx_stk_ver_migration ON udm_stk_version
    (source_id, coverage_period, migration_fl, cur_fl);

COMMENT ON TABLE  udm_stk_version IS
    'OPTION A — bridge table for domain stack temporal metadata. '
    'Alternative to Option B (four dates on stack row). '
    'Platform default is Option B. Choose once at domain onboarding. '
    'One row per entity × source × coverage_period × load version. '
    'Re-delivery: UPDATE end_tran_dt + cur_fl on old row, INSERT new row, '
    'INSERT new metric rows with new stk_version_id.';
COMMENT ON COLUMN udm_stk_version.source_type IS
    'SCD2: explicit effective dates in src_bgn_dt/src_end_dt. '
    'SNAPSHOT: snapshot date in src_bgn_dt; derived end in src_end_dt. '
    'Authoritative value is udm_source_registry.currency_mechanism.';
COMMENT ON COLUMN udm_stk_version.src_bgn_dt IS
    'SCD2: rdm.bgn_tran_dt carried exactly. '
    'SNAPSHOT: the snapshot cut date. '
    'NEVER changes after INSERT — reflects what the source declared.';
COMMENT ON COLUMN udm_stk_version.src_end_dt IS
    'SCD2: rdm.end_tran_dt carried exactly. '
    'SNAPSHOT: LEAD(next_snapshot_date)-1; 9999-12-31 if last snapshot. '
    'NEVER changes after INSERT — reflects what the source declared.';
COMMENT ON COLUMN udm_stk_version.bgn_tran_dt IS
    'SYSDATE at INSERT. When this version became current in UDM. '
    'Never changes after INSERT.';
COMMENT ON COLUMN udm_stk_version.end_tran_dt IS
    '9999-12-31 when inserted. Set to SYSDATE-1 on re-delivery. '
    'Updated atomically with cur_fl.';
COMMENT ON COLUMN udm_stk_version.data_version IS
    '1 on first load. Increments per re-delivery for this '
    'entity × source × coverage_period combination.';

-- ─────────────────────────────────────────────────────────────────────────────
-- OPTION A — STACK TABLE TEMPLATE (if udm_stk_version is chosen at onboarding)
-- ─────────────────────────────────────────────────────────────────────────────
-- When using Option A, the domain stack table carries stk_version_id (FK)
-- instead of the four date columns. The fact table is simpler but every
-- temporal query requires a JOIN to udm_stk_version.
-- ─────────────────────────────────────────────────────────────────────────────
/*
CREATE TABLE udm_{sub_domain}_stk_a (

    -- ── Identity ──────────────────────────────────────────────────────────────
    entity_key          VARCHAR2(20)    NOT NULL,   -- → udm_entity_registry
    stk_version_id      VARCHAR2(20)    NOT NULL,   -- → udm_stk_version (temporal FK)
    coverage_period     VARCHAR2(20)    NOT NULL,
    -- coverage_period denormalised from stk_version for partition key.
    -- Must match stk_version.coverage_period — CHECK or trigger enforced.

    -- ── Constituent data items (Pass 1 — is_derived_fl=N) ────────────────────
    scope1_direct       NUMBER,
    scope1_estimated    NUMBER,

    -- ── Derived canonical data items (Pass 2 — is_derived_fl=Y) ─────────────
    scope1_mtco2        NUMBER,
    scope1_source_flag  VARCHAR2(20),

    -- ... all other domain metrics

    -- ── Lineage ───────────────────────────────────────────────────────────────
    lineage_id          VARCHAR2(30)    NOT NULL,   -- → udm_lineage (LOAD step)

    CONSTRAINT pk_{sub_domain}_stk_a
        PRIMARY KEY (entity_key, stk_version_id),
    CONSTRAINT fk_stk_a_version
        FOREIGN KEY (stk_version_id) REFERENCES udm_stk_version (stk_version_id)
)
PARTITION BY RANGE (coverage_period) ...;

-- Index on stk_version_id to support the JOIN from temporal queries
CREATE INDEX idx_{domain}_stk_a_version
    ON udm_{sub_domain}_stk_a (stk_version_id);

-- Primary entity+period lookup still needed for arb engine
CREATE INDEX idx_{domain}_stk_a_entity
    ON udm_{sub_domain}_stk_a (entity_key, coverage_period)
    COMPRESS 1;

-- ── HOW CONSUMERS QUERY OPTION A (point-in-time — requires JOIN) ─────────────
--
-- "Value as of Nov 22 2022 in source":
-- SELECT stk.scope1_mtco2, v.src_bgn_dt, v.src_end_dt
-- FROM   udm_{domain}_stk_a   stk
-- JOIN   udm_stk_version        v  ON v.stk_version_id = stk.stk_version_id
-- WHERE  stk.entity_key = 'ENT-1000001'
-- AND    stk.coverage_period = 'FY2022'
-- AND    DATE '2022-11-22' BETWEEN v.src_bgn_dt AND v.src_end_dt
-- AND    v.cur_fl = 1;
--
-- "Current value only":
-- SELECT stk.scope1_mtco2
-- FROM   udm_{domain}_stk_a   stk
-- JOIN   udm_stk_version        v  ON v.stk_version_id = stk.stk_version_id
-- WHERE  stk.entity_key = 'ENT-1000001'
-- AND    stk.coverage_period = 'FY2022'
-- AND    v.cur_fl = 1
-- AND    v.src_end_dt = DATE '9999-12-31';
*/


-- =============================================================================
-- SECTION 28 — ROLE-BASED GRANTS (uncomment and adjust role names)
-- =============================================================================

-- udm_engine_role (harmonisation + arbitration)
-- GRANT SELECT         ON udm_source_system              TO udm_engine_role;
-- GRANT SELECT         ON udm_source_registry            TO udm_engine_role;
-- GRANT SELECT         ON udm_data_item                  TO udm_engine_role;
-- GRANT SELECT         ON udm_data_item_taxonomy         TO udm_engine_role;
-- GRANT SELECT         ON udm_data_item_src_map          TO udm_engine_role;
-- GRANT SELECT         ON udm_transform_rules            TO udm_engine_role;
-- GRANT SELECT         ON udm_precedence_rules           TO udm_engine_role;
-- GRANT SELECT         ON udm_grain_alignment_rules      TO udm_engine_role;
-- GRANT SELECT         ON udm_dq_rules                   TO udm_engine_role;
-- GRANT SELECT         ON udm_entity_registry            TO udm_engine_role;
-- GRANT SELECT         ON udm_company_xref               TO udm_engine_role;
-- GRANT SELECT         ON udm_entity_membership          TO udm_engine_role;
-- GRANT SELECT         ON udm_ref_source_map             TO udm_engine_role;
-- GRANT SELECT         ON udm_ref_time                   TO udm_engine_role;
-- GRANT SELECT         ON udm_quarantine                 TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_entity_registry            TO udm_engine_role;
-- GRANT INSERT         ON udm_entity_membership          TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_company_xref               TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_company                TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_sector                 TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_region                 TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_country                TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_product                TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_ref_time                   TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_process_run                TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_delivery_manifest          TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_lineage                    TO udm_engine_role;
-- GRANT INSERT         ON udm_quarantine                 TO udm_engine_role;
-- GRANT INSERT         ON udm_dq_results                 TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_arb_review_queue           TO udm_engine_role;
-- GRANT SELECT         ON udm_stk_version                TO udm_engine_role;
-- GRANT INSERT, UPDATE ON udm_stk_version                TO udm_engine_role;
-- (udm_stk_version only needed when Option A is chosen at domain onboarding)

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
-- GRANT SELECT ON udm_stk_current_v       TO udm_consumer_role;
-- GRANT SELECT ON udm_metric_catalog      TO udm_consumer_role;
-- GRANT SELECT ON udm_domain_join_map     TO udm_consumer_role;
-- GRANT SELECT ON udm_grain_compatibility TO udm_consumer_role;
-- (add SELECT on udm_{sub_domain}_arb, stk, and _v as created at onboarding)


-- =============================================================================
-- END — UDM TIER 1 DDL COMPLETE FINAL v9
-- ─────────────────────────────────────────────────────────────────────────────
-- OBJECT COUNTS
--   Sequences : 34  (udm_stk_version_seq ★ NEW in v9)
--   Tables    : 36  (udm_stk_version ★ NEW in v9; incl 2 GTTs)
--   Views     : 3   (data_item_lineage, arb_waterfall_v, stk_current_v template)
-- ─────────────────────────────────────────────────────────────────────────────
-- KEY CHANGES FROM v8
--
-- udm_stk_version  : NEW — Option A bridge table for source + UDM temporal metadata.
--                    Provided as alternative design — NOT the adopted default.
--                    Option B (dates on stack) remains the platform default.
--                    udm_stk_version_seq added (sequence 34).
--                    Option A stack template included as commented DDL.
--                    Grants for udm_stk_version added to engine role (commented).
--
-- ─────────────────────────────────────────────────────────────────────────────
-- KEY CHANGES FROM v7 (retained for history)
--   udm_entity_registry    : +match_status +vendor_id +merged_into_key
--                            +idx_entity_match_status
--   udm_company_xref       : +match_status (CONFIRMED|ENGINE|SUPERSEDED)
--                            Engine creates ENGINE entry for unknown vendors
--                            instead of ENTITY_NOT_FOUND quarantine
--   udm_process_run        : NEW — parent record per end-to-end delivery
--   udm_delivery_manifest  : +process_run_id FK → udm_process_run
--                            lineage_id removed (lineage child of process_run)
--   udm_lineage            : +process_run_id FK → udm_process_run
--                            +step_sequence (1-5 ordered within run)
--                            lineage_type extended: +GRAIN_ALIGN
--   udm_quarantine         : ENTITY_NOT_FOUND removed from check_type
--   Domain stack template  : BI-TEMPORAL — 4 date columns:
--                            src_bgn_tran_dt, src_end_tran_dt (source time)
--                            bgn_tran_dt, end_tran_dt + cur_fl (UDM time)
--                            +load_dt, +migration_fl, +data_version
--                            +idx_stk_src_blt, +idx_stk_udm_blt
--   udm_stk_current_v      : NEW VIEW template
-- ─────────────────────────────────────────────────────────────────────────────
-- NOT IN TIER 1 (created at domain onboarding)
--   udm_company_sector_mv       materialised view for COMPANY_SECTOR lookup
--   udm_{sub_domain}_stk (12)  bi-temporal vendor stack — one per sub-domain
--   udm_{sub_domain}_arb (12)  golden source + arb metadata columns
--   udm_{sub_domain}_v   (12)  reporting views from taxonomy UNION ALL
--   udm_{sub_domain}_stk_current_v (12)  convenience current views
-- NOT IN TIER 1 (Module 2 — detection layer)
--   dsc_* (10 tables)
-- NOT IN TIER 1 (engine packages)
--   udm_hrm_engine   harmonisation engine PL/SQL package
--   udm_arb_engine   arbitration engine PL/SQL package (udm_arb_engine_v1.sql)
-- ─────────────────────────────────────────────────────────────────────────────
-- SEED DATA TASKS (mandatory before engine work begins)
--   1.  Seed udm_source_system from DW.src_sys_dim
--   2.  Register all sources in udm_source_registry
--   3.  Extract Option A precedence rules → udm_precedence_rules
--       (entity_scope=CLIENT, period_scope=CURRENT for existing rules)
--   4.  Add PARENT/PRIOR_YEAR waterfall rules to udm_precedence_rules
--   5.  REFERENCE_SOURCE loads with creates_entity=Y
--   6.  Migrate CST_XREF → udm_company_xref (match_status=CONFIRMED)
--   7.  Migrate CST_PTFOL_REF → udm_entity_membership (SECTOR_MEMBERSHIP)
--   8.  Load udm_ref_time for ALL periods (critical for prior period lookup)
--   9.  Seed udm_data_item (SCD1+SCD2) for all 274 metrics
--  10.  Seed udm_data_item_taxonomy (axis+node; SCD1_KY)
--  11.  Seed udm_data_item_src_map (source attribute → data item; SCD1_KY)
--  12.  Historical migration:
--       a. Load ALL SCD2 versions from RDM (not just current)
--       b. src_bgn_tran_dt = rdm.bgn_tran_dt, src_end_tran_dt = rdm.end_tran_dt
--       c. bgn_tran_dt = migration run date, migration_fl = Y
--  13.  Build view generation script (taxonomy → UNION ALL view DDL)
--  14.  First live DATA_SOURCE fact load
--  15.  First arbitration run: udm_arb_engine.run(domain, period, lineage_id)
-- =============================================================================
