package edu.exist.exist

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/**
 * The phone's identity: a P-256 key generated inside the TEE/StrongBox. It can sign but
 * can never be exported, so an account cannot be cloned to another phone.
 */
object DeviceKeys {
    private const val ALIAS = "exist_device_key_v1"
    private val ATTESTATION_CHALLENGE = "exist-device-key-v1".toByteArray()

    private fun ks() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    @Synchronized
    fun ensure() {
        if (ks().containsAlias(ALIAS)) return
        fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setAttestationChallenge(ATTESTATION_CHALLENGE)
            .apply { if (strongBox && Build.VERSION.SDK_INT >= 28) setIsStrongBoxBacked(true) }
            .build()
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        try {
            gen.initialize(spec(true))
            gen.generateKeyPair()
        } catch (e: Exception) {
            // No StrongBox (or a buggy one): the TEE is still hardware-backed.
            gen.initialize(spec(false))
            gen.generateKeyPair()
        }
    }

    fun publicKeySpki(): String {
        ensure()
        return Base64.encodeToString(ks().getCertificate(ALIAS).publicKey.encoded, Base64.NO_WRAP)
    }

    fun sign(data: ByteArray): ByteArray {
        ensure()
        val key = ks().getKey(ALIAS, null) as PrivateKey
        return Signature.getInstance("SHA256withECDSA").run {
            initSign(key)
            update(data)
            sign()
        }
    }

    /** Key attestation certificate chain; the server checks it chains to Google's root. */
    fun attestation(): String {
        ensure()
        val chain = ks().getCertificateChain(ALIAS) ?: return ""
        val arr = JSONArray()
        chain.forEach { arr.put(Base64.encodeToString(it.encoded, Base64.NO_WRAP)) }
        return JSONObject().put("type", "android-key").put("chain", arr).toString()
    }

    fun reset() {
        ks().deleteEntry(ALIAS)
    }
}
