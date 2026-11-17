"""Exercise the shared fixture against a prebuilt real SDK (no Rust required)."""
import ctypes as c
import hashlib
import json
from pathlib import Path
import sys
import time

library, pack, report_path = map(Path, sys.argv[1:4])
report = {"schemaVersion": 1, "status": "running", "checks": [],
          "librarySha256": hashlib.sha256(library.read_bytes()).hexdigest(),
          "packIntegrity": json.loads((pack / "manifest.json").read_text())["integrity"]["root"]}
lib = c.CDLL(str(library.resolve()))


class Buffer(c.Structure):
    _fields_ = [("data", c.c_void_p), ("len", c.c_size_t)]


handle = c.c_void_p()
lib.weapp_container_sdk_session_new.argtypes = [c.c_char_p, c.c_size_t, c.POINTER(c.c_void_p), c.POINTER(Buffer)]
lib.weapp_container_sdk_session_command.argtypes = [c.c_void_p, c.c_char_p, c.c_size_t, c.c_char_p, c.c_size_t, c.POINTER(Buffer)]
lib.weapp_container_sdk_session_destroy.argtypes = [c.POINTER(c.c_void_p), c.POINTER(Buffer)]
lib.weapp_container_sdk_buffer_free.argtypes = [c.POINTER(Buffer)]


def call(function, *args):
    result = Buffer()
    status = function(*args, c.byref(result))
    try:
        value = json.loads(c.string_at(result.data, result.len))
    finally:
        lib.weapp_container_sdk_buffer_free(c.byref(result))
    assert status == 0 and value["ok"], value
    return value["value"]


def command(name, payload=None):
    op = name.encode()
    data = json.dumps(payload or {}).encode()
    return call(lib.weapp_container_sdk_session_command, handle, op, len(op), data, len(data))


def messages():
    return [event["message"] for event in command("takeEvents") if event["type"] == "message"]


def point(kind, x, y):
    contact = {"identifier": 1, "clientX": x, "clientY": y, "pageX": x, "pageY": y}
    return {"type": kind, "x": x, "y": y, "timeStamp": time.monotonic() * 1000,
            "touches": [] if kind in ("touchend", "tap") else [contact], "changedTouches": [contact]}


failure = None
try:
    config = json.dumps({"engine": "quickjs", "host": {"windowWidth": 360, "windowHeight": 480}}).encode()
    call(lib.weapp_container_sdk_session_new, config, len(config), c.byref(handle))
    command("load", {"packPath": str(pack.resolve())})
    command("sendMessage", {"message": {"op": "inspect"}})
    geometry = next(message for message in messages() if message["kind"] == "geometry")
    report["geometry"] = geometry
    assert geometry["scroll"]["height"] > 0
    report["checks"].append("verified pack and live selector geometry")
    x, y = geometry["tap"]["x"], geometry["tap"]["y"]
    command("input", {"events": [point("touchstart", x, y), point("touchend", x, y), point("tap", x, y)]})
    events = messages()
    assert any(message["kind"] == "tap" and message["count"] == 1 for message in events), events
    deadline = time.monotonic() + 3
    while not any(message["kind"] == "timer" for message in events) and time.monotonic() < deadline:
        time.sleep(.01)
        command("pump")
        events.extend(messages())
    assert any(message["kind"] == "timer" and message["count"] == 1 for message in events), events
    report["checks"].append("tap and JavaScript timer")
    rect = geometry["scroll"]
    x, y = rect["left"] + rect["width"] / 2, rect["top"] + rect["height"] * .8
    command("input", {"events": [point("touchstart", x, y)]})
    for step in range(1, 6):
        command("input", {"events": [point("touchmove", x, y - step * 15)]})
    command("input", {"events": [point("touchend", x, y - 75)]})
    events = messages()
    assert any(message["kind"] == "scroll" and message["scrollTop"] > 0 for message in events), events
    report["checks"].append("drag gesture produces real scroll offset")
    command("navigate", {"route": "pages/detail/index", "query": {"source": "fixture-probe"}})
    assert command("state")["page"]["route"] == "pages/detail/index"
    command("back")
    assert command("state")["page"]["route"] == "pages/home/index"
    report["checks"].append("navigation and back preserve real page stack")
    command("sendMessage", {"message": {"op": "store", "value": {"unicode": "中文 🧊", "number": 17}}})
    command("sendMessage", {"message": {"op": "read"}})
    assert next(message for message in messages() if message["kind"] == "storedValue")["value"] == {"unicode": "中文 🧊", "number": 17}
    report["checks"].append("business messages and synchronous storage visibility")
    report["status"] = "passed"
except BaseException as error:
    failure = error
    report["status"] = "failed"
    report["error"] = str(error)
finally:
    if handle:
        try:
            call(lib.weapp_container_sdk_session_destroy, c.byref(handle))
        except BaseException as error:
            report["status"] = "failed"
            report["cleanupError"] = str(error)
            failure = failure or error
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(report, ensure_ascii=False))
if failure:
    raise failure
