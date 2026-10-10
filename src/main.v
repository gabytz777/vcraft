module main

import os
import time
import math

import ffi
import vm
import blocks
import texture
import world
import mesher
import raycast
import player as player_mod

const (
	render_distance = 6 // in chunks
	window_w = 1280
	window_h = 720
	fov_deg = 70.0
	near_plane = 0.05
	far_plane = 400.0
	world_seed = 1337
)

// SDL scancodes (SDL_SCANCODE_*). Verified against SDL_GetScancodeFromName
// by the self-test: getting one of these wrong binds a key to an unrelated
// action, which reads as "the controls are broken".
const (
	sc_w = 26
	sc_a = 4
	sc_s = 22
	sc_d = 7
	sc_space = 44
	sc_shift_l = 225
	sc_ctrl_l = 224
	sc_f = 9
	sc_1 = 30
	sc_lbracket = 47
	sc_rbracket = 48
)

struct ChunkMesh {
mut:
	cx    i32
	cz    i32
	verts []f32
	water []f32
}

struct Game {
mut:
	w       world.World
	meshes  map[i64]ChunkMesh
	p       player_mod.Player
	selected int
	time    f64
	fps     f64
	last_fps f64
	frame   int
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
	gen_count int
	dbg_fw f32
	dbg_st f32
	// scratch buffers rebuilt each frame
	quad_buffer   []f32
	water_buffer  []f32
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

	rd := render_distance + 1
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

	mspan := render_distance * 2 + 1
	rd2 := render_distance * render_distance
	for zi in 0 .. mspan {
		for xi in 0 .. mspan {
			dx := xi - render_distance
			dz := zi - render_distance
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
	limit := (render_distance + 3) * (render_distance + 3)
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

	sens := f32(0.0022)
	// yaw decreases with mouse-right so the view turns the way the mouse
	// goes: screen right is forward x up, which puts +X on the left.
	g.p.yaw -= f32(ffi.mouse_dx()) * sens
	g.p.pitch -= f32(ffi.mouse_dy()) * sens
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

	g.p.update(&g.w, inp, dt)

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
	fov := f32(fov_deg) * f32(math.pi) / f32(180.0)
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

fn (mut g Game) render() {
	sky := sky_color(g.time)
	ffi.begin(1, sky[0], sky[1], sky[2])

	mut fog_far := f32(render_distance * world.chunk_size) * 0.95
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
		g.time += f32(dt_ms) / f32(1000.0)
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
		g.time += dt
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
		sc_check('[', sc_lbracket) + sc_check(']', sc_rbracket)
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

	mut g := Game{
		w:      world.new_world(world_seed)
		meshes: map[i64]ChunkMesh{}
	}

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
		g.render()
		if os.getenv('VTEST') != '' {
			g.selftest()
		}
		save_shot()
		return
	}

	println('controls: WASD move | mouse look | LMB break | RMB place | 1-9 hotbar')
	println('          shift sneak | ctrl sprint | space jump | F fly | Esc quit')
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
