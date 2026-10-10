class_name ResultPanel
extends RefCounted
## The unit result window of the 6.6 engine, 0x450986 → 0x450033(kind, slot, place, hp_loss, mp_loss, exp_gain,
## wexp, aexp, long): shown beside the unit after an exchange, a strategy, poison, regeneration, a duel… only when
## something changes (kind ∉ {0, 0x100} or any amount ≠ 0) and byte EV[4087] = 0. It is called before HP / MP / EXP
## are written: their bars run from the current values to the new ones.
##   kind 0x100 (also forced by byte EV[4059] = 1): the third bar is EXP (0x4065c7, max 100, "MAX" at 0xff) rising
##   by exp_gain (capped at 100); any other kind: the third bar is SP (0x424808, max 255) and kind = the SP already
##   gained (the bar runs from SP − kind to SP).
## Layout (0x44fc4b / 0x453c03 / 0x4509da): a 192 × 144 window (8 × 6 cells of 24) one cell right of the unit, or
## 4 cells left of it in the right half of the view, at its row (2 rows up in the lower half); the person's name
## (palette 0x12), level and class (0x1f) at y + 8; 24 × 24 icons (U_select 17: heart, feather, sword, scroll) at
## x + 16 and y + 0x20 / 0x38 / 0x50; 128 × 8 bars at x + 0x30, y + 8 of each row (bar = value·128 / max: HP max
## HP, MP max MP, EXP 100, SP 255) with "%4u /%4u" ("    MAX   " for EXP 0xff) at x + 0x48; weapon / armour icons
## (Mark 经验) at x + 0x18 / x + 0x70, y + 0x70. The bars move in 5 steps of one tick, then 4 ticks; the item
## EXP in 4 steps; then 4 ticks (8 with `long`).
## [G] Text outline colours, the bar fill colour (palette 8) and the item EXP lines are approximations.

const W := 192
const H := 144


static func show(st: BattleStage, u: BUnit, kind: int, hp_loss: int, mp_loss: int, exp_gain: int, wexp: int,
		aexp: int, long_wait: bool) -> void:
	if u == null or u.pid < 0:
		return
	if not ((kind != 0x100 and kind != 0) or hp_loss != 0 or mp_loss != 0 or exp_gain != 0 or wexp != 0 or aexp != 0):
		return
	if Mem.r8(Mem.EV + 4 * 4059) == 1:
		kind = 0x100
	if Mem.r8(Mem.EV + 4 * 4087) != 0 or Game.autoplay or st.view == null:
		return
	var view := st.view
	var cam := view.camera.position
	var org := Vector2i(floori(cam.x / 48.0), floori(cam.y / 48.0))
	var off := Vector2(org * 48) - cam
	var vs := view.view_size()
	var cols := int(vs.x) / 48
	var rows := int(vs.y) / 48
	var l := u.pos - org
	var cx := l.x + 1 if l.x < cols / 2 else l.x - 4
	var cy := l.y if l.y < rows / 2 else l.y - 2
	var X := float(cx * 48) + off.x
	var Y := float(cy * 48) + off.y
	var win := Win66.new()
	st.ui.add_window(win)
	var p := u.person
	# window 0x453c03: the view darkened 40 % inside, a 3-px frame (palette 0x1d..0x1f, light 0x18 top / left)
	win.fill(Rect2(X, Y, W, H), Color(0, 0, 0, 0.4))
	for i in 3:
		var c := Text66.pal(0x1d + i)
		win.fill(Rect2(X, Y + H - 3 + i, W, 1), c)
		win.fill(Rect2(X + W - 3 + i, Y, 1, H), c)
	win.fill(Rect2(X, Y, W, 1), Text66.pal(0x18))
	win.fill(Rect2(X, Y, 1, H), Text66.pal(0x18))
	win.label(X + 8, Y + 8, TextExpand.display_name(u.pid), 0x12)
	win.label(X + 72, Y + 8, "Lv%d" % p.level, 0x12)
	win.label(X + 112, Y + 8, str(Game.cls(p.cls).get("name", "")), 0x12)
	var icons := Assets.tex("gfx/ui/u_select/17.png")
	var exp_mode := kind == 0x100
	win.pic(icons, Vector2(X + 16, Y + 0x20), Rect2(0, 0, 24, 24))
	win.pic(icons, Vector2(X + 16, Y + 0x38), Rect2(0, 24, 24, 24))
	win.pic(icons, Vector2(X + 16, Y + 0x50), Rect2(0, 24 * (3 if exp_mode else 2), 24, 24))
	var marks := Assets.tex("gfx/ui/mark/10.png")
	var has_w := p.weapon >= 0
	var has_a := p.armor >= 0
	if has_w:
		win.pic(marks, Vector2(X + 0x18, Y + 0x70), Rect2(0, 0, 16, 16))
	if has_a:
		win.pic(marks, Vector2(X + 0x70, Y + 0x70), Rect2(0, 16, 16, 16))
	var base := win.parts.size()
	var hp := u.hp
	var mp := u.mp & 0xffff
	var sp := p.sp
	var ex := p.exp
	if ex == 0xff:
		exp_gain = 0
	elif ex + exp_gain > 100:
		exp_gain = 100 - ex
	var sp_gain := 0 if exp_mode else kind
	_bars(win, X, Y, u, hp, mp, ex if exp_mode else sp - sp_gain, exp_mode)
	_item_lines(win, X, Y, p, has_w, has_a, 0, 0)
	if hp_loss != 0 or mp_loss != 0 or exp_gain != 0 or (kind != 0x100 and kind != 0):
		for k in range(4, -1, -1):
			await win.ticks(1)
			win.remove_parts_from(base)
			var third_v := ex + exp_gain - (exp_gain >> 2) * k if exp_mode else sp - (sp_gain / 4) * k
			_bars(win, X, Y, u, hp - hp_loss + (hp_loss / 4) * k, mp - mp_loss + (mp_loss / 4) * k, third_v, exp_mode)
			_item_lines(win, X, Y, p, has_w, has_a, 0, 0)
		await win.ticks(4)
	if wexp != 0 or aexp != 0:
		for k in range(3, -1, -1):
			await win.ticks(1)
			win.remove_parts_from(base)
			_bars(win, X, Y, u, hp - hp_loss, mp - mp_loss, ex + exp_gain if exp_mode else sp, exp_mode)
			_item_lines(win, X, Y, p, has_w, has_a, wexp - (wexp / 3) * k, aexp - (aexp / 3) * k)
	await win.ticks(8 if long_wait else 4)
	win.queue_free()


## The three bars 0x4509da (kinds 0 HP, 1 MP, 2 EXP / 3 SP) at y + 0x20 / 0x38 / 0x50.
static func _bars(win: Win66, X: float, Y: float, u: BUnit, hp: int, mp: int, third: int, exp_mode: bool) -> void:
	_bar(win, X + 0x30, Y + 0x20, maxi(hp, 0), u.max_hp(), false)
	_bar(win, X + 0x30, Y + 0x38, maxi(mp, 0), u.max_mp(), false)
	if exp_mode:
		_bar(win, X + 0x30, Y + 0x50, third, 100, third & 0xff == 0xff)
	else:
		_bar(win, X + 0x30, Y + 0x50, maxi(third, 0), 0xff, false)


static func _bar(win: Win66, x: float, y: float, v: int, mx: int, full: bool) -> void:
	win.fill(Rect2(x, y + 8, 0x80, 8), Text66.pal(0x1f))
	var val := 100 if full else v
	var n := clampi(((val * 100) / maxi(mx, 1) << 7) / 100, 0, 0x80)
	if n > 0:
		win.fill(Rect2(x, y + 8, n, 8), Text66.pal(8))
	win.label(x + 24, y, "    MAX   " if full else "%4d /%4d" % [v, mx], 0x12)


## Weapon / armour level and EXP (gained so far) under the icons.
static func _item_lines(win: Win66, X: float, Y: float, p: Person, has_w: bool, has_a: bool, wg: int, ag: int) -> void:
	if has_w:
		win.label(X + 0x28, Y + 0x70, "Lv%d %d" % [p.weapon_lvl, (p.weapon_exp + wg) & 0xff], 0x12)
	if has_a:
		win.label(X + 0x80, Y + 0x70, "Lv%d %d" % [p.armor_lvl, (p.armor_exp + ag) & 0xff], 0x12)
