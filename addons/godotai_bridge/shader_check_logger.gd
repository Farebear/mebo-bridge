@tool
extends Logger

## Captures shader compile errors while check_shader force-compiles a Shader.
## Loaded dynamically by bridge_server.gd ONLY after a
## ClassDB.class_exists("Logger") guard: Logger (and ScriptBacktrace) postdate
## the addon's 4.4 baseline, so referencing them in bridge_server.gd itself
## would be a parse error that bricks the whole addon on older editors.
##
## Godot reports shader parse errors as ERROR_TYPE_SHADER with the shader
## source line in `line`; the follow-up generic "Shader compilation failed."
## (ERROR_TYPE_ERROR) is noise about the same failure and is dropped here.
##
## While `capture_generic` is on (only during a .tres/.res shader resource
## load), non-shader errors are collected too: a VisualShader graph with an
## invalid or dangling connection loads "successfully" — the bad connection is
## dropped with only a printed error — so this is the one window where those
## problems are observable at all.

var shader_errors: Array[Dictionary] = []
var capture_generic := false
var generic_errors: Array[String] = []


func _log_error(_function: String, _file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
	var message := rationale if not rationale.is_empty() else code
	if error_type == ERROR_TYPE_SHADER:
		shader_errors.append({"line": line, "message": message})
	elif capture_generic and error_type != ERROR_TYPE_WARNING:
		generic_errors.append(message)
