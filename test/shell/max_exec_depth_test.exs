defmodule JustBash.Shell.MaxExecDepthTest do
  use ExUnit.Case, async: true

  describe "nested script execution" do
    test "source recursion is stopped at a configurable execution depth" do
      bash =
        JustBash.new(files: %{"/loop.sh" => "source /loop.sh\n"}, security: [max_exec_depth: 5])

      {result, _} = JustBash.exec(bash, "source /loop.sh")

      assert result.exit_code != 0
      assert result.stderr =~ "maximum execution depth exceeded"
    end
  end
end
