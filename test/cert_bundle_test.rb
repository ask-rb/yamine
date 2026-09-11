# frozen_string_literal: true

require_relative "test_helper"
require "openssl"

# The child process's TLS trust.
#
# yamine serves *.localhost under its own CA. A process that talks to one
# of those names needs to be told to trust it, and the obvious
# implementation is wrong in a way that only shows up later: pointing
# SSL_CERT_FILE at the CA *replaces* OpenSSL's default store, so the app
# loses every public root and its next call to an external API fails
# verification. The bundle exists so both work at once.
class CertBundleTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @orig_state = ENV["YAMINE_STATE_DIR"]
    ENV["YAMINE_STATE_DIR"] = @dir
  end

  def teardown
    ENV["YAMINE_STATE_DIR"] = @orig_state
    FileUtils.remove_entry(@dir)
  end

  def bundle = Yamine::Certs.ensure_bundle(@dir)

  def bundle_pems
    File.read(bundle).scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
  end

  def test_bundle_contains_the_ca_and_the_system_roots
    assert File.file?(bundle)
    pems = bundle_pems
    assert_operator pems.size, :>, 1, "the bundle must carry more than the CA — SSL_CERT_FILE replaces the store"

    ca = OpenSSL::X509::Certificate.new(File.read(File.join(@dir, "ca.pem")))
    assert pems.any? { |pem| OpenSSL::X509::Certificate.new(pem).to_der == ca.to_der },
      "the bundle must contain yamine's own CA"
    assert_equal OpenSSL::X509::Certificate.new(pems.last).to_der, ca.to_der,
      "the CA goes last, so a store built in order ends with it"
  end

  def test_bundle_verifies_the_ca_as_a_trust_anchor
    store = OpenSSL::X509::Store.new
    bundle_pems.each { |pem| store.add_cert(OpenSSL::X509::Certificate.new(pem)) }

    ca = OpenSSL::X509::Certificate.new(File.read(File.join(@dir, "ca.pem")))
    assert store.verify(ca), "a store built from the bundle must accept yamine's CA"
  end

  def test_bundle_leaves_public_roots_alone
    # The point of the bundle: an app that trusts yamine's CA must still be
    # able to call the outside world. Whichever system store this machine
    # has, its bytes are in there.
    system_file = Yamine::Certs.system_bundle
    skip "no system bundle on this machine" if system_file.nil?

    assert_includes File.read(bundle), File.read(system_file).lines.first.to_s.strip
  end

  def test_bundle_is_cached_until_something_changes
    first = File.mtime(bundle)
    sleep 0.05
    Yamine::Certs.ensure_bundle(@dir)
    assert_equal first, File.mtime(bundle), "an unchanged CA and store must not rewrite the bundle"

    # A regenerated CA must invalidate it — otherwise `yamine trust` would
    # leave every app verifying against a CA that no longer signs anything.
    FileUtils.rm_f(File.join(@dir, "ca.pem"))
    sleep 0.05
    Yamine::Certs.ensure_bundle(@dir)
    assert_operator File.mtime(bundle), :>, first
  end

  def test_child_env_points_ruby_git_and_node_at_the_right_files
    store = Yamine::RouteStore.new(@dir)
    runner = Yamine::Runner.new(store: store, on_log: ->(_m) {})
    env = runner.send(:child_env, @dir, url: "https://myapp.localhost", port: 4001)

    assert_equal File.join(@dir, "ca.pem"), env["NODE_EXTRA_CA_CERTS"],
      "Node's variable is additive, so the CA alone is right there"
    assert_equal Yamine::Certs.bundle_path(@dir), env["SSL_CERT_FILE"]
    assert_equal Yamine::Certs.bundle_path(@dir), env["GIT_SSL_CAINFO"]
    refute_equal env["SSL_CERT_FILE"], env["NODE_EXTRA_CA_CERTS"],
      "SSL_CERT_FILE must be the bundle, never the CA alone"
  end

  def test_a_real_handshake_against_the_trusted_name
    # The end the whole thing exists for: Ruby's own TLS stack, given only
    # this bundle, accepts a certificate yamine minted for the name.
    ca_cert, ca_key = Yamine::Certs.load_ca(@dir)
    cert, key = Yamine::Certs.mint_host("myapp.localhost", ca_cert, ca_key)

    server = OpenSSL::SSL::SSLServer.new(TCPServer.new("127.0.0.1", 0), begin
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.cert = cert
      ctx.key = key
      ctx
    end)
    port = server.to_io.addr[1]

    client_ctx = OpenSSL::SSL::SSLContext.new
    client_ctx.cert_store = OpenSSL::X509::Store.new.tap do |store|
      bundle_pems.each { |pem| store.add_cert(OpenSSL::X509::Certificate.new(pem)) }
    end
    client_ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
    client_ctx.verify_hostname = true

    thread = Thread.new do
      socket = server.accept
      socket.close
    end
    client = OpenSSL::SSL::SSLSocket.new(TCPSocket.new("127.0.0.1", port), client_ctx)
    # SNI and — with verify_hostname — the name actually verified against
    # the certificate.
    client.hostname = "myapp.localhost"
    client.connect
    assert client.peer_cert
    client.close
    thread.join
  end
end
