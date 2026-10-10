module vm

// Minimal 3D math: vectors and 4x4 matrices.
// NOTE: this V build does not support operator overloading with multiple
// arguments, so all vector ops are named methods (add/sub/scale/...).

pub struct Vec3 {
pub:
	x f32
	y f32
	z f32
}

pub fn vec3(x f32, y f32, z f32) Vec3 {
	return Vec3{x, y, z}
}

pub fn (a Vec3) add(b Vec3) Vec3 {
	return Vec3{x: a.x + b.x, y: a.y + b.y, z: a.z + b.z}
}

pub fn (a Vec3) sub(b Vec3) Vec3 {
	return Vec3{x: a.x - b.x, y: a.y - b.y, z: a.z - b.z}
}

pub fn (a Vec3) scale(s f32) Vec3 {
	return Vec3{x: a.x * s, y: a.y * s, z: a.z * s}
}

pub fn (a Vec3) cross(b Vec3) Vec3 {
	return Vec3{
		x: a.y * b.z - a.z * b.y
		y: a.z * b.x - a.x * b.z
		z: a.x * b.y - a.y * b.x
	}
}

pub fn (a Vec3) dot(b Vec3) f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

pub fn (a Vec3) length() f32 {
	return sqrtf(a.x * a.x + a.y * a.y + a.z * a.z)
}

pub fn (a Vec3) normalize() Vec3 {
	l := a.length()
	if l == f32(0.0) {
		return Vec3{x: f32(0.0), y: f32(0.0), z: f32(0.0)}
	}
	inv := f32(1.0) / l
	return Vec3{x: a.x * inv, y: a.y * inv, z: a.z * inv}
}

pub fn (a Vec3) str() string {
	return '(${a.x:.2}, ${a.y:.2}, ${a.z:.2})'
}

// Column-major 4x4, laid out the way GL expects: m[col * 4 + row].
pub type Mat4 = [16]f32

// Pointer to the first element, for handing straight to C/GL.
pub fn (m &Mat4) ptr() &f32 {
	unsafe {
		return &m[0]
	}
}

pub fn mat4_identity() Mat4 {
	return [
		f32(1.0), f32(0.0), f32(0.0), f32(0.0),
		f32(0.0), f32(1.0), f32(0.0), f32(0.0),
		f32(0.0), f32(0.0), f32(1.0), f32(0.0),
		f32(0.0), f32(0.0), f32(0.0), f32(1.0),
	]
}

pub fn mat4_mul(a Mat4, b Mat4) Mat4 {
	mut out := Mat4{}
	for c in 0 .. 4 {
		for r in 0 .. 4 {
			mut sum := f32(0.0)
			for k in 0 .. 4 {
				sum += a[k * 4 + r] * b[c * 4 + k]
			}
			out[c * 4 + r] = sum
		}
	}
	return out
}

pub fn mat4_translate(t Vec3) Mat4 {
	mut m := mat4_identity()
	m[12] = t.x
	m[13] = t.y
	m[14] = t.z
	return m
}

pub fn mat4_scale(s Vec3) Mat4 {
	mut m := mat4_identity()
	m[0] = s.x
	m[5] = s.y
	m[10] = s.z
	return m
}

// Orthographic projection for the 2D HUD. Pass (0, w, h, 0) for a top-left
// origin in pixels.
pub fn mat4_ortho(left f32, right f32, bottom f32, top f32, near f32, far f32) Mat4 {
	mut m := Mat4{}
	m[0] = f32(2.0) / (right - left)
	m[5] = f32(2.0) / (top - bottom)
	m[10] = f32(-2.0) / (far - near)
	m[12] = -(right + left) / (right - left)
	m[13] = -(top + bottom) / (top - bottom)
	m[14] = -(far + near) / (far - near)
	m[15] = f32(1.0)
	return m
}

pub fn mat4_rot_y(rad f32) Mat4 {
	mut m := mat4_identity()
	s := sinf(rad)
	c := cosf(rad)
	m[0] = c
	m[2] = -s
	m[8] = s
	m[10] = c
	return m
}

// Right-handed perspective projection with a [-1,1] depth range.
pub fn mat4_perspective(fov_y_rad f32, aspect f32, near f32, far f32) Mat4 {
	f := f32(1.0) / tanf(fov_y_rad / f32(2.0))
	mut m := Mat4{}
	m[0] = f / aspect
	m[5] = f
	m[10] = (far + near) / (near - far)
	m[11] = f32(-1.0)
	m[14] = f32(2.0) * far * near / (near - far)
	return m
}

pub fn mat4_look_at(eye Vec3, target Vec3, up Vec3) Mat4 {
	f := target.sub(eye).normalize()
	s := f.cross(up).normalize()
	u := s.cross(f)
	mut m := mat4_identity()
	m[0] = s.x
	m[4] = s.y
	m[8] = s.z
	m[1] = u.x
	m[5] = u.y
	m[9] = u.z
	m[2] = -f.x
	m[6] = -f.y
	m[10] = -f.z
	m[12] = -s.dot(eye)
	m[13] = -u.dot(eye)
	m[14] = f.dot(eye)
	return m
}
