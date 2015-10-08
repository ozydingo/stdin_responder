# StdinResponder
# Monitor stdout and/or stderr, and feed responses to stdin based on rules
#
# EXAMPLE
# require "./stdin_responder.rb"
# r = StdinResponder.new
# r.add_rule /sudo/ => "Okay.", default: "What? Make it yourself.", repeat: Float::INFINITY
# r.run("./sandwich")
#
# RULES:
# Each rule is a Hash. Keys added to the Rule determine how the Rule
# behaves given a particular stdout buffer. Keys can be:
# Regexp: if stdout buffer matches the regexp, the value is used
# Proc / Lambda: till be called with the stdout buffer as an argument.
#   if the Proc return a truthy value, the value is used
# String: If the stdout buffer's last non-empty line matches the 
#   String exactly, the value is used
#
# The first key that results in a match will be the only key used.
#
# Each Rule also has two command symbols as keys, :default and :repeat
# :default gives the value to be used if no other keys match
# :repeat is the number of times to re-use this rule before discarding it
#
# A Rule value gets used depending on its type.
# String: puts the value to stdin
# Proc: call with the current stdout buffer as an arg. Results is
#   puts'd to stdin
# Three command symbols may be used as values:
# :wait - put the rule back on the stack and wait
# :skip - discard the rule and immediately proceed to the next one
# :abort - terminate execution
# Any other value will be converted to a String and puts'd to stdin
#
# Other rule examples:
# r.add_rule /connecting/ => :wait, /access.*denied/i => :abort, /access.*granted/i => "echo 'hello, world'"
# r.add_rule /do you want to save/i => 'y', default: :skip


require 'open4'

class StdinResponder

  attr_reader :rules

  def initialize(merge_stderr: false, prompt_delay_threshold: 1.0, timeout: 120, verbose: true, debug: false)
    @rules = []
    @stdout_buffer = ""
    @stderr_buffer = merge_stderr ? @stdout_buffer : ""
    @stdin_buffer = ""
    @prompt_delay_threshold = prompt_delay_threshold
    @timeout = timeout
    @verbose = verbose
    @debug = debug
  end

  def add_rule(rule)
    @rules << {default: "", repeat: 0}.merge(rule)
  end

  def run(command)
    @session_rules = @rules.dup
    pid, stdin, stdout, stderr = Open4.popen4(command)

    out_buffer = ""
    prompt_threshold = 1

    @stdout_thread = Thread.start do
      monitor_stdout(stdout)
    end

    @stderr_thread = Thread.start do
      monitor_stderr(stderr)
    end

    @stdin_thread = Thread.start do
      generate_responses(stdin)
    end

    master_thread = Thread.start do
      monitor_threads
    end

    @stdout_thread.abort_on_exception = true
    @stderr_thread.abort_on_exception = true
    @stdin_thread.abort_on_exception = true
    master_thread.abort_on_exception = true

    @stdout_thread.join
    @stderr_thread.join
    stdout.close
    stderr.close

    @stdin_thread.join
    stdin.close
  end

  private

  def monitor_stdout(outstream)
    outstream.each_char do |c|
      @stdout_buffer << c
    end
  end    

  def monitor_stderr(outstream)
    outstream.each_char do |c|
      @stderr_buffer << c
    end
  end

  def monitor_threads
    if ![@stdout_thread, @stderr_thread, @stdin_thread].all?(&:alive?)
      abort_threads
    end
  end

  def generate_responses(instream)
    t0 = Time.now
    read_buffer = ""

    while @stdout_thread.alive? do
      current_output = consume_stdout
      if !current_output.empty?
        # Found new output, put it in our read_buffer and reset the timer
        t0 = Time.now
        print current_output if @verbose
        read_buffer << current_output
      elsif Time.now - t0 > @prompt_delay_threshold
        # No new input and we've been waiting long enough to respond
        rule = next_rule
        puts "dt = #{Time.now - t0}, applying #{rule}" if @debug
        response = determine_response(rule, read_buffer)
        puts "Response: #{response.inspect}" if @debug
        case response
        when nil then nil
        when :skip then next
        when :wait
          t0 = Time.now
          @session_rules.unshift(rule.merge(repeat: 0))
        when :abort
          $stderr.puts "^Abort!" if @verbose
          abort_threads
          break
        else
          t0 = Time.now
          puts "#{response}" if @verbose
          instream.puts response
          read_buffer = ""
        end
      else
        nil # Be patient, wait longer.
      end

      # Abort if we exceed the timeout
      if Time.now - t0 > @timeout
        $stderr.puts "Timeout: abort!" if @verbose
        abort_threads
      end

      # Wait a little
      sleep(0.1)
    end

    # For completion, read the rest of the output
    read_buffer << consume_stdout
    puts read_buffer
  end

  def next_rule
    rule = @session_rules.first or return
    rule = rule.dup
    rule[:repeat] <= 0 ? @session_rules.shift : @session_rules.first[:repeat] -= 1
    return rule
  end

  def abort_threads
    @stdout_thread.kill
    @stderr_thread.kill
    @stdin_thread.kill
  end

  def determine_response(rule, read_buffer)
    # determine which rule key, if any match the current read_buffer
    return if rule.nil?
    matcher, responder = rule.find do |matcher, responder|
      case matcher
      when Regexp then read_buffer =~ matcher
      when Proc then matcher.call(read_buffer)
      when String then read_buffer.split("\n").last == matcher
      end
    end || [:default, rule[:default]]

    # and generate the response accordingly
    response = case responder
    when Proc then responder.call(read_buffer)
    when :wait, :skip, :abort then responder
    else responder.to_s
    end

    return response
  end

  def consume_stdout
    if !@stdout_buffer.empty?
      output = @stdout_buffer.dup
      @stdout_buffer.clear
      return output
    else
      return ""
    end
  end

end