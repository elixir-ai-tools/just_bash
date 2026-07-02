defmodule JustBash.MountIntegrationTest do
  use ExUnit.Case, async: true

  alias JustBash.Test.NoEmptyDirsBackend

  describe "mutations on restricted mounts" do
    test "mkdir on a backend without directory support fails with exit 1, not a crash" do
      bash = JustBash.new() |> JustBash.mount("/mnt", %NoEmptyDirsBackend{})

      {result, _bash} = JustBash.exec(bash, "mkdir /mnt/newdir")
      assert result.exit_code == 1
      assert result.stderr =~ "mkdir: cannot create directory '/mnt/newdir'"
      assert result.stderr =~ "Operation not supported"
    end

    test "mkdir -p on a backend without directory support fails with exit 1, not a crash" do
      bash = JustBash.new() |> JustBash.mount("/mnt", %NoEmptyDirsBackend{})

      {result, _bash} = JustBash.exec(bash, "mkdir -p /mnt/a/b")
      assert result.exit_code == 1
      assert result.stderr =~ "Operation not supported"
    end

    test "rm on a read-only backend fails with exit 1, not a crash" do
      bash =
        JustBash.new()
        |> JustBash.mount("/mnt", %NoEmptyDirsBackend{files: %{"/f.txt" => "x"}, read_only: true})

      {result, _bash} = JustBash.exec(bash, "rm /mnt/f.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "rm: cannot remove '/mnt/f.txt'"
      assert result.stderr =~ "Read-only file system"
    end
  end

  describe "JustBash.mount/3" do
    test "bash commands read a mounted VFS.Memory backend" do
      bash =
        JustBash.new()
        |> JustBash.mount("/mnt", VFS.Memory.new(%{"/data.csv" => "a,b\n1,2\n"}))

      {result, _bash} = JustBash.exec(bash, "cat /mnt/data.csv")
      assert result.exit_code == 0
      assert result.stdout == "a,b\n1,2\n"
    end

    test "mounted files appear in ls and glob expansion" do
      bash =
        JustBash.new()
        |> JustBash.mount("/mnt", VFS.Memory.new(%{"/one.txt" => "1", "/two.txt" => "2"}))

      {result, bash} = JustBash.exec(bash, "ls /mnt")
      assert result.stdout == "one.txt\ntwo.txt\n"

      {result, _bash} = JustBash.exec(bash, "echo /mnt/*.txt")
      assert result.stdout == "/mnt/one.txt /mnt/two.txt\n"
    end

    test "writes and redirections route to the mounted backend" do
      bash = JustBash.new() |> JustBash.mount("/mnt", VFS.Memory.new())

      {result, bash} =
        JustBash.exec(bash, "echo hello > /mnt/out.txt && echo more >> /mnt/out.txt")

      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "cat /mnt/out.txt")
      assert result.stdout == "hello\nmore\n"
    end

    test "cp works across mounts" do
      bash =
        JustBash.new(files: %{"/home/user/src.txt" => "cross-mount"})
        |> JustBash.mount("/mnt", VFS.Memory.new())

      {result, bash} = JustBash.exec(bash, "cp /home/user/src.txt /mnt/dest.txt")
      assert result.exit_code == 0

      {result, _bash} = JustBash.exec(bash, "cat /mnt/dest.txt")
      assert result.stdout == "cross-mount"
    end

    test "cd and pwd work inside a mount" do
      bash =
        JustBash.new()
        |> JustBash.mount("/mnt", VFS.Memory.new(%{"/sub/f.txt" => "x"}))

      {result, _bash} = JustBash.exec(bash, "cd /mnt/sub && pwd && cat f.txt")
      assert result.exit_code == 0
      assert result.stdout == "/mnt/sub\nx"
    end

    test "conditionals see mounted paths" do
      bash =
        JustBash.new()
        |> JustBash.mount("/mnt", VFS.Memory.new(%{"/f.txt" => "content"}))

      {result, _bash} =
        JustBash.exec(bash, ~s{[[ -f /mnt/f.txt ]] && echo yes; [[ -d /mnt ]] && echo dir})

      assert result.stdout == "yes\ndir\n"
    end

    test "symlink creation on a backend without symlinks fails gracefully" do
      bash =
        JustBash.new()
        |> JustBash.mount("/mnt", VFS.Memory.new(%{"/f.txt" => "x"}))

      {result, _bash} = JustBash.exec(bash, "ln -s /mnt/f.txt /mnt/link")
      assert result.exit_code == 1
      assert result.stderr =~ "Operation not supported"
      assert result.stdout == ""
    end

    test "umount removes the mount" do
      bash =
        JustBash.new()
        |> JustBash.mount("/mnt", VFS.Memory.new(%{"/f.txt" => "x"}))
        |> JustBash.umount("/mnt")

      {result, _bash} = JustBash.exec(bash, "cat /mnt/f.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end
  end
end
