# ask-local

[![Gem Version](https://badge.fury.io/rb/ask-local.svg)](https://badge.fury.io/rb/ask-local)

Stable named `.localhost` URLs for Ruby development. Gives every Ruby app
a stable `https://<app>.localhost` URL instead of a memorized port.
Zero runtime dependencies — Ruby stdlib only (`openssl`, `socket`).

```bash
gem install ask-local
# Interactive shortcut: `askl` is the same binary (shell-friendly alias).
# Keep `ask-local` in logs and docs so `grep` stays useful.
ask-local start          # setup + boot in one go (or plain `ask-local`)
ask-local setup          # once per machine: CA trust + port 443 + hosts + verify
cd ~/code/myapp && ask-local
# -> https://myapp.localhost
```

## The no-fallback promise

ask-local never silently degrades to a `:<port>` URL. Clean
`https://<app>.localhost` requires the proxy on port 443; if 443
cannot be bound, you get a hard error pointing at `ask-local setup`
— never a booted app on `https://app.localhost:1355` that silently
poisons OAuth callbacks, mailer hosts, and webhooks downstream.

The only port-suffixed URLs are the ones you explicitly ask for:
`ask-local proxy start -p 1355` (CI/sandboxes where 443 is impossible).
There the suffix is honest, and `ASK_LOCAL_URL` carries it faithfully.

## Port 443: one-time setup, then never again

Binding 443 is privileged, so ask-local installs a **root-owned launchd
service** (macOS) or systemd unit (Linux) that binds 443 at boot — the
same model as puma-dev and portless. Installing it needs sudo **once per
machine**; after that, every `ask-local` run in any project gets a clean
`https://<app>.localhost` with no elevation and no prompt.

**Human (interactive):** run setup once — it trusts the CA, installs the
service, syncs hosts, and verifies:

```bash
ask-local setup
```

**Agent / CI (no TTY):** the same commands fail fast with guidance,
because sudo needs a terminal. To pre-provision a machine or image so
agents can install the service without a prompt, install the scoped
passwordless-sudo rules once (as an admin):

```bash
ask-local sudoers > /tmp/ask-local.sudoers
sudo install -o root -g wheel -m 440 /tmp/ask-local.sudoers /etc/sudoers.d/ask-local   # macOS
sudo install -o root -g root -m 440 /tmp/ask-local.sudoers /etc/sudoers.d/ask-local   # Linux
```

`ask-local sudoers` prints rules scoped to ask-local's own service
re-exec — the gem's exact ruby + bin path with the `service install
--internal` / `service uninstall --internal` subcommands — never a bare
interpreter. Re-run it after upgrading the gem if the install path
changes. To undo: `sudo rm /etc/sudoers.d/ask-local`.

## The one-file model

Every app declares `config/local.yml` (Kamal-style) — the single source
of truth for service name, proxy TLD/host, processes, and env:

```yaml
service: myapp
proxy:
  tld: localhost
processes:
  web:
    cmd: bundle exec puma -b tcp://127.0.0.1:$PORT config.ru
    proxy: true
  worker:
    cmd: bundle exec sidekiq
    proxy: false
```

`ask-local init` creates the file (migrating an existing Procfile);
Rails apps need no extra gem — ask-local injects `RAILS_DEVELOPMENT_HOSTS`
so the proxied hostname is allowed automatically. `ask-local`
then boots every process, assigns each a `$PORT`, injects
`ASK_LOCAL_URL`, registers routes for HTTP processes, supervises the
whole tree, and cleans up when one exits.

Variants are file overlays: `config/local.<variant>.yml` deep-merges on
top of `config/local.yml`, selected by `ASK_LOCAL_VARIANT` (Kamal's
destination pattern).

`.localhost` resolves to loopback natively in Chrome, Firefox, and Edge —
no DNS server, no `/etc/resolver`. Safari may need `ask-local hosts sync`.

## Hostname shape

```
{variant}.{service}.{app}.{tld}
```

| Axis | Example | Source |
|---|---|---|
| app | `myapp` | inferred, `--name`, `ask-local.json`, `ASK_LOCAL_NAME` |
| service | `api.myapp` | `--service`, `ASK_LOCAL_SERVICE` (`web` stays bare) |
| variant | `fix-ui.myapp` | `--variant`, `ASK_LOCAL_VARIANT`, linked worktree branch |
| tld | `myapp.preview.example.com` | `--tld` (default `localhost`) |

Linked git worktrees get a branch prefix automatically
(`fix-ui.myapp.localhost`); the main checkout keeps the bare name.
Pass `--branch` (or `ASK_LOCAL_BRANCH=1`) to prefix by current branch
outside worktrees. `main`/`master`/detached HEAD never prefix.

```bash
ask-local                                          # -> https://myapp.localhost
ask-local --service api                            # -> https://api.myapp.localhost
ask-local --variant demo                           # -> https://demo.myapp.localhost
ask-local --tld preview.example.com                # your own domain (OAuth parity)
```

## Commands

```bash
ask-local                        # infer name, boot app
ask-local run -- <cmd>           # run explicit command through proxy
ask-local <name> <cmd>           # explicit app name
ask-local get <name>             # print URL for cross-service wiring
ask-local alias <name> <port>    # static route (e.g. Docker)
ask-local list [--json]          # show active routes (+ backend liveness)
ask-local status [--json]        # show effective naming context here
ask-local doctor [--json]        # machine-readable health checks
ask-local open [name]            # open the app URL in a browser
ask-local doctor                 # read-only health check (state, proxy, routes, DNS, CA)
ask-local trust                  # add local CA to system trust store
ask-local clean                  # remove state and hosts entries
ask-local prune                  # remove stale routes
ask-local stop                   # stop this app's backend + routes
ask-local restart                # touch tmp/restart.txt (managed apps reboot)
ask-local log [-f] [n]           # tail (or follow) this app's backend log
ask-local proxy start|stop       # control the proxy
ask-local service install|status|uninstall   # root-owned OS startup service
ask-local hosts sync|clean       # manage /etc/hosts entries
ask-local kamal <variant>        # preview-deploy snippet for Kamal
```

Child processes receive `ASK_LOCAL_URL` (the stable URL — use it for
OAuth callbacks, mailer hosts, webhook URLs), `PORT`, and `HOST`.

## Frameworks

Rails and bare Rack (`config.ru`) boot managed on a unix socket (Puma
when available; `rackup` on TCP otherwise). `Procfile.dev`/`bin/dev`,
Jekyll, Bridgetown, and Middleman run in run mode with `PORT` injected
(port-ignoring CLIs get explicit `--port/--host` flags). Anything else:
`ask-local run -- <cmd>`.

```bash
ask-local --proc web             # boot a specific Procfile process
ask-local --proc worker          # (first line is the default)
```

Procfile lines that are compound (`&&`, `||`, `|`, `;`) are refused with
guidance rather than silently mis-injected.

For Rails integration (hosts, Action Cable origins, Procfile rewrite,
generators) — deprecated; core covers Rails now.

## WebSockets

Action Cable and any Rack hijack-based WebSocket server work through the
proxy: HTTP/1.1 `Upgrade` requests are byte-forwarded to the backend
after header rewriting, and the tunnel stays raw for the life of the
connection (verified end-to-end: RFC 6455 handshake + frame echo).

## Machine-readable output

`list`, `status`, and `doctor` accept `--json` with stable keys for
agents and scripts (`DevUrl` in ask-ruby-harness consumes the same data
in-process). Hostnames that fall outside the configured TLDs get a bare
404 naming nothing — route names never leak to foreign hosts
(DNS-rebinding boundary).

## Log rotation

`proxy.log` and per-app backend logs rotate at 5MB
(`ASK_LOCAL_LOG_MAX_BYTES`), keeping one generation. `doctor` warns
when the state dir passes 100MB.

## Supervision

Managed apps are supervised by the proxy daemon, not the CLI:

- idle backends stop after 15 minutes (`ASK_LOCAL_IDLE_TIMEOUT`
  seconds; `0` disables) and boot transparently on the next request
- touching `tmp/restart.txt` stops the backend; next request reboots it
- crashed backends are detected and rebooted on the next request
- daemon shutdown stops every supervised backend (no orphans)

Run-mode (TCP) routes and static aliases are never supervised.

## Ask ecosystem integration

| Gem | How ask-local helps |
|---|---|
| `ask-rails` | ask-local core injects `RAILS_DEVELOPMENT_HOSTS`; Cable origins + helpers live in the deprecated ask-local-rails |
| `ask-rails-harness` | Its 9 Rails tools (routes, models, DB, logs) run against the app the proxy serves; `DevUrl` gives the agent the stable URL instead of a guessed port |
| `ask-app-server` | The JSON-RPC/stdio session host sits behind `https://api.<app>.localhost`; editor/IDE clients use `ask-local get` output |
| `ask-mcp` | MCP servers get named URLs per service (`mcp.<app>.localhost`), no port coordination across servers |
| `ask-skills` | Ships the `ask-local` skill (auto-discovered): boot via `ask-local`, wire via `get`, callbacks from `ASK_LOCAL_URL` |
| `ask-ruby-harness` | `DevUrl` tool: structured `list`/`get` for agents, audit-logged like every other tool |

What we do differently from Kamal for local dev: Kamal + kamal-proxy
own production (Let's Encrypt, zero-downtime deploys, multi-host).
ask-local never serves prod — but the variant slug is shared, so
`fix-ui.myapp.localhost` locally and `myapp-fix-ui.preview.example.com`
in staging (via `ask-local kamal fix-ui`) are the same branch everywhere.

## Prior art

Same problem, three generations — ask-local borrows from all of them:

- **Pow** (2011–2017, macOS-only Rack): the ergonomics — zero-config
  names, `tmp/restart.txt`, `.powrc` env loading. Left behind: Nack
  workers, firewall forwarding, HTTP-only, unmaintained.
- **puma-dev** (Go, macOS/Linux): the engine semantics — Puma on unix
  sockets, lazy boot, idle kill, restart.txt watching, in-memory dynamic
  TLS, per-route status. Kept as behavior, reimplemented in Ruby.
- **portless** (Node 24, any stack): the agent interface — explicit run
  ownership, `PORTLESS_URL`-style env contract, `get/doctor/prune`,
  worktree prefixes, custom-TLD OAuth parity, SKILL.md pattern.

Build vs borrow decision: ask-local is pure Ruby (stdlib + base64),
not a wrapper around puma-dev's Go core. Rationale: zero-toolchain
distribution (`gem install`, no Go/Node), the ask-core zero-dependency
philosophy, and full control over the agent surface (route store,
supervision, skills). puma-dev's semantics were ported, not its binary.

## Non-goals (deliberate)

- **HTTP/2.** Ruby dev servers serve a handful of requests, not Vite's
  hundreds of unbundled files — the multiplexing win doesn't apply, and
  ALPN/HPACK/stream state would triple the proxy's auditable surface.
  Revisit only on benchmarked HMR latency. (Consequence: no HTTP/2
  extended-CONNECT bridging; browsers never negotiate h2 here, so plain
  Upgrade tunneling covers Action Cable fully.)
- **LAN/mDNS and Tailscale/ngrok tunnels.** mDNS behaves differently on
  every network; tunnels need third-party CLIs, auth state, and accounts.
  The 95% "show this branch to someone" case is covered by the `kamal`
  preview-deploy snippet on real infrastructure instead of a laptop
  tunnel. Kamal owns remote access; ask-local owns local naming.
- **Production serving.** The proxy binds loopback only, the CA is
  self-signed, and there is no request buffering, rate limiting, or
  access control. Anything real goes through Kamal + kamal-proxy.

## Development

```bash
bundle install
bundle exec rake test
```

## Non-goals (deliberate)

- **HTTP/2.** Ruby dev servers serve a handful of requests, not Vite's
  hundreds of unbundled files — the multiplexing win doesn't apply, and
  ALPN/HPACK/stream state would triple the proxy's auditable surface.
- **LAN/mDNS or tunneled sharing.** mDNS behaves differently on every
  network; third-party tunnels need CLIs, auth state, and accounts.
  The `kamal` preview-deploy snippet covers "show this branch to
  someone" on real infrastructure instead.
- **Production serving.** The proxy binds loopback only, the CA is
  self-signed, and there is no buffering or rate limiting.


The `ask-local-apps` fixture fleet (sibling checkout) exercises
detection, inference, and boot across Rails variants, Roda, Sinatra,
bare Rack, Jekyll, compound Procfiles, and a monorepo. CI runs the
fixture sweep automatically.

## License

MIT
