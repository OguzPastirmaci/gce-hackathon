# Slurm Accounting

Linux identity and Slurm accounting are separate.

The login pod can know that `alice` is UID `10001`, but SlurmDBD still needs an
association for `alice` before accounting, fairshare, QOS, and limits are
useful.

## Enable SlurmDBD

The base OKE guide includes MariaDB setup. After MariaDB is ready, enable
accounting in the Slurm values:

```yaml
accounting:
  enabled: true
  storageConfig:
    host: mariadb
    port: 3306
    database: slurm_acct_db
    username: slurm
    passwordKeyRef:
      name: mariadb-password
      key: password
```

Also enable accounting enforcement if the cluster should reject jobs from users
without valid associations or enforce limits:

```yaml
controller:
  extraConfMap:
    AccountingStorageEnforce: "associations,limits,qos"
```

Merge this with any existing `controller.extraConfMap` values such as
`GresTypes`, `ReturnToService`, or `PropagateResourceLimitsExcept`.

## Create Accounts and Users

Run `sacctmgr` from the controller pod:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  sacctmgr add account project-a Description="Project A" Organization=example -i

kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  sacctmgr add user name=alice account=project-a defaultaccount=project-a -i
```

Verify:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- \
  sacctmgr show assoc format=cluster,account,user,qos
```

## Group-to-Account Sync

For production, automate this mapping:

- identity group `project-a` -> Slurm account `project-a`;
- members of `project-a` -> Slurm users associated with account `project-a`;
- default account set from a primary project group;
- optional QOS set from group membership.

The sync process can be:

- a scheduled Kubernetes CronJob;
- a GitOps CI job;
- a custom controller;
- an external identity-management workflow.

The important property is idempotency. Re-running the sync should converge
SlurmDBD to the desired associations without breaking active users.

## Test Accounting

SSH as a real user:

```bash
ssh alice@<slurm-login-load-balancer>
```

Submit a job:

```bash
sbatch --account=project-a --wrap="hostname"
squeue -u alice
sacct -u alice
```

Expected behavior:

- `squeue` shows `alice` as the user;
- `sacct` shows completed jobs for `alice`;
- jobs fail at submission if `alice` has no valid association and enforcement
  is enabled.
