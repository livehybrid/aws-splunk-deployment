"""Stoker configuration + run driver. Executed inside the control-plane pod.

Environment-agnostic: the HEC endpoint, token and index arrive as environment
variables from sok-bootstrap-common.sh, which discovers them from the cluster.
Nothing here is specific to any one estate.

Subcommands: configure | run <spec> [--wait] | results <run_id> | ls | stop <run_id>
"""

import json
import os
import sys
import time
import http.cookiejar
import urllib.error
import urllib.request

BASE = os.environ.get("SOK_STOKER_URL", "http://127.0.0.1:8080")
USER = os.environ.get("STOKER_ADMIN_USER", "admin")
PASS = os.environ.get("STOKER_ADMIN_PASSWORD", "password")
HEC_URL = os.environ["SOK_HEC_URL"]
HEC_TOKEN = os.environ["SOK_HEC_TOKEN"]
INDEX = os.environ.get("SOK_INDEX", "main")
TARGET = os.environ.get("SOK_TARGET_NAME", "sok-hec")
FLEET = os.environ.get("SOK_FLEET", "k8s-local")

# The standard load set. Addressed by NAME everywhere, because ids shift each
# time the control plane's database is recreated.
SPECS = [
    {"name": "smoke-eventgen", "pack": "web-access", "engine": "eventgen",
     "rate_mode": "eps", "rate_value": 1000, "workers": 1, "duration_s": 90},
    {"name": "eventgen-20k-5w", "pack": "web-access", "engine": "eventgen",
     "rate_mode": "eps", "rate_value": 20000, "workers": 5, "duration_s": 180},
    {"name": "eventgen-1w-ceiling", "pack": "web-access", "engine": "eventgen",
     "rate_mode": "eps", "rate_value": 20000, "workers": 1, "duration_s": 120},
    # rawreplay is single-worker by design; the submit gate rejects more.
    {"name": "rawreplay-attack", "pack": "attack-replay", "engine": "rawreplay",
     "rate_mode": "eps", "rate_value": 200, "workers": 1, "duration_s": 180},
]

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


def configure():
    call("/api/auth/login", {"username": USER, "password": PASS})

    target_id = None
    for t in call("/api/targets"):
        if t["name"] == TARGET:
            target_id = t["id"]
            break
    if target_id is None:
        target_id = call("/api/targets", {
            "name": TARGET, "hec_url": HEC_URL, "token": HEC_TOKEN,
            "default_index": INDEX, "env_tag": "lab", "verify_tls": False})["id"]
        print("created target %s -> %s" % (TARGET, HEC_URL))
    else:
        print("target %s already present (id %s)" % (TARGET, target_id))

    health = call("/api/targets/%s/test" % target_id, {}, timeout=120)
    print("  health=%s auth=%s latency=%sms"
          % (health.get("health"), health.get("auth"), health.get("latency_ms")))
    if health.get("health") != "up":
        print("  *** target is not up; runs will be refused at submit ***")

    packs = {p["name"]: p["id"] for p in call("/api/packs")}
    existing = {s["name"]: s["id"] for s in call("/api/specs")}
    for spec in SPECS:
        if spec["name"] in existing:
            print("  spec %-22s id=%s (existing)" % (spec["name"], existing[spec["name"]]))
            continue
        pid = packs.get(spec["pack"])
        if pid is None:
            print("  spec %-22s SKIPPED: pack %r not registered"
                  % (spec["name"], spec["pack"]))
            continue
        body = {k: v for k, v in spec.items() if k != "pack"}
        body.update({"pack_id": pid, "target_id": target_id, "fleet": FLEET})
        print("  spec %-22s id=%s (created)" % (spec["name"], call("/api/specs", body)["id"]))


def resolve(which):
    if str(which).isdigit():
        return int(which)
    for s in call("/api/specs"):
        if s["name"] == which:
            return s["id"]
    raise SystemExit("no spec named %r (run `configure` first)" % which)


def report(run_id):
    r = call("/api/runs/%s" % run_id)
    t = r.get("totals_json") or {}
    ev = t.get("events_total") or 0
    secs = None
    if r.get("t0") and r.get("ended_at"):
        try:
            f = "%Y-%m-%dT%H:%M:%S"
            secs = time.mktime(time.strptime(r["ended_at"][:19], f)) - \
                   time.mktime(time.strptime(r["t0"][:19], f))
        except ValueError:
            pass
    print("run %s  state=%s degraded=%s reason=%s"
          % (run_id, r.get("state"), r.get("degraded"), r.get("end_reason")))
    print("  events=%s bytes=%s" % (ev, t.get("bytes_total")))
    print("  hec 2xx=%s 4xx=%s 5xx=%s timeouts=%s dropped=%s"
          % (t.get("hec_2xx"), t.get("hec_4xx"), t.get("hec_5xx"),
             t.get("hec_timeouts"), t.get("dropped")))
    if secs:
        print("  window=%.0fs  ACHIEVED %.0f eps" % (secs, ev / secs))
    # Stoker reports a run that sent nothing as completed/not-degraded, so the
    # harness has to be the thing that says so. Until that is fixed upstream,
    # this line is the difference between a wrong number and a caught failure.
    if r.get("state") in ("completed", "stopped") and not ev:
        print("  *** WARNING: ZERO events delivered. This run is NOT a result. ***")
    for l in (r.get("leases") or []):
        print("  slot %s %s restarts=%s"
              % (l.get("slot"), l.get("state"), l.get("restarts")))
    return r


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    cmd = args[0]

    if cmd == "configure":
        configure()
        return

    call("/api/auth/login", {"username": USER, "password": PASS})

    if cmd == "run":
        rid = call("/api/specs/%s/run" % resolve(args[1]), {})["run_id"]
        print("launched run %s" % rid)
        if "--wait" in args:
            while True:
                time.sleep(15)
                st = call("/api/runs/%s" % rid).get("state")
                if st in ("completed", "stopped", "failed"):
                    break
                print("  ...%s" % st)
            report(rid)
    elif cmd == "results":
        report(args[1])
    elif cmd == "stop":
        call("/api/runs/%s/stop" % args[1], {})
        print("stop requested for run %s" % args[1])
    elif cmd == "ls":
        print("targets:", [(t["id"], t["name"], t.get("health_state")) for t in call("/api/targets")])
        print("specs:  ", [(s["id"], s["name"]) for s in call("/api/specs")])
        print("runs:   ", [(r["id"], r["state"]) for r in call("/api/runs")[:8]])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
