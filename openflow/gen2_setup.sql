/* =============================================================================
   Openflow gen 2 – end-to-end setup on an EMPTY Snowflake account
   Deployment type : Snowflake deployment (Snowflake-managed compute)
   Admin user      : OPENFLOW_ADMIN
   Admin role      : OPENFLOW_ADMIN   (owns deployment, runtime, infra objects)

   PRE-REQUISITE (one-time, manual, cannot be scripted):
     An ORGADMIN must accept the Openflow terms in Snowsight:
       Admin > Billing & Terms > Snowflake Feature Terms > Openflow
     Check: SHOW OPENFLOW DEPLOYMENTS;  -> must run without error.

   Run top-to-bottom as a user that has ACCOUNTADMIN.
   Edit the values marked  <<< CHANGE  before running.
   Object names are literals (Openflow DDL does not accept IDENTIFIER($var)),
   so if you rename something, search/replace it across the whole file.
   ============================================================================= */

-- -----------------------------------------------------------------------------
-- 0. Sanity check – terms accepted & gen 2 SQL API available
-- -----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
SHOW OPENFLOW DEPLOYMENTS;               -- error here = terms not accepted
SHOW OPENFLOW CONNECTOR DEFINITIONS;     -- syntax error here = gen 2 not enabled

-- -----------------------------------------------------------------------------
-- 1. Admin role + account-level privileges
-- -----------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS OPENFLOW_ADMIN
  COMMENT = 'Openflow admin role - owns deployments, runtimes and infrastructure. [openflow]';

GRANT CREATE DATABASE                      ON ACCOUNT TO ROLE OPENFLOW_ADMIN;
GRANT CREATE ROLE                          ON ACCOUNT TO ROLE OPENFLOW_ADMIN;
GRANT CREATE WAREHOUSE                     ON ACCOUNT TO ROLE OPENFLOW_ADMIN;
GRANT CREATE COMPUTE POOL                  ON ACCOUNT TO ROLE OPENFLOW_ADMIN;
GRANT CREATE OPENFLOW DEPLOYMENT           ON ACCOUNT TO ROLE OPENFLOW_ADMIN;
GRANT CREATE EXTERNAL ACCESS INTEGRATION   ON ACCOUNT TO ROLE OPENFLOW_ADMIN;
GRANT CREATE INTEGRATION                   ON ACCOUNT TO ROLE OPENFLOW_ADMIN;
GRANT BIND SERVICE ENDPOINT                ON ACCOUNT TO ROLE OPENFLOW_ADMIN;

-- keep the role hierarchy clean
GRANT ROLE OPENFLOW_ADMIN TO ROLE SYSADMIN;

-- -----------------------------------------------------------------------------
-- 2. Admin user
--    Password login works for Snowsight; key-pair is recommended for CLI/automation.
-- -----------------------------------------------------------------------------
CREATE USER IF NOT EXISTS OPENFLOW_ADMIN
  PASSWORD             = 'ChangeMe_Openflow#2026'   -- <<< CHANGE
  MUST_CHANGE_PASSWORD = TRUE
  DEFAULT_ROLE         = OPENFLOW_ADMIN
  DEFAULT_WAREHOUSE    = OPENFLOW_WH
  EMAIL                = 'openflow-admin@example.com' -- <<< CHANGE
  COMMENT              = 'Openflow administrator. [openflow]';
-- Optional key-pair auth:
-- ALTER USER OPENFLOW_ADMIN SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqh...';

GRANT ROLE OPENFLOW_ADMIN TO USER OPENFLOW_ADMIN;
-- Also give it to the person running this script (optional)
-- GRANT ROLE OPENFLOW_ADMIN TO USER <YOUR_USER>;

-- -----------------------------------------------------------------------------
-- 3. Switch to the admin role – everything below is owned by OPENFLOW_ADMIN
-- -----------------------------------------------------------------------------
USE ROLE OPENFLOW_ADMIN;

-- Warehouse used by connectors for ingestion / merges
CREATE WAREHOUSE IF NOT EXISTS OPENFLOW_WH
  WAREHOUSE_SIZE = XSMALL
  AUTO_SUSPEND   = 60
  AUTO_RESUME    = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Openflow ingestion warehouse. [openflow]';

-- Infrastructure database/schema (runtimes, secrets, network rules, event table)
CREATE DATABASE IF NOT EXISTS OPENFLOW COMMENT = 'Openflow infrastructure database. [openflow]';
CREATE SCHEMA   IF NOT EXISTS OPENFLOW.OPENFLOW COMMENT = 'Openflow infrastructure schema. [openflow]';



-- -----------------------------------------------------------------------------
-- 4. Openflow deployment (account-level object, no USE DATABASE needed)
--    Provisioning takes ~5-10 min.
-- -----------------------------------------------------------------------------
CREATE OPENFLOW DEPLOYMENT IF NOT EXISTS OPENFLOW_DEPLOYMENT
  COMMENT = 'Openflow gen 2 Snowflake deployment. [openflow]';

-- Blocks until stable; raises on timeout/failure. On timeout just re-run this
-- line – do NOT re-issue CREATE OPENFLOW DEPLOYMENT.
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_DEPLOYMENTS(600, 'OPENFLOW_DEPLOYMENT');

ALTER OPENFLOW DEPLOYMENT OPENFLOW_DEPLOYMENT SET DISPLAY_NAME = 'Openflow Deployment';
SHOW OPENFLOW DEPLOYMENTS;

-- -----------------------------------------------------------------------------
-- 5. Event table for runtime logs/metrics (recommended)
-- -----------------------------------------------------------------------------
CREATE EVENT TABLE IF NOT EXISTS OPENFLOW.OPENFLOW.EVENTS
  COMMENT = 'Openflow runtime logs and metrics. [openflow]';
ALTER OPENFLOW DEPLOYMENT 73STRINGS  SET EVENT_TABLE = 'OPENFLOW.OPENFLOW.OPENFLOW_EVENTS';

USE ROLE OPENFLOW_ADMIN;

-- -----------------------------------------------------------------------------
-- 6. Execute-as role (the role connectors use to read/write Snowflake data)
--    You asked for OPENFLOW_ADMIN to run Openflow – it owns the runtime.
--    Best practice is a separate, least-privilege execute-as role, granted to
--    OPENFLOW_ADMIN. To use OPENFLOW_ADMIN itself instead, set
--    EXECUTE_AS_ROLE = OPENFLOW_ADMIN in step 8 and skip this section.
-- -----------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS OPENFLOW_RUNTIME_EXECUTE_AS_RL
  COMMENT = 'Execute-as role for Openflow runtime OPENFLOW_RUNTIME. [openflow]';
GRANT ROLE OPENFLOW_RUNTIME_EXECUTE_AS_RL TO ROLE OPENFLOW_ADMIN;

GRANT USAGE, OPERATE ON WAREHOUSE OPENFLOW_WH         TO ROLE OPENFLOW_RUNTIME_EXECUTE_AS_RL;
GRANT USAGE ON DATABASE OPENFLOW                     TO ROLE OPENFLOW_RUNTIME_EXECUTE_AS_RL;
GRANT USAGE ON SCHEMA   OPENFLOW.OPENFLOW            TO ROLE OPENFLOW_RUNTIME_EXECUTE_AS_RL;
GRANT USAGE ON DATABASE OPENFLOW_DATA                TO ROLE OPENFLOW_RUNTIME_EXECUTE_AS_RL;
GRANT USAGE, CREATE TABLE, CREATE SCHEMA ON DATABASE OPENFLOW_DATA TO ROLE OPENFLOW_RUNTIME_EXECUTE_AS_RL;


-- -----------------------------------------------------------------------------
-- 7. Network egress (EAI) – lets the runtime reach external sources.
--    Replace the host list with your sources. Never CREATE OR REPLACE these:
--    replacing silently detaches them from runtimes.
-- -----------------------------------------------------------------------------
CREATE NETWORK RULE IF NOT EXISTS OPENFLOW.OPENFLOW.OPENFLOW_RUNTIME_NETWORK_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('mydb.example.com:5432')   -- <<< CHANGE
  COMMENT = 'Egress for Openflow runtime OPENFLOW_RUNTIME. [openflow]';

CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS OPENFLOW_RUNTIME_EAI
  ALLOWED_NETWORK_RULES = (OPENFLOW.OPENFLOW.OPENFLOW_RUNTIME_NETWORK_RULE)
  ENABLED = TRUE
  COMMENT = 'EAI for Openflow runtime OPENFLOW_RUNTIME. [openflow]';

GRANT USAGE ON INTEGRATION OPENFLOW_RUNTIME_EAI TO ROLE OPENFLOW_RUNTIME_EXECUTE_AS_RL;

-- -----------------------------------------------------------------------------
-- 8. Openflow runtime
--    NODE_TYPE: SMALL | MEDIUM | LARGE  (cannot be changed later)
--    NODE_TYPE_TIER: S1/S2/S3 (SMALL), M4/M6 (MEDIUM), L8 (LARGE) – changeable later
-- -----------------------------------------------------------------------------
USE SCHEMA OPENFLOW.OPENFLOW;

CREATE OPENFLOW RUNTIME IF NOT EXISTS OPENFLOW.OPENFLOW.OPENFLOW_RUNTIME
  IN DEPLOYMENT OPENFLOW_DEPLOYMENT
  NODE_TYPE      = SMALL          -- <<< CHANGE if needed
  NODE_TYPE_TIER = 'S1'
  MIN_NODES      = 1
  MAX_NODES      = 1
  EXECUTE_AS_ROLE = OPENFLOW_RUNTIME_EXECUTE_AS_RL
  EXTERNAL_ACCESS_INTEGRATIONS = (OPENFLOW_RUNTIME_EAI)
  DISPLAY_NAME   = 'OPENFLOW_RUNTIME'
  COMMENT        = 'Openflow gen 2 runtime. [openflow]';

-- ~3-5 min
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_RUNTIMES(600, 'OPENFLOW.OPENFLOW.OPENFLOW_RUNTIME');

-- -----------------------------------------------------------------------------
-- 9. Verify
-- -----------------------------------------------------------------------------
SHOW OPENFLOW DEPLOYMENTS;
SHOW OPENFLOW RUNTIMES IN ACCOUNT;                       -- status = ACTIVE
DESCRIBE OPENFLOW RUNTIME OPENFLOW.OPENFLOW.OPENFLOW_RUNTIME;  -- server_url populated
SHOW OPENFLOW CONNECTOR DEFINITIONS;                     -- gen 2 connectors you can deploy
