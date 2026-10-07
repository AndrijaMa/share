-- 03_mongodb_discovery.sql — fills MONGODB_CLUSTER_NODES and keeps it current.
--
-- Hourly task HOURLY_MONGODB_SYNC runs three procedures in order:
--   1. LOAD_MONGODB_MEMBERS(cluster)            resolve the Atlas SRV/TXT records (DNS over HTTPS) and append a
--                                               new batch to MONGODB_CLUSTER_NODES, only if members changed
--   2. UPDATE_MONGODB_ATLAS_NETWORK_RULE()      point the egress network rule MONGODB_ATLAS_RULE at the current
--                                               members, so the Openflow runtime can still reach the cluster
--   3. BUILD_MONGODB_CONNECTION_STRING(cluster) build the mongodb:// URI and store it on the latest batch
-- mongodb_uri_to_openflow.py then copies that CONNECTION_STRING into the connector parameter.
--
-- Run after 01_setup.sql, as ACCOUNTADMIN (network rules / integrations / tasks need elevated privileges).
-- Search/replace these placeholders before running:
--   <DB>, <SCHEMA>         same as in 01_setup.sql
--   <WAREHOUSE>            warehouse for the task
--   <CLUSTER_DNS>          Atlas cluster host from the SRV connection string, e.g. cluster0.abc123.mongodb.net
--   <APP_NAME>             appName put in the URI, e.g. Cluster0
--   <INITIAL_MEMBER_HOST>  any one current member host (placeholder for the rule until step 2 runs), e.g.
--                          ac-xxxx-shard-00-00.abc123.mongodb.net

USE ROLE ACCOUNTADMIN;
USE SCHEMA <DB>.<SCHEMA>;

-- ---------------------------------------------------------------------------
-- 1. Egress for DNS over HTTPS (Google JSON DNS API)
-- ---------------------------------------------------------------------------
CREATE NETWORK RULE IF NOT EXISTS <DB>.<SCHEMA>.DNS_OVER_HTTPS_RULE
  MODE = EGRESS TYPE = HOST_PORT VALUE_LIST = ('dns.google:443');

CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS DNS_OVER_HTTPS_EAI
  ALLOWED_NETWORK_RULES = (<DB>.<SCHEMA>.DNS_OVER_HTTPS_RULE)
  ENABLED = TRUE;

-- ---------------------------------------------------------------------------
-- 2. Egress rule for the MongoDB members. Its VALUE_LIST is rewritten by
--    UPDATE_MONGODB_ATLAS_NETWORK_RULE. Add this rule to the External Access
--    Integration attached to your Openflow runtime, so the connector can reach the nodes.
-- ---------------------------------------------------------------------------
CREATE NETWORK RULE IF NOT EXISTS <DB>.<SCHEMA>.MONGODB_ATLAS_RULE
  MODE = EGRESS TYPE = HOST_PORT VALUE_LIST = ('<INITIAL_MEMBER_HOST>:27017');

-- ---------------------------------------------------------------------------
-- 3. Table function: resolve replica-set members from SRV + TXT records
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION <DB>.<SCHEMA>.RESOLVE_MONGODB_MEMBERS(REPLICA_SET VARCHAR)
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
-- 4. LOAD_MONGODB_MEMBERS: append a new batch only when host:port set changed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE <DB>.<SCHEMA>.LOAD_MONGODB_MEMBERS(REPLICA_SET VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS $$
DECLARE
  diff_count INTEGER;   -- number of hosts that differ between new and latest batch
  n INTEGER;            -- rows inserted
BEGIN
  -- Resolve once and stage the result in a session temp table
  CREATE OR REPLACE TEMPORARY TABLE RESOLVED_MEMBERS AS
    SELECT r.* FROM TABLE(<DB>.<SCHEMA>.RESOLVE_MONGODB_MEMBERS(:REPLICA_SET)) r;

  -- Never record an empty member list
  IF ((SELECT COUNT(*) FROM RESOLVED_MEMBERS) = 0) THEN
    RETURN 'No members resolved for ' || :REPLICA_SET || '; nothing written';
  END IF;

  -- Compare host+port pairs against the latest saved batch for this cluster (both directions)
  SELECT COUNT(*) INTO :diff_count FROM (
    -- members that are new or changed port
    (SELECT HOST, PORT FROM RESOLVED_MEMBERS
     MINUS
     SELECT HOST, PORT FROM <DB>.<SCHEMA>.MONGODB_CLUSTER_NODES
     WHERE REPLICA_SET = :REPLICA_SET
       AND RESOLVED_AT = (SELECT MAX(RESOLVED_AT) FROM <DB>.<SCHEMA>.MONGODB_CLUSTER_NODES WHERE REPLICA_SET = :REPLICA_SET))
    UNION ALL
    -- members that disappeared or had a different port
    (SELECT HOST, PORT FROM <DB>.<SCHEMA>.MONGODB_CLUSTER_NODES
     WHERE REPLICA_SET = :REPLICA_SET
       AND RESOLVED_AT = (SELECT MAX(RESOLVED_AT) FROM <DB>.<SCHEMA>.MONGODB_CLUSTER_NODES WHERE REPLICA_SET = :REPLICA_SET)
     MINUS
     SELECT HOST, PORT FROM RESOLVED_MEMBERS)
  );

  IF (diff_count = 0) THEN
    RETURN 'Members unchanged for ' || :REPLICA_SET || '; nothing written';
  END IF;

  -- Write the full new member list as one batch (shared RESOLVED_AT)
  INSERT INTO <DB>.<SCHEMA>.MONGODB_CLUSTER_NODES
    (REPLICA_SET, HOST, PORT, PRIORITY, WEIGHT, TTL, TXT_OPTIONS, RESOLVED_AT)
  SELECT :REPLICA_SET, HOST, PORT, PRIORITY, WEIGHT, TTL, TXT_OPTIONS, CURRENT_TIMESTAMP()
  FROM RESOLVED_MEMBERS;
  n := SQLROWCOUNT;
  RETURN 'Members changed: ' || n || ' member(s) written for ' || :REPLICA_SET;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. UPDATE_MONGODB_ATLAS_NETWORK_RULE: sync MONGODB_ATLAS_RULE to the latest batch
--    (the procedure owner must own MONGODB_ATLAS_RULE)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE <DB>.<SCHEMA>.UPDATE_MONGODB_ATLAS_NETWORK_RULE(DRY_RUN BOOLEAN DEFAULT FALSE)
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
    FROM <DB>.<SCHEMA>.MONGODB_CLUSTER_NODES
    WHERE RESOLVED_AT = (SELECT MAX(RESOLVED_AT) FROM <DB>.<SCHEMA>.MONGODB_CLUSTER_NODES);

  IF (:value_list IS NULL OR :value_list = '') THEN
    RETURN 'No members found in MONGODB_CLUSTER_NODES; network rule not updated';
  END IF;

  IF (:DRY_RUN) THEN
    RETURN 'DRY_RUN — would set VALUE_LIST = (' || :value_list || ')';
  END IF;

  EXECUTE IMMEDIATE
    'ALTER NETWORK RULE <DB>.<SCHEMA>.MONGODB_ATLAS_RULE SET VALUE_LIST = (' || :value_list || ')';

  RETURN 'UPDATED — VALUE_LIST = (' || :value_list || ')';
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. BUILD_MONGODB_CONNECTION_STRING: mongodb:// URI from the latest batch
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE <DB>.<SCHEMA>.BUILD_MONGODB_CONNECTION_STRING(REPLICA_SET VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS $$
DECLARE
  host_list VARCHAR;
  conn_string VARCHAR;
  txt VARCHAR;
  rs_name VARCHAR;
BEGIN
  -- Build comma-separated host:port list from the latest batch
  SELECT LISTAGG(HOST || ':' || PORT, ',') WITHIN GROUP (ORDER BY HOST),
         MAX(TXT_OPTIONS)
    INTO :host_list, :txt
    FROM <DB>.<SCHEMA>.MONGODB_CLUSTER_NODES
    WHERE REPLICA_SET = :REPLICA_SET
      AND RESOLVED_AT = (SELECT MAX(RESOLVED_AT)
                           FROM <DB>.<SCHEMA>.MONGODB_CLUSTER_NODES
                          WHERE REPLICA_SET = :REPLICA_SET);

  IF (:host_list IS NULL OR :host_list = '') THEN
    RETURN 'No members found for ' || :REPLICA_SET || '; connection string not built';
  END IF;

  -- Extract replicaSet value from TXT_OPTIONS (e.g. "authSource=admin&replicaSet=atlas-xxxx-shard-0")
  SELECT REGEXP_SUBSTR(:txt, 'replicaSet=([^&]+)', 1, 1, 'e') INTO :rs_name;

  -- Build the connection string (no credentials; the connector holds those separately)
  conn_string := 'mongodb://' || :host_list
              || '/?ssl=true'
              || '&replicaSet=' || NVL(:rs_name, 'unknown')
              || '&authSource=admin'
              || '&appName=<APP_NAME>';

  -- Store the connection string on all rows of the latest batch
  UPDATE <DB>.<SCHEMA>.MONGODB_CLUSTER_NODES
     SET CONNECTION_STRING = :conn_string
   WHERE REPLICA_SET = :REPLICA_SET
     AND RESOLVED_AT = (SELECT MAX(RESOLVED_AT)
                          FROM <DB>.<SCHEMA>.MONGODB_CLUSTER_NODES
                         WHERE REPLICA_SET = :REPLICA_SET);

  RETURN :conn_string;
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. Hourly task (created suspended; resumed at the end)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TASK <DB>.<SCHEMA>.HOURLY_MONGODB_SYNC
  WAREHOUSE = <WAREHOUSE>
  SCHEDULE = '60 MINUTE'
AS
BEGIN
  CALL <DB>.<SCHEMA>.LOAD_MONGODB_MEMBERS('<CLUSTER_DNS>');
  CALL <DB>.<SCHEMA>.UPDATE_MONGODB_ATLAS_NETWORK_RULE();
  CALL <DB>.<SCHEMA>.BUILD_MONGODB_CONNECTION_STRING('<CLUSTER_DNS>');
END;

-- ---------------------------------------------------------------------------
-- 8. First run by hand, check, then start the schedule
-- ---------------------------------------------------------------------------
CALL <DB>.<SCHEMA>.LOAD_MONGODB_MEMBERS('<CLUSTER_DNS>');
CALL <DB>.<SCHEMA>.UPDATE_MONGODB_ATLAS_NETWORK_RULE(TRUE);    -- dry run: shows the new VALUE_LIST
CALL <DB>.<SCHEMA>.UPDATE_MONGODB_ATLAS_NETWORK_RULE();
CALL <DB>.<SCHEMA>.BUILD_MONGODB_CONNECTION_STRING('<CLUSTER_DNS>');
SELECT REPLICA_SET, HOST, PORT, CONNECTION_STRING, RESOLVED_AT
  FROM <DB>.<SCHEMA>.MONGODB_CLUSTER_NODES
 ORDER BY RESOLVED_AT DESC LIMIT 10;

ALTER TASK <DB>.<SCHEMA>.HOURLY_MONGODB_SYNC RESUME;

-- Monitor:
-- SELECT NAME, STATE, ERROR_MESSAGE, SCHEDULED_TIME, COMPLETED_TIME
--   FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'HOURLY_MONGODB_SYNC'))
--  ORDER BY SCHEDULED_TIME DESC LIMIT 20;
