# frozen_string_literal: true

require "fileutils"

module Yamine
  class CLI
    # Manages the yamine SKILL.md copy in conventional skill directories.
    #
    # The bundled skill lives inside the gem at lib/ask/skills/yamine/SKILL.md.
    # With ask-skills / ask-agent it is auto-discovered. Without them, users
    # still need it where harnesses look — most commonly ~/.agents/skills/.
    # This command handles that copy so nobody has to find the gem path by hand.
    module SkillsCommand
      module_function

      SKILL_NAME = "yamine"
      SOURCE_REL = "ask/skills/yamine/SKILL.md"

      # Keeps installed copies in sync after `gem update yamine`. Called
      # once per yamine invocation, silently, before the subcommand runs.
      # Only touches copies that were created by `yamine skills install`
      # (identified by the marker file next to SKILL.md) so a hand-copied
      # or hand-edited skill is never overwritten. Failures are swallowed
      # — a stale skill is better than a broken boot.
      def auto_sync
        candidates.each do |dest|
          next unless File.file?(dest)
          next unless managed?(dest)
          sync_copy(dest)
        end
      rescue StandardError
        nil
      end

      def run(_ctx, args)
        sub = args.shift
        if sub == "--help" || sub == "-h" || sub.nil?
          return install(["--help"])
        end
        case sub
        when "install" then install(args)
        when "uninstall" then uninstall(args)
        when nil
          raise Error, "Usage: yamine skills install [--global] [--local] [--dir <path>] | " \
            "yamine skills uninstall [--global] [--local] [--dir <path>]"
        else
          raise Error, "Unknown skills subcommand #{sub.inspect}. " \
            "Try: yamine skills install --global"
        end
      end

      def install(args)
        opts, rest = take_flags(args)
        unless rest.empty?
          raise Error, "Unknown argument #{rest.first.inspect}. " \
            "Try: yamine skills install --global"
        end
        dest = target_dirs(opts).first
        source = bundled_skill_path
        unless File.file?(source)
          raise Error, "Bundled skill not found at #{source} — reinstall yamine"
        end
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(source, dest)
        stamp(dest)
        puts "Installed yamine skill -> #{dest}"
        if opts[:dir].nil? && !opts[:local]
          collisions = other_skill_dirs(opts)
          existing = collisions.select { |p| File.file?(p) }
          unless existing.empty?
            puts "Note: also found at #{existing.join(", ")} (yamine is already available there)"
          end
        end
        0
      end

      def uninstall(args)
        opts, rest = take_flags(args)
        unless rest.empty?
          raise Error, "Unknown argument #{rest.first.inspect}."
        end
        dest = target_dirs(opts).first
        if File.file?(dest)
          FileUtils.rm(dest)
          FileUtils.rm_f(managed_marker(dest))
          puts "Removed #{dest}"
        else
          puts "Not installed at #{dest} (nothing to do)"
        end
        0
      end

      def target_dirs(opts)
        return [File.expand_path(File.join(opts[:dir], SKILL_NAME, "SKILL.md"))] if opts[:dir]

        if opts[:local]
          [File.join(Dir.pwd, ".agents", "skills", SKILL_NAME, "SKILL.md")]
        else
          [File.expand_path("~/.agents/skills/#{SKILL_NAME}/SKILL.md")]
        end
      end

      def other_skill_dirs(opts)
        [
          File.join(Dir.pwd, ".agents", "skills", SKILL_NAME, "SKILL.md"),
          File.expand_path("~/.agents/skills/#{SKILL_NAME}/SKILL.md"),
          File.expand_path("~/.config/ask/skills/#{SKILL_NAME}/SKILL.md")
        ].reject { |p| p == target_dirs(opts).first }
      end

      def bundled_skill_path
        File.expand_path("../../ask/skills/yamine/SKILL.md", __dir__)
      end

      def managed_marker(dest)
        File.join(File.dirname(dest), ".yamine-managed")
      end

      def managed?(dest)
        File.file?(managed_marker(dest))
      end

      def stamp(dest)
        File.write(managed_marker(dest), "managed by yamine skills install; safe to auto-update\n")
      rescue StandardError
        nil
      end

      def candidates
        [
          File.expand_path("~/.agents/skills/#{SKILL_NAME}/SKILL.md"),
          File.join(Dir.pwd, ".agents", "skills", SKILL_NAME, "SKILL.md")
        ]
      end

      def sync_copy(dest)
        source = bundled_skill_path
        FileUtils.cp(source, dest) if File.exist?(source) && File.read(source) != File.read(dest)
        stamp(dest)
      rescue StandardError
        nil
      end

      def take_flags(args)
        opts = {}
        rest = []
        i = 0
        while i < args.length
          arg = args[i]
          case arg
          when "--local"
            opts[:local] = true
            i += 1
          when "--global"
            i += 1
          when "--dir"
            opts[:dir] = args.fetch(i + 1) { raise Error, "--dir needs a path" }
            i += 2
          when "--help", "-h"
            puts <<~HELP
              yamine skills install   Install the yamine SKILL.md into your skills directories

              Usage:
                yamine skills install [--global]   -> ~/.agents/skills/yamine/SKILL.md (default)
                yamine skills install --local      -> .agents/skills/yamine/SKILL.md
                yamine skills install --dir <path> -> <path>/yamine/SKILL.md

              The skill is already bundled at lib/ask/skills/yamine/SKILL.md inside the gem.
              Most harnesses discover ~/.agents/skills/ automatically. Use --local for per-project.

              Other subcommands:
                yamine skills uninstall [--global|--local|--dir <path>]
            HELP
            exit 0
          when /\A--/
            raise Error, "Unknown flag #{arg} for yamine skills install. " \
              "Try --global, --local, or --dir <path>."
          else
            rest << arg
            i += 1
          end
        end
        [opts, rest]
      end
    end
  end
end
