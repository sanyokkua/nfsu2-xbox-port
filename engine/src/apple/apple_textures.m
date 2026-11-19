/**
 * Texture replacement for NFSU2 on the Mac (Deadware): the title side of
 * nv2a_metal's nv2a_tex_replace_hook.
 *
 *   NFSU2_TEX_DUMP=<dir>   write every new 2D texture once as
 *                          <hash>_<fmt>_<w>x<h>.png (finding hashes).
 *
 * Users of the hook register a provider (button prompts, HD packs); the
 * first that answers wins.
 */
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "../../xboxrecomp/src/kernel/nv2a_backend.h"
#include "apple_textures.h"

#define MAX_PROVIDERS 4
static nfsu2_tex_provider s_prov[MAX_PROVIDERS];
static int s_nprov;
static const char *s_dump;
static NSMutableSet<NSNumber *> *s_dumped;

void nfsu2_tex_write_png(const char *path, const uint32_t *argb, uint32_t w, uint32_t h)
{
    /* A8R8G8B8 little endian = BGRA bytes, straight alpha. */
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)argb, (CFIndex)w * h * 4);
    CGDataProviderRef dp = CGDataProviderCreateWithCFData(data);
    CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, cs,
        kCGImageAlphaFirst | kCGBitmapByteOrder32Little, dp, NULL, false,
        kCGRenderingIntentDefault);
    if (img) {
        NSURL *u = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)u,
                                                                  CFSTR("public.png"), 1, NULL);
        if (d) {
            CGImageDestinationAddImage(d, img, NULL);
            CGImageDestinationFinalize(d);
            CFRelease(d);
        }
        CGImageRelease(img);
    }
    CGDataProviderRelease(dp);
    CFRelease(data);
    CGColorSpaceRelease(cs);
}

static const uint32_t *replace(const Nv2aTexInfo *ti, uint32_t *k)
{
    int i;
    static int logged;
    if (logged < 3 && getenv("NFSU2_TEX_TRACE")) {
        logged++;
        fprintf(stderr, "[tex] ask %016llx fmt %02x %ux%u\n", (unsigned long long)ti->hash,
                ti->color, ti->w, ti->h);
    }
    if (s_dump) {
        NSNumber *key = @(ti->hash);
        if (![s_dumped containsObject:key]) {
            char path[1024];
            [s_dumped addObject:key];
            snprintf(path, sizeof path, "%s/%016llx_%02x_%ux%u.png", s_dump,
                     (unsigned long long)ti->hash, ti->color, ti->w, ti->h);
            nfsu2_tex_write_png(path, ti->argb, ti->w, ti->h);
        }
    }
    for (i = 0; i < s_nprov; i++) {
        const uint32_t *px = s_prov[i](ti, k);
        if (px)
            return px;
    }
    return NULL;
}

void nfsu2_tex_add_provider(nfsu2_tex_provider p)
{
    if (s_nprov < MAX_PROVIDERS)
        s_prov[s_nprov++] = p;
    nv2a_tex_replace_hook = replace;
}

void nfsu2_tex_init(void)
{
    const char *d = getenv("NFSU2_TEX_DUMP");
    if (d && *d) {
        s_dump = strdup(d);
        mkdir(s_dump, 0755);
        s_dumped = [NSMutableSet new];
        nv2a_tex_replace_hook = replace;
        fprintf(stderr, "[tex] dumping new textures to %s\n", s_dump);
    }
    nfsu2_prompts_init();
}
