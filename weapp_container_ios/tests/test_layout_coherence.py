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
            fixture = json.loads((HERE.parent.parent / "weapp_container/test/fixtures/ios-layout-cancellation-v1.json").read_text())
            self.assertEqual(report["cancellationContracts"], fixture["contracts"])

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
        self.assertIn("measurementOwnerCancellation(entry, lifetime)", source)
        self.assertIn("viewRetiring: entry.retiringView != nil, lifetimeCurrent: entry.measurementLifetime == lifetime", source)
        for start, end in (("private func retireView(", "private func acceptPreparedChrome("),
                           ("private func close(", "private func retireAll(")):
            body = source.split(start, 1)[1].split(end, 1)[0]
            self.assertIn("entry.measurementLifetime = UUID()", body)

    def test_restart_authority_is_native_metadata_and_rechecked_before_return(self):
        source = PLUGIN.read_text()
        measure = source.split("private func measureLayout(", 1)[1].split("private func updateChrome(", 1)[0]
        self.assertIn('if let context = frozen["restartAttempt"]', measure)
        self.assertIn('guard preparing, let value = context as? [String: Any]', measure)
        self.assertIn('restartAttempt: restartAttempt', measure)
        polling = source.split("private func measureChrome(", 1)[1].split("private func close(", 1)[0]
        self.assertEqual(polling.count('restartMeasurementSnapshot(entry, measurement)'), 2)
        self.assertIn('state: final.state', polling)
        self.assertIn('restartReceipt: final.receipt', polling)
        metadata = source.split("private func restartMeasurementSnapshot(", 1)[1].split("private func measureChrome(", 1)[0]
        self.assertIn('entry.session.queryDevPackAttemptForLayout(ownerId: owner, attemptId: attempt)', metadata)
        self.assertNotIn('executeCommand(', metadata)
        self.assertIn('case "capabilities": return try mergeAdapterCapabilities(session.capabilities())', source)
        prepare = source.split('case "prepareView":', 1)[1].split('case "detachView":', 1)[0]
        self.assertIn('return try mergeAdapterCapabilities(capabilities)', prepare)
        self.assertIn('atomic["preparedRestartMeasurement"] = "1.0"', source)
        self.assertIn('if trueBoolean(atomic["enabled"])', source)
        returned = measure.split('var layout:', 1)[1]
        self.assertNotIn('restartAttempt', returned)

    def test_typed_failure_is_forwarded_without_message_inference_or_raw_details(self):
        source = PLUGIN.read_text()
        boundary = source.split("catch let error as IOSLayoutMeasurementError {", 1)[1].split("catch {", 1)[0]
        self.assertIn("let failure = error.wireFailure", boundary)
        self.assertIn("FlutterError(code: failure.code, message: failure.message, details: failure.details)", boundary)
        self.assertIn("try decision.requireReadyOrWaiting()", source)
        self.assertIn("catch is CancellationError { throw IOSLayoutMeasurementError.cancelled(.taskCancelled) }", source)
        self.assertNotIn("ownerCurrent:", source)
        self.assertNotIn('details: error', source)


if __name__ == "__main__":
    unittest.main()
