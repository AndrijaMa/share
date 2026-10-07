# mongodb-uri-sync

Keeps an Openflow MongoDB connector pointed at the right MongoDB cluster.

- **In Snowflake (Snowsight):** an hourly task resolves the Atlas cluster members, keeps an egress network rule
  in sync with them, and builds a `mongodb://` connection string into a table.
- **Locally (Python):** a script reads the most recent `CONNECTION_STRING` from that table and writes it to the
  connector parameter (default `MongoDB Connection URI`) on the Openflow runtime.

```
Atlas DNS (SRV/TXT) ──▶ HOURLY_MONGODB_SYNC task (Snowflake)
                          1. LOAD_MONGODB_MEMBERS              → MONGODB_CLUSTER_NODES (new batch if members changed)
                          2. UPDATE_MONGODB_ATLAS_NETWORK_RULE → MONGODB_ATLAS_RULE egress rule = current members
                          3. BUILD_MONGODB_CONNECTION_STRING   → CONNECTION_STRING on latest batch

MONGODB_CLUSTER_NODES ──(PAT, SQL)──▶ mongodb_uri_to_openflow.py (your machine) ──(PAT, NiFi REST)──▶ connector parameter
```

> Sample code provided as-is, without warranty or official Snowflake support. Review and test before production use.

## Contents

| File | Runs in | Purpose |
|---|---|---|
| `sql/01_setup.sql` | Snowsight | Role, service user, table, grants, network policy |
| `sql/02_create_pat.sql` | Snowsight | Creates / rotates the PAT for the service user |
| `sql/03_mongodb_discovery.sql` | Snowsight | Config table, DNS resolver function, procedures `LOAD_MONGODB_MEMBERS`, `UPDATE_MONGODB_ATLAS_NETWORK_RULE`, `BUILD_MONGODB_CONNECTION_STRING`, network rules, EAI and task `HOURLY_MONGODB_SYNC` |
| `mongodb_uri_to_openflow.py` | Local | The sync script (dry run by default) |
| `requirements.txt` | Local | Python dependencies |
| `config.example.env` | Local | Script settings, copy to `.env` |

## Prerequisites

### Snowflake / Openflow
- An Openflow deployment with a runtime that has the MongoDB connector added to its canvas.
- Access to Snowsight with `ACCOUNTADMIN` (or a role that can create roles, users, network rules and policies,
  external access integrations, functions, procedures and tasks).
- A warehouse for the task and for the script's query.
- A MongoDB Atlas cluster and its SRV host (the part after `mongodb+srv://`, e.g. `cluster0.abc123.mongodb.net`).
  The connector's username and password are configured separately; the generated URI contains no credentials.

### Local machine (for the Python script)
- **Python 3.9 or newer** with `pip` and `venv`:
  - macOS: `brew install python` (or the installer from python.org)
  - Linux (Debian/Ubuntu): `sudo apt install python3 python3-venv python3-pip`
  - Windows: installer from python.org (tick "Add python.exe to PATH")
  - Check: `python3 --version` (Windows: `py --version`)
- **Outbound HTTPS (port 443)** from the machine to:
  - `<account_identifier>.snowflakecomputing.com` (Snowflake SQL)
  - the Openflow runtime host, e.g. `of2--<org>-<account>.snowflakecomputing.app`
    (the `server_url` from `DESCRIBE OPENFLOW RUNTIME`)
  - `pypi.org` / `files.pythonhosted.org` once, for `pip install`
- **The machine's public IP**, used as `runner_ip` in `01_setup.sql` (the PAT is rejected from any other IP).
  Find it with `curl https://ifconfig.me`, or ask your network team for the egress IP or range.
  If the IP changes (VPN, DHCP, a different office), update the network rule `URI_SYNC_RUNNER_IPS`.
- **The PAT** from step 2 below.

## Part 1: Snowflake setup (Snowsight)

Open each file in a Snowsight worksheet (**Projects » Worksheets » + » SQL Worksheet**, then paste it in or use
**Create from file**). Edit the `SET` block at the top, between `>>> Edit the values in this block <<<` and
`<<< end of parameters >>>`, then click **Run All** (the ▾ next to Run, or Ctrl/Cmd+Shift+Enter).
Values must not contain single quotes.

| Parameter | File | Meaning |
|---|---|---|
| `db`, `schema` | 01, 03 | Location of the table, procedures, rules and task (use the same values in both files) |
| `warehouse` | 01, 03 | Warehouse for the script's SELECT and for the task |
| `sync_role`, `sync_user` | 01, 02 | Service role and user the Python script authenticates as |
| `runtime_role` | 01 | Role that administers the Openflow runtime (e.g. `OPENFLOW_ADMIN`) |
| `runner_ip` | 01 | Public IP of the machine running the Python script |
| `pat_name`, `pat_days` | 02 | PAT name and lifetime |
| `cluster_dns` | 03 | Atlas SRV host from the `mongodb+srv://` string |
| `app_name` | 03 | `appName` in the generated URI (empty = omitted) |
| `initial_member_host` | 03 | Any one current member host, the first value of `MONGODB_ATLAS_RULE` (must resolve in DNS) |

1. **Snowflake objects**: run `sql/01_setup.sql`.
2. **PAT**: run `sql/02_create_pat.sql` and copy `token_secret` from the result grid. Snowflake shows it only
   once. Don't share your screen while you do this.
3. **Discovery and hourly task**: run `sql/03_mongodb_discovery.sql`. It creates:
   - `MONGODB_SYNC_CONFIG`: a one-row table holding `cluster_dns` and `app_name`. The procedures and the task
     read it, because session variables are not visible inside them. To change these values later, run
     `UPDATE MONGODB_SYNC_CONFIG SET ...`; you don't need to redeploy.
   - `DNS_OVER_HTTPS_RULE` + `DNS_OVER_HTTPS_EAI` (egress to `dns.google:443`) and the Python table function
     `RESOLVE_MONGODB_MEMBERS`, which reads the cluster's `_mongodb._tcp` SRV and TXT records.
   - `MONGODB_ATLAS_RULE`: an egress rule for the member hosts.
   - The three procedures (the cluster argument is optional and defaults to the config table) and the task
     `HOURLY_MONGODB_SYNC`, which runs them every 60 minutes.

   The file ends with a manual first run, a check query and `ALTER TASK ... RESUME`. Before you continue,
   confirm that `CONNECTION_STRING` is filled in the check query's output.

   The newest batch (by `RESOLVED_AT`) is the current one. A new batch is written only when the set of
   host:port members changes, so the table stays small.
4. **Let the connector reach the nodes**: add `MONGODB_ATLAS_RULE` to the External Access Integration used by
   your Openflow runtime (for example `ALTER EXTERNAL ACCESS INTEGRATION <runtime_eai> SET ALLOWED_NETWORK_RULES = (...existing rules..., <db>.<schema>.MONGODB_ATLAS_RULE);`).
   Otherwise the connector can't reach new members when they change.

## Examples (Snowsight)

Replace `ADMIN.MONGODB` and the cluster host with your own values.

```sql
-- Look up the members without saving:
SELECT * FROM TABLE(ADMIN.MONGODB.RESOLVE_MONGODB_MEMBERS('cluster0.iqm3dvu.mongodb.net'));

-- Resolve and save (only writes when host names changed):
CALL ADMIN.MONGODB.LOAD_MONGODB_MEMBERS('cluster0.iqm3dvu.mongodb.net');

-- Build the connection string and write it to the table:
CALL ADMIN.MONGODB.BUILD_MONGODB_CONNECTION_STRING('cluster0.iqm3dvu.mongodb.net');

-- Show the new network rule value without changing it, then apply it:
CALL ADMIN.MONGODB.UPDATE_MONGODB_ATLAS_NETWORK_RULE(TRUE);
CALL ADMIN.MONGODB.UPDATE_MONGODB_ATLAS_NETWORK_RULE();

-- Without an argument, the procedures use the cluster from MONGODB_SYNC_CONFIG (this is what the task does):
CALL ADMIN.MONGODB.LOAD_MONGODB_MEMBERS();
CALL ADMIN.MONGODB.BUILD_MONGODB_CONNECTION_STRING();

-- Current connection string:
SELECT CONNECTION_STRING, RESOLVED_AT
  FROM ADMIN.MONGODB.MONGODB_CLUSTER_NODES
 WHERE CONNECTION_STRING IS NOT NULL
 ORDER BY RESOLVED_AT DESC LIMIT 1;

-- Change the cluster or appName later:
UPDATE ADMIN.MONGODB.MONGODB_SYNC_CONFIG SET CLUSTER_DNS = 'cluster0.iqm3dvu.mongodb.net', APP_NAME = 'Cluster0';

-- Task control and history:
EXECUTE TASK ADMIN.MONGODB.HOURLY_MONGODB_SYNC;   -- run now
ALTER TASK ADMIN.MONGODB.HOURLY_MONGODB_SYNC SUSPEND;
ALTER TASK ADMIN.MONGODB.HOURLY_MONGODB_SYNC RESUME;
SELECT NAME, STATE, ERROR_MESSAGE, SCHEDULED_TIME, COMPLETED_TIME
  FROM TABLE(ADMIN.INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'HOURLY_MONGODB_SYNC'))
 ORDER BY SCHEDULED_TIME DESC LIMIT 20;
```

## Part 2: Python script (local machine)

### Install

macOS / Linux:
```bash
cd mongodb-uri-sync
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
cp config.example.env .env
```

Windows (PowerShell):
```powershell
cd mongodb-uri-sync
py -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
copy config.example.env .env
```

### Configure

Edit `.env`. Put the PAT from Part 1, step 2 in `SNOWFLAKE_PAT`.

| Setting | Value |
|---|---|
| `SNOWFLAKE_ACCOUNT` | Account identifier, `<orgname>-<account_name>` |
| `SNOWFLAKE_USER`, `SNOWFLAKE_ROLE` | `sync_user` and `sync_role` from `01_setup.sql` |
| `SNOWFLAKE_WAREHOUSE` | `warehouse` from `01_setup.sql` |
| `SYNC_TABLE` | `<db>.<schema>.MONGODB_CLUSTER_NODES` |
| `OPENFLOW_DEPLOYMENT`, `OPENFLOW_RUNTIME` | The `deployment` and `name` (or `display_name`) columns of `SHOW OPENFLOW RUNTIMES IN ACCOUNT` |
| `OPENFLOW_CONNECTOR` | Exact name of the connector's process group on the runtime canvas |
| `OPENFLOW_PARAMETER` | Parameter to write (default `MongoDB Connection URI`) |

### Run

macOS / Linux:
```bash
set -a; . ./.env; set +a
python mongodb_uri_to_openflow.py            # dry run: shows what would change
python mongodb_uri_to_openflow.py --apply    # writes the parameter
```

Windows (PowerShell):
```powershell
Get-Content .env | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
  $k, $v = $_ -split '=', 2; [Environment]::SetEnvironmentVariable($k.Trim(), $v.Trim(), 'Process') }
python mongodb_uri_to_openflow.py
python mongodb_uri_to_openflow.py --apply
```

Every setting can also be passed as a flag (`--account`, `--user`, `--role`, `--warehouse`, `--table`,
`--deployment`, `--runtime`, `--connector`, `--parameter`, `--runtime-url`). Run `--help` for the full list.
The PAT is read only from `SNOWFLAKE_PAT`, so it never appears in your shell history or process list.

Example output:
```
Latest connection string from ADMIN.MONGODB.MONGODB_CLUSTER_NODES (RESOLVED_AT 2026-10-07 09:12:00+02:00)
Runtime API: https://of2--myorg-myacct.snowflakecomputing.app:443/demo-100/nifi-api
Authenticated as SVC_OPENFLOW_URI_SYNC
Parameter 'MongoDB Connection URI' lives in context 'MongoDB Source Parameters' (sensitive=False)
Parameter updated.
```

### Schedule (optional)

The script is idempotent: if the runtime already has the value, it changes nothing. The Snowflake task refreshes
the table hourly, so running the script hourly as well (offset by a few minutes) is enough.

macOS / Linux, using cron:
```cron
10 * * * * cd /path/to/mongodb-uri-sync && set -a && . ./.env && set +a && .venv/bin/python mongodb_uri_to_openflow.py --apply >> sync.log 2>&1
```

On Windows, use Task Scheduler to run a `.ps1` file containing the PowerShell commands above.

## How the script works

1. Connects to Snowflake with `authenticator=PROGRAMMATIC_ACCESS_TOKEN`.
2. Reads the newest `CONNECTION_STRING` from the table.
3. Resolves the runtime's NiFi API URL with `SHOW OPENFLOW RUNTIMES` + `DESCRIBE OPENFLOW RUNTIME` (`server_url`),
   or uses `OPENFLOW_RUNTIME_URL` if you set it.
4. Uses the same PAT as a bearer token against the runtime. It finds the connector process group by name, then
   finds the parameter in the group's parameter context or in any context that one inherits from.
5. Submits a NiFi parameter-context update request. NiFi stops the affected components, applies the value and
   restarts them, and the script reads the value back to confirm it.

## Security notes

- Use the dedicated `TYPE=SERVICE` user. Its PAT is restricted to one role, only accepted from `runner_ip`, and
  expires after `pat_days`. Rotate it with the statements in `sql/02_create_pat.sql`.
- Keep `.env` out of version control (`.gitignore` already does) and prefer a secret manager in production.
- If the connector parameter is marked sensitive, NiFi masks it and the script cannot compare values, so it
  rewrites the parameter on every `--apply`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Object ... does not exist or not authorized` on the SELECT | Missing grants on the table, schema or database (step 3 of `01_setup.sql`) |
| `Incoming request with IP/Token ... is not allowed` / code 390422 | The machine's public IP is not `runner_ip`. Update network rule `URI_SYNC_RUNNER_IPS` |
| `expected 1 runtime ... found 0` | Wrong deployment or runtime name, or the role cannot see the runtime (step 4 of `01_setup.sql`) |
| `HTTP 401` from the runtime | PAT expired or revoked, its `ROLE_RESTRICTION` differs from `SNOWFLAKE_ROLE`, or a network policy blocks the caller's IP |
| `HTTP 403` from the runtime | The role has no permission on the runtime canvas |
| `expected 1 process group ...` | `OPENFLOW_CONNECTOR` must exactly match a process group at the root of the canvas (the error lists the names it found) |
| `parameter ... not found` | Check `OPENFLOW_PARAMETER`; names are case-sensitive |
| `No members resolved for ...` | Wrong `cluster_dns` (use the host from the `mongodb+srv://` string), or `DNS_OVER_HTTPS_EAI` is missing or disabled |
| `no CONNECTION_STRING rows` | `BUILD_MONGODB_CONNECTION_STRING` has not run yet. Run it (see Examples) or wait for the task |
| Task failing | Check the task history query in Examples. The task owner must own `MONGODB_ATLAS_RULE` |
| Connector cannot reach the nodes after a change | `MONGODB_ATLAS_RULE` is not in the runtime's External Access Integration (Part 1, step 4) |
| `No warehouse` / `Cannot perform SELECT` | Set `SNOWFLAKE_WAREHOUSE` or give the service user a default warehouse |
| `ModuleNotFoundError: snowflake` | The virtual environment is not active, or `pip install -r requirements.txt` was not run |
| SSL / certificate errors on a corporate network | TLS inspection proxy. Point `REQUESTS_CA_BUNDLE` and `SSL_CERT_FILE` at your corporate CA bundle |
