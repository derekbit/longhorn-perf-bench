#!/bin/bash

LOCAL_PATH_PROVISIONER_VERSION="0.0.32"
LOCAL_PATH_PROVISIONER_DISK_PATH="/mnt/local-path-provisioner"

NODES=("inst-1ru91-dereksu-nvme" "inst-bcoj9-dereksu-nvme" "inst-hljkq-dereksu-nvme")
BLOCK_TYPE_DISKS=("0000:00:04.0" "0000:00:04.0" "0000:00:05.0")
CPU_MASKS=("0x1" "0x3" "0xF" "0x3F" "0xFF")

function install_local_path_provisioner() {
    echo "Installing local-path provisioner..."
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml

    # List pods in the namespace local-path-storage
    local PODS=$(kubectl get pods -n local-path-storage -o jsonpath="{.items[*].metadata.name}")
    # Wait for the provisioner to be ready
    for POD in "${PODS[@]}"; do
        echo "⏳ Waiting for pod $POD to be ready..."
        kubectl wait --for=condition=Ready pod/$POD -n local-path-storage --timeout=300s
        if [ $? -ne 0 ]; then
            echo "❌ Error: Pod $POD in namespace local-path-storage is not ready after 300 seconds."
            exit 1
        fi
    done
}

function wait_for_instance_manager_ready() {
    local DATA_ENGINE=$1
    echo "⏳ Waiting for ${DATA_ENGINE} data engine instance manager to be ready..."
    local PODS=$(kubectl -n longhorn-system get pods -l longhorn.io/component=${DATA_ENGINE}-instance-manager -l longhorn.io/data-engine=${DATA_ENGINE} -o jsonpath="{.items[*].metadata.name}")
    for POD in $PODS; do
        echo "⏳ Waiting for pod $POD to be ready..."
        kubectl -n longhorn-system wait --for=condition=Ready pod/$POD -n longhorn-system --timeout=300s
        if [ $? -ne 0 ]; then
            echo "❌ Error: Pod $POD for ${DATA_ENGINE} data engine is not ready after 300 seconds."
            exit 1
        fi
    done
}

function wait_for_instance_manager_terminated() {
    local DATA_ENGINE=$1

    echo "⏳ Waiting for ${DATA_ENGINE} data engine instance manager to terminate..."

    local TIMEOUT=300
    local INTERVAL=5
    local ELAPSED=0

    while [ $ELAPSED -lt $TIMEOUT ]; do
        local PODS=$(kubectl -n longhorn-system get pods -l longhorn.io/component=${DATA_ENGINE}-instance-manager -l longhorn.io/data-engine=${DATA_ENGINE} -o jsonpath="{.items[*].metadata.name}")
        if [ -z "$PODS" ]; then
            echo "All ${DATA_ENGINE} data engine instance manager pods have terminated."
            return
        fi
        echo "⏳ Waiting for pods to terminate: $PODS"
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done

    echo "❌ Error: Timeout waiting for ${DATA_ENGINE} data engine instance manager pods to terminate."
    exit 1
}

function enable_data_engine() {
    local DATA_ENGINE=$1
    kubectl -n longhorn-system patch setting.longhorn.io ${DATA_ENGINE}-data-engine --type=merge -p "{\"value\":\"true\"}"
    if [ $? -ne 0 ]; then
        echo "❌ Error: Failed to enable ${DATA_ENGINE} data engine."
        exit 1
    fi

    wait_for_instance_manager_ready $DATA_ENGINE
}

function disable_data_engine() {
    local DATA_ENGINE=$1
    kubectl -n longhorn-system patch setting.longhorn.io ${DATA_ENGINE}-data-engine --type=merge -p "{\"value\":\"false\"}"
    if [ $? -ne 0 ]; then
        echo "❌ Error: Failed to disable ${DATA_ENGINE} data engine."
        exit 1
    fi

   wait_for_instance_manager_terminated $DATA_ENGINE
}

function update_data_engine_cpu_mask() {
    local CPU_MASK=$1
    kubectl -n longhorn-system patch setting.longhorn.io data-engine-cpu-mask --type=merge -p "{\"value\":\"${CPU_MASK}\"}"
    if [ $? -ne 0 ]; then
        echo "❌ Error: Failed to update data engine CPU mask."
        exit 1
    fi

   wait_for_instance_manager_terminated v2
   wait_for_instance_manager_ready v2
}

function disable_node_scheduling() {
    local NODE=$1

    echo "⚙️ Disabling node scheduling for ${DATA_ENGINE} data engine..."
    kubectl -n longhorn-system patch node.longhorn.io "${NODE}" \
      --type='json' \
      -p='[{"op":"replace","path":"/spec/allowScheduling","value":false}]'
}

function enable_filesystem_disks() {
    for NODE in "${NODES[@]}"; do
        enable_filesystem_disks_on_node "$NODE" || return 1
    done
}

function enable_filesystem_disks_on_node() {
    local NODE="$1"
    echo "⚙️ Enabling filesystem disks on Longhorn node '${NODE}'..."

    local FILESYSTEM_DISKS
    FILESYSTEM_DISKS=$(kubectl -n longhorn-system get node.longhorn.io "${NODE}" -o jsonpath='{.spec.disks}' \
      | yq -r 'to_entries | map(select(.value.diskType == "filesystem")) | .[].key')

    if [[ -z "$FILESYSTEM_DISKS" ]]; then
        echo "✅ No filesystem disks found on node '${NODE}'."
        return
    fi

    echo "🔍 Found filesystem disks on node '${NODE}': ${FILESYSTEM_DISKS}"
    for DISK in "${FILESYSTEM_DISKS[@]}"; do
        echo "🟢 Enabling scheduling for filesystem disk '${DISK}' on node '${NODE}'..."

        local SUCCESS=false
        local RETRIES=60
        local SLEEP_INTERVAL=5

        for ((i=1; i<=RETRIES; i++)); do
            if kubectl -n longhorn-system patch node.longhorn.io "${NODE}" \
              --type='json' \
              -p="[ {\"op\":\"replace\", \"path\":\"/spec/disks/${DISK}/allowScheduling\", \"value\":true} ]" >/dev/null 2>&1; then
                echo "✅ Successfully enabled scheduling for '${DISK}' (attempt ${i}/${RETRIES})"
                SUCCESS=true
                break
            else
                echo "⚠️  Patch failed for '${DISK}' (attempt ${i}/${RETRIES}), retrying in ${SLEEP_INTERVAL}s..."
                sleep "$SLEEP_INTERVAL"
            fi
        done

        if [[ "$SUCCESS" == false ]]; then
            echo "❌ Failed to enable scheduling for '${DISK}' after ${RETRIES} attempts."
            return 1
        fi
    done

    echo "⏳ Verifying filesystem disks status on node '${NODE}'..."
    local VERIFIED=true

    for DISK in "${FILESYSTEM_DISKS[@]}"; do
        echo "🔎 Checking disk '${DISK}' status..."
        local READY_STATUS SCHEDULABLE_STATUS
        READY_STATUS=$(kubectl -n longhorn-system get node.longhorn.io "${NODE}" -o json \
          | jq -r ".status.diskStatus[\"${DISK}\"].conditions[] | select(.type==\"Ready\") | .status")
        SCHEDULABLE_STATUS=$(kubectl -n longhorn-system get node.longhorn.io "${NODE}" -o json \
          | jq -r ".status.diskStatus[\"${DISK}\"].conditions[] | select(.type==\"Schedulable\") | .status")

        if [[ "$READY_STATUS" != "True" || "$SCHEDULABLE_STATUS" != "True" ]]; then
            echo "❌ Disk '${DISK}' verification failed. Ready=${READY_STATUS}, Schedulable=${SCHEDULABLE_STATUS}"
            VERIFIED=false
        else
            echo "✅ Disk '${DISK}' is Ready and Schedulable."
        fi
    done

    if [[ "$VERIFIED" == true ]]; then
        echo "🎉 All filesystem disks on node '${NODE}' are successfully enabled and verified!"
    else
        echo "⚠️ Some filesystem disks on node '${NODE}' are not fully ready or schedulable."
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
    echo "⚙️ Disabling filesystem disks on Longhorn node '${NODE}'..."

    local FILESYSTEM_DISKS
    FILESYSTEM_DISKS=$(kubectl -n longhorn-system get node.longhorn.io "${NODE}" -o jsonpath='{.spec.disks}' \
      | yq -r 'to_entries | map(select(.value.diskType == "filesystem")) | .[].key')

    if [[ -z "$FILESYSTEM_DISKS" ]]; then
        echo "✅ No filesystem disks found on node '${NODE}'."
        return
    fi

    echo "🔍 Found filesystem disks on node '${NODE}': ${FILESYSTEM_DISKS}"

    for DISK in "${FILESYSTEM_DISKS[@]}"; do
        echo "🛑 Disabling scheduling for filesystem disk '${DISK}' on node '${NODE}'..."

        local SUCCESS=false
        local RETRIES=60
        local SLEEP_INTERVAL=5

        for ((i=1; i<=RETRIES; i++)); do
            if kubectl -n longhorn-system patch node.longhorn.io "${NODE}" \
              --type='json' \
              -p="[ {\"op\":\"replace\", \"path\":\"/spec/disks/${DISK}/allowScheduling\", \"value\":false} ]" >/dev/null 2>&1; then
                echo "✅ Successfully disabled scheduling for '${DISK}' (attempt ${i}/${RETRIES})"
                SUCCESS=true
                break
            else
                echo "⚠️  Patch failed for '${DISK}' (attempt ${i}/${RETRIES}), retrying in ${SLEEP_INTERVAL}s..."
                sleep "$SLEEP_INTERVAL"
            fi
        done

        if [[ "$SUCCESS" == false ]]; then
            echo "❌ Failed to disable scheduling for '${DISK}' after ${RETRIES} attempts."
            return 1
        fi
    done
}

function add_block_disks() {
    for i in "${!NODES[@]}"; do
        local NODE="${NODES[i]}"
        local DISK="${BLOCK_TYPE_DISKS[i]}"

        if [[ -z "$DISK" ]]; then
            echo "Warning: No block disk defined for node $NODE, skipping..."
            continue
        fi

        if ! add_block_disk_on_node "$NODE" "$DISK"; then
            echo "❌ Error: Failed to add block disk $DISK on node $NODE"
            return 1
        fi
    done
}

function add_block_disk_on_node() {
    local NODE="$1"
    local DISK_PATH="$2"   # e.g. /dev/nvme1n1
    local DISK_NAME="disk-nvme"

    echo "⚙️ Adding block disk '${DISK_NAME}' (${DISK_PATH}) to Longhorn node '${NODE}'..."

    if [[ -z "$NODE" || -z "$DISK_PATH" ]]; then
        echo "❌ Usage: add_block_disk_on_node <node> <disk_path>"
        return 1
    fi

    # Define the disk configuration
    local DISK_CONFIG
    DISK_CONFIG=$(cat <<EOF
{
  "path": "${DISK_PATH}",
  "allowScheduling": true,
  "evictionRequested": false,
  "diskType": "block",
  "diskDriver": "",
  "storageReserved": 0,
}
EOF
)

    local RETRIES=60
    local SLEEP_INTERVAL=5

    # Patch the node to add the new block disk
    local PATCH_SUCCESS=false

    for ((i=1; i<=RETRIES; i++)); do
        echo "Patching node '${NODE}' to add block disk '${DISK_NAME}' (attempt ${i}/${RETRIES})..."
        if kubectl -n longhorn-system patch node.longhorn.io "${NODE}" \
            --type='json' \
            -p="[ {\"op\":\"add\", \"path\":\"/spec/disks/${DISK_NAME}\", \"value\":${DISK_CONFIG}} ]" >/dev/null 2>&1; then
            PATCH_SUCCESS=true
            echo "✅ Successfully patched node '${NODE}' with disk '${DISK_NAME}'."
            break
        else
            echo "⚠️ Patch failed for '${DISK_NAME}' (attempt ${i}/${RETRIES}), retrying in ${SLEEP_INTERVAL}s..."
            sleep "$SLEEP_INTERVAL"
        fi
    done

    if [[ "$PATCH_SUCCESS" != true ]]; then
        echo "❌ Failed to patch node '${NODE}' with disk '${DISK_NAME}' after ${RETRIES} attempts."
        return 1
    fi

    # Verify disk status
    # echo "⏳ Waiting for disk '${DISK_NAME}' to become Ready and Schedulable..."
    for ((i=1; i<=RETRIES; i++)); do
        local READY_STATUS SCHEDULABLE_STATUS
        READY_STATUS=$(kubectl -n longhorn-system get node.longhorn.io "${NODE}" -o json \
          | jq -r ".status.diskStatus[\"${DISK_NAME}\"].conditions[] | select(.type==\"Ready\") | .status")
        SCHEDULABLE_STATUS=$(kubectl -n longhorn-system get node.longhorn.io "${NODE}" -o json \
          | jq -r ".status.diskStatus[\"${DISK_NAME}\"].conditions[] | select(.type==\"Schedulable\") | .status")

        if [[ "$READY_STATUS" == "True" && "$SCHEDULABLE_STATUS" == "True" ]]; then
            echo "✅ Block disk '${DISK_NAME}' is Ready and Schedulable on node '${NODE}'."
            return 0
        fi

        # echo "⏳ Waiting for disk '${DISK_NAME}' to become ready... (${i}/${RETRIES})"
        sleep "$SLEEP_INTERVAL"
    done

    echo "❌ Timeout waiting for block disk '${DISK_NAME}' to become ready on node '${NODE}'."
    return 1
}

function delete_block_disks() {
    for NODE in "${NODES[@]}"; do
        delete_block_disks_on_node "$NODE" || return 1
    done
}

function delete_block_disks_on_node() {
    local NODE="$1"
    echo "⚙️ Removing block disks from Longhorn node '${NODE}'..."

    local BLOCK_DISKS
    BLOCK_DISKS=$(kubectl -n longhorn-system get node.longhorn.io "${NODE}" -o jsonpath='{.spec.disks}' \
      | yq -r 'to_entries | map(select(.value.diskType == "block")) | .[].key')

    if [[ -z "$BLOCK_DISKS" ]]; then
        echo "✅ No block disks found on node '${NODE}'. Nothing to remove."
        return
    fi

    local RETRIES=60
    local SLEEP_INTERVAL=5

    echo "🔍 Found block disks on node '${NODE}': ${BLOCK_DISKS}"

    for DISK in ${BLOCK_DISKS[@]}; do
        echo "🛑 Disabling scheduling and requesting eviction for block disk '${DISK}'..."
        for ((r=1; r<=RETRIES; r++)); do
            kubectl -n longhorn-system patch node.longhorn.io "${NODE}" \
              --type='json' \
              -p="[ {\"op\":\"replace\", \"path\":\"/spec/disks/${DISK}/allowScheduling\", \"value\":false}, {\"op\":\"replace\", \"path\":\"/spec/disks/${DISK}/evictionRequested\", \"value\":true} ]"
            if [[ $? -eq 0 ]]; then
                echo "✅ Successfully disabled scheduling and requested eviction for '${DISK}'."
                break
            fi
            echo "⚠️ Failed to patch (attempt ${r}/${RETRIES}), retrying in ${SLEEP_INTERVAL}s..."
            sleep "$SLEEP_INTERVAL"
            if [[ $r -eq $RETRIES ]]; then
                echo "❌ Failed to disable scheduling for '${DISK}' after ${RETRIES} attempts."
            fi
        done

        echo "🧹 Removing block disk '${DISK}' from node '${NODE}'..."
        for ((r=1; r<=RETRIES; r++)); do
            kubectl -n longhorn-system patch node.longhorn.io "${NODE}" \
              --type='json' \
              -p="[ {\"op\":\"remove\", \"path\":\"/spec/disks/${DISK}\"} ]"
            if [[ $? -eq 0 ]]; then
                echo "✅ Successfully removed block disk '${DISK}'."
                break
            fi
            echo "⚠️ Failed to remove block disk (attempt ${r}/${RETRIES}), retrying in ${SLEEP_INTERVAL}s..."
            sleep "$SLEEP_INTERVAL"
            if [[ $r -eq $RETRIES ]]; then
                echo "❌ Failed to remove block disk '${DISK}' after ${RETRIES} attempts."
            fi
        done
    done

    echo "⏳ Waiting for Longhorn to reconcile node '${NODE}'..."
    local REMAINING_BLOCK_DISKS=""

    for ((i=1; i<=RETRIES; i++)); do
        REMAINING_BLOCK_DISKS=$(kubectl -n longhorn-system get node.longhorn.io "${NODE}" -o json \
          | yq -r '.status.diskStatus | to_entries | map(select(.value.diskType == "block")) | .[].key')

        if [[ -z "$REMAINING_BLOCK_DISKS" ]]; then
            echo "✅ All block disks have been successfully removed from node '${NODE}'!"
            return 0
        fi

        echo "⏱️ Still found block disks (${REMAINING_BLOCK_DISKS}), retrying... (${i}/${RETRIES})"
        sleep "$SLEEP_INTERVAL"
    done

    echo "❌ Timeout waiting for block disks to be removed from node '${NODE}'."
    echo "⚠️ Remaining block disks: ${REMAINING_BLOCK_DISKS}"
    return 1
}

function enable_node_scheduling() {
    for NODE in "${NODES[@]}"; do
        enable_node_scheduling_on_node "$NODE"
    done
}

function enable_node_scheduling_on_node() {
    local NODE=$1

    echo "Enabling node scheduling for node $NODE..."
    kubectl -n longhorn-system patch node.longhorn.io "${NODE}" \
      --type='json' \
      -p='[{"op":"replace","path":"/spec/allowScheduling","value":true}]'
}

function wait_for_fio_pods_completed() {
    echo "⏳ Waiting for fio pods to be completed..."

    PODS=$(kubectl get pods -o jsonpath="{.items[*].metadata.name}")
    for POD in "${PODS[@]}"; do
        echo "⏳ Waiting for fio pod $POD to be completed..."
        while true; do
            PHASE=$(kubectl get pod "$POD" -o jsonpath='{.status.phase}')
            if [[ "$PHASE" == "Succeeded" || "$PHASE" == "Failed" ]]; then
                break
            fi
            sleep 5
        done
    done

    # Output the log of the pod
    for POD in "${PODS[@]}"; do
        echo "Logs for fio pod $POD:"
        kubectl logs $POD
    done
}

function terminate_fio_pods() {
    echo "Terminating fio pods..."
    kubectl delete -f fio.yaml

    # Wait for fio pods to be deleted
    local TIMEOUT=60
    local INTERVAL=5
    local ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        local PODS=$(kubectl get pods -o jsonpath="{.items[*].metadata.name}" | grep fio || true)
        if [ -z "$PODS" ]; then
            echo "All fio pods have been terminated."
            return
        fi
        echo "⏳ Waiting for fio pods to terminate: $PODS"
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done
}

function set_fio_pvc_storage_class() {
    local STORAGE_CLASS="$1"
    export STORAGE_CLASS
    if ! yq -i '
      ( select(.kind == "PersistentVolumeClaim") | .spec.storageClassName ) = strenv(STORAGE_CLASS)
      | .
    ' fio.yaml; then
        echo "❌ Error: Failed to patch fio.yaml with storageClassName."
        exit 1
    fi
}


function set_fio_running_node() {
    local NODE="$1"
    export NODE
    if ! yq -i '
      ( select(.kind == "Job") | .spec.template.spec.nodeName ) = strenv(NODE)
      | .
    ' fio.yaml; then
        echo "❌ Error: Failed to patch fio.yaml with nodeName."
        exit 1
    fi
}

function run_fio() {
    local STORAGE_CLASS="$1"
    local NODE="$2"

    set_fio_pvc_storage_class ${STORAGE_CLASS} || exit 1
    set_fio_running_node ${NODE} || exit 1

    kubectl apply -f fio.yaml
    if [ $? -ne 0 ]; then
        echo "❌ Error: Failed to apply fio.yaml."
        exit 1
    fi

    wait_for_fio_pods_completed 
}

function reset_environment() {
    # Enable both data engines first to ensure proper cleanup
    terminate_fio_pods
    enable_data_engine "v1" || exit 1
    enable_data_engine "v2" || exit 1
    enable_filesystem_disks || exit 1
    delete_block_disks || exit 1
    enable_node_scheduling || exit 1
}

function benchmark_v1_r3_volume() {
    reset_environment

    # Enable v1 data engine
    disable_data_engine "v2" || exit 1
    enable_data_engine "v1" || exit 1
    enable_filesystem_disks || exit 1

    run_fio "longhorn-v1-r3" "${NODES[0]}" || exit 1
}

function benchmark_v1_r1_volume() {
    reset_environment

    # Enable v1 data engine
    disable_data_engine "v2" || exit 1
    enable_data_engine "v1" || exit 1
    disable_filesystem_disks || exit 1
    enable_filesystem_disks_on_node "${NODES[0]}" || exit 1

    run_fio "longhorn-v1-r1" "${NODES[0]}" || exit 1
}

function benchmark_v1_r1_crossnode_volume() {
    reset_environment

    # Enable v1 data engine
    disable_data_engine "v2" || exit 1
    enable_data_engine "v1" || exit 1
    disable_filesystem_disks || exit 1
    enable_filesystem_disks_on_node "${NODES[1]}" || exit 1

    run_fio "longhorn-v1-r1" "${NODES[0]}" || exit 1
}

function benchmark_v2_r3_volume() {
    local CPU_MASK="$1"

    reset_environment

    # Set CPU mask for v2 data engine
    disable_data_engine "v2" || exit 1
    update_data_engine_cpu_mask "$CPU_MASK" || exit 1

    # Enable v2 data engine
    enable_data_engine "v2" || exit 1
    add_block_disks || exit 1

    run_fio "longhorn-v2-r3" "${NODES[0]}" || exit 1
}

function benchmark_v2_r1_volume() {
    local CPU_MASK="$1"

    reset_environment

    # Set CPU mask for v2 data engine
    disable_data_engine "v2" || exit 1
    update_data_engine_cpu_mask "$CPU_MASK" || exit 1

    # Enable v2 data engine
    enable_data_engine "v2" || exit 1
    add_block_disk_on_node "${NODES[0]}" "${BLOCK_TYPE_DISKS[0]}" || exit 1

    run_fio "longhorn-v2-r1" "${NODES[0]}" || exit 1
}

function benchmark_v2_r1_crossnode_volume() {
    local CPU_MASK="$1"

    reset_environment

    # Set CPU mask for v2 data engine
    disable_data_engine "v2" || exit 1
    update_data_engine_cpu_mask "$CPU_MASK" || exit 1

    # Enable v2 data engine
    enable_data_engine "v2" || exit 1
    add_block_disk_on_node "${NODES[1]}" "${BLOCK_TYPE_DISKS[1]}" || exit 1

    run_fio "longhorn-v2-r1" "${NODES[0]}" || exit 1
}

# ============ Main Logic ============
echo "⚙️ Resetting Longhorn storage classes..."
kubectl delete -f storageclass/
kubectl apply -f storageclass/

echo "⚙️ Installing local-path provisioner..."
install_local_path_provisioner || exit 1

echo "🏃🏃🏃 Benchmarking v1 3-replicas volume..."
benchmark_v1_r3_volume || exit 1

echo "🏃🏃🏃 Benchmarking v1 1-replicas volume..."
benchmark_v1_r1_volume || exit 1

echo "🏃🏃🏃 Benchmarking v1 1-replicas cross-node volume..."
benchmark_v1_r1_crossnode_volume || exit 1

for CPU_MASK in "${CPU_MASKS[@]}"; do
    echo "🏃🏃🏃 Benchmarking v2 3-replicas volume with CPU mask ${CPU_MASK}..."
    benchmark_v2_r3_volume "${CPU_MASK}" || exit 1
done

for CPU_MASK in "${CPU_MASKS[@]}"; do
    echo "🏃🏃🏃 Benchmarking v2 1-replica volume with CPU mask ${CPU_MASK}..."
    benchmark_v2_r1_volume "${CPU_MASK}" || exit 1
done

for CPU_MASK in "${CPU_MASKS[@]}"; do
    echo "🏃🏃🏃 Benchmarking v2 1-replica cross-node volume with CPU mask ${CPU_MASK}..."
    benchmark_v2_r1_crossnode_volume "${CPU_MASK}" || exit 1
done
