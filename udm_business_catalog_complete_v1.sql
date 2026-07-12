-- =============================================================================
-- UDM BUSINESS EXPLORATION CATALOG + HARMONISATION METADATA -- COMPLETE v1
-- File: udm_business_catalog_complete_v1.sql
-- Self-contained, re-runnable. Consolidates:
--   PATTERN A -- STRUCTURE items (repeating scope/category/method targets;
--                CDP HEADER-form + ESGBook CATEGORY-form; OBS/STRUCT spine)
--   PATTERN B -- STACK items resolved from multiple raw columns (direct /
--                ratio / pct-change / delta; evidenced by page+comment;
--                NO OBS/STRUCT spine -- writes straight to existing flat cols)
--
-- NAMING RECONCILED to the org's established convention:
--   UDM_DATA_ITM_SRC_MAP       = STACK source mapping (existing convention)
--   UDM_DATA_ITM_SRC_COL_MAP   = STRUCTURE source mapping (existing convention)
--   UDM_DATA_ITM_SRC_COMPONENT_MAP = NEW: children of SRC_MAP for a STACK item
--                                     resolved from multiple raw components.
--                                     (SRC_MAP alone only covers 1 source col
--                                     -> 1 target col; this covers N -> 1.)
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED;

-- 0. Re-runnable cleanup ---------------------------------------------------------
BEGIN
  FOR r IN (
    SELECT obj FROM (
      SELECT 'VIEW  V_UDM_STACK_COMPONENT_CATALOG' obj FROM dual UNION ALL
      SELECT 'VIEW  V_UDM_SRC_TGT_LINEAGE'              FROM dual UNION ALL
      SELECT 'VIEW  V_UDM_STRUCT_CATALOG'                   FROM dual UNION ALL
      SELECT 'VIEW  V_STG_RESP_ARBITRATED'                      FROM dual UNION ALL
      SELECT 'VIEW  V_STG_RESP_RESOLVED'                            FROM dual UNION ALL
      SELECT 'VIEW  V_STG_RESP_SLOTTED'                                FROM dual UNION ALL
      SELECT 'TABLE UDM_STG_RESP_RAW'                                     FROM dual UNION ALL
      SELECT 'TABLE UDM_SOURCE_PRIORITY'                                     FROM dual UNION ALL
      SELECT 'TABLE UDM_STD_RESP_EVID'                                         FROM dual UNION ALL
      SELECT 'TABLE UDM_DATA_ITM_SRC_COMPONENT_MAP'                               FROM dual UNION ALL
      SELECT 'TABLE UDM_DATA_ITM_SRC_MAP'                                            FROM dual UNION ALL
      SELECT 'TABLE UDM_RESP_SLOT_DOMAIN'                                               FROM dual UNION ALL
      SELECT 'TABLE UDM_DATA_ITM_SRC_COL_MAP'                                              FROM dual UNION ALL
      SELECT 'TABLE UDM_STRUCT_STORAGE_MAP'                                                   FROM dual UNION ALL
      SELECT 'TABLE UDM_DATA_ITM_ELMT'                                                           FROM dual UNION ALL
      SELECT 'TABLE UDM_TRGT_MTRC_DOMAIN'                                                           FROM dual UNION ALL
      SELECT 'TABLE UDM_STD_EMSN_INTENSITY_STACK'                                                      FROM dual UNION ALL
      SELECT 'TABLE UDM_DATA_ITM_RGSTR_STUB'                                                              FROM dual
    )
  ) LOOP
    BEGIN EXECUTE IMMEDIATE 'DROP ' || r.obj || ' CASCADE CONSTRAINTS';
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
  FOR s IN (SELECT 'UDM_DATA_ITM_ELMT_SEQ' n FROM dual UNION ALL
            SELECT 'UDM_STRUCT_STORAGE_MAP_SEQ'  FROM dual UNION ALL
            SELECT 'UDM_SRC_COL_MAP_SEQ'         FROM dual UNION ALL
            SELECT 'UDM_SRC_MAP_SEQ'             FROM dual UNION ALL
            SELECT 'UDM_SRC_COMPONENT_MAP_SEQ'   FROM dual UNION ALL
            SELECT 'UDM_RESP_EVID_SEQ'           FROM dual) LOOP
    BEGIN EXECUTE IMMEDIATE 'DROP SEQUENCE '||s.n; EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END;
/

CREATE SEQUENCE udm_data_itm_elmt_seq      START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE udm_struct_storage_map_seq START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE udm_src_col_map_seq        START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE udm_src_map_seq            START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE udm_src_component_map_seq  START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE udm_resp_evid_seq          START WITH 1 INCREMENT BY 1 NOCACHE;

-- =============================================================================
-- UNIFIED REGISTRY STUB (represents UDM_DATA_ITM_RGSTR).
-- SCD1_KY is the logical FK target. STRUCTURE_TYPE decides which mapping
-- family applies. DERIVATION_RULE_CD is NOT here -- it is source-scoped
-- (see UDM_DATA_ITM_SRC_MAP) because how a value is represented is a
-- property of the source's feed, not of the governed concept.
-- =============================================================================
CREATE TABLE udm_data_itm_rgstr_stub (
    scd1_ky         NUMBER        NOT NULL,
    data_itm_id     VARCHAR2(50)  NOT NULL,
    canonical_nm    VARCHAR2(200) NOT NULL,
    structure_type  VARCHAR2(10)  NOT NULL,   -- STACK | STRUCTURE
    phy_storage_tx  VARCHAR2(10)  NOT NULL,   -- WIDE | OVERFLOW | VIRTUAL | PENDING
    target_table    VARCHAR2(128),            -- physical home (STACK: direct; STRUCTURE: via UDM_STRUCT_STORAGE_MAP)
    target_column   VARCHAR2(128),            -- physical column (STACK only)
    CONSTRAINT pk_rgstr_stub PRIMARY KEY (scd1_ky),
    CONSTRAINT chk_rgstr_sttype CHECK (structure_type IN ('STACK','STRUCTURE')),
    CONSTRAINT chk_rgstr_phystg CHECK (phy_storage_tx IN ('WIDE','OVERFLOW','VIRTUAL','PENDING'))
);

-- =============================================================================
-- PATTERN A -- STRUCTURE ITEMS (unchanged from udm_struct_catalog_v3.sql)
-- =============================================================================
CREATE TABLE udm_trgt_mtrc_domain (
    trgt_mtrc_cd    VARCHAR2(50)  NOT NULL,
    mtrc_name_tx    VARCHAR2(200) NOT NULL,
    uom_cd          VARCHAR2(20),
    mtrc_desc_tx    VARCHAR2(1000),
    is_active_fl    CHAR(1) DEFAULT 'Y' NOT NULL,
    CONSTRAINT pk_trgt_mtrc_domain PRIMARY KEY (trgt_mtrc_cd),
    CONSTRAINT chk_mtrc_dom_actv CHECK (is_active_fl IN ('Y','N'))
);
COMMENT ON TABLE udm_trgt_mtrc_domain IS
    'Governed, closed vocabulary of metric concept codes usable in a STRUCTURE '
    'INSTANCE_MTRC element. Enforces the metric relation as codified, not EAV.';

CREATE TABLE udm_data_itm_elmt (
    elmt_ky           NUMBER              NOT NULL,
    data_itm_scd1_ky  NUMBER              NOT NULL,
    data_itm_id       VARCHAR2(50)        NOT NULL,
    elmt_cd           VARCHAR2(50)        NOT NULL,
    elmt_name_tx      VARCHAR2(200)       NOT NULL,
    role_cd           VARCHAR2(15)        NOT NULL,
    storage_role_cd   VARCHAR2(15)        NOT NULL,
    value_type        VARCHAR2(10)        NOT NULL,
    cardinality       VARCHAR2(4)         NOT NULL,
    target_col_nm     VARCHAR2(128),
    trgt_mtrc_cd      VARCHAR2(50),
    is_mandatory      CHAR(1) DEFAULT 'N' NOT NULL,
    is_active_fl      CHAR(1) DEFAULT 'Y' NOT NULL,
    created_by        VARCHAR2(50) DEFAULT USER NOT NULL,
    created_date      DATE DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_data_itm_elmt PRIMARY KEY (elmt_ky),
    CONSTRAINT uq_udm_data_itm_elmt UNIQUE (data_itm_scd1_ky, elmt_cd),
    CONSTRAINT fk_elmt_rgstr FOREIGN KEY (data_itm_scd1_ky)
        REFERENCES udm_data_itm_rgstr_stub (scd1_ky),
    CONSTRAINT fk_elmt_mtrc_domain FOREIGN KEY (trgt_mtrc_cd)
        REFERENCES udm_trgt_mtrc_domain (trgt_mtrc_cd),
    CONSTRAINT chk_elmt_role CHECK
        (role_cd IN ('IDENTIFYING','MEASURE','QUALIFIER','LINKAGE','NARRATIVE')),
    CONSTRAINT chk_elmt_storage CHECK
        (storage_role_cd IN ('INSTANCE_COL','INSTANCE_MTRC','ATTR_KV',
                             'GHG_LIST','SCOP_LIST','CTGY_LIST','NZ_LINK')),
    CONSTRAINT chk_elmt_vtype CHECK
        (value_type IN ('NUMBER','DATE','CODE','TEXT','BOOLEAN')),
    CONSTRAINT chk_elmt_card  CHECK (cardinality IN ('ONE','MANY')),
    CONSTRAINT chk_elmt_mand  CHECK (is_mandatory IN ('Y','N')),
    CONSTRAINT chk_elmt_actv  CHECK (is_active_fl IN ('Y','N')),
    CONSTRAINT chk_elmt_placement CHECK (
        (storage_role_cd = 'INSTANCE_COL'
             AND target_col_nm IS NOT NULL AND trgt_mtrc_cd IS NULL)
     OR (storage_role_cd = 'INSTANCE_MTRC'
             AND trgt_mtrc_cd IS NOT NULL AND target_col_nm IS NULL)
     OR (storage_role_cd IN ('ATTR_KV','GHG_LIST','SCOP_LIST','CTGY_LIST','NZ_LINK')
             AND target_col_nm IS NULL AND trgt_mtrc_cd IS NULL) ),
    CONSTRAINT chk_elmt_listcard CHECK (
        storage_role_cd NOT IN ('GHG_LIST','SCOP_LIST','CTGY_LIST','NZ_LINK')
     OR cardinality = 'MANY' )
);
COMMENT ON TABLE  udm_data_itm_elmt IS
    'Business exploration catalog for STRUCTURE items. Canonical, source-'
    'agnostic. INSTANCE_COL and INSTANCE_MTRC are two normalized projections '
    'of the SAME target instance (shared instance key), not parent/child.';

CREATE TABLE udm_struct_storage_map (
    storage_map_ky    NUMBER        NOT NULL,
    data_itm_scd1_ky  NUMBER        NOT NULL,
    storage_role_cd   VARCHAR2(15)  NOT NULL,
    phy_table_nm      VARCHAR2(128) NOT NULL,
    instance_key_col  VARCHAR2(128) NOT NULL,
    is_active_fl      CHAR(1) DEFAULT 'Y' NOT NULL,
    CONSTRAINT pk_struct_storage_map PRIMARY KEY (storage_map_ky),
    CONSTRAINT uq_struct_storage_map UNIQUE (data_itm_scd1_ky, storage_role_cd),
    CONSTRAINT fk_ssm_rgstr FOREIGN KEY (data_itm_scd1_ky)
        REFERENCES udm_data_itm_rgstr_stub (scd1_ky),
    CONSTRAINT chk_ssm_storage CHECK
        (storage_role_cd IN ('INSTANCE_COL','INSTANCE_MTRC','ATTR_KV',
                             'GHG_LIST','SCOP_LIST','CTGY_LIST','NZ_LINK')),
    CONSTRAINT chk_ssm_actv CHECK (is_active_fl IN ('Y','N'))
);

-- STRUCTURE source mapping -- existing convention name, extended.
CREATE TABLE udm_data_itm_src_col_map (
    src_col_map_ky  NUMBER        NOT NULL,
    source_id       VARCHAR2(30)  NOT NULL,
    src_metric_cd   VARCHAR2(30),
    elmt_ky         NUMBER        NOT NULL,
    src_key_type    VARCHAR2(10)  NOT NULL,        -- HEADER | CATEGORY
    src_key_tx      VARCHAR2(1000) NOT NULL,
    src_column_nm   VARCHAR2(128),
    val_bucket_cd   VARCHAR2(12),                  -- BASE_VAL|TRGT_VAL|RPT_YR_VAL
    scop_cd         VARCHAR2(20),
    s3_ctgy_cd      VARCHAR2(20),
    meth_cd         VARCHAR2(20),
    transform_rule  VARCHAR2(500),
    CONSTRAINT pk_src_col_map PRIMARY KEY (src_col_map_ky),
    CONSTRAINT fk_scm_elmt FOREIGN KEY (elmt_ky)
        REFERENCES udm_data_itm_elmt (elmt_ky),
    CONSTRAINT chk_scm_keytype CHECK (src_key_type IN ('HEADER','CATEGORY')),
    CONSTRAINT chk_scm_bucket  CHECK
        (val_bucket_cd IN ('BASE_VAL','TRGT_VAL','RPT_YR_VAL'))
);
COMMENT ON TABLE udm_data_itm_src_col_map IS
    'STRUCTURE source mapping (org convention). Element <-> source label. '
    'HEADER=CDP column header; CATEGORY=ESGBook category value.';

CREATE OR REPLACE VIEW v_udm_struct_catalog AS
SELECT e.data_itm_id, e.elmt_cd, e.elmt_name_tx, e.role_cd, e.storage_role_cd,
       e.cardinality, e.value_type, e.is_mandatory,
       m.phy_table_nm AS target_table,
       CASE e.storage_role_cd
           WHEN 'INSTANCE_COL'  THEN e.target_col_nm
           WHEN 'INSTANCE_MTRC' THEN e.trgt_mtrc_cd || ' -> {BASE_VAL_NO|TRGT_VAL_NO|RPT_YR_VAL_NO}'
           WHEN 'ATTR_KV'       THEN '{ATTR_CD=' || e.elmt_cd || ', ATTR_VAL_TX}'
           ELSE '{LIST_VAL_CD}'
       END AS target_mapping
FROM        udm_data_itm_elmt      e
LEFT JOIN   udm_struct_storage_map m ON m.data_itm_scd1_ky=e.data_itm_scd1_ky AND m.storage_role_cd=e.storage_role_cd
WHERE e.is_active_fl='Y'
ORDER BY e.data_itm_id,
    CASE e.role_cd WHEN 'IDENTIFYING' THEN 1 WHEN 'MEASURE' THEN 2
                   WHEN 'QUALIFIER' THEN 3 WHEN 'LINKAGE' THEN 4 ELSE 5 END, e.elmt_cd;

CREATE OR REPLACE VIEW v_udm_src_tgt_lineage AS
SELECT e.data_itm_id, s.source_id, s.src_metric_cd, s.src_key_type, s.src_key_tx,
       s.src_column_nm, e.elmt_cd, e.storage_role_cd, m.phy_table_nm AS target_table,
       CASE e.storage_role_cd
           WHEN 'INSTANCE_COL'  THEN e.target_col_nm
           WHEN 'INSTANCE_MTRC' THEN DECODE(s.val_bucket_cd,'BASE_VAL','BASE_VAL_NO',
                                        'TRGT_VAL','TRGT_VAL_NO','RPT_YR_VAL','RPT_YR_VAL_NO')
           WHEN 'ATTR_KV' THEN 'ATTR_VAL_TX' ELSE 'LIST_VAL_CD'
       END AS target_column,
       e.trgt_mtrc_cd, s.scop_cd, s.s3_ctgy_cd, s.meth_cd
FROM        udm_data_itm_src_col_map s
JOIN        udm_data_itm_elmt        e ON e.elmt_ky=s.elmt_ky
LEFT JOIN   udm_struct_storage_map   m ON m.data_itm_scd1_ky=e.data_itm_scd1_ky AND m.storage_role_cd=e.storage_role_cd
ORDER BY s.source_id, e.elmt_cd, s.scop_cd, s.val_bucket_cd;

-- =============================================================================
-- PATTERN B -- STACK ITEMS (single-column AND multi-component resolution)
-- No OBS/STRUCT spine. Resolved value writes to the EXISTING flat column via
-- the registry (target_table/target_column). SRC_MAP is source-scoped
-- (derivation_rule_cd lives here, not on the registry).
-- =============================================================================
CREATE TABLE udm_resp_slot_domain (
    resp_slot_cd  VARCHAR2(15) NOT NULL,
    slot_desc_tx  VARCHAR2(200),
    CONSTRAINT pk_resp_slot_domain PRIMARY KEY (resp_slot_cd)
);
INSERT INTO udm_resp_slot_domain VALUES ('VALUE',      'Directly reported scalar value');
INSERT INTO udm_resp_slot_domain VALUES ('NUMERATOR',  'Numerator component of a derived value');
INSERT INTO udm_resp_slot_domain VALUES ('DENOMINATOR','Denominator component of a derived value');
INSERT INTO udm_resp_slot_domain VALUES ('UOM',        'Unit of measure as reported');
INSERT INTO udm_resp_slot_domain VALUES ('SRC_PAGE',   'Source document page/section reference');
INSERT INTO udm_resp_slot_domain VALUES ('COMMENT',    'Free-text respondent comment');

-- STACK source mapping header -- existing convention name.
-- One row per (source, item). DERIVATION_RULE_CD source-scoped here.
CREATE TABLE udm_data_itm_src_map (
    src_map_ky          NUMBER        NOT NULL,
    source_id           VARCHAR2(30)  NOT NULL,
    data_itm_scd1_ky    NUMBER        NOT NULL,
    derivation_rule_cd  VARCHAR2(15)  DEFAULT 'DIRECT' NOT NULL,
    CONSTRAINT pk_src_map PRIMARY KEY (src_map_ky),
    CONSTRAINT fk_srcmap_rgstr FOREIGN KEY (data_itm_scd1_ky)
        REFERENCES udm_data_itm_rgstr_stub (scd1_ky),
    CONSTRAINT chk_srcmap_deriv CHECK
        (derivation_rule_cd IN ('DIRECT','RATIO','PCT_CHANGE','DELTA')),
    CONSTRAINT uq_srcmap UNIQUE (source_id, data_itm_scd1_ky)
);
COMMENT ON TABLE udm_data_itm_src_map IS
    'STACK source mapping (org convention), header grain. DERIVATION_RULE_CD '
    'is source-scoped: same governed item may be DIRECT from one source and '
    'derived from another.';

-- NEW: children of SRC_MAP for the N-columns-to-1-target case.
CREATE TABLE udm_data_itm_src_component_map (
    src_component_map_ky NUMBER        NOT NULL,
    src_map_ky           NUMBER        NOT NULL,   -- FK -> UDM_DATA_ITM_SRC_MAP
    resp_slot_cd         VARCHAR2(15)  NOT NULL,
    src_key_type         VARCHAR2(10)  DEFAULT 'CATEGORY' NOT NULL,
    src_key_tx           VARCHAR2(200) NOT NULL,
    CONSTRAINT pk_src_component_map PRIMARY KEY (src_component_map_ky),
    CONSTRAINT fk_scpm_srcmap FOREIGN KEY (src_map_ky)
        REFERENCES udm_data_itm_src_map (src_map_ky),
    CONSTRAINT fk_scpm_slot   FOREIGN KEY (resp_slot_cd)
        REFERENCES udm_resp_slot_domain (resp_slot_cd),
    CONSTRAINT uq_scpm UNIQUE (src_map_ky, resp_slot_cd)
);
COMMENT ON TABLE udm_data_itm_src_component_map IS
    'NEW table. SRC_MAP alone maps 1 source column -> 1 target column. This '
    'covers the case where a STACK item is resolved from MULTIPLE raw source '
    'columns (value/numerator/denominator/uom/page/comment) under one '
    'SRC_MAP header. Distinct from SRC_COL_MAP, which is reserved for '
    'STRUCTURE items per org convention.';

CREATE TABLE udm_std_resp_evid (
    resp_evid_ky         NUMBER        NOT NULL,
    entity_key           VARCHAR2(50)  NOT NULL,
    disclosure_year      NUMBER(4)     NOT NULL,
    data_itm_scd1_ky     NUMBER        NOT NULL,
    source_id            VARCHAR2(30)  NOT NULL,
    numerator_val_no     NUMBER,
    denominator_val_no   NUMBER,
    uom_cd                VARCHAR2(20),
    is_derived_fl          CHAR(1) DEFAULT 'N' NOT NULL,
    src_page_ref            VARCHAR2(50),
    response_comment_tx      VARCHAR2(2000),
    cur_fl                    CHAR(1) DEFAULT 'Y' NOT NULL,
    CONSTRAINT pk_resp_evid PRIMARY KEY (resp_evid_ky),
    CONSTRAINT fk_evid_rgstr FOREIGN KEY (data_itm_scd1_ky)
        REFERENCES udm_data_itm_rgstr_stub (scd1_ky),
    CONSTRAINT chk_evid_derived CHECK (is_derived_fl IN ('Y','N')),
    CONSTRAINT chk_evid_curfl   CHECK (cur_fl IN ('Y','N')),
    CONSTRAINT uq_resp_evid UNIQUE (entity_key, disclosure_year, data_itm_scd1_ky, source_id, cur_fl)
);
COMMENT ON TABLE udm_std_resp_evid IS
    'Evidence sidecar. Never carries the resolved value -- that lives in the '
    'existing flat subdomain column via registry routing.';

-- Business explorability for STACK multi-component items. No new catalog
-- table -- the engine metadata (SRC_MAP + SRC_COMPONENT_MAP) IS the source of
-- truth; this view exposes it for browsing without duplicating it.
CREATE OR REPLACE VIEW v_udm_stack_component_catalog AS
SELECT r.data_itm_id, r.target_table, r.target_column,
       sm.source_id, sm.derivation_rule_cd,
       cm.resp_slot_cd, cm.src_key_tx
FROM        udm_data_itm_rgstr_stub          r
JOIN        udm_data_itm_src_map             sm ON sm.data_itm_scd1_ky = r.scd1_ky
LEFT JOIN   udm_data_itm_src_component_map   cm ON cm.src_map_ky = sm.src_map_ky
WHERE r.structure_type = 'STACK'
ORDER BY r.data_itm_id, sm.source_id, cm.resp_slot_cd;
COMMENT ON TABLE udm_std_resp_evid IS 'See view comment above for catalog exposure pattern.';

-- Cross-source arbitration priority (stand-in for Module 7 Arbitration).
CREATE TABLE udm_source_priority (
    source_id    VARCHAR2(30) NOT NULL,
    priority_no  NUMBER       NOT NULL,
    CONSTRAINT pk_source_priority PRIMARY KEY (source_id)
);

-- Staging pipeline -------------------------------------------------------------
CREATE TABLE udm_stg_resp_raw (
    entity_key       VARCHAR2(50) NOT NULL,
    disclosure_year  NUMBER(4)    NOT NULL,
    source_id        VARCHAR2(30) NOT NULL,
    src_key_tx       VARCHAR2(200) NOT NULL,
    raw_val_tx       VARCHAR2(2000)
);

CREATE OR REPLACE VIEW v_stg_resp_slotted AS
SELECT r.entity_key, r.disclosure_year, sm.source_id, sm.data_itm_scd1_ky,
    MAX(CASE WHEN cm.resp_slot_cd='VALUE'       THEN TO_NUMBER(r.raw_val_tx) END) value_no,
    MAX(CASE WHEN cm.resp_slot_cd='NUMERATOR'   THEN TO_NUMBER(r.raw_val_tx) END) numerator_no,
    MAX(CASE WHEN cm.resp_slot_cd='DENOMINATOR' THEN TO_NUMBER(r.raw_val_tx) END) denominator_no,
    MAX(CASE WHEN cm.resp_slot_cd='UOM'         THEN r.raw_val_tx END) uom_cd,
    MAX(CASE WHEN cm.resp_slot_cd='SRC_PAGE'    THEN r.raw_val_tx END) src_page_ref,
    MAX(CASE WHEN cm.resp_slot_cd='COMMENT'     THEN r.raw_val_tx END) comment_tx
FROM        udm_stg_resp_raw               r
JOIN        udm_data_itm_src_component_map cm ON cm.src_key_tx = r.src_key_tx
JOIN        udm_data_itm_src_map           sm ON sm.src_map_ky = cm.src_map_ky AND sm.source_id = r.source_id
GROUP BY r.entity_key, r.disclosure_year, sm.source_id, sm.data_itm_scd1_ky;

CREATE OR REPLACE VIEW v_stg_resp_resolved AS
SELECT s.entity_key, s.disclosure_year, s.source_id, s.data_itm_scd1_ky, sm.derivation_rule_cd,
       CASE sm.derivation_rule_cd
           WHEN 'DIRECT'     THEN s.value_no
           WHEN 'RATIO'      THEN s.numerator_no / NULLIF(s.denominator_no,0)
           WHEN 'PCT_CHANGE' THEN (s.numerator_no - s.denominator_no) / NULLIF(s.denominator_no,0)
           WHEN 'DELTA'      THEN s.numerator_no - s.denominator_no
       END AS resolved_val_no,
       CASE WHEN sm.derivation_rule_cd <> 'DIRECT' THEN 'Y' ELSE 'N' END AS is_derived_fl,
       s.numerator_no, s.denominator_no, s.uom_cd, s.src_page_ref, s.comment_tx
FROM        v_stg_resp_slotted    s
JOIN        udm_data_itm_src_map  sm ON sm.source_id=s.source_id AND sm.data_itm_scd1_ky=s.data_itm_scd1_ky;

CREATE OR REPLACE VIEW v_stg_resp_arbitrated AS
SELECT entity_key, disclosure_year, data_itm_scd1_ky, source_id,
       resolved_val_no, is_derived_fl, numerator_no, denominator_no, uom_cd, src_page_ref, comment_tx
FROM (
    SELECT r.*, ROW_NUMBER() OVER (
        PARTITION BY entity_key, disclosure_year, data_itm_scd1_ky ORDER BY sp.priority_no
    ) rn
    FROM v_stg_resp_resolved r JOIN udm_source_priority sp ON sp.source_id = r.source_id
) WHERE rn = 1;

-- Wide pivot: one generated MERGE per target_table. Column count scales with
-- item count; statement count does not.
CREATE OR REPLACE PROCEDURE pivot_stack_to_target (
    p_target_table  IN VARCHAR2, p_entity_key IN VARCHAR2,
    p_disclosure_yr IN NUMBER,   p_apply IN CHAR DEFAULT 'Y'
) AS
    v_sql CLOB;
BEGIN
    v_sql := 'MERGE INTO ' || p_target_table || ' t' || CHR(10)
          || 'USING (SELECT entity_key, disclosure_year' || CHR(10);
    FOR r IN (SELECT target_column, scd1_ky FROM udm_data_itm_rgstr_stub
              WHERE target_table=p_target_table AND structure_type='STACK' AND phy_storage_tx='WIDE') LOOP
        v_sql := v_sql || '     , MAX(CASE WHEN data_itm_scd1_ky=' || r.scd1_ky
              || ' THEN resolved_val_no END) AS ' || r.target_column || CHR(10);
    END LOOP;
    v_sql := v_sql || '  FROM v_stg_resp_arbitrated' || CHR(10)
          || '  WHERE entity_key=:p_ent AND disclosure_year=:p_yr' || CHR(10)
          || '  GROUP BY entity_key, disclosure_year) s' || CHR(10)
          || 'ON (t.entity_key=s.entity_key AND t.disclosure_year=s.disclosure_year)' || CHR(10)
          || 'WHEN MATCHED THEN UPDATE SET';
    FOR r IN (SELECT target_column FROM udm_data_itm_rgstr_stub
              WHERE target_table=p_target_table AND structure_type='STACK' AND phy_storage_tx='WIDE') LOOP
        v_sql := v_sql || ' t.' || r.target_column || '=s.' || r.target_column || ',';
    END LOOP;
    v_sql := RTRIM(v_sql,',') || CHR(10) || 'WHEN NOT MATCHED THEN INSERT (entity_key, disclosure_year';
    FOR r IN (SELECT target_column FROM udm_data_itm_rgstr_stub
              WHERE target_table=p_target_table AND structure_type='STACK' AND phy_storage_tx='WIDE') LOOP
        v_sql := v_sql || ', ' || r.target_column;
    END LOOP;
    v_sql := v_sql || ') VALUES (s.entity_key, s.disclosure_year';
    FOR r IN (SELECT target_column FROM udm_data_itm_rgstr_stub
              WHERE target_table=p_target_table AND structure_type='STACK' AND phy_storage_tx='WIDE') LOOP
        v_sql := v_sql || ', s.' || r.target_column;
    END LOOP;
    v_sql := v_sql || ')';
    IF p_apply='Y' THEN
        EXECUTE IMMEDIATE v_sql USING p_entity_key, p_disclosure_yr, p_entity_key, p_disclosure_yr;
        COMMIT;
    ELSE DBMS_OUTPUT.PUT_LINE(v_sql); END IF;
END pivot_stack_to_target;
/

-- Structure adapter generator (unchanged from Pattern A) -----------------------
CREATE OR REPLACE PROCEDURE generate_target_adapters (
    p_source_id IN VARCHAR2, p_data_itm_scd1_ky IN NUMBER, p_apply IN CHAR DEFAULT 'N'
) AS
    v_sql CLOB;
    FUNCTION resolve(p_role VARCHAR2) RETURN udm_struct_storage_map%ROWTYPE IS
        r udm_struct_storage_map%ROWTYPE;
    BEGIN
        SELECT * INTO r FROM udm_struct_storage_map
        WHERE data_itm_scd1_ky=p_data_itm_scd1_ky AND storage_role_cd=p_role AND is_active_fl='Y';
        RETURN r;
    EXCEPTION WHEN NO_DATA_FOUND THEN r.phy_table_nm:=NULL; RETURN r; END;
    PROCEDURE emit(p CLOB) IS BEGIN
        IF p_apply='Y' THEN EXECUTE IMMEDIATE p;
        ELSE DBMS_OUTPUT.PUT_LINE(p); DBMS_OUTPUT.PUT_LINE('/'); END IF;
    END;
BEGIN
    v_sql := 'CREATE OR REPLACE VIEW adpt_'||p_source_id||'_'||p_data_itm_scd1_ky||'_instance AS'||CHR(10)
           || 'SELECT /* instance key */'||CHR(10);
    FOR r IN (SELECT e.elmt_cd, e.target_col_nm, s.src_key_type, s.src_key_tx
              FROM udm_data_itm_elmt e JOIN udm_data_itm_src_col_map s ON s.elmt_ky=e.elmt_ky
              WHERE e.data_itm_scd1_ky=p_data_itm_scd1_ky AND e.storage_role_cd='INSTANCE_COL'
              AND s.source_id=p_source_id) LOOP
        IF r.src_key_type='HEADER' THEN
            v_sql := v_sql||'   , '||r.src_key_tx||' AS '||r.target_col_nm||CHR(10);
        ELSE
            v_sql := v_sql||'   , MAX(CASE WHEN category='''||r.src_key_tx||''' THEN value END) AS '||r.target_col_nm||CHR(10);
        END IF;
    END LOOP;
    v_sql := v_sql||'FROM /* raw source '||p_source_id||' */ DUAL';
    emit(v_sql);
    IF resolve('INSTANCE_MTRC').phy_table_nm IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('-- metric adapter: reshape per val_bucket_cd (see udm_struct_catalog_v3.sql)');
    END IF;
END generate_target_adapters;
/

-- =============================================================================
-- SEED -- Pattern A (structure) + Pattern B (stack, dual-source)
-- =============================================================================
INSERT INTO udm_data_itm_rgstr_stub VALUES
 (1001,'DI_EMSN_RED_TGT','Emission Reduction Target','STRUCTURE','WIDE',NULL,NULL);
INSERT INTO udm_trgt_mtrc_domain (trgt_mtrc_cd, mtrc_name_tx, uom_cd) VALUES
 ('EMISSIONS_COVERED','Emissions covered by target','TCO2E');
INSERT INTO udm_struct_storage_map (storage_map_ky,data_itm_scd1_ky,storage_role_cd,phy_table_nm,instance_key_col) VALUES
 (udm_struct_storage_map_seq.NEXTVAL,1001,'INSTANCE_COL' ,'UDM_STD_EMSN_TRGT_SNPSHT_FCT'  ,'TARGET_REFERENCE_ID');
INSERT INTO udm_struct_storage_map (storage_map_ky,data_itm_scd1_ky,storage_role_cd,phy_table_nm,instance_key_col) VALUES
 (udm_struct_storage_map_seq.NEXTVAL,1001,'INSTANCE_MTRC','UDM_STD_EMSN_TRGT_MTRC_SNPSHT' ,'TARGET_REFERENCE_ID');
INSERT INTO udm_data_itm_elmt (elmt_ky,data_itm_scd1_ky,data_itm_id,elmt_cd,elmt_name_tx,role_cd,storage_role_cd,value_type,cardinality,target_col_nm,is_mandatory)
 VALUES (udm_data_itm_elmt_seq.NEXTVAL,1001,'DI_EMSN_RED_TGT','TARGET_REFERENCE_ID','Target reference number','IDENTIFYING','INSTANCE_COL','CODE','ONE','TARGET_REFERENCE_ID','Y');
INSERT INTO udm_data_itm_elmt (elmt_ky,data_itm_scd1_ky,data_itm_id,elmt_cd,elmt_name_tx,role_cd,storage_role_cd,value_type,cardinality,trgt_mtrc_cd,is_mandatory)
 VALUES (udm_data_itm_elmt_seq.NEXTVAL,1001,'DI_EMSN_RED_TGT','EMISSIONS_COVERED','Emissions covered by target','MEASURE','INSTANCE_MTRC','NUMBER','MANY','EMISSIONS_COVERED','N');
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Target reference number','C_TGT_REF' FROM udm_data_itm_elmt WHERE elmt_cd='TARGET_REFERENCE_ID';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm,val_bucket_cd,scop_cd)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Base year Scope 1 emissions covered by target (metric tons CO2e)','C_BY_S1','BASE_VAL','SCOPE_1' FROM udm_data_itm_elmt WHERE elmt_cd='EMISSIONS_COVERED';

INSERT INTO udm_data_itm_rgstr_stub VALUES
 (2001,'DI_ASK_3YR_PRIOR','Client ASK 3 years before reporting year','STACK','WIDE','UDM_STD_EMSN_INTENSITY_STACK','ASK_3YR_PRIOR_VAL_NO');
INSERT INTO udm_data_itm_rgstr_stub VALUES
 (2002,'DI_JET_FUEL_TONS','Tons of jet fuel reported','STACK','WIDE','UDM_STD_EMSN_INTENSITY_STACK','JET_FUEL_REPORTED_TONS_NO');
INSERT INTO udm_data_itm_rgstr_stub VALUES
 (2003,'DI_FLARE_INTENSITY_CHG','Change in methane flaring intensity','STACK','WIDE','UDM_STD_EMSN_INTENSITY_STACK','FLARE_INTENSITY_CHG_PCT');

INSERT INTO udm_source_priority VALUES ('FEED',1);
INSERT INTO udm_source_priority VALUES ('ESGBOOK',2);

INSERT INTO udm_data_itm_src_map (src_map_ky,source_id,data_itm_scd1_ky,derivation_rule_cd) VALUES (udm_src_map_seq.NEXTVAL,'FEED',2001,'DIRECT');
INSERT INTO udm_data_itm_src_component_map (src_component_map_ky,src_map_ky,resp_slot_cd,src_key_tx)
 SELECT udm_src_component_map_seq.NEXTVAL,src_map_ky,'VALUE','Q014_VALUE' FROM udm_data_itm_src_map WHERE source_id='FEED' AND data_itm_scd1_ky=2001;
INSERT INTO udm_data_itm_src_component_map (src_component_map_ky,src_map_ky,resp_slot_cd,src_key_tx)
 SELECT udm_src_component_map_seq.NEXTVAL,src_map_ky,'SRC_PAGE','Q014_PAGE' FROM udm_data_itm_src_map WHERE source_id='FEED' AND data_itm_scd1_ky=2001;

INSERT INTO udm_data_itm_src_map (src_map_ky,source_id,data_itm_scd1_ky,derivation_rule_cd) VALUES (udm_src_map_seq.NEXTVAL,'FEED',2002,'DIRECT');
INSERT INTO udm_data_itm_src_component_map (src_component_map_ky,src_map_ky,resp_slot_cd,src_key_tx)
 SELECT udm_src_component_map_seq.NEXTVAL,src_map_ky,'VALUE','Q027_VALUE' FROM udm_data_itm_src_map WHERE source_id='FEED' AND data_itm_scd1_ky=2002;
INSERT INTO udm_data_itm_src_component_map (src_component_map_ky,src_map_ky,resp_slot_cd,src_key_tx)
 SELECT udm_src_component_map_seq.NEXTVAL,src_map_ky,'UOM','Q027_UOM' FROM udm_data_itm_src_map WHERE source_id='FEED' AND data_itm_scd1_ky=2002;
INSERT INTO udm_data_itm_src_component_map (src_component_map_ky,src_map_ky,resp_slot_cd,src_key_tx)
 SELECT udm_src_component_map_seq.NEXTVAL,src_map_ky,'SRC_PAGE','Q027_PAGE' FROM udm_data_itm_src_map WHERE source_id='FEED' AND data_itm_scd1_ky=2002;

INSERT INTO udm_data_itm_src_map (src_map_ky,source_id,data_itm_scd1_ky,derivation_rule_cd) VALUES (udm_src_map_seq.NEXTVAL,'FEED',2003,'PCT_CHANGE');
INSERT INTO udm_data_itm_src_component_map (src_component_map_ky,src_map_ky,resp_slot_cd,src_key_tx)
 SELECT udm_src_component_map_seq.NEXTVAL,src_map_ky,'NUMERATOR','Q041_CURR_INTENSITY' FROM udm_data_itm_src_map WHERE source_id='FEED' AND data_itm_scd1_ky=2003;
INSERT INTO udm_data_itm_src_component_map (src_component_map_ky,src_map_ky,resp_slot_cd,src_key_tx)
 SELECT udm_src_component_map_seq.NEXTVAL,src_map_ky,'DENOMINATOR','Q041_PRIOR_INTENSITY' FROM udm_data_itm_src_map WHERE source_id='FEED' AND data_itm_scd1_ky=2003;
INSERT INTO udm_data_itm_src_component_map (src_component_map_ky,src_map_ky,resp_slot_cd,src_key_tx)
 SELECT udm_src_component_map_seq.NEXTVAL,src_map_ky,'SRC_PAGE','Q041_PAGE' FROM udm_data_itm_src_map WHERE source_id='FEED' AND data_itm_scd1_ky=2003;

INSERT INTO udm_data_itm_src_map (src_map_ky,source_id,data_itm_scd1_ky,derivation_rule_cd) VALUES (udm_src_map_seq.NEXTVAL,'ESGBOOK',2003,'DIRECT');
INSERT INTO udm_data_itm_src_component_map (src_component_map_ky,src_map_ky,resp_slot_cd,src_key_tx)
 SELECT udm_src_component_map_seq.NEXTVAL,src_map_ky,'VALUE','methane_flaring_intensity_change_pct' FROM udm_data_itm_src_map WHERE source_id='ESGBOOK' AND data_itm_scd1_ky=2003;

CREATE TABLE udm_std_emsn_intensity_stack (
    entity_key                VARCHAR2(50) NOT NULL,
    disclosure_year           NUMBER(4)    NOT NULL,
    ask_3yr_prior_val_no       NUMBER,
    jet_fuel_reported_tons_no   NUMBER,
    flare_intensity_chg_pct      NUMBER,
    CONSTRAINT pk_emsn_intensity_stack PRIMARY KEY (entity_key, disclosure_year)
);

INSERT INTO udm_stg_resp_raw VALUES ('ENTITY_001',2025,'FEED','Q014_VALUE','12.5');
INSERT INTO udm_stg_resp_raw VALUES ('ENTITY_001',2025,'FEED','Q027_VALUE','48200');
INSERT INTO udm_stg_resp_raw VALUES ('ENTITY_001',2025,'FEED','Q041_CURR_INTENSITY','0.85');
INSERT INTO udm_stg_resp_raw VALUES ('ENTITY_001',2025,'FEED','Q041_PRIOR_INTENSITY','1.20');
INSERT INTO udm_stg_resp_raw VALUES ('ENTITY_001',2025,'ESGBOOK','methane_flaring_intensity_change_pct','-8.75');
COMMIT;

EXEC pivot_stack_to_target('UDM_STD_EMSN_INTENSITY_STACK','ENTITY_001',2025,'Y');

PROMPT ==== Pattern A: V_UDM_STRUCT_CATALOG ====
SELECT elmt_cd, role_cd, storage_role_cd, target_table, target_mapping FROM v_udm_struct_catalog;
PROMPT ==== Pattern B: V_UDM_STACK_COMPONENT_CATALOG ====
SELECT data_itm_id, source_id, derivation_rule_cd, resp_slot_cd, src_key_tx FROM v_udm_stack_component_catalog;
PROMPT ==== Pattern B: resolved wide row ====
SELECT * FROM udm_std_emsn_intensity_stack;

-- =============================================================================
-- END udm_business_catalog_complete_v1.sql
-- =============================================================================
