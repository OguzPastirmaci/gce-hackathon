# Resume Checkpoint

Date: 2026-05-05

Stop point: Slurm, SSH login as `alice`, FSS home isolation, SR-IOV workers,
GPU scheduling, SlurmDBD accounting, and LDAP-backed SSSD identity are
installed and validated. The next session should continue from this running
cluster, not reinstall from scratch.

## Local Files

Guide directory:

```text
/Users/opastirm/Documents/Repos/guides/slurm-operator/multi-user-oke
```

Most important files:

- `product-requirements.md`: PRD for production multi-user Slurm on OKE.
- `cluster-test-log.md`: full step log.
- `overlays/values-oke-bm-gpu4-8-fss-pvc.yaml`: concrete Slurm values for the
  current test cluster.
- `manifests/local-user-entrypoint-configmap.yaml`: no-LDAP local user wrapper.
- `manifests/openldap-test-identity.yaml`: disposable OpenLDAP test identity
  source and SSSD Secret.
- `overlays/values-oke-bm-gpu4-8-fss-sssd-ldap.yaml`: concrete Slurm values
  for the current SSSD/LDAP test.
- `overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml`:
  concrete deployed values for the current SSSD/LDAP test with controller-side
  SSSD/NSS.
- `overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd-autodetect.yaml`:
  non-static `AutoDetect=nvidia` reproduction values. This path was tested and
  rejected for the current BM.GPU4.8 environment; next test is NVML.
- `overlays/values-controller-sssd-sidecar.yaml`: design overlay for a root
  SSSD sidecar in the controller pod; now points at the pushed controller
  image with NSS/SSSD client support.
- `sssd-ldap-test.md`: exact SSSD test steps and validation results.
- `controller-sssd-nss.md`: findings from `slinky-containers` and a design for
  controller-side NSS/SSSD integration.
- `controller-image-build.md`: exact Dockerfile, build, smoke-test, and OCIR
  push details for the custom controller image.
- `gpu-autodetect.md`: prepared apply, validation, and rollback runbook for
  using `AutoDetect=nvidia` on BM.GPU4.8.

The concrete values file uses:

```yaml
nodeSelector:
  node.kubernetes.io/instance-type: BM.GPU4.8
```

and preserves:

- `nvidia.com/gpu: 8`
- `nvidia.com/sriov-rdma-vf: 16`
- SR-IOV NAD annotation with 16 `sriov-rdma-vf` attachments
- `/dev/infiniband`
- `/dev/shm`
- `slurm-home` PVC mounted at `/home`

## Operator Node Files

Operator node access:

```bash
ssh -o BatchMode=yes \
  -o UserKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=no \
  -J ubuntu@152.67.124.58 ubuntu@10.140.0.18
```

Use this environment for `kubectl`, `helm`, and `oci`:

```bash
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

Files copied to the operator node:

```text
/home/ubuntu/slinky-values-sriov-fss-pvc.yaml
/home/ubuntu/slurm-multi-user-manifests/local-user-entrypoint-configmap.yaml
/home/ubuntu/alice-slurm-job-test.sh
/home/ubuntu/alice-accounting-test.sh
/home/ubuntu/slurm-multi-user-manifests/openldap-test-identity.yaml
/home/ubuntu/slurm-multi-user-overlays/values-oke-bm-gpu4-8-fss-sssd-ldap.yaml
/home/ubuntu/slurm-multi-user-overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml
/home/ubuntu/slurm-multi-user-overlays/rendered-controller-sssd.yaml
```

Generated test key for `alice`:

```text
/home/ubuntu/.ssh/alice_slurm_test
/home/ubuntu/.ssh/alice_slurm_test.pub
```

Test user:

```text
username: alice
uid: 10001
gid: 10001
home: /home/alice
```

Additional FSS home directory created for isolation testing:

```text
/home/bob uid=10002 gid=10002 mode=700
```

## Cluster State

Applied:

- `cert-manager` Helm release in namespace `cert-manager`.
- `slurm-operator-crds` Helm release in namespace `default`.
- `slurm-operator` Helm release in namespace `slinky`.
- `mariadb-operator-crds` Helm release in namespace `default`.
- `mariadb-operator` Helm release in namespace `mariadb`.
- `slurm` namespace.
- copied `NetworkAttachmentDefinition/slurm/sriov-rdma-vf`.
- created `PersistentVolumeClaim/slurm/slurm-home`, bound to `fss-pv`.
- applied `ConfigMap/slurm/slurm-local-user-entrypoint`.
- provisioned `/home/alice/.ssh/authorized_keys` on `slurm-home` with
  UID/GID `10001:10001`.
- installed Slurm Helm release `slurm` in namespace `slurm`.
- created `MariaDB/slurm/mariadb`.
- enabled Slurm accounting and restarted `slurm-controller-0` to load the new
  accounting config.
- created Slurm account `project-a`.
- associated Slurm user `alice` with default account `project-a`.
- validated Alice cannot list `/home` or read `/home/bob`.
- validated a one-GPU job as Alice with `--gres=gpu:1`; output landed in
  `/home/alice/gpu-4.out` and accounting recorded
  `alice/project-a/COMPLETED/gres/gpu=1`.
- created disposable `OpenLDAP/slurm/openldap-test` for SSSD testing.
- created `Secret/slurm/site-sssd-ldap-test-conf`.
- upgraded Slurm to Helm release revision `3` using
  `values-oke-bm-gpu4-8-fss-sssd-ldap.yaml`.
- removed the local-user wrapper from login and slurmd in the active release.
- validated `alice` resolves from LDAP through SSSD in login and worker pods.
- validated SSH public key lookup through `sss_ssh_authorizedkeys` with
  `AuthorizedKeysFile none`.
- validated SSSD-backed GPU job `5`; accounting recorded
  `alice/project-a/COMPLETED/gres/gpu=1`.
- built and pushed custom controller image
  `iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04`.
- upgraded Slurm to Helm release revision `8` using
  `values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml`.
- deployed a root SSSD sidecar in the controller pod and the custom
  SSSD/NSS-enabled `slurmctld` image.
- validated controller-side `getent passwd alice` and `id alice`.
- validated fresh GPU job `6`; `scontrol show job 6` from the controller
  resolved `UserId=alice(10001)` and accounting recorded
  `alice/project-a/COMPLETED/gres/gpu=1`.

Not applied yet:

- production LDAP, FreeIPA, or AD integration. The current identity source is a
  disposable in-cluster OpenLDAP service for validation.
- NVML-backed GPU autodetect. `AutoDetect=nvidia` was tested and rejected for
  BM.GPU4.8 because it invalidated the nodes on GPU CPU-affinity/socket-boundary
  checks unless we started statically defining topology, which we do not want.

Custom controller image built and pushed:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04
digest: sha256:683d5fd96ceee8e34d8647a29eda69ba8e9220ca762064f951c0183edc522567
```

Current Helm release:

```text
slurm revision 13 deployed
manual GRES active: Name=gpu Type=a100 File=/dev/nvidia[0-7]
gpu-b4-0 idle gpu:a100:8 none
gpu-b4-1 idle gpu:a100:8 none
```

Live GPU nodes were verified as:

```text
10.140.76.140 node.kubernetes.io/instance-type=BM.GPU4.8 gpu=8 vf=16
10.140.89.40  node.kubernetes.io/instance-type=BM.GPU4.8 gpu=8 vf=16
```

## Next Steps

1. Re-check the running state:

```bash
kubectl -n slurm get pods,svc,pvc -o wide
sacctmgr show user alice format=user,defaultaccount,adminlevel -P
kubectl -n slurm exec deploy/slurm-login-slinky -c login -- getent passwd alice
kubectl -n slurm exec slurm-worker-gpu-b4-0 -c slurmd -- getent passwd alice
```

2. SSH as `alice` from the operator node:

```bash
ssh -i /home/ubuntu/.ssh/alice_slurm_test alice@<login-lb-ip>
```

Current login LoadBalancer IP:

```text
192.9.181.77
```

3. Re-run the SSSD GPU accounting test if needed:

```bash
ssh -i /home/ubuntu/.ssh/alice_slurm_test alice@192.9.181.77 \
  'sbatch --parsable --wait --account=project-a --gres=gpu:1 \
    --output=/home/alice/sssd-gpu-%j.out \
    --wrap="hostname; whoami; id; getent passwd alice; getent group project-a; nvidia-smi -L"'
```

The latest successful controller-side SSSD GPU test was job `6`:

```text
6|alice|project-a|COMPLETED|0:0|billing=2,cpu=2,gres/gpu=1,mem=2064153M,node=1|gpu-b4-1
```

4. Next functional work should focus on production identity:

- replace the disposable OpenLDAP test source with production LDAP, FreeIPA, or
  Active Directory;
- use LDAPS or StartTLS with CA validation;
- use a real SSH-key LDAP attribute instead of the test `description` mapping;
- automate Slurm account/user association sync from identity groups.

5. Next GPU autodetect work:

- build and push a worker image with Slurm rebuilt against `libnvidia-ml-dev`;
- use the prepared Dockerfile at
  `multi-user-oke/images/slurmd-rdma-pmix-nvml/Dockerfile`;
- test that the image contains `/usr/lib/x86_64-linux-gnu/slurm/gpu_nvml.so`;
- deploy a values variant with `configFiles.gres.conf: AutoDetect=nvml` and no
  static socket/core/thread topology fields.

## Important Cautions

- Do not use `hostNetwork`; the prepared values file uses SR-IOV VFs.
- Keep the shape selector as `BM.GPU4.8`, not `BM.GPU.B4.8`.
- The no-LDAP wrapper is for testing. It creates `alice` in login and slurmd
  containers. Production should use SSSD backed by LDAP, FreeIPA, or Active
  Directory for consistent identity on every Slurm component.
- The active release now uses SSSD/LDAP, not the wrapper. `scontrol` from both
  Alice's login session and the controller resolves `alice(10001)`.
- Do not use static `Sockets`, `CoresPerSocket`, or `ThreadsPerCore` fields as
  the GPU AutoDetect workaround. That path was tested and rejected.
- Worker SSSD is currently enabled through `nodesets.gpu-b4.ssh.enabled=true`;
  this is the chart switch that mounts `sssd.conf` into slurmd pods.
- Helm list merging is dangerous here. Do not layer a small values file that
  replaces `volumeMounts` or `volumes`; use the prepared merged values file.
