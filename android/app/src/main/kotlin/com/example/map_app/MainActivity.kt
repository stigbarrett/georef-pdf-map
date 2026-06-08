package com.example.map_app

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream

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
                        val filePath = copyUriToCache(uri)
                        result.success(filePath)
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
                val filePath = copyUriToCache(uri)
                MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                    .invokeMethod("onNewPdf", filePath)
            }
        }
    }
    
    private fun copyUriToCache(uri: Uri): String? {
        return try {
            val inputStream: InputStream? = contentResolver.openInputStream(uri)
            if (inputStream == null) return null
            
            val fileName = getFileName(uri)
            val tempFile = File(cacheDir, fileName ?: "temp.pdf")
            
            FileOutputStream(tempFile).use { output ->
                inputStream.copyTo(output)
            }
            inputStream.close()
            
            tempFile.absolutePath
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }
    
    private fun getFileName(uri: Uri): String? {
        var result: String? = null
        if (uri.scheme == "content") {
            val cursor = contentResolver.query(uri, null, null, null, null)
            cursor?.use {
                if (it.moveToFirst()) {
                    val index = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) {
                        result = it.getString(index)
                    }
                }
            }
        }
        if (result == null) {
            result = uri.path
            val cut = result?.lastIndexOf('/')
            if (cut != -1) {
                result = result?.substring(cut!! + 1)
            }
        }
        return result
    }
}
