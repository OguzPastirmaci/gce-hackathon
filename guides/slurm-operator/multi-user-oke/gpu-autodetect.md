# GPU AutoDetect on BM.GPU4.8

Date: 2026-05-05

This note records the prepared Slurm GPU AutoDetect path for the current OKE
Slurm test cluster.

## Status

`AutoDetect=nvidia` was tested on the live BM.GPU4.8 OKE cluster and is not the
recommended path for this environment.

The active live release is back on the validated manual GRES config:

```text
Name=gpu Type=a100 File=/dev/nvidia[0-7]
```

The AutoDetect values file is:

```text
overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd-autodetect.yaml
```

## Configuration

Use `AutoDetect=nvidia` in `gres.conf`:

```yaml
configFiles:
  gres.conf: |
    AutoDetect=nvidia
```

Keep `Gres` in the NodeSet so Slurm knows the expected type and count. Do not
statically define the full socket/core/thread topology as a workaround; that is
too brittle for the Kubernetes deployment model we want.

```yaml
nodesets:
  gpu-b4:
    slurmd:
      args:
        - --parameters
        - l3cache_as_socket
    extraConfMap:
      Gres: ["gpu:a100:8"]
      Features: ["a100", "40gb", "rdma", "sriov"]
      Weight: 1
```

The local render check for the non-static variant produced:

```text
AutoDetect=nvidia
extraConf: Features=a100,40gb,rdma,sriov Gres=gpu:a100:8 Weight=1
nvidia.com/sriov-rdma-vf: 16
node.kubernetes.io/instance-type: BM.GPU4.8
claimName: slurm-home
```

## Live Test Results

Tested on 2026-05-05:

- Helm revision 9: `AutoDetect=nvidia` without `l3cache_as_socket` registered
  both GPUs but drained both nodes as `INVALID_REG`.
- Helm revision 10: adding `Parameters=l3cache_as_socket` through
  `nodesets.gpu-b4.extraConfMap` did not work because Slinky renders that value
  into `slurmd --conf`, and Slurm did not apply the parameter from there.
- Helm revision 11: adding `slurmd.args: ["--parameters",
  "l3cache_as_socket"]` made Slurm record `Parameters=l3cache_as_socket`, but
  the node still registered with the default BM.GPU4.8 topology and stayed
  invalid.
- Helm revision 12: a temporary static topology test with `Sockets=16`,
  `CoresPerSocket=4`, and `ThreadsPerCore=2` was also rejected as a direction.
  It still failed because GPU CPU affinity crossed the derived L3-cache socket
  boundaries, and statically defining hardware topology is not acceptable for
  the desired Kubernetes-native deployment.
- Helm revision 13: rolled back to manual GRES and restarted the controller and
  worker pods. Both workers returned to `idle` with `gpu:a100:8`.

Conclusion: use manual GRES for the current non-NVML image, and test the next
iteration with Slurm rebuilt with NVML support and `AutoDetect=nvml`.

## Apply

Copy the values file to the operator node:

```bash
scp -o ProxyJump=ubuntu@152.67.124.58 \
  overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd-autodetect.yaml \
  ubuntu@10.140.0.18:/home/ubuntu/slurm-multi-user-overlays/
```

Then run from the operator node:

```bash
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal

helm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  --namespace slurm \
  -f /home/ubuntu/slurm-multi-user-overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd-autodetect.yaml
```

The NodeSet/worker pods should roll because `gres.conf` and NodeSet
`extraConf` changed.

## Validate

Check rendered Slurm config inside the controller:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  grep -R "AutoDetect\\|Gres=\\|Parameters=" /etc/slurm
```

Check nodes and GRES:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- sinfo -N -o "%N %t %G"
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- scontrol show node gpu-b4-0 | grep -E "Gres=|CfgTRES|AllocTRES"
```

Submit a one-GPU job as Alice:

```bash
LOGIN_IP=$(kubectl -n slurm get svc slurm-login-slinky -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

JOB=$(ssh -i /home/ubuntu/.ssh/alice_slurm_test alice@$LOGIN_IP \
  'sbatch --parsable --account=project-a --gres=gpu:1 \
    --output=/home/alice/autodetect-%j.out \
    --wrap="hostname; whoami; id; nvidia-smi -L"')

kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  scontrol show job "$JOB" | grep -E "UserId|GroupId|Account|JobState|TresPerNode"

ssh -i /home/ubuntu/.ssh/alice_slurm_test alice@$LOGIN_IP \
  "sacct -j $JOB --format=JobID,User,Account,State,ExitCode,AllocTRES%80,NodeList -P"
```

Expected:

```text
UserId=alice(10001)
Account=project-a
TresPerNode=gres/gpu:1
AllocTRES includes gres/gpu=1
```

## Roll Back

If the workers fail to register or GRES does not show correctly, roll back to
the last validated manual-GRES values:

```bash
helm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  --namespace slurm \
  -f /home/ubuntu/slurm-multi-user-overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml
```

The manual values use:

```text
Name=gpu Type=a100 File=/dev/nvidia[0-7]
```
