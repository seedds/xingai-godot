"""Copy BGM mp3s (CD track N -> bgm/NN.mp3) and convert SE wavs to 16-bit PCM."""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import os, re, shutil, subprocess, sys
SRC = _REPO + '/wg2025'
DST = _REPO + '/game/assets/audio'
os.makedirs(DST + '/bgm', exist_ok=True); os.makedirs(DST + '/se', exist_ok=True)
for f in sorted(os.listdir(SRC + '/SoundTrk')):
    m = re.match(r'(\d+)-AudioTrack', f)
    if m and f.lower().endswith('.mp3'):
        shutil.copyfile(os.path.join(SRC, 'SoundTrk', f), '%s/bgm/%02d.mp3' % (DST, int(m.group(1))))
for f in sorted(os.listdir(SRC)):
    if f.lower().endswith('.wav'):
        out = '%s/se/%s.wav' % (DST, f[:-4].lower())
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', os.path.join(SRC, f), '-acodec', 'pcm_s16le', out], check=True)
print(len(os.listdir(DST + '/bgm')), 'bgm', len(os.listdir(DST + '/se')), 'se')
