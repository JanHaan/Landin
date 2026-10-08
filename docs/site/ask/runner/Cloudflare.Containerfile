# The preparer substitutes the repository's digest-pinned Debian base.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
RUN apt-get update \
 && apt-get install --no-install-recommends --yes \
    ca-certificates curl binutils libc6-dev python3 util-linux \
 && rm -rf /var/lib/apt/lists/*
COPY pins.sh /opt/landin/pins.sh
RUN set -eu; . /opt/landin/pins.sh; \
    landin_install_toolchain /opt/landin-toolchains x86_64-linux; \
    ln -s "gnat-$LANDIN_GNAT_VERSION" /opt/landin-toolchains/gnat
# Package the checked compiler, never its Ada sources or a compiler build.
COPY refine compiler.sha256 container_entry.py cloudflare_server.py /opt/landin/
COPY core /opt/landin/core
RUN cd /opt/landin && sha256sum -c compiler.sha256 && chmod 755 refine \
 && mkdir -p /work && chown 65532:65532 /work && chmod 700 /work \
 && chmod -R go-w /opt/landin /opt/landin-toolchains
ENV LANDIN_GNAT_HOME=/opt/landin-toolchains/gnat
ENV PATH=/opt/landin-toolchains/gnat/bin:/usr/bin:/bin
WORKDIR /work
EXPOSE 8080
# A trusted controller retains root; compiler/program children explicitly
# drop all privileges. Only the microVM is public-code execution territory.
USER 0:0
ENTRYPOINT ["/usr/bin/python3", "/opt/landin/cloudflare_server.py"]
