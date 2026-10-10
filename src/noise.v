module noise

import math

// Deterministic hash-based value noise + fBm. All integer maths so world
// generation is reproducible across runs and machines.

fn hash2(x i32, y i32, seed i32) f32 {
	mut h := u32(x) * u32(0x27d4eb2d) ^ u32(y) * u32(0x165667b1) ^ u32(seed) * u32(0x9e3779b1)
	h ^= h >> 15
	h = h * u32(0x2c1b3c6d)
	h ^= h >> 12
	h = h * u32(0x297a2d39)
	h ^= h >> 15
	return f32(h & 0x00ffffff) / f32(0x00ffffff)
}

fn hash3(x i32, y i32, z i32, seed i32) f32 {
	mut h := u32(x) * u32(0x27d4eb2d) ^ u32(y) * u32(0x165667b1) ^
		u32(z) * u32(0x1b873593) ^ u32(seed) * u32(0x9e3779b1)
	h ^= h >> 15
	h = h * u32(0x2c1b3c6d)
	h ^= h >> 12
	h = h * u32(0x297a2d39)
	h ^= h >> 15
	return f32(h & 0x00ffffff) / f32(0x00ffffff)
}

fn smooth(t f32) f32 {
	return t * t * (3.0 - 2.0 * t)
}

pub fn noise2(x f32, y f32, seed int) f32 {
	xi := i32(math.floor(f64(x)))
	yi := i32(math.floor(f64(y)))
	xf := x - f32(xi)
	yf := y - f32(yi)
	u := smooth(xf)
	v := smooth(yf)
	a := hash2(xi, yi, seed)
	b := hash2(xi + 1, yi, seed)
	c := hash2(xi, yi + 1, seed)
	d := hash2(xi + 1, yi + 1, seed)
	top := a + (b - a) * u
	bot := c + (d - c) * u
	return top + (bot - top) * v
}

pub fn noise3(x f32, y f32, z f32, seed int) f32 {
	xi := i32(math.floor(f64(x)))
	yi := i32(math.floor(f64(y)))
	zi := i32(math.floor(f64(z)))
	xf := x - f32(xi)
	yf := y - f32(yi)
	zf := z - f32(zi)
	u := smooth(xf)
	v := smooth(yf)
	w := smooth(zf)
	mut acc := f32(0.0)
	for dz in 0 .. 2 {
		for dy in 0 .. 2 {
			for dx in 0 .. 2 {
				val := hash3(xi + dx, yi + dy, zi + dz, seed)
				wx := if dx == 0 { 1.0 - u } else { u }
				wy := if dy == 0 { 1.0 - v } else { v }
				wz := if dz == 0 { 1.0 - w } else { w }
				acc += val * wx * wy * wz
			}
		}
	}
	return acc
}

// Fractal brownian motion: layered noise, normalised to roughly 0..1.
pub fn fbm2(x f32, y f32, seed int, octaves int, lacunarity f32, gain f32) f32 {
	mut amp := f32(1.0)
	mut freq := f32(1.0)
	mut sum := f32(0.0)
	mut norm := f32(0.0)
	for _ in 0 .. octaves {
		sum += noise2(x * freq, y * freq, seed) * amp
		norm += amp
		amp *= gain
		freq *= lacunarity
	}
	return sum / norm
}

pub fn fbm3(x f32, y f32, z f32, seed int, octaves int, lacunarity f32, gain f32) f32 {
	mut amp := f32(1.0)
	mut freq := f32(1.0)
	mut sum := f32(0.0)
	mut norm := f32(0.0)
	for _ in 0 .. octaves {
		sum += noise3(x * freq, y * freq, z * freq, seed) * amp
		norm += amp
		amp *= gain
		freq *= lacunarity
	}
	return sum / norm
}

// Ridged noise produces sharper mountain crests.
pub fn ridge2(x f32, y f32, seed int, octaves int) f32 {
	mut amp := f32(1.0)
	mut freq := f32(1.0)
	mut sum := f32(0.0)
	mut norm := f32(0.0)
	for _ in 0 .. octaves {
		n := noise2(x * freq, y * freq, seed)
		mut v := f32(1.0) - (n - f32(0.5)) * f32(2.0)
		if v < 0.0 {
			v = -v
		}
		sum += v * v * amp
		norm += amp
		amp *= 0.5
		freq *= 2.0
	}
	return sum / norm
}

// Stable per-column pseudo random in 0..1, used for tree/flower placement.
pub fn rand2(x i32, z i32, seed i32) f32 {
	return hash2(x, z, seed)
}
