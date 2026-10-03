// feedpusher.m — schreibt NV12-Frames per task_for_pid + vm_write in einen
// in cameracaptured injizierten Feed-Puffer (ccp_feed_buf/seq/w/h).
//
// Flow:
//   1. task_for_pid(pid)  (pid = cameracaptured; vorher jbctl proc_set_debugged)
//   2. dyld-Image-Enumeration im remote task -> Basis + Slide der injizierten
//      Dylib CamCaptureProbe.dylib finden sowie Adressen der exportierten
//      Symbole ccp_feed_buf / ccp_feed_seq / ccp_feed_w / ccp_feed_h.
//   3. vm_write: neue Frame-Bytes in ccp_feed_buf schreiben, dann seq++, w/h setzen.
//
// Symbol-Offsets werden hier statisch mitgegeben (stimmen ueberein mit Tweak.m
// v10; bei Aenderungen am Dylib-Layout neu extrahieren).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach/mach.h>
#include <mach-o/dyld_images.h>
#include <mach-o/loader.h>

// ---- statische Symbol-Offsets (aus dem gebauten Dylib via nm -j lesen) ----
// werden zur Laufzeit durch Bildschirm-Makefile konstant gehalten; hier Platzhalter
// die von build-deb.yml mit nm aus der local dylib befuellt werden.
#ifndef CCP_FEED_BUF_OFF
#define CCP_FEED_BUF_OFF 0
#endif
#ifndef CCP_FEED_SEQ_OFF
#define CCP_FEED_SEQ_OFF 0
#endif
#ifndef CCP_FEED_W_OFF
#define CCP_FEED_W_OFF 0
#endif
#ifndef CCP_FEED_H_OFF
#define CCP_FEED_H_OFF 0
#endif

#define FEED_SZ (640*480 + 640*480/2)

static uint64_t task_find_image(mach_port_t task, const char *name, uint64_t *slide_out) {
    task_dyld_info_data_t di;
    mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&di, &cnt) != KERN_SUCCESS)
        return 0;
    if (di.all_image_info_addr == 0) return 0;
    struct dyld_all_image_infos infos;
    vm_size_t got = 0;
    if (mach_vm_read_overwrite(task, di.all_image_info_addr, sizeof(infos),
                               (mach_vm_address_t)&infos, &got) != KERN_SUCCESS || got != sizeof(infos))
        return 0;
    uint32_t n = infos.infoArrayCount;
    if (n == 0 || n > 4096) return 0;
    uint64_t ia = infos.infoArray;
    struct dyld_image_info *arr = (struct dyld_image_info*)malloc(sizeof(*arr) * n);
    if (!arr) return 0;
    if (mach_vm_read_overwrite(task, ia, sizeof(*arr)*n, (mach_vm_address_t)arr, &got) != KERN_SUCCESS
        || got != sizeof(*arr)*n) {
        free(arr); return 0;
    }
    for (uint32_t i = 0; i < n; i++) {
        uint64_t path_addr = arr[i].imageFilePath;
        char path[512];
        vm_size_t pg = 0;
        if (mach_vm_read_overwrite(task, path_addr, sizeof(path)-1, (mach_vm_address_t)path, &pg) == KERN_SUCCESS) {
            path[pg] = 0;
            if (strstr(path, name)) {
                uint64_t base = arr[i].imageLoadAddress;
                free(arr);
                /* slide = base - preferred basis; wir brauchen absolute base. */
                if (slide_out) *slide_out = base;
                return base;
            }
        }
    }
    free(arr);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: feedpusher <pid>\n"); return 1; }
    int pid = atoi(argv[1]);

    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "task_for_pid fail: %d\n", kr); return 2; }
    printf("task_port ok (pid %d)\n", pid);

    uint64_t base = task_find_image(task, "CamCaptureProbe", NULL);
    if (!base) { fprintf(stderr, "CamCaptureProbe dylib not found in remote\n"); return 3; }
    printf("dylib base = 0x%llx\n", base);

    uint64_t buf_addr = base + CCP_FEED_BUF_OFF;
    uint64_t seq_addr = base + CCP_FEED_SEQ_OFF;
    uint64_t w_addr   = base + CCP_FEED_W_OFF;
    uint64_t h_addr   = base + CCP_FEED_H_OFF;
    printf("buf=0x%llx seq=0x%llx\n", buf_addr, seq_addr);

    /* frame-puffer anlegen: 4-Quadranten-Bild (Y)+UV neutral — aber mit
     * animateigem rotierendem Balken, damit man Bewegung sieht. */
    uint8_t frame[FEED_SZ];
    memset(frame, 128, FEED_SZ);
    uint32_t seq = 1;
    while (1) {
        for (int y = 0; y < 480; y++) {
            for (int x = 0; x < 640; x++) {
                int bar = (seq * 8) % 640;
                uint8_t v;
                if (x >= bar && x < bar + 64 + 320) {
                    v = 235;   /* heller bewegter Balken */
                } else {
                    v = (y < 240) ? ((x < 320) ? 40 : 90) : ((x < 320) ? 150 : 210);
                }
                frame[y*640 + x] = v;
            }
        }
        memset(frame + 640*480, 128, 640*480/2);

        /* writes */
        uint32_t W = 640, H = 480;
        kr = mach_vm_write(task, w_addr, (vm_offset_t)&W, sizeof(W));
        if (kr) { fprintf(stderr, "write w fail %d\n", kr); break; }
        kr = mach_vm_write(task, h_addr, (vm_offset_t)&H, sizeof(H));
        if (kr) break;
        kr = mach_vm_write(task, buf_addr, (vm_offset_t)frame, FEED_SZ);
        if (kr) { fprintf(stderr, "write buf fail %d\n", kr); break; }
        seq++;
        kr = mach_vm_write(task, seq_addr, (vm_offset_t)&seq, sizeof(seq));
        if (kr) { fprintf(stderr, "write seq fail %d\n", kr); break; }

        usleep(33000); /* ~30fps */
    }
    return 0;
}