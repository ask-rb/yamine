# frozen_string_literal: true

require_relative "test_helper"

# The config's `env:` reaching spawned processes.
#
# This was silently broken: `build_env` existed with no callers, so
# top-level `env.clear` (and every `env.secret`) was parsed, validated, and
# then thrown away. It looked fine because DATABASE_URL had its own path —
# but an app whose whole integration depends on a variable in that block
# booted with it blank, which is indistinguishable from a code bug until
# someone reads the process's environment.
class ConfigEnvTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, "config"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_config(yaml)
    File.write(File.join(@dir, "config", "local.yml"), yaml)
  end

  def write_secrets(text)
    File.write(File.join(@dir, "config", "local.secrets"), text)
  end

  def boot_command = Yamine::CLI::BootCommand

  def env_for(proc_name, yaml:, secrets: nil)
    write_config(yaml)
    write_secrets(secrets) if secrets
    resolved = Yamine::Resolver.resolve(@dir)
    boot_command.send(:build_env, resolved, resolved.processes[proc_name], proc_name: proc_name)
  end

  BASE = <<~YAML
    service: myapp
    processes:
      web:
        cmd: bin/rails server
        proxy: true
  YAML

  def test_top_level_env_clear_reaches_every_process
    env = env_for("web", yaml: <<~YAML + BASE)
      service: myapp
      env:
        clear:
          ANYMARK_URL: https://anymark.localhost
          RAILS_ENV: development
      processes:
        web:
          cmd: bin/rails server
          proxy: true
    YAML
    assert_equal "https://anymark.localhost", env["ANYMARK_URL"]
    assert_equal "development", env["RAILS_ENV"]
  end

  def test_process_env_wins_over_top_level
    env = env_for("web", yaml: <<~YAML)
      service: myapp
      env:
        clear:
          LOG_LEVEL: info
      processes:
        web:
          cmd: bin/rails server
          proxy: true
          env:
            clear:
              LOG_LEVEL: debug
    YAML
    assert_equal "debug", env["LOG_LEVEL"], "a process's own env must override the app-wide one"
  end

  def test_top_level_secret_names_are_satisfied_from_the_secrets_file
    env = env_for("web", yaml: <<~YAML + BASE, secrets: "ANYMARK_TOKEN=from-file\n")
      service: myapp
      env:
        secret:
          - ANYMARK_TOKEN
    YAML
    assert_equal "from-file", env["ANYMARK_TOKEN"]
  end

  def test_process_level_secret_names_still_work
    env = env_for("web", yaml: <<~YAML, secrets: "JOB_TOKEN=worker-only\n")
      service: myapp
      processes:
        web:
          cmd: bin/rails server
          proxy: true
          env:
            secret:
              - JOB_TOKEN
    YAML
    assert_equal "worker-only", env["JOB_TOKEN"]
  end

  def test_a_missing_secret_warns_instead_of_booting_blank
    _out, err = capture_io do
      @env = env_for("web", yaml: <<~YAML)
        service: myapp
        env:
          secret:
            - NOT_THERE
        processes:
          web:
            cmd: bin/rails server
            proxy: true
      YAML
    end
    refute @env.key?("NOT_THERE")
    assert_includes err, "NOT_THERE"
    assert_includes err, "not in config/local.secrets"
  end

  def test_an_export_satisfies_a_declared_secret
    ENV["IN_SHELL"] = "exported"
    env = env_for("web", yaml: <<~YAML)
      service: myapp
      env:
        secret:
          - IN_SHELL
      processes:
        web:
          cmd: bin/rails server
          proxy: true
    YAML
    assert_equal "exported", env["IN_SHELL"]
  ensure
    ENV.delete("IN_SHELL")
  end

  def test_spawned_process_actually_receives_the_config_env
    # The end of the chain, not just the function: a real spawn, read back
    # from the child's own environment. build_env returning the right hash
    # and the runner dropping it on the floor is exactly the bug being
    # fixed here.
    env = env_for("web", yaml: <<~YAML)
      service: myapp
      env:
        clear:
          PROOF_OF_ENV: delivered
      processes:
        web:
          cmd: bin/rails server
          proxy: true
    YAML

    store = Yamine::RouteStore.new(@dir)
    runner = Yamine::Runner.new(store: store, on_log: ->(_m) {})
    out_file = File.join(@dir, "env.txt")
    runner.boot_run(name: "web", hostname: "myapp.localhost",
      url: "https://myapp.localhost", dir: @dir,
      command: ["sh", "-c", "printenv PROOF_OF_ENV > #{out_file}"],
      port: 4001, register: false, extra_env: env)

    deadline = Time.now + 5
    sleep 0.05 until File.file?(out_file) || Time.now > deadline
    assert_equal "delivered", File.read(out_file).strip
  end

  def test_yamine_own_variables_win_over_a_stray_config_key
    # PORT and YAMINE_URL describe this boot; a config that sets them by
    # accident must not be able to steer the process off its route.
    store = Yamine::RouteStore.new(@dir)
    runner = Yamine::Runner.new(store: store, on_log: ->(_m) {})
    env = runner.send(:child_env, @dir, url: "https://myapp.localhost", port: 4001,
      extra_env: {"PORT" => "9999", "YAMINE_URL" => "https://wrong.localhost"})

    assert_equal "4001", env["PORT"]
    assert_equal "https://myapp.localhost", env["YAMINE_URL"]
  end
end
