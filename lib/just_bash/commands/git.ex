if Code.ensure_loaded?(Exgit) do
  defmodule JustBash.Commands.Git do
    @moduledoc """
    The `git` command — git operations backed by Exgit.

    Supports `git clone`, `git commit`, and `git push`. Cloning lazily mounts a
    `GitFS` backend at the target path. Committing creates an in-memory git commit
    from the current tree state. Pushing sends commits to the remote.

    Git must be explicitly enabled via `JustBash.new(git: %{enabled: true})`.
    Credentials are read from `bash.git.credentials`, set by the host application
    and never exposed inside the sandbox.
    """
    @behaviour JustBash.Commands.Command

    alias Exgit.Object.Commit
    alias Exgit.ObjectStore
    alias JustBash.Commands.Command
    alias JustBash.Fs
    alias JustBash.Fs.GitFS

    @impl true
    def names, do: ["git"]

    @impl true
    def execute(bash, args, _stdin) do
      if bash.git.enabled do
        dispatch(bash, args)
      else
        {Command.error("git: command not available (git access is disabled)\n", 127), bash}
      end
    end

    defp dispatch(bash, ["clone" | rest]), do: do_clone(bash, rest)
    defp dispatch(bash, ["commit" | rest]), do: do_commit(bash, rest)
    defp dispatch(bash, ["push" | rest]), do: do_push(bash, rest)

    defp dispatch(bash, [subcmd | _]),
      do: {Command.error("git: '#{subcmd}' is not a git command\n"), bash}

    defp dispatch(bash, []), do: {Command.error("usage: git <command> [<args>]\n"), bash}

    # --- clone ---

    defp do_clone(bash, args) do
      {opts, positional} = parse_clone_args(args)

      case positional do
        [url | rest] ->
          target = clone_target(url, List.first(rest))
          resolved = Fs.resolve_path(bash.cwd, target)
          writable = not Keyword.get(opts, :bare, false)

          clone_opts =
            case bash.git.credentials do
              nil -> []
              auth -> [auth: auth]
            end

          case Exgit.clone(url, clone_opts) do
            {:ok, repo} ->
              git_state = build_git_state(repo, url, writable)
              mount_clone(bash, resolved, git_state, target)

            {:error, reason} ->
              {Command.error("fatal: #{format_error(reason)}\n", 128), bash}
          end

        [] ->
          {Command.error("fatal: You must specify a repository to clone.\n", 128), bash}
      end
    end

    defp parse_clone_args(args) do
      Enum.reduce(args, {[], []}, fn
        "--bare", {opts, pos} -> {[{:bare, true} | opts], pos}
        "--" <> _flag, {opts, pos} -> {opts, pos}
        arg, {opts, pos} -> {opts, pos ++ [arg]}
      end)
    end

    defp clone_target(url, nil) do
      url
      |> String.trim_trailing("/")
      |> String.trim_trailing(".git")
      |> String.split("/")
      |> List.last()
    end

    defp clone_target(_url, explicit), do: explicit

    defp build_git_state(repo, url, writable) do
      {tree, parent_commit} = resolve_tree_and_commit(repo)

      %GitFS{
        repo: repo,
        ref: "HEAD",
        tree: tree,
        writable: writable,
        url: url,
        parent_commit: parent_commit
      }
    end

    defp resolve_tree_and_commit(repo) do
      case Exgit.RefStore.resolve(repo.ref_store, "HEAD") do
        {:ok, commit_sha} ->
          case ObjectStore.get(repo.object_store, commit_sha) do
            {:ok, %Commit{} = c} -> {Commit.tree(c), commit_sha}
            _ -> {nil, nil}
          end

        _ ->
          {nil, nil}
      end
    end

    defp mount_clone(bash, resolved, git_state, display_name) do
      case Fs.mount(bash.fs, resolved, GitFS, git_state) do
        {:ok, new_fs} ->
          msg = "Cloning into '#{display_name}'...\n"
          {Command.result(msg, "", 0), %{bash | fs: new_fs}}

        {:error, :eexist} ->
          {Command.error(
             "fatal: destination path '#{display_name}' already exists.\n",
             128
           ), bash}

        {:error, reason} ->
          {Command.error("fatal: #{reason}\n", 128), bash}
      end
    end

    # --- commit ---

    defp do_commit(bash, args) do
      {message, _opts} = parse_commit_args(args)

      case find_git_mount(bash) do
        {:ok, mountpoint, %GitFS{tree: nil}} ->
          {Command.error("fatal: no tree to commit at #{mountpoint}\n", 128), bash}

        {:ok, mountpoint, %GitFS{} = git_state} ->
          create_commit(bash, mountpoint, git_state, message)

        {:error, msg} ->
          {Command.error(msg, 128), bash}
      end
    end

    defp parse_commit_args(args) do
      {message, opts} =
        Enum.reduce(args, {nil, []}, fn
          "-m", {msg, opts} -> {msg, [:expect_message | opts]}
          arg, {_msg, [:expect_message | opts]} -> {arg, opts}
          _arg, acc -> acc
        end)

      {message || "No message", opts}
    end

    defp create_commit(bash, mountpoint, git_state, message) do
      timestamp = DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()
      author = "Agent <agent@justbash> #{timestamp} +0000"

      parents =
        case git_state.parent_commit do
          nil -> []
          sha -> [sha]
        end

      commit =
        Commit.new(
          tree: git_state.tree,
          parents: parents,
          author: author,
          committer: author,
          message: message <> "\n"
        )

      {:ok, commit_sha, store} = ObjectStore.put(git_state.repo.object_store, commit)
      repo = %{git_state.repo | object_store: store}

      {:ok, ref_store} =
        Exgit.RefStore.write(repo.ref_store, "refs/heads/main", commit_sha, [])

      repo = %{repo | ref_store: ref_store}
      new_state = %{git_state | repo: repo, parent_commit: commit_sha}

      case update_mount_state(bash.fs, mountpoint, new_state) do
        {:ok, new_fs} ->
          short_sha = commit_sha |> Base.encode16(case: :lower) |> String.slice(0, 7)
          {Command.ok("[main #{short_sha}] #{message}\n"), %{bash | fs: new_fs}}

        {:error, reason} ->
          {Command.error("fatal: #{reason}\n", 128), bash}
      end
    end

    # --- push ---

    defp do_push(bash, _args) do
      case find_git_mount(bash) do
        {:ok, _mountpoint, %GitFS{url: nil}} ->
          {Command.error("fatal: no remote configured\n", 128), bash}

        {:ok, _mountpoint, %GitFS{} = git_state} ->
          push_to_remote(bash, git_state)

        {:error, msg} ->
          {Command.error(msg, 128), bash}
      end
    end

    defp push_to_remote(bash, git_state) do
      push_opts =
        case bash.git.credentials do
          nil -> []
          auth -> [auth: auth]
        end

      case Exgit.push(git_state.repo, git_state.url, push_opts) do
        {:ok, %{ref_results: results}} ->
          output =
            Enum.map_join(results, "", fn
              {ref, :ok} -> "   #{ref}\n"
              {ref, {:error, reason}} -> " ! #{ref} (#{reason})\n"
            end)

          {Command.ok("To #{git_state.url}\n#{output}"), bash}

        {:error, reason} ->
          {Command.error("fatal: #{format_error(reason)}\n", 128), bash}
      end
    end

    # --- helpers ---

    defp find_git_mount(bash) do
      case Fs.find_mount(bash.fs, bash.cwd) do
        {mp, GitFS, state} -> {:ok, mp, state}
        {_mp, mod, _state} -> {:error, "fatal: not a git repository (#{mod})\n"}
        nil -> {:error, "fatal: not a git repository\n"}
      end
    end

    defp update_mount_state(%Fs{mounts: mounts} = fs, mountpoint, new_state) do
      idx = Enum.find_index(mounts, fn {mp, _mod, _state} -> mp == mountpoint end)

      if idx do
        {mp, mod, _old} = Enum.at(mounts, idx)
        {:ok, %{fs | mounts: List.replace_at(mounts, idx, {mp, mod, new_state})}}
      else
        {:error, :enoent}
      end
    end

    defp format_error(:not_found), do: "repository not found"
    defp format_error({:http_error, code, msg}), do: "HTTP #{code}: #{msg}"
    defp format_error(reason) when is_binary(reason), do: reason
    defp format_error(reason), do: inspect(reason)
  end
end
