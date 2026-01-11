# Contributing to JustBash

Thank you for your interest in contributing to JustBash! This document provides guidelines and information for contributors.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/your-username/just_bash.git`
3. Install dependencies: `mix deps.get`
4. Run tests to make sure everything works: `mix test`

## Development Setup

JustBash requires:
- Elixir 1.15 or later
- Erlang/OTP 25 or later

```bash
# Install dependencies
mix deps.get

# Run tests
mix test

# Run the demo
mix run demo.exs

# Generate documentation
mix docs

# Run static analysis
mix credo
mix dialyzer
```

## Making Changes

### Branch Naming

- `feature/` - New features (e.g., `feature/add-sed-command`)
- `fix/` - Bug fixes (e.g., `fix/pipe-stdin-handling`)
- `docs/` - Documentation changes
- `refactor/` - Code refactoring without functional changes

### Code Style

- Follow the existing code style
- Run `mix format` before committing
- Run `mix credo` to check for style issues
- Add tests for new functionality
- Update documentation for API changes

### Commit Messages

Use clear, descriptive commit messages:

```
Add support for 'cut' command

- Implement -d (delimiter) and -f (fields) flags
- Add stdin support
- Add tests for basic functionality
```

## Adding New Commands

To add a new command (e.g., `cut`):

1. Add the command implementation in `lib/just_bash.ex`:

```elixir
defp execute_builtin(bash, "cut", args, stdin) do
  # Parse flags
  # Implement logic
  # Return {%{stdout: output, stderr: "", exit_code: 0}, bash}
end
```

2. Add flag parsing if needed:

```elixir
defp parse_cut_flags(args), do: parse_cut_flags(args, %{d: "\t", f: nil}, [])
# ... flag parsing clauses
```

3. Add tests in `test/interpreter_test.exs`:

```elixir
describe "cut command" do
  test "cuts fields with delimiter" do
    bash = JustBash.new(files: %{"/test.txt" => "a:b:c\n1:2:3"})
    {result, _} = JustBash.exec(bash, "cut -d: -f2 /test.txt")
    assert result.stdout == "b\n2\n"
  end
end
```

4. Update the README with the new command

## Adding New Shell Features

For parser/lexer changes:

1. **Lexer changes** - `lib/just_bash/parser/lexer.ex`
   - Add new token types
   - Add lexing rules

2. **Parser changes** - `lib/just_bash/parser/parser.ex`
   - Add AST node types in `lib/just_bash/ast/types.ex`
   - Add parsing functions

3. **Interpreter changes** - `lib/just_bash.ex`
   - Add `execute_command/3` clauses for new AST nodes

## Testing

### Running Tests

```bash
# Run all tests
mix test

# Run specific test file
mix test test/interpreter_test.exs

# Run tests matching a pattern
mix test --only grep

# Run with coverage
mix test --cover
```

### Test Organization

- `test/just_bash_test.exs` - Basic integration tests
- `test/interpreter_test.exs` - Command and feature tests
- `test/in_memory_fs_test.exs` - Filesystem tests

### Writing Tests

```elixir
describe "feature name" do
  test "basic functionality" do
    bash = JustBash.new()
    {result, _} = JustBash.exec(bash, "command")
    assert result.stdout == "expected output\n"
    assert result.exit_code == 0
  end

  test "error handling" do
    bash = JustBash.new()
    {result, _} = JustBash.exec(bash, "command with error")
    assert result.exit_code != 0
    assert result.stderr =~ "error message"
  end
end
```

## Pull Request Process

1. Ensure all tests pass: `mix test`
2. Run the formatter: `mix format`
3. Run static analysis: `mix credo`
4. Update documentation if needed
5. Create a pull request with a clear description

### PR Description Template

```markdown
## Summary
Brief description of the changes

## Changes
- Change 1
- Change 2

## Testing
How was this tested?

## Checklist
- [ ] Tests pass
- [ ] Code formatted
- [ ] Documentation updated
```

## Reporting Issues

When reporting issues, please include:

1. Elixir and OTP versions (`elixir --version`)
2. JustBash version
3. Minimal reproduction case
4. Expected vs actual behavior

## Feature Requests

Feature requests are welcome! Please check existing issues first to avoid duplicates.

Good feature requests include:
- Clear description of the feature
- Use case / motivation
- Example of how it would work

## Areas for Contribution

### Good First Issues

- Add missing flags to existing commands
- Improve error messages
- Add more tests
- Documentation improvements

### Medium Complexity

- Implement new commands (sed, awk, find, xargs)
- Add glob expansion
- Improve pipe performance

### Advanced

- Here documents (`<<EOF`)
- Function definitions
- Arrays and associative arrays
- Process substitution

## Questions?

Feel free to open an issue for questions or discussions about the project.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
