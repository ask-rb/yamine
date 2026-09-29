# frozen_string_literal: true

module Yamine
  # Stopping a spawned process AND everything it started.
  #
  # Every run-mode process is spawned as ["sh", "-c", cmd] (see
  # BootCommand.collect_spawns), so the pid yamine owns is the SHELL and
  # the app is the shell's child. Signalling that pid alone is not
  # stopping the app: on linux the shell's child is outside the shell's
  # own signal scope, so TERM to the shell leaves the app running,
  # reparented to init. `yamine stop` reports "Stopped <host>" and the
  # app goes on serving, the route is gone, and nothing holds a handle
  # to the process anymore. macOS forwards the signal, which is why a
  # linux-only defect stayed invisible to the unit suite.
  #
  # Two halves, and the second is only safe with the first:
  #   * spawn each process as its own group leader (pgroup: true), so
  #     the whole tree shares a group that dies together;
  #   * signal the GROUP (-pid), which reaches the shell and every
  #     descendant in one syscall.
  #
  # A negative pid means "the process group whose id is that number",
  # not "this process and its children" — so it is only correct for a
  # pid that actually LEADS a group, and the two ways to know that are
  # not equally good.
  #
  # The kernel can be asked, and it is the only option for a pid that
  # came from a file (`yamine stop` and `yamine worktree remove` run in
  # a different process than the spawn, with nothing but a pid from a
  # route entry or a sidecar). But that is a reading, and it has two
  # ways of being wrong:
  #
  #   * ESRCH. The pid is gone — yet a process group outlives its
  #     leader, and the members behind it are exactly what needs
  #     stopping: a `sh -c` shell that died on its own leaves the app
  #     running in its group with nothing left to signal it by pid. A
  #     dead leader answers ESRCH, which reads exactly like "leads no
  #     group".
  #
  #   * "Same group as me". A pid that never led a group answers this
  #     (a directly-spawned puma), and so does one of ours that has not
  #     run its setpgid yet — `pgroup: true` puts that in the child, so
  #     whether the parent can look first is a property of the spawn
  #     path, not something to bet a stop on.
  #
  # So a process spawned through `ProcessTree.spawn` is recorded as a
  # leader, and the record is a fact about what we asked for rather than
  # a reading of the moment. Everything else is the kernel's answer, and
  # a pid number on its own is never evidence: 1234 may be a live
  # process that inherited its group, and `kill(-1234)` would then hit
  # whatever unrelated group wears that id.
  module ProcessTree
    # Pids we spawned as group leaders. A plain Hash, deliberately
    # unlocked: every operation on it is a single call the GVL makes
    # atomic, and yamine stops its processes from inside a trap handler
    # (BootCommand.trap_cleanup), where Mutex#synchronize raises
    # "can't be called from trap context" — a stop path that only works
    # outside a trap is a stop that never happens on Ctrl-C.
    PGROUP_LEADERS = {}
    # Exit statuses of what we spawned, by pid, filled in by the reaper
    # that `detach` starts. Same reasoning, same shape, and the same
    # bounded cost as PGROUP_LEADERS above: an entry is a few dozen bytes
    # per process this one ever spawned, dropped by `forget` whenever
    # the pid is signalled.
    STATUSES = {}

    module_function

    # Spawn a child and reap it without blocking us, keeping what it
    # exited with. A drop-in for Process.detach — nobody waits on a live
    # backend, a dead pid is all the boot needs — that also keeps the one
    # thing only a reaper can know. Without it the answer dies with the
    # child: `kill(0, pid)` says a process is gone and nothing says
    # whether it exited 0 or was killed, so "web is down" is all a
    # supervisor could ever report.
    #
    # Unlocked, like PGROUP_LEADERS, and a Hash read from a supervision
    # thread: every operation is a single call the GVL makes atomic.
    def detach(pid)
      return pid unless pid.to_i.positive?

      Thread.new do
        _waited, status = ::Process.waitpid2(pid)
        STATUSES[pid] = status
      rescue SystemCallError
        nil
      end
      pid
    end

    # Process::Status for a pid we spawned, or nil when there is nothing
    # to report: not our child, or it has not been reaped yet.
    #
    # Never blocks, which is the whole point — the caller is a loop that
    # has other routes to watch, and asking a live child how it is doing
    # would hang it. So a status that has not arrived yet is nil, and the
    # caller asks again on its next pass.
    def status(pid)
      recorded = STATUSES[pid]
      return recorded if recorded

      # Not one of ours to have reaped (a pid out of a route entry, a
      # double in a test): ask the kernel. WNOHANG so a live pid is not
      # waited on, and ECHILD — which is the answer for anything that is
      # not a child of ours — is a nil, not a failure.
      _waited, status = ::Process.waitpid2(pid, ::Process::WNOHANG)
      status
    rescue StandardError
      nil
    end

    # Spawn a boot process as its own group leader and record that it is
    # one. This is the only place a boot process is created, so "every
    # process we boot leads a group" is one fact in one place rather
    # than a convention spread across spawns.
    def spawn(*args, **opts)
      pid = ::Process.spawn(*args, pgroup: true, **opts)
      note_group_leader(pid)
      pid
    end

    # A pid we spawned with pgroup: true leads its own group — that is
    # what we asked for, so the kernel is not consulted. Two readings it
    # could give are both wrong here: "still in my group" while the
    # child has not run its setpgid, and ESRCH once it is gone while
    # the members it left behind are still running.
    def note_group_leader(pid)
      return unless pid.to_i.positive?

      PGROUP_LEADERS[pid] = true
    end

    def known_group_leader?(pid)
      PGROUP_LEADERS.key?(pid)
    end

    # Drop every record of a pid we have finished with. Both tables are
    # about a spawn, not about a number that has to keep meaning one:
    # leaving them behind is how a pid that later gets recycled gets
    # signalled as a group it never led, or reported with an exit status
    # that belongs to somebody else.
    def forget(pid)
      PGROUP_LEADERS.delete(pid)
      STATUSES.delete(pid)
    end

    # Does this pid lead its own process group? Ours, if we spawned it.
    # Otherwise the kernel — and its "no" is the answer we want: a dead
    # pid and a process that inherited its group are exactly the pids
    # that must be signalled on their own, never by group id.
    def group_leader?(pid)
      return true if known_group_leader?(pid)

      Process.getpgid(pid) == pid
    rescue SystemCallError
      false
    end

    # TERM a spawned process and its whole tree. Returns true when the
    # signal was delivered, false when there was nothing left to signal
    # (already dead, or a pid we may not touch) — which is the end
    # state every caller wants, not an error, so this never raises.
    def term(pid, signal: "TERM")
      return false unless pid.to_i.positive?

      group_signal(pid, signal) || pid_signal(pid, signal)
    ensure
      # The record is about a spawn, not about a pid that must keep
      # this meaning: dropping it here keeps a pid that later gets
      # recycled from being signalled as a group it never led.
      forget(pid) if pid.to_i.positive?
    end

    # The whole group, one syscall. Best-effort: returns false when
    # there is no such group left, so the caller can fall back.
    def group_signal(pid, signal)
      return false unless group_leader?(pid)

      Process.kill(signal, -pid)
      true
    rescue SystemCallError
      # ESRCH: the group outlived neither the leader nor its members.
      # EPERM: the group exists but is not ours to signal. Either way a
      # single-pid signal is the last thing left to try.
      false
    end

    def pid_signal(pid, signal)
      Process.kill(signal, pid)
      true
    rescue SystemCallError
      false
    end

    # Stop a tree and make sure it is GONE — for the callers that go on
    # to delete the directory it runs in, drop the route, or report
    # "Stopped <host>". `term` alone is not that promise: it hands the
    # signal to the group and returns, and the kernel's sweep covers
    # the members that exist at that instant. A `sh -c` shell that is
    # still assembling its tree forks its app *after* the sweep, and
    # that app never sees the signal at all.
    #
    # Measured on linux: TERM the group of a `sh -c "ruby <app>"` a
    # few milliseconds after the spawn and the shell dies while the app
    # comes up behind it, reparented to init and serving forever —
    # a live process whose working directory is on the way out, which
    # is the exact shape of the bug this module exists to kill. A stop
    # that only asks cannot rule that out, so this asks and then
    # insists: TERM, give the group a moment to leave on its own
    # terms, KILL whatever is still in it.
    #
    # The liveness question is asked of the GROUP, not of the pid: a
    # dead leader that is a zombie still answers `kill(0, pid)`, and a
    # live tree behind one does not answer to its pid at all. The group
    # is the only handle that tells the two apart.
    #
    # `term` is deliberately left alone: it is the primitive a signal
    # trap handler uses (BootCommand.trap_cleanup), and a trap handler
    # must not sit in a sleep loop.
    def terminate(pid, grace: 5)
      return false unless term(pid)

      deadline = monotonic + grace
      sleep 0.05 while group?(pid) && monotonic < deadline
      return true unless group?(pid)

      # A group that outlived its grace period is not draining, it is
      # stuck or ignoring us, and the caller is about to delete what it
      # runs in. No group_leader? check here: the leader is very likely
      # already gone, and it is the members behind it that need the
      # signal.
      Process.kill("KILL", -pid)
      true
    rescue SystemCallError
      # The group went away between the last look and this signal.
      true
    end

    # Does this process group still have a member in it? Signal 0 asks
    # the kernel about the group rather than about a pid, so it stays
    # true while anything behind a dead leader is still running, and
    # goes false only once the tree really is down.
    def group?(pid)
      return false unless pid.to_i.positive?

      Process.kill(0, -pid)
      true
    rescue SystemCallError
      false
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
