module main

import os
import time
import math
import ffi
import vm
import blocks
import texture
import font
import audio
import world
import mesher
import raycast
import player as player_mod

const window_w = 1280
const window_h = 720
const near_plane = 0.05
const far_plane = 400.0
const world_seed = 1337

// Cheapest render distance the settings menu allows, and the bounds for the
// other tunables. They are read back from disk on startup.
//
// The upper bound is deliberately conservative: every meshed chunk is drawn
// in one batch, so the vertex buffer grows with the square of the radius.
// Anything past 8 wedges the GL driver on a weak iGPU (measured on the
// Radeon 610M development machine, where 10 aborts Mesa mid-frame).
const min_rd = 2
const max_rd = 8
const min_fov = f32(40.0)
const max_fov = f32(110.0)

// Pause menu entries.
const menu_main_items = 3
const menu_settings_items = 6

enum MenuScreen {
	none
	main
	settings
}

// SDL scancodes (SDL_SCANCODE_*). Verified against SDL_GetScancodeFromName
// by the self-test: getting one of these wrong binds a key to an unrelated
// action, which reads as "the controls are broken".
const sc_w = 26
const sc_a = 4
const sc_s = 22
const sc_d = 7
const sc_space = 44
const sc_shift_l = 225
const sc_ctrl_l = 224
const sc_f = 9
const sc_1 = 30
const sc_lbracket = 47
const sc_rbracket = 48
const sc_escape = 41
const sc_enter = 40
const sc_up = 82
const sc_down = 81
const sc_left = 80
const sc_right = 79

struct ChunkMesh {
mut:
	cx    i32
	cz    i32
	verts []f32
	water []f32
}

struct Game {
mut:
	w        world.World
	meshes   map[i64]ChunkMesh
	p        player_mod.Player
	selected int
	time     f64
	fps      f64
	last_fps f64
	frame    int
	// camera
	pos  vm.Vec3
	dir  vm.Vec3
	view vm.Mat4
	proj vm.Mat4
	vp   vm.Mat4
	// interaction
	target raycast.Hit
	logs   []string
	// mining: hold the button to fill a per-block timer, rather than
	// destroying whatever is in front of the player every frame
	break_active   bool
	break_x        i32
	break_y        i32
	break_z        i32
	break_progress f32
	break_frac     f32
	place_cd       f32
	gen_count      int
	dbg_fw         f32
	dbg_st         f32
	// scratch buffers rebuilt each frame
	quad_buffer  []f32
	water_buffer []f32
	// settings, persisted to ~/.config/vcraft/settings.cfg
	rd     int = 6
	fov    f32 = 70.0
	sens   f32 = 1.0
	volume f32 = 0.7
	invert bool
	// pause menu
	paused      bool
	menu_screen MenuScreen
	menu_sel    int
	// audio bookkeeping
	step_acc     f32
	was_in_water bool
	was_ground   bool
}

fn key_down(sc int) bool {
	return ffi.key_down(sc)
}

fn key_pressed(sc int) bool {
	return ffi.key_pressed(sc)
}

fn mouse_button(i int) bool {
	return (ffi.buttons() & (u64(1) << u64(i))) != 0
}

// Generate + mesh the chunks around the player.
fn (mut g Game) update_chunks() {
	pcx := i32(math.floor(f64(g.p.pos[0]))) >> 4
	pcz := i32(math.floor(f64(g.p.pos[2]))) >> 4

	rd := g.rd + 1
	span := rd * 2 + 1
	for zi in 0 .. span {
		for xi in 0 .. span {
			dx := xi - rd
			dz := zi - rd
			// circular mask keeps the far corners out
			if dx * dx + dz * dz <= rd * rd {
				if g.w.ensure_chunk(pcx + dx, pcz + dz) {
					g.gen_count++
				}
			}
		}
	}
	dbg := os.getenv('VDEBUG')
	if dbg != '' {
		println('dbg: rd=${rd} gen=${g.gen_count} chunks=${g.w.chunks.len}')
	}
}

fn (mut g Game) update_meshes() {
	pcx := i32(math.floor(f64(g.p.pos[0]))) >> 4
	pcz := i32(math.floor(f64(g.p.pos[2]))) >> 4

	mspan := g.rd * 2 + 1
	rd2 := g.rd * g.rd
	for zi in 0 .. mspan {
		for xi in 0 .. mspan {
			dx := xi - g.rd
			dz := zi - g.rd
			if dx * dx + dz * dz <= rd2 {
				cx := pcx + dx
				cz := pcz + dz
				k := world.chunk_key(cx, cz)
				if g.w.has_chunk(cx, cz) {
					ch := g.w.get_chunk(cx, cz) or { continue }
					mut needs := ch.dirty == 1
					if k !in g.meshes {
						needs = true
					}
					if needs {
						g.meshes[k] = ChunkMesh{
							cx: cx
							cz: cz
							verts: mesher.build_mesh(&g.w, ch)
							water: mesher.build_water_mesh(&g.w, ch)
						}
						g.w.clear_dirty(cx, cz)
					}
				}
			}
		}
	}

	// drop chunks that fell outside the view radius
	limit := (g.rd + 3) * (g.rd + 3)
	mut drop := []i64{}
	for k, cm in g.meshes {
		d := (cm.cx - pcx) * (cm.cx - pcx) + (cm.cz - pcz) * (cm.cz - pcz)
		if d > limit {
			drop << k
		}
	}
	for k in drop {
		g.meshes.delete(k)
	}
}

fn (mut g Game) handle_input(dt f32) {
	ffi.pump()

	// Esc toggles the pause menu; while paused the world is frozen and the
	// menu owns all input.
	if key_pressed(sc_escape) {
		g.toggle_pause()
		return
	}
	if g.paused {
		g.update_menu(dt)
		return
	}

	sens := f32(0.0022) * g.sens
	// yaw decreases with mouse-right so the view turns the way the mouse
	// goes: screen right is forward x up, which puts +X on the left.
	g.p.yaw -= f32(ffi.mouse_dx()) * sens
	mut pitch_delta := f32(ffi.mouse_dy()) * sens
	if g.invert {
		pitch_delta = -pitch_delta
	}
	g.p.pitch -= pitch_delta
	max_pitch := f32(math.pi / 2.0 - 0.001)
	if g.p.pitch > max_pitch {
		g.p.pitch = max_pitch
	}
	if g.p.pitch < -max_pitch {
		g.p.pitch = -max_pitch
	}

	ws := hotbar_window(g.selected)
	for i in 0 .. 9 {
		if key_pressed(sc_1 + i) {
			sel := ws + i
			if sel < blocks.hotbar.len {
				g.selected = sel
			}
		}
	}
	if key_pressed(sc_lbracket) {
		g.selected = (g.selected + blocks.hotbar.len - 1) % blocks.hotbar.len
	}
	if key_pressed(sc_rbracket) {
		g.selected = (g.selected + 1) % blocks.hotbar.len
	}
	if key_pressed(sc_f) {
		g.p.flying = !g.p.flying
		g.p.vel[1] = 0.0
	}

	mut inp := player_mod.Input{}
	if key_down(sc_w) {
		inp.forward += 1.0
	}
	if key_down(sc_s) {
		inp.forward -= 1.0
	}
	if key_down(sc_d) {
		inp.strafe += 1.0
	}
	if key_down(sc_a) {
		inp.strafe -= 1.0
	}
	if key_down(sc_space) {
		inp.jump = true
	}
	if key_down(sc_shift_l) {
		inp.sneak = true
	}
	if key_down(sc_ctrl_l) {
		inp.sprint = true
	}

	if os.getenv('VKEYLOG') != '' {
		fw := inp.forward
		st := inp.strafe
		if fw != g.dbg_fw || st != g.dbg_st {
			println('input   : fwd=${fw:.0f} strafe=${st:.0f} yaw=${g.p.yaw:.3} keys=0x${ffi.keys():x}')
			g.dbg_fw = fw
			g.dbg_st = st
		}
	}

	// Snapshot a little state so the audio cues below can tell what changed.
	prev_x := g.p.pos[0]
	prev_z := g.p.pos[2]
	vy_before := g.p.vel[1]
	ground_before := g.p.on_ground

	g.p.update(&g.w, inp, dt)

	// Footsteps, splashes, jumps and landings, all driven by movement.
	dxm := g.p.pos[0] - prev_x
	dzm := g.p.pos[2] - prev_z
	moved := f32(math.sqrt(f64(dxm * dxm + dzm * dzm)))
	if g.p.on_ground && !g.p.in_water {
		g.step_acc += moved
		if g.step_acc > 1.7 {
			g.step_acc = 0.0
			audio.play_step()
		}
	} else {
		g.step_acc = 0.0
	}
	if g.p.in_water && !g.was_in_water {
		audio.play_splash()
	}
	if ground_before && !g.p.on_ground && g.p.vel[1] > 0.0 {
		audio.play_jump()
	}
	if !ground_before && g.p.on_ground && vy_before < f32(-7.0) {
		audio.play_land()
	}
	g.was_in_water = g.p.in_water
	g.was_ground = g.p.on_ground

	hit := raycast.cast(&g.w, g.p.eye(), g.p.look_dir(), 6.0)
	g.target = hit

	// Mining: holding the button fills a timer; the block only breaks when
	// the timer reaches its hardness. Switching target starts over, so
	// holding the button no longer eats a block every frame.
	h := if hit.found { blocks.hardness(hit.block_id) } else { f32(-1.0) }
	mineable := mouse_button(1) && hit.found && h >= 0.0
	same := g.break_active && hit.found && g.break_x == hit.block[0] && g.break_y == hit.block[1] && g.break_z == hit.block[2]
	if mineable && same {
		g.break_progress += dt
	} else if mineable {
		g.break_active = true
		g.break_x = hit.block[0]
		g.break_y = hit.block[1]
		g.break_z = hit.block[2]
		g.break_progress = dt
	} else {
		g.break_active = false
		g.break_progress = 0.0
	}
	g.break_frac = 0.0
	if g.break_active {
		g.break_frac = g.break_progress / h
		if g.break_frac > 1.0 {
			g.break_frac = 1.0
		}
	}
	if g.break_active && g.break_progress >= h {
		name := blocks.def(hit.block_id).name
		g.w.set_block(g.break_x, g.break_y, g.break_z, blocks.air)
		g.logs << 'broke ${name}'
		audio.play_break()
		g.update_meshes()
		g.break_active = false
		g.break_progress = 0.0
		g.break_frac = 0.0
	}

	// Placing fires once per click, on a short cooldown, instead of every
	// frame the button is held.
	g.place_cd -= dt
	if g.place_cd < 0.0 {
		g.place_cd = 0.0
	}
	if mouse_button(3) && hit.found && g.place_cd <= 0.0 {
		t := hit.previous
		cur := g.w.get_block(t[0], t[1], t[2])
		if cur == blocks.air || cur == blocks.water {
			b := blocks.hotbar[g.selected]
			// never entomb the player
			px := i32(math.floor(f64(g.p.pos[0])))
			pz := i32(math.floor(f64(g.p.pos[2])))
			py := i32(math.floor(f64(g.p.pos[1])))
			feet_y := py
			head_y := i32(math.floor(f64(g.p.pos[1] + 1.8)))
			overlap := t[0] == px && t[2] == pz && t[1] >= feet_y && t[1] <= head_y
			if !overlap {
				g.w.set_block(t[0], t[1], t[2], b)
				g.logs << 'placed ${blocks.def(b).name}'
				audio.play_place()
				g.update_meshes()
				g.place_cd = 0.25
			}
		}
	}
}

fn (mut g Game) update_camera(aspect f32) {
	eye := g.p.eye()
	dirs := g.p.look_dir()
	g.pos = vm.Vec3{x: eye[0], y: eye[1], z: eye[2]}
	g.dir = vm.Vec3{x: dirs[0], y: dirs[1], z: dirs[2]}
	target := g.pos.add(g.dir.scale(f32(10.0)))
	fov := g.fov * f32(math.pi) / f32(180.0)
	g.proj = vm.mat4_perspective(fov, aspect, near_plane, far_plane)
	g.view = vm.mat4_look_at(g.pos, target, vm.Vec3{x: 0.0, y: 1.0, z: 0.0})
	g.vp = vm.mat4_mul(g.proj, g.view)
}

// Day/night cycle: 0.0 -> noon, 0.5 -> midnight
fn sky_color(t f64) [3]f32 {
	day_len := 600.0
	phase := math.fmod(t / day_len, 1.0)
	mut daylight := f32(math.cos(f64(phase) * 2.0 * math.pi))
	if daylight < 0.0 {
		daylight = 0.0
	}
	dl := daylight * daylight
	return [0.46 * dl + 0.015, 0.66 * dl + 0.02, 0.96 * dl + 0.04]
}

// Flatten every meshed chunk into two scratch buffers for the frame.
fn (mut g Game) gather_geometry() {
	mut opaque := []f32{}
	mut water := []f32{}
	for _, cm in g.meshes {
		if cm.verts.len > 0 {
			opaque << cm.verts
		}
		if cm.water.len > 0 {
			water << cm.water
		}
	}
	g.quad_buffer = opaque
	g.water_buffer = water
}

// First visible hotbar slot. The hotbar holds more blocks than the nine
// visible slots, so the window follows the selection (brackets scroll it).
fn hotbar_window(selected int) int {
	mut ws := selected - 4
	if ws < 0 {
		ws = 0
	}
	max_ws := blocks.hotbar.len - 9
	if ws > max_ws {
		ws = max_ws
	}
	return ws
}

// One flat-coloured quad, 6 floats per vertex (x, y, r, g, b, a).
fn ui_quad(mut buf []f32, x f32, y f32, w f32, h f32, c [4]f32) {
	buf << x
	buf << y
	buf << c[0]
	buf << c[1]
	buf << c[2]
	buf << c[3]
	buf << x + w
	buf << y
	buf << c[0]
	buf << c[1]
	buf << c[2]
	buf << c[3]
	buf << x + w
	buf << y + h
	buf << c[0]
	buf << c[1]
	buf << c[2]
	buf << c[3]
	buf << x
	buf << y
	buf << c[0]
	buf << c[1]
	buf << c[2]
	buf << c[3]
	buf << x + w
	buf << y + h
	buf << c[0]
	buf << c[1]
	buf << c[2]
	buf << c[3]
	buf << x
	buf << y + h
	buf << c[0]
	buf << c[1]
	buf << c[2]
	buf << c[3]
}

// One textured quad for a hotbar icon, 7 floats per vertex (the world
// shader's layout) with full brightness.
fn icon_quad(mut buf []f32, x f32, y f32, w f32, h f32, layer f32) {
	// exactly 7 floats per vertex: x, y, z, u, v, layer, light
	buf << x
	buf << y
	buf << f32(0.0)
	buf << f32(0.0)
	buf << f32(0.0)
	buf << layer
	buf << f32(1.0)
	buf << x + w
	buf << y
	buf << f32(0.0)
	buf << f32(1.0)
	buf << f32(0.0)
	buf << layer
	buf << f32(1.0)
	buf << x + w
	buf << y + h
	buf << f32(0.0)
	buf << f32(1.0)
	buf << f32(1.0)
	buf << layer
	buf << f32(1.0)
	buf << x
	buf << y
	buf << f32(0.0)
	buf << f32(0.0)
	buf << f32(0.0)
	buf << layer
	buf << f32(1.0)
	buf << x + w
	buf << y + h
	buf << f32(0.0)
	buf << f32(1.0)
	buf << f32(1.0)
	buf << layer
	buf << f32(1.0)
	buf << x
	buf << y + h
	buf << f32(0.0)
	buf << f32(0.0)
	buf << f32(1.0)
	buf << layer
	buf << f32(1.0)
}

// Crosshair + the nine-slot hotbar with the real block textures.
fn (mut g Game) render_hud() {
	w := f32(ffi.win_w())
	h := f32(ffi.win_h())
	if w < 1.0 || h < 1.0 {
		return
	}
	ortho := vm.mat4_ortho(f32(0.0), w, h, f32(0.0), f32(-1.0), f32(1.0))
	ident := vm.mat4_identity()

	slot := f32(46.0)
	gap := f32(4.0)
	total := f32(9.0) * slot + f32(8.0) * gap
	x0 := (w - total) / f32(2.0)
	y0 := h - slot - f32(14.0)
	ws := hotbar_window(g.selected)

	mut ui := []f32{}
	mut i := 0
	for i < 9 {
		sx := x0 + f32(i) * (slot + gap)
		if ws + i == g.selected {
			ui_quad(mut ui, sx - f32(2.0), y0 - f32(2.0), slot + f32(4.0),
				slot + f32(4.0), [f32(0.98), f32(0.98), f32(0.94), f32(0.98)])
		} else {
			ui_quad(mut ui, sx, y0, slot, slot,
				[f32(0.05), f32(0.05), f32(0.07), f32(0.62)])
		}
		i++
	}
	// crosshair
	cx := w / f32(2.0)
	cy := h / f32(2.0)
	ui_quad(mut ui, cx - f32(7.0), cy - f32(1.0), f32(14.0), f32(2.0),
		[f32(1.0), f32(1.0), f32(1.0), f32(0.72)])
	ui_quad(mut ui, cx - f32(1.0), cy - f32(7.0), f32(2.0), f32(14.0),
		[f32(1.0), f32(1.0), f32(1.0), f32(0.72)])

	// real block textures in the slots
	mut ic := []f32{}
	mut j := 0
	for j < 9 {
		idx := ws + j
		if idx < blocks.hotbar.len {
			b := blocks.hotbar[idx]
			layer := f32(blocks.def(b).sides[4])
			sx := x0 + f32(j) * (slot + gap) + f32(5.0)
			sy := y0 + f32(5.0)
			sz := slot - f32(10.0)
			icon_quad(mut ic, sx, sy, sz, sz, layer)
		}
		j++
	}

	ffi.ui_begin()
	ffi.blend(true)
	if os.getenv('VHUD') != '' {
		mut hb := ''
		mut k := 0
		for k < blocks.hotbar.len {
			hb += ' ${blocks.hotbar[k]}'
			k++
		}
		println('hud: ui=${ui.len / 6} ic=${ic.len / 7} sel=${g.selected} ws=${ws} hotbar=${blocks.hotbar.len} vals=${hb}')
	}
	if ui.len > 0 {
		unsafe {
			ffi.draw_colors(&ui[0], ui.len / 6, ortho.ptr())
		}
	}
	ffi.set_uniforms(ortho.ptr(), ident.ptr(), f32(0.0), f32(0.0), f32(0.0),
		f32(1000000.0), f32(1000001.0), f32(0.5), f32(0.0),
		f32(1.0), f32(1.0), f32(1.0))
	if ic.len > 0 {
		unsafe {
			ffi.upload(&ic[0], ic.len / 7)
			ffi.draw(ic.len / 7)
		}
	}
	ffi.blend(false)
	ffi.ui_end()
}

// ==================================================================
// Pause menu + settings
// ==================================================================

// Menu labels. The settings screen shows the live value next to each name.
fn (g &Game) menu_items() []string {
	if g.menu_screen == .settings {
		inv := if g.invert { 'ON' } else { 'OFF' }
		vol := int(g.volume * 100.0 + 0.5)
		fv := int(g.fov + 0.5)
		return [
			'RENDER DISTANCE  ${g.rd}',
			'FIELD OF VIEW  ${fv}',
			'SENSITIVITY  ${g.sens:.1}',
			'VOLUME  ${vol}%',
			'INVERT MOUSE  ${inv}',
			'BACK',
		]
	}
	return ['RESUME', 'SETTINGS', 'QUIT']
}

// Rect (x, y, w, h) of menu row `i`, shared by rendering and hit-testing.
fn menu_item_rect(w f32, h f32, screen MenuScreen, i int) [4]f32 {
	pw := f32(560.0)
	ph := if screen == .settings { f32(380.0) } else { f32(280.0) }
	py := (h - ph) / 2.0
	iw := pw - f32(96.0)
	ix := (w - iw) / 2.0
	iy := py + f32(78.0) + f32(i) * f32(44.0)
	return [ix, iy, iw, f32(34.0)]
}

// ---- bitmap text ------------------------------------------------- //

fn tv(mut buf []f32, x f32, y f32, u f32, v f32, col [4]f32) {
	buf << x
	buf << y
	buf << u
	buf << v
	buf << col[0]
	buf << col[1]
	buf << col[2]
	buf << col[3]
}

fn text_quad(mut buf []f32, c int, x f32, y f32, scale f32, col [4]f32) {
	if c < font.first || c > font.last {
		return
	}
	idx := c - font.first
	cx := (idx % font.cols) * font.cell_w
	cy := (idx / font.cols) * font.cell_h
	u0 := f32(cx) / f32(font.atlas_w)
	v0 := f32(cy) / f32(font.atlas_h)
	u1 := f32(cx + font.glyph_w) / f32(font.atlas_w)
	v1 := f32(cy + font.glyph_h) / f32(font.atlas_h)
	w := f32(font.glyph_w) * scale
	h := f32(font.glyph_h) * scale
	tv(mut buf, x, y, u0, v0, col)
	tv(mut buf, x + w, y, u1, v0, col)
	tv(mut buf, x + w, y + h, u1, v1, col)
	tv(mut buf, x, y, u0, v0, col)
	tv(mut buf, x + w, y + h, u1, v1, col)
	tv(mut buf, x, y + h, u0, v1, col)
}

fn text_buf(mut buf []f32, s string, x f32, y f32, scale f32, col [4]f32) {
	up := s.to_upper()
	mut cx := x
	mut i := 0
	for i < up.len {
		text_quad(mut buf, int(up[i]), cx, y, scale, col)
		cx += f32(font.glyph_w + 1) * scale
		i++
	}
}

fn text_width(s string, scale f32) f32 {
	return f32(s.len) * f32(font.glyph_w + 1) * scale
}

// ---- pause menu -------------------------------------------------- //

fn (mut g Game) render_menu() {
	w := f32(ffi.win_w())
	h := f32(ffi.win_h())
	if w < 1.0 || h < 1.0 {
		return
	}
	ortho := vm.mat4_ortho(f32(0.0), w, h, f32(0.0), f32(-1.0), f32(1.0))
	items := g.menu_items()

	// dim the frozen world, then draw the panel
	mut ui := []f32{}
	ui_quad(mut ui, f32(0.0), f32(0.0), w, h, [f32(0.0), f32(0.0), f32(0.0), f32(0.55)])
	pw := f32(560.0)
	ph := if g.menu_screen == .settings { f32(380.0) } else { f32(280.0) }
	px := (w - pw) / 2.0
	py := (h - ph) / 2.0
	ui_quad(mut ui, px, py, pw, ph, [f32(0.06), f32(0.07), f32(0.10), f32(0.94)])
	ui_quad(mut ui, px, py, pw, f32(3.0), [f32(0.36), f32(0.76), f32(0.44), f32(1.0)])

	mut ti := 0
	for ti < items.len {
		r := menu_item_rect(w, h, g.menu_screen, ti)
		if ti == g.menu_sel {
			ui_quad(mut ui, r[0], r[1], r[2], r[3], [f32(0.30), f32(0.62), f32(0.38), f32(0.95)])
		} else {
			ui_quad(mut ui, r[0], r[1], r[2], r[3], [f32(0.14), f32(0.16), f32(0.20), f32(0.85)])
		}
		ti++
	}

	title := if g.menu_screen == .settings { 'SETTINGS' } else { 'VCRAFT' }
	ts := f32(4.0)
	mut tb := []f32{}
	text_buf(mut tb, title, (w - text_width(title, ts)) / 2.0, py + f32(24.0), ts,
		[f32(0.92), f32(0.96), f32(0.86), f32(1.0)])

	mut di := 0
	for di < items.len {
		r := menu_item_rect(w, h, g.menu_screen, di)
		mut col := [4]f32{}
		if di == g.menu_sel {
			col[0] = 1.0
			col[1] = 1.0
			col[2] = 1.0
			col[3] = 1.0
		} else {
			col[0] = 0.78
			col[1] = 0.82
			col[2] = 0.86
			col[3] = 1.0
		}
		text_buf(mut tb, items[di], (w - text_width(items[di], f32(2.0))) / 2.0,
			r[1] + f32(10.0), f32(2.0), col)
		di++
	}

	ffi.ui_begin()
	ffi.blend(true)
	if ui.len > 0 {
		unsafe {
			ffi.draw_colors(&ui[0], ui.len / 6, ortho.ptr())
		}
	}
	ffi.text_begin(ortho.ptr())
	if tb.len > 0 {
		unsafe {
			ffi.draw_text(&tb[0], tb.len / 8)
		}
	}
	ffi.blend(false)
	ffi.ui_end()
}

fn (mut g Game) toggle_pause() {
	g.paused = !g.paused
	if g.paused {
		g.menu_screen = .main
		g.menu_sel = 0
		ffi.set_mouse_relative(false)
		g.break_active = false
		g.break_progress = 0.0
		g.break_frac = 0.0
	} else {
		g.menu_screen = .none
		ffi.set_mouse_relative(true)
		g.save_settings()
	}
}

fn (mut g Game) update_menu(dt f32) {
	_ = dt
	items := g.menu_items()
	n := items.len
	if n == 0 {
		return
	}

	// Mouse hover moves the selection.
	w := f32(ffi.win_w())
	h := f32(ffi.win_h())
	mx := f32(ffi.mouse_x())
	my := f32(ffi.mouse_y())
	if hover := menu_row_at(w, h, g.menu_screen, n, mx, my) {
		g.menu_sel = hover
	}

	if key_pressed(sc_up) || key_pressed(sc_w) {
		g.menu_sel = (g.menu_sel + n - 1) % n
		audio.play_click()
	}
	if key_pressed(sc_down) || key_pressed(sc_s) {
		g.menu_sel = (g.menu_sel + 1) % n
		audio.play_click()
	}

	// Left/right adjust the highlighted setting (the last row is BACK).
	if g.menu_screen == .settings && g.menu_sel < menu_settings_items - 1 {
		mut delta := 0
		if key_pressed(sc_left) || key_pressed(sc_a) {
			delta = -1
		}
		if key_pressed(sc_right) || key_pressed(sc_d) {
			delta = 1
		}
		if delta != 0 {
			g.adjust_setting(g.menu_sel, delta)
		}
	}

	if key_pressed(sc_enter) || key_pressed(sc_space) {
		g.activate_menu_item()
		return
	}
	// Left click activates the row under the cursor, and only that row: a
	// click in the gap between rows, or on the panel background, must do
	// nothing. Note the button index: 1 is left, because pump() shifts
	// SDL's mouse mask by one.
	if ffi.button_pressed(1) {
		if hit := menu_row_at(w, h, g.menu_screen, n, mx, my) {
			g.menu_sel = hit
			g.activate_menu_item()
		}
	}
}

// Index of the menu row under the cursor, or none when the point misses
// them all. Shared by hover and click so the two can never disagree. Note
// the miss case must be none rather than -1: as an ?int, some(-1) is a
// perfectly good value and a truthy one, which would select a row that
// does not exist.
fn menu_row_at(w f32, h f32, screen MenuScreen, n int, mx f32, my f32) ?int {
	mut i := 0
	for i < n {
		r := menu_item_rect(w, h, screen, i)
		if mx >= r[0] && mx <= r[0] + r[2] && my >= r[1] && my <= r[1] + r[3] {
			return i
		}
		i++
	}
	return none
}

fn (mut g Game) activate_menu_item() {
	if g.menu_screen == .settings {
		if g.menu_sel == menu_settings_items - 1 {
			audio.play_click()
			g.menu_screen = .main
			g.menu_sel = 1
		} else {
			g.adjust_setting(g.menu_sel, 1)
		}
		return
	}
	audio.play_click()
	match g.menu_sel {
		0 { g.toggle_pause() }
		1 {
			g.menu_screen = .settings
			g.menu_sel = 0
		}
		2 { ffi.request_close() }
		else {}
	}
}

fn (mut g Game) adjust_setting(idx int, dir int) {
	audio.play_click()
	match idx {
		0 {
			g.rd += dir
			if g.rd < min_rd {
				g.rd = min_rd
			}
			if g.rd > max_rd {
				g.rd = max_rd
			}
			g.update_chunks()
			g.update_meshes()
		}
		1 {
			g.fov += f32(dir) * 5.0
			if g.fov < min_fov {
				g.fov = min_fov
			}
			if g.fov > max_fov {
				g.fov = max_fov
			}
		}
		2 {
			g.sens += f32(dir) * 0.1
			if g.sens < 0.2 {
				g.sens = 0.2
			}
			if g.sens > 3.0 {
				g.sens = 3.0
			}
		}
		3 {
			g.volume += f32(dir) * 0.05
			if g.volume < 0.0 {
				g.volume = 0.0
			}
			if g.volume > 1.0 {
				g.volume = 1.0
			}
			audio.set_volume(g.volume)
		}
		4 {
			g.invert = !g.invert
		}
		else {}
	}
	g.save_settings()
}

// ---- settings persistence ---------------------------------------- //

// The self-test never reads or writes a player's real configuration: VTEST
// redirects it to a scratch file that only this program ever looks at.
const test_settings_path = '/tmp/opencode/vcraft-test-settings.cfg'

fn self_testing() bool {
	return os.getenv('VTEST') != ''
}

fn settings_path() string {
	if self_testing() {
		return test_settings_path
	}
	override := os.getenv('VCRAFT_CONFIG')
	if override != '' {
		return override
	}
	home := os.getenv('HOME')
	if home == '' {
		return ''
	}
	return home + '/.config/vcraft/settings.cfg'
}

// A snapshot of the five tunable values, so the self-test can put them back
// the way it found them.
struct Tune {
mut:
	rd     int
	fov    f32
	sens   f32
	volume f32
	invert bool
}

fn (g &Game) tune() Tune {
	return Tune{ rd: g.rd, fov: g.fov, sens: g.sens, volume: g.volume, invert: g.invert }
}

fn (mut g Game) apply_tune(t Tune) {
	g.rd = t.rd
	g.fov = t.fov
	g.sens = t.sens
	g.volume = t.volume
	g.invert = t.invert
	audio.set_volume(g.volume)
}

// The values a fresh install starts with.
fn (mut g Game) reset_settings() {
	g.apply_tune(Tune{ rd: 6, fov: 70.0, sens: 1.0, volume: 0.7, invert: false })
}

fn clamp_f32(v f32, lo f32, hi f32) f32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

fn (mut g Game) load_settings() {
	p := settings_path()
	if p == '' {
		return
	}
	txt := os.read_file(p) or { return }
	for line in txt.split_into_lines() {
		kv := line.split('=')
		if kv.len != 2 {
			continue
		}
		key := kv[0].trim_space()
		val := kv[1].trim_space()
		match key {
			'render_distance' {
				g.rd = clamp_int(val.int(), min_rd, max_rd)
			}
			'fov' {
				g.fov = clamp_f32(f32(val.f64()), min_fov, max_fov)
			}
			'sensitivity' {
				g.sens = clamp_f32(f32(val.f64()), 0.2, 3.0)
			}
			'volume' {
				g.volume = clamp_f32(f32(val.f64()), 0.0, 1.0)
			}
			'invert_mouse' {
				g.invert = val == '1'
			}
			else {}
		}
	}
}

fn (g &Game) save_settings() {
	p := settings_path()
	if p == '' {
		return
	}
	os.mkdir_all(os.dir(p)) or {}
	inv := if g.invert { 1 } else { 0 }
	txt := 'render_distance=${g.rd}\nfov=${g.fov:.1}\nsensitivity=${g.sens:.2}\nvolume=${g.volume:.2}\ninvert_mouse=${inv}\n'
	os.write_file(p, txt) or {}
}

fn clamp_int(v int, lo int, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

fn (mut g Game) render() {
	sky := sky_color(g.time)
	ffi.begin(1, sky[0], sky[1], sky[2])

	mut fog_far := f32(g.rd * world.chunk_size) * 0.95
	if os.getenv('VFOG') == '0' {
		fog_far = f32(far_plane)
	}
	mut fog_near := fog_far * env_f('VFOGSTART', 0.74)
	mut amb := 0.45 + sky[1] * 0.9
	if amb > 1.2 {
		amb = 1.2
	}

	// submerged: pull the view towards deep blue and pull the fog in close
	mut underwater := false
	if g.w.get_block(i32(math.floor(f64(g.pos.x))), i32(math.floor(f64(g.pos.y))),
		i32(math.floor(f64(g.pos.z)))) == blocks.water {
		underwater = true
	}
	mut fog_r := sky[0]
	mut fog_g := sky[1]
	mut fog_b := sky[2]
	if underwater {
		fog_r = 0.06
		fog_g = 0.22
		fog_b = 0.38
		fog_near = 1.0
		fog_far = 22.0
		amb *= 0.75
	}

	// Concatenate every visible chunk into one buffer: a single upload and
	// draw is far cheaper than one per chunk.
	g.gather_geometry()
	opaque := g.quad_buffer
	n_opaque := opaque.len / mesher.floats_per_vertex

	ffi.blend(false)
	ffi.set_uniforms(g.vp.ptr(), g.view.ptr(), fog_r, fog_g, fog_b, fog_near, fog_far,
		0.1, f32(g.time), amb, amb, amb)
	if n_opaque > 0 {
		ffi.upload(&opaque[0], n_opaque)
		ffi.draw(n_opaque)
	}

	// water
	draw_water := os.getenv('VWATER') != '0'
	if draw_water {
		water := g.water_buffer
		n_water := water.len / mesher.floats_per_vertex
		ffi.blend(true)
		ffi.set_uniforms(g.vp.ptr(), g.view.ptr(), fog_r, fog_g, fog_b, fog_near,
			fog_far, 0.0, f32(g.time), amb, amb, amb)
		if n_water > 0 {
			ffi.upload(&water[0], n_water)
			ffi.draw(n_water)
		}
		ffi.blend(false)
	}

	// targeted block outline; brightens as mining progresses
	ffi.blend(false)
	if g.target.found {
		hv := mesher.build_highlight(g.target.block[0], g.target.block[1], g.target.block[2])
		n := hv.len / mesher.floats_per_vertex
		bb := f32(0.08) + g.break_frac * f32(0.85)
		ffi.set_uniforms(g.vp.ptr(), g.view.ptr(), fog_r, fog_g, fog_b, fog_near,
			fog_far, 0.1, f32(g.time), bb, bb * f32(0.85), bb * f32(0.6))
		ffi.upload(&hv[0], n)
		ffi.draw_lines(n)
	}

	g.render_hud()
	if g.paused {
		g.render_menu()
	}
}

fn (mut g Game) run() {
	mut last := time.ticks()
	mut last_cx := i32(math.floor(f64(g.p.pos[0]))) >> 4
	mut last_cz := i32(math.floor(f64(g.p.pos[2]))) >> 4

	for !ffi.should_close() {
		now := time.ticks()
		mut dt_ms := now - last
		if dt_ms <= 0 {
			dt_ms = 1
		}
		if dt_ms > 100 {
			dt_ms = 100
		}
		last = now
		dt := f32(dt_ms) / f32(1000.0)
		if !g.paused {
			g.time += f32(dt_ms) / f32(1000.0)
		}
		g.frame++

		g.handle_input(dt)

		cx := i32(math.floor(f64(g.p.pos[0]))) >> 4
		cz := i32(math.floor(f64(g.p.pos[2]))) >> 4
		if cx != last_cx || cz != last_cz {
			g.update_chunks()
			g.update_meshes()
			last_cx = cx
			last_cz = cz
		}

		aspect := f32(ffi.win_w()) / f32(ffi.win_h())
		g.update_camera(aspect)
		g.render()
		ffi.present()

		if g.time - g.last_fps >= 1.0 {
			g.fps = f64(g.frame) / (g.time - g.last_fps)
			g.last_fps = g.time
			g.frame = 0
		}
	}
}

// Run the loop's logic without presenting, so the whole game path can be
// exercised headlessly.
fn (mut g Game) simulate(frames int, dt f32) {
	mut last_cx := i32(math.floor(f64(g.p.pos[0]))) >> 4
	mut last_cz := i32(math.floor(f64(g.p.pos[2]))) >> 4
	mut i := 0
	for i < frames {
		// Mirrors run(): a paused world keeps its clock still.
		if !g.paused {
			g.time += dt
		}
		g.frame++
		g.handle_input(dt)
		cx := i32(math.floor(f64(g.p.pos[0]))) >> 4
		cz := i32(math.floor(f64(g.p.pos[2]))) >> 4
		if cx != last_cx || cz != last_cz {
			g.update_chunks()
			g.update_meshes()
			last_cx = cx
			last_cz = cz
		}
		g.update_camera(f32(window_w) / f32(window_h))
		g.render()
		i++
	}
}

// Headless self-test of the parts a screenshot cannot show.
fn (mut g Game) selftest() {
	mut failures := 0

	// Start from a known state: a settings file left behind by an earlier run
	// (or a hand-edited one) would otherwise decide the render distance, and
	// a stale high value is enough to wedge the GL driver.
	if self_testing() {
		os.rm(settings_path()) or {}
		g.reset_settings()
	}
	orig := g.tune()

	// Flatten a small arena around the player: the spawn is often a forest
	// now, and tree trunks/canopies at eye level would clip the movement,
	// raycast, and mining checks below.
	fx := i32(math.floor(f64(g.p.pos[0])))
	fz := i32(math.floor(f64(g.p.pos[2])))
	mut yy := 2
	for yy < world.world_height {
		mut zz := fz - 7
		for zz < fz + 8 {
			mut xx := fx - 7
			for xx < fx + 8 {
				b := g.w.get_block(xx, yy, zz)
				if b == blocks.log || b == blocks.leaves || b == blocks.tall_grass {
					g.w.set_block(xx, yy, zz, blocks.air)
				}
				xx++
			}
			zz++
		}
		yy++
	}

	// 1. physics: the player must settle on solid ground, not fall through
	start_y := g.p.pos[1]
	g.simulate(180, f32(1.0 / 60.0))
	grounded := i32(math.floor(f64(g.p.pos[1])))
	under := g.w.get_block(i32(math.floor(f64(g.p.pos[0]))), grounded - 1,
		i32(math.floor(f64(g.p.pos[2]))))
	mut ok := blocks.is_solid(under) && g.p.pos[1] > start_y - f32(40.0)
	println('test gravity : ${ok}  fell ${start_y - g.p.pos[1]:.2} blocks, floor=${blocks.def(under).name}')
	if !ok {
		failures++
	}

	// 2. place a block
	px := i32(math.floor(f64(g.p.pos[0]))) + 2
	pz := i32(math.floor(f64(g.p.pos[2])))
	py := i32(math.floor(f64(g.p.pos[1]))) + 2
	g.w.set_block(px, py, pz, blocks.cobble)
	g.update_meshes()
	ok = g.w.get_block(px, py, pz) == blocks.cobble
	println('test place   : ${ok}')
	if !ok {
		failures++
	}

	// 3. break it again
	g.w.set_block(px, py, pz, blocks.air)
	g.update_meshes()
	ok = g.w.get_block(px, py, pz) == blocks.air
	println('test break   : ${ok}')
	if !ok {
		failures++
	}

	// 4. raycast straight down must find the block underfoot
	down := g.p.eye()
	hit := raycast.cast(&g.w, down, [f32(0.0), f32(-1.0), f32(0.0)], 6.0)
	println('test raycast : found=${hit.found} target=${blocks.def(hit.block_id).name} d=${hit.distance:.2}')
	if !hit.found {
		failures++
	}

	// 5. an edit must mark its chunk for remeshing
	ecx := i32(math.floor(f64(g.p.pos[0]))) >> 4
	ecz := i32(math.floor(f64(g.p.pos[2]))) >> 4
	g.w.clear_dirty(ecx, ecz)
	g.w.set_block(ecx * 16 + 2, 50, ecz * 16 + 2, blocks.glow)
	dirty := g.w.get_chunk(ecx, ecz) or { world.Chunk{} }
	ok = dirty.dirty == 1
	println('test dirty   : ${ok} chunk=(${ecx},${ecz})')
	if !ok {
		failures++
	}

	// 6. W must move the player towards where the camera points, and D
	// must strafe to the right of it.
	g.p.vel[0] = 0.0
	g.p.vel[2] = 0.0
	mut sx0 := g.p.pos[0]
	mut sz0 := g.p.pos[2]
	mut fw := player_mod.Input{ forward: 1.0 }
	mut n := 0
	for n < 30 {
		g.p.update(&g.w, fw, f32(1.0 / 60.0))
		n++
	}
	fd := g.p.look_dir()
	fdot := (g.p.pos[0] - sx0) * fd[0] + (g.p.pos[2] - sz0) * fd[2]
	ok = fdot > 0.0
	println('test forward : ${ok} dot=${fdot:.3f} moved=(${g.p.pos[0] - sx0:.2f},${g.p.pos[2] - sz0:.2f})')
	if !ok {
		failures++
	}

	g.p.vel[0] = 0.0
	g.p.vel[2] = 0.0
	sx0 = g.p.pos[0]
	sz0 = g.p.pos[2]
	// screen right = forward x up
	rx := -fd[2]
	rz := fd[0]
	mut st := player_mod.Input{ strafe: 1.0 }
	n = 0
	for n < 30 {
		g.p.update(&g.w, st, f32(1.0 / 60.0))
		n++
	}
	sdot := (g.p.pos[0] - sx0) * rx + (g.p.pos[2] - sz0) * rz
	ok = sdot > 0.0
	println('test strafe  : ${ok} dot=${sdot:.3f} moved=(${g.p.pos[0] - sx0:.2f},${g.p.pos[2] - sz0:.2f})')
	if !ok {
		failures++
	}

	// 7. every scancode constant must match SDL's own name lookup. A wrong
	// one binds a key to an unrelated action, which is invisible to every
	// other test but reads as broken controls.
	mut bad := sc_check('W', sc_w) + sc_check('A', sc_a) + sc_check('S', sc_s) +
		sc_check('D', sc_d) + sc_check('Space', sc_space) +
		sc_check('Left Shift', sc_shift_l) + sc_check('Left Ctrl', sc_ctrl_l) +
		sc_check('F', sc_f) + sc_check('1', sc_1) +
		sc_check('[', sc_lbracket) + sc_check(']', sc_rbracket) +
		sc_check('Escape', sc_escape) + sc_check('Return', sc_enter) +
		sc_check('Up', sc_up) + sc_check('Down', sc_down) +
		sc_check('Left', sc_left) + sc_check('Right', sc_right)
	ok = bad == ''
	println('test scancodes : ${ok} ${bad}')
	if !ok {
		failures++
	}

	// 8. synthesise real SDL key events and confirm every movement key
	// produces the motion its binding promises. This covers the whole
	// chain: event -> scancode bit -> Input -> wish direction.
	failures += g.test_keys()

	// 9. hotbar keys: digits select within the visible window, brackets
	// cycle through every block including wraparound.
	failures += g.test_hotbar()

	// 9b. mining is timed: the block must survive the first frames and only
	// break once the hold has lasted its hardness. Before the timer any
	// held button destroyed a block every single frame.
	g.p.yaw = 0.0
	g.p.pitch = 0.0
	mbx := i32(math.floor(f64(g.p.pos[0])))
	mby := i32(math.floor(f64(g.p.eye()[1])))
	mbz := i32(math.floor(f64(g.p.pos[2]))) + 1
	g.w.set_block(mbx, mby, mbz, blocks.stone)
	ffi.inject_button(1, true)
	mut mframes := 0
	mut broke_at := -1
	for mframes < 300 && broke_at < 0 {
		g.handle_input(f32(1.0 / 60.0))
		if g.w.get_block(mbx, mby, mbz) == blocks.air {
			broke_at = mframes
		}
		mframes++
	}
	ffi.inject_button(1, false)
	ffi.pump()
	// stone takes 1.5s = 90 frames; under ~0.3s means the timer is broken
	ok = broke_at > 20 && broke_at < 240
	println('test mining  : ${ok} broke at frame ${broke_at} (expect ~90)')
	if !ok {
		failures++
	}

	// 10. water: sink slowly instead of accelerating to the bottom, and
	// swim back up while jump is held.
	wx := i32(math.floor(f64(g.p.pos[0])))
	wz := i32(math.floor(f64(g.p.pos[2])))
	mut wy := 0
	for wy < 9 {
		g.w.set_block(wx, 95 - wy, wz, blocks.water)
		wy++
	}
	g.p.flying = false
	g.p.pos[1] = f32(89.0)
	g.p.vel[0] = 0.0
	g.p.vel[1] = 0.0
	g.p.vel[2] = 0.0
	mut wf := 0
	for wf < 60 {
		g.p.update(&g.w, player_mod.Input{}, f32(1.0 / 60.0))
		wf++
	}
	sink := g.p.pos[1] - f32(89.0)
	ok = sink < 0.0 && sink > -3.5
	println('test water sink : ${ok} dy=${sink:.2f} (slow sink, not pinned)')
	if !ok {
		failures++
	}

	g.p.pos[1] = f32(89.0)
	g.p.vel[0] = 0.0
	g.p.vel[1] = 0.0
	g.p.vel[2] = 0.0
	wf = 0
	for wf < 60 {
		g.p.update(&g.w, player_mod.Input{ jump: true }, f32(1.0 / 60.0))
		wf++
	}
	rise := g.p.pos[1] - f32(89.0)
	ok = rise > 1.0
	println('test water swim : ${ok} dy=${rise:.2f} (swims up)')
	if !ok {
		failures++
	}

	// 11. tall grass tufts: a forest/plains column must have plants on top
	// of its grass blocks.
	mut pc := world.find_biome_column('forest', 0, 0)
	if pc[0] == world.no_column {
		pc = world.find_biome_column('plains', 0, 0)
	}
	mut plants := 0
	mut where := 'none'
	if pc[0] != world.no_column {
		where = '${pc[0]},${pc[1]}'
		g.w.ensure_chunk(pc[0] >> 4, pc[1] >> 4)
		ch := g.w.get_chunk(pc[0] >> 4, pc[1] >> 4) or { world.Chunk{} }
		mut y := 0
		for y < world.world_height {
			mut z := 0
			for z < world.chunk_size {
				mut x := 0
				for x < world.chunk_size {
					if ch.get(x, y, z) == blocks.tall_grass {
						plants++
					}
					x++
				}
				z++
			}
			y++
		}
	}
	ok = plants > 0
	println('test grass tufts : ${ok} plants=${plants} col=${where}')
	if !ok {
		failures++
	}

	// 12. real placement: right-click must put a block beyond the faced
	// block through the whole input path (mouse event -> raycast -> set).
	g.p.flying = true
	g.p.pos[1] = f32(90.0)
	g.p.yaw = 0.0
	g.p.pitch = 0.0
	g.p.vel[0] = 0.0
	g.p.vel[1] = 0.0
	g.p.vel[2] = 0.0
	plx := i32(math.floor(f64(g.p.pos[0])))
	ply := i32(math.floor(f64(g.p.eye()[1])))
	plz := i32(math.floor(f64(g.p.pos[2])))
	g.w.set_block(plx, ply, plz + 2, blocks.stone)
	g.w.set_block(plx, ply, plz + 1, blocks.air)
	g.place_cd = 0.0
	ffi.inject_button(3, true)
	mut pn := 0
	for pn < 10 {
		g.handle_input(f32(1.0 / 60.0))
		pn++
	}
	ffi.inject_button(3, false)
	ffi.pump()
	placed := g.w.get_block(plx, ply, plz + 1)
	ok = placed == blocks.grass
	println('test place rmb : ${ok} placed=${blocks.def(placed).name} @(${plx},${ply},${plz + 1}) logs=${g.logs.len}')
	if !ok {
		failures++
	}

	// 13. water exit: swimming against a one-block-high shore must step up
	// onto it. Before the step-up the player bobbed at the water's edge
	// forever and could never reach dry land. The rig is built high in the
	// sky so terrain cannot interfere.
	ex2 := i32(math.floor(f64(g.p.pos[0]))) + 3
	ez2 := i32(math.floor(f64(g.p.pos[2]))) + 3
	mut q := ez2 - 1
	for q < ez2 + 5 {
		g.w.set_block(ex2, 88, q, blocks.stone)
		g.w.set_block(ex2 - 1, 88, q, blocks.stone)
		g.w.set_block(ex2 + 1, 88, q, blocks.stone)
		q++
	}
	// pool at ez2, shore ez2+1..ez2+3, end wall at ez2+4
	g.w.set_block(ex2, 89, ez2, blocks.water)
	g.w.set_block(ex2, 89, ez2 + 1, blocks.grass)
	g.w.set_block(ex2, 89, ez2 + 2, blocks.grass)
	g.w.set_block(ex2, 89, ez2 + 3, blocks.grass)
	q = ez2 - 1
	for q < ez2 + 5 {
		g.w.set_block(ex2 - 1, 89, q, blocks.stone)
		g.w.set_block(ex2 + 1, 89, q, blocks.stone)
		q++
	}
	mut yy2 := 88
	for yy2 < 94 {
		g.w.set_block(ex2, yy2, ez2 + 4, blocks.stone)
		yy2++
	}
	g.p.flying = false
	g.p.yaw = f32(0.0)
	g.p.pitch = f32(0.0)
	g.p.pos[0] = f32(ex2) + 0.5
	g.p.pos[1] = f32(89.3)
	g.p.pos[2] = f32(ez2) + 0.5
	g.p.vel[0] = 0.0
	g.p.vel[1] = 0.0
	g.p.vel[2] = 0.0
	st2 := player_mod.Input{ forward: 1.0, jump: true }
	mut wn := 0
	for wn < 120 {
		g.p.update(&g.w, st2, f32(1.0 / 60.0))
		wn++
	}
	ok = g.p.pos[2] > f32(ez2) + 0.8 && g.p.pos[1] >= 90.0
	println('test water exit : ${ok} forward=${g.p.pos[2] - f32(ez2):.2f} feet=${g.p.pos[1]:.2f}')
	if !ok {
		failures++
	}

	// 14. the procedural font must actually contain glyph pixels, and
	// layout must produce six vertices (one quad) per character.
	fatlas := font.build_font()
	mut lit := 0
	mut fi := 0
	for fi < font.atlas_w * font.atlas_h {
		if fatlas[fi * 4 + 3] != 0 {
			lit++
		}
		fi++
	}
	mut tb := []f32{}
	text_buf(mut tb, 'ABC', f32(0.0), f32(0.0), f32(2.0), [f32(1.0), f32(1.0), f32(1.0), f32(1.0)])
	ok = lit > 100 && tb.len == 3 * 6 * 8 && text_width('ABC', f32(2.0)) > 0.0
	println('test font    : ${ok} lit=${lit} verts=${tb.len / 8} width=${text_width('ABC', f32(2.0)):.0f}')
	if !ok {
		failures++
	}

	// 15. every sound cue must be synthesised to a non-empty waveform.
	cnts := audio.sample_counts()
	mut amin := cnts[0]
	for c in cnts {
		if c < amin {
			amin = c
		}
	}
	ok = amin > 0
	println('test audio   : ${ok} cues=${cnts.len} shortest=${amin} samples')
	if !ok {
		failures++
	}

	// 16. settings must survive a save/load round-trip, and out-of-range or
	// corrupt values must be clamped rather than trusted.
	g.rd = 7
	g.fov = 85.0
	g.sens = 1.7
	g.volume = 0.42
	g.invert = true
	g.save_settings()
	g.rd = 6
	g.fov = 70.0
	g.sens = 1.0
	g.volume = 0.7
	g.invert = false
	g.load_settings()
	ok = g.rd == 7 && int(g.fov + 0.5) == 85 && g.invert && g.volume > 0.4 && g.sens > 1.5
	println('test settings: ${ok} rd=${g.rd} fov=${g.fov:.0f} sens=${g.sens:.1} vol=${g.volume:.2f} invert=${g.invert}')
	if !ok {
		failures++
	}

	os.write_file(settings_path(), 'render_distance=999\nfov=1\nvolume=-4\nsensitivity=99\ninvert_mouse=maybe\n') or {
		failures++
	}
	g.load_settings()
	ok = g.rd == max_rd && int(g.fov + 0.5) == 40 && g.volume == 0.0 && g.sens > 2.9
		&& !g.invert
	println('test clamp   : ${ok} rd=${g.rd} fov=${g.fov:.0f} sens=${g.sens:.1} vol=${g.volume:.2f}')
	if !ok {
		failures++
	}

	// 17. Esc opens the pause menu (freezing play), arrows navigate, the
	// selected setting is adjustable, and Esc resumes.
	g.apply_tune(orig)
	g.paused = false
	g.menu_screen = .none
	ffi.inject_key(sc_escape, true)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_key(sc_escape, false)
	g.handle_input(f32(1.0 / 60.0))
	ok = g.paused && g.menu_screen == .main && g.menu_items().len == menu_main_items
	println('test pause   : ${ok} paused=${g.paused} sel=${g.menu_sel}')
	if !ok {
		failures++
	}

	g.menu_sel = 0
	ffi.inject_key(sc_down, true)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_key(sc_down, false)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_key(sc_enter, true)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_key(sc_enter, false)
	g.handle_input(f32(1.0 / 60.0))
	ok = g.menu_screen == .settings && g.menu_items().len == menu_settings_items
	println('test menu nav: ${ok} screen=${int(g.menu_screen)} sel=${g.menu_sel}')
	if !ok {
		failures++
	}

	// Drawing the menu exercises the text program and font texture.
	g.update_camera(f32(window_w) / f32(window_h))
	g.render()

	rd0 := g.rd
	ffi.inject_key(sc_right, true)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_key(sc_right, false)
	g.handle_input(f32(1.0 / 60.0))
	ok = g.rd == rd0 + 1
	println('test setting : ${ok} rd ${rd0} -> ${g.rd}')
	if !ok {
		failures++
	}

	// Invert is a toggle: left and right both flip it, which is what a
	// player expects from a row with no "left/right" affordance.
	inv0 := g.invert
	g.menu_sel = 4
	ffi.inject_key(sc_right, true)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_key(sc_right, false)
	g.handle_input(f32(1.0 / 60.0))
	ok = g.invert != inv0
	println('test toggle  : ${ok} invert ${inv0} -> ${g.invert}')
	if !ok {
		failures++
	}

	// The volume row must also drive the audio mixer, not just the label.
	vol0 := g.volume
	g.menu_sel = 3
	ffi.inject_key(sc_left, true)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_key(sc_left, false)
	g.handle_input(f32(1.0 / 60.0))
	ok = g.volume < vol0 && audio.volume() == g.volume
	println('test volume  : ${ok} ${vol0:.2f} -> ${g.volume:.2f} mixer=${audio.volume():.2f}')
	if !ok {
		failures++
	}

	ffi.inject_key(sc_escape, true)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_key(sc_escape, false)
	g.handle_input(f32(1.0 / 60.0))
	ok = !g.paused && g.menu_screen == .none
	println('test resume  : ${ok} paused=${g.paused}')
	if !ok {
		failures++
	}

	// The menu must freeze the world clock, otherwise time-driven shaders
	// keep animating behind a menu that promises a pause.
	g.paused = true
	t0 := g.time
	g.simulate(30, f32(1.0 / 60.0))
	ok = g.time == t0
	println('test freeze  : ${ok} time ${t0:.3f} -> ${g.time:.3f}')
	if !ok {
		failures++
	}
	// 18. A left click must activate the menu row it lands on. The button
	// index matters: pump() shifts SDL's mask, so left is 1, not 0. A
	// click test that used the wrong index still passes on the keyboard
	// path, so it has to drive the button explicitly.
	g.paused = true
	g.menu_screen = .main
	g.menu_sel = 0
	w := f32(ffi.win_w())
	h := f32(ffi.win_h())
	r := menu_item_rect(w, h, .main, 1) // SETTINGS
	ffi.set_mouse_at(i32(r[0] + r[2] / 2.0), i32(r[1] + r[3] / 2.0))
	ffi.inject_button(1, true)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_button(1, false)
	g.handle_input(f32(1.0 / 60.0))
	ok = g.menu_screen == .settings
	println('test menu clk: ${ok} screen=${int(g.menu_screen)} (clicked SETTINGS row)')
	if !ok {
		failures++
	}
	// ... and a click on empty panel space must do nothing at all.
	g.menu_screen = .main
	g.menu_sel = 0
	ffi.set_mouse_at(i32(w / 2.0), i32(h - f32(20.0)))
	ffi.inject_button(1, true)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_button(1, false)
	g.handle_input(f32(1.0 / 60.0))
	ok = g.menu_screen == .main && g.paused
	println('test clk miss: ${ok} screen=${int(g.menu_screen)} paused=${g.paused} (clicked empty space)')
	if !ok {
		failures++
	}

	g.paused = false
	g.apply_tune(orig)
	g.save_settings()
	if self_testing() {
		os.rm(settings_path()) or {}
	}

	if failures == 0 {
		println('SELFTEST PASS')
	} else {
		println('SELFTEST FAIL (${failures})')
	}
}

// Hold a synthetic key for a few frames and report how far the player moved.
fn (mut g Game) probe_key(sc int, dt f32) [2]f32 {
	g.p.vel[0] = 0.0
	g.p.vel[2] = 0.0
	rc := ffi.inject_key(sc, true)
	ffi.pump()
	println('  probe sc=${sc} push=${rc} keys=0x${ffi.keys():x} down=${key_down(sc)}')
	x0 := g.p.pos[0]
	z0 := g.p.pos[2]
	mut n := 0
	for n < 60 {
		g.handle_input(dt)
		n++
	}
	ffi.inject_key(sc, false)
	ffi.pump()
	return [g.p.pos[0] - x0, g.p.pos[2] - z0]
}

// Each movement key must push the player along the direction it promises.
fn (mut g Game) test_keys() int {
	mut fails := 0
	save := g.p.pos
	save_fly := g.p.flying
	save_yaw := g.p.yaw
	// yaw 0 puts forward on +Z and screen-right on -X, which keeps the
	// expected results readable. Fly high so terrain cannot block motion.
	g.p.yaw = f32(0.0)
	g.p.pos[1] = f32(90.0)
	g.p.flying = true

	names := ['W forward', 'S back', 'A left', 'D right']
	codes := [sc_w, sc_s, sc_a, sc_d]
	want_x := [f32(0.0), f32(0.0), f32(1.0), f32(-1.0)]
	want_z := [f32(1.0), f32(-1.0), f32(0.0), f32(0.0)]

	mut i := 0
	for i < 4 {
		d := g.probe_key(codes[i], f32(1.0 / 60.0))
		mag := f32(math.sqrt(f64(d[0] * d[0] + d[1] * d[1])))
		dot := d[0] * want_x[i] + d[1] * want_z[i]
		// must actually move, and move mostly along the promised axis
		ok := mag > f32(0.5) && dot > mag * f32(0.7)
		println('test key ${names[i]} : ${ok} moved=(${d[0]:.1f},${d[1]:.1f}) dot=${dot:.1f}')
		if !ok {
			fails++
		}
		i++
	}

	g.p.pos = save
	g.p.flying = save_fly
	g.p.yaw = save_yaw
	return fails
}

// The hotbar keys must land on the right block: digits pick within the
// visible nine slots, brackets cycle one step and wrap around the ends.
// handle_input() calls ffi.pump() itself, so a press must be injected and
// then handed to handle_input without an extra pump in between - otherwise
// the second pump consumes the rising edge before the handler reads it.
fn (mut g Game) test_hotbar() int {
	mut fails := 0
	save := g.selected
	g.selected = 0

	// '2' picks the second visible slot
	ffi.inject_key(sc_1 + 1, true)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_key(sc_1 + 1, false)
	ffi.pump()
	mut ok := g.selected == 1
	println('test hotbar digit  : ${ok} selected=${g.selected} block=${blocks.def(blocks.hotbar[g.selected]).name}')
	if !ok {
		fails++
	}

	// ']' then '[' move one block up and back down
	ffi.inject_key(sc_rbracket, true)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_key(sc_rbracket, false)
	ffi.pump()
	after_up := g.selected
	ffi.inject_key(sc_lbracket, true)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_key(sc_lbracket, false)
	ffi.pump()
	ok = after_up == 2 && g.selected == 1
	println('test hotbar cycle  : ${ok} up=${after_up} down=${g.selected}')
	if !ok {
		fails++
	}

	// '[' from slot 0 wraps to the last block: the first press walks 1->0,
	// the second wraps 0->15.
	ffi.inject_key(sc_lbracket, true)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_key(sc_lbracket, false)
	ffi.pump()
	ffi.inject_key(sc_lbracket, true)
	g.handle_input(f32(1.0 / 60.0))
	ffi.inject_key(sc_lbracket, false)
	ffi.pump()
	ok = g.selected == blocks.hotbar.len - 1
	println('test hotbar wrap   : ${ok} selected=${g.selected} last=${blocks.hotbar.len - 1}')
	if !ok {
		fails++
	}

	g.selected = save
	return fails
}

// '' when `want` agrees with SDL's own translation of `name`.
fn sc_check(name string, want int) string {
	got := ffi.scancode(name)
	if got == want {
		return ''
	}
	return '${name}(want ${want}, got ${got}) '
}

fn env_f(name string, def f32) f32 {
	v := os.getenv(name)
	if v == '' {
		return def
	}
	return f32(v.f64())
}

fn env_i(name string, def i32) i32 {
	v := os.getenv(name)
	if v == '' {
		return def
	}
	return i32(v.i64())
}

fn main() {
	headless := os.getenv('VHEADLESS') != ''
	println('=== VCraft :: voxel sandbox in V ===')
	mode := if headless { 0 } else { 1 }
	if ffi.init(mode, c'VCraft', window_w, window_h) == 0 {
		eprintln('graphics init failed')
		return
	}
	println('GL      : ' + ffi.gl_version())
	println('renderer: ' + ffi.gl_renderer())

	atlas := texture.build_atlas()
	tex := ffi.make_texture(&atlas[0], texture.tex_size, blocks.layer_count)
	ffi.use_texture(tex)
	println('atlas   : ${blocks.layer_count} layers @ ${texture.tex_size}px')

	font_atlas := font.build_font()
	ffi.make_font_texture(&font_atlas[0], font.atlas_w, font.atlas_h)

	mut g := Game{
		w:      world.new_world(world_seed)
		meshes: map[i64]ChunkMesh{}
	}
	g.load_settings()
	audio.init(g.volume, !headless)
	audio_status := if audio.available() { '48kHz mono' } else { 'disabled' }
	println('audio   : ' + audio_status)

	if os.getenv('VSTATS') != '' {
		print_height_stats()
	}
	if os.getenv('VCAVE') != '' {
		println('caves   : ' + world.cave_stats())
	}

	// A headless camera pose can be requested from the environment. It is
	// applied before any chunks are generated so the world builds around it.
	bname := os.getenv('VBIOME')
	cam_override := os.getenv('VCAM_X') != '' || bname != ''
	if cam_override {
		mut fx := env_f('VCAM_X', 0.0)
		mut fz := env_f('VCAM_Z', 0.0)
		if bname != '' {
			bc := world.find_biome_column(bname, 0, 0)
			if bc[0] != world.no_column {
				fx = f32(bc[0])
				fz = f32(bc[1])
			}
		}
		cx := fx
		cz := fz
		ground := f32(world.terrain_height(i32(cx), i32(cz)))
		cy := env_f('VCAM_Y', ground + f32(14.0))
		g.p = player_mod.new_player(cx, cy, cz)
		g.p.yaw = env_f('VCAM_YAW', 0.0)
		g.p.pitch = env_f('VCAM_PITCH', -0.35)
		g.update_chunks()
		g.update_meshes()
		println('world   : ${g.w.chunks.len} chunks, ${g.meshes.len} meshed')
		println('cam     : ${cx} ${cy} ${cz} ground=${ground} biome=${world.biome_name(world.biome_at(i32(cx), i32(cz)))}')

		g.update_camera(f32(window_w) / f32(window_h))
		g.render()
		save_shot()
		return
	}

	// Pick the spawn column first: terrain_height is pure maths, so this
	// works before any chunk exists. Chunks then build around the spawn.
	// Prefer a grassy biome: the first land column can be pure tundra,
	// which reads as "the game is broken" because everything is white.
	mut scol := world.find_biome_column('forest', 8, 8)
	if scol[0] == world.no_column {
		scol = world.find_biome_column('plains', 8, 8)
	}
	if scol[0] == world.no_column {
		scol = world.find_biome_column('savanna', 8, 8)
	}
	if scol[0] == world.no_column {
		scol = world.find_land_column(8, 8)
	}
	sx := if scol[0] != world.no_column { scol[0] } else { 8 }
	sz := if scol[1] != world.no_column { scol[1] } else { 8 }
	ground := world.terrain_height(sx, sz)
	g.p = player_mod.new_player(f32(sx) + 0.5, f32(ground) + 2.0, f32(sz) + 0.5)

	g.update_chunks()
	g.update_meshes()
	println('world   : ${g.w.chunks.len} chunks, ${g.meshes.len} meshed')
	println('biome   : ${world.biome_name(world.biome_at(sx, sz))} at (${sx},${sz}) h=${ground}')

	// Settle onto the surface. A top-down scan can land the player on a
	// tree crown (the spawn biome is often a forest), so walk the ground
	// height and nudge to a nearby column with two clear blocks of
	// headroom until the spot is safe.
	mut spx := sx
	mut spz := sz
	mut shy := ground + 1
	mut settled := false
	mut ring := 0
	for !settled && ring < 6 {
		mut ox := -ring
		for !settled && ox <= ring {
			mut oz := -ring
			for !settled && oz <= ring {
				dxa := if ox < 0 { -ox } else { ox }
				dza := if oz < 0 { -oz } else { oz }
				md := if dxa > dza { dxa } else { dza }
				if md == ring {
					gx := sx + ox
					gz := sz + oz
					gh := world.terrain_height(gx, gz)
					if blocks.is_solid(g.w.get_block(gx, gh, gz)) {
						mut clear := true
						mut dy := 1
						for dy < 3 {
							if blocks.is_solid(g.w.get_block(gx, gh + dy, gz)) {
								clear = false
							}
							dy++
						}
						if clear {
							spx = gx
							spz = gz
							shy = gh + 1
							settled = true
						}
					}
				}
				oz++
			}
			ox++
		}
		ring++
	}
	g.p.pos[0] = f32(spx) + 0.5
	g.p.pos[1] = f32(shy)
	g.p.pos[2] = f32(spz) + 0.5
	sp := g.p.pos
	println('spawn   : ${sp[0]:.1f} ${sp[1]:.1f} ${sp[2]:.1f}')

	if os.getenv('VCOUNT') != '' {
		// census of every block type in the loaded chunks
		mut counts := map[string]int{}
		for _, ch in g.w.chunks {
			mut y := 0
			for y < world.world_height {
				mut z := 0
				for z < world.chunk_size {
					mut x := 0
					for x < world.chunk_size {
						b := ch.blocks[world.chunk_index(x, y, z)]
						if b != blocks.air {
							nm := blocks.def(b).name
							counts[nm]++
						}
						x++
					}
					z++
				}
				y++
			}
		}
		for nm, n in counts {
			println('  ${nm}: ${n}')
		}
		return
	}

	if os.getenv('VSLICE') != '' {
		// vertical cross-section through a column, to inspect tree shapes
		slx := env_i('VSLICE_X', 0)
		slz := env_i('VSLICE_Z', 0)
		span := env_i('VSLICE_N', 24)
		half := span / 2
		h := world.terrain_height(slx, slz)
		println('slice   : x=${slx} z=${slz} h=${h}')
		mut y := h + 12
		for y >= h - 1 {
			mut line := ''
			mut z := slz - half
			for z < slz + half {
				b := g.w.get_block(slx, y, z)
				mut ch := u8(46)
				if b != blocks.air {
					ch = blocks.def(b).name[0]
				}
				line += ch.ascii_str()
				z++
			}
			println('${y}: ${line}')
			y--
		}
		return
	}

	if os.getenv('VPROBE') != '' {
		px := env_i('VPROBE_X', 0)
		pz := env_i('VPROBE_Z', 0)
		n := env_i('VPROBE_N', 48)
		half := n / 2
		// character map of the topmost solid block in each column
		mut z := pz - half
		for z < pz + half {
			mut line := ''
			mut x := px - half
			for x < px + half {
				mut top := -1
				mut y := world.world_height - 1
				for y >= 0 {
					if blocks.is_solid(g.w.get_block(x, y, z)) {
						top = y
						break
					}
					y--
				}
				mut ch := u8(46) // '.'
				if top >= 0 {
					ch = blocks.def(g.w.get_block(x, top, z)).name[0]
				}
				line += ch.ascii_str()
				x++
			}
			println(line)
			z++
		}
		return
	}

	if os.getenv('VATLAS') != '' {
		dump_atlas()
		return
	}

	if headless {
		g.update_camera(f32(window_w) / f32(window_h))
		if os.getenv('VMENU') != '' {
			g.paused = true
			g.menu_screen = if os.getenv('VMENU') == 'settings' {
				MenuScreen.settings
			} else {
				MenuScreen.main
			}
			g.menu_sel = 0
			g.render()
			save_shot()
			return
		}
		g.render()
		if os.getenv('VTEST') != '' {
			g.selftest()
		}
		save_shot()
		return
	}

	println('controls: WASD move | mouse look | LMB break | RMB place | 1-9 hotbar')
	println('          shift sneak | ctrl sprint | space jump | F fly | Esc pause')
	g.run()
	println('bye')
}

// Surface height spread across a wide area, for tuning the terrain.
fn print_height_stats() {
	mut hmin := 9999
	mut hmax := -9999
	mut ocean := 0
	mut total := 0
	for pz in 0 .. 96 {
		for px in 0 .. 96 {
			h := world.terrain_height(px * 47 - 2200, pz * 47 - 2200)
			total++
			if h < hmin {
				hmin = h
			}
			if h > hmax {
				hmax = h
			}
			if h < world.sea_level {
				ocean++
			}
		}
	}
	println('heights : min=${hmin} max=${hmax} ocean=${100 * ocean / total}%')

	// biome spread across the same area
	mut counts := [8]int{}
	for pz in 0 .. 64 {
		for px in 0 .. 64 {
			b := world.biome_at(px * 79 - 2500, pz * 79 - 2500)
			if b >= 0 && b < 8 {
				counts[b]++
			}
		}
	}
	mut line := 'biomes  :'
	mut i := 0
	for i < 8 {
		line += ' ${world.biome_name(i)}=${100 * counts[i] / 4096}%'
		i++
	}
	println(line)
}

// Write the whole texture atlas to a PNG, for eyeballing the art.
fn dump_atlas() {
	vs := os.getenv('VATLAS')
	mut path := '/tmp/opencode/atlas.png'
	if vs != '' {
		path = vs
	}
	atlas := texture.build_atlas()
	ok := ffi.write_atlas(atlas, texture.tex_size, blocks.layer_count, 6, path)
	println('atlas   : ${blocks.layer_count} layers -> ${path} (${ok})')
	// average colour per layer, to catch mis-ordered textures
	n := texture.tex_size * texture.tex_size * 4
	mut layer := 0
	for layer < blocks.layer_count {
		mut r := 0
		mut gg := 0
		mut b := 0
		mut i := 0
		for i < texture.tex_size * texture.tex_size {
			r += atlas[layer * n + i * 4]
			gg += atlas[layer * n + i * 4 + 1]
			b += atlas[layer * n + i * 4 + 2]
			i++
		}
		cnt := texture.tex_size * texture.tex_size
		println('  layer ${layer}: rgb(${r / cnt}, ${gg / cnt}, ${b / cnt})')
		layer++
	}
}

fn save_shot() {
	vs := os.getenv('VSHOT')
	mut shot := '/tmp/opencode/vcraft.png'
	if vs != '' {
		shot = vs
	}
	println('shot    : ${shot} -> ${ffi.screenshot(shot, window_w, window_h)}')
}
