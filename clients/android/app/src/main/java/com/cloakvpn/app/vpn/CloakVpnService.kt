package com.cloakvpn.app.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import androidx.core.app.NotificationCompat
import com.cloakvpn.app.MainActivity
import com.cloakvpn.app.R

/**
 * Foreground VPN service. Owns the ParcelFileDescriptor returned by
 * VpnService.Builder.establish() and delegates actual tunnel I/O to
 * wireguard-android's GoBackend via [TunnelRepository].
 */
class CloakVpnService : VpnService() {

    override fun onCreate() {
        super.onCreate()
        createChannel()
        startAsForeground()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Actual tunnel bringup happens in TunnelRepository.connect(), which
        // calls into wireguard-android's GoBackend. This service only exists
        // so Android keeps the process alive and shows the persistent
        // notification required on API 34+.
        return START_STICKY
    }

    override fun onDestroy() {
        TunnelRepository.get(this).disconnect()
        super.onDestroy()
    }

    // MARK: - Notification

    private fun createChannel() {
        val mgr = getSystemService(NotificationManager::class.java)
        val existing = mgr.getNotificationChannel(CHANNEL_ID)
        if (existing == null) {
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Cloak VPN tunnel",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps the VPN tunnel alive while connected."
                setShowBadge(false)
            }
            mgr.createNotificationChannel(ch)
        }
    }

    private fun startAsForeground() {
        val pi = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notif: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Cloak VPN connected")
            .setContentText("Post-quantum tunnel active")
            .setSmallIcon(android.R.drawable.ic_lock_idle_lock) // replace with real icon
            .setContentIntent(pi)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIF_ID, notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    companion object {
        private const val CHANNEL_ID = "cloak_vpn_tunnel"
        private const val NOTIF_ID = 0xC10AC
    }
}
