#!/usr/bin/env node
// Long-lived suggestion server, so the dropdown never pays Node's startup cost
// and never blocks the shell: zsh sends a request and keeps taking keystrokes,
// then draws the reply whenever it arrives.
//
// Usage: node server.mjs <socket path>
// Request:  one line, fields separated by \x1f: id, fresh (0/1), cwd, raw word, word1, word2, ...
// Response: "#<id>" on the first line, then one "kind\tname\tdescription\tinsert" line per
//           suggestion, best first. The connection then closes.
// Exits on its own after an hour without requests.

import { existsSync, unlinkSync } from "node:fs";
import { createServer } from "node:net";
import { suggest } from "./suggest.mjs";

const socketPath = process.argv[2];
const IDLE_EXIT_MS = 60 * 60 * 1000;

if (!socketPath) {
  console.error("usage: server.mjs <socket path>");
  process.exit(1);
}

let idle;
const touch = () => {
  clearTimeout(idle);
  idle = setTimeout(shutdown, IDLE_EXIT_MS);
};

const server = createServer((sock) => {
  touch();
  let buf = "";
  let handled = false;
  sock.setEncoding("utf8");
  sock.on("error", () => {}); // the shell hangs up on requests it no longer needs
  sock.on("data", async (chunk) => {
    if (handled) return;
    buf += chunk;
    const nl = buf.indexOf("\n");
    if (nl === -1) return;
    handled = true;
    const [id, fresh, cwd, raw, ...words] = buf.slice(0, nl).split("\x1f");
    let lines;
    try {
      lines = await suggest({
        words,
        raw,
        fresh: fresh === "1",
        cwd: existsSync(cwd) ? cwd : process.env.HOME,
      });
    } catch {
      lines = [];
    }
    if (!sock.destroyed) sock.end(`#${id}\n` + lines.map((l) => l + "\n").join(""));
  });
});

function shutdown() {
  server.close();
  try {
    unlinkSync(socketPath);
  } catch {}
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
process.umask(0o077);
try {
  unlinkSync(socketPath);
} catch {}
server.listen(socketPath, touch);
