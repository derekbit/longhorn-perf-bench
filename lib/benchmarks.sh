#!/bin/bash
# Benchmark scenarios: one function per volume configuration, plus the
# reset/run orchestration used by the CLI in run.sh.
#
# Requires lib/log.sh, lib/k8s.sh and lib/fio.sh to be sourced first, and the
# following globals to be set by run.sh: NODES, FILESYSTEM_DISKS,
# NVME_BDEV_DISKS, AIO_BDEV_DISKS, CPU_MASKS, RUN_BASELINE, FIO_NODE,
# FIO_NODE_INDEX, VOLUME_ATTACH_NODE, VOLUME_ATTACH_NODE_INDEX,
# CROSSNODE_NODE, CROSSNODE_DISK_INDEX, SHARE_MANAGER_POD_NODE,
# MODE_1_REPLICA, MODE_1_REPLICA_CROSSNODE, MODE_3_REPLICAS.

# ---------------------------------------------------------------------------
# Helpers for v2 volume labeling
# ---------------------------------------------------------------------------

# cpu_mask_to_cores <mask> - counts set bits in a hex mask (e.g. 0xFF -> 8).
function cpu_mask_to_cores() {
    local mask=$(( $1 ))
    local count=0
    while (( mask > 0 )); do
        (( count += mask & 1 ))
        (( mask >>= 1 ))
    done
    echo "$count"
}

# v2_label <bdev_type> <cpu_mask> - produces a canonical v2 volume label such
# as: "v2 volume (NVMe-OF frontend, NVMe bdev, Poll, Hugepage, 4 CPU cores)".
function v2_label() {
    local BDEV_TYPE="$1" CPU_MASK="$2"
    local CORES SUFFIX
    CORES=$(cpu_mask_to_cores "$CPU_MASK")
    if [[ "$CORES" -eq 1 ]]; then SUFFIX="CPU core"; else SUFFIX="CPU cores"; fi
    echo "v2 volume (NVMe-OF frontend, ${BDEV_TYPE} bdev, Poll, Hugepage, ${CORES} ${SUFFIX})"
}

function reset_environment() {
    # Enable both data engines first to ensure proper cleanup.
    terminate_fio_pods
    enable_data_engine "v1" || exit 1
    enable_data_engine "v2" || exit 1
    enable_filesystem_disks || exit 1
    delete_block_disks || exit 1
    enable_node_scheduling || exit 1
}

function benchmark_baseline_volume() {
    reset_environment

    local LABEL="local-path provisioner (baseline)"
    run_fio "local-path" "$FIO_NODE" "$LABEL" "$MODE_1_REPLICA" || exit 1

    # The baseline has no replica concept, so mirror the same numbers across
    # every replica-mode column for a fair side-by-side comparison.
    local ROW
    ROW=$(awk -F',' -v label="$LABEL" -v mode="$MODE_1_REPLICA" \
        '$1==label && $2==mode {print; exit}' "$RESULTS_CSV")

    local RR_IOPS RW_IOPS SR_KIBPS SW_KIBPS RR_LAT RW_LAT
    IFS=',' read -r _ _ RR_IOPS RW_IOPS SR_KIBPS SW_KIBPS RR_LAT RW_LAT <<< "$ROW"

    record_result "$LABEL" "$MODE_1_REPLICA_CROSSNODE" "$RR_IOPS" "$RW_IOPS" "$SR_KIBPS" "$SW_KIBPS" "$RR_LAT" "$RW_LAT"
    record_result "$LABEL" "$MODE_3_REPLICAS" "$RR_IOPS" "$RW_IOPS" "$SR_KIBPS" "$SW_KIBPS" "$RR_LAT" "$RW_LAT"
}

function benchmark_v1_r3_volume() {
    reset_environment

    disable_data_engine "v2" || exit 1
    enable_data_engine "v1" || exit 1
    enable_filesystem_disks || exit 1

    run_fio "longhorn-v1-r3" "$FIO_NODE" "v1 volume" "$MODE_3_REPLICAS" || exit 1
}

function benchmark_v1_r1_volume() {
    reset_environment

    disable_data_engine "v2" || exit 1
    enable_data_engine "v1" || exit 1
    disable_filesystem_disks || exit 1
    # Under RWX the engine attaches to the share-manager pod's node, so
    # "co-located" means the replica must live on VOLUME_ATTACH_NODE (which
    # equals FIO_NODE under RWO).
    enable_filesystem_disks_on_node "$VOLUME_ATTACH_NODE" || exit 1

    run_fio "longhorn-v1-r1" "$FIO_NODE" "v1 volume" "$MODE_1_REPLICA" || exit 1
}

function benchmark_v1_r1_crossnode_volume() {
    reset_environment

    disable_data_engine "v2" || exit 1
    enable_data_engine "v1" || exit 1
    disable_filesystem_disks || exit 1
    enable_filesystem_disks_on_node "$CROSSNODE_NODE" || exit 1

    run_fio "longhorn-v1-r1" "$FIO_NODE" "v1 volume" "$MODE_1_REPLICA_CROSSNODE" || exit 1
}

function benchmark_v2_r3_volume() {
    local CPU_MASK="$1" BDEV_TYPE="$2" DISKS_ARRAY="$3"
    local LABEL
    LABEL=$(v2_label "$BDEV_TYPE" "$CPU_MASK")

    reset_environment

    disable_data_engine "v2" || exit 1
    update_data_engine_cpu_mask "$CPU_MASK" || exit 1

    enable_data_engine "v2" || exit 1
    add_block_disks "$DISKS_ARRAY" || exit 1

    run_fio "longhorn-v2-r3" "$FIO_NODE" "$LABEL" "$MODE_3_REPLICAS" || exit 1
}

function benchmark_v2_r1_volume() {
    local CPU_MASK="$1" BDEV_TYPE="$2" DISK_PATH="$3"
    local LABEL
    LABEL=$(v2_label "$BDEV_TYPE" "$CPU_MASK")

    reset_environment

    disable_data_engine "v2" || exit 1
    update_data_engine_cpu_mask "$CPU_MASK" || exit 1

    enable_data_engine "v2" || exit 1
    # Place the single replica on VOLUME_ATTACH_NODE (where the engine
    # attaches) so it stays co-located with the volume. Under RWO this is
    # FIO_NODE; under RWX it's the share-manager pod's node.
    add_block_disk_on_node "$VOLUME_ATTACH_NODE" "$DISK_PATH" || exit 1

    run_fio "longhorn-v2-r1" "$FIO_NODE" "$LABEL" "$MODE_1_REPLICA" || exit 1
}

function benchmark_v2_r1_crossnode_volume() {
    local CPU_MASK="$1" BDEV_TYPE="$2" DISK_PATH="$3"
    local LABEL
    LABEL=$(v2_label "$BDEV_TYPE" "$CPU_MASK")

    reset_environment

    disable_data_engine "v2" || exit 1
    update_data_engine_cpu_mask "$CPU_MASK" || exit 1

    enable_data_engine "v2" || exit 1
    add_block_disk_on_node "$CROSSNODE_NODE" "$DISK_PATH" || exit 1

    run_fio "longhorn-v2-r1" "$FIO_NODE" "$LABEL" "$MODE_1_REPLICA_CROSSNODE" || exit 1
}

function run_v1_benchmarks() {
    # Ensure the per-node filesystem disks configured in run.sh exist on
    # each Longhorn node before we start toggling their scheduling in each
    # benchmark. Idempotent - existing disks with the same path are skipped.
    if [[ ${#FILESYSTEM_DISKS[@]} -gt 0 ]]; then
        add_filesystem_disks FILESYSTEM_DISKS || exit 1
    fi

    log_run "Benchmarking v1 1-replica volume..."
    benchmark_v1_r1_volume || exit 1

    log_run "Benchmarking v1 1-replica cross-node volume..."
    benchmark_v1_r1_crossnode_volume || exit 1

    log_run "Benchmarking v1 3-replicas volume..."
    benchmark_v1_r3_volume || exit 1
}

function run_v2_benchmarks() {
    # Order matters: NVMe bdev (BDF paths) first, then AIO bdev (/dev/* paths),
    # so the CSV rows and the final report end up ordered NVMe -> AIO within
    # the v2 section.
    local BDEV_TYPE DISKS_ARRAY
    for BDEV_TYPE in NVMe AIO; do
        case "$BDEV_TYPE" in
            NVMe) DISKS_ARRAY="NVME_BDEV_DISKS" ;;
            AIO)  DISKS_ARRAY="AIO_BDEV_DISKS" ;;
        esac

        local -n disks_ref="$DISKS_ARRAY"
        if [[ ${#disks_ref[@]} -eq 0 ]]; then
            log_info "Skipping ${BDEV_TYPE} bdev (${DISKS_ARRAY} is empty)."
            unset -n disks_ref
            continue
        fi
        # VOLUME_ATTACH_DISK is the disk on the node where the engine
        # attaches (VOLUME_ATTACH_NODE) - used for the co-located 1-replica
        # benchmark. CROSSNODE_DISK is on the node immediately after it, so
        # the replica genuinely lands on a different node than the engine.
        local VOLUME_ATTACH_DISK="${disks_ref[$VOLUME_ATTACH_NODE_INDEX]}"
        local CROSSNODE_DISK="${disks_ref[$CROSSNODE_DISK_INDEX]}"
        unset -n disks_ref

        for CPU_MASK in "${CPU_MASKS[@]}"; do
            log_run "Benchmarking v2 1-replica ${BDEV_TYPE}-bdev volume with CPU mask ${CPU_MASK}..."
            benchmark_v2_r1_volume "${CPU_MASK}" "$BDEV_TYPE" "$VOLUME_ATTACH_DISK" || exit 1
        done

        for CPU_MASK in "${CPU_MASKS[@]}"; do
            log_run "Benchmarking v2 1-replica cross-node ${BDEV_TYPE}-bdev volume with CPU mask ${CPU_MASK}..."
            benchmark_v2_r1_crossnode_volume "${CPU_MASK}" "$BDEV_TYPE" "$CROSSNODE_DISK" || exit 1
        done

        for CPU_MASK in "${CPU_MASKS[@]}"; do
            log_run "Benchmarking v2 3-replicas ${BDEV_TYPE}-bdev volume with CPU mask ${CPU_MASK}..."
            benchmark_v2_r3_volume "${CPU_MASK}" "$BDEV_TYPE" "$DISKS_ARRAY" || exit 1
        done
    done
}

# run <v1|v2|all> - runs the requested benchmark suite end-to-end and
# regenerates the HTML report. No manual steps required.
function run() {
    local DATA_ENGINE="$1"

    log_step "Resetting Longhorn storage classes..."
    set_storageclasses_share_manager_node "$SHARE_MANAGER_POD_NODE" || exit 1
    kubectl delete -f "${SCRIPT_DIR}/storageclass/" --ignore-not-found
    kubectl apply -f "${SCRIPT_DIR}/storageclass/"

    if [[ "$RUN_BASELINE" == true ]]; then
        install_local_path_provisioner || exit 1

        log_run "Benchmarking local-path provisioner (baseline)..."
        benchmark_baseline_volume || exit 1
    fi

    case "$DATA_ENGINE" in
        v1)  run_v1_benchmarks || exit 1 ;;
        v2)  run_v2_benchmarks || exit 1 ;;
        all)
            run_v1_benchmarks || exit 1
            run_v2_benchmarks || exit 1
            ;;
        *)
            die "Invalid data engine '${DATA_ENGINE}'. Use 'v1', 'v2' or 'all'."
            ;;
    esac

    generate_report
}

function reset() {
    log_step "Resetting environment to default state..."
    reset_environment || exit 1
}
