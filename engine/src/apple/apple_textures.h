/* Texture replacement on the Mac (apple_textures.m). */
#ifndef APPLE_TEXTURES_H
#define APPLE_TEXTURES_H
#include <stdint.h>
#include "../../xboxrecomp/src/kernel/nv2a_backend.h"

typedef const uint32_t *(*nfsu2_tex_provider)(const Nv2aTexInfo *ti, uint32_t *k);
void nfsu2_tex_init(void);
void nfsu2_tex_add_provider(nfsu2_tex_provider p);
void nfsu2_tex_write_png(const char *path, const uint32_t *argb, uint32_t w, uint32_t h);

/* Button prompts for the connected pad (apple_prompts.m). */
void nfsu2_prompts_init(void);
void nfsu2_prompts_pads_changed(void);   /* host main thread only */
#endif
