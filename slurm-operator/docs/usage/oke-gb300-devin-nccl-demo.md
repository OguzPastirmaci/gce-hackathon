# GB300 Devin NCCL Demo

This demo validates the user-facing Slurm-on-OKE experience with a new LDAP
user named `devin`.

The demo proves:

- `devin` can SSH into the Slinky login service with an LDAP-backed SSH key;
- `devin` resolves through SSSD in login, controller, and worker pods;
- `/home/devin` is mounted from FSS through `slurm-home` and `fss-pv`;
- Slurm accounting records `devin` and the project account;
- `AutoDetect=nvml` exposes the GB300 GPUs to Slurm;
- `switch/nvidia_imex` and the DRA IMEX channel are active;
- `devin` can run an NCCL `all_reduce_perf` job through Slurm.

The example workload is the NCCL test job. It uses the current GB300 worker
image:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2
```

That image already contains `/opt/nccl-tests/bin/all_reduce_perf`, NCCL,
CUDA runtime libraries, HPCX OpenMPI/UCX, and the Spectrum-X NCCL net plugin.

## Assumptions

Run this against a GB300 cluster that has already deployed:

- HA OpenLDAP in namespace `identity`;
- Slinky Slurm in namespace `slurm`;
- `slurm-home` PVC bound to `fss-pv`;
- MariaDB and SlurmDBD accounting;
- GB300 NodeSet with 4 `BM.GPU.GB300.4` workers;
- IMEX/DRA overlay with `SwitchType=switch/nvidia_imex`;
- worker image `slurmd-nvml-nccl-25.11.5-ubuntu24.04-r2`.

Use the GB300 shape runbook first if the cluster is not already deployed:

```text
docs/usage/oke-slurm-shape-runbooks.md
```

## 1. Connect to the Operator Node

From your workstation:

```bash
ssh -J ubuntu@151.106.182.43 ubuntu@10.140.0.20
```

On the operator node:

```bash
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

Check the cluster state:

```bash
kubectl -n identity get pods -o wide
kubectl -n slurm get pods -o wide
kubectl -n slurm get pvc slurm-home
kubectl get pv fss-pv
```

Check Slurm and IMEX:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  scontrol show config | egrep '^(SwitchType|TopologyPlugin|GresTypes|SelectType|SelectTypeParameters)'

kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  sinfo -N -p gb300 -o '%N|%t|%G|%C'
```

Expected Slurm config includes:

```text
GresTypes               = gpu
SelectType              = select/cons_tres
SelectTypeParameters    = CR_CORE_MEMORY
SwitchType              = switch/nvidia_imex
TopologyPlugin          = topology/flat
```

## 2. Create the Devin SSH Key

Run on the operator node:

```bash
mkdir -p /home/ubuntu/.ssh
chmod 700 /home/ubuntu/.ssh

ssh-keygen -t ed25519 -N "" \
  -f /home/ubuntu/.ssh/devin_slurm_demo \
  -C devin-slurm-demo

chmod 600 /home/ubuntu/.ssh/devin_slurm_demo
```

If the key already exists and you want to reuse it, skip `ssh-keygen`.

## 3. Add Devin to LDAP

Run this whole block on the operator node. It is idempotent for the demo user:
it creates missing LDAP entries and updates Devin's SSH key if the user already
exists.

```bash
export DEMO_USER=devin
export DEMO_UID=10002
export DEMO_GID=10002
export DEMO_ACCOUNT=project-devin
export DEMO_ACCOUNT_GID=11002
export DEMO_PUBKEY="$(cat /home/ubuntu/.ssh/devin_slurm_demo.pub)"

ldapsearch_primary() {
  kubectl -n identity exec openldap-0 -- \
    /opt/bitnami/openldap/bin/ldapsearch \
      -x -H ldap://127.0.0.1:1389 \
      -D cn=admin,dc=example,dc=org -w adminpassword "$@"
}

ldapadd_primary() {
  kubectl -n identity exec -i openldap-0 -- \
    /opt/bitnami/openldap/bin/ldapadd \
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

if ! ldap_entry_exists "cn=${DEMO_USER},ou=Groups,dc=example,dc=org"; then
  printf "%s\n" \
    "dn: cn=${DEMO_USER},ou=Groups,dc=example,dc=org" \
    "objectClass: top" \
    "objectClass: posixGroup" \
    "cn: ${DEMO_USER}" \
    "gidNumber: ${DEMO_GID}" \
    "memberUid: ${DEMO_USER}" | ldapadd_primary
fi

if ! ldap_entry_exists "cn=${DEMO_ACCOUNT},ou=Groups,dc=example,dc=org"; then
  printf "%s\n" \
    "dn: cn=${DEMO_ACCOUNT},ou=Groups,dc=example,dc=org" \
    "objectClass: top" \
    "objectClass: posixGroup" \
    "cn: ${DEMO_ACCOUNT}" \
    "gidNumber: ${DEMO_ACCOUNT_GID}" \
    "memberUid: ${DEMO_USER}" | ldapadd_primary
elif ! ldapsearch_primary -LLL \
    -b "cn=${DEMO_ACCOUNT},ou=Groups,dc=example,dc=org" \
    -s base memberUid | grep -qx "memberUid: ${DEMO_USER}"; then
  printf "%s\n" \
    "dn: cn=${DEMO_ACCOUNT},ou=Groups,dc=example,dc=org" \
    "changetype: modify" \
    "add: memberUid" \
    "memberUid: ${DEMO_USER}" | ldapmodify_primary
fi

if ldap_entry_exists "uid=${DEMO_USER},ou=People,dc=example,dc=org"; then
  printf "%s\n" \
    "dn: uid=${DEMO_USER},ou=People,dc=example,dc=org" \
    "changetype: modify" \
    "replace: description" \
    "description: ${DEMO_PUBKEY}" | ldapmodify_primary
else
  printf "%s\n" \
    "dn: uid=${DEMO_USER},ou=People,dc=example,dc=org" \
    "objectClass: inetOrgPerson" \
    "objectClass: posixAccount" \
    "objectClass: shadowAccount" \
    "cn: Devin Slurm" \
    "sn: Slurm" \
    "uid: ${DEMO_USER}" \
    "uidNumber: ${DEMO_UID}" \
    "gidNumber: ${DEMO_GID}" \
    "homeDirectory: /home/${DEMO_USER}" \
    "loginShell: /bin/bash" \
    "userPassword: devinpw" \
    "description: ${DEMO_PUBKEY}" | ldapadd_primary
fi

for pod in openldap-0 openldap-readonly-0 openldap-readonly-1; do
  kubectl -n identity exec "$pod" -- \
    /opt/bitnami/openldap/bin/ldapsearch \
      -LLL -x -H ldap://127.0.0.1:1389 \
      -D cn=admin,dc=example,dc=org -w adminpassword \
      -b dc=example,dc=org "(uid=${DEMO_USER})" \
      dn uid uidNumber gidNumber homeDirectory loginShell description
done
```

Expected: all three LDAP pods return `uid=devin`, `uidNumber=10002`,
`gidNumber=10002`, and `homeDirectory=/home/devin`.

## 4. Create Devin's FSS Home Directory

Run on the operator node:

```bash
kubectl -n slurm exec deploy/slurm-login-slinky -c login -- sh -lc '
  mkdir -p /home/devin
  chown 10002:10002 /home/devin
  chmod 700 /home/devin
  chmod 711 /home
  ls -ld /home /home/devin
'
```

Expected:

```text
drwx--x--x ... /home
drwx------ ... /home/devin
```

## 5. Validate Devin Through SSSD

Run on the operator node:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- getent passwd devin
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- id devin
kubectl -n slurm exec deploy/slurm-login-slinky -c login -- getent passwd devin
kubectl -n slurm exec deploy/slurm-login-slinky -c login -- id devin
kubectl -n slurm exec deploy/slurm-login-slinky -c login -- sss_ssh_authorizedkeys devin
kubectl -n slurm exec slurm-worker-gb300-0 -c slurmd -- getent passwd devin
kubectl -n slurm exec slurm-worker-gb300-0 -c slurmd -- id devin
```

The current Slinky/login images used in this demo do not include `sss_cache`.
Do not treat `sss_cache: executable file not found` as a validation failure.
The authoritative check is whether `getent`, `id`, and
`sss_ssh_authorizedkeys` return Devin from the controller, login, and worker
pods.

Expected identity shape:

```text
devin:*:10002:10002:Devin Slurm:/home/devin:/bin/bash
uid=10002(devin) gid=10002(devin) groups=10002(devin),11002(project-devin)
```

## 6. Add Devin to Slurm Accounting

Run on the operator node:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- sh -lc '
  sacctmgr -i add account project-devin Description="Project Devin" Organization=example || true
  sacctmgr -i add user name=devin account=project-devin defaultaccount=project-devin || true
  sacctmgr -nP show assoc user=devin format=User,Account,DefaultQOS,QOS
'
```

Expected:

```text
devin|project-devin||normal
```

## 7. SSH as Devin

Run on the operator node:

```bash
LOGIN_IP="$(kubectl -n slurm get svc slurm-login-slinky \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

ssh -i /home/ubuntu/.ssh/devin_slurm_demo \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  devin@"${LOGIN_IP}" \
  'whoami; id; pwd; ls -ld /home /home/devin; ls /home/alice 2>&1 || true'
```

Expected:

```text
devin
uid=10002(devin) gid=10002(devin) groups=10002(devin),11002(project-devin)
/home/devin
drwx--x--x ... /home
drwx------ ... /home/devin
ls: cannot open directory '/home/alice': Permission denied
```

## 8. Create Devin's NCCL Job

SSH as Devin:

```bash
LOGIN_IP="${LOGIN_IP:-$(kubectl -n slurm get svc slurm-login-slinky \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')}"

ssh -i /home/ubuntu/.ssh/devin_slurm_demo \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  devin@"${LOGIN_IP}"
```

Create the job script:

```bash
cat > /home/devin/nccl-imex-demo-gb300.sbatch <<'EOF'
#!/bin/bash
#SBATCH --job-name=devin-nccl-imex
#SBATCH --partition=gb300
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=4
#SBATCH --gres=gpu:4
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=00:10:00
#SBATCH --output=/home/devin/devin-nccl-imex-%j.out
#SBATCH --error=/home/devin/devin-nccl-imex-%j.err

set -euxo pipefail

# Keep OpenMPI control traffic on the pod/node Ethernet path.  NCCL data traffic
# still uses the RDMA rails through the Spectrum-X plugin.
export OMPI_MCA_pml=ob1
export OMPI_MCA_btl=tcp,self
export OMPI_MCA_btl_tcp_if_include=eth0
export OMPI_MCA_oob_tcp_if_include=eth0
export OMPI_MCA_coll=^ucc

export RX_QUEUE_LEN=8192
export IB_RX_QUEUE_LEN=8192
export HCOLL_ENABLE_MCAST_ALL=0
export coll_hcoll_enable=0

export NCCL_DEBUG=WARN
export NCCL_TOPO_DUMP_FILE="/home/devin/nccl-topo-${SLURM_JOB_ID}-$(date +%F-%H%M%S).txt"
export NCCL_SOCKET_IFNAME=eth0
export NCCL_IB_HCA=rdma_vf_rail0,rdma_vf_rail1,rdma_vf_rail2,rdma_vf_rail3
export NCCL_IB_GID_INDEX=3
export NCCL_IB_TIMEOUT=16
export NCCL_IB_RETRY_CNT=7
export NCCL_IB_SL=0
export NCCL_IB_TC=96
export NCCL_IB_ADAPTIVE_ROUTING=1
export NCCL_IB_QPS_PER_CONNECTION=16
export NCCL_NET_GDR_C2C=1
export NCCL_NET=IB
export NCCL_NET_PLUGIN=spcx
export NCCL_ASYNC_ERROR_HANDLING=1
export NCCL_NVLS_ENABLE=0
export NCCL_MNNVL_ENABLE=1
export NCCL_WORK_FIFO_BYTES=0
export NCCL_CUMEM_ENABLE=1
export NCCL_IGNORE_CPU_AFFINITY=1
export NCCL_MIN_CTAS=16

echo "== Slurm allocation =="
echo "job=${SLURM_JOB_ID} user=${USER} nodes=${SLURM_JOB_NODELIST}"

echo "== Rank visibility check =="
srun --mpi=pmix -l bash -lc '
  echo rank=${SLURM_PROCID} local=${SLURM_LOCALID} host=$(hostname -f) cuda=${CUDA_VISIBLE_DEVICES:-unset}
  printf visible_gpu_count=
  nvidia-smi -L | wc -l
  printf imex_channels=
  find /dev/nvidia-caps-imex-channels -maxdepth 1 -type c 2>/dev/null | wc -l
  find /dev/nvidia-caps-imex-channels -maxdepth 1 -type c -exec basename {} \; 2>/dev/null | sort | head -5
'

echo "== NCCL all_reduce_perf =="
srun --mpi=pmix with-nccl-tests-env \
  /opt/nccl-tests/bin/all_reduce_perf \
  -b 8M -e 8G -f 2 -g 1 -n 30
EOF
```

The same sbatch content is tracked in the repo as:

```text
docs/usage/nccl-imex-demo-gb300.sbatch
```

Why `--gres=gpu:4` instead of `--gpus-per-task=1`: this `nccl-tests` build
expects each rank on a node to see all four node GPUs and choose one by local
rank. `--gpus-per-task=1` hides the other GPUs from each rank and can make the
test fail.

Why `--mem=64G`: the live cluster uses consumable memory
(`SelectTypeParameters=CR_CORE_MEMORY`) and `DefMemPerNode=UNLIMITED`. A job
that omits `--mem` can reserve full node memory. The demo uses a bounded memory
request so smaller jobs can share nodes when needed.

## 9. Submit the NCCL Job as Devin

Run as Devin on the login pod:

```bash
JOB="$(sbatch --parsable /home/devin/nccl-imex-demo-gb300.sbatch)"
echo "JOB=${JOB}"

squeue -j "${JOB}"
```

Wait for completion:

```bash
while squeue -h -j "${JOB}" | grep -q .; do
  squeue -j "${JOB}"
  sleep 5
done
```

## 10. Show Accounting and NCCL Output

Run as Devin on the login pod:

```bash
sacct -j "${JOB}" \
  --format=JobID,JobName,User,Account,State,ExitCode,AllocTRES%100,NodeList -P

cat "/home/devin/devin-nccl-imex-${JOB}.out"

if [ -s "/home/devin/devin-nccl-imex-${JOB}.err" ]; then
  cat "/home/devin/devin-nccl-imex-${JOB}.err"
fi
```

Expected accounting shape:

```text
JobID|JobName|User|Account|State|ExitCode|AllocTRES|NodeList
<job>|devin-nccl-imex|devin|project-devin|COMPLETED|0:0|billing=256,cpu=256,gres/gpu=16,mem=...,node=4|...
<job>.batch|batch||project-devin|COMPLETED|0:0|cpu=...,gres/gpu=...,mem=...,node=1|...
<job>.extern|extern||project-devin|COMPLETED|0:0|billing=256,cpu=256,gres/gpu=16,mem=...,node=4|...
```

Expected output shape:

```text
== Slurm allocation ==
job=<job> user=devin nodes=...

== Rank visibility check ==
0: rank=0 local=0 host=... cuda=0,1,2,3
0: visible_gpu_count=4
0: imex_channels=1
...
15: rank=15 local=3 host=... cuda=0,1,2,3
15: visible_gpu_count=4
15: imex_channels=1

== NCCL all_reduce_perf ==
# nccl-tests version 2.17.9 nccl-headers=22903 nccl-library=22903
# Collective test starting: all_reduce_perf
# Using devices
#  Rank  0 Group  0 Pid ... device  0 ... NVIDIA GB300
#  Rank  1 Group  0 Pid ... device  1 ... NVIDIA GB300
#  ...
#  Rank 15 Group  0 Pid ... device  3 ... NVIDIA GB300
NCCL version 2.29.3+cuda13.1
#
#                                                              out-of-place                       in-place
#       size         count      type   redop    root     time   algbw   busbw  #wrong     time   algbw   busbw  #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)             (us)  (GB/s)  (GB/s)
     8388608       2097152     float     sum      -1      ...     ...     ...       0      ...     ...     ...       0
    16777216       4194304     float     sum      -1      ...     ...     ...       0      ...     ...     ...       0
    ...
  8589934592    2147483648     float     sum      -1      ...     ...     ...       0      ...     ...     ...       0
# Out of bounds values : 0 OK
# Avg bus bandwidth    : ...
# Collective test concluded: all_reduce_perf
```

Pass criteria:

- job state is `COMPLETED`;
- `User=devin`;
- `Account=project-devin`;
- `AllocTRES` includes `gres/gpu=16`;
- each rank sees `visible_gpu_count=4`;
- each rank sees `imex_channels=1`;
- NCCL prints `NCCL version 2.29.3+cuda13.1`;
- NCCL prints `# Out of bounds values : 0 OK`.
- `/home/devin/nccl-topo-<job>-<timestamp>.txt` is created for topology
  troubleshooting.

## 11. Optional Per-Job IMEX Channel Check

This is not the main demo workload. Use it only if you want to show that
`switch/nvidia_imex` can expose distinct IMEX channels to overlapping jobs on
the same worker.

If the probe file is not already on the operator node, copy it from the repo:

```bash
scp -o ProxyJump=ubuntu@151.106.182.43 \
  docs/usage/imex-per-job-channel-check.sbatch \
  ubuntu@10.140.0.20:/home/ubuntu/imex-per-job-channel-check.sbatch
```

Copy the probe to Devin's home:

```bash
scp -i /home/ubuntu/.ssh/devin_slurm_demo \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  /home/ubuntu/imex-per-job-channel-check.sbatch \
  devin@"${LOGIN_IP}":/home/devin/imex-per-job-channel-check.sbatch
```

Submit two jobs pinned to the same worker with bounded memory:

```bash
NODE="$(kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  sinfo -h -N -p gb300 -o '%N' | head -1)"

ssh -i /home/ubuntu/.ssh/devin_slurm_demo \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  devin@"${LOGIN_IP}" \
  "sbatch --nodelist=${NODE} --mem=16G /home/devin/imex-per-job-channel-check.sbatch"

ssh -i /home/ubuntu/.ssh/devin_slurm_demo \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  devin@"${LOGIN_IP}" \
  "sbatch --nodelist=${NODE} --mem=16G /home/devin/imex-per-job-channel-check.sbatch"
```

Expected: both jobs can overlap on the same node and print different channel
names, for example `channel1` and `channel2`.

## 12. Cleanup

Keep Devin for repeated demos. If you need to remove only demo job output:

```bash
ssh -i /home/ubuntu/.ssh/devin_slurm_demo \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  devin@"${LOGIN_IP}" \
  'rm -f /home/devin/devin-nccl-imex-*.out /home/devin/devin-nccl-imex-*.err /home/devin/imex-channel-*.out /home/devin/imex-channel-*.err'
```

Do not delete the LDAP user, FSS home, or Slurm account unless you want to
reset the demo from scratch.
