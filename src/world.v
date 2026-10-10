module world

import noise
import blocks

pub const (
	chunk_size = 16
	world_height = 96
	sea_level = 40
)

pub fn chunk_index(x i32, y i32, z i32) int {
	return (y * chunk_size + z) * chunk_size + x
}

pub struct Chunk {
pub mut:
	cx    i32
	cz    i32
	blocks []u8 // chunk_size * world_height * chunk_size
	// 0 = empty, 1 = needs meshing, 2 = meshed
	dirty   u8
	opaque_cache []u8 // 1 if the column has any fully opaque stack
}

pub fn (c &Chunk) get(x i32, y i32, z i32) u8 {
	if y < 0 || y >= world_height {
		return blocks.air
	}
	return c.blocks[chunk_index(x, y, z)]
}

pub fn (mut c Chunk) set(x i32, y i32, z i32, b u8) {
	if y < 0 || y >= world_height {
		return
	}
	c.blocks[chunk_index(x, y, z)] = b
	c.dirty = 1
}

// Height of the topmost non-air block in a column.
pub fn (c &Chunk) height_at(x i32, z i32) i32 {
	for y := world_height - 1; y >= 0; y-- {
		if blocks.is_solid(c.get(x, y, z)) || c.get(x, y, z) == blocks.water {
			return y
		}
	}
	return 0
}

fn new_chunk(cx i32, cz i32) Chunk {
	return Chunk{
		cx: cx
		cz: cz
		blocks: []u8{len: chunk_size * world_height * chunk_size}
		dirty: 1
		opaque_cache: []u8{len: chunk_size * chunk_size}
	}
}

// ------------------------------------------------------------------ //
// Terrain generation                                                 //
// ------------------------------------------------------------------ //

// Biome ids.
pub const (
	bi_ocean   = i32(0)
	bi_beach   = i32(1)
	bi_plains  = i32(2)
	bi_forest  = i32(3)
	bi_desert  = i32(4)
	bi_savanna = i32(5)
	bi_snowy   = i32(6)
	bi_mountain = i32(7)
)

pub fn biome_name(b i32) string {
	return match b {
		bi_ocean    { 'Ocean' }
		bi_beach    { 'Beach' }
		bi_plains   { 'Plains' }
		bi_forest   { 'Forest' }
		bi_desert   { 'Desert' }
		bi_savanna  { 'Savanna' }
		bi_snowy    { 'Snowy Tundra' }
		else         { 'Mountains' }
	}
}

// Two very low frequency fields pick the climate: temperature and humidity.
// Kept separate from the height field so biomes cut across the terrain
// instead of following it.
pub fn climate(wx i32, wz i32) [2]f32 {
	xf := f32(wx)
	zf := f32(wz)
	t := noise.fbm2(xf * 0.00085, zf * 0.00085, 20240, 3, 2.0, 0.5)
	hum := noise.fbm2(xf * 0.00105, zf * 0.00105, 9091, 3, 2.0, 0.5)
	return [t, hum]
}

fn climate_temp(wx i32, wz i32) f32 {
	return noise.fbm2(f32(wx) * 0.00085, f32(wz) * 0.00085, 20240, 3, 2.0, 0.5)
}

// Which biome covers this column.
pub fn biome_at(wx i32, wz i32) i32 {
	h := terrain_height(wx, wz)
	cl := climate(wx, wz)
	temp := cl[0]
	hum := cl[1]

	// altitude overrides climate
	if h < sea_level - 1 {
		return bi_ocean
	}
	if h <= sea_level + 1 && climate_temp(wx, wz) > 0.44 {
		return bi_beach
	}
	if h > 73 {
		return bi_mountain
	}
	if h > 58 && temp < f32(0.52) {
		return bi_snowy
	}
	if temp < f32(0.36) {
		return bi_snowy
	}
	if temp > f32(0.60) && hum < f32(0.50) {
		return bi_desert
	}
	if hum > f32(0.55) {
		return bi_forest
	}
	if hum < f32(0.42) {
		return bi_savanna
	}
	return bi_plains
}

// Layered continental height field.
//
// Four bands of noise, each recentred on zero so amplitudes are predictable:
//   cont   - very large landmasses (oceans vs highlands)
//   hills  - rolling terrain
//   detail - small surface roughness
//   mtn    - ridged noise, masked so crests only appear on high ground
pub fn terrain_height(wx i32, wz i32) i32 {
	xf := f32(wx)
	zf := f32(wz)

	// fBm clusters tightly around its mean, so the continental term is
	// expanded and clamped to push lowlands and highlands apart.
	cont := clampf(centred(noise.fbm2(xf * 0.0018, zf * 0.0018, 1337, 5, 2.0, 0.5)) * 2.4, -1.0, 1.0)
	hills := centred(noise.fbm2(xf * 0.017, zf * 0.017, 4242, 4, 2.0, 0.5))
	detail := centred(noise.fbm2(xf * 0.055, zf * 0.055, 777, 3, 2.0, 0.5))
	mtn := noise.ridge2(xf * 0.0055, zf * 0.0055, 9001, 4)

	mut base := f32(sea_level) + 4.0
	base += cont * 24.0
	base += hills * 7.0
	base += detail * 2.5

	// Only high continental ground grows mountains; squaring keeps the
	// foothills lower than the crests.
	mask := cont * cont
	base += mtn * mtn * 32.0 * mask

	// Flatten the sea floor so oceans read as basins rather than noise.
	if base < f32(sea_level) {
		base = f32(sea_level) - (f32(sea_level) - base) * 0.45
	}
	if base > f32(world_height - 12) {
		base = f32(world_height - 12)
	}
	return int(base)
}

// Remap a 0..1 noise value onto -1..1.
fn centred(v f32) f32 {
	return (v - f32(0.5)) * f32(2.0)
}

fn clampf(v f32, lo f32, hi f32) f32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

fn math_max(a f32, b f32) f32 {
	return if a > b { a } else { b }
}

// Diagnostic toggle: set false to render solid terrain with no caves.
const caves_enabled = true

// Cave carving.
//
// Each field's "below threshold" set is a smooth 2D sheet through 3D space;
// where two decorrelated sheets cross you get a 1D curve, which is exactly a
// winding tunnel. Intersecting them keeps the carved volume small, unlike
// thresholding a single field (which gives swiss cheese).
fn is_cave(wx i32, wy i32, wz i32) bool {
	if !caves_enabled {
		return false
	}
	if wy < 5 || wy > world_height - 16 {
		return false
	}
	xf := f32(wx)
	yf := f32(wy)
	zf := f32(wz)
	n1 := noise.fbm3(xf * 0.028, yf * 0.045, zf * 0.028, 777, 3, 2.0, 0.5)
	n2 := noise.fbm3(xf * 0.026, yf * 0.042, zf * 0.026, 31337, 3, 2.0, 0.5)
	// tunnels widen with depth: the deep world feels more cavernous
	mut t := 0.385
	if wy < 24 {
		t = 0.340
	} else if wy > 56 {
		t = 0.360
	}
	return n1 < t && n2 < t
}

// Diagnostic: how much of the volume the cave test actually removes.
pub fn cave_stats() string {
	mut n := 0
	mut hit := 0
	for y in 5 .. 45 {
		for z in -64 .. 64 {
			for x in -64 .. 64 {
				if is_cave(x, y, z) {
					hit++
				}
				n++
			}
		}
	}
	return 'carved=${100.0 * f32(hit) / f32(n):.2}%'
}

fn generate_chunk(mut c Chunk) {
	base_x := c.cx * chunk_size
	base_z := c.cz * chunk_size

	for lz in 0 .. chunk_size {
		for lx in 0 .. chunk_size {
			wx := base_x + lx
			wz := base_z + lz
			h := terrain_height(wx, wz)
			bi := biome_at(wx, wz)

			for y in 0 .. world_height {
				mut b := blocks.air

				if y == 0 {
					b = blocks.bedrock
				} else if y <= h {
					if is_cave(wx, y, wz) && y < h - 3 {
						b = blocks.air
					} else if y == h {
						b = surface_block(bi, h)
					} else if y > h - 4 {
						b = sub_surface_block(bi)
					} else {
						b = deep_block(wx, y, wz, h)
					}
				} else if y <= sea_level {
					b = blocks.water
				}

				if b != blocks.air {
					c.set(lx, y, lz, b)
				}
			}
		}
	}

	decorate(mut c, base_x, base_z)
	c.dirty = 1
}

// The block that caps a column, given its biome.
fn surface_block(bi i32, h i32) u8 {
	if h < sea_level - 2 {
		return blocks.gravel
	}
	return match bi {
		bi_ocean    { blocks.gravel }
		bi_beach    { blocks.sand }
		bi_desert   { blocks.sand }
		bi_snowy    { blocks.snow }
		bi_mountain { if h > 72 { blocks.snow } else { blocks.stone } }
		else        { blocks.grass }
	}
}

// Just under the surface.
fn sub_surface_block(bi i32) u8 {
	return match bi {
		bi_desert   { blocks.sand }
		bi_beach    { blocks.sand }
		bi_mountain { blocks.stone }
		else        { blocks.dirt }
	}
}

// Deep rock, with ore pockets.
fn deep_block(wx i32, y i32, wz i32, h i32) u8 {
	if h > 66 {
		return blocks.stone
	}
	r := noise.rand2(wx * 31 + y * 7, wz * 17 + y * 13, 555)
	if y < 20 && r < 0.006 {
		return blocks.glow
	}
	if y < 26 && r > 0.986 {
		return blocks.gold
	}
	if y < 34 && r > 0.978 && r < 0.984 {
		return blocks.gravel
	}
	return blocks.stone
}

// Scatter trees and glowstone according to the biome.
fn decorate(mut c Chunk, base_x i32, base_z i32) {
	// A margin is scanned so canopies crossing chunk borders still grow in.
	for dz in -2 .. chunk_size + 2 {
		for dx in -2 .. chunk_size + 2 {
			wx := base_x + dx
			wz := base_z + dz
			bi := biome_at(wx, wz)
			chance := tree_chance(bi)
			r := noise.rand2(wx, wz, 8888)
			if chance > 0.0 && r > 1.0 - chance {
				h := surface_y(&c, dx, dz)
				if h > sea_level {
					plant_tree(mut c, dx, h + 1, dz)
				}
			}
		}
	}

	// Glowstone clusters tucked into cave pockets.
	for dz in 0 .. chunk_size {
		for dx in 0 .. chunk_size {
			wx := base_x + dx
			wz := base_z + dz
			if noise.rand2(wx * 3, wz * 5, 24680) > 0.9988 {
				mut placed := false
				mut y := 6
				for y < 40 {
					if !placed && c.get(dx, y, dz) == blocks.air &&
						c.get(dx, y - 1, dz) == blocks.stone &&
						c.get(dx, y + 1, dz) == blocks.stone {
						c.set(dx, y, dz, blocks.glow)
						placed = true
					}
					y++
				}
			}
		}
	}

	// Grass tufts scattered over grassy surfaces. Only on top of a grass
	// block that still has open air above it (so trees win).
	for dz in 0 .. chunk_size {
		for dx in 0 .. chunk_size {
			wx := base_x + dx
			wz := base_z + dz
			if noise.rand2(wx * 7 + 3, wz * 13 + 5, 13579) > 0.78 {
				h := surface_y(&c, dx, dz)
				if h >= 0 && h + 1 < world_height {
					if c.get(dx, h, dz) == blocks.grass && c.get(dx, h + 1, dz) == blocks.air {
						c.set(dx, h + 1, dz, blocks.tall_grass)
					}
				}
			}
		}
	}
}

// Probability that a column in this biome grows a tree.
fn tree_chance(bi i32) f32 {
	return match bi {
		bi_forest   { 0.070 }
		bi_plains   { 0.008 }
		bi_savanna  { 0.005 }
		bi_snowy    { 0.014 }
		bi_mountain { 0.016 }
		else        { 0.0 }
	}
}

// Find dry land near the origin: the first column whose surface sits above
// sea level, searched in expanding squares. Returns -1 if nothing is found.
// Find a column with the named biome, searching outwards from the origin.
// Returns [no_column, no_column] if the world has none nearby.
pub fn find_biome_column(name string, cx i32, cz i32) [2]i32 {
	target := match name {
		'ocean'    { bi_ocean }
		'beach'    { bi_beach }
		'plains'   { bi_plains }
		'forest'   { bi_forest }
		'desert'   { bi_desert }
		'savanna'  { bi_savanna }
		'snowy'    { bi_snowy }
		else       { bi_mountain }
	}
	mut i := 0
	for i < 20000 {
		ex := cx + ((i * 53) % 601) - 300
		ez := cz + ((i * 127) % 601) - 300
		if biome_at(ex, ez) == target {
			return [ex, ez]
		}
		i++
	}
	return [no_column, no_column]
}

// Sentinel returned by find_land_column when no dry land was found.
// Negative coordinates are perfectly valid, so this cannot be -1.
pub const no_column = i32(-1000000)

pub fn find_land_column(cx i32, cz i32) [2]i32 {
	// Walk a strided lattice outwards until dry land turns up. Written as a
	// flat loop: nested loops with per-iteration mutations proved unreliable
	// in this V build.
	mut i := 0
	for i < 6000 {
		ex := cx + ((i * 37) % 401) - 200
		ez := cz + ((i * 91) % 401) - 200
		if terrain_height(ex, ez) > sea_level + 1 {
			return [ex, ez]
		}
		i++
	}
	return [no_column, no_column]
}

// Y of the first grass or dirt block counting down from the sky, or -1.
// dx/dz may be outside the chunk, in which case the column is clamped.
fn surface_y(c &Chunk, dx i32, dz i32) i32 {
	ccx := clampi(dx, 0, chunk_size - 1)
	ccz := clampi(dz, 0, chunk_size - 1)
	mut i := 0
	for i < world_height {
		y := world_height - 1 - i
		blk := c.get(ccx, y, ccz)
		if blk == blocks.grass || blk == blocks.dirt || blk == blocks.sand ||
			blk == blocks.snow {
			return y
		}
		i++
	}
	return -1
}

fn clampi(v i32, lo i32, hi i32) i32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

fn plant_tree(mut c Chunk, x i32, y_base i32, z i32) {
	// Trunk 4-6 blocks.
	th := 4 + int(noise.rand2(x * 13, z * 17, 99) * 3.0)
	mut i := 0
	for i < th {
		yy := y_base + i
		if yy < world_height && in_chunk(x) && in_chunk(z) {
			c.set(x, yy, z, blocks.log)
		}
		i++
	}
	top := min_i(y_base + th - 1, world_height - 1)

	// Canopy: two wide layers, two narrow ones, then a single tip. Starting
	// it low keeps the trunk mostly hidden, the way a real oak reads.
	for dy in -3 .. 3 {
		ly := top + dy
		mut radius := 1
		if dy <= -1 {
			radius = 2
		}
		if dy == 3 {
			radius = 0
		}
		for dz in -radius .. radius + 1 {
			for dx in -radius .. radius + 1 {
				corner := abs_i(dx) == radius && abs_i(dz) == radius && radius > 1
				trunk_slot := dx == 0 && dz == 0 && dy <= 0
				nx := x + dx
				nz := z + dz
				fits := ly >= 0 && ly < world_height && in_chunk(nx) && in_chunk(nz)
				if !corner && !trunk_slot && fits && c.get(nx, ly, nz) == blocks.air {
					c.set(nx, ly, nz, blocks.leaves)
				}
			}
		}
	}
}

fn min_i(a i32, b i32) i32 {
	return if a < b { a } else { b }
}

fn abs_i(v i32) i32 {
	return if v < 0 { -v } else { v }
}

fn in_chunk(v i32) bool {
	return v >= 0 && v < chunk_size
}

// ------------------------------------------------------------------ //
// World: chunk registry + block access across chunk borders           //
// ------------------------------------------------------------------ //

pub struct World {
pub mut:
	chunks   map[i64]Chunk
	seed     i32
}

// Pack two i32 chunk coords into one i64 map key.
// Note: must use u32 casts -- a literal 0xffffffff is signed in V, so it
// would fail to mask and collide for negative coordinates.
pub fn chunk_key(cx i32, cz i32) i64 {
	return (i64(u32(cx)) << 32) | i64(u32(cz))
}

pub fn new_world(seed int) &World {
	return &World{
		chunks: map[i64]Chunk{}
		seed: seed
	}
}

pub fn (mut w World) ensure_chunk(cx i32, cz i32) bool {
	k := chunk_key(cx, cz)
	if k in w.chunks {
		return false
	}
	mut c := new_chunk(cx, cz)
	generate_chunk(mut c)
	w.chunks[k] = c
	return true
}

// Returns a handle on the chunk. Chunks hold their blocks in a slice, so
// copies are cheap and share the same block storage.
pub fn (w &World) get_chunk(cx i32, cz i32) ?Chunk {
	k := chunk_key(cx, cz)
	if k in w.chunks {
		return w.chunks[k]
	}
	return none
}

pub fn (w &World) has_chunk(cx i32, cz i32) bool {
	return chunk_key(cx, cz) in w.chunks
}

// World-space block read. Returns air for unloaded chunks.
pub fn (w &World) get_block(wx i32, wy i32, wz i32) u8 {
	if wy < 0 || wy >= world_height {
		return blocks.air
	}
	cx := wx >> 4
	cz := wz >> 4
	ch := w.get_chunk(cx, cz) or { return blocks.air }
	return ch.get(wx & 15, wy, wz & 15)
}

pub fn (mut w World) set_block(wx i32, wy i32, wz i32, b u8) {
	if wy < 0 || wy >= world_height {
		return
	}
	cx := wx >> 4
	cz := wz >> 4
	k := chunk_key(cx, cz)
	if k !in w.chunks {
		return
	}
	unsafe {
		w.chunks[k].set(wx & 15, wy, wz & 15, b)
	}
	// mark neighbouring chunks dirty when the edit touches a border
	lx := wx & 15
	lz := wz & 15
	if lx == 0 {
		w.touch(cx - 1, cz)
	}
	if lx == 15 {
		w.touch(cx + 1, cz)
	}
	if lz == 0 {
		w.touch(cx, cz - 1)
	}
	if lz == 15 {
		w.touch(cx, cz + 1)
	}
}

fn (mut w World) touch(cx i32, cz i32) {
	k := chunk_key(cx, cz)
	if k in w.chunks {
		unsafe {
			w.chunks[k].dirty = 1
		}
	}
}

// Clear the dirty flag once a chunk has been meshed.
pub fn (mut w World) clear_dirty(cx i32, cz i32) {
	k := chunk_key(cx, cz)
	if k in w.chunks {
		unsafe {
			w.chunks[k].dirty = 0
		}
	}
}
