class_name PartyMenu
extends RefCounted
## Entry points of the out-of-battle windows (called by the story stage's toolbar and system menu):
##  * equip_menu → dialog 328 装备 (EquipDlg66; toolbar 装备, 0x461c88);
##  * unit_list → dialog 186 部队情报一览 (UnitList66; menu 情报 → 武将一览, 0x47af8a), rows open 武将情报;
##  * item_menu → dialog 325 道具一览 (ItemList66; menu 情报 → 持有道具一览, 0x43fdef). The 6.6 engine has no item use
##    outside a battle: this list only shows what is held.


static func equip_menu(ui: GameUI) -> void:
	await EquipDlg66.run(ui)


static func item_menu(ui: GameUI) -> void:
	await ItemList66.run(ui)


static func unit_list(ui: GameUI) -> void:
	await UnitList66.run(ui)
