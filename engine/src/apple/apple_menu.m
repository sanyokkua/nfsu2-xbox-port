/*
 * apple_menu.m -- Settings... (Cmd+,) in the app menu SDL makes (Quit is Cmd+Q
 * there). It opens and closes the overlay menu (src/overlay/overlay.h), which
 * F1 and Back + Start on a controller open too.
 */
#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include "apple_menu.h"
#include "../overlay/overlay.h"

@interface NFSSettingsItem : NSObject
@end
@implementation NFSSettingsItem
- (void)toggle:(id)sender
{
    overlay_toggle();
}
@end

static NFSSettingsItem *s_target;

void apple_menu_install(SDL_Window *win)
{
    NSMenu *app = NSApp.mainMenu.itemArray.firstObject.submenu;
    NSMenuItem *item = nil;
    NSInteger at = 0;

    (void)win;
    if (!app) {
        fprintf(stderr, "[menu] no app menu: Settings... not added\n");
        return;
    }
    s_target = [NFSSettingsItem new];
    /* SDL's menu may already have a Settings... (Preferences...) item that does
     * nothing; take it over rather than add a second one. */
    for (NSMenuItem *m in app.itemArray)
        if ([m.keyEquivalent isEqualToString:@","] || [m.title hasPrefix:@"Settings"] ||
            [m.title hasPrefix:@"Preferences"]) {
            item = m;
            break;
        }
    if (!item) {
        if (app.numberOfItems > 1 && [app itemAtIndex:1].isSeparatorItem)
            at = 2;     /* after "About ..." and its separator, where macOS apps keep it */
        item = [[NSMenuItem alloc] initWithTitle:@"Settings…" action:NULL keyEquivalent:@","];
        [app insertItem:item atIndex:at];
        [app insertItem:[NSMenuItem separatorItem] atIndex:at + 1];
    }
    item.title = @"Settings… (F1)";
    item.keyEquivalent = @",";
    item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    item.action = @selector(toggle:);
    item.target = s_target;
    item.enabled = YES;
}
