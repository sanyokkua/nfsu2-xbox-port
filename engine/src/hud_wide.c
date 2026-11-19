/**
 * HUD at the visible edges of a 16:10 Mac screen (Deadware).
 *
 * On a screen narrower than 16:9 the presenter (nv2a_metal.m, crop mode)
 * fills the height and cuts the picture's sides: only clip x in +-vis stays
 * visible (vis = screen aspect / (16/9), 0.866 on a 3024x1964 MacBook Pro).
 * NFSU2's race HUD sits out to x = +-0.85 of the 16:9 frame (mini-map
 * bottom left, speedometer bottom right, position/laps top right), so it
 * would be cut. Every HUD element in an outer column is moved inward by
 * (1 - vis), the left ones right and the right ones left: the HUD keeps its distance to the visible
 * edge (the corners), its size and its layout.
 *
 * NFSU2_HUD_TRACE=<s>: logs the draws of the race back buffer for a moment
 * after <s> seconds. NFSU2_HUD_WIDE=0 off (HUD and loading pictures). NFSU2_LOAD_TRACE=1 logs one line
 * per frame shape; NFSU2_LOAD_DUMP=<flip> (0 = 40 frames into the first loading screen) logs its draws.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>

#include "../xboxrecomp/src/kernel/nv2a_backend.h"

/* The visible half-width in 16:9 clip units, set by the presenter (1 = all). */
volatile float nfsu2_hud_visible = 1.0f;

static void attr_get(const Nv2aRawBatch *rb, const float *attrs, uint32_t a,
                     uint32_t i, float o[4])
{
    if (rb->attr_direct & (1u << a)) {
        const uint8_t *p = rb->direct[a].ptr + (size_t)i * rb->direct[a].stride;
        uint32_t k;
        o[0] = o[1] = o[2] = 0.0f;
        o[3] = 1.0f;
        if (rb->direct[a].type == 2)
            for (k = 0; k < rb->direct[a].size; k++)
                memcpy(&o[k], p + 4 * k, 4);
        return;
    }
    memmove(o, attrs + ((size_t)i * NV2A_RAW_ATTRS + a) * 4, 16);
}

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void trace_batch(const Nv2aRawBatch *rb, const float *attrs)
{
    static double t0, at = -1;
    static int n;
    float mn[4] = { 1e30f, 1e30f, 1e30f, 1e30f }, mx[4] = { -1e30f, -1e30f, -1e30f, -1e30f };
    uint32_t i, k;
    const uint32_t *r = rb->regs;

    if (at < 0) {
        const char *e = getenv("NFSU2_HUD_TRACE");
        at = e ? atof(e) : 0;
        t0 = now_s();
    }
    if (!at || now_s() - t0 < at || n >= 3000)
        return;
    n++;
    for (i = 0; i < rb->vertex_count; i++) {
        float v[4];
        attr_get(rb, attrs, 0, i, v);
        for (k = 0; k < 4; k++) {
            if (v[k] < mn[k]) mn[k] = v[k];
            if (v[k] > mx[k]) mx[k] = v[k];
        }
    }
    fprintf(stderr, "[hud] %04d surf %08X %ux%u aa %ux%u xf %u prim %u nv %u ni %u tex %08X "
            "x %.1f..%.1f y %.1f..%.1f z %.3g..%.3g w %.3g..%.3g ztest %u zw %u blend %u vp %u/%u\n",
            n, rb->color_va, rb->surface.width, rb->surface.height, rb->surface.aa_sx, rb->surface.aa_sy,
            rb->xform, rb->prim, rb->vertex_count, rb->index_count, rb->tex_va[0],
            mn[0], mx[0], mn[1], mx[1], mn[2], mx[2], mn[3], mx[3],
            r[0x30C / 4], r[0x35C / 4], r[0x304 / 4], rb->vp_start, rb->vp_prog_gen);
}

/* NFSU2_LOAD_TRACE=1: one line per frame that changes shape (or every 120th): batches, 3D batches
 * (xform != 2), 2D quads (xform 2, prim 7) and the largest 2D quad's box, texture and z. */
static void frame_trace(const Nv2aRawBatch *rb, const float *attrs)
{
    static int on = -1;
    static uint32_t fl, nb, n3d, n2d, big_tex, big_sw, big_nv, sig0;
    static float big_a, big_box[4], big_z;
    static unsigned long frames;
    float box[4];
    uint32_t flips = 0, i;
    if (on < 0) {
        const char *e = getenv("NFSU2_LOAD_TRACE");
        on = e && *e == '1';
    }
    if (!on)
        return;
    if (!nv2a_pb_batch_screen_box(box, &flips))
        box[0] = box[1] = box[2] = box[3] = 0.0f;
    if (flips != fl) {
        uint32_t sig = (n3d ? 1u : 0u) | (n2d << 1) | (big_tex << 12);
        if (sig != sig0 || !(frames % 120))
            fprintf(stderr, "[load] flip %u: %u batches, 3d %u, 2d quads %u, big %.0f..%.0f x %.0f..%.0f "
                    "tex %08X nv %u surf %u z %.3g\n", fl, nb, n3d, n2d, big_box[0], big_box[1], big_box[2],
                    big_box[3], big_tex, big_nv, big_sw, big_z);
        sig0 = sig; frames++;
        fl = flips; nb = n3d = n2d = 0; big_a = 0.0f; big_tex = 0;
    }
    nb++;
    {
        static long dump_at = -2;
        if (dump_at == -2) {
            const char *e = getenv("NFSU2_LOAD_DUMP");
            dump_at = e ? atol(e) : -1;
        }
        if (dump_at == 0 && rb->surface.width == 640 && box[1] - box[0] > 700.0f)
            dump_at = flips + 40;   /* NFSU2_LOAD_DUMP=0: 40 frames into the first loading screen */
        if (dump_at >= 0 && (flips == (uint32_t)dump_at || flips == (uint32_t)dump_at + 50)) {
            float v[4] = { 0, 0, 0, 0 }, u[4] = { 0, 0, 0, 0 };
            if (rb->vertex_count && (rb->attr_present & 1u))
                attr_get(rb, attrs, 0, 0, v);
            if (rb->vertex_count > 2 && (rb->attr_present & 1u))
                attr_get(rb, attrs, 0, 2, u);
            fprintf(stderr, "[load]   %u #%u xf %u prim %u nv %u tex %08X surf %ux%u box %.1f..%.1f x %.1f..%.1f "
                    "v0 %.2f %.2f %.3g v2 %.2f %.2f direct %04X\n", flips, nb, rb->xform, rb->prim,
                    rb->vertex_count, rb->tex_va[0], rb->surface.width, rb->surface.height,
                    box[0], box[1], box[2], box[3], v[0], v[1], v[2], u[0], u[1], rb->attr_direct);
        }
    }
    if (rb->xform != 2) { n3d++; return; }
    if (rb->prim != 7)
        return;
    n2d++;
    if ((box[1] - box[0]) * (box[3] - box[2]) > big_a) {
        float v[4] = { 0, 0, 0, 0 };
        if (rb->vertex_count && (rb->attr_present & 1u))
            attr_get(rb, attrs, 0, 0, v);
        big_a = (box[1] - box[0]) * (box[3] - box[2]);
        for (i = 0; i < 4; i++) big_box[i] = box[i];
        big_tex = rb->tex_va[0]; big_nv = rb->vertex_count; big_sw = rb->surface.width; big_z = v[2];
    }
}

static int wide_on(void)
{
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("NFSU2_HUD_WIDE");
        on = !(e && *e == '0');
    }
    return on;
}

/* A HUD quad: race back buffer (640 wide, no AA), vertex program, quads,
 * depth test off, every vertex at z = 1 (the HUD's flat layer). */
static int hud_quad(const Nv2aRawBatch *rb, const float *attrs, float *rx0, float *rx1)
{
    uint32_t i;
    if (rb->xform != 2 || rb->prim != 7 || rb->vertex_count < 4 || !(rb->attr_present & 1u))
        return 0;
    if (!((rb->surface.width == 640 && rb->surface.aa_sx <= 1) ||
          (rb->surface.width == 1280 && rb->surface.aa_sx == 2)) || rb->regs[0x30C / 4])
        return 0;
    *rx0 = 1e30f; *rx1 = -1e30f;
    for (i = 0; i < rb->vertex_count; i++) {
        float v[4];
        attr_get(rb, attrs, 0, i, v);
        if (v[2] != 1.0f)
            return 0;
        if (v[0] < *rx0) *rx0 = v[0];
        if (v[0] > *rx1) *rx1 = v[0];
    }
    return 1;
}

/* Elements (PIT-R08): sprites that touch, from the previous frame. An
 * element wholly left or right of the middle moves; one that reaches the
 * middle (pause box, its text rows, messages) stays whole. A sprite with
 * no element in the previous frame stays for that one frame. */
#define HUD_MAX 1024
typedef struct { float x0, x1, y0, y1; int side; } HudBox;
static HudBox s_cur[HUD_MAX], s_el[HUD_MAX];
static int s_ncur, s_nel;
static uint32_t s_flips;

static int touch(const HudBox *a, const HudBox *b)
{
    const float t = 2.0f;
    return a->x0 <= b->x1 + t && b->x0 <= a->x1 + t &&
           a->y0 <= b->y1 + t && b->y0 <= a->y1 + t;
}

static void end_frame(float half)
{
    int i, j, grew;
    /* Merge touching boxes into element bounds until nothing changes. */
    s_nel = 0;
    for (i = 0; i < s_ncur; i++)
        s_el[s_nel++] = s_cur[i];
    do {
        grew = 0;
        for (i = 0; i < s_nel; i++)
            for (j = i + 1; j < s_nel; j++)
                if (touch(&s_el[i], &s_el[j])) {
                    HudBox *a = &s_el[i], *b = &s_el[j];
                    if (b->x0 < a->x0) a->x0 = b->x0;
                    if (b->x1 > a->x1) a->x1 = b->x1;
                    if (b->y0 < a->y0) a->y0 = b->y0;
                    if (b->y1 > a->y1) a->y1 = b->y1;
                    s_el[j--] = s_el[--s_nel];
                    grew = 1;
                }
    } while (grew);
    for (i = 0; i < s_nel; i++) {
        float c0 = s_el[i].x0 / half - 1.0f, c1 = s_el[i].x1 / half - 1.0f;
        s_el[i].side = c1 < -0.3f ? -1 : c0 > 0.3f ? 1 : 0;
    }
    s_ncur = 0;
}

static int element_side(const HudBox *b)
{
    float cx = 0.5f * (b->x0 + b->x1), cy = 0.5f * (b->y0 + b->y1);
    int i;
    for (i = 0; i < s_nel; i++)
        if (cx >= s_el[i].x0 - 1.0f && cx <= s_el[i].x1 + 1.0f &&
            cy >= s_el[i].y0 - 1.0f && cy <= s_el[i].y1 + 1.0f)
            return s_el[i].side;
    return 0;
}

/* Loading screens (v1.0.1): the game draws each loading picture as one full-height quad in the
 * movies' 4:3 box at 90% (clip +-1.05, 0.707 of the frame's width), pillarboxed; the presenter's
 * 16:10 crop keeps bars at its sides. That quad is scaled about the centre by vis / its width, so it
 * fills the visible width (cuts ~9% top and bottom); the text, panels and bar drawn over it keep
 * their places in the 4:3 box. Movies (0.675 of the width, movie_crop.c) are not matched.
 * NFSU2_LOAD_WIDE=0 off. */
static int load_zoom(Nv2aRawBatch *rb, float *attrs, float vis)
{
    static int on = -1;
    static unsigned long zoomed;
    float box[4], w, h, f, s, sum = 0.0f;
    uint32_t i, flips;
    if (on < 0) {
        const char *e = getenv("NFSU2_LOAD_WIDE");
        on = !(e && *e == '0');
    }
    if (!on || rb->xform != 2 || rb->prim != 7 || rb->vertex_count != 4 || !(rb->attr_present & 1u))
        return 0;
    for (i = 0; i < 4; i++) {
        float v[4];
        attr_get(rb, attrs, 0, i, v);
        if (v[2] != 1.0f || v[0] * v[0] < 0.25f)
            return 0;
        sum += v[0];
    }
    if (sum * sum > 1e-4f || !nv2a_pb_batch_screen_box(box, &flips))
        return 0;
    w = (float)rb->surface.width * (rb->surface.aa_sx > 1 ? rb->surface.aa_sx : 1);
    h = (float)rb->surface.height * (rb->surface.aa_sy > 1 ? rb->surface.aa_sy : 1);
    if (w <= 0.0f || h <= 0.0f)
        return 0;
    f = (box[1] - box[0]) / w;
    if (f < 0.69f || f > 0.73f || box[2] > 0.02f * h || box[3] < 0.98f * h ||
        fabsf(0.5f * (box[0] + box[1]) - 0.5f * w) > 0.01f * w)
        return 0;
    s = vis / f;
    for (i = 0; i < 4; i++) {
        float *p = attrs + (size_t)i * NV2A_RAW_ATTRS * 4;
        attr_get(rb, attrs, 0, i, p);
        p[0] *= s;
        p[1] *= s;
    }
    rb->attr_direct &= (uint16_t)~1u;
    if (!zoomed++)
        fprintf(stderr, "[hud] loading picture %08X: %.3f of the width -> zoom %.3f (visible +-%.3f)\n",
                rb->tex_va[0], f, s, vis);
    return 1;
}

void nfsu2_hud_batch(Nv2aRawBatch *rb, float *attrs)
{
    static float slope = 0.0f;              /* screen px per attribute unit */
    static unsigned long moved;
    float vis = nfsu2_hud_visible, rx0, rx1, box[4], half, dx;
    uint32_t i, flips;
    HudBox b;
    int side;

    trace_batch(rb, attrs);
    frame_trace(rb, attrs);
    if (vis > 0.999f || vis < 0.5f || !wide_on() || load_zoom(rb, attrs, vis) || !hud_quad(rb, attrs, &rx0, &rx1))
        return;
    if (!nv2a_pb_batch_screen_box(box, &flips))
        return;
    half = rb->surface.width == 1280 ? 640.0f   /* the front end: boxes in real pixels */
                                     : 0.5f * (float)rb->surface.width * (rb->aa_sx > 0 ? rb->aa_sx : 1.0f);
    if (flips != s_flips) {
        if (flips == s_flips + 1)
            end_frame(half);
        else
            s_ncur = s_nel = 0;
        s_flips = flips;
    }
    b.x0 = box[0]; b.x1 = box[1]; b.y0 = box[2]; b.y1 = box[3]; b.side = 0;
    if (s_ncur < HUD_MAX)
        s_cur[s_ncur++] = b;
    if (rx1 - rx0 > 1e-4f && box[1] - box[0] > 0.5f)
        slope = (box[1] - box[0]) / (rx1 - rx0);
    side = element_side(&b);
    if (!side || slope <= 0.0f)
        return;
    dx = -(float)side * (1.0f - vis) * half / slope;
    for (i = 0; i < rb->vertex_count; i++) {
        float *p = attrs + (size_t)i * NV2A_RAW_ATTRS * 4;
        attr_get(rb, attrs, 0, i, p);
        p[0] += dx;
    }
    rb->attr_direct &= (uint16_t)~1u;
    if (!moved++)
        fprintf(stderr, "[hud] wide HUD: visible +-%.3f, corner elements moved %.1f px\n",
                vis, (1.0f - vis) * half);
}
