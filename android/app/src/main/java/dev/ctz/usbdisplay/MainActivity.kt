package dev.ctz.usbdisplay

import android.app.Activity
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Executors

private const val PORT = 7355
private const val LEGACY_FALLBACK_MS = 2000L

/** Root that swallows every touch while arranging, so no pane forwards one to the Mac. */
class RootLayout(ctx: Context) : FrameLayout(ctx) {
    var arrange = false
    var toggleRect = Rect()
    var onArrangeTouch: ((MotionEvent) -> Boolean)? = null

    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean =
        arrange && !toggleRect.contains(ev.x.toInt(), ev.y.toInt())

    override fun onTouchEvent(ev: MotionEvent): Boolean = onArrangeTouch?.invoke(ev) ?: false
}

/** Pane outlines and resize handles. Never clickable, so in view mode touches fall through. */
class BorderOverlay(ctx: Context) : View(ctx) {
    var arrange = false
    var rects: List<RectF> = emptyList()
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 2f * ctx.resources.displayMetrics.density
        color = Color.WHITE
    }
    private val handle = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }

    override fun onDraw(canvas: Canvas) {
        if (!arrange) return
        val d = resources.displayMetrics.density
        for (r in rects) {
            canvas.drawRect(r, line)
            canvas.drawRect(r.right - 32 * d, r.bottom - 32 * d, r.right, r.bottom, handle)
        }
    }
}

/**
 * Shows up to three Mac sources as panes, each with its own socket and decoder.
 * View mode forwards touches to the Mac; arrange mode drags panes and forwards nothing.
 */
class MainActivity : Activity() {

    private lateinit var root: RootLayout
    private lateinit var overlay: BorderOverlay
    private lateinit var toggle: ImageView
    private lateinit var banner: TextView
    private lateinit var control: ControlClient

    private val panes = LinkedHashMap<String, Pane>()
    private val netExec = Executors.newSingleThreadExecutor()
    private val ui = Handler(Looper.getMainLooper())
    private val token = UUID.randomUUID().toString().substring(0, 8)

    @Volatile private var destroyed = false
    private var arrange = false
    private var rev = -1
    private var sourceIds: List<String> = emptyList()
    private var childOrder: List<String> = emptyList()
    private var gotControl = false
    private var legacyMode = false

    private var draggingSrc: String? = null
    private var dragMode = 0          // 1 = move, 2 = resize
    private var dragX = 0f
    private var dragY = 0f
    private var dragStart: PaneSpec? = null
    private var lastProposal = 0L

    private val density get() = resources.displayMetrics.density

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE

        root = RootLayout(this).apply { setBackgroundColor(Color.BLACK) }
        root.onArrangeTouch = { e -> onArrangeTouch(e) }

        overlay = BorderOverlay(this)
        banner = TextView(this).apply {
            setTextColor(Color.WHITE)
            setBackgroundColor(0xCC000000.toInt())
            setPadding((12 * density).toInt(), (8 * density).toInt(), (12 * density).toInt(), (8 * density).toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            visibility = View.GONE
        }
        toggle = ImageView(this).apply {
            setImageResource(R.drawable.ic_logo)
            contentDescription = getString(R.string.arrange_toggle_desc) + ": " + getString(R.string.arrange_toggle)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0x99000000.toInt())
                setStroke((1 * density).toInt(), 0x66FFFFFF)
            }
            val pad = (7 * density).toInt()
            setPadding(pad, pad, pad, pad)
            isClickable = true
            setOnClickListener { setArrange(!arrange) }
            setOnLongClickListener { resetLayout(); true }
        }

        root.addView(overlay, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        root.addView(banner, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP))
        // added last: touch dispatch walks children in reverse, so the toggle wins inside
        // its own box and is never consulted anywhere else
        val toggleSize = (40 * density).toInt()
        root.addView(toggle, FrameLayout.LayoutParams(
            toggleSize, toggleSize, Gravity.BOTTOM or Gravity.END))
        toggle.addOnLayoutChangeListener { _, l, t, r, b, _, _, _, _ ->
            root.toggleRect = Rect(l, t, r, b)
        }
        @Suppress("DEPRECATION")
        root.setOnApplyWindowInsetsListener { _, insets ->
            val lp = toggle.layoutParams as FrameLayout.LayoutParams
            lp.bottomMargin = insets.systemWindowInsetBottom + (16 * density).toInt()
            lp.marginEnd = insets.systemWindowInsetRight + (16 * density).toInt()
            toggle.layoutParams = lp
            insets
        }
        root.addOnLayoutChangeListener { _, l, t, r, b, ol, ot, orr, ob ->
            if (r - l != orr - ol || b - t != ob - ot) positionPanes()
        }
        setContentView(root)

        control = ControlClient(PORT, netExec, { msg -> ui.post { if (!destroyed) onControl(msg) } },
            { up -> ui.post { if (!destroyed && !up && !legacyMode) onControlDown() } })
    }

    override fun onStart() {
        super.onStart()
        destroyed = false
        control.start()
        // an older Mac build has no control channel; fall back to a single fullscreen pane
        ui.postDelayed({ if (!destroyed && !gotControl && panes.isEmpty()) enterLegacy() }, LEGACY_FALLBACK_MS)
    }

    override fun onStop() {
        super.onStop()
        destroyed = true
        control.stop()
        for (p in panes.values) p.destroy()
        panes.clear()
        childOrder = emptyList()
        sourceIds = emptyList()
        gotControl = false
        legacyMode = false
        rev = -1
        removePaneViews()
    }

    override fun onDestroy() {
        super.onDestroy()
        destroyed = true
        netExec.shutdownNow()
    }

    // MARK: control channel

    private fun onControl(msg: JSONObject) {
        gotControl = true
        when (msg.optString("t")) {
            "sources" -> {
                val arr = msg.optJSONArray("sources") ?: JSONArray()
                val ids = (0 until arr.length()).map { arr.getJSONObject(it).optString("id") }
                applySources(ids)
            }
            "layout" -> applyLayout(msg)
            "error" -> showBanner(when (msg.optString("code")) {
                "no_accessibility" -> getString(R.string.err_no_accessibility)
                "source_lost" -> return
                else -> getString(R.string.err_mac, msg.optString("msg"))
            })
        }
    }

    private fun onControlDown() {
        for (p in panes.values) p.showLost(getString(R.string.pane_connection_lost))
    }

    private fun applySources(ids: List<String>) {
        if (ids == sourceIds) return
        for ((src, pane) in panes) {
            if (src !in ids) pane.showLost(getString(R.string.pane_window_closed, label(src)))
        }
        // the view type depends on how many panes there are, so rebuild on any change
        for (p in panes.values) p.destroy()
        panes.clear()
        removePaneViews()
        sourceIds = ids
        childOrder = emptyList()
        for (src in ids) addPane(src, useTexture = ids.size > 1, legacy = false)
        positionPanes()
    }

    private fun applyLayout(msg: JSONObject) {
        val newRev = msg.optInt("rev", -1)
        val mine = msg.optString("ack", "") == token
        if (newRev <= rev && !mine) return
        rev = newRev
        val arr = msg.optJSONArray("panes") ?: return
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            val src = o.optString("src")
            // never yank a pane out from under the finger holding it
            if (src == draggingSrc) continue
            val p = panes[src] ?: continue
            p.spec.x = o.optDouble("x", 0.0).toFloat()
            p.spec.y = o.optDouble("y", 0.0).toFloat()
            p.spec.w = o.optDouble("w", 1.0).toFloat()
            p.spec.h = o.optDouble("h", 1.0).toFloat()
            p.spec.z = o.optInt("z", 0)
        }
        positionPanes()
    }

    // MARK: panes

    private fun addPane(src: String, useTexture: Boolean, legacy: Boolean) {
        val pane = Pane(this, src, PORT, useTexture, legacy, netExec, ui, { arrange }, { positionPanes() })
        pane.build()
        panes[src] = pane
        pane.start()
    }

    private fun enterLegacy() {
        legacyMode = true
        addPane("display", useTexture = false, legacy = true)
        sourceIds = listOf("display")
        positionPanes()
    }

    private fun removePaneViews() {
        var i = 0
        while (i < root.childCount) {
            val c = root.getChildAt(i)
            if (c !== overlay && c !== toggle && c !== banner) root.removeViewAt(i) else i++
        }
    }

    private fun label(src: String) = src.removePrefix("window:")

    private fun rectOf(spec: PaneSpec): RectF {
        val w = root.width.toFloat()
        val h = root.height.toFloat()
        return RectF(spec.x * w, spec.y * h, (spec.x + spec.w) * w, (spec.y + spec.h) * h)
    }

    private fun positionPanes() {
        if (root.width == 0 || root.height == 0) return
        val ordered = panes.values.sortedBy { it.spec.z }
        val order = ordered.map { it.src }
        if (order != childOrder) {
            // reordering re-attaches views and costs a surface, so only do it when z really moved
            removePaneViews()
            for ((i, p) in ordered.withIndex()) root.addView(p.container, i)
            childOrder = order
        }
        for (p in ordered) {
            val r = rectOf(p.spec)
            val lp = FrameLayout.LayoutParams(r.width().toInt().coerceAtLeast(1),
                                              r.height().toInt().coerceAtLeast(1))
            lp.leftMargin = r.left.toInt()
            lp.topMargin = r.top.toInt()
            p.container.layoutParams = lp
            p.container.requestLayout()
            p.applyFit()
        }
        overlay.rects = ordered.map { rectOf(it.spec) }
        overlay.invalidate()
    }

    // MARK: arrange mode

    private fun setArrange(on: Boolean) {
        if (on) for (p in panes.values) p.releaseTouch()   // no stuck mouse button on the Mac
        arrange = on
        root.arrange = on
        overlay.arrange = on
        overlay.invalidate()
        // no label anymore — arrange state reads as a solid white ring
        (toggle.background as GradientDrawable).setStroke(
            ((if (on) 2 else 1) * density).toInt(), if (on) 0xFFFFFFFF.toInt() else 0x66FFFFFF)
        toggle.contentDescription = getString(R.string.arrange_toggle_desc) + ": " +
            getString(if (on) R.string.arrange_toggle_done else R.string.arrange_toggle)
        root.announceForAccessibility(getString(if (on) R.string.arrange_on else R.string.arrange_off))
    }

    private fun paneAt(x: Float, y: Float): Pane? =
        panes.values.sortedByDescending { it.spec.z }.firstOrNull { rectOf(it.spec).contains(x, y) }

    private fun onArrangeTouch(e: MotionEvent): Boolean {
        if (!arrange) return false
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val hit = paneAt(e.x, e.y) ?: return false
                val r = rectOf(hit.spec)
                val grab = 48 * density
                dragMode = if (e.x > r.right - grab && e.y > r.bottom - grab) 2 else 1
                draggingSrc = hit.src
                dragX = e.x
                dragY = e.y
                dragStart = PaneSpec(hit.src, hit.spec.x, hit.spec.y, hit.spec.w, hit.spec.h, hit.spec.z)
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val src = draggingSrc ?: return false
                val p = panes[src] ?: return false
                val start = dragStart ?: return false
                val dx = (e.x - dragX) / root.width
                val dy = (e.y - dragY) / root.height
                if (dragMode == 2) {
                    p.spec.w = (start.w + dx).coerceIn(0.15f, 1f - start.x)
                    p.spec.h = (start.h + dy).coerceIn(0.15f, 1f - start.y)
                } else {
                    p.spec.x = (start.x + dx).coerceIn(0f, 1f - p.spec.w)
                    p.spec.y = (start.y + dy).coerceIn(0f, 1f - p.spec.h)
                }
                positionPanes()
                val now = System.currentTimeMillis()
                if (now - lastProposal >= 50) {   // 20Hz is plenty for the 200ms sync budget
                    lastProposal = now
                    propose()
                }
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (draggingSrc == null) return false
                propose()
                draggingSrc = null
                dragMode = 0
                dragStart = null
                return true
            }
        }
        return false
    }

    private fun propose() {
        if (legacyMode) return
        val arr = JSONArray()
        for (p in panes.values.sortedBy { it.spec.z }) {
            arr.put(JSONObject()
                .put("src", p.src)
                .put("x", p.spec.x.toDouble())
                .put("y", p.spec.y.toDouble())
                .put("w", p.spec.w.toDouble())
                .put("h", p.spec.h.toDouble())
                .put("z", p.spec.z))
        }
        control.send(JSONObject().put("t", "layout").put("panes", arr).put("tok", token))
    }

    /** Drag is unusable with explore-by-touch on, so TalkBack users get this instead. */
    private fun resetLayout() {
        val ordered = panes.values.sortedBy { it.spec.z }
        for ((i, p) in ordered.withIndex()) {
            if (i == 0) {
                p.spec.x = 0f; p.spec.y = 0f; p.spec.w = 1f; p.spec.h = 1f
            } else {
                p.spec.x = 0.58f; p.spec.y = 0.68f; p.spec.w = 0.4f; p.spec.h = 0.3f
            }
        }
        positionPanes()
        propose()
        root.announceForAccessibility(getString(R.string.reset_layout))
    }

    private fun showBanner(text: String) {
        banner.text = text
        banner.visibility = View.VISIBLE
        ui.postDelayed({ if (!destroyed) banner.visibility = View.GONE }, 5000)
    }
}
