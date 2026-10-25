#import "CDVAppSchemeCORS.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kOriginsPreference = @"appschemecorsorigins"; // config.xml preference AppSchemeCorsOrigins (keys are lower-cased by Cordova)

@interface CDVAppSchemeCORS ()
/** Allowed origin patterns (lower-cased, '*' = any label); nil means every origin is allowed. */
@property (nonatomic, strong, nullable) NSArray<NSString *> *allowedOrigins;
@end

@implementation CDVAppSchemeCORS

- (void)pluginInitialize
{
    NSString *pref = [self.commandDelegate.settings objectForKey:kOriginsPreference];
    NSMutableArray *origins = [NSMutableArray array];
    for (NSString *part in [pref componentsSeparatedByString:@","]) {
        NSString *trimmed = [[part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        if (trimmed.length == 0) {
            continue;
        }
        if ([trimmed isEqualToString:@"*"]) {
            origins = nil;
            break;
        }
        [origins addObject:trimmed];
    }
    self.allowedOrigins = (origins.count > 0) ? origins : nil;
    NSLog(@"AppSchemeCORS: serving %@://… with CORS headers for %@",
          self.viewController.appScheme ?: @"app",
          self.allowedOrigins ? [self.allowedOrigins componentsJoinedByString:@", "] : @"any origin");
}

#pragma mark - CDVPluginSchemeHandler

- (BOOL)overrideSchemeTask:(id<WKURLSchemeTask>)task
{
    NSURLRequest *request = task.request;
    NSString *scheme = self.viewController.appScheme ?: @"app";
    if (![request.URL.scheme.lowercaseString isEqualToString:scheme.lowercaseString]) {
        return NO;
    }

    // Only CORS requests (they carry an Origin header) are handled here; everything else keeps
    // Cordova's default behaviour.
    NSString *origin = [request valueForHTTPHeaderField:@"Origin"];
    if (origin.length == 0 || ![self isOriginAllowed:origin]) {
        return NO;
    }

    NSString *method = request.HTTPMethod.uppercaseString ?: @"GET";
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    headers[@"Access-Control-Allow-Origin"] = origin;
    headers[@"Access-Control-Expose-Headers"] = @"Content-Length, Content-Range, Accept-Ranges, Content-Type";
    headers[@"Vary"] = @"Origin";

    if ([method isEqualToString:@"OPTIONS"]) {
        // Preflight
        NSString *requestedHeaders = [request valueForHTTPHeaderField:@"Access-Control-Request-Headers"];
        headers[@"Access-Control-Allow-Methods"] = @"GET, HEAD, OPTIONS";
        headers[@"Access-Control-Allow-Headers"] = requestedHeaders.length > 0 ? requestedHeaders : @"*";
        headers[@"Access-Control-Max-Age"] = @"86400";
        headers[@"Content-Length"] = @"0";
        [self finishTask:task statusCode:204 headers:headers body:nil];
        return YES;
    }

    if (![method isEqualToString:@"GET"] && ![method isEqualToString:@"HEAD"]) {
        return NO;
    }

    NSURL *fileURL = [self fileURLForRequestURL:request.URL];
    NSData *data = fileURL ? [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe error:nil] : nil;
    if (!data) {
        headers[@"Content-Type"] = @"text/plain";
        NSData *body = [[NSString stringWithFormat:@"Not found: %@", request.URL.path] dataUsingEncoding:NSUTF8StringEncoding];
        headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)body.length];
        [self finishTask:task statusCode:404 headers:headers body:([method isEqualToString:@"HEAD"] ? nil : body)];
        return YES;
    }

    NSInteger status = 200;
    NSUInteger total = data.length;
    NSData *body = data;
    headers[@"Content-Type"] = [self mimeTypeForURL:fileURL];
    headers[@"Accept-Ranges"] = @"bytes";
    headers[@"Cache-Control"] = @"no-cache";

    NSString *rangeHeader = [request valueForHTTPHeaderField:@"Range"];
    if ([rangeHeader hasPrefix:@"bytes="]) {
        NSArray<NSString *> *parts = [[rangeHeader substringFromIndex:6] componentsSeparatedByString:@"-"];
        NSUInteger start = (NSUInteger)[parts[0] integerValue];
        NSUInteger end = (parts.count > 1 && parts[1].length > 0) ? (NSUInteger)[parts[1] integerValue] : (total > 0 ? total - 1 : 0);
        if (total == 0 || start >= total || end < start) {
            headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes */%lu", (unsigned long)total];
            headers[@"Content-Length"] = @"0";
            [self finishTask:task statusCode:416 headers:headers body:nil];
            return YES;
        }
        if (end >= total) {
            end = total - 1;
        }
        body = [data subdataWithRange:NSMakeRange(start, end - start + 1)];
        status = 206;
        headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %lu-%lu/%lu", (unsigned long)start, (unsigned long)end, (unsigned long)total];
    }
    headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)body.length];

    [self finishTask:task statusCode:status headers:headers body:([method isEqualToString:@"HEAD"] ? nil : body)];
    return YES;
}

- (void)stopSchemeTask:(id<WKURLSchemeTask>)task
{
    // Responses are produced synchronously inside overrideSchemeTask:, nothing to cancel.
}

#pragma mark - Helpers

- (void)finishTask:(id<WKURLSchemeTask>)task statusCode:(NSInteger)status headers:(NSDictionary<NSString *, NSString *> *)headers body:(nullable NSData *)body
{
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:task.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
    [task didReceiveResponse:response];
    if (body.length > 0) {
        [task didReceiveData:body];
    }
    [task didFinish];
}

- (BOOL)isOriginAllowed:(NSString *)origin
{
    if (self.allowedOrigins == nil) {
        return YES;
    }
    NSString *candidate = origin.lowercaseString;
    for (NSString *pattern in self.allowedOrigins) {
        if ([pattern isEqualToString:candidate]) {
            return YES;
        }
        if ([pattern containsString:@"*"]) {
            NSString *escaped = [NSRegularExpression escapedPatternForString:pattern];
            NSString *regex = [NSString stringWithFormat:@"^%@$", [escaped stringByReplacingOccurrencesOfString:@"\\*" withString:@"[^./]*"]];
            if ([candidate rangeOfString:regex options:NSRegularExpressionSearch].location != NSNotFound) {
                return YES;
            }
        }
    }
    return NO;
}

/** Maps the request path onto the bundled www folder; nil when it escapes that folder. */
- (nullable NSURL *)fileURLForRequestURL:(NSURL *)url
{
    NSURL *wwwDir = [[[NSBundle mainBundle] URLForResource:self.viewController.webContentFolderName withExtension:nil] URLByStandardizingPath];
    if (!wwwDir) {
        return nil;
    }
    NSString *path = url.path;
    if (path.length == 0 || [path isEqualToString:@"/"]) {
        path = self.viewController.startPage ?: @"index.html";
    }
    NSURL *fileURL = [[wwwDir URLByAppendingPathComponent:path] URLByStandardizingPath];
    NSString *root = [wwwDir.path stringByAppendingString:@"/"];
    if (![fileURL.path hasPrefix:root]) {
        return nil; // path traversal
    }
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path isDirectory:&isDir] || isDir) {
        return nil;
    }
    return fileURL;
}

- (NSString *)mimeTypeForURL:(NSURL *)url
{
    static NSDictionary<NSString *, NSString *> *fallback;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fallback = @{
            @"js": @"text/javascript", @"mjs": @"text/javascript", @"css": @"text/css", @"json": @"application/json",
            @"map": @"application/json", @"html": @"text/html", @"htm": @"text/html", @"svg": @"image/svg+xml",
            @"woff": @"font/woff", @"woff2": @"font/woff2", @"ttf": @"font/ttf", @"otf": @"font/otf", @"eot": @"application/vnd.ms-fontobject",
            @"wasm": @"application/wasm", @"txt": @"text/plain", @"xml": @"application/xml"
        };
    });
    NSString *ext = url.pathExtension.lowercaseString;
    NSString *mime = fallback[ext];
    if (mime) {
        return mime;
    }
    if (@available(iOS 14.0, *)) {
        UTType *type = [UTType typeWithFilenameExtension:ext];
        if (type.preferredMIMEType) {
            return type.preferredMIMEType;
        }
    }
    return @"application/octet-stream";
}

@end
