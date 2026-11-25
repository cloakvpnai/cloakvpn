package ai.latticevpn.android.ui.components

import ai.latticevpn.android.data.LatticeRegion
import ai.latticevpn.android.ui.theme.LatticeMint
import ai.latticevpn.android.ui.theme.LatticeOnSurface
import ai.latticevpn.android.ui.theme.LatticeOnSurfaceMuted
import ai.latticevpn.android.ui.theme.LatticeOutline
import ai.latticevpn.android.vpn.cnsa2.Cnsa2Stats
import android.content.Context
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import kotlin.math.abs
import kotlin.math.atan2
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import java.io.DataInputStream
import java.util.Calendar
import java.util.TimeZone
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The globe panel on the home screen: a globe that turns continuously, one dot per
 * region, the exit in use lit, and four facts about the current session. It shows this
 * device's own connection only. Nothing about other customers is fetched or drawn.
 *
 * The globe is drawn here from a small outline of the continents shipped inside the app
 * (Natural Earth, public domain), so it makes no network requests and uses no map service.
 */
@Composable
fun GlobePanel(
    selectedRegionId: String?,
    connected: Boolean,
    stats: Cnsa2Stats,
    onPick: (LatticeRegion) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val land = remember { GlobeLand.load(context) }
    val liveRegion = if (connected) selectedRegionId?.let { LatticeRegion.byId(it) } else null
    var open by remember { mutableStateOf<GlobeTile?>(null) }

    // Where the globe is looking, in degrees.
    var centerLon by remember { mutableFloatStateOf(-100f) }
    var centerLat by remember { mutableFloatStateOf(18f) }
    // The globe rests until this time (frame clock, nanoseconds) after a touch or a new connection.
    var holdUntil by remember { mutableLongStateOf(0L) }
    var frameNow by remember { mutableLongStateOf(0L) }

    // Turn continuously: one full turn in about two minutes, drifting back to a latitude
    // that keeps most regions in view.
    LaunchedEffect(Unit) {
        var last = 0L
        while (true) {
            withFrameNanos { now ->
                frameNow = now
                if (last != 0L && now >= holdUntil) {
                    val dt = min((now - last) / 1e9f, 0.1f)
                    var lon = centerLon + DEGREES_PER_SECOND * dt
                    if (lon > 180f) lon -= 360f
                    centerLon = lon
                    centerLat += (18f - centerLat) * min(1f, dt * 0.4f)
                }
                last = now
            }
        }
    }

    // Swing to the exit when a connection comes up, rest on it, then carry on turning.
    LaunchedEffect(connected, selectedRegionId) {
        val exit = if (connected) selectedRegionId?.let { REGION_COORDINATES[it] } else null
        if (exit != null) {
            holdUntil = Long.MAX_VALUE
            val fromLon = centerLon
            val fromLat = centerLat
            var delta = exit.second - fromLon
            if (delta > 180f) delta -= 360f
            if (delta < -180f) delta += 360f
            animate(0f, 1f, animationSpec = tween(900)) { v, _ ->
                var lon = fromLon + delta * v
                if (lon > 180f) lon -= 360f
                if (lon < -180f) lon += 360f
                centerLon = lon
                centerLat = fromLat + (exit.first - fromLat) * v
            }
            holdUntil = frameNow + 6_000_000_000L
        }
    }

    val pulse by rememberInfiniteTransition(label = "exit").animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(1800), RepeatMode.Restart),
        label = "ring",
    )
    val pick by rememberUpdatedState(onPick)

    Box(
        modifier
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF04070D))
            .border(1.dp, LatticeOutline, RoundedCornerShape(16.dp))
            .semantics {
                contentDescription = liveRegion?.let { "Globe. Connected through ${it.displayName}." }
                    ?: "Globe of regions. Not connected."
            },
    ) {
        Canvas(
            Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    // Sideways drags turn the globe. Up and down drags are left alone, so they
                    // still scroll the page the panel sits in.
                    detectHorizontalDragGestures { change, dragX ->
                        change.consume()
                        val radius = globeRadius(Size(size.width.toFloat(), size.height.toFloat()))
                        var lon = centerLon - dragX / radius * RAD_TO_DEG
                        if (lon > 180f) lon -= 360f
                        if (lon < -180f) lon += 360f
                        centerLon = lon
                        holdUntil = frameNow + 5_000_000_000L
                    }
                }
                .pointerInput(Unit) {
                    detectTapGestures { position ->
                        val canvas = Size(size.width.toFloat(), size.height.toFloat())
                        val radius = globeRadius(canvas)
                        val center = globeCenter(canvas)
                        val view = GlobeView(centerLon, centerLat)
                        var best: LatticeRegion? = null
                        var bestDistance = 28.dp.toPx()
                        for (region in LatticeRegion.all) {
                            val c = REGION_COORDINATES[region.id] ?: continue
                            val p = view.project(c.second, c.first)
                            if (p.z <= 0f) continue
                            val d = hypot(center.x + radius * p.x - position.x, center.y - radius * p.y - position.y)
                            if (d < bestDistance) { bestDistance = d; best = region }
                        }
                        best?.let {
                            holdUntil = frameNow + 5_000_000_000L
                            pick(it)
                        }
                    }
                },
        ) {
            drawGlobe(land, GlobeView(centerLon, centerLat), selectedRegionId, connected, pulse)
        }

        Column(Modifier.fillMaxSize().padding(10.dp)) {
            AnimatedVisibility(visible = open == null, enter = fadeIn(), exit = fadeOut()) {
                GlobeHeader(liveRegion)
            }
            Spacer(Modifier.weight(1f))
            AnimatedVisibility(
                visible = open != null,
                enter = fadeIn() + scaleIn(initialScale = 0.9f),
                exit = fadeOut() + scaleOut(targetScale = 0.9f),
            ) {
                // Keep the last tile while the card animates away.
                val shown = remember { mutableStateOf(GlobeTile.SESSION) }
                open?.let { shown.value = it }
                GlobeDetail(shown.value, liveRegion, stats, connected) { open = null }
            }
            Spacer(Modifier.height(8.dp))
            GlobeTiles(liveRegion != null, stats, connected, open) { tile -> open = if (open == tile) null else tile }
        }
    }
}

enum class GlobeTile { SESSION, TRAFFIC, LATENCY, KEYS }

private const val DEGREES_PER_SECOND = 3f
private const val RAD_TO_DEG = (180.0 / PI).toFloat()
private const val DEG_TO_RAD = (PI / 180.0).toFloat()
private val GlobePanelFill = Color(0xFF0A1628)

/** Where each region's servers are, to the nearest city: latitude, longitude. */
internal val REGION_COORDINATES: Map<String, Pair<Float, Float>> = mapOf(
    "us-west-1" to (45.52f to -122.99f),
    "us-east-1" to (39.04f to -77.49f),
    "us-central-1" to (32.78f to -96.80f),
    "de1" to (50.48f to 12.37f),
    "fi1" to (60.17f to 24.94f),
    "es1" to (40.42f to -3.70f),
    "mx1" to (19.43f to -99.13f),
    "za1" to (-26.20f to 28.05f),
    "in1" to (19.08f to 72.88f),
    "jp1" to (35.68f to 139.69f),
)

// ---- Projection -----------------------------------------------------------

internal class Projected(val x: Float, val y: Float, val z: Float)

/** An orthographic view of the globe centred on a longitude and latitude, in degrees. */
internal class GlobeView(centerLon: Float, centerLat: Float) {
    private val lon0 = centerLon * DEG_TO_RAD
    private val sin0 = sin(centerLat * DEG_TO_RAD)
    private val cos0 = cos(centerLat * DEG_TO_RAD)

    /** x to the right, y up, z toward the viewer, on a sphere of radius 1. z > 0 is the near side. */
    fun project(lonDeg: Float, latDeg: Float): Projected {
        val lat = latDeg * DEG_TO_RAD
        return project(lonDeg * DEG_TO_RAD, sin(lat), cos(lat))
    }

    fun project(lonRad: Float, sinLat: Float, cosLat: Float): Projected {
        val dl = lonRad - lon0
        val cosDl = cos(dl)
        return Projected(
            x = cosLat * sin(dl),
            y = cos0 * sinLat - sin0 * cosLat * cosDl,
            z = sin0 * sinLat + cos0 * cosLat * cosDl,
        )
    }
}

/** The outline of the continents: rings of points, stored as longitude and the sine and cosine of latitude. */
internal class GlobeLand(val rings: List<Ring>) {
    class Ring(val lon: FloatArray, val sinLat: FloatArray, val cosLat: FloatArray)

    companion object {
        fun load(context: Context): GlobeLand = try {
            context.assets.open("globe_land.bin").use { parse(DataInputStream(it.buffered())) }
        } catch (_: Exception) {
            GlobeLand(emptyList())
        }

        /** Format: ring count, then for each ring a point count and (longitude, latitude) pairs in hundredths of a degree, all 16 bit big endian. */
        fun parse(input: DataInputStream): GlobeLand {
            val count = input.readUnsignedShort()
            val rings = ArrayList<Ring>(count)
            repeat(count) {
                val n = input.readUnsignedShort()
                val lon = FloatArray(n)
                val sinLat = FloatArray(n)
                val cosLat = FloatArray(n)
                for (i in 0 until n) {
                    lon[i] = input.readShort() / 100f * DEG_TO_RAD
                    val lat = input.readShort() / 100f * DEG_TO_RAD
                    sinLat[i] = sin(lat)
                    cosLat[i] = cos(lat)
                }
                rings.add(Ring(lon, sinLat, cosLat))
            }
            return GlobeLand(rings)
        }
    }
}

/** Where the sun is overhead right now: latitude and longitude in degrees. Good to about a degree. */
internal fun subsolarPoint(nowMillis: Long = System.currentTimeMillis()): Pair<Float, Float> {
    val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { timeInMillis = nowMillis }
    val day = utc.get(Calendar.DAY_OF_YEAR)
    val hours = utc.get(Calendar.HOUR_OF_DAY) + utc.get(Calendar.MINUTE) / 60f
    val latitude = -23.44f * cos((2.0 * PI * (day + 10) / 365.0).toFloat())
    var longitude = -15f * (hours - 12f)
    if (longitude > 180f) longitude -= 360f
    if (longitude < -180f) longitude += 360f
    return latitude to longitude
}

// ---- Drawing --------------------------------------------------------------

private fun globeCenter(canvas: Size) = Offset(canvas.width / 2f, canvas.height * 0.46f)
private fun globeRadius(canvas: Size) = min(canvas.width * 0.42f, canvas.height * 0.36f)

private fun DrawScope.drawGlobe(land: GlobeLand, view: GlobeView, selectedRegionId: String?, connected: Boolean, pulse: Float) {
    val center = globeCenter(size)
    val radius = globeRadius(size)

    // A few fixed stars behind the globe.
    for (i in 0 until 70) {
        val x = ((i * 7919) % 1000) / 1000f * size.width
        val y = ((i * 6007 + 131) % 1000) / 1000f * size.height
        drawCircle(Color.White.copy(alpha = 0.18f + (i % 5) * 0.08f), radius = 0.6f + (i % 3) * 0.5f, center = Offset(x, y))
    }

    // Atmosphere, then the ocean.
    drawCircle(
        Brush.radialGradient(listOf(Color(0x553FA9FF), Color.Transparent), center = center, radius = radius * 1.12f),
        radius = radius * 1.12f, center = center,
    )
    drawCircle(
        Brush.radialGradient(
            listOf(Color(0xFF1B5A94), Color(0xFF123F70), Color(0xFF0B2748)),
            center = Offset(center.x - radius * 0.25f, center.y - radius * 0.3f), radius = radius * 1.5f,
        ),
        radius = radius, center = center,
    )

    val disk = Path().apply { addOval(androidx.compose.ui.geometry.Rect(center.x - radius, center.y - radius, center.x + radius, center.y + radius)) }
    clipPath(disk) {
        // Land. Each outline is cut where it crosses the horizon and closed along the
        // edge of the disk, so a continent that runs over the horizon ends at it.
        val path = Path()
        val points = HorizonClipper()
        for (ring in land.rings) {
            points.clip(ring, view)
            val count = points.count
            if (count < 6) continue
            val xy = points.xy
            path.moveTo(center.x + radius * xy[0], center.y - radius * xy[1])
            var k = 2
            while (k < count) {
                path.lineTo(center.x + radius * xy[k], center.y - radius * xy[k + 1])
                k += 2
            }
            path.close()
        }
        drawPath(path, Color(0xFF3E9C78))
        drawPath(path, Color(0xFF7FD6B0).copy(alpha = 0.35f), style = Stroke(width = 1f))

        // Night side, from where the sun is now.
        val sun = subsolarPoint()
        val s = view.project(sun.second, sun.first)
        val flat = sqrt(s.x * s.x + s.y * s.y)
        if (flat < 0.05f) {
            if (s.z < 0f) drawCircle(Color.Black.copy(alpha = 0.55f), radius = radius, center = center)
        } else {
            val ux = s.x / flat
            val uy = -s.y / flat
            val k = (-s.z * 0.8f / flat).coerceIn(-1.3f, 1.3f)
            val from = Offset(center.x + radius * ux * (k + 0.35f), center.y + radius * uy * (k + 0.35f))
            val to = Offset(center.x + radius * ux * (k - 0.35f), center.y + radius * uy * (k - 0.35f))
            drawCircle(
                Brush.linearGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.6f)), start = from, end = to),
                radius = radius, center = center,
            )
        }
    }
    drawCircle(Color(0x66A9D8FF), radius = radius, center = center, style = Stroke(width = 1.2f))

    // Region dots. The exit in use is larger, mint, and sends out a ring.
    for (region in LatticeRegion.all) {
        val c = REGION_COORDINATES[region.id] ?: continue
        val p = view.project(c.second, c.first)
        if (p.z <= 0.02f) continue
        val at = Offset(center.x + radius * p.x, center.y - radius * p.y)
        val selected = region.id == selectedRegionId
        val live = connected && selected
        if (live) {
            drawCircle(LatticeMint.copy(alpha = 0.9f * (1f - pulse)), radius = (6f + 14f * pulse) * density, center = at, style = Stroke(width = 2f * density))
        }
        val r = (if (live) 6.5f else 4.5f) * density
        drawCircle(Color.Black.copy(alpha = 0.55f), radius = r + 1.5f * density, center = at)
        drawCircle(if (live) LatticeMint else if (selected) Color(0xFFBFF3DC) else Color.White.copy(alpha = 0.9f), radius = r, center = at)
    }
}

/**
 * Cuts one land outline to the visible half of the globe. The result is in [xy] as
 * unit-disk coordinates (x right, y up), [count] floats long. Where the outline goes
 * behind the horizon and comes back, the gap is closed along the edge of the disk by
 * the shorter way round.
 */
internal class HorizonClipper {
    var xy = FloatArray(1024)
        private set
    var count = 0
        private set

    private fun add(x: Float, y: Float) {
        if (count + 2 > xy.size) xy = xy.copyOf(xy.size * 2)
        xy[count++] = x
        xy[count++] = y
    }

    fun clip(ring: GlobeLand.Ring, view: GlobeView) {
        count = 0
        val n = ring.lon.size
        var start = -1
        for (i in 0 until n) {
            if (view.project(ring.lon[i], ring.sinLat[i], ring.cosLat[i]).z >= 0f) { start = i; break }
        }
        if (start < 0) return // wholly on the far side
        var prev = view.project(ring.lon[start], ring.sinLat[start], ring.cosLat[start])
        var px = prev.x; var py = prev.y; var pz = prev.z
        add(px, py)
        var exitAngle = 0f
        for (step in 1..n) {
            val i = (start + step) % n
            val cur = view.project(ring.lon[i], ring.sinLat[i], ring.cosLat[i])
            val cx = cur.x; val cy = cur.y; val cz = cur.z
            if (pz >= 0f && cz >= 0f) {
                if (step < n) add(cx, cy)
            } else if (pz >= 0f) {
                // going behind the horizon: stop at the edge
                val t = pz / (pz - cz)
                val angle = atan2(py + (cy - py) * t, px + (cx - px) * t)
                add(cos(angle), sin(angle))
                exitAngle = angle
            } else if (cz >= 0f) {
                // coming back: follow the edge from where the outline left it
                val t = pz / (pz - cz)
                val angle = atan2(py + (cy - py) * t, px + (cx - px) * t)
                var sweep = angle - exitAngle
                while (sweep > PI) sweep -= (2 * PI).toFloat()
                while (sweep < -PI) sweep += (2 * PI).toFloat()
                val pieces = max(1, (abs(sweep) / 0.09f).toInt())
                for (j in 1..pieces) {
                    val at = exitAngle + sweep * j / pieces
                    add(cos(at), sin(at))
                }
                if (step < n) add(cx, cy)
            }
            px = cx; py = cy; pz = cz
        }
    }
}

// ---- Header, tiles and the popped-out detail ---------------------------------

@Composable
private fun GlobeHeader(liveRegion: LatticeRegion?) {
    Column(
        Modifier
            .background(GlobePanelFill.copy(alpha = 0.82f), RoundedCornerShape(10.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(6.dp).background(if (liveRegion == null) LatticeOnSurfaceMuted else LatticeMint, CircleShape))
            Spacer(Modifier.width(6.dp))
            Text(
                if (liveRegion == null) "REGIONS" else "LIVE CONNECTION",
                color = LatticeOnSurfaceMuted, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.sp,
            )
        }
        Text(
            liveRegion?.let { "${it.countryFlag}  ${it.displayName}" } ?: "Tap a dot to pick a region",
            color = if (liveRegion == null) LatticeOnSurface else Color(0xFFBFF3DC),
            fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun GlobeTiles(lit: Boolean, stats: Cnsa2Stats, connected: Boolean, open: GlobeTile?, onTap: (GlobeTile) -> Unit) {
    val now by sessionClock()
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        GlobeFact("SESSION", sessionText(connected, stats, now), lit, open == GlobeTile.SESSION, Modifier.weight(1f)) { onTap(GlobeTile.SESSION) }
        GlobeFact("DOWN / UP", tileTraffic(connected, stats), lit, open == GlobeTile.TRAFFIC, Modifier.weight(1.25f)) { onTap(GlobeTile.TRAFFIC) }
        GlobeFact("LATENCY", latencyText(connected, stats), lit, open == GlobeTile.LATENCY, Modifier.weight(0.85f)) { onTap(GlobeTile.LATENCY) }
        GlobeFact("NEW KEYS", keysText(connected, stats).removePrefix("Every "), lit, open == GlobeTile.KEYS, Modifier.weight(1.1f)) { onTap(GlobeTile.KEYS) }
    }
}

/** A tile. Tapping it pops its detail out; tapping it again, or the detail, puts it away. */
@Composable
private fun GlobeFact(label: String, value: String, lit: Boolean, isOpen: Boolean, modifier: Modifier, onTap: () -> Unit) {
    Column(
        modifier
            .clip(RoundedCornerShape(10.dp))
            .background(GlobePanelFill.copy(alpha = if (isOpen) 0.95f else 0.82f))
            .border(1.dp, if (isOpen) LatticeMint.copy(alpha = 0.7f) else Color.Transparent, RoundedCornerShape(10.dp))
            .clickable(onClickLabel = if (isOpen) "Close the detail" else "Show more detail", onClick = onTap)
            .padding(horizontal = 6.dp, vertical = 7.dp),
    ) {
        // Sized in fixed units: four tiles share one row, so the text must not grow
        // with the phone's font setting. The detail that pops out does grow.
        val labelSize = with(LocalDensity.current) { 8.5.dp.toSp() }
        val valueSize = with(LocalDensity.current) { 10.5.dp.toSp() }
        Text(label, color = if (isOpen) LatticeMint else LatticeOnSurfaceMuted, fontSize = labelSize, fontWeight = FontWeight.SemiBold, maxLines = 1, softWrap = false)
        Text(
            value,
            color = if (lit) Color(0xFFBFF3DC) else LatticeOnSurface,
            fontSize = valueSize, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace,
            maxLines = 1, overflow = TextOverflow.Clip, softWrap = false,
        )
    }
}

@Composable
private fun GlobeDetail(tile: GlobeTile, liveRegion: LatticeRegion?, stats: Cnsa2Stats, connected: Boolean, onClose: () -> Unit) {
    val now by sessionClock()
    val live = liveRegion != null
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(GlobePanelFill.copy(alpha = 0.95f))
            .border(1.dp, LatticeMint.copy(alpha = 0.45f), RoundedCornerShape(14.dp))
            .clickable(onClickLabel = "Close the detail", onClick = onClose)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                when (tile) {
                    GlobeTile.SESSION -> "THIS SESSION"
                    GlobeTile.TRAFFIC -> "DATA THIS SESSION"
                    GlobeTile.LATENCY -> "LATENCY TO THE EXIT"
                    GlobeTile.KEYS -> "KEY CHANGES"
                },
                color = LatticeMint, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.sp,
            )
            Spacer(Modifier.weight(1f))
            Text("✕", color = LatticeOnSurfaceMuted, fontSize = 13.sp)
        }
        when (tile) {
            GlobeTile.SESSION -> {
                DetailBig(sessionText(connected, stats, now), live)
                if (liveRegion != null) {
                    DetailLine("Exit", "${liveRegion.countryFlag}  ${liveRegion.displayName}")
                    DetailLine("Exit address", liveRegion.endpointIP)
                    if (stats.connectedAtMs > 0) {
                        DetailLine("Connected at", java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(stats.connectedAtMs)))
                    }
                } else {
                    DetailNote("Tap the shield, or a dot on the globe, to connect.")
                }
            }
            GlobeTile.TRAFFIC -> {
                if (live) {
                    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                        DetailPair("DOWN", formatBytes(stats.rxBytes))
                        DetailPair("UP", formatBytes(stats.txBytes))
                        DetailPair("TOTAL", formatBytes(stats.rxBytes + stats.txBytes))
                    }
                } else {
                    DetailBig("--", false)
                }
                DetailNote("Counted on this device for this session only. Not saved and not sent to Lattice.")
            }
            GlobeTile.LATENCY -> {
                DetailBig(latencyText(connected, stats), live)
                if (live && stats.latencyBestMs > 0) {
                    DetailLine("Best", "${stats.latencyBestMs} ms")
                    DetailLine("Average", "${stats.latencyAverageMs} ms")
                }
                DetailNote(liveRegion?.let { "Round trip from this device to ${it.displayName} and back, through the tunnel." } ?: "Shown while connected.")
            }
            GlobeTile.KEYS -> {
                DetailBig(if (live) "${stats.keyChanges} so far" else "--", live)
                DetailLine("Replaced", "Every 10 minutes")
                DetailLine("Key exchange", "ML-KEM-1024")
                DetailLine("Signatures", "ML-DSA-87")
                DetailLine("Cipher", "AES-256-GCM")
            }
        }
    }
}

@Composable
private fun DetailBig(text: String, lit: Boolean) {
    Text(
        text, color = if (lit) Color(0xFFBFF3DC) else LatticeOnSurface,
        fontSize = 26.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace, maxLines = 1, softWrap = false,
    )
}

@Composable
private fun DetailPair(label: String, value: String) {
    Column {
        Text(label, color = LatticeOnSurfaceMuted, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.8.sp)
        Text(value, color = Color(0xFFBFF3DC), fontSize = 17.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace, maxLines = 1, softWrap = false)
    }
}

@Composable
private fun DetailLine(label: String, value: String) {
    Row(Modifier.fillMaxWidth()) {
        Text(label, color = LatticeOnSurfaceMuted, fontSize = 12.sp)
        Spacer(Modifier.weight(1f))
        Text(value, color = LatticeOnSurface, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace, maxLines = 1)
    }
}

@Composable
private fun DetailNote(text: String) {
    Text(text, color = LatticeOnSurfaceMuted, fontSize = 11.sp)
}

/** The wall clock, once a second, for the session timer. */
@Composable
private fun sessionClock() = produceState(System.currentTimeMillis()) {
    while (true) {
        value = System.currentTimeMillis()
        delay(1000)
    }
}

internal fun sessionText(connected: Boolean, stats: Cnsa2Stats, nowMillis: Long): String {
    if (!connected || stats.connectedAtMs <= 0) return "Not connected"
    val s = max(0L, (nowMillis - stats.connectedAtMs) / 1000)
    return "%02d:%02d:%02d".format(s / 3600, (s % 3600) / 60, s % 60)
}

internal fun trafficText(connected: Boolean, stats: Cnsa2Stats): String =
    if (!connected) "--" else "${formatBytes(stats.rxBytes)} / ${formatBytes(stats.txBytes)}"

/** Short form for the tile, for example "1.5M / 250K". The detail shows the full figures. */
internal fun tileTraffic(connected: Boolean, stats: Cnsa2Stats): String =
    if (!connected) "--" else "${shortBytes(stats.rxBytes)} / ${shortBytes(stats.txBytes)}"

internal fun shortBytes(bytes: Long): String = when {
    bytes < 1_000_000L -> "${max(0L, bytes) / 1000}K"
    bytes < 100_000_000L -> "%.1fM".format(bytes / 1_000_000.0)
    bytes < 1_000_000_000L -> "${bytes / 1_000_000}M"
    else -> "%.1fG".format(bytes / 1_000_000_000.0)
}

internal fun latencyText(connected: Boolean, stats: Cnsa2Stats): String =
    if (!connected || stats.latencyMs <= 0) "--" else "${stats.latencyMs} ms"

/** The keys are replaced every 10 minutes; the count is how many times so far. */
internal fun keysText(connected: Boolean, stats: Cnsa2Stats): String =
    if (!connected || stats.keyChanges == 0) "Every 10 min" else "${stats.keyChanges} so far"

internal fun formatBytes(bytes: Long): String = when {
    bytes < 1_000_000L -> "${max(0L, bytes) / 1000} KB"
    bytes < 1_000_000_000L -> "%.1f MB".format(bytes / 1_000_000.0)
    else -> "%.2f GB".format(bytes / 1_000_000_000.0)
}
