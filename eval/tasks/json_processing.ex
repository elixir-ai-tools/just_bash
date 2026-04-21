defmodule JustBash.Eval.Tasks.JsonProcessing do
  @behaviour JustBash.Eval.Task

  @impl true
  def tasks do
    [
      jq_transform(),
      jq_api_response(),
      csv_to_json(),
      json_schema_validator(),
      package_inventory()
    ]
  end

  defp jq_transform do
    %{
      name: "jq_transform",
      description: """
      You have a JSON file at /data/users.json containing an array of user objects,
      each with "name", "email", and "age" fields. Use jq to:
      1. Filter to users aged 30 or older
      2. Transform each to have only "name" and "email"
      3. Sort by name
      4. Write the result to /output/senior_users.json
      """,
      files: %{
        "/data/users.json" =>
          Jason.encode!([
            %{name: "Charlie", email: "charlie@example.com", age: 35},
            %{name: "Alice", email: "alice@example.com", age: 28},
            %{name: "Bob", email: "bob@example.com", age: 42},
            %{name: "Diana", email: "diana@example.com", age: 31},
            %{name: "Eve", email: "eve@example.com", age: 22}
          ])
      },
      validators: [
        {:command_used, "jq"},
        {:tool_call_count, :max, 6},
        {:file_contains, "/output/senior_users.json",
         [
           {:json,
            fn data ->
              cond do
                not is_list(data) ->
                  {:error, "expected array"}

                length(data) != 3 ->
                  {:error, "expected 3 users, got #{length(data)}"}

                Enum.any?(data, &Map.has_key?(&1, "age")) ->
                  {:error, "age field should be removed"}

                Enum.map(data, & &1["name"]) != ["Bob", "Charlie", "Diana"] ->
                  {:error, "wrong names or order"}

                true ->
                  :ok
              end
            end}
         ]},
        {:llm_judge,
         "Did the agent accomplish the task by using jq to filter users aged 30+, keep only name/email, and sort by name? Ignore missing output in tool results — focus on whether the commands used were correct."}
      ]
    }
  end

  defp jq_api_response do
    %{
      name: "jq_api_response",
      description: """
      You have a JSON API response at /data/api_response.json. It contains a nested structure
      with a "data" array of order objects. Each order has "id", "customer" (object with "name"),
      "items" (array of objects with "product" and "price"), and "status".

      Create /output/orders.csv with columns: order_id,customer_name,total,status
      where "total" is the sum of all item prices for that order. Include a header row.
      Sort by order_id ascending.
      """,
      files: %{
        "/data/api_response.json" =>
          Jason.encode!(%{
            data: [
              %{
                id: 1003,
                customer: %{name: "Charlie"},
                items: [%{product: "Mouse", price: 25}, %{product: "Keyboard", price: 75}],
                status: "shipped"
              },
              %{
                id: 1001,
                customer: %{name: "Alice"},
                items: [%{product: "Laptop", price: 999}, %{product: "Case", price: 49}],
                status: "delivered"
              },
              %{
                id: 1002,
                customer: %{name: "Bob"},
                items: [%{product: "Monitor", price: 300}],
                status: "pending"
              }
            ],
            meta: %{total: 3, page: 1}
          })
      },
      validators: [
        {:command_used, "jq"},
        {:file_contains, "/output/orders.csv",
         [
           {:line_count, 4},
           {:regex, ~r/order_id/},
           {:regex, ~r/1001.*Alice.*1048.*delivered/},
           {:regex, ~r/1002.*Bob.*300.*pending/},
           {:regex, ~r/1003.*Charlie.*100.*shipped/}
         ]},
        {:llm_judge,
         "Did the agent correctly use jq to flatten the nested JSON structure and compute totals? Was the CSV properly formatted?"}
      ]
    }
  end

  defp csv_to_json do
    csv_data =
      Enum.join(
        [
          "name,department,salary",
          "Alice,Engineering,95000",
          "Bob,Marketing,72000",
          "Charlie,Engineering,88000",
          "Diana,Marketing,76000",
          "Eve,Engineering,102000"
        ],
        "\n"
      ) <> "\n"

    %{
      name: "csv_to_json",
      description: """
      You have a CSV file at /data/employees.csv with columns: name, department, salary.
      Convert it to a JSON file at /output/employees.json that is an array of objects,
      each with "name" (string), "department" (string), and "salary" (number, not string).
      Skip the header row. Sort by salary descending.

      Use awk or sed to parse the CSV and construct the JSON. You can also use jq to
      format or validate the output.
      """,
      files: %{"/data/employees.csv" => csv_data},
      validators: [
        {:file_contains, "/output/employees.json",
         [
           {:json,
            fn data ->
              cond do
                not is_list(data) ->
                  {:error, "expected array"}

                length(data) != 5 ->
                  {:error, "expected 5 employees, got #{length(data)}"}

                not Enum.all?(data, &is_number(&1["salary"])) ->
                  {:error, "salary should be a number"}

                hd(data)["name"] != "Eve" ->
                  {:error, "first employee should be Eve (highest salary)"}

                List.last(data)["name"] != "Bob" ->
                  {:error, "last employee should be Bob (lowest salary)"}

                true ->
                  :ok
              end
            end}
         ]}
      ]
    }
  end

  defp json_schema_validator do
    valid1 = Jason.encode!(%{name: "Alice", age: 30, email: "alice@example.com"})
    valid2 = Jason.encode!(%{name: "Bob", age: 25, email: "bob@example.com"})
    invalid1 = Jason.encode!(%{name: "Charlie", email: "charlie@example.com"})
    invalid2 = Jason.encode!(%{name: "", age: -5, email: "not-an-email"})
    invalid3 = Jason.encode!(%{name: "Diana", age: "thirty", email: "diana@example.com"})

    data =
      Enum.join([valid1, valid2, invalid1, invalid2, invalid3], "\n") <> "\n"

    %{
      name: "json_schema_validator",
      description: """
      You have a file at /data/records.jsonl (one JSON object per line). Each record
      should have: "name" (non-empty string), "age" (positive number), and
      "email" (string containing "@").

      Validate each line and write results:
      - /output/valid.jsonl — lines that pass all checks (one JSON per line)
      - /output/invalid.jsonl — lines that fail any check (one JSON per line)
      - /output/summary.txt — "Valid: N, Invalid: M"

      Use jq to parse and validate each line.
      """,
      files: %{"/data/records.jsonl" => data},
      validators: [
        {:command_used, "jq"},
        {:file_contains, "/output/summary.txt", [{:regex, ~r/Valid:\s*2.*Invalid:\s*3/}]},
        {:custom, "valid_count",
         fn %{bash: bash} ->
           case JustBash.Fs.read_file(bash.fs, "/output/valid.jsonl") do
             {:ok, content} ->
               lines =
                 content
                 |> String.trim()
                 |> String.split("\n")
                 |> Enum.reject(&(&1 == ""))

               if length(lines) == 2,
                 do: :ok,
                 else: {:error, "expected 2 valid records, got #{length(lines)}"}

             {:error, _} ->
               {:error, "file not found"}
           end
         end},
        {:custom, "invalid_count",
         fn %{bash: bash} ->
           case JustBash.Fs.read_file(bash.fs, "/output/invalid.jsonl") do
             {:ok, content} ->
               lines =
                 content
                 |> String.trim()
                 |> String.split("\n")
                 |> Enum.reject(&(&1 == ""))

               if length(lines) == 3,
                 do: :ok,
                 else: {:error, "expected 3 invalid records, got #{length(lines)}"}

             {:error, _} ->
               {:error, "file not found"}
           end
         end}
      ]
    }
  end

  defp package_inventory do
    pkg1 =
      Jason.encode!(%{
        name: "web-app",
        version: "2.1.0",
        dependencies: %{
          "express" => "^4.18.0",
          "lodash" => "^4.17.21",
          "axios" => "^1.4.0"
        }
      })

    pkg2 =
      Jason.encode!(%{
        name: "api-server",
        version: "1.5.3",
        dependencies: %{
          "express" => "^4.17.0",
          "mongoose" => "^7.0.0",
          "axios" => "^1.3.0"
        }
      })

    pkg3 =
      Jason.encode!(%{
        name: "cli-tool",
        version: "0.9.1",
        dependencies: %{
          "commander" => "^11.0.0",
          "chalk" => "^5.3.0",
          "lodash" => "^4.17.20"
        }
      })

    %{
      name: "package_inventory",
      description: """
      You have three package.json files at /projects/web-app/package.json,
      /projects/api-server/package.json, and /projects/cli-tool/package.json.

      Create a dependency inventory at /output/inventory.json with:
      {
        "total_dependencies": <number of unique dependency names across all projects>,
        "shared_dependencies": [<list of dependency names that appear in 2+ projects, sorted>],
        "projects": {
          "<project-name>": {"version": "...", "dep_count": N},
          ...
        }
      }

      Use jq to parse the JSON files and construct the output.
      """,
      files: %{
        "/projects/web-app/package.json" => pkg1,
        "/projects/api-server/package.json" => pkg2,
        "/projects/cli-tool/package.json" => pkg3
      },
      validators: [
        {:command_used, "jq"},
        {:file_contains, "/output/inventory.json",
         [
           {:json,
            fn data ->
              cond do
                data["total_dependencies"] != 6 ->
                  {:error,
                   "total_dependencies should be 6, got #{inspect(data["total_dependencies"])}"}

                not is_list(data["shared_dependencies"]) ->
                  {:error, "shared_dependencies should be an array"}

                Enum.sort(data["shared_dependencies"]) != ["axios", "express", "lodash"] ->
                  {:error,
                   "shared_dependencies should be [axios, express, lodash], got #{inspect(data["shared_dependencies"])}"}

                not is_map(data["projects"]) ->
                  {:error, "projects should be an object"}

                data["projects"]["web-app"]["dep_count"] != 3 ->
                  {:error, "web-app dep_count should be 3"}

                true ->
                  :ok
              end
            end}
         ]}
      ]
    }
  end
end
