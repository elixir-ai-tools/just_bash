defmodule JustBash.Eval.Tasks.ShellFeatures do
  @moduledoc """
  Eval tasks focused on shell features: loops, functions, set operations,
  pipelines with tee/paste/xargs/comm, date generation, and nested loops.
  """

  @behaviour JustBash.Eval.Task

  @impl true
  def tasks do
    [
      nginx_vhost_generator(),
      function_library(),
      nested_loop_matrix(),
      date_range_generator(),
      tee_pipeline(),
      set_operations(),
      column_joiner(),
      xargs_batch_processor()
    ]
  end

  # --- Nginx virtual host generator ---

  defp nginx_vhost_generator do
    domains =
      Enum.join(
        [
          "example.com:8080:/var/www/example",
          "api.example.com:3000:/var/www/api",
          "blog.example.com:4000:/var/www/blog"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "nginx_vhost_generator",
      description: """
      You have a domain configuration at /data/domains.txt where each line is:
        domain:port:document_root

      Generate Nginx virtual host config files under /output/sites/ — one file per domain
      named <domain>.conf. Each file should contain a server block like:

      server {
          listen 80;
          server_name <domain>;
          root <document_root>;

          location / {
              proxy_pass http://127.0.0.1:<port>;
          }
      }

      Also create /output/sites/all_domains.txt listing all domain names, one per line, sorted.
      """,
      files: %{"/data/domains.txt" => domains},
      validators: [
        {:file_contains, "/output/sites/example.com.conf",
         [
           {:regex, ~r/server_name\s+example\.com/},
           {:regex, ~r/proxy_pass\s+http:\/\/127\.0\.0\.1:8080/},
           {:regex, ~r/root\s+\/var\/www\/example/}
         ]},
        {:file_contains, "/output/sites/api.example.com.conf",
         [
           {:regex, ~r/proxy_pass\s+http:\/\/127\.0\.0\.1:3000/}
         ]},
        {:file_contains, "/output/sites/all_domains.txt",
         [
           {:line_count, 3}
         ]}
      ]
    }
  end

  # --- Function library: shell functions and case statements ---

  defp function_library do
    data =
      Enum.join(
        [
          "photo_001.jpg 2048000",
          "document.pdf 524288",
          "song.mp3 4194304",
          "video.mp4 104857600",
          "notes.txt 1024",
          "archive.tar.gz 10485760",
          "script.sh 512",
          "image.png 8388608",
          "readme.md 2048",
          "backup.zip 52428800"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "function_library",
      description: """
      You have a file at /data/files.txt with one entry per line:
        filename size_in_bytes

      Write a single script that defines and uses shell functions to:
      1. `classify_file` — takes a filename and prints its category based on extension:
         - jpg, jpeg, png, gif, bmp -> "image"
         - mp3, wav, flac, ogg -> "audio"
         - mp4, avi, mkv, mov -> "video"
         - pdf, doc, docx, odt -> "document"
         - tar.gz, zip, rar, 7z -> "archive"
         - Everything else -> "other"
         Use a `case` statement with glob patterns.

      2. `format_size` — takes bytes and prints a human-readable size:
         - >= 1048576 (1MB): print as "X.XMB" (use integer arithmetic: MB = bytes/1048576)
         - >= 1024: print as "X.XKB" (KB = bytes/1024)
         - Otherwise: print as "NB"

      Process each line of /data/files.txt and produce /output/catalog.txt with:
        filename | category | human_size
      one per line, sorted by category then filename.

      Also produce /output/category_summary.txt with:
        category: count
      sorted by category name.

      IMPORTANT: All logic MUST go in a single tool call since functions
      don't persist between calls.
      """,
      files: %{"/data/files.txt" => data},
      validators: [
        {:file_contains, "/output/catalog.txt",
         [
           {:line_count, 10},
           {:regex, ~r/photo_001\.jpg.*image/},
           {:regex, ~r/video\.mp4.*video/},
           {:regex, ~r/notes\.txt.*other/},
           {:regex, ~r/archive\.tar\.gz.*archive/}
         ]},
        {:file_contains, "/output/category_summary.txt",
         [
           {:regex, ~r/image: 2/},
           {:regex, ~r/archive: 2/},
           {:regex, ~r/video: 1/}
         ]}
      ]
    }
  end

  # --- Nested loop matrix: generate a multiplication table ---

  defp nested_loop_matrix do
    %{
      name: "nested_loop_matrix",
      description: """
      Generate a formatted multiplication table for 1 through 8 and write it
      to /output/table.txt.

      The table should have:
      1. A header row with column numbers: "  x |  1   2   3   4   5   6   7   8"
      2. A separator line of dashes: "----+----------------------------------------" (or similar)
      3. One row per multiplier (1-8), formatted as:
         "  N | R1  R2  R3  R4  R5  R6  R7  R8"
         where each result is right-aligned to 3 characters width.

      Use nested loops and `printf` for formatting.

      Also create /output/diagonal.txt containing just the diagonal values
      (1*1, 2*2, 3*3, ... 8*8), one per line: 1, 4, 9, 16, 25, 36, 49, 64.
      """,
      files: %{},
      validators: [
        {:file_contains, "/output/table.txt",
         [
           {:regex, ~r/\d.*\|.*1.*2.*3.*4.*5.*6.*7.*8/},
           {:regex, ~r/3.*\|.*3.*6.*9.*12.*15.*18.*21.*24/}
         ]},
        {:file_contains, "/output/diagonal.txt",
         [
           {:line_count, 8},
           {:regex, ~r/^1$/m},
           {:regex, ~r/^4$/m},
           {:regex, ~r/^9$/m},
           {:regex, ~r/^64$/m}
         ]}
      ]
    }
  end

  # --- Date range generator: generate date-based file structure ---

  defp date_range_generator do
    %{
      name: "date_range_generator",
      description: """
      Generate a log directory structure for the first 7 days of January 2024.

      For each day (2024-01-01 through 2024-01-07), create:
      - /logs/2024-01-DD/access.log containing "Access log for 2024-01-DD"
      - /logs/2024-01-DD/error.log containing "Error log for 2024-01-DD"

      Use a counter variable and a while loop (or for loop with seq 1 7).
      Use `printf` to zero-pad the day number.

      Then create /output/index.txt listing all the directories created, one per
      line, sorted. Example: "2024-01-01" on the first line.

      Also write /output/stats.txt with:
        directories: 7
        files: 14
        total_size: N
      where N is the sum of all file sizes.
      """,
      files: %{},
      validators: [
        {:file_contains, "/output/index.txt",
         [
           {:line_count, 7},
           {:regex, ~r/2024-01-01/},
           {:regex, ~r/2024-01-07/}
         ]},
        {:file_contains, "/output/stats.txt",
         [
           {:regex, ~r/directories: 7/},
           {:regex, ~r/files: 14/},
           {:regex, ~r/total_size: \d+/}
         ]},
        {:custom, "day3_access_log",
         fn %{bash: bash} ->
           case JustBash.Fs.InMemoryFs.read_file(bash.fs, "/logs/2024-01-03/access.log") do
             {:ok, content} ->
               if String.contains?(content, "2024-01-03"),
                 do: :ok,
                 else: {:error, "access.log for day 3 doesn't contain correct date"}

             {:error, _} ->
               {:error, "/logs/2024-01-03/access.log not found"}
           end
         end}
      ]
    }
  end

  # --- Tee pipeline: split output to multiple destinations ---

  defp tee_pipeline do
    log =
      Enum.join(
        [
          "2024-01-01 10:00:00 INFO Starting application",
          "2024-01-01 10:00:01 DEBUG Loading config from /etc/app.conf",
          "2024-01-01 10:00:02 INFO Server listening on port 8080",
          "2024-01-01 10:00:05 WARN High memory usage: 85%",
          "2024-01-01 10:00:10 ERROR Connection to database failed",
          "2024-01-01 10:00:11 INFO Retrying database connection",
          "2024-01-01 10:00:15 ERROR Timeout waiting for database",
          "2024-01-01 10:00:20 DEBUG Cleanup routine started",
          "2024-01-01 10:00:25 WARN Disk usage above 90%",
          "2024-01-01 10:00:30 INFO Application shutdown requested"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "tee_pipeline",
      description: """
      You have an application log at /var/log/app.log with timestamped entries
      at different log levels (INFO, DEBUG, WARN, ERROR).

      Create a log routing pipeline that splits the log into separate files by
      severity level. Use `tee` to write to files while continuing the pipeline.

      Produce:
      1. /output/errors.log — only ERROR lines
      2. /output/warnings.log — only WARN lines
      3. /output/info.log — only INFO lines
      4. /output/debug.log — only DEBUG lines
      5. /output/important.log — both ERROR and WARN lines combined, sorted by timestamp

      Use `tee` at least once in your pipeline.

      Finally, create /output/summary.txt with:
        total: N
        info: I
        debug: D
        warn: W
        error: E
      """,
      files: %{"/var/log/app.log" => log},
      validators: [
        {:command_used, "tee"},
        {:file_contains, "/output/errors.log",
         [
           {:line_count, 2},
           {:regex, ~r/ERROR/}
         ]},
        {:file_contains, "/output/warnings.log",
         [
           {:line_count, 2},
           {:regex, ~r/WARN/}
         ]},
        {:file_contains, "/output/important.log",
         [
           {:line_count, 4},
           {:regex, ~r/ERROR/},
           {:regex, ~r/WARN/}
         ]},
        {:file_contains, "/output/summary.txt",
         [
           {:regex, ~r/total: 10/},
           {:regex, ~r/error: 2/},
           {:regex, ~r/warn: 2/}
         ]}
      ]
    }
  end

  # --- Set operations with comm: compare sorted file lists ---

  defp set_operations do
    prod =
      Enum.join(
        [
          "api-gateway",
          "auth-service",
          "billing-service",
          "cache-service",
          "notification-service",
          "payment-service",
          "user-service",
          "web-frontend"
        ],
        "\n"
      ) <> "\n"

    staging =
      Enum.join(
        [
          "api-gateway",
          "auth-service",
          "cache-service",
          "feature-flags",
          "notification-service",
          "search-service",
          "user-service",
          "web-frontend"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "set_operations",
      description: """
      You have two sorted lists of microservice names:
      - /data/prod_services.txt — services deployed in production
      - /data/staging_services.txt — services deployed in staging

      Using `comm` (which compares two sorted files), produce three output files:
      1. /output/prod_only.txt — services in prod but NOT staging (one per line)
      2. /output/staging_only.txt — services in staging but NOT prod (one per line)
      3. /output/both.txt — services in both environments (one per line)

      Also create /output/summary.txt with exactly 3 lines:
        prod_only: N
        staging_only: M
        both: K
      where N, M, K are the counts.

      Use `comm` to compute the three sets.
      """,
      files: %{
        "/data/prod_services.txt" => prod,
        "/data/staging_services.txt" => staging
      },
      validators: [
        {:command_used, "comm"},
        {:file_contains, "/output/prod_only.txt",
         [
           {:line_count, 2},
           {:regex, ~r/billing-service/},
           {:regex, ~r/payment-service/}
         ]},
        {:file_contains, "/output/staging_only.txt",
         [
           {:line_count, 2},
           {:regex, ~r/feature-flags/},
           {:regex, ~r/search-service/}
         ]},
        {:file_contains, "/output/both.txt",
         [
           {:line_count, 6},
           {:regex, ~r/api-gateway/},
           {:regex, ~r/user-service/}
         ]},
        {:file_contains, "/output/summary.txt",
         [
           {:line_count, 3},
           {:regex, ~r/prod_only: 2/},
           {:regex, ~r/staging_only: 2/},
           {:regex, ~r/both: 6/}
         ]}
      ]
    }
  end

  # --- Column joiner: merge files side-by-side with paste ---

  defp column_joiner do
    names =
      Enum.join(["Alice", "Bob", "Charlie", "Diana", "Eve"], "\n") <> "\n"

    scores =
      Enum.join(["92", "87", "95", "78", "91"], "\n") <> "\n"

    grades =
      Enum.join(["A", "B+", "A", "C+", "A-"], "\n") <> "\n"

    %{
      name: "column_joiner",
      description: """
      You have three files with aligned data (same number of lines, one value per line):
      - /data/names.txt — student names
      - /data/scores.txt — numeric scores
      - /data/grades.txt — letter grades

      Use `paste` to combine them into a single file /output/report.csv:
      1. First use `paste -d,` to join all three files with comma delimiters.
      2. Prepend a header line "name,score,grade" to the output.
      3. Also create /output/top_students.txt containing only students with
         score >= 90, one name per line, sorted alphabetically. Use awk on
         the CSV to filter by score field.
      """,
      files: %{
        "/data/names.txt" => names,
        "/data/scores.txt" => scores,
        "/data/grades.txt" => grades
      },
      validators: [
        {:command_used, "paste"},
        {:file_contains, "/output/report.csv",
         [
           {:line_count, 6},
           {:regex, ~r/name,score,grade/},
           {:regex, ~r/Alice,92,A/},
           {:regex, ~r/Charlie,95,A/}
         ]},
        {:file_contains, "/output/top_students.txt",
         [
           {:line_count, 3},
           {:regex, ~r/Alice/},
           {:regex, ~r/Charlie/},
           {:regex, ~r/Eve/}
         ]}
      ]
    }
  end

  # --- Xargs batch processor: parallel-style processing ---

  defp xargs_batch_processor do
    urls =
      Enum.join(
        [
          "/api/users",
          "/api/products",
          "/api/orders",
          "/api/categories",
          "/api/reviews",
          "/api/inventory",
          "/api/payments",
          "/api/shipping"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "xargs_batch_processor",
      description: """
      You have a file /data/endpoints.txt with API endpoint paths, one per line.

      Use `xargs` to batch-process these endpoints:

      1. Use `cat /data/endpoints.txt | xargs -I{} echo "GET {}"` to generate
         a list of HTTP-style request lines. Write to /output/requests.txt.

      2. Create a /output/report.json using jq. The JSON should be an object with:
         - "total_endpoints": count of endpoints
         - "endpoints": array of objects, each with "path" and "method" keys
           Example: {"path": "/api/users", "method": "GET"}
         Sort the endpoints array by path.

      3. Create /output/by_resource.txt grouping endpoints by their resource
         (the part after /api/). Format:
           resource: endpoint_count
         sorted alphabetically. Use awk or cut to extract the resource name
         and `sort | uniq -c` to count.
      """,
      files: %{"/data/endpoints.txt" => urls},
      validators: [
        {:command_used, "xargs"},
        {:file_contains, "/output/requests.txt",
         [
           {:line_count, 8},
           {:regex, ~r/GET \/api\/users/},
           {:regex, ~r/GET \/api\/products/}
         ]},
        {:file_contains, "/output/report.json",
         [
           {:json,
            fn data ->
              cond do
                data["total_endpoints"] != 8 ->
                  {:error, "expected total_endpoints=8, got #{inspect(data["total_endpoints"])}"}

                not is_list(data["endpoints"]) ->
                  {:error, "endpoints should be an array"}

                length(data["endpoints"]) != 8 ->
                  {:error, "expected 8 endpoints, got #{length(data["endpoints"])}"}

                true ->
                  :ok
              end
            end}
         ]},
        {:file_contains, "/output/by_resource.txt",
         [
           {:line_count, 8},
           {:regex, ~r/users/},
           {:regex, ~r/products/}
         ]}
      ]
    }
  end
end
