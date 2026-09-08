# frozen_string_literal: true

require_relative "test_helper"

class TrustTest < Minitest::Test
  # untrust on macOS must not raise NameError: the CA common name lives in
  # Ask::Local::Certs, and the delete-certificate loop has to reach it
  # (regression: bare CA_COMMON_NAME raised NameError, so `ask-local clean`
  # crashed mid-untrust). The security commands run for real here but are
  # harmless — deleting a certificate that isn't in the keychain is a
  # silent no-op, and untrust rescues and reports failures.
  def setup
    @dir = Dir.mktmpdir
    Ask::Local::Certs.ensure_ca(@dir)
    Ask::Local::Certs.mark_trusted(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_untrust_macos_reaches_delete_certificate_without_name_error
    Ask::Local::Trust.stubs(:platform).returns(:macos)
    Ask::Local::Trust.stubs(:login_keychain).returns("login.keychain-db")

    result = Ask::Local::Trust.untrust(@dir)

    refute_includes result[:error].to_s, "NameError",
      "untrust must not crash on a missing CA_COMMON_NAME constant"
    assert_includes result[:error].to_s, "CA still trusted",
      "with real keychains untouched, untrust reports the CA remains trusted"
  end

  def test_untrust_windows_uses_qualified_common_name_without_name_error
    Ask::Local::Trust.stubs(:platform).returns(:windows)

    result = Ask::Local::Trust.untrust(@dir)

    refute_includes result[:error].to_s, "NameError",
      "untrust must not crash on a missing CA_COMMON_NAME constant"
  end
end
