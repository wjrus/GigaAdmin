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

function keyboardEvent(key, interactive = false) {
  return {
    key,
    defaultPrevented: false,
    target: { closest: () => interactive ? {} : null },
    preventDefault() { this.defaultPrevented = true },
  }
}

test("row links navigate with Enter and Space and suppress their browser defaults", async () => {
  const visits = []
  const controller = await controllerFor("row_link", { Turbo: { visit: (url) => visits.push(url) } })
  controller.urlValue = "/users/42"
  for (const key of ["Enter", " "]) {
    const event = keyboardEvent(key)
    controller.openWithKeyboard(event)
    assert.equal(event.defaultPrevented, true)
  }
  assert.deepEqual(visits, ["/users/42", "/users/42"])
})

test("row links leave nested controls and handled keyboard events alone", async () => {
  const visits = []
  const controller = await controllerFor("row_link", { Turbo: { visit: (url) => visits.push(url) } })
  const nested = keyboardEvent("Enter", true)
  controller.openWithKeyboard(nested)
  assert.equal(nested.defaultPrevented, false)
  const handled = keyboardEvent("Enter")
  handled.preventDefault()
  controller.openWithKeyboard(handled)
  controller.openWithKeyboard(keyboardEvent("Tab"))
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
