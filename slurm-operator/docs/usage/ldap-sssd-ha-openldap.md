# HA OpenLDAP for Slurm Identity on Kubernetes

Use this design when LDAP must run inside Kubernetes. This is the production
direction for an in-cluster LDAP service.

Keep the [LDAP/SSSD Disposable Test Runbook](ldap-sssd-disposable-test.md)
separate. It validates the Slurm and SSSD path, but it is not an HA identity
service.

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

## Apply-Ready Test Manifests

The guide repo contains an apply-ready HA OpenLDAP manifest set for the current
OKE validation cluster:

```text
guides/slurm-operator/multi-user-oke/manifests/ha-openldap/
```

Deploy it from the combined repo root:

```bash
kubectl apply -k guides/slurm-operator/multi-user-oke/manifests/ha-openldap
kubectl -n identity rollout status statefulset/openldap --timeout=10m
kubectl -n identity wait --for=condition=complete job/openldap-bootstrap --timeout=5m
kubectl -n identity get pods,pvc,svc -o wide
```

The manifest set creates:

- `Namespace/identity`;
- `StatefulSet/openldap` with three replicas;
- `openldap-headless`, `openldap-primary`, and `openldap-read` Services;
- one data PVC and one config PVC per replica using `oci-bv`;
- `openldap-credentials` Secret with sample test credentials;
- `site-sssd-ha-ldap-conf` Secret in the `slurm` namespace;
- bootstrap Job that creates `alice`, `project-a`, and `sssd-reader`;
- PDB and NetworkPolicy.

The config PVC is required. The OpenLDAP image keeps the config database under
`/etc/ldap/slapd.d`; persisting only `/var/lib/ldap` causes pods to fail after
restart with an existing data directory and an empty config directory.

The current manifest is for validation. Before production use:

- replace all sample passwords;
- enable LDAPS or StartTLS;
- use a real CA bundle in SSSD clients;
- add backup, restore, and replica-promotion runbooks;
- decide how secrets are generated and rotated.

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
entry_cache_timeout = 60
entry_cache_nowait_percentage = 75

[pam]

[ssh]

[domain/LDAP]
id_provider = ldap
auth_provider = ldap
access_provider = ldap

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

## Current OKE Validation

Validated on the current OKE cluster on 2026-05-05:

- applied `manifests/ha-openldap`;
- all three pods reached `1/1 Running`;
- `openldap-bootstrap` completed;
- each replica has a data PVC and config PVC on `oci-bv`;
- `sssd-reader` can read `alice` from `openldap-0`, `openldap-1`, and
  `openldap-2`;
- adding `bob` through `openldap-0` replicated to both replicas;
- adding `carol` through `openldap-primary.identity.svc.cluster.local`
  replicated to both replicas;
- direct write to `openldap-1` failed with LDAP `53 operation restricted`;
- deleting `openldap-2` recreated it successfully with zero restarts and the
  LDAP data remained readable.
- updated the live HA LDAP `alice` entry with the real
  `/home/ubuntu/.ssh/alice_slurm_test.pub` key;
- switched the live Slurm release from `site-sssd-ldap-test-conf` to
  `site-sssd-ha-ldap-conf`;
- confirmed login, worker, and controller SSSD configs use the HA OpenLDAP
  replica URIs;
- confirmed `getent passwd alice`, `id alice`, and
  `sss_ssh_authorizedkeys alice` work from the login pod;
- confirmed `getent passwd alice` and `id alice` work from a worker pod and the
  controller container;
- confirmed SSH as `alice` through the login LoadBalancer works with
  LDAP-backed SSH keys;
- confirmed `/home/alice` is mounted from FSS and `/home/bob` cannot be listed
  by `alice`;
- submitted job `8` over SSH as `alice` with `--account=project-a` and
  `--gres=gpu:1`;
- confirmed `scontrol show job 8` resolves `UserId=alice(10001)`,
  `GroupId=alice(10001)`, `Account=project-a`, and `TresPerNode=gres/gpu:1`;
- confirmed `sacct -j 8` reports `8|alice|project-a|COMPLETED|0:0|...`.

The concrete values file used for the HA OpenLDAP end-to-end test is:

```text
guides/slurm-operator/multi-user-oke/overlays/values-oke-bm-gpu4-8-fss-sssd-ha-openldap-controller-sssd.yaml
```

That file preserves the current static `gres.conf` from the live cluster and
changes only the SSSD Secret references from the disposable LDAP Secret to
`site-sssd-ha-ldap-conf`.

## Open Items Before Implementation

- Replace the test OpenLDAP image and bootstrap scripts with the final approved
  image and configuration mechanism.
- Define the exact LDAP suffix, for example `dc=example,dc=org`.
- Define UID/GID ranges and ownership policy.
- Define the SSH public key attribute, for example `sshPublicKey`.
- Decide how certificates are issued and rotated.
- Decide how bind credentials are generated and rotated.
- Write the replica promotion and restore runbooks.
- Define the onboarding automation that creates LDAP users, FSS homes, and
  SlurmDBD associations.
