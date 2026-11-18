#include <stdio.h>
#include <string.h>
#include "crypto.h"

int main(void)
{
    /* DES known-answer vector, with key bits reversed for the RFB API. */
    const unsigned char key[8] = {0xc8, 0x2c, 0xea, 0x9e, 0xd9, 0x3d, 0xfb, 0x8f};
    const unsigned char challenge[8] = {0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef};
    const unsigned char expected[8] = {0x85, 0xe8, 0x13, 0x54, 0x0f, 0x0a, 0xb4, 0x05};
    unsigned char response[16];
    int response_len = 0;
    if (!encrypt_rfbdes(response, &response_len, key, challenge, sizeof(challenge)) ||
        response_len != sizeof(expected) || memcmp(response, expected, sizeof(expected)) != 0) {
        fputs("LibVNCClient DES authentication failed without external OpenSSL modules\n", stderr);
        return 1;
    }
    puts("LibVNCClient DES authentication works without external OpenSSL modules");
    return 0;
}
