/*
 * nv2a_metal_post.inc -- the Mac's picture options (Deadware standard, item 5),
 * included by nv2a_metal.m (it uses that file's statics).
 *
 *   NFSU2_GAMMA=original|modern|warm   at present, the whole picture HUD included
 *       (the same curves as the ROTK launcher): original = the game's picture;
 *       modern = c^(2.2/2.5), the CRT-made picture opened up for an LCD;
 *       warm = c^(2.5/2.2) with a warm white point.
 *   NFSU2_AO=1|0        screen-space ambient occlusion on the 3D scene (default 0: over the
 *                       60 fps budget at 2.0x on an M1 Pro, owner 2026-11-07)
 *   NFSU2_BLOOM=0..1    glow of bright, emissive pixels: neon, lamps, headlights
 *                       (default 0.35; 0 off)
 *   NFSU2_POST_DEBUG=1  shows the occlusion term alone (tests)
 *
 * The scene effects must not touch the HUD. The game draws the 3D scene with
 * the depth test on; the HUD, the game's own full-screen treatments and the
 * text come after it with the depth test off. So the scene surface is the one
 * that took the most depth-tested draws this frame (at least 150, at least
 * 90 % of the presented width: reflection maps are smaller), and the effects
 * run on it, in place, at the first draw without the depth test after that
 * -- once per frame. Front-end menus have no such scene and stay untouched.
 *
 * AO: depth only (the NV2A depth is Depth32Float here), linearised with the
 * camera's near/far (NFSU2_AO_NEAR/FAR, default 0.5 / 10000), compared with
 * the plane fitted through the pixel's neighbours so flat road and walls at
 * a grazing angle do not darken themselves; 12 samples at half resolution,
 * rotated by a fixed 4x4 interleaved pattern (the same every frame: white
 * noise crawled over the textures as the camera moved), then a depth-aware
 * 4x4 blur that spans exactly that pattern, so no grain is left. AO fades
 * out with distance (NFSU2_AO_FADE metres, default 60) and leaves bright,
 * emissive pixels alone (lights, neon, sky glow), so it darkens creases and
 * contact shadows, not the textures' own colours.
 * Stability: the scene test has hysteresis (enter at 150 depth-tested draws,
 * stay at 60, leave after 30 frames without a scene) and the effects fade
 * in over 20 frames, so 3D menus and camera sequences no longer switch AO
 * on and off between frames.
 */

static int   s_post_init_done;
/* The overlay changed NFSU2_GAMMA / NFSU2_AO / NFSU2_BLOOM: read them again
 * at the next flip (post_frame calls post_settings, on this thread). */
void nv2a_mtl_post_reload(void) { s_post_init_done = 0; }
static int   s_gamma_on, s_ao_on, s_post_debug;
static float s_bloom_k;
/* s_gamma_v (exponent, tint rgb), s_present_pipe: declared in nv2a_metal.m */
static float s_ao_near = 0.5f, s_ao_far = 10000.0f, s_ao_fade_m = 60.0f;

static id<MTLRenderPipelineState> s_ao_pipe, s_aoblur_pipe, s_bright_pipe, s_blur_pipe, s_comp_pipe;
static id<MTLTexture> s_post_src, s_post_ao, s_post_ao2, s_post_b0, s_post_b1;

static MtSurf  *s_scene;
static MtDepth *s_scene_d;
static uint32_t s_scene_draws, s_post_pw, s_post_runs, s_post_frames;
static int      s_post_done;
static int      s_post_active, s_post_idle;    /* hysteresis: in a 3D scene; frames without one */
static float    s_post_fade;                   /* 0..1, effects fade in */

static const char *post_msl(void)
{
    return
        "#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "struct QOut { float4 pos [[position]]; float2 uv; };\n"
        "vertex QOut post_vs(uint vid [[vertex_id]], constant float4& r [[buffer(0)]]) {\n"
        "    QOut o; float2 p = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);\n"
        "    o.pos = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);\n"
        "    o.uv = mix(r.xy, r.zw, p); return o;\n"
        "}\n"
        /* present: the copy with the launcher's gamma */
        "fragment float4 present_fs(QOut in [[stage_in]], texture2d<float> t [[texture(0)]],\n"
        "                           sampler s [[sampler(0)]], constant float4& g [[buffer(0)]]) {\n"
        "    float4 c = t.sample(s, in.uv);\n"
        "    c.rgb = pow(max(c.rgb, 0.0), float3(g.x)) * g.yzw;\n"
        "    return c;\n"
        "}\n"
        /* present with FXAA 3.11 (quality preset, 8 search steps, nv2a_vk.c's
         * s_pp_fs) in the source's texels, then the gamma curve */
        "static float L(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }\n"
        "fragment float4 fxaa_fs(QOut in [[stage_in]], texture2d<float> t [[texture(0)]],\n"
        "                        sampler s [[sampler(0)]], constant float4& g [[buffer(0)]]) {\n"
        "    const float Q[8] = { 1.0, 1.0, 1.0, 1.5, 2.0, 2.0, 4.0, 8.0 };\n"
        "    float2 uv = in.uv, r = 1.0 / float2(t.get_width(), t.get_height());\n"
        "#define LO(x, y) L(t.sample(s, uv, level(0.0), int2(x, y)).rgb)\n"
        "#define LAT(p) L(t.sample(s, p, level(0.0)).rgb)\n"
        "    float4 cM = t.sample(s, uv, level(0.0));\n"
        "    float lM = L(cM.rgb), lD = LO(0, 1), lU = LO(0, -1), lL = LO(-1, 0), lR = LO(1, 0);\n"
        "    float mx = max(lM, max(max(lD, lU), max(lL, lR)));\n"
        "    float mn = min(lM, min(min(lD, lU), min(lL, lR)));\n"
        "    float range = mx - mn;\n"
        "    float3 o;\n"
        "    if (range < max(0.0312, mx * 0.125)) {\n"
        "        o = cM.rgb;\n"
        "    } else {\n"
        "        float lDL = LO(-1, 1), lUR = LO(1, -1), lUL = LO(-1, -1), lDR = LO(1, 1);\n"
        "        float lDU = lD + lU, lLR = lL + lR;\n"
        "        float lLc = lDL + lUL, lDc = lDL + lDR, lRc = lDR + lUR, lUc = lUR + lUL;\n"
        "        float eH = abs(-2.0 * lL + lLc) + abs(-2.0 * lM + lDU) * 2.0 + abs(-2.0 * lR + lRc);\n"
        "        float eV = abs(-2.0 * lU + lUc) + abs(-2.0 * lM + lLR) * 2.0 + abs(-2.0 * lD + lDc);\n"
        "        bool hor = eH >= eV;\n"
        "        float l1 = hor ? lU : lL, l2 = hor ? lD : lR;\n"
        "        float g1 = l1 - lM, g2 = l2 - lM;\n"
        "        bool steep1 = abs(g1) >= abs(g2);\n"
        "        float gs = 0.25 * max(abs(g1), abs(g2));\n"
        "        float st = hor ? r.y : r.x, avg;\n"
        "        if (steep1) { st = -st; avg = 0.5 * (l1 + lM); } else avg = 0.5 * (l2 + lM);\n"
        "        float2 cur = uv;\n"
        "        if (hor) cur.y += st * 0.5; else cur.x += st * 0.5;\n"
        "        float2 off = hor ? float2(r.x, 0.0) : float2(0.0, r.y);\n"
        "        float2 uv1 = cur - off, uv2 = cur + off;\n"
        "        float e1 = LAT(uv1) - avg, e2 = LAT(uv2) - avg;\n"
        "        bool r1 = abs(e1) >= gs, r2 = abs(e2) >= gs;\n"
        "        if (!r1) uv1 -= off;\n"
        "        if (!r2) uv2 += off;\n"
        "        for (int i = 2; i < 8 && !(r1 && r2); i++) {\n"
        "            if (!r1) e1 = LAT(uv1) - avg;\n"
        "            if (!r2) e2 = LAT(uv2) - avg;\n"
        "            r1 = abs(e1) >= gs; r2 = abs(e2) >= gs;\n"
        "            if (!r1) uv1 -= off * Q[i];\n"
        "            if (!r2) uv2 += off * Q[i];\n"
        "        }\n"
        "        float d1 = hor ? uv.x - uv1.x : uv.y - uv1.y;\n"
        "        float d2 = hor ? uv2.x - uv.x : uv2.y - uv.y;\n"
        "        bool dir1 = d1 < d2;\n"
        "        float px = -min(d1, d2) / (d1 + d2) + 0.5;\n"
        "        bool ok = ((dir1 ? e1 : e2) < 0.0) != (lM < avg);\n"
        "        float fin = ok ? px : 0.0;\n"
        "        float la = (1.0 / 12.0) * (2.0 * (lDU + lLR) + lLc + lRc);\n"
        "        float s1 = clamp(abs(la - lM) / range, 0.0, 1.0);\n"
        "        float s2 = (-2.0 * s1 + 3.0) * s1 * s1;\n"
        "        fin = max(fin, s2 * s2 * 0.75);\n"
        "        float2 u2 = uv;\n"
        "        if (hor) u2.y += fin * st; else u2.x += fin * st;\n"
        "        o = t.sample(s, u2, level(0.0)).rgb;\n"
        "    }\n"
        "#undef LO\n"
        "#undef LAT\n"
        "    return float4(pow(max(o, 0.0), float3(g.x)) * g.yzw, 1.0);\n"
        "}\n"
        "struct PostP { float near_, far_, w, h, strength, radius, debug, bloom, fade_m, k; };\n"
        "static float lin(float z, constant PostP& p) {\n"
        "    return p.near_ / max(1.0 - z * (1.0 - p.near_ / p.far_), 1e-6);\n"
        "}\n"
        "static float ld(depth2d<float> d, int2 q, constant PostP& p) {\n"
        "    q = clamp(q, int2(0), int2(int(p.w) - 1, int(p.h) - 1));\n"
        "    return lin(d.read(uint2(q)), p);\n"
        "}\n"
        /* AO at half resolution: out = visibility (1 = open) */
        "fragment float ao_fs(QOut in [[stage_in]], depth2d<float> d [[texture(0)]],\n"
        "                     constant PostP& p [[buffer(0)]]) {\n"
        "    int2 c = int2(in.uv * float2(p.w, p.h));\n"
        "    float zr = d.read(uint2(clamp(c, int2(0), int2(int(p.w) - 1, int(p.h) - 1))));\n"
        "    if (zr >= 0.99999) return 1.0;\n"                       /* sky, nothing drawn */
        "    float z = lin(zr, p);\n"
        "    float zl = ld(d, c - int2(1, 0), p), zrr = ld(d, c + int2(1, 0), p);\n"
        "    float zu = ld(d, c - int2(0, 1), p), zd = ld(d, c + int2(0, 1), p);\n"
        "    float gx = abs(z - zl) < abs(zrr - z) ? z - zl : zrr - z;\n"
        "    float gy = abs(z - zu) < abs(zd - z) ? z - zu : zd - z;\n"
        "    float rpx = clamp(p.radius * p.h / z, 3.0, p.h * 0.06);\n"
        "    if (z > p.fade_m) return 1.0;\n"                       /* far: no AO (precision, shimmer) */
        "    uint2 b = uint2(in.pos.xy) & 3u;\n"                    /* 4x4 interleaved, fixed in time */
        "    const float bay[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };\n"
        "    float a0 = (bay[b.y * 4 + b.x] + 0.5) / 16.0 * 6.2832;\n"
        "    float occ = 0.0;\n"
        "    for (int i = 0; i < 12; i++) {\n"
        "        float t = (float(i) + 0.5) / 12.0;\n"
        "        float a = a0 + float(i) * 2.39996;\n"
        "        float2 o = float2(cos(a), sin(a)) * rpx * sqrt(t);\n"
        "        int2 q = c + int2(o);\n"
        "        float zs = ld(d, q, p);\n"
        "        float plane = z + o.x * gx + o.y * gy;\n"
        "        float diff = plane - zs;\n"                          /* > 0: in front of the plane */
        "        float range = p.radius * 2.0;\n"
        "        float eps = z * 0.004 + 0.02;\n"
        "        occ += step(eps, diff) * saturate(1.0 - (diff - eps) / range);\n"
        "    }\n"
        "    float fade = 1.0 - smoothstep(p.fade_m * 0.5, p.fade_m, z);\n"
        "    return saturate(1.0 - p.strength * fade * occ / 12.0);\n"
        "}\n"
        /* depth-aware 4x4 blur over the pattern's period, at half resolution */
        "fragment float aoblur_fs(QOut in [[stage_in]], texture2d<float> ao [[texture(0)]],\n"
        "                         depth2d<float> d [[texture(1)]], constant PostP& p [[buffer(0)]]) {\n"
        "    int2 h = int2(in.pos.xy);\n"
        "    int2 hw = int2(ao.get_width(), ao.get_height());\n"
        "    float z0 = ld(d, h * 2 + 1, p);\n"
        "    float acc = 0.0, wsum = 0.0;\n"
        "    for (int j = -2; j < 2; j++) for (int i = -2; i < 2; i++) {\n"
        "        int2 q = clamp(h + int2(i, j), int2(0), hw - 1);\n"
        "        float zq = ld(d, q * 2 + 1, p);\n"
        "        float w = saturate(1.0 - abs(zq - z0) / (z0 * 0.05 + 0.1));\n"
        "        acc += ao.read(uint2(q)).r * w; wsum += w;\n"
        "    }\n"
        "    return wsum > 0.0 ? acc / wsum : 1.0;\n"
        "}\n"
        /* bloom: bright, saturated (emissive) pixels at a quarter of the size */
        "fragment float4 bright_fs(QOut in [[stage_in]], texture2d<float> t [[texture(0)]],\n"
        "                          sampler s [[sampler(0)]], constant float4& r [[buffer(1)]]) {\n"
        "    float3 acc = 0.0;\n"
        "    for (int j = 0; j < 4; j++) {\n"
        "        float2 o = float2((j & 1) ? 0.5 : -0.5, (j & 2) ? 0.5 : -0.5) * r.xy;\n"
        "        float3 c = t.sample(s, in.uv + o).rgb;\n"
        "        float m = max(c.r, max(c.g, c.b)), n = min(c.r, min(c.g, c.b));\n"
        "        float sat = m > 0.0 ? (m - n) / m : 0.0;\n"
        "        float thr = mix(0.78, 0.6, sat);\n"                 /* neon glows earlier than white */
        "        acc += c * saturate((m - thr) / (1.0 - thr));\n"
        "    }\n"
        "    return float4(acc * 0.25, 1.0);\n"
        "}\n"
        "fragment float4 blur_fs(QOut in [[stage_in]], texture2d<float> t [[texture(0)]],\n"
        "                        sampler s [[sampler(0)]], constant float4& r [[buffer(1)]]) {\n"
        "    const float w[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };\n"
        "    float3 acc = t.sample(s, in.uv).rgb * w[0];\n"
        "    for (int i = 1; i < 5; i++) {\n"
        "        acc += t.sample(s, in.uv + r.xy * float(i)).rgb * w[i];\n"
        "        acc += t.sample(s, in.uv - r.xy * float(i)).rgb * w[i];\n"
        "    }\n"
        "    return float4(acc, 1.0);\n"
        "}\n"
        "fragment float4 comp_fs(QOut in [[stage_in]], texture2d<float> src [[texture(0)]],\n"
        "                        texture2d<float> ao [[texture(1)]], texture2d<float> bl [[texture(2)]],\n"
        "                        sampler s [[sampler(0)]], constant PostP& p [[buffer(0)]]) {\n"
        "    float4 c = src.sample(s, in.uv);\n"
        "    float v = ao.sample(s, in.uv).r;\n"
        "    if (p.debug > 0.5) return float4(v, v, v, c.a);\n"
        "    float l = dot(c.rgb, float3(0.299, 0.587, 0.114));\n"
        "    float keep = smoothstep(0.55, 0.9, l);\n"            /* lit / emissive: leave alone */
        "    v = mix(1.0, v, p.k * (1.0 - keep));\n"
        "    c.rgb = c.rgb * v + bl.sample(s, in.uv).rgb * p.bloom * p.k;\n"
        "    return c;\n"
        "}\n";
}

static void post_settings(void)
{
    const char *e;
    if (s_post_init_done)
        return;
    s_post_init_done = 1;
    s_gamma_v[0] = s_gamma_v[1] = s_gamma_v[2] = s_gamma_v[3] = 1.0f;
    s_gamma_on = 0;                 /* Original again after Modern/Warm (the overlay) */
    e = getenv("NFSU2_GAMMA");
    if (e && !strcmp(e, "modern")) {
        s_gamma_v[0] = 2.2f / 2.5f; s_gamma_on = 1;
    } else if (e && !strcmp(e, "warm")) {
        s_gamma_v[0] = 2.5f / 2.2f; s_gamma_v[2] = 0.97f; s_gamma_v[3] = 0.90f; s_gamma_on = 1;
    }
    e = getenv("NFSU2_AO");
    s_ao_on = e && *e == '1';
    e = getenv("NFSU2_BLOOM");
    s_bloom_k = e ? (float)atof(e) : 0.35f;
    if (s_bloom_k < 0) s_bloom_k = 0;
    if (s_bloom_k > 1) s_bloom_k = 1;
    e = getenv("NFSU2_POST_DEBUG");
    s_post_debug = e && *e == '1';
    if ((e = getenv("NFSU2_AO_NEAR"))) s_ao_near = (float)atof(e);
    if ((e = getenv("NFSU2_AO_FAR"))) s_ao_far = (float)atof(e);
    if ((e = getenv("NFSU2_AO_FADE"))) s_ao_fade_m = (float)atof(e);
    fprintf(stderr, "[post] gamma %s, ambient occlusion %s, bloom %.2f%s\n",
            s_gamma_v[0] == 1.0f ? "original" : s_gamma_v[0] < 1.0f ? "modern" : "warm",
            s_ao_on ? "on" : "off", s_bloom_k, s_post_debug ? " (debug: occlusion only)" : "");
}

static int post_shaders(void)
{
    NSError *err = nil;
    id<MTLLibrary> lib;
    MTLRenderPipelineDescriptor *d;
    struct { const char *fs; MTLPixelFormat fmt; id<MTLRenderPipelineState> __strong *out; } P[] = {
        { "present_fs", MTLPixelFormatBGRA8Unorm, &s_present_pipe },
        { "fxaa_fs", MTLPixelFormatBGRA8Unorm, &s_fxaa_pipe },
        { "ao_fs", MTLPixelFormatR8Unorm, &s_ao_pipe },
        { "aoblur_fs", MTLPixelFormatR8Unorm, &s_aoblur_pipe },
        { "bright_fs", MTLPixelFormatRGBA16Float, &s_bright_pipe },
        { "blur_fs", MTLPixelFormatRGBA16Float, &s_blur_pipe },
        { "comp_fs", MTLPixelFormatBGRA8Unorm, &s_comp_pipe },
    };
    post_settings();
    lib = [s_dev newLibraryWithSource:[NSString stringWithUTF8String:post_msl()] options:s_copts error:&err];
    if (!lib) {
        LOGE("post shaders: %s\n", err.localizedDescription.UTF8String);
        return 0;
    }
    for (size_t i = 0; i < sizeof P / sizeof P[0]; i++) {
        d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"post_vs"];
        d.fragmentFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:P[i].fs]];
        d.colorAttachments[0].pixelFormat = P[i].fmt;
        if (!(*P[i].out = [s_dev newRenderPipelineStateWithDescriptor:d error:&err])) {
            LOGE("post pipeline %s: %s\n", P[i].fs, err.localizedDescription.UTF8String);
            return 0;
        }
    }
    return 1;
}

/* A full-screen pass into dst with pipe; textures 0.., bytes at fragment buffer 0/1. */
static void post_pass(id<MTLTexture> dst, id<MTLRenderPipelineState> pipe, id<MTLTexture> __strong *tex, int ntex,
                      const void *fb0, size_t fb0n, const void *fb1, size_t fb1n)
{
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    id<MTLRenderCommandEncoder> e;
    float uv[4] = { 0, 0, 1, 1 };
    rp.colorAttachments[0].texture = dst;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    e = [s_cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:pipe];
    [e setVertexBytes:uv length:sizeof uv atIndex:0];
    for (int i = 0; i < ntex; i++)
        [e setFragmentTexture:tex[i] atIndex:i];
    [e setFragmentSamplerState:s_linear atIndex:0];
    if (fb0) [e setFragmentBytes:fb0 length:fb0n atIndex:0];
    if (fb1) [e setFragmentBytes:fb1 length:fb1n atIndex:1];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [e endEncoding];
}

static id<MTLTexture> post_tex(id<MTLTexture> t, MTLPixelFormat f, uint32_t w, uint32_t h)
{
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    if (t && t.width == w && t.height == h)
        return t;
    return make_texture(MTLTextureType2D, f, w, h, MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
}

static void post_run(MtSurf *s, MtDepth *d)
{
    struct { float near_, far_, w, h, strength, radius, debug, bloom, fade_m, k; } p;
    id<MTLTexture> t[3];
    uint32_t qw = s->pw / 4, qh = s->ph / 4;
    int ao = s_ao_on && d && d->pw == s->pw && d->ph == s->ph;

    end_pass();
    end_blit();
    s_post_src = post_tex(s_post_src, MTLPixelFormatBGRA8Unorm, s->pw, s->ph);
    s_post_ao = post_tex(s_post_ao, MTLPixelFormatR8Unorm, s->pw / 2, s->ph / 2);
    s_post_ao2 = post_tex(s_post_ao2, MTLPixelFormatR8Unorm, s->pw / 2, s->ph / 2);
    s_post_b0 = post_tex(s_post_b0, MTLPixelFormatRGBA16Float, qw, qh);
    s_post_b1 = post_tex(s_post_b1, MTLPixelFormatRGBA16Float, qw, qh);
    if (!s_post_src || !s_post_ao || !s_post_ao2 || !s_post_b0 || !s_post_b1)
        return;
    [blit() copyFromTexture:s->tex toTexture:s_post_src];
    end_blit();

    p.near_ = s_ao_near; p.far_ = s_ao_far;
    p.w = (float)s->pw; p.h = (float)s->ph;
    p.strength = ao ? 0.9f : 0.0f;
    p.fade_m = s_ao_fade_m;
    p.k = s_post_fade;
    p.radius = 1.0f;                  /* world units (the game's metres) */
    p.debug = s_post_debug ? 1.0f : 0.0f;
    p.bloom = s_bloom_k;
    if (ao) {
        t[0] = d->tex;
        post_pass(s_post_ao, s_ao_pipe, t, 1, &p, sizeof p, NULL, 0);
        t[0] = s_post_ao; t[1] = d->tex;
        post_pass(s_post_ao2, s_aoblur_pipe, t, 2, &p, sizeof p, NULL, 0);
    } else {
        float one[4] = { 1, 1, 1, 1 };   /* AO texture cleared to 1 by a gamma-less copy of white */
        (void)one;
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = s_post_ao2;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        [[s_cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    }
    if (s_bloom_k > 0) {
        float r[4] = { 4.0f / s->pw, 4.0f / s->ph, 0, 0 };
        t[0] = s_post_src;
        post_pass(s_post_b0, s_bright_pipe, t, 1, NULL, 0, r, sizeof r);
        for (int k = 1; k <= 2; k++) {
            float h[4] = { (float)k / qw, 0, 0, 0 }, v[4] = { 0, (float)k / qh, 0, 0 };
            t[0] = s_post_b0; post_pass(s_post_b1, s_blur_pipe, t, 1, NULL, 0, h, sizeof h);
            t[0] = s_post_b1; post_pass(s_post_b0, s_blur_pipe, t, 1, NULL, 0, v, sizeof v);
        }
    } else {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = s_post_b0;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        [[s_cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    }
    t[0] = s_post_src; t[1] = s_post_ao2; t[2] = s_post_b0;
    post_pass(s->tex, s_comp_pipe, t, 3, &p, sizeof p, NULL, 0);
    s->gen++;
    s_post_runs++;
}

/* Every draw, before its pass begins: counts the scene's depth-tested draws
 * and runs the effects at the first draw without the depth test after it. */
static void post_scene_hook(MtSurf *s, MtDepth *d, const uint32_t *r)
{
    if (s_post_done || (!s_ao_on && s_bloom_k <= 0))
        return;
    if (d && r[0x30C / 4]) {
        if (s == s_scene) {
            s_scene_draws++;
            s_scene_d = d;
        } else if (s->pw * 10 >= s_post_pw * 9 && s_scene_draws < 150) {
            s_scene = s; s_scene_d = d; s_scene_draws = 1;
        }
        return;
    }
    if (s_scene && s_scene_draws >= (s_post_active ? 60u : 150u)) {
        if (!s_post_active)
            s_post_fade = 0.0f;
        s_post_active = 1;
        s_post_idle = 0;
        post_run(s_scene, s_scene_d);
        s_post_done = 1;
    }
}

/* At every flip: a new frame, and the presented width for the next one. */
static void post_frame(MtSurf *presented)
{
    post_settings();                /* again after nv2a_mtl_post_reload (the overlay's Gamma/Effects) */
    s_post_frames++;
    if (s_post_frames % 600 == 0 && (s_ao_on || s_bloom_k > 0))
        fprintf(stderr, "[post] scene effects ran in %u of the last 600 frames\n", s_post_runs),
        s_post_runs = 0;
    s_post_pw = presented ? presented->pw : 0;
    if (s_post_done) {
        s_post_fade = s_post_fade + 0.05f > 1.0f ? 1.0f : s_post_fade + 0.05f;
    } else if (s_post_active && ++s_post_idle > 30) {
        s_post_active = 0;
    }
    s_scene = NULL; s_scene_d = NULL; s_scene_draws = 0; s_post_done = 0;
}
