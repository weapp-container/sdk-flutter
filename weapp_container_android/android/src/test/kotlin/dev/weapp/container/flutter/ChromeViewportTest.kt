package dev.weapp.container.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import kotlin.math.roundToInt

class ChromeViewportTest {
    @Test fun fractionalDensityUsesTheNativeViewportAfterPhysicalQuantization() {
        // A valid Flutter layout rounds up logically, while Android's rounded
        // physical View height maps back down. The old raw geometry failed the
        // runtime's half-logical-pixel agreement check on this class of device.
        val height = 660.501
        val measured = ChromeViewport.measured(1080, 1816, 2.75)
        assertEquals(Pair(393, 660), measured)
        assertNotEquals(height.roundToInt(), measured.second)
        assertEquals(measured, ChromeViewport.prospective(1080 / 2.75, height, 2.75))
    }

    @Test fun stagedResizeAgreesWithItsFutureAndroidViewOnBothSidesOfPixelBoundary() {
        assertEquals(Pair(393, 660), ChromeViewport.prospective(392.7272727, 660.54, 2.75))
        assertEquals(Pair(393, 661), ChromeViewport.prospective(392.7272727, 660.55, 2.75))
        assertEquals(Pair(390, 700), ChromeViewport.measured(1170, 2100, 3.0))
        assertEquals(Pair(390, 700), ChromeViewport.prospective(390.0, 700.0, 3.0))
    }

    @Test(expected = IllegalArgumentException::class)
    fun invalidDensityIsRejectedBeforeQuantization() {
        ChromeViewport.prospective(390.0, 700.0, Double.NaN)
    }
}
