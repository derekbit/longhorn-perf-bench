#!/bin/bash
# Benchmark scenarios: one function per volume configuration, plus the
# reset/run orchestration used by the CLI in run.sh.
#
# Requires lib/log.sh, lib/k8s.sh and lib/fio.sh to be sourced first, and the
# following globals to be set by run.sh: NODES, FILESYSTEM_DISKS,
# V2_NVME_BDEV_DISKS, V2_AIO_BDEV_DISKS, V2_CPU_MASKS, V2_IO_MODES,
# V2_IO_MODE_DISKS, SHARD_NVME_BDEV_DISKS,
# SHARD_AIO_BDEV_DISKS, SHARD_CPU_MASKS, SHARD_DATA_PARITY_CHUNKS,
# SHARD_STRIP_SIZE_KB, RUN_BASELINE, DATA_ENGINES, FIO_NODE, FIO_NODE_INDEX,
# SHARE_MANAGER_POD_NODE, SHARE_MANAGER_POD_NODE_INDEX, FIO_ACCESS_MODES,
# MODE_1_REPLICA, MODE_1_REPLICA_CROSSNODE, MODE_3_REPLICAS.
#
# The per-iteration globals FIO_ACCESS_MODE, VOLUME_ATTACH_NODE,
# VOLUME_ATTACH_NODE_INDEX, CROSSNODE_NODE and CROSSNODE_DISK_INDEX are
# (re)computed by set_access_mode_context() at the start of each access-mode
# iteration in run().

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

# v2_label <bdev_type> <cpu_mask> <io_mode> - produces a canonical v2 volume
# label such as: "v2 volume (NVMe-OF frontend, NVMe bdev, Poll, Hugepage, 4 CPU cores)".
function v2_label() {
    local BDEV_TYPE="$1" CPU_MASK="$2" IO_MODE="$3"
    local CORES SUFFIX
    CORES=$(cpu_mask_to_cores "$CPU_MASK")
    if [[ "$CORES" -eq 1 ]]; then SUFFIX="CPU core"; else SUFFIX="CPU cores"; fi
    echo "v2 volume (NVMe-OF frontend, ${BDEV_TYPE} bdev, ${IO_MODE}, Hugepage, ${CORES} ${SUFFIX})"
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
    # every replica-mode column for a fair side-by-side comparison. Look up
    # the row we just recorded, keyed on (access_mode, label, mode).
    local ROW
    ROW=$(awk -F',' -v am="$FIO_ACCESS_MODE" -v label="$LABEL" -v mode="$MODE_1_REPLICA" \
        '$1==am && $2==label && $3==mode {print; exit}' "$RESULTS_CSV")

    local RR_IOPS RW_IOPS SR_KIBPS SW_KIBPS RR_LAT RW_LAT
    IFS=',' read -r _ _ _ RR_IOPS RW_IOPS SR_KIBPS SW_KIBPS RR_LAT RW_LAT <<< "$ROW"

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
    local CPU_MASK="$1" BDEV_TYPE="$2" DISKS_ARRAY="$3" IO_MODE="$4"
    local LABEL
    LABEL=$(v2_label "$BDEV_TYPE" "$CPU_MASK" "$IO_MODE")

    reset_environment

    disable_data_engine "v2" || exit 1
    update_data_engine_cpu_mask "$CPU_MASK" || exit 1
    update_data_engine_io_mode "$IO_MODE" || exit 1

    enable_data_engine "v2" || exit 1
    add_block_disks "$DISKS_ARRAY" || exit 1

    run_fio "longhorn-v2-r3" "$FIO_NODE" "$LABEL" "$MODE_3_REPLICAS" || exit 1
}

function benchmark_v2_r1_volume() {
    local CPU_MASK="$1" BDEV_TYPE="$2" DISK_PATH="$3" IO_MODE="$4"
    local LABEL
    LABEL=$(v2_label "$BDEV_TYPE" "$CPU_MASK" "$IO_MODE")

    reset_environment

    disable_data_engine "v2" || exit 1
    update_data_engine_cpu_mask "$CPU_MASK" || exit 1
    update_data_engine_io_mode "$IO_MODE" || exit 1

    enable_data_engine "v2" || exit 1
    # Place the single replica on VOLUME_ATTACH_NODE (where the engine
    # attaches) so it stays co-located with the volume. Under RWO this is
    # FIO_NODE; under RWX it's the share-manager pod's node.
    add_block_disk_on_node "$VOLUME_ATTACH_NODE" "$DISK_PATH" || exit 1

    run_fio "longhorn-v2-r1" "$FIO_NODE" "$LABEL" "$MODE_1_REPLICA" || exit 1
}

function benchmark_v2_r1_crossnode_volume() {
    local CPU_MASK="$1" BDEV_TYPE="$2" DISK_PATH="$3" IO_MODE="$4"
    local LABEL
    LABEL=$(v2_label "$BDEV_TYPE" "$CPU_MASK" "$IO_MODE")

    reset_environment

    disable_data_engine "v2" || exit 1
    update_data_engine_cpu_mask "$CPU_MASK" || exit 1
    update_data_engine_io_mode "$IO_MODE" || exit 1

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
    # Order matters: IO mode (v2.ioModes key order) outermost, then NVMe bdev
    # (BDF paths) before AIO bdev (/dev/* paths), so the CSV rows and the
    # final report follow the same order within the v2 section.
    local IO_IDX IO_MODE IO_MODE_DISKS DISK_KEY BDEV_TYPE DISKS_ARRAY
    for IO_IDX in "${!V2_IO_MODES[@]}"; do
        IO_MODE="${V2_IO_MODES[IO_IDX]}"
        IO_MODE_DISKS="${V2_IO_MODE_DISKS[IO_IDX]}"
        for DISK_KEY in nvmeBdevDisks aioBdevDisks; do
            case "$DISK_KEY" in
                nvmeBdevDisks) BDEV_TYPE="NVMe"; DISKS_ARRAY="V2_NVME_BDEV_DISKS" ;;
                aioBdevDisks)  BDEV_TYPE="AIO";  DISKS_ARRAY="V2_AIO_BDEV_DISKS" ;;
            esac

            if [[ " ${IO_MODE_DISKS} " != *" ${DISK_KEY} "* ]]; then
                log_info "Skipping v2.${DISK_KEY} under ${IO_MODE} mode (not listed in v2.ioModes.${IO_MODE})."
                continue
            fi

            local disks_count
            eval "disks_count=\${#${DISKS_ARRAY}[@]}"
            if [[ "$disks_count" -eq 0 ]]; then
                log_info "Skipping ${BDEV_TYPE} bdev (${DISKS_ARRAY} is empty)."
                continue
            fi
            # VOLUME_ATTACH_DISK is the disk on the node where the engine
            # attaches (VOLUME_ATTACH_NODE) - used for the co-located 1-replica
            # benchmark. CROSSNODE_DISK is on the node immediately after it, so
            # the replica genuinely lands on a different node than the engine.
            local VOLUME_ATTACH_DISK CROSSNODE_DISK
            eval "VOLUME_ATTACH_DISK=\${${DISKS_ARRAY}[\$VOLUME_ATTACH_NODE_INDEX]}"
            eval "CROSSNODE_DISK=\${${DISKS_ARRAY}[\$CROSSNODE_DISK_INDEX]}"

            for CPU_MASK in "${V2_CPU_MASKS[@]}"; do
                log_run "Benchmarking v2 1-replica ${BDEV_TYPE}-bdev ${IO_MODE}-mode volume with CPU mask ${CPU_MASK}..."
                benchmark_v2_r1_volume "${CPU_MASK}" "$BDEV_TYPE" "$VOLUME_ATTACH_DISK" "$IO_MODE" || exit 1
            done

            for CPU_MASK in "${V2_CPU_MASKS[@]}"; do
                log_run "Benchmarking v2 1-replica cross-node ${BDEV_TYPE}-bdev ${IO_MODE}-mode volume with CPU mask ${CPU_MASK}..."
                benchmark_v2_r1_crossnode_volume "${CPU_MASK}" "$BDEV_TYPE" "$CROSSNODE_DISK" "$IO_MODE" || exit 1
            done

            for CPU_MASK in "${V2_CPU_MASKS[@]}"; do
                log_run "Benchmarking v2 3-replicas ${BDEV_TYPE}-bdev ${IO_MODE}-mode volume with CPU mask ${CPU_MASK}..."
                benchmark_v2_r3_volume "${CPU_MASK}" "$BDEV_TYPE" "$DISKS_ARRAY" "$IO_MODE" || exit 1
            done
        done
    done
}

# ---------------------------------------------------------------------------
# v2 sharded (erasure-coded) volume - independent of the v1/v2 replica
# scenarios above. Each "mode" is a k+m EC scheme (e.g. 2+1: 2 data chunks
# + 1 parity chunk, tolerating 1 node failure).
#
# Requirements per upstream (examples/v2/sharding/storageclass.yaml):
#   - Needs at least k+m nodes (one shard per node, hard anti-affinity).
#   - numberOfReplicas MUST be 1 (parity provides fault tolerance).
#   - dataLocality MUST be disabled (chunks span k+m nodes).
#   - RWO-only.
# ---------------------------------------------------------------------------

# shard_label <bdev_type> <cpu_mask> <strip_size_kb> - canonical label used
# in the CSV / report, e.g. "shard volume (NVMe bdev, 64 KiB strip, 1 CPU
# core)". Kept parallel to v2_label so the report groups them consistently.
function shard_label() {
    local BDEV_TYPE="$1" CPU_MASK="$2" STRIP="$3"
    local CORES SUFFIX
    CORES=$(cpu_mask_to_cores "$CPU_MASK")
    if [[ "$CORES" -eq 1 ]]; then SUFFIX="CPU core"; else SUFFIX="CPU cores"; fi
    echo "shard volume (${BDEV_TYPE} bdev, ${STRIP} KiB strip, ${CORES} ${SUFFIX})"
}

# benchmark_v2_shard_volume <cpu_mask> <bdev_type> <disks_array_name> <k> <m> <strip_size_kb>
function benchmark_v2_shard_volume() {
    local CPU_MASK="$1" BDEV_TYPE="$2" DISKS_ARRAY="$3" K="$4" M="$5" STRIP="$6"
    local LABEL MODE
    LABEL=$(shard_label "$BDEV_TYPE" "$CPU_MASK" "$STRIP")
    MODE="${K}+${M}"

    reset_environment

    disable_data_engine "v2" || exit 1
    update_data_engine_cpu_mask "$CPU_MASK" || exit 1
    # Shard labels don't carry an I/O mode, so pin Poll to avoid leaking Interrupt from v2 runs.
    update_data_engine_io_mode "Poll" || exit 1
    enable_data_engine "v2" || exit 1

    # EC spreads chunks across k+m distinct nodes, so every node needs its
    # block disk from the selected bdev array.
    add_block_disks "$DISKS_ARRAY" || exit 1

    apply_shard_storageclass "$K" "$M" "$STRIP" || exit 1

    run_fio "longhorn-v2-shard" "$FIO_NODE" "$LABEL" "$MODE" || exit 1

    delete_shard_storageclass
}

# run_shard_benchmarks - iterates the SHARD_DATA_PARITY_CHUNKS matrix over
# whichever of the shard.nvmeBdevDisks / shard.aioBdevDisks arrays are
# non-empty, using SHARD_CPU_MASKS as the CPU-mask sweep. k+m schemes that
# would need more nodes than are available are skipped with a warning (still
# logged so the report clearly reflects what ran).
function run_shard_benchmarks() {
    if [[ ${#SHARD_DATA_PARITY_CHUNKS[@]} -eq 0 ]]; then
        log_info "shard.dataParityChunks is empty; skipping shard benchmarks."
        return 0
    fi
    if [[ -z "$SHARD_STRIP_SIZE_KB" || "$SHARD_STRIP_SIZE_KB" == "null" ]]; then
        log_warn "shard.stripSizeKB is unset; skipping shard benchmarks."
        return 0
    fi
    if [[ ${#SHARD_CPU_MASKS[@]} -eq 0 ]]; then
        log_warn "shard.cpuMasks is empty; skipping shard benchmarks."
        return 0
    fi

    local TOTAL_NODES=${#NODES[@]}
    local BDEV_TYPE DISKS_ARRAY

    # Order matters: NVMe bdev first, then AIO bdev, so the CSV rows and the
    # final report end up ordered NVMe -> AIO within the shard section.
    for BDEV_TYPE in NVMe AIO; do
        case "$BDEV_TYPE" in
            NVMe) DISKS_ARRAY="SHARD_NVME_BDEV_DISKS" ;;
            AIO)  DISKS_ARRAY="SHARD_AIO_BDEV_DISKS" ;;
        esac

        local disks_count
        eval "disks_count=\${#${DISKS_ARRAY}[@]}"
        if [[ "$disks_count" -eq 0 ]]; then
            log_info "Skipping shard ${BDEV_TYPE} bdev (${DISKS_ARRAY} is empty)."
            continue
        fi

        for CPU_MASK in "${SHARD_CPU_MASKS[@]}"; do
            for SCHEME in "${SHARD_DATA_PARITY_CHUNKS[@]}"; do
                if [[ ! "$SCHEME" =~ ^([0-9]+)\+([0-9]+)$ ]]; then
                    log_warn "Ignoring malformed shard.dataParityChunks entry '${SCHEME}' (expected 'k+m')."
                    continue
                fi
                local K="${BASH_REMATCH[1]}" M="${BASH_REMATCH[2]}"
                local REQUIRED=$((K + M))
                if (( REQUIRED > TOTAL_NODES )); then
                    log_warn "Skipping shard ${K}+${M} on ${BDEV_TYPE} bdev: needs ${REQUIRED} nodes, only ${TOTAL_NODES} available."
                    continue
                fi

                log_run "Benchmarking shard ${K}+${M} ${BDEV_TYPE}-bdev volume (stripSizeKB=${SHARD_STRIP_SIZE_KB}, CPU mask ${CPU_MASK})..."
                benchmark_v2_shard_volume "${CPU_MASK}" "$BDEV_TYPE" "$DISKS_ARRAY" \
                    "$K" "$M" "$SHARD_STRIP_SIZE_KB" || exit 1
            done
        done
    done
}

# run - end-to-end benchmark driver. Runs whichever engines are listed in
# DATA_ENGINES (any subset of {v1, v2, shard}) and finishes by regenerating
# the HTML/PDF/Markdown report. No manual steps required.
#
# v1/v2 iterate the FIO_ACCESS_MODES matrix (RWO first, then RWX). Shard is
# independent of access mode (RWO-only per upstream) and runs once as its
# own report section.
function run() {
    # Fetch a fresh copy of the upstream fio.yaml template; we don't track
    # it in this repo. All per-run edits (storageClassName, accessModes,
    # nodeSelector) are then applied by lib/fio.sh helpers.
    download_fio_yaml || exit 1

    log_step "Resetting Longhorn storage classes..."
    render_replica_storageclasses "$SHARE_MANAGER_POD_NODE" || exit 1
    kubectl delete -f "${TMP_DIR}/storageclass/" --ignore-not-found
    kubectl apply -f "${TMP_DIR}/storageclass/"
    # The shard StorageClass is dynamically rendered per iteration
    # (see apply_shard_storageclass), so clear any stale copy up-front.
    delete_shard_storageclass

    # Membership tests over DATA_ENGINES.
    local ENGINE HAS_V1=false HAS_V2=false HAS_SHARD=false
    for ENGINE in "${DATA_ENGINES[@]}"; do
        case "$ENGINE" in
            v1)    HAS_V1=true ;;
            v2)    HAS_V2=true ;;
            shard) HAS_SHARD=true ;;
        esac
    done

    # v1 / v2 need per-access-mode context. Skip the outer loop entirely
    # when only shard is requested.
    if [[ "$HAS_V1" == true || "$HAS_V2" == true || "$RUN_BASELINE" == true ]]; then
        local ACCESS_MODE
        for ACCESS_MODE in "${FIO_ACCESS_MODES[@]}"; do
            set_access_mode_context "$ACCESS_MODE" || exit 1

            log_step "========================================================="
            log_step "Running benchmarks with access mode: ${ACCESS_MODE}"
            log_step "  FIO_NODE=${FIO_NODE}  VOLUME_ATTACH_NODE=${VOLUME_ATTACH_NODE}  CROSSNODE_NODE=${CROSSNODE_NODE}"
            log_step "========================================================="

            # local-path baseline is RWO-only (hostPath). Skip under RWX
            # with a warning so RWX iterations still complete cleanly.
            if [[ "$RUN_BASELINE" == true ]]; then
                if [[ "$ACCESS_MODE" == "ReadWriteMany" ]]; then
                    log_warn "Skipping local-path baseline under ${ACCESS_MODE} (local-path is RWO-only)."
                else
                    install_local_path_provisioner || exit 1
                    log_run "Benchmarking local-path provisioner (baseline)..."
                    benchmark_baseline_volume || exit 1
                fi
            fi

            [[ "$HAS_V1" == true ]] && { run_v1_benchmarks || exit 1; }
            [[ "$HAS_V2" == true ]] && { run_v2_benchmarks || exit 1; }
        done
    fi

    if [[ "$HAS_SHARD" == true ]]; then
        set_access_mode_context "Sharded" || exit 1
        log_step "========================================================="
        log_step "Running shard (erasure-coded) benchmarks"
        log_step "  FIO_NODE=${FIO_NODE}  Total nodes=${#NODES[@]}  strip=${SHARD_STRIP_SIZE_KB} KiB"
        log_step "========================================================="
        run_shard_benchmarks || exit 1
    fi

    generate_report
}

# set_access_mode_context <access_mode> - populates the per-iteration
# globals that the benchmark functions read (FIO_ACCESS_MODE + the derived
# VOLUME_ATTACH_* / CROSSNODE_* pair).
#
# The synthetic "Sharded" value is used only for CSV / report bucketing (so
# shard results land in their own section); the actual PVC access mode is
# translated back to ReadWriteOnce by run_fio in lib/fio.sh.
function set_access_mode_context() {
    local ACCESS_MODE="$1"

    case "$ACCESS_MODE" in
        ReadWriteOnce|ReadWriteMany|Sharded) ;;
        *) log_error "Unsupported access mode '${ACCESS_MODE}'."; return 1 ;;
    esac

    FIO_ACCESS_MODE="$ACCESS_MODE"

    # Under RWX the engine follows the share-manager pod, so the "volume
    # attach node" moves to SHARE_MANAGER_POD_NODE. Under RWO / Sharded it
    # stays on the fio pod's node.
    if [[ "$ACCESS_MODE" == "ReadWriteMany" ]]; then
        VOLUME_ATTACH_NODE_INDEX="$SHARE_MANAGER_POD_NODE_INDEX"
    else
        VOLUME_ATTACH_NODE_INDEX="$FIO_NODE_INDEX"
    fi
    CROSSNODE_DISK_INDEX=$(( (VOLUME_ATTACH_NODE_INDEX + 1) % ${#NODES[@]} ))
    VOLUME_ATTACH_NODE="${NODES[$VOLUME_ATTACH_NODE_INDEX]}"
    CROSSNODE_NODE="${NODES[$CROSSNODE_DISK_INDEX]}"
}

function reset() {
    log_step "Resetting environment to default state..."
    reset_environment || exit 1
}
