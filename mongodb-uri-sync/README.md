# mongodb-uri-sync

Keeps an Openflow MongoDB connector pointed at the right MongoDB cluster. The script reads the most recent
`CONNECTION_STRING` from a Snowflake table and writes it to a connector parameter
(default `MongoDB Connection URI`).

```
Snowflake table ──(PAT, SQL)──▶ mongodb_uri_to_openflow.py ──(PAT, NiFi REST)──▶ Openflow runtime / connector parameter
```

> Sample code provided as-is, without warranty or official Snowflake support. Review and test before production use.

## Contents

| File | Purpose |
|---|---|
| `mongodb_uri_to_openflow.py` | The sync script (dry run by default) |
| `requirements.txt` | Python dependencies |
| `config.example.env` | All settings, copy to `.env` |
| `sql/01_setup.sql` | Role, service user, table, grants, network policy |
| `sql/02_create_pat.sql` | Creates / rotates the PAT |

## Prerequisites

- An Openflow deployment with a runtime that has the MongoDB connector added to its canvas.
- Python 3.9+.
- `ACCOUNTADMIN` (or equivalent) for the one-time setup.
- The table `MONGODB_CLUSTER_NODES` is populated by your own process (a discovery job, ETL, or manual insert).
  The script only reads it. The newest row by `RESOLVED_AT` that has a non-null `CONNECTION_STRING` wins.

## Setup

1. **Snowflake objects**: replace the placeholders in `sql/01_setup.sql` and run it.
2. **PAT**: run `sql/02_create_pat.sql` and copy `token_secret`. Snowflake shows it only once.
3. **Config**:
   ```bash
   cp config.example.env .env      # fill in values, put the PAT in SNOWFLAKE_PAT
   ```
   The values for `OPENFLOW_DEPLOYMENT` and `OPENFLOW_RUNTIME` are the `deployment` and `name` (or `display_name`)
   columns of `SHOW OPENFLOW RUNTIMES IN ACCOUNT`. `OPENFLOW_CONNECTOR` is the exact name of the connector's
   process group on the runtime canvas.
4. **Install**:
   ```bash
   python3 -m venv .venv && . .venv/bin/activate
   pip install -r requirements.txt
   ```

## Run

```bash
set -a; . ./.env; set +a
python mongodb_uri_to_openflow.py            # dry run: shows what would change
python mongodb_uri_to_openflow.py --apply    # writes the parameter
```

Every setting can also be passed as a flag (`--account`, `--user`, `--role`, `--warehouse`, `--table`,
`--deployment`, `--runtime`, `--connector`, `--parameter`, `--runtime-url`). Run `--help` for the full list.
The PAT is read only from `SNOWFLAKE_PAT`, so it never appears in your shell history or process list.

Example output:
```
Latest connection string from ANALYTICS.MONGODB.MONGODB_CLUSTER_NODES (RESOLVED_AT 2026-10-07 09:12:00+02:00)
Runtime API: https://of2--myorg-myacct.snowflakecomputing.app:443/demo-100/nifi-api
Authenticated as SVC_OPENFLOW_URI_SYNC
Parameter 'MongoDB Connection URI' lives in context 'MongoDB Source Parameters' (sensitive=False)
Parameter updated.
```

## Scheduling

The script is idempotent: if the runtime already has the value, it changes nothing. Schedule it with whatever
scheduler you already use, for example cron:

```cron
*/15 * * * * cd /opt/mongodb-uri-sync && set -a && . ./.env && set +a && .venv/bin/python mongodb_uri_to_openflow.py --apply >> sync.log 2>&1
```

Windows Task Scheduler, systemd timers or an Airflow task work the same way.

## How it works

1. Connects to Snowflake with `authenticator=PROGRAMMATIC_ACCESS_TOKEN`.
2. Reads the newest `CONNECTION_STRING` from the table.
3. Resolves the runtime's NiFi API URL with `SHOW OPENFLOW RUNTIMES` + `DESCRIBE OPENFLOW RUNTIME` (`server_url`),
   or uses `OPENFLOW_RUNTIME_URL` if you set it.
4. Uses the same PAT as a bearer token against the runtime. It finds the connector process group by name, then
   finds the parameter in the group's parameter context or in any context that one inherits from.
5. Submits a NiFi parameter-context update request. NiFi stops the affected components, applies the value and
   restarts them, and the script reads the value back to confirm it.

## Security notes

- Use the dedicated `TYPE=SERVICE` user. Its PAT is restricted to one role and expires after 90 days.
  Rotate it with the statement in `sql/02_create_pat.sql`.
- Keep `.env` out of version control (`.gitignore` already does) and prefer a secret manager in production.
- The connection string can contain credentials. If the connector parameter is marked sensitive, NiFi masks it,
  and the script then cannot compare values, so it rewrites the parameter on every `--apply`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Object ... does not exist or not authorized` on the SELECT | Missing grants on the table, schema or database (step 3 of `01_setup.sql`) |
| `expected 1 runtime ... found 0` | Wrong deployment or runtime name, or the role cannot see the runtime (step 4) |
| `HTTP 401` from the runtime | PAT expired or revoked, its `ROLE_RESTRICTION` differs from `SNOWFLAKE_ROLE`, or a network policy blocks the caller's IP |
| `HTTP 403` from the runtime | The role has no permission on the runtime canvas |
| `expected 1 process group ...` | `OPENFLOW_CONNECTOR` must exactly match a process group at the root of the canvas (the error lists the names it found) |
| `parameter ... not found` | Check `OPENFLOW_PARAMETER`; names are case-sensitive |
| `No warehouse` / `Cannot perform SELECT` | Set `SNOWFLAKE_WAREHOUSE` or give the service user a default warehouse |
