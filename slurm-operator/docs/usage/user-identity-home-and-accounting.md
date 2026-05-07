# User Identity, Home Directories, and Accounting

## Overview

Slurm on Kubernetes should present the same user-facing model as a traditional
Slurm cluster:

- users SSH into a login node;
- shells run as the real user, not as `root` or `slurm`;
- `/home/$USER` is available on login and compute nodes;
- jobs are submitted under the real Slurm user;
- Slurm accounting records and limits apply to that user.

In this operator, a `LoginSet` creates homogeneous login pods behind a Service.
It does not model users directly. User identity is provided by the operating
system identity layer inside the login pod, typically SSSD/PAM/NSS, while Slurm
accounting is managed separately through SlurmDBD associations.

## Shape-Specific Runbooks

Before applying Slurm values, pick the runbook section for the exact OKE GPU
shape:

| Shape | Runbook section | Main difference |
| --- | --- | --- |
| `BM.GPU4.8` | [Shape: BM.GPU4.8](oke-slurm-shape-runbooks.md#shape-bmgpu48) | SR-IOV/VF pod networking, 8 GPUs, 16 VFs, BM.GPU4.8 NUMA-shaped NVML autodetect path |
| `BM.GPU.GB200.4` | [Shape: BM.GPU.GB200.4](oke-slurm-shape-runbooks.md#shape-bmgpugb2004) | hostNetwork, arm64 worker, 4 GPUs, worker sshd on `Port 2222` |
| `BM.GPU.GB300.4` | [Shape: BM.GPU.GB300.4](oke-slurm-shape-runbooks.md#shape-bmgpugb3004) | hostNetwork, arm64 worker, 4 GPUs, `AutoDetect=nvml` only, worker sshd on `Port 2222` |

The identity model is the same for these shapes: users come from LDAP through
SSSD, `/home` comes from FSS, and SlurmDBD records the submitting user. The
worker values are not interchangeable.

## Recommended Architecture

For production clusters, use:

1. A shared `LoginSet` for normal SSH access.
2. LDAP, FreeIPA, or Active Directory through SSSD for POSIX identities.
3. OCI File Storage, or another shared POSIX filesystem, mounted at `/home`.
4. SlurmDBD accounting with explicit user/account associations.
5. A sync process that maps identity groups to Slurm accounts, QOS, and default
   accounts.

Per-user login pods are optional. They are useful for stronger login-node
isolation, but they are not required for normal Slurm behavior.

## How SSH Into Login Pods Works

The login pod must be able to resolve and authenticate the SSH user as a Linux
account. That means the pod needs a source for:

- username;
- UID and GID;
- supplementary groups;
- login shell;
- home directory;
- SSH keys or password authentication policy.

With SSSD, the login pod resolves those details from LDAP, FreeIPA, or Active
Directory. With a local or GitOps-managed user model, the same information must
be provided through local passwd/group data, mounted configuration, generated
image content, or another NSS/PAM mechanism.

When a user runs `sbatch`, `srun`, or `squeue` from the login pod, the command
runs as that user. Slurm can then record the submitter correctly.

## Home Directories

Mount the same shared filesystem at `/home` in both login pods and compute pods.
For OCI, OCI File Storage Service (FSS) is a natural fit because it provides a
shared NFS filesystem.

Example chart shape:

```yaml
loginsets:
  slinky:
    enabled: true
    login:
      volumeMounts:
        - name: home
          mountPath: /home
    podSpec:
      volumes:
        - name: home
          nfs:
            server: <fss-mount-target-ip-or-dns>
            path: /slurm-home

nodesets:
  slinky:
    slurmd:
      volumeMounts:
        - name: home
          mountPath: /home
    podSpec:
      volumes:
        - name: home
          nfs:
            server: <fss-mount-target-ip-or-dns>
            path: /slurm-home
```

Create one directory per user:

```console
/home
/home/alice
/home/bob
```

Recommended ownership and permissions:

```bash
chown alice:alice /home/alice
chmod 700 /home/alice
chown bob:bob /home/bob
chmod 700 /home/bob
chmod 711 /home
```

`chmod 700` prevents other normal users from reading a user's home directory.
`chmod 711 /home` allows users to traverse to their own known path without
listing all home directory names.

This relies on stable UID/GID values. LDAP, FreeIPA, or Active Directory is the
cleanest way to keep those values consistent across login pods, compute pods,
and the shared filesystem.

## Slurm Accounting

Linux identity and Slurm accounting are separate.

The login pod may know that `alice` is UID `10001`, but SlurmDBD also needs an
accounting association for `alice` before accounting, limits, fairshare, and QOS
policy are useful.

Example:

```bash
sacctmgr add account project-a Description="Project A" Organization=example
sacctmgr add user name=alice account=project-a defaultaccount=project-a
sacctmgr add user name=bob account=project-a defaultaccount=project-a
```

If the cluster should reject jobs from users without associations or enforce
limits, configure Slurm accounting enforcement accordingly, for example with
association and limit enforcement.

## Option A: Shared LoginSet With LDAP, FreeIPA, or AD

This is the closest model to a traditional Slurm installation.

Pros:

- Users SSH into a shared login service as themselves.
- Slurm jobs are submitted under the real username.
- UID, GID, groups, shell, and SSH keys are centrally managed.
- `/home/$USER` permissions work naturally with a shared POSIX filesystem.
- Slurm accounting can be automated from identity groups.
- Compute pods do not necessarily need direct LDAP access if Slurm client IDs
  and `nss_slurm` cover the required compute-side identity resolution.

Cons:

- Requires operating and securing LDAP, FreeIPA, or Active Directory.
- Requires SSSD configuration, TLS/bind credentials, and access policy.
- Slurm accounting associations still need to be created and kept in sync.
- Shared login pods provide normal Unix isolation, not hard tenant isolation.

Use this as the default production option.

## Option B: Shared LoginSet Without LDAP

This keeps the traditional Slurm experience but uses a GitOps-managed local user
registry instead of LDAP.

The registry should define:

- username;
- UID and GID;
- groups;
- shell;
- home path;
- SSH public keys;
- Slurm account and default account.

A job or controller should then:

- render passwd/group or SSSD files configuration;
- create `/home/$USER` on FSS with the correct owner and mode;
- install SSH authorized keys;
- create or update SlurmDBD associations with `sacctmgr`;
- roll login pods when user configuration changes.

Pros:

- No LDAP service required.
- Works for small clusters or controlled internal environments.
- Still gives users a normal SSH and Slurm CLI experience.
- User configuration can be reviewed through Git.

Cons:

- You own UID/GID allocation and lifecycle management.
- Offboarding, SSH key rotation, group changes, and home retention need careful
  automation.
- Scaling this to many users becomes identity-management work.
- Password authentication is awkward; SSH keys are easier.

Use this when LDAP is unavailable and the user count is modest.

## Option C: Per-User LoginSets

Each user gets a dedicated `LoginSet`, typically with `replicas: 1`, its own
Service, and an SSH policy such as:

```text
AllowUsers alice
```

The pod can mount all of `/home` or only that user's home path, depending on the
storage layout.

Pros:

- Stronger isolation for login-node CPU, memory, processes, and temp files.
- Easy to disable one user's login environment.
- Allows per-user pod scheduling, quotas, labels, and network policy.
- Can be useful for sensitive users, projects, demos, or notebook-like access.

Cons:

- Does not replace POSIX identity.
- Does not replace SlurmDBD accounting associations.
- Adds one or more Kubernetes objects per user.
- Per-user Services or LoadBalancers can be expensive and harder to operate.
- Less like a conventional shared Slurm login node.

Use this selectively, not as the baseline design.

## Option D: Kubernetes `SlurmUser` Controller

A Kubernetes-native controller can own the user lifecycle while still producing
normal Slurm behavior.

Example custom resource:

```yaml
apiVersion: slinky.slurm.net/v1alpha1
kind: SlurmUser
metadata:
  name: alice
spec:
  uid: 10001
  gid: 10001
  groups:
    - project-a
  sshAuthorizedKeys:
    - ssh-ed25519 AAAA...
  home:
    path: /home/alice
    storage: fss
  accounting:
    account: project-a
    defaultAccount: project-a
    qos:
      - normal
```

The controller could:

- allocate or validate UID/GID values;
- create home directories on FSS;
- render identity data for login pods;
- manage SSH keys;
- create Slurm accounting associations;
- optionally create per-user LoginSets, namespaces, quotas, or network policy.

Pros:

- Kubernetes-native and GitOps-friendly.
- Can work without LDAP.
- Centralizes onboarding and offboarding.
- Provides a clean place to automate Slurm accounting.

Cons:

- This is identity infrastructure and needs a careful security model.
- Must handle UID reuse, deleted users, retained homes, and failed accounting
  operations.
- More custom code and more responsibility than using LDAP/FreeIPA/AD.

Use this when the cluster needs Kubernetes-native user lifecycle management and
LDAP is not available or not desired.

## LDAP Deployment Options

Keep two LDAP paths documented and separate:

- [LDAP/SSSD Disposable Test Runbook](ldap-sssd-disposable-test.md) deploys the
  current single-pod `openldap-test` validation environment. Use it to prove
  SSSD, SSH login, FSS homes, Slurm accounting, and GPU job attribution end to
  end. Do not use it as the production identity service.
- [HA OpenLDAP for Slurm Identity on Kubernetes](ldap-sssd-ha-openldap.md)
  describes the production in-cluster LDAP direction: a StatefulSet with one
  writable primary and read replicas, TLS, replication, backups, and SSSD
  failover.

The Slurm-side integration stays the same for both options: login, worker, and
controller pods consume an SSSD Secret through the Slurm chart `sssd.secretRef`
values. The difference is only the identity service behind `sssd.conf`.

## Practical Recommendation

Start with:

- one shared `LoginSet`;
- SSSD backed by LDAP, FreeIPA, or Active Directory;
- OCI FSS mounted at `/home` in login and compute pods;
- SlurmDBD accounting;
- automated group-to-account sync.

If LDAP is not available, use a GitOps-managed POSIX user registry and automate
home directory creation plus `sacctmgr` updates. Add per-user LoginSets only for
users or projects that need stronger login-node isolation.
