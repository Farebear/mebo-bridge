@tool
extends RefCounted

## JSON-RPC 2.0 server for the mebo IDE, over raw TCP with LSP-style
## `Content-Length: <n>\r\n\r\n<body>` framing (the same transport Godot's own
## language server uses on port 6005). Bound to localhost only.
##
## Params/results use camelCase keys. Godot values that don't fit JSON travel
## as `var_to_str` strings; string values sent to set_node_property are run
## through `str_to_var` (and `load()` for res:// paths of existing resources).

const DEFAULT_PORT := 6010
# Must match plugin.cfg's version; ping reports it so the IDE can tell when a
# stale copy of the addon is still the one running in the editor.
const VERSION := "0.3.0"
# Byte length of the "\r\n\r\n" header terminator. (A PackedByteArray
# constructor call is not a constant expression, so keep the size, not
# the bytes; _find_header_end matches the bytes directly.)
const HEADER_END_SIZE := 4

var port := DEFAULT_PORT

var _tcp := TCPServer.new()
# One entry per client: {"peer": StreamPeerTCP, "buf": PackedByteArray}
var _sessions: Array[Dictionary] = []


func start() -> Error:
	port = _configured_port()
	return _tcp.listen(port, "127.0.0.1")


# MEBO_BRIDGE_PORT overrides the port (set on the editor's environment). The
# IDE's E2E tests use it to run scratch editors without touching the real 6010.
static func _configured_port() -> int:
	var env := OS.get_environment("MEBO_BRIDGE_PORT")
	if env.is_valid_int():
		var value := env.to_int()
		if value > 0 and value < 65536:
			return value
	return DEFAULT_PORT


func stop() -> void:
	for session in _sessions:
		(session["peer"] as StreamPeerTCP).disconnect_from_host()
	_sessions.clear()
	_tcp.stop()


## Called every editor frame by plugin.gd.
func poll() -> void:
	while _tcp.is_connection_available():
		var peer := _tcp.take_connection()
		if peer != null:
			peer.set_no_delay(true)
			_sessions.append({"peer": peer, "buf": PackedByteArray()})

	for i in range(_sessions.size() - 1, -1, -1):
		var session := _sessions[i]
		var peer: StreamPeerTCP = session["peer"]
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			_sessions.remove_at(i)
			continue
		var available := peer.get_available_bytes()
		if available <= 0:
			continue
		var chunk := peer.get_data(available)
		if chunk[0] != OK:
			continue
		session["buf"] = (session["buf"] as PackedByteArray) + (chunk[1] as PackedByteArray)
		_drain(session)


## Parse as many complete framed messages as are buffered for one client.
func _drain(session: Dictionary) -> void:
	while true:
		var buf: PackedByteArray = session["buf"]
		var sep := _find_header_end(buf)
		if sep < 0:
			return
		var header := buf.slice(0, sep).get_string_from_ascii()
		var length := _content_length(header)
		var body_start := sep + HEADER_END_SIZE
		if length < 0:
			# Unparseable header; skip past it to resync.
			session["buf"] = buf.slice(body_start)
			continue
		if buf.size() < body_start + length:
			return  # wait for the rest of the body
		var body := buf.slice(body_start, body_start + length).get_string_from_utf8()
		session["buf"] = buf.slice(body_start + length)
		_dispatch(session["peer"], body)


func _find_header_end(buf: PackedByteArray) -> int:
	for i in range(buf.size() - HEADER_END_SIZE + 1):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i
	return -1


func _content_length(header: String) -> int:
	for line in header.split("\r\n"):
		var parts: PackedStringArray = line.split(":", true, 1)
		if parts.size() == 2 and parts[0].strip_edges().to_lower() == "content-length":
			var value := parts[1].strip_edges()
			if value.is_valid_int():
				return value.to_int()
	return -1


func _dispatch(peer: StreamPeerTCP, raw: String) -> void:
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = parsed
	var id: Variant = msg.get("id")
	var method := str(msg.get("method", ""))
	var params: Variant = msg.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		params = {}

	var outcome := _handle(method, params)
	if id == null:
		return  # notification: no response
	var response := {"jsonrpc": "2.0", "id": id}
	if outcome.has("error"):
		response["error"] = outcome["error"]
	else:
		response["result"] = outcome["result"]
	_send(peer, response)


func _send(peer: StreamPeerTCP, message: Dictionary) -> void:
	var body := JSON.stringify(message).to_utf8_buffer()
	var header := ("Content-Length: %d\r\n\r\n" % body.size()).to_utf8_buffer()
	peer.put_data(header + body)


func _ok(result: Variant) -> Dictionary:
	return {"result": result}


func _err(code: int, message: String) -> Dictionary:
	return {"error": {"code": code, "message": message}}


# --- Method dispatch ---------------------------------------------------------

func _handle(method: String, p: Dictionary) -> Dictionary:
	match method:
		"ping":
			return _ok({
				"godotVersion": Engine.get_version_info()["string"],
				"pluginVersion": VERSION,
				# Which project this editor serves — the IDE refuses the
				# connection when it isn't the one it has open.
				"projectRoot": ProjectSettings.globalize_path("res://"),
				"editedScene": _edited_scene_path(),
			})
		"get_scene_tree":
			var root := EditorInterface.get_edited_scene_root()
			if root == null:
				return _ok({"root": null})
			return _ok({"root": _serialize_node(root, root)})
		"get_selection":
			return _get_selection()
		"create_node":
			return _create_node(p)
		"delete_node":
			return _delete_node(p)
		"rename_node":
			return _rename_node(p)
		"set_node_property":
			return _set_node_property(p)
		"attach_script":
			return _attach_script(p)
		"connect_signal":
			return _connect_signal(p)
		"save_scene":
			var err := EditorInterface.save_scene()
			if err != OK:
				return _err(-32000, "save_scene failed (error %d). Is a scene open?" % err)
			return _ok({"ok": true})
		"open_scene":
			var res_path := str(p.get("resPath", ""))
			if not ResourceLoader.exists(res_path):
				return _err(-32000, "Scene not found: %s" % res_path)
			EditorInterface.open_scene_from_path(res_path)
			return _ok({"ok": true})
		"reload_changed_files":
			return _reload_changed_files(p)
		"get_editor_file_info":
			return _get_editor_file_info(p)
		"reload_plugin":
			_schedule_plugin_reload()
			return _ok({"ok": true})
		"capture_screenshot":
			return _capture_screenshot(p)
		"run_project":
			var main_scene := _sync_run_settings()
			if main_scene.is_empty():
				return _err(-32000, "No main scene is set in project.godot (application/run/main_scene). Set it, or use run_current_scene.")
			EditorInterface.play_main_scene()
			_show_game_screen()
			return _ok({"ok": true, "mainScene": main_scene})
		"run_current_scene":
			if EditorInterface.get_edited_scene_root() == null:
				return _err(-32000, "No scene is open in the editor to run.")
			EditorInterface.play_current_scene()
			_show_game_screen()
			return _ok({"ok": true})
		"stop":
			EditorInterface.stop_playing_scene()
			return _ok({"ok": true})
		_:
			return _err(-32601, "Method not found: %s" % method)


# --- Run preparation ---------------------------------------------------------

## The editor caches ProjectSettings in memory and does NOT reload project.godot
## when the IDE changes it on disk (e.g. sets application/run/main_scene through a
## file edit). Without this, play_main_scene() sees no main scene and pops the
## "No main scene has ever been defined" dialog instead of launching. Re-read the
## on-disk value into the live settings, and rescan the filesystem so files the
## IDE created outside the editor are imported before the game loads them.
## Returns the resolved main scene path ("" if none is configured on disk).
func _sync_run_settings() -> String:
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null and not fs.is_scanning():
		fs.scan()
	var cfg := ConfigFile.new()
	if cfg.load("res://project.godot") != OK:
		return str(ProjectSettings.get_setting("application/run/main_scene", ""))
	var main_scene := str(cfg.get_value("application", "run/main_scene", ""))
	if not main_scene.is_empty():
		ProjectSettings.set_setting("application/run/main_scene", main_scene)
	return main_scene


## Godot 4.4+ embeds the running game in the editor's "Game" main screen.
## Switch to it on play so the user (and capture_screenshot's whole-window
## fallback) can actually see the game; harmless no-op on layouts without it.
func _show_game_screen() -> void:
	EditorInterface.set_main_screen_editor("Game")


# --- External change pickup ---------------------------------------------------

## The IDE writes scripts and scenes straight to disk; on its own the editor
## only notices on the next window focus and then prompts instead of reloading.
## Pick the changes up immediately: rescan the filesystem, refresh cached
## resources, reload affected open scenes, and refresh script editor buffers.
##
## Open scenes with unsaved editor changes are NOT reloaded — a silent reload
## would discard work that exists nowhere else; Godot's own conflict prompt
## still covers them on the next focus. Editor APIs newer than this addon's
## 4.4 baseline go through has_method guards so the script still loads there.
func _reload_changed_files(p: Dictionary) -> Dictionary:
	var raw: Variant = p.get("resPaths", [])
	if typeof(raw) != TYPE_ARRAY:
		return _err(-32602, "resPaths must be an array of res:// paths.")
	var res_paths: Array = raw

	var fs := EditorInterface.get_resource_filesystem()
	if fs != null and not fs.is_scanning():
		fs.scan()

	var open_scenes := EditorInterface.get_open_scenes()
	var unsaved := _unsaved_scene_paths()
	var current: Variant = _edited_scene_path()
	var reloaded_scenes: Array[String] = []
	var skipped_unsaved: Array[String] = []
	var refreshed_resources := 0
	var scripts_changed := false

	for path_variant in res_paths:
		var res_path := str(path_variant)
		if res_path.ends_with(".gd") or res_path.ends_with(".cs"):
			scripts_changed = true
		var is_scene := res_path.ends_with(".tscn") or res_path.ends_with(".scn")
		if is_scene and open_scenes.has(res_path):
			if unsaved.has(res_path):
				skipped_unsaved.append(res_path)
			elif FileAccess.file_exists(res_path):
				EditorInterface.reload_scene_from_path(res_path)
				reloaded_scenes.append(res_path)
			continue
		# Not open in a scene tab: refreshing the resource cache is enough
		# (covers scripts, .tres resources, and scenes instanced elsewhere).
		# Deleted files (checkpoint restores) are left to the rescan.
		if FileAccess.file_exists(res_path) and ResourceLoader.has_cached(res_path):
			ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_REPLACE)
			refreshed_resources += 1

	if scripts_changed:
		var script_editor := EditorInterface.get_script_editor()
		# reload_open_files postdates 4.4; without it, buffers refresh on focus.
		if script_editor != null and script_editor.has_method("reload_open_files"):
			script_editor.call("reload_open_files")

	# reload_scene_from_path focuses the reloaded scene's tab; put the user
	# back on the scene they were actually looking at.
	if not reloaded_scenes.is_empty() and typeof(current) == TYPE_STRING:
		EditorInterface.open_scene_from_path(str(current))

	return _ok({
		"ok": true,
		"reloadedScenes": reloaded_scenes,
		"skippedUnsavedScenes": skipped_unsaved,
		"refreshedResources": refreshed_resources,
	})


## The editor's own view of a file, as opposed to the disk's: `indexed` flips
## true only once the filesystem scan has picked the file up, which is how the
## IDE verifies its writes actually landed in the editor without a manual
## reload. `type` is the indexed resource type ("GDScript", "PackedScene", …).
func _get_editor_file_info(p: Dictionary) -> Dictionary:
	var res_path := str(p.get("resPath", ""))
	if res_path.is_empty():
		return _err(-32602, "resPath is required.")
	var fs := EditorInterface.get_resource_filesystem()
	var type := "" if fs == null else fs.get_file_type(res_path)
	return _ok({
		"resPath": res_path,
		"indexed": type != "",
		"type": type,
		"existsOnDisk": FileAccess.file_exists(res_path),
		"scanning": fs != null and fs.is_scanning(),
	})


## Re-instantiate this plugin so freshly written addon files take effect (the
## IDE calls this right after updating them). The work runs on a self-freeing
## node from plugin_reloader.gd parked in the editor UI: the tree keeps it
## alive through the plugin teardown, whereas a deferred Callable on a
## transient RefCounted is silently dropped before it runs (verified on 4.7).
func _schedule_plugin_reload() -> void:
	var runner_script: Script = load("res://addons/godotai_bridge/plugin_reloader.gd")
	var runner: Node = runner_script.new()
	runner.name = "MeboBridgePluginReloader"
	EditorInterface.get_base_control().add_child(runner)


## get_unsaved_scenes postdates the 4.4 baseline; without it, report none
## (changed open scenes are then reloaded unconditionally).
func _unsaved_scene_paths() -> PackedStringArray:
	if not EditorInterface.has_method("get_unsaved_scenes"):
		return PackedStringArray()
	var result: Variant = EditorInterface.call("get_unsaved_scenes")
	return result if result is PackedStringArray else PackedStringArray()


## What the user has selected in the editor right now: scene-tree nodes (paths
## relative to the edited scene root, "." = root) and FileSystem-dock items
## (res:// paths; directories end with "/"). Read-only; the IDE polls this to
## suggest chat references for whatever the user clicked.
func _get_selection() -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	var node_paths: Array[String] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		if root != null and (node == root or root.is_ancestor_of(node)):
			node_paths.append("." if node == root else str(root.get_path_to(node)))
	return _ok({
		"nodePaths": node_paths,
		"assetPaths": Array(EditorInterface.get_selected_paths()),
		"editedScene": _edited_scene_path(),
	})


# --- Scene operations --------------------------------------------------------

func _edited_scene_path() -> Variant:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or root.scene_file_path.is_empty():
		return null
	return root.scene_file_path


## Resolve a request path ("." or "" = scene root; otherwise relative to it).
func _get_node(path: String) -> Node:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	if path == "." or path.is_empty():
		return root
	return root.get_node_or_null(NodePath(path))


## Key properties surfaced in get_scene_tree, encoded with var_to_str.
const SURFACED_PROPERTIES: Array[String] = [
	"position", "rotation", "scale", "visible", "text", "size",
]


func _serialize_node(node: Node, root: Node) -> Dictionary:
	var script_path: Variant = null
	var script: Variant = node.get_script()
	if script != null and not (script as Script).resource_path.is_empty():
		script_path = (script as Script).resource_path

	var properties := {}
	for prop in SURFACED_PROPERTIES:
		if prop in node:
			properties[prop] = var_to_str(node.get(prop))

	var children := []
	for child in node.get_children():
		children.append(_serialize_node(child, root))

	return {
		"name": str(node.name),
		"type": node.get_class(),
		"path": "." if node == root else str(root.get_path_to(node)),
		"scriptResPath": script_path,
		"properties": properties,
		"children": children,
	}


func _create_node(p: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32000, "No scene is open in the editor.")
	var parent := _get_node(str(p.get("parentPath", ".")))
	if parent == null:
		return _err(-32000, "Parent node not found: %s" % str(p.get("parentPath")))
	var type := str(p.get("type", ""))
	if not ClassDB.class_exists(type) or not ClassDB.can_instantiate(type):
		return _err(-32000, "Cannot instantiate node type: %s" % type)
	var instance: Variant = ClassDB.instantiate(type)
	if not (instance is Node):
		return _err(-32000, "%s is not a Node type." % type)
	var node := instance as Node
	node.name = str(p.get("name", type))
	parent.add_child(node)
	node.owner = root  # required for the node to persist in the saved scene
	_mark_unsaved()
	return _ok({"path": str(root.get_path_to(node))})


func _delete_node(p: Dictionary) -> Dictionary:
	var node := _get_node(str(p.get("path", "")))
	if node == null:
		return _err(-32000, "Node not found: %s" % str(p.get("path")))
	if node == EditorInterface.get_edited_scene_root():
		return _err(-32000, "Refusing to delete the scene root.")
	node.get_parent().remove_child(node)
	node.queue_free()
	_mark_unsaved()
	return _ok({"ok": true})


func _rename_node(p: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	var node := _get_node(str(p.get("path", "")))
	if node == null:
		return _err(-32000, "Node not found: %s" % str(p.get("path")))
	node.name = str(p.get("newName", node.name))
	_mark_unsaved()
	return _ok({"path": "." if node == root else str(root.get_path_to(node))})


func _set_node_property(p: Dictionary) -> Dictionary:
	var node := _get_node(str(p.get("path", "")))
	if node == null:
		return _err(-32000, "Node not found: %s" % str(p.get("path")))
	var property := str(p.get("property", ""))
	if not (property in node):
		return _err(-32000, "Node %s has no property \"%s\"." % [node.name, property])
	node.set(property, _decode_value(p.get("value")))
	_mark_unsaved()
	return _ok({"ok": true})


## Strings get two extra interpretations: res:// paths of existing resources
## are loaded, and Godot literals ("Vector2(1, 2)") go through str_to_var.
func _decode_value(value: Variant) -> Variant:
	if typeof(value) != TYPE_STRING:
		return value
	var text := value as String
	if text.begins_with("res://") and ResourceLoader.exists(text):
		return load(text)
	var parsed: Variant = str_to_var(text)
	if parsed != null:
		return parsed
	return text


func _attach_script(p: Dictionary) -> Dictionary:
	var node := _get_node(str(p.get("path", "")))
	if node == null:
		return _err(-32000, "Node not found: %s" % str(p.get("path")))
	var script_path := str(p.get("scriptResPath", ""))
	if not ResourceLoader.exists(script_path):
		return _err(-32000, "Script not found: %s" % script_path)
	var script: Variant = load(script_path)
	if not (script is Script):
		return _err(-32000, "%s is not a script." % script_path)
	node.set_script(script)
	_mark_unsaved()
	return _ok({"ok": true})


func _connect_signal(p: Dictionary) -> Dictionary:
	var from_node := _get_node(str(p.get("fromPath", "")))
	if from_node == null:
		return _err(-32000, "Node not found: %s" % str(p.get("fromPath")))
	var to_node := _get_node(str(p.get("toPath", "")))
	if to_node == null:
		return _err(-32000, "Node not found: %s" % str(p.get("toPath")))
	var signal_name := str(p.get("signal", ""))
	if not from_node.has_signal(signal_name):
		return _err(-32000, "%s has no signal \"%s\"." % [from_node.name, signal_name])
	var callable := Callable(to_node, str(p.get("method", "")))
	if from_node.is_connected(signal_name, callable):
		return _err(-32000, "Signal already connected.")
	# CONNECT_PERSIST makes the connection part of the scene when saved.
	from_node.connect(signal_name, callable, CONNECT_PERSIST)
	_mark_unsaved()
	return _ok({"ok": true})


## Longest screenshot side sent over the wire; larger viewports are downscaled.
const MAX_SCREENSHOT_DIM := 1280


func _capture_screenshot(p: Dictionary) -> Dictionary:
	var viewport: Viewport
	if str(p.get("viewport", "2d")) == "3d":
		viewport = EditorInterface.get_editor_viewport_3d(0)
	else:
		viewport = EditorInterface.get_editor_viewport_2d()
	var image: Image = null
	if viewport != null:
		image = viewport.get_texture().get_image()
	# An editor viewport that is not the active main screen doesn't render and
	# yields a degenerate (e.g. 2x2) texture. Fall back to the whole editor
	# window, which is always rendered and still shows the scene.
	if image == null or image.is_empty() or maxi(image.get_width(), image.get_height()) < 32:
		var base := EditorInterface.get_base_control()
		if base != null and base.get_viewport() != null:
			image = base.get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		return _err(-32000, "Could not capture the editor viewport.")
	var w := image.get_width()
	var h := image.get_height()
	if maxi(w, h) > MAX_SCREENSHOT_DIM:
		var factor := float(MAX_SCREENSHOT_DIM) / float(maxi(w, h))
		image.resize(int(w * factor), int(h * factor), Image.INTERPOLATE_LANCZOS)
	return _ok({
		"imageBase64": Marshalls.raw_to_base64(image.save_png_to_buffer()),
		"width": image.get_width(),
		"height": image.get_height(),
		"mediaType": "image/png",
	})


func _mark_unsaved() -> void:
	EditorInterface.mark_scene_as_unsaved()
