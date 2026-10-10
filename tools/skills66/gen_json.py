"""Build game/assets/data/skills.json (catalogue) from Ekd5.exe tables + the query-site list."""
import sys, json, os
S=sys.argv[1]; OUT=sys.argv[2]
base=json.load(open(S+'/base_data.json'))
sites=json.load(open(S+'/sites.json'))
extra=json.load(open(S+'/extra_queries.json')) if os.path.exists(S+'/extra_queries.json') else []
q={}
def add(a1,a2,mode,a4,wrapper,uses):
    k=(a1,a2,mode,a4)
    e=q.setdefault(k,{'sid':a1,'eid':a2,'mode':mode,'a4':a4,'wrappers':[],'call_sites':[]})
    if wrapper and wrapper not in e['wrappers']: e['wrappers'].append(wrapper)
    for u in uses:
        if u not in e['call_sites']: e['call_sites'].append(u)
for s in sites:
    if not isinstance(s['a1'],int) or not isinstance(s['a2'],int): continue
    if s.get('wrapper'): add(s['a1'],s['a2'],s['mode'],s['a4'],s['wrapper'],s.get('callers') or [])
    else: add(s['a1'],s['a2'],s['mode'],s['a4'],None,[s['site']])
for e in extra: add(e['sid'],e['eid'],e['mode'],e['a4'],e.get('wrapper'),e.get('call_sites',[]))
DISPATCH={'0x405942':'0x438f28 (table 0x415e2b)','0x405954':'0x438f28 (table 0x415e2b)','0x42f8a1':'0x42f8d9 (table 0x42f8c5)','0x42f8b3':'0x42f8d9 (table 0x42f8c5)','0x43d0d6':'0x42f8d9 (table 0x42f8c5)','0x43d0e8':'0x42f8d9 (table 0x42f8c5)','0x42114f':'0x412bf6 (table 0x412c70)','0x421162':'0x412bf6 (table 0x412c70)','0x42f88e':'0x42f8d9 (table 0x42f8c5)'}
for e in q.values():
    for w in e['wrappers']:
        if w in DISPATCH and DISPATCH[w] not in e['call_sites']: e['call_sites'].append(DISPATCH[w])
queries=sorted(q.values(),key=lambda e:(e['sid'],e['eid']))
out={'_doc':'docs/skills.md. specials = 特效 ids (names 0x4cc600, desc Imsg 430+id); item_effects = equipment effect ids (names 0x4cb7a0[id-0x1a], kind 0x4cb6ba, lv10 0x4cb5ca); queries = the fixed (sid, eid, mode, a4) pairs the engine asks 0x4101d9 / 0x41301e; mode 0 sum, 1 max, 2 first-nonzero (7 dominant), 3 OR; a4 != 0: a matching item counts 100.',
     'specials':base['specials'],'item_effects':base['item_effects'],'queries':queries}
if os.path.exists(S+'/bisha.json'): out['bisha']=json.load(open(S+'/bisha.json'))
json.dump(out,open(OUT,'w'),ensure_ascii=False,indent=1)
print('specials',len(out['specials']),'item_effects',len(out['item_effects']),'queries',len(queries))
