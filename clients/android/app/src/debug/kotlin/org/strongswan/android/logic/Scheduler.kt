/*
 * Lattice VPN: timer service for the strongSwan native engine.
 *
 * Replaces the upstream class of the same name, which needs the exact alarm
 * permission. Jobs run from a timer thread while the device is awake. An
 * ordinary (inexact) alarm is kept as a backstop so that due jobs still run
 * soon after the device wakes from idle. Late key rotation is safe: the
 * gateway enforces the hard lifetime of every key.
 *
 * Distributed under the terms of strongSwan (GPLv2 or later).
 */
package org.strongswan.android.logic

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import java.util.PriorityQueue
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

class Scheduler(private val context: Context) : BroadcastReceiver() {
    private class Job(val id: String, val time: Long) : Comparable<Job> {
        override fun compareTo(other: Job) = time.compareTo(other.time)
    }

    private val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
    private val timer = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "cnsa2-timer").apply { isDaemon = true } }
    private val jobs = PriorityQueue<Job>()
    private var pending: ScheduledFuture<*>? = null

    init {
        val filter = IntentFilter(ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(this, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(this, filter)
        }
    }

    fun Terminate() {
        synchronized(this) {
            jobs.clear()
            pending?.cancel(false)
        }
        alarms.cancel(alarmIntent())
        timer.shutdownNow()
        try {
            context.unregisterReceiver(this)
        } catch (_: IllegalArgumentException) {
        }
    }

    fun allocateId(): String = UUID.randomUUID().toString()

    fun scheduleJob(id: String, ms: Long) {
        synchronized(this) {
            val job = Job(id, System.currentTimeMillis() + ms)
            jobs.add(job)
            if (job === jobs.peek()) arm(job.time)
        }
    }

    override fun onReceive(context: Context, intent: Intent) = runDue()

    private fun arm(time: Long) {
        pending?.cancel(false)
        val delay = maxOf(0L, time - System.currentTimeMillis())
        pending = try {
            timer.schedule({ runDue() }, delay, TimeUnit.MILLISECONDS)
        } catch (_: Exception) {
            null
        }
        try {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, time, alarmIntent())
        } catch (_: Exception) {
        }
    }

    private fun runDue() {
        val due = ArrayList<Job>()
        synchronized(this) {
            val now = System.currentTimeMillis()
            while (jobs.peek()?.let { it.time <= now } == true) due.add(jobs.remove())
            jobs.peek()?.let { arm(it.time) }
        }
        due.forEach { executeJob(it.id) }
    }

    private fun alarmIntent(): PendingIntent =
        PendingIntent.getBroadcast(context, 0, Intent(ACTION).setPackage(context.packageName), PendingIntent.FLAG_IMMUTABLE)

    external fun executeJob(id: String)

    private companion object {
        const val ACTION = "ai.latticevpn.android.cnsa2.EXECUTE_JOB"
    }
}
