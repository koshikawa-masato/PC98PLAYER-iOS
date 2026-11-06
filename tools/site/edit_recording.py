"""Join three real screen recordings with chapter titles and fade-to-black cuts.

Usage: python3 tools/site/edit_recording.py demo.mov transfer.mov nas.mov --output /tmp/real-guide.mp4
Input order: built-in demo, ZIP transfer, NAS connection. Inputs are never modified.
Requires ffmpeg (libx264), ffprobe, and Noto Sans CJK. Output is intentionally silent.
"""
import argparse
import json
from pathlib import Path
import subprocess


def duration(path):
    data = subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'json', str(path)])
    return float(json.loads(data)['format']['duration'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('clips', nargs=3, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--font', type=Path, default=Path('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'))
    args = parser.parse_args()
    if not args.font.is_file():
        parser.error('Japanese font is missing; supply --font')
    if args.output.exists() or args.output.resolve() in [x.resolve() for x in args.clips]:
        parser.error('Choose a new output path; existing files will not be overwritten')
    lengths = [duration(x) for x in args.clips]
    if any(x < 3 for x in lengths):
        parser.error('Each chapter must be at least 3 seconds')
    titles = ['01 / デモを起動して入力', '02 / ZIP を展開して開く', '03 / NAS に接続して起動']
    # Normalize recordings without cropping the device display or speeding up actions.
    filters = []
    for i, title in enumerate(titles):
        filters.append(f'[{i}:v]fps=30,scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=0x182d29,setsar=1,format=yuv420p,settb=AVTB,setpts=PTS-STARTPTS,drawtext=fontfile={args.font}:text={title}:fontsize=26:fontcolor=white:box=1:boxcolor=0x182d29@0.95:boxborderw=12:x=24:y=24:enable=\'lt(t,2.5)\',fps=30[v{i}]')
    offset1 = lengths[0] - .6
    offset2 = lengths[0] + lengths[1] - 1.2
    filters += [f'[v0][v1]xfade=transition=fadeblack:duration=0.6:offset={offset1},fps=30[a]', f'[a][v2]xfade=transition=fadeblack:duration=0.6:offset={offset2}[out]']
    cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-n', '-filter_complex_threads', '1']
    for clip in args.clips:
        cmd += ['-i', str(clip)]
    cmd += ['-filter_complex', ';'.join(filters), '-map', '[out]', '-an', '-c:v', 'libx264', '-threads', '2', '-crf', '22', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(args.output)]
    subprocess.run(cmd, check=True)
    print(f'Created {args.output}; chapters begin at 0, {offset1:.2f}, {offset2:.2f} seconds. Audio omitted.')


if __name__ == '__main__':
    main()
