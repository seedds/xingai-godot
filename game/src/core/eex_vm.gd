class_name EexVM
extends RefCounted
## Interpreter for EEX scenario scripts (JSON produced by tools/eex.py), following the 6.6 engine's execution model
## (docs/eex.md §4; select 0x4100a1, run_block 0x4105ff, run_child 0x410857, block_end 0x410738, dispatcher
## 0x4109e6, goto 0x416c41, manager 0x4180c1 / 0x41811f):
##  * poll(): when no body is running, evaluate every section of the current scene; the LAST section whose
##    condition list qualifies runs (an instruction that returns 0 vetoes; other results don't).
##  * Bodies are flat lists; nesting is tracked at run time. IF pushes a level, END runs block_end for the level.
##    Each level keeps its own "last test result" (ELSE), next-scene and end-of-file marks, as run_block's locals.
##  * block_end(depth): next_scene, or the body END of a one-section scene → scene + 1 (status 3, ends the body);
##    else, at depth > 0 or in a multi-section scene → continue (0) unless the file ended (goto_scenario) → the
##    file is finished (4). Status 3 / 4 from an inner level end the whole body.
##  * goto (0x76): jump, then leave the current level iff the target is at/before the latest IF executed
##    ([0x500ab0]) or the target is at/after the latest block end ([0x500ab4]) while the goto itself is before it.
##    At depth 0 it never leaves.
## Opcodes are dispatched to `host.op_<name>(ins)`; tests return bool; handlers may await.

signal file_finished

var data: Dictionary
var host: Object
var name := ""
var scene := 0
var running := false
var active := false          # reader +0x28: false once the file has finished
var abort := false
var trace := false
var last_section := -1
var next_op := -1            # opcode after the one being executed (-1 at the end of a body)
var _warned: Dictionary = {}
var _last_if := -1           # [0x500ab0]: offset of the latest IF opcode executed
var _block_end := -1         # [0x500ab4]: end offset of the latest block entered or skipped (or the body)


func load_script(file: String) -> bool:
	var d: Variant = Assets.json("scripts/%s.json" % file, false)
	if d == null:
		push_error("script not found: " + file)
		return false
	data = d
	name = file
	trace = OS.get_environment("WG_TRACE_OPS") != ""
	scene = 0
	active = true
	running = false
	return true


func scene_count() -> int:
	return data.get("scenes", []).size()


func sections(sc: int) -> Array:
	var scs: Array = data["scenes"]
	if sc < 0 or sc >= scs.size():
		return []
	return scs[sc]["sections"]


static var op_stats: Dictionary = {}       # WG_OPSTATS: executed ops by name (printed when a file ends)
static var _stats_on := OS.get_environment("WG_OPSTATS") != ""


## Ops that only read or write the emulated memory (no window, sound, animation or wait): a section run made of
## these that changed no memory leaves everything as it was (BattleStage.checkpoint stops repeating it).
const PURE_OPS := {"end": 1, "if": 1, "comment": 1, "else": 1, "goto": 1, "int_var_op": 1, "set_flag": 1,
		"data_transfer": 1, "set_attr": 1, "copy_person_word": 1}
const PURE_EXT := {4: 1, 5: 1, 6: 1, 7: 1, 9: 1, 10: 1, 23: 1, 24: 1, 26: 1, 35: 1, 36: 1}
var impure := false          # an op outside PURE_OPS / test_* ran since the flag was cleared
var _handlers: Dictionary = {}


func _call(ins: Dictionary) -> Variant:
	var n: String = ins["name"]
	if _stats_on:
		var key := n
		if int(ins["op"]) == 0x72:
			key += ":%d" % int(ins.get("ext", {}).get("sub", -1))
		op_stats[key] = int(op_stats.get(key, 0)) + 1
	if not impure and not PURE_OPS.has(n) and not n.begins_with("test_"):
		if n != "ext_command" or not PURE_EXT.has(int(ins.get("ext", {}).get("sub", -1))):
			impure = true
	var h: Variant = _handlers.get(n)
	if h == null:
		var m := "op_" + n
		h = Callable(host, m) if host.has_method(m) else false
		_handlers[n] = h
	if h is Callable:
		return await (h as Callable).call(ins)
	if not _warned.has(n):
		_warned[n] = true
		push_warning("EEX unimplemented op %s (0x%02x) args=%s in %s" % [n, int(ins["op"]), ins["args"], name])
	return null


## Result of a test position (condition list or IF): 1 true, 0 false. Handlers that return nothing count as 1 ("ok"),
## as the original's non-test handlers return status 1.
func _test(ins: Dictionary) -> int:
	var op := int(ins["op"])
	if op == 2:
		return 1
	var r: Variant = await _call(ins)
	if r == null:
		return 1
	return 1 if bool(r) else 0


## Condition list (0x4100a1): qualifies if no instruction returned 0.
func check_conditions(sec: Dictionary) -> bool:
	for ins in sec.get("conditions", []):
		if int(ins["op"]) == 0:
			break
		var r := await _test(ins)
		if r == 0:
			return false
	return true


## One poll of the current scene. Returns true if a body ran.
func poll() -> bool:
	if not active or running:
		return false
	var secs := sections(scene)
	if secs.is_empty():
		_advance_scene()
		return false
	var chosen := -1
	for k in secs.size():
		if await check_conditions(secs[k]):
			chosen = k
	if chosen < 0 or not active:
		return false
	await run_section(chosen)
	return true


## Keep polling until the scene loop is idle (no section qualifies) or the file ends.
func poll_all(max_rounds := 1000) -> void:
	var n := 0
	while active and n < max_rounds:
		var ran := await poll()
		if not ran:
			break
		n += 1


func run_section(k: int) -> void:
	var secs := sections(scene)
	running = true
	last_section = k
	if OS.get_environment("WG_TRACE_SEC") != "":
		var t := ""
		if host.has_method("trace_info"):
			t = host.trace_info()
		print("  [sec %s %d.%d] %s %s" % [name, scene, k, secs[k].get("title", ""), t])
	abort = false
	_block_end = int(secs[k].get("body_end", -1))
	var r := await _run(secs[k]["body"], scene, k, 0, secs.size())
	running = false
	if r == 4 and not abort:
		_finish_file()


func _advance_scene() -> void:
	scene += 1
	if scene >= scene_count():
		_finish_file()


func _finish_file() -> void:
	if _stats_on:
		print("OPSTATS %s %s" % [name, JSON.stringify(op_stats)])
	active = false
	file_finished.emit()


func _body_of(sc: int, sec: int) -> Array:
	var secs := sections(sc)
	if sec < 0 or sec >= secs.size():
		return []
	return secs[sec]["body"]


## block_end 0x410738 for the level that just reached its END: 3 = scene advanced (ends the body), 4 = file finished,
## 0 = continue.
func _block_end_status(depth: int, end_file: bool, next_scene: bool, nsections: int) -> int:
	if next_scene or (depth == 0 and nsections == 1):
		scene += 1
		if scene < scene_count():
			return 3
	elif scene < scene_count() and not end_file:
		return 0
	active = false
	return 4


## Goto verdict (0x416c41): true = leave the current level.
func _goto_leaves(ins: Dictionary, t: Dictionary) -> bool:
	if not t.has("off") or not ins.has("off"):
		return true      # JSON without offsets: the wg2025 rule (always leave)
	var target := int(t["off"])
	if target <= _last_if:
		return true
	if target < _block_end:
		return false
	return int(ins["off"]) + 2 < _block_end


## Run a section body (run_child(1, 0) → run_block). Returns the status of the body: 1 done, 3 scene advanced,
## 4 file finished, 5 aborted.
func _run(body: Array, sc: int, sec: int, start: int, nsections: int) -> int:
	var pc := start
	var depth := 0
	var last: Array[int] = [1]         # run_block local_c per level: result of the latest IF test (ELSE)
	var ns: Array[bool] = [false]      # local_18: next_scene seen at this level
	var ef: Array[bool] = [false]      # local_10: goto_scenario seen at this level
	var steps := 0
	while true:
		if abort or host == null or not is_instance_valid(host):
			return 5
		if pc >= body.size():
			return 1      # ran past the body (only the casino loops of R_110…, docs/eex.md §4.2): status 5 → 1
		var ins: Dictionary = body[pc]
		var op := int(ins["op"])
		steps += 1
		if steps % 4000 == 0:
			await host.get_tree().process_frame
		if trace:
			print("[%s %d.%d #%d d%d] %s %s" % [name, sc, sec, pc, depth, ins["name"], ins["args"]])
		match op:
			0:    # END → block_end for this level
				var st := _block_end_status(depth, ef[depth], ns[depth], nsections)
				if st != 0 or depth == 0:
					return st if st != 0 else 1
				depth -= 1
				last.pop_back()
				ns.pop_back()
				ef.pop_back()
				pc += 1
				continue
			1:    # IF <cond> {block}
				_last_if = int(ins.get("off", -1))
				var c: Dictionary = ins["cond"]
				var cop := int(c["op"])
				if cop == 0x76:
					# a goto as the condition: the jump happens; leaving pops this level (not in the shipped files)
					var tg: Dictionary = c.get("target", {})
					if tg.is_empty():
						pc += 1
						continue
					if _goto_leaves(c, tg) and depth > 0:
						depth -= 1
						last.pop_back()
						ns.pop_back()
						ef.pop_back()
					if int(tg["scene"]) != sc or int(tg["section"]) != sec:
						sc = int(tg["scene"])
						sec = int(tg["section"])
						body = _body_of(sc, sec)
					pc = int(tg["index"])
					continue
				var take := false
				if cop == 3:
					take = last[depth] == 0          # ELSE (status 6) does not change `last`
				else:
					next_op = -1
					var r := await _test(c)
					if abort:
						return 5
					last[depth] = r
					take = r == 1
				_block_end = int(ins.get("end_off", _block_end))
				if take:
					depth += 1
					last.append(1)
					ns.append(false)
					ef.append(false)
					pc += 1
				else:
					pc = int(ins["end"])
				continue
			3:    # ELSE outside an IF condition: status 6 → the block (and body) returns 1
				return 1
			0x0c: # exit_section: status 8 → 5
				await _call(ins)
				return 5
			0x0d: # next_scene: status 7, takes effect at this level's END
				await _call(ins)
				ns[depth] = true
				pc += 1
				continue
			0x11: # goto_scenario: status 9, takes effect at this level's END
				await _call(ins)
				ef[depth] = true
				pc += 1
				continue
			0x76: # goto
				var t: Dictionary = ins.get("target", {})
				if t.is_empty():
					pc += 1
					continue
				if _goto_leaves(ins, t) and depth > 0:
					depth -= 1
					last.pop_back()
					ns.pop_back()
					ef.pop_back()
				if int(t["scene"]) != sc or int(t["section"]) != sec:
					sc = int(t["scene"])
					sec = int(t["section"])
					body = _body_of(sc, sec)
				pc = int(t["index"])
				continue
		next_op = int(body[pc + 1]["op"]) if pc + 1 < body.size() else -1
		await _call(ins)
		pc += 1
	return 1
