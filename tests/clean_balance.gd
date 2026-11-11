class_name CleanBalanceRunner
extends Node
## White Glove balance runner (phase 2): many all-bot matches headless.
##   godot --headless --path . res://tests/clean_balance.tscn -- --matches=60 --level=normal --seed=1
## Goals: blue and orange each win 45-55 % of decided matches; under 25 % of the dropped litter is left at the end.


func _ready() -> void:
	var args := Boot.parse(OS.get_cmdline_user_args())
	var r := run(int(args.get("matches", "40")), str(args.get("level", "normal")), int(args.get("seed", "1")))
	for line in r.lines:
		print(line)
	get_tree().quit(0 if r.ok or args.get("report", "") == "1" else 1)


static func run(matches: int, level: String, base_seed: int) -> Dictionary:
	var wins := [0, 0]
	var draws := 0
	var points := 0
	var left := 0
	var dropped := 0
	var catches := 0
	var t0 := Time.get_ticks_msec()
	for i in matches:
		var m := CleanMatch.create(base_seed + i * 7919, "", 6, level)
		while not m.finished():
			m.step()
		var s := m.sim
		points += s.score_0 + s.score_1
		left += s.litter.size()
		dropped += s.dropped
		for h in s.ents:
			catches += h.catches
		if s.score_0 == s.score_1:
			draws += 1
		else:
			wins[0 if s.score_0 > s.score_1 else 1] += 1
	var decided := maxi(1, wins[0] + wins[1])
	var blue: float = 100.0 * wins[0] / decided
	var left_pct: float = 100.0 * left / maxi(1, dropped)
	var ok := blue >= 45.0 and blue <= 55.0 and left_pct < 25.0
	var lines := [
		"clean balance: %d matches, level %s, %.1f s wall" % [matches, level, (Time.get_ticks_msec() - t0) / 1000.0],
		"clean balance: blue wins %.0f %%, orange %.0f %%, draws %d; points per team per match %.0f; catches per match %.1f; litter left %.0f %% of dropped" % [
			blue, 100.0 - blue, draws, float(points) / maxi(1, matches * 2), float(catches) / maxi(1, matches), left_pct],
		"clean balance: %s" % ("within goals" if ok else "OUTSIDE goals"),
	]
	return {"ok": ok, "lines": lines, "blue_pct": blue, "left_pct": left_pct}
