"""Copy the BGM mp3s (CD track N -> bgm/NN.mp3) and convert the sound effects to 16-bit PCM wavs.

usage: conv_audio.py [GAME_DIR]   (default <repo>/orig, read-only input)

The engine opens ".\\SoundTrk\\%02u-AudioTrack %02u.mp3" and SE%02u / SE_M_%02u / SE_E_%02u / SE_V_%03u .WAV
(strings in Ekd5.exe), so files not matching those names (backups such as "167-AudioTrack 167-.mp3",
"Se68-.wav", "Se_v_033~1.wav") are left out.
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import os, re, shutil, subprocess, sys
SRC = sys.argv[1] if len(sys.argv) > 1 else _REPO + '/orig'
DST = _REPO + '/game/assets/audio'
os.makedirs(DST + '/bgm', exist_ok=True)
os.makedirs(DST + '/se', exist_ok=True)

nb = 0
for f in sorted(os.listdir(SRC + '/SoundTrk')):
    m = re.fullmatch(r'(\d+)-AudioTrack (\d+)\.mp3', f, re.I)
    if m and m.group(1) == m.group(2):
        shutil.copyfile(os.path.join(SRC, 'SoundTrk', f), '%s/bgm/%02d.mp3' % (DST, int(m.group(1))))
        nb += 1

ns = 0
for f in sorted(os.listdir(SRC + '/WAV')):
    name = f.lower()
    if not re.fullmatch(r'se(\d\d|_m_\d\d|_e_\d\d|_v_\d\d\d)\.wav', name):
        continue
    out = '%s/se/%s' % (DST, name)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', os.path.join(SRC, 'WAV', f), '-acodec', 'pcm_s16le',
                    out], check=True)
    ns += 1
print(nb, 'bgm', ns, 'se')
