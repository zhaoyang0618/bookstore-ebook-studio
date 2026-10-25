package com.bookstore.ebook_studio

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var recorderBridge: RecorderBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 录课桥接（设计文档 3.5）：需要 Activity 来处理麦克风权限，手动注册
        recorderBridge = RecorderBridge(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            RecorderBridge.CHANNEL,
        ).setMethodCallHandler(recorderBridge)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == RecorderBridge.REQUEST_CODE_MIC) {
            recorderBridge?.onMicPermissionResult(
                grantResults.isNotEmpty() && grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED)
        } else {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }
}
