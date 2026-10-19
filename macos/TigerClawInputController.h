#pragma once
#import <Cocoa/Cocoa.h>

// Warm the shared engine before IMK dispatches the first key. Safe to call more
// than once; failures are logged and retried by the controller on demand.
void TigerClawPreloadEngine(void);
