# frozen_string_literal: true

require_relative "test_helper"

class RailsModuleKebabTest < Minitest::Test
  def test_camelcase_boundaries_become_hyphens
    assert_equal "rails-8-min", Yamine::Inference.parse_rails_module("module Rails8Min\nend")
    assert_equal "my-app", Yamine::Inference.parse_rails_module("module MyApp\nend")
    assert_equal "my-app", Yamine::Inference.parse_rails_module("module My_App\nend")
    assert_nil Yamine::Inference.parse_rails_module("nothing here")
  end
end

class MonorepoRootConfigTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @orig_env = ENV.to_h
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "config", "local.yml"), <<~YAML)
      service: shop
      proxy:
        tld: localhost
      processes:
        web:
          cmd: bin/rails s
          proxy: true
        api:
          cmd: bin/api
          proxy: true
    YAML
    FileUtils.mkdir_p(File.join(@root, "web"))
    FileUtils.mkdir_p(File.join(@root, "api"))
    FileUtils.mkdir_p(File.join(@root, "other"))
  end

  def teardown
    FileUtils.remove_entry(@root)
    ENV.replace(@orig_env)
  end

  def test_subdir_uses_root_config
    r = Yamine::Resolver.resolve(File.join(@root, "web"))
    assert_equal "shop", r.app
    assert_includes Yamine::Resolver.hostnames(r), "shop.localhost"
  end

  def test_unlisted_subdir_falls_back_to_inference
    r = Yamine::Resolver.resolve(File.join(@root, "other"))
    assert_equal "shop", r.app  # walks up to root config.local.yml
  end

  def test_variant_overlay
    overlay = File.join(@root, "config", "local.staging.yml")
    FileUtils.mkdir_p(File.dirname(overlay))
    File.write(overlay, "proxy:\n  tld: staging.example.com")
    r = Yamine::Resolver.resolve(File.join(@root, "web"), variant: "staging")
    assert_equal "staging.example.com", r.tld
    assert_equal "shop", r.app
  end
end

class WebServiceBareTest < Minitest::Test
  def test_web_service_stays_bare
    assert_equal ["shop.localhost"],
      Yamine::Hostname.build(app: "shop", service: "web")
    assert_equal ["api.shop.localhost"],
      Yamine::Hostname.build(app: "shop", service: "api")
  end
end

class PortInjectionTest < Minitest::Test
  def cli
    @cli ||= Yamine::CLI.new
  end

  def test_jekyll_gets_port_and_host
    cmd = ["bundle", "exec", "jekyll", "serve"]
    assert_equal cmd + ["--port", "4123", "--host", "127.0.0.1"],
      cli.send(:inject_port_flags, cmd, 4123)
  end

  def test_respects_existing_port
    cmd = ["bundle", "exec", "jekyll", "serve", "--port", "4000"]
    assert_equal cmd, cli.send(:inject_port_flags, cmd, 4123)
  end

  def test_ignores_puma
    cmd = ["puma", "-b", "unix://x"]
    assert_equal cmd, cli.send(:inject_port_flags, cmd, 4123)
  end

  def test_does_not_double_inject_dollar_port
    cmd = ["sh", "-c", "bin/dev-server --port $PORT"]
    assert_equal cmd, cli.send(:inject_port_flags, cmd, 4123)
  end
end

class ProcfileSelectTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def cli
    @cli ||= Yamine::CLI.new
  end

  def in_dir(&block)
    Dir.chdir(@dir, &block)
  end

  def test_first_line_by_default
    File.write(File.join(@dir, "Procfile.dev"),
      "web: bin/rails s -p 3000\nworker: bundle exec sidekiq\n")
    in_dir { assert_equal ["sh", "-c", "bin/rails s -p 3000"], cli.send(:procfile_command) }
  end

  def test_proc_flag_picks_named_process
    File.write(File.join(@dir, "Procfile.dev"),
      "web: bin/rails s -p 3000\nworker: bundle exec sidekiq\n")
    in_dir { assert_equal ["sh", "-c", "bundle exec sidekiq"], cli.send(:procfile_command, "worker") }
  end

  def test_unknown_process_returns_nil
    File.write(File.join(@dir, "Procfile.dev"), "web: bin/rails s\n")
    in_dir { assert_nil cli.send(:procfile_command, "bogus") }
  end

  def test_compound_process_refused
    File.write(File.join(@dir, "Procfile.dev"), "web: bin/rails s -p 3000 && echo hi\n")
    in_dir { assert_nil cli.send(:procfile_command) }
  end
end

class SkillTest < Minitest::Test
  def test_skill_ships_in_yamine
    path = File.expand_path("../lib/ask/skills/yamine/SKILL.md", __dir__)
    assert File.file?(path)
    content = File.read(path)
    assert_includes content, "name: yamine"
    assert_includes content, "description:"
    assert_includes content, "YAMINE_URL"
    assert_includes content, "config/local.yml"
    assert_includes content, "yamine init"
    refute_includes content, "--proc"  # old Procfile-era flag gone
  end
end

