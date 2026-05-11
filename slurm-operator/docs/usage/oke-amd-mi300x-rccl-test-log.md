# OKE AMD MI300X Slurm and RCCL Test Log

Date: 2026-05-07

This log records the current AMD `BM.GPU.MI300X.8` validation work for Slinky,
HA OpenLDAP, FSS, accounting, RSMI autodetect, and RCCL tests.

## Cluster

Operator access:

```bash
ssh -J ubuntu@217.142.249.158 ubuntu@10.140.0.21
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

GPU nodes:

```text
10.140.64.165  BM.GPU.MI300X.8
10.140.78.229  BM.GPU.MI300X.8
```

Relevant Kubernetes state:

```text
AMD device plugin installed
GPU resource: amd.com/gpu=8 per MI300X node
GPU taint: amd.com/gpu=present:NoSchedule
FSS PV: fss-pv
Slurm home PVC: slurm/slurm-home
cert-manager installed
Kueue and MPIJob CRDs/operators installed
```

## Files

```text
docs/usage/manifests/oke-amd-mi300x-ha-openldap-prereqs.yaml
docs/usage/manifests/oke-amd-mi300x-ha-openldap.values.yaml
docs/usage/ldif/oke-amd-mi300x-ha-openldap-tls-config.ldif
docs/usage/ldif/oke-amd-mi300x-ha-openldap-primary-syncprov.ldif
docs/usage/manifests/oke-amd-mi300x-slurm-home-pvc.yaml
docs/usage/manifests/oke-amd-mi300x-mariadb.yaml
docs/usage/manifests/oke-amd-mi300x-hostnetwork-ha-openldap-slurm.values.yaml
docs/usage/scripts/oke-amd-mi300x-ha-openldap-deploy.sh
docs/usage/manifests/oke-amd-mi300x-kueue-rccl-tests-cpu-launcher.yaml
docs/usage/jobs/oke-amd-mi300x-slurm-rccl.sbatch
images/slurmd-rocm-rccl/Dockerfile
```

The HA OpenLDAP values already use the chart's preferred anti-affinity setting:

```yaml
podAntiAffinityPreset: soft
```

That is the default for the HA OpenLDAP path. It spreads OpenLDAP pods across
`kubernetes.io/hostname` when possible without making replicas unschedulable on
small test clusters.

## Worker Image

Current AMD Slurm worker image:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rocm-rccl-25.11.5-rocm7.1.1-sssd-r2
sha256:57eb9b1145370909fa8f4c8f6128727ba4d4694ed0055e7c8dfc2f7cf8c7c0bb
```

The image is built from:

```text
iad.ocir.io/idxzjcdglx2s/rccl-tests:rocm-7.1.1-ubuntu22.04-rccl-2.27.7-011826.1
```

It adds:

- Slurm `25.11.5`;
- `gpu_rsmi.so` and `gres_gpu.so`;
- SSSD/NSS packages;
- RCCL tests under `/opt/oci-hpc/rccl-tests`;
- `with-rccl-tests-env`;
- a `slurmd-sssd-wrapper` that starts SSSD, raises memlock to `unlimited`,
  strips Slinky's quoted `--conf` argument, and execs `slurmd -D`.

Important memlock detail:

- `kubectl exec` shells still show the Kubernetes default memlock of `8192` KB.
- The real `slurmd` process has `Max locked memory unlimited`.
- Slurm batch jobs inherit the `slurmd` limit and also show
  `Max locked memory unlimited`.

## Slurm Validation

Both Slurm workers were rolled to `r2`:

```text
slurm-worker-mi300x-0 imageID=sha256:57eb9b1145370909fa8f4c8f6128727ba4d4694ed0055e7c8dfc2f7cf8c7c0bb
slurm-worker-mi300x-1 imageID=sha256:57eb9b1145370909fa8f4c8f6128727ba4d4694ed0055e7c8dfc2f7cf8c7c0bb
```

RSMI autodetect worked on both workers:

```text
gpu/rsmi: _get_system_gpu_list_rsmi: 8 GPU system device(s) detected
slurmd version 25.11.5 started
```

Slurm saw both MI300X nodes with 8 GPUs:

```text
10.140.64.165|idle|0/224/0/224|gpu:amd_instinct_mi300x_oam:8(S:0-1)|mi300x,amd,rocm,rdma,hostnetwork|none
10.140.78.229|idle|0/224/0/224|gpu:amd_instinct_mi300x_oam:8(S:0-1)|mi300x,amd,rocm,rdma,hostnetwork|none
```

LDAP identity resolution worked in both workers:

```text
alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
```

Single-node RCCL smoke test as `alice` completed:

```text
JobID|User|Account|State|ExitCode|AllocTRES|NodeList
5|alice|project-a|COMPLETED|0:0|billing=2,cpu=2,gres/gpu=1,mem=2063904M,node=1|10.140.78.229
Out of bounds values : 0 OK
```

## Earlier Two-Node RCCL Rail Investigation

The OCI MI300X RCCL variables from:

```text
https://raw.githubusercontent.com/oracle-quickstart/oci-hpc-oke/refs/heads/main/manifests/rccl-tests/kueue/BM.GPU.MI300X.8.yaml
```

initially failed in Slurm with all rails:

```text
UCX_NET_DEVICES=mlx5_0:1
NCCL_IB_HCA='=mlx5_0,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_7,mlx5_8,mlx5_9'
```

After the `r2` memlock fix, the failure moved from memory registration to UCX
endpoint creation:

```text
ibv_create_ah(... dgid=::ffff:10.224.14.229 ... sgid_index=3 ...) failed: Connection timed out
PML ucx cannot be selected
```

RDMA reachability checks showed only two of the eight RDMA rails were reachable
between the two MI300X nodes:

```text
reachable:
rdma4 / mlx5_5
rdma5 / mlx5_7

not reachable:
rdma0 / mlx5_0
rdma1 / mlx5_2
rdma2 / mlx5_3
rdma3 / mlx5_4
rdma6 / mlx5_8
rdma7 / mlx5_9
```

The two-node Slurm RCCL job completed when restricted to the reachable rails:

```bash
export UCX_NET_DEVICES=mlx5_5:1,mlx5_7:1
export NCCL_IB_HCA==mlx5_5,mlx5_7
```

Result:

```text
JobID|User|Account|State|ExitCode|AllocTRES|NodeList
10|alice|project-a|COMPLETED|0:0|billing=448,cpu=448,gres/gpu=16,mem=4127808M,node=2|10.140.78.229,10.140.64.165

Ranks: 16
GPUs: 16
RCCL version: 2.27.7
ROCm version: 7.1.1
Out of bounds values : 0 OK
Avg bus bandwidth    : 19.0952 GB/s
```

## Standalone Kueue/MPIJob Check

To test the upstream OCI RCCL Kueue manifest outside Slurm, the Slinky MI300X
NodeSet was scaled to zero:

```bash
kubectl -n slurm patch nodeset slurm-worker-mi300x --type=merge \
  -p '{"spec":{"replicas":0}}'
```

The upstream raw OCI manifest created the Kueue objects and MPIJob, and Kueue
admitted the workload. Worker pods scheduled on the two GPU nodes, but the
launcher stayed Pending:

```text
0/5 nodes are available:
2 node(s) had untolerated taint(s),
3 node(s) didn't match Pod's node affinity/selector
```

Cause:

- the launcher pod also received the MI300X GPU node selector;
- the two GPU nodes have `amd.com/gpu=present:NoSchedule`;
- the launcher did not tolerate that taint;
- non-GPU nodes could not be used because of the injected GPU selector.

The local variant
`docs/usage/manifests/oke-amd-mi300x-kueue-rccl-tests-cpu-launcher.yaml` adds a CPU
ResourceFlavor and pins the launcher to `VM.Standard.E5.Flex`, while keeping
workers on `BM.GPU.MI300X.8`.

Scheduling with that variant was validated:

```text
rccl-tests-launcher-*  Running/CrashLoopBackOff  10.140.81.135  VM.Standard.E5.Flex
rccl-tests-worker-0    Running                   10.140.78.229  BM.GPU.MI300X.8
rccl-tests-worker-1    Running                   10.140.64.165  BM.GPU.MI300X.8
```

After the GPU-node reboot, the CPU-launcher variant scheduled cleanly again,
but the raw OCI rail settings still failed. The launcher reached both workers,
then UCX timed out on `mlx5_0`:

```text
All workers are ready!
ibv_create_ah(... sgid_index=3 ...) for UD mlx5 connect on mlx5_0 failed: Connection timed out
ucp_ep_create(...) failed: Endpoint timeout
MPI_ERR_OTHER: known error not in list
```

The Kubernetes labels on the launcher use
`training.kubeflow.org/job-role=launcher`, not
`training.kubeflow.org/replica-type=launcher`. Use either the pod name or this
selector to get launcher logs:

```bash
kubectl logs -l training.kubeflow.org/job-name=rccl-tests,training.kubeflow.org/job-role=launcher
```

The standalone Kueue/MPIJob completed successfully after restricting the same
CPU-launcher manifest to the two reachable rails:

```bash
UCX_NET_DEVICES=mlx5_5:1,mlx5_7:1
NCCL_IB_HCA='=mlx5_5,mlx5_7'
```

Completed placement:

```text
rccl-tests-launcher-qcgj5  Completed  10.140.81.135  VM.Standard.E5.Flex
rccl-tests-worker-0        Running    10.140.64.165  BM.GPU.MI300X.8
rccl-tests-worker-1        Running    10.140.78.229  BM.GPU.MI300X.8
```

RCCL output:

```text
Ranks: 16
GPUs: 16
RCCL version : 2.27.7-HEAD:bf3ebf5
HIP version  : 7.1.52802-26aae437f6
ROCm version : 7.1.1.0-38-26aae437f6

  1073741824     268435456     float     sum      -1   100834   10.65   19.97      0   100934   10.64   19.95      0
  2147483648     536870912     float     sum      -1   201531   10.66   19.98      0   201559   10.65   19.98      0
  4294967296    1073741824     float     sum      -1   403053   10.66   19.98      0   403059   10.66   19.98      0
  8589934592    2147483648     float     sum      -1   805898   10.66   19.99      0   807077   10.64   19.96      0
 17179869184    4294967296     float     sum      -1  1613400   10.65   19.97      0  1611943   10.66   19.98      0
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 19.972
# Collective test concluded: all_reduce_perf
```

Warnings seen during the successful run:

```text
NCCL WARN Missing "iommu=pt" from kernel command line which can lead to system instablity or hang!
NCCL WARN LL cutoff points not detected for a supported arch gfx942
```

## Current Slurm RCCL Re-Test

After validating that `/home/ubuntu/oguz/BM.GPU.MI300X.8.yaml` worked as a
standalone Kubernetes MPIJob on the current AMD cluster, the Slinky MI300X
NodeSet was scaled back to two Slurm workers:

```bash
kubectl -n slurm patch nodeset slurm-worker-mi300x --type=merge \
  -p '{"spec":{"replicas":2}}'
```

Slurm registered both workers as idle with 8 MI300X GPUs each:

```text
10.140.81.44|idle|0/224/0/224|2063905|gpu:amd_instinct_mi300x_oam:8(S:0-1)|none
10.140.91.212|idle|0/224/0/224|2063905|gpu:amd_instinct_mi300x_oam:8(S:0-1)|none
```

The Slurm worker image contained both supported RCCL test paths:

```text
/opt/oci-hpc/rccl-tests/bin/all_reduce_perf
/workspace/rccl-tests/build/all_reduce_perf
/usr/local/bin/all_reduce_perf -> /opt/oci-hpc/rccl-tests/bin/all_reduce_perf
```

`docs/usage/jobs/oke-amd-mi300x-slurm-rccl.sbatch` captures the Slurm version of the
working Kubernetes MPIJob command. The Slurm job uses the same RCCL/OpenMPI
variables as the OCI manifest, but replaces the MPIJob ssh launcher settings
with OpenMPI's Slurm launcher:

```text
--mca ras slurm
--mca plm slurm
```

The job completed as LDAP user `alice` with Slurm accounting under
`project-a`:

```text
JobID|JobName|User|Account|State|ExitCode|Elapsed|AllocTRES
11|rccl-mi300x-slurm|alice|project-a|COMPLETED|0:0|00:00:36|billing=448,cpu=448,gres/gpu=16,mem=4127810M,node=2
11.batch|batch||project-a|COMPLETED|0:0|00:00:36|cpu=224,gres/gpu=8,mem=2063905M,node=1
11.extern|extern||project-a|COMPLETED|0:0|00:00:36|billing=448,cpu=448,gres/gpu=16,mem=4127810M,node=2
11.0|orted||project-a|COMPLETED|0:0|00:00:36|billing=448,cpu=448,gres/gpu=16,mem=4127810M,node=2
```

RCCL output from the Slurm run:

```text
Ranks: 16
GPUs: 16
RCCL version : 2.27.7-HEAD:bf3ebf5
HIP version  : 7.1.52802-26aae437f6
ROCm version : 7.1.1.0-38-26aae437f6

  1073741824     268435456     float     sum      -1   5734.8  187.23  351.06      0   5739.5  187.08  350.77      0
  2147483648     536870912     float     sum      -1    11397  188.42  353.28      0    11402  188.34  353.14      0
  4294967296    1073741824     float     sum      -1    22744  188.84  354.07      0    22745  188.83  354.06      0
  8589934592    2147483648     float     sum      -1    45325  189.52  355.35      0    45312  189.57  355.45      0
 17179869184    4294967296     float     sum      -1    89763  191.39  358.86      0    89731  191.46  358.99      0
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 354.504
# Collective test concluded: all_reduce_perf
```

## Current Notes

- The committed Slurm values still set the MI300X Slurm worker replica count to
  `2`.
- After the standalone Kueue/MPIJob test, the live cluster was scaled back to
  `2` Slurm workers and the same two-node RCCL test completed through Slurm.
- The earlier MI300X cluster showed RDMA reachability problems on several rails
  and required restricting UCX/NCCL to `mlx5_5` and `mlx5_7`. The current
  cluster completed with the upstream OCI settings that use
  `UCX_NET_DEVICES=mlx5_0:1` and all eight HCAs in `NCCL_IB_HCA`.
