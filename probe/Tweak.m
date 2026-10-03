#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <syslog.h>
#import <unistd.h>
#import <string.h>
#import <stdarg.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

/* v2-Daemon-Probe (cameracaptured, iOS 18 arm64e)
 * Proof-Kanal: syslog/os_log — socket-bind scheitert evtl. an temporary-sandbox.
 * ctor schreibt als ERSTES einen Marker, dann dyld-Images + ObjC-Klassen-Survey. */

static void lg(const char *fmt, ...) {
    char buf[2048];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    syslog(LOG_ERR, "%s", buf);
}

__attribute__((constructor)) void ccp_init(void) {
    syslog(LOG_ERR, "[CCP] ctor pid=%d proc=%s", getpid(),
           [[NSProcessInfo processInfo].processName UTF8String] ?: "?");

    /* Marker-Datei unter /var/tmp (mobile-sichtbar, sandbox-tolerant) */
    FILE *m = fopen("/var/tmp/ccp_ctor.txt", "a");
    if (m) { fprintf(m, "ctor pid=%d\n", getpid()); fclose(m); }

    /* dyld images gefiltert */
    uint32_t n = _dyld_image_count();
    lg("[CCP] dyld images=%u", n);
    int hits = 0;
    for (uint32_t i = 0; i < n && hits < 30; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strstr(name, "Capture") || strstr(name, "Camera") ||
            strstr(name, "CoreMedia") || strstr(name, "MediaToolbox")) {
            lg("[CCP] img[%u] %s", i, name);
            hits++;
        }
    }

    const char *cls[] = {
        "BWPixelTransferNode","BWNodeOutput","BWNode","BWGraph",
        "BWImageQueueSinkNode","BWVideoOrientationMetadataNode",
        "FigCaptureSession","FigCaptureSource","FigCaptureDevice",
        "AVCaptureSession","AVCaptureDevice", NULL
    };
    for (int i = 0; cls[i]; i++) {
        Class c = objc_getClass(cls[i]);
        if (c) {
            unsigned mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            int shown = 0;
            for (unsigned j = 0; j < mc && shown < 6; j++) {
                const char *sn = sel_getName(method_getName(ms[j]));
                if (strstr(sn, "emitSample") || strstr(sn, "PixelTransfer") ||
                    strstr(sn, "renderSample") || strstr(sn, "emitPixelBuffer")) {
                    IMP imp = method_getImplementation(ms[j]);
                    lg("[CCP] %s :: %s IMP=0x%lx", cls[i], sn, (unsigned long)(uintptr_t)imp);
                    shown++;
                }
            }
            if (ms) free(ms);
        } else {
            lg("[CCP] %s --MISSING--", cls[i]);
        }
    }
}