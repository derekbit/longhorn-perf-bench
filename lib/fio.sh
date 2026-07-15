#!/bin/bash
# fio benchmark job management: templating fio.yaml, waiting for completion,
# and recording parsed results into the results CSV consumed by
# generate_report.py.
#
# Requires lib/log.sh to be sourced first, and the following globals to be
# set by run.sh: FIO_YAML, FIO_JOB_NAME, FIO_ACCESS_MODE, RESULTS_CSV,
# RESULTS_LOG_DIR.

function set_fio_pvc_storage_class() {
    local STORAGE_CLASS="$1"
    export STORAGE_CLASS
    yq -i '
      ( select(.kind == "PersistentVolumeClaim") | .spec.storageClassName ) = strenv(STORAGE_CLASS)
      | .
    ' "$FIO_YAML" || die "Failed to patch fio.yaml with storageClassName."
}

# set_fio_pvc_access_mode <ReadWriteOnce|ReadWriteMany|...>
function set_fio_pvc_access_mode() {
    local ACCESS_MODE="$1"
    export ACCESS_MODE
    yq -i '
      ( select(.kind == "PersistentVolumeClaim") | .spec.accessModes ) = [strenv(ACCESS_MODE)]
      | .
    ' "$FIO_YAML" || die "Failed to patch fio.yaml with accessModes."
}

# Uses nodeSelector rather than pinning spec.template.spec.nodeName directly.
# Setting nodeName bypasses the Kubernetes scheduler entirely, which also
# skips the scheduler's volume-binding step - so StorageClasses with
# volumeBindingMode=WaitForFirstConsumer (e.g. the "local-path" baseline)
# would never get their PVC's selected-node annotation set and stay Pending
# forever. nodeSelector still pins the pod to a single node but keeps the
# pod going through normal scheduling.
function set_fio_running_node() {
    local NODE="$1"
    export NODE
    yq -i '
      ( select(.kind == "Job") | .spec.template.spec.nodeSelector) = {"kubernetes.io/hostname": strenv(NODE)}
      | .
    ' "$FIO_YAML" || die "Failed to patch fio.yaml with nodeSelector."
}

# wait_for_fio_pods_completed - waits for all pods of the fio Job to reach a
# terminal phase and prints the name of the (single) fio pod on stdout.
function wait_for_fio_pods_completed() {
    log_wait "Waiting for fio pods to be completed..."

    local PODS
    PODS=$(kubectl get pods -l "job-name=${FIO_JOB_NAME}" -o jsonpath="{.items[*].metadata.name}")

    if [[ -z "$PODS" ]]; then
        log_error "No fio pods found for job '${FIO_JOB_NAME}'."
        return 1
    fi

    for POD in $PODS; do
        log_wait "Waiting for fio pod ${POD} to be completed..."
        while true; do
            local PHASE
            PHASE=$(kubectl get pod "$POD" -o jsonpath='{.status.phase}')
            [[ "$PHASE" == "Succeeded" || "$PHASE" == "Failed" ]] && break
            sleep 5
        done
    done

    echo "$PODS"
}

function terminate_fio_pods() {
    log_step "Terminating fio pods..."
    kubectl delete -f "$FIO_YAML" --ignore-not-found

    local ELAPSED=0
    while [ $ELAPSED -lt $FIO_TERMINATE_TIMEOUT ]; do
        local PODS
        PODS=$(kubectl get pods -l "job-name=${FIO_JOB_NAME}" -o jsonpath="{.items[*].metadata.name}")
        if [ -z "$PODS" ]; then
            log_ok "All fio pods have been terminated."
            return 0
        fi
        log_wait "Waiting for fio pods to terminate: $PODS"
        sleep "$FIO_TERMINATE_INTERVAL"
        ELAPSED=$((ELAPSED + FIO_TERMINATE_INTERVAL))
    done

    log_warn "Timeout waiting for fio pods to terminate."
}

# parse_fio_summary <log_text>
#
# Extracts the six metrics out of the "FIO Benchmark Summary" block emitted
# by the kbench image, e.g.:
#   IOPS (Read/Write)
#           Random:          23,776 / 18,614
#   Bandwidth in KiB/sec (Read/Write)
#       Sequential:        922,440 / 904,009
#   Latency in ns (Read/Write)
#           Random:        385,412 / 779,086
#
# Prints "key=value" lines (one per metric) on stdout.
function parse_fio_summary() {
    local LOG="$1"
    awk '
        /IOPS \(Read\/Write\)/ { section = "iops"; next }
        /Bandwidth in KiB\/sec \(Read\/Write\)/ { section = "bw"; next }
        /Latency in ns \(Read\/Write\)/ { section = "lat"; next }

        section == "iops" && /Random:/ { emit("rand_read_iops", "rand_write_iops"); section = "" }
        section == "bw"   && /Sequential:/ { emit("seq_read_kibps", "seq_write_kibps"); section = "" }
        section == "lat"  && /Random:/ { emit("rand_read_lat_ns", "rand_write_lat_ns"); section = "" }

        function emit(read_key, write_key,    line, parts) {
            line = $0
            gsub(",", "", line)
            sub(/^[^:]*:/, "", line)
            split(line, parts, "/")
            gsub(/[ \t]/, "", parts[1])
            gsub(/[ \t]/, "", parts[2])
            print read_key "=" parts[1]
            print write_key "=" parts[2]
        }
    ' <<< "$LOG"
}

# record_result <label> <replica_mode> <rand_read_iops> <rand_write_iops> \
#               <seq_read_kibps> <seq_write_kibps> <rand_read_lat_ns> <rand_write_lat_ns>
#
# Upserts one row into RESULTS_CSV (any existing row with the same
# label+replica_mode is replaced), so re-running a benchmark updates its
# results instead of appending duplicates.
#
# Uses python's csv module for proper quoting/escaping - the v2 labels
# generated by lib/benchmarks.sh contain commas (e.g. "v2 volume (NVMe-OF
# frontend, NVMe bdev, Poll, Hugepage, 4 CPU cores)"), which would corrupt
# the CSV if written naively.
function record_result() {
    local LABEL="$1" MODE="$2" RR_IOPS="$3" RW_IOPS="$4" SR_KIBPS="$5" SW_KIBPS="$6" RR_LAT="$7" RW_LAT="$8"

    mkdir -p "$(dirname "$RESULTS_CSV")"

    python3 - "$RESULTS_CSV" "$LABEL" "$MODE" \
        "$RR_IOPS" "$RW_IOPS" "$SR_KIBPS" "$SW_KIBPS" "$RR_LAT" "$RW_LAT" <<'PY' \
        || die "Failed to record result into $RESULTS_CSV."
import csv
import os
import sys

path, label, mode = sys.argv[1], sys.argv[2], sys.argv[3]
new_row = [label, mode] + sys.argv[4:]

header = [
    "label", "replica_mode",
    "rand_read_iops", "rand_write_iops",
    "seq_read_kibps", "seq_write_kibps",
    "rand_read_lat_ns", "rand_write_lat_ns",
]

rows = []
if os.path.exists(path):
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
if rows and rows[0] == header:
    rows = rows[1:]

# Upsert: drop any existing row with same (label, mode), then append new one.
rows = [r for r in rows if not (len(r) >= 2 and r[0] == label and r[1] == mode)]
rows.append(new_row)

with open(path, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(header)
    w.writerows(rows)
PY

    log_ok "Recorded result: '${LABEL}' / '${MODE}'"
}

# run_fio <storage_class> <node> <label> <replica_mode>
#
# Runs the fio benchmark Job against <storage_class> on <node>, waits for it
# to complete, parses the results and records them under <label>/<replica_mode>.
function run_fio() {
    local STORAGE_CLASS="$1" NODE="$2" LABEL="$3" MODE="$4"

    set_fio_pvc_storage_class "$STORAGE_CLASS"
    set_fio_pvc_access_mode "$FIO_ACCESS_MODE"
    set_fio_running_node "$NODE"

    kubectl apply -f "$FIO_YAML" || die "Failed to apply fio.yaml."

    local PODS POD LOG
    PODS=$(wait_for_fio_pods_completed) || return 1
    POD=$(awk '{print $1}' <<< "$PODS")

    LOG=$(kubectl logs "$POD")
    echo "Logs for fio pod ${POD}:"
    echo "$LOG"

    mkdir -p "$RESULTS_LOG_DIR"
    local SLUG
    SLUG=$(echo "${LABEL}_${MODE}" | tr -cs '[:alnum:]' '_')
    echo "$LOG" > "${RESULTS_LOG_DIR}/${SLUG}.log"

    local RAND_READ_IOPS RAND_WRITE_IOPS SEQ_READ_KIBPS SEQ_WRITE_KIBPS RAND_READ_LAT_NS RAND_WRITE_LAT_NS
    while IFS='=' read -r KEY VALUE; do
        case "$KEY" in
            rand_read_iops)   RAND_READ_IOPS="$VALUE" ;;
            rand_write_iops)  RAND_WRITE_IOPS="$VALUE" ;;
            seq_read_kibps)   SEQ_READ_KIBPS="$VALUE" ;;
            seq_write_kibps)  SEQ_WRITE_KIBPS="$VALUE" ;;
            rand_read_lat_ns) RAND_READ_LAT_NS="$VALUE" ;;
            rand_write_lat_ns) RAND_WRITE_LAT_NS="$VALUE" ;;
        esac
    done < <(parse_fio_summary "$LOG")

    if [[ -z "$RAND_READ_IOPS" || -z "$RAND_WRITE_IOPS" || -z "$SEQ_READ_KIBPS" \
          || -z "$SEQ_WRITE_KIBPS" || -z "$RAND_READ_LAT_NS" || -z "$RAND_WRITE_LAT_NS" ]]; then
        log_error "Failed to parse fio summary for '${LABEL}' / '${MODE}'. See ${RESULTS_LOG_DIR}/${SLUG}.log"
        return 1
    fi

    record_result "$LABEL" "$MODE" \
        "$RAND_READ_IOPS" "$RAND_WRITE_IOPS" \
        "$SEQ_READ_KIBPS" "$SEQ_WRITE_KIBPS" \
        "$RAND_READ_LAT_NS" "$RAND_WRITE_LAT_NS"
}

# generate_report - regenerate results/report.html and results/results.md
# from results.csv.
function generate_report() {
    if [[ ! -f "$RESULTS_CSV" ]]; then
        log_warn "No results recorded yet, skipping report generation."
        return 0
    fi

    log_step "Generating report from ${RESULTS_CSV}..."
    python3 "${SCRIPT_DIR}/generate_report.py" \
        --csv "$RESULTS_CSV" \
        --out "$REPORT_HTML" \
        --md "$RESULTS_MD" \
        || die "Failed to generate report."
}
