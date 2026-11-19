class_name Survivor
extends RefCounted
## One survivor: four bars (health, food, water, stamina) plus state flags.
## All numbers come from GameData; this class only holds the values.

enum Activity { REST, SLEEP, WORK, EXPEDITION }
enum Life { OK, COLLAPSED, DEAD, LEFT }

var id: int = 0
var name_key: String = ""
var job: String = ""

var health: float = 80.0
var food: float = 80.0
var water: float = 80.0
var stamina: float = 80.0

var activity: Activity = Activity.REST
var life: Life = Life.OK
var at_base: bool = true

var forced_sleep_minutes: int = 0   # fell asleep from exhaustion
var collapsed_minutes: int = 0      # time since health hit 0
var upset_minutes: int = 0          # stomach upset from dirty water
var injury: String = ""             # "", "light", "serious", "infected"
var injury_minutes: int = 0         # time spent with the current injury
var splinted: bool = false          # serious injury given first aid
var disinfect_doses: int = 0        # infected: doses taken (3 cures)
var last_dose_day: int = 0
var guard: bool = false             # stays up on night watch (22:00-04:00)
var expedition_id: int = 0          # 0 = at the base
var carried_food: int = 0           # rations packed for an expedition
var carried_water: int = 0          # bottles packed for an expedition
var wet: bool = false
var cause_of_death: String = ""


func _init(p_id: int, p_name_key: String, p_job: String, start_value: float) -> void:
	id = p_id
	name_key = p_name_key
	job = p_job
	health = start_value
	food = start_value
	water = start_value
	stamina = start_value


func is_alive() -> bool:
	return life == Life.OK or life == Life.COLLAPSED


func is_active() -> bool:
	return life == Life.OK


## "normal" / "caution" / "danger" / "zero", using the bands in config.json.
static func band(value: float, bands: Dictionary) -> String:
	if value <= 0.0:
		return "zero"
	if value < float(bands.get("caution", 30)):
		return "danger"
	if value < float(bands.get("normal", 60)):
		return "caution"
	return "normal"
