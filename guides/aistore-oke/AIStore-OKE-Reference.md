# AIStore on OKE — Detailed Reference

## Overview

This guide covers deploying NVIDIA AIStore on an existing OKE cluster with bare-metal nodes that have local NVMe storage. AIStore uses the NVMe drives as high-performance object storage targets.

### Tested Configuration

| Component | Details |
|-----------|---------|
| Node Shape | BM.DenseIO.E5.128 (128 OCPUs, 1.5TB RAM, 12x 5.8T NVMe, 100 Gbps NIC) |
| Nodes | 6 |
| OKE Stack | oci-hpc-oke |
| Kubernetes | v1.33.1 |
| AIStore | v4.3 |
| cert-manager | v1.16.2 |
| Deployment | 6 proxies + 6 targets (1:1 per node) |
| Total Capacity | ~418 TiB (6 nodes x 12 drives x 5.8 TiB) |

---

## 1. NVMe Drive Preparation

### Why Individual Mounts

AIStore targets expect each mountpath to be a separate filesystem, not a RAID array. This allows AIStore to distribute data across disks independently, detect individual disk failures, and report per-disk metrics.

### NVMe Provisioner DaemonSet

Instead of SSHing into each node, deploy a DaemonSet that automatically tears down any existing RAID and formats each NVMe drive individually. The DaemonSet is idempotent — it skips drives that are already mounted.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvme-provisioner
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: nvme-provisioner
  template:
    metadata:
      labels:
        app: nvme-provisioner
    spec:
      nodeSelector:
        aistore.nvidia.com/role: proxy-target
      hostPID: true
      hostNetwork: true
      containers:
      - name: nvme-setup
        image: ubuntu:24.04
        securityContext:
          privileged: true
        command:
        - /bin/bash
        - -c
        - |
          apt-get update -qq && apt-get install -y -qq mdadm xfsprogs util-linux > /dev/null 2>&1

          set -euo pipefail
          echo "=== NVMe provisioner starting on $(hostname) ==="

          FSTAB="/host-etc/fstab"
          MDADM_CONF="/host-etc/mdadm/mdadm.conf"

          # Stop any existing RAID
          if grep -q md0 /proc/mdstat 2>/dev/null; then
            echo "Tearing down existing RAID..."
            umount /mnt/nvme 2>/dev/null || true
            mdadm --stop /dev/md0 2>/dev/null || true
            mdadm --stop --scan 2>/dev/null || true
            for dev in /dev/nvme*n1; do
              mdadm --zero-superblock $dev 2>/dev/null || true
            done
            echo "" > "${MDADM_CONF}" 2>/dev/null || true
            sed -i '/\/dev\/md0/d' "${FSTAB}"
            sed -i '/\/mnt\/nvme/d' "${FSTAB}"
          fi

          # Format and mount each NVMe drive individually
          DISKS=($(ls -1 /dev/nvme*n1 2>/dev/null | sort -V))
          echo "Found ${#DISKS[@]} NVMe drives"
          for idx in "${!DISKS[@]}"; do
            dev="${DISKS[$idx]}"
            mp="/mnt/nvme${idx}"
            if mountpoint -q "${mp}" 2>/dev/null; then
              echo "${mp} already mounted, skipping"
              continue
            fi
            echo "Setting up ${dev} -> ${mp}"
            mkdir -p "${mp}"
            wipefs -a "${dev}" 2>/dev/null || true
            mkfs.xfs -f "${dev}"
            mount -o defaults,noatime,nofail "${dev}" "${mp}"
            uuid=$(blkid -s UUID -o value "${dev}")
            sed -i "\|${mp}|d" "${FSTAB}"
            echo "UUID=${uuid} ${mp} xfs defaults,noatime,nofail 0 2" >> "${FSTAB}"
          done

          echo "=== NVMe provisioner done ==="
          df -h | grep nvme

          # Sleep forever to keep the DaemonSet running
          sleep infinity
        volumeMounts:
        - name: host-dev
          mountPath: /dev
        - name: host-mnt
          mountPath: /mnt
          mountPropagation: Bidirectional
        - name: host-etc
          mountPath: /host-etc
        - name: host-run
          mountPath: /run/mdadm
      volumes:
      - name: host-dev
        hostPath:
          path: /dev
      - name: host-mnt
        hostPath:
          path: /mnt
      - name: host-etc
        hostPath:
          path: /etc
      - name: host-run
        hostPath:
          path: /run/mdadm
      tolerations:
      - operator: Exists
```

**How it works:**
- Runs on all nodes with the `aistore.nvidia.com/role=proxy-target` label
- Requires `privileged: true` and host root mount for disk operations
- Tears down any existing RAID array (oci-hpc-oke may configure NVMe as RAID)
- Formats each NVMe drive as XFS and mounts at `/mnt/nvme0` through `/mnt/nvmeN`
- Updates `/etc/fstab` with UUID-based entries for persistence across reboots
- Idempotent — skips drives that are already mounted
- Sleeps after setup to keep the pod running (DaemonSet requirement)

**Note:** Label nodes before deploying the DaemonSet (section 4), or the pods won't schedule.

### Verification

```bash
# Check DaemonSet pods
kubectl -n kube-system get pods -l app=nvme-provisioner -o wide
kubectl -n kube-system logs -l app=nvme-provisioner --tail=5

# Verify from a worker node
df -h | grep nvme
# Expected: 12 drives at /mnt/nvme0 through /mnt/nvme11, each ~5.8T

cat /proc/mdstat
# Expected: unused devices: <none>
```

### Cleanup

To remove the provisioner after setup (the mounts persist independently):

```bash
kubectl delete daemonset nvme-provisioner -n kube-system
```

---

## 2. Network Tuning

Deploy a DaemonSet to apply sysctl settings on all worker nodes (from the NVIDIA ais-k8s playbook). Uses an init container to write and apply the config, then runs a pause container to keep the DaemonSet alive:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: sysctl-tuner
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: sysctl-tuner
  template:
    metadata:
      labels:
        app: sysctl-tuner
    spec:
      nodeSelector:
        aistore.nvidia.com/role: proxy-target
      hostPID: true
      hostNetwork: true
      initContainers:
      - name: sysctl-apply
        image: ubuntu:24.04
        securityContext:
          privileged: true
        command:
        - /bin/bash
        - -c
        - |
          cat << 'SYSCTL' > /host-etc/sysctl.d/99-aistore.conf
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
          SYSCTL
          sysctl -p /host-etc/sysctl.d/99-aistore.conf
          echo "=== sysctl tuning applied on $(hostname) ==="
        volumeMounts:
        - name: host-etc
          mountPath: /host-etc
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
      volumes:
      - name: host-etc
        hostPath:
          path: /etc
      tolerations:
      - operator: Exists
```

**How it works:**
- Init container writes `/etc/sysctl.d/99-aistore.conf` on the host and applies it
- Pause container keeps the DaemonSet running (Kubernetes requirement)
- Settings persist across reboots via the sysctl.d config file
- `hostPID: true` and `privileged: true` required for sysctl to take effect on the host

Alternatively, apply manually via SSH (see the quickstart for the raw sysctl commands).

Key settings:
- `rmem_max`/`wmem_max` at 128MB — critical for 100 Gbps links (default 30MB leaves throughput on the table)
- `tcp_mtu_probing=2` — required for jumbo frames (MTU 9000)
- `tcp_slow_start_after_idle=0` — prevents throughput drops after idle periods

Verify MTU: `ip link show eth0 | grep mtu` — should be 9000.

---

## 3. Cert-Manager

Check if cert-manager is already running (the oci-hpc-oke stack may have installed it as an OKE addon):

```bash
kubectl get pods -n cert-manager | grep Running
```

If pods show `Running`, skip to section 4. A namespace existing with no pods means cert-manager was partially installed — proceed with the install below:

```bash
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.crds.yaml
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml

kubectl -n cert-manager rollout status deploy/cert-manager --timeout=120s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=120s
```

---

## 4. AIStore Operator

```bash
kubectl create namespace ais
helm repo add ais https://nvidia.github.io/ais-k8s/charts
helm repo update
helm upgrade --install ais-operator ais/ais-operator --namespace ais

# Service account with cluster-admin
kubectl -n ais create serviceaccount ais-sa
kubectl create clusterrolebinding ais-sa-cluster-admin \
  --clusterrole=cluster-admin --serviceaccount=ais:ais-sa

# Wait for operator
sleep 15
kubectl get pods -n ais
kubectl get crd | grep ais
```

### Node Labeling

Label all DenseIO worker nodes:

```bash
for node in $(kubectl get nodes -l node.kubernetes.io/instance-type=BM.DenseIO.E5.128 -o name); do
  kubectl label $node aistore.nvidia.com/role=proxy-target --overwrite
done

# Verify
kubectl get nodes -l aistore.nvidia.com/role=proxy-target
```

If the OKE label `node.kubernetes.io/instance-type` isn't available, label by node name:

```bash
kubectl get nodes
# Then label each DenseIO node manually
kubectl label node <node-ip-or-name> aistore.nvidia.com/role=proxy-target --overwrite
```

---

## 5. AIStore Cluster Deployment

### Configuration

Deploy 6 proxies + 6 targets (1:1 per node). Targets use `hostNetwork: true` to avoid port conflicts with proxies on the same node:

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
    size: 6
    servicePort: 51080
    portPublic: 51080
    portIntraControl: 51082
    portIntraData: 51083
    nodeSelector:
      aistore.nvidia.com/role: proxy-target
  targetSpec:
    size: 6
    hostNetwork: true
    servicePort: 51081
    portPublic: 51081
    portIntraControl: 51082
    portIntraData: 51083
    nodeSelector:
      aistore.nvidia.com/role: proxy-target
    mounts:
    - path: "/mnt/nvme0"
      useHostPath: true
      size: 5Ti
      label: "nvme"
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
    - path: "/mnt/nvme4"
      useHostPath: true
      size: 5Ti
      label: "nvme"
    - path: "/mnt/nvme5"
      useHostPath: true
      size: 5Ti
      label: "nvme"
    - path: "/mnt/nvme6"
      useHostPath: true
      size: 5Ti
      label: "nvme"
    - path: "/mnt/nvme7"
      useHostPath: true
      size: 5Ti
      label: "nvme"
    - path: "/mnt/nvme8"
      useHostPath: true
      size: 5Ti
      label: "nvme"
    - path: "/mnt/nvme9"
      useHostPath: true
      size: 5Ti
      label: "nvme"
    - path: "/mnt/nvme10"
      useHostPath: true
      size: 5Ti
      label: "nvme"
    - path: "/mnt/nvme11"
      useHostPath: true
      size: 5Ti
      label: "nvme"
```

### Key Configuration Choices

| Setting | Value | Why |
|---------|-------|-----|
| `proxySpec.size: 6` | 1 proxy per node | NVIDIA-recommended 1:1 ratio for HA and write throughput |
| `targetSpec.hostNetwork: true` | Targets on host network | Eliminates port conflicts (51082/51083) between proxy and target on the same node |
| `targetSpec.size: 6` | 1 target per node | AIStore scales with disks, not targets |
| 12 mounts per target | 1 per NVMe drive | Each drive is an independent mountpath |
| `size: 5Ti` per mount | Conservative | Accounts for XFS overhead on 5.8T drives |

### Why hostNetwork on Targets

Without hostNetwork, proxy and target pods both need intra-cluster ports (51082, 51083) via hostPort. When scheduled on the same node, these conflict. With `hostNetwork: true` on targets, targets bind directly to the host network namespace, so ports don't conflict with proxy pods that use pod networking.

### Deploy

```bash
kubectl apply -f aiscluster.yaml

# Watch pods come up
kubectl -n ais get pods -w

# Verify statefulsets
kubectl -n ais get sts
# Expected: ais-proxy 6/6, ais-target 6/6
```

### Verification

```bash
# Targets should have host IPs (e.g., 10.140.x.x), proxies should have pod IPs
kubectl -n ais get pods -o wide

# Check services
kubectl -n ais get svc
```

---

## 6. Load Balancer Service

Create a Load Balancer for access to the AIStore proxy:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ais-proxy-lb
  namespace: ais
  annotations:
    service.beta.kubernetes.io/oci-load-balancer-shape: "flexible"
    service.beta.kubernetes.io/oci-load-balancer-shape-flex-min: "100"
    service.beta.kubernetes.io/oci-load-balancer-shape-flex-max: "4900"
spec:
  type: LoadBalancer
  selector:
    app: ais
    component: proxy
  ports:
  - name: pub
    protocol: TCP
    port: 51080
    targetPort: 51080
```

Wait for external IP:

```bash
kubectl get svc -n ais ais-proxy-lb -w
# Note the EXTERNAL-IP once assigned
```

**Note:** Use a regular OCI Load Balancer (not NLB). NLB health checks may fail to reach worker NodePorts in certain OKE configurations. The regular LB uses the Kubernetes proxy for health checking which works reliably.

### LB Shape and AIStore Traffic Flow

Use the flexible shape (`100-4900 Mbps`) for production. However, the LB shape has **minimal impact on aggregate throughput** because AIStore bypasses the LB for data transfers:

1. Client sends PUT/GET to the LB
2. LB routes to a proxy pod
3. Proxy determines which target owns the object
4. Proxy sends an **HTTP redirect** to the client with the target's direct address
5. Client talks **directly to the target** — data never flows through the LB

With `hostNetwork: true` on targets, the redirect points to the target's host IP (e.g., `10.140.x.x:51081`). Any client inside the VCN follows the redirect and transfers data at full NIC speed, not LB speed.

**LB shape matters for:** single external clients, applications that don't follow redirects, and proxy-to-proxy communication. **LB shape doesn't matter for:** multi-client benchmarks with hostNetwork, or any client that can reach target host IPs directly.

---

## 7. AIS CLI Installation

Build the AIS CLI and aisloader benchmark tool from source:

```bash
# Install Go 1.26+ and build tools (system Go is typically too old)
sudo apt-get update && sudo apt-get install -y make
sudo rm -rf /usr/local/go
curl -fsSL https://go.dev/dl/go1.26.1.linux-amd64.tar.gz | sudo tar -C /usr/local -xz
export PATH=/usr/local/go/bin:$PATH
echo 'export PATH=/usr/local/go/bin:$PATH' >> ~/.bashrc
go version  # should show go1.26.1

# Build AIS CLI and aisloader from source
export GOPATH=$HOME/go
mkdir -p $GOPATH/src/github.com/NVIDIA
cd $GOPATH/src/github.com/NVIDIA
git clone https://github.com/NVIDIA/aistore.git
cd aistore
make cli aisloader
sudo cp $GOPATH/bin/ais $GOPATH/bin/aisloader /usr/local/bin/
ais version
```

### Connect to Cluster

```bash
export AIS_ENDPOINT=http://$(kubectl get svc -n ais ais-proxy-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):51080
ais show cluster
```

Expected output:
```
Proxies:    6 (all electable)
Targets:    6 (total disks: N)
Capacity:   used X%, available ~418 TiB
Status:     12 online
```

### Smoke Test

```bash
ais create ais://test-bucket
echo "Hello from AIStore" > /tmp/test.txt
ais put /tmp/test.txt ais://test-bucket/test.txt
ais get ais://test-bucket/test.txt /tmp/test-out.txt
cat /tmp/test-out.txt
ais ls ais://test-bucket
```

---

## 8. Benchmarking

### Single Client

```bash
export AIS_ENDPOINT=http://$(kubectl get svc -n ais ais-proxy-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):51080

# Pre-create bucket
ais create ais://bench

# Write
aisloader -bucket=ais://bench -duration=1m -numworkers=32 \
  -minsize=1MB -maxsize=1MB -pctput=100 -cleanup=false

# Read
aisloader -bucket=ais://bench -duration=1m -numworkers=32 \
  -minsize=1MB -maxsize=1MB -pctput=0 -cleanup=false
```

### Multi-Client (aggregate throughput)

Pre-create the benchmark bucket from one node, then run aisloader from all 6 nodes in parallel:

```bash
# On one node first:
export AIS_ENDPOINT=http://$(kubectl get svc -n ais ais-proxy-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):51080
ais create ais://bench

# Then on all 6 nodes simultaneously:
aisloader -bucket=ais://bench -duration=1m -numworkers=64 \
  -minsize=1MB -maxsize=1MB -pctput=100 -cleanup=false \
  -ip=$(kubectl get svc -n ais ais-proxy-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}') -port=51080
```

**Important:** Pre-create the bucket before launching parallel clients to avoid `ErrBucketAlreadyExists` race conditions.

### Benchmark Parameters

| Parameter | Description |
|-----------|-------------|
| `-numworkers` | Concurrent goroutines per client (32 for single-client, 64 for multi-client) |
| `-minsize`/`-maxsize` | Object size range |
| `-pctput` | PUT percentage (100 = all writes, 0 = all reads) |
| `-duration` | Test duration (e.g., `1m`, `5m`, `1h`) |
| `-cleanup` | Delete objects after test |

### Benchmark Results (BM.DenseIO.E5.128, 6 nodes, 6P+6T, Flexible LB)

**Multi-client (6 nodes x 64 workers, 1MB objects, 1 min):**

| Test | Per-node range | Aggregate | Errors |
|------|---------------|-----------|--------|
| Write | 6.37 - 6.55 GiB/s | **~38.8 GiB/s** | 0 |
| Read | 12.47 - 12.68 GiB/s | **~75.3 GiB/s** | 0 |

Read throughput (~12.5 GiB/s per node) exceeds the 100 Gbps NIC theoretical limit (~11.6 GiB/s) because AIStore redirects GET requests directly to targets via `hostNetwork`, allowing some reads to be served locally without crossing the network.

**LB shape matters.** The default 100 Mbps shape bottlenecks single-client access. Use the flexible shape (100-4900 Mbps) for production workloads.

NVIDIA's own benchmarks with 16 DenseIO.E5 nodes achieved **167 GiB/s** aggregate read throughput (~10.4 GiB/s per node). Our 6-node result of 75.3 GiB/s (~12.5 GiB/s per node) is proportionally better, likely due to the hostNetwork optimization.

---

## 9. Troubleshooting

### Pods stuck in ImagePullBackOff

Docker Hub rate limiting. Login to Docker Hub on each worker node via CRI-O:

```bash
echo "<password>" | sudo skopeo login docker.io --username <user> --password-stdin
```

Or pre-pull images:

```bash
sudo apt-get install -y skopeo
sudo skopeo copy --src-creds <user>:<pass> \
  docker://docker.io/aistorage/ais-init:v4.3 containers-storage:docker.io/aistorage/ais-init:v4.3
sudo skopeo copy --src-creds <user>:<pass> \
  docker://docker.io/aistorage/aisnode:v4.3 containers-storage:docker.io/aistorage/aisnode:v4.3
```

### Pods not scheduled on DenseIO nodes

Check for taints:

```bash
kubectl describe node <node> | grep Taints
```

If nodes have `nvidia.com/gpu` taint, add tolerations to the AIStore CR:

```yaml
tolerations:
- key: "nvidia.com/gpu"
  operator: "Exists"
  effect: "NoSchedule"
```

### AIStore proxy crashes with "BMD UUIDs don't match"

Leftover state from a previous deployment. Clean all NVMe drives:

```bash
sudo rm -rf /mnt/aistore /mnt/nvme*/ais
```

### aisloader "cannot assign requested address"

Ephemeral port exhaustion. Apply sysctl tuning (section 2) and use 32 workers instead of 64 for single-client tests.

### NVMe drives still in RAID after prep

The oci-hpc-oke stack may configure NVMe as RAID. See the "tear down RAID" steps at the top of section 1.

### Targets not joining proxy

If targets use hostNetwork and can't reach proxies on pod IPs, check that pod-to-host networking works:

```bash
# From a worker node, test reaching a proxy pod IP
curl -sk http://<proxy-pod-ip>:51080/v1/health
```

If unreachable, check iptables and NSG rules. Set `iptables -P FORWARD ACCEPT` on all worker nodes.

---

## 10. Performance Tuning

### Proxy-to-Target Ratio

NVIDIA recommends 1 proxy + 1 target per node. With 6 nodes, use 6 proxies + 6 targets. The `hostNetwork: true` setting on targets enables this without port conflicts.

Fewer proxies bottleneck write throughput — benchmarks show 2 proxies vs 6 proxies gives ~61% lower write performance.

### Target-per-Node

Run 1 target per node with all NVMe drives as separate mountpaths. From the NVIDIA docs: "AIStore scales linearly with each added disk (and not target)."

### MTU

Ensure jumbo frames (MTU 9000) on all nodes: `ip link show eth0 | grep mtu`.

### AIStore Configuration Defaults

| Parameter | Default | Description |
|-----------|---------|-------------|
| `disk.disk_util_low_wm` | 60 | Below this: no I/O throttling |
| `disk.disk_util_high_wm` | 80 | Above this: maximum throttle |
| `rebalance.enabled` | true | Auto-rebalance on cluster changes |
| `mirror.enabled` | false | N-way replication (not needed with network redundancy) |

### Multihoming

BM.DenseIO.E5.128 has 100 Gbps networking. AIStore supports multihoming (v3.22+) with secondary VNICs to use additional network interfaces, potentially increasing throughput. Requires Multus CNI — not covered in this guide.

---

## 11. OCI Object Storage Backend

To use AIStore as a cache for OCI Object Storage buckets, use the OCI-specific image and provide credentials:

```yaml
spec:
  nodeImage: "aistorage/aisnode:v4.3-oci"
  ociSecretName: "oci-config"
  targetSpec:
    env:
    - name: OCI_COMPARTMENT_OCID
      value: "ocid1.compartment.oc1..xxxxx"
```

Create the secret:

```bash
kubectl -n ais create secret generic oci-config \
  --from-file=config=$HOME/.oci/config \
  --from-file=oci_api_key.pem=$HOME/.oci/oci_api_key.pem
```

### Ports

| Port | Purpose |
|------|---------|
| 51080 | Proxy public (client API) |
| 51081 | Target public |
| 51082 | Intra-cluster control |
| 51083 | Intra-cluster data |
