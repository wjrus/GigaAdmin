import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "title", "body", "confirmButton"]

  confirmSubmit(event) {
    const form = event.target
    if (form.dataset.confirmWhenEmpty === "true" && this.hasSelectedOptions(form)) return
    if (form.dataset.confirmed === "true") {
      delete form.dataset.confirmed
      return
    }

    event.preventDefault()
    this.pendingForm = form
    this.titleTarget.textContent = form.dataset.confirmTitle || "Confirm action"
    this.bodyTarget.textContent = this.confirmBody(form)
    this.confirmButtonTarget.textContent = form.dataset.confirmButton || "Confirm"
    this.dialogTarget.showModal()
  }

  cancel() {
    this.pendingForm = null
    this.dialogTarget.close()
  }

  submit() {
    if (!this.pendingForm) return

    const form = this.pendingForm
    this.pendingForm = null
    form.dataset.confirmed = "true"
    this.dialogTarget.close()
    try {
      form.requestSubmit()
    } finally {
      delete form.dataset.confirmed
    }
  }

  hasSelectedOptions(form) {
    const selectedOptions = Array.from(form.querySelectorAll("select[multiple] option")).some((option) => option.selected)
    const checkedBoxes = Array.from(form.elements).some((element) => element.matches?.("input[type='checkbox'][name='library_ids[]']") && element.checked)

    return selectedOptions || checkedBoxes
  }

  confirmBody(form) {
    if (form.dataset.confirmLibrarySummary === "true") {
      return this.libraryChangeSummary(form)
    }
    if (form.dataset.confirmBulkSummary === "true") {
      return this.bulkChangeSummary(form)
    }

    return form.dataset.confirmBody || "This action cannot be undone."
  }

  libraryChangeSummary(form) {
    const checkboxes = Array.from(form.elements).filter((element) => element.matches?.("input[type='checkbox'][name='library_ids[]']"))
    const added = checkboxes.filter((checkbox) => !checkbox.defaultChecked && checkbox.checked).map((checkbox) => checkbox.dataset.libraryTitle)
    const removed = checkboxes.filter((checkbox) => checkbox.defaultChecked && !checkbox.checked).map((checkbox) => checkbox.dataset.libraryTitle)

    if (checkboxes.every((checkbox) => !checkbox.checked)) {
      return "This will remove all library access for this user."
    }

    const changes = []
    if (added.length) changes.push(`Add: ${added.join(", ")}`)
    if (removed.length) changes.push(`Remove: ${removed.join(", ")}`)

    return changes.length ? changes.join(". ") : "No library changes are selected."
  }

  bulkChangeSummary(form) {
    const selectedUsers = Array.from(form.elements).filter((element) => element.matches?.("input[type='checkbox'][name='user_ids[]']") && element.checked)
    const operation = form.elements.operation?.selectedOptions?.[0]?.textContent || "Update"
    const library = form.elements.library_id?.selectedOptions?.[0]?.textContent || "the selected library"

    return `${operation} ${library} for ${selectedUsers.length} selected user${selectedUsers.length === 1 ? "" : "s"}.`
  }
}
