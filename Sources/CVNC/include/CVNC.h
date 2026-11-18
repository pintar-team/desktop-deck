#pragma once
#include <stdint.h>
#define DECK_CLIPBOARD_LIMIT 1000000
typedef struct DeckVNC DeckVNC;
DeckVNC *deck_vnc_create(void);
int deck_vnc_connect(DeckVNC *, const char *host, int port, const char *password, int ssh_otp);
int deck_vnc_poll(DeckVNC *);
int deck_vnc_received_bytes(DeckVNC *, uint64_t *total);
int deck_vnc_width(DeckVNC *);
int deck_vnc_height(DeckVNC *);
const void *deck_vnc_pixels(DeckVNC *);
int deck_vnc_dirty(DeckVNC *);
int deck_vnc_auth_failed(DeckVNC *);
int deck_vnc_pointer(DeckVNC *, int x, int y, int mask);
int deck_vnc_key(DeckVNC *, uint32_t key, int down);
uint32_t deck_vnc_keysym(uint32_t unicode_scalar);
int deck_vnc_quality(DeckVNC *, int quality, int compression);
int deck_vnc_resize(DeckVNC *, int width, int height);
int deck_vnc_cancel_resize(DeckVNC *);
int deck_vnc_refresh(DeckVNC *);
int deck_vnc_send_clipboard(DeckVNC *, const char *utf8, int length, const void *latin1, int latin1_length);
int deck_vnc_take_clipboard(DeckVNC *, const void **bytes, int *length, int *utf8);
void deck_vnc_free(DeckVNC *);
void deck_vnc_interrupt(DeckVNC *);
