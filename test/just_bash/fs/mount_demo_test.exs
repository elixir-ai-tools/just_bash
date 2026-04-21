defmodule JustBash.FS.MountDemoTest do
  @moduledoc """
  Demonstration of the mountable virtual filesystem.

  This test file exists to explain the mount system to maintainers. Each test
  is a self-contained scenario that shows a specific capability. Run it with:

      mix test test/just_bash/fs/mount_demo_test.exs

  The mount system lets callers compose multiple filesystem backends behind a
  single `%JustBash.FS{}` struct. The shell sees one unified directory tree.
  Backends are pluggable modules that implement `JustBash.FS.Backend`.

  Three backends ship in-tree:

    - `InMemoryFS`  — the default; a plain in-memory filesystem
    - `ReadOnlyFS`  — a decorator that wraps any backend and blocks all writes
    - `NullFS`      — a /dev/null sink (used in tests, not meant for production)

  Key design points:

    1. Backends are dumb. They operate on root-relative paths (`/`, `/foo.txt`)
       and know nothing about where they are mounted.

    2. The mount table routes operations by longest-prefix match. `/data/cache`
       is more specific than `/data`, which is more specific than `/`.

    3. Mountpoints are visible to `ls`, `stat`, `cd`, and `[ -e ... ]` even
       when the parent backend has no entry there (synthetic visibility).

    4. `cp` works transparently across mounts. `mv` across mounts is refused
       with "Invalid cross-device link", matching Linux behavior.

    5. Mounting at a path shadows whatever was there before. Unmounting
       restores the original content.
  """

  use ExUnit.Case, async: true

  alias JustBash.FS
  alias JustBash.FS.InMemoryFS
  alias JustBash.FS.ReadOnlyFS

  # ---------------------------------------------------------------------------
  # Scenario 1: AI agent sandbox
  #
  # An AI coding agent gets a read-only view of a project and a writable
  # scratch area. It can read the project, copy files to its workspace,
  # modify them, and diff the results — but it can never alter the original.
  # ---------------------------------------------------------------------------

  test "AI agent sandbox: read-only project + writable workspace" do
    # -- Setup: build the mount table --
    project =
      InMemoryFS.new(%{
        "/lib/app.ex" => "defmodule App do\n  def run, do: :ok\nend\n",
        "/lib/helpers.ex" => "defmodule Helpers do\n  def format(x), do: inspect(x)\nend\n",
        "/mix.exs" => "defmodule App.MixProject do\n  use Mix.Project\nend\n",
        "/README.md" => "# App\n\nA sample project.\n"
      })

    fs = FS.new()
    {:ok, fs} = FS.mount(fs, "/project", ReadOnlyFS, ReadOnlyFS.new(inner: {InMemoryFS, project}))
    {:ok, fs} = FS.mount(fs, "/workspace", InMemoryFS, InMemoryFS.new())

    bash = JustBash.new(fs: fs)

    # The agent can browse the project
    {r, bash} = JustBash.exec(bash, "ls /project/lib")
    assert r.exit_code == 0
    assert r.stdout =~ "app.ex"
    assert r.stdout =~ "helpers.ex"

    # The agent can read files
    {r, bash} = JustBash.exec(bash, "cat /project/lib/app.ex")
    assert r.exit_code == 0
    assert r.stdout =~ "defmodule App"

    # The agent CANNOT write to the project
    {r, bash} = JustBash.exec(bash, "echo 'pwned' > /project/lib/app.ex")
    assert r.exit_code != 0
    assert r.stderr =~ "Read-only file system"

    # The agent copies files to its workspace and edits them there
    {r, bash} = JustBash.exec(bash, "cp -r /project/lib /workspace/lib")
    assert r.exit_code == 0

    {r, bash} =
      JustBash.exec(
        bash,
        "echo 'defmodule App do\n  def run, do: :patched\nend' > /workspace/lib/app.ex"
      )

    assert r.exit_code == 0

    # The workspace copy is modified
    {r, bash} = JustBash.exec(bash, "cat /workspace/lib/app.ex")
    assert r.stdout =~ ":patched"

    # The project original is untouched
    {r, bash} = JustBash.exec(bash, "cat /project/lib/app.ex")
    assert r.stdout =~ ":ok"

    # diff shows what changed
    {r, _bash} = JustBash.exec(bash, "diff /project/lib/app.ex /workspace/lib/app.ex")
    assert r.exit_code != 0
    assert r.stdout =~ ":ok"
    assert r.stdout =~ ":patched"
  end

  # ---------------------------------------------------------------------------
  # Scenario 2: Shadowing and unmounting
  #
  # Mounting at a path hides whatever was there before. Unmounting brings it
  # back. This matches how Linux mount works.
  # ---------------------------------------------------------------------------

  test "shadowing: mount hides existing content, unmount restores it" do
    bash = JustBash.new(files: %{"/data/secret.txt" => "original secret"})

    # Before mount: file is visible
    {r, bash} = JustBash.exec(bash, "cat /data/secret.txt")
    assert r.stdout == "original secret"

    # Mount an overlay at /data — original content is now hidden
    overlay = InMemoryFS.new(%{"/public.txt" => "overlay content"})
    {:ok, new_fs} = FS.mount(bash.fs, "/data", InMemoryFS, overlay)
    bash = %{bash | fs: new_fs}

    {r, bash} = JustBash.exec(bash, "cat /data/secret.txt")
    assert r.exit_code != 0
    assert r.stderr =~ "No such file"

    {r, bash} = JustBash.exec(bash, "cat /data/public.txt")
    assert r.stdout == "overlay content"

    # Unmount — original is back
    {:ok, new_fs} = FS.umount(bash.fs, "/data")
    bash = %{bash | fs: new_fs}

    {r, _bash} = JustBash.exec(bash, "cat /data/secret.txt")
    assert r.stdout == "original secret"
  end

  # ---------------------------------------------------------------------------
  # Scenario 3: Nested mounts with independent lifecycles
  #
  # /data and /data/cache are separate backends. Writes to the cache don't
  # affect the data backend. `ls /data` shows both real children and the
  # synthetic "cache" entry from the mount table.
  # ---------------------------------------------------------------------------

  test "nested mounts: /data and /data/cache are independent" do
    data = InMemoryFS.new(%{"/readme.txt" => "data root", "/reports/q1.csv" => "revenue,100"})
    cache = InMemoryFS.new(%{"/session.bin" => "cached_session"})

    fs = FS.new()
    {:ok, fs} = FS.mount(fs, "/data", InMemoryFS, data)
    {:ok, fs} = FS.mount(fs, "/data/cache", InMemoryFS, cache)
    bash = JustBash.new(fs: fs)

    # ls /data shows real entries AND the synthetic "cache" child
    {r, bash} = JustBash.exec(bash, "ls /data")
    assert r.stdout =~ "readme.txt"
    assert r.stdout =~ "reports"
    assert r.stdout =~ "cache"

    # Reads route to the correct backend
    {r, bash} = JustBash.exec(bash, "cat /data/readme.txt")
    assert r.stdout == "data root"

    {r, bash} = JustBash.exec(bash, "cat /data/cache/session.bin")
    assert r.stdout == "cached_session"

    # Writing to cache doesn't affect data
    {_, bash} = JustBash.exec(bash, "echo 'hot' > /data/cache/new.key")
    {r, bash} = JustBash.exec(bash, "cat /data/cache/new.key")
    assert r.stdout == "hot\n"

    {r, _bash} = JustBash.exec(bash, "cat /data/readme.txt")
    assert r.stdout == "data root"
  end

  # ---------------------------------------------------------------------------
  # Scenario 4: Cross-mount copy vs move
  #
  # cp works across mount boundaries (read from A, write to B).
  # mv is refused — just like Linux refuses mv across real filesystems.
  # ---------------------------------------------------------------------------

  test "cross-mount: cp succeeds, mv is refused" do
    store = InMemoryFS.new()

    fs = FS.new(%{"/tmp/report.csv" => "col1,col2\na,b\n"})
    {:ok, fs} = FS.mount(fs, "/store", InMemoryFS, store)
    bash = JustBash.new(fs: fs)

    # cp across mounts works
    {r, bash} = JustBash.exec(bash, "cp /tmp/report.csv /store/report.csv")
    assert r.exit_code == 0

    {r, bash} = JustBash.exec(bash, "cat /store/report.csv")
    assert r.stdout == "col1,col2\na,b\n"

    # Source still exists
    {r, bash} = JustBash.exec(bash, "cat /tmp/report.csv")
    assert r.stdout == "col1,col2\na,b\n"

    # mv across mounts is refused
    {r, bash} = JustBash.exec(bash, "mv /tmp/report.csv /store/moved.csv")
    assert r.exit_code != 0
    assert r.stderr =~ "cross-device"

    # mv within a mount works fine
    {r, bash} = JustBash.exec(bash, "mv /store/report.csv /store/archived.csv")
    assert r.exit_code == 0

    {r, _bash} = JustBash.exec(bash, "cat /store/archived.csv")
    assert r.stdout == "col1,col2\na,b\n"
  end

  # ---------------------------------------------------------------------------
  # Scenario 5: Building a mount table programmatically
  #
  # This shows the API a library caller would use to set up a JustBash
  # instance with multiple mounts.
  # ---------------------------------------------------------------------------

  test "API: building a multi-mount JustBash from scratch" do
    # Option A: build the FS yourself and pass it in
    project = InMemoryFS.new(%{"/src/main.py" => "print('hello')\n"})
    ro = ReadOnlyFS.new(inner: {InMemoryFS, project})
    scratch = InMemoryFS.new()

    fs = FS.new()
    {:ok, fs} = FS.mount(fs, "/project", ReadOnlyFS, ro)
    {:ok, fs} = FS.mount(fs, "/scratch", InMemoryFS, scratch)

    bash = JustBash.new(fs: fs)

    # Verify the mount table
    mounts = FS.mounts(bash.fs)
    assert {"/", InMemoryFS} in mounts
    assert {"/project", ReadOnlyFS} in mounts
    assert {"/scratch", InMemoryFS} in mounts

    # Everything works through the shell
    {r, _} =
      JustBash.exec(
        bash,
        "cat /project/src/main.py && echo 'notes' > /scratch/notes.txt && cat /scratch/notes.txt"
      )

    assert r.exit_code == 0
    assert r.stdout == "print('hello')\nnotes\n"
  end
end
