//
//  MediaProjection 桥接（设计文档 3.5：Android 平板端屏幕录制）。
//
//  通过 Flutter Platform Channel 暴露 startRecording / stopRecording 两个方法，
//  内部调用 MediaProjection API 录制屏幕并编码为 MP4。
//
//  Dart 侧见 lib/features/recorder/record_page.dart（channel: ebook_studio/recorder）。
//

package com.example.ebook_studio

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MediaProjection 桥接。
 *
 * 注意：Android 14+ 要求 MediaProjection 只能在用户授权的会话内启动，
 * 且 `startRecording` 必须在 `onActivityResult` 拿到授权结果之后调用。
 * 这里只实现桥接骨架，实际项目里应把授权流程放到 MainActivity。
 */
class MediaProjectionBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "ebook_studio/recorder"
        const val REQUEST_CODE_PROJECTION = 4001
    }

    private var projectionManager: MediaProjectionManager =
        activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
    private var mediaProjection: MediaProjection? = null
    private var recording = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startRecording" -> {
                // Android 必须先取得用户授权
                activity.startActivityForResult(projectionManager.createScreenCaptureIntent(), REQUEST_CODE_PROJECTION)
                result.success(null)
            }
            "stopRecording" -> {
                mediaProjection?.stop()
                mediaProjection = null
                recording = false
                result.success(mapOf("path" to ""))
            }
            else -> result.notImplemented()
        }
    }

    /**
     * MainActivity.onActivityResult 拿到授权后调用，
     * 这里再真正创建 MediaProjection 并启动编码器。
     */
    fun onProjectionGranted(data: Intent) {
        mediaProjection = projectionManager.getMediaProjection(FlutterActivity.RESULT_OK, data)
        recording = true
        // TODO: 创建 MediaRecorder / MediaCodec 编码 MP4，输出到 recordings/ 目录
    }
}
