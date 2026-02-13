defmodule JustBash.Fs.ContentAdapterTest do
  use ExUnit.Case, async: true

  alias JustBash.Fs.ContentAdapter
  alias JustBash.Fs.Content.FunctionContent
  alias JustBash.Fs.Content.S3Content

  describe "BitString implementation" do
    test "resolve returns the binary as-is" do
      assert {:ok, "hello world"} = ContentAdapter.resolve("hello world")
    end

    test "size returns byte_size" do
      assert 11 = ContentAdapter.size("hello world")
      assert 0 = ContentAdapter.size("")
      assert 5 = ContentAdapter.size("hello")
    end
  end

  describe "FunctionContent implementation" do
    test "resolve calls a zero-arity anonymous function" do
      fc = FunctionContent.new(fn -> "generated content" end)
      assert {:ok, "generated content"} = ContentAdapter.resolve(fc)
    end

    test "resolve calls an MFA tuple" do
      fc = FunctionContent.new({String, :upcase, ["hello"]})
      assert {:ok, "HELLO"} = ContentAdapter.resolve(fc)
    end

    test "resolve returns error when function raises" do
      fc = FunctionContent.new(fn -> raise "boom" end)
      assert {:error, {:function_error, _}} = ContentAdapter.resolve(fc)
    end

    test "resolve returns error when MFA raises" do
      fc = FunctionContent.new({String, :upcase, [123]})
      assert {:error, {:function_error, _}} = ContentAdapter.resolve(fc)
    end

    test "resolve returns cached content without calling function again" do
      # Use a reference to track if function is called
      ref = make_ref()
      send(self(), {:call_count, 0})

      fc =
        FunctionContent.new(fn ->
          receive do
            {:call_count, n} -> send(self(), {:call_count, n + 1})
          after
            0 -> :ok
          end

          "call_#{inspect(ref)}"
        end)

      # First resolve calls function
      {:ok, content1} = ContentAdapter.resolve(fc)
      assert_received {:call_count, 1}

      # Materialize to cache
      {:ok, ^content1, cached_fc} = FunctionContent.materialize(fc)
      assert cached_fc.cached_content == content1

      # Second resolve on cached version doesn't call function
      {:ok, content2} = ContentAdapter.resolve(cached_fc)
      assert content2 == content1
      refute_received {:call_count, 2}
    end

    test "size returns nil when not materialized" do
      fc = FunctionContent.new(fn -> "hello" end)
      assert nil == ContentAdapter.size(fc)
    end

    test "size returns byte_size when materialized" do
      fc = FunctionContent.new(fn -> "hello world" end)
      {:ok, _content, cached_fc} = FunctionContent.materialize(fc)
      assert 11 == ContentAdapter.size(cached_fc)
    end

    test "materialize is idempotent" do
      fc = FunctionContent.new(fn -> "test" end)
      {:ok, content1, cached_fc1} = FunctionContent.materialize(fc)
      {:ok, content2, cached_fc2} = FunctionContent.materialize(cached_fc1)

      assert content1 == content2
      assert cached_fc1.cached_content == cached_fc2.cached_content
    end
  end

  describe "S3Content implementation" do
    defmodule MockS3Client do
      @behaviour JustBash.Fs.Content.S3Content

      @impl true
      def get_object("test-bucket", "success.txt"), do: {:ok, "s3 content"}
      def get_object("test-bucket", "error.txt"), do: {:error, :not_found}
    end

    test "resolve delegates to client" do
      s3 = S3Content.new(bucket: "test-bucket", key: "success.txt", client: MockS3Client)
      assert {:ok, "s3 content"} = ContentAdapter.resolve(s3)
    end

    test "resolve returns error when client fails" do
      s3 = S3Content.new(bucket: "test-bucket", key: "error.txt", client: MockS3Client)
      assert {:error, :not_found} = ContentAdapter.resolve(s3)
    end

    test "resolve returns cached content without calling client again" do
      s3 = S3Content.new(bucket: "test-bucket", key: "success.txt", client: MockS3Client)

      # First resolve calls client
      {:ok, content1} = ContentAdapter.resolve(s3)

      # Materialize to cache
      {:ok, ^content1, cached_s3} = S3Content.materialize(s3)
      assert cached_s3.cached_content == content1

      # Replace client with one that would error - cached version doesn't call it
      cached_s3_bad_client = %{cached_s3 | client: __MODULE__}
      {:ok, content2} = ContentAdapter.resolve(cached_s3_bad_client)
      assert content2 == content1
    end

    test "size returns nil when not materialized and no metadata size" do
      s3 = S3Content.new(bucket: "test-bucket", key: "success.txt", client: MockS3Client)
      assert nil == ContentAdapter.size(s3)
    end

    test "size returns metadata size when provided" do
      s3 =
        S3Content.new(
          bucket: "test-bucket",
          key: "success.txt",
          client: MockS3Client,
          size: 1024
        )

      assert 1024 == ContentAdapter.size(s3)
    end

    test "size returns byte_size when materialized" do
      s3 = S3Content.new(bucket: "test-bucket", key: "success.txt", client: MockS3Client)
      {:ok, _content, cached_s3} = S3Content.materialize(s3)
      assert 10 == ContentAdapter.size(cached_s3)
    end

    test "materialize updates size from fetched content" do
      s3 = S3Content.new(bucket: "test-bucket", key: "success.txt", client: MockS3Client)
      {:ok, content, cached_s3} = S3Content.materialize(s3)

      assert content == "s3 content"
      assert cached_s3.size == 10
    end
  end
end
