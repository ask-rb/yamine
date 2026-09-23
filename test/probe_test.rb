# frozen_string_literal: true

require_relative "test_helper"

# The probe asks the app what it has. Its contract: one marker line
# amidst boot noise, nil on any failure (a probe is an enhancement,
# never a boot-killer), and a child environment scrubbed of DATABASE_URL
# so the caller's own variables cannot win over database.yml inside
# the resolver.
class ProbeTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_dburl = ENV.delete("DATABASE_URL")
  end

  def teardown
    ENV["DATABASE_URL"] = @orig_dburl if @orig_dburl
    FileUtils.remove_entry(@dir)
  end

  def write_fake_rails(body)
    bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(bin)
    path = File.join(bin, "rails")
    File.write(path, "#!/bin/sh\n#{body}")
    File.chmod(0o755, path)
  end

  def test_parse_finds_marker_line_amidst_boot_noise
    rows = Yamine::Probe.parse(<<~OUT)
      => Loading development environment
      YAMINE_DBS=[{"name":"primary","database":"app_dev","url":"postgres://u@h/app_dev"}]
      some trailing warning
    OUT
    assert_equal 1, rows.size
    assert_equal "app_dev", rows.first["database"]
  end

  def test_parse_returns_nil_on_garbage_or_absence
    assert_nil Yamine::Probe.parse("nothing here")
    assert_nil Yamine::Probe.parse("YAMINE_DBS=not json")
    assert_nil Yamine::Probe.parse('YAMINE_DBS={"name":"primary"}')
    assert_nil Yamine::Probe.parse('YAMINE_DBS=[]')
    assert_nil Yamine::Probe.parse(nil)
    assert_nil Yamine::Probe.parse('YAMINE_DBS=[{"name":"x"}]')
  end

  def test_server_backed_filters_local_adapters
    rows = [
      { "name" => "primary", "database" => "a", "url" => "postgres://u@h/a" },
      { "name" => "cache", "database" => "b", "url" => "mysql2://u@h/b" },
      { "name" => "aux", "database" => "c.sqlite3", "url" => "sqlite3:c.sqlite3" }
    ]
    assert_equal %w[primary cache], Yamine::Probe.server_backed(rows).map { |r| r["name"] }
  end

  def test_rails_databases_reads_the_fake_app
    write_fake_rails(<<~SH)
      [ "$1" = "runner" ] || exit 0
      echo "boot noise first"
      if [ -f .yamine-db-suffix ]; then
        S=$(cat .yamine-db-suffix)
        printf '%s\\n' "YAMINE_DBS=[{\\"name\\":\\"primary\\",\\"database\\":\\"app_dev_$S\\",\\"url\\":\\"postgres://u@h/app_dev_$S\\"}]"
      else
        printf '%s\\n' 'YAMINE_DBS=[{"name":"primary","database":"app_dev","url":"postgres://u@h/app_dev"}]'
      fi
    SH
    rows = Yamine::Probe.rails_databases(@dir)
    assert_equal "app_dev", rows.first["database"]

    Yamine::Database.write_marker(@dir, "wt")
    rows = Yamine::Probe.rails_databases(@dir)
    assert_equal "app_dev_wt", rows.first["database"],
      "a conforming app resolves suffixed once the marker exists"
  end

  def test_rails_databases_returns_nil_when_the_app_fails
    write_fake_rails('echo "boom" >&2; exit 1')
    assert_nil Yamine::Probe.rails_databases(@dir)
  end

  def test_rails_databases_returns_nil_without_bin_rails
    assert_nil Yamine::Probe.rails_databases(@dir)
  end

  def test_caller_database_url_never_leaks_into_the_probe
    # A stray DATABASE_URL in yamine's own environment would win over
    # database.yml inside Rails' resolver — the probe must see the
    # app's configuration, not the caller's leftovers.
    ENV["DATABASE_URL"] = "postgres://evil@h/poisoned"
    write_fake_rails(<<~SH)
      [ "$1" = "runner" ] || exit 0
      V=${DATABASE_URL:-unset}
      printf '%s\\n' "YAMINE_DBS=[{\\"name\\":\\"primary\\",\\"database\\":\\"d\\",\\"url\\":\\"$V\\"}]"
    SH
    rows = Yamine::Probe.rails_databases(@dir)
    assert_equal "unset", rows.first["url"]
  end
end
