# Random regression (`verification/random`)

Seeded random regression for `chi_to_ucie_bridge`. Env: **cocotb + Icarus** (the only env with a randomized,
self-checking scoreboard; `verification/directed` is a fixed-sequence TB and the UVM env is not run here).

Stimulus and checks are the existing cocotb tests in `verification/cocotb/test_bridge.py`
(`test_random_traffic`: random reads/writes, back-pressure, out-of-order completions, QoS, scoreboard + coverage
asserts; `test_random_errors`: corrupted-checksum read completions, DERR/crc counter checks). `rr.py` only re-seeds
them (`TEST_SEED` -> `random.seed`) and runs them in parallel. No checker lives here.

## Contract

| target | what |
|---|---|
| `make rr-build` | build the Icarus sim once into `verification/random/build/` (incremental: also the rebuild after an RTL mutation) |
| `make rr N=20 JOBS=4 [SEED=1]` | N jobs, seeds `SEED+i`, `JOBS` in parallel; writes `runs/<UTC ts>/results.jsonl`; prints `rr run: <dir> seed_base=<s> jobs=<N> fail=<F>`; exit != 0 iff F > 0 |
| `make rr-triage RUN=<dir>` | cluster FAILs by (config, signature): one line each with count + repro |
| `make rr-replay` | rerun every `corpus.json` entry; entries with `"fixed": true` must PASS (gate) |

`results.jsonl` line: `{"job","seed","config","status","signature","log","repro"}`. `runs/` and `build/` are git-ignored.

## Knobs

- `SEED` base seed, `N` jobs, `JOBS` parallelism (make vars).
- `config` = which randomized test a job runs; jobs rotate `test_random_traffic`, `test_random_errors`
  (even job index -> traffic, odd -> errors). The seed drives everything else inside the test (gaps, back-pressure,
  TxnIDs, read/write mix, QoS, completion order, which completions are corrupted).
- `RR_TIMEOUT` per-job wall-clock limit in seconds (default 300). A wedged bench is reported as a FAIL with a
  `Timeout...` signature. Note the tests' own limit is 2 ms of sim time, roughly 90 s wall.

Determinism: a seed replays bit-identically (same coverage counts and sim time in the log; checked for seed 1, 3).

Repro of any job: the `repro` field, e.g.
`make -C verification/cocotb SIM_BUILD=verification/random/build TEST_SEED=1 TESTCASE=test_random_traffic COCOTB_RESULTS_FILE=/tmp/r.xml`.

## Corpus

`corpus.json`: `{"entries": [{"id", "seed", "config", "fixed": bool, "note"}]}`. Empty at bootstrap (no failure found yet).
Pin a fixed failure by adding its seed/config with `"fixed": true` after verifying FAIL on the pre-fix commit and PASS on the fix.

## Stimulus backlog

Randomize only what the scoreboards already check; do one item per branch; keep earlier seeds bit-identical
(add new knobs as opt-in configs, never reorder existing `random` calls).

- B1. Per-job knob set (env `RR_*` read by the cocotb tests): ready probability (currently fixed 0.7), max in-flight (12), N (80).
- B2. Random request mix incl. CMO / atomics / DVM / snoop flows (directed tests exist; no random scoreboard yet).
- B3. Random PHY error injection + retrain mid-traffic (needs a scoreboard that tolerates drain/flush).
- B4. Random sideband messages (PM L1 entry/exit, param exchange) interleaved with traffic.
- B5. Random credit return timing / credit starvation on UCIe TX; FIFO-full pressure (`rdat`/`wdat`/`rsp`).
- B6. Split / multi-beat completions with random beat gaps; poisoned completions.
- B7. Random reset assertion mid-run with the reset_drain checks.
- B8. Port to Verilator (`SIM=verilator`, enables the bound SVA) once the Icarus flow is stable.
