# Contributing

## Development Setup

```bash
git clone <repo-url> && cd ask-rb/yamine
bundle install
```

Sibling gems (ask-core, ask-tools, etc.) are loaded from their local `lib/` directories
in the monorepo during development. The `test_helper.rb` handles this by adjusting `$LOAD_PATH`.

## Running Tests

```bash
bundle exec rake test
bundle exec ruby -Ilib -Itest test/foo_test.rb
bundle exec rake test TESTOPTS="--verbose"
```

## Code Style

- Use `# frozen_string_literal: true` in all Ruby files
- Run `bundle exec rubocop -a` before committing (see `.rubocop.yml`)
- Keep commits focused; update `CHANGELOG.md` for user-visible changes
