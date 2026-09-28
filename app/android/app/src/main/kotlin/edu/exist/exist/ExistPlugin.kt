package edu.exist.exist

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Dart <-> native bridge. Method names match lib/core/native.dart. */
class ExistPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var ctx: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private var teacher: TeacherPeripheral? = null

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        ctx = b.applicationContext
        methods = MethodChannel(b.binaryMessenger, "exist/native").also { it.setMethodCallHandler(this) }
        events = EventChannel(b.binaryMessenger, "exist/native/events").also { it.setStreamHandler(this) }
        StudentAgent.listener = { r -> emit(mapOf("type" to "studentCheckin", "result" to r.toString())) }
        StudentAgent.registerBackgroundScan(ctx)
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        StudentAgent.listener = null
    }

    override fun onListen(args: Any?, s: EventChannel.EventSink?) { sink = s }
    override fun onCancel(args: Any?) { sink = null }
    private fun emit(e: Map<String, Any?>) = main.post { sink?.success(e) }

    @SuppressLint("BatteryLife")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "keys.publicKey" -> result.success(DeviceKeys.publicKeySpki())
                "keys.sign" -> result.success(DeviceKeys.sign(call.arguments as ByteArray))
                "keys.attest" -> result.success(DeviceKeys.attestation())
                "keys.reset" -> { DeviceKeys.reset(); result.success(null) }

                "system.state" -> {
                    val adapter = (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
                    val pm = ctx.getSystemService(PowerManager::class.java)
                    result.success(mapOf(
                        "bluetooth" to when { adapter == null -> "unsupported"; adapter.isEnabled -> "on"; else -> "off" },
                        "canAdvertise" to (adapter?.isMultipleAdvertisementSupported == true),
                        "backgroundOk" to (pm.isIgnoringBatteryOptimizations(ctx.packageName) && Alarms.canExact(ctx)),
                        "exactAlarms" to Alarms.canExact(ctx),
                        "sdk" to Build.VERSION.SDK_INT,
                        "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
                        // Per-app id, reset on factory reset. Shown to admins only; spoofable, never trusted.
                        "installId" to Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ANDROID_ID),
                    ))
                }
                "system.requestBackgroundExemption" -> {
                    val pm = ctx.getSystemService(PowerManager::class.java)
                    if (!pm.isIgnoringBatteryOptimizations(ctx.packageName)) {
                        ctx.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${ctx.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    } else if (!Alarms.canExact(ctx) && Build.VERSION.SDK_INT >= 31) {
                        ctx.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${ctx.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                    result.success(null)
                }

                "teacher.start" -> {
                    val p = teacher ?: TeacherPeripheral(ctx,
                        onCheckin = { id, data -> emit(mapOf("type" to "checkin", "id" to id, "data" to data)) },
                        onError = { msg -> emit(mapOf("type" to "teacherError", "message" to msg)) },
                    ).also { teacher = it }
                    val targets = (call.argument<List<Map<String, String>>>("targets") ?: emptyList()).map { t ->
                        Target(listOf(UUID.fromString(t["service0"]), UUID.fromString(t["service1"])), listOf(UUID.fromString(t["region0"]), UUID.fromString(t["region1"])))
                    }
                    if (targets.isEmpty()) throw IllegalArgumentException("no subjects")
                    p.start(targets, call.argument<Int>("toggle") ?: 0, call.argument<ByteArray>("challenge")!!)
                    AttendanceService.start(ctx, AttendanceService.ACTION_TEACHER_ACTIVE)
                    result.success(null)
                }
                "teacher.update" -> {
                    teacher?.update(call.argument<Int>("toggle") ?: 0, call.argument<ByteArray>("challenge")!!)
                    result.success(null)
                }
                "teacher.respond" -> {
                    teacher?.respond(call.argument<Int>("id")!!, call.argument<Int>("code")!!)
                    result.success(null)
                }
                "system.notify" -> {
                    Notifications.post(ctx, call.argument<String>("title") ?: "Exist", call.argument<String>("body") ?: "")
                    result.success(null)
                }
                "teacher.stop" -> {
                    teacher?.stop()
                    teacher = null
                    AttendanceService.start(ctx, AttendanceService.ACTION_TEACHER_STOP)
                    result.success(null)
                }
                "teacher.scheduleAlarms" -> {
                    val items = JSONArray()
                    (call.argument<List<Map<String, Any>>>("items") ?: emptyList()).forEach { items.put(JSONObject(it)) }
                    Alarms.scheduleTeacher(ctx, items)
                    result.success(null)
                }

                "student.configure" -> {
                    val subjects = JSONArray()
                    (call.argument<List<Map<String, Any>>>("subjects") ?: emptyList()).forEach { subjects.put(JSONObject(it)) }
                    val windows = JSONArray()
                    (call.argument<List<Map<String, Any>>>("windows") ?: emptyList()).forEach { windows.put(JSONObject(it)) }
                    StudentAgent.configure(ctx, call.argument<String>("deviceId")!!, subjects, windows)
                    StudentAgent.registerBackgroundScan(ctx)
                    Alarms.scheduleStudent(ctx)
                    result.success(null)
                }
                "student.log" -> {
                    val log = StudentAgent.log(ctx)
                    result.success((0 until log.length()).map { i ->
                        val o = log.getJSONObject(i)
                        o.keys().asSequence().associateWith { k -> o.get(k).takeUnless { it == JSONObject.NULL } }
                    })
                }
                "student.checkNow" -> {
                    StudentAgent.get(ctx).checkNow { r ->
                        result.success(r.keys().asSequence().associateWith { k -> r.get(k).takeUnless { it == JSONObject.NULL } })
                    }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("native", e.message ?: e.toString(), null)
        }
    }
}
