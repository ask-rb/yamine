# frozen_string_literal: true

require "open3"

module Yamine
  # Install the local CA into the OS trust store.
  module Trust
    module_function

    def platform
      case RUBY_PLATFORM
      when /darwin/ then :macos
      when /linux/ then :linux
      when /mingw|mswin/ then :windows
      else :unknown
      end
    end

    def trust(dir = Certs.state_dir)
      paths = Certs.ensure_ca(dir)
      prune_stale(dir)
      case platform
      when :macos then trust_macos(paths[:cert])
      when :linux then trust_linux(paths[:cert])
      when :windows then trust_windows(paths[:cert])
      else return { trusted: false, error: "Unsupported platform: #{RUBY_PLATFORM}" }
      end
      Certs.mark_trusted(dir)
      { trusted: true }
    rescue StandardError => e
      { trusted: false, error: e.message }
    end

    # The fingerprint `security -Z` prints: uppercase hex, no colons.
    # Certificates are identified by THIS, never by common name: every CA
    # this project has generated shares a name with the others, so a
    # by-name lookup or delete cannot tell the current CA from a stale
    # one and may remove the wrong certificate.
    def fingerprint_of(cert_path)
      require "digest"
      cert = OpenSSL::X509::Certificate.new(File.read(cert_path))
      Digest::SHA1.hexdigest(cert.to_der).upcase
    rescue OpenSSL::OpenSSLError, SystemCallError
      nil
    end

    # Certificates in a keychain as { fingerprint:, subject:, cert: }.
    # Parsed in ONE call; empty when the keychain (or `security`) is
    # unavailable, which callers treat as "cannot tell".
    #
    # -a is required: without it `security find-certificate` returns a
    # single certificate, so any scan silently sees one entry and every
    # comparison against it is wrong.
    def keychain_certs(keychain)
      out, status = Command.capture2("security", "find-certificate", "-a", "-Z", "-p", keychain)
      return [] unless status.success?

      require "digest"
      out.split("-----BEGIN CERTIFICATE-----").filter_map do |block|
        next unless block.include?("-----END CERTIFICATE-----")

        cert = begin
          OpenSSL::X509::Certificate.new("-----BEGIN CERTIFICATE-----" + block)
        rescue OpenSSL::OpenSSLError
          next
        end
        { fingerprint: Digest::SHA1.hexdigest(cert.to_der).upcase,
          subject: cert.subject.to_s,
          cert: cert }
      end
    rescue SystemCallError
      []
    end

    # Fingerprints of certificates in a keychain, optionally limited to
    # one common name.
    def keychain_fingerprints(keychain, common_name: nil)
      certs = keychain_certs(keychain)
      certs = certs.select { |c| c[:subject].include?(common_name) } if common_name
      certs.map { |c| c[:fingerprint] }
    end

    def keychains
      [login_keychain, "/Library/Keychains/System.keychain"]
    end

    # Remove trusted certificates that carry one of our CA names but are
    # neither the CA on disk nor the one a live proxy is signing with.
    #
    # Regeneration is normal (the CA is rebuilt when it is missing,
    # expiring, or renamed), and each rebuild produced a new certificate
    # that was trusted and NEVER removed: one machine accumulated 14
    # distinct trusted roots, all named "Ask Local CA". Apple's keychain
    # keeps its own copy, so deleting the state dir does not untrust
    # anything, and a trusted root whose superseded private key is still
    # on disk (or in a backup) is a real liability.
    #
    # The running proxy's CA is protected by SIGNATURE, not by name:
    # `server_context` loads the CA once at startup and the SNI callback
    # mints host certs from that in-memory copy, so a live proxy keeps
    # using its boot-time CA whatever is on disk. Deleting that
    # certificate would break TLS for every live route until a restart,
    # and since superseded CAs share a name with the live one, only a
    # signature check can tell them apart.
    def prune_stale(dir = Certs.state_dir, keychains: nil)
      current = fingerprint_of(Certs.ca_paths(dir)[:cert])
      return 0 unless current

      names = Certs.ca_common_names
      leaf = live_proxy_cert
      (keychains || self.keychains).sum do |keychain|
        keychain_certs(keychain).count do |entry|
          next false if entry[:fingerprint] == current
          next false unless names.any? { |n| entry[:subject].include?(n) }
          next false if leaf && signed_by?(leaf, entry[:cert])

          Command.capture2("security", "delete-certificate", "-Z", entry[:fingerprint], keychain)
          true
        end
      end
    rescue SystemCallError
      0
    end

    # True when `cert` is the issuer of `leaf` — i.e. that CA signed it.
    # This is what identifies the live proxy's CA exactly.
    def signed_by?(leaf, cert)
      leaf.verify(cert.public_key)
    rescue StandardError
      false
    end

    # A certificate minted by the running proxy, whose issuer is the CA it
    # is signing with, or nil when no proxy is serving.
    def live_proxy_cert(store = nil)
      return nil unless defined?(ProxyControl)

      store ||= RouteStore.new(Certs.state_dir)
      port = ProxyControl.serving_port(store)
      return nil unless port

      proxy_peer_cert(port)
    rescue StandardError
      nil
    end

    def proxy_peer_cert(port, host = "yamine-ca-probe.localhost")
      sock = TCPSocket.new("127.0.0.1", port)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
      ssl = OpenSSL::SSL::SSLSocket.new(sock, ctx)
      ssl.hostname = host if ssl.respond_to?(:hostname=)
      ssl.connect
      ssl.peer_cert
    ensure
      begin
        ssl&.close
      rescue StandardError
        nil
      end
      begin
        sock&.close unless sock.nil? || sock.closed?
      rescue StandardError
        nil
      end
    end

    # The common name of the CA a running proxy actually signs with,
    # read from the issuer of a certificate it mints, or nil when no
    # proxy is serving or the name cannot be determined.
    def serving_ca_common_name(store = nil)
      leaf = live_proxy_cert(store)
      return nil unless leaf

      leaf.issuer.to_s[/CN=([^\/,]+)/, 1]
    end

    def proxy_peer_cert(port, host = "yamine-ca-probe.localhost")
      sock = TCPSocket.new("127.0.0.1", port)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
      ssl = OpenSSL::SSL::SSLSocket.new(sock, ctx)
      ssl.hostname = host if ssl.respond_to?(:hostname=)
      ssl.connect
      ssl.peer_cert
    ensure
      begin
        ssl&.close
      rescue StandardError
        nil
      end
      begin
        sock&.close unless sock.nil? || sock.closed?
      rescue StandardError
        nil
      end
    end

    def trust_macos(cert_path)
      if Process.uid.zero?
        # Running elevated (service install / root proxy): add to the
        # System keychain with the admin (-d) domain. Root can modify it
        # silently — no GUI authorization popup, and every user's
        # browsers trust the proxy.
        keychain = "/Library/Keychains/System.keychain"
        return if already_trusted?(cert_path, keychain)

        _out, status = Command.capture2("security", "add-trusted-cert",
          "-d", "-r", "trustRoot", "-k", keychain, cert_path)
        raise CertError, "security add-trusted-cert (system) failed" unless status.success?
      else
        keychain = login_keychain
        return if already_trusted?(cert_path, keychain)

        _out, status = Command.capture2("security", "add-trusted-cert",
          "-r", "trustRoot", "-k", keychain, cert_path)
        raise CertError, "security add-trusted-cert failed" unless status.success?
      end
    end

    # Adding the same certificate twice is not harmless: it is how the
    # trust store accumulated duplicates across repeated setup runs.
    def already_trusted?(cert_path, keychain)
      fp = fingerprint_of(cert_path)
      return false unless fp

      keychain_fingerprints(keychain, common_name: nil).include?(fp)
    end

    def login_keychain
      out, status = Command.capture2("security", "default-keychain")
      if status.success? && (m = out.match(/"(.+)"/))
        m[1]
      else
        File.join(Certs.home, "Library", "Keychains", "login.keychain-db")
      end
    end

    def trust_linux(cert_path)
      dest_dir, update_cmd = linux_ca_config
      FileUtils.mkdir_p(dest_dir)
      FileUtils.cp(cert_path, File.join(dest_dir, "yamine-ca.crt"))
      _out, status = Command.capture2(update_cmd)
      raise CertError, "#{update_cmd} failed" unless status.success?
    end

    def linux_ca_config
      os_release = begin
        File.read("/etc/os-release").downcase
      rescue SystemCallError
        ""
      end
      if os_release.include?("arch")
        ["/etc/ca-certificates/trust-source/anchors", "update-ca-trust"]
      elsif os_release.match?(/fedora|rhel|centos/)
        ["/etc/pki/ca-trust/source/anchors", "update-ca-trust"]
      elsif os_release.include?("suse")
        ["/etc/pki/trust/anchors", "update-ca-certificates"]
      else
        ["/usr/local/share/ca-certificates", "update-ca-certificates"]
      end
    end

    def trust_windows(cert_path)
      _out, status = Command.capture2("certutil", "-addstore", "-user", "Root", cert_path)
      raise CertError, "certutil failed" unless status.success?
    end

    # Best-effort removal of the CA from the OS trust store. Only
    # attempts when our marker says we trusted it; used by `clean`.
    def untrust(dir = Certs.state_dir)
      return { removed: true } unless Certs.trusted?(dir)

      paths = Certs.ca_paths(dir)
      fp = fingerprint_of(paths[:cert])
      errors = []
      case platform
      when :macos
        Command.capture2("security", "remove-trusted-cert", paths[:cert])
        # Delete by FINGERPRINT, never by common name. Every yamine CA is
        # named "Ask Local CA", so `delete-certificate -c` removes an
        # arbitrary one of them — possibly the CURRENT CA, or one a
        # sibling checkout still serves — and leaves the target behind.
        # The old by-name loop here deleted up to five certificates per
        # keychain for that reason.
        keychains.each do |kc|
          next unless fp && keychain_fingerprints(kc).include?(fp)

          Command.capture2("security", "delete-certificate", "-Z", fp, kc)
        end
      when :linux
        dest_dir, update_cmd = linux_ca_config
        dest = File.join(dest_dir, "yamine-ca.crt")
        FileUtils.rm_f(dest) if File.file?(dest)
        Command.capture2(update_cmd)
      when :windows
        Command.capture2("certutil", "-delstore", "-user", "Root", Certs::CA_COMMON_NAME)
      end
      trusted_after = begin
        Certs.trusted?(dir)
      rescue StandardError
        false
      end
      File.unlink(File.join(dir, "ca.trusted")) if File.file?(File.join(dir, "ca.trusted"))
      if trusted_after
        { removed: false, error: errors.empty? ? "CA still trusted (remove manually)" : errors.join("; ") }
      else
        { removed: true }
      end
    rescue StandardError => e
      { removed: false, error: e.message }
    end
  end
end
