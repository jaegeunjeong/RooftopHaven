extends Node
## Loads the design data in res://data/*.json (autoload: GameData).
## The JSON files are the single place where game numbers live; code reads them
## through this node and never hard-codes balance values.

const DATA_DIR := "res://data/"
const FILES := ["config", "items", "facilities", "recipes", "locations", "events",
		"jobs", "night", "injuries", "weather", "score"]

var config: Dictionary = {}
var night: Dictionary = {}
var injuries: Dictionary = {}
var weather: Dictionary = {}
var score: Dictionary = {}
var location_rules: Dictionary = {}
var event_rules: Dictionary = {}

var items: Dictionary = {}       # id -> Dictionary
var facilities: Dictionary = {}  # id -> Dictionary
var recipes: Dictionary = {}     # id -> Dictionary
var locations: Dictionary = {}   # id -> Dictionary
var events: Dictionary = {}      # id -> Dictionary
var jobs: Dictionary = {}        # id -> Dictionary

var errors: PackedStringArray = []
var loaded: bool = false


func _ready() -> void:
	load_all()


func load_all() -> bool:
	errors = PackedStringArray()
	var raw: Dictionary = {}
	for f: String in FILES:
		var parsed: Variant = _read_json(DATA_DIR + f + ".json")
		if parsed is Dictionary:
			raw[f] = parsed
		else:
			errors.append("%s.json: could not be read as a JSON object" % f)
	if not errors.is_empty():
		_report()
		return false

	config = raw["config"]
	night = raw["night"]
	injuries = raw["injuries"]
	weather = raw["weather"]
	score = raw["score"]
	location_rules = raw["locations"].get("rules", {})
	event_rules = raw["events"].get("rules", {})
	items = _index(raw["items"], "items")
	facilities = _index(raw["facilities"], "facilities")
	recipes = _index(raw["recipes"], "recipes")
	locations = _index(raw["locations"], "locations")
	events = _index(raw["events"], "events")
	jobs = _index(raw["jobs"], "jobs")
	_validate()
	loaded = errors.is_empty()
	_report()
	return loaded


func item(id: String) -> Dictionary:
	return items.get(id, {})


func facility(id: String) -> Dictionary:
	return facilities.get(id, {})


func job(id: String) -> Dictionary:
	return jobs.get(id, {})


## Translated display name for any data entry that has a "name" key.
func display_name(entry: Dictionary) -> String:
	return tr(String(entry.get("name", entry.get("id", "?"))))


# --------------------------------------------------------------- internals

func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var text := FileAccess.get_file_as_string(path)
	var json := JSON.new()
	if json.parse(text) != OK:
		errors.append("%s: JSON error on line %d: %s" % [path, json.get_error_line(), json.get_error_message()])
		return null
	return json.data


func _index(block: Dictionary, label: String) -> Dictionary:
	var out: Dictionary = {}
	for entry: Variant in block.get("list", []):
		if not (entry is Dictionary) or not entry.has("id"):
			errors.append("%s: an entry has no id" % label)
			continue
		var id: String = entry["id"]
		if out.has(id):
			errors.append("%s: duplicate id '%s'" % [label, id])
		out[id] = entry
	return out


func _check_item(id: String, where: String) -> void:
	if not items.has(id):
		errors.append("%s: unknown item '%s'" % [where, id])


func _check_items_in(d: Dictionary, where: String) -> void:
	for id: String in d.keys():
		_check_item(id, where)


## Every id that one file uses must exist in the file that defines it.
func _validate() -> void:
	var stations: Dictionary = {}
	for fid: String in facilities:
		var f: Dictionary = facilities[fid]
		_check_items_in(f.get("cost", {}), "facility " + fid + " cost")
		for req: String in f.get("requires", []):
			if not items.has(req) and not facilities.has(req):
				errors.append("facility %s: unknown requirement '%s'" % [fid, req])
		var eff: Dictionary = f.get("effects", {})
		if eff.has("station"):
			stations[eff["station"]] = true
		_check_items_in(eff.get("daily", {}), "facility " + fid + " daily")
		_check_items_in(eff.get("daily_rain", {}), "facility " + fid + " daily_rain")
		_check_items_in(eff.get("daily_random", {}), "facility " + fid + " daily_random")
	for rid: String in recipes:
		var r: Dictionary = recipes[rid]
		_check_items_in(r.get("output", {}), "recipe " + rid + " output")
		_check_items_in(r.get("inputs", {}), "recipe " + rid + " inputs")
		if not stations.has(r.get("station", "")):
			errors.append("recipe %s: unknown station '%s'" % [rid, r.get("station", "")])
		if r.has("uses_durability"):
			_check_item(r["uses_durability"], "recipe " + rid + " uses_durability")
	for lid: String in locations:
		var l: Dictionary = locations[lid]
		_check_items_in(l.get("loot", {}), "location " + lid + " loot")
		for rare: Dictionary in l.get("rare", []):
			if rare.has("item"):
				_check_item(rare["item"], "location " + lid + " rare")
	for eid: String in events:
		for c: Dictionary in events[eid].get("choices", []):
			var req: Variant = c.get("requires")
			if req is Dictionary and req.has("item"):
				_check_item(req["item"], "event " + eid + " choice " + String(c.get("id", "")))
			for b: Dictionary in c.get("bonus", []):
				if b.has("item"):
					_check_item(b["item"], "event " + eid + " bonus")
				if b.has("job") and not jobs.has(b["job"]):
					errors.append("event %s: unknown job '%s'" % [eid, b["job"]])
	var start: Dictionary = config.get("start", {})
	_check_items_in(start.get("inventory", {}), "config start inventory")
	for s: Dictionary in start.get("survivors", []):
		if not jobs.has(s.get("job", "")):
			errors.append("config start survivor: unknown job '%s'" % s.get("job", ""))


func _report() -> void:
	for e: String in errors:
		push_error("GameData: " + e)
	if errors.is_empty():
		print("GameData: loaded %d items, %d facilities, %d recipes, %d locations, %d events" % [
				items.size(), facilities.size(), recipes.size(), locations.size(), events.size()])
