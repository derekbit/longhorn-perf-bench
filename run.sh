#!/bin/bash
set -o pipefail

# ============================================================================
# Longhorn performance benchmark driver.
#
# Usage:
#   ./run.sh [-c|--config <path>] reset             Reset the cluster to its default state.
#   ./run.sh [-c|--config <path>] run                Benchmark whichever engines are listed in
#                                                    config.json's `dataEngines` (any subset of
#                                                    {v1, v2, shard}).
#   ./run.sh [-c|--config <path>] report             Regenerate results/report.html only.
#
# The config path can also be set via the CONFIG_FILE env var
# (`CONFIG_FILE=... ./run.sh run`). Precedence: CLI flag > env var >
# ${SCRIPT_DIR}/config.json.
#
# Each `run` regenerates results/report.html (tables + bar charts) from
# results/results.csv - no manual steps are required to view the results.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# CLI arg parsing.
#
# Parsed here (before the config loader runs) so `-c|--config <path>` can
# switch the config file that gets loaded at global scope. Non-flag args
# accumulate into POSITIONAL_ARGS[] and are dispatched by main() at the
# bottom.
# ---------------------------------------------------------------------------
_CLI_CONFIG_FILE=""
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            if [[ -z "$2" ]]; then
                echo "❌ ${1} requires a path argument." >&2
                exit 1
            fi
            _CLI_CONFIG_FILE="$2"
            shift 2
            ;;
        --config=*)
            _CLI_CONFIG_FILE="${1#--config=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [-c|--config <path>] {reset|run|report}"
            echo "  run    Benchmark engines listed in <config>.dataEngines"
            echo "         (any subset of {v1, v2, shard})."
            echo "  Config precedence: --config flag > CONFIG_FILE env > ${SCRIPT_DIR}/config.json"
            exit 0
            ;;
        --)
            shift
            POSITIONAL_ARGS+=("$@")
            break
            ;;
        -*)
            echo "❌ Unknown flag: $1" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done
# CONFIG_FILE precedence: --config flag > env > default.
CONFIG_FILE="${_CLI_CONFIG_FILE:-${CONFIG_FILE:-${SCRIPT_DIR}/config.json}}"
unset _CLI_CONFIG_FILE

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"
# shellcheck source=lib/fio.sh
source "${SCRIPT_DIR}/lib/fio.sh"
# shellcheck source=lib/benchmarks.sh
source "${SCRIPT_DIR}/lib/benchmarks.sh"

# ---------------------------------------------------------------------------
# Cluster topology / test matrix.
#
# All user-tunable knobs live in config.json (next to this script). Override
# with `CONFIG_FILE=/path/to/other.json ./run.sh ...`.
#
# Schema (see config.json for defaults):
#
#   Top-level (global):
#     nodes                      -> NODES                          (string array)
#     fioAccessModes             -> FIO_ACCESS_MODES               (string array)
#     fioNodeIndex               -> FIO_NODE_INDEX                 (integer)
#     shareManagerPodNodeIndex   -> SHARE_MANAGER_POD_NODE_INDEX   (integer)
#     runBaseline                -> RUN_BASELINE                   (bool)
#     dataEngines                -> DATA_ENGINES                   (subset of {v1, v2, shard})
#
#   v1: { filesystemDisks }      -> FILESYSTEM_DISKS               (string array, per-node)
#
#   v2: { nvmeBdevDisks,         -> V2_NVME_BDEV_DISKS             (string array, per-node)
#         aioBdevDisks,          -> V2_AIO_BDEV_DISKS              (string array, per-node)
#         cpuMasks }             -> V2_CPU_MASKS                   (string array)
#
#   shard: { nvmeBdevDisks,      -> SHARD_NVME_BDEV_DISKS          (string array, per-node)
#            aioBdevDisks,       -> SHARD_AIO_BDEV_DISKS           (string array, per-node)
#            cpuMasks,           -> SHARD_CPU_MASKS                (string array)
#            dataParityChunks,   -> SHARD_DATA_PARITY_CHUNKS       ("k+m" string array, k=dataChunks, m=parityChunks)
#            stripSizeKB }       -> SHARD_STRIP_SIZE_KB            (integer, power of two 4..1024)
#
# Per engine, an empty disk array means "skip that bdev backend". e.g.
# setting shard.aioBdevDisks to [] restricts the shard suite to the NVMe
# bdev backend only.
# ---------------------------------------------------------------------------

# CONFIG_FILE was resolved at the top of the script (CLI flag > env > default).

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ 'jq' is required to parse ${CONFIG_FILE} but is not installed." >&2
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ Config file not found: ${CONFIG_FILE}" >&2
    echo "   Pass '-c <path>' / '--config <path>' or set CONFIG_FILE=... to override." >&2
    exit 1
fi

# Fail early on malformed JSON so a typo doesn't quietly produce empty arrays.
if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
    echo "❌ ${CONFIG_FILE} is not valid JSON." >&2
    jq empty "$CONFIG_FILE"
    exit 1
fi

# _cfg_array <jq_path> - print each element of an array config field on its
# own line. Empty arrays / missing keys produce no output (mapfile -> size 0).
_cfg_array() { jq -r "${1} // [] | .[]" "$CONFIG_FILE"; }
# _cfg_scalar <jq_path> - print a scalar config field (integer / bool / string).
_cfg_scalar() { jq -r "${1}" "$CONFIG_FILE"; }

# -- Global -----------------------------------------------------------------
mapfile -t NODES              < <(_cfg_array '.nodes')

# PVC access modes exercised by the benchmark. The full v1/v2 suite is run
# once per entry, in order, and the report groups results into one section
# per access mode ("ReadWriteOnce" first, then "ReadWriteMany").
#
# Notes on compatibility:
#   - Both Longhorn v1 and v2 StorageClasses support "ReadWriteMany" via a
#     share-manager (see storageclass/*.yaml.tmpl's shareManagerNodeSelector).
#     The local-path baseline is RWO-only (hostPath) and is skipped
#     automatically under RWX with a warning.
#   - Set to a single-element array (e.g. ["ReadWriteOnce"]) to run only
#     one access mode.
mapfile -t FIO_ACCESS_MODES   < <(_cfg_array '.fioAccessModes')

# Which NODES[] entry actually runs the fio benchmark pod (the workload
# node). Change this to e.g. 2 to run fio on the third node instead of the
# first - no other edits needed, the downloaded fio.yaml is patched
# automatically from this on every run.
#
# For "cross-node replica" scenarios, the replica's disk is placed on the
# node immediately after the *volume attach node* (wrapping around):
#   - RWO:  volume attach node == FIO_NODE, so replica lands on
#           (FIO_NODE_INDEX + 1) % ${#NODES[@]}.
#   - RWX:  volume attach node == SHARE_MANAGER_POD_NODE, so replica lands
#           on (SHARE_MANAGER_POD_NODE_INDEX + 1) % ${#NODES[@]}. This is
#           needed because the Longhorn engine attaches to the share-manager
#           pod's node under RWX - not the fio pod's node.
FIO_NODE_INDEX=$(_cfg_scalar '.fioNodeIndex')

# Which NODES[] entry runs each Longhorn StorageClass's share-manager
# (parameters.shareManagerNodeSelector). Only relevant when FIO_ACCESS_MODE
# is "ReadWriteMany". Independent of FIO_NODE_INDEX.
SHARE_MANAGER_POD_NODE_INDEX=$(_cfg_scalar '.shareManagerPodNodeIndex')

# Whether to also install local-path-provisioner and benchmark it as a
# baseline (see the attached example report). Optional since it requires
# applying local-path-storage.yaml.
RUN_BASELINE=$(_cfg_scalar '.runBaseline')

# Which data engines to benchmark on this run. Any subset of {v1, v2,
# shard} in any order; each entry runs its own suite. v1/v2 iterate every
# access mode in FIO_ACCESS_MODES; "shard" is independent (RWO-only) and
# runs once as its own report section.
mapfile -t DATA_ENGINES       < <(_cfg_array '.dataEngines')

# -- v1 (filesystem-disk based replica volumes) -----------------------------
# Per-node filesystem-disk paths for the v1 data engine. Each entry is
# ensured to exist as a Longhorn filesystem disk on the corresponding node
# before v1 benchmarks run (idempotent - existing disks with the same path
# are skipped). Set to [] to skip auto-provisioning (expect the disks to be
# pre-configured on the cluster).
mapfile -t FILESYSTEM_DISKS   < <(_cfg_array '.v1.filesystemDisks')

# -- v2 (block-disk based replica volumes) ---------------------------------
# Per-node block-disk paths for each v2 bdev backend. The suite runs NVMe
# bdev (BDF paths) first, then AIO bdev (block-device paths). Set either
# array to [] in config.json to skip that bdev type.
mapfile -t V2_NVME_BDEV_DISKS < <(_cfg_array '.v2.nvmeBdevDisks')   # BDF format, e.g. "0000:00:0b.0"
mapfile -t V2_AIO_BDEV_DISKS  < <(_cfg_array '.v2.aioBdevDisks')    # block device path, e.g. "/dev/nvme3n1"
mapfile -t V2_CPU_MASKS       < <(_cfg_array '.v2.cpuMasks')

# -- shard (v2 erasure-coded volumes) --------------------------------------
# Same shape as v2, plus the erasure-coding matrix.
#
# Each entry in dataParityChunks is a "k+m" string where k is
# dataLayout.dataChunks and m is dataLayout.parityChunks (e.g. "4+2" ->
# dataChunks=4, parityChunks=2). A k+m scheme needs at least k+m nodes
# (one shard per node, hard anti-affinity), so entries requiring more nodes
# than are available in NODES[] are skipped at runtime with a warning.
#
# See https://github.com/longhorn/longhorn/tree/master/examples/v2/sharding.
mapfile -t SHARD_NVME_BDEV_DISKS   < <(_cfg_array '.shard.nvmeBdevDisks')
mapfile -t SHARD_AIO_BDEV_DISKS    < <(_cfg_array '.shard.aioBdevDisks')
mapfile -t SHARD_CPU_MASKS         < <(_cfg_array '.shard.cpuMasks')
mapfile -t SHARD_DATA_PARITY_CHUNKS < <(_cfg_array '.shard.dataParityChunks')
# Chunk stripe size in KiB. Must be a power of two in [4, 1024]; fixed at
# volume creation time. Applied to every shard scheme.
SHARD_STRIP_SIZE_KB=$(_cfg_scalar '.shard.stripSizeKB')

# =========================================================================

if [[ "${#NODES[@]}" -lt 2 ]]; then
    echo "❌ NODES must have at least 2 entries for cross-node tests." >&2
    exit 1
fi

if [[ "${#FIO_ACCESS_MODES[@]}" -eq 0 ]]; then
    echo "❌ FIO_ACCESS_MODES must contain at least one entry." >&2
    exit 1
fi
for _AM in "${FIO_ACCESS_MODES[@]}"; do
    case "$_AM" in
        ReadWriteOnce|ReadWriteMany) ;;
        *) echo "❌ Unsupported access mode '${_AM}' in FIO_ACCESS_MODES." >&2; exit 1 ;;
    esac
done
unset _AM

if [[ "${#DATA_ENGINES[@]}" -eq 0 ]]; then
    echo "❌ dataEngines must contain at least one of {v1, v2, shard} in ${CONFIG_FILE}." >&2
    exit 1
fi
for _DE in "${DATA_ENGINES[@]}"; do
    case "$_DE" in
        v1|v2|shard) ;;
        *) echo "❌ Unsupported entry '${_DE}' in dataEngines (allowed: v1, v2, shard)." >&2; exit 1 ;;
    esac
done
unset _DE

# The "volume attach node" is where the Longhorn engine actually attaches:
#   - RWO: the fio pod's node (engine attaches wherever the workload runs).
#   - RWX (v1 share-manager): the share-manager pod's node (the engine
#     attaches to the share-manager, which then serves NFS to the fio pod).
# Both VOLUME_ATTACH_* and CROSSNODE_* depend on the current access mode, so
# they are (re)computed per access-mode iteration by set_access_mode_context
# in lib/benchmarks.sh - do not read them at this scope.

SHARE_MANAGER_POD_NODE="${NODES[$SHARE_MANAGER_POD_NODE_INDEX]}"

FIO_NODE="${NODES[$FIO_NODE_INDEX]}"

# ---------------------------------------------------------------------------
# Timeouts / retry tuning.
# ---------------------------------------------------------------------------

POD_READY_TIMEOUT="300s"
RETRY_COUNT=60
RETRY_INTERVAL=5
INSTANCE_MANAGER_TIMEOUT=300
INSTANCE_MANAGER_INTERVAL=5
FIO_TERMINATE_TIMEOUT=60
FIO_TERMINATE_INTERVAL=5

# ---------------------------------------------------------------------------
# fio job template + result output paths.
# ---------------------------------------------------------------------------

# fio.yaml is not maintained in this repo - it is downloaded fresh from
# upstream longhorn/kbench on every `./run.sh run` into ${TMP_DIR}, then
# patched in place (storageClassName / accessModes / nodeSelector) by
# lib/fio.sh. Override FIO_YAML_URL to pin a fork or a specific commit.
FIO_YAML_URL="https://raw.githubusercontent.com/longhorn/kbench/refs/heads/main/deploy/fio.yaml"
TMP_DIR="${SCRIPT_DIR}/tmp"
FIO_YAML="${TMP_DIR}/fio.yaml"
FIO_JOB_NAME="kbench"

RESULTS_DIR="${SCRIPT_DIR}/results"
RESULTS_CSV="${RESULTS_DIR}/results.csv"
RESULTS_MD="${RESULTS_DIR}/results.md"
RESULTS_LOG_DIR="${RESULTS_DIR}/logs"
REPORT_HTML="${RESULTS_DIR}/report.html"
REPORT_PDF="${RESULTS_DIR}/report.pdf"

# Canonical replica-mode labels shared by lib/benchmarks.sh and the report
# generator (order here is also the column order in the generated report).
MODE_1_REPLICA="1 replica"
MODE_1_REPLICA_CROSSNODE="1 cross-node replica"
MODE_3_REPLICAS="3 replicas"

# ============ Main Logic ============
#
# Wrapped in a function (and invoked at the very bottom) so that bash parses
# the entire script before executing anything. Otherwise, editing run.sh
# during a long benchmark run can shift byte offsets and make bash read a
# partial line from disk, producing bogus "syntax error near unexpected
# token" failures at completion time.

main() {
    case "$1" in
        reset)
            reset
            ;;
        run)
            if [[ -n "$2" ]]; then
                echo "ℹ️  './run.sh run <engine>' is no longer accepted; edit 'dataEngines' in ${CONFIG_FILE} instead." >&2
                echo "   Ignoring extra argument '$2'." >&2
            fi
            run
            ;;
        report)
            generate_report
            ;;
        *)
            echo "Usage: $0 [-c|--config <path>] {reset|run|report}" >&2
            echo "  run    Benchmark engines listed in ${CONFIG_FILE}'s 'dataEngines'." >&2
            exit 1
            ;;
    esac
}

main "${POSITIONAL_ARGS[@]}"
exit $?
