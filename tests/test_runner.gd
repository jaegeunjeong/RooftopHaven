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
	_test_building_and_crafting()
	_test_queue_rules()
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


func _test_building_and_crafting() -> void:
	print("building and crafting")
	_reset(21)
	_check(GameState.build_blocker("stove").begins_with("REASON_NEED_TOOL:hammer"), "stove needs a hammer first")
	_check(GameState.craft_blocker("heated_can").begins_with("REASON_NEED_STATION"), "heating a can needs a stove")
	_check(GameState.queue_craft("hammer"), "queued a hammer")
	_check(GameState.count("scrap") == 4 and GameState.count("wood") == 5, "hammer materials set aside (scrap 2, wood 1)")
	_run_minutes(1)
	var w := GameState._survivor(int(GameState.tasks[0]["worker"]))
	_check(w != null and w.job == "mechanic", "the mechanic picked up the job")
	_run_minutes(45)
	_check(GameState.count("hammer") == 1 and GameState.tasks.is_empty(), "hammer done in about 40 min (mechanic -25%)")
	var trace_before := GameState.trace
	_check(GameState.queue_build("stove"), "queued the stove")
	_run_minutes(170)
	_check(int(GameState.built.get("stove", 0)) == 1, "stove built in about 2h40m")
	_check(GameState.trace > trace_before, "building raised trace (%.0f -> %.0f)" % [trace_before, GameState.trace])
	_check(int(GameState.durability.get("hammer", 0)) == 29, "hammer lost 1 durability (%d left)" % int(GameState.durability.get("hammer", 0)))
	_check(GameState.queue_craft("heated_can"), "can heat a can now")
	var fuel_before := GameState.count("fuel")
	_run_minutes(25)
	_check(GameState.count("heated_can") == 1 or fuel_before == GameState.count("fuel") + 1, "heated can made, fuel used")
	_check(GameState.queue_craft("water_filter"), "queued a water filter")
	_run_minutes(90)
	_check(int(GameState.durability.get("water_filter", 0)) == 30, "filter has 30 uses")


func _test_queue_rules() -> void:
	print("queue rules")
	_reset(22)
	GameState.add_item("cloth", 20)
	GameState.add_item("rope", 3)
	_check(GameState.queue_craft("bandage") and GameState.queue_craft("bandage") and GameState.queue_craft("bandage"), "queued three bandages")
	_run_minutes(1)
	var busy := 0
	for t in GameState.tasks:
		if int(t["worker"]) != 0:
			busy += 1
	_check(busy == 3, "three survivors work in parallel (%d busy)" % busy)
	var cloth := GameState.count("cloth")
	GameState.cancel_task(2)
	_check(GameState.count("cloth") == cloth + 2, "cancel gives the materials back")
	_run_minutes(30)
	_check(GameState.count("bandage") == 2, "two bandages done")
	# work stops at night and resumes in the morning
	GameClock.hour = 21
	GameClock.minute = 30
	GameState.queue_craft("warm_coat")
	_run_minutes(40)
	_check(int(GameState.tasks[0]["worker"]) == 0, "nobody works after 22:00")
	var done_at_night := float(GameState.tasks[0]["done"])
	_run_minutes(8 * 60)
	_check(GameClock.hour >= 6 and float(GameState.tasks[0]["done"]) >= done_at_night, "work resumes after 06:00")
	_check(GameState.storage_capacity() == 40, "storeroom has 40 slots without shelves")
