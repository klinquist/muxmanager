#!/usr/bin/env python3
"""Export captured app footage with a local FFmpeg binary; adds no app dependency."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'output/app-store/2026-10'

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ffmpeg', default='ffmpeg')
args = parser.parse_args()
tool = Path('/private/tmp/mux-app-store-video')
subprocess.run(['swiftc', '-module-cache-path', '/private/tmp/mux-store-render-modules', '-parse-as-library', str(ROOT / 'scripts/app-store/video.swift'), '-o', str(tool)], check=True)
for family, width, height in [('iphone', 886, 1920), ('ipad', 1200, 1600)]:
    destination = OUTPUT / f'previews/{family}-preview.mp4'
    destination.parent.mkdir(exist_ok=True)
    subprocess.run([
        args.ffmpeg, '-y', '-v', 'error', '-t', '15', '-i', str(OUTPUT / f'recordings/{family}-native.mov'),
        '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo', '-t', '24', '-r', '30',
        '-vf', f'scale={width}:{height}:flags=lanczos,tpad=stop_mode=clone:stop_duration=10',
        '-c:v', 'libx264', '-preset', 'medium', '-profile:v', 'high', '-level:v', '4.0', '-pix_fmt', 'yuv420p',
        '-b:v', '10M', '-maxrate', '12M', '-bufsize', '24M',
        '-c:a', 'aac', '-b:a', '256k', '-shortest', '-movflags', '+faststart', str(destination)
    ], check=True)
    subprocess.run([str(tool), 'inspect', str(destination)], check=True)
