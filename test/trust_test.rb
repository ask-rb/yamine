# frozen_string_literal: true

require_relative "test_helper"

# untrust on macOS/Windows must not raise NameError: the CA common name
# lives in Yamine::Certs, and removal has to reach it (regression:
# bare CA_COMMON_NAME raised NameError, so `yamine clean` crashed
# mid-untrust).
#
# These tests are deliberately hermetic: no `security`/`certutil`
# subprocesses, no real keychain access. Shelling out in unit tests is
# non-hermetic — it can prompt, mutate the developer's real keychain, and
# fail in CI. The regression is a constant-resolution bug, so it is pinned
# by resolving the constant through the code path and asserting the source
# references the qualified name.
class TrustTest < Minitest::Test
  def test_ca_common_name_is_reachable_from_trust_source
    source = File.read(File.join(__dir__, "..", "lib", "yamine", "trust.rb"))

    assert_includes source, "Certs::CA_COMMON_NAME",
      "Trust.untrust must reference the CA common name through Certs (bare CA_COMMON_NAME raises NameError)"
  end

  def test_ca_common_name_constant_resolves
    assert_equal "Ask Local CA", Yamine::Certs::CA_COMMON_NAME
  end

  # The name is kept from the ask-local era on purpose: valid_pair? keys
  # off it, so changing it would invalidate every existing CA and force a
  # regeneration + re-trust on every machine. Cleanup no longer depends on
  # the name (it uses fingerprints), which is what made the name a problem
  # in the first place.
  def test_renaming_the_ca_would_force_a_regeneration
    dir = Dir.mktmpdir
    paths = Yamine::Certs.ensure_ca(dir)
    cert = OpenSSL::X509::Certificate.new(File.read(paths[:cert]))

    assert cert.subject.to_s.include?(Yamine::Certs::CA_COMMON_NAME),
      "the on-disk CA must carry CA_COMMON_NAME or valid_pair? regenerates it"
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  # The prunable-names list exists so a future rename can still shed old
  # certificates; it must always cover the name currently in use.
  def test_prunable_names_cover_the_current_name
    assert_includes Yamine::Certs.ca_common_names, Yamine::Certs::CA_COMMON_NAME
  end

  # Deleting by common name removes an ARBITRARY certificate with that
  # name — with 14 of them, possibly the current CA. Removal must be by
  # fingerprint.
  def test_untrust_does_not_delete_by_common_name
    source = File.read(File.join(__dir__, "..", "lib", "yamine", "trust.rb"))
    untrust_body = source[/def untrust.*?\n    end/m]

    refute_match(/"delete-certificate", "-c"/, untrust_body,
      "untrust must delete by fingerprint (-Z), never by common name (-c)")
    assert_match(/"-Z"/, untrust_body, "untrust should delete by fingerprint")
  end

  def test_fingerprint_is_uppercase_hex_without_colons
    dir = Dir.mktmpdir
    paths = Yamine::Certs.ensure_ca(dir)
    fp = Yamine::Trust.fingerprint_of(paths[:cert])
    assert_match(/\A[0-9A-F]{40}\z/, fp,
      "must match the format `security -Z` prints, or lookups never match")
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  def test_untrust_guards_unknown_platform_without_touching_keychain
    # platform :unknown short-circuits before any subprocess; proving the
    # method is safe to call and returns a structured result, not a raise.
    Yamine::Trust.stubs(:platform).returns(:unknown)

    result = Yamine::Trust.untrust(Dir.mktmpdir)

    assert result.is_a?(Hash), "untrust must return a result hash on unsupported platforms"
    refute_includes result[:error].to_s, "NameError"
  ensure
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # our_cert? decides whether a certificate may be deleted, so it must
  # actually find the certificate among ALL of them. It once omitted `-a`,
  # and `security find-certificate` then returns a SINGLE certificate —
  # so the subject check silently answered "not ours" for every one but
  # the first, and stale CAs were never pruned.
  def test_our_cert_asks_for_all_certificates
    args_seen = nil
    status = Struct.new(:success?).new(false)
    Yamine::Command.expects(:capture2)
      .with { |*args| args_seen = args; true }
      .returns(["", status])

    Yamine::Trust.our_cert?("/tmp/kc", "ABC", ["Yamine CA"])

    assert_includes args_seen, "-a",
      "without -a only one certificate is returned and matching breaks"
  end

  # Pruning must never run while a proxy is serving: the live proxy holds
  # the CA it booted with in memory, so removing that certificate would
  # break TLS for every live route.
  def test_prune_is_skipped_while_a_proxy_serves
    Yamine::Trust.stubs(:serving_proxy?).returns(true)
    Yamine::Command.expects(:capture2).never

    assert_equal 0, Yamine::Trust.prune_stale
  end
end
