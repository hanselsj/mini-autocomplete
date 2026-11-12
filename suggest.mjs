// Turns the command line into the ranked list the dropdown shows.
//
// suggest({ words, raw, cwd, fresh }) -> array of "kind\tname\tdescription\tinsert"
//   words  the words before the one being typed (unquoted), words[0] = command
//   raw    the word being typed, exactly as typed (may contain quotes / ~)
//   fresh  true on the first request for a new word: re-run the spec's generators
//          (git branches, npm scripts...) instead of reusing the cached ones
//
// kind is s (subcommand), o (option), a (argument value), d (folder) or f (file).

import { readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";
import { complete } from "./complete.mjs";

const MAX_RESULTS = 500;
const MAX_DIR_ENTRIES = 2000;
const CACHE_TTL_MS = 30_000;

// ---------- spec results, cached per command line ----------

const cache = new Map(); // key -> { at, promise }

function specItems(words, cwd, fresh) {
  const key = `${cwd}\0${words.join("\0")}`;
  const hit = cache.get(key);
  if (hit && !fresh && Date.now() - hit.at < CACHE_TTL_MS) return hit.promise;
  const promise = complete({ words, cwd }).then(parseSpecLines, () => parseSpecLines([]));
  cache.set(key, { at: Date.now(), promise });
  if (cache.size > 200) cache.delete(cache.keys().next().value);
  return promise;
}

function parseSpecLines(lines) {
  const items = [];
  let files = null;
  if (lines === null) return { items, files: "files" }; // no spec: offer files
  for (const line of lines) {
    if (line === "@files") files = "files";
    else if (line === "@folders") files ??= "folders";
    else {
      const [kind, name, description = ""] = line.split("\t");
      if (kind && name) items.push({ kind, name, description });
    }
  }
  // Generators like cd's only list ./ — when every argument looks like a path,
  // list from disk instead so `cd Repos/<...>` works.
  const args = items.filter((i) => i.kind === "a");
  if (args.length && args.every((i) => i.name.endsWith("/"))) {
    return { items: items.filter((i) => i.kind !== "a"), files: files ?? "folders" };
  }
  return { items, files };
}

// ---------- matching ----------

const WORD_START = /[-_./:@ ]/;

// Lower rank = better. Tiers: 0 starts with the query, 1 query starts a word
// inside the name, 2 contains it, 3 fuzzy (letters in order, tightest first).
export function rank(name, query) {
  if (!query) return 0;
  const n = name.toLowerCase();
  const q = query.toLowerCase();
  if (n.startsWith(q)) return 0;
  let at = n.indexOf(q);
  while (at > 0) {
    if (WORD_START.test(n[at - 1])) return 1000 + at;
    at = n.indexOf(q, at + 1);
  }
  at = n.indexOf(q);
  if (at !== -1) return 2000 + at;
  const span = fuzzySpan(n, q);
  return span === -1 ? -1 : 3000 + span;
}

// Length of the shortest window of n that contains q's letters in order, or -1.
function fuzzySpan(n, q) {
  let best = -1;
  for (let start = n.indexOf(q[0]); start !== -1; start = n.indexOf(q[0], start + 1)) {
    let j = 1;
    let i = start + 1;
    for (; i < n.length && j < q.length; i++) if (n[i] === q[j]) j++;
    if (j < q.length) break; // no later start can match either
    const span = i - start;
    if (best === -1 || span < best) best = span;
  }
  return best;
}

// ---------- shell quoting ----------

// Same idea as zsh's ${(q)name}: backslash-escape anything the shell would read specially.
export function shellQuote(s) {
  if (s === "") return "''";
  return s.replace(/[^A-Za-z0-9_\-.,:/@%+=^]/g, (c) => "\\" + c);
}

// Undo the shell quoting in what the user has typed so far (best effort for a partial word).
function unquote(raw) {
  let out = "";
  let quote = null;
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i];
    if (quote) {
      if (c === quote) quote = null;
      else if (c === "\\" && quote === '"' && i + 1 < raw.length) out += raw[++i];
      else out += c;
    } else if (c === "'" || c === '"') quote = c;
    else if (c === "\\" && i + 1 < raw.length) out += raw[++i];
    else out += c;
  }
  return out;
}

// ---------- files ----------

function listDir(dir, foldersOnly, showHidden) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  const out = [];
  for (const e of entries.slice(0, MAX_DIR_ENTRIES)) {
    if (!showHidden && e.name.startsWith(".")) continue;
    let isDir = e.isDirectory();
    if (e.isSymbolicLink()) {
      try {
        isDir = statSync(join(dir, e.name)).isDirectory();
      } catch {}
    }
    if (foldersOnly && !isDir) continue;
    out.push({ name: e.name, isDir });
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

// ---------- main ----------

export async function suggest({ words, raw = "", cwd = process.cwd(), fresh = false }) {
  const { items, files } = await specItems(words, cwd, fresh);
  const q = unquote(raw);
  const wantOptionsFirst = q.startsWith("-");
  const ranked = [];
  let idx = 0;

  const add = (r, kind, name, description, insert) => {
    ranked.push({ r, idx: idx++, line: `${kind}\t${name}\t${description}\t${insert}` });
  };

  for (const pass of [0, 1]) {
    const wantOptions = wantOptionsFirst || pass === 1;
    for (const it of items) {
      if ((it.kind === "o") !== wantOptions) continue;
      const r = rank(it.name, q);
      if (r < 0) continue;
      // $VARS are inserted as-is, everything else shell-quoted.
      add(r, it.kind, it.name, it.description, it.name.startsWith("$") ? it.name : shellQuote(it.name));
    }

    if (files && !wantOptionsFirst && pass === 0) {
      const slash = q.lastIndexOf("/");
      const dir = slash === -1 ? "" : q.slice(0, slash + 1);
      const base = q.slice(slash + 1);
      const rawDir = slash === -1 ? "" : raw.slice(0, raw.lastIndexOf("/") + 1);
      let path = dir.replace(/^~(?=\/|$)/, homedir()) || ".";
      if (!isAbsolute(path)) path = join(cwd, path);
      for (const e of listDir(path, files === "folders", base.startsWith("."))) {
        const r = rank(e.name, base);
        if (r < 0) continue;
        if (e.isDir) add(r, "d", e.name + "/", "", rawDir + shellQuote(e.name) + "/");
        else add(r, "f", e.name, "", rawDir + shellQuote(e.name));
      }
    }

    // With nothing else to show, fall back to the options.
    if (ranked.length || wantOptionsFirst) break;
  }

  ranked.sort((a, b) => a.r - b.r || a.idx - b.idx);
  return ranked.slice(0, MAX_RESULTS).map((x) => x.line);
}
