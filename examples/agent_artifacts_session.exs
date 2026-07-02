# An agent loop with durable, forkable memory — pure Elixir, top to bottom. The sandbox is
# JustBash (a bash interpreter on a virtual filesystem), the git client is exgit (clone, commit,
# and push implemented in Elixir — no git binary, no subprocess, no host filesystem), and the
# remote is a Cloudflare Artifacts repo, one per session.
#
# The session repo is cloned in memory and mounted into the sandbox at /work, so the agent's
# bash writes land directly in a git workspace. A checkpoint is Workspace.commit + Exgit.push —
# one commit per agent turn, labeled with the commands that ran. Re-running with the same session
# name clones the repo and resumes: filesystem, shell env/cwd, and conversation (stored under
# /work/.agent/, which the loop overwrites each turn). The repo is an ordinary git remote, so
# state flows both ways — clone it with a read-scoped token to audit the session, push with a
# write-scoped token and the next resume sees your files. Sessions fork like repos do.
#
# The durable transcript is complete, but only a recent window is sent to the model. Git trees
# cannot hold empty directories, so `mkdir` fails inside /work (exit 1) — files create their
# parents implicitly. Anything written outside /work is ephemeral.
#
# Requires CF_API_TOKEN (Artifacts Read+Edit), CF_ACCOUNT_ID, and ANTHROPIC_API_KEY.
#
#     source .env
#     elixir examples/agent_artifacts_session.exs my-session "write a haiku about zip files to haiku.txt"
#     elixir examples/agent_artifacts_session.exs my-session "append a second stanza"
#     elixir examples/agent_artifacts_session.exs my-session --fork my-experiment
#
Mix.install([
  {:just_bash, github: "elixir-ai-tools/just_bash"},
  {:exgit, github: "ivarvong/exgit"},
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

defmodule ArtifactsSession do
  @moduledoc false

  alias Exgit.CloudflareArtifacts
  alias Exgit.Workspace

  @anthropic_api "https://api.anthropic.com/v1/messages"
  @model System.get_env("ANTHROPIC_MODEL", "claude-sonnet-5")
  @branch "refs/heads/main"
  @transcript "/.agent/transcript.json"
  @shell_state "/.agent/shell.json"
  @author %{name: "agent", email: "agent@artifacts.invalid"}
  @token_ttl 86_400
  @max_turns 30
  @max_tool_output 20_000
  @max_context_messages 40

  @system_prompt """
  You are operating a persistent bash sandbox (JustBash: virtual filesystem, no network). Your
  durable workspace is /work — a git repo committed after every turn and restored when the
  session resumes, so files there survive across conversations; anything outside /work does not.
  Directories in /work are implicit: writing a file creates its parents, and mkdir fails. Use the
  bash tool to inspect state you don't remember — /work may contain earlier sessions' output, and
  only recent conversation is in your context.
  """

  @tools [
    %{
      name: "bash",
      description:
        "Run a bash command in the persistent session sandbox. " <>
          "Stdout and stderr are returned; state persists across calls.",
      input_schema: %{
        type: "object",
        properties: %{command: %{type: "string", description: "The bash command to run"}},
        required: ["command"]
      }
    }
  ]

  def client do
    CloudflareArtifacts.new(
      account_id: System.fetch_env!("CF_ACCOUNT_ID"),
      namespace: System.get_env("ARTIFACTS_NAMESPACE", "default"),
      api_token: System.fetch_env!("CF_API_TOKEN")
    )
  end

  def ensure_repo(client, name) do
    case CloudflareArtifacts.get_repo(client, name) do
      {:ok, repo} ->
        {:resumed, repo.remote}

      {:error, %Req.Response{status: 404}} ->
        {:ok, repo} = CloudflareArtifacts.create_repo(client, name: name, default_branch: "main")
        {:created, repo.remote}
    end
  end

  def transport(client, name, remote) do
    {:ok, token} =
      CloudflareArtifacts.create_token(client, repo: name, scope: "write", ttl: @token_ttl)

    Exgit.Transport.HTTP.new(remote, auth: Exgit.Credentials.Artifacts.auth(token.plaintext))
  end

  # Clone the session repo in memory, mount its workspace at /work, and rebuild the JustBash
  # value. A just-created repo has an unborn main branch: reads fall back to defaults and the
  # first checkpoint creates the branch.
  def restore(transport) do
    {:ok, repo} = Exgit.clone(transport)
    ws = Workspace.open(repo, @branch)

    {messages, ws} = read_json(ws, @transcript, [])
    {shell, ws} = read_json(ws, @shell_state, %{"env" => %{}, "cwd" => "/work"})

    bash =
      JustBash.new(env: shell["env"], cwd: shell["cwd"])
      |> JustBash.mount("/work", ws)

    {bash, messages}
  end

  defp read_json(ws, path, default) do
    case Workspace.read(ws, path) do
      {:ok, content, ws} -> {Jason.decode!(content), ws}
      {:error, _} -> {default, ws}
    end
  end

  # The workspace holding the agent's writes lives inside the mount table; pull it out, record
  # loop state, commit, push, and mount the committed workspace back so the next turn builds on
  # the new base.
  def checkpoint(bash, messages, transport, label) do
    {"/work", ws} = bash.fs |> VFS.mounts() |> List.keyfind("/work", 0)

    {:ok, ws} = Workspace.write(ws, @transcript, Jason.encode!(messages, pretty: true))
    {:ok, ws} = Workspace.write(ws, @shell_state, Jason.encode!(%{env: bash.env, cwd: bash.cwd}))

    {:ok, _sha, ws} =
      Workspace.commit(ws, message: label, author: @author, update_ref: @branch)

    case Exgit.push(ws.repo, transport, refspecs: [@branch]) do
      {:ok, %{ref_results: results}} ->
        unless Enum.all?(results, &match?({_ref, :ok}, &1)) do
          raise "push rejected (session advanced on the remote? concurrent run?): " <>
                  inspect(results)
        end

      {:error, reason} ->
        raise "push failed: #{inspect(reason)}"
    end

    bash |> JustBash.umount("/work") |> JustBash.mount("/work", ws)
  end

  def fork(client, name, new_name) do
    {:ok, repo} = CloudflareArtifacts.fork_repo(client, name, name: new_name)
    repo
  end

  def run(bash, messages, transport, turn \\ 1)

  def run(_bash, _messages, _transport, turn) when turn > @max_turns do
    raise "agent did not finish within #{@max_turns} turns"
  end

  def run(bash, messages, transport, turn) do
    response = claude!(messages)
    content = response["content"]
    messages = messages ++ [%{"role" => "assistant", "content" => content}]

    for %{"type" => "text", "text" => text} <- content, do: IO.puts("\n#{text}")

    case response["stop_reason"] do
      "tool_use" ->
        {results, bash} =
          content
          |> Enum.filter(&(&1["type"] == "tool_use"))
          |> Enum.map_reduce(bash, &execute_tool/2)

        messages = messages ++ [%{"role" => "user", "content" => results}]
        commands = for %{"type" => "tool_use", "input" => %{"command" => c}} <- content, do: c
        bash = checkpoint(bash, messages, transport, label(turn, Enum.join(commands, " && ")))
        run(bash, messages, transport, turn + 1)

      stop_reason ->
        bash = checkpoint(bash, messages, transport, "turn #{turn}: assistant (#{stop_reason})")
        {bash, messages}
    end
  end

  defp label(turn, commands) do
    subject = commands |> String.replace(~r/\s+/, " ") |> String.slice(0, 200)
    "turn #{turn}: #{subject}"
  end

  defp execute_tool(%{"id" => id, "input" => %{"command" => command}}, bash) do
    IO.puts("\n$ #{command}")
    {result, bash} = JustBash.exec(bash, command)
    output = tool_output(result)
    IO.write(output |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1)))
    IO.puts("")

    block = %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => output,
      "is_error" => result.exit_code != 0
    }

    {block, bash}
  end

  defp tool_output(%{stdout: stdout, stderr: stderr, exit_code: exit_code}) do
    [
      stdout,
      if(stderr != "", do: "[stderr] " <> stderr),
      if(exit_code != 0, do: "(exit #{exit_code})")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> truncate(@max_tool_output)
    |> scrub_utf8()
    |> case do
      "" -> "(no output)"
      out -> out
    end
  end

  defp truncate(bin, max) when byte_size(bin) <= max, do: bin
  defp truncate(bin, max), do: binary_part(bin, 0, max) <> "\n…(truncated)"

  # Sandbox commands can emit arbitrary bytes, and truncation can split a codepoint; both must
  # become valid UTF-8 before Jason and the Anthropic API see them.
  defp scrub_utf8(bin) do
    case :unicode.characters_to_binary(bin) do
      valid when is_binary(valid) -> valid
      {:error, good, <<_bad, rest::binary>>} -> good <> "�" <> scrub_utf8(rest)
      {:incomplete, good, _rest} -> good <> "�"
    end
  end

  defp claude!(messages) do
    response =
      Req.post!(@anthropic_api,
        headers: [
          {"x-api-key", System.fetch_env!("ANTHROPIC_API_KEY")},
          {"anthropic-version", "2023-06-01"}
        ],
        json: %{
          model: @model,
          max_tokens: 8192,
          system: @system_prompt,
          tools: @tools,
          messages: window(messages)
        },
        receive_timeout: 300_000
      )

    case response do
      %{status: 200, body: body} -> body
      %{status: status, body: body} -> raise "Anthropic API error (#{status}): #{inspect(body)}"
    end
  end

  # The durable transcript keeps everything; the model sees a recent window. Cut only at a user
  # prompt (plain string content) so tool_use/tool_result pairs stay intact. A single task longer
  # than the window is sent whole.
  defp window(messages) when length(messages) <= @max_context_messages, do: messages

  defp window(messages) do
    total = length(messages)

    cut =
      messages
      |> Enum.with_index()
      |> Enum.find(fn {message, index} ->
        total - index <= @max_context_messages and
          message["role"] == "user" and is_binary(message["content"])
      end)

    case cut do
      {_message, index} -> Enum.drop(messages, index)
      nil -> messages
    end
  end
end

case System.argv() do
  [session, "--fork", new_name] ->
    repo = ArtifactsSession.fork(ArtifactsSession.client(), session, new_name)
    IO.puts("== forked #{inspect(session)} -> #{inspect(new_name)}\n== remote: #{repo.remote}")

  [session, prompt] ->
    client = ArtifactsSession.client()
    {status, remote} = ArtifactsSession.ensure_repo(client, session)
    IO.puts("== #{status} session #{inspect(session)}\n== remote: #{remote}")

    transport = ArtifactsSession.transport(client, session, remote)
    {bash, messages} = ArtifactsSession.restore(transport)
    IO.puts("== restored #{length(messages)} transcript messages")

    messages = messages ++ [%{"role" => "user", "content" => prompt}]
    {_bash, _messages} = ArtifactsSession.run(bash, messages, transport, 1)

    IO.puts("""

    == session checkpointed to Artifacts
       resume:  elixir examples/agent_artifacts_session.exs #{session} "<next prompt>"
       fork:    elixir examples/agent_artifacts_session.exs #{session} --fork <new-session>
       inspect: git -c http.extraHeader="Authorization: Bearer <read token>" clone #{remote}
    """)

  _ ->
    raise "usage: elixir examples/agent_artifacts_session.exs <session-name> (\"<prompt>\" | --fork <new-session>)"
end
