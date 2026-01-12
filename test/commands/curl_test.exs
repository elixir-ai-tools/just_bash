defmodule JustBash.Commands.CurlTest do
  use ExUnit.Case, async: true

  describe "curl command" do
    test "curl without network enabled returns error" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "curl https://example.com")
      assert result.exit_code == 1
      assert result.stderr =~ "network access is disabled"
    end

    test "curl with network enabled can make requests" do
      bash = JustBash.new(network: %{enabled: true})
      {result, _} = JustBash.exec(bash, "curl -s https://httpbin.org/get")
      assert result.exit_code == 0
      assert result.stdout =~ "httpbin.org"
    end

    test "curl respects allow_list" do
      bash = JustBash.new(network: %{enabled: true, allow_list: ["api.github.com"]})
      {result, _} = JustBash.exec(bash, "curl https://httpbin.org/get")
      assert result.exit_code == 1
      assert result.stderr =~ "not allowed"
    end

    test "curl allow_list with wildcard" do
      bash = JustBash.new(network: %{enabled: true, allow_list: ["*.org"]})
      {result, _} = JustBash.exec(bash, "curl -s https://httpbin.org/get")
      assert result.exit_code == 0
    end

    test "curl --help shows usage" do
      bash = JustBash.new()
      {result, _} = JustBash.exec(bash, "curl --help")
      assert result.exit_code == 0
      assert result.stdout =~ "transfer data"
      assert result.stdout =~ "-X, --request"
    end

    test "curl without URL returns error" do
      bash = JustBash.new(network: %{enabled: true})
      {result, _} = JustBash.exec(bash, "curl")
      assert result.exit_code == 1
      assert result.stderr =~ "no URL"
    end

    test "curl -I shows headers only" do
      bash = JustBash.new(network: %{enabled: true})
      {result, _} = JustBash.exec(bash, "curl -s -I https://httpbin.org/get")
      assert result.exit_code == 0
      assert result.stdout =~ "HTTP/"
    end

    test "curl -o writes to file" do
      bash = JustBash.new(network: %{enabled: true})
      {result, new_bash} = JustBash.exec(bash, "curl -s -o /tmp/out.txt https://httpbin.org/get")
      assert result.exit_code == 0

      {read_result, _} = JustBash.exec(new_bash, "cat /tmp/out.txt")
      assert read_result.stdout =~ "httpbin.org"
    end

    test "curl POST with data" do
      bash = JustBash.new(network: %{enabled: true})

      {result, _} =
        JustBash.exec(
          bash,
          ~s[curl -s -X POST -d '{"test":1}' -H "Content-Type: application/json" https://httpbin.org/post]
        )

      assert result.exit_code == 0
      assert result.stdout =~ "test"
    end

    test "curl follows redirects with -L" do
      bash = JustBash.new(network: %{enabled: true})
      {result, _} = JustBash.exec(bash, "curl -s -L https://httpbin.org/redirect/1")
      assert result.exit_code == 0
      assert result.stdout =~ "url"
    end
  end
end
