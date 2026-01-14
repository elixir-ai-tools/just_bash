defmodule JustBash.Commands.Sqlite3Test do
  use ExUnit.Case, async: true

  alias JustBash.Fs.InMemoryFs

  describe "sqlite3 command" do
    test "creates table and inserts data" do
      bash = JustBash.new()

      {result, bash} =
        JustBash.exec(
          bash,
          "sqlite3 mydb 'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)'"
        )

      assert result.exit_code == 0

      {result, bash} =
        JustBash.exec(bash, "sqlite3 mydb \"INSERT INTO users VALUES (1, 'alice')\"")

      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb 'SELECT * FROM users'")
      assert result.exit_code == 0
      assert result.stdout == "1|alice\n"
    end

    test "database persists across commands" do
      bash = JustBash.new()

      {_, bash} =
        JustBash.exec(bash, "sqlite3 testdb 'CREATE TABLE t (x INTEGER)'")

      {_, bash} = JustBash.exec(bash, "sqlite3 testdb 'INSERT INTO t VALUES (42)'")
      {result, _bash} = JustBash.exec(bash, "sqlite3 testdb 'SELECT x FROM t'")

      assert result.stdout == "42\n"
    end

    test ":memory: database does not persist" do
      bash = JustBash.new()

      {_, bash} =
        JustBash.exec(bash, "sqlite3 :memory: 'CREATE TABLE t (x INTEGER)'")

      {result, _bash} = JustBash.exec(bash, "sqlite3 :memory: 'SELECT * FROM t'")
      assert result.exit_code == 1
      assert result.stderr =~ "no such table"
    end

    test "multiple databases are independent" do
      bash = JustBash.new()

      {_, bash} = JustBash.exec(bash, "sqlite3 db1 'CREATE TABLE t (x INTEGER)'")
      {_, bash} = JustBash.exec(bash, "sqlite3 db2 'CREATE TABLE t (x TEXT)'")
      {_, bash} = JustBash.exec(bash, "sqlite3 db1 'INSERT INTO t VALUES (123)'")
      {_, bash} = JustBash.exec(bash, "sqlite3 db2 \"INSERT INTO t VALUES ('hello')\"")

      {result1, bash} = JustBash.exec(bash, "sqlite3 db1 'SELECT * FROM t'")
      {result2, _bash} = JustBash.exec(bash, "sqlite3 db2 'SELECT * FROM t'")

      assert result1.stdout == "123\n"
      assert result2.stdout == "hello\n"
    end

    test "--json outputs JSON array" do
      bash = JustBash.new()

      {_, bash} =
        JustBash.exec(bash, "sqlite3 mydb 'CREATE TABLE users (id INTEGER, name TEXT)'")

      {_, bash} = JustBash.exec(bash, "sqlite3 mydb \"INSERT INTO users VALUES (1, 'alice')\"")
      {_, bash} = JustBash.exec(bash, "sqlite3 mydb \"INSERT INTO users VALUES (2, 'bob')\"")

      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb 'SELECT * FROM users' --json")

      assert result.exit_code == 0
      parsed = Jason.decode!(result.stdout)
      assert parsed == [%{"id" => 1, "name" => "alice"}, %{"id" => 2, "name" => "bob"}]
    end

    test "--csv outputs CSV format" do
      bash = JustBash.new()

      {_, bash} =
        JustBash.exec(bash, "sqlite3 mydb 'CREATE TABLE items (id INTEGER, value TEXT)'")

      {_, bash} = JustBash.exec(bash, "sqlite3 mydb \"INSERT INTO items VALUES (1, 'foo')\"")
      {_, bash} = JustBash.exec(bash, "sqlite3 mydb \"INSERT INTO items VALUES (2, 'bar')\"")

      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb 'SELECT * FROM items' --csv")

      assert result.exit_code == 0
      assert result.stdout == "id,value\n1,foo\n2,bar\n"
    end

    test "--csv escapes special characters" do
      bash = JustBash.new()

      {_, bash} = JustBash.exec(bash, "sqlite3 mydb 'CREATE TABLE t (s TEXT)'")
      {_, bash} = JustBash.exec(bash, ~s[sqlite3 mydb "INSERT INTO t VALUES ('hello,world')"])

      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb 'SELECT * FROM t' --csv")

      lines = String.split(result.stdout, "\n", trim: true)
      # CSV escapes the comma by quoting the field
      assert Enum.at(lines, 1) == "\"hello,world\""
    end

    test "reads SQL from stdin" do
      bash = JustBash.new()

      {_, bash} = JustBash.exec(bash, "sqlite3 mydb 'CREATE TABLE t (x INTEGER)'")
      {_, bash} = JustBash.exec(bash, "sqlite3 mydb 'INSERT INTO t VALUES (99)'")

      {result, _bash} = JustBash.exec(bash, "echo 'SELECT * FROM t' | sqlite3 mydb")

      assert result.exit_code == 0
      assert result.stdout == "99\n"
    end

    test "multiple statements in one call" do
      bash = JustBash.new()

      {result, bash} =
        JustBash.exec(
          bash,
          "sqlite3 mydb 'CREATE TABLE t (x INTEGER); INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)'"
        )

      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb 'SELECT SUM(x) FROM t'")
      assert result.stdout == "3\n"
    end

    test "--help shows usage" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "sqlite3 --help")
      assert result.exit_code == 0
      assert result.stdout =~ "Usage:"
      assert result.stdout =~ "--json"
    end

    test "error without SQL (defaults to :memory: database)" do
      # sqlite3 without args defaults to :memory: like real sqlite3
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "sqlite3")
      assert result.exit_code == 1
      assert result.stderr =~ "no SQL"
    end

    test "error without SQL" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb")
      assert result.exit_code == 1
      assert result.stderr =~ "no SQL"
    end

    test "reports SQL syntax errors" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb 'SELEKT * FROM nope'")
      assert result.exit_code == 1
      assert result.stderr =~ "sqlite3:"
    end

    test "json output pipes to jq" do
      bash = JustBash.new()

      {_, bash} =
        JustBash.exec(bash, "sqlite3 mydb 'CREATE TABLE users (id INTEGER, name TEXT)'")

      {_, bash} = JustBash.exec(bash, "sqlite3 mydb \"INSERT INTO users VALUES (1, 'alice')\"")

      {result, _bash} =
        JustBash.exec(bash, "sqlite3 mydb 'SELECT * FROM users' --json | jq '.[0].name'")

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "\"alice\""
    end

    test "handles NULL values" do
      bash = JustBash.new()

      {_, bash} =
        JustBash.exec(bash, "sqlite3 mydb 'CREATE TABLE t (x INTEGER, y TEXT)'")

      {_, bash} = JustBash.exec(bash, "sqlite3 mydb 'INSERT INTO t VALUES (1, NULL)'")

      {result, bash} = JustBash.exec(bash, "sqlite3 mydb 'SELECT * FROM t'")
      assert result.stdout == "1|\n"

      {result, bash} = JustBash.exec(bash, "sqlite3 mydb 'SELECT * FROM t' --json")
      assert Jason.decode!(result.stdout) == [%{"x" => 1, "y" => nil}]

      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb 'SELECT * FROM t' --csv")
      assert result.stdout == "x,y\n1,\n"
    end

    test "aggregation queries" do
      bash = JustBash.new()

      script = """
      sqlite3 db 'CREATE TABLE sales (amount INTEGER)'
      sqlite3 db 'INSERT INTO sales VALUES (100)'
      sqlite3 db 'INSERT INTO sales VALUES (200)'
      sqlite3 db 'INSERT INTO sales VALUES (300)'
      sqlite3 db 'SELECT SUM(amount), AVG(amount), COUNT(*) FROM sales' --json
      """

      {result, _bash} = JustBash.exec(bash, script)

      parsed = Jason.decode!(result.stdout)

      assert parsed == [
               %{"SUM(amount)" => 600, "AVG(amount)" => 200.0, "COUNT(*)" => 3}
             ]
    end
  end

  describe ".import command" do
    test "imports CSV from file and auto-creates table" do
      bash =
        JustBash.new(
          files: %{
            "/tmp/data.csv" => "id,name,score\n1,alice,100\n2,bob,85\n3,charlie,92"
          }
        )

      {result, bash} = JustBash.exec(bash, ~s[sqlite3 mydb ".import /tmp/data.csv users"])
      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb 'SELECT * FROM users' --json")
      data = Jason.decode!(result.stdout)

      assert data == [
               %{"id" => "1", "name" => "alice", "score" => "100"},
               %{"id" => "2", "name" => "bob", "score" => "85"},
               %{"id" => "3", "name" => "charlie", "score" => "92"}
             ]
    end

    test "imports CSV from stdin via pipe" do
      bash =
        JustBash.new(
          files: %{
            "/tmp/data.csv" => "name,value\nfoo,123\nbar,456"
          }
        )

      {result, bash} =
        JustBash.exec(bash, ~s[cat /tmp/data.csv | sqlite3 mydb ".import /dev/stdin items"])

      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb 'SELECT * FROM items'")
      assert result.stdout == "foo|123\nbar|456\n"
    end

    test "imports CSV using - for stdin" do
      bash =
        JustBash.new(files: %{"/tmp/data.csv" => "x,y\n1,2\n3,4"})

      {result, bash} =
        JustBash.exec(bash, ~s[cat /tmp/data.csv | sqlite3 mydb ".import - points"])

      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb 'SELECT COUNT(*) FROM points'")
      assert String.trim(result.stdout) == "2"
    end

    test "imports into existing table" do
      bash = JustBash.new()

      {_, bash} =
        JustBash.exec(bash, "sqlite3 mydb 'CREATE TABLE t (a TEXT, b TEXT)'")

      {_, bash} =
        JustBash.exec(bash, "sqlite3 mydb \"INSERT INTO t VALUES ('existing', 'row')\"")

      csv = "a,b\nnew1,val1\nnew2,val2"

      bash =
        put_in(
          bash.fs,
          InMemoryFs.write_file(bash.fs, "/tmp/more.csv", csv) |> elem(1)
        )

      {result, bash} = JustBash.exec(bash, ~s[sqlite3 mydb ".import /tmp/more.csv t"])
      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb 'SELECT COUNT(*) FROM t'")
      assert String.trim(result.stdout) == "3"
    end

    test "handles quoted CSV fields with commas" do
      bash =
        JustBash.new(
          files: %{
            "/tmp/data.csv" =>
              ~s|name,address\n"Smith, John","123 Main St"\n"Doe, Jane","456 Oak Ave"|
          }
        )

      {_, bash} = JustBash.exec(bash, ~s[sqlite3 mydb ".import /tmp/data.csv people"])
      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb 'SELECT name FROM people'")

      assert result.stdout == "Smith, John\nDoe, Jane\n"
    end

    test "handles CSV with escaped quotes" do
      bash =
        JustBash.new(
          files: %{
            "/tmp/data.csv" => ~s|text\n"He said ""hello"""|
          }
        )

      {_, bash} = JustBash.exec(bash, ~s[sqlite3 mydb ".import /tmp/data.csv quotes"])
      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb 'SELECT * FROM quotes'")

      assert result.stdout == ~s|He said "hello"\n|
    end

    test "error when file not found" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, ~s[sqlite3 mydb ".import /nonexistent.csv t"])
      assert result.exit_code == 1
      assert result.stderr =~ "cannot open"
    end

    test "error when .import missing arguments" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, ~s[sqlite3 mydb ".import /tmp/file.csv"])
      assert result.exit_code == 1
      assert result.stderr =~ "requires FILE TABLE"
    end
  end

  describe ".tables command" do
    test "lists all tables" do
      bash = JustBash.new()

      {_, bash} = JustBash.exec(bash, "sqlite3 mydb 'CREATE TABLE users (id INTEGER)'")
      {_, bash} = JustBash.exec(bash, "sqlite3 mydb 'CREATE TABLE orders (id INTEGER)'")
      {_, bash} = JustBash.exec(bash, "sqlite3 mydb 'CREATE TABLE products (id INTEGER)'")

      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb .tables")

      tables = String.split(result.stdout, "\n", trim: true)
      assert Enum.sort(tables) == ["orders", "products", "users"]
    end

    test "empty for new database" do
      bash = JustBash.new()
      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb .tables")
      assert result.stdout == ""
    end
  end

  describe ".schema command" do
    test "shows schema for all tables" do
      bash = JustBash.new()

      {_, bash} = JustBash.exec(bash, "sqlite3 mydb 'CREATE TABLE users (id INTEGER, name TEXT)'")

      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb .schema")

      assert result.stdout =~ "CREATE TABLE"
      assert result.stdout =~ "users"
    end

    test "shows schema for specific table" do
      bash = JustBash.new()

      {_, bash} = JustBash.exec(bash, "sqlite3 mydb 'CREATE TABLE a (x INTEGER)'")
      {_, bash} = JustBash.exec(bash, "sqlite3 mydb 'CREATE TABLE b (y TEXT)'")

      {result, _bash} = JustBash.exec(bash, "sqlite3 mydb '.schema a'")

      assert result.stdout =~ "a"
      refute result.stdout =~ "b"
    end
  end
end
