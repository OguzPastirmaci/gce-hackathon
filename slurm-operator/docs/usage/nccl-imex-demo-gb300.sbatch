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

# Keep OpenMPI control traffic on eth0. NCCL data traffic still uses the RDMA
# rails through the Spectrum-X plugin.
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
scontrol show hostnames "${SLURM_JOB_NODELIST}"

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
