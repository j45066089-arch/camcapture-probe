#include <substrate.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <objc/runtime.h>
#include <pthread.h>

#define LISTEN_PORT 8798

static int servfd = -1;

// Ein Client annehmen, Ergebnis liefern, zu machen.
static void serve_classes(void) {
    for (;;) {
        int c = accept(servfd, NULL, NULL);
        if (c < 0) continue;
        const char *header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n";
        send(c, header, strlen(header), 0);
        char buf[4096];

        // Prozess-Info zuerst (beweist ob wir in cameracaptured sind)
        const char *pn = [[NSProcessInfo processInfo].processName UTF8String];
        snprintf(buf, sizeof(buf), "PROCESS=%s\nPID=%d\n\n", pn ? pn : "?", getpid());
        send(c, buf, strlen(buf), 0);

        const char *classes[] = {
            "BWGraph", "BWNode", "BWNodeOutput", "BWNodeInput",
            "BWPixelTransferNode", "BWPhotoEncoderNode",
            "BWMetadataSourceNode", "BWVideoOrientationMetadataNode",
            "BWMetadataDetectorGatingNode", "BWStillImageScalerNode",
            "BWMultiStreamCameraSourceNode", "BWImageQueueSinkNode",
            "FigCaptureClientSessionMonitor", "FigCaptureSession",
            "FigCaptureDeviceVendor", "FigCaptureFrameCounter",
            "FigCaptureSource", "FigCaptureDevice",
            "BWVideoDataOutput", "BWImageQueueSinkNode",

            "AVCapturePhotoOutput", "AVCaptureVideoDataOutput",
            "AVCaptureMetadataOutput", "AVCaptureDepthDataOutput",
            "AVCaptureVideoPreviewLayer", "AVCaptureSession",
            "AVCaptureDevice",

            "FBSOrientationUpdate",
            NULL
        };
        for (int i = 0; classes[i]; i++) {
            id cls = objc_getClass(classes[i]);
            snprintf(buf, sizeof(buf), "%-42s %s\n", classes[i],
                     cls ? "PRESENT" : "--missing--");
            send(c, buf, strlen(buf), 0);
        }

        // Methoden von BWNodeOutput / BWPixelTransferNode listen (wie v2-Probe)
        snprintf(buf, sizeof(buf), "\n--- BWNodeOutput methods ---\n");
        send(c, buf, strlen(buf), 0);
        Class cNO = objc_getClass("BWNodeOutput");
        if (cNO) {
            unsigned int n = 0;
            Method *ms = class_copyMethodList(cNO, &n);
            for (unsigned int i = 0; i < n; i++) {
                const char *nm = sel_getName(method_getName(ms[i]));
                if (strstr(nm, "SampleBuffer") || strstr(nm, "emit") ||
                    strstr(nm, "render") || strstr(nm, "Output") ||
                    strstr(nm, "mark") || strstr(nm, "copy") ||
                    strstr(nm, "getFrame") || strstr(nm, "next")) {
                    snprintf(buf, sizeof(buf), "  %s\n", nm);
                    send(c, buf, strlen(buf), 0);
                }
            }
            free(ms);
        }

        snprintf(buf, sizeof(buf), "\n--- BWPixelTransferNode methods ---\n");
        send(c, buf, strlen(buf), 0);
        Class cPT = objc_getClass("BWPixelTransferNode");
        if (cPT) {
            unsigned int n = 0;
            Method *ms = class_copyMethodList(cPT, &n);
            for (unsigned int i = 0; i < n; i++) {
                const char *nm = sel_getName(method_getName(ms[i]));
                if (strstr(nm, "render") || strstr(nm, "SampleBuffer") ||
                    strstr(nm, "Pixel") || strstr(nm, "Transfer")) {
                    snprintf(buf, sizeof(buf), "  %s\n", nm);
                    send(c, buf, strlen(buf), 0);
                }
            }
            free(ms);
        }

        snprintf(buf, sizeof(buf), "\n--- class_copyMethodList(BWNodeOutput) full count ---\n");
        send(c, buf, strlen(buf), 0);
        if (cNO) {
            unsigned int n = 0;
            Method *ms = class_copyMethodList(cNO, &n);
            snprintf(buf, sizeof(buf), "BWNodeOutput total methods: %u\n", n);
            send(c, buf, strlen(buf), 0);
            free(ms);
        }
        close(c);
    }
}

__attribute__((constructor))
static void probe_ctor(void) {
    // dlopen der Capture-Frameworks (wie v2-cctor)
    dlopen("/System/Library/PrivateFrameworks/CMCaptureCore.framework/CMCaptureCore", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);

    // Loopback-TCP-Beweis: binden
    servfd = socket(AF_INET, SOCK_STREAM, 0);
    if (servfd < 0) return;
    int on = 1;
    setsockopt(servfd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(LISTEN_PORT);
    if (bind(servfd, (struct sockaddr *)&a, sizeof(a)) != 0) {
        close(servfd);
        servfd = -1;
        return;
    }
    listen(servfd, 8);
    // einfacher Thread für accept-schleife
    pthread_t th;
    pthread_create(&th, NULL, (void *(*)(void *))serve_classes, NULL);
    pthread_detach(th);
}