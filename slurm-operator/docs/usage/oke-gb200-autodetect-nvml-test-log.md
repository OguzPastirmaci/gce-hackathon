# OKE GB200 AutoDetect=nvml Test Log

Date: 2026-05-05

Operator host:

```bash
ssh -J ubuntu@192.9.189.161 ubuntu@10.140.0.20
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

## Shape: BM.GPU.GB200.4

This log applies only to `BM.GPU.GB200.4`.

Use the [OKE Slurm Shape Runbooks](oke-slurm-shape-runbooks.md) before applying
values. The GB200 test path uses an `arm64` worker node, `hostNetwork`,
worker sshd on `Port 2222`, and a multi-platform Slurm worker image. Do not use
these hostNetwork values as the `BM.GPU4.8` SR-IOV/VF path.

## Cluster Discovery

Nodes:

```text
10.140.64.164  Ready  BM.GPU.GB200.4      arm64  Ubuntu 22.04.5 LTS  6.8.0-1047-nvidia-64k  nvidia.com/gpu=4
10.140.77.160  Ready  VM.Standard.E5.Flex  amd64
10.140.84.244  Ready  VM.Standard.E5.Flex  amd64
10.140.88.234  Ready  VM.Standard.E5.Flex  amd64
```

The GB200 node has taint:

```text
nvidia.com/gpu=present:NoSchedule
```

Storage class:

```text
oci-bv (default)
```

## Image Probe

Probed the stock Slinky arm64 worker image on the GB200 node:

```bash
kubectl run slurmd-nvml-check --restart=Never \
  --image=ghcr.io/slinkyproject/slurmd:25.11-ubuntu24.04 \
  --overrides='...' \
  --command -- /bin/sh -lc \
  'uname -m; find /usr -name gpu_nvml.so -o -name gpu_nvidia.so; nvidia-smi -L; slurmd -V'
```

Result:

```text
aarch64
/usr/lib/aarch64-linux-gnu/slurm/gpu_nvidia.so
GPU 0: NVIDIA GB200
slurm 25.11.5
```

Finding: the stock arm64 `slurmd` image can run on GB200 and see GPUs, but it
does not contain `gpu_nvml.so`. Since this test requires `AutoDetect=nvml`, a
minimal NVML-enabled slurmd image is required. Build and publish it as a
multi-platform image so the same tag works on both the arm64 GB200 worker node
and amd64 environments used for other Slinky tests.

## Image Build

Created local Dockerfile:

```text
images/slurmd-nvml/Dockerfile
```

The current design keeps the stock Slinky `slurmd` runtime image and compiles
only the required Slurm NVML pieces from the matching SchedMD source tag:

```text
libslurmfull.so
gpu_nvml.so
gres_gpu.so
```

This is intentionally smaller than rebuilding and replacing all Slurm Debian
packages.

Target image:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-core-25.11.5-ubuntu24.04
```

Build command on `image-builder`:

```bash
cd /home/ubuntu/slurmd-nvml-gb200
docker buildx build --builder multiarch-builder --platform linux/amd64,linux/arm64 \
  -t iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-core-25.11.5-ubuntu24.04 \
  --push .
```

Note: an initial arm64-only full Slurm Debian package rebuild was started while
validating GB200 support. That build was cancelled after the image policy was
changed to multi-platform and the Dockerfile was simplified to build only the
NVML plugin. Going forward, container images for this guide should be built and
pushed as multi-platform images unless there is a deliberate reason to publish
an architecture-specific tag.

First multi-platform plugin build failed while compiling `src/plugins/gpu/nvml`
because `../common/libgpu_common.la` had not been built. The Dockerfile was
updated to build `src/plugins/gpu/common` before `src/plugins/gpu/nvml`.

The corrected multi-platform build succeeded and pushed a manifest list:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-25.11.5-ubuntu24.04
linux/amd64 + linux/arm64
manifest list: sha256:e2d80eacaed7581a8311f0c426c8dcbfdbf64ffd4d7d2c775815f860ea6f9293
```

Runtime result from that first plugin-only image: `gpu_nvml.so` existed, but
`AutoDetect=nvml` still did not work. `slurmd` logged:

```text
We were configured to autodetect nvml functionality, but we weren't able to find that lib when Slurm was configured.
Reason=gres/gpu count reported lower than configured (0 < 4)
```

Conclusion: `AutoDetect=nvml` also requires the `gres/gpu` plugin to be built
with NVML support. The image tag was changed to
`slurmd-nvml-gres-25.11.5-ubuntu24.04` and the Dockerfile now installs both
`gpu_nvml.so` and `gres_gpu.so`.

The corrected GPU/GRES plugin image was built and pushed as a multi-platform
manifest:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-gres-25.11.5-ubuntu24.04
linux/amd64 + linux/arm64
manifest list: sha256:ea6223423db2c55b11450a105ab2268a5c19023c4ab76e4c0c98b3f3479bf084
```

Runtime result from the GPU/GRES plugin image: it still logged the same
build-time NVML error. Source inspection showed the decision is in
`src/interfaces/gpu.c`, which is compiled into `libslurmfull.so`; `slurmd`
calls `gres_get_autodetected_gpus()` from that library during dynamic node
registration. The Dockerfile was updated again to rebuild and install
`libslurmfull.so`, and the tag was changed to
`slurmd-nvml-core-25.11.5-ubuntu24.04`.

First attempt at the core-library build failed because building
`src/api/libslurmfull.la` directly also needs the generated
`src/api/full_version.map` linker script. The Dockerfile was updated to build
`full_version.map` before `libslurmfull.la`.

The final core-library image was built and pushed as a multi-platform manifest:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-core-25.11.5-ubuntu24.04
linux/amd64 + linux/arm64
manifest list: sha256:e12a52b4793d3e4c7f1db83f21c507c95aae10f51a5e53779c335ffb1577fe65
amd64 manifest: sha256:493082fe97284da99104eeb60cbb0a9518f600d74a5a226f052962cacdd0431e
arm64 manifest: sha256:c0cca5082c4905ddf2c0b23c9ecb01a2048aafab43810e409646f5ed01d723cc
```

## Slinky Values

Created:

```text
docs/usage/oke-gb200-hostnetwork-autodetect-nvml.values.yaml
```

Important settings:

```yaml
configFiles:
  gres.conf: |
    AutoDetect=nvml

nodesets:
  gb200:
    scalingMode: StatefulSet
    replicas: 1
    useResourceLimits: false
    slurmd:
      image:
        repository: iad.ocir.io/idxzjcdglx2s/slinky
        tag: slurmd-nvml-core-25.11.5-ubuntu24.04
      args:
        - -N
        - $(KUBE_NODE_NAME)
      env:
        - name: KUBE_NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
      lifecycle:
        preStop:
          exec:
            command:
              - /usr/bin/sh
              - -c
              - scontrol update nodename="${KUBE_NODE_NAME}" state=down reason='Pod is terminating'; scontrol delete nodename="${KUBE_NODE_NAME}" || true
      resources:
        limits:
          nvidia.com/gpu: 4
        requests:
          nvidia.com/gpu: 4
    ssh:
      enabled: true
      extraSshdConfig: |
        Port 2222
    extraConfMap:
      Gres:
        - gpu:4
      Features:
        - gb200
        - blackwell
        - rdma
        - hostnetwork
    podSpec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      nodeSelector:
        node.kubernetes.io/instance-type: BM.GPU.GB200.4
```

Intentional omissions:

```text
Boards
CPUs
SocketsPerBoard
CoresPerSocket
ThreadsPerCore
Parameters=l3cache_as_socket
Parameters=numa_node_as_socket
```

The `-N $(KUBE_NODE_NAME)` argument is required for this OKE hostNetwork test.
With Slinky `1.1.0`, a hostNetwork StatefulSet NodeSet maps the Slurm node name
to `pod.spec.nodeName`. On this cluster the Kubernetes node name is the private
IP (`10.140.64.164`), while the host OS hostname inside the hostNetwork pod is
`instance20260505204444`. Without `-N`, `slurmd` registers
`instance20260505204444`; the NodeSet controller expects `10.140.64.164` and
repeatedly deletes the worker pod as "Slurm node is not registered but pod is
healthy".

Tried `scalingMode: DaemonSet` plus the node annotation
`nodeset.slinky.slurm.net/hostname-override=instance20260505204444`. The
deployed operator image was `ghcr.io/slinkyproject/slurm-operator:1.1.0` and did
not honor that annotation. The DaemonSet pod hostname/Slurm label became `10`
because the operator derived it from the IP-style Kubernetes node name
`10.140.64.164` by trimming at the first dot. That attempt was rolled back, and
the unused node annotation was removed.

The hostNetwork guide also moves the worker container's `sshd` to port `2222`:

```yaml
nodesets:
  gb200:
    ssh:
      enabled: true
      extraSshdConfig: |
        Port 2222
```

This is hostNetwork-only. It avoids the worker container colliding with the
Kubernetes node's own `sshd` on port `22`. Do not add this setting to SR-IOV/VF
workers; those pods keep their own network namespace and do not collide with
the host port. This SSH port change was added to the guide after the initial
revision `5` NVML validation; redeploy the values file to apply it to the live
cluster.

## Deployment Commands

Copy the values to the operator node:

```bash
scp -o BatchMode=yes -J ubuntu@192.9.189.161 \
  docs/usage/oke-gb200-hostnetwork-autodetect-nvml.values.yaml \
  ubuntu@10.140.0.20:/home/ubuntu/values-gb200-hostnetwork-autodetect-nvml.yaml
```

Apply the Slurm release:

```bash
ssh -o BatchMode=yes -J ubuntu@192.9.189.161 ubuntu@10.140.0.20 \
  'export PATH=/home/ubuntu/bin:$PATH OCI_CLI_AUTH=instance_principal;
   helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
     -f /home/ubuntu/values-gb200-hostnetwork-autodetect-nvml.yaml \
     --namespace slurm --create-namespace'
```

The final successful deployment was Helm revision `5`, deployed at
`2026-05-05T22:19:55Z`.

## Runtime Validation

Final pod and NodeSet state after the hostNetwork node-name fix:

```text
NAME                     READY   STATUS    RESTARTS   AGE   IP             NODE
slurm-worker-gb200-0     2/2     Running   0          95s   10.140.64.164  10.140.64.164

NAME                 DESIRED   REPLICAS   UPDATED   READY   IDLE
slurm-worker-gb200   1         1          1         1       1
```

Generated `slurmd` args:

```text
["-Z","--conf-server","slurm-controller.slurm:6817","--conf",
"'Features=gb200,gb200,blackwell,rdma,hostnetwork Gres=gpu:4 Weight=1'",
"-N","$(KUBE_NODE_NAME)"]
```

The container entrypoint expanded the Kubernetes Downward API value correctly:

```text
exec slurmd --systemd -Z --conf-server slurm-controller.slurm:6817 \
  --conf 'Features=gb200,gb200,blackwell,rdma,hostnetwork Gres=gpu:4 Weight=1' \
  -N 10.140.64.164
```

`AutoDetect=nvml` now loads and detects the GB200 GPUs:

```text
gpu/nvml: _get_system_gpu_list_nvml: 4 GPU system device(s) detected
```

The node registers in Slurm without `INVALID_REG`:

```text
NODELIST       NODES PARTITION STATE CPUS    S:C:T  MEMORY
10.140.64.164      1 gb200     idle  144     2:72:1 979729
10.140.64.164      1 all*      idle  144     2:72:1 979729
```

`scontrol show node` reports the GPUs:

```text
NodeName=10.140.64.164 Arch=aarch64 CoresPerSocket=72
   Gres=gpu:4(S:0-1)
   NodeAddr=10.140.64.164 NodeHostName=instance20260505204444 Version=25.11.5
   State=IDLE+DYNAMIC_NORM ThreadsPerCore=1
   Comment={"namespace":"slurm","podName":"slurm-worker-gb200-0","node":"10.140.64.164"}
```

GPU scheduling test:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  srun -N1 -n1 --gres=gpu:4 --time=00:02:00 nvidia-smi -L
```

Result:

```text
GPU 0: NVIDIA GB200 (UUID: GPU-c180d613-630c-b39f-e5e0-7eaf7372e826)
GPU 1: NVIDIA GB200 (UUID: GPU-6a2cc93b-3a6e-39d7-db27-09fc77822678)
GPU 2: NVIDIA GB200 (UUID: GPU-dbdc9460-7f3f-0c52-7566-7929b34f905b)
GPU 3: NVIDIA GB200 (UUID: GPU-c7648206-65ae-2cb8-dc17-e7a40cb55fef)
```

Notes:

- The revision `5` validation still showed the pre-change hostNetwork SSH noise:
  worker `sshd` could not bind port `22` because the Kubernetes node's host SSH
  daemon owns it. The guide now configures worker `sshd` on `Port 2222` through
  `nodesets.<name>.ssh.extraSshdConfig`; redeploy before testing SSH to the
  worker container.
- `sssd` exits because no SSSD domain is configured in this GB200 autodetect
  test. This is unrelated to NVML detection.
- `AccountingStorageTRES` is still the chart default because
  `accounting.enabled=false` in this test values file. GPU scheduling works with
  `--gres=gpu:4`; accounting-specific GPU TRES validation is a separate test.

## Single-Node Job Test

Submitted a real batch job requesting one node, one task, and all four GPUs:

```bash
sbatch --parsable -N1 -n1 --gres=gpu:4 --time=00:03:00 \
  --output=/tmp/gb200-single-node-%j.out \
  --wrap='echo hostname=$(hostname); echo SLURM_JOB_ID=$SLURM_JOB_ID; echo SLURM_JOB_NODELIST=$SLURM_JOB_NODELIST; echo CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-unset}; nvidia-smi -L'
```

Result:

```text
JobId=4
JobState=COMPLETED
ExitCode=0:0
NodeList=10.140.64.164
BatchHost=10.140.64.164
TresPerNode=gres/gpu:4
```

The output file was written on the worker pod at
`/tmp/gb200-single-node-4.out`:

```text
hostname=instance20260505204444
SLURM_JOB_ID=4
SLURM_JOB_NODELIST=10.140.64.164
CUDA_VISIBLE_DEVICES=0,1,2,3
GPU 0: NVIDIA GB200
GPU 1: NVIDIA GB200
GPU 2: NVIDIA GB200
GPU 3: NVIDIA GB200
```

Also ran a foreground single-node `srun` for visible output from the controller
pod:

```bash
srun -N1 -n1 --gres=gpu:4 --time=00:02:00 bash -lc \
  'echo hostname=$(hostname); echo SLURM_JOB_ID=$SLURM_JOB_ID; echo SLURM_JOB_NODELIST=$SLURM_JOB_NODELIST; echo CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-unset}; nvidia-smi -L'
```

Result: job `5` ran on `10.140.64.164`, exposed
`CUDA_VISIBLE_DEVICES=0,1,2,3`, and listed all four GB200 GPUs.
