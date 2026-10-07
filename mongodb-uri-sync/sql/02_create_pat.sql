-- 02_create_pat.sql — create the PAT used by mongodb-uri-sync.
-- Run in a Snowsight worksheet, after 01_setup.sql
-- (the network policy must be on the user before the PAT can be used).
-- The token_secret column is shown ONCE. Store it in your secret manager / .env as SNOWFLAKE_PAT.
--
-- >>> Edit the values in this block (must match 01_setup.sql), then run the whole file. <<<
SET sync_role = 'OPENFLOW_URI_SYNC_ROLE';   -- ROLE_RESTRICTION; must equal SNOWFLAKE_ROLE used by the script
SET sync_user = 'SVC_OPENFLOW_URI_SYNC';
SET pat_name  = 'MONGODB_URI_SYNC';
SET pat_days  = 90;
-- <<< end of parameters >>>

USE ROLE ACCOUNTADMIN;

SET stmt = 'ALTER USER ' || $sync_user || ' ADD PROGRAMMATIC ACCESS TOKEN ' || $pat_name ||
           ' ROLE_RESTRICTION = ''' || $sync_role || ''' DAYS_TO_EXPIRY = ' || $pat_days ||
           ' COMMENT = ''mongodb-uri-sync''';
EXECUTE IMMEDIATE $stmt;

-- Rotate (returns a new secret, old one stops working):
--   SET stmt = 'ALTER USER ' || $sync_user || ' ROTATE PROGRAMMATIC ACCESS TOKEN ' || $pat_name;
--   EXECUTE IMMEDIATE $stmt;
-- Inspect / remove:
--   SHOW USER PROGRAMMATIC ACCESS TOKENS FOR USER IDENTIFIER($sync_user);
--   SET stmt = 'ALTER USER ' || $sync_user || ' REMOVE PROGRAMMATIC ACCESS TOKEN ' || $pat_name;
--   EXECUTE IMMEDIATE $stmt;
