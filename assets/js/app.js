import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import {withDialogModal} from "../vendor/dialog"
import {Workspace} from "./workspace"
import {ServiceAPI} from "./service_api"

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, withDialogModal({params: {_csrf_token: csrfToken}, hooks: {Workspace, ServiceAPI}}))

topbar.config({barColors: {0: "#68deb3"}, shadowColor: "rgba(15, 23, 42, .18)"})
window.addEventListener("phx:page-loading-start", () => topbar.show(300))
window.addEventListener("phx:page-loading-stop", () => topbar.hide())
window.addEventListener("phx:embedding:inspect", () => {
  if (window.matchMedia("(max-width: 1199px)").matches) {
    document.getElementById("embedding-inspector")?.scrollIntoView({
      block: "start",
      behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth"
    })
  }
})

liveSocket.connect()
window.liveSocket = liveSocket
