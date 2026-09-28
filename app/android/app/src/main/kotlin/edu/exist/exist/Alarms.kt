package edu.exist.exist

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONArray

/**
 * Wakes the app at class time. Exact alarms are allowed to start a foreground service
 * from the background; inexact ones may be late and are not.
 */
object Alarms {
    private const val STUDENT_RC = 1000
    private const val TEACHER_RC = 2000

    fun canExact(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 31 || ctx.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()

    private fun set(ctx: Context, at: Long, rc: Int, action: String) {
        val am = ctx.getSystemService(AlarmManager::class.java)
        val pi = PendingIntent.getBroadcast(
            ctx, rc, Intent(ctx, AlarmReceiver::class.java).setAction(action),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        if (canExact(ctx)) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
    }

    /** Next timetabled class time (or now, if one is on). Classes started on the spot are
     *  caught by the always-on background scan instead. */
    fun scheduleStudent(ctx: Context) {
        val now = System.currentTimeMillis()
        val windows = StudentAgent.windows(ctx)
        if (windows.any { now in it.from..it.to }) {
            AttendanceService.start(ctx, AttendanceService.ACTION_STUDENT)
            return
        }
        windows.filter { it.from > now }.minByOrNull { it.from }?.let { set(ctx, it.from, STUDENT_RC, AttendanceService.ACTION_STUDENT) }
    }

    fun scheduleTeacher(ctx: Context, items: JSONArray) {
        ctx.getSharedPreferences("exist_teacher", 0).edit().putString("alarms", items.toString()).apply()
        rearmTeacher(ctx)
    }

    fun rearmTeacher(ctx: Context) {
        val arr = JSONArray(ctx.getSharedPreferences("exist_teacher", 0).getString("alarms", "[]"))
        val now = System.currentTimeMillis()
        val next = (0 until arr.length()).map { arr.getJSONObject(it).getLong("at") }.filter { it > now }.minOrNull() ?: return
        set(ctx, next, TEACHER_RC, AttendanceService.ACTION_TEACHER_STANDBY)
    }
}

class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        when (intent.action) {
            AttendanceService.ACTION_TEACHER_STANDBY -> {
                // Starting the service also starts the process, whose cached Flutter engine
                // runs the teacher autopilot that begins the class.
                AttendanceService.start(ctx, AttendanceService.ACTION_TEACHER_STANDBY)
                Alarms.rearmTeacher(ctx)
            }
            else -> AttendanceService.start(ctx, AttendanceService.ACTION_STUDENT)
        }
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        Alarms.scheduleStudent(ctx)
        Alarms.rearmTeacher(ctx)
        StudentAgent.registerBackgroundScan(ctx)
    }
}
