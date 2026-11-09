#!/bin/bash
# =============================================================================
# etcd MVCC Exhaustion Demo
# Reproduces the "death by a thousand patches" failure mode
#
# Prerequisites: kind, kubectl, Docker, Python 3
# Usage: ./demo.sh [scenario]
#   scenarios: guided | setup | break | monitor | recover | guardrails | cleanup
#              offline-prep | offline-check | offline-export | offline-import
# =============================================================================

set -euo pipefail
CLUSTER_NAME="etcd-mvcc-demo"
NAMESPACE="mvcc-demo"
REQUESTED_SCENARIO="${1:-}"

# Stage-tuned defaults. Override at runtime, e.g.:
#   STATUS_REPLICAS=60 STATUS_PAYLOAD_BYTES=65536 ./demo.sh break
STATUS_REPLICAS="${STATUS_REPLICAS:-80}"
STATUS_PAYLOAD_BYTES="${STATUS_PAYLOAD_BYTES:-98304}"
STATUS_PARALLELISM="${STATUS_PARALLELISM:-20}"
STATUS_DEADLINE_SECONDS="${STATUS_DEADLINE_SECONDS:-90}"
STATUS_PATCH_TYPE="${STATUS_PATCH_TYPE:-strategic}"
STATUS_IMAGE="${STATUS_IMAGE:-registry.k8s.io/pause:3.10}"
TEST_IMAGE="${TEST_IMAGE:-busybox:latest}"
RESET_CLUSTER="${RESET_CLUSTER:-0}"
PRELOAD_IMAGES="${PRELOAD_IMAGES:-0}"
OFFLINE_ASSETS_DIR="${OFFLINE_ASSETS_DIR:-offline-assets}"
OFFLINE_IMAGE_TAR="${OFFLINE_IMAGE_TAR:-$OFFLINE_ASSETS_DIR/demo-images.tar}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"
DEMO_IMAGE_PLATFORM="${DEMO_IMAGE_PLATFORM:-}"
DETECTED_IMAGE_PLATFORM=""
if [[ -z "${DEMO_PROMPT:-}" ]]; then
    if [[ -z "$REQUESTED_SCENARIO" || "$REQUESTED_SCENARIO" == "guided" ]]; then
        DEMO_PROMPT=1
    else
        DEMO_PROMPT=0
    fi
fi
if [[ -z "${DEMO_COMMAND_PAUSE:-}" ]]; then
    if [[ "$DEMO_PROMPT" == "1" ]]; then
        DEMO_COMMAND_PAUSE=major
    else
        DEMO_COMMAND_PAUSE=0
    fi
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[DEMO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[FAIL]${NC} $1"; }
print_cmd() { echo -e "${YELLOW}$ $*${NC}"; }
pause_before_command() {
    local pause_level="${1:-normal}"

    if [[ ! -t 0 ]]; then
        return 0
    fi

    case "$DEMO_COMMAND_PAUSE:$pause_level" in
        1:*|all:*|major:major) ;;
        *) return 0 ;;
    esac

    local _
    read -r -p "Press Enter to run this command..." _
}
show_cmd() {
    print_cmd "$@"
    pause_before_command normal
}
show_key_cmd() {
    print_cmd "$@"
    pause_before_command major
}

show_metrics_cmd() {
    show_cmd "curl -sk https://localhost:2379/metrics | grep -E '^etcd_mvcc_db_total_size_in_bytes |^etcd_mvcc_db_total_size_in_use_in_bytes |^etcd_server_quota_backend_bytes '"
}

confirm_action() {
    local title="$1"
    shift

    echo ""
    warn "$title"
    for line in "$@"; do
        echo "  - $line"
    done

    if [[ "$DEMO_PROMPT" == "0" || ! -t 0 ]]; then
        return 0
    fi

    local reply
    read -r -p "Continue? [y/N] " reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) err "Aborted."; exit 1 ;;
    esac
    echo ""
}

ask_yes_no() {
    local title="$1"
    shift

    echo ""
    warn "$title"
    for line in "$@"; do
        echo "  - $line"
    done

    if [[ "$DEMO_PROMPT" == "0" || ! -t 0 ]]; then
        return 1
    fi

    local reply
    read -r -p "Run this step? [y/N] " reply
    case "$reply" in
        y|Y|yes|YES) echo ""; return 0 ;;
        *) echo ""; return 1 ;;
    esac
}

docker_image_exists() {
    docker image inspect "$1" >/dev/null 2>&1
}

docker_image_local_platform() {
    docker image inspect "$1" --format '{{.Os}}/{{.Architecture}}' 2>/dev/null || true
}

normalize_arch() {
    case "$1" in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) echo "$1" ;;
    esac
}

demo_image_platform() {
    if [[ -n "$DETECTED_IMAGE_PLATFORM" ]]; then
        echo "$DETECTED_IMAGE_PLATFORM"
        return 0
    fi

    if [[ -n "$DEMO_IMAGE_PLATFORM" ]]; then
        DETECTED_IMAGE_PLATFORM="$DEMO_IMAGE_PLATFORM"
        echo "$DETECTED_IMAGE_PLATFORM"
        return 0
    fi

    local os arch
    if os=$(docker inspect "${CLUSTER_NAME}-control-plane" --format '{{.Os}}' 2>/dev/null) &&
       arch=$(docker inspect "${CLUSTER_NAME}-control-plane" --format '{{.Architecture}}' 2>/dev/null) &&
       [[ -n "$os" && -n "$arch" ]]; then
        DETECTED_IMAGE_PLATFORM="$os/$(normalize_arch "$arch")"
        echo "$DETECTED_IMAGE_PLATFORM"
        return 0
    fi

    if os=$(docker info --format '{{.OSType}}' 2>/dev/null) &&
       arch=$(docker info --format '{{.Architecture}}' 2>/dev/null) &&
       [[ -n "$os" && -n "$arch" ]]; then
        DETECTED_IMAGE_PLATFORM="$os/$(normalize_arch "$arch")"
        echo "$DETECTED_IMAGE_PLATFORM"
        return 0
    fi

    DETECTED_IMAGE_PLATFORM="linux/$(normalize_arch "$(uname -m)")"
    echo "$DETECTED_IMAGE_PLATFORM"
}

docker_pull_image() {
    local image="$1"
    local platform
    platform="$(demo_image_platform)"
    show_cmd "docker pull --platform=$platform $image"
    docker pull --platform="$platform" "$image"
}

save_platform_image_archive() {
    local image="$1"
    local archive="$2"
    local platform
    platform="$(demo_image_platform)"
    show_cmd "docker save --platform=$platform -o $archive $image"
    docker save --platform="$platform" -o "$archive" "$image"
}

kind_cluster_exists() {
    kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}

add_unique_image() {
    local image="$1"
    local existing
    for existing in "${DEMO_IMAGES[@]:-}"; do
        [[ -z "$existing" ]] && continue
        if [[ "$existing" == "$image" ]]; then
            return 0
        fi
    done
    DEMO_IMAGES+=("$image")
}

collect_workload_images() {
    DEMO_IMAGES=()
    add_unique_image "$STATUS_IMAGE"
    add_unique_image "$TEST_IMAGE"
}

collect_export_images() {
    collect_workload_images
    if [[ -n "$KIND_NODE_IMAGE" ]]; then
        add_unique_image "$KIND_NODE_IMAGE"
    fi
}

create_kind_cluster() {
    if [[ -n "$KIND_NODE_IMAGE" ]]; then
        show_key_cmd "kind create cluster --config kind-config.yaml --image $KIND_NODE_IMAGE --wait 60s"
        kind create cluster --config kind-config.yaml --image "$KIND_NODE_IMAGE" --wait 60s
    else
        show_key_cmd "kind create cluster --config kind-config.yaml --wait 60s"
        kind create cluster --config kind-config.yaml --wait 60s
    fi
}

load_images_into_kind() {
    if ! kind_cluster_exists; then
        warn "kind cluster '$CLUSTER_NAME' does not exist yet; skipping kind image preload."
        return 0
    fi

    collect_workload_images
    local nodes
    nodes=$(kind get nodes --name "$CLUSTER_NAME" 2>/dev/null |
        grep -v -- '-control-plane$' |
        paste -sd, - || true)

    if [[ -z "$nodes" ]]; then
        warn "No worker nodes found; loading images into all kind nodes."
    else
        log "Preloading images into worker nodes: $nodes"
    fi

    mkdir -p "$OFFLINE_ASSETS_DIR"

    local failures=0
    local image
    for image in "${DEMO_IMAGES[@]}"; do
        if docker_image_exists "$image"; then
            local archive
            archive=$(mktemp "$OFFLINE_ASSETS_DIR/kind-load.XXXXXX")
            if ! save_platform_image_archive "$image" "$archive"; then
                warn "Could not create a $(demo_image_platform) archive for $image."
                rm -f "$archive"
                failures=$((failures + 1))
                continue
            fi
            if [[ -n "$nodes" ]]; then
                show_cmd "kind load image-archive $archive --name $CLUSTER_NAME --nodes $nodes"
                if ! kind load image-archive "$archive" --name "$CLUSTER_NAME" --nodes "$nodes"; then
                    warn "Could not preload $image into worker nodes."
                    failures=$((failures + 1))
                fi
            else
                show_cmd "kind load image-archive $archive --name $CLUSTER_NAME"
                if ! kind load image-archive "$archive" --name "$CLUSTER_NAME"; then
                    warn "Could not preload $image into kind."
                    failures=$((failures + 1))
                fi
            fi
            rm -f "$archive"
        else
            warn "Image not present locally, cannot preload into kind: $image"
            failures=$((failures + 1))
        fi
    done

    if (( failures > 0 )); then
        err "Image preload failed for $failures image(s)."
        warn "The script already pulled images for platform $(demo_image_platform)."
        warn "If Docker has a stale image cache, remove the affected image and rerun './demo.sh offline-prep'."
        return 1
    fi
}

offline_preflight() {
    log "=== Offline Demo Preflight ==="
    log "Checks Docker image cache and kind readiness without downloading anything."

    local failures=0

    collect_workload_images
    local image
    local expected_platform
    expected_platform="$(demo_image_platform)"
    for image in "${DEMO_IMAGES[@]}"; do
        show_cmd "docker image inspect $image"
        if docker_image_exists "$image"; then
            local local_platform
            local_platform="$(docker_image_local_platform "$image")"
            if [[ "$local_platform" == "$expected_platform" ]]; then
                log "Image cached locally for $local_platform: $image"
            else
                err "Image cached for '$local_platform', expected '$expected_platform': $image"
                failures=$((failures + 1))
            fi
        else
            err "Missing local image: $image"
            failures=$((failures + 1))
        fi
    done

    if kind_cluster_exists; then
        log "kind cluster '$CLUSTER_NAME' already exists."
    elif [[ -n "$KIND_NODE_IMAGE" ]]; then
        show_cmd "docker image inspect $KIND_NODE_IMAGE"
        if docker_image_exists "$KIND_NODE_IMAGE"; then
            log "kind node image cached locally: $KIND_NODE_IMAGE"
        else
            err "Missing kind node image: $KIND_NODE_IMAGE"
            failures=$((failures + 1))
        fi
    else
        warn "kind cluster does not exist and KIND_NODE_IMAGE is not set."
        warn "Best stage path: create the kind cluster before the talk, or set KIND_NODE_IMAGE to a cached kindest/node image."
        failures=$((failures + 1))
    fi

    if (( failures > 0 )); then
        err "Offline preflight failed with $failures missing item(s)."
        return 1
    fi

    log "Offline preflight passed. This laptop is ready to run without internet."
}

offline_prep() {
    log "=== Offline Demo Prep ==="
    confirm_action "Offline prep will:" \
        "Pull the demo workload images into the local Docker cache" \
        "Load those images into the kind cluster if it already exists" \
        "Use the kind control-plane container for etcd monitoring and recovery" \
        "Require internet now, so the stage demo does not require internet later"

    show_cmd "mkdir -p $OFFLINE_ASSETS_DIR"
    mkdir -p "$OFFLINE_ASSETS_DIR"

    log "Detected image platform: $(demo_image_platform)"

    collect_workload_images
    local image
    for image in "${DEMO_IMAGES[@]}"; do
        docker_pull_image "$image"
    done

    if [[ -n "$KIND_NODE_IMAGE" ]]; then
        docker_pull_image "$KIND_NODE_IMAGE"
    else
        warn "KIND_NODE_IMAGE is not set, so offline-prep cannot pin/cache the kind node image."
        warn "Either create the cluster before stage time or rerun with KIND_NODE_IMAGE=kindest/node:<version>."
    fi

    load_images_into_kind
    offline_preflight
}

offline_export() {
    log "=== Offline Demo Export ==="
    confirm_action "Offline export will:" \
        "Write a Docker image bundle to '$OFFLINE_IMAGE_TAR'" \
        "Include demo workload images and KIND_NODE_IMAGE when it is set" \
        "Use only images already present in the local Docker cache"

    show_cmd "mkdir -p $OFFLINE_ASSETS_DIR"
    mkdir -p "$OFFLINE_ASSETS_DIR"

    collect_export_images
    local missing=0
    local image
    for image in "${DEMO_IMAGES[@]}"; do
        if ! docker_image_exists "$image"; then
            err "Missing local image, cannot export: $image"
            missing=$((missing + 1))
        fi
    done

    if (( missing > 0 )); then
        err "Run './demo.sh offline-prep' while online first, or load these images another way."
        return 1
    fi

    local platform
    platform="$(demo_image_platform)"
    show_cmd "docker save --platform=$platform -o $OFFLINE_IMAGE_TAR ${DEMO_IMAGES[*]}"
    docker save --platform="$platform" -o "$OFFLINE_IMAGE_TAR" "${DEMO_IMAGES[@]}"
    log "Wrote $OFFLINE_IMAGE_TAR"
}

offline_import() {
    log "=== Offline Demo Import ==="
    confirm_action "Offline import will:" \
        "Load Docker images from '$OFFLINE_IMAGE_TAR'" \
        "Load those images into the kind cluster if it already exists" \
        "Run the offline preflight check"

    show_cmd "test -f $OFFLINE_IMAGE_TAR"
    if [[ ! -f "$OFFLINE_IMAGE_TAR" ]]; then
        err "Missing image bundle: $OFFLINE_IMAGE_TAR"
        return 1
    fi

    show_cmd "docker load -i $OFFLINE_IMAGE_TAR"
    docker load -i "$OFFLINE_IMAGE_TAR"
    load_images_into_kind
    offline_preflight
}

etcd_metrics() {
    docker exec "${CLUSTER_NAME}-control-plane" \
        curl -sk https://localhost:2379/metrics \
        --cert /etc/kubernetes/pki/etcd/peer.crt \
        --key /etc/kubernetes/pki/etcd/peer.key \
        --cacert /etc/kubernetes/pki/etcd/ca.crt 2>/dev/null
}

etcdctl_cmd() {
    local etcd_container_id
    etcd_container_id=$(docker exec "${CLUSTER_NAME}-control-plane" \
        crictl ps --name etcd -q 2>/dev/null | head -n1)
    if [[ -z "$etcd_container_id" ]]; then
        err "Could not find the etcd static pod container."
        return 1
    fi

    docker exec "${CLUSTER_NAME}-control-plane" \
        crictl exec "$etcd_container_id" \
        etcdctl \
        --endpoints=https://localhost:2379 \
        --cert=/etc/kubernetes/pki/etcd/peer.crt \
        --key=/etc/kubernetes/pki/etcd/peer.key \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        "$@"
}

etcd_alarm_active() {
    local alarms
    alarms=$(etcdctl_cmd alarm list 2>/dev/null || true)
    [[ "$alarms" == *NOSPACE* ]]
}

quota_error_seen() {
    local file="$1"
    [[ -s "$file" ]] && grep -Eiq 'database space exceeded|NOSPACE|no space' "$file"
}

native_admission_policy_resource() {
    kubectl api-resources --api-group=admissionregistration.k8s.io 2>/dev/null |
        awk '$1 == "validatingadmissionpolicies"'
}

wait_for_status_pods() {
    local deadline=$((SECONDS + 60))
    local count=0

    while true; do
        count=$(kubectl get pods -n "$NAMESPACE" -l app=status-victim \
            --no-headers 2>/dev/null | awk 'END {print NR + 0}')
        if (( count >= STATUS_REPLICAS )); then
            echo "$count"
            return 0
        fi
        if (( SECONDS >= deadline )); then
            echo "$count"
            return 1
        fi
        sleep 1
    done
}

reset_demo_namespace() {
    log "Resetting demo namespace..."
    show_cmd "kubectl delete namespace $NAMESPACE --ignore-not-found --wait=true --timeout=90s"
    kubectl delete namespace "$NAMESPACE" \
        --ignore-not-found \
        --wait=true \
        --timeout=90s >/dev/null 2>&1 || \
        warn "Namespace reset did not fully finish; continuing with a best-effort setup."
    show_cmd "kubectl create namespace $NAMESPACE"
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# --- SETUP ---
setup() {
    confirm_action "Setup will:" \
        "Create or reuse kind cluster '$CLUSTER_NAME' with a 100MiB etcd quota" \
        "Create namespace '$NAMESPACE'" \
        "Use './demo.sh monitor' for live etcd size without deploying extra pods" \
        "Print the starting etcd size"

    if kind_cluster_exists; then
        if [[ "$RESET_CLUSTER" == "1" ]]; then
            warn "Deleting existing kind cluster '$CLUSTER_NAME' for a clean stage setup..."
            show_key_cmd "kind delete cluster --name $CLUSTER_NAME"
            kind delete cluster --name "$CLUSTER_NAME"
            log "Creating kind cluster with 100MB etcd quota..."
            create_kind_cluster
        else
            warn "kind cluster '$CLUSTER_NAME' already exists; reusing it."
            warn "If it predates this script, run 'RESET_CLUSTER=1 ./demo.sh setup' to pick up the 10m compaction window."
        fi
    else
        log "Creating kind cluster with 100MB etcd quota..."
        create_kind_cluster
    fi

    if [[ "$PRELOAD_IMAGES" == "1" ]]; then
        log "Preloading locally cached images into kind..."
        load_images_into_kind
    fi

    log "Creating demo namespace..."
    show_cmd "kubectl create namespace $NAMESPACE"
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    log ""
    log "Cluster ready. etcd quota: 100MB"
    log "Current etcd size:"
    check_etcd_size
    log ""
    log "Next: run './demo.sh break' to start the status patch storm"
}

# --- CHECK ETCD SIZE ---
check_etcd_size() {
    local metrics
    metrics=$(etcd_metrics || true)
    if [[ -z "$metrics" ]]; then
        warn "Could not read etcd metrics. Is the kind cluster running?"
        return 1
    fi

    echo "$metrics" | awk '
        /^etcd_mvcc_db_total_size_in_bytes / {size=$2}
        /^etcd_mvcc_db_total_size_in_use_in_bytes / {in_use=$2}
        /^etcd_server_quota_backend_bytes / {quota=$2}
        END {
            pct = quota ? (size/quota)*100 : 0
            dead = size - in_use
            printf "  etcd db size: %.1f MB / %.1f MB (%.0f%%)\n", size/1024/1024, quota/1024/1024, pct
            printf "  etcd in-use:  %.1f MB\n", in_use/1024/1024
            printf "  dead space:   %.1f MB\n", dead/1024/1024
        }'

    if etcd_alarm_active; then
        err "  etcd alarm: NOSPACE"
    else
        echo "  etcd alarm: none"
    fi
}

# --- BREAK: Annotation Bomb ---
break_annotations() {
    log "=== SCENARIO: Annotation Bomb ==="
    log "Creating 50 pods, then patching each with 50KB annotations every 2s"
    log "This simulates a misbehaving controller that stores state in annotations"
    log ""
    warn "Watch etcd grow: run './demo.sh monitor' in another terminal"
    log ""
    confirm_action "Annotation storm will:" \
        "Create 50 test pods using image '$TEST_IMAGE' in namespace '$NAMESPACE'" \
        "Patch each pod with a 50KiB annotation every 2 seconds" \
        "Stop when etcd reports the NOSPACE alarm"

    # Create pods
    log "Creating 50 pods..."
    show_key_cmd "for i in \$(seq 1 50); do kubectl run victim-\$i --image=$TEST_IMAGE --namespace=$NAMESPACE -- sleep 3600; done"
    for i in $(seq 1 50); do
        kubectl run "victim-$i" --image="$TEST_IMAGE" --namespace=$NAMESPACE \
            --command -- sleep 3600 2>/dev/null &
    done
    wait
    log "50 pods created. Waiting for them to be Running..."
    show_cmd "kubectl wait --for=condition=Ready pod --all -n $NAMESPACE --timeout=120s"
    kubectl wait --for=condition=Ready pod --all -n $NAMESPACE --timeout=120s 2>/dev/null || true

    # Generate a 50KB annotation value
    BLOB=$(python3 -c "print('x' * 51200)")

    log ""
    log "Starting annotation storm... (Ctrl+C to stop)"
    log "Each patch writes the ENTIRE pod object (~65KB with annotation) as a new etcd revision"
    show_key_cmd "kubectl annotate pod victim-<n> -n $NAMESPACE bloat.demo/data-<k>=<50KiB> --overwrite"
    log ""

    local iteration=0
    while true; do
        iteration=$((iteration + 1))
        for i in $(seq 1 50); do
            kubectl annotate pod "victim-$i" -n $NAMESPACE \
                "bloat.demo/data-$((iteration % 5))=$BLOB" \
                --overwrite 2>/dev/null &
        done
        wait

        # Check if we've hit the quota. Reads still work during NOSPACE, so
        # use the etcd alarm instead of a kubectl get as the signal.
        if etcd_alarm_active; then
            echo ""
            err "=== CLUSTER IS NOW READ-ONLY ==="
            err "etcd quota exceeded. All writes rejected."
            err ""
            err "Try these (they all fail):"
            err "  kubectl delete pod victim-1 -n $NAMESPACE"
            err "  kubectl scale deployment anything --replicas=0"
            err "  kubectl create namespace test"
            err ""
            err "Run './demo.sh recover' to fix it"
            break
        fi

        echo -ne "\r  Iteration $iteration - 50 pods × 50KB annotation = ~3.2MB written to etcd per cycle"
        sleep 2
    done
}

write_status_patch_file() {
    local iteration="$1"
    local patch_file="$2"

    python3 - "$STATUS_PAYLOAD_BYTES" "$iteration" > "$patch_file" <<'PY'
import json
import sys
from datetime import datetime, timezone

size = int(sys.argv[1])
iteration = sys.argv[2]
prefix = f"iteration={iteration};"
message = (prefix + ("x" * max(0, size - len(prefix))))[:size]

patch = {
    "status": {
        "conditions": [
            {
                "type": "demo.kubecon.io/MVCCPressure",
                "status": "True",
                "lastTransitionTime": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "reason": f"Iteration{iteration}",
                "message": message,
            }
        ]
    }
}

json.dump(patch, sys.stdout)
PY
}

show_blocked_writes() {
    echo ""
    err "=== CLUSTER IS NOW READ-ONLY ==="
    err "etcd quota exceeded. Writes are rejected, but reads still work."
    echo ""

    warn "A read still succeeds:"
    show_key_cmd "kubectl get namespace $NAMESPACE"
    kubectl get namespace "$NAMESPACE" >/dev/null && echo "  kubectl get namespace $NAMESPACE  # OK"
    echo ""

    warn "A tiny write now fails:"
    show_key_cmd "kubectl create configmap mvcc-write-probe -n $NAMESPACE --from-literal=ts=<now>"
    if ! kubectl create configmap mvcc-write-probe \
        -n "$NAMESPACE" \
        --from-literal=ts="$(date -u +%s)" 2>&1 | sed 's/^/  /'; then
        true
    fi
    err "WRITES BLOCKED - cluster is read-only!"
    echo ""

    err "Try these too:"
    err "  kubectl delete pod <pod> -n $NAMESPACE"
    err "  kubectl scale deployment status-victim --replicas=0 -n $NAMESPACE"
    err "  kubectl create namespace test"
    echo ""
    err "Run './demo.sh recover' to fix it"
}

# --- BREAK: Status Patch Storm ---
break_status() {
    log "=== SCENARIO: Status Patch Storm ==="
    log "Simulates a controller that writes high-churn data into pod status"
    log "Replicas: $STATUS_REPLICAS | payload: $((STATUS_PAYLOAD_BYTES / 1024))KiB/pod | parallelism: $STATUS_PARALLELISM"
    log "Image: $STATUS_IMAGE"
    log ""
    confirm_action "Status storm setup will:" \
        "Reset namespace '$NAMESPACE' so the run starts clean" \
        "Create deployment/status-victim using image '$STATUS_IMAGE'" \
        "Scale it to $STATUS_REPLICAS pods" \
        "Generate a $((STATUS_PAYLOAD_BYTES / 1024))KiB status patch payload"

    reset_demo_namespace

    log "Creating status-victim deployment..."
    show_key_cmd "kubectl create deployment status-victim --image=$STATUS_IMAGE --namespace=$NAMESPACE --dry-run=client -o yaml | kubectl apply -f -"
    kubectl create deployment status-victim \
        --image="$STATUS_IMAGE" \
        --namespace="$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    show_cmd "kubectl scale deployment status-victim --replicas=$STATUS_REPLICAS -n $NAMESPACE"
    kubectl scale deployment status-victim --replicas="$STATUS_REPLICAS" -n "$NAMESPACE" >/dev/null

    log "Waiting for pod objects to be created..."
    show_cmd "kubectl get pods -n $NAMESPACE -l app=status-victim"
    local pod_count
    if ! pod_count=$(wait_for_status_pods); then
        warn "Only found $pod_count/$STATUS_REPLICAS pods; patching the pods that exist."
    fi

    local pods=()
    while IFS= read -r pod; do
        pods+=("$pod")
    done < <(kubectl get pods -n "$NAMESPACE" -l app=status-victim -o name)

    if [[ "${#pods[@]}" -eq 0 ]]; then
        err "No status-victim pods found. Check the cluster and rerun './demo.sh break'."
        return 1
    fi

    log "Patching status on ${#pods[@]} pods as fast as the API server accepts it..."
    log "(This is what broken operators do: reconcile loops that always patch.)"
    log ""
    confirm_action "Starting the status storm will:" \
        "Patch ${#pods[@]} pod status subresources in parallel" \
        "Write a new full pod revision to etcd on every successful patch" \
        "Continue until etcd rejects writes or $STATUS_DEADLINE_SECONDS seconds elapse"

    local patch_file
    local err_file
    patch_file=$(mktemp "${TMPDIR:-/tmp}/mvcc-status-patch.XXXXXX.json")
    err_file=$(mktemp "${TMPDIR:-/tmp}/mvcc-status-errors.XXXXXX.log")

    log "Testing one status patch before starting the storm..."
    local patch_type="$STATUS_PATCH_TYPE"
    write_status_patch_file 0 "$patch_file"
    show_key_cmd "kubectl patch ${pods[0]} -n $NAMESPACE --subresource=status --type=$patch_type --patch-file=<${STATUS_PAYLOAD_BYTES}B payload>"
    if ! kubectl patch "${pods[0]}" -n "$NAMESPACE" \
        --subresource=status \
        --type="$patch_type" \
        --patch-file="$patch_file" >/dev/null; then
        if [[ "$patch_type" == "strategic" ]]; then
            warn "Strategic status patch failed; retrying with merge patch."
            patch_type="merge"
            show_key_cmd "kubectl patch ${pods[0]} -n $NAMESPACE --subresource=status --type=$patch_type --patch-file=<${STATUS_PAYLOAD_BYTES}B payload>"
            if ! kubectl patch "${pods[0]}" -n "$NAMESPACE" \
                --subresource=status \
                --type="$patch_type" \
                --patch-file="$patch_file" >/dev/null; then
                err "The API server rejected the status patch. Try a smaller payload:"
                err "  STATUS_PAYLOAD_BYTES=32768 ./demo.sh break"
                rm -f "$patch_file" "$err_file"
                return 1
            fi
        else
            err "The API server rejected the status patch. Try a smaller payload:"
            err "  STATUS_PAYLOAD_BYTES=32768 ./demo.sh break"
            rm -f "$patch_file" "$err_file"
            return 1
        fi
    fi

    local iteration=0
    local start_ts
    start_ts=$(date +%s)
    show_key_cmd "kubectl patch pod/<name> -n $NAMESPACE --subresource=status --type=$patch_type --patch-file=<${STATUS_PAYLOAD_BYTES}B payload>"
    while true; do
        iteration=$((iteration + 1))
        write_status_patch_file "$iteration" "$patch_file"
        : > "$err_file"

        local launched=0
        for pod in "${pods[@]}"; do
            kubectl patch "$pod" -n "$NAMESPACE" \
                --subresource=status \
                --type="$patch_type" \
                --patch-file="$patch_file" >/dev/null 2>>"$err_file" &
            launched=$((launched + 1))
            if (( launched % STATUS_PARALLELISM == 0 )); then
                wait || true
            fi
        done
        wait || true

        local elapsed
        elapsed=$(($(date +%s) - start_ts))
        echo ""
        echo "  Iteration $iteration | elapsed ${elapsed}s"
        check_etcd_size || true

        if etcd_alarm_active || quota_error_seen "$err_file"; then
            if quota_error_seen "$err_file"; then
                warn "A status write failed with the quota error:"
                grep -Eim1 'database space exceeded|NOSPACE|no space' "$err_file" | sed 's/^/  /'
            fi
            show_blocked_writes
            break
        fi

        if [[ -s "$err_file" ]]; then
            warn "Some status patches failed without a quota error; first error was:"
            sed -n '1p' "$err_file" | sed 's/^/  /'
        fi

        if (( elapsed >= STATUS_DEADLINE_SECONDS )); then
            echo ""
            warn "Deadline reached before NOSPACE."
            warn "For stage certainty, rerun with one of these:"
            warn "  STATUS_REPLICAS=100 ./demo.sh break"
            warn "  STATUS_PAYLOAD_BYTES=131072 ./demo.sh break"
            warn "  Or lower quota-backend-bytes in kind-config.yaml for rehearsal clusters."
            break
        fi
    done

    rm -f "$patch_file" "$err_file"
}

# --- MONITOR ---
monitor() {
    log "=== Monitoring etcd size (updates every 5s) ==="
    log "Quota: 100MB. Cluster goes read-only when exceeded."
    log ""
    confirm_action "Monitor will:" \
        "Poll the etcd metrics endpoint every 5 seconds" \
        "Display total size, in-use bytes, dead space, quota percentage, and alarm state" \
        "Run until you stop it with Ctrl+C"
    show_metrics_cmd

    while true; do
        local alarm="none"
        if etcd_alarm_active; then
            alarm="NOSPACE"
        fi

        echo -ne "\r$(date +%H:%M:%S) | "
        etcd_metrics | awk -v alarm="$alarm" '
                /^etcd_server_quota_backend_bytes / {quota=$2}
                /^etcd_mvcc_db_total_size_in_bytes / {size=$2}
                /^etcd_mvcc_db_total_size_in_use_in_bytes / {in_use=$2}
                END {
                    pct = (size/quota)*100
                    dead = size - in_use
                    printf "Size: %.1f/%.1f MB (%3.0f%%) | in-use: %.1f MB | dead: %.1f MB | alarm: %s",
                        size/1024/1024, quota/1024/1024, pct, in_use/1024/1024, dead/1024/1024, alarm
                    if (pct > 80) printf " ⚠️  DANGER"
                    if (pct > 95) printf " 🔥 CRITICAL"
                }'
        sleep 5
    done
}

# --- RECOVER ---
recover() {
    log "=== Recovery Procedure ==="
    log "This is the non-obvious part. You can't just delete objects."
    log ""
    confirm_action "Recovery will:" \
        "Read the etcd NOSPACE alarm" \
        "Find the current revision and compact old MVCC revisions" \
        "Defragment etcd to reclaim backend file space" \
        "Disarm the NOSPACE alarm" \
        "Verify Kubernetes writes work again"

    warn "Step 1: Check the alarm"
    show_key_cmd "etcdctl alarm list"
    etcdctl_cmd alarm list
    echo ""

    log "Step 2: Get current revision and compact"
    local rev
    show_key_cmd "etcdctl endpoint status --write-out=json"
    rev=$(etcdctl_cmd endpoint status --write-out=json \
        | python3 -c "import sys,json; print(json.loads(sys.stdin.read())[0]['Status']['header']['revision'])")
    log "  Current revision: $rev"
    log "  Compacting to revision $rev..."
    show_key_cmd "etcdctl compact $rev"

    local compact_output
    if ! compact_output=$(etcdctl_cmd compact "$rev" 2>&1); then
        if grep -q "required revision has been compacted" <<<"$compact_output"; then
            warn "  Revision $rev was already compacted; continuing to defrag."
        else
            echo "$compact_output"
            return 1
        fi
    else
        echo "$compact_output"
    fi
    echo ""

    log "Step 3: Defragment (compaction removes revisions but doesn't free disk)"
    show_key_cmd "etcdctl defrag"
    etcdctl_cmd defrag
    echo ""

    log "Step 4: Disarm the alarm"
    show_key_cmd "etcdctl alarm disarm"
    etcdctl_cmd alarm disarm
    echo ""

    log "Step 5: Verify cluster is writable"
    show_key_cmd "kubectl create namespace recovery-test"
    if kubectl create namespace recovery-test 2>/dev/null; then
        show_cmd "kubectl delete namespace recovery-test --wait=false"
        kubectl delete namespace recovery-test --wait=false 2>/dev/null || true
        log "✅ Cluster is writable again!"
    else
        err "Cluster still read-only. May need to restart etcd."
    fi

    echo ""
    check_etcd_size
}

# --- GUARDRAILS ---
guardrails() {
    log "=== Deploying Prevention Guardrails ==="
    log ""
    local metadata_guardrail_ok=0
    local status_guardrail_ok=0

    confirm_action "Guardrails will:" \
        "Apply a native Kubernetes ValidatingAdmissionPolicy" \
        "Reject oversized pod metadata entries" \
        "Reject oversized pod status condition messages" \
        "Apply or print the Prometheus etcd alerting rule" \
        "Try 50KiB metadata and status rejection without needing internet or add-ons"

    log "1. Native admission guardrail: limit high-risk mutable pod fields"
    show_cmd "kubectl api-resources --api-group=admissionregistration.k8s.io | grep '^validatingadmissionpolicies[[:space:]]'"
    local vap_resource
    vap_resource="$(native_admission_policy_resource || true)"
    if [[ -n "$vap_resource" ]]; then
        echo "$vap_resource" | sed 's/^/  /'
        show_key_cmd "kubectl apply -f manifests/native-pod-mvcc-guardrails.yaml"
        kubectl apply -f manifests/native-pod-mvcc-guardrails.yaml
        show_cmd "kubectl get validatingadmissionpolicy pod-mvcc-write-guardrails pod-status-mvcc-guardrails"
        kubectl get validatingadmissionpolicy \
            pod-mvcc-write-guardrails \
            pod-status-mvcc-guardrails
        show_cmd "kubectl get validatingadmissionpolicybinding pod-mvcc-write-guardrails pod-status-mvcc-guardrails"
        kubectl get validatingadmissionpolicybinding \
            pod-mvcc-write-guardrails \
            pod-status-mvcc-guardrails
    else
        warn "This cluster does not expose ValidatingAdmissionPolicy."
        warn "Showing the native policy manifest instead of applying it."
        show_cmd "cat manifests/native-pod-mvcc-guardrails.yaml"
        cat manifests/native-pod-mvcc-guardrails.yaml
    fi
    echo ""

    log "2. Prometheus alerting rule: alert when etcd is 50% full"
    show_cmd "kubectl apply -f manifests/prometheus-etcd-alert.yaml"
    kubectl apply -f manifests/prometheus-etcd-alert.yaml 2>/dev/null || \
        log "   (Prometheus not installed - showing rule definition)"
    show_cmd "cat manifests/prometheus-etcd-alert.yaml"
    cat manifests/prometheus-etcd-alert.yaml
    echo ""

    log "3. Testing the guardrail..."
    if [[ -n "$vap_resource" ]]; then
        local guardrail_output
        local blob
        blob=$(python3 -c "print('x' * 51200)")
        show_key_cmd "kubectl run guardrail-test --image=$TEST_IMAGE -n $NAMESPACE --annotations=bloat.demo/huge=<50KiB> -- sleep 1"
        guardrail_output=$(kubectl run guardrail-test --image="$TEST_IMAGE" -n $NAMESPACE \
            --annotations="bloat.demo/huge=$blob" \
            --command -- sleep 1 2>&1 || true)
        echo "$guardrail_output" | sed 's/^/  /'

        if grep -qiE "denied the request|blocked due to|10KiB|Large annotations cause|Pod annotation entries" <<<"$guardrail_output"; then
            log "✅ Metadata guardrail working - bloated pod rejected"
            metadata_guardrail_ok=1
        else
            warn "Metadata guardrail test was not rejected. Check ValidatingAdmissionPolicy status."
        fi

        local status_patch_file
        local status_guardrail_output
        status_patch_file=$(mktemp "${TMPDIR:-/tmp}/mvcc-status-guardrail.XXXXXX.json")
        write_status_patch_file "guardrail" "$status_patch_file"

        show_cmd "kubectl delete pod guardrail-status-test -n $NAMESPACE --ignore-not-found --wait=false"
        kubectl delete pod guardrail-status-test -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
        show_key_cmd "kubectl run guardrail-status-test --image=$STATUS_IMAGE -n $NAMESPACE"
        kubectl run guardrail-status-test --image="$STATUS_IMAGE" -n "$NAMESPACE" >/dev/null
        show_key_cmd "kubectl patch pod/guardrail-status-test -n $NAMESPACE --subresource=status --type=merge --patch-file=<${STATUS_PAYLOAD_BYTES}B payload>"
        status_guardrail_output=$(kubectl patch pod/guardrail-status-test -n "$NAMESPACE" \
            --subresource=status \
            --type=merge \
            --patch-file="$status_patch_file" 2>&1 || true)
        echo "$status_guardrail_output" | sed 's/^/  /'
        rm -f "$status_patch_file"
        show_cmd "kubectl delete pod guardrail-status-test -n $NAMESPACE --ignore-not-found --wait=false"
        kubectl delete pod guardrail-status-test -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true

        if grep -qiE "denied the request|10KiB|status condition messages|High-churn status payloads" <<<"$status_guardrail_output"; then
            log "✅ Status guardrail working - bloated status patch rejected"
            status_guardrail_ok=1
        else
            warn "Status guardrail test was not rejected. Check ValidatingAdmissionPolicy status."
        fi
    else
        warn "Live rejection test skipped because native admission policy is unavailable."
    fi

    if [[ "$metadata_guardrail_ok" != "1" || "$status_guardrail_ok" != "1" ]]; then
        err "Admission guardrail was not verified."
        warn "This should work on recent kind/Kubernetes clusters with ValidatingAdmissionPolicy enabled."
        return 1
    fi

    log "✅ Admission guardrails verified - metadata and status bloat are blocked before etcd"

}

# --- CLEANUP ---
cleanup() {
    confirm_action "Cleanup will:" \
        "Delete the kind cluster '$CLUSTER_NAME'" \
        "Remove all demo workloads and etcd data with that cluster"
    log "Deleting kind cluster..."
    show_key_cmd "kind delete cluster --name $CLUSTER_NAME"
    kind delete cluster --name $CLUSTER_NAME
    log "Done."
}

# --- SIZE ---
size() {
    confirm_action "Size check will:" \
        "Read etcd metrics from the kind control-plane container" \
        "Print total size, in-use bytes, dead space, and alarm state"
    show_metrics_cmd
    check_etcd_size
}

# --- GUIDED A-Z DEMO ---
guided_demo() {
    log "=== Guided A-Z Demo ==="
    log "Run a full stage flow: setup → observe → break → recover → guardrails."
    log "Run a specific scenario, such as './demo.sh break', to skip this guided flow."

    confirm_action "Guided demo will:" \
        "Create or reuse the kind cluster" \
        "Show the starting etcd size" \
        "Pause so you can start './demo.sh monitor' in a second terminal" \
        "Run the status patch storm until writes fail" \
        "Recover etcd with compact, defrag, and alarm disarm" \
        "Deploy guardrail examples"

    setup
    size

    confirm_action "Before the break scenario:" \
        "Open a second terminal if you want live monitoring" \
        "Run: ./demo.sh monitor" \
        "Come back here and continue when the monitor is visible"

    break_status
    recover
    guardrails

    if ask_yes_no "Optional cleanup:" \
        "Delete the kind cluster '$CLUSTER_NAME'" \
        "Use this after the talk or rehearsal, not before recovery verification"; then
        cleanup
    else
        log "Leaving the recovered cluster in place."
    fi
}

# --- MAIN ---
case "${REQUESTED_SCENARIO:-guided}" in
    guided)     guided_demo ;;
    setup)      setup ;;
    break)      break_status ;;
    break-annotations) break_annotations ;;
    break-status) break_status ;;
    monitor)    monitor ;;
    recover)    recover ;;
    guardrails) guardrails ;;
    cleanup)    cleanup ;;
    size)       size ;;
    offline-prep) offline_prep ;;
    offline-check|offline-preflight) offline_preflight ;;
    offline-export) offline_export ;;
    offline-import) offline_import ;;
    *)
        echo "Usage: ./demo.sh [scenario]"
        echo ""
        echo "Run './demo.sh' with no scenario for the guided A-Z stage flow."
        echo "Run a specific scenario to execute it directly without prompts by default."
        echo "Set DEMO_PROMPT=1 to force prompts, or DEMO_PROMPT=0 to disable them."
        echo "Set DEMO_COMMAND_PAUSE=major, all, or 0 to control Enter pauses before commands."
        echo ""
        echo "Scenarios (run in order):"
        echo "  guided      - Full guided flow: setup, size, break, recover, guardrails"
        echo "  setup       - Create kind cluster with 100MB etcd quota"
        echo "  break       - Stage path: pod status patch storm (fills etcd)"
        echo "  break-annotations - Alternative: annotation patch storm"
        echo "  monitor     - Watch etcd size in real-time (run in separate terminal)"
        echo "  recover     - Walk through recovery procedure"
        echo "  guardrails  - Deploy prevention (native admission policy + Prometheus alerts)"
        echo "  cleanup     - Delete the cluster"
        echo "  size        - Check current etcd size"
        echo "  offline-prep   - Pull demo images and preload kind if present"
        echo "  offline-check  - Verify the laptop is ready to demo without internet"
        echo "  offline-export - Save cached demo images to offline-assets/demo-images.tar"
        echo "  offline-import - Load cached demo images from offline-assets/demo-images.tar"
        ;;
esac
