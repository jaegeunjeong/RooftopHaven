extends Node
## Real-time game clock (autoload: GameClock).
## Design rule: time keeps flowing with no pause. A speed multiplier exists
## for the open question about 1x/2x speed control.

signal minute_changed(day: int, hour: int, minute: int)
signal hour_changed(day: int, hour: int)
signal day_started(day: int)
signal phase_changed(phase: StringName)

## Real seconds per in-game minute. 0.5 means one in-game day = 12 real minutes.
@export var seconds_per_game_minute: float = 0.5
## Speed multiplier (1.0 = normal). Pending design decision.
var time_scale: float = 1.0

var day: int = 1
var hour: int = 6
var minute: int = 0
var phase: StringName = &"morning"

var _accum: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	phase = phase_for_hour(hour)


func _process(delta: float) -> void:
	_accum += delta * time_scale
	while _accum >= seconds_per_game_minute:
		_accum -= seconds_per_game_minute
		_advance_minute()


func _advance_minute() -> void:
	minute += 1
	if minute >= 60:
		minute = 0
		hour += 1
		if hour >= 24:
			hour = 0
			day += 1
			day_started.emit(day)
		hour_changed.emit(day, hour)
		var new_phase := phase_for_hour(hour)
		if new_phase != phase:
			phase = new_phase
			phase_changed.emit(phase)
	minute_changed.emit(day, hour, minute)


## morning 06-12, day 12-18, evening 18-21, night 21-06
static func phase_for_hour(h: int) -> StringName:
	if h >= 6 and h < 12:
		return &"morning"
	if h >= 12 and h < 18:
		return &"day"
	if h >= 18 and h < 21:
		return &"evening"
	return &"night"
