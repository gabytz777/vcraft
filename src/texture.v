module texture

import math
import blocks

// Procedurally generated 16x16 pixel-art textures, packed into a single
// GL_TEXTURE_2D_ARRAY. All art is authored here as code; no external
// image assets are used.

pub const tex_size = 16

struct Rng {
mut:
	state u32
}

fn (mut r Rng) next() u32 {
	// xorshift32
	mut x := r.state
	x ^= x << 13
	x ^= x >> 17
	x ^= x << 5
	r.state = x
	return x
}

fn (mut r Rng) f() f32 {
	return f32(r.next() & 0x00ffffff) / f32(0x00ffffff)
}

fn (mut r Rng) range_(lo f32, hi f32) f32 {
	return lo + r.f() * (hi - lo)
}

fn (mut r Rng) chance(p f32) bool {
	return r.f() < p
}

struct Canvas {
mut:
	px []u8
}

fn new_canvas() Canvas {
	return Canvas{ px: []u8{len: tex_size * tex_size * 4} }
}

fn (mut c Canvas) set(x int, y int, col []f64) {
	if x < 0 || y < 0 || x >= tex_size || y >= tex_size {
		return
	}
	i := (y * tex_size + x) * 4
	c.px[i] = u8(math.clamp(col[0], 0.0, 1.0) * 255.0)
	c.px[i + 1] = u8(math.clamp(col[1], 0.0, 1.0) * 255.0)
	c.px[i + 2] = u8(math.clamp(col[2], 0.0, 1.0) * 255.0)
	c.px[i + 3] = u8(math.clamp(col[3], 0.0, 1.0) * 255.0)
}

fn (mut c Canvas) get(x int, y int) []f64 {
	xx := ((x % tex_size) + tex_size) % tex_size
	yy := ((y % tex_size) + tex_size) % tex_size
	i := (yy * tex_size + xx) * 4
	return [
		f32(c.px[i]) / 255.0,
		f32(c.px[i + 1]) / 255.0,
		f32(c.px[i + 2]) / 255.0,
		f32(c.px[i + 3]) / 255.0,
	]
}

fn (mut c Canvas) fill(col []f64) {
	for y in 0 .. tex_size {
		for x in 0 .. tex_size {
			c.set(x, y, col)
		}
	}
}

// Per-pixel noise tinting - the core of the blocky, hand-placed look.
fn (mut c Canvas) speckle(base []f64, amount f64, seed u32) {
	mut r := Rng{state: if seed == 0 { u32(0x2545f491) } else { seed }}
	for y in 0 .. tex_size {
		for x in 0 .. tex_size {
			d := (r.f() - 0.5) * 2.0 * amount
			c.set(x, y, [base[0] + d, base[1] + d, base[2] + d, 1.0])
		}
	}
}

// Draw axis-aligned rectangles of colour (used for planks, ore, bricks).
fn (mut c Canvas) rect(x0 int, y0 int, w int, h int, col []f64) {
	for y in y0 .. y0 + h {
		for x in x0 .. x0 + w {
			c.set(x, y, col)
		}
	}
}

// Scatter small clusters, used for ore and gravel speckles.
fn (mut c Canvas) cluster(seed u32, n int, col []f64, size int) {
	mut r := Rng{state: seed}
	for _ in 0 .. n {
		cx := int(r.f() * f32(tex_size))
		cy := int(r.f() * f32(tex_size))
		w := 1 + int(r.f() * f32(size))
		h := 1 + int(r.f() * f32(size))
		for y in cy .. cy + h {
			for x in cx .. cx + w {
				c.set(x, y, col)
			}
		}
	}
}

// ------------------------------------------------------------------ //
// Individual textures                                                //
// ------------------------------------------------------------------ //

fn tex_grass_top(mut c Canvas) {
	// Two-tone green base so the surface reads as a lawn, not a flat fill.
	mut r := Rng{state: 0x1234567}
	for y in 0 .. 16 {
		for x in 0 .. 16 {
			v := (r.f() - 0.5) * 0.20
			g := 0.58 + (r.f() - 0.5) * 0.16
			c.set(x, y, [0.30 + v, g, 0.22 + v * 0.7, 1.0])
		}
	}
	// darker clumps
	for _ in 0 .. 14 {
		cx := int(r.f() * 16.0)
		cy := int(r.f() * 16.0)
		col := c.get(cx, cy)
		c.set(cx, cy, [col[0] - 0.08, col[1] - 0.10, col[2] - 0.05, 1.0])
	}
	// bright blades, a couple of pixels tall
	for _ in 0 .. 16 {
		bx := int(r.f() * 16.0)
		by := int(r.f() * 15.0)
		col := c.get(bx, by)
		c.set(bx, by, [col[0] + 0.05, col[1] + 0.14, col[2] + 0.05, 1.0])
		c.set(bx, by + 1, [col[0] + 0.03, col[1] + 0.10, col[2] + 0.03, 1.0])
	}
}

fn tex_grass_side(mut c Canvas) {
	// dirt base
	c.speckle([0.45, 0.33, 0.22], 0.09, 0x2468135)
	// Grass overhang: deeper and more ragged than before, so the edge reads
	// as blades instead of a thin stripe.
	mut r := Rng{state: 0x5150c1}
	for x in 0 .. 16 {
		depth := 3 + int(r.f() * 4.0)
		for y in 0 .. depth {
			v := (r.f() - 0.5) * 0.12
			c.set(x, y, [0.30 + v, 0.58 + v * 0.8, 0.22, 1.0])
		}
	}
	// a few strands hanging below the fringe
	for x in 0 .. 16 {
		if r.chance(0.4) {
			y := 3 + int(r.f() * 4.0)
			col := c.get(x, y)
			c.set(x, y, [col[0] - 0.10, col[1] - 0.06, col[2], 1.0])
		}
	}
}

// A cut-out tuft of blades, drawn on a transparent background. Used by the
// cross-shaped plant mesh, never on a cube face.
fn tex_grass_plant(mut c Canvas) {
	c.fill([0.0, 0.0, 0.0, 0.0])
	mut r := Rng{state: 0x60dd5e1}
	for _ in 0 .. 12 {
		x := int(r.f() * 16.0)
		h := 5 + int(r.f() * 10.0)
		green := 0.52 + r.f() * 0.22
		mut y := 15
		mut n := 0
		for n < h {
			// the blade wobbles and thins as it rises
			wob := int((r.f() - 0.5) * 2.0)
			v := (r.f() - 0.5) * 0.10
			c.set(x + wob, y, [0.20 + v, green + v, 0.16 + v, 1.0])
			y -= 1
			n++
		}
	}
	// brighter tips on the blades that reached high enough
	for _ in 0 .. 10 {
		x := int(r.f() * 16.0)
		y := int(r.f() * 8.0)
		col := c.get(x, y)
		if col[3] > 0.5 {
			c.set(x, y, [col[0] + 0.06, col[1] + 0.12, col[2] + 0.04, 1.0])
		}
	}
}

fn tex_dirt(mut c Canvas) {
	c.speckle([0.45, 0.33, 0.22], 0.09, 0x0badf00)
}

fn tex_stone(mut c Canvas) {
	c.speckle([0.50, 0.50, 0.52], 0.09, 0x5eed5ee)
	// subtle darker blotches
	mut r := Rng{state: 0xabc1234}
	for _ in 0 .. 6 {
		cx := int(r.f() * 16.0)
		cy := int(r.f() * 16.0)
		for y in cy .. cy + 2 + int(r.f() * 2.0) {
			for x in cx .. cx + 2 + int(r.f() * 2.0) {
				col := c.get(x, y)
				c.set(x, y, [col[0] - 0.06, col[1] - 0.06, col[2] - 0.05, 1.0])
			}
		}
	}
}

fn tex_cobble(mut c Canvas) {
	// irregular stone cells separated by dark mortar
	c.fill([0.28, 0.28, 0.30, 1.0])
	cells := [[0, 0, 5, 5], [6, 0, 4, 3], [11, 0, 5, 6], [0, 6, 3, 4], [4, 6, 6, 5],
		[11, 7, 5, 4], [0, 11, 6, 5], [7, 12, 4, 4], [12, 12, 4, 4]]
	mut r := Rng{state: 0x77ccdd1}
	for cell in cells {
		base := 0.44 + r.f() * 0.16
		col := [base, base, base * 1.04, 1.0]
		for y in cell[1] .. cell[1] + cell[3] {
			for x in cell[0] .. cell[0] + cell[2] {
				v := (r.f() - 0.5) * 0.10
				c.set(x, y, [col[0] + v, col[1] + v, col[2] + v, 1.0])
			}
		}
	}
}

fn tex_planks(mut c Canvas) {
	c.fill([0.68, 0.52, 0.32, 1.0])
	mut r := Rng{state: 0x9a7b123}
	// four horizontal boards with dark seams
	for board in 0 .. 4 {
		y0 := board * 4
		for y in y0 .. y0 + 4 {
			for x in 0 .. 16 {
				v := (r.f() - 0.5) * 0.09
				c.set(x, y, [0.68 + v, 0.52 + v, 0.32 + v, 1.0])
			}
		}
		// seam
		for x in 0 .. 16 {
			c.set(x, y0, [0.42, 0.31, 0.18, 1.0])
		}
		// occasional knot
		if r.chance(0.5) {
			kx := int(r.f() * 14.0)
			ky := y0 + 1 + int(r.f() * 2.0)
			c.set(kx, ky, [0.50, 0.37, 0.21, 1.0])
			c.set(kx + 1, ky, [0.52, 0.39, 0.22, 1.0])
		}
	}
}

fn tex_sand(mut c Canvas) {
	c.speckle([0.85, 0.79, 0.58], 0.06, 0x1a2b3c4)
	mut r := Rng{state: 0x4d5e6f7}
	for _ in 0 .. 10 {
		x := int(r.f() * 16.0)
		y := int(r.f() * 16.0)
		c.set(x, y, [0.90, 0.85, 0.65, 1.0])
	}
}

fn tex_log_side(mut c Canvas) {
	c.speckle([0.42, 0.31, 0.18], 0.05, 0x2b3c4d5)
	mut r := Rng{state: 0x6e7f809}
	for _ in 0 .. 6 {
		x := int(r.f() * 16.0)
		y := int(r.f() * 16.0)
		h := 2 + int(r.f() * 4.0)
		for yy in y .. y + h {
			c.set(x, yy, [0.35, 0.25, 0.14, 1.0])
		}
	}
}

fn tex_log_top(mut c Canvas) {
	c.speckle([0.60, 0.47, 0.28], 0.05, 0x3f4e5d6)
	// concentric growth rings
	for i in 0 .. 4 {
		inset := i * 2
		col := if i % 2 == 0 { [0.44, 0.33, 0.19, 1.0] } else { [0.56, 0.43, 0.25, 1.0] }
		for t in 0 .. 1 {
			_ = t
		}
		// draw ring outline
		for x in inset .. 16 - inset {
			c.set(x, inset, col)
			c.set(x, 15 - inset, col)
		}
		for y in inset .. 16 - inset {
			c.set(inset, y, col)
			c.set(15 - inset, y, col)
		}
	}
}

fn tex_leaves(mut c Canvas) {
	mut r := Rng{state: 0x7c8d9e1}
	for y in 0 .. 16 {
		for x in 0 .. 16 {
			v := (r.f() - 0.5) * 0.22
			g := 0.42 + r.f() * 0.14
			c.set(x, y, [0.16 + v, g + v * 0.6, 0.14 + v, 1.0])
		}
	}
	// punch small holes so leaves read as foliage
	for _ in 0 .. 22 {
		x := int(r.f() * 16.0)
		y := int(r.f() * 16.0)
		c.set(x, y, [0, 0, 0, 0])
	}
}

fn tex_water(mut c Canvas) {
	for y in 0 .. 16 {
		for x in 0 .. 16 {
			w := (x + y) % 4
			v := f32(w) * 0.012
			c.set(x, y, [0.09 + v, 0.26 + v, 0.62 + v * 1.5, 0.78])
		}
	}
}

fn tex_bedrock(mut c Canvas) {
	c.speckle([0.30, 0.30, 0.32], 0.16, 0x8e9fa0b)
	c.cluster(0x1231231, 8, [0.16, 0.16, 0.18, 1.0], 3)
	c.cluster(0x3213213, 6, [0.48, 0.48, 0.50, 1.0], 2)
}

fn tex_gravel(mut c Canvas) {
	c.speckle([0.52, 0.50, 0.48], 0.10, 0x5f5e5d5)
	c.cluster(0x9988776, 12, [0.38, 0.36, 0.35, 1.0], 2)
	c.cluster(0x1122334, 10, [0.64, 0.62, 0.60, 1.0], 2)
}

fn tex_gold(mut c Canvas) {
	c.speckle([0.50, 0.50, 0.52], 0.08, 0x3344556)
	c.cluster(0xaabbcc1, 7, [0.92, 0.76, 0.24, 1.0], 3)
	c.cluster(0xccbbaa1, 5, [0.78, 0.62, 0.18, 1.0], 2)
}

fn tex_glow(mut c Canvas) {
	mut r := Rng{state: 0xdeadbee}
	for y in 0 .. 16 {
		for x in 0 .. 16 {
			v := (r.f() - 0.5) * 0.18
			c.set(x, y, [0.98 + v * 0.2, 0.84 + v, 0.48 + v, 1.0])
		}
	}
	c.cluster(0xfeedba1, 8, [1.0, 0.95, 0.72, 1.0], 2)
}

fn tex_white(mut c Canvas) {
	c.speckle([0.93, 0.93, 0.95], 0.03, 0x99aabb1)
}

fn tex_snow(mut c Canvas) {
	c.speckle([0.95, 0.96, 0.99], 0.025, 0xccbbaa2)
	c.cluster(0x3344556, 5, [0.86, 0.89, 0.95, 1.0], 2)
}

fn tex_obsidian(mut c Canvas) {
	c.speckle([0.10, 0.07, 0.14], 0.05, 0x2a2b2c2)
	c.cluster(0x4b4c4d4, 6, [0.20, 0.13, 0.28, 1.0], 2)
	c.cluster(0x6e6f707, 3, [0.30, 0.18, 0.40, 1.0], 1)
}

// Copy one canvas into its layer slot of the atlas.
fn put(mut buf []u8, layer int, c &Canvas) {
	off := layer * tex_size * tex_size * 4
	mut i := 0
	for i < tex_size * tex_size * 4 {
		buf[off + i] = c.px[i]
		i++
	}
}

// Build every layer into one contiguous RGBA buffer (layer-major).
//
// The layers are written out explicitly rather than through a table of
// function pointers: this V build mis-orders that kind of array, which
// silently shuffled the textures.
pub fn build_atlas() []u8 {
	mut buf := []u8{len: tex_size * tex_size * 4 * blocks.layer_count}

	mut c := new_canvas()
	tex_grass_top(mut c)
	put(mut buf, 0, c)
	tex_grass_side(mut c)
	put(mut buf, 1, c)
	tex_dirt(mut c)
	put(mut buf, 2, c)
	tex_stone(mut c)
	put(mut buf, 3, c)
	tex_cobble(mut c)
	put(mut buf, 4, c)
	tex_planks(mut c)
	put(mut buf, 5, c)
	tex_sand(mut c)
	put(mut buf, 6, c)
	tex_log_side(mut c)
	put(mut buf, 7, c)
	tex_log_top(mut c)
	put(mut buf, 8, c)
	tex_leaves(mut c)
	put(mut buf, 9, c)
	tex_water(mut c)
	put(mut buf, 10, c)
	tex_bedrock(mut c)
	put(mut buf, 11, c)
	tex_gravel(mut c)
	put(mut buf, 12, c)
	tex_gold(mut c)
	put(mut buf, 13, c)
	tex_glow(mut c)
	put(mut buf, 14, c)
	tex_white(mut c)
	put(mut buf, 15, c)
	tex_snow(mut c)
	put(mut buf, 16, c)
	tex_obsidian(mut c)
	put(mut buf, 17, c)
	tex_grass_plant(mut c)
	put(mut buf, 18, c)

	return buf
}
