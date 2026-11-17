#include "CVNC.h"

/* Compile the pinned upstream's public-domain converter without copying its
   international keysym table or changing the vendor checkout. */
#define keysym2ucs deck_upstream_keysym2ucs
#define ucs2keysym deck_upstream_ucs2keysym
#define ucs2combining deck_upstream_ucs2combining
#include "../../Vendor/TurboVNC/unix/vncviewer/keysym2ucs.c"

uint32_t deck_vnc_keysym(uint32_t scalar) {
    if (scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) return 0;
    return scalar < 256 ? scalar : deck_upstream_ucs2keysym(scalar);
}
