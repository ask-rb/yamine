# frozen_string_literal: true

require_relative "test_helper"

# hosts sync runs as root over user-writable route names, so every
# name is strictly validated before anything is written: only
# well-formed hostnames, only inside the managed block, and only under
# an allowed dev TLD. An unvalidated sync is a domain-hijack primitive
# (a crafted route name could plant an entry for a real vendor domain
# or break out of the block with an embedded newline).
class HostsScopeTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "hosts")
    File.write(@path, "127.0.0.1 localhost\n")
    # Hermetic: redirect the privileged root into the tmpdir so the
    # suite never inherits the machine's staged allowlist — without
    # this, default_scope_tlds answers from /Library on staged machines
    # and the proxy.tlds fallback below is never exercised.
    @orig_privileged_root = ENV["YAMINE_PRIVILEGED_ROOT"]
    ENV["YAMINE_PRIVILEGED_ROOT"] = File.join(@dir, "privileged-root")
  end

  def teardown
    ENV["YAMINE_PRIVILEGED_ROOT"] = @orig_privileged_root
    FileUtils.remove_entry(@dir)
  end

  def test_localhost_names_sync_fine
    assert Yamine::Hosts.sync(["myapp.localhost"], @path, tlds: ["localhost"])
    assert Yamine::Hosts.synced?(["myapp.localhost"], @path)
  end

  def test_real_vendor_domain_is_refused
    err = assert_raises(Yamine::Error) do
      Yamine::Hosts.sync(["github.com"], @path, tlds: ["localhost"])
    end

    assert_match(/outside.*allowed|refusing/i, err.message)
    refute_includes File.read(@path), "github.com"
  end

  def test_newline_injection_is_refused
    evil = "myapp.localhost\n9.9.9.9 hijack.example"

    err = assert_raises(Yamine::Error) do
      Yamine::Hosts.sync([evil], @path, tlds: ["localhost"])
    end

    assert_match(/invalid hostname/i, err.message)
    refute_includes File.read(@path), "hijack"
  end

  def test_subdomain_of_vendor_domain_is_refused
    err = assert_raises(Yamine::Error) do
      Yamine::Hosts.sync(["evil.github.com"], @path, tlds: ["localhost"])
    end

    assert_match(/refusing/i, err.message)
  end

  def test_name_under_an_allowed_custom_tld_syncs
    assert Yamine::Hosts.sync(["myapp.preview.example.com"], @path,
      tlds: ["localhost", "preview.example.com"])
  end

  def test_proxy_host_style_name_needs_its_parent_domain_allowed
    assert_raises(Yamine::Error) do
      Yamine::Hosts.sync(["myapp.local.example.com"], @path, tlds: ["localhost"])
    end

    assert Yamine::Hosts.sync(["myapp.local.example.com"], @path,
      tlds: ["localhost", "local.example.com"])
  end

  def test_malformed_names_are_refused
    ["", "-bad.localhost", "bad-.localhost", "a" * 64 + ".localhost",
     "myapp..localhost", "my app.localhost"].each do |bad|
      assert_raises(Yamine::Error, "expected #{bad.inspect} to be refused") do
        Yamine::Hosts.sync([bad], @path, tlds: ["localhost"])
      end
    end
  end

  def test_sync_validates_even_when_the_block_already_matches
    # A block written before validation existed must not silently
    # survive: validation runs before the already-synced short-circuit.
    File.write(@path, "127.0.0.1 localhost\n#{Yamine::Hosts.managed_block(["github.com"])}")

    assert_raises(Yamine::Error) do
      Yamine::Hosts.sync(["github.com"], @path, tlds: ["localhost"])
    end
  end

  def test_sync_only_touches_the_managed_block
    File.write(@path, "127.0.0.1 localhost\n10.0.0.5 db.internal\n")
    Yamine::Hosts.sync(["myapp.localhost"], @path, tlds: ["localhost"])

    content = File.read(@path)
    assert_includes content, "10.0.0.5 db.internal"
    assert_includes content, "127.0.0.1 localhost"
    assert_includes content, "127.0.0.1 myapp.localhost"
  end

  def test_valid_hostname_predicate
    assert Yamine::Hosts.valid_hostname?("myapp.localhost")
    assert Yamine::Hosts.valid_hostname?("feature-login.myapp.localhost")
    assert Yamine::Hosts.valid_hostname?("localhost")
    refute Yamine::Hosts.valid_hostname?("github.com\n9.9.9.9 x")
    refute Yamine::Hosts.valid_hostname?("")
    refute Yamine::Hosts.valid_hostname?("-lead.localhost")
  end

  def test_default_scope_always_allows_localhost
    assert_includes Yamine::Hosts.default_scope_tlds(@dir), "localhost"
  end

  def test_default_scope_reads_served_tlds_from_state
    File.write(File.join(@dir, "proxy.tlds"), "preview.example.com\n")

    assert_includes Yamine::Hosts.default_scope_tlds(@dir), "preview.example.com"
  end

  def test_default_scope_prefers_the_root_owned_allowlist
    File.write(File.join(@dir, "proxy.tlds"), "stale.example.com\n")
    staged = Yamine::PrivilegedPayload.allowlist_file
    FileUtils.mkdir_p(File.dirname(staged))
    File.write(staged, "kept.example.com\n")

    tlds = Yamine::Hosts.default_scope_tlds(@dir)

    assert_includes tlds, "kept.example.com"
    assert_includes tlds, "localhost"
    refute_includes tlds, "stale.example.com"
  end
end
