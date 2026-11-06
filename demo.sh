#!/bin/bash
# =============================================================================
# etcd MVCC Exhaustion Demo
# Reproduces the "death by a thousand patches" failure mode
#
# Prerequisites: kind, kubectl, Docker, Python 3
# Usage: ./demo.sh [scenario]
#   scenarios: setup | break | monitor | recover | guardrails | cleanup
# =============================================================================

set -euo pipefail
CLUSTER_NAME="etcd-mvcc-demo"
NAMESPACE="mvcc-demo"

# Stage-tuned defaults. Override at runtime, e.g.:
#   STATUS_REPLICAS=60 STATUS_PAYLOAD_BYTES=65536 ./demo.sh break
STATUS_REPLICAS="${STATUS_REPLICAS:-80}"
STATUS_PAYLOAD_BYTES="${STATUS_PAYLOAD_BYTES:-98304}"
STATUS_PARALLELISM="${STATUS_PARALLELISM:-20}"
STATUS_DEADLINE_SECONDS="${STATUS_DEADLINE_SECONDS:-90}"
STATUS_PATCH_TYPE="${STATUS_PATCH_TYPE:-strategic}"
STATUS_IMAGE="${STATUS_IMAGE:-registry.k8s.io/pause:3.10}"
RESET_CLUSTER="${RESET_CLUSTER:-0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[DEMO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[FAIL]${NC} $1"; }

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
    kubectl delete namespace "$NAMESPACE" \
        --ignore-not-found \
        --wait=true \
        --timeout=90s >/dev/null 2>&1 || \
        warn "Namespace reset did not fully finish; continuing with a best-effort setup."
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# --- SETUP ---
setup() {
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
        if [[ "$RESET_CLUSTER" == "1" ]]; then
            warn "Deleting existing kind cluster '$CLUSTER_NAME' for a clean stage setup..."
            kind delete cluster --name "$CLUSTER_NAME"
            log "Creating kind cluster with 100MB etcd quota..."
            kind create cluster --config kind-config.yaml --wait 60s
        else
            warn "kind cluster '$CLUSTER_NAME' already exists; reusing it."
            warn "If it predates this script, run 'RESET_CLUSTER=1 ./demo.sh setup' to pick up the 10m compaction window."
        fi
    else
        log "Creating kind cluster with 100MB etcd quota..."
        kind create cluster --config kind-config.yaml --wait 60s
    fi

    log "Creating demo namespace..."
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    log "Deploying monitoring..."
    kubectl apply -f manifests/monitoring.yaml

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

    # Create pods
    log "Creating 50 pods..."
    for i in $(seq 1 50); do
        kubectl run "victim-$i" --image=busybox --namespace=$NAMESPACE \
            --command -- sleep 3600 2>/dev/null &
    done
    wait
    log "50 pods created. Waiting for them to be Running..."
    kubectl wait --for=condition=Ready pod --all -n $NAMESPACE --timeout=120s 2>/dev/null || true

    # Generate a 50KB annotation value
    BLOB=$(python3 -c "print('x' * 51200)")

    log ""
    log "Starting annotation storm... (Ctrl+C to stop)"
    log "Each patch writes the ENTIRE pod object (~65KB with annotation) as a new etcd revision"
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
    kubectl get namespace "$NAMESPACE" >/dev/null && echo "  kubectl get namespace $NAMESPACE  # OK"
    echo ""

    warn "A tiny write now fails:"
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

    reset_demo_namespace

    log "Creating status-victim deployment..."
    kubectl create deployment status-victim \
        --image="$STATUS_IMAGE" \
        --namespace="$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl scale deployment status-victim --replicas="$STATUS_REPLICAS" -n "$NAMESPACE" >/dev/null

    log "Waiting for pod objects to be created..."
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

    local patch_file
    local err_file
    patch_file=$(mktemp "${TMPDIR:-/tmp}/mvcc-status-patch.XXXXXX.json")
    err_file=$(mktemp "${TMPDIR:-/tmp}/mvcc-status-errors.XXXXXX.log")
    trap 'rm -f "$patch_file" "$err_file"' RETURN

    log "Calibrating one status patch..."
    local patch_type="$STATUS_PATCH_TYPE"
    write_status_patch_file 0 "$patch_file"
    if ! kubectl patch "${pods[0]}" -n "$NAMESPACE" \
        --subresource=status \
        --type="$patch_type" \
        --patch-file="$patch_file" >/dev/null; then
        if [[ "$patch_type" == "strategic" ]]; then
            warn "Strategic status patch failed; retrying with merge patch."
            patch_type="merge"
            if ! kubectl patch "${pods[0]}" -n "$NAMESPACE" \
                --subresource=status \
                --type="$patch_type" \
                --patch-file="$patch_file" >/dev/null; then
                err "The API server rejected the status patch. Try a smaller payload:"
                err "  STATUS_PAYLOAD_BYTES=32768 ./demo.sh break"
                return 1
            fi
        else
            err "The API server rejected the status patch. Try a smaller payload:"
            err "  STATUS_PAYLOAD_BYTES=32768 ./demo.sh break"
            return 1
        fi
    fi

    local iteration=0
    local start_ts
    start_ts=$(date +%s)
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
}

# --- MONITOR ---
monitor() {
    log "=== Monitoring etcd size (updates every 5s) ==="
    log "Quota: 100MB. Cluster goes read-only when exceeded."
    log ""

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

    warn "Step 1: Check the alarm"
    etcdctl_cmd alarm list
    echo ""

    log "Step 2: Get current revision and compact"
    local rev
    rev=$(etcdctl_cmd endpoint status --write-out=json \
        | python3 -c "import sys,json; print(json.loads(sys.stdin.read())[0]['Status']['header']['revision'])")
    log "  Current revision: $rev"
    log "  Compacting to revision $rev..."

    etcdctl_cmd compact "$rev"
    echo ""

    log "Step 3: Defragment (compaction removes revisions but doesn't free disk)"
    etcdctl_cmd defrag
    echo ""

    log "Step 4: Disarm the alarm"
    etcdctl_cmd alarm disarm
    echo ""

    log "Step 5: Verify cluster is writable"
    if kubectl create namespace recovery-test 2>/dev/null; then
        kubectl delete namespace recovery-test 2>/dev/null
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

    log "1. Kyverno policy: reject pods with annotations > 10KB total"
    kubectl apply -f manifests/kyverno-annotation-limit.yaml
    echo ""

    log "2. Prometheus alerting rule: alert when etcd is 50% full"
    kubectl apply -f manifests/prometheus-etcd-alert.yaml 2>/dev/null || \
        log "   (Prometheus not installed - showing rule definition)"
    cat manifests/prometheus-etcd-alert.yaml
    echo ""

    log "3. Testing the guardrail..."
    BLOB=$(python3 -c "print('x' * 51200)")
    if kubectl run guardrail-test --image=busybox -n $NAMESPACE \
        --annotations="bloat.demo/huge=$BLOB" \
        --command -- sleep 1 2>&1 | grep -q "blocked"; then
        log "✅ Guardrail working - bloated pod rejected"
    else
        warn "Guardrail may need Kyverno to be installed first"
    fi
}

# --- CLEANUP ---
cleanup() {
    log "Deleting kind cluster..."
    kind delete cluster --name $CLUSTER_NAME
    log "Done."
}

# --- MAIN ---
case "${1:-help}" in
    setup)      setup ;;
    break)      break_status ;;
    break-annotations) break_annotations ;;
    break-status) break_status ;;
    monitor)    monitor ;;
    recover)    recover ;;
    guardrails) guardrails ;;
    cleanup)    cleanup ;;
    size)       check_etcd_size ;;
    *)
        echo "Usage: ./demo.sh <scenario>"
        echo ""
        echo "Scenarios (run in order):"
        echo "  setup       - Create kind cluster with 100MB etcd quota"
        echo "  break       - Stage path: pod status patch storm (fills etcd)"
        echo "  break-status - Same as break"
        echo "  break-annotations - Alternative: annotation patch storm"
        echo "  monitor     - Watch etcd size in real-time (run in separate terminal)"
        echo "  recover     - Walk through recovery procedure"
        echo "  guardrails  - Deploy prevention (Kyverno + Prometheus alerts)"
        echo "  cleanup     - Delete the cluster"
        echo "  size        - Check current etcd size"
        ;;
esac
