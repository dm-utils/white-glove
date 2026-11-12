class_name CleanSim
extends RefCounted
## The rules of White Glove (phase 2): pure, deterministic, integer-only, the same pattern as the other games.
## Input: one command per hero seat per tick ({m: move angle, a: action angle, s: trick angle, sd: distance}).
## Action does what fits: catch a crook in reach, else empty your hands into the bin you stand at, else pick up the
## nearest litter. Crooks are part of the world (not players): they roam, drop litter, run from heroes; a caught
## crook helps the team that caught it for a while. Two teams of 3, 3 minutes, most points wins.
## Units: milli-tiles, ticks (30/s), angles 0..4095.

const TILE := 1000
const WALL := 0
const PAPER := 0
const ROAM := 0
const HELP := 1 # a caught crook helping a team
const AWAY := 2 # gone for a bit after helping
const HERO_FIELDS := ["id", "team", "x", "y", "carry_0", "carry_1", "carry_2", "cooldown", "trick_cd", "sprint", "aim",
	"points", "catches", "is_bot", "goal_x", "goal_y", "next_think", "role"]
const CROOK_FIELDS := ["x", "y", "state", "team", "timer", "drop", "freeze", "goal_x", "goal_y"]
const LITTER_FIELDS := ["kind", "x", "y"]

static var _rules: Dictionary
static var _maps: Dictionary = {}


class Hero:
	var id := 0
	var team := 0
	var x := 0
	var y := 0
	var carry_0 := 0 # paper in hand
	var carry_1 := 0 # plastic
	var carry_2 := 0 # rest
	var cooldown := 0
	var trick_cd := 0
	var sprint := 0
	var aim := 0
	var points := 0
	var catches := 0
	var is_bot := 0
	var goal_x := 0
	var goal_y := 0
	var next_think := 0
	var role := 0 # bots: 0 chaser, 1 collector


class Crook:
	var x := 0
	var y := 0
	var state := ROAM
	var team := -1 # helping this team
	var timer := 0
	var drop := 0
	var freeze := 0
	var goal_x := 0
	var goal_y := 0


class Litter:
	var kind := 0
	var x := 0
	var y := 0


var seed_value := 0
var tick := 0
var rng: SimRng
var rules: Dictionary
var width := 0
var height := 0
var tiles := PackedByteArray()
var stations: Array = [] # [x, y] of the paper bin (milli-tiles); plastic +1 tile, rest +2 tiles
var ents: Array = [] # heroes, one per seat (Rollback reads ents[s].is_bot)
var crooks: Array = []
var litter: Array = []
var score_0 := 0
var score_1 := 0
var dropped := 0 # litter dropped by crooks so far (for "how clean did it stay")
var wind := 0 # angle the wind blows paper to (from the seed)
var finished := 0
var events: Array = []
var characters: Array = [] # hero config per seat
var _map: Dictionary


static func load_config() -> void:
	if _rules.is_empty():
		_rules = Content.load_json("res://data/clean_rules.json")


static func map_data(name: String) -> Dictionary:
	if not _maps.has(name):
		_maps[name] = Content.load_json("res://data/maps/%s.json" % name)
	return _maps[name]


func _init(p_seed: int, entrants: Array) -> void:
	load_config()
	rules = _rules
	seed_value = p_seed
	rng = SimRng.new(p_seed)
	_map = map_data(str(rules.map))
	width = int(_map.width)
	height = int(_map.height)
	for v in _map.tiles:
		tiles.append(int(v))
	for st in _map.stations:
		stations.append([int(st[0]) * TILE + TILE / 2, int(st[1]) * TILE + TILE / 2])
	wind = rng.range_i(Fx.ANGLES)
	for i in entrants.size():
		characters.append(Content.character(str(entrants[i])))
		var h := Hero.new()
		h.id = i
		h.team = i % 2
		var sp: Array = _map.team_spawns[h.team][(i / 2) % 3]
		h.x = int(sp[0]) * TILE + TILE / 2
		h.y = int(sp[1]) * TILE + TILE / 2
		h.goal_x = h.x
		h.goal_y = h.y
		h.role = 0 if i / 2 == 0 else 1
		ents.append(h)
	for i in int(rules.crooks.start):
		_spawn_crook()
	for i in int(rules.litter.start):
		_drop_random(PAPER + rng.range_i(3))


# --- queries ---

func tile_at(x: int, y: int) -> int:
	return tiles[clampi(y / TILE, 0, height - 1) * width + clampi(x / TILE, 0, width - 1)]


func walkable(x: int, y: int) -> bool:
	return tile_at(x, y) != WALL


func carried(h: Hero) -> int:
	return h.carry_0 + h.carry_1 + h.carry_2


## Which bin (station index, kind) a point is at, or [-1, -1].
func bin_at(x: int, y: int) -> Array:
	var reach := int(rules.bin_reach)
	var best := [-1, -1]
	var bd := reach * reach + 1
	for i in stations.size():
		for k in 3:
			var d := _d2(stations[i][0] + k * TILE - x, stations[i][1] - y)
			if d < bd:
				bd = d
				best = [i, k]
	return best


func seconds_left() -> int:
	return maxi(0, int(rules.match_ticks) - tick) / 30


# --- the tick ---

func step(cmds: Array) -> void:
	events.clear()
	if finished:
		return
	tick += 1
	for h in ents:
		_update_hero(h, cmds[h.id] if h.id < cmds.size() and cmds[h.id] is Dictionary else {})
	for c in crooks:
		_update_crook(c)
	_wind()
	var cr: Dictionary = rules.crooks
	if tick % int(cr.every_ticks) == 0 and crooks.size() < int(cr.max):
		_spawn_crook()
	if tick >= int(rules.match_ticks):
		_finish()


func _update_hero(h: Hero, cmd: Dictionary) -> void:
	if h.cooldown > 0:
		h.cooldown -= 1
	if h.trick_cd > 0:
		h.trick_cd -= 1
	if h.sprint > 0:
		h.sprint -= 1
	var m := int(cmd.get("m", -1))
	if m >= 0:
		var sp := int(rules.speed.hero)
		if h.sprint > 0:
			sp = sp * int(rules.tricks.runner.speed_pct) / 100
		_move(h, m, sp)
		h.aim = m
	var a := int(cmd.get("a", -1))
	if a >= 0 and h.cooldown == 0:
		h.cooldown = int(rules.action_cooldown_ticks)
		_action(h)
	var s := int(cmd.get("s", -1))
	if s >= 0 and h.trick_cd == 0:
		h.trick_cd = int(rules.tricks.cooldown_ticks)
		_trick(h, posmod(s, Fx.ANGLES))


## Moves with walls: each axis on its own, so you slide along a house. A body is `radius` wide to each side (so the
## sprite never stands half inside a house), only a little behind the feet when walking up to a house's front wall.
func _move(o, ang: int, sp: int) -> void:
	var r := int(rules.radius)
	var dx: int = Fx.cos_a(ang) * sp / Fx.ONE
	var dy: int = Fx.sin_a(ang) * sp / Fx.ONE
	var nx: int = o.x + dx
	var ny: int = o.y + dy
	var ex := signi(dx) * r
	if dx != 0 and walkable(nx + ex, o.y) and walkable(nx + ex, o.y - r / 2):
		o.x = clampi(nx, 500, width * TILE - 500)
	var ey := r if dy < 0 else r / 4
	if dy != 0 and walkable(o.x, ny + signi(dy) * ey) and walkable(o.x - r, ny + signi(dy) * ey) and walkable(o.x + r, ny + signi(dy) * ey):
		o.y = clampi(ny, 500, height * TILE - 500)


func _action(h: Hero) -> void:
	var reach := int(rules.reach)
	# 1. a crook in reach: catch it
	var c := _nearest_crook(h.x, h.y, reach)
	if c != null:
		_catch(h, c)
		return
	# 2. at a bin with something in your hands: throw it all in
	if carried(h) > 0:
		var b := bin_at(h.x, h.y)
		if b[0] >= 0:
			var pts: Dictionary = rules.points
			var gained := 0
			for k in 3:
				var n: int = h.get("carry_%d" % k)
				gained += n * (int(pts.right_bin) if k == b[1] else int(pts.wrong_bin))
				h.set("carry_%d" % k, 0)
			_score(h.team, gained)
			h.points += gained
			events.append({"type": "bin", "id": h.id, "kind": b[1], "points": gained})
			return
	# 3. pick up the nearest litter in reach
	if carried(h) < int(rules.carry_max):
		var li := _nearest_litter(h.x, h.y, reach)
		if li >= 0:
			var l: Litter = litter[li]
			h.set("carry_%d" % l.kind, int(h.get("carry_%d" % l.kind)) + 1)
			litter.remove_at(li)
			events.append({"type": "pick", "id": h.id, "kind": l.kind})


func _catch(h: Hero, c: Crook) -> void:
	c.state = HELP
	c.team = h.team
	c.timer = int(rules.crooks.help_ticks)
	c.freeze = 0
	h.catches += 1
	var pts := int(rules.points.catch)
	h.points += pts
	_score(h.team, pts)
	events.append({"type": "catch", "id": h.id, "x": c.x, "y": c.y})


func _trick(h: Hero, ang: int) -> void:
	var tr: Dictionary = rules.tricks
	var kind := str(characters[h.id].get("id", "runner"))
	match kind:
		"runner":
			h.sprint = int(tr.runner.ticks)
		"netter":
			# the net flies in the aimed direction: the first roaming crook on that line within range is caught
			var best: Crook = null
			var bd := 0
			for c in crooks:
				if c.state != ROAM:
					continue
				var dx: int = c.x - h.x
				var dy: int = c.y - h.y
				var d := Fx.dist(dx, dy)
				if d <= int(tr.netter.range) and absi(Fx.angle_diff(Fx.atan2_a(dy, dx), ang)) < 300 and (best == null or d < bd):
					best = c
					bd = d
			if best != null:
				_catch(h, best)
		"whistler":
			for c in crooks:
				if c.state == ROAM and Fx.dist(c.x - h.x, c.y - h.y) <= int(tr.whistler.range):
					c.freeze = int(tr.whistler.freeze_ticks)
		"dogwalker":
			var c := _nearest_crook(h.x, h.y, int(tr.dogwalker.range))
			if c != null:
				c.freeze = int(tr.dogwalker.hold_ticks)
	events.append({"type": "trick", "id": h.id, "kind": kind})


func _update_crook(c: Crook) -> void:
	var cr: Dictionary = rules.crooks
	match c.state:
		AWAY:
			c.timer -= 1
			if c.timer <= 0:
				var sp: Array = _map.crook_spawns[rng.range_i(_map.crook_spawns.size())]
				c.x = int(sp[0]) * TILE + TILE / 2
				c.y = int(sp[1]) * TILE + TILE / 2
				c.state = ROAM
				c.team = -1
				_new_goal(c)
			return
		HELP:
			c.timer -= 1
			if c.timer <= 0:
				c.state = AWAY # "does better from now on": leaves the street for a while
				c.timer = int(cr.respawn_ticks)
				events.append({"type": "crook_leaves", "x": c.x, "y": c.y})
				return
			# walks to the nearest litter and picks it up for its team
			var li := _nearest_litter(c.x, c.y, 1 << 30)
			if li >= 0:
				var l: Litter = litter[li]
				var dx: int = l.x - c.x
				var dy: int = l.y - c.y
				if Fx.dist(dx, dy) <= int(rules.reach):
					litter.remove_at(li)
					_score(c.team, int(rules.points.helper_pick))
					events.append({"type": "helper_pick", "team": c.team})
				else:
					_move(c, Fx.atan2_a(dy, dx), int(rules.speed.helper))
			return
	# roaming: frozen, fleeing from a hero close by, or walking to its goal; drops litter now and then
	if c.freeze > 0:
		c.freeze -= 1
		return
	var flee := int(cr.flee_range)
	var near: Hero = null
	var nd := flee * flee + 1
	for h in ents:
		var d := _d2(h.x - c.x, h.y - c.y)
		if d < nd:
			nd = d
			near = h
	if near != null:
		var away := Fx.atan2_a(c.y - near.y, c.x - near.x) + rng.between(-300, 300)
		_move(c, posmod(away, Fx.ANGLES), int(rules.speed.crook_flee))
	else:
		var gx := c.goal_x - c.x
		var gy := c.goal_y - c.y
		if Fx.dist(gx, gy) < 400:
			_new_goal(c)
		else:
			_move(c, Fx.atan2_a(gy, gx), int(rules.speed.crook))
	c.drop -= 1
	if c.drop <= 0:
		c.drop = int(cr.drop_every_ticks) + rng.range_i(30)
		if litter.size() < int(rules.litter.max):
			var l := Litter.new()
			l.kind = rng.range_i(3)
			l.x = c.x
			l.y = c.y
			litter.append(l)
			dropped += 1
			events.append({"type": "drop", "x": c.x, "y": c.y, "kind": l.kind})


func _new_goal(c: Crook) -> void:
	for i in 20:
		var x := 1000 + rng.range_i((width - 2) * TILE)
		var y := 1000 + rng.range_i((height - 2) * TILE)
		var r := int(rules.radius)
		if walkable(x, y) and walkable(x - r, y - r) and walkable(x + r, y - r) and walkable(x - r, y + r) and walkable(x + r, y + r):
			c.goal_x = x
			c.goal_y = y
			return


## Paper blows a little with the wind every so often (never into a house).
func _wind() -> void:
	var lr: Dictionary = rules.litter
	if tick % int(lr.wind_every_ticks) != 0:
		return
	var step := int(lr.wind_step)
	for l in litter:
		if l.kind == PAPER:
			var nx: int = l.x + Fx.cos_a(wind) * step / Fx.ONE
			var ny: int = l.y + Fx.sin_a(wind) * step / Fx.ONE
			if walkable(nx, ny) and nx > 500 and ny > 500 and nx < width * TILE - 500 and ny < height * TILE - 500:
				l.x = nx
				l.y = ny


func _spawn_crook() -> void:
	var c := Crook.new()
	var sp: Array = _map.crook_spawns[crooks.size() % _map.crook_spawns.size()]
	c.x = int(sp[0]) * TILE + TILE / 2
	c.y = int(sp[1]) * TILE + TILE / 2
	c.drop = int(rules.crooks.drop_every_ticks)
	_new_goal(c)
	crooks.append(c)
	events.append({"type": "crook", "x": c.x, "y": c.y})


func _drop_random(kind: int) -> void:
	for i in 20:
		var x := 1000 + rng.range_i((width - 2) * TILE)
		var y := 1000 + rng.range_i((height - 2) * TILE)
		if walkable(x, y):
			var l := Litter.new()
			l.kind = kind % 3
			l.x = x
			l.y = y
			litter.append(l)
			return


func _nearest_crook(x: int, y: int, reach: int) -> Crook:
	var best: Crook = null
	var bd := reach * reach + 1
	for c in crooks:
		if c.state != ROAM:
			continue
		var d := _d2(c.x - x, c.y - y)
		if d < bd:
			bd = d
			best = c
	return best


func _nearest_litter(x: int, y: int, reach: int) -> int:
	var best := -1
	var bd := reach * reach + 1 if reach < (1 << 20) else (1 << 62)
	for i in litter.size():
		var d := _d2(litter[i].x - x, litter[i].y - y)
		if d < bd:
			bd = d
			best = i
	return best


func _score(team: int, n: int) -> void:
	if team == 0:
		score_0 += n
	elif team == 1:
		score_1 += n


func _finish() -> void:
	finished = 1
	for h in ents: # 1 won, 2 draw, 3 lost
		var mine := score_0 if h.team == 0 else score_1
		var theirs := score_1 if h.team == 0 else score_0
		_places[h.id] = 1 if mine > theirs else (2 if mine == theirs else 3)
	events.append({"type": "finished"})


var _places := {}


## [{id, character, team, points, place}] (place 1 won, 2 draw, 3 lost; valid once finished).
func result() -> Array:
	var out: Array = []
	for h in ents:
		out.append({"id": h.id, "character": str(characters[h.id].get("id", "")), "team": h.team, "points": h.points,
			"catches": h.catches, "place": int(_places.get(h.id, 0))})
	return out


static func _d2(dx: int, dy: int) -> int:
	return dx * dx + dy * dy


# --- determinism ---

static func _mix(h: int, v: int) -> int:
	var u := v & 0xFFFFFFFF
	for i in 4:
		h ^= (u >> (i * 8)) & 0xFF
		h = (h * 16777619) & 0xFFFFFFFF
	return h


func state_hash() -> int:
	var h := 2166136261
	for v in [tick, rng.state, score_0, score_1, dropped, wind, finished, ents.size(), crooks.size(), litter.size()]:
		h = _mix(h, v)
	for e in ents:
		for f in HERO_FIELDS:
			h = _mix(h, int(e.get(f)))
	for c in crooks:
		for f in CROOK_FIELDS:
			h = _mix(h, int(c.get(f)))
	for l in litter:
		for f in LITTER_FIELDS:
			h = _mix(h, int(l.get(f)))
	return h


func snapshot() -> Dictionary:
	var out := {"tick": tick, "rng": rng.state, "score_0": score_0, "score_1": score_1, "dropped": dropped, "wind": wind,
		"finished": finished, "places": _places.duplicate(), "ents": [], "crooks": [], "litter": []}
	for pair in [["ents", ents, HERO_FIELDS], ["crooks", crooks, CROOK_FIELDS], ["litter", litter, LITTER_FIELDS]]:
		for o in pair[1]:
			var d := {}
			for f in pair[2]:
				d[f] = o.get(f)
			out[pair[0]].append(d)
	return out


func restore(s: Dictionary) -> void:
	tick = int(s.tick)
	rng.state = int(s.rng)
	score_0 = int(s.score_0)
	score_1 = int(s.score_1)
	dropped = int(s.dropped)
	wind = int(s.wind)
	finished = int(s.finished)
	_places = (s.places as Dictionary).duplicate()
	for i in ents.size():
		for f in HERO_FIELDS:
			ents[i].set(f, int(s.ents[i][f]))
	crooks = []
	for d in s.crooks:
		var c := Crook.new()
		for f in CROOK_FIELDS:
			c.set(f, int(d[f]))
		crooks.append(c)
	litter = []
	for d in s.litter:
		var l := Litter.new()
		for f in LITTER_FIELDS:
			l.set(f, int(d[f]))
		litter.append(l)
