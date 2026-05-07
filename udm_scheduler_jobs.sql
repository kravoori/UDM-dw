-- ============================================================================
-- UDM ENGINE — ORACLE SCHEDULER JOB DEFINITIONS
-- File    : udm_scheduler_jobs.sql
-- Purpose : Defines the Oracle Scheduler jobs that trigger the engine
--           pipeline in the correct sequence:
--
--   JOB 1  udm_job_manifest_watcher   — polls for COMPLETE manifests
--   JOB 2  udm_job_harmonise_source   — runs harmonisation for one source
--   JOB 3  udm_job_arbitrate_domain   — runs arbitration after all sources load
--   JOB 4  udm_job_di_domain          — runs DI checks after harmonisation
--
-- Trigger chain (event-based):
--   manifest COMPLETE → JOB2 (per source) → JOB4 (DI) → JOB3 (arbitration)
--
-- Schedule: Jobs run via Oracle Scheduler chains or can be triggered
--           externally (ETL tool, Airflow) via DBMS_SCHEDULER.RUN_JOB.
-- ============================================================================


-- ============================================================================
-- SECTION 1 — PROGRAMS
-- Parameterised executable units. Jobs reference these programs.
-- ============================================================================

BEGIN
  -- Program: run harmonisation for one source + period
  DBMS_SCHEDULER.CREATE_PROGRAM(
    program_name   => 'UDM.UDM_PRG_HARMONISE_SOURCE',
    program_type   => 'STORED_PROCEDURE',
    program_action => 'UDM.UDM_PKG_HARMONISATION.RUN_SOURCE',
    number_of_arguments => 2,
    enabled        => FALSE,
    comments       => 'Runs harmonisation engine for a single source and coverage period'
  );

  DBMS_SCHEDULER.DEFINE_PROGRAM_ARGUMENT(
    program_name      => 'UDM.UDM_PRG_HARMONISE_SOURCE',
    argument_position => 1,
    argument_name     => 'p_source_id',
    argument_type     => 'VARCHAR2',
    default_value     => NULL
  );

  DBMS_SCHEDULER.DEFINE_PROGRAM_ARGUMENT(
    program_name      => 'UDM.UDM_PRG_HARMONISE_SOURCE',
    argument_position => 2,
    argument_name     => 'p_coverage_period',
    argument_type     => 'VARCHAR2',
    default_value     => NULL
  );

  DBMS_SCHEDULER.ENABLE('UDM.UDM_PRG_HARMONISE_SOURCE');
END;
/

BEGIN
  -- Program: run harmonisation for all sources in a domain
  DBMS_SCHEDULER.CREATE_PROGRAM(
    program_name   => 'UDM.UDM_PRG_HARMONISE_DOMAIN',
    program_type   => 'STORED_PROCEDURE',
    program_action => 'UDM.UDM_PKG_HARMONISATION.RUN_DOMAIN',
    number_of_arguments => 2,
    enabled        => FALSE,
    comments       => 'Runs harmonisation engine for all sources in a domain'
  );

  DBMS_SCHEDULER.DEFINE_PROGRAM_ARGUMENT(
    program_name      => 'UDM.UDM_PRG_HARMONISE_DOMAIN',
    argument_position => 1,
    argument_name     => 'p_domain_id',
    argument_type     => 'VARCHAR2',
    default_value     => NULL
  );

  DBMS_SCHEDULER.DEFINE_PROGRAM_ARGUMENT(
    program_name      => 'UDM.UDM_PRG_HARMONISE_DOMAIN',
    argument_position => 2,
    argument_name     => 'p_coverage_period',
    argument_type     => 'VARCHAR2',
    default_value     => NULL
  );

  DBMS_SCHEDULER.ENABLE('UDM.UDM_PRG_HARMONISE_DOMAIN');
END;
/

BEGIN
  -- Program: run arbitration for a domain
  DBMS_SCHEDULER.CREATE_PROGRAM(
    program_name   => 'UDM.UDM_PRG_ARBITRATE_DOMAIN',
    program_type   => 'STORED_PROCEDURE',
    program_action => 'UDM.UDM_PKG_ARBITRATION.RUN_DOMAIN',
    number_of_arguments => 2,
    enabled        => FALSE,
    comments       => 'Runs arbitration engine for a domain and coverage period'
  );

  DBMS_SCHEDULER.DEFINE_PROGRAM_ARGUMENT(
    program_name      => 'UDM.UDM_PRG_ARBITRATE_DOMAIN',
    argument_position => 1,
    argument_name     => 'p_domain_id',
    argument_type     => 'VARCHAR2',
    default_value     => NULL
  );

  DBMS_SCHEDULER.DEFINE_PROGRAM_ARGUMENT(
    program_name      => 'UDM.UDM_PRG_ARBITRATE_DOMAIN',
    argument_position => 2,
    argument_name     => 'p_coverage_period',
    argument_type     => 'VARCHAR2',
    default_value     => NULL
  );

  DBMS_SCHEDULER.ENABLE('UDM.UDM_PRG_ARBITRATE_DOMAIN');
END;
/

BEGIN
  -- Program: run DI checks for a domain
  DBMS_SCHEDULER.CREATE_PROGRAM(
    program_name   => 'UDM.UDM_PRG_DI_DOMAIN',
    program_type   => 'STORED_PROCEDURE',
    program_action => 'UDM.UDM_PKG_DI.RUN_DOMAIN_CHECKS',
    number_of_arguments => 2,
    enabled        => FALSE,
    comments       => 'Runs DI framework checks for all sources in a domain'
  );

  DBMS_SCHEDULER.DEFINE_PROGRAM_ARGUMENT(
    program_name      => 'UDM.UDM_PRG_DI_DOMAIN',
    argument_position => 1,
    argument_name     => 'p_domain_id',
    argument_type     => 'VARCHAR2',
    default_value     => NULL
  );

  DBMS_SCHEDULER.DEFINE_PROGRAM_ARGUMENT(
    program_name      => 'UDM.UDM_PRG_DI_DOMAIN',
    argument_position => 2,
    argument_name     => 'p_coverage_period',
    argument_type     => 'VARCHAR2',
    default_value     => NULL
  );

  DBMS_SCHEDULER.ENABLE('UDM.UDM_PRG_DI_DOMAIN');
END;
/


-- ============================================================================
-- SECTION 2 — STANDING JOBS
-- These run on a schedule and are the entry points for the pipeline.
-- ============================================================================

BEGIN
  -- JOB: Manifest watcher — checks for newly COMPLETE manifests every 15 min
  -- When manifest becomes COMPLETE, this job fires run_domain for the domain.
  -- In production, replace with event-driven trigger from the file landing zone.
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'UDM.UDM_JOB_MANIFEST_WATCHER',
    job_type        => 'PLSQL_BLOCK',
    job_action      => q'[
DECLARE
  CURSOR c_ready IS
    SELECT DISTINCT sr.domain_id, dm.coverage_period
    FROM   udm_delivery_manifest dm
    JOIN   udm_source_registry   sr  ON sr.source_id = dm.source_id
    WHERE  dm.status             = 'COMPLETE'
    AND    sr.governance_status IN ('UDM_CATALOGED', 'MIGRATING')
    -- Only pick up manifests completed in the last 20 minutes (watcher interval + buffer)
    AND    dm.completed_at      >= SYSDATE - (20/1440)
    -- Exclude domains already processed in current lineage batch
    AND NOT EXISTS (
      SELECT 1 FROM udm_lineage l
      WHERE  l.domain_id       = sr.domain_id
      AND    l.coverage_period = dm.coverage_period
      AND    l.lineage_type    = 'LOAD'
      AND    l.status          IN ('RUNNING', 'COMPLETE')
      AND    l.started_at     >= dm.completed_at - (5/1440)
    );
BEGIN
  FOR d IN c_ready LOOP
    DBMS_SCHEDULER.CREATE_JOB(
      job_name        => 'UDM.UDM_JOB_RUN_' || REPLACE(d.domain_id,'-','_')
                         || '_' || TO_CHAR(SYSDATE,'YYYYMMDDHH24MISS'),
      program_name    => 'UDM.UDM_PRG_HARMONISE_DOMAIN',
      start_date      => SYSTIMESTAMP,
      enabled         => TRUE,
      auto_drop       => TRUE,
      comments        => 'Auto-triggered harmonisation: domain=' || d.domain_id
    );
    DBMS_SCHEDULER.SET_JOB_ARGUMENT_VALUE(
      'UDM.UDM_JOB_RUN_' || REPLACE(d.domain_id,'-','_')
      || '_' || TO_CHAR(SYSDATE,'YYYYMMDDHH24MISS'),
      1, d.domain_id);
    DBMS_SCHEDULER.SET_JOB_ARGUMENT_VALUE(
      'UDM.UDM_JOB_RUN_' || REPLACE(d.domain_id,'-','_')
      || '_' || TO_CHAR(SYSDATE,'YYYYMMDDHH24MISS'),
      2, d.coverage_period);
  END LOOP;
END;
]',
    repeat_interval => 'FREQ=MINUTELY;INTERVAL=15',
    start_date      => SYSTIMESTAMP,
    enabled         => FALSE,   -- enable manually after testing
    auto_drop       => FALSE,
    comments        => 'Polls for COMPLETE manifests and fires harmonisation jobs'
  );
END;
/

BEGIN
  -- JOB: Nightly arbitration sweep — catches any domains not triggered intraday
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'UDM.UDM_JOB_NIGHTLY_ARBITRATION',
    job_type        => 'PLSQL_BLOCK',
    job_action      => q'[
BEGIN
  -- Derive current coverage period (adjust format to domain convention)
  udm.udm_pkg_arbitration.run_all_domains(
    p_coverage_period => TO_CHAR(ADD_MONTHS(TRUNC(SYSDATE,'MM'),-1), 'YYYY-MM')
  );
END;
]',
    repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=0;BYSECOND=0',
    start_date      => SYSTIMESTAMP,
    enabled         => FALSE,
    auto_drop       => FALSE,
    comments        => 'Nightly arbitration sweep for prior month coverage period'
  );
END;
/

BEGIN
  -- JOB: Nightly DI check sweep
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'UDM.UDM_JOB_NIGHTLY_DI',
    job_type        => 'PLSQL_BLOCK',
    job_action      => q'[
DECLARE
  l_period VARCHAR2(20) :=
    TO_CHAR(ADD_MONTHS(TRUNC(SYSDATE,'MM'),-1), 'YYYY-MM');
  CURSOR c_domains IS
    SELECT DISTINCT domain_id
    FROM   udm_lineage
    WHERE  coverage_period = l_period
    AND    lineage_type    = 'LOAD'
    AND    status          = 'COMPLETE'
    AND    started_at     >= SYSDATE - 1;
BEGIN
  FOR d IN c_domains LOOP
    udm.udm_pkg_di.run_domain_checks(d.domain_id, l_period);
  END LOOP;
END;
]',
    repeat_interval => 'FREQ=DAILY;BYHOUR=3;BYMINUTE=0;BYSECOND=0',
    start_date      => SYSTIMESTAMP,
    enabled         => FALSE,
    auto_drop       => FALSE,
    comments        => 'Nightly DI check sweep — runs after nightly arbitration'
  );
END;
/


-- ============================================================================
-- SECTION 3 — MANUAL TRIGGER HELPERS
-- Use these scripts to manually trigger engine runs during testing or
-- for ad-hoc restatement. Do not run in production without change control.
-- ============================================================================

-- Trigger harmonisation for a specific source:
/*
BEGIN
  udm.udm_pkg_harmonisation.run_source(
    p_source_id       => 'SRC-001',
    p_coverage_period => '2024-Q1'
  );
END;
/
*/

-- Trigger full domain run (all sources, in correct role order):
/*
BEGIN
  udm.udm_pkg_harmonisation.run_domain(
    p_domain_id       => 'EMISSIONS',
    p_coverage_period => '2024-Q1'
  );
END;
/
*/

-- Trigger arbitration for a domain:
/*
BEGIN
  udm.udm_pkg_arbitration.run_domain(
    p_domain_id       => 'EMISSIONS',
    p_coverage_period => '2024-Q1'
  );
END;
/
*/

-- Trigger DI checks for a domain:
/*
BEGIN
  udm.udm_pkg_di.run_domain_checks(
    p_domain_id       => 'EMISSIONS',
    p_coverage_period => '2024-Q1'
  );
END;
/
*/

-- Monitor lineage:
/*
SELECT lineage_type, source_id, domain_id, coverage_period,
       status, rows_read, rows_written, rows_rejected, rows_quarantined,
       duration_secs, error_message
FROM   udm_lineage
WHERE  started_at >= SYSDATE - 1
ORDER  BY started_at DESC;
*/

-- Review quarantine:
/*
SELECT source_id, vendor_id, coverage_period, entity_id_raw,
       attribute_name, check_type, rejection_reason, quarantined_at
FROM   udm_quarantine
WHERE  resolved_flag = 'N'
ORDER  BY quarantined_at DESC;
*/

-- Review DQ results:
/*
SELECT check_type, attribute_name, check_status, actual_value,
       threshold_value, action_taken, details, checked_at
FROM   udm_dq_results
WHERE  coverage_period = '2024-Q1'
ORDER  BY check_status DESC, checked_at DESC;
*/
