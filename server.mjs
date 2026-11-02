#!/usr/bin/env node
// Long-lived completion server so the dropdown never pays Node's startup cost.
//
// Usage: node server.mjs <socket path>
// Request:  one line, fields separated by \x1f: cwd, prefix, word1, word2, ...
// Response: the lines from complete(), then the connection closes.
//           A single "@nospec" line means there is no spec for word1.
// Exits on its own after an hour without requests.

import { existsSync, unlinkSync } from "node:fs";
import { createServer } from "node:net";
import { complete } from "./complete.mjs";

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
  sock.setEncoding("utf8");
  sock.on("error", () => {});
  sock.on("data", async (chunk) => {
    buf += chunk;
    const nl = buf.indexOf("\n");
    if (nl === -1) return;
    const [cwd, prefix, ...words] = buf.slice(0, nl).split("\x1f");
    let lines;
    try {
      lines = await complete({ words, prefix, cwd: existsSync(cwd) ? cwd : process.env.HOME });
    } catch {
      lines = [];
    }
    sock.end((lines ? lines : ["@nospec"]).join("\n") + "\n");
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
