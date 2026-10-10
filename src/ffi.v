module ffi

// Pure-V platform layer.
//
// This file replaces the old csrc/shim.c. It still links against the system
// C libraries (SDL2 / EGL / OpenGL / zlib) because those only expose a C ABI,
// but every line of logic - context creation, event handling, shader
// compilation, mesh upload, PNG encoding - now lives in V. There is no
// project-owned C source left.
//
// V 0.5.2 cannot read C struct layouts out of headers, so we deliberately
// avoid C structs entirely: every call is expressed with `voidptr`/fixed-width
// integers and the handful of SDL_Event bytes we care about (quit / resize)
// are read by explicit byte offset.

#flag -DGL_GLEXT_PROTOTYPES
#flag -lSDL2
#flag -lEGL
#flag -lGL
#flag -lz
#include <SDL2/SDL.h>
#include <GL/gl.h>
#include <GL/glext.h>
#include <EGL/egl.h>
#include <zlib.h>
#include <stdio.h>

// ------------------------------------------------------------------
// SDL2
// ------------------------------------------------------------------
fn C.SDL_Init(flags u32) i32
fn C.SDL_InitSubSystem(flags u32) i32
fn C.SDL_GL_SetAttribute(attr i32, value i32) i32
fn C.SDL_CreateWindow(title &char, x i32, y i32, w i32, h i32, flags u32) voidptr
fn C.SDL_GL_CreateContext(win voidptr) voidptr
fn C.SDL_GL_MakeCurrent(win voidptr, ctx voidptr) i32
fn C.SDL_GL_SetSwapInterval(interval i32) i32
fn C.SDL_SetRelativeMouseMode(enabled i32) i32
fn C.SDL_GL_SwapWindow(win voidptr)
fn C.SDL_PumpEvents()
fn C.SDL_PollEvent(ev voidptr) i32
fn C.SDL_GetKeyboardState(numkeys voidptr) &u8
fn C.SDL_GetRelativeMouseState(x &i32, y &i32) u32
fn C.SDL_GetScancodeFromName(name &char) i32
fn C.SDL_GetMouseState(x &i32, y &i32) u32
fn C.SDL_GetError() &char

// ------------------------------------------------------------------
// OpenGL
// ------------------------------------------------------------------
fn C.glGenVertexArrays(n i32, arrays &u32)
fn C.glBindVertexArray(vao u32)
fn C.glGenBuffers(n i32, bufs &u32)
fn C.glBindBuffer(target u32, buf u32)
fn C.glBufferData(target u32, size isize, data voidptr, usage u32)
fn C.glEnableVertexAttribArray(index u32)
fn C.glVertexAttribPointer(index u32, size i32, typ u32, normalized u8, stride i32, ptr voidptr)
fn C.glCreateShader(typ u32) u32
fn C.glShaderSource(shader u32, count i32, src &&char, length voidptr)
fn C.glCompileShader(shader u32)
fn C.glGetShaderiv(shader u32, pname u32, p &i32)
fn C.glGetShaderInfoLog(shader u32, max i32, len voidptr, log &u8)
fn C.glCreateProgram() u32
fn C.glAttachShader(prog u32, shader u32)
fn C.glLinkProgram(prog u32)
fn C.glGetProgramiv(prog u32, pname u32, p &i32)
fn C.glGetProgramInfoLog(prog u32, max i32, len voidptr, log &u8)
fn C.glDeleteShader(shader u32)
fn C.glGetUniformLocation(prog u32, name &char) i32
fn C.glUseProgram(prog u32)
fn C.glUniformMatrix4fv(loc i32, count i32, transpose u8, val &f32)
fn C.glUniform3f(loc i32, a f32, b f32, c f32)
fn C.glUniform2f(loc i32, a f32, b f32)
fn C.glUniform1f(loc i32, v f32)
fn C.glUniform1i(loc i32, v i32)
fn C.glViewport(x i32, y i32, w i32, h i32)
fn C.glClearColor(r f32, g f32, b f32, a f32)
fn C.glClear(mask u32)
fn C.glEnable(cap u32)
fn C.glDisable(cap u32)
fn C.glCullFace(mode u32)
fn C.glDepthMask(flag u8)
fn C.glBlendFunc(sfactor u32, dfactor u32)
fn C.glDrawArrays(mode u32, first i32, count i32)
fn C.glReadPixels(x i32, y i32, w i32, h i32, fmt u32, typ u32, pixels voidptr)
fn C.glPixelStorei(pname u32, param i32)
fn C.glGenTextures(n i32, tex &u32)
fn C.glBindTexture(target u32, tex u32)
fn C.glTexImage3D(target u32, level i32, internal_fmt i32, w i32, h i32, depth i32, border i32, fmt u32, typ u32, pixels voidptr)
fn C.glTexImage2D(target u32, level i32, internal_fmt i32, w i32, h i32, border i32, fmt u32, typ u32, pixels voidptr)
fn C.glTexParameteri(target u32, pname u32, param i32)
fn C.glActiveTexture(tex u32)
fn C.glGetString(name u32) &char

// ------------------------------------------------------------------
// EGL (used for the offscreen / headless context)
// ------------------------------------------------------------------
fn C.eglGetDisplay(id voidptr) voidptr
fn C.eglInitialize(dpy voidptr, maj &i32, min &i32) i32
fn C.eglChooseConfig(dpy voidptr, attribs &i32, configs voidptr, n i32, num &i32) i32
fn C.eglCreatePbufferSurface(dpy voidptr, cfg voidptr, attribs &i32) voidptr
fn C.eglBindAPI(api u32) i32
fn C.eglCreateContext(dpy voidptr, cfg voidptr, share voidptr, attribs voidptr) voidptr
fn C.eglMakeCurrent(dpy voidptr, draw voidptr, read voidptr, ctx voidptr) i32

// ------------------------------------------------------------------
// zlib + stdio (PNG encoding)
// ------------------------------------------------------------------
fn C.compressBound(source_len u64) u64
fn C.compress2(dest &u8, dest_len &u64, src &u8, src_len u64, level i32) i32
fn C.crc32(crc u32, buf &u8, len u32) u32
fn C.fopen(path &char, mode &char) voidptr
fn C.fwrite(ptr voidptr, size u64, count u64, fp voidptr) u64
fn C.fclose(fp voidptr) i32

// ------------------------------------------------------------------
// GL object handles + input state
// ------------------------------------------------------------------
__global (
	g_prog         u32
	g_vao          u32
	g_vbo          u32
	g_ui_prog      u32
	g_ui_vao       u32
	g_ui_vbo       u32
	g_white_tex    u32
	g_text_prog    u32
	g_text_vao     u32
	g_text_vbo     u32
	g_font_tex     u32
	u_ui_proj      i32 = -1
	u_text_proj    i32 = -1
	u_text_font    i32 = -1
	u_mvp          i32 = -1
	u_view         i32 = -1
	u_fog_color    i32 = -1
	u_fog_range    i32 = -1
	u_alpha_cutoff i32 = -1
	u_tex          i32 = -1
	u_time         i32 = -1
	u_tint         i32 = -1
	g_win_w        i32
	g_win_h        i32
	g_win          voidptr
	g_ctx          voidptr
	g_ks           [512]u8
	g_ks_prev      [512]u8
	g_ik           [256]i32
	g_ik_n         i32
	g_ib           [64]i32
	g_ib_n         i32
	g_mouse_dx     i32
	g_mouse_dy     i32
	g_mouse_x      i32
	g_mouse_y      i32
	g_mouse_btns   u32
	g_mouse_prev   u32
	g_close        i32
	g_resized      i32
)

// ---- GL enum constants (frozen ABI values from the GL/EGL specs) ----
const c_gl_array_buffer = u32(0x8892)
const c_gl_dynamic_draw = u32(0x88E8)
const c_gl_float = u32(0x1406)
const c_gl_triangles = u32(0x0004)
const c_gl_lines = u32(0x0001)
const c_gl_vertex_shader = u32(0x8B31)
const c_gl_fragment_shader = u32(0x8B30)
const c_gl_compile_status = u32(0x8B81)
const c_gl_link_status = u32(0x8B82)
const c_gl_depth_test = u32(0x0B71)
const c_gl_cull_face = u32(0x0B44)
const c_gl_back = u32(0x0405)
const c_gl_blend = u32(0x0BE2)
const c_gl_src_alpha = u32(0x0302)
const c_gl_one_minus_src_alpha = u32(0x0303)
const c_gl_texture_2d_array = u32(0x8C1A)
const c_gl_texture_2d = u32(0x0DE1)
const c_gl_texture0 = u32(0x84C0)
const c_gl_texture1 = u32(0x84C1)
const c_gl_rgba = u32(0x1908)
const c_gl_rgba8 = 0x8058
const c_gl_unsigned_byte = u32(0x1401)
const c_gl_nearest = 0x2600
const c_gl_texture_min_filter = u32(0x2801)
const c_gl_texture_mag_filter = u32(0x2800)
const c_gl_texture_wrap_s = u32(0x2802)
const c_gl_texture_wrap_t = u32(0x2803)
const c_gl_clamp_to_edge = 0x812F
const c_gl_pack_alignment = u32(0x0D05)
const c_gl_version = u32(0x1F02)
const c_gl_renderer = u32(0x1F01)

// ==================================================================
// Shader sources
// ==================================================================
fn vs_src() string {
	return [
		'#version 330 core',
		'layout(location=0) in vec3 a_pos;',
		'layout(location=1) in vec2 a_uv;',
		'layout(location=2) in float a_layer;',
		'layout(location=3) in float a_light;',
		'uniform mat4 u_mvp;',
		'uniform mat4 u_view;',
		'out vec2 v_uv;',
		'out float v_layer;',
		'out float v_light;',
		'out float v_dist;',
		'void main() {',
		'  v_uv = a_uv;',
		'  v_layer = a_layer;',
		'  v_light = a_light;',
		'  vec4 vp = u_view * vec4(a_pos, 1.0);',
		'  v_dist = length(vp.xyz);',
		'  gl_Position = u_mvp * vec4(a_pos, 1.0);',
		'}',
	].join('\n') + '\n'
}

fn fs_src() string {
	return [
		'#version 330 core',
		'in vec2 v_uv;',
		'in float v_layer;',
		'in float v_light;',
		'in float v_dist;',
		'uniform sampler2DArray u_tex;',
		'uniform vec3 u_fog_color;',
		'uniform vec2 u_fog_range;',
		'uniform float u_alpha_cutoff;',
		'uniform float u_time;',
		'uniform vec3 u_tint;',
		'out vec4 out_color;',
		'void main() {',
		'  vec2 uv = v_uv;',
		'  float layer = v_layer;',
		'  if (layer < 0.0) {',
		'    uv.x += sin(u_time * 1.3 + v_uv.y * 6.283) * 0.03;',
		'    uv.y += cos(u_time * 0.9 + v_uv.x * 6.283) * 0.03;',
		'  }',
		'  vec4 c = texture(u_tex, vec3(uv, abs(layer)));',
		'  if (c.a < u_alpha_cutoff) discard;',
		'  vec3 col = c.rgb * v_light * u_tint;',
		'  float f = smoothstep(u_fog_range.x, u_fog_range.y, v_dist);',
		'  col = mix(col, u_fog_color, f);',
		'  out_color = vec4(col, c.a);',
		'}',
	].join('\n') + '\n'
}

fn ui_vs_src() string {
	return [
		'#version 330 core',
		'layout(location=0) in vec2 a_pos;',
		'layout(location=1) in vec4 a_col;',
		'uniform mat4 u_proj;',
		'out vec4 v_col;',
		'void main() {',
		'  v_col = a_col;',
		'  gl_Position = u_proj * vec4(a_pos, 0.0, 1.0);',
		'}',
	].join('\n') + '\n'
}

fn ui_fs_src() string {
	return [
		'#version 330 core',
		'in vec4 v_col;',
		'out vec4 out_color;',
		'void main() { out_color = v_col; }',
	].join('\n') + '\n'
}

// Text draws sample a single 2D font atlas and take their alpha from it, so
// the same white glyph grid serves any colour.
fn text_vs_src() string {
	return [
		'#version 330 core',
		'layout(location=0) in vec2 a_pos;',
		'layout(location=1) in vec2 a_uv;',
		'layout(location=2) in vec4 a_col;',
		'uniform mat4 u_proj;',
		'out vec2 v_uv;',
		'out vec4 v_col;',
		'void main() {',
		'  v_uv = a_uv;',
		'  v_col = a_col;',
		'  gl_Position = u_proj * vec4(a_pos, 0.0, 1.0);',
		'}',
	].join('\n') + '\n'
}

fn text_fs_src() string {
	return [
		'#version 330 core',
		'in vec2 v_uv;',
		'in vec4 v_col;',
		'uniform sampler2D u_font;',
		'out vec4 out_color;',
		'void main() {',
		'  float a = texture(u_font, v_uv).a;',
		'  out_color = vec4(v_col.rgb, v_col.a * a);',
		'}',
	].join('\n') + '\n'
}

fn compile_shader(typ u32, src string, tag string) u32 {
	sh := unsafe { C.glCreateShader(typ) }
	cs := src.str
	unsafe { C.glShaderSource(sh, 1, &cs, voidptr(0)) }
	unsafe { C.glCompileShader(sh) }
	mut ok := i32(0)
	unsafe { C.glGetShaderiv(sh, c_gl_compile_status, &ok) }
	if ok == 0 {
		mut log := [2048]u8{}
		unsafe { C.glGetShaderInfoLog(sh, 2048, voidptr(0), &log[0]) }
		eprintln('[vshim] ${tag} shader failed: ${log.bytestr()}')
	}
	return sh
}

fn build_program() int {
	vs := compile_shader(c_gl_vertex_shader, vs_src(), 'vertex')
	fs := compile_shader(c_gl_fragment_shader, fs_src(), 'fragment')
	g_prog = unsafe { C.glCreateProgram() }
	unsafe {
		C.glAttachShader(g_prog, vs)
		C.glAttachShader(g_prog, fs)
		C.glLinkProgram(g_prog)
	}
	mut ok := i32(0)
	unsafe { C.glGetProgramiv(g_prog, c_gl_link_status, &ok) }
	if ok == 0 {
		mut log := [2048]u8{}
		unsafe { C.glGetProgramInfoLog(g_prog, 2048, voidptr(0), &log[0]) }
		eprintln('[vshim] link failed: ${log.bytestr()}')
		return 0
	}
	unsafe {
		C.glDeleteShader(vs)
		C.glDeleteShader(fs)
	}
	u_mvp = unsafe { C.glGetUniformLocation(g_prog, c'u_mvp') }
	u_view = unsafe { C.glGetUniformLocation(g_prog, c'u_view') }
	u_fog_color = unsafe { C.glGetUniformLocation(g_prog, c'u_fog_color') }
	u_fog_range = unsafe { C.glGetUniformLocation(g_prog, c'u_fog_range') }
	u_alpha_cutoff = unsafe { C.glGetUniformLocation(g_prog, c'u_alpha_cutoff') }
	u_tex = unsafe { C.glGetUniformLocation(g_prog, c'u_tex') }
	u_time = unsafe { C.glGetUniformLocation(g_prog, c'u_time') }
	u_tint = unsafe { C.glGetUniformLocation(g_prog, c'u_tint') }
	return 1
}

fn build_ui_program() int {
	vs := compile_shader(c_gl_vertex_shader, ui_vs_src(), 'ui-vertex')
	fs := compile_shader(c_gl_fragment_shader, ui_fs_src(), 'ui-fragment')
	g_ui_prog = unsafe { C.glCreateProgram() }
	unsafe {
		C.glAttachShader(g_ui_prog, vs)
		C.glAttachShader(g_ui_prog, fs)
		C.glLinkProgram(g_ui_prog)
	}
	mut ok := i32(0)
	unsafe { C.glGetProgramiv(g_ui_prog, c_gl_link_status, &ok) }
	if ok == 0 {
		mut log := [2048]u8{}
		unsafe { C.glGetProgramInfoLog(g_ui_prog, 2048, voidptr(0), &log[0]) }
		eprintln('[vshim] ui link failed: ${log.bytestr()}')
		return 0
	}
	unsafe {
		C.glDeleteShader(vs)
		C.glDeleteShader(fs)
	}
	u_ui_proj = unsafe { C.glGetUniformLocation(g_ui_prog, c'u_proj') }
	unsafe { C.glGenVertexArrays(1, &g_ui_vao) }
	unsafe { C.glBindVertexArray(g_ui_vao) }
	unsafe { C.glGenBuffers(1, &g_ui_vbo) }
	unsafe { C.glBindBuffer(c_gl_array_buffer, g_ui_vbo) }
	unsafe {
		C.glEnableVertexAttribArray(0)
		C.glVertexAttribPointer(0, 2, c_gl_float, u8(0), 24, voidptr(0))
		C.glEnableVertexAttribArray(1)
		C.glVertexAttribPointer(1, 4, c_gl_float, u8(0), 24, voidptr(8))
	}
	return 1
}

fn build_text_program() int {
	vs := compile_shader(c_gl_vertex_shader, text_vs_src(), 'text-vertex')
	fs := compile_shader(c_gl_fragment_shader, text_fs_src(), 'text-fragment')
	g_text_prog = unsafe { C.glCreateProgram() }
	unsafe {
		C.glAttachShader(g_text_prog, vs)
		C.glAttachShader(g_text_prog, fs)
		C.glLinkProgram(g_text_prog)
	}
	mut ok := i32(0)
	unsafe { C.glGetProgramiv(g_text_prog, c_gl_link_status, &ok) }
	if ok == 0 {
		mut log := [2048]u8{}
		unsafe { C.glGetProgramInfoLog(g_text_prog, 2048, voidptr(0), &log[0]) }
		eprintln('[vshim] text link failed: ${log.bytestr()}')
		return 0
	}
	unsafe {
		C.glDeleteShader(vs)
		C.glDeleteShader(fs)
	}
	u_text_proj = unsafe { C.glGetUniformLocation(g_text_prog, c'u_proj') }
	u_text_font = unsafe { C.glGetUniformLocation(g_text_prog, c'u_font') }
	unsafe { C.glGenVertexArrays(1, &g_text_vao) }
	unsafe { C.glBindVertexArray(g_text_vao) }
	unsafe { C.glGenBuffers(1, &g_text_vbo) }
	unsafe { C.glBindBuffer(c_gl_array_buffer, g_text_vbo) }
	unsafe {
		// pos(2) uv(2) colour(4) = 8 floats per vertex
		C.glEnableVertexAttribArray(0)
		C.glVertexAttribPointer(0, 2, c_gl_float, u8(0), 32, voidptr(0))
		C.glEnableVertexAttribArray(1)
		C.glVertexAttribPointer(1, 2, c_gl_float, u8(0), 32, voidptr(8))
		C.glEnableVertexAttribArray(2)
		C.glVertexAttribPointer(2, 4, c_gl_float, u8(0), 32, voidptr(16))
	}
	return 1
}

// ==================================================================
// Context creation
// ==================================================================

// Offscreen (headless): EGL surfaceless + pbuffer.
fn ctx_offscreen(w int, h int) int {
	// SDL's event queue must still be initialised or PollEvent does nothing.
	unsafe { C.SDL_InitSubSystem(u32(0x00004000)) } // SDL_INIT_EVENTS
	d := unsafe { C.eglGetDisplay(voidptr(0)) }
	if d == voidptr(0) {
		eprintln('[vshim] no EGL display')
		return 0
	}
	mut maj := i32(0)
	mut min := i32(0)
	if unsafe { C.eglInitialize(d, &maj, &min) } == 0 {
		eprintln('[vshim] eglInitialize failed')
		return 0
	}
	mut attrs := [i32(0x3033), i32(0x0001), i32(0x3040), i32(0x0008), i32(0x3038)]
	mut cfg := [u64(0)]
	mut n := i32(0)
	if unsafe { C.eglChooseConfig(d, &attrs[0], &cfg[0], 1, &n) } == 0 || n < 1 {
		eprintln('[vshim] eglChooseConfig failed')
		return 0
	}
	cv := unsafe { voidptr(cfg[0]) }
	mut pb := [i32(0x3057), i32(w), i32(0x3056), i32(h), i32(0x3038)]
	surf := unsafe { C.eglCreatePbufferSurface(d, cv, &pb[0]) }
	unsafe { C.eglBindAPI(u32(0x30A2)) } // EGL_OPENGL_API
	ctx := unsafe { C.eglCreateContext(d, cv, voidptr(0), voidptr(0)) }
	if ctx == voidptr(0) {
		eprintln('[vshim] eglCreateContext failed')
		return 0
	}
	unsafe { C.eglMakeCurrent(d, surf, surf, ctx) }
	g_win_w = i32(w)
	g_win_h = i32(h)
	return 1
}

// Windowed: SDL + OpenGL core 3.3.
fn ctx_window(title &char, w int, h int) int {
	if unsafe { C.SDL_Init(u32(0x00000020)) } != 0 { // SDL_INIT_VIDEO
		eprintln('[vshim] SDL_Init: ${unsafe { cstring_to_vstring(C.SDL_GetError()) }}')
		return 0
	}
	unsafe {
		C.SDL_GL_SetAttribute(0x113, 3) // major
		C.SDL_GL_SetAttribute(0x114, 3) // minor
		C.SDL_GL_SetAttribute(0x116, 1) // core profile
		C.SDL_GL_SetAttribute(0x111, 1) // doublebuffer
		C.SDL_GL_SetAttribute(0x110, 24) // depth size
	}
	g_win = unsafe {
		C.SDL_CreateWindow(title, 0x2FFF0000, 0x2FFF0000, w, h, u32(0x00000002) | u32(0x00000020))
	}
	if g_win == voidptr(0) {
		eprintln('[vshim] SDL_CreateWindow: ${unsafe { cstring_to_vstring(C.SDL_GetError()) }}')
		return 0
	}
	g_ctx = unsafe { C.SDL_GL_CreateContext(g_win) }
	if g_ctx == voidptr(0) {
		eprintln('[vshim] SDL_GL_CreateContext: ${unsafe { cstring_to_vstring(C.SDL_GetError()) }}')
		return 0
	}
	unsafe {
		C.SDL_GL_MakeCurrent(g_win, g_ctx)
		C.SDL_GL_SetSwapInterval(1)
		C.SDL_SetRelativeMouseMode(1)
	}
	g_win_w = i32(w)
	g_win_h = i32(h)
	return 1
}

pub fn init(mode int, title &char, w int, h int) int {
	ok := if mode == 0 { ctx_offscreen(w, h) } else { ctx_window(title, w, h) }
	if ok == 0 {
		return 0
	}
	if build_program() == 0 {
		return 0
	}
	if build_ui_program() == 0 {
		return 0
	}
	if build_text_program() == 0 {
		return 0
	}

	unsafe {
		C.glGenVertexArrays(1, &g_vao)
		C.glBindVertexArray(g_vao)
		C.glGenBuffers(1, &g_vbo)
		C.glBindBuffer(c_gl_array_buffer, g_vbo)
		C.glEnableVertexAttribArray(0)
		C.glVertexAttribPointer(0, 3, c_gl_float, u8(0), 28, voidptr(0))
		C.glEnableVertexAttribArray(1)
		C.glVertexAttribPointer(1, 2, c_gl_float, u8(0), 28, voidptr(12))
		C.glEnableVertexAttribArray(2)
		C.glVertexAttribPointer(2, 1, c_gl_float, u8(0), 28, voidptr(20))
		C.glEnableVertexAttribArray(3)
		C.glVertexAttribPointer(3, 1, c_gl_float, u8(0), 28, voidptr(24))
		C.glEnable(c_gl_depth_test)
		C.glEnable(c_gl_cull_face)
		C.glCullFace(c_gl_back)
		C.glClearColor(0.48, 0.66, 0.92, 1.0)
	}

	// 1x1 white fallback texture array so UI draws work before/at init.
	mut white := [4]u8{}
	white[0] = 255
	white[1] = 255
	white[2] = 255
	white[3] = 255
	unsafe {
		C.glGenTextures(1, &g_white_tex)
		C.glBindTexture(c_gl_texture_2d_array, g_white_tex)
		C.glTexImage3D(c_gl_texture_2d_array, 0, c_gl_rgba8, 1, 1, 1, 0, c_gl_rgba,
			c_gl_unsigned_byte, &white[0])
		C.glTexParameteri(c_gl_texture_2d_array, c_gl_texture_min_filter, c_gl_nearest)
		C.glTexParameteri(c_gl_texture_2d_array, c_gl_texture_mag_filter, c_gl_nearest)
	}
	return 1
}

// ==================================================================
// Texture array (procedural art generated in V)
// ==================================================================
pub fn make_texture(data &u8, size int, layers int) int {
	mut t := u32(0)
	unsafe {
		C.glGenTextures(1, &t)
		C.glBindTexture(c_gl_texture_2d_array, t)
		C.glTexImage3D(c_gl_texture_2d_array, 0, c_gl_rgba8, size, size, layers, 0,
			c_gl_rgba, c_gl_unsigned_byte, data)
		C.glTexParameteri(c_gl_texture_2d_array, c_gl_texture_min_filter, c_gl_nearest)
		C.glTexParameteri(c_gl_texture_2d_array, c_gl_texture_mag_filter, c_gl_nearest)
		C.glTexParameteri(c_gl_texture_2d_array, c_gl_texture_wrap_s, c_gl_clamp_to_edge)
		C.glTexParameteri(c_gl_texture_2d_array, c_gl_texture_wrap_t, c_gl_clamp_to_edge)
	}
	return int(t)
}

// A single 2D RGBA texture holding the procedural font atlas. The handle is
// kept in g_font_tex so the text program can bind it on texture unit 1.
pub fn make_font_texture(data &u8, w int, h int) int {
	mut t := u32(0)
	unsafe {
		C.glGenTextures(1, &t)
		C.glBindTexture(c_gl_texture_2d, t)
		C.glTexImage2D(c_gl_texture_2d, 0, c_gl_rgba8, w, h, 0, c_gl_rgba, c_gl_unsigned_byte, data)
		C.glTexParameteri(c_gl_texture_2d, c_gl_texture_min_filter, c_gl_nearest)
		C.glTexParameteri(c_gl_texture_2d, c_gl_texture_mag_filter, c_gl_nearest)
		C.glTexParameteri(c_gl_texture_2d, c_gl_texture_wrap_s, c_gl_clamp_to_edge)
		C.glTexParameteri(c_gl_texture_2d, c_gl_texture_wrap_t, c_gl_clamp_to_edge)
		C.glBindTexture(c_gl_texture_2d, u32(0))
	}
	g_font_tex = t
	return int(t)
}

pub fn use_texture(tex int) {
	unsafe {
		C.glActiveTexture(c_gl_texture0)
		C.glBindTexture(c_gl_texture_2d_array, if tex != 0 { u32(tex) } else { g_white_tex })
	}
}

// ==================================================================
// Mesh upload / draw
// ==================================================================
pub fn upload(verts &f32, count int) {
	unsafe {
		C.glBindVertexArray(g_vao)
		C.glBindBuffer(c_gl_array_buffer, g_vbo)
		C.glBufferData(c_gl_array_buffer, isize(count) * 28, verts, c_gl_dynamic_draw)
	}
}

pub fn set_uniforms(mvp &f32, view &f32, fr f32, fg f32, fb f32, fog_near f32, fog_far f32, alpha_cutoff f32, time f32, tr f32, tg f32, tb f32) {
	unsafe {
		C.glUseProgram(g_prog)
		C.glUniformMatrix4fv(u_mvp, 1, u8(0), mvp)
		C.glUniformMatrix4fv(u_view, 1, u8(0), view)
		C.glUniform3f(u_fog_color, fr, fg, fb)
		C.glUniform2f(u_fog_range, fog_near, fog_far)
		C.glUniform1f(u_alpha_cutoff, alpha_cutoff)
		C.glUniform1f(u_time, time)
		C.glUniform3f(u_tint, tr, tg, tb)
		C.glUniform1i(u_tex, 0)
	}
}

pub fn begin(clear int, r f32, g f32, b f32) {
	unsafe {
		C.glViewport(0, 0, g_win_w, g_win_h)
		C.glClearColor(r, g, b, 1.0)
		if clear != 0 {
			C.glClear(u32(0x4000) | u32(0x0100)) // COLOR | DEPTH
		}
	}
}

// Alpha blending, used for the translucent water pass.
pub fn blend(on bool) {
	unsafe {
		if on {
			C.glEnable(c_gl_blend)
			C.glBlendFunc(c_gl_src_alpha, c_gl_one_minus_src_alpha)
			C.glDepthMask(u8(0))
		} else {
			C.glDisable(c_gl_blend)
			C.glDepthMask(u8(1))
		}
	}
}

pub fn draw(count int) {
	if count > 0 {
		unsafe { C.glDrawArrays(c_gl_triangles, 0, count) }
	}
}

pub fn draw_lines(count int) {
	if count > 0 {
		unsafe { C.glDrawArrays(c_gl_lines, 0, count) }
	}
}

pub fn ui_begin() {
	unsafe {
		C.glDisable(c_gl_depth_test)
		C.glDisable(c_gl_cull_face)
	}
}

pub fn ui_end() {
	unsafe {
		C.glEnable(c_gl_depth_test)
		C.glEnable(c_gl_cull_face)
		C.glBindVertexArray(g_vao)
	}
}

// verts: 6 floats per vertex (x, y, r, g, b, a), already in draw order.
pub fn draw_colors(verts &f32, count int, proj &f32) {
	unsafe {
		C.glUseProgram(g_ui_prog)
		C.glUniformMatrix4fv(u_ui_proj, 1, u8(0), proj)
		C.glBindVertexArray(g_ui_vao)
		C.glBindBuffer(c_gl_array_buffer, g_ui_vbo)
		C.glBufferData(c_gl_array_buffer, isize(count) * 24, verts, c_gl_dynamic_draw)
		if count > 0 {
			C.glDrawArrays(c_gl_triangles, 0, count)
		}
	}
}

// verts: 8 floats per vertex (x, y, u, v, r, g, b, a), already in draw order.
pub fn text_begin(proj &f32) {
	unsafe {
		C.glUseProgram(g_text_prog)
		C.glUniformMatrix4fv(u_text_proj, 1, u8(0), proj)
		C.glActiveTexture(c_gl_texture1)
		C.glBindTexture(c_gl_texture_2d, g_font_tex)
		C.glActiveTexture(c_gl_texture0)
		C.glUniform1i(u_text_font, 1)
		C.glBindVertexArray(g_text_vao)
	}
}

pub fn draw_text(verts &f32, count int) {
	unsafe {
		C.glBindVertexArray(g_text_vao)
		C.glBindBuffer(c_gl_array_buffer, g_text_vbo)
		C.glBufferData(c_gl_array_buffer, isize(count) * 32, verts, c_gl_dynamic_draw)
		if count > 0 {
			C.glDrawArrays(c_gl_triangles, 0, count)
		}
		C.glBindVertexArray(g_vao)
	}
}

// ==================================================================
// PNG output (headless screenshots + atlas dump)
// ==================================================================
fn be32(mut buf []u8, off int, v u32) {
	buf[off] = u8(v >> 24)
	buf[off + 1] = u8((v >> 16) & 0xff)
	buf[off + 2] = u8((v >> 8) & 0xff)
	buf[off + 3] = u8(v & 0xff)
}

fn png_chunk(mut out []u8, ctype string, data []u8) {
	mut lenbuf := []u8{len: 4}
	be32(mut lenbuf, 0, u32(data.len))
	out << lenbuf
	mut tb := [4]u8{}
	tb[0] = ctype[0]
	tb[1] = ctype[1]
	tb[2] = ctype[2]
	tb[3] = ctype[3]
	out << tb[0]
	out << tb[1]
	out << tb[2]
	out << tb[3]
	out << data
	mut c := unsafe { C.crc32(0, &tb[0], 4) }
	if data.len > 0 {
		c = unsafe { C.crc32(c, &data[0], u32(data.len)) }
	}
	mut crcbuf := []u8{len: 4}
	be32(mut crcbuf, 0, u32(c))
	out << crcbuf
}

fn write_file(path string, data []u8) int {
	f := unsafe { C.fopen(path.str, c'wb') }
	if f == voidptr(0) {
		return 0
	}
	unsafe {
		C.fwrite(&data[0], 1, u64(data.len), f)
		C.fclose(f)
	}
	return 1
}

// flip: true when the source rows are bottom-up (glReadPixels), else false.
fn write_png(px []u8, w int, h int, flip bool, path string) int {
	row := w * 4 + 1
	mut raw := []u8{len: h * row}
	mut y := 0
	for y < h {
		raw[y * row] = 0 // filter: none
		src_y := if flip { h - 1 - y } else { y }
		mut x := 0
		for x < w * 4 {
			raw[y * row + 1 + x] = px[src_y * w * 4 + x]
			x++
		}
		y++
	}

	zbound := u64(C.compressBound(u64(raw.len)))
	mut z := []u8{len: int(zbound)}
	mut zl := zbound
	if unsafe { C.compress2(&z[0], &zl, &raw[0], u64(raw.len), 6) } != 0 {
		eprintln('[vshim] zlib compress failed')
		return 0
	}
	zs := z[..int(zl)]

	mut out := []u8{}
	out << u8(0x89)
	out << u8(0x50)
	out << u8(0x4e)
	out << u8(0x47)
	out << u8(0x0d)
	out << u8(0x0a)
	out << u8(0x1a)
	out << u8(0x0a)

	mut ihdr := []u8{len: 13}
	be32(mut ihdr, 0, u32(w))
	be32(mut ihdr, 4, u32(h))
	ihdr[8] = u8(8) // bit depth
	ihdr[9] = u8(6) // colour type RGBA
	ihdr[10] = u8(0)
	ihdr[11] = u8(0)
	ihdr[12] = u8(0)
	png_chunk(mut out, 'IHDR', ihdr)
	png_chunk(mut out, 'IDAT', zs)
	png_chunk(mut out, 'IEND', []u8{})
	return write_file(path, out)
}

pub fn screenshot(path string, w int, h int) int {
	mut px := []u8{len: w * h * 4}
	unsafe {
		C.glPixelStorei(c_gl_pack_alignment, 1)
		C.glReadPixels(0, 0, w, h, c_gl_rgba, c_gl_unsigned_byte, &px[0])
	}
	return write_png(px, w, h, true, path)
}

// Lay the texture array out as a grid and write it straight from memory.
// Bypasses GL entirely, so it works even when rendering is unavailable.
pub fn write_atlas(data []u8, size int, layers int, scale int, path string) int {
	sc := if scale < 1 { 1 } else { scale }
	cols := 6
	rows := (layers + cols - 1) / cols
	pad := 4
	cell := size * sc
	w := cols * (cell + pad) + pad
	h := rows * (cell + pad) + pad
	mut px := []u8{len: w * h * 4}
	mut i := 0
	for i < w * h {
		px[i * 4] = u8(24)
		px[i * 4 + 1] = u8(24)
		px[i * 4 + 2] = u8(28)
		px[i * 4 + 3] = u8(255)
		i++
	}
	mut layer := 0
	for layer < layers {
		cx := layer % cols
		cy := layer / cols
		ox := pad + cx * (cell + pad)
		oy := pad + cy * (cell + pad)
		mut y := 0
		for y < cell {
			mut x := 0
			for x < cell {
				sx := x / sc
				sy := y / sc
				sidx := (layer * size * size + sy * size + sx) * 4
				didx := ((oy + y) * w + (ox + x)) * 4
				px[didx] = data[sidx]
				px[didx + 1] = data[sidx + 1]
				px[didx + 2] = data[sidx + 2]
				px[didx + 3] = u8(255)
				x++
			}
			y++
		}
		layer++
	}
	return write_png(px, w, h, false, path)
}

// ==================================================================
// Input + present
// ==================================================================

// pump() samples the real device state once per frame (windowed mode) and
// then applies any synthetic events queued by inject_key/inject_button. The
// previous-frame snapshot is taken first, so key_pressed() is a pure query
// that sees the same edge no matter how many keys are checked.
pub fn pump() {
	mut i := 0
	for i < 512 {
		g_ks_prev[i] = g_ks[i]
		i++
	}
	g_mouse_prev = g_mouse_btns

	if g_win != voidptr(0) {
		unsafe { C.SDL_PumpEvents() }
		ks := unsafe { C.SDL_GetKeyboardState(voidptr(0)) }
		if ks != unsafe { nil } {
			mut j := 0
			for j < 512 {
				g_ks[j] = unsafe { ks[j] }
				j++
			}
		}
		mut dx := i32(0)
		mut dy := i32(0)
		mask := unsafe { C.SDL_GetRelativeMouseState(&dx, &dy) }
		g_mouse_dx += dx
		g_mouse_dy += dy
		// SDL button bit -> our bit: left=0->1, middle=1->2, right=2->3.
		g_mouse_btns = mask << 1
		// Absolute cursor position, for the pause menu. SDL's origin is
		// top-left, which matches the HUD's ortho projection.
		mut mx := i32(0)
		mut my := i32(0)
		unsafe { C.SDL_GetMouseState(&mx, &my) }
		g_mouse_x = mx
		g_mouse_y = my
	}

	// Synthetic keys, applied in order so a down+up pair still lands cleanly.
	mut k := 0
	for k < g_ik_n {
		v := g_ik[k]
		sc := int(v / 2)
		if sc >= 0 && sc < 512 {
			g_ks[sc] = if v % 2 == 1 { u8(1) } else { u8(0) }
		}
		k++
	}
	g_ik_n = 0

	mut b := 0
	for b < g_ib_n {
		v := g_ib[b]
		btn := int(v / 2)
		if btn >= 0 && btn < 64 {
			bit := u32(1) << u32(btn)
			if v % 2 == 1 {
				g_mouse_btns |= bit
			} else {
				g_mouse_btns &= ~bit
			}
		}
		b++
	}
	g_ib_n = 0

	// Only two event kinds need parsing: quit and window resize/close.
	// (SDL_Event is a 56-byte union; we read the raw bytes we need.)
	mut ev := [64]u8{}
	mut more := true
	for more {
		got := unsafe { C.SDL_PollEvent(&ev[0]) }
		if got == 0 {
			more = false
		} else {
			t := u32(ev[0]) | (u32(ev[1]) << 8) | (u32(ev[2]) << 16) | (u32(ev[3]) << 24)
			if t == u32(0x100) {
				g_close = 1 // SDL_QUIT
			} else if t == u32(0x200) {
				we := ev[12]
				if we == u8(14) {
					g_close = 1 // SDL_WINDOWEVENT_CLOSE
				} else if we == u8(5) || we == u8(6) {
					// RESIZED / SIZE_CHANGED
					g_resized = 1
					g_win_w = i32(int(ev[16]) | (int(ev[17]) << 8) | (int(ev[18]) << 16) | (int(ev[19]) << 24))
					g_win_h = i32(int(ev[20]) | (int(ev[21]) << 8) | (int(ev[22]) << 16) | (int(ev[23]) << 24))
				}
			}
		}
	}
}

pub fn inject_key(sc int, down bool) int {
	d := if down { 1 } else { 0 }
	if g_ik_n < 256 {
		g_ik[g_ik_n] = i32(sc * 2 + d)
		g_ik_n++
	}
	return 1
}

pub fn inject_button(button int, down bool) int {
	d := if down { 1 } else { 0 }
	if g_ib_n < 64 {
		g_ib[g_ib_n] = i32(button * 2 + d)
		g_ib_n++
	}
	return 1
}

pub fn scancode(name string) int {
	return unsafe { C.SDL_GetScancodeFromName(name.str) }
}

pub fn key_down(sc int) bool {
	if sc < 0 || sc >= 512 {
		return false
	}
	return g_ks[sc] != 0
}

pub fn key_pressed(sc int) bool {
	if sc < 0 || sc >= 512 {
		return false
	}
	return g_ks[sc] != 0 && g_ks_prev[sc] == 0
}

// Bitmask over scancodes 0..63, for debug logging only.
pub fn keys() u64 {
	mut m := u64(0)
	mut i := 0
	for i < 64 {
		if g_ks[i] != 0 {
			m |= u64(1) << u64(i)
		}
		i++
	}
	return m
}

pub fn buttons() u64 {
	return u64(g_mouse_btns)
}

// Rising edge of a mouse button this frame. The index is our own shifted
// numbering - left=1, middle=2, right=3 - not SDL's, because pump() shifts
// SDL's mask left by one. Passing 0 would test a bit nothing ever sets.
pub fn button_pressed(i int) bool {
	if i < 0 || i >= 32 {
		return false
	}
	bit := u32(1) << u32(i)
	return (g_mouse_btns & bit) != 0 && (g_mouse_prev & bit) == 0
}

pub fn mouse_x() int {
	return int(g_mouse_x)
}

pub fn mouse_y() int {
	return int(g_mouse_y)
}

// Place the cursor at an absolute window position. pump() overwrites this
// from the real device every frame, so the self-test uses it only headless,
// where there is no device to read.
pub fn set_mouse_at(x int, y int) {
	g_mouse_x = i32(x)
	g_mouse_y = i32(y)
}

// Free the cursor for the pause menu, and re-grab it for mouse-look.
pub fn set_mouse_relative(on bool) {
	if g_win != voidptr(0) {
		unsafe { C.SDL_SetRelativeMouseMode(if on { 1 } else { 0 }) }
	}
}

pub fn request_close() {
	g_close = 1
}

pub fn mouse_dx() int {
	v := g_mouse_dx
	g_mouse_dx = 0
	return v
}

pub fn mouse_dy() int {
	v := g_mouse_dy
	g_mouse_dy = 0
	return v
}

pub fn should_close() bool {
	return g_close != 0
}

pub fn resized() bool {
	v := g_resized
	g_resized = 0
	return v != 0
}

pub fn win_w() int {
	return int(g_win_w)
}

pub fn win_h() int {
	return int(g_win_h)
}

pub fn present() {
	if g_win != voidptr(0) {
		unsafe { C.SDL_GL_SwapWindow(g_win) }
	}
}

pub fn gl_version() string {
	s := unsafe { C.glGetString(c_gl_version) }
	if s == unsafe { nil } {
		return 'unknown'
	}
	return unsafe { cstring_to_vstring(s) }
}

pub fn gl_renderer() string {
	s := unsafe { C.glGetString(c_gl_renderer) }
	if s == unsafe { nil } {
		return 'unknown'
	}
	return unsafe { cstring_to_vstring(s) }
}
