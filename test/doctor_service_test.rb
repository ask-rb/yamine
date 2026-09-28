# frozen_string_literal: true

require_relative "test_helper"

# doctor's privileged-service check: legacy installs are named with
# the exact migration command, staged-vs-CLI skew is surfaced, bad
# ownership fails, and the interpreter is reported truthfully.
# Hermetic: the PrivilegedPayload seams are stubbed, no unit files or
# sudo are ever touched.
class DoctorServiceCheckTest < Minitest::Test
  def check
    Yamine::Doctor.check_service
  end

  def test_skips_cleanly_without_a_service
    Yamine::PrivilegedPayload.stubs(:service_unit_present?).returns(false)

    c = check

    assert c.ok
    refute c.warn?
    assert_match(/no privileged service/i, c.message)
  end

  def test_legacy_install_warns_with_the_exact_migration
    Yamine::PrivilegedPayload.stubs(:service_unit_present?).returns(true)
    Yamine::PrivilegedPayload.stubs(:installed_payload_ref).returns(
      File.expand_path("~/.local/share/mise/installs/ruby/3.4.4/lib/ruby/gems/3.4.0/gems/yamine-0.19.0/bin/yamine"))
    Yamine::PrivilegedPayload.stubs(:ruby_info).returns({ path: "/x/ruby", writable: false })

    c = check

    assert c.ok, "a legacy daemon keeps working — this warns, it does not fail"
    assert c.warn?
    assert_match(/legacy|user-writable/i, c.message)
    assert_match(/sudo yamine service install/, c.message)
  end

  def test_staged_version_skew_warns
    Yamine::PrivilegedPayload.stubs(:service_unit_present?).returns(true)
    Yamine::PrivilegedPayload.stubs(:installed_payload_ref).returns(Yamine::PrivilegedPayload.bin_path)
    Yamine::PrivilegedPayload.stubs(:verify!).returns(true)
    Yamine::PrivilegedPayload.stubs(:staged_version).returns("0.1.0")
    Yamine::PrivilegedPayload.stubs(:ruby_info).returns({ path: "/x/ruby", writable: false })

    c = check

    assert c.ok
    assert c.warn?
    assert_match(/0\.1\.0/, c.message)
    assert_match(/#{Regexp.escape(Yamine::VERSION)}/, c.message)
    assert_match(/sudo yamine service install/, c.message)
  end

  def test_bad_ownership_fails_with_the_fix
    Yamine::PrivilegedPayload.stubs(:service_unit_present?).returns(true)
    Yamine::PrivilegedPayload.stubs(:installed_payload_ref).returns(Yamine::PrivilegedPayload.bin_path)
    Yamine::PrivilegedPayload.stubs(:verify!).raises(Yamine::Error.new("refusing the privileged payload: x is not root-owned"))
    Yamine::PrivilegedPayload.stubs(:staged_version).returns(Yamine::VERSION)
    Yamine::PrivilegedPayload.stubs(:ruby_info).returns({ path: "/x/ruby", writable: false })

    c = check

    refute c.ok
    assert_match(/not root-owned/, c.message)
    assert_match(/sudo yamine service install/, c.message)
  end

  def test_healthy_staged_install_is_ok
    Yamine::PrivilegedPayload.stubs(:service_unit_present?).returns(true)
    Yamine::PrivilegedPayload.stubs(:installed_payload_ref).returns(Yamine::PrivilegedPayload.bin_path)
    Yamine::PrivilegedPayload.stubs(:verify!).returns(true)
    Yamine::PrivilegedPayload.stubs(:staged_version).returns(Yamine::VERSION)
    Yamine::PrivilegedPayload.stubs(:ruby_info).returns({ path: "/x/ruby", writable: false })

    c = check

    assert c.ok
    refute c.warn?
  end

  def test_user_writable_interpreter_is_reported_truthfully
    Yamine::PrivilegedPayload.stubs(:service_unit_present?).returns(true)
    Yamine::PrivilegedPayload.stubs(:installed_payload_ref).returns(Yamine::PrivilegedPayload.bin_path)
    Yamine::PrivilegedPayload.stubs(:verify!).returns(true)
    Yamine::PrivilegedPayload.stubs(:staged_version).returns(Yamine::VERSION)
    Yamine::PrivilegedPayload.stubs(:ruby_info).returns({ path: "/Users/x/.local/share/mise/shims/ruby", writable: true })

    c = check

    assert c.ok
    assert c.warn?
    assert_match(%r{/Users/x/\.local/share/mise/shims/ruby}, c.message)
    assert_match(/user-writable/i, c.message)
  end

  def test_unreadable_unit_warns_to_reinstall
    Yamine::PrivilegedPayload.stubs(:service_unit_present?).returns(true)
    Yamine::PrivilegedPayload.stubs(:installed_payload_ref).returns(nil)

    c = check

    assert c.ok
    assert c.warn?
    assert_match(/sudo yamine service install/, c.message)
  end

  def test_run_includes_the_service_check
    store = mock("store")
    store.stubs(:dir).returns(Dir.mktmpdir)
    store.stubs(:port_path).returns("/nonexistent")
    store.stubs(:load_routes).returns([])
    Yamine::ProxyControl.stubs(:proxy_tls).returns(false)
    Yamine::ProxyControl.stubs(:serving_port).returns(nil)
    Yamine::Hosts.stubs(:resolution).returns(ok: [], warn: [], fail: [])
    Yamine::PrivilegedPayload.stubs(:service_unit_present?).returns(false)

    names = Yamine::Doctor.run(store: store).map(&:name)

    assert_includes names, "service"
  end
end
