import Foundation
import CoreFoundation
import Dispatch

/// Closed diagnostic provenance only. No cancellation reason establishes
/// operation success, safe recovery or permission to enable input.
enum IOSLayoutCancellationReason: String, CaseIterable {
    case taskCancelled = "layout-measurement-task-cancelled"
    case engineDetached = "layout-measurement-engine-detached"
    case engineInitializing = "layout-measurement-engine-initializing"
    case entryClosing = "layout-measurement-entry-closing"
    case viewRetiring = "layout-measurement-view-retiring"
    case lifetimeChanged = "layout-measurement-lifetime-changed"
    case entryRemoved = "layout-measurement-entry-removed"
    case restartReceiptMismatch = "layout-measurement-restart-receipt-mismatch"
    case observationSuperseded = "layout-measurement-observation-superseded"
}

struct IOSLayoutMeasurementFailure {
    let code: String
    let message: String
    let details: [String: Any]?
}

enum IOSLayoutMeasurementError: Error {
    case invalidSnapshot, cancelled(IOSLayoutCancellationReason), expired

    /// Used unchanged by the Flutter boundary and deterministic contract tests.
    var wireFailure: IOSLayoutMeasurementFailure {
        switch self {
        case .cancelled(let reason):
            return .init(code: "ERR_CANCELLED",
                         message: "Native layout measurement was superseded or its owner retired",
                         details: ["schemaVersion": 1, "reason": reason.rawValue])
        case .expired:
            return .init(code: "ERR_NOT_READY", message: "Native layout measurement deadline expired", details: nil)
        case .invalidSnapshot:
            return .init(code: "ERR_INVALID_REQUEST", message: "Expected immutable complete native layout measurement", details: nil)
        }
    }
}

/// Value-only gate shared by atomic measurement and native chrome conversion.
/// Its deterministic tests compile this exact production code without UIKit.
struct IOSLayoutMeasurement {
    enum Decision: Equatable {
        case ready, wait, cancelled(IOSLayoutCancellationReason), expired

        func requireReadyOrWaiting() throws {
            switch self {
            case .cancelled(let reason): throw IOSLayoutMeasurementError.cancelled(reason)
            case .expired: throw IOSLayoutMeasurementError.expired
            case .ready, .wait: return
            }
        }
    }
    /// Preserve the former predicate order, with provenance at its source.
    static func ownerCancellation(taskCancelled: Bool = false, engineDetached: Bool = false,
                                  engineInitializing: Bool = false, entryClosing: Bool = false,
                                  viewRetiring: Bool = false, lifetimeCurrent: Bool = true,
                                  entryPresent: Bool = true) -> IOSLayoutCancellationReason? {
        if taskCancelled { return .taskCancelled }
        if engineDetached { return .engineDetached }
        if engineInitializing { return .engineInitializing }
        if entryClosing { return .entryClosing }
        if viewRetiring { return .viewRetiring }
        if !lifetimeCurrent { return .lifetimeChanged }
        if !entryPresent { return .entryRemoved }
        return nil
    }
    struct Native {
        let windowMetrics: [String: Any]
        let left: Double
        let top: Double
    }
    static let budgetNanoseconds: UInt64 = 10_000_000_000
    let deadlineNanoseconds: UInt64
    let observation: [String: Any]?
    let layoutRevision: String?
    let preparingNavigation: Bool
    let restartAttempt: [String: Any]?

    init(observation: [String: Any]? = nil, layoutRevision: String? = nil,
         preparingNavigation: Bool = false, restartAttempt: [String: Any]? = nil, nowNanoseconds: UInt64,
         budgetNanoseconds: UInt64 = Self.budgetNanoseconds) throws {
        let sum = nowNanoseconds.addingReportingOverflow(budgetNanoseconds)
        deadlineNanoseconds = sum.overflow ? UInt64.max : sum.partialValue
        self.observation = try observation.map(Self.snapshot)
        self.layoutRevision = layoutRevision
        self.preparingNavigation = preparingNavigation
        self.restartAttempt = try restartAttempt.map(Self.snapshot)
        if let context = self.restartAttempt {
            guard preparingNavigation, self.observation != nil,
                  Set(context.keys) == Set(["schemaVersion", "ownerId", "attemptId", "targetRoot", "expectedAccepted"]),
                  Self.schemaOne(context["schemaVersion"]), Self.sequence(context["ownerId"]) != nil,
                  Self.sequence(context["attemptId"]) != nil, Self.root(context["targetRoot"]),
                  context["expectedAccepted"] is NSNull || Self.acceptedIdentity(context["expectedAccepted"]) else {
                throw IOSLayoutMeasurementError.invalidSnapshot
            }
        }
        if let value = self.observation {
            guard Self.schemaOne(value["schemaVersion"]), Self.sequence(value["ownerId"]) != nil,
                  Self.sequence(value["surfaceGeneration"]) != nil, Self.sequence(value["observationId"]) != nil,
                  Self.sequence(layoutRevision) != nil,
                  let metrics = value["windowMetrics"] as? [String: Any], Self.validMetrics(metrics) else {
                throw IOSLayoutMeasurementError.invalidSnapshot
            }
        }
    }

    static func snapshot(_ value: [String: Any]) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(value) else { throw IOSLayoutMeasurementError.invalidSnapshot }
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw IOSLayoutMeasurementError.invalidSnapshot
        }
        return result
    }
    static func mergeAdapterCapabilities(_ value: [String: Any]) -> [String: Any] {
        var result = value
        guard var chrome = result["chrome"] as? [String: Any],
              var atomic = chrome["atomicLayout"] as? [String: Any] else { return result }
        if trueBoolean(atomic["enabled"]) { atomic["preparedRestartMeasurement"] = "1.0" }
        else { atomic.removeValue(forKey: "preparedRestartMeasurement") }
        chrome["atomicLayout"] = atomic; result["chrome"] = chrome
        return result
    }
    static func sequence(_ value: Any?) -> UInt64? {
        guard let raw = value as? String, !raw.isEmpty, raw.utf8.count <= 20,
              raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = UInt64(raw), number > 0, String(number) == raw else { return nil }
        return number
    }
    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func schemaOne(_ value: Any?) -> Bool { number(value) == 1 }
    private static func falseBoolean(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return !value.boolValue
    }
    private static func trueBoolean(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }
    private static func root(_ value: Any?) -> Bool {
        guard let value = value as? String, value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
    private static func acceptedIdentity(_ value: Any?) -> Bool {
        guard let value = value as? [String: Any],
              Set(value.keys) == Set(["root", "acceptedPackRevision", "sessionId"]),
              root(value["root"]), sequence(value["acceptedPackRevision"]) != nil,
              let session = value["sessionId"] as? String, !session.isEmpty else { return false }
        return true
    }
    private static func absent(_ value: Any?) -> Bool { value == nil || value is NSNull }
    private static func equal(_ left: Any?, _ right: Any?) -> Bool {
        if absent(left) || absent(right) { return absent(left) && absent(right) }
        guard let left, let right,
              let a = try? JSONSerialization.data(withJSONObject: left, options: [.sortedKeys, .fragmentsAllowed]),
              let b = try? JSONSerialization.data(withJSONObject: right, options: [.sortedKeys, .fragmentsAllowed]) else { return false }
        return a == b
    }
    private static func healthy(_ state: [String: Any]) -> Bool {
        guard let health = state["executionHealth"] as? [String: Any], schemaOne(health["schemaVersion"]),
              falseBoolean(health["requiresRestart"]) else { return false }
        return ["appServiceFault", "viewFault", "navigationFault"].allSatisfy { absent(health[$0]) }
    }
    /// A caller-supplied context is only a lookup key. The SDK journal receipt
    /// is fetched again after every suspension; it alone grants preparation.
    private func matchesRestartReceipt(_ receipt: [String: Any], state: [String: Any]) -> Bool {
        guard let context = restartAttempt,
              Self.schemaOne(receipt["schemaVersion"]), receipt["status"] as? String == "prepared",
              receipt["reloadKind"] as? String == "restart",
              let operation = receipt["operation"] as? String, ["load", "applyDevPack"].contains(operation),
              receipt.keys.contains("expectedAccepted"), receipt.keys.contains("acceptedPackIdentity"),
              state.keys.contains("acceptedPackIdentity"),
              state["ownerId"] as? String == context["ownerId"] as? String else { return false }
        for key in ["ownerId", "attemptId", "targetRoot", "expectedAccepted"] {
            guard Self.equal(receipt[key], context[key]) else { return false }
        }
        guard Self.equal(receipt["acceptedPackIdentity"], context["expectedAccepted"]),
              Self.equal(state["acceptedPackIdentity"], context["expectedAccepted"]),
              let observed = observation else { return false }
        if context["expectedAccepted"] is NSNull {
            return state["sessionId"] is NSNull && state["page"] is NSNull
                && Self.absent(observed["sessionId"]) && Self.absent(observed["pageId"])
        }
        guard let expected = context["expectedAccepted"] as? [String: Any],
              let pageID = Self.number(observed["pageId"]), pageID > 0, pageID.rounded() == pageID,
              Self.equal(expected["sessionId"], observed["sessionId"]),
              Self.equal(state["sessionId"], observed["sessionId"]),
              let page = state["page"] as? [String: Any], Self.equal(page["id"], observed["pageId"]) else { return false }
        return true
    }
    private func viewFaultMayPrepareRestart(_ state: [String: Any]) -> Bool {
        guard let context = restartAttempt, Self.acceptedIdentity(context["expectedAccepted"]),
              let health = state["executionHealth"] as? [String: Any], Self.schemaOne(health["schemaVersion"]),
              Self.trueBoolean(health["requiresRestart"]), health["appServiceFault"] is NSNull,
              health["navigationFault"] is NSNull, state["pendingNavigation"] is NSNull,
              Self.falseBoolean(state["inputEnabled"]), Self.falseBoolean(state["presentationEnabled"]),
              let fault = health["viewFault"] as? [String: Any], fault["domain"] as? String == "view",
              Self.trueBoolean(fault["requiresRestart"]), let code = fault["code"] as? String,
              code.range(of: #"^ERR_[A-Z0-9_]+$"#, options: .regularExpression) != nil,
              let message = fault["message"] as? String,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }
    private static func typedEmpty(_ state: [String: Any], observation: [String: Any]) -> Bool {
        // HostLayoutObservation omits None session/page Options on the Rust
        // wire. Accept omitted or explicit null there, while state ownership
        // and accepted identities must remain present with typed null values.
        state["status"] as? String == "empty" && state["executionHealth"] is NSNull
            && ["sessionId", "page", "acceptedPackIdentity", "acceptedLayout"].allSatisfy { state[$0] is NSNull }
            && absent(observation["sessionId"]) && absent(observation["pageId"])
    }
    private static func validMetrics(_ metrics: [String: Any]) -> Bool {
        let required: Set<String> = ["windowWidth", "windowHeight", "screenWidth", "screenHeight", "pixelRatio",
                                     "statusBarHeight", "screenTop", "deviceOrientation"]
        guard required.isSubset(of: Set(metrics.keys)), Set(metrics.keys).isSubset(of: required.union(["safeArea"])) else { return false }
        for key in ["windowWidth", "windowHeight", "screenWidth", "screenHeight"] {
            guard let value = number(metrics[key]), value > 0, value <= Double(UInt32.max), value.rounded() == value else { return false }
        }
        guard let scale = number(metrics["pixelRatio"]), scale > 0,
              let status = number(metrics["statusBarHeight"]), status >= 0,
              let screenHeight = number(metrics["screenHeight"]), status <= screenHeight + 0.5,
              number(metrics["screenTop"]) != nil,
              let orientation = metrics["deviceOrientation"] as? String,
              ["portrait", "landscape"].contains(orientation) else { return false }
        if !absent(metrics["safeArea"]) {
            guard let safe = metrics["safeArea"] as? [String: Any],
                  Set(safe.keys) == Set(["left", "top", "right", "bottom", "width", "height"]),
                  let screenWidth = number(metrics["screenWidth"]) else { return false }
            for key in ["left", "top", "right", "bottom", "width", "height"] {
                guard number(safe[key]) != nil else { return false }
            }
            let limit = max(screenWidth, screenHeight) + 0.5
            for (extent, start, end) in [("width", "left", "right"), ("height", "top", "bottom")] {
                let size = number(safe[extent])!, leading = number(safe[start])!, trailing = number(safe[end])!
                guard size > 0, size <= limit, abs(size - (trailing - leading)) <= 0.000001 else { return false }
            }
        }
        return true
    }

    /// A healthy frame or different rectangle never establishes supersession.
    /// Require the native owner, canonical u64 identities and a strict advance.
    func superseded(by state: [String: Any]) -> Bool {
        guard let old = observation, let owner = old["ownerId"] as? String,
              let surface = Self.sequence(old["surfaceGeneration"]),
              let sequence = Self.sequence(old["observationId"]),
              let revision = Self.sequence(layoutRevision), Self.schemaOne(state["schemaVersion"]),
              state["ownerId"] as? String == owner,
              let active = state["hostSurface"] as? [String: Any], active["ownerId"] as? String == owner,
              let activeSurface = Self.sequence(active["surfaceGeneration"]), activeSurface >= surface else { return false }
        let empty = Self.typedEmpty(state, observation: old)
        guard empty || (state["status"] as? String == "ready" && Self.healthy(state)) else { return false }
        func newer(_ item: Any?, accepted: Bool) -> Bool {
            guard let value = item as? [String: Any], Self.schemaOne(value["schemaVersion"]),
                  value["ownerId"] as? String == owner,
                  value["surfaceGeneration"] as? String == active["surfaceGeneration"] as? String,
                  let next = Self.sequence(value["observationId"]), next >= sequence,
                  let metrics = value["windowMetrics"] as? [String: Any], Self.validMetrics(metrics) else { return false }
            if empty {
                return !accepted && Self.absent(value["sessionId"]) && Self.absent(value["pageId"]) && next > sequence
            }
            let nextRevision = accepted ? Self.sequence(value["layoutRevision"]) : nil
            if accepted && nextRevision == nil { return false }
            if next > sequence { return true }
            return accepted && activeSurface == surface && nextRevision! > revision
        }
        return newer(state["pendingHostLayout"], accepted: false) || newer(state["acceptedLayout"], accepted: true)
    }
    private func matchesCurrentTuple(_ state: [String: Any]) -> Bool {
        guard let old = observation, Self.schemaOne(state["schemaVersion"]),
              state["ownerId"] as? String == old["ownerId"] as? String,
              let surface = state["hostSurface"] as? [String: Any],
              surface["ownerId"] as? String == old["ownerId"] as? String,
              surface["surfaceGeneration"] as? String == old["surfaceGeneration"] as? String else { return false }
        let pending = state["pendingHostLayout"] as? [String: Any]
        // Only an explicit empty startup owner can lack execution health.
        // Readiness still needs its exact pending tuple; cancellation instead
        // requires the strict newer pending proof checked by superseded(by:).
        let emptyStartup = Self.typedEmpty(state, observation: old) && pending != nil
        let ready = state["status"] as? String == "ready"
            && (Self.healthy(state) || viewFaultMayPrepareRestart(state))
        guard ready || emptyStartup else { return false }
        if restartAttempt != nil {
            // A prepared restart measures a fresh, exact pending observation,
            // never an old accepted rectangle or a navigation ticket.
            guard state["pendingNavigation"] is NSNull, pending != nil else { return false }
            if !emptyStartup {
                guard let session = old["sessionId"] as? String, !session.isEmpty,
                      let pageID = Self.number(old["pageId"]), pageID > 0, pageID.rounded() == pageID,
                      Self.equal(state["sessionId"], old["sessionId"]),
                      let page = state["page"] as? [String: Any], Self.equal(page["id"], old["pageId"]),
                      let identity = state["acceptedPackIdentity"] as? [String: Any],
                      Self.equal(identity["sessionId"], old["sessionId"]) else { return false }
            }
        }
        // Generic hostLayout must never consume a native navigation ticket.
        // A prepared payload is committed later by completeNavigationLayout.
        if !preparingNavigation && !Self.absent(state["pendingNavigation"]) { return false }
        let candidate: [String: Any]
        let owner: [String: Any]
        if let pending { candidate = pending; owner = pending }
        else {
            guard Self.absent(state["pendingHostLayout"]), let accepted = state["acceptedLayout"] as? [String: Any],
                  accepted["layoutRevision"] as? String == layoutRevision,
                  let chrome = accepted["chrome"] as? [String: Any] else { return false }
            candidate = accepted; owner = chrome
        }
        guard Self.schemaOne(candidate["schemaVersion"]) else { return false }
        for key in ["ownerId", "surfaceGeneration", "observationId", "windowMetrics"] {
            if !Self.equal(candidate[key], old[key]) { return false }
        }
        return ["sessionId", "pageId"].allSatisfy { Self.equal(owner[$0], old[$0]) }
    }
    private func matchesNative(_ native: Native, chrome: [String: Any]) -> Bool {
        guard let old = observation, let expected = old["windowMetrics"] as? [String: Any],
              Self.validMetrics(native.windowMetrics), native.left.isFinite, native.top.isFinite,
              let content = chrome["contentRect"] as? [String: Any] else { return false }
        for key in ["windowWidth", "windowHeight", "screenWidth", "screenHeight", "screenTop", "statusBarHeight", "pixelRatio"] {
            guard let a = Self.number(expected[key]), let b = Self.number(native.windowMetrics[key]),
                  abs(a - b) <= (key == "pixelRatio" ? 0.000001 : 0.5) else { return false }
        }
        guard expected["deviceOrientation"] as? String == native.windowMetrics["deviceOrientation"] as? String else { return false }
        let expectedSafe = expected["safeArea"] as? [String: Any], currentSafe = native.windowMetrics["safeArea"] as? [String: Any]
        if let a = expectedSafe, let b = currentSafe {
            for key in ["left", "top", "right", "bottom", "width", "height"] {
                guard let x = Self.number(a[key]), let y = Self.number(b[key]), abs(x - y) <= 0.5 else { return false }
            }
        } else if !Self.absent(expected["safeArea"]) || !Self.absent(native.windowMetrics["safeArea"]) { return false }
        for (field, target) in [("width", expected["windowWidth"]), ("height", expected["windowHeight"])] {
            guard let actual = Self.number(content[field]), let expected = Self.number(target), actual > 0, abs(actual - expected) <= 0.5 else { return false }
        }
        guard let left = Self.number(content["left"]), let top = Self.number(content["top"]),
              abs(left - native.left) <= 0.5, abs(top - native.top) <= 0.5 else { return false }
        return true
    }
    func decision(nowNanoseconds: UInt64, ownerCancellation: IOSLayoutCancellationReason? = nil, state: [String: Any]? = nil,
                  native: Native? = nil, chrome: [String: Any]? = nil,
                  restartReceipt: [String: Any]? = nil) -> Decision {
        if let ownerCancellation { return .cancelled(ownerCancellation) }
        if nowNanoseconds >= deadlineNanoseconds { return .expired }
        guard observation != nil else { return .ready }
        guard let state else { return .wait }
        if restartAttempt != nil {
            guard let restartReceipt else { return .wait }
            if !matchesRestartReceipt(restartReceipt, state: state) { return .cancelled(.restartReceiptMismatch) }
        }
        if superseded(by: state) { return .cancelled(.observationSuperseded) }
        guard matchesCurrentTuple(state), let native, let chrome, matchesNative(native, chrome: chrome) else { return .wait }
        return .ready
    }
    func remainingNanoseconds(now: UInt64) -> UInt64 { now >= deadlineNanoseconds ? 0 : deadlineNanoseconds - now }
}

#if !WEAPP_LAYOUT_GATE_TESTS
import Flutter
import UIKit

/// All Flutter and native Swift SDK calls run on the UIKit main actor.
@MainActor public final class WeappContainerIosPlugin: NSObject, @preconcurrency FlutterPlugin, @preconcurrency FlutterStreamHandler {
    @MainActor private final class Entry {
        let session: WeappContainerSession
        var view: WeappContainerView?
        var closing: Task<Void, Error>?
        var retiringView: Task<Void, Error>?
        var calls: [String: CheckedContinuation<WeappJSON, Error>] = [:]
        var accountCleanup: (operationId:String,continuation:CheckedContinuation<Void,Error>)?
        var deviceServices:WeappNativeDeviceServices?
        var clientChrome: [String: Any]?
        var preparedClientChrome: [String: Any]?
        var measurementLifetime = UUID()
        init(_ session: WeappContainerSession) { self.session = session }
    }
    private weak var devicePresenter:UIViewController?
    private var entries: [Int64: Entry] = [:]
    private var closed: Set<Int64> = []
    private var nextID: Int64 = 1
    private var nextCall: UInt64 = 1
    private var epoch: String?
    private var initializing: Task<Void, Error>?
    private var sink: FlutterEventSink?
    private var detached = false
    private static var retiring: [ObjectIdentifier: WeappContainerIosPlugin] = [:]

    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = WeappContainerIosPlugin()
        plugin.devicePresenter=registrar.viewController
        registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(name: "dev.weapp.container/methods", binaryMessenger: registrar.messenger()))
        FlutterEventChannel(name: "dev.weapp.container/events", binaryMessenger: registrar.messenger()).setStreamHandler(plugin)
        registrar.register(Factory(plugin), withId: "dev.weapp.container/view")
    }
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        detached = true; sink = nil
        Self.retiring[ObjectIdentifier(self)] = self
        retireEngine(attempt: 0)
    }
    private func retireEngine(attempt: Int) {
        Task { @MainActor in
            do { try await retireAll(); Self.retiring.removeValue(forKey: ObjectIdentifier(self)) }
            catch {
                if attempt < 3 { try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 100_000_000); retireEngine(attempt: attempt + 1) }
                else { NSLog("WeappContainer retains failed engine cleanup: %@", error.localizedDescription) }
            }
        }
    }
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
    public func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        Task { @MainActor in
            do { result(try await perform(call)) }
            catch let error as WeappContainerError { result(FlutterError(code: error.code, message: error.message, details: nil)) }
            catch let error as WeappHostError { result(FlutterError(code: error.code.rawValue, message: error.message, details: codec(.object(error.details)))) }
            catch let error as IOSLayoutMeasurementError {
                let failure = error.wireFailure
                result(FlutterError(code: failure.code, message: failure.message, details: failure.details))
            }
            catch { result(FlutterError(code: "ERR_INVALID_REQUEST", message: error.localizedDescription, details: nil)) }
        }
    }
    private func perform(_ call: FlutterMethodCall) async throws -> Any? {
        guard !detached else { throw fail("Engine detached") }
        guard let args = call.arguments as? [String: Any] else { throw fail("Expected arguments") }
        if call.method == "initialize" {
            let next = try string(args, "clientEpoch")
            guard !next.isEmpty else { throw fail("Empty clientEpoch") }
            if let pending = initializing { try await pending.value }
            if next == epoch { return nil }
            let operation = Task { @MainActor in try await self.retireAll() }; initializing = operation
            do { try await operation.value; epoch = next; initializing = nil }
            catch { initializing = nil; throw error }
            return nil
        }
        guard epoch != nil, initializing == nil else { throw fail("Initialize client before creating sessions") }
        if call.method == "create" {
            guard args.keys.contains("storageKey") else { throw fail("storageKey must be explicit; null selects memory") }
            var configuration: WeappContainerConfiguration
            if args["storageKey"] is NSNull { configuration = .init(storage: .memoryOnly) }
            else { let key = try string(args, "storageKey"); guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail("Empty storage key") }; configuration = .init(storageKey: key) }
            if let value = args["gpuRequired"] {
                guard let required = value as? Bool, required else { throw fail("iOS native preview requires gpuRequired=true") }
                configuration.gpuRequired = required
            }
            if let value = args["devDiagnostics"] {
                guard let enabled = value as? Bool else { throw fail("devDiagnostics must be a boolean") }
                configuration.devDiagnostics = enabled
            }
            if let value = args["systemTabBar"] {
                guard let enabled = value as? Bool else { throw fail("systemTabBar must be a boolean") }
                configuration.systemTabBar = enabled
            }
            if let layout = args["hostLayout"] as? [String: Any] {
                guard layout["protocolVersion"] as? String == "1.0", layout["atomic"] as? Bool == true else { throw fail("hostLayout requires atomic protocol 1.0") }
                configuration.atomicHostLayout = true
            }
            let id = nextID; nextID += 1
            let entry = Entry(WeappContainerSession(configuration: configuration)); entries[id] = entry
            entry.session.onAccountCleanup = { [weak self, weak entry] operationId in
                guard let self,let entry else { throw CancellationError() }
                guard entry.accountCleanup == nil else { throw self.fail("Previous cleanup transport has not ended") }
                try await withTaskCancellationHandler(operation: {
                    try Task.checkCancellation()
                    try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                        entry.accountCleanup=(operationId,continuation)
                        self.emit(id,["type":"accountCleanupRequired","operationId":operationId])
                    }
                }, onCancel: {
                    Task { @MainActor [weak self,weak entry] in
                        guard let entry,entry.accountCleanup?.operationId==operationId else { return }
                        self?.emit(id,["type":"accountCleanupCancelled","operationId":operationId])
                    }
                })
            }
            entry.session.onEvent = { [weak self] event in self?.event(id, event) }
            return ["id": id]
        }
        guard let value = args["id"] as? NSNumber else { throw fail("Missing id") }
        let id = value.int64Value
        if ["close", "detachView"].contains(call.method), closed.contains(id) { return nil }
        guard let entry = entries[id] else { throw WeappContainerError(code: "ERR_CLOSED", message: "Unknown or retired session") }
        let session = entry.session
        switch call.method {
        case "installNativeDeviceApis":
            guard entry.deviceServices==nil else { throw fail("Native devices already installed") }
            guard let presenter=devicePresenter else { throw fail("A Flutter view controller is required") }
            let wifiConfiguration: WeappWifiConfiguration?
            if let raw = args["wifiConfiguration"], !(raw is NSNull) {
                guard let wifi = raw as? [String: Any],
                      let connect = wifi["connectToNetworks"] as? Bool,
                      let read = wifi["readCurrentNetwork"] as? Bool else {
                    throw fail("wifiConfiguration requires connectToNetworks and readCurrentNetwork booleans")
                }
                wifiConfiguration = .init(connectToNetworks: connect, readCurrentNetwork: read)
            } else { wifiConfiguration = nil }
            let nfcConfiguration: WeappNfcConfiguration?
            if let raw = args["nfcConfiguration"], !(raw is NSNull) {
                guard let nfc = raw as? [String: Any] else { throw fail("nfcConfiguration must be an object") }
                func flag(_ key: String, _ fallback: Bool = false) throws -> Bool {
                    guard let raw = nfc[key] else { return fallback }
                    guard let value = raw as? Bool else { throw fail("nfcConfiguration.\(key) must be a boolean") }; return value
                }
                nfcConfiguration = try .init(ndef: flag("ndef", true), isoDep: flag("isoDep"), mifareUltralight: flag("mifareUltralight"), nfcF: flag("nfcF"), nfcV: flag("nfcV"))
            } else { nfcConfiguration = nil }
            let driver=try WeappNativeDeviceServices(presenter:presenter,
                networkOrigins:(args["allowedNetworkOrigins"] as? [String]) ?? [],
                allowLoopbackForDevelopment:args["allowLoopbackForDevelopment"] as? Bool == true,
                enableBluetooth:args["bluetooth"] as? Bool != false,
                allowedMediaOrigins:(args["allowedMediaOrigins"] as? [String]) ?? [],
                recordingAudioSession:args["dedicatedAudioSession"] as? Bool == true ? WeappExclusiveRecordingAudioSession() : nil,
                enableNfc:args["nfc"] as? Bool == true,
                wifiConfiguration:wifiConfiguration, nfcConfiguration:nfcConfiguration)
            entry.deviceServices=driver
            try driver.install(in:session)
        case "completeAccountCleanup":
            guard let pending=entry.accountCleanup,pending.operationId==args["operationId"] as? String else { throw fail("Account cleanup belongs to another operation") }
            entry.accountCleanup=nil
            if args["retired"] as? Bool == true { pending.continuation.resume(throwing:CancellationError()) }
            else if let failure=args["error"] as? [String:Any] { pending.continuation.resume(throwing:WeappContainerError(code:"ERR_ACCOUNT_CLEANUP",message:failure["message"] as? String ?? "Account cleanup failed")) }
            else { pending.continuation.resume() }
        case "registerHostMethod":
            let name = try string(args, "name")
            try session.registerHostMethod(name) { [weak self, weak entry] payload in
                guard let self, let entry else { throw WeappHostError(code: .cancelled, message: "Engine retired") }
                let callID = "flutter-\(self.nextCall)"; self.nextCall += 1
                return try await withTaskCancellationHandler(operation: {
                    try Task.checkCancellation()
                    return try await withCheckedThrowingContinuation { continuation in
                        entry.calls[callID] = continuation
                        self.emit(id, ["type": "hostCall", "callId": callID, "method": name, "payload": self.codec(payload)])
                    }
                }, onCancel: {
                    Task { @MainActor in
                        guard let pending = entry.calls.removeValue(forKey: callID) else { return }
                        self.emit(id, ["type": "hostCallCancelled", "callId": callID])
                        pending.resume(throwing: WeappHostError(code: .cancelled, message: "Host call cancelled"))
                    }
                })
            }
        case "registerApiHandler":
            let name = try string(args, "name")
            try session.registerApiHandler(name) { [weak self, weak entry] apiCall in
                guard let self, let entry else { throw WeappHostError(code: .cancelled, message: "Engine retired") }
                let callID = "flutter-\(self.nextCall)"; self.nextCall += 1
                if apiCall.keepsResourceAlive {
                    apiCall.cancellation.onCancel { [weak self, weak entry] in
                        guard let self, let entry else { return }
                        entry.calls.removeValue(forKey:callID)?.resume(throwing:WeappHostError(code:.cancelled,message:"Host resource released"))
                        self.emit(id,["type":"hostCallCancelled","callId":callID])
                    }
                }
                return try await withTaskCancellationHandler(operation: {
                    try Task.checkCancellation()
                    return try await withCheckedThrowingContinuation { continuation in
                        entry.calls[callID] = continuation
                        self.emit(id, ["type":"hostCall", "callId":callID, "method":name,
                            "payload":self.codec(apiCall.payload), "context":self.codec(apiCall.context),
                            "deadlineNs":apiCall.deadlineNs as Any? ?? NSNull(), "cancelToken":apiCall.cancelToken as Any? ?? NSNull(), "retainUntilCancelled":apiCall.keepsResourceAlive])
                    }
                }, onCancel: {
                    Task { @MainActor in
                        guard let pending = entry.calls.removeValue(forKey:callID) else { return }
                        self.emit(id, ["type":"hostCallCancelled", "callId":callID])
                        pending.resume(throwing:WeappHostError(code:.cancelled,message:"Host API cancelled"))
                    }
                })
            }
        case "hostComponents", "authorizeInstalledPack", "migrateLegacyStorage", "deleteAccountData", "retryAccountCleanup", "configureHostServices", "hostApiEvent", "hostComponentFrame", "hostComponentEvent", "authorizePhoneButton", "prepareAccountHostServiceSnapshots", "updateHostServiceSnapshots", "switchAccount", "queryAccountSwitch", "updateAccountSwitchLaunch", "acknowledgeAccountCleanup", "retryAccountSwitch", "cancelAccountSwitch", "hostApiResource", "createHostBinary", "readHostBinary", "retainHostBinary", "releaseHostBinary":
            return codec(try session.hostServicesCommand(call.method, try object(args.filter { $0.key != "id" })))
        case "load":
            try await session.load(packURL: URL(fileURLWithPath: try string(args, "packPath")), route: args["route"] as? String, options: try object(args["options"]), initialHostChrome: args["initialHostChrome"] == nil ? nil : try object(args["initialHostChrome"]), initialHostLayout: args["initialHostLayout"] == nil ? nil : try object(args["initialHostLayout"]))
            acceptPreparedChrome(entry,args)
        case "applyDevPack":
            let value=try await session.applyDevPack(packURL: URL(fileURLWithPath: try string(args, "packPath")), route: args["route"] as? String, options: try object(args["options"]), initialHostChrome: args["initialHostChrome"] == nil ? nil : try object(args["initialHostChrome"]), initialHostLayout: args["initialHostLayout"] == nil ? nil : try object(args["initialHostLayout"]))
            acceptPreparedChrome(entry,args);return codec(value)
        case "command":
            let operation = try string(args, "operation")
            let value = try await session.executeCommand(operation, object(args["payload"]))
            if operation == "applyDevPackAttempt", value["status"].string == "accepted", let raw = entry.preparedClientChrome {
                entry.clientChrome = raw; entry.preparedClientChrome = nil
            }
            return codec(value)
        case "prepareHostLayout", "hostLayout":
            let raw = try IOSLayoutMeasurement.snapshot(args.filter { $0.key != "id" })
            let value = try await measureLayout(entry, raw, preparing: call.method == "prepareHostLayout")
            if call.method == "prepareHostLayout" { entry.preparedClientChrome = raw["chrome"] as? [String: Any]; return value }
            _ = try await session.executeCommand("hostLayout", object(value)); entry.clientChrome = raw["chrome"] as? [String: Any]
        case "devState": return codec(try session.devState())
        case "clearDevStorage": try await session.clearDevStorage()
        case "navigate": try session.navigate(route: string(args, "route"), query: object(args["query"]), replace: args["replace"] as? Bool ?? false)
        case "back": try session.back()
        case "switchTab": try session.switchTab(route: string(args, "route"))
        case "inspectPackChrome": return codec(try session.inspectPackChrome(packURL: URL(fileURLWithPath: string(args, "packPath")), route: args["route"] as? String))
        case "hostChrome": try await updateChrome(entry, args.filter { $0.key != "id" })
        case "prepareHostChrome":
            let raw=try IOSLayoutMeasurement.snapshot(args.filter { $0.key != "id" })
            let value=try await measureChrome(entry,raw,prospective:true)
            entry.preparedClientChrome=raw;return value
        case "setPreviewOccluded":
            guard let value = args["occluded"] as? Bool else { throw fail("Missing occluded") }
            try session.setPreviewOccluded(value)
        case "sendMessage": try session.sendMessage(json(args["message"]))
        case "setForeground":
            guard let active = args["foreground"] as? Bool else { throw fail("Missing foreground") }
            try session.setForeground(active)
        case "flushStorage": try await session.flushStorage()
        case "state": return codec(try session.state())
        case "capabilities": return try mergeAdapterCapabilities(session.capabilities())
        case "observeHostLayout": _ = try await session.requestHostLayoutObservation()
        case "prepareView":
            let capabilities = try await session.prepareView()
            return try mergeAdapterCapabilities(capabilities)
        case "detachView":
            try await retireView(entry)
        case "close": try await close(id, entry)
        case "completeHostCall":
            guard args.keys.contains("result") != args.keys.contains("error") else { throw fail("Provide exactly one of result/error") }
            let callID = try string(args, "callId")
            // Validate before consuming the exactly-once continuation.
            let completion: Result<WeappJSON, Error>
            if args.keys.contains("error") {
                guard let error = args["error"] as? [String: Any] else { throw fail("Expected host error object") }
                completion = .failure(WeappHostError(code: WeappHostError.Code(rawValue: error["code"] as? String ?? "") ?? .invalidRequest,
                    message: error["message"] as? String ?? "Host method failed", retryable: error["retryable"] as? Bool ?? false, details: try object(error["details"])))
            } else { completion = .success(try json(args["result"])) }
            guard let pending = entry.calls.removeValue(forKey: callID) else { throw WeappHostError(code: .cancelled, message: "Call no longer accepts completion") }
            pending.resume(with: completion)
        default: return FlutterMethodNotImplemented
        }
        return nil
    }
    private func mergeAdapterCapabilities(_ value: WeappJSON) throws -> [String: Any] {
        guard let raw = codec(value) as? [String: Any] else { throw fail("Missing native capabilities") }
        return IOSLayoutMeasurement.mergeAdapterCapabilities(raw)
    }
    private func retireView(_ entry: Entry) async throws {
        entry.measurementLifetime = UUID()
        if let pending = entry.retiringView { return try await pending.value }
        guard let view = entry.view else { return }
        let operation = Task { @MainActor in try await view.detach() }; entry.retiringView = operation
        do { try await operation.value; if entry.view === view { entry.view = nil }; entry.retiringView = nil }
        catch { entry.retiringView = nil; throw error }
    }
    private func acceptPreparedChrome(_ entry: Entry,_ args:[String:Any]) {
        guard let initial=args["initialHostChrome"] as? [String:Any],let raw=entry.preparedClientChrome,
              (initial["revision"] as? NSNumber)?.uint64Value == (raw["revision"] as? NSNumber)?.uint64Value else { return }
        entry.clientChrome=raw;entry.preparedClientChrome=nil
    }
    private func measureLayout(_ entry: Entry, _ supplied: [String: Any], preparing: Bool) async throws -> [String: Any] {
        let started = DispatchTime.now().uptimeNanoseconds
        let frozen = try IOSLayoutMeasurement.snapshot(supplied)
        guard let observation = frozen["observation"] as? [String: Any], var chrome = frozen["chrome"] as? [String: Any],
              let revision = frozen["layoutRevision"] as? String else { throw fail("Expected complete host layout observation, chrome and revision") }
        let restartAttempt: [String: Any]?
        if let context = frozen["restartAttempt"] {
            guard preparing, let value = context as? [String: Any] else { throw IOSLayoutMeasurementError.invalidSnapshot }
            restartAttempt = value
        } else { restartAttempt = nil }
        let measurement = try IOSLayoutMeasurement(observation: observation, layoutRevision: revision,
                                                   preparingNavigation: preparing, restartAttempt: restartAttempt,
                                                   nowNanoseconds: started)
        let lifetime = entry.measurementLifetime
        chrome["coordinateSpace"] = frozen["coordinateSpace"]
        chrome.removeValue(forKey: "observationId")
        // Atomic layout measures the native view already mounted in this
        // shell. The prior accepted clientChrome is not its coordinate anchor.
        chrome = try await measureChrome(entry, chrome, prospective: false, measurement: measurement, lifetime: lifetime)
        for key in ["sessionId", "pageId"] { chrome.removeValue(forKey: key); if let value = observation[key] { chrome[key] = value } }
        var layout: [String: Any] = ["schemaVersion": 1, "chrome": chrome, "layoutRevision": revision]
        for key in ["ownerId", "surfaceGeneration", "observationId", "windowMetrics"] {
            guard let value = observation[key] else { throw fail("Missing layout observation field") }; layout[key] = value
        }
        return layout
    }
    private func updateChrome(_ entry: Entry, _ supplied: [String: Any]) async throws {
        let frozen = try IOSLayoutMeasurement.snapshot(supplied)
        let measured=try await measureChrome(entry,frozen,prospective:false)
        try entry.session.updateHostChrome(object(measured));entry.clientChrome=frozen
    }
    private func measurementOwnerCancellation(_ entry: Entry, _ lifetime: UUID) -> IOSLayoutCancellationReason? {
        IOSLayoutMeasurement.ownerCancellation(taskCancelled: Task.isCancelled, engineDetached: detached,
            engineInitializing: initializing != nil, entryClosing: entry.closing != nil,
            viewRetiring: entry.retiringView != nil, lifetimeCurrent: entry.measurementLifetime == lifetime,
            entryPresent: entries.values.contains(where: { $0 === entry }))
    }
    private func requireMeasurement(_ decision: IOSLayoutMeasurement.Decision) throws {
        try decision.requireReadyOrWaiting()
    }
    private func nativeMeasurement(_ view: WeappContainerView) -> IOSLayoutMeasurement.Native? {
        // Capture through the SDK's one UIKit geometry contract. This passive
        // read neither advances its observation nor extends this attempt's lease.
        guard let window = view.window, let scene = window.windowScene,
              let captured = view.captureWindowMetrics(),
              let metrics = codec(captured) as? [String: Any] else { return nil }
        let inScreen = view.convert(view.bounds, to: scene.screen.coordinateSpace)
        return IOSLayoutMeasurement.Native(windowMetrics: metrics, left: Double(inScreen.minX), top: Double(inScreen.minY))
    }
    private func restartMeasurementSnapshot(_ entry: Entry, _ measurement: IOSLayoutMeasurement) throws -> (receipt: [String: Any], state: [String: Any])? {
        guard let context = measurement.restartAttempt else { return nil }
        guard let owner = context["ownerId"] as? String, let attempt = context["attemptId"] as? String,
              let snapshot = codec(try entry.session.queryDevPackAttemptForLayout(ownerId: owner, attemptId: attempt)) as? [String: Any],
              let receipt = snapshot["receipt"] as? [String: Any], let state = snapshot["state"] as? [String: Any] else {
            throw IOSLayoutMeasurementError.invalidSnapshot
        }
        return (receipt, state)
    }
    private func measureChrome(_ entry: Entry, _ supplied: [String: Any], prospective: Bool,
                               measurement suppliedMeasurement: IOSLayoutMeasurement? = nil,
                               lifetime suppliedLifetime: UUID? = nil) async throws -> [String: Any] {
        let started = DispatchTime.now().uptimeNanoseconds
        let measurement = try suppliedMeasurement ?? IOSLayoutMeasurement(nowNanoseconds: started)
        let lifetime = suppliedLifetime ?? entry.measurementLifetime
        var payload = try IOSLayoutMeasurement.snapshot(supplied)
        let anchor = try IOSLayoutMeasurement.snapshot(prospective ? (entry.clientChrome ?? payload) : payload)
        let coordinates = payload.removeValue(forKey: "coordinateSpace") as? String ?? "screen"
        guard coordinates == "screen" || coordinates == "flutterClient" else { throw fail("Unknown chrome coordinate space") }
        while true {
            try requireMeasurement(measurement.decision(nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                                       ownerCancellation: measurementOwnerCancellation(entry, lifetime)))
            if coordinates == "screen", measurement.observation == nil { return payload }
            // Every atomic payload, even at unchanged dimensions, must still
            // belong to the exact immutable native observation and page owner.
            // The exact receipt is read from native metadata on each poll.
            // Never treat the copied Dart proof as an authorization receipt.
            let restartSnapshot = try restartMeasurementSnapshot(entry, measurement)
            let state: [String: Any]?
            if let restartSnapshot { state = restartSnapshot.state }
            else if measurement.observation != nil { state = codec(try entry.session.state()) as? [String: Any] }
            else { state = nil }
            try requireMeasurement(measurement.decision(nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                                       ownerCancellation: measurementOwnerCancellation(entry, lifetime), state: state,
                                                       restartReceipt: restartSnapshot?.receipt))
            if let view = entry.view, let native = nativeMeasurement(view) {
                var measured = payload
                if coordinates == "flutterClient" {
                    guard let content = anchor["contentRect"] as? [String: Any],
                          let left = IOSLayoutMeasurement.number(content["left"]),
                          let top = IOSLayoutMeasurement.number(content["top"]) else { throw fail("Missing content rectangle") }
                    let dx = native.left - left, dy = native.top - top
                    for name in ["contentRect", "menuButtonRect"] {
                        guard var rect = measured[name] as? [String: Any] else { throw fail("Missing chrome rectangle") }
                        for key in ["left", "right"] { if let n = IOSLayoutMeasurement.number(rect[key]) { rect[key] = n + dx } }
                        for key in ["top", "bottom"] { if let n = IOSLayoutMeasurement.number(rect[key]) { rect[key] = n + dy } }
                        measured[name] = rect
                    }
                }
                let content = measured["contentRect"] as? [String: Any]
                let width = IOSLayoutMeasurement.number(content?["width"]), height = IOSLayoutMeasurement.number(content?["height"])
                let sizeReady = prospective || (width != nil && height != nil
                    && abs(width! - Double(view.bounds.width.rounded())) <= 0.5
                    && abs(height! - Double(view.bounds.height.rounded())) <= 0.5)
                let decision = measurement.decision(nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
                    ownerCancellation: measurementOwnerCancellation(entry, lifetime), state: state, native: native, chrome: measured,
                    restartReceipt: restartSnapshot?.receipt)
                try requireMeasurement(decision)
                if sizeReady && decision == .ready {
                    // Re-read the journal and owner immediately before returning
                    // a prepared layout. No cancelled/replaced attempt can use
                    // a receipt cached before a suspended measurement poll.
                    if let final = try restartMeasurementSnapshot(entry, measurement) {
                        let finalDecision = measurement.decision(nowNanoseconds: DispatchTime.now().uptimeNanoseconds,
                            ownerCancellation: measurementOwnerCancellation(entry, lifetime), state: final.state,
                            native: native, chrome: measured, restartReceipt: final.receipt)
                        try requireMeasurement(finalDecision)
                        if finalDecision == .ready { return measured }
                    } else { return measured }
                }
            }
            let remaining = measurement.remainingNanoseconds(now: DispatchTime.now().uptimeNanoseconds)
            if remaining == 0 { throw IOSLayoutMeasurementError.expired }
            // Yield UIKit's actor so layout, close and view retirement can run.
            do { try await Task.sleep(nanoseconds: min(16_000_000, remaining)) }
            catch is CancellationError { throw IOSLayoutMeasurementError.cancelled(.taskCancelled) }
        }
    }
    private func close(_ id: Int64, _ entry: Entry) async throws {
        entry.measurementLifetime = UUID()
        if let pending=entry.accountCleanup { emit(id,["type":"accountCleanupCancelled","operationId":pending.operationId]) }
        if let operation = entry.closing { return try await operation.value }
        let operation = Task { @MainActor in
            try await self.retireView(entry)
            try await entry.session.close()
        }
        entry.closing = operation
        do { try await operation.value; try await entry.deviceServices?.close(); entries.removeValue(forKey: id); closed.insert(id) }
        catch { entry.closing = nil; throw error }
    }
    private func retireAll() async throws {
        var failure: Error?
        for (id, entry) in Array(entries) { do { try await close(id, entry) } catch { failure = failure ?? error } }
        if let failure { throw failure }
    }
    private func event(_ id: Int64, _ event: WeappContainerEvent) {
        switch event {
        case .ready(let value): emit(id, merged(value, type: "ready"))
        case .navigation(let value): emit(id, merged(value, type: "navigation"))
        case .chrome(let value): emit(id, merged(value, type: "chrome"))
        case .raw(let value): if let fields = codec(value) as? [String: Any] { emit(id, fields) }
        case .message(let value): emit(id, ["type": "message", "message": codec(value)])
        case .error(let error): emit(id, ["type": "error", "code": error.code, "message": error.message])
        case .closed(let error): emit(id, ["type": "closed", "ok": error == nil, "error": error.map { ["code": $0.code, "message": $0.message] as Any } ?? NSNull()])
        }
    }
    private func merged(_ value: WeappJSON, type: String) -> [String: Any] { var fields = codec(value) as? [String: Any] ?? [:]; fields["type"] = type; return fields }
    private func emit(_ id: Int64, _ event: [String: Any]) { if !detached { sink?(["id": id, "event": event]) } }
    private func fail(_ message: String) -> WeappContainerError { .init(code: "ERR_INVALID_REQUEST", message: message) }
    private func string(_ args: [String: Any], _ name: String) throws -> String { guard let value = args[name] as? String else { throw fail("Missing \(name)") }; return value }
    private func json(_ value: Any?) throws -> WeappJSON {
        guard let value, !(value is NSNull) else { return .null }
        return try JSONDecoder().decode(WeappJSON.self, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }
    private func object(_ value: Any?) throws -> [String: WeappJSON] {
        if value == nil { return [:] }; guard case .object(let values) = try json(value) else { throw fail("Expected JSON object") }; return values
    }
    private func codec(_ value: WeappJSON) -> Any {
        switch value {
        case .null: return NSNull(); case .bool(let v): return v; case .number(let v): return v; case .string(let v): return v
        case .array(let v): return v.map(codec); case .object(let v): return v.mapValues(codec)
        }
    }
    @MainActor private final class Factory: NSObject, @preconcurrency FlutterPlatformViewFactory {
        weak var plugin: WeappContainerIosPlugin?
        init(_ plugin: WeappContainerIosPlugin) { self.plugin = plugin }
        func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
        func create(withFrame frame: CGRect, viewIdentifier viewID: Int64, arguments args: Any?) -> FlutterPlatformView {
            guard let plugin, !plugin.detached, plugin.initializing == nil,
                  let values = args as? [String: Any], let id = values["id"] as? NSNumber, let entry = plugin.entries[id.int64Value], entry.view == nil else {
                return FailedView("Unknown session or duplicate view")
            }
            do {
                let view = try WeappContainerView(session: entry.session); view.frame = frame; entry.view = view
                view.onPresented = { [weak plugin] revision in plugin?.emit(id.int64Value, ["type": "presented", "revision": revision]) }
                return WrappedView(view) { [weak plugin, weak entry] in
                    guard let plugin, let entry, entry.view === view else { return }
                    do { try await plugin.retireView(entry) }
                    catch { plugin.emit(id.int64Value, ["type": "error", "code": "ERR_RENDER", "message": error.localizedDescription]) }
                }
            } catch { plugin.emit(id.int64Value, ["type": "error", "code": "ERR_RENDER", "message": error.localizedDescription]); return FailedView(error.localizedDescription) }
        }
    }
    @MainActor private final class WrappedView: NSObject, @preconcurrency FlutterPlatformView {
        let native: UIView
        let retirement: @MainActor () async -> Void
        init(_ native: UIView, retirement: @escaping @MainActor () async -> Void) { self.native = native; self.retirement = retirement }
        func view() -> UIView { native }
        deinit { let cleanup = retirement; Task { @MainActor in await cleanup() } }
    }
    @MainActor private final class FailedView: NSObject, @preconcurrency FlutterPlatformView {
        let label = UILabel()
        init(_ message: String) { super.init(); label.text = message }
        func view() -> UIView { label }
    }
}
#endif
