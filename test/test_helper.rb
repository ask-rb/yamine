# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "yamine"
require "minitest/autorun"
require "mocha/minitest"
require "tmpdir"
require "fileutils"

# Every `git commit` spawns `git maintenance run --auto --quiet --detach`, a
# background child that creates and then removes .git/objects/maintenance.lock
# and .git/gc.pid in the repo it just wrote to. Tests build throwaway repos and
# then hand them straight to FileUtils.remove_entry (directly, or via
# Dir.mktmpdir's block form), so the cleanup walk can collide with that detached
# child: FileUtils stats a lock file, and by the time it unlinks it the child has
# already renamed it away -> Errno::ENOENT from apply2files. It surfaced as an
# intermittent failure attributed to whichever test happened to be running.
#
# maintenance.auto=false stops git spawning that child at all. Verified on
# git 2.53: gc.auto=0, gc.autoDetach=false and maintenance.autoDetach=false all
# still spawn it -- only maintenance.auto=false removes the spawn.
#
# Applied as an env overlay (GIT_CONFIG_*) so every git subprocess the suite
# starts inherits it, including the detached ones. It is a command-line overlay,
# so nothing is written into any test repo's on-disk .git/config, and no test
# asserts on git config output.
ENV["GIT_CONFIG_COUNT"] = "1"
ENV["GIT_CONFIG_KEY_0"] = "maintenance.auto"
ENV["GIT_CONFIG_VALUE_0"] = "false"
