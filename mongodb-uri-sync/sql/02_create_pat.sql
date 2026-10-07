-- 02_create_pat.sql — create the PAT used by mongodb-uri-sync.
-- The token_secret column is shown ONCE. Store it in your secret manager / .env as SNOWFLAKE_PAT.
-- ROLE_RESTRICTION must equal SNOWFLAKE_ROLE used by the script.
-- Run after 01_setup.sql (the network policy must be on the user before the PAT can be used).

USE ROLE ACCOUNTADMIN;

ALTER USER SVC_OPENFLOW_URI_SYNC ADD PROGRAMMATIC ACCESS TOKEN MONGODB_URI_SYNC
  ROLE_RESTRICTION = 'OPENFLOW_URI_SYNC_ROLE'
  DAYS_TO_EXPIRY = 90
  COMMENT = 'mongodb-uri-sync';

-- Rotate (returns a new secret, old one stops working):
-- ALTER USER SVC_OPENFLOW_URI_SYNC ROTATE PROGRAMMATIC ACCESS TOKEN MONGODB_URI_SYNC;
-- Inspect / remove:
-- SHOW USER PROGRAMMATIC ACCESS TOKENS FOR USER SVC_OPENFLOW_URI_SYNC;
-- ALTER USER SVC_OPENFLOW_URI_SYNC REMOVE PROGRAMMATIC ACCESS TOKEN MONGODB_URI_SYNC;
