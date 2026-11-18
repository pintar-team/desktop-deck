#include "CVNC.h"
#include <rfb/rfbclient.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdarg.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
struct DeckVNC { rfbClient *client; char *password; void *pixels; int dirty; int auth_failed; int interrupt_fd; int cancelled; pthread_mutex_t mutex; char *clipboard; int clipboard_length; int clipboard_utf8; int clipboard_dirty; int clipboard_caps_sent; };
static _Thread_local DeckVNC *connecting;
static void quiet(const char *format, ...) {
    if(connecting && (strstr(format,"authentication failed") || strstr(format,"Unknown authentication") || strstr(format,"Unknown sub authentication"))) connecting->auth_failed=1;
}
static void configure_logs(void) { rfbClientLog=quiet; rfbClientErr=quiet; }
static pthread_once_t logs_once=PTHREAD_ONCE_INIT;
static DeckVNC *owner(rfbClient *c) { return rfbClientGetClientData(c,(void*)owner); }
static char *password(rfbClient *c) { return strdup(owner(c)->password ?: ""); }
static rfbBool allocate(rfbClient *c) {
    if(c->width<1 || c->height<1 || c->width>16384 || c->height>16384 ||
       (size_t)c->width*c->height>33554432) return FALSE;
    free(c->frameBuffer); c->frameBuffer=calloc((size_t)c->width*c->height,4);
    owner(c)->pixels=c->frameBuffer;
    owner(c)->dirty=0; return c->frameBuffer!=NULL;
}
static void updated(rfbClient *c,int x,int y,int w,int h) { owner(c)->dirty=1; }
static void received_clipboard(rfbClient *c,const char *text,int length,int utf8) {
    if(length<0 || length>DECK_CLIPBOARD_LIMIT) return;
    char *copy=malloc((size_t)length+1);if(!copy) return;
    memcpy(copy,text,length);copy[length]=0;
    DeckVNC *v=owner(c);free(v->clipboard);v->clipboard=copy;
    v->clipboard_length=length;v->clipboard_utf8=utf8;v->clipboard_dirty=1;
}
static void clipboard_latin1(rfbClient *c,const char *text,int length) {received_clipboard(c,text,length,0);}
static void clipboard_utf8(rfbClient *c,const char *text,int length) {received_clipboard(c,text,length,1);}
DeckVNC *deck_vnc_create(void) {
    pthread_once(&logs_once,configure_logs);DeckVNC *v=calloc(1,sizeof(DeckVNC));
    if(v) {v->interrupt_fd=-1;pthread_mutex_init(&v->mutex,NULL);}return v;
}
int deck_vnc_connect(DeckVNC *v,const char *host,int port,const char *pass,int ssh_otp) {
    pthread_mutex_lock(&v->mutex);int cancelled=v->cancelled;pthread_mutex_unlock(&v->mutex);
    if(cancelled) return 0;
    rfbClient *c=rfbGetClient(8,3,4); if(!c) return 0;
    v->client=c; v->password=strdup(pass); rfbClientSetClientData(c,(void*)owner,v);
    free(c->serverHost); c->serverHost=strdup(host); c->serverPort=port;
    c->connectTimeout=8; c->readTimeout=10; c->canHandleNewFBSize=TRUE;
    c->GetPassword=password; c->MallocFrameBuffer=allocate; c->GotFrameBufferUpdate=updated;
    c->GotXCutText=clipboard_latin1;c->GotXCutTextUTF8=clipboard_utf8;
    /* Session Manager's OTP is VNC authentication inside an already authenticated
       SSH tunnel. Do not negotiate a second, unrelated TLS authentication scheme. */
    if(ssh_otp) {const uint32_t types[]={rfbVncAuth};SetClientAuthSchemes(c,types,1);}
    c->appData.encodingsString="tight zrle hextile raw"; c->appData.qualityLevel=7;
    c->appData.compressLevel=1; c->appData.useRemoteCursor=FALSE;
    c->format.redShift=16; c->format.greenShift=8; c->format.blueShift=0;
    int ok=ConnectToRFBServer(c,host,port);
    if(ok) {
        /* A lost tunnel must become a failed write, never terminate every desktop. */
        int one=1;
        if(setsockopt(c->sock,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one))!=0) return 0;
        pthread_mutex_lock(&v->mutex);
        v->interrupt_fd=dup(c->sock);
        if(v->cancelled) {shutdown(c->sock,SHUT_RDWR);ok=0;}
        pthread_mutex_unlock(&v->mutex);
    }
    /* Own client lifetime and use public initialization APIs, so cancellation can
       shut down our duplicated socket without racing rfbInitClient's implicit free. */
    connecting=v;
    if(ok) ok=InitialiseRFBConnection(c);
    if(ok) {c->width=c->si.framebufferWidth;c->height=c->si.framebufferHeight;ok=allocate(c);}
    if(ok) ok=SetFormatAndEncodings(c);
    if(ok) {
        c->updateRect.x=c->updateRect.y=0;c->updateRect.w=c->width;c->updateRect.h=c->height;c->isUpdateRectManagedByLib=TRUE;
        ok=SendFramebufferUpdateRequest(c,0,0,c->width,c->height,FALSE);
    }
    connecting=NULL;
    free(v->password); v->password=NULL; return ok;
}
int deck_vnc_poll(DeckVNC *v) {
    int n=WaitForMessage(v->client,10000);
    int ok=n<0 ? 0 : n==0 ? 1 : HandleRFBServerMessage(v->client);
    if(ok && v->client->extendedClipboardServerCapabilities && !v->clipboard_caps_sent) {
        /* Upstream decodes UTF-8 provides but does not advertise the receive
           limit. Request bounded unsolicited text so notify-only servers also
           deliver clipboard changes without polling or vendor patches. */
        rfbClientCutTextMsg message={0};message.type=rfbClientCutText;
        message.length=htonl((uint32_t)-8);
        uint32_t payload[]={htonl(rfbExtendedClipboard_Caps|rfbExtendedClipboard_Provide|rfbExtendedClipboard_Text),htonl(DECK_CLIPBOARD_LIMIT)};
        ok=WriteToRFBServer(v->client,(char*)&message,sz_rfbClientCutTextMsg) && WriteToRFBServer(v->client,(char*)payload,sizeof(payload));
        v->clipboard_caps_sent=ok;
    }
    return ok;
}
int deck_vnc_received_bytes(DeckVNC *v, uint64_t *total) {
    struct tcp_connection_info info = {0};
    socklen_t size = sizeof(info);
    pthread_mutex_lock(&v->mutex);
    int ok = v->interrupt_fd >= 0 && !v->cancelled &&
        getsockopt(v->interrupt_fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &info, &size) == 0;
    pthread_mutex_unlock(&v->mutex);
    if (ok) *total = info.tcpi_rxbytes;
    return ok;
}
int deck_vnc_width(DeckVNC *v) { return v->client->width; }
int deck_vnc_height(DeckVNC *v) { return v->client->height; }
const void *deck_vnc_pixels(DeckVNC *v) { return v->client->frameBuffer; }
int deck_vnc_dirty(DeckVNC *v) { int result=v->dirty; v->dirty=0; return result; }
int deck_vnc_auth_failed(DeckVNC *v) { return v->auth_failed; }
int deck_vnc_pointer(DeckVNC *v,int x,int y,int mask) { return SendPointerEvent(v->client,x,y,mask); }
int deck_vnc_key(DeckVNC *v,uint32_t key,int down) { return SendKeyEvent(v->client,key,down); }
int deck_vnc_quality(DeckVNC *v,int quality,int compression) {
    v->client->appData.enableJPEG=quality>=0;
    v->client->appData.qualityLevel=quality;
    v->client->appData.compressLevel=compression;
    return SetFormatAndEncodings(v->client);
}
int deck_vnc_resize(DeckVNC *v,int w,int h) {
    rfbClient *c=v->client;
    if(!c->screen.width || !c->screen.height) return -1;
    if(w<320 || h<200 || w>8192 || h>8192 || (size_t)w*h>33554432) return -2;
    /* 0.9.15's SendExtDesktopSize leaves screen id/x/y/flags uninitialized.
       Keep upstream unchanged; serialize a fully initialized single-screen request
       with its public protocol types and transport, retaining the server's id. */
    rfbSetDesktopSizeMsg message={0};
    rfbExtDesktopScreen screen=c->screen;
    message.type=rfbSetDesktopSize;message.width=htons((uint16_t)w);
    message.height=htons((uint16_t)h);message.numberOfScreens=1;
    screen.x=0;screen.y=0;screen.width=message.width;screen.height=message.height;
    if(!WriteToRFBServer(c,(char*)&message,sz_rfbSetDesktopSizeMsg) ||
       !WriteToRFBServer(c,(char*)&screen,sz_rfbExtDesktopScreen)) return 0;
    c->requestedResize=TRUE;
    return 1;
}
int deck_vnc_refresh(DeckVNC *v) { return SendFramebufferUpdateRequest(v->client,0,0,v->client->width,v->client->height,FALSE); }
int deck_vnc_cancel_resize(DeckVNC *v) {v->client->requestedResize=FALSE;return deck_vnc_refresh(v);}
int deck_vnc_send_clipboard(DeckVNC *v,const char *utf8,int length,const void *latin1,int latin1_length) {
    if(length<0 || length>DECK_CLIPBOARD_LIMIT) return -2;
    if(v->client->extendedClipboardServerCapabilities) return SendClientCutTextUTF8(v->client,(char*)utf8,length);
    if(latin1_length<0) return -1;
    return SendClientCutText(v->client,(char*)latin1,latin1_length);
}
int deck_vnc_take_clipboard(DeckVNC *v,const void **bytes,int *length,int *utf8) {
    if(!v->clipboard_dirty) return 0;v->clipboard_dirty=0;
    *bytes=v->clipboard;*length=v->clipboard_length;*utf8=v->clipboard_utf8;return 1;
}
void deck_vnc_free(DeckVNC *v) {
    free(v->pixels);free(v->clipboard);
    if(v->client) { v->client->frameBuffer=NULL; rfbClientCleanup(v->client); }
    if(v->interrupt_fd>=0) close(v->interrupt_fd);
    pthread_mutex_destroy(&v->mutex);free(v->password); free(v);
}
void deck_vnc_interrupt(DeckVNC *v) {
    pthread_mutex_lock(&v->mutex);v->cancelled=1;
    if(v->interrupt_fd>=0) shutdown(v->interrupt_fd,SHUT_RDWR);
    pthread_mutex_unlock(&v->mutex);
}
