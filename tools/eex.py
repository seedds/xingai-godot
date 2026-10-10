"""EEX scenario script converter for 新改曹操傳 6.6 (Koei 三国志曹操传 on the community "6.6 engine", Ekd5.exe).

Usage (from the repository root):
  tools/venv/bin/python -I tools/eex.py                  # convert orig/RS/R_###.eex + S_###.eex (249 files)
  tools/venv/bin/python -I tools/eex.py --stats          # also print the opcode frequency table
  tools/venv/bin/python -I tools/eex.py --offsets        # byte offset 'off' on every instruction (default: IF/goto)
  tools/venv/bin/python -I tools/eex.py --out DIR        # write the JSON somewhere else (default game/assets/scripts)
  tools/venv/bin/python -I tools/eex.py --txt DIR        # disassembly directory (default extract/eex_txt, '-' = none)
  tools/venv/bin/python -I tools/eex.py FILE.eex ...     # convert only these

Outputs:
  <out>/R_###.json, <out>/S_###.json   (UTF-8, compact; names as the originals, 3 digits)
  <out>/opcodes.json                   (opcode schema: port name, official 6.x name, parameter tags)
  <txt>/R_###.txt ...                  (indented human-readable disassembly)

Only files named [RS]_ddd.eex are scenario scripts; the editor scratch files in RS/ (單挑.eex, 記錄寫法.eex, …)
are never loaded by the engine (loader 0x417eea builds "RS\\R_%s.EEX"/"RS\\S_%s.EEX" from the scenario counter).

Format and semantics: docs/eex.md.  Grammar = the parameter tags the 6.6 handlers (table 0x410a38, op-2) pass to
READP 0x4183f7.  The input files are untrusted data: they are only parsed, never executed.
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys, os, re, struct, json, glob, codecs

ROOT = _REPO
SRC = ROOT + '/orig/RS'
OUT_JSON = ROOT + '/game/assets/scripts'
OUT_TXT = ROOT + '/extract/eex_txt'
FILE_RE = re.compile(r'^([RS])_(\d{3})\.eex$', re.I)

# ---------------------------------------------------------------------------
# Parameter tags (READP 0x4183f7).  tag 4 -> u32, tag 5 -> NUL-terminated GBK string, other tags -> u16.
# "tag" 1 is not a tag: a raw untagged u16 (only inside op 0x05 lists).
# EV indirection (EV = u32[4096] @0x502000):
#   * u16 values 0xEFFF..0xFFFE of tags 0x02/0x38/0x39 read EV[0xFFFE - v]   (0xFFFF stays literal = none/-1)
#   * a NEGATIVE int32 (tag 4) of an opcode <= 0x6d reads EV[-v]           (READP checks the opcode byte +0x2e)
#   Both are emitted as {"var": index}.
TAG_NAMES = {
    0x02: 'int16', 0x03: 'unit_side', 0x04: 'int32', 0x05: 'string', 0x07: 'ai_mode',
    0x09: 'sound', 0x0c: 'scene_arg', 0x0d: 'action', 0x0e: 'join_mode', 0x10: 'mark_type',
    0x12: 'screen_mode', 0x13: 'actor_state', 0x15: 'scene_arg2', 0x17: 'item', 0x18: 'b_action',
    0x1a: 'scene_arg3', 0x1b: 'weather', 0x1c: 'image', 0x1e: 'music', 0x22: 'b_flag',
    0x23: 'attr', 0x24: 'cmp', 0x26: 'person', 0x27: 'bool', 0x28: 'resource', 0x2b: 'dir',
    0x2c: 'select_mode', 0x2d: 'scene_mode', 0x2e: 'result', 0x2f: 'b_dir', 0x30: 'b_arg',
    0x32: 'b_set', 0x34: 'op', 0x35: 'count', 0x36: 'toggle', 0x37: 'scenario', 0x38: 'person_list',
    0x39: 'person_list2', 0x3a: 'join_arg', 0x3b: 'weapon', 0x3c: 'armor', 0x3d: 'accessory',
    0x3e: 'flag', 0x3f: 'area_mode', 0x40: 'select', 0x41: 'select2', 0x42: 'eff_a', 0x43: 'eff_b',
    0x44: 'eff_c', 0x45: 'ai_target', 0x46: 'status', 0x47: 'b_param', 0x48: 'side', 0x49: 'level',
    0x4a: 'arg4a', 0x4b: 'effect', 0x4c: 'duel_act', 0x4d: 'duel_act2', 0x4e: 'duel_act3',
    0x4f: 'duel_arg', 0x50: 'byte', 0x51: 'var_kind', 0x52: 'val_kind', 0x53: 'arith_op',
    0x54: 'direction', 0x55: 'var_index', 0x56: 'cmp_mode',
}
INDIRECT_TAGS = (0x02, 0x38, 0x39)
INT_EV_MAX_OP = 0x6d
EV_COUNT = 4096

# 0x46 / 0x47 entry layouts (table 0x407f7c).  6.6: entry j of the p-th executed 0x46 -> unit slot 20+20p+j,
# of the p-th executed 0x47 -> slot 60+80p+j (page bytes 0x500ad4/0x500ad5, reset by 0x44; 250 unit slots).
S46 = [0x02, 0x26, 0x04, 0x04, 0x2b, 0x3e, 0x45, 0x07, 0x02, 0x04, 0x04]          # 20 entries
S47 = [0x02, 0x26, 0x26, 0x04, 0x04, 0x2b, 0x3e, 0x45, 0x07, 0x02, 0x04, 0x04]    # 80 entries

# op: (port name, official 6.x name (剧本编辑器 CczString.ini), [param tags])   -- None grammar = special-cased
# Port names are the Godot handler names (op_<name>); they are kept from the wg2025 port wherever the opcode
# means the same thing (some of those names are historical/misleading, see docs/engine_notes.md).  Opcodes whose
# meaning or layout changed in 6.6 got new names: see RENAMED below and docs/eex.md.
OPS = {
    0x00: ('end', '事件结束', []),
    0x01: ('if', '子事件设定', []),
    0x02: ('comment', '内部信息', [5]),
    0x03: ('else', 'else', []),
    0x04: ('test_yes_no', '询问测试', [0x26]),
    0x05: ('test_flags', '变量测试', None),
    0x06: ('battle_select_units', '我军出场限制', [0x2e, 4] + [0x38] * 5 + [0x39] * 5),
    0x07: ('test_pending', '出战测试', []),
    0x08: ('set_menu', '菜单处理', [0x2e]),
    0x09: ('delay', '延时', [4]),
    0x0a: ('clear_flags', '初始化局部变量', []),
    0x0b: ('set_flag', '变量赋值', [4, 0x27]),
    0x0c: ('exit_section', '结束Section', []),
    0x0d: ('next_scene', '结束Scene', []),
    0x0e: ('ui_0e', '战斗失败', []),
    0x0f: ('screen_mode', '结局设定', [0x12]),
    0x10: ('nop', '许子将指导', []),
    0x11: ('goto_scenario', '剧本跳转', [0x37]),
    0x12: ('choice', '选择框', [5, 2]),
    0x13: ('test_choice', 'case', [4]),
    0x14: ('dialog', '对话', [5]),
    0x15: ('unit_say', '对话2', [2, 2, 5]),
    0x16: ('info', '信息', [5]),
    0x17: ('place_name', '场所名', [5]),
    0x18: ('title_text', '事件名称设定', [5]),
    0x19: ('victory_cond_text', '胜利条件', [5]),
    0x1a: ('battle_goal_text', '显示胜利条件', [5]),
    0x1b: ('op_1b', '撤退信息是否显示设定', [2, 0x27]),
    0x1c: ('fade_out', '绘图', []),
    0x1d: ('fade_in', '调色板设定', []),
    0x1e: ('wait_frame', '武将重绘', []),
    0x1f: ('scroll_to', '地图视点切换', [4, 4]),
    0x20: ('op_20', '武将头像状态设置', [0x4a]),
    0x21: ('map_mark', '战场物体添加', [4, 4, 0x10, 0x26, 0x26]),
    0x22: ('set_weather', '动画', [0x1b]),
    0x23: ('play_music', '音效', [0x1e, 4]),
    0x24: ('play_sound', 'CD音轨', [9]),
    0x25: ('test_unit_at', '武将进入指定地点测试', [2, 4, 4]),
    0x26: ('test_unit_in_area', '武将进入指定区域测试', [2, 4, 4, 4, 4]),
    0x27: ('change_scene', '背景显示', [0x2d, 0x0c, 0x1a, 0x1c, 0x15]),
    0x28: ('op_28', '自由R启动指令', [0x36]),
    0x29: ('op_29', '地图头像显示', [2, 4, 4]),
    0x2a: ('op_2a', '地图头像移动', [2, 4, 4]),
    0x2b: ('op_2b', '地图头像消失', [2]),
    0x2c: ('caption', '地图文字显示', [5, 0x26, 0x26, 0x26]),
    0x2d: ('test_clicked', '武将点击测试', [2]),
    0x2e: ('test_adjacent', '武将相邻测试', [2, 2, 0x26]),
    0x2f: ('op_2f', '清除人物', []),
    0x30: ('actor_appear', '武将出现', [2, 4, 4, 0x2b, 0x0d]),
    0x31: ('actor_select', '武将消失', [0x2c, 2, 4, 4, 4, 4, 3]),
    0x32: ('actor_move', '武将移动', [0x40, 2, 4, 4, 4, 0x2b]),
    0x33: ('actor_face', '武将转向', [2, 0x0d, 0x2b]),
    0x34: ('actor_action', '武将动作', [2, 0x0d]),
    0x35: ('set_r_image', '武将形象改变', [2, 0x13]),
    0x36: ('test_attr', '武将状态测试', [2, 0x23, 4, 0x24]),
    0x37: ('test_resource', '钱、章节编号、忠奸测试', [0x28, 4, 0x24]),
    0x38: ('set_attr', '武将能力设定', [2, 0x23, 0x34, 4]),
    0x39: ('level_up', '武将等级提升', [2, 4]),
    0x3a: ('set_resource', '钱、章节编号、忠奸设置', [0x28, 0x34, 4]),
    0x3b: ('join', '武将加入', [2, 0x0e, 0x3e]),
    0x3c: ('test_last_action', '武将加入测试', [2, 0x0e, 0x3a]),
    0x3d: ('get_item', '获得物品', [0x17, 0x49, 0x26, 2]),
    0x3e: ('set_equipment', '加入装备设定', [2, 0x3b, 0x49, 0x3c, 0x49, 0x3d]),
    0x3f: ('test_turn', '回合测试', [4, 0x24]),
    0x40: ('test_side', '行动方测试', [0x48]),
    0x41: ('test_units_in_area', '战场人数测试', [3, 4, 0x24, 0x3f, 4, 4, 4, 4]),
    0x42: ('test_event5', '战斗胜利测试', []),
    0x43: ('test_event6', '战斗失败测试', []),
    0x44: ('battle_init', '战斗初始化', []),
    0x45: ('battle_settings', '战场全局变量', [0x26, 0x26, 4, 0x3e, 0x32, 2, 0x32, 2, 0x47, 0x22]),
    0x46: ('battle_allies', '友军出场设定', None),
    0x47: ('battle_enemies', '敌军出场设定', None),
    0x48: ('battle_equipment', '敌方装备设定', [2, 0x3b, 0x49, 0x3c, 0x49, 0x3d]),
    0x49: ('ui_49', '战斗结束', []),
    0x4a: ('battle_prepare', '我军出场强制设定', [4] + [0x38] * 5 + [0x39] * 5),
    0x4b: ('op_4b', '我军出场设定', [4, 4, 4, 0x2b, 0x26]),
    0x4c: ('unit_op_4c', '隐藏武将出现', [0x40, 2, 4]),
    0x4d: ('unit_op_4d', '武将状态变更', [0x41, 2, 4, 4, 4, 4, 4, 3, 0x2f, 0x18, 0x30, 4, 4]),
    0x4e: ('unit_op_4e', '武将方针变更', [0x2c, 2, 4, 4, 4, 4, 3, 7, 2, 4, 4]),
    0x4f: ('unit_op_4f', '战场转向设置', [2, 2, 0x2b, 0x26, 0x26, 0x26]),
    0x50: ('unit_status', '战场动作设定', [2, 0x46, 0x26, 0x26]),
    0x51: ('op_51', '战场恢复行动权', []),
    0x52: ('op_52', '兵种改变', [2, 3]),
    0x53: ('unit_op_53', '战场撤退', [0x2c, 2, 4, 4, 4, 4, 3, 0x26]),
    0x54: ('ui_54', '战场撤退确认', []),
    0x55: ('unit_move', '战场复活', [0x40, 2, 4, 4, 4, 0x2b]),
    0x56: ('op_56', '天气类别设定', [0x47]),
    0x57: ('op_57', '当前天气设定', [0x22]),
    0x58: ('op_58', '战场障碍设定', [0x42, 0x43, 0x44, 4, 4, 0x26, 0x26]),
    0x59: ('op_59', '战利品', [4, 0x17, 0x49, 0x17, 0x49, 0x17, 0x49, 0x26]),
    0x5a: ('ui_5a', '战场操作开始', []),
    0x5b: ('op_5b', '战场高亮区域', [4, 4, 4, 4, 0x26]),
    0x5c: ('op_5c', '战场高亮人物', [2]),
    0x5d: ('op_5d', '回合上限设定', [0x34, 4]),
    0x5e: ('test_action_pair', '武将不同测试', [2, 2]),
    0x5f: ('duel_start', '单挑结束', []),
    0x60: ('duel_say', '单挑武将出场', [0x26, 5, 0x4c]),
    0x61: ('duel_end', '单挑胜负显示', []),
    0x62: ('duel_62', '单挑阵亡', [0x26]),
    0x63: ('duel_say2', '单挑对话', [0x26, 5, 0x26]),
    0x64: ('duel_action', '单挑动作', [0x26, 0x4c]),
    0x65: ('duel_action2', '单挑攻击1', [0x26, 0x4d, 0x26]),
    0x66: ('duel_action3', '单挑攻击2', [0x26, 0x4e, 0x26]),
    0x67: ('chapter_title', '章名', [4, 5]),
    0x68: ('duel_setup', '单挑开始', [2, 2, 0x4f]),
    0x69: ('popup', '旁白', [5]),
    0x6a: ('op_6a', 'Game Over指令', []),
    0x6b: ('op_6b', '法术', [4, 4, 0x4b, 0x26]),
    0x6c: ('op_6c', '武将能力复制', [2, 2]),
    0x6d: ('op_6d', '相对复活或移动', [0x40, 2, 4, 2, 4, 4, 0x2b, 0x26]),
    0x6e: ('test_random', '概率测试', [4]),
    0x6f: ('lose_item', '丢弃物品', [0x17]),
    0x70: ('copy_person_word', '能力选择复制', [2, 2, 4]),
    0x71: ('special_func', '特效请求', [4]),
    0x72: ('ext_command', '信息传送', [4, 5]),
    0x73: ('test_sum', '人物五围和测试', [2, 4, 0x24] + [0x26] * 5),
    0x74: ('set_save_enabled', '开/禁存档', [0x26]),
    0x75: ('set_s_image', 'S特殊形象指定', [2, 0x50]),
    0x76: ('goto', '无条件跳转', [4]),
    0x77: ('int_var_op', '变量运算', [0x51, 4, 0x53, 0x52, 4]),
    0x78: ('data_transfer', '整型变量赋值', [4, 0x54, 2, 0x55]),
    0x79: ('test_int_var', '变量测试', [0x52, 4, 0x56, 0x52, 4]),
    0x7a: ('dialog3', '对话3', [5]),
    0x7b: ('test_ext_command', '信息传送测试', [4, 5]),
}
# wg2025 port name -> 6.6 name, for opcodes whose meaning/layout changed (or that are new in 6.6)
RENAMED = {
    0x08: 'set_result', 0x35: 'actor_state', 0x39: 'op_39', 0x3c: 'op_3c', 0x5e: 'mod_5e',
    0x70: 'copy_person_byte', 0x72: 'rewind', 0x74: 'set_4ce004', 0x75: 'set_byte_var', 0x7a: None, 0x7b: None,
}


class EexError(Exception):
    pass


def _gbk_errors(e):
    # The only non-GBK sequence in the shipped strings is A1 40 (25x, e.g. "陈留\xa1\x40曹操军大本营"): the Big5
    # full-width space typed by the (Big5) authors; GBK leaves A140 undefined.  Shown as U+3000.
    if e.object[e.start:e.start + 2] == b'\xa1\x40':
        return '\u3000', e.start + 2
    return '\ufffd', e.start + 1


codecs.register_error('eex_gbk', _gbk_errors)


class Reader:
    def __init__(self, data):
        self.d = data
        self.p = 0
        self.op = 0          # opcode of the instruction being read (READP looks at it, reader +0x2e)
        self.bad_strings = 0
        self.raw = b''       # raw bytes of the last string read

    def u16(self):
        if self.p + 2 > len(self.d):
            raise EexError('EOF at %x' % self.p)
        v = struct.unpack_from('<H', self.d, self.p)[0]
        self.p += 2
        return v

    def u32(self):
        if self.p + 4 > len(self.d):
            raise EexError('EOF at %x' % self.p)
        v = struct.unpack_from('<I', self.d, self.p)[0]
        self.p += 4
        return v

    def param(self, tag):
        if tag == 1:
            return self.u16()
        a = self.p
        t = self.u16()
        if t != tag:
            raise EexError('param tag mismatch at %x: want %x got %x' % (a, tag, t))
        if tag == 4:
            v = self.u32()
            if v & 0x80000000 and self.op <= INT_EV_MAX_OP:
                return {'var': (1 << 32) - v}
            return v
        if tag == 5:
            e = self.d.find(b'\0', self.p)
            if e < 0:
                raise EexError('unterminated string at %x' % self.p)
            s = self.d[self.p:e]
            self.raw = s
            self.p = e + 1
            try:
                return s.decode('gbk')
            except UnicodeDecodeError:
                v = s.decode('gbk', errors='eex_gbk')
                if '\ufffd' in v:
                    self.bad_strings += 1
                return v
        v = self.u16()
        if tag in INDIRECT_TAGS and 0xEFFF <= v <= 0xFFFE:
            return {'var': 0xFFFE - v}
        return v

    def instr(self):
        """read one instruction -> dict (without block structure)"""
        a = self.p
        op = self.u16()
        if op not in OPS:
            raise EexError('bad opcode %x at %x' % (op, a))
        self.op = op
        name = OPS[op][0]
        if op == 0x05:
            n = self.param(0x35)
            on = [self.param(1) for _ in range(n)]
            m = self.param(0x35)
            off = [self.param(1) for _ in range(m)]
            args = [on, off]
        elif op == 0x46:
            args = [[self.param(t) for t in S46] for _ in range(20)]
        elif op == 0x47:
            args = [[self.param(t) for t in S47] for _ in range(80)]
        else:
            args = [self.param(t) for t in OPS[op][2]]
            if op == 0x76:  # signed relative offset from the end of this instruction
                v = args[0]
                args[0] = v - (1 << 32) if v & 0x80000000 else v
        ins = {'op': op, 'name': name, 'args': args, '_off': a, '_end': self.p}
        if op in (0x72, 0x7b):
            ins['ext'] = decode_ext(args[0], self.raw, tests=(op == 0x7b))
        return ins


# ---------------------------------------------------------------------------
# 0x72 信息传送 (handler 0x47d89e: call [0x47d8df + 4*sub](string), 37 sub-functions) and 0x7b 信息传送测试
# (0x47e9f0: [0x47ea2f + 4*n](string), 6 tests).  The sub-functions parse the string themselves with
# num() = 0x426e64: optional '-' / '*' prefix characters (before the first digit, any order), ASCII digits;
# '*N' = EV[N] (one level), '-' negates (after the dereference); no digits -> value 0 with length = number of
# prefix chars.  After every field the reader skips len+1 bytes, i.e. exactly ONE separator byte, whatever it is
# ('\n' ',' '|' are only the editor's conventions).  Fixed-count readers (0x42c6c5 / 0x407356) consume a field
# even if it is empty; list readers stop at the first field of length 0.  The rest of the string is ignored
# (a comment) except for subs 0 / 8 / 34 where it is data.  Parsing works on the GBK bytes.
# The JSON keeps the raw string in args[1] and adds  ext = {"sub": n, "fn": name, "nums": [...], "text": tail}
# where nums are ints or {"var": N} ({"var": N, "neg": true} for "-*N").  Subs whose arguments are not decoded
# (13, 29, 30..33: unused) get "nums": null and text = the whole string.  docs/eex.md §5.
EXT_SUBS = {
    0: 'rename_person', 1: 'cast_on_persons', 2: 'cast_on_points', 3: 'cast_on_rect', 4: 'learn_strategy',
    5: 'learn_skill', 6: 'learn_special', 7: 'set_shop', 8: 'map_extend', 9: 'ending_cast',
    10: 'equip_skill', 11: 'limit_ai_area_units', 12: 's_picture', 13: 'call_function', 14: 'battle_tint',
    15: 'change_anim', 16: 'clear_left_person', 17: 'limit_ai_area_rect', 18: 'party_to_average_level',
    19: 'clear_pt_patch', 20: 'preload_files', 21: 'unit_acted_flag', 22: 'set_ending', 23: 'set_biography',
    24: 'click_voice', 25: 'r_number', 26: 'random_number', 27: 'clear_merit', 28: 'r_picture',
    29: 'call_pl_function', 30: 'r_text', 31: 'battle_viewport', 32: 'control_anim', 33: 'black_rect',
    34: 'choice_menu', 35: 'grant_skill_timed', 36: 'growth_grade_mod',
}
EXT_TESTS = {0: 'picture_done', 1: 'value_at_most', 2: 'membership_is', 3: 'terrain_under_unit', 4: 'phase_is',
             5: 'unit_status_bit'}
_EXT_FIXED = {3: 8, 4: 3, 5: 4, 6: 4, 7: 2, 14: 3, 16: 1, 17: 8, 19: 1, 20: 2, 21: 3, 22: 2, 26: 1, 34: 2, 35: 4,
              36: 3}
_EXT_UPTO = {12: 10, 24: 3, 25: 7, 28: 6}


def ext_num(b, p):
    """port of num() 0x426e64 on bytes b at p -> (value, length)"""
    neg = star = nd = 0
    while True:
        k = p + neg + star + nd
        c = b[k] if k < len(b) else 0
        if 0x30 <= c <= 0x39:
            nd += 1
        elif c == 0x2d and nd == 0:
            neg += 1
        elif c == 0x2a and nd == 0:
            star += 1
        else:
            break
    if nd == 0:
        return 0, neg + star
    v = int(b[p + neg + star:p + neg + star + nd])
    if star:
        return ({'var': v, 'neg': True} if neg else {'var': v}), neg + star + nd
    return (-v if neg else v), neg + star + nd


def decode_ext(sub, b, tests=False):
    """structured view of a 0x72 (tests=False) / 0x7b (tests=True) string (bytes b)"""
    if isinstance(sub, dict):
        return {'sub': sub, 'fn': None, 'nums': None, 'text': b.decode('gbk', errors='eex_gbk')}
    sub = sub - (1 << 32) if sub & 0x80000000 else sub
    p = 0
    nums = []

    def fixed(k):
        nonlocal p
        for _ in range(k):
            v, n = ext_num(b, p)
            nums.append(v)
            p += n + 1

    def lst(maxn=1 << 30):
        nonlocal p
        while len(nums) < maxn:
            v, n = ext_num(b, p)
            if n == 0:
                break
            nums.append(v)
            p += n + 1

    if tests:
        if sub in (0, 4):                   # 0x7b: field counts as read by the six test handlers
            fixed(1)
        elif sub in (1, 2):
            fixed(2)
        elif sub == 3:
            fixed(3)
        elif sub == 5:
            fixed(4)
        else:
            nums = None
    elif sub in _EXT_FIXED:
        fixed(_EXT_FIXED[sub])
    elif sub in _EXT_UPTO:
        lst(_EXT_UPTO[sub])
    elif sub in (0, 18):
        pass
    elif sub == 1:
        fixed(3); lst()                     # power, strategy, camera, persons...
    elif sub == 2:
        fixed(4); lst()                     # power, strategy, camera, side, x,y pairs...
    elif sub == 8:
        fixed(1)                            # n (-> EV[4051]); text = stage name
    elif sub == 9:
        lst()
    elif sub == 10:
        fixed(1)
        m = nums[0]
        if isinstance(m, int) and 0 <= m < 2:
            fixed(5 + m)
    elif sub == 11:
        fixed(5); lst()
    elif sub in (23, 27):
        v, n = ext_num(b, p)
        if n:
            nums.append(v)
            p += n + 1
            lst()
    else:
        nums = None
    if nums is None:
        p = 0
    p = min(p, len(b))
    return {'sub': sub, 'fn': (EXT_TESTS if tests else EXT_SUBS).get(sub), 'nums': nums,
            'text': b[p:].decode('gbk', errors='eex_gbk')}


def parse_block(r, endp, out, depth, maxdepth, stats):
    """Flat parse of a block ending exactly at endp (lengths are authoritative)."""
    first = len(out)
    while r.p < endp:
        ins = r.instr()
        ins['_depth'] = depth
        out.append(ins)
        if ins['op'] == 1:
            cond = r.instr()
            if cond['op'] in (0, 1):
                raise EexError('bad IF condition op %x at %x' % (cond['op'], cond['_off']))
            ln = r.u16()
            ins['cond'] = cond
            ins['len'] = ln
            ce = r.p + ln
            if ce > endp:
                raise EexError('child block overruns parent at %x' % ins['_off'])
            maxdepth[0] = max(maxdepth[0], depth + 1)
            parse_block(r, ce, out, depth + 1, maxdepth, stats)
            ins['_endidx'] = len(out)
            ins['_endoff'] = ce
    if r.p != endp:
        raise EexError('block overrun: at %x expected end %x' % (r.p, endp))
    # nesting check: a block must end with END at its own depth; ENDs before it are dead code (jumped over)
    own = [i for i in range(first, len(out)) if out[i]['_depth'] == depth]
    if not own or out[own[-1]]['op'] != 0:
        raise EexError('block ending at %x does not end with END' % endp)
    stats['inner_end'] += sum(1 for i in own[:-1] if out[i]['op'] == 0)


def parse_file(path):
    d = open(path, 'rb').read()
    if d[:4] != b'EEX\0':
        raise EexError('bad magic')
    if d[4] > 1 or (d[4] == 1 and d[5] > 2):    # loader 0x40fe3d accepts major <= 1, minor <= 2
        raise EexError('unsupported version %d.%d' % (d[4], d[5]))
    r = Reader(d)
    ver = [d[4], d[5]]
    r.p = 6
    tlv = []
    while True:
        t = r.u16()
        l = r.u16()
        if t == 0:
            break
        tlv.append({'type': t, 'data': d[r.p:r.p + l].hex()})
        r.p += l
    if tlv:
        # type 1 (font/charset name) sets reader+0x34: one extra u16 before every instruction and section.
        raise EexError('TLV header entries are not supported (none of the shipped files has any)')
    hdr = r.p
    first = struct.unpack_from('<I', d, hdr)[0]
    nsc = (first - hdr) // 4
    offs = [struct.unpack_from('<I', d, hdr + 4 * i)[0] for i in range(nsc)]
    scenes = []
    maxdepth = [0]
    stats = {'inner_end': 0}
    for si, o in enumerate(offs):
        r.p = o
        ns = r.u16()
        secs = []
        for k in range(ns):
            soff = r.p
            sl = r.u16()
            st = r.p
            conds = []
            while True:
                ins = r.instr()
                if ins['op'] == 1:
                    raise EexError('IF inside section condition list at %x' % ins['_off'])
                conds.append(ins)
                if ins['op'] == 0:
                    break
            bl = r.u16()
            body = []
            bstart = r.p
            parse_block(r, bstart + bl, body, 0, maxdepth, stats)
            if r.p != st + sl:
                raise EexError('section length mismatch at %x' % soff)
            secs.append({'offset': soff, 'conditions': conds, 'body': body, 'body_off': bstart, 'body_end': r.p})
        end = offs[si + 1] if si + 1 < len(offs) else len(d)
        if r.p != end:
            raise EexError('scene %d ends at %x, next starts %x' % (si, r.p, end))
        scenes.append({'offset': o, 'sections': secs})
    # resolve goto targets: byte offset -> (scene, section, body index).  Gotos may jump into other
    # sections/scenes (the engine just moves the read pointer).
    where = {}
    for si, sc in enumerate(scenes):
        for k, sec in enumerate(sc['sections']):
            for i, ins in enumerate(sec['body']):
                where[ins['_off']] = (si, k, i)
    ngoto = 0
    for si, sc in enumerate(scenes):
        for k, sec in enumerate(sc['sections']):
            for ins in sec['conditions'] + sec['body']:
                for g in ([ins, ins['cond']] if ins['op'] == 1 else [ins]):
                    if g['op'] == 0x76:
                        t = g['_end'] + g['args'][0]
                        if t not in where:
                            raise EexError('goto target %x is not a body instruction boundary (goto at %x)' % (t, g['_off']))
                        g['target'] = {'scene': where[t][0], 'section': where[t][1], 'index': where[t][2], 'off': t}
                        ngoto += 1
    return {'version': ver, 'tlv': tlv, 'header_size': hdr, 'scenes': scenes, 'max_depth': maxdepth[0],
            'size': len(d), 'gotos': ngoto, 'inner_end': stats['inner_end'], 'bad_strings': r.bad_strings}


def scenario_index(fname):
    """R_k -> 2k, S_k -> 2k+1: the u16 scenario counter GS+6 (GS @0x4b0770) that loader 0x417eea turns
    into the file name (counter>>1, 3 digits; odd -> S)."""
    m = FILE_RE.match(os.path.basename(fname))
    if not m:
        raise EexError('not a scenario file name: %s' % fname)
    return 2 * int(m.group(2)) + (1 if m.group(1).upper() == 'S' else 0)


def clean(ins, with_off=False):
    """JSON form of one instruction.  Byte offsets ('off') are always kept on IF and goto (the 6.6 goto
    level rule compares addresses, docs/eex.md §4.2); --offsets keeps them on every instruction."""
    o = {'op': ins['op'], 'name': ins['name'], 'args': ins['args']}
    if with_off or ins['op'] in (0x01, 0x76):
        o['off'] = ins['_off']
    if ins['op'] == 1:
        o['cond'] = clean(ins['cond'], with_off)
        o['end'] = ins['_endidx']
        o['end_off'] = ins['_endoff']
    if 'target' in ins:
        o['target'] = ins['target']
    if 'ext' in ins:
        o['ext'] = ins['ext']
    return o


def to_json(path, parsed, with_off=False):
    b = os.path.basename(path)
    out = {
        'file': b,
        'kind': 'story' if b[0].upper() == 'R' else 'battle',
        'scenario_index': scenario_index(b),
        'version': parsed['version'],
        'tlv': parsed['tlv'],
        'scenes': [],
    }
    for si, sc in enumerate(parsed['scenes']):
        jsc = {'index': si, 'offset': sc['offset'], 'sections': []}
        for k, sec in enumerate(sc['sections']):
            jsc['sections'].append({
                'index': k,
                'offset': sec['offset'],
                'title': sec['conditions'][0]['args'][0] if sec['conditions'] and sec['conditions'][0]['op'] == 2 else None,
                'body_off': sec['body_off'],
                'body_end': sec['body_end'],
                'conditions': [clean(i, with_off) for i in sec['conditions']],
                'body': [clean(i, with_off) for i in sec['body']],
            })
        out['scenes'].append(jsc)
    return out


def fmt_arg(a):
    if isinstance(a, str):
        return json.dumps(a, ensure_ascii=False)
    if isinstance(a, dict):
        return 'EV[%d]' % a['var']
    if isinstance(a, list):
        return '[' + ','.join(fmt_arg(x) for x in a) + ']'
    if a == 0xFFFF:
        return '-1'
    return str(a)


def fmt_ins(ins):
    op = ins['op']
    if op in (0x46, 0x47):
        return '%02x %s  %d slots' % (op, ins['name'], len(ins['args']))
    s = '%02x %s %s' % (op, ins['name'], ' '.join(fmt_arg(a) for a in ins['args']))
    if op == 0x76:
        t = ins['target']
        s += '   -> %d.%d #%d (@%x)' % (t['scene'], t['section'], t['index'], t['off'])
    return s


def to_txt(path, parsed):
    L = ['; %s  EEX v%d.%d  size=%d  scenes=%d  scenario_index=%d' % (
        os.path.basename(path), parsed['version'][0], parsed['version'][1], parsed['size'],
        len(parsed['scenes']), scenario_index(path))]
    for si, sc in enumerate(parsed['scenes']):
        L.append('')
        L.append('=' * 78)
        L.append('SCENE %d  @%x  sections=%d' % (si, sc['offset'], len(sc['sections'])))
        for k, sec in enumerate(sc['sections']):
            L.append('')
            L.append('-- section %d.%d @%x' % (si, k, sec['offset']))
            for ins in sec['conditions']:
                if ins['op'] == 0:
                    continue
                L.append('  WHEN %s' % fmt_ins(ins))
            L.append('  DO:')
            for i, ins in enumerate(sec['body']):
                ind = '    ' + '  ' * ins['_depth']
                if ins['op'] == 1:
                    L.append('%06x %4d %sIF %s   {len=%d, skip->#%d}' % (ins['_off'], i, ind, fmt_ins(ins['cond']), ins['len'], ins['_endidx']))
                elif ins['op'] == 0:
                    L.append('%06x %4d %s}' % (ins['_off'], i, ind))
                else:
                    L.append('%06x %4d %s%s' % (ins['_off'], i, ind, fmt_ins(ins)))
                    if ins['op'] in (0x46, 0x47):
                        base = 20 if ins['op'] == 0x46 else 60     # + page * 20 / 80
                        for j, slot in enumerate(ins['args']):
                            if slot[1 if ins['op'] == 0x46 else 2] == 0xFFFF and slot[0] == 0xFFFF:
                                continue
                            L.append('%s      slot %3d(+page): %s' % (' ' * 11, base + j, ' '.join(fmt_arg(a) for a in slot)))
    return '\n'.join(L) + '\n'


def schema():
    out = {}
    for op, (en, cn, g) in sorted(OPS.items()):
        if op == 0x05:
            params = 'tag35 n, n*raw_u16 (flags that must be ON), tag35 m, m*raw_u16 (flags that must be OFF)'
        elif op == 0x46:
            params = {'repeat': 20, 'first_slot': 20, 'page_stride': 20, 'entry': [[t, TAG_NAMES.get(t, '')] for t in S46]}
        elif op == 0x47:
            params = {'repeat': 80, 'first_slot': 60, 'page_stride': 80, 'entry': [[t, TAG_NAMES.get(t, '')] for t in S47]}
        else:
            params = [[t, TAG_NAMES.get(t, '')] for t in g]
        e = {'hex': '0x%02x' % op, 'name': en, 'cn': cn, 'params': params}
        if op in RENAMED:
            e['wg2025_name'] = RENAMED[op]
        out['%d' % op] = e
    return out


def scenario_files(src=SRC):
    return sorted(f for f in glob.glob(os.path.join(src, '*')) if FILE_RE.match(os.path.basename(f)))


def walk(parsed):
    """yield every instruction (conditions, bodies, IF conditions)"""
    for sc in parsed['scenes']:
        for sec in sc['sections']:
            for ins in sec['conditions'] + sec['body']:
                yield ins
                if ins['op'] == 1:
                    yield ins['cond']


def main(argv):
    stats = '--stats' in argv
    out_json, out_txt = OUT_JSON, OUT_TXT
    files = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--out':
            out_json = argv[i + 1]; i += 2; continue
        if a == '--txt':
            out_txt = argv[i + 1]; i += 2; continue
        if not a.startswith('--'):
            files.append(a)
        i += 1
    if not files:
        files = scenario_files()
    os.makedirs(out_json, exist_ok=True)
    if out_txt != '-':
        os.makedirs(out_txt, exist_ok=True)
    freq, ffreq = {}, {}
    nerr = total = ngoto = inner_end = bad_str = nvar = maxdepth = 0
    var_max = 0
    for f in files:
        b = os.path.splitext(os.path.basename(f))[0]
        try:
            scenario_index(f)
            parsed = parse_file(f)
        except EexError as e:
            nerr += 1
            print('ERROR', b, e)
            continue
        seen = set()
        for x in walk(parsed):
            freq[x['op']] = freq.get(x['op'], 0) + 1
            seen.add(x['op'])
            total += 1
            for a in x['args']:
                for v in (a if isinstance(a, list) else [a]):
                    for w in (v if isinstance(v, list) else [v]):
                        if isinstance(w, dict):
                            nvar += 1
                            var_max = max(var_max, w['var'])
        for op in seen:
            ffreq[op] = ffreq.get(op, 0) + 1
        ngoto += parsed['gotos']
        inner_end += parsed['inner_end']
        bad_str += parsed['bad_strings']
        maxdepth = max(maxdepth, parsed['max_depth'])
        with open(os.path.join(out_json, b + '.json'), 'w', encoding='utf-8') as fp:
            json.dump(to_json(f, parsed, '--offsets' in argv), fp, ensure_ascii=False, separators=(',', ':'))
        if out_txt != '-':
            with open(os.path.join(out_txt, b + '.txt'), 'w', encoding='utf-8') as fp:
                fp.write(to_txt(f, parsed))
    with open(os.path.join(out_json, 'opcodes.json'), 'w', encoding='utf-8') as fp:
        json.dump(schema(), fp, ensure_ascii=False, indent=1)
    print('files: %d ok, %d errors; %d instructions; %d gotos (all resolved to instruction boundaries); '
          'IF/END nesting balanced (max depth %d, %d dead ENDs inside blocks); %d undecodable strings; '
          '%d EV-indirect args (max EV %d)' % (len(files) - nerr, nerr, total, ngoto, maxdepth, inner_end, bad_str,
                                              nvar, var_max))
    if var_max >= EV_COUNT:
        print('WARNING: EV index >= %d' % EV_COUNT)
    if stats:
        for op, c in sorted(freq.items(), key=lambda x: -x[1]):
            print('%02x %-22s %-14s %8d %4d' % (op, OPS[op][0], OPS[op][1], c, ffreq[op]))
    return 1 if nerr else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
