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
    fun reason(message: String?): String = when (message) {
        "initial host chrome dimensions differ from window metrics" -> "chrome-viewport-mismatch"
        "invalid host chrome geometry" -> "invalid-chrome-geometry"
        "host chrome geometry exceeds logical bounds" -> "chrome-bounds"
        "no pending native layout observation" -> "layout-no-pending-observation"
        "layout does not match the exact native observation and page owner" -> "layout-observation-superseded"
        "host layout surface owner changed" -> "layout-surface-owner-changed"
        "stale complete host layout revision" -> "layout-stale-revision"
        "native layout measurement expired; observe and measure again" -> "layout-measurement-expired"
        "Chrome owner retired before native measurement" -> "layout-native-owner-retired"
        else -> "native-operation"
    }
    private fun decimal(value: Any?): String? {
        val text = value as? String ?: return null
        return text.takeIf { positiveDecimal.matches(it) && BigInteger(it) <= maximum }
    }
    fun stamp(method: String?, arguments: Map<*, *>?): String {
        if (method !in setOf("hostLayout", "prepareHostLayout")) return ""
        val observation = arguments?.get("observation") as? Map<*, *> ?: return ""
        val fields = listOf("ownerId", "surfaceGeneration", "observationId").mapNotNull { name ->
            decimal(observation[name])?.let { "$name=$it" }
        }.toMutableList()
        decimal(arguments["layoutRevision"])?.let { fields.add("layoutRevision=$it") }
        return fields.joinToString(" ", prefix = if (fields.isEmpty()) "" else " ")
    }
}
