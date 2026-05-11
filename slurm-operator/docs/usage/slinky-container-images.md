# Slinky Container Images

This file records the image tags used or built during the OKE Slinky testing.

## Current GB300 Slurm Deployment

These images were running in the `slurm` namespace during the GB300
IMEX/DRA/NCCL test.

| Component | Image |
|---|---|
| `slurmctld` | `iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04` |
| controller SSSD sidecar | `ghcr.io/slinkyproject/login:25.11-ubuntu24.04` |
| login | `iad.ocir.io/idxzjcdglx2s/slinky:login-pyxis-25.11.5-ubuntu24.04-r6` |
| `slurmd` | `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-pyxis-25.11.5-ubuntu24.04-r3` |
| `slurmdbd` | `ghcr.io/slinkyproject/slurmdbd:25.11-ubuntu24.04` |
| `slurmrestd` | `ghcr.io/slinkyproject/slurmrestd:25.11-ubuntu24.04` |
| MariaDB | `docker-registry1.mariadb.com/library/mariadb:11.8.5` |
| MariaDB exporter | `prom/mysqld-exporter:v0.15.1` |

`slurmd-nvml-core-25.11.5-ubuntu24.04` is a Slurm/NVML worker image. It does
not include `nccl-tests`, NCCL runtime libraries, or the Spectrum-X NCCL net
plugin. The prior non-Pyxis GB300 deployment used
`slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2`, which keeps that NVML Slurm base and
adds the validated NCCL/HPCX payload. The current deployment uses
`slurmd-nvml-nccl-pyxis-25.11.5-ubuntu24.04-r3`, which keeps the same NVIDIA
worker payload and adds Pyxis/Enroot.

Pyxis-capable images are additive images: normal non-container Slurm jobs still
run against the pod filesystem, and Pyxis/Enroot is used only when a job passes
Pyxis flags such as `--container-image`.

| Component | Pyxis-capable image |
|---|---|
| login | `iad.ocir.io/idxzjcdglx2s/slinky:login-pyxis-25.11.5-ubuntu24.04-r6` |
| NVIDIA `slurmd` | `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-pyxis-25.11.5-ubuntu24.04-r3` |

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
login-pyxis-25.11.5-ubuntu24.04-r1
login-pyxis-25.11.5-ubuntu24.04-r2
login-pyxis-25.11.5-ubuntu24.04-r3
login-pyxis-25.11.5-ubuntu24.04-r4
login-pyxis-25.11.5-ubuntu24.04-r5
login-pyxis-25.11.5-ubuntu24.04-r6
slurmd-nvml-25.11.5-ubuntu24.04
slurmd-nvml-core-25.11.5-ubuntu24.04
slurmd-nvml-gres-25.11.5-ubuntu24.04
slurmd-nvml-nccl-25.11.5-ubuntu24.04
slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2
slurmd-nvml-nccl-pyxis-25.11.5-ubuntu24.04-r1
slurmd-nvml-nccl-pyxis-25.11.5-ubuntu24.04-r2
slurmd-nvml-nccl-pyxis-25.11.5-ubuntu24.04-r3
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

## Pyxis + Enroot Slurm Images

These images were built after the initial GB300 NCCL validation to add Pyxis and
Enroot support while preserving the current login and NVIDIA worker image
behavior.

| Field | Login image | NVIDIA worker image |
|---|---|---|
| Image | `iad.ocir.io/idxzjcdglx2s/slinky:login-pyxis-25.11.5-ubuntu24.04-r6` | `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-pyxis-25.11.5-ubuntu24.04-r3` |
| Registry digest | `sha256:e82b606bb2bfd425f6e9ca33e7da11b74eb63ee3db09ef626394abb596e97e3d` | `sha256:2164b4f8d4e24999475151755f8caef42062f3f6bfd1321f198d0c73746a2340` |
| Platforms | `linux/amd64`, `linux/arm64` | `linux/amd64`, `linux/arm64` |
| Base image | `ghcr.io/slinkyproject/login:25.11-ubuntu24.04` | `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2` |
| Pyxis source image | `ghcr.io/slinkyproject/login-pyxis:25.11-ubuntu24.04` | `ghcr.io/slinkyproject/slurmd-pyxis:25.11-ubuntu24.04` |
| Build source | `images/login-pyxis/Dockerfile` | `images/slurmd-nvml-nccl-pyxis/Dockerfile` |

Build commands used on `image-builder`:

```bash
docker buildx build \
  --builder multiarch-builder \
  --platform linux/amd64,linux/arm64 \
  -t iad.ocir.io/idxzjcdglx2s/slinky:login-pyxis-25.11.5-ubuntu24.04-r6 \
  --push /home/ubuntu/login-pyxis

docker buildx build \
  --builder multiarch-builder \
  --platform linux/amd64,linux/arm64 \
  -t iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-pyxis-25.11.5-ubuntu24.04-r3 \
  --push /home/ubuntu/slurmd-nvml-nccl-pyxis
```

The Dockerfiles copy the Pyxis/Enroot payload from the corresponding Slinky
Pyxis images, install Enroot runtime dependencies from Ubuntu, and set the Enroot
file capabilities:

```text
/usr/bin/enroot
/usr/share/pyxis/pyxis.conf
/usr/lib/<multiarch>/slurm/spank_pyxis.so
/usr/bin/enroot-aufs2ovlfs cap_sys_admin,cap_mknod=ep
/usr/bin/enroot-mksquashovlfs cap_sys_admin=ep
```

The Pyxis-capable images also set Enroot defaults that work for LDAP users
inside Kubernetes pods without per-job environment overrides:

```text
ENROOT_RUNTIME_PATH        /tmp/enroot-runtime-${UID}
ENROOT_CONFIG_PATH         /tmp/enroot-config-${UID}
ENROOT_CACHE_PATH          /tmp/enroot-cache-${UID}
ENROOT_DATA_PATH           /tmp/enroot-data-${UID}
ENROOT_TEMP_PATH           /tmp
```

The `login-pyxis` `r6` image adds the default interactive login toolset and
fail2ban for SSH login pods. It installs common tools for users who SSH into the
login pod to edit and submit jobs, including `vim`, `nano`, `less`, `tmux`,
`git`, `rsync`, `python3`, `jq`, `yq`, `htop`, `man-db`, `screen`, `tree`,
`zip`, `unzip`, `zstd`, `curl`, `wget`, `dnsutils`, and `traceroute`.

`sshd` still runs under supervisor, but through
`/usr/local/sbin/sshd-with-authlog`, which mirrors stderr to
`/var/log/auth.log` with syslog-style prefixes. fail2ban also runs under
supervisor with an enabled `sshd` jail:

```text
backend = polling
banaction = iptables-multiport
maxretry = 5
findtime = 10m
bantime = 1h
logpath = /var/log/auth.log
```

For production SSH exposure through a Kubernetes `LoadBalancer` Service, prefer
`externalTrafficPolicy: Local` so fail2ban sees the client IP. With
`externalTrafficPolicy: Cluster`, the auth log and fail2ban may see an internal
node or overlay IP instead of the original SSH client.

Worker-image validation also verified the existing NVIDIA worker payload remains
present:

```text
slurm 25.11.5
/usr/lib/<multiarch>/slurm/gpu_nvml.so
/usr/lib/<multiarch>/slurm/gres_gpu.so
/opt/nccl-tests/bin/all_reduce_perf
/usr/local/bin/with-nccl-tests-env
```

To enable the images in a Slurm deployment, use the Pyxis-capable login and
worker images and include Pyxis through `plugstack.conf`:

```yaml
configFiles:
  plugstack.conf: |
    include /usr/share/pyxis/*

loginsets:
  slinky:
    login:
      image:
        repository: iad.ocir.io/idxzjcdglx2s/slinky
        tag: login-pyxis-25.11.5-ubuntu24.04-r6
      securityContext:
        privileged: true

nodesets:
  gb300:
    slurmd:
      image:
        repository: iad.ocir.io/idxzjcdglx2s/slinky
        tag: slurmd-nvml-nccl-pyxis-25.11.5-ubuntu24.04-r3
```

Normal jobs continue to run without a container. Container execution is opt-in:

```bash
srun --container-image=alpine:latest grep PRETTY /etc/os-release
```

Runtime validation on the GB300 cluster:

```text
Normal Slurm job:
alice
instance20260506003204
/home/alice

Pyxis job, no Enroot environment overrides:
pyxis: importing docker image: ubuntu:24.04
pyxis: imported docker image: ubuntu:24.04
alice
instance20260506003204
PRETTY_NAME="Ubuntu 24.04.4 LTS"
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

## AMD ROCm/RSMI/RCCL Slurm Worker Image

The current AMD MI300X Slurm worker image uses the validated ROCm 7.1.1/RCCL
test image as the base, then installs Slurm 25.11.5 with `gpu_rsmi`, `gres_gpu`,
SSSD/NSS, and a `slurmd` entrypoint wrapper.

| Field | Value |
|---|---|
| Current image | `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rocm-rccl-25.11.5-rocm7.1.1-sssd-r2` |
| Current registry digest | `sha256:57eb9b1145370909fa8f4c8f6128727ba4d4694ed0055e7c8dfc2f7cf8c7c0bb` |
| Superseded image | `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rocm-rccl-25.11.5-rocm7.1.1-sssd-r1` |
| Base RCCL image | `iad.ocir.io/idxzjcdglx2s/rccl-tests:rocm-7.1.1-ubuntu22.04-rccl-2.27.7-011826.1` |
| Slurm version | `25.11.5` |
| Platform | `linux/amd64` only |
| Build source | `images/slurmd-rocm-rccl/Dockerfile` |

The `r2` image differs from `r1` by raising the worker memlock limit to
`unlimited` before `slurmd` starts. That matters for multi-node RCCL over RDMA:
the Slurm batch job inherits the `slurmd` limit, while an unrelated
`kubectl exec` shell still shows Kubernetes' default `8192` KB memlock.

Build command used on `image-builder`:

```bash
docker buildx build \
  --builder multiarch-builder \
  --platform linux/amd64 \
  -t iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rocm-rccl-25.11.5-rocm7.1.1-sssd-r2 \
  --push /home/ubuntu/slurmd-rocm-rccl
```

Build-time and runtime smoke tests verified:

```text
slurm 25.11.5
/usr/lib/x86_64-linux-gnu/slurm/gpu_rsmi.so
/usr/lib/x86_64-linux-gnu/slurm/gres_gpu.so
/usr/lib/x86_64-linux-gnu/libnss_sss.so.2
/opt/oci-hpc/rccl-tests/bin/all_reduce_perf
all_reduce_perf links to /workspace/rccl/install/lib/librccl.so.1
```

Runtime validation on the AMD MI300X Slurm workers:

```text
deployed image: iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rocm-rccl-25.11.5-rocm7.1.1-sssd-r2
Slurm version: 25.11.5
RSMI autodetect: 8 GPU system device(s) detected
Slurm GRES: gpu:amd_instinct_mi300x_oam:8(S:0-1)
Slurm job user/accounting: alice / project-a
2-node RCCL Slurm job: completed with 16 GPUs using the upstream OCI MI300X RCCL variables
Avg bus bandwidth: 354.504 GB/s
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
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rocm-rccl-25.11.5-rocm7.1.1-sssd-r1
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rocm-rccl-25.11.5-rocm7.1.1-sssd-r2
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
