defmodule JustBash.Eval.Tasks.CustomCommands do
  @moduledoc """
  Eval tasks that test custom command integration.
  The agent must discover and use custom commands alongside standard tools.
  """

  @behaviour JustBash.Eval.Task

  alias JustBash.Eval.Commands.KV

  @impl true
  def tasks do
    [
      kv_config_migration()
    ]
  end

  # --- KV config migration ---
  # The agent has a CSV config file and must load it into the KV store,
  # transform some values, export a .env file, and produce a summary.

  defp kv_config_migration do
    config_csv = """
    key,value,environment
    db_host,localhost,development
    db_port,5432,development
    db_name,myapp_dev,development
    db_host,db.prod.internal,production
    db_port,5432,production
    db_name,myapp_prod,production
    cache_url,redis://localhost:6379,development
    cache_url,redis://cache.prod:6379,production
    log_level,debug,development
    log_level,warn,production
    secret_key,dev-secret-123,development
    secret_key,prod-secret-xyz,production
    max_workers,2,development
    max_workers,16,production
    """

    %{
      name: "kv_config_migration",
      description: """
      You have a configuration CSV file at /data/config.csv with columns: key, value, environment.

      Your task:
      1. Read the CSV and load ALL production (environment=production) key-value pairs into the `kv` \
      store using the `kv` command.
      2. After loading, use `kv dump` to export all stored pairs to /output/production.env \
      (the dump output is already in key=value format).
      3. Create /output/summary.txt containing:
         - Line 1: the total count of keys stored (use `kv count`)
         - Line 2: the value of `db_host` (use `kv get`)
         - Line 3: the value of `log_level`
      """,
      files: %{"/data/config.csv" => config_csv},
      commands: %{"kv" => KV},
      validators: [
        {:command_used, "kv"},
        {:file_contains, "/output/production.env",
         [
           {:regex, ~r/db_host=db\.prod\.internal/},
           {:regex, ~r/db_port=5432/},
           {:regex, ~r/db_name=myapp_prod/},
           {:regex, ~r/cache_url=redis:\/\/cache\.prod:6379/},
           {:regex, ~r/log_level=warn/},
           {:regex, ~r/secret_key=prod-secret-xyz/},
           {:regex, ~r/max_workers=16/},
           {:line_count, 7}
         ]},
        {:file_contains, "/output/summary.txt",
         [
           {:regex, ~r/7/},
           {:regex, ~r/db\.prod\.internal/},
           {:regex, ~r/warn/}
         ]},
        {:custom, "kv_store_populated",
         fn %{bash: bash} ->
           {result, _} = KV.execute(bash, ["count"], "")

           if String.trim(result.stdout) == "7" do
             :ok
           else
             {:error, "expected 7 keys in kv store, got #{String.trim(result.stdout)}"}
           end
         end}
      ]
    }
  end
end
