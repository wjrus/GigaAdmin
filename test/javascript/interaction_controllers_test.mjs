import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
import { createContext, SourceTextModule, SyntheticModule } from "node:vm"

async function controllerFor(name, globals = {}) {
  const source = await readFile(new URL(`../../app/javascript/controllers/${name}_controller.js`, import.meta.url), "utf8")
  const context = createContext(globals)
  const module = new SourceTextModule(source, { context })
  await module.link((specifier) => {
    assert.equal(specifier, "@hotwired/stimulus")
    return new SyntheticModule(["Controller"], function() {
      this.setExport("Controller", class {})
    }, { context })
  })
  await module.evaluate()
  return new module.namespace.default()
}

function clickEvent(overrides = {}, interactive = false) {
  return {
    button: 0,
    defaultPrevented: false,
    target: { closest: () => interactive ? {} : null },
    preventDefault() { this.defaultPrevented = true },
    ...overrides,
  }
}

test("clicking a non-interactive cell navigates to its row's user", async () => {
  const visits = []
  const controller = await controllerFor("row_link", { Turbo: { visit: (url) => visits.push(url) } })
  controller.urlValue = "/users/42"
  controller.open(clickEvent())
  assert.deepEqual(visits, ["/users/42"])
})

test("row clicks leave native links, controls, modified clicks, and handled events alone", async () => {
  const visits = []
  const controller = await controllerFor("row_link", { Turbo: { visit: (url) => visits.push(url) } })
  controller.open(clickEvent({}, true))
  for (const overrides of [{ defaultPrevented: true }, { button: 1 }, { metaKey: true }, { ctrlKey: true }, { shiftKey: true }, { altKey: true }]) {
    controller.open(clickEvent(overrides))
  }
  assert.deepEqual(visits, [])
})

test("confirmation is consumed by one submission and cannot bypass a later action", async () => {
  const controller = await controllerFor("confirmation")
  let submissions = 0
  let confirmations = 0
  controller.titleTarget = {}
  controller.bodyTarget = {}
  controller.confirmButtonTarget = {}
  controller.dialogTarget = { showModal: () => confirmations++, close() {} }
  const form = {
    dataset: {},
    requestSubmit() {
      const event = { target: form, defaultPrevented: false, preventDefault() { this.defaultPrevented = true } }
      controller.confirmSubmit(event)
      if (!event.defaultPrevented) submissions++
    },
  }
  form.requestSubmit()
  assert.equal(submissions, 0)
  assert.equal(confirmations, 1)
  controller.submit()
  assert.equal(submissions, 1)
  assert.equal(form.dataset.confirmed, undefined)
  controller.submit()
  assert.equal(submissions, 1)
  form.requestSubmit()
  assert.equal(submissions, 1)
  assert.equal(confirmations, 2)
})

test("failed form validation does not retain confirmation for a later submission", async () => {
  const controller = await controllerFor("confirmation")
  const form = { dataset: {}, requestSubmit() {} }
  controller.pendingForm = form
  controller.dialogTarget = { close() {} }
  controller.submit()
  assert.equal(form.dataset.confirmed, undefined)
  assert.equal(controller.pendingForm, null)
})

test("Escape cancellation clears the pending destructive action", async () => {
  const controller = await controllerFor("confirmation")
  let submissions = 0
  let closed = 0
  const event = { preventDefault() { this.defaultPrevented = true } }
  controller.pendingForm = { requestSubmit: () => submissions++ }
  controller.dialogTarget = { close: () => closed++ }

  controller.cancel(event)
  controller.submit()

  assert.equal(event.defaultPrevented, true)
  assert.equal(controller.pendingForm, null)
  assert.equal(closed, 1)
  assert.equal(submissions, 0)
})

async function flashController(duration) {
  const timers = new Map()
  const frames = new Map()
  let nextId = 0
  const controller = await controllerFor("flash", { window: {
    setTimeout: (callback) => { timers.set(++nextId, callback); return nextId },
    clearTimeout: (id) => timers.delete(id),
    requestAnimationFrame: (callback) => { frames.set(++nextId, callback); return nextId },
    cancelAnimationFrame: (id) => frames.delete(id),
  } })
  controller.durationValue = duration
  controller.barTarget = { style: {} }
  controller.element = { classList: { add() {} }, remove() { this.removed = true } }
  return { controller, timers, frames }
}

test("persistent alerts remain until explicitly dismissed", async () => {
  const { controller, timers, frames } = await flashController(0)

  controller.connect()
  assert.equal(timers.size, 0)
  assert.equal(frames.size, 0)
  controller.dismiss()
  assert.equal(timers.size, 1)
  timers.values().next().value()
  assert.equal(controller.element.removed, true)
  controller.disconnect()
})

test("disconnect cancels flash animation and dismissal callbacks", async () => {
  const { controller, timers, frames } = await flashController(5000)

  controller.connect()
  assert.equal(timers.size, 1)
  assert.equal(frames.size, 1)
  controller.disconnect()
  assert.equal(timers.size, 0)
  assert.equal(frames.size, 0)

  controller.connect()
  controller.dismiss()
  controller.dismiss()
  assert.equal(timers.size, 1)
  assert.equal(frames.size, 0)
  controller.disconnect()
  assert.equal(timers.size, 0)
  assert.equal(controller.element.removed, undefined)
})
