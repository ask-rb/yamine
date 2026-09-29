# frozen_string_literal: true

require "open3"
require "tmpdir"

module Yamine
  # Install the local CA into the OS trust store.
  module Trust
    SYSTEM_KEYCHAIN = "/Library/Keychains/System.keychain"

    # The policies a browser's TLS stack evaluates a leaf under: SSL
    # server (the hostname check) and X.509 basic (the chain build).
    #
    # They have to be named, and this is measured, not assumed.
    # `add-trusted-cert -r trustRoot` with no `-p` exits 0 and records
    # the certificate in the trust store with NO `trustSettings` array at
    # all: `security dump-trust-settings` reports "Number of trust
    # settings : 0", and `security trust-settings-export` shows a
    # trustList entry holding only issuerName/modDate/serialNumber. What
    # the CA is trusted FOR is then unstated, and whether such an entry
    # is honoured at all depends on the certificate also being installed
    # in a keychain the evaluator searches — on the machine this was
    # fixed on, it was not, and every browser answered
    # ERR_CERT_AUTHORITY_INVALID.
    #
    # With `-p ssl -p basic` the same call records
    # kSecTrustSettingsPolicyName sslServer + basicX509, and per
    # SecTrustSettings.h a settings entry with no explicit
    # kSecTrustSettingsResult defaults to kSecTrustSettingsResultTrustRoot
    # ("trust this root cert"). That is also what Keychain Access writes
    # for a certificate set to Secure Sockets Layer + X.509 Basic.
    MACOS_TRUST_POLICIES = %w[-p ssl -p basic].freeze

    # SecTrustSettingsResult (Security/SecTrustSettings.h). Only these
    # two grant trust; 3 is Deny and 4 is Unspecified, so a CA whose only
    # setting is one of those is explicitly NOT trusted.
    TRUST_RESULTS = [1, 2].freeze

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

    # True when the OS trust store will honour the CA in `dir`.
    #
    # The state-dir marker is only half the answer, and the half that
    # lies: it records that WE trusted this exact certificate at some
    # point, so it survives a keychain that never took the setting, a
    # trust run that recorded nothing, and a CA that was regenerated
    # under it. Treating the marker as "trusted" is how a machine kept a
    # CA in its keychain that no browser would accept.
    def trusted?(dir = Certs.state_dir)
      return false unless Certs.trusted?(dir)
      return true unless platform == :macos

      paths = Certs.ca_paths(dir)
      return false unless File.file?(paths[:cert])

      macos_keychains.any? { |keychain| already_trusted?(paths[:cert], keychain) }
    end

    # The keychains a CA can be trusted into: the user's own, and — for
    # an elevated run — the System one, which every user on the machine
    # reads. Both are checked because the certificate on disk may have
    # been trusted into either, and a CA trusted only as root is not
    # trusted for a later unprivileged run (or the reverse).
    def macos_keychains
      [login_keychain, SYSTEM_KEYCHAIN].uniq
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
      [login_keychain, SYSTEM_KEYCHAIN]
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
          "-d", "-r", "trustRoot", *MACOS_TRUST_POLICIES, "-k", keychain, cert_path)
        raise CertError, macos_trust_error(cert_path, keychain) unless status.success?
      else
        # Not elevated: the user's own keychain, with the trust policies
        # named. The certificate still has to be in a keychain — macOS
        # builds the chain by searching keychains for the issuer, so a
        # trust setting for a certificate that is not installed anywhere
        # is dead weight. Measured: CA trusted but absent from every
        # keychain => "unable to get local issuer certificate".
        keychain = login_keychain
        return if already_trusted?(cert_path, keychain)

        _out, status = Command.capture2("security", "add-trusted-cert",
          "-r", "trustRoot", *MACOS_TRUST_POLICIES, "-k", keychain, cert_path)
        raise CertError, macos_trust_error(cert_path, keychain) unless status.success?
      end

      # `add-trusted-cert` exits 0 for a certificate it merely filed —
      # which is exactly what the policy-less invocation did on every
      # non-elevated install. The exit status is not evidence of trust,
      # only the trust store is: re-read it here, or the state-dir marker
      # records a success no browser will ever agree with.
      return if already_trusted?(cert_path, keychain)

      raise CertError, macos_trust_error(cert_path, keychain)
    end

    def macos_trust_error(cert_path, keychain)
      domain = (keychain == "/Library/Keychains/System.keychain") ? ["-d"] : []
      command = (["security", "add-trusted-cert", *domain, "-r", "trustRoot",
        *MACOS_TRUST_POLICIES, "-k", keychain, cert_path]).join(" ")
      "macOS recorded no trust setting for the CA in #{keychain}. " \
        "Writing user trust settings needs authorization, which a detached " \
        "or headless run cannot grant — run this in a terminal, then retry: " \
        "#{command}"
    end

    # True when macOS will actually honour this certificate as a CA.
    #
    # BOTH halves are required, and the second one is the one that used
    # to be missing:
    #
    #   1. the certificate is in the keychain, so the trust evaluator can
    #      find the issuer when it builds the chain; and
    #   2. the trust store records a trust SETTING for its fingerprint.
    #
    # Presence alone is not trust: a certificate in a keychain with no
    # trust setting fails with CSSMERR_TP_NOT_TRUSTED. Neither is a bare
    # trust-list entry — the key with no `trustSettings` array that
    # `add-trusted-cert` without `-p` leaves behind, which
    # `security dump-trust-settings` counts as zero settings. Requiring
    # a real setting costs one corrective add on a machine that has the
    # bare kind (the add upgrades it in place, without duplicating the
    # certificate) and nothing thereafter, so the stricter reading
    # converges rather than looping.
    #
    # The fingerprint comparison stays: adding a certificate twice is not
    # harmless, and it is how the trust store filled up with duplicates.
    # It is now a necessary condition rather than the whole answer.
    def already_trusted?(cert_path, keychain)
      fp = fingerprint_of(cert_path)
      return false unless fp
      return false unless keychain_fingerprints(keychain, common_name: nil).include?(fp)

      trust_setting?(fp, keychain)
    end

    # The trust settings the OS records, as plist XML, or nil when macOS
    # cannot be asked at all.
    #
    # The trust store is keyed by the certificate's SHA-1 fingerprint —
    # the same identity `security -Z` prints — so this never has to match
    # on a common name, which every yamine CA shares.
    #
    # `security trust-settings-export` is the only `security` subcommand
    # that reports the SETTING rather than the presence:
    # `dump-trust-settings` lists certificates and a count of their
    # settings, `find-certificate` lists certificates. The admin domain
    # needs `-d`; without it only the user's own settings are exported,
    # so a root install would look untrusted forever.
    #
    # The certificate's own key is looked up by the caller, so a store
    # that holds no entry for it comes back as XML WITHOUT it — that is a
    # definite answer (never trusted), not an unreadable one.
    def trust_settings(keychain)
      file = File.join(Dir.tmpdir, "yamine-trust-#{Process.pid}-#{rand(1 << 32)}.plist")
      _out, status = Command.capture2("security", "trust-settings-export",
        *("-d" if keychain == SYSTEM_KEYCHAIN), file)
      return nil unless status.success?

      # Read back through plutil rather than parsing the plist here: it
      # is Apple's own reader, and it keeps this file free of a plist
      # parser (rexml is a bundled gem, unavailable under bundler).
      xml, converted = Command.capture2("plutil", "-convert", "xml1", "-o", "-", file)
      converted.success? ? xml : nil
    rescue SystemCallError
      nil
    ensure
      File.unlink(file) if file && File.file?(file)
    end

    # True when the trust store records a trust SETTING that grants
    # trust for this certificate.
    #
    # Returns TRUE when the trust store cannot be read. That direction
    # is deliberate: a check that always answers "not trusted" turns
    # every boot into a re-add, and a re-add in the user domain can
    # raise a GUI authorization prompt — a worse failure than the one
    # this fixes.
    def trust_setting?(fingerprint, keychain)
      settings = trust_settings(keychain)
      return true if settings.nil?

      entry = plist_dict_after(settings, fingerprint)
      return false unless entry&.include?("<key>trustSettings</key>")

      granted = entry.scan(%r{<key>kSecTrustSettingsResult</key>\s*<integer>(\d+)</integer>}).flatten
      return true if granted.empty? # policies only: defaults to trustRoot

      granted.any? { |result| TRUST_RESULTS.include?(result.to_i) }
    end

    # The `<dict>` that follows `key`, nested dicts included. A
    # trustSettings array is a list of dicts, so a lazy `.*?</dict>`
    # would stop in the middle of the very array being read.
    def plist_dict_after(xml, key)
      at = xml.index("<key>#{key}</key>")
      return nil unless at

      rest = xml[(at + 1)..]
      depth = 0
      rest.scan(/<dict>|<\/dict>/) do
        depth += ($~[0] == "<dict>" ? 1 : -1)
        return rest[0...$~.end(0)] if depth.zero?
      end
      nil
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
