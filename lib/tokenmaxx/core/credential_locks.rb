# frozen_string_literal: true

require "fileutils"

module TokenMaxx
  module Core
    # Cross-process locks that serialize OAuth renewal with every other client
    # that renews the same credential file. Two kinds exist in the wild:
    #
    # - `:mkdir`: the proper-lockfile protocol Claude Code uses. The lock is a
    #   directory created atomically; its holder refreshes its mtime, and a lock
    #   whose mtime is older than `stale` seconds belongs to a dead holder and may
    #   be taken over.
    # - `:flock`: an advisory `flock(2)` on a plain file (Hermes, TokenMaxx).
    module CredentialLocks
      class Busy < StandardError; end

      MKDIR_STALE_SECONDS = 60
      MKDIR_TOUCH_SECONDS = 5
      ATTEMPTS = 8
      RETRY_DELAY_SECONDS = (1.0..2.0)

      module_function

      # Holds every lock in `specs` (in order) for the duration of the block.
      # Raises Busy when a lock stays held by a live holder.
      def with_locks(specs, sleeper: ->(seconds) { sleep(seconds) }, &block)
        return yield if specs.empty?

        spec, *rest = specs
        acquire(spec, sleeper) { with_locks(rest, sleeper: sleeper, &block) }
      end

      def acquire(spec, sleeper, &block)
        case spec.fetch(:kind)
        when :mkdir then with_mkdir_lock(spec.fetch(:path), spec.fetch(:stale, MKDIR_STALE_SECONDS), sleeper, &block)
        when :flock then with_flock(spec.fetch(:path), sleeper, &block)
        else raise ArgumentError, "Unknown credential lock kind: #{spec[:kind].inspect}"
        end
      end

      def with_mkdir_lock(path, stale, sleeper)
        FileUtils.mkdir_p(File.dirname(path))
        ATTEMPTS.times do |attempt|
          if try_mkdir(path, stale)
            toucher = start_toucher(path)
            begin
              return yield
            ensure
              toucher.kill
              FileUtils.rm_rf(path)
            end
          end
          sleeper.call(rand(RETRY_DELAY_SECONDS)) if attempt < ATTEMPTS - 1
        end
        raise Busy, "Another client is renewing these credentials (#{path})."
      end

      def try_mkdir(path, stale)
        Dir.mkdir(path)
        true
      rescue Errno::EEXIST
        return false unless stale_lock?(path, stale)

        FileUtils.rm_rf(path)
        begin
          Dir.mkdir(path)
          true
        rescue Errno::EEXIST
          false
        end
      end

      def stale_lock?(path, stale)
        Time.now - File.mtime(path) > stale
      rescue Errno::ENOENT
        true
      end

      def start_toucher(path)
        Thread.new do
          loop do
            sleep(MKDIR_TOUCH_SECONDS)
            now = Time.now
            File.utime(now, now, path)
          end
        rescue Errno::ENOENT
          nil
        end
      end

      def with_flock(path, sleeper)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
          ATTEMPTS.times do |attempt|
            return yield if file.flock(File::LOCK_EX | File::LOCK_NB)

            sleeper.call(rand(RETRY_DELAY_SECONDS)) if attempt < ATTEMPTS - 1
          end
          raise Busy, "Another client is renewing these credentials (#{path})."
        end
      end
    end
  end
end
