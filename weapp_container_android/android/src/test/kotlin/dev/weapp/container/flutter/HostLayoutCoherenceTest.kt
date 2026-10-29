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
    private fun acceptedIdentity() = mutableMapOf<String, Any?>("root" to "a".repeat(64), "acceptedPackRevision" to "3", "sessionId" to "session")
    private fun restartProof() = mutableMapOf<String, Any?>("schemaVersion" to 1, "ownerId" to "7", "attemptId" to "12", "targetRoot" to "b".repeat(64), "expectedAccepted" to acceptedIdentity())
    private fun receipt() = restartProof().apply { put("status", "prepared"); put("operation", "load"); put("reloadKind", "restart"); put("acceptedPackIdentity", acceptedIdentity()) }
    private fun viewFaultState() = state().apply {
        put("acceptedPackIdentity", acceptedIdentity()); put("inputEnabled", false); put("presentationEnabled", false)
        put("executionHealth", mapOf("schemaVersion" to 1, "requiresRestart" to true, "appServiceFault" to null,
            "viewFault" to mapOf("domain" to "view", "code" to "ERR_TIMEOUT", "message" to "View execution timed out", "requiresRestart" to true), "navigationFault" to null))
    }
    @Test fun preparedRestartCanMeasureAnExactFaultedViewWithoutGrantingPresentation() {
        val current = viewFaultState(); val before = current.toString()
        val request = HostLayoutCoherence(observation(), "17", 100, prepareOnly = true, restartAttempt = restartProof())
        assertEquals(HostLayoutCoherence.Decision.READY, request.decide(101, metrics(), current, journalReceipt = receipt()))
        assertEquals(before, current.toString())
        assertEquals(false, current["inputEnabled"]); assertEquals(false, current["presentationEnabled"])
    }

    private fun recoveryGate(proof: Map<*, *> = restartProof(), prepare: Boolean = true) =
        HostLayoutCoherence(observation(), "17", 100, prepareOnly = prepare, restartAttempt = proof)
    private fun faultHealth(change: MutableMap<String, Any?>.() -> Unit): MutableMap<String, Any?> =
        viewFaultState().apply {
            @Suppress("UNCHECKED_CAST")
            val health = (get("executionHealth") as Map<String, Any?>).toMutableMap()
            health.change(); put("executionHealth", health)
        }
    @Test fun recoveryIsPrepareOnlyAndRequiresAnExplicitExactJournalProof() {
        val current = viewFaultState()
        assertEquals(HostLayoutCoherence.Decision.WAIT, gate(prepare = true).decide(101, metrics(), current))
        assertEquals(HostLayoutCoherence.Decision.CANCELLED, recoveryGate(prepare = false).decide(101, metrics(), current, journalReceipt = receipt()))
        val healthy = state().apply { put("acceptedPackIdentity", acceptedIdentity()) }
        assertEquals(HostLayoutCoherence.Decision.CANCELLED, recoveryGate(prepare = false).decide(101, metrics(), healthy, journalReceipt = receipt()))
        assertEquals(HostLayoutCoherence.Decision.WAIT, recoveryGate().decide(101, metrics(), current))
        assertEquals(HostLayoutCoherence.Decision.CANCELLED, recoveryGate().decide(101, metrics(), current, journalReceipt = emptyMap<Any, Any>()))
        assertEquals(HostLayoutCoherence.Decision.READY, recoveryGate().decide(101, metrics(), current, journalReceipt = receipt().apply { put("operation", "applyDevPack") }))
    }
    @Test fun restartProofHasAClosedCanonicalWireShape() {
        assertTrue(HostLayoutCoherence.validRestartProof(restartProof()))
        assertTrue(HostLayoutCoherence.validRestartProof(restartProof().apply { put("expectedAccepted", null) }))
        for (field in restartProof().keys) {
            assertFalse("missing $field", HostLayoutCoherence.validRestartProof(restartProof().apply { remove(field) }))
        }
        assertFalse(HostLayoutCoherence.validRestartProof(restartProof().apply { put("extra", true) }))
        for (field in listOf("ownerId", "attemptId")) for (bad in listOf(null, 7, "0", "07", "+7", "7 ", "18446744073709551616")) {
            assertFalse("$field=$bad", HostLayoutCoherence.validRestartProof(restartProof().apply { put(field, bad) }))
        }
        for (bad in listOf(null, "", "B".repeat(64), "g".repeat(64), "b".repeat(63), 12)) {
            assertFalse("targetRoot=$bad", HostLayoutCoherence.validRestartProof(restartProof().apply { put("targetRoot", bad) }))
        }
        for (bad in listOf(null, 2, "1", true)) assertFalse(HostLayoutCoherence.validRestartProof(restartProof().apply { put("schemaVersion", bad) }))
        val badAccepted = listOf<Any>(true, "accepted", emptyMap<String, Any?>(), acceptedIdentity().apply { put("extra", 1) },
            acceptedIdentity().apply { remove("root") }, acceptedIdentity().apply { put("root", "A".repeat(64)) },
            acceptedIdentity().apply { put("acceptedPackRevision", "03") }, acceptedIdentity().apply { put("acceptedPackRevision", "18446744073709551616") },
            acceptedIdentity().apply { put("sessionId", "  ") }, acceptedIdentity().apply { put("sessionId", 7) })
        for (bad in badAccepted) assertFalse("expectedAccepted=$bad", HostLayoutCoherence.validRestartProof(restartProof().apply { put("expectedAccepted", bad) }))
        val maximum = restartProof().apply { put("ownerId", "18446744073709551615"); put("attemptId", "18446744073709551615") }
        assertTrue(HostLayoutCoherence.validRestartProof(maximum))
    }
    @Test fun journalMustStillBePreparedRestartForTheExactAcceptedIdentity() {
        val current = viewFaultState()
        for (field in receipt().keys) {
            assertEquals("missing $field", HostLayoutCoherence.Decision.CANCELLED, recoveryGate().decide(101, metrics(), current,
                journalReceipt = receipt().apply { remove(field) }))
        }
        val invalid = listOf(
            "schemaVersion" to 2, "status" to "notSeen", "status" to "notRetained", "status" to "applying", "status" to "accepted",
            "status" to "rejected", "status" to "cancelled", "reloadKind" to "inPlace", "operation" to "queryDevPackAttempt",
            "ownerId" to "8", "attemptId" to "13", "targetRoot" to "c".repeat(64),
            "expectedAccepted" to acceptedIdentity().apply { put("acceptedPackRevision", "4") },
            "acceptedPackIdentity" to acceptedIdentity().apply { put("root", "c".repeat(64)) })
        for ((field, bad) in invalid) assertEquals("$field=$bad", HostLayoutCoherence.Decision.CANCELLED,
            recoveryGate().decide(101, metrics(), current, journalReceipt = receipt().apply { put(field, bad) }))
        for (field in listOf("root", "acceptedPackRevision", "sessionId")) {
            val changed = acceptedIdentity().apply { put(field, if (field == "root") "c".repeat(64) else "changed") }
            assertEquals("state accepted $field", HostLayoutCoherence.Decision.CANCELLED,
                recoveryGate().decide(101, metrics(), viewFaultState().apply { put("acceptedPackIdentity", changed) }, journalReceipt = receipt()))
        }
        for (field in listOf("acceptedPackIdentity", "sessionId", "page")) {
            assertEquals("state missing $field", HostLayoutCoherence.Decision.CANCELLED,
                recoveryGate().decide(101, metrics(), viewFaultState().apply { remove(field) }, journalReceipt = receipt()))
        }
        assertEquals(HostLayoutCoherence.Decision.CANCELLED,
            recoveryGate().decide(101, metrics(), viewFaultState().apply { put("sessionId", "new-session") }, journalReceipt = receipt()))
        assertEquals(HostLayoutCoherence.Decision.CANCELLED,
            recoveryGate().decide(101, metrics(), viewFaultState().apply { put("page", mapOf("id" to 3)) }, journalReceipt = receipt()))
    }
    @Test fun onlyAnExplicitTypedViewFaultCanUseRestartMeasurement() {
        val excluded = listOf(
            faultHealth { put("appServiceFault", mapOf("code" to "ERR_TIMEOUT")) },
            faultHealth { put("navigationFault", mapOf("code" to "ERR_TIMEOUT")) },
            faultHealth { remove("appServiceFault") }, faultHealth { remove("navigationFault") },
            faultHealth { put("schemaVersion", 2) }, faultHealth { put("requiresRestart", false) },
            faultHealth { remove("requiresRestart") }, faultHealth { put("viewFault", null) })
        for ((index, bad) in excluded.withIndex()) assertEquals("health $index", HostLayoutCoherence.Decision.WAIT,
            recoveryGate().decide(101, metrics(), bad, journalReceipt = receipt()))
        for ((field, values) in mapOf("domain" to listOf(null, "appService", "navigation", "View"),
            "requiresRestart" to listOf(null, false, "true"), "code" to listOf(null, "ERR_", "err_timeout", "ERR_TIMEOUT!", 1),
            "message" to listOf(null, "", "  ", 7))) {
            for (bad in values) {
                val current = faultHealth {
                    put("viewFault", mutableMapOf<String, Any?>("domain" to "view", "code" to "ERR_TIMEOUT", "message" to "View execution timed out", "requiresRestart" to true).apply { put(field, bad) })
                }
                assertEquals("fault $field=$bad", HostLayoutCoherence.Decision.WAIT, recoveryGate().decide(101, metrics(), current, journalReceipt = receipt()))
            }
        }
        for (field in listOf("inputEnabled", "presentationEnabled", "pendingNavigation")) {
            val missing = viewFaultState().apply { remove(field) }
            assertEquals("missing $field", HostLayoutCoherence.Decision.WAIT, recoveryGate().decide(101, metrics(), missing, journalReceipt = receipt()))
            val active = viewFaultState().apply { put(field, if (field == "pendingNavigation") mapOf("ticket" to "pending") else true) }
            assertEquals("active $field", HostLayoutCoherence.Decision.WAIT, recoveryGate().decide(101, metrics(), active, journalReceipt = receipt()))
        }
        val nullProof = restartProof().apply { put("expectedAccepted", null) }
        val nullReceipt = receipt().apply { put("expectedAccepted", null); put("acceptedPackIdentity", null) }
        assertEquals(HostLayoutCoherence.Decision.CANCELLED, recoveryGate(nullProof).decide(101, metrics(), viewFaultState().apply { put("acceptedPackIdentity", null) }, journalReceipt = nullReceipt))
        for (status in listOf("empty", "closing", "closed", "unknown", null)) assertEquals("status=$status", HostLayoutCoherence.Decision.WAIT,
            recoveryGate().decide(101, metrics(), viewFaultState().apply { put("status", status) }, journalReceipt = receipt()))
    }
    @Test fun exactNativeTupleAndGeometryRemainMandatoryDuringViewRecovery() {
        val request = recoveryGate()
        for ((field, bad) in listOf("ownerId" to "8", "surfaceGeneration" to "4", "observationId" to "9", "sessionId" to "old", "pageId" to 3)) {
            val current = viewFaultState().apply { put("pendingHostLayout", observation().apply { put(field, bad) }) }
            assertEquals(field, HostLayoutCoherence.Decision.WAIT, request.decide(101, metrics(), current, journalReceipt = receipt()))
        }
        assertEquals(HostLayoutCoherence.Decision.WAIT, request.decide(101, metrics(), viewFaultState().apply {
            put("hostSurface", mapOf("ownerId" to "7", "surfaceGeneration" to "6"))
        }, journalReceipt = receipt()))
        assertEquals(HostLayoutCoherence.Decision.WAIT, request.decide(101, metrics().apply { put("screenTop", 69.0) }, viewFaultState(), journalReceipt = receipt()))
        assertEquals(HostLayoutCoherence.Decision.WAIT, request.decide(101, null, viewFaultState(), journalReceipt = receipt()))
        val accepted = observation().apply { put("layoutRevision", "17"); put("chrome", mapOf("sessionId" to "session", "pageId" to 2)) }
        assertEquals(HostLayoutCoherence.Decision.WAIT, request.decide(101, metrics(), viewFaultState().apply {
            put("pendingHostLayout", null); put("acceptedLayout", accepted)
        }, journalReceipt = receipt()))
        val newer = viewFaultState().apply { put("pendingHostLayout", observation("11")) }
        assertEquals(HostLayoutCoherence.Decision.SUPERSEDED, request.decide(101, metrics(), newer, journalReceipt = receipt()))
        assertFalse(request.contentMatches(mapOf("width" to 390.0, "height" to 700.0, "left" to 8.0, "top" to 68.0), 8.0, 69.0))
    }
    @Test fun receiptAndStateAreRevalidatedOnEveryPollWithoutExtendingDeadlineOrAuthority() {
        val request = recoveryGate(); val current = viewFaultState(); val before = current.toString()
        assertEquals(HostLayoutCoherence.Decision.READY, request.decide(101, metrics(), current, journalReceipt = receipt()))
        assertEquals(HostLayoutCoherence.Decision.CANCELLED, request.decide(102, metrics(), current, journalReceipt = receipt().apply { put("status", "cancelled") }))
        val healthy = state().apply { put("acceptedPackIdentity", acceptedIdentity()) }
        assertEquals(HostLayoutCoherence.Decision.CANCELLED, request.decide(103, metrics(), healthy, journalReceipt = receipt().apply { put("reloadKind", "inPlace") }))
        assertEquals(HostLayoutCoherence.Decision.WAIT, request.decide(10_099, metrics(), current, journalReceipt = null))
        assertEquals(HostLayoutCoherence.Decision.EXPIRED, request.decide(10_100, metrics(), current, journalReceipt = receipt()))
        assertEquals(HostLayoutCoherence.Decision.RETIRED, request.decide(10_100, metrics(), current, retired = true, journalReceipt = receipt()))
        assertEquals(10_100, request.deadlineMillis.toInt()); assertEquals(before, current.toString())
    }
    @Test fun proofNeverFallsBackToHistoricalAcceptedLayoutOrPendingNavigationEvenWhenHealthy() {
        val accepted = observation().apply { put("layoutRevision", "17"); put("chrome", mapOf("sessionId" to "session", "pageId" to 2)) }
        val healthy = state().apply { put("acceptedPackIdentity", acceptedIdentity()) }
        assertEquals(HostLayoutCoherence.Decision.READY, recoveryGate().decide(101, metrics(), healthy, journalReceipt = receipt()))
        assertEquals(HostLayoutCoherence.Decision.WAIT, recoveryGate().decide(101, metrics(), healthy.toMutableMap().apply {
            put("pendingHostLayout", null); put("acceptedLayout", accepted)
        }, journalReceipt = receipt()))
        for (pending in listOf(null, mapOf("ticket" to "navigation"))) {
            val changed = healthy.toMutableMap().apply { if (pending == null) remove("pendingNavigation") else put("pendingNavigation", pending) }
            assertEquals(HostLayoutCoherence.Decision.WAIT, recoveryGate().decide(101, metrics(), changed, journalReceipt = receipt()))
        }
        val nullProof = restartProof().apply { put("expectedAccepted", null) }
        val nullReceipt = receipt().apply { put("expectedAccepted", null); put("acceptedPackIdentity", null) }
        assertEquals(HostLayoutCoherence.Decision.CANCELLED, recoveryGate(nullProof).decide(101, metrics(), healthy.toMutableMap().apply {
            put("acceptedPackIdentity", null)
        }, journalReceipt = nullReceipt))
        val emptyObservation = observation(empty = true)
        val emptyRequest = HostLayoutCoherence(emptyObservation, "17", 100, prepareOnly = true, restartAttempt = nullProof)
        assertEquals(HostLayoutCoherence.Decision.READY, emptyRequest.decide(101, metrics(), state(emptyObservation, empty = true), journalReceipt = nullReceipt))
    }
    @Test fun journalAuthorityCancellationIsDistinctFromGeometryWaitingAndObservationSupersession() {
        val request = recoveryGate(); val current = viewFaultState()
        assertEquals(HostLayoutCoherence.Decision.WAIT, request.decide(101, null, current, journalReceipt = receipt()))
        assertEquals(HostLayoutCoherence.Decision.WAIT, request.decide(102, metrics(), current.toMutableMap().apply { put("pendingHostLayout", null) }, journalReceipt = receipt()))
        assertEquals(HostLayoutCoherence.Decision.CANCELLED, request.decide(103, null, current, journalReceipt = receipt().apply { put("status", "cancelled") }))
        assertEquals(HostLayoutCoherence.Decision.CANCELLED, request.decide(104, metrics(), current.toMutableMap().apply {
            put("pendingHostLayout", observation("11"))
        }, journalReceipt = receipt().apply { put("ownerId", "8") }))
        assertEquals(HostLayoutCoherence.Decision.SUPERSEDED, request.decide(105, metrics(), current.toMutableMap().apply {
            put("pendingHostLayout", observation("11"))
        }, journalReceipt = receipt()))
        assertEquals(10_100, request.deadlineMillis.toInt())
    }
    @Test fun restartProofIsCapturedImmutablyBeforeAsynchronousWaits() {
        val original = restartProof(); val request = recoveryGate(original)
        original["attemptId"] = "13"
        @Suppress("UNCHECKED_CAST") val accepted = original["expectedAccepted"] as MutableMap<String, Any?>
        accepted["root"] = "c".repeat(64)
        assertEquals(HostLayoutCoherence.Decision.READY, request.decide(101, metrics(), viewFaultState(), journalReceipt = receipt()))
    }

}
