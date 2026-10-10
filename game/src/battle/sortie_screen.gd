class_name SortieScreen
extends RefCounted
## 出场选择 (builder 0x418597 → dialog 236 选择武将 0x45e6b3, Sortie66): the candidates are the forced persons
## (protagonist first, then the forced list) followed by the other army members in person order, without the persons
## of the flag list 0x4b0a04 (`excluded`); at most `maxn` (≤ 20) sortie. Returns the chosen ids, [] when the player
## cancels (取消 empties the list). Autoplay takes the forced ones and fills up in person order without a window.


static func choose(ui: GameUI, _stage: Node, maxn: int, forced: Array[int], excluded: Array[int]) -> Array[int]:
	var cands: Array[int] = []
	for f in forced:
		if not cands.has(f):
			cands.append(f)
	var nforced := cands.size()
	for pid in 0x400:                     # members: person +0x2a ≠ 0xff (0x42ac58)
		if Mem.r8(Mem.person_addr(pid) + 0x2a) != 0xff and not excluded.has(pid) and not cands.has(pid):
			cands.append(pid)
	if maxn <= 0 or maxn > 20:
		maxn = 20
	if Game.autoplay:
		var out: Array[int] = []
		out.assign(cands.slice(0, maxi(maxn, nforced)))
		return out
	return await Sortie66.run(ui, cands, nforced, maxn)
