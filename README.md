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

**Minimum resources:** 4 vCPU, 8GB RAM (for 3-node kind cluster under write pressure)

## Quick Start

```bash
# Guided stage flow: setup → size → break → recover → guardrails
./demo.sh

# If you already had this demo cluster, use this instead so kind picks up
# the current 10-minute compaction window:
RESET_CLUSTER=1 ./demo.sh

# When the guided flow asks, open a second terminal and run:
./demo.sh monitor
```

To run one section directly without the guided prompts:

```bash
./demo.sh setup
./demo.sh break
./demo.sh recover
./demo.sh guardrails
```

## Validated Results

```
$ ./demo.sh break
[DEMO] === SCENARIO: Status Patch Storm ===
[DEMO] Replicas: 80 | payload: 96KiB/pod | parallelism: 20
[DEMO] Patching status on 80 pods as fast as the API server accepts it...

  Iteration 9 | elapsed 11s
  etcd db size: 92.5 MB / 100.0 MB (92%)
  etcd in-use:  89.7 MB
  dead space:   2.8 MB
  etcd alarm: none

  Iteration 11 | elapsed 13s
  etcd db size: 100.2 MB / 100.0 MB (100%)
  etcd alarm: NOSPACE

  kubectl get namespace mvcc-demo  # OK
  Error from server: etcdserver: mvcc: database space exceeded
  ...
  WRITES BLOCKED - cluster is read-only!

$ kubectl create namespace test
  Error from server: etcdserver: mvcc: database space exceeded

$ kubectl delete namespace mvcc-demo
  Error from server (InternalError): Internal error occurred: etcdserver: mvcc: database space exceeded

$ kubectl run test --image=busybox
  Error from server: etcdserver: mvcc: database space exceeded
```

## Stage Tuning

The defaults are intentionally stage-biased:

```bash
STATUS_REPLICAS=80
STATUS_PAYLOAD_BYTES=98304   # 96KiB condition message per pod
STATUS_PARALLELISM=20
STATUS_DEADLINE_SECONDS=90
STATUS_IMAGE=registry.k8s.io/pause:3.10
TEST_IMAGE=busybox:latest
DEMO_PROMPT=<auto>         # no args: prompts on; explicit scenario: prompts off
DEMO_COMMAND_PAUSE=<auto>  # no args: major; explicit scenario: 0
```

To force or disable prompts:

```bash
DEMO_PROMPT=1 ./demo.sh break
DEMO_PROMPT=0 ./demo.sh break
```

Command pause modes:

```bash
DEMO_PROMPT=1 DEMO_COMMAND_PAUSE=major ./demo.sh break  # balanced stage mode
DEMO_PROMPT=1 DEMO_COMMAND_PAUSE=all ./demo.sh break    # pause before every shown command
DEMO_PROMPT=1 DEMO_COMMAND_PAUSE=0 ./demo.sh break      # section prompts only
```

To run the admission guardrail demo:

```bash
./demo.sh guardrails
```

The stage path uses Kubernetes' built-in `ValidatingAdmissionPolicy`, so it does not install any add-on admission controller and does not need internet.

## Offline Stage Mode

Do not depend on conference Wi-Fi for the live demo. Prepare once while you have internet:

```bash
./demo.sh offline-prep
RESET_CLUSTER=1 PRELOAD_IMAGES=1 ./demo.sh setup
./demo.sh guardrails
./demo.sh offline-check
```

That flow pulls the workload images for the kind node platform, preloads them into the kind worker nodes when the cluster exists, and verifies the laptop can run without fetching from registries during the talk. Monitoring and recovery use the kind control-plane container directly, so there is no separate etcd monitor image to pull.

`offline-prep` detects the kind/Docker platform automatically, usually `linux/amd64` or `linux/arm64`, and pulls images for that platform.

If you need to prepare on one machine and move the demo bundle to another, export/import the image cache:

```bash
# On the connected prep machine, after offline-prep:
./demo.sh offline-export

# Copy offline-assets/ to the demo laptop, then:
./demo.sh offline-import
```

For the stage run, use:

```bash
./demo.sh
```

If you want to recreate the kind cluster while offline, pin and cache the kind node image ahead of time:

```bash
KIND_NODE_IMAGE=kindest/node:<version> ./demo.sh offline-prep
KIND_NODE_IMAGE=kindest/node:<version> RESET_CLUSTER=1 PRELOAD_IMAGES=1 ./demo.sh setup
```

The lowest-risk stage path is to create and recover the kind cluster before the talk, then run the guided flow against that already-warm local cluster.

If rehearsal does not cross quota fast enough, use one of these:

```bash
STATUS_REPLICAS=100 ./demo.sh break
STATUS_PAYLOAD_BYTES=131072 ./demo.sh break
```

If your laptop is struggling, lower pressure but keep the compaction window at `10m`:

```bash
STATUS_REPLICAS=60 STATUS_PAYLOAD_BYTES=65536 ./demo.sh break
```

### Recovery (validated):
```
$ etcdctl alarm list
  memberID:2583549131277751082 alarm:NOSPACE

$ etcdctl compact 2253
  compacted revision 2253

$ etcdctl defrag
  Finished defragmenting etcd member[...]
  (100.2 MB → 9.2 MB)

$ etcdctl alarm disarm
  memberID:2583549131277751082 alarm:NOSPACE

$ kubectl create namespace recovery-test
  namespace/recovery-test created   ← cluster is back

$ kubectl delete namespace recovery-test --wait=false
  namespace "recovery-test" deleted
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
kubectl create namespace test && kubectl delete namespace test --wait=false
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

**Why not a fixed write rate threshold?** Because "normal" depends entirely on cluster size. A 10,000-node cluster generates ~1,000 writes/sec just from node lease renewals alone (10,000 nodes / 10s lease update interval). A 50-node cluster might see 5 writes/sec normally. A fixed threshold like "alert at 100/sec" would either never fire on large clusters or constantly fire on them. The 3x-baseline approach catches anomalous spikes (broken controller, runaway operator) without false-alerting, regardless of cluster size.

### 2. Admission Guardrails (manifests/native-pod-mvcc-guardrails.yaml)

Use Kubernetes' built-in `ValidatingAdmissionPolicy` to reject known high-risk pod writes before they become etcd revisions:

- pod annotation entries over 10KiB
- pod label entries over 2KiB
- pod status condition messages over 10KiB on the `pods/status` subresource

This catches both common metadata bloat and the status-patch storm used in the demo, without installing a third-party admission controller. It is not a claim that annotations are the only risk; unexpected write paths still need audit-log grouping by resource/user-agent and write-rate alerts against the cluster's own baseline.

Advanced production option: teams that already run Kyverno, or need richer policy lifecycle controls, can express the same CEL checks as Kyverno `ValidatingPolicy` resources. That adds policy-as-code packaging, background scans, PolicyReports, fine-grained PolicyExceptions, namespace-scoped policy ownership, CLI/unit testing, and optional generation of native `ValidatingAdmissionPolicy` objects. The stage demo stays native so it has no add-on or internet dependency, but Kyverno is a strong implementation path when you need central policy governance across many clusters.

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
| `guided` or no argument | Full stage flow with prompts: setup → size → break → recover → guardrails | End-to-end |
| `break` | Stage path: pod status storm - simulates a broken controller | ~45-90 seconds |
| `break-annotations` | Annotation patch storm for comparison | Hardware-dependent |
| `recover` | Full recovery: compact → defrag → disarm | ~30 seconds |
| `guardrails` | Native admission policy + Prometheus alerts | Instant |
| `offline-prep` | Cache manifests/images before the conference | Prep step |
| `offline-check` | Verify no live internet dependency remains | Prep step |
| `offline-export` | Save cached demo images into `offline-assets/demo-images.tar` | Prep step |
| `offline-import` | Load cached demo images from `offline-assets/demo-images.tar` | Prep step |

## Key Learnings from Building This Demo

1. **Auto-compaction can mask the problem in demos.** The first version used 30-second auto-compaction and small status messages, so etcd reused freed pages about as fast as the demo created new pressure. That is why a run can plateau around 40-50% instead of hitting NOSPACE. The kind config now uses a 10-minute compaction window so the stage demo finishes before old revisions are reclaimed.

2. **Defrag is the missing step.** Compaction marks revisions as deleted but the physical db file doesn't shrink. You must defrag to reclaim space. This is why `etcd_mvcc_db_total_size_in_bytes` (physical) can be much larger than `etcd_mvcc_db_total_size_in_use_in_bytes` (logical).

3. **Reads still work after NOSPACE.** `kubectl get` can succeed even though all writes are rejected. The script checks `etcdctl alarm list` for `NOSPACE` and then demonstrates both sides: a successful read and a failed tiny write.

4. **Deletes are not fully blocked.** Individual object deletes (tombstone markers) sometimes succeed because they're smaller writes. But namespace deletion and any operation that triggers cascading writes will fail. This makes the failure confusing - "I can delete this configmap but not that namespace."

## References

- [etcd documentation: Space quota](https://etcd.io/docs/v3.5/op-guide/maintenance/#space-quota)
- [Kubernetes: Configure and upgrade etcd](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/)
- [KEP-4222: CBOR Serialization](https://github.com/kubernetes/enhancements/issues/4222) (future improvement, ~30% size reduction)
- [Kubernetes: ValidatingAdmissionPolicy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
- [Kyverno: ValidatingPolicy](https://kyverno.io/docs/policy-types/validating-policy/)

## License

MIT
