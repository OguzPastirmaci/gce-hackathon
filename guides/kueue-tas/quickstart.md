# Kueue Topology-Aware Scheduling (TAS) with MPIJobs on OKE - Quickstart

## Prerequisites

- Kueue v0.17.0+
- OCI RDMA topology labels on nodes (`oci.oraclecloud.com/rdma.hpc_island_id`, `network_block_id`, `local_block_id`)
- Kubeflow MPI Operator

## 1. Create the Topology resource

```bash
kubectl apply -f - <<'EOF'
apiVersion: kueue.x-k8s.io/v1beta1
kind: Topology
metadata:
  name: oci-rdma
spec:
  levels:
  - nodeLabel: "oci.oraclecloud.com/rdma.hpc_island_id"
  - nodeLabel: "oci.oraclecloud.com/rdma.network_block_id"
  - nodeLabel: "oci.oraclecloud.com/rdma.local_block_id"
  - nodeLabel: "kubernetes.io/hostname"
EOF
```

## 2. Create ResourceFlavors, ClusterQueue, LocalQueue

```yaml
# CPU flavor for the launcher (no topologyName)
apiVersion: kueue.x-k8s.io/v1beta2
kind: ResourceFlavor
metadata:
  name: cpu-nodes
spec:
  nodeLabels:
    node.kubernetes.io/instance-type: VM.Standard.E5.Flex
---
# GPU flavor with TAS enabled
apiVersion: kueue.x-k8s.io/v1beta2
kind: ResourceFlavor
metadata:
  name: bm-gpu-h100-8
spec:
  nodeLabels:
    node.kubernetes.io/instance-type: BM.GPU.H100.8
    nvidia.com/gpu: "true"
  topologyName: oci-rdma
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: gpu-queue
spec:
  namespaceSelector: {}
  resourceGroups:
  - coveredResources: ["cpu", "memory", "nvidia.com/gpu", "ephemeral-storage"]
    flavors:
    # cpu-nodes first: launcher (0 GPUs) matches here
    - name: cpu-nodes
      resources:
      - name: cpu
        nominalQuota: "100"
      - name: memory
        nominalQuota: "200Gi"
      - name: nvidia.com/gpu
        nominalQuota: "0"
      - name: ephemeral-storage
        nominalQuota: "100Gi"
    # Workers fall through here (need GPUs)
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

## 3. MPIJob with TAS annotations

Key requirements for the MPIJob:

**Launcher:**
- Needs `resources.requests` (cpu/memory) -- TAS cannot assign a flavor to a podset with zero resource requests
- No topology annotation needed -- without it, Kueue assigns the non-TAS `cpu-nodes` flavor
- No GPU toleration needed -- runs on CPU nodes

**Worker:**
- Add `kueue.x-k8s.io/podset-preferred-topology` annotation with the desired topology level
- Must have explicit `nvidia.com/gpu` toleration -- TAS evaluates taints at admission time, before the GPU device plugin adds automatic tolerations

```yaml
mpiReplicaSpecs:
  Launcher:
    replicas: 1
    template:
      metadata:
        labels:
          nccl-test-replica: mpi-launcher
      spec:
        containers:
        - name: mpi-launcher
          resources:
            requests:
              cpu: "2"
              memory: "8Gi"
          # ... rest of launcher spec
  Worker:
    replicas: 2
    template:
      metadata:
        annotations:
          kueue.x-k8s.io/podset-preferred-topology: oci.oraclecloud.com/rdma.local_block_id
      spec:
        tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
        # ... rest of worker spec
```

## 4. Check topology assignments

```bash
# See which nodes were assigned and their local blocks
kubectl get workload -o json | jq -r '
  .items[0].status.admission.podSetAssignments[].topologyAssignment?.slices[]?.valuesPerLevel[0].individual |
  .roots[] as $r | .prefix + $r' | \
xargs -I{} kubectl get node {} -o jsonpath='{.metadata.labels.oci\.oraclecloud\.com/rdma\.local_block_id}{"\t"}{.metadata.name}{"\n"}' | sort
```

## Topology levels

| Annotation value | Behavior |
|---|---|
| `oci.oraclecloud.com/rdma.local_block_id` | Prefer same local block (tightest RDMA locality) |
| `oci.oraclecloud.com/rdma.network_block_id` | Prefer same network block |
| `oci.oraclecloud.com/rdma.hpc_island_id` | Prefer same HPC island (loosest) |

Use `podset-preferred-topology` to allow fallback to higher levels when capacity is insufficient. Use `podset-required-topology` to reject the workload if it can't fit at the requested level.
