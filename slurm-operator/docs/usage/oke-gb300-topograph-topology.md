# OKE GB300 Topograph OCI Provider Topology Option

Status: researched, not deployed in the tested GB300 cluster.

This note captures the specific Topograph path we want to evaluate next:
Topograph with `provider=oci` and `engine=slinky`.

This is different from what was tested on 2026-05-06. The tested path did not
install Topograph. It manually used Oracle Cloud Infrastructure labels already
present on OKE nodes, generated Slurm `topology.yaml`, and used Slinky's
`topology.slinky.slurm.net/spec` node annotations. That validates the Slinky
topology wiring, but not the Topograph controller or the Topograph OCI provider.

## What Topograph Adds

Topograph is a topology discovery and topology rendering service. With
`engine=slinky`, Topograph writes Slurm topology configuration into a Kubernetes
ConfigMap for a Slinky Slurm-on-Kubernetes deployment.

Topograph does not deploy Slinky itself. The Slinky cluster must already exist.

The main benefit for our GB300 work would be automation:

- node add/remove events can trigger topology regeneration;
- the output ConfigMap can be managed consistently by Topograph;
- the same framework can use different topology sources through providers.

The main cost is another controller and another moving part in the Slurm config
reload path. We still need to validate the end-to-end behavior with this repo's
Slurm 25.11 `topology.yaml` setup, Slinky dynamic-node topology annotations,
and controller reconfigure/restart sequencing.

## Provider: `oci`

Use this when the desired topology source is Oracle Cloud Infrastructure
physical/network placement metadata rather than DRA clique labels.

Topograph's OCI provider has two variants:

- IMDS-based: queries each participating node's local OCI IMDS endpoint for RDMA
  topology data. The upstream docs describe this as SLURM-cluster-only because
  Topograph needs access to each participating worker node.
- API-based: the default OCI provider. It uses OCI Core Services APIs to list
  compute hosts and read host/network topology metadata.

For OKE/Slinky, the API-based OCI provider is the path to test first because it
can run as a Kubernetes workload. It requires OCI authorization. The upstream
minimum IAM permission is:

```text
Allow dynamic-group <dynamic-group> to inspect dedicated-vm-hosts in tenancy
```

For this environment, prefer instance-principal-style auth over static user
keys. That still needs a specific OKE validation because a Kubernetes pod must
be able to obtain the intended OCI credentials from the node or from an approved
workload identity mechanism. If that is blocked, the fallback is an explicit OCI
credential secret scoped only to the required inspect permission.

The DRA provider is not the target for this test. It reads
`nvidia.com/gpu.clique` labels and is useful for MNNVL clique topology, but the
requested path here is OCI physical/network topology.

## What We Tested

The current validated path is intentionally simpler:

1. Read Kubernetes node labels such as:

```text
oci.oraclecloud.com/rdma.local_block_id
oci.oraclecloud.com/rdma.network_block_id
oci.oraclecloud.com/rdma.hpc_island_id
nvidia.com/gpu.clique
```

2. Generate `topology.yaml` from those labels.
3. Annotate Kubernetes nodes with Slinky's topology annotation:

```text
topology.slinky.slurm.net/spec=topo-oci-local-block:lb_<local_block_id>
```

4. Let the Slinky operator update the registered Slurm nodes.

This avoids deploying Topograph, but node additions require a script or manual
process to regenerate `topology.yaml`, update node annotations, apply the Helm
overlay, and trigger Slinky reconciliation.

The validated test log is:

```text
docs/usage/oke-gb300-oci-label-topology-test-log.md
```

## What Happens When a Local Block Is Too Small

Local block should usually be treated as a preferred placement unit, not as the
largest schedulable unit.

For production topology generation, use multiple levels:

```text
OCI local_block_id    -> smallest Slurm block
OCI network_block_id  -> aggregate Slurm block
OCI hpc_island_id     -> larger aggregate grouping
```

For example:

```text
local_block_a = 4 nodes
local_block_b = 4 nodes
network_block_x = 8 nodes
```

If a job requests 4 nodes, Slurm can keep it inside one local block. If a job
requests 6 nodes, the job needs a valid aggregate block, such as the network
block. Without the aggregate topology, the job may remain pending even when
enough total idle nodes exist across the cluster.

For Topograph, this means the `slinky` engine should be configured with block
sizes that represent both small and aggregate placement units, for example:

```yaml
global:
  engine:
    name: slinky
  engineParams:
    plugin: topology/block
    blockSizes:
      - 4
      - 8
      - 16
```

The exact sizes must match the actual OCI or DRA topology discovered for the
cluster. Do not assume every cluster has the same local block or aggregate
sizes; verify generated output with `scontrol show topology`.

## Expected Slinky Integration Shape

The expected OCI provider plus Slinky engine shape is:

```yaml
global:
  provider:
    name: oci
  engine:
    name: slinky
  engineParams:
    namespace: slurm
    podSelector:
      matchLabels:
        app.kubernetes.io/name: slurmd
    plugin: topology/block
    blockSizes:
      - 4
      - 8
      - 16
    topologyConfigmapName: slurm-config-extra
    topologyConfigPath: topology.yaml
```

Notes for this repo:

- Treat this as a starting shape, not a tested manifest. The exact Topograph
  values for OCI credentials, compartment/region scope, and provider parameters
  still need to be validated against the chart version we deploy.
- Use `topologyConfigPath: topology.yaml`, because the current Slinky chart
  values mount `configFiles.topology.yaml`.
- Confirm the generated ConfigMap key and format before wiring this into the
  live Slurm controller. Upstream examples often show `topology.conf`; our
  current tested path uses Slurm's YAML topology file.
- Keep old topology names during migration. Slurm persists node topology in
  controller state, so removing a previous topology name before nodes reconcile
  can prevent `slurmctld` from starting.
- After Topograph updates the ConfigMap, Slurm still needs to load the changed
  topology and Slinky still needs to reconcile Slurm node topology. Validate the
  exact reload path before using this in production.

## Recommendation

Keep the current no-Topograph OCI-label path as the baseline until we need
automatic topology regeneration.

Use Topograph with `provider=oci` when either of these becomes important:

- nodes are added and removed often enough that manual/scripted topology
  regeneration is operationally risky;
- we want OCI physical/network placement metadata to be discovered directly
  from OCI APIs instead of relying on the subset of OCI labels already present
  on Kubernetes nodes;
- we want one controller to handle topology refresh across multiple partitions.

For the next Topograph test, use a non-production window and validate this
sequence:

1. Deploy Topograph with `provider=oci`, `engine=slinky`, and
   `plugin=topology/block`.
2. Use OCI instance-principal-style auth if the pod can obtain it; otherwise use
   a tightly scoped OCI credential secret.
3. Point Topograph at `slurm-config-extra` and the `topology.yaml` key.
4. Confirm the generated ConfigMap content before reloading Slurm.
5. Keep any previous topology names during migration so persisted Slurm node
   state does not block controller startup.
6. Reconfigure or restart the Slurm controller in a controlled way.
7. Confirm `scontrol show topology` and `scontrol show node -o`.
8. Add or remove one GB300 worker and verify Topograph updates the topology.
9. Submit a multi-node NCCL job and capture the output.

## References

- NVIDIA Topograph Kubernetes quickstart: `docs/get-started/quickstart-k8s.md`
- NVIDIA Topograph Slinky engine: `docs/engines/slinky.md`
- NVIDIA Topograph OCI provider: `docs/providers/oci.md`
