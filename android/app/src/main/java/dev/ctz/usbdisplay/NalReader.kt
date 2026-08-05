package dev.ctz.usbdisplay

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream

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
