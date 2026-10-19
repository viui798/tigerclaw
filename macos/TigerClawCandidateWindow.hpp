#pragma once
#import <Cocoa/Cocoa.h>
#include <vector>
#include "TigerClawEngine.hpp"

// Non-activating candidate panel. The panel must never become key/main and
// must disable hidesOnDeactivate; an input method is not the active app.
@interface TigerClawCandidateWindow : NSPanel
+ (instancetype)sharedWindow;
@property(nonatomic, copy) void (^selectionHandler)(NSInteger index);
- (void)showCandidates:(const std::vector<tigerclaw::macos::Candidate>&)candidates
              selected:(NSInteger)selected
                  page:(NSInteger)page
                 pages:(NSInteger)pages
               atPoint:(NSPoint)point
              fontSize:(CGFloat)fontSize
             showIndex:(BOOL)showIndex
              vertical:(BOOL)vertical;
- (void)hideCandidates;
@end
