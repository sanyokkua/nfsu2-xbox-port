/*
 * overlay_options.h -- the game's table of settings for the overlay menu.
 *
 * One OverlayOption per row; the game defines overlay_game_options() (for
 * NFSU2: src/overlay/nfsu2_options.c). An option is either
 *
 *   - kept in settings.ini (`key` set, `values` = what the file holds for each
 *     choice): overlay.mm reads and writes it, and calls `apply` with the
 *     choice at start (at_start 1) and on every change (0). `apply` sets the
 *     environment the game reads at start, or changes the live state; or
 *   - kept by the game itself (`key` NULL): `get` reads the current choice,
 *     `set` changes and saves it (the game's own options file).
 *
 * `where` says where the player will see the change (races, menus, the whole
 * picture...); the help area shows it with `help` and when it applies.
 * `restart` 1: the game reads it only at start; the menu shows "restart"
 * while the chosen value differs from the one this run started with.
 * An action row (`action` set, no choices) runs `action` on A / Enter / click.
 * Callbacks run on the render thread (where the menu lives); use
 * overlay_request() for what must happen on the main thread.
 */
#ifndef OVERLAY_OPTIONS_H
#define OVERLAY_OPTIONS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OverlayOption {
    const char *page;               /* "Display", "Graphics", "Audio", "Input", "Advanced" */
    const char *label;
    const char *help;               /* the line under the rows when it is chosen */
    const char *where;              /* where the change shows: "Races and the city", ... */
    const char *const *choices;     /* labels shown, n of them */
    int n;
    int def;                        /* default choice */
    int restart;                    /* 1: applies at the next start */
    const char *key;                /* settings.ini key, or NULL */
    const char *const *values;      /* settings.ini value of each choice */
    void (*apply)(int choice, int at_start);
    int (*get)(void);               /* key NULL: the game's own value */
    void (*set)(int choice);
    void (*action)(void);           /* an action row: no choices */
    const char *action_label;       /* its value column, e.g. "Open" */
} OverlayOption;

/* The game's table, in menu order (pages appear in the order they first do). */
const OverlayOption *overlay_game_options(int *count);

/* The game's name for titles and the Quit prompt, and the lines of Advanced's
 * about text (NULL-terminated). */
const char *overlay_game_title(void);
const char *const *overlay_game_about(void);

/* Main-thread requests (overlay_main_tick runs them). */
enum {
    OVERLAY_REQ_FULLSCREEN_ON = 1,
    OVERLAY_REQ_FULLSCREEN_OFF,
    OVERLAY_REQ_QUIT,
    OVERLAY_REQ_OPEN_LOGS,
};
void overlay_request(int what);

#ifdef __cplusplus
}
#endif

#endif
