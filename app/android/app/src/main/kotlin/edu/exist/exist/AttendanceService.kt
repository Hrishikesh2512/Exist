package edu.exist.exist

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * Foreground service that keeps attendance running with the screen off.
 *  - teacher: keeps the process (and the Dart runner in the cached engine) alive while
 *    advertising;
 *  - student: scans and checks in natively during class hours, then stops itself.
 */
class AttendanceService : Service() {
    companion object {
        const val ACTION_TEACHER_STANDBY = "teacher_standby" // alarm: class about to start
        const val ACTION_TEACHER_ACTIVE = "teacher_active"
        const val ACTION_TEACHER_STOP = "teacher_stop"
        const val ACTION_STUDENT = "student"
        private const val CHANNEL = "attendance"
        private const val NOTIF_ID = 42

        @Volatile var teacherActive = false

        fun start(ctx: Context, action: String) {
            val i = Intent(ctx, AttendanceService::class.java).setAction(action)
            try {
                ctx.startForegroundService(i)
            } catch (e: Exception) {
                // Android 12+ refuses to start from the background without an exact alarm.
                Notifications.post(ctx, "Attendance paused", "Open Exist so your attendance can be marked.")
            }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var standbyUntil = 0L
    private val loop = object : Runnable {
        override fun run() {
            refresh()
            handler.postDelayed(this, 30_000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TEACHER_STANDBY -> standbyUntil = System.currentTimeMillis() + 10 * 60_000
            ACTION_TEACHER_ACTIVE -> teacherActive = true
            ACTION_TEACHER_STOP -> teacherActive = false
        }
        goForeground()
        handler.removeCallbacks(loop)
        handler.post(loop)
        return START_STICKY
    }

    private fun goForeground() {
        val text = when {
            teacherActive -> "Class running: taking attendance"
            System.currentTimeMillis() < standbyUntil -> "Class starting…"
            else -> "Attendance active during class"
        }
        val n = Notifications.build(this, "Exist", text, ongoing = true)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    private fun refresh() {
        val inClass = StudentAgent.inWindow(this)
        val agent = StudentAgent.get(this)
        if (inClass) agent.startForegroundScan() else agent.stopForegroundScan()
        val needed = teacherActive || inClass || System.currentTimeMillis() < standbyUntil
        if (!needed) {
            Alarms.scheduleStudent(this)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        } else {
            goForeground()
        }
    }

    override fun onDestroy() {
        handler.removeCallbacks(loop)
        StudentAgent.get(this).stopForegroundScan()
        super.onDestroy()
    }
}

object Notifications {
    private const val CHANNEL = "attendance"

    private fun channel(ctx: Context) {
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL) == null) {
                nm.createNotificationChannel(NotificationChannel(CHANNEL, "Attendance", NotificationManager.IMPORTANCE_LOW))
            }
        }
    }

    fun build(ctx: Context, title: String, text: String, ongoing: Boolean = false): Notification {
        channel(ctx)
        val open = PendingIntent.getActivity(
            ctx, 0, Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(ctx))
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(ongoing)
            .setContentIntent(open)
            .build()
    }

    fun post(ctx: Context, title: String, text: String) {
        try {
            ctx.getSystemService(NotificationManager::class.java).notify((title + text).hashCode(), build(ctx, title, text))
        } catch (_: SecurityException) {}
    }
}
