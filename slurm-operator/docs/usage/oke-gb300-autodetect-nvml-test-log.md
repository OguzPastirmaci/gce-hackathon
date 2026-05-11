# OKE GB300 AutoDetect=nvml Test Log

Date: 2026-05-06

Operator host:

```bash
ssh -J ubuntu@151.106.182.43 ubuntu@10.140.0.20
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

## Shape: BM.GPU.GB300.4

This log applies only to `BM.GPU.GB300.4`.

Use the [OKE Slurm Shape Runbooks](oke-slurm-shape-runbooks.md) before applying
values. The GB300 test path is expected to follow the GB200 hostNetwork pattern:
`arm64` worker nodes, `hostNetwork`, worker sshd on `Port 2222`, and a
multi-platform Slurm worker image. Do not use these hostNetwork values as the
`BM.GPU4.8` SR-IOV/VF path.

## Cluster Discovery

Nodes:

```text
11 x BM.GPU.GB300.4      arm64  Ubuntu 24.04.4 LTS  6.14.0-1015-nvidia-64k  nvidia.com/gpu=4
3  x VM.Standard.E5.Flex  amd64  Ubuntu 24.04.4 LTS  6.17.0-1010-oracle
```

Example GPU node:

```text
10.140.66.190  Ready  BM.GPU.GB300.4  arm64  nvidia.com/gpu=4
```

GPU nodes have taint:

```text
nvidia.com/gpu=present:NoSchedule
```

Storage:

```text
oci-bv default StorageClass
fss-pv Available RWX Retain 50Gi
```

Installed before Slurm deployment:

```text
cert-manager v1.19.2
kube-prometheus-stack
dcgm-exporter
gpu-rdma-node-problem-detector
mpi-operator
```

## Image and GPU Probe

Probed the stock Slinky arm64 worker image on a GB300 node:

```bash
kubectl run -n default gb300-nvidia-probe --restart=Never \
  --image=ghcr.io/slinkyproject/slurmd:25.11-ubuntu24.04 \
  --overrides='...' \
  --command -- /bin/sh -lc \
  'uname -m; find /usr -name gpu_nvml.so -o -name gpu_nvidia.so -o -name gres_gpu.so; nvidia-smi -L; nvidia-smi topo -m; slurmd -V'
```

Result:

```text
aarch64
/usr/lib/aarch64-linux-gnu/slurm/gpu_nvidia.so
/usr/lib/aarch64-linux-gnu/slurm/gres_gpu.so
GPU 0: NVIDIA GB300
GPU 1: NVIDIA GB300
GPU 2: NVIDIA GB300
GPU 3: NVIDIA GB300
slurm 25.11.5
```

Finding: the stock arm64 `slurmd` image can run on GB300 and see GPUs, but it
does not contain `gpu_nvml.so`. Use the same multi-platform NVML/GRES image
validated on GB200 unless a GB300-specific rebuild becomes necessary:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-core-25.11.5-ubuntu24.04
```

`nvidia-smi topo -m` reports a clean two-domain CPU affinity:

```text
GPU0/GPU1: CPU Affinity 0-71,   NUMA Affinity 0
GPU2/GPU3: CPU Affinity 72-143, NUMA Affinity 1
```

This suggests the GB300 path should not need the BM.GPU4.8
`numa_node_as_socket` workaround. Start with `AutoDetect=nvml` only.

## Working Values Under Test

```text
docs/usage/manifests/oke-gb300-hostnetwork-autodetect-nvml.values.yaml
```

The values intentionally use:

- `AutoDetect=nvml` only in `gres.conf`;
- no static `Boards`, `CPUs`, `SocketsPerBoard`, `CoresPerSocket`, or
  `ThreadsPerCore`;
- no `l3cache_as_socket` or `numa_node_as_socket`;
- `hostNetwork: true`;
- worker sshd `Port 2222`;
- `slurmd -N $(KUBE_NODE_NAME)`;
- `node.kubernetes.io/instance-type: BM.GPU.GB300.4`;
- `nvidia.com/gpu: 4`.

## 2026-05-06 Pause Point: HA OpenLDAP Deployment

User requested the GB300 path with HA LDAP, not the minimal Slurm-only
deployment. I created GB300-specific copies of the GB200 HA assets:

```text
docs/usage/manifests/oke-gb300-ha-openldap-prereqs.yaml
docs/usage/manifests/oke-gb300-ha-openldap.values.yaml
docs/usage/ldif/oke-gb300-ha-openldap-tls-config.ldif
docs/usage/ldif/oke-gb300-ha-openldap-primary-syncprov.ldif
docs/usage/manifests/oke-gb300-slurm-home-pvc.yaml
docs/usage/manifests/oke-gb300-mariadb.yaml
docs/usage/manifests/oke-gb300-hostnetwork-ha-openldap-slurm.values.yaml
docs/usage/scripts/oke-gb300-ha-openldap-deploy.sh
```

The GB300 Slurm HA values keep:

- `AutoDetect=nvml` only;
- no static CPU/socket/core topology;
- no `l3cache_as_socket` or `numa_node_as_socket`;
- `hostNetwork: true`;
- worker sshd `Port 2222`;
- NodeSet `gb300`;
- node selector `node.kubernetes.io/instance-type: BM.GPU.GB300.4`;
- feature `gb300`;
- FSS home PVC `slurm-home` bound to `fss-pv`;
- HA OpenLDAP through SSSD in controller, login, and worker pods;
- MariaDB-backed Slurm accounting.

Copied the GB300 files to the operator node:

```bash
scp -o BatchMode=yes -o ProxyJump=ubuntu@151.106.182.43 \
  docs/usage/manifests/oke-gb300-ha-openldap-prereqs.yaml \
  docs/usage/manifests/oke-gb300-ha-openldap.values.yaml \
  docs/usage/ldif/oke-gb300-ha-openldap-tls-config.ldif \
  docs/usage/ldif/oke-gb300-ha-openldap-primary-syncprov.ldif \
  docs/usage/manifests/oke-gb300-slurm-home-pvc.yaml \
  docs/usage/manifests/oke-gb300-mariadb.yaml \
  docs/usage/manifests/oke-gb300-hostnetwork-ha-openldap-slurm.values.yaml \
  docs/usage/scripts/oke-gb300-ha-openldap-deploy.sh \
  ubuntu@10.140.0.20:/home/ubuntu/
```

Started the deploy script:

```bash
ssh -o BatchMode=yes -J ubuntu@151.106.182.43 ubuntu@10.140.0.20 \
  'bash /home/ubuntu/oke-gb300-ha-openldap-deploy.sh'
```

Observed progress before stopping:

```text
fss-pv Available RWX Retain 50Gi
slurm minimal release uninstalled
slurm-operator-crds revision 2 deployed
slurm-operator revision 2 deployed
identity namespace created
slurm namespace configured
openldap-root-selfsigned issuer created
openldap-ca-root certificate created
openldap-ca issuer created
openldap-tls certificate created and Ready
site-sssd-ha-ldap-conf secret created
openldap Helm release installed
openldap StatefulSet reached 1 primary pod ready
openldap-readonly StatefulSet was still waiting for replicas
```

The user asked to stop here. I killed the local SSH command after it was waiting
for the OpenLDAP read-only replicas. The Kubernetes resources already applied
remain in the cluster.

Resume by checking the live state first:

```bash
ssh -J ubuntu@151.106.182.43 ubuntu@10.140.0.20
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal

kubectl -n identity get pods -o wide
kubectl -n identity get pvc
kubectl -n identity get certificates,issuers
kubectl -n identity describe pod openldap-readonly-0
kubectl -n identity describe pod openldap-readonly-1
```

If the OpenLDAP pods are healthy, rerun the deploy script. It is written to
reuse existing resources and continue through TLS config, syncprov, CA copy,
FSS, MariaDB, Slurm, Alice home creation, accounting association, and validation:

```bash
bash /home/ubuntu/oke-gb300-ha-openldap-deploy.sh
```

## 2026-05-06 HA OpenLDAP End-To-End Result

Resumed from the pause point and found OpenLDAP healthy:

```text
openldap-0            1/1 Running  primary
openldap-readonly-0   1/1 Running  read replica
openldap-readonly-1   1/1 Running  read replica
```

All OpenLDAP PVCs were bound to `oci-bv`, and both cert-manager certificates
were ready:

```text
certificate/openldap-ca-root  Ready=True
certificate/openldap-tls      Ready=True
issuer/openldap-ca            Ready=True
issuer/openldap-root-selfsigned Ready=True
```

Reran `/home/ubuntu/oke-gb300-ha-openldap-deploy.sh`. The script completed the
OpenLDAP TLS fix, added the primary `syncprov` overlay, copied the LDAP CA into
the `slurm` namespace, bound `slurm-home` to `fss-pv`, deployed MariaDB
accounting, and deployed Slurm with:

```text
docs/usage/manifests/oke-gb300-hostnetwork-ha-openldap-slurm.values.yaml
```

The original version of the script stopped after Slurm deployment because it
waited for a non-existent Kubernetes StatefulSet named `slurm-worker-gb300`.
Slinky created a `NodeSet` named `slurm-worker-gb300` and a pod named
`slurm-worker-gb300-0`; the script now waits for the pod instead.

The OpenLDAP chart did not bootstrap the custom LDIF into the existing data
volume on this run. I generated a fresh Alice test key on the operator node and
added the base DN, OUs, Alice groups, Alice user, and the generated public key
explicitly:

```text
/home/ubuntu/.ssh/alice_slurm_test
/home/ubuntu/.ssh/alice_slurm_test.pub
```

Generated public key used in this GB300 cluster:

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINfa3UnJFuMQBwKRjNYMUDMBlLbAy6MwD5IHS9oeFN7r alice-slurm-test
```

Replication was verified on the primary and both read-only replicas:

```text
openldap-0            uid=alice uidNumber=10001 gidNumber=10001
openldap-readonly-0   uid=alice uidNumber=10001 gidNumber=10001
openldap-readonly-1   uid=alice uidNumber=10001 gidNumber=10001
```

Final Slurm pods:

```text
mariadb-0                             1/1 Running
mariadb-metrics-9df7948d5-lfk7s       1/1 Running
slurm-accounting-0                    1/1 Running
slurm-controller-0                    4/4 Running
slurm-login-slinky-6494b68698-4qtb7   1/1 Running
slurm-restapi-6cddf94b6d-vqsc8        1/1 Running
slurm-worker-gb300-0                  2/2 Running
```

SSSD/NSS resolved Alice in controller, login, and worker pods:

```text
alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINfa3UnJFuMQBwKRjNYMUDMBlLbAy6MwD5IHS9oeFN7r alice-slurm-test
```

Created Alice's FSS-backed home:

```text
drwx--x--x 3 root  root  1 May  6 03:24 /home
drwx------ 2 alice alice 0 May  6 03:24 /home/alice
```

Slurm accounting association:

```text
alice|project-a||normal
```

`AutoDetect=nvml` registered the GB300 worker without static topology:

```text
NodeName=10.140.79.152 Arch=aarch64 CoresPerSocket=72
CPUAlloc=0 CPUEfctv=144 CPUTot=144
Gres=gpu:4(S:0-1)
RealMemory=979788 Sockets=2 Boards=1
State=IDLE+DYNAMIC_NORM ThreadsPerCore=1
CfgTRES=cpu=144,mem=979788M,billing=144,gres/gpu=4
```

Worker `slurmd` log evidence:

```text
gpu/nvml: _get_system_gpu_list_nvml: 4 GPU system device(s) detected
CPUs=144 Boards=1 Sockets=2 Cores=72 Threads=1 Memory=979788
```

The reused Slurm controller state PVC still contained a stale dynamic node from
the earlier minimal test (`10.140.82.65`). I deleted it with `scontrol delete`.
After cleanup, `sinfo` showed only the current GB300 worker. The node still
appears once per partition (`gb300` and `all`), which is expected with
`sinfo -N`.

SSH into the login service worked:

```text
LOGIN_IP=151.106.163.175
alice
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
/home/alice
drwx--x--x 3 root  root  1 May  6 03:24 /home
drwx------ 3 alice alice 1 May  6 03:25 /home/alice
ls: cannot access '/home/bob': No such file or directory
```

Submitted a GPU job as Alice through SSH:

```bash
sbatch --parsable -N1 -n1 --gres=gpu:1 \
  --output=/home/alice/ha-ldap-gb300-%j.out \
  --wrap="whoami; id; hostname; nvidia-smi -L"
```

Job `1` completed with accounting:

```text
JobID|User|Account|State|ExitCode|AllocTRES|NodeList
1|alice|project-a|COMPLETED|0:0|billing=1,cpu=1,gres/gpu=1,mem=979788M,node=1|10.140.79.152
1.batch||project-a|COMPLETED|0:0|cpu=1,gres/gpu=1,mem=979788M,node=1|10.140.79.152
1.extern||project-a|COMPLETED|0:0|billing=1,cpu=1,gres/gpu=1,mem=979788M,node=1|10.140.79.152
```

Job output:

```text
alice
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
instance20260506003155
GPU 0: NVIDIA GB300 (UUID: GPU-86908f3e-7523-069a-01c5-a8d5bf837b90)
```

## 2026-05-06 NCCL RDMA/SPCX Rail Debugging

The initial two-node NCCL MPIJob failed when all four RDMA VF rails were
enabled:

```text
NCCL_IB_HCA=rdma_vf_rail0,rdma_vf_rail1,rdma_vf_rail2,rdma_vf_rail3
NCCL_IB_GID_INDEX=3
NCCL_NET=IB
NCCL_NET_PLUGIN=spcx
```

As a control, `NCCL_NET=Socket` with exact interface selection
`NCCL_SOCKET_IFNAME==eth0` completed across two GB300 workers. The exact match
matters: `NCCL_SOCKET_IFNAME=eth0` matched `eth0.*` and other interfaces, which
caused NCCL to try unreachable secondary addresses.

Created privileged hostNetwork debug pods on workers `10.140.85.5` and
`10.140.80.145` with `/dev/infiniband` mounted. Both pods saw the expected RDMA
devices and active `rdma_vf_rail*` netdevs. The image contained the Spectrum-X
and RDMA/SHARP NCCL net plugins under `/opt/hpcx`.

Basic verbs testing with `ibv_rc_pingpong` showed the problem is below NCCL:

```text
rdma_vf_rail0 gid3: pass
rdma_vf_rail1 gid3: fail, transport retry counter exceeded
rdma_vf_rail2 gid3: pass
rdma_vf_rail3 gid3: fail, transport retry counter exceeded
```

Additional GID checks on the failing rails:

```text
rdma_vf_rail1 gid1/gid2/gid3/gid5: fail
rdma_vf_rail3 gid1/gid2/gid3: fail
rdma_vf_rail3 gid5: pass, but very slow in the quick ping-pong test
```

This indicates rail-level RDMA reachability, GID/address selection, or fabric
health issues on `rdma_vf_rail1` and `rdma_vf_rail3`. It is not a generic NCCL,
MPI, GPU, pod privilege, or `/dev/infiniband` mount problem because the same
pods, image, nodes, and GID index worked on `rdma_vf_rail0` and
`rdma_vf_rail2`.

Restricting NCCL to the healthy rails completed a two-worker/eight-GPU RDMA
SPCX run:

```text
NCCL_IB_HCA=rdma_vf_rail0,rdma_vf_rail2
NCCL_IB_GID_INDEX=3
NCCL_NET=IB
NCCL_NET_PLUGIN=spcx
```

Result:

```text
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 194.961
# Collective test concluded: all_reduce_perf
```

A 16-worker test was then started with the same restricted RDMA/SPCX settings.
At the first status check the workload was admitted, the launcher was running,
and 16 workers were scheduled across GB300 nodes, with several pods still
pulling or creating the NCCL test image.

Checked GID index 3 across the 16-worker job on all four `rdma_vf_rail*`
interfaces per worker. Correct was defined as:

- `gid3` exists;
- `gid3` type is `RoCE v2`;
- `gid3` netdev matches the rail, for example `rdma_vf_rail2`;
- `gid3` is not all zeros.

Result:

```text
total VF rail gid3 entries checked: 64
passing: 63
failing: 1
```

The failing entry was:

```text
pod:  nccl-test-worker-4
node: 10.140.82.207
rail: rdma_vf_rail2
gid3_type=MISSING
gid3_ndev=MISSING
gid3=0000:0000:0000:0000:0000:0000:0000:0000
```

This means the restricted `rdma_vf_rail0,rdma_vf_rail2` NCCL setting is valid
for the two-worker test nodes, but is not universally valid across the larger
16-worker placement because at least one selected worker has no usable GID index
3 for `rdma_vf_rail2`.

Deleted the NCCL MPIJob and cleaned leftover NCCL pods, workloads, and
resource claims. Then rebooted all nodes labeled
`node.kubernetes.io/instance-type=BM.GPU.GB300.4` through OCI instance
principal auth with:

```bash
oci compute instance action --instance-id "$INSTANCE_OCID" --action SOFTRESET
```

Reboot result:

```text
GB300 instances: 21 RUNNING
GB300 Kubernetes nodes: 21 Ready
NCCL leftovers in default namespace: none
```

After reboot, created a temporary privileged hostNetwork DaemonSet on all GB300
nodes and rechecked GID index 3 for every `rdma_vf_rail*` interface. Correct was
defined as `RoCE v2`, matching `rdma_vf_railN` netdev, and non-zero GID value.

Result:

```text
total VF rail gid3 entries checked: 84
passing: 84
failing: 0
```

The temporary `rdma-gid-check` DaemonSet was deleted after the scan.

Reran the 16-worker NCCL MPIJob with all four RDMA VF rails enabled:

```text
Worker replicas: 16
Ranks: 64
NCCL_IB_HCA=rdma_vf_rail0,rdma_vf_rail1,rdma_vf_rail2,rdma_vf_rail3
NCCL_IB_GID_INDEX=3
NCCL_NET=IB
NCCL_NET_PLUGIN=spcx
```

The first post-reboot attempt failed before NCCL started because worker pods hit
`CreateContainerError`:

```text
CDI device injection failed: failed to stat CDI host device "/dev/infiniband/uverbs10": no such file or directory
```

Deleted the failed MPIJob and restarted the NVIDIA components that publish or
consume CDI state:

```bash
kubectl -n gpu-operator rollout restart daemonset/nvidia-device-plugin-daemonset
kubectl -n nvidia-dra-driver-gpu rollout restart daemonset/nvidia-dra-driver-gpu-kubelet-plugin
```

After both DaemonSets rolled out, reapplied `/home/ubuntu/nccl.yaml`. The
16-worker/all-four-rail NCCL run completed successfully:

```text
MPIJobSucceeded
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 343.389
# Collective test concluded: all_reduce_perf
```

After the successful run, reduced NCCL logging in `/home/ubuntu/nccl.yaml`:

```text
NCCL_DEBUG=WARN
```

Removed `NCCL_DEBUG_SUBSYS=INIT,NET,GRAPH` so WARN-level messages are not
restricted to only those subsystems. Kept `NCCL_SOCKET_IFNAME==eth0` as an
exact interface match because the earlier `NCCL_SOCKET_IFNAME=eth0` form also
matched `eth0.*` and other secondary addresses during socket-path debugging.

Reran the current `/home/ubuntu/nccl.yaml` after the WARN-level logging change.
The manifest was deleted and reapplied rather than patched in place:

```bash
kubectl delete -f /home/ubuntu/nccl.yaml --ignore-not-found
kubectl apply -f /home/ubuntu/nccl.yaml
kubectl -n default wait --for=condition=Succeeded mpijob/nccl-test --timeout=20m
```

Run shape and NCCL settings:

```text
Worker replicas: 16
Ranks: 64
NCCL_DEBUG=WARN
NCCL_SOCKET_IFNAME==eth0
NCCL_IB_HCA=rdma_vf_rail0,rdma_vf_rail1,rdma_vf_rail2,rdma_vf_rail3
NCCL_IB_GID_INDEX=3
NCCL_NET=IB
NCCL_NET_PLUGIN=spcx
```

The rerun completed successfully:

```text
MPIJobSucceeded
NCCL version 2.29.3+cuda13.1
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 331.959
# Collective test concluded: all_reduce_perf
```

The recent event tail for this rerun showed normal scheduling, container start,
job completion, and worker shutdown events. It did not show the earlier CDI
device injection failure.

Changed the NCCL test to a smaller 4-node run and disabled MNNVL:

```text
Worker replicas: 4
Ranks: 16
NCCL_MNNVL_ENABLE=0
```

Updated the test command in `/home/ubuntu/nccl.yaml`:

```bash
/workspace/nccl-tests/build/all_reduce_perf -b 8M -e 8G -f 2 -g 1 -n 30
```

Deleted and reapplied the manifest:

```bash
kubectl delete -f /home/ubuntu/nccl.yaml --ignore-not-found
kubectl apply -f /home/ubuntu/nccl.yaml
kubectl -n default wait --for=condition=Succeeded mpijob/nccl-test --timeout=15m
```

The 4-node rerun completed successfully:

```text
MPIJobSucceeded
NCCL version 2.29.3+cuda13.1
# nThread 1 nGpus 1 minBytes 8388608 maxBytes 8589934592 step: 2(factor) warmup iters: 1 iters: 30 agg iters: 1 validation: 1 graph: 0
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 274.156
# Collective test concluded: all_reduce_perf
```

The largest tested size, 8 GiB, completed with no wrong results:

```text
8589934592 bytes: out-of-place busbw 373.41 GB/s, in-place busbw 373.46 GB/s, wrong 0/0
```

The Kubernetes event tail still showed `RdmaLinkHasIssues` warnings from the
GPU/RDMA health checks on several nodes, including one node used by this 4-node
run. The NCCL MPIJob still completed successfully with `0 OK` validation.

Changed the NCCL test back to 16 nodes and re-enabled MNNVL:

```text
Worker replicas: 16
Ranks: 64
NCCL_MNNVL_ENABLE=1
```

Kept the longer test command:

```bash
/workspace/nccl-tests/build/all_reduce_perf -b 8M -e 8G -f 2 -g 1 -n 30
```

Deleted and reapplied the manifest:

```bash
kubectl delete -f /home/ubuntu/nccl.yaml --ignore-not-found
kubectl apply -f /home/ubuntu/nccl.yaml
kubectl -n default wait --for=condition=Succeeded mpijob/nccl-test --timeout=20m
```

The 16-node MNNVL-enabled rerun completed successfully:

```text
MPIJobSucceeded
NCCL version 2.29.3+cuda13.1
# nThread 1 nGpus 1 minBytes 8388608 maxBytes 8589934592 step: 2(factor) warmup iters: 1 iters: 30 agg iters: 1 validation: 1 graph: 0
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 412.4
# Collective test concluded: all_reduce_perf
```

Largest tested size:

```text
8589934592 bytes: out-of-place busbw 630.09 GB/s, in-place busbw 631.10 GB/s, wrong 0/0
```

The recent event tail for this run showed normal pod startup, MPIJob running,
MPIJob completion, and worker shutdown events. It did not show the RDMA
healthcheck warnings that appeared in the immediately previous 4-node event
tail.

## Slinky IMEX/DRA Test - 2026-05-06

Goal: test the NVIDIA DRA ComputeDomain IMEX path with Slinky on
`BM.GPU.GB300.4`, using the DRA driver's all-channel mode and Slurm's
`switch/nvidia_imex` plugin.

Initial cluster state:

```text
Slurm Helm release: slurm-1.1.0, app 25.11
GPU Operator Helm release: gpu-operator-v26.3.1
NVIDIA DRA driver Helm release: nvidia-dra-driver-gpu-25.12.0
ComputeDomain CRD allocationMode enum: All, Single
```

The active Slurm images already include the IMEX switch plugin:

```text
Controller: slurm 25.11.4, /usr/lib/x86_64-linux-gnu/slurm/switch_nvidia_imex.so
Worker:     slurm 25.11.5, /usr/lib/aarch64-linux-gnu/slurm/switch_nvidia_imex.so
```

Before the DRA overlay, Slurm reported:

```text
SwitchType=(null)
TopologyPlugin=topology/flat
```

The initial GB300 worker pod saw only the default IMEX channel:

```text
/dev/nvidia-caps-imex-channels/channel0
```

Created separate manifests:

- `docs/usage/manifests/oke-gb300-imex-dra-computedomain.yaml`
- `docs/usage/manifests/oke-gb300-imex-dra-overlay.values.yaml`

The packaged `ghcr.io/slinkyproject/charts/slurm:1.1.0` chart did not render
the local chart's `extraObjects` helper, so the ComputeDomain is applied as a
separate manifest for this test. The overlay:

- adds `SwitchType=switch/nvidia_imex`
- attaches the generated `ResourceClaimTemplate/slurm-gb300-imex-channel` to
  the GB300 NodeSet pod through `podSpec.resourceClaims`
- attaches the same claim to the `slurmd` container through `resources.claims`
- scales the GB300 NodeSet to 4 worker pods for the first multi-node Slinky test

The separate ComputeDomain manifest creates
`ComputeDomain/slurm-gb300-imex-compute-domain` with
`spec.channel.allocationMode: All`.

Applied the IMEX/DRA overlay from the operator node:

```bash
kubectl apply -f /home/ubuntu/oke-gb300-imex-dra-computedomain.yaml
helm -n slurm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  --reuse-values \
  -f /home/ubuntu/oke-gb300-imex-dra-overlay.values.yaml
```

After rollout, Slurm reported:

```text
SwitchType= switch/nvidia_imex
TopologyPlugin=topology/flat
4 x slurm-worker-gb300 pods Ready
4 x ResourceClaims allocated,reserved
ComputeDomain/slurm-gb300-imex-compute-domain Ready
```

The long-running `slurmd` containers showed an empty channel directory:

```bash
find /dev/nvidia-caps-imex-channels -maxdepth 1 -type c | wc -l
```

```text
0
```

This initially looked like failed DRA injection, but comparison probes proved
that DRA and CDI were working:

- Ubuntu probe with the IMEX claim saw `2048` channel devices.
- Slinky worker image probe with GPU request, privileged mode, and hostNetwork
  saw `2048` channel devices.
- Slinky-like probe with the worker mounts and restartable logfile sidecar saw
  `2048` channel devices.
- Probe with `restartPolicy: Always` saw `2048` channel devices.
- Probe with host ports declared saw `2048` channel devices.
- Host-side CDI specs for the real worker claim contained the expected 2048
  `nvidia-caps-imex-channels` device entries.

The key finding is that `switch/nvidia_imex` does not leave all IMEX channel
devices visible in the idle `slurmd` process. It exposes the job channel during
the Slurm job step. Validated from the login pod as Alice:

```bash
kubectl -n slurm exec "$LOGIN_POD" -- runuser -u alice -- \
  srun -N2 -n2 --gres=gpu:1 bash -lc \
  'echo NODE=$(hostname -f); printf channels=; \
   find /dev/nvidia-caps-imex-channels -maxdepth 1 -type c 2>/dev/null | wc -l; \
   ls /dev/nvidia-caps-imex-channels 2>/dev/null | head -5'
```

Result:

```text
NODE=instance20260506003208
channels=1
channel1
NODE=instance20260506002104
channels=1
channel1
```

Interpretation: the no-Topograph path works for IMEX channel plumbing:

1. NVIDIA DRA `ComputeDomain` creates the channel ResourceClaimTemplate.
2. Slinky worker pods consume that claim.
3. Slurm uses `SwitchType=switch/nvidia_imex`.
4. Idle `slurmd` may show zero channel devices.
5. A running Slurm job step receives the channel device.

Topograph is not required for this IMEX/DRA function. Topograph's Slinky engine
and DRA provider are a separate topology-generation path: they read
`nvidia.com/gpu.clique` labels and write Slurm `topology.conf` block topology
to a ConfigMap. That may be useful later for topology-aware placement, but it
is not required for exposing IMEX channels to Slurm jobs.

Cleanup performed:

```text
Deleted all temporary IMEX diagnostic pods.
Kept the Slinky IMEX/DRA overlay running.
Current non-system IMEX ResourceClaims are only the four slurm-worker-gb300 claims.
```

## Slurm NCCL Test With IMEX/DRA - 2026-05-06

Goal: run `nccl-tests` through Slurm using the no-Topograph IMEX/DRA path:

- Slinky worker pods consume the NVIDIA DRA `ComputeDomain` channel claim.
- Slurm is configured with `SwitchType=switch/nvidia_imex`.
- NCCL runs from a normal Alice `sbatch` job on the Slinky login pod.

Current live Slurm worker image:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-core-25.11.5-ubuntu24.04
```

The worker image has CUDA driver libraries plus OpenMPI/PMIx, but it does not
include `all_reduce_perf`, NCCL runtime libraries, or the Spectrum-X NCCL net
plugin. The known-good Kubernetes MPIJob image on this cluster was used as the
source for the test payload:

```text
iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.1.1-ubuntu-24.04-nccl-2.29.3-020926.1
```

Created a temporary staging pod in the `slurm` namespace that mounted the
`slurm-home` FSS PVC:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nccl-stage
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/arch: arm64
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: nccl
    image: iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.1.1-ubuntu-24.04-nccl-2.29.3-020926.1
    command: ["bash", "-lc", "sleep 3600"]
    volumeMounts:
    - name: home
      mountPath: /stage-home
  volumes:
  - name: home
    persistentVolumeClaim:
      claimName: slurm-home
```

Staged the arm64 NCCL test payload into Alice's FSS home:

```bash
rm -rf /stage-home/alice/nccl-tests
mkdir -p /stage-home/alice/nccl-tests/bin \
  /stage-home/alice/nccl-tests/lib \
  /stage-home/alice/nccl-tests/hpcx
cp -a /workspace/nccl-tests/build/all_reduce_perf \
  /stage-home/alice/nccl-tests/bin/
cp -a /usr/lib/aarch64-linux-gnu/libnccl.so* \
  /stage-home/alice/nccl-tests/lib/
cp -a /usr/local/cuda-13.1/targets/sbsa-linux/lib/libcudart.so* \
  /stage-home/alice/nccl-tests/lib/
cp -a /opt/hpcx/ompi /stage-home/alice/nccl-tests/hpcx/
cp -a /opt/hpcx/ucx /stage-home/alice/nccl-tests/hpcx/
cp -a /opt/hpcx/nccl_spectrum-x_plugin /stage-home/alice/nccl-tests/hpcx/
cp -a /opt/hpcx/nccl_rdma_sharp_plugin /stage-home/alice/nccl-tests/hpcx/
chown -R 10001:10001 /stage-home/alice/nccl-tests
```

Validation from `slurm-worker-gb300-0` showed:

```text
/home/alice/nccl-tests/bin/all_reduce_perf resolves:
  libcudart.so.13 => /home/alice/nccl-tests/lib/libcudart.so.13
  libmpi.so.40 => /home/alice/nccl-tests/hpcx/ompi/lib/libmpi.so.40
  libnccl.so.2 => /home/alice/nccl-tests/lib/libnccl.so.2

/home/alice/nccl-tests/hpcx/nccl_spectrum-x_plugin/lib/libnccl-net.so resolves:
  libibverbs.so.1 => /lib/aarch64-linux-gnu/libibverbs.so.1
```

This keeps the low-level verbs stack from the Slurm worker image while staging
the NCCL test, NCCL runtime, HPCX OpenMPI, HPCX UCX, and NCCL net plugins in
FSS.

The first Slurm job used `--gpus-per-task=1` and failed. Each task saw only one
GPU:

```text
cuda=0
imex_channels=1
Invalid number of GPUs: 4 requested but only 1 were found.
```

`nccl-tests` expects each process on a node to see the node-level GPU allocation
and then picks a GPU by local rank. The corrected Slurm job requests GPUs at
the node level:

```bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=4
#SBATCH --gres=gpu:4
#SBATCH --cpus-per-task=16
```

Successful job script:

```bash
#!/bin/bash
#SBATCH --job-name=nccl-imex-gb300
#SBATCH --partition=gb300
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=4
#SBATCH --gres=gpu:4
#SBATCH --cpus-per-task=16
#SBATCH --time=00:20:00
#SBATCH --output=/home/alice/nccl-imex-gb300-%j.out
#SBATCH --error=/home/alice/nccl-imex-gb300-%j.err

set -euxo pipefail

export NCCL_TEST_HOME=/home/alice/nccl-tests
export PATH=$NCCL_TEST_HOME/hpcx/ompi/bin:$PATH
export LD_LIBRARY_PATH=$NCCL_TEST_HOME/lib:$NCCL_TEST_HOME/hpcx/ucx/lib:$NCCL_TEST_HOME/hpcx/ompi/lib:$NCCL_TEST_HOME/hpcx/nccl_spectrum-x_plugin/lib:${LD_LIBRARY_PATH:-}
export OPAL_PREFIX=$NCCL_TEST_HOME/hpcx/ompi

export OMPI_MCA_pml=ob1
export OMPI_MCA_btl=tcp,self
export OMPI_MCA_btl_tcp_if_include=eth0
export OMPI_MCA_oob_tcp_if_include=eth0
export OMPI_MCA_coll=^ucc

export RX_QUEUE_LEN=8192
export IB_RX_QUEUE_LEN=8192
export HCOLL_ENABLE_MCAST_ALL=0
export coll_hcoll_enable=0

export NCCL_DEBUG=WARN
export NCCL_TOPO_DUMP_FILE="/home/alice/nccl-topo-${SLURM_JOB_ID}-$(date +%F-%H%M%S).txt"
export NCCL_SOCKET_IFNAME=eth0
export NCCL_IB_HCA=rdma_vf_rail0,rdma_vf_rail1,rdma_vf_rail2,rdma_vf_rail3
export NCCL_IB_GID_INDEX=3
export NCCL_IB_TIMEOUT=16
export NCCL_IB_RETRY_CNT=7
export NCCL_IB_SL=0
export NCCL_IB_TC=96
export NCCL_IB_ADAPTIVE_ROUTING=1
export NCCL_IB_QPS_PER_CONNECTION=16
export NCCL_NET_GDR_C2C=1
export NCCL_NET=IB
export NCCL_NET_PLUGIN=spcx
export NCCL_ASYNC_ERROR_HANDLING=1
export NCCL_NVLS_ENABLE=0
export NCCL_MNNVL_ENABLE=1
export NCCL_WORK_FIFO_BYTES=0
export NCCL_CUMEM_ENABLE=1
export NCCL_IGNORE_CPU_AFFINITY=1
export NCCL_MIN_CTAS=16

srun --mpi=pmix -l bash -lc 'echo node=$(hostname -f) rank=${SLURM_PROCID} local=${SLURM_LOCALID} cuda=${CUDA_VISIBLE_DEVICES:-unset}; printf visible_gpu_count=; nvidia-smi -L | wc -l; printf imex_channels=; find /dev/nvidia-caps-imex-channels -maxdepth 1 -type c 2>/dev/null | wc -l; ls /dev/nvidia-caps-imex-channels 2>/dev/null | head -5'

srun --mpi=pmix \
  /home/alice/nccl-tests/bin/all_reduce_perf -b 8M -e 8G -f 2 -g 1 -n 30
```

Submitted as Alice from the Slinky login pod:

```bash
sbatch --wait /home/alice/nccl-imex-slurm-gb300.sbatch
```

Result:

```text
Submitted batch job 5
SBATCH_RC=0
```

Slurm allocated all four GB300 worker pods and all 16 GPUs:

```text
JobId=5 JobName=nccl-imex-gb300
JobState=COMPLETED
NumNodes=4 NumTasks=16
ReqTRES=cpu=256,mem=3919152M,node=4,billing=256,gres/gpu=16
AllocTRES=cpu=256,mem=3919152M,node=4,billing=256,gres/gpu=16
TresPerNode=gres/gpu:4
```

Accounting also recorded the user, account, GPU TRES, and completed job steps:

```text
5|nccl-imex-gb300|alice|project-a|COMPLETED|0:0|billing=256,cpu=256,gres/gpu=16,mem=3919152M,node=4
5.1|all_reduce_perf||project-a|COMPLETED|0:0|cpu=256,gres/gpu=16,mem=3919152M,node=4
```

Each rank saw all four node GPUs and one job-step IMEX channel:

```text
rank=0 local=0 cuda=0,1,2,3
rank=1 local=1 cuda=0,1,2,3
rank=2 local=2 cuda=0,1,2,3
rank=3 local=3 cuda=0,1,2,3
visible_gpu_count=4
imex_channels=1
channel1
```

NCCL used all 16 GB300 GPUs:

```text
# Rank  0 ... instance20260506003208 device 0 NVIDIA GB300
# Rank  1 ... instance20260506003208 device 1 NVIDIA GB300
# Rank  2 ... instance20260506003208 device 2 NVIDIA GB300
# Rank  3 ... instance20260506003208 device 3 NVIDIA GB300
...
# Rank 15 ... instance20260506002108 device 3 NVIDIA GB300
NCCL version 2.29.3+cuda13.1
```

Final `all_reduce_perf` result:

```text
  8589934592    2147483648     float     sum      -1  44750.4  191.95  359.91       0  44710.5  192.12  360.23       0
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 249.085
# Collective test concluded: all_reduce_perf
```

Conclusion: the no-Topograph Slinky IMEX/DRA path can run NCCL from a normal
Slurm job on the GB300 cluster. The important Slurm-specific detail is to
allocate GPUs per node (`--gres=gpu:4`) instead of per task, because this
`nccl-tests` build chooses the local GPU itself.

## Combined NVML + NCCL Slurm Worker Image - 2026-05-06

Created a new multi-platform worker image so NCCL tests do not need to be
staged into FSS:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-25.11.5-ubuntu24.04
```

Dockerfile:

```text
images/slurmd-nvml-nccl/Dockerfile
```

Design:

- base image:
  `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-core-25.11.5-ubuntu24.04`
- NCCL/HPCX payload source:
  `iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.1.1-ubuntu-24.04-nccl-2.29.3-020926.1`
- copies the validated `nccl-tests` binaries, NCCL runtime, CUDA runtime,
  HPCX OpenMPI, HPCX UCX, and Spectrum-X NCCL net plugin into the Slurm worker
  image
- keeps Slurm's NVML AutoDetect plugins from the working `slurmd-nvml-core`
  image

Build command used on `image-builder`:

```bash
docker buildx build \
  --builder multiarch-builder \
  --platform linux/amd64,linux/arm64 \
  -t iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-25.11.5-ubuntu24.04 \
  --push /home/ubuntu/slurmd-nvml-nccl
```

Pushed manifest:

```text
sha256:648d59fdbc24fdaf2a6d71b12cbe3bdc138da83d28133002d60be6f7c8f6ee9a
linux/amd64  sha256:de61ff6175eff72651a33d5abc21a1b7845db76a100fbcdb7ebadab5c805c7cf
linux/arm64  sha256:501ad65ea0b9038edd89653d5c810035c98f5511caf6efa50a252d50ec981501
```

Build-time validation checked both platforms for:

```text
/opt/nccl-tests/bin/all_reduce_perf
/opt/nccl-tests/lib/libnccl.so.2
/opt/hpcx/ompi/lib/libmpi.so.40
/opt/hpcx/nccl_spectrum-x_plugin/lib/libnccl-net.so
/usr/lib/<multiarch>/slurm/gpu_nvml.so
/usr/lib/<multiarch>/slurm/gres_gpu.so
```

An amd64 runtime smoke test on `image-builder` confirmed:

```text
/opt/nccl-tests/bin/all_reduce_perf
libcudart.so.13 => /opt/nccl-tests/lib/libcudart.so.13
libmpi.so.40 => /opt/hpcx/ompi/lib/libmpi.so.40
libnccl.so.2 => /opt/nccl-tests/lib/libnccl.so.2
```

The arm64 image was validated during the build. A direct `docker run
--platform linux/arm64` smoke test on `image-builder` failed with
`exec format error` because that Docker daemon does not have arm64 binfmt
enabled for direct runtime execution.

## Combined NVML + NCCL Worker Image Deployment - 2026-05-06

The first combined image was deployed successfully, but a PMIx/NCCL smoke job
hung because the image exported HPCX/OpenMPI variables globally. That caused
generic Slurm-launched shell steps to inherit the HPCX MPI environment when they
did not need it.

I rebuilt the image as:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2
sha256:eee6dd3d685ff80fe4918f36fe5077fe29403a64bed45435304891362e3dd973
```

The `-r2` image keeps only this global image environment:

```text
NCCL_TEST_HOME=/opt/nccl-tests
PATH=/opt/nccl-tests/bin:${PATH}
```

NCCL jobs opt into the NCCL/HPCX runtime with:

```bash
with-nccl-tests-env /opt/nccl-tests/bin/all_reduce_perf ...
```

Rolled the GB300 NodeSet to the `-r2` image with Helm:

```bash
helm -n slurm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  --reuse-values \
  --set nodesets.gb300.slurmd.image.repository=iad.ocir.io/idxzjcdglx2s/slinky \
  --set nodesets.gb300.slurmd.image.tag=slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2
```

All four worker pods rolled and became ready:

```text
slurm-worker-gb300-0  2/2 Running
slurm-worker-gb300-1  2/2 Running
slurm-worker-gb300-2  2/2 Running
slurm-worker-gb300-3  2/2 Running
```

Worker-local runtime check on arm64 confirmed:

```text
NCCL_TEST_HOME=/opt/nccl-tests
/opt/nccl-tests/bin/all_reduce_perf
libcudart.so.13 => /opt/nccl-tests/lib/libcudart.so.13
libmpi.so.40 => /opt/hpcx/ompi/lib/libmpi.so.40
libnccl.so.2 => /opt/nccl-tests/lib/libnccl.so.2
```

A generic PMIx launch smoke test completed on all four nodes. Each rank found
`all_reduce_perf` and saw one IMEX channel:

```text
rank=0 node=instance20260506003204 imex_channels=1
rank=1 node=instance20260506003159 imex_channels=1
rank=2 node=instance20260506003155 imex_channels=1
rank=3 node=instance20260506003207 imex_channels=1
```

The first full NCCL run with `with-nccl-tests-env` failed because HPCX OpenMPI
defaulted to UCX PML and tried to bind to RDMA rail IPv6 addresses that were not
available inside the Slurm worker context:

```text
UCX ERROR bind(... rdma_vf_rail0) failed: Cannot assign requested address
pml_ucx.c:314 Error: Failed to create UCP worker
```

The fix is to use the same OpenMPI transport settings from the earlier
successful staged NCCL job:

```bash
export OMPI_MCA_pml=ob1
export OMPI_MCA_btl=tcp,self
export OMPI_MCA_btl_tcp_if_include=eth0
export OMPI_MCA_oob_tcp_if_include=eth0
export OMPI_MCA_coll=^ucc
export RX_QUEUE_LEN=8192
export IB_RX_QUEUE_LEN=8192
export HCOLL_ENABLE_MCAST_ALL=0
export coll_hcoll_enable=0
export NCCL_TOPO_DUMP_FILE="/home/alice/nccl-topo-${SLURM_JOB_ID}-$(date +%F-%H%M%S).txt"
```

Validated the deployed `-r2` image with an Alice Slurm job:

```bash
#SBATCH --partition=gb300
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=4
#SBATCH --gres=gpu:4
#SBATCH --cpus-per-task=16

srun --mpi=pmix with-nccl-tests-env \
  /opt/nccl-tests/bin/all_reduce_perf \
  -b 8M -e 8G -f 2 -g 1 -n 30
```

Accounting result:

```text
JobID|User|Account|State|ExitCode|Elapsed|NodeList
9|alice|project-a|COMPLETED|0:0|00:00:09|10.140.88.115,10.140.71.103,10.140.79.152,10.140.93.120
9.1||project-a|COMPLETED|0:0|00:00:08|10.140.88.115,10.140.71.103,10.140.79.152,10.140.93.120
```

Each of the 16 ranks saw all four local GPUs and one IMEX channel:

```text
rank=0  cuda=0,1,2,3 imex=1
rank=1  cuda=0,1,2,3 imex=1
...
rank=15 cuda=0,1,2,3 imex=1
```

NCCL result:

```text
NCCL version 2.29.3+cuda13.1
     8388608       2097152     float     sum      -1   101.47   82.67  155.01       0    95.84   87.53  164.12       0
    16777216       4194304     float     sum      -1   159.77  105.01  196.89       0   157.50  106.52  199.73       0
    33554432       8388608     float     sum      -1   154.27  217.50  407.81       0   146.72  228.70  428.82       0
    67108864      16777216     float     sum      -1   465.43  144.19  270.35       0   456.11  147.13  275.87       0
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 262.326
# Collective test concluded: all_reduce_perf
```

## Per-Job IMEX Channel Probe - 2026-05-06

The current production-style IMEX setup keeps the DRA `imex-channel`
ResourceClaim on each long-running Slinky `slurmd` pod. I also tested whether
Slurm's `switch/nvidia_imex` can expose different IMEX channels to overlapping
jobs, as described in the NVIDIA DRA driver issue around per-job IMEX channel
selection.

Added a lightweight probe script:

```text
docs/usage/jobs/imex-per-job-channel-check.sbatch
```

The script prints the visible IMEX channel device from inside a Slurm job:

```bash
find /dev/nvidia-caps-imex-channels -maxdepth 1 -type c -exec basename {} \; | sort
```

First attempt: two jobs pinned to the same worker without an explicit memory
request did not overlap. The first job ran and the second stayed pending for
resources. The reason is the live Slurm memory policy:

```text
SelectType              = select/cons_tres
SelectTypeParameters    = CR_CORE_MEMORY
DefMemPerNode           = UNLIMITED
MaxMemPerNode           = UNLIMITED
```

With `CR_CORE_MEMORY`, memory is consumable. Because the jobs did not specify
`--mem`, Slurm allocated the full node memory to the first job:

```text
15|imex-channel-check|alice|project-a|COMPLETED|0:0|billing=4,cpu=4,gres/gpu=1,mem=979788M,node=1|10.140.79.152
16|imex-channel-check|alice|project-a|CANCELLED by 401|0:0||None assigned
```

That blocked the second job from using the same node, even though free CPUs and
GPUs remained.

Control check: a single pinned job saw one IMEX channel:

```text
14|wrap|alice|COMPLETED|0:0|10.140.79.152|billing=4,cpu=4,gres/gpu=1,mem=979788M,node=1
job=14 node=instance20260506003155 cuda=0
channel1
```

Then I reran two same-node jobs with an explicit memory request:

```bash
sbatch --nodelist=10.140.79.152 --mem=16G /home/alice/imex-per-job-channel-check.sbatch
sbatch --nodelist=10.140.79.152 --mem=16G /home/alice/imex-per-job-channel-check.sbatch
```

Both jobs overlapped on the same GB300 worker and completed:

```text
19|imex-channel-check|alice|project-a|COMPLETED|0:0|billing=4,cpu=4,gres/gpu=1,mem=16G,node=1|10.140.79.152
20|imex-channel-check|alice|project-a|COMPLETED|0:0|billing=4,cpu=4,gres/gpu=1,mem=16G,node=1|10.140.79.152
```

They saw distinct IMEX channel devices while running on the same node:

```text
job=19 node=instance20260506003155 slurm_node=10.140.79.152 cuda=0
channels_by_find:
channel1

job=20 node=instance20260506003155 slurm_node=10.140.79.152 cuda=0
channels_by_find:
channel2
```

Conclusion: with the current DRA `ComputeDomain` attached to the worker pods
and `SwitchType=switch/nvidia_imex`, Slurm can expose distinct IMEX channels to
overlapping jobs on the same worker. The practical requirement is to avoid
implicit full-node memory allocation, either by specifying `--mem` per job or by
setting a sane default memory policy for the partition/cluster.
