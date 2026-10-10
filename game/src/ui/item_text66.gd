class_name ItemText66
extends RefCounted
## Item texts and numbers of the 6.6 list views (cell drawers of 0x46776a, jump table 0x467c62; column kinds 0..14 with
## headers 0x466613 and alignments 0x46664f) and the shop arithmetic. Item data from Game.item() (Data.e5 / Star.e5).
## Column kinds: 0 名称 (small icon + name), 1 Lv, 2 Exp ("--" for accessories, "MAX" for exp 0xff), 3 属性 (kind
## name 0x40b460 → table 0x48bc04), 4 功效 (effect name 0x4230f9), 5 效果 (value text 0x405c5c), 6 价格 (buy price
## 0x40d85e), 7 总数 (owned incl. equipped, 0x42fab3(item, 1)), 8 装备 (○ usable by the current person / ×), 9 卖价
## (0x40b477, "---" unsellable), 10 特殊效果 (0x461ed6, "无"), 11 库存 (in the warehouse / count, 0x42fab3(item, 0)),
## 12 持有者 (holder or 仓库), 13 护具, 14 辅助.

const TITLES := ["名称", "Lv", "Exp", "属性", "功效", "效果", "价格", "总数", "装备", "卖价", "特殊效果", "库存", "持有者",
	"护具", "辅助"]
const LVCFMT := [0, 1, 1, 2, 2, 1, 1, 1, 2, 1, 2, 1, 2, 0, 0]      # 0x46664f
## Sample strings measured for the base widths (0x466f0b) and the padding added (0x466f47).
const SAMPLES := ["道具名文字数", "Lv", "MAX", "属性", "兵种上升", "效果", "价格", "总数", "装备", "价格", "特殊效果", "库存",
	"持有者", "道具名文字数", "道具名文字数"]
const PAD := [8, 8, 8, 12, 12, 12, 12, 12, 12, 12, 22, 12, 12, 8, 8]
const KINDS := ["剑", "枪", "弓", "棍", "炮车", "锤", "斧", "扇", "宝剑", "神器", "铠甲", "劲装", "袍服", "辅助", "道具"]
## Value display type per effect id − 0x1a (table 0x4cb6ba): 0 "--", 1 "+%d" (0xff "ALL"), 2 "+%d%%", 3 "-%d%%",
## 4 "%d%%", 5 "%d", 6 "%d次", ≥ 7 a name (0x460510; shown as the number here, [G]).
const FMT_TABLE := 0x4cb6ba


## A list column of kind k (header 0x466613, LVCFMT 0x46664f: 0 left, 1 right, 2 centre).
static func column(k: int, d: Dlg66) -> Dictionary:
	var al: int = [0, 2, 1][LVCFMT[k]]
	return {"title": TITLES[k], "w": d._tw(SAMPLES[k]) + PAD[k] * 1.5, "align": al, "kind": k}


static func it(iid: int) -> Dictionary:
	return Game.item(iid & 0xff) if iid >= 0 and iid < 0xff else {}


static func name(iid: int) -> String:
	return str(it(iid).get("name", "")).strip_edges()


static func category(iid: int) -> int:
	return int(it(iid).get("category_code", 3))


static func is_equipment(iid: int) -> bool:
	return category(iid) <= 1


static func is_treasure(iid: int) -> bool:
	return bool(it(iid).get("treasure", false))


static func small_icon(iid: int) -> Texture2D:
	var d := it(iid)
	if d.is_empty():
		return null
	var p := "gfx/icons/items/small/%03d.png" % int(d.get("icon", iid))
	return Assets.tex(p) if Assets.exists(p) else null


static func large_icon(iid: int) -> Texture2D:
	var d := it(iid)
	if d.is_empty():
		return null
	var p := "gfx/icons/items/large/%03d.png" % int(d.get("icon", iid))
	return Assets.tex(p) if Assets.exists(p) else null


## 属性 (0x40b460): weapon / armour kind type >> 1, else 13 + category (辅助 / 道具).
static func kind_name(iid: int) -> String:
	var d := it(iid)
	if d.is_empty():
		return ""
	var t := int(d.get("type", 0))
	var k := t >> 1 if t < 0x1a else int(d.get("category_code", 3)) + 11
	return KINDS[k] if k >= 0 and k < KINDS.size() else ""


## Effect id − 0x1a (0x40b4bd): equipment → the treasure special (+0x14), others → the type (+0x11).
static func effect_index(iid: int) -> int:
	var d := it(iid)
	if d.is_empty():
		return -1
	var e: Variant = d.get("special") if is_equipment(iid) else d.get("type")
	return -1 if e == null else int(e) - 0x1a


## 功效 (0x4230f9).
static func effect_name(iid: int) -> String:
	return str(it(iid).get("effect_name", "")) if it(iid).get("effect_name") != null else ""


## Equipment value at a level (0x40b3d7): base + growth × (level − 1).
static func value_at(iid: int, lvl: int) -> int:
	var d := it(iid)
	var v := int(d.get("value", 0))
	if is_equipment(iid):
		var n := (lvl - 1) & 0xff
		v += int(d.get("growth", 0)) * n
	return v


## Value text of an effect (0x46215b, format table 0x4cb6ba).
static func effect_value_text(iid: int, lvl := 0) -> String:
	var e := effect_index(iid)
	if e < 0:
		return "--"
	var t := Mem.r8(FMT_TABLE + e)
	var v := int(it(iid).get("value", 0)) if not is_treasure(iid) else int(it(iid).get("special_value", 0))
	match t:
		0:
			return "--"
		1:
			if v == 0xff:
				return "ALL"
			return "--" if v == 0 else "+%d" % v
		2:
			return "--" if v == 0 else "+%d%%" % v
		3:
			return "-%d%%" % v
		4:
			return "%d%%" % v
		5:
			return "%d" % v
		6:
			return "%d次" % v
	return "%d" % v


## 效果 (0x405c5c): no item "--"; equipment "+value at level"; others the effect's value text.
static func value_text(iid: int, lvl: int) -> String:
	if iid < 0 or iid >= 0xff:
		return "--"
	if is_equipment(iid):
		return "+%d" % value_at(iid, lvl)
	return effect_value_text(iid, lvl)


## 特殊效果 (0x461ed6): treasures and accessories / consumables show "effect value"; plain equipment "无".
static func special_text(iid: int, lvl: int) -> String:
	if iid < 0 or iid >= 0xff:
		return ""
	if not is_treasure(iid) and int(it(iid).get("type", 0)) <= 0x19:
		return "无"
	var nm := effect_name(iid)
	var vt := effect_value_text(iid, lvl)
	if vt == "--" or vt == "":
		return nm
	return "%s %s" % [nm, vt]


## Buy price 0x40d85e: price byte × 100; equipment with EV[4039] (auto upgrade) costs 8000 (0x453a98(0xff, …)).
static func buy_price(iid: int) -> int:
	var p := int(it(iid).get("price", 0)) * 100
	if is_equipment(iid) and Mem.r8(Mem.EV + 4 * 4039) != 0:
		return 8000
	return p


## Sell price 0x40b477(item, level): price 0xff → -1 (cannot be sold); else price × 300 / 4; equipment through
## 0x453a98(level, v): EV[4039] → 8000, else (level + 1) × v / 2 unless the level is 0xff.
static func sell_price(iid: int, lvl: int) -> int:
	var pr := int(it(iid).get("price", 0xff))
	if pr == 0xff:
		return -1
	var v := (pr * 300) >> 2
	if is_equipment(iid):
		if Mem.r8(Mem.EV + 4 * 4039) != 0:
			return 8000
		if lvl != 0xff:
			v = ((lvl + 1) * v) >> 1
	return v


## Count in the warehouse (0x40d623) or, for consumables, the count byte (0x4202c4: u8 0x493a50[item]).
static func stock(iid: int) -> int:
	if category(iid) == 3:
		return Mem.r8(0x493a50 + iid)
	var n := 0
	for i in Game.BAG_SLOTS:
		if Mem.r8(Game.BAG + 3 * i) == (iid & 0xff):
			n += 1
	return n


## Owned in total 0x42fab3(item, 1): the warehouse plus what members (+0x2a ≠ 0xff, 0x41a22b) wear in the item's slot.
static func total(iid: int) -> int:
	if category(iid) == 3:
		return stock(iid)
	var n := stock(iid)
	var slot := category(iid)
	for pid in 0x400:
		var b := Mem.person_addr(pid)
		if Mem.r8(b + 0x2a) != 0xff and Mem.r8(b + 0x2e + 3 * slot) == (iid & 0xff):
			n += 1
	return n


## Bag occupancy 0x40d651 (slots whose id byte is not 0xff).
static func bag_count() -> int:
	var n := 0
	for i in Game.BAG_SLOTS:
		if Mem.r8(Game.BAG + 3 * i) != 0xff:
			n += 1
	return n


static func lv_text(iid: int, lvl: int) -> String:
	if category(iid) == 2:
		return "--"
	return "%d" % lvl


static func exp_text(iid: int, xp: int) -> String:
	if category(iid) == 2:
		return "--"
	return "MAX" if xp == 0xff else "%d" % xp


## Cell text of column kind k for a row {item, lvl, exp, usable, holder}.
static func cell(k: int, row: Dictionary) -> String:
	var iid := int(row.get("item", 0xff))
	var lvl := int(row.get("lvl", 0))
	var xp := int(row.get("exp", 0))
	match k:
		0: return name(iid)
		1: return lv_text(iid, lvl)
		2: return exp_text(iid, xp)
		3: return kind_name(iid)
		4: return effect_name(iid)
		5: return value_text(iid, lvl)
		6: return "%d" % buy_price(iid)
		7: return "%d" % total(iid)
		8: return "○" if bool(row.get("usable", false)) else "×"
		9:
			var sp := sell_price(iid, lvl)
			return "---" if sp < 0 else "%d" % sp
		10: return special_text(iid, lvl)
		11: return "%d" % stock(iid)
		12:
			var h := int(row.get("holder", -1))
			return "仓库" if h < 0 else TextExpand.display_name(h)
	return ""
