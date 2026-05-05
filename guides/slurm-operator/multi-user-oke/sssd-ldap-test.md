# SSSD LDAP Test on OKE

Date: 2026-05-05

This test validates the preferred production identity pattern with a disposable
in-cluster OpenLDAP service. The same Slurm-side behavior should apply to
FreeIPA, Active Directory with POSIX attributes, or a production LDAP service
once `sssd.conf` is changed for that directory.

## Test Files

Local guide files:

```text
manifests/openldap-test-identity.yaml
overlays/values-oke-bm-gpu4-8-fss-sssd-ldap.yaml
```

Operator node copies:

```text
/home/ubuntu/slurm-multi-user-manifests/openldap-test-identity.yaml
/home/ubuntu/slurm-multi-user-overlays/values-oke-bm-gpu4-8-fss-sssd-ldap.yaml
```

## What Changed

The SSSD values file preserves:

- `node.kubernetes.io/instance-type: BM.GPU4.8`
- `nvidia.com/gpu: 8`
- `nvidia.com/sriov-rdma-vf: 16`
- 16 `sriov-rdma-vf` Multus attachments
- `/dev/infiniband`
- `/dev/shm`
- FSS PVC `slurm-home` mounted at `/home`
- SlurmDBD accounting

It removes the no-LDAP local-user wrapper from login and slurmd containers.
`alice` is no longer created in `/etc/passwd`.

The login pod uses:

```text
AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys
AuthorizedKeysCommandUser nobody
AuthorizedKeysFile none
PasswordAuthentication no
```

The test LDAP stores Alice's SSH public key in the LDAP `description`
attribute and maps it with:

```ini
ldap_user_ssh_public_key = description
```

This is only for the disposable test. Production LDAP should use a deliberate
SSH-key attribute and schema, such as an `sshPublicKey` attribute, or the
site-standard FreeIPA/AD key storage pattern.

## Apply

Create the disposable LDAP service and SSSD Secret:

```bash
kubectl apply -f /home/ubuntu/slurm-multi-user-manifests/openldap-test-identity.yaml
kubectl -n slurm rollout status deploy/openldap-test --timeout=180s
kubectl -n slurm wait --for=condition=complete job/openldap-test-bootstrap --timeout=180s
```

Upgrade Slurm to use SSSD:

```bash
helm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  -f /home/ubuntu/slurm-multi-user-overlays/values-oke-bm-gpu4-8-fss-sssd-ldap.yaml \
  --namespace slurm
```

## Validation Results

LDAP contents:

```text
uid=alice
uidNumber=10001
gidNumber=10001
homeDirectory=/home/alice
loginShell=/bin/bash
cn=project-a gidNumber=11001 memberUid=alice
```

Login pod:

```text
grep '^alice:' /etc/passwd -> no local entry
getent passwd alice -> alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
id alice -> uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
getent group project-a -> project-a:*:11001:alice
sss_ssh_authorizedkeys alice -> ssh-ed25519 ... alice-slurm-test
```

Worker pod:

```text
grep '^alice:' /etc/passwd -> no local entry
getent passwd alice -> alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
id alice -> uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
getent group project-a -> project-a:*:11001:alice
```

SSH as Alice succeeded with LDAP-backed authorized keys:

```bash
ssh -i /home/ubuntu/.ssh/alice_slurm_test alice@192.9.181.77
```

Inside the SSH session:

```text
whoami -> alice
id -> uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
pwd -> /home/alice
```

Submitted an SSSD-backed GPU/accounting job:

```bash
sbatch --parsable --wait --account=project-a --gres=gpu:1 \
  --output=/home/alice/sssd-gpu-%j.out \
  --wrap="hostname; whoami; id; getent passwd alice; getent group project-a; nvidia-smi -L"
```

Result:

```text
JOBID=5
gpu-b4-1
alice
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
project-a:*:11001:alice
GPU 0: NVIDIA A100-SXM4-40GB
```

Accounting:

```text
JobID|User|Account|State|ExitCode|AllocTRES|NodeList
5|alice|project-a|COMPLETED|0:0|billing=2,cpu=2,gres/gpu=1,mem=2064153M,node=1|gpu-b4-1
5.batch||project-a|COMPLETED|0:0|cpu=2,gres/gpu=1,mem=2064153M,node=1|gpu-b4-1
5.extern||project-a|COMPLETED|0:0|billing=2,cpu=2,gres/gpu=1,mem=2064153M,node=1|gpu-b4-1
```

`scontrol show job 5` from Alice's login session resolves names:

```text
UserId=alice(10001) GroupId=alice(10001)
Account=project-a QOS=normal
JobState=COMPLETED
NodeList=gpu-b4-1
TresPerNode=gres/gpu:1
StdOut=/home/alice/sssd-gpu-5.out
```

`scontrol show job 5` from the controller still shows numeric UID/GID:

```text
UserId=10001(10001) GroupId=10001(10001)
```

This happens because the current controller image does not include SSSD/NSS
integration. User-facing login and job execution are correct, and accounting
records `alice`, but operator-side commands run inside the controller cannot
resolve UID `10001` to `alice`.

## Final State

Helm release:

```text
slurm revision 3 deployed
```

Pods:

```text
openldap-test                         1/1 Running
mariadb-0                             1/1 Running
slurm-accounting-0                    1/1 Running
slurm-controller-0                    3/3 Running
slurm-login-slinky-...                1/1 Running
slurm-restapi-...                     1/1 Running
slurm-worker-gpu-b4-0                 2/2 Running
slurm-worker-gpu-b4-1                 2/2 Running
```

Workers still use VFs, not host networking:

```text
slurm-worker-gpu-b4-0 hostNetwork=<unset/false> vfLimit=16 gpuLimit=8
slurm-worker-gpu-b4-1 hostNetwork=<unset/false> vfLimit=16 gpuLimit=8
```

## Production Notes

For production:

- point `sssd.conf` at real LDAP, FreeIPA, or AD;
- use LDAPS or StartTLS with CA validation;
- store bind credentials in a Secret;
- use a real SSH-key attribute instead of the test `description` mapping;
- keep UID/GID values stable for FSS ownership;
- sync directory groups to SlurmDBD accounts and associations;
- decide whether the controller also needs NSS/SSSD support for operator-side
  name resolution.

Important chart behavior: worker SSSD was activated by setting
`nodesets.gpu-b4.ssh.enabled=true`. Without that, the current chart does not
mount `sssd.conf` into slurmd pods, so jobs may not resolve LDAP users inside
the compute container.
