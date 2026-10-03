#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <stdatomic.h>
#import <string.h>
#import <stdlib.h>
#import <pthread.h>
#import <unistd.h>

/* CamCaptureProbe v10 — externer Feed via vm_write (Puffer im Daemon, dateilos)
 *
 * Datei-Read ist in cameracaptured blockt (v8). Stattdessen:
 *   - Die Dylib exportiert einen Feed-Puffer + Geometrie + Sequenzzaehler.
 *   - Ein externer Helper schreibt Frames per task_for_pid + vm_write direkt
 *     in diesen Puffer (feedpusher) und erhoeht ccp_feed_seq.
 *   - Der Frame-Hook liest den Puffer (plane-agnostisch blit, v9-verifiziert),
 *     wenn sich ccp_feed_seq geaendert hat; sonst animierter Balken (Fallback).
 *
 * Exportierte Symbole:
 *   uint8_t          ccp_feed_buf[FEED_Y + FEED_UV]  (fixed 640x480 NV12)
 *   volatile uint32_t ccp_feed_w, ccp_feed_h         (feed-aufloesung)
 *   volatile uint32_t ccp_feed_seq                   (frame-zaehler)
 */
#define FEED_W  640
#define FEED_H  480
#define FEED_Y  (FEED_W * FEED_H)
#define FEED_UV (FEED_W * FEED_H / 2)

__attribute__((visibility("default")))
uint8_t ccp_feed_buf[FEED_Y + FEED_UV];

__attribute__((visibility("default")))
volatile uint32_t ccp_feed_w = FEED_W;

__attribute__((visibility("default")))
volatile uint32_t ccp_feed_h = FEED_H;

__attribute__((visibility("default")))
volatile uint32_t ccp_feed_seq = 0;

static IMP imp_bwnode_emit    = NULL;
static IMP imp_bwnode_emit2   = NULL;
static IMP imp_pixel_transfer = NULL;
static IMP imp_imgqueue_sink  = NULL;

static _Atomic int  g_hit1 = 0, g_hit2 = 0, g_hit3 = 0, g_hit4 = 0;
static _Atomic long g_frame = 0;
static uint32_t g_seen_seq = 0;

/* ---------- Blit (plane-agnostisch, v9-verifiziert) ---------- */
static int ccp_blit_feed(CVImageBufferRef img, uint32_t fw, uint32_t fh,
                         const uint8_t *buf, size_t ysz) {
    size_t np = CVPixelBufferGetPlaneCount(img);
    if (np < 1 || np > 3) return 0;
    size_t tw = CVPixelBufferGetWidthOfPlane(img, 0);
    size_t th = CVPixelBufferGetHeightOfPlane(img, 0);

    uint8_t *y0 = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, 0);
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

    size_t fuvh = fh / 2;
    const uint8_t *uvsrc = buf + ysz;
    if (np == 2) {
        uint8_t *uv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, 1);
        size_t uvbpr = CVPixelBufferGetBytesPerRowOfPlane(img, 1);
        size_t tuvh = th / 2;
        if (uv) {
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
    } else if (np == 3) {
        uint8_t *up = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, 1);
        uint8_t *vp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, 2);
        size_t ubpr = CVPixelBufferGetBytesPerRowOfPlane(img, 1);
        size_t vbpr = CVPixelBufferGetBytesPerRowOfPlane(img, 2);
        size_t uw = CVPixelBufferGetWidthOfPlane(img, 1);
        size_t vw = CVPixelBufferGetWidthOfPlane(img, 2);
        size_t uh = CVPixelBufferGetHeightOfPlane(img, 1);
        size_t vh = CVPixelBufferGetHeightOfPlane(img, 2);
        if (up) {
            for (size_t ty = 0; ty < uh; ty++) {
                uint32_t sy = (uint32_t)((uint64_t)ty * fuvh / uh);
                const uint8_t *srow = uvsrc + (size_t)sy * fw;
                uint8_t *drow = up + ty * ubpr;
                for (size_t tx = 0; tx < uw; tx++) {
                    uint32_t sx = (uint32_t)((uint64_t)tx * fw / tw);
                    drow[tx] = srow[2*sx];
                }
                if (ubpr > uw) memset(drow + uw, 0, ubpr - uw);
            }
        }
        if (vp) {
            for (size_t ty = 0; ty < vh; ty++) {
                uint32_t sy = (uint32_t)((uint64_t)ty * fuvh / vh);
                const uint8_t *srow = uvsrc + (size_t)sy * fw;
                uint8_t *drow = vp + ty * vbpr;
                for (size_t tx = 0; tx < vw; tx++) {
                    uint32_t sx = (uint32_t)((uint64_t)tx * fw / tw);
                    drow[tx] = srow[2*sx + 1];
                }
                if (vbpr > vw) memset(drow + vw, 0, vbpr - vw);
            }
        }
    }
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

/* ---------- Feed-Simulator: thread mutiert den exportierten Puffer ---------- */
static void *ccp_feed_thread(void *arg) {
    (void)arg;
    /* puffer als Y(640x480) + UV neutral; bewegter farbiger Balken */
    uint32_t s = 1;
    for (;;) {
        for (size_t y = 0; y < FEED_H; y++) {
            for (size_t x = 0; x < FEED_W; x++) {
                size_t bar = (s * 10) % FEED_W;
                uint8_t v;
                if (x >= bar && x < bar + 96) {
                    v = 235;                                  /* heller balken */
                } else {
                    v = (y < FEED_H/2) ? ((x < FEED_W/2) ? 40 : 90)
                                       : ((x < FEED_W/2) ? 150 : 210);
                }
                ccp_feed_buf[y*FEED_W + x] = v;
            }
        }
        memset(ccp_feed_buf + FEED_Y, 128, FEED_UV);
        ccp_feed_seq = s;
        s++;
        usleep(33000);
    }
    return NULL;
}

static void ccp_paint(CMSampleBufferRef sb) {
    if (!sb) return;
    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
    if (!img) return;
    if (kCVReturnSuccess != CVPixelBufferLockBaseAddress(img, 0)) return;

    long f = atomic_fetch_add_explicit(&g_frame, 1, memory_order_relaxed);

    uint32_t seq = ccp_feed_seq;
    uint32_t fw = ccp_feed_w, fh = ccp_feed_h;
    if (seq != 0 && seq != g_seen_seq && fw > 0 && fh > 0 && fw <= FEED_W && fh <= FEED_H) {
        if (ccp_blit_feed(img, fw, fh, ccp_feed_buf, FEED_Y)) {
            g_seen_seq = seq;
        } else {
            ccp_paint_fallback(img, f);
        }
    } else {
        ccp_paint_fallback(img, f);
    }

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

    /* feed-puffer default: 4 Quadranten (erkennbar) */
    for (size_t y = 0; y < FEED_H; y++) {
        for (size_t x = 0; x < FEED_W; x++) {
            uint8_t v = (y < FEED_H/2) ? ((x < FEED_W/2) ? 40 : 90)
                                       : ((x < FEED_W/2) ? 150 : 210);
            ccp_feed_buf[y*FEED_W + x] = v;
        }
    }
    memset(ccp_feed_buf + FEED_Y, 128, FEED_UV);

        /* feed-simulator ehren — laeuft nur, wenn ein Flag gesetzt ist (hier: immer).
           Besser: ueber einen exportierbaren Schalter; simpel: immer an. */
        pthread_t th;
        pthread_create(&th, NULL, ccp_feed_thread, NULL);

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