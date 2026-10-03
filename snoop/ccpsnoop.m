// ccpsnoop.m — Darwin notify listener for CamCaptureProbe survey.
// Runs as mobile; the daemon also runs as mobile → same notify namespace.
// Usage: ccpsnoop <seconds>   (listens, prints FIRED lines, then exits)

#import <Foundation/Foundation.h>
#import <notify.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

typedef struct { const char *name; int token; } NReg;
static NReg regs[24];
static int regc = 0;

static void install(const char *name) {
    NReg *r = &regs[regc++];
    r->name = name;
    uint32_t st = notify_register_dispatch(name, &r->token,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int t){
            printf("FIRED %s\n", r->name);
            fflush(stdout);
        });
    printf("REG %s status=%u\n", name, st);
    fflush(stdout);
}

int main(int argc, char **argv) {
    int secs = (argc > 1) ? atoi(argv[1]) : 15;
    const char *names[] = {
        "com.maurice.vcam.ctor",
        "com.maurice.vcam.s0", "com.maurice.vcam.s1", "com.maurice.vcam.s2",
        "com.maurice.vcam.s3", "com.maurice.vcam.s4", "com.maurice.vcam.s5",
        "com.maurice.vcam.s6", "com.maurice.vcam.s7",
        "com.maurice.vcam.hit1", "com.maurice.vcam.hit2",
        "com.maurice.vcam.hit3", "com.maurice.vcam.hit4",
        "com.maurice.vcam.face1", "com.maurice.vcam.face2",
        "com.maurice.vcam.meta1", "com.maurice.vcam.meta2",
        NULL
    };
    regc = 0;
    for (int i = 0; names[i] && regc < 24; i++) install(names[i]);
    printf("LISTENING %d s\n", secs);
    fflush(stdout);
    sleep(secs);
    printf("DONE\n");
    fflush(stdout);
    return 0;
}