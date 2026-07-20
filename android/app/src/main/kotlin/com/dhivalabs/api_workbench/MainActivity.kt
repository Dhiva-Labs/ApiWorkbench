package com.dhivalabs.api_workbench

import android.media.MediaPlayer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "apiworkbench/sound")
            .setMethodCallHandler { call, result ->
                if (call.method == "play") {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("no_path", "Missing sound path", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val player = MediaPlayer()
                        player.setDataSource(path)
                        player.setOnPreparedListener { it.start() }
                        player.setOnCompletionListener { it.release() }
                        player.setOnErrorListener { p, _, _ -> p.release(); true }
                        player.prepareAsync()
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("play_failed", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
