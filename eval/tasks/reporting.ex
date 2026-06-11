defmodule JustBash.Eval.Tasks.Reporting do
  @moduledoc """
  Reporting-oriented eval tasks: install script, crontab parsing, markdown tables,
  access log stats, ASCII bar charts, disk usage reports, numbered reports, and diff patching.
  """

  @behaviour JustBash.Eval.Task

  @impl true
  def tasks do
    [
      install_script(),
      crontab_parser(),
      markdown_table(),
      access_log_stats(),
      ascii_bar_chart(),
      disk_usage_report(),
      numbered_report(),
      diff_patcher()
    ]
  end

  # --- Realistic: parse a Dockerfile and extract metadata as JSON ---

  defp install_script do
    %{
      name: "install_script",
      description: """
      You have a Dockerfile at /app/Dockerfile. Parse it and produce a JSON report
      at /output/dockerfile_report.json with the following fields:
      - "base_image": the image from the FROM instruction (string)
      - "exposed_ports": array of port numbers (integers) from EXPOSE instructions
      - "env_vars": object mapping ENV variable names to their values
      - "num_run_commands": count of RUN instructions (integer)

      Use grep/awk to extract values and jq to construct the JSON.
      """,
      files: %{
        "/app/Dockerfile" =>
          Enum.join(
            [
              "FROM elixir:1.15-alpine",
              "ENV MIX_ENV=prod",
              "ENV PORT=4000",
              "ENV SECRET_KEY_BASE=supersecret123",
              "WORKDIR /app",
              "COPY mix.exs mix.lock ./",
              "RUN mix deps.get --only prod",
              "RUN mix deps.compile",
              "COPY . .",
              "RUN mix compile",
              "RUN mix release",
              "EXPOSE 4000",
              "EXPOSE 4001",
              ~s(CMD ["_build/prod/rel/myapp/bin/myapp", "start"])
            ],
            "\n"
          ) <> "\n"
      },
      validators: [
        {:file_contains, "/output/dockerfile_report.json",
         [
           {:json,
            fn data ->
              cond do
                data["base_image"] != "elixir:1.15-alpine" ->
                  {:error,
                   "base_image: expected elixir:1.15-alpine, got #{inspect(data["base_image"])}"}

                Enum.sort(data["exposed_ports"] || []) != [4000, 4001] ->
                  {:error,
                   "exposed_ports: expected [4000,4001], got #{inspect(data["exposed_ports"])}"}

                not is_map(data["env_vars"]) ->
                  {:error, "env_vars should be an object"}

                data["env_vars"]["MIX_ENV"] != "prod" ->
                  {:error, "env_vars.MIX_ENV should be 'prod'"}

                data["num_run_commands"] != 4 ->
                  {:error,
                   "num_run_commands: expected 4, got #{inspect(data["num_run_commands"])}"}

                true ->
                  :ok
              end
            end}
         ]},
        {:command_used, "grep"}
      ]
    }
  end

  # --- 13. Crontab parser: extract schedule metadata from cron entries ---

  defp crontab_parser do
    crontab =
      Enum.join(
        [
          "# Database backups",
          "0 2 * * * /usr/bin/pg_dump mydb > /backups/db.sql",
          "30 3 * * 0 /usr/bin/full_backup.sh",
          "",
          "# App maintenance",
          "*/15 * * * * /usr/bin/health_check.sh",
          "0 0 1 * * /usr/bin/rotate_logs.sh",
          "0 6,18 * * 1-5 /usr/bin/report_gen.sh"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "crontab_parser",
      description: """
      You have a crontab file at /etc/crontab. Parse it and produce a JSON report at
      /output/cron_report.json with the following structure:
      {
        "total_jobs": <number>,
        "jobs": [
          {"schedule": "<cron expression>", "command": "<command path>", "frequency": "<human readable>"},
          ...
        ]
      }

      For "frequency", use simple descriptions like "daily", "weekly", "every 15 minutes",
      "monthly", or describe the schedule briefly. Extract the command as just the executable
      path (first element after the 5 cron fields, without arguments).

      Skip comment lines and blank lines. Use grep/sed/awk to parse, and jq to build the JSON.
      """,
      files: %{"/etc/crontab" => crontab},
      validators: [
        {:file_contains, "/output/cron_report.json",
         [
           {:json,
            fn data ->
              cond do
                data["total_jobs"] != 5 ->
                  {:error, "expected 5 jobs, got #{inspect(data["total_jobs"])}"}

                not is_list(data["jobs"]) ->
                  {:error, "jobs should be an array"}

                length(data["jobs"]) != 5 ->
                  {:error, "expected 5 job entries, got #{length(data["jobs"])}"}

                not Enum.all?(data["jobs"], &(is_binary(&1["command"]) and &1["command"] != "")) ->
                  {:error, "all jobs must have a non-empty command string"}

                true ->
                  :ok
              end
            end}
         ]},
        {:command_used, "grep"}
      ]
    }
  end

  # --- 14. Markdown table generation from raw data ---

  defp markdown_table do
    data =
      Enum.join(
        [
          "product:price:quantity:category",
          "Widget A:9.99:150:hardware",
          "Gadget B:24.50:75:electronics",
          "Tool C:5.00:300:hardware",
          "Device D:49.99:20:electronics",
          "Part E:2.50:500:hardware"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "markdown_table",
      description: """
      You have a colon-delimited data file at /data/products.txt (header: product:price:quantity:category).
      Generate a Markdown report at /output/report.md with:

      1. A heading "# Product Report"
      2. A Markdown table with columns: Product, Price, Quantity, Category, Total Value
         where Total Value = price * quantity (formatted as a plain number, no currency symbol needed)
      3. A summary line below the table: "**Total inventory value: X**" where X is the sum
         of all Total Value entries

      Use awk to compute values. The table must have proper Markdown table formatting
      (header row, separator row with dashes, data rows, all pipe-delimited).
      """,
      files: %{"/data/products.txt" => data},
      validators: [
        {:command_used, "awk"},
        {:file_contains, "/output/report.md",
         [
           {:regex, ~r/# Product Report/},
           {:regex, ~r/\|.*Product.*\|.*Price.*\|/},
           {:regex, ~r/\|[-\s|:]+\|/},
           {:regex, ~r/Widget A/},
           {:regex, ~r/Total inventory value/}
         ]},
        {:custom, "has_all_products",
         fn %{bash: bash} ->
           case JustBash.Fs.read_file(bash.fs, "/output/report.md") do
             {:ok, content} ->
               products = ["Widget A", "Gadget B", "Tool C", "Device D", "Part E"]
               missing = Enum.reject(products, &String.contains?(content, &1))

               if missing == [],
                 do: :ok,
                 else: {:error, "missing products: #{inspect(missing)}"}

             {:error, _} ->
               {:error, "file not found"}
           end
         end}
      ]
    }
  end

  # --- 16. Access log statistics: awk-heavy analytics ---

  defp access_log_stats do
    log =
      Enum.join(
        [
          ~s(192.168.1.1 - - [01/Jan/2024:10:00:00] "GET /index.html HTTP/1.1" 200 1024),
          ~s(192.168.1.2 - - [01/Jan/2024:10:01:00] "POST /api/login HTTP/1.1" 200 512),
          ~s(192.168.1.1 - - [01/Jan/2024:10:02:00] "GET /about.html HTTP/1.1" 200 2048),
          ~s(10.0.0.5 - - [01/Jan/2024:10:03:00] "GET /index.html HTTP/1.1" 304 0),
          ~s(192.168.1.1 - - [01/Jan/2024:10:04:00] "GET /api/users HTTP/1.1" 500 128),
          ~s(192.168.1.2 - - [01/Jan/2024:10:05:00] "GET /index.html HTTP/1.1" 200 1024),
          ~s(10.0.0.5 - - [01/Jan/2024:10:06:00] "POST /api/login HTTP/1.1" 401 64),
          ~s(192.168.1.3 - - [01/Jan/2024:10:07:00] "GET /contact.html HTTP/1.1" 200 768),
          ~s(192.168.1.1 - - [01/Jan/2024:10:08:00] "GET /index.html HTTP/1.1" 200 1024),
          ~s(10.0.0.5 - - [01/Jan/2024:10:09:00] "GET /api/users HTTP/1.1" 403 128)
        ],
        "\n"
      ) <> "\n"

    %{
      name: "access_log_stats",
      description: """
      You have a web server access log at /var/log/access.log in common log format.
      Analyze it and produce /output/stats.txt with the following sections:

      1. "Total requests: N"
      2. "Unique IPs: N"
      3. "Top IP:" followed by the IP with the most requests and its count
      4. "Status codes:" followed by lines showing each status code and count,
         sorted by code (e.g., "  200: 6")
      5. "Error rate: X%" — percentage of requests with status >= 400

      Use awk for the heavy lifting. The exact format should match what's described above.
      """,
      files: %{"/var/log/access.log" => log},
      validators: [
        {:command_used, "awk"},
        {:file_contains, "/output/stats.txt",
         [
           {:regex, ~r/Total requests:\s*10/},
           {:regex, ~r/Unique IPs:\s*4/},
           {:regex, ~r/192\.168\.1\.1/},
           {:regex, ~r/200:\s*6/},
           {:regex, ~r/Error rate:\s*30/}
         ]}
      ]
    }
  end

  # --- 20. ASCII bar chart from data ---

  defp ascii_bar_chart do
    data =
      Enum.join(
        [
          "JavaScript:45",
          "Python:38",
          "Rust:12",
          "Go:22",
          "Elixir:8"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "ascii_bar_chart",
      description: """
      You have a data file at /data/languages.txt with lines in the format "Language:Count".
      Generate an ASCII horizontal bar chart at /output/chart.txt.

      Format each line as:
        Language   | ####... | Count
      where # characters represent the count (one # per unit value). Left-pad the language
      name to 12 characters for alignment. Sort by count descending (highest first).

      Example line: "  JavaScript | ############################################# | 45"

      Use awk or printf for formatting.
      """,
      files: %{"/data/languages.txt" => data},
      validators: [
        {:file_contains, "/output/chart.txt",
         [
           {:line_count, 5},
           {:regex, ~r/JavaScript/},
           {:regex, ~r/Elixir/},
           {:regex, ~r/\#{3,}/}
         ]},
        {:custom, "correct_order",
         fn %{bash: bash} ->
           case JustBash.Fs.read_file(bash.fs, "/output/chart.txt") do
             {:ok, content} ->
               lines =
                 content |> String.trim() |> String.split("\n") |> Enum.map(&String.trim/1)

               first_has_js = String.contains?(hd(lines), "JavaScript")
               last_has_elixir = String.contains?(List.last(lines), "Elixir")

               if first_has_js and last_has_elixir,
                 do: :ok,
                 else: {:error, "expected JavaScript first and Elixir last (by count desc)"}

             {:error, _} ->
               {:error, "file not found"}
           end
         end}
      ]
    }
  end

  # --- 33. Disk usage report: analyze directory sizes with du and stat ---

  defp disk_usage_report do
    %{
      name: "disk_usage_report",
      description: """
      You have a project directory /project/ with several files and subdirectories.
      Generate a disk usage report at /output/usage.txt.

      The report should contain:
      1. A header: "Disk Usage Report"
      2. A blank line
      3. For each file (found with `find /project -type f`), a line showing:
         filename<TAB>size_in_bytes
         Sort these lines by size descending (largest first).
      4. A blank line
      5. "Total files: N"
      6. "Total bytes: B"
      7. "Largest file: FILENAME (SIZE bytes)"
      """,
      files: %{
        "/project/README.md" => "# Project\n\nA description of the project with some content.\n",
        "/project/src/main.py" =>
          "import sys\n\ndef main():\n    print('Hello')\n\nif __name__ == '__main__':\n    main()\n",
        "/project/src/utils.py" => "def helper():\n    pass\n",
        "/project/tests/test_main.py" =>
          "import unittest\n\nclass TestMain(unittest.TestCase):\n    def test_hello(self):\n        self.assertTrue(True)\n",
        "/project/config.json" => "{\"debug\": true, \"port\": 8080}\n"
      },
      validators: [
        {:file_contains, "/output/usage.txt",
         [
           {:regex, ~r/Disk Usage Report/},
           {:regex, ~r/Total files: 5/},
           {:regex, ~r/Total bytes: \d+/},
           {:regex, ~r/Largest file:/}
         ]},
        {:custom, "largest_file_check",
         fn %{bash: bash} ->
           case JustBash.Fs.read_file(bash.fs, "/output/usage.txt") do
             {:ok, content} ->
               # test_main.py is the largest file
               if String.contains?(content, "test_main.py"),
                 do: :ok,
                 else: {:error, "expected test_main.py to appear as it's the largest file"}

             {:error, _} ->
               {:error, "file not found"}
           end
         end}
      ]
    }
  end

  # --- 32. Numbered report: add line numbers with nl ---

  defp numbered_report do
    code =
      Enum.join(
        [
          "#!/bin/bash",
          "",
          "# Configuration",
          "APP_NAME=\"myapp\"",
          "APP_PORT=3000",
          "",
          "# Functions",
          "start_server() {",
          "    echo \"Starting $APP_NAME on port $APP_PORT\"",
          "    echo \"Server running...\"",
          "}",
          "",
          "stop_server() {",
          "    echo \"Stopping $APP_NAME\"",
          "}",
          "",
          "# Main",
          "start_server"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "numbered_report",
      description: """
      You have a bash script at /src/server.sh.

      Generate a code review report at /output/review.txt that contains:
      1. A header line: "Code Review: server.sh"
      2. A blank line
      3. The full script with line numbers added by `nl` (using `nl -ba` to number
         ALL lines including blank ones).
      4. A blank line
      5. A summary section:
         - "Total lines: N" (use `wc -l`)
         - "Comment lines: M" (lines starting with #, use `grep -c`)
         - "Blank lines: K" (empty lines, use `grep -c`)
         - "Code lines: J" (total - comments - blank)
      """,
      files: %{"/src/server.sh" => code},
      validators: [
        {:command_used, "nl"},
        {:file_contains, "/output/review.txt",
         [
           {:regex, ~r/Code Review: server\.sh/},
           {:regex, ~r/Total lines: 18/},
           {:regex, ~r/Comment lines: 4/},
           {:regex, ~r/Blank lines: 4/},
           {:regex, ~r/Code lines: 10/}
         ]}
      ]
    }
  end

  # --- 31. Diff patcher: compare files and generate a patch report ---

  defp diff_patcher do
    original =
      Enum.join(
        [
          "server {",
          "    listen 80;",
          "    server_name example.com;",
          "    root /var/www/html;",
          "    index index.html;",
          "    error_log /var/log/nginx/error.log;",
          "}"
        ],
        "\n"
      ) <> "\n"

    updated =
      Enum.join(
        [
          "server {",
          "    listen 443 ssl;",
          "    server_name example.com;",
          "    root /var/www/html;",
          "    index index.html index.htm;",
          "    error_log /var/log/nginx/error.log warn;",
          "    ssl_certificate /etc/ssl/cert.pem;",
          "}"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "diff_patcher",
      description: """
      You have two versions of an Nginx config file:
      - /config/nginx.conf.old — the original
      - /config/nginx.conf.new — the updated version

      Generate a change report at /output/changes.txt that contains:
      1. The output of `diff /config/nginx.conf.old /config/nginx.conf.new`
      2. After a blank line, a summary section with:
         - "Lines added: N" (count of lines starting with + that are NOT +++)
         - "Lines removed: M" (count of lines starting with - that are NOT ---)

      Use `diff` (unified format is the default) and `grep -c` to count.
      """,
      files: %{
        "/config/nginx.conf.old" => original,
        "/config/nginx.conf.new" => updated
      },
      validators: [
        {:command_used, "diff"},
        {:file_contains, "/output/changes.txt",
         [
           {:regex, ~r/listen 443 ssl/},
           {:regex, ~r/Lines added: \d+/},
           {:regex, ~r/Lines removed: \d+/}
         ]}
      ]
    }
  end
end
