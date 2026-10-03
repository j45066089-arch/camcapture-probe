#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <stdatomic.h>
#import <string.h>
#import <unistd.h>
#import <fcntl.h>
#import <strings.h>
#import <stdlib.h>
#import <stdio.h>

/* CamCaptureProbe v4 — v3 (full-plane fill, VERIFIZIERT) + face-metadata strip + diagnostics
 *
 * Frame-Swap: VERIFIZIERT (Kamera + Galerie komplett getauscht).
 * Offen: Gesichtstracking laeuft weiter -> SEPARATER Metadata-Feed, nicht der Pixel-Buffer.
 *
 * v4 Neuerungen:
 *   (1) im emit-Hook die Gesichts-Metadaten-Attachments strippen
 *   (2) beim ERSTEN Frame: Attachment-Keys + Pixelformat + Face/Metadata/Track-Klassen-Survey
 *       nach /var/tmp/ccp_diag.txt schreiben (Test: laesst temporary-sandbox /var/tmp-Write zu?)
 */

#define NOTIFY_FACEBIT "com.maurice.vcam.facebit"

static IMP imp_bwnode_emit    = NULL;
static IMP imp_bwnode_emit2   = NULL;
static IMP imp_pixel_transfer = NULL;
static IMP imp_imgqueue_sink  = NULL;

static _Atomic int g_hit1 = 0, g_hit2 = 0, g_hit3 = 0, g_hit4 = 0;
static _Atomic int g_diag_done = 0;

static int ccp_fd = -1;

static void ccp_w(const char *s) { if (ccp_fd >= 0) write(ccp_fd, s, strlen(s)); }
static void ccp_wl(const char *s) { ccp_w(s); ccp_w("\n"); }

/* --- v3 full-plane fill (verifiziert) --- */
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
                    if (y < half) { b = 0; g = 0; r = 255; }
                    else          { b = 255; g = 255; r = 0; }
                    for (size_t x = 0; x < (bpr >> 2); x++) {
                        row[x*4+0]=b; row[x*4+1]=g; row[x*4+2]=r; row[x*4+3]=255;
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
            size_t half = ph >> 1;
            for (size_t y = 0; y < ph; y++)
                memset(pp + y*pbpr, (p==0) ? ((y<half)?16:235) : 128, pbpr);
        }
    }
    CVPixelBufferUnlockBaseAddress(img, 0);
}

/* --- Face-/Detect-Metadaten aus dem Main-Buffer strippen --- */
static void ccp_strip_meta(CMSampleBufferRef sb) {
    if (!sb) return;
    const CFStringRef keys[] = {
        CFSTR("DetectedFaceInfo"),
        CFSTR("DetectedFacesInfo"),
        CFSTR("FacesArray"),
        CFSTR("MetadataDictionary"),
        CFSTR("FaceRectDisplayBuffer"),
    };
    for (size_t i = 0; i < sizeof(keys)/sizeof(keys[0]); i++)
        CMSetAttachment(sb, keys[i], NULL, kCMAttachmentMode_ShouldPropagate);
}

/* --- einmalige Diagnose: Attachments + Pixelformat + Klassen-Survey --- */
static void ccp_diag(CMSampleBufferRef sb) {
    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(&g_diag_done, &expected, 1,
                                                 memory_order_relaxed, memory_order_relaxed))
        return;
    char b[1024];
    ccp_wl("=== FRAME DIAG ===");
    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
    if (img) {
        snprintf(b, sizeof b, "pixfmt=0x%x planes=%zu w=%zu h=%zu",
                 (unsigned)CVPixelBufferGetPixelFormatType(img),
                 CVPixelBufferGetPlaneCount(img),
                 CVPixelBufferGetWidth(img), CVPixelBufferGetHeight(img));
        ccp_wl(b);
        for (size_t p = 0; p < CVPixelBufferGetPlaneCount(img); p++) {
            snprintf(b, sizeof b, "  plane%zu w=%zu h=%zu bpr=%zu",
                     p, CVPixelBufferGetWidthOfPlane(img,p),
                     CVPixelBufferGetHeightOfPlane(img,p),
                     CVPixelBufferGetBytesPerRowOfPlane(img,p));
            ccp_wl(b);
        }
    }
    ccp_wl("--- attachments ---");
    CFDictionaryRef atts = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sb, kCMAttachmentMode_ShouldPropagate);
    if (atts) {
        CFIndex n = CFDictionaryGetCount(atts);
        const void **keys = (const void **)malloc(sizeof(void*) * (n ? n : 1));
        CFDictionaryGetKeysAndValues(atts, keys, NULL);
        for (CFIndex i = 0; i < n; i++) {
            if (CFGetTypeID(keys[i]) == CFStringGetTypeID()) {
                snprintf(b, sizeof b, "  key=%s", [(__bridge NSString*)keys[i] UTF8String]);
                ccp_wl(b);
            }
        }
        free(keys);
        CFRelease(atts);
    }
    ccp_wl("=== CLASS SURVEY (face/meta/track/detect/vision/landmark/body) ===");
    int nc = objc_getClassList(NULL, 0);
    if (nc > 0) {
        Class *cls = (Class*)malloc(sizeof(Class)*nc);
        int got = objc_getClassList(cls, nc);
        int cnt = 0;
        for (int i = 0; i < got; i++) {
            const char *n = class_getName(cls[i]);
            if (!n) continue;
            if (strcasestr(n,"Face") || strcasestr(n,"Metadata") ||
                strcasestr(n,"Track") || strcasestr(n,"Detect") ||
                strcasestr(n,"Vision") || strcasestr(n,"landmark") ||
                strcasestr(n,"Body") || strcasestr(n,"VNImage")) {
                ccp_wl(n);
                cnt++;
            }
        }
        snprintf(b, sizeof b, "face-meta-classes-total=%d", cnt);
        ccp_wl(b);
        free(cls);
    }
    ccp_wl("=== END DIAG ===");
    notify_post("com.maurice.vcam.diag");
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
    ccp_strip_meta((CMSampleBufferRef)sb);
    ccp_diag((CMSampleBufferRef)sb);
    ccp_paint((CMSampleBufferRef)sb);
    if (imp_bwnode_emit) ((emit1_t)imp_bwnode_emit)(self, sel, sb);
}
static void hk_emit2(id self, SEL sel, void *sb, void *inp) {
    ccp_latch(&g_hit2, "com.maurice.vcam.hit2");
    ccp_strip_meta((CMSampleBufferRef)sb);
    ccp_diag((CMSampleBufferRef)sb);
    ccp_paint((CMSampleBufferRef)sb);
    if (imp_bwnode_emit2) ((emit2_t)imp_bwnode_emit2)(self, sel, sb, inp);
}
static void hk_pxt(id self, SEL sel, void *sb) {
    ccp_latch(&g_hit3, "com.maurice.vcam.hit3");
    ccp_strip_meta((CMSampleBufferRef)sb);
    ccp_diag((CMSampleBufferRef)sb);
    ccp_paint((CMSampleBufferRef)sb);
    if (imp_pixel_transfer) ((emit1_t)imp_pixel_transfer)(self, sel, sb);
}
static void hk_imgqueue(id self, SEL sel, void *sb, void *inp) {
    ccp_latch(&g_hit4, "com.maurice.vcam.hit4");
    ccp_strip_meta((CMSampleBufferRef)sb);
    ccp_diag((CMSampleBufferRef)sb);
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
    ccp_fd = open("/var/tmp/ccp_diag.txt", O_CREAT|O_TRUNC|O_WRONLY, 0644);
    if (ccp_fd < 0) {
        /* /var/tmp write blockt -> 2. Versuch /tmp */
        ccp_fd = open("/tmp/ccp_diag.txt", O_CREAT|O_TRUNC|O_WRONLY, 0644);
    }
    ccp_wl("CTOR\n");

    /* welche face/metadata node existiert -> binär-Survey in die Diag-Datei */
        {
            const char *fc[] = {
                "BWFaceDetectionNode", "BWMetadataSourceNode", "FigCaptureMetadata",
                "FigFaceDetect", "BWFaceSegmentation", "BWFaceIntelligenceEstimator",
                "AVCaptureMetadataOutput", "AVCaptureSession", NULL
            };
            ccp_wl("--- face/meta nodes ---");
            for (int i = 0; fc[i]; i++) {
                char b[256];
                snprintf(b, sizeof b, "%s%s", fc[i], objc_getClass(fc[i]) ? " = PRESENT" : " = missing");
                ccp_wl(b);
            }
            notify_post(NOTIFY_FACEBIT);
        }

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