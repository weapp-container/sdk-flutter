import Foundation

/// Deterministic checks of the production gate; no UIKit, native session or IO.
@main enum LayoutCoherenceChecks {
    struct Failure: Error { let message: String }
    static var passed: [String] = []
    static func check(_ name: String, _ body: () throws -> Void) throws {
        do { try body(); passed.append(name) }
        catch { throw Failure(message: name + ": " + String(describing: error)) }
    }
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String = "Unexpected gate decision") throws {
        if try !value() { throw Failure(message: message) }
    }
    static var metrics: [String: Any] { [
        "windowWidth": 375, "windowHeight": 600, "screenWidth": 375, "screenHeight": 812,
        "pixelRatio": 3.0, "statusBarHeight": 44.0, "screenTop": 88.0,
        "deviceOrientation": "portrait",
        "safeArea": ["left": 0, "top": 0, "right": 375, "bottom": 600, "width": 375, "height": 600],
    ] }
    static var observation: [String: Any] { [
        "schemaVersion": 1, "ownerId": "3", "surfaceGeneration": "2", "observationId": "10",
        "windowMetrics": metrics, "sessionId": "current-session", "pageId": 1,
    ] }
    static var health: [String: Any] { [
        "schemaVersion": 1, "requiresRestart": false, "appServiceFault": NSNull(),
        "viewFault": NSNull(), "navigationFault": NSNull(),
    ] }
    static var state: [String: Any] { [
        "schemaVersion": 1, "status": "ready", "ownerId": "3", "sessionId": "current-session",
        "page": ["id": 1], "executionHealth": health,
        "hostSurface": ["ownerId": "3", "surfaceGeneration": "2"],
        "pendingHostLayout": observation, "acceptedLayout": NSNull(), "pendingNavigation": NSNull(),
            "acceptedPackIdentity": ["sessionId": "current-session"],
    ] }
    static var chrome: [String: Any] { [
        "schemaVersion": 1, "revision": 20, "sessionId": "current-session", "pageId": 1,
        "contentRect": ["left": 0.0, "top": 88.0, "width": 375.0, "height": 600.0],
        "menuButtonRect": ["left": 280, "right": 360, "top": 44, "bottom": 76, "width": 80, "height": 32],
    ] }
    static var native: IOSLayoutMeasurement.Native { .init(windowMetrics: metrics, left: 0, top: 88) }
    static func gate(_ old: [String: Any] = observation, revision: String = "20", preparing: Bool = false) throws -> IOSLayoutMeasurement {
        try .init(observation: old, layoutRevision: revision, preparingNavigation: preparing, nowNanoseconds: 100)
    }
    static func decision(_ gate: IOSLayoutMeasurement, _ current: [String: Any] = state,
                         native: IOSLayoutMeasurement.Native = native, chrome: [String: Any] = chrome,
                         now: UInt64 = 101, alive: Bool = true) -> IOSLayoutMeasurement.Decision {
        gate.decision(nowNanoseconds: now, ownerCurrent: alive, state: current, native: native, chrome: chrome)
    }
    static func accepted(revision: String = "20") -> [String: Any] {
        var value = observation; value.removeValue(forKey: "sessionId"); value.removeValue(forKey: "pageId")
        value["layoutRevision"] = revision; value["chrome"] = chrome; return value
    }
    static func main() throws {
        try check("exact-pending-tuple-and-native-measurement-ready") { try expect(decision(try gate()) == .ready) }
        try check("old-observation-new-sized-view-never-ready") {
            var next = metrics; next["windowWidth"] = 700
            try expect(decision(try gate(), native: .init(windowMetrics: next, left: 0, top: 88)) == .wait)
        }
        try check("same-size-new-screen-top-never-ready") {
            var next = metrics; next["screenTop"] = 92
            var value = chrome; value["contentRect"] = ["left": 0, "top": 92, "width": 375, "height": 600]
            try expect(decision(try gate(), native: .init(windowMetrics: next, left: 0, top: 92), chrome: value) == .wait)
        }
        try check("same-size-dpr-status-screen-extent-and-orientation-mismatch") {
            for (key, value) in [("pixelRatio", 2.0 as Any), ("statusBarHeight", 48), ("screenWidth", 390),
                                 ("screenHeight", 844), ("deviceOrientation", "landscape")] {
                var next = metrics; next[key] = value
                try expect(decision(try gate(), native: .init(windowMetrics: next, left: 0, top: 88)) == .wait)
            }
        }
        try check("same-size-safe-area-mismatch") {
            var next = metrics; next["safeArea"] = ["left": 1, "top": 0, "right": 375, "bottom": 600, "width": 374, "height": 600]
            try expect(decision(try gate(), native: .init(windowMetrics: next, left: 0, top: 88)) == .wait)
        }
        try check("newer-exact-native-pending-is-supersession-proof") {
            var next = observation; next["observationId"] = "11"
            var current = state; current["pendingHostLayout"] = next
            try expect(decision(try gate(), current) == .cancelled)
        }
        try check("newer-native-surface-needs-strict-observation-advance") {
            var next = accepted(revision: "21"); next["surfaceGeneration"] = "3"
            var current = state; current["hostSurface"] = ["ownerId": "3", "surfaceGeneration": "3"]
            current["pendingHostLayout"] = NSNull(); current["acceptedLayout"] = next
            try expect(decision(try gate(), current) == .wait)
            next["observationId"] = "11"; current["acceptedLayout"] = next
            try expect(decision(try gate(), current) == .cancelled)
        }
        try check("accepted-same-observation-newer-canonical-revision-proves-supersession") {
            var current = state; current["pendingHostLayout"] = NSNull(); current["acceptedLayout"] = accepted(revision: "21")
            try expect(decision(try gate(), current) == .cancelled)
        }
        try check("same-revision-exact-accepted-only-idempotent-without-pending") {
            var current = state; current["pendingHostLayout"] = NSNull(); current["acceptedLayout"] = accepted()
            try expect(decision(try gate(), current) == .ready)
            try expect(decision(try gate(revision: "21"), current) == .wait)
            var different = observation; different["observationId"] = "9"; current["pendingHostLayout"] = different
            try expect(decision(try gate(), current) == .wait)
        }
        try check("healthy-state-without-proof-cannot-cancel-or-succeed") {
            var current = state; current["pendingHostLayout"] = NSNull()
            try expect(decision(try gate(), current) == .wait)
        }
        try check("only-ready-active-status-can-measure-or-prove-supersession") {
            let statuses: [String?] = ["closing", "closed", nil, "unknown", "loaded"]
            for status in statuses {
                var current = state
                if let status { current["status"] = status }
                else { current.removeValue(forKey: "status") }
                try expect(decision(try gate(), current) == .wait)
                current["pendingHostLayout"] = NSNull(); current["acceptedLayout"] = accepted()
                try expect(decision(try gate(), current) == .wait)
                var next = observation; next["observationId"] = "11"
                current["pendingHostLayout"] = next; current["acceptedLayout"] = NSNull()
                try expect(decision(try gate(), current) == .wait)
                current["pendingHostLayout"] = NSNull(); current["acceptedLayout"] = accepted(revision: "21")
                try expect(decision(try gate(), current) == .wait)
            }
        }
        try check("matching-rectangle-does-not-establish-tuple-identity") {
            var next = observation; next["observationId"] = "9"
            var current = state; current["pendingHostLayout"] = next
            try expect(decision(try gate(), current) == .wait)
        }
        try check("same-identity-mutated-complete-metrics-cannot-prepare") {
            for key in ["screenTop", "statusBarHeight", "pixelRatio"] {
                var nextMetrics = metrics; nextMetrics[key] = 7
                var next = observation; next["windowMetrics"] = nextMetrics
                var current = state; current["pendingHostLayout"] = next
                try expect(decision(try gate(), current) == .wait)
            }
        }
        try check("session-or-page-owner-mismatch-cannot-prepare") {
            for key in ["sessionId", "pageId"] {
                var next = observation; next[key] = key == "sessionId" ? "other-session" as Any : 2
                var current = state; current["pendingHostLayout"] = next
                try expect(decision(try gate(), current) == .wait)
            }
        }
        try check("fault-in-any-domain-never-supersession-or-ready") {
            for key in ["appServiceFault", "viewFault", "navigationFault"] {
                var broken = health; broken[key] = ["code": "ERR_TIMEOUT"]
                var current = state; current["executionHealth"] = broken
                try expect(decision(try gate(), current) == .wait)
                var next = observation; next["observationId"] = "11"; current["pendingHostLayout"] = next
                try expect(decision(try gate(), current) == .wait)
            }
        }
        try check("restart-or-malformed-health-cannot-be-swallowed") {
            for value in [true as Any, 0, NSNull()] {
                var broken = health; broken["requiresRestart"] = value
                var current = state; current["executionHealth"] = broken
                var next = observation; next["observationId"] = "11"; current["pendingHostLayout"] = next
                try expect(decision(try gate(), current) == .wait)
            }
        }
        try check("changed-owner-and-regressed-surface-are-not-proof") {
            var next = observation; next["observationId"] = "11"
            var current = state; current["pendingHostLayout"] = next; current["ownerId"] = "4"
            try expect(decision(try gate(), current) == .wait)
            current = state; current["hostSurface"] = ["ownerId": "3", "surfaceGeneration": "1"]
            current["pendingHostLayout"] = next
            try expect(decision(try gate(), current) == .wait)
        }
        try check("canonical-u64-identity-boundary") {
            try expect(IOSLayoutMeasurement.sequence("18446744073709551615") == UInt64.max)
            for invalid in ["0" as Any, "01", "18446744073709551616", "+1", " 1", "١", 1, true] {
                try expect(IOSLayoutMeasurement.sequence(invalid) == nil)
            }
            var invalid = observation; invalid["observationId"] = "01"
            do { _ = try gate(invalid); throw Failure(message: "Malformed submitted identity accepted") }
            catch IOSLayoutMeasurementError.invalidSnapshot {}
        }
        try check("malformed-newer-proof-does-not-cancel") {
            for invalid in ["01" as Any, "18446744073709551616", 11, true] {
                var next = observation; next["observationId"] = invalid
                var current = state; current["pendingHostLayout"] = next
                try expect(decision(try gate(), current) == .wait)
            }
            var current = state; current["schemaVersion"] = true
            try expect(decision(try gate(), current) == .wait)
        }
        try check("newer-proof-requires-complete-valid-native-window-metrics") {
            var malformed: [[String: Any]] = []
            var missing = metrics; missing.removeValue(forKey: "pixelRatio"); malformed.append(missing)
            var extra = metrics; extra["windowTop"] = 88; malformed.append(extra)
            var unsafe = metrics; unsafe["safeArea"] = ["left": 0, "top": 0, "right": 375, "bottom": 600, "width": 374, "height": 600]; malformed.append(unsafe)
            var status = metrics; status["statusBarHeight"] = 9999; malformed.append(status)
            for value in malformed {
                var next = observation; next["observationId"] = "11"; next["windowMetrics"] = value
                var current = state; current["pendingHostLayout"] = next
                try expect(decision(try gate(), current) == .wait)
            }
        }
        try check("deep-copy-observation-and-chrome-survive-input-mutation") {
            let nested = NSMutableDictionary(dictionary: metrics)
            var original = observation; original["windowMetrics"] = nested
            let frozen = try gate(original)
            nested["windowWidth"] = 900
            original["observationId"] = "99"
            try expect(decision(frozen) == .ready)
            let rect = NSMutableDictionary(dictionary: ["left": 0, "top": 88, "width": 375, "height": 600])
            var raw = chrome; raw["contentRect"] = rect
            let copy = try IOSLayoutMeasurement.snapshot(raw); rect["width"] = 900
            try expect(decision(frozen, chrome: copy) == .ready)
        }
        try check("fixed-absolute-deadline-is-shared-across-all-retries") {
            let frozen = try gate(); let deadline = frozen.deadlineNanoseconds
            var current = state; current["pendingHostLayout"] = NSNull()
            for offset in 1...1000 {
                try expect(decision(frozen, current, now: deadline - UInt64(offset)) == .wait)
                try expect(frozen.deadlineNanoseconds == deadline)
            }
            try expect(decision(frozen, current, now: deadline) == .expired)
            try expect(frozen.remainingNanoseconds(now: deadline + 1) == 0)
        }
        try check("deadline-addition-never-wraps-into-new-budget") {
            let frozen = try IOSLayoutMeasurement(nowNanoseconds: UInt64.max - 10)
            try expect(frozen.deadlineNanoseconds == UInt64.max)
            try expect(frozen.decision(nowNanoseconds: UInt64.max, ownerCurrent: true) == .expired)
        }
        try check("close-detach-engine-and-view-retirement-cancel-promptly") {
            for _ in ["close", "detachView", "engineDetach", "viewReplaced", "taskCancelled"] {
                let frozen = try gate()
                try expect(decision(frozen, now: 101, alive: false) == .cancelled)
            }
        }
        try check("fractional-content-uses-native-rounded-viewport-and-rust-halfpoint-limit") {
            for width in [374.5, 375.0, 375.49, 375.5] {
                var value = chrome; value["contentRect"] = ["left": 0, "top": 88, "width": width, "height": 600]
                try expect(decision(try gate(), chrome: value) == .ready)
            }
            var value = chrome; value["contentRect"] = ["left": 0, "top": 88, "width": 375.5001, "height": 600]
            try expect(decision(try gate(), chrome: value) == .wait)
        }
        try check("content-origin-must-match-current-native-screen-origin") {
            var value = chrome; value["contentRect"] = ["left": 2, "top": 88, "width": 375, "height": 600]
            try expect(decision(try gate(), chrome: value) == .wait)
        }
        try check("prepare-navigation-can-measure-ticket-generic-hostlayout-cannot-consume-it") {
            var current = state; current["pendingNavigation"] = ["ticket": "4"]
            try expect(decision(try gate(), current) == .wait)
            try expect(decision(try gate(preparing: true), current) == .ready)
        }
        try check("explicit-empty-startup-needs-exact-pending-null-owners-and-no-accepted-layout") {
            var emptyObservation = observation; emptyObservation.removeValue(forKey: "sessionId"); emptyObservation.removeValue(forKey: "pageId")
            var current = state; current["status"] = "empty"; current["executionHealth"] = NSNull()
            current["sessionId"] = NSNull(); current["page"] = NSNull(); current["pendingHostLayout"] = emptyObservation
            current["acceptedPackIdentity"] = NSNull()
            let frozen = try gate(emptyObservation)
            try expect(decision(frozen, current) == .ready)
            current["status"] = "ready"; try expect(decision(frozen, current) == .wait)
            current["status"] = "empty"; current["acceptedLayout"] = accepted()
            try expect(decision(frozen, current) == .wait)
        }
        try check("typed-empty-initial-and-candidate-rotation-need-strict-newer-pending") {
            var old = observation; old.removeValue(forKey: "sessionId"); old.removeValue(forKey: "pageId")
            var next = old; next["observationId"] = "11"
            var current = state; current["status"] = "empty"; current["executionHealth"] = NSNull()
            current["sessionId"] = NSNull(); current["page"] = NSNull(); current["pendingHostLayout"] = next
            current["acceptedPackIdentity"] = NSNull()
            try expect(decision(try gate(old), current) == .cancelled)
            try expect(decision(try gate(next), current) == .ready)
            current["pendingHostLayout"] = NSNull()
            try expect(decision(try gate(old), current) == .wait)
        }
        try check("rust-empty-option-wire-omission-and-explicit-null-are-compatible") {
            // Rust HostLayoutObservation skips None Options. Also support the
            // equivalent explicit-null form from native codec consumers.
            var omitted = observation
            omitted.removeValue(forKey: "sessionId"); omitted.removeValue(forKey: "pageId")
            var explicit = omitted; explicit["sessionId"] = NSNull(); explicit["pageId"] = NSNull()
            var mixed = omitted; mixed["sessionId"] = NSNull()
            for old in [omitted, explicit, mixed] {
                for wire in [omitted, explicit, mixed] {
                    var current = state; current["status"] = "empty"; current["executionHealth"] = NSNull()
                    current["sessionId"] = NSNull(); current["page"] = NSNull(); current["acceptedPackIdentity"] = NSNull()
                    current["pendingHostLayout"] = wire
                    try expect(decision(try gate(old), current) == .ready)
                    var next = wire; next["observationId"] = "11"; current["pendingHostLayout"] = next
                    try expect(decision(try gate(old), current) == .cancelled)
                }
            }
        }
        try check("empty-option-nonnull-and-missing-state-null-never-prove-supersession") {
            var old = observation; old.removeValue(forKey: "sessionId"); old.removeValue(forKey: "pageId")
            var next = old; next["observationId"] = "11"
            var empty = state; empty["status"] = "empty"; empty["executionHealth"] = NSNull()
            empty["sessionId"] = NSNull(); empty["page"] = NSNull(); empty["acceptedPackIdentity"] = NSNull()
            empty["pendingHostLayout"] = next
            for key in ["sessionId", "pageId"] {
                var active = old; active[key] = key == "sessionId" ? "active" as Any : 9
                try expect(decision(try gate(active), empty) == .wait)
            }
            for key in ["sessionId", "page", "acceptedPackIdentity", "acceptedLayout", "executionHealth"] {
                var incomplete = empty; incomplete.removeValue(forKey: key)
                try expect(decision(try gate(old), incomplete) == .wait)
                incomplete["pendingHostLayout"] = old
                try expect(decision(try gate(old), incomplete) == .wait)
            }
        }
        try check("typed-empty-cannot-cancel-on-active-ids-fault-or-missing-proof") {
            var old = observation; old.removeValue(forKey: "sessionId"); old.removeValue(forKey: "pageId")
            var next = old; next["observationId"] = "11"
            var empty = state; empty["status"] = "empty"; empty["executionHealth"] = NSNull()
            empty["sessionId"] = NSNull(); empty["page"] = NSNull(); empty["acceptedPackIdentity"] = NSNull()
            empty["pendingHostLayout"] = next
            for key in ["sessionId", "pageId"] {
                var mixed = next; mixed[key] = key == "sessionId" ? "active" as Any : 9
                var current = empty; current["pendingHostLayout"] = mixed
                try expect(decision(try gate(old), current) == .wait)
            }
            for key in ["sessionId", "page", "acceptedPackIdentity", "acceptedLayout"] {
                var current = empty; current[key] = ["unexpected": true]
                try expect(decision(try gate(old), current) == .wait)
            }
            var current = empty; var broken = health; broken["viewFault"] = ["code": "ERR_TIMEOUT"]
            current["executionHealth"] = broken
            try expect(decision(try gate(old), current) == .wait)
        }
        try check("reload-old-context-cannot-adopt-newer-observation") {
            let old = try gate(); var next = observation; next["observationId"] = "11"
            var current = state; current["pendingHostLayout"] = next
            try expect(decision(old, current) == .cancelled)
            try expect(decision(try gate(next), current) == .ready)
            try expect(old.observation?["observationId"] as? String == "10")
        }
        let report: [String: Any] = ["schemaVersion": 1, "status": "passed", "checks": passed,
                                   "count": passed.count, "nativeSessionsCreated": 0, "devicesUsed": 0]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
