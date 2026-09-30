import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    interval: { type: Number, default: 10000 },
    url: String,
    replace: { type: Boolean, default: false },
  }

  connect() {
    this.visibilityChanged = () => this.start()
    document.addEventListener("visibilitychange", this.visibilityChanged)
    this.start()
  }

  disconnect() {
    document.removeEventListener("visibilitychange", this.visibilityChanged)
    this.stop()
  }

  start() {
    this.stop()
    this.active = !document.hidden
    this.schedule()
  }

  stop() {
    this.active = false
    window.clearTimeout(this.timer)
    this.timer = null
    this.request?.abort()
    this.request = null
  }

  schedule() {
    if (!this.active || !this.urlValue || this.timer) return

    this.timer = window.setTimeout(() => {
      this.timer = null
      this.refresh()
    }, Math.max(1000, this.intervalValue))
  }

  async refresh() {
    if (!this.active || !this.urlValue || this.request) return

    window.clearTimeout(this.timer)
    this.timer = null
    const request = new AbortController()
    this.request = request

    try {
      const response = await fetch(this.urlWithCacheBust(), {
        signal: request.signal,
        headers: {
          Accept: "text/html",
          "X-Requested-With": "XMLHttpRequest",
        },
      })
      if (this.request !== request) return
      if (response.redirected) {
        this.stop()
        return
      }
      if (!response.ok) return

      const html = await response.text()
      if (this.active && this.request === request) {
        if (this.replaceValue) {
          // Some responses include the controller element itself. Replacing it
          // lets Stimulus start one fresh poller, or stop when the run finishes.
          this.element.outerHTML = html
          this.stop()
        } else {
          this.element.innerHTML = html
        }
      }
    } catch (_error) {
      // Keep the existing content visible until the next polling attempt.
    } finally {
      if (this.request === request) {
        this.request = null
        this.schedule()
      }
    }
  }

  urlWithCacheBust() {
    const url = new URL(this.urlValue, window.location.href)
    url.searchParams.set("_", Date.now())
    return url.toString()
  }
}
