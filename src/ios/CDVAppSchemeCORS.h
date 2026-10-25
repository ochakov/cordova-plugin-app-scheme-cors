#import <Cordova/CDV.h>
#import <WebKit/WebKit.h>

/**
 * Serves files from the bundled www folder over the cordova-ios custom scheme
 * (app://localhost/...) with CORS headers for requests that carry an Origin header,
 * so a page loaded from a remote server can fetch local assets and fonts.
 * Requests without an Origin header are left to Cordova's own scheme handler.
 */
@interface CDVAppSchemeCORS : CDVPlugin <CDVPluginSchemeHandler>

- (BOOL)overrideSchemeTask:(id<WKURLSchemeTask>)task;
- (void)stopSchemeTask:(id<WKURLSchemeTask>)task;

@end
