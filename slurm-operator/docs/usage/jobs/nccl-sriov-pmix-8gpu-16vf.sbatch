#!/usr/bin/env bash
#SBATCH --job-name=nccl-8gpu-16vf
#SBATCH --partition=gpu-b4
#SBATCH --account=project-a
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=2
#SBATCH --gres=gpu:8

set -euo pipefail

export LD_LIBRARY_PATH=/usr/local/openmpi/lib:/usr/lib/x86_64-linux-gnu:/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}
export NCCL_DEBUG=INFO
export NCCL_IB_SPLIT_DATA_ON_QPS=0
export NCCL_IB_QPS_PER_CONNECTION=4
export NCCL_IB_GID_INDEX=3
export NCCL_IB_HCA=mlx5
export NCCL_IB_TC=41
export NCCL_IB_SL=0
export NCCL_IB_TIMEOUT=22

echo "SLURM_JOB_ID=${SLURM_JOB_ID}"
echo "SLURM_JOB_NODELIST=${SLURM_JOB_NODELIST}"
echo "SLURM_NTASKS=${SLURM_NTASKS}"
echo "SLURM_GPUS=${SLURM_GPUS:-unset}"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-unset}"
echo "Preflight per node: expect 8 visible GPUs and 16 SR-IOV RDMA VFs"

srun --mpi=none -N 2 --ntasks-per-node=1 --export=ALL sh -lc '
  printf "%s " "$(hostname)"
  printf "cuda_visible=%s " "${CUDA_VISIBLE_DEVICES:-unset}"
  printf "gpus="
  nvidia-smi -L | wc -l | tr -d "\n"
  printf " vfs="
  ls /sys/class/infiniband | wc -l | tr -d "\n"
  printf " ibdevs="
  ls /sys/class/infiniband | sort | paste -sd, -
  test "$(nvidia-smi -L | wc -l)" -eq 8
  test "$(ls /sys/class/infiniband | wc -l)" -eq 16
'

echo "Running NCCL all_reduce_perf with 8 ranks per node and 1 GPU per rank"
srun --mpi=pmix --export=ALL \
  /opt/nccl-tests/bin/all_reduce_perf -b 1G -f 2 -g 1 -e 4G -c 1
