import wasmUrl from "../../deps/phoenix_cap/assets/wasm/cap_wasm_bg.wasm"

// Configure the widget before its module runs, including its eager WASM load.
window.CAP_CUSTOM_WASM_URL = new URL(wasmUrl, window.location.origin).href
window.CAP_PAKO_URL = "/assets/cap-inflate.js"
window.CAP_CUSTOM_FETCH = (input, options = {}) => {
  const url = new URL(input, window.location.href)
  const headers = new Headers(options.headers)
  if (url.origin === window.location.origin && url.pathname.startsWith("/admin/cap/")) {
    headers.set("x-csrf-token", document.querySelector('meta[name="csrf-token"]').content)
    headers.set("accept", "application/json")
  }
  return fetch(input, {...options, headers, credentials: "same-origin"})
}
