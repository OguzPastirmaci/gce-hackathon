# Slinky Container Images

This file records the image tags used or built during the OKE Slinky testing.

## Current GB300 Slurm Deployment

These images were running in the `slurm` namespace during the GB300
IMEX/DRA/NCCL test.

| Component | Image |
|---|---|
| `slurmctld` | `iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04` |
| controller SSSD sidecar | `ghcr.io/slinkyproject/login:25.11-ubuntu24.04` |
| login | `ghcr.io/slinkyproject/login:25.11-ubuntu24.04` |
| `slurmd` | `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2` |
| `slurmdbd` | `ghcr.io/slinkyproject/slurmdbd:25.11-ubuntu24.04` |
| `slurmrestd` | `ghcr.io/slinkyproject/slurmrestd:25.11-ubuntu24.04` |
| MariaDB | `docker-registry1.mariadb.com/library/mariadb:11.8.5` |
| MariaDB exporter | `prom/mysqld-exporter:v0.15.1` |

`slurmd-nvml-core-25.11.5-ubuntu24.04` is a Slurm/NVML worker image. It does
not include `nccl-tests`, NCCL runtime libraries, or the Spectrum-X NCCL net
plugin. The current GB300 deployment uses
`slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2`, which keeps that NVML Slurm base and
adds the validated NCCL/HPCX payload.

## NCCL Test Images

The successful GB300 Slurm NCCL run staged NCCL payloads from:

| Image | Use |
|---|---|
| `iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.1.1-ubuntu-24.04-nccl-2.29.3-020926.1` | Validated NCCL 2.29.3 + CUDA 13.1 + HPCX/Spectrum-X payload used for GB300 testing |

Registry tags currently present on `iad.ocir.io/idxzjcdglx2s/nccl-tests`:

```text
causal-v1
cuda-12.9.1-ubuntu-24.04-nccl-2.28.9-26.1.0
cuda-12.9.1-ubuntu-24.04-nccl-2.29.2-011826.1
cuda-12.9.1-ubuntu-24.04-nccl-2.29.2-26.1.0
cuda-12.9.1-ubuntu-24.04-nccl-2.29.3-020926.1
cuda-13.0-nccl-2.27.7-1-v1
cuda-13.1.0-ubuntu-24.04-nccl-2.28.9-26.1.0
cuda-13.1.0-ubuntu-24.04-nccl-2.29.2-011826.1
cuda-13.1.0-ubuntu-24.04-nccl-2.29.2-1-25.1.0
cuda-13.1.0-ubuntu-24.04-nccl-2.29.2-25.1.0
cuda-13.1.0-ubuntu-24.04-nccl-2.29.2-26.1.0
cuda-13.1.1-ubuntu-24.04-nccl-2.29.2-020826.1
cuda-13.1.1-ubuntu-24.04-nccl-2.29.2-020926.1
cuda-13.1.1-ubuntu-24.04-nccl-2.29.3-020926.1
cuda-13.2.0-ubuntu-24.04-nccl-2.29.7-040926.0
cuda-13.2.0-ubuntu-24.04-nccl-2.29.7-040926.1
cuda-13.2.0-ubuntu-24.04-nccl-2.29.7-041526.1
cuda-test-v1
itv-cuda13.1-v1
itv-v1
latest
nccl-2.28.7-1-ib
nccl-2.28.7-1-ib-amd64
nccl-2.28.7-1-ib-arm64
pytorch-25.08-nccl-2.27.7-1-v1
pytorch-25.08-nccl-2.27.7-1-v2
pytorch-25.08-nccl-2.27.7-1-v3
pytorch-25.08-nccl-2.27.7-nccl-tests-2.17.1
pytorch-25.08-nccl-2.28.3-1-v1
torchtitan-v1
ubuntu22.04-nccl-2.29.2-1
ubuntu24.04-nccl-2.29.2-1
ubuntu24.04-nccl-2.29.2-1-test1
```

## Slinky Worker Images

Registry tags currently present on `iad.ocir.io/idxzjcdglx2s/slinky`:

```text
slurmctld-pmix-25.11-ubuntu24.04
slurmctld-pmix-sssd-nss-25.11-ubuntu24.04
slurmd-nvml-25.11.5-ubuntu24.04
slurmd-nvml-core-25.11.5-ubuntu24.04
slurmd-nvml-gres-25.11.5-ubuntu24.04
slurmd-nvml-nccl-25.11.5-ubuntu24.04
slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2
slurmd-rocm-torch-24.05.7-rocm25.4-fa43b1ca-r1
slurmd-rdma-25.11-ubuntu24.04
slurmd-rdma-pmix-25.11-ubuntu24.04
slurmd-rdma-pmix-nvml-25.11.4-ubuntu24.04
```

## Combined NVML + NCCL Slurm Worker Image

| Image | Purpose |
|---|---|
| `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-25.11.5-ubuntu24.04` | First multi-platform `slurmd` image based on `slurmd-nvml-core-25.11.5-ubuntu24.04` with the validated NCCL/HPCX payload copied in. Superseded because global HPCX/OpenMPI environment variables interfered with generic Slurm/PMIx launch. |
| `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2` | Current GB300 deployment image. Keeps only `NCCL_TEST_HOME` and `PATH` globally, and requires NCCL jobs to opt in through `with-nccl-tests-env`. |

Build source:

```text
images/slurmd-nvml-nccl/Dockerfile
```

Build command used on `image-builder`:

```bash
docker buildx build \
  --builder multiarch-builder \
  --platform linux/amd64,linux/arm64 \
  -t iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2 \
  --push /home/ubuntu/slurmd-nvml-nccl
```

First pushed manifest list:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-25.11.5-ubuntu24.04
sha256:648d59fdbc24fdaf2a6d71b12cbe3bdc138da83d28133002d60be6f7c8f6ee9a
```

Platforms:

```text
linux/amd64  sha256:de61ff6175eff72651a33d5abc21a1b7845db76a100fbcdb7ebadab5c805c7cf
linux/arm64  sha256:501ad65ea0b9038edd89653d5c810035c98f5511caf6efa50a252d50ec981501
```

Current pushed manifest list:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2
sha256:eee6dd3d685ff80fe4918f36fe5077fe29403a64bed45435304891362e3dd973
linux/amd64  sha256:af97033daaf4eb25abf24466da729959af5139693039128288ee2041cb4c3373
linux/arm64  sha256:635a5e945aa506c491c13dcb5b20af32de4fe5a536689488fe000c0a79d19a4c
```

Contents:

```text
/opt/nccl-tests/bin/*_perf
/workspace/nccl-tests/build/*_perf
/opt/nccl-tests/lib/libnccl.so*
/opt/nccl-tests/lib/libcudart.so*
/opt/hpcx/ompi
/opt/hpcx/ucx
/opt/hpcx/nccl_spectrum-x_plugin
/opt/hpcx/nccl_rdma_sharp_plugin
Slurm NVML plugins inherited from slurmd-nvml-core
```

Build-time validation verified both architectures have:

```text
/opt/nccl-tests/bin/all_reduce_perf
/opt/nccl-tests/lib/libnccl.so.2
/opt/hpcx/ompi/lib/libmpi.so.40
/opt/hpcx/nccl_spectrum-x_plugin/lib/libnccl-net.so
/usr/lib/<multiarch>/slurm/gpu_nvml.so
/usr/lib/<multiarch>/slurm/gres_gpu.so
```

Runtime smoke test on `image-builder` for `linux/amd64`:

```text
x86_64
/opt/nccl-tests/bin/all_reduce_perf
libcudart.so.13 => /opt/nccl-tests/lib/libcudart.so.13
libmpi.so.40 => /opt/hpcx/ompi/lib/libmpi.so.40
libnccl.so.2 => /opt/nccl-tests/lib/libnccl.so.2
```

The `linux/arm64` runtime check could not be executed with plain
`docker run --platform linux/arm64` on `image-builder` because that Docker
daemon does not have arm64 binfmt enabled for direct container execution. The
multi-platform build did execute and validate the arm64 image under buildx.

Runtime validation on GB300 arm64 Slurm workers:

```text
deployed image: iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2
Slurm job: 9
Nodes: 4 x BM.GPU.GB300.4
Ranks: 16
NCCL version: 2.29.3+cuda13.1
Result: 0 OK
Avg bus bandwidth: 262.326 GB/s
```

## AMD ROCm Slurm Worker Image

This image was built for the upcoming AMD GPU node cluster from the ROCm GPU
Operator Slinky example.

| Field | Value |
|---|---|
| Image | `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rocm-torch-24.05.7-rocm25.4-fa43b1ca-r1` |
| Registry digest | `sha256:0cd3523aa85d8f91872a081b5ab30b8f4d567d8f757d02437617b9f68d6e22fb` |
| Source repo | `https://github.com/ROCm/gpu-operator` |
| Source commit | `fa43b1ca` |
| Source Dockerfile | `example/slinky/slurm-rocm-torch/Dockerfile` |
| Docker target | `slurmd` |
| Parent image | `rocm/pytorch-training:v25.4` |
| Slurm version | `24.05.7` |
| Platform | `linux/amd64` only |
| Local image size on `image-builder` | `93.3GB` |

The parent ROCm/PyTorch image is a single `linux/amd64` Docker manifest, so this
one could not be built as a multi-platform image without changing the parent
image strategy.

The upstream example Dockerfile needed two build-only fixes on `image-builder`
before it could produce the `slurmd` target:

- guard the patch application step so the build works when the example has no
  `patches/` directory;
- restore `COPY --from=build /tmp/*.deb /tmp/` so the runtime stage can install
  the Slurm packages built in the `build` stage.

Build command used on `image-builder`:

```bash
cd /home/ubuntu/rocm-gpu-operator/example/slinky/slurm-rocm-torch
docker buildx build \
  --builder multiarch-builder \
  --platform linux/amd64 \
  --target slurmd \
  -t iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rocm-torch-24.05.7-rocm25.4-fa43b1ca-r1 \
  --load .
```

The buildx client hung after Docker import even though the image had already
loaded locally; the stale client was killed and the loaded image was validated
and pushed.

Local smoke test on `image-builder`:

```text
x86_64
slurm 24.05.7
PyTorch: 2.7.0a0+git6374332
HIP: 6.3.42131-fa1d09cbd
torch.cuda.is_available(): False
rocm-smi: /opt/rocm/bin/rocm-smi
```

Push result:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rocm-torch-24.05.7-rocm25.4-fa43b1ca-r1
sha256:0cd3523aa85d8f91872a081b5ab30b8f4d567d8f757d02437617b9f68d6e22fb
```

## Local Build Host Images

The `image-builder` host also had these relevant local images:

```text
ghcr.io/coreweave/nccl-tests:13.0.1-devel-ubuntu22.04-nccl2.28.7-1-6b47463
ghcr.io/slinkyproject/login:25.11-ubuntu24.04
iad.ocir.io/idxzjcdglx2s/mpi-operator:0.8.0
iad.ocir.io/idxzjcdglx2s/nccl-tests:cuda-13.1.0-ubuntu-24.04-nccl-2.29.2-011826.1
iad.ocir.io/idxzjcdglx2s/nccl-tests:itv-cuda13.1-v1
iad.ocir.io/idxzjcdglx2s/nccl-tests:itv-v1
iad.ocir.io/idxzjcdglx2s/nccl-tests:nccl-2.28.7-1-ib
iad.ocir.io/idxzjcdglx2s/nccl-tests:nccl-2.28.7-1-ib-amd64
iad.ocir.io/idxzjcdglx2s/nccl-tests:nccl-2.28.7-1-ib-arm64
iad.ocir.io/idxzjcdglx2s/oke-npd:v1.34.0-1
iad.ocir.io/idxzjcdglx2s/oke-npd:v1.34.0-2
iad.ocir.io/idxzjcdglx2s/oke-npd:v1.34.0-cuda-5
iad.ocir.io/idxzjcdglx2s/oke-npd:v1.34.0-cuda-7
iad.ocir.io/idxzjcdglx2s/oke-npd:v1.34.0-cuda-8
iad.ocir.io/idxzjcdglx2s/oke-npd:v1.34.0-cuda-9
iad.ocir.io/idxzjcdglx2s/rccl-tests:rocm-7.1.1-ubuntu22.04-rccl-2.27.7-011826
iad.ocir.io/idxzjcdglx2s/rccl-tests:rocm-7.1.1-ubuntu22.04-rccl-2.27.7-011826.1
iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-25.11-ubuntu24.04
iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-gres-25.11.5-ubuntu24.04
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rocm-torch-24.05.7-rocm25.4-fa43b1ca-r1
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rdma-25.11-ubuntu24.04
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rdma-pmix-25.11-ubuntu24.04
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rdma-pmix-nvml-25.11.4-ubuntu24.04
iad.ocir.io/idxzjcdglx2s/vf-config:v1
nccl-tests:cuda12.9-nccl-base
nccl-tests:cuda12.9-nccl-latest
nccl-tests:cuda13.1-nccl-base
nccl-tests:cuda13.1-nccl-latest
```
