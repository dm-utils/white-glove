extends Node2D
## A White Glove match on screen (phase 3). Reads the sim, never changes it: input becomes a command per tick, the
## sim steps at 30 Hz, the view interpolates. The neighbourhood is drawn once from the tiles; litter, bins, heroes
## and crooks are SVG sprites from tools/art.
## Debug entry: --scene=game --seed=N [--character=runner] [--bots=easy|normal|hard]

const PX := 0.08 # screen pixels per milli-tile: 80 px per tile
const TP := 80.0
const DT := 1.0 / 30.0
const MAX_STEPS := 3
const RESULT_SCENE := "res://ui/result_screen.tscn"
const PERSON_SCALE := 0.7 # 200 x 240 SVG -> 140 x 168 px
const CROOK_SCALE := 0.64
const LITTER_SCALE := 1.0 # the pieces fill ~60 of 200 px: ~60 px on screen, >= 30 px on a 960 x 540 screen
const BIN_SCALE := 0.62
const KINDS := ["paper", "plastic", "rest"]
const KIND_COLORS := [Color("2F5DA8"), Color("F2C230"), Color("7A828C")] # as the bins (tools/art/props.py)
const TEAM_COLORS := [Color("3F8CFF"), Color("FF8A3D")]
const INK := Color("2B3A4A")
const ROOFS := [Color("C4553F"), Color("D9825B"), Color("8E9BB0"), Color("6F9E7F")]
const WALL := Color("F1E3C8")
const ASPHALT := Color("6B7380")
const PAVEMENT := Color("DCD6CA")
const GRASS := Color("9DBF5A")
const SQUARE := Color("E3B38C")
const HEDGE := Color("4F7A3A")
const TRICK_RANGE := {"netter": 3200, "whistler": 4000, "dogwalker": 6500}

var m: CleanMatch
var ground: Node2D # the tiles, drawn once (z -2)
var marks: Node2D # team rings, shadows, trick waves (z -1)
var litter_layer: Node2D # litter on the ground (z 0)
var actors: Node2D # bins, heroes and crooks, sorted by y (z 1)
var overlay: Node2D # stars, carried dots, floating points, your marker (z 2)
var cam: Camera2D
var hud: Control
var controls := "keys" # keys | mouse | touch
var touch: TouchControls
var rb: Rollback # online: the rollback driving the match
var net: OnlineClient # online: the room connection

var _heroes := {} # seat -> Sprite2D
var _crooks: Array[Sprite2D] = []
var _litter: Array[Sprite2D] = []
var _prev := {} # "h<seat>" / "c<index>" -> Vector2 (milli-tiles) of the previous tick
var _hop := {} # crook index -> seconds left of the "caught!" jump
var _face := {} # crook index -> 1 or -1
var _waves: Array = [] # {pos, radius, color, t}
var _floats: Array = [] # {pos, text, color, t}
var _textures := {}
var _labels := {}
var _hands: Array[Label] = []
var _trick_btn: Button
var _trick_pending := false
var _acc := 0.0
var _t := 0.0
var _ending := -1.0
var _msg := ""
var _msg_t := 0.0
var _warned := false
var _my_carry := [0, 0, 0]
var _online_started := false
var _next_hash := Rollback.HASH_EVERY - 1


func _ready() -> void:
	Platform.entered("game")
	var profile: Dictionary = Platform.load_profile()
	var seed_value := Boot.seed_value() if Boot.seed_value() != 0 else randi() % 2000000000 + 1
	var who := str(Boot.args.get("character", profile.get("selected_character", "runner")))
	if not CleanMatch.HEROES.has(who):
		who = "runner"
	m = CleanMatch.create(seed_value, who, 6, str(Boot.args.get("bots", "normal")))
	var plan: Dictionary = Boot.next_match
	Boot.next_match = {}
	if plan.has("online"):
		_start_online(plan.online)
	var s := m.sim
	ground = Node2D.new()
	ground.z_index = -2
	ground.draw.connect(_draw_ground)
	add_child(ground)
	marks = Node2D.new()
	marks.z_index = -1
	marks.draw.connect(_draw_marks)
	add_child(marks)
	litter_layer = Node2D.new()
	add_child(litter_layer)
	actors = Node2D.new()
	actors.y_sort_enabled = true
	actors.z_index = 1
	add_child(actors)
	for st in s.stations:
		for k in 3:
			var b := _sprite("bin_" + KINDS[k], Vector2(0, -50), BIN_SCALE)
			b.position = Vector2(int(st[0]) + k * CleanSim.TILE, int(st[1])) * PX
			actors.add_child(b)
	for e in s.ents:
		var c := _sprite_file("res://assets/people/%s.svg" % str(s.characters[e.id].get("id", "runner")), Vector2(0, -80), PERSON_SCALE)
		actors.add_child(c)
		_heroes[e.id] = c
		_prev["h%d" % e.id] = Vector2(e.x, e.y)
	overlay = Node2D.new()
	overlay.z_index = 2
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)
	cam = Camera2D.new()
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = int(s.width * TP)
	cam.limit_bottom = int(s.height * TP)
	add_child(cam)
	cam.make_current()
	cam.position = _hero_pos(s.ents[m.human])
	_build_hud()
	_sync_sprites()
	_update_hud()
	if rb == null:
		_say(tr("CLEAN_START"), 2.2)
		Sfx.play("whistle")


func _texture(path: String) -> Texture2D:
	if not _textures.has(path):
		_textures[path] = load(path)
	return _textures[path]


func _sprite(prop: String, offset: Vector2, k: float) -> Sprite2D:
	return _sprite_file("res://assets/props/%s.svg" % prop, offset, k)


func _sprite_file(path: String, offset: Vector2, k: float) -> Sprite2D:
	var sp := Sprite2D.new()
	sp.texture = _texture(path)
	sp.offset = offset
	sp.scale = Vector2.ONE * k
	return sp


# --- loop ---

func _process(delta: float) -> void:
	_t += delta
	_msg_t -= delta
	if _ending < 0.0:
		_acc += delta
		var steps := 0
		while _acc >= DT and steps < MAX_STEPS:
			if rb != null:
				if not _online_step():
					break # waiting for the start, or for someone's input
			else:
				_remember()
				m.step(_command())
			_handle_events()
			_acc -= DT
			steps += 1
		if steps == MAX_STEPS:
			_acc = 0.0
		if m.finished():
			_ending = 2.0
	else:
		_ending -= delta
		if _ending <= 0.0:
			if net != null:
				net.close()
			Boot.last_result = m.human_result()
			get_tree().change_scene_to_file(RESULT_SCENE)
			return
	for k in _hop.keys():
		_hop[k] = float(_hop[k]) - delta
	_waves = _waves.filter(func(w: Dictionary) -> bool: return float(w.t) < 0.6)
	for w in _waves:
		w.t = float(w.t) + delta
	_floats = _floats.filter(func(f: Dictionary) -> bool: return float(f.t) < 1.2)
	for f in _floats:
		f.t = float(f.t) + delta
	_sync_sprites()
	cam.position = cam.position.lerp(_hero_pos(m.sim.ents[m.human]), minf(1.0, delta * 6.0))
	_update_hud()
	marks.queue_redraw()
	overlay.queue_redraw()


## Positions before the tick, so the view can slide between ticks; also your hands, to tell right from wrong bins.
func _remember() -> void:
	var s := m.sim
	for e in s.ents:
		_prev["h%d" % e.id] = Vector2(e.x, e.y)
	for i in s.crooks.size():
		_prev["c%d" % i] = Vector2(s.crooks[i].x, s.crooks[i].y)
	var me: CleanSim.Hero = s.ents[m.human]
	_my_carry = [me.carry_0, me.carry_1, me.carry_2]


func _alpha() -> float:
	return clampf(_acc / DT, 0.0, 1.0)


func _lerp_pos(key: String, x: int, y: int) -> Vector2:
	var cur := Vector2(x, y)
	var before: Vector2 = _prev.get(key, cur)
	if before.distance_to(cur) > 2000.0: # a respawn: jump, don't slide across the map
		before = cur
	return before.lerp(cur, _alpha()) * PX


func _hero_pos(e: CleanSim.Hero) -> Vector2:
	return _lerp_pos("h%d" % e.id, e.x, e.y)


func _crook_pos(i: int) -> Vector2:
	var c: CleanSim.Crook = m.sim.crooks[i]
	return _lerp_pos("c%d" % i, c.x, c.y)


func _key(k: Key) -> bool:
	return Input.is_physical_key_pressed(k)


## Keys: WASD/arrows walk, Space acts (catch, bin or pick up: what fits), Shift the trick. Mouse: hold the left
## button to walk to the pointer, right button acts. Touch: left thumb walks, the orange button acts.
func _command() -> Dictionary:
	var me: CleanSim.Hero = m.sim.ents[m.human]
	var cmd := {"m": -1, "a": -1, "s": -1}
	var mx := int(_key(KEY_D) or _key(KEY_RIGHT)) - int(_key(KEY_A) or _key(KEY_LEFT))
	var my := int(_key(KEY_S) or _key(KEY_DOWN)) - int(_key(KEY_W) or _key(KEY_UP))
	if touch != null and touch.move != Vector2.ZERO:
		cmd.m = Fx.atan2_a(int(touch.move.y * 1000), int(touch.move.x * 1000))
	elif mx != 0 or my != 0:
		cmd.m = Fx.atan2_a(my * 1000, mx * 1000)
	elif controls == "mouse" and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var w := get_global_mouse_position() / PX
		if Vector2(me.x, me.y).distance_to(w) > 300.0:
			cmd.m = Fx.atan2_a(int(w.y) - me.y, int(w.x) - me.x)
	if (touch != null and touch.attacking) or _key(KEY_SPACE) or _key(KEY_E) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		cmd.a = 0
	if _trick_pending:
		_trick_pending = false
		cmd.s = trick_aim(m.sim, me)
	return cmd


## The trick aims itself at the nearest roaming crook in range (kind to small thumbs), else the way you face.
static func trick_aim(s: CleanSim, h: CleanSim.Hero) -> int:
	var kind := str(s.characters[h.id].get("id", "runner"))
	var reach: int = TRICK_RANGE.get(kind, 0)
	var best := -1
	var bd := reach + 1
	for c in s.crooks:
		if c.state != CleanSim.ROAM:
			continue
		var d := Fx.dist(c.x - h.x, c.y - h.y)
		if d < bd:
			bd = d
			best = Fx.atan2_a(c.y - h.y, c.x - h.x)
	return best if best >= 0 else h.aim


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and (event.physical_keycode == KEY_SHIFT or event.physical_keycode == KEY_Q):
		_trick_pending = true


func _handle_events() -> void:
	var s := m.sim
	for ev in s.events:
		match str(ev.type):
			"pick":
				if int(ev.id) == m.human:
					Sfx.play("pick")
					if s.carried(s.ents[m.human]) >= int(s.rules.carry_max):
						_say(tr("CLEAN_FULL"), 1.6)
			"bin":
				var h: CleanSim.Hero = s.ents[int(ev.id)]
				_float(Vector2(h.x, h.y) * PX + Vector2(0, -150), "+%d" % int(ev.points), TEAM_COLORS[h.team])
				if int(ev.id) == m.human:
					Sfx.play("bin")
					var right: int = _my_carry[int(ev.kind)]
					var all: int = _my_carry[0] + _my_carry[1] + _my_carry[2]
					_say(tr("CLEAN_RIGHT_BIN") if right == all else tr("CLEAN_WRONG_BIN"), 1.4)
				else:
					Sfx.play_at("bin", Vector2(h.x, h.y) * PX, cam.position)
			"catch":
				var who: CleanSim.Hero = s.ents[int(ev.id)]
				var p := Vector2(int(ev.x), int(ev.y)) * PX
				_float(p + Vector2(0, -170), "+%d" % int(s.rules.points.catch), TEAM_COLORS[who.team])
				for i in s.crooks.size():
					if s.crooks[i].x == int(ev.x) and s.crooks[i].y == int(ev.y):
						_hop[i] = 0.5
				if int(ev.id) == m.human:
					Sfx.play("catch")
					_say(tr("CLEAN_CAUGHT"), 1.8)
				else:
					Sfx.play_at("catch", p, cam.position)
			"trick":
				var t: CleanSim.Hero = s.ents[int(ev.id)]
				var kind := str(ev.kind)
				if TRICK_RANGE.has(kind):
					_waves.append({"pos": Vector2(t.x, t.y) * PX, "radius": float(TRICK_RANGE[kind]) * PX, "color": TEAM_COLORS[t.team], "t": 0.0})
				if int(ev.id) == m.human:
					Sfx.play("whoosh")
				else:
					Sfx.play_at("whoosh", Vector2(t.x, t.y) * PX, cam.position)
			"finished":
				Sfx.play("whistle")
				Sfx.play("win" if int(s.result()[m.human].place) == 1 else "tap")


func _say(text: String, seconds: float) -> void:
	_msg = text
	_msg_t = seconds


func _float(pos: Vector2, text: String, color: Color) -> void:
	_floats.append({"pos": pos, "text": text, "color": color, "t": 0.0})


# --- sprites ---

func _sync_sprites() -> void:
	var s := m.sim
	for e in s.ents:
		var c: Sprite2D = _heroes[e.id]
		var pos := _hero_pos(e)
		var walking := pos.distance_to(Vector2(e.x, e.y) * PX) > 0.5 or Vector2(_prev.get("h%d" % e.id, Vector2(e.x, e.y))) != Vector2(e.x, e.y)
		var bob := absf(sin(_t * 14.0)) * 5.0 if walking else 0.0
		c.position = pos + Vector2(0, 18 - bob)
		c.scale = Vector2(PERSON_SCALE * (-1.0 if Fx.cos_a(e.aim) < 0 else 1.0), PERSON_SCALE)
		c.rotation = sin(_t * 14.0) * 0.06 if walking else 0.0
	while _crooks.size() < s.crooks.size():
		var sp := _sprite("crook", Vector2(0, -80), CROOK_SCALE)
		actors.add_child(sp)
		_crooks.append(sp)
	for i in s.crooks.size():
		var c: CleanSim.Crook = s.crooks[i]
		var sp: Sprite2D = _crooks[i]
		sp.visible = c.state != CleanSim.AWAY
		if not sp.visible:
			continue
		sp.texture = _texture("res://assets/props/%s.svg" % ("crook_helper" if c.state == CleanSim.HELP else "crook"))
		var pos := _crook_pos(i)
		var before: Vector2 = _prev.get("c%d" % i, Vector2(c.x, c.y))
		if absf(c.x - before.x) > 5.0:
			_face[i] = 1 if c.x > before.x else -1
		var hop := float(_hop.get(i, 0.0))
		var lift := sin(clampf(hop / 0.5, 0.0, 1.0) * PI) * 40.0 if hop > 0.0 else 0.0
		var walking := before != Vector2(c.x, c.y)
		sp.position = pos + Vector2(0, 16 - lift - (absf(sin(_t * 16.0)) * 4.0 if walking else 0.0))
		sp.scale = Vector2(CROOK_SCALE * float(_face.get(i, 1)), CROOK_SCALE)
	while _litter.size() < s.litter.size():
		var sp := _sprite("litter_paper", Vector2(0, -50), LITTER_SCALE)
		litter_layer.add_child(sp)
		_litter.append(sp)
	for i in _litter.size():
		var sp: Sprite2D = _litter[i]
		sp.visible = i < s.litter.size()
		if sp.visible:
			var l: CleanSim.Litter = s.litter[i]
			sp.texture = _texture("res://assets/props/litter_%s.svg" % KINDS[l.kind])
			sp.position = Vector2(l.x, l.y) * PX + Vector2(0, 20)
			sp.rotation = float(posmod(l.x * 7 + l.y * 13, 9) - 4) * 0.12 # a fixed tilt per piece, so it looks dropped


# --- drawing ---

func _draw_ground() -> void:
	var s := m.sim
	for y in s.height:
		for x in s.width:
			var k := s.tiles[y * s.width + x]
			var r := Rect2(x * TP, y * TP, TP, TP)
			match k:
				0:
					_draw_building(x, y, r)
				1:
					ground.draw_rect(r, ASPHALT)
				2:
					ground.draw_rect(r, PAVEMENT)
					ground.draw_line(r.position + Vector2(TP / 2.0, 0), r.position + Vector2(TP / 2.0, TP), PAVEMENT.darkened(0.06), 2.0)
					ground.draw_line(r.position + Vector2(0, TP / 2.0), r.position + Vector2(TP, TP / 2.0), PAVEMENT.darkened(0.06), 2.0)
				3:
					ground.draw_rect(r, GRASS)
					var n := posmod(x * 31 + y * 17, 5)
					ground.draw_circle(r.position + Vector2(18 + n * 9, 24 + n * 5), 5.0, GRASS.darkened(0.12))
					ground.draw_circle(r.position + Vector2(56 - n * 4, 58 - n * 3), 4.0, GRASS.darkened(0.12))
				4:
					ground.draw_rect(r, SQUARE)
					ground.draw_rect(r.grow(-1.5), SQUARE.lightened(0.05), false, 2.0)
	# road markings: dashes in the middle of each two-lane street, never on a crossing; kerbs along the pavement
	for y in s.height:
		for x in s.width:
			var k := s.tiles[y * s.width + x]
			var r := Rect2(x * TP, y * TP, TP, TP)
			if k == 1:
				var row_street := y + 1 < s.height and s.tiles[(y + 1) * s.width + x] == 1 and (y == 7 or y == 17)
				var col_street := x + 1 < s.width and s.tiles[y * s.width + x + 1] == 1 and x in [6, 19, 32]
				if row_street and not (x in [6, 7, 19, 20, 32, 33]):
					ground.draw_rect(Rect2(r.position + Vector2(14, TP - 3), Vector2(TP - 28, 6)), Color(1, 1, 1, 0.8))
				if col_street and not (y in [7, 8, 17, 18]):
					ground.draw_rect(Rect2(r.position + Vector2(TP - 3, 14), Vector2(6, TP - 28)), Color(1, 1, 1, 0.8))
			elif k == 2 or k == 4:
				for d in [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]:
					var nx: int = x + d.x
					var ny: int = y + d.y
					if nx >= 0 and ny >= 0 and nx < s.width and ny < s.height and s.tiles[ny * s.width + nx] == 1:
						var a := r.get_center() + Vector2(d) * TP / 2.0 + Vector2(-d.y, d.x) * TP / 2.0
						var b := r.get_center() + Vector2(d) * TP / 2.0 - Vector2(-d.y, d.x) * TP / 2.0
						ground.draw_line(a, b, Color("B8B2A6"), 6.0)
	# a few bushes in the park (flat, you walk over them)
	for p in [Vector2(14.6, 10.6), Vector2(25.4, 10.6), Vector2(14.6, 15.4), Vector2(25.4, 15.4)]:
		ground.draw_circle(p * TP, 30.0, INK)
		ground.draw_circle(p * TP, 26.0, Color("6E9A3E"))
		ground.draw_circle(p * TP + Vector2(-8, -8), 9.0, Color("8DBB55"))


## A house from above with its front wall showing: roof colour per block, a wall with windows where the street is
## below, an ink edge where it meets the open street. The map's border is a hedge.
func _draw_building(x: int, y: int, r: Rect2) -> void:
	var s := m.sim
	if x == 0 or y == 0 or x == s.width - 1 or y == s.height - 1:
		ground.draw_rect(r, HEDGE)
		ground.draw_circle(r.get_center() + Vector2(-14, -10), 16.0, HEDGE.lightened(0.12))
		ground.draw_circle(r.get_center() + Vector2(16, 12), 14.0, HEDGE.lightened(0.08))
		return
	var bx := 0 if x < 6 else (1 if x < 19 else (2 if x < 33 else 3))
	var by := 0 if y < 7 else (1 if y < 17 else 2)
	var roof: Color = ROOFS[(bx * 3 + by) % ROOFS.size()]
	var below_open := s.tiles[(y + 1) * s.width + x] != 0
	ground.draw_rect(r, roof)
	ground.draw_line(r.position + Vector2(0, TP * 0.35), r.position + Vector2(TP, TP * 0.35), roof.darkened(0.15), 3.0)
	if below_open:
		var wall := Rect2(r.position + Vector2(0, TP * 0.55), Vector2(TP, TP * 0.45))
		ground.draw_rect(wall, WALL)
		ground.draw_rect(Rect2(wall.position + Vector2(18, 8), Vector2(44, 20)), Color("8FC3E8"))
		ground.draw_rect(Rect2(wall.position + Vector2(18, 8), Vector2(44, 20)), INK, false, 3.0)
		ground.draw_line(r.position + Vector2(0, TP * 0.55), r.position + Vector2(TP, TP * 0.55), INK, 3.0)
	for d in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1)]:
		if s.tiles[(y + d.y) * s.width + x + d.x] != 0:
			var c := r.get_center() + Vector2(d) * TP / 2.0
			var side := Vector2(-d.y, d.x) * TP / 2.0
			ground.draw_line(c + side, c - side, INK, 4.0)


func _draw_marks() -> void:
	var s := m.sim
	for e in s.ents:
		var p := _hero_pos(e) + Vector2(0, 18)
		marks.draw_set_transform(p, 0.0, Vector2(1.0, 0.4))
		marks.draw_circle(Vector2.ZERO, 46.0, Color(TEAM_COLORS[e.team], 0.45))
		marks.draw_arc(Vector2.ZERO, 46.0, 0, TAU, 32, TEAM_COLORS[e.team], 7.0)
		marks.draw_set_transform(Vector2.ZERO)
	for i in s.crooks.size():
		var c: CleanSim.Crook = s.crooks[i]
		if c.state == CleanSim.HELP:
			marks.draw_set_transform(_crook_pos(i) + Vector2(0, 16), 0.0, Vector2(1.0, 0.4))
			marks.draw_arc(Vector2.ZERO, 40.0, 0, TAU, 32, TEAM_COLORS[c.team], 6.0)
			marks.draw_set_transform(Vector2.ZERO)
	for w in _waves:
		var k := float(w.t) / 0.6
		marks.draw_arc(w.pos, float(w.radius) * k, 0, TAU, 48, Color(w.color, 0.8 * (1.0 - k)), 8.0)


func _draw_overlay() -> void:
	var s := m.sim
	var font := UiTheme.title_font()
	for i in s.crooks.size():
		var c: CleanSim.Crook = s.crooks[i]
		if c.state == CleanSim.ROAM and c.freeze > 0: # stopped by a whistle or a dog: stars round the head
			var top := _crook_pos(i) + Vector2(0, -150)
			for j in 3:
				var a := _t * 5.0 + j * TAU / 3.0
				_star(top + Vector2(cos(a) * 30.0, sin(a) * 10.0), 9.0)
	for e in s.ents:
		# what each hero carries: one coloured dot per piece over the head
		var n := s.carried(e)
		if n > 0:
			var top := _hero_pos(e) + Vector2(-(n - 1) * 11.0, -168)
			var j := 0
			for k in 3:
				for q in int(e.get("carry_%d" % k)):
					overlay.draw_circle(top + Vector2(j * 22.0, 0), 10.0, INK)
					overlay.draw_circle(top + Vector2(j * 22.0, 0), 7.0, KIND_COLORS[k])
					j += 1
		if e.sprint > 0:
			var p := _hero_pos(e)
			var back := -1.0 if Fx.cos_a(e.aim) >= 0 else 1.0
			for j in 3:
				overlay.draw_line(p + Vector2(back * 40, -40 - j * 24), p + Vector2(back * 80, -40 - j * 24), Color(1, 1, 1, 0.8), 5.0)
	for f in _floats:
		var k := float(f.t) / 1.2
		var p: Vector2 = f.pos + Vector2(-60, -k * 60.0)
		var col: Color = f.color
		overlay.draw_string_outline(font, p, str(f.text), HORIZONTAL_ALIGNMENT_CENTER, 120, 40, 8, Color(INK, 1.0 - k))
		overlay.draw_string(font, p, str(f.text), HORIZONTAL_ALIGNMENT_CENTER, 120, 40, Color(col.lightened(0.2), 1.0 - k))
	# you: a bouncing arrow over your head
	var me: CleanSim.Hero = s.ents[m.human]
	var tip := _hero_pos(me) + Vector2(0, -180 - absf(sin(_t * 4.0)) * 8.0 - (24.0 if s.carried(me) > 0 else 0.0))
	var arrow := PackedVector2Array([tip, tip + Vector2(-18, -24), tip + Vector2(18, -24)])
	overlay.draw_colored_polygon(arrow, Color.WHITE)
	overlay.draw_polyline(arrow + PackedVector2Array([tip]), INK, 4.0)


func _star(c: Vector2, r: float) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI / 2.0 + i * PI / 5.0
		pts.append(c + Vector2(cos(a), sin(a)) * (r if i % 2 == 0 else r * 0.45))
	overlay.draw_colored_polygon(pts, Color("FFD23F"))
	pts.append(pts[0])
	overlay.draw_polyline(pts, INK, 2.0)


# --- HUD ---

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Control.new()
	hud.theme = UiTheme.get_theme()
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(hud)
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	SafeArea.apply(hud)
	# the score: blue left, the clock in the middle, orange right
	var score := HBoxContainer.new()
	score.add_theme_constant_override("separation", 16)
	hud.add_child(score)
	score.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	score.grow_horizontal = Control.GROW_DIRECTION_BOTH
	score.position.y = 24
	for key in ["blue", "time", "orange"]:
		var panel := PanelContainer.new()
		score.add_child(panel)
		var l := Label.new()
		l.add_theme_font_override("font", UiTheme.title_font())
		l.add_theme_font_size_override("font_size", 44)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.custom_minimum_size = Vector2(240 if key != "time" else 150, 0)
		if key != "time":
			l.add_theme_color_override("font_color", TEAM_COLORS[0 if key == "blue" else 1])
		panel.add_child(l)
		_labels[key] = l
	# your hands: a piece of each kind with how many you carry
	var hands := PanelContainer.new()
	hud.add_child(hands)
	hands.position = Vector2(40, 24)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	hands.add_child(row)
	for k in 3:
		var icon := TextureRect.new()
		var crop := AtlasTexture.new() # the piece itself, without the empty room around it in the SVG
		crop.atlas = _texture("res://assets/props/litter_%s.svg" % KINDS[k])
		crop.region = Rect2(52, 62, 104, 96)
		icon.texture = crop
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(64, 64)
		row.add_child(icon)
		var l := Label.new()
		l.add_theme_font_override("font", UiTheme.title_font())
		l.add_theme_font_size_override("font_size", 36)
		l.custom_minimum_size = Vector2(36, 0)
		row.add_child(l)
		_hands.append(l)
	var total := Label.new()
	total.add_theme_font_override("font", UiTheme.title_font())
	total.add_theme_font_size_override("font_size", 30)
	row.add_child(total)
	_labels["total"] = total
	var msg := Label.new()
	msg.label_settings = UiTheme.heading(64)
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud.add_child(msg)
	msg.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	msg.position.y = 170
	msg.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_labels["msg"] = msg
	controls = Controls.choose(Platform.load_profile(), Boot.args, DisplayServer.is_touchscreen_available())
	if controls == "touch":
		touch = TouchControls.new()
		hud.add_child(touch)
		touch.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		hud.move_child(touch, 0)
	_trick_btn = Button.new()
	_trick_btn.focus_mode = Control.FOCUS_NONE
	_trick_btn.custom_minimum_size = Vector2(240, 100)
	_trick_btn.pressed.connect(func() -> void: _trick_pending = true)
	hud.add_child(_trick_btn)
	_trick_btn.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	var lift := 2.0 * TouchControls.ATTACK_RADIUS + 60.0 if touch != null else 0.0
	_trick_btn.offset_left = -300
	_trick_btn.offset_right = -60
	_trick_btn.offset_top = -160 - lift
	_trick_btn.offset_bottom = -60 - lift
	if touch != null:
		touch.blocked.append(_trick_btn)
	var hint := Label.new()
	hint.text = tr("CLEAN_CONTROLS_TOUCH") if controls == "touch" else tr("CLEAN_CONTROLS_KEYS")
	get_tree().create_timer(8.0).timeout.connect(hint.hide)
	hint.label_settings = UiTheme.heading(26, Color.WHITE, 6)
	hud.add_child(hint)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	hint.offset_left = 40
	hint.offset_top = -70


func _update_hud() -> void:
	var s := m.sim
	var me: CleanSim.Hero = s.ents[m.human]
	_labels.blue.text = "%s %d" % [tr("CLEAN_BLUE"), s.score_0]
	_labels.orange.text = "%d %s" % [s.score_1, tr("CLEAN_ORANGE")]
	var secs := s.seconds_left()
	_labels.time.text = "%d:%02d" % [secs / 60, secs % 60]
	_labels.time.add_theme_color_override("font_color", Color("E03A2A") if secs <= 10 else INK)
	if secs <= 10 and not _warned and not s.finished:
		_warned = true
		_say(tr("CLEAN_LAST"), 1.6)
	for k in 3:
		_hands[k].text = str(int(me.get("carry_%d" % k)))
	_labels.total.text = "%d/%d" % [s.carried(me), int(s.rules.carry_max)]
	_labels.total.add_theme_color_override("font_color", Color("E03A2A") if s.carried(me) >= int(s.rules.carry_max) else INK)
	_labels.msg.text = _msg
	_labels.msg.modulate.a = clampf(_msg_t * 2.0, 0.0, 1.0)
	var kind := str(s.characters[me.id].get("id", "runner"))
	var name := tr("CLEAN_TRICK_" + kind.to_upper())
	_trick_btn.text = name if me.trick_cd == 0 else "%s %d" % [name, ceili(me.trick_cd / 30.0)]
	_trick_btn.disabled = me.trick_cd > 0 or s.finished == 1


# --- online (phase 4): relay + rollback, as in the other games ---

## The lobby's "match" message: same seed and seats on every screen; bots fill the empty seats.
func _start_online(info: Dictionary) -> void:
	m = CleanMatch.create_online(int(info.seed), info.get("characters", info.get("animals", [])), 6, "normal")
	m.human = int(info.slot)
	rb = Rollback.new(m, m.human, int(info.get("delay", 2)))
	net = OnlineClient.new()
	add_child(net)
	net.message.connect(_on_net)
	net.closed.connect(func(_code: int) -> void:
		if _ending < 0.0:
			_say(tr("ONLINE_LOST"), 3.0)
			_ending = 3.0)
	net.open(St33f.client.pvp_room_url(str(info.room), int(info.slot), str(info.key)))
	_say(tr("ONLINE_WAITING_START"), 30.0)


func _on_net(msg: Dictionary) -> void:
	match OnlineClient.apply(rb, msg):
		"start":
			_online_started = true
			_say(tr("CLEAN_START"), 2.2)
			Sfx.play("whistle")
		"desync":
			_say(tr("ONLINE_DESYNC"), 3.0)
			if _ending < 0.0:
				_ending = 3.0
			if St33f.crash != null:
				St33f.crash.capture("desync", "online desync at tick %d" % int(msg.get("t", -1)), [])


## One online tick: own input out, the rollback plays (replaying corrected ticks), settled hashes out.
func _online_step() -> bool:
	if not _online_started or not rb.can_advance():
		return false
	_remember()
	rb.local_input(CleanMatch.cmd_to(_command()))
	for out in OnlineClient.batch(rb.outbox):
		net.send(out)
	rb.outbox.clear()
	rb.advance()
	while rb.settled_hash(_next_hash) != -1:
		net.send({"type": "hash", "t": _next_hash, "h": rb.settled_hash(_next_hash)})
		_next_hash += Rollback.HASH_EVERY
	return true
