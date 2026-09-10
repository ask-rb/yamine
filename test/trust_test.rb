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
    assert_equal "Yamine CA", Yamine::Certs::CA_COMMON_NAME
  end

  # Every CA name we have ever generated must stay prunable, or machines
  # that trusted a pre-rename CA can never shed it.
  def test_prunable_names_cover_current_and_legacy
    names = Yamine::Certs.ca_common_names

    assert_includes names, Yamine::Certs::CA_COMMON_NAME
    assert_includes names, "Ask Local CA",
      "the pre-rename name must stay prunable"
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

  # keychain_certs decides what may be deleted, so it must see ALL
  # certificates. The earlier version omitted `-a`, and `security
  # find-certificate` then returns a SINGLE certificate — so matching
  # silently failed for every entry but the first, and stale CAs were
  # never pruned.
  def test_keychain_scan_asks_for_all_certificates
    args_seen = nil
    status = Struct.new(:success?).new(false)
    Yamine::Command.expects(:capture2)
      .with { |*args| args_seen = args; true }
      .returns(["", status])

    Yamine::Trust.keychain_certs("/tmp/kc")

    assert_includes args_seen, "-a",
      "without -a only one certificate is returned and matching breaks"
  end

  # The live proxy's CA must survive pruning even though it is not the
  # CA on disk — a running proxy signs from the CA it booted with, and
  # superseded CAs share a name with it, so only a signature check can
  # tell them apart.
  def test_prune_spares_the_ca_a_live_proxy_signs_with
    dir = Dir.mktmpdir
    on_disk = Yamine::Certs.ensure_ca(Dir.mktmpdir)
    live_ca = Yamine::Certs.ensure_ca(Dir.mktmpdir)
    stale_ca = Yamine::Certs.ensure_ca(Dir.mktmpdir)
    leaf = mint_leaf(live_ca)

    entries = [on_disk, live_ca, stale_ca].map do |paths|
      { fingerprint: Yamine::Trust.fingerprint_of(paths[:cert]),
        subject: "/CN=#{Yamine::Certs::CA_COMMON_NAME}",
        cert: cert_of(paths[:cert]) }
    end
    deleted = []
    Yamine::Trust.stubs(:fingerprint_of).returns(entries[0][:fingerprint])
    Yamine::Trust.stubs(:keychain_certs).returns(entries)
    Yamine::Trust.stubs(:live_proxy_cert).returns(leaf)
    Yamine::Command.stubs(:capture2).returns(["", Struct.new(:success?).new(true)])
    Yamine::Command.stubs(:capture2)
      .with { |*args| args.include?("delete-certificate") && (deleted << args[3]; true) }
      .returns(["", Struct.new(:success?).new(true)])

    count = Yamine::Trust.prune_stale(dir, keychains: ["/tmp/kc"])

    assert_equal 1, count
    assert_equal [entries[2][:fingerprint]], deleted,
      "the on-disk CA and the live proxy's CA must both be spared"
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  # A certificate that signed nothing we can find is not protected by the
  # signature check — only the live proxy's issuer is.
  def test_signed_by_is_a_real_signature_check
    ca = Yamine::Certs.ensure_ca(Dir.mktmpdir)
    other = Yamine::Certs.ensure_ca(Dir.mktmpdir)
    leaf = mint_leaf(ca)

    assert Yamine::Trust.signed_by?(leaf, cert_of(ca[:cert])),
      "the issuing CA must match"
    refute Yamine::Trust.signed_by?(leaf, cert_of(other[:cert])),
      "an unrelated CA must not be mistaken for the issuer"
  end

  def cert_of(path)
    OpenSSL::X509::Certificate.new(File.read(path))
  end

  def mint_leaf(ca_paths)
    Yamine::Certs.mint_host("probe.localhost", cert_of(ca_paths[:cert]),
      OpenSSL::PKey.read(File.read(ca_paths[:key]))).first
  end
end

# The service identity was an ask-local leftover ("dev.ask.local"), and a
# label is how launchctl addresses a service — so installing the renamed
# service while the old plist is still loaded would leave TWO root
# proxies fighting over port 443, the loser crash-looping under
# KeepAlive.
class ServiceLabelTest < Minitest::Test
  def test_label_is_renamed
    assert_equal "dev.yamine", Yamine::CLI::SystemCommand::LAUNCHD_LABEL
  end

  def test_legacy_label_is_cleared
    assert_includes Yamine::CLI::SystemCommand::LEGACY_LAUNCHD_LABELS, "dev.ask.local",
      "the pre-rename service must be booted out, or both proxies fight over 443"
  end

  def test_install_uses_the_label_constant_not_a_literal
    source = File.read(File.join(__dir__, "..", "lib", "yamine", "cli", "system.rb"))
    install = source[/def install_launchd(.*?)^      end/m, 1]

    assert_includes install, "LAUNCHD_LABEL"
    refute_match(/dev\.ask\.local/, install,
      "install must not hardcode the legacy label")
  end

  def test_remove_legacy_launchd_is_called_on_install_and_uninstall
    source = File.read(File.join(__dir__, "..", "lib", "yamine", "cli", "system.rb"))
    install = source[/def install_launchd(.*?)^      end/m, 1]
    uninstall = source[/def service_uninstall(.*?)^      end/m, 1]

    assert_includes install, "remove_legacy_launchd"
    assert_includes uninstall, "remove_legacy_launchd"
  end
end
