module vm

import math as stdmath

// Thin f32 wrappers over the standard library, kept in one place so the
// rest of the engine reads cleanly.

pub fn sqrtf(v f32) f32 {
	return f32(stdmath.sqrt(f64(v)))
}

pub fn sinf(v f32) f32 {
	return f32(stdmath.sin(f64(v)))
}

pub fn cosf(v f32) f32 {
	return f32(stdmath.cos(f64(v)))
}

pub fn tanf(v f32) f32 {
	return f32(stdmath.tan(f64(v)))
}

pub fn floorf(v f32) f32 {
	return f32(stdmath.floor(f64(v)))
}
