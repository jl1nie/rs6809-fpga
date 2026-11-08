#!/usr/bin/env python3
"""mksd68k.py: an SD card image for the 68000 machine (Tiny68K, 8 MiB).

The card has four slots of 512 MiB (slot n starts at sector n * $100000);
the boot ROM asks which one to boot and the IDE bridge shows the slot as
the disk from its first sector. A slot holds:

  fuzix:DISK.IMG
      FUZIX's disk.img (artifacts/fuzix68k-tn20k/disk.img from rs6809's
      scripts/build-fuzix-tiny68k.sh --tn20k): partition table, loader at
      sector 1 (the boot ROM loads it at $15000), kernel, file systems.
  cpm:DISK.IMG:SYSTEM.SR[,BIOS.SR...]
      a CP/M-68K disk A: (rs6809's artifacts/cpm68k/a.img), and the system
      (CPM15000.SR and examples/cpm68k/bios-tn20k.sr) as a boot image at
      sector $8000 of the slot: a header ("RS68BOOT", load address, entry,
      sector count) and the memory from $15000, started at $15000.

Disks are stored as they are: the board's disks have their bytes swapped,
and so does the boot image (the ROM reads words from the IDE register).

usage: mksd68k.py OUT.img SLOT=KIND:... [SLOT=KIND:...]
  e.g. mksd68k.py sd68k.img 0=fuzix:disk.img 1=cpm:a.img:CPM15000.SR,bios-tn20k.sr
Write it with: dd if=sd68k.img of=/dev/sdX bs=1M conv=sparse,fsync
"""
import struct
import sys

SLOT_SECTORS = 0x100000
BOOT_AT = 0x8000
LOAD = 0x15000


def swab(b):
    if len(b) & 1:
        b += b"\0"
    out = bytearray(len(b))
    out[0::2] = b[1::2]
    out[1::2] = b[0::2]
    return bytes(out)


def srec(path):
    mem = {}
    for line in open(path):
        line = line.strip()
        if len(line) < 4 or line[0] != "S" or line[1] not in "123":
            continue
        n = int(line[2:4], 16)
        alen = {"1": 2, "2": 3, "3": 4}[line[1]]
        raw = bytes.fromhex(line[4:4 + 2 * n])
        addr = int.from_bytes(raw[:alen], "big")
        for i, b in enumerate(raw[alen:-1]):
            mem[addr + i] = b
    return mem


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out = open(sys.argv[1], "wb")
    for spec in sys.argv[2:]:
        slot, rest = spec.split("=", 1)
        base = int(slot) * SLOT_SECTORS * 512
        kind, *parts = rest.split(":")
        disk = open(parts[0], "rb").read()
        if len(disk) > BOOT_AT * 512 and kind == "cpm":
            sys.exit(f"{parts[0]}: larger than {BOOT_AT * 512} bytes")
        out.seek(base)
        out.write(disk)
        if kind == "cpm":
            mem = {}
            for p in parts[1].split(","):
                mem.update(srec(p))
            end = max(mem) + 1
            # 4 KiB of zeros after the data: the BIOS's .bss (S-records do
            # not carry it, and the SDRAM holds whatever it held)
            image = bytes(mem.get(a, 0) for a in range(LOAD, end + 4096))
            nsec = (len(image) + 511) // 512
            image = image.ljust(nsec * 512, b"\0")
            header = b"RS68BOOT" + struct.pack(">III", LOAD, LOAD, nsec)
            out.seek(base + BOOT_AT * 512)
            out.write(swab(header.ljust(512, b"\0")))
            out.write(swab(image))
            print(f"slot {slot}: CP/M disk {len(disk)} bytes, system ${LOAD:X}-${end - 1:X} ({nsec} sectors)")
        elif kind == "fuzix":
            print(f"slot {slot}: FUZIX disk {len(disk)} bytes")
        else:
            sys.exit(f"unknown kind {kind} (fuzix or cpm)")
    out.close()


if __name__ == "__main__":
    main()
