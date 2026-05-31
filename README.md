# Death by a Thousand Patches: etcd MVCC Exhaustion Demo

> Companion repo for KubeCon 2026 talk: "Death by a Thousand Patches: How Pod Status Updates Exhaust etcd and What to Do About It"

## What This Demonstrates

Every Kubernetes object update stores the **entire object** as a new etcd revision - not a diff. This demo shows how frequent writes fill etcd's storage quota, making the cluster unable to self-heal with no obvious recovery path.

You'll see:
1. A healthy cluster go read-only in under 2 minutes
2. Why you can't `kubectl delete` your way out
3. The exact recovery procedure (compact → defrag → disarm)
4. Guardrails that prevent this from ever happening

## Prerequisites

- [kind](https://kind.sigs.k8s.io/) v0.20+
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Docker](https://docs.docker.com/get-docker/)
- Python 3 (for generating test data)
- Optional: [Kyverno](https://kyverno.io/) (for guardrail demo)

**Minimum resources:** 4 vCPU, 8GB RAM (for 3-node kind cluster under write pressure)

## Quick Start

```bash
# 1. Create cluster with reduced etcd quota
./demo.sh setup

# 2. In a second terminal, watch etcd fill up
./demo.sh monitor

# 3. Start the annotation bomb
./demo.sh break

# 4. Wait for cluster to go read-only (~2 min)
# 5. Try to do anything:
kubectl create namespace test              # FAILS
kubectl delete namespace mvcc-demo         # FAILS
kubectl run test --image=busybox           # FAILS

# 6. Recover
./demo.sh recover

# 7. Deploy guardrails
./demo.sh guardrails

# 8. Cleanup
./demo.sh cleanup
```

## Validated Results

```
$ ./demo.sh break
[DEMO] Creating 50 pods, then patching each with 100KB configmaps...
  Created 50 configmaps. etcd: 47.1 MB / 50 MB
  Created 85 configmaps. etcd: 50.7 MB / 50 MB
  error: failed to create configmap: etcdserver: mvcc: database space exceeded
  error: failed to create configmap: etcdserver: mvcc: database space exceeded
  ...
  WRITES BLOCKED - cluster is read-only!

$ kubectl create namespace test
  Error from server: etcdserver: mvcc: database space exceeded

$ kubectl delete namespace mvcc-demo
  Error from server (InternalError): Internal error occurred: etcdserver: mvcc: database space exceeded

$ kubectl run test --image=busybox
  Error from server: etcdserver: mvcc: database space exceeded
```

### Recovery (validated):
```
$ etcdctl alarm list
  memberID:2583549131277751082 alarm:NOSPACE

$ etcdctl compact 2253
  compacted revision 2253

$ etcdctl defrag
  Finished defragmenting etcd member[...]
  (50.7 MB → 21.8 MB)

$ etcdctl alarm disarm
  memberID:2583549131277751082 alarm:NOSPACE

$ kubectl create namespace recovery-test
  namespace/recovery-test created   ← cluster is back
```

## Business Impact

When etcd quota is exceeded:

| Action | Result |
|--------|--------|
| Deploy new pods | ❌ Blocked |
| Scale deployments | ❌ Blocked |
| Delete a namespace | ❌ Blocked (finalizer cascade requires writes) |
| HPA/VPA autoscaling | ❌ Dead |
| Node lease renewals | ❌ Fail → nodes marked Unknown |
| Pod eviction | ❌ Can't write eviction records |
| Endpoint updates | ❌ Restarted pods won't rejoin services |
| Certificate rotation | ❌ Can't write new secrets |

### What happens to existing pods?

Existing pods **continue serving traffic** as long as they don't crash. But the cluster's self-healing is completely dead:

1. **Node leases fail** → nodes marked `Unknown` within 40 seconds
2. **Pod eviction can't execute** → nodes are `Unknown` but pods aren't rescheduled (eviction requires a write)
3. **Endpoints freeze** → if a pod restarts, its new IP is never registered in service endpoints
4. **Liveness probe results can't be written** → no automatic restart on failure
5. **A single pod crash becomes permanent** → nothing can recover it, reschedule it, or update its service registration

This is a **silent degradation**: everything looks fine until the first pod restart, then cascading failures begin with no automatic recovery.

**Blast radius:** Entire cluster. Every namespace, every team, every workload.

**Recovery time:** ~30 seconds if you know the exact steps. Hours if you don't (most teams discover this during the incident). On managed Kubernetes, you cannot access etcd directly - you must contact your provider.

## How etcd MVCC Works

```
Pod created (15KB)      → Revision 1: [15KB stored]
Pod patched (+50KB ann) → Revision 2: [65KB stored] (FULL copy, not diff)
Pod patched again       → Revision 3: [65KB stored] (another FULL copy)
...
After 1000 patches      → 1000 revisions × 65KB = 65MB for ONE pod
```

Compaction removes old revisions but **does not free disk space**. Defragmentation is required separately. If the quota is hit before compaction runs, the cluster is bricked.

## Recovery Procedure

**Critical:** Steps 3 AND 4 are both required. Compaction removes old revisions from the logical database but does NOT free physical disk space. Defragmentation is what actually reclaims bytes. Most runbooks miss this.

```bash
# 1. Confirm the alarm
etcdctl alarm list
# Expected: memberID:XXXX alarm:NOSPACE

# 2. Get current revision
REV=$(etcdctl endpoint status --write-out=json | \
  python3 -c "import sys,json; print(json.loads(sys.stdin.read())[0]['Status']['header']['revision'])")

# 3. Compact (removes old revisions from logical DB)
etcdctl compact $REV

# 4. Defragment (frees physical disk space - THIS IS THE STEP PEOPLE MISS)
etcdctl defrag

# 5. Disarm the alarm
etcdctl alarm disarm

# 6. Verify
kubectl create namespace test && kubectl delete namespace test
```

## Prevention

### 1. Alerting (detect before it happens)

```promql
# Alert at 50% quota - you have days to investigate
etcd_mvcc_db_total_size_in_bytes / etcd_server_quota_backend_bytes > 0.5

# Alert at 75% - incident imminent, page someone
etcd_mvcc_db_total_size_in_bytes / etcd_server_quota_backend_bytes > 0.75

# Compaction falling behind (dead space accumulating)
1 - (etcd_mvcc_db_total_size_in_use_in_bytes / etcd_mvcc_db_total_size_in_bytes) > 0.5

# Anomalous write rate (3x your cluster's normal baseline)
# This auto-adjusts to cluster size - works for 10-node and 10,000-node clusters
rate(etcd_mvcc_put_total[5m]) > 3 * avg_over_time(rate(etcd_mvcc_put_total[5m])[7d:1h])
```

**Understanding these queries:**

```promql
# "Is etcd more than half full?"
etcd_mvcc_db_total_size_in_bytes / etcd_server_quota_backend_bytes > 0.5
#   ↑ current db size in bytes       ↑ maximum allowed size
# Dividing gives you a percentage. 0.5 = 50%.

# "Is dead space piling up?"
1 - (etcd_mvcc_db_total_size_in_use_in_bytes / etcd_mvcc_db_total_size_in_bytes) > 0.5
#         ↑ live data                              ↑ total file on disk
# If total is 80MB but only 30MB is live data, you have 62% dead space.
# Means compaction ran but defrag hasn't - disk isn't being reclaimed.

# "Is something writing abnormally fast right now?"
rate(etcd_mvcc_put_total[5m]) > 3 * avg_over_time(rate(etcd_mvcc_put_total[5m])[7d:1h])
#   ↑ writes per second right now        ↑ average writes per second over the past 7 days
# If right now is more than 3x your normal, something changed.
# A broken controller was deployed, an operator is stuck in a loop, etc.
```

**Why not a fixed write rate threshold?** Because "normal" depends entirely on cluster size. A 10,000-node cluster generates ~250 writes/sec just from node lease renewals alone (10,000 nodes / 40s lease interval). A 50-node cluster might see 5 writes/sec normally. A fixed threshold like "alert at 100/sec" would either never fire on large clusters or constantly fire on them. The 3x-baseline approach catches anomalous spikes (broken controller, runaway operator) without false-alerting, regardless of cluster size.

### 2. Admission Guardrails (manifests/kyverno-annotation-limit.yaml)

Reject pods with annotations exceeding 10KB at admission time. Stops the problem at the source.

### 3. Best Practices

| Practice | Why |
|----------|-----|
| Set `ttlSecondsAfterFinished` on all Jobs | Completed Jobs accumulate forever without this |
| Limit CronJob history (`successfulJobsHistoryLimit: 3`) | Default keeps all history |
| Audit `verb=patch` in API audit logs grouped by user-agent | Finds the controller patching too often |
| Never use annotations as a communication channel between controllers | Each update stores the entire object as a new revision |
| Monitor write rate relative to YOUR baseline | Absolute thresholds don't work across cluster sizes |
| Run defrag on a schedule (not just compaction) | Compaction without defrag doesn't free disk |
| Make controller reconcile loops idempotent | Don't patch status if nothing actually changed |

### 4. Architectural Pattern: Offload High-Churn Data

Move frequently-updated metadata out of pod annotations into separate lightweight CRDs with short TTL:

```yaml
apiVersion: example.io/v1
kind: WorkloadStatus
metadata:
  name: my-pod-status
  ownerReferences: [...]  # garbage collected with the pod
spec:
  lastChecked: "2026-05-31T22:00:00Z"
  metrics: {...}
  ttl: 1h  # auto-cleanup
```

This isolates high-frequency writes to objects that are small and disposable, keeping your core pod/deployment objects stable.

## Demo Scenarios

| Scenario | What It Shows | Time to Break |
|----------|--------------|---------------|
| `break` | Annotation bomb - 50 pods × 100KB configmaps | ~90 seconds |
| `break-status` | Status patch storm - simulates broken controller | ~3 minutes |
| `recover` | Full recovery: compact → defrag → disarm | ~30 seconds |
| `guardrails` | Kyverno policy + Prometheus alerts | Instant |

## Key Learnings from Building This Demo

1. **Auto-compaction can mask the problem in demos.** If annotations cycle through the same keys (overwrite), compaction removes old revisions fast enough to keep up. In production, controllers create unique entries per reconcile cycle, which compaction can't help with. The demo uses unique keys per iteration to be realistic.

2. **Defrag is the missing step.** Compaction marks revisions as deleted but the physical db file doesn't shrink. You must defrag to reclaim space. This is why `etcd_mvcc_db_total_size_in_bytes` (physical) can be much larger than `etcd_mvcc_db_total_size_in_use_in_bytes` (logical).

3. **Deletes are not fully blocked.** Individual object deletes (tombstone markers) sometimes succeed because they're smaller writes. But namespace deletion and any operation that triggers cascading writes will fail. This makes the failure confusing - "I can delete this configmap but not that namespace."

## References

- [etcd documentation: Space quota](https://etcd.io/docs/v3.5/op-guide/maintenance/#space-quota)
- [Kubernetes: Configure and upgrade etcd](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/)
- [KEP-4222: CBOR Serialization](https://github.com/kubernetes/enhancements/issues/4222) (future improvement, ~30% size reduction)
- [Kyverno: Validation Policies](https://kyverno.io/docs/writing-policies/validate/)

## License

MIT
