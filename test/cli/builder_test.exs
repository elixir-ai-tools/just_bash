defmodule JustBash.CLI.BuilderTest do
  use ExUnit.Case, async: true

  alias JustBash.CLI
  alias JustBash.CLI.Command

  describe "command/2" do
    test "builds a leaf with a run handler" do
      run = fn inv -> {%{stdout: "", stderr: "", exit_code: 0}, inv.bash} end
      cmd = CLI.command("list", doc: "List things", run: run)

      assert %Command{name: "list", doc: "List things", run: ^run, commands: []} = cmd
      assert Command.leaf?(cmd)
      refute Command.group?(cmd)
    end

    test "builds a group with nested commands" do
      child = CLI.command("review", run: fn inv -> {ok(), inv.bash} end)
      group = CLI.command("pr", doc: "PRs", commands: [child])

      assert %Command{name: "pr", commands: [^child], run: nil} = group
      assert Command.group?(group)
      refute Command.leaf?(group)
    end

    test "normalizes positional arg specs with defaults" do
      cmd =
        CLI.command("show", args: [%{name: :id, required: true}], run: fn i -> {ok(), i.bash} end)

      assert [%{name: :id, required: true, variadic: false, doc: nil}] = cmd.args
    end

    test "raises when a node is neither group nor leaf" do
      assert_raise ArgumentError, ~r/either a group .* or a leaf/, fn ->
        CLI.command("oops")
      end
    end

    test "raises when a node is both group and leaf" do
      child = CLI.command("x", run: fn i -> {ok(), i.bash} end)

      assert_raise ArgumentError, ~r/cannot be both/, fn ->
        CLI.command("pr", commands: [child], run: fn i -> {ok(), i.bash} end)
      end
    end

    test "raises on a non-1-arity run handler" do
      assert_raise ArgumentError, ~r/:run must be a 1-arity function/, fn ->
        CLI.command("x", run: fn _a, _b -> :nope end)
      end
    end

    test "raises on duplicate child names" do
      a = CLI.command("dup", run: fn i -> {ok(), i.bash} end)
      b = CLI.command("dup", run: fn i -> {ok(), i.bash} end)

      assert_raise ArgumentError, ~r/duplicate subcommand name/, fn ->
        CLI.command("group", commands: [a, b])
      end
    end

    test "raises on a name with spaces" do
      assert_raise ArgumentError, ~r/must not contain spaces/, fn ->
        CLI.command("pr review", run: fn i -> {ok(), i.bash} end)
      end
    end

    test "raises on a variadic arg that is not last" do
      assert_raise ArgumentError, ~r/variadic positional argument must be last/, fn ->
        CLI.command("x",
          args: [%{name: :rest, variadic: true}, %{name: :tail}],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when a required positional follows an optional one" do
      assert_raise ArgumentError,
                   ~r/required positional argument .* cannot follow an optional/,
                   fn ->
                     CLI.command("x",
                       args: [%{name: :a}, %{name: :b, required: true}],
                       run: fn i -> {ok(), i.bash} end
                     )
                   end
    end

    test "allows required positionals before optional ones" do
      cmd =
        CLI.command("x",
          args: [%{name: :a, required: true}, %{name: :b}],
          run: fn i -> {ok(), i.bash} end
        )

      assert [%{name: :a, required: true}, %{name: :b, required: false}] = cmd.args
    end

    test "raises when a flag declares both :required and :default" do
      assert_raise ArgumentError, ~r/cannot be both :required and have a :default/, fn ->
        CLI.command("x",
          flags: [n: [type: :integer, required: true, default: 1]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when a flag :default is not a member of :values" do
      assert_raise ArgumentError, ~r/:default "xml" is not one of :values/, fn ->
        CLI.command("x",
          flags: [format: [type: :string, default: "xml", values: ~w(text json)]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "allows a flag :default that is a member of :values" do
      cmd =
        CLI.command("x",
          flags: [format: [type: :string, default: "text", values: ~w(text json)]],
          run: fn i -> {ok(), i.bash} end
        )

      assert cmd.flags[:format][:default] == "text"
    end

    test "raises when a flag claims the reserved --help long form" do
      assert_raise ArgumentError, ~r/--help.* is reserved/, fn ->
        CLI.command("x",
          flags: [help: [type: :boolean]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when a flag claims the reserved -h short form" do
      assert_raise ArgumentError, ~r/-h.* is reserved/, fn ->
        CLI.command("x",
          flags: [height: [type: :integer, short: "-h"]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises on an unrecognized flag-spec key" do
      assert_raise ArgumentError,
                   ~r/unknown flag option :totally_bogus_key.*valid options are/s,
                   fn ->
                     CLI.command("x",
                       flags: [
                         other: [type: :string, long: "--other-name", totally_bogus_key: 123]
                       ],
                       run: fn i -> {ok(), i.bash} end
                     )
                   end
    end

    test "raises on a misspelled flag-spec key" do
      assert_raise ArgumentError, ~r/unknown flag option :requird/, fn ->
        CLI.command("x",
          flags: [n: [type: :integer, requird: true]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises naming a duplicated flag-spec key as a duplicate, not as unknown" do
      err =
        assert_raise ArgumentError, fn ->
          CLI.command("x",
            flags: [n: [type: :integer, type: :string]],
            run: fn i -> {ok(), i.bash} end
          )
        end

      message = Exception.message(err)

      assert message =~ "duplicate flag option :type"
      refute message =~ "unknown flag option"
    end

    test "accepts a flag :aliases list and keeps :long canonical" do
      cmd =
        CLI.command("x",
          flags: [target_on: [type: :string, aliases: ["--target-date", "--date"]]],
          run: fn i -> {ok(), i.bash} end
        )

      assert cmd.flags[:target_on][:long] == "--target-on"
      assert cmd.flags[:target_on][:aliases] == ["--target-date", "--date"]
    end

    test "raises when :aliases is not a list of strings" do
      assert_raise ArgumentError, ~r/:aliases must be a list of strings/, fn ->
        CLI.command("x",
          flags: [target_on: [type: :string, aliases: "--target-date"]],
          run: fn i -> {ok(), i.bash} end
        )
      end

      assert_raise ArgumentError, ~r/:aliases must be a list of strings/, fn ->
        CLI.command("x",
          flags: [target_on: [type: :string, aliases: [:"--target-date"]]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when an alias is not a long flag form" do
      assert_raise ArgumentError, ~r/alias "target-date" must be a long flag form/, fn ->
        CLI.command("x",
          flags: [target_on: [type: :string, aliases: ["target-date"]]],
          run: fn i -> {ok(), i.bash} end
        )
      end

      assert_raise ArgumentError, ~r/alias "-t" must be a long flag form/, fn ->
        CLI.command("x",
          flags: [target_on: [type: :string, aliases: ["-t"]]],
          run: fn i -> {ok(), i.bash} end
        )
      end

      assert_raise ArgumentError, ~r/alias "--" must be a long flag form/, fn ->
        CLI.command("x",
          flags: [target_on: [type: :string, aliases: ["--"]]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when an alias claims the reserved --help form" do
      assert_raise ArgumentError, ~r/--help.* is reserved/, fn ->
        CLI.command("x",
          flags: [target_on: [type: :string, aliases: ["--help"]]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when an alias collides with another flag's long form" do
      assert_raise ArgumentError, ~r/alias "--format" collides/, fn ->
        CLI.command("x",
          flags: [
            format: [type: :string],
            target_on: [type: :string, aliases: ["--format"]]
          ],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when an alias collides with another flag's alias" do
      assert_raise ArgumentError, ~r/alias "--date" collides/, fn ->
        CLI.command("x",
          flags: [
            recorded_on: [type: :string, aliases: ["--date"]],
            target_on: [type: :string, aliases: ["--date"]]
          ],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when an alias collides with its own flag's long form" do
      assert_raise ArgumentError, ~r/alias "--target-on" collides/, fn ->
        CLI.command("x",
          flags: [target_on: [type: :string, aliases: ["--target-on"]]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    # `ArgParser` splits a long token on its first `=` before consulting the long-form map, so
    # a spelling containing `=` is registered but unreachable — it would build clean and never
    # match, the exact silent-drop failure the key allowlist exists to prevent.
    test "raises when an alias contains =" do
      assert_raise ArgumentError, ~r/alias "--target=date" cannot contain "="/, fn ->
        CLI.command("x",
          flags: [target_on: [type: :string, aliases: ["--target=date"]]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when a :long form contains =" do
      assert_raise ArgumentError, ~r/long form "--target=date" cannot contain "="/, fn ->
        CLI.command("x",
          flags: [target_on: [type: :string, long: "--target=date"]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when two flags claim the same long form" do
      assert_raise ArgumentError, ~r/long form "--dup" collides/, fn ->
        CLI.command("x",
          flags: [a: [type: :string, long: "--dup"], b: [type: :string, long: "--dup"]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when two flag names derive the same long form" do
      assert_raise ArgumentError, ~r/long form "--dry-run" collides/, fn ->
        CLI.command("x",
          flags: [dry_run: [type: :boolean], "dry-run": [type: :boolean]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises when two flags claim the same short form" do
      assert_raise ArgumentError, ~r/short form "-x" collides/, fn ->
        CLI.command("x",
          flags: [a: [type: :boolean, short: "-x"], b: [type: :boolean, short: "-x"]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises on flags that are not a keyword list" do
      assert_raise ArgumentError, ~r/:flags must be a keyword list/, fn ->
        CLI.command("x", flags: %{not: :keyword}, run: fn i -> {ok(), i.bash} end)
      end
    end

    test "raises when a group node is given flags" do
      child = CLI.command("review", run: fn i -> {ok(), i.bash} end)

      assert_raise ArgumentError, ~r/group .* cannot define :flags or :args/, fn ->
        CLI.command("pr", commands: [child], flags: [verbose: [type: :boolean]])
      end
    end

    test "raises when a group node is given positional args" do
      child = CLI.command("review", run: fn i -> {ok(), i.bash} end)

      assert_raise ArgumentError, ~r/group .* cannot define :flags or :args/, fn ->
        CLI.command("pr", commands: [child], args: [%{name: :id}])
      end
    end

    test "raises on an unrecognized command option" do
      assert_raise ArgumentError, ~r/command "admin": unknown option :totally_bogus/, fn ->
        CLI.command("admin",
          totally_bogus: 123,
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    # Dropping the `?` discards the authorization predicate: the node stays routable for every
    # caller, which is a silent security downgrade rather than a cosmetic typo.
    test "raises on :visible written without its question mark" do
      assert_raise ArgumentError, ~r/unknown option :visible;/, fn ->
        CLI.command("admin",
          visible: fn _bash -> false end,
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises on a misspelled :flags option" do
      assert_raise ArgumentError, ~r/unknown option :flgs/, fn ->
        CLI.command("go",
          flgs: [target_on: [type: :string]],
          run: fn i -> {ok(), i.bash} end
        )
      end
    end

    test "raises on a duplicated command option" do
      err =
        assert_raise ArgumentError, fn ->
          CLI.command("go", doc: "one", doc: "two", run: fn i -> {ok(), i.bash} end)
        end

      assert Exception.message(err) =~ "duplicate option :doc"
    end

    test "raises on an unrecognized positional argument key" do
      assert_raise ArgumentError,
                   ~r/unknown positional argument option :requird/,
                   fn ->
                     CLI.command("go",
                       args: [%{name: :path, requird: true, doc: "path"}],
                       run: fn i -> {ok(), i.bash} end
                     )
                   end
    end
  end

  describe "new/2" do
    test "builds a CLI root" do
      cmd = CLI.command("list", run: fn i -> {ok(), i.bash} end)
      cli = CLI.new("acme", doc: "Acme toolkit", commands: [cmd], aliases: ["ac"])

      assert %CLI{name: "acme", doc: "Acme toolkit", commands: [^cmd], aliases: ["ac"]} = cli
    end

    test "defaults to no commands and no aliases" do
      assert %CLI{commands: [], aliases: []} = CLI.new("acme")
    end

    test "raises on an empty name" do
      assert_raise ArgumentError, ~r/non-empty string/, fn -> CLI.new("") end
    end

    test "raises on colliding top-level command names" do
      a = CLI.command("dup", run: fn i -> {ok(), i.bash} end)
      b = CLI.command("dup", run: fn i -> {ok(), i.bash} end)

      assert_raise ArgumentError, ~r/duplicate subcommand name/, fn ->
        CLI.new("acme", commands: [a, b])
      end
    end

    test "raises on an unrecognized CLI option" do
      assert_raise ArgumentError, ~r/CLI "acme": unknown option :comands/, fn ->
        CLI.new("acme", comands: [])
      end
    end

    test "raises on a duplicated CLI option" do
      err = assert_raise ArgumentError, fn -> CLI.new("acme", doc: "one", doc: "two") end

      assert Exception.message(err) =~ "duplicate option :doc"
    end
  end

  # The builder's key allowlists are load-bearing in the *strict* direction: any key missing
  # from one turns a spec that works today into a build-time raise, and nothing else in the
  # suite would notice — dropping `:transform` from the flag list left the whole suite green
  # while breaking every downstream CLI that uses it. These tests enumerate each list rather
  # than sampling it: every key is exercised positively, and the builder's own "valid options
  # are" list is pinned to the enumeration, so a key added or dropped on either side goes red.
  describe "spec key allowlists" do
    @flag_spec_keys [
      :type,
      :short,
      :long,
      :aliases,
      :default,
      :required,
      :values,
      :transform,
      :doc
    ]

    @command_opt_keys [
      :doc,
      :commands,
      :run,
      :flags,
      :args,
      :examples,
      :validate,
      :allow_unknown_flags,
      :visible?,
      :on_missing_subcommand
    ]

    @cli_opt_keys [:doc, :commands, :aliases, :on_missing_subcommand]

    @arg_spec_keys [:name, :doc, :required, :variadic]

    test "every flag-spec key is accepted on its own" do
      for key <- @flag_spec_keys do
        spec = Keyword.put([type: :string], key, flag_spec_value(key))

        assert %Command{} =
                 CLI.command("x", flags: [n: spec], run: fn i -> {ok(), i.bash} end),
               "flag-spec key #{inspect(key)} was rejected by the builder"
      end
    end

    test "a flag spec carrying every key at once is accepted" do
      # :required and :default are mutually exclusive by design, so each variant drops the
      # other; between them the two specs cover the whole allowlist.
      for dropped <- [:default, :required] do
        spec = for key <- @flag_spec_keys -- [dropped], do: {key, flag_spec_value(key)}

        assert %Command{} = CLI.command("x", flags: [n: spec], run: fn i -> {ok(), i.bash} end)
      end
    end

    test "the builder reports exactly the enumerated flag-spec keys as valid" do
      err =
        assert_raise ArgumentError, fn ->
          CLI.command("x", flags: [n: [nope: 1]], run: fn i -> {ok(), i.bash} end)
        end

      assert Exception.message(err) =~ "valid options are #{inspect(@flag_spec_keys)}"
    end

    test "every command option is accepted, on a leaf or on a group" do
      leaf_opts = [
        doc: "leaf doc",
        run: fn i -> {ok(), i.bash} end,
        flags: [verbose: [type: :boolean]],
        args: [%{name: :path}],
        examples: ["x go /tmp"],
        validate: fn _inv -> :ok end,
        allow_unknown_flags: true,
        visible?: fn _bash -> true end
      ]

      group_opts = [
        doc: "group doc",
        commands: [CLI.command("child", run: fn i -> {ok(), i.bash} end)],
        visible?: fn _bash -> true end,
        on_missing_subcommand: :help
      ]

      assert Enum.sort(Enum.uniq(Keyword.keys(leaf_opts) ++ Keyword.keys(group_opts))) ==
               Enum.sort(@command_opt_keys)

      assert %Command{} = CLI.command("go", leaf_opts)
      assert %Command{} = CLI.command("pr", group_opts)
    end

    test "the builder reports exactly the enumerated command options as valid" do
      err =
        assert_raise ArgumentError, fn ->
          CLI.command("go", nope: 1, run: fn i -> {ok(), i.bash} end)
        end

      assert Exception.message(err) =~ "valid options are #{inspect(@command_opt_keys)}"
    end

    test "every CLI option is accepted at once" do
      opts = [
        doc: "Acme toolkit",
        commands: [CLI.command("go", run: fn i -> {ok(), i.bash} end)],
        aliases: ["ac"],
        on_missing_subcommand: :help
      ]

      assert Enum.sort(Keyword.keys(opts)) == Enum.sort(@cli_opt_keys)
      assert %CLI{name: "acme"} = CLI.new("acme", opts)
    end

    test "the builder reports exactly the enumerated CLI options as valid" do
      err = assert_raise ArgumentError, fn -> CLI.new("acme", nope: 1) end

      assert Exception.message(err) =~ "valid options are #{inspect(@cli_opt_keys)}"
    end

    test "every positional argument key is accepted at once" do
      spec = %{name: :path, doc: "a path", required: true, variadic: true}

      assert Enum.sort(Map.keys(spec)) == Enum.sort(@arg_spec_keys)

      cmd = CLI.command("go", args: [spec], run: fn i -> {ok(), i.bash} end)

      assert [%{name: :path, doc: "a path", required: true, variadic: true}] = cmd.args
    end

    test "the builder reports exactly the enumerated positional argument keys as valid" do
      err =
        assert_raise ArgumentError, fn ->
          CLI.command("go", args: [%{name: :path, nope: 1}], run: fn i -> {ok(), i.bash} end)
        end

      assert Exception.message(err) =~ "valid options are #{inspect(@arg_spec_keys)}"
    end
  end

  # A representative value for each flag-spec key. Kept as a function rather than a module
  # attribute because `:transform` holds a function capture, which cannot be escaped into one.
  defp flag_spec_value(:type), do: :integer
  defp flag_spec_value(:short), do: "-n"
  defp flag_spec_value(:long), do: "--enum"
  defp flag_spec_value(:aliases), do: ["--alias-form"]
  defp flag_spec_value(:default), do: "a"
  defp flag_spec_value(:required), do: true
  defp flag_spec_value(:values), do: ["a", "b"]
  defp flag_spec_value(:transform), do: &String.upcase/1
  defp flag_spec_value(:doc), do: "a doc string"

  defp ok, do: %{stdout: "", stderr: "", exit_code: 0}
end
