package dev.weapp.container.flutter

import java.math.BigInteger

/** Diagnostic output is an allowlist, never arbitrary exception or call text. */
internal object LayoutFailureDiagnostic {
    private val positiveDecimal = Regex("[1-9][0-9]{0,19}")
    private val maximum = BigInteger("18446744073709551615")
    private val operations = setOf("load", "applyDevPack", "prepareView", "hostChrome",
        "prepareHostChrome", "inspectPackChrome", "state", "capabilities", "hostLayout",
        "prepareHostLayout", "observeHostLayout")
    fun operation(value: String?): String = value?.takeIf { it in operations } ?: "other"
    private data class KnownFailure(val code: String, val message: String, val reason: String)
    private val failures = listOf(
        KnownFailure("ERR_INVALID_REQUEST", "initial host chrome dimensions differ from window metrics", "chrome-viewport-mismatch"),
        KnownFailure("ERR_INVALID_REQUEST", "invalid host chrome geometry", "invalid-chrome-geometry"),
        KnownFailure("ERR_INVALID_REQUEST", "host chrome geometry exceeds logical bounds", "chrome-bounds"),
        KnownFailure("ERR_INVALID_REQUEST", "content rectangle disagrees with native window metrics", "layout-content-metrics-mismatch"),
        KnownFailure("ERR_INVALID_REQUEST", "a navigation measurement must commit through completeNavigationLayout", "layout-navigation-measurement-required"),
        KnownFailure("ERR_CANCELLED", "no pending native layout observation", "layout-no-pending-observation"),
        KnownFailure("ERR_CANCELLED", "layout does not match the exact native observation and page owner", "layout-observation-superseded"),
        KnownFailure("ERR_CANCELLED", "host layout surface owner changed", "layout-surface-owner-changed"),
        KnownFailure("ERR_CANCELLED", "stale complete host layout revision", "layout-stale-revision"),
        KnownFailure("ERR_TIMEOUT", "native layout measurement expired; observe and measure again", "layout-measurement-expired"),
        KnownFailure("ERR_CANCELLED", "Chrome owner retired before native measurement", "layout-native-owner-retired"),
    )
    // The immutable FFI uses SdkError's "{code}: {message}" Display; local
    // wrapper errors use the bare message. Accept only these two exact forms
    // for a reviewed (code, message) pair. Never strip arbitrary prefixes or
    // expose an unknown message in diagnostics. Classification is not recovery.
    fun reason(code: String?, message: String?): String = failures.firstOrNull {
        it.code == code && (message == it.message || message == "${it.code}: ${it.message}")
    }?.reason ?: "native-operation"
    private fun decimal(value: Any?): String? {
        val text = value as? String ?: return null
        return text.takeIf { positiveDecimal.matches(it) && BigInteger(it) <= maximum }
    }
    private fun boundedNumber(value: Any?): String? {
        val number = (value as? Number)?.toDouble() ?: return null
        return number.takeIf { it.isFinite() && it >= -16384 && it <= 16384 }?.toString()
    }
    fun stamp(method: String?, arguments: Map<*, *>?): String {
        if (method !in setOf("hostLayout", "prepareHostLayout")) return ""
        val observation = arguments?.get("observation") as? Map<*, *> ?: return ""
        val fields = listOf("ownerId", "surfaceGeneration", "observationId").mapNotNull { name ->
            decimal(observation[name])?.let { "$name=$it" }
        }.toMutableList()
        decimal(arguments["layoutRevision"])?.let { fields.add("layoutRevision=$it") }
        val metrics = observation["windowMetrics"] as? Map<*, *>
        for ((field, label) in listOf("windowWidth" to "requestedWindowWidth", "windowHeight" to "requestedWindowHeight", "screenTop" to "requestedScreenTop", "pixelRatio" to "requestedPixelRatio")) {
            boundedNumber(metrics?.get(field))?.let { fields.add("$label=$it") }
        }
        val content = (arguments["chrome"] as? Map<*, *>)?.get("contentRect") as? Map<*, *>
        for ((field, label) in listOf("width" to "requestedChromeWidth", "height" to "requestedChromeHeight")) {
            boundedNumber(content?.get(field))?.let { fields.add("$label=$it") }
        }
        return fields.joinToString(" ", prefix = if (fields.isEmpty()) "" else " ")
    }
}
