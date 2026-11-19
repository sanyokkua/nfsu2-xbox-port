/*
 * nfsu2_options.c -- NFS Underground 2's rows in the overlay menu
 * (overlay_options.h). Only what this port has: the Metal renderer's picture
 * options, NFSU2Deadware's frame rate, effects and draw distance, the game's
 * Options rows (src/recomp_manual.c), the host's sound volume and keyboard.
 *
 * Live: everything but Frame Rate and Keyboard as Controller, which the game
 * reads at start (the flip interval wrapper, the keyboard pad).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "overlay_options.h"

#ifndef NFSU2_PORT_VERSION
#define NFSU2_PORT_VERSION "dev"
#endif
#ifndef NFSU2_PORT_COMMIT
#define NFSU2_PORT_COMMIT "local"
#endif

/* The game's Options rows (recomp_manual.c) and the renderer's switches. */
int nfsu2_option_get(int which);
void nfsu2_option_set(int which, int choice);
void nfsu2_set_draw_distance(float f);
void nv2a_mtl_post_reload(void);
void xa2_set_master_volume(float v);
extern volatile int nv2a_mtl_fps_overlay;
extern volatile int nv2a_mtl_blur_off;

enum { OPT_REFLECTIONS, OPT_SCALE, OPT_FXAA, OPT_ANISO, OPT_SQUARE, OPT_VIBRATION };

/* An environment variable the game reads: at start only where nothing set it
 * by hand (a variable set by hand wins for that run); on a change, always. */
static void env(const char *k, const char *v, int at_start)
{
    setenv(k, v, !at_start);
}

static const char *const k_onoff[] = { "Off", "On" };
static const char *const k_01[] = { "0", "1" };

/* Display */
static const char *const k_display[] = { "Window", "Full Screen" };
static void apply_display(int c, int at_start)
{
    if (at_start)
        env("NFSU2_FULLSCREEN", c ? "1" : "0", 1);
    else
        overlay_request(c ? OVERLAY_REQ_FULLSCREEN_ON : OVERLAY_REQ_FULLSCREEN_OFF);
}

static const char *const k_scale[] = { "1x (640 x 480)", "1.5x (960 x 720)", "2x (1280 x 960)",
                                       "2.5x (1600 x 1200)", "4x (2560 x 1920)" };
static int get_scale(void) { return nfsu2_option_get(OPT_SCALE); }
static void set_scale(int c) { nfsu2_option_set(OPT_SCALE, c); }

static const char *const k_fps[] = { "60 fps", "120 fps", "30 fps (the original)" };
static const char *const k_fps_v[] = { "60", "120", "30" };
static void apply_fps(int c, int at_start) { env("NFSU2_FPS_CAP", k_fps_v[c], at_start); }

/* Graphics */
static int get_fxaa(void) { return nfsu2_option_get(OPT_FXAA); }
static void set_fxaa(int c) { nfsu2_option_set(OPT_FXAA, c); }
static const char *const k_aniso[] = { "Off", "2x", "4x", "8x", "16x" };
static int get_aniso(void) { return nfsu2_option_get(OPT_ANISO); }
static void set_aniso(int c) { nfsu2_option_set(OPT_ANISO, c); }
static int get_square(void) { return nfsu2_option_get(OPT_SQUARE); }
static void set_square(int c) { nfsu2_option_set(OPT_SQUARE, c); }
static int get_refl(void) { return nfsu2_option_get(OPT_REFLECTIONS); }
static void set_refl(int c) { nfsu2_option_set(OPT_REFLECTIONS, c); }

static const char *const k_draw[] = { "Normal (the original)", "Far (x2)" };
static const char *const k_draw_v[] = { "1", "2" };
static void apply_draw(int c, int at_start)
{
    env("NFSU2_DRAW_DISTANCE", k_draw_v[c], at_start);
    if (!at_start)
        nfsu2_set_draw_distance((float)atof(k_draw_v[c]));
}

static const char *const k_gamma[] = { "Original", "Modern (brighter)", "Warm" };
static const char *const k_gamma_v[] = { "original", "modern", "warm" };
static void apply_gamma(int c, int at_start)
{
    env("NFSU2_GAMMA", k_gamma_v[c], at_start);
    if (!at_start)
        nv2a_mtl_post_reload();
}

static const char *const k_fx[] = { "Bloom", "Bloom + Ambient Occlusion", "Off" };
static const char *const k_fx_v[] = { "bloom", "ssao", "off" };
static void apply_fx(int c, int at_start)
{
    env("NFSU2_AO", c == 1 ? "1" : "0", at_start);
    env("NFSU2_BLOOM", c == 2 ? "0" : "0.35", at_start);
    if (!at_start)
        nv2a_mtl_post_reload();
}

static const char *const k_blur_v[] = { "off", "on" };
static void apply_blur(int c, int at_start)
{
    env("NFSU2_BLUR_OFF", c ? "0" : "1", at_start);
    if (!at_start)
        nv2a_mtl_blur_off = !c;
}

/* Audio */
static const char *const k_pct[] = { "0%", "10%", "20%", "30%", "40%", "50%", "60%", "70%", "80%", "90%", "100%" };
static const char *const k_pct_v[] = { "0", "10", "20", "30", "40", "50", "60", "70", "80", "90", "100" };
static void apply_volume(int c, int at_start)
{
    (void)at_start;
    xa2_set_master_volume((float)c / 10.0f);
}

/* Input */
static const char *const k_vib[] = { "Off", "10%", "20%", "30%", "40%", "50%", "60%", "70%", "80%", "90%", "100%" };
static int get_vib(void) { return nfsu2_option_get(OPT_VIBRATION); }
static void set_vib(int c) { nfsu2_option_set(OPT_VIBRATION, c); }

static const char *const k_kbd[] = { "Without a controller", "Always", "Off" };
static const char *const k_kbd_v[] = { "1", "2", "0" };
static void apply_kbd(int c, int at_start) { env("NFSU2_KEYBOARD", k_kbd_v[c], at_start); }

/* Advanced */
static void apply_fps_counter(int c, int at_start)
{
    (void)at_start;
    nv2a_mtl_fps_overlay = c;
}
static void open_logs(void) { overlay_request(OVERLAY_REQ_OPEN_LOGS); }

#define CHOICES(a) a, (int)(sizeof a / sizeof a[0])

static const OverlayOption k_options[] = {
    { "Display", "Display", "Full screen over the whole panel, or a window. F11 switches it for this run.",
      CHOICES(k_display), 1, 0, "fullscreen", k_01, apply_display },
    { "Display", "Resolution Scale", "How many pixels the game draws: more is sharper and costs the GPU. "
      "Also in the game: Options > Video.", CHOICES(k_scale), 4, 0, NULL, NULL, NULL, get_scale, set_scale },
    { "Display", "Frame Rate", "60 fps in races and the city; 120 fps on a 120 Hz display. The menus and "
      "the camera sequences keep the game's own pace.", CHOICES(k_fps), 0, 1, "fps", k_fps_v, apply_fps },

    { "Graphics", "Anti-Aliasing", "FXAA over the finished picture: smoother edges.",
      CHOICES(k_onoff), 1, 0, NULL, NULL, NULL, get_fxaa, set_fxaa },
    { "Graphics", "Anisotropic Filtering", "Sharper road and walls at an angle.",
      CHOICES(k_aniso), 4, 0, NULL, NULL, NULL, get_aniso, set_aniso },
    { "Graphics", "Square Pixels", "Widescreen drawn with square pixels (more columns) instead of the "
      "Xbox's stretched 640 x 480.", CHOICES(k_onoff), 1, 0, NULL, NULL, NULL, get_square, set_square },
    { "Graphics", "Car Reflections", "The cars' paint and glass reflect the city.",
      CHOICES(k_onoff), 1, 0, NULL, NULL, NULL, get_refl, set_refl },
    { "Graphics", "Draw Distance", "How far scenery keeps its detail. Far costs GPU time late in races.",
      CHOICES(k_draw), 0, 0, "draw", k_draw_v, apply_draw },
    { "Graphics", "Gamma", "The picture's brightness curve: the Xbox's, a brighter one for modern "
      "displays, or a warmer one.", CHOICES(k_gamma), 0, 0, "gamma", k_gamma_v, apply_gamma },
    { "Graphics", "Effects", "Bloom on bright lights; ambient occlusion darkens corners and contacts "
      "(costs GPU time at high scales).", CHOICES(k_fx), 0, 0, "effects", k_fx_v, apply_fx },
    { "Graphics", "Motion Blur", "The game's own blur at speed.",
      CHOICES(k_onoff), 0, 0, "blur", k_blur_v, apply_blur },

    { "Audio", "Master Volume", "The whole game's sound, before the Mac's volume. The game's own "
      "sliders are in Options > Audio.", CHOICES(k_pct), 5, 0, "volume", k_pct_v, apply_volume },

    { "Input", "Vibration", "Controller rumble strength. Also in the game: Options > Gameplay.",
      CHOICES(k_vib), 10, 0, NULL, NULL, NULL, get_vib, set_vib },
    { "Input", "Keyboard as Controller", "Arrows/WASD drive, Enter is A and Start, Esc is B, P is Start.",
      CHOICES(k_kbd), 0, 1, "keyboard", k_kbd_v, apply_kbd },

    { "Advanced", "Performance Overlay", "Frames per second and the slowest frame, top left "
      "(also Cmd+Option+F).", CHOICES(k_onoff), 0, 0, "fps_counter", k_01, apply_fps_counter },
    { "Advanced", "Logs", "The game's and the installer's logs, in Finder (for a bug report).",
      NULL, 0, 0, 0, NULL, NULL, NULL, NULL, NULL, open_logs, "Open" },
};

const OverlayOption *overlay_game_options(int *count)
{
    *count = (int)(sizeof k_options / sizeof k_options[0]);
    return k_options;
}

const char *overlay_game_title(void)
{
    return "NFS Underground 2";
}

const char *const *overlay_game_about(void)
{
    static const char *const lines[] = {
        "NFS Underground 2 for Mac v" NFSU2_PORT_VERSION " (" NFSU2_PORT_COMMIT "), built " __DATE__ ", macOS arm64, Metal",
        "Free software under the GPL-3.0-or-later, with no warranty. Built on nfsu2-sw (antoxa2584x),",
        "nfsu2-ios (myUdav4iik), xboxrecomp (sp00nz), NFSU2Deadware (LeoDeadware): see NOTICE.",
        "Not affiliated with Electronic Arts or Microsoft. Your own disc, built on your Mac.",
        NULL,
    };
    return lines;
}
