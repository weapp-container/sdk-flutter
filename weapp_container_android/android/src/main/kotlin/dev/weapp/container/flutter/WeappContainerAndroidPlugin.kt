package dev.weapp.container.flutter

import android.content.Context
import android.content.res.Configuration
import android.graphics.Point
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.view.WindowInsets
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
import kotlin.math.roundToInt

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
        var measurementEpoch = 0L
        val measurements = mutableSetOf<CompletableFuture<JSONObject>>()
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
                    measureLayout(entry, supplied, call.method == "prepareHostLayout").thenCompose { value ->
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
                "capabilities" -> session.capabilities().thenApply(::preparedRestartCapabilities)
                "observeHostLayout" -> session.requestHostLayoutObservation()
                "prepareView" -> session.prepareView().thenApply(::preparedRestartCapabilities)
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
            settle(operation, result, call.method, entry, args)
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
    private fun measureLayout(entry: Entry, supplied: JSONObject, prepareOnly: Boolean): CompletableFuture<JSONObject> {
        val observation = JSONObject(supplied.getJSONObject("observation").toString())
        val revision = supplied.getString("layoutRevision")
        if (supplied.has("restartAttempt") && !prepareOnly) throw ContainerException("ERR_PROTOCOL_VERSION", "restartAttempt is valid only for prepareHostLayout")
        val restartAttempt = if (supplied.has("restartAttempt")) supplied.optJSONObject("restartAttempt")
            ?: throw ContainerException("ERR_PROTOCOL_VERSION", "restartAttempt must be an explicit versioned object") else null
        val proof = restartAttempt?.let { codec(it) as Map<*, *> }
        if (proof != null && !HostLayoutCoherence.validRestartProof(proof)) throw ContainerException("ERR_PROTOCOL_VERSION", "Invalid prepared restart measurement proof")
        val coherence = HostLayoutCoherence(codec(observation) as Map<*, *>, revision, SystemClock.uptimeMillis(), prepareOnly = prepareOnly, restartAttempt = proof)
        val chrome = JSONObject(supplied.getJSONObject("chrome").toString())
        chrome.put("coordinateSpace", supplied.optString("coordinateSpace", "screen")); chrome.remove("observationId")
        // The atomic shell already moved this native view. Match its current
        // size and origin; old accepted chrome belongs to the previous shell.
        return measureChrome(entry, chrome, false, coherence, restartAttempt).thenApply { measured ->
            for (key in listOf("sessionId", "pageId")) { measured.remove(key); if (observation.has(key)) measured.put(key, observation.get(key)) }
            JSONObject().put("schemaVersion", 1).put("layoutRevision", revision)
                .put("ownerId", observation.getString("ownerId")).put("surfaceGeneration", observation.getString("surfaceGeneration"))
                .put("observationId", observation.getString("observationId")).put("windowMetrics", observation.getJSONObject("windowMetrics")).put("chrome", measured)
        }
    }
    private fun preparedRestartCapabilities(value: JSONObject): JSONObject {
        val result = JSONObject(value.toString())
        val chrome = result.optJSONObject("chrome") ?: JSONObject().also { result.put("chrome", it) }
        val atomic = chrome.optJSONObject("atomicLayout") ?: JSONObject().also { chrome.put("atomicLayout", it) }
        atomic.put("preparedRestartMeasurement", "1.0")
        return result
    }
    private fun updateChrome(entry: Entry, payload: JSONObject): CompletableFuture<Unit> {
        val raw=JSONObject(payload.toString())
        return measureChrome(entry,payload,false).thenCompose { measured ->
            entry.session.updateHostChrome(measured).thenApply { entry.clientChrome=raw;Unit }
        }
    }
    private data class NativeChromeMeasurement(val view: WeappContainerView, val x: Int, val y: Int, val density: Double, val metrics: JSONObject)
    @Suppress("DEPRECATION")
    private fun measureNativeChrome(view: WeappContainerView?): NativeChromeMeasurement? {
        if (view == null || !view.isAttachedToWindow || !view.isAvailable || view.width <= 0 || view.height <= 0) return null
        val display = view.display ?: return null
        val insets = view.rootWindowInsets ?: return null
        val extent = Point(); display.getRealSize(extent)
        val density = view.resources.displayMetrics.density.toDouble()
        if (!density.isFinite() || density <= 0 || extent.x <= 0 || extent.y <= 0) return null
        val origin = IntArray(2); view.getLocationOnScreen(origin)
        val viewport = ChromeViewport.measured(view.width, view.height, density)
        val status = if (Build.VERSION.SDK_INT >= 30) insets.getInsetsIgnoringVisibility(WindowInsets.Type.statusBars()).top else insets.stableInsetTop
        // Same measured fields and integer quantization as the immutable native
        // SDK's WindowMetrics producer. That ABI deliberately has no safeArea.
        val metrics = JSONObject().put("windowWidth", viewport.first).put("windowHeight", viewport.second)
            .put("pixelRatio", density).put("screenWidth", (extent.x / density).roundToInt())
            .put("screenHeight", (extent.y / density).roundToInt()).put("statusBarHeight", status / density)
            .put("screenTop", origin[1] / density).put("deviceOrientation", if (view.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) "landscape" else "portrait")
        return NativeChromeMeasurement(view, origin[0], origin[1], density, metrics)
    }
    private fun measureChrome(entry: Entry, supplied: JSONObject, prospective: Boolean, coherence: HostLayoutCoherence? = null, restartAttempt: JSONObject? = null): CompletableFuture<JSONObject> {
        val source = JSONObject(supplied.toString())
        val coordinates = source.optString("coordinateSpace", "screen")
        source.remove("coordinateSpace")
        require(coordinates == "screen" || coordinates == "flutterClient") { "Unknown chrome coordinate space" }
        if (coordinates == "screen" && coherence == null) return CompletableFuture.completedFuture(source)
        val result = CompletableFuture<JSONObject>()
        entry.measurements.add(result)
        result.whenComplete { _, _ -> entry.measurements.remove(result) }
        val epoch = entry.measurementEpoch
        var ownedView = entry.view
        val deadline = coherence?.deadlineMillis ?: (SystemClock.uptimeMillis() + 10_000)
        lateinit var observe: () -> Unit
        fun retired(): Boolean = detached || entry.closing != null || entry.retiringView != null ||
            !sessions.containsValue(entry) || entry.measurementEpoch != epoch ||
            (ownedView != null && entry.view !== ownedView)
        fun stopIfExpiredOrRetired(): Boolean {
            if (result.isDone) return true
            if (retired()) {
                result.completeExceptionally(ContainerException("ERR_CANCELLED", "Chrome owner retired before native measurement")); return true
            }
            if (SystemClock.uptimeMillis() >= deadline) {
                result.completeExceptionally(ContainerException("ERR_NOT_READY", "Native chrome viewport has not matched measured layout")); return true
            }
            return false
        }
        fun retry() { if (!stopIfExpiredOrRetired()) main.postDelayed({ observe() }, 16) }
        fun translated(measurement: NativeChromeMeasurement): JSONObject? {
            val payload = JSONObject(source.toString())
            if (coordinates == "screen") return payload
            val content = if (prospective) entry.clientChrome?.getJSONObject("contentRect") ?: payload.getJSONObject("contentRect") else payload.getJSONObject("contentRect")
            if (!prospective && (kotlin.math.abs(measurement.view.width / measurement.density - content.getDouble("width")) > 1 || kotlin.math.abs(measurement.view.height / measurement.density - content.getDouble("height")) > 1)) return null
            val targetContent = payload.getJSONObject("contentRect")
            val viewport = if (prospective) ChromeViewport.prospective(targetContent.getDouble("width"), targetContent.getDouble("height"), measurement.density)
                else Pair(measurement.metrics.getInt("windowWidth"), measurement.metrics.getInt("windowHeight"))
            targetContent.put("width", viewport.first).put("height", viewport.second)
            val dx = measurement.x / measurement.density - content.getDouble("left")
            val dy = measurement.y / measurement.density - content.getDouble("top")
            for (name in listOf("contentRect", "menuButtonRect")) {
                val rect = payload.getJSONObject(name)
                for (edge in listOf("left", "right")) if (rect.has(edge)) rect.put(edge, rect.getDouble(edge) + dx)
                for (edge in listOf("top", "bottom")) if (rect.has(edge)) rect.put(edge, rect.getDouble(edge) + dy)
            }
            return payload
        }
        observe = observer@{
            if (stopIfExpiredOrRetired()) return@observer
            if (ownedView == null) ownedView = entry.view
            try {
                if (coherence == null) {
                    val measurement = measureNativeChrome(entry.view)
                    val payload = measurement?.let(::translated)
                    if (payload == null) retry() else result.complete(payload)
                } else {
                    fun assess(snapshot: JSONObject, finalProof: Boolean) {
                        if (stopIfExpiredOrRetired()) return
                        val state = snapshot.getJSONObject("state")
                        val receipt = snapshot.optJSONObject("journalReceipt")
                        // Every poll re-reads both journal and state in one
                        // passive native-owner task. Re-measure only after its
                        // reply; no geometry or healthy result is cached.
                        val measurement = measureNativeChrome(entry.view)
                        val decision = coherence.decide(SystemClock.uptimeMillis(), measurement?.let { codec(it.metrics) as Map<*, *> }, codec(state) as Map<*, *>, journalReceipt = receipt?.let { codec(it) as Map<*, *> })
                        when (decision) {
                            HostLayoutCoherence.Decision.SUPERSEDED -> result.completeExceptionally(ContainerException("ERR_CANCELLED", "layout does not match the exact native observation and page owner"))
                            HostLayoutCoherence.Decision.CANCELLED -> result.completeExceptionally(ContainerException("ERR_CANCELLED", "Prepared restart journal authority changed before native measurement"))
                            HostLayoutCoherence.Decision.READY -> {
                                val payload = measurement?.let(::translated)
                                val content = payload?.getJSONObject("contentRect")
                                if (payload == null || content == null ||
                                    !coherence.contentMatches(codec(content) as Map<*, *>, measurement.x / measurement.density, measurement.y / measurement.density)) retry()
                                else if (restartAttempt != null && !finalProof) {
                                    // A cancellation/replacement between polls
                                    // cannot be hidden by an earlier receipt.
                                    entry.session.hostLayoutPreparationState(restartAttempt).whenComplete { latest, error ->
                                        if (!stopIfExpiredOrRetired()) {
                                            if (error != null) result.completeExceptionally(error)
                                            else try { assess(latest, true) } catch (failure: Throwable) { result.completeExceptionally(failure) }
                                        }
                                    }
                                } else result.complete(payload)
                            }
                            else -> retry()
                        }
                    }
                    entry.session.hostLayoutPreparationState(restartAttempt).whenComplete { snapshot, failure ->
                        if (!stopIfExpiredOrRetired()) {
                            if (failure != null) result.completeExceptionally(failure)
                            else try { assess(snapshot, false) } catch (error: Throwable) { result.completeExceptionally(error) }
                        }
                    }
                }
            } catch (error: Throwable) { result.completeExceptionally(error) }
        }
        // Bound even an outstanding read-only worker reply; retry callbacks
        // and individual state requests never create a fresh budget.
        val timeout = Runnable { stopIfExpiredOrRetired() }
        main.postDelayed(timeout, (deadline - SystemClock.uptimeMillis()).coerceAtLeast(0))
        result.whenComplete { _, _ -> main.removeCallbacks(timeout) }
        observe()
        return result
    }
    private fun cancelMeasurements(entry: Entry) {
        entry.measurementEpoch++
        entry.measurements.toList().forEach { it.completeExceptionally(ContainerException("ERR_CANCELLED", "Chrome owner retired before native measurement")) }
    }
    private fun retireView(entry: Entry): CompletableFuture<Unit> {
        cancelMeasurements(entry)
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
    private fun settle(future: CompletableFuture<*>, result: MethodChannel.Result, operation: String? = null, entry: Entry? = null, arguments: Map<*, *>? = null) {
        future.whenComplete { value, error -> if (error == null) result.success(if (value === Unit) null else codec(value)) else {
            if (entry?.diagnostics == true) logFailure(operation, entry, error, arguments)
            failure(result, error)
        } }
    }
    private fun logFailure(operation: String?, entry: Entry, raw: Throwable, arguments: Map<*, *>?) {
        var error = raw
        while ((error is CompletionException || error is ExecutionException) && error.cause != null) error = error.cause!!
        // Never log arbitrary native text, payloads, paths or credentials. The
        // reviewed reason and numeric layout observations locate startup faults.
        val code = (error as? ContainerException)?.code?.takeIf { it.matches(Regex("ERR_[A-Z_]{1,48}")) } ?: "ERR_ANDROID"
        val reason = LayoutFailureDiagnostic.reason(code, error.message)
        val op = LayoutFailureDiagnostic.operation(operation)
        val stamp = LayoutFailureDiagnostic.stamp(operation, arguments)
        val content = entry.clientChrome?.optJSONObject("contentRect")
        val view = entry.view
        Log.e("WeappContainer", "operation=$op code=$code reason=$reason$stamp clientWidth=${content?.optDouble("width")} clientHeight=${content?.optDouble("height")} physicalWidth=${view?.width} physicalHeight=${view?.height} density=${view?.resources?.displayMetrics?.density}")
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
