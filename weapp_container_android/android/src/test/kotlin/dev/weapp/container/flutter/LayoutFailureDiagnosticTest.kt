package dev.weapp.container.flutter

import org.junit.Assert.assertEquals
import org.junit.Test

class LayoutFailureDiagnosticTest {
    @Test fun allowlistedLayoutFailuresKeepOnlyCanonicalNativeIdentities() {
        assertEquals("hostLayout", LayoutFailureDiagnostic.operation("hostLayout"))
        assertEquals("layout-observation-superseded", LayoutFailureDiagnostic.reason(
            "layout does not match the exact native observation and page owner"))
        assertEquals(" ownerId=9007199254740993 surfaceGeneration=1 observationId=18446744073709551615 layoutRevision=8",
            LayoutFailureDiagnostic.stamp("hostLayout", mapOf("observation" to mapOf(
                "ownerId" to "9007199254740993", "surfaceGeneration" to "1",
                "observationId" to "18446744073709551615", "sessionId" to "must-not-log"),
                "layoutRevision" to "8", "packPath" to "must-not-log")))
    }
    @Test fun arbitraryMessagesOperationsAndInvalidIdentitiesNeverReachLogs() {
        val secret = "weapp-container://connect?token=private\nforged-log=true"
        assertEquals("other", LayoutFailureDiagnostic.operation(secret))
        assertEquals("native-operation", LayoutFailureDiagnostic.reason(secret))
        assertEquals("", LayoutFailureDiagnostic.stamp("hostLayout", mapOf("observation" to mapOf(
            "ownerId" to secret, "surfaceGeneration" to "01", "observationId" to "18446744073709551616"),
            "layoutRevision" to 3)))
        assertEquals("", LayoutFailureDiagnostic.stamp("load", mapOf("observation" to mapOf("ownerId" to "1"))))
    }
}
