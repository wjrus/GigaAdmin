import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
import { createContext, SourceTextModule, SyntheticModule } from "node:vm"

const source = await readFile(new URL("../../app/javascript/controllers/activity_chart_controller.js", import.meta.url), "utf8")

async function setup() {
  const timers = new Map()
  const window = {
    innerWidth: 1000, innerHeight: 800,
    setTimeout(callback) { timers.set(1, callback); return 1 },
    clearTimeout(id) { timers.delete(id) },
  }
  const document = { documentElement: { get clientWidth() { return window.innerWidth - 15 } } }
  const context = createContext({ window, document })
  const module = new SourceTextModule(source, { context })
  await module.link(() => new SyntheticModule(["Controller"], function() {
    this.setExport("Controller", class {})
  }, { context }))
  await module.evaluate()
  const controller = new module.namespace.default()
  controller.pointsValue = ["Oct 3, 2026 12:00 UTC\nAll streams: 0 streams\n1 poll", "Not observed\n0 polls", "All streams: 4 streams\n10 polls"]
  const nativeTitle = { remove() { this.removed = true } }
  controller.svgTarget = { querySelectorAll: () => [nativeTitle] }
  controller.plotTarget = {
    x: { baseVal: { value: 48 } }, width: { baseVal: { value: 660 } },
    getBoundingClientRect: () => ({ left: 100, right: 760, top: 200, bottom: 340, width: 660 }),
  }
  controller.cursorTarget = { setAttribute(name, value) { this[name] = value } }
  controller.tooltipTarget = {
    hidden: true, style: {},
    matches() { return Boolean(this.hovered) },
    showPopover() { this.open = true }, hidePopover() { this.open = false },
    getBoundingClientRect: () => ({ width: 220, height: 110 }),
  }
  controller.element = { contains: (target) => target === controller.tooltipTarget || target === controller.svgTarget }
  controller.connect()
  return { controller, window, timers, nativeTitle }
}

test("hovering anywhere inside the plot selects the nearest bucket at rendered scale", async () => {
  const { controller, nativeTitle, timers } = await setup()
  controller.show({ clientX: 290, clientY: 300 })
  assert.equal(controller.index, 1)
  assert.equal(controller.tooltipTarget.textContent, "Not observed\n0 polls")
  assert.equal(controller.cursorTarget.x1, 378)
  assert.equal(controller.cursorTarget.visibility, "visible")
  assert.equal(controller.tooltipTarget.open, true)
  assert.equal(nativeTitle.removed, true)
  controller.show({ clientX: 100, clientY: 210 })
  assert.match(controller.tooltipTarget.textContent, /0 streams/)
  controller.show({ clientX: 760, clientY: 339 })
  assert.equal(controller.index, 2)
  controller.show({ clientX: 761, clientY: 300 })
  timers.get(1)()
  assert.equal(controller.tooltipTarget.hidden, true)
})

test("keyboard navigation is bounded and dismissed tooltips can reopen on the same sample", async () => {
  const { controller } = await setup()
  controller.focus()
  assert.equal(controller.index, 2)
  for (const [key, expected] of [["ArrowLeft", 1], ["Home", 0], ["ArrowLeft", 0], ["End", 2], ["ArrowRight", 2]]) {
    const event = { key, preventDefault() { this.prevented = true } }
    controller.navigate(event)
    assert.equal(controller.index, expected)
    assert.equal(event.prevented, true)
  }
  controller.hide()
  assert.equal(controller.cursorTarget.visibility, "hidden")
  assert.equal(controller.tooltipTarget.open, false)
  controller.focus()
  assert.equal(controller.tooltipTarget.hidden, false)
})

test("tooltip stays inside a narrow viewport without changing its data", async () => {
  const { controller, window } = await setup()
  window.innerWidth = 320
  window.innerHeight = 180
  controller.select(2)
  assert.equal(controller.tooltipTarget.style.left, "77px")
  assert.equal(controller.tooltipTarget.style.top, "62px")
  assert.equal(controller.tooltipTarget.textContent, controller.pointsValue[2])
})

test("tooltip is hoverable and touch inspection lasts until outside tap or dismissal", async () => {
  const { controller, timers } = await setup()
  controller.select(0)
  controller.leave({ relatedTarget: null, pointerType: "mouse" })
  assert.equal(timers.size, 1)
  controller.cancelHide()
  assert.equal(timers.size, 0)
  assert.equal(controller.tooltipTarget.hidden, false)
  controller.leave({ relatedTarget: null, pointerType: "touch" })
  assert.equal(timers.size, 0)
  controller.dismissOutside({ target: controller.svgTarget })
  assert.equal(controller.tooltipTarget.hidden, false)
  controller.dismissOutside({ target: {} })
  assert.equal(controller.tooltipTarget.hidden, true)
})

test("disconnect closes its popover and cancels pending dismissal", async () => {
  const { controller, timers } = await setup()
  controller.select(1)
  controller.leave({ relatedTarget: null })
  controller.disconnect()
  assert.equal(timers.size, 0)
  assert.equal(controller.tooltipTarget.hidden, true)
  assert.equal(controller.tooltipTarget.open, false)
})

test("moving focus does not close a tooltip while the pointer is over it", async () => {
  const { controller } = await setup()
  controller.focus()
  controller.tooltipTarget.hovered = true
  controller.blur()
  assert.equal(controller.tooltipTarget.hidden, false)
  controller.tooltipTarget.hovered = false
  controller.blur()
  assert.equal(controller.tooltipTarget.hidden, true)
})

test("empty datasets and browsers without popover support do not throw", async () => {
  const { controller } = await setup()
  delete controller.tooltipTarget.showPopover
  delete controller.tooltipTarget.hidePopover
  controller.select(0)
  assert.equal(controller.tooltipTarget.hidden, false)
  controller.hide()
  controller.pointsValue = []
  controller.focus()
  assert.equal(controller.tooltipTarget.hidden, true)
})
