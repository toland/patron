require 'thread'

class Fork
  def initialize(&block)
    @mu = Mutex.new
    @cond = ConditionVariable.new
    @pstate = nil
    @pid = Process.fork(&block)
    @killed = false

    # Start monitoring the PID.
    Thread.new { monitor }

    # Kill the process anyway when the program exits.
    ppid = Process.pid
    at_exit do
      if ppid == Process.pid # Make sure we are not inside another fork spawned by rspec example.
        do_kill("KILL")
      end
    end
  end

  # Wait for process to exit.
  def wait(timeout = nil)
    @mu.synchronize do
      next @pstate unless @pstate.nil?

      @cond.wait(@mu, timeout)
      @pstate
    end
  end

  # Signal the process.
  def kill(sig)
    already_killed = @mu.synchronize do
      old = @killed
      @killed = true
      old
    end
    signaled = do_kill(sig)
    Thread.new { reaper } if signaled && !already_killed
    signaled
  end

  private

  # Signal the process.
  def do_kill(sig)
    Process.kill(sig, @pid)
    true
  rescue Errno::ESRCH # No such process
    false
  end

  # Monitor the process state.
  def monitor
    _, pstate = Process.wait2(@pid)

    @mu.synchronize do
      @pstate = pstate
      @cond.broadcast
    end
  end

  # Wait 500 milliseconds and force terminate.
  def reaper
    pstate = wait(0.5)
    do_kill("KILL") unless pstate
  end
end
