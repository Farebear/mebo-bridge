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

var shader_errors: Array[Dictionary] = []


func _log_error(_function: String, _file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
	if error_type != ERROR_TYPE_SHADER:
		return
	var message := rationale if not rationale.is_empty() else code
	shader_errors.append({"line": line, "message": message})
