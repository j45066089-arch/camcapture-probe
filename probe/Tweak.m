#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <stdatomic.h>
#import <string.h>

/* CamCaptureProbe v2 — Sentinel-Swap + Beacon (cameracaptured, arm64e)
 *
 * Proof-Kanäle (nur notify_post, keine Socket-/Datei-Writes):
 *   ctor gefeuert   -> "com.maurice.vcam.ctor"
 *   Klasse da       -> "com.maurice.vcam.cls.bw" / ".bwp" / ".imgq"
 *   Frame-Treffer   -> "com.maurice.vcam.hit1..4" (Latch auf ersten Treffer je Tag)
 *
 * Hooks:
 *   hit1  BWNodeOutput          emitSampleBuffer:
 *   hit2  BWNodeOutput          emitSampleBuffer:forInput:
 *   hit3  BWPixelTransferNode   emitSampleBuffer:   (falls Override)
 *   hit4  BWImageQueueSinkNode  renderSampleBuffer:forInput:
 */

static IMP imp_bwnode_emit    = NULL;
static IMP imp_bwnode_emit2   = NULL;
static IMP imp_pixel_transfer = NULL;
static IMP imp_imgqueue_sink  = NULL;

static _Atomic int g_hit1 = 0, g_hit2 = 0, g_hit3 = 0, g_hit4 = 0;

/* ---------- Sentinel: bestehenden Buffer in-place füllen ---------- */
static void ccp_paint(CMSampleBufferRef sb) {
    if (!sb) return;
    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
    if (!img) return;
    if (kCVReturnSuccess != CVPixelBufferLockBaseAddress(img, 0)) return;

    size_t np = CVPixelBufferGetPlaneCount(img);
    if (np == 0) {
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(img);
        if (base) {
            size_t h   = CVPixelBufferGetHeight(img);
            size_t bpr = CVPixelBufferGetBytesPerRow(img);
            size_t half = h >> 1;
            if (CVPixelBufferGetPixelFormatType(img) == kCVPixelFormatType_32BGRA) {
                for (size_t y = 0; y < h; y++) {
                    uint8_t *row = base + y * bpr;
                    uint8_t b, g, r;
                    if (y < half) { b = 0;   g = 0;   r = 255; }
                    else          { b = 255; g = 255; r = 0; }
                    for (size_t x = 0; x < (bpr >> 2); x++) {
                        row[x*4+0] = b; row[x*4+1] = g; row[x*4+2] = r; row[x*4+3] = 255;
                    }
                }
            } else {
                memset(base, 128, bpr * h);
            }
        }
    } else {
        uint8_t *yp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, 0);
        if (yp) {
            size_t yh   = CVPixelBufferGetHeightOfPlane(img, 0);
            size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(img, 0);
            size_t yw   = CVPixelBufferGetWidthOfPlane(img, 0);
            size_t half = yh >> 1;
            for (size_t y = 0; y < yh; y++)
                memset(yp + y * ybpr, (y < half) ? 16 : 235, yw);
        }
        for (size_t p = 1; p < np; p++) {
            uint8_t *pp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, p);
            if (!pp) continue;
            size_t ph   = CVPixelBufferGetHeightOfPlane(img, p);
            size_t pbpr = CVPixelBufferGetBytesPerRowOfPlane(img, p);
            size_t pw   = CVPixelBufferGetWidthOfPlane(img, p);
            for (size_t y = 0; y < ph; y++) memset(pp + y * pbpr, 128, pw);
        }
    }
    CVPixelBufferUnlockBaseAddress(img, 0);
}

/* ---------- Latch-Helfer: post nur beim ersten Treffer ---------- */
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

/* ---------- Hook-Helfer ---------- */
static void ccp_hook(Class c, SEL sel, IMP *orig_out, IMP newImp) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    *orig_out = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

__attribute__((constructor)) void ccp_init(void) {
    notify_post("com.maurice.vcam.ctor");

    if (objc_getClass("BWNodeOutput"))        notify_post("com.maurice.vcam.cls.bw");
    if (objc_getClass("BWPixelTransferNode")) notify_post("com.maurice.vcam.cls.bwp");
    if (objc_getClass("BWImageQueueSinkNode"))notify_post("com.maurice.vcam.cls.imgq");

    Class bw  = objc_getClass("BWNodeOutput");
    Class bwp = objc_getClass("BWPixelTransferNode");
    Class iq  = objc_getClass("BWImageQueueSinkNode");

    if (bw) {
        ccp_hook(bw, sel_registerName("emitSampleBuffer:"),
                 &imp_bwnode_emit, (IMP)hk_emit1);
        ccp_hook(bw, sel_registerName("emitSampleBuffer:forInput:"),
                 &imp_bwnode_emit2, (IMP)hk_emit2);
    }
    if (bwp) {
        Method m = class_getInstanceMethod(bwp, sel_registerName("emitSampleBuffer:"));
        if (m) ccp_hook(bwp, sel_registerName("emitSampleBuffer:"),
                        &imp_pixel_transfer, (IMP)hk_pxt);
    }
    if (iq) {
        ccp_hook(iq, sel_registerName("renderSampleBuffer:forInput:"),
                 &imp_imgqueue_sink, (IMP)hk_imgqueue);
    }
}