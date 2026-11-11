extends Control
## The game itself comes in phase 2 (functional design 4). Until then this screen says so and leads back.
## Debug entry: --scene=game


func _ready() -> void:
	theme = UiTheme.get_theme()
	Platform.entered("game")
	var bg := TextureRect.new()
	bg.texture = UiTheme.sky_gradient()
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 30)
	add_child(box)
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var l := Label.new()
	l.text = tr("GAME_SOON")
	l.label_settings = UiTheme.heading(64)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(l)
	var back := Button.new()
	back.text = tr("RESULT_MENU")
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back.pressed.connect(func() -> void: get_tree().change_scene_to_file(Boot.SCENES["menu"]))
	box.add_child(back)
