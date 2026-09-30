import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
import { createContext, SourceTextModule, SyntheticModule } from "node:vm"

const source = await readFile(new URL("../../app/javascript/application.js", import.meta.url), "utf8")

async function setup(storage) {
  const listeners = new Map()
  const mediaListeners = []
  const picker = { value: "system" }
  const document = {
    documentElement: { dataset: {}, classList: { add() {}, remove() {} } },
    querySelectorAll: () => [picker],
    addEventListener(name, callback) {
      const callbacks = listeners.get(name) || []
      callbacks.push(callback)
      listeners.set(name, callbacks)
    },
  }
  const media = { matches: false, addEventListener: (_name, callback) => mediaListeners.push(callback) }
  const context = createContext({
    document,
    window: { localStorage: storage, matchMedia: () => media },
    requestAnimationFrame: (callback) => callback(),
  })
  const module = new SourceTextModule(source, { context })
  await module.link(() => new SyntheticModule([], () => {}, { context }))
  await module.evaluate()
  const dispatch = (name, event = {}) => listeners.get(name)?.forEach((callback) => callback(event))
  const choose = (value) => {
    picker.value = value
    dispatch("change", { target: { closest: () => picker } })
  }
  dispatch("DOMContentLoaded")
  return { document, picker, media, mediaListeners, listeners, dispatch, choose }
}

test("blocked storage does not prevent changing themes or retaining a choice across Turbo visits", async () => {
  const storage = { getItem() { throw new Error("blocked") }, setItem() { throw new Error("blocked") } }
  const state = await setup(storage)
  assert.equal(state.document.documentElement.dataset.theme, "light")

  state.choose("paper")
  state.dispatch("turbo:load")
  state.media.matches = true
  state.mediaListeners.forEach((callback) => callback())

  assert.equal(state.document.documentElement.dataset.theme, "paper")
  assert.equal(state.picker.value, "paper")
  assert.equal(state.listeners.get("change").length, 1)
  assert.equal(state.mediaListeners.length, 1)
})

test("a failed write cannot revert the selected theme to an older saved preference", async () => {
  const state = await setup({ getItem: () => "system", setItem() { throw new Error("quota") } })
  state.choose("amber")
  state.media.matches = true
  state.mediaListeners.forEach((callback) => callback())
  state.dispatch("turbo:load")

  assert.equal(state.document.documentElement.dataset.theme, "amber")
})

test("system theme follows OS changes while invalid preferences remain constrained", async () => {
  const saved = []
  const state = await setup({ getItem: () => "unknown", setItem: (key, value) => saved.push([key, value]) })
  state.media.matches = true
  state.mediaListeners.forEach((callback) => callback())
  assert.equal(state.document.documentElement.dataset.theme, "dark")

  state.choose("invalid-theme")
  assert.equal(state.picker.value, "system")
  assert.deepEqual(saved, [["plex-theme", "system"]])
})
