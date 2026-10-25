//
//  录课桥接（设计文档 3.5：Android 端）—— **只录内容区**。
//
//  用 PixelCopy 逐帧抓取**本应用窗口**（无需投屏授权、无需前台服务），
//  按 Dart 传来的内容区矩形裁剪、缩放到目标分辨率，经 MediaCodec
//  （H.264，Surface 输入）+ MediaMuxer 编码 MP4；麦克风经 AudioRecord +
//  AAC 编码进同一条 MP4。
//
//  之前的 MediaProjection 方案被替换的原因：它只能镜像整个屏幕
//  （系统没有强制「只录本应用」的 API），且 Android 14+ 需要授权弹窗 +
//  mediaProjection 前台服务。PixelCopy 抓自己的窗口没有这些限制
//  （仅要求 API 26+）。
//
//  Dart 侧见 lib/features/recorder/record_page.dart（channel: ebook_studio/recorder）。
//

package com.bookstore.ebook_studio

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.Paint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.view.PixelCopy
import android.view.Surface
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class RecorderBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "ebook_studio/recorder"
        const val REQUEST_CODE_MIC = 4002
    }

    private var recording = false

    // startRecording 的 Dart 结果：麦克风权限通过后才真正开始
    private var pendingStart: MethodChannel.Result? = null
    private var wantAudio = true
    private var fps = 30

    // 裁剪区域 / 输出尺寸（物理像素，偶数）
    private var cropX = 0
    private var cropY = 0
    private var cropW = 0
    private var cropH = 0
    private var outW = 0
    private var outH = 0

    private var outputPath: String? = null
    private var startedAt = 0L

    private var captureThread: HandlerThread? = null
    private var captureHandler: Handler? = null
    private var audioThread: Thread? = null

    private var muxer: MediaMuxer? = null
    private val muxerLock = Any()
    private var videoEncoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var audioEncoder: MediaCodec? = null
    private var audioRecord: AudioRecord? = null
    private var windowBitmap: Bitmap? = null

    private var muxerStarted = false
    private var videoTrack = -1
    private var audioTrack = -1

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startRecording" -> startRecording(call, result)
            "stopRecording" -> stopRecording(result)
            else -> result.notImplemented()
        }
    }

    // ---------- 开始 ----------

    private fun startRecording(call: MethodCall, result: MethodChannel.Result) {
        if (recording) {
            result.error("ALREADY_RECORDING", "已经在录制中", null)
            return
        }
        if (Build.VERSION.SDK_INT < 26) {
            result.error("REQUIRES_ANDROID_8", "内容录制需要 Android 8 及以上（PixelCopy API）", null)
            return
        }
        fps = (call.argument<Int>("fps") ?: 30).coerceIn(1, 60)
        wantAudio = call.argument<Boolean>("audio") ?: false

        // 裁剪矩形（Flutter 视图内逻辑坐标）→ 物理像素 → 加上视图在窗口内的偏移
        //（PixelCopy 抓的是整个窗口，含状态栏；Flutter 内容区不一定顶到窗口原点）
        val density = activity.resources.displayMetrics.density
        val crop = call.argument<Map<String, Any?>>("crop")
        val decor = activity.window.decorView
        val winW = decor.width
        val winH = decor.height
        val contentView = activity.findViewById<android.view.ViewGroup>(android.R.id.content)
        val viewOffset = IntArray(2)
        if (contentView.childCount > 0) contentView.getChildAt(0).getLocationInWindow(viewOffset)

        fun even(v: Double, lo: Int, hi: Int): Int {
            val i = v.toInt().coerceIn(lo, hi)
            return i - (i % 2)
        }
        val cx = ((crop?.get("x") as? Number)?.toDouble() ?: 0.0) * density + viewOffset[0]
        val cy = ((crop?.get("y") as? Number)?.toDouble() ?: 0.0) * density + viewOffset[1]
        val cw = ((crop?.get("w") as? Number)?.toDouble() ?: winW.toDouble()) * density
        val ch = ((crop?.get("h") as? Number)?.toDouble() ?: winH.toDouble()) * density
        cropX = even(cx, 0, winW - 2)
        cropY = even(cy, 0, winH - 2)
        cropW = even(cw, 2, winW - cropX)
        cropH = even(ch, 2, winH - cropY)

        // 输出分辨率：0 = 裁剪区域原尺寸
        val out = call.argument<Map<String, Any?>>("out")
        outW = ((out?.get("w") as? Number)?.toInt() ?: cropW).coerceIn(16, 7680)
        outH = ((out?.get("h") as? Number)?.toInt() ?: cropH).coerceIn(16, 4320)
        outW -= outW % 2
        outH -= outH % 2

        if (wantAudio && !hasMicPermission()) {
            pendingStart = result
            activity.requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), REQUEST_CODE_MIC)
            return
        }
        launchStart(result)
    }

    /** MainActivity.onRequestPermissionsResult 转发进来：麦克风权限结果。 */
    fun onMicPermissionResult(granted: Boolean) {
        val pending = pendingStart ?: return
        if (granted || !wantAudio) {
            launchStart(pending)
        } else {
            pendingStart = null
            pending.error("MIC_PERMISSION_DENIED", "麦克风权限被拒绝，可在设置中开启，或关闭「含麦克风」", null)
        }
    }

    private fun hasMicPermission(): Boolean =
        activity.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    private fun launchStart(result: MethodChannel.Result) {
        pendingStart = null
        try {
            startEncoderPipeline()
            result.success(null)
        } catch (e: Exception) {
            releaseAll()
            result.error("START_FAILED", "无法开始录制：${e.message}", null)
        }
    }

    private fun startEncoderPipeline() {
        val dir = File(activity.filesDir, "recordings").apply { mkdirs() }
        val file = File(dir, timestampFileName() + ".mp4")
        outputPath = file.absolutePath
        muxer = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        // 视频编码器（Surface 输入）
        val bitrate = (outW.toLong() * outH * fps * 15 / 100).toInt().coerceIn(2_000_000, 16_000_000)
        val videoFormat = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, outW, outH).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
        }
        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        encoder.configure(videoFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = encoder.createInputSurface()
        encoder.start()
        videoEncoder = encoder
        inputSurface = surface

        if (wantAudio) startAudio()

        captureThread = HandlerThread("ebook-studio-capture").apply { start() }
        captureHandler = Handler(captureThread!!.looper)
        muxerStarted = false
        videoTrack = -1
        audioTrack = if (wantAudio) -1 else Int.MAX_VALUE // 无音频轨：用哨兵值表示「不再等待」
        recording = true
        startedAt = SystemClock.elapsedRealtime()
        scheduleCapture()
        if (wantAudio) {
            audioThread = Thread({ audioLoop() }, "ebook-studio-audio").apply { start() }
        }
    }

    private fun startAudio() {
        val sampleRate = 44100
        val minBuf = AudioRecord.getMinBufferSize(
            sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC, sampleRate,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minBuf * 2, 16384))
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 96_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }
        audioEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }
        audioRecord!!.startRecording()
    }

    // ---------- 逐帧抓取（captureThread） ----------

    private fun scheduleCapture() {
        captureHandler?.post {
            if (!recording) return@post
            val window = activity.window
            var bitmap = windowBitmap
            if (bitmap == null || bitmap.width != window.decorView.width || bitmap.height != window.decorView.height) {
                bitmap?.recycle()
                bitmap = Bitmap.createBitmap(window.decorView.width, window.decorView.height, Bitmap.Config.ARGB_8888)
                windowBitmap = bitmap
            }
            try {
                PixelCopy.request(window, bitmap, { copyResult ->
                    if (!recording) return@request
                    if (copyResult == PixelCopy.SUCCESS) {
                        drawFrame(bitmap)
                        drainVideo(endOfStream = false)
                    }
                    captureHandler?.postDelayed({ scheduleCapture() }, 1000L / fps)
                }, captureHandler)
            } catch (e: Exception) {
                // 窗口尺寸突变等：跳过这一帧
                captureHandler?.postDelayed({ scheduleCapture() }, 1000L / fps)
            }
        }
    }

    /** 裁剪子矩形 → 缩放 → 画进编码器的输入 Surface。 */
    private fun drawFrame(bitmap: Bitmap) {
        val surface = inputSurface ?: return
        val canvas = surface.lockCanvas(null) ?: return
        try {
            canvas.drawColor(android.graphics.Color.BLACK)
            val paint = Paint(Paint.FILTER_BITMAP_FLAG)
            val matrix = Matrix()
            matrix.setScale(outW.toFloat() / cropW, outH.toFloat() / cropH)
            matrix.postTranslate(-cropX * outW.toFloat() / cropW, -cropY * outH.toFloat() / cropH)
            canvas.drawBitmap(bitmap, matrix, paint)
        } finally {
            surface.unlockCanvasAndPost(canvas)
        }
    }

    // ---------- 编码输出 → Muxer ----------

    private fun drainVideo(endOfStream: Boolean) {
        val codec = videoEncoder ?: return
        if (endOfStream) codec.signalEndOfInputStream()
        val info = MediaCodec.BufferInfo()
        while (true) {
            val index = codec.dequeueOutputBuffer(info, if (endOfStream) 10_000 else 0)
            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!endOfStream) return
                continue
            }
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                synchronized(muxerLock) {
                    videoTrack = muxer?.addTrack(codec.outputFormat) ?: -1
                    maybeStartMuxer()
                }
                continue
            }
            if (index < 0) continue
            val buffer = codec.getOutputBuffer(index)
            if (buffer != null && info.size > 0) {
                synchronized(muxerLock) {
                    if (muxerStarted && videoTrack >= 0) {
                        muxer?.writeSampleData(videoTrack, buffer, info)
                    }
                }
            }
            codec.releaseOutputBuffer(index, false)
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
        }
    }

    private fun maybeStartMuxer() {
        if (muxerStarted || muxer == null) return
        val audioReady = audioTrack != -1
        val videoReady = videoTrack >= 0
        if (videoReady && audioReady) {
            muxer?.start()
            muxerStarted = true
        }
    }

    // ---------- 麦克风（audioThread） ----------

    private fun audioLoop() {
        val codec = audioEncoder ?: return
        val record = audioRecord ?: return
        val sampleRate = 44100
        val bytesPerFrame = 2 // mono 16bit
        var totalBytes = 0L
        val chunk = ByteArray(4096)
        var endOfInput = false
        val info = MediaCodec.BufferInfo()

        while (true) {
            // 送入
            if (!endOfInput) {
                if (!recording) {
                    endOfInput = true
                    try {
                        record.stop()
                    } catch (e: Exception) {
                    }
                    codec.queueInputBuffer(
                        codec.dequeueInputBuffer(-1), 0, 0,
                        totalBytes * 1_000_000L / (sampleRate * bytesPerFrame),
                        MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                } else {
                    val index = codec.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val input = codec.getInputBuffer(index)!!
                        val read = record.read(chunk, 0, minOf(chunk.size, input.capacity()))
                        if (read > 0) {
                            input.clear()
                            input.put(chunk, 0, read)
                            val pts = totalBytes * 1_000_000L / (sampleRate * bytesPerFrame)
                            totalBytes += read
                            codec.queueInputBuffer(index, 0, read, pts, 0)
                        }
                    }
                }
            }
            // 取出
            var outputDone = false
            while (!outputDone) {
                val index = codec.dequeueOutputBuffer(info, if (endOfInput) 10_000 else 0)
                when {
                    index == MediaCodec.INFO_TRY_AGAIN_LATER ->
                        outputDone = !endOfInput || (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0)
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                        synchronized(muxerLock) {
                            audioTrack = muxer?.addTrack(codec.outputFormat) ?: -1
                            maybeStartMuxer()
                        }
                    index >= 0 -> {
                        val buffer = codec.getOutputBuffer(index)
                        if (buffer != null && info.size > 0) {
                            synchronized(muxerLock) {
                                if (muxerStarted && audioTrack >= 0) {
                                    muxer?.writeSampleData(audioTrack, buffer, info)
                                }
                            }
                        }
                        codec.releaseOutputBuffer(index, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                    }
                }
            }
        }
    }

    // ---------- 停止 ----------

    private fun stopRecording(result: MethodChannel.Result) {
        if (!recording) {
            result.error("NOT_RECORDING", "当前没有正在进行的录制", null)
            return
        }
        recording = false
        val duration = ((SystemClock.elapsedRealtime() - startedAt) / 1000).toInt()

        captureHandler?.post {
            try {
                drainVideo(endOfStream = true)
            } catch (e: Exception) {
            }
            try {
                audioThread?.join(3000)
            } catch (e: InterruptedException) {
            }
            var error: String? = null
            try {
                if (!muxerStarted) {
                    error = "没有录到有效画面（录制时间过短）"
                } else {
                    muxer?.stop()
                }
            } catch (e: Exception) {
                error = "视频封装失败（可能录制时间过短）"
            }
            releaseAll()
            Handler(Looper.getMainLooper()).post {
                val path = outputPath
                if (error != null || path == null || !File(path).exists()) {
                    result.error("STOP_FAILED", error ?: "视频文件丢失", null)
                } else {
                    result.success(mapOf("path" to path, "duration_seconds" to duration))
                }
            }
        }
    }

    private fun releaseAll() {
        try {
            inputSurface?.release()
        } catch (e: Exception) {
        }
        inputSurface = null
        try {
            videoEncoder?.stop()
        } catch (e: Exception) {
        }
        videoEncoder?.release()
        videoEncoder = null
        try {
            audioEncoder?.stop()
        } catch (e: Exception) {
        }
        audioEncoder?.release()
        audioEncoder = null
        try {
            audioRecord?.release()
        } catch (e: Exception) {
        }
        audioRecord = null
        try {
            muxer?.release()
        } catch (e: Exception) {
        }
        muxer = null
        windowBitmap?.recycle()
        windowBitmap = null
        captureThread?.quitSafely()
        captureThread = null
        captureHandler = null
        audioThread = null
        muxerStarted = false
        videoTrack = -1
        audioTrack = -1
    }

    private fun timestampFileName(): String {
        val formatter = SimpleDateFormat("yyyy-MM-dd-HHmmss", Locale.US)
        return formatter.format(Date())
    }
}
