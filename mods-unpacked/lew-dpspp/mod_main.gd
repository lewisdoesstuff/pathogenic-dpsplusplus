extends Node

const MOD_DIR := "lew-dpspp"
const LOG_NAME := "lew-dpspp:Main"

var mod_dir_path := ""
var translations_dir_path := ""

var _ui_root: Control = null
var _ui_injected := false
var _plasmid_cache := []
var _plasmid_cache_time := 0
var _last_tooltip_item = null
var _stats_base_label: Label = null
var _stats_charged_label: Label = null

func _init() -> void:
	print("=== DPS++ init start ===")
	ModLoaderLog.info("=== DPS++ init start ===", LOG_NAME)
	mod_dir_path = ModLoaderMod.get_unpacked_dir().path_join(MOD_DIR)
	ModLoaderLog.info("=== DPS++ init done ===", LOG_NAME)

func _ready() -> void:
	ModLoaderLog.info("=== DPS++ _ready. Monitoring for Editor UI. ===", LOG_NAME)
	
	var tracker = load("res://mods-unpacked/" + MOD_DIR + "/realtime_tracker.gd").new()
	tracker.name = "RealtimeTracker"
	add_child(tracker)
	
	var overlay = load("res://mods-unpacked/" + MOD_DIR + "/tooltip_overlay.gd").new()
	overlay.name = "TooltipOverlay"
	add_child(overlay)

func _process(delta: float) -> void:
	var tracker = get_node_or_null("RealtimeTracker")
	if tracker:
		tracker.inject_label()
		tracker.update(delta)
	
	if not is_instance_valid(G.editor):
		_ui_injected = false
		return
	
	if not _ui_injected:
		_inject_ui()
		
	if G.editor.active:
		if is_instance_valid(_ui_root) and not _ui_root.visible:
			_ui_root.show()
		_update_stats_labels()
		
		var overlay = get_node_or_null("TooltipOverlay")
		if overlay:
			overlay.update()
	else:
		if is_instance_valid(_ui_root) and _ui_root.visible:
			_ui_root.hide()
		_last_tooltip_item = null

func _inject_ui() -> void:
	if not is_instance_valid(G.editor):
		return

	_ui_injected = true
	ModLoaderLog.info("DPS++ injecting editor UI...", LOG_NAME)

	_ui_root = Control.new()
	_ui_root.name = "DpsViewerRoot"
	_ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE

	G.editor.add_child(_ui_root)
	
	var vitals = _find_descendant(G.editor, "VitalsGraph")
	if vitals:
		var label_settings = null
		var label_modulate = Color(0, 0, 0, 0.45)
		
		var temp_label = _find_descendant(vitals, "TemperatureLabel")
		if temp_label:
			label_settings = temp_label.label_settings
			label_modulate = temp_label.modulate
		
		var stats_wrapper = VBoxContainer.new()
		stats_wrapper.name = "DpsStatsWrapper"
		stats_wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stats_wrapper.add_theme_constant_override("separation", 0)
		stats_wrapper.position = Vector2(40, 75)
		_ui_root.add_child(stats_wrapper)
			
		_stats_base_label = Label.new()
		_stats_base_label.name = "DpsBaseLabel"
		_stats_base_label.modulate = label_modulate
		_stats_base_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		if label_settings:
			_stats_base_label.label_settings = label_settings
		stats_wrapper.add_child(_stats_base_label)
		
		_stats_charged_label = Label.new()
		_stats_charged_label.name = "DpsChargedLabel"
		_stats_charged_label.modulate = label_modulate
		_stats_charged_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		if label_settings:
			_stats_charged_label.label_settings = label_settings
		stats_wrapper.add_child(_stats_charged_label)

func _update_stats_labels() -> void:
	if not _stats_base_label:
		return
	if not is_instance_valid(G.player):
		_stats_base_label.text = ""
		_stats_charged_label.text = ""
		return
	
	var total_base := 0.0
	var total_charged := 0.0
	var any_charge := false
	
	for slot in get_tree().get_nodes_in_group("slot"):
		if not is_instance_valid(slot) or not is_instance_valid(slot.bodypart): continue
		if not "player" in slot or slot.player != G.player: continue
		var bp: Bodypart = slot.bodypart
		if not _is_weapon(bp): continue
		
		var info := _get_weapon_dps_info(bp)
		if info.dps_base <= 0: continue
		
		total_base += info.dps_base
		total_charged += info.dps_charged if info.has_charge else info.dps_base
		if info.has_charge:
			any_charge = true
	
	if total_base <= 0:
		_stats_base_label.text = ""
		_stats_charged_label.text = ""
		return
	
	_stats_base_label.text = "DPS: " + str(roundi(total_base))
	if any_charge:
		_stats_charged_label.text = "Charged: " + str(roundi(total_charged))
	else:
		_stats_charged_label.text = ""
func _get_attack_speed(bp: Bodypart, default: float) -> float:
	if "HITS_PER_SECOND" in bp:
		return 1.0 / float(bp.get("HITS_PER_SECOND"))
	if bp.has_method("get_attack_speed"):
		return float(bp.get_attack_speed())
	elif bp.has_method("get_zap_cost") and bp.has_method("get_self_charge_mult"):
		var mult = bp.get_self_charge_mult()
		if mult > 0:
			return 1.0 / mult * float(bp.get_zap_cost())
	elif "attack_speed" in bp:
		return float(bp.get("attack_speed"))
	return default

func _get_weapon_dps_info(bp: Bodypart, _override_infusors = null) -> Dictionary:
	var res := {"dps_base": 0, "dps_charged": 0, "has_charge": false, "modifier_names": [] as Array[String]}
	
	var base_dmg := 0.0
	var atk_speed := 0.1
	var base_num_shots := 1.0
	var charge_speed_bonus := 0.0
	var raw_dps_fallback := 0.0
	var is_gun := bp is Gun

	if bp.has_method("get_damage"):
		base_dmg = bp.get_damage()
	elif bp.has_method("get_tick_burn"):
		base_dmg = float(bp.get_tick_burn())
	
	atk_speed = _get_attack_speed(bp, atk_speed)
			
	if atk_speed <= 0: return res

	if is_gun:
		var gun: Gun = bp as Gun
		base_dmg = gun.base_damage * gun.get_damage_mult()
		if bp.get_script() and bp.get_script().resource_path.get_file() == "staurolobber.gd":
			base_dmg = 35.0 * (1.5 / 0.1) * 4.0 * gun.get_damage_mult()
		if gun.has_method("get_num_shots"):
			base_num_shots = float(gun.get_num_shots())
		charge_speed_bonus = gun.attack_speed_charge_bonus
	elif bp.has_method("get_format_dict"):
		var fmt: Dictionary = bp.get_format_dict()
		if fmt.has("dps"):
			raw_dps_fallback = float(fmt["dps"])
		if bp.has_method("get_charge_attack_speed_bonus"):
			charge_speed_bonus = float(bp.get_charge_attack_speed_bonus())

	var infusors = _override_infusors if _override_infusors != null else _get_connected_infusors(bp)
	res.modifier_names = _get_modifier_names(bp)

	var total_charge = _get_connected_charge(bp)
	if total_charge > 0: 
		res.has_charge = true
	else:
		for inf in infusors:
			if _get_connected_charge(inf) > 0:
				res.has_charge = true
				break

	var num_shots_charged = base_num_shots
	if bp.has_method("get_shot_num_charge_bonus"):
		num_shots_charged += roundi(total_charge * float(bp.get_shot_num_charge_bonus()))

	var mut_mults = _get_global_mutation_mults(bp)
	
	var base_atk_speed = atk_speed / (1.0 + mut_mults.atk_speed_bonus)
	var charged_atk_speed = atk_speed / (1.0 + mut_mults.atk_speed_bonus + charge_speed_bonus * total_charge)
	
	for inf in infusors:
		if not is_instance_valid(inf) or not is_instance_valid(inf.res) or not inf.get_script(): continue
		var p_name = inf.get_script().resource_path.get_file()
		var inf_charge = _get_connected_charge(inf)
		if p_name == "auto_shooter.gd":
			if inf.has_method("get_attack_speed_mult"):
				base_atk_speed /= inf.get_attack_speed_mult()
				charged_atk_speed /= (inf.get_attack_speed_mult() * (1.0 + inf.get_attack_speed_charge_bonus() * inf_charge))
		elif p_name == "firerate_no_miss.gd":
			if inf.has_method("get_attack_speed_per_hit"):
				var bonus = inf.get_attack_speed_per_hit() * inf.get_max_hits()
				base_atk_speed /= (1.0 + bonus)
				charged_atk_speed /= (1.0 + bonus + bonus * inf.get_hit_charge_bonus() * inf_charge)

	var dmg_base = _apply_infusors(bp, base_dmg, base_num_shots, infusors, false)
	dmg_base *= mut_mults.base_mult
	dmg_base += mut_mults.flat_add

	if raw_dps_fallback > 0 and base_dmg <= 0:
		res.dps_base = roundi(raw_dps_fallback)
	else:
		res.dps_base = roundi(dmg_base / base_atk_speed)

	var dmg_charged = _apply_infusors(bp, base_dmg, num_shots_charged, infusors, true)
	
	if bp.has_method("get_charge_damage_bonus"):
		dmg_charged *= 1.0 + float(bp.get_charge_damage_bonus()) * total_charge

	dmg_charged *= mut_mults.base_mult
	dmg_charged += mut_mults.flat_add

	if charged_atk_speed > 0:
		res.dps_charged = roundi(dmg_charged / charged_atk_speed)
	else:
		res.dps_charged = res.dps_base

	return res

func _apply_infusors(bp: Bodypart, base_damage: float, num_shots: int, infusors: Array, use_charge: bool) -> float:
	var current_damage = base_damage
	var current_shots = num_shots

	for inf in infusors:
		if not is_instance_valid(inf) or not is_instance_valid(inf.res): continue
		
		var rarity = inf.rarity
		var inf_charge = 0.0
		if use_charge:
			inf_charge = _get_connected_charge(inf)

		if inf.res.ui_name == "o_damage_mult_name":
			var mult = 0.25 + rarity * 0.15 + (inf_charge * (0.4 + rarity * 0.1))
			current_damage += base_damage * mult
		elif inf.res.ui_name == "o_damage_charge_mult_name":
			var mult = -0.4 + rarity * 0.1 + (inf_charge * (1.6 + rarity * 0.2))
			current_damage += base_damage * mult
		elif inf.res.ui_name == "o_triple_shot_name":
			var mult = 0.25 + rarity * 0.1
			if inf_charge > 0:
				mult += inf_charge * 0.25
			var extra_shots = current_shots * 2
			var total_dmg = current_damage * current_shots + (extra_shots * (current_damage * mult))
			current_shots *= 3
			current_damage = total_dmg / float(current_shots)
		elif inf.res.ui_name == "o_split_shot_name":
			var mult = 0.95 + rarity * 0.1
			var extra_shots = current_shots * 1
			var total_dmg = current_damage * current_shots + (extra_shots * (current_damage * mult))
			current_shots *= 2
			current_damage = total_dmg / float(current_shots)
		elif inf.res.ui_name == "o_side_laser_name":
			var mult = (1.0 + 0.4 * rarity + inf_charge * 0.5)
			var extra_lasers = 2
			current_damage += extra_lasers * (base_damage * mult)
		elif inf.get_script() and inf.get_script().resource_path.get_file() == "piercing.gd":
			var mult = -0.4 + rarity * 0.1
			if use_charge:
				mult += inf_charge * 0.15
			current_damage += base_damage * mult
		elif inf.get_script() and inf.get_script().resource_path.get_file() == "rhythm_damage.gd":
			var c = (1.0 + inf_charge) / (3.0 + inf_charge)
			var mult = lerp(-1.0, 2.0 + rarity * 0.7, c)
			current_damage += base_damage * mult
		elif inf.get_script() and inf.get_script().resource_path.get_file() == "damage_up_on_recycle.gd":
			var mult = -0.2 + rarity * 0.05
			if inf.has_method("get_damage_mult"):
				mult = float(inf.get_damage_mult())
			current_damage += base_damage * mult
	
	if is_instance_valid(bp.slot) and bp.slot.get_script() and bp.slot.get_script().resource_path.ends_with("slot_damage.gd"):
		current_damage += base_damage * 0.4
		
	var active_plasmids = _get_active_plasmids_data()
	for p in active_plasmids:
		var is_node = p is Node
		var p_name = ""
		var dmg_mult = 0.0
		
		if is_node:
			if not is_instance_valid(p) or not p.get_script(): continue
			p_name = p.get_script().resource_path.get_file()
			dmg_mult = float(p.get("damage_mult")) if "damage_mult" in p else 0.0
		elif p is Dictionary:
			p_name = p.get("script_name", "")
			dmg_mult = float(p.get("damage_mult", 0.0))
			
		if p_name in ["damage_plasmid.gd", "glass_cannon_plasmid.gd", "damage_lower_hp_plasmid.gd", "auto_shoot_plasmid.gd"]:
			current_damage += base_damage * dmg_mult
		elif p_name == "top_damage_plasmid.gd":
			if is_instance_valid(bp.slot) and not bp.slot.internal and bp.slot_body_offset().y < -50.0:
				current_damage += base_damage * dmg_mult
		elif p_name == "bottom_damage_plasmid.gd":
			if is_instance_valid(bp.slot) and not bp.slot.internal and bp.slot_body_offset().y > 50.0:
				current_damage += base_damage * dmg_mult
		elif p_name == "bottom_melee_damage_plasmid.gd":
			if bp.has_tag(G.BodypartTags.MeleeWeapon) and is_instance_valid(bp.slot) and not bp.slot.internal and bp.slot_body_offset().y > 50.0:
				current_damage += base_damage * dmg_mult
		elif p_name == "damage_progression_plasmid.gd":
			if is_node and p.has_method("_current_mult"):
				current_damage += base_damage * p._current_mult()

	return current_damage * current_shots

func _get_active_plasmids_data() -> Array:
	var pm = get_node_or_null("/root/PlasmidManager")
	if not is_instance_valid(pm): return []
	
	if "applied_plasmids" in pm and not pm.applied_plasmids.is_empty():
		return pm.applied_plasmids
		
	var current_time = Time.get_ticks_msec()
	if current_time - _plasmid_cache_time < 1000:
		return _plasmid_cache
		
	_plasmid_cache_time = current_time
	_plasmid_cache.clear()
	
	if pm.has_method("get_plasmid_map_scene"):
		var scene = pm.get_plasmid_map_scene()
		if scene:
			var map = scene.instantiate()
			for p in map.get_children():
				if p.has_method("restore"):
					p.restore()
				if "active" in p and p.active:
					var p_data = {}
					if p.get_script():
						p_data["script_name"] = p.get_script().resource_path.get_file()
					if "damage_mult" in p:
						p_data["damage_mult"] = p.damage_mult
					if "mutation_res" in p and p.mutation_res and p.mutation_res.get_script():
						p_data["mutation_script_name"] = p.mutation_res.get_script().resource_path.get_file()
					_plasmid_cache.append(p_data)
			map.queue_free()
			
	return _plasmid_cache

func _get_global_mutation_mults(bp: Bodypart) -> Dictionary:
	var base_mult = 1.0
	var flat_add = 0.0
	var atk_speed_bonus = 0.0
	
	var active_mutations = []
	if is_instance_valid(G.player):
		for m in G.player.mutations:
			active_mutations.append(m.get_script().resource_path.get_file())
	
	# Also pull starting mutations from cached metaprogression plasmids (editor menu)
	var cached_plasmids = _get_active_plasmids_data()
	for p in cached_plasmids:
		if p is Dictionary and p.get("script_name") == "starting_mutation_plasmid.gd":
			var mut_script = p.get("mutation_script_name", "")
			if mut_script and mut_script not in active_mutations:
				active_mutations.append(mut_script)

	var in_game = is_instance_valid(G.player)
	var slots = G.player.slots if in_game else G.main.get_tree().get_nodes_in_group("slot")

	# Check for cell evolutions (active in-game or hovered in editor)
	var active_evo = null
	if in_game and "evolution" in G.player and is_instance_valid(G.player.get("evolution")):
		active_evo = G.player.evolution
	elif not in_game and is_instance_valid(G.editor) and G.editor.has_method("is_choosing_mutation") and G.editor.is_choosing_mutation():
		var tooltip = G.editor.get_node_or_null("%MutationTooltip")
		if tooltip and "item" in tooltip and tooltip.item and tooltip.item.get_script() and tooltip.item.get_script().resource_path.get_file() == "evolution.gd":
			active_evo = tooltip.item
			
	if active_evo and "bonus_damage" in active_evo:
		base_mult += float(active_evo.get("bonus_damage"))

	for m_name in active_mutations:
		if m_name == "damage_mutation.gd":
			base_mult += 0.10
		elif m_name == "glass_cannon_mutation.gd":
			base_mult += 0.50
		elif m_name == "stamina_damage_mutation.gd":
			if in_game:
				var missing = (G.player.get_max_stamina(bp) - G.player.get_stamina(bp)) / 100.0
				base_mult += missing * 0.15
		elif m_name == "money_damage_mutation.gd":
			if in_game:
				base_mult += G.player.money * 0.005
		elif m_name == "low_health_buff_mutation.gd":
			if in_game and G.player.hp <= 1.0: 
				base_mult += 0.5
				atk_speed_bonus += 0.4
		elif m_name == "speed_damage_mutation.gd":
			var total_thrust = 0
			for s in slots:
				if is_instance_valid(s.bodypart) and s.bodypart is Lash:
					var thrust := roundi(s.bodypart.power * s.bodypart.get_rarity_mult() / 30.0)
					total_thrust += (thrust * 2) if ("mirror" in s and s.mirror and is_instance_valid(s.mirror_slot)) else thrust
			base_mult += total_thrust * 0.0075
		elif m_name == "attack_speed_mutation.gd":
			atk_speed_bonus += 0.15
		elif m_name == "empty_islot_damage_mutation.gd":
			var empty = 0
			for slot in slots:
				if is_instance_valid(slot) and slot.internal and slot.bodypart == null:
					empty += 1
			base_mult += empty * 0.20
		elif m_name == "few_weapons_buff_mutation.gd":
			var w_count = 0
			for slot in slots:
				if is_instance_valid(slot) and slot.bodypart is Gun:
					w_count += 1
			base_mult += max(2.0 - (w_count * 0.5), -0.9)
		elif m_name == "myofibrillar_hypertrophy_mutation.gd":
			if bp.has_tag(G.BodypartTags.MeleeWeapon):
				base_mult += 0.15
		elif m_name == "no_stamina_mutation.gd":
			base_mult -= 0.30
		elif m_name == "respiratory_burst_mutation.gd":
			var gen_count = 0
			for slot in slots:
				if is_instance_valid(slot) and slot.bodypart and slot.bodypart.has_tag(G.BodypartTags.EnergyGenerator):
					var b = slot.bodypart
					# In editor provided_charge might not update dynamically, check its charge
					if in_game:
						if b.get("provided_charge") and b.provided_charge > 0.9: gen_count += 1
					else:
						# In editor, just assume any generator with >0 charge is active
						if _get_connected_charge(b) > 0: gen_count += 1
			base_mult += gen_count * 0.15
		elif m_name == "right_hand_mutation.gd":
			if is_instance_valid(bp.slot) and not bp.slot.internal:
				var offset_x = bp.slot_body_offset().x
				if offset_x > 15.0: base_mult += 1.0
				elif offset_x < -15.0: base_mult -= 0.5
		elif m_name == "left_hand_mutation.gd":
			if is_instance_valid(bp.slot) and not bp.slot.internal:
				var offset_x = bp.slot_body_offset().x
				if offset_x < -15.0: base_mult += 1.0
				elif offset_x > 15.0: base_mult -= 0.5
		
	return {"base_mult": base_mult, "flat_add": flat_add, "atk_speed_bonus": atk_speed_bonus}

func _is_weapon(bp: Bodypart) -> bool:
	if bp.has_tag(G.BodypartTags.Weapon): return true
	if bp.has_method("_fire"): return true
	if bp.has_method("get_damage") and bp.has_method("get_attack_speed"): return true
	if bp.has_method("get_damage") and bp.has_method("get_zap_cost"): return true
	return false

func _get_bodypart_name(bp: Bodypart) -> String:
	if not is_instance_valid(bp): return ""
	if bp.has_method("get_ui_name"): return str(bp.get_ui_name())
	return bp.name.capitalize()

func _get_connected_infusors(bp: Bodypart) -> Array:
	var infusors = []
	var start_slot = bp.slot if is_instance_valid(bp.slot) else bp.get("preview_slot")
	if not is_instance_valid(start_slot): return infusors
	var visited = {}
	var queue = [start_slot]
	visited[start_slot] = true
	while queue.size() > 0:
		var cur = queue.pop_front()
		for nb_slot in cur.connections:
			if not visited.has(nb_slot) and is_instance_valid(nb_slot) and is_instance_valid(nb_slot.bodypart):
				visited[nb_slot] = true
				var nb = nb_slot.bodypart
				
				if nb.has_tag(G.BodypartTags.AttackModifier) or nb.has_tag(G.BodypartTags.BulletModifier) or nb.has_tag(G.BodypartTags.WeaponModifier):
					infusors.append(nb)
				
				# Only propagate the BFS if this node actually passes attacks to its neighbors
				var propagates = false
				if nb.has_method("modify_attack"):
					var script = nb.get_script()
					if script and script.source_code.find("c.modify_attack") != -1:
						propagates = true
				
				if propagates:
					queue.append(nb_slot)
	return infusors

func _get_connected_charge(bp: Bodypart) -> float:
	var total = 0.0
	var start_slot = bp.slot if is_instance_valid(bp.slot) else bp.get("preview_slot")
	if not is_instance_valid(start_slot): return total
	var visited = {}
	var queue = [start_slot]
	visited[start_slot] = true
	while queue.size() > 0:
		var cur = queue.pop_front()
		for nb_slot in cur.connections:
			if not visited.has(nb_slot) and is_instance_valid(nb_slot) and is_instance_valid(nb_slot.bodypart):
				visited[nb_slot] = true
				
				var nb = nb_slot.bodypart
				if nb.get_script() and "conduit" in nb.get_script().resource_path:
					queue.append(nb_slot)
					
				if nb.has_tag(G.BodypartTags.EnergyGenerator):
					var c = 0.0
					if nb.provided_charge > 0:
						c = nb.provided_charge
					elif nb.has_method("get_charge"):
						c = float(nb.get_charge())
					else:
						c = 3.0
					
					var gen_mult = 1.0
					if is_instance_valid(nb_slot) and nb_slot.get_script() and nb_slot.get_script().resource_path.ends_with("slot_energy.gd"):
						gen_mult += 0.4
					total += c * gen_mult
						
	var consumer_mult = 1.0
	if is_instance_valid(start_slot) and start_slot.get_script() and start_slot.get_script().resource_path.ends_with("slot_energy.gd"):
		consumer_mult += 0.4

	return total * consumer_mult

func _get_modifier_names(bp: Bodypart) -> Array[String]:
	var names: Array[String] = []
	var start_slot = bp.slot if is_instance_valid(bp.slot) else bp.get("preview_slot")
	if not is_instance_valid(start_slot): return names
	var visited = {}
	var queue = [start_slot]
	visited[start_slot] = true
	while queue.size() > 0:
		var cur = queue.pop_front()
		for nb_slot in cur.connections:
			if not visited.has(nb_slot) and is_instance_valid(nb_slot) and is_instance_valid(nb_slot.bodypart):
				visited[nb_slot] = true
				var nb = nb_slot.bodypart
				
				if nb.has_tag(G.BodypartTags.AttackModifier) or nb.has_tag(G.BodypartTags.BulletModifier) or nb.has_tag(G.BodypartTags.WeaponModifier) or nb.has_tag(G.BodypartTags.EnergyGenerator):
					names.append(_get_bodypart_name(nb))
				
				# Only propagate the BFS if this node actually passes attacks to its neighbors
				var propagates = false
				if nb.has_method("modify_attack"):
					var script = nb.get_script()
					if script and script.source_code.find("c.modify_attack") != -1:
						propagates = true
				elif nb.has_tag(G.BodypartTags.EnergyGenerator) or nb.has_method("get_charge"):
					# Generators propagate charge, so we should visually show anything attached to them?
					# Wait, if we are listing modifier names FOR THIS WEAPON's ATTACK, 
					# then it should strictly follow attack propagation!
					propagates = false
				
				if propagates:
					queue.append(nb_slot)
	return names

# Public wrappers for child-node access
func compute_weapon_dps(bp, override_infusors = null):
	return _get_weapon_dps_info(bp, override_infusors)

func compute_preview_dps(bp):
	return _compute_preview_dps(bp)

func compute_infusor_impacts(bp):
	return _get_infusor_impacts(bp)

func is_weapon(bp):
	return _is_weapon(bp)

func find_descendant(root: Node, node_name: String) -> Node:
	return _find_descendant(root, node_name)

func _get_infusor_impacts(bp: Bodypart) -> Array:
	var results: Array = []
	var all_infusors = _get_connected_infusors(bp)
	if all_infusors.size() <= 0:
		return results
	
	var full_info = _get_weapon_dps_info(bp)
	if full_info.dps_base <= 0:
		return results
	
	for inf in all_infusors:
		if not is_instance_valid(inf):
			continue
		var reduced = all_infusors.duplicate()
		reduced.erase(inf)
		var info_without = _get_weapon_dps_info(bp, reduced)
		var delta = full_info.dps_base - info_without.dps_base
		if delta != 0:
			var entry = {"name": _get_bodypart_name(inf), "delta": delta}
			if full_info.has_charge:
				entry["delta_charged"] = full_info.dps_charged - info_without.dps_charged
			results.append(entry)
	
	results.sort_custom(func(a, b): return abs(b.delta) < abs(a.delta))
	return results

func _compute_preview_dps(bp: Bodypart) -> Dictionary:
	if not bp.has_method("has_active_preview") or not bp.has_active_preview():
		return {}
	
	var snap = bp.get("_preview_snapshot")
	if snap == null or snap.is_empty():
		return {}
	
	var saved_rarity = bp.base_rarity
	var saved_prefixes = bp.prefixes.duplicate()
	var saved_rooms = bp.rooms_left
	
	var after_info = _get_weapon_dps_info(bp)
	
	bp.base_rarity = snap.get("base_rarity", saved_rarity)
	bp.prefixes = (snap.get("prefixes", []) as Array).duplicate()
	bp.rooms_left = snap.get("rooms_left", saved_rooms)
	
	var before_info = _get_weapon_dps_info(bp)
	
	bp.base_rarity = saved_rarity
	bp.prefixes = saved_prefixes
	bp.rooms_left = saved_rooms
	
	return {
		"before_base": before_info.dps_base,
		"before_charged": before_info.dps_charged,
		"after_base": after_info.dps_base,
		"after_charged": after_info.dps_charged,
	}

func _find_descendant(root: Node, node_name: String) -> Node:
	for child in root.get_children():
		if child.name == node_name:
			return child
		var found = _find_descendant(child, node_name)
		if found:
			return found
	return null
