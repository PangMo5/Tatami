#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Export explicit, accepted takes to a reviewable web asset bundle. Never publishes."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys
from video_gallery import collection
from video_theme import palette, restyle

ROOT = Path(__file__).resolve().parents[1]


def run(args):
    subprocess.run([str(x) for x in args], check=True)


def probe(movie):
    return json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(movie)
    ]))


def sha(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def validate_take(movie, asset):
    record = json.loads(movie.with_suffix('.take.json').read_text())
    if record.get('schemaVersion') != 2 or record.get('status') != 'passed':
        raise ValueError(f'{movie}: a passed v2 take is required')
    if record.get('scene') != asset['scene'] or record.get('overlay') != 'off':
        raise ValueError(f'{movie}: wrong scene or live overlay already burned in')
    if record['sceneSHA256'] != sha(ROOT / 'scenes' / (asset['scene'] + '.json')):
        raise ValueError(f'{movie}: scene changed after capture; re-record before exporting')
    if record['frames'] <= 0 or record['droppedFrames'] / record['frames'] > .01:
        raise ValueError(f'{movie}: missing frames or more than 1% capture drops')
    timeline = json.loads(movie.with_suffix('.timeline.json').read_text())
    info = probe(movie)
    duration = float(info['format']['duration'])
    video = next(s for s in info['streams'] if s['codec_type'] == 'video')
    expected_size=(3840,1200) if asset.get('presentation')=='dual' else (1920,1200)
    if (video['width'], video['height']) != expected_size:
        raise ValueError(f'{movie}: publishing canvas expects 1920x1200 capture')
    if not 1 < duration <= asset['maxSeconds']:
        raise ValueError(f'{movie}: {duration:.1f}s exceeds the {asset["maxSeconds"]}s editorial budget')
    if abs(duration - timeline['durationSeconds']) > .35:
        raise ValueError(f'{movie}: capture clock and narration differ by more than 350ms')
    captions = [e for e in timeline['events'] if e['track'] == 'caption' and e['text']]
    if not captions or captions[0]['start'] > .35:
        raise ValueError(f'{movie}: opening narration is late or missing')
    return record, duration


def export(movie, asset, destination):
    record, duration = validate_take(movie, asset)
    target = destination / (asset['scene'] + '.mp4')
    if target.exists():
        raise ValueError(f'{target} exists; choose a new output folder')
    with tempfile.TemporaryDirectory(prefix='tatami-export-') as scratch:
        intermediate = Path(scratch) / 'encoded.mp4'
        styled = Path(scratch) / 'film.ass'
        subtitles=restyle(movie.with_suffix('.ass').read_text())
        if asset.get('presentation')=='dual':
            subtitles=subtitles.replace('PlayResY: 1200','PlayResY: 800')
        styled.write_text(subtitles)
        geometry='scale=1760:550:flags=lanczos,pad=1920:800:80:80' if asset.get('presentation')=='dual' else 'scale=1664:1040:flags=lanczos,pad=1920:1200:128:48'

        run(['mpv', '--no-config', movie, '--no-audio', '--sub-auto=no',
             '--sub-file=' + str(styled), '--sub-visibility=yes',
             '--sub-ass-override=no',
             f'--vf=lavfi=[fps=30,{geometry}:color=0x{palette()["background"]},format=yuv420p],sub',
             '--ovc=libx264', '--ovcopts=crf=21,preset=medium', '--of=mp4',
             '--o=' + str(intermediate), '--msg-level=all=warn'])
        run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', intermediate,
             '-map', '0:v:0', '-c', 'copy', '-movflags', '+faststart', target])
    output = probe(target)
    video = next(s for s in output['streams'] if s['codec_type'] == 'video')
    if video['codec_name'] != 'h264' or video['pix_fmt'] != 'yuv420p':
        raise ValueError(f'{target}: incompatible web encoding')
    if abs(float(output['format']['duration']) - duration) > .15:
        raise ValueError(f'{target}: duration changed during encoding')
    if target.stat().st_size > asset['maxMB'] * 1024**2:
        raise ValueError(f'{target}: exceeds {asset["maxMB"]} MB budget')
    # Decode the entire delivery, not just its header.
    run(['ffmpeg', '-v', 'error', '-xerror', '-i', target, '-f', 'null', '-'])
    poster = target.with_suffix('.jpg')
    captions = [e for e in json.loads(movie.with_suffix('.timeline.json').read_text())['events']
                if e['track'] == 'caption' and e['text']]
    cue = asset.get('posterCaptionIndex')
    poster_time = captions[cue]['start'] + .3 if cue is not None else .5
    run(['ffmpeg', '-v', 'error', '-ss', str(poster_time), '-i', target, '-frames:v', '1', '-q:v', '2', poster])
    evidence = destination / 'evidence'
    evidence.mkdir(exist_ok=True)
    # Regular samples include the opening and final state; human review stays explicit.
    timeline = json.loads(movie.with_suffix('.timeline.json').read_text())
    chapter_samples = [min(e['end'] - .1, e['start'] + 3) for e in timeline['events']
                       if e['track'] == 'chapter' and e['text'] and e['end'] - e['start'] > .2]
    sample_times = sorted(set([0, .5, 2, duration * .25, duration * .5, duration * .75, duration - .2] + chapter_samples))
    for index, second in enumerate(sample_times):
        run(['ffmpeg', '-v', 'error', '-ss', str(max(0, second)), '-i', target,
             '-frames:v', '1', '-q:v', '3', evidence / f'{asset["scene"]}-{index}.jpg'])
    for suffix in ['.ass', '.timeline.json', '.take.json', '.scene.json']:
        shutil.copy2(movie.with_suffix(suffix), evidence / (asset['scene'] + suffix))
    (evidence / (asset['scene'] + '.ass')).write_text(subtitles)
    return dict(asset, durationSeconds=round(duration, 2), bytes=target.stat().st_size,
                sha256=sha(target), sourceSHA256=sha(movie), tatamiVersion=record['tatamiVersion'],
                video=target.name, poster=poster.name)


def gallery(destination, records):
    groups = {}
    for asset in records:
        groups.setdefault(asset['section'], []).append(asset)
    labels = {'demo':'The complete workflow','workspaces':'Workspaces','profiles':'Profiles & displays',
              'tiling':'Tiling & focus','borrow':'Borrow','floating':'Window modes',
              'automation':'CLI & hooks','guided-setup':'Guided Setup'}
    sections = []
    for name, assets in groups.items():
        sections.append(f'<section id="{name}"><div class="wrap"><h2>{labels.get(name,name)}</h2>' + collection(name, assets) + '</div></section>')
    shutil.copy2(ROOT.parent/'web/style.css', destination/'style.css')
    shutil.copy2(ROOT.parent/'web/demos.js', destination/'demos.js')
    (destination/'index.html').write_text('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tatami · Demo library</title><link rel="stylesheet" href="style.css"></head><body><section class="hero"><div class="wrap"><p class="eyebrow">TATAMI / DEMO LAB</p><h1>Make room for the whole workflow.</h1><p class="sub">Real Tatami, interactive demo apps, and a collection of focused demonstrations.</p></div></section>' + ''.join(sections) + '<script src="demos.js" defer></script></body></html>')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--takes', required=True, type=Path, help='directory of <scene>.mov + sidecars')
    parser.add_argument('--output', required=True, type=Path, help='new local review bundle')
    parser.add_argument('--scenes', nargs='+', help='subset of publication.json')
    args = parser.parse_args()
    for tool in ['mpv', 'ffmpeg', 'ffprobe']:
        if not shutil.which(tool):
            parser.error(f'{tool} is required on the export host')
    contract = json.loads((ROOT / 'publication.json').read_text())
    assets = contract['assets']
    if args.scenes:
        unknown = set(args.scenes) - {a['scene'] for a in assets}
        if unknown:
            parser.error(f'unknown scenes: {sorted(unknown)}')
        assets = [a for a in assets if a['scene'] in args.scenes]
    for asset in assets:
        if asset.get('presentation') == 'dual' and not (args.takes/(asset['scene']+'.mkv')).exists():
            run([sys.executable, ROOT/'scripts/compose-displays.py', args.takes, asset['scene']])
    # Validate the entire requested batch before spending time encoding any file.
    for asset in assets:
        validate_take(args.takes / (asset['scene'] + ('.mkv' if asset.get('presentation')=='dual' else '.mov')), asset)
    args.output.mkdir(parents=True, exist_ok=False)
    records = []
    for asset in assets:
        print(f'Exporting {asset["scene"]}', flush=True)
        records.append(export(args.takes / (asset['scene'] + ('.mkv' if asset.get('presentation')=='dual' else '.mov')), asset, args.output))
    (args.output / 'theme.json').write_text(json.dumps(palette(),indent=2)+'\n')
    (args.output / 'manifest.json').write_text(json.dumps(dict(schemaVersion=1, assets=records), indent=2) + '\n')
    gallery(args.output, records)
    print(f'Review: {args.output / "index.html"}')


if __name__ == '__main__':
    main()
