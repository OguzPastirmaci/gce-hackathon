# OKE Slurm Shape Runbooks

For a single ordered deployment path that includes Slinky Operator, HA
OpenLDAP, FSS home directories, SlurmDBD accounting, and shape-specific worker
values, start with
`guides/slurm-operator/start-here-full-oke-slurm.md`.

Use this index when you need the shape-specific details behind that guide. The
Slurm-on-OKE instructions are shape-specific because GPU topology, CPU
affinity, node architecture, and network mode differ by GPU shape.

Pick the section that matches the OKE GPU node shape and follow only that
section's manifests and values. Do not mix worker values between shapes.

| Shape | Tested worker mode | Worker architecture | GPU detection | Worker sshd |
| --- | --- | --- | --- | --- |
| `BM.GPU4.8` | SR-IOV/VF pod networking | `amd64` | `AutoDetect=nvml` with NUMA-shaped dynamic-node topology | normal pod-networked sshd |
| `BM.GPU.GB200.4` | `hostNetwork` | `arm64` | `AutoDetect=nvml` only | `Port 2222` because of hostNetwork |
| `BM.GPU.GB300.4` | `hostNetwork` | `arm64` | `AutoDetect=nvml` only | `Port 2222` because of hostNetwork |

## Shape: BM.GPU4.8

Use this section for the previous A100 generation `BM.GPU4.8` clusters.

Current tested assumptions:

- worker architecture: `amd64`;
- worker network mode: SR-IOV/VF pod networking, not `hostNetwork`;
- expected RDMA resource: `nvidia.com/sriov-rdma-vf`;
- expected GPU count: 8 GPUs per node;
- expected RDMA VF count: 16 VFs per node;
- FSS home PVC: `slurm-home`, usually bound to `fss-pv`;
- identity path: LDAP through SSSD in login, worker, and controller pods;
- worker sshd: normal pod networking; do not force port `2222` for this path;
- tested NVML topology path: SMT disabled, `Parameters=numa_node_as_socket`,
  and Slinky dynamic-node registration with `SocketsPerBoard=8`,
  `CoresPerSocket=8`, `ThreadsPerCore=1`, and `CPUs=64`.

Primary docs and manifests:

| File | Purpose |
| --- | --- |
| `docs/usage/ldap-sssd-disposable-test.md` | Disposable LDAP/SSSD/FSS/accounting validation runbook for the BM.GPU4.8 path |
| `docs/usage/ldap-sssd-ha-openldap.md` | Production HA OpenLDAP identity design; use the BM.GPU4.8 shape notes in that guide |
| `docs/usage/oke-bm-gpu4-8-fss-sssd-ha-openldap-controller-sssd-autodetect-nvml-numa-topology.overlay.yaml` | BM.GPU4.8 values overlay for the SR-IOV/FSS/SSSD/accounting path |
| `docs/usage/oke-bm-gpu4-autodetect-test-log.md` | BM.GPU4.8 `AutoDetect=nvml` investigation log |

Important result from the BM.GPU4.8 `AutoDetect=nvml` investigation:

- Plain `AutoDetect=nvml`, the `l3cache_as_socket` variants, and passing only
  `--parameters numa_node_as_socket` to `slurmd` failed GRES validation because
  GPU core affinity did not match Slurm's registered socket boundaries.
- The working BM.GPU4.8 path uses `AutoDetect=nvml` plus NUMA-shaped topology
  in the NodeSet `extraConfMap`, which Slinky passes to dynamic-node
  registration through `slurmd -Z --conf`.
- Keep BM.GPU4.8 deployment instructions separate from GB200. The GB200
  `AutoDetect=nvml` hostNetwork path does not apply to BM.GPU4.8.

Deployment order for the BM.GPU4.8 identity path:

1. Use `ldap-sssd-disposable-test.md` for the disposable LDAP validation path,
   or use `ldap-sssd-ha-openldap.md` for the HA LDAP design.
2. From the workstation, copy the BM.GPU4.8 Slurm values overlay to the
   operator node. For the tested BM.GPU4.8 cluster:

```bash
scp -o ProxyJump=ubuntu@152.67.124.58 \
  docs/usage/oke-bm-gpu4-8-fss-sssd-ha-openldap-controller-sssd-autodetect-nvml-numa-topology.overlay.yaml \
  ubuntu@10.140.0.18:/home/ubuntu/values-fresh-nvml-autodetect-numa-topology.yaml
```

3. SSH to the BM.GPU4.8 operator node:

```bash
ssh -J ubuntu@152.67.124.58 ubuntu@10.140.0.18
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

4. Verify the shape and SR-IOV prerequisites:

```bash
kubectl get nodes -l node.kubernetes.io/instance-type=BM.GPU4.8
kubectl get network-attachment-definitions -A | grep sriov-rdma-vf
kubectl get pv fss-pv
kubectl -n slurm get pvc slurm-home
kubectl -n slurm get secret mariadb-password
```

5. Use the BM.GPU4.8 values overlay from the BM.GPU4.8 runbook. Do not use the
   GB200 hostNetwork values.
6. Deploy Slurm with the BM.GPU4.8 overlay after the LDAP, FSS, and accounting
   prerequisites are in place:

```bash
helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  -n slurm \
  -f /home/ubuntu/values-fresh-nvml-autodetect-numa-topology.yaml
```

7. Keep worker SSH on normal pod networking. Do not add `Port 2222` unless you
   deliberately switch this shape to hostNetwork.
8. Validate the result with the BM.GPU4.8 test log checks:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  sinfo -N -o '%N %t %G %E'

kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  scontrol show node gpu-b4-0 | grep -E 'Sockets=|CoresPerSocket=|ThreadsPerCore=|Gres=|Parameters='
```

## Shape: BM.GPU.GB200.4

Use this section for GB200 `BM.GPU.GB200.4` clusters.

Current tested assumptions:

- worker architecture: `arm64`;
- worker network mode in the tested cluster: `hostNetwork`;
- expected GPU count: 4 GPUs per node;
- Slurm GPU detection: `AutoDetect=nvml` only;
- Slurm worker image: multi-platform `linux/amd64` plus `linux/arm64`;
- worker sshd port: `2222`, only because `hostNetwork` would otherwise
  conflict with the node's own sshd on port `22`;
- controller/login/accounting/identity pods: pinned to CPU nodes in the tested
  values;
- FSS home PVC: `slurm-home`, bound to `fss-pv`;
- identity path: HA OpenLDAP through SSSD in login, worker, and controller pods;
- accounting path: MariaDB plus SlurmDBD.

Primary docs and manifests:

| File | Purpose |
| --- | --- |
| `docs/usage/oke-gb200-ha-openldap-test-log.md` | End-to-end GB200 HA OpenLDAP, SSSD, FSS, SSH, Slurm, and accounting validation log |
| `docs/usage/oke-gb200-ha-openldap-prereqs.yaml` | Namespaces, cert-manager CA/server certs, and SSSD Secret |
| `docs/usage/oke-gb200-ha-openldap.values.yaml` | HA OpenLDAP Helm values for one writable primary and two read replicas |
| `docs/usage/oke-gb200-ha-openldap-tls-config.ldif` | OpenLDAP `cn=config` TLS fix used by this chart |
| `docs/usage/oke-gb200-ha-openldap-primary-syncprov.ldif` | Primary `mdb` `syncprov` overlay required for read-replica replication |
| `docs/usage/oke-gb200-slurm-home-pvc.yaml` | FSS-backed `/home` PVC bound to `fss-pv` |
| `docs/usage/oke-gb200-mariadb.yaml` | MariaDB CR used by SlurmDBD accounting |
| `docs/usage/oke-gb200-hostnetwork-ha-openldap-slurm.values.yaml` | Full GB200 hostNetwork Slurm values with HA LDAP/SSSD/FSS/accounting |
| `docs/usage/oke-gb200-hostnetwork-autodetect-nvml.values.yaml` | Minimal GB200 hostNetwork `AutoDetect=nvml` Slurm validation values |
| `docs/usage/oke-gb200-autodetect-nvml-test-log.md` | GB200 `AutoDetect=nvml` image build and validation log |

Deployment order for the tested GB200 path:

1. From the workstation, copy the GB200 manifests from this repo to the
   operator node, preserving the `/home/ubuntu/` paths used by the commands
   below. For the tested GB200 cluster:

```bash
scp -o ProxyJump=ubuntu@192.9.189.161 \
  docs/usage/oke-gb200-ha-openldap-prereqs.yaml \
  docs/usage/oke-gb200-ha-openldap.values.yaml \
  docs/usage/oke-gb200-ha-openldap-tls-config.ldif \
  docs/usage/oke-gb200-ha-openldap-primary-syncprov.ldif \
  docs/usage/oke-gb200-slurm-home-pvc.yaml \
  docs/usage/oke-gb200-mariadb.yaml \
  docs/usage/oke-gb200-hostnetwork-ha-openldap-slurm.values.yaml \
  ubuntu@10.140.0.20:/home/ubuntu/
```

2. SSH to the GB200 operator node:

```bash
ssh -J ubuntu@192.9.189.161 ubuntu@10.140.0.20
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

3. Verify the cluster matches the GB200 hostNetwork path:

```bash
kubectl get nodes -l node.kubernetes.io/instance-type=BM.GPU.GB200.4 -o wide
kubectl get pv fss-pv
kubectl get storageclass oci-bv
```

4. Deploy HA OpenLDAP, FSS, MariaDB, and Slurm:

```bash
helm repo add helm-openldap https://jp-gouin.github.io/helm-openldap/ || true
helm repo update helm-openldap

kubectl apply -f /home/ubuntu/oke-gb200-ha-openldap-prereqs.yaml
kubectl -n identity wait --for=condition=Ready certificate/openldap-tls --timeout=180s

helm upgrade --install openldap helm-openldap/openldap-stack-ha \
  --version 4.3.3 \
  -n identity \
  -f /home/ubuntu/oke-gb200-ha-openldap.values.yaml

for pod in openldap-0 openldap-readonly-0 openldap-readonly-1; do
  kubectl -n identity exec -i "$pod" -- \
    /opt/bitnami/openldap/bin/ldapmodify \
      -x -H ldap://127.0.0.1:1389 \
      -D cn=admin,cn=config -w configpassword \
    < /home/ubuntu/oke-gb200-ha-openldap-tls-config.ldif
done

kubectl -n identity exec -i openldap-0 -- \
  /opt/bitnami/openldap/bin/ldapadd \
    -x -H ldap://127.0.0.1:1389 \
    -D cn=admin,cn=config -w configpassword \
  < /home/ubuntu/oke-gb200-ha-openldap-primary-syncprov.ldif

CRT="$(kubectl -n identity get secret openldap-tls -o jsonpath='{.data.ca\.crt}')"
if [ -z "$CRT" ]; then
  CRT="$(kubectl -n identity get secret openldap-ca-root -o jsonpath='{.data.tls\.crt}')"
fi

cat >/tmp/openldap-ca-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openldap-ca
  namespace: slurm
type: Opaque
data:
  ca.crt: ${CRT}
EOF

kubectl apply -f /tmp/openldap-ca-secret.yaml

kubectl apply -f /home/ubuntu/oke-gb200-slurm-home-pvc.yaml

helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator || true
helm repo update mariadb-operator
helm upgrade --install mariadb-operator-crds mariadb-operator/mariadb-operator-crds \
  --namespace mariadb --create-namespace
helm upgrade --install mariadb-operator mariadb-operator/mariadb-operator \
  --namespace mariadb --create-namespace
kubectl -n mariadb rollout status deploy/mariadb-operator-webhook --timeout=180s
kubectl -n mariadb rollout status deploy/mariadb-operator-cert-controller --timeout=180s

kubectl apply -f /home/ubuntu/oke-gb200-mariadb.yaml
kubectl -n slurm wait --for=condition=Ready pod/mariadb-0 --timeout=420s

helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  -n slurm \
  -f /home/ubuntu/oke-gb200-hostnetwork-ha-openldap-slurm.values.yaml
```

Validated GB200 end state:

- Alice can SSH into `slurm-login-slinky` and lands in `/home/alice`.
- `getent passwd alice` and `id alice` work in controller, login, and worker
  pods through SSSD.
- Slurm sees node `10.140.64.164` with `gpu:4`.
- Job `6` completed as `alice` with `Account=project-a` and
  `AllocTRES=gres/gpu=1`.

## Shape: BM.GPU.GB300.4

Use this section for GB300 `BM.GPU.GB300.4` clusters.

Current tested assumptions:

- worker architecture: `arm64`;
- worker network mode in the tested cluster: `hostNetwork`;
- expected GPU count: 4 GPUs per node;
- Slurm GPU detection: `AutoDetect=nvml` only;
- no static `Boards`, `CPUs`, `SocketsPerBoard`, `CoresPerSocket`, or
  `ThreadsPerCore` values;
- no `l3cache_as_socket` or `numa_node_as_socket` parameter;
- Slurm worker image: multi-platform `linux/amd64` plus `linux/arm64`;
- current full HA/IMEX validation image:
  `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2`;
- worker sshd port: `2222`, only because `hostNetwork` would otherwise
  conflict with the node's own sshd on port `22`;
- controller/login/accounting/identity pods: pinned to CPU nodes in the tested
  values;
- FSS home PVC: `slurm-home`, bound to `fss-pv`;
- identity path: HA OpenLDAP through SSSD in login, worker, and controller pods;
- accounting path: MariaDB plus SlurmDBD;
- IMEX path: NVIDIA DRA `ComputeDomain` channel attached to the long-running
  Slinky `slurmd` pods, with Slurm using `SwitchType=switch/nvidia_imex`;
- GPU allocation path: Kubernetes still allocates 4 GPUs to each worker pod
  through `nvidia.com/gpu`, and Slurm jobs request GPUs through Slurm GRES.

Primary docs and manifests:

| File | Purpose |
| --- | --- |
| `docs/usage/oke-gb300-autodetect-nvml-test-log.md` | GB300 deployment, HA LDAP, SSSD, FSS, SSH, Slurm, accounting, and AutoDetect validation log |
| `docs/usage/oke-gb300-ha-openldap-deploy.sh` | End-to-end GB300 deploy script for HA OpenLDAP, FSS, MariaDB, Slurm, Alice bootstrap, and validation |
| `docs/usage/oke-gb300-ha-openldap-prereqs.yaml` | Namespaces, cert-manager CA/server certs, and SSSD Secret |
| `docs/usage/oke-gb300-ha-openldap.values.yaml` | HA OpenLDAP Helm values for one writable primary and two read replicas |
| `docs/usage/oke-gb300-ha-openldap-tls-config.ldif` | OpenLDAP `cn=config` TLS fix used by this chart |
| `docs/usage/oke-gb300-ha-openldap-primary-syncprov.ldif` | Primary `mdb` `syncprov` overlay required for read-replica replication |
| `docs/usage/oke-gb300-slurm-home-pvc.yaml` | FSS-backed `/home` PVC bound to `fss-pv` |
| `docs/usage/oke-gb300-mariadb.yaml` | MariaDB CR used by SlurmDBD accounting |
| `docs/usage/oke-gb300-hostnetwork-ha-openldap-slurm.values.yaml` | Full GB300 hostNetwork Slurm values with HA LDAP/SSSD/FSS/accounting |
| `docs/usage/oke-gb300-hostnetwork-autodetect-nvml.values.yaml` | Minimal GB300 hostNetwork `AutoDetect=nvml` Slurm validation values |
| `docs/usage/oke-gb300-imex-dra-computedomain.yaml` | NVIDIA DRA `ComputeDomain` used to create the shared IMEX channel |
| `docs/usage/oke-gb300-imex-dra-overlay.values.yaml` | Helm overlay that enables `switch/nvidia_imex` and attaches the IMEX DRA claim to GB300 workers |
| `docs/usage/oke-gb300-devin-nccl-demo.md` | End-to-end demo that creates LDAP user `devin`, validates SSH/FSS/accounting, and runs an NCCL Slurm job |
| `docs/usage/oke-gb300-topology-block-test.values.yaml` | Manual split-block topology overlay used to validate Slurm `BlockAsNodeRank` behavior |
| `docs/usage/oke-gb300-topology-block-test-log.md` | Manual split-block topology test log and NCCL validation notes |
| `docs/usage/oke-gb300-oci-label-topology-test.values.yaml` | OCI RDMA label-derived topology overlay using `oci.oraclecloud.com/rdma.local_block_id` |
| `docs/usage/oke-gb300-oci-label-topology-test-log.md` | OCI label topology migration/recovery notes and smoke test output |
| `docs/usage/oke-gb300-topograph-topology.md` | Optional Topograph integration notes for Slinky topology generation from DRA or OCI providers |
| `docs/usage/imex-per-job-channel-check.sbatch` | Lightweight Slurm probe for checking IMEX channel assignment across overlapping jobs |
| `docs/usage/slinky-container-images.md` | Container image inventory, including the combined NVML+NCCL worker image |

Deployment order for the tested GB300 path:

1. From the workstation, copy the GB300 files to the operator node:

```bash
scp -o ProxyJump=ubuntu@151.106.182.43 \
  docs/usage/oke-gb300-ha-openldap-prereqs.yaml \
  docs/usage/oke-gb300-ha-openldap.values.yaml \
  docs/usage/oke-gb300-ha-openldap-tls-config.ldif \
  docs/usage/oke-gb300-ha-openldap-primary-syncprov.ldif \
  docs/usage/oke-gb300-slurm-home-pvc.yaml \
  docs/usage/oke-gb300-mariadb.yaml \
  docs/usage/oke-gb300-hostnetwork-ha-openldap-slurm.values.yaml \
  docs/usage/oke-gb300-imex-dra-computedomain.yaml \
  docs/usage/oke-gb300-imex-dra-overlay.values.yaml \
  docs/usage/oke-gb300-ha-openldap-deploy.sh \
  ubuntu@10.140.0.20:/home/ubuntu/
```

2. SSH to the GB300 operator node:

```bash
ssh -J ubuntu@151.106.182.43 ubuntu@10.140.0.20
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

3. Verify the cluster matches the GB300 hostNetwork path:

```bash
kubectl get nodes -l node.kubernetes.io/instance-type=BM.GPU.GB300.4 -o wide
kubectl get pv fss-pv
kubectl get storageclass oci-bv
```

4. Run the end-to-end deployment script:

```bash
bash /home/ubuntu/oke-gb300-ha-openldap-deploy.sh
```

The script installs or refreshes the Slinky operator, deploys HA OpenLDAP,
applies the TLS and `syncprov` fixes, generates `/home/ubuntu/.ssh/alice_slurm_test`
if missing, ensures the LDAP Alice test entries exist, copies the LDAP CA into
the `slurm` namespace, binds `/home` to `fss-pv`, installs MariaDB accounting,
deploys Slurm, creates `/home/alice`, seeds `project-a` accounting, and runs a
validation snapshot.

5. If the cluster will run IMEX/NCCL jobs, apply the IMEX/DRA overlay:

```bash
kubectl apply -f /home/ubuntu/oke-gb300-imex-dra-computedomain.yaml
helm -n slurm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  --reuse-values \
  -f /home/ubuntu/oke-gb300-imex-dra-overlay.values.yaml
```

This overlay sets `SwitchType=switch/nvidia_imex` in Slurm and attaches the DRA
`imex-channel` claim to each long-running GB300 `slurmd` pod. It does not move
GPU allocation to DRA. Worker pods still request `nvidia.com/gpu: 4`, and users
still request GPUs from Slurm with options such as `--gres=gpu:4`.

6. If topology-aware placement is needed, start with the validated manual or
   OCI-label path before adding Topograph:

```text
docs/usage/oke-gb300-topology-block-test-log.md
docs/usage/oke-gb300-oci-label-topology-test-log.md
docs/usage/oke-gb300-topograph-topology.md
```

Topograph is not required for the current IMEX/DRA channel plumbing. Its value
is topology generation and refresh automation. For this repo, the current
baseline remains the no-Topograph OCI-label path:

```text
oci.oraclecloud.com/rdma.local_block_id -> Slurm topology block
topology.slinky.slurm.net/spec          -> Slinky node topology annotation
```

If a local block is too small for a job, the topology generator should also
include aggregate levels, such as `network_block_id` and `hpc_island_id`, so
larger jobs can span valid higher-level blocks instead of sitting pending while
enough total nodes exist elsewhere.

For multiple independent jobs to pack onto one GB300 worker, users must request
bounded memory or the partition should set a reasonable default memory policy.
The live config uses `SelectType=select/cons_tres` and
`SelectTypeParameters=CR_CORE_MEMORY`, so memory is consumable. With
`DefMemPerNode=UNLIMITED`, a job that omits `--mem` receives the full node
memory TRES and blocks other jobs from using that same node. The per-job IMEX
probe overlapped two jobs on one worker only after adding `--mem=16G`.

The live validation command for the Slurm-side switch setting is:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  scontrol show config | egrep '^(SwitchType|TopologyPlugin|GresTypes)'
```

Expected output:

```text
GresTypes      = gpu
SwitchType     = switch/nvidia_imex
TopologyPlugin = topology/flat
```

Validated GB300 end state:

- Alice can SSH into `slurm-login-slinky` and lands in `/home/alice`.
- `/home/alice` is backed by the `slurm-home` PVC bound to `fss-pv`.
- `getent passwd alice`, `id alice`, and `sss_ssh_authorizedkeys alice` work in
  controller, login, and worker pods through SSSD.
- Slurm sees node `10.140.79.152` with `Sockets=2`, `CoresPerSocket=72`,
  `ThreadsPerCore=1`, and `Gres=gpu:4(S:0-1)`.
- `slurmd` logs `gpu/nvml: _get_system_gpu_list_nvml: 4 GPU system device(s)
  detected`.
- Job `1` completed as `alice` with `Account=project-a` and
  `AllocTRES=gres/gpu=1` on an NVIDIA GB300 GPU.
- Job `9` completed as `alice` on 4 GB300 nodes and 16 GPUs using the deployed
  `slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2` image, `with-nccl-tests-env`, and
  `all_reduce_perf`; NCCL reported `0 OK` and average bus bandwidth
  `262.326 GB/s`.
- The live `ComputeDomain` reported all four GB300 worker nodes as `Ready`, and
  worker pod status showed an `imex-channel` DRA ResourceClaim while the
  `slurmd` container still had `nvidia.com/gpu: 4` allocated.
- Two overlapping single-GPU jobs on the same worker, each submitted with
  `--mem=16G`, saw distinct IMEX channels:
  `job 19 -> channel1`, `job 20 -> channel2`.
