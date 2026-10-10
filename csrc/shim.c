/*
 * csrc/shim.c - thin C platform layer for the V voxel engine.
 *
 * This file intentionally contains ONLY boilerplate that is painful or
 * unreliable to express through V's FFI (GL object lifetime, shader
 * compilation, EGL/SDL context creation, PNG encoding, input pumping).
 * All game logic lives in V.
 */
#define GL_GLEXT_PROTOTYPES 1

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <zlib.h>

#include <GL/gl.h>
#include <GL/glext.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

#include <SDL2/SDL.h>

/* ------------------------------------------------------------------ */
/* GL objects                                                          */
/* ------------------------------------------------------------------ */

static GLuint g_prog = 0;
static GLuint g_vao = 0;
static GLuint g_vbo = 0;
/* Separate program/VAO for the flat-colour HUD, so UI colours never fight
 * the textured world shader's vertex format. */
static GLuint g_ui_prog = 0;
static GLuint g_ui_vao = 0;
static GLuint g_ui_vbo = 0;
static GLint u_ui_proj = -1;
static GLint u_mvp = -1, u_view = -1, u_fog_color = -1, u_fog_range = -1;
static GLint u_alpha_cutoff = -1, u_tex = -1, u_time = -1, u_tint = -1;
static GLuint g_white_tex = 0;
static int g_win_w = 0, g_win_h = 0;
static SDL_Window *g_win = NULL;

/* ------------------------------------------------------------------ */
/* Shaders                                                             */
/* ------------------------------------------------------------------ */

static const char *VS_SRC =
    "#version 330 core\n"
    "layout(location=0) in vec3 a_pos;\n"
    "layout(location=1) in vec2 a_uv;\n"
    "layout(location=2) in float a_layer;\n"
    "layout(location=3) in float a_light;\n"
    "uniform mat4 u_mvp;\n"
    "uniform mat4 u_view;\n"
    "out vec2 v_uv;\n"
    "out float v_layer;\n"
    "out float v_light;\n"
    "out float v_dist;\n"
    "void main() {\n"
    "  v_uv = a_uv;\n"
    "  v_layer = a_layer;\n"
    "  v_light = a_light;\n"
    "  vec4 vp = u_view * vec4(a_pos, 1.0);\n"
    "  v_dist = length(vp.xyz);\n"
    "  gl_Position = u_mvp * vec4(a_pos, 1.0);\n"
    "}\n";

static const char *FS_SRC =
    "#version 330 core\n"
    "in vec2 v_uv;\n"
    "in float v_layer;\n"
    "in float v_light;\n"
    "in float v_dist;\n"
    "uniform sampler2DArray u_tex;\n"
    "uniform vec3 u_fog_color;\n"
    "uniform vec2 u_fog_range;\n"
    "uniform float u_alpha_cutoff;\n"
    "uniform float u_time;\n"
    "uniform vec3 u_tint;\n"
    "out vec4 out_color;\n"
    "void main() {\n"
    "  vec2 uv = v_uv;\n"
    "  float layer = v_layer;\n"
    "  if (layer < 0.0) {\n"
    "    /* animated water surface */\n"
    "    uv.x += sin(u_time * 1.3 + v_uv.y * 6.283) * 0.03;\n"
    "    uv.y += cos(u_time * 0.9 + v_uv.x * 6.283) * 0.03;\n"
    "  }\n"
    "  vec4 c = texture(u_tex, vec3(uv, abs(layer)));\n"
    "  if (c.a < u_alpha_cutoff) discard;\n"
    "  vec3 col = c.rgb * v_light * u_tint;\n"
    "  float f = smoothstep(u_fog_range.x, u_fog_range.y, v_dist);\n"
    "  col = mix(col, u_fog_color, f);\n"
    "  out_color = vec4(col, c.a);\n"
    "}\n";

static GLuint compile_shader(GLenum type, const char *src, const char *tag)
{
    GLuint sh = glCreateShader(type);
    glShaderSource(sh, 1, &src, NULL);
    glCompileShader(sh);
    GLint ok = 0;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetShaderInfoLog(sh, sizeof(log), NULL, log);
        fprintf(stderr, "[shim] %s shader failed: %s\n", tag, log);
    }
    return sh;
}

static const char *UI_VS_SRC =
    "#version 330 core\n"
    "layout(location=0) in vec2 a_pos;\n"
    "layout(location=1) in vec4 a_col;\n"
    "uniform mat4 u_proj;\n"
    "out vec4 v_col;\n"
    "void main() {\n"
    "  v_col = a_col;\n"
    "  gl_Position = u_proj * vec4(a_pos, 0.0, 1.0);\n"
    "}\n";

static const char *UI_FS_SRC =
    "#version 330 core\n"
    "in vec4 v_col;\n"
    "out vec4 out_color;\n"
    "void main() { out_color = v_col; }\n";

static int build_ui_program(void)
{
    GLuint vs = compile_shader(GL_VERTEX_SHADER, UI_VS_SRC, "ui-vertex");
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, UI_FS_SRC, "ui-fragment");
    g_ui_prog = glCreateProgram();
    glAttachShader(g_ui_prog, vs);
    glAttachShader(g_ui_prog, fs);
    glLinkProgram(g_ui_prog);
    GLint ok = 0;
    glGetProgramiv(g_ui_prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetProgramInfoLog(g_ui_prog, sizeof(log), NULL, log);
        fprintf(stderr, "[shim] ui link failed: %s\n", log);
        return 0;
    }
    glDeleteShader(vs);
    glDeleteShader(fs);
    u_ui_proj = glGetUniformLocation(g_ui_prog, "u_proj");

    glGenVertexArrays(1, &g_ui_vao);
    glBindVertexArray(g_ui_vao);
    glGenBuffers(1, &g_ui_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, g_ui_vbo);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 6 * sizeof(float), (void *)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, 6 * sizeof(float), (void *)(2 * sizeof(float)));
    return 1;
}

static int build_program(void)
{
    GLuint vs = compile_shader(GL_VERTEX_SHADER, VS_SRC, "vertex");
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, FS_SRC, "fragment");
    g_prog = glCreateProgram();
    glAttachShader(g_prog, vs);
    glAttachShader(g_prog, fs);
    glLinkProgram(g_prog);
    GLint ok = 0;
    glGetProgramiv(g_prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetProgramInfoLog(g_prog, sizeof(log), NULL, log);
        fprintf(stderr, "[shim] link failed: %s\n", log);
        return 0;
    }
    glDeleteShader(vs);
    glDeleteShader(fs);
    u_mvp = glGetUniformLocation(g_prog, "u_mvp");
    u_view = glGetUniformLocation(g_prog, "u_view");
    u_fog_color = glGetUniformLocation(g_prog, "u_fog_color");
    u_fog_range = glGetUniformLocation(g_prog, "u_fog_range");
    u_alpha_cutoff = glGetUniformLocation(g_prog, "u_alpha_cutoff");
    u_tex = glGetUniformLocation(g_prog, "u_tex");
    u_time = glGetUniformLocation(g_prog, "u_time");
    u_tint = glGetUniformLocation(g_prog, "u_tint");
    return 1;
}

/* ------------------------------------------------------------------ */
/* Context creation                                                    */
/* ------------------------------------------------------------------ */

static int ctx_offscreen(int w, int h)
{
    /* The GL context comes from EGL here, but the event queue still has to
     * be initialised or SDL_PollEvent/SDL_PushEvent silently do nothing. */
    SDL_InitSubSystem(SDL_INIT_EVENTS);
    EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (d == EGL_NO_DISPLAY) {
        fprintf(stderr, "[shim] no EGL display\n");
        return 0;
    }
    EGLint maj, min;
    if (!eglInitialize(d, &maj, &min)) {
        fprintf(stderr, "[shim] eglInitialize failed\n");
        return 0;
    }
    EGLint attrs[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                       EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_NONE };
    EGLConfig cfg;
    EGLint n = 0;
    if (!eglChooseConfig(d, attrs, &cfg, 1, &n) || n < 1) {
        fprintf(stderr, "[shim] eglChooseConfig failed\n");
        return 0;
    }
    EGLint pb[] = { EGL_WIDTH, w, EGL_HEIGHT, h, EGL_NONE };
    EGLSurface surf = eglCreatePbufferSurface(d, cfg, pb);
    eglBindAPI(EGL_OPENGL_API);
    EGLContext ctx = eglCreateContext(d, cfg, EGL_NO_CONTEXT, NULL);
    if (ctx == EGL_NO_CONTEXT) {
        fprintf(stderr, "[shim] eglCreateContext failed\n");
        return 0;
    }
    eglMakeCurrent(d, surf, surf, ctx);
    g_win_w = w;
    g_win_h = h;
    return 1;
}

static int ctx_window(const char *title, int w, int h)
{
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "[shim] SDL_Init: %s\n", SDL_GetError());
        return 0;
    }
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
    g_win = SDL_CreateWindow(title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                             w, h, SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE);
    if (!g_win) {
        fprintf(stderr, "[shim] SDL_CreateWindow: %s\n", SDL_GetError());
        return 0;
    }
    SDL_GLContext ctx = SDL_GL_CreateContext(g_win);
    if (!ctx) {
        fprintf(stderr, "[shim] SDL_GL_CreateContext: %s\n", SDL_GetError());
        return 0;
    }
    SDL_GL_MakeCurrent(g_win, ctx);
    SDL_GL_SetSwapInterval(1);
    SDL_SetRelativeMouseMode(SDL_TRUE);
    g_win_w = w;
    g_win_h = h;
    return 1;
}

/* mode: 0 = offscreen (headless), 1 = window */
int mc_init(int mode, const char *title, int w, int h)
{
    int ok = 0;
    if (mode == 0) {
        ok = ctx_offscreen(w, h);
    } else {
        ok = ctx_window(title, w, h);
    }
    if (!ok) return 0;
    if (!build_program()) return 0;
    if (!build_ui_program()) return 0;

    glGenVertexArrays(1, &g_vao);
    glBindVertexArray(g_vao);
    glGenBuffers(1, &g_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 7 * sizeof(float), (void *)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 7 * sizeof(float), (void *)(3 * sizeof(float)));
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, 7 * sizeof(float), (void *)(5 * sizeof(float)));
    glEnableVertexAttribArray(3);
    glVertexAttribPointer(3, 1, GL_FLOAT, GL_FALSE, 7 * sizeof(float), (void *)(6 * sizeof(float)));

    glEnable(GL_DEPTH_TEST);
    glEnable(GL_CULL_FACE);
    glCullFace(GL_BACK);
    glClearColor(0.48f, 0.66f, 0.92f, 1.0f);

    /* 1x1 white fallback texture array so UI draws work before/at init */
    unsigned char px[4] = { 255, 255, 255, 255 };
    glGenTextures(1, &g_white_tex);
    glBindTexture(GL_TEXTURE_2D_ARRAY, g_white_tex);
    glTexImage3D(GL_TEXTURE_2D_ARRAY, 0, GL_RGBA8, 1, 1, 1, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, px);
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    return 1;
}

/* ------------------------------------------------------------------ */
/* Texture array (procedural art generated in V)                      */
/* ------------------------------------------------------------------ */

/* data: layers * size * size * 4 bytes, layer-major */
int mc_make_texture(const unsigned char *data, int size, int layers)
{
    GLuint t = 0;
    glGenTextures(1, &t);
    glBindTexture(GL_TEXTURE_2D_ARRAY, t);
    glTexImage3D(GL_TEXTURE_2D_ARRAY, 0, GL_RGBA8, size, size, layers, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, data);
    /* crisp Minecraft-style pixels: no filtering, no mips */
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return (int)t;
}

void mc_use_texture(int tex)
{
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D_ARRAY, (GLuint)(tex ? tex : g_white_tex));
}

/* ------------------------------------------------------------------ */
/* Mesh upload / draw                                                  */
/* ------------------------------------------------------------------ */

void mc_upload(const float *verts, int count)
{
    glBindVertexArray(g_vao);
    glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)count * 7 * sizeof(float),
                 verts, GL_DYNAMIC_DRAW);
}

/* HUD drawing: flat RGBA vertices in screen space, no depth, no culling. */
void mc_ui_begin(void)
{
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
}

void mc_ui_end(void)
{
    glEnable(GL_DEPTH_TEST);
    glEnable(GL_CULL_FACE);
    glBindVertexArray(g_vao);
}

/* verts: 6 floats per vertex (x, y, r, g, b, a), already in draw order. */
void mc_draw_colors(const float *verts, int count, const float *proj)
{
    glUseProgram(g_ui_prog);
    glUniformMatrix4fv(u_ui_proj, 1, GL_FALSE, proj);
    glBindVertexArray(g_ui_vao);
    glBindBuffer(GL_ARRAY_BUFFER, g_ui_vbo);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)count * 6 * sizeof(float),
                 verts, GL_DYNAMIC_DRAW);
    if (count > 0) glDrawArrays(GL_TRIANGLES, 0, count);
}

void mc_set_uniforms(const float *mvp, const float *view,
                     float fr, float fg, float fb, float fog_near, float fog_far,
                     float alpha_cutoff, float time, float tr, float tg, float tb)
{
    glUseProgram(g_prog);
    glUniformMatrix4fv(u_mvp, 1, GL_FALSE, mvp);
    glUniformMatrix4fv(u_view, 1, GL_FALSE, view);
    glUniform3f(u_fog_color, fr, fg, fb);
    glUniform2f(u_fog_range, fog_near, fog_far);
    glUniform1f(u_alpha_cutoff, alpha_cutoff);
    glUniform1f(u_time, time);
    glUniform3f(u_tint, tr, tg, tb);
    glUniform1i(u_tex, 0);
}

void mc_begin(int clear, float r, float g, float b)
{
    glViewport(0, 0, g_win_w, g_win_h);
    glClearColor(r, g, b, 1.0f);
    if (clear) {
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    }
}

/* Alpha blending, used for the translucent water pass. */
void mc_blend(int on)
{
    if (on) {
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDepthMask(GL_FALSE);
    } else {
        glDisable(GL_BLEND);
        glDepthMask(GL_TRUE);
    }
}

void mc_draw(int count)
{
    if (count > 0) glDrawArrays(GL_TRIANGLES, 0, count);
}

/* Line primitives, used for the targeted-block outline. */
void mc_draw_lines(int count)
{
    if (count > 0) glDrawArrays(GL_LINES, 0, count);
}

/* ------------------------------------------------------------------ */
/* PNG output (for headless screenshots)                               */
/* ------------------------------------------------------------------ */

static void be32(unsigned char *p, unsigned int v)
{
    p[0] = (unsigned char)(v >> 24);
    p[1] = (unsigned char)(v >> 16);
    p[2] = (unsigned char)(v >> 8);
    p[3] = (unsigned char)v;
}

static void png_chunk(FILE *f, const char *type, const unsigned char *data, unsigned int len)
{
    unsigned char hdr[4], crcbuf[4];
    be32(hdr, len);
    fwrite(hdr, 1, 4, f);
    fwrite(type, 1, 4, f);
    if (len) fwrite(data, 1, len, f);
    uLong c = crc32(0, (const Bytef *)type, 4);
    if (len) c = crc32(c, data, len);
    be32(crcbuf, (unsigned int)c);
    fwrite(crcbuf, 1, 4, f);
}

/* flip: 1 when the source rows are bottom-up (glReadPixels), else 0. */
static int write_png(const unsigned char *px, int w, int h, int flip, const char *path)
{
    size_t raw_len = (size_t)h * ((size_t)w * 4 + 1);
    unsigned char *raw = (unsigned char *)malloc(raw_len);
    if (!raw) return 0;
    for (int y = 0; y < h; y++) {
        unsigned char *dst = raw + (size_t)y * ((size_t)w * 4 + 1);
        dst[0] = 0; /* filter: none */
        int src_y = flip ? (h - 1 - y) : y;
        memcpy(dst + 1, px + (size_t)src_y * w * 4, (size_t)w * 4);
    }

    uLongf zlen = compressBound((uLong)raw_len);
    unsigned char *z = (unsigned char *)malloc(zlen);
    if (!z) { free(raw); return 0; }
    if (compress2(z, &zlen, raw, (uLong)raw_len, 6) != Z_OK) {
        fprintf(stderr, "[shim] zlib compress failed\n");
        free(raw);
        free(z);
        return 0;
    }

    FILE *f = fopen(path, "wb");
    if (!f) { free(raw); free(z); return 0; }
    static const unsigned char sig[8] = { 137, 80, 78, 71, 13, 10, 26, 10 };
    fwrite(sig, 1, 8, f);

    unsigned char ihdr[13];
    be32(ihdr, (unsigned int)w);
    be32(ihdr + 4, (unsigned int)h);
    ihdr[8] = 8;  /* bit depth */
    ihdr[9] = 6;  /* colour type RGBA */
    ihdr[10] = 0; /* deflate */
    ihdr[11] = 0; /* adaptive filtering */
    ihdr[12] = 0; /* no interlace */
    png_chunk(f, "IHDR", ihdr, 13);
    png_chunk(f, "IDAT", z, (unsigned int)zlen);
    png_chunk(f, "IEND", NULL, 0);
    fclose(f);

    free(raw);
    free(z);
    return 1;
}

int mc_screenshot(const unsigned char *path, int w, int h)
{
    unsigned char *px = (unsigned char *)malloc((size_t)w * h * 4);
    if (!px) return 0;
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px);
    int ok = write_png(px, w, h, 1, (const char *)path);
    free(px);
    return ok;
}

/* Lay the texture array out as a grid and write it straight from memory.
 * Bypasses GL entirely, so it works even when rendering is unavailable. */
int mc_write_atlas(const unsigned char *data, int size, int layers, int scale,
                   const unsigned char *path)
{
    if (scale < 1) scale = 1;
    int cols = 6;
    int rows = (layers + cols - 1) / cols;
    int pad = 4;
    int cell = size * scale;
    int w = cols * (cell + pad) + pad;
    int h = rows * (cell + pad) + pad;
    unsigned char *px = (unsigned char *)malloc((size_t)w * h * 4);
    if (!px) return 0;
    for (int i = 0; i < w * h; i++) {
        px[i * 4 + 0] = 24;
        px[i * 4 + 1] = 24,
        px[i * 4 + 2] = 28;
        px[i * 4 + 3] = 255;
    }
    for (int layer = 0; layer < layers; layer++) {
        int cx = layer % cols, cy = layer / cols;
        int ox = pad + cx * (cell + pad);
        int oy = pad + cy * (cell + pad);
        for (int y = 0; y < cell; y++) {
            for (int x = 0; x < cell; x++) {
                int sx = x / scale, sy = y / scale;
                const unsigned char *src = data + ((size_t)layer * size * size +
                                   (size_t)sy * size + sx) * 4;
                unsigned char *dst = px + ((size_t)(oy + y) * w + (ox + x)) * 4;
                dst[0] = src[0];
                dst[1] = src[1];
                dst[2] = src[2];
                dst[3] = 255;
            }
        }
    }
    int ok = write_png(px, w, h, 0, (const char *)path);
    free(px);
    return ok;
}

/* ------------------------------------------------------------------ */
/* Input + present                                                     */
/* ------------------------------------------------------------------ */

/* One byte per SDL scancode. A u64 bitmask cannot hold scancodes >= 64
 * (Left Shift is 225), and storing the scancode itself rather than setting
 * a bit silently aliases unrelated keys. */
static Uint8 g_ks[SDL_NUM_SCANCODES];
static Uint8 g_ks_prev[SDL_NUM_SCANCODES];
static int g_keylog = -1;
static int g_mouse_dx = 0, g_mouse_dy = 0;
static Uint32 g_mouse_btns = 0;
static int g_close = 0;
static int g_resized = 0;

static void pump(void)
{
    SDL_Event ev;
    /* Snapshot held keys exactly once per frame. key_pressed() is a pure
     * query against this snapshot, so several queries in one frame all see
     * the same edge. */
    memcpy(g_ks_prev, g_ks, sizeof(g_ks));
    while (SDL_PollEvent(&ev)) {
        switch (ev.type) {
        case SDL_KEYDOWN:
            if (ev.key.repeat) break;
            if (g_keylog < 0) g_keylog = getenv("VKEYLOG") ? 1 : 0;
            if (g_keylog) {
                fprintf(stderr, "[key] down sc=%d name=[%s]\n",
                        (int)ev.key.keysym.scancode,
                        SDL_GetScancodeName(ev.key.keysym.scancode));
            }
            {
                int sc = (int)ev.key.keysym.scancode;
                if (sc >= 0 && sc < SDL_NUM_SCANCODES) g_ks[sc] = 1;
            }
            break;
        case SDL_KEYUP:
            if (g_keylog < 0) g_keylog = getenv("VKEYLOG") ? 1 : 0;
            if (g_keylog) {
                fprintf(stderr, "[key] up   sc=%d name=[%s]\n",
                        (int)ev.key.keysym.scancode,
                        SDL_GetScancodeName(ev.key.keysym.scancode));
            }
            {
                int sc = (int)ev.key.keysym.scancode;
                if (sc >= 0 && sc < SDL_NUM_SCANCODES) g_ks[sc] = 0;
            }
            break;
        case SDL_MOUSEMOTION:
            g_mouse_dx += ev.motion.xrel;
            g_mouse_dy += ev.motion.yrel;
            break;
        case SDL_MOUSEBUTTONDOWN:
            g_mouse_btns |= (1u << ev.button.button);
            break;
        case SDL_MOUSEBUTTONUP:
            g_mouse_btns &= ~(1u << ev.button.button);
            break;
        case SDL_WINDOWEVENT:
            if (ev.window.event == SDL_WINDOWEVENT_CLOSE) g_close = 1;
            if (ev.window.event == SDL_WINDOWEVENT_RESIZED ||
                ev.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
                g_resized = 1;
                g_win_w = ev.window.data1;
                g_win_h = ev.window.data2;
            }
            break;
        case SDL_QUIT:
            g_close = 1;
            break;
        default:
            break;
        }
    }
}

int mc_key_down(int sc)
{
    if (sc < 0 || sc >= SDL_NUM_SCANCODES) return 0;
    return g_ks[sc] ? 1 : 0;
}

/* Push a synthetic mouse button event, mirroring mc_inject_key. */
int mc_inject_button(int button, int down)
{
    SDL_Event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = down ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
    ev.button.type = (Uint32)ev.type;
    ev.button.state = down ? SDL_PRESSED : SDL_RELEASED;
    ev.button.button = (Uint8)button;
    ev.button.clicks = 1;
    return (int)SDL_PushEvent(&ev);
}

/* Bitmask over scancodes 0..63, for debug logging only. */
unsigned long long mc_keys(void)
{
    unsigned long long m = 0;
    for (int i = 0; i < 64; i++) if (g_ks[i]) m |= (1ULL << i);
    return m;
}
unsigned long long mc_buttons(void)   { return (unsigned long long)g_mouse_btns; }
int mc_mouse_dx(void) { int v = g_mouse_dx; g_mouse_dx = 0; return v; }
int mc_mouse_dy(void) { int v = g_mouse_dy; g_mouse_dy = 0; return v; }
int mc_should_close(void) { return g_close; }
int mc_resized(void) { int v = g_resized; g_resized = 0; return v; }
int mc_win_w(void) { return g_win_w; }
int mc_win_h(void) { return g_win_h; }

void mc_pump(void) { pump(); }

/* non-blocking edge detect on a key bit; does NOT pump, so calling it
 * for many keys in one frame sees the same snapshot */
/* Push a synthetic key event, so the whole event -> binding chain can be
 * tested without a human at the keyboard. */
int mc_inject_key(int sc, int down)
{
    SDL_Event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = down ? SDL_KEYDOWN : SDL_KEYUP;
    ev.key.type = (Uint32)ev.type;
    ev.key.state = down ? SDL_PRESSED : SDL_RELEASED;
    ev.key.repeat = 0;
    ev.key.keysym.scancode = (SDL_Scancode)sc;
    ev.key.keysym.sym = SDL_GetKeyFromScancode((SDL_Scancode)sc);
    return (int)SDL_PushEvent(&ev);
}

int mc_key_pressed(int sc)
{
    if (sc < 0 || sc >= SDL_NUM_SCANCODES) return 0;
    return (int)(g_ks[sc] && !g_ks_prev[sc]);
}

/* Resolve a key name to its real scancode, so the V-side table can be
 * checked against SDL instead of being trusted by hand. */
int mc_scancode(const char *name)
{
    return (int)SDL_GetScancodeFromName(name);
}

int mc_scroll(void)
{
    pump();
    static int acc = 0;
    int v = acc;
    acc = 0;
    return v;
}

int mc_present(void)
{
    if (!g_win) return 1;
    SDL_GL_SwapWindow(g_win);
    return 1;
}

void mc_gl_version(char *buf, int len)
{
    const char *s = (const char *)glGetString(GL_VERSION);
    if (!s) s = "unknown";
    snprintf(buf, (size_t)len, "%s", s);
}

void mc_gl_renderer(char *buf, int len)
{
    const char *s = (const char *)glGetString(GL_RENDERER);
    if (!s) s = "unknown";
    snprintf(buf, (size_t)len, "%s", s);
}
