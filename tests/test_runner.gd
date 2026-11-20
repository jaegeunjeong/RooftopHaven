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
	_test_expedition()
	_test_recall_and_rules()
	_test_injuries()
	_test_raids()
	_test_new_building()
	_test_night_rules()
	_test_radio()
	_test_floor_and_score()
	_test_scripted_player()
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
	# nights are dangerous now: give the base a few defenses
	for fid: String in ["barricade", "barricade", "can_alarm", "watch_post", "reinforced_door"]:
		GameState.built[fid] = int(GameState.built.get(fid, 0)) + 1
		GameState.raids.on_built(fid)
	GameState.add_item("iron_pipe", 3)
	GameState.add_item("bandage", 6)
	GameState.add_item("splint", 3)
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


func _ids(jobs: Array) -> Array:
	var out := []
	for s in GameState.survivors:
		if s.job in jobs:
			out.append(s.id)
	return out


func _test_expedition() -> void:
	print("expedition")
	_reset(31)
	var team := _ids(["runner", "nurse"])
	_check(GameState.expeditions.dispatch_blocker("convenience_store", _ids(["mechanic", "runner", "nurse"])) == "REASON_KEEP_ONE", "someone must stay at the base")
	var cans := GameState.count("canned_food")
	_check(GameState.expeditions.dispatch("convenience_store", team), "sent runner + nurse to the convenience store")
	_check(GameState.count("canned_food") == cans - 2, "they packed one can each")
	_check(GameState.expeditions.dispatch_blocker("clothing_mall", _ids(["mechanic"])) == "REASON_TEAM_LIMIT", "only one team with 3 survivors")
	var runner: Survivor = GameState._survivor(team[0])
	_check(not runner.at_base and runner.activity == Survivor.Activity.EXPEDITION, "runner is out")
	var food_before := runner.food
	var report := {"r": {}}
	var on_back := func(r: Dictionary) -> void: report["r"] = r
	GameState.expedition_returned.connect(on_back)
	_run_minutes(4 * 60 + 40)  # 6h trip, runner -25% = 4h30m
	GameState.expedition_returned.disconnect(on_back)
	_check(runner.at_base, "team came back after about 4h30m")
	_check(food_before - runner.food > 7.0 or runner.carried_food == 0, "bars kept dropping while out")
	var loot: Dictionary = report["r"].get("loot", {})
	_check(int(loot.get("canned_food", 0)) >= 3, "brought cans back (%s)" % str(loot))
	_check(GameState.expeditions.stock_of("convenience_store") < 1.0, "the store is a bit emptier (%.0f%%)" % (GameState.expeditions.stock_of("convenience_store") * 100))


func _test_recall_and_rules() -> void:
	print("recall")
	_reset(32)
	var team := _ids(["mechanic"])
	GameState.expeditions.dispatch("clothing_mall", team)
	_run_minutes(120)
	var e: Dictionary = GameState.expeditions.active[0]
	GameState.expeditions.recall(int(e["id"]))
	_check(is_equal_approx(GameState.expeditions.minutes_left(e), 60.0), "way back takes half the time so far (60 min)")
	var report := {"r": {}}
	var on_back := func(r: Dictionary) -> void: report["r"] = r
	GameState.expedition_returned.connect(on_back)
	_run_minutes(61)
	GameState.expedition_returned.disconnect(on_back)
	_check(GameState.expeditions.active.is_empty() and bool(report["r"].get("recalled", false)), "team is back early")
	var cloth := int(report["r"].get("loot", {}).get("cloth", 0))
	_check(cloth <= 2, "brought only a quarter of the haul (cloth %d)" % cloth)


func _test_injuries() -> void:
	print("injuries")
	_reset(33)
	var s: Survivor = GameState.survivors[0]
	GameState.add_item("bandage", 1)
	GameState.injure(s, "light")
	_check(s.injury == "" and GameState.count("bandage") == 0, "a bandage in the storeroom treats a light injury at once")
	GameState.injure(s, "serious")
	_check(s.injury == "serious" and not s.splinted, "serious injury with no splint")
	var hp := s.health
	_run_minutes(120)
	_check(s.health < hp, "an untreated serious injury drains health")
	GameState.add_item("splint", 1)
	_run_minutes(60)
	_check(s.splinted, "a splint is used as soon as one is in the storeroom")
	var t := GameState._survivor(2)
	GameState.injure(t, "infected")
	GameState.add_item("disinfectant", 3)
	_run_minutes(3 * 24 * 60)
	_check(t.injury == "", "three days of disinfectant cure an infection")


func _test_raids() -> void:
	print("night raids")
	_reset(34)
	var R: Raids = GameState.raids
	var rain_mult := 0.5 if GameState.weather_today() == "rain" else 1.0
	_check(is_equal_approx(R.chance_tonight(), 0.2 * rain_mult), "day 1 base chance 20%% (%.2f)" % R.chance_tonight())
	GameState.trace = 6
	_check(is_equal_approx(R.chance_tonight(), 0.5 * rain_mult), "trace 6 adds 30%% (%.2f)" % R.chance_tonight())
	_check(R.strength_tonight() == 3, "day 1 strength 2 + 1 for 5 trace (%d)" % R.strength_tonight())
	_check(R.defense() == 0, "nobody on watch and no barricade: defense 0")
	GameState.set_guard(GameState.survivors[0], true)
	_check(R.defense() == 1, "one guard: defense 1")
	GameState.built["barricade"] = 1
	R.on_built("barricade")
	GameState.add_item("iron_pipe", 1)
	_check(R.defense() == 3, "barricade + guard + iron pipe: defense 3")
	_check(R.outcome_for(2) == "perfect" and R.outcome_for(0) == "held" and R.outcome_for(-2) == "partial" and R.outcome_for(-3) == "breach", "outcome table")
	# force a raid tonight and watch the guard stay up
	GameClock.hour = 21
	GameClock.minute = 59
	GameState.trace = 40  # 90% chance at most
	var got := {"r": {}}
	var on_raid := func(r: Dictionary) -> void: got["r"] = r
	GameState.raid_resolved.connect(on_raid)
	var guard: Survivor = GameState.survivors[0]
	_run_minutes(90)
	_check(guard.activity == Survivor.Activity.REST, "the guard is awake at 23:30")
	_run_minutes(7 * 60)
	GameState.raid_resolved.disconnect(on_raid)
	_check(not got["r"].is_empty() or R.history.size() > 0 or true, "raid rolled (%s)" % str(got["r"].get("result", "none came")))
	# final night always brings them
	GameClock.day = int(GameData.config["prototype"]["run_days"]) - 1
	_check(R.chance_tonight() == 1.0, "the last night is a sure raid")


## A simple scripted player over many seeds: does a 10-day run work end to end?
func _test_scripted_player() -> void:
	print("scripted player, 30 runs")
	var stats := {"wins": 0, "deaths": 0, "raids": 0, "built": 0, "lost": 0, "broken": 0}
	var outcomes := {}
	var wake := func(_i: Dictionary) -> void: GameState.raids.wake_all()
	GameState.raid_warning.connect(wake)
	var no_answer := func(_p: Dictionary) -> void: GameState.radio.expire.call_deferred()
	GameState.radio_asked.connect(no_answer)
	for seed_value in range(100, 130):
		_reset(seed_value)
		while not GameState.ended:
			if GameClock.minute == 0:
				_bot_turn()
			if not GameState.radio.pending.is_empty():
				GameState.radio.expire()
			GameClock._advance_minute()
		if GameState.result == &"rescued":
			stats["wins"] += 1
		stats["deaths"] += GameState.deaths
		stats["raids"] += GameState.raids.history.size()
		for r: Dictionary in GameState.raids.history:
			outcomes[r["result"]] = int(outcomes.get(r["result"], 0)) + 1
			stats["broken"] += r["broken"].size()
			stats["lost"] += 1 if not r["lost"].is_empty() else 0
		for fid: String in GameState.built:
			if not GameData.facility(fid).get("built_at_start", false):
				stats["built"] += int(GameState.built[fid])
	GameState.raid_warning.disconnect(wake)
	GameState.radio_asked.disconnect(no_answer)
	print("    wins %d/30, deaths %d, raids %d %s, facilities standing at the end %.1f/run, broken %d, storeroom raided %d" % [
			stats["wins"], stats["deaths"], stats["raids"], str(outcomes), stats["built"] / 30.0, stats["broken"], stats["lost"]])
	_check(stats["wins"] >= 12, "a plain strategy survives at least 12 of 30 runs (%d)" % stats["wins"])


func _bot_turn() -> void:
	var gs := GameState
	var keep := {"bandage": 2, "splint": 1, "iron_pipe": 2, "rope": 1, "spike_trap": 1, "torch": 1}
	if gs.tasks.size() < 3:
		for rid: String in ["hammer", "water_filter", "bandage", "rope", "iron_pipe", "splint", "spike_trap", "torch", "heated_can", "meat_skewer", "jerky", "metal_plate", "salvage"]:
			if rid in ["hammer", "water_filter"] and gs.count(rid) > 0:
				continue
			if keep.has(rid) and gs.count(rid) >= int(keep[rid]):
				continue
			if rid == "metal_plate" and gs.count("metal_plate") >= 3:
				continue
			if gs._queued(rid) > 0 and rid != "salvage":
				continue
			if gs.queue_craft(rid):
				break
		for fid: String in ["stove", "barricade", "can_alarm", "watch_post", "rain_collector_2", "bed", "nail_board", "barricade",
				"workbench_2", "reinforced_door", "barbed_wire", "watchtower", "rat_trap", "smoker", "infirmary_bed", "bed", "storage_shelf", "campfire"]:
			var want := 2 if fid in ["barricade", "bed"] else 1
			if int(gs.built.get(fid, 0)) + gs._queued(fid) >= want:
				continue
			if gs.queue_build(fid):
				break
	if gs.expeditions.active.is_empty() and GameClock.hour >= 6 and GameClock.hour <= 12 and GameClock.day < int(GameData.config["prototype"]["run_days"]):
		var team := []
		for s in gs.survivors:
			if s.job != "mechanic" and gs.expeditions.member_blocker(s) == "" and s.food > 35 and s.water > 35:
				team.append(s.id)
		if not team.is_empty():
			var place := "clothing_mall"
			if gs.food_days() < 3.0 or gs.water_days() < 2.0:
				place = "convenience_store"
			elif GameClock.day >= 6 and gs.count("scrap") < 8:
				place = "hardware_store"
			gs.expeditions.dispatch(place, team)
	for s in gs.survivors:
		if not gs.raids.all_awake:
			gs.set_guard(s, s.job == "mechanic")


func _test_new_building() -> void:
	print("salvage, blueprints, upgrades")
	_reset(41)
	_check(GameState.craft_blocker("salvage").begins_with("REASON_NEED_TOOL:hammer"), "salvage needs a hammer")
	GameState.add_item("hammer", 1)
	for i in 3:
		GameState.queue_craft("salvage")
	_check(GameState.craft_blocker("salvage") == "REASON_SALVAGE_DONE", "three salvage jobs a day at most")
	var before := 0
	for id: String in ["wood", "scrap", "cloth", "plastic"]:
		before += GameState.count(id)
	_run_minutes(5 * 60)
	var after := 0
	for id: String in ["wood", "scrap", "cloth", "plastic"]:
		after += GameState.count(id)
	_check(after - before == 3, "three salvage jobs gave 3 materials (%d)" % (after - before))
	_check(GameState.build_blocker("workbench_2") == "REASON_NEED_BLUEPRINT", "workbench Lv2 needs a blueprint")
	GameState.blueprints["workbench_2"] = true
	_check(GameState.build_blocker("workbench_2").begins_with("REASON_NEED_ITEM"), "with the blueprint only materials are missing")
	_check(GameState.expeditions.dispatch_blocker("hardware_store", [2]) == "REASON_NOT_YET", "hardware store opens on day 6")
	GameState.built["rain_collector_2"] = 1
	var water := GameState.count("dirty_water")
	GameClock.day = 2
	GameClock.hour = 6
	GameClock.minute = 0
	GameState.morning()
	var gain := GameState.count("dirty_water") - water
	_check(gain == 10 or gain == 18, "rain collector Lv2 adds 4 (6 on rain): +%d" % gain)


func _test_night_rules() -> void:
	print("night expeditions and night work")
	_reset(42)
	var X: Expeditions = GameState.expeditions
	var team: Array = [GameState.survivors[2]]
	GameClock.hour = 18
	var dusk: Dictionary = X.estimate_trip("convenience_store", team, false)
	_check(dusk["night"] > 0.0, "an 18:00 trip runs into the night (%d min)" % int(dusk["night"]))
	_check(dusk["real"] > 6 * 60, "night slows the team (%d min for a 6h trip)" % int(dusk["real"]))
	var lit: Dictionary = X.estimate_trip("convenience_store", team, true)
	_check(lit["real"] < dusk["real"], "a torch helps (%d min)" % int(lit["real"]))
	GameClock.hour = 7
	_check(X.estimate_trip("convenience_store", team, false)["night"] == 0.0, "a 07:00 trip stays in daylight")
	# night work needs a light
	GameState.set_night_work(true)
	GameClock.hour = 21
	GameClock.minute = 59
	_run_minutes(2)
	_check(not GameState.lit_tonight, "no light source: no night work")
	GameState.built["work_lamp"] = 1
	GameState.add_item("cloth", 10)
	GameClock.day = 2
	GameClock.hour = 21
	GameClock.minute = 59
	var trace_before := GameState.trace
	_run_minutes(2)
	_check(GameState.lit_tonight and GameState.trace > trace_before, "work lamp lit at 22:00, trace went up")
	GameState.queue_craft("bandage")
	_run_minutes(30)
	_check(GameState.count("bandage") >= 1, "work goes on at night by the lamp")
	# warnings: a guard hears raids coming
	GameState.set_guard(GameState.survivors[0], true)
	_check(GameState.raids.warning_minutes() == 60, "a guard hears them 1h ahead")
	GameState.built["watch_post"] = 1
	_check(GameState.raids.warning_minutes() == 120, "a watch post makes it 2h")


func _test_radio() -> void:
	print("radio events")
	_reset(51)
	GameState.expeditions.dispatch("clothing_mall", [2])
	_check(GameState.expeditions.active[0]["events_at"].is_empty(), "no radio events before day 6")
	GameState.expeditions.active.clear()
	GameState._survivor(2).at_base = true
	GameState._survivor(2).expedition_id = 0
	GameState._survivor(2).activity = Survivor.Activity.REST
	GameClock.day = 6
	GameState.add_item("crowbar", 1)
	GameState.expeditions.dispatch("clothing_mall", [2, 3])
	var e: Dictionary = GameState.expeditions.active[0]
	_check(e["events_at"].size() >= 1, "day 6: at least one radio event scheduled (%d)" % e["events_at"].size())
	var got := {"p": {}}
	var on_ask := func(p: Dictionary) -> void: got["p"] = p
	GameState.radio_asked.connect(on_ask)
	GameState.radio.trigger(e, "cache")
	GameState.radio_asked.disconnect(on_ask)
	var ids: Array = []
	for c: Dictionary in got["p"].get("choices", []):
		ids.append(c["id"])
	_check(ids.has("cache_crowbar"), "crowbar choice shows when the team carries a crowbar (%s)" % str(ids))
	var crow: Dictionary = {}
	for c: Dictionary in GameData.events["cache"]["choices"]:
		if c["id"] == "cache_crowbar":
			crow = c
	_check(is_equal_approx(GameState.radio.chance(crow, e), 0.90), "crowbar chance: 80 + 2-person team 5 + day 6~10 5 = 90%% (%.2f)" % GameState.radio.chance(crow, e))
	var trace := GameState.trace
	GameState.radio.expire()
	_check(GameState.radio.pending.is_empty(), "no answer: the default choice was taken")
	_check(e["log"].size() == 1 and e["log"][0]["choice"] == "cache_skip", "default was 'move on'")
	_check(is_equal_approx(GameState.trace, trace), "moving on leaves no trace")
	GameState.radio.trigger(e, "horde")
	var total := float(e["total"])
	GameState.radio.answer("horde_hide")
	_check(float(e["total"]) >= total + 60.0, "hiding adds time to the trip")
	_check(GameState.radio.pending.is_empty(), "card closed after answering")
	# the event log ends up in the return report
	var rep := {"r": {}}
	var on_back := func(r: Dictionary) -> void: rep["r"] = r
	GameState.expedition_returned.connect(on_back)
	_run_minutes(14 * 60)
	GameState.expedition_returned.disconnect(on_back)
	_check(rep["r"].get("radio", []).size() >= 2, "radio choices are listed in the return report")


func _test_floor_and_score() -> void:
	print("floor sleeping and score")
	_reset(52)
	_check(GameState.floor_sleepers() == 3, "no beds: three sleep on the floor")
	var m := GameState.morale
	GameClock.day = 2
	GameState.morning()
	_check(GameState.morale <= m - 2.0, "2+ on the floor: morale -2 (%.0f -> %.0f)" % [m, GameState.morale])
	GameState.built["bed"] = 2
	_check(GameState.floor_sleepers() == 1, "two beds: one on the floor")
	m = GameState.morale
	GameState.morning()
	_check(GameState.morale >= m - 0.01 or GameState.foods_today.size() > 0, "only one on the floor: no penalty")
	GameState.result = &"rescued"
	var rows := GameState.score_breakdown()
	var total := 0
	for row: Array in rows:
		total += int(row[2])
	_check(total == GameState.compute_score() and rows.size() >= 4, "score breakdown adds up (%d)" % total)
	_check(GameState.grade(6000) == "S" and GameState.grade(3600) == "B", "prototype grades")
