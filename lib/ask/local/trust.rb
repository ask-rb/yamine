# frozen_string_literal: true

require "open3"

module Ask
  module Local
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

      def trust_macos(cert_path)
        if Process.uid.zero?
          # Running elevated (service install / root proxy): add to the
          # System keychain with the admin (-d) domain. Root can modify it
          # silently — no GUI authorization popup, and every user's
          # browsers trust the proxy.
          _out, status = Command.capture2("security", "add-trusted-cert",
            "-d", "-r", "trustRoot", "-k", "/Library/Keychains/System.keychain", cert_path)
          raise CertError, "security add-trusted-cert (system) failed" unless status.success?
        else
          keychain = login_keychain
          _out, status = Command.capture2("security", "add-trusted-cert",
            "-r", "trustRoot", "-k", keychain, cert_path)
          raise CertError, "security add-trusted-cert failed" unless status.success?
        end
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
        FileUtils.cp(cert_path, File.join(dest_dir, "ask-local-ca.crt"))
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
        errors = []
        case platform
        when :macos
          Command.capture2("security", "remove-trusted-cert", paths[:cert])
          # delete-certificate fails silently when no match remains; loop
          # to clear duplicate CN entries from each keychain.
          [login_keychain, "/Library/Keychains/System.keychain"].each do |kc|
            5.times do
              Command.capture2("security", "delete-certificate", "-c", Certs::CA_COMMON_NAME, kc)
            end
          rescue SystemCallError
            nil
          end
        when :linux
          dest_dir, update_cmd = linux_ca_config
          dest = File.join(dest_dir, "ask-local-ca.crt")
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
end
