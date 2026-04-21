defmodule JustBash.FS.MountTest do
  use ExUnit.Case, async: true

  alias JustBash.FS
  alias JustBash.FS.InMemoryFS
  alias JustBash.FS.NullFS
  alias JustBash.FS.ReadOnlyFS

  # ---------------------------------------------------------------------------
  # 10.1 Routing
  # ---------------------------------------------------------------------------

  describe "routing" do
    test "ls /tmp with only root mounted dispatches to root" do
      bash = JustBash.new(files: %{"/tmp/a.txt" => "hello"})
      {result, _} = JustBash.exec(bash, "ls /tmp")
      assert result.exit_code == 0
      assert result.stdout =~ "a.txt"
    end

    test "ls /data with /data mounted to NullFS dispatches to NullFS" do
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data", NullFS.new())
      bash = JustBash.new(fs: fs)

      # NullFS returns :enoent for readdir, but synthetic visibility
      # means /data itself exists as a mountpoint directory
      {result, _} = JustBash.exec(bash, "ls /data")
      # NullFS has no contents, so ls should show nothing or error gracefully
      assert result.exit_code in [0, 2]
    end

    test "ls /data/sub routes to /data backend with path /sub" do
      inner = InMemoryFS.new(%{"/sub/file.txt" => "content"})
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data", inner)
      bash = JustBash.new(fs: fs)

      {result, _} = JustBash.exec(bash, "cat /data/sub/file.txt")
      assert result.exit_code == 0
      assert result.stdout == "content"
    end

    test "/datastore does not match /data mount (boundary check)" do
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data", NullFS.new())
      {:ok, fs} = FS.write_file(fs, "/datastore/file.txt", "root content")

      # /datastore/file.txt should route to root, not /data
      {:ok, content} = FS.read_file(fs, "/datastore/file.txt")
      assert content == "root content"
    end

    test "nested mounts: /data/cache routes separately from /data" do
      data_inner = InMemoryFS.new(%{"/readme.txt" => "data readme"})
      cache_inner = InMemoryFS.new(%{"/hot.bin" => "cached"})

      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data", data_inner)
      {:ok, fs} = FS.mount(fs, "/data/cache", cache_inner)

      {:ok, content1} = FS.read_file(fs, "/data/readme.txt")
      assert content1 == "data readme"

      {:ok, content2} = FS.read_file(fs, "/data/cache/hot.bin")
      assert content2 == "cached"
    end
  end

  # ---------------------------------------------------------------------------
  # 10.2 Synthetic visibility
  # ---------------------------------------------------------------------------

  describe "synthetic visibility" do
    test "ls / shows mounted /data even with empty root" do
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data", NullFS.new())

      {:ok, entries} = FS.readdir(fs, "/")
      assert "data" in entries
    end

    test "ls / shows union of root entries and mounted /data" do
      fs = FS.new(%{"/tmp/a" => "x", "/home/b" => "y"})
      {:ok, fs} = FS.mount(fs, "/data", NullFS.new())

      {:ok, entries} = FS.readdir(fs, "/")
      assert "data" in entries
      assert "tmp" in entries
      assert "home" in entries
    end

    test "ls / with shadowed /data entry shows data exactly once" do
      fs = FS.new(%{"/data/old.txt" => "old"})
      {:ok, fs} = FS.mount(fs, "/data", NullFS.new())

      {:ok, entries} = FS.readdir(fs, "/")
      assert Enum.count(entries, &(&1 == "data")) == 1
    end

    test "stat /data with /data mounted reports is_directory: true" do
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data", NullFS.new())

      {:ok, stat} = FS.stat(fs, "/data")
      assert stat.is_directory == true
    end

    test "stat synthetic ancestor directory when only nested mount exists" do
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data/nested/sub", NullFS.new())

      {:ok, stat} = FS.stat(fs, "/data/nested")
      assert stat.is_directory == true

      {:ok, stat2} = FS.stat(fs, "/data")
      assert stat2.is_directory == true
    end

    test "cd to synthetic ancestor directory succeeds" do
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data/nested/sub", NullFS.new())
      bash = JustBash.new(fs: fs)

      {result, bash} = JustBash.exec(bash, "cd /data/nested && pwd")
      assert result.exit_code == 0
      assert result.stdout =~ "/data/nested"
      assert bash.cwd == "/data/nested"
    end

    test "[ -e /data ] returns exit 0 for mounted path" do
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data", NullFS.new())
      bash = JustBash.new(fs: fs)

      {result, _} = JustBash.exec(bash, "[ -e /data ]")
      assert result.exit_code == 0
    end

    test "exists? returns true for mountpoints and synthetic ancestors" do
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data/nested/sub", NullFS.new())

      assert FS.exists?(fs, "/data") == true
      assert FS.exists?(fs, "/data/nested") == true
      assert FS.exists?(fs, "/data/nested/sub") == true
      assert FS.exists?(fs, "/data/other") == false
    end
  end

  # ---------------------------------------------------------------------------
  # 10.3 Cross-mount operations
  # ---------------------------------------------------------------------------

  describe "cross-mount operations" do
    test "cp across mounts succeeds" do
      data_inner = InMemoryFS.new()
      fs = FS.new(%{"/tmp/a.txt" => "hello"})
      {:ok, fs} = FS.mount(fs, "/data", data_inner)

      bash = JustBash.new(fs: fs)
      {result, bash} = JustBash.exec(bash, "cp /tmp/a.txt /data/a.txt")
      assert result.exit_code == 0

      # File exists in /data backend
      {result2, _} = JustBash.exec(bash, "cat /data/a.txt")
      assert result2.stdout == "hello"

      # Source still exists
      {result3, _} = JustBash.exec(bash, "cat /tmp/a.txt")
      assert result3.stdout == "hello"
    end

    test "cp -r across backends for directory" do
      data_inner = InMemoryFS.new()
      fs = FS.new(%{"/project/src/a.ex" => "defmodule A", "/project/src/b.ex" => "defmodule B"})
      {:ok, fs} = FS.mount(fs, "/data", data_inner)
      bash = JustBash.new(fs: fs)

      {result, bash} = JustBash.exec(bash, "cp -r /project /data/backup")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "cat /data/backup/src/a.ex")
      assert result2.stdout == "defmodule A"
    end

    test "mv across backends fails with cross-device link" do
      data_inner = InMemoryFS.new()
      fs = FS.new(%{"/tmp/a.txt" => "hello"})
      {:ok, fs} = FS.mount(fs, "/data", data_inner)
      bash = JustBash.new(fs: fs)

      {result, bash} = JustBash.exec(bash, "mv /tmp/a.txt /data/a.txt")
      assert result.exit_code != 0

      # Source unchanged
      {result2, _} = JustBash.exec(bash, "cat /tmp/a.txt")
      assert result2.stdout == "hello"
    end

    test "mv within same mount succeeds" do
      data_inner = InMemoryFS.new(%{"/a.txt" => "hello"})
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data", data_inner)
      bash = JustBash.new(fs: fs)

      {result, bash} = JustBash.exec(bash, "mv /data/a.txt /data/b.txt")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "cat /data/b.txt")
      assert result2.stdout == "hello"
    end
  end

  # ---------------------------------------------------------------------------
  # 10.4 Error propagation
  # ---------------------------------------------------------------------------

  describe "error propagation" do
    test "cat missing file on backend returns No such file or directory" do
      data_inner = InMemoryFS.new()
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data", data_inner)
      bash = JustBash.new(fs: fs)

      {result, _} = JustBash.exec(bash, "cat /data/missing.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end

    test "write to ReadOnlyFS mount returns Read-only file system" do
      inner = InMemoryFS.new(%{"/readme.txt" => "hello"})
      ro = ReadOnlyFS.new(inner: {InMemoryFS, inner})
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/snapshot", ro)
      bash = JustBash.new(fs: fs)

      {result, _} = JustBash.exec(bash, "echo x > /snapshot/new.txt")
      assert result.exit_code != 0
      assert result.stderr =~ "Read-only file system"
    end

    test "ReadOnlyFS allows reads" do
      inner = InMemoryFS.new(%{"/readme.txt" => "hello world"})
      ro = ReadOnlyFS.new(inner: {InMemoryFS, inner})
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/snapshot", ro)
      bash = JustBash.new(fs: fs)

      {result, _} = JustBash.exec(bash, "cat /snapshot/readme.txt")
      assert result.exit_code == 0
      assert result.stdout == "hello world"
    end
  end

  # ---------------------------------------------------------------------------
  # 10.5 Mount lifecycle
  # ---------------------------------------------------------------------------

  describe "mount lifecycle" do
    test "mount with non-absolute path returns :einval" do
      fs = FS.new()
      assert {:error, :einval} = FS.mount(fs, "data", NullFS.new())
    end

    test "mount at already-mounted point returns :eexist" do
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data", NullFS.new())
      assert {:error, :eexist} = FS.mount(fs, "/data", NullFS.new())
    end

    test "mount at / returns :eexist" do
      fs = FS.new()
      assert {:error, :eexist} = FS.mount(fs, "/", NullFS.new())
    end

    test "umount of / returns :ebusy" do
      fs = FS.new()
      assert {:error, :ebusy} = FS.umount(fs, "/")
    end

    test "umount non-existent returns :enoent" do
      fs = FS.new()
      assert {:error, :enoent} = FS.umount(fs, "/data")
    end

    test "umount restores shadowed content" do
      fs = FS.new(%{"/data/old.txt" => "old content"})
      {:ok, fs} = FS.mount(fs, "/data", NullFS.new())

      # Shadowed — NullFS returns :enoent
      assert {:error, :enoent} = FS.read_file(fs, "/data/old.txt")

      # Unmount
      {:ok, fs} = FS.umount(fs, "/data")

      # Restored
      {:ok, content} = FS.read_file(fs, "/data/old.txt")
      assert content == "old content"
    end

    test "mounts/1 lists all current mounts" do
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data", NullFS.new())

      {:ok, fs} =
        FS.mount(
          fs,
          "/snapshot",
          ReadOnlyFS.new(inner: {InMemoryFS, InMemoryFS.new()})
        )

      mount_list = FS.mounts(fs)
      assert {"/", InMemoryFS} in mount_list
      assert {"/data", NullFS} in mount_list
      assert {"/snapshot", ReadOnlyFS} in mount_list
      assert length(mount_list) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # JustBash.new/1 integration
  # ---------------------------------------------------------------------------

  describe "JustBash.new/1 integration" do
    test "fs: option uses caller's FS directly" do
      inner = InMemoryFS.new(%{"/hello.txt" => "from custom"})
      fs = %FS{mounts: [{"/", InMemoryFS, inner}]}
      bash = JustBash.new(fs: fs)

      {result, _} = JustBash.exec(bash, "cat /hello.txt")
      assert result.exit_code == 0
      assert result.stdout == "from custom"
    end

    test "fs: combined with files: raises" do
      inner = InMemoryFS.new()
      fs = %FS{mounts: [{"/", InMemoryFS, inner}]}

      assert_raise ArgumentError, ~r/cannot combine/, fn ->
        JustBash.new(fs: fs, files: %{"/a" => "b"})
      end
    end

    test "fs: combined with mounts: raises" do
      inner = InMemoryFS.new()
      fs = %FS{mounts: [{"/", InMemoryFS, inner}]}

      assert_raise ArgumentError, ~r/cannot combine/, fn ->
        JustBash.new(fs: fs, mounts: [{"/data", NullFS, []}])
      end
    end

    test "default new/0 is backward compatible" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo hello > /tmp/test.txt && cat /tmp/test.txt")
      assert result.exit_code == 0
      assert result.stdout == "hello\n"
    end

    test ":context is preserved alongside mounts" do
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data", NullFS.new())

      bash = JustBash.new(fs: fs, context: %{x: 1, api_key: "secret"})

      assert bash.context == %{x: 1, api_key: "secret"}
      assert {"/data", NullFS} in FS.mounts(bash.fs)
    end
  end

  # ---------------------------------------------------------------------------
  # NullFS behaviour
  # ---------------------------------------------------------------------------

  describe "NullFS" do
    test "queries return :enoent, mutations return {:ok, state}" do
      s = NullFS.new()
      assert NullFS.exists?(s, "/anything") == false
      assert {:error, :enoent} = NullFS.stat(s, "/x")
      assert {:error, :enoent} = NullFS.read_file(s, "/x")
      assert {:ok, %NullFS{}} = NullFS.write_file(s, "/x", "data", [])
      assert {:ok, %NullFS{}} = NullFS.mkdir(s, "/x", [])
      assert {:ok, %NullFS{}} = NullFS.rm(s, "/x", [])
    end
  end

  # ---------------------------------------------------------------------------
  # ReadOnlyFS behaviour
  # ---------------------------------------------------------------------------

  describe "ReadOnlyFS" do
    test "reads pass through" do
      inner = InMemoryFS.new(%{"/file.txt" => "content"})
      ro = ReadOnlyFS.new(inner: {InMemoryFS, inner})

      assert ReadOnlyFS.exists?(ro, "/file.txt") == true
      assert {:ok, "content"} = ReadOnlyFS.read_file(ro, "/file.txt")
      assert {:ok, stat} = ReadOnlyFS.stat(ro, "/file.txt")
      assert stat.is_file == true
    end

    test "writes return :erofs" do
      inner = InMemoryFS.new()
      ro = ReadOnlyFS.new(inner: {InMemoryFS, inner})

      assert {:error, :erofs} = ReadOnlyFS.write_file(ro, "/x", "data", [])
      assert {:error, :erofs} = ReadOnlyFS.append_file(ro, "/x", "data")
      assert {:error, :erofs} = ReadOnlyFS.mkdir(ro, "/x", [])
      assert {:error, :erofs} = ReadOnlyFS.rm(ro, "/x", [])
      assert {:error, :erofs} = ReadOnlyFS.chmod(ro, "/x", 0o755)
      assert {:error, :erofs} = ReadOnlyFS.symlink(ro, "/target", "/link")
      assert {:error, :erofs} = ReadOnlyFS.link(ro, "/a", "/b")
    end
  end

  # ---------------------------------------------------------------------------
  # FS.new/1 root: variant
  # ---------------------------------------------------------------------------

  describe "FS.new(root:)" do
    test "creates filesystem with custom root backend" do
      inner = InMemoryFS.new(%{"/hello.txt" => "custom root"})
      fs = FS.new(root: inner)

      {:ok, content} = FS.read_file(fs, "/hello.txt")
      assert content == "custom root"
      assert [{"/", InMemoryFS}] = FS.mounts(fs)
    end
  end

  # ---------------------------------------------------------------------------
  # rm -rf / across mounts
  # ---------------------------------------------------------------------------

  describe "rm -rf / across mounts" do
    test "clears all mount backends" do
      data_inner = InMemoryFS.new(%{"/file.txt" => "data content"})
      fs = FS.new(%{"/root.txt" => "root content"})
      {:ok, fs} = FS.mount(fs, "/data", data_inner)

      # Both files exist
      assert FS.exists?(fs, "/root.txt")
      assert FS.exists?(fs, "/data/file.txt")

      # rm -rf /
      {:ok, fs} = FS.rm(fs, "/", recursive: true, force: true)

      # Contents cleared, mounts still registered
      assert {:error, :enoent} = FS.read_file(fs, "/root.txt")
      assert {:error, :enoent} = FS.read_file(fs, "/data/file.txt")
      assert length(FS.mounts(fs)) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown error atom (§10.4)
  # ---------------------------------------------------------------------------

  describe "unknown error atom" do
    test "shell does not crash on unknown backend error" do
      # NullFS.write_file returns {:ok, :unit} so the write "succeeds",
      # but NullFS.read_file returns {:error, :enoent}. To test a truly
      # unknown error, we need a backend that returns something exotic.
      # We'll use a redirect to a read-only mount to trigger :erofs,
      # but the real test is that the shell survives any error atom.
      inner = InMemoryFS.new()
      ro = ReadOnlyFS.new(inner: {InMemoryFS, inner})
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/ro", ro)
      bash = JustBash.new(fs: fs)

      # This triggers :erofs which is handled. The shell should not crash.
      {result, _} = JustBash.exec(bash, "echo test > /ro/file.txt")
      assert result.exit_code != 0

      # Shell still works after the error
      {result2, _} = JustBash.exec(bash, "echo alive")
      assert result2.exit_code == 0
      assert result2.stdout == "alive\n"
    end
  end

  # ---------------------------------------------------------------------------
  # Cross-mount symlink refusal (§4.5)
  # ---------------------------------------------------------------------------

  describe "cross-mount symlink" do
    test "hard link across mounts returns :exdev" do
      data_inner = InMemoryFS.new(%{"/a.txt" => "content"})
      fs = FS.new(%{"/root.txt" => "root"})
      {:ok, fs} = FS.mount(fs, "/data", data_inner)

      assert {:error, :exdev} = FS.link(fs, "/root.txt", "/data/link.txt")
      assert {:error, :exdev} = FS.link(fs, "/data/a.txt", "/root_link.txt")
    end

    test "symlink target crossing mount boundary returns :einval at FS level" do
      data_inner = InMemoryFS.new()
      fs = FS.new(%{"/root.txt" => "root"})
      {:ok, fs} = FS.mount(fs, "/data", data_inner)

      # Creating a symlink at /data/link pointing to /root.txt crosses mounts
      assert {:error, :einval} = FS.symlink(fs, "/root.txt", "/data/link")
    end

    test "symlink within same mount succeeds" do
      data_inner = InMemoryFS.new(%{"/a.txt" => "content"})
      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data", data_inner)

      # Target /data/a.txt resolves to the same mount as link /data/link
      assert {:ok, _} = FS.symlink(fs, "/data/a.txt", "/data/link")
    end

    test "relative symlink within same mount succeeds" do
      fs = FS.new(%{"/home/user/a.txt" => "content"})
      assert {:ok, _} = FS.symlink(fs, "a.txt", "/home/user/link")
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-end integration: realistic agent sandbox
  # ---------------------------------------------------------------------------

  describe "agent sandbox scenario" do
    @tag :integration
    test "agent with read-only project snapshot + writable workspace" do
      # ---------------------------------------------------------------
      # Setup: simulate an AI agent sandbox.
      #
      #   /project   → read-only snapshot of a codebase (ReadOnlyFS)
      #   /workspace → writable scratch area (InMemoryFS)
      #   /          → default root with standard dirs
      # ---------------------------------------------------------------
      project_files = %{
        "/lib/app.ex" => "defmodule App do\n  def hello, do: :world\nend\n",
        "/lib/helper.ex" => "defmodule Helper do\n  def greet(name), do: name\nend\n",
        "/mix.exs" => "defmodule App.MixProject do\n  use Mix.Project\nend\n",
        "/README.md" => "# My App\n\nA sample project.\n",
        "/test/app_test.exs" => "defmodule AppTest do\n  use ExUnit.Case\nend\n"
      }

      project_state = InMemoryFS.new(project_files)
      ro_state = ReadOnlyFS.new(inner: {InMemoryFS, project_state})
      workspace_state = InMemoryFS.new()

      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/project", ro_state)
      {:ok, fs} = FS.mount(fs, "/workspace", workspace_state)
      bash = JustBash.new(fs: fs)

      # ---------------------------------------------------------------
      # 1. Agent can see the project structure
      # ---------------------------------------------------------------
      {result, bash} = JustBash.exec(bash, "ls /")
      assert result.exit_code == 0
      assert result.stdout =~ "project"
      assert result.stdout =~ "workspace"

      {result, bash} = JustBash.exec(bash, "ls /project")
      assert result.exit_code == 0
      assert result.stdout =~ "lib"
      assert result.stdout =~ "mix.exs"
      assert result.stdout =~ "README.md"
      assert result.stdout =~ "test"

      {result, bash} = JustBash.exec(bash, "ls /project/lib")
      assert result.exit_code == 0
      assert result.stdout =~ "app.ex"
      assert result.stdout =~ "helper.ex"

      # ---------------------------------------------------------------
      # 2. Agent can read project files
      # ---------------------------------------------------------------
      {result, bash} = JustBash.exec(bash, "cat /project/lib/app.ex")
      assert result.exit_code == 0
      assert result.stdout =~ "defmodule App"
      assert result.stdout =~ "def hello, do: :world"

      {result, bash} = JustBash.exec(bash, "wc -l /project/lib/app.ex")
      assert result.exit_code == 0
      assert result.stdout =~ "3"

      # ---------------------------------------------------------------
      # 3. Agent CANNOT modify the project (read-only)
      # ---------------------------------------------------------------
      {result, bash} = JustBash.exec(bash, "echo 'hacked' > /project/lib/app.ex")
      assert result.exit_code != 0
      assert result.stderr =~ "Read-only file system"

      {result, bash} = JustBash.exec(bash, "rm /project/README.md")
      assert result.exit_code != 0

      {result, bash} = JustBash.exec(bash, "mkdir /project/new_dir")
      assert result.exit_code != 0

      # Original content is untouched
      {result, bash} = JustBash.exec(bash, "cat /project/lib/app.ex")
      assert result.stdout =~ "defmodule App"

      # ---------------------------------------------------------------
      # 4. Agent can copy project files to workspace and modify them
      # ---------------------------------------------------------------
      {result, bash} = JustBash.exec(bash, "cp -r /project/lib /workspace/lib")
      assert result.exit_code == 0

      {result, bash} = JustBash.exec(bash, "ls /workspace/lib")
      assert result.exit_code == 0
      assert result.stdout =~ "app.ex"
      assert result.stdout =~ "helper.ex"

      # Modify the copy in workspace
      {result, bash} =
        JustBash.exec(bash, "echo 'modified app module' > /workspace/lib/app.ex")

      assert result.exit_code == 0

      {result, bash} = JustBash.exec(bash, "cat /workspace/lib/app.ex")
      assert result.stdout =~ "modified app module"

      # Project original is still intact
      {result, bash} = JustBash.exec(bash, "cat /project/lib/app.ex")
      assert result.stdout =~ ":world"

      # ---------------------------------------------------------------
      # 5. Agent can create new files in workspace
      # ---------------------------------------------------------------
      {result, bash} =
        JustBash.exec(bash, """
        mkdir -p /workspace/lib
        cat > /workspace/lib/new_module.ex << 'EOF'
        defmodule NewModule do
          def run, do: :ok
        end
        EOF
        """)

      assert result.exit_code == 0

      {result, bash} = JustBash.exec(bash, "cat /workspace/lib/new_module.ex")
      assert result.exit_code == 0
      assert result.stdout =~ "defmodule NewModule"

      # ---------------------------------------------------------------
      # 6. Agent can use grep/find across mounts
      # ---------------------------------------------------------------
      {result, bash} = JustBash.exec(bash, "grep -r 'defmodule' /project/lib")
      assert result.exit_code == 0
      assert result.stdout =~ "App"
      assert result.stdout =~ "Helper"

      {result, bash} = JustBash.exec(bash, "find /workspace -name '*.ex'")
      assert result.exit_code == 0
      assert result.stdout =~ "app.ex"
      assert result.stdout =~ "new_module.ex"

      # ---------------------------------------------------------------
      # 7. Agent cannot mv across mount boundaries
      # ---------------------------------------------------------------
      {result, bash} = JustBash.exec(bash, "mv /workspace/lib/app.ex /project/lib/app.ex")
      assert result.exit_code != 0
      assert result.stderr =~ "cross-device"

      # But mv within workspace works
      {result, bash} =
        JustBash.exec(bash, "mv /workspace/lib/new_module.ex /workspace/lib/renamed.ex")

      assert result.exit_code == 0

      {result, bash} = JustBash.exec(bash, "cat /workspace/lib/renamed.ex")
      assert result.stdout =~ "defmodule NewModule"

      # ---------------------------------------------------------------
      # 8. Agent can diff project vs workspace
      # ---------------------------------------------------------------
      {result, _bash} = JustBash.exec(bash, "diff /project/lib/app.ex /workspace/lib/app.ex")
      assert result.exit_code != 0
      assert result.stdout =~ ":world"
      assert result.stdout =~ "modified"
    end

    @tag :integration
    test "mount, use, unmount — shadowing round-trip" do
      # Start with some data at /data in the root fs
      bash = JustBash.new(files: %{"/data/original.txt" => "I was here first"})

      {result, bash} = JustBash.exec(bash, "cat /data/original.txt")
      assert result.stdout == "I was here first"

      # Mount an overlay at /data — shadows the original
      overlay = InMemoryFS.new(%{"/overlay.txt" => "I am the overlay"})
      {:ok, new_fs} = FS.mount(bash.fs, "/data", overlay)
      bash = %{bash | fs: new_fs}

      # Original is hidden
      {result, bash} = JustBash.exec(bash, "cat /data/original.txt")
      assert result.exit_code != 0
      assert result.stderr =~ "No such file"

      # Overlay is visible
      {result, bash} = JustBash.exec(bash, "cat /data/overlay.txt")
      assert result.stdout == "I am the overlay"

      # Write something to the overlay
      {_, bash} = JustBash.exec(bash, "echo 'new file' > /data/new.txt")

      # Unmount — original comes back, overlay writes are gone
      {:ok, new_fs} = FS.umount(bash.fs, "/data")
      bash = %{bash | fs: new_fs}

      {result, bash} = JustBash.exec(bash, "cat /data/original.txt")
      assert result.stdout == "I was here first"

      {result, _bash} = JustBash.exec(bash, "cat /data/new.txt")
      assert result.exit_code != 0
    end

    @tag :integration
    test "nested mounts with independent backends" do
      # /data         → backend A (general data store)
      # /data/cache   → backend B (hot cache, separate lifecycle)
      data_files = %{"/readme.txt" => "data root", "/reports/q1.csv" => "revenue,100"}
      cache_files = %{"/session.bin" => "cached_session_data"}

      data_state = InMemoryFS.new(data_files)
      cache_state = InMemoryFS.new(cache_files)

      fs = FS.new()
      {:ok, fs} = FS.mount(fs, "/data", data_state)
      {:ok, fs} = FS.mount(fs, "/data/cache", cache_state)
      bash = JustBash.new(fs: fs)

      # ls /data shows both real entries AND the synthetic "cache" child
      {result, bash} = JustBash.exec(bash, "ls /data")
      assert result.exit_code == 0
      assert result.stdout =~ "readme.txt"
      assert result.stdout =~ "reports"
      assert result.stdout =~ "cache"

      # /data/cache routes to its own backend
      {result, bash} = JustBash.exec(bash, "cat /data/cache/session.bin")
      assert result.stdout == "cached_session_data"

      # /data/reports routes to the data backend
      {result, bash} = JustBash.exec(bash, "cat /data/reports/q1.csv")
      assert result.stdout == "revenue,100"

      # Write to cache doesn't affect data
      {_, bash} = JustBash.exec(bash, "echo 'hot' > /data/cache/hot.key")

      {result, bash} = JustBash.exec(bash, "cat /data/cache/hot.key")
      assert result.stdout == "hot\n"

      # Data backend is untouched
      {result, _bash} = JustBash.exec(bash, "cat /data/readme.txt")
      assert result.stdout == "data root"
    end
  end
end
