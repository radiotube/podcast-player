// Makes transcripts on the device: Whisper speech recognition running in the browser (transformers.js).
// The app sends 16 kHz mono audio in windows of up to 30 seconds and gets back timed lines of text.
// The model is downloaded once from Hugging Face and kept in the browser's cache.
import { pipeline, env } from "https://cdn.jsdelivr.net/npm/@huggingface/transformers@4.3.1/dist/transformers.min.js";

env.allowLocalModels = false;
try { env.backends.onnx.wasm.numThreads = 1; } catch (e) {}

const MODEL = "onnx-community/whisper-tiny.en";
let asr = null;
const files = {};

function load() {
  if (!asr) {
    asr = pipeline("automatic-speech-recognition", MODEL, {
      dtype: "q8",
      device: "wasm",
      progress_callback: (p) => {
        if (p.status === "progress" && p.file) {
          files[p.file] = { loaded: p.loaded || 0, total: p.total || 0 };
          let loaded = 0, total = 0;
          for (const k in files) { loaded += files[k].loaded; total += files[k].total; }
          postMessage({ type: "load", loaded, total });
        }
      }
    });
    asr.catch(() => { asr = null; });
  }
  return asr;
}

onmessage = async (ev) => {
  const m = ev.data || {};
  try {
    if (m.type === "load") {
      await load();
      postMessage({ type: "ready" });
    } else if (m.type === "run") {
      const run = await load();
      const t0 = performance.now();
      const out = await run(m.audio, { return_timestamps: true });
      const lines = (out.chunks || []).map((c) => ({
        s: c.timestamp && c.timestamp[0] != null ? c.timestamp[0] : null,
        e: c.timestamp && c.timestamp[1] != null ? c.timestamp[1] : null,
        b: String(c.text || "").trim()
      }));
      postMessage({ type: "done", id: m.id, lines, text: out.text || "", ms: performance.now() - t0 });
    }
  } catch (e) {
    postMessage({ type: "error", id: m.id, msg: String((e && e.message) || e) });
  }
};
