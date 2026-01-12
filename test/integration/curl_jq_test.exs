defmodule JustBash.Integration.CurlJqTest do
  @moduledoc """
  Integration tests for curl | jq pipelines with injected HTTP client.
  """
  use ExUnit.Case, async: true

  defmodule TestHttpClient do
    @moduledoc """
    Test HTTP client that returns canned responses based on URL.
    """
    @behaviour JustBash.HttpClient

    @impl true
    def request(%{url: url} = req) do
      responses = Process.get(:http_responses, %{})

      case Map.get(responses, url) do
        nil ->
          {:error, %{reason: "no response configured for #{url}"}}

        response when is_function(response) ->
          {:ok, response.(req)}

        response when is_map(response) ->
          {:ok,
           %{
             status: Map.get(response, :status, 200),
             headers: Map.get(response, :headers, []),
             body: Map.get(response, :body, "")
           }}
      end
    end
  end

  defp bash_with_responses(responses) do
    Process.put(:http_responses, responses)
    JustBash.new(network: %{enabled: true}, http_client: TestHttpClient)
  end

  defp bash_with_responses_and_files(responses, files) do
    Process.put(:http_responses, responses)
    JustBash.new(network: %{enabled: true}, http_client: TestHttpClient, files: files)
  end

  describe "curl | jq basic pipelines" do
    test "fetch JSON and extract field" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/user" => %{
            status: 200,
            body: ~s({"id": 123, "name": "Alice", "email": "alice@example.com"})
          }
        })

      {result, _} = JustBash.exec(bash, "curl -s https://api.example.com/user | jq '.name'")

      assert result.exit_code == 0
      assert result.stdout == ~s("Alice"\n)
    end

    test "fetch JSON and extract multiple fields" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/user" => %{
            status: 200,
            body: ~s({"id": 123, "name": "Alice", "email": "alice@example.com"})
          }
        })

      {result, _} =
        JustBash.exec(
          bash,
          "curl -s https://api.example.com/user | jq '{name: .name, email: .email}'"
        )

      assert result.exit_code == 0
      decoded = Jason.decode!(String.trim(result.stdout))
      assert decoded == %{"name" => "Alice", "email" => "alice@example.com"}
    end

    test "fetch JSON array and count filtered items" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/users" => %{
            status: 200,
            body:
              Jason.encode!([
                %{id: 1, name: "Alice", active: true},
                %{id: 2, name: "Bob", active: false},
                %{id: 3, name: "Charlie", active: true}
              ])
          }
        })

      cmd = ~S"""
      curl -s https://api.example.com/users | jq '[.[] | select(.active)] | length'
      """

      {result, _} = JustBash.exec(bash, cmd)

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "2"
    end

    test "fetch JSON and use raw output" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/config" => %{
            status: 200,
            body: ~s({"version": "1.2.3", "env": "production"})
          }
        })

      {result, _} =
        JustBash.exec(bash, "curl -s https://api.example.com/config | jq -r '.version'")

      assert result.exit_code == 0
      assert result.stdout == "1.2.3\n"
    end
  end

  describe "curl | jq with POST requests" do
    test "POST JSON and process response" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/items" => fn req ->
            body = Jason.decode!(req.body)

            %{
              status: 201,
              headers: [],
              body: Jason.encode!(%{id: 999, name: body["name"], created: true})
            }
          end
        })

      cmd = ~S"""
      curl -s -X POST -d '{"name":"test"}' -H "Content-Type: application/json" https://api.example.com/items | jq '.id'
      """

      {result, _} = JustBash.exec(bash, cmd)

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "999"
    end
  end

  describe "curl | jq complex pipelines" do
    test "extract nested data" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/repo" => %{
            status: 200,
            body:
              Jason.encode!(%{
                repository: %{
                  name: "awesome-project",
                  owner: %{login: "alice", id: 42},
                  stats: %{stars: 1000, forks: 250}
                }
              })
          }
        })

      {result, _} =
        JustBash.exec(bash, "curl -s https://api.example.com/repo | jq '.repository.stats.stars'")

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "1000"
    end

    test "transform array of objects" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/commits" => %{
            status: 200,
            body:
              Jason.encode!([
                %{sha: "abc123", message: "Fix bug", author: "alice"},
                %{sha: "def456", message: "Add feature", author: "bob"},
                %{sha: "ghi789", message: "Update docs", author: "alice"}
              ])
          }
        })

      cmd = ~S"""
      curl -s https://api.example.com/commits | jq -r '.[].sha'
      """

      {result, _} = JustBash.exec(bash, cmd)

      assert result.exit_code == 0
      assert result.stdout == "abc123\ndef456\nghi789\n"
    end

    test "filter array with select" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/products" => %{
            status: 200,
            body:
              Jason.encode!([
                %{name: "Widget", price: 10, in_stock: true},
                %{name: "Gadget", price: 25, in_stock: false},
                %{name: "Gizmo", price: 15, in_stock: true}
              ])
          }
        })

      cmd = ~S"""
      curl -s https://api.example.com/products | jq '[.[] | select(.in_stock)]'
      """

      {result, _} = JustBash.exec(bash, cmd)

      assert result.exit_code == 0
      decoded = Jason.decode!(String.trim(result.stdout))
      assert length(decoded) == 2
      assert Enum.all?(decoded, & &1["in_stock"])
    end

    test "aggregate data with add" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/orders" => %{
            status: 200,
            body:
              Jason.encode!([
                %{id: 1, total: 100},
                %{id: 2, total: 250},
                %{id: 3, total: 75}
              ])
          }
        })

      cmd = ~S"""
      curl -s https://api.example.com/orders | jq '[.[].total] | add'
      """

      {result, _} = JustBash.exec(bash, cmd)

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "425"
    end
  end

  describe "curl | jq with variables and scripting" do
    test "store curl output in variable and process" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/status" => %{
            status: 200,
            body: ~s({"status": "healthy", "uptime": 99.9})
          }
        })

      {result, _} =
        JustBash.exec(bash, """
        response=$(curl -s https://api.example.com/status)
        echo "$response" | jq -r '.status'
        """)

      assert result.exit_code == 0
      assert result.stdout == "healthy\n"
    end

    test "conditional based on jq output" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/health" => %{
            status: 200,
            body: ~s({"healthy": true, "services": 5})
          }
        })

      {result, _} =
        JustBash.exec(bash, """
        healthy=$(curl -s https://api.example.com/health | jq '.healthy')
        if [ "$healthy" = "true" ]; then
          echo "System is healthy"
        else
          echo "System is unhealthy"
        fi
        """)

      assert result.exit_code == 0
      assert result.stdout == "System is healthy\n"
    end

    test "loop over JSON array items" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/tags" => %{
            status: 200,
            body: ~s(["v1.0", "v1.1", "v2.0"])
          }
        })

      {result, _} =
        JustBash.exec(bash, ~S"""
        for tag in $(curl -s https://api.example.com/tags | jq -r '.[]'); do
          echo "Tag: $tag"
        done
        """)

      assert result.exit_code == 0
      assert result.stdout == "Tag: v1.0\nTag: v1.1\nTag: v2.0\n"
    end
  end

  describe "curl | jq error handling" do
    test "curl without network enabled fails" do
      bash = JustBash.new(network: %{enabled: false})
      {result, _} = JustBash.exec(bash, "curl -s https://api.example.com/data")

      assert result.exit_code == 1
      assert result.stderr =~ "network access is disabled"
    end

    test "jq handles invalid JSON gracefully" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/broken" => %{
            status: 200,
            body: "not valid json"
          }
        })

      {result, _} = JustBash.exec(bash, "curl -s https://api.example.com/broken | jq '.'")

      assert result.exit_code == 1
      assert result.stderr =~ "parse error"
    end

    test "HTTP error status with JSON body" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/missing" => %{
            status: 404,
            body: ~s({"error": "Not found", "code": 404})
          }
        })

      {result, _} =
        JustBash.exec(bash, "curl -s https://api.example.com/missing | jq -r '.error'")

      assert result.exit_code == 0
      assert result.stdout == "Not found\n"
    end
  end

  describe "curl | jq with output to file" do
    test "save processed JSON to file" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/data" => %{
            status: 200,
            body: ~s({"items": [1, 2, 3], "total": 3})
          }
        })

      {_, bash} =
        JustBash.exec(
          bash,
          "curl -s https://api.example.com/data | jq '.items' > /tmp/items.json"
        )

      {result, _} = JustBash.exec(bash, "cat /tmp/items.json")

      assert result.exit_code == 0
      decoded = Jason.decode!(String.trim(result.stdout))
      assert decoded == [1, 2, 3]
    end

    test "append processed JSON to file" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/page1" => %{status: 200, body: ~s({"page": 1})},
          "https://api.example.com/page2" => %{status: 200, body: ~s({"page": 2})}
        })

      {_, bash} =
        JustBash.exec(
          bash,
          "curl -s https://api.example.com/page1 | jq -c '.' > /tmp/pages.jsonl"
        )

      {_, bash} =
        JustBash.exec(
          bash,
          "curl -s https://api.example.com/page2 | jq -c '.' >> /tmp/pages.jsonl"
        )

      {result, _} = JustBash.exec(bash, "cat /tmp/pages.jsonl")

      assert result.exit_code == 0
      lines = String.split(String.trim(result.stdout), "\n")
      assert length(lines) == 2
      assert Jason.decode!(Enum.at(lines, 0)) == %{"page" => 1}
      assert Jason.decode!(Enum.at(lines, 1)) == %{"page" => 2}
    end
  end

  describe "realistic API scenarios" do
    test "GitHub-like API: list repositories and find top starred" do
      bash =
        bash_with_responses(%{
          "https://api.github.mock/users/alice/repos" => %{
            status: 200,
            body:
              Jason.encode!([
                %{name: "project-a", stars: 100, language: "Elixir"},
                %{name: "project-b", stars: 50, language: "JavaScript"},
                %{name: "project-c", stars: 200, language: "Elixir"}
              ])
          }
        })

      cmd = ~S"""
      curl -s https://api.github.mock/users/alice/repos | jq '[.[] | select(.language == "Elixir")] | sort_by(.stars) | reverse | .[0].name'
      """

      {result, _} = JustBash.exec(bash, cmd)

      assert result.exit_code == 0
      assert String.trim(result.stdout) == ~s("project-c")
    end

    test "Weather API: extract condition" do
      bash =
        bash_with_responses(%{
          "https://api.weather.mock/current?city=london" => %{
            status: 200,
            body:
              Jason.encode!(%{
                city: "London",
                current: %{temp_c: 15.5, humidity: 72, condition: "Cloudy"},
                forecast: [%{day: "Mon", high: 18}, %{day: "Tue", high: 20}]
              })
          }
        })

      {result, _} =
        JustBash.exec(bash, ~S"""
        curl -s "https://api.weather.mock/current?city=london" | jq -r '.current.condition'
        """)

      assert result.exit_code == 0
      assert result.stdout == "Cloudy\n"
    end

    test "Paginated API: collect items from multiple pages" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/items?page=1" => %{
            status: 200,
            body: Jason.encode!(%{items: ["a", "b"], next_page: 2})
          },
          "https://api.example.com/items?page=2" => %{
            status: 200,
            body: Jason.encode!(%{items: ["c", "d"], next_page: nil})
          }
        })

      {result, _} =
        JustBash.exec(bash, ~S"""
        page1=$(curl -s "https://api.example.com/items?page=1" | jq -r '.items[]')
        page2=$(curl -s "https://api.example.com/items?page=2" | jq -r '.items[]')
        echo "$page1"
        echo "$page2"
        """)

      assert result.exit_code == 0
      assert result.stdout == "a\nb\nc\nd\n"
    end

    test "REST API: create and verify resource" do
      bash =
        bash_with_responses(%{
          "https://api.example.com/users" => fn req ->
            body = Jason.decode!(req.body)

            %{
              status: 201,
              headers: [],
              body: Jason.encode!(%{id: 42, name: body["name"], created_at: "2024-01-15"})
            }
          end,
          "https://api.example.com/users/42" => %{
            status: 200,
            body: Jason.encode!(%{id: 42, name: "NewUser", created_at: "2024-01-15"})
          }
        })

      {result, _} =
        JustBash.exec(bash, ~S"""
        id=$(curl -s -X POST -d '{"name":"NewUser"}' -H "Content-Type: application/json" https://api.example.com/users | jq '.id')
        curl -s "https://api.example.com/users/$id" | jq -r '.name'
        """)

      assert result.exit_code == 0
      assert result.stdout == "NewUser\n"
    end
  end

  describe "authenticated requests with bearer token from file" do
    test "load token from file and make authenticated GET request" do
      bash =
        bash_with_responses_and_files(
          %{
            "https://api.example.com/me" => fn req ->
              auth = Map.get(req.headers, "authorization", "")

              if auth == "Bearer secret-token-12345" do
                %{status: 200, headers: [], body: Jason.encode!(%{id: 1, name: "Alice"})}
              else
                %{status: 401, headers: [], body: Jason.encode!(%{error: "Unauthorized"})}
              end
            end
          },
          %{"/home/user/.token" => "secret-token-12345"}
        )

      {result, _} =
        JustBash.exec(bash, ~S"""
        TOKEN=$(cat ~/.token)
        curl -s -H "Authorization: Bearer $TOKEN" https://api.example.com/me | jq -r '.name'
        """)

      assert result.exit_code == 0
      assert result.stdout == "Alice\n"
    end

    test "load token and make authenticated POST request" do
      bash =
        bash_with_responses_and_files(
          %{
            "https://api.example.com/posts" => fn req ->
              auth = Map.get(req.headers, "authorization", "")

              if auth == "Bearer my-api-key" do
                body = Jason.decode!(req.body)
                %{status: 201, headers: [], body: Jason.encode!(%{id: 99, title: body["title"]})}
              else
                %{status: 401, headers: [], body: Jason.encode!(%{error: "Unauthorized"})}
              end
            end
          },
          %{"/etc/api_token" => "my-api-key"}
        )

      {result, _} =
        JustBash.exec(bash, ~S"""
        TOKEN=$(cat /etc/api_token)
        curl -s -X POST \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -d '{"title":"Hello World"}' \
          https://api.example.com/posts | jq '.id'
        """)

      assert result.exit_code == 0
      assert String.trim(result.stdout) == "99"
    end

    test "token file with trailing newline is trimmed by command substitution" do
      bash =
        bash_with_responses_and_files(
          %{
            "https://api.example.com/data" => fn req ->
              auth = Map.get(req.headers, "authorization", "")

              if auth == "Bearer token-no-newline" do
                %{status: 200, headers: [], body: Jason.encode!(%{data: "secret"})}
              else
                %{
                  status: 401,
                  headers: [],
                  body: Jason.encode!(%{error: "bad token: #{inspect(auth)}"})
                }
              end
            end
          },
          %{"/tmp/token.txt" => "token-no-newline\n"}
        )

      {result, _} =
        JustBash.exec(bash, ~S"""
        TOKEN=$(cat /tmp/token.txt)
        curl -s -H "Authorization: Bearer $TOKEN" https://api.example.com/data | jq -r '.data'
        """)

      assert result.exit_code == 0
      assert result.stdout == "secret\n"
    end

    test "missing token file causes error" do
      bash = bash_with_responses(%{})

      {result, _} = JustBash.exec(bash, "cat /nonexistent/token")

      assert result.exit_code == 1
      assert result.stderr =~ "No such file"
    end

    test "use environment variable for token path" do
      bash =
        bash_with_responses_and_files(
          %{
            "https://api.example.com/secure" => fn req ->
              auth = Map.get(req.headers, "authorization", "")

              if auth == "Bearer env-token-xyz" do
                %{status: 200, headers: [], body: Jason.encode!(%{status: "ok"})}
              else
                %{status: 401, headers: [], body: Jason.encode!(%{error: "Unauthorized"})}
              end
            end
          },
          %{"/secrets/prod.token" => "env-token-xyz"}
        )

      {result, _} =
        JustBash.exec(bash, ~S"""
        TOKEN_FILE=/secrets/prod.token
        TOKEN=$(cat "$TOKEN_FILE")
        curl -s -H "Authorization: Bearer $TOKEN" https://api.example.com/secure | jq -r '.status'
        """)

      assert result.exit_code == 0
      assert result.stdout == "ok\n"
    end

    test "refresh token workflow: read, use, update" do
      bash =
        bash_with_responses_and_files(
          %{
            "https://api.example.com/refresh" => fn req ->
              auth = Map.get(req.headers, "authorization", "")

              if auth == "Bearer old-refresh-token" do
                %{
                  status: 200,
                  headers: [],
                  body:
                    Jason.encode!(%{
                      access_token: "new-access-token",
                      refresh_token: "new-refresh-token"
                    })
                }
              else
                %{
                  status: 401,
                  headers: [],
                  body: Jason.encode!(%{error: "Invalid refresh token"})
                }
              end
            end,
            "https://api.example.com/protected" => fn req ->
              auth = Map.get(req.headers, "authorization", "")

              if auth == "Bearer new-access-token" do
                %{status: 200, headers: [], body: Jason.encode!(%{message: "Success!"})}
              else
                %{status: 401, headers: [], body: Jason.encode!(%{error: "Unauthorized"})}
              end
            end
          },
          %{"/tmp/refresh_token" => "old-refresh-token"}
        )

      {result, bash} =
        JustBash.exec(bash, ~S"""
        REFRESH_TOKEN=$(cat /tmp/refresh_token)
        RESPONSE=$(curl -s -X POST -H "Authorization: Bearer $REFRESH_TOKEN" https://api.example.com/refresh)
        ACCESS_TOKEN=$(echo "$RESPONSE" | jq -r '.access_token')
        NEW_REFRESH=$(echo "$RESPONSE" | jq -r '.refresh_token')
        echo "$NEW_REFRESH" > /tmp/refresh_token
        curl -s -H "Authorization: Bearer $ACCESS_TOKEN" https://api.example.com/protected | jq -r '.message'
        """)

      assert result.exit_code == 0
      assert result.stdout == "Success!\n"

      {read_result, _} = JustBash.exec(bash, "cat /tmp/refresh_token")
      assert String.trim(read_result.stdout) == "new-refresh-token"
    end

    test "multiple API calls with same token" do
      bash =
        bash_with_responses_and_files(
          %{
            "https://api.example.com/users" => fn req ->
              if Map.get(req.headers, "authorization") == "Bearer shared-token" do
                %{status: 200, headers: [], body: Jason.encode!([%{id: 1}, %{id: 2}])}
              else
                %{status: 401, headers: [], body: "{}"}
              end
            end,
            "https://api.example.com/posts" => fn req ->
              if Map.get(req.headers, "authorization") == "Bearer shared-token" do
                %{status: 200, headers: [], body: Jason.encode!([%{id: 10}, %{id: 20}])}
              else
                %{status: 401, headers: [], body: "{}"}
              end
            end
          },
          %{"/app/token" => "shared-token"}
        )

      {result, _} =
        JustBash.exec(bash, ~S"""
        TOKEN=$(cat /app/token)
        AUTH="Authorization: Bearer $TOKEN"

        user_count=$(curl -s -H "$AUTH" https://api.example.com/users | jq 'length')
        post_count=$(curl -s -H "$AUTH" https://api.example.com/posts | jq 'length')

        echo "users: $user_count, posts: $post_count"
        """)

      assert result.exit_code == 0
      assert result.stdout == "users: 2, posts: 2\n"
    end
  end
end
