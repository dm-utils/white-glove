class_name CleanBrain
extends RefCounted
## White Glove hero bots (phase 2). Same rules as the other games: they run inside the sim tick with the sim's RNG
## and keep their memory on the hero, so they are deterministic. Two roles per team: the chaser goes after the nearest
## roaming crook (and uses its trick on it); collectors pick up the nearest litter and bring full hands to the bin
## that fits most of what they carry.

static var _levels: Dictionary = {}


static func level_config(name: String) -> Dictionary:
	if _levels.is_empty():
		_levels = Content.load_json("res://data/clean_bots.json").levels
	return _levels.get(name, _levels.normal)


static func think(sim: CleanSim, h: CleanSim.Hero, cfg: Dictionary) -> Dictionary:
	var cmd := {"m": -1, "a": -1, "s": -1}
	if sim.tick >= h.next_think:
		h.next_think = sim.tick + int(cfg.think_ticks) + sim.rng.range_i(4)
		_plan(sim, h, cfg)
	var gx := h.goal_x - h.x
	var gy := h.goal_y - h.y
	var d := Fx.dist(gx, gy)
	if d > 250:
		cmd.m = Fx.atan2_a(gy, gx)
	# act when there is something to act on in reach: a crook, a bin with full hands, litter
	if d < int(sim.rules.reach) + 200 and h.cooldown == 0:
		cmd.a = 0
	# trick: on the chaser's crook when it is close enough to matter
	if h.trick_cd == 0 and h.role == 0 and d < 3000 and sim.rng.range_i(100) < int(cfg.trick_pct):
		cmd.s = Fx.atan2_a(gy, gx)
	return cmd


static func _plan(sim: CleanSim, h: CleanSim.Hero, cfg: Dictionary) -> void:
	var full := sim.carried(h) >= int(sim.rules.carry_max)
	if h.role == 0 and not full:
		var c := _nearest_crook(sim, h, int(cfg.chase_range))
		if c != null:
			h.goal_x = c.x
			h.goal_y = c.y
			return
	if full or (sim.carried(h) > 0 and sim.litter.is_empty()):
		var b := _best_bin(sim, h)
		h.goal_x = b.x
		h.goal_y = b.y
		return
	var li := sim._nearest_litter(h.x, h.y, 1 << 30)
	if li >= 0:
		h.goal_x = sim.litter[li].x
		h.goal_y = sim.litter[li].y
		return
	var c2 := _nearest_crook(sim, h, 1 << 20) # nothing to pick up: help catch
	if c2 != null:
		h.goal_x = c2.x
		h.goal_y = c2.y


static func _nearest_crook(sim: CleanSim, h: CleanSim.Hero, reach: int) -> CleanSim.Crook:
	return sim._nearest_crook(h.x, h.y, reach)


## The bin for the kind you carry most of, at the station nearest to you.
static func _best_bin(sim: CleanSim, h: CleanSim.Hero) -> Vector2i:
	var kind := 0
	for k in 3:
		if int(h.get("carry_%d" % k)) > int(h.get("carry_%d" % kind)):
			kind = k
	var best := Vector2i(h.x, h.y)
	var bd := -1
	for st in sim.stations:
		var x: int = st[0] + kind * CleanSim.TILE
		var y: int = st[1]
		var d := CleanSim._d2(x - h.x, y - h.y)
		if bd < 0 or d < bd:
			bd = d
			best = Vector2i(x, y)
	return best
