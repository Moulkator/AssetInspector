#########################################################################################################
##
## INSPECT ASSET MOD
## Adds a toggle button to the SelectTool panel that shows a tooltip with the asset name
## when hovering over assets on the map
##
#########################################################################################################

var script_class = "tool"

var select_tool = null
var select_tool_panel = null
var inspect_button = null
var settings_button = null
var settings_popup = null
var scale_slider = null
var scale_spinbox = null
var reset_button = null
var tooltip_label = null
var inspect_enabled = false
var ui_scale = 1.0
var follow_cursor = true
var hide_delay = 2.0  # seconds before hiding tooltip in fixed mode
var inspect_button_row = null  # HBox containing inspect button + cog
var follow_cursor_toggle = null
var hide_delay_slider = null
var hide_delay_spinbox = null
var hide_delay_container = null  # Container for timer UI (shown only in fixed mode)

# Drag support for fixed mode
var tooltip_dragging = false
var tooltip_drag_offset = Vector2.ZERO
var tooltip_custom_position = null  # Saved position for fixed mode
var tooltip_hide_timer = null  # Timer for auto-hiding in fixed mode

const TOOLTIP_OFFSET = Vector2(15, 15)  # Offset from cursor
const SCALE_MIN = 0.5
const SCALE_MAX = 5.0
const SCALE_DEFAULT = 1.0
const SCALE_STEP = 0.1
const SETTINGS_FILE = "user://inspect_asset_settings.json"
const SHORTCUT_ACTION = "inspect_asset_toggle"

func start() -> void:
	print("[InspectAsset] start() called")

	# Register with _lib if available (enables the update checker + rebindable shortcut)
	if Engine.has_signal("_lib_register_mod"):
		Engine.emit_signal("_lib_register_mod", self)
		if "API" in Global and Global.API.has("UpdateChecker"):
			var uc = Global.API.UpdateChecker
			uc.register(uc.builder()\
				.fetcher(uc.github_fetcher("Moulkator", "AssetInspector"))\
				.downloader(uc.github_downloader("Moulkator", "AssetInspector"))\
				.build())
		register_shortcut()
	select_tool = Global.Editor.Tools["SelectTool"]
	select_tool_panel = Global.Editor.Toolset.GetToolPanel("SelectTool")
	print("[InspectAsset] Mod root: ", Global.Root)
	
	# Load saved settings (global, persists across maps)
	load_settings()
	
	# Create the UI elements
	call_deferred("setup_ui")

func save_settings() -> void:
	var data = {
		"ui_scale": ui_scale,
		"follow_cursor": follow_cursor,
		"hide_delay": hide_delay
	}
	if tooltip_custom_position != null:
		data["tooltip_pos_x"] = tooltip_custom_position.x
		data["tooltip_pos_y"] = tooltip_custom_position.y
	var file = File.new()
	file.open(SETTINGS_FILE, File.WRITE)
	file.store_line(JSON.print(data, "\t"))
	file.close()
	print("[InspectAsset] Settings saved (ui_scale: ", ui_scale, ")")

func load_settings() -> void:
	var file = File.new()
	if not file.file_exists(SETTINGS_FILE):
		print("[InspectAsset] No settings file found, using defaults")
		return
	file.open(SETTINGS_FILE, File.READ)
	var text = file.get_as_text()
	file.close()
	var result = JSON.parse(text)
	if result.error == OK and result.result is Dictionary:
		var data = result.result
		if data.has("ui_scale"):
			ui_scale = clamp(float(data["ui_scale"]), SCALE_MIN, SCALE_MAX)
		if data.has("follow_cursor"):
			follow_cursor = bool(data["follow_cursor"])
		if data.has("hide_delay"):
			hide_delay = clamp(float(data["hide_delay"]), 0.0, 5.0)
		if data.has("tooltip_pos_x") and data.has("tooltip_pos_y"):
			tooltip_custom_position = Vector2(float(data["tooltip_pos_x"]), float(data["tooltip_pos_y"]))
		print("[InspectAsset] Settings loaded (ui_scale: ", ui_scale, ")")
	else:
		print("[InspectAsset] Failed to parse settings file")

func register_shortcut() -> void:
	# Requires _Lib's InputMapApi (rebindable via _Lib's Preferences window).
	if not ("API" in Global) or Global.API == null:
		print("[InspectAsset] _Lib API not available, shortcut disabled")
		return

	# Default keybind: CTRL+I. _Lib's deserialize_event splits on "+",
	# reads modifiers (alt/ctrl/cmd/shift) and parses the last token as a
	# scancode when it is a valid integer (KEY_I == 73 in Godot 3).
	var inputs = {
		"Toggle Inspect Mode": [SHORTCUT_ACTION, "Ctrl+" + str(KEY_I)]
	}

	# Clear stale events from previous load attempts so the default below
	# isn't appended on top of leftover bindings.
	if InputMap.has_action(SHORTCUT_ACTION):
		InputMap.action_erase_events(SHORTCUT_ACTION)

	# Step 1: register the action and bind the default key in InputMap.
	Global.API.InputMapApi.add_actions(inputs, "Asset Inspector")

	# Step 2: expose the binding in _Lib's Preferences so the user can
	# rebind it. build() also loads any previously saved rebind, which
	# then overrides the CTRL+I default above.
	Global.API.ModConfigApi.create_config() \
		.shortcuts("shortcuts", inputs) \
		.build()

	# Hook _Lib's master InputEventEmitterNode: signal_input fires from
	# _input (before _unhandled_input), so we can consume the event
	# before DD reacts to it.
	var emitter = Global.API.InputMapApi.master_event_emitter()
	emitter.connect("signal_input", self, "_on_lib_input")
	print("[InspectAsset] Shortcut registered (default CTRL+I)")

func _on_lib_input(event, emitter) -> void:
	# Only react while the Select Tool is active.
	if Global.Editor.ActiveTool != select_tool:
		return
	if not (event is InputEventKey):
		return
	if not event.pressed or event.echo:
		return
	if not InputMap.event_is_action(event, SHORTCUT_ACTION):
		return
	if inspect_button == null:
		return

	# Toggling .pressed on a toggle-mode Button emits "toggled" in Godot 3,
	# so _on_inspect_toggled runs and keeps the UI state in sync.
	inspect_button.pressed = not inspect_button.pressed

	# Consume the event so nothing else reacts to CTRL+I.
	emitter.accept_event()

func _load_icon(icon_path: String, scale: float = 1.0) -> ImageTexture:
	var full_path = Global.Root + icon_path
	var image = Image.new()
	var err = image.load(full_path)
	if err != OK:
		print("[InspectAsset] Warning: could not load icon: ", full_path)
		return null
	if scale != 1.0:
		var new_size = Vector2(image.get_width() * scale, image.get_height() * scale)
		image.resize(int(new_size.x), int(new_size.y), Image.INTERPOLATE_LANCZOS)
	var texture = ImageTexture.new()
	texture.create_from_image(image)
	return texture

func _make_icon_button(icon_path: String, tooltip: String, icon_scale: float = 1.0) -> Button:
	var btn = Button.new()
	btn.hint_tooltip = tooltip
	var tex = _load_icon(icon_path, icon_scale)
	if tex != null:
		btn.icon = tex
	return btn

func setup_ui() -> void:
	# Create the toggle button in the SelectTool panel
	create_inspect_button()
	
	# Create the settings button next to the inspect button
	create_settings_button()
	
	# Create the settings popup (initially hidden)
	create_settings_popup()
	
	# Create the tooltip label (initially hidden)
	create_tooltip_label()
	
	# Apply the loaded scale value to the UI
	apply_ui_scale()
	
	print("[InspectAsset] UI setup complete")

func create_inspect_button() -> void:
	# Use CreateButton which places the button among other tool buttons
	inspect_button = select_tool_panel.CreateButton("Inspect Mode", "res://ui/icons/misc/search.png")
	inspect_button.toggle_mode = true
	inspect_button.pressed = false
	inspect_button.connect("toggled", self, "_on_inspect_toggled")

func create_settings_button() -> void:
	# Create the cog button as a toggle
	settings_button = _make_icon_button("icons/cog.png", "Show/hide settings", 0.55)
	settings_button.name = "InspectSettingsBtn"
	settings_button.toggle_mode = true
	settings_button.pressed = false
	settings_button.connect("toggled", self, "_on_settings_toggled")
	
	# Wrap inspect button + cog in an HBox
	inspect_button_row = HBoxContainer.new()
	inspect_button_row.name = "InspectButtonRow"
	
	var parent = inspect_button.get_parent()  # "Align" VBoxContainer
	if parent != null:
		var idx = inspect_button.get_index()
		parent.remove_child(inspect_button)
		inspect_button_row.add_child(inspect_button)
		inspect_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		inspect_button_row.add_child(settings_button)
		
		# Find the right insertion point: just before the first hidden VBoxContainer
		# These hidden VBoxContainers are the asset-specific options that expand when
		# an asset is selected, pushing everything below them down.
		var insert_idx = parent.get_child_count()  # default: end
		for i in range(parent.get_child_count()):
			var child = parent.get_child(i)
			if child is VBoxContainer and not child.visible:
				insert_idx = i
				break
		
		parent.add_child(inspect_button_row)
		parent.move_child(inspect_button_row, insert_idx)
		print("[InspectAsset] Buttons placed at index ", insert_idx, " (before hidden option panels)")

func create_settings_popup() -> void:
	settings_popup = VBoxContainer.new()
	settings_popup.name = "InspectSettingsPanel"
	settings_popup.visible = false
	
	# --- UI Scale ---
	var scale_label = Label.new()
	scale_label.text = "UI Scale"
	scale_label.add_color_override("font_color", Color(0.85, 0.85, 0.85, 1.0))
	settings_popup.add_child(scale_label)
	
	# [Slider] [SpinBox] [Reset] on same row
	var scale_hbox = HBoxContainer.new()
	scale_hbox.name = "ScaleRow"
	scale_hbox.set("custom_constants/separation", 4)
	
	scale_slider = HSlider.new()
	scale_slider.min_value = SCALE_MIN
	scale_slider.max_value = SCALE_MAX
	scale_slider.step = SCALE_STEP
	scale_slider.value = ui_scale
	scale_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scale_slider.connect("value_changed", self, "_on_scale_slider_changed")
	scale_hbox.add_child(scale_slider)
	
	scale_spinbox = SpinBox.new()
	scale_spinbox.min_value = SCALE_MIN
	scale_spinbox.max_value = SCALE_MAX
	scale_spinbox.step = SCALE_STEP
	scale_spinbox.value = ui_scale
	scale_spinbox.rect_min_size.x = 60
	scale_spinbox.connect("value_changed", self, "_on_scale_spinbox_changed")
	scale_hbox.add_child(scale_spinbox)
	
	reset_button = _make_icon_button("icons/reset.png", "Reset to default (1.0)", 0.5)
	reset_button.rect_min_size = Vector2(28, 28)
	reset_button.connect("pressed", self, "_on_reset_scale")
	scale_hbox.add_child(reset_button)
	
	settings_popup.add_child(scale_hbox)
	
	# --- Separator ---
	var sep = HSeparator.new()
	sep.add_constant_override("separation", 6)
	settings_popup.add_child(sep)
	
	# --- Follow cursor toggle ---
	var follow_hbox = HBoxContainer.new()
	follow_hbox.name = "FollowCursorRow"
	var follow_label = Label.new()
	follow_label.text = "Follow cursor"
	follow_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	follow_hbox.add_child(follow_label)
	follow_cursor_toggle = CheckButton.new()
	follow_cursor_toggle.pressed = follow_cursor
	follow_cursor_toggle.connect("toggled", self, "_on_follow_cursor_toggled")
	follow_hbox.add_child(follow_cursor_toggle)
	settings_popup.add_child(follow_hbox)
	
	# --- Hide delay (only visible in fixed mode) ---
	hide_delay_container = VBoxContainer.new()
	hide_delay_container.name = "HideDelayContainer"
	hide_delay_container.visible = not follow_cursor
	
	var delay_label = Label.new()
	delay_label.text = "Hide delay"
	delay_label.add_color_override("font_color", Color(0.85, 0.85, 0.85, 1.0))
	hide_delay_container.add_child(delay_label)
	
	# [Slider] [SpinBox] on same row
	var delay_hbox = HBoxContainer.new()
	delay_hbox.name = "DelayRow"
	delay_hbox.set("custom_constants/separation", 4)
	
	hide_delay_slider = HSlider.new()
	hide_delay_slider.min_value = 0.0
	hide_delay_slider.max_value = 5.0
	hide_delay_slider.step = 0.5
	hide_delay_slider.value = hide_delay
	hide_delay_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hide_delay_slider.connect("value_changed", self, "_on_hide_delay_changed")
	delay_hbox.add_child(hide_delay_slider)
	
	hide_delay_spinbox = SpinBox.new()
	hide_delay_spinbox.min_value = 0.0
	hide_delay_spinbox.max_value = 5.0
	hide_delay_spinbox.step = 0.5
	hide_delay_spinbox.value = hide_delay
	hide_delay_spinbox.suffix = "s"
	hide_delay_spinbox.rect_min_size.x = 60
	hide_delay_spinbox.connect("value_changed", self, "_on_hide_delay_spinbox_changed")
	delay_hbox.add_child(hide_delay_spinbox)
	
	hide_delay_container.add_child(delay_hbox)
	settings_popup.add_child(hide_delay_container)
	
	# Insert into the panel's Align VBox, right after the button row
	var align_vbox = inspect_button_row.get_parent()
	if align_vbox != null:
		var idx = inspect_button_row.get_index()
		align_vbox.add_child(settings_popup)
		align_vbox.move_child(settings_popup, idx + 1)
	
	print("[InspectAsset] Settings panel created inline")

func create_tooltip_label() -> void:
	# Create a label for displaying asset info
	tooltip_label = Label.new()
	tooltip_label.name = "InspectTooltip"
	
	# Style the tooltip
	var stylebox = StyleBoxFlat.new()
	stylebox.bg_color = Color(0.1, 0.1, 0.1, 0.9)
	stylebox.border_color = Color(0.5, 0.5, 0.5, 1.0)
	stylebox.border_width_top = 1
	stylebox.border_width_bottom = 1
	stylebox.border_width_left = 1
	stylebox.border_width_right = 1
	stylebox.corner_radius_top_left = 4
	stylebox.corner_radius_top_right = 4
	stylebox.corner_radius_bottom_left = 4
	stylebox.corner_radius_bottom_right = 4
	stylebox.content_margin_left = 8
	stylebox.content_margin_right = 8
	stylebox.content_margin_top = 4
	stylebox.content_margin_bottom = 4
	
	tooltip_label.add_stylebox_override("normal", stylebox)
	tooltip_label.add_color_override("font_color", Color(1, 1, 1, 1))
	
	# Set mouse filter based on mode
	if follow_cursor:
		tooltip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	else:
		tooltip_label.mouse_filter = Control.MOUSE_FILTER_STOP
	
	tooltip_label.visible = false
	
	# Connect drag signals for fixed mode
	tooltip_label.connect("gui_input", self, "_on_tooltip_gui_input")
	
	# Add to the UI layer (CanvasLayer) so it's always on top
	var ui_layer = CanvasLayer.new()
	ui_layer.layer = 100  # High layer to be on top
	ui_layer.name = "InspectTooltipLayer"
	
	Global.Editor.add_child(ui_layer)
	ui_layer.add_child(tooltip_label)
	
	# Create timer for auto-hide in fixed mode
	tooltip_hide_timer = Timer.new()
	tooltip_hide_timer.one_shot = true
	tooltip_hide_timer.connect("timeout", self, "_on_hide_timer_timeout")
	Global.Editor.add_child(tooltip_hide_timer)
	
	print("[InspectAsset] Tooltip label created")

func _on_inspect_toggled(pressed: bool) -> void:
	inspect_enabled = pressed
	print("[InspectAsset] Inspect mode: ", "ON" if pressed else "OFF")
	
	if not pressed:
		tooltip_label.visible = false

func _on_tooltip_gui_input(event) -> void:
	# Only handle drag in fixed mode
	if follow_cursor:
		return
	
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT:
			if event.pressed:
				tooltip_dragging = true
				tooltip_drag_offset = tooltip_label.rect_position - event.global_position
			else:
				tooltip_dragging = false
				tooltip_custom_position = tooltip_label.rect_position
				save_settings()
	
	elif event is InputEventMouseMotion:
		if tooltip_dragging:
			var new_pos = event.global_position + tooltip_drag_offset
			
			# Clamp to window bounds
			var viewport = Global.Editor.get_viewport()
			var screen_size = viewport.size
			var tooltip_size = tooltip_label.rect_size
			
			new_pos.x = clamp(new_pos.x, 0, screen_size.x - tooltip_size.x)
			new_pos.y = clamp(new_pos.y, 0, screen_size.y - tooltip_size.y)
			
			tooltip_label.rect_position = new_pos

func _on_settings_toggled(pressed: bool) -> void:
	settings_popup.visible = pressed

func _on_follow_cursor_toggled(pressed: bool) -> void:
	follow_cursor = pressed
	if follow_cursor:
		tooltip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tooltip_hide_timer.stop()
	else:
		tooltip_label.mouse_filter = Control.MOUSE_FILTER_STOP
	# Show/hide the delay slider
	if hide_delay_container != null:
		hide_delay_container.visible = not follow_cursor
	save_settings()
	print("[InspectAsset] Follow cursor: ", "ON" if pressed else "OFF")

func _on_hide_delay_changed(value: float) -> void:
	hide_delay = value
	if hide_delay_spinbox.value != value:
		hide_delay_spinbox.value = value
	save_settings()

func _on_hide_delay_spinbox_changed(value: float) -> void:
	hide_delay = clamp(value, 0.0, 5.0)
	if hide_delay_slider.value != hide_delay:
		hide_delay_slider.value = hide_delay
	save_settings()

func _on_hide_timer_timeout() -> void:
	tooltip_label.visible = false

func _on_scale_slider_changed(value: float) -> void:
	ui_scale = value
	# Sync the spinbox without triggering its signal back
	if scale_spinbox.value != value:
		scale_spinbox.value = value
	apply_ui_scale()
	save_settings()

func _on_scale_spinbox_changed(value: float) -> void:
	ui_scale = clamp(value, SCALE_MIN, SCALE_MAX)
	# Sync the slider without triggering its signal back
	if scale_slider.value != ui_scale:
		scale_slider.value = ui_scale
	apply_ui_scale()
	save_settings()

func _on_reset_scale() -> void:
	ui_scale = SCALE_DEFAULT
	scale_slider.value = SCALE_DEFAULT
	scale_spinbox.value = SCALE_DEFAULT
	apply_ui_scale()
	save_settings()
	print("[InspectAsset] UI scale reset to default: ", SCALE_DEFAULT)

var base_font_size = -1  # Will store the original font size

func apply_ui_scale() -> void:
	# Apply scale by changing the font size (avoids pixelation unlike rect_scale)
	if tooltip_label != null:
		# Get or create a dynamic font to control size
		var current_font = tooltip_label.get_font("font")
		
		# Store the base font size on first call
		if base_font_size < 0:
			if current_font != null and current_font is DynamicFont:
				base_font_size = current_font.size
			else:
				base_font_size = 14  # Default Godot font size
		
		if current_font != null and current_font is DynamicFont:
			# Duplicate the font so we don't affect other labels
			var scaled_font = current_font.duplicate()
			scaled_font.size = int(base_font_size * ui_scale)
			tooltip_label.add_font_override("font", scaled_font)
		else:
			# If the default font is not a DynamicFont, create one
			var dyn_font = DynamicFont.new()
			var default_font_data = load("res://ui/fonts/Alegreya-Regular.ttf")
			if default_font_data == null:
				default_font_data = load("res://ui/fonts/default.ttf")
			if default_font_data != null:
				dyn_font.font_data = default_font_data
			dyn_font.size = int(base_font_size * ui_scale)
			tooltip_label.add_font_override("font", dyn_font)
		
		# Also scale the stylebox margins proportionally
		var stylebox = tooltip_label.get_stylebox("normal")
		if stylebox != null and stylebox is StyleBoxFlat:
			var scaled_box = stylebox.duplicate()
			var margin = int(8 * ui_scale)
			var v_margin = int(4 * ui_scale)
			scaled_box.content_margin_left = margin
			scaled_box.content_margin_right = margin
			scaled_box.content_margin_top = v_margin
			scaled_box.content_margin_bottom = v_margin
			tooltip_label.add_stylebox_override("normal", scaled_box)
		
		# Recalculate tooltip size with the new font/margins
		call_deferred("_resize_tooltip")
	
	print("[InspectAsset] UI scale set to: ", ui_scale)

func _is_mouse_over_tooltip() -> bool:
	if follow_cursor or tooltip_label == null or not tooltip_label.visible:
		return false
	var mouse_pos = tooltip_label.get_global_mouse_position()
	return tooltip_label.get_global_rect().has_point(mouse_pos)

func update(delta: float) -> void:
	if not inspect_enabled:
		return
	
	# Only show tooltip when SelectTool is active
	if not Global.Editor.Toolset.ToolPanels["SelectTool"].visible:
		tooltip_label.visible = false
		return
	
	# Check if mouse is over the content area (map)
	var content = Global.Editor.get("content")
	if content != null:
		var mouse_pos = content.get_global_mouse_position()
		var content_rect = content.get_global_rect()
		if not content_rect.has_point(mouse_pos):
			# In fixed mode, freeze everything if hovering tooltip
			if not follow_cursor and _is_mouse_over_tooltip():
				tooltip_hide_timer.stop()
				return
			if follow_cursor:
				tooltip_label.visible = false
			return
	
	# In fixed mode, if mouse is over the tooltip, freeze (don't update text, don't start timer)
	if not follow_cursor and _is_mouse_over_tooltip():
		tooltip_hide_timer.stop()
		return
	
	# Get highlighted asset
	select_tool.HighlightThingAtPoint()
	var highlighted_selectable = select_tool.get("highlighted")
	
	if highlighted_selectable != null:
		var node = highlighted_selectable.get("Thing")
		
		if node != null:
			var asset_name = get_asset_display_name(node, highlighted_selectable)
			tooltip_label.text = asset_name
			
			# Defer size recalculation so Godot processes the new text first
			call_deferred("_resize_tooltip")
			
			if follow_cursor:
				# Follow cursor mode: position near mouse
				var viewport = Global.Editor.get_viewport()
				var screen_mouse_pos = viewport.get_mouse_position()
				tooltip_label.rect_position = screen_mouse_pos + TOOLTIP_OFFSET
				
				var screen_size = viewport.size
				var tooltip_size = tooltip_label.rect_size
				
				if tooltip_label.rect_position.x + tooltip_size.x > screen_size.x:
					tooltip_label.rect_position.x = screen_mouse_pos.x - tooltip_size.x - 5
				if tooltip_label.rect_position.y + tooltip_size.y > screen_size.y:
					tooltip_label.rect_position.y = screen_mouse_pos.y - tooltip_size.y - 5
			else:
				# Fixed mode: use saved position or default to top-center
				if not tooltip_dragging:
					if tooltip_custom_position != null:
						tooltip_label.rect_position = tooltip_custom_position
					elif not tooltip_label.visible:
						var viewport = Global.Editor.get_viewport()
						var screen_size = viewport.size
						call_deferred("_position_tooltip_centered", screen_size)
				# Reset hide timer since we have content
				tooltip_hide_timer.stop()
			
			tooltip_label.visible = true
		else:
			_handle_no_asset()
	else:
		_handle_no_asset()

func _resize_tooltip() -> void:
	# Manually calculate the exact size needed for the current text
	# because Godot 3.x Label doesn't reliably shrink rect_size
	var font = tooltip_label.get_font("font")
	if font == null:
		return
	
	var text = tooltip_label.text
	var lines = text.split("\n")
	
	# Calculate width: widest line
	var max_width = 0.0
	for line in lines:
		var w = font.get_string_size(line).x
		if w > max_width:
			max_width = w
	
	# Calculate height: line count * line height
	var line_height = font.get_height()
	var total_height = line_height * lines.size()
	
	# Add stylebox margins
	var stylebox = tooltip_label.get_stylebox("normal")
	if stylebox != null:
		max_width += stylebox.get_margin(MARGIN_LEFT) + stylebox.get_margin(MARGIN_RIGHT)
		total_height += stylebox.get_margin(MARGIN_TOP) + stylebox.get_margin(MARGIN_BOTTOM)
	
	var target_size = Vector2(max_width, total_height)
	tooltip_label.rect_min_size = target_size
	tooltip_label.rect_size = target_size

func _handle_no_asset() -> void:
	if follow_cursor:
		tooltip_label.visible = false
	else:
		# Don't start hide timer while mouse is over tooltip
		if _is_mouse_over_tooltip():
			tooltip_hide_timer.stop()
			return
		# Fixed mode: start the hide timer if not already running
		if tooltip_label.visible and hide_delay > 0 and tooltip_hide_timer.is_stopped():
			tooltip_hide_timer.start(hide_delay)
		elif tooltip_label.visible and hide_delay == 0:
			tooltip_label.visible = false

func _position_tooltip_centered(screen_size: Vector2) -> void:
	tooltip_label.rect_size = Vector2.ZERO
	var tooltip_size = tooltip_label.rect_size
	tooltip_label.rect_position.x = (screen_size.x - tooltip_size.x) / 2
	tooltip_label.rect_position.y = 60
	tooltip_custom_position = tooltip_label.rect_position

func get_asset_display_name(node, selectable = null) -> String:
	var lines = []
	var sel_type = -1
	if selectable != null and selectable.get("Type") != null:
		sel_type = selectable.Type
	
	# Line 1: Asset name
	var resource_name = get_resource_name(node)
	if resource_name != "":
		lines.append(resource_name)
	else:
		lines.append(node.name)
	
	# Line 2: [Type] | [Layer] (layer only for Objects, Paths, Patterns/Tilesets)
	var line2_parts = []
	var asset_type = get_asset_type_name(node, selectable)
	if asset_type != "":
		line2_parts.append("[" + asset_type + "]")
	
	# Add layer for Objects (4), Paths (5), Patterns/Tilesets (7)
	if sel_type == 4 or sel_type == 5 or sel_type == 7:
		var layer_info = get_layer_info(node)
		if layer_info != "":
			line2_parts.append("[" + layer_info + "]")
	
	if line2_parts.size() > 0:
		lines.append(PoolStringArray(line2_parts).join(" | "))
	
	# Line 3: Pack name
	var pack_name = get_pack_name(node, selectable)
	if pack_name != "":
		lines.append(pack_name)
	
	return PoolStringArray(lines).join("\n")

func get_pack_name(node, selectable = null) -> String:
	var tex_path = get_texture_path(node, selectable)
	if tex_path == "":
		return ""
	
	# Check if it's from a pack or default assets
	# Path format: "res://packs/PACKID/textures/..."
	if tex_path.begins_with("res://packs/"):
		# Extract pack ID - skip "res://packs/" (12 chars)
		var after_packs = tex_path.right(12)
		var slash_idx = after_packs.find("/")
		var pack_id = ""
		if slash_idx != -1:
			pack_id = after_packs.left(slash_idx)
		else:
			pack_id = after_packs
		
		if pack_id != "":
			# Get pack info from Global.Editor.owner.AssetPacks
			var pack = Global.Editor.owner.AssetPacks.get(pack_id)
			if pack != null and pack.get("Name") != null:
				return pack.Name
			else:
				return pack_id  # Fallback to ID
	elif tex_path.begins_with("res://textures/"):
		return "Default Assets"
	
	return ""

func get_layer_info(node) -> String:
	var layer_value = 0
	var layer_found = false
	
	# Method 1: Check node's Layer property (uppercase) - for Patterns
	if node.get("Layer") != null:
		layer_value = node.Layer
		layer_found = true
	
	# Method 2: Check z_index (for Objects, Paths)
	if not layer_found and node.z_index != 0:
		layer_value = node.z_index
		layer_found = true
	
	# Method 3: For Patterns (Polygon2D), check parent's z_index
	if not layer_found and node is Polygon2D:
		var parent = node.get_parent()
		if parent != null and parent.get("z_index") != null:
			layer_value = parent.z_index
			layer_found = true
	
	# Method 4: z_index == 0 is a valid layer (Floor), check if the node actually has z_index
	if not layer_found and node.get("z_index") != null:
		layer_value = node.z_index
		layer_found = true
	
	if layer_found:
		var layer_name = get_layer_display_name(layer_value)
		return str(layer_value) + ": " + layer_name
	
	return ""

func get_layer_display_name(layer_value: int) -> String:
	# Common layer names in Dungeondraft
	match layer_value:
		-400: return "Below Terrain"
		-300: return "Terrain"
		-200: return "Below Ground"
		-100: return "Ground"
		0: return "Floor"
		100: return "User Layer 1"
		200: return "User Layer 2"
		300: return "User Layer 3"
		400: return "User Layer 4"
		500: return "User Layer 5"
		900: return "Above Everything"
	
	# Default naming based on value
	if layer_value < 0:
		return "Below Ground"
	elif layer_value > 0:
		return "User Layer"
	else:
		return "Ground"

func get_texture_path(node, selectable = null) -> String:
	var sel_type = -1
	if selectable != null and selectable.get("Type") != null:
		sel_type = selectable.Type
	
	# Use the correct method based on type (from AssetManager.gd)
	# Wall=1, Portal=2,3, Object=4: prop.Texture
	# Path=5, Light=6: prop.get_texture()
	# Pattern=7: prop._Texture
	# Roof=8: prop.TilesTexture
	
	match sel_type:
		1, 2, 3, 4:  # Wall, Portal, Object
			if node.get("Texture") != null and node.Texture != null:
				return node.Texture.resource_path
		5, 6:  # Path, Light
			if node.has_method("get_texture"):
				var tex = node.get_texture()
				if tex != null:
					return tex.resource_path
		7:  # Pattern
			if node.get("_Texture") != null and node._Texture != null:
				return node._Texture.resource_path
		8:  # Roof
			if node.get("TilesTexture") != null and node.TilesTexture != null:
				return node.TilesTexture.resource_path
	
	return ""

func get_asset_type_name(node, selectable = null) -> String:
	# Use selectable type if available
	var sel_type = -1
	if selectable != null and selectable.get("Type") != null:
		sel_type = selectable.Type
	
	# For Type 7, differentiate between Tileset and Pattern based on texture path
	if sel_type == 7:
		var tex_path = get_texture_path(node, selectable)
		if "/tilesets/" in tex_path:
			return "Tileset"
		elif "/patterns/" in tex_path:
			return "Pattern"
		else:
			return "Pattern"  # Default fallback
	
	# Other types
	match sel_type:
		1: return "Wall"
		2: return "Portal"
		3: return "Portal"
		4: return "Object"
		5: return "Path"
		6: return "Light"
		8: return "Roof"
	
	# Fallback based on node class
	var node_class = node.get_class()
	if node_class == "Polygon2D" or node is Polygon2D:
		return "Pattern"
	elif node_class == "Line2D" or node is Line2D:
		return "Path"
	
	return ""

func get_resource_name(node) -> String:
	var selectable = select_tool.get("highlighted")
	var tex_path = get_texture_path(node, selectable)
	
	if tex_path != "":
		return extract_name_from_path(tex_path)
	
	return ""

func extract_name_from_path(path: String) -> String:
	# Handle different path formats:
	# Tilesets: res://textures/tilesets/simple/tileset_brick_basketweave.png
	# Patterns: res://textures/patterns/normal/pattern_name.png
	# Roofs: res://textures/roofs/plank_mossy/tiles.png (use folder name)
	# Objects: res://textures/objects/category/object_name.png
	# Walls: res://packs/PACKID/textures/walls/Wall_Name.webp
	# Paths: res://textures/paths/path_name.png
	
	var name = ""
	
	# For roofs, use the folder name (e.g., "plank_mossy" from ".../roofs/plank_mossy/tiles.png")
	if "/roofs/" in path and "/tiles.png" in path:
		var parts = path.split("/")
		for i in range(parts.size()):
			if parts[i] == "roofs" and i + 1 < parts.size():
				name = parts[i + 1]
				break
	else:
		# For other assets, use filename without extension
		var filename = path.get_file()
		name = filename.get_basename()
		
		# Remove common prefixes
		if name.begins_with("tileset_"):
			name = name.substr(8)
		elif name.begins_with("Wall_"):
			name = name.substr(5)
		elif name.begins_with("Path_"):
			name = name.substr(5)
	
	# Clean up the name
	# Replace underscores with spaces
	name = name.replace("_", " ")
	
	# Capitalize first letter of each word
	var words = name.split(" ")
	var capitalized = []
	for word in words:
		if word.length() > 0:
			capitalized.append(word.capitalize())
	
	return PoolStringArray(capitalized).join(" ")
