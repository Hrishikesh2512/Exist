package edu.exist.exist

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.util.UUID
import kotlin.random.Random

/** One subject group the student studies (from Dart's student.configure). */
data class Subject(val sectionId: String, val title: String, val service: List<UUID>)

/** A timetabled class time, during which the foreground service listens hard. */
data class Window(val from: Long, val to: Long, val title: String)

/**
 * Checks the student in by itself, for any class of their own subjects (timetabled or started
 * on the spot) and never for other classes. The teacher's phone advertises the subject's
 * service UUID in one of two variants; a change of variant means "a check just opened", so
 * the phone connects, reads the challenge, signs it with the hardware key and writes it back.
 *
 * Three ways in, one shared instance: an always-on low-power scan delivered by the system even
 * when the app is closed (ScanReceiver), the foreground service during timetabled classes, and
 * the "Check in now" button.
 */
@SuppressLint("MissingPermission")
class StudentAgent private constructor(private val ctx: Context) {
    companion object {
        private const val PREFS = "exist_student"
        private const val RETRY_MS = 15_000L
        private const val FORGET_MS = 10 * 60_000L // teacher gone this long: next sighting is a new class
        private const val ATTEMPT_TIMEOUT_MS = 15_000L
        const val MIN_RSSI = -95

        @Volatile private var instance: StudentAgent? = null
        fun get(ctx: Context): StudentAgent = instance ?: synchronized(this) { instance ?: StudentAgent(ctx.applicationContext).also { instance = it } }

        var listener: ((JSONObject) -> Unit)? = null

        private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, 0)

        fun configure(ctx: Context, deviceId: String, subjects: JSONArray, windows: JSONArray) {
            prefs(ctx).edit().putString("deviceId", deviceId).putString("subjects", subjects.toString()).putString("windows", windows.toString()).apply()
        }

        fun subjects(ctx: Context): List<Subject> {
            val arr = JSONArray(prefs(ctx).getString("subjects", "[]"))
            return (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                Subject(o.getString("sectionId"), o.optString("title"), listOf(UUID.fromString(o.getString("service0")), UUID.fromString(o.getString("service1"))))
            }
        }

        fun windows(ctx: Context): List<Window> {
            val arr = JSONArray(prefs(ctx).getString("windows", "[]"))
            return (0 until arr.length()).map { i -> arr.getJSONObject(i).let { Window(it.getLong("from"), it.getLong("to"), it.optString("title")) } }
        }

        fun inWindow(ctx: Context, now: Long = System.currentTimeMillis()) = windows(ctx).any { now in it.from..it.to }

        fun log(ctx: Context): JSONArray = JSONArray(prefs(ctx).getString("log", "[]"))

        private fun done(ctx: Context): MutableSet<String> = prefs(ctx).getStringSet("done", emptySet())!!.toMutableSet()

        private fun filters(ctx: Context) = subjects(ctx).flatMap { s -> s.service.map { ScanFilter.Builder().setServiceUuid(ParcelUuid(it)).build() } }

        private fun scanIntent(ctx: Context): PendingIntent = PendingIntent.getBroadcast(
            ctx, 7, Intent(ctx, ScanReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0),
        )

        /**
         * Always-on background scan handled by the Bluetooth chip / system: costs very little
         * battery and delivers results even when the app is closed. Survives until reboot
         * (BootReceiver re-registers it).
         */
        fun registerBackgroundScan(ctx: Context) {
            val scanner = (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter?.bluetoothLeScanner ?: return
            val pi = scanIntent(ctx)
            try { scanner.stopScan(pi) } catch (_: Exception) {}
            val f = filters(ctx)
            if (f.isEmpty()) return
            try {
                scanner.startScan(f, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER).setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES).build(), pi)
            } catch (_: Exception) {}
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val prefs = prefs(ctx)
    private val adapter = (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    @Volatile private var busy = false
    private var scanning = false

    private val scanCb = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) = handle(result, null)
        override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach { handle(it, null) }
    }

    /** Fast scanning while the foreground service runs (timetabled class times). */
    fun startForegroundScan() {
        if (scanning || adapter?.isEnabled != true) return
        val f = filters(ctx)
        if (f.isEmpty()) return
        try {
            adapter.bluetoothLeScanner?.startScan(f, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build(), scanCb)
            scanning = true
        } catch (_: Exception) {}
    }

    fun stopForegroundScan() {
        if (scanning) try { adapter?.bluetoothLeScanner?.stopScan(scanCb) } catch (_: Exception) {}
        scanning = false
    }

    // ---- per-subject state, persisted so it survives the app being killed
    private fun state(sectionId: String): JSONObject = JSONObject(prefs.getString("state", "{}")).optJSONObject(sectionId) ?: JSONObject()
    private fun saveState(sectionId: String, o: JSONObject) {
        val all = JSONObject(prefs.getString("state", "{}"))
        all.put(sectionId, o)
        prefs.edit().putString("state", all.toString()).apply()
    }

    /** A scan result arrived. [onDone] is called when handling (possibly a check-in) finishes. */
    fun handle(r: ScanResult, onDone: (() -> Unit)?) {
        val uuids = r.scanRecord?.serviceUuids?.map { it.uuid } ?: emptyList()
        val subject = subjects(ctx).firstOrNull { s -> s.service.any { it in uuids } }
        if (subject == null || r.rssi < MIN_RSSI) {
            onDone?.invoke()
            return
        }
        val toggle = if (subject.service[1] in uuids) 1 else 0
        val now = System.currentTimeMillis()
        val st = state(subject.sectionId)
        if (now - st.optLong("lastSeen") > FORGET_MS) st.remove("handled")
        st.put("lastSeen", now)
        val needed = st.optInt("handled", -1) != toggle
        val backoffOk = now - st.optLong("lastAttempt") >= st.optLong("backoff", 0)
        if (!needed || !backoffOk || busy) {
            saveState(subject.sectionId, st)
            onDone?.invoke()
            return
        }
        st.put("lastAttempt", now)
        saveState(subject.sectionId, st)
        // The whole class sees the change at once: spread connections over a few seconds.
        main.postDelayed({
            attempt(subject, r.device, force = false) { res ->
                val s2 = state(subject.sectionId)
                if (res.optBoolean("ok") || res.optBoolean("skipped") || res.optString("error") == "not in this class") {
                    s2.put("handled", toggle)
                    s2.put("backoff", 0)
                } else {
                    s2.put("backoff", RETRY_MS + Random.nextLong(0, 5_000))
                }
                saveState(subject.sectionId, s2)
                onDone?.invoke()
            }
        }, Random.nextLong(0, 3_000))
    }

    /** One connect → read challenge → sign → write cycle. */
    fun attempt(s: Subject, device: BluetoothDevice, force: Boolean, done: (JSONObject) -> Unit) {
        if (busy) return done(JSONObject().put("ok", false).put("error", "busy"))
        val deviceId = prefs.getString("deviceId", null) ?: return done(JSONObject().put("ok", false).put("error", "phone not registered"))
        busy = true
        var gatt: BluetoothGatt? = null
        var finished = false
        var challenge: Proto.Challenge? = null
        var checkinChar: BluetoothGattCharacteristic? = null
        fun finish(result: JSONObject) {
            if (finished) return
            finished = true
            busy = false
            try { gatt?.disconnect(); gatt?.close() } catch (_: Exception) {}
            result.put("sectionId", s.sectionId).put("title", s.title).put("at", System.currentTimeMillis())
            challenge?.let { result.put("phase", Proto.phaseName(it.phase)).put("windowIndex", it.windowIndex).put("session", it.shortId) }
            if (!result.optBoolean("skipped")) record(result)
            main.post { done(result) }
        }
        main.postDelayed({ finish(JSONObject().put("ok", false).put("error", "timed out")) }, ATTEMPT_TIMEOUT_MS)

        val cb = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) g.requestMtu(185)
                else if (newState == BluetoothProfile.STATE_DISCONNECTED) finish(JSONObject().put("ok", false).put("error", "disconnected ($status)"))
            }

            override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
                g.discoverServices()
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                val svc = s.service.firstNotNullOfOrNull { g.getService(it) }
                    ?: return finish(JSONObject().put("ok", false).put("error", "not this class"))
                checkinChar = svc.getCharacteristic(Proto.CHECKIN_CHAR)
                g.readCharacteristic(svc.getCharacteristic(Proto.CHALLENGE_CHAR))
            }

            @Deprecated("pre-33 callback")
            override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
                @Suppress("DEPRECATION")
                onRead(g, c.value, status)
            }

            override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) = onRead(g, value, status)

            private fun onRead(g: BluetoothGatt, value: ByteArray?, status: Int) {
                val ch = Proto.decodeChallenge(value)
                if (status != BluetoothGatt.GATT_SUCCESS || ch == null) return finish(JSONObject().put("ok", false).put("error", "bad challenge"))
                challenge = ch
                val doneSet = done(ctx)
                val arrived = doneSet.any { it.startsWith("${ch.shortId}|") }
                val doneKey = "${ch.shortId}|${Proto.phaseName(ch.phase)}|${ch.windowIndex}"
                if ((ch.phase == Proto.PHASE_ARRIVE && arrived && !force) || doneKey in doneSet) {
                    return finish(JSONObject().put("ok", false).put("skipped", true))
                }
                val nonce = ByteArray(8).also { SecureRandom().nextBytes(it) }
                val body = Proto.checkinBody(ch, UUID.fromString(deviceId), nonce, System.currentTimeMillis())
                val payload = try {
                    Proto.checkin(body, DeviceKeys.sign(Proto.signedMessage(body)))
                } catch (e: Exception) {
                    return finish(JSONObject().put("ok", false).put("error", "signing failed"))
                }
                val w = checkinChar ?: return finish(JSONObject().put("ok", false).put("error", "not this class"))
                if (Build.VERSION.SDK_INT >= 33) {
                    g.writeCharacteristic(w, payload, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
                } else {
                    @Suppress("DEPRECATION")
                    w.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                    @Suppress("DEPRECATION")
                    w.value = payload
                    @Suppress("DEPRECATION")
                    g.writeCharacteristic(w)
                }
            }

            override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
                val ch = challenge
                when {
                    status == BluetoothGatt.GATT_SUCCESS && ch != null -> {
                        val set = done(ctx).apply { add("${ch.shortId}|${Proto.phaseName(ch.phase)}|${ch.windowIndex}") }
                        prefs.edit().putStringSet("done", trimmed(set)).apply()
                        finish(JSONObject().put("ok", true))
                    }
                    // Android teacher answers 0x80, iPhone teacher 0x08 (insufficient authorization).
                    status == TeacherPeripheral.STATUS_NOT_IN_CLASS || status == 0x08 ->
                        finish(JSONObject().put("ok", false).put("error", "not in this class"))
                    else -> finish(JSONObject().put("ok", false).put("error", "not accepted ($status), retrying"))
                }
            }
        }
        gatt = device.connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE)
    }

    /** Keep the done-set from growing forever (it is only needed for recent classes). */
    private fun trimmed(set: Set<String>): Set<String> = if (set.size <= 300) set else set.toList().takeLast(300).toSet()

    private fun record(r: JSONObject) {
        val log = log(ctx)
        log.put(r)
        val out = JSONArray()
        for (i in maxOf(0, log.length() - 200) until log.length()) out.put(log.get(i))
        prefs.edit().putString("log", out.toString()).apply()
        if (r.optBoolean("ok")) Notifications.post(ctx, "Attendance marked", "${r.optString("title")} · ${r.optString("phase").lowercase()}")
        listener?.invoke(r)
    }

    /** "Check in now" button: find the teacher's phone of any of my subjects and check in. */
    fun checkNow(done: (JSONObject) -> Unit) {
        if (adapter?.isEnabled != true) return done(JSONObject().put("ok", false).put("error", "Bluetooth is off"))
        val scanner = adapter.bluetoothLeScanner ?: return done(JSONObject().put("ok", false).put("error", "no scanner"))
        val f = filters(ctx)
        if (f.isEmpty()) return done(JSONObject().put("ok", false).put("error", "no subjects this semester"))
        var found = false
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                if (found) return
                val uuids = result.scanRecord?.serviceUuids?.map { it.uuid } ?: emptyList()
                val s = subjects(ctx).firstOrNull { sub -> sub.service.any { it in uuids } } ?: return
                found = true
                try { scanner.stopScan(this) } catch (_: Exception) {}
                attempt(s, result.device, force = true, done)
            }
        }
        scanner.startScan(f, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), cb)
        main.postDelayed({
            if (!found) {
                found = true
                try { scanner.stopScan(cb) } catch (_: Exception) {}
                done(JSONObject().put("ok", false).put("error", "no class of yours nearby"))
            }
        }, 10_000)
    }
}

/** Receives the system's background scan results, even when the app is closed. */
class ScanReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val results: List<ScanResult> = (
            if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableArrayListExtra(android.bluetooth.le.BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT, ScanResult::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra(android.bluetooth.le.BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT)
            }
        ) ?: return
        val first = results.firstOrNull() ?: return
        // Keep the process alive while a check-in runs (background broadcasts may take up to ~30 s).
        val pending = goAsync()
        var finished = false
        val finish = {
            if (!finished) {
                finished = true
                pending.finish()
            }
        }
        Handler(Looper.getMainLooper()).postDelayed({ finish() }, 25_000)
        StudentAgent.get(ctx).handle(first) { finish() }
    }
}
