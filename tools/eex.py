"""EEX scenario script parser for wg2025 (CCZ / 三国志曹操传 engine, Sui-Tang mod).

Usage:
  tools/venv/bin/python -I tools/eex.py                 # convert all R_xx/S_xx.wagan
  tools/venv/bin/python -I tools/eex.py --stats         # also print opcode frequency table
  tools/venv/bin/python -I tools/eex.py --offsets       # also store byte offsets ('off') in JSON
  tools/venv/bin/python -I tools/eex.py FILE.wagan ...  # convert only these

Outputs:
  game/assets/scripts/<R_xx|S_xx>.json   (UTF-8, compact)
  game/assets/scripts/opcodes.json       (opcode schema: names, param tags/types)
  extract/eex_txt/<R_xx|S_xx>.txt        (indented human-readable disassembly)

Format spec: docs/eex.md.  Grammar recovered from the handler table @0x410a3e in wagan.wa
(handlers call READP=0x4183f7(tag) for every parameter).
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys, os, struct, json, glob

ROOT = _REPO
SRC = ROOT + '/wg2025'
OUT_JSON = ROOT + '/game/assets/scripts'
OUT_TXT = ROOT + '/extract/eex_txt'

# ---------------------------------------------------------------------------
# Parameter tags.  tag 4 -> u32, tag 5 -> NUL-terminated GBK string, other tags -> u16.
# "tag" 1 is not a tag: it is a raw untagged u16 (only used inside op 0x05 lists).
# Mod: u16 values 0xEFFF..0xFFFE of tags 2/0x38/0x39 are indirect refs to ext int var
#      EV[0xFFFE - v] (dword array @0x55b000); emitted as {"var": index}.
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

S46 = [0x02, 0x26, 0x04, 0x04, 0x2b, 0x3e, 0x45, 0x07, 0x02, 0x04, 0x04]          # 20 slots (15..34)
S47 = [0x02, 0x26, 0x26, 0x04, 0x04, 0x2b, 0x3e, 0x45, 0x07, 0x02, 0x04, 0x04]    # 80 slots (35..114)

# op: (en_name, cn_name, [param tags])   -- None grammar = special-cased
OPS = {
    0x00: ('end', '结束', []),
    0x01: ('if', '条件', []),
    0x02: ('comment', '注释', [5]),
    0x03: ('else', '否则', []),
    0x04: ('test_yes_no', '测试是否', [0x26]),
    0x05: ('test_flags', '测试变量', None),
    0x06: ('battle_select_units', '出场选择(战中)', [0x2e, 4] + [0x38] * 5 + [0x39] * 5),
    0x07: ('test_pending', '测试待处理事件', []),
    0x08: ('set_result', '设定结果', [0x2e]),
    0x09: ('delay', '延时', [4]),
    0x0a: ('clear_flags', '清除局部变量', []),
    0x0b: ('set_flag', '变量赋值', [4, 0x27]),
    0x0c: ('exit_section', '中止', []),
    0x0d: ('next_scene', '场景结束', []),
    0x0e: ('ui_0e', '界面0E', []),
    0x0f: ('screen_mode', '画面模式', [0x12]),
    0x10: ('nop', '空', []),
    0x11: ('goto_scenario', '剧本跳转', [0x37]),
    0x12: ('choice', '选择', [5, 2]),
    0x13: ('test_choice', '测试选择', [4]),
    0x14: ('dialog', '对话', [5]),
    0x15: ('unit_say', '战场对话', [2, 2, 5]),
    0x16: ('info', '信息', [5]),
    0x17: ('place_name', '地名显示', [5]),
    0x18: ('title_text', '标题显示', [5]),
    0x19: ('victory_cond_text', '胜利条件', [5]),
    0x1a: ('battle_goal_text', '战斗目标', [5]),
    0x1b: ('op_1b', '指令1B', [2, 0x27]),
    0x1c: ('fade_out', '淡出', []),
    0x1d: ('fade_in', '淡入', []),
    0x1e: ('wait_frame', '等待', []),
    0x1f: ('scroll_to', '镜头移动', [4, 4]),
    0x20: ('op_20', '指令20', [0x4a]),
    0x21: ('map_mark', '地图标记', [4, 4, 0x10, 0x26, 0x26]),
    0x22: ('set_weather', '天气', [0x1b]),
    0x23: ('play_music', '背景音乐', [0x1e, 4]),
    0x24: ('play_sound', '音效', [9]),
    0x25: ('test_unit_at', '测试武将位置', [2, 4, 4]),
    0x26: ('test_unit_in_area', '测试武将区域', [2, 4, 4, 4, 4]),
    0x27: ('change_scene', '场景切换', [0x2d, 0x0c, 0x1a, 0x1c, 0x15]),
    0x28: ('op_28', '指令28', [0x36]),
    0x29: ('op_29', '指令29', [2, 4, 4]),
    0x2a: ('op_2a', '指令2A', [2, 4, 4]),
    0x2b: ('op_2b', '指令2B', [2]),
    0x2c: ('caption', '字幕', [5, 0x26, 0x26, 0x26]),
    0x2d: ('test_clicked', '测试点击', [2]),
    0x2e: ('test_adjacent', '测试相邻', [2, 2, 0x26]),
    0x2f: ('op_2f', '指令2F', []),
    0x30: ('actor_appear', '武将出场', [2, 4, 4, 0x2b, 0x0d]),
    0x31: ('actor_select', '武将选择', [0x2c, 2, 4, 4, 4, 4, 3]),
    0x32: ('actor_move', '武将移动', [0x40, 2, 4, 4, 4, 0x2b]),
    0x33: ('actor_face', '武将转向', [2, 0x0d, 0x2b]),
    0x34: ('actor_action', '武将动作', [2, 0x0d]),
    0x35: ('actor_state', '武将状态', [2, 0x13]),
    0x36: ('test_attr', '测试属性', [2, 0x23, 4, 0x24]),
    0x37: ('test_resource', '测试资源', [0x28, 4, 0x24]),
    0x38: ('set_attr', '属性变更', [2, 0x23, 0x34, 4]),
    0x39: ('op_39', '指令39', [2, 4]),
    0x3a: ('set_resource', '资源变更', [0x28, 0x34, 4]),
    0x3b: ('join', '加入/离队', [2, 0x0e, 0x3e]),
    0x3c: ('op_3c', '指令3C', [2, 0x0e, 0x3a]),
    0x3d: ('get_item', '获得物品', [0x17, 0x49, 0x26, 2]),
    0x3e: ('set_equipment', '装备设定', [2, 0x3b, 0x49, 0x3c, 0x49, 0x3d]),
    0x3f: ('test_turn', '测试回合', [4, 0x24]),
    0x40: ('test_side', '测试阵营', [0x48]),
    0x41: ('test_units_in_area', '测试区域部队', [3, 4, 0x24, 0x3f, 4, 4, 4, 4]),
    0x42: ('test_event5', '测试事件5', []),
    0x43: ('test_event6', '测试事件6', []),
    0x44: ('battle_init', '战场初始化', []),
    0x45: ('battle_settings', '战场设定', [0x26, 0x26, 4, 0x3e, 0x32, 2, 0x32, 2, 0x47, 0x22]),
    0x46: ('battle_allies', '友军出场设定', None),
    0x47: ('battle_enemies', '敌军出场设定', None),
    0x48: ('battle_equipment', '战场装备设定', [2, 0x3b, 0x49, 0x3c, 0x49, 0x3d]),
    0x49: ('ui_49', '界面49', []),
    0x4a: ('battle_prepare', '出场选择', [4] + [0x38] * 5 + [0x39] * 5),
    0x4b: ('op_4b', '指令4B', [4, 4, 4, 0x2b, 0x26]),
    0x4c: ('unit_op_4c', '战场指令4C', [0x40, 2, 4]),
    0x4d: ('unit_op_4d', '战场指令4D', [0x41, 2, 4, 4, 4, 4, 4, 3, 0x2f, 0x18, 0x30, 4, 4]),
    0x4e: ('unit_op_4e', '战场指令4E', [0x2c, 2, 4, 4, 4, 4, 3, 7, 2, 4, 4]),
    0x4f: ('unit_op_4f', '战场指令4F', [2, 2, 0x2b, 0x26, 0x26, 0x26]),
    0x50: ('unit_status', '战场状态', [2, 0x46, 0x26, 0x26]),
    0x51: ('op_51', '指令51', []),
    0x52: ('op_52', '指令52', [2, 3]),
    0x53: ('unit_op_53', '战场指令53', [0x2c, 2, 4, 4, 4, 4, 3, 0x26]),
    0x54: ('ui_54', '界面54', []),
    0x55: ('unit_move', '战场移动', [0x40, 2, 4, 4, 4, 0x2b]),
    0x56: ('op_56', '指令56', [0x47]),
    0x57: ('op_57', '指令57', [0x22]),
    0x58: ('op_58', '指令58', [0x42, 0x43, 0x44, 4, 4, 0x26, 0x26]),
    0x59: ('op_59', '指令59', [4, 0x17, 0x49, 0x17, 0x49, 0x17, 0x49, 0x26]),
    0x5a: ('ui_5a', '界面5A', []),
    0x5b: ('op_5b', '指令5B', [4, 4, 4, 4, 0x26]),
    0x5c: ('op_5c', '指令5C', [2]),
    0x5d: ('op_5d', '指令5D', [0x34, 4]),
    0x5e: ('mod_5e', '扩展5E', [4]),
    0x5f: ('duel_start', '单挑开始', []),
    0x60: ('duel_say', '单挑对话', [0x26, 5, 0x4c]),
    0x61: ('duel_end', '单挑结束', []),
    0x62: ('duel_62', '单挑62', [0x26]),
    0x63: ('duel_say2', '单挑对话2', [0x26, 5, 0x26]),
    0x64: ('duel_action', '单挑动作', [0x26, 0x4c]),
    0x65: ('duel_action2', '单挑动作2', [0x26, 0x4d, 0x26]),
    0x66: ('duel_action3', '单挑动作3', [0x26, 0x4e, 0x26]),
    0x67: ('chapter_title', '章节标题', [4, 5]),
    0x68: ('duel_setup', '单挑设定', [2, 2, 0x4f]),
    0x69: ('popup', '提示', [5]),
    0x6a: ('op_6a', '指令6A', []),
    0x6b: ('op_6b', '指令6B', [4, 4, 0x4b, 0x26]),
    0x6c: ('op_6c', '指令6C', [2, 2]),
    0x6d: ('op_6d', '指令6D', [0x40, 2, 4, 2, 4, 4, 0x2b, 0x26]),
    0x6e: ('test_random', '概率测试', [4]),
    0x6f: ('lose_item', '失去物品', [0x17]),
    0x70: ('copy_person_byte', '复制武将数据', [2, 2, 4]),
    0x71: ('special_func', '特殊功能', [4]),
    0x72: ('rewind', '跳回开头', []),
    0x73: ('test_sum', '测试合计', [2, 4, 0x24] + [0x26] * 5),
    0x74: ('set_4ce004', '设定扩展值', [0x26]),
    0x75: ('set_byte_var', '字节变量赋值', [2, 0x50]),
    0x76: ('goto', '跳转', [4]),
    0x77: ('int_var_op', '整型变量运算', [0x51, 4, 0x53, 0x52, 4]),
    0x78: ('data_transfer', '数据存取', [4, 0x54, 2, 0x55]),
    0x79: ('test_int_var', '整型变量比较', [0x52, 4, 0x56, 0x52, 4]),
}


class EexError(Exception):
    pass


class Reader:
    def __init__(self, data):
        self.d = data
        self.p = 0

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
            return self.u32()
        if tag == 5:
            e = self.d.find(b'\0', self.p)
            if e < 0:
                raise EexError('unterminated string at %x' % self.p)
            s = self.d[self.p:e]
            self.p = e + 1
            try:
                return s.decode('gbk')
            except UnicodeDecodeError:
                return s.decode('gbk', errors='replace')
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
        return {'op': op, 'name': name, 'args': args, '_off': a, '_end': self.p}


def parse_block(r, endp, out, depth, maxdepth):
    """Flat parse of a block ending exactly at endp (lengths are authoritative)."""
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
            parse_block(r, ce, out, depth + 1, maxdepth)
            ins['_endidx'] = len(out)
    if r.p != endp:
        raise EexError('block overrun: at %x expected end %x' % (r.p, endp))


def parse_file(path):
    d = open(path, 'rb').read()
    if d[:4] != b'EEX\0':
        raise EexError('bad magic')
    r = Reader(d)
    r.p = 4
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
    hdr = r.p
    first = struct.unpack_from('<I', d, hdr)[0]
    nsc = (first - hdr) // 4
    offs = [struct.unpack_from('<I', d, hdr + 4 * i)[0] for i in range(nsc)]
    scenes = []
    maxdepth = [0]
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
            parse_block(r, bstart + bl, body, 0, maxdepth)
            if r.p != st + sl:
                raise EexError('section length mismatch at %x' % soff)
            secs.append({'offset': soff, 'conditions': conds, 'body': body})
        end = offs[si + 1] if si + 1 < len(offs) else len(d)
        if r.p != end:
            raise EexError('scene %d ends at %x, next starts %x' % (si, r.p, end))
        scenes.append({'offset': o, 'sections': secs})
    # resolve goto targets: byte offset -> (scene, section, body index).  Gotos may jump into
    # other sections/scenes (the engine just moves the read pointer).
    where = {}
    for si, sc in enumerate(scenes):
        for k, sec in enumerate(sc['sections']):
            for i, ins in enumerate(sec['body']):
                where[ins['_off']] = (si, k, i)
                if ins['op'] == 1:
                    where.setdefault(('cond', ins['cond']['_off']), (si, k, i))
    for si, sc in enumerate(scenes):
        for k, sec in enumerate(sc['sections']):
            for ins in sec['body']:
                if ins['op'] == 0x76:
                    t = ins['_end'] + ins['args'][0]
                    if t not in where:
                        raise EexError('goto target %x is not a body instruction boundary (goto at %x)' % (t, ins['_off']))
                    ins['target'] = {'scene': where[t][0], 'section': where[t][1], 'index': where[t][2], 'off': t}
    return {'version': ver, 'tlv': tlv, 'header_size': hdr, 'scenes': scenes, 'max_depth': maxdepth[0], 'size': len(d)}


def scenario_index(fname):
    """R_ab -> n = 20*a + 2*b, S_ab -> n+1 (GS+7 scenario counter)"""
    b = os.path.basename(fname)
    a, c = int(b[2]), int(b[3])
    return 20 * a + 2 * c + (1 if b[0].upper() == 'S' else 0)


def clean(ins, with_off):
    o = {'op': ins['op'], 'name': ins['name'], 'args': ins['args']}
    if with_off:
        o['off'] = ins['_off']
    if ins['op'] == 1:
        o['cond'] = clean(ins['cond'], with_off)
        o['end'] = ins['_endidx']
    if 'target' in ins:
        o['target'] = ins['target']
    return o


def to_json(path, parsed, with_off=True):
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
                        base = 0x0f if ins['op'] == 0x46 else 0x23
                        for j, slot in enumerate(ins['args']):
                            if slot[1 if ins['op'] == 0x46 else 2] == 0xFFFF and slot[0] == 0xFFFF:
                                continue
                            L.append('%s      slot %3d: %s' % (' ' * 11, base + j, ' '.join(fmt_arg(a) for a in slot)))
    return '\n'.join(L) + '\n'


def schema():
    out = {}
    for op, (en, cn, g) in sorted(OPS.items()):
        if op == 0x05:
            params = 'tag35 n, n*raw_u16 (flags that must be ON), tag35 m, m*raw_u16 (flags that must be OFF)'
        elif op == 0x46:
            params = {'repeat': 20, 'first_slot': 15, 'entry': [[t, TAG_NAMES.get(t, '')] for t in S46]}
        elif op == 0x47:
            params = {'repeat': 80, 'first_slot': 35, 'entry': [[t, TAG_NAMES.get(t, '')] for t in S47]}
        else:
            params = [[t, TAG_NAMES.get(t, '')] for t in g]
        out['%d' % op] = {'hex': '0x%02x' % op, 'name': en, 'cn': cn, 'params': params}
    return out


def main(argv):
    stats = '--stats' in argv
    files = [a for a in argv if not a.startswith('--')]
    if not files:
        files = sorted(glob.glob(SRC + '/R_*.wagan') + glob.glob(SRC + '/S_*.wagan'))
    os.makedirs(OUT_JSON, exist_ok=True)
    os.makedirs(OUT_TXT, exist_ok=True)
    freq = {}
    nerr = 0
    total = 0
    for f in files:
        b = os.path.splitext(os.path.basename(f))[0]
        try:
            parsed = parse_file(f)
        except EexError as e:
            nerr += 1
            print('ERROR', b, e)
            continue
        for sc in parsed['scenes']:
            for sec in sc['sections']:
                for ins in sec['conditions'] + sec['body']:
                    for x in ([ins, ins['cond']] if ins['op'] == 1 else [ins]):
                        freq[x['op']] = freq.get(x['op'], 0) + 1
                        total += 1
        with open(os.path.join(OUT_JSON, b + '.json'), 'w', encoding='utf-8') as fp:
            json.dump(to_json(f, parsed, with_off='--offsets' in argv), fp, ensure_ascii=False, separators=(',', ':'))
        with open(os.path.join(OUT_TXT, b + '.txt'), 'w', encoding='utf-8') as fp:
            fp.write(to_txt(f, parsed))
    with open(os.path.join(OUT_JSON, 'opcodes.json'), 'w', encoding='utf-8') as fp:
        json.dump(schema(), fp, ensure_ascii=False, indent=1)
    print('files: %d ok, %d errors; %d instructions' % (len(files) - nerr, nerr, total))
    if stats:
        for op, c in sorted(freq.items(), key=lambda x: -x[1]):
            print('%02x %-22s %-10s %8d' % (op, OPS[op][0], OPS[op][1], c))
    return 1 if nerr else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
