# 68000 machine (Tiny68K-compatible, 8 MiB): registers

The specification is rs6809's `src/m68k/tiny68k.rs` (with `--ram-kb 8192`); the hardware is in `m68k/`. Differences from the emulator are marked **FPGA**.

## Memory map

| Address | Device |
|---|---|
| `$000000`-`$7FFFFF` | 8 MiB RAM (SDRAM) |
| `$000000`-`$00FFFF` | after reset, reads come from the boot ROM until the first instruction fetched from `$FF0000`-`$FFFFFF` |
| `$800000`-`$FEFFFF` | nothing: reads `$FFFF`, writes ignored (no bus error), as rs6809 with 8 MiB |
| `$FF0000`-`$FF3FFF` | boot ROM (16 KiB block RAM; m68k/rom/boot.S) — **FPGA** only |
| `$FFD000`-`$FFDFFF` | the ICE's debug window, only while the CPU is in the stub — **FPGA** only |
| `$FFE000`-`$FFEFFF` | IDE registers, register = (address & 31) >> 1 |
| `$FFE800`-`$FFE805` | the slot's first card sector (32 bits, big-endian), card ready (bit 0 of `$FFE805`) — **FPGA** only |
| `$FFF000`-`$FFF01F` | MC68681 DUART, odd addresses, register = (address >> 1) & 15 |

## DUART

Channel A is the console on the USB serial port, channel B a second serial port on header pins 71 (out) and 72 (in), at 115200 baud whatever CSR says. Level 2 interrupt, vector from IVR (reset `$0F`).

| Reg | Read | Write |
|---|---|---|
| 0 / 8 | MR1/MR2 (pointer moves to MR2) | MR1/MR2 |
| 1 / 9 | SR: bit 0 RxRDY, bit 2 TxRDY, bit 3 TxEMT | CSR (ignored) |
| 2 / 10 | `$FF` | CR: Rx/Tx enable/disable, `001` reset MR pointer, `010` reset receiver |
| 3 / 11 | RHR | THR |
| 4 | `$FF` | ACR; bit 6 sets timer mode and reloads |
| 5 | ISR: bit 0 TxRDYA, 1 RxRDYA, 3 counter ready, 4 TxRDYB, 5 RxRDYB | IMR |
| 6 / 7 | `$FF` | CTUR / CTLR |
| 12 | IVR | IVR |
| 14 | start counter | OPR set bits |
| 15 | stop counter (clears counter ready) | OPR clear bits |

Counter/timer: X1 = 3.6864 MHz; it counts X1/16 unless ACR bits 6-4 = 6 (X1). Timer mode (ACR bit 6): counter ready every 2 × preload counts, free running. Counter mode: once, from "start counter". This is rs6809's behaviour (ACR = 0 counts X1/16, where the chip would count IP2).
**FPGA**: the X1 clock is a phase accumulator on the 32.4 MHz clock (exact on average); transmit FIFOs of 16 bytes drained at 115200 baud, receive FIFOs of 64. The counter stands still while the ICE has the CPU stopped.

## IDE

| Reg | Read | Write |
|---|---|---|
| 0 | data: 16-bit word = (byte n+1 << 8) \| byte n; a byte access takes one byte | data |
| 1 | error (`$04` aborted) | features |
| 2-5 | sector count, LBA 7-0, 15-8, 23-16 | |
| 6 | drive/head: bit 6 LBA, bit 4 device 1 (absent: status 0), bits 3-0 LBA 27-24 | |
| 7, 14 | status: BSY `$80`, DRDY `$40`, DRQ `$08`, ERR `$01` | 7: command |

Commands: `$20`/`$21` READ SECTORS, `$30`/`$31` WRITE SECTORS, `$EC` IDENTIFY DEVICE, `$EF`, `$E0`-`$E7`, `$91`, `$1x` accepted; others abort. A command without LBA mode aborts.
**FPGA**: the card is slow, so BSY (`$80`) shows while a sector moves between the card and the buffer (before DRQ on reads, after the 512th byte on writes). IDENTIFY reports 2^21 sectors. LBA = slot start + register LBA. The emulator's range check against the disk size is not made.

## Boot

No Tiny68K monitor: the boot ROM (m68k/rom/boot.S) asks for the slot (0-3, 2 s, default 0), sets `$FFE800`, and then either loads the boot image at sector `$8000` of the slot (header `RS68BOOT`, load address, entry, sector count; tools/mksd68k.py) or, without one, loads sector 1 to `$15000` and starts there (as the monitor's CP/M boot loader does; FUZIX's loader). rs6809's `--boot-sector` does the second.

## CPU and interrupts

fx68k (Jorge Cwik, GPL-3.0), unchanged, at 8 MHz (PHI1/PHI2 every 4 clocks of 32.4 MHz). SDRAM accesses fit in a bus cycle. VPA, BERR, BR, BGACK and HALT are not used. IPL: 2 for the DUART; 7 is the ICE's (acknowledged with vector `$FF`, whose fetch the debug unit answers with the stub's address).
