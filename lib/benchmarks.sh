#!/bin/bash
# Benchmark scenarios: one function per volume configuration, plus the
# reset/run orchestration used by the CLI in run.sh.
#
# Requires lib/log.sh, lib/k8s.sh and lib/fio.sh to be sourced first, and the
# following globals to be set by run.sh: NODES, BLOCK_TYPE_DISKS, CPU_MASKS,
# RUN_BASELINE, FIO_NODE, FIO_BLOCK_DISK, CROSSNODE_NODE, CROSSNODE_BLOCK_DISK,
# SHARE_MANAGER_POD_NODE, MODE_1_REPLICA, MODE_1_REPLICA_CROSSNODE,
# MODE_3_REPLICAS.

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
    enable_filesystem_disks_on_node "$FIO_NODE" || exit 1

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
    local CPU_MASK="$1"
    local LABEL="v2 volume (CPU mask ${CPU_MASK})"

    reset_environment

    disable_data_engine "v2" || exit 1
    update_data_engine_cpu_mask "$CPU_MASK" || exit 1

    enable_data_engine "v2" || exit 1
    add_block_disks || exit 1

    run_fio "longhorn-v2-r3" "$FIO_NODE" "$LABEL" "$MODE_3_REPLICAS" || exit 1
}

function benchmark_v2_r1_volume() {
    local CPU_MASK="$1"
    local LABEL="v2 volume (CPU mask ${CPU_MASK})"

    reset_environment

    disable_data_engine "v2" || exit 1
    update_data_engine_cpu_mask "$CPU_MASK" || exit 1

    enable_data_engine "v2" || exit 1
    add_block_disk_on_node "$FIO_NODE" "$FIO_BLOCK_DISK" || exit 1

    run_fio "longhorn-v2-r1" "$FIO_NODE" "$LABEL" "$MODE_1_REPLICA" || exit 1
}

function benchmark_v2_r1_crossnode_volume() {
    local CPU_MASK="$1"
    local LABEL="v2 volume (CPU mask ${CPU_MASK})"

    reset_environment

    disable_data_engine "v2" || exit 1
    update_data_engine_cpu_mask "$CPU_MASK" || exit 1

    enable_data_engine "v2" || exit 1
    add_block_disk_on_node "$CROSSNODE_NODE" "$CROSSNODE_BLOCK_DISK" || exit 1

    run_fio "longhorn-v2-r1" "$FIO_NODE" "$LABEL" "$MODE_1_REPLICA_CROSSNODE" || exit 1
}

function run_v1_benchmarks() {
    log_run "Benchmarking v1 1-replica volume..."
    benchmark_v1_r1_volume || exit 1

    log_run "Benchmarking v1 1-replica cross-node volume..."
    benchmark_v1_r1_crossnode_volume || exit 1

    log_run "Benchmarking v1 3-replicas volume..."
    benchmark_v1_r3_volume || exit 1
}

function run_v2_benchmarks() {
    for CPU_MASK in "${CPU_MASKS[@]}"; do
        log_run "Benchmarking v2 1-replica volume with CPU mask ${CPU_MASK}..."
        benchmark_v2_r1_volume "${CPU_MASK}" || exit 1
    done

    for CPU_MASK in "${CPU_MASKS[@]}"; do
        log_run "Benchmarking v2 1-replica cross-node volume with CPU mask ${CPU_MASK}..."
        benchmark_v2_r1_crossnode_volume "${CPU_MASK}" || exit 1
    done

    for CPU_MASK in "${CPU_MASKS[@]}"; do
        log_run "Benchmarking v2 3-replicas volume with CPU mask ${CPU_MASK}..."
        benchmark_v2_r3_volume "${CPU_MASK}" || exit 1
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
