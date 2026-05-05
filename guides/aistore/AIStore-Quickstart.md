# AIStore on Slurm GPU Nodes — Quickstart

Deploy NVIDIA AIStore on Slurm cluster GPU nodes. Two deployment options:
- **Kind** (steps 1-8) — for testing, each node runs its own K8s cluster
- **OKE** (steps 9-13) — for production, nodes join a shared OKE cluster

Both options use the spare NVMe drives while Slurm keeps one NVMe for `/mnt/localdisk`.

> **Differences from the NVIDIA PDFs:** The PDF guides assume nodes provisioned via OKE node pools. In our converged setup, we use existing Slurm GPU nodes as self-managed OKE workers. Key changes: (1) metadata update must remove `compute_management` read-only field, (2) GPU nodes need `nvidia.com/gpu` tolerations in the AIStore CR, (3) NSGs/security lists need rules for cross-CIDR communication, (4) `iptables -P FORWARD ACCEPT` required on self-managed nodes, (5) pre-pull images via `skopeo` to avoid Docker Hub rate limits with CRI-O.

## Prerequisites

- Slurm cluster deployed with the HPC stack
- GPU nodes with multiple NVMe drives (e.g., BM.GPU.B4.8 with 4x 6.2T NVMe)
- SSH access to the GPU nodes

## 1. Split NVMe Drives

**Drain the node first** — this destroys all data on `/mnt/localdisk`. If the node has a reservation, delete it first or the playbook may fail with `Device or resource busy`:

```bash
# From the controller
sudo scontrol update NodeName=GPU-XXXX State=DRAIN Reason="localdisk-aistore setup"
# If node is reserved: sudo scontrol delete reservation <name>
```

Run the `localdisk-aistore` playbook on each GPU node. This uses `nvme0n1` for Slurm (`/mnt/localdisk`) and leaves the remaining drives raw for AIStore.

```bash
# From the GPU node
sudo /config/bin/custom_ansible.sh localdisk_aistore
```

Or via the mgmt tool from the controller:

```bash
mgmt nodes reconfigure --nodes GPU-XXXX --action localdisk-aistore
```

Resume the node after completion:

```bash
sudo scontrol update NodeName=GPU-XXXX State=RESUME
```

Verify:

```bash
lsblk | grep nvme
# nvme0n1 should have a partition mounted at /mnt/localdisk
# nvme1n1, nvme2n1, nvme3n1 should be raw (no partitions)
```

## 2. Format NVMe Drives for AIStore

On each GPU node, format and mount the remaining drives individually:

```bash
cat > /tmp/prep_nvme_aistore.sh << 'EOF'
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
EOF
sudo bash /tmp/prep_nvme_aistore.sh
```

## 3. Install Tools

```bash
# Kind
curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
chmod +x /tmp/kind && sudo mv /tmp/kind /usr/local/bin/kind

# kubectl
curl -Lo /tmp/kubectl "https://dl.k8s.io/release/v1.32.3/bin/linux/amd64/kubectl"
chmod +x /tmp/kubectl && sudo mv /tmp/kubectl /usr/local/bin/kubectl

# Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Go (for AIS CLI)
curl -fsSL https://go.dev/dl/go1.23.6.linux-amd64.tar.gz | sudo tar -C /usr/local -xz
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh
export PATH=$PATH:/usr/local/go/bin
```

## 4. Create Kind Cluster

```bash
cat > /tmp/kind-config.yaml << 'EOF'
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
EOF
sudo kind create cluster --config /tmp/kind-config.yaml --name aistore
```

## 5. Install Cert-Manager and AIStore Operator

All kubectl/helm commands from here on require root's kubeconfig (Kind was created with sudo):

```bash
export KUBECONFIG=/root/.kube/config

# Cert-manager
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.crds.yaml
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml

# Wait for cert-manager
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=120s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=120s

# AIStore operator
kubectl create namespace ais
helm repo add ais https://nvidia.github.io/ais-k8s/charts
helm repo update
helm upgrade --install ais-operator ais/ais-operator --namespace ais

# Service account
kubectl -n ais create serviceaccount ais-sa
kubectl create clusterrolebinding ais-sa-cluster-admin \
  --clusterrole=cluster-admin --serviceaccount=ais:ais-sa

# Label worker
kubectl label node aistore-worker aistore.nvidia.com/role=proxy-target --overwrite
```

## 6. Deploy AIStore

```bash
cat > /tmp/aiscluster.yaml << 'EOF'
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
EOF
kubectl apply -f /tmp/aiscluster.yaml
```

Wait for pods:

```bash
kubectl -n ais get pods -w
# Wait until ais-proxy-0 and ais-target-0 are Running
```

## 7. Install AIS CLI and Test

Run these as root (or with sudo) since KUBECONFIG points to `/root/.kube/config`:

```bash
export GOPATH=/root/go
export PATH=$PATH:/usr/local/go/bin
mkdir -p $GOPATH/src/github.com/NVIDIA
cd $GOPATH/src/github.com/NVIDIA
git clone https://github.com/NVIDIA/aistore.git
cd aistore && make cli
cp $GOPATH/bin/ais /usr/local/bin/

# Port-forward and test
kubectl -n ais port-forward svc/ais-proxy 51080:51080 &
sleep 3
export AIS_ENDPOINT=http://localhost:51080

ais show cluster
ais create ais://test-bucket
echo "Hello from AIStore" > /tmp/test.txt
ais put /tmp/test.txt ais://test-bucket/test.txt
ais get ais://test-bucket/test.txt /tmp/test-out.txt
cat /tmp/test-out.txt
```

## 8. Run Benchmark

```bash
# Build aisloader
cd $GOPATH/src/github.com/NVIDIA/aistore && make aisloader
cp $GOPATH/bin/aisloader /usr/local/bin/

# Ensure AIS_ENDPOINT is set (from step 7)
export AIS_ENDPOINT=http://localhost:51080

# Write test (1MB objects, 64 workers, 1 min)
aisloader -bucket=ais://bench -duration=1m -numworkers=64 \
  -minsize=1MB -maxsize=1MB -pctput=100 -cleanup=false

# Read test (uses objects written above)
aisloader -bucket=ais://bench -duration=1m -numworkers=64 \
  -minsize=1MB -maxsize=1MB -pctput=0 -cleanup=false
```

---

## OKE Deployment (Production)

Steps 1-2 (NVMe split and format) are the same. Replace steps 3-8 with the following.

## 9. Deploy OKE Cluster

Use `oci-hpc-oke` Terraform stack with `create_vcn=false`, pointing to the Slurm VCN. Add `10.140.0.0/16` as a secondary CIDR to the VCN first. Pre-create subnets with DNS labels in the secondary CIDR. See the reference guide for full Terraform config.

## 10. Bootstrap GPU Nodes into OKE

On each GPU node:

```bash
# Replace docker-ce with docker.io
sudo apt-get purge -y docker-ce docker-ce-cli docker-ce-rootless-extras \
  docker-buildx-plugin docker-compose-plugin containerd.io 2>/dev/null || true
sudo apt-get autoremove -y
sudo apt-get -y update
sudo apt-get install -y docker.io
sudo systemctl enable --now docker

# Update instance metadata — save this as /tmp/update_metadata.py first:
# ---------------------------------------------------------------
# #!/usr/bin/env python3
# import json, subprocess, sys
# meta = json.loads(subprocess.check_output(
#     ["curl", "-sH", "Authorization: Bearer Oracle", "-L",
#      "http://169.254.169.254/opc/v2/instance/metadata"], text=True))
# meta.pop("compute_management", None)
# meta["oke-native-pod-networking"] = "true"
# meta["oke-max-pods"] = "32"
# meta["pod-subnets"] = sys.argv[1]
# with open("/tmp/meta.json", "w") as f:
#     json.dump(meta, f)
# instance_id = subprocess.check_output(
#     ["curl", "-sH", "Authorization: Bearer Oracle", "-L",
#      "http://169.254.169.254/opc/v2/instance/id"], text=True).strip()
# result = subprocess.run([
#     "/config/venv/Ubuntu_24.04_x86_64/oci/bin/oci", "compute", "instance", "update",
#     "--instance-id", instance_id,
#     "--metadata", "file:///tmp/meta.json",
#     "--auth", "instance_principal", "--force"
# ], capture_output=True, text=True)
# print("OK" if result.returncode == 0 else f"Error: {result.stderr[-200:]}")
# ---------------------------------------------------------------
sudo python3 /tmp/update_metadata.py <pod-subnet-ocid>

# Bootstrap into OKE
sudo oke bootstrap --apiserver-host <control-plane-ip> \
  --ca "<base64-ca>" \
  --kubelet-extra-args "--reserved-cpus=0-119 --cpu-manager-policy=static --cpu-manager-policy-options=strict-cpu-reservation=true"

# Required for pod networking
sudo iptables -P FORWARD ACCEPT
```

## 11. Pre-pull Images

```bash
sudo apt-get install -y skopeo
sudo skopeo copy --src-creds <user>:<pass> \
  docker://docker.io/aistorage/ais-init:v4.3 containers-storage:docker.io/aistorage/ais-init:v4.3
sudo skopeo copy --src-creds <user>:<pass> \
  docker://docker.io/aistorage/aisnode:v4.3 containers-storage:docker.io/aistorage/aisnode:v4.3
```

## 12. Deploy AIStore on OKE

From the OKE operator, first install cert-manager and the AIStore operator (same commands as step 5). Then:

```bash
# Label GPU nodes
kubectl label node <gpu-node-ip> aistore.nvidia.com/role=proxy-target --overwrite

# Deploy AIStore CR — note tolerations and nodeSelector (required for GPU nodes)
kubectl apply -f - << 'EOF'
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
    size: 6  # match to GPU node count (1:1 ratio)
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
    size: 6  # match to GPU node count
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
EOF

# Create NLB service
kubectl apply -f - << 'EOF'
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
EOF
```

## 13. Test and Benchmark

```bash
# Tune sysctl for benchmarks
sudo sysctl -w net.ipv4.ip_local_port_range="1024 65535"
sudo sysctl -w net.ipv4.tcp_tw_reuse=1

export AIS_ENDPOINT=http://<nlb-external-ip>:51080

# Smoke test
ais show cluster
ais create ais://test-bucket
echo "Hello from AIStore" > /tmp/test.txt
ais put /tmp/test.txt ais://test-bucket/test.txt
ais get ais://test-bucket/test.txt /tmp/test-out.txt
cat /tmp/test-out.txt

# Benchmark (use 32 workers to avoid port exhaustion)
aisloader -bucket=ais://bench -duration=1m -numworkers=32 -minsize=1MB -maxsize=1MB -pctput=100 -cleanup=false
aisloader -bucket=ais://bench -duration=1m -numworkers=32 -minsize=1MB -maxsize=1MB -pctput=0 -cleanup=false
```
