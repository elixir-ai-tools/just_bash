defmodule JustBash.FSToTreeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias JustBash.FS

  describe "to_tree/2" do
    test "empty filesystem yields an empty tree" do
      assert {:ok, %{}, _fs} = FS.to_tree(FS.new())
    end

    test "returns every regular file keyed by absolute path" do
      files = %{
        "/a.txt" => "alpha",
        "/notes/deep/nested/b.txt" => "beta",
        "/empty" => "",
        "/bin/blob" => <<0, 255, 254, 1>>,
        "/data/café/naïve résumé.txt" => "unicode paths",
        "/with spaces/file name.txt" => "spaces"
      }

      assert {:ok, tree, _fs} = FS.to_tree(FS.new(files))
      assert tree == files
    end

    test "round-trips through new/1" do
      files = %{"/a/b.txt" => "one", "/c.bin" => <<7, 0, 9>>}

      assert {:ok, tree, _fs} = FS.to_tree(FS.new(files))
      assert {:ok, ^tree, _fs} = FS.to_tree(FS.new(tree))
    end

    test "captures content but not modes" do
      fs = FS.new(%{"/bin/script" => %{content: "#!/bin/bash", mode: 0o755}})
      assert {:ok, %{"/bin/script" => "#!/bin/bash"}, _fs} = FS.to_tree(fs)
    end

    test "omits directories, including empty ones" do
      {:ok, fs} = FS.mkdir(FS.new(%{"/kept.txt" => "x"}), "/empty/dir", parents: true)
      assert {:ok, %{"/kept.txt" => "x"}, _fs} = FS.to_tree(fs)
    end

    test "scopes to a subtree root, keeping absolute keys" do
      fs = FS.new(%{"/data/in.txt" => "in", "/other/out.txt" => "out"})
      assert {:ok, %{"/data/in.txt" => "in"}, _fs} = FS.to_tree(fs, "/data")
    end

    test "a file root yields a single-entry tree" do
      fs = FS.new(%{"/only.txt" => "just me", "/other.txt" => "not me"})
      assert {:ok, %{"/only.txt" => "just me"}, _fs} = FS.to_tree(fs, "/only.txt")
    end

    test "a missing root yields an empty tree" do
      assert {:ok, %{}, _fs} = FS.to_tree(FS.new(%{"/a.txt" => "x"}), "/nope")
    end

    test "materializes symlinks as their target's content" do
      {:ok, fs} = FS.symlink(FS.new(%{"/target.txt" => "real"}), "/target.txt", "/link.txt")

      assert {:ok, tree, _fs} = FS.to_tree(fs)
      assert tree == %{"/target.txt" => "real", "/link.txt" => "real"}
    end

    test "omits dangling symlinks" do
      {:ok, fs} = FS.symlink(FS.new(%{"/a.txt" => "x"}), "/gone", "/dangling")
      assert {:ok, %{"/a.txt" => "x"}, _fs} = FS.to_tree(fs)
    end

    test "captures files from every mount in the table" do
      fs = VFS.mount(FS.new(%{"/local.txt" => "local"}), "/mnt", FS.Memory.new(%{"/x.txt" => "mounted"}))

      assert {:ok, tree, _fs} = FS.to_tree(fs)
      assert tree == %{"/local.txt" => "local", "/mnt/x.txt" => "mounted"}
    end

    property "any conflict-free file map round-trips exactly" do
      check all files <- file_map() do
        assert {:ok, tree, _fs} = FS.to_tree(FS.new(files))
        assert tree == files
      end
    end
  end

  defp file_map do
    segment =
      string(:printable, min_length: 1, max_length: 8)
      |> filter(&(not String.contains?(&1, "/") and &1 not in [".", ".."]))

    path =
      segment
      |> list_of(min_length: 1, max_length: 4)
      |> map(&("/" <> Enum.join(&1, "/")))

    map_of(path, binary(), max_length: 8)
    |> map(&drop_ancestor_conflicts/1)
  end

  # A file cannot live below another file, so drop any path with an
  # already-kept path as a directory ancestor (or vice versa).
  defp drop_ancestor_conflicts(files) do
    files
    |> Enum.sort_by(fn {path, _} -> path end)
    |> Enum.reduce(%{}, fn {path, content}, kept ->
      conflict? =
        Enum.any?(Map.keys(kept), fn other ->
          String.starts_with?(path, other <> "/") or String.starts_with?(other, path <> "/")
        end)

      if conflict?, do: kept, else: Map.put(kept, path, content)
    end)
  end
end
