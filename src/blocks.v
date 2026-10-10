module blocks

pub const (
	air      = u8(0)
	stone    = u8(1)
	grass    = u8(2)
	dirt     = u8(3)
	cobble   = u8(4)
	planks   = u8(5)
	sand     = u8(6)
	log      = u8(7)
	leaves   = u8(8)
	water    = u8(9)
	bedrock  = u8(10)
	gravel   = u8(11)
	gold     = u8(12)
	glow     = u8(13)
	white    = u8(14)
	snow     = u8(15)
	obsidian = u8(16)
	tall_grass = u8(17)
)

// Texture-array layer indices (must match generation order in texture.v)
pub const (
	t_grass_top  = i32(0)
	t_grass_side = i32(1)
	t_dirt       = i32(2)
	t_stone      = i32(3)
	t_cobble     = i32(4)
	t_planks     = i32(5)
	t_sand       = i32(6)
	t_log_side   = i32(7)
	t_log_top    = i32(8)
	t_leaves     = i32(9)
	t_water      = i32(10)
	t_bedrock    = i32(11)
	t_gravel     = i32(12)
	t_gold       = i32(13)
	t_glow       = i32(14)
	t_white      = i32(15)
	t_snow       = i32(16)
	t_obsidian   = i32(17)
	t_grass_plant = i32(18)
)

pub const layer_count = 19

// Per-block face layers in the order +X -X +Y -Y +Z -Z
pub struct BlockDef {
pub:
	name     string
	solid    bool
	opaque   bool // blocks light / culls neighbouring faces
	light    f32 // emitted light 0..1
	liquid   bool
	sides    [6]i32
	// Seconds of held mining to break. Negative means unbreakable.
	hardness f32
}

// No block is unbreakable by default.
pub const unbreakable = f32(-1.0)

pub fn def(b u8) BlockDef {
	return match b {
		stone    { BlockDef{'Stone', true, true, 0.0, false, [3, 3, 3, 3, 3, 3], 1.5} }
		grass    { BlockDef{'Grass', true, true, 0.0, false, [t_grass_side, t_grass_side, t_grass_top, t_dirt, t_grass_side, t_grass_side], 0.6} }
		dirt     { BlockDef{'Dirt', true, true, 0.0, false, [2, 2, 2, 2, 2, 2], 0.5} }
		cobble   { BlockDef{'Cobblestone', true, true, 0.0, false, [4, 4, 4, 4, 4, 4], 1.7} }
		planks   { BlockDef{'Planks', true, true, 0.0, false, [5, 5, 5, 5, 5, 5], 0.9} }
		sand     { BlockDef{'Sand', true, true, 0.0, false, [6, 6, 6, 6, 6, 6], 0.5} }
		log      { BlockDef{'Oak Log', true, true, 0.0, false, [t_log_side, t_log_side, t_log_top, t_log_top, t_log_side, t_log_side], 1.0} }
		leaves   { BlockDef{'Leaves', true, false, 0.0, false, [t_leaves, t_leaves, t_leaves, t_leaves, t_leaves, t_leaves], 0.2} }
		water    { BlockDef{'Water', false, false, 0.0, true, [t_water, t_water, t_water, t_water, t_water, t_water], unbreakable} }
		bedrock  { BlockDef{'Bedrock', true, true, 0.0, false, [11, 11, 11, 11, 11, 11], unbreakable} }
		gravel   { BlockDef{'Gravel', true, true, 0.0, false, [12, 12, 12, 12, 12, 12], 0.6} }
		gold     { BlockDef{'Gold Ore', true, true, 0.35, false, [13, 13, 13, 13, 13, 13], 2.2} }
		glow     { BlockDef{'Glowstone', true, true, 0.85, false, [14, 14, 14, 14, 14, 14], 0.5} }
		white    { BlockDef{'White Block', true, true, 0.0, false, [15, 15, 15, 15, 15, 15], 1.2} }
		snow     { BlockDef{'Snow', true, true, 0.0, false, [t_snow, t_snow, t_snow, t_snow, t_snow, t_snow], 0.3} }
		obsidian { BlockDef{'Obsidian', true, true, 0.0, false, [17, 17, 17, 17, 17, 17], 8.0} }
		tall_grass { BlockDef{'Tall Grass', false, false, 0.0, false, [t_grass_plant, t_grass_plant, t_grass_plant, t_grass_plant, t_grass_plant, t_grass_plant], 0.05} }
		else     { BlockDef{'Air', false, false, 0.0, false, [0, 0, 0, 0, 0, 0], unbreakable} }
	}
}

pub fn hardness(b u8) f32 {
	return def(b).hardness
}

pub fn is_solid(b u8) bool {
	return def(b).solid
}

pub fn is_opaque(b u8) bool {
	return def(b).opaque
}

pub fn is_liquid(b u8) bool {
	return def(b).liquid
}

pub fn light_of(b u8) f32 {
	return def(b).light
}

// Blocks the player can select in the hotbar. Individual consts, not the
// `[u8(a, b, ...)]` multi-cast form: V 0.5.2 appends a phantom trailing 0
// to that, which would put an unplaceable air slot at the end.
pub const hotbar = [grass, dirt, stone, cobble, planks, log, leaves, sand,
	gravel, glow, white, snow, obsidian, gold, bedrock, water]
