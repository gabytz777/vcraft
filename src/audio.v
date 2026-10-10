module audio

import math

// Sound effects, synthesised in V and played through SDL2's audio queue.
//
// There are no audio files: every cue is a short procedurally generated
// waveform (filtered noise and tones), matching how the textures and the
// font are generated. SDL2 is already a dependency of the game, so this
// adds no new library.

#flag -lSDL2
#include <SDL2/SDL.h>

fn C.SDL_InitSubSystem(flags u32) i32
fn C.SDL_OpenAudioDevice(name &char, capture i32, want &C.SDL_AudioSpec, have &C.SDL_AudioSpec, changes i32) u32
fn C.SDL_PauseAudioDevice(dev u32, pause i32) i32
fn C.SDL_QueueAudio(dev u32, data voidptr, len u32) i32
fn C.SDL_GetQueuedAudioSize(dev u32) u32

// Mirrors the C SDL_AudioSpec so we can describe the format we want without
// a header-parsing step (V 0.5.2 cannot read struct layouts from headers).
struct C.SDL_AudioSpec {
	freq      int
	format    u16
	channels  u8
	silence   u8
	samples   u16
	padding   u16
	size      u32
	callback  voidptr
	user_data voidptr
}

const sample_rate = 48000
const fmt_s16 = u16(0x8010) // AUDIO_S16LSB

__global (
	g_dev    u32
	g_volume f32 = 0.7
	g_break  []i16
	g_place  []i16
	g_step   []i16
	g_jump   []i16
	g_land   []i16
	g_splash []i16
	g_click  []i16
)

fn xorshift(x u32) u32 {
	mut v := x
	v ^= v << 13
	v ^= v >> 17
	v ^= v << 5
	return v
}

fn clamp_f(v f32, lo f32, hi f32) f32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// One short one-shot: an exponential-decay envelope over a sine tone mixed
// with xorshift noise. `noise_amt` 0 is a pure tone, 1 is pure noise.
fn synth(dur f32, seed u32, base_hz f32, noise_amt f32, decay f32) []i16 {
	n := int(dur * f32(sample_rate))
	mut out := []i16{len: n}
	mut s := seed
	mut phase := f32(0.0)
	mut i := 0
	for i < n {
		t := f32(i) / f32(sample_rate)
		env := f32(math.exp(-f64(t) * f64(decay)))
		s = xorshift(s)
		nf := (f32(s & 0xffff) / f32(32768.0)) - 1.0
		phase += base_hz / f32(sample_rate)
		if phase > 1.0 {
			phase -= 1.0
		}
		tone := f32(math.sin(f64(phase) * 2.0 * math.pi))
		v := (tone * (1.0 - noise_amt) + nf * noise_amt) * env
		out[i] = i16(v * 26000.0)
		i++
	}
	return out
}

fn build_sounds() {
	g_break = synth(0.20, 0x12345, 110.0, 0.85, 14.0)
	g_place = synth(0.12, 0x9abc1, 190.0, 0.55, 22.0)
	g_step = synth(0.06, 0x555a1, 95.0, 0.90, 42.0)
	g_jump = synth(0.11, 0x2c0de, 320.0, 0.15, 24.0)
	g_land = synth(0.13, 0x77aa1, 120.0, 0.70, 20.0)
	g_splash = synth(0.28, 0xbeef1, 210.0, 1.00, 9.0)
	g_click = synth(0.045, 0xc0ffee, 880.0, 0.0, 70.0)
}

// Build the waveforms always (so the self-test can check them); open an
// audio device only when asked, and stay silent if there is none.
pub fn init(vol f32, with_device bool) {
	g_volume = clamp_f(vol, 0.0, 1.0)
	build_sounds()
	if !with_device {
		return
	}
	if unsafe { C.SDL_InitSubSystem(u32(0x10)) } != 0 { // SDL_INIT_AUDIO
		return
	}
	mut want := C.SDL_AudioSpec{
		freq:     sample_rate
		format:   fmt_s16
		channels: 1
		samples:  1024
	}
	mut have := C.SDL_AudioSpec{}
	g_dev = C.SDL_OpenAudioDevice(unsafe { nil }, 0, &want, &have, 0)
	if g_dev == 0 {
		return
	}
	C.SDL_PauseAudioDevice(g_dev, 0)
}

pub fn available() bool {
	return g_dev != 0
}

pub fn set_volume(v f32) {
	g_volume = clamp_f(v, 0.0, 1.0)
}

// Current mixer volume, so the settings menu can be checked against the
// value the audio layer actually holds.
pub fn volume() f32 {
	return g_volume
}

// Queue one voice, dropping it if a lot is already pending so latency can
// never run away when many cues fire at once.
fn push(s []i16, gain f32) {
	if g_dev == 0 || s.len == 0 {
		return
	}
	if C.SDL_GetQueuedAudioSize(g_dev) > u32(sample_rate / 6) {
		return
	}
	v := clamp_f(g_volume * gain, 0.0, 1.0)
	mut buf := []i16{len: s.len}
	mut i := 0
	for i < s.len {
		buf[i] = i16(f32(s[i]) * v)
		i++
	}
	C.SDL_QueueAudio(g_dev, unsafe { &buf[0] }, u32(buf.len * 2))
}

pub fn play_break() {
	push(g_break, 1.0)
}

pub fn play_place() {
	push(g_place, 0.9)
}

pub fn play_step() {
	push(g_step, 0.5)
}

pub fn play_jump() {
	push(g_jump, 0.6)
}

pub fn play_land() {
	push(g_land, 0.7)
}

pub fn play_splash() {
	push(g_splash, 0.8)
}

pub fn play_click() {
	push(g_click, 0.6)
}

// Lengths of the generated cues, for the headless self-test.
pub fn sample_counts() [7]int {
	return [g_break.len, g_place.len, g_step.len, g_jump.len, g_land.len, g_splash.len, g_click.len]
}
