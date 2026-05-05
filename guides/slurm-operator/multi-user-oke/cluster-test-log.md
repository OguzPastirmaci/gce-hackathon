# Multi-User OKE Slurm Test Log

Date: 2026-05-04

This file records the live-cluster exploration and test plan for adapting the
OKE Slurm deployment to a multi-user Slurm model with SR-IOV VFs and OCI FSS.

## Goal

Validate these instructions on the live OKE cluster:

- use SR-IOV VFs, not `hostNetwork`;
- use the existing FSS PersistentVolume `fss-pv` for `/home`;
- provide a normal Slurm user experience through SSH into login pods;
- make a test user visible to Slurm when submitting jobs;
- validate Slurm accounting once enabled.

## Local Guide Work Completed

Created a new guide directory:

```text
/Users/opastirm/Documents/Repos/guides/slurm-operator/multi-user-oke
```

Files created:

```text
multi-user-oke/README.md
multi-user-oke/fss-home.md
multi-user-oke/ldap-sssd-login.md
multi-user-oke/local-users-without-ldap.md
multi-user-oke/slurm-accounting.md
multi-user-oke/overlays/values-multi-user-base.yaml
```

Important note added to the guide: Helm replaces list values, so the multi-user
`/home` volume entries must be merged into existing RDMA lists. They should not
be blindly applied as a second `-f` values file over the SR-IOV values because
that could drop existing `/dev/infiniband` and `/dev/shm` mounts.

## Operator Node Access

The working SSH command is:

```bash
ssh -J ubuntu@152.67.124.58 ubuntu@10.140.0.18
```

The prior short host alias failed due to local SSH host-key/proxy issues.

For non-interactive commands, this form worked:

```bash
ssh -o BatchMode=yes \
  -o UserKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=no \
  -J ubuntu@152.67.124.58 ubuntu@10.140.0.18 \
  '<command>'
```

## OCI CLI and Kubernetes Auth

The OCI CLI is installed, but not on the non-interactive shell `PATH` by
default.

Located OCI CLI at:

```text
/home/ubuntu/bin/oci
/home/ubuntu/lib/oracle-cli/bin/oci
```

Kubeconfig uses an OCI exec plugin:

```text
oci ce cluster generate-token --cluster-id <cluster-ocid> --region ap-sydney-1
```

The kubeconfig exec stanza does not include `--auth instance_principal`.
Kubernetes API calls fail unless the environment sets instance-principal auth:

```bash
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

Validated that instance-principal OCI auth works:

```bash
oci iam region list --auth instance_principal
oci os ns get --auth instance_principal
```

Validated that Kubernetes API access works with:

```bash
export PATH=/home/ubuntu/bin:$PATH OCI_CLI_AUTH=instance_principal
kubectl get nodes -o wide
```

## Cluster State Discovered

Current Kubernetes context:

```text
slinky-tmband
```

Nodes:

```text
10.140.70.101   Ready   node     Ubuntu 22.04.5 LTS
10.140.76.140   Ready   <none>   Ubuntu 24.04.4 LTS
10.140.77.204   Ready   node     Ubuntu 22.04.5 LTS
10.140.89.40    Ready   <none>   Ubuntu 24.04.4 LTS
10.140.91.210   Ready   node     Ubuntu 22.04.5 LTS
```

GPU nodes:

```text
10.140.76.140
10.140.89.40
```

Each GPU node exposes:

```text
nvidia.com/gpu: 8
nvidia.com/sriov-rdma-vf: 16
```

This matches the requested test environment: two BM.GPU4.8 nodes with VFs.

## FSS State

PersistentVolume:

```text
name: fss-pv
status: Available
accessModes: ReadWriteMany
capacity: 50Gi
driver: fss.csi.oraclecloud.com
volumeHandle: ocid1.filesystem.oc1.ap_sydney_1.aaaaaaaaaan4akehon4willqojxwiotboawxg6lenzsxsljrfvqwiljr:10.140.0.114:/oke-gpu-tmband
reclaimPolicy: Retain
```

No PVC was bound to `fss-pv` at discovery time.

Observed PVCs were only monitoring-related `oci-bv` claims:

```text
monitoring/prometheus-prometheus-kube-prometheus-stack-prometheus-0
monitoring/storage-kube-prometheus-stack-grafana-0
```

Next required storage step:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: slurm-home
  namespace: slurm
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 50Gi
  volumeName: fss-pv
  storageClassName: ""
```

## SR-IOV State

NVIDIA Network Operator is installed.

The NetworkAttachmentDefinition exists only in `default`:

```text
default/sriov-rdma-vf
```

It references resource:

```text
nvidia.com/sriov-rdma-vf
```

The active `sriov-rdma-vf` config uses:

```json
{
  "type": "sriov",
  "ipam": {
    "type": "nv-ipam",
    "poolName": "sriov-pool"
  }
}
```

Next required network step before Slurm install:

```bash
kubectl create namespace slurm
kubectl get net-attach-def sriov-rdma-vf -n default -o json | \
  jq '.metadata = {name: .metadata.name, namespace: "slurm", annotations: .metadata.annotations}' | \
  kubectl apply -f -
```

## Helm and Slurm State

Installed Helm releases discovered:

```text
contour
dcgm-exporter
gpu-operator
gpu-rdma-node-problem-detector
kube-prometheus-stack
kueue
network-operator
oci-hpc-oke-utils
oke-ons-webhook
```

No Slurm/Slinky Helm release was installed at discovery time.

Slinky CRDs were not installed at discovery time. Only the NetworkAttachment CRD
matched the Slinky/SR-IOV search.

Available Slinky charts:

```text
ghcr.io/slinkyproject/charts/slurm:1.1.0
ghcr.io/slinkyproject/charts/slurm-operator:1.1.0
ghcr.io/slinkyproject/charts/slurm-operator-crds:1.1.0
```

## 2026-05-05 GPU AutoDetect Follow-Up

Tested `AutoDetect=nvidia` on the live two-node BM.GPU4.8 OKE cluster:

- without `l3cache_as_socket`, both workers registered `gpu:a100:8` but entered
  `IDLE+DRAIN+DYNAMIC_NORM+INVALID_REG` because autodetected GPU CPU affinity
  did not match Slurm socket boundaries;
- putting `Parameters: ["l3cache_as_socket"]` under
  `nodesets.gpu-b4.extraConfMap` was ineffective because Slinky renders it into
  `slurmd --conf`;
- putting `--parameters l3cache_as_socket` in `nodesets.gpu-b4.slurmd.args`
  made Slurm record the parameter, but the node still stayed invalid;
- a temporary static topology test with `Sockets=16`, `CoresPerSocket=4`, and
  `ThreadsPerCore=2` was also rejected because we do not want static topology in
  the deployment values, and it still did not clear the affinity-boundary error.

Rolled back to the manual GRES config and restarted the controller and worker
pods so configless Slurm served the updated `gres.conf`.

Current live state after rollback:

```text
Helm release: slurm revision 13
gres.conf: Name=gpu Type=a100 File=/dev/nvidia[0-7]
gpu-b4-0 idle gpu:a100:8 none
gpu-b4-1 idle gpu:a100:8 none
```

Next path is to rebuild the worker image with NVML support and test
`AutoDetect=nvml` without static topology fields.

## Current SR-IOV Values File on Operator Node

Found:

```text
/home/ubuntu/slinky-values-sriov.yaml
```

Important contents:

```yaml
controller:
  slurmctld:
    image:
      repository: iad.ocir.io/idxzjcdglx2s/slinky
      tag: slurmctld-pmix-25.11-ubuntu24.04
  persistence:
    enabled: true
    storageClassName: oci-bv
    resources:
      requests:
        storage: 10Gi
  extraConfMap:
    GresTypes: "gpu"
    PropagateResourceLimitsExcept: MEMLOCK

nodesets:
  gpu-b4:
    enabled: true
    replicas: 2
    useResourceLimits: false
    slurmd:
      image:
        repository: iad.ocir.io/idxzjcdglx2s/slinky
        tag: slurmd-rdma-pmix-25.11-ubuntu24.04
      resources:
        limits:
          nvidia.com/gpu: 8
          nvidia.com/sriov-rdma-vf: 16
        requests:
          nvidia.com/gpu: 8
          nvidia.com/sriov-rdma-vf: 16
      volumeMounts:
        - { name: devinf, mountPath: /dev/infiniband }
        - { name: shm, mountPath: /dev/shm }
    metadata:
      annotations:
        k8s.v1.cni.cncf.io/networks: sriov-rdma-vf,... repeated 16 times
    podSpec:
      nodeSelector:
        node.kubernetes.io/instance-type: BM.GPU4.8
      volumes:
        - { name: devinf, hostPath: { path: /dev/infiniband } }
        - { name: shm, emptyDir: { medium: Memory, sizeLimit: 32Gi } }

loginsets:
  slinky:
    enabled: true
    replicas: 1
    rootSshAuthorizedKeys: "ssh-rsa YOUR_KEY_HERE"
    service:
      spec: { type: LoadBalancer }

accounting:
  enabled: false
```

This file already uses VFs and does not use `hostNetwork`.

## Test User Plan

To validate without LDAP, use one local test user:

```text
username: alice
uid: 10001
gid: 10001
home: /home/alice
```

Generated a test SSH key on the operator node:

```text
/home/ubuntu/.ssh/alice_slurm_test
/home/ubuntu/.ssh/alice_slurm_test.pub
```

Public key:

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHmMWbUCIHpGAIW/WIM6tKHp5g6ET52JFLTXGApEbP2J alice-slurm-test
```

A password hash was generated locally for a locked/non-real test password:

```text
$6$slurmtest$TTJq5sE.Ci1zm8V/qMYBjKr6x517xtlMQeF2MHaI1MYSTanO5sETM0UPYHFEAGpiZmQAfd8TManOiu/ZqqP8I.
```

Intended no-LDAP test approach:

1. Use an init container or custom login image to create `alice` in the login
   pod.
2. Mount FSS at `/home`.
3. Provision `/home/alice/.ssh/authorized_keys` on FSS.
4. SSH as `alice` to the login LoadBalancer.
5. Submit a Slurm job and verify `alice` appears in `squeue`/`sacct`.

Important caveat: adding `alice` only to the login pod may be enough for Slurm
job submission identity with `auth/slurm`/`use_client_ids`, but jobs that need
home-directory ownership or group resolution on compute pods may require
compute-side user resolution too. The production recommendation remains SSSD
backed by LDAP/FreeIPA/AD, or a controlled local-user mechanism on all relevant
pods.

## Recommended Next Steps

1. Create namespace `slurm`.
2. Copy `sriov-rdma-vf` NetworkAttachmentDefinition from `default` to `slurm`.
3. Create PVC `slurm-home` bound to `fss-pv`.
4. Create a temporary admin/provisioning pod mounting `slurm-home`.
5. Create `/home/alice/.ssh/authorized_keys` on FSS with UID/GID `10001:10001`.
6. Install `slurm-operator-crds`.
7. Install `slurm-operator`.
8. Create a merged SR-IOV multi-user values file:
   - preserve existing VF, `/dev/infiniband`, and `/dev/shm` settings;
   - add `slurm-home` PVC mount at `/home` to login and `gpu-b4` NodeSet;
   - add local-user creation for `alice` or use a custom login image;
   - keep `hostNetwork` absent;
   - leave accounting disabled for the first basic Slurm test or enable it if
     MariaDB is deployed first.
9. Install Slurm with the merged values file.
10. Wait for controller, workers, login pod, and service.
11. SSH from the operator node:

```bash
ssh -i ~/.ssh/alice_slurm_test alice@<login-lb-ip>
```

12. Inside the login pod:

```bash
whoami
id
pwd
ls -ld /home /home/alice
sinfo
sbatch --wrap="hostname"
squeue -u alice
```

13. Enable SlurmDBD accounting and add associations:

```bash
sacctmgr add account project-a Description="Project A" Organization=example -i
sacctmgr add user name=alice account=project-a defaultaccount=project-a -i
```

14. Retest:

```bash
sbatch --account=project-a --wrap="hostname"
squeue -u alice
sacct -u alice
```

## Commands That Were Used For Discovery

Use this SSH wrapper for future commands:

```bash
ssh -o BatchMode=yes \
  -o UserKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=no \
  -J ubuntu@152.67.124.58 ubuntu@10.140.0.18 \
  'export PATH=/home/ubuntu/bin:$PATH OCI_CLI_AUTH=instance_principal; <command>'
```

Key read-only commands used:

```bash
kubectl get nodes -o wide
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{.status.allocatable}{"\n---\n"}{end}'
kubectl get pv fss-pv -o yaml
kubectl get pvc -A -o wide
kubectl get sc
helm list -A
kubectl get pods -A -o wide
kubectl get net-attach-def -A
kubectl get crd
helm show chart oci://ghcr.io/slinkyproject/charts/slurm
helm show chart oci://ghcr.io/slinkyproject/charts/slurm-operator
helm show chart oci://ghcr.io/slinkyproject/charts/slurm-operator-crds
sed -n '1,260p' ~/slinky-values-sriov.yaml
```

## Cluster Changes Made So Far

No Slurm resources were installed or modified during discovery.

Changes made:

- created guide files under `multi-user-oke` in the local guide repo;
- generated `/home/ubuntu/.ssh/alice_slurm_test` and
  `/home/ubuntu/.ssh/alice_slurm_test.pub` on the operator node for the planned
  test user.

## 2026-05-04 Checkpoint: Pre-Install Live State

Read-only checks were re-run from the operator node using instance principal
auth for the OCI kubeconfig exec plugin.

Findings:

- `slurm` namespace is absent.
- no Slinky Helm releases are installed.
- no Slinky or Slurm CRDs are installed.
- `cert-manager` namespace exists, but no cert-manager pods or CRDs are present.
- `fss-pv` is still `Available`, `RWX`, `50Gi`, with reclaim policy `Retain`.
- `NetworkAttachmentDefinition/default/sriov-rdma-vf` exists.
- `NetworkAttachmentDefinition/slurm/sriov-rdma-vf` does not exist yet because
  the `slurm` namespace is absent.
- GPU nodes currently reporting Slurm-relevant resources:
  - `10.140.76.140`: `nvidia.com/gpu=8`,
    `nvidia.com/sriov-rdma-vf=16`
  - `10.140.89.40`: `nvidia.com/gpu=8`,
    `nvidia.com/sriov-rdma-vf=16`

Installed Helm releases at this checkpoint:

```text
contour
dcgm-exporter
gpu-operator
gpu-rdma-node-problem-detector
kube-prometheus-stack
kueue
network-operator
oci-hpc-oke-utils
oke-ons-webhook
```

Next planned cluster changes:

1. Install cert-manager because the Slinky operator webhook needs certificate
   resources.
2. Install Slinky CRDs and operator.
3. Create the `slurm` namespace.
4. Copy the `sriov-rdma-vf` NAD from `default` to `slurm`.
5. Bind `fss-pv` to a `slurm/slurm-home` PVC.
6. Prepare `/home/alice` on FSS and continue with a no-LDAP login-user test.

## 2026-05-04 Checkpoint: Operator Prerequisites Installed

Cluster changes made:

- installed `cert-manager` from `oci://quay.io/jetstack/charts/cert-manager`,
  chart/app `v1.20.2`, with `crds.enabled=true`;
- installed `slurm-operator-crds` from
  `oci://ghcr.io/slinkyproject/charts/slurm-operator-crds`, chart `1.1.0`;
- installed `slurm-operator` from
  `oci://ghcr.io/slinkyproject/charts/slurm-operator`, chart `1.1.0`, into
  namespace `slinky`.

Validation:

- `cert-manager`, `cert-manager-webhook`, and `cert-manager-cainjector` pods
  reached `Running`.
- cert-manager API services `v1.cert-manager.io` and
  `v1.acme.cert-manager.io` reported `Available=True`.
- `slurm-operator` and `slurm-operator-webhook` deployments rolled out.
- Slinky CRDs present:
  - `accountings.slinky.slurm.net`
  - `controllers.slinky.slurm.net`
  - `loginsets.slinky.slurm.net`
  - `nodesets.slinky.slurm.net`
  - `restapis.slinky.slurm.net`
  - `tokens.slinky.slurm.net`

Installed Helm releases added:

```text
cert-manager                   cert-manager   cert-manager-v1.20.2
slurm-operator-crds            default        slurm-operator-crds-1.1.0
slurm-operator                 slinky         slurm-operator-1.1.0
```

No Slurm workload resources have been installed yet.

## 2026-05-04 Checkpoint: BM.GPU4.8 Shape Confirmed

The live GPU node labels were checked before preparing install values:

```text
10.140.76.140 node.kubernetes.io/instance-type=BM.GPU4.8 gpu=8 vf=16
10.140.89.40  node.kubernetes.io/instance-type=BM.GPU4.8 gpu=8 vf=16
```

The existing operator-node SR-IOV values file already uses:

```yaml
nodesets:
  gpu-b4:
    podSpec:
      nodeSelector:
        node.kubernetes.io/instance-type: BM.GPU4.8
```

The `gpu-b4` key is just the existing NodeSet name; the Kubernetes selector is
the important shape constraint and it is `BM.GPU4.8`.

Guide updates made:

- added the same `BM.GPU4.8` selector to
  `overlays/values-multi-user-base.yaml`;
- added `overlays/values-oke-bm-gpu4-8-fss-pvc.yaml`, a concrete test values
  file preserving the existing SR-IOV VF resources, `/dev/infiniband`,
  `/dev/shm`, and adding the `slurm-home` PVC at `/home`.

## 2026-05-04 Checkpoint: No-LDAP Wrapper Manifest Prepared

Temporary image inspection pods were run and then deleted:

- `login-image-inspect`
- `login-supervisor-inspect`
- `login-entrypoint-inspect`
- `slurmd-image-inspect`

Findings:

- `ghcr.io/slinkyproject/login:25.11-ubuntu24.04` includes `useradd`,
  `groupadd`, `sshd`, `sssd`, and `supervisord`.
- the login image starts through `/usr/local/bin/entrypoint.sh`, which creates
  runtime directories and then execs:

```bash
supervisord -c /etc/supervisor/supervisord.conf
```

- `iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rdma-pmix-25.11-ubuntu24.04` also
  includes `useradd`, `groupadd`, and starts through
  `/usr/local/bin/entrypoint.sh`.
- both images have NSS configured with `files sss systemd` for `passwd` and
  `group`.

Manifest updates made:

- added `manifests/local-user-entrypoint-configmap.yaml`;
- updated `overlays/values-oke-bm-gpu4-8-fss-pvc.yaml` so login and slurmd
  containers run `/usr/local/bin/local-user-entrypoint.sh`;
- the wrapper creates local POSIX user/group `alice` with UID/GID `10001`, fixes
  `/home/alice` ownership/mode, and then execs the stock image entrypoint with
  all original args preserved.

This ConfigMap has not been applied to the cluster yet. Slurm has not been
installed yet.

## 2026-05-05 Checkpoint: Local User Wrapper Applied and Alice Home Provisioned

Re-verified before continuing:

- namespaces `slurm`, `slinky`, and `cert-manager` exist;
- Helm releases `cert-manager`, `slurm-operator-crds`, and `slurm-operator`
  are deployed;
- `slurm/slurm-home` is still bound to `fss-pv`;
- `slurm/sriov-rdma-vf` NAD exists;
- the prepared values file on the operator node still uses
  `node.kubernetes.io/instance-type: BM.GPU4.8`;
- direct node describe output confirmed both GPU nodes still expose
  `nvidia.com/gpu: 8` and `nvidia.com/sriov-rdma-vf: 16`.

Applied:

```bash
kubectl apply -f /home/ubuntu/slurm-multi-user-manifests/local-user-entrypoint-configmap.yaml
```

Created:

- `ConfigMap/slurm/slurm-local-user-entrypoint`

Provisioned Alice's FSS home using a temporary pod mounting `slurm-home`.

Result from the provisioning pod:

```text
drwx--x--x    3 0        0                1 May  5 02:37 /mnt/home
drwx------    3 10001    10001            1 May  5 02:37 /mnt/home/alice
drwx------    2 10001    10001            1 May  5 02:37 /mnt/home/alice/.ssh
-rw-------    1 10001    10001           98 May  5 02:37 /mnt/home/alice/.ssh/authorized_keys
```

Temporary resources created and then deleted:

- `Pod/slurm/fss-home-provision-alice`
- `Secret/slurm/alice-authorized-keys`

Slurm has still not been installed at this checkpoint.

## 2026-05-05 Checkpoint: Slurm Installed and User SSH Validated

Installed Slurm with the prepared BM.GPU4.8 SR-IOV/FSS values:

```bash
helm install slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  -f /home/ubuntu/slinky-values-sriov-fss-pvc.yaml \
  --namespace slurm
```

Result:

- Helm release `slurm` revision `1` deployed in namespace `slurm`.
- `slurm-login-slinky` LoadBalancer IP: `192.9.181.77`.
- all Slurm pods reached Running:
  - `slurm-controller-0`
  - `slurm-login-slinky-...`
  - `slurm-restapi-...`
  - `slurm-worker-gpu-b4-0`
  - `slurm-worker-gpu-b4-1`
- `sinfo -Nel` showed both `gpu-b4` nodes idle.
- worker pod events confirmed SR-IOV VF attachment through
  `slurm/sriov-rdma-vf`, including `net1` through `net16` on each worker pod.

SSH test from the operator node:

```bash
ssh -i /home/ubuntu/.ssh/alice_slurm_test alice@192.9.181.77
```

Observed inside the SSH session:

```text
alice
uid=10001(alice) gid=10001(alice) groups=10001(alice)
/home/alice
drwx--x--x 3     0     0 /home
drwx------ 4 10001 10001 /home/alice
gpu-b4-[0-1] idle gpu:a100:8
```

Submitted test job as `alice`.

Clean job test result:

```text
JOBID=2
UserId=alice(10001) GroupId=alice(10001)
JobState=COMPLETED
NodeList=gpu-b4-1
StdOut=/home/alice/slurm-2.out
```

Output from `/home/alice/slurm-2.out`:

```text
gpu-b4-1
alice
uid=10001(alice) gid=10001(alice) groups=10001(alice)
/home/alice
```

No-LDAP caveat observed:

- login and slurmd containers resolve `alice` because of the local-user wrapper;
- `slurmctld` runs as the `slurm` user and the same wrapper cannot create local
  users there without a custom controller image or a different identity source;
- user-facing Slurm commands from the login pod show `alice`, but operator-side
  `scontrol` inside the controller can display numeric UID for jobs submitted
  before accounting is enabled;
- production should use SSSD backed by LDAP, FreeIPA, or Active Directory for
  consistent identity on every Slurm component.

## 2026-05-05 Checkpoint: Accounting Enabled and Verified

Installed MariaDB operator:

```bash
helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator
helm repo update mariadb-operator
helm install mariadb-operator-crds mariadb-operator/mariadb-operator-crds --version 26.3.0
helm install mariadb-operator mariadb-operator/mariadb-operator \
  --version 26.3.0 \
  --namespace mariadb --create-namespace
```

Created `MariaDB/slurm/mariadb` with:

- database: `slurm_acct_db`
- username: `slurm`
- generated password secret: `mariadb-password`
- storage: `oci-bv`, 16Gi requested by manifest, bound as a 50Gi OCI block
  volume by the storage class.

MariaDB pod:

```text
mariadb-0  1/1  Running
```

Updated the prepared values file to enable accounting:

```yaml
controller:
  extraConfMap:
    AccountingStorageEnforce: "associations,limits,qos"

accounting:
  enabled: true
  storageConfig:
    host: mariadb
    port: 3306
    database: slurm_acct_db
    username: slurm
    passwordKeyRef:
      name: mariadb-password
      key: password
```

Upgraded Slurm:

```bash
helm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  -f /home/ubuntu/slinky-values-sriov-fss-pvc.yaml \
  --namespace slurm
```

Result:

- Helm release `slurm` revision `2`.
- `Accounting/slurm/slurm` created.
- `slurm-accounting-0` created and Running.
- `slurm-accounting` service created on port `6819`.
- `slurmdbd` log showed MariaDB connection and startup.

The controller ConfigMap updated immediately, but the existing controller pod
still had the old projected config mounted. Restarted only the controller pod:

```bash
kubectl -n slurm delete pod slurm-controller-0
```

After restart, `/etc/slurm/slurm.conf` inside `slurmctld` showed:

```text
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=slurm-accounting
AccountingStoragePort=6819
AccountingStorageTRES=gres/gpu
AccountingStorageEnforce=associations,limits,qos
```

Controller log showed:

```text
accounting_storage/slurmdbd: clusteracct_storage_p_register_ctld: Registering slurmctld at port 6817 with slurmdbd
```

Created Slurm accounting objects:

```bash
sacctmgr add account project-a Description="Project A" Organization=example -i
sacctmgr add user name=alice account=project-a defaultaccount=project-a -i
```

Verified:

```text
User|Def Acct|Admin
alice|project-a|None
```

Submitted an accounting test job over SSH as `alice`:

```bash
sbatch --parsable --wait --account=project-a \
  --output=/home/alice/accounting-%j.out \
  /home/alice/accounting-test.sh
```

Result:

```text
JOBID=3
UserId=alice(10001) GroupId=alice(10001)
Account=project-a QOS=normal
JobState=COMPLETED
NodeList=gpu-b4-1
```

`sacct` from Alice's SSH session:

```text
JobID|User|Account|State|ExitCode|Elapsed|NodeList
3|alice|project-a|COMPLETED|0:0|00:00:01|gpu-b4-1
3.batch||project-a|COMPLETED|0:0|00:00:01|gpu-b4-1
3.extern||project-a|COMPLETED|0:0|00:00:01|gpu-b4-1
```

`sacct` from the controller also showed the same completed job for
`alice/project-a`.

Final state at this checkpoint:

```text
cert-manager                   cert-manager  deployed  cert-manager-v1.20.2
mariadb-operator-crds          default       deployed  mariadb-operator-crds-26.3.0
mariadb-operator               mariadb       deployed  mariadb-operator-26.3.0
slurm-operator-crds            default       deployed  slurm-operator-crds-1.1.0
slurm-operator                 slinky        deployed  slurm-operator-1.1.0
slurm                          slurm         deployed  slurm-1.1.0 revision 2
```

Running Slurm/MariaDB pods:

```text
mariadb-0                             1/1 Running
slurm-accounting-0                    1/1 Running
slurm-controller-0                    3/3 Running
slurm-login-slinky-...                1/1 Running
slurm-restapi-...                     1/1 Running
slurm-worker-gpu-b4-0                 2/2 Running
slurm-worker-gpu-b4-1                 2/2 Running
```

## 2026-05-05 Continuation: Home Isolation and GPU Accounting Test

Re-checked the running state:

```text
mariadb-0                             1/1 Running
slurm-accounting-0                    1/1 Running
slurm-controller-0                    3/3 Running
slurm-login-slinky-...                1/1 Running
slurm-restapi-...                     1/1 Running
slurm-worker-gpu-b4-0                 2/2 Running
slurm-worker-gpu-b4-1                 2/2 Running
slurm-home                            Bound fss-pv 50Gi RWX
slurm-login-slinky                    LoadBalancer 192.9.181.77
```

## HA OpenLDAP StatefulSet Test

Added and tested the HA OpenLDAP manifest set:

```text
guides/slurm-operator/multi-user-oke/manifests/ha-openldap/
```

Deployment commands used on the operator node:

```bash
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal

kubectl apply -k /tmp/gce-hackathon-guides/slurm-operator/multi-user-oke/manifests/ha-openldap
kubectl -n identity rollout status statefulset/openldap --timeout=10m
kubectl -n identity wait --for=condition=complete job/openldap-bootstrap --timeout=5m
```

Initial rollout exposed one issue: only `/var/lib/ldap` was persisted. On pod
replacement, `openldap-2` failed because the image found an existing data
directory but an empty `/etc/ldap/slapd.d` config directory. Fixed the manifest
by adding a second PVC template, `ldap-config`, mounted at
`/etc/ldap/slapd.d`.

Final HA LDAP state:

```text
openldap-0 1/1 Running primary
openldap-1 1/1 Running read replica
openldap-2 1/1 Running read replica
openldap-bootstrap Completed
ldap-data-openldap-{0,1,2}   Bound oci-bv
ldap-config-openldap-{0,1,2} Bound oci-bv
```

Validation results:

- `sssd-reader` can read `alice` from `openldap-0`, `openldap-1`, and
  `openldap-2`;
- adding `bob` through `openldap-0` replicated to both replicas;
- adding `carol` through `openldap-primary.identity.svc.cluster.local`
  replicated to both replicas;
- direct write to `openldap-1` failed with LDAP `53 operation restricted`;
- deleting `openldap-2` recreated the pod with zero restarts and data still
  readable.

Confirmed the accounting association is still present:

```text
User|Def Acct|Admin
alice|project-a|None
```

Re-confirmed SSH as `alice`:

```text
whoami -> alice
id     -> uid=10001(alice) gid=10001(alice) groups=10001(alice)
pwd    -> /home/alice
```

Created a second FSS home directory to validate isolation:

```text
drwx--x--x 4     0     0 /home
drwx------ 4 10001 10001 /home/alice
drwx------ 2 10002 10002 /home/bob
```

From Alice's SSH session:

```text
ls /home     -> Permission denied
ls /home/bob -> Permission denied
```

Submitted a one-GPU job as Alice:

```bash
sbatch --parsable --wait --account=project-a --gres=gpu:1 \
  --output=/home/alice/gpu-%j.out \
  --wrap="hostname; whoami; id; nvidia-smi -L"
```

Result:

```text
JOBID=4
```

Output from `/home/alice/gpu-4.out`:

```text
gpu-b4-1
alice
uid=10001(alice) gid=10001(alice) groups=10001(alice)
GPU 0: NVIDIA A100-SXM4-40GB (UUID: GPU-ce1927ca-2941-0491-ad35-fed92d6715f8)
```

Accounting from Alice's SSH session:

```text
JobID|User|Account|State|ExitCode|AllocTRES|NodeList
4|alice|project-a|COMPLETED|0:0|billing=2,cpu=2,gres/gpu=1,mem=2064153M,node=1|gpu-b4-1
4.batch||project-a|COMPLETED|0:0|cpu=2,gres/gpu=1,mem=2064153M,node=1|gpu-b4-1
4.extern||project-a|COMPLETED|0:0|billing=2,cpu=2,gres/gpu=1,mem=2064153M,node=1|gpu-b4-1
```

`scontrol show job 4` from Alice's login session resolved names correctly:

```text
UserId=alice(10001) GroupId=alice(10001)
Account=project-a QOS=normal
JobState=COMPLETED
NodeList=gpu-b4-1
TresPerNode=gres/gpu:1
```

The same `scontrol` command from the controller showed numeric UID/GID because
the no-LDAP test wrapper does not run in the controller container:

```text
UserId=10001(10001) GroupId=10001(10001)
```

This is acceptable for the no-LDAP test path, but production should use SSSD
backed by LDAP, FreeIPA, or Active Directory so login, controller, accounting,
and slurmd components all resolve the same names.

Verified workers are still using SR-IOV VFs and not host networking:

```text
slurm-worker-gpu-b4-0 hostNetwork=<unset/false> vfLimit=16 gpuLimit=8 node=10.140.89.40
slurm-worker-gpu-b4-1 hostNetwork=<unset/false> vfLimit=16 gpuLimit=8 node=10.140.76.140
```

## 2026-05-05 Continuation: SSSD With LDAP Test

Created new local guide files:

```text
manifests/openldap-test-identity.yaml
overlays/values-oke-bm-gpu4-8-fss-sssd-ldap.yaml
sssd-ldap-test.md
```

Copied them to the operator node:

```text
/home/ubuntu/slurm-multi-user-manifests/openldap-test-identity.yaml
/home/ubuntu/slurm-multi-user-overlays/values-oke-bm-gpu4-8-fss-sssd-ldap.yaml
```

The first OpenLDAP attempt mounted the custom LDIF into the image bootstrap
directory. The image pulled successfully, but startup exited with status `68`
during custom bootstrap. Changed the pattern to:

1. start OpenLDAP normally;
2. load the LDIF with a separate Kubernetes Job using `ldapadd`.

Applied:

```bash
kubectl apply -f /home/ubuntu/slurm-multi-user-manifests/openldap-test-identity.yaml
kubectl -n slurm rollout status deploy/openldap-test --timeout=180s
kubectl -n slurm wait --for=condition=complete job/openldap-test-bootstrap --timeout=180s
```

LDAP bootstrap job added:

```text
ou=People,dc=example,dc=org
ou=Groups,dc=example,dc=org
cn=alice,ou=Groups,dc=example,dc=org
cn=project-a,ou=Groups,dc=example,dc=org
uid=alice,ou=People,dc=example,dc=org
```

Validated LDAP:

```text
uid=alice
uidNumber=10001
gidNumber=10001
homeDirectory=/home/alice
loginShell=/bin/bash
description=ssh-ed25519 ... alice-slurm-test

cn=project-a
gidNumber=11001
memberUid=alice
```

Upgraded Slurm to the SSSD values:

```bash
helm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  -f /home/ubuntu/slurm-multi-user-overlays/values-oke-bm-gpu4-8-fss-sssd-ldap.yaml \
  --namespace slurm
```

Result:

```text
slurm revision 3 deployed
```

Important values changes:

- removed the local-user wrapper command and volume from login and slurmd;
- set `sssd.secretRef` to `site-sssd-ldap-test-conf`;
- set login SSH to use `sss_ssh_authorizedkeys`;
- set `AuthorizedKeysFile none` so the SSH key must come from SSSD/LDAP;
- set `nodesets.gpu-b4.ssh.enabled=true` so workers mount `sssd.conf` and run
  SSSD.

Login pod validation:

```text
grep '^alice:' /etc/passwd -> no local entry
getent passwd alice -> alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
id alice -> uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
getent group project-a -> project-a:*:11001:alice
sss_ssh_authorizedkeys alice -> ssh-ed25519 ... alice-slurm-test
sssd domain -> LDAP
```

Worker pod validation:

```text
grep '^alice:' /etc/passwd -> no local entry
/etc/sssd/sssd.conf mounted
getent passwd alice -> alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
id alice -> uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
getent group project-a -> project-a:*:11001:alice
sssd domain -> LDAP
```

SSH as `alice` succeeded through the login LoadBalancer:

```text
whoami -> alice
id -> uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
pwd -> /home/alice
```

Because `AuthorizedKeysFile none` was active, this validated LDAP-backed SSH key
lookup through `sss_ssh_authorizedkeys`.

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

`scontrol show job 5` from Alice's login session resolved names:

```text
UserId=alice(10001) GroupId=alice(10001)
Account=project-a QOS=normal
JobState=COMPLETED
NodeList=gpu-b4-1
StdOut=/home/alice/sssd-gpu-5.out
TresPerNode=gres/gpu:1
```

`scontrol show job 5` from the controller still showed numeric UID/GID:

```text
UserId=10001(10001) GroupId=10001(10001)
```

The current controller image has `passwd: files`, no `sssd` binary, and no
SSSD process. User-facing login and worker execution are correct; controller
operator-side name resolution would require adding SSSD/NSS support to the
controller image and pod wiring.

Final SSSD test state:

```text
openldap-test                         1/1 Running
mariadb-0                             1/1 Running
slurm-accounting-0                    1/1 Running
slurm-controller-0                    3/3 Running
slurm-login-slinky-...                1/1 Running
slurm-restapi-...                     1/1 Running
slurm-worker-gpu-b4-0                 2/2 Running
slurm-worker-gpu-b4-1                 2/2 Running
slurm-home                            Bound fss-pv 50Gi RWX
slurm-login-slinky                    LoadBalancer 192.9.181.77
```

Workers still use VFs and not host networking:

```text
slurm-worker-gpu-b4-0 hostNetwork=<unset/false> vfLimit=16 gpuLimit=8 sssd-conf mounted node=10.140.89.40
slurm-worker-gpu-b4-1 hostNetwork=<unset/false> vfLimit=16 gpuLimit=8 sssd-conf mounted node=10.140.76.140
```

## Controller SSSD/NSS Image Build

Built and pushed the custom controller image on `image-builder`:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04
digest: sha256:683d5fd96ceee8e34d8647a29eda69ba8e9220ca762064f951c0183edc522567
```

The build derives from:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-25.11-ubuntu24.04
```

The builder could not reach the Ubuntu archive over HTTP, but HTTPS worked.
The PMIx controller image also lacked `ca-certificates`, so the Dockerfile
bootstraps CA certificates before installing `authselect`, `sssd`, `sssd-ad`,
`sssd-ldap`, `libpam-sss`, and `libnss-sss`.

Smoke test passed:

```text
/usr/sbin/sssd
passwd:     files sss systemd
group:      files sss systemd
slurm:x:401:401::/home/slurm:/usr/sbin/nologin
slurm:x:401:
```

## Controller SSSD/NSS Deployment

Applied the controller SSSD/NSS values with Helm:

```text
/home/ubuntu/slurm-multi-user-overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml
```

Final deployed release:

```text
slurm revision 8, chart slurm-1.1.0, app 25.11
```

The first sidecar attempts exposed two Kubernetes-specific fixes that are now
encoded in the values files:

- mounting the Secret directly at `/etc/sssd/sssd.conf` failed SSSD's config
  ownership/permission check, so the sidecar copies it from
  `/etc/sssd-secret/sssd.conf` to `/etc/sssd/sssd.conf` as `root:root` mode
  `0600`;
- the shared emptyDir for `/var/lib/sss` inherited `fsGroup=401`, so the
  sidecar resets SSSD state directories to `root:root` with the same modes used
  by the working login image before starting SSSD.

Final controller state:

```text
slurm-controller-0 4/4 Running 0 restarts
slurmctld image=iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04
sssd image=ghcr.io/slinkyproject/login:25.11-ubuntu24.04
```

Controller-side NSS validation from the `slurmctld` container:

```text
/usr/sbin/sssd
passwd:     files sss systemd
group:      files sss systemd
alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
```

Submitted a fresh GPU job as Alice after the controller restart:

```text
JOB=6
UserId=alice(10001) GroupId=alice(10001)
Account=project-a QOS=normal
JobState=RUNNING
TresPerNode=gres/gpu:1
```

Accounting for the same job:

```text
6|alice|project-a|COMPLETED|0:0|billing=2,cpu=2,gres/gpu=1,mem=2064153M,node=1|gpu-b4-1
6.batch||project-a|COMPLETED|0:0|cpu=2,gres/gpu=1,mem=2064153M,node=1|gpu-b4-1
6.extern||project-a|COMPLETED|0:0|billing=2,cpu=2,gres/gpu=1,mem=2064153M,node=1|gpu-b4-1
```

Current final cluster state:

```text
mariadb-0                             1/1 Running
openldap-test                         1/1 Running
slurm-accounting-0                    1/1 Running
slurm-controller-0                    4/4 Running
slurm-login-slinky-...                1/1 Running
slurm-restapi-...                     1/1 Running
slurm-worker-gpu-b4-0                 2/2 Running
slurm-worker-gpu-b4-1                 2/2 Running
slurm-home                            Bound fss-pv 50Gi RWX
slurm-login-slinky                    LoadBalancer 192.9.181.77
```

## HA OpenLDAP End-to-End Slurm Validation

Date: 2026-05-05.

Goal: switch the live Slurm deployment from the disposable `openldap-test`
identity service to the HA OpenLDAP deployment in the `identity` namespace and
re-run the full `alice` SSH, NSS, Slurm job, and accounting path.

Pre-change state:

```text
identity/openldap-0 1/1 Running primary
identity/openldap-1 1/1 Running read replica
identity/openldap-2 1/1 Running read replica
slurm/site-sssd-ha-ldap-conf present
slurm/site-sssd-ldap-test-conf present
helm release slurm revision 24, chart slurm-1.1.0
```

The first HA LDAP lookup found that `alice` still had the sample SSH key from
the HA manifest:

```text
sshPublicKey: ssh-ed25519 AAAA_REPLACE_ME alice@example
```

Updated the live HA OpenLDAP primary with the real test key from
`/home/ubuntu/.ssh/alice_slurm_test.pub`:

```ldif
dn: uid=alice,ou=People,dc=example,dc=org
changetype: modify
replace: sshPublicKey
sshPublicKey: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHmMWbUCIHpGAIW/WIM6tKHp5g6ET52JFLTXGApEbP2J alice-slurm-test
```

Applied with:

```bash
kubectl -n identity cp /home/ubuntu/alice-ha-key.ldif openldap-0:/tmp/alice-ha-key.ldif
kubectl -n identity exec openldap-0 -- ldapmodify -x \
  -H ldap://openldap-primary.identity.svc.cluster.local:389 \
  -D cn=admin,dc=example,dc=org \
  -w adminpassword \
  -f /tmp/alice-ha-key.ldif
```

Confirmed replication of the updated key through all HA read paths:

```text
openldap-1.openldap-headless.identity.svc.cluster.local -> alice key readable
openldap-2.openldap-headless.identity.svc.cluster.local -> alice key readable
openldap-read.identity.svc.cluster.local                -> alice key readable
```

Captured the live Slurm Helm values and changed only the SSSD Secret
references:

```text
controller.podSpec.volumes[0].secret.secretName:
  site-sssd-ldap-test-conf -> site-sssd-ha-ldap-conf

sssd.secretRef.name:
  site-sssd-ldap-test-conf -> site-sssd-ha-ldap-conf
```

The captured values preserved the current static GPU GRES config:

```text
gres.conf: Name=gpu Type=a100 File=/dev/nvidia[0-7]
```

Applied the HA SSSD values:

```bash
helm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  -f /home/ubuntu/slurm-values-ha-openldap.yaml \
  --namespace slurm
```

Result:

```text
slurm revision 25 deployed
```

After the rollout, all Slurm pods returned to ready:

```text
slurm-controller-0                    4/4 Running
slurm-login-slinky-58947b5d7c-f52bk   1/1 Running
slurm-worker-gpu-b4-0                 2/2 Running
slurm-worker-gpu-b4-1                 2/2 Running
```

Confirmed the login, worker, and controller SSSD configs point at HA OpenLDAP:

```text
ldap_uri = ldap://openldap-0.openldap-headless.identity.svc.cluster.local:389,ldap://openldap-1.openldap-headless.identity.svc.cluster.local:389,ldap://openldap-2.openldap-headless.identity.svc.cluster.local:389
```

Login pod NSS and SSH key validation:

```text
getent passwd alice -> alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
id alice -> uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
sss_ssh_authorizedkeys alice -> ssh-ed25519 ... alice-slurm-test
grep alice: /etc/passwd -> no local entry
```

Worker and controller NSS validation:

```text
slurm-worker-gpu-b4-0 getent passwd alice -> alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
slurm-worker-gpu-b4-0 id alice -> uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
slurm-controller-0 getent passwd alice -> alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
slurm-controller-0 id alice -> uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
```

SSH as `alice` through the login LoadBalancer succeeded:

```text
login LoadBalancer IP: 192.9.181.77
whoami -> alice
id -> uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
pwd -> /home/alice
```

FSS home isolation still behaved as expected:

```text
/home       -> drwx--x--x root root
/home/alice -> drwx------ alice alice
/home/bob   -> drwx------ bob 10002
ls /home/bob as alice -> Permission denied
```

Submitted a GPU job over SSH as `alice`:

```bash
sbatch --parsable --wait --account=project-a --gres=gpu:1 \
  --output=/home/alice/ha-ldap-%j.out \
  /home/alice/job-test.sh
```

Result:

```text
JOB=8
gpu-b4-1
alice
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
/home/alice
```

Accounting:

```text
JobID|User|Account|State|ExitCode|AllocTRES|NodeList
8|alice|project-a|COMPLETED|0:0|billing=1,cpu=1,gres/gpu=1,mem=2064153M,node=1|gpu-b4-1
8.batch||project-a|COMPLETED|0:0|cpu=1,gres/gpu=1,mem=2064153M,node=1|gpu-b4-1
8.extern||project-a|COMPLETED|0:0|billing=1,cpu=1,gres/gpu=1,mem=2064153M,node=1|gpu-b4-1
```

`scontrol show job 8` from Alice's login session resolved the user, group,
account, and GPU allocation:

```text
UserId=alice(10001) GroupId=alice(10001)
Account=project-a QOS=normal
JobState=COMPLETED
NodeList=gpu-b4-1
StdOut=/home/alice/ha-ldap-8.out
TresPerNode=gres/gpu:1
```

SlurmDBD association remained correct:

```text
alice|project-a||normal
```

Conclusion: HA OpenLDAP now works end to end for `alice`: LDAP/NSS resolution,
SSH key lookup, FSS home access, Slurm job submission, GPU allocation, and
Slurm accounting all passed.
