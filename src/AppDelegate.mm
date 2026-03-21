#import "AppDelegate.h"
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>

#define CONFIG_PATH [NSHomeDirectory() stringByAppendingPathComponent:@"/Library/Application Support/ClipTyper/config.json"]

@implementation AppDelegate {
    NSMutableDictionary *config;
    NSMenuItem *zhSpeedItem;
    NSMenuItem *enSpeedItem;
    NSMenuItem *delayItem;
    NSMenuItem *hotkeyItem;
    id _eventMonitor;
    NSStatusItem *_statusItem;

    BOOL _isTyping;
    BOOL _shouldStopTyping;
    dispatch_queue_t _typingQueue;
}

- (BOOL)checkAccessibilityPermission {
    if (AXIsProcessTrusted()) {
        NSLog(@"✅ 已获得辅助功能权限");
        return YES;
    }

    NSLog(@"⚠️ 未获得辅助功能权限");
    [self showAccessibilityPermissionAlertAndQuit];
    return NO;
}

- (void)showAccessibilityPermissionAlertAndQuit {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"需要开启辅助功能权限"];
    [alert setInformativeText:@"ClipTyper 需要辅助功能权限才能模拟键盘输入。\n\n请前往：系统设置 → 隐私与安全性 → 辅助功能，并把 ClipTyper 打开。\n\n程序将退出。"];
    [alert addButtonWithTitle:@"打开系统设置并退出"];
    [alert addButtonWithTitle:@"直接退出"];

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
        [[NSWorkspace sharedWorkspace] openURL:url];
    }

    [NSApp terminate:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSLog(@"✅ 应用启动成功");

    _typingQueue = dispatch_queue_create("com.cliptyper.typing", DISPATCH_QUEUE_SERIAL);
    _isTyping = NO;
    _shouldStopTyping = NO;

    if (![self checkAccessibilityPermission]) {
        return;
    }

    [self loadOrInitConfig];

    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];

    NSString *path = [[NSBundle mainBundle] pathForResource:@"logo_menu" ofType:@"png"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSLog(@"❌ 找不到图标文件: %@", path);
    } else {
        NSLog(@"✅ 找到图标文件: %@", path);
    }

    NSImage *icon = [[NSImage alloc] initWithContentsOfFile:path];
    if (icon) {
        [icon setTemplate:NO];
        _statusItem.button.image = icon;
        NSLog(@"✅ 成功设置菜单栏图标");
    } else {
        NSLog(@"❌ 图标加载失败");
    }

    NSMenu *menu = [[NSMenu alloc] init];

    zhSpeedItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"中文打字速度: %@ms", config[@"zhSpeed"] ?: @"120"]
                                             action:@selector(changeZhSpeed)
                                      keyEquivalent:@""];
    [menu addItem:zhSpeedItem];

    enSpeedItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"英文打字速度: %@ms", config[@"enSpeed"] ?: @"50"]
                                             action:@selector(changeEnSpeed)
                                      keyEquivalent:@""];
    [menu addItem:enSpeedItem];

    delayItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"触发延迟: %@ms", config[@"delay"] ?: @"300"]
                                           action:@selector(changeDelay)
                                    keyEquivalent:@""];
    [menu addItem:delayItem];

    NSUInteger keyCode = [config[@"keyCode"] unsignedIntegerValue];
    NSUInteger modFlags = [config[@"modifierFlags"] unsignedIntegerValue];
    hotkeyItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"快捷键: %@",
                                                    [self describeHotkeyWithKeyCode:keyCode modifiers:modFlags]]
                                            action:@selector(changeHotkey)
                                     keyEquivalent:@""];
    [menu addItem:hotkeyItem];

    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"退出" action:@selector(quitApp:) keyEquivalent:@"q"];

    _statusItem.menu = menu;

    [self registerGlobalHotkey];
}

- (NSString *)configDirectoryPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"/Library/Application Support/ClipTyper"];
}

- (void)ensureConfigDirectoryExists {
    NSString *configDir = [self configDirectoryPath];
    NSFileManager *fm = [NSFileManager defaultManager];

    BOOL isDirectory = NO;
    BOOL exists = [fm fileExistsAtPath:configDir isDirectory:&isDirectory];
    if (exists && isDirectory) {
        return;
    }

    NSError *error = nil;
    BOOL ok = [fm createDirectoryAtPath:configDir
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:&error];
    if (!ok) {
        NSLog(@"❌ 创建配置目录失败: %@, error=%@", configDir, error);
    }
}

- (void)loadOrInitConfig {
    [self ensureConfigDirectoryExists];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:CONFIG_PATH]) {
        config = [@{
            @"zhSpeed": @"120",
            @"enSpeed": @"50",
            @"delay": @"300",
            @"keyCode": @(35), // P 键
            @"modifierFlags": @(NSEventModifierFlagControl | NSEventModifierFlagOption) // ⌃⌥
        } mutableCopy];
        [self saveConfig];
        return;
    }

    NSData *data = [NSData dataWithContentsOfFile:CONFIG_PATH];
    if (data) {
        NSError *jsonError = nil;
        NSDictionary *jsonObject = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&jsonError];
        if ([jsonObject isKindOfClass:[NSDictionary class]]) {
            config = [jsonObject mutableCopy];
        } else {
            NSLog(@"⚠️ 配置文件格式无效，使用默认配置。error=%@", jsonError);
            config = [NSMutableDictionary dictionary];
        }
    } else {
        NSLog(@"⚠️ 读取配置文件失败，使用默认配置。");
        config = [NSMutableDictionary dictionary];
    }

    if (!config) {
        config = [NSMutableDictionary dictionary];
    }

    if (!config[@"zhSpeed"]) {
        config[@"zhSpeed"] = @"120";
    }
    if (!config[@"enSpeed"]) {
        config[@"enSpeed"] = @"50";
    }
    if (!config[@"delay"]) {
        config[@"delay"] = @"300";
    }

    // 兼容旧键名：hotkeyKeyCode / hotkeyModifierFlags -> keyCode / modifierFlags
    if (!config[@"keyCode"]) {
        if (config[@"hotkeyKeyCode"]) {
            config[@"keyCode"] = config[@"hotkeyKeyCode"];
        } else {
            config[@"keyCode"] = @(35); // P 键
        }
    }

    if (!config[@"modifierFlags"]) {
        if (config[@"hotkeyModifierFlags"]) {
            config[@"modifierFlags"] = config[@"hotkeyModifierFlags"];
        } else {
            config[@"modifierFlags"] = @(NSEventModifierFlagControl | NSEventModifierFlagOption);
        }
    }

    // 清理旧键名，避免后续继续混用
    [config removeObjectForKey:@"hotkeyKeyCode"];
    [config removeObjectForKey:@"hotkeyModifierFlags"];

    [self saveConfig];
}

- (void)saveConfig {
    [self ensureConfigDirectoryExists];

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&jsonError];
    if (!data) {
        NSLog(@"❌ 序列化配置失败: %@", jsonError);
        return;
    }

    NSError *writeError = nil;
    BOOL ok = [data writeToFile:CONFIG_PATH options:NSDataWritingAtomic error:&writeError];
    if (!ok) {
        NSLog(@"❌ 保存配置失败: %@, error=%@", CONFIG_PATH, writeError);
    }
}

- (void)changeZhSpeed {
    [self promptForKey:@"zhSpeed" label:@"中文打字速度(ms)" menuItem:zhSpeedItem];
}

- (void)changeEnSpeed {
    [self promptForKey:@"enSpeed" label:@"英文打字速度(ms)" menuItem:enSpeedItem];
}

- (void)changeDelay {
    [self promptForKey:@"delay" label:@"触发延迟(ms)" menuItem:delayItem];
}

- (void)promptForKey:(NSString *)key label:(NSString *)label menuItem:(NSMenuItem *)item {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:label];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    input.stringValue = config[key] ?: @"100";
    [alert setAccessoryView:input];

    [alert addButtonWithTitle:@"确定"];
    [alert addButtonWithTitle:@"取消"];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        config[key] = input.stringValue;
        [self saveConfig];
        item.title = [NSString stringWithFormat:@"%@: %@ms", label, input.stringValue];
    }
}

- (void)quitApp:(id)sender {
    [[NSApplication sharedApplication] terminate:nil];
}

- (void)startTypingClipboardText {
    if (_isTyping) {
        return;
    }

    if (!AXIsProcessTrusted()) {
        NSLog(@"⚠️ 未获得辅助功能权限，无法模拟输入");
        [self showAccessibilityPermissionAlertAndQuit];
        return;
    }

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSString *text = [pasteboard stringForType:NSPasteboardTypeString];

    if (!text || text.length == 0) {
        NSLog(@"⚠️ 剪贴板无文本");
        return;
    }

    _isTyping = YES;
    _shouldStopTyping = NO;

    dispatch_async(_typingQueue, ^{
        [self typeClipboardTextInternal:text];
    });
}

- (void)stopTyping {
    if (!_isTyping) {
        return;
    }

    NSLog(@"⏹️ 请求停止输入");
    _shouldStopTyping = YES;
}

- (void)typeClipboardTextInternal:(NSString *)text {
    @autoreleasepool {
        NSUInteger length = [text length];

        for (NSUInteger i = 0; i < length; i++) {
            if (_shouldStopTyping) {
                NSLog(@"⏹️ 输入已停止");
                break;
            }

            UniChar c = [text characterAtIndex:i];

            // 兼容 Windows 风格换行 \r\n：把它当成一次回车
            if (c == '\r') {
                if (i + 1 < length && [text characterAtIndex:i + 1] == '\n') {
                    i++;
                }

                CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
                CGEventRef keyDown = CGEventCreateKeyboardEvent(source, (CGKeyCode)36, true);   // Return
                CGEventRef keyUp = CGEventCreateKeyboardEvent(source, (CGKeyCode)36, false);

                CGEventPost(kCGHIDEventTap, keyDown);
                CGEventPost(kCGHIDEventTap, keyUp);

                CFRelease(keyDown);
                CFRelease(keyUp);
                CFRelease(source);

                usleep([config[@"enSpeed"] intValue] * 1000);
                continue;
            }

            // Unix/macOS 风格换行 \n
            if (c == '\n') {
                CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
                CGEventRef keyDown = CGEventCreateKeyboardEvent(source, (CGKeyCode)36, true);   // Return
                CGEventRef keyUp = CGEventCreateKeyboardEvent(source, (CGKeyCode)36, false);

                CGEventPost(kCGHIDEventTap, keyDown);
                CGEventPost(kCGHIDEventTap, keyUp);

                CFRelease(keyDown);
                CFRelease(keyUp);
                CFRelease(source);

                usleep([config[@"enSpeed"] intValue] * 1000);
                continue;
            }

            if (c == '\t') {
                CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
                CGEventRef keyDown = CGEventCreateKeyboardEvent(source, (CGKeyCode)48, true);   // Tab
                CGEventRef keyUp = CGEventCreateKeyboardEvent(source, (CGKeyCode)48, false);

                CGEventPost(kCGHIDEventTap, keyDown);
                CGEventPost(kCGHIDEventTap, keyUp);

                CFRelease(keyDown);
                CFRelease(keyUp);
                CFRelease(source);

                usleep([config[@"enSpeed"] intValue] * 1000);
                continue;
            }

            CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
            CGEventRef keyDown = CGEventCreateKeyboardEvent(source, 0, true);
            CGEventRef keyUp = CGEventCreateKeyboardEvent(source, 0, false);

            CGEventKeyboardSetUnicodeString(keyDown, 1, &c);
            CGEventKeyboardSetUnicodeString(keyUp, 1, &c);

            CGEventPost(kCGHIDEventTap, keyDown);
            CGEventPost(kCGHIDEventTap, keyUp);

            CFRelease(keyDown);
            CFRelease(keyUp);
            CFRelease(source);

            BOOL isChinese = (c >= 0x4E00 && c <= 0x9FFF);
            int sleepTime = isChinese ? [config[@"zhSpeed"] intValue] : [config[@"enSpeed"] intValue];
            usleep(sleepTime * 1000);
        }

        _shouldStopTyping = NO;
        _isTyping = NO;
        NSLog(@"✅ 模拟输入结束");
    }
}

- (void)changeHotkey {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"设置快捷键"];
    [alert setInformativeText:@"请直接按下新的组合键，然后点击“确定”。"];

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 52)];

    NSTextField *displayField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 8, 260, 28)];
    displayField.editable = NO;
    displayField.bezeled = YES;
    displayField.drawsBackground = YES;
    displayField.alignment = NSTextAlignmentCenter;
    displayField.stringValue = [self describeHotkeyWithKeyCode:[config[@"keyCode"] unsignedIntegerValue]
                                                     modifiers:[config[@"modifierFlags"] unsignedIntegerValue]];
    [container addSubview:displayField];

    [alert setAccessoryView:container];
    [alert addButtonWithTitle:@"确定"];
    [alert addButtonWithTitle:@"取消"];

    __block NSUInteger capturedKeyCode = [config[@"keyCode"] unsignedIntegerValue];
    __block NSUInteger capturedModifiers = [config[@"modifierFlags"] unsignedIntegerValue];
    __block BOOL keyCaptured = NO;

    id localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                            handler:^NSEvent * _Nullable(NSEvent *event) {
        NSUInteger modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;

        // 忽略单独按修饰键的情况
        if (event.keyCode == 54 || event.keyCode == 55 ||   // Command
            event.keyCode == 56 || event.keyCode == 60 ||   // Shift
            event.keyCode == 58 || event.keyCode == 61 ||   // Option
            event.keyCode == 59 || event.keyCode == 62) {   // Control
            return nil;
        }

        // 不把回车当作录制的快捷键，避免用户点确定时混淆
        if (event.keyCode == 36) {
            return event;
        }

        capturedKeyCode = event.keyCode;
        capturedModifiers = modifiers;
        keyCaptured = YES;

        displayField.stringValue = [self describeHotkeyWithKeyCode:capturedKeyCode
                                                         modifiers:capturedModifiers];
        return nil;
    }];

    NSModalResponse response = [alert runModal];
    [NSEvent removeMonitor:localMonitor];

    if (response != NSAlertFirstButtonReturn || !keyCaptured) {
        return;
    }

    NSUInteger effectiveModifiers = capturedModifiers & NSEventModifierFlagDeviceIndependentFlagsMask;

    // 禁止单键快捷键
    if (effectiveModifiers == 0) {
        NSAlert *errorAlert = [[NSAlert alloc] init];
        [errorAlert setMessageText:@"快捷键无效"];
        [errorAlert setInformativeText:@"禁止使用单个字符键作为快捷键，请至少包含一个修饰键（如 Control、Option、Command、Shift）。"];
        [errorAlert addButtonWithTitle:@"确定"];
        [errorAlert runModal];
        return;
    }

    config[@"keyCode"] = @(capturedKeyCode);
    config[@"modifierFlags"] = @(effectiveModifiers);
    [self saveConfig];

    hotkeyItem.title = [NSString stringWithFormat:@"快捷键: %@",
                        [self describeHotkeyWithKeyCode:capturedKeyCode modifiers:effectiveModifiers]];
    [self registerGlobalHotkey];
}

- (void)registerGlobalHotkey {
    if (_eventMonitor) {
        [NSEvent removeMonitor:_eventMonitor];
        _eventMonitor = nil;
    }

    NSUInteger keyCode = [config[@"keyCode"] unsignedIntegerValue];
    NSUInteger modFlags = [config[@"modifierFlags"] unsignedIntegerValue] & NSEventModifierFlagDeviceIndependentFlagsMask;

    // 防御性检查：禁止注册无修饰键的单键热键
    if (modFlags == 0) {
        NSLog(@"⚠️ 快捷键配置无效：禁止使用无修饰键的单键快捷键");
        return;
    }

    _eventMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                           handler:^(NSEvent *event) {
        NSUInteger eventModifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        if (event.keyCode == keyCode && eventModifiers == modFlags) {
            if (self->_isTyping) {
                NSLog(@"⏹️ 再次按下快捷键，停止输入");
                [self stopTyping];
                return;
            }

            NSLog(@"✅ 快捷键触发！");

            double delayMs = [self->config[@"delay"] doubleValue];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                if (!self->_isTyping) {
                    [self startTypingClipboardText];
                }
            });
        }
    }];
}

- (NSString *)describeHotkeyWithKeyCode:(NSUInteger)keyCode modifiers:(NSUInteger)modifiers {
    NSMutableString *desc = [NSMutableString string];

    if (modifiers & NSEventModifierFlagControl) [desc appendString:@"⌃"];
    if (modifiers & NSEventModifierFlagOption) [desc appendString:@"⌥"];
    if (modifiers & NSEventModifierFlagCommand) [desc appendString:@"⌘"];
    if (modifiers & NSEventModifierFlagShift) [desc appendString:@"⇧"];

    TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
    CFDataRef layoutData = (CFDataRef)TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData);

    if (layoutData) {
        const UCKeyboardLayout *keyboardLayout = (const UCKeyboardLayout *)CFDataGetBytePtr(layoutData);
        UInt32 deadKeyState = 0;
        UniCharCount maxStringLength = 4;
        UniCharCount actualStringLength = 0;
        UniChar unicodeString[4];

        OSStatus status = UCKeyTranslate(keyboardLayout,
                                         (UInt16)keyCode,
                                         kUCKeyActionDisplay,
                                         0,
                                         LMGetKbdType(),
                                         kUCKeyTranslateNoDeadKeysBit,
                                         &deadKeyState,
                                         maxStringLength,
                                         &actualStringLength,
                                         unicodeString);

        if (status == noErr && actualStringLength > 0) {
            NSString *keyStr = [NSString stringWithCharacters:unicodeString length:1];
            [desc appendString:[keyStr uppercaseString]];
        } else {
            [desc appendString:@"?"];
        }
    } else {
        [desc appendString:@"?"];
    }

    if (source) {
        CFRelease(source);
    }

    return desc;
}

@end