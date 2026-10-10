module player

import math
import world
import blocks

pub const (
	player_width = 0.6
	player_height = 1.8
	eye_height = 1.62
	player_aabb_height = 1.8
)

pub struct Player {
pub mut:
	pos       [3]f32 // feet position
	vel       [3]f32
	yaw       f32
	pitch     f32
	on_ground bool
	flying    bool
	sprinting bool
	// 0..1 smoothed, drives the view bob
	walk_phase f32
	in_water   bool
}

pub fn new_player(x f32, y f32, z f32) &Player {
	mut p := Player{}
	p.pos[0] = x
	p.pos[1] = y
	p.pos[2] = z
	p.yaw = 0.6
	p.pitch = -0.2
	return &p
}

pub fn (mut p Player) eye() [3]f32 {
	return [p.pos[0], p.pos[1] + eye_height, p.pos[2]]
}

pub fn (mut p Player) look_dir() [3]f32 {
	cp := f32(math.cos(f64(p.pitch)))
	return [
		f32(math.sin(f64(p.yaw))) * cp,
		f32(math.sin(f64(p.pitch))),
		f32(math.cos(f64(p.yaw))) * cp,
	]
}

// AABB overlaps any solid block?
fn collides(w &world.World, p [3]f32) bool {
	half := player_width / 2.0
	min_x := int(math.floor(f64(p[0] - half)))
	max_x := int(math.floor(f64(p[0] + half)))
	min_y := int(math.floor(f64(p[1])))
	max_y := int(math.floor(f64(p[1] + player_aabb_height)))
	min_z := int(math.floor(f64(p[2] - half)))
	max_z := int(math.floor(f64(p[2] + half)))

	for by in min_y .. max_y + 1 {
		for bz in min_z .. max_z + 1 {
			for bx in min_x .. max_x + 1 {
				if blocks.is_solid(w.get_block(bx, by, bz)) {
					return true
				}
			}
		}
	}
	return false
}

fn feet_in_water(w &world.World, p [3]f32) bool {
	bx := int(math.floor(f64(p[0])))
	bz := int(math.floor(f64(p[2])))
	by := int(math.floor(f64(p[1] + 0.4)))
	return w.get_block(bx, by, bz) == blocks.water
}

pub struct Input {
pub mut:
	forward f32
	strafe  f32
	jump    bool
	sneak   bool
	sprint  bool
}

// Move with per-axis collision resolution so sliding along walls works.
fn (mut p Player) move_axis(w &world.World, axis int, delta f32) {
	if delta == 0.0 {
		return
	}
	mut np := p.pos
	np[axis] += delta
	if !collides(w, np) {
		p.pos = np
		return
	}
	// One-block auto step-up. Without this the player can never climb out
	// of water onto a shore (the shore's lip is exactly one block), and
	// hills and stairs are unwalkable. Only offered on horizontal axes.
	if axis != 1 {
		mut sp := p.pos
		sp[axis] += delta
		sp[1] += 1.0
		if !collides(w, sp) {
			p.pos = sp
			p.vel[1] = 0.0
			p.on_ground = true
			return
		}
	}
	// blocked: snap flush to the block boundary
	step := f32(0.001)
	mut t := delta
	steps: for _ in 0 .. 64 {
		if abs_f(t) <= step {
			break steps
		}
		t -= if t > 0.0 { step } else { -step }
		np[axis] = p.pos[axis] + t
		if !collides(w, np) {
			p.pos = np
			return
		}
	}
	// fully blocked, stay put and zero the velocity on this axis
	p.vel[axis] = 0.0
	if axis == 1 {
		if delta < 0.0 {
			p.on_ground = true
		}
	}
}

fn abs_f(v f32) f32 {
	return if v < 0.0 { -v } else { v }
}

pub fn (mut p Player) update(w &world.World, inp Input, dt f32) {
	// Look
	// (yaw/pitch are modified externally from mouse deltas)

	p.in_water = feet_in_water(w, p.pos)

	// Desired horizontal direction in world space
	sy := f32(math.sin(f64(p.yaw)))
	cy := f32(math.cos(f64(p.yaw)))
	// Forward must agree with look_dir(), otherwise W walks away from
	// where the camera is pointing.
	fx := sy
	fz := cy
	// Screen right is forward x up.
	rx := -cy
	rz := sy

	wish_x := fx * inp.forward + rx * inp.strafe
	wish_z := fz * inp.forward + rz * inp.strafe
	wl := f32(math.sqrt(f64(wish_x * wish_x + wish_z * wish_z)))
	mut ndx := f32(0.0)
	mut ndz := f32(0.0)
	if wl > 0.0001 {
		ndx = wish_x / wl
		ndz = wish_z / wl
	}

	p.sprinting = inp.sprint && inp.forward > 0.1

	mut speed := f32(4.317)
	if p.sprinting {
		speed = 5.612
	}
	if inp.sneak && !p.flying {
		speed = 1.3
	}
	if p.in_water && !p.flying {
		speed = 3.0
	}
	if p.flying {
		speed = if p.sprinting { 21.0 } else { 10.5 }
	}

	// Ground/air acceleration
	target_x := ndx * speed
	target_z := ndz * speed
	accel := if p.flying {
		f32(8.0)
	} else if p.on_ground {
		f32(40.0)
	} else {
		f32(8.0)
	}
	p.vel[0] = approach(p.vel[0], target_x, accel * dt)
	p.vel[2] = approach(p.vel[2], target_z, accel * dt)

	if p.flying {
		mut vy := f32(0.0)
		if inp.jump {
			vy += speed
		}
		if inp.sneak {
			vy -= speed
		}
		p.vel[1] = approach(p.vel[1], vy, accel * dt)
	} else if p.in_water {
		// Buoyancy: weak gravity plus speed-proportional drag, so the player
		// settles into a slow sink instead of accelerating to the sea floor
		// and getting pinned there.
		p.vel[1] -= f32(7.0) * dt
		p.vel[1] -= p.vel[1] * f32(3.2) * dt
		// Holding jump always swims up, even while standing on the bottom,
		// so deep water can never trap the player.
		if inp.jump {
			p.vel[1] = approach(p.vel[1], f32(4.2), f32(18.0) * dt)
		}
		if p.vel[1] > 4.2 {
			p.vel[1] = 4.2
		}
		if p.vel[1] < -4.0 {
			p.vel[1] = -4.0
		}
	} else {
		p.vel[1] -= f32(28.0) * dt
		// terminal velocity
		if p.vel[1] < -78.0 {
			p.vel[1] = -78.0
		}
		// jump
		if inp.jump && p.on_ground {
			p.vel[1] = 8.95
			p.on_ground = false
		}
	}

	// Integrate with collision resolution
	p.on_ground = false
	p.move_axis(w, 0, p.vel[0] * dt)
	p.move_axis(w, 2, p.vel[2] * dt)
	p.move_axis(w, 1, p.vel[1] * dt)

	// Ground probe (small downward nudge so on_ground sticks)
	if !p.flying && p.vel[1] <= 0.0 {
		mut probe := p.pos
		probe[1] -= 0.02
		if collides(w, probe) {
			p.on_ground = true
		}
	}

	// Don't fall out of the world
	if p.pos[1] < -20.0 {
		p.pos[1] = f32(80.0)
		p.vel[0] = f32(0.0)
		p.vel[1] = f32(0.0)
		p.vel[2] = f32(0.0)
	}

	// Walk bob phase from horizontal speed
	hspeed := f32(math.sqrt(f64(p.vel[0] * p.vel[0] + p.vel[2] * p.vel[2])))
	if p.on_ground && hspeed > 0.1 {
		p.walk_phase += dt * hspeed * 1.6
		if p.walk_phase > 6.2831853 {
			p.walk_phase -= 6.2831853
		}
	}
}

fn approach(current f32, target f32, max_delta f32) f32 {
	d := target - current
	if d > max_delta {
		return current + max_delta
	}
	if d < -max_delta {
		return current - max_delta
	}
	return target
}

// Find a safe spawn point: highest solid ground at or below `from_y`.
pub fn find_spawn(w &world.World, x i32, z i32, from_y i32) [3]f32 {
	mut found_y := -1
	mut i := 0
	scan: for i < from_y {
		y := from_y - i
		if y <= 1 {
			break scan
		}
		b := w.get_block(x, y, z)
		ground_ok := blocks.is_solid(b) && b != blocks.leaves && b != blocks.log
		if ground_ok {
			// need two blocks of headroom
			mut clear := true
			mut dy := 1
			for dy < 3 {
				if blocks.is_solid(w.get_block(x, y + dy, z)) {
					clear = false
				}
				dy++
			}
			if clear {
				found_y = y
				break scan
			}
		}
		i++
	}
	if found_y < 0 {
		return [f32(x) + 0.5, f32(from_y), f32(z) + 0.5]
	}
	return [f32(x) + 0.5, f32(found_y) + 1.0, f32(z) + 0.5]
}
