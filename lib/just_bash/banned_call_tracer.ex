defmodule JustBash.BannedCallTracer do
  @moduledoc """
  Detects banned remote function calls by inspecting compiled BEAM files.

  Rather than re-compiling source, this module reads the abstract code
  (debug info) from already-compiled `.beam` files and walks the call
  tree looking for banned calls. No recompilation, no module-redefinition
  warnings, no load-order problems.

  ## Security model

  JustBash code must never touch real system resources — all I/O goes
  through the virtual filesystem and environment abstractions. The banned
  categories are:

  ### Filesystem (`File`, `:file`)
  Any call into `File.*` or the Erlang `:file` module. Covers reads, writes,
  stat, ls, exists?, mkdir, rm, etc.

  ### Environment (`System.get_env`, `System.put_env`, `System.delete_env`)
  Reading or mutating real OS environment variables.

  ### Process / OS escape (`System.cmd`, `System.shell`, `Port`, `:os`, `:erlang.open_port`)
  Spawning real OS processes or opening ports. These are the most dangerous
  — they can execute arbitrary host commands regardless of filesystem sandboxing.

  ### Node escape (`Node`)
  Connecting to or spawning processes on remote Erlang nodes.

  ### Mutable shared state (`Process.put/get/delete`, `:ets`)
  Process dictionary and ETS leak mutable state across calls, breaking
  referential transparency and making code unpredictable in concurrent use.

  ## What this catches

  - Direct calls: `File.read(path)`, `System.cmd("rm", [...])`
  - Calls through Elixir aliases (resolved before compilation)
  - `apply/3` and `:erlang.apply/3` **when both the module and function
    are literal atoms** at the call site, e.g. `apply(File, :read, [path])`

  ## What this cannot catch

  Dynamic dispatch where the module or function is a runtime variable:

      mod = File
      mod.read(path)          # module is a variable — opaque to static analysis

      fun = :read
      apply(File, fun, [path]) # function is a variable — opaque

  These cases require runtime instrumentation (e.g. `:erlang.trace`) to
  detect. No purely static tool can catch them. The defense against dynamic
  dispatch is code review discipline and the fact that there is no legitimate
  reason for JustBash library code to hold a reference to `File` or `System`
  in a variable at all.
  """

  # Entire modules whose every function is banned.
  # Any remote call to mod.anything/any_arity is a violation.
  @banned_modules [
    # Filesystem
    File,
    :file,
    # OS process spawning
    Port,
    # Remote node operations
    Node,
    # ETS — mutable shared state that leaks across calls
    :ets
  ]

  # Specific functions banned within modules that have some safe functions.
  # {module, function, arity}
  @banned_functions [
    # Environment reads/writes
    {System, :get_env, 1},
    {System, :get_env, 2},
    {System, :put_env, 2},
    {System, :put_env, 3},
    {System, :delete_env, 1},
    # OS process spawning
    {System, :cmd, 2},
    {System, :cmd, 3},
    {System, :shell, 1},
    {System, :shell, 2},
    # Erlang-level port / OS escape
    {:os, :cmd, 1},
    {:os, :cmd, 2},
    {:erlang, :open_port, 2},
    # Process dictionary — leaks mutable global state across calls
    {Process, :put, 2},
    {Process, :get, 0},
    {Process, :get, 1},
    {Process, :get, 2},
    {Process, :delete, 1}
  ]

  @type violation :: %{
          call: {module(), atom(), arity()},
          beam: Path.t(),
          line: non_neg_integer()
        }

  @doc """
  Checks all `.beam` files under `beam_dir` for banned calls.
  Returns a list of violations.
  """
  @spec check_app(Path.t()) :: [violation()]
  def check_app(beam_dir \\ "_build/test/lib/just_bash/ebin") do
    beam_dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(&check_beam/1)
  end

  @doc """
  Checks a single `.beam` file for banned calls.
  """
  @spec check_beam(Path.t()) :: [violation()]
  def check_beam(beam_path) do
    path_charlist = String.to_charlist(beam_path)

    case :beam_lib.chunks(path_charlist, [:abstract_code]) do
      {:ok, {_mod, [{:abstract_code, {:raw_abstract_v1, abstract_code}}]}} ->
        walk(abstract_code, beam_path, [])

      {:ok, {_mod, [{:abstract_code, :no_debug_info}]}} ->
        []

      {:error, :beam_lib, _reason} ->
        []
    end
  end

  # Walk the abstract code tree collecting banned remote calls.
  # Abstract code is Erlang's internal AST — tuples all the way down.

  # apply(Mod, :fun, [...]) and :erlang.apply(Mod, :fun, [...])
  # Must come before the generic remote call clause since :erlang.apply/3
  # also matches that pattern — we want to resolve the effective target first.
  # When mod and fun are literal atoms we can determine the effective call statically.
  # Dynamic dispatch (variable module/function) is opaque to static analysis.
  defp walk(
         {:call, ann, {:remote, _, {:atom, _, :erlang}, {:atom, _, :apply}},
          [{:atom, _, mod}, {:atom, _, fun}, args_list]},
         beam,
         acc
       ) do
    arity = list_length(args_list)
    line = :erl_anno.line(ann)

    acc =
      if arity != :unknown and banned?(mod, fun, arity) do
        [%{call: {mod, fun, arity}, beam: beam, line: line} | acc]
      else
        acc
      end

    walk(args_list, beam, acc)
  end

  # Direct remote call: Mod.fun(args...)
  defp walk({:call, ann, {:remote, _, {:atom, _, mod}, {:atom, _, fun}}, args}, beam, acc) do
    arity = length(args)
    line = :erl_anno.line(ann)

    acc =
      if banned?(mod, fun, arity) do
        [%{call: {mod, fun, arity}, beam: beam, line: line} | acc]
      else
        acc
      end

    Enum.reduce(args, acc, &walk(&1, beam, &2))
  end

  defp walk(tuple, beam, acc) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.reduce(acc, &walk(&1, beam, &2))
  end

  defp walk(list, beam, acc) when is_list(list) do
    Enum.reduce(list, acc, &walk(&1, beam, &2))
  end

  defp walk(_other, _beam, acc), do: acc

  defp banned?(mod, fun, arity) do
    mod in @banned_modules or {mod, fun, arity} in @banned_functions
  end

  # Count the length of an abstract code list (cons cells) to determine arity.
  # Returns :unknown if the list is not fully literal (e.g. a variable or expression).
  defp list_length({nil, _}), do: 0
  defp list_length({:cons, _, _head, tail}), do: add_one(list_length(tail))
  defp list_length(_), do: :unknown

  defp add_one(:unknown), do: :unknown
  defp add_one(n), do: n + 1
end
