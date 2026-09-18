export const ServiceAPI = {
  mounted() {
    this.handleEvent("clear-api-token", () => {
      const field = this.el.querySelector('input[name="key[token]"]')
      if (field) field.value = ""
    })
    this.copy = async event => {
      const button = event.target.closest("[data-copy-target]")
      if (!button) return
      const field = this.el.querySelector(button.dataset.copyTarget)
      const feedback = this.el.querySelector("[data-copy-feedback]")
      if (!field) return
      try {
        await navigator.clipboard.writeText(field.value || field.textContent.trim())
        if (feedback) feedback.textContent = "Copied to clipboard."
      } catch {
        field.focus()
        if (field.select) field.select()
        if (feedback) feedback.textContent = "Select and copy the value manually."
      }
    }
    this.el.addEventListener("click", this.copy)
  },
  destroyed() { this.el.removeEventListener("click", this.copy) }
}
