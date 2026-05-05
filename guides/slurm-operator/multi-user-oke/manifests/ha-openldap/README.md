# HA OpenLDAP Manifest Set

This directory contains an apply-ready HA OpenLDAP test deployment for the
multi-user Slurm on OKE guide.

The topology is single writable primary plus read replicas:

- `openldap-0`: writable primary;
- `openldap-1`: read replica using `syncrepl`;
- `openldap-2`: read replica using `syncrepl`.

The current manifest uses plaintext LDAP on port `389` and sample credentials
so it can be validated in the current OKE test cluster. Before using this as a
production identity source, replace the sample Secret values, enable LDAPS or
StartTLS, mount a trusted CA bundle into Slurm SSSD clients, and add backup,
restore, and replica-promotion runbooks.

## Deploy

```bash
kubectl apply -k guides/slurm-operator/multi-user-oke/manifests/ha-openldap
kubectl -n identity rollout status statefulset/openldap --timeout=10m
kubectl -n identity wait --for=condition=complete job/openldap-bootstrap --timeout=5m
```

## Validate

```bash
kubectl -n identity get pods,pvc,svc

for i in 0 1 2; do
  kubectl -n identity run "ldap-check-${i}" \
    --image=docker.io/osixia/openldap:1.5.0 \
    --restart=Never \
    --rm -i -- \
    ldapsearch -x \
      -H "ldap://openldap-${i}.openldap-headless.identity.svc.cluster.local:389" \
      -D cn=sssd-reader,ou=ServiceAccounts,dc=example,dc=org \
      -w readerpassword \
      -b dc=example,dc=org \
      '(uid=alice)' uid uidNumber gidNumber homeDirectory sshPublicKey
done
```

Test replication after bootstrap:

```bash
cat >/tmp/ha-ldap-bob.ldif <<'EOF'
dn: uid=bob,ou=People,dc=example,dc=org
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
objectClass: ldapPublicKey
cn: Bob Slurm
sn: Slurm
uid: bob
uidNumber: 10002
gidNumber: 10002
homeDirectory: /home/bob
loginShell: /bin/bash
sshPublicKey: ssh-ed25519 AAAA_REPLACE_ME bob@example
EOF

kubectl -n identity cp /tmp/ha-ldap-bob.ldif openldap-0:/tmp/bob.ldif
kubectl -n identity exec openldap-0 -- \
  ldapadd -x -H ldap://localhost:389 \
    -D cn=admin,dc=example,dc=org \
    -w adminpassword \
    -f /tmp/bob.ldif

kubectl -n identity exec openldap-1 -- \
  ldapsearch -x -H ldap://localhost:389 \
    -D cn=sssd-reader,ou=ServiceAccounts,dc=example,dc=org \
    -w readerpassword \
    -b dc=example,dc=org \
    '(uid=bob)' uid uidNumber
```

## Cleanup

This removes the test deployment and the test LDAP PVCs:

```bash
kubectl delete -k guides/slurm-operator/multi-user-oke/manifests/ha-openldap
kubectl -n identity delete pvc -l app.kubernetes.io/name=openldap
kubectl -n identity delete pvc ldap-data-openldap-0 ldap-data-openldap-1 ldap-data-openldap-2
kubectl -n identity delete pvc ldap-config-openldap-0 ldap-config-openldap-1 ldap-config-openldap-2
```
