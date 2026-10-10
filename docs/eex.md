# EEX scenario scripts (`RS/R_###.eex`, `RS/S_###.eex`) — 新改曹操傳 6.6

Reverse-engineered from `orig/Ekd5.exe` (the community "6.6 engine": Koei's 三国志曹操传 executable with ~83 %
of its code rewritten in place). VAs below are Ekd5.exe addresses (ImageBase 0x400000); "wg2025" refers to the
previous port (`rea`, exe `wagan.wa`), whose addresses and mod semantics do **not** carry over.

Converter: `tools/eex.py` → `game/assets/scripts/<file>.json` (+ `opcodes.json`) and `extract/eex_txt/<file>.txt`
(indented disassembly). **All 249 scenario files parse with zero errors**: every scene, section and IF-block length
agrees with the parsed instruction stream, every block ends with its END, all 228 gotos land on instruction
boundaries, all strings decode as GBK (see §2). 670,689 instructions in total.

Official opcode names below are the 6.x editor's (`修改器與修改記錄/剧本编辑器v0.24/CczString.ini`, GBK);
"port name" is the JSON `name` = Godot handler `op_<name>`.

---------------------------------------------------------------------------------------------------------

## 1. Files and scenario progression

| item | value |
|---|---|
| scenario counter | **u16 `GS+6`** (GS = game-state object @0x4b0770; read 0x43ad32). wg2025: u8 GS+7. |
| file name | loader 0x417eea: `n = GS+6`; format `"RS\\R_%s.EEX"` (n even) / `"RS\\S_%s.EEX"` (n odd) @0x48b394/0x48b3a0 with `%s` = `n>>1` printed `%d` and left-padded with `'0'` to 3 digits (0x4196c8 → 0x41800d). So n = 2k → `RS/R_k` (story/town, RPG mode), n = 2k+1 → `RS/S_k` (battle). The 6.6 patch list ("修改劇本名稱字數" @0x409a43/0x417f23 = 3) widened the old 2-digit names. |
| shipped files | R_000…R_126 without R_100 and R_109, plus R_150; S_000…S_125 without S_100, S_108, S_109 (249 files). R_150 is reached through the >255 rule below. `單挑.eex`, `記錄寫法.eex`, `記錄寫法---.eex`, `地雷測試.eex` in RS/ are editor scratch files the engine never loads (the converter skips them). |
| next file | when a body run ends with code 4 ("file finished", §4.2) the manager 0x41811f does `GS+6 += 1` (u16), loads the next file (0x417eea → `Reader::load` 0x40fe3d on the global reader @0x492f90), resets the reader (vtable[0] 0x40ffd0) and re-initialises (0x417e84, 0x417e95). |
| goto_scenario (op 0x11) | handler 0x42547a: `v = u16 arg (tag 0x37, no EV indirection)`; clears all 128 RPG actors (0x426bb2); **`GS+6 = EV[4051]*200 + v; EV[4051] = 0`** (0x418ab1); returns 9 (end of file). The file then finishes (§4.2) and the next file loaded is counter `GS+6 + 1`. EV[4051] (@0x505f4c, "剧本破百") is the escape for counters > 255: one unit = 200 counter steps = 100 file numbers. 234 uses in 110 files. |
| new game | n = 0 (R_000). |
| save slots | the load/save screen (0x4099aa) shows `R_%s`/`S_%s` with the 3-digit number of `counter>>1` (strings @0x48b54b/0x48b531). |

## 2. Container format (unchanged from CCZ / wg2025)

```
0x00  char[4]  "EEX\0"                  (0x48b348)
0x04  u8 major = 1, u8 minor = 2         loader 0x40fe3d accepts major <= 1 and (major < 1 or minor <= 2)
0x06  TLV list {u16 type; u16 len; u8 data[len]} terminated by type 0 (v1.0 files: fixed 16-byte header).
      All shipped files: just "00 00 00 00".  type 1 = a string sent to the editor via DDE
      (DdeClientTransaction) that also sets reader+0x34: one extra u16 before every instruction and every
      section (editor debug mode) - unused, the converter rejects files with TLV entries.
0x0A  u32 scene_offset[N]    N = (scene_offset[0] - 0x0A) / 4    (absolute file offsets; 0x40fc03)
```

**Scene** (场景) at `scene_offset[i]`:
```
u16 nsections
section[nsections]:
    u16 section_len                    // bytes after this field up to the next section
    <condition list>                   // instructions, terminated by op 0x00; no IFs
    u16 body_len                       // bytes after this field
    <body block>                       // instructions, terminated by op 0x00; may contain nested IF blocks
```

**Instruction**: `u16 opcode` + the opcode's fixed list of *tagged* parameters. Parameter reader READP
0x4183f7(tag):
```
u16 tag ; value      tag 0x04 -> u32 (little endian)
                     tag 0x05 -> NUL-terminated GBK string
                     any other tag -> u16
```
A tag mismatch does not consume the value: READP returns 0x80000000 (tags 4/5) or 0x8000 (others) and the
handler returns 5 (error). The only untagged values are the flag lists of op 0x05 ("tag 1").

**EV indirection** (EV = u32[4096] @0x502000, "整型变量"):
* tags **0x02, 0x38, 0x39**: a u16 in **0xEFFF..0xFFFE** reads `EV[0xFFFE - v]` (0xFFFF stays literal = none/-1).
  Same rule as wg2025 (there the EV array was @0x55b000). 6,347 uses (most: 0x4d arg1 2,459, 0x78 index 1,652,
  0x52 640, 0x75 424, 0x36 325, 0x26 240, 0x15 206).
* **new in 6.6**: tag **0x04** with a **negative** int32 reads `EV[-v]` — but only while the opcode being
  executed (`reader+0x2e`, stored by the dispatcher) is **≤ 0x6d**. For 0x6e..0x7b (0x76 goto, 0x77/0x78/0x79,
  0x72 …) int32 args are raw. In the shipped scripts only op 0x6b uses it (2 args); it matters for EV-computed
  args of every op ≤ 0x6d, e.g. `set_flag` with a computed flag number.
* `eex.py` emits both as `{"var": idx}` (resolved by `ScriptHost.arg()`).

**IF blocks**: op 0x01 is followed by exactly one condition instruction (any opcode), then `u16 len` and a child
block of `len` bytes ending with op 0x00. No shipped block has dead code after an inner END (wg2025 had 4).

**Strings** are GBK (the engine's own UI strings are GBK, e.g. "可以吗？" @0x48b3ab). The text is mostly traditional
characters (which GBK encodes). The only non-GBK sequence is `A1 40` (25×, place names such as "陈留?曹操军大本营"):
the Big5 full-width space typed by the authors; GBK leaves A140 undefined. `eex.py` maps it to U+3000.

## 3. Script-visible state (overview; details §7–§9)

| storage | address | script access |
|---|---|---|
| boolean flags (变量) | **bit-packed**: flag i = bit `7 - i%8` of byte `reader+0x38 + i/8` (reader @0x492f90 → bytes @0x492fc8, room for 65,536 flags; get 0x40c6a9, set 0x40c6cc). wg2025 used one u32 per flag. Numbers used: 0..3002. | op 0x05 test, 0x0b set, 0x0a clears 0..255 |
| choice result | `reader+0x2038` (i32) | op 0x12 writes 1-based index; op 0x13 compares and **resets it to -1 when it matches** (0x4184a0) |
| event parameters | `reader+0x1c` → slots (1 = clicked person, …) | set by the drivers before a poll |
| EV | u32[4096] @0x502000 (config EVs 4016–4095 @0x505ec0..0x505ffc, §9) | 0x77/0x79/0x78, EV indirection |
| PT (指针变量) | u32[481] @0x506000 (PT[200..480] are "patches" re-applied after loading, §7.1) | 0x77/0x79 pointer kinds (§7) |
| GS | 0x4b0770 | GS+0 trigger bits (0x20 = RPG click event), GS+6 u16 scenario counter, GS+0xc gold, GS+0x10 menu flag, GS+0x12 忠奸 |
| save block | 0x501000..0x531000 is saved verbatim with the game (§7.2) | all mod tables |

## 4. Execution model (interpreter 0x4100a1 / 0x4105ff / 0x410857 / 0x410738, manager 0x4180c1)

Same structure as CCZ/wg2025 except the goto level rule (§4.2). Reader object: global @0x492f90, vtable 0x486610
`[0x40ffd0 reset, 0x40fe3d load, 0x4109e6 execute, 0x480612 busy (always 0), 0x418bbc peek u16]`; `+0x04` scene
index, `+0x08` byte counter, `+0x0c` read pointer, `+0x10` opcode of a suspended instruction or 0xFFFF, `+0x14`
depth of the suspension or -1, `+0x20` file buffer, `+0x24` sections of the current scene, `+0x28` active, `+0x2c`
running a body, `+0x2e` (byte) opcode being executed, `+0x30` header size, `+0x34` TLV debug flag, `+0x38` flags,
`+0x2038` choice.

Dispatcher 0x4109e6: `op = u16; reader+0x2e = op; op > 0x7b → 5; op 0 → 3 (END); op 1 → 4 (IF) and
`[0x500ab0] = address of this IF opcode`; else `handler[op-2](reader)` (table 0x410a38). It returns the status in
eax and the opcode in ecx — **except for op 0x76**, where ecx is the goto handler's verdict (0x76 = leave the
level, 0 = stay).

Status codes: **0** false, **1** ok/true, **2** yield, **3** END, **4** IF, **5** error, **6** ELSE, **7** next scene
(0x0d), **8** abort section (0x0c), **9** end of file (0x11).

### 4.1 Section selection (`select` 0x4100a1)
1. If an instruction is suspended (`+0x10 != 0xFFFF`): ask vtable+0x0c (0x480612 always says "done"), clear and
   resume (4.2 rebuilds the nesting down to the saved depth without re-reading block lengths).
2. Else, if the file is active and no body is running: seek to the current scene, `+0x24 = nsections`; for every
   section in order run its condition list until END; the section qualifies if every instruction that returned 0
   or 1 returned 1 (other codes don't veto). **The last qualifying section wins.**
3. Run its body (manager → 0x41811f → `run_child(1, depth 0)`).

### 4.2 Block execution (`run_block(depth)` 0x4105ff, `run_child(exec, depth)` 0x410857, `block_end` 0x410738)
```
run_child(exec, depth):                 # pointer at a "u16 len" (section body or IF child block)
    if file not active: return 4
    if not resuming:
        len = u16;  BLOCK_END = ptr + len          # u32 [0x500ab4], also for skipped blocks and bodies
        if not exec: ptr += len; return 0
    return run_block(depth)                       # (depth 0: +0x2c "running" while inside)

run_block(depth):
    last = 1; next_scene = 0; end_file = 0
    loop:
        r, ecx = execute(next instruction)
        if ecx == 0x76 and depth > 0: return 0                # goto that leaves the level (see below)
        r > 9: return 1
        2: suspend (+0x10 = opcode, +0x14 = depth); return 2
        4: (IF) c, ecx = execute(condition)
               if ecx == 0x76 and depth > 0: return 0
               c <= 1: last = c;  c == 5: return 1
               take = c == 1 or (c == 6 /*ELSE*/ and last == 0)
               x = run_child(take, depth+1);  if x: return x if x <= 5 else 1
        5, 6: return 1 ;  7: next_scene = 1 ;  8: return 5 ;  9: end_file = 1
    until r == 3                                          # END of this block
    return block_end(depth, end_file, next_scene)

block_end(depth, end_file, next_scene):
    if next_scene or (depth == 0 and nsections == 1):
        scene++; if scene < nscenes: return 3
    elif scene < nscenes and not end_file: return 0
    active = 0; return 4                                  # file finished → manager loads counter+1
```
Consequences (as in wg2025): ELSE runs iff the latest IF test at the same level returned 0; a one-section scene
is a linear cut-scene (its body end advances the scene); multi-section scenes are event loops left via 0x0d/0x11;
0x0d / 0x11 only take effect at the END of the current block, then propagate up.

**Goto (op 0x76, handler 0x416c41) — changed in 6.6.** `p0 = address of the goto's parameter (goto + 2)`;
`ptr += (signed) arg` (relative to the end of the 8-byte instruction); then
```
leave = target <= [0x500ab0] (latest IF executed)  or  (target >= [0x500ab4] (latest block end) and p0 < [0x500ab4])
```
and ecx = 0x76 if leave else 0. wg2025 always left the current level when depth > 0. So in 6.6 a jump *within*
the latest-entered block, or a forward jump after an inner block has finished, keeps the nesting level. The JSON
keeps the byte offsets needed to replay this exactly: `off` on every IF and goto, `end_off` (block end) on every
IF, `target.off` on gotos, `body_end` on every section.
Shipped scripts: all 228 gotos are loop-backs to (or to a label before) the innermost enclosing IF, i.e.
`leave` is true on every possible path → **identical to the wg2025 rule** for these files. 221 land one static
level up. **7 land two levels up** (the casino "all in" loop, R_110/112/114/116/120/124/125, `goto` at depth 8 →
comment at depth 6): every iteration therefore runs one dynamic level deeper (leave pops only one level), and when
the body's final END is reached at dynamic depth k > 0, `block_end` returns 0 and the original keeps reading
**past the body**: the next u16 (the following section's length, 0xe7..0x41d, all > 0x7b) is an invalid opcode →
status 5 → the body aborts with status 1 (no scene advance). All 7 are in multi-section scenes, so this is the same
as a normal body end; the port VM (which simply stops at the end of the body list) matches.

### 4.3 Yield / async
Instructions that start something asynchronous return 2; the interpreter suspends and the drivers decide when to
poll again (busy check 0x480612 is a stub returning 0 — the RPG driver 0x41839c refuses to poll (returns 6) while
any of the 128 actors @0x49cf68 (64 B each) has bit 0x8000 set with state < 3).

### 4.4 Who runs the script
* Main loop 0x4180f9: `while (([0x4abf9c] & 0x6e) == 0) if ([0x4abf9c] != 2) manager()`.
* Story (R): 0x41839c (tick, waits for actors) and 0x418162 (click: `GS+0 |= 0x20`, event slot 1 = person,
  one poll, restore GS+0).
* Battle (S): manager calls at 0x44c61d, 0x44ec4c, 0x44ece2, 0x44f0c1 (battle turn checkpoints).

## 5. Opcode reference

R / S = uses in story / battle files, F = files. Layout = parameter tags (04 u32, 05 string, others u16). Handler =
table 0x410a38 entry. "T" = test (returns 0/1). "Same" = same behaviour as wg2025 (rea docs/eex.md), with the
6.6 data structures (§3, §7, §8). Use counts include IF conditions.

| op | official | port name | R | S | F | layout | handler | 6.6 semantics |
|---|---|---|---|---|---|---|---|---|
| 00 | 事件结束 | end | 14562 | 99555 | 249 | — | inline | END of the block / condition list (status 3). |
| 01 | 子事件设定 | if | 11228 | 86865 | 249 | — | inline | IF (status 4); sets u32 [0x500ab0] = its address (goto rule §4.2). |
| 02 | 内部信息 | comment | 3637 | 21721 | 249 | 05 | 41177d | comment / section title; true. |
| 03 | else | else | 158 | 5880 | 150 | — | 4834c6 | ELSE (status 6), only meaningful as an IF condition. |
| 04 | 询问测试 | test_yes_no | 42 | 0 | 26 | 26 | 4116ff | T: yes/no box 0x42f699(1, "可以吗？") == arg. Same. |
| 05 | 变量测试 | test_flags | 3226 | 16164 | 247 | tag35 n, n×u16, tag35 m, m×u16 | 41179f | T: all n flags set and all m flags clear (bit-packed flags §3). |
| 06 | 我军出场限制 | battle_select_units | 663 | 0 | 121 | 2e 04 38×5 39×5 | 415b4f | **changed** storage, §11.1. |
| 07 | 出战测试 | test_pending | 122 | 0 | 119 | — | 40b900 | T: once after toolbar 出征 (flag 0x4ae4c0, cleared when read). Same. |
| 08 | 菜单处理 | **set_menu** (wg2025 set_result) | 2320 | 247 | 248 | 2e | 41431d | GS+0x10 = v (menu on, 0x41196c); scene mode 2 → also 0x40dff9; v ≠ 0 and toolbar window[0] exists → re-show the toolbar (0x411991). Values 0/1. |
| 09 | 延时 | delay | 10279 | 4273 | 239 | 04 | 415b21 | blocking delay v × 100 ms (timer 0x4b1b18 = ticks + 2v, tick = GetTickCount/50); 0 = nothing. Same. |
| 0A | 初始化局部变量 | clear_flags | 265 | 55 | 175 | — | 415aca | clear flags 0..255; zero **0x501b00..0x501fff** (battle bytes incl. tint/level offset, the **SP table 0x501c00**, toolbar flag 0x501fff); 0x473de1: 3 × 12 B @0x501aac (0x40dd0b), memset(0x510000, 0, 0xc80), purge timed 特技 grants (0x42fc8c). wg2025 cleared mod bytes 0x569f00/0x55ac06/0x55e9d4. |
| 0B | 变量赋值 | set_flag | 2293 | 13662 | 246 | 04 27 | 401925 | flag[arg0] = (arg1 ≠ 0); arg0 is an int32 (negative → EV[-v], §2). |
| 0C | 结束Section | exit_section | 0 | 0 | 0 | — | 481156 | abort the body (status 8). Unused. |
| 0D | 结束Scene | next_scene | 155 | 535 | 245 | — | 4103ac | GS+0x10 = 0 (0x41196c(0); scene mode 2 → 0x40dff9); status 7. Same. |
| 0E | 战斗失败 | ui_0e | 0 | 236 | 122 | — | 415890 | battle: game over (0x4144ab(3)). Same. |
| 0F | 结局设定 | screen_mode | 3 | 0 | 1 | 12 | 4158af | ending: v < 3 → record ending 0x41a1c6(v); 0x42bed5(v, 0): stop audio, **play video 2 (End.Avi)**, ending show 0x4317ab(v), then 0x415692 (= 0x6a). |
| 10 | 许子将指导 | nop | 0 | 0 | 0 | — | 42bce9 | 许子将 advice UI (not a nop in 6.6). Unused. |
| 11 | 剧本跳转 | goto_scenario | 202 | 32 | 110 | 37 | 42547a | **changed**: clear the 128 RPG actors; GS+6 (u16) = EV[4051]·200 + v; EV[4051] = 0; status 9 (§1). |
| 12 | 选择框 | choice | 568 | 258 | 203 | 05 02 | 411aa6 | **changed**: options = text lines (`*` escapes, numbered "1." … by the engine, ≤ 6); arg1 = **portrait person** (0xFFFF → 0; the port read it as default option); window 0x42de7d (≥ 3 rows); result index+1 → reader+0x2038. arg1 == 0x3ff with EV[4083] ≠ 0 → 舌战/单挑 instead (unused). |
| 13 | case | test_choice | 1546 | 633 | 203 | 04 | 41173b | T: choice == arg; **on a match the choice is reset to −1** (0x4184a0). |
| 14 | 对话 | dialog | 16690 | 25701 | 248 | 05 | 4136ad | **changed**, §11.2. |
| 15 | 对话2 | unit_say | 102 | 1780 | 131 | 02 02 05 | 41396a | text (`*` escapes). **Story (new)**: portrait window for person a0 (0x42d5b0(text, a0, 0)). Battle: a1 ≠ −1 → bubble at a0's unit (0x45972e / 0x4596ce, unit lookup 0x41b882), else 0x4596aa. |
| 16 | 信息 | info | 395 | 2836 | 204 | 05 | 413a35 | **changed**: EV[4071] = 0 → box without portrait 0x42d5b0(text, −1, 0x20); ≠ 0 → 历史情报 record (§11.3). EV[4071] reset to 0. |
| 17 | 场所名 | place_name | 553 | 1 | 124 | 05 | 417d6c | expand into 0x4b0758, draw 0x476612; if u8 [0x501bfb] ≠ 0 also message box 0x42f699(2, text). (wg2025: mod code.) |
| 18 | 事件名称设定 | title_text | 268 | 5 | 126 | 05 | 417dc8 | expand into 0x49f1cc, draw 0x47650f; same [0x501bfb] box. |
| 19 | 胜利条件 | victory_cond_text | 0 | 203 | 123 | 05 | 413ba0 | expand into 0x496ca0, **store only** (no window); u8 0x4b3d10 = 0. Same as wg2025 (the port shows a dialog here). |
| 1A | 显示胜利条件 | battle_goal_text | 0 | 202 | 123 | 05 | 413bdb | battle: panel 0x44be80 with the stored lines (≤ 30 bytes each, `*` escapes) plus a line from the turn limit u8 0x4b3d0b. |
| 1B | 撤退信息是否显示设定 | op_1b | 0 | 195 | 33 | 02 27 | 413c17 | battle: unit(person)+0x1f = (arg ≠ 0) (retreat message on/off). Same. |
| 1C | 绘图 | fade_out | 1469 | 124 | 247 | — | 413e49 | scene mode 2: [0x501bfb] = 1, 0x41c39d; mode ≠ 3: redraw. Equivalent. |
| 1D | 调色板设定 | fade_in | 1131 | 125 | 248 | — | 413ec7 | mode 2: clear 8000 B @0x4a8ac0, 0x426c3b, 0x481107; then 0x411600 (clears [0x501bfb]). Equivalent. |
| 1E | 武将重绘 | wait_frame | 1033 | 0 | 103 | — | 41e1a5 | yield (2) until actors are idle. Same. |
| 1F | 地图视点切换 | scroll_to | 0 | 87 | 27 | 04 04 | 42b391 | 0x45503f(x, y); no-op while byte EV[4087] ≠ 0. |
| 20 | 武将头像状态设置 | op_20 | 0 | 0 | 0 | 4a | 416fd6 | unused. |
| 21 | 战场物体添加 | map_mark | 0 | 831 | 26 | 04 04 10 26 26 | 413efc | battle: kind 0 → 0x4560f3(x, y, 0x1a, 0, a3, a4, 0) (obstacle, shares 0x58's code/table, EV[4036]/EV[4050]); kind 1 → revert 0x456670(x, y, 0, a3). wg2025 kind 0 ignored a3/a4. |
| 22 | 动画 | set_weather | 1 | 0 | 1 | 1b | 42c3c7 | **video** (0x42f5c9): 0 Logo.Avi, 1 Open.Avi, 2 End.Avi, 3 Press.Avi (table 0x4ce210), ≥ 4 `Mov%03u.Avi` (id−3); id 1 unskippable. Only use: `22 1`. |
| 23 | 音效 | play_music | 1012 | 1461 | 221 | 1e 04 | 4157b9 | **sound effect** (0x474a44): id 0–99 `WAV\SE%02u`, 100–199 `SE_M_%02u`, 200+ `SE_E_%02u`; mode 0 loop, 1 once, 0xff stop, n = play n times synchronously. Same as the port. |
| 24 | CD音轨 | play_sound | 1389 | 432 | 248 | 09 | 4157fa | **BGM**: 0xff → GS byte = 0xff + stop; else track id+2 → `SoundTrk\%02u-AudioTrack %02u.mp3` (0x42f789), not restarted if already playing (files 02–207). Same. |
| 25 | 武将进入指定地点测试 | test_unit_at | 0 | 468 | 100 | 02 04 04 | 411827 | T: battle; selector < 0x4fe (0x45b50a): 0x400 any, 0x401 side class 1, 0x402 not side 1, ≤ 0x403 person, **0x404+N unit index**; unit in state 2 with HP > 0 at (x, y). |
| 26 | 武将进入指定区域测试 | test_unit_in_area | 0 | 7806 | 122 | 02 04 04 04 04 | 40f397 | T: battle: rect version of 0x25 (0x45b597). Story path (new, unused): true once when RPG actor 0–24 enters the rect (0x411f75, state bytes 0x501ae0). |
| 27 | 背景显示 | change_scene | 1519 | 127 | 247 | 2d 0c 1a 1c 15 | 413d13 | **changed**, §11.4. Yields. |
| 28 | 自由R启动指令 | op_28 | 77 | 0 | 17 | 36 | 406fd9 | v = 0 → hide the 4 toolbar buttons (0x429cab); v ≠ 0 → [0x501fff] = 0, create/position the toolbar without showing (0x419959(tb, 1)). |
| 29 | 地图头像显示 | op_29 | 389 | 0 | 60 | 02 04 04 | 417143 | show portrait at (x, y) (0x42c4a5). Same. Quirk: person ≥ 0x400 returns 0 before reading x, y (never happens). |
| 2A | 地图头像移动 | op_2a | 209 | 0 | 59 | 02 04 04 | 4171bc | move portrait. Same (same quirk). |
| 2B | 地图头像消失 | op_2b | 74 | 0 | 33 | 02 | 4172ec | hide portrait (person < 0x400). Same. |
| 2C | 地图文字显示 | caption | 995 | 0 | 84 | 05 26 26 26 | 417235 | map text (0x4332a6; 0xffff → 0), `*` escapes. Same. |
| 2D | 武将点击测试 | test_clicked | 949 | 0 | 119 | 02 | 41391a | T: GS+0 & 0x20 and event slot 1 == person. Same. |
| 2E | 武将相邻测试 | test_adjacent | 0 | 1494 | 120 | 02 02 26 | 4119c2 | T: 0x45afca (same code as wg2025). |
| 2F | 清除人物 | op_2f | 1060 | 0 | 123 | — | 413647 | clear actors (0x426c3b). Same. |
| 30 | 武将出现 | actor_appear | 4038 | 0 | 123 | 02 04 04 2b 0d | 411dae | story 0x428c8e(p\|0x1000, x, y, dir&3, act > 18 → 0); battle 0x40216a(p). Same. |
| 31 | 武将消失 | actor_select | 988 | 1203 | 214 | 2c 02 04 04 04 04 03 | 413522 | remove actor / units (as wg2025; persons 0x400..0x402 = current unit; the 4 ints must be ≥ 0 or error). |
| 32 | 武将移动 | actor_move | 2790 | 1906 | 208 | 40 02 04 04 04 2b | 4133b2 | story same (parallel if the next op is 0x32, else yield); battle mode 1 slot limit now **< 20**. |
| 33 | 武将转向 | actor_face | 5893 | 0 | 123 | 02 0d 2b | 411e79 | 0x428845. Same. |
| 34 | 武将动作 | actor_action | 12495 | 0 | 124 | 02 0d | 411ede | Same. |
| 35 | 武将形象改变 | **set_r_image** (wg2025 actor_state) | 466 | 0 | 113 | 02 13 | 411f2d | u16 0x50f800[person] = v (R形象 table, = 0x78 field 0); no bounds check. |
| 36 | 武将状态测试 | test_attr | 361 | 9032 | 135 | 02 23 04 24 | 4112fa | **changed**, §11.5. |
| 37 | 钱、章节编号、忠奸测试 | test_resource | 149 | 14 | 33 | 28 04 24 | 4118bd | T (cmp 0x421e00: 0 ≥, 1 <, other ==): kind 0 gold GS+0xc; **kind 1 = min(GS+6 / 2, 127)** (the current file number, not 0x510cf9!); kind 2 忠奸 GS+0x12. |
| 38 | 武将能力设定 | set_attr | 2345 | 8583 | 231 | 02 23 34 04 | 412007 | **changed**, §11.5. |
| 39 | 武将等级提升 | **level_up** (new) | 72 | 27 | 11 | 02 04 | 4148f8 | (person, n): battle 0x400..0x402 → current unit; silent level-up 0x4073f3(rec, n, 0): Lv += n (≤ 255), each of the 7 stats grows n times (0x4250b6 + 0x406eca, or 0x43a409 when EV[4094]); Lv > 99 → exp 0xff; battle unit max HP/MP refreshed. |
| 3A | 钱、章节编号、忠奸设置 | set_resource | 485 | 9 | 55 | 28 34 04 | 41481f | kind 0 gold, cap **999,999** (add 0x40da71, sub saturating 0x40d7ee); **kind 1: u8 0x510cf9 = v** whatever the op; kind 2 忠奸: op 0 set min(v, 100), 1/2 add (≤ 100) / sub (≥ 0) with gauge animation (0x40d3bc). |
| 3B | 武将加入 | join | 220 | 123 | 74 | 02 0e 3e | 414790 | **changed**, §11.6. |
| 3C | 武将加入测试 | **test_last_action** (new; official name misleading) | 0 | 74 | 35 | 02 0e 3a | 415d34 | T, battle only: u8 [0x501bf9] (last action: 1 attack, 2 strategy, 5 item, 6 ?) == a1·2 + a2 + 1 (a1 0xff → 2) and the acting unit [0x4b5df0] is `person` (0x400 = anyone, > 0x400 → selector 0x41260a). E.g. `119 0 0` / `119 0 1`: 119 just attacked / used a strategy. |
| 3D | 获得物品 | get_item | 331 | 696 | 173 | 17 49 26 02 | 4143cb | item **0xFFFF → EV[4025]**; level/flag 0xFFFF → 0, level 0 = auto for equipment; story 0x4144ef (message box 2, bag); battle 0x459950 (fly-to-unit animation when flag ≠ 0; selectors ≥ 0x400); record 0x408b0d. |
| 3E | 加入装备设定 | set_equipment | 384 | 3857 | 176 | 02 3b 49 3c 49 3d | 416326 | **changed**, §11.7. |
| 3F | 回合测试 | test_turn | 0 | 652 | 111 | 04 24 | 411664 | T: turn (u8 0x4b3d0a + 1) cmp arg (0x421e00). Same. |
| 40 | 行动方测试 | test_side | 0 | 773 | 116 | 48 | 4116bc | T: phase byte 0x41c325(0x4b3d08) == arg & 0xff; battle only. Same. |
| 41 | 战场人数测试 | test_units_in_area | 0 | 403 | 97 | 03 04 24 3f 04 04 04 04 | 411507 | T: count units (side −1→6, area mode −1→0, rect; 0x428df1) over 250 slots; cmp 0x421e00: 0 ≥, 1 <, else ==. Same apart from 250 slots. |
| 42 | 战斗胜利测试 | test_event5 | 0 | 103 | 101 | — | 411bd0 | T: victory flag of the battle object (+1), or a unit **60..249** in state 3/4 is the boss (reader+0x3d04 bit 0, person +0x3d06), or no enemy left; event slot 5. (wg2025 enemies 35..114.) |
| 43 | 战斗失败测试 | test_event6 | 0 | 110 | 110 | — | 411ba5 | T: a unit 0..**60 inclusive** in state 3/4 is the lose-person (reader+0x3d08/+0x3d0a); else if unit 0's person == 0: no unit 0..**20** in state 1/2; else no side-0 unit. Event slot 6. The inclusive bounds (first ally / first enemy slot) are the original's. |
| 44 | 战斗初始化 | battle_init | 0 | 124 | 123 | — | 4121e2 | page counters u16 0x500ad4 = 0; clear u16[256] @0x508a00 and flags 0..255; entries 0..249: person = sortie list[i] (i < 20, until 0xFFFF) else 0xFFFF, flags 0; fill 1000 B @0x4930c8 with **byte EV[4017]** (initial 气); zero 0x640 B @0x4934b0; 0x41c96d. |
| 45 | 战场全局变量 | battle_settings | 0 | 197 | 123 | 26 26 04 3e 32 02 32 02 47 22 | 4122c3 | a0 ≠ 0 → u16 0x494fd0; a1 → u8 0x496c9f; a2 → u8 0x496c9e (turn limit); a3 level offset (−1→0; > **100** → −(a3−100); i8 @0x501bf4; wg2025 threshold 50); a5 boss → 0x496c96 + flag 0x496c94; a7 lose-person → 0x496c9a + flag 0x496c98; a8 (−1→0) → 0x496e21; a9 (−1→**0**, wg2025 1) → 0x496e22; **EV[4057] = 0xFFFF**. |
| 46 | 友军出场设定 | battle_allies | 0 | 126 | 123 | 20 × [02 26 04 04 2b 3e 45 07 02 04 04] | 419b61 | → 0x41240b: entry j → slot **20 + 20·page + j** (page u8 0x500ad4, ++ per op). Level code (0x4123c8): base = sortie average (0x4184dd) + i8 0x501bf4 (min 1); code < 101 → min(base+code, **110**); ≥ 101 → max(base−(code−100), 1) (wg2025: < 51 cap 70, ≥ 51 −(code−50)). Defaults: hidden −1→0, AI −1→1, level −1→0, 0x45 field −1→2. Per-person battle record (0x4264c6): +2, +3 level, +0xc AI, +0xe target person (AI 3/5) or tx,ty (AI 4/6). |
| 47 | 敌军出场设定 | battle_enemies | 0 | 132 | 123 | 80 × [02 26 26 04 04 2b 3e 45 07 02 04 04] | 407fbc | as 0x46 with slot **60 + 80·page + j** (page u8 0x500ad5); the extra 0x26 (2nd) sets entry flag bit 2. S_018 has 3 × 0x47 (two in an IF/ELSE), so enemy slots reach 219. |
| 48 | 敌方装备设定 | battle_equipment | 0 | 3954 | 121 | 02 3b 49 3c 49 3d | 411cdb | first entry 20..249 with that person: +9 weapon code, +0xa armour, +0xb accessory, +6/+7 levels (−1→0); returns 0 if none. Code decoding at battle start not traced (wg2025: 0 default, 1 take off, ≥ 2 item). |
| 49 | 战斗结束 | ui_49 | 0 | 535 | 123 | — | 417ad7 | battle: 0x4144ab(2) → 0x40be38(0x4b3d08, 2) (battle finished). Same role. |
| 4A | 我军出场强制设定 | battle_prepare | 0 | 38 | 10 | 04 38 38 38 38 38 39 39 39 39 39 | 415bd0 | int arg ignored; 5 × 0x38 → u16 ring[20] @0x4b09dc (index u32 0x4b0a2c, +5); 5 × 0x39 → u16 ring @0x4b0a04 (index 0x4b0a30); u8 0x4b09db = 1; sortie builder 0x418597(0): protagonist first iff no 0x4b0a04 entry is 0, forced members, selection UI 0x45e6b3 if max ≠ count; result u16[] @0x48b350. Shares 0x415c0d with 0x06. |
| 4B | 我军出场设定 | op_4b | 822 | 1031 | 191 | 04 04 04 2b 26 | 415e33 | slot, x, y, dir, hidden (−1→0). EV[4057] == 0xFFFF (battle): entry(slot) with person ≠ 0xFFFF and (flags & 3) == 0 gets x, y, flags = dir bits \| hidden·4. Else (R-file sortie preview, EV[4057] = map no.): u32 @0x507680 + 3·slot = {x, y, hidden, 0xFF}. (wg2025: mod table 0x55e9d8.) |
| 4C | 隐藏武将出现 | unit_op_4c | 0 | 4013 | 116 | 40 02 04 | 414adc | mode −1→0. 0: unit via selector; if state ≠ 2 → appear at its deployment entry (0x409229: entry x,y, flag 8, **SE 15**, scroll, delay 4). 1: unit index arg2 (any slot), must be state 1. (wg2025: slot < 15, hidden only, SE 42.) |
| 4D | 武将状态变更 | unit_op_4d | 0 | 5171 | 123 | 41 02 04 04 04 04 04 03 2f 18 30 04 04 | 415551 | **changed**, §10.1. |
| 4E | 武将方针变更 | unit_op_4e | 0 | 3776 | 111 | 2c 02 04 04 04 04 03 07 02 04 04 | 4146d4 | AI change (int args & 0xff). mode 0: 0x459d95(unit via selector, ai 0..7 via table 0x48e379, target, x, y); rect: 0x459e79 (raw side +5), rect clamped to the map. Same + selector. |
| 4F | 战场转向设置 | unit_op_4f | 0 | 11530 | 123 | 02 02 2b 26 26 26 | 415f47 | unit, target (0xFFFF → face dir arg2), back (> 0 turn away), scroll (≠ 0 → scroll + 8 ticks), wait (≠ 0 → 8 ticks); SE 6 on turn unless u8 0x500ad7 == 2. Same + selector. |
| 50 | 战场动作设定 | unit_status | 0 | 27300 | 123 | 02 46 26 26 | 415fee | battle only; action −1 no-op; unit via selector (person < 0x400 search over 250), state 2; actions 0..12; pre/post wait 8 ticks if the arg is **≠ 0** (wg2025: == 1 after −1→1) and action ∉ {0, 11}; actions 0/6/7/10 end with a redraw whose params depend on byte EV[4087]. |
| 51 | 战场恢复行动权 | op_51 | 0 | 371 | 122 | — | 416276 | every on-map unit: flag 6 (0x406690), clear all ailments, **HP = max HP** (MP untouched — wg2025 also refilled MP); 0x453ac3, 0x44a88a. |
| 52 | 兵种改变 | op_52 | 1051 | 577 | 179 | 02 03 | 414bd4 | person (0x400..0x402 current unit, other ≥ 0x400 ignored) → class = arg (0x40e01f); unusable items dropped (0x414b93); **byte EV[4081] ≠ 0 → recompute abilities** (0x4149cf); battle: refresh unit; popup 0x479a01. |
| 53 | 战场撤退 | unit_op_53 | 0 | 3974 | 123 | 2c 02 04 04 04 04 03 26 | 41569e | mode 0: retreat unit (selector; 0x45a7a2 → 0x441744; flag −1→0); else all units of side (−1→6) in the rect (0x45a80f). Battle only. Same + selector. |
| 54 | 战场撤退确认 | ui_54 | 0 | 1 | 1 | — | 4144d2 | battle: 0x42bc14 (retreat/death check pass). |
| 55 | 战场复活 | unit_move | 0 | 1838 | 72 | 40 02 04 04 04 2b | 415932 | revive (0x4092c0): mode −1→0, dir −1→2; mode 1: unit index arg2 (skip if on map) → its entry's person; **any unit with state ≠ 2** (wg2025: state 3, slot < 15); x = −1 → entry position (flags &= 0x93) else (x,y) with dir bits; SE 15, scroll, redraw. |
| 56/57 | 天气类别设定 / 当前天气设定 | op_56 / op_57 | 0 | 0 | 0 | 47 / 22 | 41264b / 414ab0 | unused. |
| 58 | 战场障碍设定 | op_58 | 0 | 850 | 33 | 42 43 44 04 04 26 26 | 416796 | **rewritten**, §10.2. |
| 59 | 战利品 | op_59 | 0 | 320 | 122 | 04 17 49 17 49 17 49 26 | 41688b | gold = arg + (L+7)·100 (L = party level 0x40c231); reward box 0x44b5a8; GS gold +=; each item ≠ 0xFFFF (u16 ids now): equipment with level 0 → auto level 0x407da3(L); bag 0x459950; record 0x408b0d. |
| 5A | 战场操作开始 | ui_5a | 0 | 117 | 116 | — | 44bac2 | 0x44b328(0x48e1c8): start player control. Same. |
| 5B | 战场高亮区域 | op_5b | 0 | 119 | 65 | 04 04 04 04 26 | 416ae3 | battle: highlight rect 0x416609(flag −1→0, x1,y1,x2,y2). Same. |
| 5C | 战场高亮人物 | op_5c | 0 | 82 | 57 | 02 | 416b54 | person < 0x400 on the map: scroll, blink 3× (10-tick halves). Same. |
| 5D | 回合上限设定 | op_5d | 0 | 12 | 10 | 34 04 | 41709c | turn u8 0x4b3d0a, limit u8 0x4b3d0b: op 0 limit = max(n, turn+1); 1 limit += n (≤ 255); ≥ 2 limit −= n but ≥ turn+1; op 0xFFFF → 0. Redraw 0x410549. (wg2025: op 0 kept the value, op 2 no-op.) |
| 5E | 武将不同测试 | **test_action_pair** (wg2025 mod_5e) | 0 | 136 | 58 | 02 02 | 44e642 | **new**, §10.3. |
| 5F | 单挑结束 | duel_start | 0 | 257 | 87 | — | 41583f | closes the duel (0x4498e5, as wg2025) **then** 0x411991: outside a battle and [0x4b0780] ≠ 0 → restore the R scene (0x419959) — duels also run in 5 R files. |
| 60 | 单挑武将出场 | duel_say | 0 | 515 | 87 | 26 05 4c | 417447 | appear + action + bubble; text expanded by 0x417df6. Same. |
| 61 | 单挑胜负显示 | duel_end | 0 | 246 | 84 | — | 4174c0 | banner, fight start. Same. |
| 62 | 单挑阵亡 | duel_62 | 0 | 94 | 43 | 26 | 4111f4 | winner side: loser greyed; exp award as wg2025. Same. |
| 63 | 单挑对话 | duel_say2 | 0 | 2573 | 87 | 26 05 26 | 4175c2 | bubble. Same. |
| 64 | 单挑动作 | duel_action | 0 | 4077 | 87 | 26 4c | 417636 | action 0..16 (table 0x4484e7; scripts use 0..15). Same. |
| 65 | 单挑攻击1 | duel_action2 | 0 | 1915 | 80 | 26 4d 26 | 41768c | kinds 0..4 as wg2025; new 5..8 (unused). |
| 66 | 单挑攻击2 | duel_action3 | 0 | 1409 | 84 | 26 4e 26 | 4176e6 | kinds 0..2. Same. |
| 67 | 章名 | chapter_title | 6 | 0 | 6 | 04 05 | 413b1b | **u8 0x510cf9** = max(n−1, 0) (wg2025 GS+6, now the scenario counter); title 0x40b935(n, expanded text). |
| 68 | 单挑开始 | duel_setup | 24 | 261 | 92 | 02 02 4f | 4103ee | A, B < 0x400 and A ≠ B else returns 0. **byte EV[4087] == 0** → classic duel 0x4499a3 (player side = A if hostility class(A) == 1; wg2025: A's unit < 35); **≠ 0** → small-window duel 0x41e6a4 (§10.4). |
| 69 | 旁白 | popup | 1736 | 5076 | 236 | 05 | 4139f9 | expanded text (0x417df6) → message box **0x42f699(2, text)**. **No "\|" battle-panel prefix** (wg2025) and box style 2. |
| 6A | Game Over指令 | op_6a | 12 | 0 | 3 | — | 415692 | 0x42b5e1(0): full teardown + DestroyWindow — **the program exits** (wg2025 → title). Only R_108/R_116/R_117 after next_scene; the port should end the game → title. |
| 6B | 法术 | op_6b | 0 | 26 | 10 | 04 04 4b 26 | 414071 | x, y, effect, scroll (u16): story (new) grid→screen 0x427a0b; battle: optional scroll, tile→px; effect < 100 magic animation (0x40bcd2), ≥ 100 resource effect #(e%100) (0x416a14). S_106 uses x,y = int −1/−2 → EV[1]/EV[2]. |
| 6C | 武将能力复制 | op_6c | 0 | 0 | 0 | 02 02 | 410c39 | unused. |
| 6D | 相对复活或移动 | op_6d | 0 | 745 | 99 | 40 02 04 02 04 04 2b 26 | 410d3b | mode 1: slot < **20** in state arg7+2 → its person; else person = arg1. Reference unit arg3 (selector); offsets ≤ 40 → +d, > 40 → −(d−40) (saturating); arg7 == 1 → revive 0x4092c0 else move 0x4594ea. |
| 6E | 概率测试 | test_random | 16 | 3 | 7 | 04 | 41741e | T: p = **low byte** of arg (raw: 0x6e > 0x6d), > 99 → 100; 0x47fb32(p). |
| 6F | 丢弃物品 | lose_item | 154 | 50 | 81 | 17 | 40c603 | **changed**, §10.5. Always returns 1. |
| 70 | 能力选择复制 | **copy_person_word** (wg2025 copy_person_byte) | 0 | 0 | 0 | 02 02 04 | 40f2ea | T: off < 0x48 → copy the u16 person[a]+off → person[b]+off. Unused. §7.1 |
| 71 | 特效请求 | special_func | 0 | 0 | 0 | 04 | 403936 | custom-person dialogs (§6). Different from wg2025's 0x71. Unused. |
| 72 | 信息传送 | **ext_command** (wg2025 rewind) | 832 | 17446 | 208 | 04 05 | 47d89e | extension call with 37 sub-functions, §6. |
| 73 | 人物五围和测试 | test_sum | 0 | 0 | 0 | 02 04 24 26 26 26 26 26 | 40f244 | T: sum of 武力..运气 by flags vs v. Unused. |
| 74 | 开/禁存档 | **set_save_enabled** (wg2025 set_4ce004) | 0 | 0 | 0 | 26 | 41dd26 | u8 0x500fff = v (save allowed). Unused. |
| 75 | S特殊形象指定 | **set_s_image** (wg2025 set_byte_var) | 1624 | 783 | 172 | 02 50 | 465d8a | u16 0x501000[id] = v; re-skin in battle. §7.1 |
| 76 | 无条件跳转 | goto | 24 | 204 | 137 | 04 | 416c41 | relative jump; 6.6 level rule §4.2. |
| 77 | 变量运算 | int_var_op | 3927 | 25167 | 246 | 51 04 53 52 04 | 416c87 | **changed** (width EV[4076], op 5 = percent, 6 = mod, −= wraps), §7.1 |
| 78 | 整型变量赋值 | data_transfer | 1288 | 54452 | 176 | 04 54 02 55 | 416dcd | **changed** field map, §7.1 |
| 79 | 变量测试 | test_int_var | 3226 | 41103 | 177 | 52 04 56 52 04 | 415093 | T: **changed** modes (2 = `<=`, 3 `!=`, 4 `<`, 5 `>`), kind 1 works, §7.1 |
| 7A | 对话3 | **dialog3** (new) | 30 | 31 | 24 | 05 | 4284a2 | three-portrait dialog, §6. |
| 7B | 信息传送测试 | **test_ext_command** (new) | 0 | 0 | 0 | 04 05 | 47e9f0 | T: 6 tests, §6. Unused. |

## 6. 0x72 信息传送 (`ext_command`) — the 6.x extension call

18,278 uses in 208 files (832 R, 17,446 S). Handler 0x47d89e (hand-written): `sub = int32 (raw: 0x72 > 0x6d)`,
`s = string`; a tag mismatch → 5; else `call [0x47d8df + 4*sub](s)` (37 stdcall entries 0..36, no bounds check —
sub ≥ 37 crashes) and return **1**. It never yields; subs 1/2 (strategy animation) and 34 (modal dialog) block
inside the call.

**String grammar.** Each sub-function parses the string itself with `num()` = 0x426e64 (returns value, length,
EV index): optional prefix chars `-` and `*` (only before the first digit, any order), then ASCII digits. `*N` =
EV[N] (one level, no bounds check), `-` negates after the dereference; no digits → value 0 with length = number of
prefix chars. After each field the reader advances **len + 1** bytes — exactly one separator byte, whatever it is
(`\n`, `,`, `|` are just the editor's habits). Fixed-count readers (0x42c6c5 / 0x407356) consume a field even when
it is empty (value 0); list readers stop at the first field of length 0 (so the `\n` before a trailing comment ends a
list because `\n` cannot start a number). Everything after the last field read is ignored — a comment — except for
subs 0, 8 and 34 where the tail is data. Parse the GBK **bytes** (skipping one byte can split a 2-byte character).
Subs 13/29 read args with 0x426840 which also knows `vN` = EV[N].

**JSON** (`tools/eex.py decode_ext`, an exact port of the above): `args = [sub, raw string]` plus
`ext = {"sub": n, "fn": name, "nums": [...], "text": tail}` with nums = ints or `{"var": N}` (`"neg": true` for
`-*N`, never used). 1,317 `*N` references (subs 5, 6, 21, 35; EVs 0, 1, 2, 103, 260). Fields consumed per sub:
FIXED 3:8, 4:3, 5:4, 6:4, 7:2, 14:3, 16:1, 17:8, 19:1, 20:2, 21:3, 22:2, 26:1, 34:2, 35:4, 36:3; UP TO 12:10,
24:3, 25:7, 28:6; 1 = 3 + list; 2 = 4 + list of x,y; 8 = 1 (text = stage name); 9 = list; 10 = mode + (5+mode) if
mode < 2; 11 = 5 + list; 23/27 = 1 + list; 0/18 none; 13/29/30–33 not decoded (`nums: null`). Quirk kept: S_106
`6 "27\n0\n1\n200\n30…"` has 5 numbers, the engine reads 4 (蚩尤 gets 必杀 27 at level 1).

**EVs involved:** EV[4054] (target person of sub 0 and op 0x71), EV[4040..4042] (EAX/ECX/EDX after subs 13/29),
byte EV[4031] (unit selector, subs 1/2), EV[4051] (written by sub 8), EV[4025] (sub 26), EV[4056] (sub 9),
EV[0..n-1] (sub 34 multi-select), EV[c] (sub 21 read mode), EV[4058] (class match of 特技 class slots).

| # | official name | `fn` | uses | handler | fields | semantics / memory |
|---|---|---|---|---|---|---|
| 0 | 武将改名 | rename_person | 26 (21 R) | 0x4081f2 | text = new name | rename person EV[4054] (< 0x400): name truncated in place to 13 bytes (0x41e1a9), refused if another person already has it (0x44deef); rename table 0x510d00 (48 × {u16 person (0x400 free), char[14]}), count u8 0x5083fe; copies to person+8 (0x435ab0(+8, 9), 0x40a72c). |
| 1 | 对指定人物释放法术 | cast_on_persons | 865 | 0x40c4b7 | power, strategy, camera, persons… | battle only. strategy < 100; context 0x497af8 (0x4251e1(ctx, strategy, 0x3c)); targets (< 0x400, unit selector 0x41b882, unit state 2) → list 0x497b05 (≤ 250); camera ≠ 0 → scroll to the first; animation 0x406d64(targets, strategy, 250, 0, power). power ≠ 0: each target's HP (unit+0x10) += power clamped to [1, maxHP] (0x4142dd — never kills), numbers shown (0x40 damage / 0x50 heal); power = 0: the strategy's own effect. |
| 2 | 对指定地点释放法术 | cast_on_points | 16 | 0x41419f | power, strategy, camera, side, x,y… | battle only. Points u8 x,y @0x492874 (≤ 120, 0xFFFF end); per point the unit of `side` (<4 exact, 4 side<2, 5 side 2/3, 6 any; 0x45aed1); animation on the points (0x406d64(…, 240, 1, power)), HP as sub 1. |
| 3 | 对指定范围施放法术 | cast_on_rect | 0 | 0x40221b | 4 + x1,y1,x2,y2 | like 2 over a rectangle. |
| 4 | 习得策略 | learn_strategy | 20 (11 R) | 0x402a96 | strategy, level, person | keyed table 0x507800 (C=0): {u8 level, u16 person} under key strategy; usable when unit level ≥ level (0x40de69). |
| 5 | 习得特技 | learn_skill | 9,236 | 0x408811 | skill, slot, who, value | 特技 table 0x511000 (ptr u32 0x500c3b): 255 rows × 16 B, row = skill (≤ 254). slots 0–3 at +3·slot {u16 person (0x400 none), u8 value}; slots 4–5 at +12/+14 {u8 class (80 none), u8 value}; other slots ignored. Lookup 0x4198be(skill, person): first person slot that matches, class slots via 0x42f998 (EV[4058] = 0: same class family with slot class ≤ unit class, else exact), plus sub-35 grants. |
| 6 | 习得必杀 | learn_special | 3,924 | 0x40886e | id, slot, level, person | 必杀 table 0x512000 (ptr 0x500c37): 80 rows × 16 B, row = id (< 80). slots 0–4 {u16 person (0x400 none), u8 level}; slot ≥ 5 writes only the byte row+3·slot = low byte of field 4 (slot 5 = byte 15 = class, 40 none). Level-up message 0x4073f3→0x41bce6 when person and level match. |
| 7 | 商店商家变更 | set_shop | 0 | 0x41104b | a, b | u16 0x510cfa = a, u16 0x510cfc = b. |
| 8 | 战场地图扩展 | map_extend | 27 | 0x41e5bb | n; text = stage name | EV[4051] = n; strncpy(0x4b0758, text, 22) (stage-name buffer, also written by 0x17). The next 0x27 mode 3 / 0x11 consumes EV[4051]. |
| 9 | 结局角色展示 | ending_cast | 0 | 0x414571 | persons… | ≤ 127 persons → u32 0x4b2b30; count → EV[4056]. |
| 10 | 装备专属和套装 | equip_skill | 705 | 0x411c4a | mode; mode 0: slot, 特效, person, item, value; mode 1: slot, 特效, weapon, armour, accessory, value | table 0x50e000: 255 特效 rows × 16 B (slot < 2). mode 0 (专属): dword row+4·slot = {u16 person, u8 item, u8 value}; mode 1 (套装): dword row+8+4·slot = {u8 weapon, u8 armour, u8 accessory (255 unused), u8 value}; mode ≥ 2 no-op. Read in the 特技 computation (0x402cf9 in 0x41301e). |
| 11 | 限定AI行动范围(逐个) | limit_ai_area_units | 0 | 0x44ce20 | 5 + units | unit+9 / unit+0x20 = rectangle. |
| 12 | S插图 | s_picture | 83 | 0x4295fb | ≤ 10: slot, x, y, n3..n8, anim | record 0x507180 + 32·slot (slot < 40): +0 slot, +1 battle flag, +2 x, +4 y, +6..+0x13 n3..n8; in battle x,y ≥ 0 ×48. < 10 numbers or anim = 0 → remove (0x40519f); else show (0x40da9a) if +0x18 == 0; battle redraw 0x465973. The 8 uses of the 7-number form `x,y\n1,1\nN\n40,40` therefore just remove picture slot x. |
| 13 | 剧本调用函数 | call_function | 0 | 0x404e70 | n, args, eax, ecx, edx, address | calls native code; results → EV[4040..4042]. Not portable (unused). |
| 14 | 战场明暗变化 | battle_tint | 74 | 0x40dc06 | colour, level, mode | mode ≠ 0 → 0x42aa4a(mode, level); u32 0x501bd4 = colour, u8 0x501bd3 = level, u8 0x501bd2 = mode; redraw 0x44a88a. "0,50,1" = half dark in battle, "0,0,1" restore. |
| 15 | 更换动图 | change_anim | 0 | 0x40dcb3 | k < 3, 3 ints | 0x501aac + 12k (cleared by 0x0a). |
| 16 | 清理离队武将信息 | clear_left_person | 0 | 0x4107a7 | person | 0x4773ae(person). |
| 17 | 限制区域AI行动范围（范围） | limit_ai_area_rect | 2 | 0x42c846 | ax1,ay1,ax2,ay2, ux1,uy1,ux2,uy2 | every unit inside the u-rect (unless unit+0xe == 7): u16 unit+9 = (ax1,ay1), u16 unit+0x20 = (ax2,ay2) — its AI action area. |
| 18 | 全队成员提升到平均等级 | party_to_average_level | 65 (R) | 0x406cfa | — | repeat until stable: avg = 0x40c231(); every member among persons 0..126 (0x42ac58) below avg levels up silently by avg−level (0x4073f3(rec, d, 0)). |
| 19 | 清除一个特殊指针变量 | clear_pt_patch | 0 | 0x4290fc | n | 200 ≤ n < 481 and PT[n] ≠ 0: restore the patched original (0x42913f), PT[n] = 0, record cleared (§7.2). |
| 20 | 待开发 | preload_files | 0 | 0x41648e | kind, n | file preloader. |
| 21 | 部队行动标识 | unit_acted_flag | 547 | 0x4078ed | mode, unit index, c | unit = 0x4a7b20 + 0x30·(low byte of field 2) — a battle **unit index**, not a person (scripts pass `*103`/`*260`). mode 0: EV[c] = (unit+0xd & 2) ? 1 : 0; mode ≠ 0: c ≠ 0 sets bits 0x06 of unit+0xd (acted / 不可行动, 0x442718), c = 0 clears them (0x406690); redraw 0x44a88a. |
| 22 | 结局设置 | set_ending | 0 | 0x4211f4 | a, b | 0x414050(b, a). |
| 23 | 指定武将列传 | set_biography | 0 | 0x408cfa | v, persons… | person byte +3 = v. |
| 24 | 指定武将点击语音 | click_voice | 20 (12 R) | 0x4236c2 | mode, person, voice | table 0x5076c0: 102 × {u16 person, u8 voice}, 0xFFFF end; mode ≠ 0 update/append, 0 delete. Selecting the unit in battle plays `WAV\SE_V_%03u.WAV` (0x40904c, only when unit+0xe == 7). |
| 25 | R数字 | r_number | 0 | 0x425b66 | ≤ 7 | story overlay number. |
| 26 | 产生一个随机数 | random_number | 60 (R) | 0x426404 | n | EV[4025] = rand() % n (0 if n ≤ 1; 0x47fb13). Tested afterwards with 0x79. |
| 27 | 清空指定武将的功勋 | clear_merit | 0 | 0x423e63 | v, persons… | 0x423ead(v) per person. |
| 28 | R插图 | r_picture | 0 | 0x425bf2 | ≤ 6 | story picture. |
| 29 | pl版指令 | call_pl_function | 0 | 0x47a919 | like 13 | function from table 0x4f0000[k]. |
| 30–33 | R文字 / 只使用战场的一个矩形范围 / 控制动态图 / 设置一个矩形范围的黑幕 | r_text / battle_viewport / control_anim / black_rect | 0 | 0x42af6f / 0x42d260 / 0x42c45a / 0x42a61d | — | 31: 4 bytes → battle viewport 0x501bf0. |
| 34 | (unnamed) | choice_menu | 21 (R) | 0x42c992 | a, b; text = option lines | modal dialog (resource 0x156): text expanded (0x417df6), split on `\n` into ≤ 9 options "1."… a = 0: radio buttons, OK → choice register reader+0x2038 = index+1 (same as op 0x12; test with 0x13). a ≠ 0: checkboxes, EV[0..n-1] = 0 on open, at most b checkable, OK sets EV[i] = 1 per checked option. OK enabled only with ≥ 1 selection; Cancel/Esc swallowed. |
| 35 | (unnamed) | grant_skill_timed | 123 | 0x42fd47 | skill, value, turns, person | keyed table 0x512dc0 (C=1, overwrite): {u8 value, u8 turns, u16 person} under key skill; lookup 0x42fbe1 = value if turns ≠ 0 (part of 0x4198be). turns 1..99 tick down at the owner's phase start (0x42fc0c from 0x44ee4a), ≥ 100 permanent, 0 inactive; entries with turns < 100 are purged by `clear_flags` (0x42fc8c). All 123 uses are `*0,0,0,119` (disable skill EV[0] for person 119). |
| 36 | (unnamed) | growth_grade_mod | 2,464 | 0x436eb0 | stat, value, person | keyed table 0x507ec0 (C=0): value ≠ 0 → set {i8 value, u16 person} under key stat; value = 0 → remove. Read by 0x436e3d: grade = base + value (negative values +1 first). stats 0..4 攻防精爆士: base grade from the person's stat byte +0x21+k (≥99→10, ≥90→8, ≥70→6, ≥50→4, else 2; 0x4072f2); 5/6 (HP/MP): class record byte (0x4a2a27 + 0x23·class)+2+k (0x425097). |

**Keyed list format** (subs 4, 35, 36; insert 0x402ac7, lookup 0x436f16): a byte stream of groups
`FF key entry…`, ended by `FF FF`; entry = C+3 bytes (C=0 {u8 v, u16 person}, C=1 {u8 a, u8 b, u16 person});
update in place (C=1 without overwrite: per-byte max), else insert at the end of the group (memmove) or append a
group; capacity 0x800 bytes. All these tables lie in the 0x501000..0x531000 block that is saved with the game (§7).

Battle-only subs: 1, 2, 3, 11, 12 (in battle), 14, 17, 21. Table subs 4, 5, 6, 10, 35, 36 and 0, 8, 18, 24, 26, 34
work anywhere.

### 0x7b 信息传送测试 (`test_ext_command`, unused) — 0x47e9f0
Test op `[4, 5]`: returns `[0x47ea2f + 4n](string)` (6 entries, no bounds check; JSON `ext.fn`): 0 picture_done
(sub-12 picture slot active and animation done, 0x42fb85), 1 value_at_most (b ≤ 0x42fab3(a)), 2 membership_is
(person, v), 3 terrain_under_unit (mode, id, v), 4 phase_is (n == 0x41553b(0x4b3d08)), 5 unit_status_bit (mode, id,
bit, expected).

### 0x71 特效请求 (`special_func`, unused) — 0x403936
`[4]`: byte 0x500acd = n; `call [0x409693 + 4n]` (6 entries): n = 0, 1, 3, 4, 5 → 0x41ff21 custom-person dialog
(resource 0x150) for EV[4054] (< 0x400, custom-name count u8 0x5083ff < 20); n = 2 → 0x41e34e. wg2025's 0x71 was a
different table (random numbers / Niuniu).

### 0x7a 对话3 (`dialog3`) — three half-body portraits, 61 uses (10 R, 14 S files), 0x4284a2 → 0x42db2c
String = segments `&f0,f1,f2,f3,f4\n<text>`, a new segment at each `\n&`. Fields: a byte ≤ `'9'` starts a number
(`num`, `*N` allowed), otherwise a person **name** (≤ 16 bytes up to `\n`/`,`, 0x413656 → 0x44deef); values ≥ 0x400
(and -1) → -1; a `&` ends the header early. f0 = speaker mask (bit 2 left = f2, bit 1 middle = f3, bit 0 right = f4);
f1 → EV[4031] for the duration of the window (battle only: f2..f4 are then unit indices); f2/f3/f4 = left/middle/right
person (-1 empty). Text up to the next `\n&`, expanded by 0x417df6.
Display 0x42d8bf: battle — resolve f2..f4 through the unit selector to persons; the first one on the map (state 2)
is focused (0x4596bd, area capture 0x42ceee); if none is on the map the dialog is skipped silently unless
f2 == f3 == f4 ≠ -1 (the scripts' `837,837,837` form, then unmasked slots are emptied); window at
((screen w − 600)/2, screen h − 300). Story — window at (20, 84). Window 600 × 356; three 192 × 272 portrait
panels at x + 198·i + 6 (spacing 72 when only left and middle are used); portrait = face u16 0x50f000[person]
(+7 if ≠ 0) from the face archive (0x4789d6(face, …, 10, …, 0x4ac430)); unlit slots dimmed (0x40690c(0xcc00, …)),
names drawn for lit ones; text box 600 × 84 below, 3 lines/page, 20 px line pitch, click-wait per page (0x42d565).
After the last segment the window is closed (0x4137e1) **only if the next opcode is not 0x7a** (consecutive 0x7a
share one window); at entry any window still open is closed (0x4137cd, flag 0x501fff).

## 7. Variables, pointers and the memory scripts poke

### 7.1 Variable opcodes
**0x77 变量运算 `int_var_op dk, di, op, sk, sv`** (0x416c87; 29,094 uses; all int args raw since 0x77 > 0x6d).
* destination: dk 0 = through the pointer PT[di]; 1 = &PT[di]; 2 = &EV[di]. di ≤ 480 for PT, < 4096 for EV, else
  the error box 0x42f699(0, "变量值溢出" @0x500cc0) and return 1.
* source: sk 0 immediate sv; 1 `*(u32*)PT[sv]` (always a full dword); 2 PT[sv]; 3 &PT[sv]; 4 EV[sv]; 5 &EV[sv];
  other → error box.
* op: 0 `+=`, 1 `-=` (**wraps**, no saturation — wg2025 saturated at 0), 2 `=`; ops ≥ 3 compute from the full dword
  *dst then assign with the width rule: 3 `*=` (low 32 bits), 4 `/=` unsigned, **5 = dst·v/100** unsigned (0x425ad9,
  the editor's "%=" is a percentage), **6 = dst % v** (editor "M="); higher odd ops act like 5, even like 4. Division
  by 0 is not checked (the original crashes).
* **write width** (0x41046a): if dk == 1 or sk ≥ 2 → dword; else the low byte of **EV[4076]**: 1 = byte, 2 = word,
  other = dword. This applies to EV destinations too: only the low byte/word of EV[x] changes (upper bytes kept), and
  `+=`/`-=` wrap within that width without carry. Scripts rely on it (880 byte-width `EV = imm`, 192 word-width
  `EV += imm`, 738 word-width `*PT = 1024`).
* PT patch record (0x413604): when dk == 0 and di ≥ 200, after the write: new value → u32 0x506464[di], width →
  u8 0x506f84[di], and if u32 0x5068c8[di] == 0 it takes the old dword ("original"; misfires when the original was 0).
  On load the engine restores originals (0x417020(0)), reads the save block, and re-applies PT[200..480] patches
  (0x417020(1) → 0x42913f) and renames (0x44f006). 0x72 sub 19 undoes one patch.
* Used: op 2 25,537×, 0 2,326×, 3 935×, 4 155×, 1 141×; (dk,sk): (2,0) 26,955, (0,0) 746, (2,4) 619, (1,0) 515,
  (1,4) 246, (0,4) 12, (2,1) 1.

**0x79 变量测试 `test_int_var ka, va, mode, kb, vb`** (0x415093; 44,329 uses). Value resolver 0x415133: 0 immediate;
**1 `*(u32*)PT[v]` masked by EV[4076] (1 byte, 2 word)** (744 uses; wg2025 crashed on kind 1); 2 PT[v]; 3 &PT[v];
4 EV[v] (full dword); ≥ 5 &EV[v]; an out-of-range index (PT > 480, EV ≥ 4096) yields the index itself. Modes, all
**unsigned**: 0 `==`, 1 `>=`, **2 `<=`** (wg2025 port: `<`; 16,458 uses), 3 `!=`, 4 `<`, other `>` (mode 5 used once).
Tag mismatch → false.

**0x78 整型变量赋值 `data_transfer var, dir, id, field`** (0x416dcd → 0x4202d8, field decoder 0x415418; 55,740 uses).
var ≥ 0x1000 → error box. dir 0: `EV[var] = field` (zero-extended full dword, no width rule); dir ≠ 0:
`field = EV[var]` truncated to the field size. id is a u16 (may be EV-indirect). Person record =
`*(u32*)0x4cea00 + id*0x48` (0x4061e4, no bounds check). Unit = first of the 250 unit records (0x30 B @0x4a7b20) whose
dword +0 == id (0x43e4d6; state not checked; EV[4031] does **not** apply); no unit → nothing happens (EV unchanged).

| f | official name | location | size | notes / write side effects (wg2025 difference) |
|---|---|---|---|---|
| 0 | R形象 | u16 0x50f800[id] | u16 | story sprite id (wg 0x565000) |
| 1 | 头像 | person+4 | u16 | write also stores u16 0x50f000[id] (face table, 0x423e30) |
| 2–6 | 攻击 防御 精神 爆发 士气 | person+0x11/13/15/17/19 | u16 | 功勋 hook, see below |
| 7 | HP | person+0x1b | u16 | (wg +0x1c u32); 功勋 hook |
| 8 | MP | person+0x1f | u16 | (wg +0x20 u8); 功勋 hook |
| 9–13 | 武力 统率 智力 敏捷 运气 | person+0x21..0x25 | u8 | |
| 14 | 出战场数 | person+0x27 | u8 | |
| 15 | 撤退场数 | person+0x29 | u8 | |
| 16 | 我军标识 | person+0x2a | u8 | membership (0 member, 0xff not) |
| 17 | 兵种 | person+0x2b | u8 | class |
| 18 | 人物等级 | person+0x2c | u8 | write with EV > level → level-up 0x4073f3(person, EV−level, silent) (growth applied; level > 99 sets exp 0xff); otherwise plain store |
| 19 | 人物经验值 | person+0x2d | u8 | |
| 20–22 | 武器 武器等级 武器经验值 | person+0x2e..0x30 | u8 | |
| 23–25 | 防具 防具等级 防具经验值 | person+0x31..0x33 | u8 | |
| 26 | 辅助 | person+0x34 | u8 | |
| 27 | 战场特殊形象 | u16 0x501000[id] | u16 | S-image (wg: byte var 0x55a000); write re-skins the unit in battle (0x40523a) |
| 28 | 战场编号 | unit+4 | u8 | unit index |
| 29 | 战场纵坐标 | unit+6 | u8 | **x** (editor labels 纵/横 are swapped) |
| 30 | 战场横坐标 | unit+7 | u8 | y |
| 31 | 杀敌数 (editor: 战场行动标识) | person+0x35 | u16 | kills (wg: unit+0xd) |
| 32 | 可以控制 (editor: 战场人物朝向) | unit+0xe | u8 | |
| 33 | HpCur | unit+0x10 | u32 | **no death check** (wg killed the unit at ≤ 0) |
| 34 | MpCur | unit+0x14 | u32 | (wg u8) |
| 35–41 | 攻击 防御 精神 爆发 士气 移动 健康 状态 | unit+0x18..0x1e | u8 | buffs (0..6, 3 = normal); 41 = ailment byte (§8.1) |
| ≥ 42 | — | unit+(f−0x0b) | u8 | no bound check |

功勋 hook (f2–f8): before the write, for ids < 102 with +0x2a ≠ 0xff, 0x408b52 sets the merit bonus
s16 0x508400[id·7 + stat] = value − base (HP/MP: base = current − bonus; stats 0..4: base = 0x408a60(stat) +
person[0x21+stat]). Most used fields: 40, 35, 37, 26, 20, 33, 23, 18.

**0x75 S特殊形象指定 `set_s_image id, v`** (0x465d8a; 2,407 uses; was wg2025 `set_byte_var`, a byte var @0x55a000):
u16 0x501000[id] = v (no range check), then 0x40523a re-skins the unit if in battle. Value meaning (0x4068a1):
0 = class default; 1..32 = battle sprite 0x50 + (v−1)·3 + class tier; ≥ 33 = sprite v + 0x8f.

**0x70 能力选择复制 `copy_person_word a, b, off`** (0x40f2ea, unused): off < 0x48 (signed) → copy the **word**
person[a]+off → person[b]+off, return 1; else 0 (wg2025 copied a byte).
**0x73 人物五围和测试 `test_sum p, v, cmp, f×5`** (0x40f244, unused): sum of attributes 10..14 (武力..运气, 0x422e9d)
whose flag is set; cmp 0 `≥ v`, 1 `< v`, else `==`.
**0x74 开/禁存档 `set_save_enabled v`** (0x41dd26, unused): u8 0x500fff = v (save allowed; set to 1 on load 0x4188eb;
read by the save menu). wg2025 wrote u32 0x4ce004.

### 7.2 Memory map
EV = u32[4096] @**0x502000**; PT = u32[481] @**0x506000** (wg2025: EV @0x55b000, PT[2048] @0x563000). The block
**0x501000..0x531000** (0x30000 bytes) is written verbatim into save files (save 0x405362; load 0x41888d; version
byte at file offset 0x30000 must be 5), so every table below is saved with the game.

| address | contents | script access |
|---|---|---|
| 0x501000 | u16[1024] S-image per person | 0x75, 0x78 f27 |
| 0x501aac | 3 × 12 B animation records | 0x72 sub 15; cleared by 0x0a |
| 0x501b00..0x501fff | misc battle/UI bytes (tint 0x501bd2.., level offset 0x501bf4, last action 0x501bf9, 0x501bfb, toolbar flag 0x501fff) and the SP table | **all zeroed by 0x0a clear_flags** |
| 0x501bd2..0x501bd7 | battle tint mode/level/colour | 0x72 sub 14 |
| 0x501bf4 | i8 enemy level offset | 0x45 |
| 0x501c00 | u8[1024] SP per person (cleared by 0x0a) | EV[4061] threshold, EV[4030], EV[4095] |
| 0x502000 | EV[4096] (config 4016–4095 @0x505ec0..0x505ffc, §8) | |
| 0x506000 | PT[481]; patch records new 0x506464[i], original 0x5068c8[i], width u8 0x506f84[i] (i ≥ 200) | 0x77/0x79 |
| 0x507180 | 40 × 32 B pictures | 0x72 sub 12 |
| 0x507680 | 3 B × n sortie-preview positions | 0x4b when EV[4057] ≠ 0xFFFF |
| 0x5076c0 | click voices 102 × 3 B | 0x72 sub 24 |
| 0x507800 | learned strategies (keyed list) | 0x72 sub 4 |
| 0x507ec0 | growth-grade modifiers (keyed list) | 0x72 sub 36 |
| 0x5083fc | u8 stage counter (++ saturating, 0x40badd; AI growth with EV[4075]) | scripts write it via PT ("調整關卡累積次數") |
| 0x5083fe / 0x5083ff | u8 rename count / custom-name count | 0x72 sub 0, 0x71 |
| 0x508400 | s16[102·7] 功勋 bonus (攻 防 精 爆 士 HP MP) | 0x78 f2–f8 |
| 0x508a00 | u16[256] | cleared by 0x44 |
| 0x509000 | 历史情报 records | 0x16 with EV[4071] |
| 0x50e000 | 255 × 16 B 专属/套装 rows | 0x72 sub 10; scripts scan it through PT |
| 0x50f000 | u16[1024] face per person | 0x78 f1 mirror; 0x7a portraits |
| 0x50f800 | u16[1024] R (story) image per person | 0x78 f0 |
| 0x510000 | u16 per map tile (0xc80 B) | cleared by 0x0a |
| 0x510cf9 | u8 chapter number | 0x67 |
| 0x510cfa / 0x510cfc | shop selectors | 0x72 sub 7 |
| 0x510cfe | u16 current battle map | 0x27 mode 3 |
| 0x510d00 | 48 × 16 B renames | 0x72 sub 0 |
| 0x511000 | 255 × 16 B 特技 rows | 0x72 sub 5; scripts scan it through PT |
| 0x512000 | 80 × 16 B 必杀 rows | 0x72 sub 6 |
| 0x512500 | custom names | 0x71 |
| 0x512dc0 | timed 特技 grants (keyed list) | 0x72 sub 35; purged by 0x0a |
| engine | units 250 × 0x30 @0x4a7b20; person ptr [0x4cea00] (0x48 B each); map w/h u8 0x4b422c/d; GS 0x4b0770; reader 0x492f90 | |

**Immediate addresses loaded into PT by the scripts** (all of them; computed addresses go through EVs):

| address | uses | files | purpose |
|---|---|---|---|
| 0x5083fc | 13 | R_004/010/015/020/025/030/040/045/046/050/055 | "調整關卡累積次數": EV[4076] = 1 then `*PT = EV0` (sk 4 → **dword** write, also zeroes 0x5083fd..ff = the rename counters) |
| 0x5083fc | 2 | R_072, R_150 | "重置": `*PT = 1` (byte write) |
| 0x510c81, 0x510c84 | 3 each | S_000/017/018 | "吃不完的米或酒": byte set to 1 if 0 (engine reader not found) |
| 0x4a7b20 | 1 | S_069 | walks the unit array (+48) |
| 0x502054 (&EV[21]) | 1 | S_069 | copies the person ids of unit slots 0..19 into EV21..40 |

Computed: `PT[3] = EV2 = 0x511000 or 0x50e000 + 16·EV0` (R_001 and 122 S files, "檢測開始": replace person 119 by
1024 in the 特技 / 专属 rows). Plain EVs used by scripts: 0–6, 21–40, 49–50, 77, 103, 200–211, 220–221, 240,
242–248, 250–258, 260–287, 299–300, 400–401; config 4017–4095.

## 8. Battle data model (6.6) — applies to every battle op

* **Units**: 250 records × 0x30 B @0x4a7b20 (accessor 0x4061f9: cl = index → **ecx** = record). wg2025: 115 ×
  0x24 @0x4b2c50. +0 u32 person (0xFFFF empty), +4 u8 own index, +5 u8 side code, +6/+7 x/y, +9/+0x20 AI area,
  +0xc state (0 none, 1 hidden, 2 on map, 3/4 retreated/dead), +0xd flags (0x06 = acted), +0xe AI/control,
  +0x10 HP u32, +0x14 MP u32, +0x18..+0x1d buffs (0..6, 3 = normal), +0x1e ailments.
* **Slots**: player 0..19 (from the sortie list, now **u16[]** @0x48b350, 0xFFFF end; wg2025 u32[], 15 slots),
  allies from 20, enemies from 60 (0x46 entry j of page p → 20+20p+j; 0x47 → 60+80p+j). Side test 0x44cb12: a unit
  with side code 2 counts as side 0 if index < 20, 1 if < 60, else 2. Side query argument: 0..3 exact, 4 = side < 2,
  5 = side 2 or 3, 6 = all. Hostility class 0x406710/0x40672d: side 0, 1, 5, 6 → 1; 2, 3 → 0; side 3 → class 2 when
  byte EV[4053] ≠ 0.
* **Deployment entries**: 16 B @0x494fd4 (= reader+0x2044; slot → entry 0x418dd0): +0 u32 person, +4 x, +5 y,
  +6 weapon level, +7 armour level, +8 flags (dir bits 0x449b29: dir 0→0x20, 1→8, 3→0x10, else 0x40; |4 hidden;
  enemy |1, |2 with the extra flag; ally |2), +9 weapon code, +0xa armour code, +0xb accessory code (wg2025: 0x24 B).
* **Unit selector 0x41b882(v)** (new; used by 0x30 in battle, 0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x53, 0x55, 0x6d,
  0x72 subs 1/2, 0x7a, actor moves …): v ≥ **0x404** → unit index v−0x404; else if byte **EV[4031]** ≠ 0 and v < 250
  → unit index v (战场编号); else v is a person → first unit with that person and state ≠ 0 (0x456079) or 0x4029c2.
  Empty slot → -1 = do nothing. 0x400..0x402 keep their wg2025 meaning ("current unit" 0x418ce0(0x4b5df0)) in
  0x4d/0x52/0x53.
* **Ailment byte +0x1e**: four 2-bit turn counters 麻痺 0x03, 禁咒 0x0c, 混亂 0x30, 中毒 0xc0
  (matches 6.5異常狀態計算.txt).

## 9. Config EVs 4016–4095 (@0x505ec0 + 4·(n−4016))

Initial values in the exe: 4021 = 1024, 4026 = 512, 4030 = 200, 4050 = 0xFFFF, 4056 = 255, 4057 = 0xFFFF,
4061 = 100, 4062 = 1024, 4072 = 1024, 4077 = 2, 4085 = 5; all others 0. Meanings from the mod notes
(`變量計算+意義.txt`), verified by the readers listed. Port: **M** = script semantics / must implement,
r = game rule (rules/data owner), – = UI/editor/unused.

| EV | meaning (verified) | engine readers | set by scripts | port |
|---|---|---|---|---|
| 4016 | unused | — | – | – |
| 4017 | initial 气 per unit (byte memset of 0x4930c8 at 0x44 battle_init); also the hit floor n1 of 4018 | 0x41225a, 0x4277c0, 0x43b4ee | 0/50 | r |
| 4018 | hit mode: 0 original, 1 集气 gauge, 2..100 hit threshold | 0x4131f7, 0x42882c, 0x42893f, 0x43b4e0, 0x445d67 | 0/1 | r |
| 4019 | ZOC rule (fn table 0x42e2e5) | 0x42e2be | 0 | r |
| 4020 / 4021 | R-scene name display; persons ≥ EV[4021] nameless | 0x42d20f, 0x429e22 | 0 / 1024 | r |
| 4022 / 4023 | merit buffer / status-recovery mode | 0x43a466 / 0x424078 | 0 | r |
| 4024 | 公/私档 | 0x4241aa | – | – |
| 4025 | random result: 0x72 sub 26 writes rand(n); 0x3d get_item with item 0xFFFF gives item EV[4025] | 0x41440d, 0x426415 | +=, tested | **M** |
| 4026 | dialog: speakers ≥ EV don't turn | 0x478c58 | 1024 | r |
| 4027 | background = scene value + 256·EV[4027] (persistent, not cleared) | 0x413de0 (from 0x40bbaf, 0x425dd0) | 0..3 (432×) | **M** |
| 4028 | 直角坐标 (coords << 3) | 0x427a0e | – | r |
| 4029 | summoned-unit equipment: data / shop | 0x424a97 | 0/1 | r |
| 4030 | SP reads 0 for person ids > EV (AI gets no SP) | 0x42393b | 1024 | r |
| 4031 | byte: unit selector treats args < 250 as unit indices (§8); 0x7a sets it temporarily | 0x41b894, 0x42d8bf | 0 | **M** |
| 4032 | sortie toolbar hide bitmask (8 出战, 4 装备, 2 买进, 1 卖出) | 0x4199ed | – | – |
| 4033 / 4034 | stat % multiplier for enemy/reinforcement (unit+5 ≥ 2) / ally (+5 == 1); 0 = off | 0x4200a2 | 80–140 / 100 | **M** |
| 4035 / 4036 | auto-use doesn't consume / 0x58 keeps the given terrain | 0x416455 / 0x4561c0 | – | r |
| 4037 / 4038 | map tint colour / alpha (engine writes 4038) | 0x42c483 | – | – |
| 4039 | equipment auto-upgrade at sortie | 0x40c9ab, 0x40d55c, 0x453a9b | 0/1 | r |
| 4040–4042 | EAX/ECX/EDX after 0x72 subs 13/29 | written 0x404efb, 0x47a980 | – | – |
| 4043 / 4044 | 0x4d: 0 = one group animation for rect mode, 1 = per unit / HP-MP op 0 sub (floor 1), 1 add, 2 set | 0x45ae59 / 0x40da4d | – (engine sets them temporarily) | **M** |
| 4046–4048 | kill-count bonus / merit sharing / merit pool | 0x405b86, 0x408fa0, 0x423ed9, 0x408ffe | 0/1 | r |
| 4049 / 4050 | 0x58 white box / batch-terrain origin (x·256+y, reset to 0xFFFF after each 0x58) | 0x452639 / 0x42aac0, 0x4565fa | – | **M** (4050) |
| 4051 | ×100 extension, consumed (reset to 0): 0x11 → GS+6 = v + 200·EV; 0x27 mode 3 → map = v (0xFFFF → 99) + 100·EV; set by 0x72 sub 8 | 0x418ab4, 0x413dac | 1/0 (170×) | **M** |
| 4052 / 4053 | swap equipment with allies / allies vs reinforcements fight | 0x41bc16 / 6 sites | 0 / 0,1 | r |
| 4054 | person for rename / custom name (0x72 sub 0, 0x71) | 0x4081f2, 0x41ff2d | 725/747/837 | **M** |
| 4055 / 4056 | merit in 练武场 / ending portraits mode (sub 9 sets it) | 0x42abc8 / 0x4145a1… | – | r |
| 4057 | sortie-preview map: 0x45 resets it to 0xFFFF; 0x4b stores preview positions while ≠ 0xFFFF | 0x415e93, 0x41e805, 0x45e85e | many | **M** |
| 4058 | class trait inheritance (also 特技 class slots) | 0x42f9a2 | 0 | r |
| 4059 | 必杀 disabled when 1 | 6 sites | 0/1, tested | **M** |
| 4060 / 4064 | 历史情报 sort UI | 0x44d958 / 0x41a42a… | 1 | – |
| 4061 | SP needed for 必杀 (vs SP[person] u8 0x501c00) | 0x401e29, 0x416eba, 0x422634 | 255 | **M** |
| 4062 | person-id threshold in 0x4101d9 (level-up stat dialog) | 0x4101f3 | 1024 | r |
| 4063 / 4065 / 4066 | AI order / AI terrain use / attack-direction bonus | 0x44db6b / 0x407c17 / 0x408db7 | 2/1/1 | r |
| 4067–4070 | 0x6f: 4067 ≠ 0 = test only (don't remove); out: holder (0x400 bag, 0x401 none), level, exp | 0x40c630, 0x418096 | – | **M** |
| 4071 | 0x16 info → 历史情报 record (1–4 colour, 255 edit/delete) @0x509000; reset to 0 after | 0x413a54, 0x413ae1 | 2,490× | **M** |
| 4072 | R-scene free-walk person (≥ 0x400 = off) | 0x4154c1, 0x429bd0… | – | r |
| 4073–4075 | ability > 100 bonus / merit system / AI growth (with 0x5083fc) | various | 0/1 | r |
| 4076 | 0x77/0x79 access width (1 byte, 2 word, else dword) | §7.1 | 7,150× | **M** |
| 4077 | pseudo-random (2 = off) | 0x437870, 0x44e891 | 0/2 | r |
| 4078 / 4079 / 4080 | 6th new strategy effect / 精进 exp / re-summon after death | 0x4073c6 / 0x421066 / 0x426616 | 0 | r |
| 4081 | 0x52 class change recomputes abilities | 0x414c58, 0x41ec88 | 1/0 (877×) | **M** |
| 4082–4087 | duels: 4082 loser dies, 4083 battle duel mode (19 readers), 4084 result (0 draw, 1 win, 2 lose), 4085 enemy HP, 4086 enemy abilities, 4087 small-window duel mode (61 readers; scripts set 1/2 before 0x68 and test 4084); 0x415cb5 zeroes 4082/4083/4086 | duel code | 4087, 4084 | **M** (duel) |
| 4088–4092 | shop: auto shop off, mines/tools for sale | 0x472c08, 0x466c7e | yes | r |
| 4093 | modern warfare | 6 sites | 1 | r |
| 4094 | recompute abilities on level-up (engine forces it temporarily) | 0x407400, 0x41d216 | 0/1 | r |
| 4095 | revived units keep their SP (0 → SP cleared) | 0x4277e6 | 0 | r |

## 10. Details of changed battle ops

### 10.1 0x4d 武将状态变更 `unit_op_4d` (0x415551; 5,171 uses)
Args: mode (0x41), person, slot, x1, y1, x2, y2, side (03), buff index (0x2f), buff value (0x18), ailments (0x30),
HP (u32), MP. Battle only. Mode 0: person (0x400..0x402 = current unit); 1: unit index arg2 in state 2; 2: all
units of side (−1→6) in the rect.
* buff: if index (0..5) ≠ −1 and value ≠ −1: value 2 → 6, 1 → 3, **any other value raw** (wg2025: 0 → 0, else 3);
  applied via 0x420eb9 → 0x45aa37 (single) / 0x45ade7 (rect).
* ailments (≠ −1): bits 1..4 = 麻痺/禁咒/混亂/中毒; without 0x80 OR table 0x4240ce {0x01, 0x08, 0x10, 0xc0} into
  the 2-bit counters of +0x1e (1/2/1/3 turns); with 0x80 clear those fields (mask table 0x4240d2 {03, 0c, 30, c0}).
  Script values: 138 = clear 麻痺+混亂, 142 = clear 麻痺/禁咒/混亂, 158 = clear all, 2 麻痺, 8 混亂, 16 禁咒.
  (The port's `status |= v / &= ~v` is wrong for 6.6.)
* HP (≠ 0) / MP (≠ 0): new value by **EV[4044]** (0x40da4a): 0 → cur > v ? cur − v : 1 (**never kills**); 1 → cur + v;
  2 → v; then clamped to the max (0x43f6db HP @+0x10, 0x43f715 MP @+0x14). (The port subtracts and kills.)
* animation: single target always animates (0x43e6aa + popup 0x479a01); rect mode with **EV[4043] == 0** collects the
  units (list 0x497b05) and plays one group effect 0x406d64 (effect id by direction from 0x43e776/7, 0x2c otherwise,
  0x40ddaf for ailments); EV[4043] ≠ 0 → per unit (original CCZ behaviour). Ends with 0x42bc14.

### 10.2 0x58 战场障碍设定 `op_58` (0x416796; 850 uses)
Args: type (0x42), revert (0x43), terrain (0x44), x, y, a5 (−1→0), a6 (−1→0). x ≥ 40 → x −= 40 and "special
obstacle" (type := a5 == 1 ? 0xcd : 0xc9). Area = the tile, or the rectangle between (x,y) and **EV[4050]**
(u16 x·256+y, 0x42aab7); every call resets EV[4050]'s low word to 0xFFFF. Records in the 250 × 5 B table @0x4b3d21
{x, y, new, old, type} (undone by revert / op 0x21). Unless **EV[4036]** ≠ 0 the terrain is forced: type 0 → 0x1a,
1/2 → 0x1b. Types 0..3 and > 200: terrain change (SE 0x13 for types 0/2 unless a6); 4..200: map object (0x437779,
SE 0x10/0x0f/0x12 by terrain, water 0x11). Revert = 0x456670. EV[4049] only affects the unknown-box display
(0x45263b).

### 10.3 0x5e 武将不同测试 `test_action_pair A, B` (0x44e642 → 0x41ebcb; 136 uses, new)
Battle only (else false); −1 → 0x400. actor = A ≥ 0x400 ? person of the current unit [0x4b5df0] : A.
1. The actor must be the **actor of the current action**: unit index of actor (0x42c6f7(actor, 0)) checked against
   the action context 0x44a5d6: action type u8 [0x501bf9] 1/5/6 (attack): idx == attacker u8 [0x4927f0] (or the
   defender u8 [0x4927f1] when [0x501bfa] == 1; type 6 also list 0x500e9d[8]); 2 (strategy, unless
   [0x497af8] == 'H'): ctx+1 == idx.
2. B < 0x400: B must be a **target** (0x42c6f7(B, 1)): strategy target list ctx+0xd (0xFF end), or for attacks the
   attacker/defender or list 0x492800 (0xFF end). B ≥ 0x400, by the actor's hostility class (0x406710): 0x400 → true;
   0x401 → class 1 (player/ally); 0x402 → class ≠ 0; ≥ 0x403 → class 1 and actor == current unit.
Typical: `IF 5e 119 1026` (119 acts on the player side), `5e 1026 119` (current unit acts on 119).

### 10.4 Small-window duel (EV[4087] ≠ 0)
0x68 with byte EV[4087] ≠ 0 calls 0x41e6a4: ++u8 0x500d8f; scene object 0x4ac63c mode 1 (0x41de7e);
0x418f05(this = 0x500ae0, A record, 0, B record, backdrop). Scripts set EV[4087] = 1 (升级 mode) or 2 (单挑 mode)
before 0x68 (28×: R_028 ×10, R_110, R_112, R_114 ×3, R_116 ×9, S_014, S_065, S_114, S_118) and branch on
**EV[4084]** (0 draw, 1 win, 2 lose); EV[4085] enemy HP, EV[4086] enemy abilities (4 bytes). The subsystem itself
is not reverse-engineered yet (needs its own pass).

### 10.5 0x6f 丢弃物品 `lose_item item` (0x40c603; 204 uses)
item < 0xa0: search the bag 0x4b0783 (200 × {item, lvl, exp}) → holder 0x400; else persons 0..0x3ff with membership
+0x2a == 0, slots +0x2e/+0x31/+0x34 → holder = person. The item is removed (set 0xFF) **only if byte EV[4067] == 0**;
0x418096 sets EV[4068] = holder, EV[4069] = level, EV[4070] = exp. item ≥ 0xa0: consumable count u8 0x493a50[item]
−1 if ≥ 1 (0x420299). Not found (or consumable) → EV[4068] = 0x401. **Always returns 1** (wg2025: true only if
removed; ranges < 0x57 / 0x57..0x67).

## 11. Details of changed story / general ops

**Text expansion 0x417df6** (replaces wg2025 0x4179a5; used by 0x12, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a,
0x2c, 0x60, 0x67, 0x69, 0x7a, 0x72 sub 34) adds `*` escapes (0x44cf28): `*/N` → EV[N] as "%d" (not expanded while
EV[4071] ≠ 0); `*.N` → name of person N (the +0x37 display name); `*+N` / `*,N` / `*-N` → form 0/1/2 of the
custom-name table 0x512500 (20 × 16 B {u16 person, 3 × 5-byte strings}, empty = 0x400); anything else after `*`
stays literal. Expansion stops at `\n&`. Scripts: `*/N` 57× in 0x14, 2× in 0x69.

**Person record** `[0x4cea00] + 0x48·id` (0x4061e4, returns in ecx), 1024 persons: +3 biography byte, +4 face u16,
+8 name, +0x11 five stat words (攻防精爆士), +0x1b HP base (dword read by the attribute getter; 0x78 f7 uses the low
word), +0x1f MP base u16, +0x21..0x25 raw abilities 武统智敏运 (cap 100), +0x27 sorties, +0x29 retreats, +0x2a
membership (0 member, 0xff not), +0x2b class, +0x2c Lv, +0x2d exp, +0x2e/+0x31/+0x34 equipment {item, lv, exp},
+0x35 kills u16, +0x37 8-byte display name (name without trailing digits, 0x407775).

### 11.1 0x06 我军出场限制 `battle_select_units enable, max, forced×5, flags×5` (0x415b4f + 0x415c0d)
The 0x38/0x39 lists go into two **u16 rings of 20**: forced persons @0x4b09dc (base index u32 0x4b0a2c), flag list
@0x4b0a04 (base 0x4b0a30); each call appends 5 and the base wraps at 20, so repeated 0x06 calls accumulate up to 20
forced persons. max → u8 0x4b09db (0 → 1). enable ≠ 0: [0x501fff] = 1 and the toolbar is shown (0x419959(tb, 0));
enable = 0: max = 1, both rings refilled with 0xFFFF and the bases reset (0x41c96d), toolbar dialogs closed
(0x420660). (wg2025: u32[5] @0x4b09f0 / 0x4b0a04, u8 0x4b09ec.) The sortie builder is 0x418597 (§5 0x4a).

### 11.2 0x14 对话 `dialog text` (0x4136ad; 42,391 uses)
Segments `&speaker\ntext`, a new segment at each `\n&`.
* Story speaker (0x413656): name up to `\n` or `,` (≤ 16 chars) matched over persons 0..0x3ff against the name at +8
  **or** the display name at +0x37 (0x44deef); not found → −1. **New `&*.N\n`** = person N directly (0x4082ac; 152×).
* Battle speaker: `&\n` = current unit (0x418ce0); `&` + up to **3** digits = unit index (wg2025: 2) — if that
  unit is not on the map (state ≠ 2) the **whole op ends**; otherwise as in story.
* Display: story, or speaker −1 → portrait window 0x42d5b0(text, person, 0x20) (the toolbar is hidden first,
  0x4137cd, if [0x501fff]); battle with a speaker → bubble 0x45965d. After the last segment, if the next opcode is not
  0x14, the toolbar is re-shown (0x411991).
* Portrait window 0x42d5b0: person ≥ 0x400 → centred 0x150 × 0x90 box without portrait; the window side toggles
  whenever the speaker changes (0x48e864, 0x4b1b24), speaker 0 forces left; y = 0x30 or 0x138 by the actor's
  screen y; 3 lines per page with a portrait, 4 without; in battle, a person with a unit (0x41b882, EV[4031]) →
  battle dialog 0x42cd05. Text gets `*` escapes.

### 11.3 0x16 信息 history records (EV[4071] ≠ 0)
Buffer 0x509000..0x50dc00 (full → ignored), byte length u32 0x508994; entry = `&` + colour byte (EV[4071] low byte,
1–4) + expanded text; EV[4071] = 255 → edit/delete the record whose leading number matches (0x47826a); if the history
window is open ([0x500fe4]) refresh 0x41c21c; EV[4071] := 0 afterwards. (The wg2025 port used 0x55effc /
0x55eff8 / 0x4d105c — switch to EV[4071] @0x505f9c, 0x508994, 0x509000.)

### 11.4 0x27 背景显示 `change_scene mode, a1, a2, a3, a4` (0x413d13; 1,646 uses)
Stored value v: mode 0 → a1 (0xFFFF → 0); mode 1 → a2 == 0 ? 114 : (a1 == 0xFFFF ? (a3 == 0xFFFF ? 114 : a3 + 40)
: a1); mode 2 → a3 (0xFFFF → 0); mode 3 → (a4, 0xFFFF → 99) + (EV[4051] & 0xff)·100, stored as u16 at 0x510cfe
(current battle map), EV[4051] = 0. Then 0x428346: scene object 0x4ac63c = {mode, byte v} (0xff for mode 3);
[0x4abf9c] |= 2; returns 2 (yield). **Background index = stored byte + EV[4027]·256 into PMAP.E5** (0x413de0 /
0x425de6) — no per-mode offset is added later (wg2025 Giji: +114 / +40). Script usage: mode 0 266 distinct
argument sets, mode 2 103, mode 3 28, mode 1 only "−1 0 …" (→ 114).

### 11.5 0x36 武将状态测试 / 0x38 武将能力设定 attribute ids (getter 0x422e9d)
| attr | value |
|---|---|
| 0–4 | stat word +0x11+2a (攻防精爆士) |
| 5 | HP base (dword +0x1b) |
| 6 | MP base +0x1f |
| 7 / 8 | battle unit HPcur (+0x10) / MPcur (+0x14) |
| 9 | Lv +0x2c |
| 10–14 | raw ability +0x17+a (武统智敏运) |
| 15 | special |

**0x36 test_attr person, attr, v, cmp** (cmp 0x421e00: 0 ≥, 1 <, other ==; CczString's "≠" (3) acts as ==):
person 0xFFFF → false; attr 7/8 without a unit → **false** (wg2025 compared 0xff); attr 15 = "person has item v
equipped" (0x4114d4; cmp ignored; on a hit EV[4068] = person). **In battle a person ≥ 0x400 is a selector**
(0x4113f5): true if any unit 0..249 on the map matches — 0x400 any, 0x401 side 1, 0x402 not side 1, 0x403 current
unit (wg2025 mapped 0x400..0x402 to the current unit). Persons > 0x400 in story → false.

**0x38 set_attr person, attr, op, v** (op 0 =, 1 +, 2 −; − = get, saturating minus 0x47fa9e, set): rejected for
person 0xFFFF, > 0x400, attr > 15; battle 0x400..0x402 → current unit's person.
| attr | set (0x407027) | add (0x406eca) |
|---|---|---|
| 0–4 | min(v, 9999) | capped 9999 |
| 5 | min(v, 0xffff) | capped 9999 |
| 6 | min(v, 9999) | capped 9999 |
| 7 / 8 | battle HP/MP via 0x45aa37(person, attr, v, 1, 0) with byte EV[4044] = 2 (set) — the 0x4d routine: clamped, never kills; EV[4044] reset to 0 | same with EV[4044] = 1 (add) |
| 9 Lv | no-op | no-op |
| 10–14 | min(v, 100) | capped 100 |
| 15 | face u16 +4, portrait refresh 0x423e30 | u8 [0x501a84 + unit index] = v |
attr ≤ 6 also update the 功勋 table s16[7] @0x508400 + 14·person (members < 102; 0x408b52). Afterwards
0x4158dc → 0x479a01(person) refresh. (wg2025: attr 7 could kill via 0x4121b0; attrs 8 and 15 unsupported.)

### 11.6 0x3b 武将加入 `join person, mode, arg` (0x414790; persons < 0x400)
Story (0x40c2e7):
| mode | behaviour |
|---|---|
| 0xff / 0xffff | leave: if arg = 0 and member → equipment back to the bag (0x40c436); membership = 0xff (0x4095b9) |
| 0 | join (no-op if already a member): **reload the person from DATA.E5** (0x46206c, + 功勋 bonus with EV[4075]); Lv := 0; class := tiered class; level up to target T (0x4073f3); default weapon/armour (0x407fd4); membership 0; recorded in the join list 0x501801 (≤ 0x67 × 6 B) |
| 1 | keep the data; arg = 101 → membership only; else if Lv < T: set the tiered class, level up by T − Lv; default equipment; membership 0 |
T = min(avg + arg, 100) for arg < 101, max(avg − (arg − 100), 1) for arg ≥ 101 (0x4123c8); avg = mean Lv of all
members among persons 0..126, ≥ 1 (0x40c231). Class tiers (0x40bf0c): family = class/3 (class < 60), class − 40
(< 80), else 40; base = family < 20 ? family·3 : family + 40; if base < 59 add 0/1/2 for Lv < 15 / 15–29 / ≥ 30.
(wg2025: mean of the top 15 of persons 0..25, cap 70, tiers at 20/40.)
Battle (**new**, 0x45b771): move the person's unit to side `mode` (0 → player slots 0–19, 1 → ally 20–59, else enemy
60–249) into a free slot (0x4081a6); a retreated unit (state 3) only changes membership; mode 0 also records the
equipment items.

### 11.7 0x3e 加入装备设定 `set_equipment person, w, wl, a, al, acc` (0x416326; 4,241 uses)
Person < 0x400; 0xffff → 0 for all 5 codes. Each slot uses **its own code** (wg2025 tested the weapon code for all
three): 0 = leave the slot, 1 = take off (0x406cbc(rec, slot, lv)), other → 0x407df1(rec, slot, code, lv) with
**item = code − 2 + {0, 70, 109}** for weapon / armour / accessory (wg2025: −2 / +0x24 / +0x33); level **0xfe** → the
code is the raw item id (level 0); the item type (0x40b444) must match the slot; level 0 = automatic from the
person's Lv, capped at the item's maximum; accessories get level 0xff. In battle the unit must exist (state ≠ 0)
and codes > 0x95 are ignored (0x44299b). 0x48 probably uses the same mapping at battle start (not traced).

## 12. JSON produced by `tools/eex.py`

```
{file: "R_000.eex", kind: "story"|"battle", scenario_index: 2k / 2k+1 (= GS+6 counter), version: [1,2], tlv: [],
 scenes: [{index, offset, sections: [{index, offset, title, body_off, body_end, conditions: [ins…], body: [ins…]}]}]}
ins = {op, name, args: [...]}      args: ints, strings, {"var": n} (EV indirection, §2), lists (ops 05/46/47)
  op 0x01 IF: + off, cond: ins, end: index of the first body instruction after the child block (skip target),
              end_off: byte offset of the block end (= body[end].off)
  op 0x76 goto (in a body or as an IF condition): + off, target: {scene, section, index, off}
              (targets may be in other sections/scenes; the VM keeps a runtime level stack)
  op 0x72 / 0x7b: + ext: {sub, fn, nums, text} (§6); args[1] keeps the raw string
  --offsets: "off" on every instruction (debugging); default only on IF/goto (needed for the 6.6 goto rule)
```
`body` is a flat list in file order; the child block of an IF at index i is `body[i+1 .. end-1]` (its last element
is the block's END). `title` = text of a leading op 0x02 in the condition list (the editor's section label).
`section.body_end` = end address of the body = the BLOCK_END value the engine sets when the body starts.

`opcodes.json`: per opcode `{hex, name, cn (official 6.x name), params: [[tag, tag name]…], wg2025_name?}` (not read
by the game; documentation/schema).

Converter checks (printed summary): 249 files ok; 670,689 instructions; every scene/section/block length consistent;
every block ends with END (0 dead ENDs); 228 gotos resolved to body-instruction boundaries; max IF depth 11;
0 undecodable strings (A1 40 → U+3000); 6,349 EV-indirect args (6,347 u16 + 2 int32), EV indices ≤ 250 (+ `*N` in
0x72 strings: 1,317).

Renamed / new port names (old wg2025 name → 6.6 name): 0x08 set_result → **set_menu**, 0x35 actor_state →
**set_r_image**, 0x39 op_39 → **level_up**, 0x3c op_3c → **test_last_action**,
0x5e mod_5e → **test_action_pair**, 0x70 copy_person_byte → **copy_person_word**, 0x72 rewind → **ext_command**,
0x74 set_4ce004 → **set_save_enabled**, 0x75 set_byte_var → **set_s_image**, new 0x7a **dialog3**, new 0x7b
**test_ext_command**. All other names are the wg2025 port's (several are historically misleading, see
engine_notes.md); their 6.6 semantics are in §5.
