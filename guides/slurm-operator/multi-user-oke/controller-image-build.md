# Controller Image Build: SSSD/NSS

Date: 2026-05-05

This records the controller image built on `image-builder` so the non-root
`slurmctld` container can use NSS through an SSSD sidecar.

## Result

Built and pushed:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04
```

OCIR digest:

```text
sha256:683d5fd96ceee8e34d8647a29eda69ba8e9220ca762064f951c0183edc522567
```

Local image ID on `image-builder`:

```text
sha256:a9036c7216aab24c1448fbe4daca0bf148cd3af47571cbefb494f8b27f9ce6de
```

## Builder Host

Access:

```bash
ssh image-builder
```

Existing PMIx controller image on the builder:

```text
iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-25.11-ubuntu24.04
sha256:ca9f81da8669ebec4131ebe01600e49120093e0aaeccfa4ee2267593149f7f89 amd64 linux 373988616
```

Existing source Dockerfile:

```text
/home/ubuntu/slurmctld-pmix/Dockerfile
```

That image starts from `ghcr.io/slinkyproject/slurmctld:25.11-ubuntu24.04`
and only adds `libpmix2t64`.

## Dockerfile

The new build context is:

```text
/home/ubuntu/slurmctld-pmix-sssd-nss
```

Dockerfile used:

```dockerfile
# syntax=docker/dockerfile:1
#
# Custom slurmctld image with PMIx plus SSSD/NSS client support.
# SSSD itself is expected to run as a root sidecar in the controller pod.

ARG SLURMCTLD_PMIX_IMAGE=iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-25.11-ubuntu24.04

FROM ${SLURMCTLD_PMIX_IMAGE}

SHELL ["bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
USER root

RUN set -eux; \
    find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -print0 \
      | xargs -0 sed -i \
        -e 's|http://archive.ubuntu.com/ubuntu|https://archive.ubuntu.com/ubuntu|g' \
        -e 's|http://security.ubuntu.com/ubuntu|https://security.ubuntu.com/ubuntu|g'; \
    printf '%s\n' 'Acquire::https::Verify-Peer "false";' > /etc/apt/apt.conf.d/99bootstrap-ca; \
    apt-get -qq update; \
    apt-get -qq -y install --no-install-recommends ca-certificates; \
    rm -f /etc/apt/apt.conf.d/99bootstrap-ca; \
    apt-get -qq update \
    && apt-get -qq -y install --no-install-recommends \
        authselect \
        sssd \
        sssd-ad \
        sssd-ldap \
        libpam-sss \
        libnss-sss \
    && mkdir -p /etc/authselect \
    && authselect select sssd --force \
    && rm -rf /var/lib/apt/lists/*
```

## Build Notes

The builder could reach `archive.ubuntu.com` over HTTPS, but not HTTP:

```text
http://archive.ubuntu.com/ubuntu/ -> connection timed out
https://archive.ubuntu.com/ubuntu/ -> HTTP/1.1 200 OK
```

The PMIx controller base image also lacked CA certificates. The Dockerfile
therefore rewrites apt sources to HTTPS, temporarily disables HTTPS peer
verification only to install `ca-certificates`, removes that temporary apt
setting, and then runs the real package install with normal certificate
verification.

## Build And Push

Build command:

```bash
docker build --progress=plain \
  -t iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04 \
  /home/ubuntu/slurmctld-pmix-sssd-nss
```

Push command:

```bash
docker push iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04
```

Push result:

```text
slurmctld-pmix-sssd-nss-25.11-ubuntu24.04: digest: sha256:683d5fd96ceee8e34d8647a29eda69ba8e9220ca762064f951c0183edc522567 size: 3245
```

## Smoke Test

Command:

```bash
docker run --rm --entrypoint bash \
  iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04 \
  -lc 'set -ex; command -v sssd; dpkg-query -W authselect sssd sssd-ad sssd-ldap libpam-sss libnss-sss ca-certificates; grep -E "^(passwd|group):" /etc/nsswitch.conf; getent passwd slurm; getent group slurm'
```

Result:

```text
/usr/sbin/sssd
authselect      1.5.0-1
ca-certificates 20240203
libnss-sss:amd64        2.9.4-1.1ubuntu6.4
libpam-sss:amd64        2.9.4-1.1ubuntu6.4
sssd    2.9.4-1.1ubuntu6.4
sssd-ad 2.9.4-1.1ubuntu6.4
sssd-ldap       2.9.4-1.1ubuntu6.4
passwd:     files sss systemd
group:      files sss systemd
slurm:x:401:401::/home/slurm:/usr/sbin/nologin
slurm:x:401:
```

## Deployment Status

The image is built, pushed, and deployed to the live cluster.

```text
Helm release: slurm
Namespace: slurm
Revision: 8
```

The deployed values file is:

```text
overlays/values-oke-bm-gpu4-8-fss-sssd-ldap-controller-sssd.yaml
```

The controller pod is `4/4 Running` with:

```text
slurmctld image: iad.ocir.io/idxzjcdglx2s/slinky:slurmctld-pmix-sssd-nss-25.11-ubuntu24.04
sssd sidecar: ghcr.io/slinkyproject/login:25.11-ubuntu24.04
```

The sidecar cannot mount the Secret directly at `/etc/sssd/sssd.conf` because
SSSD rejects Kubernetes Secret ownership/permission details. The deployed
sidecar mounts the Secret at `/etc/sssd-secret`, copies it to
`/etc/sssd/sssd.conf` as `root:root` mode `0600`, recreates the SSSD state
directory layout on the shared emptyDir, resets ownership to `root:root`, and
removes stale SSSD socket files before starting `sssd -i`.
