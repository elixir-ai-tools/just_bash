defmodule JustBash.Commands.Sqlite3 do
  @moduledoc """
  The `sqlite3` command - query SQLite databases.

  Databases are stored in-memory per named database. Use `:memory:` for
  a throwaway database that won't be stored in bash state.

  ## Examples

      sqlite3 mydb "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
      sqlite3 mydb "INSERT INTO users VALUES (1, 'alice')"
      sqlite3 mydb "SELECT * FROM users"

      # JSON output for piping to jq
      sqlite3 mydb "SELECT * FROM users" --json | jq '.[].name'

      # CSV output
      sqlite3 mydb "SELECT * FROM users" --csv

      # Read SQL from stdin
      echo "SELECT * FROM users" | sqlite3 mydb

      # Import CSV data
      curl -s https://example.com/data.csv | sqlite3 mydb ".import /dev/stdin users"
      sqlite3 mydb ".import /tmp/data.csv users"
  """
  @behaviour JustBash.Commands.Command

  alias JustBash.Commands.Command
  alias JustBash.Fs.InMemoryFs

  @impl true
  def names, do: ["sqlite3"]

  @impl true
  def execute(bash, args, stdin) do
    case parse_args(args) do
      {:error, msg} ->
        {Command.error(msg), bash}

      {:ok, opts} ->
        execute_with_opts(bash, opts, stdin)
    end
  end

  defp execute_with_opts(bash, %{help: true}, _stdin) do
    help = """
    Usage: sqlite3 [OPTIONS] DBNAME [SQL]

    Execute SQL against an in-memory SQLite database.

    Options:
      --json       Output results as JSON array
      --csv        Output results as CSV
      --header     Include column headers (default for CSV)
      --no-header  Exclude column headers
      --help       Show this help message

    Dot Commands:
      .import FILE TABLE   Import CSV file into table (auto-creates if needed)
      .tables              List all tables
      .schema [TABLE]      Show CREATE statements

    If SQL is not provided, reads from stdin.
    Use /dev/stdin or - to read import data from pipe.

    Examples:
      sqlite3 mydb "CREATE TABLE t (id INTEGER, name TEXT)"
      sqlite3 mydb "SELECT * FROM t" --json
      echo "SELECT 1+1" | sqlite3 :memory:
      cat data.csv | sqlite3 mydb ".import /dev/stdin users"
    """

    {Command.ok(help), bash}
  end

  defp execute_with_opts(bash, opts, stdin) do
    sql = opts.sql || String.trim(stdin)

    if sql == "" do
      {Command.error("sqlite3: no SQL provided\n"), bash}
    else
      run_command(bash, opts.db_name, sql, opts, stdin)
    end
  end

  defp run_command(bash, db_name, sql, opts, stdin) do
    if String.starts_with?(sql, ".") do
      run_dot_command(bash, db_name, sql, stdin)
    else
      run_query(bash, db_name, sql, opts)
    end
  end

  # Dot commands (.import, .tables, .schema)
  defp run_dot_command(bash, db_name, cmd, stdin) do
    case parse_dot_command(cmd) do
      {:import, file, table} ->
        run_import(bash, db_name, file, table, stdin)

      {:tables, _} ->
        run_tables(bash, db_name)

      {:schema, table} ->
        run_schema(bash, db_name, table)

      {:error, msg} ->
        {Command.error(msg), bash}
    end
  end

  defp parse_dot_command(cmd) do
    parts = String.split(cmd, ~r/\s+/, trim: true)

    case parts do
      [".import", file, table] -> {:import, file, table}
      [".import" | _] -> {:error, "sqlite3: .import requires FILE TABLE\n"}
      [".tables"] -> {:tables, nil}
      [".schema"] -> {:schema, nil}
      [".schema", table] -> {:schema, table}
      [dot_cmd | _] -> {:error, "sqlite3: unknown command: #{dot_cmd}\n"}
    end
  end

  defp run_import(bash, db_name, file, table, stdin) do
    # Get CSV content from file or stdin
    case get_import_content(bash, file, stdin) do
      {:ok, content} ->
        import_csv(bash, db_name, table, content)

      {:error, msg} ->
        {Command.error(msg), bash}
    end
  end

  defp get_import_content(_bash, "/dev/stdin", stdin), do: {:ok, stdin}
  defp get_import_content(_bash, "-", stdin), do: {:ok, stdin}

  defp get_import_content(bash, file, _stdin) do
    resolved = InMemoryFs.resolve_path(bash.cwd, file)

    case InMemoryFs.read_file(bash.fs, resolved) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, "sqlite3: cannot open \"#{file}\"\n"}
    end
  end

  defp import_csv(bash, db_name, table, content) do
    lines = String.split(content, ~r/\r?\n/, trim: true)

    case lines do
      [] ->
        {Command.ok(""), bash}

      [header | data_lines] ->
        columns = parse_csv_line(header)
        rows = Enum.map(data_lines, &parse_csv_line/1)
        do_import(bash, db_name, table, columns, rows)
    end
  end

  defp parse_csv_line(line) do
    # Simple CSV parsing - handles quoted fields with commas
    parse_csv_fields(line, [], "")
  end

  defp parse_csv_fields("", acc, current) do
    Enum.reverse([current | acc])
  end

  defp parse_csv_fields(<<"\"", rest::binary>>, acc, "") do
    # Start of quoted field
    parse_quoted_field(rest, acc, "")
  end

  defp parse_csv_fields(<<",", rest::binary>>, acc, current) do
    parse_csv_fields(rest, [current | acc], "")
  end

  defp parse_csv_fields(<<char::utf8, rest::binary>>, acc, current) do
    parse_csv_fields(rest, acc, current <> <<char::utf8>>)
  end

  defp parse_quoted_field(<<"\"\"", rest::binary>>, acc, current) do
    # Escaped quote
    parse_quoted_field(rest, acc, current <> "\"")
  end

  defp parse_quoted_field(<<"\"", rest::binary>>, acc, current) do
    # End of quoted field
    parse_csv_fields(rest, [current | acc], "")
  end

  defp parse_quoted_field(<<char::utf8, rest::binary>>, acc, current) do
    parse_quoted_field(rest, acc, current <> <<char::utf8>>)
  end

  defp parse_quoted_field("", acc, current) do
    # Unterminated quote - just finish
    Enum.reverse([current | acc])
  end

  defp do_import(bash, db_name, table, columns, rows) do
    {conn, bash} = get_or_create_connection(bash, db_name)

    with :ok <- ensure_table_exists(conn, table, columns),
         :ok <- insert_rows(conn, table, columns, rows) do
      bash = maybe_store_connection(bash, db_name, conn)
      {Command.ok(""), bash}
    else
      {:error, reason} ->
        Exqlite.Sqlite3.close(conn)
        {Command.error("sqlite3: #{reason}\n"), bash}
    end
  end

  defp ensure_table_exists(conn, table, columns) do
    # Check if table exists
    check_sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"

    case Exqlite.Sqlite3.prepare(conn, check_sql) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [table])
        exists = Exqlite.Sqlite3.step(conn, stmt) == {:row, [table]}
        Exqlite.Sqlite3.release(conn, stmt)

        if exists do
          :ok
        else
          create_table(conn, table, columns)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_table(conn, table, columns) do
    # Create table with TEXT columns for all fields
    col_defs = Enum.map_join(columns, ", ", fn col -> "\"#{col}\" TEXT" end)
    create_sql = "CREATE TABLE \"#{table}\" (#{col_defs})"

    case Exqlite.Sqlite3.prepare(conn, create_sql) do
      {:ok, stmt} ->
        Exqlite.Sqlite3.step(conn, stmt)
        Exqlite.Sqlite3.release(conn, stmt)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_rows(_conn, _table, _columns, []), do: :ok

  defp insert_rows(conn, table, columns, rows) do
    placeholders = Enum.map_join(1..length(columns), ", ", fn _ -> "?" end)
    col_names = Enum.map_join(columns, ", ", fn col -> "\"#{col}\"" end)
    insert_sql = "INSERT INTO \"#{table}\" (#{col_names}) VALUES (#{placeholders})"

    case Exqlite.Sqlite3.prepare(conn, insert_sql) do
      {:ok, stmt} ->
        result = insert_all_rows(conn, stmt, rows, length(columns))
        Exqlite.Sqlite3.release(conn, stmt)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_all_rows(conn, stmt, rows, col_count) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      row = normalize_row(row, col_count)

      case insert_single_row(conn, stmt, row) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp normalize_row(row, col_count) do
    row_len = length(row)

    cond do
      row_len == col_count -> row
      row_len < col_count -> row ++ List.duplicate(nil, col_count - row_len)
      true -> Enum.take(row, col_count)
    end
  end

  defp insert_single_row(conn, stmt, row) do
    :ok = Exqlite.Sqlite3.bind(stmt, row)

    case Exqlite.Sqlite3.step(conn, stmt) do
      :done ->
        Exqlite.Sqlite3.reset(stmt)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_tables(bash, db_name) do
    {conn, bash} = get_or_create_connection(bash, db_name)
    sql = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"

    case execute_single_statement(conn, sql) do
      {:ok, {_cols, rows}} ->
        output = Enum.map_join(rows, "\n", fn [name] -> name end)
        output = if output != "", do: output <> "\n", else: ""
        bash = maybe_store_connection(bash, db_name, conn)
        {Command.ok(output), bash}

      {:error, reason} ->
        Exqlite.Sqlite3.close(conn)
        {Command.error("sqlite3: #{reason}\n"), bash}
    end
  end

  defp run_schema(bash, db_name, table) do
    {conn, bash} = get_or_create_connection(bash, db_name)

    sql =
      if table do
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='#{table}'"
      else
        "SELECT sql FROM sqlite_master WHERE type='table' ORDER BY name"
      end

    case execute_single_statement(conn, sql) do
      {:ok, {_cols, rows}} ->
        output = Enum.map_join(rows, "\n", fn [sql] -> sql <> ";" end)
        output = if output != "", do: output <> "\n", else: ""
        bash = maybe_store_connection(bash, db_name, conn)
        {Command.ok(output), bash}

      {:error, reason} ->
        Exqlite.Sqlite3.close(conn)
        {Command.error("sqlite3: #{reason}\n"), bash}
    end
  end

  defp run_query(bash, db_name, sql, opts) do
    {conn, bash} = get_or_create_connection(bash, db_name)

    case execute_sql(conn, sql) do
      {:ok, results} ->
        output = format_output(results, opts)
        bash = maybe_store_connection(bash, db_name, conn)
        {Command.ok(output), bash}

      {:error, reason} ->
        Exqlite.Sqlite3.close(conn)
        {Command.error("sqlite3: #{reason}\n"), bash}
    end
  end

  defp get_or_create_connection(bash, ":memory:") do
    {:ok, conn} = Exqlite.Sqlite3.open(":memory:")
    {conn, bash}
  end

  defp get_or_create_connection(bash, db_name) do
    databases = Map.get(bash, :databases, %{})

    case Map.get(databases, db_name) do
      nil ->
        {:ok, conn} = Exqlite.Sqlite3.open(":memory:")
        {conn, bash}

      conn ->
        {conn, bash}
    end
  end

  defp maybe_store_connection(bash, ":memory:", conn) do
    Exqlite.Sqlite3.close(conn)
    bash
  end

  defp maybe_store_connection(bash, db_name, conn) do
    databases = Map.get(bash, :databases, %{})
    databases = Map.put(databases, db_name, conn)
    Map.put(bash, :databases, databases)
  end

  defp execute_sql(conn, sql) do
    statements = split_statements(sql)
    execute_statements(conn, statements)
  end

  defp execute_statements(conn, statements) do
    Enum.reduce_while(statements, {:ok, []}, fn stmt, {:ok, _acc} ->
      execute_trimmed_statement(conn, String.trim(stmt))
    end)
  end

  defp execute_trimmed_statement(_conn, ""), do: {:cont, {:ok, []}}

  defp execute_trimmed_statement(conn, stmt) do
    case execute_single_statement(conn, stmt) do
      {:ok, result} -> {:cont, {:ok, result}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp split_statements(sql) do
    # Simple split on semicolons - doesn't handle strings with semicolons
    String.split(sql, ";")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp execute_single_statement(conn, sql) do
    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        result = fetch_all_rows(conn, stmt, [])
        Exqlite.Sqlite3.release(conn, stmt)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_all_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} ->
        fetch_all_rows(conn, stmt, [row | acc])

      :done ->
        columns = get_columns(conn, stmt)
        rows = Enum.reverse(acc)
        {:ok, {columns, rows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_columns(conn, stmt) do
    case Exqlite.Sqlite3.columns(conn, stmt) do
      {:ok, cols} -> cols
      _ -> []
    end
  end

  defp format_output({columns, rows}, opts) do
    cond do
      opts.json -> format_json(columns, rows)
      opts.csv -> format_csv(columns, rows, opts.header)
      true -> format_table(columns, rows, opts.header)
    end
  end

  defp format_json(columns, rows) do
    json_rows =
      Enum.map(rows, fn row ->
        Enum.zip(columns, row) |> Map.new()
      end)

    Jason.encode!(json_rows) <> "\n"
  end

  defp format_csv(columns, rows, show_header) do
    header_line = if show_header, do: [Enum.join(columns, ",")], else: []

    data_lines =
      Enum.map(rows, fn row ->
        Enum.map_join(row, ",", &escape_csv_field/1)
      end)

    Enum.join(header_line ++ data_lines, "\n") <>
      if(rows != [] or show_header, do: "\n", else: "")
  end

  defp escape_csv_field(nil), do: ""

  defp escape_csv_field(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp escape_csv_field(value), do: to_string(value)

  defp format_table(_columns, rows, _show_header) do
    # Simple pipe-separated output like sqlite3 default
    Enum.map_join(rows, "\n", fn row ->
      Enum.map_join(row, "|", fn
        nil -> ""
        val -> to_string(val)
      end)
    end) <> if(rows != [], do: "\n", else: "")
  end

  defp parse_args(args) do
    parse_args(args, %{
      db_name: nil,
      sql: nil,
      json: false,
      csv: false,
      header: false,
      help: false
    })
  end

  defp parse_args([], %{db_name: nil}), do: {:error, "sqlite3: no database specified\n"}
  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["--help" | _rest], opts), do: {:ok, %{opts | help: true}}
  defp parse_args(["-h" | _rest], opts), do: {:ok, %{opts | help: true}}
  defp parse_args(["--json" | rest], opts), do: parse_args(rest, %{opts | json: true})
  defp parse_args(["--csv" | rest], opts), do: parse_args(rest, %{opts | csv: true, header: true})
  defp parse_args(["--header" | rest], opts), do: parse_args(rest, %{opts | header: true})
  defp parse_args(["--no-header" | rest], opts), do: parse_args(rest, %{opts | header: false})

  defp parse_args([arg | rest], %{db_name: nil} = opts) do
    parse_args(rest, %{opts | db_name: arg})
  end

  defp parse_args([arg | rest], %{sql: nil} = opts) do
    parse_args(rest, %{opts | sql: arg})
  end

  defp parse_args([arg | rest], opts) do
    # Append additional args to SQL
    parse_args(rest, %{opts | sql: opts.sql <> " " <> arg})
  end
end
