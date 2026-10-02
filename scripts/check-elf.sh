#!/usr/bin/env bash
# check-elf.sh - fail if an x86-64 ELF executable lacks the hardening
# properties its build policy promises. Uses only readelf (binutils).
#
#   usage: check-elf.sh static-pie|dynamic-pie FILE...
#
# static-pie   syscall-only programs: PIE, no interpreter, no dynamic
#              relocations (nothing would apply them), non-exec stack.
# dynamic-pie  libc programs: PIE, interpreter, full RELRO, non-exec stack.
#
# Exit status: 0 if every check passed, 1 if any failed, 2 on bad usage.

set -euo pipefail

usage() { echo "usage: $0 static-pie|dynamic-pie FILE..." >&2; exit 2; }

[[ $# -ge 2 ]] || usage
policy=$1
shift
[[ $policy == static-pie || $policy == dynamic-pie ]] || usage

status=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; status=1; }

# Print the flag letters (e.g. "RW", "RE", "RWE") of every program header of
# the given type. readelf separates flags with spaces ("R E"), so join the
# columns between MemSiz (field 6) and Align (last field).
segment_flags() {
    awk -v type="$1" '$1 == type { f = ""; for (i = 7; i < NF; i++) f = f $i; print f }' <<<"$phdrs"
}

for file in "$@"; do
    echo "$file ($policy)"
    if ! header=$(readelf -hW "$file" 2>&1); then
        fail "not a readable ELF file: $header"
        continue
    fi
    if ! phdrs=$(readelf -lW "$file" 2>&1) || ! dynamic=$(readelf -dW "$file" 2>&1) \
        || ! relocs=$(readelf -rW "$file" 2>&1); then
        fail "readelf could not parse the file"
        continue
    fi

    if grep -q 'Class:.*ELF64' <<<"$header" && grep -q 'Machine:.*X86-64' <<<"$header"; then
        ok "ELF64 x86-64"
    else
        fail "expected ELF64 x86-64"
    fi

    # A PIE is ET_DYN with DF_1_PIE; a shared library is ET_DYN without it.
    if grep -q 'Type:.*DYN' <<<"$header" && grep -q 'FLAGS_1.*PIE' <<<"$dynamic"; then
        ok "position-independent executable (ET_DYN + DF_1_PIE)"
    else
        fail "not a PIE: $(grep 'Type:' <<<"$header" | xargs)"
    fi

    stack=$(segment_flags GNU_STACK)
    if [[ $stack == RW ]]; then
        ok "non-executable stack (PT_GNU_STACK $stack)"
    elif [[ -z $stack ]]; then
        fail "no PT_GNU_STACK header: stack permissions left to kernel defaults"
    else
        fail "stack flags are $stack, expected RW"
    fi

    rwx=$(segment_flags LOAD | grep -c 'W.*E' || true)
    if [[ $rwx -eq 0 ]]; then
        ok "no writable+executable LOAD segment"
    else
        fail "$rwx LOAD segment(s) are both writable and executable"
    fi

    if grep -q 'TEXTREL' <<<"$dynamic"; then
        fail "text relocations present (DT_TEXTREL)"
    else
        ok "no text relocations"
    fi

    has_interp=$(grep -c '^ *INTERP' <<<"$phdrs" || true)
    if [[ $policy == static-pie ]]; then
        if [[ $has_interp -eq 0 ]]; then
            ok "no program interpreter (static)"
        else
            fail "has a program interpreter, expected a static PIE"
        fi
        if grep -q 'There are no relocations' <<<"$relocs"; then
            ok "no dynamic relocations (none needed without a loader)"
        else
            fail "has relocations, but no dynamic loader exists to apply them"
        fi
        if [[ -z $(segment_flags GNU_RELRO) ]]; then
            ok "no PT_GNU_RELRO (would be inert without a loader)"
        else
            fail "PT_GNU_RELRO present, but no loader exists to apply it"
        fi
    else
        if [[ $has_interp -eq 1 ]]; then
            ok "program interpreter present (dynamic)"
        else
            fail "no program interpreter, expected a dynamically linked PIE"
        fi
        if [[ -n $(segment_flags GNU_RELRO) ]] && grep -qE 'BIND_NOW|FLAGS_1.* NOW' <<<"$dynamic"; then
            ok "full RELRO (PT_GNU_RELRO + BIND_NOW)"
        else
            fail "missing full RELRO (needs PT_GNU_RELRO and BIND_NOW)"
        fi
    fi
done

exit "$status"
