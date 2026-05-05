# syntax=docker/dockerfile:1
#
# Rebuild Slurm 25.11 with NVML development headers, then reinstall the rebuilt
# Slurm packages into the existing OKE BM.GPU4.8 slurmd RDMA/PMIx image.
#
# The final image keeps the already validated RDMA, PMIx, CUDA/NCCL, SSSD, and
# SSH tooling from the current custom worker image, but adds Slurm's gpu_nvml
# plugin so `AutoDetect=nvml` can be tested.

ARG SLURM_VERSION=25.11.4
ARG SLURM_VERSION_MICRO=1
ARG SLURM_DIR=slurm
ARG PARENT_IMAGE=ubuntu:24.04
ARG BASE_SLURMD_IMAGE=iad.ocir.io/idxzjcdglx2s/slinky:slurmd-rdma-pmix-25.11-ubuntu24.04

################################################################################
FROM alpine:latest AS slurm-src

ARG SLURM_VERSION
ARG SLURM_VERSION_MICRO
ARG SLURM_DIR
ARG SLURM_TAR="slurm-${SLURM_VERSION//./-}-${SLURM_VERSION_MICRO}.tar.gz"

WORKDIR /workspace/

RUN apk add -q --no-cache tar

ADD https://github.com/SchedMD/slurm/archive/refs/tags/${SLURM_TAR} ${SLURM_TAR}

RUN \
  mkdir -p ${SLURM_DIR} && \
  tar --strip-components=1 -zxvf ${SLURM_TAR} -C ${SLURM_DIR} && \
  rm ${SLURM_TAR}

################################################################################
FROM ${PARENT_IMAGE} AS build

SHELL ["bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
ARG SLURM_VERSION
ENV SLURM_VERSION=${SLURM_VERSION}
ARG SLURM_DIR

USER root
WORKDIR /tmp/

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked <<EOR
set -xeuo pipefail

# The image-builder environment has reliable HTTPS egress. Bootstrap CA certs
# before normal apt operations so Ubuntu package downloads do not stall on HTTP.
find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -print0 \
  | xargs -0 sed -i \
    -e 's|http://archive.ubuntu.com/ubuntu|https://archive.ubuntu.com/ubuntu|g' \
    -e 's|http://security.ubuntu.com/ubuntu|https://security.ubuntu.com/ubuntu|g'
printf '%s\n' 'Acquire::https::Verify-Peer "false";' > /etc/apt/apt.conf.d/99bootstrap-ca
apt-get -qq update
apt-get -qq -y install --no-install-recommends ca-certificates
rm -f /etc/apt/apt.conf.d/99bootstrap-ca

apt-get -qq update
apt-get -qq -y upgrade
apt-get -qq -y install --no-install-recommends \
  build-essential apt-utils fakeroot devscripts equivs libnvidia-ml-dev
EOR

COPY --from=slurm-src /workspace/${SLURM_DIR} ${SLURM_DIR}

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked <<EOR
set -xeuo pipefail
mk-build-deps -ir --tool='apt-get -y -o Debug::pkgProblemResolver=yes --no-install-recommends' ${SLURM_DIR}/debian/control >/dev/null
( cd ${SLURM_DIR} && debuild -b -uc -us )
EOR

################################################################################
FROM ${BASE_SLURMD_IMAGE}

SHELL ["bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

USER root
WORKDIR /tmp/slurm-nvml-debs/

COPY --from=build /tmp/slurm-smd*.deb /tmp/slurm-nvml-debs/

RUN set -xeuo pipefail; \
    dpkg -i \
      ./slurm-smd_[0-9]*.deb \
      ./slurm-smd-client_[0-9]*.deb \
      ./slurm-smd-dev_[0-9]*.deb \
      ./slurm-smd-doc_[0-9]*.deb \
      ./slurm-smd-libnss-slurm_[0-9]*.deb \
      ./slurm-smd-libpam-slurm-adopt_[0-9]*.deb \
      ./slurm-smd-libpmi2-0_[0-9]*.deb \
      ./slurm-smd-slurmd_[0-9]*.deb; \
    rm -rf /tmp/slurm-nvml-debs; \
    test -f /usr/lib/x86_64-linux-gnu/slurm/gpu_nvml.so

WORKDIR /
