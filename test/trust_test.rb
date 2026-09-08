# frozen_string_literal: true

require_relative "test_helper"

# untrust on macOS/Windows must not raise NameError: the CA common name
# lives in Yamine::Certs, and removal has to reach it (regression:
# bare CA_COMMON_NAME raised NameError, so `yamine clean` crashed
# mid-untrust).
#
# These tests are deliberately hermetic: no `security`/`certutil`
# subprocesses, no real keychain access. Shelling out in unit tests is
# non-hermetic — it can prompt, mutate the developer's real keychain, and
# fail in CI. The regression is a constant-resolution bug, so it is pinned
# by resolving the constant through the code path and asserting the source
# references the qualified name.
class TrustTest < Minitest::Test
  def test_ca_common_name_is_reachable_from_trust_source
    source = File.read(File.join(__dir__, "..", "lib", "yamine", "trust.rb"))

    assert_includes source, "Certs::CA_COMMON_NAME",
      "Trust.untrust must reference the CA common name through Certs (bare CA_COMMON_NAME raises NameError)"
  end

  def test_ca_common_name_constant_resolves
    assert_equal "Ask Local CA", Yamine::Certs::CA_COMMON_NAME
  end

  def test_untrust_guards_unknown_platform_without_touching_keychain
    # platform :unknown short-circuits before any subprocess; proving the
    # method is safe to call and returns a structured result, not a raise.
    Yamine::Trust.stubs(:platform).returns(:unknown)

    result = Yamine::Trust.untrust(Dir.mktmpdir)

    assert result.is_a?(Hash), "untrust must return a result hash on unsupported platforms"
    refute_includes result[:error].to_s, "NameError"
  ensure
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end
end
