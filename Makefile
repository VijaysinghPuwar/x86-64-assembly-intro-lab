# x86-64 Linux assembly + binary-hardening lab
#
#   make                  build the programs into build/
#   make check-hardening  verify ELF security properties of the programs
#   make security-demo    build the deliberately insecure demos and compare them
#   make clean

NASM    ?= nasm
LD      ?= ld
ifeq ($(origin CC),default)
CC      := gcc
endif
PYTHON  ?= python3
BUILD   ?= build

NASMFLAGS := -f elf64 -w+all -Werror -I include/

# Linker guards shared by every hardened binary. Warnings are errors, an
# executable stack or an RWX segment fails the link, and so does any text
# relocation (code that is not position independent).
GUARDS := --fatal-warnings --error-execstack --error-rwx-segments -z text

# Syscall-only programs: static PIE. ET_DYN with no interpreter, so the kernel
# loads it at a random base. -z norelro: RELRO is applied by the dynamic
# loader, which these binaries do not have, so a PT_GNU_RELRO header would
# only make tools like checksec report protection that never happens.
STATIC_PIE := -pie --no-dynamic-linker -z norelro $(GUARDS)

# libc programs: PIE with full RELRO (GOT read-only after startup).
comma := ,
space := $() $()
LIBC_PIE := -pie -Wl,$(subst $(space),$(comma),$(GUARDS)),-z,relro,-z,now

PROGRAMS := $(addprefix $(BUILD)/,hello star add asm-hexdump)

DEMOS := $(addprefix $(BUILD)/security/,execstack-bad execstack-good \
           whereami-nopie whereami-pie)

DEPS := include/linux.inc Makefile

.PHONY: all check-hardening security-demo clean
.DELETE_ON_ERROR:

all: $(PROGRAMS)

# ---- objects ---------------------------------------------------------------

$(BUILD)/obj/%.o: src/%.asm $(DEPS)
	@mkdir -p $(@D)
	$(NASM) $(NASMFLAGS) $< -o $@

$(BUILD)/obj/security/%.o: security/%.asm $(DEPS)
	@mkdir -p $(@D)
	$(NASM) $(NASMFLAGS) $< -o $@

$(BUILD)/obj/security/execstack-bad.o: security/execstack.asm $(DEPS)
	@mkdir -p $(@D)
	$(NASM) $(NASMFLAGS) -DOMIT_STACK_NOTE $< -o $@

$(BUILD)/obj/security/whereami-abs.o: security/whereami.asm $(DEPS)
	@mkdir -p $(@D)
	$(NASM) $(NASMFLAGS) -DABSOLUTE $< -o $@

IO := $(BUILD)/obj/io.o

# ---- programs --------------------------------------------------------------

$(BUILD)/hello $(BUILD)/star: $(BUILD)/%: $(BUILD)/obj/%.o $(IO)
	$(LD) $(STATIC_PIE) $^ -o $@

$(BUILD)/asm-hexdump: $(BUILD)/obj/hexdump.o $(IO)
	$(LD) $(STATIC_PIE) $^ -o $@

$(BUILD)/add: $(BUILD)/obj/add.o
	$(CC) $(LIBC_PIE) $^ -o $@

# ---- security demos (some are insecure on purpose) ---------------------------

# Linked exactly like the original lab's add: default gcc flags, no guards.
# The linker warning printed here is the point of the demo.
$(BUILD)/security/execstack-bad: $(BUILD)/obj/security/execstack-bad.o $(IO)
	@mkdir -p $(@D)
	@echo "note: the executable-stack warning below is expected (insecure demo)"
	$(CC) $^ -o $@

$(BUILD)/security/execstack-good: $(BUILD)/obj/security/execstack.o $(IO)
	@mkdir -p $(@D)
	$(CC) $(LIBC_PIE) $^ -o $@

$(BUILD)/security/whereami-nopie: $(BUILD)/obj/security/whereami-abs.o $(IO)
	@mkdir -p $(@D)
	$(LD) $^ -o $@

$(BUILD)/security/whereami-pie: $(BUILD)/obj/security/whereami.o $(IO)
	@mkdir -p $(@D)
	$(LD) $(STATIC_PIE) $^ -o $@

# Expected to FAIL: absolute addressing cannot be linked as PIE. Used by tests.
$(BUILD)/security/whereami-abs-pie: $(BUILD)/obj/security/whereami-abs.o $(IO)
	@mkdir -p $(@D)
	$(LD) $(STATIC_PIE) $^ -o $@

# ---- checks ----------------------------------------------------------------

check-hardening: all
	scripts/check-elf.sh static-pie $(BUILD)/hello $(BUILD)/star $(BUILD)/asm-hexdump
	scripts/check-elf.sh dynamic-pie $(BUILD)/add

security-demo: $(DEMOS)
	@scripts/security-demo.sh $(BUILD)

clean:
	rm -rf $(BUILD)
