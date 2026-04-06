defmodule JustBash.BannedCallTracerTest do
  use ExUnit.Case

  @ebin "_build/test/lib/just_bash/ebin"

  describe "BannedCallTracer" do
    test "detects System.get_env/1 in a compiled fixture module" do
      beam = Path.join(@ebin, "Elixir.BannedCallTracer.Fixture.beam")
      violations = JustBash.BannedCallTracer.check_beam(beam)

      assert length(violations) == 1
      assert %{call: {System, :get_env, 1}} = hd(violations)
    end

    test "detects System.cmd/2 in a compiled fixture module" do
      beam = Path.join(@ebin, "Elixir.BannedCallTracer.Fixture.Cmd.beam")
      violations = JustBash.BannedCallTracer.check_beam(beam)

      assert length(violations) == 1
      assert %{call: {System, :cmd, 2}} = hd(violations)
    end

    test "detects apply(File, :read, [...]) with literal module and function atoms" do
      beam = Path.join(@ebin, "Elixir.BannedCallTracer.Fixture.Apply.beam")
      violations = JustBash.BannedCallTracer.check_beam(beam)

      assert length(violations) == 1
      assert %{call: {File, :read, 1}} = hd(violations)
    end

    test "detects :erlang.apply(File, :read, [...]) with literal module and function atoms" do
      beam = Path.join(@ebin, "Elixir.BannedCallTracer.Fixture.ErlangApply.beam")
      violations = JustBash.BannedCallTracer.check_beam(beam)

      assert length(violations) == 1
      assert %{call: {File, :read, 1}} = hd(violations)
    end

    test "grep patterns detect dynamic dispatch fixture (self-test)" do
      # Confirms the grep patterns are not silently failing.
      # This fixture intentionally contains `mod = File` — it must be found.
      fixture = "test/support/banned_fixture_dynamic.ex"

      banned_modules = ~w[File System Port Node]

      patterns =
        Enum.flat_map(banned_modules, fn mod ->
          [~r/=\s*#{mod}\b/, ~r/apply\(\s*#{mod}\b/]
        end)

      violations =
        fixture
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reject(fn {line, _} -> String.match?(line, ~r/^\s*#|\@(doc|moduledoc)/) end)
        |> Enum.flat_map(fn {line, lineno} ->
          matched = Enum.filter(patterns, &Regex.match?(&1, line))
          Enum.map(matched, fn pat -> {fixture, lineno, line, pat} end)
        end)

      assert violations != [],
             "Grep self-test failed: expected to find dynamic dispatch in #{fixture} but found nothing. " <>
               "The regex patterns may be broken."
    end

    test "no dynamic dispatch of banned modules in lib/just_bash source" do
      # Grep check — catches the pattern static BEAM analysis cannot:
      # assigning a banned module to a variable for later dynamic dispatch.
      #
      #   mod = File          <- this
      #   mod.read(path)      <- leads to this, which is opaque to :beam_lib
      #
      # We search for bare banned module names appearing as values (after `=`
      # or inside `apply(`) in non-comment, non-doc source lines.
      # The tracer module itself is excluded since it references these names
      # in documentation examples.
      banned_modules = ~w[File System Port Node]

      patterns =
        Enum.flat_map(banned_modules, fn mod ->
          [
            ~r/=\s*#{mod}\b/,
            ~r/apply\(\s*#{mod}\b/
          ]
        end)

      violations =
        Path.wildcard("lib/just_bash/**/*.ex")
        |> Enum.reject(&String.contains?(&1, "banned_call_tracer"))
        |> Enum.flat_map(fn path ->
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.reject(fn {line, _} -> String.match?(line, ~r/^\s*#|\@(doc|moduledoc)/) end)
          |> Enum.flat_map(fn {line, lineno} ->
            matched = Enum.filter(patterns, &Regex.match?(&1, line))
            Enum.map(matched, fn pat -> {path, lineno, line, pat} end)
          end)
        end)

      assert violations == [],
             "Dynamic dispatch of banned module found:\n" <>
               Enum.map_join(violations, "\n", fn {path, line, content, _pat} ->
                 "  #{path}:#{line}: #{String.trim(content)}"
               end)
    end

    test "no String.to_atom in lib/just_bash source" do
      violations =
        Path.wildcard("lib/just_bash/**/*.ex")
        |> Enum.flat_map(fn path ->
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.reject(fn {line, _} -> String.match?(line, ~r/^\s*#|\@(doc|moduledoc)/) end)
          |> Enum.flat_map(fn {line, lineno} ->
            if String.match?(line, ~r/String\.to_atom\b/) do
              [{path, lineno, line}]
            else
              []
            end
          end)
        end)

      assert violations == [],
             "String.to_atom found (use String.to_existing_atom or an explicit map):\n" <>
               Enum.map_join(violations, "\n", fn {path, line, content} ->
                 "  #{path}:#{line}: #{String.trim(content)}"
               end)
    end

    test "no banned calls in lib/ (excluding intentional real-IO modules)" do
      # Modules allowed to use real filesystem / environment access,
      # with the reason each is exempt from the sandbox rule:
      excluded = [
        # The tracer itself — only references banned calls in module docs
        "Elixir.JustBash.BannedCallTracer.beam",
        # Test fixtures that intentionally contain banned calls for tracer testing
        "Elixir.BannedCallTracer.Fixture",
        # Mix tasks are host-side dev/maintenance tooling, not part of the sandbox
        "Elixir.Mix.Tasks",
        # LLM benchmark client — reads ANTHROPIC_API_KEY to call external API
        "Elixir.JustBash.Eval.Client",
        # Benchmark runner — writes results.jsonl to host filesystem
        "Elixir.JustBash.Eval.Runner",
        # Spec test parser — reads fixture files from host filesystem during mix test
        "Elixir.JustBash.SpecTest.Parser",
        # Test-only mock that uses Process dictionary for test state
        "Elixir.JustBash.MockHttpClient"
      ]

      violations =
        @ebin
        |> JustBash.BannedCallTracer.check_app()
        |> Enum.reject(fn %{beam: beam} ->
          Enum.any?(excluded, &String.contains?(beam, &1))
        end)

      assert violations == [],
             "Banned calls found:\n" <>
               Enum.map_join(violations, "\n", fn %{call: {m, f, a}, beam: beam, line: line} ->
                 "  #{beam}:#{line} — #{m}.#{f}/#{a}"
               end)
    end
  end
end
