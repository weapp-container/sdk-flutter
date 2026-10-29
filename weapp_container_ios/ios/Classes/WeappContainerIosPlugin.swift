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
        var clientChrome: [String: Any]?
        var preparedClientChrome: [String: Any]?
        init(_ session: WeappContainerSession) { self.session = session }
    }
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
            catch let error as WeappHostError { result(FlutterError(code: error.code.rawValue, message: error.message, details: nil)) }
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
            let id = nextID; nextID += 1
            let entry = Entry(WeappContainerSession(configuration: configuration)); entries[id] = entry
            entry.session.onEvent = { [weak self] event in self?.event(id, event) }
            return ["id": id]
        }
        guard let value = args["id"] as? NSNumber else { throw fail("Missing id") }
        let id = value.int64Value
        if ["close", "detachView"].contains(call.method), closed.contains(id) { return nil }
        guard let entry = entries[id] else { throw WeappContainerError(code: "ERR_CLOSED", message: "Unknown or retired session") }
        let session = entry.session
        switch call.method {
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
        case "load":
            try await session.load(packURL: URL(fileURLWithPath: try string(args, "packPath")), route: args["route"] as? String, options: try object(args["options"]), initialHostChrome: args["initialHostChrome"] == nil ? nil : try object(args["initialHostChrome"]))
            acceptPreparedChrome(entry,args)
        case "applyDevPack":
            let value=try await session.applyDevPack(packURL: URL(fileURLWithPath: try string(args, "packPath")), route: args["route"] as? String, options: try object(args["options"]), initialHostChrome: args["initialHostChrome"] == nil ? nil : try object(args["initialHostChrome"]))
            acceptPreparedChrome(entry,args);return codec(value)
        case "devState": return codec(try session.devState())
        case "clearDevStorage": try await session.clearDevStorage()
        case "navigate": try session.navigate(route: string(args, "route"), query: object(args["query"]), replace: args["replace"] as? Bool ?? false)
        case "back": try session.back()
        case "switchTab": try session.switchTab(route: string(args, "route"))
        case "inspectPackChrome": return codec(try session.inspectPackChrome(packURL: URL(fileURLWithPath: string(args, "packPath")), route: args["route"] as? String))
        case "hostChrome": try await updateChrome(entry, args.filter { $0.key != "id" })
        case "prepareHostChrome":
            let raw=args.filter { $0.key != "id" }
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
        case "capabilities": return codec(try session.capabilities())
        case "prepareView": return codec(try await session.prepareView())
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
                    message: error["message"] as? String ?? "Host method failed", retryable: error["retryable"] as? Bool ?? false))
            } else { completion = .success(try json(args["result"])) }
            guard let pending = entry.calls.removeValue(forKey: callID) else { throw WeappHostError(code: .cancelled, message: "Call no longer accepts completion") }
            pending.resume(with: completion)
        default: return FlutterMethodNotImplemented
        }
        return nil
    }
    private func retireView(_ entry: Entry) async throws {
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
    private func updateChrome(_ entry: Entry, _ supplied: [String: Any]) async throws {
        let measured=try await measureChrome(entry,supplied,prospective:false)
        try entry.session.updateHostChrome(object(measured));entry.clientChrome=supplied
    }
    private func measureChrome(_ entry: Entry, _ supplied: [String: Any],prospective:Bool) async throws -> [String:Any] {
        var payload = supplied
        let coordinates = payload.removeValue(forKey: "coordinateSpace") as? String ?? "screen"
        if coordinates == "screen" { return payload }
        guard coordinates == "flutterClient" else { throw fail("Unknown chrome coordinate space") }
        let deadline = Date().addingTimeInterval(10)
        while true {
            try Task.checkCancellation()
            guard !detached, entry.closing == nil, entries.values.contains(where: { $0 === entry }) else {
                throw WeappContainerError(code: "ERR_CANCELLED", message: "Chrome owner retired before native measurement")
            }
            if let view = entry.view, let window = view.window, view.bounds.width > 0, view.bounds.height > 0 {
                guard let content = (prospective ? entry.clientChrome?["contentRect"] : payload["contentRect"]) as? [String: Any],
                      let left = content["left"] as? NSNumber, let top = content["top"] as? NSNumber else { throw fail("Missing content rectangle") }
                if !prospective, let width=content["width"] as? NSNumber,let height=content["height"] as? NSNumber,
                   abs(Double(view.bounds.width)-width.doubleValue)>1 || abs(Double(view.bounds.height)-height.doubleValue)>1 {
                    guard Date()<deadline else { throw WeappContainerError(code:"ERR_NOT_READY",message:"Native chrome viewport has not matched measured layout") }
                    try await Task.sleep(nanoseconds:16_000_000);continue
                }
                let origin = view.convert(view.bounds, to: window.screen.coordinateSpace).origin
                let dx = Double(origin.x) - left.doubleValue, dy = Double(origin.y) - top.doubleValue
                for name in ["contentRect", "menuButtonRect"] {
                    guard var rect = payload[name] as? [String: Any] else { throw fail("Missing chrome rectangle") }
                    for key in ["left", "right"] { if let n = rect[key] as? NSNumber { rect[key] = n.doubleValue + dx } }
                    for key in ["top", "bottom"] { if let n = rect[key] as? NSNumber { rect[key] = n.doubleValue + dy } }
                    payload[name] = rect
                }
                return payload
            }
            guard Date() < deadline else { throw WeappContainerError(code: "ERR_NOT_READY", message: "Chrome needs an attached measured native view") }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
    }
    private func close(_ id: Int64, _ entry: Entry) async throws {
        if let operation = entry.closing { return try await operation.value }
        let operation = Task { @MainActor in
            try await entry.session.close()
            try await self.retireView(entry)
        }
        entry.closing = operation
        do { try await operation.value; entries.removeValue(forKey: id); closed.insert(id) }
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
