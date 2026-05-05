# HA OpenLDAP for Slurm Identity on Kubernetes

Use this design when LDAP must run inside Kubernetes. This is the production
direction for an in-cluster LDAP service.

Keep the [LDAP/SSSD Disposable Test Runbook](ldap-sssd-disposable-test.md)
separate. It validates the Slurm and SSSD path, but it is not an HA identity
service.

Start with the [OKE Slurm Shape Runbooks](oke-slurm-shape-runbooks.md) before
applying manifests. `BM.GPU4.8` and `BM.GPU.GB200.4` use different worker
networking, node architecture, GPU counts, and Slurm GPU-detection behavior.

## Shape-Specific Entry Points

Use this LDAP design as the shared identity layer, but deploy Slurm from the
shape-specific section that matches the GPU workers:

| Shape | Start here | Worker path |
| --- | --- | --- |
| `BM.GPU4.8` | [Shape: BM.GPU4.8](oke-slurm-shape-runbooks.md#shape-bmgpu48) | SR-IOV/VF pod networking, 8 A100 GPUs, `AutoDetect=nvml` with NUMA-shaped dynamic-node topology |
| `BM.GPU.GB200.4` | [Shape: BM.GPU.GB200.4](oke-slurm-shape-runbooks.md#shape-bmgpugb2004) | hostNetwork, 4 GB200 GPUs, arm64 worker image, worker sshd on `Port 2222` |

Do not copy the GB200 hostNetwork values, `Port 2222` override, or arm64-only
assumptions into the BM.GPU4.8 SR-IOV path.

## Recommendation

Run OpenLDAP as a **single writable primary with read replicas**:

```text
identity namespace

openldap-0
  role: primary
  accepts writes
  stores authoritative LDAP DB

openldap-1
  role: read replica
  pulls from openldap-0 with syncrepl
  serves SSSD reads

openldap-2
  role: read replica
  pulls from openldap-0 with syncrepl
  serves SSSD reads
```

This model is simpler and safer than active/active LDAP for Slurm identity.
User and group writes are low volume, but UID/GID correctness is critical. A
single write path avoids most conflict cases and makes promotion, backup, and
audit easier to reason about.

## Architecture

```text
admin/onboarding job
  -> openldap-primary.identity.svc
  -> openldap-0

SSSD in Slurm login pods
  -> openldap-0/openldap-1/openldap-2

SSSD in Slurm worker pods
  -> openldap-0/openldap-1/openldap-2

SSSD/NSS in Slurm controller pod
  -> openldap-0/openldap-1/openldap-2

openldap-1 and openldap-2
  <- replicate from openldap-0
```

Keep LDAP independent from Slurm:

- LDAP owns POSIX users, UID/GID, groups, home paths, shells, and SSH public
  keys.
- SSSD exposes those identities to Linux inside Slurm pods.
- SlurmDBD owns Slurm accounts, associations, QOS, limits, and accounting.
- OCI FSS owns shared `/home`.

## Kubernetes Resources

Use these resources for the LDAP service:

| Resource | Purpose |
| --- | --- |
| `Namespace/identity` | Keeps identity separate from Slurm workloads |
| `StatefulSet/openldap` | Stable pod names and stable per-replica storage |
| `Service/openldap-headless` | Stable DNS for `openldap-0`, `openldap-1`, and `openldap-2` |
| `Service/openldap-primary` | Write endpoint that selects only `openldap-0` |
| `Service/openldap-read` | Read endpoint for SSSD clients, or use direct replica URIs |
| `Secret/openldap-admin` | Admin credentials and replication credentials |
| `Secret/openldap-tls` | Server certificate and private key |
| `ConfigMap/openldap-config` | Non-secret LDAP config and bootstrap templates |
| `PersistentVolumeClaim` per pod | LDAP database and config storage |
| `PodDisruptionBudget` | Avoid voluntary disruption of too many replicas |
| `NetworkPolicy` | Restrict LDAP access to Slurm pods and admin jobs |

Use OCI Block Volume PVCs for LDAP state. Do not store the LDAP database on FSS.
FSS remains the right backing store for user home directories, not for LDAP's
database files.

## Shape-Specific Deployment Notes

### BM.GPU4.8

`BM.GPU4.8` workers are `amd64` in the tested environment. The existing
BM.GPU4.8 path uses SR-IOV/VF pod networking and 8 GPUs per node. Do not copy
the GB200 hostNetwork sshd port override into this path.

The BM.GPU4.8 `AutoDetect=nvml` investigation is tracked separately in
`oke-bm-gpu4-autodetect-test-log.md`. The working path uses
`AutoDetect=nvml` with NUMA-shaped dynamic-node topology:
`Parameters=numa_node_as_socket`, `SocketsPerBoard=8`, `CoresPerSocket=8`,
`ThreadsPerCore=1`, and `CPUs=64`. Earlier attempts without that NodeSet
topology failed because GPU core affinity did not match Slurm socket
boundaries.

### BM.GPU.GB200.4

On GB200 OKE clusters the GPU worker node is `arm64`. Any container scheduled
there must have a `linux/arm64` image. For the GB200 guide, keep Slurm worker
images multi-platform, for example `linux/amd64` plus `linux/arm64`, because
the same tag may be reused across CPU control-plane nodes and GB200 worker
nodes.

Identity services such as OpenLDAP, MariaDB, SSSD helper pods, and Slurm
controller/login pods can be pinned to CPU nodes if their images have only been
validated for `linux/amd64`. If you remove those node selectors or schedule
identity services on the GB200 node, validate every image manifest for
`linux/arm64` first.

## Services

Use three service patterns:

```text
openldap-headless.identity.svc.cluster.local
  stable StatefulSet DNS for replication and direct client failover

openldap-primary.identity.svc.cluster.local
  write endpoint for ldapadd, ldapmodify, onboarding jobs, and key rotation

openldap-read.identity.svc.cluster.local
  read endpoint for LDAP clients that do not use a direct replica URI list
```

For SSSD, prefer explicit replica URIs so failover behavior is visible in the
client config:

```ini
ldap_uri = ldaps://openldap-0.openldap-headless.identity.svc.cluster.local,ldaps://openldap-1.openldap-headless.identity.svc.cluster.local,ldaps://openldap-2.openldap-headless.identity.svc.cluster.local
```

For writes, always use the primary service:

```bash
ldapadd -H ldaps://openldap-primary.identity.svc.cluster.local ...
ldapmodify -H ldaps://openldap-primary.identity.svc.cluster.local ...
```

## Replication

Configure `openldap-1` and `openldap-2` as read replicas using `syncrepl` from
`openldap-0`.

The desired behavior is:

- writes are accepted only by `openldap-0`;
- replicas pull changes from `openldap-0`;
- replicas serve read traffic for SSSD;
- replicas do not accept normal admin writes;
- promotion from replica to primary is an explicit administrator action.

Avoid active/active multi-provider replication for the first production version.
It improves write availability, but it also adds conflict behavior that is not
worth the risk for UID/GID and group identity data.

For the `helm-openldap/openldap-stack-ha` chart, validate that the primary data
database has the `syncprov` overlay, not only the config database. The replicas
may bind and search the primary successfully but remain empty if
`olcOverlay=syncprov,olcDatabase={2}mdb,cn=config` is missing on the primary.
The GB200 test manifest includes
`oke-gb200-ha-openldap-primary-syncprov.ldif` for this check/fix.

## SSSD Configuration

Slurm pods should use the HA LDAP endpoints through SSSD:

```ini
[sssd]
config_file_version = 2
services = nss,pam,ssh
domains = LDAP

[nss]
filter_users = root,slurm
filter_groups = root,slurm

[pam]

[ssh]

[domain/LDAP]
id_provider = ldap
auth_provider = ldap
access_provider = ldap
entry_cache_timeout = 60

ldap_uri = ldaps://openldap-0.openldap-headless.identity.svc.cluster.local,ldaps://openldap-1.openldap-headless.identity.svc.cluster.local,ldaps://openldap-2.openldap-headless.identity.svc.cluster.local
ldap_search_base = dc=example,dc=org
ldap_user_search_base = ou=People,dc=example,dc=org
ldap_group_search_base = ou=Groups,dc=example,dc=org

ldap_schema = rfc2307
ldap_id_mapping = false
ldap_tls_cacert = /etc/sssd/ca/site-ca.crt

ldap_default_bind_dn = cn=sssd-reader,ou=ServiceAccounts,dc=example,dc=org
ldap_default_authtok_type = password
ldap_default_authtok = REPLACE_WITH_SECRET

ldap_user_object_class = posixAccount
ldap_user_name = uid
ldap_user_uid_number = uidNumber
ldap_user_gid_number = gidNumber
ldap_user_home_directory = homeDirectory
ldap_user_shell = loginShell
ldap_user_ssh_public_key = sshPublicKey

ldap_group_object_class = posixGroup
ldap_group_name = cn
ldap_group_gid_number = gidNumber
ldap_group_member = memberUid

cache_credentials = true
enumerate = false
```

Production values must not put bind passwords directly in a checked-in file.
Render the final `sssd.conf` from Kubernetes Secrets, an external secrets
operator, or another approved secret-management process.

## Slurm Integration

The Slurm chart should consume the SSSD config through the existing `sssd`
Secret reference:

```yaml
sssd:
  secretRef:
    name: site-sssd-ldap-conf
    key: sssd.conf
```

The same identity source should be available to:

- login pods, for SSH login and user shells;
- worker pods, for job UID/GID and user resolution;
- controller pod, for controller-side commands and accounting inspection.

The Slurm controller can use the validated controller-side SSSD/NSS pattern:

- custom `slurmctld` image with `libnss-sss` and SSSD client support;
- root SSSD sidecar;
- shared SSSD runtime and cache volumes;
- same `sssd.conf` Secret mounted into the sidecar.

## Home Directories

LDAP does not create home directories. Keep user homes on OCI FSS:

```text
/home        root:root     711
/home/alice 10001:10001   700
/home/bob   10002:10002   700
```

Onboarding must create or repair `/home/$USER` with the UID/GID from LDAP.
Workers and login pods must mount the same FSS PVC at `/home`.

## Slurm Accounting

LDAP identity is not enough for Slurm accounting. Each LDAP user must have a
SlurmDBD association:

```bash
sacctmgr -i add account project-a Description="Project A" Organization=example
sacctmgr -i add user name=alice account=project-a defaultaccount=project-a
```

In production, automate group-to-account sync:

```text
LDAP group project-a
  -> Slurm account project-a
  -> Slurm association alice/project-a
```

## Failure Behavior

| Failure | Expected behavior | Operator action |
| --- | --- | --- |
| One read replica fails | SSSD fails over to another LDAP URI | Replace or restart the replica |
| Primary fails but replicas are healthy | Existing reads and cached logins may continue; writes pause | Restore primary or promote a replica |
| Primary storage is lost | Writes stop; replicas may still have data | Restore from backup or promote a current replica deliberately |
| Replication lag | New users, SSH keys, or groups may not appear on replicas immediately | Check `syncrepl` state and replica logs |
| LDAP unavailable | New logins may fail; cached users may continue for a limited time | Restore LDAP and monitor SSSD cache behavior |

Primary promotion must be a deliberate runbook, not an automatic side effect of
Kubernetes rescheduling. Automatic write failover can create split-brain unless
the promotion mechanism is carefully controlled.

## Backup and Restore

Back up both LDAP data and configuration:

```bash
slapcat -n 0 > config.ldif
slapcat -n 1 > data.ldif
```

Store backups outside the cluster and test restore regularly. A backup is not
valid until restore has been tested into a clean LDAP instance and Slurm SSSD
clients can resolve users from it.

Minimum restore test:

```bash
ldapsearch -x -H ldaps://openldap-primary.identity.svc.cluster.local \
  -D cn=sssd-reader,ou=ServiceAccounts,dc=example,dc=org \
  -W \
  -b dc=example,dc=org \
  '(uid=alice)'
```

Then validate from Slurm:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- getent passwd alice
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- id alice
```

## Security Requirements

Production OpenLDAP in Kubernetes must use:

- `ldaps://` or StartTLS;
- CA bundle mounted into SSSD pods;
- no anonymous bind for user data;
- read-only bind DN for SSSD;
- separate admin bind DN for onboarding;
- Kubernetes Secrets for bind credentials;
- NetworkPolicies limiting LDAP access;
- Pod anti-affinity across nodes;
- PodDisruptionBudget;
- regular backup and restore tests;
- explicit UID/GID allocation policy;
- no UID/GID reuse while old files may exist.

## Operational Checks

Check LDAP pods:

```bash
kubectl -n identity get pods -l app.kubernetes.io/name=openldap -o wide
kubectl -n identity get pvc
kubectl -n identity get svc
```

Check LDAP reads:

```bash
ldapsearch -x -H ldaps://openldap-read.identity.svc.cluster.local \
  -D cn=sssd-reader,ou=ServiceAccounts,dc=example,dc=org \
  -W \
  -b dc=example,dc=org \
  '(uid=alice)'
```

Check Slurm-side identity:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- getent passwd alice
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- id alice

LOGIN_POD="$(kubectl -n slurm get pods -o name \
  | grep '^pod/slurm-login-slinky-' \
  | head -1 \
  | cut -d/ -f2)"

kubectl -n slurm exec "$LOGIN_POD" -c login -- getent passwd alice
kubectl -n slurm exec "$LOGIN_POD" -c login -- sss_ssh_authorizedkeys alice
```

Check accounting:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  sacctmgr -nP show assoc user=alice format=User,Account,DefaultQOS,QOS
```

## Open Items Before Implementation

- Choose the OpenLDAP container image and version.
- Decide whether to use dynamic `cn=config`, static config, or a generated
  config mounted at startup.
- Define the exact LDAP suffix, for example `dc=example,dc=org`.
- Define UID/GID ranges and ownership policy.
- Define the SSH public key attribute, for example `sshPublicKey`.
- Decide how certificates are issued and rotated.
- Decide how bind credentials are generated and rotated.
- Write the replica promotion and restore runbooks.
- Define the onboarding automation that creates LDAP users, FSS homes, and
  SlurmDBD associations.
