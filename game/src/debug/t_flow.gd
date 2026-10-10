extends Node
## Smoke test: run scenarios from WG_FROM to WG_TO in autoplay mode, report unimplemented ops.
func run() -> void:
	var main = Game.main
	print("main: ", main)
