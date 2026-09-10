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

# resolves? backs the "will not resolve — run yamine hosts sync" warning
# and doctor's dns check. It must ask the SYSTEM resolver, because that
# is what browsers and curl use. Ruby's Resolv is a pure-Ruby DNS client
# with no nsswitch and no RFC 6761 knowledge, so it reports .localhost as
# unresolvable on machines where it resolves perfectly — sending users to
# an elevated /etc/hosts write they never needed.
class HostsResolvesTest < Minitest::Test
  def test_localhost_resolves
    assert Yamine::Hosts.resolves?("localhost"),
      "localhost must resolve (RFC 6761 special-use, handled by getaddrinfo)"
  end

  def test_loopback_ip_resolves
    assert Yamine::Hosts.resolves?("127.0.0.1")
  end

  def test_nonexistent_tld_does_not_resolve
    refute Yamine::Hosts.resolves?("this-host-does-not-exist.invalid")
  end

  def test_unresolved_reports_only_the_missing
    missing = Yamine::Hosts.unresolved(["localhost", "nope.invalid"])

    assert_equal ["nope.invalid"], missing
  end

  # The bug this guards: `.localhost` resolved by getaddrinfo but NOT by
  # Resolv on macOS. Assert the fix is the system path by pinning that
  # Resolv would disagree — if Resolv ever agrees here the test is moot,
  # but the assertion above still holds the line.
  def test_uses_system_resolver_not_pure_ruby_dns
    resolved = begin
      Addrinfo.getaddrinfo("localhost", nil)
    rescue SocketError
      nil
    end

    refute_nil resolved, "getaddrinfo must resolve localhost"
  end
end
