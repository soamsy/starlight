import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

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
      const mode = btn.dataset.pasteMode

      navigator.clipboard.readText()
        .then(text => this.pushEvent("paste_priority", { priority, mode, text }))
        .catch(err => {
          this.pushEvent("paste_priority_failed", { message: `Couldn't read clipboard: ${err.message || err}` })
        })
    })
  }
}

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
      if (!btn || !window.confirm(btn.dataset.confirm)) return

      navigator.clipboard.readText()
        .then(text => this.pushEvent("paste_plan", { text }))
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

    const place = (parent, ref) => {
      const drag = sortDrag
      if (drag.item.parentElement === drag.source && parent !== drag.source && !drag.spacer) {
        drag.spacer = document.createElement("div")
        drag.spacer.style.height = `${drag.item.offsetHeight}px`
        drag.source.insertBefore(drag.spacer, drag.item)
      }
      parent.insertBefore(drag.item, ref)
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
      if (!over || over === sortDrag.item) return
      const rect = over.getBoundingClientRect()
      if (over.querySelector("[data-sort-move-event]") && e.clientY > rect.top + SORT_EDGE_PX && e.clientY < rect.bottom - SORT_EDGE_PX) return
      const after = this.el.dataset.sortAxis === "x"
        ? e.clientX > rect.left + rect.width / 2
        : e.clientY > rect.top + rect.height / 2
      place(this.el, after ? over.nextSibling : over)
    })

    this.el.addEventListener("dragend", () => {
      if (!sortDrag || sortDrag.item.parentElement !== this.el) return
      const { item, source, highlight, spacer } = sortDrag
      spacer?.remove()
      highlight?.classList.remove("bg-primary/15")
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
  hooks: { ScreenshotCanvas, BattleInspectorCanvas, ChainPreviewCanvas, TargetPreviewCanvas, DungeonInspectorCanvas, GiftInspectorCanvas, TemplateTransfer, EditableNotes, PreserveScroll, ScrollToBottom, PriorityClipboard, PlanClipboard, ItemClipboard, PriorityChips, LocalStorageForm, SortableList, GiftDragSource, GiftDropZone, RegionDragDrop, ChannelBand, DblClickEvent, RightClickEvent, DragScroll, TeamNavMemory, ViewMemory, GiftPopup, FocusSelect }
})

liveSocket.connect()
window.liveSocket = liveSocket
