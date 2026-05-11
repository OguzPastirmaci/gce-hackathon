# Deploying Slinky (Slurm on Kubernetes) on an OKE Cluster from oci-hpc-oke

## What is Slinky?

Slinky is SchedMD's Kubernetes operator for running Slurm clusters natively on Kubernetes. It unifies Kubernetes orchestration with Slurm's HPC scheduling, enabling GPU/RDMA workloads to be managed by Slurm while running as Kubernetes pods.

**Components deployed:**

- **slurm-operator** + **webhook** -- watches CRDs and reconciles Slurm resources
- **slurmctld** -- Slurm controller (scheduling engine)
- **slurmd** -- worker daemons (NodeSet pods, 1 per GPU node)
- **slurmrestd** -- REST API for operator-to-Slurm communication
- **slurmdbd** -- accounting daemon (optional)
- **login pods** -- SSH-accessible submit nodes (optional)

---

## Prerequisites

### 1. OKE Cluster via oci-hpc-oke

Deploy your OKE cluster using [oci-hpc-oke](https://github.com/oracle-quickstart/oci-hpc-oke). Ensure:

- **Kubernetes v1.29+** (Slinky minimum)
- **GPU worker pool** with your target shape (e.g., `VM.GPU.A10.1`, `BM.GPU.H100.8`, `BM.GPU.A100-v2.8`)
- **Operational worker pool** (3 nodes) for Slurm control plane components
- **cgroup v2** enabled on worker nodes (Oracle Linux 8+ / Ubuntu 22.04+ should have this)

### 2. Storage Class

OKE provides the `oci-bv` (Block Volume) storage class by default. Verify:

```sh
kubectl get storageclasses
```

You need at least one storage class for slurmctld state persistence.

### 3. CRI-O Memlock Limit (bare-metal RDMA only)

OKE's default CRI-O configuration sets `memlock` to 8MB, which is insufficient for RDMA (`ibv_reg_mr` / `ibv_create_qp` will fail with "Cannot allocate memory"). On bare-metal GPU nodes with RDMA, update CRI-O to allow unlimited memlock:

```sh
# On each bare-metal GPU node, edit /etc/crio/crio.conf.d/00-default.conf
# Change:
#   default_ulimits = ["nofile=1048576:1048576"]
# To:
#   default_ulimits = ["nofile=1048576:1048576", "memlock=-1:-1"]

# Then restart CRI-O:
sudo systemctl restart crio
```

Or apply via a DaemonSet targeting the GPU nodes:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: crio-memlock-fix
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: crio-memlock-fix
  template:
    metadata:
      labels:
        app: crio-memlock-fix
    spec:
      hostNetwork: true
      hostPID: true
      nodeSelector:
        node.kubernetes.io/instance-type: BM.GPU.B4.8   # Adjust for your shape
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
        - key: nodeset.slinky.slurm.net/worker
          operator: Exists
          effect: NoExecute
      initContainers:
        - name: fix-memlock
          image: alpine
          securityContext:
            privileged: true
          command: ["sh", "-c"]
          args:
            - |
              if nsenter -t 1 -m -- grep -q "memlock" /etc/crio/crio.conf.d/00-default.conf 2>/dev/null; then
                echo "Already configured"
                exit 0
              fi
              nsenter -t 1 -m -- sed -i \
                's|default_ulimits = \["nofile=1048576:1048576"\]|default_ulimits = ["nofile=1048576:1048576", "memlock=-1:-1"]|' \
                /etc/crio/crio.conf.d/00-default.conf
              nsenter -t 1 -m -u -i -n -p -- systemctl restart crio
              sleep 5
              echo "CRI-O restarted with memlock=unlimited"
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
```

After applying, delete and recreate the slurmd worker pods so they get the new memlock limit. Verify with:

```sh
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  srun --gres=gpu:1 -N 1 -n 1 --export=ALL bash -c "ulimit -l"
# Should print "unlimited"
```

### 4. NVIDIA GPU Operator

If not already installed by oci-hpc-oke, install the NVIDIA GPU Operator so GPUs are exposed as `nvidia.com/gpu` resources:

```sh
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator --create-namespace \
  --set driver.enabled=true
```

Verify GPUs are visible:

```sh
kubectl get nodes -o json | jq '.items[].status.allocatable["nvidia.com/gpu"]'
```

---

## Step-by-Step Deployment

### Step 1: Install cert-manager

Required for the operator's webhook TLS certificates:

```sh
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
```

### Step 2: Install Slurm Operator CRDs and Operator

```sh
# Install CRDs
helm install slurm-operator-crds oci://ghcr.io/slinkyproject/charts/slurm-operator-crds

# Install operator
helm install slurm-operator oci://ghcr.io/slinkyproject/charts/slurm-operator \
  --namespace=slinky --create-namespace
```

Verify:

```sh
kubectl -n slinky get pods -l app.kubernetes.io/instance=slurm-operator
```

Expected output:

```
slurm-operator-xxxxx           1/1     Running   0
slurm-operator-webhook-xxxxx   1/1     Running   0
```

Wait for the webhook to be ready before proceeding (the Slurm cluster install will fail if the webhook isn't available):

```sh
kubectl -n slinky rollout status deployment/slurm-operator-webhook --timeout=60s
```

### Step 3: Install the Slurm Cluster

Create a values file tailored for your OKE HPC cluster. Choose the example that matches your node shape.

#### Example A: VM GPU Nodes (no RDMA)

For clusters with VM GPU shapes like `VM.GPU.A10.1` where RDMA is not needed.

**`slinky-values.yaml`:**

```yaml
# ──────────────────────────────────────────────
# Controller (slurmctld)
# ──────────────────────────────────────────────
controller:
  persistence:
    enabled: true
    storageClassName: oci-bv
    resources:
      requests:
        storage: 10Gi
  extraConfMap:
    GresTypes: "gpu"
  podSpec:
    nodeSelector:
      kubernetes.io/os: linux
    tolerations: []

# ──────────────────────────────────────────────
# Slurm config files
# ──────────────────────────────────────────────
configFiles:
  gres.conf: |
    AutoDetect=nvidia
  cgroup.conf: |
    CgroupPlugin=cgroup/v2
    IgnoreSystemd=yes
    ConstrainCores=yes
    ConstrainRAMSpace=yes
    ConstrainDevices=yes
    ConstrainSwapSpace=yes

# ──────────────────────────────────────────────
# REST API (required by operator)
# ──────────────────────────────────────────────
restapi:
  replicas: 1

# ──────────────────────────────────────────────
# GPU NodeSets (compute workers)
# ──────────────────────────────────────────────
nodesets:
  slinky:
    enabled: false

  gpu-a10:
    enabled: true
    replicas: 1                     # Set to number of GPU nodes in the pool
    slurmd:
      image:
        repository: ghcr.io/slinkyproject/slurmd
        tag: 25.11-ubuntu24.04
      resources:
        limits:
          nvidia.com/gpu: 1
        requests:
          nvidia.com/gpu: 1
    logfile:
      image:
        repository: docker.io/library/alpine
        tag: latest
    extraConfMap:
      Gres: ["gpu:a10:1"]
      Features: ["a10", "24gb"]
      Weight: 1
    partition:
      enabled: true
      configMap:
        State: UP
        Default: "YES"
        MaxTime: UNLIMITED
    updateStrategy:
      type: RollingUpdate
      rollingUpdate:
        maxUnavailable: 25%
    podSpec:
      nodeSelector:
        node.kubernetes.io/instance-type: VM.GPU.A10.1
      tolerations:
        - key: nvidia.com/gpu
          effect: NoSchedule
          operator: Exists

# ──────────────────────────────────────────────
# Partitions
# ──────────────────────────────────────────────
partitions:
  all:
    enabled: true
    nodesets: [ALL]
    configMap:
      State: UP
      MaxTime: UNLIMITED

# ──────────────────────────────────────────────
# Login nodes (for SSH access)
# ──────────────────────────────────────────────
loginsets:
  slinky:
    enabled: true
    replicas: 1
    rootSshAuthorizedKeys: "ssh-rsa AAAAB3Nz... your-key-here"  # Replace with your public key
    service:
      spec:
        type: LoadBalancer

# ──────────────────────────────────────────────
# Accounting (optional)
# ──────────────────────────────────────────────
accounting:
  enabled: false

vendor:
  nvidia:
    dcgm:
      enabled: false
```

#### Example B: Bare-Metal GPU Nodes with RDMA (hostNetwork)

For clusters with bare-metal GPU shapes like `BM.GPU.B4.8`, `BM.GPU.H100.8`, or `BM.GPU.A100-v2.8` that have RDMA cluster networking. This example uses `BM.GPU.B4.8` (8x A100-SXM4-40GB).

Key differences from the VM example:
- **hostNetwork** for direct RDMA/InfiniBand access
- **Manual GRES config** instead of `AutoDetect=nvidia` (avoids core affinity mismatch on bare-metal)
- **`/dev/infiniband`** hostPath mount for IB verbs
- **`/dev/shm`** large emptyDir for NCCL shared memory
- **`ReturnToService=2`** to handle CPU count mismatches from cgroup detection
- **`useResourceLimits: false`** since the whole node is dedicated to one slurmd pod

**`slinky-values.yaml`:**

```yaml
# ──────────────────────────────────────────────
# Controller (slurmctld)
# ──────────────────────────────────────────────
controller:
  persistence:
    enabled: true
    storageClassName: oci-bv
    resources:
      requests:
        storage: 10Gi
  extraConfMap:
    GresTypes: "gpu"
    ReturnToService: 2              # Accept nodes despite cgroup CPU count mismatch
  podSpec:
    nodeSelector:
      kubernetes.io/os: linux
    tolerations: []

# ──────────────────────────────────────────────
# Slurm config files
# ──────────────────────────────────────────────
configFiles:
  # Use manual GRES config -- AutoDetect=nvidia fails on bare-metal shapes
  # because GPU core affinity doesn't match socket boundaries.
  gres.conf: |
    Name=gpu Type=a100 File=/dev/nvidia[0-7]
  cgroup.conf: |
    CgroupPlugin=cgroup/v2
    IgnoreSystemd=yes
    ConstrainCores=yes
    ConstrainRAMSpace=no                         # Required for RDMA memory registration
    ConstrainDevices=yes
    ConstrainSwapSpace=no

# ──────────────────────────────────────────────
# REST API (required by operator)
# ──────────────────────────────────────────────
restapi:
  replicas: 1

# ──────────────────────────────────────────────
# GPU NodeSets (compute workers)
# ──────────────────────────────────────────────
nodesets:
  slinky:
    enabled: false

  gpu-b4:
    enabled: true
    replicas: 2                     # Set to number of BM GPU nodes in the pool
    useResourceLimits: false        # Whole node is dedicated -- don't derive from limits
    slurmd:
      image:
        repository: iad.ocir.io/idxzjcdglx2s/slinky
        tag: slurmd-rdma-25.11-ubuntu24.04   # Custom image -- see "Building Custom Slurm Images" or "Pre-Built Images"
      resources:
        limits:
          nvidia.com/gpu: 8         # BM.GPU.B4.8 has 8 GPUs
        requests:
          nvidia.com/gpu: 8
      volumeMounts:
        - name: devinf
          mountPath: /dev/infiniband
        - name: shm
          mountPath: /dev/shm
    logfile:
      image:
        repository: docker.io/library/alpine
        tag: latest
    # hostNetwork only: move the container sshd away from the node's port 22.
    # Do not add this to SR-IOV/VF pod-networked workers.
    ssh:
      enabled: true
      extraSshdConfig: |
        Port 2222
    extraConfMap:
      Gres: ["gpu:a100:8"]         # Must match gres.conf and actual GPU count
      Features: ["a100", "40gb", "rdma"]
      Weight: 1
    partition:
      enabled: true
      configMap:
        State: UP
        Default: "YES"
        MaxTime: UNLIMITED
    updateStrategy:
      type: RollingUpdate
      rollingUpdate:
        maxUnavailable: 25%
    podSpec:
      hostNetwork: true             # Direct access to host RDMA interfaces
      dnsPolicy: ClusterFirstWithHostNet  # Keep K8s DNS working with hostNetwork
      nodeSelector:
        node.kubernetes.io/instance-type: BM.GPU.B4.8
      tolerations:
        - key: nvidia.com/gpu
          effect: NoSchedule
          operator: Exists
      volumes:
        - name: devinf
          hostPath:
            path: /dev/infiniband   # IB verbs devices for RDMA
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 32Gi         # Large shared memory for NCCL

# ──────────────────────────────────────────────
# Partitions
# ──────────────────────────────────────────────
partitions:
  all:
    enabled: true
    nodesets: [ALL]
    configMap:
      State: UP
      MaxTime: UNLIMITED

# ──────────────────────────────────────────────
# Login nodes (for SSH access)
# ──────────────────────────────────────────────
loginsets:
  slinky:
    enabled: true
    replicas: 1
    rootSshAuthorizedKeys: "ssh-rsa AAAAB3Nz... your-key-here"  # Replace with your public key
    service:
      spec:
        type: LoadBalancer

# ──────────────────────────────────────────────
# Accounting (optional)
# ──────────────────────────────────────────────
accounting:
  enabled: false

vendor:
  nvidia:
    dcgm:
      enabled: false
```

> **Note:** This example uses the `slurmd-rdma` custom image which includes CUDA, NCCL, nccl-tests, perftest, and RDMA tools. For `srun --mpi=pmix` support, use `slurmd-rdma-pmix` instead (see [PMIx-Enabled Images](#option-a2-pmix-enabled-images)).

To adapt for other bare-metal shapes, change these fields:

| Shape | `nodeSelector` | `nvidia.com/gpu` | `Gres` | `gres.conf` |
|---|---|---|---|---|
| `BM.GPU.B4.8` | `BM.GPU.B4.8` | 8 | `gpu:a100:8` | `Name=gpu Type=a100 File=/dev/nvidia[0-7]` |
| `BM.GPU.H100.8` | `BM.GPU.H100.8` | 8 | `gpu:h100:8` | `Name=gpu Type=h100 File=/dev/nvidia[0-7]` |
| `BM.GPU.A100-v2.8` | `BM.GPU.A100-v2.8` | 8 | `gpu:a100:8` | `Name=gpu Type=a100 File=/dev/nvidia[0-7]` |

#### Install

```sh
helm install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  -f slinky-values.yaml \
  --namespace=slurm --create-namespace
```

### Step 4: Verify Deployment

```sh
# Check all pods
kubectl -n slurm get pods
```

Expected output (VM example):

```
slurm-controller-0                    3/3     Running
slurm-restapi-xxxxx                   1/1     Running
slurm-login-slinky-xxxxx              1/1     Running
slurm-worker-gpu-a10-0                2/2     Running
```

Expected output (bare-metal RDMA example):

```
slurm-controller-0                    3/3     Running
slurm-restapi-xxxxx                   1/1     Running
slurm-login-slinky-xxxxx              1/1     Running
slurm-worker-gpu-b4-0                 2/2     Running
slurm-worker-gpu-b4-1                 2/2     Running
```

Check Slurm from inside the controller:

```sh
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- sinfo
# Should show your partitions and nodes in "idle" state

kubectl -n slurm exec slurm-controller-0 -c slurmctld -- sinfo -o "%N %G %f"
# Should show GPU GRES and features
```

### Step 5: Test a GPU Job

```sh
# Single GPU
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- srun --gres=gpu:1 nvidia-smi

# All 8 GPUs on a bare-metal node
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- srun --gres=gpu:8 nvidia-smi -L
```

For RDMA nodes, verify InfiniBand devices are accessible from within a job:

```sh
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  srun --gres=gpu:8 bash -c "ls /dev/infiniband/ && cat /proc/net/dev | grep rdma | wc -l"
```

---

## RDMA / InfiniBand for Bare-Metal GPU Nodes

OCI bare-metal GPU shapes (e.g., `BM.GPU.B4.8`, `BM.GPU.H100.8`) have RDMA NICs via cluster networking. There are two approaches for exposing RDMA to Slinky slurmd pods:

| Approach | Pros | Cons | Tested BW |
|---|---|---|---|
| **hostNetwork** | No operator needed, full access to all host RDMA interfaces | Pods share host network, port conflicts, needs DNS/OpenMPI workarounds, CPU mismatch | ~189 GB/s |
| **SR-IOV VFs** (recommended) | Network isolation, standard K8s DNS, no workarounds, cleaner config | Requires NVIDIA Network Operator + SR-IOV VF pre-creation | ~188 GB/s |

### Option 1: Using hostNetwork

#### Why hostNetwork

- Gives slurmd pods direct access to all host RDMA interfaces (e.g., 16x rdma0-rdma15) and `/dev/infiniband` devices
- No need for NVIDIA Network Operator or SR-IOV VF management
- Simpler than network attachment definitions
- One slurmd pod per node means no slurmd port conflicts (slurmd uses port 6818)

> **Note:** The slurmd container runs supervisord which starts an internal sshd. With hostNetwork, configure the container sshd on a non-host port, for example `nodesets.<name>.ssh.extraSshdConfig: "Port 2222"`, because the node's own sshd already owns port 22. This setting is hostNetwork-only; do not add it to SR-IOV/VF pod-networked workers. When using `mpirun`, `-mca plm_rsh_args "-p 22"` connects to the **host's** sshd, while `-mca plm_rsh_args "-p 2222"` targets the slurmd container sshd.

#### Required Pod Configuration

The nodeset `podSpec` must include:

```yaml
podSpec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet  # Required -- without this, K8s DNS breaks
```

For hostNetwork workers that need container SSH, add:

```yaml
ssh:
  enabled: true
  extraSshdConfig: |
    Port 2222
```

Do not apply this to SR-IOV/VF workers; they do not share the host network
namespace and should keep the default pod-network SSH behavior.

And the slurmd container needs volume mounts for IB devices and shared memory:

```yaml
slurmd:
  volumeMounts:
    - name: devinf
      mountPath: /dev/infiniband
    - name: shm
      mountPath: /dev/shm
# ...
podSpec:
  volumes:
    - name: devinf
      hostPath:
        path: /dev/infiniband       # IB uverbs and umad devices
    - name: shm
      emptyDir:
        medium: Memory
        sizeLimit: 32Gi             # NCCL needs large shared memory
```

#### Why Manual GRES (not AutoDetect)

On bare-metal shapes, `AutoDetect=nvidia` in `gres.conf` will fail with:

```
gres/gpu GRES autodetected core affinity 16-31 on node doesn't match socket boundaries.
Consider setting Parameters=l3cache_as_socket as part of the Node configuration.
```

This happens because GPU core affinity doesn't align with socket boundaries on these shapes. The fix is to use manual GRES configuration instead:

```yaml
configFiles:
  gres.conf: |
    Name=gpu Type=a100 File=/dev/nvidia[0-7]
```

This avoids the autodetection issue entirely. NCCL handles GPU/NIC topology at runtime, so Slurm-level core affinity isn't needed for RDMA workloads.

#### CPU Count Mismatch

With hostNetwork, slurmd sees all host CPUs in the cgroup (e.g., 255 on a 128-core node with HT). This causes a "Node configuration differs from hardware" error. Setting `ReturnToService=2` in the controller config accepts nodes despite this mismatch:

```yaml
controller:
  extraConfMap:
    ReturnToService: 2
```

#### Running Multi-Node NCCL Jobs

The NCCL test commands below assume nccl-tests binaries are available at `/opt/nccl-tests/bin/` via a [custom slurmd image](#building-custom-slurm-images-optional). For quick testing without building images, see [staging-nccl-test-binaries.md](staging-nccl-test-binaries.md).

Multi-node NCCL jobs over RDMA require careful configuration. Key points:

1. **`NCCL_SOCKET_IFNAME=eth0`** -- Forces NCCL bootstrap over the host network interface, not the K8s pod IP
2. **`ulimit -l unlimited`** -- Required for RDMA memory registration (must be set in the job script; Slurm sets a soft limit of 8MB by default, but with the CRI-O memlock fix the hard limit is unlimited)
3. **OpenMPI network config** -- Restrict BTL and OOB to `eth0` to avoid connecting via unreachable pod IPs
4. **`--bind-to none`** -- Prevents hwloc binding errors from the cgroup CPU count mismatch

> **Debugging note:** If you see OpenMPI verbs BTL errors in mpirun or srun output, these are a **red herring**. The root cause of multi-node MPI hangs is OpenMPI's TCP OOB/BTL layers picking up K8s pod IPs from the many hostNetwork interfaces -- not an IB verbs issue. Building OpenMPI `--without-verbs` removes the noise but the actual fix is restricting interfaces to eth0 via `-mca btl_tcp_if_include eth0 -mca oob_tcp_if_include eth0` (or `OMPI_MCA_*` env vars).

##### Single-Node Test (8 GPUs, NVLink)

```sh
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  srun --gres=gpu:8 -N 1 -n 1 \
  --export=ALL,NCCL_DEBUG=WARN \
  bash -c "mpirun --allow-run-as-root -np 1 \
    /opt/nccl-tests/bin/all_reduce_perf -b 512M -f 2 -g 8 -e 4G -c 1"
```

##### Multi-Node Test (16 GPUs, RDMA) -- sbatch + mpirun

This approach works with the stock `slurmd-rdma` image (no PMIx needed).

**1. Create the job script on the controller:**

```sh
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- bash -c 'cat > /tmp/nccl-mpirun.sh << "EOF"
#!/bin/bash
#SBATCH --gres=gpu:8
#SBATCH -N 2
#SBATCH --ntasks-per-node=8

ulimit -l unlimited

export NCCL_DEBUG=WARN
export NCCL_SOCKET_IFNAME=eth0
export NCCL_IB_SPLIT_DATA_ON_QPS=0
export NCCL_IB_QPS_PER_CONNECTION=4
export NCCL_IB_GID_INDEX=3
export NCCL_IB_HCA="=mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_14,mlx5_15,mlx5_16,mlx5_17,mlx5_9,mlx5_10,mlx5_11,mlx5_12"
export NCCL_IB_TC=41
export NCCL_IB_SL=0
export NCCL_IB_TIMEOUT=22
export UCX_TLS=tcp
export UCX_NET_DEVICES=eth0

scontrol show hostnames $SLURM_JOB_NODELIST > /tmp/hostfile
NUM_HOSTS=$(wc -l < /tmp/hostfile)
NP=$((NUM_HOSTS * 8))

mpirun --allow-run-as-root \
  -np $NP -npernode 8 --bind-to none \
  --hostfile /tmp/hostfile \
  -mca plm_rsh_args "-p 22" \
  -mca btl self,vader,tcp \
  -mca btl_tcp_if_include eth0 \
  -mca oob_tcp_if_include eth0 \
  -mca coll ^hcoll \
  -mca coll_hcoll_enable 0 \
  -x LD_LIBRARY_PATH -x NCCL_DEBUG -x NCCL_SOCKET_IFNAME \
  -x NCCL_IB_SPLIT_DATA_ON_QPS -x NCCL_IB_QPS_PER_CONNECTION \
  -x NCCL_IB_GID_INDEX -x NCCL_IB_HCA -x NCCL_IB_TC \
  -x NCCL_IB_SL -x NCCL_IB_TIMEOUT \
  -x UCX_TLS -x UCX_NET_DEVICES \
  /opt/nccl-tests/bin/all_reduce_perf -b 1G -f 2 -g 1 -e 4G -c 1
EOF
chmod +x /tmp/nccl-mpirun.sh'
```

**2. Submit and wait for results:**

```sh
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  sbatch --output=/tmp/nccl-mpirun-out.txt --wait /tmp/nccl-mpirun.sh
```

**3. Read the output** (the output file is on the batch host node):

```sh
# Try each worker until the output file is found
kubectl -n slurm exec slurm-worker-gpu-b4-0 -c slurmd -- cat /tmp/nccl-mpirun-out.txt 2>/dev/null || \
kubectl -n slurm exec slurm-worker-gpu-b4-1 -c slurmd -- cat /tmp/nccl-mpirun-out.txt
```

Or submit from the **login node** for a more natural workflow:

```sh
# SSH into the login node
SLURM_LOGIN_IP=$(kubectl get svc -n slurm slurm-login-slinky -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
ssh root@${SLURM_LOGIN_IP}

# Inside the login pod:
sbatch /tmp/nccl-mpirun.sh       # Submit
squeue                            # Check status
cat /tmp/nccl-mpirun-out.txt      # Read output (after job completes)
```

##### Multi-Node Test (16 GPUs, RDMA) -- srun --mpi=pmix

This approach requires the `slurmd-rdma-pmix` + `slurmctld-pmix` images. No mpirun or hostfile needed.

**1. Create the job script on the controller:**

```sh
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- bash -c 'cat > /tmp/nccl-pmix.sh << "EOF"
#!/bin/bash
#SBATCH --gres=gpu:8
#SBATCH -N 2
#SBATCH --ntasks-per-node=8

export LD_LIBRARY_PATH=/usr/local/openmpi/lib:/usr/lib/x86_64-linux-gnu:/usr/local/cuda/lib64
export NCCL_DEBUG=WARN
export NCCL_SOCKET_IFNAME=eth0
export NCCL_IB_SPLIT_DATA_ON_QPS=0
export NCCL_IB_QPS_PER_CONNECTION=4
export NCCL_IB_GID_INDEX=3
export NCCL_IB_HCA="=mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_14,mlx5_15,mlx5_16,mlx5_17,mlx5_9,mlx5_10,mlx5_11,mlx5_12"
export NCCL_IB_TC=41
export NCCL_IB_SL=0
export NCCL_IB_TIMEOUT=22
# Required for hostNetwork -- srun tasks don't inherit Docker ENV vars
export OMPI_MCA_oob_tcp_if_include=eth0
export OMPI_MCA_btl_tcp_if_include=eth0

srun --mpi=pmix /opt/nccl-tests/bin/all_reduce_perf -b 1G -f 2 -g 1 -e 4G -c 1
EOF
chmod +x /tmp/nccl-pmix.sh'
```

**2. Submit and wait for results:**

```sh
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  sbatch --output=/tmp/nccl-pmix-out.txt --wait /tmp/nccl-pmix.sh
```

**3. Read the output:**

```sh
kubectl -n slurm exec slurm-worker-gpu-b4-0 -c slurmd -- cat /tmp/nccl-pmix-out.txt 2>/dev/null || \
kubectl -n slurm exec slurm-worker-gpu-b4-1 -c slurmd -- cat /tmp/nccl-pmix-out.txt
```

> **Note on stock images:** `srun --mpi=pmix` does not work with the stock Slinky images because:
> 1. The **slurmd** image's OpenMPI (`openmpi-bin`) lacks PMIx support
> 2. The **slurmctld** image lacks `libpmix.so` for the `mpi/pmix_v5` plugin
>
> See [Building Custom Slurm Images](#building-custom-slurm-images-optional) for how to build the PMIx images. With stock images, use `sbatch` + `mpirun` as shown above.

##### Expected Results (BM.GPU.B4.8, 2 nodes)

| Test | Approach | Nodes | GPUs | Avg Bus BW |
|---|---|---|---|---|
| Single-node (NVLink) | `srun --mpi=pmix` | 1 | 8 | ~228 GB/s |
| Multi-node (RDMA) | `sbatch` + `mpirun` | 2 | 16 | ~185 GB/s |
| Multi-node (RDMA) | `srun --mpi=pmix` | 2 | 16 | ~189 GB/s |

### Option 2: Using SR-IOV RDMA Virtual Functions

This approach uses the NVIDIA Network Operator with SR-IOV to expose RDMA VFs directly to slurmd pods via Kubernetes network attachment definitions. Pods retain their own network namespace with isolated RDMA interfaces — no hostNetwork needed.

#### Prerequisites

- NVIDIA Network Operator with `sriovNetworkOperator.enabled=true`
- SR-IOV VFs pre-created on each bare-metal GPU node (OCI images typically handle this via cloud-init)
- `SriovNetwork` and `SriovNetworkNodePolicy` CRDs configured for the RDMA NICs
- `NetworkAttachmentDefinition` named `sriov-rdma-vf` in the `slurm` namespace (copy from `default` if needed)
- Each GPU node exposes `nvidia.com/sriov-rdma-vf` as an allocatable resource (16 VFs per BM.GPU.B4.8)
- CRI-O memlock fix applied (same as hostNetwork — see [CRI-O Memlock Limit](#3-cri-o-memlock-limit-bare-metal-rdma-only))

#### Advantages over hostNetwork

- No `dnsPolicy: ClusterFirstWithHostNet` needed (standard K8s DNS works)
- No OpenMPI interface restrictions (`OMPI_MCA_*` env vars not needed)
- No port 22 sshd conflict
- No CPU count mismatch (pods see their own cgroup, not the host's 255 CPUs)
- No `ReturnToService=2` needed (nodes register cleanly)
- `NCCL_IB_HCA=mlx5` works (simpler than listing specific HCAs)
- Better network isolation between pods
- `srun --mpi=pmix` works without `OMPI_MCA` workarounds

#### Values File (SR-IOV)

Key differences from the hostNetwork values:
- **No** `hostNetwork`, `dnsPolicy`, or `ReturnToService`
- `nvidia.com/sriov-rdma-vf: 16` as a resource request
- Pod annotation `k8s.v1.cni.cncf.io/networks` with 16x `sriov-rdma-vf`
- `NCCL_IB_HCA=mlx5` (all VF HCAs match this pattern)

```yaml
controller:
  persistence:
    enabled: true
    storageClassName: oci-bv
    resources:
      requests:
        storage: 10Gi
  extraConfMap:
    GresTypes: "gpu"
    PropagateResourceLimitsExcept: MEMLOCK        # Required for srun RDMA jobs
    # No ReturnToService needed -- SR-IOV pods see correct CPU counts
  podSpec:
    nodeSelector:
      kubernetes.io/os: linux
    tolerations: []

configFiles:
  gres.conf: |
    Name=gpu Type=a100 File=/dev/nvidia[0-7]
  cgroup.conf: |
    CgroupPlugin=cgroup/v2
    IgnoreSystemd=yes
    ConstrainCores=yes
    ConstrainRAMSpace=no                         # Required for RDMA memory registration
    ConstrainDevices=yes
    ConstrainSwapSpace=no

restapi:
  replicas: 1

nodesets:
  slinky:
    enabled: false

  gpu-b4:
    enabled: true
    replicas: 2
    useResourceLimits: false
    slurmd:
      image:
        repository: iad.ocir.io/idxzjcdglx2s/slinky
        tag: slurmd-rdma-25.11-ubuntu24.04      # Or slurmd-rdma-pmix for srun --mpi=pmix (add PropagateResourceLimitsExcept: MEMLOCK to extraConfMap)
      resources:
        limits:
          nvidia.com/gpu: 8
          nvidia.com/sriov-rdma-vf: 16           # 16 SR-IOV RDMA VFs per node
        requests:
          nvidia.com/gpu: 8
          nvidia.com/sriov-rdma-vf: 16
      volumeMounts:
        - name: devinf
          mountPath: /dev/infiniband
        - name: shm
          mountPath: /dev/shm
    logfile:
      image:
        repository: docker.io/library/alpine
        tag: latest
    extraConfMap:
      Gres: ["gpu:a100:8"]
      Features: ["a100", "40gb", "rdma", "sriov"]
      Weight: 1
    partition:
      enabled: true
      configMap:
        State: UP
        Default: "YES"
        MaxTime: UNLIMITED
    updateStrategy:
      type: RollingUpdate
      rollingUpdate:
        maxUnavailable: 25%
    metadata:
      annotations:
        # Attach 16 SR-IOV RDMA VFs to each slurmd pod
        k8s.v1.cni.cncf.io/networks: sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf,sriov-rdma-vf
    podSpec:
      nodeSelector:
        node.kubernetes.io/instance-type: BM.GPU.B4.8
      tolerations:
        - key: nvidia.com/gpu
          effect: NoSchedule
          operator: Exists
      volumes:
        - name: devinf
          hostPath:
            path: /dev/infiniband
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 32Gi

partitions:
  all:
    enabled: true
    nodesets: [ALL]
    configMap:
      State: UP
      MaxTime: UNLIMITED

loginsets:
  slinky:
    enabled: true
    replicas: 1
    rootSshAuthorizedKeys: "ssh-rsa AAAAB3Nz... your-key-here"  # Replace with your public key
    service:
      spec:
        type: LoadBalancer

accounting:
  enabled: false

vendor:
  nvidia:
    dcgm:
      enabled: false
```

> **Note:** The `sriov-rdma-vf` NetworkAttachmentDefinition must exist in the `slurm` namespace. If it was created in `default` by the Network Operator, copy it:
> ```sh
> kubectl get net-attach-def sriov-rdma-vf -o json | \
>   jq '.metadata = {name: .metadata.name, namespace: "slurm", annotations: .metadata.annotations}' | \
>   kubectl apply -f -
> ```

#### Running NCCL Jobs (SR-IOV)

SR-IOV simplifies the NCCL job scripts compared to hostNetwork — `NCCL_IB_HCA=mlx5` works for all VFs, and the `srun --mpi=pmix` path needs no `NCCL_SOCKET_IFNAME` or `OMPI_MCA` workarounds. The `sbatch` + `mpirun` path still uses `-mca btl_tcp_if_include eth0` as a safety measure (mpirun enumerates all interfaces and may pick SR-IOV VF IPs for its control plane).

**Multi-Node via `sbatch` + `mpirun` (stock `slurmd-rdma` image):**

```sh
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- bash -c 'cat > /tmp/nccl-sriov.sh << "EOF"
#!/bin/bash
#SBATCH --gres=gpu:8
#SBATCH -N 2
#SBATCH --ntasks-per-node=8

ulimit -l unlimited

export NCCL_DEBUG=WARN
export NCCL_IB_SPLIT_DATA_ON_QPS=0
export NCCL_IB_QPS_PER_CONNECTION=4
export NCCL_IB_GID_INDEX=3
export NCCL_IB_HCA=mlx5
export NCCL_IB_TC=41
export NCCL_IB_SL=0
export NCCL_IB_TIMEOUT=22
export UCX_TLS=tcp
export UCX_NET_DEVICES=eth0

scontrol show hostnames $SLURM_JOB_NODELIST > /tmp/hostfile
NUM_HOSTS=$(wc -l < /tmp/hostfile)
NP=$((NUM_HOSTS * 8))

mpirun --allow-run-as-root \
  -np $NP -npernode 8 --bind-to none \
  --hostfile /tmp/hostfile \
  -mca plm_rsh_args "-p 22" \
  -mca btl self,vader,tcp \
  -mca btl_tcp_if_include eth0 \
  -mca oob_tcp_if_include eth0 \
  -mca coll ^hcoll \
  -mca coll_hcoll_enable 0 \
  -x NCCL_DEBUG \
  -x NCCL_IB_SPLIT_DATA_ON_QPS -x NCCL_IB_QPS_PER_CONNECTION \
  -x NCCL_IB_GID_INDEX -x NCCL_IB_HCA -x NCCL_IB_TC \
  -x NCCL_IB_SL -x NCCL_IB_TIMEOUT \
  -x UCX_TLS -x UCX_NET_DEVICES \
  /opt/nccl-tests/bin/all_reduce_perf -b 1G -f 2 -g 1 -e 4G -c 1
EOF
chmod +x /tmp/nccl-sriov.sh'
```

```sh
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  sbatch --output=/tmp/nccl-sriov-out.txt --wait /tmp/nccl-sriov.sh

# Read output (file is on the batch host node):
kubectl -n slurm exec slurm-worker-gpu-b4-0 -c slurmd -- cat /tmp/nccl-sriov-out.txt 2>/dev/null || \
kubectl -n slurm exec slurm-worker-gpu-b4-1 -c slurmd -- cat /tmp/nccl-sriov-out.txt
```

**Multi-Node via `srun --mpi=pmix` (requires `slurmd-rdma-pmix` + `slurmctld-pmix`):**

```sh
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- bash -c 'cat > /tmp/nccl-sriov-pmix.sh << "EOF"
#!/bin/bash
#SBATCH --gres=gpu:8
#SBATCH -N 2
#SBATCH --ntasks-per-node=8

export LD_LIBRARY_PATH=/usr/local/openmpi/lib:/usr/lib/x86_64-linux-gnu:/usr/local/cuda/lib64
export NCCL_DEBUG=WARN
export NCCL_IB_SPLIT_DATA_ON_QPS=0
export NCCL_IB_QPS_PER_CONNECTION=4
export NCCL_IB_GID_INDEX=3
export NCCL_IB_HCA=mlx5
export NCCL_IB_TC=41
export NCCL_IB_SL=0
export NCCL_IB_TIMEOUT=22

srun --mpi=pmix /opt/nccl-tests/bin/all_reduce_perf -b 1G -f 2 -g 1 -e 4G -c 1
EOF
chmod +x /tmp/nccl-sriov-pmix.sh'
```

```sh
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  sbatch --output=/tmp/nccl-sriov-pmix-out.txt --wait /tmp/nccl-sriov-pmix.sh

# Read output:
kubectl -n slurm exec slurm-worker-gpu-b4-0 -c slurmd -- cat /tmp/nccl-sriov-pmix-out.txt 2>/dev/null || \
kubectl -n slurm exec slurm-worker-gpu-b4-1 -c slurmd -- cat /tmp/nccl-sriov-pmix-out.txt
```

Note how much simpler the PMIx script is with SR-IOV — no `ulimit`, no `NCCL_SOCKET_IFNAME`, no `OMPI_MCA` settings, no `mpirun` hostfile management.

#### Expected Results (BM.GPU.B4.8, 2 nodes)

| Test | Approach | Nodes | GPUs | Avg Bus BW |
|---|---|---|---|---|
| Multi-node (SR-IOV) | `sbatch` + `mpirun` | 2 | 16 | ~179 GB/s |
| Multi-node (SR-IOV) | `srun --mpi=pmix` | 2 | 16 | ~188 GB/s |
| Multi-node (hostNetwork) | `sbatch` + `mpirun` | 2 | 16 | ~185 GB/s |
| Multi-node (hostNetwork) | `srun --mpi=pmix` | 2 | 16 | ~189 GB/s |

SR-IOV performance is within ~3% of hostNetwork, with significantly simpler configuration.

---

## Topology-Aware Scheduling (Optional)

For multi-node NCCL jobs, topology-aware scheduling improves performance. Annotate your K8s nodes:

```sh
# Example: nodes in the same RDMA leaf switch
kubectl annotate node <node-1> topology.slinky.slurm.net/spec="topo-switch:leaf1"
kubectl annotate node <node-2> topology.slinky.slurm.net/spec="topo-switch:leaf1"
kubectl annotate node <node-3> topology.slinky.slurm.net/spec="topo-switch:leaf2"
```

And add a `topology.yaml` to your configFiles:

```yaml
configFiles:
  topology.yaml: |
    - topology: topo-switch
      cluster_default: true
      tree:
        switches:
          - switch: spine
            children: leaf[1-2]
          - switch: leaf1
            nodes: slurm-worker-gpu-h100-[0-1]
          - switch: leaf2
            nodes: slurm-worker-gpu-h100-[2-3]
```

---

## Enabling Accounting (Optional)

If you want job history and fair-share scheduling, deploy MariaDB and enable accounting.

### Install MariaDB Operator

```sh
helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator
helm repo update
helm install mariadb-operator-crds mariadb-operator/mariadb-operator-crds
helm install mariadb-operator mariadb-operator/mariadb-operator \
  --namespace mariadb --create-namespace
```

### Create the MariaDB Database

```sh
kubectl create namespace slurm

kubectl apply -f - <<EOF
apiVersion: k8s.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: mariadb
  namespace: slurm
spec:
  rootPasswordSecretKeyRef:
    name: mariadb-root
    key: password
    generate: true
  username: slurm
  database: slurm_acct_db
  passwordSecretKeyRef:
    name: mariadb-password
    key: password
    generate: true
  storage:
    size: 16Gi
  myCnf: |
    [mariadb]
    bind-address=*
    default_storage_engine=InnoDB
    binlog_format=row
    innodb_autoinc_lock_mode=2
    innodb_buffer_pool_size=4096M
    innodb_lock_wait_timeout=900
    innodb_log_file_size=1024M
    max_allowed_packet=256M
EOF
```

### Update slinky-values.yaml

```yaml
accounting:
  enabled: true
  storageConfig:
    host: mariadb
    port: 3306
    database: slurm_acct_db
    user: slurm
    passwordSecretRef:
      name: mariadb-password
      key: password
```

Then upgrade:

```sh
helm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  -f slinky-values.yaml \
  --namespace=slurm
```

---

## Autoscaling with KEDA (Optional)

Scale NodeSets based on pending Slurm jobs.

### Install Dependencies

```sh
# Prometheus
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/kube-prometheus-stack \
  --set 'installCRDs=true' \
  --namespace prometheus --create-namespace

# KEDA
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda \
  --namespace keda --create-namespace
```

### Enable Slurm Metrics

Add to `slinky-values.yaml`:

```yaml
controller:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
```

### Create a ScaledObject

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: scale-gpu-a10
  namespace: slurm
spec:
  scaleTargetRef:
    apiVersion: slinky.slurm.net/v1beta1
    kind: NodeSet
    name: slurm-worker-gpu-a10
  idleReplicaCount: 0
  minReplicaCount: 1
  maxReplicaCount: 16
  triggers:
    - type: prometheus
      metricType: Value
      metadata:
        serverAddress: http://prometheus-kube-prometheus-prometheus.prometheus:9090
        query: slurm_partition_jobs_pending{partition="gpu-a10"}
        threshold: '1'
```

> **Note:** KEDA scales the NodeSet by adjusting `replicas`. Ensure your OKE node pool can scale to match.

---

## SSH into the Cluster via Login Node

```sh
SLURM_LOGIN_IP=$(kubectl get svc -n slurm slurm-login-slinky \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

ssh root@${SLURM_LOGIN_IP}
```

From inside the login pod:

```sh
sinfo                          # View cluster status
srun hostname                  # Run a quick test
srun --gres=gpu:1 nvidia-smi   # Test GPU access
sbatch --wrap="sleep 60"       # Submit a batch job
squeue                         # View job queue
sacct                          # View job accounting (if enabled)
```

---

## Key Decisions Summary

| Decision | Recommendation for OKE HPC |
|---|---|
| **Scaling mode** | `replicas` set to number of GPU nodes (chart v1.0.2); use `nodeSelector` to target the GPU shape |
| **Storage class** | `oci-bv` for controller persistence |
| **GPU detection (VM)** | `AutoDetect=nvidia` in gres.conf |
| **GPU detection (BM)** | Manual GRES config (`Name=gpu Type=<type> File=/dev/nvidia[0-N]`) -- AutoDetect fails on BM shapes due to core affinity mismatch |
| **RDMA (hostNetwork)** | hostNetwork + `/dev/infiniband` hostPath + `/dev/shm` emptyDir (no Network Operator needed) |
| **RDMA (SR-IOV)** | `nvidia.com/sriov-rdma-vf: 16` resource + `k8s.v1.cni.cncf.io/networks` annotation (requires Network Operator) |
| **hostNetwork DNS** | `dnsPolicy: ClusterFirstWithHostNet` required (hostNetwork only) |
| **CPU mismatch** | `ReturnToService=2` in controller config (hostNetwork only — SR-IOV pods see correct CPU counts) |
| **CRI-O memlock** | Must set `memlock=-1:-1` in CRI-O `default_ulimits` on BM GPU nodes for RDMA memory registration |
| **NCCL socket** | `NCCL_SOCKET_IFNAME=eth0` required (hostNetwork only — not needed with SR-IOV) |
| **MPI launcher (stock image)** | Use `sbatch` + `mpirun` with `-mca btl self,vader,tcp -mca btl_tcp_if_include eth0 -mca oob_tcp_if_include eth0 --bind-to none` |
| **MPI launcher (PMIx image)** | `srun --mpi=pmix` works directly; requires `slurmd-rdma-pmix` + `slurmctld-pmix` images with `PropagateResourceLimitsExcept: MEMLOCK` |
| **OpenMPI interface** | Must export `OMPI_MCA_*` in sbatch scripts (hostNetwork only); Docker ENV vars are NOT inherited by srun tasks |
| **libibverbs staging** | Do NOT stage `libibverbs.so` from container images; must use host-matched version to avoid segfaults in `ibv_cmd_reg_dmabuf_mr` |
| **slurmd sshd** | Use `nodesets.<name>.ssh.extraSshdConfig: Port 2222` for hostNetwork workers only; do not add this to SR-IOV/VF workers |
| **slurmctld PMIx** | slurmctld image lacks `libpmix.so`; `srun --mpi=pmix` requires custom slurmctld + slurmd images |
| **Login access** | LoginSet with LoadBalancer service |
| **Accounting** | Optional; deploy MariaDB via mariadb-operator if needed |
| **Autoscaling** | KEDA + Prometheus for scaling NodeSets on pending jobs |

---

## Building Custom Slurm Images (Optional)

The stock Slinky slurmd image (`ghcr.io/slinkyproject/slurmd:25.11-ubuntu24.04`) does not include CUDA, NCCL, or NCCL test binaries. For bare-metal RDMA clusters, build custom images that include everything needed to run NCCL workloads natively.

### Pre-Built Images

The following images are available for OCI bare-metal GPU + RDMA deployments:

| Image | Tag | Description |
|---|---|---|
| `iad.ocir.io/idxzjcdglx2s/slinky` | `slurmd-rdma-25.11-ubuntu24.04` | slurmd + CUDA/NCCL/RDMA tools + nccl-tests + perftest (stock OpenMPI) |
| `iad.ocir.io/idxzjcdglx2s/slinky` | `slurmd-rdma-pmix-25.11-ubuntu24.04` | Same as above + OpenMPI 5.0.7 rebuilt with PMIx/Slurm support |
| `iad.ocir.io/idxzjcdglx2s/slinky` | `slurmctld-pmix-25.11-ubuntu24.04` | slurmctld + libpmix (needed for `srun --mpi=pmix`) |

**Which image to use:**
- `slurmd-rdma` — simple, multi-node NCCL via `sbatch` + `mpirun`
- `slurmd-rdma-pmix` + `slurmctld-pmix` — full `srun --mpi=pmix` support for both single-node and multi-node RDMA jobs

### Option A: Extend the Stock slurmd Image (Recommended)

The simplest approach is to extend the stock slurmd image with a custom Dockerfile that adds CUDA, NCCL, RDMA tools, nccl-tests, and perftest. A ready-to-use Dockerfile is provided at [`images/slurmd-rdma/Dockerfile`](images/slurmd-rdma/Dockerfile).

**Build:**

```sh
cd images/slurmd-rdma
docker build -t your-registry.example.com/slurmd-rdma:25.11-ubuntu24.04 .
docker push your-registry.example.com/slurmd-rdma:25.11-ubuntu24.04
```

**Use in Helm values:**

```yaml
nodesets:
  gpu-b4:
    slurmd:
      image:
        repository: your-registry.example.com/slurmd-rdma
        tag: 25.11-ubuntu24.04
```

This Dockerfile mirrors the [oci-hpc-oke NCCL test image](https://github.com/oracle-quickstart/oci-hpc-oke) but swaps the base from `nvcr.io/nvidia/cuda-dl-base` to the Slinky slurmd image. Key adaptations:

- **Base image**: `ghcr.io/slinkyproject/slurmd:25.11-ubuntu24.04` (includes slurmd, supervisord, OpenMPI)
- **MPI_HOME**: Changed from `/usr/local/mpi` to `/usr/lib/x86_64-linux-gnu/openmpi` (Ubuntu's OpenMPI path)
- **CUDA**: Installed from NVIDIA apt repos (not pre-installed in slurmd base)
- **Entrypoint**: Inherited from slurmd base (supervisord) -- not overridden

Includes:
- CUDA toolkit (nvcc) + runtime + NCCL 2.x
- RDMA userspace tools (`ibverbs`, `infiniband-diags`, `ibdev2netdev`, `perftest`)
- Pre-built `nccl-tests` at `/opt/nccl-tests/bin/` (also at `/workspace/nccl-tests/build/`)
- Pre-built `perftest` (`ib_write_bw`, `ib_read_bw`, etc.)
- Network diagnostics (`iproute2`, `ethtool`, `pciutils`, `numactl`, `iperf3`, `tcpdump`)
- `gpu-fryer` GPU stress test tool
- SSH config for passwordless inter-node communication

**Tested result:** 2-node / 16-GPU NCCL all_reduce over RDMA achieved **~185 GB/s** avg bus bandwidth on BM.GPU.B4.8 with this image.

> **Note on libibverbs:** The Dockerfile installs `libibverbs` and `rdma-core` from the Ubuntu 24.04 repos. If your host RDMA stack uses a different version, you may need to pin the package version or bind-mount the host's libraries at runtime via `LD_LIBRARY_PATH`.

### Option A.2: PMIx-Enabled Images

For `srun --mpi=pmix` support (eliminates the `sbatch` + `mpirun` workaround), two additional Dockerfiles are provided:

- [`images/slurmd-rdma-pmix/Dockerfile`](images/slurmd-rdma-pmix/Dockerfile) — Everything in `slurmd-rdma` plus OpenMPI 5.0.7 rebuilt from source with `--with-pmix --with-slurm`, and `OMPI_MCA` env vars baked in
- [`images/slurmctld-pmix/Dockerfile`](images/slurmctld-pmix/Dockerfile) — Adds `libpmix2t64` to the stock slurmctld image (required for the `mpi/pmix_v5` plugin)

Key design decisions in the PMIx slurmd image:
- OpenMPI built with `--without-verbs --without-ucx` — NCCL handles RDMA directly; OpenMPI only needs TCP for its MPI-level control plane
- `OMPI_MCA_oob_tcp_if_include=eth0` and `OMPI_MCA_btl_tcp_if_include=eth0` baked in as ENV — required for hostNetwork (OpenMPI picks up K8s pod IPs causing `MPI_Bcast` to hang). These are harmless with SR-IOV but can be overridden at runtime if needed

> **Important:** Slurm's srun does NOT inherit Docker ENV vars from the container. The `OMPI_MCA_*` vars are available inside the container (e.g., via `kubectl exec`) but NOT in srun-spawned tasks. You must explicitly `export OMPI_MCA_oob_tcp_if_include=eth0` and `export OMPI_MCA_btl_tcp_if_include=eth0` in your sbatch scripts when using the hostNetwork approach. With SR-IOV, these are not needed.

**Build and push:**

```sh
# slurmctld with PMIx
cd images/slurmctld-pmix
docker build -t your-registry.example.com/slurmctld-pmix:25.11-ubuntu24.04 .
docker push your-registry.example.com/slurmctld-pmix:25.11-ubuntu24.04

# slurmd with PMIx-enabled OpenMPI
cd ../slurmd-rdma-pmix
docker build -t your-registry.example.com/slurmd-rdma-pmix:25.11-ubuntu24.04 .
docker push your-registry.example.com/slurmd-rdma-pmix:25.11-ubuntu24.04
```

**Use in Helm values:**

```yaml
controller:
  slurmctld:
    image:
      repository: your-registry.example.com/slurmctld-pmix
      tag: 25.11-ubuntu24.04
  extraConfMap:
    GresTypes: "gpu"
    ReturnToService: 2
    PropagateResourceLimitsExcept: MEMLOCK   # Required for srun RDMA jobs

nodesets:
  gpu-b4:
    slurmd:
      image:
        repository: your-registry.example.com/slurmd-rdma-pmix
        tag: 25.11-ubuntu24.04
```

> **Important:** `PropagateResourceLimitsExcept: MEMLOCK` is required in the controller config. Without it, Slurm sets the memlock soft limit to 8MB on srun-spawned tasks, causing RDMA `ibv_reg_mr` to fail. (The `sbatch` + `mpirun` approach avoids this because `ulimit -l unlimited` can be set in the batch script.)

**Tested results (BM.GPU.B4.8, 2 nodes / 16 GPUs):**

| Approach | Image | Avg Bus BW |
|---|---|---|
| `sbatch` + `mpirun` | slurmd-rdma | ~185 GB/s |
| `srun --mpi=pmix` | slurmd-rdma-pmix + slurmctld-pmix | ~189 GB/s |
| Single-node `srun --mpi=pmix` | slurmd-rdma-pmix + slurmctld-pmix | ~228 GB/s |

### Option B: Modify the Slinky Build System

For deeper customization (e.g., rebuilding Slurm itself, adding PMIx to OpenMPI, or changing the base OS), modify the Slinky container source.

Clone the Slinky container build system:

```sh
git clone https://github.com/SlinkyProject/containers.git
cd containers
```

The relevant files:

```
schedmd/slurm/
├── docker-bake.hcl                  # Build orchestration (targets, tags, registry)
├── 25.11/ubuntu24.04/
│   ├── Dockerfile                   # Multi-stage build for all Slurm components
│   ├── Dockerfile.pyxis             # Extends slurmd/login with Pyxis+Enroot
│   ├── slurm.hcl                    # Version pinning (25.11.4)
│   └── files/                       # supervisord configs, entrypoints
```

### Dockerfile Build Chain

```
base (ubuntu:24.04 + slurm debs + supervisor)
├── base-extra (+ openmpi-bin)          ← Modify this for CUDA/NCCL/RDMA
│   ├── slurmd                          ← Modify this for nccl-tests
│   └── sackd (auth daemon) → login (extends sackd with sshd/sssd)
├── slurmctld                           ← Modify this for PMIx library (optional)
├── slurmdbd
└── slurmrestd
```

### What to Change

#### 1. Add CUDA, NCCL, and RDMA libraries to `base-extra`

In `schedmd/slurm/25.11/ubuntu24.04/Dockerfile`, replace the `base-extra` stage (around line 114):

```dockerfile
################################################################################
FROM base AS base-extra

SHELL ["bash", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

ADD https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb /tmp/cuda-keyring.deb

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked <<EOR
# Install Extra Packages
set -xeuo pipefail
dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb
apt-get -qq update
apt-get -qq -y install --no-install-recommends \
  openmpi-bin \
  cuda-cudart-13-1 \
  libnccl2 libnccl-dev \
  libibverbs-dev rdma-core ibverbs-providers \
  cuda-nvcc-13-1 \
  build-essential git
EOR
```

> **Note on libibverbs:** The installed `libibverbs` version must match the host kernel's RDMA modules. If your host RDMA stack is newer/older than what's in the Ubuntu 24.04 repos, you may need to pin the package version or bind-mount the host's libraries at runtime.

#### 2. Build nccl-tests and perftest into the `slurmd` stage

In the same Dockerfile, add a new `RUN` block inside the `slurmd` stage (after the "Install Slurm Packages" block, before the `COPY files/...` lines):

```dockerfile
# Build NCCL tests
ARG NCCL_TESTS_VERSION=2.18.2  # Check https://github.com/NVIDIA/nccl-tests/releases for latest
ARG NVCC_GENCODE="-gencode=arch=compute_80,code=sm_80 -gencode=arch=compute_90,code=sm_90 -gencode=arch=compute_100,code=sm_100 -gencode=arch=compute_120,code=sm_120 -gencode=arch=compute_120,code=compute_120"

RUN <<EOR
set -xeuo pipefail
cd /tmp
git clone --depth 1 --branch v${NCCL_TESTS_VERSION} https://github.com/NVIDIA/nccl-tests.git
cd nccl-tests
make -j MPI=1 MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi \
  CUDA_HOME=/usr/local/cuda NCCL_HOME=/usr \
  NVCC_GENCODE="${NVCC_GENCODE}"
mkdir -p /opt/nccl-tests/bin
cp build/*_perf /opt/nccl-tests/bin/
cd / && rm -rf /tmp/nccl-tests
EOR

# Build perftest (RDMA benchmarks)
ARG PERFTEST_VERSION=perftest-26.01.5

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked <<EOR
set -xeuo pipefail
apt-get -qq update
apt-get -qq -y install --no-install-recommends \
  autoconf automake libtool libpci-dev
for lib in libibverbs.so.1 librdmacm.so.1 libibumad.so.3 libmlx5.so.1 libefa.so.1; do
  base=$(echo $lib | sed 's/\.so\..*/\.so/')
  ln -sf /usr/lib/x86_64-linux-gnu/$lib /usr/lib/x86_64-linux-gnu/$base 2>/dev/null || true
done
cd /tmp
git clone --depth 1 --branch ${PERFTEST_VERSION} https://github.com/linux-rdma/perftest.git
cd perftest
./autogen.sh
./configure --prefix=/usr/local \
  CUDA_H_PATH=/usr/local/cuda/include/cuda.h \
  --enable-cuda --with-cuda=/usr/local/cuda
make -j && make install
cd / && rm -rf /tmp/perftest
EOR
```

#### 3. (Optional) Rebuild OpenMPI with PMIx support

The stock Ubuntu `openmpi-bin` package lacks Slurm PMIx support, which means you must use `sbatch` + `mpirun` instead of `srun` for multi-node MPI jobs. To fix this, replace `openmpi-bin` in `base-extra` with a custom build:

```dockerfile
# Replace "openmpi-bin" in the apt-get install above with this block:
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked <<EOR
set -xeuo pipefail
apt-get -qq update
apt-get -qq -y install --no-install-recommends \
  libpmix-dev libhwloc-dev libevent-dev wget
wget -q https://download.open-mpi.org/release/open-mpi/v5.0/openmpi-5.0.7.tar.gz
tar xzf openmpi-5.0.7.tar.gz && cd openmpi-5.0.7
./configure --prefix=/usr/local --with-pmix --with-slurm --with-hwloc --without-verbs --without-ucx
make -j$(nproc) && make install && ldconfig
cd / && rm -rf /tmp/openmpi*
EOR
```

With this change on the slurmd side, you also need to install PMIx on the **slurmctld** image for end-to-end `srun --mpi=pmix` support. In the `slurmctld` stage, add:

```dockerfile
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked <<EOR
set -xeuo pipefail
apt-get -qq update
apt-get -qq -y install --no-install-recommends libpmix2t64
EOR
```

With both sides rebuilt, `srun --mpi=pmix` works directly for multi-node NCCL jobs, and the `sbatch` + `mpirun` workaround is no longer needed.

### Build

```sh
cd schedmd/slurm

# Build just the slurmd image
docker buildx bake -f docker-bake.hcl -f 25.11/ubuntu24.04/slurm.hcl \
  --set "*.args.REGISTRY=your-registry.example.com/slinky" \
  slurmd

# Build all images
docker buildx bake -f docker-bake.hcl -f 25.11/ubuntu24.04/slurm.hcl \
  --set "*.args.REGISTRY=your-registry.example.com/slinky" \
  core
```

### Use Custom Images in Helm Values

```yaml
nodesets:
  gpu-b4:
    slurmd:
      image:
        repository: your-registry.example.com/slinky/slurmd
        tag: 25.11-ubuntu24.04
```

### Changes to the NCCL Test Image

If you're building a standalone NCCL test image (for MPIJob or direct testing outside Slurm), no changes are needed to the Dockerfile. The existing image works as-is with the Kueue MPIJob pattern.

However, if you want the same image to work inside Slurm's slurmd pods (via `srun`), the MPI build must include PMIx support. Replace the `MPI_HOME` to use a PMIx-enabled OpenMPI build, or build nccl-tests without MPI (remove `MPI=1`) for single-process multi-GPU mode (`-g 8`).

For `srun` compatibility without rebuilding OpenMPI, build nccl-tests without MPI:

```dockerfile
# In your NCCL test Dockerfile, change the nccl-tests build line:
RUN cd nccl-tests-${NCCL_TESTS_VERSION} \
    && make -j NVCC_GENCODE="${NVCC_GENCODE}" \
    ...
```

This produces a binary that uses NCCL's built-in bootstrap (no MPI_Init), which works directly with `srun` for single-node multi-GPU tests (`-g 8`). Multi-node still requires MPI or NCCL's socket bootstrap.

## Cleanup

```sh
helm uninstall slurm -n slurm
helm uninstall slurm-operator -n slinky
helm uninstall slurm-operator-crds
helm uninstall cert-manager -n cert-manager
kubectl delete namespace slurm slinky
```
