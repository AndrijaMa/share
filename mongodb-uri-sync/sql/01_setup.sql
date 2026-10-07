-- 01_setup.sql — one-time setup for mongodb-uri-sync.
-- Run as ACCOUNTADMIN (or a role that can create users/roles and grant on the objects below).
-- Search/replace these placeholders before running:
--   <WAREHOUSE>               warehouse used for the SELECT
--   <DB>, <SCHEMA>            location of MONGODB_CLUSTER_NODES
--   <OPENFLOW_RUNTIME_ROLE>   role that administers the Openflow runtime (e.g. OPENFLOW_ADMIN)
--   <RUNNER_IP>               public IP of the host running the script

USE ROLE ACCOUNTADMIN;

-- 1. Role and service user (no password; authenticates with a PAT only)
CREATE ROLE IF NOT EXISTS OPENFLOW_URI_SYNC_ROLE;
CREATE USER IF NOT EXISTS SVC_OPENFLOW_URI_SYNC
  TYPE = SERVICE
  DEFAULT_ROLE = OPENFLOW_URI_SYNC_ROLE
  DEFAULT_WAREHOUSE = <WAREHOUSE>
  COMMENT = 'mongodb-uri-sync: copies MongoDB URI into Openflow connector parameter';
GRANT ROLE OPENFLOW_URI_SYNC_ROLE TO USER SVC_OPENFLOW_URI_SYNC;

-- 2. Source table (skip if it already exists and is populated by your discovery process)
CREATE SCHEMA IF NOT EXISTS <DB>.<SCHEMA>;
CREATE TABLE IF NOT EXISTS <DB>.<SCHEMA>.MONGODB_CLUSTER_NODES (
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
GRANT USAGE  ON WAREHOUSE <WAREHOUSE>                         TO ROLE OPENFLOW_URI_SYNC_ROLE;
GRANT USAGE  ON DATABASE  <DB>                                TO ROLE OPENFLOW_URI_SYNC_ROLE;
GRANT USAGE  ON SCHEMA    <DB>.<SCHEMA>                       TO ROLE OPENFLOW_URI_SYNC_ROLE;
GRANT SELECT ON TABLE     <DB>.<SCHEMA>.MONGODB_CLUSTER_NODES TO ROLE OPENFLOW_URI_SYNC_ROLE;

-- 4. Openflow runtime access.
-- Simplest: inherit the runtime admin role so SHOW/DESCRIBE OPENFLOW RUNTIME and the runtime
-- NiFi API accept the PAT. Tighten to object-level grants if your security policy requires it.
GRANT ROLE <OPENFLOW_RUNTIME_ROLE> TO ROLE OPENFLOW_URI_SYNC_ROLE;

-- 5. Network policy for the service user (PATs on service users require one by default).
CREATE NETWORK RULE IF NOT EXISTS <DB>.<SCHEMA>.URI_SYNC_RUNNER_IPS
  MODE = INGRESS TYPE = IPV4 VALUE_LIST = ('<RUNNER_IP>/32');
CREATE NETWORK POLICY IF NOT EXISTS URI_SYNC_POLICY
  ALLOWED_NETWORK_RULE_LIST = ('<DB>.<SCHEMA>.URI_SYNC_RUNNER_IPS');
ALTER USER SVC_OPENFLOW_URI_SYNC SET NETWORK_POLICY = URI_SYNC_POLICY;
