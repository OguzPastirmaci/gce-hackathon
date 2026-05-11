#!/usr/bin/env bash
set -euo pipefail

export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal

echo "== MI300X cluster prerequisites =="
kubectl get nodes -l node.kubernetes.io/instance-type=BM.GPU.MI300X.8 -o wide
kubectl get pv fss-pv
kubectl get storageclass oci-bv

echo "== Remove existing Slurm release, if present =="
if helm status slurm -n slurm >/dev/null 2>&1; then
  helm uninstall slurm -n slurm --wait
fi

echo "== Install or refresh Slinky operator =="
helm upgrade --install slurm-operator-crds \
  oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
  --namespace=slinky \
  --create-namespace
helm upgrade --install slurm-operator \
  oci://ghcr.io/slinkyproject/charts/slurm-operator \
  --namespace=slinky \
  --create-namespace
kubectl -n slinky rollout status deployment/slurm-operator-webhook --timeout=180s

echo "== Deploy HA OpenLDAP prerequisites =="
helm repo add helm-openldap https://jp-gouin.github.io/helm-openldap/ --force-update
helm repo update helm-openldap
kubectl apply -f /home/ubuntu/oke-amd-mi300x-ha-openldap-prereqs.yaml
kubectl -n identity wait --for=condition=Ready certificate/openldap-tls --timeout=180s

echo "== Deploy HA OpenLDAP =="
helm upgrade --install openldap helm-openldap/openldap-stack-ha \
  --version 4.3.3 \
  -n identity \
  -f /home/ubuntu/oke-amd-mi300x-ha-openldap.values.yaml
kubectl -n identity rollout status statefulset/openldap --timeout=420s
kubectl -n identity rollout status statefulset/openldap-readonly --timeout=420s

echo "== Apply OpenLDAP TLS cn=config fix =="
for pod in openldap-0 openldap-readonly-0 openldap-readonly-1; do
  kubectl -n identity exec -i "$pod" -- \
    /opt/bitnami/openldap/bin/ldapmodify \
      -x -H ldap://127.0.0.1:1389 \
      -D cn=admin,cn=config -w configpassword \
    < /home/ubuntu/oke-amd-mi300x-ha-openldap-tls-config.ldif
done

echo "== Ensure primary syncprov overlay exists =="
if kubectl -n identity exec openldap-0 -- \
  /opt/bitnami/openldap/bin/ldapsearch \
    -x -H ldap://127.0.0.1:1389 \
    -D cn=admin,cn=config -w configpassword \
    -b olcDatabase={2}mdb,cn=config \
    olcOverlay=syncprov dn | grep -q '^dn:'; then
  echo "syncprov already present"
else
  kubectl -n identity exec -i openldap-0 -- \
    /opt/bitnami/openldap/bin/ldapmodify -a \
      -x -H ldap://127.0.0.1:1389 \
      -D cn=admin,cn=config -w configpassword \
    < /home/ubuntu/oke-amd-mi300x-ha-openldap-primary-syncprov.ldif
fi

echo "== Ensure Alice SSH test key and LDAP entries =="
mkdir -p /home/ubuntu/.ssh
chmod 700 /home/ubuntu/.ssh
if [ ! -f /home/ubuntu/.ssh/alice_slurm_test ]; then
  ssh-keygen -t ed25519 -N "" -f /home/ubuntu/.ssh/alice_slurm_test -C alice-slurm-test >/dev/null
fi
chmod 600 /home/ubuntu/.ssh/alice_slurm_test
ALICE_PUBKEY="$(cat /home/ubuntu/.ssh/alice_slurm_test.pub)"

ldapsearch_primary() {
  kubectl -n identity exec openldap-0 -- \
    /opt/bitnami/openldap/bin/ldapsearch \
      -x -H ldap://127.0.0.1:1389 \
      -D cn=admin,dc=example,dc=org -w adminpassword "$@"
}

ldapadd_primary() {
  kubectl -n identity exec -i openldap-0 -- \
    /opt/bitnami/openldap/bin/ldapmodify -a \
      -x -H ldap://127.0.0.1:1389 \
      -D cn=admin,dc=example,dc=org -w adminpassword
}

ldapmodify_primary() {
  kubectl -n identity exec -i openldap-0 -- \
    /opt/bitnami/openldap/bin/ldapmodify \
      -x -H ldap://127.0.0.1:1389 \
      -D cn=admin,dc=example,dc=org -w adminpassword
}

ldap_entry_exists() {
  ldapsearch_primary -b "$1" -s base dn >/dev/null 2>&1
}

if ! ldap_entry_exists dc=example,dc=org; then
  printf "%s\n" \
    "dn: dc=example,dc=org" \
    "objectClass: top" \
    "objectClass: dcObject" \
    "objectClass: organization" \
    "o: Slurm Test" \
    "dc: example" | ldapadd_primary
fi

if ! ldap_entry_exists ou=People,dc=example,dc=org; then
  printf "%s\n" \
    "dn: ou=People,dc=example,dc=org" \
    "objectClass: organizationalUnit" \
    "ou: People" | ldapadd_primary
fi

if ! ldap_entry_exists ou=Groups,dc=example,dc=org; then
  printf "%s\n" \
    "dn: ou=Groups,dc=example,dc=org" \
    "objectClass: organizationalUnit" \
    "ou: Groups" | ldapadd_primary
fi

if ! ldap_entry_exists cn=alice,ou=Groups,dc=example,dc=org; then
  printf "%s\n" \
    "dn: cn=alice,ou=Groups,dc=example,dc=org" \
    "objectClass: top" \
    "objectClass: posixGroup" \
    "cn: alice" \
    "gidNumber: 10001" \
    "memberUid: alice" | ldapadd_primary
fi

if ! ldap_entry_exists cn=project-a,ou=Groups,dc=example,dc=org; then
  printf "%s\n" \
    "dn: cn=project-a,ou=Groups,dc=example,dc=org" \
    "objectClass: top" \
    "objectClass: posixGroup" \
    "cn: project-a" \
    "gidNumber: 11001" \
    "memberUid: alice" | ldapadd_primary
fi

if ldap_entry_exists uid=alice,ou=People,dc=example,dc=org; then
  printf "%s\n" \
    "dn: uid=alice,ou=People,dc=example,dc=org" \
    "changetype: modify" \
    "replace: description" \
    "description: ${ALICE_PUBKEY}" | ldapmodify_primary
else
  printf "%s\n" \
    "dn: uid=alice,ou=People,dc=example,dc=org" \
    "objectClass: inetOrgPerson" \
    "objectClass: posixAccount" \
    "objectClass: shadowAccount" \
    "cn: Alice Slurm" \
    "sn: Slurm" \
    "uid: alice" \
    "uidNumber: 10001" \
    "gidNumber: 10001" \
    "homeDirectory: /home/alice" \
    "loginShell: /bin/bash" \
    "userPassword: alicepw" \
    "description: ${ALICE_PUBKEY}" | ldapadd_primary
fi

for pod in openldap-0 openldap-readonly-0 openldap-readonly-1; do
  kubectl -n identity exec "$pod" -- \
    /opt/bitnami/openldap/bin/ldapsearch \
      -LLL -x -H ldap://127.0.0.1:1389 \
      -D cn=admin,dc=example,dc=org -w adminpassword \
      -b dc=example,dc=org "(uid=alice)" dn uid uidNumber gidNumber description
done

echo "== Copy OpenLDAP CA into the slurm namespace =="
CRT="$(kubectl -n identity get secret openldap-tls -o jsonpath='{.data.ca\.crt}')"
if [ -z "$CRT" ]; then
  CRT="$(kubectl -n identity get secret openldap-ca-root -o jsonpath='{.data.tls\.crt}')"
fi
kubectl -n slurm create secret generic openldap-ca \
  --from-literal=ca.crt="$(printf '%s' "$CRT" | base64 -d)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "== Deploy FSS-backed /home =="
kubectl apply -f /home/ubuntu/oke-amd-mi300x-slurm-home-pvc.yaml
kubectl -n slurm get pvc slurm-home

echo "== Deploy MariaDB operator and accounting database =="
helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator --force-update
helm repo update mariadb-operator
helm upgrade --install mariadb-operator-crds mariadb-operator/mariadb-operator-crds \
  --namespace mariadb --create-namespace
helm upgrade --install mariadb-operator mariadb-operator/mariadb-operator \
  --namespace mariadb --create-namespace
kubectl -n mariadb rollout status deploy/mariadb-operator-webhook --timeout=180s
kubectl -n mariadb rollout status deploy/mariadb-operator-cert-controller --timeout=180s
kubectl apply -f /home/ubuntu/oke-amd-mi300x-mariadb.yaml
kubectl -n slurm wait --for=condition=Ready pod/mariadb-0 --timeout=420s

echo "== Deploy Slurm with HA LDAP, FSS, accounting, and AMD AutoDetect=rsmi =="
helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  -n slurm \
  -f /home/ubuntu/oke-amd-mi300x-hostnetwork-ha-openldap-slurm.values.yaml
kubectl -n slurm wait --for=condition=Ready pod/slurm-controller-0 --timeout=420s
kubectl -n slurm rollout status deploy/slurm-login-slinky --timeout=420s
kubectl -n slurm rollout status statefulset/slurm-accounting --timeout=420s
kubectl -n slurm wait --for=condition=Ready pod/slurm-worker-mi300x-0 --timeout=900s

echo "== Create Alice home on FSS =="
kubectl -n slurm exec deploy/slurm-login-slinky -c login -- sh -lc '
  mkdir -p /home/alice
  chown 10001:10001 /home/alice
  chmod 700 /home/alice
  chmod 711 /home
  ls -ld /home /home/alice
'

echo "== Seed Slurm accounting association =="
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- sh -lc '
  sacctmgr -i add account project-a Description="Project A" Organization=example || true
  sacctmgr -i add user name=alice account=project-a defaultaccount=project-a || true
  sacctmgr -nP show assoc user=alice format=User,Account,DefaultQOS,QOS
'

echo "== Validation snapshot =="
kubectl -n identity get pods -o wide
kubectl -n slurm get pods -o wide
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- getent passwd alice
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- id alice
kubectl -n slurm exec deploy/slurm-login-slinky -c login -- getent passwd alice
kubectl -n slurm exec deploy/slurm-login-slinky -c login -- id alice
kubectl -n slurm exec slurm-worker-mi300x-0 -c slurmd -- getent passwd alice
kubectl -n slurm exec slurm-worker-mi300x-0 -c slurmd -- id alice
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- sinfo -N -o "%N|%t|%C|%m|%G|%E"
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- scontrol show node | egrep "NodeName=|Gres=|CfgTRES=|AllocTRES=|Reason=|State="
