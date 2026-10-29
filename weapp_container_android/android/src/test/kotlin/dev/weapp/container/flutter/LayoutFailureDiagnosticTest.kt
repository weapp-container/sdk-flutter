package dev.weapp.container.flutter

import org.junit.Assert.assertEquals
import org.junit.Test

class LayoutFailureDiagnosticTest {
    @Test fun allowlistedLayoutFailuresKeepOnlyCanonicalNativeIdentities() {
        assertEquals("hostLayout", LayoutFailureDiagnostic.operation("hostLayout"))
        assertEquals("layout-observation-superseded", LayoutFailureDiagnostic.reason("ERR_CANCELLED",
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
        assertEquals("native-operation", LayoutFailureDiagnostic.reason("ERR_CANCELLED", secret))
        assertEquals("", LayoutFailureDiagnostic.stamp("hostLayout", mapOf("observation" to mapOf(
            "ownerId" to secret, "surfaceGeneration" to "01", "observationId" to "18446744073709551616"),
            "layoutRevision" to 3)))
        assertEquals("", LayoutFailureDiagnostic.stamp("load", mapOf("observation" to mapOf("ownerId" to "1"))))
    }
    @Test fun canonicalMessagesRequireTheirExactErrorCode() {
        val failures = listOf(
            Triple("ERR_INVALID_REQUEST", "initial host chrome dimensions differ from window metrics", "chrome-viewport-mismatch"),
            Triple("ERR_INVALID_REQUEST", "invalid host chrome geometry", "invalid-chrome-geometry"),
            Triple("ERR_INVALID_REQUEST", "host chrome geometry exceeds logical bounds", "chrome-bounds"),
            Triple("ERR_INVALID_REQUEST", "content rectangle disagrees with native window metrics", "layout-content-metrics-mismatch"),
            Triple("ERR_INVALID_REQUEST", "a navigation measurement must commit through completeNavigationLayout", "layout-navigation-measurement-required"),
            Triple("ERR_CANCELLED", "no pending native layout observation", "layout-no-pending-observation"),
            Triple("ERR_CANCELLED", "layout does not match the exact native observation and page owner", "layout-observation-superseded"),
            Triple("ERR_CANCELLED", "host layout surface owner changed", "layout-surface-owner-changed"),
            Triple("ERR_CANCELLED", "stale complete host layout revision", "layout-stale-revision"),
            Triple("ERR_TIMEOUT", "native layout measurement expired; observe and measure again", "layout-measurement-expired"),
            Triple("ERR_CANCELLED", "Chrome owner retired before native measurement", "layout-native-owner-retired"),
        )
        for ((code, message, reason) in failures) {
            assertEquals(reason, LayoutFailureDiagnostic.reason(code, message))
            assertEquals(reason, LayoutFailureDiagnostic.reason(code, "$code: $message"))
            for (wrongCode in listOf("ERR_CANCELLED", "ERR_TIMEOUT", "ERR_INVALID_REQUEST", "ERR_ENGINE", "ERR_UNKNOWN")) {
                if (wrongCode == code) continue
                assertEquals("native-operation", LayoutFailureDiagnostic.reason(wrongCode, message))
                assertEquals("native-operation", LayoutFailureDiagnostic.reason(wrongCode, "$code: $message"))
                assertEquals("native-operation", LayoutFailureDiagnostic.reason(wrongCode, "$wrongCode: $message"))
            }
        }
    }
    @Test fun immutableFfiDisplayPrefixClassifiesKnownCancellationAndTimeout() {
        // SdkError's Display is "{code}: {message}" and Failure::from uses
        // error.to_string(). JNI and ContainerException preserve this string.
        assertEquals("layout-observation-superseded", LayoutFailureDiagnostic.reason("ERR_CANCELLED",
            "ERR_CANCELLED: layout does not match the exact native observation and page owner"))
        assertEquals("layout-no-pending-observation", LayoutFailureDiagnostic.reason("ERR_CANCELLED",
            "ERR_CANCELLED: no pending native layout observation"))
        assertEquals("layout-stale-revision", LayoutFailureDiagnostic.reason("ERR_CANCELLED",
            "ERR_CANCELLED: stale complete host layout revision"))
        assertEquals("layout-measurement-expired", LayoutFailureDiagnostic.reason("ERR_TIMEOUT",
            "ERR_TIMEOUT: native layout measurement expired; observe and measure again"))
    }
    @Test fun duplicatePrefixesAndNearMatchesRemainUnknown() {
        val message = "layout does not match the exact native observation and page owner"
        for (value in listOf(
            "ERR_CANCELLED: ERR_CANCELLED: $message", "ERR_TIMEOUT: $message",
            "ERR_CANCELLED:$message", "ERR_CANCELLED:  $message",
            " ERR_CANCELLED: $message", "ERR_CANCELLED: $message ",
            "$message\n", "ERR_CANCELLED: $message\nforged-log=true",
            "ERR_CANCELLED: $message\r", "ERR_CANCELLED: $message\u0000",
            message.uppercase(), "prefix $message", "$message suffix",
        )) assertEquals("native-operation", LayoutFailureDiagnostic.reason("ERR_CANCELLED", value))
    }
    @Test fun missingCodesAndSecretPrefixesNeverBecomeKnownReasons() {
        val message = "no pending native layout observation"
        for (code in listOf(null, "", "err_cancelled", "ERR_CANCELLED ", "ERR_CANCELLED\nforged-log=true")) {
            assertEquals("native-operation", LayoutFailureDiagnostic.reason(code, message))
            assertEquals("native-operation", LayoutFailureDiagnostic.reason(code, "ERR_CANCELLED: $message"))
        }
        assertEquals("native-operation", LayoutFailureDiagnostic.reason("ERR_CANCELLED", null))
        assertEquals("native-operation", LayoutFailureDiagnostic.reason("ERR_CANCELLED", ""))
        assertEquals("native-operation", LayoutFailureDiagnostic.reason("ERR_CANCELLED",
            "weapp-container://connect?token=private ERR_CANCELLED: $message"))
        assertEquals("native-operation", LayoutFailureDiagnostic.reason("ERR_CANCELLED",
            "ERR_CANCELLED: weapp-container://connect?token=private $message"))
    }
    @Test fun unknownCancellationAndTimeoutAreNotSilenced() {
        for (code in listOf("ERR_CANCELLED", "ERR_TIMEOUT")) {
            assertEquals("native-operation", LayoutFailureDiagnostic.reason(code, "unreviewed native failure"))
            assertEquals("native-operation", LayoutFailureDiagnostic.reason(code, "$code: unreviewed native failure"))
        }
    }
    @Test fun requestedViewportLogsOnlyBoundedNumericFields() {
        val stamp = LayoutFailureDiagnostic.stamp("prepareHostLayout", mapOf(
            "observation" to mapOf("ownerId" to "7", "surfaceGeneration" to "5", "observationId" to "10",
                "windowMetrics" to mapOf("windowWidth" to 390, "windowHeight" to 700, "screenTop" to 68.5, "pixelRatio" to 2.75,
                    "private" to "must-not-log")), "layoutRevision" to "17",
            "chrome" to mapOf("contentRect" to mapOf("width" to 389.75, "height" to 700, "private" to "must-not-log"))))
        assertEquals(" ownerId=7 surfaceGeneration=5 observationId=10 layoutRevision=17 requestedWindowWidth=390.0 requestedWindowHeight=700.0 requestedScreenTop=68.5 requestedPixelRatio=2.75 requestedChromeWidth=389.75 requestedChromeHeight=700.0", stamp)
        assertEquals("", LayoutFailureDiagnostic.stamp("hostLayout", mapOf("observation" to mapOf(
            "windowMetrics" to mapOf("windowWidth" to "token=secret", "windowHeight" to Double.NaN,
                "screenTop" to Double.POSITIVE_INFINITY, "pixelRatio" to 16385)),
            "chrome" to mapOf("contentRect" to mapOf("width" to "private", "height" to -16385)))))
    }
}
