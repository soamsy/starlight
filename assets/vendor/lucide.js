const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = plugin(function ({ matchComponents, theme }) {
  const iconsDir = path.join(__dirname, "../../deps/lucide/icons")
  const values = {}

  fs.readdirSync(iconsDir).forEach(file => {
    if (!file.endsWith(".svg")) return
    values[path.basename(file, ".svg")] = { name: path.basename(file, ".svg"), fullPath: path.join(iconsDir, file) }
  })

  matchComponents({
    "lucide": ({ name, fullPath }) => {
      const content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
      const url = `url('data:image/svg+xml;utf8,${content.replace(/#/g, "%23")}')`
      return {
        [`--lucide-${name}`]: url,
        "mask": `var(--lucide-${name})`,
        "mask-repeat": "no-repeat",
        "mask-size": "100% 100%",
        "background-color": "currentColor",
        "vertical-align": "middle",
        "display": "inline-block",
        "width": theme("spacing.4"),
        "height": theme("spacing.4")
      }
    }
  }, { values })
})
