import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["svg", "plot", "cursor", "tooltip"]
  static values = { points: Array }

  connect() {
    // Keep native SVG tooltips as a no-JavaScript fallback, without doubling up.
    this.svgTarget.querySelectorAll("title").forEach((title) => title.remove())
  }

  disconnect() {
    this.hide()
  }

  show(event) {
    this.cancelHide()
    const bounds = this.plotTarget.getBoundingClientRect()
    if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) {
      this.leave(event)
      return
    }
    const fraction = (event.clientX - bounds.left) / Math.max(bounds.width, 1)
    this.select(Math.round(fraction * (this.pointsValue.length - 1)))
  }

  focus() {
    this.select(this.index ?? this.pointsValue.length - 1)
  }

  blur() {
    if (!this.tooltipTarget.matches(":hover")) this.hide()
  }

  navigate(event) {
    const last = this.pointsValue.length - 1
    const current = this.index ?? last
    const index = { ArrowLeft: current - 1, ArrowRight: current + 1, Home: 0, End: last }[event.key]
    if (index === undefined) return

    event.preventDefault()
    this.select(Math.max(0, Math.min(last, index)))
  }

  select(index) {
    if (!this.pointsValue[index]) return
    if (this.index === index && !this.tooltipTarget.hidden) return

    this.index = index
    this.tooltipTarget.textContent = this.pointsValue[index]
    this.tooltipTarget.hidden = false
    this.tooltipTarget.showPopover?.()

    const fraction = index / Math.max(this.pointsValue.length - 1, 1)
    const plot = this.plotTarget
    const x = plot.x.baseVal.value + plot.width.baseVal.value * fraction
    this.cursorTarget.setAttribute("x1", x)
    this.cursorTarget.setAttribute("x2", x)
    this.cursorTarget.setAttribute("visibility", "visible")

    const bounds = plot.getBoundingClientRect()
    const anchor = bounds.left + bounds.width * fraction
    const tooltip = this.tooltipTarget.getBoundingClientRect()
    const viewportWidth = document.documentElement.clientWidth
    const left = Math.max(8, Math.min(anchor + 12, viewportWidth - tooltip.width - 8))
    const preferredTop = bounds.top - tooltip.height - 8
    const top = Math.max(8, Math.min(preferredTop >= 8 ? preferredTop : bounds.bottom + 8, window.innerHeight - tooltip.height - 8))
    this.tooltipTarget.style.left = `${left}px`
    this.tooltipTarget.style.top = `${top}px`
  }

  leave(event) {
    if (event.pointerType === "touch" || this.element.contains(event.relatedTarget)) return
    // Allow the pointer to cross the small gap between the plot and its tooltip.
    this.cancelHide()
    this.hideTimer = window.setTimeout(() => this.hide(), 150)
  }

  cancelHide() {
    window.clearTimeout(this.hideTimer)
  }

  dismissOutside(event) {
    if (!this.element.contains(event.target)) this.hide()
  }

  hide() {
    this.cancelHide()
    this.tooltipTarget.hidePopover?.()
    this.tooltipTarget.hidden = true
    this.cursorTarget.setAttribute("visibility", "hidden")
  }
}
