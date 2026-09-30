import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["bar"]
  static values = {
    duration: { type: Number, default: 5000 }
  }

  connect() {
    if (this.durationValue <= 0) return

    this.dismissTimeout = window.setTimeout(() => this.dismiss(), this.durationValue)

    this.animationFrame = window.requestAnimationFrame(() => {
      this.barTarget.style.transition = `width ${this.durationValue}ms linear`
      this.barTarget.style.width = "0%"
    })
  }

  disconnect() {
    window.clearTimeout(this.dismissTimeout)
    window.clearTimeout(this.removeTimeout)
    window.cancelAnimationFrame(this.animationFrame)
  }

  dismiss() {
    window.clearTimeout(this.dismissTimeout)
    window.cancelAnimationFrame(this.animationFrame)
    this.element.classList.add("opacity-0", "-translate-y-2")
    window.clearTimeout(this.removeTimeout)
    this.removeTimeout = window.setTimeout(() => this.element.remove(), 160)
  }
}
