-- =============================================================================
-- UDM STRUCTURED TARGET — CATALOG (BUSINESS + RUN-TIME), VIEWS, ADAPTER UTILITY
-- File   : udm_struct_catalog_v2.sql   (self-contained, re-runnable demo build)
-- =============================================================================
-- Semantic model (corrected):
--   A target is ONE instance identified by TARGET_REFERENCE_ID. Its wide
--   attribute set is NORMALIZED across two relations to avoid column explosion
--   -- NOT a master/detail hierarchy. Both relations share TARGET_REFERENCE_ID.
--     * UDM_STD_EMSN_TRGT_SNPSHT_FCT  = singular instance attributes  (INSTANCE_COL)
--     * UDM_STD_EMSN_TRGT_MTRC_SNPSHT = qualifier-repeating attributes (INSTANCE_MTRC),
--         keyed by TARGET_REFERENCE_ID + TRGT_MTRC_CD + scope/category/method,
--         with TYPED buckets BASE_VAL_NO / TRGT_VAL_NO / RPT_YR_VAL_NO.
--         Governed row-axis + typed columns => codified narrow fact, NOT EAV.
--
-- Layers built here:
--   BUSINESS  : UDM_DATA_ITM_ELMT        (what elements exist, logical zone)
--   RUN-TIME  : UDM_STRUCT_STORAGE_MAP   (zone -> physical table routing)
--               UDM_DATA_ITM_SRC_COL_MAP (source key vocab + metric decode)
--   VIEWS     : V_UDM_STRUCT_CATALOG     (business: element -> table/column)
--               V_UDM_SRC_TGT_LINEAGE    (source label -> target col lineage)
--   UTILITY   : generate_target_adapters (emits parent/normalized adapters)
--   SEED      : EMISSION_REDUCTION_TARGET across CDP (HEADER) + ESGBook (CATEGORY)
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED;

-- -----------------------------------------------------------------------------
-- 0. RE-RUNNABLE CLEANUP (demo convenience)
-- -----------------------------------------------------------------------------
BEGIN
  FOR r IN (
    SELECT 'VIEW  V_UDM_SRC_TGT_LINEAGE'      obj FROM dual UNION ALL
    SELECT 'VIEW  V_UDM_STRUCT_CATALOG'            FROM dual UNION ALL
    SELECT 'TABLE UDM_DATA_ITM_SRC_COL_MAP'        FROM dual UNION ALL
    SELECT 'TABLE UDM_STRUCT_STORAGE_MAP'          FROM dual UNION ALL
    SELECT 'TABLE UDM_DATA_ITM_ELMT'               FROM dual UNION ALL
    SELECT 'TABLE UDM_DATA_ITM_RGSTR_STUB'         FROM dual
  ) LOOP
    BEGIN EXECUTE IMMEDIATE 'DROP ' || r.obj
        || CASE WHEN r.obj LIKE 'TABLE%' THEN ' CASCADE CONSTRAINTS' END;
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
  FOR s IN (SELECT 'UDM_DATA_ITM_ELMT_SEQ' n FROM dual UNION ALL
            SELECT 'UDM_STRUCT_STORAGE_MAP_SEQ'  FROM dual UNION ALL
            SELECT 'UDM_SRC_COL_MAP_SEQ'         FROM dual) LOOP
    BEGIN EXECUTE IMMEDIATE 'DROP SEQUENCE ' || s.n; EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END;
/

CREATE SEQUENCE udm_data_itm_elmt_seq      START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE udm_struct_storage_map_seq START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE udm_src_col_map_seq        START WITH 1 INCREMENT BY 1 NOCACHE;


-- -----------------------------------------------------------------------------
-- 0b. REGISTRY STUB (represents existing UDM_DATA_ITM_RGSTR; SCD1_KY is the
--     logical FK target, data_itm_id is display only)
-- -----------------------------------------------------------------------------
CREATE TABLE udm_data_itm_rgstr_stub (
    scd1_ky         NUMBER        NOT NULL,
    data_itm_id     VARCHAR2(50)  NOT NULL,
    canonical_nm    VARCHAR2(200) NOT NULL,
    structure_type  VARCHAR2(10)  NOT NULL,   -- STACK | STRUCTURE
    CONSTRAINT pk_rgstr_stub PRIMARY KEY (scd1_ky),
    CONSTRAINT chk_rgstr_sttype CHECK (structure_type IN ('STACK','STRUCTURE'))
);


-- =============================================================================
-- BUSINESS CATALOG — UDM_DATA_ITM_ELMT
-- Source-agnostic. No source labels, no physical table names.
-- TARGET_COL_NM  : physical column, INSTANCE_COL only.
-- TRGT_MTRC_CD   : governed metric concept, INSTANCE_MTRC only.
-- =============================================================================
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
    target_col_nm     VARCHAR2(128),      -- INSTANCE_COL: physical column in FCT
    trgt_mtrc_cd      VARCHAR2(50),       -- INSTANCE_MTRC: governed metric concept
    is_mandatory      CHAR(1) DEFAULT 'N' NOT NULL,
    is_active_fl      CHAR(1) DEFAULT 'Y' NOT NULL,
    elmt_desc_tx      VARCHAR2(1000),
    created_by        VARCHAR2(50) DEFAULT USER NOT NULL,
    created_date      DATE DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_udm_data_itm_elmt PRIMARY KEY (elmt_ky),
    CONSTRAINT uq_udm_data_itm_elmt UNIQUE (data_itm_scd1_ky, elmt_cd),
    CONSTRAINT fk_elmt_rgstr FOREIGN KEY (data_itm_scd1_ky)
        REFERENCES udm_data_itm_rgstr_stub (scd1_ky),
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
    -- INSTANCE_COL  => target column, no metric code
    -- INSTANCE_MTRC => metric code, no target column (value goes to typed buckets)
    -- other roles   => neither
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
    'Business exploration catalog: canonical elements composing each STRUCTURE '
    'data item. INSTANCE_COL and INSTANCE_MTRC are two normalized projections of '
    'the SAME target instance (shared TARGET_REFERENCE_ID), not parent/child.';
COMMENT ON COLUMN udm_data_itm_elmt.trgt_mtrc_cd IS
    'Governed metric concept for the normalized metric relation. Value lands in '
    'typed buckets BASE_VAL_NO/TRGT_VAL_NO/RPT_YR_VAL_NO -- codified, not EAV.';


-- =============================================================================
-- RUN-TIME ROUTING — UDM_STRUCT_STORAGE_MAP
-- Resolves (data item, storage_role) -> physical table.
-- Shared fact family => many data items point at one PHY_TABLE_NM.
-- =============================================================================
CREATE TABLE udm_struct_storage_map (
    storage_map_ky    NUMBER        NOT NULL,
    data_itm_scd1_ky  NUMBER        NOT NULL,
    storage_role_cd   VARCHAR2(15)  NOT NULL,
    phy_table_nm      VARCHAR2(128) NOT NULL,
    instance_key_col  VARCHAR2(128) NOT NULL,   -- shared instance key (TARGET_REFERENCE_ID)
    is_active_fl      CHAR(1) DEFAULT 'Y' NOT NULL,
    created_by        VARCHAR2(50) DEFAULT USER NOT NULL,
    created_date      DATE DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_struct_storage_map PRIMARY KEY (storage_map_ky),
    CONSTRAINT uq_struct_storage_map UNIQUE (data_itm_scd1_ky, storage_role_cd),
    CONSTRAINT fk_ssm_rgstr FOREIGN KEY (data_itm_scd1_ky)
        REFERENCES udm_data_itm_rgstr_stub (scd1_ky),
    CONSTRAINT chk_ssm_storage CHECK
        (storage_role_cd IN ('INSTANCE_COL','INSTANCE_MTRC','ATTR_KV',
                             'GHG_LIST','SCOP_LIST','CTGY_LIST','NZ_LINK')),
    CONSTRAINT chk_ssm_actv CHECK (is_active_fl IN ('Y','N'))
);

COMMENT ON TABLE udm_struct_storage_map IS
    'Routing. INSTANCE_KEY_COL is the shared target instance key joining the '
    'normalized relations (same across INSTANCE_COL and INSTANCE_MTRC rows).';


-- =============================================================================
-- RUN-TIME ENGINE METADATA — UDM_DATA_ITM_SRC_COL_MAP
-- (In production this is the EXISTING table + the ALTER-added columns. Created
--  fresh here so the demo runs and the lineage view renders.)
-- =============================================================================
CREATE TABLE udm_data_itm_src_col_map (
    src_col_map_ky  NUMBER        NOT NULL,
    source_id       VARCHAR2(30)  NOT NULL,
    src_metric_cd   VARCHAR2(30),                 -- e.g. CDP 7.53.1
    elmt_ky         NUMBER        NOT NULL,        -- FK -> UDM_DATA_ITM_ELMT
    src_key_type    VARCHAR2(10)  NOT NULL,        -- HEADER | CATEGORY
    src_key_tx      VARCHAR2(1000) NOT NULL,       -- literal header text / category label
    src_column_nm   VARCHAR2(128),                 -- physical raw source column
    val_bucket_cd   VARCHAR2(12),                  -- BASE_VAL|TRGT_VAL|RPT_YR_VAL (metric only)
    scop_cd         VARCHAR2(20),                  -- decoded scope qualifier
    s3_ctgy_cd      VARCHAR2(20),                  -- decoded Scope-3 category
    meth_cd         VARCHAR2(20),                  -- decoded method qualifier
    transform_rule  VARCHAR2(500),
    created_by      VARCHAR2(50) DEFAULT USER NOT NULL,
    created_date    DATE DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_src_col_map PRIMARY KEY (src_col_map_ky),
    CONSTRAINT fk_scm_elmt FOREIGN KEY (elmt_ky)
        REFERENCES udm_data_itm_elmt (elmt_ky),
    CONSTRAINT chk_scm_keytype CHECK (src_key_type IN ('HEADER','CATEGORY')),
    CONSTRAINT chk_scm_bucket  CHECK
        (val_bucket_cd IN ('BASE_VAL','TRGT_VAL','RPT_YR_VAL'))
);

COMMENT ON COLUMN udm_data_itm_src_col_map.src_key_type IS
    'HEADER=CDP column header (identity in schema). CATEGORY=ESGBook category '
    '(identity in data). VAL_BUCKET_CD collapses base/target/reporting headers '
    'of one (metric,scope) onto one metric row.';


-- =============================================================================
-- VIEW 1 — BUSINESS CATALOG
-- "What data elements exist, and what column/table do they map to in the target"
-- =============================================================================
CREATE OR REPLACE VIEW v_udm_struct_catalog AS
SELECT
    e.data_itm_id,
    e.elmt_cd,
    e.elmt_name_tx,
    e.role_cd,
    e.storage_role_cd,
    e.cardinality,
    e.value_type,
    e.is_mandatory,
    m.phy_table_nm                              AS target_table,
    CASE e.storage_role_cd
        WHEN 'INSTANCE_COL'  THEN e.target_col_nm
        WHEN 'INSTANCE_MTRC' THEN e.trgt_mtrc_cd
                                  || ' -> {BASE_VAL_NO|TRGT_VAL_NO|RPT_YR_VAL_NO}'
        WHEN 'ATTR_KV'       THEN '{ATTR_CD=' || e.elmt_cd || ', ATTR_VAL_TX}'
        ELSE '{LIST_VAL_CD}'
    END                                         AS target_mapping,
    m.instance_key_col                          AS instance_key
FROM        udm_data_itm_elmt      e
LEFT JOIN   udm_struct_storage_map m
       ON   m.data_itm_scd1_ky = e.data_itm_scd1_ky
      AND   m.storage_role_cd  = e.storage_role_cd
WHERE   e.is_active_fl = 'Y'
ORDER BY
    e.data_itm_id,
    CASE e.role_cd WHEN 'IDENTIFYING' THEN 1 WHEN 'MEASURE' THEN 2
                   WHEN 'QUALIFIER'   THEN 3 WHEN 'LINKAGE' THEN 4 ELSE 5 END,
    e.elmt_cd;


-- =============================================================================
-- VIEW 2 — SOURCE -> TARGET LINEAGE
-- source construct + key vocabulary -> canonical element -> resolved target col
-- =============================================================================
CREATE OR REPLACE VIEW v_udm_src_tgt_lineage AS
SELECT
    e.data_itm_id,
    s.source_id,
    s.src_metric_cd,
    s.src_key_type,
    s.src_key_tx,
    s.src_column_nm,
    e.elmt_cd,
    e.storage_role_cd,
    m.phy_table_nm                              AS target_table,
    CASE e.storage_role_cd
        WHEN 'INSTANCE_COL'  THEN e.target_col_nm
        WHEN 'INSTANCE_MTRC' THEN DECODE(s.val_bucket_cd,
                                     'BASE_VAL',  'BASE_VAL_NO',
                                     'TRGT_VAL',  'TRGT_VAL_NO',
                                     'RPT_YR_VAL','RPT_YR_VAL_NO')
        WHEN 'ATTR_KV'       THEN 'ATTR_VAL_TX'
        ELSE 'LIST_VAL_CD'
    END                                         AS target_column,
    e.trgt_mtrc_cd,
    s.scop_cd,
    s.s3_ctgy_cd,
    s.meth_cd,
    s.transform_rule
FROM        udm_data_itm_src_col_map s
JOIN        udm_data_itm_elmt        e ON e.elmt_ky = s.elmt_ky
LEFT JOIN   udm_struct_storage_map   m
       ON   m.data_itm_scd1_ky = e.data_itm_scd1_ky
      AND   m.storage_role_cd  = e.storage_role_cd
ORDER BY s.source_id, e.elmt_cd, s.scop_cd, s.val_bucket_cd;


-- =============================================================================
-- UTILITY — ADAPTER GENERATOR
-- Emits an INSTANCE adapter (singular cols) + a NORMALIZED-METRIC adapter,
-- both projecting the SAME TARGET_REFERENCE_ID. Neither is framed as a child.
-- HEADER  -> alias projection ; CATEGORY -> pivot. Metric adapter reshapes
-- base/target/reporting headers into typed bucket columns on one row per
-- (ref_id, metric, scope, category, method).
-- SKELETON: raw-source FROM/UNION assembly is stubbed & marked.
-- =============================================================================
CREATE OR REPLACE PROCEDURE generate_target_adapters (
    p_source_id        IN VARCHAR2,
    p_data_itm_scd1_ky IN NUMBER,
    p_apply            IN CHAR DEFAULT 'N'
) AS
    v_sql   CLOB;
    v_tbl   udm_struct_storage_map.phy_table_nm%TYPE;
    v_key   udm_struct_storage_map.instance_key_col%TYPE;

    FUNCTION resolve(p_role VARCHAR2) RETURN udm_struct_storage_map%ROWTYPE IS
        r udm_struct_storage_map%ROWTYPE;
    BEGIN
        SELECT * INTO r FROM udm_struct_storage_map
        WHERE data_itm_scd1_ky=p_data_itm_scd1_ky AND storage_role_cd=p_role
          AND is_active_fl='Y';
        RETURN r;
    EXCEPTION WHEN NO_DATA_FOUND THEN r.phy_table_nm:=NULL; RETURN r; END;

    PROCEDURE emit(p CLOB) IS BEGIN
        IF p_apply='Y' THEN EXECUTE IMMEDIATE p;
        ELSE DBMS_OUTPUT.PUT_LINE(p); DBMS_OUTPUT.PUT_LINE('/'); END IF;
    END;
BEGIN
    -- INSTANCE adapter (singular attributes) -------------------------------
    v_sql := 'CREATE OR REPLACE VIEW adpt_'||p_source_id||'_'
          || p_data_itm_scd1_ky||'_instance AS'||CHR(10)
          || 'SELECT /* instance key: target_reference_id */'||CHR(10);
    FOR r IN (
        SELECT e.elmt_cd, e.target_col_nm, s.src_key_type, s.src_key_tx
        FROM udm_data_itm_elmt e
        JOIN udm_data_itm_src_col_map s ON s.elmt_ky=e.elmt_ky
        WHERE e.data_itm_scd1_ky=p_data_itm_scd1_ky
          AND e.storage_role_cd='INSTANCE_COL' AND s.source_id=p_source_id
    ) LOOP
        IF r.src_key_type='HEADER' THEN
            v_sql := v_sql||'   , '||r.src_key_tx||' AS '||r.target_col_nm||CHR(10);
        ELSE
            v_sql := v_sql||'   , MAX(CASE WHEN category='''||r.src_key_tx
                  || ''' THEN value END) AS '||r.target_col_nm||CHR(10);
        END IF;
    END LOOP;
    v_sql := v_sql||'FROM /* raw source '||p_source_id||' */ DUAL'||CHR(10);
    emit(v_sql);

    -- NORMALIZED-METRIC adapter (reshape to typed buckets) -----------------
    IF resolve('INSTANCE_MTRC').phy_table_nm IS NOT NULL THEN
        v_sql := 'CREATE OR REPLACE VIEW adpt_'||p_source_id||'_'
              || p_data_itm_scd1_ky||'_metric AS'||CHR(10)
              || 'SELECT target_reference_id, trgt_mtrc_cd, scop_cd, s3_ctgy_cd, meth_cd,'||CHR(10)
              || '   MAX(CASE WHEN bucket=''BASE_VAL''   THEN v END) base_val_no,'||CHR(10)
              || '   MAX(CASE WHEN bucket=''TRGT_VAL''   THEN v END) trgt_val_no,'||CHR(10)
              || '   MAX(CASE WHEN bucket=''RPT_YR_VAL'' THEN v END) rpt_yr_val_no'||CHR(10)
              || 'FROM ('||CHR(10)
              || '  /* STUB: one branch per INSTANCE_MTRC mapping row, UNION ALL''d.'||CHR(10)
              || '     HEADER  -> v = <src_column_nm> ;'||CHR(10)
              || '     CATEGORY-> v = CASE WHEN category=src_key_tx THEN value END'||CHR(10)
              || '     carrying trgt_mtrc_cd, scop_cd, s3_ctgy_cd, meth_cd, val_bucket_cd */'||CHR(10)
              || '  SELECT NULL target_reference_id, NULL trgt_mtrc_cd, NULL scop_cd,'||CHR(10)
              || '         NULL s3_ctgy_cd, NULL meth_cd, NULL bucket, NULL v FROM DUAL WHERE 1=0'||CHR(10)
              || ') GROUP BY target_reference_id, trgt_mtrc_cd, scop_cd, s3_ctgy_cd, meth_cd';
        emit(v_sql);
    END IF;

    DBMS_OUTPUT.PUT_LINE('-- adapters generated: source='||p_source_id
        ||' data_itm_scd1_ky='||p_data_itm_scd1_ky);
END generate_target_adapters;
/


-- =============================================================================
-- SEED DATA — EMISSION_REDUCTION_TARGET (CDP 7.53.1 + ESGBook)
-- =============================================================================

INSERT INTO udm_data_itm_rgstr_stub (scd1_ky, data_itm_id, canonical_nm, structure_type)
VALUES (1001, 'DI_EMSN_RED_TGT', 'Emission Reduction Target', 'STRUCTURE');

-- Routing: shared instance key TARGET_REFERENCE_ID across the normalized relations
INSERT INTO udm_struct_storage_map (storage_map_ky,data_itm_scd1_ky,storage_role_cd,phy_table_nm,instance_key_col) VALUES
 (udm_struct_storage_map_seq.NEXTVAL,1001,'INSTANCE_COL' ,'UDM_STD_EMSN_TRGT_SNPSHT_FCT'   ,'TARGET_REFERENCE_ID');
INSERT INTO udm_struct_storage_map (storage_map_ky,data_itm_scd1_ky,storage_role_cd,phy_table_nm,instance_key_col) VALUES
 (udm_struct_storage_map_seq.NEXTVAL,1001,'INSTANCE_MTRC','UDM_STD_EMSN_TRGT_MTRC_SNPSHT'  ,'TARGET_REFERENCE_ID');
INSERT INTO udm_struct_storage_map (storage_map_ky,data_itm_scd1_ky,storage_role_cd,phy_table_nm,instance_key_col) VALUES
 (udm_struct_storage_map_seq.NEXTVAL,1001,'ATTR_KV'      ,'UDM_STD_OBS_ATTR'               ,'TARGET_REFERENCE_ID');
INSERT INTO udm_struct_storage_map (storage_map_ky,data_itm_scd1_ky,storage_role_cd,phy_table_nm,instance_key_col) VALUES
 (udm_struct_storage_map_seq.NEXTVAL,1001,'SCOP_LIST'    ,'UDM_STD_OBS_INCL_SCOP_LST_SNPSHT','TARGET_REFERENCE_ID');
INSERT INTO udm_struct_storage_map (storage_map_ky,data_itm_scd1_ky,storage_role_cd,phy_table_nm,instance_key_col) VALUES
 (udm_struct_storage_map_seq.NEXTVAL,1001,'NZ_LINK'      ,'UDM_STD_TRGT_NZ_LINK_LST_SNPSHT','TARGET_REFERENCE_ID');

-- Elements ---------------------------------------------------------------------
-- INSTANCE_COL (singular scalars)
INSERT INTO udm_data_itm_elmt (elmt_ky,data_itm_scd1_ky,data_itm_id,elmt_cd,elmt_name_tx,role_cd,storage_role_cd,value_type,cardinality,target_col_nm,is_mandatory)
 VALUES (udm_data_itm_elmt_seq.NEXTVAL,1001,'DI_EMSN_RED_TGT','TARGET_REFERENCE_ID','Target reference number','IDENTIFYING','INSTANCE_COL','CODE','ONE','TARGET_REFERENCE_ID','Y');
INSERT INTO udm_data_itm_elmt (elmt_ky,data_itm_scd1_ky,data_itm_id,elmt_cd,elmt_name_tx,role_cd,storage_role_cd,value_type,cardinality,target_col_nm,is_mandatory)
 VALUES (udm_data_itm_elmt_seq.NEXTVAL,1001,'DI_EMSN_RED_TGT','YEAR_TARGET_SET','Year target was set','MEASURE','INSTANCE_COL','NUMBER','ONE','YEAR_TARGET_SET_NO','N');
INSERT INTO udm_data_itm_elmt (elmt_ky,data_itm_scd1_ky,data_itm_id,elmt_cd,elmt_name_tx,role_cd,storage_role_cd,value_type,cardinality,target_col_nm,is_mandatory)
 VALUES (udm_data_itm_elmt_seq.NEXTVAL,1001,'DI_EMSN_RED_TGT','TARGET_YEAR','Target year','MEASURE','INSTANCE_COL','NUMBER','ONE','TARGET_YEAR_NO','Y');
INSERT INTO udm_data_itm_elmt (elmt_ky,data_itm_scd1_ky,data_itm_id,elmt_cd,elmt_name_tx,role_cd,storage_role_cd,value_type,cardinality,target_col_nm,is_mandatory)
 VALUES (udm_data_itm_elmt_seq.NEXTVAL,1001,'DI_EMSN_RED_TGT','TARGET_STATUS','Target status in reporting year','MEASURE','INSTANCE_COL','CODE','ONE','TARGET_STATUS_CD','N');
INSERT INTO udm_data_itm_elmt (elmt_ky,data_itm_scd1_ky,data_itm_id,elmt_cd,elmt_name_tx,role_cd,storage_role_cd,value_type,cardinality,target_col_nm,is_mandatory)
 VALUES (udm_data_itm_elmt_seq.NEXTVAL,1001,'DI_EMSN_RED_TGT','IS_SCIENCE_BASED','Is this a science-based target','MEASURE','INSTANCE_COL','CODE','ONE','SBTI_STATUS_CD','N');
INSERT INTO udm_data_itm_elmt (elmt_ky,data_itm_scd1_ky,data_itm_id,elmt_cd,elmt_name_tx,role_cd,storage_role_cd,value_type,cardinality,target_col_nm,is_mandatory)
 VALUES (udm_data_itm_elmt_seq.NEXTVAL,1001,'DI_EMSN_RED_TGT','TARGETED_REDUCTION_PCT','Targeted reduction from base year (%)','MEASURE','INSTANCE_COL','NUMBER','ONE','TARGETED_REDUCTION_PCT_NO','N');

-- INSTANCE_MTRC (governed metric, repeats over scope/category/method)
INSERT INTO udm_data_itm_elmt (elmt_ky,data_itm_scd1_ky,data_itm_id,elmt_cd,elmt_name_tx,role_cd,storage_role_cd,value_type,cardinality,trgt_mtrc_cd,is_mandatory)
 VALUES (udm_data_itm_elmt_seq.NEXTVAL,1001,'DI_EMSN_RED_TGT','EMISSIONS_COVERED','Emissions covered by target (base/target/reporting)','MEASURE','INSTANCE_MTRC','NUMBER','MANY','EMISSIONS_COVERED','N');

-- ATTR_KV (narrative, NOT flattened)
INSERT INTO udm_data_itm_elmt (elmt_ky,data_itm_scd1_ky,data_itm_id,elmt_cd,elmt_name_tx,role_cd,storage_role_cd,value_type,cardinality,is_mandatory)
 VALUES (udm_data_itm_elmt_seq.NEXTVAL,1001,'DI_EMSN_RED_TGT','TARGET_COMMENTARY','Please explain target coverage and progress','NARRATIVE','ATTR_KV','TEXT','ONE','N');

-- SCOP_LIST (multi-valued qualifier)
INSERT INTO udm_data_itm_elmt (elmt_ky,data_itm_scd1_ky,data_itm_id,elmt_cd,elmt_name_tx,role_cd,storage_role_cd,value_type,cardinality,is_mandatory)
 VALUES (udm_data_itm_elmt_seq.NEXTVAL,1001,'DI_EMSN_RED_TGT','INCLUDED_SCOPE','Scope(s) covered by target','QUALIFIER','SCOP_LIST','CODE','MANY','N');

-- NZ_LINK (instance-to-instance linkage)
INSERT INTO udm_data_itm_elmt (elmt_ky,data_itm_scd1_ky,data_itm_id,elmt_cd,elmt_name_tx,role_cd,storage_role_cd,value_type,cardinality,is_mandatory)
 VALUES (udm_data_itm_elmt_seq.NEXTVAL,1001,'DI_EMSN_RED_TGT','NZ_LINKED_TARGET_REF','Linked net-zero target reference','LINKAGE','NZ_LINK','CODE','MANY','N');


-- Source mappings --------------------------------------------------------------
-- CDP (HEADER): singular scalars
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Target reference number','C_TGT_REF' FROM udm_data_itm_elmt WHERE elmt_cd='TARGET_REFERENCE_ID';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Year target was set','C_YR_SET' FROM udm_data_itm_elmt WHERE elmt_cd='YEAR_TARGET_SET';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Target year','C_TGT_YR' FROM udm_data_itm_elmt WHERE elmt_cd='TARGET_YEAR';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Target status in reporting year','C_STATUS' FROM udm_data_itm_elmt WHERE elmt_cd='TARGET_STATUS';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Is this a science-based target?','C_SBTI' FROM udm_data_itm_elmt WHERE elmt_cd='IS_SCIENCE_BASED';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Targeted reduction from base year (%)','C_RED_PCT' FROM udm_data_itm_elmt WHERE elmt_cd='TARGETED_REDUCTION_PCT';

-- CDP (HEADER): the column explosion -> one governed metric, decoded by scope+bucket
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm,val_bucket_cd,scop_cd)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Base year Scope 1 emissions covered by target (metric tons CO2e)','C_BY_S1','BASE_VAL','SCOPE_1' FROM udm_data_itm_elmt WHERE elmt_cd='EMISSIONS_COVERED';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm,val_bucket_cd,scop_cd)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Target year Scope 1 emissions covered by target (metric tons CO2e)','C_TY_S1','TRGT_VAL','SCOPE_1' FROM udm_data_itm_elmt WHERE elmt_cd='EMISSIONS_COVERED';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm,val_bucket_cd,scop_cd)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Reporting year Scope 1 emissions covered by target (metric tons CO2e)','C_RY_S1','RPT_YR_VAL','SCOPE_1' FROM udm_data_itm_elmt WHERE elmt_cd='EMISSIONS_COVERED';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm,val_bucket_cd,scop_cd)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Base year Scope 2 emissions covered by target (metric tons CO2e)','C_BY_S2','BASE_VAL','SCOPE_2' FROM udm_data_itm_elmt WHERE elmt_cd='EMISSIONS_COVERED';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm,val_bucket_cd,scop_cd)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Target year Scope 2 emissions covered by target (metric tons CO2e)','C_TY_S2','TRGT_VAL','SCOPE_2' FROM udm_data_itm_elmt WHERE elmt_cd='EMISSIONS_COVERED';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm,val_bucket_cd,scop_cd)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Reporting year Scope 2 emissions covered by target (metric tons CO2e)','C_RY_S2','RPT_YR_VAL','SCOPE_2' FROM udm_data_itm_elmt WHERE elmt_cd='EMISSIONS_COVERED';

-- CDP (HEADER): narrative + list + linkage
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Please explain target coverage and identify any exclusions','C_COMMENT' FROM udm_data_itm_elmt WHERE elmt_cd='TARGET_COMMENTARY';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Scope(s)','C_SCOPES' FROM udm_data_itm_elmt WHERE elmt_cd='INCLUDED_SCOPE';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm)
 SELECT udm_src_col_map_seq.NEXTVAL,'CDP','7.53.1',elmt_ky,'HEADER','Linked net-zero target reference number','C_NZ_LINK' FROM udm_data_itm_elmt WHERE elmt_cd='NZ_LINKED_TARGET_REF';

-- ESGBook (CATEGORY): same elements, identity carried in category values
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm)
 SELECT udm_src_col_map_seq.NEXTVAL,'ESGBOOK','EMSN_RED',elmt_ky,'CATEGORY','target_id','ESG_VALUE' FROM udm_data_itm_elmt WHERE elmt_cd='TARGET_REFERENCE_ID';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm)
 SELECT udm_src_col_map_seq.NEXTVAL,'ESGBOOK','EMSN_RED',elmt_ky,'CATEGORY','target_year','ESG_VALUE' FROM udm_data_itm_elmt WHERE elmt_cd='TARGET_YEAR';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm)
 SELECT udm_src_col_map_seq.NEXTVAL,'ESGBOOK','EMSN_RED',elmt_ky,'CATEGORY','reduction_percentage','ESG_VALUE' FROM udm_data_itm_elmt WHERE elmt_cd='TARGETED_REDUCTION_PCT';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm,val_bucket_cd,scop_cd)
 SELECT udm_src_col_map_seq.NEXTVAL,'ESGBOOK','EMSN_RED',elmt_ky,'CATEGORY','base_year_emissions_scope1','ESG_VALUE','BASE_VAL','SCOPE_1' FROM udm_data_itm_elmt WHERE elmt_cd='EMISSIONS_COVERED';
INSERT INTO udm_data_itm_src_col_map (src_col_map_ky,source_id,src_metric_cd,elmt_ky,src_key_type,src_key_tx,src_column_nm,val_bucket_cd,scop_cd)
 SELECT udm_src_col_map_seq.NEXTVAL,'ESGBOOK','EMSN_RED',elmt_ky,'CATEGORY','target_year_emissions_scope1','ESG_VALUE','TRGT_VAL','SCOPE_1' FROM udm_data_itm_elmt WHERE elmt_cd='EMISSIONS_COVERED';

COMMIT;

-- =============================================================================
-- VISUALIZATION
-- =============================================================================
PROMPT
PROMPT ==== V_UDM_STRUCT_CATALOG (business: element -> target table/column) ====
COLUMN elmt_cd        FORMAT A24
COLUMN role_cd        FORMAT A11
COLUMN storage_role_cd FORMAT A13
COLUMN target_table   FORMAT A32
COLUMN target_mapping FORMAT A46
SELECT elmt_cd, role_cd, storage_role_cd, target_table, target_mapping
FROM   v_udm_struct_catalog;

PROMPT
PROMPT ==== V_UDM_SRC_TGT_LINEAGE (source key -> canonical element -> target) ====
COLUMN source_id     FORMAT A8
COLUMN src_key_type  FORMAT A9
COLUMN src_key_tx    FORMAT A46
COLUMN elmt_cd       FORMAT A22
COLUMN target_table  FORMAT A30
COLUMN target_column FORMAT A16
COLUMN scop_cd       FORMAT A8
SELECT source_id, src_key_type, src_key_tx, elmt_cd, target_table, target_column, scop_cd
FROM   v_udm_src_tgt_lineage;

PROMPT
PROMPT ==== generate_target_adapters dry-run: CDP ====
EXEC generate_target_adapters('CDP', 1001, 'N');

-- =============================================================================
-- END udm_struct_catalog_v2.sql
-- =============================================================================
