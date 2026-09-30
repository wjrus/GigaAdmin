import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
import { createContext, SourceTextModule, SyntheticModule } from "node:vm"

const source = await readFile(new URL("../../app/javascript/controllers/deferred_page_controller.js", import.meta.url), "utf8")

async function setup() {
  const visits = []
  const attributes = new Map([["src", "/stats?period=30d"], ["aria-busy", "true"]])
  let reloads = 0
  const context = createContext({ URL, window: { location: { href: "https://example.test/stats?period=30d", origin: "https://example.test" } } })
  const module = new SourceTextModule(source, { context })
  await module.link((specifier) => {
    if (specifier === "@hotwired/stimulus") {
      return new SyntheticModule(["Controller"], function() { this.setExport("Controller", class {}) }, { context })
    }
    assert.equal(specifier, "@hotwired/turbo-rails")
    return new SyntheticModule(["Turbo"], function() {
      this.setExport("Turbo", { visit: (...arguments_) => visits.push(arguments_) })
    }, { context })
  })
  await module.evaluate()
  const controller = new module.namespace.default()
  controller.element = {
    disabled: true,
    getAttribute: (name) => attributes.get(name),
    hasAttribute: (name) => attributes.has(name),
    setAttribute: (name, value) => attributes.set(name, value),
    set src(value) { attributes.set("src", value) },
    reload: () => { reloads++ },
  }
  controller.signInUrlValue = "/sign_in"
  controller.setupUrlValue = "/setup"
  controller.hasLoadingTarget = true
  controller.hasErrorTarget = true
  controller.loadingTarget = { hidden: false }
  controller.errorTarget = { hidden: true }
  controller.connect()
  const event = (detail = {}, target = controller.element) => ({
    target, detail, defaultPrevented: false,
    preventDefault() { this.defaultPrevented = true },
  })
  return { controller, visits, attributes, event, reloads: () => reloads }
}

const fetchResponse = (options = {}) => ({ succeeded: true, isHTML: true, statusCode: 200,
  response: { redirected: false, ok: true, url: "https://example.test/stats?period=30d" }, ...options })

test("connect enables one native frame load and does not initiate a separate request or reload", async () => {
  const { controller, reloads } = await setup()
  assert.equal(controller.element.disabled, false)
  assert.equal(controller.pending, true)
  controller.retry()
  assert.equal(reloads(), 0)
})

test("transport failure keeps the placeholder available and retries only once per request", async () => {
  const { controller, event, attributes, reloads } = await setup()
  const error = event({ error: new Error("offline") })
  controller.failed(error)
  assert.equal(error.defaultPrevented, true)
  assert.equal(controller.loadingTarget.hidden, true)
  assert.equal(controller.errorTarget.hidden, false)
  assert.equal(attributes.get("aria-busy"), "false")

  controller.retry()
  controller.retry()
  assert.equal(reloads(), 1)
  assert.equal(controller.loadingTarget.hidden, false)
  assert.equal(controller.errorTarget.hidden, true)
  assert.equal(attributes.get("aria-busy"), "true")
})

test("HTTP errors empty responses and non-HTML responses never replace the navigation with an error document", async () => {
  for (const response of [fetchResponse({ succeeded: false, statusCode: 500 }), fetchResponse({ isHTML: false }), fetchResponse({ statusCode: 204 })]) {
    const { controller, event } = await setup()
    const received = event({ fetchResponse: response })
    controller.response(received)
    assert.equal(received.defaultPrevented, true)
    assert.equal(controller.errorTarget.hidden, false)
    assert.equal(controller.pending, false)
  }
})

test("successful frame responses use native rendering and finish the loading state", async () => {
  const { controller, event, attributes } = await setup()
  const received = event({ fetchResponse: fetchResponse() })
  controller.response(received)
  assert.equal(received.defaultPrevented, false)
  // Successful replacement removes placeholder targets from the frame.
  controller.hasLoadingTarget = false
  controller.hasErrorTarget = false
  controller.loaded(event())
  assert.equal(controller.pending, false)
  assert.equal(attributes.get("aria-busy"), "false")
})

test("a controlled HTML 404 can render its expected frame instead of trapping the user in retries", async () => {
  const { controller, event } = await setup()
  const received = event({ fetchResponse: fetchResponse({ succeeded: false, statusCode: 404 }) })
  controller.response(received)
  assert.equal(received.defaultPrevented, false)
})

test("authentication redirects navigate the full page only to an expected same-origin authentication endpoint", async () => {
  for (const path of ["/sign_in", "/setup"]) {
    const { controller, event, visits } = await setup()
    const response = { redirected: true, ok: true, url: `https://example.test${path}` }
    const received = event({ fetchResponse: fetchResponse({ response }) })
    controller.response(received)
    assert.equal(received.defaultPrevented, true)
    assert.equal(visits.length, 1)
    assert.equal(visits[0][0], response.url)
    assert.equal(visits[0][1].action, "replace")
  }
})

test("missing frames show a recoverable error unless an authentication redirect occurred", async () => {
  for (const response of [
    { redirected: false, ok: true, url: "https://example.test/sign_in" },
    { redirected: true, ok: true, url: "https://other.test/sign_in" },
    { redirected: true, ok: true, url: "https://example.test/unexpected" },
    { redirected: true, ok: false, url: "https://example.test/sign_in" },
  ]) {
    const { controller, event, visits } = await setup()
    const missing = event({ response })
    controller.missing(missing)
    assert.equal(missing.defaultPrevented, true)
    assert.equal(controller.errorTarget.hidden, false)
    assert.equal(visits.length, 0)
  }
  const { controller, event, visits } = await setup()
  controller.missing(event({ response: { redirected: true, ok: true, url: "https://example.test/sign_in" } }))
  assert.equal(visits.length, 1)
})

test("retry restores the original frame source after an unrelated missing-frame redirect", async () => {
  const { controller, event, attributes, reloads } = await setup()
  attributes.set("src", "https://example.test/unexpected")
  controller.missing(event({ response: { redirected: true, ok: true, url: "https://example.test/unexpected" } }))
  controller.retry()
  assert.equal(attributes.get("src"), "/stats?period=30d")
  assert.equal(reloads(), 0)
  assert.equal(controller.pending, true)
})

test("nested frame events and late events after disconnect cannot alter the page or redirect it", async () => {
  const { controller, event, visits, reloads } = await setup()
  const nested = event({ error: new Error("nested") }, {})
  controller.failed(nested)
  assert.equal(nested.defaultPrevented, false)
  assert.equal(controller.errorTarget.hidden, true)

  controller.disconnect()
  const late = event({ response: { redirected: true, ok: true, url: "https://example.test/sign_in" } })
  controller.missing(late)
  controller.failed(event())
  controller.retry()
  assert.equal(late.defaultPrevented, false)
  assert.equal(controller.errorTarget.hidden, true)
  assert.equal(visits.length, 0)
  assert.equal(reloads(), 0)
})
