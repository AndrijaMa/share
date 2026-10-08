/*
    Create a fork of https://github.com/AndrijaMa/auto2
    Generate a PAT: permissions Read access to metadata,  Read and Write access to issues (Github Settings/Developer settings/Personal Access Token/Fine-grained tokens). Copy the pat value and use it in the github_pat variable below.
    Create paramaters and secrets in your repo:
    Security and quality/Secrets and variables:
    Actions:
    Create a secret OPENFLOW_PAT: Enter the value of the PAT that you genetrated for you SVC_OPENFLOW user
    Create 3 Variables:
    OPENFLOW_ACCOUNT: Snowflake Account identifier
    OPENFLOW_INGRESS_PREFIX: of2
    OPENFLOW_RUNTIME_KEY: The value is the name of your runtime 


    In the code below search for https://api.github.com/repos/AndrijaMa/automations/issues
    Relace AndrijaMa/automations with your github name/repo name
    Review conn_string := ''mongodb://'' || :host_list settings
    
*/
--search for NIFI_API and modify the url
SET db           = 'ADMIN';                     -- database for the table/procedures
SET schema       = 'MDB3';                   -- schema for the table/procedures
SET warehouse    = 'MYWH';                -- warehouse used by the script's SELECT
SET sync_role    = 'OPENFLOW_ADMIN';    -- role the Python script authenticates as
SET sync_user    = 'SVC_OPENFLOW_SVCx';     -- service user that owns the PAT
SET runtime_role = 'OPENFLOW_ADMIN'; 
SET github_pat   = 'github_pat';

SET schema_fqn = $db || '.' || $schema;


SET stmt = 'CREATE USER IF NOT EXISTS ' || $sync_user ||
           ' TYPE = SERVICE DEFAULT_ROLE = ' || $sync_role || ' DEFAULT_WAREHOUSE = ' || $warehouse ||
           ' COMMENT = ''mongodb-uri-sync service user''';
           
EXECUTE IMMEDIATE $stmt;
GRANT ROLE IDENTIFIER($sync_role) TO USER IDENTIFIER($sync_user);

--Save the output of the command as this is what will be coptied to GitHub Secret OPENFLOW_PAT

SET stmtx = 'ALTER USER IF EXISTS ' || $sync_user ||
            ' ADD PROGRAMMATIC ACCESS TOKEN OPENFLOW_SVC' ||
            ' ROLE_RESTRICTION = ' || $runtime_role ||
            ' DAYS_TO_EXPIRY = 90 ' ||
            ' COMMENT = ''GitHub permission to talk to OpenFlow''';
SELECT $stmtx;           
EXECUTE IMMEDIATE $stmtx            


CREATE DATABASE IF NOT EXISTS IDENTIFIER($db);
CREATE SCHEMA IF NOT EXISTS IDENTIFIER($schema_fqn);

USE SCHEMA IDENTIFIER($schema_fqn);



--Create a github PAT with read write Issues permissions
CREATE SECRET GITHUBACTIONS
    TYPE = GENERIC_STRING
    SECRET_STRING = $github_pat;
    
CREATE SECRET MONGODB 
    TYPE = GENERIC_STRING
    SECRET_STRING = 'mongodb://';

GRANT READ ON SECRET MONGODB TO ROLE IDENTIFIER($runtime_role);
GRANT USAGE ON SECRET MONGODB TO ROLE IDENTIFIER($runtime_role);
GRANT READ ON SECRET GITHUBACTIONS TO ROLE IDENTIFIER($runtime_role);
GRANT USAGE ON SECRET GITHUBACTIONS TO ROLE IDENTIFIER($runtime_role);

-- Allow outbound HTTPS to Google's public DNS-over-HTTPS endpoint only.
CREATE OR REPLACE NETWORK RULE GITHUB_API_RULE MODE = EGRESS TYPE = HOST_PORT VALUE_LIST = ('api.github.com:443');
CREATE OR REPLACE NETWORK RULE DNS_OVER_HTTPS_RULE MODE = EGRESS TYPE = HOST_PORT VALUE_LIST = ('dns.google:443');
CREATE OR REPLACE NETWORK RULE MONGODB_ATLAS_RULE MODE = EGRESS TYPE = HOST_PORT VALUE_LIST = ('dns.google:443');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION DNS_OVER_HTTPS_EAI ALLOWED_NETWORK_RULES = (DNS_OVER_HTTPS_RULE) ENABLED = TRUE;
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION GITHUB_API_ACCESS ALLOWED_NETWORK_RULES = (GITHUB_API_RULE) ENABLED = TRUE;
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION MONGODB_ATLAS_ACCESS ALLOWED_NETWORK_RULES = (MONGODB_ATLAS_RULE) ENABLED = TRUE;

ALTER EXTERNAL ACCESS INTEGRATION GITHUB_API_ACCESS SET ALLOWED_AUTHENTICATION_SECRETS = (GITHUBACTIONS);
--ALTER EXTERNAL ACCESS INTEGRATION GITHUB_API_ACCESS SET ALLOWED_AUTHENTICATION_SECRETS = (ADMIN.OPENFLOW.GITHUBACTIONS, ADMIN.MDB3.GITHUBACTIONS);

CREATE OR REPLACE TABLE MONGODB_CLUSTER_NODES (
  REPLICA_SET VARCHAR, HOST VARCHAR, PORT INTEGER, CONNECTION_STRING VARCHAR, PRIORITY INTEGER, WEIGHT INTEGER,
  TTL INTEGER, TXT_OPTIONS VARCHAR, RESOLVED_AT TIMESTAMP_LTZ);


CREATE OR REPLACE PROCEDURE UPDATE_MONGODB_ATLAS_NETWORK_RULE("DRY_RUN" BOOLEAN DEFAULT FALSE)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
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

  EXECUTE IMMEDIATE
    'ALTER NETWORK RULE MONGODB_ATLAS_RULE SET VALUE_LIST = (' || :value_list || ')';

  RETURN 'UPDATED — VALUE_LIST = (' || :value_list || ')';
END;
$$;

CREATE OR REPLACE PROCEDURE BUILD_MONGODB_CONNECTION_STRING("REPLICA_SET" VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS '
DECLARE
  host_list VARCHAR;
  conn_string VARCHAR;
  txt VARCHAR;
  rs_name VARCHAR;
BEGIN
  -- Build comma-separated host:port list from the latest batch
  SELECT LISTAGG(HOST || '':'' || PORT, '','') WITHIN GROUP (ORDER BY HOST),
         MAX(TXT_OPTIONS)
    INTO :host_list, :txt
    FROM MONGODB_CLUSTER_NODES
    WHERE REPLICA_SET = :REPLICA_SET
      AND RESOLVED_AT = (SELECT MAX(RESOLVED_AT)
                           FROM MONGODB_CLUSTER_NODES
                          WHERE REPLICA_SET = :REPLICA_SET);

  IF (:host_list IS NULL OR :host_list = '''') THEN
    RETURN ''No members found for '' || :REPLICA_SET || ''; connection string not built'';
  END IF;

  -- Extract replicaSet value from TXT_OPTIONS (e.g. "authSource=admin&replicaSet=atlas-84odu6-shard-0")
  SELECT REGEXP_SUBSTR(:txt, ''replicaSet=([^&]+)'', 1, 1, ''e'') INTO :rs_name;

  -- Build the connection string
  conn_string := ''mongodb://'' || :host_list
              || ''/?ssl=true''
              || ''&replicaSet='' || NVL(:rs_name, ''unknown'')
              || ''&authSource=admin''
              || ''&appName=Cluster0'';

  -- Store the connection string on all rows of the latest batch
  UPDATE MONGODB_CLUSTER_NODES
     SET CONNECTION_STRING = :conn_string
   WHERE REPLICA_SET = :REPLICA_SET
     AND RESOLVED_AT = (SELECT MAX(RESOLVED_AT)
                          FROM MONGODB_CLUSTER_NODES
                         WHERE REPLICA_SET = :REPLICA_SET);

  RETURN :conn_string;
END;
';

CREATE OR REPLACE PROCEDURE CREATE_GITHUB_ISSUE("CLUSTER_NAME" VARCHAR, "CLUSTER_MEMBERS" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('requests','snowflake-snowpark-python')
HANDLER = 'main'
EXTERNAL_ACCESS_INTEGRATIONS = (GITHUB_API_ACCESS)
SECRETS = ('github_token'=GITHUBACTIONS)
EXECUTE AS OWNER
AS '
import _snowflake
import requests
from datetime import datetime

def main(session, cluster_name, cluster_members):
    token = _snowflake.get_generic_secret_string(''github_token'')
    now = datetime.utcnow().strftime(''%y%m%d %H:%M:%S'')
    title = f''MongoDB {cluster_name} {now}''

    nl = chr(10)
    body = f''## Cluster members changed{nl}{nl}**Cluster:** {cluster_name}{nl}{nl}**New members:**{nl}{cluster_members}''

    resp = requests.post(
        ''https://api.github.com/repos/AndrijaMa/automations/issues'',
        headers={
            ''Authorization'': f''Bearer {token}'',
            ''Accept'': ''application/vnd.github+json'',
            ''X-GitHub-Api-Version'': ''2022-11-28'',
        },
        json={''title'': title, ''body'': body},
        timeout=30,
    )
    resp.raise_for_status()
    issue = resp.json()
    return f"Created issue #{issue[''number'']}: {issue[''html_url'']}"
';



CREATE OR REPLACE PROCEDURE LOAD_MONGODB_MEMBERS(REPLICA_SET VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
  diff_count INTEGER;   -- number of hosts that differ between new and latest batch
  n INTEGER;            -- rows inserted
BEGIN
  -- Resolve once and stage the result in a session temp table
  CREATE OR REPLACE TEMPORARY TABLE RESOLVED_MEMBERS AS
    SELECT r.* FROM TABLE(RESOLVE_MONGODB_MEMBERS(:REPLICA_SET)) r;

  -- Never record an empty member list
  IF ((SELECT COUNT(*) FROM RESOLVED_MEMBERS) = 0) THEN
    RETURN 'No members resolved for ' || :REPLICA_SET || '; nothing written';
  END IF;

  -- Compare host+port pairs against the latest saved batch for this cluster (both directions)
   SELECT COUNT(*) INTO :diff_count FROM (
     -- members that are new or changed port
     (SELECT HOST, PORT FROM RESOLVED_MEMBERS
      MINUS
      SELECT HOST, PORT FROM MONGODB_CLUSTER_NODES
      WHERE REPLICA_SET = :REPLICA_SET
        AND RESOLVED_AT = (SELECT MAX(RESOLVED_AT) FROM MONGODB_CLUSTER_NODES WHERE REPLICA_SET = :REPLICA_SET))
     UNION ALL
     -- members that disappeared or had a different port
     (SELECT HOST, PORT FROM MONGODB_CLUSTER_NODES
      WHERE REPLICA_SET = :REPLICA_SET
        AND RESOLVED_AT = (SELECT MAX(RESOLVED_AT) FROM MONGODB_CLUSTER_NODES WHERE REPLICA_SET = :REPLICA_SET)
      MINUS
      SELECT HOST, PORT FROM RESOLVED_MEMBERS)
   );

   IF (diff_count = 0) THEN
     RETURN 'Members unchanged for ' || :REPLICA_SET || '; nothing written';
   END IF;

   -- Write the full new member list as one batch (shared RESOLVED_AT)
   INSERT INTO MONGODB_CLUSTER_NODES
     (REPLICA_SET, HOST, PORT, PRIORITY, WEIGHT, TTL, TXT_OPTIONS, RESOLVED_AT)
   SELECT :REPLICA_SET, HOST, PORT, PRIORITY, WEIGHT, TTL, TXT_OPTIONS, CURRENT_TIMESTAMP()
   FROM RESOLVED_MEMBERS;
   n := SQLROWCOUNT;
   RETURN 'Members changed: ' || n || ' member(s) written for ' || :REPLICA_SET;
END;
$$;




CREATE OR REPLACE FUNCTION RESOLVE_MONGODB_MEMBERS("REPLICA_SET" VARCHAR)
RETURNS TABLE ("HOST" VARCHAR, "PORT" NUMBER(38,0), "PRIORITY" NUMBER(38,0), "WEIGHT" NUMBER(38,0), "TTL" NUMBER(38,0), "TXT_OPTIONS" VARCHAR)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('requests')
HANDLER = 'Resolver'
EXTERNAL_ACCESS_INTEGRATIONS = (DNS_OVER_HTTPS_EAI)
AS '
import requests

# Google JSON DNS-over-HTTPS API (must match DNS_OVER_HTTPS_RULE)
DOH_URL = "https://dns.google/resolve"

def _query(name, rtype):
    """Return the DoH ''Answer'' list for name/rtype, or [] if the name does not resolve."""
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
        # TXT record (type 16) holds default URI options; multiple records are joined with '';''
        txt = ";".join(a["data"].strip(''"'') for a in _query(host, "TXT") if a.get("type") == 16) or None
        # SRV records (type 33): data = "<priority> <weight> <port> <target>."
        for a in _query(f"_mongodb._tcp.{host}", "SRV"):
            if a.get("type") != 33:   # skip CNAMEs etc. in the answer chain
                continue
            prio, weight, port, target = a["data"].split()
            yield (target.rstrip("."), int(port), int(prio), int(weight), int(a.get("TTL", 0)), txt)
';


CREATE OR REPLACE PROCEDURE REFRESH_MONGODB_CLUSTER("REPLICA_SET" VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS '
DECLARE
  load_status VARCHAR;
  conn_str VARCHAR;
  members_list VARCHAR;
  changed BOOLEAN DEFAULT FALSE;
BEGIN
  -- 1. Resolve members and write only if hosts changed
  CALL LOAD_MONGODB_MEMBERS(:REPLICA_SET);
  SELECT * INTO :load_status FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

  changed := (load_status LIKE ''Members changed%'');

  IF (NOT changed) THEN
    RETURN load_status;
  END IF;

  -- 2. Update the network rule with the new host:port list
  CALL UPDATE_MONGODB_ATLAS_NETWORK_RULE();

  -- 3. Rebuild the connection string
  CALL BUILD_MONGODB_CONNECTION_STRING(:REPLICA_SET);

  -- 4. Update the Openflow MongoDB secret with the latest connection string
  SELECT CONNECTION_STRING INTO :conn_str
    FROM MONGODB_CLUSTER_NODES
    WHERE RESOLVED_AT = (SELECT MAX(RESOLVED_AT) FROM MONGODB_CLUSTER_NODES)
    LIMIT 1;

  EXECUTE IMMEDIATE
    ''ALTER SECRET MONGODB SET SECRET_STRING = '''''' || REPLACE(:conn_str, '''''''', ''\\\\'''''') || '''''''';

  -- 5. Build a member list for the GitHub issue body
  SELECT LISTAGG(''- '' || HOST || '':'' || PORT, ''\\n'') WITHIN GROUP (ORDER BY HOST)
    INTO :members_list
    FROM MONGODB_CLUSTER_NODES
    WHERE RESOLVED_AT = (SELECT MAX(RESOLVED_AT) FROM MONGODB_CLUSTER_NODES);

  -- 6. Open a GitHub issue to notify the team
  CALL CREATE_GITHUB_ISSUE(:REPLICA_SET, :members_list);

  RETURN load_status || '' | Network rule updated | Connection string rebuilt | Secret updated | GitHub issue created'';
END;
';

create or replace task HOURLY_MONGODB_SYNC
	warehouse=MYWH
	schedule='60 MINUTE'fREFRESH_MONGODB_CLUSTER
	as BEGIN
    CALL REFRESH_MONGODB_CLUSTER('cluster0.iqm3dvu.mongodb.net');
END;

CALL REFRESH_MONGODB_CLUSTER('cluster0.iqm3dvu.mongodb.net');

SELECT * FROM MONGODB_CLUSTER_NODES;
TRUNCATE MONGODB_CLUSTER_NODES;

--Simulate change
UPDATE MONGODB_CLUSTER_NODES SET HOST = 'cc-5e4dtv2-shard-00-01.iqm3dvu.mongodb.net' WHERE REPLICA_SET = 'cluster0.iqm3dvu.mongodb.net';
