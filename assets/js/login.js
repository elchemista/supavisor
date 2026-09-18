import "./login_cap_config"
import "../../deps/phoenix_cap/assets/cap.min.js"

document.querySelectorAll("[data-cap-form]").forEach(form => {
  const widget = form.querySelector("cap-widget")
  const status = form.querySelector(".captcha-status")
  const button = form.querySelector('button[type="submit"]')
  const message = text => { status.textContent = text }

  widget.addEventListener("solve", () => message(""))
  widget.addEventListener("reset", () => message("Please verify again to continue."))
  widget.addEventListener("error", () => message("Verification failed. Try the checkbox again."))

  form.addEventListener("submit", event => {
    if (!widget.token) {
      event.preventDefault()
      message("Complete the anti-bot verification to continue.")
      return
    }
    button.disabled = true
    button.setAttribute("aria-busy", "true")
  })
})

// Back/forward navigation must not reuse an already consumed verification token.
window.addEventListener("pageshow", event => {
  if (!event.persisted) return
  document.querySelectorAll("[data-cap-form]").forEach(form => {
    form.querySelector("cap-widget").reset()
    const button = form.querySelector('button[type="submit"]')
    button.disabled = false
    button.removeAttribute("aria-busy")
  })
})
