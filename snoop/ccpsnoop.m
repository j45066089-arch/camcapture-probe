// ccpsnoop.m — listen for Darwin notifications posted by the injected dylib
// in cameracaptured. Both run as mobile (uid 501) = same notify namespace.

#import <Foundation/Foundation.h>
#import <notify.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>

typedef struct { const char *name; uint32_t token; } NReg;
static NReg regs[16];
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
    int secs = (argc > 1) ? atoi(argv[1]) : 60;
    printf("SURVEY-BITS: ");
    int sk = -1;
    if (notify_register_check("com.maurice.vcam.survey", &sk) == NOTIFY_STATUS_OK) {
        uint64_t v = 0;
        if (notify_get_state(sk, &v) == NOTIFY_STATUS_OK) printf("%llu", v);
        else printf("(get-state-fail)");
    } else printf("(register-fail)");
    printf("\n");
    fflush(stdout);

    const char *names[] = {
        "com.maurice.vcam.ctor",
        "com.maurice.vcam.survey",
        "com.maurice.vcam.hit1", "com.maurice.vcam.hit2",
        "com.maurice.vcam.hit3", "com.maurice.vcam.hit4",
        "com.maurice.vcam.diag",
        NULL
    };
    regc = 0;
    for (int i = 0; names[i] && regc < 16; i++) install(names[i]);
    printf("LISTENING %d s\n", secs);
    fflush(stdout);
    sleep(secs);
    printf("DONE\n");
    return 0;
}