class_name Raids
extends RefCounted
## Night raids (grey-box step 5, retuned after the first playtest).
## At 22:00 the night is rolled: the infected come with a base chance plus the
## trace, and from day 8 raiders come every few days for the storeroom. Each
## raid arrives at a random time before dawn. Someone awake on watch hears them
## coming and the player can wake everybody up. Then defense is compared with
## strength and the outcome table is applied.

signal changed
signal resolved(report: Dictionary)
signal warning(info: Dictionary)

var gs: Node
var tonight: Array[Dictionary] = []   # {"kind", "minute", "strength", "warned"}
var history: Array[Dictionary] = []
var durability: Dictionary = {}       # defense facility id -> Array[int] per copy
var raider_day: int = 0
var all_awake: bool = false           # "wake everyone" was pressed tonight
var _saved_guards: Dictionary = {}


func _init(state: Node) -> void:
	gs = state


func reset() -> void:
	tonight.clear()
	history.clear()
	durability.clear()
	all_awake = false
	_saved_guards.clear()
	var rd: Array = cfg()["raiders"]["first_day"]
	raider_day = gs._rng.randi_range(int(rd[0]), int(rd[1]))


func cfg() -> Dictionary:
	return GameData.night


# ------------------------------------------------------------------ estimates for the screen

func _by_day(table: Array, day: int, fallback: float) -> float:
	for row: Array in table:
		if day >= int(row[0]) and day <= int(row[1]):
			return float(row[2])
	return fallback


## Chance that the infected come tonight (base chance for the day + trace).
func chance_tonight() -> float:
	var inf: Dictionary = cfg()["infected"]
	var day := GameClock.day
	if _is_final_night(day):
		return 1.0
	var p: float = _by_day(inf["base_chance_by_day"], day, 0.2) + float(gs.trace) * float(inf["chance_per_trace"])
	p = min(p, float(inf["chance_max"]))
	if gs.weather_today() == "rain":
		p *= float(inf["rain_mult"])
	return p


func strength_tonight() -> int:
	var inf: Dictionary = cfg()["infected"]
	var day := GameClock.day
	var st := int(_by_day(inf["strength_by_day"], day, 2.0)) + int(floor(float(gs.trace) / 5.0)) * int(inf["strength_per_5_trace"])
	if _is_final_night(day):
		st += int(inf["final_night_bonus"])
	for fid: String in gs.built:
		var eff: Dictionary = GameData.facility(fid).get("effects", {})
		st += int(eff.get("infected_strength", 0)) * int(gs.built[fid])
	return max(0, st)


func raider_strength() -> int:
	return int(_by_day(cfg()["raiders"]["strength_by_day"], GameClock.day, 5.0))


func raiders_tonight() -> bool:
	return GameClock.day == raider_day and GameClock.day < int(GameData.config["prototype"]["run_days"])


## Who fights: with a can alarm (or after "wake everyone") all at the base,
## otherwise only those on watch. At most `guard_cap` count.
func guards() -> Array[Survivor]:
	var out: Array[Survivor] = []
	var alarm := int(gs.built.get("can_alarm", 0)) > 0 or all_awake
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
	var guard_points := float(g.size()) * float(cfg()["defense"]["guard_value"])
	for fid: String in gs.built:
		var eff: Dictionary = GameData.facility(fid).get("effects", {})
		if int(gs.built[fid]) > 0 and not g.is_empty():
			guard_points *= float(eff.get("guard_mult", 1.0))
			guard_points += float(eff.get("guard_bonus", 0))
	var weapons: int = min(g.size(), gs.count("iron_pipe"))
	return gs.defense_from_facilities() + int(floor(guard_points)) + weapons


func outcome_for(margin: int) -> String:
	for o: Dictionary in cfg()["outcomes"]:
		if margin >= int(o["min_margin"]):
			return String(o["result"])
	return "breach"


## How long before a raid someone on watch hears it (0 = nobody will).
func warning_minutes() -> int:
	var awake_guard := false
	for s in gs.survivors:
		if s.is_active() and s.at_base and s.guard:
			awake_guard = true
	if not awake_guard:
		return 0
	var best := int(cfg()["warning"]["guard_minutes"])
	for fid: String in gs.built:
		if int(gs.built[fid]) > 0:
			best = max(best, int(GameData.facility(fid).get("effects", {}).get("warning_minutes", 0)))
	return best


# ------------------------------------------------------------------ the night

func tick() -> void:
	if GameClock.hour == int(cfg().get("raid_check_hour", 22)) and GameClock.minute == 0:
		_roll_night()
	var now := _now()
	for r in tonight.duplicate():
		if not r["warned"]:
			var w := warning_minutes()
			if w > 0 and now >= int(r["minute"]) - w:
				r["warned"] = true
				warning.emit({"kind": r["kind"], "minutes": int(r["minute"]) - now})
				gs.warn("WARN_RAID_HEARD_" + String(r["kind"]).to_upper(), null)
		if now >= int(r["minute"]):
			tonight.erase(r)
			_resolve(r)


func morning() -> void:
	tonight.clear()
	if all_awake:
		for s in gs.survivors:
			s.guard = bool(_saved_guards.get(s.id, false))
		all_awake = false
		_saved_guards.clear()
	changed.emit()


## "Wake everyone": all at the base get up and fight tonight.
func wake_all() -> void:
	if all_awake:
		return
	all_awake = true
	_saved_guards.clear()
	for s in gs.survivors:
		_saved_guards[s.id] = s.guard
		if s.is_active() and s.at_base:
			s.guard = true
	gs.warn("WARN_WOKE_ALL", null)
	changed.emit()


func _roll_night() -> void:
	tonight.clear()
	var rng: RandomNumberGenerator = gs._rng
	if rng.randf() < chance_tonight():
		tonight.append({"kind": "infected", "minute": _now() + rng.randi_range(60, 6 * 60),
				"strength": strength_tonight(), "warned": false})
	if raiders_tonight():
		tonight.append({"kind": "raiders", "minute": _now() + rng.randi_range(60, 6 * 60),
				"strength": raider_strength(), "warned": false})
		var iv: Array = cfg()["raiders"]["interval_days"]
		raider_day = GameClock.day + rng.randi_range(int(iv[0]), int(iv[1]))
	changed.emit()


func _resolve(raid: Dictionary) -> void:
	var st := int(raid["strength"])
	var kind := String(raid["kind"])
	var trap_used := false
	if gs.count("spike_trap") > 0:
		gs.take_item("spike_trap")
		st += int(GameData.item("spike_trap").get("raid_strength", -2))
		trap_used = true
	var g := guards()
	var dfn := defense()
	var result := outcome_for(dfn - st)
	var rng: RandomNumberGenerator = gs._rng
	var report := {"kind": "raid", "enemy": kind, "strength": st, "defense": dfn, "guards": g.size(),
			"result": result, "injuries": [], "broken": [], "lost": {}, "trap": trap_used}
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
			if kind == "infected":
				gs.trace = max(0.0, float(gs.trace) + float(row.get("trace", -2)))
		"held":
			for s in g:
				s.health = max(0.0, s.health + float(row.get("guard_health", 0)))
			if not g.is_empty() and rng.randf() < float(row.get("guard_light_injury", 0.3)):
				var s: Survivor = g[rng.randi_range(0, g.size() - 1)]
				gs.injure(s, "light")
				report["injuries"].append({"id": s.id, "kind": "light"})
			_wear_defense(report)
		"partial":
			var hurt: Array[Survivor] = g if not g.is_empty() else at_base.slice(0, 1)
			for s in hurt:
				if rng.randf() < float(row.get("guard_injury", 0.6)):
					var k := "serious" if rng.randf() < float(row.get("serious_share", 0.25)) else "light"
					s.health = max(0.0, s.health + float(row.get("victim_health", 0)))
					gs.injure(s, k)
					report["injuries"].append({"id": s.id, "kind": k})
			if kind == "raiders":
				_steal(float(row.get("raider_steal", 0.1)), report)
			else:
				for i in int(row.get("infected_break_facilities", 1)):
					_break_facility(report)
		_:
			var pool := at_base.duplicate()
			for i in min(rng.randi_range(1, 2), pool.size()):
				var s: Survivor = pool.pop_at(rng.randi_range(0, pool.size() - 1))
				s.health = max(0.0, s.health + float(row.get("victim_health", 0)))
				gs.injure(s, "serious")
				report["injuries"].append({"id": s.id, "kind": "serious"})
			_steal(float(row.get("storage_loss", 0.25)), report)
			var br: Array = row.get("break_facilities", [1, 2])
			for i in rng.randi_range(int(br[0]), int(br[1])):
				_break_facility(report)
			gs.change_morale(float(row.get("morale", -10)))
	_count_nail_boards(report)
	history.append(report)
	gs.warn("WARN_RAID_" + result.to_upper(), null)
	changed.emit()
	gs.built_changed.emit()
	resolved.emit(report)


func _steal(fraction: float, report: Dictionary) -> void:
	for id: String in gs.inventory.keys():
		var n := int(floor(gs.count(id) * fraction))
		if n > 0:
			gs.take_item(id, n)
			report["lost"][id] = int(report["lost"].get(id, 0)) + n


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
