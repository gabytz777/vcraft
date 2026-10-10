module ffi

#include "shim.h"

// Declarations for the C platform shim (csrc/shim.c).
// V requires `fn C.name(...)` declarations to call C symbols; the C side is
// compiled separately (see build.sh) and linked as a static library.

fn C.mc_init(mode int, title &char, w int, h int) int
fn C.mc_make_texture(data &u8, size int, layers int) int
fn C.mc_use_texture(tex int)
fn C.mc_upload(verts &f32, count int)
fn C.mc_set_uniforms(mvp &f32, view &f32, fr f32, fg f32, fb f32, fog_near f32, fog_far f32, alpha_cutoff f32, time f32, tr f32, tg f32, tb f32)
fn C.mc_begin(clear int, r f32, g f32, b f32)
fn C.mc_blend(on int)
fn C.mc_draw(count int)
fn C.mc_draw_lines(count int)
fn C.mc_ui_begin()
fn C.mc_ui_end()
fn C.mc_draw_colors(verts &f32, count int, proj &f32)
fn C.mc_screenshot(path &u8, w int, h int) int
fn C.mc_write_atlas(data &u8, size int, layers int, scale int, path &u8) int
fn C.mc_keys() u64
fn C.mc_buttons() u64
fn C.mc_mouse_dx() int
fn C.mc_mouse_dy() int
fn C.mc_should_close() int
fn C.mc_resized() int
fn C.mc_win_w() int
fn C.mc_win_h() int
fn C.mc_pump()
fn C.mc_key_pressed(sc int) int
fn C.mc_key_down(sc int) int
fn C.mc_scancode(name &u8) int
fn C.mc_inject_key(sc int, down int) int
fn C.mc_inject_button(button int, down int) int
fn C.mc_present() int
fn C.mc_gl_version(buf &u8, len int)
fn C.mc_gl_renderer(buf &u8, len int)

pub fn init(mode int, title &char, w int, h int) int {
	return unsafe { C.mc_init(mode, title, w, h) }
}

pub fn make_texture(data &u8, size int, layers int) int {
	return unsafe { C.mc_make_texture(data, size, layers) }
}

pub fn use_texture(tex int) {
	unsafe { C.mc_use_texture(tex) }
}

pub fn upload(verts &f32, count int) {
	unsafe { C.mc_upload(verts, count) }
}

pub fn set_uniforms(mvp &f32, view &f32, fr f32, fg f32, fb f32, fog_near f32, fog_far f32, alpha_cutoff f32, time f32, tr f32, tg f32, tb f32) {
	unsafe {
		C.mc_set_uniforms(mvp, view, fr, fg, fb, fog_near, fog_far, alpha_cutoff, time,
			tr, tg, tb)
	}
}

pub fn begin(clear int, r f32, g f32, b f32) {
	unsafe { C.mc_begin(clear, r, g, b) }
}

pub fn write_atlas(data []u8, size int, layers int, scale int, path string) int {
	unsafe {
		return C.mc_write_atlas(&data[0], size, layers, scale, &path[0])
	}
}

pub fn blend(on bool) {
	unsafe {
		C.mc_blend(int(on))
	}
}

pub fn draw_lines(count int) {
	unsafe {
		C.mc_draw_lines(count)
	}
}

pub fn ui_begin() {
	unsafe { C.mc_ui_begin() }
}

pub fn ui_end() {
	unsafe { C.mc_ui_end() }
}

pub fn draw_colors(verts &f32, count int, proj &f32) {
	unsafe { C.mc_draw_colors(verts, count, proj) }
}

pub fn draw(count int) {
	unsafe { C.mc_draw(count) }
}

pub fn screenshot(path string, w int, h int) int {
	return unsafe {
		C.mc_screenshot(&path[0], w, h)
	}
}

pub fn keys() u64 {
	return unsafe { C.mc_keys() }
}

pub fn buttons() u64 {
	return unsafe { C.mc_buttons() }
}

pub fn mouse_dx() int {
	return unsafe { C.mc_mouse_dx() }
}

pub fn mouse_dy() int {
	return unsafe { C.mc_mouse_dy() }
}

pub fn should_close() bool {
	return unsafe { C.mc_should_close() != 0 }
}

pub fn resized() bool {
	return unsafe { C.mc_resized() != 0 }
}

pub fn win_w() int {
	return unsafe { C.mc_win_w() }
}

pub fn win_h() int {
	return unsafe { C.mc_win_h() }
}

pub fn pump() {
	unsafe { C.mc_pump() }
}

pub fn inject_key(sc int, down bool) int {
	unsafe {
		return C.mc_inject_key(sc, if down { 1 } else { 0 })
	}
}

pub fn inject_button(button int, down bool) int {
	unsafe {
		return C.mc_inject_button(button, if down { 1 } else { 0 })
	}
}

pub fn scancode(name string) int {
	unsafe {
		return C.mc_scancode(&name[0])
	}
}

pub fn key_down(sc int) bool {
	unsafe {
		return C.mc_key_down(sc) != 0
	}
}

pub fn key_pressed(sc int) bool {
	return unsafe { C.mc_key_pressed(sc) != 0 }
}

pub fn present() {
	unsafe { C.mc_present() }
}

pub fn gl_version() string {
	mut buf := [128]u8{}
	unsafe {
		C.mc_gl_version(&buf[0], 128)
	}
	return buf.bytestr()
}

pub fn gl_renderer() string {
	mut buf := [128]u8{}
	unsafe {
		C.mc_gl_renderer(&buf[0], 128)
	}
	return buf.bytestr()
}
