package edu.exist.exist

import java.nio.ByteBuffer
import java.util.UUID

/** Byte layouts of protocol v1 (see backend/src/crypto/protocol.ts). */
object Proto {
    const val VERSION = 1
    val CHALLENGE_CHAR: UUID = UUID.fromString("6a1f0001-7e57-4e1a-9d2b-3c5e0b1d7a01")
    val CHECKIN_CHAR: UUID = UUID.fromString("6a1f0002-7e57-4e1a-9d2b-3c5e0b1d7a01")
    const val APPLE_ID = 0x004C

    const val PHASE_ARRIVE = 1
    const val PHASE_MID = 2
    const val PHASE_END = 3
    fun phaseName(p: Int) = when (p) { PHASE_MID -> "MID"; PHASE_END -> "END"; else -> "ARRIVE" }

    data class Challenge(val shortId: Long, val slot: Long, val token: Long, val phase: Int, val windowIndex: Int)

    fun decodeChallenge(b: ByteArray?): Challenge? {
        if (b == null || b.size != 19 || b[0].toInt() != VERSION) return null
        val bb = ByteBuffer.wrap(b)
        bb.get()
        return Challenge(
            shortId = bb.int.toLong() and 0xffffffffL,
            slot = bb.long,
            token = bb.int.toLong() and 0xffffffffL,
            phase = bb.get().toInt() and 0xff,
            windowIndex = bb.get().toInt() and 0xff,
        )
    }

    fun uuidBytes(u: UUID): ByteArray =
        ByteBuffer.allocate(16).putLong(u.mostSignificantBits).putLong(u.leastSignificantBits).array()

    fun uuidFrom(b: ByteArray, off: Int = 0): UUID {
        val bb = ByteBuffer.wrap(b, off, 16)
        return UUID(bb.long, bb.long)
    }

    fun checkinBody(c: Challenge, deviceId: UUID, nonce: ByteArray, clientTs: Long): ByteArray =
        ByteBuffer.allocate(49)
            .put(VERSION.toByte())
            .putInt(c.shortId.toInt())
            .putLong(c.slot)
            .putInt(c.token.toInt())
            .put(uuidBytes(deviceId))
            .put(nonce)
            .putLong(clientTs)
            .array()

    fun signedMessage(body: ByteArray) = "EXST-CHK".toByteArray(Charsets.US_ASCII) + body

    fun checkin(body: ByteArray, sig: ByteArray) = body + byteArrayOf(sig.size.toByte()) + sig

    /** iBeacon manufacturer payload (without the 0x004C company id). */
    fun iBeacon(uuid: UUID, major: Int = 0, minor: Int = 0, txPower: Int = -59): ByteArray =
        ByteBuffer.allocate(23).put(0x02).put(0x15).put(uuidBytes(uuid))
            .putShort(major.toShort()).putShort(minor.toShort()).put(txPower.toByte()).array()

    fun parseIBeacon(md: ByteArray?): UUID? =
        if (md != null && md.size >= 18 && md[0] == 0x02.toByte() && md[1] == 0x15.toByte()) uuidFrom(md, 2) else null
}
