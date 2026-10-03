#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <stdatomic.h>
#import <string.h>

/* CamCaptureProbe v13 — Klassen-Survey als Bild-Streifen + Face-Strip
 *
 * Face-Tracking laeuft NICHT ueber Sample-Buffer-Attachments (v12 bewiesen:
 * Bild gesund, Tracking bleibt). Es ist ein eigener Node. Um den zu treffen,
 * brauche ich die Liste der EXISTIERENDEN Tracking-Klassen im Daemon.
 *
 * Kanal: KEIN Datei-Write (sandbox-tot), KEIN log, KEIN Frida. -> Bild selbst.
 *
 * Layout (plane-kodiert):
 *   OBERE Haelft = 4-Quadranten-Baseline (zeigt: Hook + Paint gesund).
 *   UNTERE Haelft in 8 vertikale Streifen. Streifen i:
 *     hell (235) = Klasse existiert, dunkel (16) = fehlt.
 *
 * Streifen-Reihenfolge (links->rechts):
 *   1 BWFaceDetectionNode
 *   2 BWMetadataSourceNode
 *   3 FigCaptureMetadata
 *   4 BWFaceIntelligenceEstimator
 *   5 BWFaceSegmentation
 *   6 FigFaceDetect
 *   7 BWStillImageNode        (Kontrolle: muesste existieren, Video+Still)
 *   8 BWImageQueueSinkNode    (Kontrolle: existiert, unser Hook-Kandidat)
 */

static IMP imp_bwnode_emit    = NULL;
static IMP imp_bwnode_emit2   = NULL;
static IMP imp_pixel_transfer = NULL;
static IMP imp_imgqueue_sink  = NULL;

static _Atomic int  g_hit1 = 0, g_hit2 = 0, g_hit3 = 0, g_hit4 = 0;
static _Atomic long g_frame = 0;

static const char *g_survey_names[8] = {
    "BWFaceDetectionNode",
    "BWMetadataSourceNode",
    "FigCaptureMetadata",
    "BWFaceIntelligenceEstimator",
    "BWFaceSegmentation",
    "BWFaceDetect",
    "BWStillImageNode",
    "BWImageQueueSinkNode",
};

/* Existenz-Bitset (0..7 -> Klassen 1..8) — im ctor befüllt */
static _Atomic unsigned g_survey_bits = 0;

/* Nur Face-/Detect-Keys entfernen — MetadataDictionary / AE / Fokus bleiben. */
static void ccp_strip_face(CMSampleBufferRef sb) {
    if (!sb) return;
    const CFStringRef keys[] = {
        CFSTR("DetectedFaceInfo"),
        CFSTR("DetectedFacesInfo"),
        CFSTR("FacesArray"),
        CFSTR("FaceRectDisplayBuffer"),
    };
    for (size_t i = 0; i < sizeof(keys)/sizeof(keys[0]); i++)
        CMSetAttachment(sb, keys[i], NULL, kCMAttachmentMode_ShouldPropagate);
}

static inline uint8_t survey_luma(size_t x, size_t y, size_t w, size_t h) {
    if (y < h/2) {
        /* obere Hälfte: 4-Quadranten-Baseline */
        if (y < h/4) return (x < w/2) ? 40 : 90;
        else         return (x < w/2) ? 90 : 40;
    }
    /* untere Haelft: 8 Streifen */
    unsigned bits = (unsigned)atomic_load(&g_survey_bits);
    size_t stripe = (x * 8) / w;   /* 0..7 */
    if (stripe > 7) stripe = 7;
    return (bits & (1u << stripe)) ? 235 : 16;
}

static void ccp_paint(CMSampleBufferRef sb) {
    if (!sb) return;
    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
    if (!img) return;
    if (kCVReturnSuccess != CVPixelBufferLockBaseAddress(img, 0)) return;
    atomic_fetch_add_explicit(&g_frame, 1, memory_order_relaxed);

    size_t np = CVPixelBufferGetPlaneCount(img);
    if (np == 0) {
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(img);
        if (base) {
            size_t h   = CVPixelBufferGetHeight(img);
            size_t bpr = CVPixelBufferGetBytesPerRow(img);
            size_t w   = CVPixelBufferGetWidth(img);
            unsigned bits = (unsigned)atomic_load(&g_survey_bits);
            for (size_t y = 0; y < h; y++) {
                uint8_t *row = base + y * bpr;
                for (size_t x = 0; x < w; x++) {
                    uint8_t B, G, R;
                    if (y < h/2) {
                        if (y < h/4) { if (x < w/2) {B=255;G=0;R=0;} else {B=0;G=255;R=0;} }
                        else         { if (x < w/2) {B=255;G=0;R=255;} else {B=255;G=255;R=0;} }
                    } else {
                        size_t stripe = (x * 8) / w; if (stripe > 7) stripe = 7;
                        if (bits & (1u << stripe)) { B=255; G=255; R=255; } /* hell */
                        else                        { B=16;  G=16;  R=16;  } /* dunkel */
                    }
                    row[x*4+0]=B; row[x*4+1]=G; row[x*4+2]=R; row[x*4+3]=255;
                }
            }
        }
    } else {
        uint8_t *y0 = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, 0);
        size_t yw   = CVPixelBufferGetWidthOfPlane(img, 0);
        size_t yh   = CVPixelBufferGetHeightOfPlane(img, 0);
        size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(img, 0);
        if (y0) {
            for (size_t y = 0; y < yh; y++) {
                uint8_t *row = y0 + y * ybpr;
                for (size_t x = 0; x < yw; x++) row[x] = survey_luma(x, y, yw, yh);
                if (ybpr > yw) memset(row + yw, 0, ybpr - yw);
            }
        }
        for (size_t p = 1; (int)p < (int)np; p++) {
            uint8_t *pp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, p);
            if (!pp) continue;
            size_t ph   = CVPixelBufferGetHeightOfPlane(img, p);
            size_t pbpr = CVPixelBufferGetBytesPerRowOfPlane(img, p);
            for (size_t y = 0; y < ph; y++) memset(pp + y * pbpr, 128, pbpr);
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
    ccp_strip_face((CMSampleBufferRef)sb);
    ccp_paint((CMSampleBufferRef)sb);
    if (imp_bwnode_emit) ((emit1_t)imp_bwnode_emit)(self, sel, sb);
}
static void hk_emit2(id self, SEL sel, void *sb, void *inp) {
    ccp_latch(&g_hit2, "com.maurice.vcam.hit2");
    ccp_strip_face((CMSampleBufferRef)sb);
    ccp_paint((CMSampleBufferRef)sb);
    if (imp_bwnode_emit2) ((emit2_t)imp_bwnode_emit2)(self, sel, sb, inp);
}
static void hk_pxt(id self, SEL sel, void *sb) {
    ccp_latch(&g_hit3, "com.maurice.vcam.hit3");
    ccp_strip_face((CMSampleBufferRef)sb);
    ccp_paint((CMSampleBufferRef)sb);
    if (imp_pixel_transfer) ((emit1_t)imp_pixel_transfer)(self, sel, sb);
}
static void hk_imgqueue(id self, SEL sel, void *sb, void *inp) {
    ccp_latch(&g_hit4, "com.maurice.vcam.hit4");
    ccp_strip_face((CMSampleBufferRef)sb);
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

    unsigned bits = 0;
    const char *snames[8] = {
        "com.maurice.vcam.s0", "com.maurice.vcam.s1", "com.maurice.vcam.s2",
        "com.maurice.vcam.s3", "com.maurice.vcam.s4", "com.maurice.vcam.s5",
        "com.maurice.vcam.s6", "com.maurice.vcam.s7",
    };
    for (int i = 0; i < 8; i++) {
        if (objc_getClass(g_survey_names[i])) {
            bits |= (1u << i);
            notify_post(snames[i]);   /* live-post, snoop muss VOR inject lauschen */
        }
    }
    atomic_store(&g_survey_bits, bits);

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