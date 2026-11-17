#!/usr/bin/env python3
"""Real X11 input for Flutter host scrolling, Navigator, and presentation leases."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from linux_window import delete_window

executable, output = Path(sys.argv[1]), Path(sys.argv[2])
data = Path(tempfile.mkdtemp(prefix='application-data-', dir=output))
env = {**os.environ, 'XDG_DATA_HOME': str(data)}
window = None
actions = []


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def report():
    for file in data.glob('**/sdk-flutter-host-lifecycle.json'):
        try:
            return json.loads(file.read_text())
        except json.JSONDecodeError:
            pass
    return None


def wait_for(condition, process, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'Owned host exited early: {process.returncode}')
        value = report()
        if value and value.get('error'):
            raise RuntimeError(json.dumps(value))
        found = condition(value)
        if found:
            return found
        time.sleep(0.05)
    raise TimeoutError(f'Host did not reach expected state: {report()}')


def stage(name, process):
    return wait_for(lambda value: value if value and value['stage'] == name else None, process)


def pointer(x, y, button=None):
    run('xdotool', 'mousemove', '--sync', '--window', window, str(round(x)), str(round(y)))
    if button:
        run('xdotool', 'click', str(button))
    actions.append({'kind': 'XTest pointer', 'x': x, 'y': y, 'button': button})


def screenshot(name):
    run('import', '-window', window, str(output / name))


with (output / 'application.log').open('w') as log:
    process = subprocess.Popen([str(executable)], env=env, stdout=log, stderr=log)
    try:
        def find_window(_):
            found = subprocess.run(['xdotool', 'search', '--onlyvisible', '--pid', str(process.pid)],
                                   capture_output=True, text=True, check=False)
            if found.returncode == 1 and not found.stdout.strip():
                return None
            if found.returncode:
                raise RuntimeError(found.stderr)
            values = found.stdout.strip().splitlines()
            if len(values) != 1:
                raise RuntimeError(f'Ambiguous owned application windows: {values}')
            return values[0]

        window = wait_for(find_window, process)
        run('xdotool', 'windowfocus', '--sync', window)
        ready = stage('scroll-parent-then-check', process)
        dimensions = dict(line.split('=', 1) for line in run('xdotool', 'getwindowgeometry', '--shell', window).splitlines())
        ratio = ready['geometry']['pixelRatio']
        width = int(dimensions['WIDTH'])
        action_x, action_y = width - 65 * ratio, 28 * ratio
        screenshot('initial.png')
        pointer(width / 2, 178 * ratio, 5)
        wait_for(lambda value: value if value and value['parentOffset'] >= 20 else None, process)
        pointer(action_x, action_y, 1)
        ready = stage('click-child-after-parent-scroll', process)
        origin, geometry = ready['viewOrigin'], ready['geometry']
        pointer((origin['x'] + geometry['tap']['x']) * ratio,
                (origin['y'] + geometry['tap']['y']) * ratio, 1)
        ready = stage('scroll-child', process)
        scroll = geometry['scroll']
        x = (origin['x'] + scroll['x'] + scroll['width'] / 2) * ratio
        y = (origin['y'] + scroll['y'] + scroll['height'] / 2) * ratio
        pointer(x, y, 5)
        stage('arm-child-drag', process)
        screenshot('after-child-wheel.png')
        pointer(action_x, action_y, 1)
        stage('drag-child', process)
        pointer(x, y + 35 * ratio)
        run('xdotool', 'mousedown', '1')
        try:
            for index in range(1, 11):
                run('xdotool', 'mousemove', '--sync', '--window', window,
                    str(round(x)), str(round(y + (35 - index * 8) * ratio)))
                time.sleep(0.02)
        finally:
            run('xdotool', 'mouseup', '1')
        actions.append({'kind': 'XTest pointer drag', 'from': [x, y + 35 * ratio],
                        'to': [x, y - 45 * ratio]})
        stage('move-route', process)
        screenshot('after-child-drag.png')
        pointer(action_x, action_y, 1)
        stage('pop-flutter-route', process)
        time.sleep(0.4)  # Let the real Material route transition finish.
        screenshot('detail-route.png')
        pointer(28 * ratio, 28 * ratio, 1)
        stage('ready-to-close', process)
        screenshot('primary-restored.png')
        pointer(action_x, action_y, 1)
        result = stage('complete', process)
        if result['status'] != 'passed' or len(result['checks']) != 10:
            raise RuntimeError(json.dumps(result))
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        screenshot('complete.png')
        delete_window(window)
        actions.append({'kind': 'WM_DELETE_WINDOW', 'window': window})
        code = process.wait(timeout=20)
        if code:
            raise RuntimeError(f'Owned host normal shutdown failed: {code}')
        (output / 'input-and-shutdown.json').write_text(json.dumps({
            'status': 'passed', 'backend': 'X11', 'display': os.environ['DISPLAY'],
            'processId': process.pid, 'processExitCode': code,
            'applicationData': str(data), 'actions': actions, 'wayland': 'not executed',
        }, indent=2) + '\n')
    except Exception as error:
        (output / 'failure.json').write_text(json.dumps({
            'status': 'failed', 'error': str(error), 'report': report(), 'actions': actions,
        }, indent=2) + '\n')
        raise
    finally:
        if process.poll() is None:
            if window is not None:
                delete_window(window)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                raise RuntimeError('Owned host process required forced cleanup')
