// harness.h - what the testbenches of both machines share: the board's
// UART at bit level, connected to this terminal, to a TCP client (rs6809's
// ICE with --fpga tcp:HOST:PORT) or to a script, and option parsing.
// GPL-3.0-or-later.
#pragma once
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <termios.h>
#include <unistd.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

// 8N1 at `div` clocks per bit.
struct Uart {
    int div;
    // receive (board tx)
    int rx_cnt = 0, rx_bit = -1;
    uint8_t rx_sh = 0;
    // transmit (board rx)
    std::deque<uint8_t> out;
    int tx_cnt = 0, tx_bit = -1;
    uint8_t tx_byte = 0;
    uint8_t line = 1;
    explicit Uart(int d) : div(d) {}

    // Call once per clock. Returns a received byte or -1.
    int tick(uint8_t board_tx) {
        int got = -1;
        if (rx_bit < 0) {
            if (!board_tx) { rx_bit = 0; rx_cnt = div / 2; }
        } else if (--rx_cnt <= 0) {
            rx_cnt = div;
            if (rx_bit == 0) { if (board_tx) rx_bit = -1; else rx_bit = 1; }
            else if (rx_bit <= 8) { rx_sh = (rx_sh >> 1) | (board_tx ? 0x80 : 0); rx_bit++; }
            else { if (board_tx) got = rx_sh; rx_bit = -1; }
        }
        if (tx_bit < 0) {
            line = 1;
            if (!out.empty()) { tx_byte = out.front(); out.pop_front(); tx_bit = 0; tx_cnt = div; line = 0; }
        } else if (--tx_cnt <= 0) {
            tx_cnt = div;
            tx_bit++;
            if (tx_bit <= 8) line = (tx_byte >> (tx_bit - 1)) & 1;
            else if (tx_bit == 9) line = 1;
            else { tx_bit = -1; line = 1; }   // stop bit done (with a one-bit gap)
        }
        return got;
    }
};

// The host side of the serial line.
struct Host {
    int listen_fd = -1, fd = -1;
    bool tty = false;
    bool raw_console = true;      // stdin/stdout when not on TCP
    // scripted console input: (wait for, send) pairs
    std::vector<std::pair<std::string, std::string>> script;
    size_t script_i = 0;
    std::string seen;
    std::string until;
    bool done = false;
    struct termios saved;
    bool term_saved = false;
    bool dle = false;
    FILE *echo = stdout;   // where the console output is shown
    std::deque<uint8_t> pending;
    std::vector<uint8_t> early;
    uint64_t next_key = 0, key_gap = 40000;

    bool listen_tcp(const char *spec) {
        const char *colon = strrchr(spec, ':');
        int port = atoi(colon ? colon + 1 : spec);
        listen_fd = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_port = htons(port);
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(listen_fd, (sockaddr *)&a, sizeof a) || ::listen(listen_fd, 1)) { perror("listen"); return false; }
        fcntl(listen_fd, F_SETFL, O_NONBLOCK);
        fprintf(stderr, "sim: serial port on tcp 127.0.0.1:%d\n", port);
        return true;
    }
    void stdin_raw() {
        if (isatty(0) && tcgetattr(0, &saved) == 0) {
            term_saved = true;
            struct termios t = saved;
            t.c_lflag &= ~(ICANON | ECHO);
            tcsetattr(0, TCSANOW, &t);
        }
        fcntl(0, F_SETFL, O_NONBLOCK);
    }
    ~Host() { if (term_saved) tcsetattr(0, TCSANOW, &saved); }

    // a byte from the board
    void from_board(uint8_t b) {
        if (listen_fd >= 0) {
            if (fd >= 0) (void)!write(fd, &b, 1);
            else if (early.size() < 65536) early.push_back(b);   // until a client connects
            return;
        }
        if (b == 0x10 && !dle) { dle = true; return; }   // DLE DLE: one console 0x10
        dle = false;
        if (echo) { fputc(b, echo); fflush(echo); }
        seen.push_back((char)b);
        if (seen.size() > 8192) seen.erase(0, 4096);
        if (!until.empty() && seen.find(until) != std::string::npos) done = true;
    }
    // bytes to the board, now and then
    void poll(Uart &u, uint64_t now) {
        uint8_t buf[256];
        if (listen_fd >= 0) {
            if (fd < 0) {
                fd = accept(listen_fd, nullptr, nullptr);
                if (fd >= 0) {
                    if (!early.empty()) (void)!write(fd, early.data(), early.size());
                    early.clear();
                    fcntl(fd, F_SETFL, O_NONBLOCK);
                    int one = 1;
                    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
                    fprintf(stderr, "sim: client connected\n");
                }
            }
            if (fd >= 0 && u.out.size() < 64) {
                ssize_t n = read(fd, buf, sizeof buf);
                if (n == 0) { close(fd); fd = -1; fprintf(stderr, "sim: client left\n"); }
                for (ssize_t i = 0; i < n; i++) u.out.push_back(buf[i]);
            }
            return;
        }
        if (!pending.empty()) {
            // typed, one character at a time
            if (u.out.empty() && now >= next_key) {
                u.out.push_back(pending.front());
                pending.pop_front();
                next_key = now + key_gap;
            }
        } else if (script_i < script.size()) {
            if (seen.find(script[script_i].first) != std::string::npos) {
                for (char c : script[script_i].second) pending.push_back((uint8_t)c);
                pending.push_back('\r');
                seen.clear();
                script_i++;
                next_key = now + key_gap;
            }
        } else if (raw_console && u.out.size() < 16) {
            ssize_t n = read(0, buf, sizeof buf);
            for (ssize_t i = 0; i < n; i++) {
                uint8_t c = buf[i] == '\n' ? '\r' : buf[i];
                if (c == 0x10) u.out.push_back(0x10);   // DLE goes twice (dbg_link)
                u.out.push_back(c);
            }
        }
    }
    bool load_script(const char *path) {
        FILE *f = fopen(path, "r");
        if (!f) { perror(path); return false; }
        char line[1024];
        while (fgets(line, sizeof line, f)) {
            std::string s(line);
            while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
            if (s.empty() || s[0] == '#') continue;
            if (s.size() > 1 && s[0] == '\\' && s[1] == '#') s.erase(0, 1);   // \# : a prompt with #
            size_t tab = s.find('\t');
            if (tab == std::string::npos) script.push_back({s, ""});
            else script.push_back({s.substr(0, tab), s.substr(tab + 1)});
        }
        fclose(f);
        return true;
    }
};
