# Product Requirements Document: Multi-User Slurm on OKE

Status: Draft  
Date: 2026-05-05  
Owner: TBD  
Target platform: Slurm Operator on Oracle Kubernetes Engine (OKE)

## Summary

Provide a traditional multi-user Slurm experience on Kubernetes-backed OKE
clusters.

Users should SSH to a Slurm login endpoint as themselves, land in their own FSS
home directory, submit jobs with normal Slurm commands, and have Slurm and
SlurmDBD accounting record the real submitting user. The implementation must
preserve the existing GPU and RDMA architecture on OKE: `BM.GPU4.8` worker
nodes, SR-IOV VFs, and no `hostNetwork`.

The preferred production identity model is LDAP, FreeIPA, or Active Directory
through SSSD. If LDAP must run inside Kubernetes, the recommended production
shape is HA OpenLDAP with one writable primary and read replicas. A no-LDAP
local-user path can remain as a small-cluster fallback and test path, but it is
not the recommended production design.

## Problem

The current Kubernetes-native Slurm deployment can run Slurm workloads, but a
cluster intended for multiple human users needs the same identity, home
directory, SSH, and accounting behavior that users expect from a traditional
bare-metal Slurm installation.

The main gaps are:

- Linux identity must be consistent across login and compute pods.
- SSH access must authenticate real users, not root.
- `/home/$USER` must be shared across login and compute via OCI FSS.
- Users must not be able to list or read other users' homes.
- Slurm jobs must show the submitting user, not root or an operator identity.
- SlurmDBD associations, limits, QOS, and accounting must work.
- Operator-side commands in the controller should optionally resolve usernames,
  not only numeric UIDs.

## Goals

- Give users a familiar Slurm access model: `ssh user@login`, then `sbatch`,
  `squeue`, `sacct`, `srun`.
- Use a shared LoginSet as the normal access path.
- Use SSSD with LDAP, FreeIPA, or AD for production POSIX identity.
- When LDAP is hosted inside Kubernetes, use an HA OpenLDAP StatefulSet design
  with one writable primary, read replicas, TLS, backup/restore, and explicit
  promotion runbooks.
- Mount OCI FSS at `/home` in login and compute pods.
- Enforce home directory isolation with POSIX permissions.
- Preserve OKE GPU/RDMA requirements: `BM.GPU4.8`, SR-IOV VFs, no
  `hostNetwork`.
- Enable SlurmDBD accounting and account/user associations.
- Provide clear onboarding, offboarding, key rotation, and account-sync
  workflows.
- Document and support a tested fallback path for small clusters without LDAP.

## Non-Goals

- Replace Slurm with Kubernetes-native job submission for users.
- Use `kubectl exec` as the primary user workflow.
- Require one login pod per user for the default design.
- Build a full identity provider product.
- Solve high-performance shared scratch storage for training datasets.
- Provide per-user Kubernetes namespaces as the primary isolation boundary.

## Users and Personas

HPC user:

- SSHs into the login service.
- Uses normal Slurm CLI commands.
- Expects `$HOME` to follow them from login to jobs.
- Expects jobs, accounting, and errors to show their username.

Cluster administrator:

- Installs and upgrades Slurm on OKE.
- Configures identity, FSS, accounting, GPU/RDMA, and access control.
- Onboards users and maps identity groups to Slurm accounts.
- Troubleshoots jobs from login, worker, controller, and accounting pods.

Security or platform administrator:

- Requires stable UID/GID assignment.
- Requires auditable authentication and authorization.
- Requires users to be isolated from other users' homes.
- Requires a clear offboarding and key rotation process.

## Product Scope

### MVP

The MVP is a production-ready multi-user path with:

- one shared LoginSet;
- LDAP, FreeIPA, or AD identity through SSSD;
- SSH public key authentication through SSSD;
- FSS-backed `/home`;
- per-user home directory permissions;
- SSSD-backed user resolution in login pods;
- SSSD-backed user resolution in worker pods;
- SSSD/NSS-backed user resolution in the controller pod for administrator and
  controller-side Slurm commands;
- SlurmDBD accounting with user/account associations;
- GPU jobs that record the real user and account;
- no `hostNetwork`; SR-IOV VFs remain active.

### Post-MVP

- First-class chart and image support for controller SSSD/NSS, replacing the
  current custom-image and values-overlay implementation.
- Automated group-to-Slurm-account sync.
- Automated home provisioning.
- Optional per-user LoginSets for stronger login-node isolation.
- Production hardening for LDAPS, CA management, secret rotation, and
  identity-source failover.

## Current Validated State

The current OKE test cluster validates the following:

- two GPU workers are `BM.GPU4.8`;
- each worker exposes `nvidia.com/gpu: 8`;
- each worker exposes `nvidia.com/sriov-rdma-vf: 16`;
- worker pods use SR-IOV VF attachments and do not use `hostNetwork`;
- existing FSS PV `fss-pv` is bound to PVC `slurm-home`;
- `/home` is mounted in login and worker pods;
- `/home` mode `711` prevents directory listing by normal users;
- `/home/alice` mode `700` is owned by UID/GID `10001:10001`;
- `/home/bob` mode `700` is not readable by Alice;
- MariaDB and SlurmDBD accounting are running;
- `alice` is associated with Slurm account `project-a`;
- no-LDAP wrapper path was tested successfully;
- LDAP-backed SSSD path was tested successfully with disposable OpenLDAP;
- HA OpenLDAP-backed SSSD path was tested successfully end to end with `alice`;
- `alice` resolves through SSSD in login and worker pods without a local
  `/etc/passwd` entry;
- `alice` resolves through SSSD/NSS in the controller pod using the custom
  controller image and root SSSD sidecar;
- SSH as `alice` works through `sss_ssh_authorizedkeys`;
- GPU jobs submitted as `alice/project-a` allocate `gres/gpu=1`;
- `sacct` records the top-level Slurm job as `alice/project-a`.

Known limitation:

- controller-side NSS resolution currently depends on a custom controller image
  and an explicit SSSD sidecar in the values overlay. This is validated, but
  still needs first-class chart/image productization before it is a polished
  default.
- cert-manager is installed in the test cluster, but the HA OpenLDAP validation
  still uses plaintext LDAP. LDAP CA issuance, server certificates, and SSSD CA
  trust remain production hardening work.

## User Experience Requirements

### Login

P0 requirements:

- Users can SSH to a stable login service endpoint.
- Users authenticate as their own username.
- Users do not use root as their normal access path.
- Users land in `/home/$USER`.
- `whoami`, `id`, and `getent passwd $USER` show the expected user and UID/GID.
- SSH public keys can be sourced from LDAP, FreeIPA, or AD through SSSD.
- Password SSH is disabled unless explicitly enabled by policy.

Acceptance criteria:

```bash
ssh alice@<slurm-login-load-balancer>
whoami
id
pwd
getent passwd alice
```

Expected:

```text
alice
uid=10001(alice) gid=10001(alice)
/home/alice
alice:*:10001:10001:...:/home/alice:/bin/bash
```

### Slurm Job Submission

P0 requirements:

- Users can run `sinfo`, `sbatch`, `squeue`, `sacct`, and `scontrol` from the
  login pod.
- Jobs submitted from a user shell are owned by that user.
- Job working directory and output paths under `/home/$USER` work on compute
  pods.
- GPU jobs can request and receive `gres/gpu`.
- Slurm accounting records the real user and account.

Acceptance criteria:

```bash
sbatch --parsable --wait --account=project-a --gres=gpu:1 \
  --output=/home/alice/test-%j.out \
  --wrap="hostname; whoami; id; nvidia-smi -L"

sacct -j <jobid> --format=JobID,User,Account,State,ExitCode,AllocTRES,NodeList -P
```

Expected:

```text
User=alice
Account=project-a
State=COMPLETED
AllocTRES includes gres/gpu=1
```

### Home Directories

P0 requirements:

- OCI FSS is mounted at `/home` in all login pods and compute NodeSets.
- Each user has exactly one home path, `/home/$USER`.
- Per-user home directories are owned by stable numeric UID/GID values.
- Users cannot list all home directories.
- Users cannot read another user's home directory.

Required permissions:

```text
/home       root:root     711
/home/alice 10001:10001   700
/home/bob   10002:10002   700
```

Acceptance criteria:

```bash
ls -ld /home /home/alice /home/bob
ls /home
ls /home/bob
```

Expected for Alice:

- `ls -ld` shows ownership and mode;
- `ls /home` returns permission denied;
- `ls /home/bob` returns permission denied.

## Identity Requirements

### Production Identity

P0 requirements:

- Use SSSD with LDAP, FreeIPA, or Active Directory.
- If LDAP runs inside Kubernetes, use HA OpenLDAP with a single writable
  primary and read replicas rather than the disposable OpenLDAP test manifest.
- UID/GID values are stable and never reused while old files may exist.
- Login and worker pods resolve users through the same identity source.
- Controller pods resolve users through the same identity source when
  controller-side Slurm commands or accounting inspection need names instead of
  numeric IDs.
- Users can be authorized by identity group membership.
- SSH public keys can be returned by SSSD.
- Identity configuration is stored in Kubernetes Secrets, not ConfigMaps.

P1 requirements:

- SSSD config changes trigger pod rollout.
- Identity source supports LDAPS or StartTLS with CA validation.
- Bind credentials can be rotated without image rebuilds.
- Replica promotion and restore are documented and tested if OpenLDAP runs
  inside Kubernetes.

### LDAP TLS and CA Management

Current status:

- cert-manager is available in the OKE test cluster for Kubernetes certificate
  automation.
- The validated HA OpenLDAP test currently uses `ldap://` endpoints and
  `ldap_id_use_start_tls = false`.
- No LDAP `Issuer`, `ClusterIssuer`, or `Certificate` resources are part of the
  HA OpenLDAP manifests yet.

P0 production requirements:

- Production LDAP traffic from Slurm SSSD clients to the identity source uses
  LDAPS or StartTLS, not plaintext LDAP.
- If OpenLDAP runs inside Kubernetes, cert-manager is the default
  Kubernetes-native mechanism for issuing and rotating LDAP server
  certificates.
- The LDAP certificate covers every DNS name used by SSSD and admin clients,
  including:
  - `openldap-0.openldap-headless.identity.svc.cluster.local`;
  - `openldap-1.openldap-headless.identity.svc.cluster.local`;
  - `openldap-2.openldap-headless.identity.svc.cluster.local`;
  - `openldap-primary.identity.svc.cluster.local`;
  - `openldap-read.identity.svc.cluster.local`.
- OpenLDAP pods mount the server certificate, private key, and CA bundle from
  Kubernetes Secrets.
- OpenLDAP config enables TLS for client traffic and replication traffic.
- SSSD clients mount the trusted LDAP CA bundle and set `ldap_tls_cacert`.
- SSSD uses either `ldaps://...` URIs or StartTLS with
  `ldap_id_use_start_tls = true`.
- Certificate rotation causes predictable reload or rollout of affected
  OpenLDAP and Slurm SSSD pods.

P1 requirements:

- Certificate expiration is monitored.
- CA rotation supports a dual-trust window so existing and new LDAP server
  certificates can both be trusted during migration.
- Production deployments can use either an in-cluster cert-manager CA Issuer or
  an enterprise/private CA issuer, depending on platform security policy.

Acceptance criteria:

```bash
kubectl -n identity get issuer,clusterissuer,certificate
kubectl -n identity get secret <ldap-tls-secret>
kubectl -n slurm exec <login-pod> -c login -- grep -E 'ldap_uri|ldap_id_use_start_tls|ldap_tls_cacert' /etc/sssd/sssd.conf
kubectl -n slurm exec <login-pod> -c login -- getent passwd alice
```

Expected:

```text
LDAP Certificate is Ready=True
SSSD uses ldaps://... or StartTLS
SSSD has ldap_tls_cacert configured
alice resolves through SSSD with TLS enabled
```

### Small-Cluster Fallback

P1 requirements:

- A no-LDAP path can create local users in login and slurmd containers.
- UID/GID registry is stored in Git or another authoritative source.
- The fallback clearly documents drift, offboarding, and scaling limitations.

Non-production warning:

- The local-user wrapper does not give the controller consistent identity.
- It is acceptable for testing and small clusters, but not preferred for
  production.

## Slurm Accounting Requirements

P0 requirements:

- SlurmDBD is enabled.
- MariaDB is deployed and persistent.
- `AccountingStorageEnforce=associations,limits,qos` can be enabled.
- Every Slurm user has at least one account association.
- Users can submit jobs with valid accounts.
- Jobs without valid associations are rejected when enforcement is enabled.
- `sacct` shows user, account, state, exit code, elapsed time, node list, and
  GPU TRES.

P1 requirements:

- Identity groups are synced to Slurm accounts.
- Group membership changes converge to SlurmDBD associations.
- Default account selection is automated.
- QOS and limits can be mapped from groups.

## Kubernetes and OKE Requirements

P0 requirements:

- Worker NodeSet uses `node.kubernetes.io/instance-type: BM.GPU4.8`.
- Worker pods request and limit `nvidia.com/gpu: 8`.
- Worker pods request and limit `nvidia.com/sriov-rdma-vf: 16`.
- Worker pods use the `sriov-rdma-vf` NetworkAttachmentDefinition.
- Worker pods do not use `hostNetwork`.
- `/dev/infiniband` is preserved.
- `/dev/shm` is preserved.
- FSS PVC `slurm-home` is mounted at `/home`.

P0 operational caution:

- Helm values list merging must be handled carefully. Do not apply a small
  overlay that replaces `volumeMounts` or `volumes` and drops RDMA or FSS
  mounts.

## Topology Requirements

P1 requirements:

- Support Slurm Operator topology propagation for worker NodeSet pods.
- Kubernetes nodes can carry `topology.slinky.slurm.net/spec` annotations that
  map the scheduled worker pod to Slurm topology names.
- A matching `topology.yaml` can be supplied through Slurm config files so
  Slurm can place multi-node jobs with topology awareness.
- On OKE GPU/RDMA clusters, topology should represent real placement domains
  such as RDMA leaf, network block, or HPC island when those labels are
  available.
- Topology support must not require `hostNetwork`, must not remove SR-IOV VFs,
  and must not rely on static socket/core/thread hardware topology as a GPU
  autodetect workaround.

Related implementation docs:

- `slurm-operator/docs/usage/topology.md`
- `guides/slurm-operator/deploying-slinky-on-oke.md`

## Controller SSSD/NSS Requirement

Current status:

- Implemented and validated in the OKE test overlay.
- Design details are documented in `controller-sssd-nss.md`.
- The validated controller image is
  `iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04`.
- The validated overlay is
  `overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml`.

P0 requirement:

- Operator-side commands in the controller container can resolve LDAP users.

Recommended implementation:

- Build a custom `slurmctld` image with `libnss-sss`, SSSD client packages, and
  `nsswitch.conf` configured for `sss`.
- Keep `slurmctld` running as non-root UID/GID `401`.
- Run SSSD as a root sidecar in the controller pod.
- Share SSSD runtime/cache directories between the sidecar and controller
  container.
- Mount the same `sssd.conf` Secret used by login and workers.
- Add SSSD config hash to controller pod annotations for rollout on change.

Acceptance criteria:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- getent passwd alice
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- id alice
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- scontrol show job <jobid> | grep UserId
```

Expected:

```text
alice:*:10001:10001:...:/home/alice:/bin/bash
uid=10001(alice) gid=10001(alice)
UserId=alice(10001) GroupId=alice(10001)
```

Productization requirement:

- The custom-image and sidecar pattern should become a supported chart/image
  option with clear values, documented security context, and predictable rollout
  behavior when `sssd.conf` changes.

## Administrative Workflows

### Onboard User

P0 workflow:

1. Create user in LDAP, FreeIPA, or AD with stable UID/GID.
2. Add user to authorized login group.
3. Add user to one or more project groups.
4. Store or sync SSH public key in the identity source.
5. Create `/home/$USER` on FSS with correct ownership and mode.
6. Create or update SlurmDBD account association.
7. Validate SSH and a small Slurm job.

### Offboard User

P0 workflow:

1. Disable SSH/authentication in identity source.
2. Remove user from project groups.
3. Disable or remove Slurm associations according to policy.
4. Preserve, archive, or remove FSS home according to policy.
5. Confirm the user can no longer SSH or submit jobs.

### Rotate SSH Key

P0 workflow:

1. Update SSH key in LDAP, FreeIPA, or AD.
2. Invalidate SSSD cache or wait for configured cache TTL.
3. Validate SSH with the new key.
4. Confirm old key no longer works.

### Sync Groups to Slurm Accounts

P1 workflow:

1. Read identity groups.
2. Create Slurm accounts for project groups.
3. Create, update, or disable Slurm user associations.
4. Set default account.
5. Apply QOS or limits.
6. Run idempotently as a CronJob, GitOps job, or controller.

## Security Requirements

P0 requirements:

- No normal user SSH as root.
- No user workflow depends on `kubectl exec`.
- FSS home permissions prevent user-to-user home reads.
- SSSD bind credentials are stored as Kubernetes Secrets.
- Login access can be restricted by identity group.
- Password SSH is disabled unless explicitly required.
- Slurm jobs run as the submitting UID/GID.
- Worker pods keep SR-IOV configuration and do not switch to host networking.

P1 requirements:

- LDAPS or StartTLS is required for production identity.
- LDAP CA bundles are managed and rotated, preferably through cert-manager for
  in-cluster OpenLDAP.
- SSSD cache behavior is documented for offboarding.
- Audit logs can connect SSH login, Slurm job, account, and UID.

## Reliability Requirements

P0 requirements:

- Existing jobs are not broken by login pod restart.
- Slurm controller state persists across controller pod restart.
- MariaDB accounting storage persists.
- FSS remains mounted in login and worker pods.
- Workers recover to idle after Helm upgrade or pod restart.

P1 requirements:

- SSSD cache allows short identity-source interruptions without breaking
  already-started sessions.
- Identity-source outage behavior is documented.
- SSSD config changes roll the affected pods predictably.

## Observability Requirements

P0 requirements:

- Administrators can verify SSSD health in login and worker pods.
- Administrators can verify user resolution with `getent` and `id`.
- Administrators can verify SSH key lookup with `sss_ssh_authorizedkeys`.
- Administrators can verify Slurm accounting with `sacct`.
- Administrators can verify SR-IOV VF use from pod resources and annotations.

Useful checks:

```bash
getent passwd alice
id alice
sss_ssh_authorizedkeys alice
sacct -u alice
kubectl -n slurm get pod slurm-worker-gpu-b4-0 -o yaml
```

## Architecture

Production architecture with in-cluster HA OpenLDAP:

![Multi-user Slurm on OKE architecture](images/multi-user-slurm-oke-architecture.svg)

If the production identity source is external FreeIPA, Active Directory, or
managed LDAP, replace the `identity` namespace in the diagram with that external
directory service. The Slurm-side SSSD, FSS, and SlurmDBD flows remain the same.

## Release Plan

### Milestone 1: Validated Multi-User Test

Status: complete.

Delivered:

- FSS `/home`;
- no-LDAP fallback test;
- SlurmDBD accounting;
- SSSD with disposable OpenLDAP;
- SSH as Alice via SSSD;
- controller-side SSSD/NSS resolution through the custom controller image and
  root SSSD sidecar;
- GPU job with accounting;
- SR-IOV VFs preserved.

### Milestone 2: Production Identity Integration

Deliver:

- production `sssd.conf` for LDAP, FreeIPA, or AD;
- if LDAP runs inside Kubernetes, HA OpenLDAP with one writable primary and
  read replicas;
- cert-manager-backed LDAP server certificates and CA bundle distribution for
  in-cluster OpenLDAP;
- LDAPS or StartTLS with SSSD CA validation;
- production SSH key attribute mapping;
- access control groups;
- home provisioning process;
- Slurm account association process.

Exit criteria:

- real user can SSH with production identity;
- real user can submit a GPU job;
- `sacct` records user and account;
- offboarding and key rotation are validated.
- LDAP certificate rotation and SSSD CA trust are validated.
- if in-cluster OpenLDAP is used, read replica failover, primary restore, and
  deliberate replica promotion are validated.

### Milestone 3: Controller Name Resolution

Status: validated in the OKE overlay; productization remains.

Deliver:

- supported `slurmctld` image build with NSS/SSSD client support;
- supported SSSD sidecar values for the controller pod;
- controller `sssd.conf` Secret mount;
- pod rollout on SSSD config changes;
- validation that controller-side commands resolve `alice(10001)`.

Validated implementation:

- image:
  `iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04`;
- overlay:
  `overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml`.

### Milestone 3.5: End-to-End LDAP/SSSD Runbook

Status: documented.

Deliver:

- disposable OpenLDAP Kubernetes manifest for validation only;
- HA OpenLDAP design for the production in-cluster LDAP option;
- Slurm Helm values overlay that consumes the SSSD Secret;
- operator-node instructions using instance principal auth;
- validation for LDAP contents, NSS lookup, SSH login, FSS home isolation,
  SlurmDBD associations, GPU job submission, and `sacct`;
- clear production replacement checklist for LDAP, FreeIPA, or AD.

Primary runbook:

```text
/Users/opastirm/Documents/Repos/slurm-operator/docs/usage/user-identity-home-and-accounting.md
```

Related LDAP option docs:

```text
/Users/opastirm/Documents/Repos/slurm-operator/docs/usage/ldap-sssd-disposable-test.md
/Users/opastirm/Documents/Repos/slurm-operator/docs/usage/ldap-sssd-ha-openldap.md
```

Guide repo assets:

```text
manifests/openldap-test-identity.yaml
overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml
```

### Milestone 4: Automation

Deliver:

- identity group to Slurm account sync;
- user home provisioning automation;
- GitOps or controller-based reconciliation;
- documented operational runbooks.

## Risks and Mitigations

Risk: Helm list replacement drops RDMA, VF, or FSS mounts.  
Mitigation: maintain merged concrete values files and validate rendered values
before upgrade.

Risk: UID/GID drift causes wrong FSS ownership.  
Mitigation: use LDAP, FreeIPA, or AD as the authoritative UID/GID source and
never reuse IDs.

Risk: SSSD cache delays offboarding.  
Mitigation: document cache TTLs and provide a cache-invalidation procedure.

Risk: Controller name resolution requires weakening security.  
Mitigation: run SSSD as a root sidecar and keep `slurmctld` non-root.

Risk: Identity-source outage blocks new logins.  
Mitigation: configure SSSD cache behavior and monitor identity availability.

Risk: LDAP certificate expiry or CA rotation breaks login and user resolution.
Mitigation: use cert-manager for certificate lifecycle, monitor expiration,
document CA rotation, and validate SSSD trust after rotation.

Risk: In-cluster OpenLDAP primary failure blocks onboarding and key rotation.  
Mitigation: serve reads from replicas, back up LDAP data and config, and keep a
tested restore and deliberate replica-promotion runbook.

Risk: FSS NFS permissions do not protect against root clients.  
Mitigation: do not give users sudo in login pods, avoid user root jobs, restrict
FSS export access, and use root-squash or stronger NFS controls where required.

## Open Questions

- Which production identity source will be used: LDAP, FreeIPA, or AD?
- If LDAP runs inside Kubernetes, which OpenLDAP image, storage class,
  certificate issuer, backup target, and primary promotion process will be
  used?
- Which LDAP attribute will store SSH public keys?
- What is the required group-to-account mapping model?
- Should controller-side username resolution be a hard launch requirement?
- What is the offboarding policy for FSS home directories?
- What are the required QOS and account limits?
- Should per-user LoginSets be offered for privileged or high-isolation users?

## Launch Acceptance Checklist

- A production user can SSH to the login LoadBalancer.
- `whoami`, `id`, and `getent passwd` show the expected identity.
- Controller-side `getent passwd`, `id`, and relevant Slurm commands resolve
  the same user identity.
- User lands in `/home/$USER` on FSS.
- User cannot list `/home` or read another user's home.
- User can submit CPU and GPU jobs.
- Job output lands in `/home/$USER`.
- `squeue`, `scontrol`, and `sacct` show the real user from the login pod.
- `sacct` records the expected Slurm account.
- Jobs without valid associations are rejected when enforcement is enabled.
- Worker pods use `BM.GPU4.8`, GPUs, SR-IOV VFs, and no `hostNetwork`.
- Production identity uses LDAPS or StartTLS.
- If OpenLDAP runs inside Kubernetes, cert-manager issues LDAP server
  certificates, SSSD trusts the LDAP CA bundle, and certificate rotation has
  been tested.
- If OpenLDAP runs inside Kubernetes, LDAP runs as a StatefulSet with one
  writable primary, read replicas, tested backup/restore, and documented
  primary promotion.
- User onboarding, offboarding, and key rotation are documented and tested.
