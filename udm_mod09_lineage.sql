-- ============================================================================
-- MODULE 9 — LINEAGE RECORDER
-- Package  : UDM.UDM_PKG_LINEAGE
-- Purpose  : Shared batch-level audit trail called by Modules 6, 7 and 8.
--            Quarantine writes use AUTONOMOUS_TRANSACTION so row rejections
--            are committed independently of the caller's main transaction.
-- Depends  : udm_lineage, udm_quarantine, udm_lineage_seq, udm_quarantine_seq
-- Compile  : First — no other UDM package dependencies.
-- ============================================================================

-- ============================================================================
-- PACKAGE SPEC
-- ============================================================================
CREATE OR REPLACE PACKAGE udm.udm_pkg_lineage AS

  -- -------------------------------------------------------------------------
  -- open_batch
  -- Inserts a RUNNING lineage row and returns the generated lineage_id.
  -- Call this at the start of every engine pass before touching data.
  -- -------------------------------------------------------------------------
  FUNCTION open_batch (
    p_lineage_type    IN VARCHAR2,   -- LOAD | ARBITRATION | DI_CHECK | MANIFEST
    p_source_id       IN VARCHAR2 DEFAULT NULL,
    p_domain_id       IN VARCHAR2 DEFAULT NULL,
    p_vendor_id       IN VARCHAR2 DEFAULT NULL,
    p_coverage_period IN VARCHAR2 DEFAULT NULL,
    p_manifest_id     IN VARCHAR2 DEFAULT NULL
  ) RETURN VARCHAR2;

  -- -------------------------------------------------------------------------
  -- close_batch
  -- Updates the lineage row with final status and row counts.
  -- Always call in both success and exception handlers.
  -- -------------------------------------------------------------------------
  PROCEDURE close_batch (
    p_lineage_id       IN VARCHAR2,
    p_status           IN VARCHAR2,   -- COMPLETE | FAILED | PARTIAL
    p_rows_read        IN NUMBER   DEFAULT NULL,
    p_rows_written     IN NUMBER   DEFAULT NULL,
    p_rows_rejected    IN NUMBER   DEFAULT NULL,
    p_rows_quarantined IN NUMBER   DEFAULT NULL,
    p_error_message    IN VARCHAR2 DEFAULT NULL
  );

  -- -------------------------------------------------------------------------
  -- quarantine_row
  -- Rejects a single data row to udm_quarantine.
  -- AUTONOMOUS_TRANSACTION: committed even if the caller rolls back.
  -- -------------------------------------------------------------------------
  PROCEDURE quarantine_row (
    p_lineage_id       IN VARCHAR2,
    p_source_id        IN VARCHAR2,
    p_domain_id        IN VARCHAR2,
    p_vendor_id        IN VARCHAR2,
    p_coverage_period  IN VARCHAR2,
    p_entity_id_raw    IN VARCHAR2,
    p_attribute_name   IN VARCHAR2,
    p_raw_value        IN VARCHAR2,
    p_check_type       IN VARCHAR2,
    p_rejection_reason IN VARCHAR2
  );

  -- -------------------------------------------------------------------------
  -- log_manifest_event
  -- Convenience wrapper for MANIFEST-type lineage events.
  -- -------------------------------------------------------------------------
  PROCEDURE log_manifest_event (
    p_manifest_id     IN VARCHAR2,
    p_source_id       IN VARCHAR2,
    p_vendor_id       IN VARCHAR2,
    p_coverage_period IN VARCHAR2,
    p_status          IN VARCHAR2 DEFAULT 'COMPLETE'
  );

END udm_pkg_lineage;
/


-- ============================================================================
-- PACKAGE BODY
-- ============================================================================
CREATE OR REPLACE PACKAGE BODY udm.udm_pkg_lineage AS

  -- --------------------------------------------------------------------------
  -- Private: generate a lineage_id in format LIN-YYYYMMDD-NNNNNNNN
  -- --------------------------------------------------------------------------
  FUNCTION gen_lineage_id RETURN VARCHAR2 IS
  BEGIN
    RETURN 'LIN-' || TO_CHAR(SYSDATE, 'YYYYMMDD') || '-'
           || LPAD(udm_lineage_seq.NEXTVAL, 8, '0');
  END;

  -- --------------------------------------------------------------------------
  FUNCTION open_batch (
    p_lineage_type    IN VARCHAR2,
    p_source_id       IN VARCHAR2 DEFAULT NULL,
    p_domain_id       IN VARCHAR2 DEFAULT NULL,
    p_vendor_id       IN VARCHAR2 DEFAULT NULL,
    p_coverage_period IN VARCHAR2 DEFAULT NULL,
    p_manifest_id     IN VARCHAR2 DEFAULT NULL
  ) RETURN VARCHAR2
  IS
    l_lineage_id VARCHAR2(30) := gen_lineage_id;
  BEGIN
    INSERT INTO udm_lineage (
      lineage_id, lineage_type, source_id, domain_id,
      vendor_id, coverage_period, manifest_id,
      rows_read, rows_written, rows_rejected, rows_quarantined,
      started_at, completed_at, status, created_date
    ) VALUES (
      l_lineage_id, p_lineage_type, p_source_id, p_domain_id,
      p_vendor_id, p_coverage_period, p_manifest_id,
      0, 0, 0, 0,
      SYSDATE, NULL, 'RUNNING', SYSDATE
    );
    COMMIT;
    RETURN l_lineage_id;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE_APPLICATION_ERROR(-20100,
        'udm_pkg_lineage.open_batch failed for type=' || p_lineage_type
        || ' source=' || p_source_id || ': ' || SQLERRM);
  END open_batch;

  -- --------------------------------------------------------------------------
  PROCEDURE close_batch (
    p_lineage_id       IN VARCHAR2,
    p_status           IN VARCHAR2,
    p_rows_read        IN NUMBER   DEFAULT NULL,
    p_rows_written     IN NUMBER   DEFAULT NULL,
    p_rows_rejected    IN NUMBER   DEFAULT NULL,
    p_rows_quarantined IN NUMBER   DEFAULT NULL,
    p_error_message    IN VARCHAR2 DEFAULT NULL
  ) IS
  BEGIN
    UPDATE udm_lineage
    SET    status            = p_status,
           completed_at      = SYSDATE,
           rows_read         = NVL(p_rows_read,        rows_read),
           rows_written      = NVL(p_rows_written,     rows_written),
           rows_rejected     = NVL(p_rows_rejected,    rows_rejected),
           rows_quarantined  = NVL(p_rows_quarantined, rows_quarantined),
           error_message     = SUBSTR(p_error_message, 1, 2000)
    WHERE  lineage_id = p_lineage_id;
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      -- Never raise from close — log to DBMS_OUTPUT as last resort
      DBMS_OUTPUT.PUT_LINE('WARNING: close_batch failed for '
        || p_lineage_id || ': ' || SQLERRM);
  END close_batch;

  -- --------------------------------------------------------------------------
  PROCEDURE quarantine_row (
    p_lineage_id       IN VARCHAR2,
    p_source_id        IN VARCHAR2,
    p_domain_id        IN VARCHAR2,
    p_vendor_id        IN VARCHAR2,
    p_coverage_period  IN VARCHAR2,
    p_entity_id_raw    IN VARCHAR2,
    p_attribute_name   IN VARCHAR2,
    p_raw_value        IN VARCHAR2,
    p_check_type       IN VARCHAR2,
    p_rejection_reason IN VARCHAR2
  ) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_q_id VARCHAR2(30);
  BEGIN
    l_q_id := 'QUA-' || TO_CHAR(SYSDATE, 'YYYYMMDD') || '-'
              || LPAD(udm_quarantine_seq.NEXTVAL, 8, '0');

    INSERT INTO udm_quarantine (
      quarantine_id, lineage_id, source_id, domain_id, vendor_id,
      coverage_period, entity_id_raw, attribute_name,
      raw_value, check_type, rejection_reason,
      quarantined_at, resolved_flag
    ) VALUES (
      l_q_id, p_lineage_id, p_source_id, p_domain_id, p_vendor_id,
      p_coverage_period,
      SUBSTR(p_entity_id_raw,    1, 200),
      SUBSTR(p_attribute_name,   1, 128),
      SUBSTR(p_raw_value,        1, 2000),
      p_check_type,
      SUBSTR(p_rejection_reason, 1, 500),
      SYSDATE, 'N'
    );
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      DBMS_OUTPUT.PUT_LINE('WARNING: quarantine_row failed: ' || SQLERRM);
  END quarantine_row;

  -- --------------------------------------------------------------------------
  PROCEDURE log_manifest_event (
    p_manifest_id     IN VARCHAR2,
    p_source_id       IN VARCHAR2,
    p_vendor_id       IN VARCHAR2,
    p_coverage_period IN VARCHAR2,
    p_status          IN VARCHAR2 DEFAULT 'COMPLETE'
  ) IS
    l_lineage_id VARCHAR2(30);
  BEGIN
    l_lineage_id := open_batch(
      p_lineage_type    => 'MANIFEST',
      p_source_id       => p_source_id,
      p_vendor_id       => p_vendor_id,
      p_coverage_period => p_coverage_period,
      p_manifest_id     => p_manifest_id
    );
    close_batch(
      p_lineage_id  => l_lineage_id,
      p_status      => p_status
    );
  END log_manifest_event;

END udm_pkg_lineage;
/
