import { readFile, writeFile } from "node:fs/promises"
import { resolve } from "node:path"

const outputDirectory = resolve("../macos/Resources/ControlPanel")
const indexPath = resolve(outputDirectory, "index.html")
let html = await readFile(indexPath, "utf8")
const stylesheet = html.match(/<link rel="stylesheet" crossorigin href="([^"]+)">/)
const script = html.match(/<script type="module" crossorigin src="([^"]+)"><\/script>/)
if (!stylesheet || !script) throw new Error("Unable to locate generated assets")
const css = await readFile(resolve(outputDirectory, stylesheet[1]), "utf8")
const javascript = await readFile(resolve(outputDirectory, script[1]), "utf8")
html = html
  .replace(stylesheet[0], `<style>${css.replaceAll("</style>", "<\\/style>")}</style>`)
  .replace(
    script[0],
    `<script type="module">${javascript.replaceAll("</script>", "<\\/script>")}</script>`,
  )
await writeFile(indexPath, html)
