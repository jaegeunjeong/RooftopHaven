extends Node
## State of the current run (autoload: GameState).
## Step 2 of the grey-box prototype: survivors, their four bars, automatic
## eating / drinking / sleeping, the storeroom, daily rain water, food spoilage,
## base morale, and the win / lose checks. Building, expeditions and raids come
## in later steps and plug into the same tick.

signal survivors_changed
signal inventory_changed
signal morale_changed(value: float)
signal warning(text: String)
signal survivor_died(survivor: Survivor)
signal run_ended(result: StringName, score: int)

const MIN_PER_HOUR := 60.0

var survivors: Array[Survivor] = []
var inventory: Dictionary = {}          # item id -> count
var raw_food: Array[Dictionary] = []    # {item, day} batches that spoil
var durability: Dictionary = {}         # tool item id -> remaining uses (pooled)
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

var _rng := RandomNumberGenerator.new()
var _warned: Dictionary = {}


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
	_make_weather()
	survivors_changed.emit()
	inventory_changed.emit()
	morale_changed.emit(morale)


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
	var it: Dictionary = GameData.item(item_id)
	if it.get("category", "") == "food_raw":
		for i in n:
			raw_food.append({"item": item_id, "day": GameClock.day})
	elif it.has("durability") and it.get("category", "") in ["tool", "survival"] and item_id == "water_filter":
		durability[item_id] = int(durability.get(item_id, 0)) + int(it["durability"]) * n
	inventory[item_id] = count(item_id) + n
	inventory_changed.emit()


func take_item(item_id: String, n: int = 1) -> bool:
	if count(item_id) < n:
		return false
	inventory[item_id] = count(item_id) - n
	if GameData.item(item_id).get("category", "") == "food_raw":
		for i in n:
			for j in raw_food.size():
				if raw_food[j]["item"] == item_id:
					raw_food.remove_at(j)
					break
	inventory_changed.emit()
	return true


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
		elif s.activity == Survivor.Activity.EXPEDITION or s.activity == Survivor.Activity.WORK:
			pass  # set by later steps
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
		if s.health <= 0.0:
			s.health = 0.0
			_collapse(s)
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
	for i in int(built.get("bed", 0)):
		spots.append(bed_gain)
	return spots


func _eat(s: Survivor) -> void:
	# cooked food that spoils goes first, then canned food (cold)
	for id: String in ["veggie_soup", "ration", "canned_food"]:
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
	# rain collector
	var collector: Dictionary = GameData.facility("rain_collector").get("effects", {})
	var daily: Dictionary = collector.get("daily_rain" if rain else "daily", {})
	for id: String in daily:
		add_item(id, int(daily[id]) * int(built.get("rain_collector", 0)))
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
	# morale from yesterday's meals
	var md: Dictionary = cfg["morale"]["daily"]
	if foods_today.size() >= 2:
		change_morale(float(md["two_food_kinds"]))
	elif foods_today.size() == 1 and foods_today.keys() == foods_yesterday.keys():
		change_morale(float(md["same_food_two_days"]))
	foods_yesterday = foods_today.duplicate()
	foods_today.clear()
	# trace decay
	var tr_cfg: Dictionary = GameData.night["trace"]
	trace = max(0.0, trace - float(tr_cfg["morning_decay"]) - (float(tr_cfg["rain_extra_decay"]) if rain else 0.0))
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


## Score formula from score.json (helicopter boarding = active survivors at the base).
func compute_score() -> int:
	var sc: Dictionary = GameData.score
	var won := result == &"rescued"
	var days := int(GameData.config["prototype"]["run_days"]) if won else GameClock.day
	var total := days * int(sc["per_day"])
	if won:
		total += int(sc["win"])
		for s in survivors:
			if s.is_active() and s.at_base:
				total += int(sc["per_boarded"])
	total += joined * int(sc["per_joined"]) + deaths * int(sc["per_death"])
	for id: String in inventory:
		var cat := String(GameData.item(id).get("category", ""))
		var n := count(id)
		if cat in ["food", "water", "food_raw"]:
			total += n * int(sc["per_food_water"])
		elif cat == "material":
			total += n * int(sc["per_material"])
	return total


static func grade(score_value: int) -> String:
	for g: Array in GameData.score["grades"]:
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


## Warnings fire once per survivor per in-game hour so the log stays readable.
func _warn(key: String, s: Survivor) -> void:
	var tag := "%s:%d:%d:%d" % [key, s.id if s else 0, GameClock.day, GameClock.hour]
	if _warned.has(tag):
		return
	_warned[tag] = true
	var who := tr(s.name_key) if s else ""
	warning.emit(tr(key).format({"name": who}))
