#import "WorkspacePreview.h"
#import "VDVirtualDisplay.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>

static NSString *const YMPreviewEnabledKey = @"YMWorkspacePreviewEnabled";
static NSString *const YMPreviewPiPFrameKey = @"YMWorkspacePreviewPiPFrame";
static const CGFloat YMTabWidth = 14, YMTabHeight = 54, YMTabGap = 6;
static const CGFloat YMCardWidth = 232, YMCardHeight = 130.5, YMCardGap = 12, YMDockPad = 14;

static BOOL YMReduceMotion(void) { return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion; }
static void YMAnimate(NSTimeInterval duration, void (^changes)(void), void (^_Nullable done)(void)) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = YMReduceMotion() ? 0 : duration;
        context.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.9 :0.25 :1];
        context.allowsImplicitAnimation = YES;
        changes();
    } completionHandler:done];
}
static void YMSetContents(CALayer *layer, id contents) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.contents = contents;
    [CATransaction commit];
}


// Where a display's picture actually sits inside an aspect-fit layer.
static CGRect YMAspectFitRect(CGSize content, CGRect bounds) {
    if (content.width <= 0 || content.height <= 0 || bounds.size.width <= 0 || bounds.size.height <= 0) return bounds;
    CGFloat scale = MIN(bounds.size.width / content.width, bounds.size.height / content.height);
    CGSize size = CGSizeMake(content.width * scale, content.height * scale);
    return CGRectMake(CGRectGetMidX(bounds) - size.width / 2, CGRectGetMidY(bounds) - size.height / 2, size.width, size.height);
}
static void YMAddRipple(CALayer *host, CGPoint at, CGFloat radius) {
    if (!host) return;
    CAShapeLayer *ring = [CAShapeLayer layer];
    CGPathRef path = CGPathCreateWithEllipseInRect(CGRectMake(-radius, -radius, radius * 2, radius * 2), NULL);
    ring.path = path;
    CGPathRelease(path);
    ring.position = at;
    ring.fillColor = [NSColor colorWithSRGBRed:0.898 green:0.282 blue:0.302 alpha:0.22].CGColor;
    ring.strokeColor = [NSColor colorWithSRGBRed:0.898 green:0.282 blue:0.302 alpha:1].CGColor;
    ring.lineWidth = MAX(2.5, radius / 4);
    ring.shadowColor = NSColor.whiteColor.CGColor;
    ring.shadowOpacity = 0.9;
    ring.shadowRadius = 1.5;
    ring.shadowOffset = CGSizeZero;
    [host addSublayer:ring];
    CAShapeLayer *dot = [CAShapeLayer layer];
    CGFloat dr = MAX(3, radius / 3.5);
    CGPathRef dotPath = CGPathCreateWithEllipseInRect(CGRectMake(-dr, -dr, dr * 2, dr * 2), NULL);
    dot.path = dotPath;
    CGPathRelease(dotPath);
    dot.position = at;
    dot.fillColor = [NSColor colorWithSRGBRed:0.898 green:0.282 blue:0.302 alpha:1].CGColor;
    dot.strokeColor = NSColor.whiteColor.CGColor;
    dot.lineWidth = MAX(1, dr / 3);
    [host addSublayer:dot];
    CABasicAnimation *dotFade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    dotFade.fromValue = @1; dotFade.toValue = @0; dotFade.beginTime = CACurrentMediaTime() + 0.8; dotFade.duration = 0.5;
    dotFade.fillMode = kCAFillModeBackwards; dotFade.removedOnCompletion = NO;
    dot.opacity = 0;
    [dot addAnimation:dotFade forKey:@"fade"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [dot removeFromSuperlayer]; });
    CAMediaTimingFunction *ease = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.9 :0.25 :1];
    CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    grow.fromValue = @(YMReduceMotion() ? 1.0 : 0.35);
    grow.toValue = @(YMReduceMotion() ? 1.0 : 1.5);
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1;
    fade.toValue = @0;
    fade.beginTime = 0.6;
    fade.duration = 0.6;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[grow, fade];
    group.duration = 1.2;
    group.timingFunction = ease;
    group.fillMode = kCAFillModeForwards;
    group.removedOnCompletion = NO;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{ [ring removeFromSuperlayer]; }];
    [ring addAnimation:group forKey:@"ripple"];
    [CATransaction commit];
}

#pragma mark - Capture source (one ScreenCaptureKit stream per virtual display)

@interface YMPreviewSource : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic) CGDirectDisplayID displayID;
@property(nonatomic, nullable) SCStream *stream;
@property(nonatomic, nullable) SCDisplay *display;
@property(nonatomic) BOOL live;
@property(nonatomic) BOOL started;
@property(atomic) BOOL stopped;
@property(atomic) NSUInteger generation;
@property(nonatomic) NSHashTable<CALayer *> *layers;
@property(nonatomic, nullable) id latest;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic, copy, nullable) void (^onFailure)(YMPreviewSource *, NSError *);
@property(nonatomic, copy, nullable) void (^onFirstFrame)(void);
@end

@implementation YMPreviewSource
+ (SCStreamConfiguration *)configurationForDisplay:(SCDisplay *)display live:(BOOL)live {
    SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
    double aspect = display.height > 0 ? (double)display.width / (double)display.height : 16.0 / 9.0;
    size_t width = live ? MIN((size_t)display.width * 2, (size_t)3840) : 480;
    configuration.width = width;
    configuration.height = (size_t)llround((double)width / aspect);
    configuration.minimumFrameInterval = live ? CMTimeMake(1, 30) : CMTimeMake(1, 2);
    configuration.queueDepth = 3;
    configuration.showsCursor = NO;
    configuration.pixelFormat = kCVPixelFormatType_32BGRA;
    return configuration;
}
- (instancetype)init {
    if ((self = [super init])) {
        _layers = [NSHashTable weakObjectsHashTable];
        _generation = 1;
        _queue = dispatch_queue_create("dev.chekusu.yomado.preview", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (instancetype)initWithDisplay:(SCDisplay *)display {
    if ((self = [self init])) {
        _display = display;
        _displayID = display.displayID;
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        _stream = [[SCStream alloc] initWithFilter:filter configuration:[YMPreviewSource configurationForDisplay:display live:NO] delegate:self];
    }
    return self;
}
- (void)start {
    if (self.stopped || self.started) return;
    self.started = YES;
    if (!self.stream) {
        [self failWithError:[NSError errorWithDomain:@"YMWorkspacePreview" code:2 userInfo:nil]];
        return;
    }
    NSError *error = nil;
    if (![self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.queue error:&error]) {
        [self failWithError:error ?: [NSError errorWithDomain:@"YMWorkspacePreview" code:1 userInfo:nil]];
        return;
    }
    __weak YMPreviewSource *weakSelf = self;
    [self.stream startCaptureWithCompletionHandler:^(NSError *startError) {
        if (startError) dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf failWithError:startError]; });
    }];
}
- (void)attachLayer:(CALayer *)layer {
    YMSetContents(layer, self.stopped ? nil : self.latest);
    if (!self.stopped) [self.layers addObject:layer];
}
- (void)detachLayer:(CALayer *)layer { [self.layers removeObject:layer]; }
- (void)setLive:(BOOL)live {
    if (_live == live || self.stopped) return;
    _live = live;
    if (!self.display || !self.stream) return;
    __weak YMPreviewSource *weakSelf = self;
    [self.stream updateConfiguration:[YMPreviewSource configurationForDisplay:self.display live:live] completionHandler:^(NSError *error) {
        if (error) dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf failWithError:error]; });
    }];
}
- (void)stop {
    if (self.stopped) return;
    // Invalidate before asking ScreenCaptureKit to stop: frames already queued
    // on the main thread must not repopulate detached or disabled previews.
    self.stopped = YES;
    self.generation += 1;
    self.latest = nil;
    for (CALayer *layer in self.layers) YMSetContents(layer, nil);
    [self.layers removeAllObjects];
    self.onFailure = nil;
    self.onFirstFrame = nil;
    SCStream *stream = self.stream;
    self.stream = nil;
    [stream stopCaptureWithCompletionHandler:^(NSError *error) { (void)error; }];
}
- (void)failWithError:(NSError *)error {
    if (self.stopped) return;
    void (^failure)(YMPreviewSource *, NSError *) = self.onFailure;
    [self stop];
    if (failure) failure(self, error);
}
- (void)publishContents:(id)contents generation:(NSUInteger)generation {
    if (self.stopped || generation != self.generation) return;
    BOOL first = !self.latest;
    self.latest = contents;
    for (CALayer *layer in self.layers) YMSetContents(layer, contents);
    if (first && self.onFirstFrame) self.onFirstFrame();
}
- (void)enqueueContents:(id)contents {
    NSUInteger generation = self.generation;
    __weak YMPreviewSource *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf publishContents:contents generation:generation]; });
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    (void)stream;
    if (self.stopped || type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer)) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
        NSNumber *status = info[SCStreamFrameInfoStatus];
        if (status && status.integerValue != SCFrameStatusComplete) return;
    }
    CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
    IOSurfaceRef surface = pixels ? CVPixelBufferGetIOSurface(pixels) : NULL;
    if (surface) [self enqueueContents:(__bridge id)surface];
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    __weak YMPreviewSource *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf failWithError:error]; });
}
@end

#pragma mark - Panels and views

@interface YMPreviewPanel : NSPanel
@end
@implementation YMPreviewPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static void YMConfigureFloatingPanel(NSPanel *panel) {
    panel.level = NSFloatingWindowLevel;
    panel.floatingPanel = YES;
    panel.hidesOnDeactivate = NO;
    panel.becomesKeyOnlyIfNeeded = YES;
    panel.releasedWhenClosed = NO;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary
        | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    panel.animationBehavior = NSWindowAnimationBehaviorNone;
}

// A click target that never activates yomado.
@interface YMPreviewHitView : NSView
@property(nonatomic, copy, nullable) void (^onClick)(void);
@property(nonatomic, copy, nullable) void (^onDoubleClick)(void);
@end
@implementation YMPreviewHitView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (BOOL)mouseDownCanMoveWindow { return self.onClick == nil; }
- (void)mouseUp:(NSEvent *)event {
    if (event.clickCount == 2 && self.onDoubleClick) self.onDoubleClick();
    else if (event.clickCount == 1 && self.onClick) self.onClick();
}
@end

// Collapsed tab: a sliver of the live picture with a status dot.
@interface YMPreviewTab : YMPreviewHitView
@property(nonatomic) CALayer *picture;
@end
@implementation YMPreviewTab
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 5;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
        self.layer.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.92].CGColor;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.18].CGColor;
        _picture = [CALayer layer];
        _picture.contentsGravity = kCAGravityResizeAspectFill;
        _picture.frame = self.layer.bounds;
        _picture.opacity = 0.85;
        [self.layer addSublayer:_picture];
    }
    return self;
}
- (void)layout { [super layout]; self.picture.frame = self.layer.bounds; }
@end

// Expanded card: live thumbnail with the display name on a soft gradient.
@interface YMPreviewCard : YMPreviewHitView
@property(nonatomic) CALayer *picture;
@property(nonatomic) CAGradientLayer *shade;
@property(nonatomic) NSTextField *label;
@property(nonatomic) NSTextField *status;
@end
@implementation YMPreviewCard
- (instancetype)initWithFrame:(NSRect)frame name:(NSString *)name {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 10;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.22].CGColor;
        _picture = [CALayer layer];
        _picture.contentsGravity = kCAGravityResizeAspect;
        [self.layer addSublayer:_picture];
        _shade = [CAGradientLayer layer];
        _shade.colors = @[(id)[NSColor colorWithWhite:0 alpha:0.55].CGColor, (id)[NSColor colorWithWhite:0 alpha:0].CGColor];
        _shade.startPoint = CGPointMake(0.5, 0);
        _shade.endPoint = CGPointMake(0.5, 1);
        [self.layer addSublayer:_shade];
        _label = [NSTextField labelWithString:name];
        _label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        _label.textColor = NSColor.whiteColor;
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_label];
        _status = [NSTextField labelWithString:@""];
        _status.font = [NSFont systemFontOfSize:11];
        _status.textColor = [NSColor colorWithWhite:0.72 alpha:1];
        _status.alignment = NSTextAlignmentCenter;
        [self addSubview:_status];
        self.toolTip = [NSString stringWithFormat:@"查看 %@", name];
    }
    return self;
}
- (void)layout {
    [super layout];
    self.picture.frame = self.layer.bounds;
    self.shade.frame = CGRectMake(0, 0, self.bounds.size.width, 34);
    self.label.frame = NSMakeRect(10, 7, self.bounds.size.width - 20, 16);
    self.status.frame = NSMakeRect(10, NSMidY(self.bounds) - 8, self.bounds.size.width - 20, 16);
}
@end

// Dock content: tracks hover to expand and collapse.
@interface YMPreviewDockView : NSView
@property(nonatomic, copy, nullable) void (^onHover)(BOOL inside);
@end
@implementation YMPreviewDockView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; if (self.onHover) self.onHover(YES); }
- (void)mouseExited:(NSEvent *)event { (void)event; if (self.onHover) self.onHover(NO); }
@end

// Read-only picture-in-picture with a title and close control on hover.
@interface YMPiPView : YMPreviewHitView
@property(nonatomic) CALayer *picture;
@property(nonatomic) NSView *bar;
@property(nonatomic) NSTextField *title;
@property(nonatomic) NSTextField *status;
@property(nonatomic) NSButton *closeButton;
@end
@implementation YMPiPView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        _picture = [CALayer layer];
        _picture.contentsGravity = kCAGravityResizeAspect;
        [self.layer addSublayer:_picture];
        _bar = [[NSView alloc] init];
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.colors = @[(id)[NSColor colorWithWhite:0 alpha:0].CGColor, (id)[NSColor colorWithWhite:0 alpha:0.5].CGColor];
        _bar.wantsLayer = YES;
        _bar.layer = gradient;
        _bar.alphaValue = 0;
        [self addSubview:_bar];
        _title = [NSTextField labelWithString:@""];
        _title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        _title.textColor = NSColor.whiteColor;
        [_bar addSubview:_title];
        _closeButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:@"收起预览"] target:nil action:nil];
        _closeButton.bordered = NO;
        _closeButton.contentTintColor = [NSColor colorWithWhite:1 alpha:0.9];
        _closeButton.toolTip = @"收起预览";
        _closeButton.refusesFirstResponder = YES;
        [_bar addSubview:_closeButton];
        _status = [NSTextField labelWithString:@""];
        _status.font = [NSFont systemFontOfSize:13];
        _status.textColor = [NSColor colorWithWhite:0.72 alpha:1];
        _status.alignment = NSTextAlignmentCenter;
        [self addSubview:_status];
    }
    return self;
}
- (BOOL)acceptsFirstResponder { return NO; }
- (void)layout {
    [super layout];
    NSSize size = self.bounds.size;
    self.picture.frame = self.layer.bounds;
    self.bar.frame = NSMakeRect(0, size.height - 40, size.width, 40);
    self.title.frame = NSMakeRect(14, 12, size.width - 60, 16);
    self.closeButton.frame = NSMakeRect(size.width - 34, 10, 20, 20);
    self.status.frame = NSMakeRect(14, size.height / 2 - 10, size.width - 28, 20);
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    YMAnimate(0.18, ^{ self.bar.animator.alphaValue = 1; }, nil);
}
- (void)mouseExited:(NSEvent *)event {
    (void)event;
    YMAnimate(0.25, ^{ self.bar.animator.alphaValue = 0; }, nil);
}
@end

#pragma mark - Controller

@interface YMWorkspacePreview ()
@property(nonatomic, readwrite) BOOL enabled;
@property(nonatomic) NSArray<NSDictionary *> *displays;
@property(nonatomic) NSMutableDictionary<NSNumber *, YMPreviewSource *> *sources;
@property(nonatomic, nullable) YMPreviewPanel *dock;
@property(nonatomic, nullable) YMPreviewDockView *dockView;
@property(nonatomic) NSMutableArray<YMPreviewTab *> *tabs;
@property(nonatomic) NSMutableArray<YMPreviewCard *> *cards;
@property(nonatomic) BOOL expanded;
@property(nonatomic) BOOL fetching;
@property(nonatomic) NSUInteger retries;
@property(nonatomic, nullable) YMPreviewPanel *pip;
@property(nonatomic, nullable) YMPiPView *pipView;
@property(nonatomic, nullable) NSNumber *pipDisplayID;
@property(nonatomic) BOOL permissionMissing;
@property(nonatomic) BOOL invalidated;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL retryScheduled;
@property(nonatomic) NSMutableSet<NSNumber *> *failedDisplays;
@end

@implementation YMWorkspacePreview
- (instancetype)init { return [self initWithEnabled:[NSUserDefaults.standardUserDefaults boolForKey:YMPreviewEnabledKey]]; }
- (instancetype)initWithEnabled:(BOOL)enabled {
    if ((self = [super init])) {
        _enabled = enabled;
        _failedDisplays = [NSMutableSet set];
        _displays = @[];
        _sources = [NSMutableDictionary dictionary];
        _tabs = [NSMutableArray array];
        _cards = [NSMutableArray array];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(screensChanged:)
            name:NSApplicationDidChangeScreenParametersNotification object:nil];
    }
    return self;
}
- (void)invalidate {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.invalidated = YES;
    _enabled = NO;
    self.displays = @[];
    [self teardown];
}
- (void)setEnabled:(BOOL)enabled {
    if (self.invalidated) return;
    self.generation += 1;
    self.fetching = NO;
    self.retryScheduled = NO;
    self.retries = 0;
    [self.failedDisplays removeAllObjects];
    _enabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:YMPreviewEnabledKey];
    if (enabled && !CGPreflightScreenCaptureAccess()) CGRequestScreenCaptureAccess();
    [self reconcile];
}
- (void)updateDisplays:(NSArray<NSDictionary *> *)displays {
    if (self.invalidated || [displays isEqualToArray:self.displays]) return;
    self.generation += 1;
    self.fetching = NO;
    self.retryScheduled = NO;
    [self.failedDisplays removeAllObjects];
    self.displays = [displays copy];
    self.retries = 0;
    [self reconcile];
}
- (void)screensChanged:(NSNotification *)note {
    (void)note;
    [self layoutDockAnimated:NO];
}

- (void)teardown {
    self.generation += 1;
    self.fetching = NO;
    self.retryScheduled = NO;
    for (YMPreviewSource *source in self.sources.allValues) [source stop];
    [self.sources removeAllObjects];
    [self closePiP];
    [self.dock orderOut:nil];
    self.dock = nil;
    self.dockView = nil;
    [self.tabs removeAllObjects];
    [self.cards removeAllObjects];
    self.expanded = NO;
}

- (void)reconcile {
    if (self.invalidated || !self.enabled || !self.displays.count) { [self teardown]; return; }
    NSMutableSet *wanted = [NSMutableSet set];
    for (NSDictionary *display in self.displays) [wanted addObject:display[@"displayID"]];
    for (NSNumber *ident in self.sources.allKeys) {
        if ([wanted containsObject:ident]) continue;
        [self.sources[ident] stop];
        [self.sources removeObjectForKey:ident];
    }
    if (self.pipDisplayID && ![wanted containsObject:self.pipDisplayID]) [self closePiP];
    self.permissionMissing = !CGPreflightScreenCaptureAccess();
    [self rebuildDock];
    if (!self.permissionMissing) [self startMissingSources];
}

- (void)fetchShareableContentWithCompletion:(void (^)(SCShareableContent *, NSError *))completion {
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES completionHandler:completion];
}
- (void)scheduleRetry {
    if (self.invalidated || !self.enabled || self.retryScheduled || self.retries >= 10 || !self.displays.count) {
        [self updatePreviewStatus];
        return;
    }
    self.retries += 1;
    self.retryScheduled = YES;
    NSUInteger generation = self.generation;
    __weak YMWorkspacePreview *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YMWorkspacePreview *strong = weakSelf;
        if (!strong || strong.invalidated || !strong.enabled || strong.generation != generation) return;
        strong.retryScheduled = NO;
        [strong startMissingSources];
    });
    [self updatePreviewStatus];
}
- (void)sourceFailed:(YMPreviewSource *)source {
    NSNumber *ident = @(source.displayID);
    if (self.sources[ident] != source) return;
    [self.sources removeObjectForKey:ident];
    [self.failedDisplays addObject:ident];
    [self scheduleRetry];
}
- (YMPreviewSource *)sourceForDisplay:(SCDisplay *)display {
    return [[YMPreviewSource alloc] initWithDisplay:display];
}
- (void)startMissingSources {
    if (self.invalidated || !self.enabled || self.fetching || self.retryScheduled) return;
    BOOL missing = NO;
    for (NSDictionary *display in self.displays) if (!self.sources[display[@"displayID"]]) missing = YES;
    if (!missing) return;
    self.fetching = YES;
    NSUInteger generation = self.generation;
    __weak YMWorkspacePreview *weakSelf = self;
    [self fetchShareableContentWithCompletion:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YMWorkspacePreview *strong = weakSelf;
            if (!strong || strong.invalidated || !strong.enabled || strong.generation != generation) return;
            strong.fetching = NO;
            if (!content || error) {
                strong.permissionMissing = !CGPreflightScreenCaptureAccess();
                for (NSDictionary *display in strong.displays) {
                    NSNumber *ident = display[@"displayID"];
                    if (!strong.sources[ident]) [strong.failedDisplays addObject:ident];
                }
                [strong rebuildDock];
                if (!strong.permissionMissing) [strong scheduleRetry];
                return;
            }
            for (NSDictionary *display in strong.displays) {
                NSNumber *ident = display[@"displayID"];
                if (strong.sources[ident]) continue;
                SCDisplay *match = nil;
                for (SCDisplay *candidate in content.displays) if (candidate.displayID == ident.unsignedIntValue) match = candidate;
                YMPreviewSource *source = match ? [strong sourceForDisplay:match] : nil;
                if (!source) { [strong.failedDisplays addObject:ident]; continue; }
                source.onFailure = ^(YMPreviewSource *failed, NSError *failure) { (void)failure; [weakSelf sourceFailed:failed]; };
                source.onFirstFrame = ^{ [weakSelf updatePreviewStatus]; };
                [strong.failedDisplays removeObject:ident];
                strong.sources[ident] = source;
                [source start];
            }
            [strong bindLayers];
            BOOL stillMissing = NO;
            for (NSDictionary *display in strong.displays) if (!strong.sources[display[@"displayID"]]) stillMissing = YES;
            if (stillMissing) [strong scheduleRetry];
        });
    }];
    [self updatePreviewStatus];
}
- (NSString *)statusForDisplayID:(NSNumber *)ident {
    if (self.sources[ident].latest) return @"";
    if ([self.failedDisplays containsObject:ident])
        return self.retryScheduled || self.fetching ? @"预览失败，正在重试" : @"预览不可用";
    return @"正在连接预览";
}
- (void)updatePreviewStatus {
    if (!self.permissionMissing) {
        for (NSUInteger index = 0; index < self.displays.count && index < self.cards.count; index++) {
            NSNumber *ident = self.displays[index][@"displayID"];
            NSString *status = [self statusForDisplayID:ident];
            self.cards[index].status.stringValue = status;
            self.tabs[index].toolTip = status.length ? [NSString stringWithFormat:@"%@ · %@", [self nameForDisplayID:ident], status] : [self nameForDisplayID:ident];
        }
    }
    if (self.pipDisplayID) self.pipView.status.stringValue = [self statusForDisplayID:self.pipDisplayID];
}

- (void)bindLayers {
    for (NSUInteger index = 0; index < self.displays.count && index < self.cards.count; index++) {
        YMPreviewSource *source = self.sources[self.displays[index][@"displayID"]];
        if (!source) continue;
        [source attachLayer:self.cards[index].picture];
        if (index < self.tabs.count) [source attachLayer:self.tabs[index].picture];
    }
    if (self.pipDisplayID && self.sources[self.pipDisplayID]) {
        [self.sources[self.pipDisplayID] attachLayer:self.pipView.picture];
        self.sources[self.pipDisplayID].live = YES;
    }
    [self updatePreviewStatus];
}

#pragma mark Dock

- (NSScreen *)dockScreen {
    // The rightmost physical screen; virtual displays are never used for the dock.
    NSScreen *best = nil;
    for (NSScreen *screen in NSScreen.screens) {
        CGDirectDisplayID ident = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        if ([VDVirtualDisplay isVirtualDisplay:ident]) continue;
        if (!best || NSMaxX(screen.frame) > NSMaxX(best.frame)) best = screen;
    }
    return best ?: NSScreen.mainScreen;
}

- (NSUInteger)itemCount { return self.permissionMissing ? 1 : self.displays.count; }

- (NSRect)dockFrameExpanded:(BOOL)expanded {
    NSRect visible = [self dockScreen].visibleFrame;
    CGFloat count = (CGFloat)MAX((NSUInteger)1, [self itemCount]);
    CGFloat width = expanded ? YMCardWidth + YMDockPad * 2 : YMTabWidth;
    CGFloat height = expanded ? count * YMCardHeight + (count - 1) * YMCardGap + YMDockPad * 2
                              : count * YMTabHeight + (count - 1) * YMTabGap;
    return NSMakeRect(NSMaxX(visible) - width, NSMidY(visible) - height / 2, width, height);
}

- (void)rebuildDock {
    if (!self.dock) {
        YMPreviewPanel *panel = [[YMPreviewPanel alloc] initWithContentRect:[self dockFrameExpanded:NO]
            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        YMConfigureFloatingPanel(panel);
        panel.opaque = NO;
        panel.backgroundColor = NSColor.clearColor;
        panel.hasShadow = NO;
        YMPreviewDockView *view = [[YMPreviewDockView alloc] initWithFrame:NSZeroRect];
        view.wantsLayer = YES;
        __weak YMWorkspacePreview *weakSelf = self;
        view.onHover = ^(BOOL inside) { [weakSelf hoverChanged:inside]; };
        panel.contentView = view;
        self.dock = panel;
        self.dockView = view;
    }
    for (NSView *view in [(NSArray<NSView *> *)self.tabs arrayByAddingObjectsFromArray:(NSArray<NSView *> *)self.cards]) [view removeFromSuperview];
    for (YMPreviewSource *source in self.sources.allValues) [source.layers removeAllObjects];
    [self.tabs removeAllObjects];
    [self.cards removeAllObjects];
    __weak YMWorkspacePreview *weakSelf = self;
    if (self.permissionMissing) {
        YMPreviewTab *tab = [[YMPreviewTab alloc] initWithFrame:NSZeroRect];
        tab.layer.backgroundColor = NSColor.systemOrangeColor.CGColor;
        tab.onClick = ^{ [weakSelf requestPermission]; };
        YMPreviewCard *card = [[YMPreviewCard alloc] initWithFrame:NSZeroRect name:@"需要「屏幕录制」权限才能预览 · 点此授权"];
        card.layer.backgroundColor = [NSColor colorWithWhite:0.16 alpha:0.95].CGColor;
        card.label.lineBreakMode = NSLineBreakByWordWrapping;
        card.onClick = ^{ [weakSelf requestPermission]; };
        [self.tabs addObject:tab];
        [self.cards addObject:card];
    } else {
        for (NSDictionary *display in self.displays) {
            NSNumber *ident = display[@"displayID"];
            YMPreviewTab *tab = [[YMPreviewTab alloc] initWithFrame:NSZeroRect];
            tab.toolTip = display[@"name"];
            tab.onClick = ^{ [weakSelf openPiPForDisplayID:ident]; };
            YMPreviewCard *card = [[YMPreviewCard alloc] initWithFrame:NSZeroRect name:display[@"name"] ?: @""];
            card.onClick = ^{ [weakSelf openPiPForDisplayID:ident]; };
            [self.tabs addObject:tab];
            [self.cards addObject:card];
        }
    }
    for (NSView *view in [(NSArray<NSView *> *)self.tabs arrayByAddingObjectsFromArray:(NSArray<NSView *> *)self.cards]) [self.dockView addSubview:view];
    [self bindLayers];
    [self layoutDockAnimated:NO];
    [self.dock orderFrontRegardless];
}

- (void)layoutSubviewsExpanded:(BOOL)expanded inSize:(NSSize)size {
    CGFloat y = size.height - (expanded ? YMDockPad : 0);
    for (NSUInteger index = 0; index < self.cards.count; index++) {
        if (expanded) {
            y -= YMCardHeight;
            self.cards[index].frame = NSMakeRect(YMDockPad, y, YMCardWidth, YMCardHeight);
            y -= YMCardGap;
        } else {
            y -= YMTabHeight;
            self.tabs[index].frame = NSMakeRect(0, y, YMTabWidth, YMTabHeight);
            y -= YMTabGap;
        }
    }
}

- (void)layoutDockAnimated:(BOOL)animated {
    if (!self.dock) return;
    BOOL expanded = self.expanded;
    NSRect frame = [self dockFrameExpanded:expanded];
    [self layoutSubviewsExpanded:expanded inSize:frame.size];
    void (^changes)(void) = ^{
        [self.dock.animator setFrame:frame display:YES];
        for (YMPreviewTab *tab in self.tabs) tab.animator.alphaValue = expanded ? 0 : 1;
        for (YMPreviewCard *card in self.cards) card.animator.alphaValue = expanded ? 1 : 0;
    };
    if (animated) YMAnimate(0.24, changes, nil);
    else {
        [self.dock setFrame:frame display:YES];
        for (YMPreviewTab *tab in self.tabs) tab.alphaValue = expanded ? 0 : 1;
        for (YMPreviewCard *card in self.cards) card.alphaValue = expanded ? 1 : 0;
    }
}

- (void)hoverChanged:(BOOL)inside {
    if (inside) {
        if (self.expanded) return;
        self.expanded = YES;
        [self layoutDockAnimated:YES];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.dock || NSPointInRect(NSEvent.mouseLocation, self.dock.frame)) return;
        [self collapseDock];
    });
}
- (void)collapseDock {
    if (!self.expanded) return;
    self.expanded = NO;
    [self layoutDockAnimated:YES];
}

- (void)requestPermission {
    CGRequestScreenCaptureAccess();
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}

#pragma mark Agent action marks

- (void)markPoint:(CGPoint)point {
    if (!self.enabled) return;
    for (NSUInteger index = 0; index < self.displays.count; index++) {
        NSNumber *ident = self.displays[index][@"displayID"];
        CGRect bounds = CGDisplayBounds(ident.unsignedIntValue);
        if (!CGRectContainsPoint(bounds, point)) continue;
        // Normalized position, origin bottom-left to match AppKit layers.
        CGFloat nx = (point.x - bounds.origin.x) / bounds.size.width;
        CGFloat ny = 1 - (point.y - bounds.origin.y) / bounds.size.height;
        NSMutableArray<CALayer *> *hosts = [NSMutableArray array];
        if (index < self.cards.count) [hosts addObject:self.cards[index].picture];
        if ([self.pipDisplayID isEqual:ident] && self.pip.visible) [hosts addObject:self.pipView.picture];
        for (CALayer *host in hosts) {
            CGRect fit = YMAspectFitRect(bounds.size, host.bounds);
            CGPoint at = CGPointMake(CGRectGetMinX(fit) + nx * fit.size.width, CGRectGetMinY(fit) + ny * fit.size.height);
            YMAddRipple(host, at, MAX(7, fit.size.width / 60));
        }
        return;
    }
}


- (NSString *)nameForDisplayID:(NSNumber *)ident {
    for (NSDictionary *display in self.displays) if ([display[@"displayID"] isEqual:ident]) return display[@"name"] ?: @"";
    return @"";
}

- (NSRect)defaultPiPFrame {
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:YMPreviewPiPFrameKey];
    NSRect frame = saved.length ? NSRectFromString(saved) : NSZeroRect;
    // Only reuse the saved frame on the dock's screen: the person just clicked
    // there, and another screen may be covered by a full-screen app or unplugged.
    NSRect visible = [self dockScreen].visibleFrame;
    if (frame.size.width >= 240 && NSContainsRect(visible, frame)) return frame;
    CGFloat width = 640, height = 360;
    return NSMakeRect(NSMaxX(visible) - width - YMTabWidth - 24, NSMinY(visible) + 24, width, height);
}

- (void)openPiPForDisplayID:(NSNumber *)ident {
    [self collapseDock];
    if (self.pipDisplayID && ![self.pipDisplayID isEqual:ident]) {
        YMPreviewSource *previous = self.sources[self.pipDisplayID];
        [previous detachLayer:self.pipView.picture];
        previous.live = NO;
    }
    if (!self.pip) {
        YMPreviewPanel *panel = [[YMPreviewPanel alloc] initWithContentRect:[self defaultPiPFrame]
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView | NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        YMConfigureFloatingPanel(panel);
        panel.titleVisibility = NSWindowTitleHidden;
        panel.titlebarAppearsTransparent = YES;
        for (NSWindowButton button = NSWindowCloseButton; button <= NSWindowZoomButton; button++)
            [panel standardWindowButton:button].hidden = YES;
        panel.movableByWindowBackground = YES;
        panel.contentAspectRatio = NSMakeSize(16, 9);
        panel.minSize = NSMakeSize(320, 180);
        panel.backgroundColor = NSColor.blackColor;
        YMPiPView *view = [[YMPiPView alloc] initWithFrame:NSZeroRect];
        __weak YMWorkspacePreview *weakSelf = self;
        view.onDoubleClick = ^{ [weakSelf togglePiPSize]; };
        view.closeButton.target = self;
        view.closeButton.action = @selector(closePiPFromButton:);
        panel.contentView = view;
        self.pip = panel;
        self.pipView = view;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(pipFrameChanged:) name:NSWindowDidEndLiveResizeNotification object:panel];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(pipFrameChanged:) name:NSWindowDidMoveNotification object:panel];
    }
    self.pipDisplayID = ident;
    self.pipView.title.stringValue = [self nameForDisplayID:ident];
    YMSetContents(self.pipView.picture, nil);
    YMPreviewSource *source = self.sources[ident];
    if (source) { [source attachLayer:self.pipView.picture]; source.live = YES; }
    [self updatePreviewStatus];
    if (!self.pip.visible || !NSIntersectsRect([self dockScreen].visibleFrame, self.pip.frame)) {
        [self.pip setFrame:[self defaultPiPFrame] display:NO];
        self.pip.alphaValue = 0;
        [self.pip orderFrontRegardless];
        YMAnimate(0.2, ^{ self.pip.animator.alphaValue = 1; }, nil);
    }
}

- (void)pipFrameChanged:(NSNotification *)note {
    (void)note;
    if (self.pip) [NSUserDefaults.standardUserDefaults setObject:NSStringFromRect(self.pip.frame) forKey:YMPreviewPiPFrameKey];
}

- (void)togglePiPSize {
    NSRect frame = self.pip.frame;
    NSRect visible = (self.pip.screen ?: [self dockScreen]).visibleFrame;
    BOOL large = frame.size.width >= 1000;
    CGFloat width = large ? 640 : MIN(1280, visible.size.width - 48);
    CGFloat height = width * 9 / 16;
    NSRect next = NSMakeRect(NSMaxX(frame) - width, NSMinY(frame), width, height);
    next.origin.x = MAX(NSMinX(visible) + 12, MIN(next.origin.x, NSMaxX(visible) - width - 12));
    next.origin.y = MAX(NSMinY(visible) + 12, MIN(next.origin.y, NSMaxY(visible) - height - 12));
    YMAnimate(0.25, ^{ [self.pip.animator setFrame:next display:YES]; }, nil);
}

- (void)closePiPFromButton:(id)sender { (void)sender; [self closePiP]; }

- (void)closePiP {
    if (!self.pip) return;
    if (self.pipDisplayID) {
        YMPreviewSource *source = self.sources[self.pipDisplayID];
        [source detachLayer:self.pipView.picture];
        source.live = NO;
    }
    self.pipDisplayID = nil;
    YMPreviewPanel *panel = self.pip;
    YMAnimate(0.18, ^{ panel.animator.alphaValue = 0; }, ^{ [panel orderOut:nil]; });
}
@end
