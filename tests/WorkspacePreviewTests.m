// Runs production lifecycle code with in-memory streams and content callbacks.
// No NSApplication, windows, defaults, display inventory or real capture.
#import "WorkspacePreview.h"
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

@interface YMPreviewSource : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic) CGDirectDisplayID displayID;
@property(nonatomic) SCStream *stream;
@property(nonatomic) NSHashTable<CALayer *> *layers;
@property(nonatomic) id latest;
@property(atomic) NSUInteger generation;
@property(nonatomic, copy) void (^onFailure)(YMPreviewSource *, NSError *);
- (void)start;
- (void)stop;
- (void)attachLayer:(CALayer *)layer;
- (void)publishContents:(id)contents generation:(NSUInteger)generation;
- (void)enqueueContents:(id)contents;
@end
@interface YMWorkspacePreview (LifecycleTesting)
@property(nonatomic) NSArray<NSDictionary *> *displays;
@property(nonatomic) NSMutableDictionary<NSNumber *, YMPreviewSource *> *sources;
@property(nonatomic) BOOL retryScheduled;
@property(nonatomic) NSUInteger retries;
- (instancetype)initWithEnabled:(BOOL)enabled;
- (void)fetchShareableContentWithCompletion:(void (^)(SCShareableContent *, NSError *))completion;
- (YMPreviewSource *)sourceForDisplay:(SCDisplay *)display;
- (void)startMissingSources;
- (void)sourceFailed:(YMPreviewSource *)source;
- (void)scheduleRetry;
- (NSString *)statusForDisplayID:(NSNumber *)ident;
@end

static void YMCheck(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void YMDrainMainQueue(void) {
    __block BOOL done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (!done && deadline.timeIntervalSinceNow > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, true);
    YMCheck(done, @"main queue drained");
}
static id YMTestImage(void) {
    unsigned char pixel[4] = {255, 255, 255, 255};
    CFDataRef data = CFDataCreate(NULL, pixel, sizeof(pixel));
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(1, 1, 8, 32, 4, color, (CGBitmapInfo)kCGImageAlphaPremultipliedLast, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(color);
    CGDataProviderRelease(provider);
    CFRelease(data);
    return CFBridgingRelease(image);
}

@interface YMFakePreviewStream : NSObject
@property(nonatomic) NSUInteger starts;
@property(nonatomic) NSUInteger stops;
@property(nonatomic) BOOL failStart;
@property(nonatomic) BOOL failOutput;
@end
@implementation YMFakePreviewStream
- (BOOL)addStreamOutput:(id)output type:(SCStreamOutputType)type sampleHandlerQueue:(dispatch_queue_t)queue error:(NSError **)error {
    (void)output; (void)type; (void)queue;
    if (self.failOutput && error) *error = [NSError errorWithDomain:@"test" code:1 userInfo:nil];
    return !self.failOutput;
}
- (void)startCaptureWithCompletionHandler:(void (^)(NSError *))completion {
    self.starts += 1;
    completion(self.failStart ? [NSError errorWithDomain:@"test" code:2 userInfo:nil] : nil);
}
- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))completion {
    self.stops += 1;
    // Even an error while stopping must leave all frames cleared.
    completion([NSError errorWithDomain:@"test" code:3 userInfo:nil]);
}
@end

@interface YMTestPreview : YMWorkspacePreview
@property(nonatomic, copy) void (^pendingContent)(SCShareableContent *, NSError *);
@property(nonatomic) NSUInteger fetchCount;
@property(nonatomic) NSUInteger createdCount;
@end
@implementation YMTestPreview
- (void)fetchShareableContentWithCompletion:(void (^)(SCShareableContent *, NSError *))completion {
    self.fetchCount += 1;
    self.pendingContent = completion;
}
- (YMPreviewSource *)sourceForDisplay:(SCDisplay *)display {
    (void)display;
    self.createdCount += 1;
    return [[YMPreviewSource alloc] init];
}
- (void)rebuildDock { }
- (void)bindLayers { }
- (void)updatePreviewStatus { }
@end

static YMPreviewSource *YMSourceWithFrame(YMFakePreviewStream **streamOut, CALayer **layerOut) {
    YMPreviewSource *source = [[YMPreviewSource alloc] init];
    source.displayID = 123;
    YMFakePreviewStream *stream = [[YMFakePreviewStream alloc] init];
    source.stream = (SCStream *)stream;
    CALayer *layer = [CALayer layer];
    [source attachLayer:layer];
    [source publishContents:YMTestImage() generation:source.generation];
    YMCheck(source.latest != nil && layer.contents != nil, @"fixture presents a current frame");
    *streamOut = stream;
    *layerOut = layer;
    return source;
}

int main(void) {
    @autoreleasepool {
        YMFakePreviewStream *stream;
        CALayer *layer;
        YMPreviewSource *source = YMSourceWithFrame(&stream, &layer);
        stream.failStart = YES;
        __block NSUInteger failures = 0;
        source.onFailure = ^(YMPreviewSource *failed, NSError *error) {
            YMCheck(failed.latest == nil && layer.contents == nil && error != nil, @"failure callback observes cleared frames");
            failures += 1;
        };
        [source start];
        [source start];
        [source enqueueContents:YMTestImage()];
        YMDrainMainQueue();
        YMCheck(failures == 1 && stream.starts == 1 && stream.stops == 1, @"start failure stops once and notifies owner once");
        YMCheck(source.latest == nil && layer.contents == nil, @"queued frame cannot revive failed capture");
        [source start];
        YMCheck(stream.starts == 1, @"failed source cannot start again");

        source = YMSourceWithFrame(&stream, &layer);
        stream.failOutput = YES;
        [source start];
        YMCheck(stream.starts == 0 && source.latest == nil && layer.contents == nil, @"output registration failure clears without starting capture");

        source = YMSourceWithFrame(&stream, &layer);
        source.stream = nil;
        [source start];
        YMCheck(source.latest == nil && layer.contents == nil, @"missing stream fails instead of caching a stalled preview");

        source = YMSourceWithFrame(&stream, &layer);
        NSUInteger oldGeneration = source.generation;
        [source enqueueContents:YMTestImage()];
        [source stop];
        [source publishContents:YMTestImage() generation:oldGeneration];
        YMDrainMainQueue();
        YMCheck(source.latest == nil && layer.contents == nil && source.layers.count == 0, @"stop invalidates pending and stale frames");
        [source attachLayer:layer];
        YMCheck(layer.contents == nil && source.layers.count == 0, @"stopped source cannot reattach an old picture");

        source = YMSourceWithFrame(&stream, &layer);
        YMTestPreview *preview = [[YMTestPreview alloc] initWithEnabled:YES];
        preview.displays = @[@{@"displayID": @123, @"name": @"Test"}];
        preview.sources[@123] = source;
        __weak YMTestPreview *weakPreview = preview;
        source.onFailure = ^(YMPreviewSource *failed, NSError *error) { (void)error; [weakPreview sourceFailed:failed]; };
        [source stream:(SCStream *)stream didStopWithError:[NSError errorWithDomain:@"test" code:4 userInfo:nil]];
        YMDrainMainQueue();
        YMCheck(source.latest == nil && layer.contents == nil && preview.sources[@123] == nil, @"stream error clears frame and removes cached source");
        YMCheck(preview.retryScheduled && preview.retries == 1, @"stream error schedules one retry");
        for (NSUInteger attempt = 0; attempt < 20; attempt++) {
            preview.retryScheduled = NO;
            [preview scheduleRetry];
        }
        YMCheck(preview.retries == 10 && !preview.retryScheduled, @"retry budget is bounded");
        YMCheck([[preview statusForDisplayID:@123] isEqualToString:@"预览不可用"], @"exhausted retry is visibly unavailable");
        [preview invalidate];

        preview = [[YMTestPreview alloc] initWithEnabled:YES];
        preview.displays = @[@{@"displayID": @123, @"name": @"Test"}];
        [preview startMissingSources];
        [preview startMissingSources];
        YMCheck(preview.fetchCount == 1, @"parallel reconciliation does not duplicate content requests");
        void (^pending)(SCShareableContent *, NSError *) = preview.pendingContent;
        source = YMSourceWithFrame(&stream, &layer);
        preview.sources[@123] = source;
        [source enqueueContents:YMTestImage()];
        [preview invalidate];
        // Non-nil is sufficient: stale callback must return before inspecting content.
        pending((SCShareableContent *)[[NSObject alloc] init], nil);
        [preview startMissingSources];
        [preview setEnabled:YES];
        YMDrainMainQueue();
        YMCheck(preview.createdCount == 0 && preview.fetchCount == 1 && preview.sources.count == 0, @"invalidation rejects pending fetch and later starts");
        YMCheck(source.latest == nil && layer.contents == nil, @"controller invalidation rejects queued frames");
        printf("WorkspacePreviewTests: PASS (capture failures, stale frames, cache eviction, bounded retries, invalidation)\n");
    }
    return 0;
}
