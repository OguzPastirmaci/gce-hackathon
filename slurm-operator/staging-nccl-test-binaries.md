# Staging NCCL Test Binaries via DaemonSet

If you don't want to build a [custom slurmd image](deploying-slinky-on-oke.md#building-custom-slurm-images-optional) but need nccl-tests for quick testing, you can stage the binaries from a pre-built image onto each GPU node via a DaemonSet, then mount them into the slurmd pods.

## Step 1: Deploy the stager DaemonSet

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nccl-tests-stager
  namespace: slurm
spec:
  selector:
    matchLabels:
      app: nccl-tests-stager
  template:
    metadata:
      labels:
        app: nccl-tests-stager
    spec:
      nodeSelector:
        node.kubernetes.io/instance-type: BM.GPU.B4.8
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      initContainers:
        - name: copy-nccl
          image: ghcr.io/coreweave/nccl-tests:13.1.1-devel-ubuntu24.04-nccl2.29.7-1-7112046
          command: ["bash", "-c"]
          args:
            - |
              set -e
              rm -rf /host-nccl/bin /host-nccl/lib
              mkdir -p /host-nccl/bin /host-nccl/lib
              cp /opt/nccl-tests/build/*_perf /host-nccl/bin/
              # Copy NCCL and CUDA runtime only -- do NOT copy libibverbs (must match host kernel)
              cp /usr/lib/x86_64-linux-gnu/libnccl.so* /host-nccl/lib/ 2>/dev/null || true
              cp /usr/local/cuda/targets/x86_64-linux/lib/libcudart.so* /host-nccl/lib/ 2>/dev/null || true
              echo "DONE"
          volumeMounts:
            - name: host-nccl
              mountPath: /host-nccl
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
      volumes:
        - name: host-nccl
          hostPath:
            path: /opt/nccl-tests
            type: DirectoryOrCreate
```

> **Important:** Do not copy `libibverbs.so` from the container image. The slurmd container must use the system's `libibverbs` that matches the host kernel's RDMA modules. Mismatched versions cause segfaults in `ibv_cmd_reg_dmabuf_mr`.

## Step 2: Mount `/opt/nccl-tests` in the slurmd pods

Add the hostPath volume and mount to your `slinky-values.yaml` nodeset:

```yaml
nodesets:
  gpu-b4:
    slurmd:
      volumeMounts:
        - name: devinf
          mountPath: /dev/infiniband
        - name: shm
          mountPath: /dev/shm
        - name: nccl-tests
          mountPath: /opt/nccl-tests        # Staged binaries + libs
    podSpec:
      volumes:
        - name: devinf
          hostPath:
            path: /dev/infiniband
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 32Gi
        - name: nccl-tests
          hostPath:
            path: /opt/nccl-tests
```

Then upgrade and restart the worker pods:

```sh
helm upgrade slurm oci://ghcr.io/slinkyproject/charts/slurm \
  -f slinky-values.yaml --namespace=slurm
kubectl -n slurm delete pod -l slinky.slurm.net/component=worker
```

Verify the binaries are accessible:

```sh
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  srun --gres=gpu:1 ls /opt/nccl-tests/bin/all_reduce_perf
```

## Notes

- When using the stager approach, job scripts need `LD_LIBRARY_PATH=/opt/nccl-tests/lib:/usr/lib/x86_64-linux-gnu` to find the staged NCCL and CUDA libraries. With the [custom slurmd image](deploying-slinky-on-oke.md#building-custom-slurm-images-optional), this is not needed (libraries are system-installed).
- The stager DaemonSet must run before the slurmd pods start. If the slurmd pods are already running, restart them after deploying the stager.
- The binaries are placed at `/opt/nccl-tests/bin/` on the host, which matches the path used by the custom slurmd images.
