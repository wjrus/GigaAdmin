import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }

  open(event) {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || this.interactiveElement(event.target)) return

    Turbo.visit(this.urlValue)
  }

  interactiveElement(target) {
    return target.closest("a, button, input, select, textarea, label, summary, details")
  }
}
