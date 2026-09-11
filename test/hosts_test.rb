# frozen_string_literal: true

require_relative "test_helper"

# Hosts.synced? backs the setup hosts step: the root service install
# syncs /etc/hosts under elevation, and a plain re-run of setup must
# detect the block is already in place instead of failing to rewrite
# /etc/hosts unprivileged. Tests use a temp file, never /etc/hosts.
class HostsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "hosts")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_synced_true_when_managed_block_present
    Yamine::Hosts.sync(["myapp.localhost"], @path)

    assert Yamine::Hosts.synced?(["myapp.localhost"], @path)
  end

  def test_synced_false_when_block_missing
    refute Yamine::Hosts.synced?(["myapp.localhost"], @path)
  end

  def test_synced_false_when_block_has_different_hosts
    Yamine::Hosts.sync(["other.localhost"], @path)

    refute Yamine::Hosts.synced?(["myapp.localhost"], @path)
  end

  def test_synced_unaffected_by_unmanaged_lines
    File.write(@path, "127.0.0.1 localhost\n")
    Yamine::Hosts.sync(["myapp.localhost"], @path)

    assert Yamine::Hosts.synced?(["myapp.localhost"], @path)
  end

  # sync must be a no-op when the block already matches. /etc/hosts is
  # root-owned, so an unconditional rewrite fails without sudo — and both
  # `setup` and every boot's workstation check call this. Without the
  # guard, a machine whose hosts file was already correct got
  # "could not write /etc/hosts (try sudo yamine hosts sync)" on every
  # run, pointing at an elevated write for a file that needed nothing.
  def test_sync_is_noop_when_already_synced
    Yamine::Hosts.sync(["myapp.localhost"], @path)
    before = File.read(@path)
    mtime = File.mtime(@path)

    assert Yamine::Hosts.sync(["myapp.localhost"], @path),
      "an already-synced file must report success, not a failed rewrite"

    assert_equal before, File.read(@path)
    assert_equal mtime, File.mtime(@path), "the file must not be rewritten"
  end

  # The real-world shape: a root-owned file the process cannot write. If
  # the block already matches, sync must succeed anyway.
  def test_sync_succeeds_on_unwritable_file_when_already_correct
    Yamine::Hosts.sync(["myapp.localhost"], @path)
    File.chmod(0o444, @path)

    assert Yamine::Hosts.sync(["myapp.localhost"], @path),
      "a correct but unwritable /etc/hosts is not an error"
  ensure
    File.chmod(0o644, @path)
  end

  # ...and it still reports the failure when a rewrite IS needed.
  def test_sync_fails_on_unwritable_file_when_change_needed
    File.write(@path, "127.0.0.1 localhost\n")
    File.chmod(0o444, @path)

    refute Yamine::Hosts.sync(["myapp.localhost"], @path),
      "a needed rewrite that cannot happen must be reported"
  ensure
    File.chmod(0o644, @path)
  end

  def test_sync_still_updates_when_hostnames_change
    Yamine::Hosts.sync(["old.localhost"], @path)
    Yamine::Hosts.sync(["new.localhost"], @path)

    assert Yamine::Hosts.synced?(["new.localhost"], @path)
    refute_includes File.read(@path), "old.localhost"
  end
end

# classification/resolution back doctor's dns check and boot's DNS
# warning. The oracle is the hosts FILE, not a resolver probe: it is the
# one source every client shares. getaddrinfo is consulted only for
# custom-TLD names the file does not answer, and never for .localhost —
# on macOS the system resolver answers any .localhost unconditionally,
# so probing it reported every .localhost route as fully resolved while
# a CGO-disabled Go binary (file-only resolver) could not see any of
# them. That false "resolves" is the bug this class guards against
# returning.
class HostsResolutionTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "hosts")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_hosts(content)
    File.write(@path, content)
  end

  def test_entry_in_the_managed_block_counts
    write_hosts("# --- yamine begin ---\n127.0.0.1 myapp.localhost\n# --- yamine end ---\n")

    assert Yamine::Hosts.hosts_entry?("myapp.localhost", @path)
  end

  # A hand-added entry resolves the name for file-only clients just as
  # well as a synced one; the check must not demand yamine's block.
  def test_hand_added_entry_outside_the_block_counts
    write_hosts("127.0.0.1 myapp.localhost\n")

    assert Yamine::Hosts.hosts_entry?("myapp.localhost", @path)
  end

  def test_ipv6_loopback_mapping_counts
    write_hosts("::1 myapp.localhost\n")

    assert Yamine::Hosts.hosts_entry?("myapp.localhost", @path)
  end

  def test_comments_tabs_and_case_are_ignored
    write_hosts("# Host Database\n127.0.0.1\tMyApp.Localhost # inline comment\n")

    assert Yamine::Hosts.hosts_entry?("myapp.localhost", @path)
  end

  # The proxy serves on loopback; a mapping elsewhere points the name
  # away from yamine and must not read as "resolves to the proxy".
  def test_non_loopback_mapping_does_not_count
    write_hosts("10.0.0.5 myapp.localhost\n")

    refute Yamine::Hosts.hosts_entry?("myapp.localhost", @path)
  end

  def test_missing_file_has_no_entries
    refute Yamine::Hosts.hosts_entry?("myapp.localhost", File.join(@dir, "nope"))
  end

  def test_entry_in_the_file_is_ok
    write_hosts("127.0.0.1 myapp.test\n")

    assert_equal :ok, Yamine::Hosts.classification("myapp.test", @path)
  end

  # The load-bearing no-probe: classification must not ask getaddrinfo
  # about .localhost, because its unconditional yes is exactly the false
  # "resolves" that hid this gap from doctor and boot.
  def test_localhost_without_entry_is_warn_without_a_probe
    Addrinfo.expects(:getaddrinfo).never

    assert_equal :warn, Yamine::Hosts.classification("myapp.localhost", @path)
  end

  # .invalid cannot resolve anywhere; the probe confirms the name is
  # truly dead rather than served by real DNS.
  def test_custom_tld_missing_everywhere_is_fail
    write_hosts("")

    assert_equal :fail, Yamine::Hosts.classification("this-host-does-not-exist.invalid", @path)
  end

  # A custom TLD served by real DNS or /etc/resolver resolves for every
  # client without a hosts entry — ok, not a sync candidate.
  def test_custom_tld_resolved_by_dns_is_ok
    write_hosts("")
    Addrinfo.stubs(:getaddrinfo).returns([:addr])

    assert_equal :ok, Yamine::Hosts.classification("myapp.test", @path)
  end

  def test_resolution_partitions_by_class
    write_hosts("127.0.0.1 synced.test\n")

    groups = Yamine::Hosts.resolution(
      ["synced.test", "native.localhost", "gone.invalid"], @path)

    assert_equal ["synced.test"], groups[:ok]
    assert_equal ["native.localhost"], groups[:warn]
    assert_equal ["gone.invalid"], groups[:fail]
  end
end
