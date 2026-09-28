# frozen_string_literal: true

require_relative "test_helper"

# The privileged payload: yamine's bin+lib staged into a root-owned,
# version-independent directory, so user-space writes (gem upgrades,
# bundle installs, agents editing the gem) can never change what runs
# as root. Hermetic: the root is redirected to a tmpdir, ownership is
# stubbed — no real sudo, chown, or /Library writes.
class PrivilegedPayloadLayoutTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @root = File.join(@dir, "yamine")
    ENV["YAMINE_PRIVILEGED_ROOT"] = @root
  end

  def teardown
    ENV.delete("YAMINE_PRIVILEGED_ROOT")
    FileUtils.remove_entry(@dir)
  end

  def test_platform_roots_are_conventional_and_share_one_leaf_name
    mac = Yamine::PrivilegedPayload::MACOS_ROOT
    linux = Yamine::PrivilegedPayload::LINUX_ROOT

    assert_equal "yamine", File.basename(mac)
    assert_equal "yamine", File.basename(linux)
    refute_equal mac, linux
    assert_match(%r{\A/Library/}, mac)
    assert_match(%r{\A/usr/local/share/}, linux)
  end

  def test_bin_path_is_version_independent
    bin = Yamine::PrivilegedPayload.bin_path

    assert_equal File.join(@root, "current", "bin", "yamine"), bin
    refute_match(/0\.20\.0|#{Regexp.escape(Yamine::VERSION)}/, bin)
    refute_match(%r{/gems/yamine-}, bin)
  end

  def test_stage_copies_bin_and_lib_and_records_the_version
    Yamine::PrivilegedPayload.stubs(:root_owned?).returns(true)

    version = Yamine::PrivilegedPayload.stage!

    assert_equal Yamine::VERSION, version
    assert File.file?(File.join(@root, "current", "bin", "yamine")),
      "the staged entrypoint must exist behind the stable path"
    assert File.file?(File.join(@root, "current", "lib", "yamine.rb")),
      "the staged payload must carry the gem's lib"
    assert_equal Yamine::VERSION, File.read(File.join(@root, "VERSION")).strip
    assert_equal version, Yamine::PrivilegedPayload.staged_version
    assert File.executable?(File.join(@root, "current", "bin", "yamine")),
      "the staged entrypoint must stay executable"
  end

  def test_stage_swap_is_atomic_and_old_versions_are_pruned
    Yamine::PrivilegedPayload.stubs(:root_owned?).returns(true)

    Yamine::PrivilegedPayload.stage!(version: "0.1.0")
    first_target = File.realpath(File.join(@root, "current"))
    Yamine::PrivilegedPayload.stage!(version: "0.2.0")

    assert_equal File.realpath(File.join(@root, "versions", "0.2.0")), File.realpath(File.join(@root, "current"))
    refute File.exist?(first_target), "the previous version dir must be pruned"
    assert_equal "0.2.0", Yamine::PrivilegedPayload.staged_version
  end

  def test_verify_fails_closed_when_a_path_is_not_root_owned
    Yamine::PrivilegedPayload.stubs(:root_owned?).returns(true)
    Yamine::PrivilegedPayload.stage!
    Yamine::PrivilegedPayload.stubs(:root_owned?).returns(false)

    err = assert_raises(Yamine::Error) { Yamine::PrivilegedPayload.verify! }

    assert_match(/not root-owned/i, err.message)
  end

  def test_verify_fails_closed_when_a_path_is_group_writable
    Yamine::PrivilegedPayload.stubs(:root_owned?).returns(true)
    Yamine::PrivilegedPayload.stage!
    bin = File.join(@root, "current", "bin", "yamine")
    File.chmod(0o775, bin)

    err = assert_raises(Yamine::Error) { Yamine::PrivilegedPayload.verify! }

    assert_match(/writable/i, err.message)
  end

  def test_stage_refuses_a_non_payload_root
    ENV["YAMINE_PRIVILEGED_ROOT"] = File.join(@dir, "evil")

    assert_raises(Yamine::Error) { Yamine::PrivilegedPayload.stage! }
  end

  def test_remove_payload_deletes_only_yamines_own_files
    Yamine::PrivilegedPayload.stubs(:root_owned?).returns(true)
    Yamine::PrivilegedPayload.stage!
    sentinel = File.join(@dir, "keep-me")
    File.write(sentinel, "1")

    Yamine::PrivilegedPayload.remove_payload!

    refute File.exist?(File.join(@root, "current"))
    refute File.exist?(File.join(@root, "VERSION"))
    refute File.exist?(File.join(@root, "versions"))
    assert File.file?(sentinel), "removal must stay scoped to the payload root"
  end

  def test_remove_payload_refuses_a_non_payload_root
    ENV["YAMINE_PRIVILEGED_ROOT"] = File.join(@dir, "evil")

    assert_raises(Yamine::Error) { Yamine::PrivilegedPayload.remove_payload! }
  end
end

class LegacyPayloadDetectionTest < Minitest::Test
  def staged
    Yamine::PrivilegedPayload.bin_path
  end

  def test_version_stamped_gem_path_is_legacy
    ref = File.expand_path("~/.local/share/mise/installs/ruby/3.4.4/lib/ruby/gems/3.4.0/gems/yamine-0.20.0/bin/yamine")

    assert Yamine::PrivilegedPayload.legacy_ref?(ref), "a version-stamped gem payload is the legacy layout"
  end

  def test_user_home_payload_is_legacy
    home = Yamine::Certs.home
    ref = File.join(home, ".yamine-dev", "bin", "yamine")

    assert Yamine::PrivilegedPayload.legacy_ref?(ref)
  end

  def test_staged_path_is_not_legacy
    refute Yamine::PrivilegedPayload.legacy_ref?(staged)
  end

  def test_plist_payload_ref_extraction
    xml = <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0">
      <dict>
        <key>Label</key><string>dev.yamine</string>
        <key>ProgramArguments</key>
        <array>
          <string>/Users/kaka/.local/share/mise/installs/ruby/3.4.4/bin/ruby</string>
          <string>/Users/kaka/.local/share/mise/installs/ruby/3.4.4/lib/ruby/gems/3.4.0/gems/yamine-0.20.0/bin/yamine</string>
          <string>proxy</string><string>start</string><string>--foreground</string>
          <string>--port</string><string>443</string>
        </array>
      </dict>
      </plist>
    PLIST

    ref = Yamine::PrivilegedPayload.payload_ref_from_plist(xml)

    assert_match(%r{gems/yamine-0\.20\.0/bin/yamine\z}, ref)
    assert Yamine::PrivilegedPayload.legacy_ref?(ref)
  end

  def test_systemd_payload_ref_extraction
    unit = <<~UNIT
      [Service]
      ExecStart=/home/kaka/.local/share/mise/shims/ruby /home/kaka/.local/share/mise/installs/ruby/3.4.4/lib/ruby/gems/3.4.0/gems/yamine-0.19.0/bin/yamine proxy start --foreground --port 443
    UNIT

    ref = Yamine::PrivilegedPayload.payload_ref_from_unit(unit)

    assert_match(%r{gems/yamine-0\.19\.0/bin/yamine\z}, ref)
    assert Yamine::PrivilegedPayload.legacy_ref?(ref)
  end

  def test_staged_plist_ref_is_not_legacy
    xml = <<~PLIST
      <array>
        <string>/usr/bin/ruby</string>
        <string>#{staged}</string>
        <string>proxy</string>
      </array>
    PLIST

    refute Yamine::PrivilegedPayload.legacy_ref?(
      Yamine::PrivilegedPayload.payload_ref_from_plist(xml))
  end
end
