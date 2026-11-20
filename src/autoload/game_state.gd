extends Node
## State of the current run (autoload: GameState).
## Survivors and their four bars, automatic eating / drinking / sleeping,
## injuries, the storeroom, the work queue, daily rain water, food spoilage,
## base morale and the win / lose checks. Expeditions (Expeditions) and night
## raids (Raids) are helper objects that run on the same one-minute tick.

signal survivors_changed
signal inventory_changed
signal morale_changed(value: float)
signal warning(text: String)
signal survivor_died(survivor: Survivor)
signal run_ended(result: StringName, score: int)
signal queue_changed
signal built_changed
signal expedition_returned(report: Dictionary)
signal raid_resolved(report: Dictionary)
signal night_changed
signal raid_warning(info: Dictionary)
signal radio_asked(pending: Dictionary)
signal radio_answered(result: Dictionary)

const MIN_PER_HOUR := 60.0

var survivors: Array[Survivor] = []
var inventory: Dictionary = {}          # item id -> count
var raw_food: Array[Dictionary] = []    # {item, day} batches of anything that spoils
var durability: Dictionary = {}         # item id -> remaining uses, pooled over all copies
var tasks: Array[Dictionary] = []       # work queue, see queue_build() / queue_craft()
var cooks_today: int = 0
var blueprints: Dictionary = {}         # facility id -> true once found
var salvage_today: int = 0
var night_work: bool = false            # light up and keep working until 02:00
var lit_tonight: bool = false
var built: Dictionary = {}              # facility id -> count
var morale: float = 60.0
var morale_zero_minutes: int = 0
var trace: float = 0.0
var weather_by_day: Dictionary = {}     # day -> "clear" / "rain"
var revives_used: Dictionary = {}       # nurse survivor id -> true
var foods_today: Dictionary = {}
var foods_yesterday: Dictionary = {}
var deaths: int = 0
var joined: int = 0
var ended: bool = false
var result: StringName = &""

var expeditions: Expeditions
var raids: Raids
var radio: Radio

var _rng := RandomNumberGenerator.new()
var _warned: Dictionary = {}


func _init() -> void:
	expeditions = Expeditions.new(self)
	raids = Raids.new(self)
	radio = Radio.new(self)
	radio.asked.connect(func(p: Dictionary) -> void: radio_asked.emit(p))
	radio.answered.connect(func(r: Dictionary) -> void: radio_answered.emit(r))
	expeditions.returned.connect(func(r: Dictionary) -> void: expedition_returned.emit(r))
	raids.resolved.connect(func(r: Dictionary) -> void: raid_resolved.emit(r))
	raids.changed.connect(func() -> void: night_changed.emit())
	raids.warning.connect(func(i: Dictionary) -> void: raid_warning.emit(i))


func _process(delta: float) -> void:
	radio.process_real(delta)


func _ready() -> void:
	if not GameData.loaded:
		push_error("GameState: GameData failed to load; the run cannot start")
		return
	new_run()
	GameClock.minute_changed.connect(_on_minute)
	GameClock.day_started.connect(_on_day_started)


## Start a fresh run from config.json. `seed_value` 0 means random.
func new_run(seed_value: int = 0) -> void:
	if seed_value == 0:
		_rng.randomize()
	else:
		_rng.seed = seed_value
	var cfg: Dictionary = GameData.config
	var start: Dictionary = cfg["start"]
	survivors.clear()
	var next_id := 1
	for s: Dictionary in start["survivors"]:
		survivors.append(Survivor.new(next_id, s.get("name", ""), s["job"], float(start["stats"])))
		next_id += 1
	inventory = {}
	for k: String in start["inventory"]:
		inventory[k] = int(start["inventory"][k])
	raw_food.clear()
	durability.clear()
	tasks.clear()
	cooks_today = 0
	blueprints.clear()
	salvage_today = 0
	night_work = false
	lit_tonight = false
	for k: String in inventory:
		_add_durability(k, count(k))
	built.clear()
	for fid: String in GameData.facilities:
		if GameData.facilities[fid].get("built_at_start", false):
			built[fid] = 1
	morale = float(cfg["morale"]["start"])
	morale_zero_minutes = 0
	trace = 0.0
	revives_used.clear()
	foods_today.clear()
	foods_yesterday.clear()
	deaths = 0
	joined = 0
	ended = false
	result = &""
	_warned.clear()
	expeditions.reset()
	raids.reset()
	radio.reset()
	_make_weather()
	survivors_changed.emit()
	inventory_changed.emit()
	morale_changed.emit(morale)
	queue_changed.emit()
	built_changed.emit()


# ------------------------------------------------------------------ queries

func count(item_id: String) -> int:
	return int(inventory.get(item_id, 0))


func living() -> Array[Survivor]:
	var out: Array[Survivor] = []
	for s in survivors:
		if s.is_alive():
			out.append(s)
	return out


func weather_today() -> String:
	return String(weather_by_day.get(GameClock.day, "clear"))


## Food in the storeroom expressed as days for the current group.
func food_days() -> float:
	var food_points := 0.0
	for id: String in inventory:
		var it: Dictionary = GameData.item(id)
		if it.get("category", "") in ["food", "consumable"] and it.has("food"):
			food_points += float(it["food"]) * count(id)
	for batch in raw_food:
		if batch["item"] == "ingredients":
			food_points += 20.0  # two ingredients make a 40-point soup
	return food_points / max(1.0, _daily_need("food") * living().size())


func water_days() -> float:
	var water_points := 30.0 * (count("clean_water") + count("bottled_water"))
	water_points += 30.0 * min(count("dirty_water"), int(durability.get("water_filter", 0)))
	return water_points / max(1.0, _daily_need("water") * living().size())


func _daily_need(stat: String) -> float:
	var d: Dictionary = GameData.config["stats"]["decay_per_hour"][stat]
	var a: Dictionary = GameData.config["auto"]
	var sleep_h := float((24 - int(a["sleep_from_hour"])) + int(a["wake_hour"]))
	var work_h := float(int(a["work_to_hour"]) - int(a["work_from_hour"]))
	return float(d["sleep"]) * sleep_h + float(d["work"]) * work_h + float(d["rest"]) * (24.0 - sleep_h - work_h)


# ------------------------------------------------------------------ inventory

func add_item(item_id: String, n: int = 1) -> void:
	if n <= 0:
		return
	if _spoils(item_id):
		for i in n:
			raw_food.append({"item": item_id, "day": GameClock.day})
	_add_durability(item_id, n)
	inventory[item_id] = count(item_id) + n
	inventory_changed.emit()


func take_item(item_id: String, n: int = 1) -> bool:
	if count(item_id) < n:
		return false
	inventory[item_id] = count(item_id) - n
	if GameData.item(item_id).has("durability"):
		var per := int(GameData.item(item_id)["durability"])
		durability[item_id] = min(int(durability.get(item_id, 0)), count(item_id) * per)
	if _spoils(item_id):
		for i in n:
			for j in raw_food.size():
				if raw_food[j]["item"] == item_id:
					raw_food.remove_at(j)
					break
	inventory_changed.emit()
	return true


func _spoils(item_id: String) -> bool:
	return GameData.item(item_id).get("spoil_days") != null


func _add_durability(item_id: String, n: int) -> void:
	var it: Dictionary = GameData.item(item_id)
	if it.has("durability") and n > 0:
		durability[item_id] = int(durability.get(item_id, 0)) + int(it["durability"]) * n


## Use one durability point of a tool. When a copy wears out it leaves the storeroom.
func wear(item_id: String, uses: int = 1) -> void:
	if count(item_id) <= 0:
		return
	var per := int(GameData.item(item_id).get("durability", 1))
	durability[item_id] = max(0, int(durability.get(item_id, 0)) - uses)
	var left := int(ceil(float(durability[item_id]) / float(per)))
	if left < count(item_id):
		inventory[item_id] = left
		_warn("WARN_BROKE", null, {"item": GameData.display_name(GameData.item(item_id))})
		inventory_changed.emit()


## Storeroom slots in use / available (stack of `stack` per slot).
func storage_used() -> int:
	var stack := int(GameData.config["storage"]["stack"])
	var used := 0
	for id: String in inventory:
		used += int(ceil(float(count(id)) / float(stack)))
	return used


func storage_capacity() -> int:
	var shelf := int(GameData.facility("storage_shelf").get("effects", {}).get("storage_slots", 20))
	return int(GameData.config["storage"]["base_slots"]) + shelf * int(built.get("storage_shelf", 0))


func defense_from_facilities() -> int:
	var total := 0
	for fid: String in built:
		var f: Dictionary = GameData.facility(fid)
		if f.get("kind", "") == "defense":
			total += int(f.get("effects", {}).get("defense", 0)) * int(built[fid])
	return total


# ------------------------------------------------------------------ building & crafting

## Why something can't be started right now ("" means it can).
func build_blocker(fid: String) -> String:
	var f: Dictionary = GameData.facility(fid)
	if f.is_empty() or f.get("built_at_start", false):
		return "REASON_NOT_BUILDABLE"
	if f.has("max_count") and int(built.get(fid, 0)) + _queued(fid) >= int(f["max_count"]):
		return "REASON_BUILT_MAX"
	if f.get("blueprint", false) and not blueprints.has(fid):
		return "REASON_NEED_BLUEPRINT"
	for req: String in f.get("requires", []):
		if GameData.items.has(req) and count(req) <= 0:
			return "REASON_NEED_TOOL:" + req
		if GameData.facilities.has(req) and int(built.get(req, 0)) <= 0:
			return "REASON_NEED_FACILITY:" + req
	return _missing(f.get("cost", {}))


func craft_blocker(rid: String) -> String:
	var r: Dictionary = GameData.recipes.get(rid, {})
	if r.is_empty():
		return "REASON_NOT_BUILDABLE"
	var station := String(r.get("station", ""))
	if not _has_station(station):
		return "REASON_NEED_STATION:" + station
	if r.has("uses_durability") and count(String(r["uses_durability"])) <= 0:
		return "REASON_NEED_TOOL:" + String(r["uses_durability"])
	if r.has("salvage") and salvage_today + _queued(rid) >= int(r["salvage"]["per_day"]):
		return "REASON_SALVAGE_DONE"
	if r.has("salvage") and count("hammer") <= 0:
		return "REASON_NEED_TOOL:hammer"
	var m := _missing(r.get("inputs", {}))
	if m != "":
		return m
	if int(r.get("fuel", 0)) > 0 and count("fuel") + count("wood") < int(r["fuel"]):
		return "REASON_NEED_FUEL"
	return ""


func _queued(id: String) -> int:
	var n := 0
	for t in tasks:
		if t["id"] == id:
			n += 1
	return n


## A light source for night work: the work lamp is free, the campfire burns one fuel or wood a night.
func light_source() -> String:
	for fid: String in ["work_lamp", "campfire"]:
		if int(built.get(fid, 0)) > 0:
			if fid == "campfire" and count("fuel") + count("wood") <= 0:
				continue
			return fid
	return ""


func set_night_work(on: bool) -> void:
	night_work = on
	night_changed.emit()


## 22:00: light up for night work (costs trace and maybe fuel), before the raid roll.
func _light_up() -> void:
	lit_tonight = false
	if not night_work:
		return
	var src := light_source()
	if src == "":
		_warn("WARN_NO_LIGHT", null)
		return
	var eff: Dictionary = GameData.facility(src).get("effects", {})
	if int(eff.get("fuel_per_night", 0)) > 0:
		take_item("fuel" if count("fuel") > 0 else "wood", int(eff["fuel_per_night"]))
	trace += float(eff.get("trace_per_night", 1))
	lit_tonight = true
	_warn("WARN_LIT", null, {"item": GameData.display_name(GameData.facility(src))})


func _has_station(station: String) -> bool:
	for fid: String in built:
		if int(built[fid]) > 0 and GameData.facility(fid).get("effects", {}).get("station", "") == station:
			return true
	return false


func _missing(cost: Dictionary) -> String:
	for id: String in cost:
		if count(id) < int(cost[id]):
			return "REASON_NEED_ITEM:%s:%d" % [id, int(cost[id]) - count(id)]
	return ""


## Queue a facility. Materials are set aside now and returned if cancelled.
func queue_build(fid: String) -> bool:
	if build_blocker(fid) != "":
		return false
	var f: Dictionary = GameData.facility(fid)
	var cost: Dictionary = f.get("cost", {})
	for id: String in cost:
		take_item(id, int(cost[id]))
	var hours := float(f.get("build_hours", GameData.config["build"]["hours"].get(f.get("tier", "early"), 2)))
	_add_task({"kind": "build", "id": fid, "spent": cost.duplicate(), "fuel": "",
			"total": hours * MIN_PER_HOUR, "done": 0.0, "worker": 0})
	return true


func queue_craft(rid: String) -> bool:
	if craft_blocker(rid) != "":
		return false
	var r: Dictionary = GameData.recipes[rid]
	var spent: Dictionary = r.get("inputs", {}).duplicate()
	for id: String in spent:
		take_item(id, int(spent[id]))
	var fuel_used := ""
	if int(r.get("fuel", 0)) > 0:
		fuel_used = "fuel" if count("fuel") > 0 else "wood"
		take_item(fuel_used, int(r["fuel"]))
	_add_task({"kind": "craft", "id": rid, "spent": spent, "fuel": fuel_used,
			"total": float(r.get("minutes", 30)), "done": 0.0, "worker": 0})
	return true


func cancel_task(index: int) -> void:
	if index < 0 or index >= tasks.size():
		return
	var t: Dictionary = tasks[index]
	for id: String in t["spent"]:
		add_item(id, int(t["spent"][id]))
	if t["fuel"] != "":
		add_item(t["fuel"], 1)
	_release_worker(t)
	tasks.remove_at(index)
	queue_changed.emit()


func task_name(t: Dictionary) -> String:
	if t["kind"] == "build":
		return GameData.display_name(GameData.facility(t["id"]))
	return GameData.display_name(GameData.recipes[t["id"]])


func task_of(s: Survivor) -> Dictionary:
	for t in tasks:
		if int(t["worker"]) == s.id:
			return t
	return {}


func _add_task(t: Dictionary) -> void:
	tasks.append(t)
	queue_changed.emit()
	inventory_changed.emit()


func _release_worker(t: Dictionary) -> void:
	for s in survivors:
		if s.id == int(t["worker"]) and s.activity == Survivor.Activity.WORK:
			s.activity = Survivor.Activity.REST
	t["worker"] = 0


func _can_work(s: Survivor) -> bool:
	var auto: Dictionary = GameData.config["auto"]
	var hour := GameClock.hour
	var night := hour >= int(auto["sleep_from_hour"]) or hour < int(auto["wake_hour"])
	if night and lit_tonight and (hour >= int(auto["sleep_from_hour"]) or hour < int(GameData.night["night_work"]["until_hour"])):
		night = false  # working by the light
	return s.is_active() and s.at_base and not night and s.forced_sleep_minutes <= 0 \
			and s.stamina >= float(auto["sleep_if_stamina_below"]) \
			and s.health >= float(GameData.config["stats"]["bands"]["caution"]) \
			and s.activity != Survivor.Activity.EXPEDITION


## Give waiting tasks to free survivors (mechanic first), stop work at night.
func _assign_work() -> void:
	var changed := false
	for t in tasks:
		var w := _survivor(int(t["worker"]))
		if w and not _can_work(w):
			_release_worker(t)
			changed = true
	for t in tasks:
		if int(t["worker"]) != 0:
			continue
		var best: Survivor = null
		for s in survivors:
			if not _can_work(s) or not task_of(s).is_empty():
				continue
			if best == null or (s.job == "mechanic" and best.job != "mechanic"):
				best = s
		if best:
			t["worker"] = best.id
			best.activity = Survivor.Activity.WORK
			changed = true
	if changed:
		queue_changed.emit()


func _work_speed(s: Survivor) -> float:
	var speed := 1.0
	var jm := float(GameData.job(s.job).get("build_time_mult", 1.0))
	speed /= jm
	var mc: Dictionary = GameData.config["morale"]
	if morale >= float(mc["high"]):
		speed *= float(mc["high_work_mult"])
	elif morale < float(mc["low"]):
		speed *= float(mc["low_work_mult"])
	var de: Dictionary = GameData.config["stats"]["danger_effects"]
	var caution := float(GameData.config["stats"]["bands"]["caution"])
	if s.food < caution:
		speed *= float(de["food_work_mult"])
	if s.water < caution:
		speed *= float(de["water_work_mult"])
	if s.injury == "light":
		speed *= float(GameData.injuries["light"]["work_mult"])
	elif s.injury == "serious":
		speed *= float(GameData.injuries["serious"]["work_mult"])
	return speed


func _progress_work() -> void:
	var finished: Array[Dictionary] = []
	for t in tasks:
		var w := _survivor(int(t["worker"]))
		if w == null:
			continue
		t["done"] = float(t["done"]) + _work_speed(w)
		if float(t["done"]) >= float(t["total"]):
			finished.append(t)
	for t in finished:
		_finish_task(t)
	if not finished.is_empty():
		queue_changed.emit()


func _finish_task(t: Dictionary) -> void:
	var worker := _survivor(int(t["worker"]))
	_release_worker(t)
	tasks.erase(t)
	if t["kind"] == "build":
		var fid: String = t["id"]
		built[fid] = int(built.get(fid, 0)) + 1
		raids.on_built(fid)
		for req: String in GameData.facility(fid).get("requires", []):
			if GameData.items.has(req):
				wear(req)
		trace += float(GameData.night["trace"]["sources"]["build"])
		built_changed.emit()
		_warn("WARN_BUILT", worker, {"item": task_name(t)})
	else:
		var r: Dictionary = GameData.recipes[t["id"]]
		var out: Dictionary = r.get("output", {})
		if r.has("salvage"):
			out = {_salvage_roll(r["salvage"]): 1}
			salvage_today += 1
			if salvage_today == 1:
				trace += float(r["salvage"].get("trace_first", 1))
			wear("hammer")
			t["salvaged"] = out.keys()[0]
		for id: String in out:
			add_item(id, int(out[id]))
		if r.has("uses_durability"):
			wear(String(r["uses_durability"]))
		if r.get("station", "") == "stove":
			cooks_today += 1
			if cooks_today == 3:
				trace += float(GameData.night["trace"]["sources"]["cooks_3_per_day"])
		if t.has("salvaged"):
			_warn("WARN_SALVAGED", worker, {"item": GameData.display_name(GameData.item(t["salvaged"]))})
		else:
			_warn("WARN_CRAFTED", worker, {"item": task_name(t)})
	# small chance of hurting yourself while working
	if worker and worker.injury == "":
		var b: Dictionary = GameData.config["build"]
		var p := float(b["accident_chance"])
		if worker.stamina < float(GameData.config["stats"]["bands"]["caution"]):
			p = float(b["accident_chance_tired"])
		if _rng.randf() < p:
			worker.injury = "light"
			change_morale(float(GameData.config["morale"]["daily"]["injury"]))
			_warn("WARN_ACCIDENT", worker)


func _salvage_roll(cfg: Dictionary) -> String:
	var w: Dictionary = cfg["weights"]
	var total := 0
	for k: String in w:
		total += int(w[k])
	var roll := _rng.randi_range(1, total)
	for k: String in w:
		roll -= int(w[k])
		if roll <= 0:
			return k
	return String(w.keys()[0])


func _survivor(sid: int) -> Survivor:
	for s in survivors:
		if s.id == sid:
			return s
	return null


# ------------------------------------------------------------------ clock

func _on_minute(_day: int, _hour: int, _minute: int) -> void:
	advance_minute()


## One in-game minute for everyone. Tests call this directly.
func advance_minute() -> void:
	if ended:
		return
	var cfg: Dictionary = GameData.config
	var stats: Dictionary = cfg["stats"]
	var auto: Dictionary = cfg["auto"]
	var hour := GameClock.hour
	var sleep_time := hour >= int(auto["sleep_from_hour"]) or hour < int(auto["wake_hour"])
	var beds := _sleep_spots()
	var spot := 0
	_assign_work()
	for s in survivors:
		if s.life == Survivor.Life.COLLAPSED:
			_tick_collapsed(s)
			continue
		if not s.is_active():
			continue
		# what is this survivor doing this minute?
		if s.forced_sleep_minutes > 0:
			s.activity = Survivor.Activity.SLEEP
			s.forced_sleep_minutes -= 1
		elif s.activity == Survivor.Activity.EXPEDITION:
			pass  # set by the expedition step
		elif not task_of(s).is_empty():
			s.activity = Survivor.Activity.WORK
		elif s.guard and _on_watch(hour) and s.stamina > 5.0:
			s.activity = Survivor.Activity.REST  # night watch: stays up
		elif sleep_time or (s.activity == Survivor.Activity.SLEEP and s.stamina < 80.0) \
				or s.stamina < float(auto["sleep_if_stamina_below"]):
			s.activity = Survivor.Activity.SLEEP
		else:
			s.activity = Survivor.Activity.REST
		var key := _activity_key(s.activity)
		var decay: Dictionary = stats["decay_per_hour"]
		var food_loss := float(decay["food"][key]) / MIN_PER_HOUR
		var water_loss := float(decay["water"][key]) / MIN_PER_HOUR
		var stamina_loss := float(decay["stamina"][key]) / MIN_PER_HOUR
		if s.job == "runner":
			stamina_loss *= float(GameData.job("runner").get("stamina_decay_mult", 1.0))
		if s.activity == Survivor.Activity.EXPEDITION:
			water_loss *= expeditions.water_decay_mult(s)
			stamina_loss *= expeditions.stamina_decay_mult(s)
		if s.upset_minutes > 0:
			water_loss += float(GameData.injuries["upset"]["extra_water_per_hour"]) / MIN_PER_HOUR
			s.upset_minutes -= 1
		s.food = max(0.0, s.food - food_loss)
		s.water = max(0.0, s.water - water_loss)
		s.stamina = max(0.0, s.stamina - stamina_loss)
		if s.activity == Survivor.Activity.SLEEP:
			var gain := float(stats["sleep_gain_floor"])
			if spot < beds.size():
				gain = beds[spot]
			spot += 1
			if s.injury == "infected":
				gain *= float(GameData.injuries["infected"]["sleep_gain_mult"])
			s.stamina = min(100.0, s.stamina + gain / MIN_PER_HOUR)
		elif s.stamina <= 0.0:
			# passed out from exhaustion
			s.forced_sleep_minutes = int(float(stats["stamina_zero"]["sleep_hours"]) * MIN_PER_HOUR)
			change_morale(float(stats["stamina_zero"]["morale"]))
			_warn("WARN_EXHAUSTED", s)
		# eat and drink when low (only at the base)
		if s.at_base:
			if s.food < float(auto["eat_below"]):
				_eat(s)
			if s.water < float(auto["drink_below"]):
				_drink(s)
		# health
		var zero: Dictionary = stats["at_zero_health_per_hour"]
		var damage := 0.0
		if s.food <= 0.0:
			damage += float(zero["food"])
		if s.water <= 0.0:
			damage += float(zero["water"])
		if damage > 0.0:
			s.health -= damage / MIN_PER_HOUR
			s.cause_of_death = "CAUSE_STARVATION"
			_warn("WARN_STARVING", s)
		else:
			var heal: Dictionary = stats["natural_heal"]
			var resting := s.activity == Survivor.Activity.REST or s.activity == Survivor.Activity.SLEEP
			if resting and s.injury == "" and s.food >= float(heal["needs_food"]) and s.water >= float(heal["needs_water"]):
				s.health = min(100.0, s.health + float(heal["per_hour"]) / MIN_PER_HOUR)
		_tick_injury(s)
		if s.health <= 0.0:
			s.health = 0.0
			_collapse(s)
	_progress_work()
	expeditions.tick()
	radio.tick()
	if GameClock.hour == int(GameData.night.get("raid_check_hour", 22)) and GameClock.minute == 0:
		_light_up()
	raids.tick()
	_tick_morale()
	_check_end()
	survivors_changed.emit()


func _activity_key(a: Survivor.Activity) -> String:
	match a:
		Survivor.Activity.SLEEP:
			return "sleep"
		Survivor.Activity.WORK:
			return "work"
		Survivor.Activity.EXPEDITION:
			return "expedition"
	return "rest"


## Sleep gains per spot, best first: sleeping bags, then beds, then floor.
func _sleep_spots() -> Array[float]:
	var spots: Array[float] = []
	for i in count("sleeping_bag"):
		spots.append(float(GameData.item("sleeping_bag").get("sleep_gain", 8)))
	var bed_gain := float(GameData.facility("bed").get("effects", {}).get("sleep_gain", 7))
	for i in int(built.get("bed", 0)) + int(built.get("infirmary_bed", 0)):
		spots.append(bed_gain)
	return spots


## People at the base tonight without a bed or a sleeping bag.
func floor_sleepers() -> int:
	var n := 0
	for s in survivors:
		if s.is_active() and s.at_base:
			n += 1
	return max(0, n - _sleep_spots().size())


func _eat(s: Survivor) -> void:
	# cooked food that spoils goes first, then canned food (cold)
	for id: String in ["heated_can", "meat_skewer", "veggie_soup", "canned_food", "ration"]:
		if count(id) > 0:
			var it: Dictionary = GameData.item(id)
			take_item(id)
			s.food = min(100.0, s.food + float(it.get("food", 0)))
			s.water = min(100.0, s.water + float(it.get("water", 0)))
			foods_today[id] = true
			return
	_warn("WARN_NO_FOOD", null)


func _drink(s: Survivor) -> void:
	for id: String in ["clean_water", "bottled_water"]:
		if count(id) > 0:
			take_item(id)
			s.water = min(100.0, s.water + float(GameData.item(id).get("water", 30)))
			return
	if count("dirty_water") > 0:
		take_item("dirty_water")
		var dirty: Dictionary = GameData.item("dirty_water")
		s.water = min(100.0, s.water + float(dirty.get("water", 30)))
		if int(durability.get("water_filter", 0)) > 0:
			durability["water_filter"] = int(durability["water_filter"]) - 1  # filtered on the spot
		elif _rng.randf() < float(dirty.get("sickness", {}).get("chance", 0.4)):
			s.upset_minutes = int(float(GameData.injuries["upset"]["hours"]) * MIN_PER_HOUR)
			_warn("WARN_UPSET", s)
		return
	_warn("WARN_NO_WATER", null)


# ------------------------------------------------------------------ injuries

## Give a survivor an injury (a worse one replaces a lighter one).
func injure(s: Survivor, kind: String) -> void:
	if not s.is_alive():
		return
	var order := {"": 0, "light": 1, "serious": 2, "infected": 3}
	change_morale(float(GameData.config["morale"]["daily"]["injury"]))
	if s.injury != "" and int(order.get(kind, 0)) <= int(order.get(s.injury, 0)):
		if s.injury == "light" and kind == "light":
			kind = "serious"  # hurt again on top of a light injury
		else:
			return
	s.injury = kind
	s.injury_minutes = 0
	s.splinted = false
	s.disinfect_doses = 0
	_warn("WARN_INJ_" + kind.to_upper(), s)
	_treat(s)


func _nurse_at_base() -> bool:
	for n in survivors:
		if n.job == "nurse" and n.is_active() and n.at_base:
			return true
	return false


## Use bandages / splints / disinfectant from the storeroom automatically.
func _treat(s: Survivor) -> void:
	if not s.at_base or not s.is_alive():
		return
	var heal_mult := float(GameData.job("nurse").get("treat_mult", 1.0)) if _nurse_at_base() else 1.0
	match s.injury:
		"light":
			if take_item("bandage"):
				s.injury = ""
				s.health = min(100.0, s.health + float(GameData.item("bandage").get("health", 15)) * heal_mult)
				_warn("WARN_TREATED", s, {"item": GameData.display_name(GameData.item("bandage"))})
		"serious":
			if not s.splinted and take_item("splint"):
				s.splinted = true
				_warn("WARN_TREATED", s, {"item": GameData.display_name(GameData.item("splint"))})
		"infected":
			if s.last_dose_day != GameClock.day and take_item("disinfectant"):
				s.last_dose_day = GameClock.day
				s.disinfect_doses += 1
				_warn("WARN_TREATED", s, {"item": GameData.display_name(GameData.item("disinfectant"))})
				if s.disinfect_doses >= int(GameData.injuries["infected"]["cure"]["disinfectant_days"]):
					s.injury = ""
					_warn("WARN_CURED", s)


func _tick_injury(s: Survivor) -> void:
	if s.injury == "":
		return
	s.injury_minutes += 1
	if s.at_base and s.injury != "infected" and int(built.get("infirmary_bed", 0)) > 0:
		s.injury_minutes += int(GameData.facility("infirmary_bed")["effects"].get("heal_speed", 2.0)) - 1
	var inj: Dictionary = GameData.injuries
	if s.injury_minutes % 60 == 0:
		_treat(s)
		if s.injury == "":
			return
	match s.injury:
		"light":
			var l: Dictionary = inj["light"]
			if s.injury_minutes % 1440 == 0 and _rng.randf() < float(l["infection_chance_per_day"]):
				_set_infected(s)
			elif s.injury_minutes >= int(float(l["heals_days"]) * 1440.0):
				s.injury = ""
		"serious":
			var r: Dictionary = inj["serious"]
			if s.splinted:
				if s.injury_minutes >= int(float(r["heals_days_with_splint"]) * 1440.0):
					s.injury = ""
			else:
				s.health += float(r["health_per_hour"]) / MIN_PER_HOUR
				s.cause_of_death = "CAUSE_INJURY"
				if s.injury_minutes == int(float(r["infection_after_hours"]) * MIN_PER_HOUR) and _rng.randf() < float(r["infection_chance"]):
					_set_infected(s)
		"infected":
			var f: Dictionary = inj["infected"]
			s.health += float(f["health_per_hour"]) / MIN_PER_HOUR
			s.cause_of_death = "CAUSE_INFECTION"
			if s.disinfect_doses == 0 and s.injury_minutes >= int(float(f["collapse_after_days"]) * 1440.0):
				s.health = 0.0


func _set_infected(s: Survivor) -> void:
	s.injury = "infected"
	s.injury_minutes = 0
	s.disinfect_doses = 0
	_warn("WARN_INJ_INFECTED", s)
	_treat(s)


## Night watch hours (22:00-04:00).
func _on_watch(hour: int) -> bool:
	return hour >= int(GameData.config["auto"]["sleep_from_hour"]) or hour < 4


func set_guard(s: Survivor, on: bool) -> void:
	s.guard = on and s.is_active()
	night_changed.emit()


# ------------------------------------------------------------------ collapse & death

func _collapse(s: Survivor) -> void:
	if s.life != Survivor.Life.OK:
		return
	s.life = Survivor.Life.COLLAPSED
	s.collapsed_minutes = 0
	_warn("WARN_COLLAPSED", s)
	_try_revive(s)


func _try_revive(s: Survivor) -> void:
	if not s.at_base:
		return
	var nurse_job: Dictionary = GameData.job("nurse")
	for n in survivors:
		if n == s or not n.is_active() or not n.at_base or n.job != "nurse":
			continue
		if revives_used.get(n.id, false):
			continue
		revives_used[n.id] = true
		s.life = Survivor.Life.OK
		s.health = float(GameData.config["stats"]["collapse"]["revive_health"])
		s.collapsed_minutes = 0
		_warn("WARN_REVIVED", s)
		return
	if nurse_job.is_empty():
		return


func _tick_collapsed(s: Survivor) -> void:
	s.collapsed_minutes += 1
	_try_revive(s)
	if s.life != Survivor.Life.COLLAPSED:
		return
	var limit := float(GameData.config["stats"]["collapse"]["death_after_hours"]) * MIN_PER_HOUR
	if s.collapsed_minutes >= int(limit):
		s.life = Survivor.Life.DEAD
		deaths += 1
		change_morale(float(GameData.config["morale"]["daily"]["death"]))
		survivor_died.emit(s)


# ------------------------------------------------------------------ morale, days, end of run

func change_morale(delta: float) -> void:
	morale = clamp(morale + delta, 0.0, 100.0)
	morale_changed.emit(morale)


func _tick_morale() -> void:
	if morale <= 0.0:
		morale_zero_minutes += 1
	else:
		morale_zero_minutes = 0


func _on_day_started(_day: int) -> void:
	pass  # the daily update runs at 06:00 instead, see _morning()


## Runs once every in-game morning (06:00): rain water, spoilage, morale from
## yesterday's meals, trace decay.
func morning() -> void:
	var cfg: Dictionary = GameData.config
	var day := GameClock.day
	var rain := weather_today() == "rain"
	# rain collectors (Lv2 adds on top)
	for fid: String in built:
		var eff: Dictionary = GameData.facility(fid).get("effects", {})
		var daily: Dictionary = eff.get("daily_rain" if rain else "daily", {})
		for id: String in daily:
			add_item(id, int(daily[id]) * int(built[fid]))
	salvage_today = 0
	lit_tonight = false
	raids.morning()
	# spoilage
	var kept: Array[Dictionary] = []
	var spoiled := 0
	for batch in raw_food:
		var life_days := int(GameData.item(batch["item"]).get("spoil_days", 99))
		if day - int(batch["day"]) < life_days:
			kept.append(batch)
		else:
			spoiled += 1
			inventory[batch["item"]] = max(0, count(batch["item"]) - 1)
	raw_food = kept
	if spoiled > 0:
		_warn("WARN_SPOILED", null)
	cooks_today = 0
	expeditions.morning()
	# morale from yesterday's meals
	var md: Dictionary = cfg["morale"]["daily"]
	if foods_today.size() >= 2:
		change_morale(float(md["two_food_kinds"]))
	elif foods_today.size() == 1 and foods_today.keys() == foods_yesterday.keys():
		change_morale(float(md["same_food_two_days"]))
	foods_yesterday = foods_today.duplicate()
	foods_today.clear()
	var fl: Dictionary = cfg["morale"].get("floor_sleepers", {})
	if not fl.is_empty() and floor_sleepers() >= int(fl["min"]):
		change_morale(float(fl["morale"]))
		_warn("WARN_FLOOR", null, {"n": floor_sleepers()})
	# trace decay
	var tr_cfg: Dictionary = GameData.night["trace"]
	trace = max(0.0, trace - float(tr_cfg["morning_decay"]) - (float(tr_cfg["rain_extra_decay"]) if rain else 0.0))
	# facilities that produce something every morning (rat trap); their smell counts for today
	for fid: String in built:
		var eff: Dictionary = GameData.facility(fid).get("effects", {})
		var dr: Dictionary = eff.get("daily_random", {})
		for id: String in dr:
			for k in int(built[fid]):
				add_item(id, _rng.randi_range(int(dr[id][0]), int(dr[id][1])))
		trace += float(eff.get("daily_trace", 0)) * int(built[fid])
	# morale zero: someone may leave
	if morale <= 0.0 and _rng.randf() < float(cfg["morale"]["zero_leave_chance"]):
		var here := living().filter(func(x: Survivor) -> bool: return x.is_active())
		if not here.is_empty():
			var gone: Survivor = here[_rng.randi_range(0, here.size() - 1)]
			gone.life = Survivor.Life.LEFT
			_warn("WARN_LEFT", gone)
	inventory_changed.emit()


func _check_end() -> void:
	if GameClock.minute == 0 and GameClock.hour == int(GameData.config["auto"]["wake_hour"]):
		morning()
	if living().is_empty():
		_end(&"wiped_out")
		return
	var zero_limit := int(float(GameData.config["morale"]["zero_lose_hours"]) * MIN_PER_HOUR)
	if morale_zero_minutes >= zero_limit:
		_end(&"base_collapsed")
		return
	var proto: Dictionary = GameData.config["prototype"]
	if GameClock.day >= int(proto["run_days"]) and GameClock.hour >= int(proto["helicopter_hour"]):
		_end(&"rescued")


func _end(r: StringName) -> void:
	if ended:
		return
	ended = true
	result = r
	run_ended.emit(r, compute_score())


## Score lines for the result screen: [label key, count, points].
func score_breakdown() -> Array:
	var sc: Dictionary = GameData.score
	var won := result == &"rescued"
	var days := int(GameData.config["prototype"]["run_days"]) if won else GameClock.day
	var rows: Array = [["SCORE_DAYS", days, days * int(sc["per_day"])]]
	if won:
		rows.append(["SCORE_WIN", 1, int(sc["win"])])
		var boarded := 0
		for s in survivors:
			if s.is_active() and s.at_base:
				boarded += 1
		rows.append(["SCORE_BOARDED", boarded, boarded * int(sc["per_boarded"])])
	if joined > 0:
		rows.append(["SCORE_JOINED", joined, joined * int(sc["per_joined"])])
	if deaths > 0:
		rows.append(["SCORE_DEATHS", deaths, deaths * int(sc["per_death"])])
	var fw := 0
	var mats := 0
	for id: String in inventory:
		var cat := String(GameData.item(id).get("category", ""))
		if cat in ["food", "water", "food_raw"]:
			fw += count(id)
		elif cat == "material":
			mats += count(id)
	rows.append(["SCORE_FOOD_WATER", fw, fw * int(sc["per_food_water"])])
	rows.append(["SCORE_MATERIALS", mats, mats * int(sc["per_material"])])
	if not blueprints.is_empty():
		rows.append(["SCORE_BLUEPRINTS", blueprints.size(), blueprints.size() * int(sc["per_blueprint"])])
	return rows


## Score formula from score.json (helicopter boarding = active survivors at the base).
func compute_score() -> int:
	var total := 0
	for row: Array in score_breakdown():
		total += int(row[2])
	return total


static func grade(score_value: int) -> String:
	for g: Array in GameData.score.get("prototype_grades", GameData.score["grades"]):
		if score_value >= int(g[1]):
			return String(g[0])
	return "C"


# ------------------------------------------------------------------ helpers

func _make_weather() -> void:
	weather_by_day.clear()
	var odds: Dictionary = GameData.weather["prototype"]
	var block: Array = GameData.weather["block_days"]
	var day := 1
	var total_days := int(GameData.config["prototype"]["run_days"]) + 1
	while day <= total_days:
		var roll := _rng.randf() * (float(odds["clear"]) + float(odds["rain"]))
		var w := "clear" if roll < float(odds["clear"]) else "rain"
		for i in _rng.randi_range(int(block[0]), int(block[1])):
			weather_by_day[day] = w
			day += 1


func warn(key: String, s: Survivor, extra: Dictionary = {}) -> void:
	_warn(key, s, extra)


## Warnings fire once per survivor per in-game hour so the log stays readable.
func _warn(key: String, s: Survivor, extra: Dictionary = {}) -> void:
	var tag := "%s:%d:%d:%d:%s" % [key, s.id if s else 0, GameClock.day, GameClock.hour, extra.get("item", "")]
	if _warned.has(tag) and extra.is_empty():
		return
	_warned[tag] = true
	var fields := {"name": tr(s.name_key) if s else ""}
	fields.merge(extra)
	warning.emit(tr(key).format(fields))
