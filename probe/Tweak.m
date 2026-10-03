#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <stdatomic.h>
#import <string.h>

/* CamCaptureProbe v7 — animierter Vollbild-Feed (prozedural, kein Datei/Socket)
 *
 * Ziel: beweisen, dass JEDER Frame kontinuierlich durch den Hook neu geschrieben
 * wird (bewegter heller Balken auf dunklem Grund). Damit ist der zentrale
 * Swap-Pfad der LordVCAM-v2 Ebene fest etabliert; hier wird als Naechstes der
 * echte Transport (H.264 -> CVPixelBuffer) eingeklinkt.
 *
 * Paint:
 *   YUV planar: Y=16 Grund, Y=235 wandernder Balken, Chroma 128 neutral.
 *   32BGRA:     dunkelblauer Grund, weisser wandernder Balken.
 *
 * Hooks (bewaehrt, verifiziert):
 *   hit1  BWNodeOutput          emitSampleBuffer:
 *   hit2  BWNodeOutput          emitSampleBuffer:forInput:
 *   hit3  BWPixelTransferNode   emitSampleBuffer:
 *   hit4  BWImageQueueSinkNode  renderSampleBuffer:forInput:
 */

static IMP imp_bwnode_emit    = NULL;
static IMP imp_bwnode_emit2   = NULL;
static IMP imp_pixel_transfer = NULL;
static IMP imp_imgqueue_sink  = NULL;

static _Atomic int  g_hit1 = 0, g_hit2 = 0, g_hit3 = 0, g_hit4 = 0;
static _Atomic long g_frame = 0;

static void ccp_paint(CMSampleBufferRef sb) {
    if (!sb) return;
    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
    if (!img) return;
    if (kCVReturnSuccess != CVPixelBufferLockBaseAddress(img, 0)) return;

    long f  = atomic_fetch_add_explicit(&g_frame, 1, memory_order_relaxed);
    size_t np = CVPixelBufferGetPlaneCount(img);

    if (np == 0) {
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(img);
        if (base) {
            size_t h   = CVPixelBufferGetHeight(img);
            size_t bpr = CVPixelBufferGetBytesPerRow(img);
            size_t w   = CVPixelBufferGetWidth(img);
            if (CVPixelBufferGetPixelFormatType(img) == kCVPixelFormatType_32BGRA) {
                size_t bar = (size_t)((f * 6) % (w ? w : 1));
                size_t bw  = w / 10; if (bw == 0) bw = 1;
                for (size_t y = 0; y < h; y++) {
                    uint8_t *row = base + y * bpr;
                    for (size_t x = 0; x < w; x++) {
                        row[x*4+0] = 25;  /* B */
                        row[x*4+1] = 20;  /* G */
                        row[x*4+2] = 60;  /* R */
                        row[x*4+3] = 255;
                    }
                    size_t end = bar + bw; if (end > w) end = w;
                    for (size_t x = bar; x < end; x++) {
                        row[x*4+0] = 255; row[x*4+1] = 255;
                        row[x*4+2] = 255; row[x*4+3] = 255;
                    }
                }
            } else {
                memset(base, 128, bpr * h);
            }
        }
    } else {
        for (size_t p = 0; p < np; p++) {
            uint8_t *pp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, p);
            if (!pp) continue;
            size_t ph   = CVPixelBufferGetHeightOfPlane(img, p);
            size_t pbpr = CVPixelBufferGetBytesPerRowOfPlane(img, p);
            size_t pw   = CVPixelBufferGetWidthOfPlane(img, p);
            if (p == 0) {
                size_t bar = (size_t)((f * 3) % (pw ? pw : 1));
                size_t bw  = pw / 8; if (bw == 0) bw = 1;
                for (size_t y = 0; y < ph; y++) {
                    memset(pp + y * pbpr, 16, pbpr);
                    size_t end = bar + bw; if (end > pw) end = pw;
                    memset(pp + y * pbpr + bar, 235, end - bar);
                }
            } else {
                for (size_t y = 0; y < ph; y++)
                    memset(pp + y * pbpr, 128, pbpr);
            }
        }
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