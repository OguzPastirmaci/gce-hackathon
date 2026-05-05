# AIStore on Slurm GPU Nodes — Detailed Reference

## Overview

This guide covers deploying NVIDIA AIStore as a high-performance object storage cache on GPU nodes that are part of a Slurm cluster. Two deployment models are covered: **Kind** (sections 1-10, for testing) and **OKE** (section 13, for production), with shared guidance on production considerations and performance tuning (sections 11-12). Both share the local NVMe drives between Slurm and AIStore.

### Architecture

```
GPU Node (BM.GPU.B4.8)
├── nvme0n1 ─── /mnt/localdisk (XFS, Slurm scratch + enroot + slurm-tmp)
├── nvme1n1 ─── /mnt/nvme1 (XFS, AIStore target mountpath)
├── nvme2n1 ─── /mnt/nvme2 (XFS, AIStore target mountpath)
├── nvme3n1 ─── /mnt/nvme3 (XFS, AIStore target mountpath)
├── Slurm (slurmd) ── 8x A100 GPUs, 128 CPUs
└── Kind (Docker) ── K8s cluster
    ├── cert-manager
    ├── AIStore operator
    ├── ais-proxy-0 (1 proxy)
    └── ais-target-0 (1 target, 3 NVMe mounts)
```

### Why Kind Instead of OKE

For testing and development, Kind provides several advantages over OKE for running AIStore on Slurm nodes:

- **No OKE bootstrap required** — avoids docker-ce/docker.io swap, instance metadata updates, and `oke.sh` bootstrapping
- **No networking changes** — no NSG/security list updates for ports 51080-51083
- **Self-contained** — entire K8s cluster runs inside Docker on the GPU node
- **Quick iteration** — destroy and recreate in seconds with `kind delete cluster`
- **No CPU reservation complexity** — Kind doesn't compete with Slurm for CPU scheduling

For production deployments, see the converged Slurm+OKE guide which bootstraps the GPU nodes as self-managed OKE nodes.

### Tested Configuration

| Component | Version/Details |
|-----------|----------------|
| Node Shape | BM.GPU.B4.8 (8x A100, 128 CPUs, 4x 6.2T NVMe) |
| OS | Ubuntu 24.04 |
| Slurm | 25.11.0 |
| Kind | v0.31.0 |
| Kubernetes | v1.32.2 (via Kind) |
| AIStore | v4.3 |
| cert-manager | v1.16.2 |
| Docker | 29.3.1 |
| Go | 1.23.6 (for CLI build) |

### Benchmark Results (BM.GPU.B4.8, 3x 6.2T NVMe)

| Test | Object Size | Workers | Throughput | Avg Latency | Duration |
|------|------------|---------|------------|-------------|----------|
| Write | 1 MB | 64 | ~390 MiB/s | ~165 ms | 1 min |
| Read | 1 MB | 64 | ~8.5 GiB/s | ~7.3 ms | 1 min |

---

## 1. NVMe Drive Splitting

### Background

The Slurm HPC stack configures all local NVMe drives as a single RAID0 array mounted at `/mnt/localdisk`. For AIStore, we need to split this so that:

- `nvme0n1` remains dedicated to Slurm (scratch space, enroot containers, slurm-tmp)
- Remaining drives (`nvme1n1`, `nvme2n1`, `nvme3n1`) are formatted individually for AIStore targets

### Using the localdisk-aistore Playbook

The `localdisk-aistore` playbook (added to the HPC stack) automates this split. It:

1. Tears down the existing RAID0 array (`/dev/md0`)
2. Zeroes superblocks and wipes filesystem signatures on all drives
3. Partitions and formats `nvme0n1` as XFS, mounts at `/mnt/localdisk`
4. Cleans up `mdadm.conf` and rebuilds initramfs
5. Recreates service directories (`slurm-tmp`, `enroot`)
6. Updates NHC config to expect `nvme0n1p1` instead of `md0`

**From the GPU node:**

```bash
sudo /config/bin/custom_ansible.sh localdisk_aistore
```

**From the controller via mgmt:**

```bash
mgmt nodes reconfigure --nodes GPU-XXXX --action localdisk-aistore
```

### Important: Drain Node First

Always drain the node in Slurm before running this playbook — it destroys all data on `/mnt/localdisk`:

```bash
# From the controller
sudo scontrol update NodeName=GPU-XXXX State=DRAIN Reason="localdisk-aistore setup"
```

**Reserved nodes:** If a node has a Slurm reservation, draining alone may not be enough. The `job_container/tmpfs` feature creates bind mounts under `/mnt/localdisk/slurm-tmp/<jobid>` that prevent unmounting `/dev/md0`. If the playbook fails with `Device or resource busy` on `mkfs.xfs`:

```bash
# Check for leftover slurm-tmp bind mounts
mount | grep slurm-tmp

# Unmount them
sudo umount -f /mnt/localdisk/slurm-tmp/* 2>/dev/null

# Delete the reservation if needed
sudo scontrol delete reservation <reservation_name>

# Then re-run the playbook
```

After the playbook completes, resume the node:

```bash
sudo scontrol update NodeName=GPU-XXXX State=RESUME
```

### Verification

```bash
# Check disk layout
lsblk | grep nvme
# Expected:
# nvme0n1     259:2    0   6.2T  0 disk
# └─nvme0n1p1 259:6    0   6.2T  0 part /mnt/localdisk
# nvme1n1     259:3    0   6.2T  0 disk   (raw)
# nvme2n1     259:1    0   6.2T  0 disk   (raw)
# nvme3n1     259:0    0   6.2T  0 disk   (raw)

# Verify RAID is gone
cat /proc/mdstat
# Expected: unused devices: <none>

# Verify Slurm directories exist
ls -la /mnt/localdisk/slurm-tmp  # slurm:slurm, mode 01777
ls -la /mnt/localdisk/enroot     # ubuntu:ubuntu, mode 0777

# Verify NHC config was updated
grep localdisk /etc/nhc/oci.nhc.conf
# Expected: check_fs_mount_rw -t "xfs" -s "/dev/nvme0n1p1" -f "/mnt/localdisk"
```

### What Breaks If You Skip the NHC Fix

The NHC (Node Health Check) config is rendered from a Jinja2 template at node provisioning time. It contains a `check_fs_mount_rw` line that expects `/mnt/localdisk` to be mounted from `/dev/md0`. If not updated:

- NHC healthcheck fails
- Slurm's `HealthCheckProgram` returns non-zero
- Node goes to `DRAIN` state
- Jobs fail with "Prolog failure on node"

The `localdisk-aistore` playbook handles this automatically by replacing `/dev/md0` with `/dev/nvme0n1p1` in `/etc/nhc/oci.nhc.conf`.

### Reverting to RAID0

To put all drives back into a single RAID0 array:

```bash
# 1. Stop AIStore and Kind first (the NVMe drives are in use)
sudo kind delete cluster --name aistore

# 2. Unmount AIStore drives
sudo umount /mnt/nvme1 /mnt/nvme2 /mnt/nvme3

# 3. Remove AIStore fstab entries
sudo sed -i '/\/mnt\/nvme[0-9]/d' /etc/fstab

# 4. Drain the node
sudo scontrol update NodeName=GPU-XXXX State=DRAIN Reason="reverting to RAID0"

# 5. Recreate the RAID0 array
mgmt nodes reconfigure --nodes GPU-XXXX --action localdisk-raid0

# 6. Resume the node
sudo scontrol update NodeName=GPU-XXXX State=RESUME
```

---

## 2. Formatting NVMe Drives for AIStore

After the `localdisk-aistore` playbook leaves the remaining drives raw, they need to be formatted individually and mounted at `/mnt/nvme1`, `/mnt/nvme2`, `/mnt/nvme3` for AIStore.

### Why Individual Mounts (Not RAID)

AIStore targets expect each mountpath to be a separate filesystem. This allows AIStore to:

- Distribute data across disks independently
- Detect and handle individual disk failures
- Report per-disk capacity and I/O metrics

### Preparation Script

Save as `/tmp/prep_nvme_aistore.sh` and run with `sudo bash`:

```bash
#!/bin/bash
set -euo pipefail
for i in 1 2 3; do
  dev="/dev/nvme${i}n1"
  mp="/mnt/nvme${i}"
  echo "=== Setting up ${dev} -> ${mp} ==="
  mkdir -p "${mp}"
  wipefs -a "${dev}"
  mkfs.xfs -f "${dev}"
  mount -o defaults,noatime,nofail "${dev}" "${mp}"
  uuid=$(blkid -s UUID -o value "${dev}")
  # Remove any existing fstab entry for this mount, then add
  sed -i "\|${mp}|d" /etc/fstab
  echo "UUID=${uuid} ${mp} xfs defaults,noatime,nofail 0 2" >> /etc/fstab
done
echo "=== Done ==="
df -h | grep nvme
```

**Note:** The script is idempotent — it removes existing fstab entries before adding new ones, so it's safe to run multiple times. Adjust the loop range (`1 2 3`) based on the number of NVMe drives available. BM.GPU.B4.8 has 4 drives (nvme0-3), BM.GPU.H100.8 has 8 drives (nvme0-7).

### Verification

```bash
df -h | grep nvme
# Expected:
# /dev/nvme0n1p1  6.2T  122G  6.1T   2% /mnt/localdisk
# /dev/nvme1n1    6.2T  122G  6.1T   2% /mnt/nvme1
# /dev/nvme2n1    6.2T  122G  6.1T   2% /mnt/nvme2
# /dev/nvme3n1    6.2T  122G  6.1T   2% /mnt/nvme3

# Verify fstab entries
grep nvme /etc/fstab
```

---

## 3. Installing Prerequisites

All tools are installed on the GPU node where AIStore will run.

### Kind

```bash
curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
chmod +x /tmp/kind
sudo mv /tmp/kind /usr/local/bin/kind
kind version
```

### kubectl

```bash
curl -Lo /tmp/kubectl "https://dl.k8s.io/release/v1.32.3/bin/linux/amd64/kubectl"
chmod +x /tmp/kubectl
sudo mv /tmp/kubectl /usr/local/bin/kubectl
kubectl version --client
```

### Helm

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### Go (for building AIS CLI)

```bash
curl -fsSL https://go.dev/dl/go1.23.6.linux-amd64.tar.gz | sudo tar -C /usr/local -xz
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh
export PATH=$PATH:/usr/local/go/bin
go version
```

---

## 4. Creating the Kind Cluster

### Configuration

The Kind config mounts the AIStore NVMe paths into both control-plane and worker containers:

```yaml
# /tmp/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: /mnt/nvme1
    containerPath: /mnt/nvme1
  - hostPath: /mnt/nvme2
    containerPath: /mnt/nvme2
  - hostPath: /mnt/nvme3
    containerPath: /mnt/nvme3
- role: worker
  extraMounts:
  - hostPath: /mnt/nvme1
    containerPath: /mnt/nvme1
  - hostPath: /mnt/nvme2
    containerPath: /mnt/nvme2
  - hostPath: /mnt/nvme3
    containerPath: /mnt/nvme3
```

**Note:** Both nodes get all mounts because AIStore pods can be scheduled on either. The `hostPath` volumes pass through directly — writes inside the Kind container go to the actual NVMe drives.

### Create Cluster

```bash
sudo kind create cluster --config /tmp/kind-config.yaml --name aistore
```

### Verification

```bash
sudo kubectl --kubeconfig /root/.kube/config get nodes
# Expected:
# aistore-control-plane   Ready   control-plane   ...
# aistore-worker          Ready   <none>          ...
```

### Destroying and Recreating

```bash
sudo kind delete cluster --name aistore
# Then re-create with the same command
```

---

## 5. Installing Cert-Manager

Cert-manager is a prerequisite for the AIStore operator's webhook TLS certificates.

```bash
export KUBECONFIG=/root/.kube/config

kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.crds.yaml
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
```

### Verification

Wait for all three deployments to be ready:

```bash
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=120s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=120s

kubectl -n cert-manager get pods
# Expected: 3 pods, all Running
```

---

## 6. Installing AIStore Operator

The AIStore operator manages the AIStore CRD and handles deployment of proxy and target pods.

```bash
export KUBECONFIG=/root/.kube/config

kubectl create namespace ais
helm repo add ais https://nvidia.github.io/ais-k8s/charts
helm repo update
helm upgrade --install ais-operator ais/ais-operator --namespace ais
```

### Service Account Setup

AIStore needs a service account with cluster-admin permissions:

```bash
kubectl -n ais create serviceaccount ais-sa
kubectl create clusterrolebinding ais-sa-cluster-admin \
  --clusterrole=cluster-admin --serviceaccount=ais:ais-sa
```

### Node Labeling

Label the worker node so AIStore knows where to schedule pods:

```bash
kubectl label node aistore-worker aistore.nvidia.com/role=proxy-target --overwrite
```

Label values:
- `proxy-target` — node runs both proxy and target pods
- `target-only` — node runs only target pods (use for data-heavy nodes)

### Verification

```bash
kubectl get crd | grep ais
# Expected: aistores.ais.nvidia.com

kubectl get pods -n ais
# Expected: ais-operator-controller-manager-xxx  Running
```

---

## 7. Deploying AIStore Cluster

### Configuration

The AIStore custom resource defines the cluster topology:

```yaml
# /tmp/aiscluster.yaml
apiVersion: ais.nvidia.com/v1beta1
kind: AIStore
metadata:
  name: ais
  namespace: ais
spec:
  hostpathPrefix: "/mnt/aistore"
  logsDir: "/mnt/aistore/logs"
  nodeImage: "aistorage/aisnode:v4.3"
  initImage: "aistorage/ais-init:v4.3"
  enableExternalLB: false
  proxySpec:
    size: 1
    servicePort: 51080
    hostPort: 51080
    portPublic: 51080
    portIntraControl: 51082
    portIntraData: 51083
  targetSpec:
    size: 1
    servicePort: 51081
    hostPort: 51081
    portPublic: 51081
    portIntraControl: 51082
    portIntraData: 51083
    mounts:
    - path: "/mnt/nvme1"
      useHostPath: true
      size: 5Ti
      label: "nvme"
    - path: "/mnt/nvme2"
      useHostPath: true
      size: 5Ti
      label: "nvme"
    - path: "/mnt/nvme3"
      useHostPath: true
      size: 5Ti
      label: "nvme"
```

### Key Configuration Fields

| Field | Description |
|-------|-------------|
| `hostpathPrefix` | Where AIStore stores metadata and state inside the Kind container (not on the NVMe data drives). Created automatically by the operator. |
| `nodeImage` | AIStore node image. Use `-oci` suffix for OCI Object Storage backend support |
| `enableExternalLB` | Set `true` if you need external access via OCI Load Balancer |
| `proxySpec.size` | Number of proxy pods (gateway/routing layer) |
| `targetSpec.size` | Number of target pods (storage layer) |
| `targetSpec.mounts` | NVMe mount paths — one entry per drive |
| `useHostPath` | Must be `true` when using host NVMe drives |
| `size` | Reported capacity per mount. Set conservatively (e.g., `5Ti` for 6.2T drives) to account for XFS overhead |

### Scaling for Multiple Nodes

Set `targetSpec.size` to match the number of GPU nodes with NVMe drives. Set `proxySpec.size` to 1 for small clusters, 2-3 for larger ones:

```yaml
proxySpec:
  size: 2      # 1 proxy per 2-3 target nodes is a good ratio
targetSpec:
  size: 6      # 1 target per GPU node — match this to your node count
```

### Deploy

```bash
kubectl apply -f /tmp/aiscluster.yaml
```

### Verification

```bash
# Wait for pods
kubectl -n ais get pods -w

# Check statefulsets
kubectl -n ais get sts
# Expected:
# ais-proxy    1/1
# ais-target   1/1

# Check services
kubectl -n ais get svc
# Expected:
# ais-proxy    ClusterIP  None  51080/TCP,51082/TCP,51083/TCP
# ais-target   ClusterIP  None  51081/TCP,51082/TCP,51083/TCP
```

---

## 8. Installing AIS CLI

The AIS CLI is built from source using Go. Since Kind and kubectl run as root (KUBECONFIG is at `/root/.kube/config`), the AIS CLI and port-forward commands should also run as root:

```bash
export PATH=$PATH:/usr/local/go/bin
export GOPATH=/root/go
mkdir -p $GOPATH/src/github.com/NVIDIA
cd $GOPATH/src/github.com/NVIDIA
git clone https://github.com/NVIDIA/aistore.git
cd aistore
make cli
cp $GOPATH/bin/ais /usr/local/bin/
ais version
```

### Connecting to AIStore

Since AIStore runs inside Kind's pod network, use `kubectl port-forward` to access it from the host:

```bash
kubectl -n ais port-forward svc/ais-proxy 51080:51080 &
export AIS_ENDPOINT=http://localhost:51080
```

### Verify Cluster Status

```bash
ais show cluster
```

Expected output shows proxies, targets, capacity, and disk count:

```
PROXY                    MEM USED(%) MEM AVAIL  LOAD AVERAGE  UPTIME  K8s POD      STATUS
p[Jpjj3i0r3azc3][P]     0.00%       1.92TiB    [...]         5m      ais-proxy-0  online

TARGET       MEM USED(%) MEM AVAIL  CAP USED(%) CAP AVAIL   LOAD AVERAGE  UPTIME  K8s POD       STATUS
t[axWHfQTi]  0.00%       1.92TiB    1%          18.196TiB   [...]         5m      ais-target-0  online

Cluster:
   Proxies:   1
   Targets:   1 (num disks: 12)
   Capacity:  used 363.83GiB (1%), available 18.20TiB
```

**Note:** "num disks: 12" means 12 logical disks — AIStore counts XFS allocation groups (4 per drive x 3 drives = 12), not physical NVMe drives.

---

## 9. Testing and Benchmarking

### Smoke Test

```bash
# Create a bucket
ais create ais://test-bucket

# Upload a file
echo "Hello from AIStore on Slurm" > /tmp/test.txt
ais put /tmp/test.txt ais://test-bucket/test.txt

# Download and verify
ais get ais://test-bucket/test.txt /tmp/test-out.txt
cat /tmp/test-out.txt

# List bucket contents
ais ls ais://test-bucket

# Storage summary
ais storage summary
```

### Building aisloader

```bash
cd $GOPATH/src/github.com/NVIDIA/aistore
make aisloader
cp $GOPATH/bin/aisloader /usr/local/bin/
```

### Write Benchmark

```bash
aisloader -bucket=ais://bench -duration=1m -numworkers=64 \
  -minsize=1MB -maxsize=1MB -pctput=100 -cleanup=false \
  -ip=localhost -port=51080
```

### Read Benchmark

```bash
# Requires a bucket with existing objects (run write benchmark first)
aisloader -bucket=ais://bench -duration=1m -numworkers=64 \
  -minsize=1MB -maxsize=1MB -pctput=0 -cleanup=false \
  -ip=localhost -port=51080
```

### Benchmark Parameters

| Parameter | Description |
|-----------|-------------|
| `-bucket` | Target bucket (use `ais://` prefix for local buckets) |
| `-duration` | Test duration (e.g., `1m`, `5m`, `1h`) |
| `-numworkers` | Number of concurrent workers |
| `-minsize`/`-maxsize` | Object size range |
| `-pctput` | Percentage of PUT operations (100 = all writes, 0 = all reads) |
| `-cleanup` | Delete objects after test |

### Mixed Read/Write Test

```bash
# 70% read, 30% write
aisloader -bucket=ais://bench -duration=5m -numworkers=64 \
  -minsize=1MB -maxsize=1MB -pctput=30 -cleanup=false \
  -ip=localhost -port=51080
```

---

## 10. Troubleshooting

### AIStore pods stuck in Pending

Check if the worker node has the correct label:

```bash
kubectl get nodes --show-labels | grep aistore
kubectl describe pod -n ais ais-target-0 | grep -A5 Events
```

### Port-forward dies

The `kubectl port-forward` command runs in the foreground and dies when the SSH session ends. For persistence:

```bash
nohup kubectl -n ais port-forward svc/ais-proxy 51080:51080 &>/dev/null &
```

### aisloader connection refused

Ensure port-forward is running and `AIS_ENDPOINT` is set:

```bash
export AIS_ENDPOINT=http://localhost:51080
pgrep -f "port-forward.*51080" || kubectl -n ais port-forward svc/ais-proxy 51080:51080 &
```

### NVMe drive not visible inside Kind

Verify the mount is present in the Kind container:

```bash
docker exec aistore-worker df -h | grep nvme
```

If missing, the Kind config `extraMounts` may not include the path. Destroy and recreate the cluster with the correct config.

### Slurm node goes to INVALID after localdisk-aistore

Check the slurmd unit override for stale gres configuration:

```bash
cat /etc/systemd/system/slurmd.service.d/unit.conf
# Look for --conf "Gres=gpu:XXX:8"
# The GPU type must match the actual hardware
```

If wrong, update it, reload systemd, and restart slurmd:

```bash
sudo sed -i 's/Gres=gpu:H100:8/Gres=gpu:A100:8/' /etc/systemd/system/slurmd.service.d/unit.conf
sudo systemctl daemon-reload
sudo systemctl restart slurmd
```

Then delete the node from slurmctld and let it re-register:

```bash
# From the controller
sudo scontrol delete NodeName=GPU-XXXX
# slurmd will re-register with correct gres
```

If the node keeps coming back with the wrong gres, stop slurmd, stop slurmctld, delete `/config/spool_*/slurm/node_state*`, restart slurmctld, then restart slurmd.

### NHC healthcheck fails after localdisk-aistore

The NHC config expects `/dev/md0` but the mount is now `/dev/nvme0n1p1`. The playbook should fix this automatically, but if it didn't:

```bash
sudo sed -i 's|/dev/md0|/dev/nvme0n1p1|' /etc/nhc/oci.nhc.conf
```

---

## 11. Production Considerations

### Kind vs OKE

Kind is suitable for testing and development. For production AIStore deployments on Slurm nodes, consider the converged Slurm+OKE approach which:

- Joins GPU nodes to an OKE cluster as self-managed nodes
- Uses `--reserved-cpus` to partition CPUs between Slurm and Kubernetes (e.g., `0-119` for Slurm, leaving CPUs 120-127 for K8s/AIStore on a 128-CPU node)
- Supports OCI Load Balancer for external AIStore access
- Enables OCI Object Storage as an AIStore backend

### OCI Object Storage Backend

To use AIStore as a cache for OCI Object Storage, add the OCI secret and use the `-oci` image tag:

```yaml
spec:
  nodeImage: "aistorage/aisnode:v4.3-8045374-oci"
  ociSecretName: "oci-config"
  targetSpec:
    env:
    - name: OCI_COMPARTMENT_OCID
      value: "ocid1.compartment.oc1..xxxxx"
```

Create the OCI config secret:

```bash
kubectl -n ais create secret generic oci-config \
  --from-file=config=$HOME/.oci/config \
  --from-file=oci_api_key.pem=$HOME/.oci/oci_api_key.pem
```

### Ports

AIStore uses the following ports:

| Port | Purpose |
|------|---------|
| 51080 | Proxy public (client API) |
| 51081 | Target public |
| 51082 | Intra-cluster control |
| 51083 | Intra-cluster data |

For OKE or external access, open ports 51080-51083 in the NSG/security lists.

---

## 12. Performance Tuning (from NVIDIA AIStore docs)

### Proxy-to-Target Ratio

NVIDIA recommends **1 proxy and 1 target per node** for production. For HA, deploy **3+ proxies** so automatic primary failover works without a single point of failure.

To run 1:1 (e.g., 6 proxies + 6 targets on 6 nodes), enable `hostNetwork: true` on targets. This puts targets in the host network namespace, eliminating port conflicts with proxy pods on the same node. Without hostNetwork, proxy and target share intra-cluster ports (51082, 51083) causing scheduling conflicts.

Benchmarked impact (6 nodes, OKE):

| Config | Write aggregate | Read aggregate |
|--------|----------------|----------------|
| 2 proxies + 6 targets | 13.0 GiB/s | 37.6 GiB/s |
| 6 proxies + 6 targets (hostNetwork) | **20.9 GiB/s** | **38.7 GiB/s** |

The 6-proxy setup improved write throughput by **61%** because writes fan out through proxies — more proxies means more parallel write paths. Read throughput barely changed because reads are NIC-limited (~50 Gbps per node).

### Target-per-Node

Run **1 target per node with multiple mountpaths** — not multiple targets. From the NVIDIA docs: "AIStore scales linearly with each added disk (and not target)." Our 1-target-with-3-mountpaths setup is optimal.

### Network Sysctl Tuning

Apply these on all AIStore nodes for high-throughput networking (from `ais-k8s/playbooks/host-config/vars/host_config_sysctl.yml`):

```bash
sudo sysctl -w net.core.somaxconn=65535
sudo sysctl -w net.core.rmem_max=134217728
sudo sysctl -w net.core.wmem_max=134217728
sudo sysctl -w net.core.optmem_max=25165824
sudo sysctl -w net.core.netdev_max_backlog=250000
sudo sysctl -w net.ipv4.tcp_wmem="4096 16384 134217728"
sudo sysctl -w net.ipv4.tcp_rmem="4096 262144 134217728"
sudo sysctl -w net.ipv4.tcp_tw_reuse=1
sudo sysctl -w net.ipv4.ip_local_port_range="2048 65535"
sudo sysctl -w net.ipv4.tcp_max_tw_buckets=1440000
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=100000
sudo sysctl -w net.ipv4.tcp_mtu_probing=2
sudo sysctl -w net.ipv4.tcp_slow_start_after_idle=0
sudo sysctl -w net.ipv4.tcp_adv_win_scale=1
```

To make persistent:

```bash
cat << 'EOF' | sudo tee /etc/sysctl.d/99-aistore.conf
net.core.somaxconn=65535
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.core.optmem_max=25165824
net.core.netdev_max_backlog=250000
net.ipv4.tcp_wmem=4096 16384 134217728
net.ipv4.tcp_rmem=4096 262144 134217728
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=2048 65535
net.ipv4.tcp_max_tw_buckets=1440000
net.ipv4.tcp_max_syn_backlog=100000
net.ipv4.tcp_mtu_probing=2
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_adv_win_scale=1
EOF
sudo sysctl -p /etc/sysctl.d/99-aistore.conf
```

### MTU

Ensure MTU is set to **9000** (jumbo frames) on all nodes. OCI BM shapes typically have this by default on the primary NIC. Verify with `ip link show eth0 | grep mtu`.

### CPU and Memory

AIStore is I/O bound, not CPU bound. No strict resource minimums. Larger node memory benefits reads through the Linux page cache. For Kubernetes Guaranteed QoS, set `requests = limits`:

```yaml
resources:
  requests:
    cpu: "8"
    memory: "32Gi"
  limits:
    cpu: "8"
    memory: "32Gi"
```

### Multihoming

BM.GPU.B4.8 nodes have multiple NICs. AIStore supports multihoming (v3.22+) to use secondary VNICs for data traffic, potentially doubling throughput. This requires additional VNICs and Multus CNI configuration — not covered in this guide but documented in the ais-k8s repo.

### AIStore Configuration

Keep defaults unless tuning for specific workloads:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `disk.disk_util_low_wm` | 60 | Below this: no I/O throttling |
| `disk.disk_util_high_wm` | 80 | Above this: maximum throttle |
| `rebalance.enabled` | true | Auto-rebalance on cluster changes |
| `mirror.enabled` | false | N-way replication (not needed with network redundancy) |

---

## 13. Converged Slurm + OKE Deployment

This section covers deploying AIStore on OKE using the same GPU nodes that are part of a Slurm cluster. The nodes run both Slurm (for GPU workloads) and Kubernetes (for AIStore), sharing NVMe drives between them.

### Architecture

```
VCN (172.16.0.0/18 + 10.140.0.0/16 secondary CIDR)
├── Slurm Cluster (172.16.x.x subnets)
│   ├── Controller
│   ├── Login node
│   └── GPU nodes (BM.GPU.B4.8) ── also OKE self-managed workers
├── OKE Cluster (10.140.x.x subnets)
│   ├── Control plane (managed, 10.140.0.0/29)
│   ├── System pool (1x VM.Standard.E5.Flex, 10.140.64.0/19)
│   ├── Bastion (10.140.0.8/29)
│   ├── Operator (10.140.0.16/29)
│   └── Pod subnet (10.140.128.0/17)
└── NLB ── AIStore proxy endpoint
```

### Prerequisites

- Slurm cluster deployed with the HPC stack
- GPU nodes with NVMe split done (`localdisk-aistore`)
- NVMe drives formatted individually (`/mnt/nvme1`, `/mnt/nvme2`, `/mnt/nvme3`)
- OCI CLI available on the cluster nodes

### Deviations from NVIDIA PDF Guides

The NVIDIA PDFs ("AIStore Converged with Nodes in Slurm and OKE both" and "NVIDIA AIStore on OCI OKE Complete Guide") assume nodes provisioned via OKE node pools. Our converged setup uses existing Slurm nodes as self-managed OKE workers, which required these changes:

1. **Instance metadata update** — must remove `compute_management` read-only field before updating (causes 400 error otherwise)
2. **GPU tolerations** — OKE's GPU device plugin taints nodes with `nvidia.com/gpu: present`; the AIStore CR must include tolerations (not in PDFs)
3. **NSG/security list rules** — cross-CIDR communication between Slurm subnet (`172.16.x.x`) and OKE subnets (`10.140.x.x`) must be explicitly allowed (not needed when OKE manages its own nodes)
4. **iptables FORWARD ACCEPT** — required on self-managed nodes for pod-to-pod traffic (mentioned in PDF but easy to miss)
5. **Image pre-pull via skopeo** — CRI-O doesn't share Docker's image cache; Docker Hub rate limits hit quickly with unauthenticated pulls
6. **NLB configuration** — requires `externalTrafficPolicy: Local` (not specified in PDFs)
7. **Client sysctl tuning** — `tcp_tw_reuse=1` and wider ephemeral port range needed for high-throughput benchmarks
8. **Stale AIStore state** — old AIStore data from Kind deployments causes "BMD UUIDs don't match" errors; must clean `/mnt/nvme*/ais` before deploying on OKE

### 13.1 Deploy OKE Cluster

Use the `oci-hpc-oke` Terraform stack to deploy an OKE cluster into the Slurm VCN. Key configuration:

- Add `10.140.0.0/16` as a secondary CIDR to the existing VCN
- Pre-create subnets in the `10.140.x.x` range with DNS labels
- Set `create_vcn = false` and provide `vcn_id` + subnet IDs
- Deploy only the system pool (no GPU worker pools)
- Use `oci_auth = "instance_principal"`
- Run Terraform from a cluster node, not locally

**Important:** The OKE stack's subnet auto-calculation uses the VCN's primary CIDR. When using an existing VCN, you must pre-create subnets in the secondary CIDR and pass their IDs to avoid CIDR conflicts.

**Bastion/operator subnets must have DNS labels** — create them with `--dns-label` or the OKE bastion/operator instances will fail to launch.

### 13.2 Networking: NSG and Security List Rules

This is the most critical part. The Slurm nodes (172.16.x.x) need to communicate with OKE components (10.140.x.x) and vice versa. Required rules:

**Control plane NSG** — allow from Slurm subnet:
- Ingress TCP 6443 from `172.16.0.0/18` (K8s API)
- Ingress TCP 12250 from `172.16.0.0/18` (OKE worker bootstrap)

**Worker NSG** — allow all between subnets:
- Ingress all from `172.16.0.0/18`
- Egress all to `172.16.0.0/18`
- Ingress all from `10.140.0.0/16`
- Egress all to `10.140.0.0/16`

**Pod NSG** — allow all between subnets:
- Ingress all from `172.16.0.0/18`
- Egress all to `172.16.0.0/18`

**Slurm private subnet security list** — add:
- Ingress all from `10.140.0.0/16`

**Pod and worker subnet security lists** — allow all:
- Ingress all from `0.0.0.0/0`
- Egress all to `0.0.0.0/0`

Without these rules, `oke bootstrap` will fail with timeout on port 12250, and AIStore pods won't be able to communicate across nodes.

### 13.3 Operator Setup

After the OKE cluster is created, fix the kubeconfig on the operator to use instance principal auth:

```bash
# SSH to operator via bastion
ssh -o ProxyCommand='ssh -W %h:%p ubuntu@<bastion-ip>' ubuntu@<operator-ip>

# Symlink OCI CLI
sudo ln -sf /home/ubuntu/bin/oci /usr/local/bin/oci

# Generate kubeconfig
oci ce cluster create-kubeconfig --cluster-id <cluster-id> \
  --file $HOME/.kube/config --region <region> \
  --token-version 2.0.0 --kube-endpoint PRIVATE_ENDPOINT \
  --auth instance_principal

# Add instance_principal auth to kubeconfig exec args
python3 -c "
import yaml
with open('$HOME/.kube/config') as f: c = yaml.safe_load(f)
for u in c.get('users', []):
    args = u.get('user', {}).get('exec', {}).get('args', [])
    if '--auth' not in args and '--region' in args:
        idx = args.index('--region')
        args.insert(idx, 'instance_principal')
        args.insert(idx, '--auth')
with open('$HOME/.kube/config', 'w') as f: yaml.dump(c, f, default_flow_style=False)
"

# Verify
kubectl get nodes
```

### 13.4 Bootstrap GPU Nodes into OKE

On each GPU node, run the following steps from the "AIStore Converged with Nodes in Slurm and OKE" guide:

**Step 1: Replace docker-ce with docker.io**

```bash
sudo systemctl disable --now docker || true
sudo apt-get purge -y docker-ce docker-ce-cli docker-ce-rootless-extras \
  docker-buildx-plugin docker-compose-plugin containerd.io 2>/dev/null || true
sudo apt-get autoremove -y
sudo apt-get -y update
sudo apt-get install -y docker.io
sudo systemctl enable --now docker
```

**Step 2: Update instance metadata**

The metadata update must remove the `compute_management` read-only field:

```python
#!/usr/bin/env python3
# save as /tmp/update_metadata.py
import json, subprocess, sys
meta = json.loads(subprocess.check_output(
    ["curl", "-sH", "Authorization: Bearer Oracle", "-L",
     "http://169.254.169.254/opc/v2/instance/metadata"], text=True))
meta.pop("compute_management", None)
meta["oke-native-pod-networking"] = "true"
meta["oke-max-pods"] = "32"
meta["pod-subnets"] = sys.argv[1]
with open("/tmp/meta.json", "w") as f:
    json.dump(meta, f)
instance_id = subprocess.check_output(
    ["curl", "-sH", "Authorization: Bearer Oracle", "-L",
     "http://169.254.169.254/opc/v2/instance/id"], text=True).strip()
result = subprocess.run([
    "/config/venv/Ubuntu_24.04_x86_64/oci/bin/oci", "compute", "instance", "update",
    "--instance-id", instance_id,
    "--metadata", "file:///tmp/meta.json",
    "--auth", "instance_principal", "--force"
], capture_output=True, text=True)
print("Metadata updated successfully" if result.returncode == 0 else f"Error: {result.stderr[-200:]}")
```

Run: `sudo python3 /tmp/update_metadata.py <pod-subnet-ocid>`

**Step 3: Run oke bootstrap**

```bash
sudo oke bootstrap \
  --apiserver-host <control-plane-private-ip> \
  --ca "<base64-ca-cert>" \
  --kubelet-extra-args "--reserved-cpus=0-119 --cpu-manager-policy=static --cpu-manager-policy-options=strict-cpu-reservation=true"
```

**Step 4: Set iptables FORWARD ACCEPT**

Required for pod-to-pod traffic on self-managed nodes:

```bash
sudo iptables -P FORWARD ACCEPT
```

**Note:** This is not persistent across reboots. To make it persistent on Ubuntu 24.04:

```bash
sudo apt-get install -y iptables-persistent
sudo iptables-save | sudo tee /etc/iptables/rules.v4
```

### 13.5 NPN (VCN-Native Pod Networking) Behavior

After bootstrapping, the OKE control plane creates NativePodNetwork CRs for each node to attach pod VNICs. This process:

- Happens asynchronously (not instant)
- Processes nodes at a limited rate
- Nodes stay `NotReady` until their pod VNIC is attached and CNI config is written
- Some nodes may take 10+ minutes to become Ready
- If nodes stay NotReady for over 15 minutes, check NPN CR status:

```bash
kubectl get nativepodnetwork -A
```

### 13.6 Deploy AIStore on OKE

**Prerequisites:** Install cert-manager, AIStore operator, service account, and label nodes (same as sections 5-6, run from the OKE operator). Then:

**Pre-pull images** to avoid Docker Hub rate limiting:

```bash
# Login to Docker Hub on each node
echo "<password>" | sudo docker login -u <username> --password-stdin

# Copy images from Docker Hub to CRI-O via skopeo
sudo apt-get install -y skopeo
sudo skopeo copy --src-creds <user>:<pass> \
  docker://docker.io/aistorage/ais-init:v4.3 \
  containers-storage:docker.io/aistorage/ais-init:v4.3
sudo skopeo copy --src-creds <user>:<pass> \
  docker://docker.io/aistorage/aisnode:v4.3 \
  containers-storage:docker.io/aistorage/aisnode:v4.3
```

**AIStore CR with GPU node tolerations:**

GPU nodes in OKE get a `nvidia.com/gpu: present` taint from the GPU device plugin. The AIStore CR must include tolerations. Set `hostNetwork: true` on targets to enable 1:1 proxy-target ratio (see section 12 for rationale):

```yaml
apiVersion: ais.nvidia.com/v1beta1
kind: AIStore
metadata:
  name: ais
  namespace: ais
spec:
  hostpathPrefix: "/mnt/aistore"
  logsDir: "/mnt/aistore/logs"
  nodeImage: "aistorage/aisnode:v4.3"
  initImage: "aistorage/ais-init:v4.3"
  enableExternalLB: false
  proxySpec:
    size: 6  # match to node count for 1:1 ratio
    servicePort: 51080
    portPublic: 51080
    portIntraControl: 51082
    portIntraData: 51083
    tolerations:
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
    nodeSelector:
      aistore.nvidia.com/role: proxy-target
  targetSpec:
    size: 6  # match to node count
    hostNetwork: true  # enables 1:1 proxy-target on same node
    servicePort: 51081
    portPublic: 51081
    portIntraControl: 51082
    portIntraData: 51083
    tolerations:
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
    nodeSelector:
      aistore.nvidia.com/role: proxy-target
    mounts:
    - path: "/mnt/nvme1"
      useHostPath: true
      size: 5Ti
      label: "nvme"
    - path: "/mnt/nvme2"
      useHostPath: true
      size: 5Ti
      label: "nvme"
    - path: "/mnt/nvme3"
      useHostPath: true
      size: 5Ti
      label: "nvme"
```

**Why hostNetwork on targets:** Without it, proxy and target pods compete for intra-cluster ports (51082, 51083) via hostPort, preventing co-location on the same node. With `hostNetwork: true`, targets bind directly to the host network, eliminating the conflict. Proxies stay on pod networking with their own ports. This enables the NVIDIA-recommended 1:1 ratio and improves write throughput by ~61%.

**NLB service** for external access:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ais-proxy-lb
  namespace: ais
  annotations:
    oci.oraclecloud.com/load-balancer-type: "nlb"
    oci-network-load-balancer.oraclecloud.com/node-label-selector: "aistore.nvidia.com/role=proxy-target"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector:
    app: ais
    component: proxy
  ports:
  - name: pub
    protocol: TCP
    port: 51080
    targetPort: 51080
```

**Important:** Use NLB (not LB) for better TCP performance. Set `externalTrafficPolicy: Local` — required for NLB. The `node-label-selector` restricts NLB backends to only proxy nodes.

**NLB tuning:**

Add `node-label-selector` to restrict NLB backends to only proxy nodes (avoids unhealthy backend noise):

```yaml
annotations:
  oci.oraclecloud.com/load-balancer-type: "nlb"
  oci-network-load-balancer.oraclecloud.com/node-label-selector: "aistore.nvidia.com/role=proxy-target"
```

The NLB defaults to `FIVE_TUPLE` load balancing policy (hash on src IP, src port, dst IP, dst port, protocol). With `externalTrafficPolicy: Local`, only nodes running proxy pods accept traffic — the NLB health checks automatically exclude nodes without proxies.

**NLB is not the bottleneck.** The per-node throughput is limited by the **50 Gbps primary NIC** (~5.8 GiB/s theoretical). Each proxy node handles both proxy routing and local target I/O on the same NIC. Verified by checking:
- NLB backend health: only proxy nodes are healthy, others correctly excluded
- NLB policy: FIVE_TUPLE distributes connections across healthy backends
- Actual per-node read throughput (~6.3 GiB/s) approaches the NIC theoretical limit

### 13.7 Client Tuning for Benchmarks

To avoid ephemeral port exhaustion when running `aisloader` with many workers:

```bash
sudo sysctl -w net.ipv4.ip_local_port_range="1024 65535"
sudo sysctl -w net.ipv4.tcp_tw_reuse=1
```

Use 32 workers instead of 64 to avoid port exhaustion:

```bash
export AIS_ENDPOINT=http://<nlb-external-ip>:51080
aisloader -bucket=ais://bench -duration=1m -numworkers=32 \
  -minsize=1MB -maxsize=1MB -pctput=100 -cleanup=false
```

### 13.8 OKE Benchmark Results (BM.GPU.B4.8, AIStore v4.3, NLB)

**Recommended config: 6 proxies + 6 targets with hostNetwork (6 parallel clients, 64 workers each):**

| Test | Per-node range | Aggregate | Errors |
|------|---------------|-----------|--------|
| Write | 3.34 - 3.67 GiB/s | **20.9 GiB/s** | 0 |
| Read | 6.31 - 6.65 GiB/s | **38.7 GiB/s** | 0 |

**Previous config: 2 proxies + 6 targets (6 parallel clients, 64 workers each):**

| Test | Per-node range | Aggregate | Errors |
|------|---------------|-----------|--------|
| Write | 1.69 - 2.37 GiB/s | ~13.0 GiB/s | 0 |
| Read | 6.09 - 6.45 GiB/s | ~37.6 GiB/s | 0 |

**Important:** Pre-create the benchmark bucket before launching parallel aisloader to avoid `ErrBucketAlreadyExists` race conditions:

```bash
export AIS_ENDPOINT=http://<nlb-ip>:51080
ais create ais://bench
# Then launch parallel aisloader from all nodes
```

**Comparison across deployment models (6 nodes, 6 parallel clients):**

| Setup | Proxies | Aggregate Write | Aggregate Read | Notes |
|-------|---------|----------------|----------------|-------|
| Kind (6 independent clusters) | 6 (local) | ~2.3 GiB/s | ~50.8 GiB/s | Local NVMe only, no network I/O |
| OKE (2P+6T, NLB) | 2 | ~13.0 GiB/s | ~37.6 GiB/s | Proxy bottleneck on writes |
| OKE (6P+6T, hostNetwork, NLB) | 6 | **20.9 GiB/s** | **38.7 GiB/s** | Optimal — 1:1 ratio, NIC-limited |

### Why Kind Read Numbers Are Higher Than OKE

Kind's aggregate read throughput (50.8 GiB/s) appears higher than OKE's (38.7 GiB/s), but these are fundamentally different workloads:

| Factor | Kind | OKE (6P+6T, hostNetwork) |
|--------|------|--------------------------|
| **Architecture** | 6 independent single-node clusters | 1 unified 6-node cluster |
| **Network path** | Localhost — zero network hops | NLB -> proxy -> target across pod/host network |
| **Data locality** | Client, proxy, target all on same host | Data distributed across 6 targets on different nodes |
| **Proxy ratio** | 6 independent proxies (1 per node) | 6 proxies + 6 targets (1:1 ratio via hostNetwork) |
| **What it measures** | Raw NVMe read speed (~8.5 GiB/s per drive set) | Distributed storage throughput including network overhead |

Kind's 50.8 GiB/s is the sum of 6 nodes each reading from local NVMe at ~8.5 GiB/s. No data crosses the network. OKE's 38.7 GiB/s is real distributed I/O where reads traverse the pod/host network.

The per-node read difference (8.5 -> ~6.5 GiB/s) is caused by the **50 Gbps primary NIC** being the bottleneck on OKE, not NVMe speed. BM.GPU.B4.8 nodes have a 50 Gbps primary NIC (~5.8 GiB/s theoretical); the measured ~6.5 GiB/s per node actually exceeds this slightly due to some reads being served locally. On Kind, reads are purely local NVMe I/O with no network involvement.

Write throughput is **much higher** on OKE (~3.5 GiB/s per node vs ~390 MiB/s on Kind) because AIStore distributes writes across all 6 targets in parallel through 6 proxies, whereas Kind writes only to the local target.

**Per-node variance** in OKE benchmarks is minimal with the 6P+6T hostNetwork config (~9% spread on writes, ~5% on reads). Remaining variance is caused by NLB FIVE_TUPLE hashing and minor differences in proxy-target co-location effects.

### 13.9 OKE Troubleshooting

**`oke bootstrap` fails with timeout on port 12250:**
The control plane NSG doesn't allow ingress from the Slurm subnet. Add TCP 12250 ingress from `172.16.0.0/18` to the control plane NSG.

**Nodes stay NotReady (CNI not ready):**
The NPN controller hasn't created NativePodNetwork CRs yet. Check with `kubectl get nativepodnetwork -A`. If CRs are missing, wait — the controller processes nodes asynchronously. Rebooting nodes doesn't help.

**AIStore pods not scheduled on GPU nodes:**
GPU nodes have taint `nvidia.com/gpu: present`. Add tolerations to the AIStore CR.

**AIStore proxy crashes with "BMD UUIDs don't match":**
Leftover state from a previous AIStore deployment (Kind or prior OKE). Clean all NVMe drives:
```bash
sudo rm -rf /mnt/aistore /mnt/nvme1/ais /mnt/nvme2/ais /mnt/nvme3/ais
```

**AIStore pods in ImagePullBackOff:**
Docker Hub rate limit. Pre-pull images using `skopeo` with Docker Hub credentials.

**aisloader "cannot assign requested address":**
Ephemeral port exhaustion. Tune sysctl (`tcp_tw_reuse=1`, wider port range) and use 32 workers instead of 64.

**AIStore targets can't join proxy (cross-node):**
Security lists on the Slurm private subnet block traffic from `10.140.0.0/16`. Add ingress rule for the OKE CIDR. Also set `iptables -P FORWARD ACCEPT` on all GPU nodes.
