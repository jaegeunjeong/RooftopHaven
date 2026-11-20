class_name Expeditions
extends RefCounted
## Sending survivors out (grey-box step 4). Owned by GameState.
## A team leaves with gear picked automatically from the storeroom, their bars
## keep dropping in real time, and when they come back the loot, injuries and
## trace are rolled. The player can call a team back at any time.

signal changed
signal returned(report: Dictionary)

const TOOL_PRIORITY := ["crowbar", "iron_pipe", "hatchet"]
const SURVIVAL_PRIORITY := ["canteen", "sleeping_bag"]
const CLOTHING_PRIORITY := ["padded_workwear", "warm_coat"]

var gs: Node
var active: Array[Dictionary] = []
var stock: Dictionary = {}       # location id -> 0.3 .. 1.0 (how much is left to loot)
var _next_id := 1
var trips := 0


func _init(state: Node) -> void:
	gs = state


func reset() -> void:
	active.clear()
	stock.clear()
	_next_id = 1
	trips = 0
	for lid: String in GameData.locations:
		stock[lid] = 1.0


func rules() -> Dictionary:
	return GameData.location_rules


# ------------------------------------------------------------------ queries

## How many teams may be out at once (3 or fewer survivors: 1, 4+: 2).
func max_teams() -> int:
	var t: Dictionary = rules().get("teams", {})
	var n := 0
	for s in gs.survivors:
		if s.is_active():
			n += 1
	if n >= 6 and int(gs.built.get("radio_antenna", 0)) > 0:
		return int(t.get("from_6_with_antenna", 3))
	if n >= 4:
		return int(t.get("from_4", 2))
	return int(t.get("up_to_3_survivors", 1))


## Why this survivor can't go right now ("" = can go).
func member_blocker(s: Survivor) -> String:
	if not s.is_active():
		return "REASON_NOT_ACTIVE"
	if not s.at_base:
		return "REASON_AWAY"
	if s.injury == "serious" or s.injury == "infected":
		return "REASON_TOO_HURT"
	if s.health < 30.0:
		return "REASON_TOO_WEAK"
	if s.stamina < 30.0 or s.forced_sleep_minutes > 0:
		return "REASON_TOO_TIRED"
	return ""


func dispatch_blocker(lid: String, ids: Array) -> String:
	if not GameData.locations.has(lid):
		return "REASON_NOT_BUILDABLE"
	if GameClock.day < int(GameData.locations[lid].get("from_day", 1)):
		return "REASON_NOT_YET"
	if active.size() >= max_teams():
		return "REASON_TEAM_LIMIT"
	if ids.is_empty():
		return "REASON_PICK_TEAM"
	if ids.size() > 3:
		return "REASON_TEAM_TOO_BIG"
	var at_base := 0
	for s in gs.survivors:
		if s.is_active() and s.at_base:
			at_base += 1
	if at_base - ids.size() < 1:
		return "REASON_KEEP_ONE"
	for sid: int in ids:
		var s: Survivor = gs._survivor(sid)
		if s == null:
			return "REASON_PICK_TEAM"
		var b := member_blocker(s)
		if b != "":
			return b
	return ""


## Trip length in in-game minutes (runner -25%).
func trip_minutes(lid: String, members: Array) -> float:
	var hours := float(GameData.locations[lid]["hours"])
	for s: Survivor in members:
		var m := float(GameData.job(s.job).get("expedition", {}).get("time_mult", 1.0))
		if m < 1.0:
			hours *= m
			break
	return hours * 60.0


## Injury chance per member for a team.
func injury_chance(lid: String, members: Array, gear: Dictionary = {}) -> float:
	var base := float(GameData.locations[lid]["injury"])
	var mult := float(rules()["team_injury"].get(str(clampi(members.size(), 1, 3)), 1.0))
	var p := base * mult
	for s: Survivor in members:
		p *= float(GameData.job(s.job).get("expedition", {}).get("team_injury_mult", 1.0))
	if int(gear.get("padded_workwear", 0)) >= members.size() and members.size() > 0:
		p *= float(GameData.item("padded_workwear").get("injury_mult", 1.0))
	return p


## What the team would take: one tool, one survival item and one piece of
## clothing each (best first), plus one ration and one bottle of water each.
func pick_gear(members: Array, lid: String = "") -> Dictionary:
	var gear: Dictionary = {}
	if lid != "" and gs.count("torch") > 0 and estimate_trip(lid, members, false)["night"] > 0.0:
		gear["torch"] = 1
	var rain: bool = gs.weather_today() == "rain"
	var clothing: Array = (["poncho"] + CLOTHING_PRIORITY) if rain else CLOTHING_PRIORITY + ["poncho"]
	for i in members.size():
		for list: Array in [TOOL_PRIORITY, SURVIVAL_PRIORITY, clothing]:
			for id: String in list:
				if gs.count(id) - int(gear.get(id, 0)) > 0:
					gear[id] = int(gear.get(id, 0)) + 1
					break
	var n := members.size()
	gear["bandage"] = min(gs.count("bandage"), 1)
	var food_id: String = "ration" if gs.count("ration") > 0 else "canned_food"
	gear[food_id] = int(gear.get(food_id, 0)) + min(gs.count(food_id), n)
	var water_id: String = "clean_water" if gs.count("clean_water") >= n else "bottled_water"
	gear[water_id] = int(gear.get(water_id, 0)) + min(gs.count(water_id), n)
	for k: String in gear.keys():
		if int(gear[k]) <= 0:
			gear.erase(k)
	return gear


## Night rules for expeditions (22:00-06:00 out there): slower, more
## dangerous, but more to find. A torch halves the downsides.
func night_rules() -> Dictionary:
	return rules().get("night", {})


func is_night_hour(hour: int) -> bool:
	var n := night_rules()
	return hour >= int(n.get("from_hour", 22)) or hour < int(n.get("to_hour", 6))


func travel_rate(has_torch: bool) -> float:
	var slow := float(night_rules().get("travel_mult", 1.25)) - 1.0
	if has_torch:
		slow *= float(GameData.item("torch").get("expedition", {}).get("night_penalty_mult", 0.5))
	return 1.0 / (1.0 + slow)


## Walk the clock forward to see how long a trip takes and how much of it is at night.
func estimate_trip(lid: String, members: Array, has_torch: bool) -> Dictionary:
	var need := trip_minutes(lid, members)
	var done := 0.0
	var real := 0
	var night := 0.0
	var minute_of_day := GameClock.hour * 60 + GameClock.minute
	while done < need and real < 3 * 1440:
		var at_night := is_night_hour(((minute_of_day + real) / 60) % 24)
		done += travel_rate(has_torch) if at_night else 1.0
		if at_night:
			night += 1.0
		real += 1
	return {"real": float(real), "night": night}


func team_loot_mult(n: int) -> float:
	return float(rules()["team_loot"].get(str(clampi(n, 1, 3)), 1.0))


func stock_of(lid: String) -> float:
	return float(stock.get(lid, 1.0))


# ------------------------------------------------------------------ actions

func dispatch(lid: String, ids: Array) -> bool:
	if dispatch_blocker(lid, ids) != "":
		return false
	var members: Array[Survivor] = []
	for sid: int in ids:
		members.append(gs._survivor(sid))
	var gear := pick_gear(members, lid)
	for id: String in gear:
		gs.take_item(id, int(gear[id]))
	var e := {
		"id": _next_id, "location": lid, "members": ids.duplicate(), "gear": gear,
		"total": trip_minutes(lid, members), "elapsed": 0.0,
		"recalled": false, "return_left": 0.0, "loot_fraction": 1.0,
		"rain_wear_done": false, "log": [], "out_minutes": 0.0, "night_minutes": 0.0,
	}
	_next_id += 1
	for s in members:
		# drop any building job they were doing
		var t: Dictionary = gs.task_of(s)
		if not t.is_empty():
			gs._release_worker(t)
		s.at_base = false
		s.expedition_id = e["id"]
		s.activity = Survivor.Activity.EXPEDITION
		s.guard = false
		s.wet = false
	_share_supplies(e, members)
	trips += 1
	gs.radio.schedule(e)
	active.append(e)
	gs.warn("WARN_EXP_LEFT", null, {"place": GameData.display_name(GameData.locations[lid])})
	changed.emit()
	gs.queue_changed.emit()
	return true


## Call a team back. The way home takes half the time spent so far, and they
## only bring what they found until now.
func recall(exp_id: int) -> void:
	for e in active:
		if int(e["id"]) == exp_id and not e["recalled"]:
			e["recalled"] = true
			e["loot_fraction"] = clamp(float(e["elapsed"]) / max(1.0, float(e["total"])), 0.0, 1.0)
			e["return_left"] = float(e["elapsed"]) * float(rules().get("recall_return_ratio", 0.5))
			gs.warn("WARN_EXP_RECALLED", null, {"place": GameData.display_name(GameData.locations[e["location"]])})
			changed.emit()


func members_of(e: Dictionary) -> Array[Survivor]:
	var out: Array[Survivor] = []
	for sid: int in e["members"]:
		var s: Survivor = gs._survivor(sid)
		if s:
			out.append(s)
	return out


func progress(e: Dictionary) -> float:
	if e["recalled"]:
		var back := float(e["elapsed"]) * float(rules().get("recall_return_ratio", 0.5))
		return 1.0 - float(e["return_left"]) / max(1.0, back)
	return float(e["elapsed"]) / max(1.0, float(e["total"]))


func minutes_left(e: Dictionary) -> float:
	if e["recalled"]:
		return float(e["return_left"])
	return float(e["total"]) - float(e["elapsed"])


# ------------------------------------------------------------------ every minute

func tick() -> void:
	var done: Array[Dictionary] = []
	for e in active:
		var members := members_of(e)
		# rain: a poncho keeps one member dry, the rest get wet
		if gs.weather_today() == "rain":
			var ponchos := int(e["gear"].get("poncho", 0))
			for s in members:
				s.wet = ponchos <= 0
				ponchos -= 1
			if not e["rain_wear_done"] and int(e["gear"].get("poncho", 0)) > 0:
				e["rain_wear_done"] = true
		# packed food and water are used when bars get low
		for s in members:
			if not s.is_active():
				continue
			if s.food < 40.0 and s.carried_food > 0:
				s.carried_food -= 1
				var fid := "ration" if int(e["gear"].get("ration", 0)) > 0 else "canned_food"
				s.food = min(100.0, s.food + float(GameData.item(fid).get("food", 25)))
				e["gear"][fid] = max(0, int(e["gear"].get(fid, 0)) - 1)
			if s.water < 40.0 and s.carried_water > 0:
				s.carried_water -= 1
				var wid := "clean_water" if int(e["gear"].get("clean_water", 0)) > 0 else "bottled_water"
				s.water = min(100.0, s.water + 30.0)
				e["gear"][wid] = max(0, int(e["gear"].get(wid, 0)) - 1)
		# someone collapsed out there: the team turns back carrying them
		var down := false
		for s in members:
			if s.life == Survivor.Life.COLLAPSED:
				down = true
		if down and not e["recalled"]:
			recall(int(e["id"]))
			gs.warn("WARN_EXP_CARRY", null, {"place": GameData.display_name(GameData.locations[e["location"]])})
		if e["recalled"]:
			e["return_left"] = float(e["return_left"]) - _rate_now(e)
			if float(e["return_left"]) <= 0.0:
				done.append(e)
		else:
			e["elapsed"] = float(e["elapsed"]) + _rate_now(e)
			if float(e["elapsed"]) >= float(e["total"]):
				done.append(e)
	for e in done:
		_finish(e)
	if not active.is_empty():
		changed.emit()


## Multiplier on the water bar's drop for this survivor while out (canteen).
func _rate_now(e: Dictionary) -> float:
	e["out_minutes"] = float(e["out_minutes"]) + 1.0
	if is_night_hour(GameClock.hour):
		e["night_minutes"] = float(e["night_minutes"]) + 1.0
		return travel_rate(int(e["gear"].get("torch", 0)) > 0)
	return 1.0


func night_share(e: Dictionary) -> float:
	return float(e["night_minutes"]) / max(1.0, float(e["out_minutes"]))


func water_decay_mult(s: Survivor) -> float:
	var e := _exp_of(s)
	if e.is_empty():
		return 1.0
	if int(e["gear"].get("canteen", 0)) > 0:
		return float(GameData.item("canteen").get("expedition", {}).get("water_decay_mult", 1.0))
	return 1.0


## Wet survivors tire 1.5x faster.
func stamina_decay_mult(s: Survivor) -> float:
	return 1.5 if s.wet else 1.0


func morning() -> void:
	var grow := float(rules().get("regrow_per_day", 0.1))
	for lid: String in stock:
		stock[lid] = min(1.0, float(stock[lid]) + grow)


# ------------------------------------------------------------------ coming home

func _finish(e: Dictionary) -> void:
	active.erase(e)
	var lid: String = e["location"]
	var loc: Dictionary = GameData.locations[lid]
	var members := members_of(e)
	var able: Array[Survivor] = []
	for s in members:
		if s.is_alive():
			able.append(s)
	var rng: RandomNumberGenerator = gs._rng
	var report := {"kind": "expedition", "location": lid, "members": e["members"].duplicate(),
			"loot": {}, "injuries": [], "trace": 0, "recalled": e["recalled"], "broken": []}
	# loot
	var frac := float(e["loot_fraction"])
	var nr := night_rules()
	var night := night_share(e)
	var torch := int(e["gear"].get("torch", 0)) > 0
	var night_penalty := night * (float(GameData.item("torch").get("expedition", {}).get("night_penalty_mult", 0.5)) if torch else 1.0)
	report["night"] = night
	var mult := team_loot_mult(able.size()) * stock_of(lid) * frac * (1.0 + float(nr.get("loot_bonus", 0.3)) * night)
	mult *= 1.0 + float(e.get("loot_mult_bonus", 0.0))
	var loot: Dictionary = {}
	for id: String in loc["loot"]:
		var r: Array = loc["loot"][id]
		var amount := int(round(float(rng.randi_range(int(r[0]), int(r[1]))) * mult))
		if amount > 0:
			loot[id] = amount
	if int(e["gear"].get("hatchet", 0)) > 0 and frac >= 0.5:
		var bonus: Dictionary = GameData.item("hatchet").get("loot_bonus", {})
		for id: String in bonus:
			loot[id] = int(loot.get(id, 0)) + int(bonus[id])
	var rare_mult := 1.0 + (float(nr.get("rare_mult", 2.0)) - 1.0) * night
	for _roll in 1 + int(e.get("extra_rare", 0)):
		for rare: Dictionary in loc.get("rare", []):
			if GameClock.day < int(rare.get("from_day", 0)):
				continue
			if rare.has("blueprint"):
				if rng.randf() < float(rare["chance"]) * frac * rare_mult:
					var bp := String(rare["blueprint"])
					if gs.blueprints.has(bp):
						loot["parts"] = int(loot.get("parts", 0)) + 2
					else:
						gs.blueprints[bp] = true
						report["blueprint"] = bp
						gs.change_morale(float(GameData.config["morale"]["daily"]["big_success"]))
						gs.warn("WARN_BLUEPRINT", null, {"item": GameData.display_name(GameData.facility(bp))})
				continue
			if not rare.has("item"):
				continue
			if rng.randf() < float(rare["chance"]) * frac * rare_mult:
				var c: Variant = rare.get("count", 1)
				var n := rng.randi_range(int(c[0]), int(c[1])) if c is Array else int(c)
				loot[rare["item"]] = int(loot.get(rare["item"], 0)) + n
	# bag space: 8 slots of 5 per survivor
	var cap := able.size() * int(rules().get("bag_slots", 8)) * int(rules().get("stack_in_bag", 5))
	var total := 0
	for id: String in loot.keys():
		var take: int = min(int(loot[id]), max(0, cap - total))
		total += take
		if take <= 0:
			loot.erase(id)
		else:
			loot[id] = take
	# injuries
	var p := injury_chance(lid, able, e["gear"]) * frac * (1.0 + (float(nr.get("injury_mult", 2.0)) - 1.0) * night_penalty) + float(_day_injury_add())
	var nurse_along := false
	for s in able:
		if s.job == "nurse":
			nurse_along = true
	var split: Dictionary = rules().get("injury_split", {"light": 0.8})
	for s in able:
		if not s.is_active() or rng.randf() >= p:
			continue
		var kind := "light" if rng.randf() < float(split.get("light", 0.8)) else "serious"
		if kind == "serious" and nurse_along and rng.randf() < float(GameData.job("nurse").get("expedition", {}).get("downgrade_serious_chance", 0.0)):
			kind = "light"
		if kind == "light" and int(e["gear"].get("bandage", 0)) > 0:
			# a packed bandage patches it up on the spot
			e["gear"]["bandage"] = int(e["gear"]["bandage"]) - 1
			s.health = min(100.0, s.health + float(GameData.item("bandage").get("health", 15)))
			gs.change_morale(float(GameData.config["morale"]["daily"]["injury"]))
			report["injuries"].append({"id": s.id, "kind": "patched"})
			continue
		gs.injure(s, kind)
		report["injuries"].append({"id": s.id, "kind": kind})
	# gear comes back (worn clothing loses a use; a poncho loses one more in the rain)
	var gear: Dictionary = e["gear"]
	for id: String in gear:
		var n := int(gear[id])
		if n <= 0:
			continue
		gs.add_item(id, n)
	for id: String in ["padded_workwear", "warm_coat"]:
		if int(gear.get(id, 0)) > 0:
			gs.wear(id)
	if e["rain_wear_done"]:
		gs.wear("poncho")
	if torch and night > 0.0:
		gs.wear("torch")
	var event_wear: Dictionary = e.get("wear", {})
	for id: String in event_wear:
		gs.wear(id, int(event_wear[id]))
	report["radio"] = e["log"].duplicate()
	for s in members:
		s.carried_food = 0
		s.carried_water = 0
	for id: String in loot:
		gs.add_item(id, int(loot[id]))
	report["loot"] = loot
	# back at the base
	for s in members:
		s.at_base = true
		s.expedition_id = 0
		s.wet = false
		if s.activity == Survivor.Activity.EXPEDITION:
			s.activity = Survivor.Activity.REST
		if s.life == Survivor.Life.COLLAPSED:
			gs._try_revive(s)
	stock[lid] = max(float(rules().get("depletion_floor", 0.3)), stock_of(lid) - float(rules().get("depletion_per_visit", 0.2)) * max(frac, 0.25))
	var auto: Dictionary = GameData.config["auto"]
	if GameClock.hour >= int(auto["sleep_from_hour"]) or GameClock.hour < int(auto["wake_hour"]):
		gs.trace += float(GameData.night["trace"]["sources"]["night_return"])
		report["trace"] = 1
	gs.warn("WARN_EXP_BACK", null, {"place": GameData.display_name(loc)})
	changed.emit()
	gs.queue_changed.emit()
	returned.emit(report)


func _day_injury_add() -> float:
	return 0.0  # the 10-day prototype stays in the first band of the day table


func _exp_of(s: Survivor) -> Dictionary:
	for e in active:
		if int(e["id"]) == s.expedition_id:
			return e
	return {}


func _share_supplies(e: Dictionary, members: Array[Survivor]) -> void:
	var food := 0
	var water := 0
	for id: String in e["gear"]:
		if id in ["ration", "canned_food"]:
			food += int(e["gear"][id])
		elif id in ["bottled_water", "clean_water"]:
			water += int(e["gear"][id])
	for s in members:
		s.carried_food = 1 if food > 0 else 0
		food -= s.carried_food
		s.carried_water = 1 if water > 0 else 0
		water -= s.carried_water
