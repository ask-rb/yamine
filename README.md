# yamine

[![Gem Version](https://badge.fury.io/rb/yamine.svg)](https://badge.fury.io/rb/yamine)

Stable named `.localhost` URLs for Ruby development. Gives every Ruby app
a stable `https://<app>.localhost` URL instead of a memorized port.
Zero runtime dependencies — Ruby stdlib only (`openssl`, `socket`).

```bash
gem install yamine
yamine start          # setup + boot in one go (or plain `yamine`)
yamine setup          # once per machine: CA trust + port 443 + hosts + verify
cd ~/code/myapp && yamine
# -> https://myapp.localhost
```


## Why "yamine"?

**Yamine** (يمين, *yamīn*) is Arabic for "right hand" — the side of blessing
and good fortune, the hand you keep things close with. It sits next to
**Kamal** (كمال, *kamāl*, "completeness, perfection"): Kamal completes the
deploy, Yamine keeps the app at your right hand — local, close, yours.

And yes, if you follow football: *Yamine Kamal* is Lamine Yamal with the
names flipped. I'm a fan — the kid who nutmegs entire defenses at sixteen
is exactly the energy local dev should have. The local half of the game,
played the same way: fast, fearless, and fun to watch.

(For the curious: `yamine` is pronounced "ya-MEEN".)

## The no-fallback promise

yamine never silently degrades to a `:<port>` URL. Clean
`https://<app>.localhost` requires the proxy on port 443; if 443
cannot be bound, you get a hard error pointing at `yamine setup`
— never a booted app on `https://app.localhost:1355` that silently
poisons OAuth callbacks, mailer hosts, and webhooks downstream.

The only port-suffixed URLs are the ones you explicitly ask for:
`yamine proxy start -p 1355` (CI/sandboxes where 443 is impossible).
There the suffix is honest, and `YAMINE_URL` carries it faithfully.

Because the port is recorded machine-wide, yamine refuses to let a
one-off `-p` outlive its process: a recorded port is reused only while
something is actually listening on it. Stop that proxy and the next
`yamine` run goes back to the clean default (443) instead of quietly
raising another proxy on 1355. `yamine doctor` and `yamine start` both
say so out loud when a running proxy is on a non-default port — the
`[warn]` line names the port, the `:PORT` it puts in every URL, and how
to get back to 443.

## Port 443: one-time setup, then never again

Binding 443 is privileged, so yamine installs a **root-owned launchd
service** (macOS) or systemd unit (Linux) that binds 443 at boot — the
same model as puma-dev and portless. Installing it needs sudo **once per
machine**; after that, every `yamine` run in any project gets a clean
`https://<app>.localhost` with no elevation and no prompt.

**Human (interactive):** run setup once — it trusts the CA, installs the
service, syncs hosts, and verifies:

```bash
yamine setup
```

**Agent / CI (no TTY):** the same commands fail fast with guidance,
because sudo needs a terminal. To pre-provision a machine or image so
agents can install the service without a prompt, install the scoped
passwordless-sudo rules once (as an admin):

```bash
yamine sudoers > /tmp/yamine.sudoers
sudo install -o root -g wheel -m 440 /tmp/yamine.sudoers /etc/sudoers.d/yamine   # macOS
sudo install -o root -g root -m 440 /tmp/yamine.sudoers /etc/sudoers.d/yamine   # Linux
```

`yamine sudoers` prints rules scoped to yamine's own service
re-exec — the gem's exact ruby + bin path with the `service install
--internal` / `service uninstall --internal` subcommands — never a bare
interpreter. Re-run it after upgrading the gem if the install path
changes. To undo: `sudo rm /etc/sudoers.d/yamine`.

## The one-file model

Every app declares `config/local.yml` (Kamal-style) — the single source
of truth for service name, proxy TLD/host, processes, and env:

```yaml
service: myapp
proxy:
  tld: localhost
  subdomains: false      # opt in to answering *.myapp.localhost
processes:
  web:
    cmd: bundle exec puma -b tcp://127.0.0.1:$PORT config.ru
    proxy: true
  worker:
    cmd: bundle exec sidekiq
    proxy: false
```

Optional top-level `db: false` opts out of per-worktree databases
(exotic setups — manual `establish_connection`, shared staging DB, …);
`db.schema_load` overrides the schema-load command. Per-process
`healthcheck: { path: /up, timeout: 30 }` declares what `--wait` polls
(TCP accept when absent). The poll is plain HTTP against the app's own
`127.0.0.1:$PORT` listener — TLS is terminated by the proxy, so the path
is reached over http regardless of the `https://` URL in the banner.)

`yamine init` creates the file (migrating an existing Procfile);
Rails apps need no extra gem — yamine injects `RAILS_DEVELOPMENT_HOSTS`
so the proxied hostname is allowed automatically. `yamine`
then boots every process, assigns each a `$PORT`, injects
`YAMINE_URL`, registers routes for HTTP processes, supervises the
whole tree, and cleans up when one exits.

Variants are file overlays: `config/local.<variant>.yml` deep-merges on
top of `config/local.yml`, selected by `YAMINE_VARIANT` (Kamal's
destination pattern). Naming a variant also prefixes the hostname — see
below for how that differs from a worktree's automatic prefix.

`.localhost` resolves to loopback natively in Chrome, Firefox, and Edge —
no DNS server, no `/etc/resolver`. Safari may need `yamine hosts sync`.

## Hostname shape

```
{variant}.{service}.{app}.{tld}
```

| Axis | Example | Source |
|---|---|---|
| app | `myapp` | inferred, `--name`, `yamine.json`, `YAMINE_NAME` |
| service | `api.myapp` | `--service`, `YAMINE_SERVICE` (`web` stays bare) |
| variant | `fix-ui.myapp` | `--variant`, `YAMINE_VARIANT`, linked worktree branch |
| tld | `myapp.preview.example.com` | `--tld` (default `localhost`) |

`proxy.host` is the one exception: an explicitly written full hostname
bypasses composition entirely, variant included.

Linked git worktrees get a branch prefix automatically
(`ui-onboarding.myapp.localhost`); the main checkout keeps the bare name,
so a worktree and its main checkout run side by side. The label is the
whole branch (`feature/login` → `feature-login.myapp.localhost`), so two
branches that share a last segment never share a hostname. A detached
HEAD has no branch to name it and falls back to the worktree's directory
— the same identity its per-worktree database uses. `main`/`master`
never prefix. Pass `--branch` (or `YAMINE_BRANCH=1`) to prefix by the
current branch outside worktrees.

A variant is a hostname label, not a config file. Only an explicit
`--variant` / `YAMINE_VARIANT` goes looking for
`config/local.<name>.yml` to merge; a worktree branch never does, so a
branch named like a file on disk cannot change your config by accident.
`yamine status` prints both lines so the two are never confused.

```bash
yamine                                          # -> https://myapp.localhost
yamine --service api                            # -> https://api.myapp.localhost
yamine --variant demo                           # -> https://demo.myapp.localhost
yamine --tld preview.example.com                # your own domain (OAuth parity)
```

## Subdomains are opt-in

A route answers its exact hostname. `*.myapp.localhost` reaches
`myapp.localhost` only if that app asked for it:

```yaml
proxy:
  subdomains: true     # this app answers its own subdomains
```

```bash
yamine alias tenant1 4001 --wildcard   # one route, its subdomains
```

Off is the useful default. An unregistered label under a live app is far
more likely to be a worktree whose stack is stopped than a tenant, and
handing that label to the parent app means HTTP 200 with the wrong code.
Instead the request 404s and names the parent app, its directory, and how
to start it. `yamine status` reports which mode an app is in.

## Commands

```bash
yamine                        # boot app (waits until healthy, then supervises)
yamine start --no-wait        # fire-and-forget (register routes immediately)
yamine start --json           # machine-readable wait result (--wait default)
yamine run -- <cmd>           # run explicit command through proxy
yamine get <name>             # print URL for cross-service wiring
yamine alias <name> <port>    # static route (e.g. Docker)
yamine list [--json]          # show active routes (+ backend liveness)
yamine status [--json]        # show effective naming context here
yamine doctor [--json]        # machine-readable health checks
yamine open [name]            # open the app URL in a browser
yamine trust                  # add local CA to system trust store
yamine clean                  # remove state and hosts entries
yamine prune                  # remove stale routes
yamine db list|create|drop    # per-worktree databases
yamine worktree list|clean    # worktree databases + orphan cleanup
yamine stop                   # stop this app's backend + routes
yamine restart                # touch tmp/restart.txt (managed apps reboot)
yamine log [-f] [n]           # tail (or follow) this app's backend log
yamine proxy start|stop       # control the proxy
yamine service install|status|uninstall   # root-owned OS startup service
yamine hosts sync|clean       # manage /etc/hosts entries
yamine kamal <variant>        # preview-deploy snippet for Kamal
```

Child processes receive `YAMINE_URL` (the stable URL — use it for
OAuth callbacks, mailer hosts, webhook URLs), `PORT`, and `HOST`.

## Frameworks

Rails and bare Rack (`config.ru`) boot managed on a unix socket (Puma
when available; `rackup` on TCP otherwise). `Procfile.dev`/`bin/dev`,
Jekyll, Bridgetown, and Middleman run in run mode with `PORT` injected
(port-ignoring CLIs get explicit `--port/--host` flags). Anything else:
`yamine run -- <cmd>`.

```bash
yamine --proc web             # boot a specific Procfile process
yamine --proc worker          # (first line is the default)
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

`list`, `status`, `doctor`, and `yamine start --wait` accept `--json` with stable keys for
agents and scripts (`DevUrl` in ask-ruby-harness consumes the same data
in-process). Hostnames that fall outside the configured TLDs get a bare
404 naming nothing — route names never leak to foreign hosts
(DNS-rebinding boundary).

`yamine start` (default `--wait`) exits 0 only once every HTTP route is healthy
(healthcheck path when declared, TCP accept otherwise). On failure it
exits 1 with the failed process, its phase, and the tail of its own log
— no guessing, no polling, no half-booted routes. `--no-wait` keeps the
old fire-and-forget path.

## Log rotation

`proxy.log` and per-app backend logs rotate at 5MB
(`YAMINE_LOG_MAX_BYTES`), keeping one generation. `doctor` warns
when the state dir passes 100MB.

## Supervision

Managed apps are supervised by the proxy daemon, not the CLI:

- idle backends stop after 15 minutes (`YAMINE_IDLE_TIMEOUT`
  seconds; `0` disables) and boot transparently on the next request
- touching `tmp/restart.txt` stops the backend; next request reboots it
- crashed backends are detected and rebooted on the next request
- daemon shutdown stops every supervised backend (no orphans)

Run-mode (TCP) routes and static aliases are never supervised.

## Ask ecosystem integration

| Gem | How yamine helps |
|---|---|
| `ask-rails` | yamine core injects `RAILS_DEVELOPMENT_HOSTS`; Cable origins + helpers live in the deprecated yamine-rails |
| `ask-rails-harness` | Its 9 Rails tools (routes, models, DB, logs) run against the app the proxy serves; `DevUrl` gives the agent the stable URL instead of a guessed port |
| `ask-app-server` | The JSON-RPC/stdio session host sits behind `https://api.<app>.localhost`; editor/IDE clients use `yamine get` output |
| `ask-mcp` | MCP servers get named URLs per service (`mcp.<app>.localhost`), no port coordination across servers |
| `ask-skills` | Ships the `yamine` skill (auto-discovered): boot via `yamine`, wire via `get`, callbacks from `YAMINE_URL` |
| `ask-ruby-harness` | `DevUrl` tool: structured `list`/`get` for agents, audit-logged like every other tool |

What we do differently from Kamal for local dev: Kamal + kamal-proxy
own production (Let's Encrypt, zero-downtime deploys, multi-host).
yamine never serves prod — but the variant slug is shared, so
`fix-ui.myapp.localhost` locally and `myapp-fix-ui.preview.example.com`
in staging (via `yamine kamal fix-ui`) are the same branch everywhere.

## Prior art

Same problem, three generations — yamine borrows from all of them:

- **Pow** (2011–2017, macOS-only Rack): the ergonomics — zero-config
  names, `tmp/restart.txt`, `.powrc` env loading. Left behind: Nack
  workers, firewall forwarding, HTTP-only, unmaintained.
- **puma-dev** (Go, macOS/Linux): the engine semantics — Puma on unix
  sockets, lazy boot, idle kill, restart.txt watching, in-memory dynamic
  TLS, per-route status. Kept as behavior, reimplemented in Ruby.
- **portless** (Node 24, any stack): the agent interface — explicit run
  ownership, `PORTLESS_URL`-style env contract, `get/doctor/prune`,
  worktree prefixes, custom-TLD OAuth parity, SKILL.md pattern.

Build vs borrow decision: yamine is pure Ruby (stdlib + base64),
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
  tunnel. Kamal owns remote access; yamine owns local naming.
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


The `yamine-apps` fixture fleet (sibling checkout) exercises
detection, inference, and boot across Rails variants, Roda, Sinatra,
bare Rack, Jekyll, compound Procfiles, and a monorepo. CI runs the
fixture sweep automatically.

## License

MIT
