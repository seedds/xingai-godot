import sys,struct,glob,os
for p in sorted(glob.glob(sys.argv[1]+'/*.wagan')):
    d=open(p,'rb').read()
    first=struct.unpack_from('<I',d,10)[0]
    offs=[struct.unpack_from('<I',d,10+4*i)[0] for i in range((first-10)//4)]
    print(os.path.basename(p), len(d), d[4:10].hex(), [hex(o) for o in offs])
    for o in offs:
        print('   ', hex(o), d[o:o+24].hex(' '))
