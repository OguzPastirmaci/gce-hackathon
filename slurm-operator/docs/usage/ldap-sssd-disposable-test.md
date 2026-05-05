# LDAP/SSSD Disposable Test Runbook

Use this runbook to deploy the disposable LDAP test environment and validate the
same user experience expected from a production LDAP, FreeIPA, or Active
Directory integration.

This is not a production LDAP design. It exists to validate the Slurm-side path.
For an in-cluster production LDAP direction, use
[HA OpenLDAP for Slurm Identity on Kubernetes](ldap-sssd-ha-openldap.md).

## Shape: BM.GPU4.8

This disposable validation runbook applies to the previous `BM.GPU4.8` test
path. It uses SR-IOV/VF pod networking, FSS-backed `/home`, SSSD in Slurm pods,
and the BM.GPU4.8 Slurm values overlay.

Do not use this as the `BM.GPU.GB200.4` guide. For GB200, use the
[BM.GPU.GB200.4 shape section](oke-slurm-shape-runbooks.md#shape-bmgpugb2004)
and the `oke-gb200-*` manifests.

The disposable test validates:

- LDAP publishes the POSIX user, group, home directory, shell, and SSH public
  key;
- SSSD resolves that identity in the login, worker, and controller pods;
- the user SSHs into the login service as themselves;
- `/home/<user>` is mounted from FSS and owned by the user's UID/GID;
- SlurmDBD has an accounting association for the user;
- a job submitted from the login service is attributed to that user in Slurm
  accounting.

The examples use:

- namespace: `slurm`;
- login service: `slurm-login-slinky`;
- test user: `alice`;
- test Slurm account: `project-a`;
- shared home mount: `/home`;
- SSH key: `~/.ssh/alice_slurm_test`.

Adjust those names for your environment.

## What Gets Deployed

There are two separate pieces:

| Piece | Deployed by | Purpose |
| --- | --- | --- |
| Disposable OpenLDAP test service | Plain Kubernetes manifest | Creates `alice`, `project-a`, and the SSSD Secret for this test |
| Slurm on OKE | Slinky Slurm Helm chart plus an OKE values overlay | Mounts FSS at `/home`, enables SR-IOV VFs, enables accounting, and consumes the SSSD Secret |

The OKE overlay uses the `sriov-rdma-vf` network attachment for BM.GPU4.8
workers. It does not use `hostNetwork`.

There is no LDAP Helm chart in this guide. The test LDAP server is intentionally
just a Kubernetes manifest. The Slurm chart does not deploy LDAP, FreeIPA, or
Active Directory; it consumes SSSD configuration through chart-level `sssd`
values:

```yaml
sssd:
  secretRef:
    name: site-sssd-ldap-test-conf
    key: sssd.conf
```

The chart support for this is in:

```text
helm/slurm/values.yaml
helm/slurm/templates/cluster/sssd-conf-secret.yaml
```

For the OKE LDAP test environment used by these instructions, the source files
are in the separate guide repo:

| File | Purpose |
| --- | --- |
| `/Users/opastirm/Documents/Repos/guides/slurm-operator/multi-user-oke/manifests/openldap-test-identity.yaml` | Disposable OpenLDAP deployment, bootstrap LDIF, service, bootstrap Job, and `site-sssd-ldap-test-conf` Secret |
| `/Users/opastirm/Documents/Repos/guides/slurm-operator/multi-user-oke/overlays/values-oke-bm-gpu4-8-fss-sssd-ldap.yaml` | Slurm values overlay with LDAP/SSSD for login and worker pods |
| `/Users/opastirm/Documents/Repos/guides/slurm-operator/multi-user-oke/overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml` | Same as above, plus controller-side SSSD/NSS support |

The LDAP manifest creates:

- `ConfigMap/openldap-test-bootstrap`, containing the LDIF for `alice` and
  `project-a`;
- `Deployment/openldap-test`, running `docker.io/osixia/openldap:1.5.0`;
- `Service/openldap-test`, exposing LDAP port `389` inside the `slurm`
  namespace;
- `Job/openldap-test-bootstrap`, which waits for LDAP and loads the LDIF;
- `Secret/site-sssd-ldap-test-conf`, containing `sssd.conf`.

Use the controller-side values overlay for this test:

```text
/Users/opastirm/Documents/Repos/guides/slurm-operator/multi-user-oke/overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml
```

It uses this controller image, which includes SSSD/NSS integration:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04
```

The runbook copies those files to the operator node here:

```text
/home/ubuntu/slurm-multi-user-manifests/openldap-test-identity.yaml
/home/ubuntu/slurm-multi-user-overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml
```

## 1. Copy the Test Assets to the Operator Node

Run this from the workstation that has both repos checked out.

```bash
GUIDE_DIR="/Users/opastirm/Documents/Repos/guides/slurm-operator/multi-user-oke"
OPERATOR="ubuntu@10.140.0.18"
BASTION="ubuntu@152.67.124.58"

ssh -J "$BASTION" "$OPERATOR" \
  'mkdir -p /home/ubuntu/slurm-multi-user-manifests /home/ubuntu/slurm-multi-user-overlays'

scp -o ProxyJump="$BASTION" \
  "$GUIDE_DIR/manifests/openldap-test-identity.yaml" \
  "$OPERATOR:/home/ubuntu/slurm-multi-user-manifests/openldap-test-identity.yaml"

scp -o ProxyJump="$BASTION" \
  "$GUIDE_DIR/overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml" \
  "$OPERATOR:/home/ubuntu/slurm-multi-user-overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml"
```

## 2. Connect to the Operator Node

Run the remaining commands on the operator node unless a step says otherwise.

```bash
ssh -J ubuntu@152.67.124.58 ubuntu@10.140.0.18
```

Set the common variables:

```bash
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal

export NAMESPACE=slurm
export LDAP_MANIFEST=/home/ubuntu/slurm-multi-user-manifests/openldap-test-identity.yaml
export SLURM_VALUES=/home/ubuntu/slurm-multi-user-overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml
export LOGIN_SERVICE=slurm-login-slinky
export TEST_USER=alice
export TEST_UID=10001
export TEST_GID=10001
export TEST_ACCOUNT=project-a
export TEST_KEY=$HOME/.ssh/alice_slurm_test
```

Verify the operator node has the files and tooling:

```bash
ls -l "$LDAP_MANIFEST" "$SLURM_VALUES"
kubectl version --client
helm version
oci os ns get --auth instance_principal
```

## 3. Check Cluster Prerequisites

```bash
kubectl get namespace "$NAMESPACE"
kubectl get nodes -l node.kubernetes.io/instance-type=BM.GPU4.8
kubectl get network-attachment-definitions -A | grep sriov-rdma-vf
kubectl get pv fss-pv
kubectl -n "$NAMESPACE" get pvc slurm-home
kubectl -n "$NAMESPACE" get secret mariadb-password
```

The OKE test overlay assumes:

- the `slurm` namespace already exists;
- two `BM.GPU4.8` worker nodes are available;
- SR-IOV network attachment `sriov-rdma-vf` exists;
- FSS PV `fss-pv` is bound to PVC `slurm-home`;
- `/home` in login and worker pods is backed by `slurm-home`;
- Slurm accounting can use Secret `mariadb-password`;
- custom images referenced by the overlay are already pushed and pullable.

If the cluster does not need controller-side NSS lookup, use the simpler
`values-oke-bm-gpu4-8-fss-sssd-ldap.yaml` overlay instead.

## 4. Prepare Alice's SSH Key

The OpenLDAP test manifest stores Alice's SSH public key in LDAP. The private
key used for SSH must match that public key. Generate or verify the key on the
operator node because the SSH tests below run from the operator node.

If the expected key already exists, verify it:

```bash
ls -l "$TEST_KEY" "$TEST_KEY.pub"
```

If you need to create a new key, generate it and replace the `description:`
line in the copied LDAP manifest before applying the manifest:

```bash
install -d -m 0700 "$HOME/.ssh"
ssh-keygen -t ed25519 -f "$TEST_KEY" -N '' -C alice-slurm-test
ALICE_PUB="$(cat "$TEST_KEY.pub")"

sed -i.bak \
  "s#^    description: ssh-.*#    description: ${ALICE_PUB}#" \
  "$LDAP_MANIFEST"

grep -n 'description: ssh-' "$LDAP_MANIFEST"
```

After LDAP is bootstrapped, changing this key requires updating LDAP or deleting
and re-running the bootstrap Job with a changed LDIF.

## 5. Deploy the Disposable LDAP Service

For a clean disposable test run, delete any prior test resources and immediately
apply the manifest again. The delete command is harmless on a first run because
it uses `--ignore-not-found`.

```bash
kubectl delete -f "$LDAP_MANIFEST" --ignore-not-found
```

```bash
kubectl apply -f "$LDAP_MANIFEST"
kubectl -n "$NAMESPACE" rollout status deploy/openldap-test --timeout=180s
kubectl -n "$NAMESPACE" wait --for=condition=complete job/openldap-test-bootstrap --timeout=180s
```

Verify that LDAP contains the test user and group:

```bash
kubectl -n "$NAMESPACE" exec deploy/openldap-test -- ldapsearch -x \
  -H ldap://localhost:389 \
  -D cn=admin,dc=example,dc=org \
  -w adminpassword \
  -b dc=example,dc=org \
  '(|(uid=alice)(cn=project-a))'
```

Expected LDAP attributes include:

```text
uid=alice
uidNumber=10001
gidNumber=10001
homeDirectory=/home/alice
loginShell=/bin/bash
cn=project-a
gidNumber=11001
memberUid=alice
```

The test manifest stores Alice's SSH public key in the LDAP `description`
attribute and maps it with `ldap_user_ssh_public_key = description` in
`sssd.conf`. That is only for this disposable test. For production, use a real
SSH-key attribute and schema.

## 6. Deploy Slurm With the LDAP/SSSD Overlay

The overlay mounts `site-sssd-ldap-test-conf` into login and worker pods. The
controller-side overlay also runs SSSD as a sidecar in the controller pod so
controller-side commands can resolve `alice`.

```bash
helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  --namespace "$NAMESPACE" \
  -f "$SLURM_VALUES"
```

Wait for the Slurm pods:

```bash
kubectl -n "$NAMESPACE" get pods -o wide
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/slurm-controller-0 --timeout=300s
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/slurm-worker-gpu-b4-0 --timeout=300s
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/slurm-worker-gpu-b4-1 --timeout=300s
kubectl -n "$NAMESPACE" get svc "$LOGIN_SERVICE"
kubectl -n "$NAMESPACE" get pvc
```

The controller, accounting, login, and worker pods should be running. The login
service should have an address or hostname that users can SSH to, and the home
PVC or NFS-backed volume should be bound and mounted into login and worker pods.

## 7. Verify NSS Resolution

Check that the Slurm controller can resolve the LDAP user. This matters because
Slurm controller-side tools and accounting views need NSS user lookup.

```bash
kubectl -n "$NAMESPACE" exec slurm-controller-0 -c slurmctld -- getent passwd "$TEST_USER"
kubectl -n "$NAMESPACE" exec slurm-controller-0 -c slurmctld -- id "$TEST_USER"
```

Check the login pod as well:

```bash
LOGIN_POD="$(kubectl -n "$NAMESPACE" get pods -o name \
  | grep "^pod/${LOGIN_SERVICE}-" \
  | head -1 \
  | cut -d/ -f2)"

kubectl -n "$NAMESPACE" exec "$LOGIN_POD" -c login -- getent passwd "$TEST_USER"
kubectl -n "$NAMESPACE" exec "$LOGIN_POD" -c login -- id "$TEST_USER"
```

If worker pods run SSSD, or if workers expose SSH with SSSD enabled, check one
worker too:

```bash
kubectl -n "$NAMESPACE" exec slurm-worker-gpu-b4-0 -c slurmd -- getent passwd "$TEST_USER"
kubectl -n "$NAMESPACE" exec slurm-worker-gpu-b4-0 -c slurmd -- id "$TEST_USER"
```

Expected result: all required pods resolve the same username, UID, GID, groups,
home directory, and shell.

For `alice`, the passwd record should include:

```text
alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
```

## 8. Prepare and Verify Home Directory Permissions

LDAP provides the UID/GID and home path, but it does not create the FSS
directory. Create or repair `/home/alice` once on the shared home filesystem.
Use a temporary pod, an admin login session, or any trusted pod that mounts
`slurm-home`.

Example using the login pod:

```bash
kubectl -n "$NAMESPACE" exec "$LOGIN_POD" -c login -- bash -lc "
  install -d -m 0711 /home
  install -d -o ${TEST_UID} -g ${TEST_GID} -m 0700 /home/${TEST_USER}
  install -d -o 10002 -g 10002 -m 0700 /home/bob
  ls -ld /home /home/${TEST_USER} /home/bob
"
```

If your FSS export uses root squash, do the ownership operation from an
appropriate storage administration path instead.

The `/home/bob` directory is only a negative-control directory for the isolation
test. It lets you confirm that `alice` can traverse `/home` but cannot read
another user's private home directory.

## 9. Verify SSH Login

Get the login service address:

```bash
LOGIN_ADDR="$(kubectl -n "$NAMESPACE" get svc "$LOGIN_SERVICE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

if [ -z "$LOGIN_ADDR" ]; then
  LOGIN_ADDR="$(kubectl -n "$NAMESPACE" get svc "$LOGIN_SERVICE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
fi

echo "$LOGIN_ADDR"
```

SSH as the LDAP user:

```bash
ssh -i "$TEST_KEY" \
  -o BatchMode=yes \
  "${TEST_USER}@${LOGIN_ADDR}" \
  'whoami; id; pwd; getent passwd "$USER"'
```

Expected result:

- `whoami` prints `alice`;
- `id` shows the LDAP UID/GID and expected groups;
- `pwd` is `/home/alice` if LDAP sets `homeDirectory=/home/alice`;
- `getent passwd alice` returns the LDAP passwd record.

If SSH authentication uses LDAP-published SSH keys, also verify the key lookup
inside the login pod:

```bash
kubectl -n "$NAMESPACE" exec "$LOGIN_POD" -c login -- sss_ssh_authorizedkeys "$TEST_USER"
```

The command should print the public key from `$TEST_KEY.pub`.

## 10. Verify Home Directory Isolation

```bash
ssh -i "$TEST_KEY" \
  -o BatchMode=yes \
  "${TEST_USER}@${LOGIN_ADDR}" \
  'touch "$HOME/ssh-home-write-test"; ls -ld /home "$HOME" /home/bob || true; ls -la /home || true; ls -la /home/bob || true'
```

Expected result:

- `/home/alice` is owned by `alice` and is writable by `alice`;
- `/home/bob` exists but `alice` gets `Permission denied` when trying to list
  it;
- if `/home` is mode `711`, `alice` can traverse to `/home/alice` but cannot
  list every home directory.

For FSS-backed homes, verify the same path exists on worker pods:

```bash
kubectl -n "$NAMESPACE" exec slurm-worker-gpu-b4-0 -c slurmd -- ls -ld /home "/home/${TEST_USER}"
```

## 11. Create or Verify the Slurm Accounting Association

The LDAP user must also exist in SlurmDBD accounting. LDAP identity alone is not
enough for account limits, fairshare, QOS, or enforced associations.

```bash
kubectl -n "$NAMESPACE" exec slurm-controller-0 -c slurmctld -- \
  sacctmgr -nP show assoc user="$TEST_USER" format=User,Account,DefaultQOS,QOS
```

If the user or account is missing, create them. This block is safe to re-run.

```bash
kubectl -n "$NAMESPACE" exec slurm-controller-0 -c slurmctld -- bash -lc "
  sacctmgr -nP show account ${TEST_ACCOUNT} format=Account | grep -qx ${TEST_ACCOUNT} ||
    sacctmgr -i add account ${TEST_ACCOUNT} Description='Project A' Organization=example

  sacctmgr -nP show assoc user=${TEST_USER} account=${TEST_ACCOUNT} format=User,Account |
    grep -qx '${TEST_USER}|${TEST_ACCOUNT}' ||
    sacctmgr -i add user name=${TEST_USER} account=${TEST_ACCOUNT} defaultaccount=${TEST_ACCOUNT}
"
```

Re-check the association:

```bash
kubectl -n "$NAMESPACE" exec slurm-controller-0 -c slurmctld -- \
  sacctmgr -nP show assoc user="$TEST_USER" format=User,Account,DefaultQOS,QOS
```

Expected output includes:

```text
alice|project-a
```

## 12. Submit a Job as the LDAP User

Submit from the login service over SSH. This verifies the user experience that
normal Slurm users will see.

```bash
JOB="$(ssh -i "$TEST_KEY" \
  -o BatchMode=yes \
  "${TEST_USER}@${LOGIN_ADDR}" \
  "sbatch --parsable \
    --account=${TEST_ACCOUNT} \
    --cpus-per-task=2 \
    --gres=gpu:1 \
    --time=00:05:00 \
    --wrap='whoami; id; pwd; hostname; touch \$HOME/slurm-ldap-test-\$SLURM_JOB_ID'")"

echo "$JOB"
```

Watch the job until it leaves the queue:

```bash
ssh -i "$TEST_KEY" \
  -o BatchMode=yes \
  "${TEST_USER}@${LOGIN_ADDR}" \
  "while squeue -h -j ${JOB} | grep -q .; do
     squeue -j ${JOB} -o '%i %u %a %T %b %N';
     sleep 10;
   done"
```

Then check accounting:

```bash
ssh -i "$TEST_KEY" \
  -o BatchMode=yes \
  "${TEST_USER}@${LOGIN_ADDR}" \
  "sacct -j ${JOB} --format=JobID,User,Account,State,ExitCode,AllocTRES%80,NodeList -P"
```

Expected result:

- the top-level job row shows `User=alice`;
- `Account=project-a`;
- GPU allocation appears in `AllocTRES`, for example `gres/gpu=1`;
- the final state is `COMPLETED` with `ExitCode=0:0`;
- the test file exists in `/home/alice`.

Some Slurm versions leave the `User` field blank on `.batch` or `.extern` step
rows. The top-level job row is the important accounting identity check.

Verify the job wrote to Alice's FSS-backed home:

```bash
ssh -i "$TEST_KEY" \
  -o BatchMode=yes \
  "${TEST_USER}@${LOGIN_ADDR}" \
  "ls -l \$HOME/slurm-ldap-test-${JOB}"
```

## 13. Cleanup or Reset

To remove only the disposable LDAP test service and SSSD Secret:

```bash
kubectl delete -f "$LDAP_MANIFEST"
```

If Slurm is still configured to use `site-sssd-ldap-test-conf`, first roll Slurm
back to a non-LDAP values file or replace the Secret with a production
`sssd.conf`. Otherwise login and worker pods will lose identity lookup.

## Common Failures

| Symptom | Likely cause | Check |
| --- | --- | --- |
| `ssh alice@...` fails with public key errors | SSSD SSH key lookup, LDAP SSH key attribute, or `AuthorizedKeysCommand` is wrong | `sss_ssh_authorizedkeys alice` in the login pod |
| `sss_ssh_authorizedkeys alice` prints an old key | The disposable LDAP bootstrap already loaded an older public key | Delete and re-apply `$LDAP_MANIFEST`, then redeploy or restart affected pods |
| `getent passwd alice` works in login pod but not controller | Controller image or sidecar lacks SSSD/NSS integration | `kubectl exec slurm-controller-0 -c slurmctld -- getent passwd alice` |
| `sbatch: Invalid account or account/partition combination` | SlurmDBD association is missing or wrong | `sacctmgr show assoc user=alice` |
| job runs but `/home/alice` is missing on workers | shared home volume is not mounted into the NodeSet | `kubectl exec slurm-worker-... -- mount | grep /home` |
| users can read other users' homes | FSS directory ownership or mode is too permissive | `ls -ld /home /home/alice /home/bob` |
| `sacct` does not show the LDAP user on the top-level job row | submit command did not run as the LDAP user, or controller-side NSS is broken | `whoami` over SSH and `getent passwd alice` in controller |
