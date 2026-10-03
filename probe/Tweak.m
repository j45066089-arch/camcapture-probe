#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <stdatomic.h>
#import <string.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdlib.h>

/* CamCaptureProbe v8 — externer Feed (raw NV12 aus Datei) statt nur prozedural
 *
 * Ziel: beweisen, dass der Daemon EXTERNE Daten liest und aufs Display bringt
 * — das ist der Baustein fuer den spaeteren H.264-Decode/Transport.
 *
 * Feed-Datei: raw NV12 mit 16-Byte-Header (little-endian):
 *   [0..3]  magic "CCPF" (0x46 0x50 0x43 0x43)
 *   [4..7]  u32 width
 *   [8..11] u32 height
 *   [12..15] u32 fmt (0 = NV12 zwei Ebenen: Y + interleaved UV)
 *   danach: Y Ebene (w*h), dann interleaved UV (w*h/2).
 *
 * ccp_paint liest die Datei JEDEN Frame neu (op/read/close) und blittet sie,
 * wenn sie existiert und geometrisch passt. Sonst animierter Balken (Fallback,
 * bewaehrt, also nie Schwarz). Datei hot-swapbar: neue Datei -> live neues Bild.
 *
 * Lesepfade (mobile-Daemon uid 501, HOME=/var/mobile):
 *   1. /var/mobile/Library/ccp_feed.raw
 *   2. /var/jb/usr/lib/ccp_feed.raw
 *   3. /var/tmp/ccp_feed.raw
 */

static IMP imp_bwnode_emit    = NULL;
static IMP imp_bwnode_emit2   = NULL;
static IMP imp_pixel_transfer = NULL;
static IMP imp_imgqueue_sink  = NULL;

static _Atomic int  g_hit1 = 0, g_hit2 = 0, g_hit3 = 0, g_hit4 = 0;
static _Atomic long g_frame = 0;
static _Atomic int  g_feed_ok = 0;   /* einmal erster erfolgreicher Feed-Blits */

/* ---------- externer Feed: read + scale-to-fit blit (1 = ok, 0 = fallback) ---------- */
static int ccp_feed_apply(CVImageBufferRef img) {
    if (CVPixelBufferGetPlaneCount(img) != 2) return 0;  /* nur NV12-Target */

    size_t tw = CVPixelBufferGetWidthOfPlane(img, 0);
    size_t th = CVPixelBufferGetHeightOfPlane(img, 0);

    const char *paths[] = {
        "/var/mobile/Library/ccp_feed.raw",
        "/var/jb/usr/lib/ccp_feed.raw",
        "/var/tmp/ccp_feed.raw",
        NULL
    };
    int fd = -1;
    for (int i = 0; paths[i]; i++) { fd = open(paths[i], O_RDONLY); if (fd >= 0) break; }
    if (fd < 0) return 0;

    uint8_t hdr[16];
    ssize_t got = read(fd, hdr, 16);
    if (got != 16 || hdr[0] != 'C' || hdr[1] != 'C' || hdr[2] != 'P' || hdr[3] != 'F') {
        close(fd); return 0;
    }
    uint32_t fw = *((uint32_t*)(hdr+4));
    uint32_t fh = *((uint32_t*)(hdr+8));
    if (fw == 0 || fh == 0) { close(fd); return 0; }

    size_t ysz  = (size_t)fw * fh;          /* Y */
    size_t uvsz = (size_t)fw * fh / 2;      /* interleaved NV12 chroma */
    uint8_t *buf = (uint8_t*)malloc(ysz + uvsz);
    if (!buf) { close(fd); return 0; }
    ssize_t payload = read(fd, buf, ysz + uvsz);
    close(fd);
    if (payload != (ssize_t)(ysz + uvsz)) { free(buf); return 0; }

    /* Y: nearest-neighbor scale fw x fh -> tw x th */
    uint8_t *y0 = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(img, 0);
    size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(img, 0);
    if (y0) {
        for (size_t ty = 0; ty < th; ty++) {
            uint32_t sy = (uint32_t)((uint64_t)ty * fh / th);
            const uint8_t *srow = buf + (size_t)sy * fw;
            uint8_t *drow = y0 + ty * ybpr;
            for (size_t tx = 0; tx < tw; tx++) {
                uint32_t sx = (uint32_t)((uint64_t)tx * fw / tw);
                drow[tx] = srow[sx];
            }
            if (ybpr > tw) memset(drow + tw, 0, ybpr - tw);
        }
    }
    /* UV (interleaved, halbe Aufloesung) scale fw x fh/2 -> tw x th/2 */
    uint8_t *uv = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(img, 1);
    size_t uvbpr = CVPixelBufferGetBytesPerRowOfPlane(img, 1);
    if (uv) {
        size_t fuvh = fh / 2, tuvh = th / 2;
        const uint8_t *uvsrc = buf + ysz;
        for (size_t ty = 0; ty < tuvh; ty++) {
            uint32_t sy = (uint32_t)((uint64_t)ty * fuvh / tuvh);
            const uint8_t *srow = uvsrc + (size_t)sy * fw;
            uint8_t *drow = uv + ty * uvbpr;
            for (size_t tx = 0; tx < tw; tx++) {
                uint32_t sx = (uint32_t)((uint64_t)tx * fw / tw);
                drow[tx] = srow[sx];
            }
            if (uvbpr > tw) memset(drow + tw, 0, uvbpr - tw);
        }
    }
    free(buf);

    int expected = 0;
    atomic_compare_exchange_strong_explicit(&g_feed_ok, &expected, 1,
                                            memory_order_relaxed, memory_order_relaxed);
    return 1;
}

/* ---------- animierter Balken (Fallback, bewaehrt v7) ---------- */
static void ccp_paint_fallback(CVImageBufferRef img, long f) {
    size_t np = CVPixelBufferGetPlaneCount(img);
    if (np == 0) {
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(img);
        if (base) {
            size_t h   = CVPixelBufferGetHeight(img);
            size_t bpr = CVPixelBufferGetBytesPerRow(img);
            size_t w   = CVPixelBufferGetWidth(img);
            size_t bar = (size_t)((f * 6) % (w ? w : 1));
            size_t bw  = w / 10; if (bw == 0) bw = 1;
            for (size_t y = 0; y < h; y++) {
                uint8_t *row = base + y * bpr;
                for (size_t x = 0; x < w; x++) {
                    row[x*4+0]=25; row[x*4+1]=20; row[x*4+2]=60; row[x*4+3]=255;
                }
                size_t end = bar + bw; if (end > w) end = w;
                for (size_t x = bar; x < end; x++) {
                    row[x*4+0]=255; row[x*4+1]=255; row[x*4+2]=255; row[x*4+3]=255;
                }
            }
        }
    } else {
        for (size_t p = 0; p < np; p++) {
            uint8_t *pp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, p);
            if (!pp) continue;
            size_t phh = CVPixelBufferGetHeightOfPlane(img, p);
            size_t pbpr = CVPixelBufferGetBytesPerRowOfPlane(img, p);
            size_t pww = CVPixelBufferGetWidthOfPlane(img, p);
            if (p == 0) {
                size_t bar = (size_t)((f * 3) % (pww ? pww : 1));
                size_t bw  = pww / 8; if (bw == 0) bw = 1;
                for (size_t y = 0; y < phh; y++) {
                    memset(pp + y*pbpr, 16, pbpr);
                    size_t end = bar + bw; if (end > pww) end = pww;
                    memset(pp + y*pbpr + bar, 235, end - bar);
                }
            } else {
                for (size_t y = 0; y < phh; y++) memset(pp + y*pbpr, 128, pbpr);
            }
        }
    }
}

static void ccp_paint(CMSampleBufferRef sb) {
    if (!sb) return;
    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
    if (!img) return;
    if (kCVReturnSuccess != CVPixelBufferLockBaseAddress(img, 0)) return;

    long f = atomic_fetch_add_explicit(&g_frame, 1, memory_order_relaxed);
    if (!ccp_feed_apply(img)) ccp_paint_fallback(img, f);

    CVPixelBufferUnlockBaseAddress(img, 0);
}

static void ccp_latch(_Atomic int *flag, const char *name) {
    int expected = 0;
    if (atomic_compare_exchange_strong_explicit(flag, &expected, 1,
                                                memory_order_relaxed, memory_order_relaxed)) {
        notify_post(name);
    }
}

typedef void (*emit1_t)(id, SEL, void *);
typedef void (*emit2_t)(id, SEL, void *, void *);
typedef void (*render2_t)(id, SEL, void *, void *);

static void hk_emit1(id self, SEL sel, void *sb) {
    ccp_latch(&g_hit1, "com.maurice.vcam.hit1");
    ccp_paint((CMSampleBufferRef)sb);
    if (imp_bwnode_emit) ((emit1_t)imp_bwnode_emit)(self, sel, sb);
}
static void hk_emit2(id self, SEL sel, void *sb, void *inp) {
    ccp_latch(&g_hit2, "com.maurice.vcam.hit2");
    ccp_paint((CMSampleBufferRef)sb);
    if (imp_bwnode_emit2) ((emit2_t)imp_bwnode_emit2)(self, sel, sb, inp);
}
static void hk_pxt(id self, SEL sel, void *sb) {
    ccp_latch(&g_hit3, "com.maurice.vcam.hit3");
    ccp_paint((CMSampleBufferRef)sb);
    if (imp_pixel_transfer) ((emit1_t)imp_pixel_transfer)(self, sel, sb);
}
static void hk_imgqueue(id self, SEL sel, void *sb, void *inp) {
    ccp_latch(&g_hit4, "com.maurice.vcam.hit4");
    ccp_paint((CMSampleBufferRef)sb);
    if (imp_imgqueue_sink) ((render2_t)imp_imgqueue_sink)(self, sel, sb, inp);
}

static void ccp_hook(Class c, SEL sel, IMP *orig_out, IMP newImp) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    *orig_out = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

__attribute__((constructor)) void ccp_init(void) {
    notify_post("com.maurice.vcam.ctor");

    Class bw  = objc_getClass("BWNodeOutput");
    Class bwp = objc_getClass("BWPixelTransferNode");
    Class iq  = objc_getClass("BWImageQueueSinkNode");

    if (bw) {
        ccp_hook(bw, sel_registerName("emitSampleBuffer:"), &imp_bwnode_emit, (IMP)hk_emit1);
        ccp_hook(bw, sel_registerName("emitSampleBuffer:forInput:"), &imp_bwnode_emit2, (IMP)hk_emit2);
    }
    if (bwp) {
        Method m = class_getInstanceMethod(bwp, sel_registerName("emitSampleBuffer:"));
        if (m) ccp_hook(bwp, sel_registerName("emitSampleBuffer:"), &imp_pixel_transfer, (IMP)hk_pxt);
    }
    if (iq) {
        ccp_hook(iq, sel_registerName("renderSampleBuffer:forInput:"), &imp_imgqueue_sink, (IMP)hk_imgqueue);
    }
}