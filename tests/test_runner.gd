extends Node
## Headless checks for the grey-box prototype.
## Run: godot --headless --path . res://tests/test_runner.tscn

var _fails := 0


func _ready() -> void:
	GameClock.set_process(false)  # drive time by hand
	await get_tree().process_frame
	_test_data()
	_test_two_days()
	_test_starvation_and_revive()
	_test_full_run_rescued()
	print("TESTS: %s (%d failed)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _reset(seed_value: int) -> void:
	GameClock.day = 1
	GameClock.hour = 6
	GameClock.minute = 0
	GameState.new_run(seed_value)


func _run_minutes(n: int) -> void:
	for i in n:
		GameClock._advance_minute()


func _test_data() -> void:
	print("data")
	_check(GameData.loaded, "GameData loaded without errors (%d errors)" % GameData.errors.size())
	_check(GameData.items.size() >= 30, "items loaded: %d" % GameData.items.size())
	_check(GameData.recipes.size() >= 10, "recipes loaded: %d" % GameData.recipes.size())
	var proto := 0
	for r: Dictionary in GameData.recipes.values():
		if r.get("prototype", false):
			proto += 1
	_check(proto == 10, "10 prototype recipes (found %d)" % proto)
	_check(GameData.events.size() == 3, "3 prototype radio events")


func _test_two_days() -> void:
	print("two days with starting supplies")
	_reset(11)
	var cans := GameState.count("canned_food")
	_run_minutes(48 * 60)
	_check(GameClock.day == 3 and GameClock.hour == 6, "clock at day 3 06:00")
	_check(GameState.living().size() == 3, "all three alive")
	var ok := true
	for s in GameState.survivors:
		for v: float in [s.health, s.food, s.water, s.stamina]:
			if v < 0.0 or v > 100.0:
				ok = false
	_check(ok, "all bars stay within 0..100")
	var eaten := cans - GameState.count("canned_food")
	_check(eaten >= 3 and eaten <= 8, "ate %d cans in 2 days of resting (1~2 each)" % eaten)
	_check(GameState.count("dirty_water") >= 4, "rain collector added dirty water each morning")
	for s in GameState.survivors:
		_check(s.stamina > 30.0, "%s slept and kept stamina (%.0f)" % [tr(s.name_key), s.stamina])


func _test_starvation_and_revive() -> void:
	print("no food or water at all")
	_reset(12)
	GameState.inventory.clear()
	GameState.built.erase("rain_collector")
	var seen := {"revived": 0, "died": 0}  # lambdas capture locals by value, so use a dictionary
	var on_warn := func(t: String) -> void:
		if t.contains("살려") or t.contains("brought"):
			seen["revived"] += 1
	var on_died := func(_s: Survivor) -> void: seen["died"] += 1
	GameState.warning.connect(on_warn)
	GameState.survivor_died.connect(on_died)
	_run_minutes(6 * 24 * 60)
	GameState.warning.disconnect(on_warn)
	GameState.survivor_died.disconnect(on_died)
	_check(seen["revived"] == 1, "nurse revived someone exactly once (%d)" % seen["revived"])
	_check(seen["died"] >= 1, "someone died after collapsing (%d deaths)" % seen["died"])
	_check(GameState.ended and GameState.result == &"wiped_out", "run ended as wiped out (result=%s, day %d)" % [GameState.result, GameClock.day])


func _test_full_run_rescued() -> void:
	print("well supplied 10-day run")
	_reset(13)
	GameState.add_item("canned_food", 60)
	GameState.add_item("bottled_water", 90)
	_run_minutes(10 * 24 * 60)
	_check(GameState.ended and GameState.result == &"rescued", "rescued by the helicopter (result=%s)" % GameState.result)
	var sc := GameState.compute_score()
	_check(sc >= 4000, "score %d grade %s" % [sc, GameState.grade(sc)])
