# Engine notes (6.6 engine, Ekd5.exe) — script side

Complements `eex.md` (format, execution model, opcode spec). Evidence = addresses in `orig/Ekd5.exe`.
Decompiles: `GDEC_PROJ=<own copy> tools/ghidra/gdec.sh OUT ADDR...` (Ghidra refuses project paths containing a
dot-directory such as `.claude`: symlink the copy to e.g. `/tmp/gproj_x`); disassembly `tools/disx.py VA [n]`.
The 6.6 engine contains hand-written asm with odd conventions (results in ECX, arguments pushed early and read back
as `[ebp-4]`, cdecl handlers that return a second value in ECX): check decompiles against the disassembly.

## Script ops whose names mislead

| op | port name | official 6.x name | real behaviour |
|---|---|---|---|
| 0x08 | set_menu | 菜单处理 | menu flag GS+0x10 + toolbar re-show (the wg2025 port called it set_result and ignored it) |
| 0x0e | ui_0e | 战斗失败 | battle lost → game over |
| 0x0f | screen_mode | 结局设定 | record the ending, play End.Avi, ending show, back to title |
| 0x10 | nop | 许子将指导 | 许子将 advice UI (unused, not a nop) |
| 0x1c / 0x1d | fade_out / fade_in | 绘图 / 调色板设定 | redraw / palette sequences by scene mode (equivalent to the port's fades) |
| 0x1e | wait_frame | 武将重绘 | yield until no actor moves |
| 0x22 | set_weather | 动画 | **play a video** (0 Logo, 1 Open, 2 End, 3 Press, ≥ 4 Mov%03u(id−3); .Avi) |
| 0x23 | play_music | 音效 | **sound effect** (SE%02u / SE_M_%02u / SE_E_%02u) |
| 0x24 | play_sound | CD音轨 | **BGM** track id+2 (`SoundTrk/NN-AudioTrack NN.mp3`) |
| 0x31 | actor_select | 武将消失 | remove actor / units |
| 0x35 | set_r_image | 武将形象改变 | u16 0x50f800[person] = story sprite (wg2025's 0x35 was a different op) |
| 0x37 / 0x3a | test_resource / set_resource | 钱、章节编号、忠奸 | kind 1 "chapter": the **test reads GS+6/2** (current file number, ≤ 127) but the **set writes u8 0x510cf9** (the chapter byte of 0x67) — they are different values |
| 0x3c | test_last_action | 武将加入测试 | nothing to do with joining: last-action code + acting unit test |
| 0x42 / 0x43 | test_event5 / test_event6 | 战斗胜利测试 / 战斗失败测试 | victory / defeat test |
| 0x49 / 0x5a / 0x54 | ui_49 / ui_5a / ui_54 | 战斗结束 / 战场操作开始 / 战场撤退确认 | battle finished / start player control / retreat-death check pass |
| 0x4c / 0x4e / 0x4f / 0x53 | unit_op_4c/4e/4f/53 | 隐藏武将出现 / 武将方针变更 / 战场转向设置 / 战场撤退 | hidden unit appears / AI change / turn / retreat |
| 0x50 | unit_status | 战场动作设定 | battle unit **action/animation**, not a status |
| 0x55 | unit_move | 战场复活 | revive / re-enter a unit |
| 0x5f / 0x61 | duel_start / duel_end | 单挑结束 / 单挑胜负显示 | **close** the duel screen / start the fight + 胜负 banner (port names swapped) |
| 0x62 | duel_62 | 单挑阵亡 | duel result: loser greyed, exp award (nobody dies) |
| 0x68 | duel_setup | 单挑开始 | duel setup (classic or small-window by EV[4087]) |
| 0x69 | popup | 旁白 | narration message box (style 2) |
| 0x6a | op_6a | Game Over指令 | the original **exits the program**; the port should return to the title |
| 0x75 | set_s_image | S特殊形象指定 | u16 0x501000[person] battle sprite (wg2025: byte var) |
| 0x78 | data_transfer | 整型变量赋值 | field 29 = **x** and 30 = y although the editor labels them 纵/横; fields 31/32 are 杀敌数 / 可以控制 (the editor's CczString still says 战场行动标识 / 战场人物朝向) |

## Interpreter quirks the VM must get exactly right

* **Flags are bits**: flag i = bit `7 - i%8` of byte `reader+0x38 + i/8` (0x40c6a9 / 0x40c6cc); wg2025 used u32s.
* **`test_choice` (0x13) consumes the choice**: a match sets reader+0x2038 = −1 (0x4184a0), so testing the same
  value again after a hit is false.
* **Negative int32 args are EV references only for opcodes ≤ 0x6d** (READP 0x4183f7 reads the opcode byte at
  reader+0x2e). The converter resolves them statically to `{"var": n}`; handlers must use `ScriptHost.arg()` for
  every integer argument.
* **Goto level rule** (0x416c41; eex.md §4.2): leave the level only if the target is at/before the latest executed
  IF, or beyond the latest entered block's end while the goto is inside it. Identical to "always leave one level"
  for all 228 shipped gotos. The 7 casino "all in" loops (R_110/112/114/116/120/124/125) jump two static levels up,
  so every iteration nests one dynamic level deeper; the body then ends by running past its END into the next
  section header (invalid opcode → abort, no scene advance). All are in multi-section scenes, so a VM that simply
  stops at the end of the body list behaves the same.
* **goto_scenario**: GS+6 (u16) `= EV[4051]*200 + arg`, `EV[4051] = 0`, all 128 RPG actors cleared; the next file
  is counter+1 → `R_%03d` / `S_%03d` of `counter>>1`. R_150 is reached that way.
* **0x27 mode 3** also consumes EV[4051] (map = a4 + 100·EV[4051]); the background index of every mode is
  `byte + 256·EV[4027]` (EV[4027] persists).
* **0x14 / 0x7a / 0x16 / 0x69 / 0x12 / 0x15 … text** goes through 0x417df6 with the new `*` escapes (`*/N` EV value,
  `*.N` person name, `*+N` `*,N` `*-N` custom names) — `*/N` is not expanded while EV[4071] ≠ 0.
* **0x7a keeps its window open** while the next opcode is 0x7a; 0x14 re-shows the toolbar only when the next opcode
  is not 0x14 (both look one instruction ahead, like 0x32's parallel moves).
* **0x72 strings** are parsed byte-wise with "skip exactly one byte after each number" (eex.md §6). The converter's
  `ext.nums` already follows the engine (including the S_106 extra number that the engine ignores).
* **0x77 width**: when EV[4076] is 1 or 2 and the source is an immediate or `*PT`, writes to EVs are byte/word
  partial writes (upper bytes kept) and `+=`/`-=` wrap inside that width. EV[4076] is set by scripts 7,150 times.
* **0x79 compares unsigned** with modes 0 `==`, 1 `>=`, 2 `<=`, 3 `!=`, 4 `<`, other `>`; the comparison helper of
  0x36/0x37/0x3f/0x41 (0x421e00) is different: 0 `>=`, 1 `<`, other `==`.
* **0x78 HP write does not kill** (wg2025 did); 0x4d / 0x38 HP changes go through the EV[4044] routine (subtract
  floors at 1, never kills); 0x72 subs 1/2 power also clamps to [1, max].
* **`clear_flags` (0x0a)** zeroes 0x501b00..0x501fff — this includes the whole **SP table** (0x501c00) and the
  sortie-toolbar flag 0x501fff — and purges timed 特技 grants (0x72 sub 35, turns < 100).
* **Battle unit references**: arguments ≥ 0x404 are unit indices; with byte EV[4031] ≠ 0 arguments < 250 are unit
  indices too (0x41b882). 0x7a sets EV[4031] for its own duration. 0x78 ignores EV[4031].
* **Saves**: 0x501000..0x531000 is saved verbatim (all mod tables, EVs, PT and PT patch records); after loading,
  PT[200..480] patches are re-applied to engine memory (0x417020(1)). A port has to persist the same state (or the
  equivalent structures) and re-apply the patches it emulates.

## Must-implement differences from the wg2025 port (by use count)

1. 0x78 data_transfer (55.7k): new field map (eex.md §7.1), unit lookup over 250 × 0x30 records, side effects
   (level-up, 功勋 table, face mirror, S-image refresh), no death on HP write.
2. 0x79 test_int_var (44.3k): mode 2 is `<=`, modes 3/4/5; kind 1 through a pointer masked by EV[4076].
3. 0x14 dialog (42.4k): `&*.N` speaker, display-name lookup, `*` escapes, 3-digit unit speakers, toolbar handling.
4. 0x77 int_var_op (29.1k): EV[4076] width, op 5 = percent, op 6 = modulo, `-=` wraps.
5. 0x50 unit_status (27.3k): waits on any non-zero flag; unit selector; 250 slots.
6. 0x72 ext_command (18.3k): 特技 / 必杀 / growth-grade / 专属套装 tables (subs 5, 6, 36, 10 = 16.3k), strategy
   casts (1, 2), unit acted flag (21), timed grants (35), tint (14), pictures (12), menus (34), random (26) …
7. 0x4f (11.5k), 0x38 / 0x36 (20.3k): new attribute table and selectors; 0x26 / 0x25 (8.3k): new selectors.
8. 0x69 popup (6.8k): plain message box, no `|` prefix.
9. 0x4d (5.2k): ailment bit fields, EV[4044] HP/MP ops, buff value mapping, EV[4043] group animation.
10. 0x3e (4.2k): per-slot codes, item offsets 0 / 70 / 109, level 0xfe raw ids.
11. 0x16 (3.2k): EV[4071] history records. 0x08 (2.6k) menu flag. 0x13 (2.2k) choice reset. 0x75 (2.4k) S-image.
12. Battle setup 0x44–0x48, 0x4b, 0x4c, 0x55, 0x6d: 250 slots (player 0–19, ally 20+, enemy 60+), paging,
    16-byte deployment entries, 6.6 level formula, EV[4017]/EV[4057].
13. 0x27 backgrounds (EV[4027]), 0x11/0x27 EV[4051], 0x3b join formula and battle side switch, 0x3d item
    0xFFFF = EV[4025], 0x5e / 0x3c action tests, 0x6f EV[4067..4070], 0x5d, 0x51 (HP only), 0x52 (EV[4081]),
    0x7a three-portrait dialog, 0x68 small-window duel (EV[4087], not yet reverse-engineered).

## Open questions

* Small-window duel subsystem (0x68 with EV[4087] ≠ 0, 0x41e6a4 → 0x418f05; results in EV[4084]): not analysed.
* 0x48 equipment codes at battle start (users of 0x418dd0: 0x426551, 0x4081a6, 0x43bb57).
* [0x501bf9] last-action codes 3/4/6, [0x500ad7] (0x4f SE suppression), 0x41260a selectors in 0x3c.
* 0x72 sub 12 fields n3..n8 and the picture source (0x40da9a); sub 14 modes ≥ 2; sub 1/2 status effects with power ≠ 0.
* How 特技 values combine (person slots, class slots, sub 35 grants, sub 10 专属/套装 rows: 0x413009 / 0x402cf9 inside
  0x41301e) — rules/data side.
* Readers of 0x510c81/0x510c84 ("吃不完的米或酒" pokes), of 0x50f800 (R形象) and of u8 0x501a84[unit] (0x38 attr 15 add).

## Script-track findings (port implementation, verified in the disassembly)

* **block_end** (0x410738): with `next_scene` or at the body END of a one-section scene the scene advances even when
  `goto_scenario` ran at depth 0 (status 9 is then ignored); every shipped depth-0 `goto_scenario` sits in the last
  scene or in a multi-section scene, so it always ends the file. Each run_block level keeps its own ELSE result and
  next-scene / end-of-file marks; a goto that leaves a level drops them.
* **0x30 actor_appear** does nothing when the person already has an actor (0x428969 finds it → 0x80).
* **0x0a clear_flags** zeroes 0x501b00..0x501fff (0x140 dwords), then 0x473de1 (anim records, 0x510000 × 0xc80).
* **Talk / dialog**: 0x4137cd hides the toolbar only when [0x501fff] ≠ 0; 0x411991 re-shows it only outside a battle
  with GS+0x10 ≠ 0, with its buttons only in sortie mode ([0x501fff] ≠ 0 → 0x419959(tb, 0)).
* **Toolbar** (0x419959, dialog 0x129 ×4): 50×50 buttons at (w − 50(k+1), h − 90), k = 0 卖出 1 买进 2 装备 3 出征,
  EV[4032] bit k hides one; click handler 0x4196f8: 0/1 → shop 0x461cf6(sell), 2 → 0x461c88, 3 → 0x418597(1), then
  hide, GS+0x10 = 0, [0x4ae4c0] = 1. The first-use greetings ("%s，卖掉物资！" 0x48b49b…, answer "是！" 0x48b496 by
  the shop person 0x40c755: shop record of min(GS+6/2,127) +4 / +0, or 0x510cfa / 0x510cfc for 127) need
  0x40311e ([0x49cee4] ≠ 0xffff — the free-walk actor), so they never show in this mod.
* **Sortie builder 0x418597**: membership test 0x42ac58 = person +0x2a ≠ 0xff; forced entries 0 / 0xffff skipped;
  the protagonist leads unless the "may not sortie" ring holds a 0; param ≠ 1 counts one extra forced entry.
* **Title** (boot loop 0x404caf): BGM track 0x12, four U_select[11] buttons 176×44 at (432, 88 + 64i) (hover = frame
  i + 4 with SE 15): 刀兵初現 new game, 烽煙再起 load, 沙場點兵 the 環境 dialog (KANKYOU), 南山放馬 quit.
* **BGM** 0x24: GS+4 = track (0x418c99); id 0xff stops; tracks ≥ 0xff do nothing. **SE** 0x474777: file name
  format[id/100] % (id%100) from table 0x474878; nothing plays while a looping effect is active (wave object
  0x4b69b0 +4) or for ids with low byte 0xff.
* **Text** (0x417df6): escapes are only recognised at a 2-byte unit boundary; `*+N`/`*,N`/`*-N` copy at most 4 bytes.
* **Rename** (0x72 sub 0, 0x4081f2): refused if any person (itself included) already has the name; strcpy to +0x08,
  zero-fill to 9 bytes, tail from byte 8 to +0x3f (0x40a72c).
* **历史情报** records: "&" + colour + text, back to back without NULs; length u32 0x508994 excludes the final NUL;
  EV[4071] low byte 255 = 0x47826a: a text that is only the number deletes the record (and its 2 header bytes),
  otherwise replaces its text.
* **0x3d get_item** consumables (category 3): count table u8 0x493af0 + (id − 0xa0), + level + 1 (0x43e093);
  others "得到了%s！" (0x48e39c) box style 2 then the bag (0x40d693; full bag → error box + discard window).
* **0x3e set_equipment** story path 0x412db6: code 1 → take off (to the bag only when the op's weapon-level arg is 1,
  0x406cbc), else 0x407df1; exp after equipping 0x4201d5: level < max → 0, else 0xff (0xfe for a level-9 treasure
  at max). Auto level 0x407da3: treasures min(Lv/6 + 1, 9), others Lv ≥ 60 → 5 else (Lv%20)/4 + 1.
* **0x3b join** default equipment 0x407fd4: tier min(Lv/20, 2), level (Lv%20)/4 + 1 (5 from Lv 60) minus one
  (flag 1); weapon = the first usable weapon type 0..19, armour 20..25, item = byte table 0x482427[type>>1] + tier.
* **0x52 class change** 0x414b93 replaces an unusable weapon / armour with the default equipment (the old item is
  lost); 0x4149cf (EV[4081]) recomputes stats from growth sums, 功勋 and DATA.E5 HP/MP.
* **SV\SV.E5S** (0x10f bytes, fresh: bytes 4..7 = 1f 01 01 64): 0..2 endings, 3 window pattern, item + 0x10 the
  item records of 0x408b0d (item byte +0x18 bit 0).
* **Godot 4.7 bug** met by the port: `PackedByteArray.get_string_from_multibyte_char("GBK")` hangs on an
  unterminated buffer holding exactly one double-byte character; `TextExpand.from_gbk` appends a NUL first.
