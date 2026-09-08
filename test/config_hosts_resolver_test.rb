# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, "config"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_yml(content)
    File.write(File.join(@dir, "config", "local.yml"), content)
  end

  def test_loads_service
    write_yml("service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    config = Yamine::Config.load(@dir)
    assert_equal "myapp", config.service
  end

  def test_invalid_yml_raises
    File.write(File.join(@dir, "config", "local.yml"), ": [bad")
    assert_raises(Yamine::ConfigError) { Yamine::Config.load(@dir) }
  end

  def test_missing_service_raises
    write_yml("proxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    assert_raises(Yamine::ConfigError) { Yamine::Config.load(@dir) }
  end

  def test_empty_processes_raises
    write_yml("service: x\nprocesses: {}")
    assert_raises(Yamine::ConfigError) { Yamine::Config.load(@dir) }
  end

  def test_missing_config_returns_nil
    assert_nil Yamine::Config.load(@dir)
  end
end

class ResolverTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, "config"))
    @orig = ENV.to_h
  end

  def teardown
    ENV.replace(@orig)
    FileUtils.remove_entry(@dir)
  end

  def write_yml(content)
    File.write(File.join(@dir, "config", "local.yml"), content)
  end

  def test_service_from_config
    write_yml("service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    r = Yamine::Resolver.resolve(@dir)
    assert_equal "myapp", r.app
    assert_equal "localhost", r.tld
  end

  def test_tld_from_config
    write_yml("service: x\nproxy:\n  tld: preview.example.com\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    r = Yamine::Resolver.resolve(@dir)
    assert_equal "preview.example.com", r.tld
  end

  def test_host_from_config
    write_yml("service: x\nproxy:\n  host: myapp.prod.example.com\nprocesses:\n  web:\n    cmd: s\n    proxy: true")
    r = Yamine::Resolver.resolve(@dir)
    assert_equal "myapp.prod.example.com", r.host
  end

  def test_hostnames_compose_from_config
    write_yml("service: myapp\nproxy:\n  tld: localhost\nprocesses:\n  web:\n    cmd: s\n    proxy: true\n  api:\n    cmd: api\n    proxy: true\n  worker:\n    cmd: j\n    proxy: false")
    r = Yamine::Resolver.resolve(@dir)
    hostnames = Yamine::Resolver.hostnames(r)
    assert_includes hostnames, "myapp.localhost"
    assert_includes hostnames, "api.myapp.localhost"
    refute_includes hostnames, "worker.myapp.localhost"
  end

  def test_missing_config_raises
    err = assert_raises(Yamine::ConfigError) do
      Yamine::Resolver.resolve(@dir)
    end
    assert_match(/yamine init/, err.message)
  end
end
