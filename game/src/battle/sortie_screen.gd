class_name SortieScreen
extends RefCounted
## 出场选择 (0x45e6b3): pick up to `maxn` army members (≤ 20 player slots); the forced ones (protagonist first, then the
## forced list) are always included, the persons of the flag list (0x4b0a04) are not offered.


static func choose(ui: GameUI, _stage: Node, maxn: int, forced: Array[int], excluded: Array[int]) -> Array[int]:
	var members: Array[int] = []
	for pid in Game.party_ids():
		if not excluded.has(pid):
			members.append(pid)
	var chosen: Array[int] = []
	for f in forced:
		if not chosen.has(f):
			chosen.append(f)
	if maxn <= 0 or maxn > 20:
		maxn = 20
	if members.size() <= maxn or Game.autoplay:
		for m in members:
			if chosen.size() >= maxn:
				break
			if not chosen.has(m):
				chosen.append(m)
		return chosen
	while true:
		var labels := []
		for m in members:
			var p := Game.person(m)
			var mark := "●" if chosen.has(m) else "○"
			labels.append("%s %s　%s Lv%d" % [mark, p.name, p.class_name_str(), p.level])
		labels.append("【出征】（%d/%d）" % [chosen.size(), maxn])
		var i := await ui.menu.choose(labels, Vector2(-1, -1), false, "出场武将选择", [], 260)
		if i == labels.size() - 1:
			if not chosen.is_empty():
				return chosen
			continue
		var pid := members[i]
		if chosen.has(pid):
			if not forced.has(pid):
				chosen.erase(pid)
		elif chosen.size() < maxn:
			chosen.append(pid)
	return chosen
