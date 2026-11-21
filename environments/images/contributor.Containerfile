#  The contributor image: the pinned environment for building and testing
#  the Landin bootstrap compiler, on Linux amd64 and arm64.
#
#  The release workflow builds it for both and publishes it as
#  ghcr.io/701-dev/landin-contributor (D1668); scripts/linux-loop.sh builds
#  it locally for the Rosetta loop.  Native Linux stays the authority: a
#  result inside this image is evidence about this image.  It is pinned as
#  tightly as the archives it installs, a base image by digest and the GNAT
#  and GPRbuild that environments/pins.sh names, checked against the
#  checksums written there; no version is written here, so check.py's pin
#  agreement covers this file by its reading pins.sh.
#
#  The build context is environments/, so that pins.sh can be copied in:
#      docker build -f environments/images/contributor.Containerfile environments

FROM docker.io/library/debian@sha256:f324c7ff54321e8d9c588493a20244965938ce0aa50bbd1022d38010e9ffc4b1

#  Only what the pinned Ada toolchain needs to link a program and fetch itself,
#  plus the deliberately separate C header frontend and GDB. clang-19
#  reads external headers and compiles generated adapters; libc6-dev supplies
#  the Linux C headers and link-time sysroot; python3 and git run the
#  build. qemu-user supplies a GDB remote stub for the local debugger loop:
#  Rosetta does not implement the ptrace register operations required by
#  native GDB. A broad build-essential would install another unselected C
#  toolchain rather than make either role clearer.
RUN apt-get update \
 && apt-get install --no-install-recommends --yes \
        ca-certificates \
        clang-19 \
        curl \
        binutils \
        gdb \
        git \
        libc6-dev \
        python3 \
        qemu-user \
 && rm -rf /var/lib/apt/lists/*

#  Verify before unpacking, every time: landin_install_toolchain refuses an
#  archive that does not match its recorded checksum, which is not a slower
#  build but a different compiler.  TARGETARCH is the platform the builder
#  builds for; the versionless links let the environment below name no
#  version.
ARG TARGETARCH
COPY pins.sh /opt/landin-toolchains/pins.sh
RUN set -eu; \
    case "$TARGETARCH" in \
        amd64) platform=x86_64-linux ;; \
        arm64) platform=aarch64-linux ;; \
        *) echo "landin: no pinned toolchain for the platform '$TARGETARCH'" >&2; exit 2 ;; \
    esac; \
    . /opt/landin-toolchains/pins.sh; \
    landin_install_toolchain /opt/landin-toolchains "$platform"; \
    ln -s "gnat-$LANDIN_GNAT_VERSION" /opt/landin-toolchains/gnat; \
    ln -s "gprbuild-$LANDIN_GPRBUILD_VERSION" /opt/landin-toolchains/gprbuild; \
    /opt/landin-toolchains/gnat/bin/gnat --version | head -1

ENV LANDIN_GNAT_HOME=/opt/landin-toolchains/gnat
ENV LANDIN_GPRBUILD_HOME=/opt/landin-toolchains/gprbuild
ENV PATH=/opt/landin-toolchains/gnat/bin:/opt/landin-toolchains/gprbuild/bin:$PATH

#  A checkout is bind-mounted here, by scripts/linux-loop.sh or by hand.
WORKDIR /work

CMD ["/bin/sh", "-c", "./scripts/toolchain.sh"]
