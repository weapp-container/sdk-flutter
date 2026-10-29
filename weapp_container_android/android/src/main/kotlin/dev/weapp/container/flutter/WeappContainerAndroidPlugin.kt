package dev.weapp.container.flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.View
import com.sonofmagic.weapp.container.sdk.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.*
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionException
import java.util.concurrent.ExecutionException

/** Per-engine registry. The native SDK owns worker/runtime/GLES operations. */
class WeappContainerAndroidPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var app: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var epoch: String? = null
    private var initializing: CompletableFuture<Unit>? = null
    private var nextId = 1L
    private var detached = false
    private val sessions = mutableMapOf<Long, Entry>()
    private val closed = mutableSetOf<Long>()
    private class Entry(val session: WeappContainerSession, val diagnostics: Boolean) {
        var view: WeappContainerView? = null
        var closing: CompletableFuture<Unit>? = null
        var retiringView: CompletableFuture<Unit>? = null
        val replies = mutableMapOf<String, HostReply>()
        var clientChrome: JSONObject? = null
        var preparedClientChrome: JSONObject? = null
    }
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        app = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "dev.weapp.container/methods")
        events = EventChannel(binding.binaryMessenger, "dev.weapp.container/events")
        methods.setMethodCallHandler(this); events.setStreamHandler(this)
        binding.platformViewRegistry.registerViewFactory("dev.weapp.container/view", object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
            override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
                check(!detached && initializing == null && epoch != null) { "Plugin is not initialized" }
                val id = ((args as Map<*, *>)["id"] as Number).toLong()
                val entry = requireEntry(id)
                check(entry.view == null) { "Session already has a platform view" }
                val view = WeappContainerView(context); view.bind(entry.session); entry.view = view
                return object : PlatformView {
                    override fun getView(): View = view
                    override fun dispose() { if (entry.view === view) retireView(entry) }
                }
            }
        })
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detached = true; sink = null
        methods.setMethodCallHandler(null); events.setStreamHandler(null)
        retiring.add(this)
        retireEngine(0)
    }
    private fun retireEngine(attempt: Int) {
        retireAll().whenComplete { _, error ->
            if (error == null) retiring.remove(this)
            else if (attempt < 3) main.postDelayed({ retireEngine(attempt + 1) }, 100L * (attempt + 1))
            else Log.e("WeappContainer", "Engine cleanup retains sessions after retries", error)
        }
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }
    private fun emit(id: Long, event: Any) { if (!detached) sink?.success(mapOf("id" to id, "event" to codec(event))) }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            check(!detached) { "Engine has detached" }
            val args = call.arguments as? Map<*, *> ?: throw IllegalArgumentException("Expected method arguments")
            if (call.method == "initialize") {
                val next = args["clientEpoch"] as? String ?: throw IllegalArgumentException("Missing clientEpoch")
                require(next.isNotBlank())
                settle(initialize(next), result); return
            }
            check(epoch != null && initializing == null) { "Initialize the Dart client before creating sessions" }
            if (call.method == "create") {
                require(args.containsKey("storageKey")) { "storageKey must be explicit; null selects memory" }
                val key = args["storageKey"] as? String
                require(args["storageKey"] == null || key != null) { "Invalid storageKey" }
                val id = nextId++
                val gpuRequired = args["gpuRequired"]?.let { value -> require(value is Boolean) { "gpuRequired must be a boolean" }; value as Boolean }
                val devDiagnostics = args["devDiagnostics"]?.let { value -> require(value is Boolean) { "devDiagnostics must be a boolean" }; value as Boolean } ?: false
                val layout = args["hostLayout"] as? Map<*, *>
                if (layout != null) require(layout["protocolVersion"] == "1.0" && layout["atomic"] == true) { "hostLayout requires atomic protocol 1.0" }
                val entry = Entry(WeappContainerSession(app, key, gpuRequired = gpuRequired, devDiagnostics = devDiagnostics, atomicHostLayout = layout != null), devDiagnostics)
                sessions[id] = entry
                entry.session.eventListener = ContainerEventListener { emit(id, it) }
                result.success(mapOf("id" to id)); return
            }
            val id = (args["id"] as? Number)?.toLong() ?: throw IllegalArgumentException("Missing id")
            if (call.method in listOf("close", "detachView") && closed.contains(id)) { result.success(null); return }
            val entry = requireEntry(id)
            val session = entry.session
            val operation: CompletableFuture<*> = when (call.method) {
                "registerHostMethod" -> {
                    val name = args["name"] as String
                    session.registerHostMethod(name, HostMethod { hostCall, reply ->
                        entry.replies[hostCall.id] = reply
                        hostCall.onCancel = {
                            entry.replies.remove(hostCall.id)
                            emit(id, mapOf("type" to "hostCallCancelled", "callId" to hostCall.id))
                        }
                        if (!hostCall.isCancelled) emit(id, mapOf("type" to "hostCall", "callId" to hostCall.id,
                            "method" to hostCall.method, "payload" to codec(hostCall.payload), "deadlineNs" to hostCall.deadlineNs,
                            "cancelToken" to hostCall.cancelToken))
                    })
                }
                "load" -> session.load(PackSource.Directory(File(args["packPath"] as String)), LoadOptions(args["route"] as? String, jsonObject(args["options"]), args["initialHostChrome"]?.let { jsonObject(it) }, args["initialHostLayout"]?.let { jsonObject(it) })).whenComplete { _, error -> if(error==null) acceptPreparedChrome(entry,args) }
                "applyDevPack" -> session.applyDevPack(PackSource.Directory(File(args["packPath"] as String)), LoadOptions(args["route"] as? String, jsonObject(args["options"]), args["initialHostChrome"]?.let { jsonObject(it) }, args["initialHostLayout"]?.let { jsonObject(it) })).whenComplete { _, error -> if(error==null) acceptPreparedChrome(entry,args) }
                "command" -> session.executeCommand(args["operation"] as String, jsonObject(args["payload"])).thenApply { value ->
                    if (args["operation"] == "applyDevPackAttempt" && value is JSONObject && value.optString("status") == "accepted") {
                        entry.preparedClientChrome?.let { entry.clientChrome = it }; entry.preparedClientChrome = null
                    }
                    value
                }
                "prepareHostLayout", "hostLayout" -> {
                    val supplied = jsonObject(args.filterKeys { it != "id" })
                    measureLayout(entry, supplied).thenCompose { value ->
                        if (call.method == "prepareHostLayout") {
                            entry.preparedClientChrome = supplied.getJSONObject("chrome")
                            CompletableFuture.completedFuture(value)
                        } else session.executeCommand("hostLayout", value).thenApply { entry.clientChrome = supplied.getJSONObject("chrome"); null }
                    }
                }
                "devState" -> session.devState()
                "clearDevStorage" -> session.clearDevStorage()
                "navigate" -> session.navigate(args["route"] as String, jsonObject(args["query"]), args["replace"] as? Boolean ?: false)
                "back" -> session.back()
                "switchTab" -> session.switchTab(args["route"] as String)
                "inspectPackChrome" -> session.inspectPackChrome(PackSource.Directory(File(args["packPath"] as String)), args["route"] as? String)
                "hostChrome" -> updateChrome(entry, jsonObject(args.filterKeys { it != "id" }))
                "prepareHostChrome" -> {
                    val raw=jsonObject(args.filterKeys { it != "id" })
                    measureChrome(entry,JSONObject(raw.toString()),true).thenApply { value -> entry.preparedClientChrome=raw;value }
                }
                "setPreviewOccluded" -> session.setPreviewOccluded(args["occluded"] as Boolean)
                "sendMessage" -> session.sendMessage(json(args["message"]))
                "setForeground" -> session.setForeground(args["foreground"] as Boolean)
                "flushStorage" -> session.flushStorage()
                "state" -> session.state()
                "capabilities" -> session.capabilities()
                "observeHostLayout" -> session.requestHostLayoutObservation()
                "prepareView" -> session.prepareView()
                "detachView" -> retireView(entry)
                "close" -> closeEntry(id, entry)
                "completeHostCall" -> {
                    require(args.containsKey("result") xor args.containsKey("error")) { "Provide exactly one of result/error" }
                    val value = if (args.containsKey("result")) json(args["result"]) else null
                    val failure = if (args.containsKey("error")) args["error"] as Map<*, *> else null
                    val reply = entry.replies.remove(args["callId"] as String)
                    if (reply == null) { result.error("cancelled", "Call no longer accepts completion", null); return }
                    if (args.containsKey("result")) reply.resolve(value)
                    else {
                        val error = checkNotNull(failure)
                        val code = when (error["code"]) {
                            "permission_denied" -> HostErrorCode.PERMISSION_DENIED; "timeout" -> HostErrorCode.TIMEOUT
                            "cancelled" -> HostErrorCode.CANCELLED; "unsupported" -> HostErrorCode.UNSUPPORTED
                            else -> HostErrorCode.INVALID_REQUEST
                        }
                        reply.reject(code, error["message"] as? String ?: "Host method failed", error["retryable"] as? Boolean ?: false)
                    }
                    CompletableFuture.completedFuture(Unit)
                }
                else -> { result.notImplemented(); return }
            }
            settle(operation, result, call.method, entry)
        } catch (error: Throwable) { failure(result, error) }
    }
    private fun initialize(next: String): CompletableFuture<Unit> {
        initializing?.let { pending -> return pending.thenCompose { initialize(next) } }
        if (next == epoch) return CompletableFuture.completedFuture(Unit)
        val operation = retireAll()
        val done = CompletableFuture<Unit>(); initializing = done
        operation.whenComplete { _, error ->
            initializing = null
            if (error == null) { epoch = next; done.complete(Unit) } else done.completeExceptionally(error)
        }
        return done
    }
    private fun acceptPreparedChrome(entry: Entry,args: Map<*,*>) {
        val initial=args["initialHostChrome"] as? Map<*,*> ?: return
        val raw=entry.preparedClientChrome ?: return
        if((initial["revision"] as? Number)?.toLong()==raw.optLong("revision"))entry.clientChrome=raw
        entry.preparedClientChrome=null
    }
    private fun measureLayout(entry: Entry, supplied: JSONObject): CompletableFuture<JSONObject> {
        val observation = supplied.getJSONObject("observation")
        val chrome = JSONObject(supplied.getJSONObject("chrome").toString())
        chrome.put("coordinateSpace", supplied.optString("coordinateSpace", "screen")); chrome.remove("observationId")
        // The atomic shell already moved this native view. Match its current
        // size and origin; old accepted chrome belongs to the previous shell.
        return measureChrome(entry, chrome, false).thenApply { measured ->
            for (key in listOf("sessionId", "pageId")) { measured.remove(key); if (observation.has(key)) measured.put(key, observation.get(key)) }
            JSONObject().put("schemaVersion", 1).put("layoutRevision", supplied.getString("layoutRevision"))
                .put("ownerId", observation.getString("ownerId")).put("surfaceGeneration", observation.getString("surfaceGeneration"))
                .put("observationId", observation.getString("observationId")).put("windowMetrics", observation.getJSONObject("windowMetrics")).put("chrome", measured)
        }
    }
    private fun updateChrome(entry: Entry, payload: JSONObject): CompletableFuture<Unit> {
        val raw=JSONObject(payload.toString())
        return measureChrome(entry,payload,false).thenCompose { measured ->
            entry.session.updateHostChrome(measured).thenApply { entry.clientChrome=raw;Unit }
        }
    }
    private fun measureChrome(entry: Entry, payload: JSONObject, prospective: Boolean): CompletableFuture<JSONObject> {
        val coordinates = payload.optString("coordinateSpace", "screen")
        payload.remove("coordinateSpace")
        if (coordinates == "screen") return CompletableFuture.completedFuture(payload)
        require(coordinates == "flutterClient") { "Unknown chrome coordinate space" }
        val result = CompletableFuture<JSONObject>()
        val deadline = SystemClock.uptimeMillis() + 10_000
        fun observe() {
            if (result.isDone) return
            if (detached || entry.closing != null || !sessions.containsValue(entry)) {
                result.completeExceptionally(ContainerException("ERR_CANCELLED", "Chrome owner retired before native measurement")); return
            }
            val view = entry.view
            if (view == null || !view.isAttachedToWindow || view.width <= 0 || view.height <= 0) {
                if (SystemClock.uptimeMillis() >= deadline) result.completeExceptionally(ContainerException("ERR_NOT_READY", "Chrome needs an attached measured native view"))
                else main.postDelayed({ observe() }, 16)
                return
            }
            try {
                val origin = IntArray(2); view.getLocationOnScreen(origin)
                val density = view.resources.displayMetrics.density.toDouble()
                val content = if(prospective) entry.clientChrome?.getJSONObject("contentRect")
                    ?: payload.getJSONObject("contentRect")
                    else payload.getJSONObject("contentRect")
                if(!prospective&&(kotlin.math.abs(view.width/density-content.getDouble("width"))>1||kotlin.math.abs(view.height/density-content.getDouble("height"))>1)) {
                    if(SystemClock.uptimeMillis()>=deadline)throw ContainerException("ERR_NOT_READY","Native chrome viewport has not matched measured layout")
                    main.postDelayed({ observe() },16);return
                }
                val targetContent = payload.getJSONObject("contentRect")
                val viewport = if (prospective) ChromeViewport.prospective(
                    targetContent.getDouble("width"), targetContent.getDouble("height"), density
                ) else ChromeViewport.measured(view.width, view.height, density)
                // Only the content viewport is integer-quantized. Origins and
                // the actual capsule stay measured screen-logical doubles.
                targetContent.put("width", viewport.first).put("height", viewport.second)
                val dx = origin[0] / density - content.getDouble("left")
                val dy = origin[1] / density - content.getDouble("top")
                for (name in listOf("contentRect", "menuButtonRect")) {
                    val rect = payload.getJSONObject(name)
                    for (edge in listOf("left", "right")) if (rect.has(edge)) rect.put(edge, rect.getDouble(edge) + dx)
                    for (edge in listOf("top", "bottom")) if (rect.has(edge)) rect.put(edge, rect.getDouble(edge) + dy)
                }
                result.complete(payload)
            } catch (error: Throwable) { result.completeExceptionally(error) }
        }
        observe()
        return result
    }
    private fun retireView(entry: Entry): CompletableFuture<Unit> {
        entry.retiringView?.let { return it }
        val view = entry.view ?: return CompletableFuture.completedFuture(Unit)
        val done = CompletableFuture<Unit>(); entry.retiringView = done
        view.unbindAsync().whenComplete { _, error ->
            entry.retiringView = null
            if (error == null) { if (entry.view === view) entry.view = null; done.complete(Unit) }
            else done.completeExceptionally(error)
        }
        return done
    }
    private fun closeEntry(id: Long, entry: Entry): CompletableFuture<Unit> {
        entry.closing?.let { return it }
        retireView(entry)
        val done = CompletableFuture<Unit>(); entry.closing = done
        entry.session.closeAsync().whenComplete { _, error ->
            if (error == null) { sessions.remove(id); closed.add(id); entry.replies.clear(); done.complete(Unit) }
            else { entry.closing = null; done.completeExceptionally(error) }
        }
        return done
    }
    private fun retireAll(): CompletableFuture<Unit> {
        val tasks = sessions.toMap().map { (id, entry) -> closeEntry(id, entry) }.toTypedArray()
        return CompletableFuture.allOf(*tasks).thenApply { Unit }
    }
    private fun requireEntry(id: Long): Entry = sessions[id] ?: throw ContainerException("ERR_CLOSED", "Unknown or retired session id")
    private fun settle(future: CompletableFuture<*>, result: MethodChannel.Result, operation: String? = null, entry: Entry? = null) {
        future.whenComplete { value, error -> if (error == null) result.success(if (value === Unit) null else codec(value)) else {
            if (entry?.diagnostics == true) logFailure(operation, entry, error)
            failure(result, error)
        } }
    }
    private fun logFailure(operation: String?, entry: Entry, raw: Throwable) {
        var error = raw
        while ((error is CompletionException || error is ExecutionException) && error.cause != null) error = error.cause!!
        // Never log arbitrary native text, payloads, paths or credentials. The
        // reviewed reason and numeric layout observations locate startup faults.
        val reason = when (error.message) {
            "initial host chrome dimensions differ from window metrics" -> "chrome-viewport-mismatch"
            "invalid host chrome geometry" -> "invalid-chrome-geometry"
            "host chrome geometry exceeds logical bounds" -> "chrome-bounds"
            else -> "native-operation"
        }
        val code = (error as? ContainerException)?.code?.takeIf { it.matches(Regex("ERR_[A-Z_]{1,48}")) } ?: "ERR_ANDROID"
        val op = operation?.takeIf { it in setOf("load", "applyDevPack", "prepareView", "hostChrome", "prepareHostChrome", "inspectPackChrome", "state", "capabilities") } ?: "other"
        val content = entry.clientChrome?.optJSONObject("contentRect")
        val view = entry.view
        Log.e("WeappContainer", "operation=$op code=$code reason=$reason clientWidth=${content?.optDouble("width")} clientHeight=${content?.optDouble("height")} physicalWidth=${view?.width} physicalHeight=${view?.height} density=${view?.resources?.displayMetrics?.density}")
    }
    private fun failure(result: MethodChannel.Result, raw: Throwable) {
        var error = raw
        while ((error is CompletionException || error is ExecutionException) && error.cause != null) error = error.cause!!
        result.error((error as? ContainerException)?.code ?: "ERR_INVALID_REQUEST", error.message, null)
    }
    companion object {
        // Keep failed cleanup owners reachable instead of dropping live native resources.
        private val retiring = mutableSetOf<WeappContainerAndroidPlugin>()
        private fun codec(value: Any?): Any? = when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> value.keys().asSequence().associateWith { codec(value.opt(it)) }
            is JSONArray -> (0 until value.length()).map { codec(value.opt(it)) }
            is Map<*, *> -> value.entries.associate { it.key.toString() to codec(it.value) }
            is List<*> -> value.map(::codec)
            else -> value
        }
        private fun json(value: Any?): Any = when (value) {
            null -> JSONObject.NULL
            is Map<*, *> -> JSONObject().apply { value.forEach { (key, item) -> require(key is String); put(key, json(item)) } }
            is List<*> -> JSONArray().apply { value.forEach { put(json(it)) } }
            is String, is Number, is Boolean -> value
            else -> throw IllegalArgumentException("Only JSON values are accepted")
        }
        private fun jsonObject(value: Any?): JSONObject = if (value == null) JSONObject() else json(value) as JSONObject
    }
}
