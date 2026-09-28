# frozen_string_literal: true

require "fileutils"

module Yamine
  # The root-owned, version-independent payload the privileged service
  # runs.
  #
  # The root daemon used to execute the gem's bin+lib straight out of
  # the user's home (a version-stamped, user-writable gem directory),
  # so anything that could write those paths — a gem upgrade, a bundle
  # install, an agent editing the gem — ran as root at every boot.
  # Instead the elevated install stages bin+lib once into a root-owned
  # directory at a path that never changes across versions, and the
  # launchd/systemd unit plus the passwordless grant pin only that
  # path. User-space writes can no longer change what runs as root;
  # introducing new root-executed code stays a human-authorized
  # interactive-sudo step (`sudo yamine service install`).
  module PrivilegedPayload
    # Conventional root-owned homes, one leaf name ("yamine") on both
    # platforms: /Library/* is where macOS keeps machine-wide app data,
    # /usr/local/share is the FHS equivalent on Linux.
    MACOS_ROOT = "/Library/Application Support/yamine"
    LINUX_ROOT = "/usr/local/share/yamine"
    KNOWN_PARENTS = ["/Library/Application Support", "/usr/local/share", "/opt"].freeze

    # Test/dev override for the root (the suite redirects it at a
    # tmpdir). Never survives the sudo boundary without SETENV, which
    # the grant does not set — so the passwordless rules always pin
    # the real root, never this.
    ROOT_ENV_VAR = "YAMINE_PRIVILEGED_ROOT"

    VERSIONS_DIRNAME = "versions"
    CURRENT_LINKNAME = "current"
    VERSION_FILENAME = "VERSION"
    ALLOWLIST_FILENAME = "allowed-tlds"

    LAUNCHD_LABEL = "dev.yamine"
    PLIST_PATH = "/Library/LaunchDaemons/dev.yamine.plist"
    UNIT_PATH = "/etc/systemd/system/yamine.service"

    # A version-stamped gem payload: the legacy layout the unit must
    # stop referencing.
    VERSIONED_GEM_PATTERN = %r{/gems/yamine-\d+\.\d+\.\d+/}

    StatInfo = Struct.new(:uid, :mode, :directory)

    module_function

    def root_dir
      override = ENV[ROOT_ENV_VAR]
      return override unless override.nil? || override.empty?

      RUBY_PLATFORM =~ /darwin/ ? MACOS_ROOT : LINUX_ROOT
    end

    def versions_dir(root = root_dir)
      File.join(root, VERSIONS_DIRNAME)
    end

    def current_link(root = root_dir)
      File.join(root, CURRENT_LINKNAME)
    end

    def version_file(root = root_dir)
      File.join(root, VERSION_FILENAME)
    end

    def allowlist_file(root = root_dir)
      File.join(root, ALLOWLIST_FILENAME)
    end

    # The version-independent argv the unit and the grant pin: stable
    # across upgrades, never inside a user home, never version-stamped.
    def bin_path(root = root_dir)
      File.join(current_link(root), "bin", "yamine")
    end

    def gem_root
      File.expand_path("../..", __dir__)
    end

    # The version recorded at staging time, or nil when nothing valid
    # was ever staged.
    def staged_version(root = root_dir)
      path = version_file(root)
      return nil unless File.file?(path)

      version = File.read(path).strip
      version.empty? ? nil : version
    rescue SystemCallError
      nil
    end

    def staged?(root = root_dir)
      File.file?(bin_path(root)) && !staged_version(root).nil?
    end

    # Only ever stage into (or delete) our own payload root. The guard
    # is structural — leaf name plus a known parent, or the explicit
    # test override — so a bug can never turn stage!/remove_payload!
    # into a recursive delete elsewhere.
    def payload_root?(root = root_dir)
      return false unless File.basename(root) == "yamine"

      override = ENV[ROOT_ENV_VAR]
      return true if override && !override.empty? && root == override

      KNOWN_PARENTS.include?(File.dirname(root))
    end

    # Stage bin+lib from the running gem into the payload root:
    # copy to a fresh version dir, lock ownership/modes, verify BEFORE
    # touching the live `current` link, swap the link atomically,
    # record the version marker, prune superseded versions, verify the
    # whole tree again. Raises Error on any failure — the live payload
    # (if any) is left untouched, and no unit is registered against an
    # unverified tree.
    def stage!(version: Yamine::VERSION, root: root_dir, source: gem_root, state_dir: nil)
      raise Error, "refusing to stage into #{root.inspect} — not a yamine payload root" unless payload_root?(root)

      FileUtils.mkdir_p(versions_dir(root))
      dest = File.join(versions_dir(root), version)
      tmp = "#{dest}.staging-#{Process.pid}"
      FileUtils.rm_rf(tmp)
      FileUtils.mkdir_p(tmp)
      begin
        %w[bin lib].each do |entry|
          src = File.join(source, entry)
          raise Error, "cannot stage the privileged payload: #{src} is missing" unless File.exist?(src)

          FileUtils.cp_r(src, tmp)
        end
        normalize_modes!(tmp)
        secure_tree!(tmp)
        verify_tree!(tmp)
        # Promote the verified tree into place, then swing the link:
        # readers always see a complete version dir.
        File.rename(tmp, dest)
        swap_link!(current_link(root), dest)
        write_root_file(version_file(root), "#{version}\n")
        seed_allowlist!(root, state_dir: state_dir)
        prune_versions!(root, keep: dest)
        verify!(root)
      ensure
        FileUtils.rm_rf(tmp)
      end
      version
    end

    # Remove the staged payload: the link, every version dir, the
    # version marker, and the allowlist — each by exact name, so the
    # removal stays scoped to yamine's own files. The root dir itself
    # is left in place.
    def remove_payload!(root = root_dir)
      raise Error, "refusing to remove #{root.inspect} — not a yamine payload root" unless payload_root?(root)

      FileUtils.rm_f(current_link(root))
      FileUtils.rm_rf(versions_dir(root))
      FileUtils.rm_f(version_file(root))
      FileUtils.rm_f(allowlist_file(root))
      true
    end

    # Every path root executes through this payload: the root itself,
    # the entrypoint, the version marker, the allowlist, and each file
    # under the live version dir (symlinks resolved — the check must
    # see the real payload, not the link).
    def root_executed_paths(root = root_dir)
      paths = [root, bin_path(root), version_file(root), allowlist_file(root)]
      target = current_target(root)
      if target && File.directory?(target)
        Dir.glob(File.join(target, "**", "*"), File::FNM_DOTMATCH).each do |path|
          next if [".", ".."].include?(File.basename(path))

          paths << path
        end
      end
      paths.uniq
    end

    def current_target(root = root_dir)
      link = current_link(root)
      return nil unless File.symlink?(link)

      File.realpath(link)
    rescue SystemCallError
      nil
    end

    # Fail closed: every root-executed path must exist, be root-owned,
    # and not be group/other-writable. Raises Error naming each
    # problem; returns true when the tree is safe to register.
    def verify!(root = root_dir)
      problems = []
      paths = root_executed_paths(root)
      missing = paths.reject { |p| File.exist?(p) || File.symlink?(p) }
      problems += missing.map { |p| "#{p} is missing" }
      (paths - missing).each do |path|
        problems << "#{path} is not root-owned" unless root_owned?(path)
        problems << "#{path} is group/other-writable" unless world_safe?(path)
      end
      raise Error, "refusing the privileged payload: #{problems.join("; ")}" unless problems.empty?

      true
    end

    # Single ownership seam (stubbed in tests): follows symlinks so
    # the check always sees the real payload.
    def stat_info(path)
      st = File.stat(path)
      StatInfo.new(st.uid, st.mode, st.directory?)
    end

    def root_owned?(path)
      stat_info(path).uid.zero?
    rescue SystemCallError
      false
    end

    def world_safe?(path)
      (stat_info(path).mode & 0o022).zero?
    rescue SystemCallError
      false
    end

    # The payload argv a unit file references, or nil when the unit
    # does not run yamine at all. Pure string parsing — hermetic.
    def payload_ref_from_plist(xml)
      strings = xml.scan(%r{<string>(.*?)</string>}m).flatten.map(&:strip)
      strings.find { |s| s.end_with?("bin/yamine") }
    end

    def payload_ref_from_unit(text)
      line = text.each_line.find { |l| l.strip.start_with?("ExecStart=") }
      return nil unless line

      line.strip.sub(/\AExecStart=/, "").split(/\s+/)[1]
    end

    # A legacy install: the unit's payload path points into a user
    # home or at a version-stamped gem directory — user-writable code
    # running as root. The staged path is never legacy.
    def legacy_ref?(ref, home: default_home)
      return false if ref.nil? || ref.empty?
      return false if ref == bin_path
      return true if ref.match?(VERSIONED_GEM_PATTERN)
      return true if ref.start_with?(home + "/")

      false
    end

    # Which payload the installed unit (if any) runs: the plist on
    # macOS, the systemd unit on Linux. Nil when no unit is installed
    # or when it references nothing yamine-shaped.
    def installed_payload_ref(plist_path: PLIST_PATH, unit_path: UNIT_PATH)
      if RUBY_PLATFORM =~ /darwin/
        return nil unless File.file?(plist_path)

        begin
          payload_ref_from_plist(File.read(plist_path))
        rescue SystemCallError
          nil
        end
      else
        return nil unless File.file?(unit_path)

        begin
          payload_ref_from_unit(File.read(unit_path))
        rescue SystemCallError
          nil
        end
      end
    end

    def service_unit_present?(plist_path: PLIST_PATH, unit_path: UNIT_PATH)
      path = RUBY_PLATFORM =~ /darwin/ ? plist_path : unit_path
      File.file?(path)
    end

    # Domains hosts sync may write, besides *.localhost (always
    # allowed — RFC 6761 reserves .localhost to loopback, so it can
    # never hijack a real domain). Root-owned and read by the elevated
    # sync, so user-space writes cannot widen it.
    def allowed_tlds(root = root_dir)
      path = allowlist_file(root)
      return ["localhost"] unless File.file?(path)

      ["localhost"] | read_tld_list(path)
    rescue SystemCallError
      ["localhost"]
    end

    # The interpreter the unit runs under, and whether user-space
    # writes can change it. This machine has no root-owned Ruby new
    # enough for the gem, so the daemon necessarily runs a
    # user-writable interpreter today — reported truthfully, never
    # papered over.
    def ruby_info(ruby: RbConfig.ruby, home: default_home)
      { path: ruby, writable: ruby_writable?(ruby, home: home) }
    end

    def ruby_writable?(ruby = RbConfig.ruby, home: default_home)
      return true if ruby.start_with?(home + "/")

      begin
        st = File.stat(ruby)
        return true if st.uid != 0
        return true unless (st.mode & 0o022).zero?

        false
      rescue SystemCallError
        true
      end
    end

    def default_home
      Yamine::Certs.home
    end

    # Staging helpers (public so tests can pin the failure modes, but
    # only ever called from stage! above).

    # Root-own the staged tree and lock modes: dirs 0755, files 0644,
    # the entrypoint 0755. The chown only succeeds as root; anywhere
    # else it is skipped and verify_tree! below fails closed.
    def secure_tree!(dir)
      FileUtils.chown_R(0, 0, dir)
    rescue SystemCallError, ArgumentError
      nil
    end

    def verify_tree!(dir)
      problems = []
      Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).each do |path|
        next if [".", ".."].include?(File.basename(path))

        problems << "#{path} is not root-owned" unless root_owned?(path)
        problems << "#{path} is group/other-writable" unless world_safe?(path)
      end
      raise Error, "refusing the privileged payload: #{problems.join("; ")}" unless problems.empty?

      true
    end

    # dirs keep their copied modes here; normalize explicitly so the
    # staged tree never inherits a permissive umask from the gem dir.
    def normalize_modes!(dir)
      Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).each do |path|
        next if [".", ".."].include?(File.basename(path))

        if File.directory?(path) && !File.symlink?(path)
          File.chmod(0o755, path)
        elsif File.file?(path) && !File.symlink?(path)
          File.chmod(path == File.join(dir, "bin", "yamine") ? 0o755 : 0o644, path)
        end
      end
    rescue SystemCallError => e
      raise Error, "cannot lock down the staged payload: #{e.message}"
    end

    # Atomically point `current` at the new version dir: build the
    # symlink aside, then rename over the old link. Readers (the unit,
    # the grant) always see a complete tree.
    def swap_link!(link, dest)
      tmp_link = "#{link}.link-#{Process.pid}"
      FileUtils.rm_f(tmp_link)
      File.symlink(dest, tmp_link)
      File.rename(tmp_link, link)
    end

    def write_root_file(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      File.chmod(0o644, path)
      FileUtils.chown(0, 0, path)
    rescue SystemCallError, ArgumentError
      nil
    end

    # Seed the root-owned allowlist: localhost plus whatever dev TLDs
    # the machine already serves (union with entries already there —
    # an install never narrows what a human previously allowed).
    def seed_allowlist!(root, state_dir: nil)
      entries = ["localhost"]
      begin
        entries |= read_tld_list(allowlist_file(root)) if File.file?(allowlist_file(root))
      rescue SystemCallError
        nil
      end
      dir = state_dir || Yamine::Certs.state_dir
      tlds_path = File.join(dir, "proxy.tlds")
      begin
        entries |= read_tld_list(tlds_path) if File.file?(tlds_path)
      rescue SystemCallError
        nil
      end
      write_root_file(allowlist_file(root), "#{entries.sort.join("\n")}\n")
    end

    def read_tld_list(path)
      File.readlines(path).map { |l| l.strip.downcase }.reject(&:empty?)
        .select { |t| Yamine::Sanitize.valid_tld?(t) }.uniq
    rescue SystemCallError
      []
    end

    def prune_versions!(root, keep:)
      Dir.glob(File.join(versions_dir(root), "*")).each do |path|
        next if path == keep || path == "#{keep}.staging-#{Process.pid}"

        FileUtils.rm_rf(path) if File.directory?(path)
      end
      Dir.glob(File.join(versions_dir(root), "*.staging-*")).each do |path|
        FileUtils.rm_rf(path)
      end
    end
  end
end
