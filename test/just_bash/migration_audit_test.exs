defmodule JustBash.MigrationAuditTest do
  use ExUnit.Case, async: true

  alias JustBash.MigrationAudit
  alias Mix.Tasks.JustBash.Audit

  defp rules(source) do
    source |> MigrationAudit.scan_source("fixture.ex") |> Enum.map(& &1.rule)
  end

  describe "legacy_module" do
    test "flags references to JustBash.Fs and InMemoryFs" do
      source = ~S"""
      defmodule M do
        alias JustBash.Fs.InMemoryFs

        def f(bash, p), do: InMemoryFs.read_file(bash.fs, p)
      end
      """

      assert :legacy_module in rules(source)
    end
  end

  describe "stale_ok_tuple" do
    test "flags {:ok, _} matched on a three-tuple read in case/with/=" do
      source = ~S"""
      defmodule M do
        alias JustBash.FS

        def a(fs, p) do
          case FS.read_file(fs, p) do
            {:ok, content} -> content
            {:error, _} -> nil
          end
        end

        def b(fs, p) do
          with {:ok, target} <- FS.readlink(fs, p), do: target
        end

        def c(fs, p) do
          {:ok, stat} = FS.stat(fs, p)
          stat
        end
      end
      """

      findings = MigrationAudit.scan_source(source, "fixture.ex")
      assert Enum.count(findings, &(&1.rule == :stale_ok_tuple)) == 3
    end

    test "does not flag the modern three-tuple shape or mutations" do
      source = ~S"""
      defmodule M do
        alias JustBash.FS

        def a(fs, p) do
          case FS.read_file(fs, p) do
            {:ok, content, fs} -> {content, fs}
            {:error, %VFS.Error{kind: :enoent}} -> :missing
          end
        end

        def b(fs, p), do: {:ok, _fs} = FS.write_file(fs, p, "x")
      end
      """

      assert rules(source) == []
    end
  end

  describe "atom_error" do
    test "flags {:error, :atom} clauses on FS results" do
      source = ~S"""
      defmodule M do
        alias JustBash.FS

        def f(fs, p) do
          case FS.write_file(fs, p, "x") do
            {:ok, fs} -> fs
            {:error, :eisdir} -> :nope
          end
        end
      end
      """

      assert rules(source) == [:atom_error]
    end
  end

  describe "exists_truthy" do
    test "flags FS.exists? in if/&&/! and boolean case clauses" do
      source = ~S"""
      defmodule M do
        alias JustBash.FS

        def a(fs, p) do
          if FS.exists?(fs, p), do: :yes, else: :no
        end

        def b(fs, p), do: FS.exists?(fs, p) && :yes

        def c(fs, p) do
          case FS.exists?(fs, p) do
            true -> :yes
            false -> :no
          end
        end
      end
      """

      findings = MigrationAudit.scan_source(source, "fixture.ex")
      assert Enum.count(findings, &(&1.rule == :exists_truthy)) == 4
    end

    test "does not flag a destructured exists?" do
      source = ~S"""
      defmodule M do
        alias JustBash.FS

        def f(fs, p) do
          {exists, fs} = FS.exists?(fs, p)
          if exists, do: fs
        end
      end
      """

      assert rules(source) == []
    end
  end

  describe "legacy_opt" do
    test "flags mkdir recursive: and rm force:" do
      source = ~S"""
      defmodule M do
        alias JustBash.FS

        def a(fs, p), do: FS.mkdir(fs, p, recursive: true)
        def b(fs, p), do: FS.rm(fs, p, force: true)
        def c(fs, p), do: FS.mkdir(fs, p, parents: true)
        def d(fs, p), do: FS.rm(fs, p, recursive: true)
      end
      """

      findings = MigrationAudit.scan_source(source, "fixture.ex")
      assert Enum.count(findings, &(&1.rule == :legacy_opt)) == 2
    end
  end

  describe "stat_boolean_field and fs_data_access" do
    test "flags 0.3 stat fields and bash.fs.data access" do
      source = ~S"""
      defmodule M do
        def a(stat), do: stat.is_file
        def b(stat), do: match?(%{is_directory: true}, stat)
        def c(bash), do: bash.fs.data
      end
      """

      found = rules(source)
      assert Enum.count(found, &(&1 == :stat_boolean_field)) == 2
      assert :fs_data_access in found
    end

    test "does not flag stat.type or plain .data access" do
      source = ~S"""
      defmodule M do
        def a(stat), do: stat.type == :regular
        def b(thing), do: thing.data
      end
      """

      assert rules(source) == []
    end
  end

  describe "alias handling" do
    test "recognizes fully-qualified calls and as-aliases" do
      source = ~S"""
      defmodule M do
        alias JustBash.FS, as: Filesystem

        def a(fs, p) do
          {:ok, c} = JustBash.FS.read_file(fs, p)
          c
        end

        def b(fs, p) do
          {:ok, c} = Filesystem.read_file(fs, p)
          c
        end
      end
      """

      findings = MigrationAudit.scan_source(source, "fixture.ex")
      assert Enum.count(findings, &(&1.rule == :stale_ok_tuple)) == 2
    end

    test "handles piped calls" do
      source = ~S"""
      defmodule M do
        alias JustBash.FS

        def f(fs, p) do
          case fs |> FS.read_file(p) do
            {:ok, c} -> c
            _ -> nil
          end
        end
      end
      """

      assert :stale_ok_tuple in rules(source)
    end
  end

  describe "clean modern code" do
    test "a fully-migrated command produces zero findings" do
      source = ~S"""
      defmodule M do
        alias JustBash.FS

        def execute(bash, [path], _stdin) do
          resolved = FS.resolve_path(bash.cwd, path)

          case FS.read_file(bash.fs, resolved) do
            {:ok, content, fs} ->
              {:ok, fs} = FS.write_file(fs, resolved, String.upcase(content))
              {%{stdout: "", stderr: "", exit_code: 0}, %{bash | fs: fs}}

            {:error, %VFS.Error{} = err} ->
              msg = "upcase: #{path}: #{FS.strerror(err)}\n"
              {%{stdout: "", stderr: msg, exit_code: 1}, bash}
          end
        end
      end
      """

      assert rules(source) == []
    end
  end

  describe "scan_paths/1" do
    test "the just_bash codebase itself is clean" do
      findings = Audit.scan_paths(["lib", "eval"])
      assert findings == []
    end
  end
end
