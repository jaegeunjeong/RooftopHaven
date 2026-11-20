class_name Radio
extends RefCounted
## Radio events during expeditions (grey-box step 6). Owned by GameState.
## From day 6 every expedition gets one event (a second one 30% of the time).
## The player has 5 real seconds to pick a choice; the game does not pause.
## No answer means the team takes the safe default. Results are rolled with
## the chance formula in events.json and applied to the expedition.

signal asked(pending: Dictionary)       # show the card
signal answered(result: Dictionary)     # hide the card, show the outcome

var gs: Node
var pending: Dictionary = {}            # the card on screen right now
var queue: Array[Dictionary] = []       # more cards waiting {exp_id, event}


func _init(state: Node) -> void:
	gs = state


func reset() -> void:
	pending.clear()
	queue.clear()


func rules() -> Dictionary:
	return GameData.event_rules


## Called when a team leaves: decide when (in trip progress) events happen.
func schedule(e: Dictionary) -> void:
	e["events_at"] = []
	if GameClock.day < int(rules().get("start_day", 6)):
		return
	var rng: RandomNumberGenerator = gs._rng
	var points: Array = []
	if rng.randf() < float(rules().get("per_expedition_first", 1.0)):
		points.append(rng.randf_range(0.15, 0.85))
	if rng.randf() < float(rules().get("per_expedition_second", 0.3)):
		points.append(rng.randf_range(0.15, 0.85))
	points.sort()
	for p: float in points:
		e["events_at"].append(p * float(e["total"]))


## Every game minute: start events whose time has come.
func tick() -> void:
	for e: Dictionary in gs.expeditions.active:
		if e["recalled"]:
			continue
		var at: Array = e.get("events_at", [])
		while not at.is_empty() and float(e["elapsed"]) >= float(at[0]):
			at.pop_front()
			trigger(e)


## Count down the answer time in real seconds (unaffected by debug speed).
func process_real(delta: float) -> void:
	if pending.is_empty():
		return
	pending["left"] = float(pending["left"]) - delta
	if float(pending["left"]) <= 0.0:
		expire()


func trigger(e: Dictionary, event_id: String = "") -> void:
	var ev := _pick_event(e, event_id)
	if ev.is_empty():
		return
	var item := {"exp_id": int(e["id"]), "event": String(ev["id"])}
	if pending.is_empty():
		_open(item)
	else:
		queue.append(item)


func _pick_event(e: Dictionary, event_id: String) -> Dictionary:
	if event_id != "":
		return GameData.events.get(event_id, {})
	var options: Array[Dictionary] = []
	for eid: String in GameData.events:
		var ev: Dictionary = GameData.events[eid]
		var locs: Variant = ev.get("locations", "any")
		if locs is Array and not (locs as Array).has(e["location"]):
			continue
		if ev.has("weather") and not (ev["weather"] as Array).has(gs.weather_today()):
			continue
		options.append(ev)
	if options.is_empty():
		return {}
	return options[gs._rng.randi_range(0, options.size() - 1)]


func _open(item: Dictionary) -> void:
	var e := _exp(int(item["exp_id"]))
	if e.is_empty():
		_next()
		return
	var ev: Dictionary = GameData.events[item["event"]]
	var choices: Array[Dictionary] = []
	for c: Dictionary in ev["choices"]:
		if not available(c, e):
			continue
		choices.append({"id": c["id"], "text": c["text"], "chance": chance(c, e), "default": c.get("default", false)})
	pending = {"exp_id": item["exp_id"], "event": item["event"], "title": ev["title"], "line": ev["line"],
			"choices": choices, "left": float(rules().get("response_seconds", 5)),
			"total": float(rules().get("response_seconds", 5)),
			"location": e["location"]}
	asked.emit(pending)


func _next() -> void:
	pending = {}
	while not queue.is_empty():
		var item: Dictionary = queue.pop_front()
		if not _exp(int(item["exp_id"])).is_empty():
			_open(item)
			return


## Is this choice on offer for this team (gear / job requirements)?
func available(c: Dictionary, e: Dictionary) -> bool:
	var req: Variant = c.get("requires")
	if req is Dictionary:
		if req.has("item") and int(e["gear"].get(req["item"], 0)) <= 0:
			return false
		if req.has("job") and not _team_has_job(e, String(req["job"])):
			return false
	return true


## Success chance 0..1 (base + gear/job bonus + team size + day + condition), clamped 35..95%.
func chance(c: Dictionary, e: Dictionary) -> float:
	var base := float(c.get("base_chance", 1.0))
	if base >= 1.0:
		return 1.0
	var r := rules()
	var p := base * 100.0
	for b: Dictionary in c.get("bonus", []):
		if b.has("item") and int(e["gear"].get(b["item"], 0)) > 0:
			p += float(b["bonus"])
		if b.has("job") and _team_has_job(e, String(b["job"])):
			p += float(b["bonus"])
	var members: Array[Survivor] = gs.expeditions.members_of(e)
	p += float(r["team_bonus"].get(str(clampi(members.size(), 1, 3)), 0))
	for row: Dictionary in r.get("day_bonus", []):
		if GameClock.day >= int(row["from_day"]) and GameClock.day <= int(row["to_day"]):
			p += float(row["bonus"])
	var low: Dictionary = r.get("low_health_penalty", {})
	for s in members:
		if s.health < float(low.get("below", 30)):
			p += float(low.get("bonus", -10))
			break
	var clamp_range: Array = r.get("clamp", [35, 95])
	return clampf(p, float(clamp_range[0]), float(clamp_range[1])) / 100.0


func answer(choice_id: String) -> void:
	if pending.is_empty():
		return
	_resolve(choice_id, false)


## Time ran out: the team takes the default (safe) choice.
func expire() -> void:
	if pending.is_empty():
		return
	var def := ""
	for c: Dictionary in pending["choices"]:
		if c["default"]:
			def = c["id"]
	if def == "" and not pending["choices"].is_empty():
		def = pending["choices"][0]["id"]
	_resolve(def, true)


func _resolve(choice_id: String, timed_out: bool) -> void:
	var e := _exp(int(pending["exp_id"]))
	var ev: Dictionary = GameData.events[pending["event"]]
	var c: Dictionary = {}
	for x: Dictionary in ev["choices"]:
		if x["id"] == choice_id:
			c = x
	var result := {"event": pending["event"], "choice": choice_id, "timed_out": timed_out, "ok": true,
			"location": pending["location"], "effects": []}
	if e.is_empty() or c.is_empty():
		_next()
		answered.emit(result)
		return
	var p := chance(c, e)
	var ok: bool = gs._rng.randf() < p
	result["ok"] = ok
	result["chance"] = p
	var consume: Variant = c.get("consume")
	if consume is Dictionary:
		for id: String in consume:
			e["gear"][id] = max(0, int(e["gear"].get(id, 0)) - int(consume[id]))
	var chain := _apply(e, c["success"] if ok else c["fail"], result)
	e["log"].append({"event": pending["event"], "choice": choice_id, "ok": ok, "timed_out": timed_out})
	gs.warn("WARN_RADIO_" + ("OK" if ok else "FAIL"), null, {"item": tr_text(c["text"]), "place": GameData.display_name(GameData.locations[e["location"]])})
	_next()
	answered.emit(result)
	if chain != "":
		trigger(e, chain)


## Apply an outcome dictionary to the expedition. Returns a chained event id or "".
func _apply(e: Dictionary, eff: Dictionary, result: Dictionary) -> String:
	var rng: RandomNumberGenerator = gs._rng
	var members: Array[Survivor] = []
	for s in gs.expeditions.members_of(e):
		if s.is_active():
			members.append(s)
	if eff.has("hours"):
		var add := float(eff["hours"]) * 60.0
		if e["recalled"]:
			e["return_left"] = float(e["return_left"]) + add
		else:
			e["total"] = float(e["total"]) + add
		result["effects"].append("hours:%d" % int(eff["hours"]))
	for kind: String in ["light", "serious"]:
		for i in int(eff.get(kind + "_injuries", 0)):
			if members.is_empty():
				break
			var s: Survivor = members[rng.randi_range(0, members.size() - 1)]
			if kind == "light" and int(e["gear"].get("bandage", 0)) > 0:
				e["gear"]["bandage"] = int(e["gear"]["bandage"]) - 1
				gs.change_morale(float(GameData.config["morale"]["daily"]["injury"]))
				result["effects"].append("patched:%d" % s.id)
			else:
				gs.injure(s, kind)
				result["effects"].append("%s:%d" % [kind, s.id])
	if eff.has("loot_mult"):
		e["loot_mult_bonus"] = float(e.get("loot_mult_bonus", 0.0)) + float(eff["loot_mult"])
		result["effects"].append("loot")
	if eff.has("extra_rare_rolls"):
		e["extra_rare"] = int(e.get("extra_rare", 0)) + int(eff["extra_rare_rolls"])
		result["effects"].append("rare")
	if eff.has("trace"):
		gs.trace += float(eff["trace"])
		result["effects"].append("trace:%d" % int(eff["trace"]))
	if eff.has("durability"):
		if not e.has("wear"):
			e["wear"] = {}
		for id: String in eff["durability"]:
			e["wear"][id] = int(e["wear"].get(id, 0)) + int(eff["durability"][id])
	if eff.has("break_item"):
		var id := String(eff["break_item"])
		e["gear"][id] = max(0, int(e["gear"].get(id, 0)) - 1)
		result["effects"].append("broke:" + id)
	if eff.get("status", "") == "wet":
		for s in members:
			s.wet = true
		result["effects"].append("wet")
	if eff.has("team_health"):
		for s in members:
			s.health = clampf(s.health + float(eff["team_health"]), 0.0, 100.0)
		result["effects"].append("health:%d" % int(eff["team_health"]))
	var chain: Variant = eff.get("chain")
	if chain is Dictionary and rng.randf() < float(chain.get("chance", 0)):
		return String(chain["event"])
	return ""


func tr_text(key: String) -> String:
	return TranslationServer.translate(key)


func _team_has_job(e: Dictionary, job: String) -> bool:
	for s in gs.expeditions.members_of(e):
		if s.job == job and s.is_active():
			return true
	return false


func _exp(exp_id: int) -> Dictionary:
	for e: Dictionary in gs.expeditions.active:
		if int(e["id"]) == exp_id:
			return e
	return {}
