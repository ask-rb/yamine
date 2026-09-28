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

  # A root launchd proxy runs for days while `yamine clean`/`trust`/
  # `setup` regenerate the CA pair under it. The proxy must pick the
  # new CA up on the next handshake — no restart — or every browser
  # gets ERR_CERT_AUTHORITY_INVALID against a CA that no longer signs.
  def test_server_context_reloads_signing_after_ca_swap
    ctx = Yamine::Certs.server_context(@dir)
    old_ca = OpenSSL::X509::Certificate.new(File.read(File.join(@dir, "ca.pem")))

    first = ctx.servername_cb.call("myapp.localhost")
    assert first.cert.verify(old_ca.public_key)

    regenerate_ca
    new_ca = OpenSSL::X509::Certificate.new(File.read(File.join(@dir, "ca.pem")))
    refute_equal old_ca.to_der, new_ca.to_der

    second = ctx.servername_cb.call("other.localhost")
    assert second.cert.verify(new_ca.public_key),
      "a new handshake after the swap must be signed by the new CA"
    refute second.cert.verify(old_ca.public_key)
  end

  def test_server_context_drops_cached_leaves_on_ca_swap
    ctx = Yamine::Certs.server_context(@dir)
    before = ctx.servername_cb.call("cached.localhost")

    regenerate_ca
    new_ca = OpenSSL::X509::Certificate.new(File.read(File.join(@dir, "ca.pem")))

    after = ctx.servername_cb.call("cached.localhost")
    refute_equal before.cert.to_der, after.cert.to_der,
      "a leaf minted from the old CA must not survive the swap, even on a cache hit"
    assert after.cert.verify(new_ca.public_key)
  end

  def test_live_handshake_serves_new_ca_after_swap
    ctx = Yamine::Certs.server_context(@dir)
    server = OpenSSL::SSL::SSLServer.new(TCPServer.new("127.0.0.1", 0), ctx)
    port = server.to_io.addr[1]
    old_ca = OpenSSL::X509::Certificate.new(File.read(File.join(@dir, "ca.pem")))

    accepts = Thread.new do
      2.times do
        begin
          sock = server.accept
          sock.close
        rescue StandardError
          nil
        end
      end
    end

    first = tls_peer_cert(port, "myapp.localhost")
    assert first.verify(old_ca.public_key)

    regenerate_ca
    new_ca = OpenSSL::X509::Certificate.new(File.read(File.join(@dir, "ca.pem")))

    second = tls_peer_cert(port, "myapp.localhost")
    assert second.verify(new_ca.public_key),
      "a new TLS handshake must be signed by the new CA without restarting the proxy"
    refute second.verify(old_ca.public_key)
  ensure
    accepts&.join(5)
    server&.close
  end

  private

  def regenerate_ca
    paths = Yamine::Certs.ca_paths(@dir)
    FileUtils.rm_f([paths[:cert], paths[:key]])
    Yamine::Certs.ensure_ca(@dir)
  end

  def tls_peer_cert(port, hostname)
    raw = TCPSocket.new("127.0.0.1", port)
    client_ctx = OpenSSL::SSL::SSLContext.new
    client_ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
    sock = OpenSSL::SSL::SSLSocket.new(raw, client_ctx)
    sock.hostname = hostname
    sock.connect
    sock.peer_cert
  ensure
    sock&.close
  end
end
