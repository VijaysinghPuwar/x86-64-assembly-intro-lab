# x86-64 Linux assembly + binary-hardening lab
#
#   make                  build the programs into build/
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

PROGRAMS := $(addprefix $(BUILD)/,hello star add)

DEPS := include/linux.inc Makefile

.PHONY: all clean
.DELETE_ON_ERROR:

all: $(PROGRAMS)

# ---- objects ---------------------------------------------------------------

$(BUILD)/obj/%.o: src/%.asm $(DEPS)
	@mkdir -p $(@D)
	$(NASM) $(NASMFLAGS) $< -o $@

IO := $(BUILD)/obj/io.o

# ---- programs --------------------------------------------------------------

$(BUILD)/hello $(BUILD)/star: $(BUILD)/%: $(BUILD)/obj/%.o $(IO)
	$(LD) $(STATIC_PIE) $^ -o $@

$(BUILD)/add: $(BUILD)/obj/add.o
	$(CC) $(LIBC_PIE) $^ -o $@

clean:
	rm -rf $(BUILD)
