package ai.latticevpn.android.ui.components

import ai.latticevpn.android.ui.theme.LatticeAmber
import ai.latticevpn.android.ui.theme.LatticeMint
import ai.latticevpn.android.vpn.TunnelState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * Shared Compose building blocks for the Phase A6 UI — the Lattice
 * brand mark, the hero connect control, and the settings-row family.
 */

// ---------------------------------------------------------------------------
// Brand mark
// ---------------------------------------------------------------------------

/**
 * The Lattice glyph — a hexagonal lattice of connected nodes, echoing
 * the app logo. Drawn rather than bundled so it scales crisply and
 * tints to any color.
 */
@Composable
fun LatticeMark(
    modifier: Modifier = Modifier,
    color: Color = LatticeMint,
) {
    Canvas(modifier) {
        val center = Offset(size.width / 2f, size.height / 2f)
        val radius = size.minDimension / 2f * 0.92f
        val points = (0 until 6).map { i ->
            val angle = (-90.0 + 60.0 * i) * PI / 180.0
            Offset(
                center.x + radius * cos(angle).toFloat(),
                center.y + radius * sin(angle).toFloat(),
            )
        }
        val stroke = size.minDimension * 0.065f
        for (i in 0 until 6) {
            drawLine(color, points[i], points[(i + 1) % 6], stroke, StrokeCap.Round)
            drawLine(color.copy(alpha = 0.5f), center, points[i], stroke, StrokeCap.Round)
        }
        val dot = size.minDimension * 0.075f
        points.forEach { drawCircle(color, dot, it) }
        drawCircle(color, dot * 1.2f, center)
    }
}

// ---------------------------------------------------------------------------
// Connect control
// ---------------------------------------------------------------------------

/**
 * The circular hero control on the home screen. The ring and the
 * power glyph track the tunnel state: a muted outline when down, an
 * amber sweep while connecting, a mint ring with a soft glow when up.
 * The whole disc is one tap target.
 */
@Composable
fun ConnectControl(
    state: TunnelState,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val accent = when (state) {
        TunnelState.CONNECTED -> MaterialTheme.colorScheme.primary
        TunnelState.CONNECTING, TunnelState.DISCONNECTING -> LatticeAmber
        TunnelState.ERROR -> MaterialTheme.colorScheme.error
        TunnelState.DISCONNECTED -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    val track = MaterialTheme.colorScheme.surfaceVariant
    val busy = state == TunnelState.CONNECTING || state == TunnelState.DISCONNECTING
    val connected = state == TunnelState.CONNECTED

    val transition = rememberInfiniteTransition(label = "connect")
    val rotation by transition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(1400, easing = LinearEasing)),
        label = "rotation",
    )
    val pulse by transition.animateFloat(
        initialValue = 0.4f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(1700), repeatMode = RepeatMode.Reverse),
        label = "pulse",
    )

    Box(
        modifier = modifier
            .size(230.dp)
            .clip(CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val ringStroke = 13.dp.toPx()
            val center = Offset(size.width / 2f, size.height / 2f)
            val radius = size.minDimension / 2f - ringStroke

            // Soft outer glow while connected.
            if (connected) {
                for (i in 3 downTo 1) {
                    drawCircle(
                        color = accent.copy(alpha = 0.07f * pulse * i),
                        radius = radius + i * 11.dp.toPx(),
                        center = center,
                    )
                }
            }
            // Ring track.
            drawCircle(track, radius, center, style = Stroke(ringStroke))
            // Active ring.
            when {
                busy -> drawArc(
                    color = accent,
                    startAngle = rotation,
                    sweepAngle = 100f,
                    useCenter = false,
                    topLeft = Offset(center.x - radius, center.y - radius),
                    size = Size(radius * 2, radius * 2),
                    style = Stroke(ringStroke, cap = StrokeCap.Round),
                )
                connected || state == TunnelState.ERROR ->
                    drawCircle(accent, radius, center, style = Stroke(ringStroke))
            }
            // Power glyph: an almost-closed ring with a gap at the top and
            // a vertical stem through the gap.
            val glyphRadius = size.minDimension * 0.17f
            val glyphStroke = 9.dp.toPx()
            drawArc(
                color = accent,
                startAngle = 290f,
                sweepAngle = 320f,
                useCenter = false,
                topLeft = Offset(center.x - glyphRadius, center.y - glyphRadius),
                size = Size(glyphRadius * 2, glyphRadius * 2),
                style = Stroke(glyphStroke, cap = StrokeCap.Round),
            )
            drawLine(
                color = accent,
                start = Offset(center.x, center.y - glyphRadius * 1.4f),
                end = Offset(center.x, center.y + glyphRadius * 0.05f),
                strokeWidth = glyphStroke,
                cap = StrokeCap.Round,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Settings rows
// ---------------------------------------------------------------------------

/** A small uppercase label that introduces a group of settings rows. */
@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text.uppercase(),
        color = MaterialTheme.colorScheme.primary,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 1.sp,
        modifier = modifier.padding(start = 4.dp, top = 8.dp, bottom = 6.dp),
    )
}

/** A rounded container that groups a column of settings rows. */
@Composable
fun SettingsCard(content: @Composable () -> Unit) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column { content() }
    }
}

/** A thin divider sized to sit between rows inside a [SettingsCard]. */
@Composable
fun RowDivider() {
    HorizontalDivider(
        color = MaterialTheme.colorScheme.outline.copy(alpha = 0.6f),
        modifier = Modifier.padding(horizontal = 16.dp),
    )
}

/** A tappable settings row with a title, supporting text and a chevron. */
@Composable
fun SettingsItem(
    title: String,
    subtitle: String? = null,
    leadingIcon: ImageVector? = null,
    showChevron: Boolean = true,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leadingIcon != null) {
            Icon(
                imageVector = leadingIcon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(22.dp),
            )
            Spacer(Modifier.width(14.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, color = MaterialTheme.colorScheme.onSurface, fontSize = 16.sp)
            if (subtitle != null) {
                Text(
                    subtitle,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
        }
        if (showChevron) {
            Spacer(Modifier.width(8.dp))
            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** A settings row carrying a [Switch] for an app-local boolean preference. */
@Composable
fun SettingsToggle(
    title: String,
    subtitle: String? = null,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onCheckedChange(!checked) }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, color = MaterialTheme.colorScheme.onSurface, fontSize = 16.sp)
            if (subtitle != null) {
                Text(
                    subtitle,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = MaterialTheme.colorScheme.onPrimary,
                checkedTrackColor = MaterialTheme.colorScheme.primary,
            ),
        )
    }
}

/** A non-interactive row that pairs a label with a read-only value. */
@Composable
fun InfoItem(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            color = MaterialTheme.colorScheme.onSurface,
            fontSize = 16.sp,
            modifier = Modifier.weight(1f),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            value,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontSize = 14.sp,
            textAlign = androidx.compose.ui.text.style.TextAlign.End,
            overflow = TextOverflow.Ellipsis,
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
    }
}
