# OKE GB300 Topology Block Test Log

Date: 2026-05-06

Cluster access:

```bash
ssh -J ubuntu@151.106.182.43 ubuntu@10.140.0.20
export PATH=/home/ubuntu/bin:$PATH
export OCI_CLI_AUTH=instance_principal
```

Purpose:

- Test Slurm `topology/block` behavior through `topology.yaml`.
- Test `TopologyParam=BlockAsNodeRank`.
- Keep `SwitchType=switch/nvidia_imex` and the working NCCL/IMEX setup intact.
- Validate with a rank-order probe and then the Alice NCCL demo.

Starting Slurm topology config:

```text
GresTypes               = gpu
SelectType              = select/cons_tres
SelectTypeParameters    = CR_CORE_MEMORY
SwitchType              = switch/nvidia_imex
TopologyParam           = (null)
TopologyPlugin          = topology/flat
```

Active Slinky GB300 workers:

```text
slurm-worker-gb300-0  10.140.79.152
slurm-worker-gb300-1  10.140.71.103
slurm-worker-gb300-2  10.140.88.115
slurm-worker-gb300-3  10.140.93.120
```

Experimental block map:

```text
gb300_b0: 10.140.71.103, 10.140.88.115
gb300_b1: 10.140.79.152, 10.140.93.120
```

Overlay:

```text
docs/usage/manifests/oke-gb300-topology-block-test.values.yaml
```

## Apply

Copied the overlay to the operator node:

```bash
scp -J ubuntu@151.106.182.43 \
  docs/usage/manifests/oke-gb300-topology-block-test.values.yaml \
  ubuntu@10.140.0.20:/home/ubuntu/values-gb300-topology-block-test.yaml
```

Annotated only the four active Slinky worker Kubernetes nodes:

```bash
kubectl annotate node 10.140.71.103 topology.slinky.slurm.net/spec="topo-gb300-block:gb300_b0" --overwrite
kubectl annotate node 10.140.88.115 topology.slinky.slurm.net/spec="topo-gb300-block:gb300_b0" --overwrite
kubectl annotate node 10.140.79.152 topology.slinky.slurm.net/spec="topo-gb300-block:gb300_b1" --overwrite
kubectl annotate node 10.140.93.120 topology.slinky.slurm.net/spec="topo-gb300-block:gb300_b1" --overwrite
```

Applied the overlay:

```bash
helm -n slurm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  --version 1.1.0 \
  --reuse-values \
  -f /home/ubuntu/values-gb300-topology-block-test.yaml
```

Result:

```text
Release "slurm" has been upgraded.
REVISION: 5
```

## Reconfigure Note

After Helm revision 5, the generated ConfigMaps were correct:

```text
slurm-config:
  TopologyParam=BlockAsNodeRank

slurm-config-extra:
  topology.yaml
```

The running `slurmctld` did not immediately load the new projected config.
Before reconfigure, Slinky tried to push node topology and the operator logged:

```text
Requested topology configuration is not available
```

After the projected `topology.yaml` appeared in the controller pod, this command
made Slurm load it:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- scontrol reconfigure
```

After that, Slinky propagated the Kubernetes node topology annotations into
Slurm successfully.

## Topology Validation

Config after reconfigure:

```text
GresTypes               = gpu
SelectType              = select/cons_tres
SelectTypeParameters    = CR_CORE_MEMORY
SwitchType              = switch/nvidia_imex
TopologyParam           = BlockAsNodeRank
TopologyPlugin          = topology/flat
```

`scontrol show config` still reports `TopologyPlugin=topology/flat`, but Slurm
loaded the block topology from `topology.yaml`. `scontrol show topology`
reported:

```text
BlockName=gb300_b0 BlockIndex=0 Nodes=10.140.71.103,10.140.88.115 BlockSize=2
BlockName=gb300_b1 BlockIndex=1 Nodes=10.140.79.152,10.140.93.120 BlockSize=2
AggregatedBlock=gb300_b[0-1] BlockIndex=2 Nodes=10.140.71.103,10.140.79.152,10.140.88.115,10.140.93.120 BlockSize=4
```

Slurm nodes showed the expected topology:

```text
10.140.71.103  Topology=topo-gb300-block:gb300_b0
10.140.88.115  Topology=topo-gb300-block:gb300_b0
10.140.79.152  Topology=topo-gb300-block:gb300_b1
10.140.93.120  Topology=topo-gb300-block:gb300_b1
```

## Rank-Order Probe

Submitted a 4-node, one-rank-per-node probe as `alice`.

Job:

```text
24|topology-rank-probe|alice|project-a|COMPLETED|0:0|billing=4,cpu=4,gres/gpu=4,mem=16G,node=4|10.140.88.115,10.140.71.103,10.140.79.152,10.140.93.120
```

Output:

```text
JOB_ID=24
JOB_NODELIST=10.140.88.115,10.140.71.103,10.140.79.152,10.140.93.120
HOSTNAMES_FROM_NODELIST
10.140.88.115
10.140.71.103
10.140.79.152
10.140.93.120
SRUN_RANKS
0: instance20260506003204
1: instance20260506003159
2: instance20260506003155
3: instance20260506003207
```

Interpretation:

- ranks 0-1 landed in `gb300_b0`;
- ranks 2-3 landed in `gb300_b1`.

## Two-Job Packing Probe

Submitted two simultaneous 2-node exclusive jobs as `alice`.

Running placement:

```text
26  gb300  topology-pack-b  alice  R  2  10.140.79.152,10.140.93.120
25  gb300  topology-pack-a  alice  R  2  10.140.71.103,10.140.88.115
```

Accounting:

```text
25|topology-pack-a|alice|project-a|COMPLETED|0:0|billing=288,cpu=288,gres/gpu=8,mem=32G,node=2|10.140.88.115,10.140.71.103
26|topology-pack-b|alice|project-a|COMPLETED|0:0|billing=288,cpu=288,gres/gpu=8,mem=32G,node=2|10.140.79.152,10.140.93.120
```

Output:

```text
JOB=25 NODELIST=10.140.88.115,10.140.71.103
10.140.88.115
10.140.71.103
0: instance20260506003204
1: instance20260506003159

JOB=26 NODELIST=10.140.79.152,10.140.93.120
10.140.79.152
10.140.93.120
0: instance20260506003155
1: instance20260506003207
```

Result: Slurm packed each 2-node job within one block.

## NCCL Regression

Created a reusable sbatch file:

```text
docs/usage/jobs/nccl-imex-demo-gb300.sbatch
```

Copied it to `/home/alice/nccl-imex-demo-gb300.sbatch` and submitted it as
`alice`.

Accounting:

```text
27|alice-nccl-imex|alice|project-a|COMPLETED|0:0|billing=256,cpu=256,gres/gpu=16,mem=256G,node=4|10.140.88.115,10.140.71.103,10.140.79.152,10.140.93.120
27.1|with-nccl-tests-env||project-a|COMPLETED|0:0|cpu=256,gres/gpu=16,mem=256G,node=4|10.140.88.115,10.140.71.103,10.140.79.152,10.140.93.120
```

Slurm allocation:

```text
job=27 user=alice nodes=10.140.88.115,10.140.71.103,10.140.79.152,10.140.93.120
10.140.88.115
10.140.71.103
10.140.79.152
10.140.93.120
```

All ranks saw four local GPUs and one IMEX channel. NCCL ran on all 16 GB300
GPUs:

```text
#  Rank  0 Group  0 Pid   2032 on instance20260506003204 device  0 [0008:06:00] NVIDIA GB300
#  Rank  1 Group  0 Pid   2033 on instance20260506003204 device  1 [0009:06:00] NVIDIA GB300
#  Rank  2 Group  0 Pid   2034 on instance20260506003204 device  2 [0018:06:00] NVIDIA GB300
#  Rank  3 Group  0 Pid   2035 on instance20260506003204 device  3 [0019:06:00] NVIDIA GB300
#  Rank  4 Group  0 Pid   1654 on instance20260506003159 device  0 [0008:06:00] NVIDIA GB300
#  Rank  5 Group  0 Pid   1655 on instance20260506003159 device  1 [0009:06:00] NVIDIA GB300
#  Rank  6 Group  0 Pid   1656 on instance20260506003159 device  2 [0018:06:00] NVIDIA GB300
#  Rank  7 Group  0 Pid   1657 on instance20260506003159 device  3 [0019:06:00] NVIDIA GB300
#  Rank  8 Group  0 Pid   1792 on instance20260506003155 device  0 [0008:06:00] NVIDIA GB300
#  Rank  9 Group  0 Pid   1793 on instance20260506003155 device  1 [0009:06:00] NVIDIA GB300
#  Rank 10 Group  0 Pid   1794 on instance20260506003155 device  2 [0018:06:00] NVIDIA GB300
#  Rank 11 Group  0 Pid   1795 on instance20260506003155 device  3 [0019:06:00] NVIDIA GB300
#  Rank 12 Group  0 Pid   1497 on instance20260506003207 device  0 [0008:06:00] NVIDIA GB300
#  Rank 13 Group  0 Pid   1498 on instance20260506003207 device  1 [0009:06:00] NVIDIA GB300
#  Rank 14 Group  0 Pid   1499 on instance20260506003207 device  2 [0018:06:00] NVIDIA GB300
#  Rank 15 Group  0 Pid   1500 on instance20260506003207 device  3 [0019:06:00] NVIDIA GB300
NCCL version 2.29.3+cuda13.1
```

NCCL `all_reduce_perf -b 8M -e 8G -f 2 -g 1 -n 30` result:

```text
#                                                              out-of-place                       in-place
#       size         count      type   redop    root     time   algbw   busbw  #wrong     time   algbw   busbw  #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)             (us)  (GB/s)  (GB/s)
     8388608       2097152     float     sum      -1    95.46   87.87  164.76       0    93.97   89.27  167.38       0
    16777216       4194304     float     sum      -1   156.74  107.04  200.70       0   155.76  107.71  201.96       0
    33554432       8388608     float     sum      -1   147.08  228.14  427.77       0   145.65  230.37  431.94       0
    67108864      16777216     float     sum      -1   461.01  145.57  272.94       0   459.50  146.05  273.84       0
   134217728      33554432     float     sum      -1   520.73  257.75  483.28       0   520.73  257.75  483.28       0
   268435456      67108864     float     sum      -1   760.81  352.83  661.55       0   759.79  353.30  662.45       0
   536870912     134217728     float     sum      -1  1499.69  357.99  671.23       0  1493.25  359.53  674.12       0
  1073741824     268435456     float     sum      -1  2968.27  361.74  678.26       0  2968.85  361.67  678.13       0
  2147483648     536870912     float     sum      -1  5877.54  365.37  685.07       0  5864.31  366.20  686.62       0
  4294967296    1073741824     float     sum      -1  11594.2  370.44  694.58       0  11592.5  370.49  694.68       0
  8589934592    2147483648     float     sum      -1  22965.1  374.04  701.33       0  22964.0  374.06  701.37       0
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 513.51
# Collective test concluded: all_reduce_perf
```

Topology dump:

```text
/home/alice/nccl-topo-27-2026-05-06-194050.txt
```

## Result

The topology/block experiment worked:

- `topology.yaml` loaded successfully after `scontrol reconfigure`;
- Slinky propagated Kubernetes node annotations to Slurm node `Topology=...`;
- rank order grouped the 4-node allocation by block;
- two concurrent 2-node jobs were packed into separate blocks;
- 4-node/16-GPU NCCL completed successfully with IMEX/DRA still enabled.

Final cluster state after the test:

- Helm release `slurm` remains at revision 5 with the topology overlay active.
- The four active GB300 Kubernetes nodes still have
  `topology.slinky.slurm.net/spec` annotations.
- `squeue -a` was empty.
- Recent `slurm-operator` logs had no `Requested topology configuration is not
  available` errors after `scontrol reconfigure`.
