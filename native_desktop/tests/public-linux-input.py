#!/usr/bin/env python3
"""X11 input acceptance; owns only its app process and Xvfb-run display."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from linux_window import delete_window

executable, output = Path(sys.argv[1]), Path(sys.argv[2])
for dependency in ('xdotool', 'import'):
    if shutil.which(dependency) is None:
        raise RuntimeError(f'Missing input-test dependency: {dependency}')
data = Path(tempfile.mkdtemp(prefix='application-data-', dir=output))
env = {**os.environ, 'XDG_DATA_HOME': str(data)}
window = None
actions = []
hot_restart = None


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def wait_for(condition, process, timeout=45):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if process.poll() is not None:
            raise RuntimeError(f'Consumer exited early: {process.returncode}')
        result = condition()
        if result:
            return result
        time.sleep(0.05)
    raise TimeoutError('Consumer did not reach expected state')


def read_report():
    for file in data.glob('**/sdk-flutter-report.json'):
        try:
            return json.loads(file.read_text())
        except json.JSONDecodeError:
            pass  # The application writes asynchronously.
    return None


def report_at(stage):
    report = read_report()
    if report and report['status'] == 'failed':
        raise RuntimeError(json.dumps(report))
    return report if report and report['stage'] == stage else None


with (output / 'application.log').open('w') as log:
    process = subprocess.Popen([str(executable)], env=env, stdout=log, stderr=log)
    try:
        def find_window():
            # Dart can publish ready before GTK maps its first X11 window.
            found = subprocess.run(
                ['xdotool', 'search', '--onlyvisible', '--pid', str(process.pid)],
                capture_output=True, text=True, check=False)
            if found.returncode == 1 and not found.stdout.strip():
                return None
            if found.returncode != 0:
                raise RuntimeError(found.stderr)
            matches = found.stdout.strip().splitlines()
            if len(matches) != 1:
                raise RuntimeError(f'Expected one owned consumer window, got {matches}')
            return matches[0]
        window = wait_for(find_window, process)
        run('xdotool', 'windowfocus', '--sync', window)
        ready = wait_for(lambda: report_at('ready-for-input'), process)
        (output / 'before-input.json').write_text(json.dumps(ready, indent=2) + '\n')
        run('import', '-window', window, str(output / 'before-input.png'))
        geometry = ready['geometry']
        origin, tap, scroll = geometry['viewOrigin'], geometry['tap'], geometry['scroll']
        ratio = geometry['pixelRatio']
        x, y = [round((origin[axis] + tap[axis]) * ratio) for axis in ('x', 'y')]
        if len(sys.argv) > 3:
            from flutter_hot_restart import restart
            run('xdotool', 'mousemove', '--sync', '--window', window, str(x), str(y))
            run('xdotool', 'click', '1')
            # The standard consumer persists its report at milestones, not
            # for every tap. The final exact count proves this click persisted.
            report_file = next(data.glob('**/sdk-flutter-report.json'))
            before_timestamp = report_file.stat().st_mtime_ns
            time.sleep(0.2)
            run('import', '-window', window, str(output / 'before-restart.png'))
            hot_restart = restart(sys.argv[3], process, output / 'application.log', output, Path.cwd())
            wait_for(lambda: (value if (value := report_at('ready-for-input'))
                               and report_file.stat().st_mtime_ns > before_timestamp else None), process)
            run('import', '-window', window, str(output / 'after-restart.png'))
            actions.append({'kind': 'Flutter tool app.restart', 'fullRestart': True,
                            'processId': process.pid})
        run('xdotool', 'mousemove', '--sync', '--window', window, str(x), str(y))
        run('xdotool', 'click', '1')
        actions.append({'kind': 'XTest pointer click', 'window': window, 'x': x, 'y': y})
        x = round((origin['x'] + scroll['x'] + scroll['width'] / 2) * ratio)
        y = round((origin['y'] + scroll['y'] + scroll['height'] / 2) * ratio)
        run('xdotool', 'mousemove', '--sync', '--window', window, str(x), str(y))
        run('xdotool', 'click', '5')
        actions.append({'kind': 'XTest pointer wheel', 'window': window, 'x': x, 'y': y, 'steps': 1})
        result = wait_for(lambda: report_at('complete'), process)
        if hot_restart and result.get('tapCount') != 2:
            raise RuntimeError('Expected both pre-restart and post-restart native clicks to persist')
        if result['status'] != 'passed' or len(result['checks']) != 10:
            raise RuntimeError(json.dumps(result))
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        run('import', '-window', window, str(output / 'complete.png'))
        delete_window(window)
        actions.append({'kind': 'WM_DELETE_WINDOW', 'window': window})
        exit_code = process.wait(timeout=20)
        if exit_code:
            raise RuntimeError(f'Normal engine shutdown failed: {exit_code}')
        (output / 'input-and-shutdown.json').write_text(json.dumps({
            'status': 'passed', 'backend': 'X11', 'display': os.environ['DISPLAY'],
            'applicationData': str(data),
            'actions': actions, 'processExitCode': exit_code,
            'hotRestart': hot_restart,
            'wayland': 'not executed',
        }, indent=2) + '\n')
    except Exception as error:
        (output / 'failure.json').write_text(json.dumps({
            'status': 'failed', 'error': str(error), 'report': read_report(),
            'actions': actions, 'hotRestart': hot_restart,
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
                raise RuntimeError('Owned test process required forced cleanup')
