//
//  OCTBlockPlugin.h
//  OCTWebViewBridge
//
//  Created by Octree on 2017/3/2.
//  Copyright © 2017年 Octree. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "OCTWebViewPlugin.h"

@interface OCTBlockPlugin : NSObject <OCTWebViewPlugin>

@property (copy, nonatomic, readonly) NSString *identifier;
@property (copy, nonatomic, readonly) NSString *javascriptCode;

- (instancetype)initWithFunctionName:(NSString *)functionName handler:(void(^)(NSDictionary *data))block;
- (instancetype)initWithFunctionName:(NSString *)functionName handlerWithResponseBlock:(void(^)(NSDictionary *data, OCTResponseCallback responseCallback))block;


@end
