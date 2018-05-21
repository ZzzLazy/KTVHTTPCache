//
//  KTVHCDataSourcer.m
//  KTVHTTPCache
//
//  Created by Single on 2017/8/11.
//  Copyright © 2017年 Single. All rights reserved.
//

#import "KTVHCDataSourcer.h"
#import "KTVHCDataSourceQueue.h"
#import "KTVHCDataCallback.h"
#import "KTVHCLog.h"

@interface KTVHCDataSourcer () <NSLocking, KTVHCDataFileSourceDelegate, KTVHCDataNetworkSourceDelegate>

@property (nonatomic, strong) NSLock * coreLock;
@property (nonatomic, strong) KTVHCDataSourceQueue * sourceQueue;
@property (nonatomic, strong) id <KTVHCDataSourceProtocol> currentSource;
@property (nonatomic, strong) KTVHCDataNetworkSource * currentNetworkSource;
@property (nonatomic, assign) BOOL didCalledPrepare;
@property (nonatomic, assign) BOOL didCalledReceiveResponse;

@end

@implementation KTVHCDataSourcer

- (instancetype)initWithDelegate:(id <KTVHCDataSourcerDelegate>)delegate delegateQueue:(dispatch_queue_t)delegateQueue
{
    if (self = [super init])
    {
        _delegate = delegate;
        _delegateQueue = delegateQueue;
        self.sourceQueue = [KTVHCDataSourceQueue sourceQueue];
        KTVHCLogAlloc(self);
    }
    return self;
}

- (void)dealloc
{
    KTVHCLogDealloc(self);
    KTVHCLogDataReader(@"%p, Destory reader\nError : %@\ncurrentSource : %@\ncurrentNetworkSource : %@", self, self.error, self.currentSource, self.currentNetworkSource);
}

- (void)putSource:(id<KTVHCDataSourceProtocol>)source
{
    KTVHCLogDataSourcer(@"%p, Put source : %@", self, source);
    [self.sourceQueue putSource:source];
}

- (void)prepare
{
    [self lock];
    if (self.didClosed) {
        [self unlock];
        return;
    }
    if (self.didCalledPrepare) {
        [self unlock];
        return;
    }
    _didCalledPrepare = YES;
    KTVHCLogDataSourcer(@"%p, Call prepare", self);
    [self.sourceQueue sortSources];
    [self.sourceQueue setAllSourceDelegate:self delegateQueue:self.delegateQueue];
    self.currentSource = [self.sourceQueue fetchFirstSource];
    self.currentNetworkSource = [self.sourceQueue fetchFirstNetworkSource];
    KTVHCLogDataSourcer(@"%p, Sort source\ncurrentSource : %@\ncurrentNetworkSource : %@", self, self.currentSource, self.currentNetworkSource);
    [self.currentSource prepare];
    if (self.currentSource != self.currentNetworkSource) {
        [self.currentNetworkSource prepare];
    }
    [self unlock];
}

- (void)close
{
    [self lock];
    if (self.didClosed) {
        [self unlock];
        return;
    }
    _didClosed = YES;
    KTVHCLogDataSourcer(@"%p, Call close", self);
    [self.sourceQueue closeAllSource];
    [self unlock];
}

- (NSData *)readDataOfLength:(NSUInteger)length
{
    [self lock];
    if (self.didClosed) {
        [self unlock];
        return nil;
    }
    if (self.didFinished) {
        [self unlock];
        return nil;
    }
    if (self.error) {
        [self unlock];
        return nil;
    }
    NSData * data = [self.currentSource readDataOfLength:length];
    KTVHCLogDataSourcer(@"%p, Read data : %lld", self, (long long)data.length);
    if (self.currentSource.didFinished) {
        self.currentSource = [self.sourceQueue fetchNextSource:self.currentSource];
        if (self.currentSource) {
            KTVHCLogDataSourcer(@"%p, Switch to next source, %@", self, self.currentSource);
            if ([self.currentSource isKindOfClass:[KTVHCDataFileSource class]]) {
                [self.currentSource prepare];
            }
        } else {
            KTVHCLogDataSourcer(@"%p, Read data did finished", self);
            _didFinished = YES;
        }
    }
    [self unlock];
    return data;
}

- (void)callbackForPrepared
{
    if (self.didClosed) {
        return;
    }
    if (self.didPrepared) {
        return;
    }
    _didPrepared = YES;
    if ([self.delegate respondsToSelector:@selector(sourcerDidPrepared:)]) {
        KTVHCLogDataSourcer(@"%p, Callback for prepared - Begin", self);
        [KTVHCDataCallback callbackWithQueue:self.delegateQueue block:^{
            KTVHCLogDataSourcer(@"%p, Callback for prepared - End", self);
            [self.delegate sourcerDidPrepared:self];
        }];
    }
}

- (void)callbackForReceiveResponse:(KTVHCDataResponse *)response
{
    if (self.didClosed) {
        return;
    }
    if (self.didCalledReceiveResponse) {
        return;
    }
    _didCalledReceiveResponse = YES;
    if ([self.delegate respondsToSelector:@selector(sourcer:didReceiveResponse:)]) {
        KTVHCLogDataSourcer(@"%p, Callback for did receive response - End", self);
        [KTVHCDataCallback callbackWithQueue:self.delegateQueue block:^{
            KTVHCLogDataSourcer(@"%p, Callback for did receive response - End", self);
            [self.delegate sourcer:self didReceiveResponse:response];
        }];
    }
}

- (void)fileSourceDidPrepared:(KTVHCDataFileSource *)fileSource
{
    [self lock];
    [self callbackForPrepared];
    [self unlock];
}

- (void)networkSourceDidPrepared:(KTVHCDataNetworkSource *)networkSource
{
    [self lock];
    [self callbackForPrepared];
    [self callbackForReceiveResponse:networkSource.response];
    [self unlock];
}

- (void)networkSourceHasAvailableData:(KTVHCDataNetworkSource *)networkSource
{
    [self lock];
    if ([self.delegate respondsToSelector:@selector(sourcerHasAvailableData:)]) {
        KTVHCLogDataSourcer(@"%p, Callback for has available data - Begin\nSource : %@", self, networkSource);
        [KTVHCDataCallback callbackWithQueue:self.delegateQueue block:^{
            KTVHCLogDataSourcer(@"%p, Callback for has available data - End", self);
            [self.delegate sourcerHasAvailableData:self];
        }];
    }
    [self unlock];
}

- (void)networkSourceDidFinishedDownload:(KTVHCDataNetworkSource *)networkSource
{
    [self lock];
    self.currentNetworkSource = [self.sourceQueue fetchNextNetworkSource:self.currentNetworkSource];
    [self.currentNetworkSource prepare];
    [self unlock];
}

- (void)networkSource:(KTVHCDataNetworkSource *)networkSource didFailed:(NSError *)error
{
    [self lock];
    if (self.didClosed) {
        [self unlock];
        return;
    }
    if (self.error) {
        [self unlock];
        return;
    }
    _error = error;
    KTVHCLogDataSourcer(@"failure, %d", (int)self.error.code);
    if (self.error && [self.delegate respondsToSelector:@selector(sourcer:didFailed:)]) {
        KTVHCLogDataSourcer(@"%p, Callback for network source failed - Begin\nError : %@", self, self.error);
        [KTVHCDataCallback callbackWithQueue:self.delegateQueue block:^{
            KTVHCLogDataSourcer(@"%p, Callback for network source failed - End", self);
            [self.delegate sourcer:self didFailed:self.error];
        }];
    }
    [self unlock];
}

- (void)lock
{
    if (!self.coreLock) {
        self.coreLock = [[NSLock alloc] init];
    }
    [self.coreLock lock];
}

- (void)unlock
{
    [self.coreLock unlock];
}

@end
