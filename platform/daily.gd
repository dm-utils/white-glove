class_name Daily
extends RefCounted
## The daily challenge (phase 5): "the cleanest street of today". The same street (seed) for everyone on a UTC day;
## the first one you play that day gives bonus street points, win or lose (data/my_street.json daily_bonus).


static func today(unix: float) -> String:
	return St33fPeriods.utc_day(int(unix))


## The seed for a day: the same on every device (pure, tested).
static func seed_for(day: String) -> int:
	return 1 + (day.hash() & 0x3FFFFFFF)


static func done(profile: Dictionary, day: String) -> bool:
	return str(profile.get("daily_done", "")) == day


## The match plan for Boot.next_match.
static func plan(unix: float) -> Dictionary:
	var day := today(unix)
	return {"seed": seed_for(day), "daily": day}


## After a daily match: the bonus once per day (added to the street points by the caller, so its unlocks count).
## Returns the bonus (0 when already done today or not a daily).
static func claim(profile: Dictionary, day: String) -> int:
	if day == "" or done(profile, day):
		return 0
	profile["daily_done"] = day
	return int(Content.load_json("res://data/my_street.json").get("daily_bonus", 50))
