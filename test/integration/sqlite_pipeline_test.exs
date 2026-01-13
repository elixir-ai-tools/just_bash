defmodule JustBash.Integration.SqlitePipelineTest do
  use ExUnit.Case, async: true

  defmodule MockHttpClient do
    @behaviour JustBash.HttpClient

    @impl true
    def request(%{url: url}) do
      cond do
        String.contains?(url, "users.csv") ->
          csv = """
          id,name,email,department
          1,alice,alice@example.com,engineering
          2,bob,bob@example.com,sales
          3,charlie,charlie@example.com,engineering
          4,diana,diana@example.com,marketing
          5,eve,eve@example.com,engineering
          """

          {:ok, %{status: 200, headers: [{"content-type", "text/csv"}], body: csv}}

        String.contains?(url, "orders.json") ->
          json = """
          [
            {"user_id": 1, "amount": 100, "product": "widget"},
            {"user_id": 1, "amount": 250, "product": "gadget"},
            {"user_id": 3, "amount": 75, "product": "widget"},
            {"user_id": 5, "amount": 300, "product": "gizmo"}
          ]
          """

          {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: json}}

        true ->
          {:ok, %{status: 404, headers: [], body: "Not found"}}
      end
    end
  end

  describe "data pipeline: curl -> sqlite -> jq" do
    test "fetch CSV, load into SQLite, query with SQL, transform with jq" do
      bash =
        JustBash.new(
          network: %{enabled: true},
          http_client: MockHttpClient
        )

      script = ~S"""
      # Fetch CSV data and pipe directly into SQLite
      curl -s https://api.example.com/users.csv | sqlite3 analytics ".import /dev/stdin users"

      # Query engineers, output as JSON, extract names with jq
      sqlite3 analytics "SELECT name, email FROM users WHERE department = 'engineering'" --json | jq -r '.[].name'
      """

      {result, _bash} = JustBash.exec(bash, script)

      assert result.exit_code == 0
      names = String.split(result.stdout, "\n", trim: true)
      assert names == ["alice", "charlie", "eve"]
    end

    test "aggregation pipeline: group by and summarize" do
      bash = JustBash.new()

      script = ~S"""
      # Create sales data
      sqlite3 sales "CREATE TABLE orders (region TEXT, product TEXT, amount INTEGER)"
      sqlite3 sales "INSERT INTO orders VALUES ('north', 'widget', 100)"
      sqlite3 sales "INSERT INTO orders VALUES ('north', 'gadget', 200)"
      sqlite3 sales "INSERT INTO orders VALUES ('south', 'widget', 150)"
      sqlite3 sales "INSERT INTO orders VALUES ('south', 'widget', 50)"
      sqlite3 sales "INSERT INTO orders VALUES ('north', 'widget', 75)"

      # Get total sales by region as JSON
      sqlite3 sales "SELECT region, SUM(amount) as total FROM orders GROUP BY region ORDER BY total DESC" --json
      """

      {result, _bash} = JustBash.exec(bash, script)

      assert result.exit_code == 0
      data = Jason.decode!(result.stdout)

      assert data == [
               %{"region" => "north", "total" => 375},
               %{"region" => "south", "total" => 200}
             ]
    end

    test "multi-table join pipeline" do
      bash = JustBash.new()

      script = ~S"""
      # Create users table
      sqlite3 app "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
      sqlite3 app "INSERT INTO users VALUES (1, 'alice')"
      sqlite3 app "INSERT INTO users VALUES (2, 'bob')"

      # Create orders table
      sqlite3 app "CREATE TABLE orders (id INTEGER, user_id INTEGER, amount INTEGER)"
      sqlite3 app "INSERT INTO orders VALUES (1, 1, 100)"
      sqlite3 app "INSERT INTO orders VALUES (2, 1, 200)"
      sqlite3 app "INSERT INTO orders VALUES (3, 2, 50)"

      # Join and aggregate: total spent per user
      sqlite3 app "
        SELECT u.name, SUM(o.amount) as total_spent
        FROM users u
        JOIN orders o ON u.id = o.user_id
        GROUP BY u.id
        ORDER BY total_spent DESC
      " --json | jq -r '.[].name'
      """

      {result, _bash} = JustBash.exec(bash, script)

      assert result.exit_code == 0
      lines = String.split(result.stdout, "\n", trim: true)
      assert lines == ["alice", "bob"]
    end

    test "CSV export pipeline" do
      bash = JustBash.new()

      script = ~S"""
      # Build report in SQLite
      sqlite3 report "CREATE TABLE metrics (date TEXT, visitors INTEGER, conversions INTEGER)"
      sqlite3 report "INSERT INTO metrics VALUES ('2024-01-01', 1000, 50)"
      sqlite3 report "INSERT INTO metrics VALUES ('2024-01-02', 1200, 65)"
      sqlite3 report "INSERT INTO metrics VALUES ('2024-01-03', 950, 42)"

      # Export as CSV to file
      sqlite3 report "SELECT * FROM metrics" --csv > /tmp/report.csv
      cat /tmp/report.csv
      """

      {result, _bash} = JustBash.exec(bash, script)

      assert result.exit_code == 0

      assert result.stdout == """
             date,visitors,conversions
             2024-01-01,1000,50
             2024-01-02,1200,65
             2024-01-03,950,42
             """
    end

    test "conditional logic with query results" do
      bash = JustBash.new()

      script = ~S"""
      sqlite3 db "CREATE TABLE config (key TEXT, value TEXT)"
      sqlite3 db "INSERT INTO config VALUES ('feature_enabled', 'true')"
      sqlite3 db "INSERT INTO config VALUES ('max_retries', '3')"

      # Check feature flag
      enabled=$(sqlite3 db "SELECT value FROM config WHERE key = 'feature_enabled'" | tr -d '\n')
      if [ "$enabled" = "true" ]; then
        echo "Feature is ON"
      else
        echo "Feature is OFF"
      fi

      # Get numeric config
      retries=$(sqlite3 db "SELECT value FROM config WHERE key = 'max_retries'" | tr -d '\n')
      echo "Max retries: $retries"
      """

      {result, _bash} = JustBash.exec(bash, script)

      assert result.exit_code == 0
      assert result.stdout =~ "Feature is ON"
      assert result.stdout =~ "Max retries: 3"
    end

    test "jq transforms sqlite json for further processing" do
      bash = JustBash.new()

      script = ~S"""
      sqlite3 db "CREATE TABLE events (id INTEGER, type TEXT, payload INTEGER)"
      sqlite3 db "INSERT INTO events VALUES (1, 'click', 100)"
      sqlite3 db "INSERT INTO events VALUES (2, 'scroll', 500)"
      sqlite3 db "INSERT INTO events VALUES (3, 'click', 150)"

      # Get click events and sum payloads with jq
      sqlite3 db "SELECT * FROM events WHERE type = 'click'" --json | jq '[.[].payload] | add'
      """

      {result, _bash} = JustBash.exec(bash, script)

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "250"
    end
  end
end
