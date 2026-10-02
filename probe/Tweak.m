#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <stdio.h>
#import <stdarg.h>
#import <string.h>
#import <unistd.h>
#import <pthread.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

#define LISTEN_PORT 8798

static int servfd = -1;
static char gOut[65536];
static size_t gLen = 0;

static void catf(const char *fmt, ...) {
    if (gLen >= sizeof(gOut) - 1024) return;
    va_list ap; va_start(ap, fmt);
    gLen += vsnprintf(gOut + gLen, sizeof(gOut) - gLen, fmt, ap);
    va_end(ap);
}

/* alle geladenen Mach-O-Images, gefiltert auf Kamera/Media/AV/Fig-Subsysteme */
static void dump_images(void) {
    uint32_t n = _dyld_image_count();
    catf("\n== DYLD IMAGES (%u total) ==\n", n);
    int hits = 0;
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *mh = _dyld_get_image_header(i);
        uintptr_t slide = _dyld_get_image_vmaddr_slide(i);
        if (!name) continue;
        if (strstr(name, "Capture") || strstr(name, "Camera") ||
            strstr(name, "CoreMedia") || strstr(name, "AVFoundation") ||
            strstr(name, "MediaToolbox") || strstr(name, "VideoToolbox") ||
            strstr(name, "CMCapture")) {
            catf("  %-70s hdr=%p slide=0x%lx\n", name, mh, (long)slide);
            hits++;
        }
    }
    catf("  (filtered hits: %d)\n", hits);
}

/* ObjC-Klasse: vorhanden? Methoden-Dump (emitSample/PixelTransfer/render) */
static void dump_class(const char *cn) {
    Class c = objc_getClass(cn);
    catf("%-46s %s\n", cn, c ? "PRESENT" : "--MISSING--");
    if (!c) return;
    unsigned mc = 0;
    Method *ms = class_copyMethodList(c, &mc);
    if (!ms) return;
    int shown = 0;
    for (unsigned i = 0; i < mc && shown < 8; i++) {
        const char *sn = sel_getName(method_getName(ms[i]));
        if (strstr(sn, "emitSample") || strstr(sn, "pixelTransfer") ||
            strstr(sn, "PixelTransfer") || strstr(sn, "renderSample")) {
            IMP imp = method_getImplementation(ms[i]);
            catf("    %-50s IMP=0x%016lx\n", sn, (unsigned long)(uintptr_t)imp);
            shown++;
        }
    }
    free(ms);
    catf("    (emit/pixelTransfer/render shown: %d)\n", shown);
}

static void serve(void) {
    for (;;) {
        int cfd = accept(servfd, NULL, NULL);
        if (cfd < 0) continue;
        gLen = 0;
        const char *pn = [[NSProcessInfo processInfo].processName UTF8String] ?: "?";
        catf("PROCESS=%s\nPID=%d\n", pn, getpid());

        dump_images();

        catf("\n== OBJC CLASS SURVEY ==\n");
        const char *cls[] = {
            "BWPixelTransferNode", "BWNodeOutput", "BWNode", "BWGraph",
            "BWPhotoEncoderNode", "BWImageQueueSinkNode", "BWVideoOrientationMetadataNode",
            "BWMultiStreamCameraSourceNode", "FigCaptureSession", "FigCaptureSource",
            "FigCaptureDevice", "FigCaptureDeviceVendor", "FigCaptureFrameCounter",
            "AVCaptureSession", "AVCaptureDevice", "AVCaptureVideoDataOutput",
            "AVFoundationCaptureService", NULL
        };
        for (int i = 0; cls[i]; i++) dump_class(cls[i]);

        const char hdr[] = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n";
        send(cfd, hdr, strlen(hdr), 0);
        send(cfd, gOut, gLen, 0);
        close(cfd);
    }
}

/* NICHT static — externes Linkage verhindert Dead-Strip des Konstruktors. */
__attribute__((constructor)) void ccp_init(void) {
    servfd = socket(AF_INET, SOCK_STREAM, 0);
    if (servfd < 0) return;
    int on = 1;
    setsockopt(servfd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    struct sockaddr_in a; memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(LISTEN_PORT);
    if (bind(servfd, (struct sockaddr *)&a, sizeof(a)) == 0 && listen(servfd, 8) == 0) {
        pthread_t th;
        pthread_create(&th, NULL, (void *(*)(void *))serve, NULL);
        pthread_detach(th);
    } else {
        close(servfd); servfd = -1;
    }
}