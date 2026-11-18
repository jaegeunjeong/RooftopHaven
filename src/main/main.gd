extends Node2D
## Entry scene for the grey-box prototype (stage 2).
## Step 2 screen: clock, weather, morale, storeroom summary, one card per
## survivor with the four bars, and a short warning log. Everything is plain
## boxes and text on purpose.

const FONT_SIZE := 10
const BAR_COLORS := {
	"health": Color(0.80, 0.30, 0.30),
	"food": Color(0.85, 0.62, 0.30),
	"water": Color(0.35, 0.60, 0.85),
	"stamina": Color(0.55, 0.75, 0.40),
}
const STATS := ["health", "food", "water", "stamina"]
const DEBUG_SPEEDS := {KEY_1: 1.0, KEY_2: 4.0, KEY_3: 16.0, KEY_4: 60.0}

@onready var title_label: Label = $UI/TitleLabel
@onready var clock_label: Label = $UI/ClockLabel
@onready var phase_label: Label = $UI/PhaseLabel

var _cards: Dictionary = {}   # survivor id -> {labels, bars}
var _status: Label
var _stock: Label
var _log: Label
var _log_lines: PackedStringArray = []
var _end_label: Label


func _ready() -> void:
	var theme := Theme.new()
	theme.default_font_size = FONT_SIZE
	$UI.get_children().map(func(c: Node) -> void:
		if c is Control:
			(c as Control).theme = theme)
	title_label.text = "%s · %s" % [tr("GAME_TITLE"), tr("PROTOTYPE_NOTE")]
	_build_ui(theme)
	GameClock.minute_changed.connect(_on_minute_changed)
	GameClock.phase_changed.connect(_on_phase_changed)
	GameState.survivors_changed.connect(_refresh_survivors)
	GameState.inventory_changed.connect(_refresh_stock)
	GameState.morale_changed.connect(func(_v: float) -> void: _refresh_status())
	GameState.warning.connect(_on_warning)
	GameState.run_ended.connect(_on_run_ended)
	_on_minute_changed(GameClock.day, GameClock.hour, GameClock.minute)
	_on_phase_changed(GameClock.phase)
	_refresh_survivors()
	_refresh_stock()


func _unhandled_input(event: InputEvent) -> void:
	# Debug-only speed keys for testing; the game itself has no pause.
	if OS.is_debug_build() and event is InputEventKey and event.pressed and not event.echo:
		var key: int = (event as InputEventKey).keycode
		if DEBUG_SPEEDS.has(key):
			GameClock.time_scale = DEBUG_SPEEDS[key]
			_refresh_status()


# ------------------------------------------------------------------ layout

func _build_ui(theme: Theme) -> void:
	var ui: CanvasLayer = $UI
	_status = _label(ui, theme, Vector2(8, 22), Vector2(380, 14))
	_stock = _label(ui, theme, Vector2(44, 300), Vector2(340, 36))
	_stock.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log = _label(ui, theme, Vector2(44, 44), Vector2(340, 80))
	_log.add_theme_color_override("font_color", Color(0.95, 0.80, 0.55))
	_end_label = _label(ui, theme, Vector2(44, 150), Vector2(340, 40))
	_end_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end_label.add_theme_font_size_override("font_size", 16)

	var panel := PanelContainer.new()
	panel.theme = theme
	panel.position = Vector2(400, 44)
	panel.size = Vector2(232, 300)
	ui.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)
	for s in GameState.survivors:
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", 1)
		box.add_child(card)
		var head := Label.new()
		card.add_child(head)
		var bars: Dictionary = {}
		for stat: String in STATS:
			var row := HBoxContainer.new()
			card.add_child(row)
			var name_label := Label.new()
			name_label.text = tr("STAT_" + stat.to_upper())
			name_label.custom_minimum_size = Vector2(44, 0)
			row.add_child(name_label)
			var bar := ProgressBar.new()
			bar.max_value = 100
			bar.show_percentage = false
			bar.custom_minimum_size = Vector2(140, 8)
			bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var fill := StyleBoxFlat.new()
			fill.bg_color = BAR_COLORS[stat]
			bar.add_theme_stylebox_override("fill", fill)
			row.add_child(bar)
			var value := Label.new()
			value.custom_minimum_size = Vector2(28, 0)
			value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			row.add_child(value)
			bars[stat] = [bar, value]
		_cards[s.id] = {"head": head, "bars": bars}


func _label(parent: Node, theme: Theme, pos: Vector2, sz: Vector2) -> Label:
	var l := Label.new()
	l.theme = theme
	l.position = pos
	l.size = sz
	parent.add_child(l)
	return l


# ------------------------------------------------------------------ refresh

func _on_minute_changed(day: int, hour: int, minute: int) -> void:
	clock_label.text = "%s %d  %02d:%02d" % [tr("DAY"), day, hour, minute]
	if minute % 10 == 0:
		_refresh_status()


func _on_phase_changed(phase: StringName) -> void:
	phase_label.text = tr("PHASE_" + String(phase).to_upper())


func _refresh_status() -> void:
	var speed := ""
	if GameClock.time_scale != 1.0:
		speed = "   [DEBUG x%d]" % int(GameClock.time_scale)
	_status.text = "%s %s   %s %d   %s %d%s" % [
			tr("WEATHER"), tr("WEATHER_" + GameState.weather_today().to_upper()),
			tr("MORALE"), int(round(GameState.morale)),
			tr("TRACE"), int(GameState.trace), speed]


func _refresh_survivors() -> void:
	for s in GameState.survivors:
		var card: Dictionary = _cards.get(s.id, {})
		if card.is_empty():
			continue
		var state := tr("ACT_" + Survivor.Activity.keys()[s.activity])
		if s.life != Survivor.Life.OK:
			state = tr("LIFE_" + Survivor.Life.keys()[s.life])
		(card["head"] as Label).text = "%s · %s · %s" % [tr(s.name_key), tr(GameData.job(s.job).get("name", "")), state]
		for stat: String in STATS:
			var v: float = s.get(stat)
			var pair: Array = card["bars"][stat]
			(pair[0] as ProgressBar).value = v
			(pair[1] as Label).text = str(int(ceil(v)))


func _refresh_stock() -> void:
	var parts: PackedStringArray = []
	for id: String in GameState.inventory:
		var n := GameState.count(id)
		if n > 0:
			parts.append("%s %d" % [GameData.display_name(GameData.item(id)), n])
	_stock.text = "%s: %s %.1f · %s %.1f\n%s" % [
			tr("STOREROOM"), tr("FOOD_DAYS"), GameState.food_days(), tr("WATER_DAYS"), GameState.water_days(),
			", ".join(parts)]


func _on_warning(text: String) -> void:
	_log_lines.append("%02d:%02d %s" % [GameClock.hour, GameClock.minute, text])
	while _log_lines.size() > 5:
		_log_lines.remove_at(0)
	_log.text = "\n".join(_log_lines)


func _on_run_ended(r: StringName, score_value: int) -> void:
	_end_label.text = "%s\n%s %d (%s)" % [tr("RESULT_" + String(r).to_upper()), tr("SCORE"), score_value, GameState.grade(score_value)]
