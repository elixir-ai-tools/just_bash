defmodule JustBash.Eval.Tasks.DataPipelines do
  @moduledoc """
  Data pipeline eval tasks: env templating, deduplication, CSV joins,
  ETL pipelines, base64 encoding, and checksum auditing.
  """

  @behaviour JustBash.Eval.Task

  @impl true
  @spec tasks() :: [JustBash.Eval.Task.task()]
  def tasks do
    [
      env_templating(),
      data_dedup(),
      csv_join(),
      pipeline_etl(),
      base64_pipeline(),
      checksum_audit()
    ]
  end

  # --- Realistic: template .env file from a vars file + defaults ---

  defp env_templating do
    %{
      name: "env_templating",
      description: """
      You have a template file at /app/.env.template and an overrides file at /app/overrides.conf.
      The template has lines like KEY={{VALUE}} or KEY={{VALUE:-default}}.
      The overrides file has KEY=VALUE pairs.

      Generate /app/.env by:
      1. For each line in the template, if the KEY exists in overrides, use the override value
      2. If not, use the default value after :- (if present)
      3. If no override and no default, leave the value as empty string
      Write the result to /app/.env as plain KEY=VALUE lines.
      """,
      files: %{
        "/app/.env.template" =>
          Enum.join(
            [
              "DATABASE_URL={{DATABASE_URL}}",
              "REDIS_URL={{REDIS_URL:-redis://localhost:6379}}",
              "SECRET_KEY={{SECRET_KEY}}",
              "LOG_LEVEL={{LOG_LEVEL:-info}}",
              "PORT={{PORT:-3000}}"
            ],
            "\n"
          ) <> "\n",
        "/app/overrides.conf" =>
          Enum.join(
            [
              "DATABASE_URL=postgres://prod-db:5432/myapp",
              "SECRET_KEY=abc123secret",
              "PORT=8080"
            ],
            "\n"
          ) <> "\n"
      },
      validators: [
        {:file_contains, "/app/.env",
         [
           {:line_count, 5},
           {:regex, ~r/DATABASE_URL=postgres:\/\/prod-db:5432\/myapp/},
           {:regex, ~r/REDIS_URL=redis:\/\/localhost:6379/},
           {:regex, ~r/SECRET_KEY=abc123secret/},
           {:regex, ~r/LOG_LEVEL=info/},
           {:regex, ~r/PORT=8080/}
         ]},
        {:llm_judge,
         "Did the agent write a script that processes the template programmatically (using loops, sed, or grep) rather than hardcoding the exact 5 output values? Answer PASS if the approach is generalizable."}
      ]
    }
  end

  # --- Data deduplication with merge ---

  defp data_dedup do
    file1 =
      Enum.join(
        [
          "id,email,name",
          "1,alice@example.com,Alice Smith",
          "2,bob@example.com,Bob Jones",
          "3,charlie@example.com,Charlie Brown",
          "4,diana@example.com,Diana Prince"
        ],
        "\n"
      ) <> "\n"

    file2 =
      Enum.join(
        [
          "id,email,name",
          "3,charlie@example.com,Charlie Brown",
          "5,eve@example.com,Eve Wilson",
          "2,bob@corp.com,Bob Jones",
          "6,frank@example.com,Frank Castle"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "data_dedup",
      description: """
      You have two CSV files: /data/users1.csv and /data/users2.csv, both with
      columns: id, email, name. Merge them into /output/merged.csv by:

      1. Combine both files (skip duplicate headers)
      2. Deduplicate by id — if the same id appears in both files, keep the version
         from users2.csv (it's newer)
      3. Sort by id ascending
      4. Include a single header row

      The result should have exactly 6 unique users. Use sort, awk, or other
      text processing tools.
      """,
      files: %{"/data/users1.csv" => file1, "/data/users2.csv" => file2},
      validators: [
        {:file_contains, "/output/merged.csv",
         [
           {:line_count, 7},
           {:regex, ~r/^id,email,name/m},
           {:regex, ~r/alice@example\.com/},
           {:regex, ~r/bob@corp\.com/},
           {:regex, ~r/eve@example\.com/},
           {:regex, ~r/frank@example\.com/}
         ]},
        {:custom, "bob_uses_new_email",
         fn %{bash: bash} ->
           case JustBash.FS.read_file(bash.fs, "/output/merged.csv") do
             {:ok, content} ->
               if String.contains?(content, "bob@example.com"),
                 do: {:error, "bob should have bob@corp.com from users2, not bob@example.com"},
                 else: :ok

             {:error, _} ->
               {:error, "file not found"}
           end
         end}
      ]
    }
  end

  # --- CSV join: merge two CSVs on a shared key ---

  defp csv_join do
    employees =
      Enum.join(
        [
          "emp_id,name,dept_id",
          "E001,Alice,D10",
          "E002,Bob,D20",
          "E003,Charlie,D10",
          "E004,Diana,D30",
          "E005,Eve,D20"
        ],
        "\n"
      ) <> "\n"

    departments =
      Enum.join(
        [
          "dept_id,dept_name,location",
          "D10,Engineering,Building A",
          "D20,Marketing,Building B",
          "D30,Sales,Building C"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "csv_join",
      description: """
      You have two CSV files:
      - /data/employees.csv (emp_id, name, dept_id)
      - /data/departments.csv (dept_id, dept_name, location)

      Join them on dept_id to produce /output/joined.csv with columns:
        emp_id,name,dept_name,location
      (drop the dept_id column from the output). Sort by emp_id ascending.
      Include a header row.

      Use awk, grep, or other text processing tools to perform the join.
      """,
      files: %{"/data/employees.csv" => employees, "/data/departments.csv" => departments},
      validators: [
        {:command_used, "awk"},
        {:file_contains, "/output/joined.csv",
         [
           {:line_count, 6},
           {:regex, ~r/emp_id,name,dept_name,location/},
           {:regex, ~r/E001,Alice,Engineering,Building A/},
           {:regex, ~r/E002,Bob,Marketing,Building B/},
           {:regex, ~r/E004,Diana,Sales,Building C/}
         ]}
      ]
    }
  end

  # --- ETL pipeline: extract, transform, load ---

  defp pipeline_etl do
    sales =
      Enum.join(
        [
          "date,product,region,quantity,unit_price",
          "2024-01-01,Widget,North,10,25.00",
          "2024-01-01,Gadget,South,5,50.00",
          "2024-01-02,Widget,North,8,25.00",
          "2024-01-02,Widget,South,12,25.00",
          "2024-01-02,Gadget,North,3,50.00",
          "2024-01-03,Widget,North,15,25.00",
          "2024-01-03,Gadget,South,7,50.00",
          "2024-01-03,Widget,South,6,25.00"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "pipeline_etl",
      description: """
      You have sales data at /data/sales.csv. Build an ETL pipeline that produces
      three output files:

      1. /output/by_product.csv — aggregate by product:
         product,total_quantity,total_revenue
         sorted by total_revenue descending. Revenue = quantity * unit_price.

      2. /output/by_region.csv — aggregate by region:
         region,total_quantity,total_revenue
         sorted by region name ascending.

      3. /output/daily_summary.csv — aggregate by date:
         date,num_transactions,total_revenue
         sorted by date ascending.

      Include header rows in all files. Use awk for aggregation.
      """,
      files: %{"/data/sales.csv" => sales},
      validators: [
        {:command_used, "awk"},
        {:file_contains, "/output/by_product.csv",
         [
           {:regex, ~r/product,total_quantity,total_revenue/},
           {:regex, ~r/Widget/},
           {:regex, ~r/Gadget/}
         ]},
        {:file_contains, "/output/by_region.csv",
         [
           {:regex, ~r/region,total_quantity,total_revenue/},
           {:regex, ~r/North/},
           {:regex, ~r/South/}
         ]},
        {:file_contains, "/output/daily_summary.csv",
         [
           {:regex, ~r/date,num_transactions,total_revenue/},
           {:regex, ~r/2024-01-01/},
           {:regex, ~r/2024-01-02/},
           {:regex, ~r/2024-01-03/}
         ]},
        {:custom, "widget_revenue",
         fn %{bash: bash} ->
           case JustBash.FS.read_file(bash.fs, "/output/by_product.csv") do
             {:ok, content} ->
               widget_line =
                 content
                 |> String.split("\n")
                 |> Enum.find(&String.starts_with?(&1, "Widget"))

               case widget_line do
                 nil ->
                   {:error, "Widget row not found"}

                 line ->
                   # Widget: (10+8+12+15+6)*25 = 51*25 = 1275
                   if String.contains?(line, "1275"),
                     do: :ok,
                     else: {:error, "Widget total_revenue should be 1275, got: #{line}"}
               end

             {:error, _} ->
               {:error, "file not found"}
           end
         end}
      ]
    }
  end

  # --- Base64 encode/decode pipeline ---

  defp base64_pipeline do
    secret = "The secret password is: hunter2"
    encoded = Base.encode64(secret)

    %{
      name: "base64_pipeline",
      description: """
      You have an encoded file at /data/secret.b64 containing a base64-encoded message.
      1. Decode it and write the plaintext to /output/decoded.txt
      2. Then create a new file /output/re_encoded.b64 by base64-encoding the decoded content
      3. Verify they match by computing the sha256sum of each file (/data/secret.b64
         and /output/re_encoded.b64) and comparing the hashes. Write "MATCH" or
         "MISMATCH" to /output/verify.txt.

      Use the base64 command for encoding/decoding and sha256sum for verification.
      """,
      files: %{"/data/secret.b64" => encoded <> "\n"},
      validators: [
        {:command_used, "base64"},
        {:file_contains, "/output/decoded.txt", [{:regex, ~r/hunter2/}]},
        {:file_contains, "/output/verify.txt", [{:regex, ~r/MATCH/}]}
      ]
    }
  end

  # --- Checksum audit: verify file integrity ---

  defp checksum_audit do
    files = %{
      "/data/files/alpha.txt" => "Hello World\n",
      "/data/files/beta.txt" => "Goodbye World\n",
      "/data/files/gamma.txt" => "Changed Content\n"
    }

    # Pre-compute correct checksums for alpha and beta, wrong one for gamma
    alpha_hash = :crypto.hash(:sha256, "Hello World\n") |> Base.encode16(case: :lower)
    beta_hash = :crypto.hash(:sha256, "Goodbye World\n") |> Base.encode16(case: :lower)
    gamma_hash = :crypto.hash(:sha256, "Original Content\n") |> Base.encode16(case: :lower)

    checksums =
      Enum.join(
        [
          "#{alpha_hash}  /data/files/alpha.txt",
          "#{beta_hash}  /data/files/beta.txt",
          "#{gamma_hash}  /data/files/gamma.txt"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "checksum_audit",
      description: """
      You have files under /data/files/ and a checksum manifest at /data/checksums.txt
      (in sha256sum format: "hash  filepath"). Some files may have been modified since
      the checksums were generated.

      Verify each file against its expected checksum and write a report to
      /output/audit.txt with one line per file in the format:
        filepath: OK
      or
        filepath: FAILED

      At the end, add a summary line: "X of Y files OK"
      Use sha256sum to compute current checksums and compare.
      """,
      files: Map.merge(files, %{"/data/checksums.txt" => checksums}),
      validators: [
        {:command_used, "sha256sum"},
        {:file_contains, "/output/audit.txt",
         [
           {:regex, ~r/alpha\.txt.*OK/},
           {:regex, ~r/beta\.txt.*OK/},
           {:regex, ~r/gamma\.txt.*FAIL/},
           {:regex, ~r/2 of 3/}
         ]}
      ]
    }
  end
end
