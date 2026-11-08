// sdcard.h - an SDHC card in native 4-bit mode for Verilator testbenches,
// backed by an image file (sector n of the card is sector n of the file).
// Adapted from MiSTeryNano's sim/sd_card.cpp (Till Harbaum, GPL-3.0).
// GPL-3.0-or-later.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

class SdCard {
public:
    // persist: write sectors back to the file (otherwise kept in memory)
    bool open(const char *path, bool persist) {
        f_ = fopen(path, persist ? "r+b" : "rb");
        if (!f_) { perror(path); return false; }
        fseek(f_, 0, SEEK_END);
        size_ = ftell(f_);
        persist_ = persist;
        return true;
    }
    uint64_t writes = 0, reads = 0;

    // Call every half clock with the card-side pins.
    void tick(uint8_t sdclk, uint8_t sdcmd, uint8_t sddat, uint8_t &sdcmd_in, uint8_t &sddat_in) {
        if (sdclk == last_clk_) return;
        last_clk_ = sdclk;
        if (!sdclk) return;
        cmd_in_ = ((cmd_in_ << 1) | (sdcmd & 1)) & 0xffffffffffffull;

        if (dat_write_) {
            if (dat_bits_) {
                if (dat_bits_ == 128 * 8 + 16 + 1 + 1 + 4) {
                    if ((sddat & 15) != 15) dat_bits_--;   // start bit
                } else if (dat_bits_ > 1) {
                    if (dat_bits_ > 1 + 4) {
                        int high = dat_bits_ & 1;
                        if (high) *dat_ptr_ = (*dat_ptr_ & 0x0f) | ((sddat & 15) << 4);
                        else { *dat_ptr_ = (*dat_ptr_ & 0xf0) | (sddat & 15); dat_ptr_++; }
                    } else sddat_in = 0;
                    dat_bits_--;
                } else {
                    write_busy_ = 100;
                    uint8_t crc_rx[8];
                    memcpy(crc_rx, sector_ + 512, 8);
                    update_crc(sector_);
                    if (memcmp(sector_ + 512, crc_rx, 8))
                        fprintf(stderr, "sdcard: write CRC error at LBA %u\n", dat_arg_);
                    store(dat_arg_, sector_);
                    writes++;
                    dat_bits_--;
                }
            } else if (write_busy_) {
                write_busy_--;
                sddat_in = write_busy_ ? 0 : 15;
            }
        } else if (dat_bits_) {
            if (read_busy_) { sddat_in = 15; read_busy_--; }
            else {
                if (dat_bits_ == 128 * 8 + 16 + 1 + 1) sddat_in = 0;
                else if (dat_bits_ > 1) {
                    int high = dat_bits_ & 1;
                    if (high) sddat_in = (*dat_ptr_ >> 4) & 15;
                    else sddat_in = *dat_ptr_++ & 15;
                } else sddat_in = 15;
                dat_bits_--;
            }
        }

        if (cmd_ptr_ && cmd_bits_) {
            int bit = 7 - ((cmd_bits_ - 1) & 7);
            sdcmd_in = (*cmd_ptr_ & (0x80 >> bit)) ? 1 : 0;
            if (bit == 7) cmd_ptr_++;
            cmd_bits_--;
        } else {
            sdcmd_in = (cmd_out_ & (1ll << 47)) ? 1 : 0;
            cmd_out_ = (cmd_out_ << 1) | 1;
        }

        if (!(cmd_in_ & (1ll << 47)) && (cmd_in_ & (1ll << 46)) && (cmd_in_ & 1)) {
            uint8_t cmd = (cmd_in_ >> 40) & 0x7f;
            uint32_t arg = (cmd_in_ >> 8) & 0xffffffff;
            uint8_t crc7 = cmd_in_ & 0xfe;
            if (crc7 == crc_of(cmd, arg)) {
                switch (cmd & 0x3f) {
                case 0: break;
                case 8: cmd_out_ = reply(8, arg); break;
                case 55: cmd_out_ = reply(55, 0); break;
                case 41: cmd_out_ = reply(63, 0xc0ff8000); break;   // SDHC, ready
                case 2: cid_[16] = crc_bytes(cid_, 16) | 1; cmd_ptr_ = cid_; cmd_bits_ = 136; break;
                case 3: cmd_out_ = reply(3, 0x0013u << 16); break;
                case 7: cmd_out_ = reply(7, 0); break;
                case 6: cmd_out_ = reply(6, 0); break;
                case 16: cmd_out_ = reply(16, 0); break;
                case 17:
                    cmd_out_ = reply(17, 0);
                    load(arg, sector_);
                    reads++;
                    update_crc(sector_);
                    dat_ptr_ = sector_;
                    dat_write_ = false;
                    dat_bits_ = 128 * 8 + 16 + 1 + 1;
                    read_busy_ = 200;
                    break;
                case 24:
                    cmd_out_ = reply(24, 0);
                    dat_arg_ = arg;
                    dat_ptr_ = sector_;
                    dat_write_ = true;
                    dat_bits_ = 128 * 8 + 16 + 1 + 1 + 4;
                    break;
                default:
                    fprintf(stderr, "sdcard: unexpected CMD%d\n", cmd & 0x3f);
                }
                cmd_in_ = -1;
            }
        }
    }

private:
    FILE *f_ = nullptr;
    long size_ = 0;
    bool persist_ = false;
    struct Over { uint32_t lba; uint8_t d[512]; Over *next; };
    Over *over_ = nullptr;
    int last_clk_ = -1;
    uint8_t sector_[520];
    long long cmd_in_ = -1, cmd_out_ = -1;
    uint8_t *cmd_ptr_ = nullptr;
    int cmd_bits_ = 0;
    uint8_t *dat_ptr_ = nullptr;
    bool dat_write_ = false;
    int dat_bits_ = 0;
    uint32_t dat_arg_ = 0;
    int write_busy_ = 0, read_busy_ = 0;
    uint8_t cid_[17] = {0x3f, 0x02, 'T', 'M', 'S', 'A', '0', '8', 'G', 0x14, 0x39, 0x4a, 0x67, 0xc7, 0x00, 0xe4, 0};

    Over *find(uint32_t lba) {
        for (Over *o = over_; o; o = o->next) if (o->lba == lba) return o;
        return nullptr;
    }
    void load(uint32_t lba, uint8_t *d) {
        if (Over *o = find(lba)) { memcpy(d, o->d, 512); return; }
        memset(d, 0, 512);
        if ((long)lba * 512 + 512 <= size_) {
            fseek(f_, (long)lba * 512, SEEK_SET);
            if (fread(d, 1, 512, f_) != 512) perror("sdcard read");
        }
    }
    void store(uint32_t lba, const uint8_t *d) {
        if (persist_) {
            fseek(f_, (long)lba * 512, SEEK_SET);
            fwrite(d, 1, 512, f_);
            fflush(f_);
            return;
        }
        Over *o = find(lba);
        if (!o) { o = new Over; o->lba = lba; o->next = over_; over_ = o; }
        memcpy(o->d, d, 512);
    }
    static uint8_t crc7_one(uint8_t crc, uint8_t data) {
        const uint8_t g = 0x89;
        crc ^= data;
        for (int i = 0; i < 8; i++) { if (crc & 0x80) crc ^= g; crc <<= 1; }
        return crc;
    }
    static uint16_t crc16_one(uint16_t crc, uint8_t data) {
        crc = (uint8_t)(crc >> 8) | (crc << 8);
        crc ^= data;
        crc ^= (uint8_t)(crc & 0xff) >> 4;
        crc ^= (crc << 8) << 4;
        crc ^= ((crc & 0xff) << 4) << 1;
        return crc;
    }
    static uint8_t crc_of(uint8_t cmd, uint32_t arg) {
        uint8_t c = 0;
        c = crc7_one(c, cmd);
        c = crc7_one(c, arg >> 24); c = crc7_one(c, arg >> 16);
        c = crc7_one(c, arg >> 8); c = crc7_one(c, arg);
        return c;
    }
    static uint8_t crc_bytes(const uint8_t *d, int n) {
        uint8_t c = 0;
        while (n--) c = crc7_one(c, *d++);
        return c;
    }
    static unsigned long long reply(uint8_t cmd, uint32_t arg) {
        unsigned long long r = 0;
        r |= ((unsigned long long)cmd) << 40;
        r |= ((unsigned long long)arg) << 8;
        r |= crc_of(cmd, arg);
        r |= 1;
        return r;
    }
    static void update_crc(uint8_t *s) {
        uint16_t crc[4] = {0, 0, 0, 0};
        uint8_t dbits[4];
        for (int i = 0; i < 512; i++)
            for (int c = 0; c < 4; c++) {
                if ((i & 3) == 0) dbits[c] = 0;
                dbits[c] = (dbits[c] << 2) | ((s[i] & (0x10 << c)) ? 2 : 0) | ((s[i] & (0x01 << c)) ? 1 : 0);
                if ((i & 3) == 3) crc[c] = crc16_one(crc[c], dbits[c]);
            }
        for (int i = 0; i < 8; i++) s[512 + i] = 0;
        for (int i = 0; i < 16; i++) {
            int nib = ((crc[0] & (0x8000 >> i)) ? 1 : 0) + ((crc[1] & (0x8000 >> i)) ? 2 : 0) +
                      ((crc[2] & (0x8000 >> i)) ? 4 : 0) + ((crc[3] & (0x8000 >> i)) ? 8 : 0);
            s[512 + i / 2] |= (i & 1) ? nib : (nib << 4);
        }
    }
};
