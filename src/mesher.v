module mesher

import blocks
import world

// Vertex layout (7 floats): x, y, z, u, v, layer, light
pub const floats_per_vertex = 7

// Directional face shading, matching the classic look: top brightest,
// bottom darkest, and the sides stepped down from there.
fn face_shade(dir int) f32 {
	return match dir {
		2 { 1.00 } // +Y top
		3 { 0.50 } // -Y bottom
		0 { 0.72 } // +X
		1 { 0.72 } // -X
		4 { 0.86 } // +Z
		else { 0.86 } // -Z
	}
}

// The six face directions. Corners are wound counter-clockwise when viewed
// from outside the block, so GL back-face culling works. `uvs` gives each
// corner its own texture coordinate so a face spans the full tile.
struct Face {
	dir     [3]i32
	corners [4][3]i32
	uvs     [4][2]f32
}

const faces = [
	// +X
	Face{ dir: [1, 0, 0], corners: [[1, 0, 1], [1, 0, 0], [1, 1, 0], [1, 1, 1]],
		uvs: [[0, 1], [1, 1], [1, 0], [0, 0]] },
	// -X
	Face{ dir: [-1, 0, 0], corners: [[0, 0, 0], [0, 0, 1], [0, 1, 1], [0, 1, 0]],
		uvs: [[1, 1], [0, 1], [0, 0], [1, 0]] },
	// +Y
	Face{ dir: [0, 1, 0], corners: [[0, 1, 1], [1, 1, 1], [1, 1, 0], [0, 1, 0]],
		uvs: [[0, 0], [1, 0], [1, 1], [0, 1]] },
	// -Y
	Face{ dir: [0, -1, 0], corners: [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]],
		uvs: [[0, 0], [1, 0], [1, 1], [0, 1]] },
	// +Z
	Face{ dir: [0, 0, 1], corners: [[0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]],
		uvs: [[0, 1], [1, 1], [1, 0], [0, 0]] },
	// -Z
	Face{ dir: [0, 0, -1], corners: [[1, 0, 0], [0, 0, 0], [0, 1, 0], [1, 1, 0]],
		uvs: [[1, 1], [0, 1], [0, 0], [1, 0]] },
]

// Two tangent axes per face, used to sample the diagonal neighbours for
// vertex ambient occlusion.
fn tangent_for(dir int) [2][3]i32 {
	return match dir {
		0 { [[0, 1, 0], [0, 0, 1]] } // +X
		1 { [[0, 1, 0], [0, 0, 1]] } // -X
		2 { [[1, 0, 0], [0, 0, 1]] } // +Y
		3 { [[1, 0, 0], [0, 0, 1]] } // -Y
		4 { [[1, 0, 0], [0, 1, 0]] } // +Z
		else { [[1, 0, 0], [0, 1, 0]] } // -Z
	}
}

// Classic 3-neighbour vertex AO. Each argument is true when the block
// diagonally beside this corner blocks the light path.
fn vertex_ao(side1 bool, side2 bool, corner bool) f32 {
	if side1 && side2 {
		return 0.0
	}
	return f32(3 - (int(side1) + int(side2) + int(corner))) / f32(3)
}

fn ao_curve(ao f32) f32 {
	// gentle falloff so corners never go fully black
	return 0.45 + ao * 0.55
}

// ------------------------------------------------------------------ //
// Lighting                                                           //
// ------------------------------------------------------------------ //

// How much light reaches an air block: full sky if nothing opaque is above.
fn sky_light(w &world.World, x i32, y i32, z i32) f32 {
	if y < 0 || y >= world.world_height {
		return 1.0
	}
	if !w.has_chunk(x >> 4, z >> 4) {
		return 1.0
	}
	for yy in y .. world.world_height {
		if blocks.is_opaque(w.get_block(x, yy, z)) {
			return 0.16
		}
	}
	return 1.0
}

// Emissive light, sampled in a small box so a single glowstone lights its
// whole pocket rather than only itself.
fn block_light(w &world.World, x i32, y i32, z i32) f32 {
	mut best := 0.0
	for dy in -1 .. 2 {
		for dz in -1 .. 2 {
			for dx in -1 .. 2 {
				l := blocks.light_of(w.get_block(x + dx, y + dy, z + dz))
				if l > best {
					best = l
				}
			}
		}
	}
	return best
}

fn light_at(w &world.World, x i32, y i32, z i32) f32 {
	sl := sky_light(w, x, y, z)
	bl := block_light(w, x, y, z)
	if bl > sl {
		// emissive blocks glow warm
		return 0.55 + bl * 0.45
	}
	return 0.16 + sl * 0.84
}

// ------------------------------------------------------------------ //
// Meshing                                                            //
// ------------------------------------------------------------------ //

struct MeshBuf {
mut:
	verts []f32
}

fn (mut mb MeshBuf) push(x f32, y f32, z f32, u f32, v f32, layer f32, light f32) {
	mb.verts << x
	mb.verts << y
	mb.verts << z
	mb.verts << u
	mb.verts << v
	mb.verts << layer
	mb.verts << light
}

// Emit the two triangles of one visible face, or nothing if the face is
// hidden. Written as a positive test so no `continue` is needed.
fn emit_face(mut mb MeshBuf, w &world.World, wx i32, wy i32, wz i32, b u8, dir int) {
	f := faces[dir]
	nx := wx + f.dir[0]
	ny := wy + f.dir[1]
	nz := wz + f.dir[2]

	n := w.get_block(nx, ny, nz)
	visible := !blocks.is_opaque(n) && n != b
	if !visible {
		return
	}

	d := blocks.def(b)
	layer := f32(d.sides[dir])
	shade := face_shade(dir)
	tangents := tangent_for(dir)
	base_light := light_at(w, nx, ny, nz)

	// Per-corner light, combining face shading, ambient occlusion and the
	// light arriving from the neighbouring air block.
	mut lights := [f32(0.0), f32(0.0), f32(0.0), f32(0.0)]
	for ci in 0 .. 4 {
		cv := f.corners[ci]
		mut o1 := [3]i32{}
		mut o2 := [3]i32{}
		mut oc := [3]i32{}
		for k in 0 .. 3 {
			s := cv[k] * 2 - 1 // corner sits at -1 or +1 along this axis
			o1[k] = s * tangents[0][k]
			o2[k] = s * tangents[1][k]
			oc[k] = s
		}
		b1 := blocks.is_opaque(w.get_block(nx + o1[0], ny + o1[1], nz + o1[2]))
		b2 := blocks.is_opaque(w.get_block(nx + o2[0], ny + o2[1], nz + o2[2]))
		bc := blocks.is_opaque(w.get_block(nx + oc[0], ny + oc[1], nz + oc[2]))
		ao := vertex_ao(b1, b2, bc)
		lights[ci] = shade * ao_curve(ao) * base_light
	}

	// quad -> 0,1,2 then 0,2,3
	for vi in [0, 1, 2, 0, 2, 3] {
		ci := vi
		cv := f.corners[ci]
		mb.push(f32(wx + cv[0]), f32(wy + cv[1]), f32(wz + cv[2]),
			f.uvs[ci][0], f.uvs[ci][1], layer, lights[ci])
	}
}

// A cut-out plant: two quads crossing on the block diagonals. Emitting both
// windings makes them visible from every side without disabling back-face
// culling for the rest of the scene.
fn plant_quad(mut mb MeshBuf, wx i32, wy i32, wz i32, x0 f32, z0 f32, x1 f32, z1 f32, layer f32, l f32) {
	bx := f32(wx)
	by := f32(wy)
	bz := f32(wz)
	// bottom-left, bottom-right, top-right, top-left; v=0 is the top row
	mb.push(bx + x0, by, bz + z0, 0.0, 1.0, layer, l)
	mb.push(bx + x1, by, bz + z1, 1.0, 1.0, layer, l)
	mb.push(bx + x1, by + 1.0, bz + z1, 1.0, 0.0, layer, l)

	mb.push(bx + x0, by, bz + z0, 0.0, 1.0, layer, l)
	mb.push(bx + x1, by + 1.0, bz + z1, 1.0, 0.0, layer, l)
	mb.push(bx + x0, by + 1.0, bz + z0, 0.0, 0.0, layer, l)

	// reverse winding (back face)
	mb.push(bx + x1, by, bz + z1, 1.0, 1.0, layer, l)
	mb.push(bx + x0, by, bz + z0, 0.0, 1.0, layer, l)
	mb.push(bx + x0, by + 1.0, bz + z0, 0.0, 0.0, layer, l)

	mb.push(bx + x1, by + 1.0, bz + z1, 1.0, 0.0, layer, l)
	mb.push(bx + x1, by, bz + z1, 1.0, 1.0, layer, l)
	mb.push(bx + x0, by + 1.0, bz + z0, 0.0, 0.0, layer, l)
}

fn emit_plant(mut mb MeshBuf, w &world.World, wx i32, wy i32, wz i32, b u8) {
	d := blocks.def(b)
	layer := f32(d.sides[0])
	l := light_at(w, wx, wy, wz) * 0.95
	inset := f32(0.1)
	far := f32(0.9)
	// diagonal (inset,inset) -> (far,far)
	plant_quad(mut mb, wx, wy, wz, inset, inset, far, far, layer, l)
	// the perpendicular diagonal
	plant_quad(mut mb, wx, wy, wz, far, inset, inset, far, layer, l)
}

// Build the opaque mesh for one chunk, in world coordinates.
pub fn build_mesh(w &world.World, c &world.Chunk) []f32 {
	mut mb := MeshBuf{}
	base_x := c.cx * world.chunk_size
	base_z := c.cz * world.chunk_size

	for ly in 0 .. world.world_height {
		for lz in 0 .. world.chunk_size {
			for lx in 0 .. world.chunk_size {
				b := c.get(lx, ly, lz)
				d := blocks.def(b)
				wx := base_x + lx
				wz := base_z + lz
				if b == blocks.tall_grass {
					emit_plant(mut mb, w, wx, ly, wz, b)
				} else if b != blocks.air && !d.liquid {
					for dir in 0 .. 6 {
						emit_face(mut mb, w, wx, ly, wz, b, dir)
					}
				}
			}
		}
	}
	return mb.verts
}

// Water surface mesh, drawn in a second pass so it can be translucent.
fn emit_water_face(mut mb MeshBuf, w &world.World, wx i32, wy i32, wz i32, dir int) {
	f := faces[dir]
	nx := wx + f.dir[0]
	ny := wy + f.dir[1]
	nz := wz + f.dir[2]

	n := w.get_block(nx, ny, nz)
	if n == blocks.water || blocks.is_opaque(n) {
		return
	}

	shade := face_shade(dir) * 0.95
	sl := sky_light(w, wx, wy, wz)
	light := 0.35 + sl * 0.65

	// A negative layer marks the animated water path. The shader samples
	// abs(layer), so the magnitude must still be the real water layer index.
	anim := f32(-f32(blocks.t_water))
	for vi in [0, 1, 2, 0, 2, 3] {
		cv := f.corners[vi]
		mb.push(f32(wx + cv[0]), f32(wy + cv[1]), f32(wz + cv[2]),
			f.uvs[vi][0], f.uvs[vi][1], anim, shade * light)
	}
}

pub fn build_water_mesh(w &world.World, c &world.Chunk) []f32 {
	mut mb := MeshBuf{}
	base_x := c.cx * world.chunk_size
	base_z := c.cz * world.chunk_size

	for ly in 0 .. world.world_height {
		for lz in 0 .. world.chunk_size {
			for lx in 0 .. world.chunk_size {
				if c.get(lx, ly, lz) == blocks.water {
					wx := base_x + lx
					wz := base_z + lz
					for dir in 0 .. 6 {
						emit_water_face(mut mb, w, wx, ly, wz, dir)
					}
				}
			}
		}
	}
	return mb.verts
}

// Wireframe box for the targeted-block highlight.
pub fn build_highlight(x i32, y i32, z i32) []f32 {
	mut mb := MeshBuf{}
	// unit-cube corners, flat (x, y, z) triplets
	pts := [
		f32(0.0), f32(0.0), f32(0.0), // 0
		f32(1.0), f32(0.0), f32(0.0), // 1
		f32(1.0), f32(0.0), f32(1.0), // 2
		f32(0.0), f32(0.0), f32(1.0), // 3
		f32(0.0), f32(1.0), f32(0.0), // 4
		f32(1.0), f32(1.0), f32(0.0), // 5
		f32(1.0), f32(1.0), f32(1.0), // 6
		f32(0.0), f32(1.0), f32(1.0), // 7
	]
	edges := [
		[0, 1], [1, 2], [2, 3], [3, 0],
		[4, 5], [5, 6], [6, 7], [7, 4],
		[0, 4], [1, 5], [2, 6], [3, 7],
	]
	// shrink slightly toward the block centre to avoid z-fighting
	k := f32(1.0) - f32(0.006)
	for e in edges {
		for which in 0 .. 2 {
			base := e[which] * 3
			px := pts[base]
			py := pts[base + 1]
			pz := pts[base + 2]
			cx := f32(0.5) + (px - f32(0.5)) * k
			cy := f32(0.5) + (py - f32(0.5)) * k
			cz := f32(0.5) + (pz - f32(0.5)) * k
			mb.push(f32(x) + cx, f32(y) + cy, f32(z) + cz, f32(0.0), f32(0.0),
				f32(blocks.t_white), f32(1.0))
		}
	}
	return mb.verts
}
