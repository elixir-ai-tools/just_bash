defmodule JustBash.Eval.Tasks.TextProcessing do
  @moduledoc """
  Text processing eval tasks: sed config rewrite, grep pipeline, word frequency,
  INI to env conversion, and git log changelog generation.
  """

  @behaviour JustBash.Eval.Task

  @impl true
  def tasks do
    [
      sed_config_rewrite(),
      grep_pipeline(),
      word_frequency(),
      ini_to_env(),
      git_log_changelog()
    ]
  end

  # --- sed: find-and-replace in config files ---

  defp sed_config_rewrite do
    %{
      name: "sed_config_rewrite",
      description: """
      You have a configuration file at /etc/app.conf in KEY=VALUE format.
      Use sed (and any other tools) to:
      1. Change the DATABASE_HOST from "localhost" to "db.production.internal"
      2. Change the DATABASE_PORT from "5432" to "5433"
      3. Change LOG_LEVEL from "debug" to "warn"
      4. Add a new line "CACHE_ENABLED=true" at the end if it doesn't exist
      Write the result back to /etc/app.conf.
      """,
      files: %{
        "/etc/app.conf" =>
          Enum.join(
            [
              "APP_NAME=myapp",
              "DATABASE_HOST=localhost",
              "DATABASE_PORT=5432",
              "LOG_LEVEL=debug",
              "MAX_CONNECTIONS=100"
            ],
            "\n"
          )
      },
      validators: [
        {:command_used, "sed"},
        {:file_contains, "/etc/app.conf",
         [
           {:regex, ~r/DATABASE_HOST="?db\.production\.internal"?/},
           {:regex, ~r/DATABASE_PORT="?5433"?/},
           {:regex, ~r/LOG_LEVEL="?warn"?/},
           {:regex, ~r/CACHE_ENABLED="?true"?/},
           {:regex, ~r/APP_NAME="?myapp"?/},
           {:regex, ~r/MAX_CONNECTIONS="?100"?/}
         ]}
      ]
    }
  end

  # --- grep + sed + sort + uniq: log analysis pipeline ---

  defp grep_pipeline do
    %{
      name: "grep_pipeline",
      description: """
      You have a log file at /var/log/app.log. Find all ERROR lines, extract the
      unique error messages (the part after "ERROR: "), sort them alphabetically,
      and write the count of unique errors as the first line followed by each
      unique error message on its own line to /output/errors.txt.
      """,
      files: %{
        "/var/log/app.log" =>
          Enum.join(
            [
              "2024-01-01 10:00:00 INFO: Server started",
              "2024-01-01 10:01:00 ERROR: Connection refused",
              "2024-01-01 10:02:00 INFO: Request processed",
              "2024-01-01 10:03:00 ERROR: Timeout exceeded",
              "2024-01-01 10:04:00 WARN: High memory usage",
              "2024-01-01 10:05:00 ERROR: Connection refused",
              "2024-01-01 10:06:00 ERROR: Disk full",
              "2024-01-01 10:07:00 INFO: Request processed",
              "2024-01-01 10:08:00 ERROR: Timeout exceeded",
              "2024-01-01 10:09:00 ERROR: Connection refused"
            ],
            "\n"
          )
      },
      validators: [
        {:command_used, "grep"},
        {:file_contains, "/output/errors.txt",
         [
           {:not_empty},
           {:regex, ~r/Connection refused/},
           {:regex, ~r/Disk full/},
           {:regex, ~r/Timeout exceeded/}
         ]},
        {:custom, "correct_count",
         fn %{bash: bash} ->
           case JustBash.FS.read_file(bash.fs, "/output/errors.txt") do
             {:ok, content} ->
               first_line = content |> String.split("\n") |> hd() |> String.trim()

               if first_line == "3",
                 do: :ok,
                 else: {:error, "first line should be '3', got '#{first_line}'"}

             {:error, _} ->
               {:error, "file not found"}
           end
         end},
        {:llm_judge,
         "Did the agent use a pipeline approach (grep | sed | sort | uniq or similar) rather than manually constructing the output?"}
      ]
    }
  end

  # --- 10. Word frequency: classic Unix text pipeline ---

  defp word_frequency do
    text = """
    the quick brown fox jumps over the lazy dog
    the dog barked at the fox and the fox ran away
    a quick red fox outran the brown dog easily
    the lazy dog slept while the quick fox played
    """

    %{
      name: "word_frequency",
      description: """
      You have a text file at /data/passage.txt. Compute word frequencies and write
      the top 5 most frequent words to /output/top_words.txt in the format:
        COUNT WORD
      one per line, sorted by count descending (highest first). In case of ties,
      sort alphabetically by word. Normalize to lowercase.

      Use standard Unix text processing tools (tr, sort, uniq, etc.).
      """,
      files: %{"/data/passage.txt" => text},
      validators: [
        {:command_used, "sort"},
        {:command_used, "uniq"},
        {:file_contains, "/output/top_words.txt",
         [
           {:line_count, 5},
           {:regex, ~r/the/}
         ]},
        {:custom, "top_word_is_the",
         fn %{bash: bash} ->
           case JustBash.FS.read_file(bash.fs, "/output/top_words.txt") do
             {:ok, content} ->
               first_line =
                 content |> String.trim() |> String.split("\n") |> hd() |> String.trim()

               if String.contains?(first_line, "the"),
                 do: :ok,
                 else: {:error, "first word should be 'the', got: #{first_line}"}

             {:error, _} ->
               {:error, "file not found"}
           end
         end}
      ]
    }
  end

  # --- 18. INI config to environment variables ---

  defp ini_to_env do
    ini =
      Enum.join(
        [
          "[database]",
          "host = db.example.com",
          "port = 5432",
          "name = production_db",
          "",
          "[redis]",
          "host = cache.example.com",
          "port = 6379",
          "",
          "[app]",
          "debug = false",
          "workers = 4",
          "secret = s3cr3t_k3y"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "ini_to_env",
      description: """
      You have an INI-style configuration file at /etc/app.ini with sections like
      [database], [redis], [app], each containing key=value pairs.

      Convert it to a flat .env file at /output/app.env where each variable is named
      SECTION_KEY=value (section and key in UPPERCASE, spaces trimmed from values).
      For example, [database] host = db.example.com becomes DATABASE_HOST=db.example.com.

      Sort the output alphabetically by variable name.
      """,
      files: %{"/etc/app.ini" => ini},
      validators: [
        {:file_contains, "/output/app.env",
         [
           {:regex, ~r/DATABASE_HOST=db\.example\.com/},
           {:regex, ~r/DATABASE_PORT=5432/},
           {:regex, ~r/REDIS_PORT=6379/},
           {:regex, ~r/APP_DEBUG=false/},
           {:regex, ~r/APP_SECRET=s3cr3t_k3y/}
         ]},
        {:custom, "sorted_output",
         fn %{bash: bash} ->
           case JustBash.FS.read_file(bash.fs, "/output/app.env") do
             {:ok, content} ->
               lines =
                 content
                 |> String.trim()
                 |> String.split("\n")
                 |> Enum.map(&String.trim/1)
                 |> Enum.reject(&(&1 == ""))

               if lines == Enum.sort(lines),
                 do: :ok,
                 else: {:error, "output is not sorted alphabetically"}

             {:error, _} ->
               {:error, "file not found"}
           end
         end}
      ]
    }
  end

  # --- 25. Git-log-style changelog generator ---

  defp git_log_changelog do
    commits =
      Enum.join(
        [
          "abc1234|2024-01-15|fix: resolve login timeout issue",
          "def5678|2024-01-14|feat: add dark mode toggle",
          "ghi9012|2024-01-14|fix: correct calculation in reports",
          "jkl3456|2024-01-13|feat: implement user profiles",
          "mno7890|2024-01-13|docs: update API documentation",
          "pqr1234|2024-01-12|feat: add search functionality",
          "stu5678|2024-01-12|fix: memory leak in worker pool",
          "vwx9012|2024-01-11|chore: upgrade dependencies"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "git_log_changelog",
      description: """
      You have a git log export at /data/commits.txt with lines in the format:
        hash|date|message

      Commit messages follow conventional commits (feat:, fix:, docs:, chore:).
      Generate a changelog at /output/CHANGELOG.md grouped by type:

      # Changelog

      ## Features
      - add dark mode toggle (def5678)
      - implement user profiles (jkl3456)
      - add search functionality (pqr1234)

      ## Fixes
      - resolve login timeout issue (abc1234)
      - ...

      ## Documentation
      - ...

      ## Other
      - ...

      Within each section, list items in the order they appear in the input.
      Strip the "type: " prefix from each message.
      """,
      files: %{"/data/commits.txt" => commits},
      validators: [
        {:file_contains, "/output/CHANGELOG.md",
         [
           {:regex, ~r/# Changelog/},
           {:regex, ~r/## Features/},
           {:regex, ~r/## Fixes/},
           {:regex, ~r/dark mode toggle/},
           {:regex, ~r/login timeout/},
           {:regex, ~r/def5678/}
         ]},
        {:custom, "correct_categorization",
         fn %{bash: bash} ->
           case JustBash.FS.read_file(bash.fs, "/output/CHANGELOG.md") do
             {:ok, content} ->
               # Verify features section has 3 items and fixes has 3
               features_section =
                 content
                 |> String.split(~r/## Fix/i)
                 |> hd()
                 |> String.split(~r/## Feature/i)
                 |> List.last()

               feature_items =
                 features_section
                 |> String.split("\n")
                 |> Enum.filter(&String.starts_with?(String.trim(&1), "-"))

               if length(feature_items) == 3,
                 do: :ok,
                 else: {:error, "expected 3 features, got #{length(feature_items)}"}

             {:error, _} ->
               {:error, "file not found"}
           end
         end}
      ]
    }
  end
end
