/*
 * apple_menu.h -- the macOS menu bar's Settings... item and its window
 * (apple_menu.m). Mac only; both run on the main thread.
 */
#ifndef APPLE_MENU_H
#define APPLE_MENU_H

#include <SDL.h>

/* settings.ini (the working directory) as environment defaults, before the
 * window is made and the game starts. Variables already set win. */
void apple_settings_load(void);

/* NFS Underground 2 > Settings... (Cmd+,) in the menu bar SDL made. */
void apple_menu_install(SDL_Window *win);

/* The Settings window, as the menu item does (F1 in apple_main.c's event loop). */
void apple_settings_show(void);

/* apple_main.c: full screen on/off (its borderless full-panel window). */
void apple_set_fullscreen(int on);
int apple_is_fullscreen(void);

#endif
