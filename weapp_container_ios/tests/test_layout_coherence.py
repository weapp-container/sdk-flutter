"""Host Swift checks plus source boundaries; never builds an App or uses devices."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
PLUGIN = HERE.parent / "ios/Classes/WeappContainerIosPlugin.swift"


class LayoutCoherenceTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "Host Swift compiler unavailable")
    def test_production_gate_deterministic_swift_cases(self):
        with tempfile.TemporaryDirectory(prefix="ios-layout-coherence-") as directory:
            executable = Path(directory) / "checks"
            built = subprocess.run(["swiftc", "-D", "WEAPP_LAYOUT_GATE_TESTS", "-parse-as-library",
                                    str(PLUGIN), str(HERE / "LayoutCoherenceChecks.swift"),
                                    "-o", str(executable)], capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            checked = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
            report = json.loads(checked.stdout)
            self.assertEqual(report["status"], "passed")
            self.assertGreaterEqual(report["count"], 28)
            self.assertEqual(report["count"], len(set(report["checks"])))
            self.assertEqual(report["nativeSessionsCreated"], 0)
            self.assertEqual(report["devicesUsed"], 0)

    def test_atomic_and_chrome_measurements_share_monotonic_deadline(self):
        source = PLUGIN.read_text()
        body = source.split("private func measureLayout(", 1)[1].split("private func close(", 1)[0]
        code = "\n".join(line.split("//", 1)[0] for line in body.splitlines())
        self.assertNotIn("Date(", code)
        self.assertIn("DispatchTime.now().uptimeNanoseconds", code)
        self.assertIn("measurement: measurement, lifetime: lifetime", code)
        self.assertIn("Task.sleep(nanoseconds: min(16_000_000, remaining))", code)
        self.assertIn("IOSLayoutMeasurement.snapshot(supplied)", code)
        self.assertIn("entry.session.state()", code)
        self.assertNotIn("requestHostLayoutObservation", code)
        self.assertNotIn("observeHostLayout", code)
        self.assertIn('"screenTop": Double(inScreen.minY)', code)
        self.assertNotIn("windowTop", code)
        self.assertIn("view.bounds.width.rounded()", code)
        self.assertIn("view.safeAreaInsets", code)

    def test_all_prepare_and_layout_paths_use_gate_and_retirement_invalidates_it(self):
        source = PLUGIN.read_text()
        self.assertIn('case "prepareHostLayout", "hostLayout":', source)
        self.assertIn('preparing: call.method == "prepareHostLayout"', source)
        self.assertIn("measurementOwnerCurrent(entry, lifetime)", source)
        self.assertIn("entry.retiringView == nil && entry.measurementLifetime == lifetime", source)
        for start, end in (("private func retireView(", "private func acceptPreparedChrome("),
                           ("private func close(", "private func retireAll(")):
            body = source.split(start, 1)[1].split(end, 1)[0]
            self.assertIn("entry.measurementLifetime = UUID()", body)


if __name__ == "__main__":
    unittest.main()
