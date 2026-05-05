# Multi-User Slurm on OKE

This guide layer adapts the OKE Slurm deployment for a traditional multi-user
Slurm experience:

- users SSH to a login service as themselves;
- each shell runs with the user's real POSIX UID and GID;
- `/home/$USER` is mounted from OCI File Storage Service (FSS);
- users cannot read other users' home directories;
- `sbatch`, `srun`, `squeue`, and `sacct` show the real submitting user;
- SlurmDBD accounting associations and limits work.

The existing OKE guide is still the base for GPU, RDMA, PMIx, and NodeSet
configuration. Use these guides as an additional access, identity, storage, and
accounting layer.

## Files

- `README.md`: architecture and deployment order.
- `product-requirements.md`: PRD for the multi-user Slurm on OKE product
  direction and acceptance criteria.
- `admin-workflows.md`: operator runbook for onboarding, offboarding, SSH key
  rotation, FSS home repair, project membership, and Slurm account sync.
- `fss-home.md`: OCI FSS `/home` layout and Helm values.
- `ldap-sssd-login.md`: preferred LDAP, FreeIPA, or Active Directory login
  path through SSSD.
- `sssd-ldap-test.md`: live OKE validation of LDAP-backed SSSD identity using
  a disposable OpenLDAP service.
- `controller-sssd-nss.md`: design for making controller-side `scontrol`
  resolve LDAP usernames through SSSD/NSS.
- `controller-image-build.md`: exact `image-builder` steps, Dockerfile, smoke
  test, pushed OCIR tag, and digest for the controller SSSD/NSS image.
- `gpu-autodetect.md`: prepared apply, validation, and rollback runbook for
  using Slurm GPU `AutoDetect=nvidia` on BM.GPU4.8.
- `local-users-without-ldap.md`: no-LDAP option for small clusters.
- `slurm-accounting.md`: SlurmDBD user/account associations and enforcement.
- `overlays/values-multi-user-base.yaml`: example values overlay to merge with
  the existing OKE values file.
- `overlays/values-oke-bm-gpu4-8-fss-pvc.yaml`: concrete test values for the
  current OKE cluster using `BM.GPU4.8`, SR-IOV VFs, and the `slurm-home` FSS
  PVC.
- `overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml`:
  concrete deployed values for LDAP-backed SSSD plus controller-side NSS.
- `overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd-autodetect.yaml`:
  non-static `AutoDetect=nvidia` reproduction variant. The live BM.GPU4.8 test
  rejected this path; the next autodetect test should use `AutoDetect=nvml`
  with a rebuilt worker image.
- `overlays/values-controller-sssd-sidecar.yaml`: design overlay for running
  SSSD as a root sidecar in the controller pod after building a controller
  image with NSS/SSSD client support.
- `manifests/local-user-entrypoint-configmap.yaml`: no-LDAP test wrapper that
  creates `alice` in login and slurmd containers before running the stock
  image entrypoint.
- `manifests/openldap-test-identity.yaml`: disposable OpenLDAP service, test
  users, and SSSD Secret for validating the LDAP path.
- `manifests/ha-openldap/`: apply-ready HA OpenLDAP test deployment with one
  writable primary, two read replicas, OCI block-volume data/config PVCs, SSSD
  Secret, bootstrap Job, PDB, and NetworkPolicy.
- `resume-checkpoint.md`: exact stop point and next steps for continuing the
  cluster test later.

## Current Test Status

The concrete `BM.GPU4.8` values have been tested on the live OKE cluster with
two GPU nodes, SR-IOV VFs, and the existing `fss-pv` FSS volume. Verified paths
include SSH as `alice`, `/home/alice` from FSS, `/home` listing blocked for
normal users, SlurmDBD accounting for `alice/project-a`, and one-GPU Slurm jobs
whose output lands in Alice's home directory.

Both identity paths have been tested:

- no-LDAP wrapper for a small-cluster fallback;
- LDAP-backed SSSD with `alice` resolved from LDAP in login and worker pods.

The in-cluster HA OpenLDAP option has also been deployed and validated in the
live OKE cluster in the `identity` namespace. The test confirmed primary writes,
read replicas, read-only replica behavior, and replica restart recovery.

The custom controller image needed for controller-side NSS resolution has also
been built, pushed, and deployed:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04
```

The live cluster is on Helm release revision `8`. Controller-side lookups
(`getent passwd alice`, `id alice`, and `scontrol show job`) now resolve
`alice(10001)`.

## Recommended Architecture

For production clusters:

1. Keep one shared `LoginSet` for normal SSH access.
2. Use LDAP, FreeIPA, or Active Directory through SSSD for POSIX identity.
3. Mount OCI FSS at `/home` in login pods and all compute NodeSets.
4. Enable SlurmDBD accounting.
5. Sync identity groups to Slurm accounts and user associations.

Per-user login pods are optional. They are useful for stronger login-node
isolation, but they are not required to make Slurm identify users or account for
their jobs.

## Deployment Order

1. Deploy the base OKE Slurm cluster from the existing guide.
2. Create or identify the OCI FSS filesystem, mount target, and export path.
3. Create `/home/$USER` directories on FSS with correct ownership and mode.
4. Configure SSSD identity, or choose the local-user no-LDAP path.
5. Enable accounting and create Slurm account/user associations.
6. Merge the multi-user values into the active OKE values file.
7. Test SSH as a real user and submit a job.

Example Helm upgrade shape after creating a merged values file:

```bash
helm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  -f slinky-values-multi-user.yaml \
  --namespace=slurm
```

The example overlay contains placeholders and merge guidance. Do not apply it
blindly on top of the RDMA examples: Helm replaces lists such as
`volumeMounts` and `volumes`, so the `/home` entries must be added alongside
existing entries such as `/dev/infiniband` and `/dev/shm`.

## Target User Experience

Users should connect like this:

```bash
ssh alice@<slurm-login-load-balancer>
```

Inside the login pod:

```bash
whoami
pwd
ls -ld /home /home/alice /home/bob
sbatch --wrap="hostname"
squeue -u alice
sacct -u alice
```

Expected behavior:

- `whoami` returns `alice`;
- the shell starts in `/home/alice`;
- `/home/bob` is not readable by `alice`;
- Slurm jobs show `alice` as the submitting user;
- `sacct` shows job history once accounting is enabled and associations exist.

## Design Notes

Do not use `rootSshAuthorizedKeys` as the normal user path. It is useful for
break-glass debugging, but jobs submitted from a root shell are root jobs from
Slurm's point of view.

Do not rely on Kubernetes `kubectl exec` for the primary user experience.
`kubectl exec` is useful for operators, but it does not naturally provide the
same SSH, POSIX user, home directory, and Slurm accounting model as a
traditional Slurm login node.
