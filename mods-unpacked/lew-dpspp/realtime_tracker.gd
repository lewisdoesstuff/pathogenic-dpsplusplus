extends Node

const SAMPLE_INTERVAL := 0.25
const SMOOTHING := 0.3
const SHOW_DPS := true

var label: Label = null
var _injected := false
var _sample_damage := 0.0
var _sample_timer := 0.0
var _displayed := 0.0

func _ready() -> void:
	var sb = get_node_or_null("/root/SignalBus")
	if sb and sb.has_signal("enemy_hit"):
		sb.enemy_hit.connect(_on_enemy_hit)

func _on_enemy_hit(_enemy, damage: float, _attack) -> void:
	_sample_damage += damage

func inject_label() -> void:
	if _injected:
		return
	if not is_instance_valid(G.ui):
		return
	if not G.ui.is_inside_tree():
		return
	var money_label = get_parent().find_descendant(G.ui, "MoneyLabel")
	if not money_label or not money_label.get_parent():
		return
	var hbox = money_label.get_parent()
	var settings = money_label.label_settings
	
	label = Label.new()
	label.name = "DpsRealtimeLabel"
	label.modulate = money_label.modulate
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if settings:
		label.label_settings = settings.duplicate()
		label.label_settings.font_size = 24
	hbox.add_child(label)
	hbox.move_child(label, money_label.get_index() + 1)
	_injected = true

func update(delta: float) -> void:
	if not label:
		return
	if not is_instance_valid(label):
		label = null
		return
	if not SHOW_DPS:
		label.text = ""
		return
	
	_sample_timer -= delta
	if _sample_timer <= 0:
		var interval = SAMPLE_INTERVAL - _sample_timer
		var instant_dps = _sample_damage / max(interval, 0.01)
		_displayed = lerp(_displayed, instant_dps, SMOOTHING)
		_sample_damage = 0.0
		_sample_timer = SAMPLE_INTERVAL
	
	var shown = roundi(_displayed)
	label.text = "DPS: " + str(shown) if shown > 0 else ""
	
	if _sample_damage <= 0 and _sample_timer < SAMPLE_INTERVAL - 1.0:
		_displayed = lerp(_displayed, 0.0, SMOOTHING * 0.5)
