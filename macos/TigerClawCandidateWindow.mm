#import "TigerClawCandidateWindow.hpp"

static const CGFloat kVerticalPadding = 8.0;
static const CGFloat kHorizontalPadding = 10.0;
static const CGFloat kIndexWidth = 18.0;
static const CGFloat kFooterHeight = 15.0;

@interface TigerClawCandidateView : NSView
@property(nonatomic, copy) NSArray<NSString *> *items;
@property(nonatomic) NSInteger selection;
@property(nonatomic) CGFloat fontSize;
@property(nonatomic) BOOL showIndex;
@property(nonatomic) BOOL vertical;
@property(nonatomic, copy) NSString *pageText;
@property(nonatomic, copy) void (^onSelect)(NSInteger index);
@end

@implementation TigerClawCandidateView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (CGFloat)rowHeight { return MAX(18.0, self.fontSize + 8.0); }
- (CGFloat)footerHeight { return self.pageText.length ? kFooterHeight : 0.0; }
- (CGFloat)indexSlot { return self.showIndex ? kIndexWidth : 0.0; }

- (NSRect)itemRectAtIndex:(NSInteger)index
{
    auto font = [NSFont systemFontOfSize:self.fontSize];
    NSDictionary *attrs = @{NSFontAttributeName: font};
    if (self.vertical)
    {
        CGFloat y = kVerticalPadding + index * [self rowHeight];
        return NSMakeRect(0, y, self.bounds.size.width, [self rowHeight]);
    }
    CGFloat x = kHorizontalPadding;
    for (NSInteger i = 0; i < index; ++i)
    {
        CGFloat width = [self.items[i] sizeWithAttributes:attrs].width + [self indexSlot] + 14.0;
        x += width;
    }
    CGFloat width = [self.items[index] sizeWithAttributes:attrs].width + [self indexSlot] + 14.0;
    return NSMakeRect(x, 0, width, [self rowHeight]);
}

- (NSInteger)indexAtPoint:(NSPoint)point
{
    for (NSInteger i = 0; i < (NSInteger)self.items.count; ++i)
    {
        NSRect rect = [self itemRectAtIndex:i];
        if (NSPointInRect(point, NSInsetRect(rect, 0, 0))) return i;
    }
    return -1;
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger index = [self indexAtPoint:point];
    if (index >= 0 && index < (NSInteger)self.items.count && self.onSelect) self.onSelect(index);
}

- (void)drawRect:(NSRect)rect
{
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(rect);
    [[NSColor separatorColor] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                          xRadius:6 yRadius:6];
    [border stroke];

    auto candidateFont = [NSFont systemFontOfSize:self.fontSize];
    auto indexFont = [NSFont systemFontOfSize:MAX(10.0, self.fontSize * 0.55)];
    NSDictionary *attrs = @{NSFontAttributeName: candidateFont,
                            NSForegroundColorAttributeName: [NSColor labelColor]};
    NSDictionary *indexAttrs = @{NSFontAttributeName: indexFont,
                                 NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
    for (NSInteger i = 0; i < (NSInteger)self.items.count; ++i)
    {
        NSRect row = [self itemRectAtIndex:i];
        if (i == self.selection)
        {
            [[NSColor selectedContentBackgroundColor] setFill];
            NSBezierPath *selection = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(row, 2, 1)
                                                                     xRadius:4 yRadius:4];
            [selection fill];
        }
        CGFloat x = row.origin.x + 8.0;
        CGFloat textY = row.origin.y + (row.size.height - candidateFont.capHeight) / 2.0 - 1.0;
        if (self.showIndex)
        {
            NSString *number = [NSString stringWithFormat:@"%ld", (long)i + 1];
            CGFloat numberHeight = indexFont.capHeight;
            [number drawAtPoint:NSMakePoint(x, row.origin.y + (row.size.height - numberHeight) / 2.0)
                 withAttributes:indexAttrs];
            x += kIndexWidth;
        }
        [self.items[i] drawAtPoint:NSMakePoint(x, textY) withAttributes:attrs];
    }
    if (self.pageText.length)
    {
        auto footerFont = [NSFont systemFontOfSize:MAX(10.0, self.fontSize * 0.5)];
        NSDictionary *footerAttrs = @{NSFontAttributeName: footerFont,
                                      NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]};
        NSSize size = [self.pageText sizeWithAttributes:footerAttrs];
        [self.pageText drawAtPoint:NSMakePoint(self.bounds.size.width - size.width - 8.0,
                                               self.bounds.size.height - size.height - 2.0)
                   withAttributes:footerAttrs];
    }
}
@end

@implementation TigerClawCandidateWindow
{
    TigerClawCandidateView *_candidateView;
    CGFloat _lastFontSize;
}

+ (instancetype)sharedWindow
{
    static TigerClawCandidateWindow *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[TigerClawCandidateWindow alloc] init]; });
    return shared;
}

- (instancetype)init
{
    self = [super initWithContentRect:NSMakeRect(0, 0, 220, 120)
                             styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                               backing:NSBackingStoreBuffered
                                 defer:NO];
    if (self)
    {
        self.level = NSStatusWindowLevel;
        self.opaque = YES;
        self.hasShadow = YES;
        self.ignoresMouseEvents = NO;
        self.releasedWhenClosed = NO;
        // Input methods are never the active application; the default
        // hidesOnDeactivate would make this panel invisible forever.
        self.hidesOnDeactivate = NO;
        self.becomesKeyOnlyIfNeeded = YES;
        self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                  NSWindowCollectionBehaviorStationary |
                                  NSWindowCollectionBehaviorIgnoresCycle;
        _lastFontSize = 20.0;
        _candidateView = [[TigerClawCandidateView alloc] initWithFrame:self.contentView.bounds];
        _candidateView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        __unsafe_unretained TigerClawCandidateWindow *weakSelf = self;
        _candidateView.onSelect = ^(NSInteger index) {
            TigerClawCandidateWindow *strongSelf = weakSelf;
            if (strongSelf && strongSelf.selectionHandler) strongSelf.selectionHandler(index);
        };
        [self.contentView addSubview:_candidateView];
    }
    return self;
}

- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }

- (void)showCandidates:(const std::vector<tigerclaw::macos::Candidate>&)candidates
              selected:(NSInteger)selected
                  page:(NSInteger)page
                 pages:(NSInteger)pages
               atPoint:(NSPoint)point
              fontSize:(CGFloat)fontSize
             showIndex:(BOOL)showIndex
              vertical:(BOOL)vertical
{
    if (candidates.empty())
    {
        [self hideCandidates];
        return;
    }
    NSMutableArray<NSString *> *items = [NSMutableArray arrayWithCapacity:candidates.size()];
    for (const auto& candidate : candidates)
    {
        NSString *text = [[NSString alloc] initWithBytes:candidate.display.data()
                                                  length:candidate.display.size() * sizeof(char16_t)
                                                encoding:NSUTF16LittleEndianStringEncoding];
        [items addObject:text ?: @""];
    }
    _lastFontSize = fontSize;
    _candidateView.items = items;
    _candidateView.selection = selected;
    _candidateView.fontSize = fontSize;
    _candidateView.showIndex = showIndex;
    _candidateView.vertical = vertical;
    _candidateView.pageText = pages > 1 ? [NSString stringWithFormat:@"%ld/%ld", (long)page + 1, (long)pages] : @"";

    auto font = [NSFont systemFontOfSize:fontSize];
    NSDictionary *attrs = @{NSFontAttributeName: font};
    CGFloat width = 0;
    CGFloat height = 0;
    if (vertical)
    {
        CGFloat widest = 0;
        for (NSString *item in items) widest = MAX(widest, [item sizeWithAttributes:attrs].width);
        width = MAX(150.0, widest + (showIndex ? kIndexWidth : 0) + 34.0);
        height = items.count * MAX(18.0, fontSize + 8.0) + kVerticalPadding * 2 +
                 (pages > 1 ? kFooterHeight : 0);
    }
    else
    {
        CGFloat total = kHorizontalPadding * 2;
        for (NSString *item in items)
            total += [item sizeWithAttributes:attrs].width + (showIndex ? kIndexWidth : 0) + 14.0;
        width = MAX(150.0, total);
        height = MAX(18.0, fontSize + 8.0) + kVerticalPadding * 2 +
                 (pages > 1 ? kFooterHeight : 0);
    }
    [self setContentSize:NSMakeSize(MIN(width, 520.0), height)];
    _candidateView.frame = self.contentView.bounds;
    [_candidateView setNeedsDisplay:YES];

    NSScreen *screen = self.screen ?: [NSScreen mainScreen];
    NSRect visible = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
    CGFloat x = point.x;
    CGFloat y = point.y - height - 4;
    if (y < NSMinY(visible)) y = point.y + 20;
    x = MIN(MAX(x, NSMinX(visible) + 4), NSMaxX(visible) - width - 4);
    y = MIN(MAX(y, NSMinY(visible) + 4), NSMaxY(visible) - height - 4);
    [self setFrameOrigin:NSMakePoint(x, y)];
    [self orderFrontRegardless];
}

- (void)hideCandidates
{
    if (self.isVisible) [self orderOut:nil];
}
@end
