const host = document.querySelector("#terminal");
const terminal = new Terminal({
  cursorBlink: true, fontFamily: "Menlo, monospace", fontSize: 12, scrollback: 3000,
  theme: { background: "#15171b", foreground: "#eeeeee" }
});
const send = (type, value) => window.webkit.messageHandlers.consoleBridge.postMessage({type, value});
terminal.open(host);
terminal.onData(data => send("input", data));
terminal.onResize(({cols, rows}) => send("size", [cols, rows]));
const measure = document.createElement("span");
measure.textContent = "W";
measure.style.cssText = "position:absolute;visibility:hidden;font:12px Menlo,monospace";
document.body.append(measure);
function fit() {
  const cell = measure.getBoundingClientRect();
  if (host.clientWidth < 32 || host.clientHeight < 32) return;
  terminal.resize(Math.max(2, Math.floor((host.clientWidth - 15) / cell.width)),
                  Math.max(2, Math.floor(host.clientHeight / Math.ceil(cell.height))));
}
new ResizeObserver(fit).observe(host);
window.writeChunk = encoded => new Promise(resolve =>
  terminal.write(Uint8Array.from(atob(encoded), c => c.charCodeAt(0)), () => resolve(true)));
window.focusConsole = () => terminal.focus();
fit();
send("ready", [terminal.cols, terminal.rows]);
