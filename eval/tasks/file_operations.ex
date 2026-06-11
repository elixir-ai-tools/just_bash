defmodule JustBash.Eval.Tasks.FileOperations do
  @moduledoc """
  File operation eval tasks: multi-file processing, log rotation, directory flattening,
  renaming, splitting, tree snapshots, special characters, and symlinks.
  """

  @behaviour JustBash.Eval.Task

  @impl true
  def tasks do
    [
      multi_file_processing(),
      log_rotation(),
      directory_flattener(),
      multi_file_rename(),
      split_and_reassemble(),
      file_tree_snapshot(),
      special_char_files(),
      symlink_farm()
    ]
  end

  # --- find + sha256sum + wc: build manifest ---

  defp multi_file_processing do
    %{
      name: "multi_file_processing",
      description: """
      You have several source files under /src/. Create a build manifest at /output/manifest.txt.
      For each .sh file under /src/, produce a line with the format:
        filename <tab> line_count <tab> sha256_hash
      Sort the output by filename. The sha256 hash should be the hex digest of the file contents.
      """,
      files: %{
        "/src/deploy.sh" => "#!/bin/bash\necho \"deploying...\"\nrsync -av . server:/app\n",
        "/src/test.sh" => "#!/bin/bash\nset -e\nmix test\n",
        "/src/build.sh" => "#!/bin/bash\nset -e\nmix deps.get\nmix compile\nmix release\n",
        "/src/README.md" => "# Scripts\nThese are deployment scripts.\n"
      },
      validators: [
        {:command_used, "sha256sum"},
        {:file_contains, "/output/manifest.txt",
         [
           {:line_count, 3},
           {:regex, ~r/build\.sh\t/},
           {:regex, ~r/deploy\.sh\t/},
           {:regex, ~r/test\.sh\t/}
         ]},
        {:custom, "sorted_by_filename",
         fn %{bash: bash} ->
           case JustBash.Fs.read_file(bash.fs, "/output/manifest.txt") do
             {:ok, content} ->
               names =
                 content
                 |> String.trim()
                 |> String.split("\n")
                 |> Enum.map(&(String.split(&1, "\t") |> hd()))

               if names == Enum.sort(names),
                 do: :ok,
                 else: {:error, "not sorted: #{inspect(names)}"}

             {:error, _} ->
               {:error, "file not found"}
           end
         end}
      ]
    }
  end

  # --- Realistic: log rotation with mv/rm/touch ---

  defp log_rotation do
    %{
      name: "log_rotation",
      description: """
      The filesystem already contains these log files (do NOT create or overwrite them):
      - /var/log/app.log (current log with content)
      - /var/log/app.log.1 (previous log with content)
      - /var/log/app.log.2 (oldest log with content)

      Perform log rotation directly on these EXISTING files:
      1. Delete /var/log/app.log.2 (oldest)
      2. Move /var/log/app.log.1 to /var/log/app.log.2
      3. Move /var/log/app.log to /var/log/app.log.1
      4. Create a new empty /var/log/app.log
      5. Write a summary to /output/rotation.log listing what was done (one action per line).

      After rotation, /var/log/app.log should be empty, .log.1 should have the original
      .log content, and .log.2 should have the original .log.1 content.
      """,
      files: %{
        "/var/log/app.log" => "current log line 1\ncurrent log line 2\n",
        "/var/log/app.log.1" => "previous log line 1\nprevious log line 2\n",
        "/var/log/app.log.2" => "ancient log line 1\n"
      },
      validators: [
        {:custom, "app.log_empty",
         fn %{bash: bash} ->
           case JustBash.Fs.read_file(bash.fs, "/var/log/app.log") do
             {:ok, content} ->
               if String.trim(content) == "", do: :ok, else: {:error, "app.log should be empty"}

             {:error, _} ->
               {:error, "app.log not found"}
           end
         end},
        {:file_contains, "/var/log/app.log.1", [{:regex, ~r/current log line/}]},
        {:file_contains, "/var/log/app.log.2", [{:regex, ~r/previous log line/}]},
        {:file_contains, "/output/rotation.log", [{:not_empty}]}
      ]
    }
  end

  # --- 11. Directory flattener: mv + find + basename collision handling ---

  defp directory_flattener do
    %{
      name: "directory_flattener",
      description: """
      You have a nested directory structure under /src/ with files at various depths.
      Flatten ALL files into /output/flat/ by copying them there. If two files have
      the same basename, rename the duplicate by prepending the parent directory name
      with an underscore (e.g., utils/helper.sh -> utils_helper.sh).

      After flattening, write a manifest of all files in /output/flat/ (one filename
      per line, sorted) to /output/manifest.txt.
      """,
      files: %{
        "/src/main.sh" => "#!/bin/bash\necho main\n",
        "/src/lib/utils.sh" => "#!/bin/bash\necho lib-utils\n",
        "/src/lib/helper.sh" => "#!/bin/bash\necho lib-helper\n",
        "/src/tests/helper.sh" => "#!/bin/bash\necho tests-helper\n",
        "/src/tests/runner.sh" => "#!/bin/bash\necho tests-runner\n"
      },
      validators: [
        {:command_used, "find"},
        {:file_contains, "/output/manifest.txt",
         [
           {:regex, ~r/main\.sh/},
           {:regex, ~r/runner\.sh/},
           {:regex, ~r/utils\.sh/}
         ]},
        {:custom, "no_lost_files",
         fn %{bash: bash} ->
           case JustBash.Fs.read_file(bash.fs, "/output/manifest.txt") do
             {:ok, content} ->
               lines =
                 content |> String.trim() |> String.split("\n") |> Enum.map(&String.trim/1)

               if length(lines) >= 5,
                 do: :ok,
                 else: {:error, "expected at least 5 files, got #{length(lines)}"}

             {:error, _} ->
               {:error, "manifest not found"}
           end
         end},
        {:custom, "helper_conflict_resolved",
         fn %{bash: bash} ->
           case JustBash.Fs.read_file(bash.fs, "/output/manifest.txt") do
             {:ok, content} ->
               lines =
                 content |> String.trim() |> String.split("\n") |> Enum.map(&String.trim/1)

               helper_files = Enum.filter(lines, &String.contains?(&1, "helper"))

               if length(helper_files) >= 2,
                 do: :ok,
                 else: {:error, "expected 2 helper variants, got: #{inspect(helper_files)}"}

             {:error, _} ->
               {:error, "manifest not found"}
           end
         end}
      ]
    }
  end

  # --- 17. Batch file rename with pattern substitution ---

  defp multi_file_rename do
    %{
      name: "multi_file_rename",
      description: """
      You have image files under /photos/ with inconsistent naming:
        IMG_20240101_001.jpg, photo-2024-02-15.jpg, DSC00042.jpg,
        Screenshot 2024-03-20.png, IMG_20240101_002.jpg

      Rename (move) ALL files to /photos/organized/ using a consistent naming scheme:
        YYYY-MM-DD_NNN.ext
      where NNN is a zero-padded sequential number (001, 002, ...) assigned in the
      original alphabetical order of the source filenames. For files that don't contain
      a date, use "0000-00-00" as the date.

      Write a rename log to /output/rename_log.txt with exactly 5 lines (one per file),
      each in the format:
        old_name -> new_name
      Do NOT include any header or extra lines — just the 5 rename entries.

      IMPORTANT: One filename has a space in it ("Screenshot 2024-03-20.png").
      Make sure to handle filenames with spaces correctly.
      """,
      files: %{
        "/photos/IMG_20240101_001.jpg" => "jpeg data 1",
        "/photos/IMG_20240101_002.jpg" => "jpeg data 2",
        "/photos/DSC00042.jpg" => "jpeg data 3",
        "/photos/Screenshot 2024-03-20.png" => "png data",
        "/photos/photo-2024-02-15.jpg" => "jpeg data 4"
      },
      validators: [
        {:file_contains, "/output/rename_log.txt",
         [
           {:line_count, 5},
           {:regex, ~r/->/}
         ]},
        {:custom, "files_in_organized",
         fn %{bash: bash} ->
           case JustBash.Fs.readdir(bash.fs, "/photos/organized") do
             {:ok, entries} ->
               if length(entries) == 5,
                 do: :ok,
                 else: {:error, "expected 5 files in /photos/organized/, got #{length(entries)}"}

             {:error, _} ->
               {:error, "/photos/organized/ directory not found"}
           end
         end}
      ]
    }
  end

  # --- 22. Split file and reassemble ---

  defp split_and_reassemble do
    lines = Enum.map_join(1..30, "\n", &"Line #{String.pad_leading(to_string(&1), 2, "0")}: data")

    %{
      name: "split_and_reassemble",
      description: """
      You have a file at /data/big_file.txt with 30 lines. Perform these operations:

      1. Split it into chunks of 10 lines each, writing to /tmp/chunk_01.txt,
         /tmp/chunk_02.txt, /tmp/chunk_03.txt (use head/tail or sed to extract ranges)
      2. Reverse the order of lines within each chunk (use tac or sed)
      3. Reassemble the reversed chunks back into /output/reversed_chunks.txt
         (chunk_01 reversed, then chunk_02 reversed, then chunk_03 reversed)
      4. Write the total line count of the output to /output/count.txt

      Use head, tail, and tac (or equivalent) for splitting and reversing.
      """,
      files: %{"/data/big_file.txt" => lines <> "\n"},
      validators: [
        {:file_contains, "/output/reversed_chunks.txt",
         [
           {:line_count, 30},
           {:not_empty}
         ]},
        {:file_contains, "/output/count.txt", [{:regex, ~r/30/}]},
        {:custom, "chunks_reversed",
         fn %{bash: bash} ->
           case JustBash.Fs.read_file(bash.fs, "/output/reversed_chunks.txt") do
             {:ok, content} ->
               lines = content |> String.trim() |> String.split("\n")
               # First line should be Line 10 (last of first chunk, reversed)
               first = hd(lines)

               if String.contains?(first, "Line 10"),
                 do: :ok,
                 else:
                   {:error, "first line should be 'Line 10...' (reversed chunk 1), got: #{first}"}

             {:error, _} ->
               {:error, "file not found"}
           end
         end}
      ]
    }
  end

  # --- 27. File tree snapshot: generate a tree representation ---

  defp file_tree_snapshot do
    %{
      name: "file_tree_snapshot",
      description: """
      You have a project structure under /project/ with various files and directories.
      Generate two outputs:

      1. /output/tree.txt — an indented tree view showing the directory structure,
         using 2 spaces per indent level. Directories should end with / and files
         should show their byte size. Example:
           project/
             src/
               main.sh (45 bytes)

      2. /output/summary.json — a JSON object with:
         {"total_files": N, "total_dirs": M, "total_bytes": B, "extensions": {"sh": 3, "md": 1, ...}}

      Use find to discover the structure and wc -c for file sizes.
      """,
      files: %{
        "/project/README.md" => "# My Project\nA sample project.\n",
        "/project/src/main.sh" => "#!/bin/bash\necho hello\n",
        "/project/src/lib/utils.sh" => "#!/bin/bash\nlog() { echo \"$1\"; }\n",
        "/project/src/lib/config.sh" => "#!/bin/bash\nexport APP=myapp\n",
        "/project/tests/test_main.sh" => "#!/bin/bash\necho test\n",
        "/project/docs/guide.md" => "# Guide\nUsage instructions.\n"
      },
      validators: [
        {:command_used, "find"},
        {:file_contains, "/output/tree.txt",
         [
           {:regex, ~r/project/},
           {:regex, ~r/src/},
           {:regex, ~r/main\.sh/},
           {:regex, ~r/bytes/}
         ]},
        {:file_contains, "/output/summary.json",
         [
           {:json,
            fn data ->
              cond do
                data["total_files"] != 6 ->
                  {:error, "expected 6 total_files, got #{inspect(data["total_files"])}"}

                not is_map(data["extensions"]) ->
                  {:error, "extensions should be an object"}

                true ->
                  :ok
              end
            end}
         ]}
      ]
    }
  end

  # --- 38. Special character filenames: handle edge cases ---

  defp special_char_files do
    %{
      name: "special_char_files",
      description: """
      You have files with tricky names under /data/:
      - /data/file with spaces.txt — content "spaces work"
      - /data/file-with-dashes.txt — content "dashes work"
      - /data/file_with_underscores.txt — content "underscores work"
      - /data/FILE.UPPER.txt — content "upper works"
      - /data/MiXeD.CaSe.txt — content "mixed works"

      Tasks:
      1. Create /output/inventory.txt listing all filenames (basenames only),
         one per line, sorted alphabetically.

      2. Create /output/lowered/ directory and copy each file there with its
         filename converted to all lowercase.

      3. Create /output/checksums.txt with `sha256sum`-style output for each
         original file, sorted by filename. Format: "hash  filename" per line.

      IMPORTANT: Some filenames contain spaces — handle them correctly.
      """,
      files: %{
        "/data/file with spaces.txt" => "spaces work",
        "/data/file-with-dashes.txt" => "dashes work",
        "/data/file_with_underscores.txt" => "underscores work",
        "/data/FILE.UPPER.txt" => "upper works",
        "/data/MiXeD.CaSe.txt" => "mixed works"
      },
      validators: [
        {:file_contains, "/output/inventory.txt",
         [
           {:line_count, 5},
           {:regex, ~r/file with spaces\.txt/},
           {:regex, ~r/FILE\.UPPER\.txt/}
         ]},
        {:custom, "lowercase_files",
         fn %{bash: bash} ->
           case JustBash.Fs.read_file(bash.fs, "/output/lowered/file.upper.txt") do
             {:ok, content} ->
               if content == "upper works",
                 do: :ok,
                 else: {:error, "lowered file has wrong content: #{inspect(content)}"}

             {:error, _} ->
               {:error, "/output/lowered/file.upper.txt not found"}
           end
         end},
        {:file_contains, "/output/checksums.txt",
         [
           {:line_count, 5},
           {:regex, ~r/[a-f0-9]{64}/}
         ]}
      ]
    }
  end

  # --- 34. Symlink farm: create organized symlinks ---

  defp symlink_farm do
    %{
      name: "symlink_farm",
      description: """
      You have config files scattered across /etc/services/:
      - /etc/services/web/nginx.conf
      - /etc/services/web/apache.conf
      - /etc/services/db/postgres.conf
      - /etc/services/db/redis.conf
      - /etc/services/cache/memcached.conf

      Create a symlink farm at /links/ where each config is accessible by a
      flat name: /links/nginx.conf -> /etc/services/web/nginx.conf, etc.

      Use `ln -s` to create the links and `find /etc/services -type f` to
      discover files. Then write /output/link_map.txt with one line per link:
        symlink_name -> target_path
      sorted alphabetically by symlink name.

      Verify each symlink works by reading through it with `cat`.
      """,
      files: %{
        "/etc/services/web/nginx.conf" => "worker_processes auto;\n",
        "/etc/services/web/apache.conf" => "ServerRoot \"/etc/httpd\"\n",
        "/etc/services/db/postgres.conf" => "max_connections = 100\n",
        "/etc/services/db/redis.conf" => "bind 127.0.0.1\n",
        "/etc/services/cache/memcached.conf" => "maxconn 1024\n"
      },
      validators: [
        {:command_used, "ln"},
        {:file_contains, "/output/link_map.txt",
         [
           {:line_count, 5},
           {:regex, ~r/nginx\.conf.*->/},
           {:regex, ~r/redis\.conf.*->/}
         ]},
        {:custom, "symlinks_work",
         fn %{bash: bash} ->
           case JustBash.Fs.read_file(bash.fs, "/links/nginx.conf") do
             {:ok, content} ->
               if String.contains?(content, "worker_processes"),
                 do: :ok,
                 else: {:error, "symlink /links/nginx.conf doesn't resolve correctly"}

             {:error, _} ->
               {:error, "/links/nginx.conf not found"}
           end
         end}
      ]
    }
  end
end
