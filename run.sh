#!/bin/bash
set -o pipefail

# ============================================================================
# Longhorn performance benchmark driver.
#
# Usage:
#   ./run.sh reset             Reset the cluster to its default state.
#   ./run.sh run v1            Benchmark baseline + Longhorn v1 data engine.
#   ./run.sh run v2            Benchmark baseline + Longhorn v2 data engine.
#   ./run.sh run all           Benchmark baseline + both v1 and v2.
#   ./run.sh report            Regenerate results/report.html only.
#
# Each `run` regenerates results/report.html (tables + bar charts) from
# results/results.csv - no manual steps are required to view the results.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"
# shellcheck source=lib/fio.sh
source "${SCRIPT_DIR}/lib/fio.sh"
# shellcheck source=lib/benchmarks.sh
source "${SCRIPT_DIR}/lib/benchmarks.sh"

# ---------------------------------------------------------------------------
# Cluster topology / test matrix - edit these to match your environment.
# ---------------------------------------------------------------------------

NODES=("dereksu-bench-1" "dereksu-bench-2" "dereksu-bench-3")
#BLOCK_TYPE_DISKS=("0000:00:0b.0" "0000:00:0b.0" "0000:00:0b.0")
BLOCK_TYPE_DISKS=("/dev/nvme3n1" "/dev/nvme3n1" "/dev/nvme3n1")
CPU_MASKS=("0x1" "0x3" "0xF" "0xFF" "0xFFFF")

# PVC access mode used by the fio benchmark. "ReadWriteOnce" works for every
# StorageClass here; "ReadWriteMany" requires a Longhorn StorageClass backed
# by a share-manager (v1) - v2 and local-path don't support RWX.
FIO_ACCESS_MODE="ReadWriteMany"

# Which NODES[] entry actually runs the fio benchmark pod (the "volume"
# node). Change this to e.g. 2 to run fio on the third node instead of the
# first - no other edits needed, fio.yaml is patched automatically from this
# on every run. For "cross-node replica" scenarios, the replica's disk is
# automatically placed on the *next* node in NODES (wrapping around), e.g.
# volume on node 0 -> replica on node 1; volume on node 2 -> replica on node 0.
FIO_NODE_INDEX=2

# Which NODES[] entry runs each Longhorn StorageClass's share-manager
# (parameters.shareManagerNodeSelector). Defaults to the first node,
# independent of FIO_NODE_INDEX.
SHARE_MANAGER_POD_NODE_INDEX=0

# Whether to also install local-path-provisioner and benchmark it as a
# baseline (see the attached example report). Optional since it requires
# applying local-path-storage.yaml; defaults to off.
RUN_BASELINE=false

# =========================================================================

if [[ "${#NODES[@]}" -lt 2 ]]; then
    echo "❌ NODES must have at least 2 entries for cross-node tests." >&2
    exit 1
fi

CROSSNODE_DISK_INDEX=$(( (FIO_NODE_INDEX + 1) % ${#NODES[@]} ))

FIO_NODE="${NODES[$FIO_NODE_INDEX]}"
FIO_BLOCK_DISK="${BLOCK_TYPE_DISKS[$FIO_NODE_INDEX]}"
CROSSNODE_NODE="${NODES[$CROSSNODE_DISK_INDEX]}"
CROSSNODE_BLOCK_DISK="${BLOCK_TYPE_DISKS[$CROSSNODE_DISK_INDEX]}"

SHARE_MANAGER_POD_NODE="${NODES[$SHARE_MANAGER_POD_NODE_INDEX]}"

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

FIO_YAML="${SCRIPT_DIR}/fio.yaml"
FIO_JOB_NAME="kbench"

RESULTS_DIR="${SCRIPT_DIR}/results"
RESULTS_CSV="${RESULTS_DIR}/results.csv"
RESULTS_LOG_DIR="${RESULTS_DIR}/logs"
REPORT_HTML="${RESULTS_DIR}/report.html"

# Canonical replica-mode labels shared by lib/benchmarks.sh and the report
# generator (order here is also the column order in the generated report).
MODE_1_REPLICA="1 replica"
MODE_1_REPLICA_CROSSNODE="1 cross-node replica"
MODE_3_REPLICAS="3 replicas"

# ============ Main Logic ============

case "$1" in
    reset)
        reset
        ;;
    run)
        run "$2"
        ;;
    report)
        generate_report
        ;;
    *)
        echo "Usage: $0 {reset|run <v1|v2|all>|report}"
        exit 1
        ;;
esac
