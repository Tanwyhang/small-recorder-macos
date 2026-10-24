"""Exercise the actual FFmpeg filter, not just the generated command strings."""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
ffmpeg = shutil.which('ffmpeg')
ffprobe = shutil.which('ffprobe')
assert ffmpeg and ffprobe, 'Install FFmpeg before running the integration test.'


def run(*args):
    return subprocess.check_output(args, cwd=root)


run(ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
    '-t', '4', '-c:v', 'libx264', '-preset', 'veryfast', '-c:a', 'aac', 'fixture.mp4')
filter_graph = (root / 'filter.txt').read_text()
run(ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-i', 'fixture.mp4',
    '-map', '0:v:0', '-map', '0:a?', '-vf', filter_graph,
    '-c:v', 'libx264', '-preset', 'fast', '-crf', '25',
    '-maxrate', '2000000', '-bufsize', '4000000', '-pix_fmt', 'yuv420p',
    '-c:a', 'copy', '-movflags', '+faststart', 'follow-test.mp4')
probe = json.loads(run(ffprobe, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', 'follow-test.mp4'))
assert abs(float(probe['format']['duration']) - 4) < 0.1
video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
assert (video['width'], video['height'], int(video['nb_frames'])) == (1280, 720, 120)
assert any(s['codec_type'] == 'audio' for s in probe['streams'])
run(ffmpeg, '-v', 'error', '-i', 'follow-test.mp4', '-f', 'null', '-')


def frame_hash(graph, frame):
    result = run(ffmpeg, '-v', 'error', '-i', 'fixture.mp4', '-an', '-vf',
                 graph + f',select=eq(n\\,{frame})', '-fps_mode', 'passthrough', '-f', 'framemd5', '-')
    rows = [line for line in result.decode().splitlines() if not line.startswith('#') and line.strip()]
    assert len(rows) == 1
    return rows[0].split(',')[-1].strip()


# Pixel-exact checks before lossy encoding: the camera must reach the right
# crop, then return. These catch a silently ignored FFmpeg sendcmd target.
for frame, x, y in [(0, 122, 70), (117, 122, 70)]:
    expected = (f'fps=30,scale=2560:1440:flags=bicubic,'
                f'crop=2438:1370:{x}:{y}:exact=1,scale=1280:720:flags=lanczos,setsar=1')
    assert frame_hash(filter_graph, frame) == frame_hash(expected, frame), f'Incorrect crop at frame {frame}'
print('PASS: actual camera positions match pixel-for-pixel; full duration, frame count and audio preserved; decode clean')

# Verify intermediate frames, including 1/30 and 2/30 boundaries. Scheduling
# commands a microsecond before a frame avoids rounding them onto the next one.
commands = (root / 'motion.txt').read_text().splitlines()
for frame in [14, 16, 17, 19, 20]:
    x, y = re.search(r"x ([0-9.]+), crop@follow y ([0-9.]+)", commands[frame]).groups()
    expected = (f'fps=30,scale=2560:1440:flags=bicubic,'
                f'crop=2438:1370:{x}:{y}:exact=1,scale=1280:720:flags=lanczos,setsar=1')
    assert frame_hash(filter_graph, frame) == frame_hash(expected, frame), f'Motion command late at frame {frame}'
print('PASS: every tested movement command lands on its intended video frame')

# Exercise the timestamp format emitted by the installed FFmpeg, including a
# large input start time. Its integer offset must preserve sub-second precision.
run(ffmpeg, '-v', 'error', '-y', '-i', 'fixture.mp4', '-c', 'copy',
    '-output_ts_offset', '1234567.89', 'clock-fixture.mkv')
trace = subprocess.run([ffmpeg, '-hide_banner', '-debug_ts', '-i', 'clock-fixture.mkv',
                        '-frames:v', '1', '-an', '-f', 'null', '-'], cwd=root,
                       capture_output=True, text=True, check=True).stderr
line = next(line for line in trace.splitlines() if 'demuxer+ffmpeg ->' in line and 'type:video' in line)
offset = int(re.search(r'\boff:(-?\d+)\b', line).group(1))
assert abs(-offset / 1_000_000 - 1234567.89) < 0.1
print('PASS: installed FFmpeg exposes the exact input clock offset in microseconds')

# A display-sized source must stay at its captured dimensions in Native mode;
# FPS is chosen independently, including a non-preset value.
filters = (root / 'settings-filters.txt').read_text().splitlines()
for label, graph, fps, expected in [('native', filters[0], 48, (2560, 1600)),
                                    ('hd', filters[1], 24, (1728, 1080))]:
    run(ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=2560x1600:rate=60',
        '-t', '0.5', '-vf', graph, '-r', str(fps), '-c:v', 'libx264', '-preset', 'ultrafast', label + '.mp4')
    streams = json.loads(run(ffprobe, '-v', 'error', '-show_streams', '-of', 'json', label + '.mp4'))['streams']
    video = streams[0]
    assert (video['width'], video['height']) == expected
    assert video['avg_frame_rate'] == f'{fps}/1'
    assert int(video['nb_frames']) == fps // 2
print('PASS: native 2560x1600 at custom 48 fps and 1080p at independent 24 fps')
