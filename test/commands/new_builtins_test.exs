defmodule JustBash.Commands.NewBuiltinsTest do
  use ExUnit.Case, async: true

  describe "uname" do
    test "default output (Linux x86_64)" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "uname -s")
      assert result.stdout == "Linux\n"
    end

    test "-m returns architecture" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "uname -m")
      assert result.stdout == "x86_64\n"
    end

    test "configurable via JUST_BASH_OS" do
      bash = JustBash.new(env: %{"JUST_BASH_OS" => "Darwin"})
      {result, _} = JustBash.exec(bash, "uname -s")
      assert result.stdout == "Darwin\n"
    end

    test "configurable via JUST_BASH_ARCH" do
      bash = JustBash.new(env: %{"JUST_BASH_ARCH" => "arm64"})
      {result, _} = JustBash.exec(bash, "uname -m")
      assert result.stdout == "arm64\n"
    end

    test "-a returns all info" do
      bash = JustBash.new(env: %{"JUST_BASH_OS" => "Darwin", "JUST_BASH_ARCH" => "arm64"})
      {result, _} = JustBash.exec(bash, "uname -a")
      assert result.stdout =~ "Darwin"
      assert result.stdout =~ "arm64"
    end

    test "combined flags -sm" do
      bash = JustBash.new(env: %{"JUST_BASH_OS" => "Darwin", "JUST_BASH_ARCH" => "arm64"})
      {result, _} = JustBash.exec(bash, "uname -sm")
      assert result.stdout == "Darwin arm64\n"
    end
  end

  describe "sha256sum" do
    test "hashes a file" do
      bash = JustBash.new(files: %{"/test.txt" => "hello"})
      {result, _} = JustBash.exec(bash, "sha256sum /test.txt")
      expected = :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)
      assert result.stdout == "#{expected}  /test.txt\n"
      assert result.exit_code == 0
    end

    test "hashes multiple files" do
      bash = JustBash.new(files: %{"/a.txt" => "aaa", "/b.txt" => "bbb"})
      {result, _} = JustBash.exec(bash, "sha256sum /a.txt /b.txt")
      assert result.exit_code == 0
      lines = String.split(result.stdout, "\n", trim: true)
      assert length(lines) == 2
    end

    test "error for missing file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "sha256sum /missing.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "reads from stdin with -" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "echo -n hello | sha256sum -")
      expected = :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)
      assert result.stdout =~ expected
    end

    test "works in pipeline (cut checksum)" do
      bash = JustBash.new(files: %{"/f.txt" => "data"})
      {result, _} = JustBash.exec(bash, "sha256sum /f.txt | cut -d' ' -f1")
      expected = :crypto.hash(:sha256, "data") |> Base.encode16(case: :lower)
      assert String.trim(result.stdout) == expected
    end
  end

  describe "shasum" do
    test "default algorithm is SHA-1" do
      bash = JustBash.new(files: %{"/test.txt" => "hello"})
      {result, _} = JustBash.exec(bash, "shasum /test.txt")
      expected = :crypto.hash(:sha, "hello") |> Base.encode16(case: :lower)
      assert result.stdout =~ expected
    end

    test "-a 256 uses SHA-256" do
      bash = JustBash.new(files: %{"/test.txt" => "hello"})
      {result, _} = JustBash.exec(bash, "shasum -a 256 /test.txt")
      expected = :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)
      assert result.stdout =~ expected
    end

    test "works in pipeline" do
      bash = JustBash.new(files: %{"/f.txt" => "data"})
      {result, _} = JustBash.exec(bash, "shasum -a 256 /f.txt | cut -d' ' -f1")
      expected = :crypto.hash(:sha256, "data") |> Base.encode16(case: :lower)
      assert String.trim(result.stdout) == expected
    end
  end

  describe "chmod" do
    test "succeeds on existing file" do
      bash = JustBash.new(files: %{"/script.sh" => "#!/bin/bash"})
      {result, _} = JustBash.exec(bash, "chmod +x /script.sh")
      assert result.exit_code == 0
    end

    test "fails on missing file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "chmod 755 /missing.sh")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "succeeds on directory" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "chmod 755 /tmp")
      assert result.exit_code == 0
    end
  end

  describe "chown" do
    test "succeeds on existing file" do
      bash = JustBash.new(files: %{"/file.txt" => "content"})
      {result, _} = JustBash.exec(bash, "chown user:group /file.txt")
      assert result.exit_code == 0
    end

    test "fails on missing file" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "chown root /missing.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end
  end

  describe "wget" do
    test "fails when network is disabled" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "wget http://example.com")
      assert result.exit_code == 1
      assert result.stderr =~ "network access is disabled"
    end

    test "fails without URL" do
      bash = JustBash.new(network: %{enabled: true})
      {result, _} = JustBash.exec(bash, "wget")
      assert result.exit_code == 1
      assert result.stderr =~ "missing URL"
    end
  end

  describe "mktemp" do
    test "creates a temp file" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "mktemp")
      path = String.trim(result.stdout)
      assert String.starts_with?(path, "/tmp/tmp.")
      assert result.exit_code == 0
      # File should exist
      {result2, _} = JustBash.exec(bash, "test -f '#{path}' && echo exists")
      assert result2.stdout =~ "exists"
    end

    test "creates a temp directory with -d" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "mktemp -d")
      path = String.trim(result.stdout)
      assert String.starts_with?(path, "/tmp/tmp.")
      {result2, _} = JustBash.exec(bash, "test -d '#{path}' && echo exists")
      assert result2.stdout =~ "exists"
    end

    test "custom template" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "mktemp myapp.XXXX")
      path = String.trim(result.stdout)
      assert String.starts_with?(path, "/tmp/myapp.")
      assert String.length(Path.basename(path)) > String.length("myapp.")
    end

    test "each call produces unique names" do
      bash = JustBash.new()
      {r1, bash} = JustBash.exec(bash, "mktemp")
      {r2, _} = JustBash.exec(bash, "mktemp")
      assert String.trim(r1.stdout) != String.trim(r2.stdout)
    end
  end

  describe "whoami" do
    test "returns user from USER env" do
      bash = JustBash.new(env: %{"USER" => "alice"})
      {result, _} = JustBash.exec(bash, "whoami")
      assert result.stdout == "alice\n"
    end

    test "falls back to HOME basename" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "whoami")
      assert result.stdout == "user\n"
    end
  end

  describe "id" do
    test "default output" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "id")
      assert result.stdout =~ "uid=1000"
      assert result.stdout =~ "gid=1000"
    end

    test "-u returns uid" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "id -u")
      assert result.stdout == "1000\n"
    end

    test "configurable uid" do
      bash = JustBash.new(env: %{"JUST_BASH_UID" => "0"})
      {result, _} = JustBash.exec(bash, "id -u")
      assert result.stdout == "0\n"
    end
  end

  describe "realpath" do
    test "resolves absolute path" do
      bash = JustBash.new(files: %{"/home/user/file.txt" => ""})
      {result, _} = JustBash.exec(bash, "realpath /home/user/../user/file.txt")
      assert result.stdout == "/home/user/file.txt\n"
    end

    test "resolves relative path" do
      bash = JustBash.new(files: %{"/home/user/file.txt" => ""})
      {result, _} = JustBash.exec(bash, "realpath ./subdir/../file.txt")
      assert result.stdout =~ "file.txt"
      refute result.stdout =~ ".."
    end

    test "multiple paths" do
      bash = JustBash.new(files: %{"/b" => "", "/c/d" => ""})
      {result, _} = JustBash.exec(bash, "realpath /a/../b /c/./d")
      lines = String.split(result.stdout, "\n", trim: true)
      assert length(lines) == 2
      assert "/b" in lines
      assert "/c/d" in lines
    end

    test "errors on nonexistent path" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "realpath /no/such/path")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end
  end

  describe "nproc" do
    test "returns default 4" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "nproc")
      assert result.stdout == "4\n"
    end

    test "configurable via JUST_BASH_NPROC" do
      bash = JustBash.new(env: %{"JUST_BASH_NPROC" => "16"})
      {result, _} = JustBash.exec(bash, "nproc")
      assert result.stdout == "16\n"
    end
  end

  describe "arch" do
    test "returns default x86_64" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "arch")
      assert result.stdout == "x86_64\n"
    end

    test "configurable via JUST_BASH_ARCH" do
      bash = JustBash.new(env: %{"JUST_BASH_ARCH" => "aarch64"})
      {result, _} = JustBash.exec(bash, "arch")
      assert result.stdout == "aarch64\n"
    end
  end

  describe "yes" do
    test "outputs y repeatedly" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "yes | head -3")
      assert result.stdout == "y\ny\ny\n"
    end

    test "outputs custom string" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "yes no | head -2")
      assert result.stdout == "no\nno\n"
    end
  end
end
