# x86-64 Linux toolchain for building and testing on non-Linux or non-x86 hosts.
#
#   docker build --platform linux/amd64 -t asm-lab .
#   docker run --rm --platform linux/amd64 -v "$PWD":/src asm-lab make test
#
# On Apple Silicon this runs under emulation. Builds and tests work, but gdb
# and strace cannot trace emulated processes, so those tests are skipped.

FROM ubuntu:24.04

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      nasm binutils gcc libc6-dev make python3 \
      bsdextrautils xxd file gdb strace shellcheck \
 && rm -rf /var/lib/apt/lists/*

# Run as an unprivileged user so permission-denied tests behave as on a real system.
RUN useradd --create-home --uid 1001 builder
USER builder
WORKDIR /src
