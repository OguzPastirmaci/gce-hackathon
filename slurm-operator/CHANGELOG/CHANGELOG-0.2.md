## v0.2.1

### Added

### Fixed

- Fixed Slurm chart incorrect `imagePullPolicy` being used.
- Fixed Slurm chart not using token job `resources` constraints.
- Fixed Slurm chart not using token job `securityContext` constraints.
- Fixed mariadb subchart `innodb_*` configurations for Slurm.
- Fixed `ArchiveDir` not being a valid value.
- Fixed `slurm.extraSlurmdbdConf` not being used.
- Fixed slurmrestd failing to start when accounting is disabled.
- Fixed responsiveness of container scripts responding to termination signals.

### Changed

- Changed slurm-operator chart images tags, omit when equal to the default.

### Removed

## v0.2.0

### Added

- Added container image labels.
- Added `NodeSet.PersistentVolumeClaimRetentionPolicy.WhenScaled`
- Added out-of-order scale-in for NodeSet pods.
- Added NodeSet pod scale-in to consider running Slurm jobs.
- Added support for Slurm node names that do not have to match their pod name.

### Fixed

- Fixed HTTP/2 enabled by default. [CVE-2023-44487] [CVE-2023-39325]
- Fixed Slurm helm chart using incorrect imagePullPolicy in values file.
- Fixed accidental Slurm node undrain when drained by another source (e.g.
  Prolog, Epilog, HealthCheck).
- Fixed Slurm helm chart interaction with OwnerReferencesPermissionEnforcement
  admission controller plugin being enabled.
- Fixed unprivileged slurmrestd pod from using unshare functionality.
- Fixed Slurm helm chart projected volume overlapping paths warning.
- Fixed Slurm helm chart missing `authcred.imagePullPolicy` in values file.
- Fixed Slurm helm chart ability to disable slurm-exporter subchart.

### Changed

- Changed Slurm images to new schema.
- Changed Slurm image version to 24.11.
- Changed token job to only use authcred container images.
- Changed slurm-operator-webhook to use its own image.
- Changed NodeSet controller to scale pods similar to StatefulSet, rather than
  DaemonSet.
- Changed `NodeSet.Status` fields.
- Changed NodeSet controller specific annotations prefix.
- Changed NodeSet pod hostname to `compute.nodeset[].name`.
- Changed default to `mariadb.persistence.enabled=true`.

### Removed

- Removed `NodeSet.Spec.UpdateStrategy.RollingUpdate.Partition` option.
- Removed `NodeSet.Spec.UpdateStrategy.RollingUpdate.Paused` option.
- Removed pruning of defunct Slurm nodes and pods.
- Removed `compute.nodeset[].minReadySeconds` from Slurm helm chart values file.

<!-- Links -->

[cve-2023-39325]: https://github.com/advisories/GHSA-4374-p667-p6c8
[cve-2023-44487]: https://github.com/advisories/GHSA-qppj-fm5r-hxr3
