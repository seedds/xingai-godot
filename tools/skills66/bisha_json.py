import sys, json
sys.path.insert(0,'tools')
from pe import PE
from e5 import Archive
p=PE()
d=Archive('orig/Data.e5'); e5=d[5]; tail=e5[144*97:]
im=open('orig/Imsg.e5','rb').read()
def txt(i): return im[i*200:(i+1)*200].split(b'\0')[0].decode('gbk','replace')
persons=json.load(open('game/assets/data/persons.json')); pn={x['id']:x['name'] for x in persons}
fams=json.load(open('game/assets/data/class_families.json')); fn={x['id']:x['name'] for x in fams} if isinstance(fams,list) and 'id' in fams[0] else {i:x.get('name') for i,x in enumerate(fams)}
attr8=p.read(0x4d2200,40)
out=[]
for i in range(97):
    r=tail[i*16:(i+1)*16]
    e={'id':i,'name':r[:11].split(b'\0')[0].decode('gbk','replace'),
       'b11':r[11],'range_code':r[12],'pierce_shape':r[13],'sp_cost':r[14],'value':r[15],
       'description':txt(144+i)}
    if i<80:
        row=p.read(0x512000+16*i,16)
        e['learners']=[{'person':row[3*k]|row[3*k+1]<<8,'level':row[3*k+2]} for k in range(5)]
        e['family']=row[15]
        e['kind']='武将技 (menu)'
    else:
        e['kind']='文官必杀 (family attr8)'
        e['families']=[{'family':f,'name':fn.get(f)} for f in range(40) if attr8[f] and 0x4f+attr8[f]==i]
    out.append(e)
doc={'_source':'Ekd5.exe 6.6: records = Data.e5 e5 tail (97 x 16, runtime 0x4a7510, getter 0x41e918); learner table [0x500c37]=0x512000 (80 x 16, sub 6 0x40886e); see docs/skills.md',
     'fields':{'b11':'not read by battle logic found [G: icon]','range_code':'+0x0c attack range code replacing the class range when id!=0 (0x43f8ef)','pierce_shape':'+0x0d 穿透 shape (0x484e27 via 0x407835), 0 = none','sp_cost':'+0x0e SP cost (0x425ad0): menu needs SP>=cost (0x465bcd), spend SP-=min(SP,cost) (0x423910)','value':'+0x0f effect value returned by 0x436334(id,k) when the current 必杀 is k (0 = no forced effect)','learners':'5 slots (pid u16 (1024 = none), learn level u8); available if pid matches and person level >= level (0x418744)','family':'row byte 15: class family that has this 必杀 without learning (40 = none) (0x418755)'},
     'family_attr8':{str(f):attr8[f] for f in range(40) if attr8[f]},
     'skills':out}
json.dump(doc,open(sys.argv[1],'w'),ensure_ascii=False,indent=1)
print(len(out))
