package edu.exist.exist

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

/** Bluetooth identities of one subject group (two variants, see protocol "toggle"). */
data class Target(val service: List<UUID>, val region: List<UUID>)

/**
 * Teacher phone as a BLE peripheral:
 *  - advertising set 1 (connectable): the subject's service UUID for the current toggle;
 *  - advertising set 2: iBeacon with the subject's region UUID (wakes iPhones);
 *  - GATT server hosting every subject service (both toggles) with CHALLENGE (read) and
 *    CHECKIN (write) characteristics.
 * A class with several subject groups rotates through them every second.
 * Check-in writes are answered only after Dart has verified them (respond()), so the
 * student's phone learns whether it was accepted.
 */
@SuppressLint("MissingPermission")
class TeacherPeripheral(
    private val ctx: Context,
    private val onCheckin: (id: Int, data: ByteArray) -> Unit,
    private val onError: (String) -> Unit,
) {
    companion object {
        const val STATUS_NOT_IN_CLASS = 0x80
        const val STATUS_RETRY = 0x81
    }

    private val main = Handler(Looper.getMainLooper())
    private val manager = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private var server: BluetoothGattServer? = null
    private var serviceSet: AdvertisingSet? = null
    private var beaconSet: AdvertisingSet? = null
    @Volatile private var challenge = ByteArray(0)
    private var targets: List<Target> = emptyList()
    private var toggle = 0
    private var rotation = 0
    private val longWrites = HashMap<String, ByteArrayOutputStream>()
    private val serviceQueue = ArrayDeque<BluetoothGattService>()

    private data class Pending(val device: BluetoothDevice, val requestId: Int, val offset: Int)
    private val pending = HashMap<Int, Pending>()
    private val nextId = AtomicInteger(1)

    private val serviceCb = object : AdvertisingSetCallback() {
        override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) {
            if (status != ADVERTISE_SUCCESS) onError("advertising failed ($status)") else serviceSet = set
        }
    }
    private val beaconCb = object : AdvertisingSetCallback() {
        override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) {
            if (status != ADVERTISE_SUCCESS) onError("beacon failed ($status)") else beaconSet = set
        }
    }

    private val rotate = object : Runnable {
        override fun run() {
            if (targets.size > 1) {
                rotation = (rotation + 1) % targets.size
                pushAdvertising()
            }
            main.postDelayed(this, 1000)
        }
    }

    private val gattCb = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            main.post { addNextService() }
        }

        override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, c: BluetoothGattCharacteristic) {
            val value = challenge
            if (c.uuid != Proto.CHALLENGE_CHAR || offset > value.size) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
                return
            }
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value.copyOfRange(offset, value.size))
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, c: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?,
        ) {
            val ok = c.uuid == Proto.CHECKIN_CHAR && value != null && value.size <= 256
            if (!ok) {
                if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                return
            }
            if (preparedWrite) {
                // Long write (small MTU): collect the pieces until execute.
                val buf = longWrites.getOrPut(device.address) { ByteArrayOutputStream() }
                if (buf.size() == offset) buf.write(value!!)
                if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                return
            }
            deliver(device, requestId, offset, value!!.copyOf(), responseNeeded)
        }

        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            val buf = longWrites.remove(device.address)
            if (execute && buf != null) deliver(device, requestId, 0, buf.toByteArray(), true)
            else server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothGatt.STATE_DISCONNECTED) longWrites.remove(device.address)
        }
    }

    /** Hand the check-in to Dart; the GATT reply waits for its verdict (max 5 s). */
    private fun deliver(device: BluetoothDevice, requestId: Int, offset: Int, data: ByteArray, responseNeeded: Boolean) {
        val id = nextId.getAndIncrement()
        if (responseNeeded) {
            synchronized(pending) { pending[id] = Pending(device, requestId, offset) }
            main.postDelayed({ respond(id, 2) }, 5000)
        }
        main.post { onCheckin(id, data) }
    }

    /** code: 0 accepted, 1 not in this class, 2 invalid / try again. */
    fun respond(id: Int, code: Int) {
        val p = synchronized(pending) { pending.remove(id) } ?: return
        val status = when (code) { 0 -> BluetoothGatt.GATT_SUCCESS; 1 -> STATUS_NOT_IN_CLASS; else -> STATUS_RETRY }
        try {
            server?.sendResponse(p.device, p.requestId, status, p.offset, null)
        } catch (e: Exception) {
            Log.w("Exist", "respond failed", e)
        }
    }

    fun start(newTargets: List<Target>, newToggle: Int, initialChallenge: ByteArray) {
        stop()
        challenge = initialChallenge
        targets = newTargets
        toggle = newToggle
        rotation = 0
        val adapter = manager.adapter ?: return onError("no Bluetooth")
        if (!adapter.isEnabled) return onError("Bluetooth is off")
        val advertiser = adapter.bluetoothLeAdvertiser ?: return onError("this phone cannot advertise")

        server = manager.openGattServer(ctx, gattCb) ?: return onError("could not open GATT server")
        // Services must be added one at a time (wait for onServiceAdded).
        for (t in targets) for (u in t.service) {
            val svc = BluetoothGattService(u, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            svc.addCharacteristic(BluetoothGattCharacteristic(Proto.CHALLENGE_CHAR, BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
            svc.addCharacteristic(BluetoothGattCharacteristic(Proto.CHECKIN_CHAR, BluetoothGattCharacteristic.PROPERTY_WRITE, BluetoothGattCharacteristic.PERMISSION_WRITE))
            serviceQueue.addLast(svc)
        }
        addNextService()

        val params = { connectable: Boolean ->
            AdvertisingSetParameters.Builder()
                .setLegacyMode(true).setConnectable(connectable).setScannable(connectable)
                .setInterval(AdvertisingSetParameters.INTERVAL_LOW)
                .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_MEDIUM)
                .build()
        }
        advertiser.startAdvertisingSet(params(true), serviceData(), null, null, null, serviceCb)
        advertiser.startAdvertisingSet(params(false), beaconData(), null, null, null, beaconCb)
        main.postDelayed(rotate, 1000)
    }

    private fun addNextService() {
        val next = serviceQueue.removeFirstOrNull() ?: return
        if (server?.addService(next) != true) main.postDelayed({ addNextService() }, 100)
    }

    private fun current() = targets[rotation % targets.size]

    private fun serviceData() =
        AdvertiseData.Builder().addServiceUuid(ParcelUuid(current().service[toggle])).setIncludeDeviceName(false).build()

    private fun beaconData() =
        AdvertiseData.Builder().addManufacturerData(Proto.APPLE_ID, Proto.iBeacon(current().region[toggle])).setIncludeDeviceName(false).build()

    private fun pushAdvertising() {
        try {
            serviceSet?.setAdvertisingData(serviceData())
            beaconSet?.setAdvertisingData(beaconData())
        } catch (e: Exception) {
            Log.w("Exist", "advertising update failed", e)
        }
    }

    fun update(newToggle: Int, newChallenge: ByteArray) {
        challenge = newChallenge
        if (newToggle != toggle) {
            toggle = newToggle
            pushAdvertising()
        }
    }

    fun stop() {
        main.removeCallbacks(rotate)
        val adv = manager.adapter?.bluetoothLeAdvertiser
        try {
            adv?.stopAdvertisingSet(serviceCb)
            adv?.stopAdvertisingSet(beaconCb)
        } catch (_: Exception) {}
        serviceSet = null
        beaconSet = null
        synchronized(pending) {
            for (id in pending.keys.toList()) respond(id, 2)
        }
        try {
            server?.close()
        } catch (_: Exception) {}
        server = null
        serviceQueue.clear()
        longWrites.clear()
    }
}
