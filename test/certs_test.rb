# frozen_string_literal: true

require_relative "test_helper"

class CertsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_ensure_ca_creates_pair
    paths = Yamine::Certs.ensure_ca(@dir)
    assert File.file?(paths[:cert])
    assert File.file?(paths[:key])
    assert_equal 0o600, File.stat(paths[:key]).mode & 0o777
  end

  def test_ensure_ca_idempotent
    first = File.read(Yamine::Certs.ensure_ca(@dir)[:cert])
    second = File.read(Yamine::Certs.ensure_ca(@dir)[:cert])
    assert_equal first, second
  end

  def test_mint_host_has_exact_san
    ca_cert, ca_key = Yamine::Certs.load_ca(@dir)
    cert, _key = Yamine::Certs.mint_host("myapp.localhost", ca_cert, ca_key)
    sans = cert.extensions.find { |e| e.oid == "subjectAltName" }&.value
    assert_includes sans, "DNS:myapp.localhost"
    assert_equal ca_cert.subject.to_s, cert.issuer.to_s
  end

  def test_server_context_sni_serves_per_host_certs
    ctx = Yamine::Certs.server_context(@dir)
    refute_nil ctx.servername_cb
  end

  def test_cert_cache_lru_evicts
    cache = Yamine::Certs::CertCache.new(2)
    cache.fetch("a") { 1 }
    cache.fetch("b") { 2 }
    cache.fetch("c") { 3 }
    assert_equal 2, cache.size
  end

  def test_trust_marker_roundtrip
    Yamine::Certs.ensure_ca(@dir)
    refute Yamine::Certs.trusted?(@dir)
    Yamine::Certs.mark_trusted(@dir)
    assert Yamine::Certs.trusted?(@dir)
  end
end
