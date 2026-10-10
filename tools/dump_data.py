import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys, os
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
from ls12 import read_archive
src, out = sys.argv[1], sys.argv[2]
es = read_archive(src)
for i, e in enumerate(es):
    open(os.path.join(out, 'data_e%d.bin' % i), 'wb').write(e)
    print(i, len(e))
