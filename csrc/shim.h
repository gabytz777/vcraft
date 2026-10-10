/* csrc/shim.h - prototypes for the C platform layer.
 * V does not emit C declarations for `fn C.name(...)`, so this header is
 * #included from V to give the C compiler real prototypes. */
#ifndef VCRAFT_SHIM_H
#define VCRAFT_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

int mc_init(int mode, const char *title, int w, int h);
int mc_make_texture(const unsigned char *data, int size, int layers);
void mc_use_texture(int tex);
void mc_upload(const float *verts, int count);
void mc_set_uniforms(const float *mvp, const float *view, float fr, float fg,
                     float fb, float fog_near, float fog_far, float alpha_cutoff,
                     float time, float tr, float tg, float tb);
void mc_begin(int clear, float r, float g, float b);
void mc_blend(int on);
void mc_draw(int count);
void mc_draw_lines(int count);
void mc_ui_begin(void);
void mc_ui_end(void);
void mc_draw_colors(const float *verts, int count, const float *proj);
int mc_screenshot(const unsigned char *path, int w, int h);
int mc_write_atlas(const unsigned char *data, int size, int layers, int scale,
                   const unsigned char *path);

unsigned long long mc_keys(void);
unsigned long long mc_buttons(void);
int mc_mouse_dx(void);
int mc_mouse_dy(void);
int mc_should_close(void);
int mc_resized(void);
int mc_win_w(void);
int mc_win_h(void);
void mc_pump(void);
int mc_key_pressed(int sc);
int mc_key_down(int sc);
int mc_scancode(const char *name);
int mc_inject_key(int sc, int down);
int mc_inject_button(int button, int down);
int mc_present(void);
void mc_gl_version(char *buf, int len);
void mc_gl_renderer(char *buf, int len);

#ifdef __cplusplus
}
#endif

#endif /* VCRAFT_SHIM_H */
