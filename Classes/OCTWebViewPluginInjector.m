//
//  OCTWebViewBridge.m
//  OCTWebViewBridge
//
//  Created by Octree on 2017/3/2.
//  Copyright © 2017年 Octree. All rights reserved.
//

#import "OCTWebViewPluginInjector.h"
#import "OCTWebViewPlugin.h"
#import "OCTBlockPlugin.h"
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "OCTCSSInjectionPlugin.h"

/**
 *  WKScriptMessageHandler Name
 */
NSString *const kOCTMessageName = @"bridge";
/**
 *  Bridge Identifier
 */
NSString *const kOCTMessageIdentifierKey = @"identifier";
/**
 *  Message.body.selector
 */
NSString *const kOCTMessageSelectorKey = @"selector";
/**
 *  Message.body.args
 */
NSString *const kOCTMessageArgsKey = @"args";
/**
 *  Native 异步执行后向 Web 返回数据
 */
NSString *const kOCTMessageCallbackIdKey = @"callbackId";


/**
 *  仅让 WebView 持有 Injector 的强引用，随 WebView 一起释放
 *  不求同年同月同日生，但求同年同月同日死。
 */

@interface WKWebView (OCTInjectorHolder)

@property (strong, nonatomic) OCTWebViewPluginInjector *injector;

@end


@interface OCTWebViewPluginInjector ()<WKScriptMessageHandler>

@property (weak, nonatomic) WKWebView *webView;
@property (strong, nonatomic) NSMutableDictionary *pluginMap;
@property (copy, nonatomic, readonly) NSString *messageJavascriptCode;
/**
 *  Callback Block 的强引用，防止提前释放
 */
@property (strong, nonatomic) NSMutableDictionary *callbackMap;
@property (strong, nonatomic) OCTCSSInjectionPlugin *cssInjector;

@end

@implementation OCTWebViewPluginInjector

#pragma mark - Life Cycle

+ (instancetype)injectorForWebView:(WKWebView *)webView {

    if (!webView) {
        return nil;
    }
    
    OCTWebViewPluginInjector *injector = webView.injector;
    if (!injector) {
        
        injector = [[OCTWebViewPluginInjector alloc] initWithWebView:webView];
        webView.injector = injector;
    }
    
    return injector;
}

- (instancetype)initWithWebView:(WKWebView *)webView {
    
    if (self = [super init]) {
        
        _webView = webView;
        [_webView.configuration.userContentController addScriptMessageHandler:self name:kOCTMessageName];
        [self injectCorePlugin];
    }
    return self;
}


#pragma mark - Public Method

- (void)injectPlugin:(id<OCTWebViewPlugin>)plugin {
    
    NSParameterAssert(plugin.identifier != nil);
    NSParameterAssert(plugin.javascriptCode != nil);
    
    self.pluginMap[plugin.identifier] = plugin;
    [self injectJavascriptCode:plugin.javascriptCode
                 injectionTime:[self userScriptInjectionTimeForPlugin:plugin]
              forMainFrameOnly:NO];
}

- (void)injectPluginWithFunctionName:(NSString *)functionName handler:(void(^)(NSDictionary *data))block {

    OCTBlockPlugin *plugin = [[OCTBlockPlugin alloc] initWithFunctionName:functionName handler:block];
    [self injectPlugin:plugin];
}


- (void)injectPluginWithFunctionName:(NSString *)functionName handlerWithResponseBlock:(void(^)(NSDictionary *data, OCTResponseCallback responseCallback))block {

    OCTBlockPlugin *plugin = [[OCTBlockPlugin alloc] initWithFunctionName:functionName handlerWithResponseBlock:block];
    [self injectPlugin:plugin];
}


- (void)removePluginForIdentifier:(NSString *)identifier {

    NSParameterAssert(identifier != nil);
    [self.pluginMap removeObjectForKey:identifier];
    [self reinjectPlugins];
}

- (void)removeAllPlugins {

    self.pluginMap = nil;
    [self.webView.configuration.userContentController removeAllUserScripts];
}


- (void)injectCSSString:(NSString *)cssString forIdentifier:(NSString *)identifier {

    [self.cssInjector injectCSSString:cssString forIdentifier:identifier];
}

- (void)removeCSSStringForIdentifier:(NSString *)identifier {

    [self.cssInjector removeCSSStringForIdentifier:identifier];
}

#pragma mark - Private Method

- (void)reinjectPlugins {

    WKUserContentController *controller = self.webView.configuration.userContentController;
    [controller removeAllUserScripts];
    [self injectCorePlugin];
    
    for (id<OCTWebViewPlugin> plugin in self.pluginMap.allValues) {
        
        [self injectJavascriptCode:plugin.javascriptCode
                     injectionTime:[self userScriptInjectionTimeForPlugin:plugin]
                  forMainFrameOnly:NO];
    }
}

- (WKUserScriptInjectionTime)userScriptInjectionTimeForPlugin:(id<OCTWebViewPlugin>)plugin {

    if ([plugin respondsToSelector:@selector(injectionTime)]) {
        
        return (WKUserScriptInjectionTime)plugin.injectionTime;
    }
    
    return WKUserScriptInjectionTimeAtDocumentEnd;
}

- (void)injectCorePlugin {

    [self injectJavascriptCode:self.messageJavascriptCode injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
    [self injectPlugin:self.cssInjector];
}

- (void)injectJavascriptCode:(NSString *)jscode injectionTime:(WKUserScriptInjectionTime)time forMainFrameOnly:(BOOL)flag {
    
    WKUserScript *script = [[WKUserScript alloc] initWithSource:jscode injectionTime:time forMainFrameOnly:flag];
    [self.webView.configuration.userContentController addUserScript:script];
}

- (void)invokeWithCommands:(NSDictionary *)commands {
    
    NSString *identifier = commands[kOCTMessageIdentifierKey];
    if (!identifier) {
        return;
    }
    
    id obj = self.pluginMap[identifier];
    if (!obj) {
        return;
    }
    
    id selector = commands[kOCTMessageSelectorKey];
    if (!selector || ![selector isKindOfClass:[NSString class]]) {
        
        return;
    }
    
    id args = commands[kOCTMessageArgsKey];
    if (![args isKindOfClass:[NSArray class]]) {
        return;
    }
    
    NSInteger callbackId = [commands[kOCTMessageCallbackIdKey] integerValue];
    [self invokeWithBridgeObj:obj selector:selector args:args callbackId:callbackId];
}

- (void)invokeWithBridgeObj:(id<OCTWebViewPlugin>)obj selector:(NSString *)selector args:(NSArray *)args callbackId:(NSInteger)callbackId {
    
    SEL sel = NSSelectorFromString(selector);
    NSMethodSignature *signature = [[obj class] instanceMethodSignatureForSelector:sel];
    
    if (!signature) {
        NSLog(@"%@ has no selector: %@", NSStringFromClass([obj class]), selector);
        return;
    }
    
    NSInteger selectorArgsCount = [signature numberOfArguments] - 2;
    
    NSInteger jsArgsCount = args.count + (callbackId >= 0 ? 1: 0);
    
    NSString *lastObjType = [NSString stringWithCString:[signature getArgumentTypeAtIndex:selectorArgsCount + 1] encoding:NSUTF8StringEncoding];
    //   参考 type encoding
    if (![lastObjType isEqualToString:@"@?"] && callbackId > 0) {
        
        NSLog(@"JS Invoke - class: %@, selector: %@, js need callback，but this fucking selector does not support", NSStringFromClass([obj class]), selector);
        return;
    }
    
    if (jsArgsCount != selectorArgsCount) {
        
        NSLog(@"JS Invoke - class: %@, selector: %@，args count not match", NSStringFromClass([obj class]), selector);
        return;
    }
    
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = obj;
    invocation.selector = sel;
    
    NSInteger index = 2;
    for (id obj in args) {
        
        [invocation setArgument:(void *)&obj atIndex:index];
        index++;
    }
    
    if (callbackId >= 0) {
        
        __weak __typeof(self) wself = self;
        
        NSString *identifier = [[self class] generateCallbackIdentifier];
        OCTResponseCallback callback = ^void(NSDictionary *param) {
            __strong __typeof(wself) sself = wself;
            [sself invokeCallbackWithId:callbackId param:param];
            
            [self.callbackMap removeObjectForKey:identifier];
        };
        self.callbackMap[identifier] = callback;
        [invocation setArgument:(void *)&callback atIndex:index];
    }
    
    [invocation invoke];
}


- (void)invokeCallbackWithId:(NSInteger)callbackId param:(NSDictionary *)param {
    
    NSString *json = @"null";
    if (param) {
        NSError *error;
        NSData *data = [NSJSONSerialization dataWithJSONObject:param options:NSJSONWritingPrettyPrinted error:&error];
        if (!error) {
            json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
    }
    
    NSString *code = [NSString stringWithFormat:@"window.bridge.callback.invoke(%zd, %@)", callbackId, json];
    [self.webView evaluateJavaScript:code completionHandler:nil];
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
   
    if (![message.name isEqualToString:kOCTMessageName]) {
        
        return;
    }
    
    if ([message.body isKindOfClass:[NSDictionary class]]) {
        
        [self invokeWithCommands:message.body];
    }
}


#pragma mark - Accessor

- (NSMutableDictionary *)callbackMap {
    
    if (!_callbackMap) {
        
        _callbackMap = [NSMutableDictionary dictionary];
    }
    
    return _callbackMap;
}

- (NSMutableDictionary *)pluginMap {
    
    if (!_pluginMap) {
        
        _pluginMap = [NSMutableDictionary dictionary];
    }
    
    return _pluginMap;
}

- (NSString *)messageJavascriptCode {
    
    NSString *path = [[NSBundle bundleForClass:[self class]] pathForResource:@"message" ofType:@"js"];
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
}


+ (NSString *)generateCallbackIdentifier {

    static NSInteger count = 0;
    
    return [NSString stringWithFormat:@"%zd", count++];
}

- (OCTCSSInjectionPlugin *)cssInjector {

    if (!_cssInjector) {
        
        _cssInjector = [[OCTCSSInjectionPlugin alloc] initWithWebView:self.webView];
    }
    
    return _cssInjector;
}

@end



@implementation WKWebView (OCTInjectorHolder)

static void *kOCTWebViewPluginInjectorKey = "kOCTWebViewPluginInjectorKey";

- (void)setInjector:(OCTWebViewPluginInjector *)injector {
    
    return objc_setAssociatedObject(self, kOCTWebViewPluginInjectorKey, injector, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (OCTWebViewPluginInjector *)injector {
    
    return objc_getAssociatedObject(self, kOCTWebViewPluginInjectorKey);
}

@end
