/*
 * overlay.h -- the in-game overlay: a settings menu drawn over the game with
 * Dear ImGui (overlay.mm), the same for every port (NFSU2 first; NFSU1, HP2,
 * ProStreet and Undercover later). Modelled on SpeedBreaker's settings menu
 * (project(u), GPL-3.0-or-later): pages, one row per option, a controller
 * first, Quit Game in the footer.
 *
 *   - Open/close: F1, Back + Start on a controller, Cmd+, (the menu bar).
 *     Esc or B closes it too.
 *   - While it is open it owns the keyboard and the controllers: the game
 *     reads a neutral pad (xbox_input_blocked) until every button is up again.
 *   - Threads: SDL events arrive on the main thread (overlay_event, queued);
 *     the menu is laid out and drawn where the game presents its frame
 *     (overlay_present_metal, the render thread). Things only the main thread
 *     may do (full screen, quit, opening a folder) are requested from the
 *     menu and run by overlay_main_tick.
 *   - Which rows exist is the game's table (overlay_options.h), so each game
 *     shows only its own settings, and marks those that apply at the next
 *     start.
 */
#ifndef OVERLAY_H
#define OVERLAY_H

#include <SDL.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Main thread, before the window exists: settings.ini (the working directory)
 * read, and every option's value applied (environment defaults for the
 * game's start-up, live state for the rest). */
void overlay_settings_load(void);

/* Main thread, once the window exists. */
void overlay_init(SDL_Window *window);

/* Main thread, every SDL event before anyone else sees it. 1: the overlay took
 * it (the game must not see it). */
int overlay_event(const SDL_Event *e);

/* Main thread, every turn of the event loop: runs what the menu asked for. */
void overlay_main_tick(void);

/* Any thread. */
int overlay_is_open(void);
void overlay_toggle(void);

/* Render thread, after the game's frame is in the drawable, before it is
 * presented: draws the menu when it is open. (id<MTLCommandBuffer>,
 * id<MTLTexture>) as void *, for the C renderer. */
void overlay_present_metal(void *command_buffer, void *texture);

#ifdef __cplusplus
}
#endif

#endif
