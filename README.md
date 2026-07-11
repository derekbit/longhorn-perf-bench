# Longhorn Performance Benchmark

fio-based benchmark suite comparing Longhorn v1 and v2 data engine volumes
(1 replica, 1 cross-node replica, and 3 replicas), across a range of v2
data-engine CPU masks. Optionally also benchmarks the local-path provisioner
as a baseline.

## Usage

```sh
./run.sh reset          # Reset the cluster to its default state
./run.sh run v1          # Benchmark Longhorn v1 data engine
./run.sh run v2          # Benchmark Longhorn v2 data engine
./run.sh run all         # Benchmark both v1 and v2
./run.sh report          # Regenerate results/report.html only
```

Set `RUN_BASELINE=true` in run.sh to also install local-path-provisioner and
benchmark it as a baseline on every `run` (default: `false`).

Every `run` is fully automated end-to-end (cluster setup, fio execution,
result parsing, and report generation) and finishes by regenerating
`results/report.html` - a single self-contained HTML file (tables + bar
charts, no external dependencies) that can be opened directly in a browser.
Raw numbers are kept in `results/results.csv`, and per-test fio logs are
saved under `results/logs/`.

Charts are rendered with matplotlib (as inline SVG) if it's installed
(`pip install -r requirements.txt`); otherwise `generate_report.py`
automatically falls back to a small dependency-free SVG renderer, so the
report always regenerates with zero manual steps either way.

`fio.yaml`'s `nodeSelector` is patched automatically on every run (never
edit it by hand). By default the fio pod runs on `NODES[0]`; change
`FIO_NODE_INDEX` in run.sh to use a different node (e.g. `FIO_NODE_INDEX=2`
to run fio on the third node instead). The "cross-node replica" scenarios
automatically place the replica's disk on the *next* node in `NODES`
(wrapping around), e.g. volume on node 0 -> replica on node 1; volume on
node 2 -> replica on node 0.

`storageclass/*.yaml`'s `parameters.shareManagerNodeSelector` is likewise
patched automatically to pin each Longhorn StorageClass's share-manager to
`SHARE_MANAGER_POD_NODE` (default `NODES[0]`, independent of `FIO_NODE_INDEX`
- change `SHARE_MANAGER_POD_NODE_INDEX` in run.sh to use a different node),
before the storage classes are (re)applied on every run.

The fio PVC's `accessModes` is also configurable via `FIO_ACCESS_MODE` in
run.sh (default `ReadWriteOnce`; only Longhorn v1 StorageClasses support
`ReadWriteMany`).

## Project layout

```
run.sh                  Config + CLI entry point (reset|run|report)
lib/log.sh              Logging helpers + generic retry/poll utilities
lib/k8s.sh               Longhorn/Kubernetes control-plane helpers
                          (data engines, node disks, node scheduling)
lib/fio.sh               fio job templating, execution, result parsing,
                          and CSV recording
lib/benchmarks.sh        Benchmark scenarios (baseline, v1, v2) + orchestration
generate_report.py        Renders results/results.csv into results/report.html
                          (matplotlib SVG charts if installed, otherwise a
                          built-in dependency-free SVG renderer)
requirements.txt          Optional: matplotlib, for nicer charts
fio.yaml                  fio Job/PVC template (patched per-run by lib/fio.sh)
storageclass/             Longhorn StorageClass manifests for each scenario
local-path-storage.yaml   local-path-provisioner manifest (used as baseline)
```

Re-running `run.sh run <engine>` updates (rather than duplicates) matching
rows in `results/results.csv`, so you can re-run individual engines/CPU
masks at any time and the report will always reflect the latest numbers.