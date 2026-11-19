/*
 * apple_menu.h -- the macOS menu bar's Settings... item (apple_menu.m): it
 * opens the overlay menu (src/overlay). Main thread.
 */
#ifndef APPLE_MENU_H
#define APPLE_MENU_H

#include <SDL.h>

/* NFS Underground 2 > Settings... (Cmd+,) in the menu bar SDL made. */
void apple_menu_install(SDL_Window *win);

/* apple_main.c: full screen on/off (its borderless full-panel window). */
void apple_set_fullscreen(int on);
int apple_is_fullscreen(void);

#endif
