#!/bin/bash
# Kubernetes / Longhorn control-plane helpers: instance managers, data
# engines, node disks and node scheduling.
#
# Requires lib/log.sh to be sourced first.

# ---------------------------------------------------------------------------
# local-path provisioner (used as the benchmark baseline)
# ---------------------------------------------------------------------------

function install_local_path_provisioner() {
    log_step "Installing local-path provisioner..."
    kubectl apply -f "${SCRIPT_DIR}/local-path-storage.yaml" || die "Failed to apply local-path-storage.yaml."

    local PODS
    PODS=$(kubectl get pods -n local-path-storage -o jsonpath="{.items[*].metadata.name}")
    for POD in $PODS; do
        log_wait "Waiting for pod ${POD} to be ready..."
        kubectl wait --for=condition=Ready "pod/${POD}" -n local-path-storage --timeout="${POD_READY_TIMEOUT}" \
            || die "Pod ${POD} in namespace local-path-storage is not ready after ${POD_READY_TIMEOUT}."
    done
}

# ---------------------------------------------------------------------------
# Longhorn StorageClasses
# ---------------------------------------------------------------------------

# render_replica_storageclasses <node> - render every replica StorageClass
# template (storageclass/v{1,2}-r{1,3}-sc.yaml.tmpl) into
# ${TMP_DIR}/storageclass/ with parameters.shareManagerNodeSelector set to
# <node>. The tracked .yaml.tmpl files are never modified so the workspace
# stays clean across runs.
#
# Rendered output path is the caller's contract: `kubectl apply -f
# ${TMP_DIR}/storageclass/` picks up exactly the .yaml files produced here.
# The shard SC template is rendered separately per iteration by
# apply_shard_storageclass (below), so it is intentionally excluded here.
function render_replica_storageclasses() {
    local NODE="$1"
    if [[ -z "$NODE" ]]; then
        log_error "render_replica_storageclasses requires a node name."
        return 1
    fi

    local OUT_DIR="${TMP_DIR}/storageclass"
    rm -rf "$OUT_DIR"
    mkdir -p "$OUT_DIR"

    export NODE
    local TMPL DEST
    for TMPL in "${SCRIPT_DIR}"/storageclass/v[12]-r[13]-sc.yaml.tmpl; do
        [[ -f "$TMPL" ]] || continue
        DEST="${OUT_DIR}/$(basename "${TMPL%.tmpl}")"
        cp "$TMPL" "$DEST" || return 1
        yq -i '
          .parameters.shareManagerNodeSelector = "kubernetes.io/hostname:" + strenv(NODE)
        ' "$DEST" || die "Failed to render ${TMPL} into ${DEST}."
    done
    unset NODE
}

# apply_shard_storageclass <k> <m> <strip_size_kb> - renders
# storageclass/v2-shard-sc.yaml.tmpl with the given erasure-coding
# parameters into ${TMP_DIR}/v2-shard-sc.yaml and (re)applies it as the
# `longhorn-v2-shard` StorageClass. The SC is delete-then-applied so each
# iteration gets a fresh definition (StorageClass parameters are immutable
# on some Kubernetes versions).
function apply_shard_storageclass() {
    local K="$1" M="$2" STRIP="$3"
    local TMPL="${SCRIPT_DIR}/storageclass/v2-shard-sc.yaml.tmpl"
    local RENDERED="${TMP_DIR}/v2-shard-sc.yaml"

    if [[ ! -f "$TMPL" ]]; then
        log_error "Shard StorageClass template not found: ${TMPL}"
        return 1
    fi

    mkdir -p "$TMP_DIR"
    cp "$TMPL" "$RENDERED" || return 1

    K="$K" M="$M" STRIP="$STRIP" yq -i '
      .parameters."dataLayout.dataChunks"   = strenv(K) |
      .parameters."dataLayout.parityChunks" = strenv(M) |
      .parameters."dataLayout.stripSizeKB"  = strenv(STRIP)
    ' "$RENDERED" || die "Failed to patch ${RENDERED} with shard parameters."

    kubectl delete storageclass longhorn-v2-shard --ignore-not-found >/dev/null 2>&1 || true
    kubectl apply -f "$RENDERED" \
        || die "Failed to apply shard StorageClass (k=${K}, m=${M}, stripSizeKB=${STRIP})."
}

# delete_shard_storageclass - best-effort cleanup of the dynamically-applied
# shard StorageClass. Safe to call even when it doesn't exist.
function delete_shard_storageclass() {
    kubectl delete storageclass longhorn-v2-shard --ignore-not-found >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Instance managers / data engines
# ---------------------------------------------------------------------------

function wait_for_instance_manager_ready() {
    local DATA_ENGINE="$1"
    log_wait "Waiting for ${DATA_ENGINE} data engine instance manager to be ready..."

    local PODS
    PODS=$(kubectl -n longhorn-system get pods \
        -l longhorn.io/component=${DATA_ENGINE}-instance-manager \
        -l longhorn.io/data-engine=${DATA_ENGINE} \
        -o jsonpath="{.items[*].metadata.name}")

    for POD in $PODS; do
        log_wait "Waiting for pod ${POD} to be ready..."
        kubectl -n longhorn-system wait --for=condition=Ready "pod/${POD}" --timeout="${POD_READY_TIMEOUT}" \
            || die "Pod ${POD} for ${DATA_ENGINE} data engine is not ready after ${POD_READY_TIMEOUT}."
    done
}

function wait_for_instance_manager_terminated() {
    local DATA_ENGINE="$1"
    log_wait "Waiting for ${DATA_ENGINE} data engine instance manager to terminate..."

    local ELAPSED=0
    while [ $ELAPSED -lt $INSTANCE_MANAGER_TIMEOUT ]; do
        local PODS
        PODS=$(kubectl -n longhorn-system get pods \
            -l longhorn.io/component=${DATA_ENGINE}-instance-manager \
            -l longhorn.io/data-engine=${DATA_ENGINE} \
            -o jsonpath="{.items[*].metadata.name}")

        if [ -z "$PODS" ]; then
            log_ok "All ${DATA_ENGINE} data engine instance manager pods have terminated."
            return 0
        fi

        log_wait "Waiting for pods to terminate: ${PODS}"
        sleep "$INSTANCE_MANAGER_INTERVAL"
        ELAPSED=$((ELAPSED + INSTANCE_MANAGER_INTERVAL))
    done

    die "Timeout waiting for ${DATA_ENGINE} data engine instance manager pods to terminate."
}

function enable_data_engine() {
    local DATA_ENGINE="$1"
    kubectl -n longhorn-system patch setting.longhorn.io "${DATA_ENGINE}-data-engine" --type=merge -p '{"value":"true"}' \
        || die "Failed to enable ${DATA_ENGINE} data engine."

    wait_for_instance_manager_ready "$DATA_ENGINE"
}

function disable_data_engine() {
    local DATA_ENGINE="$1"
    kubectl -n longhorn-system patch setting.longhorn.io "${DATA_ENGINE}-data-engine" --type=merge -p '{"value":"false"}' \
        || die "Failed to disable ${DATA_ENGINE} data engine."

    wait_for_instance_manager_terminated "$DATA_ENGINE"
}

function update_data_engine_cpu_mask() {
    local CPU_MASK="$1"
    kubectl -n longhorn-system patch setting.longhorn.io data-engine-cpu-mask --type=merge -p "{\"value\":\"${CPU_MASK}\"}" \
        || die "Failed to update data engine CPU mask."

    wait_for_instance_manager_terminated v2
    wait_for_instance_manager_ready v2
}

# ---------------------------------------------------------------------------
# Disk status helpers (shared by filesystem-disk and block-disk management)
# ---------------------------------------------------------------------------

# spec_disks_by_type <node> <disk_type> - disk keys under .spec.disks matching diskType.
function spec_disks_by_type() {
    local NODE="$1" DISK_TYPE="$2"
    kubectl -n longhorn-system get node.longhorn.io "${NODE}" -o jsonpath='{.spec.disks}' \
        | yq -r "to_entries | map(select(.value.diskType == \"${DISK_TYPE}\")) | .[].key"
}

# status_disks_by_type <node> <disk_type> - disk keys under .status.diskStatus matching diskType.
function status_disks_by_type() {
    local NODE="$1" DISK_TYPE="$2"
    kubectl -n longhorn-system get node.longhorn.io "${NODE}" -o json \
        | yq -r ".status.diskStatus | to_entries | map(select(.value.diskType == \"${DISK_TYPE}\")) | .[].key"
}

# disk_condition_status <node> <disk> <condition_type> - "True"/"False"/"".
function disk_condition_status() {
    local NODE="$1" DISK="$2" CONDITION_TYPE="$3"
    kubectl -n longhorn-system get node.longhorn.io "${NODE}" -o json \
        | jq -r ".status.diskStatus[\"${DISK}\"].conditions[]? | select(.type==\"${CONDITION_TYPE}\") | .status"
}

# disk_is_ready_and_schedulable <node> <disk> - check function for poll_until.
function disk_is_ready_and_schedulable() {
    local NODE="$1" DISK="$2"
    local READY SCHEDULABLE
    READY=$(disk_condition_status "$NODE" "$DISK" "Ready")
    SCHEDULABLE=$(disk_condition_status "$NODE" "$DISK" "Schedulable")
    [[ "$READY" == "True" && "$SCHEDULABLE" == "True" ]]
}

# ---------------------------------------------------------------------------
# Filesystem disks
# ---------------------------------------------------------------------------

# add_filesystem_disks <disks_array_name> - iterates NODES[] and ensures the
# corresponding filesystem disk from the named array (bash nameref) exists on
# each node. Idempotent: existing disks with the same path are left alone.
function add_filesystem_disks() {
    local disks_array_name="$1"
    if [[ -z "$disks_array_name" ]]; then
        log_error "add_filesystem_disks requires a disks-array name (e.g. FILESYSTEM_DISKS)."
        return 1
    fi
    local -n disks_ref="$disks_array_name"

    for i in "${!NODES[@]}"; do
        local NODE="${NODES[i]}"
        local DISK="${disks_ref[i]}"

        if [[ -z "$DISK" ]]; then
            log_warn "No filesystem disk defined for node ${NODE} in ${disks_array_name}, skipping..."
            continue
        fi

        add_filesystem_disk_on_node "$NODE" "$DISK" || die "Failed to add filesystem disk ${DISK} on node ${NODE}."
    done
}

function add_filesystem_disk_on_node() {
    local NODE="$1" DISK_PATH="$2" DISK_NAME="disk-fs"

    if [[ -z "$NODE" || -z "$DISK_PATH" ]]; then
        log_error "Usage: add_filesystem_disk_on_node <node> <disk_path>"
        return 1
    fi

    # Skip patching if a filesystem disk with this exact path already exists
    # (under any name) - avoids clashing with any pre-existing default disk.
    # We still wait for it to be Ready and Schedulable below.
    local EXISTING_KEY
    EXISTING_KEY=$(kubectl -n longhorn-system get node.longhorn.io "${NODE}" -o json \
        | jq -r --arg path "$DISK_PATH" \
            '.spec.disks | to_entries | map(select(.value.path == $path)) | .[0].key // ""')
    if [[ -n "$EXISTING_KEY" ]]; then
        log_ok "Filesystem disk with path '${DISK_PATH}' already exists on node '${NODE}' as '${EXISTING_KEY}'."
        DISK_NAME="$EXISTING_KEY"
    else
        log_step "Adding filesystem disk '${DISK_NAME}' (${DISK_PATH}) to Longhorn node '${NODE}'..."

        local DISK_CONFIG
        DISK_CONFIG=$(cat <<EOF
{
  "path": "${DISK_PATH}",
  "allowScheduling": true,
  "evictionRequested": false,
  "diskType": "filesystem",
  "diskDriver": "",
  "storageReserved": 0
}
EOF
)

        retry_cmd "$RETRY_COUNT" "$RETRY_INTERVAL" "Patch node '${NODE}' to add disk '${DISK_NAME}'" \
            kubectl -n longhorn-system patch node.longhorn.io "${NODE}" \
                --type='json' -p="[{\"op\":\"add\",\"path\":\"/spec/disks/${DISK_NAME}\",\"value\":${DISK_CONFIG}}]" \
            || return 1
    fi

    log_wait "Waiting for filesystem disk '${DISK_NAME}' on node '${NODE}' to be Ready and Schedulable..."
    if poll_until "$RETRY_COUNT" "$RETRY_INTERVAL" "disk '${DISK_NAME}' ready and schedulable" \
        disk_is_ready_and_schedulable "$NODE" "$DISK_NAME"; then
        log_ok "Filesystem disk '${DISK_NAME}' is Ready and Schedulable on node '${NODE}'."
        return 0
    fi

    return 1
}

function enable_filesystem_disks() {
    for NODE in "${NODES[@]}"; do
        enable_filesystem_disks_on_node "$NODE" || return 1
    done
}

function enable_filesystem_disks_on_node() {
    local NODE="$1"
    log_step "Enabling filesystem disks on Longhorn node '${NODE}'..."

    local FILESYSTEM_DISKS
    FILESYSTEM_DISKS=$(spec_disks_by_type "$NODE" "filesystem")
    if [[ -z "$FILESYSTEM_DISKS" ]]; then
        log_ok "No filesystem disks found on node '${NODE}'."
        return 0
    fi

    log_info "Found filesystem disks on node '${NODE}': ${FILESYSTEM_DISKS}"
    for DISK in $FILESYSTEM_DISKS; do
        log_step "Enabling scheduling for filesystem disk '${DISK}' on node '${NODE}'..."
        retry_cmd "$RETRY_COUNT" "$RETRY_INTERVAL" "Enable scheduling for '${DISK}'" \
            kubectl -n longhorn-system patch node.longhorn.io "${NODE}" \
                --type='json' -p="[{\"op\":\"replace\",\"path\":\"/spec/disks/${DISK}/allowScheduling\",\"value\":true}]" \
            || return 1
    done

    log_wait "Verifying filesystem disks status on node '${NODE}'..."
    local VERIFIED=true
    for DISK in $FILESYSTEM_DISKS; do
        log_info "Checking disk '${DISK}' status..."
        if poll_until "$RETRY_COUNT" "$RETRY_INTERVAL" "disk '${DISK}' ready and schedulable" \
            disk_is_ready_and_schedulable "$NODE" "$DISK"; then
            log_ok "Disk '${DISK}' is Ready and Schedulable."
        else
            VERIFIED=false
        fi
    done

    if [[ "$VERIFIED" == true ]]; then
        log_ok "All filesystem disks on node '${NODE}' are successfully enabled and verified!"
    else
        log_warn "Some filesystem disks on node '${NODE}' are not fully ready or schedulable."
        return 1
    fi
}

function disable_filesystem_disks() {
    for NODE in "${NODES[@]}"; do
        disable_filesystem_disks_on_node "$NODE" || return 1
    done
}

function disable_filesystem_disks_on_node() {
    local NODE="$1"
    log_step "Disabling filesystem disks on Longhorn node '${NODE}'..."

    local FILESYSTEM_DISKS
    FILESYSTEM_DISKS=$(spec_disks_by_type "$NODE" "filesystem")
    if [[ -z "$FILESYSTEM_DISKS" ]]; then
        log_ok "No filesystem disks found on node '${NODE}'."
        return 0
    fi

    log_info "Found filesystem disks on node '${NODE}': ${FILESYSTEM_DISKS}"
    for DISK in $FILESYSTEM_DISKS; do
        log_step "Disabling scheduling for filesystem disk '${DISK}' on node '${NODE}'..."
        retry_cmd "$RETRY_COUNT" "$RETRY_INTERVAL" "Disable scheduling for '${DISK}'" \
            kubectl -n longhorn-system patch node.longhorn.io "${NODE}" \
                --type='json' -p="[{\"op\":\"replace\",\"path\":\"/spec/disks/${DISK}/allowScheduling\",\"value\":false}]" \
            || return 1
    done
}

# ---------------------------------------------------------------------------
# Block disks
# ---------------------------------------------------------------------------

function add_block_disks() {
    # add_block_disks <disks_array_name> - iterates NODES[] and adds the
    # corresponding disk from the named array (bash nameref) to each node.
    local disks_array_name="$1"
    if [[ -z "$disks_array_name" ]]; then
        log_error "add_block_disks requires a disks-array name (e.g. V2_NVME_BDEV_DISKS)."
        return 1
    fi
    local -n disks_ref="$disks_array_name"

    for i in "${!NODES[@]}"; do
        local NODE="${NODES[i]}"
        local DISK="${disks_ref[i]}"

        if [[ -z "$DISK" ]]; then
            log_warn "No block disk defined for node ${NODE} in ${disks_array_name}, skipping..."
            continue
        fi

        add_block_disk_on_node "$NODE" "$DISK" || die "Failed to add block disk ${DISK} on node ${NODE}."
    done
}

function add_block_disk_on_node() {
    local NODE="$1" DISK_PATH="$2" DISK_NAME="disk-nvme"

    if [[ -z "$NODE" || -z "$DISK_PATH" ]]; then
        log_error "Usage: add_block_disk_on_node <node> <disk_path>"
        return 1
    fi

    log_step "Adding block disk '${DISK_NAME}' (${DISK_PATH}) to Longhorn node '${NODE}'..."

    local DISK_CONFIG
    DISK_CONFIG=$(cat <<EOF
{
  "path": "${DISK_PATH}",
  "allowScheduling": true,
  "evictionRequested": false,
  "diskType": "block",
  "diskDriver": "",
  "storageReserved": 0
}
EOF
)

    retry_cmd "$RETRY_COUNT" "$RETRY_INTERVAL" "Patch node '${NODE}' to add disk '${DISK_NAME}'" \
        kubectl -n longhorn-system patch node.longhorn.io "${NODE}" \
            --type='json' -p="[{\"op\":\"add\",\"path\":\"/spec/disks/${DISK_NAME}\",\"value\":${DISK_CONFIG}}]" \
        || return 1

    if poll_until "$RETRY_COUNT" "$RETRY_INTERVAL" "disk '${DISK_NAME}' ready and schedulable" \
        disk_is_ready_and_schedulable "$NODE" "$DISK_NAME"; then
        log_ok "Block disk '${DISK_NAME}' is Ready and Schedulable on node '${NODE}'."
        return 0
    fi

    return 1
}

function delete_block_disks() {
    for NODE in "${NODES[@]}"; do
        delete_block_disks_on_node "$NODE" || return 1
    done
}

# no_block_disks_remain <node> - check function for poll_until.
function no_block_disks_remain() {
    local NODE="$1"
    [[ -z "$(status_disks_by_type "$NODE" "block")" ]]
}

function delete_block_disks_on_node() {
    local NODE="$1"
    log_step "Removing block disks from Longhorn node '${NODE}'..."

    local BLOCK_DISKS
    BLOCK_DISKS=$(spec_disks_by_type "$NODE" "block")
    if [[ -z "$BLOCK_DISKS" ]]; then
        log_ok "No block disks found on node '${NODE}'. Nothing to remove."
        return 0
    fi

    log_info "Found block disks on node '${NODE}': ${BLOCK_DISKS}"

    for DISK in $BLOCK_DISKS; do
        log_step "Disabling scheduling and requesting eviction for block disk '${DISK}'..."
        retry_cmd "$RETRY_COUNT" "$RETRY_INTERVAL" "Disable scheduling / request eviction for '${DISK}'" \
            kubectl -n longhorn-system patch node.longhorn.io "${NODE}" \
                --type='json' -p="[{\"op\":\"replace\",\"path\":\"/spec/disks/${DISK}/allowScheduling\",\"value\":false},{\"op\":\"replace\",\"path\":\"/spec/disks/${DISK}/evictionRequested\",\"value\":true}]" \
            || return 1

        log_step "Removing block disk '${DISK}' from node '${NODE}'..."
        retry_cmd "$RETRY_COUNT" "$RETRY_INTERVAL" "Remove block disk '${DISK}'" \
            kubectl -n longhorn-system patch node.longhorn.io "${NODE}" \
                --type='json' -p="[{\"op\":\"remove\",\"path\":\"/spec/disks/${DISK}\"}]" \
            || return 1
    done

    log_wait "Waiting for Longhorn to reconcile node '${NODE}'..."
    if poll_until "$RETRY_COUNT" "$RETRY_INTERVAL" "block disks removed from '${NODE}'" \
        no_block_disks_remain "$NODE"; then
        log_ok "All block disks have been successfully removed from node '${NODE}'!"
        return 0
    fi

    log_warn "Remaining block disks: $(status_disks_by_type "$NODE" "block")"
    return 1
}

# ---------------------------------------------------------------------------
# Node scheduling
# ---------------------------------------------------------------------------

function enable_node_scheduling() {
    for NODE in "${NODES[@]}"; do
        enable_node_scheduling_on_node "$NODE"
    done
}

function enable_node_scheduling_on_node() {
    local NODE="$1"
    log_step "Enabling node scheduling for node ${NODE}..."
    kubectl -n longhorn-system patch node.longhorn.io "${NODE}" \
        --type='json' -p='[{"op":"replace","path":"/spec/allowScheduling","value":true}]'
}
