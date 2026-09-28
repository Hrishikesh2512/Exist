package edu.exist.exist

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Creates one Flutter engine per process and keeps it alive without an Activity, so the
 * teacher's class keeps running (and auto-starts from an alarm) with the screen off.
 */
class ExistApplication : Application() {
    companion object {
        const val ENGINE_ID = "main"
    }

    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        engine.plugins.add(ExistPlugin())
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }
}
