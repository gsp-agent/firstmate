// Minimal OpenAI-compatible chat-completions stand-in for a lab Pi run.
// Logs each request body as one JSON line and streams back "OK".
import { createServer } from "node:http";
import { appendFileSync, writeFileSync } from "node:fs";
const [portFile, logFile] = process.argv.slice(2);
const server = createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    appendFileSync(logFile, `${body.replace(/\n/g, " ")}\n`);
    if (!req.url.endsWith("/chat/completions")) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
    const chunk = (obj) => res.write(`data: ${JSON.stringify(obj)}\n\n`);
    const base = { id: "lab-1", object: "chat.completion.chunk", created: 1, model: "lab-model" };
    chunk({ ...base, choices: [{ index: 0, delta: { role: "assistant", content: "OK" }, finish_reason: null }] });
    chunk({ ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } });
    res.write("data: [DONE]\n\n");
    res.end();
  });
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
