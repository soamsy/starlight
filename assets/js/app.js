import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

function postToServerLog(level, args) {
  if (!document.querySelector("meta[name=dev-js-log]")) return
  const message = args
    .map(a => {
      if (a instanceof Error) return a.stack || a.message
      if (typeof a === "object") { try { return JSON.stringify(a) } catch { return String(a) } }
      return String(a)
    })
    .join(" ")

  fetch("/dev/js-log", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ level, message }),
    keepalive: true,
  }).catch(() => {})
}

const _origError = console.error.bind(console)
console.error = (...args) => { _origError(...args); postToServerLog("error", args) }

const _origWarn = console.warn.bind(console)
console.warn = (...args) => { _origWarn(...args); postToServerLog("warn", args) }

window.addEventListener("error", (e) => {
  if (e.error) {
    // JS runtime error
    postToServerLog("error", [`Uncaught ${e.error.stack || e.message} (${e.filename}:${e.lineno}:${e.colno})`])
  } else if (e.target && e.target !== window) {
    // Resource load failure (CSS, img, script 404s etc.)
    const src = e.target.src || e.target.href || "(unknown)"
    postToServerLog("error", [`Resource load failed: ${src}`])
  }
}, { capture: true })

window.addEventListener("unhandledrejection", (e) => {
  postToServerLog("error", [`Unhandled promise rejection: ${e.reason?.stack || e.reason}`])
})

function rgbToHsvCv(r, g, b) {
  r /= 255; g /= 255; b /= 255
  const max = Math.max(r, g, b), min = Math.min(r, g, b)
  const delta = max - min
  let h = 0
  if (delta !== 0) {
    if (max === r) h = ((g - b) / delta) % 6
    else if (max === g) h = (b - r) / delta + 2
    else h = (r - g) / delta + 4
    h *= 60
    if (h < 0) h += 360
  }
  const s = max === 0 ? 0 : delta / max
  const v = max
  return { h: Math.round(h / 2), s: Math.round(s * 255), v: Math.round(v * 255) }
}

const ScreenshotCanvas = {
  mounted() {
    const canvas = this.el
    const ctx = canvas.getContext("2d")

    let img = null
    let selecting = false
    let startPos = null
    let dragPoint = null
    let lastMouse = null
    let sel = null       // detection region {x,y,w,h}
    let selClick = null  // click region {x,y,w,h}
    let selScan = null   // scan region {x,y,w,h}
    let matches = []
    let mode = "detect"  // "detect" | "click" | "scan"
    let precisionMode = false  // whether shift key is held for precision

    canvas.width = 1920
    canvas.height = 1080
    ctx.imageSmoothingEnabled = true
    ctx.imageSmoothingQuality = "high"

    const getImageCoords = (e) => {
      const rect = canvas.getBoundingClientRect()
      const scaleX = canvas.width / rect.width
      const scaleY = canvas.height / rect.height
      return {
        x: Math.round((e.clientX - rect.left) * scaleX),
        y: Math.round((e.clientY - rect.top) * scaleY)
      }
    }

    const drawSelection = (s, color, label) => {
      if (!s || s.w < 2 || s.h < 2) return
      ctx.strokeStyle = color
      ctx.lineWidth = 2
      ctx.setLineDash([6, 4])
      ctx.strokeRect(s.x, s.y, s.w, s.h)
      ctx.setLineDash([])
      ctx.fillStyle = color
      ctx.font = "bold 16px monospace"
      const text = label ? `${label} ${s.w}×${s.h}` : `${s.w}×${s.h}`
      ctx.fillText(text, s.x + 4, s.y - 6 > 0 ? s.y - 6 : s.y + 20)
    }

    const redraw = () => {
      ctx.clearRect(0, 0, canvas.width, canvas.height)
      if (img) ctx.drawImage(img, 0, 0, canvas.width, canvas.height)
      if (sel)      drawSelection(sel,      "#f87171", null)
      if (selClick) drawSelection(selClick, "#60a5fa", "C")
      if (selScan)  drawSelection(selScan,  "#facc15", "S")
      matches.forEach(({ rect, score }, i) => {
        ctx.strokeStyle = "#4ade80"
        ctx.lineWidth = 2
        ctx.setLineDash([])
        ctx.strokeRect(rect.x, rect.y, rect.w, rect.h)
        ctx.fillStyle = "rgba(74, 222, 128, 0.15)"
        ctx.fillRect(rect.x, rect.y, rect.w, rect.h)
        const label = `#${i + 1} ${score.toFixed(3)}`
        ctx.font = "bold 14px monospace"
        const ty = rect.y - 4 > 14 ? rect.y - 4 : rect.y + rect.h + 16
        ctx.fillStyle = "rgba(0, 0, 0, 0.7)"
        ctx.fillRect(rect.x, ty - 13, ctx.measureText(label).width + 6, 17)
        ctx.fillStyle = "#4ade80"
        ctx.fillText(label, rect.x + 3, ty)
      })

      if (precisionMode && selecting) {
        ctx.fillStyle = "rgba(255, 255, 255, 0.7)"
        ctx.font = "bold 14px monospace"
        ctx.fillText("PRECISION MODE (SHIFT)", 10, canvas.height - 10)
      }
    }

    this.handleEvent("load_screenshot", ({ data }) => {
      matches = []
      const newImg = new Image()
      newImg.onload = () => { img = newImg; redraw() }
      newImg.src = "data:image/jpeg;base64," + data
    })

    this.handleEvent("show_match", ({ rect, score }) => {
      redraw()
      ctx.strokeStyle = "#4ade80"
      ctx.lineWidth = 3
      ctx.setLineDash([])
      ctx.strokeRect(rect.x, rect.y, rect.w, rect.h)
      ctx.fillStyle = "rgba(74, 222, 128, 0.15)"
      ctx.fillRect(rect.x, rect.y, rect.w, rect.h)
      ctx.fillStyle = "#4ade80"
      ctx.font = "bold 18px monospace"
      ctx.fillText(`✓ ${score.toFixed(3)}`, rect.x + 4, rect.y + 22)
    })

    this.handleEvent("show_matches", ({ matches: m }) => { matches = m; redraw() })

    this.handleEvent("set_selection", ({ x, y, w, h }) => { sel = { x, y, w, h }; redraw() })
    this.handleEvent("clear_selection", () => { sel = null; redraw() })
    this.handleEvent("set_click_selection", ({ x, y, w, h }) => { selClick = { x, y, w, h }; redraw() })
    this.handleEvent("clear_click_selection", () => { selClick = null; redraw() })
    this.handleEvent("set_scan_selection", ({ x, y, w, h }) => { selScan = { x, y, w, h }; redraw() })
    this.handleEvent("clear_scan_selection", () => { selScan = null; redraw() })
    this.handleEvent("set_canvas_mode", ({ mode: m }) => { mode = m })

    canvas.addEventListener("mousedown", (e) => {
      e.preventDefault()

      if (mode === "color") {
        const { x, y } = getImageCoords(e)
        const pixel = ctx.getImageData(x, y, 1, 1).data
        const { h, s, v } = rgbToHsvCv(pixel[0], pixel[1], pixel[2])
        this.pushEvent("color_picked", { h, s, v })
        return
      }

      selecting = true
      startPos = getImageCoords(e)
      dragPoint = { ...startPos }
      lastMouse = startPos
      if (mode === "click") selClick = null
      else if (mode === "scan") selScan = null
      else sel = null
    })
    
    document.addEventListener("keydown", (e) => {
      if (e.key === "Shift" && selecting) {
        precisionMode = true
        redraw()
      }
    })
    
    document.addEventListener("keyup", (e) => {
      if (e.key === "Shift") {
        precisionMode = false
        redraw()
      }
    })

    const onMouseMove = (e) => {
      if (!selecting || !startPos) return
      const mouse = getImageCoords(e)
      const step = e.shiftKey ? 0.1 : 1
      dragPoint.x += (mouse.x - lastMouse.x) * step
      dragPoint.y += (mouse.y - lastMouse.y) * step
      lastMouse = mouse
      precisionMode = e.shiftKey

      const cur = {
        x: Math.max(0, Math.min(canvas.width, Math.round(dragPoint.x))),
        y: Math.max(0, Math.min(canvas.height, Math.round(dragPoint.y)))
      }

      const x = Math.min(startPos.x, cur.x)
      const y = Math.min(startPos.y, cur.y)
      const w = Math.abs(cur.x - startPos.x)
      const h = Math.abs(cur.y - startPos.y)
      if (mode === "click") selClick = { x, y, w, h }
      else if (mode === "scan") selScan = { x, y, w, h }
      else sel = { x, y, w, h }
      redraw()
    }

    const finishSelect = () => {
      if (!selecting) return
      selecting = false
      precisionMode = false
      const current = mode === "click" ? selClick : mode === "scan" ? selScan : sel
      if (current && current.w >= 4 && current.h >= 4) {
        const event = mode === "click" ? "click_region_selected" : mode === "scan" ? "scan_region_selected" : "region_selected"
        this.pushEvent(event, current)
      } else {
        if (mode === "click") selClick = null
        else if (mode === "scan") selScan = null
        else sel = null
        redraw()
      }
    }

    document.addEventListener("mousemove", onMouseMove)
    document.addEventListener("mouseup", finishSelect)
    this.removeDragListeners = () => {
      document.removeEventListener("mousemove", onMouseMove)
      document.removeEventListener("mouseup", finishSelect)
    }
  },
  destroyed() {
    this.removeDragListeners?.()
  }
}

function overlayCanvasHook(eventName) {
  return {
    mounted() {
      const canvas = this.el
      const ctx = canvas.getContext("2d")
      canvas.width = 1920
      canvas.height = 1080

      const draw = (img, overlays) => {
        ctx.clearRect(0, 0, canvas.width, canvas.height)
        if (img) ctx.drawImage(img, 0, 0, canvas.width, canvas.height)

        for (const o of overlays || []) {
          ctx.strokeStyle = o.color || "#f87171"
          ctx.fillStyle = o.color || "#f87171"
          ctx.lineWidth = 2
          ctx.setLineDash(o.dashed ? [6, 4] : [])

          if (o.type === "rect") {
            ctx.strokeRect(o.x, o.y, o.w, o.h)
          } else if (o.type === "line") {
            ctx.beginPath()
            ctx.moveTo(o.x1, o.y1)
            ctx.lineTo(o.x2, o.y2)
            ctx.stroke()
          }

          if (o.text) {
            ctx.font = `bold ${o.font_px || 14}px monospace`
            if (o.outline) {
              ctx.setLineDash([])
              ctx.lineWidth = 3
              ctx.lineJoin = "round"
              ctx.strokeStyle = "#000"
              ctx.strokeText(o.text, o.text_x, o.text_y)
            }
            ctx.fillText(o.text, o.text_x, o.text_y)
          }
        }
      }

      let lastImg = null

      this.handleEvent(eventName, ({ data, overlays }) => {
        if (!data) {
          draw(lastImg, overlays)
          return
        }
        const img = new Image()
        img.onload = () => {
          lastImg = img
          draw(img, overlays)
        }
        img.src = "data:image/jpeg;base64," + data
      })
    }
  }
}

const EnemyLabelCanvas = {
  mounted() {
    const canvas = this.el
    const ctx = canvas.getContext("2d")
    canvas.width = 1920
    canvas.height = 1080

    const minSize = 15
    let img = null
    let rects = []
    let diff = null
    let selected = -1
    let drag = null

    const pos = (e) => {
      const r = canvas.getBoundingClientRect()
      return {
        x: Math.max(0, Math.min(1920, Math.round(((e.clientX - r.left) * 1920) / r.width))),
        y: Math.max(0, Math.min(1080, Math.round(((e.clientY - r.top) * 1080) / r.height)))
      }
    }

    const inside = (r, p) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h
    const hit = (p) => {
      for (let i = rects.length - 1; i >= 0; i--) if (inside(rects[i], p)) return i
      return -1
    }
    const normalized = (a, b) => ({ x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), w: Math.abs(a.x - b.x), h: Math.abs(a.y - b.y) })

    const label = (text, x, y, color) => {
      ctx.setLineDash([])
      ctx.font = "bold 14px monospace"
      ctx.lineWidth = 3
      ctx.strokeStyle = "#000"
      ctx.strokeText(text, x, y)
      ctx.fillStyle = color
      ctx.fillText(text, x, y)
    }

    const box = (r, color, dashed, width) => {
      ctx.strokeStyle = color
      ctx.lineWidth = width
      ctx.setLineDash(dashed ? [6, 4] : [])
      ctx.strokeRect(r.x, r.y, r.w, r.h)
    }

    const redraw = () => {
      ctx.clearRect(0, 0, 1920, 1080)
      if (img) ctx.drawImage(img, 0, 0, 1920, 1080)

      rects.forEach((r, i) => {
        box(r, i === selected ? "#facc15" : "#4ade80", false, i === selected ? 4 : 2)
        label(`enemy ${i + 1}`, r.x + 4, r.y - 6, i === selected ? "#facc15" : "#4ade80")
      })

      if (diff) {
        for (const r of diff.missed || []) {
          box(r, "#ef4444", true, 4)
          label("MISSED", r.x + 4, r.y + r.h + 16, "#ef4444")
        }
        for (const m of diff.matched || []) {
          ctx.fillStyle = "#4ade80"
          ctx.beginPath()
          ctx.arc(m.x, m.y, 7, 0, 2 * Math.PI)
          ctx.fill()
        }
        for (const p of diff.extra || []) {
          ctx.strokeStyle = "#ef4444"
          ctx.lineWidth = 4
          ctx.setLineDash([])
          ctx.beginPath()
          ctx.moveTo(p.x - 10, p.y - 10)
          ctx.lineTo(p.x + 10, p.y + 10)
          ctx.moveTo(p.x + 10, p.y - 10)
          ctx.lineTo(p.x - 10, p.y + 10)
          ctx.stroke()
          label("EXTRA", p.x + 14, p.y + 5, "#ef4444")
        }
      }

      if (drag && drag.mode === "create") box(normalized(drag.start, drag.current), "#facc15", true, 2)
    }

    const changed = () => {
      diff = null
      this.pushEvent("enemy_rects", { rects })
      redraw()
    }

    const onDown = (e) => {
      canvas.focus()
      const p = pos(e)
      const i = hit(p)
      if (i >= 0) {
        selected = i
        drag = { mode: "move", start: p, origin: { ...rects[i] }, moved: false }
      } else {
        selected = -1
        drag = { mode: "create", start: p, current: p }
      }
      redraw()
    }

    const onMove = (e) => {
      if (!drag) return
      const p = pos(e)
      if (drag.mode === "create") {
        drag.current = p
      } else {
        const dx = p.x - drag.start.x
        const dy = p.y - drag.start.y
        if (dx !== 0 || dy !== 0) drag.moved = true
        rects[selected] = { ...rects[selected], x: drag.origin.x + dx, y: drag.origin.y + dy }
      }
      redraw()
    }

    const onUp = () => {
      if (!drag) return
      const finished = drag
      drag = null
      if (finished.mode === "create") {
        const r = normalized(finished.start, finished.current)
        if (r.w >= minSize && r.h >= minSize) {
          rects.push(r)
          selected = rects.length - 1
          changed()
          return
        }
      } else if (finished.moved) {
        changed()
        return
      }
      redraw()
    }

    const remove = (i) => {
      if (i < 0) return
      rects.splice(i, 1)
      selected = -1
      changed()
    }

    canvas.addEventListener("mousedown", onDown)
    canvas.addEventListener("dblclick", (e) => remove(hit(pos(e))))
    canvas.addEventListener("keydown", (e) => {
      if (e.key === "Delete" || e.key === "Backspace") {
        e.preventDefault()
        remove(selected)
      }
    })
    document.addEventListener("mousemove", onMove)
    document.addEventListener("mouseup", onUp)
    this.removeListeners = () => {
      document.removeEventListener("mousemove", onMove)
      document.removeEventListener("mouseup", onUp)
    }

    this.handleEvent("load_enemy_editor", ({ data, rects: incoming, diff: incomingDiff }) => {
      rects = incoming || []
      diff = incomingDiff
      selected = -1
      if (!data) {
        redraw()
        return
      }
      const next = new Image()
      next.onload = () => {
        img = next
        redraw()
      }
      next.src = "data:image/jpeg;base64," + data
    })
  },
  destroyed() {
    this.removeListeners?.()
  }
}

const BattleInspectorCanvas = overlayCanvasHook("load_battle_frame")
const BattleHistoryCanvas = overlayCanvasHook("load_battle_history_frame")
const ChainPreviewCanvas = overlayCanvasHook("load_chain_preview_frame")
const TargetPreviewCanvas = overlayCanvasHook("load_target_preview_frame")
const DungeonInspectorCanvas = overlayCanvasHook("load_dungeon_frame")

const GiftInspectorCanvas = {
  mounted() {
    const canvas = this.el
    const ctx = canvas.getContext("2d")
    canvas.width = 1920
    canvas.height = 1080
    ctx.imageSmoothingEnabled = true
    ctx.imageSmoothingQuality = "high"

    let img = null
    let selecting = false
    let startPos = null
    let sel = null
    let overlays = []

    const getImageCoords = (e) => {
      const rect = canvas.getBoundingClientRect()
      const scaleX = canvas.width / rect.width
      const scaleY = canvas.height / rect.height
      return {
        x: Math.round((e.clientX - rect.left) * scaleX),
        y: Math.round((e.clientY - rect.top) * scaleY)
      }
    }

    const redraw = () => {
      ctx.clearRect(0, 0, canvas.width, canvas.height)
      if (img) ctx.drawImage(img, 0, 0, canvas.width, canvas.height)

      if (sel && sel.w >= 2 && sel.h >= 2) {
        ctx.strokeStyle = "#60a5fa"
        ctx.lineWidth = 2
        ctx.setLineDash([6, 4])
        ctx.strokeRect(sel.x, sel.y, sel.w, sel.h)
        ctx.setLineDash([])
      }

      for (const o of overlays) {
        ctx.strokeStyle = o.color || "#4ade80"
        ctx.fillStyle = o.color || "#4ade80"
        ctx.lineWidth = 2
        if (o.type === "rect") ctx.strokeRect(o.x, o.y, o.w, o.h)
        if (o.text) {
          ctx.font = "bold 14px monospace"
          ctx.fillText(o.text, o.text_x, o.text_y)
        }
      }
    }

    this.handleEvent("load_gift_inspector_frame", ({ data }) => {
      const newImg = new Image()
      newImg.onload = () => { img = newImg; sel = null; overlays = []; redraw() }
      newImg.src = "data:image/jpeg;base64," + data
    })

    this.handleEvent("show_gift_overlays", ({ overlays: o }) => {
      overlays = o || []
      redraw()
    })

    canvas.addEventListener("mousedown", (e) => {
      e.preventDefault()
      selecting = true
      startPos = getImageCoords(e)
      sel = null
      overlays = []
      redraw()
    })

    canvas.addEventListener("mousemove", (e) => {
      if (!selecting || !startPos) return
      const cur = getImageCoords(e)
      const x = Math.max(0, Math.min(startPos.x, cur.x))
      const y = Math.max(0, Math.min(startPos.y, cur.y))
      const w = Math.min(Math.abs(cur.x - startPos.x), canvas.width - x)
      const h = Math.min(Math.abs(cur.y - startPos.y), canvas.height - y)
      sel = { x, y, w, h }
      redraw()
    })

    const finishSelect = () => {
      if (!selecting) return
      selecting = false
      if (sel && sel.w >= 4 && sel.h >= 4) {
        this.pushEvent("region_selected", sel)
      } else {
        sel = null
        redraw()
      }
    }

    canvas.addEventListener("mouseup", finishSelect)
    canvas.addEventListener("mouseleave", finishSelect)
  }
}

function openNotesEditor(cell) {
  const display = cell.querySelector(".notes-display")
  const editor = cell.querySelector(".notes-edit")
  if (!display || !editor) return
  editor.value = cell.dataset.notes || ""
  display.classList.add("hidden")
  editor.classList.remove("hidden")
  editor.focus()
  editor.select()
}

const EditableNotes = {
  mounted() {
    const cell = this.el
    const display = cell.querySelector(".notes-display")
    const editor = cell.querySelector(".notes-edit")

    const renderDisplay = (value) => {
      if (value.trim() === "") {
        display.innerHTML = '<span class="italic text-base-content/30">double-click to add</span>'
      } else {
        display.textContent = value
      }
    }

    display.addEventListener("dblclick", () => openNotesEditor(cell))

    editor.addEventListener("blur", () => {
      const value = editor.value
      cell.dataset.notes = value
      renderDisplay(value)
      display.classList.remove("hidden")
      editor.classList.add("hidden")
      this.pushEvent("save_notes", { name: cell.dataset.name, value })
    })

    editor.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        editor.blur()
      } else if (e.key === "Escape") {
        editor.value = cell.dataset.notes
        editor.blur()
      } else if (e.key === "Tab") {
        const row = cell.closest("tr")
        const siblingRow = e.shiftKey ? row?.previousElementSibling : row?.nextElementSibling
        const siblingCell = siblingRow?.querySelector(".notes-edit")?.closest("td")
        if (siblingCell) {
          e.preventDefault()
          editor.blur()
          openNotesEditor(siblingCell)
        }
      }
    })
  }
}

const PreserveScroll = {
  beforeUpdate() {
    this.scrollTop = this.el.scrollTop
    this.scrollLeft = this.el.scrollLeft
  },
  updated() {
    this.el.scrollTop = this.scrollTop
    this.el.scrollLeft = this.scrollLeft
  }
}

const STREAM_TARGET_MS = 500
const STREAM_MAX_BACKOFF_MS = 5000

const GameStream = {
  mounted() {
    this.img = this.el.querySelector("[data-stream-img]")
    this.onBtn = this.el.querySelector("[data-stream-on]")
    this.offBtn = this.el.querySelector("[data-stream-off]")
    this.status = this.el.querySelector("[data-stream-status]")
    this.active = false
    this.failures = 0
    this.onVisibility = () => {
      if (this.active && !document.hidden && !this.inflight) this.schedule(0)
    }
    this.onBtn.addEventListener("click", () => this.start())
    this.offBtn.addEventListener("click", () => this.stop())
    document.addEventListener("visibilitychange", this.onVisibility)
  },
  destroyed() {
    this.stop()
    document.removeEventListener("visibilitychange", this.onVisibility)
  },
  start() {
    this.active = true
    this.failures = 0
    this.onBtn.classList.add("hidden")
    this.offBtn.classList.remove("hidden")
    this.schedule(0)
  },
  stop() {
    this.active = false
    clearTimeout(this.timer)
    if (this.controller) this.controller.abort()
    this.releaseImage()
    this.img.classList.add("hidden")
    this.status.classList.add("hidden")
    this.offBtn.classList.add("hidden")
    this.onBtn.classList.remove("hidden")
  },
  releaseImage() {
    if (this.blobUrl) URL.revokeObjectURL(this.blobUrl)
    this.blobUrl = null
    this.img.removeAttribute("src")
  },
  schedule(delay) {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.fetchFrame(), delay)
  },
  async fetchFrame() {
    if (!this.active || document.hidden) return
    this.inflight = true
    this.controller = new AbortController()
    const started = performance.now()
    try {
      const res = await fetch(`${this.el.dataset.src}?t=${Date.now()}`, { cache: "no-store", signal: this.controller.signal })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const url = URL.createObjectURL(await res.blob())
      if (!this.active) { URL.revokeObjectURL(url); return }
      if (this.blobUrl) URL.revokeObjectURL(this.blobUrl)
      this.blobUrl = url
      this.img.src = url
      this.img.classList.remove("hidden")
      this.status.classList.add("hidden")
      this.failures = 0
    } catch (err) {
      if (err.name === "AbortError") return
      this.failures += 1
      this.status.classList.remove("hidden")
    } finally {
      this.inflight = false
    }
    if (!this.active) return
    const took = performance.now() - started
    const delay = this.failures > 0
      ? Math.min(STREAM_MAX_BACKOFF_MS, 1000 * 2 ** (this.failures - 1))
      : Math.max(STREAM_TARGET_MS - took, took)
    this.schedule(delay)
  }
}

const SCROLL_PIN_THRESHOLD_PX = 60

const ScrollToBottom = {
  mounted() {
    this.el.scrollTop = this.el.scrollHeight
  },
  beforeUpdate() {
    this.pinned = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight <= SCROLL_PIN_THRESHOLD_PX
  },
  updated() {
    if (!this.pinned) return
    cancelAnimationFrame(this.frame)
    this.frame = requestAnimationFrame(() => { this.el.scrollTop = this.el.scrollHeight })
  },
  destroyed() {
    cancelAnimationFrame(this.frame)
  }
}

const LOG_ROW_CLASS = "flex gap-2 leading-snug border-l-2 pl-2 py-px"
const LOG_KIND_CLASS = {
  error: "border-error bg-error/10 text-error",
  ok: "border-success/60 text-base-content",
  info: "border-base-content/20 text-base-content/80",
  step: "border-transparent text-base-content/40 text-[11px]"
}
const LOG_DEFAULT_CLASS = "border-base-content/10 text-base-content/60"
const LOG_PAD_PX = 8
const LOG_OVERSCAN_PX = 800
const LOG_PIN_PX = 60

const logKindClass = (kind) => LOG_KIND_CLASS[kind] || LOG_DEFAULT_CLASS

const LogVirtual = {
  mounted() {
    this.scroller = this.el.firstElementChild
    this.count = document.getElementById(this.el.dataset.countId)
    this.sizer = document.createElement("div")
    this.sizer.style.position = "relative"
    this.win = document.createElement("div")
    this.win.style.cssText = "position:absolute;left:0;right:0"
    this.sizer.appendChild(this.win)
    this.scroller.appendChild(this.sizer)

    this.all = []
    this.view = []
    this.offsets = [0]
    this.range = [0, 0]
    this.pinned = true
    this.metrics = null
    this.metricsVersion = 0
    this.filterKey = this.readFilterKey()
    this.lastWidth = 0
    this.frame = null

    this.scroller.addEventListener("scroll", this.onScroll = () => {
      this.pinned = this.scroller.scrollHeight - this.scroller.scrollTop - this.scroller.clientHeight <= LOG_PIN_PX
      this.scheduleRender()
    })

    this.resizer = new ResizeObserver(() => this.onResize())
    this.resizer.observe(this.scroller)

    this.handleEvent("log_entries", ({ id, mode, entries }) => {
      if (id === this.el.id) this.receive(mode, entries.map(parseLogEntry))
    })

    this.pushEvent("log_ready", {})
  },

  reconnected() {
    this.pushEvent("log_ready", {})
  },

  updated() {
    const key = this.readFilterKey()
    if (key === this.filterKey) return
    this.filterKey = key
    this.relayout()
  },

  destroyed() {
    this.resizer.disconnect()
    this.scroller.removeEventListener("scroll", this.onScroll)
    cancelAnimationFrame(this.frame)
  },

  readFilterKey() {
    const d = this.el.dataset
    return `${d.showSteps}|${d.errorsOnly}|${d.machine || ""}`
  },

  passes(e) {
    const d = this.el.dataset
    return (d.showSteps === "true" || e.kind !== "step") &&
      (d.errorsOnly !== "true" || e.kind === "error") &&
      (!d.machine || e.lineage.includes(d.machine))
  },

  receive(mode, entries) {
    if (mode === "reset") {
      this.all = entries
      this.pinned = true
      this.relayout()
    } else if (mode === "prepend") {
      this.all = entries.concat(this.all)
      this.relayout()
    } else {
      for (const e of entries) this.all.push(e)
      if (!this.ensureMetrics()) return
      for (const e of entries) {
        if (!this.passes(e)) continue
        this.view.push(e)
        this.offsets.push(this.offsets[this.offsets.length - 1] + this.heightOf(e))
      }
      this.layout()
      if (this.pinned) this.stickToBottom()
      else this.scheduleRender()
    }
  },

  relayout() {
    if (!this.ensureMetrics()) return
    const anchor = this.captureAnchor()
    this.view = this.all.filter((e) => this.passes(e))
    const offsets = new Array(this.view.length + 1)
    offsets[0] = 0
    for (let i = 0; i < this.view.length; i++) offsets[i + 1] = offsets[i] + this.heightOf(this.view[i])
    this.offsets = offsets
    this.layout()
    this.restoreAnchor(anchor)
    this.renderWindow(true)
  },

  layout() {
    this.sizer.style.height = `${this.offsets[this.offsets.length - 1] + 2 * LOG_PAD_PX}px`
    if (this.count) this.count.textContent = `${this.view.length} lines`
  },

  stickToBottom() {
    this.scroller.scrollTop = this.scroller.scrollHeight
    this.renderWindow(false)
  },

  captureAnchor() {
    if (this.pinned || this.view.length === 0) return null
    const y = this.scroller.scrollTop - LOG_PAD_PX
    const i = this.indexAt(y)
    return { seq: this.view[i].seq, delta: y - this.offsets[i] }
  },

  restoreAnchor(anchor) {
    if (this.pinned || !anchor) {
      this.scroller.scrollTop = this.scroller.scrollHeight
      return
    }
    const i = this.lowerBound(anchor.seq)
    this.scroller.scrollTop = this.offsets[i] + anchor.delta + LOG_PAD_PX
  },

  indexAt(y) {
    const offsets = this.offsets
    let lo = 0
    let hi = Math.max(offsets.length - 2, 0)
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1
      if (offsets[mid] <= y) lo = mid
      else hi = mid - 1
    }
    return lo
  },

  lowerBound(seq) {
    let lo = 0
    let hi = this.view.length
    while (lo < hi) {
      const mid = (lo + hi) >> 1
      if (this.view[mid].seq < seq) lo = mid + 1
      else hi = mid
    }
    return Math.min(lo, Math.max(this.view.length - 1, 0))
  },

  scheduleRender() {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      this.renderWindow(false)
    })
  },

  renderWindow(force) {
    const n = this.view.length
    if (n === 0) {
      this.win.replaceChildren()
      this.range = [0, 0]
      return
    }
    const top = this.scroller.scrollTop - LOG_PAD_PX
    const bottom = top + this.scroller.clientHeight
    const first = this.indexAt(top)
    const last = this.indexAt(bottom)
    if (!force && this.range[0] <= first && last < this.range[1]) return

    const start = this.indexAt(top - LOG_OVERSCAN_PX)
    const end = Math.min(n, this.indexAt(bottom + LOG_OVERSCAN_PX) + 1)
    const fragment = document.createDocumentFragment()
    for (let i = start; i < end; i++) fragment.appendChild(this.buildRow(this.view[i]))
    this.win.replaceChildren(fragment)
    this.win.style.top = `${LOG_PAD_PX + this.offsets[start]}px`
    this.range = [start, end]
  },

  buildRow(e) {
    const row = document.createElement("div")
    row.className = `${LOG_ROW_CLASS} ${logKindClass(e.kind)}`
    const time = document.createElement("span")
    time.className = "text-base-content/40 shrink-0 tabular-nums"
    time.title = e.at
    time.textContent = e.at.slice(11)
    const text = document.createElement("span")
    text.className = "whitespace-pre-wrap break-all"
    text.textContent = e.text
    row.append(time, text)
    return row
  },

  heightOf(e) {
    if (e.hv === this.metricsVersion) return e.h
    const m = e.kind === "step" ? this.metrics.step : this.metrics.base
    const t = e.text
    let lines = 0
    let from = 0
    for (;;) {
      const nl = t.indexOf("\n", from)
      const len = (nl === -1 ? t.length : nl) - from
      lines += Math.max(1, Math.ceil(len / m.cols))
      if (nl === -1) break
      from = nl + 1
    }
    e.h = lines * m.lineH + m.pad
    e.hv = this.metricsVersion
    return e.h
  },

  ensureMetrics() {
    if (this.metrics) return true
    return this.measure()
  },

  measure() {
    if (this.scroller.clientWidth === 0) return false
    const probe = (kind) => {
      const row = document.createElement("div")
      row.className = `${LOG_ROW_CLASS} ${logKindClass(kind)}`
      row.style.cssText = "position:absolute;visibility:hidden;left:0;right:0"
      const time = document.createElement("span")
      time.className = "shrink-0 tabular-nums"
      time.textContent = "00:00:00.000"
      const text = document.createElement("span")
      text.className = "whitespace-pre-wrap break-all"
      text.style.flex = "1 1 0%"
      text.textContent = "0"
      const ch = document.createElement("span")
      ch.style.cssText = "position:absolute;white-space:pre"
      ch.textContent = "0".repeat(100)
      row.append(time, text, ch)
      this.scroller.appendChild(row)
      const style = getComputedStyle(row)
      const pad = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom)
      const rowH = row.getBoundingClientRect().height
      const charW = ch.getBoundingClientRect().width / 100
      const textW = text.getBoundingClientRect().width
      row.remove()
      return { lineH: rowH - pad, pad, cols: Math.max(1, Math.floor(textW / charW + 1e-6)) }
    }
    this.metrics = { base: probe("info"), step: probe("step") }
    this.metricsVersion += 1
    this.lastWidth = this.scroller.clientWidth
    return true
  },

  onResize() {
    const width = this.scroller.clientWidth
    if (width !== this.lastWidth) {
      this.metrics = null
      if (this.all.length > 0) this.relayout()
      else this.lastWidth = width
    } else if (this.pinned) {
      this.stickToBottom()
    } else {
      this.scheduleRender()
    }
  }
}

const parseLogEntry = ([seq, at, kind, text, lineage]) => ({ seq, at, kind, text, lineage, h: 0, hv: -1 })

const PlanClipboard = {
  mounted() {
    this.last = undefined

    this.refresh = (force) => {
      navigator.clipboard.readText()
        .catch(() => null)
        .then(text => {
          if (!force && text === this.last) return
          this.last = text
          this.pushEvent("clipboard_status", { text })
        })
    }

    this.onFocus = () => this.refresh(false)
    window.addEventListener("focus", this.onFocus)
    this.el.addEventListener("pointerenter", () => this.refresh(true))

    this.handleEvent("copy_plan_json", ({ text }) => {
      navigator.clipboard.writeText(text)
        .then(() => this.refresh(true))
        .catch(err => {
          this.pushEvent("plan_clipboard_failed", { message: `Couldn't copy to clipboard: ${err.message || err}` })
        })
    })

    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-paste-plan]")
      if (!btn) return

      navigator.clipboard.readText()
        .then(text => {
          if (window.confirm(btn.dataset.confirmText)) this.pushEvent("paste_plan", { text })
        })
        .catch(err => {
          this.pushEvent("plan_clipboard_failed", { message: `Couldn't read clipboard: ${err.message || err}` })
        })
    })

    this.refresh(true)
  },
  destroyed() {
    window.removeEventListener("focus", this.onFocus)
  }
}

const ItemClipboard = {
  mounted() {
    this.handleEvent("copy_json", ({ text }) => {
      navigator.clipboard.writeText(text).catch(err => {
        this.pushEvent("plan_clipboard_failed", { message: `Couldn't copy to clipboard: ${err.message || err}` })
      })
    })

    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-paste-event]")
      if (!btn) return

      navigator.clipboard.readText()
        .then(text => this.pushEvent(btn.dataset.pasteEvent, { text, kind: btn.dataset.kind }))
        .catch(err => {
          this.pushEvent("plan_clipboard_failed", { message: `Couldn't read clipboard: ${err.message || err}` })
        })
    })
  }
}

const PriorityChips = {
  mounted() {
    const strip = () => this.el.querySelector("[data-chip-strip]")
    const palette = () => this.el.querySelector("[data-chip-palette]")
    const order = () => Array.from(strip().querySelectorAll("[data-chip] input")).map(i => i.value).join(",")
    const isFused = (chip) => chip.dataset.tier && chip.dataset.sin
    const isPlainTier = (chip) => chip.dataset.tier && !chip.dataset.sin
    const isPlainSin = (chip) => chip.dataset.sin && !chip.dataset.tier
    const chips = () => Array.from(this.el.querySelectorAll("[data-chip]"))
    const fuseClasses = ["ring-2", "ring-primary"]
    let dragged = null
    let before = null
    let fuseTarget = null

    const clearFuseTarget = () => {
      fuseTarget?.classList.remove(...fuseClasses)
      fuseTarget = null
    }

    const place = (chip, container, ref) => {
      if (container === palette()) {
        const next = Array.from(container.children).find(c => Number(c.dataset.canon) > Number(chip.dataset.canon))
        container.insertBefore(chip, next || null)
      } else {
        container.insertBefore(chip, ref || null)
      }
      chip.querySelector("input").disabled = container !== strip()
    }

    const fuse = (target, sinChip) => {
      const value = `${target.dataset.tier}+${sinChip.dataset.sin}`
      if (chips().some(c => isFused(c) && c.querySelector("input").value === value)) return
      const fused = target.cloneNode(true)
      fused.dataset.sin = sinChip.dataset.sin
      fused.title = value
      fused.classList.remove(...fuseClasses)
      const input = fused.querySelector("input")
      input.value = value
      input.disabled = false
      const badge = document.createElement("span")
      badge.dataset.chipSin = ""
      badge.className = "ml-1 inline-flex rounded bg-base-200 p-px"
      const icon = document.createElement("img")
      icon.src = `/images/sin/${sinChip.dataset.sin}.webp`
      icon.alt = sinChip.dataset.sin
      icon.draggable = false
      icon.className = "size-4 pointer-events-none"
      badge.append(icon)
      fused.append(badge)
      if (target.parentElement === strip()) {
        strip().insertBefore(fused, target)
        place(target, palette())
      } else {
        strip().append(fused)
      }
      if (sinChip.parentElement === strip()) place(sinChip, palette())
    }

    const unfuse = (fused) => {
      const plain = chips().find(c => isPlainTier(c) && c.dataset.tier === fused.dataset.tier)
      if (plain && plain.parentElement === palette()) place(plain, strip(), fused)
      fused.remove()
    }

    const commit = (previous) => {
      if (order() === previous) return
      this.el.querySelector("[data-chip-anchor]").dispatchEvent(new Event("input", { bubbles: true }))
    }

    this.el.addEventListener("click", (e) => {
      const chip = eventElement(e)?.closest("[data-chip]")
      if (!chip) return
      const previous = order()
      if (isFused(chip)) {
        if (eventElement(e).closest("[data-chip-sin]")) unfuse(chip)
        else chip.remove()
      } else if (e.shiftKey && isPlainSin(chip) && chip.parentElement === palette()) {
        const target = Array.from(strip().children).reverse().find(isPlainTier)
        if (target) fuse(target, chip)
      } else {
        place(chip, chip.parentElement === strip() ? palette() : strip())
      }
      commit(previous)
    })

    this.el.addEventListener("dragstart", (e) => {
      const chip = eventElement(e)?.closest("[data-chip]")
      if (!chip) return
      e.stopPropagation()
      dragged = chip
      before = order()
      e.dataTransfer.effectAllowed = "move"
      e.dataTransfer.setData("text/plain", chip.dataset.canon)
      chip.classList.add("opacity-40")
    })

    this.el.addEventListener("dragover", (e) => {
      if (!dragged) return
      const container = eventElement(e)?.closest("[data-chip-strip], [data-chip-palette]")
      if (!container) return
      e.preventDefault()
      e.stopPropagation()
      clearFuseTarget()
      const hovered = eventElement(e)?.closest("[data-chip]")
      if (isPlainSin(dragged) && hovered && hovered !== dragged && isPlainTier(hovered)) {
        const rect = hovered.getBoundingClientRect()
        const offset = (e.clientX - rect.left) / rect.width
        if (offset > 0.25 && offset < 0.75) {
          fuseTarget = hovered
          hovered.classList.add(...fuseClasses)
          return
        }
      }
      if (container === palette()) {
        if (dragged.parentElement !== container) place(dragged, container)
        return
      }
      const over = eventElement(e)?.closest("[data-chip]")
      if (!over || over === dragged || over.parentElement !== container) {
        if (dragged.parentElement !== container) place(dragged, container)
        return
      }
      const rect = over.getBoundingClientRect()
      place(dragged, container, e.clientX > rect.left + rect.width / 2 ? over.nextSibling : over)
    })

    this.el.addEventListener("dragend", (e) => {
      if (!dragged) return
      e.stopPropagation()
      dragged.classList.remove("opacity-40")
      if (fuseTarget) fuse(fuseTarget, dragged)
      clearFuseTarget()
      if (isFused(dragged) && dragged.parentElement === palette()) dragged.remove()
      dragged = null
      commit(before)
    })
  }
}

const DragScroll = {
  mounted() {
    this.syncPannable()
    this.resizeObserver = new ResizeObserver(() => this.syncPannable())
    this.resizeObserver.observe(this.el)

    this.el.addEventListener("mousedown", (e) => {
      if (!this.el.dataset.pan || e.button !== 0 || eventElement(e)?.closest("[data-no-pan], button, input")) return
      e.preventDefault()
      const startX = e.clientX
      const startScroll = this.el.scrollLeft
      this.el.dataset.pan = "active"

      const onMove = (ev) => { this.el.scrollLeft = startScroll - (ev.clientX - startX) }
      const onUp = (ev) => {
        this.syncPannable()
        if (Math.abs(ev.clientX - startX) > 3) {
          const swallow = (ce) => { ce.stopPropagation(); ce.preventDefault() }
          this.el.addEventListener("click", swallow, { capture: true, once: true })
          setTimeout(() => this.el.removeEventListener("click", swallow, { capture: true }), 0)
        }
        window.removeEventListener("mousemove", onMove)
        window.removeEventListener("mouseup", onUp)
      }
      window.addEventListener("mousemove", onMove)
      window.addEventListener("mouseup", onUp)
    })
  },
  updated() {
    this.syncPannable()
  },
  destroyed() {
    this.resizeObserver.disconnect()
  },
  syncPannable() {
    if (this.el.scrollWidth > this.el.clientWidth) this.el.dataset.pan = "ready"
    else delete this.el.dataset.pan
  }
}

let sortDrag = null
const SORT_EDGE_PX = 16
const SORT_SELECTED = ["ring-2", "ring-primary"]
const SORT_INTERACTIVE = "button, input, select, textarea, a, label, [role=button], [tabindex], [data-gift-popup]"
const sortSelection = { list: null, ids: new Set(), anchor: null }

const sortRows = (list) => Array.from(list.children).filter(c => c.dataset.sortId && !c.dataset.sortId.startsWith("group:"))

const paintSortSelection = (list) => {
  if (!list) return
  const selected = sortSelection.list === list
  sortRows(list).forEach(row => SORT_SELECTED.forEach(c => row.classList.toggle(c, selected && sortSelection.ids.has(row.dataset.sortId))))
}

const setSortSelection = (list, ids, anchor) => {
  const previous = sortSelection.list
  sortSelection.list = ids.size ? list : null
  sortSelection.ids = ids
  sortSelection.anchor = ids.size ? anchor : null
  if (previous && previous !== list) paintSortSelection(previous)
  paintSortSelection(list)
}

const clearSortSelection = () => setSortSelection(sortSelection.list, new Set(), null)

let sortSelectionBound = false
const bindSortSelectionGlobals = () => {
  if (sortSelectionBound) return
  sortSelectionBound = true
  document.addEventListener("click", (e) => {
    if (!sortSelection.list) return
    if (!eventElement(e)?.closest("[data-sort-id]")) clearSortSelection()
  })
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && sortSelection.list) clearSortSelection()
  })
}

const eventElement = (e) => (e.target instanceof Element ? e.target : e.target.parentElement)

const SortableList = {
  updated() {
    if (sortSelection.list === this.el) {
      const present = new Set(sortRows(this.el).map(r => r.dataset.sortId))
      const ids = new Set(Array.from(sortSelection.ids).filter(id => present.has(id)))
      setSortSelection(this.el, ids, ids.has(sortSelection.anchor) ? sortSelection.anchor : Array.from(ids)[0])
    }
  },

  destroyed() {
    if (sortSelection.list === this.el) setSortSelection(null, new Set(), null)
  },

  mounted() {
    const multi = "sortMulti" in this.el.dataset
    if (multi) bindSortSelectionGlobals()

    const rowOf = (e) => {
      const row = eventElement(e)?.closest("[data-sort-id]")
      return row && row.parentElement === this.el && !row.dataset.sortId.startsWith("group:") ? row : null
    }

    if (multi) {
      this.el.addEventListener("click", (e) => {
        const row = rowOf(e)
        if (!row) return

        const copy = eventElement(e).closest("[data-copy-entry]")
        if (copy) {
          const ids = sortSelection.list === this.el && sortSelection.ids.has(row.dataset.sortId)
            ? sortRows(this.el).map(r => r.dataset.sortId).filter(id => sortSelection.ids.has(id))
            : [row.dataset.sortId]
          this.pushEvent("ms_copy_entries", { ids })
          return
        }

        const paste = eventElement(e).closest("[data-paste-entries]")
        if (paste) {
          navigator.clipboard.readText()
            .then(text => this.pushEvent("ms_paste_entries", { text, after: paste.dataset.pasteEntries }))
            .catch(err => this.pushEvent("plan_clipboard_failed", { message: `Couldn't read clipboard: ${err.message || err}` }))
          return
        }

        if (eventElement(e).closest(SORT_INTERACTIVE)) return

        const id = row.dataset.sortId
        const same = sortSelection.list === this.el
        if (e.shiftKey && same && sortSelection.anchor) {
          const ids = sortRows(this.el).map(r => r.dataset.sortId)
          const from = ids.indexOf(sortSelection.anchor)
          const to = ids.indexOf(id)
          const range = from < 0 ? [id] : ids.slice(Math.min(from, to), Math.max(from, to) + 1)
          setSortSelection(this.el, new Set([...sortSelection.ids, ...range]), sortSelection.anchor)
        } else if ((e.ctrlKey || e.metaKey) && same) {
          const next = new Set(sortSelection.ids)
          if (next.has(id)) next.delete(id)
          else next.add(id)
          setSortSelection(this.el, next, next.has(id) ? id : Array.from(next)[0])
        } else {
          setSortSelection(this.el, new Set([id]), id)
        }
      })
    }

    this.el.addEventListener("mousedown", (e) => {
      const target = eventElement(e)
      const handle = target?.closest("[data-sort-handle]")
      if (!handle) return
      const item = handle.closest("[data-sort-id]")
      if (!item || item.parentElement !== this.el) return
      item.draggable = !target.closest("button, input, select, textarea, a, label, [role=button], [tabindex]")
    })

    this.el.addEventListener("mouseup", (e) => {
      const item = eventElement(e)?.closest("[data-sort-id]")
      if (item && item.parentElement === this.el && !sortDrag) item.draggable = false
    })

    this.el.addEventListener("dragstart", (e) => {
      const item = eventElement(e)?.closest("[data-sort-id]")
      if (!item || item.parentElement !== this.el) return
      const multiple = multi && sortSelection.list === this.el && sortSelection.ids.has(item.dataset.sortId) && sortSelection.ids.size > 1
      const items = multiple ? sortRows(this.el).filter(r => sortSelection.ids.has(r.dataset.sortId)) : [item]
      if (multi && !multiple) setSortSelection(this.el, new Set([item.dataset.sortId]), item.dataset.sortId)
      sortDrag = { item, items, source: this.el, packed: false }
      e.dataTransfer.effectAllowed = "move"
      if (items.length > 1) {
        const stack = document.createElement("div")
        stack.style.cssText = `position:fixed;top:-10000px;left:0;width:${item.offsetWidth}px;display:flex;flex-direction:column;gap:4px`
        items.forEach(i => {
          const clone = i.cloneNode(true)
          clone.removeAttribute("data-sort-id")
          stack.appendChild(clone)
        })
        document.body.appendChild(stack)
        const box = item.getBoundingClientRect()
        e.dataTransfer.setDragImage(stack, e.clientX - box.left, e.clientY - box.top)
        requestAnimationFrame(() => stack.remove())
      }
      requestAnimationFrame(() => items.forEach(i => i.classList.add("opacity-40")))
    })

    const place = (parent, ref) => {
      const drag = sortDrag
      if (drag.item.parentElement === drag.source && parent !== drag.source && !drag.spacer) {
        drag.spacer = document.createElement("div")
        drag.spacer.style.height = `${drag.items.reduce((sum, i) => sum + i.offsetHeight, 0) + 4 * (drag.items.length - 1)}px`
        drag.source.insertBefore(drag.spacer, drag.item)
      }
      let target = ref
      while (target && drag.items.includes(target)) target = target.nextSibling
      const last = drag.items[drag.items.length - 1]
      if (drag.packed && last.parentElement === parent && last.nextSibling === target) return
      drag.packed = true
      parent.insertBefore(drag.item, target)
      const at = drag.items.indexOf(drag.item)
      drag.items.slice(0, at).forEach(i => parent.insertBefore(i, drag.item))
      let tail = drag.item
      drag.items.slice(at + 1).forEach(i => {
        parent.insertBefore(i, tail.nextSibling)
        tail = i
      })
      if (parent === drag.source && drag.spacer) {
        drag.spacer.remove()
        drag.spacer = null
      }
    }

    this.el.addEventListener("dragover", (e) => {
      if (!sortDrag || !this.accepts(sortDrag)) return
      e.preventDefault()
      e.stopPropagation()
      const highlight = sortDrag.source !== this.el && "sortHighlight" in this.el.dataset ? this.el : null
      if (sortDrag.highlight !== highlight) {
        sortDrag.highlight?.classList.remove("bg-primary/15")
        highlight?.classList.add("bg-primary/15")
        sortDrag.highlight = highlight
      }
      const closest = eventElement(e)?.closest("[data-sort-id]")
      const over = closest?.parentElement === this.el ? closest : null
      if (!over && !Array.from(this.el.children).some(c => c.dataset.sortId)) {
        if (sortDrag.item.parentElement !== this.el) place(this.el, null)
        return
      }
      if (!over || sortDrag.items.includes(over)) return
      const rect = over.getBoundingClientRect()
      if (over.querySelector("[data-sort-move-event]") && e.clientY > rect.top + SORT_EDGE_PX && e.clientY < rect.bottom - SORT_EDGE_PX) return
      const after = this.el.dataset.sortAxis === "x"
        ? e.clientX > rect.left + rect.width / 2
        : e.clientY > rect.top + rect.height / 2
      place(this.el, after ? over.nextSibling : over)
    })

    this.el.addEventListener("dragend", () => {
      if (!sortDrag || sortDrag.item.parentElement !== this.el) return
      const { item, items, source, highlight, spacer } = sortDrag
      spacer?.remove()
      highlight?.classList.remove("bg-primary/15")
      sortDrag = null
      items.forEach(i => {
        i.classList.remove("opacity-40")
        i.draggable = false
      })
      const ids = Array.from(this.el.children).filter(c => c.dataset.sortId).map(c => c.dataset.sortId)
      const scope = this.el.dataset.sortScope || ""
      if (source === this.el) this.pushEvent(this.el.dataset.sortEvent, { scope, ids })
      else {
        const payload = { scope, from: source.dataset.sortScope || "", id: item.dataset.sortId, ids }
        if (items.length > 1) payload.moved = items.map(i => i.dataset.sortId)
        this.pushEvent(this.el.dataset.sortMoveEvent, payload)
      }
      if (sortSelection.list) {
        sortSelection.list = this.el
        paintSortSelection(source)
        paintSortSelection(this.el)
      }
    })
  },

  accepts({ item, source }) {
    if (item.contains(this.el)) return false
    if (source === this.el) return true
    const shared = this.el.dataset.sortShared
    return !!shared && shared === source.dataset.sortShared && !("sortStay" in item.dataset) && !!this.el.dataset.sortMoveEvent
  }
}

const GIFT_DRAG_TYPE = "application/x-starlight-gift"

const GiftDragSource = {
  mounted() {
    this.el.addEventListener("dragstart", (e) => {
      const row = eventElement(e)?.closest("[data-drag-gift]")
      if (!row) return e.preventDefault()
      e.dataTransfer.setData(GIFT_DRAG_TYPE, row.dataset.dragGift)
      e.dataTransfer.effectAllowed = "copy"
    })
    this.sync()
  },
  updated() {
    this.sync()
  },
  sync() {
    this.el.querySelectorAll("[data-drag-gift]").forEach(row => { row.draggable = true })
  }
}

const GiftDropZone = {
  mounted() {
    const active = (e) => this.el.dataset.dropEvent && e.dataTransfer.types.includes(GIFT_DRAG_TYPE)
    this.el.addEventListener("dragover", (e) => {
      if (!active(e)) return
      e.preventDefault()
      e.dataTransfer.dropEffect = "copy"
      this.el.classList.add("bg-primary/15")
    })
    this.el.addEventListener("dragleave", (e) => {
      if (!this.el.contains(e.relatedTarget)) this.el.classList.remove("bg-primary/15")
    })
    this.el.addEventListener("drop", (e) => {
      if (!active(e)) return
      e.preventDefault()
      this.el.classList.remove("bg-primary/15")
      this.pushEvent(this.el.dataset.dropEvent, { gift: e.dataTransfer.getData(GIFT_DRAG_TYPE) })
    })
  }
}

const REGION_DRAG_TYPE = "application/x-starlight-region"

const RegionDragDrop = {
  mounted() {
    const target = (e) => eventElement(e)?.closest("[data-region-drop]")
    const clearHighlight = () => {
      this.el.querySelectorAll("[data-region-drop]").forEach(el => el.classList.remove("bg-primary/15"))
    }
    this.el.addEventListener("dragstart", (e) => {
      const handle = eventElement(e)?.closest("[data-region-drag]")
      if (!handle) return
      e.dataTransfer.setData(REGION_DRAG_TYPE, handle.dataset.regionDrag)
      e.dataTransfer.effectAllowed = "copy"
    })
    this.el.addEventListener("dragover", (e) => {
      const zone = target(e)
      if (!zone || !e.dataTransfer.types.includes(REGION_DRAG_TYPE)) return
      e.preventDefault()
      e.dataTransfer.dropEffect = "copy"
      clearHighlight()
      zone.classList.add("bg-primary/15")
    })
    this.el.addEventListener("dragleave", (e) => {
      if (!this.el.contains(e.relatedTarget)) clearHighlight()
    })
    this.el.addEventListener("dragend", clearHighlight)
    this.el.addEventListener("drop", (e) => {
      const zone = target(e)
      if (!zone || !e.dataTransfer.types.includes(REGION_DRAG_TYPE)) return
      e.preventDefault()
      clearHighlight()
      const from = e.dataTransfer.getData(REGION_DRAG_TYPE)
      if (from !== zone.dataset.regionDrop) this.pushEvent("copy_region", { from, to: zone.dataset.regionDrop })
    })
  }
}

const ChannelBand = {
  mounted() {
    const max = Number(this.el.dataset.max)
    this.pending = null
    this.timer = null
    const flush = () => {
      clearTimeout(this.timer)
      this.timer = null
      if (this.pending === null) return
      const input = this.el.closest("form").elements[this.el.dataset.inputName]
      input.value = String(this.pending)
      this.pending = null
      input.dispatchEvent(new Event("input", { bubbles: true }))
    }
    const setFromPointer = (e) => {
      const rect = this.el.getBoundingClientRect()
      const frac = Math.min(Math.max((e.clientX - rect.left) / rect.width, 0), 1)
      const value = Math.round(frac * max)
      this.el.querySelector("[data-band-marker]").style.left = `${(value / max) * 100}%`
      this.pending = value
      if (!this.timer) this.timer = setTimeout(flush, 80)
    }
    this.el.addEventListener("pointerdown", (e) => {
      this.el.setPointerCapture(e.pointerId)
      setFromPointer(e)
    })
    this.el.addEventListener("pointermove", (e) => {
      if (this.el.hasPointerCapture(e.pointerId)) setFromPointer(e)
    })
    this.el.addEventListener("pointerup", flush)
  }
}

const LocalStorageForm = {
  mounted() {
    this.key = this.el.dataset.storageKey
    if (!this.key) return

    const saved = localStorage.getItem(this.key)
    if (saved) {
      try {
        this.pushEvent("restore_form", JSON.parse(saved))
      } catch (e) {}
    }

    this.persist = () => {
      const data = {}
      for (const [name, value] of new FormData(this.el).entries()) {
        if (name.endsWith("[]")) (data[name] ||= []).push(value)
        else data[name] = value
      }
      localStorage.setItem(this.key, JSON.stringify(data))
    }
    this.el.addEventListener("input", this.persist)
    this.el.addEventListener("change", this.persist)
  },
  updated() {
    this.persist?.()
  }
}

const TeamNavMemory = {
  mounted() {
    if (this.el.dataset.team) this.store()
    else this.pushEvent("restore_nav", {
      team: localStorage.getItem("starlight-team-editor-team"),
      pane: localStorage.getItem("starlight-team-editor-pane")
    })
  },
  updated() {
    this.store()
  },
  store() {
    const { team, pane } = this.el.dataset
    if (team) localStorage.setItem("starlight-team-editor-team", team)
    if (["battle", "packs", "gifts"].includes(pane)) localStorage.setItem("starlight-team-editor-pane", pane)
  }
}

const ViewMemory = {
  mounted() {
    this.key = null
    this.sync()
  },
  updated() {
    this.sync()
  },
  sync() {
    const key = this.el.dataset.key || null
    if (key !== this.key) {
      this.key = key
      let saved = null
      try {
        saved = key && localStorage.getItem(key)
      } catch (e) {}
      if (saved) {
        try {
          this.pushEvent("restore_view", JSON.parse(saved))
          return
        } catch (e) {}
      }
    }
    if (this.key && this.el.dataset.view) localStorage.setItem(this.key, this.el.dataset.view)
  }
}

const GiftPopup = {
  mounted() {
    this.onClick = (e) => {
      const trigger = e.target.closest("[data-gift-popup]")
      const open = this.el.dataset.gift

      if (open && this.el.contains(e.target) && e.target.closest("[data-popup-control]")) return

      if (trigger && trigger.dataset.giftPopup !== open) {
        e.preventDefault()
        e.stopPropagation()
        this.pushEvent("show_gift_popup", { gift: trigger.dataset.giftPopup, uptie: trigger.dataset.giftUptie, x: e.clientX, y: e.clientY })
      } else if (open) {
        if (trigger) {
          e.preventDefault()
          e.stopPropagation()
        }
        this.pushEvent("hide_gift_popup", {})
      }
    }
    document.addEventListener("click", this.onClick, true)
    this.place()
  },
  updated() {
    this.place()
  },
  destroyed() {
    document.removeEventListener("click", this.onClick, true)
  },
  place() {
    const box = this.el.firstElementChild
    if (!box) return
    const margin = 8
    const x = Number(this.el.dataset.x)
    const y = Number(this.el.dataset.y)
    const { width, height } = box.getBoundingClientRect()
    const left = Math.max(margin, Math.min(x + margin, window.innerWidth - width - margin))
    const below = y + margin
    const top = below + height <= window.innerHeight - margin ? below : Math.max(margin, y - height - margin)
    box.style.left = `${left}px`
    box.style.top = `${top}px`
  }
}

const WindowDrag = {
  mounted() {
    this.el.addEventListener("pointerdown", (e) => {
      const target = eventElement(e)?.closest("[data-handle]")
      const form = this.el.closest("form")
      if (!target || e.button !== 0 || !form) return
      e.preventDefault()
      const startInput = form.querySelector('input[name="window_start"]')
      const endInput = form.querySelector('input[name="window_end"]')
      const start0 = this.minutes(startInput.value)
      const end0 = this.minutes(endInput.value)
      if (start0 === null || end0 === null) return
      const handle = target.dataset.handle
      const rect = this.el.getBoundingClientRect()
      const toMinutes = (x) => Math.round(((x - rect.left) / rect.width) * 288) * 5
      const wrap = (m) => ((m % 1440) + 1440) % 1440
      this.dragging = true

      const onMove = (ev) => {
        if (handle === "start") startInput.value = this.clock(wrap(toMinutes(ev.clientX)))
        else endInput.value = this.clock(wrap(toMinutes(ev.clientX)))
        this.preview(this.minutes(startInput.value), this.minutes(endInput.value))
        this.placeHandles()
      }
      const onUp = () => {
        this.dragging = false
        window.removeEventListener("pointermove", onMove)
        window.removeEventListener("pointerup", onUp)
        const changed = [startInput, endInput].filter((input) => input.value !== (input === startInput ? this.clock(start0) : this.clock(end0)))
        if (changed.length === 0) {
          this.clearPreview()
          this.pending = null
        }
        changed.forEach((input) => input.dispatchEvent(new Event("input", { bubbles: true })))
      }
      window.addEventListener("pointermove", onMove)
      window.addEventListener("pointerup", onUp)
    })
    this.placeHandles()
  },
  updated() {
    if (this.dragging) return
    if (this.pending && this.el.dataset.start === this.pending.start && this.el.dataset.end === this.pending.end) this.clearPreview()
    this.placeHandles()
  },
  preview(start, end) {
    this.clearPreview()
    const pieces = start <= end ? [[start, end]] : [[0, end], [start, 1440]]
    const layer = document.createElement("div")
    layer.className = "pointer-events-none absolute inset-0 rounded bg-base-200"
    for (const [from, to] of pieces) {
      const piece = document.createElement("div")
      piece.className = "absolute inset-y-0 bg-success/20"
      piece.style.left = `${from / 14.4}%`
      piece.style.width = `${(to - from) / 14.4}%`
      layer.appendChild(piece)
    }
    const windows = this.el.querySelectorAll("[data-window]")
    const anchor = windows[windows.length - 1]
    if (anchor) anchor.insertAdjacentElement("afterend", layer)
    else this.el.prepend(layer)
    this.layer = layer
    this.pending = { start: this.clock(start), end: this.clock(end) }
  },
  clearPreview() {
    this.layer?.remove()
    this.layer = null
  },
  minutes(value) {
    const match = /^(\d{2}):(\d{2})/.exec(value || "")
    return match ? Number(match[1]) * 60 + Number(match[2]) : null
  },
  clock(minutes) {
    return `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`
  },
  placeHandles() {
    const form = this.el.closest("form")
    if (!form) return
    for (const [name, handle] of [["window_start", "start"], ["window_end", "end"]]) {
      const minutes = this.minutes(form.querySelector(`input[name="${name}"]`)?.value)
      const el = this.el.querySelector(`[data-handle="${handle}"]`)
      if (el && minutes !== null) el.style.left = `${minutes / 14.4}%`
    }
  }
}

const FocusSelect = {
  mounted() {
    this.el.focus()
    this.el.select()
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault()
        this.el.blur()
      }
    })
  }
}

const HookPicker = {
  mounted() {
    const panel = this.el.querySelector(".dropdown-content")
    const place = () => {
      const r = this.el.getBoundingClientRect()
      const margin = 8
      const width = Math.min(512, window.innerWidth - margin * 2)
      const group = this.el.querySelector('[data-group="Damage Type"]')
      let target = r.left + r.width / 2 - width / 2
      if (group) {
        const gr = group.getBoundingClientRect()
        const er = this.el.getBoundingClientRect()
        target = r.left + r.width / 2 - (gr.left - er.left) - gr.width / 2
      }
      const left = Math.max(margin, Math.min(target, window.innerWidth - width - margin))
      const below = window.innerHeight - r.bottom - margin
      const above = r.top - margin
      const openUp = below < 240 && above > below
      panel.style.position = "fixed"
      panel.style.width = `${width}px`
      panel.style.left = `${left}px`
      panel.style.overflowY = "auto"
      panel.style.maxHeight = `${Math.max(120, (openUp ? above : below) - 4)}px`
      panel.style.top = openUp ? "auto" : `${r.bottom + 4}px`
      panel.style.bottom = openUp ? `${window.innerHeight - r.top + 4}px` : "auto"
    }
    this.place = place
    this.onFocus = () => {
      place()
      window.addEventListener("scroll", place, true)
      window.addEventListener("resize", place)
    }
    this.onBlur = () => {
      window.removeEventListener("scroll", place, true)
      window.removeEventListener("resize", place)
    }
    this.el.addEventListener("focusin", this.onFocus)
    this.el.addEventListener("focusout", this.onBlur)
  },
  destroyed() {
    window.removeEventListener("scroll", this.place, true)
    window.removeEventListener("resize", this.place)
  }
}

const AnchoredPopup = {
  mounted() {
    this.place = () => {
      const anchor = document.getElementById(this.el.dataset.anchor)
      if (!anchor) return
      const r = anchor.getBoundingClientRect()
      const margin = 8
      this.el.style.position = "fixed"
      this.el.style.overflowY = "auto"
      this.el.style.margin = "0"
      this.el.style.right = "auto"
      const width = Math.min(512, window.innerWidth - margin * 2)
      this.el.style.width = `${width}px`
      const columns = this.el.firstElementChild
      const cs = getComputedStyle(columns)
      const gap = parseFloat(cs.columnGap) || 0
      const inset = columns.getBoundingClientRect().left - this.el.getBoundingClientRect().left
      const gapCenter = inset + (columns.clientWidth - gap * 2) / 3 + gap / 2
      const target = r.left + r.width / 2 - gapCenter
      const left = Math.max(margin, Math.min(target, r.left, window.innerWidth - width - margin))
      const below = window.innerHeight - r.bottom - margin
      const above = r.top - margin
      const openUp = below < 240 && above > below
      this.el.style.left = `${left}px`
      this.el.style.maxHeight = `${Math.max(120, (openUp ? above : below) - 4)}px`
      this.el.style.top = openUp ? "auto" : `${r.bottom + 4}px`
      this.el.style.bottom = openUp ? `${window.innerHeight - r.top + 4}px` : "auto"
    }
    this.el.showPopover()
    this.place()
    this.placed = this.el.style.cssText
    this.onResize = () => {
      this.place()
      this.placed = this.el.style.cssText
    }
    window.addEventListener("resize", this.onResize)
  },
  updated() {
    this.el.style.cssText = this.placed
  },
  destroyed() {
    window.removeEventListener("resize", this.onResize)
  }
}

const DblClickEvent = {
  mounted() {
    this.el.addEventListener("dblclick", () => this.pushEvent(this.el.dataset.event, { id: this.el.dataset.id }))
  }
}

const RightClickEvent = {
  mounted() {
    this.el.addEventListener("contextmenu", (e) => {
      e.preventDefault()
      this.pushEvent(this.el.dataset.event, { track: this.el.dataset.track, floor: this.el.dataset.floor })
    })
  }
}

const PathPicker = {
  mounted() {
    this.index = 0
    this.query = null
    this.el.addEventListener("keydown", (e) => {
      if (e.target.tagName !== "INPUT") return
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        const options = this.options()
        if (options.length === 0) {
          this.index = 0
          if (e.target.value.trim() === "") this.pushEvent("path_browse", {})
          return
        }
        const step = e.key === "ArrowDown" ? 1 : -1
        this.index = (this.index + step + options.length) % options.length
        this.paint()
      } else if (e.key === "Enter") {
        const option = this.options()[this.index]
        if (option) {
          e.preventDefault()
          option.click()
        }
      }
    })
    this.sync()
  },
  updated() {
    this.sync()
  },
  options() {
    return Array.from(this.el.querySelectorAll("[data-path-option]"))
  },
  sync() {
    const query = this.el.querySelector("input[name=query]")?.value ?? ""
    if (query !== this.query) this.index = 0
    this.query = query
    this.paint()
  },
  paint() {
    const options = this.options()
    if (this.index >= options.length) this.index = 0
    options.forEach((option, i) => option.setAttribute("aria-selected", String(i === this.index)))
    options[this.index]?.scrollIntoView({ block: "nearest" })
  }
}

const PriorityRightClick = {
  mounted() {
    this.el.addEventListener("contextmenu", (e) => {
      e.preventDefault()
      const cell = e.target.closest("[data-floors]")
      if (!cell) return
      const { packId, mode } = this.el.dataset
      this.pushEvent("toggle_cell", { pack_id: packId, mode, floors: cell.dataset.floors, action: "banned" })
    })
  }
}

const TemplateTransfer = {
  mounted() {
    const input = this.el.querySelector("[data-file]")

    this.handleEvent("download_template", ({ name, data }) => {
      const a = document.createElement("a")
      a.href = `data:image/png;base64,${data}`
      a.download = `${name}.png`
      a.click()
    })

    this.handleEvent("copy_template", async ({ data }) => {
      const bytes = Uint8Array.from(atob(data), (c) => c.charCodeAt(0))
      await navigator.clipboard.write([new ClipboardItem({ "image/png": new Blob([bytes], { type: "image/png" }) })])
    })

    this.el.querySelector("[data-upload]").addEventListener("click", () => input.click())

    this.el.querySelector("[data-blacken]").addEventListener("click", () => {
      if (!confirm("Replace this template with a 5×5 checker pattern? The current image will be lost.")) return
      const canvas = document.createElement("canvas")
      canvas.width = 5
      canvas.height = 5
      const ctx = canvas.getContext("2d")
      ctx.fillStyle = "#fff"
      ctx.fillRect(0, 0, 5, 5)
      ctx.fillStyle = "#000"
      for (let y = 0; y < 5; y++) {
        for (let x = 0; x < 5; x++) {
          if ((x + y) % 2 === 0) ctx.fillRect(x, y, 1, 1)
        }
      }
      this.pushEvent("upload_template", { name: this.el.dataset.name, data: canvas.toDataURL("image/png").split(",")[1] })
    })

    input.addEventListener("change", () => {
      const file = input.files[0]
      input.value = ""
      if (!file) return
      const url = URL.createObjectURL(file)
      const img = new Image()
      img.onload = () => {
        const canvas = document.createElement("canvas")
        canvas.width = img.naturalWidth
        canvas.height = img.naturalHeight
        canvas.getContext("2d").drawImage(img, 0, 0)
        URL.revokeObjectURL(url)
        this.pushEvent("upload_template", { name: this.el.dataset.name, data: canvas.toDataURL("image/png").split(",")[1] })
      }
      img.src = url
    })
  }
}

// --- LiveSocket setup ---

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { ScreenshotCanvas, EnemyLabelCanvas, BattleInspectorCanvas, BattleHistoryCanvas, ChainPreviewCanvas, TargetPreviewCanvas, DungeonInspectorCanvas, GiftInspectorCanvas, TemplateTransfer, EditableNotes, PreserveScroll, ScrollToBottom, LogVirtual, PlanClipboard, ItemClipboard, PriorityChips, LocalStorageForm, SortableList, GiftDragSource, GiftDropZone, RegionDragDrop, ChannelBand, DblClickEvent, RightClickEvent, PriorityRightClick, PathPicker, DragScroll, TeamNavMemory, HookPicker, AnchoredPopup, ViewMemory, GiftPopup, FocusSelect, WindowDrag, GameStream }
})

liveSocket.connect()
window.liveSocket = liveSocket
