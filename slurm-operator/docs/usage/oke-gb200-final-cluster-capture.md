# OKE GB200 Final Cluster Capture

Date: 2026-05-05 23:28 UTC

This is the final non-secret capture from the temporary GB200 OKE cluster
before termination.

## Operator Access Used

```bash
ssh -J ubuntu@192.9.189.161 ubuntu@10.140.0.20
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

## Cluster Shape

```text
10.140.64.164  Ready  BM.GPU.GB200.4      arm64  Ubuntu 22.04.5 LTS  6.8.0-1047-nvidia-64k  cri-o://1.34.0
10.140.77.160  Ready  VM.Standard.E5.Flex  amd64  Ubuntu 22.04.5 LTS  6.8.0-1022-oracle
10.140.84.244  Ready  VM.Standard.E5.Flex  amd64  Ubuntu 22.04.5 LTS  6.8.0-1022-oracle
10.140.88.234  Ready  VM.Standard.E5.Flex  amd64  Ubuntu 22.04.5 LTS  6.8.0-1022-oracle
```

## Helm Releases

Relevant deployed releases:

```text
openldap           identity  revision 2  openldap-stack-ha-4.3.3  app 2.6.9
slurm              slurm     revision 7  slurm-1.1.0              app 25.11
slurm-operator     slinky    revision 1  slurm-operator-1.1.0     app 25.11
mariadb-operator   mariadb   revision 1  mariadb-operator-26.3.0  app 26.3.0
cert-manager       cert-manager          cert-manager-v1.19.2
```

## HA OpenLDAP

Final state:

```text
openldap-0             Running  primary
openldap-readonly-0    Running  read replica
openldap-readonly-1    Running  read replica
```

Storage:

```text
data-openldap-0             Bound  oci-bv  50Gi
data-openldap-readonly-0    Bound  oci-bv  50Gi
data-openldap-readonly-1    Bound  oci-bv  50Gi
```

Certificates:

```text
certificate/openldap-ca-root  Ready=True
certificate/openldap-tls      Ready=True
issuer/openldap-ca            Ready=True
```

Alice was present on the primary and both read replicas:

```text
dn: uid=alice,ou=People,dc=example,dc=org
uid: alice
uidNumber: 10001
gidNumber: 10001
homeDirectory: /home/alice
loginShell: /bin/bash
```

## Slurm and FSS State

Final Slurm pods:

```text
mariadb-0                            Running
slurm-accounting-0                   Running
slurm-controller-0                   Running  4/4
slurm-login-slinky-78cd64664-84zc5   Running
slurm-worker-gb200-0                 Running  2/2
```

Login service:

```text
service/slurm-login-slinky  LoadBalancer  159.13.57.35  22:31643/TCP
```

Home PVC:

```text
pvc/slurm-home  Bound  fss-pv  50Gi  RWX
```

Slinky CRs:

```text
nodeset/slurm-worker-gb200   desired=1 replicas=1 ready=1 idle=1
loginset/slurm-login-slinky  replicas=1
accounting/slurm             present
```

## Slurm Node State

```text
NODELIST       STATE  CPUS(A/I/O/T)  MEMORY  GRES             REASON
10.140.64.164  idle   0/144/0/144    979729  gpu:4(S:0-1)    none
```

`scontrol show node 10.140.64.164`:

```text
NodeName=10.140.64.164 Arch=aarch64 CoresPerSocket=72
CPUAlloc=0 CPUEfctv=144 CPUTot=144
AvailableFeatures=gb200,gb200,blackwell,rdma,hostnetwork
ActiveFeatures=gb200,gb200,blackwell,rdma,hostnetwork
Gres=gpu:4(S:0-1)
NodeHostName=instance20260505204444 Version=25.11.5
RealMemory=979729 Sockets=2 Boards=1 ThreadsPerCore=1
State=IDLE+DYNAMIC_NORM
Partitions=gb200,all
CfgTRES=cpu=144,mem=979729M,billing=144,gres/gpu=4
Comment={"namespace":"slurm","podName":"slurm-worker-gb200-0","node":"10.140.64.164"}
```

## SSSD Identity Validation

Controller:

```text
alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
```

Login pod:

```text
login_pod=slurm-login-slinky-78cd64664-84zc5
alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
```

Worker pod:

```text
worker_pod=slurm-worker-gb200-0
alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
```

## Alice SSH and Home Validation

SSH through the login LoadBalancer succeeded:

```text
LOGIN_IP=159.13.57.35
alice
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
/home/alice
drwx--x--x 3 root  root  1 May  5 23:11 /home
drwx------ 3 alice alice 2 May  5 23:11 /home/alice
```

## Slurm Accounting Validation

Association:

```text
alice|project-a||normal
```

Job 6:

```text
JobID|User|Account|State|ExitCode|AllocTRES|NodeList
6|alice|project-a|COMPLETED|0:0|billing=1,cpu=1,gres/gpu=1,mem=979729M,node=1|10.140.64.164
6.batch||project-a|COMPLETED|0:0|cpu=1,gres/gpu=1,mem=979729M,node=1|10.140.64.164
6.extern||project-a|COMPLETED|0:0|billing=1,cpu=1,gres/gpu=1,mem=979729M,node=1|10.140.64.164
```

## Images

Slurm pod images:

```text
slurmctld  iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04
sssd       ghcr.io/slinkyproject/login:25.11-ubuntu24.04
login      ghcr.io/slinkyproject/login:25.11-ubuntu24.04
slurmd     iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-core-25.11.5-ubuntu24.04
slurmdbd   ghcr.io/slinkyproject/slurmdbd:25.11-ubuntu24.04
mariadb    docker-registry1.mariadb.com/library/mariadb:11.8.5
```

OpenLDAP pod image:

```text
jpgouin/openldap:2.6.9-fix
```

## NVML AutoDetect Evidence

Recent `slurmd` log excerpts:

```text
gpu/nvml: _get_system_gpu_list_nvml: 4 GPU system device(s) detected
gres/gpu: _normalize_sys_gres_types: Could not find an unused configuration record with a GRES type that is a substring of system device `nvidia_gb200`. Setting system GRES type to NULL
CPUs=144 Boards=1 Sockets=2 Cores=72 Threads=1 Memory=979729
```

The warning about the `nvidia_gb200` type did not prevent registration. Slurm
registered the node with `Gres=gpu:4(S:0-1)` and jobs accounted with
`gres/gpu=1`.

## What Was Not Captured

No Kubernetes Secret data, LDAP bind passwords, MariaDB passwords, SSH private
keys, LDAP database dump, MariaDB dump, or FSS file backup was saved in this
capture. If the cluster is terminated, recreate the test from the checked-in
manifests and runbooks, or separately preserve storage-level backups if the
actual LDAP DB, accounting DB, or FSS home contents need to survive.
