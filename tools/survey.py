import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys, os, collections
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
from ls12 import read_archive
for p in sys.argv[1:]:
    d = open(p,'rb').read()
    print('==', os.path.basename(p), len(d), d[:16].hex())
    try:
        es = read_archive(d)
    except AssertionError:
        continue
    sizes = collections.Counter(len(e) for e in es)
    print('  entries', len(es), 'sizes', sizes.most_common(8))
    for i, e in enumerate(es[:4]):
        print('   ', i, len(e), e[:32].hex())
