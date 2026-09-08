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
    Ask::Local::Hosts.sync(["myapp.localhost"], @path)

    assert Ask::Local::Hosts.synced?(["myapp.localhost"], @path)
  end

  def test_synced_false_when_block_missing
    refute Ask::Local::Hosts.synced?(["myapp.localhost"], @path)
  end

  def test_synced_false_when_block_has_different_hosts
    Ask::Local::Hosts.sync(["other.localhost"], @path)

    refute Ask::Local::Hosts.synced?(["myapp.localhost"], @path)
  end

  def test_synced_unaffected_by_unmanaged_lines
    File.write(@path, "127.0.0.1 localhost\n")
    Ask::Local::Hosts.sync(["myapp.localhost"], @path)

    assert Ask::Local::Hosts.synced?(["myapp.localhost"], @path)
  end
end
