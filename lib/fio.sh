#!/bin/bash
# fio benchmark job management: fetching the upstream fio.yaml template,
# templating it, waiting for completion, and recording parsed results into
# the results CSV consumed by generate_report.py.
#
# Requires lib/log.sh to be sourced first, and the following globals to be
# set by run.sh: FIO_YAML, FIO_YAML_URL, FIO_JOB_NAME, FIO_ACCESS_MODE,
# RESULTS_CSV, RESULTS_LOG_DIR.

# download_fio_yaml - fetch the upstream longhorn/kbench fio.yaml into
# $FIO_YAML. This repo does not maintain its own fio.yaml; a fresh copy is
# downloaded per run so upstream changes (image tag, env vars, defaults)
# flow through automatically.
function download_fio_yaml() {
    if [[ -z "$FIO_YAML_URL" || -z "$FIO_YAML" ]]; then
        die "download_fio_yaml requires FIO_YAML_URL and FIO_YAML to be set."
    fi

    log_step "Downloading fio.yaml from ${FIO_YAML_URL}..."
    mkdir -p "$(dirname "$FIO_YAML")"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 -o "$FIO_YAML" "$FIO_YAML_URL" \
            || die "Failed to download fio.yaml from ${FIO_YAML_URL}."
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 -O "$FIO_YAML" "$FIO_YAML_URL" \
            || die "Failed to download fio.yaml from ${FIO_YAML_URL}."
    else
        die "Neither curl nor wget is available to download ${FIO_YAML_URL}."
    fi

    [[ -s "$FIO_YAML" ]] || die "Downloaded fio.yaml is empty: ${FIO_YAML}."
    log_ok "Downloaded fio.yaml to ${FIO_YAML}."
}

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
    # $FIO_YAML may not exist yet on a fresh checkout (e.g. `./run.sh reset`
    # before any `run` has downloaded it). Fall back to deleting the Job by
    # name/label so reset stays offline-friendly.
    if [[ -f "$FIO_YAML" ]]; then
        kubectl delete -f "$FIO_YAML" --ignore-not-found
    else
        kubectl delete job "$FIO_JOB_NAME" --ignore-not-found
        kubectl delete pvc -l "job-name=${FIO_JOB_NAME}" --ignore-not-found
    fi

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
# Upserts one row into RESULTS_CSV, keyed by (FIO_ACCESS_MODE, label,
# replica_mode) - so re-running a benchmark updates its results instead of
# appending duplicates. FIO_ACCESS_MODE is read from the environment (set by
# set_access_mode_context in lib/benchmarks.sh).
#
# Uses python's csv module for proper quoting/escaping - the v2 labels
# generated by lib/benchmarks.sh contain commas (e.g. "v2 volume (NVMe-OF
# frontend, NVMe bdev, Poll, Hugepage, 4 CPU cores)"), which would corrupt
# the CSV if written naively. On the first write after upgrading from the
# old 8-column schema, any pre-existing rows are transparently migrated by
# tagging them with the previous default access mode ("ReadWriteOnce").
function record_result() {
    local LABEL="$1" MODE="$2" RR_IOPS="$3" RW_IOPS="$4" SR_KIBPS="$5" SW_KIBPS="$6" RR_LAT="$7" RW_LAT="$8"
    local ACCESS_MODE="${FIO_ACCESS_MODE:-ReadWriteOnce}"

    mkdir -p "$(dirname "$RESULTS_CSV")"

    "${PYTHON_BIN:-python3}" - "$RESULTS_CSV" "$ACCESS_MODE" "$LABEL" "$MODE" \
        "$RR_IOPS" "$RW_IOPS" "$SR_KIBPS" "$SW_KIBPS" "$RR_LAT" "$RW_LAT" <<'PY' \
        || die "Failed to record result into $RESULTS_CSV."
import csv
import os
import sys

path, access_mode, label, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
new_row = [access_mode, label, mode] + sys.argv[5:]

HEADER = [
    "access_mode", "label", "replica_mode",
    "rand_read_iops", "rand_write_iops",
    "seq_read_kibps", "seq_write_kibps",
    "rand_read_lat_ns", "rand_write_lat_ns",
]
LEGACY_HEADER = HEADER[1:]  # pre-access_mode 8-column schema
LEGACY_DEFAULT_ACCESS_MODE = "ReadWriteOnce"

rows = []
if os.path.exists(path):
    with open(path, newline="") as f:
        rows = list(csv.reader(f))

if rows and rows[0] == HEADER:
    rows = rows[1:]
elif rows and rows[0] == LEGACY_HEADER:
    # Migrate legacy 8-column rows: tag with the previous default access mode.
    rows = [[LEGACY_DEFAULT_ACCESS_MODE] + r for r in rows[1:]]

# Upsert: drop any existing row with same (access_mode, label, mode), then append.
rows = [
    r for r in rows
    if not (len(r) >= 3 and r[0] == access_mode and r[1] == label and r[2] == mode)
]
rows.append(new_row)

with open(path, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(HEADER)
    w.writerows(rows)
PY

    log_ok "Recorded result: '${ACCESS_MODE}' / '${LABEL}' / '${MODE}'"
}

# run_fio <storage_class> <node> <label> <replica_mode>
#
# Runs the fio benchmark Job against <storage_class> on <node>, waits for it
# to complete, parses the results and records them under <label>/<replica_mode>.
function run_fio() {
    local STORAGE_CLASS="$1" NODE="$2" LABEL="$3" MODE="$4"

    # FIO_ACCESS_MODE may be a synthetic bucketing value (e.g. "Sharded") used
    # only for the results CSV / report section. The PVC itself still needs a
    # real Kubernetes access mode - shard volumes are RWO-only per upstream.
    local PVC_ACCESS_MODE="$FIO_ACCESS_MODE"
    case "$FIO_ACCESS_MODE" in
        ReadWriteOnce|ReadWriteMany) ;;
        *) PVC_ACCESS_MODE="ReadWriteOnce" ;;
    esac

    set_fio_pvc_storage_class "$STORAGE_CLASS"
    set_fio_pvc_access_mode "$PVC_ACCESS_MODE"
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

# generate_report - regenerate results/report.html, results/report.pdf and
# results/results.md from results.csv.
function generate_report() {
    if [[ ! -f "$RESULTS_CSV" ]]; then
        log_warn "No results recorded yet, skipping report generation."
        return 0
    fi

    # Best-effort: fetch the Longhorn version from the cluster so the report
    # title reflects what was actually benchmarked. Silently skip if kubectl
    # isn't available or the setting can't be read (e.g. cluster torn down
    # after the run).
    local longhorn_version=""
    if command -v kubectl >/dev/null 2>&1; then
        longhorn_version="$(kubectl -n longhorn-system get setting.longhorn.io current-longhorn-version \
            -o jsonpath='{.value}' 2>/dev/null || true)"
    fi

    log_step "Generating report from ${RESULTS_CSV}..."
    local -a args=(
        --csv "$RESULTS_CSV"
        --out "$REPORT_HTML"
        --md  "$RESULTS_MD"
        --pdf "$REPORT_PDF"
    )
    if [[ -n "$longhorn_version" ]]; then
        args+=(--longhorn-version "$longhorn_version")
    fi
    "${PYTHON_BIN:-python3}" "${SCRIPT_DIR}/generate_report.py" "${args[@]}" \
        || die "Failed to generate report."
}
