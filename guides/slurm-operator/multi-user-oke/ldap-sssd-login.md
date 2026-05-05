# LDAP, FreeIPA, or Active Directory Login With SSSD

This is the preferred identity model for production.

The login pod should resolve users through SSSD and authenticate SSH through
PAM. Users then SSH to the login Service as themselves:

```bash
ssh alice@<slurm-login-load-balancer>
```

When `alice` runs `sbatch`, the Slurm job is submitted as `alice`.

## SSSD Secret

Create an `sssd.conf` for your directory service and store it in a Kubernetes
Secret. Example shape:

```ini
[sssd]
config_file_version = 2
services = nss,pam,ssh
domains = LDAP

[nss]
filter_users = root,slurm
filter_groups = root,slurm

[pam]

[domain/LDAP]
id_provider = ldap
auth_provider = ldap
access_provider = ldap

ldap_uri = ldaps://ldap.example.com
ldap_search_base = dc=example,dc=com

cache_credentials = true
enumerate = false
```

Create the Secret:

```bash
kubectl -n slurm create secret generic site-sssd-conf \
  --from-file=sssd.conf=./sssd.conf
```

Use a bind DN, bind password, CA bundle, and TLS settings if your directory
requires them. Store sensitive SSSD material in Secrets, not ConfigMaps.

## Helm Values

Reference the SSSD Secret from the Slurm chart:

```yaml
sssd:
  secretRef:
    name: site-sssd-conf
    key: sssd.conf

loginsets:
  slinky:
    enabled: true
    replicas: 1
    service:
      spec:
        type: LoadBalancer
```

The chart renders `spec.sssdConfRef` on the `LoginSet`, and the operator mounts
that file into the login pod.

For worker-side name resolution during jobs, enable the NodeSet SSH block so
the current chart also mounts `sssd.conf` into slurmd pods and starts SSSD:

```yaml
nodesets:
  gpu-b4:
    ssh:
      enabled: true
```

This does not make worker SSH the primary user workflow. Users should still SSH
to the login service. In the current chart, this is the switch that enables
SSSD wiring in worker pods.

## SSH Keys From LDAP

If SSH public keys are stored in the directory, add the matching SSSD LDAP
attribute mapping and configure SSH to ask SSSD for keys:

```yaml
loginsets:
  slinky:
    extraSshdConfig: |
      AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys
      AuthorizedKeysCommandUser nobody
      PasswordAuthentication no
```

Keep `PasswordAuthentication no` if the cluster should only allow SSH keys.
Remove it only if password authentication is explicitly required and PAM policy
is ready for it.

## Access Control

Prefer group-based access control in SSSD. For example, allow only members of a
cluster login group:

```ini
[domain/LDAP]
access_provider = simple
simple_allow_groups = slurm-users
```

Then map the same or related groups to Slurm accounts in the accounting sync
process.

## Validation

After upgrading the chart, test from a workstation:

```bash
ssh alice@<slurm-login-load-balancer>
```

Inside the login pod:

```bash
id
getent passwd alice
getent group project-a
pwd
ls -ld /home/alice
sbatch --wrap="hostname"
squeue -u alice
```

The username and UID/GID returned by `id` should match the owner of
`/home/alice`.

## OKE Test Result

This path was validated on the live OKE cluster with a disposable OpenLDAP
service:

- `alice` was absent from `/etc/passwd`;
- `getent passwd alice` resolved `alice:*:10001:10001:...:/home/alice:/bin/bash`;
- `id alice` included `project-a` from LDAP;
- `sss_ssh_authorizedkeys alice` returned Alice's test SSH public key;
- SSH as `alice` worked with `AuthorizedKeysFile none`;
- a `--gres=gpu:1` job completed and wrote output to `/home/alice`;
- `sacct` recorded the job as `alice/project-a`.

Controller caveat: the current controller image does not include SSSD/NSS
integration, so `scontrol` run inside the controller still shows numeric
UID/GID. User-facing commands from the login pod and job execution on workers
resolve LDAP names correctly.
