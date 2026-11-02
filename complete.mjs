#!/usr/bin/env node
// Minimal Fig-spec completion engine.
//
// As a module: complete({ words, prefix, cwd }) -> array of lines, or null when
// there is no spec for words[0].
// As a CLI:    node complete.mjs <cmd> [completed tokens...] -- <current prefix>
//
// Each line is "<kind>\t<name>\t<description>" where kind is s (subcommand),
// o (option) or a (argument), plus the marker lines "@files" / "@folders" when
// the shell should offer paths. Options are always included; the caller
// decides when to show them.

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const BUILD = join(
  dirname(fileURLToPath(import.meta.url)),
  "node_modules/@withfig/autocomplete/build",
);
const GENERATOR_TIMEOUT_MS = 2000;

const toArray = (x) => (x == null ? [] : Array.isArray(x) ? x : [x]);
const names = (item) => toArray(item?.name);

export const hasSpec = (name) =>
  !!name && !name.includes("..") && existsSync(join(BUILD, `${name}.js`));

async function loadSpec(name) {
  if (!hasSpec(name)) return null;
  const mod = await import(pathToFileURL(join(BUILD, `${name}.js`)).href);
  let spec = mod.default;
  // Versioned specs export a function; take the latest version they produce.
  if (typeof spec === "function") {
    try {
      spec = await spec();
    } catch {
      return null;
    }
  }
  return spec && typeof spec === "object" ? spec : null;
}

// ---------- shell helpers for generators ----------

function makeShell(cwd) {
  const run = (command, args, { shell = false } = {}) =>
    new Promise((resolve) => {
      let stdout = "";
      let stderr = "";
      let child;
      try {
        child = spawn(command, args, { cwd, shell, stdio: ["ignore", "pipe", "pipe"] });
      } catch {
        return resolve({ stdout: "", stderr: "", status: 1 });
      }
      const timer = setTimeout(() => child.kill("SIGKILL"), GENERATOR_TIMEOUT_MS);
      child.stdout.on("data", (d) => (stdout += d));
      child.stderr.on("data", (d) => (stderr += d));
      child.on("error", () => {});
      child.on("close", (status) => {
        clearTimeout(timer);
        resolve({ stdout: stdout.replace(/\n$/, ""), stderr, status: status ?? 1 });
      });
    });

  // Fig has had two shapes of this helper: old specs pass a string and expect
  // stdout back, newer ones pass {command, args} and expect {stdout, status}.
  const executeShellCommand = async (cmd) =>
    typeof cmd === "string"
      ? (await run(cmd, [], { shell: true })).stdout
      : run(cmd.command, cmd.args ?? []);

  const runScript = async (script, tokens) => {
    if (typeof script === "function") script = script(tokens);
    if (!script) return "";
    if (typeof script === "string") return (await run(script, [], { shell: true })).stdout;
    if (Array.isArray(script)) return (await run(script[0], script.slice(1))).stdout;
    if (script.command) return (await run(script.command, script.args ?? [])).stdout;
    return "";
  };

  const context = {
    currentWorkingDirectory: cwd,
    environmentVariables: process.env,
    currentProcess: "zsh",
    sshPrefix: "",
    isDangerous: false,
    searchTerm: "",
  };

  return { executeShellCommand, runScript, context };
}

async function runGenerator(gen, tokens, sh) {
  const out = { suggestions: [], templates: [] };
  try {
    if (gen.template) out.templates.push(...toArray(gen.template));
    if (gen.custom) {
      out.suggestions.push(...toArray(await gen.custom(tokens, sh.executeShellCommand, sh.context)));
    } else if (gen.script) {
      const stdout = await sh.runScript(gen.script, tokens);
      if (gen.postProcess) out.suggestions.push(...toArray(gen.postProcess(stdout, tokens)));
      else if (gen.splitOn)
        out.suggestions.push(...stdout.split(gen.splitOn).filter(Boolean).map((name) => ({ name })));
    }
  } catch {
    // A broken generator should never break the whole completion.
  }
  return out;
}

// ---------- spec walking ----------

const findOption = (options, token) => options.find((o) => names(o).includes(token)) ?? null;
const findSubcommand = (node, token) =>
  toArray(node.subcommands).find((s) => names(s).includes(token)) ?? null;

async function enterSubcommand(sub) {
  if (typeof sub.loadSpec === "string") {
    const loaded = await loadSpec(sub.loadSpec);
    if (loaded) return { ...sub, ...loaded, name: sub.name };
  }
  return sub;
}

// Options that need a value: those whose args are not all optional.
const optionArgs = (opt) => toArray(opt?.args);
const needsValue = (opt) => optionArgs(opt).some((a) => !a.isOptional);

async function walk(spec, tokens) {
  let node = spec;
  let persistent = toArray(spec.options).filter((o) => o.isPersistent);
  let argIndex = 0;
  let pendingOptionArg = null; // arg spec the next token fills
  let afterDoubleDash = false;
  const used = new Set();

  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];

    if (pendingOptionArg) {
      pendingOptionArg = null;
      continue;
    }
    if (t === "--" && !afterDoubleDash) {
      afterDoubleDash = true;
      continue;
    }

    if (!afterDoubleDash && t.startsWith("-") && t.length > 1) {
      const eq = t.indexOf("=");
      const opt = findOption([...toArray(node.options), ...persistent], eq === -1 ? t : t.slice(0, eq));
      if (opt) {
        names(opt).forEach((n) => used.add(n));
        if (eq === -1 && needsValue(opt)) pendingOptionArg = optionArgs(opt)[0];
      }
      continue;
    }

    const sub = argIndex === 0 ? findSubcommand(node, t) : null;
    if (sub) {
      node = await enterSubcommand(sub);
      persistent = [...persistent, ...toArray(node.options).filter((o) => o.isPersistent)];
      argIndex = 0;
      used.clear();
      continue;
    }

    const args = toArray(node.args);
    const arg = args[Math.min(argIndex, args.length - 1)];
    // `sudo git ...`, `time npm ...`: hand the rest of the line to that command's spec.
    if (arg?.isCommand) {
      const inner = await loadSpec(t);
      return inner ? walk(inner, tokens.slice(i + 1)) : { done: true };
    }
    if (!arg?.isVariadic) argIndex++;
  }

  return { node, spec, persistent, argIndex, pendingOptionArg, used };
}

async function collectArg(arg, tokens, out, sh) {
  if (!arg) return;
  const push = (s) => out.push(typeof s === "string" ? { name: s, kind: "a" } : { ...s, kind: "a" });
  toArray(arg.suggestions).forEach(push);
  const templates = [...toArray(arg.template)];
  const results = await Promise.all(toArray(arg.generators).map((g) => runGenerator(g, tokens, sh)));
  for (const r of results) {
    r.suggestions.forEach(push);
    templates.push(...r.templates);
  }
  if (templates.includes("filepaths")) out.files = "files";
  else if (templates.includes("folders")) out.files ??= "folders";
}

export async function complete({ words, prefix = "", cwd = process.cwd() }) {
  const [cmd, ...tokens] = words;
  const spec = await loadSpec(cmd);
  if (!spec) return null;

  const sh = makeShell(cwd);
  const state = await walk(spec, tokens);
  const allTokens = [cmd, ...tokens, prefix];
  const out = [];

  if (!state.done) {
    const { node, persistent, argIndex, pendingOptionArg, used } = state;
    if (pendingOptionArg) {
      await collectArg(pendingOptionArg, allTokens, out, sh);
    } else {
      if (argIndex === 0)
        for (const sub of toArray(node.subcommands))
          if (!sub.hidden)
            for (const n of names(sub)) out.push({ name: n, description: sub.description, kind: "s" });
      const args = toArray(node.args);
      await collectArg(args[Math.min(argIndex, args.length - 1)], allTokens, out, sh);
      if (argIndex === 0 && node === state.spec)
        for (const s of toArray(state.spec.additionalSuggestions))
          if (typeof s === "object" && s.name && !s.insertValue) out.push({ ...s, kind: "a" });
      for (const opt of [...toArray(node.options), ...persistent]) {
        if (opt.hidden) continue;
        if (!opt.isRepeatable && names(opt).some((n) => used.has(n))) continue;
        for (const n of names(opt)) out.push({ name: n, description: opt.description, kind: "o" });
      }
    }
  }

  const clean = (s) => String(s ?? "").replace(/[\t\n\r]+/g, " ").trim();
  const seen = new Set();
  const lines = [];
  for (const s of out) {
    if (s.hidden) continue;
    for (const n of names(s)) {
      const key = `${s.kind}\t${n}`;
      if (!n || seen.has(key)) continue;
      seen.add(key);
      lines.push(`${s.kind}\t${clean(n)}\t${clean(s.description)}`);
    }
  }
  if (out.files) lines.push(`@${out.files}`);
  return lines;
}

// ---------- CLI ----------

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const argv = process.argv.slice(2);
  const sep = argv.lastIndexOf("--");
  const words = sep === -1 ? argv : argv.slice(0, sep);
  const prefix = sep === -1 ? "" : argv[sep + 1] ?? "";
  complete({ words, prefix }).then(
    (lines) => {
      if (!lines) process.exit(2);
      // Keep the old Tab behaviour: options only once the user typed "-".
      const shown = lines.filter((l) => (prefix.startsWith("-") ? l[0] === "o" || l[0] === "@" : l[0] !== "o"));
      process.stdout.write(shown.join("\n") + (shown.length ? "\n" : ""));
      process.exit(0);
    },
    () => process.exit(1),
  );
}
