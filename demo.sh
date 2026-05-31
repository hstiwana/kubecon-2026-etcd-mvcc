#!/bin/bash
# =============================================================================
# etcd MVCC Exhaustion Demo
# Reproduces the "death by a thousand patches" failure mode
#
# Prerequisites: kind, kubectl, jq
# Usage: ./demo.sh [scenario]
#   scenarios: setup | break | monitor | recover | guardrails | cleanup
# =============================================================================

set -euo pipefail
CLUSTER_NAME="etcd-mvcc-demo"
NAMESPACE="mvcc-demo"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[DEMO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[FAIL]${NC} $1"; }

# --- SETUP ---
setup() {
    log "Creating kind cluster with 100MB etcd quota..."
    kind create cluster --config kind-config.yaml --wait 60s

    log "Creating demo namespace..."
    kubectl create namespace $NAMESPACE

    log "Deploying monitoring..."
    kubectl apply -f manifests/monitoring.yaml

    log ""
    log "Cluster ready. etcd quota: 100MB"
    log "Current etcd size:"
    check_etcd_size
    log ""
    log "Next: run './demo.sh break' to start the annotation bomb"
}

# --- CHECK ETCD SIZE ---
check_etcd_size() {
    # Get etcd db size from metrics endpoint inside the control plane
    local size
    size=$(docker exec ${CLUSTER_NAME}-control-plane \
        curl -sk https://localhost:2379/metrics \
        --cert /etc/kubernetes/pki/etcd/peer.crt \
        --key /etc/kubernetes/pki/etcd/peer.key \
        --cacert /etc/kubernetes/pki/etcd/ca.crt 2>/dev/null \
        | grep "^etcd_mvcc_db_total_size_in_bytes " \
        | awk '{printf "%.1f MB", $2/1024/1024}')
    echo "  etcd db size: $size"

    local in_use
    in_use=$(docker exec ${CLUSTER_NAME}-control-plane \
        curl -sk https://localhost:2379/metrics \
        --cert /etc/kubernetes/pki/etcd/peer.crt \
        --key /etc/kubernetes/pki/etcd/peer.key \
        --cacert /etc/kubernetes/pki/etcd/ca.crt 2>/dev/null \
        | grep "^etcd_mvcc_db_total_size_in_use_in_bytes " \
        | awk '{printf "%.1f MB", $2/1024/1024}')
    echo "  etcd in-use:  $in_use"
}

# --- BREAK: Annotation Bomb ---
break_cluster() {
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

        # Check if we've hit the quota
        if ! kubectl get ns $NAMESPACE &>/dev/null; then
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

# --- BREAK: Status Patch Storm ---
break_status() {
    log "=== SCENARIO: Status Patch Storm ==="
    log "Simulates a controller that patches pod status every second"
    log ""

    # Create a deployment
    kubectl create deployment status-victim --image=busybox \
        --namespace=$NAMESPACE -- sleep 3600
    kubectl scale deployment status-victim --replicas=20 -n $NAMESPACE
    kubectl wait --for=condition=Ready pod -l app=status-victim \
        -n $NAMESPACE --timeout=120s 2>/dev/null || true

    log "Patching status conditions on 20 pods every second..."
    log "(This is what broken operators do - reconcile loops that always patch)"
    log ""

    local iteration=0
    while true; do
        iteration=$((iteration + 1))
        for pod in $(kubectl get pods -n $NAMESPACE -l app=status-victim -o name 2>/dev/null); do
            kubectl patch $pod -n $NAMESPACE --type=merge --subresource=status \
                -p "{\"status\":{\"conditions\":[{\"type\":\"DemoCondition\",\"status\":\"True\",\"lastTransitionTime\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"reason\":\"Iteration$iteration\",\"message\":\"$(head -c 1024 /dev/urandom | base64 | head -c 1000)\"}]}}" \
                2>/dev/null &
        done
        wait

        if ! kubectl get ns $NAMESPACE &>/dev/null; then
            err "=== CLUSTER IS NOW READ-ONLY ==="
            break
        fi

        echo -ne "\r  Iteration $iteration - 20 status patches/sec"
        sleep 1
    done
}

# --- MONITOR ---
monitor() {
    log "=== Monitoring etcd size (updates every 5s) ==="
    log "Quota: 100MB. Cluster goes read-only when exceeded."
    log ""

    while true; do
        echo -ne "\r$(date +%H:%M:%S) | "
        docker exec ${CLUSTER_NAME}-control-plane \
            curl -sk https://localhost:2379/metrics \
            --cert /etc/kubernetes/pki/etcd/peer.crt \
            --key /etc/kubernetes/pki/etcd/peer.key \
            --cacert /etc/kubernetes/pki/etcd/ca.crt 2>/dev/null \
            | grep -E "^etcd_mvcc_db_total_size_in_bytes |^etcd_server_quota_backend_bytes " \
            | awk '
                /quota/ {quota=$2}
                /total_size_in_bytes / {size=$2}
                END {
                    pct = (size/quota)*100
                    printf "Size: %.1f MB / %.1f MB (%.0f%%)", size/1024/1024, quota/1024/1024, pct
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
    docker exec ${CLUSTER_NAME}-control-plane \
        etcdctl alarm list \
        --endpoints=https://localhost:2379 \
        --cert=/etc/kubernetes/pki/etcd/peer.crt \
        --key=/etc/kubernetes/pki/etcd/peer.key \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt
    echo ""

    log "Step 2: Get current revision and compact"
    local rev
    rev=$(docker exec ${CLUSTER_NAME}-control-plane \
        etcdctl endpoint status --write-out=json \
        --endpoints=https://localhost:2379 \
        --cert=/etc/kubernetes/pki/etcd/peer.crt \
        --key=/etc/kubernetes/pki/etcd/peer.key \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        | python3 -c "import sys,json; print(json.loads(sys.stdin.read())[0]['Status']['header']['revision'])")
    log "  Current revision: $rev"
    log "  Compacting to revision $rev..."

    docker exec ${CLUSTER_NAME}-control-plane \
        etcdctl compact "$rev" \
        --endpoints=https://localhost:2379 \
        --cert=/etc/kubernetes/pki/etcd/peer.crt \
        --key=/etc/kubernetes/pki/etcd/peer.key \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt
    echo ""

    log "Step 3: Defragment (compaction removes revisions but doesn't free disk)"
    docker exec ${CLUSTER_NAME}-control-plane \
        etcdctl defrag \
        --endpoints=https://localhost:2379 \
        --cert=/etc/kubernetes/pki/etcd/peer.crt \
        --key=/etc/kubernetes/pki/etcd/peer.key \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt
    echo ""

    log "Step 4: Disarm the alarm"
    docker exec ${CLUSTER_NAME}-control-plane \
        etcdctl alarm disarm \
        --endpoints=https://localhost:2379 \
        --cert=/etc/kubernetes/pki/etcd/peer.crt \
        --key=/etc/kubernetes/pki/etcd/peer.key \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt
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
    break)      break_cluster ;;
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
        echo "  break       - Start annotation bomb (fills etcd)"
        echo "  break-status - Alternative: status patch storm"
        echo "  monitor     - Watch etcd size in real-time (run in separate terminal)"
        echo "  recover     - Walk through recovery procedure"
        echo "  guardrails  - Deploy prevention (Kyverno + Prometheus alerts)"
        echo "  cleanup     - Delete the cluster"
        echo "  size        - Check current etcd size"
        ;;
esac
