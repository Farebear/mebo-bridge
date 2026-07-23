@tool
extends Node

## Applies an addon update to the running editor: disables the mebo bridge
## plugin, recompiles its scripts from what's now on disk, and re-enables it.
## Lives in its own file so the reload never recompiles the script that is
## executing it; changes to THIS file only take effect after an editor restart.
## bridge_server.gd parks one instance in the editor's base control when the
## IDE requests reload_plugin; the node frees itself when done.

const PLUGIN_NAME := "godotai_bridge"
# bridge_server.gd first: plugin.gd's preload re-binds to it when plugin.gd
# recompiles.
const PLUGIN_SCRIPTS: Array[String] = [
	"res://addons/godotai_bridge/bridge_server.gd",
	"res://addons/godotai_bridge/plugin.gd",
]


func _ready() -> void:
	# Deferred so the reload_plugin response leaves on the socket before the
	# plugin (and with it the server) is torn down.
	_run.call_deferred()


func _run() -> void:
	EditorInterface.set_plugin_enabled(PLUGIN_NAME, false)
	# Recompile from disk while no instance is alive: a cached GDScript keeps
	# its old bytecode (and plugin.gd's preload keeps the old bridge_server
	# object) even after a CACHE_MODE_REPLACE load, so re-enabling without
	# this would just restart the old version.
	for res_path in PLUGIN_SCRIPTS:
		var script := load(res_path) as Script
		if script != null:
			script.source_code = FileAccess.get_file_as_string(res_path)
			script.reload()
	EditorInterface.set_plugin_enabled(PLUGIN_NAME, true)
	queue_free()
