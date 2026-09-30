import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
import { createContext, SourceTextModule, SyntheticModule } from "node:vm"

const source = await readFile(new URL("../../app/javascript/controllers/auto_refresh_controller.js", import.meta.url), "utf8")

async function setup(fetch) {
  const timers = new Map()
  const listeners = new Map()
  let nextTimer = 0
  const document = {
    hidden: false,
    addEventListener: (name, callback) => listeners.set(name, callback),
    removeEventListener: (name, callback) => {
      if (listeners.get(name) === callback) listeners.delete(name)
    },
  }
  const context = createContext({
    URL, AbortController, fetch, document,
    window: {
      location: { href: "https://example.test/now" },
      setTimeout: (callback) => {
        timers.set(++nextTimer, callback)
        return nextTimer
      },
      clearTimeout: (id) => timers.delete(id),
    },
  })
  const module = new SourceTextModule(source, { context })
  await module.link((specifier) => {
    assert.equal(specifier, "@hotwired/stimulus")
    return new SyntheticModule(["Controller"], function() {
      this.setExport("Controller", class {})
    }, { context })
  })
  await module.evaluate()
  const controller = new module.namespace.default()
  controller.intervalValue = 10000
  controller.urlValue = "/now/sessions"
  controller.element = { innerHTML: "original" }
  controller.connect()
  return { controller, timers, listeners, document }
}

function deferred() {
  let resolve
  const promise = new Promise((done) => { resolve = done })
  return { promise, resolve }
}

const response = (html = "updated") => ({ ok: true, text: async () => html })

test("slow requests never overlap and schedule the next poll after completion", async () => {
  const pending = deferred()
  let calls = 0
  const { controller, timers } = await setup(() => { calls++; return pending.promise })
  const refresh = controller.refresh()
  await controller.refresh()
  assert.equal(calls, 1)
  assert.equal(timers.size, 0)
  pending.resolve(response())
  await refresh
  assert.equal(controller.element.innerHTML, "updated")
  assert.equal(timers.size, 1)
  controller.disconnect()
})

test("disconnect aborts transport and a late response cannot overwrite a reconnected page", async () => {
  const pending = deferred()
  let signal
  const { controller, timers, listeners } = await setup((_url, options) => {
    signal = options.signal
    return pending.promise
  })
  const refresh = controller.refresh()
  controller.disconnect()
  assert.equal(signal.aborted, true)
  assert.equal(timers.size, 0)
  assert.equal(listeners.size, 0)
  controller.connect()
  pending.resolve(response("stale"))
  await refresh
  assert.equal(controller.element.innerHTML, "original")
  assert.equal(timers.size, 1)
  controller.disconnect()
})

test("disconnect during body reading prevents insertion", async () => {
  const body = deferred()
  const { controller, timers } = await setup(async () => ({ ok: true, text: () => body.promise }))
  const refresh = controller.refresh()
  await Promise.resolve()
  controller.disconnect()
  body.resolve("stale body")
  await refresh
  assert.equal(controller.element.innerHTML, "original")
  assert.equal(timers.size, 0)
})

test("failed requests preserve content and retry later", async () => {
  const { controller, timers } = await setup(async () => { throw new Error("offline") })
  await controller.refresh()
  assert.equal(controller.element.innerHTML, "original")
  assert.equal(timers.size, 1)
  controller.disconnect()
})

test("redirected responses stop polling without inserting the sign-in page", async () => {
  const { controller, timers } = await setup(async () => ({ ...response(), redirected: true }))
  await controller.refresh()
  assert.equal(controller.element.innerHTML, "original")
  assert.equal(timers.size, 0)
  controller.disconnect()
})

test("hidden tabs stop polling and resume with one timer when visible", async () => {
  const { controller, timers, listeners, document } = await setup(async () => response())
  document.hidden = true
  listeners.get("visibilitychange")()
  assert.equal(timers.size, 0)
  document.hidden = false
  listeners.get("visibilitychange")()
  assert.equal(timers.size, 1)
  controller.disconnect()
})

test("whole-panel responses replace the controller root and stop its old polling loop", async () => {
  const html = '<div data-controller="auto-refresh">running</div>'
  const { controller, timers } = await setup(async () => response(html))
  controller.replaceValue = true

  await controller.refresh()

  assert.equal(controller.element.outerHTML, html)
  assert.equal(controller.element.innerHTML, "original")
  assert.equal(controller.active, false)
  assert.equal(controller.request, null)
  assert.equal(timers.size, 0)
  controller.disconnect()
})

test("a completed whole-panel response leaves no old timer that can continue polling", async () => {
  const html = "<div>completed</div>"
  let calls = 0
  const { controller, timers } = await setup(async () => { calls++; return response(html) })
  controller.replaceValue = true

  await controller.refresh()
  await controller.refresh()

  assert.equal(controller.element.outerHTML, html)
  assert.equal(calls, 1)
  assert.equal(timers.size, 0)
  controller.disconnect()
})
