-- 03_mongodb_discovery.sql — fills MONGODB_CLUSTER_NODES and keeps it current.
-- Run in a Snowsight worksheet ("Run All"), after 01_setup.sql.
-- Role: ACCOUNTADMIN (network rules, integrations and tasks need elevated privileges).
--
-- Hourly task HOURLY_MONGODB_SYNC runs three procedures in order:
--   1. LOAD_MONGODB_MEMBERS()              resolve the Atlas SRV/TXT records (DNS over HTTPS) and append a
--                                          new batch to MONGODB_CLUSTER_NODES, only if members changed
--   2. UPDATE_MONGODB_ATLAS_NETWORK_RULE() point the egress network rule MONGODB_ATLAS_RULE at the current
--                                          members, so the Openflow runtime can still reach the cluster
--   3. BUILD_MONGODB_CONNECTION_STRING()   build the mongodb:// URI and store it on the latest batch
-- mongodb_uri_to_openflow.py then copies that CONNECTION_STRING into the connector parameter.
--
-- Session variables are not visible inside procedures or tasks, so:
--   * all objects are created in one schema and reference each other unqualified (they resolve in their
--     own schema at run time);
--   * cluster_dns and app_name are stored in the config table MONGODB_SYNC_CONFIG, which the procedures read.
--     Change them later with UPDATE MONGODB_SYNC_CONFIG, no redeploy needed.
--
-- >>> Edit the values in this block, then run the whole file. <<<
-- Values must not contain single quotes.
SET db                  = 'ADMIN';                                  -- same as 01_setup.sql
SET schema              = 'MONGODB';                                -- same as 01_setup.sql
SET warehouse           = 'COMPUTE_WH';                             -- warehouse for the task
SET cluster_dns         = 'cluster0.abc123.mongodb.net';            -- host from the mongodb+srv:// string
SET app_name            = 'Cluster0';                               -- appName in the generated URI
SET initial_member_host = 'ac-xxxx-shard-00-00.abc123.mongodb.net'; -- any current member (first rule value)
-- <<< end of parameters >>>

SET schema_fqn = $db || '.' || $schema;

USE ROLE ACCOUNTADMIN;
USE SCHEMA IDENTIFIER($schema_fqn);

-- ---------------------------------------------------------------------------
-- 0. Config table (single row) read by the procedures
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS MONGODB_SYNC_CONFIG (CLUSTER_DNS VARCHAR, APP_NAME VARCHAR);
TRUNCATE TABLE MONGODB_SYNC_CONFIG;
INSERT INTO MONGODB_SYNC_CONFIG VALUES ($cluster_dns, $app_name);

-- ---------------------------------------------------------------------------
-- 1. Egress for DNS over HTTPS (Google JSON DNS API)
-- ---------------------------------------------------------------------------
CREATE NETWORK RULE IF NOT EXISTS DNS_OVER_HTTPS_RULE
  MODE = EGRESS TYPE = HOST_PORT VALUE_LIST = ('dns.google:443');

SET stmt = 'CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS DNS_OVER_HTTPS_EAI ALLOWED_NETWORK_RULES = (' ||
           $schema_fqn || '.DNS_OVER_HTTPS_RULE) ENABLED = TRUE';
EXECUTE IMMEDIATE $stmt;

-- ---------------------------------------------------------------------------
-- 2. Egress rule for the MongoDB members. Its VALUE_LIST is rewritten by
--    UPDATE_MONGODB_ATLAS_NETWORK_RULE. Add this rule to the External Access
--    Integration attached to your Openflow runtime, so the connector can reach the nodes.
-- ---------------------------------------------------------------------------
SET stmt = 'CREATE NETWORK RULE IF NOT EXISTS MONGODB_ATLAS_RULE MODE = EGRESS TYPE = HOST_PORT VALUE_LIST = (''' ||
           $initial_member_host || ':27017'')';
EXECUTE IMMEDIATE $stmt;

-- ---------------------------------------------------------------------------
-- 3. Table function: resolve replica-set members from SRV + TXT records
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION RESOLVE_MONGODB_MEMBERS(REPLICA_SET VARCHAR)
RETURNS TABLE (HOST VARCHAR, PORT NUMBER, PRIORITY NUMBER, WEIGHT NUMBER, TTL NUMBER, TXT_OPTIONS VARCHAR)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('requests')
HANDLER = 'Resolver'
EXTERNAL_ACCESS_INTEGRATIONS = (DNS_OVER_HTTPS_EAI)
AS $$
import requests

# Google JSON DNS-over-HTTPS API (must match DNS_OVER_HTTPS_RULE)
DOH_URL = "https://dns.google/resolve"

def _query(name, rtype):
    """Return the DoH 'Answer' list for name/rtype, or [] if the name does not resolve."""
    r = requests.get(DOH_URL, params={"name": name, "type": rtype}, timeout=10)
    r.raise_for_status()
    data = r.json()
    if data.get("Status") != 0:   # 0 = NOERROR; e.g. 3 = NXDOMAIN
        return []
    return data.get("Answer", [])

class Resolver:
    def process(self, cluster_dns):
        if not cluster_dns:
            return
        host = cluster_dns.strip().rstrip(".")
        # TXT record (type 16) holds default URI options; multiple records are joined with ';'
        txt = ";".join(a["data"].strip('"') for a in _query(host, "TXT") if a.get("type") == 16) or None
        # SRV records (type 33): data = "<priority> <weight> <port> <target>."
        for a in _query(f"_mongodb._tcp.{host}", "SRV"):
            if a.get("type") != 33:   # skip CNAMEs etc. in the answer chain
                continue
            prio, weight, port, target = a["data"].split()
            yield (target.rstrip("."), int(port), int(prio), int(weight), int(a.get("TTL", 0)), txt)
$$;

-- ---------------------------------------------------------------------------
-- 4. LOAD_MONGODB_MEMBERS: append a new batch only when the host:port set changed.
--    REPLICA_SET defaults to MONGODB_SYNC_CONFIG.CLUSTER_DNS.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE LOAD_MONGODB_MEMBERS(REPLICA_SET VARCHAR DEFAULT NULL)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS $$
DECLARE
  rs VARCHAR;           -- cluster DNS name (argument or config)
  diff_count INTEGER;   -- number of hosts that differ between new and latest batch
  n INTEGER;            -- rows inserted
BEGIN
  rs := COALESCE(:REPLICA_SET, (SELECT MAX(CLUSTER_DNS) FROM MONGODB_SYNC_CONFIG));
  IF (rs IS NULL) THEN
    RETURN 'No cluster given and MONGODB_SYNC_CONFIG is empty; nothing written';
  END IF;

  -- Resolve once and stage the result in a session temp table
  CREATE OR REPLACE TEMPORARY TABLE RESOLVED_MEMBERS AS
    SELECT r.* FROM TABLE(RESOLVE_MONGODB_MEMBERS(:rs)) r;

  -- Never record an empty member list
  IF ((SELECT COUNT(*) FROM RESOLVED_MEMBERS) = 0) THEN
    RETURN 'No members resolved for ' || :rs || '; nothing written';
  END IF;

  -- Compare host+port pairs against the latest saved batch for this cluster (both directions)
  SELECT COUNT(*) INTO :diff_count FROM (
    -- members that are new or changed port
    (SELECT HOST, PORT FROM RESOLVED_MEMBERS
     MINUS
     SELECT HOST, PORT FROM MONGODB_CLUSTER_NODES
     WHERE REPLICA_SET = :rs
       AND RESOLVED_AT = (SELECT MAX(RESOLVED_AT) FROM MONGODB_CLUSTER_NODES WHERE REPLICA_SET = :rs))
    UNION ALL
    -- members that disappeared or had a different port
    (SELECT HOST, PORT FROM MONGODB_CLUSTER_NODES
     WHERE REPLICA_SET = :rs
       AND RESOLVED_AT = (SELECT MAX(RESOLVED_AT) FROM MONGODB_CLUSTER_NODES WHERE REPLICA_SET = :rs)
     MINUS
     SELECT HOST, PORT FROM RESOLVED_MEMBERS)
  );

  IF (diff_count = 0) THEN
    RETURN 'Members unchanged for ' || :rs || '; nothing written';
  END IF;

  -- Write the full new member list as one batch (shared RESOLVED_AT)
  INSERT INTO MONGODB_CLUSTER_NODES
    (REPLICA_SET, HOST, PORT, PRIORITY, WEIGHT, TTL, TXT_OPTIONS, RESOLVED_AT)
  SELECT :rs, HOST, PORT, PRIORITY, WEIGHT, TTL, TXT_OPTIONS, CURRENT_TIMESTAMP()
  FROM RESOLVED_MEMBERS;
  n := SQLROWCOUNT;
  RETURN 'Members changed: ' || n || ' member(s) written for ' || :rs;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. UPDATE_MONGODB_ATLAS_NETWORK_RULE: sync MONGODB_ATLAS_RULE to the latest batch
--    (the procedure owner must own MONGODB_ATLAS_RULE)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE UPDATE_MONGODB_ATLAS_NETWORK_RULE(DRY_RUN BOOLEAN DEFAULT FALSE)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS $$
DECLARE
  value_list VARCHAR;
BEGIN
  -- Build a comma-separated list of 'host:port' from the latest batch
  SELECT LISTAGG('''' || HOST || ':' || PORT || '''', ', ')
           WITHIN GROUP (ORDER BY HOST)
    INTO :value_list
    FROM MONGODB_CLUSTER_NODES
    WHERE RESOLVED_AT = (SELECT MAX(RESOLVED_AT) FROM MONGODB_CLUSTER_NODES);

  IF (:value_list IS NULL OR :value_list = '') THEN
    RETURN 'No members found in MONGODB_CLUSTER_NODES; network rule not updated';
  END IF;

  IF (:DRY_RUN) THEN
    RETURN 'DRY_RUN — would set VALUE_LIST = (' || :value_list || ')';
  END IF;

  EXECUTE IMMEDIATE 'ALTER NETWORK RULE MONGODB_ATLAS_RULE SET VALUE_LIST = (' || :value_list || ')';

  RETURN 'UPDATED — VALUE_LIST = (' || :value_list || ')';
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. BUILD_MONGODB_CONNECTION_STRING: mongodb:// URI from the latest batch.
--    REPLICA_SET defaults to MONGODB_SYNC_CONFIG.CLUSTER_DNS; appName comes from MONGODB_SYNC_CONFIG.APP_NAME.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE BUILD_MONGODB_CONNECTION_STRING(REPLICA_SET VARCHAR DEFAULT NULL)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS $$
DECLARE
  rs VARCHAR;
  app VARCHAR;
  host_list VARCHAR;
  conn_string VARCHAR;
  txt VARCHAR;
  rs_name VARCHAR;
BEGIN
  SELECT COALESCE(:REPLICA_SET, MAX(CLUSTER_DNS)), MAX(APP_NAME) INTO :rs, :app FROM MONGODB_SYNC_CONFIG;
  IF (rs IS NULL) THEN
    RETURN 'No cluster given and MONGODB_SYNC_CONFIG is empty; connection string not built';
  END IF;

  -- Build comma-separated host:port list from the latest batch
  SELECT LISTAGG(HOST || ':' || PORT, ',') WITHIN GROUP (ORDER BY HOST),
         MAX(TXT_OPTIONS)
    INTO :host_list, :txt
    FROM MONGODB_CLUSTER_NODES
    WHERE REPLICA_SET = :rs
      AND RESOLVED_AT = (SELECT MAX(RESOLVED_AT) FROM MONGODB_CLUSTER_NODES WHERE REPLICA_SET = :rs);

  IF (:host_list IS NULL OR :host_list = '') THEN
    RETURN 'No members found for ' || :rs || '; connection string not built';
  END IF;

  -- Extract replicaSet value from TXT_OPTIONS (e.g. "authSource=admin&replicaSet=atlas-xxxx-shard-0")
  SELECT REGEXP_SUBSTR(:txt, 'replicaSet=([^&]+)', 1, 1, 'e') INTO :rs_name;

  -- Build the connection string (no credentials; the connector holds those separately)
  conn_string := 'mongodb://' || :host_list
              || '/?ssl=true'
              || '&replicaSet=' || NVL(:rs_name, 'unknown')
              || '&authSource=admin'
              || IFF(:app IS NULL OR :app = '', '', '&appName=' || :app);

  -- Store the connection string on all rows of the latest batch
  UPDATE MONGODB_CLUSTER_NODES
     SET CONNECTION_STRING = :conn_string
   WHERE REPLICA_SET = :rs
     AND RESOLVED_AT = (SELECT MAX(RESOLVED_AT) FROM MONGODB_CLUSTER_NODES WHERE REPLICA_SET = :rs);

  RETURN :conn_string;
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. Hourly task (created suspended; warehouse set from the parameter; resumed at the end)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TASK HOURLY_MONGODB_SYNC
  SCHEDULE = '60 MINUTE'
AS
EXECUTE IMMEDIATE $$
BEGIN
  CALL LOAD_MONGODB_MEMBERS();
  CALL UPDATE_MONGODB_ATLAS_NETWORK_RULE();
  CALL BUILD_MONGODB_CONNECTION_STRING();
END;
$$;

SET stmt = 'ALTER TASK HOURLY_MONGODB_SYNC SET WAREHOUSE = ' || $warehouse;
EXECUTE IMMEDIATE $stmt;

-- ---------------------------------------------------------------------------
-- 8. First run by hand, check, then start the schedule
-- ---------------------------------------------------------------------------
CALL LOAD_MONGODB_MEMBERS();
CALL UPDATE_MONGODB_ATLAS_NETWORK_RULE(TRUE);    -- dry run: shows the new VALUE_LIST
CALL UPDATE_MONGODB_ATLAS_NETWORK_RULE();
CALL BUILD_MONGODB_CONNECTION_STRING();
SELECT REPLICA_SET, HOST, PORT, CONNECTION_STRING, RESOLVED_AT
  FROM MONGODB_CLUSTER_NODES
 ORDER BY RESOLVED_AT DESC LIMIT 10;

ALTER TASK HOURLY_MONGODB_SYNC RESUME;

-- Monitor:
-- SELECT NAME, STATE, ERROR_MESSAGE, SCHEDULED_TIME, COMPLETED_TIME
--   FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'HOURLY_MONGODB_SYNC'))
--  ORDER BY SCHEDULED_TIME DESC LIMIT 20;
