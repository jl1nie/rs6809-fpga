English | [日本語](docs/ja/README.md)

# rs6809-fpga

The machines of [rs6809](https://github.com/jl1nie/rs6809) on a Sipeed Tang Nano 20K (Gowin GW2AR-18), with rs6809's ICE driving the real CPU on the FPGA.

| Machine | CPU | Memory | Devices | Software |
|---|---|---|---|---|
| Multicomp09-compatible | cpu09p (6809), with debug ports | 8 KiB boot ROM, 1 MiB RAM in the SDRAM behind the Multicomp MMU | 6850 ACIA (console), SD controller, 50 Hz timer | NitrOS-9 Level 1 and Level 2 (1 MiB) from the SD card |
| Tiny68K-compatible | fx68k (68000), 8 MHz | 8 MiB RAM in the SDRAM, boot ROM at `$FF0000` | MC68681 DUART (console, second port on GPIO), IDE registers on the SD card | FUZIX 0.5 (kernel built for 8 MiB), CP/M-68K 1.3 |

rs6809's machine models are the specification (`src/machine.rs`, `src/m68k/tiny68k.rs`); the hardware follows them. The plan is in [docs/PLAN.md](docs/PLAN.md) (Japanese), the register tables in [docs/spec-6809.md](docs/spec-6809.md) and [docs/spec-68k.md](docs/spec-68k.md).

## Status

Verified in simulation (Verilator, with models of the SDRAM and of an SD card in 4-bit mode, running the same RTL as the bitstream):

- 6809: CamelForth → NitrOS-9 Level 1 from the kit's SD image → BASIC09, `RUN test` prints `42`.
- 6809: NitrOS-9 Level 2 from rs6809's Level 2 disk (`scripts/build-level2-disk.py`) → `mfree` shows `$FFFFF` and 952k free, the same as rs6809 with `--ram-kb 1024`; `cc1 hello.c` compiles with Microware C on the guest and the program prints `Hello from C: 42` (`make test6809l2`).
- 68000: boot ROM → FUZIX 0.5 kernel built for 8 MiB (`8192KiB total RAM, 8094KiB available to processes`) → `login: root`, shell; CP/M-68K 1.3 from slot 1 → `A>`, `DIR`.
- ICE: rs6809 `--fpga tcp:...` against the simulation: console, stop, step, breakpoint in hardware, NitrOS-9 process table (6809) — see `tests/ice_test.py`.

Open-source place and route of the 6809 machine for the GW2AR-18C (`make check6809`; Yosys and nextpnr-himbaechel): 8,151 LUT4 (39%), 1,976 flip-flops (12%), 7 of 46 block RAMs, maximum 39.6 MHz for the 32.4 MHz clock. The 68000 machine needs sv2v for that check (Yosys cannot read fx68k); MiSTeryNano runs fx68k on this FPGA at 32 MHz with a whole Atari ST around it.

Not yet run on the board: the bitstreams have not been built with Gowin EDA here, and nothing has been tried on a Tang Nano 20K. Expect to check the SDRAM read timing, the BL616 serial pins (69 out, 70 in) and timing closure first (see "First run on the board").

## Layout

```
common/   SDRAM controller, UART, the ICE link (console + debugger on one serial port), SD (MiSTeryNano's sd_rw.v), PLL, pins
m6809/    cpu09p_dbg.vhd (cpu09p with debug ports), Multicomp devices, ICE engine (dbg6809.v), SoC, top, build.tcl
m68k/     fx68k (vendored), DUART, IDE-on-SD bridge, ICE debug unit and engine, SoC, top, build.tcl, rom/ (boot ROM, ICE stub)
sim/      Verilator testbenches, SDRAM model, SD card model, serial port on stdio or TCP
tools/    patch-cpu09p.py, bin2hex.py, mksd68k.py (68000 SD card image), oss-check.sh
tests/    console scripts, ice_test.py
```

## Building

Tools: Gowin EDA (Education edition is enough, `gw_sh`), Python 3, binutils for m68k (`apt install binutils-m68k-linux-gnu`) for the 68000 ROMs. For the simulation: Verilator 5, GHDL 4 and a C++ compiler.

```sh
# 6809: the boot ROM is the NitrOS-9 kit's 6809M.bin (not redistributed; rs6809's setup.sh fetches it)
make rom6809 ROM=../rs6809/artifacts/nitros9/6809M.bin
gw_sh m6809/build.tcl          # impl/pnr/rs6809fpga_6809.fs

# 68000
make rom68k
gw_sh m68k/build.tcl           # impl/pnr/rs6809fpga_68k.fs

openFPGALoader -b tangnano20k impl/pnr/rs6809fpga_6809.fs        # SRAM (or -f for flash)
```

`make check6809` / `make check68k` synthesize and place both designs with the open-source tools (Yosys, nextpnr-himbaechel) to see the resources and timing without Gowin EDA.

## SD cards

6809: write the NitrOS-9 image from sector 0, as rs6809 uses it (Level 1 from the kit, or the Level 2 disk built in rs6809 with `python3 scripts/build-level2-disk.py`):

```sh
sudo dd if=../rs6809/artifacts/nitros9/multicomp09_sd.img of=/dev/sdX bs=1M conv=fsync     # Level 1
sudo dd if=../rs6809/artifacts/level2/multicomp09-level2.img of=/dev/sdX bs=1M conv=fsync  # Level 2
```

Both boot from the same ROM: type `NITROS9` at CamelForth.

68000: the card has four slots of 512 MiB; the boot ROM asks which one (default 0 after 2 s). `tools/mksd68k.py` builds the image:

```sh
# in rs6809: the FUZIX kernel for 8 MiB, and the CP/M BIOS whose TPA ends at $800000
sh scripts/build-fuzix-tiny68k.sh --tn20k        # artifacts/fuzix68k-tn20k/disk.img
python3 scripts/build-cpm68k-bios.py --tn20k     # examples/cpm68k/bios-tn20k.sr
# here
python3 tools/mksd68k.py sd68k.img \
  0=fuzix:../rs6809/artifacts/fuzix68k-tn20k/disk.img \
  1=cpm:../rs6809/artifacts/cpm68k/a.img:../rs6809/artifacts/cpm68k/dist/DISK8/CPM15000.SR,../rs6809/examples/cpm68k/bios-tn20k.sr
sudo dd if=sd68k.img of=/dev/sdX bs=1M conv=sparse,fsync
```

Disk writes go to the card. Keep a copy of the images to write back.

## Using it

The console is the Tang Nano 20K's USB serial port (the BL616's second interface, `/dev/ttyUSB1` on Linux), 115200 8N1. A terminal program works as it is; the one difference is that a byte 0x10 (Ctrl-P) is sent and shown doubled, because the same port also carries the debugger.

S2 resets the machine (RAM and the card keep their contents). LEDs: 6809 — running, stopped by the ICE, SD busy, MMU on, ROM off, console output; 68000 — running, ROM overlay, IDE busy, in the ICE stub, stepping, console output.

### ICE on the real CPU

rs6809's ICE (browser UI and VS Code/DAP) can use the CPU on the FPGA instead of its emulator:

```sh
cd ../rs6809
./target/release/rs6809 --fpga /dev/ttyUSB1 --ice                       # 6809, NitrOS-9 monitor
./target/release/rs6809 --cpu 68000 --fpga /dev/ttyUSB1 --os fuzix \
    --symbols artifacts/fuzix68k-tn20k/fuzix.sym --ice                    # 68000, FUZIX monitor
# then http://127.0.0.1:6809/ ; --dap for VS Code as usual
```

- Between stops the CPU runs at full speed on the FPGA. Breakpoints (8) and watchpoints (4, address ranges, read/write) are in hardware; conditions, hit counts and logpoints are evaluated by the ICE when the hardware stops.
- Stop, step, step over (a breakpoint on the return address), registers and memory (read and write), the disassembly, symbols, C variables and the OS views (processes, modules, memory) work as with the emulator.
- Source-line steps, step out, OS call breaks and the OS call record need every instruction; the ICE then steps the hardware one instruction at a time (slow, a few hundred instructions per second at 115200 baud).
- Not available on the board: stepping back (recording), saving and loading states, and the cycle counter (the ICE shows time instead). Reset restarts the machine from its ROM and stops at the first instruction.
- While stepping, interrupts are held off; while the CPU is stopped, the 6809's timer and the DUART's counter/timer stand still.

How it works: the 6809's cpu09p got ports for its registers, a breakpoint on the address of the next instruction and register writes (tools/patch-cpu09p.py). While halted, the debug unit reads and writes memory over the machine's bus. fx68k is used unchanged: a level-7 interrupt (stop, watchpoint), an ILLEGAL shown in place of a breakpoint's instruction, or the trace exception after a step takes the CPU into a stub monitor in a debug window that only exists while it is in use (`m68k/rom/stub.S`); the stub keeps the registers in a mailbox the host reads and writes.

### Simulation

```sh
make rom6809 && make sim
cd sim/build
./sim_mc09 -s ../../../rs6809/artifacts/nitros9/multicomp09_sd.img              # console on this terminal
./sim_mc09 -s IMAGE -S ../../tests/nitros9-basic09.tsv -u " 42"                 # scripted, stops at 42
./sim_t68k -s sd68k.img -S ../../tests/fuzix-boot.tsv -u "Welcome to FUZIX"
./sim_mc09 -s IMAGE -t 6820 &    # serial port on TCP: rs6809 --fpga tcp:127.0.0.1:6820 --ice
python3 ../../tests/ice_test.py 6809 ./sim_mc09 IMAGE ../../../rs6809/target/release/rs6809 --script ../../tests/nitros9-boot.tsv
```

The simulated UART runs at 1 Mbaud (32 clocks per bit) and the 68000 boot ROM hardly waits for the slot key; otherwise the RTL is the one in the bitstream.

### First run on the board

1. Program the 6809 bitstream with no card: CamelForth must print its banner on the USB serial port (check the pins and the BL616 firmware if not).
2. Insert the NitrOS-9 card, type `NITROS9`. If reads fail or data is wrong, look at the SDRAM read capture (`common/sdram.v`, phase 2 of `S_WAIT`) first.
3. Connect the ICE: `rs6809 --fpga /dev/ttyUSB1 --ice`.

## License

GPL-3.0 (see [LICENSE](LICENSE)): the CPU cores (cpu09p, fx68k) and MiSTeryNano's SD controller (`sd_rw.v`, `sdcmd_ctrl.v`) are GPL-3.0, and the SD card model in `sim/sdcard.h` is adapted from MiSTeryNano's. Grant Searle's Multicomp files and Neal Crook's mem_mapper2 are not GPL-compatible and are not used; the Multicomp devices were written from rs6809's specification. rs6809 itself stays under the MIT license.
