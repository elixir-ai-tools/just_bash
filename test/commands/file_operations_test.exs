defmodule JustBash.Commands.FileOperationsTest do
  use ExUnit.Case, async: true

  alias JustBash.FS

  defp try_help, do: "Try 'cp --help' for more information.\n"

  describe "ls command" do
    test "ls nonexistent directory fails" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "ls /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end

    test "ls lists directory contents" do
      bash = JustBash.new(files: %{"/data/file1.txt" => "a", "/data/file2.txt" => "b"})
      {result, _} = JustBash.exec(bash, "ls /data")
      assert result.stdout =~ "file1.txt"
      assert result.stdout =~ "file2.txt"
    end

    test "ls -a shows hidden files and . .." do
      bash = JustBash.new(files: %{"/data/.hidden" => "x", "/data/visible" => "y"})
      {result, _} = JustBash.exec(bash, "ls -a /data")
      assert result.stdout =~ "."
      assert result.stdout =~ ".."
      assert result.stdout =~ ".hidden"
      assert result.stdout =~ "visible"
    end

    test "ls -l shows long format" do
      bash = JustBash.new(files: %{"/data/file.txt" => "content"})
      {result, _} = JustBash.exec(bash, "ls -l /data")
      assert result.stdout =~ "file.txt"
      assert result.stdout =~ "rw"
    end

    test "ls -la combines flags" do
      bash = JustBash.new(files: %{"/data/.hidden" => "x"})
      {result, _} = JustBash.exec(bash, "ls -la /data")
      assert result.stdout =~ ".hidden"
      assert result.stdout =~ "rw"
    end

    test "ls hides dotfiles by default" do
      bash = JustBash.new(files: %{"/data/.hidden" => "x", "/data/visible" => "y"})
      {result, _} = JustBash.exec(bash, "ls /data")
      refute result.stdout =~ ".hidden"
      assert result.stdout =~ "visible"
    end

    test "ls on single file shows filename" do
      bash = JustBash.new(files: %{"/file.txt" => "x"})
      {result, _} = JustBash.exec(bash, "ls /file.txt")
      assert result.stdout == "/file.txt\n"
    end

    test "ls -lh shows human-readable file sizes" do
      bash = JustBash.new(files: %{"/data/big.txt" => String.duplicate("x", 2048)})
      {result, _} = JustBash.exec(bash, "ls -lh /data")
      assert result.exit_code == 0
      assert result.stderr == ""
      assert result.stdout =~ "big.txt"
      assert result.stdout =~ "K"
    end

    test "ls -lah combines all three flags" do
      bash =
        JustBash.new(
          files: %{
            "/data/.hidden" => String.duplicate("x", 2048),
            "/data/visible" => "small"
          }
        )

      {result, _} = JustBash.exec(bash, "ls -lah /data")
      assert result.exit_code == 0
      assert result.stdout =~ ".hidden"
      assert result.stdout =~ "visible"
      assert result.stdout =~ "rw"
    end

    test "ls -h without -l is accepted" do
      bash = JustBash.new(files: %{"/data/file.txt" => "content"})
      {result, _} = JustBash.exec(bash, "ls -h /data")
      assert result.exit_code == 0
      assert result.stdout =~ "file.txt"
    end

    test "ls -lh shows small files without suffix" do
      bash = JustBash.new(files: %{"/data/tiny.txt" => "hi"})
      {result, _} = JustBash.exec(bash, "ls -lh /data")
      assert result.exit_code == 0
      assert result.stdout =~ "2"
      assert result.stdout =~ "tiny.txt"
    end
  end

  describe "cp/mv self-copy through a symlink" do
    # A symlinked destination used to walk around the subtree guard, which
    # compares path spellings: with `l -> /w/a`, "/w/l/x" is inside "/w/a" but
    # shares no prefix with it, so each pass created children under the tree it
    # was still walking. These four hung; `mv /w/a /w/l` destroyed the source.
    # Wording checked against GNU coreutils 9.11.
    setup do
      bash =
        JustBash.new(files: %{"/w/a/f" => "hi\n"}, cwd: "/w")
        |> then(&elem(JustBash.exec(&1, "ln -s /w/a /w/l"), 1))

      {:ok, bash: bash}
    end

    @tag timeout: 10_000
    test "cp -r into a symlink to the source reports copying into itself", %{bash: bash} do
      {result, bash} = JustBash.exec(bash, "cp -r a l")

      assert result.exit_code == 1
      assert result.stderr == "cp: cannot copy a directory, 'a', into itself, 'l/a'\n"

      {cat, _} = JustBash.exec(bash, "cat /w/a/f")
      assert cat.stdout == "hi\n"
    end

    @tag timeout: 10_000
    test "cp -r beneath a symlink to the source is refused", %{bash: bash} do
      {result, bash} = JustBash.exec(bash, "cp -r a l/x")

      # GNU reaches this through its inode-based self-detection mid-walk and
      # words it "will not create hard link 'l/x/x' to directory 'l/x'". The
      # upfront path check gets here first, so the wording differs; exit code
      # and the untouched source match. Deliberately not fixtured.
      assert result.exit_code == 1
      assert result.stderr == "cp: cannot copy a directory, 'a', into itself, 'l/x'\n"

      {cat, _} = JustBash.exec(bash, "cat /w/a/f")
      assert cat.stdout == "hi\n"
    end

    @tag timeout: 10_000
    test "mv into a symlink to the source leaves the source intact", %{bash: bash} do
      {result, bash} = JustBash.exec(bash, "mv a l")

      assert result.exit_code == 1
      assert result.stderr == "mv: cannot move 'a' to a subdirectory of itself, 'l/a'\n"

      # The regression this guards: the copy silently did nothing and the
      # recursive remove then deleted the original.
      {cat, _} = JustBash.exec(bash, "cat /w/a/f")
      assert cat.stdout == "hi\n"
    end

    @tag timeout: 10_000
    test "mv beneath a symlink to the source leaves the source intact", %{bash: bash} do
      {result, bash} = JustBash.exec(bash, "mv a l/x")

      assert result.exit_code == 1
      assert result.stderr == "mv: cannot move 'a' to a subdirectory of itself, 'l/x'\n"

      {cat, _} = JustBash.exec(bash, "cat /w/a/f")
      assert cat.stdout == "hi\n"
    end

    @tag timeout: 10_000
    test "a symlinked destination outside the source still copies", %{bash: bash} do
      {mk, bash} = JustBash.exec(bash, "mkdir /other && ln -s /other /w/out")
      assert mk.exit_code == 0

      {result, bash} = JustBash.exec(bash, "cp -r a out/copy")
      assert result.exit_code == 0
      assert result.stderr == ""

      {cat, _} = JustBash.exec(bash, "cat /other/copy/f")
      assert cat.stdout == "hi\n"
    end
  end

  describe "cp command" do
    test "cp copies file" do
      bash = JustBash.new(files: %{"/src.txt" => "content"})
      {result, bash} = JustBash.exec(bash, "cp /src.txt /dest.txt")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "cat /dest.txt")
      assert result2.stdout == "content"
    end

    test "cp file not found error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "cp /nonexistent /dest")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end

    test "cp missing operand error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "cp")
      assert result.exit_code == 1
      assert result.stderr =~ "missing file operand"
    end

    test "cp with only a source reports the missing destination operand" do
      bash = JustBash.new(files: %{"/src.txt" => "content"})
      {result, _} = JustBash.exec(bash, "cp /src.txt")
      assert result.exit_code == 1

      assert result.stderr ==
               "cp: missing destination file operand after '/src.txt'\n" <> try_help()
    end

    test "cp into an existing directory uses the source basename" do
      bash = JustBash.new(files: %{"/m/a.md" => "A\n", "/m/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp /m/a.md /m/d")
      assert result.exit_code == 0
      assert result.stderr == ""

      {cat, _} = JustBash.exec(bash, "cat /m/d/a.md")
      assert cat.stdout == "A\n"
    end

    test "cp into an existing directory with a trailing slash" do
      bash = JustBash.new(files: %{"/m/a.md" => "A\n", "/m/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp /m/a.md /m/d/")
      assert result.exit_code == 0
      assert result.stderr == ""

      {cat, _} = JustBash.exec(bash, "cat /m/d/a.md")
      assert cat.stdout == "A\n"

      {cat2, _} = JustBash.exec(bash, "cat /m/d/k.md")
      assert cat2.stdout == "K\n"
    end

    test "cp into a relative directory resolves against the cwd" do
      bash = JustBash.new(files: %{"/work/a.md" => "A\n"})
      {_, bash} = JustBash.exec(bash, "mkdir /work/d")

      {result, bash} = JustBash.exec(bash, "cd /work && cp a.md d")
      assert result.exit_code == 0

      {cat, _} = JustBash.exec(bash, "cat /work/d/a.md")
      assert cat.stdout == "A\n"
    end

    test "cp preserves the source file mode" do
      bash = JustBash.new()
      {:ok, fs} = FS.write_file(bash.fs, "/src.sh", "echo hi\n", mode: 0o755)
      bash = %{bash | fs: fs}

      {result, bash} = JustBash.exec(bash, "cp /src.sh /dest.sh")
      assert result.exit_code == 0

      {:ok, stat, _fs} = FS.stat(bash.fs, "/dest.sh")
      assert stat.mode == 0o755
    end

    test "cp -p is accepted and keeps the source mode" do
      bash = JustBash.new()
      {:ok, fs} = FS.write_file(bash.fs, "/src.sh", "echo hi\n", mode: 0o755)
      bash = %{bash | fs: fs}

      {result, bash} = JustBash.exec(bash, "cp -p /src.sh /dest.sh")
      assert result.exit_code == 0
      assert result.stderr == ""

      {:ok, stat, _fs} = FS.stat(bash.fs, "/dest.sh")
      assert stat.mode == 0o755
    end

    test "cp of a dangling symlink reports the source" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "ln -s /nope.md /dangling")

      {result, _} = JustBash.exec(bash, "cp /dangling /out.md")
      assert result.exit_code == 1
      assert result.stderr == "cp: cannot stat '/dangling': No such file or directory\n"
    end

    test "cp dereferences a symlink source" do
      bash = JustBash.new(files: %{"/target.txt" => "hello\n"})
      {_, bash} = JustBash.exec(bash, "ln -s /target.txt /link.txt")

      {result, bash} = JustBash.exec(bash, "cp /link.txt /copy.txt")
      assert result.exit_code == 0

      {cat, bash} = JustBash.exec(bash, "cat /copy.txt")
      assert cat.stdout == "hello\n"

      {readlink, _} = JustBash.exec(bash, "readlink /copy.txt")
      assert readlink.exit_code == 1
    end

    test "cp of a directory without -r omits the directory" do
      bash = JustBash.new(files: %{"/s/x.md" => "X\n"})

      {result, bash} = JustBash.exec(bash, "cp /s /d")
      assert result.exit_code == 1
      assert result.stderr == "cp: -r not specified; omitting directory '/s'\n"

      {test_result, _} = JustBash.exec(bash, "[ -e /d ] || echo absent")
      assert test_result.stdout == "absent\n"
    end

    # Divergence from bash, shared with `mv`: this filesystem creates missing
    # destination parents instead of failing with ENOENT.
    test "cp creates missing destination parent directories" do
      bash = JustBash.new(files: %{"/a.md" => "A\n"})

      {result, bash} = JustBash.exec(bash, "cp /a.md /nodir/b.md")
      assert result.exit_code == 0
      assert result.stderr == ""

      {cat, _} = JustBash.exec(bash, "cat /nodir/b.md")
      assert cat.stdout == "A\n"
    end

    test "cp of a file onto itself reports the same file" do
      bash = JustBash.new(files: %{"/m/a.md" => "A\n"})

      {result, _} = JustBash.exec(bash, "cp /m/a.md /m/")
      assert result.exit_code == 1
      assert result.stderr == "cp: '/m/a.md' and '/m/a.md' are the same file\n"
    end

    test "cp -r copies a directory into an existing directory" do
      bash = JustBash.new(files: %{"/m/s/x.md" => "X\n", "/m/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp -r /m/s /m/d")
      assert result.exit_code == 0
      assert result.stderr == ""

      {cat, bash} = JustBash.exec(bash, "cat /m/d/s/x.md")
      assert cat.stdout == "X\n"

      {cat2, _} = JustBash.exec(bash, "cat /m/s/x.md")
      assert cat2.stdout == "X\n"
    end

    test "cp -R copies a directory into an existing directory" do
      bash = JustBash.new(files: %{"/m/s/x.md" => "X\n", "/m/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp -R /m/s /m/d")
      assert result.exit_code == 0

      {cat, _} = JustBash.exec(bash, "cat /m/d/s/x.md")
      assert cat.stdout == "X\n"
    end

    test "cp --recursive copies a directory into an existing directory" do
      bash = JustBash.new(files: %{"/m/s/x.md" => "X\n", "/m/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp --recursive /m/s /m/d")
      assert result.exit_code == 0

      {cat, _} = JustBash.exec(bash, "cat /m/d/s/x.md")
      assert cat.stdout == "X\n"
    end

    test "cp -rf combines flags" do
      bash = JustBash.new(files: %{"/m/s/x.md" => "X\n", "/m/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp -rf /m/s /m/d")
      assert result.exit_code == 0

      {cat, _} = JustBash.exec(bash, "cat /m/d/s/x.md")
      assert cat.stdout == "X\n"
    end

    test "cp -a copies a directory tree" do
      bash = JustBash.new(files: %{"/m/s/x.md" => "X\n", "/m/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp -a /m/s /m/d")
      assert result.exit_code == 0

      {cat, _} = JustBash.exec(bash, "cat /m/d/s/x.md")
      assert cat.stdout == "X\n"
    end

    test "cp -r copies the source as the destination when the destination does not exist" do
      bash = JustBash.new(files: %{"/m/s/x.md" => "X\n"})

      {result, bash} = JustBash.exec(bash, "cp -r /m/s /m/newdir")
      assert result.exit_code == 0
      assert result.stderr == ""

      {cat, bash} = JustBash.exec(bash, "cat /m/newdir/x.md")
      assert cat.stdout == "X\n"

      {test_result, _} = JustBash.exec(bash, "[ -e /m/newdir/s ] || echo absent")
      assert test_result.stdout == "absent\n"
    end

    test "cp -r with a trailing slash on the source still uses the source basename" do
      bash = JustBash.new(files: %{"/m/s/x.md" => "X\n", "/m/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp -r /m/s/ /m/d")
      assert result.exit_code == 0

      {cat, _} = JustBash.exec(bash, "cat /m/d/s/x.md")
      assert cat.stdout == "X\n"
    end

    test "cp -r with a trailing slash on the destination" do
      bash = JustBash.new(files: %{"/m/s/x.md" => "X\n", "/m/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp -r /m/s /m/d/")
      assert result.exit_code == 0

      {cat, _} = JustBash.exec(bash, "cat /m/d/s/x.md")
      assert cat.stdout == "X\n"
    end

    test "cp -r with a trailing slash on both operands and a new destination" do
      bash = JustBash.new(files: %{"/m/s/x.md" => "X\n"})

      {result, bash} = JustBash.exec(bash, "cp -r /m/s/ /m/newdir/")
      assert result.exit_code == 0

      {cat, _} = JustBash.exec(bash, "cat /m/newdir/x.md")
      assert cat.stdout == "X\n"
    end

    test "cp -r of a dot-suffixed source copies the contents" do
      bash = JustBash.new(files: %{"/m/s/x.md" => "X\n", "/m/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp -r /m/s/. /m/d")
      assert result.exit_code == 0

      {cat, bash} = JustBash.exec(bash, "cat /m/d/x.md")
      assert cat.stdout == "X\n"

      {cat2, _} = JustBash.exec(bash, "cat /m/d/k.md")
      assert cat2.stdout == "K\n"
    end

    test "cp -r merges into an existing destination subtree" do
      bash = JustBash.new(files: %{"/m/s/x.md" => "X\n", "/m/d/s/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp -r /m/s /m/d")
      assert result.exit_code == 0

      {cat, bash} = JustBash.exec(bash, "cat /m/d/s/x.md")
      assert cat.stdout == "X\n"

      {cat2, _} = JustBash.exec(bash, "cat /m/d/s/k.md")
      assert cat2.stdout == "K\n"
    end

    test "cp -r copies nested directories" do
      bash = JustBash.new(files: %{"/s/n/x.md" => "X\n", "/s/y.md" => "Y\n"})

      {result, bash} = JustBash.exec(bash, "cp -r /s /d")
      assert result.exit_code == 0

      {cat, bash} = JustBash.exec(bash, "cat /d/n/x.md")
      assert cat.stdout == "X\n"

      {cat2, _} = JustBash.exec(bash, "cat /d/y.md")
      assert cat2.stdout == "Y\n"
    end

    test "cp -r refuses to copy a directory into itself" do
      bash = JustBash.new(files: %{"/a/b/c.md" => "C\n"})

      {result, _} = JustBash.exec(bash, "cp -r /a /a/b")
      assert result.exit_code == 1
      assert result.stderr == "cp: cannot copy a directory, '/a', into itself, '/a/b/a'\n"
    end

    test "cp -r of a directory onto itself reports the same file" do
      bash = JustBash.new(files: %{"/a/b/c.md" => "C\n"})

      {result, _} = JustBash.exec(bash, "cp -r /a/b /a")
      assert result.exit_code == 1
      assert result.stderr == "cp: '/a/b' and '/a/b' are the same file\n"
    end

    test "cp -r cannot overwrite a non-directory with a directory" do
      bash = JustBash.new(files: %{"/s/x.md" => "X\n", "/f" => "F\n"})

      {result, bash} = JustBash.exec(bash, "cp -r /s /f")
      assert result.exit_code == 1
      assert result.stderr == "cp: cannot overwrite non-directory '/f' with directory '/s'\n"

      {cat, _} = JustBash.exec(bash, "cat /f")
      assert cat.stdout == "F\n"
    end

    test "cp -r copies a regular file like a plain cp" do
      bash = JustBash.new(files: %{"/a.md" => "A\n"})

      {result, bash} = JustBash.exec(bash, "cp -r /a.md /b.md")
      assert result.exit_code == 0

      {cat, _} = JustBash.exec(bash, "cat /b.md")
      assert cat.stdout == "A\n"
    end

    test "cp copies multiple sources into a directory" do
      bash = JustBash.new(files: %{"/a.md" => "A\n", "/b.md" => "B\n", "/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp /a.md /b.md /d")
      assert result.exit_code == 0
      assert result.stderr == ""

      {cat, bash} = JustBash.exec(bash, "cat /d/a.md /d/b.md")
      assert cat.stdout == "A\nB\n"

      {cat2, _} = JustBash.exec(bash, "cat /d/k.md")
      assert cat2.stdout == "K\n"
    end

    test "cp with several operands requires a directory target" do
      bash = JustBash.new(files: %{"/a.md" => "A\n", "/b.md" => "B\n", "/c.md" => "C\n"})

      {result, bash} = JustBash.exec(bash, "cp /a.md /b.md /c.md")
      assert result.exit_code == 1
      assert result.stderr == "cp: target '/c.md': Not a directory\n"

      {cat, _} = JustBash.exec(bash, "cat /c.md")
      assert cat.stdout == "C\n"
    end

    test "cp with several operands requires the target to exist" do
      bash = JustBash.new(files: %{"/a.md" => "A\n", "/b.md" => "B\n"})

      {result, _} = JustBash.exec(bash, "cp /a.md /b.md /nodir")
      assert result.exit_code == 1
      assert result.stderr == "cp: target '/nodir': No such file or directory\n"
    end

    test "cp keeps copying after a failing source and exits 1" do
      bash = JustBash.new(files: %{"/a.md" => "A\n", "/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp /nope.md /a.md /d")
      assert result.exit_code == 1
      assert result.stderr == "cp: cannot stat '/nope.md': No such file or directory\n"

      {cat, _} = JustBash.exec(bash, "cat /d/a.md")
      assert cat.stdout == "A\n"
    end

    test "cp -r copies several directories into a directory" do
      bash =
        JustBash.new(files: %{"/s1/x.md" => "X\n", "/s2/y.md" => "Y\n", "/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp -r /s1 /s2 /d")
      assert result.exit_code == 0

      {cat, bash} = JustBash.exec(bash, "cat /d/s1/x.md")
      assert cat.stdout == "X\n"

      {cat2, _} = JustBash.exec(bash, "cat /d/s2/y.md")
      assert cat2.stdout == "Y\n"
    end

    test "cp treats operands after -- as paths" do
      bash = JustBash.new(files: %{"/a.md" => "A\n", "/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp -- /a.md /d")
      assert result.exit_code == 0

      {cat, _} = JustBash.exec(bash, "cat /d/a.md")
      assert cat.stdout == "A\n"
    end

    test "cp of a symlink to a directory needs -r, like a directory" do
      bash = JustBash.new(files: %{"/sd/x.md" => "X\n"})
      {_, bash} = JustBash.exec(bash, "ln -s /sd /sdlink")

      {result, bash} = JustBash.exec(bash, "cp /sdlink /outdir")
      assert result.exit_code == 1
      assert result.stderr == "cp: -r not specified; omitting directory '/sdlink'\n"

      {test_result, _} = JustBash.exec(bash, "[ -e /outdir ] || echo absent")
      assert test_result.stdout == "absent\n"
    end

    test "cp -r of a symlink to a directory copies the link" do
      bash = JustBash.new(files: %{"/sd/x.md" => "X\n"})
      {_, bash} = JustBash.exec(bash, "ln -s /sd /sdlink")

      {result, bash} = JustBash.exec(bash, "cp -r /sdlink /outdir")
      assert result.exit_code == 0
      assert result.stderr == ""

      # The link itself is what gets copied, so the copy points at the same
      # directory. (Reading *through* a directory symlink is a separate
      # filesystem limitation: `cat /sdlink/x.md` does not resolve either.)
      {readlink, bash} = JustBash.exec(bash, "readlink /outdir")
      assert readlink.stdout == "/sd\n"

      {test_result, _} = JustBash.exec(bash, "[ -L /outdir ] && echo link")
      assert test_result.stdout == "link\n"
    end

    test "cp -r of a symlink to a file copies the link" do
      bash = JustBash.new(files: %{"/target.md" => "T\n"})
      {_, bash} = JustBash.exec(bash, "ln -s /target.md /alink")

      {result, bash} = JustBash.exec(bash, "cp -r /alink /rcopy")
      assert result.exit_code == 0

      {readlink, _} = JustBash.exec(bash, "readlink /rcopy")
      assert readlink.stdout == "/target.md\n"
    end

    test "cp -a of a symlink copies the link" do
      bash = JustBash.new(files: %{"/target.md" => "T\n"})
      {_, bash} = JustBash.exec(bash, "ln -s /target.md /alink")

      {result, bash} = JustBash.exec(bash, "cp -a /alink /acopy")
      assert result.exit_code == 0

      {readlink, _} = JustBash.exec(bash, "readlink /acopy")
      assert readlink.stdout == "/target.md\n"
    end

    test "cp -P copies the link instead of dereferencing it" do
      bash = JustBash.new(files: %{"/target.md" => "T\n"})
      {_, bash} = JustBash.exec(bash, "ln -s /target.md /alink")

      {result, bash} = JustBash.exec(bash, "cp -P /alink /pcopy")
      assert result.exit_code == 0

      {readlink, _} = JustBash.exec(bash, "readlink /pcopy")
      assert readlink.stdout == "/target.md\n"
    end

    test "cp -d copies the link instead of dereferencing it" do
      bash = JustBash.new(files: %{"/target.md" => "T\n"})
      {_, bash} = JustBash.exec(bash, "ln -s /target.md /alink")

      {result, bash} = JustBash.exec(bash, "cp -d /alink /dcopy")
      assert result.exit_code == 0

      {readlink, _} = JustBash.exec(bash, "readlink /dcopy")
      assert readlink.stdout == "/target.md\n"
    end

    test "cp -L dereferences the link even with -r" do
      bash = JustBash.new(files: %{"/sd/x.md" => "X\n"})
      {_, bash} = JustBash.exec(bash, "ln -s /sd /sdlink")

      {result, bash} = JustBash.exec(bash, "cp -rL /sdlink /ldir")
      assert result.exit_code == 0

      {readlink, bash} = JustBash.exec(bash, "readlink /ldir")
      assert readlink.exit_code == 1

      {cat, _} = JustBash.exec(bash, "cat /ldir/x.md")
      assert cat.stdout == "X\n"
    end

    test "cp -r of a dangling symlink copies the link" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "ln -s /nope.md /dangling")

      {result, bash} = JustBash.exec(bash, "cp -r /dangling /dcopy")
      assert result.exit_code == 0
      assert result.stderr == ""

      {readlink, _} = JustBash.exec(bash, "readlink /dcopy")
      assert readlink.stdout == "/nope.md\n"
    end

    test "cp through a symlink keeps the target's mode" do
      bash = JustBash.new()
      {:ok, fs} = FS.write_file(bash.fs, "/src.sh", "echo hi\n", mode: 0o755)
      bash = %{bash | fs: fs}
      {_, bash} = JustBash.exec(bash, "ln -s /src.sh /mlink")

      {result, bash} = JustBash.exec(bash, "cp /mlink /mcopy")
      assert result.exit_code == 0

      {:ok, stat, _fs} = FS.stat(bash.fs, "/mcopy")
      assert stat.mode == 0o755
    end

    test "cp rejects an empty destination operand" do
      bash = JustBash.new(files: %{"/x/a.md" => "A\n"})

      {result, bash} = JustBash.exec(bash, "mkdir -p /work && cd /work && cp /x/a.md ''")
      assert result.exit_code == 1

      assert result.stderr ==
               "cp: cannot create regular file '': No such file or directory\n"

      {test_result, _} = JustBash.exec(bash, "[ -e /a.md ] || echo absent")
      assert test_result.stdout == "absent\n"
    end

    test "cp rejects an empty source operand" do
      bash = JustBash.new(files: %{"/d/k.md" => "K\n"})

      {result, _} = JustBash.exec(bash, "cp '' /d")
      assert result.exit_code == 1
      assert result.stderr == "cp: cannot stat '': No such file or directory\n"
    end

    test "cp rejects an empty target operand with several sources" do
      bash = JustBash.new(files: %{"/a.md" => "A\n", "/b.md" => "B\n"})

      {result, _} = JustBash.exec(bash, "cp /a.md /b.md ''")
      assert result.exit_code == 1
      assert result.stderr == "cp: target '': No such file or directory\n"
    end

    # Divergence from bash, which exits 0 and copies nothing here.
    test "cp -r rejects an empty destination operand" do
      bash = JustBash.new(files: %{"/s/x.md" => "X\n"})

      {result, _} = JustBash.exec(bash, "cp -r /s ''")
      assert result.exit_code == 1
      assert result.stderr == "cp: cannot create directory '': No such file or directory\n"
    end

    test "cp -v reports the copy it made" do
      bash = JustBash.new(files: %{"/a.md" => "A\n", "/d/k.md" => "K\n"})

      {result, _} = JustBash.exec(bash, "cp -v /a.md /d")
      assert result.exit_code == 0
      assert result.stdout == "'/a.md' -> '/d/a.md'\n"
      assert result.stderr == ""
    end

    test "cp -rv reports every copied entry, parents first" do
      bash =
        JustBash.new(files: %{"/s/n/n.md" => "N\n", "/s/y.md" => "Y\n", "/d/k.md" => "K\n"})

      {result, _} = JustBash.exec(bash, "cp -rv /s /d")
      assert result.exit_code == 0

      assert result.stdout == """
             '/s' -> '/d/s'
             '/s/n' -> '/d/s/n'
             '/s/n/n.md' -> '/d/s/n/n.md'
             '/s/y.md' -> '/d/s/y.md'
             """
    end

    test "cp -v reports each source copied into a directory" do
      bash = JustBash.new(files: %{"/a.md" => "A\n", "/b.md" => "B\n", "/d/k.md" => "K\n"})

      {result, _} = JustBash.exec(bash, "cp -v /a.md /b.md /d")
      assert result.exit_code == 0
      assert result.stdout == "'/a.md' -> '/d/a.md'\n'/b.md' -> '/d/b.md'\n"
    end

    test "cp -n keeps an existing destination" do
      bash = JustBash.new(files: %{"/a.md" => "A\n", "/d/a.md" => "OLD\n"})

      {result, bash} = JustBash.exec(bash, "cp -n /a.md /d")
      assert result.exit_code == 0
      assert result.stderr == ""

      {cat, _} = JustBash.exec(bash, "cat /d/a.md")
      assert cat.stdout == "OLD\n"
    end

    test "cp -n still copies a destination that does not exist" do
      bash = JustBash.new(files: %{"/a.md" => "A\n", "/d/k.md" => "K\n"})

      {result, bash} = JustBash.exec(bash, "cp -n /a.md /d")
      assert result.exit_code == 0

      {cat, _} = JustBash.exec(bash, "cat /d/a.md")
      assert cat.stdout == "A\n"
    end

    # A sandbox has no terminal to prompt on, so `-i` proceeds as if the prompt
    # were answered yes. Bash with no stdin refuses the overwrite and exits 1.
    test "cp -i overwrites without prompting" do
      bash = JustBash.new(files: %{"/a.md" => "A\n", "/b.md" => "B\n"})

      {result, bash} = JustBash.exec(bash, "cp -i /a.md /b.md")
      assert result.exit_code == 0

      {cat, _} = JustBash.exec(bash, "cat /b.md")
      assert cat.stdout == "A\n"
    end
  end

  describe "mv command" do
    test "mv moves file" do
      bash = JustBash.new(files: %{"/src.txt" => "content"})
      {result, bash} = JustBash.exec(bash, "mv /src.txt /dest.txt")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "cat /dest.txt")
      assert result2.stdout == "content"

      {result3, _} = JustBash.exec(bash, "cat /src.txt")
      assert result3.exit_code == 1
    end

    test "mv preserves file mode" do
      bash = JustBash.new()

      {:ok, fs} = FS.write_file(bash.fs, "/src.sh", "echo hi\n", mode: 0o755)
      bash = %{bash | fs: fs}

      {result, bash} = JustBash.exec(bash, "mv /src.sh /dest.sh")
      assert result.exit_code == 0

      {:ok, stat, _fs} = FS.stat(bash.fs, "/dest.sh")
      assert stat.mode == 0o755
    end

    test "mv moves a symlink without dereferencing it" do
      bash = JustBash.new(files: %{"/target.txt" => "hello\n"})
      {_, bash} = JustBash.exec(bash, "ln -s /target.txt /link.txt")

      {result, bash} = JustBash.exec(bash, "mv /link.txt /moved-link.txt")
      assert result.exit_code == 0

      {readlink_result, _} = JustBash.exec(bash, "readlink /moved-link.txt")
      assert readlink_result.stdout == "/target.txt\n"

      {cat_result, _} = JustBash.exec(bash, "cat /moved-link.txt")
      assert cat_result.stdout == "hello\n"

      {old_cat_result, _} = JustBash.exec(bash, "cat /link.txt")
      assert old_cat_result.exit_code == 1
    end

    test "mv into existing directory uses source basename" do
      bash = JustBash.new(files: %{"/src.txt" => "content"})
      {_, bash} = JustBash.exec(bash, "mkdir /dir")

      {result, bash} = JustBash.exec(bash, "mv /src.txt /dir")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "cat /dir/src.txt")
      assert result2.stdout == "content"
    end

    test "mv overwrites destination file by default" do
      bash = JustBash.new(files: %{"/src.txt" => "new", "/dest.txt" => "old"})

      {result, bash} = JustBash.exec(bash, "mv /src.txt /dest.txt")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "cat /dest.txt")
      assert result2.stdout == "new"

      {result3, _} = JustBash.exec(bash, "cat /src.txt")
      assert result3.exit_code == 1
    end

    test "mv creates missing destination parent directories" do
      bash = JustBash.new(files: %{"/src.txt" => "content"})

      {result, bash} = JustBash.exec(bash, "mv /src.txt /newdir/sub/dest.txt")
      assert result.exit_code == 0

      {result2, _} = JustBash.exec(bash, "cat /newdir/sub/dest.txt")
      assert result2.stdout == "content"

      {result3, _} = JustBash.exec(bash, "cat /src.txt")
      assert result3.exit_code == 1

      {result4, _} = JustBash.exec(bash, "[ -d /newdir/sub ] && echo yes || echo no")
      assert result4.stdout == "yes\n"
    end

    test "mv fails moving a directory onto an existing file" do
      bash = JustBash.new(files: %{"/srcdir/file.txt" => "content", "/dest.txt" => "old"})

      {result, bash} = JustBash.exec(bash, "mv /srcdir /dest.txt")
      assert result.exit_code == 1

      {result2, _} = JustBash.exec(bash, "cat /dest.txt")
      assert result2.stdout == "old"

      {result3, _} = JustBash.exec(bash, "cat /srcdir/file.txt")
      assert result3.stdout == "content"
    end

    test "mv file not found error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "mv /nonexistent /dest")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end

    test "mv missing operand error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "mv")
      assert result.exit_code == 1
      assert result.stderr =~ "missing file operand"
    end

    test "mv refuses to move a directory into a subdirectory of itself" do
      bash = JustBash.new(files: %{"/a/b/c.md" => "C\n"})

      {result, bash} = JustBash.exec(bash, "mv /a /a/b")
      assert result.exit_code == 1
      assert result.stderr == "mv: cannot move '/a' to a subdirectory of itself, '/a/b/a'\n"

      {cat, _} = JustBash.exec(bash, "cat /a/b/c.md")
      assert cat.stdout == "C\n"
    end

    test "mv removes source file" do
      bash = JustBash.new(files: %{"/src.txt" => "content"})
      {_, bash} = JustBash.exec(bash, "mv /src.txt /dst.txt")
      {result, _} = JustBash.exec(bash, "[ -f /src.txt ] || echo gone")
      assert result.stdout == "gone\n"
    end
  end

  describe "rm command" do
    test "rm nonexistent file fails" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "rm /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end

    test "rm -f nonexistent file succeeds" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "rm -f /nonexistent")
      assert result.exit_code == 0
    end

    test "rm -r removes directory recursively" do
      bash = JustBash.new(files: %{"/dir/file.txt" => "x"})
      {result, bash} = JustBash.exec(bash, "rm -r /dir")
      assert result.exit_code == 0
      {result, _} = JustBash.exec(bash, "[ -d /dir ] || echo gone")
      assert result.stdout == "gone\n"
    end

    test "rm -rf removes without error on missing" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "rm -rf /nonexistent")
      assert result.exit_code == 0
    end

    test "rm -fr works same as -rf" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "rm -fr /nonexistent")
      assert result.exit_code == 0
    end

    test "rm on non-empty directory without -r fails" do
      bash = JustBash.new(files: %{"/mydir/file.txt" => "x"})
      {result, _} = JustBash.exec(bash, "rm /mydir")
      assert result.exit_code == 1
      assert result.stderr =~ "Directory not empty"
    end
  end

  describe "mkdir command" do
    test "mkdir creates directory" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "mkdir /newdir")
      assert result.exit_code == 0
      {result, _} = JustBash.exec(bash, "[ -d /newdir ] && echo yes")
      assert result.stdout == "yes\n"
    end

    test "mkdir -p creates nested directories" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "mkdir -p /a/b/c/d")
      assert result.exit_code == 0
      {result, _} = JustBash.exec(bash, "[ -d /a/b/c/d ] && echo yes")
      assert result.stdout == "yes\n"
    end

    test "mkdir fails if parent doesn't exist" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "mkdir /nonexistent/dir")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end

    test "mkdir fails if already exists" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "mkdir /mydir")
      {result, _} = JustBash.exec(bash, "mkdir /mydir")
      assert result.exit_code == 1
      assert result.stderr =~ "File exists"
    end

    test "mkdir -p ignores existing directory" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "mkdir -p /mydir")
      {result, _} = JustBash.exec(bash, "mkdir -p /mydir")
      assert result.exit_code == 0
    end
  end

  describe "touch command" do
    test "touch existing file succeeds" do
      bash = JustBash.new(files: %{"/home/user/existing.txt" => "content"})
      {result, _} = JustBash.exec(bash, "touch /home/user/existing.txt")
      assert result.exit_code == 0
    end

    test "touch creates new file" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "touch /newfile.txt")
      assert result.exit_code == 0
      {result, _} = JustBash.exec(bash, "[ -f /newfile.txt ] && echo yes")
      assert result.stdout == "yes\n"
    end

    test "touch multiple files" do
      bash = JustBash.new()
      {result, bash} = JustBash.exec(bash, "touch /a.txt /b.txt /c.txt")
      assert result.exit_code == 0
      {result, _} = JustBash.exec(bash, "ls /")
      assert result.stdout =~ "a.txt"
      assert result.stdout =~ "b.txt"
      assert result.stdout =~ "c.txt"
    end
  end

  describe "ln command" do
    test "ln creates a symbolic link with -s" do
      bash = JustBash.new(files: %{"/target.txt" => "hello world\n"})
      {result, new_bash} = JustBash.exec(bash, "ln -s /target.txt /link.txt")
      assert result.exit_code == 0

      {cat_result, _} = JustBash.exec(new_bash, "cat /link.txt")
      assert cat_result.stdout == "hello world\n"
    end

    test "ln creates a relative symbolic link" do
      bash = JustBash.new(files: %{"/dir/target.txt" => "content\n"})
      {result, new_bash} = JustBash.exec(bash, "ln -s target.txt /dir/link.txt")
      assert result.exit_code == 0

      {cat_result, _} = JustBash.exec(new_bash, "cat /dir/link.txt")
      assert cat_result.stdout == "content\n"
    end

    test "ln allows dangling symlinks" do
      bash = JustBash.new()
      {result, new_bash} = JustBash.exec(bash, "ln -s /nonexistent /link.txt")
      assert result.exit_code == 0

      {cat_result, _} = JustBash.exec(new_bash, "cat /link.txt")
      assert cat_result.exit_code == 1
    end

    test "ln errors if link already exists" do
      bash = JustBash.new(files: %{"/target.txt" => "hello\n", "/link.txt" => "existing\n"})
      {result, _} = JustBash.exec(bash, "ln -s /target.txt /link.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "File exists"
    end

    test "ln with -f overwrites existing link" do
      bash =
        JustBash.new(files: %{"/target.txt" => "new content\n", "/link.txt" => "old content\n"})

      {result, new_bash} = JustBash.exec(bash, "ln -sf /target.txt /link.txt")
      assert result.exit_code == 0

      {cat_result, _} = JustBash.exec(new_bash, "cat /link.txt")
      assert cat_result.stdout == "new content\n"
    end

    test "ln creates hard link" do
      bash = JustBash.new(files: %{"/original.txt" => "hello world\n"})
      {result, new_bash} = JustBash.exec(bash, "ln /original.txt /hardlink.txt")
      assert result.exit_code == 0

      {orig, _} = JustBash.exec(new_bash, "cat /original.txt")
      {link, _} = JustBash.exec(new_bash, "cat /hardlink.txt")
      assert link.stdout == orig.stdout
    end

    test "ln hard link errors when target does not exist" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "ln /nonexistent.txt /link.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "ln hard link errors for directory" do
      bash = JustBash.new(files: %{"/dir/file.txt" => "test\n"})
      {result, _} = JustBash.exec(bash, "ln /dir /dirlink")
      assert result.exit_code == 1
      assert result.stderr =~ "not allowed"
    end

    test "ln errors on missing operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "ln")
      assert result.exit_code == 1
      assert result.stderr =~ "missing file operand"
    end
  end

  describe "cd command" do
    test "cd changes directory" do
      bash = JustBash.new()
      {result, new_bash} = JustBash.exec(bash, "cd /tmp")
      assert result.exit_code == 0
      assert new_bash.cwd == "/tmp"
    end

    test "cd with no args goes home" do
      # Set HOME explicitly to test cd going to home directory
      bash = JustBash.new(cwd: "/tmp", env: %{"HOME" => "/home/user"})
      {result, new_bash} = JustBash.exec(bash, "cd")
      assert result.exit_code == 0
      assert new_bash.cwd == "/home/user"
    end

    test "cd to nonexistent directory fails" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "cd /nonexistent")
      assert result.exit_code == 1
      assert result.stderr =~ "No such file or directory"
    end

    test "cd - returns to previous directory" do
      bash = JustBash.new()
      {_, bash} = JustBash.exec(bash, "cd /tmp")
      {result, bash} = JustBash.exec(bash, "cd -")
      assert result.stdout == "/home/user\n"
      assert bash.cwd == "/home/user"
    end

    test "cd to file fails" do
      bash = JustBash.new(files: %{"/file.txt" => "x"})
      {result, _} = JustBash.exec(bash, "cd /file.txt")
      assert result.exit_code == 1
      assert result.stderr =~ "Not a directory"
    end
  end

  describe "readlink command" do
    test "readlink reads symlink target" do
      bash = JustBash.new(files: %{"/target.txt" => "hello\n"})
      {_, new_bash} = JustBash.exec(bash, "ln -s /target.txt /link.txt")
      {result, _} = JustBash.exec(new_bash, "readlink /link.txt")
      assert result.stdout == "/target.txt\n"
      assert result.exit_code == 0
    end

    test "readlink reads relative symlink target" do
      bash = JustBash.new(files: %{"/dir/target.txt" => "hello\n"})
      {_, new_bash} = JustBash.exec(bash, "ln -s target.txt /dir/link.txt")
      {result, _} = JustBash.exec(new_bash, "readlink /dir/link.txt")
      assert result.stdout == "target.txt\n"
    end

    test "readlink with -f resolves full path" do
      bash = JustBash.new(files: %{"/dir/target.txt" => "hello\n"})
      {_, new_bash} = JustBash.exec(bash, "ln -s target.txt /dir/link.txt")
      {result, _} = JustBash.exec(new_bash, "readlink -f /dir/link.txt")
      assert result.stdout == "/dir/target.txt\n"
    end

    test "readlink errors on non-symlink without -f" do
      bash = JustBash.new(files: %{"/regular.txt" => "hello\n"})
      {result, _} = JustBash.exec(bash, "readlink /regular.txt")
      assert result.exit_code == 1
    end

    test "readlink missing operand" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "readlink")
      assert result.exit_code == 1
      assert result.stderr =~ "missing operand"
    end
  end
end
