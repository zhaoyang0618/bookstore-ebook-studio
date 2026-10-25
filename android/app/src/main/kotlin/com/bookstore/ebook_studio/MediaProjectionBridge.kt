//
//  MediaProjection 桥接（设计文档 3.5：Android 平板端屏幕录制）。
//
//  通过 Flutter Platform Channel 暴露 startRecording / stopRecording，
//  用 MediaProjection 建立虚拟屏幕 + MediaRecorder（H.264 + AAC）编码 MP4。
//
//  Android 14（API 34）起的关键约束：
//  - getMediaProjection() 前必须已有 `mediaProjection` 类型的前台服务在跑；
//  - 授权结果（onActivityResult）必须在用户同意的「会话」内用掉。
//  因此流程是：启动前台服务 → 弹系统授权框 → 授权后立刻建投影开录。
//
//  Dart 侧见 lib/features/recorder/record_page.dart（channel: ebook_studio/recorder）。
//

package com.bookstore.ebook_studio

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.DisplayMetrics
import android.view.WindowManager
import android.view.WindowMetrics
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MediaProjectionBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "ebook_studio/recorder"
        const val REQUEST_CODE_PROJECTION = 4001
        const val REQUEST_CODE_MIC = 4002
    }

    private val projectionManager =
        activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager

    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var recorder: MediaRecorder? = null
    private var recording = false

    // startRecording 的 Dart 结果：授权成功才回 success，拒绝/失败回 error
    private var pendingStart: MethodChannel.Result? = null
    private var wantAudio = true
    private var fps = 30

    /** MainActivity.onActivityResult 转发进来：系统授权框关闭。 */
    fun onProjectionResult(resultCode: Int, data: Intent?) {
        if (!recordingWanted()) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            RecordingForegroundService.stop(activity)
            finishStartWithError("PERMISSION_DENIED", "屏幕录制授权被拒绝")
            return
        }
        try {
            startProjection(resultCode, data)
        } catch (e: Exception) {
            RecordingForegroundService.stop(activity)
            finishStartWithError("START_FAILED", "无法开始录制：${e.message}")
        }
    }

    /** MainActivity.onRequestPermissionsResult 转发进来：麦克风权限结果。 */
    fun onMicPermissionResult(granted: Boolean) {
        if (!recordingWanted()) return
        if (granted || !wantAudio) {
            launchConsent()
        } else {
            finishStartWithError("MIC_PERMISSION_DENIED", "麦克风权限被拒绝，可在设置中开启，或关闭「含麦克风音频」")
        }
    }

    private fun recordingWanted(): Boolean = pendingStart != null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startRecording" -> startRecording(call, result)
            "stopRecording" -> stopRecording(result)
            else -> result.notImplemented()
        }
    }

    private fun startRecording(call: MethodCall, result: MethodChannel.Result) {
        if (recording) {
            result.error("ALREADY_RECORDING", "已经在录制中", null)
            return
        }
        fps = call.argument<Int>("fps") ?: 30
        wantAudio = call.argument<Boolean>("audio") ?: false
        pendingStart = result

        if (wantAudio && !hasMicPermission()) {
            activity.requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), REQUEST_CODE_MIC)
            return
        }
        launchConsent()
    }

    private fun hasMicPermission(): Boolean =
        activity.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    /**
     * 先起前台服务（Android 14 要求在 getMediaProjection 之前），再弹系统授权框。
     *
     * 只支持 Android 14+：MIRROR_MODE_APP_ONLY（API 34）才能只镜像本应用窗口；
     * 更低版本直接报错（Dart 侧会提前拦截并说明）。
     */
    private fun launchConsent() {
        if (Build.VERSION.SDK_INT < 34) {
            finishStartWithError("REQUIRES_ANDROID_14", "录制仅支持 Android 14 及以上（只录本应用窗口）")
            return
        }
        RecordingForegroundService.start(activity)
        val displayConfig = android.media.projection.DisplayConfig.Builder()
            .setDisplayMirrorMode(android.media.projection.DisplayMirrorMode.MIRROR_MODE_APP_ONLY)
            .build()
        val config = android.media.projection.MediaProjectionConfig.createFromDisplayConfig(displayConfig)
        activity.startActivityForResult(projectionManager.createScreenCaptureIntent(config), REQUEST_CODE_PROJECTION)
    }

    private fun startProjection(resultCode: Int, data: Intent) {
        // 新版 SDK 里 getMediaProjection 标注了 @Nullable（前台服务未就绪/权限被收回时返回 null）
        val projection = projectionManager.getMediaProjection(resultCode, data)
            ?: throw IllegalStateException("无法获取 MediaProjection（授权会话无效或前台服务未就绪）")
        this.projection = projection
        // 用户从系统面板停止投屏时也要收尾（registerCallback 自 API 21 就有，
        // 不用 API 34 的 registerScreenCaptureCallback —— 它不在当前 compileSdk 里）
        projection.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                if (recording) activity.runOnUiThread { selfStop() }
            }
        }, Handler(Looper.getMainLooper()))

        val metrics = screenSize()
        val dir = File(activity.filesDir, "recordings").apply { mkdirs() }
        val file = File(dir, timestampFileName() + ".mp4")

        val recorder = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(activity) else @Suppress("DEPRECATION") MediaRecorder()
        if (wantAudio) recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
        recorder.setVideoSource(MediaRecorder.VideoSource.SURFACE)
        recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        recorder.setOutputFile(file.absolutePath)
        recorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
        if (wantAudio) recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        recorder.setVideoEncodingBitRate(8_000_000)
        recorder.setVideoFrameRate(fps)
        recorder.setVideoSize(metrics.width, metrics.height)
        recorder.prepare()

        virtualDisplay = projection.createVirtualDisplay(
            "ebook-studio-recording",
            metrics.width, metrics.height, metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            recorder.surface, null, null,
        )
        recorder.start()

        this.recorder = recorder
        recording = true
        startedAt = SystemClock.elapsedRealtime()
        outputPath = file.absolutePath
        pendingStart?.success(null)
        pendingStart = null
    }

    private class ScreenSize(val width: Int, val height: Int, val densityDpi: Int)

    private fun screenSize(): ScreenSize {
        // 只支持 Android 14+（MIRROR_MODE_APP_ONLY）→ 虚拟屏尺寸取**当前窗口**
        // 而非整块屏幕；仅保证宽高为偶数（编码器要求）
        val wm = activity.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val dm = activity.resources.displayMetrics
        return if (Build.VERSION.SDK_INT >= 30) {
            val bounds = wm.currentWindowMetrics.bounds
            val w = bounds.width() - (bounds.width() % 2)
            val h = bounds.height() - (bounds.height() % 2)
            ScreenSize(w, h, dm.densityDpi)
        } else {
            @Suppress("DEPRECATION")
            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay.getRealMetrics(metrics)
            ScreenSize(metrics.widthPixels, metrics.heightPixels, dm.densityDpi)
        }
    }

    private fun timestampFileName(): String {
        val formatter = java.text.SimpleDateFormat("yyyy-MM-dd-HHmmss", java.util.Locale.US)
        return formatter.format(java.util.Date())
    }

    private fun stopRecording(result: MethodChannel.Result) {
        if (!recording) {
            result.error("NOT_RECORDING", "当前没有正在进行的录制", null)
            return
        }
        val seconds = startedAt?.let { ((SystemClock.elapsedRealtime() - it) / 1000).toInt() } ?: 0
        try {
            recorder?.stop()
        } catch (e: Exception) {
            // stop 抛异常说明没录到有效帧（如立刻停止）
        }
        releaseProjection()
        if (outputPath != null && File(outputPath!!).exists()) {
            result.success(mapOf("path" to outputPath, "duration_seconds" to seconds))
        } else {
            result.error("STOP_FAILED", "视频写入失败（可能录制时间过短）", null)
        }
        outputPath = null
    }

    /** 投影回调 / 用户撤权触发的内部停止：无 Dart 结果可回。 */
    private fun selfStop() {
        try {
            recorder?.stop()
        } catch (e: Exception) {
        }
        releaseProjection()
    }

    private fun releaseProjection() {
        recording = false
        recorder?.release()
        recorder = null
        virtualDisplay?.release()
        virtualDisplay = null
        try {
            projection?.stop()
        } catch (e: Exception) {
        }
        projection = null
        RecordingForegroundService.stop(activity)
    }

    private fun finishStartWithError(code: String, message: String) {
        pendingStart?.error(code, message, null)
        pendingStart = null
    }

    private var startedAt: Long = 0
    private var outputPath: String? = null
}

/** 录制期间的常驻通知（Android 14+ 强制要求 mediaProjection 类型前台服务）。 */
class RecordingForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "ebook_studio_recording"
        private const val NOTIFICATION_ID = 40011

        fun start(context: Context) {
            val intent = Intent(context, RecordingForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RecordingForegroundService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "录课", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            android.app.Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION") android.app.Notification.Builder(this)
        }
        return builder
            .setContentTitle("正在录课")
            .setContentText("屏幕录制进行中")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .build()
    }
}
