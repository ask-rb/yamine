# Changelog

## [0.8.1] — 2026-09-10

### Fixed

- **An already-correct `/etc/hosts` no longer reports a failure.**
  `Hosts.sync` rewrote the file unconditionally, so on a normal machine
  (where `/etc/hosts` is root-owned) it raised `Errno::EACCES`, returned
  false, and made `yamine start` print "could not write /etc/hosts (try
  sudo yamine hosts sync)" on every boot — pointing at an elevated write
  for a file that already had exactly the right block. `synced?` existed
  for precisely this guard but `sync` never consulted it. `sync` is now a
  no-op returning true when the block already matches, and the setup step
  reports "already lists N hostname(s)" instead of implying a failure.
  Chrome/Firefox/Edge resolve `*.localhost` natively anyway; the file only
  matters for Safari and custom TLDs.


## [0.8.0] — 2026-09-10

### Fixed

- **`--json` progress is flushed as it happens.** stdout is
  block-buffered when it is a pipe — exactly how an agent reads the
  stream — so the per-phase events added in 0.7.0 stayed in the buffer
  until it filled or the process exited, making a slow boot look frozen.
  That is the "poll and guess" behaviour the JSON stream exists to
  replace. Every line is now flushed before the next phase runs.

### Changed

- The yamine agent skill documents the boot stream: the human
  phase lines, the `--json` contract (one flushed object per line, human
  banner on stderr, payload last), and that failures carry the log tail
  and path.

## [0.7.1] — 2026-09-10

### Fixed

- **`yamine start` now honors `YAMINE_PORT`.** `ensure_workstation!`
  hardcoded port 443, so the documented escape hatch for CI and
  sandboxes — "where 443 is impossible" — was ignored: with
  `YAMINE_PORT=8443` on a non-interactive machine, `start` aborted with
  "port 443 needs root to bind" and demanded sudo for a port the user
  had deliberately chosen to avoid. The port and scheme now come from
  the context, and an unprivileged port is started directly instead of
  being treated as a setup failure. The root path is unchanged: 443 on a
  non-interactive machine still points at `yamine setup`.

## [0.7.0] — 2026-09-10

Keeping the no-port promise when the machine's recorded port goes stale,
and making boot legible while it happens.

### Added

- `Log::Report::Human` / `Log::Report::Json`: boot progress sinks, one
  line per phase (`[web] ok (2.2s) healthcheck /up returned 2xx-3xx`).
  `Readiness.phase`/`wait_all` take a `sink:` and never format output
  themselves; `--json` emits one JSON object per event on stdout while
  the human banner moves to stderr, so stdout stays parseable. The phase
  events were previously computed and discarded — `opts[:events]` was
  never set — so a 2-minute deps or healthcheck phase looked like a hang.
- `ProxyControl.default_port?` / `port_notice`, and a `warn` state on
  `Doctor::Check` (rendered `[warn]`, JSON `warn`/`warnings`, never
  affecting exit status).

### Fixed

- **A stale recorded proxy port no longer sticks the machine on a
  port.** `Context#proxy_port` trusted `proxy.port` unconditionally, so a
  one-off `proxy start -p 1355` (CI, a sandbox, a gem-dev foreground
  proxy) outlived its process: the next boot raised a fresh proxy on
  1355 and put `:1355` in every URL — the single outcome yamine exists to
  prevent. The recorded port is now honored only while something is
  actually listening on it; otherwise the machine returns to the clean
  default (443). An explicit `YAMINE_PORT` still wins.
- **Attaching to a non-default port is now said out loud.** Both
  `yamine start` and `yamine doctor` report it (`[warn] listening on port
  1355 — every URL carries :1355 …`) instead of a bare "[ok] listening on
  port 1355" that let a leftover dev proxy quietly downgrade every
  project on the machine.
- **`.localhost` no longer reports as unresolvable.** `Hosts.resolves?`
  used `Resolv.getaddress` — a pure-Ruby DNS client with no nsswitch and
  no RFC 6761 knowledge — so it returned "no address for
  anyworkers.localhost" on a machine where `.localhost` resolves
  perfectly, and `doctor` printed a `[FAIL] dns` while `yamine start`
  advised `sudo yamine hosts sync` (an elevated /etc/hosts write) for a
  problem that did not exist. It now asks the system resolver
  (`Addrinfo.getaddrinfo`), which is what browsers and curl use.
- `supervise_tree` names the process that exited and its log path
  instead of "a process exited — cleaning up all routes".

## [0.6.1] — 2026-09-10

### Fixed

- **Healthchecks no longer speak TLS to the backend.** `--wait` probed
  `127.0.0.1:$PORT` — the app's own listener — with the *proxy's* `tls`
  flag, so any app declaring `healthcheck: { path: }` could never boot
  under the default TLS-on proxy: the probe began an SSL handshake
  against a plaintext Puma, which logged `Invalid HTTP format, parsing
  fails. Are you trying to open an SSL connection to a non-SSL Puma?`
  once per attempt until the process phase timed out and the whole boot
  was torn down. TLS is the proxy's job; the proxy dials backends with a
  bare `TCPSocket`, so `Readiness.probe`/`probe_http`/`wait_healthy`/
  `wait_all` drop the `tls:` keyword entirely (an `https://` banner URL
  never implied the backend speaks TLS). Reported from anyworkers, whose
  web process healthchecks `/up`.

## [0.6.0] — 2026-09-09

`yamine start --wait` + boot readiness protocol. The remaining gap from
“one-storey building” onwards: boot had no definitive answer — agents
polled, guessed from logs, and raced half-booted routes. Now every phase
(deps, db, schema, per-process health) has a real event and `--wait`
delivers one call with a pass/fail payload. Credentials-only DB URLs
warn loudly instead of sharing silently.

### Added

- `Yamine::Readiness`: phased events (`phase`, `action`, `status`,
  `duration_ms`, `detail`), `check_deps` pre-flight, `wait_healthy`
  (healthcheck path or TCP accept), concurrent `wait_all` (one thread
  per process, dead-pid short-circuit so a crash fails fast), per-phase
  timeouts (deps 30s, db 15s, schema 90s, process 45s or per-healthcheck
  timeout). `Yamine::WaitPayload` success/failure payloads for `--json`.
- `yamine start --wait [--json]`: spawns every process, polls until
  healthy, registers routes only on success, kills everything (including
  background children) and exits 1 with the failed phase + that process's
  own log tail on failure — no half-booted routes. `--wait` is kept as a no-op alias;
  `--no-wait` keeps the old sequential fire-and-forget path.
  `--json` is only meaningful with wait (now default).
- Per-process `healthcheck: { path: /up, timeout: 30 }` in
  `config/local.yml`, respected by `--wait`. Absent means TCP accept.
- Boot phases now visible: deps pre-flight, db (`exists?`/`ensure_exists`
  split so provenance doesn't need a second probe), schema, per-process.
  `Runner#spawn_http`/`adopt`/`spawned?` support the concurrent path;
  `boot_run` child output is logged so failure payloads can tail it.

### Fixed

- Top-level `db: false` opts out of per-worktree databases (exotic
  setups: manual `establish_connection`, shared staging DB, …). Validated
  as boolean-or-mapping; `x-` extensions still ignored. `db.schema_load`
  moves to top-level `db` (per-process ghost `db` entry was a category
  error). Credentials-stored `DATABASE_URL`s now work when the template is
  declared in `env.clear` (password via `local.secrets`); when no template
  exists but the app looks database-backed (`database.yml` adapter or
  `pg`/`mysql2`/`trilogy` in `Gemfile`) boot warns loudly with the fix
  instead of silently sharing one database. Framework-agnostic: injection
  is still `DATABASE_URL`, no `ask-auth` dep, no Rails load at boot.

## [0.5.0] — Unreleased

Per-worktree databases: every worktree directory gets its own database
so concurrent agents never share tables.

### Added

- `Yamine::Database`: `<sanitized-dir-basename>_<env>` naming
  (`/code/myapp-fix` → `myapp_fix_development`; main keeps the bare
  name), 63-byte Postgres cap with hash-suffix truncation, collision
  guard via state map (silent sharing would be the bug this kills).
- Boot resolves the DB once, creates it (`createdb`/`mysqladmin`,
  never raises — warns and shares template on failure), runs the app's
  schema-load (`db.schema_load` in config, Rails default, else nothing),
  and injects `DATABASE_URL` into every process. SQLite left alone.
- `yamine db list|create|drop` and `yamine worktree list|clean`
  (orphan reaping for deleted worktrees). Branch plays no part —
  directories are stable, branches hop.

## [0.3.0] — Unreleased

Renamed from `ask-local` to **`yamine`** (يمين, "right hand" — the local
half of the Kamal pair; see README for the full story). Fresh gem, new
history: starts at 0.3.0 to honor the 0.2.x ask-local lineage without
claiming continuity. `Ask::Local` → `Yamine`, `ask-local`/`askl` binaries
→ `yamine`, `ASK_LOCAL_*` env → `YAMINE_*`, state dir `~/.ask-local` →
`~/.yamine`, skill `ask-local` → `yamine`, health headers
`x-ask-local*` → `x-yamine*`. No migration path — no existing users.

## [0.2.1] — 2026-09-08

Patch release focused on making `yamine setup` dependable end-to-end:
it now installs the 443 service and *finishes* (hosts + doctor), works
passwordless for agents, survives first-run edge cases, and shows what it
is doing while it works.

### Fixed

- **`setup` no longer stops after installing the service.** The elevated
  install used to `exit` mid-flow, so `/etc/hosts` was never synced and
  `doctor` never ran despite the "setup complete" promise. Install and
  uninstall now return booleans and the CLI owns the exit codes, so
  `setup` always reaches the hosts and doctor steps. (`service uninstall`
  also crashed outright — it called its handler without the required
  context argument.)
- **A stale user-owned plist is healed on install.** `File.write` keeps
  an existing file's owner, so a leftover plist from an older version
  stayed user-owned and launchd refused it forever with "Bootstrap
  failed: 5". Install now chowns the plist to root explicitly (launchd
  and systemd).
- **The TLS proxy survives plaintext probes.** The health probe sends
  plain HTTP before TLS; an unhandled `SSL_accept` error used to kill
  the acceptor thread, and with both acceptors gone the daemon exited
  before the readiness probe ever succeeded. A plaintext connection is
  now just one dropped connection.
- `clean` referenced the CA common name unqualified (NameError) — fixed.
- `setup --no-service` printed a duplicate "2/3" step — numbered 1/4–4/4.

### Added

- `yamine sudoers` — prints the scoped NOPASSWD rules so agents and
  CI can install and run the 443 service without a TTY. Non-interactive
  elevation uses `sudo -n` (never prompts) and points at the grant when
  it is missing; interactive failures just say re-run.
- The root install syncs `/etc/hosts` under elevation, so Safari works
  the moment setup finishes. `setup`'s hosts step verifies the block is
  already present instead of failing unprivileged on re-runs, and
  `yamine hosts sync` re-runs itself elevated when the direct write
  needs root.
- The CA is trusted into the System keychain silently while elevated
  (all users, no GUI popup); unprivileged trust keeps the login
  keychain.
- Progress UX: the root half of the install prints stage lines as it
  works, and the proxy-start wait shows a rotating spinner on a terminal
  (dots elsewhere), resolving to a clean "proxy is up" line.

### Changed

- launchctl uses the modern system-domain verbs
  (`bootstrap`/`bootout`/`enable`/`kickstart` — the puma-dev/portless
  pattern); the legacy `load`/`unload` are rejected by current macOS.
  The best-effort pre-install bootout is silenced — its "Boot-out
  failed: 5" noise on a first install looked like a failure.
- Every privileged execution path (sudo re-exec, launchctl, systemctl,
  `security`) flows through one injectable `Command` seam, so the test
  suite never shells out to real privileged commands.

### Tests

- Hermetic and CI-safe suite: no real sudo/security/launchctl in tests;
  exact-argument expectations on the `Command` seam, source-pinned
  regressions for the launchctl verbs, root-owned plist and stage
  progress.
- New coverage: setup runs the real elevation path to "Setup complete"
  (regression for the mid-flow exit), hosts-step write/verify/skip
  behavior, `Hosts.synced?`, terminal spinner vs. off-tty dots, e2e
  proof that a TLS daemon survives the plaintext probe, and both
  elevation-failure hint paths. 182 unit + 23 e2e, all green.


## [0.2.0] — 2026-09-07

### Changed

- `cli.rb` (757 lines) split into command objects behind a shared
  Context: `cli/boot.rb` (run/boot/supervision), `cli/routes.rb`
  (get/alias/list/prune/stop/restart/log/status/open),
  `cli/system.rb` (proxy/service/hosts/trust/clean/doctor/kamal).
- Default `rake test` runs the fast unit suite (~6s); `rake test:e2e`
  runs daemon/TLS/live-boot tests; `rake test:all` runs everything.

### Added

- Daemon-owned supervision (puma-dev model): managed apps idle-stop
  after 15 minutes (`YAMINE_IDLE_TIMEOUT`), stop when tmp/restart.txt
  changes, and boot transparently on the next request.
- `yamine stop` (exit 0 stopped / 2 no route / 3 backend already
  gone), `restart`, `log [-f] [n]`, `status` (effective naming context),
  `open [name]` (browser). `list` shows backend liveness per route.
- Root-owned `service install` (launchd/systemd) binding 80/443 at boot
  with the invoking user's state dir; sudo re-exec when needed.
- All root write paths chown state back to the invoking user; `doctor`
  reports an unwritable state dir plainly. The privileged auto-start
  re-execs under `sudo` with the correct state dir.
- Bounded proxy concurrency (`YAMINE_MAX_CONNECTIONS`, 503 past the
  cap), mtime-based route cache (no TTL race for boot-then-curl), IPv4+IPv6
  loopback listeners, dual-stack `ours?` health check.
- `get` inherits variant/TLD context from the current directory
  (`get backend` in a fix-ui worktree -> fix-ui.backend.localhost);
  `--service/--variant/--tld` overrides.
- `alias` accepts full hostnames on any TLD and honors YAMINE_TLD.
- `kamal` snippet resolves the app from the directory; `--app/--domain`
  flags and YAMINE_KAMAL_DOMAIN.
- `clean` untrusts the CA from the OS trust store.
- `--proc <name>` picks a specific Procfile process.
- Ships the `yamine` agent skill (ask/skills/yamine/SKILL.md).
- `test:e2e` / `test:all` rake tasks; CI matrix (3.2/3.3/3.4/4.0),
  macOS e2e leg, fixture-sweep job.
- Ownership module, framework fixtures (sinatra-modular,
  foreman-`$PORT`, hanami2 slice layout, jekyll livereload), SKILL.md
  "when NOT to use" section, README non-goals, vite/Shakapacker recipe.
- Host authorization patterns default TLDs from `YAMINE_TLD`.
- WebSocket Upgrade end-to-end test (RFC 6455 handshake + frame echo),
  hop-loop 508 rejection, chunked framing, and spinning-loop fix.

### Fixed

- Daemon spawn and service install resolved the yamine binary one
  directory too high — `proxy start` failed outright; failures now
  include the proxy log tail.
- Keep-alive connections now rewrite headers (X-Forwarded-Proto) on
  every request, not just the first — request 2+ previously reached the
  backend unrewritten, breaking ssl detection and OmniAuth callbacks.
- Ctrl+C / TERM stops the backend process (no orphans); the CLI exits
  when the backend dies, cleaning up routes.
- SNI certificate minting is arity-agnostic across ruby-openssl versions
  (callback args differ; a raise surfaced as an unrecognized-name alert).
- Proxy honors HTTP/1.1 framing per request: Content-Length bodies are
  forwarded exactly; chunked bodies and responses close-delimit.
- Bidirectional streaming terminates promptly on `Connection: close`
  (each pump direction closes its peer on EOF).
- `alias --remove` now appends the default TLD.
- Install generator `source_root` pointed at a doubled path; generator
  file checks now resolve against `destination_root`.
- Port-flag injection no longer double-sets an explicit `$PORT`.


## [0.1.1] — 2026-09-06

Patch release focused on workstation setup, URL correctness, and proxy reliability.

### Added — `yamine setup` & `yamine start`

- `yamine setup` — one-shot workstation setup for clean
  `https://<app>.localhost` URLs: trust the local CA, serve port 443
  (root launchd/systemd service when possible, sudo daemon otherwise),
  sync `/etc/hosts`, and verify with `doctor`. Each step reports
  `==>` / `ok` and the first failure aborts with the specific fix.
- `yamine start` — one-setup-and-go entry point: an idempotent
  workstation-check-then-boot (`yamine setup` if needed, then the
  app). `yamine` bare is an alias for it; `yamine setup` stays for
  explicit re-setup.
- `askl` — shell-friendly alias binary (`bin/askl`, same entry point as
  `bin/yamine`). Keep `yamine` in logs and docs so `grep` stays
  useful.

### Added — DNS-rebinding & log hygiene

- DNS-rebinding boundary: foreign `Host` headers get a bare 404 naming
  nothing; only hosts under our own configured TLDs see the route-listing
  404. The proxy takes `--tld` (persisted to `proxy.tlds`) so the boundary
  follows custom domains. The `X-Ask-Local: 1` health header marks our
  proxy responses (including 404s) for the `ours?` probe.
- Log rotation — `proxy.log` and per-app backend logs rotate at 5MB
  (`YAMINE_LOG_MAX_BYTES`, one generation) before each write. A new
  `doctor` disk-usage check warns past 100MB of state.

### Fixed

- **Silent `:1355` URL fallback removed.** Privileged-port (443) bind
  failure is now a hard error pointing at `yamine setup`, never a
  booted app on `https://app.localhost:1355` that silently corrupts
  downstream consumers of `YAMINE_URL`. The only port-suffixed URLs
  are the ones you explicitly ask for (`proxy start -p 1355`).
- **Health probe `130+?` hang fixed.** The TLS probe's `connect` sat
  outside the timeout: a TLS handshake against a foreign plain-HTTP
  server blocked in `connect` for 60s+. Connect is now inside the
  timeout, plain HTTP is tried first (our proxy answers plain HTTP via
  byte-peeking even on the TLS port), and any HTTP response without our
  header short-circuits as foreign — only silent servers wait for the
  timeout.
- `start` dispatch was missing from the dispatcher despite being in
  `SUBCOMMANDS`, so `yamine start` fell through to `run_named` with
  "start" as an app name. The kamal-help append drifted to a 6-space
  indent. Both are fixed and pinned by tests.
- `base64` declared as a runtime dependency (it left the default gems in
  Ruby 3.4).
- Missing `require "optparse"` lost in the CLI split.

### Tests — new coverage for this patch

- `start_test.rb` — help, fast-path vs. needs-setup branching, and the
  non-interactive hard-error message.
- `setup_test.rb` — four-step orchestration (all-steps-stubbed), first-failure
  abort with fix text, `--no-service` flag, and the three `ensure_proxy!`
  hard-error paths (non-interactive, foreign port, spawn failure) plus
  explicit-port URL honesty and responding-foreign-server fast classification.
- Pinned under `bundle exec rake test` (fast unit suite); no `test:e2e`
  needed for these.


## [0.1.0]

### Added

- Initial release: explicit-run reverse proxy giving every Ruby app a
  stable `https://<app>.localhost` URL.
- Zero-flag name inference (Rails module, gemspec, package.json, git
  root, directory) with `yamine.json` overrides.
- `{variant}.{service}.{app}.{tld}` hostname composition; linked-worktree
  branch prefixes; custom `--tld` including owned domains.
- Managed Rack boot on unix sockets (rackup/TCP fallback); run mode with
  `PORT`/`YAMINE_URL` injection; `Procfile.dev` and static-site
  framework detection.
- Local CA + per-host SNI certs (in-memory LRU), `trust`, `hosts sync`,
  `doctor`, `prune`, `alias`, `get`, `kamal` snippet.
- Explicit `--port/--host` injection for port-ignoring CLIs (Jekyll,
  Middleman, Bridgetown), skipped when the user already set a port.

### Changed

- Rails module inference kebab-cases CamelCase and digit runs:
  `Rails8Min` → `rails-8-min` (was `rails8min`).
- Monorepo `yamine.json` with an `apps:` map is discovered by walking
  up from the package directory.
- `service: web` produces the bare `app.tld` (all other services prefix).
- Puma 8 command shape (positional `config.ru`; `--rackup` was removed
  upstream) and spawned backends run unbundled so system/bundle puma is
  reachable regardless of the invoking bundle.
- Boot failures include the backend log tail in the error message.
