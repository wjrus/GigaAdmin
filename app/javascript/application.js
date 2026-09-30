// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

const THEME_STORAGE_KEY = "plex-theme"
const THEME_CHOICES = new Set(["system", "light", "dark", "paper", "terminal", "amber"])

const systemTheme = () => {
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
}

let themeChoice = "system"
try {
  const storedTheme = window.localStorage.getItem(THEME_STORAGE_KEY)
  if (THEME_CHOICES.has(storedTheme)) themeChoice = storedTheme
} catch (_error) {
  // Storage may be blocked; the picker still works for this page session.
}

const applyThemeChoice = (choice) => {
  const safeChoice = THEME_CHOICES.has(choice) ? choice : "system"
  const resolvedTheme = safeChoice === "system" ? systemTheme() : safeChoice

  document.documentElement.classList.add("theme-applying")
  document.documentElement.dataset.theme = resolvedTheme
  document.documentElement.dataset.themeChoice = safeChoice

  document.querySelectorAll("[data-theme-select]").forEach((select) => {
    select.value = safeChoice
  })

  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      document.documentElement.classList.remove("theme-applying")
    })
  })
}

let themePickerInstalled = false

const installThemePicker = () => {
  applyThemeChoice(themeChoice)

  if (themePickerInstalled) return

  document.addEventListener("change", (event) => {
    const select = event.target.closest("[data-theme-select]")
    if (!select) return

    themeChoice = THEME_CHOICES.has(select.value) ? select.value : "system"
    try {
      window.localStorage.setItem(THEME_STORAGE_KEY, themeChoice)
    } catch (_error) {
      // Keep the selection in memory when persistent storage is unavailable.
    }
    applyThemeChoice(themeChoice)
  })

  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    if (themeChoice === "system") applyThemeChoice("system")
  })

  themePickerInstalled = true
}

document.addEventListener("turbo:load", installThemePicker)
document.addEventListener("DOMContentLoaded", installThemePicker)
