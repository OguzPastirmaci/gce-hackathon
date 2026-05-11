#!/bin/bash
#SBATCH --job-name=rccl-mi300x-slurm
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --exclusive
#SBATCH --output=/home/alice/rccl-mi300x-%j.out
#SBATCH --error=/home/alice/rccl-mi300x-%j.err

set -euo pipefail

source /opt/oci-hpc/rccl-tests/env.sh
export LD_LIBRARY_PATH=/workspace/rccl/install/lib:${LD_LIBRARY_PATH:-}

NUM_GPUS=8
NP=$((SLURM_NNODES * NUM_GPUS))

echo "date=$(date -Is)"
echo "user=$(whoami) uid=$(id)"
echo "job=${SLURM_JOB_ID} nodes=${SLURM_JOB_NODELIST} nnodes=${SLURM_NNODES} ntasks=${SLURM_NTASKS:-unset} np=${NP}"
echo "hostnames:"
scontrol show hostnames "${SLURM_JOB_NODELIST}"
echo "rocm-smi summary:"
rocm-smi --showproductname --showdriverversion || true
echo "rccl all_reduce_perf start"

# These are the same MI300X RCCL/OpenMPI variables used by the OCI Kubernetes
# MPIJob manifest. Under Slurm, OpenMPI uses ras/plm slurm instead of ssh.
mpirun \
  --mca ras slurm \
  --mca plm slurm \
  -mca coll ^hcoll \
  -mca pml ucx \
  -mca btl ^openib \
  -np "${NP}" \
  -npernode "${NUM_GPUS}" \
  --bind-to numa \
  -x RX_QUEUE_LEN=8192 \
  -x IB_RX_QUEUE_LEN=8192 \
  -x UCX_NET_DEVICES=mlx5_0:1 \
  -x HCOLL_ENABLE_MCAST_ALL=0 \
  -x coll_hcoll_enable=0 \
  -x NCCL_CUMEM_ENABLE=0 \
  -x NCCL_IB_TIMEOUT=22 \
  -x NCCL_IB_SL=0 \
  -x NCCL_IB_TC=41 \
  -x NCCL_IB_GID_INDEX=3 \
  -x NCCL_DEBUG=WARN \
  -x NCCL_IB_QPS_PER_CONNECTION=1 \
  -x NCCL_IB_SPLIT_DATA_ON_QPS=0 \
  -x NCCL_IB_HCA="=mlx5_0,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_7,mlx5_8,mlx5_9" \
  -x NCCL_PXN_DISABLE=0 \
  -x NCCL_NET_PLUGIN=none \
  -x LD_LIBRARY_PATH \
  /opt/oci-hpc/rccl-tests/bin/all_reduce_perf -b 1G -e 16G -f 2 -g 1 -n 50
