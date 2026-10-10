class_name ItemInfo66
extends Dlg66
## Item details, dialog 167 (0x40be92 → 0x46d098(…, 0xa7), class vtable 0x486458; opened by the right button on a list
## row, 0x467721, or on a worn item, 0x46a89e): the 32×32 icon 0x415, the name, Lv / Exp with the exp bar 0x565 (the
## 升级 button 0x42f is not ported, [G] shown disabled), 属性 0x3ff, 价格 0x3fa, the 效果 group (E 0x401, A 0x5af),
## the description page 0x42e (items.json `description`, Imsg) and 可装备的部队: the class families that can wear it
## ([G] listed as text: weapons / armour by the classes' equip flags, 0x41c60f; accessories by the family byte +0x17
## and its groups, 0x420e83).

var iid := 0
var lvl := 0
var xp := 0


static func show_item(owner: Control, item: int, level: int, exp: int) -> void:
	if Game.autoplay or item < 0 or item >= 0xff:
		return
	var d := ItemInfo66.new()
	d.iid = item
	d.lvl = level
	d.xp = exp
	d.build()
	owner.add_child(d)
	await d.closed
	d.queue_free()


func build() -> void:
	setup(ItemText66.name(iid), 352, 267)
	var ic := add_pic(0x415, 2, 8, 23, 23)
	ic["tex"] = ItemText66.large_icon(iid)
	add_static(0x3f8, 28, 10, 141, 8, ItemText66.name(iid))
	var equip := ItemText66.category(iid) < 2
	if equip:
		add_static(0x5ab, 28, 22, 10, 8, "Lv")
		add_static(0x5ac, 40, 22, 13, 8, "%d" % lvl)
		add_static(0x5ad, 54, 22, 15, 8, "Exp")
		var bar := add_bar(0x565, 69, 22, 65, 8)
		var mx := 200 if ItemText66.is_treasure(iid) else 100
		bar["on"] = true
		bar["value"] = mx if xp == 0xff else xp
		bar["maxv"] = mx
		bar["label"] = "MAX" if xp == 0xff else "%d/%d" % [xp, mx]
	var up := add_button(0x42f, 138, 19, 32, 13, "升级")
	up["enabled"] = false
	add_group(2, 34, 65, 44, "")
	add_static(null, 7, 46, 24, 8, "属性∶")
	add_static(0x3ff, 25, 46, 32, 8, ItemText66.kind_name(iid), 1)
	add_static(null, 7, 66, 24, 8, "价格∶")
	var pr := ItemText66.sell_price(iid, lvl)
	add_static(0x3fa, 25, 66, 32, 8, "---" if pr < 0 else "%d" % ItemText66.buy_price(iid), 2)
	add_group(69, 34, 101, 44, "效果")
	add_static(0x401, 74, 46, 80, 18, PersonPanel66.bonus_text(iid, lvl) if equip else ItemText66.effect_name(iid))
	add_static(0x5af, 74, 66, 94, 8, ItemText66.special_text(iid, lvl))
	add_group(173, 6, 177, 240, "可装备的部队")
	add_static(null, 180, 20, 164, 220, _families(), 0, false)
	add_tab(0x405, 2, 80, 168, 165, ["说明"])
	add_static(0x42e, 5, 96, 161, 146, str(ItemText66.it(iid).get("description", "")).replace("\r", "").strip_edges(), 0, true)
	add_button(2, 238, 248, 49, 17, "确认")


func _families() -> String:
	var it := ItemText66.it(iid)
	var names := []
	var fams: Array = Game.families_db
	var cat := ItemText66.category(iid)
	if cat >= 3:
		return ""
	for f in fams.size():
		var ok := false
		if cat < 2:
			var t := int(it.get("type", 0))
			for c in Game.classes_db:
				if int(c.get("family", -1)) == f:
					var eq: Array = c.get("equip_raw", [])
					if t < eq.size() and int(eq[t]) != 0:
						ok = true
						break
		else:
			var want := int(it.get("growth", 0xff))
			ok = want == 0xff or want == f or want in Person.ACC_GROUPS.get(f, [])
		if ok:
			names.append(str(fams[f].get("name", "")))
	return "、".join(names)


func _on_command(id: Variant) -> void:
	if id == 2:
		close(null)
