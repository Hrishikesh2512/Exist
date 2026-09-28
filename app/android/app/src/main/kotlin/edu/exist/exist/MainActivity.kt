package edu.exist.exist

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

class MainActivity : FlutterActivity() {
    // Reuse the engine created in ExistApplication; closing the screen must not kill a running class.
    override fun provideFlutterEngine(context: Context): FlutterEngine? = FlutterEngineCache.getInstance().get(ExistApplication.ENGINE_ID)
    override fun shouldDestroyEngineWithHost(): Boolean = false
}
