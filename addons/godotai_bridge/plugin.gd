@tool
extends EditorPlugin

## Entry point for the mebo bridge addon. Owns the TCP server's lifecycle
## and pumps it from the editor's process loop; all protocol logic lives in
## bridge_server.gd.

const BridgeServer := preload("bridge_server.gd")

var _server: BridgeServer = null


func _enter_tree() -> void:
	_server = BridgeServer.new()
	var err := _server.start()
	if err != OK:
		push_error("mebo bridge: cannot listen on 127.0.0.1:%d (error %d). Is another instance running?" % [_server.port, err])
		_server = null
		return
	print("mebo bridge listening on 127.0.0.1:%d" % _server.port)
	set_process(true)


func _process(_delta: float) -> void:
	if _server != null:
		_server.poll()


func _exit_tree() -> void:
	if _server != null:
		_server.stop()
		_server = null
