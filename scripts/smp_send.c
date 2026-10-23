/*
 * zfs-ha: raw SMP frame sender via Linux bsg (SCSI transport subprotocol).
 *
 * Usage: smp_send <bsg_dev> <function_hex> <payload_hex...>
 *   smp_send /dev/bsg/expander-2:7 0x12 0000000000000000   (REPORT PHY SATA phy 0)
 *
 * Builds a SAS-2+ SMP request frame:
 *   byte 0: 0x40 (frame type)
 *   byte 1: function
 *   byte 2: allocated response length (dwords)
 *   byte 3: request length (dwords, excluding 4-byte header and 4-byte CRC)
 *   bytes 4..: payload
 *   last 4 bytes: CRC (zeroed = no CRC; expanders accept this)
 *
 * Response lengths are per-function (SAS SPL spec). Unknown functions default to 1032.
 *
 * Build: gcc -O2 -o smp_send smp_send.c
 * Requires: /dev/bsg/expander-* node (created by the kernel SAS transport layer)
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/bsg.h>
#include <scsi/sg.h>

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <bsg_dev> <fn_hex> <payload_hex...>\n", argv[0]); return 2; }
    int fn = (int)strtol(argv[2], NULL, 16);

    unsigned char payload[1024];
    int plen = 0;
    for (int a = 3; a < argc; a++) {
        char *s = argv[a];
        for (size_t i = 0; s[i] && s[i+1]; i += 2) {
            int hi = hexval(s[i]), lo = hexval(s[i+1]);
            if (hi < 0 || lo < 0) { fprintf(stderr, "bad hex in %s\n", s); return 2; }
            payload[plen++] = (unsigned char)((hi << 4) | lo);
        }
    }
    if (plen % 4) { fprintf(stderr, "payload must be dword-aligned\n"); return 2; }

    int resp_len;
    switch (fn) {
        case 0x00: resp_len = 40; break;    /* REPORT GENERAL */
        case 0x01: resp_len = 20; break;    /* REPORT MANUFACTURER */
        case 0x10: resp_len = 1032; break;  /* DISCOVER */
        case 0x11: resp_len = 36; break;    /* REPORT PHY ERROR LOG */
        case 0x12: resp_len = 72; break;    /* REPORT PHY SATA */
        case 0x13: resp_len = 36; break;    /* REPORT ROUTE INFO */
        case 0x14: resp_len = 36; break;    /* REPORT PHY EVENT */
        case 0x16: resp_len = 8; break;     /* SET PHY SATA */
        case 0x20: resp_len = 1032; break;  /* DISCOVER LIST */
        case 0x21: resp_len = 40; break;    /* REPORT PHY EVENT LIST */
        case 0x22: resp_len = 1032; break;  /* REPORT EXPANDER ROUTE TABLE LIST */
        case 0x80: case 0x81: case 0x90: case 0x91: resp_len = 36; break;
        default: resp_len = 1032;
    }

    unsigned char req[4 + 1024 + 4];
    int req_len = 4 + plen + 4;
    req[0] = 0x40;
    req[1] = (unsigned char)fn;
    req[2] = (unsigned char)((resp_len - 8) / 4);
    req[3] = (unsigned char)((req_len - 8) / 4);
    memcpy(req + 4, payload, plen);
    memset(req + 4 + plen, 0, 4);

    static unsigned char respbuf[1032];
    unsigned char sense[64];
    struct sg_io_v4 hdr;
    memset(&hdr, 0, sizeof(hdr));
    memset(sense, 0, sizeof(sense));
    hdr.guard = 'Q';
    hdr.protocol = BSG_PROTOCOL_SCSI;
    hdr.subprotocol = BSG_SUB_PROTOCOL_SCSI_TRANSPORT;
    hdr.request_len = req_len;  /* D8: computed, not fixed 16 */
    hdr.request = (uintptr_t)req;
    hdr.dout_xfer_len = req_len;
    hdr.dout_xferp = (uintptr_t)req;
    hdr.din_xfer_len = resp_len;
    hdr.din_xferp = (uintptr_t)respbuf;
    hdr.max_response_len = 64;
    hdr.response = (uintptr_t)sense;
    hdr.timeout = 20000;

    int fd = open(argv[1], O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    int res = ioctl(fd, SG_IO, &hdr);
    if (res) { perror("SG_IO"); close(fd); return 1; }
    close(fd);
    if (hdr.driver_status || hdr.transport_status || hdr.device_status) {
        fprintf(stderr, "ERR driver=%u transport=%u device=%u\n",
                hdr.driver_status, hdr.transport_status, hdr.device_status);
        return 1;
    }
    int n = resp_len - hdr.din_resid;
    if (n < 4) {
        fprintf(stderr, "short response %d (resp_len=%d din_resid=%d)\n", n, resp_len, hdr.din_resid);
        return 1;
    }
    /* D8: function_result affects exit code - refusals are not success */
    if (respbuf[2] != 0x00) {
        fprintf(stderr, "SMP function result=0x%02x (refused)\n", respbuf[2]);
        return 1;
    }
    printf("function_result=0x%02x\n", respbuf[2]);
    for (int i = 0; i < n && i < 128; i++) printf("%02x%s", respbuf[i], (i%16==15)?"\n":" ");
    printf("\n");
    return 0;
}
