# frozen_string_literal: true

require_relative "test_helper"

# The incident this pins: the CA on disk was regenerated while a root
# proxy kept signing with its boot-time CA, so every browser got
# ERR_CERT_AUTHORITY_INVALID — and doctor still said "[ok] proxy:
# listening" and "[ok] ca: CA trusted", because no check compared the
# certificate the proxy actually serves against the current CA.
class DoctorServingCaTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_state = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
    Yamine::Certs.ensure_ca(@dir)
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig_state
    FileUtils.remove_entry(@dir)
  end

  def mint_from_disk(host = "probe.localhost")
    ca_cert, ca_key = Yamine::Certs.load_ca(@dir)
    Yamine::Certs.mint_host(host, ca_cert, ca_key).first
  end

  def regenerate_ca
    paths = Yamine::Certs.ca_paths(@dir)
    FileUtils.rm_f([paths[:cert], paths[:key]])
    Yamine::Certs.ensure_ca(@dir)
  end

  def test_ok_when_serving_certificate_matches_disk_ca
    Yamine::Trust.stubs(:proxy_peer_cert).returns(mint_from_disk)

    check = Yamine::Doctor.check_serving_ca(443, tls: true)

    assert check.ok
    refute check.warn?
    assert_match(/matches the CA on disk/, check.message)
  end

  def test_fail_reports_stale_ca_with_the_fix
    stale_leaf = mint_from_disk
    regenerate_ca
    Yamine::Trust.stubs(:proxy_peer_cert).returns(stale_leaf)

    check = Yamine::Doctor.check_serving_ca(443, tls: true)

    refute check.ok
    assert_match(/superseded CA/, check.message)
    assert_match(%r{sudo launchctl kickstart -k system/dev\.yamine}, check.message)
    assert_match(/sudo yamine service install/, check.message)
  end

  def test_skips_cleanly_without_a_serving_proxy
    check = Yamine::Doctor.check_serving_ca(nil, tls: true)

    assert check.ok
    refute check.warn?
  end

  def test_skips_cleanly_when_tls_is_off
    Yamine::Trust.stubs(:proxy_peer_cert).raises("must not dial out when TLS is off")

    check = Yamine::Doctor.check_serving_ca(80, tls: false)

    assert check.ok
    refute check.warn?
  end

  def test_run_includes_the_serving_ca_check
    store = mock("store")
    store.stubs(:dir).returns(@dir)
    store.stubs(:port_path).returns(File.join(@dir, "proxy.port"))
    store.stubs(:load_routes).returns([])
    Yamine::ProxyControl.stubs(:proxy_tls).returns(false)
    Yamine::ProxyControl.stubs(:serving_port).returns(nil)
    Yamine::Hosts.stubs(:resolution).returns(ok: [], warn: [], fail: [])

    names = Yamine::Doctor.run(store: store).map(&:name)

    assert_includes names, "serving ca"
  end
end
