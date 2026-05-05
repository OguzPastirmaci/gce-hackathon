# OKE Slurm Shape Runbooks

Use this index first. The Slurm-on-OKE instructions are shape-specific because
GPU topology, CPU affinity, node architecture, and network mode differ by GPU
shape.

Pick the section that matches the OKE GPU node shape and follow only that
section's manifests and values. Do not mix worker values between shapes.

| Shape | Tested worker mode | Worker architecture | GPU detection | Worker sshd |
| --- | --- | --- | --- | --- |
| `BM.GPU4.8` | SR-IOV/VF pod networking | `amd64` | `AutoDetect=nvml` with NUMA-shaped dynamic-node topology | normal pod-networked sshd |
| `BM.GPU.GB200.4` | `hostNetwork` | `arm64` | `AutoDetect=nvml` only | `Port 2222` because of hostNetwork |

## Shape: BM.GPU4.8

Use this section for the previous A100 generation `BM.GPU4.8` clusters.

Current tested assumptions:

- worker architecture: `amd64`;
- worker network mode: SR-IOV/VF pod networking, not `hostNetwork`;
- expected RDMA resource: `nvidia.com/sriov-rdma-vf`;
- expected GPU count: 8 GPUs per node;
- expected RDMA VF count: 16 VFs per node;
- FSS home PVC: `slurm-home`, usually bound to `fss-pv`;
- identity path: LDAP through SSSD in login, worker, and controller pods;
- worker sshd: normal pod networking; do not force port `2222` for this path;
- tested NVML topology path: SMT disabled, `Parameters=numa_node_as_socket`,
  and Slinky dynamic-node registration with `SocketsPerBoard=8`,
  `CoresPerSocket=8`, `ThreadsPerCore=1`, and `CPUs=64`.

Primary docs and manifests:

| File | Purpose |
| --- | --- |
| `docs/usage/ldap-sssd-disposable-test.md` | Disposable LDAP/SSSD/FSS/accounting validation runbook for the BM.GPU4.8 path |
| `docs/usage/ldap-sssd-ha-openldap.md` | Production HA OpenLDAP identity design; use the BM.GPU4.8 shape notes in that guide |
| `docs/usage/oke-bm-gpu4-8-fss-sssd-ha-openldap-controller-sssd-autodetect-nvml-numa-topology.overlay.yaml` | BM.GPU4.8 values overlay for the SR-IOV/FSS/SSSD/accounting path |
| `docs/usage/oke-bm-gpu4-autodetect-test-log.md` | BM.GPU4.8 `AutoDetect=nvml` investigation log |

Important result from the BM.GPU4.8 `AutoDetect=nvml` investigation:

- Plain `AutoDetect=nvml`, the `l3cache_as_socket` variants, and passing only
  `--parameters numa_node_as_socket` to `slurmd` failed GRES validation because
  GPU core affinity did not match Slurm's registered socket boundaries.
- The working BM.GPU4.8 path uses `AutoDetect=nvml` plus NUMA-shaped topology
  in the NodeSet `extraConfMap`, which Slinky passes to dynamic-node
  registration through `slurmd -Z --conf`.
- Keep BM.GPU4.8 deployment instructions separate from GB200. The GB200
  `AutoDetect=nvml` hostNetwork path does not apply to BM.GPU4.8.

Deployment order for the BM.GPU4.8 identity path:

1. Use `ldap-sssd-disposable-test.md` for the disposable LDAP validation path,
   or use `ldap-sssd-ha-openldap.md` for the HA LDAP design.
2. From the workstation, copy the BM.GPU4.8 Slurm values overlay to the
   operator node. For the tested BM.GPU4.8 cluster:

```bash
scp -o ProxyJump=ubuntu@152.67.124.58 \
  docs/usage/oke-bm-gpu4-8-fss-sssd-ha-openldap-controller-sssd-autodetect-nvml-numa-topology.overlay.yaml \
  ubuntu@10.140.0.18:/home/ubuntu/values-fresh-nvml-autodetect-numa-topology.yaml
```

3. SSH to the BM.GPU4.8 operator node:

```bash
ssh -J ubuntu@152.67.124.58 ubuntu@10.140.0.18
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

4. Verify the shape and SR-IOV prerequisites:

```bash
kubectl get nodes -l node.kubernetes.io/instance-type=BM.GPU4.8
kubectl get network-attachment-definitions -A | grep sriov-rdma-vf
kubectl get pv fss-pv
kubectl -n slurm get pvc slurm-home
kubectl -n slurm get secret mariadb-password
```

5. Use the BM.GPU4.8 values overlay from the BM.GPU4.8 runbook. Do not use the
   GB200 hostNetwork values.
6. Deploy Slurm with the BM.GPU4.8 overlay after the LDAP, FSS, and accounting
   prerequisites are in place:

```bash
helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  -n slurm \
  -f /home/ubuntu/values-fresh-nvml-autodetect-numa-topology.yaml
```

7. Keep worker SSH on normal pod networking. Do not add `Port 2222` unless you
   deliberately switch this shape to hostNetwork.
8. Validate the result with the BM.GPU4.8 test log checks:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  sinfo -N -o '%N %t %G %E'

kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  scontrol show node gpu-b4-0 | grep -E 'Sockets=|CoresPerSocket=|ThreadsPerCore=|Gres=|Parameters='
```

## Shape: BM.GPU.GB200.4

Use this section for GB200 `BM.GPU.GB200.4` clusters.

Current tested assumptions:

- worker architecture: `arm64`;
- worker network mode in the tested cluster: `hostNetwork`;
- expected GPU count: 4 GPUs per node;
- Slurm GPU detection: `AutoDetect=nvml` only;
- Slurm worker image: multi-platform `linux/amd64` plus `linux/arm64`;
- worker sshd port: `2222`, only because `hostNetwork` would otherwise
  conflict with the node's own sshd on port `22`;
- controller/login/accounting/identity pods: pinned to CPU nodes in the tested
  values;
- FSS home PVC: `slurm-home`, bound to `fss-pv`;
- identity path: HA OpenLDAP through SSSD in login, worker, and controller pods;
- accounting path: MariaDB plus SlurmDBD.

Primary docs and manifests:

| File | Purpose |
| --- | --- |
| `docs/usage/oke-gb200-ha-openldap-test-log.md` | End-to-end GB200 HA OpenLDAP, SSSD, FSS, SSH, Slurm, and accounting validation log |
| `docs/usage/oke-gb200-ha-openldap-prereqs.yaml` | Namespaces, cert-manager CA/server certs, and SSSD Secret |
| `docs/usage/oke-gb200-ha-openldap.values.yaml` | HA OpenLDAP Helm values for one writable primary and two read replicas |
| `docs/usage/oke-gb200-ha-openldap-tls-config.ldif` | OpenLDAP `cn=config` TLS fix used by this chart |
| `docs/usage/oke-gb200-ha-openldap-primary-syncprov.ldif` | Primary `mdb` `syncprov` overlay required for read-replica replication |
| `docs/usage/oke-gb200-slurm-home-pvc.yaml` | FSS-backed `/home` PVC bound to `fss-pv` |
| `docs/usage/oke-gb200-mariadb.yaml` | MariaDB CR used by SlurmDBD accounting |
| `docs/usage/oke-gb200-hostnetwork-ha-openldap-slurm.values.yaml` | Full GB200 hostNetwork Slurm values with HA LDAP/SSSD/FSS/accounting |
| `docs/usage/oke-gb200-hostnetwork-autodetect-nvml.values.yaml` | Minimal GB200 hostNetwork `AutoDetect=nvml` Slurm validation values |
| `docs/usage/oke-gb200-autodetect-nvml-test-log.md` | GB200 `AutoDetect=nvml` image build and validation log |

Deployment order for the tested GB200 path:

1. From the workstation, copy the GB200 manifests from this repo to the
   operator node, preserving the `/home/ubuntu/` paths used by the commands
   below. For the tested GB200 cluster:

```bash
scp -o ProxyJump=ubuntu@192.9.189.161 \
  docs/usage/oke-gb200-ha-openldap-prereqs.yaml \
  docs/usage/oke-gb200-ha-openldap.values.yaml \
  docs/usage/oke-gb200-ha-openldap-tls-config.ldif \
  docs/usage/oke-gb200-ha-openldap-primary-syncprov.ldif \
  docs/usage/oke-gb200-slurm-home-pvc.yaml \
  docs/usage/oke-gb200-mariadb.yaml \
  docs/usage/oke-gb200-hostnetwork-ha-openldap-slurm.values.yaml \
  ubuntu@10.140.0.20:/home/ubuntu/
```

2. SSH to the GB200 operator node:

```bash
ssh -J ubuntu@192.9.189.161 ubuntu@10.140.0.20
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

3. Verify the cluster matches the GB200 hostNetwork path:

```bash
kubectl get nodes -l node.kubernetes.io/instance-type=BM.GPU.GB200.4 -o wide
kubectl get pv fss-pv
kubectl get storageclass oci-bv
```

4. Deploy HA OpenLDAP, FSS, MariaDB, and Slurm:

```bash
helm repo add helm-openldap https://jp-gouin.github.io/helm-openldap/ || true
helm repo update helm-openldap

kubectl apply -f /home/ubuntu/oke-gb200-ha-openldap-prereqs.yaml
kubectl -n identity wait --for=condition=Ready certificate/openldap-tls --timeout=180s

helm upgrade --install openldap helm-openldap/openldap-stack-ha \
  --version 4.3.3 \
  -n identity \
  -f /home/ubuntu/oke-gb200-ha-openldap.values.yaml

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

kubectl apply -f /home/ubuntu/oke-gb200-slurm-home-pvc.yaml

helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator || true
helm repo update mariadb-operator
helm upgrade --install mariadb-operator-crds mariadb-operator/mariadb-operator-crds \
  --namespace mariadb --create-namespace
helm upgrade --install mariadb-operator mariadb-operator/mariadb-operator \
  --namespace mariadb --create-namespace
kubectl -n mariadb rollout status deploy/mariadb-operator-webhook --timeout=180s
kubectl -n mariadb rollout status deploy/mariadb-operator-cert-controller --timeout=180s

kubectl apply -f /home/ubuntu/oke-gb200-mariadb.yaml
kubectl -n slurm wait --for=condition=Ready pod/mariadb-0 --timeout=420s

helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  -n slurm \
  -f /home/ubuntu/oke-gb200-hostnetwork-ha-openldap-slurm.values.yaml
```

Validated GB200 end state:

- Alice can SSH into `slurm-login-slinky` and lands in `/home/alice`.
- `getent passwd alice` and `id alice` work in controller, login, and worker
  pods through SSSD.
- Slurm sees node `10.140.64.164` with `gpu:4`.
- Job `6` completed as `alice` with `Account=project-a` and
  `AllocTRES=gres/gpu=1`.
