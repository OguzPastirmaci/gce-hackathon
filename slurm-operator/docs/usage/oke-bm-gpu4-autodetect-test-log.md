# OKE BM.GPU4.8 GPU AutoDetect Test Log

This records the live BM.GPU4.8 Slurm-on-OKE GPU autodetect tests performed on
2026-05-05.

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

## Current State After Test

The cluster was rolled back to the manual GRES overlay as Helm revision 24:

```text
Name=gpu Type=a100 File=/dev/nvidia[0-7]
```

Final Slurm node state after rollback:

```text
gpu-b4-0 idle gpu:a100:8 none
gpu-b4-1 idle gpu:a100:8 none
```

SMT remains disabled on the GPU hosts at runtime. This is not persistent across
node reboot unless configured in host boot/kernel settings or node provisioning.

## Working Conclusion

For BM.GPU4.8 on this OKE cluster, Slurm GPU `AutoDetect=nvml` is still not
usable with Slinky dynamic nodes unless the node topology supplied to Slurm is
changed to align with GPU affinity domains. Manual `gres.conf` remains the
validated fallback.
