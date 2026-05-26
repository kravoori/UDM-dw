-- =============================================================================
-- UDM DI FRAMEWORK — UDM_PHYS_CLMT_RSK_FCT
-- Domain  : Physical Climate Risk
-- Version : 1.0
-- =============================================================================
--
-- SCOPE
-- ─────────────────────────────────────────────────────────────────────────────
-- Source table:   SOURCE_1_FCT
-- Target table:   UDM_PHYS_CLMT_RSK_FCT
-- Entity bridge:  SOURCE_1_FCT.VENDOR_ENTITY_KY
--                 → udm_company_xref.external_id
--                 → udm_entity_registry.ENTITY_KY
-- Natural keys:   ENTITY_KY + FSCL_YR_NO + SRC_SYS_SHRT_NM
--
-- DATA ITEMS COVERED
-- ─────────────────────────────────────────────────────────────────────────────
-- ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO      ClimateRiskExposureScore        NUMBER
-- ENV_L23_PR_CLMT_RSK_ID_ASES_MNG_STATUS_FL  Identification+Mgmt Status VARCHAR2
-- ENV_L23_PR_CLMT_RSK_ID_ASES_STATUS_FL ClimateRiskAssessmentStatus     VARCHAR2
-- ENV_L23_PR_CLMT_RSK_MNG_PROC_DISC_STATUS_FL MgmtProcedureDisclosure   VARCHAR2
-- ENV_L23_PR_SCNRO_ANLYS_TYPE_TX        ScenarioAnalysisType            VARCHAR2
--
-- CHECKS IMPLEMENTED (all set-based — no row loops)
-- ─────────────────────────────────────────────────────────────────────────────
-- PRE-LOAD (on source table before harmonisation):
--   CHK-01  VOLUME       Source row count logged for baseline
--   CHK-02  DUPE         Duplicate (VENDOR_ENTITY_KY, FiscalYearNumber) in source
--   CHK-03  ENTITY_RESOL Vendor entity IDs with no xref mapping
--
-- POST-LOAD (on target after harmonisation engine writes):
--   CHK-04  VOLUME       Target vs source row count — expected = source minus dupes
--   CHK-05  VOLUME_DRIFT Target row count vs prior fiscal year (threshold: ±20%)
--   CHK-06  BOUNDS       ClimateRiskExposureScore must be 0–100
--   CHK-07  DRIFT        ClimateRiskExposureScore avg vs prior year (threshold: ±25%)
--   CHK-08  DOMAIN_VAL   Status flags must be in governed valid value set
--   CHK-09  DOMAIN_VAL   ScenarioAnalysisType must be in governed valid value set
--   CHK-10  CONSISTENCY  If ID_ASES_STATUS populated, MNG_STATUS must also be populated
--   CHK-11  CONSISTENCY  If MNG_PROC_DISC_STATUS populated, SCNRO_ANLYS_TYPE expected
--   CHK-12  COMPLETENESS Score populated for ≥ configured threshold % of entities
--   CHK-13  DUPE         Natural key uniqueness in target after load
--   CHK-14  CHECKSUM     ROW_CHK_SUM_TX recomputed and validated against stored value
--
-- NULL and data type checks are NOT implemented here.
-- They are auto-derived at engine runtime from udm_data_item (is_mndty_fl,
-- data_typ_cd) and udm_data_item_src_map. Results written to udm_dq_results
-- with check_source=AUTO_DERIVED during the LOAD step.
--
-- ARCHITECTURE NOTES
-- ─────────────────────────────────────────────────────────────────────────────
-- All checks are a single INSERT INTO udm_dq_results ... SELECT.
-- No cursors. No FETCH loops. No row-by-row processing.
-- The package is called as step 5 (DI_CHECK) within udm_process_run.
-- Lineage_id must be the DI_CHECK step lineage row for this process run.
-- Results are written with movement_point = 'VS_TO_ARB' (post-load, pre-arb)
-- or 'STAGE_TO_VS' (pre-load, on source).
-- =============================================================================


-- =============================================================================
-- PREREQUISITE — DQ RULE SEED DATA
-- Run once per environment. Seeds the configured threshold checks.
-- Auto-derived checks (NULL, type, entity resolution) need no seed data.
-- =============================================================================

INSERT INTO udm_dq_rules (
    rule_id, domain_id, data_itm_nm, check_type,
    threshold, min_value, max_value, action,
    is_active, effective_from, created_by
)
SELECT * FROM (
    -- CHK-06 BOUNDS — exposure score must be 0 to 100
    SELECT 'DQR-PHYS-001', 'PHYSICAL_CLIMATE_RISK',
           'ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO', 'BOUNDS',
           NULL, 0, 100, 'QUARANTINE', 'Y', DATE '2024-01-01', 'SYSTEM'
    FROM DUAL
    UNION ALL
    -- CHK-07 DRIFT — exposure score avg change vs prior year > 25% = ALERT
    SELECT 'DQR-PHYS-002', 'PHYSICAL_CLIMATE_RISK',
           'ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO', 'DRIFT',
           25, NULL, NULL, 'ALERT', 'Y', DATE '2024-01-01', 'SYSTEM'
    FROM DUAL
    UNION ALL
    -- CHK-05 VOLUME_DRIFT — row count vs prior year > 20% = ALERT
    -- Uses metric_name convention for row-count checks: __ROW_COUNT__
    SELECT 'DQR-PHYS-003', 'PHYSICAL_CLIMATE_RISK',
           '__ROW_COUNT__', 'DRIFT',
           20, NULL, NULL, 'ALERT', 'Y', DATE '2024-01-01', 'SYSTEM'
    FROM DUAL
    UNION ALL
    -- CHK-12 COMPLETENESS — score populated for >= 60% of entities
    SELECT 'DQR-PHYS-004', 'PHYSICAL_CLIMATE_RISK',
           'ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO', 'COMPLETENESS',
           60, NULL, NULL, 'ALERT', 'Y', DATE '2024-01-01', 'SYSTEM'
    FROM DUAL
);
COMMIT;


-- =============================================================================
-- PACKAGE SPECIFICATION
-- =============================================================================

CREATE OR REPLACE PACKAGE udm_di_phys_clmt_rsk AS

    -- ─────────────────────────────────────────────────────────────────────────
    -- MAIN ENTRY POINT
    -- Called by scheduler as step 5 (DI_CHECK) of the process run.
    --
    -- p_fscl_yr_no    : fiscal year being validated e.g. 2024
    -- p_src_sys_nm    : source system short name e.g. 'VENDOR_A'
    -- p_lineage_id    : DI_CHECK step lineage_id for this process run
    -- p_process_run_id: parent process run
    -- ─────────────────────────────────────────────────────────────────────────
    PROCEDURE run (
        p_fscl_yr_no        IN NUMBER,
        p_src_sys_nm        IN VARCHAR2,
        p_lineage_id        IN VARCHAR2,
        p_process_run_id    IN VARCHAR2
    );

    -- ─────────────────────────────────────────────────────────────────────────
    -- INDIVIDUAL STEPS — exposed for targeted re-runs and testing
    -- ─────────────────────────────────────────────────────────────────────────
    PROCEDURE chk_pre_load  (p_fscl_yr_no IN NUMBER, p_src_sys_nm IN VARCHAR2, p_lineage_id IN VARCHAR2);
    PROCEDURE chk_post_load (p_fscl_yr_no IN NUMBER, p_src_sys_nm IN VARCHAR2, p_lineage_id IN VARCHAR2);

END udm_di_phys_clmt_rsk;
/


-- =============================================================================
-- PACKAGE BODY
-- =============================================================================

CREATE OR REPLACE PACKAGE BODY udm_di_phys_clmt_rsk AS

    -- ─────────────────────────────────────────────────────────────────────────
    -- Private constants
    -- ─────────────────────────────────────────────────────────────────────────
    c_domain        CONSTANT VARCHAR2(50) := 'PHYSICAL_CLIMATE_RISK';
    c_target        CONSTANT VARCHAR2(128):= 'UDM_PHYS_CLMT_RSK_FCT';
    c_pkg           CONSTANT VARCHAR2(50) := 'udm_di_phys_clmt_rsk';

    -- Valid value sets — governed constants
    -- In production these would be read from a udm_ref_domain_values table.
    -- Declared here for explicitness and traceability.
    c_valid_status  CONSTANT VARCHAR2(200):= '''Y'',''N'',''PARTIAL'',''NOT_APPLICABLE''';
    c_valid_scnro   CONSTANT VARCHAR2(200):= '''ORDERLY'',''DISORDERLY'',''HOT_HOUSE'',''PHYSICAL_ONLY'',''NOT_ASSESSED''';


    -- =========================================================================
    -- PRE-LOAD CHECKS (on SOURCE_1_FCT before harmonisation writes to target)
    -- Movement point: STAGE_TO_VS
    -- One INSERT per check — all set-based.
    -- =========================================================================
    PROCEDURE chk_pre_load (
        p_fscl_yr_no    IN NUMBER,
        p_src_sys_nm    IN VARCHAR2,
        p_lineage_id    IN VARCHAR2
    ) AS
        v_src_count     NUMBER;
        v_prior_yr      NUMBER := p_fscl_yr_no - 1;
    BEGIN

        -- ── CHK-01: VOLUME — Source row count baseline ────────────────────────
        -- Logs the source row count for the period. PASS always.
        -- This establishes the baseline that CHK-04 compares against.
        SELECT COUNT(*)
        INTO   v_src_count
        FROM   SOURCE_1_FCT
        WHERE  FiscalYearNumber = p_fscl_yr_no;

        INSERT INTO udm_dq_results (
            result_id, lineage_id, rule_id,
            check_type, check_source, domain_id,
            data_itm_nm, movement_point, check_result,
            actual_value, expected_value, coverage_period,
            action_taken, checked_at
        ) VALUES (
            'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' || LPAD(udm_dq_result_seq.NEXTVAL,5,'0'),
            p_lineage_id, NULL,
            'COMPLETENESS', 'CONFIGURED', c_domain,
            '__ROW_COUNT__', 'STAGE_TO_VS', 'PASS',
            v_src_count, NULL, TO_CHAR(p_fscl_yr_no),
            'NONE', SYSDATE
        );


        -- ── CHK-02: DUPE — Duplicate natural key in source ───────────────────
        -- Finds (VENDOR_ENTITY_KY, FiscalYearNumber) combinations appearing
        -- more than once. These would produce duplicate rows in the target
        -- after entity resolution.
        INSERT INTO udm_dq_results (
            result_id, lineage_id, rule_id,
            check_type, check_source, domain_id,
            data_itm_nm, movement_point, check_result,
            actual_value, expected_value, entity_key, coverage_period,
            action_taken, checked_at
        )
        SELECT
            'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' ||
                LPAD(udm_dq_result_seq.NEXTVAL,5,'0'),
            p_lineage_id,
            NULL,                               -- no dq_rule row for DUPE
            'COMPLETENESS',                     -- repurposed: structural integrity
            'AUTO_DERIVED',
            c_domain,
            '__NATURAL_KEY__',
            'STAGE_TO_VS',
            CASE WHEN dup_count > 1 THEN 'FAIL' ELSE 'PASS' END,
            dup_count,
            1,                                  -- expected: 1 row per natural key
            TO_CHAR(vendor_entity_ky),          -- store offending vendor key
            TO_CHAR(fiscal_year_number),
            CASE WHEN dup_count > 1 THEN 'ALERT' ELSE 'NONE' END,
            SYSDATE
        FROM (
            SELECT
                VENDOR_ENTITY_KY        AS vendor_entity_ky,
                FiscalYearNumber        AS fiscal_year_number,
                COUNT(*)                AS dup_count
            FROM   SOURCE_1_FCT
            WHERE  FiscalYearNumber = p_fscl_yr_no
            GROUP BY VENDOR_ENTITY_KY, FiscalYearNumber
            HAVING COUNT(*) > 1     -- only surface the failures
        );
        -- NOTE: If no duplicates exist this INSERT inserts zero rows.
        -- The absence of FAIL rows for __NATURAL_KEY__ is itself evidence of passing.


        -- ── CHK-03: ENTITY RESOLUTION — Vendor IDs with no xref mapping ──────
        -- Identifies source rows whose VENDOR_ENTITY_KY has no active entry
        -- in udm_company_xref. These rows will create VENDOR_ONLY entities
        -- (not quarantined per v8 design) but are surfaced here for visibility.
        -- Severity: ALERT — data will still load under VENDOR_ONLY entity_key.
        INSERT INTO udm_dq_results (
            result_id, lineage_id, rule_id,
            check_type, check_source, domain_id,
            data_itm_nm, movement_point, check_result,
            actual_value, expected_value, entity_key, coverage_period,
            action_taken, checked_at
        )
        SELECT
            'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' ||
                LPAD(udm_dq_result_seq.NEXTVAL,5,'0'),
            p_lineage_id,
            NULL,
            'COMPLETENESS',
            'AUTO_DERIVED',
            c_domain,
            '__ENTITY_RESOLUTION__',
            'STAGE_TO_VS',
            'WARNING',                          -- WARNING not FAIL — engine handles it
            COUNT(*),                           -- number of unresolvable rows
            0,                                  -- expected: all rows resolve
            TO_CHAR(src.VENDOR_ENTITY_KY),
            TO_CHAR(p_fscl_yr_no),
            'ALERT',
            SYSDATE
        FROM   SOURCE_1_FCT  src
        WHERE  src.FiscalYearNumber = p_fscl_yr_no
        AND    NOT EXISTS (
            SELECT 1
            FROM   udm_company_xref  cx
            WHERE  cx.vendor_id    = p_src_sys_nm
            AND    cx.external_id  = TO_CHAR(src.VENDOR_ENTITY_KY)
            AND    cx.match_status IN ('CONFIRMED','ENGINE')
            AND    (cx.effective_to IS NULL OR cx.effective_to >= SYSDATE)
        )
        GROUP BY src.VENDOR_ENTITY_KY
        HAVING COUNT(*) > 0;

    END chk_pre_load;


    -- =========================================================================
    -- POST-LOAD CHECKS (on UDM_PHYS_CLMT_RSK_FCT after harmonisation)
    -- Movement point: VS_TO_ARB
    -- One INSERT per check — all set-based.
    -- =========================================================================
    PROCEDURE chk_post_load (
        p_fscl_yr_no    IN NUMBER,
        p_src_sys_nm    IN VARCHAR2,
        p_lineage_id    IN VARCHAR2
    ) AS
        v_prior_yr          NUMBER := p_fscl_yr_no - 1;
        v_target_count      NUMBER;
        v_prior_count       NUMBER;
        v_drift_pct         NUMBER;
        v_drift_threshold   NUMBER := 20;   -- from DQR-PHYS-003
        v_bounds_min        NUMBER := 0;
        v_bounds_max        NUMBER := 100;  -- from DQR-PHYS-001
        v_score_drift_thr   NUMBER := 25;   -- from DQR-PHYS-002
        v_completeness_thr  NUMBER := 60;   -- from DQR-PHYS-004
    BEGIN

        -- ── CHK-04: VOLUME — Target vs source row count ───────────────────────
        -- Compares how many rows landed in the target vs how many were in source.
        -- Expected: target count = source count (after dedup).
        -- A shortfall indicates rows were quarantined or dropped.
        INSERT INTO udm_dq_results (
            result_id, lineage_id, rule_id,
            check_type, check_source, domain_id,
            data_itm_nm, movement_point, check_result,
            actual_value, expected_value, coverage_period,
            action_taken, checked_at
        )
        WITH
        src_cnt AS (
            SELECT COUNT(DISTINCT VENDOR_ENTITY_KY) AS cnt
            FROM   SOURCE_1_FCT
            WHERE  FiscalYearNumber = p_fscl_yr_no
        ),
        tgt_cnt AS (
            SELECT COUNT(*) AS cnt
            FROM   UDM_PHYS_CLMT_RSK_FCT
            WHERE  FSCL_YR_NO    = p_fscl_yr_no
            AND    SRC_SYS_SHRT_NM = p_src_sys_nm
            AND    CUR_FL          = 1
        )
        SELECT
            'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' ||
                LPAD(udm_dq_result_seq.NEXTVAL,5,'0'),
            p_lineage_id, 'DQR-PHYS-003',
            'COMPLETENESS', 'CONFIGURED', c_domain,
            '__ROW_COUNT__', 'VS_TO_ARB',
            CASE WHEN ABS((tgt.cnt - src.cnt) / NULLIF(src.cnt,0) * 100) > v_drift_threshold
                 THEN 'FAIL'
                 ELSE 'PASS'
            END,
            tgt.cnt, src.cnt,
            TO_CHAR(p_fscl_yr_no),
            CASE WHEN ABS((tgt.cnt - src.cnt) / NULLIF(src.cnt,0) * 100) > v_drift_threshold
                 THEN 'ALERT'
                 ELSE 'NONE'
            END,
            SYSDATE
        FROM src_cnt src, tgt_cnt tgt;


        -- ── CHK-05: VOLUME DRIFT — Row count vs prior fiscal year ─────────────
        -- Compares entity count this year vs prior year.
        -- Significant drop or spike signals a sourcing problem.
        INSERT INTO udm_dq_results (
            result_id, lineage_id, rule_id,
            check_type, check_source, domain_id,
            data_itm_nm, movement_point, check_result,
            actual_value, expected_value, coverage_period,
            action_taken, checked_at
        )
        WITH
        curr_cnt AS (
            SELECT COUNT(*) AS cnt
            FROM   UDM_PHYS_CLMT_RSK_FCT
            WHERE  FSCL_YR_NO      = p_fscl_yr_no
            AND    SRC_SYS_SHRT_NM = p_src_sys_nm
            AND    CUR_FL          = 1
        ),
        prior_cnt AS (
            SELECT COUNT(*) AS cnt
            FROM   UDM_PHYS_CLMT_RSK_FCT
            WHERE  FSCL_YR_NO      = v_prior_yr
            AND    SRC_SYS_SHRT_NM = p_src_sys_nm
            AND    CUR_FL          = 1
        )
        SELECT
            'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' ||
                LPAD(udm_dq_result_seq.NEXTVAL,5,'0'),
            p_lineage_id, 'DQR-PHYS-003',
            'DRIFT', 'CONFIGURED', c_domain,
            '__ROW_COUNT__', 'VS_TO_ARB',
            CASE
                WHEN pr.cnt = 0 THEN 'WARNING'  -- no prior year = first load
                WHEN ABS((cr.cnt - pr.cnt) / NULLIF(pr.cnt,0) * 100) > v_drift_threshold
                     THEN 'FAIL'
                ELSE 'PASS'
            END,
            cr.cnt,
            pr.cnt,
            TO_CHAR(p_fscl_yr_no),
            CASE
                WHEN pr.cnt = 0 THEN 'ALERT'
                WHEN ABS((cr.cnt - pr.cnt) / NULLIF(pr.cnt,0) * 100) > v_drift_threshold
                     THEN 'ALERT'
                ELSE 'NONE'
            END,
            SYSDATE
        FROM curr_cnt cr, prior_cnt pr;


        -- ── CHK-06: BOUNDS — Exposure score must be 0 to 100 ─────────────────
        -- Finds any row where score is outside the governed range.
        -- action = QUARANTINE per DQR-PHYS-001 (post-load ALERT here;
        -- the harmonisation engine would have QUARANTINED at load time
        -- if this check was wired to the load step).
        -- Here we surface any that slipped through for investigation.
        INSERT INTO udm_dq_results (
            result_id, lineage_id, rule_id,
            check_type, check_source, domain_id,
            data_itm_nm, movement_point, check_result,
            actual_value, expected_value, entity_key, coverage_period,
            action_taken, checked_at
        )
        SELECT
            'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' ||
                LPAD(udm_dq_result_seq.NEXTVAL,5,'0'),
            p_lineage_id,
            'DQR-PHYS-001',
            'BOUNDS',
            'CONFIGURED',
            c_domain,
            'ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO',
            'VS_TO_ARB',
            'FAIL',
            ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO,
            NULL,                               -- no single expected value for bounds
            ENTITY_KY,
            TO_CHAR(FSCL_YR_NO),
            'ALERT',
            SYSDATE
        FROM   UDM_PHYS_CLMT_RSK_FCT
        WHERE  FSCL_YR_NO      = p_fscl_yr_no
        AND    SRC_SYS_SHRT_NM = p_src_sys_nm
        AND    CUR_FL          = 1
        AND    ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO IS NOT NULL
        AND    (
            ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO < v_bounds_min
            OR ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO > v_bounds_max
        );
        -- Zero rows inserted = all in-range = implicit pass.


        -- ── CHK-07: DRIFT — Exposure score avg change vs prior year ──────────
        -- Compares the portfolio-level average score year-on-year.
        -- A >25% swing in the average signals a sourcing or methodology change.
        INSERT INTO udm_dq_results (
            result_id, lineage_id, rule_id,
            check_type, check_source, domain_id,
            data_itm_nm, movement_point, check_result,
            actual_value, expected_value, coverage_period,
            action_taken, checked_at
        )
        WITH
        curr_avg AS (
            SELECT AVG(ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO) AS avg_score
            FROM   UDM_PHYS_CLMT_RSK_FCT
            WHERE  FSCL_YR_NO      = p_fscl_yr_no
            AND    SRC_SYS_SHRT_NM = p_src_sys_nm
            AND    CUR_FL          = 1
            AND    ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO IS NOT NULL
        ),
        prior_avg AS (
            SELECT AVG(ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO) AS avg_score
            FROM   UDM_PHYS_CLMT_RSK_FCT
            WHERE  FSCL_YR_NO      = v_prior_yr
            AND    SRC_SYS_SHRT_NM = p_src_sys_nm
            AND    CUR_FL          = 1
            AND    ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO IS NOT NULL
        )
        SELECT
            'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' ||
                LPAD(udm_dq_result_seq.NEXTVAL,5,'0'),
            p_lineage_id, 'DQR-PHYS-002',
            'DRIFT', 'CONFIGURED', c_domain,
            'ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO', 'VS_TO_ARB',
            CASE
                WHEN pr.avg_score IS NULL THEN 'WARNING'   -- no prior year data
                WHEN ABS((cr.avg_score - pr.avg_score) / NULLIF(pr.avg_score,0) * 100)
                     > v_score_drift_thr THEN 'FAIL'
                ELSE 'PASS'
            END,
            ROUND(cr.avg_score, 4),
            ROUND(pr.avg_score, 4),
            TO_CHAR(p_fscl_yr_no),
            CASE
                WHEN pr.avg_score IS NULL THEN 'ALERT'
                WHEN ABS((cr.avg_score - pr.avg_score) / NULLIF(pr.avg_score,0) * 100)
                     > v_score_drift_thr THEN 'ALERT'
                ELSE 'NONE'
            END,
            SYSDATE
        FROM curr_avg cr, prior_avg pr;


        -- ── CHK-08: DOMAIN VALUE — Status flags valid value check ─────────────
        -- The three status flag columns must contain governed values only.
        -- Checks all three in one query using UNPIVOT — one DQ result per
        -- offending (entity, column) combination.
        -- Valid set: Y, N, PARTIAL, NOT_APPLICABLE (sourced from c_valid_status).
        INSERT INTO udm_dq_results (
            result_id, lineage_id, rule_id,
            check_type, check_source, domain_id,
            data_itm_nm, movement_point, check_result,
            actual_value, expected_value, entity_key, coverage_period,
            action_taken, checked_at
        )
        SELECT
            'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' ||
                LPAD(udm_dq_result_seq.NEXTVAL,5,'0'),
            p_lineage_id,
            NULL,
            'COMPLETENESS',         -- closest standard type for domain value check
            'CONFIGURED',
            c_domain,
            col_nm,                 -- which flag column failed
            'VS_TO_ARB',
            'FAIL',
            col_val,                -- the invalid value found
            c_valid_status,         -- expected: one of the valid set
            entity_ky,
            TO_CHAR(p_fscl_yr_no),
            'ALERT',
            SYSDATE
        FROM (
            -- UNPIVOT the three status flag columns into rows
            -- so one SELECT covers all three columns
            SELECT
                ENTITY_KY           AS entity_ky,
                col_nm,
                col_val
            FROM UDM_PHYS_CLMT_RSK_FCT
            UNPIVOT (col_val FOR col_nm IN (
                ENV_L23_PR_CLMT_RSK_ID_ASES_MNG_STATUS_FL  AS 'ENV_L23_PR_CLMT_RSK_ID_ASES_MNG_STATUS_FL',
                ENV_L23_PR_CLMT_RSK_ID_ASES_STATUS_FL      AS 'ENV_L23_PR_CLMT_RSK_ID_ASES_STATUS_FL',
                ENV_L23_PR_CLMT_RSK_MNG_PROC_DISC_STATUS_FL AS 'ENV_L23_PR_CLMT_RSK_MNG_PROC_DISC_STATUS_FL'
            ))
            WHERE FSCL_YR_NO      = p_fscl_yr_no
            AND   SRC_SYS_SHRT_NM = p_src_sys_nm
            AND   CUR_FL          = 1
        )
        WHERE col_val NOT IN ('Y','N','PARTIAL','NOT_APPLICABLE');
        -- UNPIVOT excludes NULLs by default — NULL flags are handled
        -- by AUTO_DERIVED null check at load time (not this package).


        -- ── CHK-09: DOMAIN VALUE — ScenarioAnalysisType valid value check ─────
        -- Scenario type must be in the governed classification list.
        INSERT INTO udm_dq_results (
            result_id, lineage_id, rule_id,
            check_type, check_source, domain_id,
            data_itm_nm, movement_point, check_result,
            actual_value, expected_value, entity_key, coverage_period,
            action_taken, checked_at
        )
        SELECT
            'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' ||
                LPAD(udm_dq_result_seq.NEXTVAL,5,'0'),
            p_lineage_id,
            NULL,
            'COMPLETENESS',
            'CONFIGURED',
            c_domain,
            'ENV_L23_PR_SCNRO_ANLYS_TYPE_TX',
            'VS_TO_ARB',
            'FAIL',
            ENV_L23_PR_SCNRO_ANLYS_TYPE_TX,
            c_valid_scnro,
            ENTITY_KY,
            TO_CHAR(FSCL_YR_NO),
            'ALERT',
            SYSDATE
        FROM   UDM_PHYS_CLMT_RSK_FCT
        WHERE  FSCL_YR_NO      = p_fscl_yr_no
        AND    SRC_SYS_SHRT_NM = p_src_sys_nm
        AND    CUR_FL          = 1
        AND    ENV_L23_PR_SCNRO_ANLYS_TYPE_TX IS NOT NULL
        AND    ENV_L23_PR_SCNRO_ANLYS_TYPE_TX
               NOT IN ('ORDERLY','DISORDERLY','HOT_HOUSE','PHYSICAL_ONLY','NOT_ASSESSED');


        -- ── CHK-10: CONSISTENCY — Assessment chain integrity ──────────────────
        -- Business rule: if climate risk ID assessment STATUS is populated,
        -- the management status must also be populated.
        -- A vendor providing the assessment outcome without the management
        -- status indicates an incomplete delivery.
        -- Severity: WARNING — both may be validly NULL (vendor doesn't cover it)
        -- but populated assessment + NULL management = data quality problem.
        INSERT INTO udm_dq_results (
            result_id, lineage_id, rule_id,
            check_type, check_source, domain_id,
            data_itm_nm, movement_point, check_result,
            actual_value, expected_value, entity_key, coverage_period,
            action_taken, checked_at
        )
        SELECT
            'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' ||
                LPAD(udm_dq_result_seq.NEXTVAL,5,'0'),
            p_lineage_id,
            NULL,
            'COMPLETENESS',
            'CONFIGURED',
            c_domain,
            'ENV_L23_PR_CLMT_RSK_ID_ASES_MNG_STATUS_FL',
            'VS_TO_ARB',
            'FAIL',
            NULL,                       -- actual: NULL (the missing management status)
            'NOT NULL',                 -- expected: should be populated
            ENTITY_KY,
            TO_CHAR(FSCL_YR_NO),
            'ALERT',
            SYSDATE
        FROM   UDM_PHYS_CLMT_RSK_FCT
        WHERE  FSCL_YR_NO      = p_fscl_yr_no
        AND    SRC_SYS_SHRT_NM = p_src_sys_nm
        AND    CUR_FL          = 1
        AND    ENV_L23_PR_CLMT_RSK_ID_ASES_STATUS_FL     IS NOT NULL  -- assessment present
        AND    ENV_L23_PR_CLMT_RSK_ID_ASES_MNG_STATUS_FL IS NULL;     -- management absent


        -- ── CHK-11: CONSISTENCY — Disclosure and scenario analysis alignment ──
        -- Business rule: if management procedure disclosure is populated,
        -- scenario analysis type is expected (though not always mandatory).
        -- Surfaces entities where disclosure exists but no scenario is declared.
        INSERT INTO udm_dq_results (
            result_id, lineage_id, rule_id,
            check_type, check_source, domain_id,
            data_itm_nm, movement_point, check_result,
            actual_value, expected_value, entity_key, coverage_period,
            action_taken, checked_at
        )
        SELECT
            'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' ||
                LPAD(udm_dq_result_seq.NEXTVAL,5,'0'),
            p_lineage_id,
            NULL,
            'COMPLETENESS',
            'CONFIGURED',
            c_domain,
            'ENV_L23_PR_SCNRO_ANLYS_TYPE_TX',
            'VS_TO_ARB',
            'WARNING',
            NULL,
            'NOT NULL',
            ENTITY_KY,
            TO_CHAR(FSCL_YR_NO),
            'ALERT',
            SYSDATE
        FROM   UDM_PHYS_CLMT_RSK_FCT
        WHERE  FSCL_YR_NO      = p_fscl_yr_no
        AND    SRC_SYS_SHRT_NM = p_src_sys_nm
        AND    CUR_FL          = 1
        AND    ENV_L23_PR_CLMT_RSK_MNG_PROC_DISC_STATUS_FL IS NOT NULL  -- disclosure present
        AND    ENV_L23_PR_SCNRO_ANLYS_TYPE_TX               IS NULL;    -- no scenario


        -- ── CHK-12: COMPLETENESS — Score coverage threshold ───────────────────
        -- At least 60% of entities loaded for this period must have a
        -- non-null exposure score (DQR-PHYS-004).
        -- Low coverage suggests a sourcing gap or entity resolution failure.
        INSERT INTO udm_dq_results (
            result_id, lineage_id, rule_id,
            check_type, check_source, domain_id,
            data_itm_nm, movement_point, check_result,
            actual_value, expected_value, coverage_period,
            action_taken, checked_at
        )
        WITH
        coverage AS (
            SELECT
                COUNT(*)                                                      AS total_entities,
                COUNT(ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO)                     AS scored_entities,
                ROUND(
                    COUNT(ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO) * 100.0
                    / NULLIF(COUNT(*),0)
                , 2)                                                           AS score_pct
            FROM   UDM_PHYS_CLMT_RSK_FCT
            WHERE  FSCL_YR_NO      = p_fscl_yr_no
            AND    SRC_SYS_SHRT_NM = p_src_sys_nm
            AND    CUR_FL          = 1
        )
        SELECT
            'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' ||
                LPAD(udm_dq_result_seq.NEXTVAL,5,'0'),
            p_lineage_id, 'DQR-PHYS-004',
            'COMPLETENESS', 'CONFIGURED', c_domain,
            'ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO', 'VS_TO_ARB',
            CASE WHEN score_pct < v_completeness_thr THEN 'FAIL' ELSE 'PASS' END,
            score_pct,          -- actual: % of entities with score
            v_completeness_thr, -- expected: >= 60%
            TO_CHAR(p_fscl_yr_no),
            CASE WHEN score_pct < v_completeness_thr THEN 'ALERT' ELSE 'NONE' END,
            SYSDATE
        FROM coverage;


        -- ── CHK-13: DUPE — Natural key uniqueness in target ───────────────────
        -- After load, (ENTITY_KY, FSCL_YR_NO, SRC_SYS_SHRT_NM) must be unique
        -- for cur_fl=1 rows. A duplicate here means the dedup logic in the
        -- harmonisation engine did not fire correctly.
        INSERT INTO udm_dq_results (
            result_id, lineage_id, rule_id,
            check_type, check_source, domain_id,
            data_itm_nm, movement_point, check_result,
            actual_value, expected_value, entity_key, coverage_period,
            action_taken, checked_at
        )
        SELECT
            'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' ||
                LPAD(udm_dq_result_seq.NEXTVAL,5,'0'),
            p_lineage_id,
            NULL,
            'COMPLETENESS',
            'AUTO_DERIVED',
            c_domain,
            '__NATURAL_KEY__',
            'VS_TO_ARB',
            'FAIL',
            dup_count,
            1,
            ENTITY_KY,
            TO_CHAR(FSCL_YR_NO),
            'ALERT',
            SYSDATE
        FROM (
            SELECT
                ENTITY_KY,
                FSCL_YR_NO,
                SRC_SYS_SHRT_NM,
                COUNT(*) AS dup_count
            FROM   UDM_PHYS_CLMT_RSK_FCT
            WHERE  FSCL_YR_NO      = p_fscl_yr_no
            AND    SRC_SYS_SHRT_NM = p_src_sys_nm
            AND    CUR_FL          = 1
            GROUP BY ENTITY_KY, FSCL_YR_NO, SRC_SYS_SHRT_NM
            HAVING COUNT(*) > 1         -- only surface failures
        );


        -- ── CHK-14: CHECKSUM — ROW_CHK_SUM_TX recomputation ──────────────────
        -- Recomputes the row checksum from the metric columns and compares
        -- against the stored ROW_CHK_SUM_TX value.
        -- A mismatch indicates a row was modified outside the engine
        -- (direct DML, replication error, or storage corruption).
        -- The checksum algorithm must match what the harmonisation engine
        -- wrote at load time. Adjust the STANDARD_HASH expression to match
        -- your engine's implementation.
        INSERT INTO udm_dq_results (
            result_id, lineage_id, rule_id,
            check_type, check_source, domain_id,
            data_itm_nm, movement_point, check_result,
            actual_value, expected_value, entity_key, coverage_period,
            action_taken, checked_at
        )
        SELECT
            'DQR-' || TO_CHAR(SYSDATE,'YYYYMMDD') || '-' ||
                LPAD(udm_dq_result_seq.NEXTVAL,5,'0'),
            p_lineage_id,
            NULL,
            'COMPLETENESS',
            'AUTO_DERIVED',
            c_domain,
            'ROW_CHK_SUM_TX',
            'VS_TO_ARB',
            'FAIL',
            NULL,
            ROW_CHK_SUM_TX,     -- expected: what was stored at load time
            ENTITY_KY,
            TO_CHAR(FSCL_YR_NO),
            'ALERT',
            SYSDATE
        FROM   UDM_PHYS_CLMT_RSK_FCT
        WHERE  FSCL_YR_NO      = p_fscl_yr_no
        AND    SRC_SYS_SHRT_NM = p_src_sys_nm
        AND    CUR_FL          = 1
        AND    ROW_CHK_SUM_TX != RAWTOHEX(STANDARD_HASH(
                    -- Recompute from current column values in same order as engine
                    NVL(TO_CHAR(ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO),'')        || '|' ||
                    NVL(ENV_L23_PR_CLMT_RSK_ID_ASES_MNG_STATUS_FL,'')         || '|' ||
                    NVL(ENV_L23_PR_CLMT_RSK_ID_ASES_STATUS_FL,'')             || '|' ||
                    NVL(ENV_L23_PR_CLMT_RSK_MNG_PROC_DISC_STATUS_FL,'')       || '|' ||
                    NVL(ENV_L23_PR_SCNRO_ANLYS_TYPE_TX,''),
               'SHA256'));

    END chk_post_load;


    -- =========================================================================
    -- MAIN: run
    -- Orchestrates all checks in sequence.
    -- Commits after each phase so partial results are visible to monitoring.
    -- On exception: updates lineage step to FAILED with error message.
    -- =========================================================================
    PROCEDURE run (
        p_fscl_yr_no        IN NUMBER,
        p_src_sys_nm        IN VARCHAR2,
        p_lineage_id        IN VARCHAR2,
        p_process_run_id    IN VARCHAR2
    ) AS
        v_proc  VARCHAR2(100) := c_pkg || '.run';
    BEGIN
        -- Mark DI_CHECK step as RUNNING
        UPDATE udm_lineage
        SET    step_status = 'RUNNING',
               started_at  = SYSDATE
        WHERE  lineage_id  = p_lineage_id;
        COMMIT;

        -- Phase 1: Pre-load checks on source table
        chk_pre_load(p_fscl_yr_no, p_src_sys_nm, p_lineage_id);
        COMMIT;

        -- Phase 2: Post-load checks on target table
        chk_post_load(p_fscl_yr_no, p_src_sys_nm, p_lineage_id);
        COMMIT;

        -- Update DI_CHECK step to COMPLETE with summary counts
        UPDATE udm_lineage
        SET    step_status   = 'COMPLETE',
               completed_at  = SYSDATE,
               rows_read      = (
                   SELECT COUNT(*)
                   FROM   udm_dq_results
                   WHERE  lineage_id = p_lineage_id
               ),
               rows_rejected  = (
                   SELECT COUNT(*)
                   FROM   udm_dq_results
                   WHERE  lineage_id   = p_lineage_id
                   AND    check_result IN ('FAIL','WARNING')
               )
        WHERE  lineage_id = p_lineage_id;
        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            UPDATE udm_lineage
            SET    step_status    = 'FAILED',
                   completed_at   = SYSDATE,
                   error_message  = SUBSTR(v_proc || ': ' || SQLERRM, 1, 2000)
            WHERE  lineage_id = p_lineage_id;
            COMMIT;
            RAISE;
    END run;

END udm_di_phys_clmt_rsk;
/


-- =============================================================================
-- CONSUMER QUERIES — Reading DI Results
-- =============================================================================

-- All failures and warnings for a specific load run:
/*
SELECT
    dq.data_itm_nm          AS data_item,
    dq.check_type,
    dq.movement_point,
    dq.check_result,
    dq.actual_value,
    dq.expected_value,
    dq.entity_key,
    dq.coverage_period,
    dq.action_taken,
    dq.check_source,
    l.step_sequence,
    pr.process_run_id
FROM   udm_dq_results   dq
JOIN   udm_lineage       l  ON l.lineage_id    = dq.lineage_id
JOIN   udm_process_run   pr ON pr.process_run_id = l.process_run_id
WHERE  pr.vendor_id        = 'VENDOR_A'
AND    dq.coverage_period   = '2024'
AND    dq.check_result     IN ('FAIL','WARNING')
ORDER BY dq.movement_point, dq.check_type, dq.entity_key;
*/

-- Summary dashboard — pass/fail counts per check per load:
/*
SELECT
    dq.data_itm_nm,
    dq.check_type,
    dq.movement_point,
    SUM(CASE WHEN dq.check_result = 'PASS'    THEN 1 ELSE 0 END) AS pass_count,
    SUM(CASE WHEN dq.check_result = 'FAIL'    THEN 1 ELSE 0 END) AS fail_count,
    SUM(CASE WHEN dq.check_result = 'WARNING' THEN 1 ELSE 0 END) AS warn_count
FROM   udm_dq_results   dq
JOIN   udm_lineage       l  ON l.lineage_id = dq.lineage_id
WHERE  l.process_run_id  = 'RUN-20240315-00001'
GROUP BY dq.data_itm_nm, dq.check_type, dq.movement_point
ORDER BY fail_count DESC, warn_count DESC;
*/

-- Trend: exposure score drift over last 3 years:
/*
SELECT
    dq.coverage_period,
    dq.actual_value     AS avg_score_this_yr,
    dq.expected_value   AS avg_score_prior_yr,
    dq.check_result
FROM   udm_dq_results   dq
JOIN   udm_lineage       l  ON l.lineage_id = dq.lineage_id
WHERE  dq.data_itm_nm   = 'ENV_L23_PR_CLMT_RSK_EXPSR_SCR_NO'
AND    dq.check_type    = 'DRIFT'
AND    l.domain_id      = 'PHYSICAL_CLIMATE_RISK'
ORDER BY dq.coverage_period DESC
FETCH FIRST 3 ROWS ONLY;
*/


-- =============================================================================
-- END — UDM DI FRAMEWORK — UDM_PHYS_CLMT_RSK_FCT v1.0
-- ─────────────────────────────────────────────────────────────────────────────
-- CHECK SUMMARY
--   PRE-LOAD  (STAGE_TO_VS):
--     CHK-01  Volume baseline              — source row count logged
--     CHK-02  Source duplicate natural key — VENDOR_ENTITY_KY + FiscalYear
--     CHK-03  Entity resolution coverage  — vendor IDs with no xref
--
--   POST-LOAD (VS_TO_ARB):
--     CHK-04  Volume: target vs source     — row count comparison
--     CHK-05  Volume drift vs prior year   — ±20% threshold (DQR-PHYS-003)
--     CHK-06  Bounds: exposure score 0–100 — DQR-PHYS-001
--     CHK-07  Drift: score avg vs prior yr — ±25% threshold (DQR-PHYS-002)
--     CHK-08  Domain value: status flags   — UNPIVOT across 3 flag columns
--     CHK-09  Domain value: scenario type  — valid classification values
--     CHK-10  Consistency: assessment chain — status → management status
--     CHK-11  Consistency: disclosure → scenario analysis expected
--     CHK-12  Completeness: score coverage — ≥60% entities (DQR-PHYS-004)
--     CHK-13  Dupe: natural key in target  — post-load uniqueness
--     CHK-14  Checksum: ROW_CHK_SUM_TX    — SHA256 recomputation
--
--   AUTO-DERIVED (handled by harmonisation engine — not in this package):
--     NULL check    — from udm_data_item.is_mndty_fl
--     Data type     — from udm_data_item.data_typ_cd
-- =============================================================================
