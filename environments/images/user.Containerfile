#  The user image: an installed refine and the C compiler it links with,
#  on Linux amd64 and arm64.
#
#  Built from a release archive, never by compiling (D1667): the archive's
#  prefix, bin/refine, libexec/landin and lib/landin, is unpacked into
#  /usr/local, and Debian's own gcc and binutils link.  Debian installs the
#  driver as x86_64-linux-gnu-gcc and aarch64-linux-gnu-gcc, names refine
#  asks for (D364), so nothing is linked under another name.  No Cortex-M,
#  RISC-V or Xtensa toolchain is here; the README says how to add one.
#
#  scripts/container_image.py user builds it: it puts the archive in an
#  empty context as landin.tar.gz beside this file.  The release workflow
#  publishes it as ghcr.io/701-dev/landin at a release and only then, so
#  its Debian packages are the ones of the day the release was built.

FROM docker.io/library/debian@sha256:f324c7ff54321e8d9c588493a20244965938ce0aa50bbd1022d38010e9ffc4b1

RUN apt-get update \
 && apt-get install --no-install-recommends --yes \
        gcc \
        libc6-dev \
 && rm -rf /var/lib/apt/lists/*

#  ADD unpacks a local archive; the archive records root as every member's
#  owner and has no top-level directory.
ADD landin.tar.gz /usr/local/

WORKDIR /work

CMD ["refine", "version"]
