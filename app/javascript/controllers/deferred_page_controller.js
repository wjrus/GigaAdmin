import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Turbo owns the request and cancels it when the frame leaves the document.
// This controller only enhances loading failures; it never starts a fetch loop.
export default class extends Controller {
  static targets = ["loading", "error"]
  static values = { signInUrl: String, setupUrl: String }

  connect() {
    this.active = true
    this.pending = !this.element.hasAttribute("complete")
    this.source = this.element.getAttribute("src")
    // Attach Stimulus actions before allowing the initial native request. An eager
    // frame can otherwise finish before its importmapped controller has loaded.
    this.element.disabled = false
  }

  disconnect() {
    this.active = false
    // Stimulus removes the declarative event listeners on disconnect.
  }

  loading(event) {
    if (!this.owns(event)) return

    this.pending = true
    this.element.setAttribute("aria-busy", "true")
    if (this.hasLoadingTarget) this.loadingTarget.hidden = false
    if (this.hasErrorTarget) this.errorTarget.hidden = true
  }

  response(event) {
    if (!this.owns(event)) return

    const response = event.detail.fetchResponse
    // A known missing user renders a useful 404 inside the expected frame.
    // Unframed 404 pages still flow through the missing-frame recovery handler.
    const renderable = response.succeeded || response.statusCode === 404
    if (!renderable || !response.isHTML || response.statusCode === 204) {
      event.preventDefault()
      this.showError()
    } else if (this.authenticationRedirect(response.response)) {
      event.preventDefault()
      Turbo.visit(response.response.url, { action: "replace" })
    }
  }

  failed(event) {
    if (!this.owns(event)) return

    event.preventDefault()
    this.showError()
  }

  missing(event) {
    if (!this.owns(event)) return

    // Keep the navigation and recovery controls instead of Turbo's missing-frame error.
    event.preventDefault()
    if (this.authenticationRedirect(event.detail.response)) {
      Turbo.visit(event.detail.response.url, { action: "replace" })
    } else {
      this.showError()
    }
  }

  loaded(event) {
    if (!this.owns(event)) return

    this.pending = false
    this.element.setAttribute("aria-busy", "false")
  }

  retry() {
    if (!this.active || this.pending) return

    this.loading({ target: this.element })
    // A missing-frame redirect may have changed src. Always retry the original page.
    if (this.element.getAttribute("src") !== this.source) {
      this.element.src = this.source
    } else {
      this.element.reload()
    }
  }

  showError() {
    this.pending = false
    this.element.setAttribute("aria-busy", "false")
    if (this.hasLoadingTarget) this.loadingTarget.hidden = true
    if (this.hasErrorTarget) this.errorTarget.hidden = false
  }

  owns(event) {
    return this.active && event.target === this.element
  }

  authenticationRedirect(response) {
    if (!response?.redirected || !response.ok) return false

    const destination = new URL(response.url, window.location.href)
    return destination.origin === window.location.origin && [this.signInUrlValue, this.setupUrlValue].some((path) => {
      return destination.pathname === new URL(path, window.location.href).pathname
    })
  }
}
