defmodule JustBash.FS.ZipTest do
  use ExUnit.Case, async: true

  alias JustBash.FS.Zip
  alias VFS.Error

  defmodule ZipHttpClient do
    @moduledoc false
    @behaviour JustBash.HttpClient

    @impl true
    def request(%{url: "https://archives.example/fixture.zip", method: :get}) do
      {:ok,
       %{
         status: 200,
         headers: %{},
         body: zip_bytes([{~c"README.md", "from url\n"}])
       }}
    end

    def request(%{url: "https://archives.example/redirect.zip", method: :get}) do
      {:ok,
       %{
         status: 302,
         headers: %{"location" => ["https://archives.example/fixture.zip"]},
         body: ""
       }}
    end

    def request(%{url: "https://archives.example/relative-redirect.zip", method: :get}) do
      {:ok,
       %{
         status: 302,
         headers: %{"location" => ["/fixture.zip"]},
         body: ""
       }}
    end

    def request(%{method: :get}) do
      {:ok, %{status: 404, headers: %{}, body: "not found"}}
    end

    defp zip_bytes(entries) do
      {:ok, {_name, bytes}} = :zip.create(~c"fixture.zip", entries, [:memory])
      bytes
    end
  end

  describe "from_binary/2" do
    test "builds a read-only VFS backend from zip bytes" do
      {:ok, zip} =
        [
          {~c"README.md", "hello\n"},
          {~c"docs/guide.txt", "guide\n"},
          {~c"empty/", ""}
        ]
        |> zip_bytes()
        |> Zip.from_binary()

      assert {:ok, ["README.md", "docs", "empty"], ^zip} = VFS.readdir(zip, "/")
      assert {:ok, ["guide.txt"], ^zip} = VFS.readdir(zip, "/docs")
      assert {:ok, [], ^zip} = VFS.readdir(zip, "/empty")
      assert {:ok, "hello\n", ^zip} = VFS.read_file(zip, "/README.md")

      assert {:error, %Error{kind: :erofs, path: "/README.md"}} =
               VFS.write_file(zip, "/README.md", "x")

      assert VFS.Mountable.capabilities(zip) == MapSet.new([:read])
    end

    test "handles UTF-8 entry paths" do
      {:ok, zip} = Zip.from_binary(zip_bytes([{~c"café/", ""}, {~c"café/menu.txt", "coffee\n"}]))

      assert {:ok, ["café"], ^zip} = VFS.readdir(zip, "/")
      assert {:ok, ["menu.txt"], ^zip} = VFS.readdir(zip, "/café")
      assert {:ok, "coffee\n", ^zip} = VFS.read_file(zip, "/café/menu.txt")
    end

    test "returns precise VFS error kinds" do
      {:ok, zip} = Zip.from_binary(zip_bytes([{~c"dir/file.txt", "content"}]))

      assert {:error, %Error{kind: :enotdir, path: "/dir/file.txt"}} =
               VFS.readdir(zip, "/dir/file.txt")

      assert {:error, %Error{kind: :enoent, path: "/missing"}} = VFS.readdir(zip, "/missing")
      assert {:error, %Error{kind: :eisdir, path: "/dir"}} = VFS.read_file(zip, "/dir")
    end

    test "honors stream read options" do
      {:ok, zip} = Zip.from_binary(zip_bytes([{~c"lines.txt", "one\ntwo\nthree\n"}]))

      assert {:ok, stream, ^zip} = VFS.stream_read(zip, "/lines.txt", line_range: {2, 2})
      assert Enum.join(stream) == "two"

      assert {:error, %Error{kind: :einval, path: "/lines.txt"}} =
               VFS.stream_read(zip, "/lines.txt", line_range: {3, 2})
    end

    test "rejects unsafe archive entry paths" do
      assert {:error, %Error{kind: :einval}} =
               Zip.from_binary(renamed_zip_bytes(~c"safe/entryx", "../evil.txt"))

      assert {:error, %Error{kind: :einval}} =
               Zip.from_binary(renamed_zip_bytes(~c"sabsolute.txt", "/absolute.txt"))

      assert {:error, %Error{kind: :einval}} =
               Zip.from_binary(renamed_zip_bytes(~c"a/xb.txt", "a//b.txt"))

      assert {:error, %Error{kind: :einval}} =
               Zip.from_binary(renamed_zip_bytes(~c"a-b.txt", "a\\b.txt"))

      assert {:error, %Error{kind: :einval}} =
               Zip.from_binary(renamed_zip_bytes(~c"a/x", "a//"))
    end

    test "rejects file directory collisions" do
      assert {:error, %Error{kind: :einval, path: "/a"}} =
               Zip.from_binary(zip_bytes([{~c"a/", ""}, {~c"a", "file"}]))

      assert {:error, %Error{kind: :einval}} =
               Zip.from_binary(zip_bytes([{~c"a", "file"}, {~c"a/b", "child"}]))

      assert {:error, %Error{kind: :einval, path: "/a"}} =
               Zip.from_binary(zip_bytes([{~c"a/b", "child"}, {~c"a", "file"}]))
    end

    test "enforces construction resource limits before mounting" do
      bytes = zip_bytes([{~c"one.txt", "12345"}, {~c"two.txt", "67890"}])

      assert {:error, %Error{kind: :einval}} = Zip.from_binary(bytes, max_archive_bytes: 1)
      assert {:error, %Error{kind: :einval}} = Zip.from_binary(bytes, max_uncompressed_bytes: 9)
      assert {:error, %Error{kind: :einval}} = Zip.from_binary(bytes, max_entries: 1)
      assert {:error, %Error{kind: :einval}} = Zip.from_binary(bytes, max_path_bytes: 3)

      assert {:ok, %Zip{}} =
               Zip.from_binary(bytes,
                 max_archive_bytes: byte_size(bytes),
                 max_uncompressed_bytes: 10,
                 max_entries: 2,
                 max_path_bytes: 7
               )
    end
  end

  describe "from_url/3" do
    test "fetches through JustBash network policy and http client" do
      bash =
        JustBash.new(
          network: %{enabled: true, allow_list: ["archives.example"]},
          http_client: ZipHttpClient
        )

      assert {:ok, zip} = Zip.from_url(bash, "https://archives.example/fixture.zip")
      assert {:ok, "from url\n", ^zip} = VFS.read_file(zip, "/README.md")
    end

    test "follows redirects through the same policy" do
      bash =
        JustBash.new(
          network: %{enabled: true, allow_list: ["archives.example"]},
          http_client: ZipHttpClient
        )

      assert {:ok, zip} = Zip.from_url(bash, "https://archives.example/redirect.zip")
      assert {:ok, "from url\n", ^zip} = VFS.read_file(zip, "/README.md")
    end

    test "resolves relative redirects through the same policy" do
      bash =
        JustBash.new(
          network: %{enabled: true, allow_list: ["archives.example"]},
          http_client: ZipHttpClient
        )

      assert {:ok, zip} = Zip.from_url(bash, "https://archives.example/relative-redirect.zip")
      assert {:ok, "from url\n", ^zip} = VFS.read_file(zip, "/README.md")
    end

    test "refuses URLs blocked by JustBash network policy" do
      bash =
        JustBash.new(
          network: %{enabled: true, allow_list: ["allowed.example"]},
          http_client: ZipHttpClient
        )

      assert {:error, %Error{kind: :eacces}} =
               Zip.from_url(bash, "https://archives.example/fixture.zip")
    end

    test "validates timeout option before HTTP fetch" do
      bash = JustBash.new(network: %{enabled: true, allow_list: :all}, http_client: ZipHttpClient)

      assert {:error, %Error{kind: :einval}} =
               Zip.from_url(bash, "https://archives.example/fixture.zip", timeout: 0)
    end
  end

  describe "JustBash.mount/3 integration" do
    test "bash commands can read and copy out of a mounted zip" do
      {:ok, zip} =
        Zip.from_binary(
          zip_bytes([{~c"README.md", "hello\n"}, {~c"src/app.ex", "defmodule App do end\n"}])
        )

      bash = JustBash.new() |> JustBash.mount("/zip", zip)

      {result, bash} =
        JustBash.exec(bash, "ls /zip && cat /zip/README.md && cp /zip/src/app.ex /tmp/app.ex")

      assert result.exit_code == 0
      assert result.stdout == "README.md\nsrc\nhello\n"

      {result, _bash} = JustBash.exec(bash, "cat /tmp/app.ex")
      assert result.stdout == "defmodule App do end\n"
    end

    test "bash mutations into the mounted zip fail read-only" do
      {:ok, zip} = Zip.from_binary(zip_bytes([{~c"README.md", "hello\n"}]))
      bash = JustBash.new() |> JustBash.mount("/zip", zip)

      {result, _bash} = JustBash.exec(bash, "echo nope > /zip/new.txt")
      assert result.exit_code == 1
      assert result.stdout == ""
      assert result.stderr =~ "Read-only file system"
    end

    test "redirection failures happen before command side effects" do
      {:ok, zip} = Zip.from_binary(zip_bytes([{~c"README.md", "hello\n"}]))
      bash = JustBash.new() |> JustBash.mount("/zip", zip)

      {result, bash} = JustBash.exec(bash, "touch /tmp/side-effect > /zip/new.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "Read-only file system"

      {exists?, _fs} = JustBash.FS.exists?(bash.fs, "/tmp/side-effect")
      refute exists?
    end

    test "POSIX mutations on the mounted zip fail read-only" do
      {:ok, zip} = Zip.from_binary(zip_bytes([{~c"README.md", "hello\n"}]))
      bash = JustBash.new() |> JustBash.mount("/zip", zip)

      {result, _bash} = JustBash.exec(bash, "chmod 600 /zip/README.md")
      assert result.exit_code == 1
      assert result.stderr =~ "Read-only file system"
    end
  end

  defp zip_bytes(entries) do
    {:ok, {_name, bytes}} = :zip.create(~c"fixture.zip", entries, [:memory])
    bytes
  end

  defp renamed_zip_bytes(safe_name, unsafe_name) do
    safe = to_string(safe_name)
    unsafe = to_string(unsafe_name)
    true = byte_size(safe) == byte_size(unsafe)

    [{String.to_charlist(safe), "x"}]
    |> zip_bytes()
    |> :binary.replace(safe, unsafe, [:global])
  end
end
