# Deploying Soperator on OKE (via oci-hpc-oke)

This guide covers deploying [Soperator](https://github.com/nebius/soperator) (a Kubernetes Operator for Slurm) on an Oracle Kubernetes Engine (OKE) cluster provisioned using the [oci-hpc-oke](https://github.com/oracle-quickstart/oci-hpc-oke) Terraform module.

> **Caveat**: Soperator is developed and tested on Nebius AI cloud. The project README states: *"We haven't tested it anywhere outside Nebius AI, so it's likely that something won't work out of the box."* Expect some adaptation work.
>
> **Tested with**: Soperator v3.0.2, Slurm 25.11.3, OKE K8s v1.34.2, VCN-Native Pod Networking, OCI FSS, VM.GPU.A10.1 shape.

## Table of Contents

- [What is Soperator?](#what-is-soperator)
- [Prerequisites](#prerequisites)
- [Step 1 — Deploy the OKE Cluster](#step-1--deploy-the-oke-cluster)
- [Step 2 — CNI / Source IP Preservation](#step-2--cni--source-ip-preservation)
- [Step 3 — Install cert-manager](#step-3--install-cert-manager)
- [Step 4 — Container Images](#step-4--container-images)
- [Step 5 — Create the Namespace](#step-5--create-the-namespace)
- [Step 6 — Provision Shared Storage (Jail Filesystem)](#step-6--provision-shared-storage-jail-filesystem)
- [Step 7 — Install Soperator CRDs](#step-7--install-soperator-crds)
- [Step 8 — Install the Soperator Operator](#step-8--install-the-soperator-operator)
- [Step 9 — Add Topology Labels to GPU Nodes](#step-9--add-topology-labels-to-gpu-nodes)
- [Step 10 — Deploy the Slurm Cluster](#step-10--deploy-the-slurm-cluster)
- [Step 11 — Deploy NodeSets (Worker Nodes)](#step-11--deploy-nodesets-worker-nodes)
- [Step 12 — Post-Deploy: Write Slurm Scripts to Jail](#step-12--post-deploy-write-slurm-scripts-to-jail)
- [Step 13 — Verify the Deployment](#step-13--verify-the-deployment)
- [RDMA on OKE (Cluster Networks)](#rdma-on-oke-cluster-networks)
- [Known Issues on OKE (v3.0.2)](#known-issues-on-oke-v302)
- [Key Challenges on OKE](#key-challenges-on-oke)
- [Recommended Order of Operations](#recommended-order-of-operations)

---

## What is Soperator?

Soperator is a Kubernetes operator that runs Slurm clusters inside Kubernetes. It lets you use Slurm's advanced HPC scheduling while leveraging Kubernetes for orchestration, self-healing, and scaling. It is designed for GPU-accelerated ML training and HPC workloads.

Key concepts:

- **Jail filesystem** — A shared `ReadWriteMany` persistent volume mounted as the root `/` on all worker and login nodes. Changes on one node are immediately visible on all others.
- **Node types** — Controller (slurmctld), Login (SSH access), Worker (compute), Exporter (metrics).
- **CRDs** — `SlurmCluster`, `NodeSet`, `NodeConfigurator`, `ActiveCheck`, etc.

---

## Prerequisites

| Requirement | OKE (oci-hpc-oke) Status |
|---|---|
| Kubernetes >= 1.29 (1.31+ ideal) | OKE supports this |
| CNI preserving client source IP | **Requires work** — see [Step 2](#step-2--cni--source-ip-preservation) |
| NVIDIA GPU Operator | oci-hpc-oke installs this |
| cert-manager | Must install separately |
| Shared `ReadWriteMany` storage (NFS) | OCI FSS or in-cluster NFS server |
| Container images accessible from cluster | Available at `cr.eu-north1.nebius.cloud/soperator/` (mirror to OCIR only if needed) |
| OpenKruise | Installed automatically by the soperator Helm chart (set `kruise.installOperator: true`) |

---

## Step 1 — Deploy the OKE Cluster

Deploy your OKE cluster with `oci-hpc-oke` as usual. Ensure you have at minimum:

- **An operational (CPU) node pool** — for the soperator controller, login nodes, exporter, and accounting components.
- **A GPU node pool** — for Slurm worker nodes (e.g. `BM.GPU.H100.8`, `BM.GPU.A100-v2.8`, `VM.GPU.A10.1`, etc.).

Take note of the node pool names — you will use them in `k8sNodeFilters` to schedule pods on the correct nodes via the `oke.oraclecloud.com/pool.name` label.

> **Note**: On OKE, the label key is `oke.oraclecloud.com/pool.name` (not `oci.oraclecloud.com/pool.name`).

---

## Step 2 — CNI / Source IP Preservation

Soperator requires the CNI to preserve client source IP for Slurm inter-node communication. The project only officially tests with [Cilium in kube-proxy replacement mode](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/).

OKE uses either **flannel** or **OCI VCN-Native Pod Networking** by default — neither of which is Cilium.

### Option A — OCI VCN-Native Pod Networking (recommended for OKE)

VCN-Native Pod Networking assigns real VCN IP addresses directly to pods. This has been tested and works for Slurm inter-node communication. You can verify it's active by checking for the `oci.oraclecloud.com/vcn-native-ip-cni=true` label on your nodes.

Set the SSH service to `NodePort` since OCI Load Balancers SNAT traffic:

```yaml
sshdServiceType: "NodePort"
sshdServiceNodePort: 30022
```

### Option B — Install Cilium on OKE

Replace kube-proxy with Cilium for the officially supported path:

```bash
cilium install --set kubeProxyReplacement=true
```

This requires careful handling since OKE manages kube-proxy. You may need to use a self-managed node pool or work around the managed kube-proxy.

### Option C — NodePort with externalTrafficPolicy

If source IP preservation only matters for the SSH login service, use `NodePort` with `externalTrafficPolicy: Local`:

```yaml
sshdServiceType: "NodePort"
sshdServiceNodePort: 30022
```

---

## Step 3 — Install cert-manager

Soperator uses cert-manager for webhook certificate management:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s
```

---

## Step 4 — Container Images

All soperator images are publicly available at `cr.eu-north1.nebius.cloud/soperator/`. The Helm charts use this registry by default, so no mirroring is required as long as your OKE cluster can reach the Nebius registry.

Verify connectivity from a cluster node:

```bash
kubectl run test-pull --rm -it --restart=Never \
  --image=cr.eu-north1.nebius.cloud/soperator/munge:3.0.2-slurm25.11.3 \
  -- echo "pull OK"
```

> **Note**: The munge container will exit with an error about missing munge key — this is expected. The important thing is that the image was pulled successfully.

<details>
<summary><strong>Optional: Mirror to OCIR</strong></summary>

If your cluster has egress restrictions or you want images closer to your OCI region, mirror them to OCIR:

```bash
IMAGES=(
  "slurm-operator:3.0.2"
  "controller_slurmctld:3.0.2-slurm25.11.3"
  "controller_slurmdbd:3.0.2-slurm25.11.3"
  "worker_slurmd:3.0.2-slurm25.11.3"
  "login_sshd:3.0.2-slurm25.11.3"
  "munge:3.0.2-slurm25.11.3"
  "populate_jail:3.0.2-slurm25.11.3-cuda12.9.0"  # CUDA version suffix is required
  "slurmrestd:3.0.2-slurm25.11.3"
  "soperator-exporter:3.0.2-slurm25.11.3"
  "sconfigcontroller:3.0.2"
)

NEBIUS_REG="cr.eu-north1.nebius.cloud/soperator"
OCI_REG="<region>.ocir.io/<tenancy-namespace>/soperator"

for img in "${IMAGES[@]}"; do
  docker pull "${NEBIUS_REG}/${img}"
  docker tag "${NEBIUS_REG}/${img}" "${OCI_REG}/${img}"
  docker push "${OCI_REG}/${img}"
done
```

If your OCIR repository is private, create an `imagePullSecret` in the relevant namespaces:

```bash
kubectl create secret docker-registry ocir-secret \
  --docker-server=<region>.ocir.io \
  --docker-username='<tenancy-namespace>/oracleidentitycloudservice/<email>' \
  --docker-password='<auth-token>' \
  -n soperator-system

kubectl create secret docker-registry ocir-secret \
  --docker-server=<region>.ocir.io \
  --docker-username='<tenancy-namespace>/oracleidentitycloudservice/<email>' \
  --docker-password='<auth-token>' \
  -n slurm1
```

If mirrored, update all image references in the values files below to point to your OCIR registry instead of `cr.eu-north1.nebius.cloud/soperator/`.

</details>

---

## Step 5 — Create the Namespace

The namespace must match the cluster name. Create it now so the jail PVC can be created in the next step:

```bash
kubectl create namespace slurm1
```

---

## Step 6 — Provision Shared Storage (Jail Filesystem)

The "jail" is a shared `ReadWriteMany` filesystem mounted on all worker and login nodes.

> **Important**: The jail PV/PVC must be **empty or contain a valid rootfs** before the populate-jail job runs. If the FSS volume has OCI's `.snapshot` directory (which cannot be deleted), the populate-jail `restic restore --delete` will report `unlinkat /mnt/jail/.snapshot: permission denied` — this is cosmetic and the jail will be populated correctly. Set `populateJail.overwrite: true` on first deploy if the volume is not empty.

### Option A — OCI File Storage Service (FSS) (recommended)

1. Create an FSS file system, mount target, and export via Terraform or the OCI Console.
2. Create a PV and PVC pointing to it:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: jail-pv
spec:
  capacity:
    storage: 2Ti
  accessModes:
    - ReadWriteMany
  mountOptions:
    - nfsvers=3
  nfs:
    server: <fss-mount-target-ip>
    path: /jail
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jail-pvc
  namespace: slurm1
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  resources:
    requests:
      storage: 2Ti
  volumeName: jail-pv
```

```bash
kubectl apply -f jail-pv-pvc.yaml
```

> **FSS `.snapshot` directory**: OCI FSS creates a `.snapshot` directory that cannot be deleted. The populate-jail job (which uses `restic restore`) will report 1 error when it tries to remove `.snapshot` — this is cosmetic and the jail will be populated correctly despite the error.

### Option B — In-cluster NFS server

Soperator includes an `nfs-server` Helm chart at `helm/nfs-server/` that can be used to run an NFS server pod backed by an OCI Block Volume.

> **Warning**: The in-cluster NFS server does **not** work for populate-jail. The `restic restore` command requires `xattr` support (`system.nfs4_acl`), which the NFS server's filesystem does not provide. This causes ~47,000 errors during jail population. **Use OCI FSS instead.**

For the **controller-spool** volume, use the `oci-bv` StorageClass (ReadWriteOnce is sufficient since only the controller pod uses it).

---

## Step 7 — Install Soperator CRDs

The CRD chart is too large for a single Helm release secret. Use `kubectl apply --server-side` instead:

```bash
kubectl apply --server-side -f ./helm/soperator-crds/templates/
```

Create the namespace for the operator if it doesn't exist:

```bash
kubectl create namespace soperator-system
```

---

## Step 8 — Install the Soperator Operator

First, build Helm dependencies (the chart depends on OpenKruise):

```bash
cd helm/soperator && helm dependency build && cd -
```

Create `soperator-values.yaml`:

```yaml
controllerManager:
  manager:
    image:
      repository: cr.eu-north1.nebius.cloud/soperator/slurm-operator
      tag: "3.0.2"
    env:
      isMariadbCrdInstalled: "false"
      isPrometheusCrdInstalled: "false"
      isOpentelemetryCollectorCrdInstalled: "false"
      isApparmorCrdInstalled: "false"
      slurmOperatorWatchNamespaces: '*'
      # Use standard Kubernetes topology labels instead of Nebius-specific
      topologyLabelPrefix: "topology.kubernetes.io"
    nodeSelector:
      # Schedule operator on the ops/CPU node pool
      oke.oraclecloud.com/pool.name: "<ops-pool-name>"
certManager:
  enabled: true
kruise:
  # MUST be true — the operator requires OpenKruise CRDs (StatefulSet, ResourceDistribution)
  installOperator: true
  manager:
    replicas: 1
    nodeSelector:
      oke.oraclecloud.com/pool.name: "<ops-pool-name>"
serviceMonitor:
  enabled: false  # set to true if Prometheus is installed
```

> **Important**: `kruise.installOperator` **must be `true`**. The operator uses OpenKruise `StatefulSet` and `ResourceDistribution` CRDs. Without them, the operator will crash with: `no matches for kind "StatefulSet" in version "apps.kruise.io/v1beta1"`.

```bash
helm install soperator ./helm/soperator \
  -n soperator-system \
  -f soperator-values.yaml
```

Verify the operator is running:

```bash
kubectl get pods -n soperator-system
# Should show soperator-manager pod with 2/2 Running
```

---

## Step 9 — Add Topology Labels to GPU Nodes

The soperator topology reconciler looks for `{topologyLabelPrefix}/tier-N` labels on nodes — **not** standard `topology.kubernetes.io/zone` or `topology.kubernetes.io/region` labels.

You must add tier labels to your GPU nodes:

```bash
# For each GPU node:
kubectl label node <gpu-node-name> topology.kubernetes.io/tier-1=switch0
```

> **Note**: Use only `tier-1` (the leaf switch level). Adding `tier-0` creates a 3-level hierarchy that can cause topology validation errors in slurmctld. For a simple flat topology, a single `tier-1` label is sufficient.

Verify the topology ConfigMap is populated after the operator reconciles:

```bash
kubectl get configmap topology-node-labels -n slurm1 -o jsonpath='{.data}'
# Should show: {"<node-ip>":"{\"tier-1\":\"switch0\"}"}
```

---

## Step 10 — Deploy the Slurm Cluster

Create `slurm-cluster-values.yaml`. This is the main configuration file — the key adaptations for OKE are around node labels, storage classes, image references, service annotations, and workarounds for dynamic node registration.

```yaml
clusterName: "slurm1"
clusterType: gpu
cudaVersion: "12.9.0"
useDefaultAppArmorProfile: false

# ──────────────────────────────────────────────
# Node filters — map to OKE node pool labels
# ──────────────────────────────────────────────
k8sNodeFilters:
  - name: gpu
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: oke.oraclecloud.com/pool.name
                  operator: In
                  values:
                    - "<gpu-pool-name>"
    tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
  - name: no-gpu
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: oke.oraclecloud.com/pool.name
                  operator: In
                  values:
                    - "<ops-pool-name>"
  - name: system
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: oke.oraclecloud.com/pool.name
                  operator: In
                  values:
                    - "<ops-pool-name>"

# ──────────────────────────────────────────────
# Volume sources
# ──────────────────────────────────────────────
volumeSources:
  - name: jail
    createPVC: false
    storageClassName: ""
    size: ""
    persistentVolumeClaim:
      claimName: "jail-pvc"
      readOnly: false

# ──────────────────────────────────────────────
# Custom Slurm config — required workarounds
# ──────────────────────────────────────────────
# The customSlurmConfig lines are appended to slurm.conf.
# Last-value-wins for duplicate keys.
customSlurmConfig: |
  SlurmctldParameters=conmgr_max_connections=1024,conmgr_threads=32,enable_configless
  NodeName=<worker-name-0> CPUs=<cpus> RealMemory=<mem-mb> Gres=gpu:<count> NodeAddr=<worker-name-0>.slurm1-nodeset-svc.slurm1.svc.cluster.local
  SuspendTime=-1

# ──────────────────────────────────────────────
# Slurm configuration
# ──────────────────────────────────────────────
slurmConfig:
  defMemPerNode: 0
  defCpuPerGPU: 4
  completeWait: 5
  maxJobCount: 20000
  minJobAge: 28800
  messageTimeout: 60
  topologyPlugin: "topology/tree"
  topologyParam: "SwitchAsNodeRank"

# ──────────────────────────────────────────────
# Populate jail settings
# ──────────────────────────────────────────────
populateJail:
  overwrite: true     # Required on first deploy with OCI FSS. See below to switch to false.
  k8sNodeFilterName: "gpu"

# ──────────────────────────────────────────────
# Slurm nodes
# ──────────────────────────────────────────────
slurmNodes:
  controller:
    k8sNodeFilterName: "no-gpu"
    slurmctld:
      resources:
        cpu: "1000m"
        memory: "3Gi"
        ephemeralStorage: "20Gi"
    volumes:
      spool:
        volumeClaimTemplateSpec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
          storageClassName: "oci-bv"
      jail:
        volumeSourceName: "jail"
  login:
    size: 1
    k8sNodeFilterName: "no-gpu"
    sshRootPublicKeys:
      - "ssh-rsa AAAA... your-public-key-here"
    sshdServiceType: "NodePort"
    sshdServiceNodePort: 30022
    volumes:
      jail:
        volumeSourceName: "jail"
  exporter:
    enabled: true
    size: 1
    k8sNodeFilterName: "no-gpu"
    volumes:
      jail:
        volumeSourceName: "jail"

sConfigController:
  node:
    k8sNodeFilterName: "system"
    size: 1
  serviceMonitor:
    enabled: false

# All built-in slurm health checks work on OKE — no need to disable any.
# (Tested with SR-IOV VFs on BM.GPU4.8: all checks pass, nodes not drained.)
```

### About `customSlurmConfig`

Three lines are required as workarounds for v3.0.2 on OKE:

1. **`SlurmctldParameters=...,enable_configless`** — Enables ConfigLess mode in slurmctld.

2. **`NodeName=<worker> ...`** — Required because Slurm 25.11 slurmd reads local slurm.conf to determine its NodeName. Without a matching `NodeName=` line, slurmd exits with `Unable to determine this slurmd's NodeName`. Adjust CPUs, RealMemory, Gres, and NodeAddr per worker. NodeAddr must be the headless service FQDN: `<pod-name>.<headless-svc>.<namespace>.svc.cluster.local`. Pod names follow `{nodeset-name}-{index}` (e.g. `worker-gpu-0`, `worker-gpu-1`).

3. **`SuspendTime=-1`** — Disables Slurm's power management. Without this, nodes get stuck in `CLOUD+POWERING_UP` because the Nebius-specific ResumeProgram doesn't work on OKE.

> **GRES AutoDetect conflict**: Static `NodeName=` entries make nodes "configured". The operator generates `AutoDetect=nvidia` in `gres.conf` (whenever any NodeSet has `gpu.enabled: true`). Slurm rejects AutoDetect on configured nodes. **Workaround**: patch gres.conf with the operator scaled to 0 — see quickstart Steps 11-12 or the RDMA section below.

```bash
helm install slurm-cluster ./helm/slurm-cluster \
  -n slurm1 \
  -f slurm-cluster-values.yaml
```

After the populate-jail job completes (~5-10 min, will show Error due to FSS `.snapshot`), switch to `overwrite: false` and delete the job:

```bash
# In slurm-cluster-values.yaml, change overwrite: true to overwrite: false, then:
helm upgrade slurm-cluster ./helm/slurm-cluster -n slurm1 -f slurm-cluster-values.yaml
kubectl delete job slurm1-populate-jail -n slurm1
```

The operator will recreate the job — it will complete in seconds (valid rootfs detected).

---

## Step 11 — Deploy NodeSets (Worker Nodes)

Create `nodesets-values.yaml`. Adjust CPU, memory, and GPU counts to match your OKE GPU shape.

> **Important**: Ensure the total CPU request (slurmd + munge) fits within the node's allocatable CPUs. OKE reserves some CPUs for system daemons. Check `kubectl describe node <gpu-node>` for the `Allocatable` value.

```yaml
images:
  munge:
    repository: "cr.eu-north1.nebius.cloud/soperator/munge"
    tag: "3.0.2-slurm25.11.3"
  slurmd:
    repository: "cr.eu-north1.nebius.cloud/soperator/worker_slurmd"
    tag: "3.0.2-slurm25.11.3"

nodesets:
  - name: worker-gpu
    replicas: 1  # match your GPU node count
    enableHostUserNamespace: true  # REQUIRED for OCI FSS — NFS doesn't support idmapped mounts
    gpu:
      enabled: true
      nvidia:
        gdrCopyEnabled: false  # set true if GPUDirect RDMA is available
    nodeConfig:
      features: ["gpu", "cuda"]
      # Adjust to match your GPU shape (example: VM.GPU.A10.1)
      static: "Boards=1 SocketsPerBoard=1 CoresPerSocket=15 ThreadsPerCore=2"
      dynamic: "InstanceId={{ .PodName }}"
      gresConfig:
        - "Name=gpu Type=nvidia File=/dev/nvidia[0-7]"  # Explicit GRES — do NOT use AutoDetect with static NodeName entries
    slurmd:
      image:
        repository: "cr.eu-north1.nebius.cloud/soperator/worker_slurmd"
        tag: "3.0.2-slurm25.11.3"
        pullPolicy: "IfNotPresent"
      customEnv:
        - name: "NVIDIA_DRIVER_CAPABILITIES"
          value: "compute,utility,video"
      resources:
        cpu: "26000m"         # adjust to your shape (must fit in allocatable)
        memory: "220Gi"       # adjust to your shape
        ephemeralStorage: "55Gi"
        gpu: 1                # GPUs per node
      volumes:
        spool:
          volumeClaimTemplateSpec:
            storageClassName: "oci-bv"
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: "50Gi"
        jail:
          persistentVolumeClaim:
            claimName: "jail-pvc"
        sharedMemorySize: "16Gi"
      security:
        appArmorProfile: "unconfined"
        # NOTE: procMount cannot be set via Helm — it must be patched on the NodeSet CR after deployment (see Step 12)
    munge:
      image:
        repository: "cr.eu-north1.nebius.cloud/soperator/munge"
        tag: "3.0.2-slurm25.11.3"
        pullPolicy: "IfNotPresent"
      resources:
        cpu: "2000m"
        memory: "4Gi"
        ephemeralStorage: "5Gi"
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: oke.oraclecloud.com/pool.name
                  operator: In
                  values:
                    - "<gpu-pool-name>"
    tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
```

### Key NodeSet adaptations for OKE

| Field | Why |
|---|---|
| `enableHostUserNamespace: true` | **Required** when using OCI FSS. The default (`false`) runs pods in a user namespace, which requires idmapped NFS mounts — OCI FSS does not support this. Without it, workers fail with `MOUNT_ATTR_IDMAP ... invalid argument`. |
| `procMount: "Default"` (via kubectl patch) | **Required** on K8s >= 1.32. The operator generates `procMount: ""` which is rejected. The Helm chart does not template this field — it must be patched on the NodeSet CR after deployment (see Step 12). |
| CPU requests | Must fit within the node's allocatable CPUs. Check with `kubectl describe node`. |

> **RDMA**: For multi-node GPU training with RDMA, see [RDMA on OKE (Cluster Networks)](#rdma-on-oke-cluster-networks).

### Common OKE GPU Shape Reference

| Shape | CPUs | Allocatable CPUs | Memory | GPUs | Notes |
|---|---|---|---|---|---|
| `VM.GPU.A10.1` | 30 | ~29 | 236 Gi | 1x A10 | Good for testing |
| `BM.GPU.A100-v2.8` | 128 | ~126 | 2 TB | 8x A100 80 GB | |
| `BM.GPU.H100.8` | 208 | ~206 | 2 TB | 8x H100 80 GB | |
| `BM.GPU4.8` | 64 | ~62 | 2 TB | 8x A100 40 GB | |
| `BM.GPU.B4.8` | 192 | ~190 | 2.7 TB | 8x B200 | Do not confuse with `BM.GPU4.8` — names are similar but hardware differs |

Adjust `resources.cpu`, `resources.memory`, and `nodeConfig.static` to match your shape. For example, for `BM.GPU.H100.8`:

```yaml
static: "Boards=1 SocketsPerBoard=2 CoresPerSocket=52 ThreadsPerCore=2"
resources:
  cpu: "200000m"
  memory: "1800Gi"
  gpu: 8
```

Deploy the nodesets:

```bash
helm install nodesets ./helm/nodesets \
  -n slurm1 \
  -f nodesets-values.yaml
```

---

## Step 12 — Post-Deploy: Write Slurm Scripts to Jail

The slurm prolog/epilog scripts exist in a ConfigMap but are **not automatically written** to the jail filesystem. You must create a `JailedConfig` CR, fix directory ownership, and create a symlink.

### 12a. Fix jail directory ownership

The sconfigcontroller runs as UID 1001 but the jail's `/opt/slurm_scripts/` directory is owned by root:

```bash
# Run from any pod that mounts the jail:
kubectl exec <worker-pod> -n slurm1 -c slurmd -- \
  chown 1001:1001 /mnt/jail/opt/slurm_scripts
```

### 12b. Create a JailedConfig for slurm scripts

The `slurm-scripts` ConfigMap is automatically created by the slurm-cluster Helm chart. The JailedConfig CR tells the sconfigcontroller to write its contents to the jail filesystem.

> **Note**: Only include keys that correspond to scripts in the `slurm-scripts` ConfigMap. Run `kubectl get configmap slurm-scripts -n slurm1 -o jsonpath='{.data}' | python3 -c "import json,sys; [print(k) for k in sorted(json.load(sys.stdin).keys())]"` to list available keys.

```bash
kubectl apply -f - <<'EOF'
apiVersion: slurm.nebius.ai/v1alpha1
kind: JailedConfig
metadata:
  name: slurm-scripts
  namespace: slurm1
  labels:
    slurm.nebius.ai/jailed-aggregation: common
spec:
  configMap:
    name: slurm-scripts
  defaultMode: 0o755
  items:
    - key: prolog.sh
      path: /opt/slurm_scripts/prolog.sh
    - key: epilog.sh
      path: /opt/slurm_scripts/epilog.sh
    - key: hc_program.sh
      path: /opt/slurm_scripts/hc_program.sh
    - key: check_runner.py
      path: /opt/slurm_scripts/check_runner.py
    - key: checks.json
      path: /opt/slurm_scripts/checks.json
    - key: pyxis_caching_importer.sh
      path: /opt/slurm_scripts/pyxis_caching_importer.sh
    - key: boot_disk_full.sh
      path: /opt/slurm_scripts/boot_disk_full.sh
    - key: chmod_enroot_layers.sh
      path: /opt/slurm_scripts/chmod_enroot_layers.sh
    - key: cleanup_enroot.sh
      path: /opt/slurm_scripts/cleanup_enroot.sh
    - key: cleanup_scratch_data.sh
      path: /opt/slurm_scripts/cleanup_scratch_data.sh
    - key: drop_page_cache.sh
      path: /opt/slurm_scripts/drop_page_cache.sh
    - key: drop_posix_shmem.sh
      path: /opt/slurm_scripts/drop_posix_shmem.sh
EOF
```

Wait for the sconfigcontroller to write the files:

```bash
kubectl get jailedconfigs -n slurm1 slurm-scripts
# FILES WRITTEN should show "Success"
```

### 12c. Create symlink for scripts

slurmd looks for scripts at `/opt/slurm_scripts/` (container rootfs) while the jail is mounted at `/mnt/jail`. Create a symlink on each worker:

```bash
# Repeat for each worker pod
kubectl exec <worker-pod> -n slurm1 -c slurmd -- \
  bash -c "ln -sf /mnt/jail/opt/slurm_scripts /opt/slurm_scripts; \
           mkdir -p /mnt/jail/opt/soperator-outputs/slurm_scripts"
```

> **Note**: The `defaultMode: 0o755` in the JailedConfig ensures scripts are written with execute permission on every reconciliation — no manual `chmod` needed. The symlink is not persistent across pod restarts; if workers restart, re-run the symlink command.

### Post-deploy patches for NodeSet CR (if not set in values)

If the worker pod fails to create with `procMount: Unsupported value: ""`:

```bash
kubectl patch nodeset worker-gpu -n slurm1 --type merge \
  -p '{"spec":{"slurmd":{"security":{"procMount":"Default"}}}}'
```

If the worker pod fails with `failed to set MOUNT_ATTR_IDMAP ... invalid argument`:

```bash
kubectl patch nodeset worker-gpu -n slurm1 --type merge \
  -p '{"spec":{"enableHostUserNamespace":true}}'
```

> If you set both values correctly in `nodesets-values.yaml` before deploying, these patches should not be needed.

---

## Step 13 — Verify the Deployment

```bash
# Reconfigure slurmctld to pick up NodeName entries from customSlurmConfig
kubectl exec controller-0 -n slurm1 -c slurmctld -- scontrol reconfigure

# Check operator pods
kubectl get pods -n soperator-system

# Check SlurmCluster status (wait for Status: Available)
kubectl get slurmclusters -n slurm1

# Check NodeSets (wait for Status: Ready)
kubectl get nodesets -n slurm1

# Check all Slurm pods
kubectl get pods -n slurm1

# Verify Slurm sees the worker node
kubectl exec controller-0 -n slurm1 -c slurmctld -- sinfo -N -l

# Get the NodePort for SSH access
kubectl get svc -n slurm1

# SSH into the Slurm cluster (via NodePort)
ssh -p 30022 root@<any-node-ip>

# Inside the Slurm cluster (via login node)
sinfo                         # view node status — should show idle
squeue                        # view job queue
srun hostname                 # test basic job
srun --gres=gpu:1 nvidia-smi  # test GPU access
```

If the worker node shows as `drain` with "Prolog error":

```bash
# Undrain the node
kubectl exec controller-0 -n slurm1 -c slurmctld -- \
  scontrol update NodeName=ALL State=IDLE
```

---

## RDMA on OKE (Cluster Networks)

OCI bare-metal GPU shapes provisioned in cluster networks provide RoCE v2 RDMA via ConnectX adapters. For example, BM.GPU4.8 nodes have 18 ConnectX adapters (`mlx5_0`-`mlx5_17`), 16 data-path RoCE NICs (`rdma0`-`rdma15`), and `/dev/infiniband/` device files.

RDMA is required for multi-node GPU training at full bandwidth. Without it, NCCL falls back to TCP. With RDMA via SR-IOV VFs, `all_reduce_perf` through soperator/Slurm achieves **232 GB/s** bus bandwidth across 2 nodes (16x A100-40GB) — compared to ~10-20 GB/s over TCP.

Two approaches exist for exposing RDMA to soperator worker pods:

### Option A — Host Network (tested, has limitations)

Uses `hostNetwork: true` on worker pods so they share the host's network stack and can access all RDMA interfaces directly.

**What works:**
- `/dev/infiniband` device access via `customVolumeMounts` with `hostPath` (works without hostNetwork too)
- NCCL IB env vars via `customEnv`
- `privileged: true` + `SYS_ADMIN` (already set)
- The `enableHostNetwork` field was added to the NodeSet CRD and operator code

**What doesn't work (v3.0.2):**
- `hostNetwork: true` causes the pod to inherit the host's UTS namespace, changing the hostname from `worker-gpu-0` to the host hostname (e.g. `inst-zkj9m-oke-rdma`)
- This breaks soperator's naming scheme: `worker-init` can't find the pod name in `topology.conf`, slurmd registers with the wrong NodeName, and static `NodeName=` entries in `customSlurmConfig` don't match
- The operator reconciles the Kruise StatefulSet back to `hostNetwork: false` (v3.0.2 doesn't know the field)

**Hostname fix (not yet implemented):** slurmd supports `-N <nodename>` to override hostname-based detection. The soperator entrypoint script (`images/worker/supervisord_entrypoint.sh`) would need to pass `-N ${POD_NAME}` (from the downward API) when hostNetwork is enabled. Combined with the `enableHostNetwork` operator change, this is the most promising fix.

**NCCL env vars for BM.GPU4.8 (A100-40GB):**

```yaml
slurmd:
  customEnv:
    - name: "NCCL_IB_HCA"
      value: "=mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_14,mlx5_15,mlx5_16,mlx5_17,mlx5_9,mlx5_10,mlx5_11,mlx5_12"
    - name: "NCCL_IB_GID_INDEX"
      value: "3"
    - name: "NCCL_IB_TC"
      value: "41"
    - name: "NCCL_IB_SL"
      value: "0"
    - name: "NCCL_IB_TIMEOUT"
      value: "22"
    - name: "NCCL_IB_SPLIT_DATA_ON_QPS"
      value: "0"
    - name: "NCCL_IB_QPS_PER_CONNECTION"
      value: "4"
    - name: "HCOLL_ENABLE_MCAST_ALL"
      value: "0"
    - name: "UCX_TLS"
      value: "tcp"
    - name: "UCX_NET_DEVICES"
      value: "eth0"
```

**`/dev/infiniband` mount (works today, add to nodesets values):**

```yaml
      volumes:
        customVolumeMounts:
          - name: devinf
            mountPath: /dev/infiniband
            volumeSource:
              hostPath:
                path: /dev/infiniband
```

### Option B — SR-IOV Virtual Functions (recommended, tested)

Uses the NVIDIA Network Operator's SR-IOV device plugin to expose RDMA virtual functions to pods without `hostNetwork`. Pods keep their own hostname and network namespace while getting RDMA device access via Multus secondary interfaces.

**Tested**: 2x BM.GPU4.8 (A100-SXM4-40GB) with 16 VFs each.

| Test | Method | Buffers | Bus BW |
|---|---|---|---|
| MPIJob baseline (no soperator) | hostNetwork + mpirun | 1G-4G | 188.8 GB/s |
| **Soperator + Slurm** | **SR-IOV VFs + srun --mpi=pmix** | **1G-4G** | **232.2 GB/s** |
| Soperator + Slurm | SR-IOV VFs + srun --mpi=pmix | 1M-256M | 107.8 GB/s |

**Prerequisites** (provisioned by `oci-hpc-oke`):
- NVIDIA GPU Operator
- NVIDIA Network Operator (deploys SR-IOV device plugin + Multus)
- `SriovNetworkNodePolicy` for the GPU shape (e.g. `bm-gpu4-8` for BM.GPU4.8)
- `NetworkAttachmentDefinition` named `sriov-rdma-vf` in the `slurm1` namespace

**Check VF availability on GPU nodes:**

```bash
# Adjust the instance-type label to match your GPU shape
kubectl get nodes -l node.kubernetes.io/instance-type=BM.GPU4.8 \
  -o custom-columns=NAME:.metadata.name,VF:.status.capacity.nvidia\\.com/sriov-rdma-vf
# Should show 16 VFs per node
```

If the `sriov-rdma-vf` NetworkAttachmentDefinition only exists in `default`, copy it to `slurm1`:

```bash
kubectl get network-attachment-definitions sriov-rdma-vf -o yaml \
  | sed 's/namespace: default/namespace: slurm1/' | kubectl apply -f -
```

**NodeSet configuration for SR-IOV VFs:**

The nodesets values from Step 11 need these additions:

```yaml
nodesets:
  - name: worker-gpu
    # ... (same base config as Step 11)
    slurmd:
      customEnv:
        - name: "NVIDIA_DRIVER_CAPABILITIES"
          value: "compute,utility,video"
        # NCCL RDMA settings — simplified HCA list for VFs
        - name: "NCCL_IB_HCA"
          value: "mlx5"
        - name: "NCCL_IB_GID_INDEX"
          value: "3"
        - name: "NCCL_IB_TC"
          value: "41"
        - name: "NCCL_IB_SL"
          value: "0"
        - name: "NCCL_IB_TIMEOUT"
          value: "22"
        - name: "NCCL_IB_SPLIT_DATA_ON_QPS"
          value: "0"
        - name: "NCCL_IB_QPS_PER_CONNECTION"
          value: "4"
        - name: "HCOLL_ENABLE_MCAST_ALL"
          value: "0"
        - name: "UCX_TLS"
          value: "tcp"
        - name: "UCX_NET_DEVICES"
          value: "eth0"
      volumes:
        # ... (spool, jail, sharedMemorySize as in Step 11)
        customVolumeMounts:
          - name: devinf
            mountPath: /dev/infiniband
            volumeSource:
              hostPath:
                path: /dev/infiniband
    # Multus annotation to attach 16 SR-IOV VFs
    workerAnnotations:
      k8s.v1.cni.cncf.io/networks: "sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf"
```

**Post-deploy: patch VF resource request onto NodeSet CR**

The Helm chart does not support arbitrary resource types. After deploying, patch the NodeSet:

```bash
kubectl patch nodeset worker-gpu -n slurm1 --type merge \
  -p '{"spec":{"slurmd":{"resources":{"nvidia.com/sriov-rdma-vf":"16"}}}}'
```

This tells the SR-IOV device plugin to allocate 16 VFs to each worker pod. The pods will get `mlx5_18`-`mlx5_33` IB devices and `net0`-`net15` RDMA interfaces.

**Post-deploy: fix gres.conf, clean spool, set nodes IDLE**

The operator generates `AutoDetect=nvidia` in gres.conf when any NodeSet has `gpu.enabled: true`. This conflicts with the static `NodeName=` entries. Patch it with the operator scaled to 0:

```bash
# Patch gres.conf (race condition — operator may overwrite, proceed quickly)
kubectl patch configmap slurm1-slurm-configs -n slurm1 --type merge \
  -p '{"data":{"gres.conf":"#Gres config\nName=gpu Type=nvidia File=/dev/nvidia[0-7]"}}'

# Verify it stuck
kubectl get configmap slurm1-slurm-configs -n slurm1 -o jsonpath='{.data.gres\.conf}'

# Clean slurmctld node state
CTRL_NODE=$(kubectl get pod controller-0 -n slurm1 -o jsonpath='{.spec.nodeName}')
kubectl run cleanup-spool --rm -it --restart=Never -n slurm1 \
  --overrides="{\"spec\":{\"nodeName\":\"$CTRL_NODE\",\"containers\":[{\"name\":\"c\",\"image\":\"busybox\",\"command\":[\"sh\",\"-c\",\"rm -f /spool/node_state /spool/node_state.old && echo DONE\"],\"volumeMounts\":[{\"name\":\"s\",\"mountPath\":\"/spool\"}]}],\"volumes\":[{\"name\":\"s\",\"persistentVolumeClaim\":{\"claimName\":\"controller-spool-controller-0\"}}],\"tolerations\":[{\"operator\":\"Exists\"}]}}" \
  --image=busybox

# Restart controller and workers
kubectl delete pod controller-0 worker-gpu-0 worker-gpu-1 -n slurm1

# Wait for controller, then set nodes to IDLE (they start as DOWN)
kubectl wait --for=condition=Ready pod/controller-0 -n slurm1 --timeout=300s
kubectl exec controller-0 -n slurm1 -c slurmctld -- scontrol update NodeName=ALL State=IDLE
```

**Key differences from Option A (hostNetwork):**

| | Option A (hostNetwork) | Option B (SR-IOV VFs) |
|---|---|---|
| Hostname | Broken (inherits host hostname) | Preserved (pod name) |
| IB devices | All 18 host HCAs | 16 VF HCAs per pod |
| Network isolation | None (shared host stack) | Per-pod VFs |
| `NCCL_IB_HCA` | Explicit list of 16 HCAs | `mlx5` (auto-discovers VFs) |
| Operator changes | `enableHostNetwork` + hostname fix | None |
| Status | Blocked by hostname issue | **Working** |

### Running NCCL Tests through Slurm

The soperator jail image includes `all_reduce_perf` at `/usr/bin/all_reduce_perf`, but it is **not compiled with MPI**. For multi-node NCCL tests, you need an MPI-enabled build.

**Build NCCL tests with MPI in the jail** (one-time setup):

```bash
# Run on one worker — the jail is NFS-shared so the build is visible to all
kubectl exec worker-gpu-0 -n slurm1 -c slurmd -- chroot /mnt/jail bash -c "
  export PATH=/usr/local/cuda/bin:/usr/mpi/gcc/openmpi-4.1.7a1/bin:\$PATH
  cd /tmp && git clone https://github.com/NVIDIA/nccl-tests.git
  cd nccl-tests && make MPI=1 MPI_HOME=/usr/mpi/gcc/openmpi-4.1.7a1 CUDA_HOME=/usr/local/cuda NCCL_HOME=/usr -j8
  cp -r build /usr/local/nccl-tests
"
```

**Run the NCCL all_reduce test across 2 nodes:**

```bash
srun -N2 --gres=gpu:8 --ntasks-per-node=8 --mpi=pmix \
  --export=ALL,NCCL_IB_HCA=mlx5,NCCL_IB_GID_INDEX=3,NCCL_IB_TC=41,NCCL_IB_SL=0,NCCL_IB_TIMEOUT=22,NCCL_IB_SPLIT_DATA_ON_QPS=0,NCCL_IB_QPS_PER_CONNECTION=4,NCCL_DEBUG=WARN,UCX_TLS=tcp,UCX_NET_DEVICES=eth0 \
  /usr/local/nccl-tests/all_reduce_perf -b 1G -f 2 -g 1 -e 4G -c 1
```

Key flags:
- `--mpi=pmix` — enables PMIx so NCCL can bootstrap a single communicator across all 16 ranks
- `--ntasks-per-node=8` — one task per GPU
- `-g 1` — one GPU per NCCL rank
- NCCL env vars passed via `--export`

Success: `Avg bus bandwidth` > 150 GB/s with 1G-4G buffers.

### RDMA Baseline Test (without soperator)

To validate RDMA works at the infrastructure level before configuring soperator, deploy the reference NCCL test MPIJob with SR-IOV VFs directly (no Slurm). This uses the same NCCL env vars and VF configuration but runs via `mpirun` instead of `srun`.

Success: `all_reduce_perf` completes with bus bandwidth >150 GB/s across 2 nodes.

---

## Known Issues on OKE (v3.0.2)

### 1. slurmd, worker-init, and GRES AutoDetect — the NodeName chain

Three issues are linked by a single root cause:

**Root cause**: Slurm 25.11 slurmd reads local `slurm.conf` to determine its NodeName. With only `MaxNodeCount` (dynamic nodes) and no `NodeName=` line, slurmd exits with `Unable to determine this slurmd's NodeName`.

**Fix**: Add static `NodeName=...` lines to `customSlurmConfig` (Step 10).

**Consequences of the fix**:
- Static NodeName entries make nodes "configured" instead of dynamic
- The operator generates `AutoDetect=nvidia` in `gres.conf` (whenever a NodeSet has `gpu.enabled: true`)
- Slurm rejects AutoDetect on configured nodes → nodes go `inval`
- **Workaround**: Patch `gres.conf` with explicit GRES while the operator is scaled to 0 (quickstart Steps 11-12)

- After spool cleanup, static nodes start in DOWN state
- The `worker-init` container tries `scontrol update state=UNDRAIN` which fails on DOWN nodes
- **Workaround**: Set nodes to IDLE before workers start: `scontrol update NodeName=ALL State=IDLE`

### 2. Nodes stuck in CLOUD+POWERING_UP+NOT_RESPONDING

**Symptom**: Worker node registers with slurmctld but never transitions to `idle`.

**Root cause**: The operator sets `SuspendTime=0` which immediately marks idle nodes as powered down. The ResumeProgram is Nebius-specific and doesn't properly resume nodes on OKE.

**Workaround**: Override with `SuspendTime=-1` in `customSlurmConfig` to disable power management.

### 3. populate-jail fails on OCI FSS `.snapshot` directory

**Symptom**: populate-jail job shows `unlinkat /mnt/jail/.snapshot: permission denied` and exits with error.

**Root cause**: OCI FSS creates a read-only `.snapshot` directory that cannot be deleted.

**Workaround**: The jail is actually populated successfully despite the error. Delete the failed job and the operator will recreate it — on the next attempt with `overwrite: false`, it will detect the valid rootfs and succeed.

### 4. Prolog/epilog scripts missing in worker container

**Symptom**: Jobs fail with "Prolog error" and the node gets drained.

**Root cause**: Three issues combine:
1. No `JailedConfig` CR is created for the `slurm-scripts` ConfigMap (only `/etc/slurm/*.conf` files are jailed).
2. The jail's `/opt/slurm_scripts/` is owned by root but sconfigcontroller runs as UID 1001.
3. slurmd runs in the container rootfs where `/opt/slurm_scripts/` doesn't exist — the jail is at `/mnt/jail/opt/slurm_scripts/`.

**Workaround**: See [Step 12](#step-12--post-deploy-write-slurm-scripts-to-jail) — create a JailedConfig with `defaultMode: 0o755` (ensures execute permission on every reconciliation), fix directory ownership, and create a symlink from `/opt/slurm_scripts` to `/mnt/jail/opt/slurm_scripts`.

### 5. Health checks and script permissions

All built-in health checks work on OKE with SR-IOV VFs — none need to be disabled. Earlier testing showed failures caused by missing script permissions. Fixed by setting `defaultMode: 0o755` in the JailedConfig spec (see Step 12).

---

## Key Challenges on OKE

| Challenge | Mitigation |
|---|---|
| **CNI source IP preservation** | VCN-Native Pod Networking works; use NodePort for SSH service |
| **Image registry** | Images available at `cr.eu-north1.nebius.cloud/soperator/`; mirror to OCIR only if egress is restricted |
| **StorageClass names** | Replace `nebius-network-ssd` / `compute-csi-network-ssd-ext4` with `oci-bv` |
| **Node labels** | Replace `nebius.com/node-group-id` with `oke.oraclecloud.com/pool.name` |
| **Topology labels** | Set `topologyLabelPrefix: "topology.kubernetes.io"` and add `tier-1` labels to GPU nodes |
| **AppArmor** | Set `useDefaultAppArmorProfile: false` |
| **procMount (K8s >= 1.32)** | Patch NodeSet CR after deployment: `kubectl patch nodeset worker-gpu --type merge -p '{"spec":{"slurmd":{"security":{"procMount":"Default"}}}}'` |
| **NFS idmapped mounts** | Set `enableHostUserNamespace: true` on NodeSets — OCI FSS doesn't support idmapped NFS |
| **CRD chart too large** | Use `kubectl apply --server-side` instead of `helm install` for CRDs |
| **Kruise dependency** | Set `kruise.installOperator: true` — the operator requires OpenKruise CRDs |
| **Dynamic node registration** | Add static `NodeName=...` entries (no State) via `customSlurmConfig` |
| **GRES AutoDetect** | Operator forces AutoDetect when NodeSets have GPUs; must patch ConfigMap with operator scaled to 0 |
| **hostNetwork (RDMA)** | Do not enable — breaks soperator naming; use SR-IOV VFs instead (see RDMA design spec) |
| **In-cluster NFS server** | Does not work for populate-jail (xattr errors); use OCI FSS |
| **Power management** | Set `SuspendTime=-1` via `customSlurmConfig` to disable Nebius-specific power save |
| **FSS .snapshot** | Cosmetic error during populate-jail — jail is populated correctly |
| **Slurm scripts not jailed** | Create a `JailedConfig` CR manually, fix directory ownership, symlink from container rootfs |
| **GPU health checks** | All built-in checks work on OKE with SR-IOV VFs — no need to disable any |

---

## Recommended Order of Operations

1. Deploy OKE cluster with `oci-hpc-oke` (CPU + GPU node pools)
2. Install cert-manager
3. Create the `slurm1` namespace
4. Provision OCI FSS and create jail PV/PVC in `slurm1`
5. Verify cluster can pull from `cr.eu-north1.nebius.cloud` (mirror to OCIR only if needed)
6. Install Soperator CRDs (`kubectl apply --server-side`)
7. Install the Soperator operator (with `kruise.installOperator: true`)
8. Add `topology.kubernetes.io/tier-1` labels to GPU nodes
9. Deploy the Slurm cluster (with `customSlurmConfig` workarounds)
10. Deploy NodeSets (with `enableHostUserNamespace: true` and `procMount: "Default"`)
11. Create JailedConfig for slurm scripts, fix permissions, create symlink
12. Verify: `sinfo` shows worker nodes as `idle`, test with `srun --gres=gpu:1 nvidia-smi`

> **Tip**: Start with a minimal setup (1 GPU node, or even CPU-only mode with `clusterType: cpu`) to validate the CNI and storage layers before scaling up.
