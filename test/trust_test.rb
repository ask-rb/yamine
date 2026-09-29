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

# A CA in the keychain is not a CA macOS trusts, and neither is one the
# trust store holds with no trust SETTING — that bare entry is exactly
# what `add-trusted-cert -r trustRoot` leaves behind without `-p`
# (`security dump-trust-settings` counts it as zero settings). A check
# that compared fingerprints alone therefore reported the broken state
# as "trusted" on every later boot, and the machine stayed broken across
# a proxy restart and a gem upgrade.
#
# Hermetic: the trust store is stubbed, never exported from the real one.
class MacosCaTrustTest < Minitest::Test
  KEYCHAIN = "/tmp/yamine-test.keychain-db"

  def setup
    @dir = Dir.mktmpdir
    @ca = Yamine::Certs.ensure_ca(@dir)
    @fp = Yamine::Trust.fingerprint_of(@ca[:cert])
    Yamine::Trust.stubs(:login_keychain).returns(KEYCHAIN)
    Process.stubs(:uid).returns(501)
  end

  def teardown
    FileUtils.remove_entry(@dir) rescue nil
  end

  # THE REGRESSION. The CA is in the keychain and the trust store holds a
  # bare entry for it — the state this bug left behind on a real machine.
  def test_present_but_untrusted_ca_is_not_trusted
    stub_keychain(@fp)
    stub_trust_store(@fp => "")

    refute Yamine::Trust.already_trusted?(@ca[:cert], KEYCHAIN),
      "a CA the trust store records no trust setting for is not trusted"
  end

  # A CA that is not in any keychain cannot be used either: macOS builds
  # the chain by searching keychains for the issuer. Measured on the
  # machine this bug was found on, whose CA had a trust-list entry and
  # no keychain copy at all: "unable to get local issuer certificate".
  def test_trusted_but_absent_from_the_keychain_is_not_trusted
    Yamine::Trust.stubs(:keychain_fingerprints).returns([])
    stub_trust_store(@fp => ssl_policies)

    refute Yamine::Trust.already_trusted?(@ca[:cert], KEYCHAIN),
      "a trust setting for a certificate no keychain holds cannot anchor a chain"
  end

  def test_ca_with_a_recorded_trust_setting_is_trusted
    stub_keychain(@fp)
    stub_trust_store(@fp => ssl_policies)

    assert Yamine::Trust.already_trusted?(@ca[:cert], KEYCHAIN),
      "sslServer + basicX509 settings mean macOS treats this as a root"
  end

  # -r deny records kSecTrustSettingsResult 3 and no policies: the user
  # asked for exactly the state we are repairing.
  def test_explicitly_distrusted_ca_is_not_trusted
    stub_keychain(@fp)
    stub_trust_store(@fp => deny_result)

    refute Yamine::Trust.already_trusted?(@ca[:cert], KEYCHAIN)
  end

  # A trust store that cannot be read must not turn every boot into a
  # re-add: a re-add in the user domain can raise a GUI authorization
  # prompt, which is worse than the bug being fixed.
  def test_unreadable_trust_store_does_not_look_untrusted
    stub_keychain(@fp)
    Yamine::Trust.stubs(:trust_settings).returns(nil)

    assert Yamine::Trust.already_trusted?(@ca[:cert], KEYCHAIN),
      "cannot read the trust store => leave it alone, do not re-add every boot"
  end

  # The non-admin invocation. Without the policies the trust store
  # records nothing usable, which is the whole bug.
  def test_non_admin_add_names_the_trust_policies
    seen = []
    record_add(seen)
    Yamine::Trust.stubs(:already_trusted?).returns(false, true)

    Yamine::Trust.trust_macos(@ca[:cert])

    assert_equal ["security", "add-trusted-cert", "-r", "trustRoot", "-p", "ssl",
      "-p", "basic", "-k", KEYCHAIN, @ca[:cert]], seen,
      "a user-domain add must name the SSL and basic policies, and must not use -d"
  end

  def test_admin_add_keeps_the_admin_domain
    Process.stubs(:uid).returns(0)
    seen = []
    record_add(seen)
    Yamine::Trust.stubs(:already_trusted?).returns(false, true)

    Yamine::Trust.trust_macos(@ca[:cert])

    assert_includes seen, "-d", "an elevated add must stay in the admin domain"
    assert_includes seen, "/Library/Keychains/System.keychain"
    assert_includes seen, "-p", "the elevated add must name its policies too"
  end

  # The state this bug was found in: the certificate is already in the
  # keychain, untrusted. The old code returned early on the fingerprint
  # match and never recorded a trust setting at all.
  def test_already_present_but_untrusted_ca_gets_the_corrective_add
    stub_keychain(@fp)
    # What the corrective add does to the store: the bare entry gains the
    # policies. The second read (after the add) sees that.
    Yamine::Trust.stubs(:trust_settings)
      .returns(exported(@fp => ""), exported(@fp => ssl_policies))
    seen = []
    record_add(seen)

    Yamine::Trust.trust_macos(@ca[:cert])

    refute_empty seen, "an untrusted CA that is already in the keychain must still be re-added"
    assert_includes seen, "-p"
  end

  # A trusted CA must not be re-added: adding a certificate twice is how
  # the trust store filled up with duplicates.
  def test_trusted_ca_is_not_re_added
    stub_keychain(@fp)
    stub_trust_store(@fp => ssl_policies)
    seen = []
    record_add(seen)

    Yamine::Trust.trust_macos(@ca[:cert])

    assert_empty seen, "an already-trusted CA must not be added again"
  end

  # `security add-trusted-cert` exits 0 for a certificate it merely
  # filed. Believing that exit code is what wrote a success marker for a
  # CA no browser would accept, so the trust store is re-read and a
  # failure names the command the user has to run.
  def test_add_that_records_no_trust_setting_is_reported
    stub_keychain(@fp)
    stub_trust_store(@fp => "")
    Yamine::Command.stubs(:capture2).returns(["", ok_status])

    error = assert_raises(Yamine::CertError) { Yamine::Trust.trust_macos(@ca[:cert]) }

    assert_includes error.message, "security add-trusted-cert",
      "the failure must name the command that fixes it"
    assert_includes error.message, "-p ssl", "and the policies that make it work"
  end

  # The state-dir marker says "we trusted this", not "macOS trusts
  # this". Trusting the marker alone is how the broken state was cached
  # and never repaired.
  def test_marker_alone_does_not_make_the_ca_trusted
    Yamine::Certs.mark_trusted(@dir)
    stub_keychain(@fp)
    stub_trust_store(@fp => "")

    refute Yamine::Trust.trusted?(@dir),
      "a marker over an untrusted CA must not short-circuit a re-trust"
  end

  def test_marker_plus_a_trust_setting_is_trusted
    Yamine::Certs.mark_trusted(@dir)
    stub_keychain(@fp)
    stub_trust_store(@fp => ssl_policies)

    assert Yamine::Trust.trusted?(@dir)
  end

  # A CA trusted into the System keychain by an elevated install is
  # trusted for the unprivileged proxy that serves it, so the check has
  # to look at both keychains rather than only the caller's.
  def test_trusted_in_the_system_keychain_counts
    Yamine::Certs.mark_trusted(@dir)
    system = "/Library/Keychains/System.keychain"
    Yamine::Trust.stubs(:keychain_fingerprints).with(KEYCHAIN, common_name: nil).returns([])
    Yamine::Trust.stubs(:keychain_fingerprints).with(system, common_name: nil).returns([@fp])
    Yamine::Trust.stubs(:trust_settings).with(KEYCHAIN).returns(exported({}))
    Yamine::Trust.stubs(:trust_settings).with(system).returns(exported(@fp => ssl_policies))

    assert Yamine::Trust.trusted?(@dir)
  end

  # The admin domain is a different store: reading only the user's own
  # settings would leave a root install looking untrusted forever.
  def test_system_keychain_is_read_from_the_admin_domain
    seen = []
    Yamine::Command.stubs(:capture2)
      .with { |*args| seen.replace(args) if args[1] == "trust-settings-export"; true }
      .returns(["", ok_status])

    Yamine::Trust.trust_settings("/Library/Keychains/System.keychain")

    assert_equal "trust-settings-export", seen[1]
    assert_includes seen, "-d", "the System keychain's settings live in the admin domain"
  end

  private

  def ok_status
    Struct.new(:success?).new(true)
  end

  # The certificate is in the keychain: `find-certificate` finds it.
  def stub_keychain(fingerprints)
    Yamine::Trust.stubs(:keychain_fingerprints).returns(fingerprints)
  end

  # The trust store, as `security trust-settings-export` writes it: keyed
  # by SHA-1 fingerprint, each entry holding only what the OS recorded.
  def stub_trust_store(entries)
    Yamine::Trust.stubs(:trust_settings).returns(exported(entries))
  end

  def record_add(seen)
    Yamine::Command.stubs(:capture2)
      .with { |*args| seen.replace(args) if args[1] == "add-trusted-cert"; true }
      .returns(["", ok_status])
  end

  def exported(entries)
    body = entries.map do |fp, settings|
      "\t<key>#{fp}</key>\n\t<dict>\n\t\t<key>issuerName</key>\n\t\t<data>MBQxEjAQBgNVBAMMCVlhbWluZSBDQQ==\n\t\t</data>\n" \
        "#{settings}\t</dict>\n"
    end.join
    %(<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n) \
      "\t<key>trustList</key>\n\t<dict>\n#{body}\t</dict>\n</dict>\n</plist>\n"
  end

  # What `-p ssl -p basic` records: policy OIDs, no explicit result, which
  # SecTrustSettings.h defines as kSecTrustSettingsResultTrustRoot.
  def ssl_policies
    "\t\t<key>trustSettings</key>\n\t\t<array>\n" \
      "\t\t\t<dict>\n\t\t\t\t<key>kSecTrustSettingsPolicy</key>\n\t\t\t\t<data>KgYIhnY2QAE=</data>\n" \
      "\t\t\t\t<key>kSecTrustSettingsPolicyName</key>\n\t\t\t\t<string>sslServer</string>\n\t\t\t</dict>\n" \
      "\t\t\t<dict>\n\t\t\t\t<key>kSecTrustSettingsPolicy</key>\n\t\t\t\t<data>KgYIhnY2QAg==</data>\n" \
      "\t\t\t\t<key>kSecTrustSettingsPolicyName</key>\n\t\t\t\t<string>basicX509</string>\n\t\t\t</dict>\n" \
      "\t\t</array>\n"
  end

  def deny_result
    "\t\t<key>trustSettings</key>\n\t\t<array>\n\t\t\t<dict>\n" \
      "\t\t\t\t<key>kSecTrustSettingsResult</key>\n\t\t\t\t<integer>3</integer>\n" \
      "\t\t\t</dict>\n\t\t</array>\n"
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
    uninstall = source[/def uninstall_launchd(.*?)^      end/m, 1]

    assert_includes install, "remove_legacy_launchd"
    assert_includes uninstall, "remove_legacy_launchd"
  end
end

# A proxy regenerates the CA at boot (Certs#load_ca -> ensure_ca) when the
# on-disk one is missing, expiring, or renamed, and the trust marker is a
# fingerprint of whatever was trusted. So deciding "already trusted" from
# the marker WITHOUT first bringing the CA up to date reads a stale match:
# trust is skipped, the proxy then boots with a CA the keychain does not
# know, and TLS verification fails for every route.
class CaFreshnessOrderingTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig
    FileUtils.remove_entry(@dir) rescue nil
  end

  # The regression: a CA whose subject no longer matches CA_COMMON_NAME
  # (the post-rename state) with a marker that matches it must NOT be
  # reported as trusted — the CA has to be replaced first.
  def test_stale_named_ca_is_not_reported_trusted
    dir = Dir.mktmpdir
    Yamine::Certs.ensure_ca(dir)
    # Rewrite the cert under an old name but leave the marker matching it,
    # exactly as a machine upgraded across a rename looks.
    paths = Yamine::Certs.ca_paths(dir)
    key = OpenSSL::PKey::EC.generate("prime256v1")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = OpenSSL::BN.rand(128, 0)
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=Ask Local CA")
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 86_400
    cert.public_key = key
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = cert
    cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
    cert.sign(key, "SHA256")
    File.write(paths[:cert], cert.to_pem)
    File.write(paths[:key], key.to_pem)
    Yamine::Certs.mark_trusted(dir)

    assert Yamine::Certs.trusted?(dir),
      "precondition: the marker matches the stale certificate"

    refute Yamine::CLI::SystemCommand.ca_current_and_trusted?(dir),
      "a CA under the old name must be replaced and re-trusted, not skipped"
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  def test_current_ca_reports_trusted_without_extra_work
    Yamine::Certs.ensure_ca(@dir)
    Yamine::Certs.mark_trusted(@dir)
    # ca_current_and_trusted? asks the OS as well as the marker now, and
    # a test CA is in no trust store. Stubbed so the suite stays hermetic;
    # the marker and the fresh-CA half of the check are still the ones
    # under test here (see MacosCaTrustTest for the OS half).
    Yamine::Trust.stubs(:already_trusted?).returns(true)

    assert Yamine::CLI::SystemCommand.ca_current_and_trusted?(@dir)
  end

  # Both trust paths must go through the fresh-CA check.
  def test_both_trust_paths_use_the_freshness_check
    source = File.read(File.join(__dir__, "..", "lib", "yamine", "cli", "system.rb"))

    %w[ensure_workstation! ensure_system_ca_trust].each do |method|
      body = method_body(source, method)

      refute_nil body, "could not locate #{method} in system.rb"
      assert_includes body, "ca_current_and_trusted?",
        "#{method} must not decide trust from a possibly-stale marker"
    end
  end

  # The method's text, from its `def` up to the next `def` at the same
  # indentation. Simpler and sturdier than matching the closing `end`,
  # since these methods close at varying depths.
  def method_body(source, name)
    start = source.index("def #{name}")
    return nil unless start

    rest = source[(start + 1)..]
    following = rest&.match(/^      def /)
    following ? source[start, following.begin(0) + 1] : source[start..]
  end
end

# Pruning only happens when `trust` runs, so a CA left trusted by the
# rename (or any regeneration) would otherwise wait for the next
# missing-CA event — possibly forever. doctor surfaces it with the one
# command that clears it.
class StaleCaReportingTest < Minitest::Test
  def test_counts_trusted_cas_that_are_not_the_current_one
    current = Struct.new(:fingerprint, :subject).new("CURRENT", "/CN=Yamine CA")
    stale = Struct.new(:fingerprint, :subject).new("STALE", "/CN=Ask Local CA")
    Yamine::Trust.stubs(:fingerprint_of).returns("CURRENT")
    Yamine::Trust.stubs(:keychains).returns(["/tmp/kc"])
    Yamine::Trust.stubs(:keychain_certs).returns([current, stale])

    assert_equal 1, Yamine::Doctor.stale_ca_count
  end

  def test_ignores_unrelated_trusted_roots
    other = Struct.new(:fingerprint, :subject).new("OTHER", "/CN=Some Corp Root CA")
    Yamine::Trust.stubs(:fingerprint_of).returns("CURRENT")
    Yamine::Trust.stubs(:keychains).returns(["/tmp/kc"])
    Yamine::Trust.stubs(:keychain_certs).returns([other])

    assert_equal 0, Yamine::Doctor.stale_ca_count,
      "a CA that is not ours must never be counted or reported"
  end

  def test_is_silent_when_the_keychain_cannot_be_read
    Yamine::Trust.stubs(:fingerprint_of).returns("CURRENT")
    Yamine::Trust.stubs(:keychains).returns(["/tmp/kc"])
    Yamine::Trust.stubs(:keychain_certs).raises(StandardError, "nope")

    assert_equal 0, Yamine::Doctor.stale_ca_count,
      "doctor is read-only and must not fail on an unreadable keychain"
  end

  def test_warns_through_the_ca_check_when_stale_cas_exist
    dir = Dir.mktmpdir
    Yamine::Certs.ensure_ca(dir)
    Yamine::Certs.mark_trusted(dir)
    # check_ca reads the ambient state dir, not the CA we just built, so
    # pin it to this test's own. Left ambient, the test only passes where
    # the developer's real ~/.yamine already holds a trusted CA; anywhere
    # else (CI, a fresh container) check_ca short-circuits to "no CA yet"
    # and the stale-CA warning under test never runs.
    Yamine::Certs.stubs(:state_dir).returns(dir)
    Yamine::Doctor.stubs(:stale_ca_count).returns(2)
    # check_ca now asks the OS trust store as well as the marker, and a
    # test CA is in no trust store. Stubbed to keep the suite hermetic;
    # this test is about the stale-CA warning, which is what it asserts.
    Yamine::Trust.stubs(:already_trusted?).returns(true)

    check = Yamine::Doctor.check_ca

    assert check.warn?
    assert_match(/2 superseded CA\(s\) are still trusted/, check.message)
    assert_match(/yamine trust/, check.message, "must name the command that clears it")
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  # Doctor reported "CA trusted" off the state-dir marker while macOS
  # held no trust setting for the CA every browser was being asked to
  # accept. The marker records what WE did, not what the OS recorded.
  def test_reports_a_ca_the_marker_calls_trusted_but_macos_does_not
    dir = Dir.mktmpdir
    Yamine::Certs.ensure_ca(dir)
    Yamine::Certs.mark_trusted(dir)
    Yamine::Certs.stubs(:state_dir).returns(dir)
    Yamine::Doctor.stubs(:stale_ca_count).returns(0)
    Yamine::Trust.stubs(:already_trusted?).returns(false)

    check = Yamine::Doctor.check_ca

    refute check.ok, "a CA macOS does not trust must not be reported as ok"
    assert_match(/macOS does not trust/, check.message)
    assert_match(/yamine trust/, check.message, "must name the command that fixes it")
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end
end

# A proxy running as an ordinary user is the process the browser's TLS
# stack actually talks to, and it skipped CA trust entirely
# (`ensure_system_ca_trust if Process.uid.zero?`). So a first run as a
# normal user installed a CA that could not work, and nothing at any
# point said so. A failure to trust has to be reported, not swallowed:
# the user is the only one who can authorize it.
class NonElevatedProxyTrustTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @errors = []
    @proxy = Yamine::Proxy.new(store: Yamine::RouteStore.new(@dir), port: 0, tls: false,
      state_dir: @dir, on_error: ->(m) { @errors << m })
  end

  def teardown
    FileUtils.remove_entry(@dir) rescue nil
  end

  def test_proxy_ensures_ca_trust_without_elevation
    source = File.read(File.join(__dir__, "..", "lib", "yamine", "proxy.rb"))
    boot = source[/def start_foreground.*?^      trap\("INT"\)/m]

    refute_nil boot, "could not locate the boot path in proxy.rb"
    assert_includes boot, "ensure_ca_trust",
      "every proxy must ensure CA trust, elevated or not"
    refute_includes boot, "Process.uid.zero?",
      "a non-elevated proxy that skips trust is how a CA gets installed unusable"
  end

  def test_proxy_attempts_trust_when_the_ca_is_not_trusted
    Yamine::Trust.stubs(:trusted?).returns(false)
    Yamine::Trust.expects(:trust).with(@dir).returns({ trusted: true })

    @proxy.send(:ensure_ca_trust)

    assert_empty @errors
  end

  # A locked keychain or a declined authorization prompt must reach the
  # user, with the reason, rather than being logged into nothing.
  def test_proxy_reports_a_failed_trust_attempt
    Yamine::Trust.stubs(:trusted?).returns(false)
    Yamine::Trust.stubs(:trust).with(@dir)
      .returns({ trusted: false, error: "no trust setting was recorded" })

    @proxy.send(:ensure_ca_trust)

    assert_equal 1, @errors.length, "a failed trust attempt must not be silent"
    assert_includes @errors.first, "no trust setting was recorded"
  end

  def test_proxy_does_not_re_trust_a_ca_macos_already_trusts
    Yamine::Trust.stubs(:trusted?).returns(true)
    Yamine::Trust.expects(:trust).never

    @proxy.send(:ensure_ca_trust)
  end

  # A machine whose CA arrives by MDM profile or a hand-run
  # `security add-trusted-cert` must not have it overwritten at every
  # proxy boot — and the suite spawns real proxies, so it must be able to
  # keep the trust store out of reach entirely.
  def test_proxy_leaves_the_trust_store_alone_when_told_to
    orig = ENV["YAMINE_SKIP_CA_TRUST"]
    ENV["YAMINE_SKIP_CA_TRUST"] = "1"
    Yamine::Trust.expects(:trusted?).never
    Yamine::Trust.expects(:trust).never

    @proxy.send(:ensure_ca_trust)
  ensure
    ENV["YAMINE_SKIP_CA_TRUST"] = orig
  end
end
