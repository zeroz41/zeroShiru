#!/usr/bin/env bash
# Regenerates test/fixtures/episode.mkv, the synthetic release the playback unit tests stream.
#
# The numbers are load-bearing: 600 seconds of duration in ~70KB gives a byte rate of ~115 B/s,
# so DebridMetadata's pacing window (120s ahead) is ~14KB and a seek to 450s lands around byte
# 50k — the tests can watch pacing and seeking happen without a real-sized video. Two subtitle
# tracks (ASS + SRT), audio, chapters and a font attachment cover every kind of sidecar the
# player consumes.
set -euo pipefail
cd "$(mktemp -d)"

python3 - <<'EOF'
lines = ["[Script Info]", "Title: Fixture ASS", "ScriptType: v4.00+", "PlayResX: 1280", "PlayResY: 720", "",
"[V4+ Styles]",
"Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
"Style: Default,Fixture Sans,52,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2.6,0,2,20,20,46,1",
"Style: Signs,Fixture Sans,40,&H00FFFF00,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2.6,0,8,20,20,46,1",
"", "[Events]",
"Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"]
def ts(s): return f"{int(s//3600)}:{int(s%3600//60):02d}:{int(s%60):02d}.00"
for i in range(60):
    t = i * 10
    style = "Signs" if i % 10 == 0 else "Default"
    lines.append(f"Dialogue: 0,{ts(t)},{ts(t+4)},{style},,0,0,0,,ASS cue {i:03d} at {t}s")
open("subs.ass","w").write("\n".join(lines) + "\n")

srt = []
def ts2(s): return f"{int(s//3600):02d}:{int(s%3600//60):02d}:{int(s%60):02d},000"
for i in range(30):
    t = i * 20 + 5
    srt.append(f"{i+1}\n{ts2(t)} --> {ts2(t+4)}\nSRT cue {i:03d} at {t}s\n")
open("subs.srt","w").write("\n".join(srt))

meta = [";FFMETADATA1"]
for i, (start, title) in enumerate([(0,"Opening"),(150,"Part A"),(300,"Part B"),(450,"Ending")]):
    end = [150,300,450,600][i]
    meta += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={start*1000}", f"END={end*1000}", f"title={title}"]
open("chapters.txt","w").write("\n".join(meta) + "\n")

# a tiny stand-in font attachment: its bytes round-trip through the pipeline, never rendered
open("FixtureSans.ttf","wb").write(b"\x00\x01\x00\x00" + bytes(range(256)) * 4)
EOF

ffmpeg -y -v error \
  -f lavfi -i "color=c=black:s=64x64:r=1:d=600" \
  -f lavfi -i "anullsrc=r=8000:cl=mono:d=600" \
  -i subs.ass -i subs.srt -i chapters.txt \
  -map 0:v -map 1:a -map 2:s -map 3:s -map_metadata 4 -map_chapters 4 \
  -c:v libx264 -preset ultrafast -crf 51 -g 30 \
  -c:a aac -b:a 8k -c:s copy \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title="Full Subtitles" \
  -metadata:s:s:1 language=spa -metadata:s:s:1 title="Spanish" \
  -attach FixtureSans.ttf -metadata:s:t:0 mimetype=font/ttf \
  episode.mkv

cp episode.mkv "$(dirname "$0")/../fixtures/episode.mkv" 2>/dev/null || cp episode.mkv "$OLDPWD/test/fixtures/episode.mkv"
echo "wrote test/fixtures/episode.mkv ($(stat -c %s episode.mkv) bytes)"
