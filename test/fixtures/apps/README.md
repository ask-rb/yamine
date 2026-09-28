# ask-local-apps

Test fixture fleet for [ask-local](https://github.com/ask-rb/ask-local).
Each app declares a `config/local.yml` (the mandatory Kamal-style config)
and exercises a different detection, boot, or routing path. Rack apps
(`config.ru`) boot through managed Puma; the monorepo exercises config
walk-up from a subdirectory.

| Fixture | service | processes | Exercises |
|---|---|---|---|
| `bare-rack` | bare-rack | web | Minimal config.ru boot |
| `roda-app` | roda-app | web | Roda via managed Puma |
| `sinatra-classic` | sinatra-classic | web | Classic Sinatra via config.ru |
| `sinatra-modular` | sinatra-modular | web | Modular Sinatra (`run ModularApp`) |
| `hanami-ish` | hanami-ish | web | Slice layout via config.ru |
| `jekyll-docs` | jekyll-docs | web | Jekyll run mode (no config.ru) |
| `rails8-min` | rails8-min | web | Rails 8 app |
| `monorepo` | shop | web, api | Root config; subdirs walk up |
| `procfile-compound-refusal` | — | — | Legacy Procfile refusal (kept for reference) |
| `rails8-hardcoded-port` | — | — | Legacy hardcoded-port case |

## The config model

Each Rack fixture has `config/local.yml`:

```yaml
service: roda-app
proxy:
  tld: localhost
processes:
  web:
    cmd: puma -b tcp://127.0.0.1:$PORT config.ru
    proxy: true
```

`$PORT` is injected by ask-local; the process runs through `sh -c` so
shell env expansion works.

## Sweep

```bash
ruby -I../ask-local/lib /tmp/sweep.rb   # resolution across all fixtures
```

Boot QA:

```bash
ruby -Ilib /tmp/boot_sweep.rb           # spawns each web process, checks route
```
