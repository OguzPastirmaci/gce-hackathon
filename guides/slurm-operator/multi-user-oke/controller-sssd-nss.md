# Controller SSSD/NSS Integration

Date: 2026-05-05

This note records what was found in
`/Users/opastirm/Documents/Repos/slinky-containers` and how to make
operator-side `scontrol` in the controller resolve LDAP users instead of
showing numeric UIDs.

## Current Finding

The `25.11/ubuntu24.04` `slurmctld` image does not include SSSD/NSS support.
The stage installs Slurm controller packages and `socat`, then copies only the
`slurmctld` and fake-systemd supervisor programs.

By contrast, the `slurmd` stage installs:

```text
authselect sssd sssd-ad sssd-ldap libpam-sss libnss-sss
```

and copies:

```text
files/etc/supervisor/conf.d/sssd.conf
```

The `login` stage does the same SSSD package install and supervisor wiring.

That explains the live test result:

- `getent passwd alice` works in login and worker pods;
- jobs run as `alice`;
- `sacct` records `alice/project-a`;
- `scontrol` from Alice's login session resolves `alice(10001)`;
- `scontrol` inside the controller shows `10001(10001)`.

The controller pod also runs with a non-root pod/container security context in
the operator:

```text
RunAsNonRoot=true
RunAsUser=401
RunAsGroup=401
```

SSSD should run as root, so starting SSSD inside the same controller container
would require weakening the controller container security context. Avoid that
unless there is a strong reason.

## Build Status

Built and pushed a controller image with PMIx plus SSSD/NSS client support:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04
```

OCIR digest:

```text
sha256:683d5fd96ceee8e34d8647a29eda69ba8e9220ca762064f951c0183edc522567
```

Build, smoke-test, and deployment details are recorded in
`controller-image-build.md`. The image is deployed in Helm release revision
`8`.

## Recommended Design

Use two pieces:

1. Build a custom `slurmctld` image that contains NSS client support:
   `libnss-sss`, SSSD client config files, and `nsswitch.conf` configured for
   `sss`.
2. Run SSSD as a root sidecar in the controller pod, sharing SSSD runtime
   socket/cache directories with the non-root `slurmctld` container.

This keeps `slurmctld` non-root and gives all commands executed inside the
controller container, such as `scontrol`, access to LDAP-backed name service.

## Container Change

In `slinky-containers/schedmd/slurm/25.11/ubuntu24.04/Dockerfile`, add a new
target derived from `slurmctld`:

```dockerfile
FROM slurmctld AS slurmctld-sssd-nss

SHELL ["bash", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

USER root

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked <<EOR
set -xeuo pipefail
apt-get -qq update
apt-get -qq -y install --no-install-recommends \
  authselect sssd sssd-ad sssd-ldap libnss-sss
mkdir -p /etc/authselect
authselect select sssd --force
EOR
```

The main `slurmctld` container will not run the SSSD daemon in the recommended
sidecar design, but installing the same SSSD/NSS packages as the login image
keeps the authselect and NSS layout consistent.

If you prefer to keep one target, the same package/config block can be added
directly to the existing `slurmctld` stage. A separate target is cleaner for
testing because it does not change the default upstream controller image.

Build shape:

```bash
cd /Users/opastirm/Documents/Repos/slinky-containers/schedmd/slurm
export BAKE_IMPORTS="--file ./docker-bake.hcl --file ./25.11/ubuntu24.04/slurm.hcl"
docker bake $BAKE_IMPORTS slurmctld --print
docker bake $BAKE_IMPORTS slurmctld
```

If using the new `slurmctld-sssd-nss` target, add a matching bake target or
build it directly with `docker buildx build --target slurmctld-sssd-nss`.

## Controller Pod Values

The current chart can inject extra controller pod volumes and containers via
`controller.podSpec`, and can add mounts to the `slurmctld` container via
`controller.slurmctld.volumeMounts`.

The concrete design overlay is:

```text
overlays/values-controller-sssd-sidecar.yaml
```

Example values shape:

```yaml
controller:
  slurmctld:
    image:
      repository: iad.ocir.io/idxzjcdglx2s/slinky
      tag: slurmctld-pmix-sssd-nss-25.11-ubuntu24.04
    volumeMounts:
      - name: sssd-state
        mountPath: /var/lib/sss
      - name: sssd-run
        mountPath: /run/sssd

  podSpec:
    securityContext:
      runAsNonRoot: false
      fsGroup: 401
    volumes:
      - name: sssd-conf
        secret:
          secretName: site-sssd-ldap-test-conf
          items:
            - key: sssd.conf
              path: sssd.conf
              mode: 0600
      - name: sssd-state
        emptyDir: {}
      - name: sssd-run
        emptyDir: {}
    containers:
      - name: sssd
        image: ghcr.io/slinkyproject/login:25.11-ubuntu24.04
        command:
          - /bin/bash
          - -lc
        args:
          - |
            set -euo pipefail
            install -d -m 0700 /etc/sssd
            install -o root -g root -m 0600 /etc/sssd-secret/sssd.conf /etc/sssd/sssd.conf
            install -d -m 0755 /var/lib/sss
            install -d -m 0700 /var/lib/sss/db /var/lib/sss/keytabs /var/lib/sss/secrets
            install -d -m 0751 /var/lib/sss/deskprofile
            install -d -m 0755 /var/lib/sss/gpo_cache /var/lib/sss/pipes /var/lib/sss/pubconf /var/lib/sss/pubconf/krb5.include.d /run/sssd
            install -d -m 0750 /var/lib/sss/pipes/private /var/log/sssd
            install -d -m 0775 /var/lib/sss/mc
            chown -R root:root /var/lib/sss /run/sssd /var/log/sssd
            chmod 0755 /var/lib/sss /var/lib/sss/gpo_cache /var/lib/sss/pipes /var/lib/sss/pubconf /var/lib/sss/pubconf/krb5.include.d /run/sssd
            chmod 0700 /var/lib/sss/db /var/lib/sss/keytabs /var/lib/sss/secrets
            chmod 0751 /var/lib/sss/deskprofile
            chmod 0750 /var/lib/sss/pipes/private /var/log/sssd
            chmod 0775 /var/lib/sss/mc
            rm -f /var/lib/sss/pipes/nss /var/lib/sss/pipes/pam /var/lib/sss/pipes/ssh
            rm -f /var/lib/sss/pipes/private/* /run/sssd.pid /run/sssd/*.pid
            exec /usr/sbin/sssd -i
        securityContext:
          runAsNonRoot: false
          runAsUser: 0
          runAsGroup: 0
        volumeMounts:
          - name: sssd-conf
            mountPath: /etc/sssd-secret
            readOnly: true
          - name: sssd-state
            mountPath: /var/lib/sss
          - name: sssd-run
            mountPath: /run/sssd
```

The `slurmctld` container does not need to run SSSD. It needs:

- `libnss-sss`;
- `passwd` and `group` NSS configured to include `sss`;
- access to the SSSD sockets/cache created by the sidecar.

The sidecar needs:

- SSSD binaries;
- `/etc/sssd/sssd.conf`, copied from the Secret as `root:root` mode `0600`;
- root privileges;
- the shared `/var/lib/sss` and `/run/sssd` volumes.

The most important shared path is `/var/lib/sss`. The SSSD NSS responder
creates its public pipe under this tree, and `libnss-sss` in the `slurmctld`
container connects to that pipe when `getent`, `id`, or Slurm's UID/GID
formatting asks NSS for a username.

Do not apply the sidecar overlay against the stock controller image and expect
name resolution to work. The sidecar may start, but `slurmctld` still lacks the
NSS client library and `nsswitch.conf` configuration needed to use it.

Live validation confirmed the overlay lands in the `Controller` CR and runs:

- `spec.template.spec.containers` includes an `sssd` sidecar;
- `spec.template.spec.volumes` includes `sssd-conf`, `sssd-state`, `sssd-run`,
  and `sssd-log`;
- `spec.slurmctld.volumeMounts` includes `/var/lib/sss` and `/run/sssd`.
- the final pod is `4/4 Running` on Helm release revision `8`.

## Production Operator Improvement

For a clean upstreamable implementation, add first-class controller SSSD
support to the operator/chart instead of relying on ad hoc `podSpec` injection:

- add `controller.sssd.enabled` or wire top-level `sssd.secretRef` into
  Controller;
- mount the SSSD Secret and shared runtime volumes in the controller builder;
- add an SSSD sidecar with root container security context;
- add the SSSD config hash to controller pod annotations so Secret changes roll
  the controller pod;
- document that controller SSSD is for operator-side NSS/name resolution, not
  for user login.

## Validation

After deploying the custom image and sidecar, run:

```bash
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- getent passwd alice
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- id alice
kubectl -n slurm exec slurm-controller-0 -c slurmctld -- scontrol show job <active-job-id> | grep UserId
```

Expected:

```text
alice:*:10001:10001:Alice Slurm:/home/alice:/bin/bash
uid=10001(alice) gid=10001(alice) groups=10001(alice),11001(project-a)
UserId=alice(10001) GroupId=alice(10001)
```

The live validation job was job `6`; it ran with `--gres=gpu:1`, `scontrol`
showed `UserId=alice(10001)`, and `sacct` recorded
`alice|project-a|COMPLETED`.
