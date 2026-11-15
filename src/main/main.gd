extends Node2D
## Entry scene for the grey-box prototype (stage 2).

@onready var title_label: Label = $UI/TitleLabel
@onready var clock_label: Label = $UI/ClockLabel
@onready var phase_label: Label = $UI/PhaseLabel


func _ready() -> void:
	title_label.text = "%s · %s" % [tr("GAME_TITLE"), tr("PROTOTYPE_NOTE")]
	GameClock.minute_changed.connect(_on_minute_changed)
	GameClock.phase_changed.connect(_on_phase_changed)
	_on_minute_changed(GameClock.day, GameClock.hour, GameClock.minute)
	_on_phase_changed(GameClock.phase)


func _on_minute_changed(day: int, hour: int, minute: int) -> void:
	clock_label.text = "%s %d  %02d:%02d" % [tr("DAY"), day, hour, minute]


func _on_phase_changed(phase: StringName) -> void:
	phase_label.text = tr("PHASE_" + String(phase).to_upper())
