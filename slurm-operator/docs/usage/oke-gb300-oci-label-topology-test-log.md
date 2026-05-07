# OKE GB300 OCI Label Topology Test Log

Date: 2026-05-06

Purpose: test the Oracle Cloud Infrastructure RDMA labels that OKE already
adds to nodes as the source of Slinky/Slurm topology.

This is not the Helm `oci://` registry transport and not Open Container
Initiative. Here, OCI means Oracle Cloud Infrastructure node labels such as:

```text
oci.oraclecloud.com/rdma.local_block_id
oci.oraclecloud.com/rdma.network_block_id
oci.oraclecloud.com/rdma.hpc_island_id
oci.oraclecloud.com/rdma.host_id
```

Access:

```bash
ssh -J ubuntu@151.106.182.43 ubuntu@10.140.0.20
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

Active GB300 workers:

```text
10.140.71.103
10.140.79.152
10.140.88.115
10.140.93.120
```

All four active workers had:

```text
nvidia.com/gpu.clique=a2221497-dbce-4964-8826-684c3694fd45.2478
oci.oraclecloud.com/rdma.cluster_id=o527l56ib6q
oci.oraclecloud.com/rdma.cluster_type=computecluster
oci.oraclecloud.com/rdma.hpc_island_id=5xxb22p6ucq
oci.oraclecloud.com/rdma.local_block_id=3bf4jpavrba
oci.oraclecloud.com/rdma.network_block_id=e4c5ds4yava
```

Only `oci.oraclecloud.com/rdma.host_id` differed per node.

Because all active workers are in the same OCI local block, the generated Slurm
topology is one 4-node block:

```text
lb_3bf4jpavrba:
  10.140.71.103
  10.140.79.152
  10.140.88.115
  10.140.93.120
```

Overlay:

```text
docs/usage/oke-gb300-oci-label-topology-test.values.yaml
```

## Result

This test used Oracle Cloud Infrastructure node labels already present on the
OKE nodes. It did not install Topograph and it did not use Open Container
Initiative artifacts as the topology source.

The first overlay defined only the new OCI-derived topology:

```text
topo-oci-local-block:lb_3bf4jpavrba
```

That broke controller startup because Slurm had persisted node topology from
the previous manual split-block test:

```text
topo-gb300-block:gb300_b0
topo-gb300-block:gb300_b1
```

The controller log showed the specific failure:

```text
Invalid node topology specified topo-gb300-block:gb300_b0 for 10.140.88.115
fatal: read_slurm_conf reading /etc/slurm/slurm.conf: Requested topology configuration is not available
```

Recovery required a migration-safe `topology.yaml` that contained both the old
topology names and the new OCI-label-derived topology. The old topology entry
lets Slurm read the persisted node state. After the controller is up, the
operator can reconcile the worker pods and update each Slurm node to the new
OCI-derived topology.

Applied the fixed overlay:

```bash
scp -J ubuntu@151.106.182.43 \
  docs/usage/oke-gb300-oci-label-topology-test.values.yaml \
  ubuntu@10.140.0.20:/home/ubuntu/values-gb300-oci-label-topology-test.yaml

ssh -J ubuntu@151.106.182.43 ubuntu@10.140.0.20
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal

helm -n slurm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  --reuse-values \
  -f /home/ubuntu/values-gb300-oci-label-topology-test.yaml

kubectl -n slurm rollout restart statefulset/slurm-controller
kubectl -n slurm wait --for=condition=Ready pod/slurm-controller-0 --timeout=300s
```

The controller recovered:

```text
Slurmctld(primary) at slurm-controller-0 is UP
```

At first, Slurm still showed the previous split-block topology in node state.
The worker pods already had the correct pod annotation/env:

```text
topology.slinky.slurm.net/spec: topo-oci-local-block:lb_3bf4jpavrba
POD_TOPOLOGY from metadata.annotations['topology.slinky.slurm.net/spec']
```

The operator had last reconciled while the controller was down, so a fresh
NodeSet reconcile was triggered:

```bash
kubectl -n slurm annotate nodesets.slinky.slurm.net slurm-worker-gb300 \
  slinky.slurm.net/reconcile-at="$(date -u +%Y%m%dT%H%M%SZ)" \
  --overwrite
```

The operator then updated all four Slurm nodes:

```text
Update Slurm Node topologySpec Node=10.140.71.103 topologySpec=topo-oci-local-block:lb_3bf4jpavrba
Update Slurm Node topologySpec Node=10.140.79.152 topologySpec=topo-oci-local-block:lb_3bf4jpavrba
Update Slurm Node topologySpec Node=10.140.88.115 topologySpec=topo-oci-local-block:lb_3bf4jpavrba
Update Slurm Node topologySpec Node=10.140.93.120 topologySpec=topo-oci-local-block:lb_3bf4jpavrba
```

Final Slurm topology:

```text
BlockName=lb_3bf4jpavrba BlockIndex=0 Nodes=10.140.71.103,10.140.79.152,10.140.88.115,10.140.93.120 BlockSize=4
```

Final node topology state:

```text
10.140.71.103  Topology=topo-oci-local-block:lb_3bf4jpavrba
10.140.79.152  Topology=topo-oci-local-block:lb_3bf4jpavrba
10.140.88.115  Topology=topo-oci-local-block:lb_3bf4jpavrba
10.140.93.120  Topology=topo-oci-local-block:lb_3bf4jpavrba
```

The test cluster only had one OCI local block, so this validates the label
plumbing and Slinky reconciliation path, not cross-block placement quality. A
cluster with nodes in multiple `oci.oraclecloud.com/rdma.local_block_id` values
is needed to validate real cross-block rank ordering.

## Smoke Test

Submitted a small four-node job as `devin` through the login service:

```bash
LOGIN_IP="$(kubectl -n slurm get svc slurm-login-slinky \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

ssh -i /home/ubuntu/.ssh/devin_slurm_demo \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  devin@"${LOGIN_IP}" \
  'JOB=$(sbatch --parsable --wait \
      --partition=gb300 \
      --account=project-devin \
      --nodes=4 \
      --ntasks-per-node=1 \
      --cpus-per-task=1 \
      --mem=1G \
      --output=/home/devin/topology-oci-smoke-%j.out \
      --wrap="srun /bin/hostname");
    echo JOB=$JOB;
    cat /home/devin/topology-oci-smoke-${JOB}.out;
    sacct -j $JOB --format=JobID,User,Account,State,ExitCode,NodeList -P'
```

Output:

```text
JOB=29
instance20260506003204
instance20260506003155
instance20260506003159
instance20260506003207
JobID|User|Account|State|ExitCode|NodeList
29|devin|project-devin|COMPLETED|0:0|10.140.88.115,10.140.71.103,10.140.79.152,10.140.93.120
29.batch||project-devin|COMPLETED|0:0|10.140.88.115
29.extern||project-devin|COMPLETED|0:0|10.140.88.115,10.140.71.103,10.140.79.152,10.140.93.120
29.0||project-devin|COMPLETED|0:0|10.140.88.115,10.140.71.103,10.140.79.152,10.140.93.120
```

## Current State

- Helm release `slurm` is revision 7.
- `slurm-controller-0` is Ready and `scontrol ping` reports UP.
- The live topology source is the Kubernetes annotation
  `topology.slinky.slurm.net/spec` populated from OCI RDMA labels.
- `docs/usage/oke-gb300-oci-label-topology-test.values.yaml` intentionally
  keeps the legacy manual topology during migration. Once all Slurm node state
  is persisted as `topo-oci-local-block:lb_3bf4jpavrba`, the old
  `topo-gb300-block` entry can be removed in a separate cleanup step.

## Recommendation

For an OCI-label-native path without Topograph:

1. Read `oci.oraclecloud.com/rdma.local_block_id` from Kubernetes node labels.
2. Generate one Slurm block per local block ID.
3. Annotate each Kubernetes node with
   `topology.slinky.slurm.net/spec=topo-oci-local-block:lb_<local_block_id>`.
4. Keep old Slurm topology names in `topology.yaml` during topology migration.
5. Trigger or wait for Slinky NodeSet reconciliation.
6. Remove old topology names only after `scontrol show node -o` confirms every
   node has the new topology.
