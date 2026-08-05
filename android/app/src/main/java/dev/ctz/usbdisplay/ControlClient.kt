package dev.ctz.usbdisplay

import org.json.JSONObject
import java.io.DataInputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ExecutorService

/**
 * The control channel: `AEZ1 control` then length-prefixed JSON both ways.
 * Carries the pane layout, the source list and the viewport size — never video.
 */
class ControlClient(
    private val port: Int,
    private val netExec: ExecutorService,
    private val onMessage: (JSONObject) -> Unit,
    private val onConnected: (Boolean) -> Unit,
) {
    @Volatile private var running = false
    @Volatile private var socket: Socket? = null
    @Volatile private var out: OutputStream? = null
    private var worker: Thread? = null

    fun start() {
        if (worker != null) return
        running = true
        worker = Thread { loop() }.also { it.start() }
    }

    fun stop() {
        running = false
        try { socket?.close() } catch (_: Exception) {}
        worker?.interrupt()
        worker = null
    }

    fun send(obj: JSONObject) {
        val o = out ?: return
        val body = obj.toString().toByteArray()
        netExec.execute {
            try {
                o.write(byteArrayOf(
                    (body.size ushr 24).toByte(), (body.size ushr 16).toByte(),
                    (body.size ushr 8).toByte(), body.size.toByte()))
                o.write(body)
                o.flush()
            } catch (_: Exception) {}
        }
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
                o.write("AEZ1 control\n".toByteArray())
                o.flush()
                out = o
                onConnected(true)
                backoff = 200L
                read(DataInputStream(s.getInputStream()))
            } catch (_: Exception) {
            } finally {
                out = null
                socket = null
                onConnected(false)
                try { s.close() } catch (_: Exception) {}
            }
            if (!running) break
            try { Thread.sleep(backoff) } catch (_: InterruptedException) { return }
            backoff = minOf(backoff * 2, 3000L)
        }
    }

    private fun read(input: DataInputStream) {
        while (running) {
            val len = input.readInt()
            if (len <= 0 || len > 1 shl 20) return   // desynced or hostile — drop the connection
            val body = ByteArray(len)
            input.readFully(body)
            val obj = try { JSONObject(String(body)) } catch (_: Exception) { continue }
            onMessage(obj)
        }
    }
}
