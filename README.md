# rs6809-fpga

FPGA implementations of the machines emulated by [rs6809](https://github.com/jl1nie/rs6809), for the Sipeed Tang Nano 20K (Gowin GW2AR-18).

- 6809: a Multicomp09-compatible machine (cpu09p core) running NitrOS-9 Level 1 and Level 2 from an SD card.
- 68000: a Tiny68K-compatible machine (fx68k core) running CP/M-68K 1.3 and FUZIX 0.5.

rs6809's machine models define the correct behaviour; the hardware follows them, and differences that cannot be removed become hardware-compatible profiles in rs6809.

The plan is in [docs/PLAN.md](docs/PLAN.md) (Japanese). Work starts with phase P0 (the 6809 register specification and a standalone synthesis of cpu09p).

## License

GPL-3.0 (see [LICENSE](LICENSE)), as the CPU cores (cpu09p, fx68k) and the SDRAM and SD card controllers taken from MiSTeryNano are GPL-3.0.
Files from Grant Searle's Multicomp and from multicomp6809's mem_mapper2 carry terms that are not compatible with the GPL, so they are not included; the corresponding parts are written from rs6809's specification.
rs6809 itself stays under the MIT license.
