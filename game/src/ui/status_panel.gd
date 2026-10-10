class_name StatusPanel
extends Dlg66
## 武将情报, dialog 166 (proc 0x479164, refresh 0x478664) with the tab pages 装备 (179, 0x476eab), 策略 (200) and 兵种
## (284, 0x477b7f) — the 6.6 window has these three pages (names 0x48ec4c, templates 0x487628).
## Main part: face 0x434 (Face.e5, key → black), the display name 0x3f6, the side 0x3f7 ("[ 我军 ]" … by unit +5, only
## with a battle unit, 0x413172), the class 0x3f8 (+ "+" when it can be promoted, 0x468c7d), Lv 0x3f9 and the Exp
## bar 0x562; 状态: HP / MP / SP bars 0x563..0x565 (0x479480: a battle unit's current HP / MP, SP u8 0x501c00[person])
## and the five values 0x566..0x56a (0x476b85: lowered / raised by the unit's buffs drawn red / pink), 移动 0x56b
## (0x476973: "%u ( +%d )" with a move buff); 基本能力 武力 统率力 智力 敏捷 运气 0x7d1..0x7d5 (raw abilities, 0x4070e1);
## the biography 0x5a6 (Imsg 922 + person, or 922 + (0x300 | byte +3) when that is set, 0x408d38 / 0x40bfdb); the 特技
## list 0x4d3 (0x401126); the status line 0x3fd (0x478a12); "出阵数 %2d  杀敌数 %2d  撤退数 %2d" 0x3fc and 现金 0x3fb
## for members. 上一武将 / 下一武将 step through the list it was opened with ([G] the members outside a battle).
## [G] bar maxima (HP / MP max, SP the 必杀 threshold EV[4061], values 2000) and colours (Dlg66._bar_fill); the 兵种
## page shows the class growth values instead of grade letters, and the 攻击 / 影响范围 pictures are not drawn.

const SIDES := ["[ 我军 ]", "[ 友军 ]", "[ 敌军 ]", "[ 援军 ]"]          # 0x48ebf1, 9 bytes each
const AILMENTS := [["麻痹", 0x03], ["禁咒", 0x0c], ["混乱", 0x30], ["中毒", 0xc0]]   # 0x486d06; unit +0x1e fields
const BUFF_NAMES := ["攻击", "防御", "精神", "爆发", "士气", "移动"]          # 0x486ae0
const FAMILY_KIND := ["全能", "文官", "武将"]                               # 0x486d38

static var tab := 0         # [0x48e9a8]: the page shown last

var pids: Array[int] = []
var idx := 0
var pid := 0
var unit := -1              # unit record address or -1


static func show_person(ui: CanvasLayer, p: Person) -> void:
	if p == null or Game.autoplay:
		return
	var d := StatusPanel.new()
	var lst: Array[int] = []
	if not _battle():
		for i in 0x400:
			if Mem.r8(Mem.person_addr(i) + 0x2a) != 0xff:
				lst.append(i)
	if not lst.has(p.id):
		lst = [p.id]
	d.pids = lst
	d.idx = lst.find(p.id)
	d.build()
	ShopMenu.click_se(0)
	await Dlg66.run_dialog(ui, d)


static func _battle() -> bool:
	var st: Variant = Game.main.stage if Game.main else null
	return st != null and is_instance_valid(st) and st.has_method("in_battle") and st.in_battle()


## 0x419b76 (in a battle): the first unit record holding the person (state ≠ 0), else -1.
static func unit_of(who: int) -> int:
	if not _battle():
		return -1
	for s in Mem.UNIT_SLOTS:
		var a := Mem.unit_addr(s)
		if Mem.r32(a) == who and Mem.r8(a + 0xc) != 0:
			return a
	return -1


func build() -> void:
	setup("武将情报", 328, 272)
	add_pic(0x434, 5, 3, 80, 80)["bg"] = Color.BLACK      # Face.e5 drawn with mode 0x60: key → black
	add_static(0x3f6, 3, 85, 40, 8)
	add_static(0x3f7, 47, 85, 36, 8)
	add_static(0x3f8, 3, 95, 45, 8)
	add_static(null, 3, 105, 8, 8, "Lv")
	add_static(0x3f9, 15, 105, 13, 8)
	add_static(null, 30, 105, 12, 8, "Exp")
	add_bar(0x562, 45, 105, 41, 8)
	add_group(1, 114, 88, 104, "状态")
	var labels := ["HP", "MP", "SP", "攻击", "防御", "精神", "爆发", "士气", "移动"]
	for k in 9:
		add_static(null, 4, 125 + 10 * k, 25 if k > 2 else 10, 8, labels[k])
	for k in 8:
		add_bar(0x563 + k, 22, 125 + 10 * k, 63, 8)
	add_static(0x56b, 43, 205, 38, 8, "", 2)
	add_group(91, 1, 106, 44, "基本能力")
	var ab := ["武力", "统率力", "智力", "敏捷", "运气"]
	var pos := [[97, 12], [97, 23], [97, 34], [150, 12], [150, 23]]
	for k in 5:
		add_static(null, pos[k][0], pos[k][1], 22, 8, ab[k])
		add_static(0x7d1 + k, pos[k][0] + 20 + (3 if k < 3 else 0), pos[k][1], 14, 8, "", 2)
	add_static(0x5a6, 91, 48, 106, 69, "", 0, true)
	add_listbox(0x4d3, 91, 119, 106, 99)
	add_static(0x3fd, 1, 221, 196, 26, "", 0, true)
	add_group(1, 248, 36, 21, "现金")
	add_static(0x3fb, 5, 259, 30, 8, "", 2)
	add_static(0x3fc, 40, 256, 147, 12, "", 2)
	add_tab(0x405, 200, 2, 127, 245, ["装备", "策略", "兵种"])
	add_button(0x403, 199, 256, 37, 13, "上一武将")
	add_button(0x404, 238, 256, 40, 13, "下一武将")
	add_button(2, 288, 256, 38, 13, "确定")
	_build_pages()
	_refresh()
	_tab(tab)


# ------------------------------------------------------------------ pages
## The pages inside the tab control (templates 179 / 200 / 284 at (1, 15) of it, 0x478f7b).
func _build_pages() -> void:
	var ox := 201.0
	var oy := 17.0
	var eq := []
	for s in 3:
		var y0: float = [1, 58, 115][s]
		eq.append(add_static([0x56f, 0x570, 0x571][s], ox + 3, oy + y0, 100, 8))
		eq.append(add_pic([0x582, 0x583, 0x584][s], ox + 3, oy + y0 + 10, 23, 23))
		if s < 2:
			eq.append(add_static([0x58a, 0x58b][s], ox + 28, oy + y0 + 12, 10, 8, "Lv"))
			eq.append(add_static([0x58e, 0x58f][s], ox + 39, oy + y0 + 12, 13, 8))
			eq.append(add_static([0x58c, 0x58d][s], ox + 28, oy + y0 + 24, 14, 8, "Exp"))
			eq.append(add_bar([0x590, 0x591][s], ox + 47, oy + y0 + 24, 73, 8))
			eq.append(add_static([0x579, 0x57a][s], ox + 3, oy + y0 + 35, 100, 8))
			eq.append(add_static([0x588, 0x589][s], ox + 3, oy + y0 + 45, 118, 8))
			eq.append(add_line(ox + 3, oy + y0 + 55, 117, 1))
		else:
			eq.append(add_static(0x57b, ox + 3, oy + y0 + 35, 100, 8))
			eq.append(add_line(ox + 3, oy + y0 + 45, 117, 1))
	eq.append(add_static(0x5dc, ox + 3, oy + 163, 117, 63, "", 0, true))
	var lv := add_list(0x521, ox + 2, oy, 120, 217)
	lv.columns = [{"title": "策略", "w": 80.0, "align": 0}, {"title": "MP", "w": 30.0, "align": 2}]
	var cl := []
	cl.append(add_static(null, ox + 2, oy + 3, 36, 8, "战斗形象"))
	cl.append(add_pic(0x3fa, ox + 1, oy + 22, 33, 33))
	var rows := ["攻击", "防御", "精神", "爆发", "士气", "移动", "HP", "MP"]
	var ids := [0x7d6, 0x7d7, 0x7d8, 0x7d9, 0x7da, 0x964, 0x969, 0x96a]
	for k in 8:
		cl.append(add_static(null, ox + 2, oy + 58 + 10 * k, 18, 8, rows[k]))
		cl.append(add_static(ids[k], ox + 23, oy + 58 + 10 * k, 18, 8, "", 1))
	cl.append(add_static(null, ox + 36, oy + 3, 39, 8, "攻击范围", 1))
	cl.append(add_pic(0x5a9, ox + 36, oy + 13, 41, 41))
	cl.append(add_static(null, ox + 80, oy + 3, 39, 8, "影响范围", 1))
	cl.append(add_pic(0x5aa, ox + 80, oy + 13, 41, 41))
	cl.append(add_static(null, ox + 46, oy + 58, 22, 8, "武器:"))
	cl.append(add_static(null, ox + 46, oy + 108, 22, 8, "护具:"))
	cl.append(add_static(0x5c0, ox + 46, oy + 66, 76, 40))
	cl.append(add_static(0x5c1, ox + 46, oy + 116, 76, 20))
	for e in [["策伤比率:", 2, 138, 0x5bb], ["参与围攻:", 62, 138, 0x5bc], ["远程单位:", 2, 148, 0x5bd], ["兵种类型:", 62, 148, 0x5be]]:
		cl.append(add_static(null, ox + e[1], oy + e[2], 36, 8, e[0]))
		cl.append(add_static(e[3], ox + e[1] + 40, oy + e[2], 20, 8))
	cl.append(add_static(0x9a6, ox + 1, oy + 161, 121, 66, "", 0, true))
	ctrl(0x405)["pages"] = [eq, [ctrl(0x521)], cl]


## 0x4790da.
func _tab(i: int) -> void:
	tab = i
	ctrl(0x405)["sel"] = i
	var pages: Array = ctrl(0x405)["pages"]
	for k in pages.size():
		for c in pages[k]:
			(c as Dictionary)["visible"] = k == i
	queue_redraw()


func _on_tab(_id: Variant, i: int) -> void:
	ShopMenu.click_se(0)
	_tab(i)


func _on_command(id: Variant) -> void:
	match id:
		0x403:
			if idx > 0:
				idx -= 1
				_refresh()
		0x404:
			if idx < pids.size() - 1:
				idx += 1
				_refresh()
		_:
			super._on_command(id)


# ------------------------------------------------------------------ fill (0x478664)
func _refresh() -> void:
	pid = pids[idx]
	var p := Game.person(pid)
	unit = unit_of(pid)
	enable(0x403, idx > 0)
	enable(0x404, idx < pids.size() - 1)
	ctrl(0x434)["tex"] = Game.person_face(pid)
	set_text(0x3f6, TextExpand.display_name(pid))
	var side := Mem.r8(unit + 5) if unit >= 0 else 0
	if side > 6:
		side = 0
	set_text(0x3f7, SIDES[side] if unit >= 0 and side < 4 else "")
	var promo := p.cls <= 59 and p.cls % 3 < 2 and (p.cls % 3 + 1) * 15 <= p.level
	set_text(0x3f8, p.class_name_str() + ("+" if promo else ""))
	set_text(0x3f9, "%d" % p.level)
	_bar(0x562, 100 if p.exp == 0xff else p.exp, 100, 5, "MAX" if p.exp == 0xff else "%d" % p.exp)
	var hp := p.max_hp()
	var mp := p.max_mp()
	var chp := hp
	var cmp := mp
	var hp_style := 1
	var mp_style := 3
	if unit >= 0:
		chp = Mem.r32(unit + 0x10)
		cmp = Mem.r32(unit + 0x14)
		if Mem.r8(unit + 0x1e) & 0xc0:
			hp_style = 2
		if Mem.r8(unit + 0x1e) & 0x0c:
			mp_style = 4
	_bar(0x563, chp, hp, hp_style, "%d/%d" % [chp, hp])
	_bar(0x564, cmp, mp, mp_style, "%d/%d" % [cmp, mp])
	var sp := Mem.r8(Mem.SP + pid)
	_bar(0x565, sp, maxi(Mem.r8(Mem.EV + 4 * 4061), 1), 6, "%d" % sp)
	for k in 5:
		var v := p.stat(k)
		var style := 6
		if unit >= 0:
			var bf := Mem.r8(unit + 0x18 + k)
			style = 7 if bf < 3 else (8 if bf > 3 else 6)
		_bar(0x566 + k, v, 2000, style, "%d" % v)
	var mv := p.move_points()
	var mtext := "%d" % mv
	if unit >= 0 and Mem.r8(unit + 0x1d) != 3:
		var dv := Mem.r8(unit + 0x1d) - 3
		mtext = "%d ( %s%d )" % [mv, "+" if dv > 0 else "-", absi(dv)]
	set_text(0x56b, mtext)
	for k in 5:
		set_text(0x7d1 + k, "%d" % Mem.r8(p.base + 0x21 + k))
	var b3 := Mem.r8(p.base + 3)
	var bio := (0x300 | b3) if b3 != 0 else pid
	set_text(0x5a6, TextExpand.expand(Game.text(0x39a + bio)).replace("\r", "") if bio < 0x400 else "")
	_status_line()
	show_ctrl(0x3fb, Mem.r8(p.base + 0x2a) != 0xff)
	set_text(0x3fb, "%d" % Game.gold)
	set_text(0x3fc, "出阵数 %2d  杀敌数 %2d  撤退数 %2d" % [Mem.r8(p.base + 0x27), Mem.r16(p.base + 0x35),
			Mem.r8(p.base + 0x29)] if Game.is_member(pid) else "")
	_skills(p)
	_equip_page(p)
	_strategy_page(p)
	_class_page(p)
	queue_redraw()


func _bar(id: int, v: int, mx: int, style: int, label: String) -> void:
	var c := ctrl(id)
	c["on"] = true
	c["value"] = v
	c["maxv"] = mx
	c["style"] = style
	c["label"] = label


## 0x478a12.
func _status_line() -> void:
	if unit < 0:
		set_text(0x3fd, "正常 ")
		return
	var s := ""
	var ail := Mem.r8(unit + 0x1e)
	for a in AILMENTS:
		if ail & int(a[1]):
			s += str(a[0]) + " "
	for k in 6:
		var v := Mem.r8(unit + 0x18 + k)
		if v != 3:
			s += BUFF_NAMES[k] + ("下降" if v < 4 else "上升") + " "
	var slot := (unit - Mem.UNITS) / Mem.UNIT_SIZE
	if Mem.r8(unit + 5) == 0 and Mem.r8(0x501b00 + slot) != 0:
		s += "经验加倍 "
	if s == "":
		s = "正常 "
	if Mem.r8(unit + 0xd) & 2:
		s += "行动完毕"
	set_text(0x3fd, s)


## 0x401126: the 特技 list.
func _skills(p: Person) -> void:
	var lv := list(0x4d3)
	lv.rows.clear()
	lv.top = 0
	lv.sel = -1
	for sid in 255:
		var v := Effects.personal_value(pid, sid)
		if v == 0:
			v = Effects.class_value(p.cls, sid)
		if v != 0:
			lv.rows.append({"cells": ["%s %d" % [PersonPanel66.skill_name(sid), v]], "enabled": true, "data": sid})


## 0x476eab.
func _equip_page(p: Person) -> void:
	var eq := []
	for s in 3:
		var b := p.base + 0x2e + 3 * s
		var iid := Mem.r8(b)
		eq.append(iid)
		var have := iid != 0xff
		set_text([0x56f, 0x570, 0x571][s], PersonPanel66.SLOT_TITLES[s] % (ItemText66.name(iid) if have else ""))
		ctrl([0x582, 0x583, 0x584][s])["tex"] = ItemText66.large_icon(iid) if have else null
		if s < 2:
			set_text([0x58e, 0x58f][s], "%d" % Mem.r8(b + 1) if have else "")
			var xp := Mem.r8(b + 2)
			var mx := 200 if ItemText66.is_treasure(iid) else 100
			var c := ctrl([0x590, 0x591][s])
			c["on"] = have
			c["value"] = mx if xp == 0xff else xp
			c["maxv"] = mx
			c["style"] = 5
			c["label"] = "MAX" if xp == 0xff else "%d" % xp
			set_text([0x579, 0x57a][s], PersonPanel66.bonus_text(iid, Mem.r8(b + 1)) if have else "")
			set_text([0x588, 0x589][s], PersonPanel66.treasure_text(iid, Mem.r8(b + 1)) if have else "")
		else:
			set_text(0x57b, ItemText66.special_text(iid, 0) if have else "")
	set_text(0x5dc, PersonPanel66.skills_text(pid, eq))


## 策略 page: strategies known by class level (0x41832b) or the learned list 0x507800 (0x40de69).
func _strategy_page(p: Person) -> void:
	var lv := list(0x521)
	lv.rows.clear()
	lv.top = 0
	for s in Game.strategies_db.size():
		if Rules.learned_by_level(p, s) or Rules.learned_by_table(p, s):
			var st: Dictionary = Game.strategies_db[s]
			lv.rows.append({"cells": [str(st.get("name", "")), "%d" % int(st.get("mp", 0))], "enabled": true, "data": s})
	lv.fit_columns(self)


## 0x477b7f: the class page.
func _class_page(p: Person) -> void:
	var fam := Game.family_of(p.cls)
	var g := p.graphic_id()
	var entry := g * 3 if g < 0x50 else g + 0xa0
	var path := "gfx/units/mov/%03d.png" % entry
	var pic := ctrl(0x3fa)
	if Assets.exists(path):
		pic["tex"] = Assets.tex(path)
		pic["src"] = Rect2(0, 48 * 6, 48, 48)                 # frame 6: standing, facing down
	for k in 5:
		set_text(0x7d6 + k, "%d" % p.growth(k))
	set_text(0x964, "%d" % int(Game.cls(p.cls).get("move", 0)))
	set_text(0x969, "%d" % p.growth(5))
	set_text(0x96a, "%d" % p.growth(6))
	set_text(0x5bb, "%d" % Mem.r8(0x4d21b0 + fam))
	set_text(0x5bc, "是" if Mem.r8(0x4d21d8 + fam) != 0 else "否")
	set_text(0x5bd, "是" if (Mem.r8(0x4d2138 + fam) ^ 1) != 0 else "否")
	set_text(0x5be, FAMILY_KIND[clampi(Mem.r8(0x4d2188 + fam), 0, 2)])
	var eqr: Array = Game.cls(p.cls).get("equip_raw", [])
	var w := []
	var a := []
	for k in 13:
		if k * 2 < eqr.size() and int(eqr[k * 2]) != 0:
			(w if k < 10 else a).append(ItemText66.KINDS[k])
	set_text(0x5c0, " ".join(w))
	set_text(0x5c1, " ".join(a))
	set_text(0x9a6, Game.text(0x15e + p.cls).replace("\r", "") if p.cls < 0x50 else "")
