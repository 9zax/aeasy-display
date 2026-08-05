package dev.ctz.usbdisplay

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Semaphore

/** Where a pane sits, in fractions of the viewport. */
class PaneSpec(
    @JvmField val src: String,
    @JvmField var x: Float = 0f,
    @JvmField var y: Float = 0f,
    @JvmField var w: Float = 1f,
    @JvmField var h: Float = 1f,
    @JvmField var z: Int = 0,
)

/**
 * One source: its own socket, worker thread, decoder and view.
 *
 * The video view is aspect-fitted inside the pane, so a touch on it normalises 1:1 onto
 * the encoded frame and the Mac needs no un-fitting — the same property the single-pane
 * build relied on.
 */
class Pane(
    ctx: Context,
    val src: String,
    private val port: Int,
    useTexture: Boolean,
    private val legacy: Boolean,
    private val netExec: ExecutorService,
    private val ui: Handler,
    private val arrangeMode: () -> Boolean,
    private val onFirstFrame: (Pane) -> Unit,
) {
    companion object {
        /** Decoders come up one at a time so the device's concurrent-codec limit always
         *  bites the same (last) pane instead of whichever thread happened to win. */
        private val decoderGate = Semaphore(1, true)
        private const val START_CODE_LEN = 4
    }

    val container = FrameLayout(ctx)
    val videoView: View = if (useTexture) TextureView(ctx) else SurfaceView(ctx)
    private val status = TextView(ctx)
    var spec = PaneSpec(src)

    @Volatile private var running = false
    @Volatile private var out: OutputStream? = null
    @Volatile private var socket: Socket? = null
    @Volatile private var surface: Surface? = null
    @Volatile var videoW = 0
    @Volatile var videoH = 0
    private var worker: Thread? = null
    private var insufficient = 0
    private var reportedFrame = false

    @SuppressLint("ClickableViewAccessibility")
    fun build() {
        container.addView(videoView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER))
        status.setTextColor(Color.WHITE)
        status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        status.gravity = Gravity.CENTER
        status.setPadding(24, 24, 24, 24)
        container.addView(status, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        container.contentDescription = container.context.getString(R.string.pane_desc, src)
        container.isFocusable = true
        setStatus(container.context.getString(R.string.pane_connecting))

        when (val v = videoView) {
            is SurfaceView -> v.holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(h: SurfaceHolder) { surface = h.surface; startWorker() }
                override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, hh: Int) {}
                override fun surfaceDestroyed(h: SurfaceHolder) { stopWorker(); surface = null }
            })
            is TextureView -> v.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                override fun onSurfaceTextureAvailable(st: SurfaceTexture, w: Int, h: Int) {
                    surface = Surface(st); startWorker()
                }
                override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, w: Int, h: Int) {}
                override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
                    stopWorker(); surface = null; return true
                }
                override fun onSurfaceTextureUpdated(st: SurfaceTexture) {}
            }
        }

        videoView.setOnTouchListener { v, e ->
            if (arrangeMode()) return@setOnTouchListener false
            val type = when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> 0
                MotionEvent.ACTION_MOVE -> 1
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> 2  // CANCEL too, or the Mac button sticks down
                else -> return@setOnTouchListener true
            }
            val x = ((e.x / v.width).coerceIn(0f, 1f) * 65535).toInt()
            val y = ((e.y / v.height).coerceIn(0f, 1f) * 65535).toInt()
            sendTouch(byteArrayOf(type.toByte(), (x shr 8).toByte(), x.toByte(), (y shr 8).toByte(), y.toByte()))
            true
        }
        container.addOnLayoutChangeListener { _, l, t, r, b, ol, ot, orr, ob ->
            if (r - l != orr - ol || b - t != ob - ot) applyFit()
        }
    }

    /** the pane's own finger-up, so switching modes mid-touch never leaves the Mac button down */
    fun releaseTouch() {
        sendTouch(byteArrayOf(2, 0, 0, 0, 0))
    }

    private fun sendTouch(pkt: ByteArray) {
        val o = out ?: return
        // ponytail: no move coalescing; 5-byte packets are noise next to the video stream
        netExec.execute { try { o.write(pkt); o.flush() } catch (_: Exception) {} }
    }

    fun applyFit() {
        val cw = container.width
        val ch = container.height
        if (cw == 0 || ch == 0 || videoW == 0 || videoH == 0) return
        val scale = minOf(cw.toFloat() / videoW, ch.toFloat() / videoH)
        videoView.layoutParams = FrameLayout.LayoutParams(
            (videoW * scale).toInt(), (videoH * scale).toInt(), Gravity.CENTER)
        videoView.requestLayout()
    }

    private fun setStatus(text: String?, clickable: Boolean = false) {
        ui.post {
            if (text == null) {
                status.visibility = View.GONE
                status.isClickable = false
            } else {
                status.text = text
                status.visibility = View.VISIBLE
                status.isClickable = clickable
                status.setOnClickListener(if (clickable) View.OnClickListener { retry() } else null)
            }
        }
    }

    fun showLost(text: String) = setStatus(text)

    private fun retry() {
        insufficient = 0
        setStatus(container.context.getString(R.string.pane_connecting))
        startWorker()
    }

    fun start() { if (surface != null) startWorker() }

    private fun startWorker() {
        if (worker != null || surface == null) return
        running = true
        worker = Thread { loop() }.also { it.start() }
    }

    fun stopWorker() {
        running = false
        // interrupt() does not unblock a thread parked in a socket read — only close() does
        try { socket?.close() } catch (_: Exception) {}
        worker?.interrupt()
        worker = null
    }

    fun destroy() {
        stopWorker()
        surface = null
    }

    private fun loop() {
        var backoff = 200L
        while (running) {
            val s = Socket()
            try {
                s.connect(InetSocketAddress("127.0.0.1", port), 3000)
                s.tcpNoDelay = true
                socket = s
                val o = s.getOutputStream()
                out = o
                if (!legacy) {
                    o.write("AEZ1 $src\n".toByteArray())
                    o.flush()
                }
                backoff = 200L
                decode(s.getInputStream())
            } catch (_: Exception) {
            } finally {
                out = null
                socket = null
                try { s.close() } catch (_: Exception) {}
            }
            if (!running) break
            reportedFrame = false
            setStatus(container.context.getString(R.string.pane_connection_lost))
            try { Thread.sleep(backoff) } catch (_: InterruptedException) { return }
            backoff = minOf(backoff * 2, 3000L)
        }
    }

    private fun decode(input: InputStream) {
        val reader = NalReader(input)
        val startCode = byteArrayOf(0, 0, 0, 1)
        var isHevc = false
        var sniffed = false
        var vps: ByteArray? = null
        var sps: ByteArray? = null
        var pps: ByteArray? = null
        var codec: MediaCodec? = null
        val info = MediaCodec.BufferInfo()
        var frame = 0L
        try {
            while (running) {
                val nal = reader.next() ?: break
                if (nal.isEmpty()) continue
                if (!sniffed) {
                    // the server always leads with parameter sets: HEVC VPS(32) vs H.264 SPS(7)
                    isHevc = (nal[0].toInt() shr 1) and 0x3F == 32
                    sniffed = true
                }
                val type = if (isHevc) (nal[0].toInt() shr 1) and 0x3F else nal[0].toInt() and 0x1F
                if (isHevc) when (type) {
                    32 -> vps = nal
                    33 -> sps = nal
                    34 -> pps = nal
                } else when (type) {
                    7 -> sps = nal
                    8 -> pps = nal
                }
                if (codec == null) {
                    val s = sps ?: continue
                    val p = pps ?: continue
                    val surf = surface ?: return
                    val mime = if (isHevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
                    val fmt = MediaFormat.createVideoFormat(mime, 1280, 720)
                    if (isHevc) {
                        val v = vps ?: continue
                        fmt.setByteBuffer("csd-0", ByteBuffer.wrap(startCode + v + startCode + s + startCode + p))
                    } else {
                        fmt.setByteBuffer("csd-0", ByteBuffer.wrap(startCode + s))
                        fmt.setByteBuffer("csd-1", ByteBuffer.wrap(startCode + p))
                    }
                    codec = createDecoder(mime, fmt, surf) ?: return
                    continue
                }
                if (if (isHevc) type >= 32 else (type != 1 && type != 5)) continue  // VCL slices only
                val inIx = codec.dequeueInputBuffer(50_000)
                if (inIx >= 0) {
                    val buf = codec.getInputBuffer(inIx)!!
                    buf.clear()
                    buf.put(startCode)
                    buf.put(nal)
                    codec.queueInputBuffer(inIx, 0, START_CODE_LEN + nal.size, frame * 1_000_000L / 30, 0)
                    frame++
                }
                var outIx = codec.dequeueOutputBuffer(info, 0)
                while (true) {
                    if (outIx >= 0) {
                        codec.releaseOutputBuffer(outIx, true)
                        if (!reportedFrame) {
                            reportedFrame = true
                            setStatus(null)
                            ui.post { onFirstFrame(this) }
                        }
                    } else if (outIx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        videoW = codec.outputFormat.getInteger(MediaFormat.KEY_WIDTH)
                        videoH = codec.outputFormat.getInteger(MediaFormat.KEY_HEIGHT)
                        ui.post { applyFit() }
                    } else break
                    outIx = codec.dequeueOutputBuffer(info, 0)
                }
            }
        } catch (_: Exception) {
        } finally {
            try { codec?.stop(); codec?.release() } catch (_: Exception) {}
        }
    }

    /** Classifies the failure instead of swallowing it: retrying an unsatisfiable
     *  resource request at 1Hz forever can reclaim a working pane's codec. */
    private fun createDecoder(mime: String, fmt: MediaFormat, surf: Surface): MediaCodec? {
        decoderGate.acquire()
        try {
            val c = MediaCodec.createDecoderByType(mime)
            c.configure(fmt, surf, null, 0)
            c.start()
            insufficient = 0
            return c
        } catch (e: MediaCodec.CodecException) {
            if (e.errorCode == MediaCodec.CodecException.ERROR_RECLAIMED) return null  // transient
            insufficient++
            if (insufficient >= 3) {
                running = false
                val ctx = container.context
                setStatus(ctx.getString(R.string.pane_decoder_unavailable) + "\n" +
                        ctx.getString(R.string.pane_decoder_detail) + "\n" +
                        ctx.getString(R.string.pane_retry), clickable = true)
            }
            return null
        } catch (_: Exception) {
            return null
        } finally {
            decoderGate.release()
        }
    }
}
