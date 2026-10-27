package dev.weapp.container.flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
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
    private class Entry(val session: WeappContainerSession) {
        var view: WeappContainerView? = null
        var closing: CompletableFuture<Unit>? = null
        var retiringView: CompletableFuture<Unit>? = null
        val replies = mutableMapOf<String, HostReply>()
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
                val entry = Entry(WeappContainerSession(app, key))
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
                "load" -> session.load(PackSource.Directory(File(args["packPath"] as String)), LoadOptions(args["route"] as? String, jsonObject(args["options"])))
                "navigate" -> session.navigate(args["route"] as String, jsonObject(args["query"]), args["replace"] as? Boolean ?: false)
                "back" -> session.back()
                "sendMessage" -> session.sendMessage(json(args["message"]))
                "setForeground" -> session.setForeground(args["foreground"] as Boolean)
                "flushStorage" -> session.flushStorage()
                "state" -> session.state()
                "capabilities" -> session.capabilities()
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
            settle(operation, result)
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
    private fun settle(future: CompletableFuture<*>, result: MethodChannel.Result) {
        future.whenComplete { value, error -> if (error == null) result.success(if (value === Unit) null else codec(value)) else failure(result, error) }
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
