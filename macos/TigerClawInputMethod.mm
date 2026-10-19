#import <InputMethodKit/InputMethodKit.h>
#import <Carbon/Carbon.h>
#include <cstring>

#import "TigerClawInputController.h"

static OSStatus EnableTigerClawMode(bool select)
{
    CFArrayRef sources = TISCreateInputSourceList(nullptr, true);
    if (!sources) return paramErr;
    OSStatus result = fnfErr;
    CFStringRef wanted = CFSTR("com.viui.inputmethod.TigerClaw.Hans");
    CFStringRef parent = CFSTR("com.viui.inputmethod.TigerClaw");
    TISInputSourceRef mode = nullptr;
    for (CFIndex i = 0; i < CFArrayGetCount(sources); ++i)
    {
        TISInputSourceRef source = (TISInputSourceRef)CFArrayGetValueAtIndex(sources, i);
        CFStringRef sourceID = (CFStringRef)TISGetInputSourceProperty(source, kTISPropertyInputSourceID);
        if (!sourceID) continue;
        if (CFEqual(sourceID, parent)) TISEnableInputSource(source);
        if (CFEqual(sourceID, wanted)) mode = (TISInputSourceRef)CFRetain(source);
    }
    CFRelease(sources);
    if (!mode) return fnfErr;
    result = TISEnableInputSource(mode);
    // The mode-enabled parent and the enabled mode settle asynchronously in
    // TextInputServices; selecting before that returns paramErr (-50).
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
    if (result == noErr && select)
    {
        result = TISSelectInputSource(mode);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
    }
    CFRelease(mode);
    return result;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool
    {
        if (argc > 1 && std::strcmp(argv[1], "--register-input-source") == 0)
        {
            NSURL *bundleURL = [NSBundle mainBundle].bundleURL;
            OSStatus status = TISRegisterInputSource((__bridge CFURLRef)bundleURL);
            NSLog(@"TigerClaw TISRegisterInputSource: %@ (%@)",
                  status == noErr ? @"success" : @"failure", bundleURL.path);
            return status == noErr ? 0 : 1;
        }
        if (argc > 1 && std::strcmp(argv[1], "--enable-input-source") == 0)
        {
            OSStatus status = EnableTigerClawMode(argc > 2 && std::strcmp(argv[2], "--select") == 0);
            NSLog(@"TigerClaw enable input source: %@", status == noErr ? @"success" : @"failure");
            return status == noErr ? 0 : 1;
        }
        if (argc > 1 && std::strcmp(argv[1], "--version") == 0)
        {
            std::printf("%s\n", [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String]);
            return 0;
        }

        NSApplication *application = [NSApplication sharedApplication];
        NSString *connection = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"InputMethodConnectionName"];
        NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];

        // Create the IMK server first so the input source becomes reachable as
        // early as possible. Dictionary parsing happens after this point.
        IMKServer *server = [[IMKServer alloc] initWithName:connection bundleIdentifier:identifier];
        if (!server) NSLog(@"TigerClaw: IMKServer creation failed");
        TigerClawPreloadEngine();
        [application run];
    }
    return 0;
}
