package dev.ctz.usbdisplay

import android.app.Activity
import android.graphics.Color
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Bundle
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer

// Reads an H.264 Annex-B stream from localhost:7355 (adb reverse tunnel over USB)
// and renders it fullscreen via hardware MediaCodec.
class MainActivity : Activity(), SurfaceHolder.Callback {

    private lateinit var surfaceView: SurfaceView
    @Volatile private var running = false
    private var worker: Thread? = null
    private var videoW = 0
    private var videoH = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE

        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        surfaceView = SurfaceView(this)
        root.addView(surfaceView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER))
        setContentView(root)
        surfaceView.holder.addCallback(this)
        // Rotation keeps the activity alive (configChanges), so re-fit whenever the root resizes.
        root.addOnLayoutChangeListener { _, l, t, r, b, ol, ot, orr, ob ->
            if (r - l != orr - ol || b - t != ob - ot) applyFit()
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        running = true
        worker = Thread { connectLoop(holder) }.apply { start() }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        running = false
        worker?.interrupt()
        worker = null
    }

    private fun connectLoop(holder: SurfaceHolder) {
        while (running) {
            try {
                Socket().use { s ->
                    s.connect(InetSocketAddress("127.0.0.1", 7355), 3000)
                    s.tcpNoDelay = true
                    decode(s.getInputStream(), holder)
                }
            } catch (_: Exception) {
            }
            try { Thread.sleep(1000) } catch (_: InterruptedException) { return }
        }
    }

    private fun decode(input: InputStream, holder: SurfaceHolder) {
        val reader = NalReader(input)
        val startCode = byteArrayOf(0, 0, 0, 1)
        var sps: ByteArray? = null
        var pps: ByteArray? = null
        var codec: MediaCodec? = null
        val info = MediaCodec.BufferInfo()
        var frame = 0L
        try {
            while (running) {
                val nal = reader.next() ?: break
                when (nal[0].toInt() and 0x1F) {
                    7 -> sps = nal
                    8 -> pps = nal
                }
                if (codec == null) {
                    val s = sps ?: continue
                    val p = pps ?: continue
                    val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1280, 720)
                    fmt.setByteBuffer("csd-0", ByteBuffer.wrap(startCode + s))
                    fmt.setByteBuffer("csd-1", ByteBuffer.wrap(startCode + p))
                    codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).apply {
                        configure(fmt, holder.surface, null, 0)
                        start()
                    }
                    continue
                }
                val type = nal[0].toInt() and 0x1F
                if (type != 1 && type != 5) continue
                val inIx = codec.dequeueInputBuffer(50_000)
                if (inIx >= 0) {
                    val buf = codec.getInputBuffer(inIx)!!
                    buf.clear()
                    buf.put(startCode)
                    buf.put(nal)
                    codec.queueInputBuffer(inIx, 0, startCode.size + nal.size, frame * 1_000_000L / 30, 0)
                    frame++
                }
                var outIx = codec.dequeueOutputBuffer(info, 0)
                while (true) {
                    if (outIx >= 0) {
                        codec.releaseOutputBuffer(outIx, true)
                    } else if (outIx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        fitSurface(codec.outputFormat)
                    } else break
                    outIx = codec.dequeueOutputBuffer(info, 0)
                }
            }
        } catch (_: Exception) {
        } finally {
            try { codec?.stop(); codec?.release() } catch (_: Exception) {}
        }
    }

    private fun fitSurface(fmt: MediaFormat) {
        videoW = fmt.getInteger(MediaFormat.KEY_WIDTH)
        videoH = fmt.getInteger(MediaFormat.KEY_HEIGHT)
        runOnUiThread { applyFit() }
    }

    private fun applyFit() {
        if (videoW == 0 || videoH == 0) return
        val parent = surfaceView.parent as FrameLayout
        if (parent.width == 0 || parent.height == 0) return
        val scale = minOf(parent.width.toFloat() / videoW, parent.height.toFloat() / videoH)
        surfaceView.layoutParams = FrameLayout.LayoutParams(
            (videoW * scale).toInt(), (videoH * scale).toInt(), Gravity.CENTER)
    }
}

// Splits an Annex-B byte stream into NAL units (start codes stripped).
class NalReader(input: InputStream) {
    private val ins = BufferedInputStream(input, 1 shl 16)
    private val buf = ByteArrayOutputStream(1 shl 16)
    private var zeros = 0

    fun next(): ByteArray? {
        while (true) {
            val b = ins.read()
            if (b < 0) return null
            if (zeros >= 2 && b == 1) {
                val arr = buf.toByteArray()
                val contentLen = arr.size - minOf(zeros, 3)
                zeros = 0
                buf.reset()
                if (contentLen > 0) return arr.copyOf(contentLen)
                continue // start code at stream head
            }
            if (b == 0) zeros++ else zeros = 0
            buf.write(b)
        }
    }
}
