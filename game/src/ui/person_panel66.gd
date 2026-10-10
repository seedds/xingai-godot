class_name PersonPanel66
extends RefCounted
## The person part of the 买进 (327) and 装备 (328) dialogs (class at dialog object +0x280 / +0x6a0, vtables 0x487278 /
## 0x487400): the member combo box 0x44a (all persons whose +0x2a ≠ 0xff, in id order, 0x469c60), 上一武将 / 下一武将
## (0x403 / 0x404, 0x469adc), the face 0x434, Lv 0x471, the eight values 0x4b0..0x4b7 (攻击 防御 精神 爆发 士气 HP MP
## 移动, getters 0x40715a.. table 0x430000) with the change an item would make in 0x4b8..0x4bf (0x468eb5 →
## 0x415507 / 0x4693cd: "+n", "n" or empty), and the weapon / armour / accessory boxes (0x46942a: "武器∶ %s", 32×32
## icon, Lv, Exp bar, the bonus text E and the treasure text B), the 专属 / 套装 skills text 0x5dc (0x477249) and, in
## 328, the 特技 list box 0x4d3 (0x401126).

const STAT_IDS := [0x4b0, 0x4b1, 0x4b2, 0x4b3, 0x4b4, 0x4b5, 0x4b6, 0x4b7]   # 攻 防 精 爆 士 HP MP 移
const STAT_LABELS := ["攻击", "防御", "精神", "爆发", "士气", "HP", "MP", "移动"]
const SLOT_TITLES := ["武器∶ %s", "护具∶ %s", "辅助∶ %s"]                   # 0x486cd0 / 0x486ce0 / 0x486cf0
const SKILL_NAMES := 0x4cc600                                                # 特效 names, 16 bytes each

var d: Dlg66
var pids: Array[int] = []
var pid := -1
var has_skills := false
var enabled := true


## Build the controls at the template positions of `lay` (dialog units):
## combo [x,y,w], lv_label / lv [x,y,w,h], face, cls, stat_label_x, stat_x, stat_w, plus_x, plus_w, stat_ys[8],
## slots: [{title, icon, lvl_lbl, lvl, exp_lbl, bar, e, b, frame}] (x,y,w,h each), desc, skills (or null),
## prev, next.
func build(dlg: Dlg66, lay: Dictionary) -> void:
	d = dlg
	for pid0 in 0x400:
		if Mem.r8(Mem.person_addr(pid0) + 0x2a) != 0xff:
			pids.append(pid0)
	var names := []
	for p in pids:
		names.append(TextExpand.display_name(p))
	var c: Array = lay["combo"]
	d.add_combo(0x44a, c[0], c[1], c[2], 110, names)
	var a: Array = lay["face"]
	d.add_pic(0x434, a[0], a[1], a[2], a[3])["bg"] = Color.BLACK      # Face.e5 drawn with mode 0x60: key → black
	a = lay["lv_label"]
	d.add_static(null, a[0], a[1], a[2], a[3], "Lv")
	a = lay["lv"]
	d.add_static(0x471, a[0], a[1], a[2], a[3], "", 2)
	a = lay["cls"]
	d.add_static(0x5db, a[0], a[1], a[2], a[3], "", 1, true)
	var ys: Array = lay["stat_ys"]
	for k in 8:
		# template order of the rows: HP, MP, 攻击, 防御, 精神, 爆发, 士气, 移动
		var row: int = [5, 6, 0, 1, 2, 3, 4, 7].find(k)
		var y: float = ys[row]
		d.add_static(null, lay["stat_label_x"], y, 25, 8, STAT_LABELS[k])
		d.add_static(STAT_IDS[k], lay["stat_x"], y, lay["stat_w"], 10, "", 2, true)
		d.add_static(STAT_IDS[k] + 8, lay["plus_x"], y, lay["plus_w"], 10, "", 2, true)
	for s in 3:
		var sl: Dictionary = lay["slots"][s]
		a = sl["frame"]
		d.add_group(a[0], a[1] - 4, a[2], a[3] + 4, "")
		a = sl["title"]
		d.add_static([0x56f, 0x572, 0x575][s], a[0], a[1], a[2], a[3], "")
		a = sl["icon"]
		d.add_pic([0x582, 0x583, 0x584][s], a[0], a[1], a[2], a[3])
		if s < 2:
			a = sl["lvl_lbl"]
			d.add_static([0x58a, 0x58c][s], a[0], a[1], a[2], a[3], "")
			a = sl["lvl"]
			d.add_static([0x570, 0x573][s], a[0], a[1], a[2], a[3], "")
			a = sl["exp_lbl"]
			d.add_static([0x58b, 0x58d][s], a[0], a[1], a[2], a[3], "")
			a = sl["bar"]
			d.add_bar([0x58e, 0x58f][s], a[0], a[1], a[2], a[3])
			a = sl["e"]
			d.add_static([0x579, 0x578][s], a[0], a[1], a[2], a[3], "")
		a = sl["b"]
		d.add_static([0x588, 0x589, 0x57a][s], a[0], a[1], a[2], a[3], "")
	a = lay["desc"]
	d.add_static(0x5dc, a[0], a[1], a[2], a[3], "", 0, true)
	if lay.get("skills") != null:
		has_skills = true
		a = lay["skills"]
		d.add_listbox(0x4d3, a[0], a[1], a[2], a[3])
	a = lay["prev"]
	d.add_button(0x403, a[0], a[1], a[2], a[3], "上一武将")
	a = lay["next"]
	d.add_button(0x404, a[0], a[1], a[2], a[3], "下一武将")
	if not pids.is_empty():
		select(0)


func person() -> Person:
	return Game.person(pid) if pid >= 0 else null


## Combo selection (0x469ecb with CBN_SELCHANGE): the person, prev / next buttons, face (Face.e5 with key → black,
## 0x4789d6 mode 0x60), the three slot boxes, the 特技 list.
func select(i: int) -> void:
	if i < 0 or i >= pids.size():
		return
	d.ctrl(0x44a)["sel"] = i
	pid = pids[i]
	d.enable(0x403, i > 0 and enabled)
	d.enable(0x404, i < pids.size() - 1 and enabled)
	d.ctrl(0x434)["tex"] = Game.person_face(pid)
	for s in 3:
		refresh_slot(s)
	if has_skills:
		_fill_skills()
	preview({})


## 0x469adc: one step through the combo box.
func step(delta: int) -> void:
	var i := clampi(int(d.ctrl(0x44a)["sel"]) + delta, 0, pids.size() - 1)
	if i != int(d.ctrl(0x44a)["sel"]):
		select(i)


## 0x4698dd: the whole panel enabled (buy dialog: only in the 武器店 tab).
func set_enabled(on: bool) -> void:
	enabled = on
	for id in [0x44a, 0x403, 0x404, 0x434, 0x471, 0x5db, 0x5dc] + STAT_IDS:
		d.enable(id, on)
	if on:
		var i := int(d.ctrl(0x44a)["sel"])
		d.enable(0x403, i > 0)
		d.enable(0x404, i < pids.size() - 1)


## 0x46942a(slot).
func refresh_slot(s: int) -> void:
	var p := person()
	if p == null:
		return
	var b := p.base + 0x2e + 3 * s
	var iid := Mem.r8(b)
	var lvl := Mem.r8(b + 1)
	var xp := Mem.r8(b + 2)
	var have := iid != 0xff
	d.set_text([0x56f, 0x572, 0x575][s], SLOT_TITLES[s] % (ItemText66.name(iid) if have else ""))
	d.ctrl([0x582, 0x583, 0x584][s])["tex"] = ItemText66.large_icon(iid) if have else null
	if s < 2:
		d.set_text([0x58a, 0x58c][s], "Lv" if have else "")
		d.set_text([0x570, 0x573][s], "%d" % lvl if have else "")
		d.set_text([0x58b, 0x58d][s], "Exp" if have else "")
		var bar: Dictionary = d.ctrl([0x58e, 0x58f][s])
		bar["on"] = have
		var mx := 200 if ItemText66.is_treasure(iid) else 100      # 0x4201e7
		bar["value"] = mx if xp == 0xff else xp
		bar["maxv"] = mx
		bar["label"] = "MAX" if xp == 0xff else "%d/%d" % [xp, mx]
		d.set_text([0x579, 0x578][s], bonus_text(iid, lvl) if have else "")
	d.set_text([0x588, 0x589, 0x57a][s], treasure_text(iid, lvl) if have else "")
	d.queue_redraw()


## E text 0x461fc8: equipment "攻击 +v" (精神 for kinds 7–8; 攻击 and 精神 for kind 9, 0x40b8a5; 防御 for armour),
## accessories the effect text (0x461ed6).
static func bonus_text(iid: int, lvl: int) -> String:
	if not ItemText66.is_equipment(iid):
		return ItemText66.special_text(iid, lvl)
	var kind := int(ItemText66.it(iid).get("type", 0)) >> 1
	var v := ItemText66.value_at(iid, lvl)
	if kind == 9:
		return "攻击 +%d  精神 +%d" % [v, v]
	var nm := "攻击"
	if kind == 7 or kind == 8:
		nm = "精神"
	elif kind >= 10:
		nm = "防御"
	return "%s +%d" % [nm, v]


## B text 0x40df60: a treasure's special effect, else empty.
static func treasure_text(iid: int, lvl: int) -> String:
	if iid == 0xff or not ItemText66.is_treasure(iid):
		return ""
	return ItemText66.special_text(iid, lvl)


## The eight values of a person (0x40715a … 0x4072bb).
static func stat_values(p: Person) -> Array:
	var out := []
	for s in 5:
		out.append(p.stat(s))
	out.append(p.max_hp())
	out.append(p.max_mp())
	out.append(p.move_points())
	return out


## 0x468eb5(row): the values with `row`'s item worn instead of the current one in its slot (row {} = none: the
## current values, no changes). Items the person cannot use (0x407961) show no change.
func preview(row: Dictionary) -> void:
	var p := person()
	if p == null:
		return
	var now := stat_values(p)
	var then := now
	var iid := int(row.get("item", 0xff))
	if iid != 0xff and Game._can_use(p, iid) and ItemText66.category(iid) < 3:
		var s := ItemText66.category(iid)
		var b := p.base + 0x2e + 3 * s
		var keep := [Mem.r8(b), Mem.r8(b + 1), Mem.r8(b + 2)]
		Mem.w8(b, iid)
		if s < 2:
			Mem.w8(b + 1, int(row.get("lvl", 1)))
			Mem.w8(b + 2, int(row.get("exp", 0)))
		then = stat_values(p)
		Mem.w8(b, keep[0])
		Mem.w8(b + 1, keep[1])
		Mem.w8(b + 2, keep[2])
	for k in 8:
		d.set_text(STAT_IDS[k], "%d" % int(then[k]))
		var diff: int = int(then[k]) - int(now[k])
		d.set_text(STAT_IDS[k] + 8, "" if diff == 0 else ("+%d" % diff if diff > 0 else "%d" % diff))
		d.set_color(STAT_IDS[k] + 8, Color8(0, 0, 200) if diff > 0 else Color8(200, 0, 0))
	d.set_text(0x471, "%d" % p.level)
	d.set_text(0x5db, p.class_name_str())
	var eq := [Mem.r8(p.base + 0x2e), Mem.r8(p.base + 0x31), Mem.r8(p.base + 0x34)]
	if iid != 0xff and Game._can_use(p, iid) and ItemText66.category(iid) < 3:
		eq[ItemText66.category(iid)] = iid
	d.set_text(0x5dc, skills_text(pid, eq))


## 0x477249 / 0x477295: "专属技能：" then the 特效 rows (0x50e000, 255 × 16 B) whose exclusive entry {u16 person, u8
## item, u8 value} names this person and a worn item, "套装技能：" then the rows whose set entry {weapon, armour,
## accessory, value} has at least two pieces worn; each as "  name  value" (names 0x4cc600 + 16·row, 0x41b707), or
## "  --" when none.
static func skills_text(who: int, eq: Array) -> String:
	var out := ""
	for mode in 2:
		out += ["专属技能：\n", "套装技能：\n"][mode]
		var lines := ""
		for row in 255:
			var val := 0
			for slot in 2:
				var a := 0x50e000 + row * 16 + mode * 8 + slot * 4
				if mode == 0:
					if Mem.r16(a) == who and Mem.r8(a + 2) != 0xff and eq.has(Mem.r8(a + 2)):
						val = Mem.r8(a + 3)
				else:
					var hits := 0
					var bad := false
					for k in 3:
						var want := Mem.r8(a + k)
						if want == 0xff:
							continue
						if want != int(eq[k]):
							bad = true
							break
						hits += 1
					if not bad and hits > 1:
						val = Mem.r8(a + 3)
				if val != 0:
					break
			if val != 0:
				lines += "  %s  %d\n" % [skill_name(row), val]
		out += lines if lines != "" else "  --\n"
	return out


static func skill_name(sid: int) -> String:
	var b := PackedByteArray()
	for k in 16:
		var c := Mem.r8(SKILL_NAMES + 16 * sid + k)
		if c == 0:
			break
		b.append(c)
	return TextExpand.from_gbk(b)


## 0x401126 → 0x40f436(0xfe, list, mode, …): the person's 特技 — personal slots of table [0x500c3b] (0x511000, rows
## of 4 × {u16 person, u8 value} + 2 × {u8 class, u8 value}) and the class slots matching the person's class
## (Effects.class_value). [G] one line "name value" per 特技.
func _fill_skills() -> void:
	var lv: Dlg66.ListView = d.list(0x4d3)
	lv.rows.clear()
	lv.top = 0
	lv.sel = -1
	var p := person()
	for sid in 255:
		var v := Effects.personal_value(pid, sid)
		if v == 0:
			v = Effects.class_value(p.cls, sid)
		if v != 0:
			lv.rows.append({"cells": ["%s %d" % [skill_name(sid), v]], "enabled": true, "data": sid})
