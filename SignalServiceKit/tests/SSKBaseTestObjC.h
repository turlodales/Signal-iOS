//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import <SignalServiceKit/MockSSKEnvironment.h>
#import <XCTest/XCTest.h>

NS_ASSUME_NONNULL_BEGIN

@class SDSAnyReadTransaction;
@class SDSAnyWriteTransaction;

#ifdef DEBUG

@interface SSKBaseTestObjC : XCTestCase

- (void)readWithBlock:(void (^)(SDSAnyReadTransaction *transaction))block;
- (void)writeWithBlock:(void (^)(SDSAnyWriteTransaction *transaction))block;

@end

#endif

NS_ASSUME_NONNULL_END
