# Start Here: Full Multi-User Slurm Operator on OKE

This is the entry point for deploying the full tested stack:

- Slinky Slurm Operator and CRDs;
- Slurm controller, login, worker, REST, and accounting services;
- HA OpenLDAP with one writable primary and read replicas;
- SSSD/NSS identity resolution in login, worker, and controller pods;
- OCI FSS mounted at `/home`;
- MariaDB-backed SlurmDBD accounting;
- shape-specific worker configuration for `BM.GPU4.8`, `BM.GPU.GB200.4`,
  `BM.GPU.GB300.4`, and `BM.GPU.MI300X.8`;
- optional GB300 IMEX/DRA and topology-aware placement.

The goal is a normal Slurm user experience even though Slurm runs on
Kubernetes: a user SSHs to a login endpoint, lands in their FSS-backed home
directory, submits jobs as their real POSIX identity, and sees correct Slurm
accounting.

## Read This First

Use this guide as the ordered path. The lower-level documents stay useful when
you need implementation details, test logs, or one-off debugging notes.

Run workstation commands from the root of this repository. Run cluster commands
from the OKE operator node with `kubectl`, `helm`, and `oci` configured.

The checked-in OpenLDAP values and test users contain sample credentials. They
are for repeatable validation, not production secrets.

## Supported Deployment Paths

Pick one shape and follow only that shape's worker values. Do not mix
hostNetwork values, GPU counts, CPU topology, or worker images between shapes.

| Shape | Worker mode | Worker arch | GPU detection | Worker image path | Status |
| --- | --- | --- | --- | --- | --- |
| `BM.GPU4.8` | SR-IOV/VF pod networking | `amd64` | `AutoDetect=nvml` with NUMA-shaped dynamic-node topology | NVML worker image | Validated on A100-generation OKE |
| `BM.GPU.GB200.4` | `hostNetwork` | `arm64` | `AutoDetect=nvml` only | multi-platform NVML worker image | Validated on GB200 OKE |
| `BM.GPU.GB300.4` | `hostNetwork` | `arm64` | `AutoDetect=nvml` only | multi-platform NVML+NCCL worker image | Validated on GB300 OKE |
| `BM.GPU.MI300X.8` | `hostNetwork` | `amd64` | `AutoDetect=rsmi` | ROCm/RSMI/RCCL worker image | Validated on AMD MI300X OKE |

For `BM.GPU.GB200.4`, `BM.GPU.GB300.4`, and `BM.GPU.MI300X.8`, worker SSH
uses port `2222` because workers run with `hostNetwork` and must not conflict
with the node's own SSH daemon on port `22`. Do not copy this setting into the
`BM.GPU4.8` SR-IOV/VF path.

## Architecture

The deployed model is intentionally close to a traditional Slurm cluster:

| Layer | Kubernetes resource | Slurm or Linux role |
| --- | --- | --- |
| Identity | `identity/openldap-0` | writable LDAP primary |
| Identity | `identity/openldap-readonly-*` | LDAP read replicas for SSSD |
| Identity client | SSSD sidecars/config in Slurm pods | POSIX UID/GID, groups, SSH keys |
| Home | PVC `slurm/slurm-home` bound to PV `fss-pv` | shared `/home` from OCI FSS |
| Accounting | MariaDB plus `slurmdbd` | accounts, associations, usage history |
| Slurm control | `slurm-controller-0` | `slurmctld`, controller-side NSS lookup |
| User access | `slurm-login-slinky` service | SSH login and job submission |
| Workers | shape-specific NodeSet pods | `slurmd`, GPUs, RDMA, FSS home mount |

LDAP owns POSIX users and groups. FSS owns home directories. SlurmDBD owns
Slurm accounts, associations, limits, and job accounting. Keep those
responsibilities separate.

## Repository Files

The most important files are:

| File | Purpose |
| --- | --- |
| `slurm-operator/docs/usage/oke-slurm-shape-runbooks.md` | Detailed shape-specific runbooks and test status |
| `slurm-operator/docs/usage/ldap-sssd-ha-openldap.md` | HA OpenLDAP design notes |
| `slurm-operator/docs/usage/user-identity-home-and-accounting.md` | Identity, FSS, and accounting design details |
| `slurm-operator/docs/usage/slinky-container-images.md` | Container image inventory |
| `guides/slurm-operator/multi-user-oke/admin-workflows.md` | Operator workflows for onboarding and offboarding users |
| `guides/slurm-operator/multi-user-oke/product-requirements.md` | PRD and architecture diagram |

Shape-specific deployment files:

| Shape | Required files |
| --- | --- |
| `BM.GPU4.8` | `slurm-operator/docs/usage/oke-bm-gpu4-8-fss-sssd-ha-openldap-controller-sssd-autodetect-nvml-numa-topology.overlay.yaml` |
| `BM.GPU.GB200.4` | `slurm-operator/docs/usage/oke-gb200-ha-openldap-prereqs.yaml`, `oke-gb200-ha-openldap.values.yaml`, `oke-gb200-ha-openldap-tls-config.ldif`, `oke-gb200-ha-openldap-primary-syncprov.ldif`, `oke-gb200-slurm-home-pvc.yaml`, `oke-gb200-mariadb.yaml`, `oke-gb200-hostnetwork-ha-openldap-slurm.values.yaml` |
| `BM.GPU.GB300.4` | `slurm-operator/docs/usage/oke-gb300-ha-openldap-prereqs.yaml`, `oke-gb300-ha-openldap.values.yaml`, `oke-gb300-ha-openldap-tls-config.ldif`, `oke-gb300-ha-openldap-primary-syncprov.ldif`, `oke-gb300-slurm-home-pvc.yaml`, `oke-gb300-mariadb.yaml`, `oke-gb300-hostnetwork-ha-openldap-slurm.values.yaml`, `oke-gb300-ha-openldap-deploy.sh` |
| `BM.GPU.MI300X.8` | `slurm-operator/docs/usage/oke-amd-mi300x-ha-openldap-prereqs.yaml`, `oke-amd-mi300x-ha-openldap.values.yaml`, `oke-amd-mi300x-ha-openldap-tls-config.ldif`, `oke-amd-mi300x-ha-openldap-primary-syncprov.ldif`, `oke-amd-mi300x-slurm-home-pvc.yaml`, `oke-amd-mi300x-mariadb.yaml`, `oke-amd-mi300x-hostnetwork-ha-openldap-slurm.values.yaml`, `oke-amd-mi300x-ha-openldap-deploy.sh`, `oke-amd-mi300x-slurm-rccl.sbatch` |

Optional GB300 files:

| File | Purpose |
| --- | --- |
| `slurm-operator/docs/usage/oke-gb300-imex-dra-computedomain.yaml` | NVIDIA DRA `ComputeDomain` for the IMEX channel |
| `slurm-operator/docs/usage/oke-gb300-imex-dra-overlay.values.yaml` | Slurm overlay for `switch/nvidia_imex` and the DRA claim |
| `slurm-operator/docs/usage/oke-gb300-devin-nccl-demo.md` | End-to-end user demo with `devin` and NCCL tests |
| `slurm-operator/docs/usage/oke-gb300-topograph-topology.md` | Optional Topograph topology notes |

## Prerequisites

OKE cluster:

- one CPU/operator node pool for controller, login, accounting, and identity
  services;
- one GPU node pool using exactly one of the supported shapes above;
- Kubernetes access from the operator node;
- OCI CLI available on the operator node with instance principal auth;
- NVIDIA GPU Operator installed for NVIDIA shapes;
- SR-IOV/VF networking configured for `BM.GPU4.8` only;
- `hostNetwork` acceptable for `BM.GPU.GB200.4`, `BM.GPU.GB300.4`, and
  `BM.GPU.MI300X.8`;
- OCI FSS PV named `fss-pv`;
- block storage class `oci-bv`;
- enough service quota for the login `LoadBalancer`.

Operator node tools:

```bash
kubectl version --client
helm version
oci --version
```

Set the operator-node environment:

```bash
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

Verify cluster basics:

```bash
kubectl get nodes -o wide
kubectl get pv fss-pv
kubectl get storageclass oci-bv
kubectl get pods -A
```

Verify the GPU node shape:

```bash
kubectl get nodes -L node.kubernetes.io/instance-type
```

## Step 1: Copy the Shape Files to the Operator Node

From your workstation, copy the files for your shape to `/home/ubuntu` on the
operator node. Replace `BASTION` and `OPERATOR_PRIVATE_IP`.

For `BM.GPU.GB300.4`:

```bash
scp -o ProxyJump=ubuntu@BASTION \
  slurm-operator/docs/usage/oke-gb300-ha-openldap-prereqs.yaml \
  slurm-operator/docs/usage/oke-gb300-ha-openldap.values.yaml \
  slurm-operator/docs/usage/oke-gb300-ha-openldap-tls-config.ldif \
  slurm-operator/docs/usage/oke-gb300-ha-openldap-primary-syncprov.ldif \
  slurm-operator/docs/usage/oke-gb300-slurm-home-pvc.yaml \
  slurm-operator/docs/usage/oke-gb300-mariadb.yaml \
  slurm-operator/docs/usage/oke-gb300-hostnetwork-ha-openldap-slurm.values.yaml \
  slurm-operator/docs/usage/oke-gb300-imex-dra-computedomain.yaml \
  slurm-operator/docs/usage/oke-gb300-imex-dra-overlay.values.yaml \
  slurm-operator/docs/usage/oke-gb300-ha-openldap-deploy.sh \
  ubuntu@OPERATOR_PRIVATE_IP:/home/ubuntu/
```

For `BM.GPU.MI300X.8`:

```bash
scp -o ProxyJump=ubuntu@BASTION \
  slurm-operator/docs/usage/oke-amd-mi300x-ha-openldap-prereqs.yaml \
  slurm-operator/docs/usage/oke-amd-mi300x-ha-openldap.values.yaml \
  slurm-operator/docs/usage/oke-amd-mi300x-ha-openldap-tls-config.ldif \
  slurm-operator/docs/usage/oke-amd-mi300x-ha-openldap-primary-syncprov.ldif \
  slurm-operator/docs/usage/oke-amd-mi300x-slurm-home-pvc.yaml \
  slurm-operator/docs/usage/oke-amd-mi300x-mariadb.yaml \
  slurm-operator/docs/usage/oke-amd-mi300x-hostnetwork-ha-openldap-slurm.values.yaml \
  slurm-operator/docs/usage/oke-amd-mi300x-ha-openldap-deploy.sh \
  slurm-operator/docs/usage/oke-amd-mi300x-slurm-rccl.sbatch \
  ubuntu@OPERATOR_PRIVATE_IP:/home/ubuntu/
```

For `BM.GPU.GB200.4`:

```bash
scp -o ProxyJump=ubuntu@BASTION \
  slurm-operator/docs/usage/oke-gb200-ha-openldap-prereqs.yaml \
  slurm-operator/docs/usage/oke-gb200-ha-openldap.values.yaml \
  slurm-operator/docs/usage/oke-gb200-ha-openldap-tls-config.ldif \
  slurm-operator/docs/usage/oke-gb200-ha-openldap-primary-syncprov.ldif \
  slurm-operator/docs/usage/oke-gb200-slurm-home-pvc.yaml \
  slurm-operator/docs/usage/oke-gb200-mariadb.yaml \
  slurm-operator/docs/usage/oke-gb200-hostnetwork-ha-openldap-slurm.values.yaml \
  ubuntu@OPERATOR_PRIVATE_IP:/home/ubuntu/
```

For `BM.GPU4.8`:

```bash
scp -o ProxyJump=ubuntu@BASTION \
  slurm-operator/docs/usage/oke-bm-gpu4-8-fss-sssd-ha-openldap-controller-sssd-autodetect-nvml-numa-topology.overlay.yaml \
  ubuntu@OPERATOR_PRIVATE_IP:/home/ubuntu/values-bm-gpu4-8-full.yaml
```

The `BM.GPU4.8` Slurm values expect the HA LDAP, FSS, and accounting
prerequisites to exist. You can reuse the HA OpenLDAP chart flow from the GB200
or GB300 files after checking the CPU node selector in the OpenLDAP values
matches your operator pool.

SSH to the operator node:

```bash
ssh -J ubuntu@BASTION ubuntu@OPERATOR_PRIVATE_IP
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

## Step 2: Validate Shape Prerequisites

For `BM.GPU4.8`:

```bash
kubectl get nodes -l node.kubernetes.io/instance-type=BM.GPU4.8 -o wide
kubectl get network-attachment-definitions -A | grep sriov-rdma-vf
kubectl get pv fss-pv
kubectl get storageclass oci-bv
```

Expected worker assumptions:

- 8 GPUs per node;
- 16 SR-IOV RDMA VFs per node;
- no `hostNetwork` worker SSH override;
- SMT disabled when using the validated NUMA-shaped NVML topology path.

For `BM.GPU.GB200.4`:

```bash
kubectl get nodes -l node.kubernetes.io/instance-type=BM.GPU.GB200.4 -o wide
kubectl get pv fss-pv
kubectl get storageclass oci-bv
```

Expected worker assumptions:

- 4 GPUs per node;
- `hostNetwork`;
- worker SSH on port `2222`;
- `AutoDetect=nvml` only, with no static socket/core topology.

For `BM.GPU.GB300.4`:

```bash
kubectl get nodes -l node.kubernetes.io/instance-type=BM.GPU.GB300.4 -o wide
kubectl get pv fss-pv
kubectl get storageclass oci-bv
```

Expected worker assumptions:

- 4 GPUs per node;
- `hostNetwork`;
- worker SSH on port `2222`;
- `AutoDetect=nvml` only, with no static socket/core topology;
- optional IMEX/DRA and NCCL test support through the combined NVML+NCCL
  worker image.

For `BM.GPU.MI300X.8`:

```bash
kubectl get nodes -l node.kubernetes.io/instance-type=BM.GPU.MI300X.8 -o wide
kubectl get pv fss-pv
kubectl get storageclass oci-bv
kubectl get pods -n kube-system | grep -i amd
```

Expected worker assumptions:

- 8 GPUs per node;
- Kubernetes GPU resource `amd.com/gpu`;
- `hostNetwork`;
- worker SSH on port `2222`;
- `AutoDetect=rsmi`;
- ROCm/RSMI/RCCL worker image.

## Step 3: Install cert-manager

HA OpenLDAP TLS certificates are generated by cert-manager.

```bash
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true

kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=180s
```

## Step 4: Install the Slinky Operator

Skip this step if you are using a scripted full-stack path in
[Step 9](#step-9-deploy-the-full-scripted-stack). The scripts install or
refresh the operator for you.

```bash
helm upgrade --install slurm-operator-crds \
  oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
  --namespace=slinky \
  --create-namespace

helm upgrade --install slurm-operator \
  oci://ghcr.io/slinkyproject/charts/slurm-operator \
  --namespace=slinky \
  --create-namespace

kubectl -n slinky rollout status deployment/slurm-operator-webhook --timeout=180s
```

## Step 5: Deploy HA OpenLDAP

The HA LDAP topology is one writable primary plus read replicas:

- `openldap-0` accepts writes;
- `openldap-readonly-0` and `openldap-readonly-1` serve reads;
- SSSD clients use LDAPS and fail over between read and primary endpoints.

For `BM.GPU.GB300.4` and `BM.GPU.MI300X.8`, the full deployment scripts run
this section for you. If you want the fast path, install cert-manager, then skip
to [Step 9](#step-9-deploy-the-full-scripted-stack).

For `BM.GPU.GB200.4`, use the same commands with the `gb200` filenames:

```bash
helm repo add helm-openldap https://jp-gouin.github.io/helm-openldap/ --force-update
helm repo update helm-openldap

kubectl apply -f /home/ubuntu/oke-gb200-ha-openldap-prereqs.yaml
kubectl -n identity wait --for=condition=Ready certificate/openldap-tls --timeout=180s

helm upgrade --install openldap helm-openldap/openldap-stack-ha \
  --version 4.3.3 \
  -n identity \
  -f /home/ubuntu/oke-gb200-ha-openldap.values.yaml

kubectl -n identity rollout status statefulset/openldap --timeout=420s
kubectl -n identity rollout status statefulset/openldap-readonly --timeout=420s
```

Apply the TLS config fix to each LDAP pod:

```bash
for pod in openldap-0 openldap-readonly-0 openldap-readonly-1; do
  kubectl -n identity exec -i "$pod" -- \
    /opt/bitnami/openldap/bin/ldapmodify \
      -x -H ldap://127.0.0.1:1389 \
      -D cn=admin,cn=config -w configpassword \
    < /home/ubuntu/oke-gb200-ha-openldap-tls-config.ldif
done
```

Ensure the primary data database has the `syncprov` overlay:

```bash
if kubectl -n identity exec openldap-0 -- \
  /opt/bitnami/openldap/bin/ldapsearch \
    -x -H ldap://127.0.0.1:1389 \
    -D cn=admin,cn=config -w configpassword \
    -b olcDatabase={2}mdb,cn=config \
    olcOverlay=syncprov dn | grep -q '^dn:'; then
  echo "syncprov already present"
else
  kubectl -n identity exec -i openldap-0 -- \
    /opt/bitnami/openldap/bin/ldapadd \
      -x -H ldap://127.0.0.1:1389 \
      -D cn=admin,cn=config -w configpassword \
    < /home/ubuntu/oke-gb200-ha-openldap-primary-syncprov.ldif
fi
```

For `BM.GPU.GB300.4`, use the same manual commands with `gb300` filenames if
you are not using the script. For `BM.GPU.MI300X.8`, use the same manual
commands with `amd-mi300x` filenames.

## Step 6: Copy the LDAP CA to the Slurm Namespace

Slurm pods mount this CA so SSSD can verify LDAPS.

```bash
CRT="$(kubectl -n identity get secret openldap-tls -o jsonpath='{.data.ca\.crt}')"
if [ -z "$CRT" ]; then
  CRT="$(kubectl -n identity get secret openldap-ca-root -o jsonpath='{.data.tls\.crt}')"
fi

kubectl -n slurm create secret generic openldap-ca \
  --from-literal=ca.crt="$(printf '%s' "$CRT" | base64 -d)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Step 7: Deploy FSS Home and Accounting

Deploy the FSS-backed `/home` PVC. For `BM.GPU.GB200.4`:

```bash
kubectl apply -f /home/ubuntu/oke-gb200-slurm-home-pvc.yaml
kubectl -n slurm get pvc slurm-home
```

For `BM.GPU.GB300.4`, use:

```bash
kubectl apply -f /home/ubuntu/oke-gb300-slurm-home-pvc.yaml
kubectl -n slurm get pvc slurm-home
```

For `BM.GPU.MI300X.8`, use:

```bash
kubectl apply -f /home/ubuntu/oke-amd-mi300x-slurm-home-pvc.yaml
kubectl -n slurm get pvc slurm-home
```

The PVC should bind to `fss-pv`.

Install the MariaDB operator and accounting database. For `BM.GPU.GB200.4`:

```bash
helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator --force-update
helm repo update mariadb-operator

helm upgrade --install mariadb-operator-crds mariadb-operator/mariadb-operator-crds \
  --namespace mariadb \
  --create-namespace

helm upgrade --install mariadb-operator mariadb-operator/mariadb-operator \
  --namespace mariadb \
  --create-namespace

kubectl -n mariadb rollout status deploy/mariadb-operator-webhook --timeout=180s
kubectl -n mariadb rollout status deploy/mariadb-operator-cert-controller --timeout=180s

kubectl apply -f /home/ubuntu/oke-gb200-mariadb.yaml
kubectl -n slurm wait --for=condition=Ready pod/mariadb-0 --timeout=420s
```

For `BM.GPU.GB300.4`, replace `gb200` with `gb300`. For
`BM.GPU.MI300X.8`, replace `gb200` with `amd-mi300x`.

For `BM.GPU4.8`, create an equivalent `slurm-home` PVC bound to `fss-pv` and a
MariaDB accounting database before applying the BM.GPU4.8 values overlay. The
existing GB200/GB300 PVC and MariaDB manifests are good templates.

## Step 8: Deploy Slurm for the Selected Shape

For `BM.GPU.GB200.4`:

```bash
helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  -n slurm \
  -f /home/ubuntu/oke-gb200-hostnetwork-ha-openldap-slurm.values.yaml
```

For `BM.GPU.GB300.4`, if you are not using the deployment script:

```bash
helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  -n slurm \
  -f /home/ubuntu/oke-gb300-hostnetwork-ha-openldap-slurm.values.yaml
```

For `BM.GPU.MI300X.8`, if you are not using the deployment script:

```bash
helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  -n slurm \
  -f /home/ubuntu/oke-amd-mi300x-hostnetwork-ha-openldap-slurm.values.yaml
```

For `BM.GPU4.8`:

```bash
helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  -n slurm \
  -f /home/ubuntu/values-bm-gpu4-8-full.yaml
```

Wait for the core pods:

```bash
kubectl -n slurm wait --for=condition=Ready pod/slurm-controller-0 --timeout=420s
kubectl -n slurm rollout status deploy/slurm-login-slinky --timeout=420s
kubectl -n slurm rollout status statefulset/slurm-accounting --timeout=420s
kubectl -n slurm get pods -o wide
```

Wait for the worker NodeSet that matches your shape:

```bash
# GB200 only:
kubectl -n slurm wait --for=condition=Ready pod/slurm-worker-gb200-0 --timeout=420s

# GB300 only:
kubectl -n slurm wait --for=condition=Ready pod/slurm-worker-gb300-0 --timeout=420s

# AMD MI300X only:
kubectl -n slurm wait --for=condition=Ready pod/slurm-worker-mi300x-0 --timeout=420s
```

Use the actual worker pod name for `BM.GPU4.8`.

## Step 9: Deploy the Full Scripted Stack

For `BM.GPU.GB300.4`, the checked-in script is the preferred fast path:

```bash
bash /home/ubuntu/oke-gb300-ha-openldap-deploy.sh
```

The script:

- installs or refreshes the Slinky operator;
- deploys HA OpenLDAP;
- applies the LDAP TLS and `syncprov` fixes;
- creates the test LDAP user `alice` and SSH key if missing;
- copies the LDAP CA into the `slurm` namespace;
- creates the FSS-backed `slurm-home` PVC;
- installs MariaDB and SlurmDBD accounting;
- deploys the GB300 Slurm values with `AutoDetect=nvml`;
- creates `/home/alice` on FSS;
- seeds the `project-a` Slurm account and Alice association;
- prints a validation snapshot.

For `BM.GPU.MI300X.8`, the checked-in script is the preferred fast path:

```bash
bash /home/ubuntu/oke-amd-mi300x-ha-openldap-deploy.sh
```

The MI300X script follows the same HA LDAP, FSS, accounting, Alice bootstrap,
and validation flow, then deploys the AMD `hostNetwork` Slurm values with
`AutoDetect=rsmi`.

Use the manual sections above when adapting the stack to GB200 or BM.GPU4.8.

## Step 10: Add a Real User

The deployment script creates `alice` for validation. For a real user, add the
LDAP user, primary group, project group, FSS home, and SlurmDBD association.
The same flow is documented in
`guides/slurm-operator/multi-user-oke/admin-workflows.md`.

Example for user `devin`:

```bash
ssh-keygen -t ed25519 -N "" -f /home/ubuntu/.ssh/devin_slurm_demo -C devin-slurm-demo
DEVIN_PUBKEY="$(cat /home/ubuntu/.ssh/devin_slurm_demo.pub)"
```

Add or modify LDAP entries on the writable primary:

```bash
cat >/tmp/devin.ldif <<EOF
dn: cn=devin,ou=Groups,dc=example,dc=org
objectClass: top
objectClass: posixGroup
cn: devin
gidNumber: 10002
memberUid: devin

dn: cn=project-devin,ou=Groups,dc=example,dc=org
objectClass: top
objectClass: posixGroup
cn: project-devin
gidNumber: 11002
memberUid: devin

dn: uid=devin,ou=People,dc=example,dc=org
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: Devin Slurm
sn: Slurm
uid: devin
uidNumber: 10002
gidNumber: 10002
homeDirectory: /home/devin
loginShell: /bin/bash
userPassword: devinpw
description: ${DEVIN_PUBKEY}
EOF

kubectl -n identity cp /tmp/devin.ldif openldap-0:/tmp/devin.ldif
kubectl -n identity exec openldap-0 -- \
  /opt/bitnami/openldap/bin/ldapadd \
    -x -H ldap://127.0.0.1:1389 \
    -D cn=admin,dc=example,dc=org -w adminpassword \
    -f /tmp/devin.ldif
```

Create the FSS home:

```bash
kubectl -n slurm exec deploy/slurm-login-slinky -c login -- sh -lc '
  mkdir -p /home/devin
  chown 10002:10002 /home/devin
  chmod 700 /home/devin
  chmod 711 /home
  ls -ld /home /home/devin
'
```

Create the Slurm accounting association:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- sh -lc '
  sacctmgr -i add account project-devin Description="Project Devin" Organization=example || true
  sacctmgr -i add user name=devin account=project-devin defaultaccount=project-devin || true
  sacctmgr -nP show assoc user=devin format=User,Account,DefaultQOS,QOS
'
```

## Step 11: Validate Identity, Home, and Accounting

Validate LDAP/SSSD from controller, login, and worker pods:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- getent passwd devin
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- id devin

kubectl -n slurm exec deploy/slurm-login-slinky -c login -- getent passwd devin
kubectl -n slurm exec deploy/slurm-login-slinky -c login -- id devin
kubectl -n slurm exec deploy/slurm-login-slinky -c login -- sss_ssh_authorizedkeys devin

kubectl -n slurm exec slurm-worker-gb300-0 -c slurmd -- getent passwd devin
kubectl -n slurm exec slurm-worker-gb300-0 -c slurmd -- id devin
```

Use the actual worker pod for your shape. Some containers do not include
`sss_cache`; rely on `getent`, `id`, and `sss_ssh_authorizedkeys` for the
portable validation path.

Validate SSH and FSS isolation:

```bash
LOGIN_IP="$(kubectl -n slurm get svc slurm-login-slinky \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

ssh -i /home/ubuntu/.ssh/devin_slurm_demo \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  devin@"${LOGIN_IP}" \
  'whoami; id; pwd; ls -ld /home /home/devin; ls /home/alice 2>&1 || true'
```

Expected result:

- `whoami` returns `devin`;
- `pwd` is `/home/devin`;
- `/home/devin` is owned by `devin`;
- other users' homes are not readable.

Validate Slurm sees the user and GPUs:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  sinfo -N -o '%N|%t|%C|%m|%G|%E'

ssh -i /home/ubuntu/.ssh/devin_slurm_demo \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  devin@"${LOGIN_IP}" \
  'squeue -u devin; sacct -u devin --format=JobID,User,Account,State,ExitCode -P | tail'
```

Submit a GPU smoke test. For NVIDIA shapes:

```bash
ssh -i /home/ubuntu/.ssh/devin_slurm_demo \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  devin@"${LOGIN_IP}" \
  'sbatch -A project-devin --gres=gpu:1 --wrap="hostname; nvidia-smi -L"'
```

For `BM.GPU.MI300X.8`:

```bash
ssh -i /home/ubuntu/.ssh/devin_slurm_demo \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  devin@"${LOGIN_IP}" \
  'sbatch -A project-devin --gres=gpu:1 --wrap="hostname; rocm-smi --showproductname --showdriverversion"'
```

Check accounting after the job finishes:

```bash
JOB=<job-id>

ssh -i /home/ubuntu/.ssh/devin_slurm_demo \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  devin@"${LOGIN_IP}" \
  "sacct -j ${JOB} --format=JobID,User,Account,State,ExitCode,AllocTRES%80,NodeList -P"
```

The top-level job row should show `User=devin` and `Account=project-devin`.
Batch and extern child rows may have an empty `User` column; that is normal
Slurm accounting output.

## Step 12: Run GB300 NCCL or MI300X RCCL Tests

This section applies to `BM.GPU.GB300.4` with the combined NVML+NCCL worker
image:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2
```

Use the demo guide:

```text
slurm-operator/docs/usage/oke-gb300-devin-nccl-demo.md
```

The tested NCCL launch pattern uses `eth0` instead of a hardcoded VCN CIDR and
opts into the NCCL/HPCX environment through `with-nccl-tests-env`.

Core launch settings:

```bash
--mca pml ob1
--mca btl tcp,self
--mca btl_tcp_if_include eth0
--mca oob_tcp_if_include eth0
-x RX_QUEUE_LEN=8192
-x IB_RX_QUEUE_LEN=8192
-x HCOLL_ENABLE_MCAST_ALL=0
-x coll_hcoll_enable=0
-x NCCL_TOPO_DUMP_FILE=/home/devin/nccl-topo-$(date +%F-%H%M%S).txt
-x NCCL_SOCKET_IFNAME=eth0
-x NCCL_IB_HCA=rdma_vf_rail0,rdma_vf_rail1,rdma_vf_rail2,rdma_vf_rail3
-x NCCL_IB_GID_INDEX=3
-x NCCL_NET_PLUGIN=spcx
-x NCCL_NET=IB
```

Use this `all_reduce_perf` range for the demo:

```bash
/opt/oci-hpc/nccl-tests/build/all_reduce_perf -b 8M -e 8G -f 2 -g 1 -n 30
```

The validated GB300 run completed on 4 nodes and 16 GPUs with `0 OK`.

For `BM.GPU.MI300X.8`, use the checked-in RCCL test log and Slurm batch script:

```text
slurm-operator/docs/usage/oke-amd-mi300x-rccl-test-log.md
slurm-operator/docs/usage/oke-amd-mi300x-slurm-rccl.sbatch
```

The validated MI300X run completed across 2 nodes and 16 GPUs with `0 OK`.

## Step 13: Enable Optional GB300 IMEX/DRA

The baseline Slurm deployment works without IMEX/DRA. Enable it when testing
GB300 large-scale NCCL behavior or per-job IMEX channels.

```bash
kubectl apply -f /home/ubuntu/oke-gb300-imex-dra-computedomain.yaml

helm -n slurm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  --reuse-values \
  -f /home/ubuntu/oke-gb300-imex-dra-overlay.values.yaml
```

Validate Slurm-side settings:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  scontrol show config | egrep '^(SwitchType|TopologyPlugin|GresTypes)'
```

Expected:

```text
GresTypes      = gpu
SwitchType     = switch/nvidia_imex
TopologyPlugin = topology/flat
```

Important behavior:

- Kubernetes still allocates GPUs to long-running Slinky worker pods through
  `nvidia.com/gpu`;
- Slurm users still request GPUs with Slurm GRES, such as `--gres=gpu:4`;
- the DRA `ComputeDomain` attaches an IMEX channel to the worker pod;
- the current baseline does not require Topograph for IMEX channel plumbing.

For per-job channel validation, use:

```text
slurm-operator/docs/usage/imex-per-job-channel-check.sbatch
```

Overlapping jobs on one worker must request bounded memory, for example
`--mem=16G`. With `SelectTypeParameters=CR_CORE_MEMORY`, a job that omits
`--mem` can consume the full node memory TRES and prevent overlap.

## Step 14: Optional Topology-Aware Placement

Start without topology automation. Add it only after the base HA LDAP, FSS,
accounting, GPU, and NCCL paths work.

Current documented options:

| Option | Use when |
| --- | --- |
| Manual topology overlay | You want deterministic block tests with known nodes |
| OCI-label generated topology | Nodes already have labels such as `oci.oraclecloud.com/rdma.local_block_id` |
| Topograph | You want a controller to keep Slinky topology data refreshed |

Relevant docs:

```text
slurm-operator/docs/usage/oke-gb300-topology-block-test-log.md
slurm-operator/docs/usage/oke-gb300-oci-label-topology-test-log.md
slurm-operator/docs/usage/oke-gb300-topograph-topology.md
```

For Slurm, the important outcome is that each node has the right Slinky
topology annotation and Slurm topology config. The OCI-label path maps labels
such as `oci.oraclecloud.com/rdma.local_block_id` to Slurm blocks.

If a local block does not have enough nodes for a job, the topology should
include higher aggregate levels, such as network block or HPC island, so jobs
can span a valid larger group instead of staying pending while enough total
nodes exist elsewhere.

## Troubleshooting

LDAP replicas are empty:

- Confirm `syncprov` exists on the primary data database:
  `olcDatabase={2}mdb,cn=config`.
- Search each replica directly for the user.

SSSD lookup fails in Slurm pods:

- Check the `site-sssd-ha-ldap-conf` Secret in the `slurm` namespace.
- Check the `openldap-ca` Secret in the `slurm` namespace.
- Use `getent passwd USER`, `id USER`, and `sss_ssh_authorizedkeys USER`.
- Do not assume `sss_cache` exists in every container image.

SSH login works but jobs show the wrong user:

- Users must SSH as their own LDAP identity, not as `root`.
- Do not use `rootSshAuthorizedKeys` as the normal access path.

Home directory is visible or writable by other users:

- `/home` should be executable but not listable by users, commonly `711`.
- `/home/$USER` should be owned by the user's UID/GID and commonly `700`.

Accounting rejects jobs:

- Confirm `sacctmgr show assoc user=USER`.
- Confirm the user submits with the correct account or has the right default
  account.
- Confirm `AccountingStorageEnforce=associations,limits,qos` is set in the
  controller config.

GB200, GB300, or MI300X worker SSH conflicts:

- Host-network workers need `Port 2222`.
- Login pods still expose the normal SSH user entry point through the
  `slurm-login-slinky` service.

GB300 jobs do not overlap on one worker:

- Use bounded memory, for example `--mem=16G`.
- Without bounded memory, a job may reserve all node memory under
  `CR_CORE_MEMORY`.

NCCL fails before transport initialization:

- Verify the job uses `eth0` for OpenMPI TCP control traffic.
- Verify `NCCL_IB_GID_INDEX=3`.
- Verify all `rdma_vf_rail*` interfaces report the expected GID.
- Start with `NCCL_DEBUG=WARN` for normal testing and increase only when
  troubleshooting.

## Final Validation Checklist

Before handing the cluster to users, validate:

- `kubectl -n identity get pods` shows the OpenLDAP primary and replicas ready;
- `kubectl -n slurm get pvc slurm-home` is bound to `fss-pv`;
- `kubectl -n slurm get pods` shows controller, login, accounting, and worker
  pods ready;
- `getent passwd USER` and `id USER` work in controller, login, and worker
  pods;
- SSH as the user lands in `/home/USER`;
- the user cannot read another user's home directory;
- `sbatch` as the user completes a GPU job;
- `sacct` shows the user, account, allocated GPU TRES, node list, and final
  state;
- shape-specific GPU detection is correct in `sinfo` and `scontrol show node`;
- GB300 NCCL and IMEX/DRA validations pass if those optional paths are enabled;
- MI300X RCCL validation passes if using the AMD ROCm path.
