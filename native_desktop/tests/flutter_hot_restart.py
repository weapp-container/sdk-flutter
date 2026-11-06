"""Perform a real Flutter tool hot restart and prove the Dart isolate changed."""
import json
from pathlib import Path
import queue
import re
import subprocess
import threading
import time
import urllib.request


def restart(flutter, application, log_path, output, cwd):
    output = Path(output)
    match = re.search(r'The Dart VM service is listening on (http://\S+)', Path(log_path).read_text())
    if not match:
        raise RuntimeError('Running debug consumer did not advertise a VM service')
    service = match.group(1)

    def vm():
        with urllib.request.urlopen(service + 'getVM', timeout=10) as response:
            return json.load(response)

    before = vm()
    (output / 'vm-before.json').write_text(json.dumps(before, indent=2) + '\n')
    events = queue.Queue()
    tool = subprocess.Popen([str(flutter), 'attach', '-d', 'linux', '--machine',
                             '--no-dds', '--no-devtools', '--debug-url', service],
                            cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, bufsize=1)
    messages = []

    def read_lines():
        with (output / 'flutter-machine-restart.log').open('w') as log:
            for line in tool.stdout:
                log.write(line)
                log.flush()
                try:
                    parsed = json.loads(line)
                    if isinstance(parsed, list):
                        for item in parsed:
                            events.put(item)
                except json.JSONDecodeError:
                    pass

    reader = threading.Thread(target=read_lines, daemon=True)
    reader.start()

    def await_event(predicate, timeout=90):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if application.poll() is not None:
                raise RuntimeError('Application exited during Flutter hot restart')
            try:
                item = events.get(timeout=0.1)
            except queue.Empty:
                if tool.poll() is not None:
                    raise RuntimeError(f'Flutter attach exited early: {tool.returncode}')
                continue
            messages.append(item)
            if predicate(item):
                return item
        raise TimeoutError('Flutter machine protocol did not complete')

    def send(identifier, method, app_id, **fields):
        value = [{'id': identifier, 'method': method,
                  'params': {'appId': app_id, **fields}}]
        tool.stdin.write(json.dumps(value) + '\n')
        tool.stdin.flush()

    app_id = None
    try:
        started = await_event(lambda item: item.get('event') == 'app.started')
        app_id = started['params']['appId']
        send(1, 'app.restart', app_id, fullRestart=True, pause=False)
        response = await_event(lambda item: item.get('id') == 1)
        if response.get('result', {}).get('code') != 0:
            raise RuntimeError(f'Flutter hot restart failed: {response}')
        after = vm()
        (output / 'vm-after.json').write_text(json.dumps(after, indent=2) + '\n')
        before_id = next(item['id'] for item in before['result']['isolates'] if item['name'] == 'main')
        after_id = next(item['id'] for item in after['result']['isolates'] if item['name'] == 'main')
        if before_id == after_id:
            raise RuntimeError('The real Flutter hot restart did not replace the main isolate')
        send(2, 'app.detach', app_id)
        await_event(lambda item: item.get('id') == 2)
        exit_code = tool.wait(timeout=15)
        reader.join(timeout=2)
        if exit_code:
            raise RuntimeError(f'Flutter detach failed: {exit_code}')
        result = {'status': 'passed', 'processIdBefore': application.pid,
                  'processIdAfter': application.pid, 'mainIsolateBefore': before_id,
                  'mainIsolateAfter': after_id, 'fullRestart': True,
                  'toolResultCode': response['result']['code'], 'toolExitCode': exit_code}
        (output / 'hot-restart.json').write_text(json.dumps(result, indent=2) + '\n')
        return result
    finally:
        if tool.poll() is None:
            if app_id is not None:
                try:
                    send(99, 'app.detach', app_id)
                    tool.wait(timeout=10)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            if tool.poll() is None:
                tool.terminate()
                try:
                    tool.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    tool.kill()
                    tool.wait()
                raise RuntimeError('Owned Flutter attach process required forced cleanup')
