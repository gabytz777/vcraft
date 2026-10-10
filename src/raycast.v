module raycast

import math
import world
import blocks

pub struct Hit {
pub mut:
	block     [3]i32
	previous  [3]i32 // the empty cell just before the hit face
	normal    [3]i32
	block_id  u8
	distance  f32
	found     bool
}

// Amanatides & Woo voxel traversal (DDA).
pub fn cast(w &world.World, origin [3]f32, dir [3]f32, max_dist f32) Hit {
	mut hit := Hit{found: false}

	mut x := i32(math.floor(f64(origin[0])))
	mut y := i32(math.floor(f64(origin[1])))
	mut z := i32(math.floor(f64(origin[2])))

	step_x := if dir[0] > 0.0 { i32(1) } else if dir[0] < 0.0 { i32(-1) } else { i32(0) }
	step_y := if dir[1] > 0.0 { i32(1) } else if dir[1] < 0.0 { i32(-1) } else { i32(0) }
	step_z := if dir[2] > 0.0 { i32(1) } else if dir[2] < 0.0 { i32(-1) } else { i32(0) }

	inf := f32(1e30)
	mut t_max_x := if step_x == 0 { inf } else { boundary(f32(x), origin[0], dir[0], step_x) }
	mut t_max_y := if step_y == 0 { inf } else { boundary(f32(y), origin[1], dir[1], step_y) }
	mut t_max_z := if step_z == 0 { inf } else { boundary(f32(z), origin[2], dir[2], step_z) }

	delta_x := if dir[0] == 0.0 { inf } else { f32(1.0) / abs_f(dir[0]) }
	delta_y := if dir[1] == 0.0 { inf } else { f32(1.0) / abs_f(dir[1]) }
	delta_z := if dir[2] == 0.0 { inf } else { f32(1.0) / abs_f(dir[2]) }

	mut t := f32(0.0)
	mut nx_n := i32(0)
	mut ny_n := i32(0)
	mut nz_n := i32(0)

	walk: for i in 0 .. 1024 {
		b := w.get_block(x, y, z)
		if b != blocks.air && b != blocks.water {
			hit.block[0] = x
			hit.block[1] = y
			hit.block[2] = z
			// The cell the ray was in before crossing the hit face: it is
			// one step against the travel direction. n is the negated
			// step, so previous = index + n.
			hit.previous[0] = x + nx_n
			hit.previous[1] = y + ny_n
			hit.previous[2] = z + nz_n
			hit.normal[0] = nx_n
			hit.normal[1] = ny_n
			hit.normal[2] = nz_n
			hit.block_id = b
			hit.distance = t
			hit.found = true
			return hit
		}
		if t > max_dist {
			break walk
		}

		if t_max_x < t_max_y && t_max_x < t_max_z {
			x += step_x
			t = t_max_x
			t_max_x += delta_x
			nx_n = -step_x
			ny_n = 0
			nz_n = 0
		} else if t_max_y < t_max_z {
			y += step_y
			t = t_max_y
			t_max_y += delta_y
			nx_n = 0
			ny_n = -step_y
			nz_n = 0
		} else {
			z += step_z
			t = t_max_z
			t_max_z += delta_z
			nx_n = 0
			ny_n = 0
			nz_n = -step_z
		}
	}
	return hit
}

fn abs_f(v f32) f32 {
	return if v < 0.0 { -v } else { v }
}

// Distance from `pos` along the ray to the next voxel edge.
fn boundary(edge f32, pos f32, dir f32, step i32) f32 {
	if step > 0 {
		return (edge + f32(1.0) - pos) / dir
	}
	return (edge - pos) / dir
}
