extends Node
## Headless test runner, run as a scene so autoloads (Platform, Boot) exist like in the real game.
## Exit code 1 on any failure, so CI fails.
##   godot --headless --path . res://tests/run_tests.tscn

const LOCAL_SEED_2026_11_10 := 1575149571 # FNV-1a over "white-glove-daily-2026-11-10", computed independently in Python
const LocalBackend := preload("res://platform/local_backend.gd")
const BootScript := preload("res://boot/boot.gd")
const ContentScript := preload("res://sim/content.gd")

var _passed := 0
var _failed := 0


func _ready() -> void:
	test_every_script_compiles()
	test_every_text_key_exists()
	test_profile_roundtrip()
	test_debug_args()
	test_profile_merge()
	await test_remote_backend()
	test_fx_and_rng()
	test_every_asset_has_credits()
	test_setting_declarations()
	test_every_language_complete()
	test_sfx()
	test_sdk_has_what_the_game_calls()
	await test_my_data()
	test_touch_and_safe_area()
	test_perf_meter()
	test_characters_and_result()
	test_room_codes()
	print("tests: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		printerr("FAIL: " + what)


## A parse error anywhere must fail CI, not only show up in the editor.
func test_every_script_compiles() -> void:
	for path in files_under("res://", [".gd"]):
		if path == "res://tests/run_tests.gd":
			continue
		var s: Script = load(path)
		check(s != null and s.can_instantiate(), "script compiles: " + path)


## No player-facing string inline: every tr("KEY") in code and every *_key in data must exist in strings.csv
## with a non-empty English text.
func test_every_text_key_exists() -> void:
	var table := read_strings("res://i18n/strings.csv")
	check(table.size() > 0, "strings.csv is readable")
	var used := {}
	var rx := RegEx.create_from_string("tr\\(\"([A-Z0-9_]+)\"\\)")
	for path in files_under("res://", [".gd", ".tscn"]):
		if path.begins_with("res://tests/"):
			continue
		for m in rx.search_all(FileAccess.get_file_as_string(path)):
			used[m.get_string(1)] = path
	var key_rx := RegEx.create_from_string("\"[a-z_]*key\"\\s*:\\s*\"([A-Z0-9_]+)\"")
	for path in files_under("res://data/", [".json"]):
		for m in key_rx.search_all(FileAccess.get_file_as_string(path)):
			used[m.get_string(1)] = path
	check(used.size() > 0, "found text keys in code")
	for key in used:
		check(table.has(key) and str(table[key]).strip_edges() != "", "text key %s (used in %s) exists in strings.csv" % [key, used[key]])


func test_profile_roundtrip() -> void:
	var b = LocalBackend.new()
	b.profile_path = "user://test_profile.json"
	if FileAccess.file_exists(b.profile_path):
		DirAccess.remove_absolute(b.profile_path)
	var p: Dictionary = b.load_profile()
	check(int(p["version"]) == 0, "fresh profile has version 0")
	p["pearls_total"] = 12
	b.save_profile(p)
	var q: Dictionary = b.load_profile()
	check(int(q["pearls_total"]) == 12, "pearls survive save/load")
	check(int(q["version"]) == 1, "save bumps version")
	check(str(q["updated_at"]).ends_with("Z"), "updated_at is UTC")
	DirAccess.remove_absolute(b.profile_path)


func test_debug_args() -> void:
	var a: Dictionary = BootScript.parse(PackedStringArray(["--scene=match", "--seed=42", "ignored"]))
	check(a.get("scene") == "match" and a.get("seed") == "42", "desktop debug args parse")
	var q: Dictionary = BootScript.parse_query("?scene=match&seed=7")
	check(q.get("scene") == "match" and q.get("seed") == "7", "web query parses")


func test_profile_merge() -> void:
	var a := {"pearls_total": 120, "unlocked_animals": ["crab", "octopus"], "selected_animal": "octopus",
		"stats": {"matches": 10, "wins": 2}, "achievements": {"first_win": 1}, "updated_at": "2026-11-10T10:00:00Z",
		"settings": {"music": 0.5}, "version": 4}
	var b := {"pearls_total": 90, "unlocked_animals": ["gull", "crab"], "selected_animal": "gull",
		"stats": {"matches": 12, "wins": 1, "knockouts": 7}, "achievements": {"first_win": 2, "survivor": 1},
		"updated_at": "2026-11-10T11:00:00Z", "settings": {"music": 0.9}, "version": 2}
	var m: Dictionary = ProfileMerge.merge(a, b)
	check(int(m.pearls_total) == 120, "merge: counters take the max")
	check(m.unlocked_animals == ["crab", "gull", "octopus"], "merge: unlocks are the sorted union")
	check(m.stats == {"knockouts": 7, "matches": 12, "wins": 2}, "merge: stats max per key")
	check(m.achievements == {"first_win": 2, "survivor": 1}, "merge: achievements max tier")
	check(m.selected_animal == "gull" and float(m.settings.music) == 0.9, "merge: choices from the newer profile")
	check(int(m.version) == 4, "merge: write counter max")
	var m2: Dictionary = ProfileMerge.merge(b, a)
	check(m2.unlocked_animals == m.unlocked_animals and m2.stats == m.stats and int(m2.pearls_total) == 120,
		"merge: order of arguments does not change counters and unlocks")
	check(ProfileMerge.merge(a, {}) == a, "merge: empty server keeps local")


func test_remote_backend() -> void:
	var server := {"profile": {"pearls_total": 50, "unlocked_animals": ["crab", "puffer"], "updated_at": "2026-01-01T00:00:00Z"}, "version": 3}
	var puts := []
	var handler := func(method, path, _h, body):
		if path == "/auth/start":
			return [200, {"ok": true, "challenge": "c1"}]
		if path == "/auth/verify":
			return [200, {"ok": true, "token": "cs1_" + "a".repeat(43), "userId": "u1"}]
		if path.ends_with("/profile") and method == HTTPClient.METHOD_GET:
			return [200, {"ok": true, "profile": server.profile, "version": server.version}]
		if path.ends_with("/profile") and method == HTTPClient.METHOD_PUT:
			puts.append(body)
			server.version += 1
			server.profile = body.profile
			return [200, {"ok": true, "version": server.version}]
		return [404, {"error": "not_found"}]
	var node = preload("res://addons/st33f/st33f.gd").new()
	node.configure("white-glove", St33fScriptedTransport.new(handler), St33fTokenStore.new(), "http://test.local", Callable(), "user://st33f/test_queue.json")
	add_child(node)
	var b = preload("res://platform/remote_backend.gd").new(node)
	b.profile_path = "user://test_remote_profile.json"
	if FileAccess.file_exists(b.profile_path):
		DirAccess.remove_absolute(b.profile_path)
	var local: Dictionary = b.load_profile()
	local["pearls_total"] = 80
	b.save_profile(local)
	check(not node.profile_sync.dirty, "signed out: saves stay local")

	await node.sign_in_start("p@example.com")
	await node.sign_in_verify("123456")
	await get_tree().process_frame
	var merged: Dictionary = b.load_profile()
	check(int(merged.pearls_total) == 80 and (merged.unlocked_animals as Array).has("puffer") and (merged.unlocked_animals as Array).has("gull"),
		"after sign-in the cloud copy is merged into the local profile")
	check(node.profile_sync.dirty and node.profile_sync.version == 3, "merged profile is queued for upload on top of server version 3")
	var r: Dictionary = await node.profile_sync.push_now()
	check(r.ok and puts.size() == 1 and int(server.profile.pearls_total) == 80, "upload sends the merged profile")
	DirAccess.remove_absolute(b.profile_path)
	node.queue_free()


func test_fx_and_rng() -> void:
	check(Fx.sin_a(0) == 0 and Fx.sin_a(1024) == 1024 and Fx.cos_a(0) == 1024 and Fx.sin_a(3072) == -1024, "sin table cardinal points")
	var worst := 0
	for a in range(0, 4096, 37):
		worst = maxi(worst, absi(Fx.angle_diff(Fx.atan2_a(Fx.sin_a(a) * 100, Fx.cos_a(a) * 100), a)))
	check(worst <= 2, "atan2 inverts sin/cos within 2 units (worst %d)" % worst)
	check(Fx.isqrt(0) == 0 and Fx.isqrt(15) == 3 and Fx.isqrt(16) == 4 and Fx.isqrt(1_000_000) == 1000, "integer sqrt")
	var r := SimRng.new(1)
	# pinned values: the C++ port must produce exactly these
	check(r.next_u32() == 270369 and r.next_u32() == 67634689, "xorshift32 reference values")


## Every sound the game asks for is defined in data/sfx.json; in CI (after sfx.py --ffmpeg) every sound exists.
func test_sfx() -> void:
	var spec: Dictionary = Content.load_json("res://data/sfx.json")
	var sounds: Dictionary = spec.sounds
	var wanted := ["tap", "win", "whistle"]
	var missing := wanted.filter(func(n): return not sounds.has(n))
	check(missing.is_empty(), "every sound the game plays is in sfx.json (missing: %s)" % ", ".join(missing))
	check(float(spec.peak_dbfs) <= -3.0, "effects are normalised to a peak <= -3 dBFS")
	check(AudioServer.get_bus_index("Sfx") != -1 and AudioServer.get_bus_effect_count(0) > 0, "Sfx bus and a limiter on the master")
	check(Sfx.attenuation_db(0.0, 1920.0) == 0.0 and Sfx.attenuation_db(1920.0, 1920.0) < -10.0 and Sfx.attenuation_db(4000.0, 1920.0) <= -60.0, "sounds fade with distance")
	if OS.has_environment("CI"):
		var absent := sounds.keys().filter(func(n): return not Sfx.has_sound(n))
		check(absent.is_empty(), "every sound was built and imported (missing: %s)" % ", ".join(absent))


## Every St33f client call the game makes exists in the copied SDK (a stale copy only fails at runtime otherwise).
func test_sdk_has_what_the_game_calls() -> void:
	var rx := RegEx.create_from_string("St33f[.]client[.]([a-z_]+)[(]")
	var missing := []
	for path in files_under("res://", [".gd"]):
		if str(path).begins_with("res://addons/") or str(path).begins_with("res://tests/"):
			continue
		for m in rx.search_all(FileAccess.get_file_as_string(path)):
			if not St33f.client.has_method(m.get_string(1)):
				missing.append("%s in %s" % [m.get_string(1), path])
	check(missing.is_empty(), "SDK has every client call the game makes (missing: %s)" % ", ".join(missing))


## "Download my data": signed out it holds what is on this device; the file is written where the player finds it.
func test_my_data() -> void:
	var data: Dictionary = await MyData.gather()
	check(data.device is Dictionary and data.platform == null and data.game == "white-glove", "signed out: the device profile, no platform part")
	var text := JSON.stringify(data, "  ")
	check(not text.contains("cs1_"), "no session token in the export")
	var path := MyData.save(text)
	check(path != "" and FileAccess.file_exists(path) and FileAccess.get_file_as_string(path) == text, "export file written (%s)" % path)
	if path != "":
		DirAccess.remove_absolute(path)
	for i in range(1, 8):
		check(tr("PRIVACY_P%d" % i) != "PRIVACY_P%d" % i, "privacy paragraph %d has a text" % i)


## Phone: two thumbs at once (move + attack), dead zone, the special button keeps its touches; safe-area insets.
func test_touch_and_safe_area() -> void:
	var t := TouchControls.new()
	t.size = Vector2(1920, 1080)
	var ev := func(index: int, pos: Vector2, pressed: bool) -> InputEventScreenTouch:
		var e := InputEventScreenTouch.new()
		e.index = index
		e.position = pos
		e.pressed = pressed
		return e
	var drag := func(index: int, pos: Vector2) -> InputEventScreenDrag:
		var e := InputEventScreenDrag.new()
		e.index = index
		e.position = pos
		return e
	t.handle(ev.call(0, Vector2(300, 700), true))
	t.handle(drag.call(0, Vector2(310, 700)))
	check(t.move == Vector2.ZERO, "a resting thumb does not walk (dead zone)")
	t.handle(drag.call(0, Vector2(600, 700)))
	check(is_equal_approx(t.move.x, 1.0) and is_zero_approx(t.move.y), "joystick: full speed to the right, capped")
	t.handle(ev.call(1, t.attack_center() + Vector2(20, 10), true))
	check(t.attacking and t.move.x > 0.9, "second thumb attacks while the first keeps moving")
	t.handle(ev.call(0, Vector2(600, 700), false))
	check(t.move == Vector2.ZERO and t.attacking, "lifting the move thumb stops walking, attack holds")
	t.handle(ev.call(1, Vector2.ZERO, false))
	check(not t.attacking, "lifting the attack thumb stops attacking")
	var special := Button.new()
	special.size = Vector2(220, 110)
	special.position = Vector2(100, 100)
	t.add_child(special)
	t.blocked.append(special)
	t.handle(ev.call(2, Vector2(150, 150), true))
	t.handle(drag.call(2, Vector2(450, 150)))
	check(t.move == Vector2.ZERO, "a touch on the special button is left to the button")
	t.handle(ev.call(3, Vector2(1500, 300), true))
	t.handle(drag.call(3, Vector2(1800, 300)))
	check(t.move == Vector2.ZERO, "the right half does not start a joystick")
	t.free()


	var i := SafeArea.from_rects(Rect2(88, 0, 2400 - 88 - 88, 1080 - 63), Vector2(2400, 1080), Vector2(1920, 1080))
	check(is_equal_approx(i.left, 70.4) and is_equal_approx(i.right, 70.4) and is_zero_approx(i.top) and is_equal_approx(i.bottom, 63.0), "notch + home bar as insets in viewport units (%s)" % str(i))
	check(SafeArea.from_rects(Rect2(0, 0, 1920, 1080), Vector2(1920, 1080), Vector2(1920, 1080)).left == 0.0, "desktop: no insets")
	check(SafeArea.parse("40,20,40,30").bottom == 30.0, "debug safe=l,t,r,b")


## Frame times: average and p95 over a rolling window (the slow frames are what you feel).
func test_perf_meter() -> void:
	var p := PerfMeter.new()
	for i in 300:
		p.add(1.0 / 60.0 if i % 10 != 0 else 0.05) # every 10th frame is a 50 ms hitch (10 % > the 5 % above p95)
	var s := p.stats()
	check(absf(s.p95_ms - 50.0) < 0.01, "p95 sees the hitches (%.1f ms)" % s.p95_ms)
	check(s.avg_ms > 19.0 and s.avg_ms < 20.5 and s.fps > 45.0, "average and fps (%.1f ms, %.0f fps)" % [s.avg_ms, s.fps])
	p.free()


## A new key goes into every language in the same change, with the same placeholders ({count} etc.).
func test_every_language_complete() -> void:
	var f := FileAccess.open("res://i18n/strings.csv", FileAccess.READ)
	var header := f.get_csv_line()
	var langs := []
	for i in range(1, header.size()):
		if not header[i].begins_with("_"):
			langs.append(i)
	check(langs.size() >= 2, "strings.csv has at least two languages (%s)" % ", ".join(header))
	var rx := RegEx.create_from_string("\\{[a-z_]+\\}")
	var problems := []
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() < 2 or row[0] == "":
			continue
		var en_ph := _placeholders(rx, row[1])
		for i in langs:
			var text: String = row[i] if i < row.size() else ""
			if text.strip_edges() == "":
				problems.append("%s has no %s text" % [row[0], header[i]])
			elif _placeholders(rx, text) != en_ph:
				problems.append("%s: placeholders differ in %s" % [row[0], header[i]])
	check(problems.is_empty(), "every key translated with matching placeholders: " + "; ".join(problems))
	TranslationServer.set_locale("nl")
	check(tr("MENU_PLAY") == "SPELEN", "the Dutch translation is loaded")
	TranslationServer.set_locale("en")
	check(tr("MENU_PLAY") == "PLAY", "English is back")


func _placeholders(rx: RegEx, text: String) -> Array:
	var out := []
	for m in rx.search_all(text):
		out.append(m.get_string())
	out.sort()
	return out


## The same checks the server applies when CI pushes the declarations, so a bad one fails here first.
func test_setting_declarations() -> void:
	var d: Dictionary = Content.load_json("res://data/settings_defs.json")
	var key_rx := RegEx.create_from_string("^[a-z][a-z0-9_]{0,47}$")
	for def in d.defs:
		var ok_type := false
		match str(def.type):
			"bool": ok_type = typeof(def.default) == TYPE_BOOL
			"int": ok_type = typeof(def.default) == TYPE_FLOAT and float(def.default) == floor(float(def.default))
			"float": ok_type = typeof(def.default) == TYPE_FLOAT
			"string": ok_type = typeof(def.default) == TYPE_STRING
		check(key_rx.search(str(def.key)) != null and ok_type and str(def.get("description", "")) != "",
			"setting %s: valid key, default matches type, has a description" % def.key)
	check(Platform.get_config("show_daily", false) == true and Platform.get_config("event_banner", "x") == "",
		"get_config falls back to the declared defaults")


## Asset policy: no file under assets/ without a credits row (source, author, licence, date).
func test_every_asset_has_credits() -> void:
	var credits := FileAccess.get_file_as_string("res://assets/credits.csv")
	# a row may name a file, or a folder ending in "/" for generated sets (e.g. cutout parts)
	var folders: Array = []
	for line in credits.split("\n"):
		var first := line.split(",")[0]
		if first.ends_with("/"):
			folders.append(first)
	for path in files_under("res://assets/", [".svg", ".png", ".jpg", ".webp", ".ttf", ".otf", ".ogg", ".wav", ".glb", ".gltf"]):
		var rel: String = str(path).trim_prefix("res://")
		var covered := credits.contains("\n" + rel + ",") or folders.any(func(f): return rel.begins_with(f))
		check(covered, "credits row for " + rel)
	# cutout parts are imported at 2x so the big menu animal stays sharp
	for path in files_under("res://assets/animals/", [".svg.import"]) + files_under("res://assets/looks/", [".svg.import"]):
		check(FileAccess.get_file_as_string(path).contains("svg/scale=2.0"), "imported at 2x: " + str(path))


# --- helpers ---

func read_strings(path: String) -> Dictionary:
	var out := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var header := f.get_csv_line()
	var en := header.find("en")
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() > en and row[0] != "":
			out[row[0]] = row[en]
	return out


func files_under(dir: String, exts: Array) -> Array:
	var out := []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for sub in d.get_directories():
		if sub.begins_with("."):
			continue
		out.append_array(files_under(dir.path_join(sub), exts))
	for file in d.get_files():
		for e in exts:
			if file.ends_with(e):
				out.append(dir.path_join(file))
	return out


## Characters load and the result bookkeeping counts pearls, wins and mastery per character.
func test_characters_and_result() -> void:
	var list := Content.characters()
	check(list.size() >= 3 and list.all(func(c): return c.has("id") and c.has("name_key") and c.has("color")), "characters.json: at least 3 with id, name, colour")
	var backend = Platform.backend
	var saved_path: String = backend.profile_path
	backend.profile_path = "user://test_result_profile.json"
	if FileAccess.file_exists(backend.profile_path):
		DirAccess.remove_absolute(backend.profile_path)
	var o: Dictionary = preload("res://ui/result_screen.gd").apply_result({"place": 1, "points": 30, "character": "netter"})
	var p: Dictionary = Platform.load_profile()
	check(int(o.earned) == 60 and int(p.pearls_total) == 60 and int(p.stats.wins) == 1 and int(p.mastery.netter.matches) == 1, "a win: 60 pearls, a win, netter mastery counted")
	for i in 2:
		o = preload("res://ui/result_screen.gd").apply_result({"place": 1, "points": 30, "character": "netter"})
	p = Platform.load_profile()
	check(int(p.pearls_total) == 180 and (p.unlocked_characters as Array) == ["netter"] and o.unlocked.size() == 1, "150 pearls unlock the netter")
	var Menu := preload("res://ui/main_menu.gd")
	check(Menu.next_character(p) == "netter" and Menu.next_character({"selected_character": "runner"}) == "runner", "the character button only offers what you have")
	DirAccess.remove_absolute(backend.profile_path)
	backend.profile_path = saved_path


## Friends room codes: what the SDK makes and what a typed code becomes.
func test_room_codes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var ok := true
	for i in 50:
		var c := St33fClient.pvp_room_code(rng)
		ok = ok and c.length() == 4 and not (c.contains("O") or c.contains("0") or c.contains("I") or c.contains("1") or c.contains("L"))
	check(ok, "room codes: 4 characters, no look-alikes")
	var OS_ := preload("res://ui/online_screen.gd")
	check(OS_.clean_code("k7pq") == "K7PQ" and OS_.clean_code(" k-7 p q x") == "K7PQ" and OS_.clean_code("o1il") == "", "typed codes: capitals, look-alikes dropped, at most 4")