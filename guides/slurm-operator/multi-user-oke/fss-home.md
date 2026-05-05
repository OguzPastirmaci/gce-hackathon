# OCI FSS Home Directories

Use OCI File Storage Service (FSS) as the shared POSIX home filesystem. Mount it
at `/home` in:

- every login pod;
- every compute NodeSet that may run jobs for users.

The path must be consistent. A job submitted from `/home/alice` should see the
same path on the compute node.

## FSS Layout

Create one directory per user:

```console
/home
/home/alice
/home/bob
```

Recommended permissions:

```bash
chown alice:alice /home/alice
chmod 700 /home/alice

chown bob:bob /home/bob
chmod 700 /home/bob

chmod 711 /home
```

`chmod 700` prevents normal users from reading each other's home directories.
`chmod 711 /home` lets users traverse to their own known home path while
preventing directory listing of all home names.

This only works correctly when UID and GID values are stable. LDAP, FreeIPA, or
Active Directory is the cleanest way to keep UID/GID values consistent. If you
do not use LDAP, maintain a single authoritative UID/GID registry.

## Direct NFS Values

Add the same volume to login pods and all active NodeSets.

```yaml
loginsets:
  slinky:
    enabled: true
    login:
      volumeMounts:
        - name: home
          mountPath: /home
    podSpec:
      volumes:
        - name: home
          nfs:
            server: <fss-mount-target-ip-or-dns>
            path: /slurm-home

nodesets:
  gpu-b4:
    slurmd:
      volumeMounts:
        - name: home
          mountPath: /home
    podSpec:
      volumes:
        - name: home
          nfs:
            server: <fss-mount-target-ip-or-dns>
            path: /slurm-home
```

Repeat the `slurmd.volumeMounts` and `podSpec.volumes` block for each active
NodeSet, for example `gpu-a10`, `gpu-b4`, or any additional partition-specific
NodeSet.

## PVC-Based Values

If you provision FSS through the OCI FSS CSI driver, mount a `ReadWriteMany`
PVC instead of a direct `nfs` volume:

```yaml
loginsets:
  slinky:
    login:
      volumeMounts:
        - name: home
          mountPath: /home
    podSpec:
      volumes:
        - name: home
          persistentVolumeClaim:
            claimName: slurm-home

nodesets:
  gpu-b4:
    slurmd:
      volumeMounts:
        - name: home
          mountPath: /home
    podSpec:
      volumes:
        - name: home
          persistentVolumeClaim:
            claimName: slurm-home
```

## Security Notes

FSS is NFS. POSIX modes protect users from other normal users, but not from root
inside privileged clients. For multi-user Slurm:

- keep login pods unprivileged;
- do not grant users sudo in login pods;
- do not run user jobs as root;
- restrict FSS export access to the OKE worker node subnet or NSG;
- enable root squash/export identity remapping where appropriate;
- use Kerberos-backed FSS exports if the environment requires stronger NFS
  authentication.

For scratch, checkpoints, or high-throughput training data, use a separate
scratch filesystem. Keep `/home` for source, scripts, small outputs, SSH keys,
and user configuration.

