# Local Users Without LDAP

Use this model only when LDAP, FreeIPA, or Active Directory is not available and
the user count is modest.

The goal is still the traditional Slurm model:

- users SSH as themselves;
- users have stable POSIX UID/GID values;
- `/home/$USER` exists on FSS;
- SlurmDBD has user/account associations for each user.

## User Registry

Keep one source of truth in Git:

```yaml
users:
  - name: alice
    uid: 10001
    gid: 10001
    groups:
      - project-a
    shell: /bin/bash
    home: /home/alice
    sshAuthorizedKeys:
      - ssh-ed25519 AAAA...
    slurm:
      account: project-a
      defaultAccount: project-a

  - name: bob
    uid: 10002
    gid: 10002
    groups:
      - project-a
    shell: /bin/bash
    home: /home/bob
    sshAuthorizedKeys:
      - ssh-ed25519 AAAA...
    slurm:
      account: project-a
      defaultAccount: project-a
```

Never reuse UID values while old files may still exist on FSS.

## Implementation Options

### Option 1: Custom Login Image

Build a login image from `ghcr.io/slinkyproject/login` that creates users and
groups:

```Dockerfile
FROM ghcr.io/slinkyproject/login:25.11-ubuntu24.04

USER root

RUN groupadd -g 10001 alice \
 && useradd -u 10001 -g 10001 -d /home/alice -s /bin/bash alice \
 && groupadd -g 10002 bob \
 && useradd -u 10002 -g 10002 -d /home/bob -s /bin/bash bob
```

Then point the LoginSet at the custom image:

```yaml
loginsets:
  slinky:
    login:
      image:
        repository: <your-registry>/slinky-login-users
        tag: 25.11-ubuntu24.04
```

This is simple and predictable, but every user change requires an image rebuild
and login pod rollout.

If you use a wrapper entrypoint for testing instead of a custom image, apply it
only as a short-lived validation path. The current test wrapper creates `alice`
in login and slurmd containers, which is enough for SSH, job execution, and
`sacct`, but the controller still lacks the user unless it also has the same
identity source. In that case, `scontrol` from the controller may show numeric
UIDs even though user-facing commands from the login pod resolve names.

### Option 2: User Provisioning Controller

Build a small controller or CI job that:

- reads the Git user registry;
- creates `/home/$USER` on FSS;
- writes `/home/$USER/.ssh/authorized_keys`;
- creates or updates users in a custom login image or mounted identity source;
- runs `sacctmgr` to create Slurm associations;
- restarts login pods when identity data changes.

This is more work, but it is the cleaner no-LDAP path for long-lived clusters.

## Home Directory Setup

For each user:

```bash
mkdir -p /home/alice/.ssh
chown -R 10001:10001 /home/alice
chmod 700 /home/alice
chmod 700 /home/alice/.ssh
chmod 600 /home/alice/.ssh/authorized_keys
```

Use numeric UID/GID values when provisioning homes from an admin pod if local
names are not available there.

## Slurm Accounting Setup

For each user:

```bash
sacctmgr add account project-a Description="Project A" Organization=example -i
sacctmgr add user name=alice account=project-a defaultaccount=project-a -i
```

The Linux user and the Slurm accounting user names must match unless you have a
very deliberate mapping layer.

## Tradeoffs

Pros:

- No external identity service.
- Git can review and audit user changes.
- Works for small teams.
- Still supports normal SSH and Slurm commands.

Cons:

- You own UID/GID allocation.
- User changes require automation or image rebuilds.
- Offboarding, key rotation, and group changes can drift.
- This becomes identity infrastructure as the cluster grows.

If the cluster will have many users or project groups, prefer SSSD backed by
LDAP, FreeIPA, or Active Directory.
