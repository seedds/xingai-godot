import sys, json, collections
sys.path.insert(0,'tools')
from pe import PE
p=PE()
def names(va,n): return [p.read(va+16*i,16).split(b'\0')[0].decode('gbk','replace') for i in range(n)]
SP=names(0x4cc600,255); IT=names(0x4cb7a0,230)
imsg=open('orig/Imsg.e5','rb').read()
def txt(i): return imsg[i*200:(i+1)*200].split(b'\0')[0].decode('gbk','replace').strip()
cls=json.load(open('game/assets/data/classes.json')); cn={c['id']:c['name'] for c in cls}
items=json.load(open('game/assets/data/items.json'))
sites=json.load(open(sys.argv[1]+'/sites.json'))
specials=[]
for i in range(255):
    r=p.read(0x511000+16*i,16)
    ce=[{'class':r[12+2*k],'class_name':cn.get(r[12+2*k]),'value':r[13+2*k]} for k in range(2) if r[12+2*k]<0x50]
    specials.append({'id':i,'name':SP[i],'desc':txt(430+i) if i<180 else '','template_value':r[2],'initial_class_skills':ce})
carriers=collections.defaultdict(list)
for it in items:
    if it['category'] in ('weapon','armor') and it['treasure'] and it['special'] is not None: carriers[it['special']].append(it['id'])
    elif it['category']=='accessory': carriers[it['type']].append(it['id'])
t10=p.read(0x4cb5ca,0xf0); kind=p.read(0x4cb6ba,0xe6)
stat={0x20:'攻击%',0x21:'防御%',0x22:'精神%',0x23:'爆发%',0x24:'士气%',0x25:'HP%',0x26:'MP%',0x27:'exp+',0x28:'移动+',0x5c:'(9: 神魔附体)'}
ie=[]
for e in range(0x1a,0x100):
    i=e-0x1a
    grants=sorted({s['a1'] for s in sites if s['a2']==e and isinstance(s['a1'],int)})
    ie.append({'id':e,'name':IT[i],'kind':kind[i] if i<len(kind) else None,'lv10':t10[i] if i<len(t10) else None,'stat':stat.get(e),'grants_specials':grants,'items':carriers.get(e,[])})
json.dump({'specials':specials,'item_effects':ie},open(sys.argv[1]+'/base_data.json','w'),ensure_ascii=False,indent=1)
for x in ie:
    if x['items'] or x['grants_specials']:
        print('%#04x %-14s kind=%s lv10=%s stat=%s grants=%s items=%s'%(x['id'],x['name'],x['kind'],x['lv10'],x['stat'],[('%d %s'%(g,SP[g])) for g in x['grants_specials']],x['items'][:8]))
