"""Regulator configuration + run driver. Executed inside the control-plane pod.

Environment-agnostic: nothing here is specific to any one estate.

Subcommands:
  configure                          verify the seeded target, list scenarios
  mint-token [--name N] [--user U]   mint a Splunk JWT and make a target from it
  add-target --name N [--username U --password P | --token T]
  run <scenario> [opts]              launch a run
  results <run_id> | ls | stop <run_id>

Run options: --users N --duration S --workers N --fleet NAME --target NAME --wait

Why mint-token exists: a Splunk auth token cannot be created before Splunk
exists, so it cannot be baked into Terraform env at deploy time. This mints one
AFTER the sok layer is up and wires it into a Regulator target in one step.

Prefer a token over username/password on a SEARCH HEAD CLUSTER. A Splunk session
key is only valid on the member that issued it and is not replicated, so through
a load-balanced endpoint a worker logs in on one member and is then rejected by
another. That surfaces as "rejected with HTTP 401 after re-authenticating"
partway into a run, often minutes in, once keep-alive stops pinning the
connection to one member. A JWT is validated against a shared secret and is
accepted by any member.
"""

import base64
import json
import os
import ssl
import sys
import time
import http.cookiejar
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("SOK_REGULATOR_URL", "http://127.0.0.1:8080")
USER = os.environ.get("REG_ADMIN_USER", "admin")
PASS = os.environ.get("REG_ADMIN_PASSWORD", "password")
MGMT_URL = os.environ.get("SOK_REG_MGMT_URL", "")
SPLUNK_USER = os.environ.get("SOK_SPLUNK_USER", "admin")
SPLUNK_PW = os.environ.get("SOK_SPLUNK_PASSWORD", "")
TARGET = os.environ.get("SOK_REG_TARGET_NAME", "splunk-local")

_opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))


def call(path, data=None, method=None, timeout=180):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(data).encode() if data is not None else None,
        headers={"Content-Type": "application/json"}, method=method)
    try:
        return json.loads(_opener.open(req, timeout=timeout).read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        raise SystemExit("HTTP %s on %s: %s" % (exc.code, path, exc.read().decode()[:400]))


def login():
    call("/api/auth/login", {"username": USER, "password": PASS})


def opt(args, flag, default=None, cast=str):
    if flag in args:
        return cast(args[args.index(flag) + 1])
    return default


def target_named(name):
    return next((t for t in call("/api/targets") if t["name"] == name), None)


def configure():
    login()
    target = target_named(TARGET)

    if target is None:
        if not MGMT_URL:
            raise SystemExit(
                "no target %r and no SOK_REG_MGMT_URL to create one.\n"
                "Regulator normally seeds this from REG_SEED_TARGET_URL; if that\n"
                "is unset or wrong, pass SOK_REG_MGMT_URL (and SOK_SPLUNK_PASSWORD)."
                % TARGET)
        body = {"name": TARGET, "mgmt_url": MGMT_URL, "verify_tls": False,
                "username": SPLUNK_USER}
        if SPLUNK_PW:
            body["password"] = SPLUNK_PW
        target = call("/api/targets", body)
        print("created target %s -> %s" % (TARGET, MGMT_URL))
    else:
        print("target %s already present (id %s) -> %s"
              % (TARGET, target["id"], target.get("mgmt_url")))

    probe = call("/api/targets/%s/test" % target["id"], {}, timeout=120)
    if probe.get("ok"):
        print("  reachable: %s" % probe.get("detail"))
        print("  cores=%s max_concurrent_searches=%s"
              % (probe.get("cores"), probe.get("max_hist_searches")))
        roles = probe.get("roles") or []
        if any("cluster_search_head" in r or "shc" in r for r in roles):
            print("  NOTE: this looks like a search head CLUSTER. Use a token,")
            print("        not username/password: session keys are per-member and")
            print("        a load-balanced run gets 401s once keep-alive churns.")
            print("        Run:  mint-token")
    else:
        print("  *** NOT reachable: %s ***" % probe.get("detail"))

    scenarios = call("/api/scenarios")
    items = scenarios if isinstance(scenarios, list) else scenarios.get("items", [])
    by_engine = {}
    for s in items:
        by_engine.setdefault(s.get("engine") or "?", []).append(s.get("name"))
    print("  scenarios available:")
    for engine, names in sorted(by_engine.items()):
        print("    %-8s %d  e.g. %s" % (engine, len(names), ", ".join(sorted(names)[:3])))
    print("\nRegulator needs no spec objects: a run names its scenario directly.")
    print("Note it validates the scenario's sourcetypes against the target first;")
    print("a scenario whose data is absent is refused rather than run empty.")


def mint_token(args):
    """Create a Splunk JWT on the search head, then a Regulator target using it."""
    login()
    name = opt(args, "--name", "splunk-token")
    splunk_user = opt(args, "--user", SPLUNK_USER)
    expires = opt(args, "--expires", "+30d")

    src = target_named(TARGET)
    mgmt = MGMT_URL or (src or {}).get("mgmt_url")
    if not mgmt:
        raise SystemExit("no management URL: set SOK_REG_MGMT_URL, or configure first")
    if not SPLUNK_PW:
        raise SystemExit("need the Splunk password to mint a token (SOK_SPLUNK_PASSWORD)")
    if target_named(name):
        raise SystemExit(
            "target %r already exists; remove it first if you want a fresh token" % name)

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    body = urllib.parse.urlencode({
        "name": splunk_user, "audience": "regulator",
        "expires_on": expires, "output_mode": "json"}).encode()
    basic = base64.b64encode(("%s:%s" % (splunk_user, SPLUNK_PW)).encode()).decode()
    req = urllib.request.Request(
        mgmt.rstrip("/") + "/services/authorization/tokens",
        data=body, headers={"Authorization": "Basic " + basic})
    try:
        raw = urllib.request.urlopen(req, timeout=60, context=ctx).read().decode()
    except urllib.error.HTTPError as exc:
        raise SystemExit(
            "minting a token failed with HTTP %s: %s\n"
            "If that mentions token auth being disabled, enable it in Splunk "
            "first (Settings -> Tokens -> Enable Token Authentication)."
            % (exc.code, exc.read().decode()[:300]))

    token = (json.loads(raw).get("entry") or [{}])[0].get("content", {}).get("token")
    if not token:
        raise SystemExit("Splunk returned no token: %s" % raw[:300])

    created = call("/api/targets", {
        "name": name, "mgmt_url": mgmt, "token": token, "verify_tls": False})
    print("minted a JWT for %r, created target %s (id %s)"
          % (splunk_user, name, created["id"]))
    probe = call("/api/targets/%s/test" % created["id"], {}, timeout=120)
    print("  probe: ok=%s %s" % (probe.get("ok"), probe.get("detail")))
    print("  use it with:  run <scenario> --target %s" % name)


def add_target(args):
    """Create an extra target with explicit credentials, for capability testing."""
    login()
    name = opt(args, "--name")
    if not name:
        raise SystemExit("--name is required")
    src = target_named(TARGET)
    mgmt = opt(args, "--mgmt-url", MGMT_URL or (src or {}).get("mgmt_url"))
    if not mgmt:
        raise SystemExit("no management URL: pass --mgmt-url")
    body = {"name": name, "mgmt_url": mgmt, "verify_tls": False}
    if opt(args, "--token"):
        body["token"] = opt(args, "--token")
    else:
        body["username"] = opt(args, "--username", SPLUNK_USER)
        pw = opt(args, "--password", SPLUNK_PW)
        if not pw:
            raise SystemExit("--password is required unless --token is given")
        body["password"] = pw
    created = call("/api/targets", body)
    print("created target %s (id %s)" % (name, created["id"]))
    probe = call("/api/targets/%s/test" % created["id"], {}, timeout=120)
    print("  probe: ok=%s %s" % (probe.get("ok"), probe.get("detail")))


def report(run_id):
    r = call("/api/runs/%s" % run_id)
    print("run %s  state=%s fleet=%s scenario=%s"
          % (run_id, r.get("state"), r.get("fleet"), r.get("scenario")))
    print("  workers=%s virtual_users=%s fleet_state=%s"
          % (r.get("workers"), r.get("virtual_users"), r.get("fleet_state")))
    summary = r.get("summary") or {}
    if summary.get("valid") is False:
        print("  *** INVALID: %s ***" % str(summary.get("invalid_reason"))[:300])
    stats = r.get("stats") or {}
    for k in ("executions", "errors", "error_rate_pct", "rps"):
        if stats.get(k) is not None:
            print("  %-16s %s" % (k, stats[k]))
    lat = stats.get("latency") or {}
    if lat:
        # ttfr_ms is time to FIRST RESULT, which is what a user actually feels;
        # total is the whole search. On a wide cluster they diverge a lot.
        print("  latency p50/p95/p99 ms: %s / %s / %s"
              % (lat.get("p50_ms"), lat.get("p95_ms"), lat.get("p99_ms")))
    if r.get("state") in ("completed", "stopped") and not stats.get("executions"):
        print("  *** WARNING: no executions recorded. This run is NOT a result. ***")
    return r


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    cmd = args[0]

    if cmd == "configure":
        configure(); return
    if cmd == "mint-token":
        mint_token(args); return
    if cmd == "add-target":
        add_target(args); return

    login()

    if cmd == "run":
        want = opt(args, "--target", TARGET)
        target = target_named(want)
        if target is None:
            raise SystemExit("no target named %r (see `ls`)" % want)
        body = {"target_id": target["id"], "scenario": args[1],
                "virtual_users": opt(args, "--users", 10, int),
                "duration_s": opt(args, "--duration", 180, float),
                "fleet": opt(args, "--fleet", os.environ.get("SOK_FLEET", "k8s"))}
        workers = opt(args, "--workers", None, int)
        if workers:
            body["workers"] = workers
        rid = call("/api/runs", body)["id"]
        print("launched run %s (%s on target %s)" % (rid, args[1], target["name"]))
        if "--wait" in args:
            while True:
                time.sleep(15)
                st = call("/api/runs/%s" % rid).get("state")
                if st in ("completed", "stopped", "failed", "error"):
                    break
                print("  ...%s" % st)
            report(rid)
    elif cmd == "results":
        report(args[1])
    elif cmd == "stop":
        call("/api/runs/%s/stop" % args[1], {})
        print("stop requested for run %s" % args[1])
    elif cmd == "ls":
        print("targets:", [(t["id"], t["name"], t.get("health")) for t in call("/api/targets")])
        print("fleets: ", [(f["kind"], f.get("available")) for f in call("/api/fleets")])
        runs = call("/api/runs")
        runs = runs if isinstance(runs, list) else runs.get("items", [])
        print("runs:   ", [(r.get("id"), r.get("state")) for r in runs[:8]])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
