import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }

  open(event) {
    if (event.defaultPrevented || this.interactiveElement(event.target)) return

    Turbo.visit(this.urlValue)
  }

  openWithKeyboard(event) {
    if (!["Enter", " "].includes(event.key) || event.defaultPrevented || this.interactiveElement(event.target)) return

    event.preventDefault()
    Turbo.visit(this.urlValue)
  }

  interactiveElement(target) {
    return target.closest("a, button, input, select, textarea, label, summary, details")
  }
}
