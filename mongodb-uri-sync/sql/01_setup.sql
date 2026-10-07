-- 01_setup.sql — one-time setup for mongodb-uri-sync.
-- Run in a Snowsight worksheet ("Run All").
-- Role: ACCOUNTADMIN (or a role that can create users/roles/network policies and grant on the objects below).
--
-- >>> Edit the values in this block, then run the whole file. <<<
-- Values must not contain single quotes.
SET db           = 'ADMIN';                     -- database for the table/procedures
SET schema       = 'MONGODB';                   -- schema for the table/procedures
SET warehouse    = 'COMPUTE_WH';                -- warehouse used by the script's SELECT
SET sync_role    = 'OPENFLOW_URI_SYNC_ROLE';    -- role the Python script authenticates as
SET sync_user    = 'SVC_OPENFLOW_URI_SYNC';     -- service user that owns the PAT
SET runtime_role = 'OPENFLOW_ADMIN';            -- role that administers the Openflow runtime
SET runner_ip    = '203.0.113.10';              -- public IP of the host running the script
-- <<< end of parameters >>>

SET schema_fqn = $db || '.' || $schema;

USE ROLE ACCOUNTADMIN;

-- 1. Role and service user (no password; authenticates with a PAT only)
CREATE ROLE IF NOT EXISTS IDENTIFIER($sync_role);
SET stmt = 'CREATE USER IF NOT EXISTS ' || $sync_user ||
           ' TYPE = SERVICE DEFAULT_ROLE = ' || $sync_role || ' DEFAULT_WAREHOUSE = ' || $warehouse ||
           ' COMMENT = ''mongodb-uri-sync service user''';
EXECUTE IMMEDIATE $stmt;
GRANT ROLE IDENTIFIER($sync_role) TO USER IDENTIFIER($sync_user);

-- 2. Source table (filled by the procedures in 03_mongodb_discovery.sql)
CREATE DATABASE IF NOT EXISTS IDENTIFIER($db);
CREATE SCHEMA IF NOT EXISTS IDENTIFIER($schema_fqn);
USE SCHEMA IDENTIFIER($schema_fqn);
CREATE TABLE IF NOT EXISTS MONGODB_CLUSTER_NODES (
  REPLICA_SET       VARCHAR,
  HOST              VARCHAR,
  PORT              NUMBER,
  CONNECTION_STRING VARCHAR,
  PRIORITY          NUMBER,
  WEIGHT            NUMBER,
  TTL               NUMBER,
  TXT_OPTIONS       VARCHAR,
  RESOLVED_AT       TIMESTAMP_LTZ
);

-- 3. Read access to the table
GRANT USAGE  ON WAREHOUSE IDENTIFIER($warehouse)  TO ROLE IDENTIFIER($sync_role);
GRANT USAGE  ON DATABASE  IDENTIFIER($db)         TO ROLE IDENTIFIER($sync_role);
GRANT USAGE  ON SCHEMA    IDENTIFIER($schema_fqn) TO ROLE IDENTIFIER($sync_role);
SET table_fqn = $schema_fqn || '.MONGODB_CLUSTER_NODES';
GRANT SELECT ON TABLE IDENTIFIER($table_fqn) TO ROLE IDENTIFIER($sync_role);

-- 4. Openflow runtime access.
-- Simplest: inherit the runtime admin role so SHOW/DESCRIBE OPENFLOW RUNTIME and the runtime
-- NiFi API accept the PAT. Tighten to object-level grants if your security policy requires it.
GRANT ROLE IDENTIFIER($runtime_role) TO ROLE IDENTIFIER($sync_role);

-- 5. Network policy for the service user (PATs on service users require one by default).
SET stmt = 'CREATE NETWORK RULE IF NOT EXISTS URI_SYNC_RUNNER_IPS MODE = INGRESS TYPE = IPV4 VALUE_LIST = (''' ||
           $runner_ip || '/32'')';
EXECUTE IMMEDIATE $stmt;
SET stmt = 'CREATE NETWORK POLICY IF NOT EXISTS ' || $sync_user || '_POLICY ALLOWED_NETWORK_RULE_LIST = (''' ||
           $schema_fqn || '.URI_SYNC_RUNNER_IPS'')';
EXECUTE IMMEDIATE $stmt;
SET stmt = 'ALTER USER ' || $sync_user || ' SET NETWORK_POLICY = ' || $sync_user || '_POLICY';
EXECUTE IMMEDIATE $stmt;
