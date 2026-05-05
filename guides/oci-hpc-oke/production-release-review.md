# Production Release Review: oci-hpc-oke

## Executive Summary

6 parallel reviews covered Terraform, shell scripts, CI/CD, Dockerfiles, Kubernetes manifests, Go tests, validation logic, and documentation. Total findings:

| Severity | Count |
|----------|-------|
| **CRITICAL** | 19 |
| **HIGH** | 50 |
| **MEDIUM** | 49 |
| **LOW** | 32 |

---

## CRITICAL Findings (Must Fix Before Release)

### Security

1. **Grafana admin password exposed in plaintext output** — `terraform/output.tf:114` uses `nonsensitive()` to strip the sensitive marker, leaking the password in `terraform output`, CI logs, and ORM console.

2. **Bootstrap scripts fetched from GitHub pinned to `main` branch** — `terraform/oke-workers.tf:27-44` downloads cloud-init scripts via `curl` from `raw.githubusercontent.com/.../refs/heads/main/...`. A push to upstream main or GitHub compromise injects code into every new node. Pin to a commit SHA or embed the scripts.

3. **SSH private key stored in Terraform state** — `tls_private_key.stack_key.private_key_openssh` is used in `null_resource` triggers across 5 files (`via-operator-grafana.tf:86`, `via-operator-lustre.tf:13`, etc.), persisted in plaintext in state.

4. **IAM policy grants `manage all-resources`** — `terraform/iam.tf:94-97` gives workload identity full compartment admin rights. Should use least-privilege.

5. **`eval` of IMDS metadata in cloud-init** — `files/oke-ubuntu-cloud-init.sh:119,219` fetches base64 scripts from IMDS and `eval`s them as root with no integrity check. Write to a file and execute instead.

### Correctness

6. **GB200/GB300 shape blocklist only checks `worker_rdma_shape`, not `worker_gpu_shape`** — `terraform/validation.tf:9`. Users can bypass by setting `worker_gpu_shape = "BM.GPU.GB200.4"`.

7. **ClusterQueue name collision** — `manifests/nccl-tests/kueue/BM.GPU.GB200-v2.4.yaml:13` uses the same queue name (`bm-gpu-gb200-4-nccl-tests-queue`) as `BM.GPU.GB200.4.yaml`. One overwrites the other.

8. **`skipUnlessEnv` uses `t.Fatalf` instead of `t.Skipf`** — `test/helpers.go:208`. Tests report FAIL instead of SKIP when env vars aren't set.

### Shell Scripts

9. **No `set -euo pipefail` in mount scripts** — `oke-fss-mount.sh`, `oke-lustre-mount.sh`, `entrypoint.sh` all silently continue after failures.

10. **No argument validation in mount scripts** — Empty args lead to `mount -t nfs ":"  ""` and corrupt `/etc/fstab` entries that can break boot.

11. **NVMe RAID `--force` flag bypasses safety checks** — `oke-nvme-raid.sh:62` silently destroys existing data without confirmation.

### Documentation

12. **Broken manifest link in README** — `README.md:240` links to `BM.GPU4.8.yaml` but the file is `BM.GPU.4.8.yaml`.

13. **Broken file reference in monitoring guide** — `docs/deploying-monitoring-stack-manually.md:542,1033` references `cluster-issuer.yaml` which doesn't exist (actual files are `cluster-issuer-prod.yaml` and `cluster-issuer-staging.yaml`).

### Docker

14. **RCCL Dockerfile: undeclared `MELLANOX_OFED_VERSION`** — `docker/rccl-tests/Dockerfile:76` silently uses `latest`, making builds non-reproducible.

---

## HIGH Findings (Should Fix Before Release)

### Security & Networking Defaults
- **Bastion defaults to `0.0.0.0/0`** — `variables.tf:140,174`
- **Control plane API defaults to public with `0.0.0.0/0`** — `variables.tf:364,369-372`
- **Lustre root squash set to `NONE`** — `lustre.tf:275-281`
- **`hostexec` DaemonSet runs privileged with `hostPID: true` and mounts host `/`** — `files/oci-hpc-oke-utils/templates/hostexec.yaml:34,69-70`
- **APT repo configured with `Trusted: yes` (no GPG verification)** — `oke-ubuntu-cloud-init.sh:159`
- **Command injection risk via `bash -c "exec $SSH_CMD"`** — `oke-bastion-service-session.sh:590,617,642`

### Terraform
- **No remote backend configured** — state is local only (`versions.tf`)
- **Provider versions use `>=` instead of `~>`** — allows breaking major version changes
- **`gavinbunney/kubectl` provider is archived/unmaintained** — `versions.tf:25-28`
- **`total_worker_nodes` counts disabled pools** — inflates count, triggers unnecessary CoreDNS scaling (`oke-cluster.tf:10-15`)
- **`helm_release` uses `force_update = true`** — causes unnecessary pod restarts in production (6 files)
- **Schema references undeclared `worker_*_image_compartment` variables** — `schema.yaml:176,197,214,232`

### CI/CD
- **Terraform binary downloaded without checksum verification** — `ci-plan.yml:99-103`
- **`pip install oci-cli` without version pinning** — all CI workflows
- **`busybox` health-check pods used without tag/digest** — 18 occurrences across CI workflows
- **No health checks for private topologies** — all validation skipped when topology is private

### Manifests
- **MI355X.8 missing Kueue `queue-name` label** — `manifests/rccl-tests/kueue/BM.GPU.MI355X.8.yaml:41`
- **Duplicate/conflicting RBAC across health-check manifests** — 4 files define same ServiceAccount/ClusterRole with different permissions
- **Missing health-check ConfigMaps for B300, GB200-v3, GB300 shapes** — `active-health-checks-nccl-tests.yaml`
- **All worker pods missing resource `requests`** — Kueue manifests only set `limits`, getting best-effort QoS
- **ComputeDomain `numNodes: 0`** in GB200-v3.4 and GB300.4 manifests — likely incorrect

### Go Tests
- **No tests for GPU/RDMA worker pool provisioning** — the core HPC functionality is untested
- **Storage test defer blocks use `t.Fatal`-calling functions** — masks original errors on failure
- **`copyFile` doesn't propagate `out.Close()` write errors** — `helpers.go:319-332`

### Documentation
- **Outdated `mofed-perftest:5.4` Ubuntu 20.04 image** in README and ib_write_bw guide
- **Images from personal test buckets** (`Sudhir-Bucket`, `Sudhir-test-bucket`) and `hpc_limited_availability` namespace may be inaccessible
- **MPI Operator install URL points to `mpi-operator` branch**, not `main`
- **NPD version inconsistency** — monitoring guide installs 2.4.0 then "upgrades" to 2.3.22

---

## MEDIUM Findings (Fix Soon)

### Terraform
- Many variables missing `type`, `description`, and `validation` blocks (especially `cni_type`, `kubernetes_version`, `max_pods_per_node`, `nvme_raid_level`)
- `schema.yaml` version field is `20230304` while stack is `v26.2.0`
- Unused variable `avoid_waiting_for_delete_target`
- Unused data source `oci_containerengine_clusters`
- FSS resources use legacy `.0` index syntax instead of `[0]`
- Missing `sensitive = true` on `cluster_ca_cert` output
- `home_region` referenced in test tfvars but not declared as a variable

### Shell Scripts
- Apt lock wait loops have no timeout (infinite hang possible) in mount scripts
- No mount idempotency — re-running cloud-init retries causes mount failures
- PID file in `/tmp` vulnerable to symlink attacks in bastion script
- LNet peer-timeout/credits values hardcoded in Lustre mount script
- `ip route show default` may return multiple interfaces in Lustre mount script
- fstab entry grep is substring-based — can match partial entries

### CI/CD
- Missing `timeout-minutes` on multiple CI jobs (default is 6 hours)
- Missing `permissions` block on `ci-release.yml`
- Hardcoded authorized user list duplicated across 5 CI locations
- Terraform version `1.5.7` hardcoded in 4 places
- `secrets: inherit` passes all secrets to 16 parallel jobs
- Dependabot config missing `reviewers` and `assignees`

### Go Tests
- `OCI_REGION` env var inconsistency between test helpers and integration tests
- `isValidOCID` is too permissive — accepts `ocid1.....`
- No unit tests for pure helper functions
- `generateKubeconfig` has no retry logic
- `TestPlanSmoke` shares TerraformDir with integration tests — potential lock conflict

### Manifests
- Kueue API version inconsistency: standalone uses v1beta2, health-checks use v1beta1
- NCCL container images differ between standalone and health-check manifests (different registries, different NCCL versions)
- BM.GPU.B300.8 uses 4 worker replicas while all others use 2 — undocumented
- GB300.4 worker spec missing `nodeSelector` for instance type

### Docker
- Node-ordering has hardcoded `gpus=8` — GB200 shapes have 4 GPUs
- Node-ordering Dockerfile uses EOL Python 3.10 on EOL Debian Bullseye
- Unpinned pip packages in node-ordering Dockerfile
- `node_ordering.py` uses bare `except:` clauses

### Documentation
- `ib_write_bw` test missing newer GPU shapes (H200, B200, B300, GB200, GB300, MI300X, MI355X) in `nodeAffinity`
- Missing RCCL test section for `BM.GPU.MI355X.8` in README
- NCCL version in example output (`2.25.1`) doesn't match current images (`2.29.3`)
- AMD Device Metrics Exporter nodeSelector only targets MI300X.8, missing MI355X shapes
- Terraform state resource name likely wrong in monitoring guide (`node-problem_detector`)
- RCCL tests docker README uses outdated ROCm 6.3.2 while manifests use 7.0.2/7.1.1

---

## LOW Findings (Track for Future)

### Terraform
- Hardcoded prepuller images from IAD region-specific OCIR namespace
- `cert-manager` CRDs configured with `keep: false` — uninstall deletes CRDs
- `FSSExport` uses PascalCase while all other resources use snake_case
- Multiple `time_sleep` resources used as fragile synchronization
- No timeouts on OCI resource operations (Lustre, FSS, Bastion, IAM)
- `oke-ons-webhook` only tolerates `nvidia.com/gpu` taint, not `amd.com/gpu`
- `fss_sn_cidr` and `lustre_sn_cidr` schema descriptions say "pods subnet" (copy-paste error)
- No pool_size minimum validation (negative values accepted)

### Shell Scripts
- Shebangs use `#!/bin/bash` but no bash-specific features used
- Duplicated tunnel setup code in bastion script

### CI/CD
- No concurrency control on `ci-release.yml`
- Duplicate setup steps across 4 workflow files (DRY violation)
- `plan-terraform` vs `plan-tf` naming confusion
- Health-check pods created without resource limits

### Manifests
- MPI operator manifest is 659KB with all CRDs inline
- Service account token uses legacy Secret-based approach
- NVIDIA GPU worker pods missing tolerations for `nvidia.com/gpu` taint
- RCCL health-checks use NCCL-specific env vars that may not be recognized

### Docker
- No `.dockerignore` files in any Docker build context
- NCCL Dockerfile build artifacts not cleaned up

### Documentation
- Kubernetes version in example output outdated (`v1.31.1`)
- MPI Operator install source inconsistent between README and health-checks doc
- Node-ordering README uses fragile hardcoded line number reference
- Typo in NPD health-check doc: `RTCCC` instead of `RTTCC`
- PAR URLs for images may expire (time-limited pre-authenticated requests)
- Missing `BM.GPU.GB200-v2.4` from README Images section
- README header inconsistency: `BM.GPU.H200` missing `.8` suffix

---

## Recommended Priority for Production Release

### P0 — Block release
1. Fix GB200/GB300 validation to check both `worker_rdma_shape` AND `worker_gpu_shape`
2. Pin bootstrap script URLs to a commit SHA or embed them
3. Fix ClusterQueue name collision (GB200 vs GB200-v2)
4. Add `sensitive = true` or remove `nonsensitive()` from Grafana password output
5. Add `set -euo pipefail` and argument validation to mount scripts
6. Fix broken README manifest link (`BM.GPU4.8` → `BM.GPU.4.8`)
7. Add missing Kueue queue-name label to MI355X.8

### P1 — Fix shortly after
- Restrict bastion and control plane CIDR defaults
- Scope down IAM policies from `manage all-resources`
- Pin `oci-cli`, `busybox`, and Terraform binary versions in CI
- Add health-check ConfigMaps for B300/GB200-v3/GB300
- Fix `skipUnlessEnv` to use `t.Skipf`
- Replace `eval` with file-based execution in cloud-init
- Update outdated container images in docs
- Fix broken `cluster-issuer.yaml` reference in monitoring guide
- Declare `MELLANOX_OFED_VERSION` ARG in RCCL Dockerfile

### P2 — Track for next release
- Add remote backend configuration
- Replace archived `gavinbunney/kubectl` provider
- Add variable validation blocks
- Consolidate duplicate RBAC manifests
- Add GPU/RDMA provisioning tests
- Update node-ordering base image from EOL Python/Debian
- Add timeout to apt lock wait loops
- Centralize CI authorized user list
