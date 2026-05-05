# Time-Slicing vs MPS: Isolation Analysis for Financial Batch GPGPU on L40S

## Background

- **Platform**: Night-time batch-processing for financial institutions (multi-tenant)
- **Workload**: GPGPU business-logic computation and data processing (not AI/ML inference)
- **Environment**: OCI OKE on bare-metal nodes (BM.GPU.L40S.4 / 4 physical GPUs per node)
- **Requirements**:
  1. 8-16 concurrent lightweight batch jobs per node
  2. Tenant isolation: a single job OOM or crash must not affect other tenants

## Project Decision Logic (as proposed)

- MIG: Not supported on L40S — excluded
- MPS: Rejected due to shared failure domain (process crash affects all)
- Time-Slicing: Chosen for "strong isolation via context-switching"

## Critical Finding: The Premise About Time-Slicing Isolation Is Wrong

The project's decision logic states Time-Slicing provides "strong isolation via context-switching." The NVIDIA device plugin's own documentation says the exact opposite. From the [k8s-device-plugin README](https://github.com/NVIDIA/k8s-device-plugin):

> *"nothing special is done to isolate workloads that are granted replicas from the same underlying GPU, and each workload has access to the GPU memory and **runs in the same fault-domain as of all the others (meaning if one workload crashes, they all do)**."*

## Comparison of GPU Sharing Mechanisms

| Property | MIG | MPS | Time-Slicing |
|---|---|---|---|
| **L40S support** | Not supported | Supported | Supported |
| **Memory isolation** | Hardware-partitioned | Enforced per-client by daemon | **None** — full memory shared |
| **Compute isolation** | Hardware-partitioned | Enforced per-client limits | **None** — fair-share time only |
| **Fault domain** | Independent | Shared (daemon crash = all clients down) | **Shared** (one crash = all down) |
| **OOM from tenant A affects tenant B?** | No | No (memory limits enforced) | **Yes** |
| **Crash from tenant A affects tenant B?** | No | Yes (daemon restarts, all clients lost) | **Yes** |

### The Irony of the Current Decision

MPS was rejected because "an abnormal termination of any process could take down the other processes." But Time-Slicing has **the exact same failure domain problem, plus worse isolation in every other dimension**:

- **MPS**: Enforces per-client memory limits and compute quotas. A tenant cannot OOM another tenant during normal operation. The failure-domain risk is specifically when a fatal GPU error (not a normal application crash) causes the MPS daemon to restart.
- **Time-Slicing**: No memory limits, no compute limits, same shared failure domain. A tenant that allocates too much GPU memory can cause CUDA OOM errors in other tenants' contexts immediately.

## Anti-Patterns for Time-Slicing in GPGPU Use Cases

### 1. Memory Contention (Biggest Risk)

With 8-16 concurrent jobs per L40S (48 GB VRAM), each job gets access to the **full 48 GB** — there is no partitioning. If 16 jobs collectively try to allocate more than 48 GB, CUDA will return `cudaErrorMemoryAllocation` to whichever job happens to allocate last. There is no fairness, no reservation, no per-tenant limit.

For financial batch workloads where you need **guarantees**, this is unacceptable.

### 2. Context-Switch Overhead Scales Poorly at 8-16 Contexts

CUDA time-slicing works by round-robin context switching. Each switch requires saving and restoring the full GPU context (registers, shared memory, local memory). With 8-16 concurrent contexts on a single GPU:

- Each job gets roughly `1/N` of the GPU time, but the effective throughput is **less than `1/N`** due to switch overhead
- For compute-heavy GPGPU kernels with large register files or shared memory usage, the context save/restore cost is non-trivial
- Unlike MPS, which allows true concurrent execution via space partitioning, time-slicing is strictly serial — only one context runs at any given moment

### 3. No Resource Accounting = No SLA Enforcement

From the README:

> *"requesting more than one shared GPU does not imply that you will get guaranteed access to a proportional amount of compute power. It only implies that you will get access to a GPU that is shared by other clients (each of which has the freedom to run as many processes on the underlying GPU as they want)."*

For a multi-tenant financial platform, you cannot enforce per-tenant SLAs with Time-Slicing.

### 4. Health Check Gap

The device plugin's health check only marks 1 out of N replicas as unhealthy when a physical GPU fails. The remaining replicas continue accepting new pods, which then fail at runtime. (See companion document for details.)

## Recommendation

### Re-evaluate MPS — It Is Actually the Better Fit

The MPS failure-domain concern is real but narrower than commonly understood:

1. **Normal application crashes** (segfaults in user code, uncaught exceptions): The MPS server does **not** crash from a client segfault in most cases. The client process terminates; other clients continue. The MPS server only terminates all clients on **fatal GPU errors** (hardware faults, unrecoverable ECC errors).

2. **MPS provides what you actually need**:
   - Per-client memory limits (prevents cross-tenant OOM)
   - Per-client compute limits (`CUDA_MPS_ACTIVE_THREAD_PERCENTAGE`)
   - True concurrent execution (higher throughput than time-slicing for 8-16 jobs)
   - Better GPU utilization (space partitioning, not time-division)

3. **The residual risk** (fatal GPU error taking down all clients) exists equally in Time-Slicing. MPS doesn't add this risk — it shares it.

### If MPS Is Still Not Acceptable

Consider a hybrid approach:

- **Dedicate 1 physical GPU per tenant** (4 tenants per node) for hard isolation
- Use Kubernetes `requests/limits` on `nvidia.com/gpu: 1` (no sharing)
- Run multiple batch jobs per tenant within that dedicated GPU using in-application CUDA streams or MPS scoped to single-tenant processes
- This trades concurrency density for the isolation guarantee your financial use case demands

### Summary

| Approach | Isolation | Concurrency | Fits Requirements? |
|---|---|---|---|
| Time-Slicing (current plan) | None | High (but serial execution) | **No** — violates isolation requirement |
| MPS | Memory + compute enforced | High (true concurrency) | **Mostly yes** — shared fault domain on fatal GPU errors only |
| Dedicated GPU per tenant | Complete | Limited (4 tenants/node) | **Yes** — but lower density |

**Bottom line: Time-Slicing is an oversubscription mechanism, not an isolation mechanism.** For a financial multi-tenant platform where "a single batch job that OOMs or crashes must not affect other tenants," Time-Slicing is the wrong tool — it provides strictly less isolation than MPS in every dimension.
