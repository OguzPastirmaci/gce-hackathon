# OKE BM.GPU4.8 GPU AutoDetect Test Log

This records the live BM.GPU4.8 Slurm-on-OKE GPU autodetect tests performed on
2026-05-05.

This log applies only to shape `BM.GPU4.8`. Do not use the GB200 hostNetwork
values or GB200 `AutoDetect=nvml` result as a substitute for this shape. For
shape selection, start with
[OKE Slurm Shape Runbooks](oke-slurm-shape-runbooks.md).

## Cluster

- Namespace: `slurm`
- Shape: `BM.GPU4.8`
- GPU nodes:
  - `10.140.76.140`
  - `10.140.89.40`
- Slurm worker image with NVML plugin:
  `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rdma-pmix-nvml-25.11.4-ubuntu24.04`
- Pushed digest:
  `iad.ocir.io/idxzjcdglx2s/slinky@sha256:6cd0af4089f5dc06950ebd7cfed3ad30f5f9ea9ea42e62fafd55e991b7163e5f`

## SMT Disable Validation

SMT was disabled at runtime on both GPU hosts with:

```bash
sudo sh -c 'echo off > /sys/devices/system/cpu/smt/control'
sudo systemctl restart kubelet
```

Host validation on both nodes:

```text
/sys/devices/system/cpu/smt/control: off
CPU(s): 128
On-line CPU(s) list: 0-63
Thread(s) per core: 1
Core(s) per socket: 32
Socket(s): 2
NUMA node(s): 8
```

Kubernetes validation after kubelet restart:

```text
BM.GPU4.8 node count: 2
10.140.76.140 cpu capacity: 64, allocatable: 63503m
10.140.89.40  cpu capacity: 64, allocatable: 63503m
GPU capacity: 8 per node
RDMA VF capacity: 16 per node
```

## AutoDetect=nvml Tests

Built and pushed the NVML-enabled worker image. The image contains:

```text
/usr/lib/x86_64-linux-gnu/slurm/gpu_nvml.so
slurm 25.11.4
```

Tested these Slurm variants without static `Sockets`, `CoresPerSocket`, or
`ThreadsPerCore` values:

- `AutoDetect=nvml`
- `AutoDetect=nvml` with `--parameters l3cache_as_socket`
- `AutoDetect=nvml` with `Parameters=l3cache_as_socket` in NodeSet `--conf`
- `AutoDetect=nvml` with `SLURMD_OPTIONS="--parameters l3cache_as_socket"`
- `AutoDetect=nvml` with `SLURMD_OPTIONS="--parameters numa_node_as_socket"`
- `AutoDetect=nvml` after runtime SMT disable, with no topology parameter

All variants failed Slurm GRES validation on BM.GPU4.8 with:

```text
gres/gpu GRES autodetected core affinity 24-31 ... doesn't match socket boundaries.
Consider setting Parameters=l3cache_as_socket as part of the Node configuration.
```

The SMT-off NVML-only test correctly reduced Slurm CPU topology to:

```text
CPUTot=64
ThreadsPerCore=1
Sockets=2
CoresPerSocket=32
```

but still failed because the detected GPU affinity `24-31` remains a subset of
Slurm socket 0 (`0-31`), not a full socket boundary.

## 2026-05-05 Fresh Reinstall Topology Check

After deleting and reinstalling Slinky and Slurm from scratch, the fresh
`AutoDetect=nvml` test reproduced the same invalid registration state. The
worker image was confirmed as:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rdma-pmix-nvml-25.11.4-ubuntu24.04
```

`gpu_nvml.so` exists in the worker image and `slurmd -V` reports `slurm
25.11.4`.

Direct host checks on both BM.GPU4.8 Kubernetes nodes showed the actual online
CPU topology:

```text
/sys/devices/system/cpu/smt/control: off
CPU(s): 128
On-line CPU(s) list: 0-63
Off-line CPU(s) list: 64-127
Thread(s) per core: 1
Core(s) per socket: 32
Socket(s): 2
NUMA node(s): 8
NUMA node0 CPU(s): 0-7
NUMA node1 CPU(s): 8-15
NUMA node2 CPU(s): 16-23
NUMA node3 CPU(s): 24-31
NUMA node4 CPU(s): 32-39
NUMA node5 CPU(s): 40-47
NUMA node6 CPU(s): 48-55
NUMA node7 CPU(s): 56-63
```

Kubernetes sees the SMT-off capacity:

```text
cpu: 64
nvidia.com/gpu: 8
nvidia.com/sriov-rdma-vf: 16
```

`slurmd -C` from the worker reports:

```text
NodeName=gpu-b4-0 CPUs=64 Boards=1 SocketsPerBoard=2 CoresPerSocket=32 ThreadsPerCore=1 RealMemory=2064153 Gres=gpu:nvidia_a100-sxm4-40gb:8
```

With topology parameters:

```text
Parameters=l3cache_as_socket:
SocketsPerBoard=16 CoresPerSocket=4 ThreadsPerCore=1

Parameters=numa_node_as_socket:
SocketsPerBoard=8 CoresPerSocket=8 ThreadsPerCore=1
```

`nvidia-smi topo -m` reports GPU CPU affinities as 8-core NUMA ranges:

```text
GPU0/GPU1: 24-31, NUMA node 3
GPU2/GPU3: 8-15,  NUMA node 1
GPU4/GPU5: 56-63, NUMA node 7
GPU6/GPU7: 40-47, NUMA node 5
```

Interpretation: the physical node is `2 sockets x 32 online cores`, but the GPU
CPU affinities align to NUMA-node boundaries of `8 sockets x 8 cores` if Slurm
uses `numa_node_as_socket`. They do not align with the default physical socket
boundaries, and they do not align with `l3cache_as_socket` because L3 cache
instances produce 4-core socket domains on this host.

## 2026-05-05 Successful Dynamic Node Topology Test

The working values overlay is saved at:

```text
docs/usage/manifests/oke-bm-gpu4-8-fss-sssd-ha-openldap-controller-sssd-autodetect-nvml-numa-topology.overlay.yaml
```

Remote copy used for the live test:

```text
/home/ubuntu/values-fresh-nvml-autodetect-numa-topology.yaml
```

The key fix was to put the NUMA-shaped topology in the Slinky NodeSet
`extraConfMap`, which Slinky passes to `slurmd -Z --conf` for Slurm dynamic
node registration. Keeping only `slurmd.args: ["--parameters",
"numa_node_as_socket"]` was not sufficient because the dynamic node still
registered as `Sockets=2 CoresPerSocket=32`.

Working values fragment:

```yaml
configFiles:
  gres.conf: |
    AutoDetect=nvml

nodesets:
  gpu-b4:
    extraConfMap:
      Boards: 1
      CoresPerSocket: 8
      CPUs: 64
      Features:
      - a100
      - 40gb
      - rdma
      - sriov
      Gres:
      - gpu:a100:8
      Parameters: numa_node_as_socket
      SocketsPerBoard: 8
      ThreadsPerCore: 1
      Weight: 1
    slurmd:
      args:
      - --parameters
      - numa_node_as_socket
      image:
        repository: iad.ocir.io/idxzjcdglx2s/slinky
        tag: slurmd-rdma-pmix-nvml-25.11.4-ubuntu24.04
```

Live worker command after Slinky rendering:

```text
slurmd --systemd -Z --conf-server slurm-controller.slurm:6817 \
  --conf 'Boards=1 Corespersocket=8 Cpus=64 Features=gpu-b4,a100,40gb,rdma,sriov Gres=gpu:a100:8 Parameters=numa_node_as_socket Socketsperboard=8 Threadspercore=1 Weight=1' \
  --parameters numa_node_as_socket
```

Slurm accepted the topology even though Slinky title-cased the multi-word
fields as `Corespersocket`, `Socketsperboard`, and `Threadspercore`.

Worker startup log:

```text
gpu/nvml: _get_system_gpu_list_nvml: 8 GPU system device(s) detected
CPUs=64 Boards=1 Sockets=8 Cores=8 Threads=1
```

Final Slurm node state:

```text
NODELIST STATE GRES REASON
gpu-b4-0 idle gpu:a100:8(S:1,3,5,7) none
gpu-b4-1 idle gpu:a100:8(S:1,3,5,7) none
```

`scontrol show node gpu-b4-0`:

```text
CoresPerSocket=8
Sockets=8 Boards=1
State=IDLE+DYNAMIC_NORM
ThreadsPerCore=1
Gres=gpu:a100:8(S:1,3,5,7)
Parameters=numa_node_as_socket
```

Recreated the test accounting association because the fresh MariaDB instance
only had `root`:

```bash
sacctmgr -i add account project-a Description="Project A" Organization=project-a
sacctmgr -i add user alice Account=project-a DefaultAccount=project-a
```

Submitted an SSH-based one-GPU job as `alice`:

```bash
sbatch --parsable --account=project-a --gres=gpu:1 \
  --output=/home/alice/autodetect-nvml-topo-%j.out \
  --wrap="hostname; whoami; id; nvidia-smi -L"
```

Result:

```text
JobId=1
UserId=alice(10001)
Account=project-a
JobState=COMPLETED
ExitCode=0:0
NodeList=gpu-b4-1
AllocTRES=cpu=1,mem=2064153M,node=1,billing=1,gres/gpu=1
TresPerNode=gres/gpu:1
```

Accounting result:

```text
1|alice|project-a|COMPLETED|0:0|billing=1,cpu=1,gres/gpu=1,mem=2064153M,node=1|gpu-b4-1
```

Job output:

```text
gpu-b4-1
alice
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
GPU 0: NVIDIA A100-SXM4-40GB
```

## Current State After Test

The live cluster is running the successful NVML AutoDetect topology test:

```text
AutoDetect=nvml
BM.GPU4.8
SMT off at runtime
Sockets=8
CoresPerSocket=8
ThreadsPerCore=1
Gres=gpu:a100:8(S:1,3,5,7)
```

SMT remains disabled on the GPU hosts at runtime. This is not persistent across
node reboot unless configured in host boot/kernel settings or node provisioning.

## Working Conclusion

`AutoDetect=nvml` works on the OKE BM.GPU4.8 cluster when Slinky dynamic nodes
register with NUMA-shaped topology in `--conf`: `CPUs=64`,
`SocketsPerBoard=8`, `CoresPerSocket=8`, `ThreadsPerCore=1`, and
`Parameters=numa_node_as_socket`. Passing only `--parameters
numa_node_as_socket` to `slurmd` records the parameter, but it does not change
the dynamic node topology that Slurm validates for GRES affinity.

## NCCL PMIx Test - 2026-05-05

Goal: submit an NCCL all-reduce job through the normal SSH-to-login-pod user
workflow as `alice`, using the two BM.GPU4.8 worker pods and SR-IOV VFs.

Preflight checks:

```bash
kubectl -n slurm exec slurm-worker-gpu-b4-0 -c slurmd -- \
  sh -lc 'ls -l /opt/nccl-tests/bin/all_reduce_perf'

kubectl -n slurm exec slurm-controller-0 -c slurmctld -- srun --mpi=list

ssh -i /home/ubuntu/.ssh/alice_slurm_test alice@$LOGIN_IP \
  'whoami; hostname; pwd; id; sacctmgr -n show assoc user=alice format=User,Account,Partition%20,QOS%20'
```

Results:

```text
/opt/nccl-tests/bin/all_reduce_perf exists on slurmd
srun --mpi=list includes pmix_v5
alice is mapped to uid=10001, gid=10001, group project-a
alice has Slurm association account=project-a qos=normal
```

First two-node submission failed because the `sbatch` allocation did not request
two nodes. The inner `srun -N 2` asked for two nodes inside a one-node batch
allocation:

```text
JobID=2
State=FAILED
Output=srun: error: Only allocated 1 nodes asked for 2
```

The script was changed to put the resource request on the batch allocation:

```bash
#!/usr/bin/env bash
#SBATCH --job-name=nccl-sriov-pmix
#SBATCH --partition=gpu-b4
#SBATCH --account=project-a
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --gres=gpu:1

set -euo pipefail
export LD_LIBRARY_PATH=/usr/local/openmpi/lib:/usr/lib/x86_64-linux-gnu:/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}
export NCCL_DEBUG=INFO
export NCCL_IB_SPLIT_DATA_ON_QPS=0
export NCCL_IB_QPS_PER_CONNECTION=4
export NCCL_IB_GID_INDEX=3
export NCCL_IB_HCA=mlx5
export NCCL_IB_TC=41
export NCCL_IB_SL=0
export NCCL_IB_TIMEOUT=22

echo "SLURM_JOB_ID=${SLURM_JOB_ID}"
echo "SLURM_JOB_NODELIST=${SLURM_JOB_NODELIST}"
echo "SLURM_NTASKS=${SLURM_NTASKS}"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-unset}"
srun --mpi=pmix --export=ALL \
  /opt/nccl-tests/bin/all_reduce_perf -b 8M -f 2 -g 1 -e 512M -c 1
```

The corrected two-node allocation reached NCCL over RDMA, but failed with
locked-memory exhaustion:

```text
JobID=3
State=FAILED
AllocTRES=billing=4,cpu=4,gres/gpu=2,mem=4128306M,node=2
NCCL INFO NET/IB : Using mlx5_* RoCE devices
NCCL INFO Channel ... via NET/IB/18/GDRDMA
NCCL WARN Call to ibv_reg_mr failed with error Cannot allocate memory
```

Slurm config already had the intended setting:

```text
PropagateResourceLimitsExcept = MEMLOCK
```

However, the slurmd process and job tasks still had an 8 MB memlock hard limit:

```text
Max locked memory         8388608              8388608              bytes
```

Temporary runtime fix used for this test:

```bash
for pod in slurm-worker-gpu-b4-0 slurm-worker-gpu-b4-1; do
  kubectl -n slurm exec "$pod" -c slurmd -- sh -lc \
    'pid=$(pgrep -x slurmd | head -1); prlimit --pid $pid --memlock=unlimited:unlimited; grep -i locked /proc/$pid/limits'
done
```

Validation after the temporary fix:

```text
Max locked memory         unlimited            unlimited            bytes

srun task:
Max locked memory         unlimited            unlimited            bytes
```

Rerun result:

```text
JobID=6
JobName=nccl-sriov-pmix
User=alice
Account=project-a
Partition=gpu-b4
State=COMPLETED
ExitCode=0:0
Elapsed=00:00:04
AllocTRES=billing=4,cpu=4,gres/gpu=2,mem=4128306M,node=2
NodeList=gpu-b4-[1,0]
```

NCCL output confirmed SR-IOV RDMA and GDRDMA:

```text
NCCL INFO NET/IB : Using mlx5_* RoCE devices
NCCL INFO Using network IB
NCCL INFO Channel ... via NET/IB/18/GDRDMA
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 18.7484
```

Conclusion: the NCCL PMIx path works with the current SR-IOV and
`AutoDetect=nvml` setup. The remaining production fix is to make the slurmd
container start with unlimited memlock, not to rely on the temporary `prlimit`
change after pod startup.

## NCCL Guide-Style 8-GPU / 16-VF Visibility Test - 2026-05-05

Goal: run the NCCL PMIx job using the same shape as
`slinky-quickstart-rdma.md`: request 8 GPUs per node from Slurm, run 8 tasks
per node, and let each task use one GPU. The 16 SR-IOV RDMA VFs are not
requested from Slurm as GRES; they are already allocated to each worker pod by
Kubernetes and are consumed by NCCL through the visible `mlx5_*` HCAs.

Current resource model:

```text
Kubernetes worker pod requests/limits:
  nvidia.com/gpu: 8
  nvidia.com/sriov-rdma-vf: 16

Slurm node:
  Gres=gpu:a100:8(S:1,3,5,7)
  CfgTRES=cpu=64,mem=2064153M,billing=64,gres/gpu=8
  GresTypes=gpu
```

The runnable validation script is saved at
`docs/usage/jobs/nccl-sriov-pmix-8gpu-16vf.sbatch`. It requests GPUs from Slurm and
fails early if an allocated worker pod does not see 16 RDMA VFs:

```bash
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=2
#SBATCH --gres=gpu:8

srun --mpi=none -N 2 --ntasks-per-node=1 --export=ALL sh -lc '
  test "$(nvidia-smi -L | wc -l)" -eq 8
  test "$(ls /sys/class/infiniband | wc -l)" -eq 16
'

srun --mpi=pmix --export=ALL \
  /opt/nccl-tests/bin/all_reduce_perf -b 1G -f 2 -g 1 -e 4G -c 1
```

Submitted as `alice`:

```bash
sbatch --output=/home/alice/nccl-sriov-pmix-guide-style-out-%j.txt \
  --wait /home/alice/nccl-sriov-pmix-guide-style.sbatch
```

Result:

```text
JobID=8
JobName=nccl-8gpu-16vf
User=alice
Account=project-a
Partition=gpu-b4
State=COMPLETED
ExitCode=0:0
Elapsed=00:00:13
AllocTRES=billing=32,cpu=32,gres/gpu=16,mem=4128306M,node=2
NodeList=gpu-b4-[1,0]
```

Job preflight output:

```text
SLURM_JOB_ID=8
SLURM_JOB_NODELIST=gpu-b4-[1,0]
SLURM_NTASKS=16
CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7
gpu-b4-1 cuda_visible=0,1,2,3,4,5,6,7 gpus=8 vfs=16 ibdevs=mlx5_18,...,mlx5_33
gpu-b4-0 cuda_visible=0,1,2,3,4,5,6,7 gpus=8 vfs=16 ibdevs=mlx5_18,...,mlx5_33
```

NCCL result:

```text
# nThread 1 nGpus 1 minBytes 1073741824 maxBytes 4294967296
# Rank 0-7 on gpu-b4-1 device 0-7 NVIDIA A100-SXM4-40GB
# Rank 8-15 on gpu-b4-0 device 0-7 NVIDIA A100-SXM4-40GB
NCCL INFO NET/IB : Using mlx5_* RoCE devices
NCCL INFO Channel ... via NET/IB/.../GDRDMA
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 188.464
```

Conclusion: the guide-style full-node NCCL workload works. Slurm requests and
accounts 8 GPUs per worker; Kubernetes has already attached 16 SR-IOV RDMA VFs
to each worker pod, and NCCL uses those VFs through `NCCL_IB_HCA=mlx5`.
