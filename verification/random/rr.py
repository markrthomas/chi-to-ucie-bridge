#!/usr/bin/env python3
"""Random regression driver for chi_to_ucie_bridge (cocotb + Icarus, self-checking scoreboards).

Stimulus is the existing cocotb tests test_random_traffic / test_random_errors in
verification/cocotb/test_bridge.py, re-seeded per job via TEST_SEED (random.seed in the test).
No new checker: the tests' scoreboards and final asserts are the contract.

  rr.py build
  rr.py run [--n N] [--jobs J] [--seed S]
  rr.py triage RUN_DIR
  rr.py replay
"""
import argparse, collections, concurrent.futures as cf, datetime, json, os, re, signal, subprocess, sys

TIMEOUT = int(os.environ.get("RR_TIMEOUT", "300"))  # per-job wall-clock seconds (normal job: ~1 s)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
COCOTB = os.path.join(ROOT, "verification", "cocotb")
BUILD = os.path.join(HERE, "build")
CORPUS = os.path.join(HERE, "corpus.json")
# the "config" knob: which randomized cocotb test a job runs; jobs rotate through these
CONFIGS = ["test_random_traffic", "test_random_errors"]


def build():
    """Incremental (make tracks RTL deps), so it is also the rebuild after an RTL mutation."""
    os.makedirs(BUILD, exist_ok=True)
    r = subprocess.run(["make", "-C", COCOTB, "SIM_BUILD=" + BUILD, BUILD + "/sim.vvp"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stdout.write((r.stdout + r.stderr)[-3000:])
        return 1
    print("rr-build: " + BUILD + "/sim.vvp")
    return 0


def rel(p):
    return os.path.relpath(p, ROOT)


def repro_cmd(seed, config, res):
    return ("make -C %s SIM_BUILD=%s TEST_SEED=%d TESTCASE=%s COCOTB_RESULTS_FILE=%s"
            % (rel(COCOTB), rel(BUILD), seed, config, res))


def signature(txt):
    # scoreboard asserts print "errors:" and then the first error on the next line: use that line
    m = re.search(r"AssertionError: (?:scoreboard )?errors:\s*\n\s*([^\n]+)", txt)
    if m:
        return re.sub(r"0x[0-9A-Fa-f]+|\d+", "N", "errors: " + m.group(1).strip())[:120]
    for pat in (r"AssertionError: ([^\n]*)", r"(Timeout[^\n]*|[^\n]*timed out[^\n]*)"):
        m = re.search(pat, txt)
        if m:
            return re.sub(r"0x[0-9A-Fa-f]+|\d+", "N", m.group(1).strip())[:120]
    return "unclassified-fail"


def run_job(i, seed, config, outdir):
    log = os.path.join(outdir, "job%s_seed%d.log" % (i, seed))
    res = os.path.join(outdir, "job%s_seed%d.xml" % (i, seed))
    env = dict(os.environ, TEST_SEED=str(seed), TESTCASE=config, COCOTB_RESULTS_FILE=res)
    # wall-clock limit: a DUT bug can wedge a testbench coroutine; that is a FAIL, not a hang
    proc = subprocess.Popen(["make", "-C", COCOTB, "SIM_BUILD=" + BUILD], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        txt, _ = proc.communicate(timeout=TIMEOUT)
        timed_out = False
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        txt, _ = proc.communicate()
        txt = (txt or "") + "\nTimeout: job exceeded %ds wall clock (testbench hang)\n" % TIMEOUT
        timed_out = True
    with open(log, "w") as f:
        f.write(txt)

    class p:  # noqa: N801 - tiny result holder
        returncode = 1 if timed_out else proc.returncode
    ok = p.returncode == 0 and re.search(r"FAIL=0", txt) and re.search(r"PASS=[1-9]", txt)
    return {"job": i, "seed": seed, "config": config, "status": "PASS" if ok else "FAIL",
            "signature": "" if ok else signature(txt),
            "log": rel(log), "repro": repro_cmd(seed, config, rel(res))}


def run(n, jobs, seed):
    if build():
        return 1
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    outdir = os.path.join(HERE, "runs", ts)
    os.makedirs(outdir, exist_ok=True)
    with cf.ThreadPoolExecutor(max_workers=max(1, jobs)) as ex:
        futs = [ex.submit(run_job, i, seed + i, CONFIGS[i % len(CONFIGS)], outdir) for i in range(n)]
        rows = [f.result() for f in futs]
    with open(os.path.join(outdir, "results.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    fails = sum(r["status"] == "FAIL" for r in rows)
    print("rr run: %s seed_base=%d jobs=%d fail=%d" % (rel(outdir), seed, n, fails))
    return 1 if fails else 0


def triage(d):
    rows = [json.loads(l) for l in open(os.path.join(d, "results.jsonl")) if l.strip()]
    cl = collections.OrderedDict()
    for r in rows:
        if r["status"] == "FAIL":
            cl.setdefault((r["config"], r["signature"]), []).append(r)
    for (cfg, sig), rs in cl.items():
        print("cluster count=%d config=%s signature=%r repro: %s" % (len(rs), cfg, sig, rs[0]["repro"]))
    print("rr triage: %d cluster(s), %d fail(s) of %d jobs"
          % (len(cl), sum(len(v) for v in cl.values()), len(rows)))
    return 0


def replay():
    entries = json.load(open(CORPUS)).get("entries", [])
    if build():
        return 1
    outdir = os.path.join(HERE, "runs", "replay")
    os.makedirs(outdir, exist_ok=True)
    bad = 0
    for k, e in enumerate(entries):
        r = run_job("c%d" % k, e["seed"], e["config"], outdir)
        fixed = e.get("fixed", False)
        ok = r["status"] == "PASS" or not fixed
        print("replay %s seed=%d config=%s fixed=%s -> %s%s"
              % (e.get("id", k), e["seed"], e["config"], fixed, r["status"], "" if ok else "  <-- REGRESSION"))
        bad += not ok
    print("rr replay: entries=%d bad=%d" % (len(entries), bad))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="c", required=True)
    sp.add_parser("build")
    r = sp.add_parser("run")
    r.add_argument("--n", type=int, default=20)
    r.add_argument("--jobs", type=int, default=4)
    r.add_argument("--seed", type=int, default=1)
    t = sp.add_parser("triage")
    t.add_argument("dir")
    sp.add_parser("replay")
    a = ap.parse_args()
    if a.c == "build":
        return build()
    if a.c == "run":
        return run(a.n, a.jobs, a.seed)
    if a.c == "triage":
        return triage(a.dir)
    return replay()


if __name__ == "__main__":
    sys.exit(main())
