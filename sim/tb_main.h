// tb_main.h - the testbench main loop, shared by both machines (TOP is
// the Verilated model).
//   -s IMAGE     SD card image (writes stay in memory; -w writes them back)
//   -t PORT      serial port on TCP 127.0.0.1:PORT (for rs6809 --fpga)
//   -S SCRIPT    console script: "wait for<TAB>send" lines
//   -u TEXT      stop when the console shows TEXT
//   -c CYCLES    stop after this many clocks
// GPL-3.0-or-later.
#include <verilated.h>
#include <csignal>
#include "harness.h"
#include "sdcard.h"

static volatile bool g_stop = false;
static void on_sig(int) { g_stop = true; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *image = nullptr, *tcp = nullptr, *script = nullptr, *until = nullptr;
    bool persist = false;
    unsigned long long max_cycles = 0;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-s" && i + 1 < argc) image = argv[++i];
        else if (a == "-w") persist = true;
        else if (a == "-t" && i + 1 < argc) tcp = argv[++i];
        else if (a == "-S" && i + 1 < argc) script = argv[++i];
        else if (a == "-u" && i + 1 < argc) until = argv[++i];
        else if (a == "-c" && i + 1 < argc) max_cycles = strtoull(argv[++i], nullptr, 0);
    }
    signal(SIGINT, on_sig);
    TOP *top = new TOP;
    SdCard sd;
    if (image && !sd.open(image, persist)) return 1;
    Uart uart(UART_DIV_SIM);
    Host host;
    if (tcp && !host.listen_tcp(tcp)) return 1;
    if (script && !host.load_script(script)) return 1;
    if (until) host.until = until;
    if (!tcp && !script) host.stdin_raw();
    if (script) host.raw_console = false;

    top->clk = 0;
    top->por_n = 0;
    top->reset_btn = 0;
    top->uart_rx = 1;
    top->sdcmd_in = 1;
    top->sddat_in = 15;
    uint64_t cyc = 0;
    while (!Verilated::gotFinish() && !g_stop && !host.done) {
        if (cyc == 20) top->por_n = 1;
        top->clk = 1;
        top->eval();
        uint8_t ci = top->sdcmd_in, di = top->sddat_in;
        if (image) sd.tick(top->sdclk, top->sdcmd, top->sddat, ci, di);
        top->sdcmd_in = ci;
        top->sddat_in = di;
        top->clk = 0;
        top->eval();
        if (image) sd.tick(top->sdclk, top->sdcmd, top->sddat, ci, di);
        top->sdcmd_in = ci;
        top->sddat_in = di;
        int b = uart.tick(top->uart_tx);
        if (b >= 0) host.from_board((uint8_t)b);
        top->uart_rx = uart.line;
        if ((cyc & 1023) == 0) host.poll(uart, cyc);
        cyc++;
        if (max_cycles && cyc >= max_cycles) break;
    }
    fprintf(stderr, "\nsim: %llu clocks, SD reads %llu writes %llu\n", (unsigned long long)cyc,
            (unsigned long long)sd.reads, (unsigned long long)sd.writes);
    top->final();
    delete top;
    return host.done ? 0 : (max_cycles && cyc >= max_cycles ? 2 : 0);
}
