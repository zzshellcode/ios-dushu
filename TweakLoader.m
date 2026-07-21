@import Darwin;
@import MachO;
#include <mach-o/ldsyms.h>

extern pthread_t pthread_main_thread_np(void);
extern void _pthread_set_self(pthread_t p);

static int (*_close)(int);
static void* (*_dlsym)(void *, const char *);
static uint8_t* (*_getsectiondata)(const struct mach_header_64 *, const char *, const char *, unsigned long *);
static thread_t (*_mach_thread_self)(void);
static int (*_open)(const char *, int, ...);
static void (*__pthread_set_self)(pthread_t p);
static pthread_t (*_pthread_main_thread_np)(void);
static kern_return_t (*_thread_terminate)(mach_port_t);
static int (*_write)(int, const void *, size_t);

int dyld_lv_bypass_init(void * (*_dlsym)(void* handle, const char* symbol), const char *next_stage_dylib_path);

static void write_marker(const char *name) {
    char path[128];
    int n = snprintf(path, sizeof(path), "/tmp/.tl_%s", name);
    if (n < 0) return;
    int fd = _open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) return;
    _write(fd, "1", 1);
    _close(fd);
}

static int try_dlopen_direct(const char *path) {
    void *(*fn_dlopen)(const char *, int) = _dlsym(RTLD_DEFAULT, "dlopen");
    char *(*fn_dlerror)(void) = _dlsym(RTLD_DEFAULT, "dlerror");
    if (!fn_dlopen) return -1;
    void *h = fn_dlopen(path, RTLD_NOW);
    if (h) { write_marker("dlopen_ok"); return 0; }
    write_marker("dlopen_fail");
    return -1;
}

const char *save_actual_dylib(void) {
    const char *path = "/tmp/actual.dylib";
    size_t dylib_size = 0;
    const char *dylib = (const char *)_getsectiondata(
        (struct mach_header_64 *)&_mh_dylib_header, "__TEXT", "__SBTweak", &dylib_size);
    if (!dylib || dylib_size == 0) { write_marker("nosection"); return NULL; }

    int fd = _open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) { write_marker("nofile"); return NULL; }

    ssize_t written = _write(fd, dylib, dylib_size);
    _close(fd);
    if (written != (ssize_t)dylib_size) { write_marker("writefail"); return NULL; }
    return path;
}

#if __arm64e__
__attribute__((noinline)) void *pacia(void* ptr, uint64_t ctx) {
    __asm__("xpaci %[value]\n" : [value] "+r"(ptr));
    __asm__("pacia %0, %1" : "+r"(ptr) : "r"(ctx));
    return ptr;
}
#endif

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

    _close = _dlsym(RTLD_DEFAULT, "close");
    _getsectiondata = _dlsym(RTLD_DEFAULT, "getsectiondata");
    _mach_thread_self = _dlsym(RTLD_DEFAULT, "mach_thread_self");
    _open = _dlsym(RTLD_DEFAULT, "open");
    _thread_terminate = _dlsym(RTLD_DEFAULT, "thread_terminate");
    _write = _dlsym(RTLD_DEFAULT, "write");

    write_marker("start");

    const char *path = save_actual_dylib();
    if (!path) {
        write_marker("nosavedylib");
        _thread_terminate(_mach_thread_self());
        return 1;
    }

    write_marker("saved");

    // Try dlopen directly first (works if Library Validation is off)
    if (try_dlopen_direct(path) == 0) {
        write_marker("ok_direct");
        _thread_terminate(_mach_thread_self());
        return 0;
    }
    write_marker("need_bypass");

    // Fallback: dyld LV bypass then dlopen
    dyld_lv_bypass_init(_dlsym, path);

    write_marker("done");
    _thread_terminate(_mach_thread_self());
    return 0;
}
