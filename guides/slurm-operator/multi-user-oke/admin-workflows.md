# Admin Workflows for Multi-User Slurm on OKE

This runbook covers the day-2 administrative workflows for a multi-user Slurm
cluster on OKE:

- create a project;
- onboard a user;
- add or remove a user from a project;
- rotate a user's SSH key;
- offboard a user;
- create or repair an FSS home directory;
- validate identity, SSH, home isolation, Slurm associations, and accounting.

The examples assume the production direction where LDAP runs inside Kubernetes
as HA OpenLDAP with one writable primary and read replicas. If the production
identity source is external LDAP, FreeIPA, or Active Directory, use the same
logical sequence but replace the `ldapadd` and `ldapmodify` commands with the
site-approved identity-management workflow.

## Assumptions

The examples use:

- identity namespace: `identity`;
- Slurm namespace: `slurm`;
- LDAP write endpoint: `ldaps://openldap-primary.identity.svc.cluster.local`;
- LDAP base DN: `dc=example,dc=org`;
- people OU: `ou=People,dc=example,dc=org`;
- groups OU: `ou=Groups,dc=example,dc=org`;
- service/admin OU: `ou=ServiceAccounts,dc=example,dc=org`;
- FSS PVC: `slurm-home`;
- login service: `slurm-login-slinky`;
- controller pod: `slurm-controller-0`;
- controller container: `slurmctld`.

The temporary `home-admin` pod examples mount the PVC named `slurm-home`.
If your deployment uses a different home PVC, update the `claimName` in the
pod override before running those examples.

Use stable UID/GID allocation. Never reuse a UID or GID while old files may
exist on FSS, in backups, or in accounting history.

## Common Variables

Run these from the operator node or another admin shell with `kubectl`, LDAP
client tools, and access to the cluster.
The examples assume `bash`; the `LDAP_AUTH=(...)` array syntax will not work
unchanged in `sh`.

```bash
export IDENTITY_NAMESPACE=identity
export SLURM_NAMESPACE=slurm
export LDAP_URI=ldaps://openldap-primary.identity.svc.cluster.local
export LDAP_BASE='dc=example,dc=org'
export LDAP_PEOPLE_OU='ou=People,dc=example,dc=org'
export LDAP_GROUPS_OU='ou=Groups,dc=example,dc=org'
export LDAP_ADMIN_DN='cn=admin,dc=example,dc=org'
export HOME_PVC=slurm-home
export LOGIN_SERVICE=slurm-login-slinky
export CONTROLLER_POD=slurm-controller-0
export CONTROLLER_CONTAINER=slurmctld
```

For interactive LDAP administration, read the bind password into the shell
rather than putting it in command history:

```bash
read -rsp "LDAP admin password: " LDAP_ADMIN_PASSWORD
echo
```

The LDAP examples below use:

```bash
LDAP_AUTH=(-x -H "$LDAP_URI" -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD")
```

For production automation, use a Kubernetes Secret or external secret manager
instead of an interactive shell variable.

## Admin Shell Options

If the operator node can resolve and reach `openldap-primary`, run LDAP commands
directly there.

If only pods can reach the LDAP service, start a temporary LDAP admin shell in
the `identity` namespace:

```bash
kubectl -n "$IDENTITY_NAMESPACE" run ldap-admin-shell \
  --image=docker.io/osixia/openldap:1.5.0 \
  --restart=Never \
  --command -- sleep infinity

kubectl -n "$IDENTITY_NAMESPACE" wait --for=condition=Ready pod/ldap-admin-shell --timeout=120s
kubectl -n "$IDENTITY_NAMESPACE" exec -it ldap-admin-shell -- bash
```

Install or mount the site CA bundle in the admin shell before using `ldaps://`.
Do not disable certificate verification in production.

Clean up when done:

```bash
kubectl -n "$IDENTITY_NAMESPACE" delete pod ldap-admin-shell
```

## Create a Project

This creates the LDAP group and the Slurm account for a project.

Set project variables:

```bash
export PROJECT=project-a
export PROJECT_GID=11001
export PROJECT_DESCRIPTION='Project A'
export PROJECT_ORG=example
```

Create the LDAP project group:

```bash
cat > /tmp/project.ldif <<EOF
dn: cn=${PROJECT},${LDAP_GROUPS_OU}
objectClass: top
objectClass: posixGroup
cn: ${PROJECT}
gidNumber: ${PROJECT_GID}
EOF

ldapadd "${LDAP_AUTH[@]}" -f /tmp/project.ldif
```

Create the Slurm account:

```bash
kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  sacctmgr -i add account "$PROJECT" Description="$PROJECT_DESCRIPTION" Organization="$PROJECT_ORG"
```

Verify:

```bash
ldapsearch "${LDAP_AUTH[@]}" -LLL -b "$LDAP_GROUPS_OU" "(cn=${PROJECT})" cn gidNumber memberUid

kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  sacctmgr -nP show account "$PROJECT" format=Account,Descr,Org
```

## Onboard a User

This creates the LDAP user, creates or repairs the FSS home, creates the Slurm
association, and validates the user path.

Set user variables:

```bash
export USERNAME=alice
export USER_CN='Alice Slurm'
export USER_SN='Slurm'
export USER_UID=10001
export USER_GID=10001
export PRIMARY_GROUP=alice
export PRIMARY_GROUP_GID=10001
export PROJECT=project-a
export LOGIN_SHELL=/bin/bash
export HOME_DIR=/home/alice
export SSH_PUBLIC_KEY='ssh-ed25519 AAAA_REPLACE_ME alice@example'
```

Create the user's primary LDAP group:

```bash
cat > /tmp/user-primary-group.ldif <<EOF
dn: cn=${PRIMARY_GROUP},${LDAP_GROUPS_OU}
objectClass: top
objectClass: posixGroup
cn: ${PRIMARY_GROUP}
gidNumber: ${PRIMARY_GROUP_GID}
memberUid: ${USERNAME}
EOF

ldapadd "${LDAP_AUTH[@]}" -f /tmp/user-primary-group.ldif
```

Create the LDAP user:

```bash
cat > /tmp/user.ldif <<EOF
dn: uid=${USERNAME},${LDAP_PEOPLE_OU}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: ${USER_CN}
sn: ${USER_SN}
uid: ${USERNAME}
uidNumber: ${USER_UID}
gidNumber: ${USER_GID}
homeDirectory: ${HOME_DIR}
loginShell: ${LOGIN_SHELL}
sshPublicKey: ${SSH_PUBLIC_KEY}
EOF

ldapadd "${LDAP_AUTH[@]}" -f /tmp/user.ldif
```

Add the user to the project group:

```bash
cat > /tmp/add-user-to-project.ldif <<EOF
dn: cn=${PROJECT},${LDAP_GROUPS_OU}
changetype: modify
add: memberUid
memberUid: ${USERNAME}
EOF

ldapmodify "${LDAP_AUTH[@]}" -f /tmp/add-user-to-project.ldif
```

Create or repair the FSS home directory:

```bash
kubectl -n "$SLURM_NAMESPACE" run home-admin \
  --image=docker.io/library/ubuntu:24.04 \
  --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"home-admin","image":"docker.io/library/ubuntu:24.04","command":["sleep","infinity"],"volumeMounts":[{"name":"home","mountPath":"/home"}]}],"volumes":[{"name":"home","persistentVolumeClaim":{"claimName":"slurm-home"}}]}}'

kubectl -n "$SLURM_NAMESPACE" wait --for=condition=Ready pod/home-admin --timeout=120s

kubectl -n "$SLURM_NAMESPACE" exec home-admin -- \
  install -d -m 0711 /home

kubectl -n "$SLURM_NAMESPACE" exec home-admin -- \
  install -d -o "$USER_UID" -g "$USER_GID" -m 0700 "$HOME_DIR"

kubectl -n "$SLURM_NAMESPACE" exec home-admin -- \
  ls -ld /home "$HOME_DIR"

kubectl -n "$SLURM_NAMESPACE" delete pod home-admin
```

If the FSS export uses root squash, create or repair ownership through the
storage administration path instead of a Kubernetes pod.

Create the Slurm association:

```bash
kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  sacctmgr -i add user name="$USERNAME" account="$PROJECT" defaultaccount="$PROJECT"
```

Clear SSSD cache for the user where practical:

```bash
kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  sss_cache -u "$USERNAME" || true

LOGIN_POD="$(kubectl -n "$SLURM_NAMESPACE" get pods -o name \
  | grep "^pod/${LOGIN_SERVICE}-" \
  | head -1 \
  | cut -d/ -f2)"

kubectl -n "$SLURM_NAMESPACE" exec "$LOGIN_POD" -c login -- \
  sss_cache -u "$USERNAME" || true
```

Run the validation checklist at the end of this document.

## Add a User to a Project

Set variables:

```bash
export USERNAME=alice
export PROJECT=project-b
```

Add LDAP group membership:

```bash
cat > /tmp/add-project-membership.ldif <<EOF
dn: cn=${PROJECT},${LDAP_GROUPS_OU}
changetype: modify
add: memberUid
memberUid: ${USERNAME}
EOF

ldapmodify "${LDAP_AUTH[@]}" -f /tmp/add-project-membership.ldif
```

Add the Slurm association:

```bash
kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  sacctmgr -i add user name="$USERNAME" account="$PROJECT"
```

Verify:

```bash
ldapsearch "${LDAP_AUTH[@]}" -LLL -b "cn=${PROJECT},${LDAP_GROUPS_OU}" memberUid

kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  sacctmgr -nP show assoc user="$USERNAME" format=User,Account,DefaultQOS,QOS
```

## Remove a User From a Project

Set variables:

```bash
export USERNAME=alice
export PROJECT=project-b
```

Remove LDAP group membership:

```bash
cat > /tmp/remove-project-membership.ldif <<EOF
dn: cn=${PROJECT},${LDAP_GROUPS_OU}
changetype: modify
delete: memberUid
memberUid: ${USERNAME}
EOF

ldapmodify "${LDAP_AUTH[@]}" -f /tmp/remove-project-membership.ldif
```

Decide how to handle the Slurm association. For immediate removal, delete the
association:

```bash
kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  sacctmgr -i delete user name="$USERNAME" account="$PROJECT"
```

Some sites prefer retaining associations for historical reporting and instead
enforcing access by LDAP group checks plus QOS or submit limits. Pick one policy
and keep it consistent.

Verify:

```bash
kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  sacctmgr -nP show assoc user="$USERNAME" format=User,Account
```

## Rotate a User's SSH Key

Set variables:

```bash
export USERNAME=alice
export NEW_SSH_PUBLIC_KEY='ssh-ed25519 AAAA_REPLACE_ME_NEW alice@example'
```

Replace the LDAP SSH key attribute:

```bash
cat > /tmp/replace-ssh-key.ldif <<EOF
dn: uid=${USERNAME},${LDAP_PEOPLE_OU}
changetype: modify
replace: sshPublicKey
sshPublicKey: ${NEW_SSH_PUBLIC_KEY}
EOF

ldapmodify "${LDAP_AUTH[@]}" -f /tmp/replace-ssh-key.ldif
```

Clear SSSD cache on login and controller pods:

```bash
LOGIN_POD="$(kubectl -n "$SLURM_NAMESPACE" get pods -o name \
  | grep "^pod/${LOGIN_SERVICE}-" \
  | head -1 \
  | cut -d/ -f2)"

kubectl -n "$SLURM_NAMESPACE" exec "$LOGIN_POD" -c login -- \
  sss_cache -u "$USERNAME" || true

kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  sss_cache -u "$USERNAME" || true
```

Verify the new key is returned:

```bash
kubectl -n "$SLURM_NAMESPACE" exec "$LOGIN_POD" -c login -- \
  sss_ssh_authorizedkeys "$USERNAME"
```

Then validate SSH with the new private key and confirm the old private key no
longer works.

## Offboard a User

Offboarding should prevent new login and new job submission while preserving or
archiving data according to site policy.

Set variables:

```bash
export USERNAME=alice
export HOME_DIR=/home/alice
```

Disable the LDAP login shell and remove SSH keys:

```bash
cat > /tmp/disable-user.ldif <<EOF
dn: uid=${USERNAME},${LDAP_PEOPLE_OU}
changetype: modify
replace: loginShell
loginShell: /usr/sbin/nologin
-
delete: sshPublicKey
EOF

ldapmodify "${LDAP_AUTH[@]}" -f /tmp/disable-user.ldif
```

Remove the user from project groups. Repeat per project:

```bash
export PROJECT=project-a

cat > /tmp/remove-user-from-project.ldif <<EOF
dn: cn=${PROJECT},${LDAP_GROUPS_OU}
changetype: modify
delete: memberUid
memberUid: ${USERNAME}
EOF

ldapmodify "${LDAP_AUTH[@]}" -f /tmp/remove-user-from-project.ldif
```

Cancel queued and running jobs if required by policy:

```bash
kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  scancel -u "$USERNAME"
```

Remove or restrict Slurm associations according to policy. Immediate removal:

```bash
kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  sacctmgr -i delete user name="$USERNAME"
```

Archive or lock the home directory. Example lock-only action:

```bash
kubectl -n "$SLURM_NAMESPACE" run home-admin \
  --image=docker.io/library/ubuntu:24.04 \
  --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"home-admin","image":"docker.io/library/ubuntu:24.04","command":["sleep","infinity"],"volumeMounts":[{"name":"home","mountPath":"/home"}]}],"volumes":[{"name":"home","persistentVolumeClaim":{"claimName":"slurm-home"}}]}}'

kubectl -n "$SLURM_NAMESPACE" wait --for=condition=Ready pod/home-admin --timeout=120s

kubectl -n "$SLURM_NAMESPACE" exec home-admin -- \
  chmod 000 "$HOME_DIR"

kubectl -n "$SLURM_NAMESPACE" exec home-admin -- \
  ls -ld "$HOME_DIR"

kubectl -n "$SLURM_NAMESPACE" delete pod home-admin
```

Clear SSSD cache:

```bash
LOGIN_POD="$(kubectl -n "$SLURM_NAMESPACE" get pods -o name \
  | grep "^pod/${LOGIN_SERVICE}-" \
  | head -1 \
  | cut -d/ -f2)"

kubectl -n "$SLURM_NAMESPACE" exec "$LOGIN_POD" -c login -- \
  sss_cache -u "$USERNAME" || true

kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  sss_cache -u "$USERNAME" || true
```

Validate:

```bash
kubectl -n "$SLURM_NAMESPACE" exec "$LOGIN_POD" -c login -- \
  getent passwd "$USERNAME" || true

kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  squeue -u "$USERNAME"
```

Also test from outside the cluster that SSH no longer succeeds.

## Repair a Home Directory

Use this when LDAP is correct but `/home/$USER` is missing or has wrong
ownership.

```bash
export USERNAME=alice
export USER_UID=10001
export USER_GID=10001
export HOME_DIR=/home/alice

kubectl -n "$SLURM_NAMESPACE" run home-admin \
  --image=docker.io/library/ubuntu:24.04 \
  --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"home-admin","image":"docker.io/library/ubuntu:24.04","command":["sleep","infinity"],"volumeMounts":[{"name":"home","mountPath":"/home"}]}],"volumes":[{"name":"home","persistentVolumeClaim":{"claimName":"slurm-home"}}]}}'

kubectl -n "$SLURM_NAMESPACE" wait --for=condition=Ready pod/home-admin --timeout=120s

kubectl -n "$SLURM_NAMESPACE" exec home-admin -- \
  install -d -m 0711 /home

kubectl -n "$SLURM_NAMESPACE" exec home-admin -- \
  install -d -o "$USER_UID" -g "$USER_GID" -m 0700 "$HOME_DIR"

kubectl -n "$SLURM_NAMESPACE" exec home-admin -- \
  ls -ld /home "$HOME_DIR"

kubectl -n "$SLURM_NAMESPACE" delete pod home-admin
```

## Sync One Project Group to Slurm

This is a manual convergence workflow for one project. Production should turn
this into a CronJob, GitOps job, or controller.

```bash
export PROJECT=project-a

ldapsearch "${LDAP_AUTH[@]}" -LLL \
  -b "cn=${PROJECT},${LDAP_GROUPS_OU}" \
  memberUid \
  | awk '/^memberUid:/ {print $2}' \
  | sort -u > /tmp/${PROJECT}.members

kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  sacctmgr -nP show account "$PROJECT" format=Account \
  | grep -qx "$PROJECT" || \
kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  sacctmgr -i add account "$PROJECT" Description="$PROJECT" Organization=example

while read -r USERNAME; do
  kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
    sacctmgr -nP show assoc user="$USERNAME" account="$PROJECT" format=User,Account \
    | grep -qx "${USERNAME}|${PROJECT}" || \
  kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
    sacctmgr -i add user name="$USERNAME" account="$PROJECT" defaultaccount="$PROJECT"
done < /tmp/${PROJECT}.members
```

This only adds missing associations. Removing stale associations should be a
separate policy decision because it can affect users with queued jobs or
historical reporting expectations.

## Validation Checklist

Set the user and account:

```bash
export USERNAME=alice
export PROJECT=project-a
```

Check LDAP:

```bash
ldapsearch "${LDAP_AUTH[@]}" -LLL -b "$LDAP_PEOPLE_OU" "(uid=${USERNAME})" \
  uid uidNumber gidNumber homeDirectory loginShell sshPublicKey

ldapsearch "${LDAP_AUTH[@]}" -LLL -b "$LDAP_GROUPS_OU" "(memberUid=${USERNAME})" \
  cn gidNumber memberUid
```

Check controller-side NSS:

```bash
kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  getent passwd "$USERNAME"

kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  id "$USERNAME"
```

Check login-side NSS and SSH key lookup:

```bash
LOGIN_POD="$(kubectl -n "$SLURM_NAMESPACE" get pods -o name \
  | grep "^pod/${LOGIN_SERVICE}-" \
  | head -1 \
  | cut -d/ -f2)"

kubectl -n "$SLURM_NAMESPACE" exec "$LOGIN_POD" -c login -- \
  getent passwd "$USERNAME"

kubectl -n "$SLURM_NAMESPACE" exec "$LOGIN_POD" -c login -- \
  id "$USERNAME"

kubectl -n "$SLURM_NAMESPACE" exec "$LOGIN_POD" -c login -- \
  sss_ssh_authorizedkeys "$USERNAME"
```

Check home permissions:

```bash
kubectl -n "$SLURM_NAMESPACE" exec "$LOGIN_POD" -c login -- \
  ls -ld /home "$HOME_DIR"
```

Check Slurm association:

```bash
kubectl -n "$SLURM_NAMESPACE" exec "$CONTROLLER_POD" -c "$CONTROLLER_CONTAINER" -- \
  sacctmgr -nP show assoc user="$USERNAME" format=User,Account,DefaultQOS,QOS
```

Check user SSH and job accounting from outside the cluster:

```bash
LOGIN_ADDR="$(kubectl -n "$SLURM_NAMESPACE" get svc "$LOGIN_SERVICE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

ssh "${USERNAME}@${LOGIN_ADDR}" 'whoami; id; pwd; getent passwd "$USER"'

JOB="$(ssh "${USERNAME}@${LOGIN_ADDR}" \
  "sbatch --parsable --account=${PROJECT} --cpus-per-task=1 --time=00:05:00 \
   --wrap='whoami; id; pwd; hostname; touch \$HOME/admin-workflow-test-\$SLURM_JOB_ID'")"

ssh "${USERNAME}@${LOGIN_ADDR}" \
  "sacct -j ${JOB} --format=JobID,User,Account,State,ExitCode,AllocTRES%80,NodeList -P"
```

Expected result:

- SSH logs in as the requested user;
- `id` shows LDAP UID/GID and project groups;
- `pwd` is `/home/$USERNAME`;
- `/home/$USERNAME` is owned by the user's UID/GID and is mode `700`;
- `sacct` top-level job row shows the user and account;
- jobs without a valid association are rejected when enforcement is enabled.
