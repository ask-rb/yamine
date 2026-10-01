# frozen_string_literal: true

require_relative "test_helper"

# The root daemon's stdout and stderr went nowhere: the launchd plist
# carried no StandardOutPath/StandardErrorPath, so every dial failure,
# stall and retry the proxy ever reported was discarded by launchd —
# which is how one debugging evening burned on a "backend-refused" the
# backend never issued. The unit now points both streams at the state
# dir's proxy.log, and the daemon rotates it at boot (systemd mirrors
# this with append: redirects in the unit file).
class LaunchdPlistTest < Minitest::Test
  def plist(state_dir: "/Users/dev/.yamine", home: "/Users/dev")
    Yamine::CLI::SystemCommand.launchd_plist(state_dir: state_dir, home: home)
  end

  def test_both_streams_land_in_the_state_dir_log
    out = plist

    assert_includes out, "<key>StandardOutPath</key><string>/Users/dev/.yamine/proxy.log</string>"
    assert_includes out, "<key>StandardErrorPath</key><string>/Users/dev/.yamine/proxy.log</string>"
  end

  def test_plist_still_carries_its_existing_contract
    out = plist

    assert_includes out, Yamine::CLI::SystemCommand::LAUNCHD_LABEL
    assert_includes out, "<key>KeepAlive</key><true/>"
    assert_includes out, "<key>RunAtLoad</key><true/>"
    assert_includes out, "<string>proxy</string><string>start</string><string>--foreground</string>"
    assert_includes out, "<key>YAMINE_STATE_DIR</key><string>/Users/dev/.yamine</string>"
  end

  def test_systemd_unit_appends_both_streams_to_the_same_log
    unit = Yamine::CLI::SystemCommand.systemd_unit(
      state_dir: "/Users/dev/.yamine", home: "/Users/dev")

    assert_includes unit, "StandardOutput=append:/Users/dev/.yamine/proxy.log"
    assert_includes unit, "StandardError=append:/Users/dev/.yamine/proxy.log"
  end
end
