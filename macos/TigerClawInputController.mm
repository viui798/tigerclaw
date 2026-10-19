#import <InputMethodKit/InputMethodKit.h>
#import <ApplicationServices/ApplicationServices.h>

#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#import "TigerClawCandidateWindow.hpp"
#import "TigerClawEngine.hpp"
#import "TigerClawInputController.h"
#import "TigerClawKeyMap.hpp"

using tigerclaw::macos::Candidate;
using tigerclaw::macos::Engine;
using tigerclaw::macos::KeyInput;
using tigerclaw::macos::Snapshot;

static NSString *ToNSString(const std::u16string &value)
{
    if (value.empty()) return @"";
    return [[[NSString alloc] initWithBytes:value.data()
                                     length:value.size() * sizeof(char16_t)
                                   encoding:NSUTF16LittleEndianStringEncoding] autorelease] ?: @"";
}

static std::u16string ToU16String(NSString *value)
{
    if (!value.length) return {};
    NSData *data = [value dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    std::u16string result;
    result.resize(data.length / sizeof(char16_t));
    if (data.length) std::memcpy(result.data(), data.bytes, data.length);
    return result;
}

static std::u16string ClientId(id client)
{
    return ToU16String([NSString stringWithFormat:@"%p", client]);
}

static tigerclaw::macos::Paths MakePaths()
{
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *data = nil;
    const char *override = std::getenv("TIGERCLAW_DATA_DIR");
    if (override && *override) data = [NSString stringWithUTF8String:override];
    if (!data.length)
    {
        NSArray<NSString *> *support = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES);
        data = [[support firstObject] stringByAppendingPathComponent:@"TigerClaw"];
    }
    if (!data.length)
        data = [@"~/Library/Application Support/TigerClaw" stringByExpandingTildeInPath];
    [manager createDirectoryAtPath:data withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *resources = [[NSBundle mainBundle] resourcePath] ?: @"";
    tigerclaw::macos::Paths paths;
    paths.dataDirectory = std::filesystem::path(data.UTF8String);
    paths.resourceDirectory = std::filesystem::path(resources.UTF8String);
    paths.configFile = paths.dataDirectory / "config.txt";
    paths.lexiconRoot = paths.dataDirectory / "码表";
    paths.modelFile = paths.resourceDirectory / "Models" / "sentence-fivegram-mobile.bin";
    const char *modelOverride = std::getenv("TIGERCLAW_SENTENCE_MODEL");
    if (modelOverride && *modelOverride)
        paths.modelFile = std::filesystem::path(modelOverride);
    return paths;
}

void TigerClawPreloadEngine(void)
{
    Engine &engine = Engine::Shared();
    if (engine.Ready()) return;
    std::string error;
    if (!engine.Initialize(MakePaths(), error))
    {
        NSLog(@"TigerClaw engine initialization failed: %s", error.c_str());
    }
    else
    {
        NSLog(@"TigerClaw engine ready: schema=%@", ToNSString(engine.CurrentSchema()));
    }
}

// InputMethodKit does not invoke menu actions with the NSMenuItem as the
// sender. The command dictionary arrives through doCommandBySelector:; asking
// it for representedObject raises an exception and the schema never switches.
// Extract the schema name from both the menu item and the command dictionary.
static NSString *SchemaNameFromSender(id sender)
{
    if ([sender isKindOfClass:[NSMenuItem class]])
        return [(NSMenuItem *)sender representedObject];
    if ([sender isKindOfClass:[NSDictionary class]])
    {
        NSDictionary *command = (NSDictionary *)sender;
        for (NSString *key in @[@"representedObject", @"MenuItem", @"menuItem",
                                @"IMKCommandMenuItem", @"NSMenuItem", @"Item"])
        {
            id value = [command objectForKey:key];
            if ([value isKindOfClass:[NSMenuItem class]])
                return [(NSMenuItem *)value representedObject];
            if ([value isKindOfClass:[NSString class]])
                return value;
        }
        NSNumber *tag = [command objectForKey:@"tag"] ?: [command objectForKey:@"Tag"];
        if ([tag isKindOfClass:[NSNumber class]])
        {
            auto names = Engine::Shared().SchemaNames();
            NSInteger index = tag.integerValue;
            if (index >= 0 && index < (NSInteger)names.size())
                return ToNSString(names[static_cast<std::size_t>(index)]);
        }
    }
    return nil;
}

@interface TigerClawInputController : IMKInputController
@end

@implementation TigerClawInputController
{
    TigerClawCandidateWindow *_candidateWindow;
    __unsafe_unretained id _client;
    NSString *_clientBundleId;
    NSTimer *_pumpTimer;
    NSString *_lastMarked;
    BOOL _composing;
    BOOL _sentenceSchema;
    BOOL _shiftDown;
    BOOL _suppressNextPump;
    NSUInteger _candidatePageIndex;
    NSUInteger _candidatePageSize;
}

- (instancetype)initWithServer:(IMKServer *)server delegate:(id)delegate client:(id)client
{
    self = [super initWithServer:server delegate:delegate client:client];
    if (self)
    {
        TigerClawPreloadEngine();
        _candidateWindow = [TigerClawCandidateWindow sharedWindow];
        _lastMarked = nil;
        _composing = NO;
        _sentenceSchema = NO;
        _shiftDown = NO;
        _candidatePageIndex = 0;
        _candidatePageSize = 5;
        _client = client;
        _clientBundleId = [[client bundleIdentifier] copy];
        _lastMarked = nil;
    }
    return self;
}

- (void)dealloc
{
    [_pumpTimer invalidate];
    if (_clientBundleId) [_clientBundleId release];
    if (_lastMarked) [_lastMarked release];
    [super dealloc];
}

- (NSUInteger)recognizedEvents:(id)sender
{
    // IMK only forwards key events to handleEvent: when declared here. Text
    // events are deliberately not implemented: inputText: would take priority
    // and arrows/space would never reach the candidate list.
    return NSEventMaskKeyDown | NSEventMaskFlagsChanged;
}

- (NSMenu *)menu
{
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"虎爪"] autorelease];
    Engine &engine = Engine::Shared();
    auto current = engine.CurrentSchema();
    auto names = engine.SchemaNames();
    for (std::size_t i = 0; i < names.size(); ++i)
    {
        NSString *title = ToNSString(names[i]);
        NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title
                                                       action:@selector(selectSchema:)
                                                keyEquivalent:@""] autorelease];
        item.target = self;
        item.representedObject = title;
        item.tag = static_cast<NSInteger>(i);
        item.state = names[i] == current ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *reload = [[[NSMenuItem alloc] initWithTitle:@"重新载入词库"
                                                     action:@selector(reloadLexicons:)
                                              keyEquivalent:@""] autorelease];
    reload.target = self;
    [menu addItem:reload];
    NSMenuItem *config = [[[NSMenuItem alloc] initWithTitle:@"打开配置目录"
                                                     action:@selector(openDataDirectory:)
                                              keyEquivalent:@""] autorelease];
    config.target = self;
    [menu addItem:config];
    return menu;
}

- (void)selectSchema:(id)sender
{
    NSString *name = SchemaNameFromSender(sender);
    if (!name.length)
    {
        NSLog(@"TigerClaw menu: no schema name in sender: %@", sender);
        return;
    }
    NSLog(@"TigerClaw menu: switch schema to %@", name);
    Engine::Shared().Cancel();
    std::string error;
    if (!Engine::Shared().SwitchSchema(ToU16String(name), error)) {
        NSLog(@"TigerClaw schema switch failed: %s", error.c_str());
        NSBeep();
        return;
    }
    [self clearMarkedForClient:_client];
    [_candidateWindow hideCandidates];
    _composing = NO;
    _sentenceSchema = [name containsString:@"整句"];
    [self stopPump];
}

- (void)reloadLexicons:(id)sender
{
    std::string error;
    if (!Engine::Shared().Reload(error))
    {
        NSLog(@"TigerClaw reload failed: %s", error.c_str());
        NSBeep();
    }
}

- (void)openDataDirectory:(id)sender
{
    NSURL *url = [NSURL fileURLWithPath:[@"~/Library/Application Support/TigerClaw" stringByExpandingTildeInPath]];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)activateServer:(id)sender
{
    NSString *bundle = [sender bundleIdentifier];
    bool sameApplication = _clientBundleId.length && bundle.length &&
        [_clientBundleId isEqualToString:bundle];
    if (!sameApplication)
    {
        // A different application is focused. The previous composition must not
        // be pasted into the new document.
        Engine::Shared().Cancel();
        [_candidateWindow hideCandidates];
        [self stopPump];
        _composing = NO;
        if (_lastMarked) { [_lastMarked release]; _lastMarked = nil; }
    }
    _client = sender;
    if (_clientBundleId) { [_clientBundleId release]; _clientBundleId = nil; }
    _clientBundleId = [bundle copy];
    [super activateServer:sender];
    if (sameApplication)
    {
        // IMK may deactivate/reactivate the server for the same client while a
        // panel is shown. Restore the marked text and candidate list from the
        // engine instead of dropping the composition.
        if (_lastMarked) { [_lastMarked release]; _lastMarked = nil; }
        Snapshot snapshot = Engine::Shared().Capture();
        [self applySnapshot:snapshot client:sender];
    }
}

- (void)deactivateServer:(id)sender
{
    [_candidateWindow hideCandidates];
    [self stopPump];
    _client = nil;
    [super deactivateServer:sender];
}

- (void)clearMarkedForClient:(id)client
{
    if (!client) return;
    @try
    {
        [client setMarkedText:@""
              selectionRange:NSMakeRange(0, 0)
            replacementRange:NSMakeRange(NSNotFound, 0)];
    }
    @catch (...) {}
    if (_lastMarked) { [_lastMarked release]; _lastMarked = nil; }
}

- (void)applySnapshot:(const Snapshot &)snapshot client:(id)client
{
    if (snapshot.error.size()) NSLog(@"TigerClaw engine: %s", snapshot.error.c_str());
    if (!client) return;
    _sentenceSchema = snapshot.schema.find(u"整句") != std::u16string::npos;
    _candidatePageIndex = snapshot.pageIndex;
    _candidatePageSize = snapshot.pageSize > 0 ? static_cast<NSUInteger>(snapshot.pageSize) : 1;

    if (snapshot.action == 1)
    {
        NSString *code = !snapshot.inputBuffer.empty() ? ToNSString(snapshot.inputBuffer) : ToNSString(snapshot.raw);
        [self presentAddWordForCode:code client:client];
        return;
    }
    if (!snapshot.commit.empty())
    {
        NSString *text = ToNSString(snapshot.commit);
        std::u16string clientId = ClientId(client);
        std::string token = Engine::Shared().IssueLearningReceipt(clientId);
        [self clearMarkedForClient:client];
        @try
        {
            [client insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
        }
        @catch (...) {}
        Engine::Shared().AcknowledgeLearningReceipt(clientId, token, true);
        [_candidateWindow hideCandidates];
        _composing = NO;
        [self stopPump];
        return;
    }

    if (snapshot.cancelBeforePass)
    {
        [self clearMarkedForClient:client];
        [_candidateWindow hideCandidates];
    }

    _composing = snapshot.composing;
    if (snapshot.composing && !snapshot.markedText.empty())
    {
        NSString *marked = ToNSString(snapshot.markedText);
        if (![marked isEqualToString:_lastMarked])
        {
            @try
            {
                [client setMarkedText:marked
                       selectionRange:NSMakeRange(marked.length, 0)
                     replacementRange:NSMakeRange(NSNotFound, 0)];
            }
            @catch (...) {}
            if (_lastMarked) [_lastMarked release];
            _lastMarked = [marked copy];
        }
    }
    else if (_lastMarked.length)
    {
        [self clearMarkedForClient:client];
    }

    if (!snapshot.candidates.empty())
    {
        __unsafe_unretained TigerClawInputController *weakSelf = self;
        _candidateWindow.selectionHandler = ^(NSInteger index) {
            TigerClawInputController *strongSelf = weakSelf;
            if (!strongSelf || index < 0) return;
            // The panel passes a page-relative row. Sentence selection uses an
            // absolute candidate index; ordinary tables use the row as a digit.
            NSUInteger absolute = static_cast<NSUInteger>(index);
            if (strongSelf->_sentenceSchema)
                absolute = strongSelf->_candidatePageIndex * strongSelf->_candidatePageSize + absolute;
            Snapshot selected = Engine::Shared().SelectCandidate(static_cast<std::size_t>(absolute));
            [strongSelf applySnapshot:selected client:strongSelf->_client];
        };
        [_candidateWindow showCandidates:snapshot.candidates
                                selected:static_cast<NSInteger>(snapshot.selected)
                                    page:static_cast<NSInteger>(snapshot.pageIndex)
                                   pages:static_cast<NSInteger>(snapshot.pageCount)
                                 atPoint:[self caretPointForClient:client]
                                fontSize:snapshot.fontSize
                               showIndex:snapshot.showIndex
                                vertical:snapshot.candidateLayoutVertical];
    }
    else
    {
        [_candidateWindow hideCandidates];
    }

    if (snapshot.composing) [self startPump:client];
    else [self stopPump];
}

- (void)presentAddWordForCode:(NSString *)code client:(id)client
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = @"添加词语";
    alert.informativeText = @"把词语加入当前码表。编码留空则只写入提示词条。";
    [alert addButtonWithTitle:@"添加"];
    [alert addButtonWithTitle:@"取消"];

    NSView *accessory = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 54)] autorelease];
    NSTextField *codeLabel = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 30, 60, 20)] autorelease];
    codeLabel.stringValue = @"编码";
    codeLabel.bezeled = NO;
    codeLabel.drawsBackground = NO;
    codeLabel.editable = NO;
    NSTextField *codeField = [[[NSTextField alloc] initWithFrame:NSMakeRect(64, 28, 250, 24)] autorelease];
    codeField.stringValue = code.length ? code : @"";
    NSTextField *wordLabel = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 2, 60, 20)] autorelease];
    wordLabel.stringValue = @"词语";
    wordLabel.bezeled = NO;
    wordLabel.drawsBackground = NO;
    wordLabel.editable = NO;
    NSTextField *wordField = [[[NSTextField alloc] initWithFrame:NSMakeRect(64, 0, 250, 24)] autorelease];
    wordField.stringValue = @"";
    [accessory addSubview:codeLabel];
    [accessory addSubview:codeField];
    [accessory addSubview:wordLabel];
    [accessory addSubview:wordField];
    alert.accessoryView = accessory;
    [NSApp activateIgnoringOtherApps:YES];
    [alert.window makeFirstResponder:wordField];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn)
    {
        std::string error;
        if (!Engine::Shared().AddWord(ToU16String(codeField.stringValue), ToU16String(wordField.stringValue), error))
        {
            NSLog(@"TigerClaw add word failed: %s", error.c_str());
            NSBeep();
        }
        else
        {
            Engine::Shared().Cancel();
            [self clearMarkedForClient:client];
            [_candidateWindow hideCandidates];
            _composing = NO;
            [self stopPump];
        }
    }
    else
    {
        Engine::Shared().Cancel();
        [self clearMarkedForClient:client];
        [_candidateWindow hideCandidates];
        _composing = NO;
        [self stopPump];
    }
}

- (void)startPump:(id)client
{
    if (_pumpTimer) return;
    __unsafe_unretained TigerClawInputController *weakSelf = self;
    _pumpTimer = [NSTimer scheduledTimerWithTimeInterval:0.04
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
        TigerClawInputController *strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }
        [strongSelf pumpCandidates];
    }];
}

- (void)stopPump
{
    [_pumpTimer invalidate];
    _pumpTimer = nil;
}

- (void)pumpCandidates
{
    if (!_client) { [self stopPump]; return; }
    if (_suppressNextPump) { _suppressNextPump = NO; return; }
    Snapshot snapshot = Engine::Shared().Capture();
    if (!snapshot.composing)
    {
        _composing = NO;
        [self stopPump];
    }
    [self applySnapshot:snapshot client:_client];
}

- (BOOL)handleEvent:(NSEvent *)event client:(id)client
{
    if (event.type == NSEventTypeFlagsChanged)
    {
        [self handleFlagsChanged:event];
        return NO;
    }
    if (event.type != NSEventTypeKeyDown) return NO;
    if (!Engine::Shared().Ready()) return NO;
    tigerclaw::macos::PhysicalKey physical = tigerclaw::macos::KeyFromEvent((__bridge void *)event);
    if (!physical.valid) return NO;
    if (physical.command) return NO; // Command shortcuts belong to the client

    // Navigation keys must not move the client's caret while a composition is
    // active; otherwise the marked text is dropped. Up/Down select candidates
    // (sentence) or turn pages (ordinary tables).
    if (_composing)
    {
        if (physical.virtualKey == 37 || physical.virtualKey == 39 ||
            physical.virtualKey == 36 || physical.virtualKey == 35)
            return YES;
        if (!_sentenceSchema && (physical.virtualKey == 38 || physical.virtualKey == 40))
            physical.virtualKey = physical.virtualKey == 38 ? 189 : 187; // - / =
    }

    KeyInput input;
    input.virtualKey = physical.virtualKey;
    input.down = true;
    input.shift = physical.shift;
    input.ctrl = physical.ctrl;
    input.alt = physical.alt;
    input.command = physical.command;
    input.capsLock = physical.capsLock;
    input.repeat = physical.repeat;
    Snapshot snapshot = Engine::Shared().Process(input);
    if (!snapshot.handled)
    {
        if (snapshot.cancelBeforePass)
        {
            [self clearMarkedForClient:client];
            [_candidateWindow hideCandidates];
            _composing = NO;
            [self stopPump];
        }
        return NO;
    }
    if (std::getenv("TIGERCLAW_DEBUG"))
        NSLog(@"TigerClaw key vk=%d shift=%d handled=%d composing=%d schema=%@ marked=%@ commit=%@ cands=%zu pending=%d",
              physical.virtualKey, physical.shift, snapshot.handled, snapshot.composing,
              ToNSString(snapshot.schema), ToNSString(snapshot.markedText), ToNSString(snapshot.commit),
              snapshot.candidates.size(), snapshot.decodePending);
    [self applySnapshot:snapshot client:client];
    return YES;
}

- (void)flagsChanged:(NSEvent *)event
{
    [self handleFlagsChanged:event];
}

- (void)handleFlagsChanged:(NSEvent *)event
{
    // Shift toggles Chinese/English by default (shift切换中英文). IMK delivers
    // it as a flags-changed event, not a key-down, so translate it explicitly.
    auto flags = event.modifierFlags;
    BOOL shift = (flags & NSEventModifierFlagShift) != 0;
    if (shift == _shiftDown) return;
    _shiftDown = shift;
    if (!Engine::Shared().Ready()) return;
    KeyInput input;
    input.virtualKey = 0x10; // VK_SHIFT
    input.down = shift;
    input.shift = shift;
    input.ctrl = (flags & NSEventModifierFlagControl) != 0;
    input.alt = (flags & NSEventModifierFlagOption) != 0;
    input.capsLock = (flags & NSEventModifierFlagCapsLock) != 0;
    Snapshot snapshot = Engine::Shared().Process(input);
    if (std::getenv("TIGERCLAW_DEBUG"))
        NSLog(@"TigerClaw shift down=%d handled=%d commit=%@ composing=%d",
              shift, snapshot.handled, ToNSString(snapshot.commit), snapshot.composing);
    if (_client && (snapshot.handled || !snapshot.commit.empty()))
        [self applySnapshot:snapshot client:_client];
}

- (NSPoint)caretPointForClient:(id)client
{
    NSRect caret = NSZeroRect;
    if ([client respondsToSelector:@selector(firstRectForCharacterRange:actualRange:)])
    {
        NSRange selection = NSMakeRange(NSNotFound, 0);
        if ([client respondsToSelector:@selector(selectedRange)]) selection = [client selectedRange];
        if (selection.location != NSNotFound)
            caret = [client firstRectForCharacterRange:selection actualRange:NULL];
        if (NSIsEmptyRect(caret))
            caret = [client firstRectForCharacterRange:NSMakeRange(NSNotFound, 0) actualRange:NULL];
    }
    if (NSIsEmptyRect(caret) &&
        [client respondsToSelector:@selector(attributesForCharacterIndex:lineHeightRectangle:)])
    {
        // Squirrel's preferred probe: many web/Electron clients implement this
        // even when firstRectForCharacterRange returns an empty rectangle.
        NSRect line = NSZeroRect;
        [client attributesForCharacterIndex:0 lineHeightRectangle:&line];
        if (!NSIsEmptyRect(line)) caret = line;
    }
    if (NSIsEmptyRect(caret))
    {
        NSPoint mouse = [NSEvent mouseLocation];
        caret = NSMakeRect(mouse.x, mouse.y - 28, 0, 0);
    }
    return caret.origin;
}
@end
