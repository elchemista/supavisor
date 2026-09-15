export const Workspace = {
  mounted() {
    this.sidebar = this.el.querySelector(".workspace-sidebar")
    this.main = this.el.querySelector(".workspace-main")
    this.trigger = this.el.querySelector("[data-open-sidebar]")
    this.dialog = this.el.querySelector("#workspace-command")
    this.search = this.dialog.querySelector("input")
    this.media = window.matchMedia("(min-width: 1024px)")
    this.handleEvent("clear-github-secret", () => {
      const field = this.el.querySelector('input[name="github[github_client_secret]"]')
      if (field) field.value = ""
    })
    this.open = false
    this.syncDrawer = () => {
      this.el.classList.toggle("sidebar-is-open", this.open)
      this.trigger.setAttribute("aria-expanded", String(this.open))
      this.main.toggleAttribute("inert", this.open)
      if (this.open) this.main.setAttribute("aria-hidden", "true")
      else this.main.removeAttribute("aria-hidden")
      this.sidebar.toggleAttribute("inert", !this.media.matches && !this.open)
      document.body.classList.toggle("navigation-open", this.open)
    }
    this.closeDrawer = (restoreFocus = false) => {
      this.open = false
      this.syncDrawer()
      if (restoreFocus) this.trigger.focus()
    }
    this.openCommand = () => {
      this.closeDrawer()
      this.search.value = ""
      this.filter()
      if (!this.dialog.open) this.dialog.showModal()
      this.search.focus()
    }
    this.filter = () => {
      const query = this.search.value.trim().toLocaleLowerCase()
      const results = Array.from(this.dialog.querySelectorAll(".command-result"))
      results.forEach(link => link.hidden = !link.dataset.searchLabel.includes(query))
      this.dialog.querySelector(".command-no-results").hidden = results.some(link => !link.hidden)
    }
    this.click = event => {
      const target = event.target
      if (target.closest("[data-open-sidebar]")) {
        this.open = true
        this.syncDrawer()
        this.sidebar.querySelector("[data-close-sidebar]").focus()
      } else if (target.closest("[data-close-sidebar]")) this.closeDrawer(true)
      else if (target.closest("[data-open-command]")) this.openCommand()
      else if (target.closest("[data-close-command]")) this.dialog.close()
      else if (target.closest(".sidebar-link, .workspace-brand, .command-result")) {
        this.closeDrawer()
        this.dialog.close()
      } else if (target === this.dialog) this.dialog.close()
    }
    this.keydown = event => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault()
        this.dialog.open ? this.dialog.close() : this.openCommand()
      }
      if (event.key === "Escape" && this.open) this.closeDrawer(true)
      if (this.dialog.open && event.key === "Enter" && event.target === this.search) {
        event.preventDefault()
        this.dialog.querySelector(".command-result:not([hidden])")?.click()
      }
      if (this.dialog.open && ["ArrowDown", "ArrowUp"].includes(event.key)) {
        event.preventDefault()
        const results = Array.from(this.dialog.querySelectorAll(".command-result:not([hidden])"))
        const index = results.indexOf(document.activeElement)
        const next = event.key === "ArrowDown" ? index + 1 : index - 1
        if (next < 0) this.search.focus()
        else results[Math.min(next, results.length - 1)]?.focus()
      }
      if (event.key === "Tab" && this.open) {
        const focusable = Array.from(this.sidebar.querySelectorAll("a[href], button, input:not([type=hidden])")).filter(el => !el.disabled && el.getClientRects().length)
        const first = focusable[0], last = focusable.at(-1)
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus() }
        if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus() }
      }
    }
    this.resize = () => this.closeDrawer()
    this.el.addEventListener("click", this.click)
    this.search.addEventListener("input", this.filter)
    window.addEventListener("keydown", this.keydown)
    this.media.addEventListener("change", this.resize)
    this.syncDrawer()
  },
  updated() { this.syncDrawer() },
  destroyed() {
    document.body.classList.remove("navigation-open")
    this.main.removeAttribute("inert")
    this.main.removeAttribute("aria-hidden")
    this.el.removeEventListener("click", this.click)
    this.search.removeEventListener("input", this.filter)
    window.removeEventListener("keydown", this.keydown)
    this.media.removeEventListener("change", this.resize)
    this.dialog.close()
  }
}
