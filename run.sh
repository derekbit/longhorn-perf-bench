#!/bin/bash
set -o pipefail

# ============================================================================
# Longhorn performance benchmark driver.
#
# Usage:
#   ./run.sh [-c|--config <path>] reset             Reset the cluster to its default state.
#   ./run.sh [-c|--config <path>] cleanup           Delete the fio test Job/pods and PVC.
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
            echo "Usage: $0 [-c|--config <path>] {setup|reset|cleanup|run|report}"
            echo "  setup    Create .venv and install report deps (matplotlib/weasyprint)."
            echo "  cleanup  Delete the fio test Job/pods and PVC."
            echo "  run      Benchmark engines listed in <config>.dataEngines"
            echo "           (any subset of {v1, v2, shard})."
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
#     fioSize                    -> FIO_SIZE                       (fio SIZE, e.g. "30G"; default "30G")
#     shareManagerPodNodeIndex   -> SHARE_MANAGER_POD_NODE_INDEX   (integer)
#     runBaseline                -> RUN_BASELINE                   (bool)
#     dataEngines                -> DATA_ENGINES                   (subset of {v1, v2, shard})
#     longhornVersion            -> LONGHORN_VERSION               (report title version, e.g. "v1.13"; default: read from cluster)
#
#   v1: { filesystemDisks }      -> FILESYSTEM_DISKS               (string array, per-node)
#
#   v2: { nvmeBdevDisks,         -> V2_NVME_BDEV_DISKS             (string array, per-node)
#         aioBdevDisks,          -> V2_AIO_BDEV_DISKS              (string array, per-node)
#         cpuMasks,              -> V2_CPU_MASKS                   (string array)
#         ioModes }              -> V2_IO_MODES / V2_IO_MODE_DISKS ({"Poll"|"Interrupt": ["nvmeBdevDisks"|"aioBdevDisks", ...]})
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
# own line. Empty arrays / missing keys produce no output (read_array -> size 0).
_cfg_array() { jq -r "${1} // [] | .[]" "$CONFIG_FILE"; }
# _cfg_scalar <jq_path> - print a scalar config field (integer / bool / string).
_cfg_scalar() { jq -r "${1}" "$CONFIG_FILE"; }

# read_array <array_name> - portable replacement for `mapfile -t` /
# `readarray -t`, which are Bash 4+ builtins absent from the Bash 3.2 that
# ships with macOS. Reads newline-delimited stdin into the named array (one
# element per line); empty input yields an empty array.
#   Usage: read_array ARRAY_NAME < <(command)
read_array() {
    local __name="$1"
    local __line
    eval "${__name}=()"
    while IFS= read -r __line || [[ -n "$__line" ]]; do
        eval "${__name}+=( \"\$__line\" )"
    done
}

# -- Global -----------------------------------------------------------------
read_array NODES              < <(_cfg_array '.nodes')

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
read_array FIO_ACCESS_MODES   < <(_cfg_array '.fioAccessModes')

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

# fio test-file size (<integer><K|M|G|T>). The PVC is auto-sized 10% larger.
FIO_SIZE=$(_cfg_scalar '.fioSize // "30G"')

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
read_array DATA_ENGINES       < <(_cfg_array '.dataEngines')

# Version shown in the report title. Empty -> current-longhorn-version from the cluster.
LONGHORN_VERSION=$(_cfg_scalar '.longhornVersion // ""')

# -- v1 (filesystem-disk based replica volumes) -----------------------------
# Per-node filesystem-disk paths for the v1 data engine. Each entry is
# ensured to exist as a Longhorn filesystem disk on the corresponding node
# before v1 benchmarks run (idempotent - existing disks with the same path
# are skipped). Set to [] to skip auto-provisioning (expect the disks to be
# pre-configured on the cluster).
read_array FILESYSTEM_DISKS   < <(_cfg_array '.v1.filesystemDisks')

# -- v2 (block-disk based replica volumes) ---------------------------------
# Per-node block-disk paths for each v2 bdev backend. The suite runs NVMe
# bdev (BDF paths) first, then AIO bdev (block-device paths). Set either
# array to [] in config.json to skip that bdev type.
read_array V2_NVME_BDEV_DISKS < <(_cfg_array '.v2.nvmeBdevDisks')   # BDF format, e.g. "0000:00:0b.0"
read_array V2_AIO_BDEV_DISKS  < <(_cfg_array '.v2.aioBdevDisks')    # block device path, e.g. "/dev/nvme3n1"
read_array V2_CPU_MASKS       < <(_cfg_array '.v2.cpuMasks')
# v2.ioModes maps each I/O mode to the disk arrays it runs on, e.g.
#   {"Poll": ["nvmeBdevDisks", "aioBdevDisks"], "Interrupt": ["aioBdevDisks"]}
# "Interrupt" sets data-engine-interrupt-mode-enabled=true; "Poll" sets it to false.
# V2_IO_MODE_DISKS[i] holds the space-joined disk keys for V2_IO_MODES[i].
_V2_IO_MODES_JQ='(.v2.ioModes // {"Poll": ["nvmeBdevDisks", "aioBdevDisks"]})'
if ! jq -e "${_V2_IO_MODES_JQ} | type == \"object\"" "$CONFIG_FILE" >/dev/null; then
    echo "❌ v2.ioModes must be an object, e.g. {\"Poll\": [\"nvmeBdevDisks\", \"aioBdevDisks\"], \"Interrupt\": [\"aioBdevDisks\"]}." >&2
    exit 1
fi
read_array V2_IO_MODES      < <(jq -r "${_V2_IO_MODES_JQ} | keys_unsorted[]" "$CONFIG_FILE")
read_array V2_IO_MODE_DISKS < <(jq -r "${_V2_IO_MODES_JQ} | .[] | join(\" \")" "$CONFIG_FILE")
unset _V2_IO_MODES_JQ

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
read_array SHARD_NVME_BDEV_DISKS   < <(_cfg_array '.shard.nvmeBdevDisks')
read_array SHARD_AIO_BDEV_DISKS    < <(_cfg_array '.shard.aioBdevDisks')
read_array SHARD_CPU_MASKS         < <(_cfg_array '.shard.cpuMasks')
read_array SHARD_DATA_PARITY_CHUNKS < <(_cfg_array '.shard.dataParityChunks')
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

if [[ ! "$FIO_SIZE" =~ ^[1-9][0-9]*[KMGT]$ ]]; then
    echo "❌ fioSize '${FIO_SIZE}' is invalid (expected <integer><K|M|G|T>, e.g. \"30G\")." >&2
    exit 1
fi

for _IM in "${V2_IO_MODES[@]}"; do
    case "$_IM" in
        Poll|Interrupt) ;;
        *) echo "❌ Unsupported key '${_IM}' in v2.ioModes (allowed: Poll, Interrupt)." >&2; exit 1 ;;
    esac
done
unset _IM

for _DK in ${V2_IO_MODE_DISKS[@]}; do
    case "$_DK" in
        nvmeBdevDisks|aioBdevDisks) ;;
        *) echo "❌ Unsupported entry '${_DK}' in v2.ioModes (allowed: nvmeBdevDisks, aioBdevDisks)." >&2; exit 1 ;;
    esac
done
unset _DK

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
# Block disks may need SPDK blobstore recovery (several minutes on large NVMe) after an unclean shutdown.
BLOCK_DISK_RETRY_COUNT=240
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
FIO_PVC_NAME="kbench-pvc"

RESULTS_DIR="${SCRIPT_DIR}/results"
RESULTS_CSV="${RESULTS_DIR}/results.csv"
RESULTS_MD="${RESULTS_DIR}/results.md"
RESULTS_LOG_DIR="${RESULTS_DIR}/logs"
REPORT_HTML="${RESULTS_DIR}/report.html"
REPORT_PDF="${RESULTS_DIR}/report.pdf"

# ---------------------------------------------------------------------------
# Python interpreter used to write results.csv and render the report
# (lib/fio.sh). Prefer the project-local virtualenv created by
# `./run.sh setup` so the optional report deps (matplotlib/weasyprint) are
# picked up even when the venv isn't activated. macOS ships an
# externally-managed Python (PEP 668) that rejects a plain `pip install`, so
# a venv is the path of least resistance there. Falls back to system python3.
# ---------------------------------------------------------------------------
VENV_DIR="${SCRIPT_DIR}/.venv"
if [[ -x "${VENV_DIR}/bin/python" ]]; then
    PYTHON_BIN="${VENV_DIR}/bin/python"
else
    PYTHON_BIN="python3"
fi

# Canonical replica-mode labels shared by lib/benchmarks.sh and the report
# generator (order here is also the column order in the generated report).
MODE_1_REPLICA="1 replica"
MODE_1_REPLICA_CROSSNODE="1 cross-node replica"
MODE_3_REPLICAS="3 replicas"

# setup_python_env - create ${VENV_DIR} (if missing) and install the optional
# report dependencies from requirements.txt into it. Idempotent; safe to
# re-run. Enables PDF (weasyprint) and nicer charts (matplotlib) without
# touching the system Python.
setup_python_env() {
    local req="${SCRIPT_DIR}/requirements.txt"
    if ! command -v python3 >/dev/null 2>&1; then
        echo "❌ python3 is required to set up the report environment." >&2
        exit 1
    fi
    if [[ ! -d "$VENV_DIR" ]]; then
        echo "⚙️  Creating virtualenv at ${VENV_DIR}..."
        python3 -m venv "$VENV_DIR" || { echo "❌ Failed to create virtualenv." >&2; exit 1; }
    fi
    echo "⚙️  Installing report dependencies from ${req}..."
    "${VENV_DIR}/bin/python" -m pip install --upgrade pip >/dev/null
    "${VENV_DIR}/bin/python" -m pip install -r "$req" \
        || { echo "❌ Failed to install ${req}." >&2; exit 1; }
    echo "✅ Report environment ready. run.sh will use ${VENV_DIR}/bin/python automatically."
}

# ============ Main Logic ============
#
# Wrapped in a function (and invoked at the very bottom) so that bash parses
# the entire script before executing anything. Otherwise, editing run.sh
# during a long benchmark run can shift byte offsets and make bash read a
# partial line from disk, producing bogus "syntax error near unexpected
# token" failures at completion time.

main() {
    case "$1" in
        setup)
            setup_python_env
            ;;
        reset)
            reset
            ;;
        cleanup)
            cleanup_fio_resources || exit 1
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
            echo "Usage: $0 [-c|--config <path>] {setup|reset|cleanup|run|report}" >&2
            echo "  setup    Create .venv and install report deps (matplotlib/weasyprint)." >&2
            echo "  cleanup  Delete the fio test Job/pods and PVC." >&2
            echo "  run      Benchmark engines listed in ${CONFIG_FILE}'s 'dataEngines'." >&2
            exit 1
            ;;
    esac
}

main "${POSITIONAL_ARGS[@]}"
exit $?
