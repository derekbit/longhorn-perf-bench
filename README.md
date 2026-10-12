# Longhorn Performance Benchmark

fio-based benchmark suite comparing Longhorn v1 and v2 data engine volumes
(1 replica, 1 cross-node replica, and 3 replicas), across a range of v2
data-engine CPU masks. Optionally also benchmarks the local-path provisioner
as a baseline, and the v2 **sharded (erasure-coded)** volumes across a
configurable `k+m` matrix.

## Usage

```sh
./run.sh reset           # Reset the cluster to its default state
./run.sh cleanup         # Delete the fio test Job/pods and PVC (kbench-pvc)
./run.sh run             # Benchmark whichever engines are listed in
                         #   config.json's `dataEngines` (any subset of
                         #   {v1, v2, shard}).
./run.sh report          # Regenerate results/report.html only
```

To use a different config file, pass `-c` / `--config` (or set
`CONFIG_FILE`):

```sh
./run.sh -c my.json run                  # CLI flag
./run.sh --config /path/to/my.json run   # long form
CONFIG_FILE=/path/to/my.json ./run.sh run  # env var
```

Precedence: `--config` flag > `CONFIG_FILE` env > `./config.json` (current
directory) > `${SCRIPT_DIR}/config.json`.

Results (`results.csv`, `report.html`, `report.pdf`, `results.md`, `charts/`,
`logs/`) are written to `-o` / `--output <dir>`, default `./results`.

```sh
./run.sh --config my.json --output out run
```

## Docker

Build the image (`REPO` defaults to `derekbit`, `TAG` to `latest`; the image
is named `$REPO/longhorn-perf-bench:$TAG`):

```sh
make                          # derekbit/longhorn-perf-bench:latest
REPO=myrepo TAG=v1.13 make    # myrepo/longhorn-perf-bench:v1.13
```

Run it from the directory holding `config.json`. With no command it runs the
benchmark (`run`); `--config` defaults to `config.json` and `--output` to
`results`, both relative to the mounted `/work`. The container needs a
kubeconfig to reach the cluster:

```sh
docker run --rm \
  -v ~/.kube/config:/root/.kube/config:ro \
  -v "$PWD":/work \
  derekbit/longhorn-perf-bench --config config.json --output results
```

Other commands work the same way, e.g. `... derekbit/longhorn-perf-bench cleanup`
or `... derekbit/longhorn-perf-bench report`.

A container cannot read host files unless they are mounted, so the two `-v`
flags are required. To avoid typing them, add an alias (e.g. in `~/.zshrc`):

```sh
alias longhorn-perf-bench='docker run --rm -v "$PWD":/work -v ~/.kube/config:/root/.kube/config:ro derekbit/longhorn-perf-bench'

longhorn-perf-bench --config config.json --output results
longhorn-perf-bench cleanup
```

## Configuration (`config.json`)

All user-tunable knobs live in [`config.json`](config.json) next to `run.sh`.
Override the path with `-c <path>` / `--config <path>` or the `CONFIG_FILE`
env var (see [Usage](#usage) above). Requires `jq`.

Engine-specific knobs are nested under `v1` / `v2` / `shard`; each engine
only pulls from its own sub-object. Setting a disk array to `[]` under any
engine skips that backend for that engine.

**Global**

| Key                        | Type      | Purpose                                                                                                    |
| -------------------------- | --------- | ---------------------------------------------------------------------------------------------------------- |
| `nodes`                    | `string[]` | Cluster node names (must have ≥ 2 for cross-node tests).                                                    |
| `fioAccessModes`           | `string[]` | PVC access modes exercised by the v1/v2 suite. Values: `"ReadWriteOnce"`, `"ReadWriteMany"`.               |
| `fioNodeIndex`             | `integer` | Index into `nodes` for the fio workload pod.                                                                |
| `fioSize`                  | `string`  | fio test-file `SIZE` (`<integer><K\|M\|G\|T>`, default `"30G"`). The PVC is auto-sized 10% larger (e.g. `30G` -> `33Gi`). |
| `shareManagerPodNodeIndex` | `integer` | Index into `nodes` for each StorageClass's share-manager (RWX only).                                        |
| `runBaseline`              | `bool`    | If `true`, also install local-path-provisioner and record it as a baseline (RWO-only, skipped under RWX).   |
| `dataEngines`              | `string[]` | Which engine suites to run this session. Any subset of `["v1", "v2", "shard"]`.                             |
| `longhornVersion`          | `string`  | Version shown in the report title (e.g. `"v1.13"`). If empty or omitted, `current-longhorn-version` is read from the cluster. |

**`v1`** (filesystem-disk based replica volumes)

| Key                | Type       | Purpose                                                                                    |
| ------------------ | ---------- | ------------------------------------------------------------------------------------------ |
| `filesystemDisks`  | `string[]` | Per-node filesystem-disk paths for the v1 data engine. `[]` to skip auto-provisioning.     |

**`v2`** (block-disk based replica volumes)

| Key             | Type       | Purpose                                                                                            |
| --------------- | ---------- | -------------------------------------------------------------------------------------------------- |
| `nvmeBdevDisks` | `string[]` | Per-node PCI BDF paths for the v2 NVMe bdev backend. `[]` to skip that backend.                     |
| `aioBdevDisks`  | `string[]` | Per-node block-device paths for the v2 AIO bdev backend. `[]` to skip that backend.                 |
| `cpuMasks`      | `string[]` | Hex CPU masks driven through the v2 data engine (e.g. `"0x1"`, `"0xFF"`).                           |
| `ioModes`       | `object`   | Maps each I/O mode (`"Poll"` / `"Interrupt"`) to the disk arrays it runs on, e.g. `{"Poll": ["nvmeBdevDisks", "aioBdevDisks"], "Interrupt": ["aioBdevDisks"]}` (NVMe bdev doesn't support interrupt mode yet). Default `{"Poll": ["nvmeBdevDisks", "aioBdevDisks"]}`. `Interrupt` sets `data-engine-interrupt-mode-enabled=true`. |

**`shard`** (v2 erasure-coded volumes)

| Key                | Type       | Purpose                                                                                                       |
| ------------------ | ---------- | ------------------------------------------------------------------------------------------------------------- |
| `nvmeBdevDisks`    | `string[]` | Per-node PCI BDF paths for the shard NVMe bdev backend. `[]` to skip that backend for shard.                   |
| `aioBdevDisks`     | `string[]` | Per-node block-device paths for the shard AIO bdev backend. `[]` to skip that backend for shard.               |
| `cpuMasks`         | `string[]` | Hex CPU masks driven through the shard suite.                                                                  |
| `dataParityChunks` | `string[]` | Erasure-coding `"k+m"` schemes where `k` = `dataLayout.dataChunks` and `m` = `dataLayout.parityChunks` (e.g. `"4+2"` -> `dataChunks=4`, `parityChunks=2`). Schemes needing more nodes than `nodes[]` are skipped with a warning. |
| `stripSizeKB`      | `integer`  | Chunk stripe size, power of two in `[4, 1024]`.                                                                |

Malformed JSON or a missing file fails fast with a clear error.

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
`v2.nvmeBdevDisks` and `v2.aioBdevDisks` in [`config.json`](config.json):

- `v2.nvmeBdevDisks` - PCI BDF paths (e.g. `0000:00:0b.0`) - runs first,
  as NVMe bdev. Labeled `v2 volume (NVMe-oF frontend, NVMe bdev, ...)`.
- `v2.aioBdevDisks` - block device paths (e.g. `/dev/nvme3n1`) - runs
  next, as AIO bdev. Labeled `v2 volume (NVMe-oF frontend, AIO bdev, ...)`.

Set either array to `[]` to skip that backend. Each backend runs the full
`v2.ioModes x v2.cpuMasks x {1 replica, 1 cross-node replica, 3 replicas}`
matrix. Shard volumes always run in Poll mode.

v1 volumes use filesystem disks configured via `v1.filesystemDisks` in
[`config.json`](config.json) (default `/mnt/disk` on every node). The suite
ensures the corresponding Longhorn filesystem disk exists on each node
before v1 benchmarks start (idempotent - existing disks with the same path,
e.g. a Longhorn default disk, are left alone). Set to `[]` to skip
auto-provisioning if the disks are already pre-configured on the cluster.

Sharded (erasure-coded) v2 volumes run only when `"shard"` is listed in
`dataEngines`. The suite iterates `shard.dataParityChunks` (default: `1+1
2+1 4+1 1+2 2+2 4+2`) over whichever of `shard.nvmeBdevDisks` /
`shard.aioBdevDisks` are non-empty, sweeping `shard.cpuMasks`, with the
chunk stripe size fixed by `shard.stripSizeKB` (default: `64`). Each
scheme spreads chunks across `k+m` nodes (one shard per node), so entries
needing more nodes than are available in `nodes[]` are skipped at runtime
with a warning. Shard results render as their own section ("Sharded
volumes (v2 erasure coding)") in the report, with one column per `k+m`
scheme, independent of the v1/v2 replica scenarios above. The upstream
reference is
[longhorn/examples/v2/sharding](https://github.com/longhorn/longhorn/tree/master/examples/v2/sharding).

The upstream [longhorn/kbench](https://github.com/longhorn/kbench)
`fio.yaml` is fetched fresh into `tmp/fio.yaml` on every `./run.sh run`
(this repo does not maintain its own copy). Its `nodeSelector` is then
patched automatically per run - never edit `tmp/fio.yaml` by hand, it is
overwritten every run. By default the fio pod runs on `nodes[0]`; change
`fioNodeIndex` in [`config.json`](config.json) to use a different node
(e.g. `"fioNodeIndex": 2` to run fio on the third node instead). The
"cross-node replica" scenarios automatically place the replica's disk on
the *next* node in `nodes` (wrapping around), e.g. volume on node 0 ->
replica on node 1; volume on node 2 -> replica on node 0.

To pin a fork or a specific commit of the upstream template, override
`FIO_YAML_URL` in run.sh.

The tracked `storageclass/*.yaml.tmpl` files are rendered fresh into
`tmp/storageclass/*.yaml` on every run, with
`parameters.shareManagerNodeSelector` set to pin each Longhorn StorageClass's
share-manager to the node at index `shareManagerPodNodeIndex` (default
`nodes[0]`, independent of `fioNodeIndex`), before the storage classes are
(re)applied. The tracked templates themselves are never modified, so
`git status` stays clean across runs.

The fio PVC's `accessModes` is configurable via `fioAccessModes` (an
array) in [`config.json`](config.json). Defaults to `["ReadWriteOnce",
"ReadWriteMany"]` - the full v1/v2 suite is run once per entry, and the
report groups results into one section per access mode (RWO first, then
RWX). Both Longhorn v1 and v2
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