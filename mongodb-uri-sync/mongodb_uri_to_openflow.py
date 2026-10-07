#!/usr/bin/env python3
"""Copy the latest MongoDB connection string from Snowflake into an Openflow connector parameter.

Steps:
  1. Connect to Snowflake with a PAT (programmatic access token).
  2. Read the latest CONNECTION_STRING (by RESOLVED_AT) from the nodes table.
  3. Resolve the runtime's NiFi API URL via SHOW/DESCRIBE OPENFLOW RUNTIME (deployment + runtime name).
  4. Find the connector process group by name, locate the parameter in its parameter
     context (or an inherited one) and update it via a NiFi update-request.

Every option can be given as a flag or as the environment variable shown in --help.
The PAT is only read from the environment (SNOWFLAKE_PAT), never from the command line.

Dry run unless --apply (or SYNC_APPLY=true). The same PAT is used for Snowflake SQL and the
runtime NiFi API, so the PAT's role needs SELECT on the table and USAGE on the Openflow runtime.
"""
import argparse
import os
import sys
import time

import requests
import snowflake.connector

TIMEOUT = 30


def env(name, default=None):
    return os.environ.get(name) or default


def sql_ident(name):
    """Validate a (possibly qualified) identifier: parts are bare words or double-quoted."""
    for part in name.split("."):
        if not (part.replace("_", "").replace("$", "").isalnum() or (part.startswith('"') and part.endswith('"'))):
            sys.exit(f"ERROR: invalid identifier '{name}'")
    return name


def latest_connection_string(cur, table):
    cur.execute(
        f"SELECT CONNECTION_STRING, RESOLVED_AT FROM {sql_ident(table)} "
        "WHERE CONNECTION_STRING IS NOT NULL ORDER BY RESOLVED_AT DESC NULLS LAST LIMIT 1"
    )
    row = cur.fetchone()
    if not row:
        sys.exit(f"ERROR: no CONNECTION_STRING rows in {table}")
    return row


def runtime_api_url(cur, deployment, runtime):
    cur.execute("SHOW OPENFLOW RUNTIMES IN ACCOUNT")
    cols = [c[0] for c in cur.description]
    rows = [dict(zip(cols, r)) for r in cur.fetchall()]
    match = [r for r in rows if r["deployment"].lower() == deployment.lower()
             and runtime.lower() in (r["name"].lower(), (r["display_name"] or "").lower())]
    if len(match) != 1:
        sys.exit(f"ERROR: expected 1 runtime '{runtime}' in deployment '{deployment}', found {len(match)}")
    r = match[0]
    name = r["name"].replace('"', '""')
    cur.execute(f'DESCRIBE OPENFLOW RUNTIME {sql_ident(r["database_name"])}.{sql_ident(r["schema_name"])}."{name}"')
    cols = [c[0] for c in cur.description]
    url = dict(zip(cols, cur.fetchone()))["server_url"]
    url = url.rstrip("/")
    if url.endswith("/nifi"):
        url = url[: -len("/nifi")]
    return url + "/nifi-api"


class Nifi:
    def __init__(self, base, token):
        self.base = base.rstrip("/")
        self.s = requests.Session()
        self.s.headers.update({"Authorization": f"Bearer {token}", "Content-Type": "application/json"})

    def req(self, method, path, **kw):
        r = self.s.request(method, f"{self.base}{path}", timeout=TIMEOUT, **kw)
        if r.status_code >= 400:
            hint = ""
            if r.status_code == 401:
                hint = " (PAT rejected: expired, wrong role, or blocked by a network policy)"
            elif r.status_code == 403:
                hint = " (PAT role lacks permission on the runtime)"
            sys.exit(f"ERROR {method} {path} -> HTTP {r.status_code}{hint}: {r.text[:500]}")
        return r.json() if r.text else {}

    def find_process_group(self, name):
        pgs = self.req("GET", "/flow/process-groups/root")["processGroupFlow"]["flow"]["processGroups"]
        match = [p for p in pgs if p["component"]["name"] == name]
        if len(match) != 1:
            sys.exit(f"ERROR: expected 1 process group '{name}' at root, found {len(match)}: "
                     f"{[p['component']['name'] for p in pgs]}")
        return match[0]

    def find_parameter(self, ctx_id, param, seen=None):
        """Depth-first search through the context and its inherited contexts."""
        seen = seen or set()
        if ctx_id in seen:
            return None
        seen.add(ctx_id)
        ctx = self.req("GET", f"/parameter-contexts/{ctx_id}")
        for p in ctx["component"]["parameters"]:
            if p["parameter"]["name"] == param:
                return ctx, p["parameter"]
        for inherited in ctx["component"].get("inheritedParameterContexts", []):
            hit = self.find_parameter(inherited["id"], param, seen)
            if hit:
                return hit
        return None

    def update_parameter(self, ctx, name, value, sensitive, limit=300):
        cid = ctx["component"]["id"]
        body = {"id": cid, "revision": ctx["revision"], "component": {
            "id": cid, "parameters": [{"parameter": {"name": name, "value": value, "sensitive": sensitive}}]}}
        req = self.req("POST", f"/parameter-contexts/{cid}/update-requests", json=body)["request"]
        rid = req["requestId"]
        deadline = time.time() + limit
        try:
            while not req.get("complete"):
                if time.time() > deadline:
                    sys.exit("ERROR: parameter update timed out")
                time.sleep(2)
                req = self.req("GET", f"/parameter-contexts/{cid}/update-requests/{rid}")["request"]
            if req.get("failureReason"):
                sys.exit(f"ERROR: parameter update failed: {req['failureReason']}")
        finally:
            self.s.delete(f"{self.base}/parameter-contexts/{cid}/update-requests/{rid}", timeout=TIMEOUT)


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--account", default=env("SNOWFLAKE_ACCOUNT"), help="Account identifier (SNOWFLAKE_ACCOUNT)")
    ap.add_argument("--user", default=env("SNOWFLAKE_USER"), help="User owning the PAT (SNOWFLAKE_USER)")
    ap.add_argument("--role", default=env("SNOWFLAKE_ROLE"), help="Role, must match the PAT role restriction (SNOWFLAKE_ROLE)")
    ap.add_argument("--warehouse", default=env("SNOWFLAKE_WAREHOUSE"), help="Warehouse for the SELECT (SNOWFLAKE_WAREHOUSE)")
    ap.add_argument("--table", default=env("SYNC_TABLE"), help="Fully qualified nodes table (SYNC_TABLE)")
    ap.add_argument("--deployment", default=env("OPENFLOW_DEPLOYMENT"), help="Openflow deployment name (OPENFLOW_DEPLOYMENT)")
    ap.add_argument("--runtime", default=env("OPENFLOW_RUNTIME"), help="Runtime name or display name (OPENFLOW_RUNTIME)")
    ap.add_argument("--connector", default=env("OPENFLOW_CONNECTOR"), help="Connector process group name, exact match (OPENFLOW_CONNECTOR)")
    ap.add_argument("--parameter", default=env("OPENFLOW_PARAMETER", "MongoDB Connection URI"),
                    help="Parameter name (OPENFLOW_PARAMETER, default 'MongoDB Connection URI')")
    ap.add_argument("--runtime-url", default=env("OPENFLOW_RUNTIME_URL"),
                    help="NiFi API URL override, skips runtime lookup (OPENFLOW_RUNTIME_URL)")
    ap.add_argument("--apply", action="store_true", default=env("SYNC_APPLY", "").lower() == "true",
                    help="Write the parameter; default is dry run (SYNC_APPLY=true)")
    args = ap.parse_args()

    required = ["account", "user", "table", "connector"]
    if not args.runtime_url:
        required += ["deployment", "runtime"]
    missing = [r for r in required if not getattr(args, r)]
    if missing:
        ap.error("missing required settings: " + ", ".join(missing))
    return args


def main():
    args = parse_args()
    token = os.environ.get("SNOWFLAKE_PAT")
    if not token:
        sys.exit("ERROR: SNOWFLAKE_PAT is not set")

    conn = snowflake.connector.connect(
        account=args.account, user=args.user, authenticator="PROGRAMMATIC_ACCESS_TOKEN", token=token,
        role=args.role, warehouse=args.warehouse)
    try:
        cur = conn.cursor()
        uri, resolved_at = latest_connection_string(cur, args.table)
        print(f"Latest connection string from {args.table} (RESOLVED_AT {resolved_at})")
        api = args.runtime_url or runtime_api_url(cur, args.deployment, args.runtime)
    finally:
        conn.close()
    print(f"Runtime API: {api}")

    nifi = Nifi(api, token)
    print("Authenticated as", nifi.req("GET", "/flow/current-user")["identity"])
    pg = nifi.find_process_group(args.connector)
    pctx = pg["component"].get("parameterContext")
    if not pctx:
        sys.exit(f"ERROR: process group '{args.connector}' has no parameter context")
    hit = nifi.find_parameter(pctx["id"], args.parameter)
    if not hit:
        sys.exit(f"ERROR: parameter '{args.parameter}' not found in context tree of '{args.connector}'")
    ctx, param = hit
    sensitive = bool(param.get("sensitive"))
    print(f"Parameter '{args.parameter}' lives in context '{ctx['component']['name']}' (sensitive={sensitive})")

    if not sensitive and param.get("value") == uri:
        print("Already up to date. Nothing to do.")
        return
    if not args.apply:
        print("Dry run. Re-run with --apply to write the parameter.")
        return

    nifi.update_parameter(ctx, args.parameter, uri, sensitive)
    _, after = nifi.find_parameter(pctx["id"], args.parameter)
    if not sensitive and after.get("value") != uri:
        sys.exit("ERROR: post-check failed, value on runtime differs")
    print("Parameter updated.")


if __name__ == "__main__":
    main()
