# Hardware Fault Behavior with Time-Slicing on NVIDIA k8s-device-plugin

## Background

- **Environment**: OKE worker node with 4x L40S GPUs, Time-Slicing enabled
- **Question**: When a hardware fault occurs on one of the four physical GPUs, does the nvidia-device-plugin detect the failure and remove all virtual GPU resources tied to the failed GPU from the scheduling pool?

## Answer: Detection Is Partial — Most Replicas Remain Schedulable

The plugin **does** detect hardware faults via NVML event monitoring, but due to a bug in the replica-to-device mapping, **only 1 out of N replicas** for the failed GPU gets marked unhealthy. The remaining replicas stay in the scheduling pool, causing new pods to fail at runtime.

## How Health Checks Work

The plugin monitors three NVML event types:
- `EventTypeXidCriticalError` — Critical Xid errors
- `EventTypeDoubleBitEccError` — Double-bit ECC errors
- `EventTypeSingleBitEccError` — Single-bit ECC errors

Events are polled every 5 seconds. When a critical event is detected, the plugin identifies the affected GPU by UUID and marks the corresponding device as `Unhealthy` via the `ListAndWatch` gRPC stream to kubelet.

## The Bug: `parentToDeviceMap` Can Only Hold One Replica Per Physical GPU

When Time-Slicing creates replicas (e.g., 4 replicas for `GPU-abc123`), four separate `Device` structs are created:
- `GPU-abc123::0`
- `GPU-abc123::1`
- `GPU-abc123::2`
- `GPU-abc123::3`

All four are passed to `checkHealth()`. Inside, the code builds a lookup map:

```go
// health.go:74,88
parentToDeviceMap := make(map[string]*Device)
for _, d := range devices {
    uuid, _, _, _ := r.getDevicePlacement(d)  // strips "::N" → returns "GPU-abc123"
    parentToDeviceMap[uuid] = d                // OVERWRITES previous entry!
}
```

Since `GetUUID()` strips the annotation (`GPU-abc123::2` → `GPU-abc123`), all four replicas map to the same key. Each overwrites the previous, so **only the last-iterated replica survives** in the map.

When a fault fires:

```go
// health.go:154,170
d, exists := parentToDeviceMap[eventUUID]  // finds ONE replica
unhealthy <- d                             // marks only that ONE
```

`ListAndWatch` marks only that single replica as `Unhealthy`. The other 3 remain `Healthy`.

## Shared Fault Domain Makes It Worse

Even **before** new pods are scheduled, the hardware fault has likely **already destroyed all running workloads on that GPU**:

> *"each workload runs in the same fault-domain as all the others (meaning if one workload crashes, they all do)."*

When GPU #2 suffers a hardware fault:

| What happens | Impact |
|---|---|
| All CUDA contexts on GPU #2 receive fatal errors | All running pods on GPU #2 fail simultaneously |
| This includes all tenants sharing that GPU | Cross-tenant failure |
| The plugin marks 1/4 replicas unhealthy | 3/4 replicas remain "healthy" in kubelet's view |
| New pods scheduled to those 3 replicas | Immediate CUDA errors on launch |
| Pods on GPUs #0, #1, #3 | Unaffected (separate physical hardware) |

**Note**: MPS would have the same blast radius for hardware faults — all clients on the failed GPU would be affected. Hardware faults are below the level where MPS vs Time-Slicing isolation matters.

## Full Failure Timeline

```
Physical GPU #2 hardware fault
│
├─ Immediate: All CUDA contexts on GPU #2 receive fatal Xid error
│   └─ All running pods on GPU #2 fail (all tenants affected)
│
├─ Within 5 seconds: NVML event detected by health check
│   └─ XidCriticalError event fires for GPU #2's UUID
│   └─ parentToDeviceMap lookup finds ONE replica pointer
│   └─ That single replica marked Unhealthy
│   └─ ListAndWatch sends updated device list to kubelet
│
├─ After health update: Kubelet removes 1 replica from allocatable pool
│   └─ 3 replicas for GPU #2 still appear Healthy
│   └─ Node advertises: 12 healthy replicas (GPUs #0,#1,#3)
│   │   + 3 stale "healthy" replicas (GPU #2)
│   └─ Effectively 15 "healthy" replicas, 3 of which are broken
│
├─ Subsequent scheduling: New pods requesting nvidia.com/gpu
│   └─ 3/15 chance of landing on a stale GPU #2 replica
│   └─ Pod starts → CUDA initialization fails → CrashLoopBackOff
│
└─ Recovery: NONE automatic
    └─ Code comment: "FIXME: there is no way to recover from
    │   the Unhealthy state" (server.go:277)
    └─ The 1 marked-unhealthy replica never recovers
    └─ The 3 falsely-healthy replicas never get corrected
    └─ Only fix: restart the device plugin pod, or drain the node
```

## Mitigations

### Short-Term (Operational)

1. **DCGM Exporter + Prometheus alerting**: Monitor Xid errors externally. When a critical Xid fires, automatically cordon and drain the node. Don't rely on the device plugin's partial health reporting.

2. **Pod-level liveness probes**: Add a CUDA health check (e.g., `cudaGetDeviceProperties` or a trivial kernel launch) as a liveness probe. Pods on the faulty GPU will fail the probe and get restarted on a healthy node.

3. **`failRequestsGreaterThanOne: true`**: Set this in the device plugin config to prevent confusion about what "2 GPUs" means in a time-sliced setup.

### Medium-Term (Architectural)

1. **File a bug upstream** on the k8s-device-plugin repo for the `parentToDeviceMap` single-replica issue. The fix is straightforward — the map should store a slice of devices per UUID, and when an event fires, all replicas for that UUID should be marked unhealthy.

2. **Re-evaluate MPS**: For software fault isolation (OOM, crashes), MPS is strictly superior to Time-Slicing. For hardware faults, both mechanisms have the same blast radius.

## The Honest Answer

The plugin **partially detects** the fault but **fails to fully remove** the faulty GPU's virtual resources from the scheduling pool. The result is:

1. Existing workloads on the faulty GPU are destroyed immediately (all tenants on that GPU)
2. New workloads continue to be scheduled to 3 out of 4 of that GPU's replicas
3. Those new workloads fail at CUDA initialization
4. There is no automatic recovery — manual intervention (node drain or plugin restart) is required
