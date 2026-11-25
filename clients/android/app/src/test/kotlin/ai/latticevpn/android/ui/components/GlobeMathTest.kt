package ai.latticevpn.android.ui.components

import ai.latticevpn.android.vpn.cnsa2.Cnsa2Stats
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.util.Calendar
import java.util.TimeZone

class GlobeMathTest {
    @Test
    fun centreOfTheViewProjectsToTheMiddleFacingTheViewer() {
        val p = GlobeView(139.69f, 35.68f).project(139.69f, 35.68f)
        assertEquals(0f, p.x, 1e-4f)
        assertEquals(0f, p.y, 1e-4f)
        assertEquals(1f, p.z, 1e-4f)
    }

    @Test
    fun oppositeSideOfTheGlobeIsHidden() {
        val p = GlobeView(0f, 0f).project(180f, 0f)
        assertEquals(-1f, p.z, 1e-4f)
    }

    @Test
    fun eastIsToTheRightAndNorthIsUp() {
        val view = GlobeView(0f, 0f)
        assertTrue(view.project(30f, 0f).x > 0f)
        assertTrue(view.project(0f, 30f).y > 0f)
    }

    @Test
    fun everyRegionHasCoordinates() {
        for (id in listOf("us-west-1", "us-east-1", "us-central-1", "de1", "fi1", "es1", "mx1", "za1", "in1", "jp1")) {
            assertTrue(id, REGION_COORDINATES.containsKey(id))
        }
    }

    @Test
    fun landOutlineParses() {
        // one ring of three points: (10.00, 20.00), (-30.50, 0.00), (0.00, -45.25)
        val bytes = byteArrayOf(0, 1, 0, 3, 0x03, 0xE8.toByte(), 0x07, 0xD0.toByte(), 0xF4.toByte(), 0x16, 0, 0, 0, 0, 0xEE.toByte(), 0x53)
        val land = GlobeLand.parse(DataInputStream(ByteArrayInputStream(bytes)))
        assertEquals(1, land.rings.size)
        assertEquals(3, land.rings[0].lon.size)
        assertEquals(Math.toRadians(10.0).toFloat(), land.rings[0].lon[0], 1e-4f)
        assertEquals(Math.sin(Math.toRadians(20.0)).toFloat(), land.rings[0].sinLat[0], 1e-4f)
        assertEquals(Math.toRadians(-30.5).toFloat(), land.rings[0].lon[1], 1e-4f)
        assertEquals(Math.sin(Math.toRadians(-45.25)).toFloat(), land.rings[0].sinLat[2], 1e-4f)
    }

    @Test
    fun sunIsOverTheGreenwichMeridianAtNoonUtc() {
        val noon = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { set(2026, Calendar.JUNE, 21, 12, 0, 0) }.timeInMillis
        val (latitude, longitude) = subsolarPoint(noon)
        assertEquals(0f, longitude, 0.5f)
        assertEquals(23.4f, latitude, 0.6f)
    }

    @Test
    fun tileTexts() {
        val stats = Cnsa2Stats(connectedAtMs = 1_000_000L, rxBytes = 1_500_000L, txBytes = 250_000L, keyChanges = 2, latencyMs = 161)
        assertEquals("00:01:05", sessionText(true, stats, 1_065_000L))
        assertEquals("Not connected", sessionText(false, stats, 1_065_000L))
        assertEquals("1.5 MB / 250 KB", trafficText(true, stats))
        assertEquals("161 ms", latencyText(true, stats))
        assertEquals("--", latencyText(true, stats.copy(latencyMs = -1)))
        assertEquals("2 so far", keysText(true, stats))
        assertEquals("Every 10 min", keysText(true, stats.copy(keyChanges = 0)))
    }

    private fun square(lonDeg: Float, latDeg: Float, half: Float): GlobeLand.Ring {
        val corners = listOf(-half to -half, half to -half, half to half, -half to half)
        val lon = FloatArray(4) { Math.toRadians((lonDeg + corners[it].first).toDouble()).toFloat() }
        val lat = DoubleArray(4) { Math.toRadians((latDeg + corners[it].second).toDouble()) }
        return GlobeLand.Ring(lon, FloatArray(4) { kotlin.math.sin(lat[it]).toFloat() }, FloatArray(4) { kotlin.math.cos(lat[it]).toFloat() })
    }

    @Test
    fun outlinesAreCutAtTheHorizon() {
        val view = GlobeView(0f, 0f)
        val clipper = HorizonClipper()

        // wholly in view: the four corners, untouched
        clipper.clip(square(0f, 0f, 10f), view)
        assertEquals(8, clipper.count)

        // wholly on the far side: nothing
        clipper.clip(square(180f, 0f, 10f), view)
        assertEquals(0, clipper.count)

        // across the horizon: closed along the edge, and never outside the disk
        clipper.clip(square(90f, 0f, 20f), view)
        assertTrue(clipper.count >= 8)
        var onEdge = 0
        for (k in 0 until clipper.count step 2) {
            val r = kotlin.math.hypot(clipper.xy[k], clipper.xy[k + 1])
            assertTrue(r <= 1.0001f)
            if (r > 0.999f) onEdge++
        }
        assertTrue(onEdge >= 2)
    }

    @Test
    fun tileTrafficIsShort() {
        assertEquals("13K / 5K", tileTraffic(true, Cnsa2Stats(rxBytes = 13_400, txBytes = 5_900)))
        assertEquals("1.5M / 250K", tileTraffic(true, Cnsa2Stats(rxBytes = 1_500_000, txBytes = 250_000)))
        assertEquals("--", tileTraffic(false, Cnsa2Stats()))
    }
}
