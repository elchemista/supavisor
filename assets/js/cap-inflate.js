// Self-hosted fallback for browsers without native deflate decompression.
import * as pako from "../vendor/pako_inflate.min.js"
window.pako = pako
