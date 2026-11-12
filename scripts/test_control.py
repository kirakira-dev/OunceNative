#!/usr/bin/env python3
"""Advance an opted-in, paused native host and capture the resulting game view."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import stat
import time


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--fifo', required=True, type=Path)
    p.add_argument('--log', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--frames', type=int, default=0)
    p.add_argument('--settle', type=int, default=0, help='additional neutral frames before capturing')
    p.add_argument('--buttons', default='', help='A+B, ZL, ZR, Plus, Minus, LS, RS, L, R, Left, Up, Right, Down')
    p.add_argument('--left', nargs=2, type=float, default=(0, 0), metavar=('X', 'Y'))
    p.add_argument('--right', nargs=2, type=float, default=(0, 0), metavar=('X', 'Y'))
    p.add_argument('--motion', nargs=2, type=float, default=(0, 0), metavar=('PITCH', 'YAW'), help='radians, applied once')
    p.add_argument('--timeout', type=float, default=60)
    a = p.parse_args()
    names = 'A B X Y LS RS L R ZL ZR Plus Minus Left Up Right Down'.split()
    bits = {n.lower(): 1 << i for i, n in enumerate(names)}
    try:
        buttons = 0
        for name in filter(None, a.buttons.split('+')):
            buttons |= bits[name.lower()]
    except KeyError as error:
        p.error(f'unknown button: {error.args[0]}')
    axes = [*a.left, *a.right]
    if not 0 <= a.frames <= 36000 or not 0 <= a.settle <= 36000 or any(not math.isfinite(x) or abs(x) > 1 for x in axes):
        p.error('frames/settle must be 0..36000 and axes must be -1..1')
    if any(not math.isfinite(x) or abs(x) > math.pi for x in a.motion):
        p.error('motion must be finite radians in -pi..pi')
    if not a.frames and (buttons or any(axes) or any(a.motion)):
        p.error('input requires a positive --frames count')
    if not math.isfinite(a.timeout) or a.timeout <= 0:
        p.error('timeout must be positive and finite')
    output = a.output.resolve()
    if output.exists() or output.with_suffix('.json').exists() or not output.parent.is_dir() or len(str(output).encode()) >= 1024 or '\n' in str(output):
        p.error('output must be a new absolute path with an existing parent, below 1024 bytes')
    if not stat.S_ISFIFO(a.fifo.stat().st_mode):
        p.error('--fifo must name the host control FIFO')

    def events():
        # The normal renderer log may grow large. Control status is recent.
        with a.log.open('rb') as log:
            log.seek(0, 2)
            log.seek(max(0, log.tell() - 65536))
            return re.findall(r'test control: (waiting frame \d+|step frame [^\n]+)', log.read().decode(errors='replace'))

    def image_complete():
        try:
            with output.open('rb') as image:
                image.seek(-12, 2)
                return image.read() == b'\x00\x00\x00\x00IEND\xaeB\x60\x82'
        except OSError:
            return False

    current = events()
    if not current or not current[-1].startswith('waiting frame '):
        p.error('host is not waiting at the frame gate')
    start = int(current[-1].split()[-1])
    commands = []
    if a.frames:
        commands.append(f'step {a.frames} {buttons} ' + ' '.join(str(round(x * 32767)) for x in axes) +
                        ' ' + ' '.join(str(x) for x in a.motion))
    if a.settle:
        commands.append(f'step {a.settle} 0 0 0 0 0 0 0')
    commands += [f'shot {output}', 'step 4 0 0 0 0 0 0 0']
    payload = ('\n'.join(commands) + '\n').encode()
    fd = os.open(a.fifo, os.O_WRONLY | os.O_NONBLOCK)
    try:
        if os.write(fd, payload) != len(payload):
            raise RuntimeError('partial FIFO write')
    finally:
        os.close(fd)
    end = start + a.frames + a.settle + 4
    deadline = time.monotonic() + a.timeout
    while time.monotonic() < deadline:
        status = events()
        if status and status[-1] == f'waiting frame {end}' and image_complete():
            result = dict(start_frame=start, end_frame=end, input_frames=a.frames,
                          settling_frames=a.settle + 4, buttons=a.buttons, left=a.left, right=a.right,
                          motion=a.motion, screenshot=str(output), commands=commands)
            output.with_suffix('.json').write_text(json.dumps(result, indent=2) + '\n')
            print(json.dumps(result))
            return
        time.sleep(.1)
    raise SystemExit(f'timed out waiting for frame {end} and {output}; inspect the host log')


if __name__ == '__main__':
    main()
