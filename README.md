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
result parsing, and report generation) and finishes by regenerating three
artifacts under `results/`:

- `results.csv` - raw numbers (re-runs update rows, never duplicate them)
- `report.html` - self-contained HTML report with summary tables and 6
  bar charts (Read/Write IOPS in `k`, Read/Write Throughput in `MiB/s`,
  Read/Write Latency in `µs`). Open directly in a browser.
- `results.md` - markdown-friendly summary tables (embeds HTML for the
  two-level headers, renders correctly on GitHub / VS Code preview).

Per-test fio logs are kept under `results/logs/`.

Charts are rendered with matplotlib (as inline SVG) if it's installed
(`pip install -r requirements.txt`); otherwise `generate_report.py`
automatically falls back to a small dependency-free SVG renderer, so the
report always regenerates with zero manual steps either way.

v2 volumes are benchmarked against **both** SPDK bdev backends, driven by
two separate per-node disk arrays in run.sh:

- `NVME_BDEV_DISKS` - PCI BDF paths (e.g. `0000:00:0b.0`) - runs first, as
  NVMe bdev. Labeled `v2 volume (NVMe-OF frontend, NVMe bdev, ...)`.
- `AIO_BDEV_DISKS` - block device paths (e.g. `/dev/nvme3n1`) - runs next,
  as AIO bdev. Labeled `v2 volume (NVMe-OF frontend, AIO bdev, ...)`.

Set either array to `()` to skip that backend. Each backend runs the full
`CPU_MASKS x {1 replica, 1 cross-node replica, 3 replicas}` matrix.

v1 volumes use filesystem disks configured via `FILESYSTEM_DISKS` in run.sh
(default `/mnt/disk` on every node). The suite ensures the corresponding
Longhorn filesystem disk exists on each node before v1 benchmarks start
(idempotent - existing disks with the same path, e.g. a Longhorn default
disk, are left alone). Set to `()` to skip auto-provisioning if the disks
are already pre-configured on the cluster.

The upstream [longhorn/kbench](https://github.com/longhorn/kbench)
`fio.yaml` is fetched fresh into `tmp/fio.yaml` on every `./run.sh run`
(this repo does not maintain its own copy). Its `nodeSelector` is then
patched automatically per run - never edit `tmp/fio.yaml` by hand, it is
overwritten every run. By default the fio pod runs on `NODES[0]`; change
`FIO_NODE_INDEX` in run.sh to use a different node (e.g. `FIO_NODE_INDEX=2`
to run fio on the third node instead). The "cross-node replica" scenarios
automatically place the replica's disk on the *next* node in `NODES`
(wrapping around), e.g. volume on node 0 -> replica on node 1; volume on
node 2 -> replica on node 0.

To pin a fork or a specific commit of the upstream template, override
`FIO_YAML_URL` in run.sh.

`storageclass/*.yaml`'s `parameters.shareManagerNodeSelector` is likewise
patched automatically to pin each Longhorn StorageClass's share-manager to
`SHARE_MANAGER_POD_NODE` (default `NODES[0]`, independent of `FIO_NODE_INDEX`
- change `SHARE_MANAGER_POD_NODE_INDEX` in run.sh to use a different node),
before the storage classes are (re)applied on every run.

The fio PVC's `accessModes` is configurable via `FIO_ACCESS_MODES` (an
array) in run.sh. Defaults to `("ReadWriteOnce" "ReadWriteMany")` - the
full suite is run once per entry, and the report groups results into one
section per access mode (RWO first, then RWX). Both Longhorn v1 and v2
StorageClasses support `ReadWriteMany` via a share-manager; the local-path
baseline is RWO-only (hostPath) and is skipped automatically under RWX
with a warning.

## Project layout

```
run.sh                  Config + CLI entry point (reset|run|report)
lib/log.sh              Logging helpers + generic retry/poll utilities
lib/k8s.sh               Longhorn/Kubernetes control-plane helpers
                          (data engines, node disks, node scheduling)
lib/fio.sh               fio job templating, execution, result parsing,
                          CSV recording, and fio.yaml downloading
lib/benchmarks.sh        Benchmark scenarios (baseline, v1, v2) + orchestration
generate_report.py        Renders results/results.csv into results/report.html,
                          results/report.pdf and results/results.md
                          (matplotlib SVG charts + WeasyPrint PDF if
                          installed, otherwise a built-in dependency-free
                          SVG renderer and no PDF)
requirements.txt          Optional: matplotlib (charts) + weasyprint (PDF)
storageclass/             Longhorn StorageClass manifests for each scenario
local-path-storage.yaml   local-path-provisioner manifest (used as baseline)
tmp/fio.yaml              Downloaded per run from upstream longhorn/kbench,
                          then patched by lib/fio.sh (git-ignored)
```

Re-running `run.sh run <engine>` updates (rather than duplicates) matching
rows in `results/results.csv`, so you can re-run individual engines/CPU
masks at any time and the report will always reflect the latest numbers.