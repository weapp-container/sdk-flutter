package dev.weapp.container.flutter

import org.junit.Assert.*
import org.junit.Test

class HostLayoutCoherenceTest {
    private fun metrics() = mutableMapOf<String, Any?>("windowWidth" to 390, "windowHeight" to 700,
        "pixelRatio" to 2.75, "screenWidth" to 390, "screenHeight" to 850, "statusBarHeight" to 24.0,
        "screenTop" to 68.0, "deviceOrientation" to "portrait")
    private fun observation(sequence: String = "10", surface: String = "5", owner: String = "7", empty: Boolean = false) = mutableMapOf<String, Any?>(
        "schemaVersion" to 1, "ownerId" to owner, "surfaceGeneration" to surface,
        "observationId" to sequence, "windowMetrics" to metrics(),
        "sessionId" to if (empty) null else "session", "pageId" to if (empty) null else 2)
    private fun state(pending: Map<*, *>? = observation(), accepted: Map<*, *>? = null, empty: Boolean = false) = mutableMapOf<String, Any?>(
        "schemaVersion" to 1, "status" to if (empty) "empty" else "ready", "ownerId" to "7",
        "sessionId" to if (empty) null else "session", "page" to if (empty) null else mapOf("id" to 2),
        "acceptedPackIdentity" to if (empty) null else mapOf("root" to "accepted-pack"),
        "hostSurface" to mapOf("ownerId" to "7", "surfaceGeneration" to "5"),
        "executionHealth" to if (empty) null else mapOf("schemaVersion" to 1, "requiresRestart" to false,
            "appServiceFault" to null, "viewFault" to null, "navigationFault" to null),
        "pendingHostLayout" to pending, "acceptedLayout" to accepted, "pendingNavigation" to null)
    private fun gate(observation: Map<*, *> = observation(), prepare: Boolean = false) = HostLayoutCoherence(observation, "17", 100, prepareOnly = prepare)
    @Test fun coherentCurrentObservationIsReadyForUpdateAndPreparation() {
        for (prepare in listOf(false, true)) assertEquals(HostLayoutCoherence.Decision.READY, gate(prepare = prepare).decide(101, metrics(), state()))
    }
    @Test fun oldObservationAndNewViewNeverProduceAMixedLayout() {
        val measured = metrics().apply { put("windowWidth", 700); put("windowHeight", 390); put("deviceOrientation", "landscape") }
        val original = observation(); val current = state(original)
        for (prepare in listOf(false, true)) {
            val request = gate(original, prepare)
            assertEquals(HostLayoutCoherence.Decision.WAIT, request.decide(200, measured, current))
            assertEquals(HostLayoutCoherence.Decision.SUPERSEDED, request.decide(201, measured, state(observation("11"))))
        }
        assertEquals(390, (original["windowMetrics"] as Map<*, *>)["windowWidth"])
    }
    @Test fun sameViewportNewObservationStillSupersedesOldDisplaySnapshot() {
        for (field in listOf("pixelRatio", "screenTop", "statusBarHeight", "screenHeight", "deviceOrientation")) {
            val next = observation("11")
            @Suppress("UNCHECKED_CAST") val display = next["windowMetrics"] as MutableMap<String, Any?>
            display[field] = when (field) { "deviceOrientation" -> "landscape"; else -> 99.0 }
            assertEquals(HostLayoutCoherence.Decision.SUPERSEDED, gate().decide(200, metrics(), state(next)))
        }
    }
    @Test fun sameObservationRequiresEveryNativeDisplayField() {
        for (field in metrics().keys) {
            val current = metrics()
            current[field] = if (field == "deviceOrientation") "landscape" else (current[field] as Number).toDouble() + 1
            assertEquals(field, HostLayoutCoherence.Decision.WAIT, gate().decide(200, current, state()))
        }
        val unknownSafeArea = metrics().apply { put("safeArea", mapOf("top" to 12)) }
        val submitted = observation().apply { put("windowMetrics", unknownSafeArea) }
        assertEquals(HostLayoutCoherence.Decision.WAIT, gate(submitted).decide(200, metrics(), state(submitted)))
    }
    @Test fun healthyWithoutNewTupleIsNotCancellationProof() {
        assertEquals(HostLayoutCoherence.Decision.WAIT, gate().decide(200, metrics(), state(pending = null)))
        assertEquals(HostLayoutCoherence.Decision.WAIT, gate().decide(200, null, state()))
        assertEquals(HostLayoutCoherence.Decision.WAIT, gate().decide(200, metrics(), state(observation("9"))))
    }
    @Test fun faultedOrWrongOwnerStatesCannotProveSupersession() {
        for (domain in listOf("appServiceFault", "viewFault", "navigationFault", "requiresRestart")) {
            val current = state(observation("11"))
            @Suppress("UNCHECKED_CAST") val health = (current["executionHealth"] as Map<String, Any?>).toMutableMap()
            health[domain] = if (domain == "requiresRestart") true else mapOf("code" to "ERR_TIMEOUT")
            current["executionHealth"] = health
            assertEquals(domain, HostLayoutCoherence.Decision.WAIT, gate().decide(200, metrics(), current))
        }
        for (owner in listOf("8", "07", "18446744073709551616")) {
            val current = state(observation("11", owner = owner)).apply { put("ownerId", owner); put("hostSurface", mapOf("ownerId" to owner, "surfaceGeneration" to "5")) }
            assertEquals(HostLayoutCoherence.Decision.WAIT, gate().decide(200, metrics(), current))
        }
        for (status in listOf("closing", "closed", "unknown", null)) {
            val current = state(observation("11")).apply { if (status == null) remove("status") else put("status", status) }
            assertEquals(HostLayoutCoherence.Decision.WAIT, gate().decide(200, metrics(), current))
        }
    }
    @Test fun exactAbsoluteDeadlineNeverExtendsAcrossRetriesOrNewObservations() {
        val request = gate()
        assertEquals(10_100, request.deadlineMillis.toInt())
        for (time in listOf(100L, 1_000L, 10_099L)) {
            assertEquals(HostLayoutCoherence.Decision.WAIT, request.decide(time, null, state()))
            assertEquals(10_100, request.deadlineMillis.toInt())
        }
        assertEquals(HostLayoutCoherence.Decision.EXPIRED, request.decide(10_100, metrics(), state()))
        assertEquals(HostLayoutCoherence.Decision.EXPIRED, request.decide(10_101, metrics(), state(observation("11"))))
    }
    @Test fun closeDetachAndReloadRetirementCancelBeforeDeadline() {
        for (prepare in listOf(false, true)) {
            val request = gate(prepare = prepare)
            assertEquals(HostLayoutCoherence.Decision.WAIT, request.decide(101, null, state()))
            assertEquals(HostLayoutCoherence.Decision.RETIRED, request.decide(102, null, null, retired = true))
            assertEquals(HostLayoutCoherence.Decision.RETIRED, request.decide(102, metrics(), state(), retired = true))
        }
    }
    @Test fun prepareMayMeasureNavigationWhileGenericUpdateCannotCommitIt() {
        val navigating = state().apply { put("pendingNavigation", mapOf("ticket" to "original-ticket", "deadlineNs" to "original-deadline")) }
        val before = navigating.toString()
        assertEquals(HostLayoutCoherence.Decision.WAIT, gate().decide(200, metrics(), navigating))
        assertEquals(HostLayoutCoherence.Decision.READY, gate(prepare = true).decide(200, metrics(), navigating))
        assertEquals(before, navigating.toString())
    }
    @Test fun exactEmptyStartupIsMeasurableAndNewEmptyObservationSupersedesPreparation() {
        val original = observation(empty = true)
        val request = gate(original, true)
        assertEquals(HostLayoutCoherence.Decision.READY, request.decide(101, metrics(), state(original, empty = true)))
        val next = observation("11", empty = true)
        assertEquals(HostLayoutCoherence.Decision.SUPERSEDED, request.decide(102, metrics(), state(next, empty = true)))
        assertEquals(HostLayoutCoherence.Decision.WAIT, request.decide(102, metrics(), state(pending = null, empty = true)))
        // Actual serde skip_serializing_if wire omits both absent Option fields.
        original.remove("sessionId"); original.remove("pageId")
        next.remove("sessionId"); next.remove("pageId")
        val wireRequest = gate(original, true)
        assertEquals(HostLayoutCoherence.Decision.READY, wireRequest.decide(101, metrics(), state(original, empty = true)))
        assertEquals(HostLayoutCoherence.Decision.SUPERSEDED, wireRequest.decide(102, metrics(), state(next, empty = true)))
    }
    @Test fun missingHealthInActiveOrAmbiguousEmptyOwnerDoesNotBecomeProof() {
        val original = observation(empty = true); val request = gate(original, true)
        val baseline = state(observation("11", empty = true), empty = true)
        for (field in listOf("executionHealth", "sessionId", "page", "acceptedPackIdentity", "acceptedLayout")) {
            val missing = baseline.toMutableMap().apply { remove(field) }
            assertEquals(field, HostLayoutCoherence.Decision.WAIT, request.decide(200, metrics(), missing))
            val present = baseline.toMutableMap().apply { put(field, mapOf("unexpected" to true)) }
            assertEquals(field, HostLayoutCoherence.Decision.WAIT, request.decide(200, metrics(), present))
        }
        val active = state(observation("11")).apply { put("executionHealth", null) }
        assertEquals(HostLayoutCoherence.Decision.WAIT, gate().decide(200, metrics(), active))
        assertEquals(HostLayoutCoherence.Decision.WAIT, request.decide(200, metrics(), state(observation("11"), empty = true)))
        val contradictory = baseline.toMutableMap().apply { put("executionHealth", state()["executionHealth"]) }
        assertEquals(HostLayoutCoherence.Decision.WAIT, request.decide(200, metrics(), contradictory))
    }
    @Test fun acceptedObservationOnlyAllowsExactRevisionAndOwner() {
        val accepted = observation().apply { put("layoutRevision", "17"); put("chrome", mapOf("sessionId" to "session", "pageId" to 2)) }
        assertEquals(HostLayoutCoherence.Decision.READY, gate().decide(200, metrics(), state(null, accepted)))
        accepted["layoutRevision"] = "18"
        assertEquals(HostLayoutCoherence.Decision.SUPERSEDED, gate().decide(200, metrics(), state(null, accepted)))
        accepted["layoutRevision"] = "16"
        assertEquals(HostLayoutCoherence.Decision.WAIT, gate().decide(200, metrics(), state(null, accepted)))
    }
    @Test fun outgoingContentIncludesTheActualHorizontalAndVerticalOrigin() {
        val request = gate()
        val content = mutableMapOf<String, Any?>("width" to 390.0, "height" to 700.0, "left" to 8.0, "top" to 68.0)
        assertTrue(request.contentMatches(content, 8.0, 68.0))
        assertFalse(request.contentMatches(content, 9.0, 68.0))
        assertFalse(request.contentMatches(content, 8.0, 69.0))
        content["width"] = 390.5
        assertTrue(request.contentMatches(content, 8.0, 68.0))
        content["width"] = 390.50001
        assertFalse(request.contentMatches(content, 8.0, 68.0))
        content["width"] = Double.NaN
        assertFalse(request.contentMatches(content, 8.0, 68.0))
    }
    @Test fun submittedMapsAreCapturedBeforeAsynchronousMeasurement() {
        val original = observation(); val expected = observation(); val request = gate(original)
        original["observationId"] = "11"
        @Suppress("UNCHECKED_CAST") val nested = original["windowMetrics"] as MutableMap<String, Any?>
        nested["screenTop"] = 99.0
        assertEquals(HostLayoutCoherence.Decision.READY, request.decide(200, metrics(), state(expected)))
    }
    @Test fun malformedOrNonCanonicalTuplesNeverBecomeReadyOrSuperseded() {
        for (field in listOf("ownerId", "surfaceGeneration", "observationId")) for (bad in listOf("01", "18446744073709551616", 11, null)) {
            val original = observation().apply { put(field, bad) }
            assertEquals(HostLayoutCoherence.Decision.WAIT, gate(original).decide(200, metrics(), state(observation("11"))))
        }
        val badMetrics = observation().apply { put("windowMetrics", mapOf("windowWidth" to 390, "windowHeight" to 700)) }
        assertEquals(HostLayoutCoherence.Decision.WAIT, gate(badMetrics).decide(200, metrics(), state(observation("11"))))
    }
}
