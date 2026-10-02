#!/usr/bin/env bash
# security-demo.sh - side-by-side comparison of the insecure and hardened demo
# binaries in security/. Run via `make security-demo`.
#
#   usage: security-demo.sh BUILD_DIR

set -euo pipefail

build=${1:?usage: $0 BUILD_DIR}
sec=$build/security

if grep -qE 'rosetta|qemu' /proc/self/maps; then
    echo "warning: running under emulation; runtime columns below do not reflect a real kernel"
    echo
fi

stack_header() { readelf -lW "$1" | awk '$1 == "GNU_STACK" { f = ""; for (i = 7; i < NF; i++) f = f $i; print f }'; }
stack_runtime() { "$1" | awk '/\[stack\]/ { print $2 }'; }
elf_type() { readelf -hW "$1" | awk '/Type:/ { print $2 }'; }
start_addr() { "$1" | awk '{ print $NF }'; }

echo "1. Executable stack: same code, with and without .note.GNU-stack"
printf '   %-16s %-20s %s\n' binary "PT_GNU_STACK" "[stack] at runtime"
for b in execstack-bad execstack-good; do
    printf '   %-16s %-20s %s\n' "$b" "$(stack_header "$sec/$b")" "$(stack_runtime "$sec/$b")"
done
echo

echo "2. PIE and ASLR: address of _start over three runs"
for b in whereami-nopie whereami-pie; do
    printf '   %-16s %-5s %s %s %s\n' "$b" "$(elf_type "$sec/$b")" \
        "$(start_addr "$sec/$b")" "$(start_addr "$sec/$b")" "$(start_addr "$sec/$b")"
done
echo

echo "3. Hardening gate on the insecure builds (failures expected)"
"$(dirname "$0")/check-elf.sh" dynamic-pie "$sec/execstack-bad" | sed 's/^/   /' || true
"$(dirname "$0")/check-elf.sh" static-pie "$sec/whereami-nopie" | sed 's/^/   /' || true
