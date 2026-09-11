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
    # The CA's name is user-visible in the trust store and is what a
    # cleanup keys off, so it belongs to this gem alone. It was inherited
    # from the ask-local rename and had said "Ask Local CA" ever since.
    CA_COMMON_NAME = "Yamine CA"
    # Every name we have ever generated a CA under. Stale certificates
    # under these are prunable (Trust.prune_stale); anything else in the
    # trust store is none of our business. The pre-rename name stays here
    # so machines that trusted an ask-local CA can still shed it.
    LEGACY_CA_COMMON_NAMES = ["Ask Local CA"].freeze
    CA_VALIDITY_DAYS = 3650
    HOST_VALIDITY_DAYS = 825
    CACHE_SIZE = 1024

    module_function

    def ca_common_names
      [CA_COMMON_NAME, *LEGACY_CA_COMMON_NAMES].uniq
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

    # The CA certificate's path on disk. Generated on first ask.
    def ca_cert_path(dir = state_dir)
      ensure_ca(dir)
      ca_paths(dir)[:cert]
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

    # A CA bundle a child process can verify against: the system roots
    # *plus* this CA.
    #
    # Why a bundle and not just the CA: `SSL_CERT_FILE` (Ruby/OpenSSL,
    # curl, git) *replaces* the default store rather than adding to it, so
    # pointing it at a file containing only our CA makes every public
    # HTTPS request in that process fail verification. Concatenating gives
    # both — yamine's names verify and rubygems, APIs, and git-over-https
    # keep working.
    #
    # Built fresh when the CA or the system store changes, and cached
    # otherwise: the bundle is ~230 KB and regenerating it on every boot
    # would be pure waste, while serving a stale one after `yamine trust`
    # regenerates the CA would silently break every TLS connection in the
    # app.
    def bundle_path(dir = state_dir)
      File.join(dir, "bundle.pem")
    end

    # The system's own roots, in the order OpenSSL would consider them.
    # SSL_CERT_FILE wins when set (that is the variable we are about to
    # write, and a caller may have pointed it somewhere deliberately),
    # else OpenSSL's compiled-in file, else the usual macOS/Linux paths.
    def system_bundle
      candidates = [ENV["SSL_CERT_FILE"],
        OpenSSL::X509::DEFAULT_CERT_FILE,
        "/etc/ssl/cert.pem",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/certs/ca-certificates.crt"].compact
      candidates.find { |path| File.file?(path) && File.size(path).positive? }
    end

    def ensure_bundle(dir = state_dir)
      paths = ensure_ca(dir)
      target = bundle_path(dir)
      ca = File.read(paths[:cert])
      system_file = system_bundle
      # Regenerate when the CA changed, when the system store changed, or
      # when the bundle is missing. mtime comparison is enough: these files
      # are written by installers, not edited in place.
      return target if bundle_current?(target, paths[:cert], system_file)

      FileUtils.mkdir_p(dir)
      content = +""
      content << File.read(system_file) if system_file
      content << "\n" unless content.empty? || content.end_with?("\n")
      content << ca
      File.write(target, content, mode: "w", perm: 0o644)
      Ownership.fix(target)
      target
    end

    def bundle_current?(target, ca_path, system_file)
      return false unless File.file?(target)

      target_mtime = File.mtime(target)
      return false if File.mtime(ca_path) > target_mtime
      return false if system_file && File.mtime(system_file) > target_mtime

      true
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
