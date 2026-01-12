# JustBash Development Guidelines

## Non-Negotiable Rules

### 1. Test-First Bug Fixing
**ALWAYS write a failing test before fixing a bug.**
```
1. Discover bug
2. Write test that reproduces it (must FAIL)
3. Verify failure
4. Fix bug
5. Verify test passes
6. Full suite passes - no regressions
```

### 2. Zero Warnings
```bash
mix compile --warnings-as-errors
```
Fix all warnings before committing. No exceptions.

### 3. Trust Tests, Not Code
We do not trust the implementation. Tests are the only source of confidence. Write adversarial tests. Compare against real bash when possible.

---

## Idiomatic Elixir

### Let It Crash
Don't defensively code against every possible error. Let processes crash and be restarted. Use supervisors. Handle expected errors, crash on unexpected ones.

```elixir
# Good - crash on unexpected
def fetch!(key), do: Map.fetch!(data, key)

# Good - handle expected errors at boundaries
case parse_input(raw) do
  {:ok, parsed} -> process(parsed)
  {:error, :invalid_format} -> {:error, "Invalid input format"}
end
```

### Pattern Matching Everywhere
Pattern match in function heads, `case`, `with`, and assignments:

```elixir
# Function heads - preferred
def handle(%{type: :success, data: data}), do: {:ok, data}
def handle(%{type: :error, reason: reason}), do: {:error, reason}

# Destructure in assignments
%{name: name, age: age} = user
[head | tail] = list
{:ok, result} = must_succeed()
```

### Pipeline Orientation
Design functions to take the "subject" as first argument for pipeline compatibility:

```elixir
# Good - pipeable
def add_header(request, name, value)
def parse(string, opts \\ [])

request
|> add_header("Content-Type", "application/json")
|> add_header("Authorization", token)
|> send()

# Avoid - not pipeable
def add_header(name, value, request)
```

### Transform, Don't Mutate
Think in data transformations, not state mutations:

```elixir
# Good - transform
def process(state) do
  state
  |> validate()
  |> enrich()
  |> persist()
end

# Avoid - imperative mutation style
def process(state) do
  state = validate(state)
  state = enrich(state)
  persist(state)
end
```

### Use `with` for Happy Path
Chain operations that may fail, bail on first error:

```elixir
with {:ok, user} <- fetch_user(id),
     {:ok, account} <- fetch_account(user),
     :ok <- verify_permissions(account) do
  {:ok, account}
else
  {:error, :not_found} -> {:error, "User not found"}
  {:error, :forbidden} -> {:error, "Access denied"}
end
```

### Keyword Lists for Options, Maps for Data
```elixir
# Options - keyword list
def connect(host, opts \\ []) do
  port = Keyword.get(opts, :port, 443)
  timeout = Keyword.get(opts, :timeout, 5000)
end

# Data - map
user = %{name: "Alice", email: "alice@example.com"}
```

### Structs for Domain Entities
```elixir
defmodule User do
  @type t :: %__MODULE__{
    id: pos_integer(),
    name: String.t(),
    email: String.t()
  }
  
  @enforce_keys [:id, :name, :email]
  defstruct [:id, :name, :email]
end
```

### Behaviours for Contracts
```elixir
defmodule Command do
  @callback execute(bash :: JustBash.t(), args :: [String.t()], stdin :: String.t()) ::
    {result(), JustBash.t()}
end

defmodule Echo do
  @behaviour Command
  
  @impl true
  def execute(bash, args, _stdin), do: ...
end
```

---

## Code Style

### Function Clauses
Group clauses together. Order from specific to general:

```elixir
# Specific first
def parse("true"), do: {:ok, true}
def parse("false"), do: {:ok, false}
def parse(<<"0x", hex::binary>>), do: parse_hex(hex)
def parse(str) when is_binary(str), do: parse_string(str)
def parse(_), do: {:error, :invalid}
```

### Guards
Use guards for type checks and simple conditions:

```elixir
def process(n) when is_integer(n) and n > 0, do: ...
def process(s) when is_binary(s), do: ...
def process(list) when is_list(list) and length(list) > 0, do: ...
```

### Private Functions
Prefix with `do_` for recursive helpers or implementation details:

```elixir
def traverse(tree), do: do_traverse(tree, [])

defp do_traverse(nil, acc), do: Enum.reverse(acc)
defp do_traverse(%{left: l, right: r, value: v}, acc) do
  acc = do_traverse(l, acc)
  acc = [v | acc]
  do_traverse(r, acc)
end
```

### Reduce Patterns
```elixir
# Simple accumulation
Enum.reduce(items, 0, fn item, sum -> sum + item.value end)

# Building a map
Enum.reduce(items, %{}, fn item, acc ->
  Map.put(acc, item.id, item)
end)

# Early termination
Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
  case validate(item) do
    :ok -> {:cont, {:ok, [item | acc]}}
    {:error, _} = err -> {:halt, err}
  end
end)
```

### Comprehensions
Use for filtering and transformation:

```elixir
# Filter and transform
for user <- users, user.active, do: user.email

# Multiple generators (cartesian product)
for x <- 1..3, y <- 1..3, do: {x, y}

# Into different collectables
for {k, v} <- map, into: %{}, do: {k, String.upcase(v)}
```

---

## Performance

### Use IOData for String Building
```elixir
# Good - O(1) prepend, single flatten at end
defp build_output(lines) do
  lines
  |> Enum.reduce([], fn line, acc -> [acc, line, "\n"] end)
  |> IO.iodata_to_binary()
end

# Avoid - O(n) concatenation each time
Enum.reduce(lines, "", fn line, acc -> acc <> line <> "\n" end)
```

### Avoid Repeated List Access
```elixir
# Good - single pass
Enum.reduce(list, {0, nil}, fn x, {max, _} = acc ->
  if x > max, do: {x, x}, else: acc
end)

# Avoid - O(n) each call
max = Enum.max(list)
idx = Enum.find_index(list, &(&1 == max))
```

### Binary Pattern Matching
```elixir
# Efficient binary parsing
def parse(<<"HTTP/", version::binary-size(3), " ", status::binary-size(3), " ", rest::binary>>) do
  {version, String.to_integer(status), rest}
end
```

### Tail Recursion
```elixir
# Tail recursive - constant stack
defp sum(list), do: do_sum(list, 0)
defp do_sum([], acc), do: acc
defp do_sum([h | t], acc), do: do_sum(t, acc + h)

# Not tail recursive - grows stack
defp sum([]), do: 0
defp sum([h | t]), do: h + sum(t)
```

---

## Testing

### Descriptive Test Names
```elixir
# Good - describes behavior
test "returns error when file does not exist"
test "splits on IFS characters by default"

# Avoid - vague
test "handles error"
test "works correctly"
```

### Property-Based Tests
Use StreamData for invariants:

```elixir
property "reverse is self-inverse" do
  check all list <- list_of(integer()) do
    assert list |> Enum.reverse() |> Enum.reverse() == list
  end
end

property "sort produces ordered output" do
  check all list <- list_of(integer()) do
    sorted = Enum.sort(list)
    assert sorted == Enum.sort(sorted)  # idempotent
    assert Enum.zip(sorted, tl(sorted)) |> Enum.all?(fn {a, b} -> a <= b end)
  end
end
```

### Bash Comparison
```elixir
@tag :bash_comparison
test "brace expansion matches bash" do
  compare_bash("echo {a,b,c}")
end
```

### Test Organization
```elixir
describe "parse/1" do
  test "parses valid input" do ...end
  test "returns error for invalid input" do ...end
  test "handles edge case X" do ...end
end
```

---

## Anti-Patterns to Avoid

```elixir
# AVOID: if/else when pattern matching works
if Map.has_key?(map, :key), do: map.key, else: nil
# USE:
Map.get(map, :key)

# AVOID: nested case
case a do
  {:ok, x} ->
    case b(x) do
      {:ok, y} -> ...
# USE: with

# AVOID: Enum.at in loops
Enum.map(0..length(list)-1, fn i -> Enum.at(list, i) * 2 end)
# USE:
Enum.map(list, fn x -> x * 2 end)

# AVOID: string concat in reduce
Enum.reduce(items, "", fn x, acc -> acc <> x end)
# USE: iodata

# AVOID: boolean parameters
def fetch(id, true), do: ...   # What does true mean?
def fetch(id, false), do: ...
# USE: keyword options or atoms
def fetch(id, cache: true), do: ...
def fetch(id, :cached), do: ...

# AVOID: deeply nested data access
user[:profile][:settings][:theme][:color]
# USE: get_in or pattern matching
get_in(user, [:profile, :settings, :theme, :color])
```

---

## Project Structure

```
lib/just_bash/
  commands/           # One module per command
    echo.ex
    sed/
      parser.ex
      executor.ex
  interpreter/
    lexer.ex
    parser.ex
    executor.ex
    expansion.ex
  fs/
    in_memory_fs.ex
  ast/
    types.ex
  
test/
  commands/           # Command tests
  shell/              # Shell feature tests  
  bash_comparison_test.exs
  property_test.exs
```

---

## Commands

```bash
mix test                             # All tests
mix test path/to/file.exs            # Single file
mix test path/to/file.exs:42         # Single test at line
mix test --only describe:"sed"       # By describe block
mix test --include bash_comparison   # Include bash tests
mix compile --warnings-as-errors     # Strict mode
mix format                           # Format code
mix credo --strict                   # Static analysis
```
