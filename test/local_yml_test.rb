# frozen_string_literal: true

require_relative "test_helper"

class LocalYmlConfigTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir) rescue nil
    FileUtils.remove_entry(ENV["YAMINE_STATE_DIR"]) rescue nil
    ENV["YAMINE_STATE_DIR"] = @orig
  end

  def write_config(content)
    FileUtils.mkdir_p(File.join(@dir, "config"))
    File.write(File.join(@dir, "config", "local.yml"), content)
  end

  def test_load_valid_config
    write_config <<~YAML
      service: myapp
      proxy:
        tld: localhost
      processes:
        web:
          cmd: bin/rails s
          proxy: true
        worker:
          cmd: bin/jobs
          proxy: false
    YAML
    config = Yamine::Config.load(@dir)
    assert_equal "myapp", config.service
    assert_equal "localhost", config.proxy_config["tld"]
    assert config.processes.key?("web")
    assert config.processes.key?("worker")
  end

  def test_load_valid_with_tld_override
    write_config <<~YAML
      service: myapp
      proxy:
        tld: local.example.com
      processes:
        web:
          cmd: bin/rails s
          proxy: true
    YAML
    config = Yamine::Config.load(@dir)
    assert_equal "local.example.com", config.proxy_config["tld"]
  end

  def test_load_valid_with_host_override
    write_config <<~YAML
      service: myapp
      proxy:
        host: myapp.local.example.com
      processes:
        web:
          cmd: bin/rails s
          proxy: true
    YAML
    config = Yamine::Config.load(@dir)
    assert_equal "myapp.local.example.com", config.proxy_config["host"]
  end

  def test_missing_config_returns_nil
    assert_nil Yamine::Config.load(@dir)
  end

  def test_missing_service_raises
    write_config <<~YAML
      proxy:
        tld: localhost
      processes:
        web:
          cmd: bin/rails s
    YAML
    err = assert_raises(Yamine::ConfigError) do
      Yamine::Config.load(@dir)
    end
    assert_match(/service.*required/, err.message)
  end

  def test_empty_processes_raises
    write_config <<~YAML
      service: myapp
      processes: {}
    YAML
    err = assert_raises(Yamine::ConfigError) do
      Yamine::Config.load(@dir)
    end
    assert_match(/at least one process/, err.message)
  end

  def test_invalid_yml_raises
    FileUtils.mkdir_p(File.join(@dir, "config"))
    File.write(File.join(@dir, "config", "local.yml"), ":\n  bad: [yaml")
    err = assert_raises(Yamine::ConfigError) do
      Yamine::Config.load(@dir)
    end
    assert_match(/Invalid YAML/, err.message)
  end

  def test_erb_interpolation
    write_config <<~YAML
      service: myapp
      proxy:
        tld: localhost
      processes:
        web:
          cmd: "bin/rails s -e <%= ENV.fetch('RAILS_ENV', 'development') %>"
          proxy: true
    YAML
    config = Yamine::Config.load(@dir)
    assert_includes config.processes["web"]["cmd"], "development"
  end

  def test_x_extensions_ignored
    write_config <<~YAML
      x-custom: { foo: bar }
      service: myapp
      processes:
        web:
          cmd: bin/rails s
          proxy: true
    YAML
    config = Yamine::Config.load(@dir)
    assert_equal "myapp", config.service
  end

  def test_unknown_key_raises
    write_config <<~YAML
      service: myapp
      bogus_key: value
      processes:
        web:
          cmd: bin/rails s
          proxy: true
    YAML
    err = assert_raises(Yamine::ConfigError) do
      Yamine::Config.load(@dir)
    end
    assert_match(/Unknown key/, err.message)
  end

  def test_variant_overlay
    write_config <<~YAML
      service: myapp
      proxy:
        tld: localhost
      processes:
        web:
          cmd: bin/rails s
          proxy: true
    YAML
    overlay_path = File.join(@dir, "config", "local.staging.yml")
    FileUtils.mkdir_p(File.dirname(overlay_path))
    File.write(overlay_path, <<~YAML)
      proxy:
        tld: local.staging.example.com
    YAML
    config = Yamine::Config.load(@dir, variant: "staging")
    assert_equal "local.staging.example.com", config.proxy_config["tld"]
    assert_equal "myapp", config.service
  end

  def test_host_tld_mutual_exclusion
    write_config <<~YAML
      service: myapp
      proxy:
        host: myapp.local.example.com
        tld: localhost
      processes:
        web:
          cmd: bin/rails s
          proxy: true
    YAML
    err = assert_raises(Yamine::ConfigError) do
      Yamine::Config.load(@dir)
    end
    assert_match(/one of host or tld/, err.message)
  end

  def test_proxy_classify_web_is_http
    write_config <<~YAML
      service: myapp
      proxy:
        tld: localhost
      processes:
        web:
          cmd: bin/rails s
          proxy: true
        worker:
          cmd: bin/jobs
          proxy: false
    YAML
    config = Yamine::Config.load(@dir)
    resolved = Yamine::Resolver.resolve(@dir)
    assert_equal "myapp", resolved.app
    assert_equal "localhost", resolved.tld
    assert_equal "myapp.localhost", Yamine::Resolver.hostname_for(resolved, "web")
    assert_nil Yamine::Resolver.hostname_for(resolved, "worker")
  end

  def test_init_creates_config_from_procfile
    FileUtils.mkdir_p(@dir)
    File.write(File.join(@dir, "Procfile.dev"), <<~PROCFILE)
      web: bin/rails server
      worker: bin/jobs
    PROCFILE
    Dir.chdir(@dir) do
      Yamine::CLI::SystemCommand.init(Yamine::CLI::Context.new, [])
    end
    config_path = File.join(@dir, "config", "local.yml")
    assert File.file?(config_path)
    content = File.read(config_path)
    assert_includes content, "service: #{File.basename(@dir).downcase.gsub(/[^a-z0-9-]/, '-')}"
    assert_includes content, "web:"
    assert_includes content, "bin/rails server"
    assert_includes content, "worker:"
    assert_includes content, "bin/jobs"
  end

  def test_resolves_local_hostnames
    write_config <<~YAML
      service: myapp
      proxy:
        tld: localhost
      processes:
        web:
          cmd: bin/rails s
          proxy: true
        api:
          cmd: bin/api
          proxy: true
        worker:
          cmd: bin/jobs
          proxy: false
    YAML
    resolved = Yamine::Resolver.resolve(@dir)
    hostnames = Yamine::Resolver.hostnames(resolved)
    assert_includes hostnames, "myapp.localhost"
    assert_includes hostnames, "api.myapp.localhost"
    refute_includes hostnames, "worker.myapp.localhost"
  end
end
