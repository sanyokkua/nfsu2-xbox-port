/*
 * apple_window.m -- fullscreen over the whole panel, the notch strip included
 * (v1.0.1, owner 2026-11-07 "чорні смуги"). macOS keeps a fullscreen window
 * (a Space or SDL's non-Space one) below the camera housing: a black strip
 * at the top of a 16:10 MacBook. Hiding the menu bar and the Dock and giving
 * the window the screen's whole frame puts the picture there too (the
 * camera covers a few pixels in the middle). The window is SDL's, borderless
 * (apple_main.c), not in fullscreen mode: AppKit keeps a fullscreen window's
 * frame. NFSU2_NOTCH=0: SDL's fullscreen as before.
 */
#import <AppKit/AppKit.h>
#import <objc/message.h>

#include <stdio.h>
#include <stdlib.h>

/* After the launcher's execv the game image is not the app LaunchServices activated:
 * macOS 14+ cooperative activation ignores activateIgnoringOtherApps there, so ask with
 * -activate as well, and bring the window in front of the Finder's (owner 2026-11-07:
 * "треба мишою клацнути по екрану"). */
static void apple_activate(NSWindow *w)
{
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    if ([NSApp respondsToSelector:@selector(activate)])
        [NSApp performSelector:@selector(activate)];
    [NSApp activateIgnoringOtherApps:YES];
    [[NSRunningApplication currentApplication] activateWithOptions:NSApplicationActivateAllWindows];
    [w makeKeyAndOrderFront:nil];
    [w orderFrontRegardless];
}

/* Pads keep sending while another app is in front (GameController's own switch; SDL's
 * JOYSTICK_ALLOW_BACKGROUND_EVENTS hint covers SDL's side). No link to the framework:
 * SDL has loaded it. Call before SDL_Init. */
void apple_pads_background(void)
{
    Class gc = NSClassFromString(@"GCController");
    if (gc && [gc respondsToSelector:@selector(setShouldMonitorBackgroundEvents:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(gc, @selector(setShouldMonitorBackgroundEvents:), YES);
        fprintf(stderr, "[apple] pads monitored in the background\n");
    }
}

void apple_window_full_panel(void *nswindow)
{
    NSWindow *w = (__bridge NSWindow *)nswindow;
    NSScreen *sc;
    if (!w)
        return;
    sc = w.screen ? w.screen : [NSScreen mainScreen];
    if (!sc)
        return;
    [NSApp setPresentationOptions:NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar];
    w.level = NSMainMenuWindowLevel + 1;
    /* No rim (owner 2026-11-09 "біла рамка"): macOS draws a 1 px light outline with the
     * shadow of every non-fullscreen window, borderless ones too; over the game it is a
     * white frame round the screen. */
    w.hasShadow = NO;
    w.opaque = YES;
    w.backgroundColor = NSColor.blackColor;
    [w setFrame:sc.frame display:YES];
    /* Key and active: macOS gives pad (GameController) and key input to the active app only. */
    apple_activate(w);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!w.isKeyWindow || !NSApp.isActive)
            apple_activate(w);
        fprintf(stderr, "[apple] window key %d, app active %d (3 s)\n", (int)w.isKeyWindow, (int)NSApp.isActive);
    });
    fprintf(stderr, "[apple] window over the whole panel %.0fx%.0f pt (notch %.0f pt)\n",
            sc.frame.size.width, sc.frame.size.height,
            [sc respondsToSelector:@selector(safeAreaInsets)] ? sc.safeAreaInsets.top : 0.0);
}

int apple_window_notch_on(void)
{
    const char *e = getenv("NFSU2_NOTCH");
    return !(e && *e == '0');
}

void apple_window_restore(void)
{
    [NSApp setPresentationOptions:NSApplicationPresentationDefault];
}
