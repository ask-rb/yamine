# frozen_string_literal: true

require "fileutils"
require "openssl"

module Yamine
  # Local CA + per-hostname certificates, all in-process via OpenSSL.
  #
  # *.localhost sits at a public-suffix boundary so a wildcard cert is
  # not honored; every hostname gets an exact-SAN cert minted on demand
  # through the SNI callback and held in an in-memory LRU
  # (puma-dev ssl.go does the same; portless caches on disk instead).
  module Certs
    # The name is inherited from the rename (ask-local → yamine) and is
    # kept deliberately: `valid_pair?` below requires the on-disk CA to
    # carry this name, so changing it would mark every existing CA
    # invalid, forcing a regeneration and a re-trust (elevation / GUI
    # auth) on every machine — a real migration cost for a cosmetic gain.
    #
    # The name was ALSO never the actual problem: cleanup used to delete
    # by common name, which is ambiguous when several CAs share it. That
    # is fixed by operating on fingerprints (see Trust), so names no
    # longer decide what gets removed.
    #
    # CA_COMMON_NAMES is the list of names we have ever generated. Add to
    # it on any future rename so old certificates stay prunable —
    # Trust.prune_stale only ever removes certificates whose subject is
    # one of these.
    CA_COMMON_NAME = "Ask Local CA"
    CA_COMMON_NAMES = [CA_COMMON_NAME].freeze
    CA_VALIDITY_DAYS = 3650
    HOST_VALIDITY_DAYS = 825
    CACHE_SIZE = 1024

    module_function

    def ca_common_names
      CA_COMMON_NAMES
    end

    def state_dir
      ENV["YAMINE_STATE_DIR"] || File.join(home, ".yamine")
    end

    def home
      ENV["HOME"] || Dir.home
    rescue ArgumentError
      Dir.pwd
    end

    def ca_paths(dir = state_dir)
      { cert: File.join(dir, "ca.pem"), key: File.join(dir, "ca-key.pem") }
    end

    def ensure_ca(dir = state_dir)
      FileUtils.mkdir_p(dir, mode: 0o755)
      Ownership.fix(dir)
      paths = ca_paths(dir)
      return paths if valid_pair?(paths[:cert], paths[:key])

      key = OpenSSL::PKey::EC.generate("prime256v1")
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = OpenSSL::BN.rand(128, 0)
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{CA_COMMON_NAME}")
      cert.not_before = Time.now - 3600
      cert.not_after = Time.now + (CA_VALIDITY_DAYS * 86_400)
      cert.public_key = key
      ef = OpenSSL::X509::ExtensionFactory.new
      ef.subject_certificate = cert
      ef.issuer_certificate = cert
      cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
      cert.add_extension(ef.create_extension("keyUsage", "keyCertSign,cRLSign", true))
      cert.sign(key, "SHA256")

      File.write(paths[:key], key.to_pem, mode: "w", perm: 0o600)
      File.write(paths[:cert], cert.to_pem, mode: "w", perm: 0o644)
      Ownership.fix(paths[:key], paths[:cert])
      paths
    rescue OpenSSL::OpenSSLError => e
      raise CertError, "Could not generate local CA: #{e.message}"
    end

    def load_ca(dir = state_dir)
      paths = ensure_ca(dir)
      [OpenSSL::X509::Certificate.new(File.read(paths[:cert])),
       OpenSSL::PKey.read(File.read(paths[:key]))]
    end

    # Mint a leaf cert for one hostname, signed by the CA.
    def mint_host(hostname, ca_cert, ca_key)
      key = OpenSSL::PKey::EC.generate("prime256v1")
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = OpenSSL::BN.rand(128, 0)
      cert.subject = OpenSSL::X509::Name.parse("/CN=#{hostname[0, 64]}")
      cert.issuer = ca_cert.subject
      cert.not_before = Time.now - 3600
      cert.not_after = Time.now + (HOST_VALIDITY_DAYS * 86_400)
      cert.public_key = key
      ef = OpenSSL::X509::ExtensionFactory.new
      ef.subject_certificate = cert
      ef.issuer_certificate = ca_cert
      cert.add_extension(ef.create_extension("basicConstraints", "CA:FALSE", true))
      cert.add_extension(ef.create_extension("keyUsage", "digitalSignature,keyEncipherment", true))
      cert.add_extension(ef.create_extension("extendedKeyUsage", "serverAuth"))
      cert.add_extension(ef.create_extension("subjectAltName", "DNS:#{hostname}"))
      cert.sign(ca_key, "SHA256")
      [cert, key]
    end

    # Build an SSLContext whose SNI callback serves the right cert per host.
    def server_context(dir = state_dir)
      ca_cert, ca_key = load_ca(dir)
      cache = CertCache.new(CACHE_SIZE)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.cert = ca_cert
      ctx.key = ca_key
      # ruby-openssl versions differ in how the callback receives its
      # arguments: [[socket, name]] (one array arg), (socket, name), or
      # (name). Flatten defensively — a raise inside the callback
      # surfaces as an unrecognized-name handshake alert.
      ctx.servername_cb = lambda do |*args|
        host = Array(args).flatten.last.to_s.downcase
        entry = cache.fetch(host) do
          cert, key = mint_host(host, ca_cert, ca_key)
          [cert, key]
        end
        entry ? OpenSSL::SSL::SSLContext.new.tap { |c| c.cert, c.key = entry } : nil
      end
      ctx
    end

    def trusted?(dir = state_dir)
      paths = ca_paths(dir)
      return false unless File.file?(paths[:cert])

      marker = File.join(dir, "ca.trusted")
      return false unless File.file?(marker)

      Digest::SHA256.hexdigest(File.read(paths[:cert])).then do |fp|
        File.read(marker).strip == fp
      end
    rescue SystemCallError
      false
    end

    def mark_trusted(dir = state_dir)
      require "digest"
      paths = ca_paths(dir)
      fp = Digest::SHA256.hexdigest(File.read(paths[:cert]))
      File.write(File.join(dir, "ca.trusted"), "#{fp}\n")
    end

    def valid_pair?(cert_path, key_path)
      return false unless File.file?(cert_path) && File.file?(key_path)

      cert = OpenSSL::X509::Certificate.new(File.read(cert_path))
      cert.not_after > Time.now + (7 * 86_400) &&
        cert.subject.to_s.include?(CA_COMMON_NAME)
    rescue OpenSSL::OpenSSLError, SystemCallError, ArgumentError
      false
    end

    # In-memory LRU for minted host certs.
    class CertCache
      def initialize(max)
        @max = max
        @store = {}
        @order = []
        @mutex = Mutex.new
      end

      def fetch(host)
        @mutex.synchronize do
          if @store.key?(host)
            @order.delete(host)
            @order << host
            return @store[host]
          end
          value = yield
          @store[host] = value
          @order << host
          if @order.length > @max
            oldest = @order.shift
            @store.delete(oldest)
          end
          value
        end
      end

      def size
        @mutex.synchronize { @store.size }
      end
    end
  end
end
