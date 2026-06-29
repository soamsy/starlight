// TemplateEditor LiveView hook
// Canvas-based template mask editor inside #template-editor-modal.
// Server sends "load_template_editor" {data: base64_png, name} to open the editor.
// On save, pushes "save_template_mask" {name, data: base64_png} back to the server.

const TemplateEditor = {
  mounted() {
    const canvas = this.el
    const ctx = canvas.getContext('2d')
    const box = canvas.closest('.modal-box')
    const qs = (attr) => box.querySelector(`[data-te="${attr}"]`)

    const workspace   = qs('workspace')  // container div; shape drags start here
    const paintBtn    = qs('paint')
    const eraseBtn    = qs('erase')
    const squareBtn   = qs('square')
    const lineBtn     = qs('line')
    const resetBtn    = qs('reset')
    const brushInput  = qs('brush')
    const brushLabel  = qs('brush-label')
    const threshBtn   = qs('threshold-toggle')
    const threshRow   = qs('threshold-row')
    const threshInput = qs('threshold-val')
    const threshLabel = qs('threshold-label')
    const undoBtn     = qs('undo')
    const saveBtn     = qs('save')
    const fileInput   = qs('file-input')
    const copyBtn     = qs('copy')
    const grayscaleBtn   = qs('grayscale')
    const brightUpBtn   = qs('brightness-up')
    const brightDownBtn = qs('brightness-down')

    let originalData   = null  // pixels as loaded from server; never mutated
    let editedData     = null  // saved snapshot of current edits (pre-threshold)
    let undoStack      = []    // ImageData snapshots, one per stroke
    let isDrawing      = false
    let lastPos        = null

    // Shared state for shape tools (square, line).
    // Coordinates are in canvas space and may be out-of-bounds during drag.
    let shapeStart       = null  // {x,y} anchor
    let shapeCurPos      = null  // current mouse pos
    let shapePreviewData = null  // canvas snapshot before drag (restored each preview frame)
    let shapeMoveDoc     = null  // document-level mousemove ref
    let shapeUpDoc       = null  // document-level mouseup ref

    let mode          = 'paint'
    let brushSize     = 10
    let threshPreview = false
    let threshold     = 127
    let currentName   = null

    const MAX_UNDO = 20

    // Convert any MouseEvent to canvas pixel coordinates.
    // Values outside [0, w/h] are valid — callers clip as needed.
    const getCanvasPos = (e) => {
      const r = canvas.getBoundingClientRect()
      return {
        x: Math.round((e.clientX - r.left) * canvas.width  / r.width),
        y: Math.round((e.clientY - r.top)  * canvas.height / r.height)
      }
    }

    const pushUndo = () => {
      undoStack.push(ctx.getImageData(0, 0, canvas.width, canvas.height))
      if (undoStack.length > MAX_UNDO) undoStack.shift()
      if (undoBtn) undoBtn.disabled = false
    }

    const popUndo = () => {
      undoStack.pop()
      if (undoBtn) undoBtn.disabled = undoStack.length === 0
    }

    const captureEdited = () => {
      editedData = ctx.getImageData(0, 0, canvas.width, canvas.height)
    }

    const restoreEdited = () => {
      if (editedData) ctx.putImageData(editedData, 0, 0)
      else if (originalData) ctx.putImageData(originalData, 0, 0)
    }

    const applyThreshold = () => {
      const src = editedData || ctx.getImageData(0, 0, canvas.width, canvas.height)
      const out = ctx.createImageData(canvas.width, canvas.height)
      for (let i = 0; i < src.data.length; i += 4) {
        const g = 0.299 * src.data[i] + 0.587 * src.data[i + 1] + 0.114 * src.data[i + 2]
        const v = g > threshold ? 255 : 0
        out.data[i] = out.data[i + 1] = out.data[i + 2] = v
        out.data[i + 3] = 255
      }
      ctx.putImageData(out, 0, 0)
    }

    const updateThreshUI = () => {
      if (threshBtn) {
        threshBtn.classList.toggle('btn-primary', threshPreview)
        threshBtn.classList.toggle('btn-outline', !threshPreview)
      }
      if (threshRow) threshRow.style.display = threshPreview ? 'flex' : 'none'
    }

    const setMode = (m) => {
      mode = m
      shapeStart = null; shapeCurPos = null; shapePreviewData = null
      const btns = { paint: paintBtn, erase: eraseBtn, square: squareBtn, line: lineBtn }
      for (const [name, btn] of Object.entries(btns)) {
        if (!btn) continue
        btn.classList.toggle('btn-primary', name === m)
        btn.classList.toggle('btn-outline', name !== m)
      }
      if (threshPreview) { threshPreview = false; restoreEdited(); updateThreshUI() }
    }

    paintBtn?.addEventListener('click',  () => setMode('paint'))
    eraseBtn?.addEventListener('click',  () => setMode('erase'))
    squareBtn?.addEventListener('click', () => setMode('square'))
    lineBtn?.addEventListener('click',   () => setMode('line'))

    undoBtn?.addEventListener('click', () => {
      if (!undoStack.length) return
      ctx.putImageData(undoStack.pop(), 0, 0)
      editedData = null
      if (undoBtn) undoBtn.disabled = undoStack.length === 0
      if (threshPreview) { threshPreview = false; updateThreshUI() }
    })

    resetBtn?.addEventListener('click', () => {
      if (!originalData) return
      pushUndo()
      ctx.putImageData(originalData, 0, 0)
      editedData = null
      if (threshPreview) { threshPreview = false; updateThreshUI() }
    })

    // Momentary color adjustments operate on whatever is currently on the canvas.
    // They exit threshold-preview mode first (same as setMode) so edits land on real pixels.
    const applyPixelOp = (transform) => {
      if (threshPreview) { threshPreview = false; restoreEdited(); updateThreshUI() }
      pushUndo()
      const img = ctx.getImageData(0, 0, canvas.width, canvas.height)
      const d = img.data
      for (let i = 0; i < d.length; i += 4) transform(d, i)
      ctx.putImageData(img, 0, 0)
      editedData = null
    }

    grayscaleBtn?.addEventListener('click', () => {
      applyPixelOp((d, i) => {
        const g = 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]
        d[i] = d[i + 1] = d[i + 2] = g
      })
    })

    const BRIGHTNESS_STEP = 1

    brightUpBtn?.addEventListener('click', () => {
      applyPixelOp((d, i) => {
        d[i]     = Math.min(255, d[i]     + BRIGHTNESS_STEP)
        d[i + 1] = Math.min(255, d[i + 1] + BRIGHTNESS_STEP)
        d[i + 2] = Math.min(255, d[i + 2] + BRIGHTNESS_STEP)
      })
    })

    brightDownBtn?.addEventListener('click', () => {
      applyPixelOp((d, i) => {
        d[i]     = Math.max(0, d[i]     - BRIGHTNESS_STEP)
        d[i + 1] = Math.max(0, d[i + 1] - BRIGHTNESS_STEP)
        d[i + 2] = Math.max(0, d[i + 2] - BRIGHTNESS_STEP)
      })
    })

    brushInput?.addEventListener('input', () => {
      brushSize = parseInt(brushInput.value)
      if (brushLabel) brushLabel.textContent = brushSize
    })

    threshBtn?.addEventListener('click', () => {
      threshPreview = !threshPreview
      if (threshPreview) { captureEdited(); applyThreshold() }
      else restoreEdited()
      updateThreshUI()
    })

    threshInput?.addEventListener('input', () => {
      threshold = parseInt(threshInput.value)
      if (threshLabel) threshLabel.textContent = threshold
      if (threshPreview) applyThreshold()
    })

    saveBtn?.addEventListener('click', () => {
      if (threshPreview) { threshPreview = false; restoreEdited(); updateThreshUI() }
      else captureEdited()
      requestAnimationFrame(() => {
        const b64 = canvas.toDataURL('image/png').split(',')[1]
        this.pushEvent('save_template_mask', { name: currentName, data: b64 })
        document.getElementById('template-editor-modal')?.close()
      })
    })

    // Upload: replace the canvas (and originalData) with an image from disk.
    // Resizes the canvas to the image's natural dimensions and clears undo history.
    fileInput?.addEventListener('change', (e) => {
      const file = e.target.files?.[0]
      if (!file) return
      const url = URL.createObjectURL(file)
      const img = new Image()
      img.onload = () => {
        canvas.width  = img.naturalWidth
        canvas.height = img.naturalHeight
        const scale = Math.max(1, Math.floor(Math.min(480 / canvas.width, 480 / canvas.height)))
        canvas.style.width  = (canvas.width  * scale) + 'px'
        canvas.style.height = (canvas.height * scale) + 'px'
        ctx.drawImage(img, 0, 0)
        originalData = ctx.getImageData(0, 0, canvas.width, canvas.height)
        editedData = null
        undoStack  = []
        shapeStart = null; shapeCurPos = null; shapePreviewData = null
        if (undoBtn) undoBtn.disabled = true
        if (threshPreview) { threshPreview = false; updateThreshUI() }
        URL.revokeObjectURL(url)
        e.target.value = ''  // allow re-uploading the same file
      }
      img.onerror = () => { URL.revokeObjectURL(url); e.target.value = '' }
      img.src = url
    })

    // Copy: write current canvas pixels (whatever is visible) to the system clipboard.
    copyBtn?.addEventListener('click', () => {
      canvas.toBlob((blob) => {
        if (!blob) return
        navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })])
          .then(() => {
            const prev = copyBtn.textContent
            copyBtn.textContent = '✓ Copied'
            setTimeout(() => { copyBtn.textContent = prev }, 1500)
          })
          .catch((err) => console.error('Clipboard write failed:', err))
      }, 'image/png')
    })

    // --- paint / erase ---

    const paintAt = (x, y) => {
      if (threshPreview) return
      ctx.save()
      ctx.lineWidth = brushSize
      ctx.lineCap = 'round'
      ctx.lineJoin = 'round'

      if (mode === 'paint') {
        ctx.strokeStyle = '#000'
        ctx.fillStyle = '#000'
        ctx.beginPath()
        if (lastPos) {
          ctx.moveTo(lastPos.x, lastPos.y)
          ctx.lineTo(x, y)
          ctx.stroke()
        } else {
          ctx.arc(x, y, brushSize / 2, 0, Math.PI * 2)
          ctx.fill()
        }
      } else if (originalData) {
        const r2 = Math.ceil(brushSize / 2)
        const x0 = Math.max(0, x - r2), y0 = Math.max(0, y - r2)
        const x1 = Math.min(canvas.width, x + r2), y1 = Math.min(canvas.height, y + r2)
        const pw = x1 - x0, ph = y1 - y0
        if (pw > 0 && ph > 0) {
          const current = ctx.getImageData(x0, y0, pw, ph)
          const patch = ctx.createImageData(pw, ph)
          for (let py = 0; py < ph; py++) {
            for (let px = 0; px < pw; px++) {
              const idx = (py * pw + px) * 4
              const dx = (x0 + px) - x, dy = (y0 + py) - y
              if (dx * dx + dy * dy <= r2 * r2) {
                const si = ((y0 + py) * canvas.width + (x0 + px)) * 4
                patch.data[idx]     = originalData.data[si]
                patch.data[idx + 1] = originalData.data[si + 1]
                patch.data[idx + 2] = originalData.data[si + 2]
                patch.data[idx + 3] = originalData.data[si + 3]
              } else {
                patch.data[idx]     = current.data[idx]
                patch.data[idx + 1] = current.data[idx + 1]
                patch.data[idx + 2] = current.data[idx + 2]
                patch.data[idx + 3] = current.data[idx + 3]
              }
            }
          }
          ctx.putImageData(patch, x0, y0)
        }
      }
      ctx.restore()
      lastPos = { x, y }
    }

    // --- square tool ---
    // Coords may be OOB; clip to canvas before drawing.

    const drawSquarePreview = (ax, ay, bx, by) => {
      const rx  = Math.max(0, Math.min(ax, bx))
      const ry  = Math.max(0, Math.min(ay, by))
      const rx2 = Math.min(canvas.width,  Math.max(ax, bx))
      const ry2 = Math.min(canvas.height, Math.max(ay, by))
      const rw = rx2 - rx, rh = ry2 - ry
      if (rw < 1 || rh < 1) return
      ctx.save()
      ctx.lineWidth = 1
      ctx.strokeStyle = 'rgba(255,255,255,0.7)'
      ctx.setLineDash([])
      ctx.strokeRect(rx + 0.5, ry + 0.5, rw, rh)
      ctx.strokeStyle = 'rgba(220,30,30,0.9)'
      ctx.setLineDash([3, 2])
      ctx.strokeRect(rx + 0.5, ry + 0.5, rw, rh)
      ctx.restore()
    }

    const commitSquare = (ax, ay, bx, by) => {
      const rx  = Math.max(0, Math.min(ax, bx))
      const ry  = Math.max(0, Math.min(ay, by))
      const rw  = Math.min(canvas.width,  Math.max(ax, bx)) - rx
      const rh  = Math.min(canvas.height, Math.max(ay, by)) - ry
      if (rw > 0 && rh > 0) {
        ctx.fillStyle = '#000'
        ctx.fillRect(rx, ry, rw, rh)
      } else {
        popUndo()
      }
    }

    // --- line tool ---
    // Uses canvas clipping so off-canvas endpoints are handled cleanly by the GPU.

    const withCanvasClip = (fn) => {
      ctx.save()
      ctx.beginPath()
      ctx.rect(0, 0, canvas.width, canvas.height)
      ctx.clip()
      fn()
      ctx.restore()
    }

    const drawLinePreview = (ax, ay, bx, by) => {
      withCanvasClip(() => {
        ctx.lineWidth = brushSize
        ctx.lineCap = 'round'
        // white halo
        ctx.strokeStyle = 'rgba(255,255,255,0.7)'
        ctx.setLineDash([])
        ctx.beginPath(); ctx.moveTo(ax, ay); ctx.lineTo(bx, by); ctx.stroke()
        // red dashes on top
        ctx.strokeStyle = 'rgba(220,30,30,0.9)'
        ctx.setLineDash([6, 4])
        ctx.beginPath(); ctx.moveTo(ax, ay); ctx.lineTo(bx, by); ctx.stroke()
      })
    }

    const commitLine = (ax, ay, bx, by) => {
      // Check if the line actually intersects the canvas before committing
      const dx = bx - ax, dy = by - ay
      const len = Math.sqrt(dx * dx + dy * dy)
      if (len < 1) { popUndo(); return }

      withCanvasClip(() => {
        ctx.lineWidth = brushSize
        ctx.lineCap = 'round'
        ctx.strokeStyle = '#000'
        ctx.setLineDash([])
        ctx.beginPath(); ctx.moveTo(ax, ay); ctx.lineTo(bx, by); ctx.stroke()
      })

      // If nothing was drawn inside the canvas, revert undo
      // (both points fully outside with no crossing — rare but possible)
      // We detect this by checking if any pixel changed; cheapest heuristic:
      // just always keep the undo entry since a zero-length line was already caught above.
    }

    // --- shared shape drag (square + line) ---
    // mousedown on workspace so drags can start outside the canvas;
    // mousemove/mouseup on document so they track globally.

    const cleanupShapeDrag = () => {
      if (shapeMoveDoc) { document.removeEventListener('mousemove', shapeMoveDoc); shapeMoveDoc = null }
      if (shapeUpDoc)   { document.removeEventListener('mouseup',   shapeUpDoc);   shapeUpDoc   = null }
    }

    const isShapeMode = () => mode === 'square' || mode === 'line'

    workspace?.addEventListener('mousedown', (e) => {
      if (e.button !== 0 || !isShapeMode()) return
      e.preventDefault()
      pushUndo()
      const p = getCanvasPos(e)
      shapeStart = p; shapeCurPos = p
      shapePreviewData = ctx.getImageData(0, 0, canvas.width, canvas.height)
      isDrawing = true

      const preview = mode === 'line' ? drawLinePreview : drawSquarePreview
      const commit  = mode === 'line' ? commitLine      : commitSquare
      const capturedMode = mode  // freeze at drag-start in case mode changes

      shapeMoveDoc = (ev) => {
        shapeCurPos = getCanvasPos(ev)
        ctx.putImageData(shapePreviewData, 0, 0)
        preview(shapeStart.x, shapeStart.y, shapeCurPos.x, shapeCurPos.y)
      }
      shapeUpDoc = () => {
        cleanupShapeDrag()
        const end = shapeCurPos || shapeStart
        ctx.putImageData(shapePreviewData, 0, 0)
        commit(shapeStart.x, shapeStart.y, end.x, end.y)
        shapeStart = null; shapeCurPos = null; shapePreviewData = null
        isDrawing = false
      }

      document.addEventListener('mousemove', shapeMoveDoc)
      document.addEventListener('mouseup',   shapeUpDoc)
    })

    // Paint/erase stay canvas-only (no off-canvas tracking needed for brushes)
    canvas.addEventListener('mousedown', (e) => {
      if (e.button !== 0 || isShapeMode()) return
      e.preventDefault()
      isDrawing = true; lastPos = null
      pushUndo()
      const p = getCanvasPos(e)
      paintAt(p.x, p.y)
    })

    canvas.addEventListener('mousemove', (e) => {
      if (!isDrawing || isShapeMode()) return
      const p = getCanvasPos(e)
      paintAt(p.x, p.y)
    })

    canvas.addEventListener('mouseup',    () => { if (!isShapeMode()) { isDrawing = false; lastPos = null } })
    canvas.addEventListener('mouseleave', () => { if (!isShapeMode()) { isDrawing = false; lastPos = null } })
    canvas.addEventListener('contextmenu', (e) => e.preventDefault())

    this.handleEvent('load_template_editor', ({ data, name }) => {
      currentName = name
      cleanupShapeDrag()
      const img = new Image()
      img.onload = () => {
        canvas.width = img.naturalWidth
        canvas.height = img.naturalHeight
        const scale = Math.max(1, Math.floor(Math.min(480 / img.naturalWidth, 480 / img.naturalHeight)))
        canvas.style.width  = (canvas.width  * scale) + 'px'
        canvas.style.height = (canvas.height * scale) + 'px'
        ctx.drawImage(img, 0, 0)
        originalData = ctx.getImageData(0, 0, canvas.width, canvas.height)
        editedData = null; undoStack = []
        shapeStart = null; shapeCurPos = null; shapePreviewData = null
        isDrawing = false
        if (undoBtn) undoBtn.disabled = true
        threshPreview = false
        updateThreshUI()
        setMode('paint')
        document.getElementById('template-editor-modal')?.showModal()
      }
      img.src = 'data:image/png;base64,' + data
    })
  }
}

export default TemplateEditor
