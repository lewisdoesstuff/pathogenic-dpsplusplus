extends Node

# Tooltip DPS overlay - replaces vanilla weapon DPS and injects infusor deltas.

var _last_item = null
var _last_stats_hash := 0

const SHOW_TOOLTIP_DPS := true
const SHOW_INFUSOR_IMPACT := true

func update() -> void:
	if not SHOW_TOOLTIP_DPS:
		_last_item = null
		return
	
	var tooltips_to_check := ["%HoverTooltip", "%BodypartTooltip", "%GeneTooltip"]
	var active_tooltip = null
	var active_item = null
	
	for tt_name in tooltips_to_check:
		var tt = G.editor.get_node_or_null(tt_name)
		if tt and tt.visible and is_instance_valid(tt.item) and tt.item is Bodypart and get_parent().is_weapon(tt.item) and not active_tooltip:
			active_tooltip = tt
			active_item = tt.item
	
	if not active_tooltip:
		_last_item = null
		return
	
	var stats_label = active_tooltip.get_node_or_null("%Stats")
	if not stats_label:
		return
	
	var current_hash = hash(stats_label.text) if stats_label.text else 0
	
	if active_item == _last_item and current_hash == _last_stats_hash:
		return
	
	_last_item = active_item
	_apply_overlay.call_deferred(active_tooltip, active_item)

func _apply_overlay(tooltip, bp: Bodypart) -> void:
	if not is_instance_valid(bp) or not is_instance_valid(tooltip):
		return
	if tooltip.item != bp:
		return
	
	var stats_label = tooltip.get_node_or_null("%Stats")
	var stats_panel = tooltip.get_node_or_null("%StatsPanel")
	if not stats_label:
		return
	
	var gfd = G.format_dict if is_instance_valid(G) and G.format_dict else {}
	var pos_col = gfd.get("pos", "[color=lime_green]")
	var pos_end = gfd.get("/pos", "[/color]")
	var neg_col = gfd.get("neg", "[color=orange_red]")
	var neg_end = gfd.get("/neg", "[/color]")
	var charge_icon = gfd.get("charge", "")
	var stat_tag = gfd.get("stat", "[b]")
	var stat_end_tag = gfd.get("/stat", "[/b]")
	var arrow = gfd.get("arrow", "→")
	
	var main = get_parent()
	var info: Dictionary = main.compute_weapon_dps(bp)
	var preview_data: Dictionary = main.compute_preview_dps(bp)
	var impacts: Array = main.compute_infusor_impacts(bp)
	var is_preview = not preview_data.is_empty() and preview_data.before_base != preview_data.after_base
	
	var current_text = stats_label.text
	
	# 1. Replace vanilla DPS number inside {stat}...{/stat}
	if info.dps_base > 0:
		var start_idx = current_text.find(stat_tag)
		if start_idx >= 0:
			var inner_start = start_idx + stat_tag.length()
			var end_idx = current_text.find(stat_end_tag, inner_start)
			if end_idx >= 0:
				var inner_text = current_text.substr(inner_start, end_idx - inner_start).strip_edges()
				var new_content = ""
				
				if is_preview:
					if arrow in inner_text:
						new_content = str(preview_data.before_base) + " " + arrow + " " + str(preview_data.after_base)
				elif inner_text.is_valid_int() and int(inner_text) != info.dps_base:
					new_content = str(info.dps_base)
				
				if new_content:
					current_text = current_text.substr(0, inner_start) + new_content + current_text.substr(inner_start + inner_text.length())
					end_idx += (len(new_content) - len(inner_text))
				
				# 2. Insert charged DPS inline
				if info.has_charge:
					var charged_delta = info.dps_charged - info.dps_base
					var charged_info = ""
					if is_preview and preview_data.has("before_charged") and preview_data.has("after_charged"):
						var bc_delta = preview_data.before_charged - preview_data.before_base
						var ac_delta = preview_data.after_charged - preview_data.after_base
						if bc_delta != ac_delta:
							charged_info = " [b](" + pos_col + charge_icon + "+" + str(bc_delta) + " " + arrow + " +" + str(ac_delta) + pos_end + ")[/b]"
						else:
							charged_info = " [b](" + pos_col + charge_icon + "+" + str(charged_delta) + pos_end + ")[/b]"
					else:
						charged_info = " [b](" + pos_col + charge_icon + "+" + str(charged_delta) + pos_end + ")[/b]"
					
					if charged_info and not charged_info in current_text:
						var after_stat = end_idx + stat_end_tag.length()
						var next_line = current_text.find("\n", after_stat)
						if next_line < 0:
							next_line = current_text.find("[font_size", after_stat)
						if next_line < 0:
							next_line = current_text.length()
						current_text = current_text.substr(0, next_line) + charged_info + current_text.substr(next_line)
	
	# 3. Inject per-modifier DPS deltas inline
	if SHOW_INFUSOR_IMPACT:
		for imp in impacts:
			var col = pos_col if imp.delta >= 0 else neg_col
			var end_col = pos_end if imp.delta >= 0 else neg_end
			var delta_str = " [b](" + col + "+" + str(imp.delta) + " DPS" + end_col + ")[/b]"
			if delta_str in current_text:
				continue
			var name_idx = current_text.find(imp.name)
			if name_idx < 0:
				continue
			var insert_pos = name_idx + imp.name.length()
			if current_text.substr(insert_pos).begins_with("[/color]"):
				insert_pos += 8
			current_text = current_text.substr(0, insert_pos) + delta_str + current_text.substr(insert_pos)
	
	stats_label.text = current_text
	if stats_panel:
		stats_panel.visible = current_text != ""
	_last_stats_hash = hash(stats_label.text) if stats_label.text else 0
