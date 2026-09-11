---
name: yamine
description: Run Ruby apps through yamine for stable named .localhost URLs (e.g. https://myapp.localhost instead of http://localhost:3000). Use when booting dev servers (Rails, Rack, Roda, Sinatra, Jekyll), wiring frontend to API, configuring OAuth callbacks or webhooks, debugging port conflicts, or working in git worktrees.
---

# Local Dev with yamine

Never invent ports. Never parse them from logs. Every app has a stable URL.

## One file, one command

Every app declares `config/local.yml` — the single source of truth:

```yaml
service: myapp
proxy:
  tld: localhost
processes:
  web:
    cmd: bundle exec puma -b tcp://127.0.0.1:$PORT config.ru
    proxy: true          # gets https://myapp.localhost
  worker:
    cmd: bundle exec sidekiq
    proxy: false         # background, supervised, no URL
env:
  clear:
    RAILS_ENV: development
```

If the file is missing, yamine prints `Run yamine init`. Generate it
with `yamine init` (migrates an existing Procfile). Rails apps need
no extra gem — the proxied hostname is allowed automatically via
`RAILS_DEVELOPMENT_HOSTS`.

```bash
yamine start              # setup if needed, then boot every process (waits until healthy)
yamine start --no-wait   # fire-and-forget (register routes immediately)
yamine start --json       # machine-readable wait result (--wait default)
yamine                    # same as start
yamine stop               # stop this app's backend + routes
yamine status             # show service, processes, and URLs
yamine log [-f]           # tail the web process log
```

`$PORT` and `YAMINE_URL` are injected per process; HTTP processes get
stable URLs, background ones are supervised without routes. A process
that exits cleans up the whole tree.

The boot narrates every phase — deps, db, schema, and each process's
healthcheck — one line per phase, so a slow boot is never a black box:

```
  [deps] ok (479ms) dependencies satisfied
  [web] ok (2.2s) healthcheck /up returned 2xx-3xx
```

With `--json` the same events stream to stdout as one JSON object per
line, flushed as they happen (safe to read incrementally), and the
human banner moves to stderr — so stdout stays parseable and the final
payload is the last line:

```
{"phase":"deps","action":"deps","status":"ok","duration_ms":479,...}
{"phase":"process","action":"web","status":"ok","duration_ms":2223,...}
{"ok":true,"service":"myapp","urls":{"web":"https://myapp.localhost"},...}
```

On failure the payload carries the failed phase, that process's log tail,
and the log path — no need to go digging.

## Cross-service wiring

```bash
yamine get backend            # -> https://backend.localhost
yamine get backend --variant demo
```

Use `get` output for frontend-to-API URLs, Cable URLs, and webhook
targets. Do not guess ports.

## Variants are files; worktrees are not

A variant is a file overlay, Kamal-style: `config/local.<variant>.yml`
deep-merges over `config/local.yml`, selected with `YAMINE_VARIANT` or
`--variant`. Naming one also prefixes the hostname.

A git worktree needs none of that: it gets a branch prefix automatically
(`ui-onboarding.myapp.localhost`) and boots alongside its main checkout,
which keeps the bare name. The whole branch is the label, so
`feature/login` and `bugfix/login` stay distinct. A detached worktree
falls back to its directory name.

```bash
YAMINE_VARIANT=fix-ui yamine    # boots with config/local.fix-ui.yml merged
```

Only an explicit variant ever looks for an overlay file — a branch name
that happens to match one on disk is ignored. `yamine status` shows
`variant:` and `overlay:` separately.

## First time on a machine

Run `yamine start` — it does the one-shot CA trust, port 443, and
hosts sync if anything is missing, then boots. Prefer `yamine setup`
for workstation setup without booting. If any command fails with a
privileged-port error, do not work around it with `-p` — run
`yamine setup` instead. A `:port` suffix in a URL means someone
explicitly opted into it.

## OAuth and webhooks

Build callback URLs from `YAMINE_URL` (injected into every HTTP
process):

```ruby
callback = "#{Yamine::Rails.url}/auth/google/callback"
```

Strict providers (Google, Apple) reject `.localhost`. Serve the app on a
domain you own instead — no code change, just config:

```yaml
proxy:
  host: myapp.local.example.com   # instead of tld: localhost
```

## Troubleshooting

```bash
yamine doctor                 # read-only: proxy, routes, DNS, CA trust
yamine list --json            # routes as stable JSON
yamine prune                  # clear stale routes from crashed sessions
yamine start --json           # boot readiness payload (pass/fail + log tail)
```

If a hostname does not resolve: `yamine hosts sync`. If the browser
warns about TLS: `yamine trust`.

## When NOT to use yamine

- **CI pipelines**: no TTY, no sudo, no browsers. Run the app's own test
  command directly; yamine fails fast here by design.
- **Production consoles and servers**: the proxy binds loopback only and
  the CA is self-signed. Use Kamal + kamal-proxy for anything real.
- **Docker-internal networking**: containers reach each other by service
  name on the compose network, not via the host's `.localhost`.
- **Debugging the proxy itself**: use `yamine proxy start --foreground`
  and read the log; do not layer another yamine on top.
