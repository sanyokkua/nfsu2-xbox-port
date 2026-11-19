/**
 * Button prompts for the connected pad (Deadware, NFSU2 on the Mac).
 *
 * The game's prompt glyphs are 32x32 textures, one per button (white-green
 * outline, tinted by the game): A, B, X, Y in a ring, L and R in a rounded
 * square. Hashes from NFSU2_TEX_DUMP (apple_textures.m) of the menus and a
 * race. With a PlayStation pad (SDL type PS3/PS4/PS5) they are redrawn,
 * procedurally (CoreGraphics; nothing derived from game data is stored), at
 * 4x: A -> cross, B -> circle, X -> square, Y -> triangle, L -> L2, R -> R2.
 * With any other pad A/B/X/Y stay the game's own (same letters as an Xbox
 * pad) and L/R become LT/RT. The new glyph keeps the original's ring (its
 * alpha's box and stroke width) and colour.
 *
 *   NFSU2_PROMPTS=auto   (default) by the first connected pad
 *                =ps     PlayStation glyphs   =xbox  LT/RT only
 *                =0      the original glyphs
 *   NFSU2_PROMPTS_DUMP=<dir>  write every replacement as <hash>.png
 */
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

#include <SDL.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "apple_textures.h"

enum { G_A, G_B, G_X, G_Y, G_L, G_R };
static const struct { uint64_t hash; int kind; } s_glyphs[] = {
    { 0x54df260d4ffaf22cull, G_A },
    { 0x1137202d59bc1d0cull, G_B },
    { 0xaf275789392c7faaull, G_X },
    { 0x0b82d7831da83536ull, G_Y },
    { 0x03c0f7aadce27211ull, G_L },
    { 0xf3cbccb25d489f28ull, G_R },
};

enum { F_OFF, F_XBOX, F_PS };
static int s_mode = -1;                 /* -1 auto, else F_* */
static volatile int s_family = F_XBOX;
static int s_watch;
static const char *s_dump;

static int pad_family(void)
{
    int i, n = SDL_NumJoysticks();
    for (i = 0; i < n; i++) {
        if (!SDL_IsGameController(i))
            continue;
        switch (SDL_GameControllerTypeForIndex(i)) {
        case SDL_CONTROLLER_TYPE_PS3:
        case SDL_CONTROLLER_TYPE_PS4:
        case SDL_CONTROLLER_TYPE_PS5:
            return F_PS;
        default:
            return F_XBOX;
        }
    }
    return F_XBOX;
}

static void set_family(int f)
{
    if (f != s_family) {
        s_family = f;
        nv2a_tex_replace_gen++;
        fprintf(stderr, "[prompts] %s button glyphs\n", f == F_PS ? "PlayStation" :
                f == F_XBOX ? "Xbox" : "original");
    }
}

static int SDLCALL on_event(void *u, SDL_Event *e)
{
    (void)u;
    if (e->type == SDL_CONTROLLERDEVICEADDED || e->type == SDL_CONTROLLERDEVICEREMOVED)
        set_family(pad_family());
    return 0;
}

void nfsu2_prompts_poll(void)
{
    if (s_mode < 0 && !s_watch) {
        s_watch = 1;
        SDL_AddEventWatch(on_event, NULL);
        set_family(pad_family());
    }
}

/* The original's ring: alpha box, stroke width, colour. */
typedef struct { double x0, y0, x1, y1, stroke; double r, g, b; } Ring;

static void measure(const uint32_t *px, uint32_t w, uint32_t h, Ring *o)
{
    uint32_t x, y, n = 0, x0 = w, x1 = 0, y0 = h, y1 = 0, run = 0, best = 0;
    double r = 0, g = 0, b = 0;
    for (y = 0; y < h; y++)
        for (x = 0; x < w; x++) {
            uint32_t c = px[y * w + x], a = c >> 24;
            if (a < 96) continue;
            if (x < x0) x0 = x;
            if (x > x1) x1 = x;
            if (y < y0) y0 = y;
            if (y > y1) y1 = y;
            if (a > 200) {
                r += (c >> 16) & 255; g += (c >> 8) & 255; b += c & 255; n++;
            }
        }
    if (x1 < x0) { x0 = y0 = 0; x1 = w - 1; y1 = h - 1; }
    /* Stroke: opaque run from the box's left edge along the middle row. */
    y = (y0 + y1) / 2;
    for (x = x0; x <= x1 && (px[y * w + x] >> 24) >= 96; x++)
        run++;
    best = run ? run : 2;
    o->x0 = x0; o->x1 = x1 + 1; o->y0 = y0; o->y1 = y1 + 1;
    o->stroke = best;
    o->r = n ? r / n / 255.0 : 0.85; o->g = n ? g / n / 255.0 : 1.0; o->b = n ? b / n / 255.0 : 0.85;
}

static void text_in(CGContextRef c, const char *s, double cx, double cy, double height)
{
    CTFontRef f = CTFontCreateWithName(CFSTR("Helvetica-Bold"), height, NULL);
    CGColorRef col = CGColorCreateGenericRGB(1, 1, 1, 1);
    CFStringRef str = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
    const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
    const void *vals[] = { f, col };
    CFDictionaryRef at = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks,
                                            &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, at);
    CTLineRef line = CTLineCreateWithAttributedString(as);
    CGRect bb = CTLineGetImageBounds(line, c);
    CGContextSetTextPosition(c, cx - bb.size.width / 2 - bb.origin.x,
                             cy - bb.size.height / 2 - bb.origin.y);
    CTLineDraw(line, c);
    CFRelease(line); CFRelease(as); CFRelease(at); CFRelease(str); CFRelease(col); CFRelease(f);
}

#define K 4
static uint32_t s_out[32 * K * 32 * K];

static const uint32_t *draw(const Nv2aTexInfo *ti, int kind, int family)
{
    uint32_t W = ti->w * K, H = ti->h * K, i;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(s_out, W, H, 8, W * 4, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    Ring g;
    double x0, y0, x1, y1, t, cx, cy, rr;

    CGColorSpaceRelease(cs);
    if (!c)
        return NULL;
    measure(ti->argb, ti->w, ti->h, &g);
    /* CoreGraphics is y-up; texture row 0 is the top. */
    x0 = g.x0 * K; x1 = g.x1 * K; y0 = H - g.y1 * K; y1 = H - g.y0 * K;
    t = g.stroke * K;
    cx = (x0 + x1) / 2; cy = (y0 + y1) / 2;
    rr = ((x1 - x0) < (y1 - y0) ? (x1 - x0) : (y1 - y0)) / 2;
    CGContextClearRect(c, CGRectMake(0, 0, W, H));
    CGContextSetRGBStrokeColor(c, 1, 1, 1, 1);
    CGContextSetRGBFillColor(c, 1, 1, 1, 1);
    CGContextSetLineWidth(c, t);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    if (kind <= G_Y) {
        double s = rr * 0.42;
        CGContextStrokeEllipseInRect(c, CGRectMake(cx - rr + t / 2, cy - rr + t / 2,
                                                   2 * rr - t, 2 * rr - t));
        CGContextSetLineWidth(c, t * 0.9);
        if (kind == G_A) {                              /* cross */
            CGContextMoveToPoint(c, cx - s, cy - s); CGContextAddLineToPoint(c, cx + s, cy + s);
            CGContextMoveToPoint(c, cx - s, cy + s); CGContextAddLineToPoint(c, cx + s, cy - s);
            CGContextStrokePath(c);
        } else if (kind == G_B) {                       /* circle */
            CGContextStrokeEllipseInRect(c, CGRectMake(cx - s * 1.05, cy - s * 1.05, s * 2.1, s * 2.1));
        } else if (kind == G_X) {                       /* square */
            CGContextStrokeRect(c, CGRectMake(cx - s * 0.9, cy - s * 0.9, s * 1.8, s * 1.8));
        } else {                                        /* triangle */
            double R = s * 1.15, oy = -s * 0.15;
            CGContextMoveToPoint(c, cx, cy + oy + R);
            CGContextAddLineToPoint(c, cx - R * 0.866, cy + oy - R * 0.5);
            CGContextAddLineToPoint(c, cx + R * 0.866, cy + oy - R * 0.5);
            CGContextClosePath(c);
            CGContextStrokePath(c);
        }
    } else {
        CGPathRef p = CGPathCreateWithRoundedRect(
            CGRectMake(x0 + t / 2, y0 + t / 2, x1 - x0 - t, y1 - y0 - t),
            (x1 - x0) * 0.18, (y1 - y0) * 0.18, NULL);
        const char *lab = family == F_PS ? (kind == G_L ? "L2" : "R2")
                                         : (kind == G_L ? "LT" : "RT");
        CGContextAddPath(c, p);
        CGContextStrokePath(c);
        CGPathRelease(p);
        text_in(c, lab, cx, cy, (y1 - y0) * 0.5);
    }
    CGContextRelease(c);
    /* White drawing -> the original's colour, straight alpha. */
    for (i = 0; i < W * H; i++) {
        uint32_t a = s_out[i] >> 24;
        s_out[i] = a << 24 | (uint32_t)lround(g.r * 255) << 16 |
                   (uint32_t)lround(g.g * 255) << 8 | (uint32_t)lround(g.b * 255);
    }
    if (s_dump) {
        char path[1024];
        snprintf(path, sizeof path, "%s/%016llx_%s.png", s_dump, (unsigned long long)ti->hash,
                 family == F_PS ? "ps" : "xbox");
        nfsu2_tex_write_png(path, s_out, W, H);
    }
    return s_out;
}

static const uint32_t *provide(const Nv2aTexInfo *ti, uint32_t *k)
{
    size_t i;
    int family;
    if (ti->w != 32 || ti->h != 32)
        return NULL;
    nfsu2_prompts_poll();
    family = s_mode >= 0 ? s_mode : s_family;
    if (family == F_OFF)
        return NULL;
    for (i = 0; i < sizeof s_glyphs / sizeof s_glyphs[0]; i++)
        if (s_glyphs[i].hash == ti->hash) {
            if (family == F_XBOX && s_glyphs[i].kind <= G_Y)
                return NULL;                            /* the game's own letters */
            *k = K;
            return draw(ti, s_glyphs[i].kind, family);
        }
    return NULL;
}

void nfsu2_prompts_init(void)
{
    const char *e = getenv("NFSU2_PROMPTS");
    if (e && *e) {
        if (!strcmp(e, "ps")) s_mode = F_PS;
        else if (!strcmp(e, "xbox")) s_mode = F_XBOX;
        else if (!strcmp(e, "0") || !strcmp(e, "off")) s_mode = F_OFF;
    }
    s_dump = getenv("NFSU2_PROMPTS_DUMP");
    if (s_dump && !*s_dump) s_dump = NULL;
    nfsu2_tex_add_provider(provide);
}
