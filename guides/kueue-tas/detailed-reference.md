# Kueue Topology-Aware Scheduling (TAS) with MPIJobs on OKE - Detailed Reference

## Overview

Kueue's Topology-Aware Scheduling (TAS) enables workload placement based on the physical network topology of OCI bare metal GPU instances. On OKE, RDMA-connected GPU nodes are organized into a hierarchy:

```
HPC Island
  └── Network Block
        └── Local Block
              └── Host (node)
```

Nodes within the same local block have the lowest RDMA latency. TAS uses this hierarchy to co-locate GPU workers for optimal collective communication (NCCL/RCCL) performance.

## Architecture

### OCI RDMA Topology Labels

OKE automatically applies these labels to RDMA-capable nodes:

| Label | Hierarchy | Description |
|---|---|---|
| `oci.oraclecloud.com/rdma.hpc_island_id` | Tier 2 | HPC island (broadest grouping) |
| `oci.oraclecloud.com/rdma.network_block_id` | Tier 1 | Network block |
| `oci.oraclecloud.com/rdma.local_block_id` | Tier 0 | Local block (best RDMA locality) |
| `kubernetes.io/hostname` | Node | Individual host |

### Kueue TAS Components

1. **Topology** -- Defines the hierarchy of node labels that represent the physical topology
2. **ResourceFlavor** -- Links node labels to a topology via `topologyName`
3. **ClusterQueue** -- Defines resource quotas per flavor; flavor ordering controls assignment priority
4. **Pod annotations** -- `podset-preferred-topology` or `podset-required-topology` on the pod template

## MPIJob-Specific Requirements

MPIJobs have two pod sets (Launcher and Worker) with different scheduling needs. TAS introduces several requirements that don't exist without topology awareness.

### Requirement 1: Launcher needs resource requests

Without TAS, the launcher runs fine with `resources: {}`. With TAS, Kueue must assign every podset a flavor and track its resources in the topology tree. A podset with zero resource requests cannot be assigned.

**Error without resource requests:**
```
failed to assign flavors to pod set launcher: no TAS flavor assigned
```

**Fix:** Add cpu/memory requests to the launcher container:
```yaml
resources:
  requests:
    cpu: "2"
    memory: "8Gi"
```

### Requirement 2: Separate flavor for the launcher

When the only ResourceFlavor has `topologyName` set, all podsets go through TAS -- including the launcher. Since the launcher doesn't need GPU topology awareness and shouldn't consume a GPU node slot, use a two-flavor approach:

1. A non-TAS `cpu-nodes` flavor (no `topologyName`) listed first in the ClusterQueue
2. A TAS-enabled `gpu-nodes` flavor listed second

The launcher (0 GPU requests) matches `cpu-nodes` first. Workers (8 GPU requests) can't use `cpu-nodes` (0 GPU quota) and fall through to the TAS flavor.

**Error when launcher uses GPU TAS flavor:**
```
topology "oci-rdma" doesn't allow to fit any of 1 pod(s). Total nodes: 26; excluded: taint "nvidia.com/gpu=present:NoSchedule": 26
```

This happens because GPU nodes have the `nvidia.com/gpu=present:NoSchedule` taint and the launcher doesn't tolerate it.

**Do NOT use `kueue.x-k8s.io/podset-unconstrained-topology: "true"` on the launcher** -- this annotation forces Kueue to use a TAS-enabled flavor. Without any topology annotation, Kueue naturally picks the first matching non-TAS flavor.

### Requirement 3: Explicit GPU tolerations on workers

Without TAS, the GPU device plugin automatically injects a toleration for `nvidia.com/gpu=present:NoSchedule` when a pod requests GPU resources. However, TAS evaluates node fitness (including taints) at **admission time**, before the pod is actually scheduled and before the device plugin acts.

**Fix:** Add explicit tolerations to the worker pod template:
```yaml
tolerations:
- key: nvidia.com/gpu
  operator: Exists
  effect: NoSchedule
```

## ClusterQueue Configuration

The two-flavor ClusterQueue is the key to separating launcher and worker scheduling:

```yaml
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: gpu-queue
spec:
  namespaceSelector: {}
  resourceGroups:
  - coveredResources: ["cpu", "memory", "nvidia.com/gpu", "ephemeral-storage"]
    flavors:
    # Listed FIRST: launcher matches here (0 GPUs needed, 0 GPU quota available)
    - name: cpu-nodes
      resources:
      - name: cpu
        nominalQuota: "100"
      - name: memory
        nominalQuota: "200Gi"
      - name: nvidia.com/gpu
        nominalQuota: "0"        # Zero GPU quota forces GPU workloads to next flavor
      - name: ephemeral-storage
        nominalQuota: "100Gi"
    # Listed SECOND: workers fall through here (need GPUs, TAS-enabled)
    - name: bm-gpu-h100-8
      resources:
      - name: cpu
        nominalQuota: "20000"
      - name: memory
        nominalQuota: "102400Gi"
      - name: nvidia.com/gpu
        nominalQuota: "1600"
      - name: ephemeral-storage
        nominalQuota: "6400Gi"
```

## Topology Annotations

### `podset-preferred-topology` (recommended)

```yaml
kueue.x-k8s.io/podset-preferred-topology: oci.oraclecloud.com/rdma.local_block_id
```

Kueue tries to place all workers within the same local block. If capacity is insufficient, it falls back up the hierarchy:
1. Try a single local block
2. Fall back to network block (distribute across multiple local blocks)
3. Fall back to HPC island (distribute across multiple network blocks)

### `podset-required-topology`

```yaml
kueue.x-k8s.io/podset-required-topology: oci.oraclecloud.com/rdma.local_block_id
```

Kueue rejects the workload entirely if all workers can't fit within a single domain at the requested level. Use this when cross-domain communication would be unacceptable.

### `podset-unconstrained-topology`

```yaml
kueue.x-k8s.io/podset-unconstrained-topology: "true"
```

No topology constraints. **Warning:** This forces Kueue to use a TAS-enabled flavor. Do not use this on the launcher -- omit topology annotations instead so Kueue picks the non-TAS flavor.

## TAS Pod Distribution Algorithm

### How fallback works

When pods can't fit in a single domain at the preferred level, TAS falls back to the parent level and distributes pods across child domains using a **greedy best-fit** algorithm:

1. Sort domains by capacity (descending)
2. Take full capacity of each domain until the count is satisfied
3. For the last domain, use best-fit (smallest domain that can hold the remaining pods)

### Effective capacity vs node count

TAS considers **effective capacity**, not just node count. Nodes that are cordoned (`spec.unschedulable: true`), have unmatched taints, or lack sufficient resources are excluded. Always check effective capacity:

```bash
kubectl get nodes -l node.kubernetes.io/instance-type=BM.GPU.H100.8 \
  --field-selector=spec.unschedulable!=true \
  -o custom-columns="LOCAL_BLOCK:.metadata.labels.oci\.oraclecloud\.com/rdma\.local_block_id" \
  --no-headers | sort | uniq -c | sort -rn
```

### TASBalancedPlacement feature gate

Kueue v0.17.0 includes an optional `TASBalancedPlacement` feature gate that uses dynamic programming to find optimal domain sets. Enable it with:

```bash
helm upgrade kueue oci://registry.k8s.io/kueue/charts/kueue --version 0.17.0 -n kueue-system \
  --set "controllerManager.featureGates[0].name=TASBalancedPlacement" \
  --set "controllerManager.featureGates[0].enabled=true"
```

**Findings from testing (Kueue v0.17.0):**

- Balanced placement optimizes for **even distribution** across domains, not for minimizing cross-domain traffic
- When the only valid packing is unique (total effective capacity barely exceeds the request), both greedy and balanced produce identical results
- Neither mode implements a "pack-first" strategy that would maximize pods per local block -- both distribute across domains rather than filling blocks to capacity before spilling
- For NCCL/RCCL workloads where minimizing cross-block traffic matters, the practical impact depends on whether multiple valid packings exist given the effective block sizes

### Code reference (Kueue v0.17.0)

The core TAS logic lives in:
- `pkg/cache/scheduler/tas_flavor_snapshot.go` -- Main assignment logic (`findTopologyAssignment`, `findLevelWithFitDomains`, `updateCountsToMinimumGeneric`)
- `pkg/cache/scheduler/tas_balanced_placement.go` -- Balanced placement DP algorithm (`selectOptimalDomainSetToFit`, `placeSlicesOnDomainsBalanced`)

Key functions:
- **`findLevelWithFitDomains`** (line ~1200): Tries to fit pods at the preferred level, recursively falls back to parent levels
- **`updateCountsToMinimumGeneric`** (line ~1356): Greedy pod-to-domain assignment with best-fit for the last domain
- **`balanceThresholdValue`** (line ~66): Calculates the minimum pods per domain for balanced placement
- **`selectOptimalDomainSetToFit`** (line ~82): DP to find minimum-capacity domain subset

## Observability

### Check workload admission status

```bash
kubectl get workloads -o wide
kubectl get workload <name> -o jsonpath='{.status.conditions[*].message}'
```

### Check topology assignments

```bash
# Node list from workload
kubectl get workload -o json | jq -r '
  .items[0].status.admission.podSetAssignments[] |
  select(.topologyAssignment) | {name, topologyAssignment}'

# Nodes grouped by local block
kubectl get workload -o json | jq -r '
  .items[0].status.admission.podSetAssignments[].topologyAssignment?.slices[]?.valuesPerLevel[0].individual |
  .roots[] as $r | .prefix + $r' | \
xargs -I{} kubectl get node {} \
  -o jsonpath='{.metadata.labels.oci\.oraclecloud\.com/rdma\.local_block_id}{"\t"}{.metadata.name}{"\n"}' | sort
```

### Check Kueue controller logs

```bash
kubectl logs -n kueue-system deployment/kueue-controller-manager --tail=50 | grep -E "failed|error"
```

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `no flavor assigned` / `no TAS flavor assigned` | Launcher has no resource requests | Add `resources.requests` (cpu/memory) to launcher |
| `taint "nvidia.com/gpu=present:NoSchedule"` excluded all nodes | Pod doesn't tolerate GPU taint | Add explicit `nvidia.com/gpu` toleration |
| `topology "oci-rdma" doesn't allow to fit` | Requested topology can't hold pods | Check effective capacity (cordoned nodes, resource limits) |
| Pods spread across more blocks than expected | Cordoned/unschedulable nodes reduce effective block sizes | Check `kubectl get nodes --field-selector=spec.unschedulable!=true` |
| Workload stuck in Pending | ClusterQueue inactive or flavor mismatch | Check `kubectl get clusterqueue -o wide` and workload conditions |
