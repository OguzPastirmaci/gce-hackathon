#!/bin/bash
# Lightweight Slurm probe for checking whether switch/nvidia_imex assigns a
# distinct IMEX channel per overlapping job.
#
# Submit two copies on the same node, then compare /home/alice/imex-channel-*.out.

#SBATCH --job-name=imex-channel-check
#SBATCH --partition=gb300
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --time=00:03:00
#SBATCH --output=/home/alice/imex-channel-%j.out
#SBATCH --error=/home/alice/imex-channel-%j.err

set -euxo pipefail

echo "job=${SLURM_JOB_ID} node=$(hostname -f) slurm_node=${SLURMD_NODENAME:-unset} cuda=${CUDA_VISIBLE_DEVICES:-unset}"
date -Is

echo "channels_by_find:"
find /dev/nvidia-caps-imex-channels -maxdepth 1 -type c -exec basename {} \; 2>/dev/null | sort || true

echo "channels_by_ls:"
ls -l /dev/nvidia-caps-imex-channels 2>/dev/null || true

sleep 90

echo "after_sleep_channels:"
find /dev/nvidia-caps-imex-channels -maxdepth 1 -type c -exec basename {} \; 2>/dev/null | sort || true
