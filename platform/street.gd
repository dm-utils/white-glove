class_name Street
extends RefCounted
## Your own street (phase 5): every match adds your own points as street points (never fewer); things for the street
## appear at fixed counts (data/my_street.json). A season (data/seasons.json) gives its thing for one match played in
## it, kept afterwards in profile.street_items. Show only, never power.


static func items() -> Array:
	return Content.load_json("res://data/my_street.json").get("items", [])


## Adds a match's points and grants what was reached: {earned, before, after, unlocked, next, season_item}.
static func add_points(profile: Dictionary, points: int, unix: float) -> Dictionary:
	var earned := maxi(0, points)
	var before := int(profile.get("street_points", 0))
	var after := before + earned
	profile["street_points"] = after
	var w := Rewards.walk(items(), before, after)
	var season_item := {}
	var s := Season.active(unix)
	if not s.is_empty() and s.has("item"):
		var owned: Array = profile.get("street_items", [])
		if not owned.has(str(s.item.id)):
			owned.append(str(s.item.id))
			profile["street_items"] = owned
			season_item = s.item
	return {"earned": earned, "before": before, "after": after, "unlocked": w.unlocked, "next": w.next, "season_item": season_item}


## Every thing your street has: the counted ones reached plus season things you earned.
static func owned(profile: Dictionary) -> Array:
	var pts := int(profile.get("street_points", 0))
	var out: Array = items().filter(func(it: Dictionary) -> bool: return int(it.at) <= pts)
	var extra: Array = profile.get("street_items", [])
	for s in Season.all():
		if s.has("item") and extra.has(str(s.item.id)):
			out.append(s.item)
	return out
