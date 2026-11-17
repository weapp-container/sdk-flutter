package dev.weapp.container.flutter

import kotlin.math.roundToInt

/** Android quantizes Flutter layouts to physical pixels before View layout.
 * Host chrome must use the same integer logical extent as WindowMetrics;
 * rounding the original Flutter double can disagree after that first step. */
internal object ChromeViewport {
    fun measured(width: Int, height: Int, density: Double): Pair<Int, Int> {
        require(width > 0 && height > 0 && density.isFinite() && density > 0)
        val logical = Pair((width / density).roundToInt(), (height / density).roundToInt())
        require(logical.first > 0 && logical.second > 0)
        return logical
    }

    fun prospective(width: Double, height: Double, density: Double): Pair<Int, Int> {
        require(width.isFinite() && height.isFinite() && width > 0 && height > 0)
        require(density.isFinite() && density > 0)
        return measured((width * density).roundToInt(), (height * density).roundToInt(), density)
    }
}
