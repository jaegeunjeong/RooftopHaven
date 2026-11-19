class_name Raids
extends RefCounted
## Night raids by the infected (grey-box step 5). Owned by GameState.
## At 22:00 the night is rolled from the trace; if they come, they arrive at a
## random hour before dawn and the base's defense is compared with their
## strength. Raiders (who target the storeroom) are not in the 10-day prototype.

signal changed
signal resolved(report: Dictionary)

var gs: Node
var tonight: Dictionary = {}     # {} or {"minute": absolute minute, "strength": int, "chance": float}
var history: Array[Dictionary] = []
var durability: Dictionary = {}  # defense facility id -> Array[int] remaining per copy


func _init(state: Node) -> void:
	gs = state


func reset() -> void:
	tonight.clear()
	history.clear()
	durability.clear()


func cfg() -> Dictionary:
	return GameData.night


# ------------------------------------------------------------------ estimates for the screen

## Chance that the infected come tonight, from the current trace.
func chance_tonight() -> float:
	var inf: Dictionary = cfg()["infected"]
	var day := GameClock.day
	if _is_final_night(day):
		return 1.0
	var p: float = float(gs.trace) * float(inf["chance_per_trace"])
	if day >= int(inf["base_from_day"]):
		p += float(inf["base_chance"])
	p = min(p, float(inf["chance_max"]))
	if gs.weather_today() == "rain":
		p *= float(inf["rain_mult"])
	return p


func strength_tonight() -> int:
	var inf: Dictionary = cfg()["infected"]
	var day := GameClock.day
	var base := 2
	for row: Array in inf["strength_by_day"]:
		if day >= int(row[0]) and day <= int(row[1]):
			base = int(row[2])
	var st := base + int(floor(float(gs.trace) / 5.0)) * int(inf["strength_per_5_trace"])
	if _is_final_night(day):
		st += int(inf["final_night_bonus"])
	for fid: String in gs.built:
		var eff: Dictionary = GameData.facility(fid).get("effects", {})
		st += int(eff.get("infected_strength", 0)) * int(gs.built[fid])
	return max(0, st)


## Survivors who would stand guard: with a can alarm everyone at the base wakes
## up, otherwise only those on night watch. At most `guard_cap` count.
func guards() -> Array[Survivor]:
	var out: Array[Survivor] = []
	var alarm := int(gs.built.get("can_alarm", 0)) > 0
	for s in gs.survivors:
		if not s.is_active() or not s.at_base or s.health < 30.0:
			continue
		if alarm or s.guard:
			out.append(s)
	var cap := int(cfg()["defense"]["guard_cap"])
	if out.size() > cap:
		out.resize(cap)
	return out


func defense() -> int:
	var g := guards()
	var weapons: int = min(g.size(), gs.count("iron_pipe"))
	return gs.defense_from_facilities() + g.size() * int(cfg()["defense"]["guard_value"]) + weapons


func outcome_for(margin: int) -> String:
	for o: Dictionary in cfg()["outcomes"]:
		if margin >= int(o["min_margin"]):
			return String(o["result"])
	return "breach"


# ------------------------------------------------------------------ the night

func tick() -> void:
	var raid_hour := int(cfg().get("raid_check_hour", 22))
	if GameClock.hour == raid_hour and GameClock.minute == 0:
		_roll_night()
	if not tonight.is_empty() and _now() >= int(tonight["minute"]):
		_resolve()


func _roll_night() -> void:
	tonight.clear()
	var p := chance_tonight()
	if gs._rng.randf() >= p:
		return
	# they arrive between 23:00 and 04:00
	var offset: int = gs._rng.randi_range(60, 6 * 60)
	tonight = {"minute": _now() + offset, "strength": strength_tonight(), "chance": p}
	changed.emit()


func _resolve() -> void:
	var st := int(tonight["strength"])
	tonight.clear()
	var g := guards()
	var dfn := defense()
	var margin := dfn - st
	var result := outcome_for(margin)
	var rng: RandomNumberGenerator = gs._rng
	var report := {"kind": "raid", "strength": st, "defense": dfn, "guards": g.size(),
			"result": result, "injuries": [], "broken": [], "lost": {}}
	var at_base: Array[Survivor] = []
	for s in gs.survivors:
		if s.is_active() and s.at_base:
			at_base.append(s)
	var row: Dictionary = {}
	for o: Dictionary in cfg()["outcomes"]:
		if String(o["result"]) == result:
			row = o
	match result:
		"perfect":
			gs.trace = max(0.0, float(gs.trace) + float(row.get("trace", -2)))
		"held":
			if not g.is_empty() and rng.randf() < float(row.get("guard_light_injury", 0.3)):
				var s: Survivor = g[rng.randi_range(0, g.size() - 1)]
				gs.injure(s, "light")
				report["injuries"].append({"id": s.id, "kind": "light"})
			_wear_defense(report)
		"partial":
			var hurt: Array[Survivor] = g if not g.is_empty() else at_base.slice(0, 1)
			for s in hurt:
				if rng.randf() < float(row.get("guard_injury", 0.6)):
					var kind := "serious" if rng.randf() < float(row.get("serious_share", 0.25)) else "light"
					gs.injure(s, kind)
					report["injuries"].append({"id": s.id, "kind": kind})
			for i in int(row.get("infected_break_facilities", 1)):
				_break_facility(report)
		_:
			var n_hurt := rng.randi_range(1, 2)
			var pool := at_base.duplicate()
			for i in min(n_hurt, pool.size()):
				var s: Survivor = pool.pop_at(rng.randi_range(0, pool.size() - 1))
				gs.injure(s, "serious")
				report["injuries"].append({"id": s.id, "kind": "serious"})
			var loss := float(row.get("storage_loss", 0.25))
			for id: String in gs.inventory.keys():
				var n := int(floor(gs.count(id) * loss))
				if n > 0:
					gs.take_item(id, n)
					report["lost"][id] = n
			var br: Array = row.get("break_facilities", [1, 2])
			for i in rng.randi_range(int(br[0]), int(br[1])):
				_break_facility(report)
			gs.change_morale(float(row.get("morale", -10)))
	# nail boards wear out after a few raids
	_count_nail_boards(report)
	history.append(report)
	gs.warn("WARN_RAID_" + result.to_upper(), null)
	changed.emit()
	gs.built_changed.emit()
	resolved.emit(report)


func on_built(fid: String) -> void:
	var eff: Dictionary = GameData.facility(fid).get("effects", {})
	var d := int(eff.get("durability", eff.get("breaks_after_raids", 0)))
	if d > 0:
		if not durability.has(fid):
			durability[fid] = []
		durability[fid].append(d)


func _wear_defense(report: Dictionary) -> void:
	var options: Array[String] = []
	for fid: String in durability:
		if GameData.facility(fid).get("effects", {}).has("durability") and not durability[fid].is_empty():
			options.append(fid)
	if options.is_empty():
		return
	var fid: String = options[gs._rng.randi_range(0, options.size() - 1)]
	durability[fid][0] = int(durability[fid][0]) - 1
	if int(durability[fid][0]) <= 0:
		_remove_one(fid)
		report["broken"].append(fid)


func _count_nail_boards(report: Dictionary) -> void:
	if not durability.has("nail_board"):
		return
	var list: Array = durability["nail_board"]
	for i in list.size():
		list[i] = int(list[i]) - 1
	var broken := 0
	for v: int in list:
		if v <= 0:
			broken += 1
	for i in broken:
		_remove_one("nail_board")
		report["broken"].append("nail_board")


## Break one built facility (never the workbench or the rain collector).
func _break_facility(report: Dictionary) -> void:
	var options: Array[String] = []
	for fid: String in gs.built:
		if int(gs.built[fid]) > 0 and not GameData.facility(fid).get("built_at_start", false):
			options.append(fid)
	if options.is_empty():
		return
	var fid: String = options[gs._rng.randi_range(0, options.size() - 1)]
	_remove_one(fid)
	report["broken"].append(fid)


func _remove_one(fid: String) -> void:
	gs.built[fid] = max(0, int(gs.built.get(fid, 0)) - 1)
	if durability.has(fid) and not durability[fid].is_empty():
		durability[fid].remove_at(0)
	gs.warn("WARN_FAC_BROKEN", null, {"item": GameData.display_name(GameData.facility(fid))})


func _is_final_night(day: int) -> bool:
	return day == int(GameData.config["prototype"]["run_days"]) - 1


func _now() -> int:
	return GameClock.day * 1440 + GameClock.hour * 60 + GameClock.minute
