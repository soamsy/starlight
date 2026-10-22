import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import TemplateEditor from "./template_editor"

function postToServerLog(level, args) {
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

const LIGHT_THEME = 'valentine'
const DARK_THEME = 'halloween'

function activeTheme() {
  return localStorage.getItem('starlight-theme') ||
    (window.matchMedia('(prefers-color-scheme: dark)').matches ? DARK_THEME : LIGHT_THEME)
}

function applyTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme)
  const cb = document.getElementById('theme-toggle-cb')
  if (cb) cb.checked = (theme === DARK_THEME)
}

function toggleTheme() {
  const next = activeTheme() === DARK_THEME ? LIGHT_THEME : DARK_THEME
  localStorage.setItem('starlight-theme', next)
  applyTheme(next)
}

document.addEventListener('DOMContentLoaded', () => {
  applyTheme(activeTheme())
  const cb = document.getElementById('theme-toggle-cb')
  if (cb) cb.addEventListener('change', toggleTheme)
})

window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', e => {
  if (!localStorage.getItem('starlight-theme')) applyTheme(e.matches ? DARK_THEME : LIGHT_THEME)
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

    canvas.addEventListener("mousemove", (e) => {
      if (!selecting || !startPos) return
      let cur = getImageCoords(e)
      
      precisionMode = e.shiftKey

      if (e.shiftKey) {
        const dx = cur.x - startPos.x
        const dy = cur.y - startPos.y
        cur = {
          x: Math.round(startPos.x + dx / 10),
          y: Math.round(startPos.y + dy / 10)
        }
      }
      
      const x = Math.max(0, Math.min(startPos.x, cur.x))
      const y = Math.max(0, Math.min(startPos.y, cur.y))
      const w = Math.min(Math.abs(cur.x - startPos.x), canvas.width - x)
      const h = Math.min(Math.abs(cur.y - startPos.y), canvas.height - y)
      if (mode === "click") selClick = { x, y, w, h }
      else if (mode === "scan") selScan = { x, y, w, h }
      else sel = { x, y, w, h }
      redraw()
    })

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

    canvas.addEventListener("mouseup", finishSelect)
    canvas.addEventListener("mouseleave", finishSelect)
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
            ctx.font = "bold 14px monospace"
            ctx.fillText(o.text, o.text_x, o.text_y)
          }
        }
      }

      this.handleEvent(eventName, ({ data, overlays }) => {
        const img = new Image()
        img.onload = () => draw(img, overlays)
        img.src = "data:image/jpeg;base64," + data
      })
    }
  }
}

const BattleInspectorCanvas = overlayCanvasHook("load_battle_frame")
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

const SCROLL_PIN_THRESHOLD_PX = 60

const ScrollToBottom = {
  mounted() {
    this.el.scrollTop = this.el.scrollHeight
  },
  beforeUpdate() {
    this.pinned = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight <= SCROLL_PIN_THRESHOLD_PX
  },
  updated() {
    if (this.pinned) this.el.scrollTop = this.el.scrollHeight
  }
}

const PriorityClipboard = {
  mounted() {
    this.handleEvent("copy_priority_json", ({ text }) => {
      navigator.clipboard.writeText(text).catch(err => {
        this.pushEvent("paste_priority_failed", { message: `Couldn't copy to clipboard: ${err.message || err}` })
      })
    })

    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-paste-priority]")
      if (!btn) return
      const priority = btn.dataset.pastePriority

      navigator.clipboard.readText()
        .then(text => this.pushEvent("paste_priority", { priority, text }))
        .catch(err => {
          this.pushEvent("paste_priority_failed", { message: `Couldn't read clipboard: ${err.message || err}` })
        })
    })
  }
}

let sortDrag = null

const eventElement = (e) => (e.target instanceof Element ? e.target : e.target.parentElement)

const SortableList = {
  mounted() {
    this.el.addEventListener("mousedown", (e) => {
      const handle = eventElement(e)?.closest("[data-sort-handle]")
      if (!handle) return
      const item = handle.closest("[data-sort-id]")
      if (item && item.parentElement === this.el) item.draggable = true
    })

    this.el.addEventListener("dragstart", (e) => {
      const item = eventElement(e)?.closest("[data-sort-id]")
      if (!item || item.parentElement !== this.el) return
      sortDrag = { item, source: this.el }
      item.classList.add("opacity-40")
      e.dataTransfer.effectAllowed = "move"
    })

    this.el.addEventListener("dragover", (e) => {
      if (!sortDrag || !this.accepts(sortDrag)) return
      e.preventDefault()
      e.stopPropagation()
      const over = eventElement(e)?.closest("[data-sort-id]")
      if (!over && !Array.from(this.el.children).some(c => c.dataset.sortId)) {
        this.el.appendChild(sortDrag.item)
        return
      }
      if (!over || over === sortDrag.item || over.parentElement !== this.el) return
      const rect = over.getBoundingClientRect()
      const after = this.el.dataset.sortAxis === "x"
        ? e.clientX > rect.left + rect.width / 2
        : e.clientY > rect.top + rect.height / 2
      this.el.insertBefore(sortDrag.item, after ? over.nextSibling : over)
    })

    this.el.addEventListener("dragend", () => {
      if (!sortDrag || sortDrag.item.parentElement !== this.el) return
      const { item, source } = sortDrag
      sortDrag = null
      item.classList.remove("opacity-40")
      item.draggable = false
      const ids = Array.from(this.el.children).filter(c => c.dataset.sortId).map(c => c.dataset.sortId)
      const scope = this.el.dataset.sortScope || ""
      if (source === this.el) this.pushEvent(this.el.dataset.sortEvent, { scope, ids })
      else this.pushEvent(this.el.dataset.sortMoveEvent, { scope, from: source.dataset.sortScope || "", id: item.dataset.sortId, ids })
    })
  },

  accepts({ item, source }) {
    if (item.contains(this.el)) return false
    if (source === this.el) return true
    const shared = this.el.dataset.sortShared
    return !!shared && shared === source.dataset.sortShared && !("sortStay" in item.dataset) && !!this.el.dataset.sortMoveEvent
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

const DblClickEvent = {
  mounted() {
    this.el.addEventListener("dblclick", () => this.pushEvent(this.el.dataset.event, { id: this.el.dataset.id }))
  }
}

// --- LiveSocket setup ---

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { ScreenshotCanvas, BattleInspectorCanvas, ChainPreviewCanvas, TargetPreviewCanvas, DungeonInspectorCanvas, GiftInspectorCanvas, TemplateEditor, EditableNotes, PreserveScroll, ScrollToBottom, PriorityClipboard, LocalStorageForm, SortableList, DblClickEvent }
})

liveSocket.connect()
window.liveSocket = liveSocket
