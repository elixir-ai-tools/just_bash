defmodule JustBash.Telemetry do
  @moduledoc """
  Telemetry instrumentation for the JustBash interpreter.

  This module emits telemetry events for script execution, allowing you to
  monitor performance, track usage, and integrate with observability tools.

  All events use `:telemetry.span/3`, which automatically includes a
  `telemetry_span_context` in metadata for distributed tracing correlation.

  ## Available Events

  All events follow the span pattern with `:start`, `:stop`, and `:exception` suffixes.

  ### Session Execution

  * `[:just_bash, :session, :run, :start]` - Emitted when `JustBash.exec/2` begins execution
    * Measurement: `%{system_time: integer, monotonic_time: integer}`
    * Metadata: `%{session: pid(), telemetry_span_context: reference()}`

  * `[:just_bash, :session, :run, :stop]` - Emitted when `JustBash.exec/2` completes
    * Measurement: `%{duration: native_time, monotonic_time: integer}`
    * Metadata: `%{session: pid(), status: :ok | :error, exit_code: integer,
      bytes_in: integer, bytes_out: integer, telemetry_span_context: reference()}`

  * `[:just_bash, :session, :run, :exception]` - Emitted when `JustBash.exec/2` raises
    * Measurement: `%{duration: native_time, monotonic_time: integer}`
    * Metadata: `%{session: pid(), kind: :error | :exit | :throw, reason: term,
      stacktrace: list, telemetry_span_context: reference()}`

  ### Command Execution

  * `[:just_bash, :command, :start]` - Emitted before a command executes
    * Measurement: `%{system_time: integer, monotonic_time: integer}`
    * Metadata: `%{command: String.t(), args: list(String.t()),
      telemetry_span_context: reference()}`

  * `[:just_bash, :command, :stop]` - Emitted after a command completes
    * Measurement: `%{duration: native_time, monotonic_time: integer}`
    * Metadata: `%{command: String.t(), args: list(String.t()), exit_code: integer,
      bytes_in: integer, bytes_out: integer, telemetry_span_context: reference()}`

  * `[:just_bash, :command, :exception]` - Emitted when a command raises
    * Measurement: `%{duration: native_time, monotonic_time: integer}`
    * Metadata: `%{command: String.t(), args: list(String.t()), kind: atom,
      reason: term, stacktrace: list, telemetry_span_context: reference()}`

  ### For Loop Execution

  * `[:just_bash, :for_loop, :start]` - Emitted before a for loop begins
    * Measurement: `%{system_time: integer, monotonic_time: integer}`
    * Metadata: `%{variable: String.t(), item_count: integer,
      telemetry_span_context: reference()}`

  * `[:just_bash, :for_loop, :stop]` - Emitted after a for loop completes
    * Measurement: `%{duration: native_time, monotonic_time: integer}`
    * Metadata: `%{variable: String.t(), item_count: integer, iteration_count: integer,
      exit_code: integer | nil, telemetry_span_context: reference()}`

  * `[:just_bash, :for_loop, :exception]` - Emitted when a for loop raises
    * Measurement: `%{duration: native_time, monotonic_time: integer}`
    * Metadata: `%{variable: String.t(), item_count: integer, kind: atom,
      reason: term, stacktrace: list, telemetry_span_context: reference()}`

  ### While/Until Loop Execution

  * `[:just_bash, :while_loop, :start]` - Emitted before a while/until loop begins
    * Measurement: `%{system_time: integer, monotonic_time: integer}`
    * Metadata: `%{until: boolean, telemetry_span_context: reference()}`

  * `[:just_bash, :while_loop, :stop]` - Emitted after a while/until loop completes
    * Measurement: `%{duration: native_time, monotonic_time: integer}`
    * Metadata: `%{until: boolean, iteration_count: integer,
      exit_code: integer | nil, telemetry_span_context: reference()}`

  * `[:just_bash, :while_loop, :exception]` - Emitted when a while/until loop raises
    * Measurement: `%{duration: native_time, monotonic_time: integer}`
    * Metadata: `%{until: boolean, kind: atom, reason: term,
      stacktrace: list, telemetry_span_context: reference()}`

  ## Usage Example

  Attach handlers to receive telemetry events:

      :telemetry.attach_many(
        "just-bash-handler",
        [
          [:just_bash, :session, :run, :start],
          [:just_bash, :session, :run, :stop],
          [:just_bash, :session, :run, :exception],
          [:just_bash, :command, :start],
          [:just_bash, :command, :stop],
          [:just_bash, :command, :exception],
          [:just_bash, :for_loop, :start],
          [:just_bash, :for_loop, :stop],
          [:just_bash, :for_loop, :exception],
          [:just_bash, :while_loop, :start],
          [:just_bash, :while_loop, :stop],
          [:just_bash, :while_loop, :exception]
        ],
        &MyApp.TelemetryHandler.handle_event/4,
        nil
      )

  ## Note on Output

  Output (stdout/stderr) is intentionally NOT included in telemetry metadata
  to avoid memory issues with large outputs. Byte counts (`bytes_in`, `bytes_out`)
  are provided instead. Use output collectors or sinks if you need to capture
  command output.
  """

  @doc false
  @spec session_span(pid(), (-> {term(), map()})) :: term()
  def session_span(session_pid, fun) when is_pid(session_pid) and is_function(fun, 0) do
    start_metadata = %{session: session_pid}
    do_span([:just_bash, :session, :run], start_metadata, fun)
  end

  @doc false
  @spec command_span(String.t(), list(String.t()), (-> {term(), map()})) :: term()
  def command_span(command, args, fun)
      when is_binary(command) and is_list(args) and is_function(fun, 0) do
    start_metadata = %{command: command, args: args}
    do_span([:just_bash, :command], start_metadata, fun)
  end

  @doc false
  @spec for_loop_span(String.t() | nil, non_neg_integer(), (-> {term(), map()})) :: term()
  def for_loop_span(variable, item_count, fun)
      when (is_binary(variable) or is_nil(variable)) and is_integer(item_count) and
             is_function(fun, 0) do
    var_name = variable || "(c-style)"
    start_metadata = %{variable: var_name, item_count: item_count}
    do_span([:just_bash, :for_loop], start_metadata, fun)
  end

  @doc false
  @spec while_loop_span(boolean(), (-> {term(), map()})) :: term()
  def while_loop_span(until_mode, fun) when is_boolean(until_mode) and is_function(fun, 0) do
    start_metadata = %{until: until_mode}
    do_span([:just_bash, :while_loop], start_metadata, fun)
  end

  # Wraps :telemetry.span/3 and merges start metadata into stop metadata
  # so handlers can rely entirely on the stop event (per telemetry conventions).
  defp do_span(event_prefix, start_metadata, fun) do
    :telemetry.span(event_prefix, start_metadata, fn ->
      {result, stop_metadata} = fun.()
      {result, Map.merge(start_metadata, stop_metadata)}
    end)
  end
end
