# lele-claude-bridge

The official Claude Code bridge for [lele](https://github.com/xilistudios/lele).

It drives [`@anthropic-ai/claude-agent-sdk`](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk)
with your **Claude subscription** — no API key, no per-token billing. lele spawns
`bridge.mjs` as a persistent child process and speaks JSON lines with it over
stdio.

```
lele agent loop (Go)
  └─ persistent child: node bridge.mjs   (JSON lines over stdio)
       └─ @anthropic-ai/claude-agent-sdk query()
            └─ claude CLI (subscription auth)
```

The bridge is an **external repo**, installed by `install.sh`; lele never writes
or downloads JavaScript itself. It resolves the install directory at bridge
start and reports a plain, actionable error when the bridge is missing.

## Requirements

- **node ≥ 18.14** (the SDK's own `engines` floor).
- **npm** for the SDK install (skip with `--skip-sdk` if you already have the SDK
  and set `CLAUDE_AGENT_SDK_PATH`).
- **A logged-in `claude` CLI** — run `claude` once and log in with your Claude
  subscription.
- **lele** itself (the `claude-code` provider lands with
  [PR #436](https://github.com/xilistudios/lele/pull/436)).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/xilistudios/lele-claude-bridge/main/install.sh | sh
```

The installer:

1. resolves the install directory (`${LELE_CONFIG_DIR:-$HOME/.lele}/claude-bridge`);
2. checks node ≥ 18.14, npm and tar;
3. downloads the repo tarball from codeload (git clone as fallback);
4. stages the files and `node_modules` **beside** the target directory, then
   swaps it in with two atomic renames (a failed run leaves the previous install
   untouched);
5. runs `npm ci --omit=dev` for the pinned SDK;
6. writes `.install-info.json` and smoke-tests the handshake: the installed
   bridge must answer `{"type":"ready",...}` before the installer calls it done.

Flags (everything after `sh -s --` when piping):

| Flag | Default | Meaning |
|------|---------|---------|
| `--dir DIR` | `${LELE_CONFIG_DIR:-$HOME/.lele}/claude-bridge` | Install directory (created if absent). |
| `--ref REF` | `main` | Branch, tag or commit to install. |
| `--skip-sdk` | off | Copy the bridge files only: no npm, no handshake smoke. |
| `--help` | — | Usage text. |

`LELE_CONFIG_DIR` is honored exactly as lele honors it, including a leading
`~/`. Prefer **absolute** paths: lele resolves a relative `LELE_CONFIG_DIR`
against its own working directory, the installer against its own.

Pin a release:

```sh
curl -fsSL https://raw.githubusercontent.com/xilistudios/lele-claude-bridge/main/install.sh | sh -s -- --ref v0.1.0
```

**Updating** is the same command: the staged tree replaces the old directory
wholesale, `node_modules` included.

## Manual install

No installer, no problem:

```sh
git clone https://github.com/xilistudios/lele-claude-bridge.git
cd lele-claude-bridge
npm ci --omit=dev --no-audit --no-fund
```

Then either point lele at that directory with
`export LELE_CLAUDE_BRIDGE_PATH=$PWD`, or copy it to
`<lele-dir>/claude-bridge` (default `~/.lele/claude-bridge`). The two modules
`bridge.mjs` and `bridge_lib.mjs` must sit side by side: `bridge.mjs` imports
`./bridge_lib.mjs` relatively.

## Configure lele

```yaml
agents:
  defaults:
    provider: claude-code
    model: claude-sonnet-4-5
```

Environment knobs:

| Variable | Read by | Meaning |
|----------|---------|---------|
| `LELE_CLAUDE_BRIDGE_PATH` | lele | Directory containing `bridge.mjs` + `bridge_lib.mjs`, **or** a direct path to `bridge.mjs`. Default `<lele-dir>/claude-bridge`. |
| `LELE_CONFIG_DIR` | lele + installer | Relocates all lele state, hence the default bridge dir. |
| `LELE_NODE_BIN` | lele | node binary lele spawns for the bridge (default `node` from lele's PATH). |
| `CLAUDE_AGENT_SDK_PATH` | bridge | `node_modules` directory to resolve the SDK from, ahead of every other candidate. Use it with a global SDK install. |
| `CLAUDE_CODE_PATH` | lele | `claude` CLI binary, when it is not on PATH. |

Note: the **installer** uses `node`/`npm` from *your* PATH, while **lele** spawns
`LELE_NODE_BIN`. If those are different node versions, make sure the one lele
spawns is ≥ 18.14 too — the SDK's `engines` floor is enforced by npm at install
time only.

## Login

Run the CLI once and log in with your Claude subscription:

```sh
claude
```

No API key is involved. lele strips the API-key and cloud-provider variables
from the bridge's environment so a stale key cannot redirect (or bill) the
wrong account: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`,
`ANTHROPIC_CUSTOM_HEADERS`, `ANTHROPIC_MODEL`,
`ANTHROPIC_DEFAULT_{SONNET,OPUS,HAIKU}_MODEL`, `CLAUDE_CODE_USE_BEDROCK`,
`CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_SKIP_BEDROCK_AUTH`,
`CLAUDE_CODE_SKIP_VERTEX_AUTH`.

## Protocol

One JSON object per line. stdout carries protocol only; every diagnostic goes to
stderr. stdin EOF is a clean shutdown.

```
init   {sdk_search_paths, claude_path}
         -> ready {sdk_version, claude_path}  |  fatal {message}
chat   {id, system, messages, tools, model, stream}
         -> chunk {id, text} | reasoning {id, text} | result {id, ...}
            | error {id, message, class} | log {level, message}
cancel {id}
```

The SDK is resolved lazily on `init`, so a missing SDK (or a missing CLI) is a
`fatal` with an actionable message, not a crash. The SDK is used for a **single
model step**: built-in Claude Code tools are disabled, lele's tools are exposed
through an in-process MCP server, and tool calls are captured and interrupted so
lele executes them itself.

> **The wire is co-owned with lele.** The Go side lives in
> `pkg/providers/claude_code_provider.go`; the fake-bridge tests there pin Go's
> half of the contract and `bridge_test.mjs` here pins this half. Any change to a
> request or event shape must land in **both repositories**, in the same change.

## Development and testing

```sh
node --test bridge_test.mjs     # 45 tests, no SDK, no login, no network
npm test                        # same thing
```

CI runs that suite on node 18.14, 20 and 22 (no SDK installed — that is the
point: nothing here imports the SDK at load time), plus an install smoke test
that runs `install.sh` into a throwaway directory and re-runs the suite with the
SDK present.

**Bumping the SDK pin** (it is pinned to an exact version on purpose: the bridge
touches SDK internals such as the low-level MCP `Server` and
`instance.connect()`):

1. edit `dependencies["@anthropic-ai/claude-agent-sdk"]` in `package.json`;
2. `npm install --no-audit --no-fund` to regenerate `package-lock.json`;
3. `node --test bridge_test.mjs`;
4. run lele's integration suite against the new version
   (`go test -tags=integration ./pkg/providers/ -run ClaudeCodeIntegration`);
5. commit `package.json` **and** `package-lock.json` together.

## Diagnostics

- `<install-dir>/.install-info.json` — `repo`, `ref`, `installed_at`, and the
  `sdk` version (`skipped` when installed with `--skip-sdk`).
- Manual handshake:

  ```sh
  printf '%s\n' '{"type":"init","sdk_search_paths":[],"claude_path":""}' | node ~/.lele/claude-bridge/bridge.mjs
  ```

  The first line is either `{"type":"ready","sdk_version":"...","claude_path":""}`
  or `{"type":"fatal","message":"..."}`.
- `fatal` messages name the remedy: re-run the installer one-liner, or set
  `CLAUDE_AGENT_SDK_PATH` to a `node_modules` that contains the SDK. Auth
  failures tell you to run `claude` and log in.

## License

MIT — see [LICENSE](LICENSE).