package com.example.map_app

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.map_app/pdf"
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getInitialPdfPath") {
                val intent = intent
                if (intent != null && (intent.action == Intent.ACTION_VIEW || intent.action == Intent.ACTION_SEND)) {
                    val uri = intent.data
                    if (uri != null) {
                        result.success(uri.toString())
                    } else {
                        result.success(null)
                    }
                } else {
                    result.success(null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
    
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Notify Flutter about the new intent
        val uri = intent.data
        if (uri != null) {
            val flutterEngine = flutterEngine
            if (flutterEngine != null) {
                MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                    .invokeMethod("onNewPdf", uri.toString())
            }
        }
    }
}
