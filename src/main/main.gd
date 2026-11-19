extends Node2D
## Entry scene for the grey-box prototype (stage 2).
## Left: base tabs (base view, build, craft, work queue). Right: survivor
## cards and a short warning log. Plain boxes and text on purpose.

const FONT_SIZE := 10
const BAR_COLORS := {
	"health": Color(0.80, 0.30, 0.30),
	"food": Color(0.85, 0.62, 0.30),
	"water": Color(0.35, 0.60, 0.85),
	"stamina": Color(0.55, 0.75, 0.40),
}
const STATS := ["health", "food", "water", "stamina"]
const DEBUG_SPEEDS := {KEY_1: 1.0, KEY_2: 4.0, KEY_3: 16.0, KEY_4: 60.0}
const FACILITY_COLORS := {
	"facility": Color(0.30, 0.36, 0.42),
	"defense": Color(0.45, 0.32, 0.28),
}
const MUTED := Color(0.62, 0.62, 0.62)
const BAD := Color(0.90, 0.55, 0.45)

@onready var title_label: Label = $UI/TitleLabel
@onready var clock_label: Label = $UI/ClockLabel
@onready var phase_label: Label = $UI/PhaseLabel

var _theme: Theme
var _cards: Dictionary = {}   # survivor id -> {head, bars}
var _status: Label
var _log: Label
var _log_lines: PackedStringArray = []
var _end_label: Label
var _tabs: TabContainer
var _base_grid: GridContainer
var _base_info: Label
var _stock: Label
var _build_list: VBoxContainer
var _craft_list: VBoxContainer
var _work_list: VBoxContainer
var _work_bars: Array[ProgressBar] = []


func _ready() -> void:
	_theme = Theme.new()
	_theme.default_font_size = FONT_SIZE
	for c in $UI.get_children():
		if c is Control:
			(c as Control).theme = _theme
	$Roof.visible = false
	title_label.text = "%s · %s" % [tr("GAME_TITLE"), tr("PROTOTYPE_NOTE")]
	_build_ui()
	GameClock.minute_changed.connect(_on_minute_changed)
	GameClock.phase_changed.connect(_on_phase_changed)
	GameState.survivors_changed.connect(_refresh_survivors)
	GameState.inventory_changed.connect(_refresh_lists)
	GameState.built_changed.connect(_refresh_lists)
	GameState.queue_changed.connect(_refresh_lists)
	GameState.morale_changed.connect(func(_v: float) -> void: _refresh_status())
	GameState.warning.connect(_on_warning)
	GameState.run_ended.connect(_on_run_ended)
	_on_minute_changed(GameClock.day, GameClock.hour, GameClock.minute)
	_on_phase_changed(GameClock.phase)
	_refresh_survivors()
	_refresh_lists()


func _unhandled_input(event: InputEvent) -> void:
	# Debug-only speed keys for testing; the game itself has no pause.
	if OS.is_debug_build() and event is InputEventKey and event.pressed and not event.echo:
		var key: int = (event as InputEventKey).keycode
		if DEBUG_SPEEDS.has(key):
			GameClock.time_scale = DEBUG_SPEEDS[key]
			_refresh_status()


# ------------------------------------------------------------------ layout

func _build_ui() -> void:
	var ui: CanvasLayer = $UI
	_status = _label(ui, Vector2(8, 22), Vector2(390, 14))
	_end_label = _label(ui, Vector2(8, 150), Vector2(390, 40))
	_end_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end_label.add_theme_font_size_override("font_size", 16)
	_end_label.z_index = 10

	_tabs = TabContainer.new()
	_tabs.theme = _theme
	_tabs.position = Vector2(8, 40)
	_tabs.size = Vector2(384, 314)
	ui.add_child(_tabs)
	_tabs.add_child(_make_base_tab())
	_build_list = _make_list_tab("TAB_BUILD")
	_craft_list = _make_list_tab("TAB_CRAFT")
	_work_list = _make_list_tab("TAB_WORK")
	_tabs.set_tab_title(0, tr("TAB_BASE"))

	var panel := PanelContainer.new()
	panel.theme = _theme
	panel.position = Vector2(400, 40)
	panel.size = Vector2(232, 232)
	ui.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)
	for s in GameState.survivors:
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", 0)
		box.add_child(card)
		var head := Label.new()
		head.clip_text = true
		head.custom_minimum_size = Vector2(220, 0)
		card.add_child(head)
		var bars: Dictionary = {}
		for stat: String in STATS:
			var row := HBoxContainer.new()
			card.add_child(row)
			var name_label := Label.new()
			name_label.text = tr("STAT_" + stat.to_upper())
			name_label.custom_minimum_size = Vector2(40, 0)
			row.add_child(name_label)
			var bar := ProgressBar.new()
			bar.max_value = 100
			bar.show_percentage = false
			bar.custom_minimum_size = Vector2(146, 7)
			bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var fill := StyleBoxFlat.new()
			fill.bg_color = BAR_COLORS[stat]
			bar.add_theme_stylebox_override("fill", fill)
			row.add_child(bar)
			var value := Label.new()
			value.custom_minimum_size = Vector2(26, 0)
			value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			row.add_child(value)
			bars[stat] = [bar, value]
		_cards[s.id] = {"head": head, "bars": bars}

	_log = _label(ui, Vector2(402, 276), Vector2(230, 80))
	_log.add_theme_color_override("font_color", Color(0.95, 0.80, 0.55))
	_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log.clip_text = true


func _make_base_tab() -> Control:
	var v := VBoxContainer.new()
	v.name = "Base"
	_base_grid = GridContainer.new()
	_base_grid.columns = 4
	_base_grid.add_theme_constant_override("h_separation", 4)
	_base_grid.add_theme_constant_override("v_separation", 4)
	v.add_child(_base_grid)
	_base_info = Label.new()
	v.add_child(_base_info)
	_stock = Label.new()
	_stock.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stock.custom_minimum_size = Vector2(370, 0)
	v.add_child(_stock)
	return v


func _make_list_tab(title_key: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title_key
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, tr(title_key))
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	scroll.add_child(list)
	return list


func _label(parent: Node, pos: Vector2, sz: Vector2) -> Label:
	var l := Label.new()
	l.theme = _theme
	l.position = pos
	l.size = sz
	parent.add_child(l)
	return l


# ------------------------------------------------------------------ refresh

func _on_minute_changed(day: int, hour: int, minute: int) -> void:
	clock_label.text = "%s %d  %02d:%02d" % [tr("DAY"), day, hour, minute]
	if minute % 10 == 0:
		_refresh_status()
	_refresh_work_bars()


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
		var task := GameState.task_of(s)
		if not task.is_empty():
			state = GameState.task_name(task)
		if s.life != Survivor.Life.OK:
			state = tr("LIFE_" + Survivor.Life.keys()[s.life])
		if s.injury != "":
			state += " · " + tr("INJ_" + s.injury.to_upper())
		(card["head"] as Label).text = "%s · %s · %s" % [tr(s.name_key), tr(GameData.job(s.job).get("name", "")), state]
		for stat: String in STATS:
			var v: float = s.get(stat)
			var pair: Array = card["bars"][stat]
			(pair[0] as ProgressBar).value = v
			(pair[1] as Label).text = str(int(ceil(v)))


func _refresh_lists() -> void:
	_refresh_base()
	_refresh_build()
	_refresh_craft()
	_refresh_work()


func _refresh_base() -> void:
	for c in _base_grid.get_children():
		c.queue_free()
	for fid: String in GameData.facilities:
		var n := int(GameState.built.get(fid, 0))
		if n <= 0:
			continue
		var f: Dictionary = GameData.facility(fid)
		var tile := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.bg_color = FACILITY_COLORS.get(f.get("kind", "facility"), FACILITY_COLORS["facility"])
		style.set_content_margin_all(3)
		tile.add_theme_stylebox_override("panel", style)
		tile.custom_minimum_size = Vector2(88, 34)
		var l := Label.new()
		l.text = GameData.display_name(f) + ("" if n == 1 else " x%d" % n)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tile.add_child(l)
		_base_grid.add_child(tile)
	_base_info.text = "%s %d/%d   %s %d   %s %.1f · %s %.1f" % [
			tr("STORAGE_SLOTS"), GameState.storage_used(), GameState.storage_capacity(),
			tr("DEFENSE"), GameState.defense_from_facilities(),
			tr("FOOD_DAYS"), GameState.food_days(), tr("WATER_DAYS"), GameState.water_days()]
	var parts: PackedStringArray = []
	for id: String in GameState.inventory:
		var n := GameState.count(id)
		if n > 0:
			parts.append("%s %d" % [GameData.display_name(GameData.item(id)), n])
	_stock.text = "%s: %s" % [tr("STOREROOM"), ", ".join(parts)]


func _refresh_build() -> void:
	for c in _build_list.get_children():
		c.queue_free()
	for fid: String in GameData.facilities:
		var f: Dictionary = GameData.facility(fid)
		if f.get("built_at_start", false):
			continue
		var hours := float(f.get("build_hours", 2))
		var cost := _cost_text(f.get("cost", {}))
		var reqs := ", ".join(Array(f.get("requires", [])).map(func(r: String) -> String: return _thing_name(r)))
		var hours_text := str(int(hours)) if is_equal_approx(hours, round(hours)) else str(hours)
		var detail := "%s · %s%s" % [cost, tr("HOURS_FMT").format({"h": hours_text, "real": _real_time(hours * 60.0)}),
				("" if reqs == "" else " · " + tr("NEEDS") + " " + reqs)]
		var have := int(GameState.built.get(fid, 0))
		var title := GameData.display_name(f) + ("" if have == 0 else "  (%s %d)" % [tr("BUILT"), have])
		_add_row(_build_list, title, detail, GameState.build_blocker(fid), func() -> void: GameState.queue_build(fid))


func _refresh_craft() -> void:
	for c in _craft_list.get_children():
		c.queue_free()
	for station: String in ["workbench", "stove"]:
		var head := Label.new()
		head.text = "— %s —" % GameData.display_name(GameData.facility(station))
		head.add_theme_color_override("font_color", MUTED)
		_craft_list.add_child(head)
		for rid: String in GameData.recipes:
			var r: Dictionary = GameData.recipes[rid]
			if r.get("station", "") != station:
				continue
			var inputs := _cost_text(r.get("inputs", {}))
			if int(r.get("fuel", 0)) > 0:
				inputs += " + " + tr("FUEL_OR_WOOD")
			if r.has("uses_durability"):
				inputs += " (" + _thing_name(String(r["uses_durability"])) + ")"
			var mins := float(r.get("minutes", 30))
			var detail := "%s · %s" % [inputs, tr("MINUTES_FMT").format({"m": int(mins), "real": _real_time(mins)})]
			var title := GameData.display_name(r)
			var out_id: String = Dictionary(r.get("output", {})).keys()[0]
			if GameState.count(out_id) > 0:
				title += "  (%s %d)" % [tr("HAVE"), GameState.count(out_id)]
			_add_row(_craft_list, title, detail, GameState.craft_blocker(rid), func() -> void: GameState.queue_craft(rid))


func _refresh_work() -> void:
	for c in _work_list.get_children():
		c.queue_free()
	_work_bars.clear()
	if GameState.tasks.is_empty():
		var l := Label.new()
		l.text = tr("WORK_EMPTY")
		l.add_theme_color_override("font_color", MUTED)
		_work_list.add_child(l)
	for i in GameState.tasks.size():
		var t: Dictionary = GameState.tasks[i]
		var row := HBoxContainer.new()
		_work_list.add_child(row)
		var name_l := Label.new()
		name_l.text = GameState.task_name(t)
		name_l.custom_minimum_size = Vector2(96, 0)
		name_l.clip_text = true
		row.add_child(name_l)
		var who := Label.new()
		var w := GameState._survivor(int(t["worker"]))
		who.text = tr(w.name_key) if w else tr("WAITING")
		who.custom_minimum_size = Vector2(52, 0)
		if not w:
			who.add_theme_color_override("font_color", MUTED)
		row.add_child(who)
		var bar := ProgressBar.new()
		bar.max_value = float(t["total"])
		bar.value = float(t["done"])
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(150, 7)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color(0.85, 0.75, 0.40) if w else Color(0.45, 0.45, 0.45)
		bar.add_theme_stylebox_override("fill", fill)
		row.add_child(bar)
		_work_bars.append(bar)
		var cancel := Button.new()
		cancel.text = tr("CANCEL")
		cancel.pressed.connect(func() -> void: GameState.cancel_task(i))
		row.add_child(cancel)
	_tabs.set_tab_title(3, "%s (%d)" % [tr("TAB_WORK"), GameState.tasks.size()])


func _refresh_work_bars() -> void:
	if _work_bars.size() != GameState.tasks.size():
		return
	for i in _work_bars.size():
		_work_bars[i].value = float(GameState.tasks[i]["done"])


## One clickable line: [title] detail, greyed out with the reason when it can't start.
func _add_row(list: VBoxContainer, title: String, detail: String, blocker: String, on_press: Callable) -> void:
	var row := HBoxContainer.new()
	list.add_child(row)
	var b := Button.new()
	b.text = title
	b.custom_minimum_size = Vector2(118, 0)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.disabled = blocker != ""
	b.pressed.connect(on_press)
	row.add_child(b)
	var info := Label.new()
	info.text = detail if blocker == "" else detail + "\n" + _reason_text(blocker)
	info.custom_minimum_size = Vector2(240, 0)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_color_override("font_color", MUTED if blocker == "" else BAD)
	row.add_child(info)


func _cost_text(cost: Dictionary) -> String:
	if cost.is_empty():
		return tr("FREE")
	var parts: PackedStringArray = []
	for id: String in cost:
		parts.append("%s %d" % [_thing_name(id), int(cost[id])])
	return ", ".join(parts)


func _thing_name(id: String) -> String:
	if GameData.items.has(id):
		return GameData.display_name(GameData.item(id))
	if GameData.facilities.has(id):
		return GameData.display_name(GameData.facility(id))
	return id


func _reason_text(code: String) -> String:
	var p := code.split(":")
	match p[0]:
		"REASON_NEED_ITEM":
			return tr("REASON_NEED_ITEM").format({"item": _thing_name(p[1]), "n": p[2]})
		"REASON_NEED_TOOL", "REASON_NEED_FACILITY":
			return tr(p[0]).format({"item": _thing_name(p[1])})
		"REASON_NEED_STATION":
			for fid: String in GameData.facilities:
				if GameData.facility(fid).get("effects", {}).get("station", "") == p[1]:
					return tr("REASON_NEED_FACILITY").format({"item": _thing_name(fid)})
	return tr(p[0])


## In-game minutes -> real time text (1 in-game minute = 0.5 s at normal speed).
func _real_time(game_minutes: float) -> String:
	var secs := int(round(game_minutes * GameClock.seconds_per_game_minute))
	if secs < 60:
		return tr("REAL_SECONDS").format({"s": secs})
	var m: float = snapped(secs / 60.0, 0.5)
	return tr("REAL_MINUTES").format({"m": str(int(m)) if is_equal_approx(m, round(m)) else str(m)})


func _on_warning(text: String) -> void:
	_log_lines.append("%02d:%02d %s" % [GameClock.hour, GameClock.minute, text])
	while _log_lines.size() > 5:
		_log_lines.remove_at(0)
	_log.text = "\n".join(_log_lines)


func _on_run_ended(r: StringName, score_value: int) -> void:
	_end_label.text = "%s\n%s %d (%s)" % [tr("RESULT_" + String(r).to_upper()), tr("SCORE"), score_value, GameState.grade(score_value)]
