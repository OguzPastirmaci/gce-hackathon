# OKE GB200 HA OpenLDAP Test Log

Date: 2026-05-05

Operator host:

```bash
ssh -J ubuntu@192.9.189.161 ubuntu@10.140.0.20
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

## Goal

Deploy the GB200 hostNetwork Slinky setup with:

- HA OpenLDAP as one writable primary plus two read-only replicas;
- SSSD-backed POSIX identity in login, worker, and controller pods;
- FSS-backed `/home` through the existing `fss-pv`;
- Slurm accounting through MariaDB and SlurmDBD;
- `AutoDetect=nvml` only for GPU detection.

## Shape: BM.GPU.GB200.4

This runbook applies only to `BM.GPU.GB200.4`.

Do not use this hostNetwork values path for the previous `BM.GPU4.8` cluster.
For shape selection, start with
[OKE Slurm Shape Runbooks](oke-slurm-shape-runbooks.md).

Shape-specific assumptions:

- GPU node architecture: `arm64`;
- worker networking: `hostNetwork`;
- worker sshd port: `2222`;
- GPU count: 4 GPUs per node;
- GPU detection: `AutoDetect=nvml` only;
- worker node name: pass Kubernetes `spec.nodeName` to `slurmd -N`;
- worker image: multi-platform `linux/amd64` plus `linux/arm64`.

## Local Files

```text
docs/usage/oke-gb200-ha-openldap-prereqs.yaml
docs/usage/oke-gb200-ha-openldap.values.yaml
docs/usage/oke-gb200-hostnetwork-ha-openldap-slurm.values.yaml
docs/usage/oke-gb200-slurm-home-pvc.yaml
docs/usage/oke-gb200-mariadb.yaml
docs/usage/oke-gb200-ha-openldap-tls-config.ldif
docs/usage/oke-gb200-ha-openldap-primary-syncprov.ldif
```

## Notes

- The LDAP server certificate is created by cert-manager in the `identity`
  namespace as `Secret/openldap-tls`. The manifest creates a self-signed CA
  first, then signs a separate LDAP server certificate from that CA. Do not use
  the CA certificate itself as the LDAP server certificate; OpenLDAP clients can
  reject it with `unsuitable certificate purpose`.
- Slurm pods cannot mount a Secret from another namespace, so the public CA
  material is copied into `Secret/openldap-ca` in the `slurm` namespace.
- The GB200 worker remains hostNetwork-only for this cluster, with worker sshd
  listening on port `2222`.
- The GB200 GPU node is `arm64`. The Slurm worker image used by these values is
  the multi-platform NVML image
  `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-core-25.11.5-ubuntu24.04`
  (`linux/amd64` and `linux/arm64`). Identity and controller-side services are
  pinned to `VM.Standard.E5.Flex` CPU nodes in these test values unless their
  images are confirmed multi-platform too.
- The OpenLDAP chart mounted the cert-manager TLS Secret and opened port `1636`,
  but `cn=config` did not initially contain the `olcTLS*` attributes. Apply
  `oke-gb200-ha-openldap-tls-config.ldif` to each OpenLDAP pod if LDAPS returns
  `Can't contact LDAP server` during the handshake.
- The primary `mdb` database also needs the `syncprov` overlay. Without it, the
  read-only replicas can bind to the primary over StartTLS and read all entries,
  but they do not apply the replicated contents locally. Apply
  `oke-gb200-ha-openldap-primary-syncprov.ldif` to `openldap-0` if replica
  searches return `No such object` while the primary has the entries.

## HA OpenLDAP Validation

Current validated state:

```text
openldap-0            primary, running
openldap-readonly-0   read replica, running
openldap-readonly-1   read replica, running
```

Validated:

- `ldaps://openldap.identity.svc.cluster.local:636` returns `alice` from the
  primary.
- `openldap-readonly-0` and `openldap-readonly-1` return `alice` locally.
- A temporary primary write for `uid=syncprobe` replicated to both read-only
  replicas while `olcReadOnly: TRUE` remained set on each replica.

Commands used for the chart-specific fixes:

```bash
for pod in openldap-0 openldap-readonly-0 openldap-readonly-1; do
  kubectl -n identity exec -i "$pod" -- \
    /opt/bitnami/openldap/bin/ldapmodify \
      -x -H ldap://127.0.0.1:1389 \
      -D cn=admin,cn=config -w configpassword \
    < /home/ubuntu/oke-gb200-ha-openldap-tls-config.ldif
done

kubectl -n identity exec -i openldap-0 -- \
  /opt/bitnami/openldap/bin/ldapadd \
    -x -H ldap://127.0.0.1:1389 \
    -D cn=admin,cn=config -w configpassword \
  < /home/ubuntu/oke-gb200-ha-openldap-primary-syncprov.ldif
```

The CA was copied to the Slurm namespace because Kubernetes Secrets are
namespace-scoped:

```bash
CRT="$(kubectl -n identity get secret openldap-tls -o jsonpath='{.data.ca\.crt}')"
if [ -z "$CRT" ]; then
  CRT="$(kubectl -n identity get secret openldap-ca-root -o jsonpath='{.data.tls\.crt}')"
fi

cat >/tmp/openldap-ca-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openldap-ca
  namespace: slurm
type: Opaque
data:
  ca.crt: ${CRT}
EOF

kubectl apply -f /tmp/openldap-ca-secret.yaml
```

## MariaDB Accounting

Installed the MariaDB operator and CRDs:

```bash
helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator || true
helm repo update mariadb-operator
helm upgrade --install mariadb-operator-crds mariadb-operator/mariadb-operator-crds \
  --namespace mariadb --create-namespace
helm upgrade --install mariadb-operator mariadb-operator/mariadb-operator \
  --namespace mariadb --create-namespace
kubectl -n mariadb rollout status deploy/mariadb-operator-webhook --timeout=180s
kubectl -n mariadb rollout status deploy/mariadb-operator-cert-controller --timeout=180s
```

Created the Slurm accounting database:

```bash
kubectl apply -f /home/ubuntu/oke-gb200-mariadb.yaml
kubectl -n slurm wait --for=condition=Ready pod/mariadb-0 --timeout=420s
```

Validated:

```text
mariadb.k8s.mariadb.com/mariadb   True   Running   mariadb-0
pod/mariadb-0                     1/1    Running
secret/mariadb-password           present
```

## Slurm HA LDAP Deployment

Deployed Slurm revision 7 with HA LDAP, SSSD, FSS `/home`, LoginSet, and
SlurmDBD accounting:

```bash
helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  -n slurm \
  -f /home/ubuntu/oke-gb200-hostnetwork-ha-openldap-slurm.values.yaml
```

Validated pods:

```text
slurm-accounting-0                    1/1 Running
slurm-controller-0                    4/4 Running
slurm-login-slinky-59584f5d9f-lj5n6   1/1 Running
slurm-worker-gb200-0                  2/2 Running
```

The login service received external IP `159.13.57.35`.

The GB200 worker is still using `AutoDetect=nvml` only. `slurmd` detected:

```text
gpu/nvml: _get_system_gpu_list_nvml: 4 GPU system device(s) detected
CPUs=144 Boards=1 Sockets=2 Cores=72 Threads=1 Memory=979729
```

## Identity And Home Validation

Created Alice's FSS home:

```bash
kubectl -n slurm exec deploy/slurm-login-slinky -c login -- sh -lc '
  mkdir -p /home/alice
  chown 10001:10001 /home/alice
  chmod 700 /home/alice
  chmod 711 /home
  ls -ld /home /home/alice
'
```

Validated SSSD/NSS on controller, login, and worker:

```text
alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMVDtBylW3N5r0XxDx/KbNrpslGX5o5dNDgWRA0QF8ag alice-slurm-test
```

SSSD config note: this cluster's SSSD rejected `entry_cache_timeout` under
`[nss]` and rejected `entry_cache_nowait_percentage` under `[domain/LDAP]`.
The checked-in prereq manifest now keeps only `entry_cache_timeout = 60` under
`[domain/LDAP]`.

Validated SSH into the login pod through the LoadBalancer:

```bash
LOGIN_IP="$(kubectl -n slurm get svc slurm-login-slinky \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

ssh -i /home/ubuntu/.ssh/alice_slurm_test \
  -o BatchMode=yes \
  alice@"$LOGIN_IP" \
  'whoami; id; pwd; ls -ld /home /home/alice /home/bob || true; sinfo -Nel'
```

Result:

```text
alice
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
/home/alice
drwx--x--x 3 root  root  1 May  5 23:11 /home
drwx------ 3 alice alice 1 May  5 23:11 /home/alice
ls: cannot access '/home/bob': No such file or directory
10.140.64.164 gb200 idle 144 CPUs 2:72:1 979729 MB
```

## Job And Accounting Validation

Created the SlurmDBD account association:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- sh -lc '
  sacctmgr -i add account project-a Description="Project A" Organization=example || true
  sacctmgr -i add user name=alice account=project-a defaultaccount=project-a || true
  sacctmgr -nP show assoc user=alice format=User,Account,DefaultQOS,QOS
'
```

Result:

```text
alice|project-a||normal
```

Submitted a GPU job as Alice:

```bash
JOB="$(ssh -i /home/ubuntu/.ssh/alice_slurm_test alice@"$LOGIN_IP" \
  'sbatch --parsable -N1 -n1 --gres=gpu:1 \
     --output=/home/alice/ha-ldap-%j.out \
     --wrap="whoami; id; hostname; nvidia-smi -L"')"
```

Job `6` completed. Accounting output:

```text
JobID|User|Account|State|ExitCode|AllocTRES|NodeList
6|alice|project-a|COMPLETED|0:0|billing=1,cpu=1,gres/gpu=1,mem=979729M,node=1|10.140.64.164
6.batch||project-a|COMPLETED|0:0|cpu=1,gres/gpu=1,mem=979729M,node=1|10.140.64.164
6.extern||project-a|COMPLETED|0:0|billing=1,cpu=1,gres/gpu=1,mem=979729M,node=1|10.140.64.164
```

Job output:

```text
alice
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
instance20260505204444
GPU 0: NVIDIA GB200 (UUID: GPU-c180d613-630c-b39f-e5e0-7eaf7372e826)
```
