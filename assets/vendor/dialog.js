/**
 * dialog_modal.js — drop-in helpers for <dialog> + Phoenix LiveView + DaisyUI (no "ignore")
 *
 * - JS.dispatch("show-dialog-modal"/"hide-dialog-modal") to open/close
 * - Hook `phx-hook="Dialog"` manages state, classes, and push_event show/hide/toggle
 * - Preserves `open` across LV patches using dom.onBeforeElUpdated (tip #2349)
 * - Adds/removes `.is-open` on <dialog>, toggles `html.modal-open` with a counter (DaisyUI)
 */

let __installed = false;
let __openCount = 0; // number of currently open dialogs (for html.modal-open)

function incHtmlOpen() {
  __openCount++;
  if (__openCount === 1) document.documentElement.classList.add("modal-open");
}

function decHtmlOpen() {
  __openCount = Math.max(0, __openCount - 1);
  if (__openCount === 0)
    document.documentElement.classList.remove("modal-open");
}

function ensureOpen(el) {
  // robust re-open: if already open or stuck, close then open next frame
  if (el.open) {
    try {
      el.close();
    } catch (_) {}
    requestAnimationFrame(() => {
      if (typeof el.showModal === "function") el.showModal();
    });
  } else {
    if (typeof el.showModal === "function") el.showModal();
  }
}

export function setupDialogModalGlobalListeners() {
  if (__installed) return;
  __installed = true;

  window.addEventListener("show-dialog-modal", (event) => {
    const el = event.target;
    if (!(el && el.nodeName === "DIALOG")) return;
    ensureOpen(el);
  });

  window.addEventListener("hide-dialog-modal", (event) => {
    const el = event.target;
    if (el && el.nodeName === "DIALOG") {
      try {
        el.close();
      } catch (_) {}
    }
  });
}

export const dialogModalHooks = {
  Dialog: {
    mounted() {
      // prevent double counting
      this._counted = false;

      // Sync CSS classes & html counter with el.open
      this._updateState = () => {
        const isOpen = !!this.el.open;
        this.el.classList.toggle("is-open", isOpen);
        if (isOpen && !this._counted) {
          incHtmlOpen();
          this._counted = true;
        }
        if (!isOpen && this._counted) {
          decHtmlOpen();
          this._counted = false;
        }
      };

      // Watch the `open` attribute (changed by showModal()/close())
      this._mo = new MutationObserver(this._updateState);
      this._mo.observe(this.el, {
        attributes: true,
        attributeFilter: ["open"],
      });

      // Native events keep everything in sync
      this._onClose = () => requestAnimationFrame(this._updateState);
      this._onCancel = () => requestAnimationFrame(this._updateState);
      this.el.addEventListener("close", this._onClose);
      this.el.addEventListener("cancel", this._onCancel);

      // Server push_event("dialog", %{id, action})
      this.handleEvent("dialog", ({ id, action }) => {
        if (this.el.id !== id) return;
        if (action === "show") ensureOpen(this.el);
        else if (action === "hide") {
          try {
            this.el.close();
          } catch (_) {}
        } else if (action === "toggle")
          this.el.open ? this.el.close() : ensureOpen(this.el);
      });

      // Initial sync
      this._updateState();
    },

    destroyed() {
      if (this._mo) this._mo.disconnect();
      if (this._onClose) this.el.removeEventListener("close", this._onClose);
      if (this._onCancel) this.el.removeEventListener("cancel", this._onCancel);
      if (this._counted) {
        decHtmlOpen();
        this._counted = false;
      }
    },
  },
};

export const dialogModalDom = {
  onBeforeElUpdated: (fromEl, toEl) => {
    if (["DIALOG", "DETAILS"].includes(fromEl.tagName)) {
      if (fromEl.hasAttribute("open")) toEl.setAttribute("open", "");
      else toEl.removeAttribute("open");
    }
  },
};

function composeDom(a, b) {
  const aFn = a.onBeforeElUpdated;
  const bFn = b.onBeforeElUpdated;
  return {
    ...a,
    ...b,
    onBeforeElUpdated(fromEl, toEl) {
      if (typeof aFn === "function") aFn(fromEl, toEl);
      if (typeof bFn === "function") bFn(fromEl, toEl);
    },
  };
}

export function withDialogModal(options = {}) {
  setupDialogModalGlobalListeners();
  const hooks = { ...(options.hooks || {}), ...dialogModalHooks };
  const dom = composeDom(options.dom || {}, dialogModalDom);
  return { ...options, hooks, dom };
}
