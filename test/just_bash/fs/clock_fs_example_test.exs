defmodule JustBash.FS.ClockFSExampleTest do
  @moduledoc """
  Worked example: a custom `JustBash.FS.Backend` that synthesizes content
  on demand. Reading any file under the mount returns the current UTC
  time in nanoseconds since the epoch.
  """

  use ExUnit.Case, async: true

  alias JustBash.FS

  defmodule ClockFS do
    @moduledoc false
    @behaviour JustBash.FS.Backend

    defstruct []

    def new, do: %__MODULE__{}

    @impl true
    def exists?(%__MODULE__{}, _path), do: true

    @impl true
    def stat(%__MODULE__{}, _path) do
      {:ok,
       %{
         is_file: true,
         is_directory: false,
         is_symbolic_link: false,
         mode: 0o444,
         size: 0,
         mtime: DateTime.utc_now()
       }}
    end

    @impl true
    def lstat(state, path), do: stat(state, path)

    @impl true
    def read_file(%__MODULE__{}, _path) do
      {:ok, Integer.to_string(System.os_time(:nanosecond)) <> "\n"}
    end

    @impl true
    def readdir(%__MODULE__{}, _path), do: {:ok, ["now"]}

    @impl true
    def readlink(%__MODULE__{}, _path), do: {:error, :einval}

    @impl true
    def write_file(%__MODULE__{}, _path, _content, _opts), do: {:error, :erofs}
    @impl true
    def append_file(%__MODULE__{}, _path, _content), do: {:error, :erofs}
    @impl true
    def mkdir(%__MODULE__{}, _path, _opts), do: {:error, :erofs}
    @impl true
    def rm(%__MODULE__{}, _path, _opts), do: {:error, :erofs}
    @impl true
    def chmod(%__MODULE__{}, _path, _mode), do: {:error, :erofs}
    @impl true
    def symlink(%__MODULE__{}, _target, _link), do: {:error, :erofs}
    @impl true
    def link(%__MODULE__{}, _existing, _new), do: {:error, :erofs}
  end

  setup do
    fs = FS.new()
    {:ok, fs} = FS.mount(fs, "/clock", ClockFS.new())
    %{bash: JustBash.new(fs: fs)}
  end

  test "cat /clock/now returns the current UTC time in nanoseconds", %{bash: bash} do
    before = System.os_time(:nanosecond)
    {result, _} = JustBash.exec(bash, "cat /clock/now")
    aft = System.os_time(:nanosecond)

    assert result.exit_code == 0
    reading = String.to_integer(String.trim(result.stdout))
    assert before <= reading and reading <= aft
  end

  test "successive reads return strictly increasing values", %{bash: bash} do
    {r1, bash} = JustBash.exec(bash, "cat /clock/now")
    {r2, _} = JustBash.exec(bash, "cat /clock/now")

    t1 = String.to_integer(String.trim(r1.stdout))
    t2 = String.to_integer(String.trim(r2.stdout))
    assert t2 > t1
  end

  test "[ -e /clock/now ] succeeds", %{bash: bash} do
    {result, _} = JustBash.exec(bash, "[ -e /clock/now ]")
    assert result.exit_code == 0
  end

  test "writes fail with read-only filesystem", %{bash: bash} do
    {result, _} = JustBash.exec(bash, "echo hi > /clock/now")
    assert result.exit_code != 0
    assert result.stderr =~ "Read-only file system"
  end
end
