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
 * Zwei Proof-Kanäle in EINEM Build:
 *   (1) Beacon: notify_post / notify_set_state (sandbox-toleranter Daemon-Signalweg)
 *   (2) Sentinel: bestehenden CVPixelBuffer in-place mit Y-Split-Muster füllen
 *
 * Hooks (parallel, welcher Sink auf iOS 18 wirklich Frames bekommt):
 *   tag1  BWNodeOutput          emitSampleBuffer:
 *   tag2  BWNodeOutput          emitSampleBuffer:forInput:
 *   tag3  BWPixelTransferNode   emitSampleBuffer:   (nur falls Override)
 *   tag4  BWImageQueueSinkNode  renderSampleBuffer:forInput:
 */

#define NOTIFY_CLASSES "com.maurice.vcam.classes"  // 64-bit Maske: welche Klassen existieren
#define NOTIFY_HIT     "com.maurice.vcam.hit"      // notify_post beim ERSTEN Frame-Treffer
#define NOTIFY_STATE   "com.maurice.vcam.state"    // (tag<<48) | frameCount

static _Atomic long        g_frames = 0;   // wie oft ein Hook feuerte
static _Atomic int         g_posted = 0;   // hit-post Latch

/* IMP-Originale */
static IMP imp_bwnode_emit   = NULL;
static IMP imp_bwnode_emit2  = NULL;
static IMP imp_pixel_transfer = NULL;
static IMP imp_imgqueue_sink = NULL;

/* ---------- Sentinel: bestehenden Buffer in-place füllen ---------- */
static void ccp_paint(CMSampleBufferRef sb) {
    if (!sb) return;
    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
    if (!img) return;
    if (kCVReturnSuccess != CVPixelBufferLockBaseAddress(img, 0)) return;

    size_t np = CVPixelBufferGetPlaneCount(img);
    if (np == 0) {
        /* gepackt (z.B. 32BGRA): oben rot, unten grün */
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(img);
        if (base) {
            size_t h = CVPixelBufferGetHeight(img);
            size_t bpr = CVPixelBufferGetBytesPerRow(img);
            size_t half = h >> 1;
            if (CVPixelBufferGetPixelFormatType(img) == kCVPixelFormatType_32BGRA) {
                for (size_t y = 0; y < h; y++) {
                    uint8_t *row = base + y * bpr;
                    uint8_t b, g, r;
                    if (y < half) { b = 0;   g = 0;   r = 255; }  /* rot    */
                    else          { b = 255; g = 255; r = 0;   }  /* gelb   */
                    for (size_t x = 0; x < (bpr >> 2); x++) {
                        row[x*4+0] = b; row[x*4+1] = g; row[x*4+2] = r; row[x*4+3] = 255;
                    }
                }
            } else {
                memset(base, 128, bpr * h);
            }
        }
    } else {
        /* planar (420f/NV12): Y-Split oben dunkel/unten hell, Chroma neutral */
        uint8_t *yp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, 0);
        if (yp) {
            size_t yh  = CVPixelBufferGetHeightOfPlane(img, 0);
            size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(img, 0);
            size_t yw  = CVPixelBufferGetWidthOfPlane(img, 0);
            size_t half = yh >> 1;
            for (size_t y = 0; y < yh; y++)
                memset(yp + y * ybpr, (y < half) ? 16 : 235, yw);
        }
        for (size_t p = 1; p < np; p++) {
            uint8_t *pp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, p);
            if (!pp) continue;
            size_t ph  = CVPixelBufferGetHeightOfPlane(img, p);
            size_t pbpr = CVPixelBufferGetBytesPerRowOfPlane(img, p);
            size_t pw  = CVPixelBufferGetWidthOfPlane(img, p);
            for (size_t y = 0; y < ph; y++) memset(pp + y * pbpr, 128, pw);
        }
    }
    CVPixelBufferUnlockBaseAddress(img, 0);
}

/* ---------- Beacon: Frame-Treffer melden (Latch + State) ---------- */
typedef void (*emit1_t)(id, SEL, void *);
typedef void (*emit2_t)(id, SEL, void *, void *);
typedef void (*render2_t)(id, SEL, void *, void *);

static void ccp_hit(uint64_t tag) {
    atomic_fetch_add_explicit(&g_frames, 1, memory_order_relaxed);
    int expected = 0;
    if (atomic_compare_exchange_strong_explicit(&g_posted, &expected, 1,
                                                memory_order_relaxed, memory_order_relaxed)) {
        notify_post(NOTIFY_HIT);
    }
    uint64_t state = (tag << 48) | ((uint64_t)atomic_load(&g_frames) & 0xFFFFFFFFFFFFULL);
    notify_set_state(NOTIFY_STATE, state);
}

static void hk_emit1(id self, SEL sel, void *sb) {
    ccp_hit(1);
    ccp_paint((CMSampleBufferRef)sb);
    if (imp_bwnode_emit) ((emit1_t)imp_bwnode_emit)(self, sel, sb);
}
static void hk_emit2(id self, SEL sel, void *sb, void *inp) {
    ccp_hit(2);
    ccp_paint((CMSampleBufferRef)sb);
    if (imp_bwnode_emit2) ((emit2_t)imp_bwnode_emit2)(self, sel, sb, inp);
}
static void hk_pxt(id self, SEL sel, void *sb) {
    ccp_hit(3);
    ccp_paint((CMSampleBufferRef)sb);
    if (imp_pixel_transfer) ((emit1_t)imp_pixel_transfer)(self, sel, sb);
}
static void hk_imgqueue(id self, SEL sel, void *sb, void *inp) {
    ccp_hit(4);
    ccp_paint((CMSampleBufferRef)sb);
    if (imp_imgqueue_sink) ((render2_t)imp_imgqueue_sink)(self, sel, sb, inp);
}

/* ---------- Hook-Helfer (method_setImplementation) ---------- */
static void ccp_hook(Class c, SEL sel, IMP *orig_out, IMP newImp) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    *orig_out = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

/* ---------- Klassen-Maske als Beacon ---------- */
static void ccp_report_classes(void) {
    const char *names[] = {
        "BWNodeOutput", "BWPixelTransferNode", "BWImageQueueSinkNode",
        "BWNode", "BWGraph", "FigCaptureSession", "FigCaptureSource",
        "AVCaptureSession", NULL
    };
    uint64_t mask = 0;
    for (int i = 0; names[i]; i++)
        if (objc_getClass(names[i])) mask |= (1ULL << i);
    notify_set_state(NOTIFY_CLASSES, mask);
    notify_post(NOTIFY_CLASSES);
}

__attribute__((constructor)) void ccp_init(void) {
    ccp_report_classes();

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
        /* nur wenn die Subklasse die Methode selbst deklariert (Override) */
        Method m = class_getInstanceMethod(bwp, sel_registerName("emitSampleBuffer:"));
        if (m) ccp_hook(bwp, sel_registerName("emitSampleBuffer:"),
                        &imp_pixel_transfer, (IMP)hk_pxt);
    }
    if (iq) {
        ccp_hook(iq, sel_registerName("renderSampleBuffer:forInput:"),
                 &imp_imgqueue_sink, (IMP)hk_imgqueue);
    }
}