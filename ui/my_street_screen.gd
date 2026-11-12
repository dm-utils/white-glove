extends Control
## My street (phase 5): the things your street got from cleaning up (street points), what comes next, and your
## mastery per hero. Show only. Debug entry: --scene=street

const INK := Color("2B3A4A")
const ART := "res://assets/props/deco_%s.svg"

var _street: Control


func _ready() -> void:
	theme = UiTheme.get_theme()
	Platform.entered("street")
	var bg := TextureRect.new()
	bg.texture = UiTheme.sky_gradient()
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var p: Dictionary = Platform.load_profile()
	var pts := int(p.get("street_points", 0))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	add_child(box)
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 80
	box.offset_right = -80
	box.offset_top = 40
	box.offset_bottom = -40
	SafeArea.apply(self)
	var title := Label.new()
	title.text = tr("STREET_TITLE")
	title.label_settings = UiTheme.heading(84)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var sub := Label.new()
	sub.text = summary(p)
	sub.label_settings = UiTheme.heading(36, INK, 0)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)

	# the street picture with every spot: earned things in colour, the rest as a shadow with its points
	_street = Control.new()
	_street.custom_minimum_size = Vector2(0, 500)
	_street.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_street.draw.connect(_draw_street)
	_street.resized.connect(_place_items.bind(p, pts))
	box.add_child(_street)

	# mastery per hero
	var heroes := HBoxContainer.new()
	heroes.alignment = BoxContainer.ALIGNMENT_CENTER
	heroes.add_theme_constant_override("separation", 40)
	box.add_child(heroes)
	var owned: Array = ["runner"] + (p.get("unlocked_characters", []) as Array)
	for c in Content.characters():
		var col := HBoxContainer.new()
		col.add_theme_constant_override("separation", 8)
		heroes.add_child(col)
		var pic := TextureRect.new()
		pic.texture = load("res://assets/people/%s.svg" % str(c.id))
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.custom_minimum_size = Vector2(80, 96)
		if not owned.has(str(c.id)):
			pic.modulate = Color(0, 0, 0, 0.3)
		col.add_child(pic)
		var l := Label.new()
		var t := Mastery.tier((p.get("mastery", {}) as Dictionary).get(str(c.id), {}))
		l.text = "%s\n%s" % [tr(str(c.name_key)), Mastery.tier_name(t) if t > 0 else "–"]
		l.label_settings = UiTheme.heading(28, INK, 0)
		col.add_child(l)

	var back := Button.new()
	back.text = tr("COMMON_BACK")
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back.pressed.connect(func() -> void: get_tree().change_scene_to_file(Boot.SCENES["menu"]))
	box.add_child(back)


## "340 street points · next: a tree at 120" (pure, tested).
static func summary(p: Dictionary) -> String:
	var pts := int(p.get("street_points", 0))
	var text := TranslationServer.translate("STREET_POINTS").format({"count": pts})
	var w := Rewards.walk(Street.items(), pts, pts)
	if not (w.next as Dictionary).is_empty():
		text += " · " + TranslationServer.translate("STREET_NEXT").format({"name": TranslationServer.translate(str(w.next.name_key)), "at": int(w.next.at)})
	return text


func _place_items(p: Dictionary, pts: int) -> void:
	for ch in _street.get_children():
		ch.queue_free()
	var have := Street.owned(p).map(func(it: Dictionary) -> String: return str(it.id))
	var spots: Array = Street.items().duplicate()
	for s in Season.all():
		if s.has("item") and have.has(str(s.item.id)):
			spots.append(s.item)
	var k := _street.size.y / 500.0
	for it in spots:
		var pic := TextureRect.new()
		pic.texture = load(ART % str(it.id))
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.custom_minimum_size = Vector2(200, 200) * k
		pic.size = pic.custom_minimum_size
		# the art's foot point (100, 150) on the spot
		pic.position = Vector2(float(it.x) * _street.size.x, float(it.y) * _street.size.y) - Vector2(100, 150) * k
		_street.add_child(pic)
		if not have.has(str(it.id)):
			pic.modulate = Color(0.1, 0.15, 0.2, 0.28)
			var l := Label.new()
			l.text = str(int(it.get("at", 0)))
			l.label_settings = UiTheme.heading(30, Color.WHITE, 8)
			l.position = pic.position + Vector2(70, 60) * k
			_street.add_child(l)


func _draw_street() -> void:
	var r := Rect2(Vector2.ZERO, _street.size)
	var houses_h := r.size.y * 0.34
	_street.draw_rect(Rect2(0, 0, r.size.x, houses_h), Color("F1E3C8"))
	var roofs := [Color("C4553F"), Color("D9825B"), Color("8E9BB0"), Color("6F9E7F"), Color("C4553F")]
	var w := r.size.x / roofs.size()
	for i in roofs.size():
		_street.draw_rect(Rect2(i * w, 0, w, houses_h * 0.45), roofs[i])
		_street.draw_rect(Rect2(i * w + w * 0.2, houses_h * 0.55, w * 0.25, houses_h * 0.3), Color("8FC3E8"))
		_street.draw_rect(Rect2(i * w + w * 0.6, houses_h * 0.5, w * 0.2, houses_h * 0.5), Color("8A5A2E"))
		_street.draw_line(Vector2(i * w, 0), Vector2(i * w, houses_h), INK, 3.0)
	_street.draw_rect(Rect2(0, houses_h, r.size.x, r.size.y * 0.12), Color("DCD6CA"))
	_street.draw_rect(Rect2(0, houses_h + r.size.y * 0.12, r.size.x, r.size.y - houses_h - r.size.y * 0.12), Color("9DBF5A"))
	_street.draw_rect(r, INK, false, 5.0)
