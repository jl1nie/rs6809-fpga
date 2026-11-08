# 68000 ROMs: the boot ROM ($FF0000) and the ICE's stub ($FFD000), as
# 16-bit words for $readmemh. Needs binutils for m68k
# (Ubuntu: binutils-m68k-linux-gnu, or m68k-elf-*).
AS := $(shell command -v m68k-linux-gnu-as || command -v m68k-elf-as)
LD := $(shell command -v m68k-linux-gnu-ld || command -v m68k-elf-ld)
OBJCOPY := $(shell command -v m68k-linux-gnu-objcopy || command -v m68k-elf-objcopy)
all: boot68k.hex boot68k_sim.hex stub68k.hex
%.o: %.S
	$(AS) -m68000 --register-prefix-optional -o $@ $<
boot68k.bin: boot.o
	$(LD) -N -Ttext=0xff0000 --no-warn-rwx-segments -o boot.elf $< && $(OBJCOPY) -O binary boot.elf $@
stub68k.bin: stub.o
	$(LD) -N -Ttext=0xffd000 -e entry --no-warn-rwx-segments -o stub.elf $< && $(OBJCOPY) -O binary stub.elf $@
boot68k.hex: boot68k.bin
	python3 ../../tools/bin2hex.py --words $< $@ 16384
stub68k.hex: stub68k.bin
	python3 ../../tools/bin2hex.py --words $< $@ 2048
clean:
	rm -f *.o *.elf *.bin
boot_sim.o: boot.S
	$(AS) -m68000 --register-prefix-optional --defsym SIM=1 -o $@ $<
boot68k_sim.bin: boot_sim.o
	$(LD) -N -Ttext=0xff0000 --no-warn-rwx-segments -o boot_sim.elf $< && $(OBJCOPY) -O binary boot_sim.elf $@
boot68k_sim.hex: boot68k_sim.bin
	python3 ../../tools/bin2hex.py --words $< $@ 16384
