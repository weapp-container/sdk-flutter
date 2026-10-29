package dev.weapp.container.flutter

import java.math.BigInteger
import kotlin.math.abs

/** One immutable measurement request and one absolute deadline, shared by
 * hostLayout and prepareHostLayout. No observation or runtime mutation occurs
 * here. A healthy frame without the submitted observation is never sufficient. */
internal class HostLayoutCoherence(
    observation: Map<*, *>,
    private val revision: String,
    startedAtMillis: Long,
    timeoutMillis: Long = 10_000,
    private val prepareOnly: Boolean = false,
) {
    enum class Decision { READY, WAIT, SUPERSEDED, EXPIRED, RETIRED }
    private val submitted = copy(observation) as Map<*, *>
    val deadlineMillis: Long
    init {
        require(startedAtMillis >= 0 && timeoutMillis > 0)
        deadlineMillis = if (startedAtMillis > Long.MAX_VALUE - timeoutMillis) Long.MAX_VALUE else startedAtMillis + timeoutMillis
    }
    fun decide(nowMillis: Long, measuredMetrics: Map<*, *>?, state: Map<*, *>?, retired: Boolean = false): Decision {
        if (retired) return Decision.RETIRED
        if (nowMillis >= deadlineMillis) return Decision.EXPIRED
        if (state == null || !validState(state)) return Decision.WAIT
        if ((healthy(state) || emptyPending(state)) && superseded(state)) return Decision.SUPERSEDED
        if (!healthy(state) && !emptyBeforeGuest(state)) return Decision.WAIT
        if (!currentObservation(state)) return Decision.WAIT
        if (!prepareOnly && state["pendingNavigation"] != null) return Decision.WAIT
        val expected = submitted["windowMetrics"] as? Map<*, *> ?: return Decision.WAIT
        if (measuredMetrics == null || !metricsEqual(expected, measuredMetrics)) return Decision.WAIT
        return Decision.READY
    }
    /** The actual outgoing chrome, rather than a second independent viewport,
     * must agree with this frozen observation and the same native origin. */
    fun contentMatches(content: Map<*, *>, originX: Double, originY: Double): Boolean {
        val expected = submitted["windowMetrics"] as? Map<*, *> ?: return false
        fun matches(field: String, value: Double, tolerance: Double): Boolean {
            val actual = (content[field] as? Number)?.toDouble() ?: return false
            return actual.isFinite() && value.isFinite() && abs(actual - value) <= tolerance
        }
        val width = (expected["windowWidth"] as? Number)?.toDouble() ?: return false
        val height = (expected["windowHeight"] as? Number)?.toDouble() ?: return false
        return matches("width", width, 0.5) && matches("height", height, 0.5) &&
            matches("left", originX, 1e-6) && matches("top", originY, 1e-6)
    }
    private fun validState(state: Map<*, *>): Boolean {
        val surface = state["hostSurface"] as? Map<*, *> ?: return false
        val metrics = submitted["windowMetrics"] as? Map<*, *> ?: return false
        return submitted["schemaVersion"] == 1 && state["schemaVersion"] == 1 &&
            decimal(submitted["ownerId"]) != null && decimal(submitted["surfaceGeneration"]) != null &&
            decimal(submitted["observationId"]) != null && decimal(revision) != null &&
            state["ownerId"] == submitted["ownerId"] && surface["ownerId"] == submitted["ownerId"] &&
            decimal(surface["surfaceGeneration"]) != null && validMetrics(metrics)
    }
    private fun healthy(state: Map<*, *>): Boolean {
        if (state["status"] != "ready") return false
        val health = state["executionHealth"] as? Map<*, *> ?: return false
        return health["schemaVersion"] == 1 && health["requiresRestart"] == false &&
            health["appServiceFault"] == null && health["viewFault"] == null && health["navigationFault"] == null
    }
    private fun emptyBeforeGuest(state: Map<*, *>): Boolean = state["status"] == "empty" &&
        listOf("executionHealth", "sessionId", "page", "acceptedPackIdentity", "acceptedLayout").all { state.containsKey(it) && state[it] == null } &&
        // HostLayoutObservation's Option fields are omitted by the Rust wire
        // serializer before a guest exists; explicit JSON null is equivalent.
        listOf("sessionId", "pageId").all { submitted[it] == null }
    private fun emptyPending(state: Map<*, *>): Boolean {
        if (!emptyBeforeGuest(state)) return false
        val pending = state["pendingHostLayout"] as? Map<*, *> ?: return false
        val metrics = pending["windowMetrics"] as? Map<*, *> ?: return false
        return listOf("sessionId", "pageId").all { pending[it] == null } && validMetrics(metrics)
    }
    private fun currentObservation(state: Map<*, *>): Boolean {
        val surface = state["hostSurface"] as Map<*, *>
        if (surface["surfaceGeneration"] != submitted["surfaceGeneration"]) return false
        val pending = state["pendingHostLayout"]
        if (pending != null) return sameObservation(pending as? Map<*, *> ?: return false, false)
        val accepted = state["acceptedLayout"] as? Map<*, *> ?: return false
        return accepted["layoutRevision"] == revision && sameObservation(accepted, true)
    }
    private fun sameObservation(value: Map<*, *>, accepted: Boolean): Boolean {
        for (field in listOf("schemaVersion", "ownerId", "surfaceGeneration", "observationId")) {
            if (value[field] != submitted[field]) return false
        }
        if (!equal(value["windowMetrics"], submitted["windowMetrics"])) return false
        val page = if (accepted) value["chrome"] as? Map<*, *> ?: return false else value
        return page["sessionId"] == submitted["sessionId"] && equal(page["pageId"], submitted["pageId"])
    }
    private fun superseded(state: Map<*, *>): Boolean {
        val surface = state["hostSurface"] as Map<*, *>
        val active = decimal(surface["surfaceGeneration"]) ?: return false
        val oldSurface = decimal(submitted["surfaceGeneration"]) ?: return false
        if (active < oldSurface) return false
        val oldSequence = decimal(submitted["observationId"]) ?: return false
        val attemptedRevision = decimal(revision) ?: return false
        fun newer(raw: Any?, accepted: Boolean): Boolean {
            val value = raw as? Map<*, *> ?: return false
            if (value["schemaVersion"] != 1 || value["ownerId"] != submitted["ownerId"] ||
                value["surfaceGeneration"] != surface["surfaceGeneration"]) return false
            val next = decimal(value["observationId"]) ?: return false
            val nextRevision = if (accepted) decimal(value["layoutRevision"]) ?: return false else null
            if (next > oldSequence) return true
            return accepted && next == oldSequence && active == oldSurface && nextRevision!! > attemptedRevision
        }
        return newer(state["pendingHostLayout"], false) || newer(state["acceptedLayout"], true)
    }
    companion object {
        private val canonical = Regex("[1-9][0-9]{0,19}")
        private val maximum = BigInteger("18446744073709551615")
        private val metricFields = setOf("windowWidth", "windowHeight", "pixelRatio", "screenWidth", "screenHeight", "statusBarHeight", "screenTop", "deviceOrientation")
        private fun decimal(value: Any?): BigInteger? {
            val text = value as? String ?: return null
            if (!canonical.matches(text)) return null
            return BigInteger(text).takeIf { it <= maximum }
        }
        private fun copy(value: Any?): Any? = when (value) {
            is Map<*, *> -> value.entries.associate { it.key to copy(it.value) }
            is List<*> -> value.map(::copy)
            else -> value
        }
        private fun equal(left: Any?, right: Any?): Boolean {
            if (left is Number && right is Number) return left.toDouble().isFinite() && right.toDouble().isFinite() && left.toDouble() == right.toDouble()
            if (left is Map<*, *> && right is Map<*, *>) return left.keys == right.keys && left.keys.all { equal(left[it], right[it]) }
            if (left is List<*> && right is List<*>) return left.size == right.size && left.indices.all { equal(left[it], right[it]) }
            return left == right
        }
        private fun metricsEqual(expected: Map<*, *>, measured: Map<*, *>): Boolean {
            if (!validMetrics(expected) || !validMetrics(measured)) return false
            if (!metricFields.all { expected.containsKey(it) && measured.containsKey(it) }) return false
            if (!expected.keys.all { it in metricFields || it == "safeArea" }) return false
            for (field in metricFields) {
                val a = expected[field]; val b = measured[field]
                if (a is Number && b is Number) {
                    if (!a.toDouble().isFinite() || !b.toDouble().isFinite() || abs(a.toDouble() - b.toDouble()) > 1e-6) return false
                } else if (a != b) return false
            }
            // Android's native WindowMetrics deliberately omits safeArea. A
            // future producer adding it must also supply an independent native
            // measurement; do not silently drop a supplied rectangle.
            return expected["safeArea"] == null || equal(expected["safeArea"], measured["safeArea"])
        }
        private fun validMetrics(value: Map<*, *>): Boolean {
            if (!metricFields.all { value.containsKey(it) }) return false
            for (field in metricFields - "deviceOrientation") {
                val number = (value[field] as? Number)?.toDouble() ?: return false
                if (!number.isFinite()) return false
                if (field in setOf("windowWidth", "windowHeight", "screenWidth", "screenHeight") &&
                    (number <= 0 || number > 16384 || number % 1 != 0.0)) return false
                if (field == "pixelRatio" && number <= 0 || field == "statusBarHeight" && number < 0) return false
            }
            return value["deviceOrientation"] == "portrait" || value["deviceOrientation"] == "landscape"
        }
    }
}
