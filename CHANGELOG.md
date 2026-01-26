# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-01-11

### Added

- Initial release
- In-memory virtual filesystem (`JustBash.Fs.InMemoryFs`)
- Bash lexer and recursive descent parser
- Variable expansion: `$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR:=default}`, `${VAR:+alt}`, `${#VAR}`, `${VAR:start:len}`, `${VAR#pattern}`, `${VAR%pattern}`, `${VAR/old/new}`, `${VAR^^}`, `${VAR,,}`
- Command substitution: `$(cmd)` and backticks
- Arithmetic expansion: `$((expr))` with full operator support including `**`, `?:`, hex, binary
- Control flow: `if/elif/else/fi`, `for x in ...; do; done`, `while/until`, `case/esac`
- Logical operators: `&&`, `||`, `!` with short-circuit evaluation
- Pipes with stdin/stdout flow
- Redirections: `>`, `>>`, `2>`, `&>`, `<`, `<<<`, heredocs
- Brace expansion: `{a,b,c}`, `{1..5}`, `{a..z}`
- Arrays: `arr=(...)`, `${arr[0]}`, `${arr[@]}`, `${#arr[@]}`
- Functions with local variables
- Extended test command: `[[ ]]` with regex support

### Commands

File operations:
- `cat`, `ls`, `cp`, `mv`, `rm`, `mkdir`, `touch`, `ln`
- `find`, `stat`, `du`, `tree`, `file`, `readlink`

Text processing:
- `grep`, `sed`, `awk` (full implementations)
- `sort`, `uniq`, `head`, `tail`, `wc`, `cut`, `tr`
- `rev`, `tac`, `nl`, `fold`, `paste`, `comm`, `diff`, `expand`

Data tools:
- `jq` (comprehensive JSON processor)
- `curl` (HTTP client with network allowlists)
- `markdown` / `md` (Markdown to HTML)
- `base64`, `md5sum`

Shell builtins:
- `echo`, `printf`, `pwd`, `cd`, `export`, `unset`
- `test`, `[`, `[[`, `true`, `false`, `:`
- `set` (shell options: `-e`, `-u`, `-o pipefail`)
- `source`, `.`, `read`, `exit`, `return`
- `local`, `declare`, `typeset`
- `break`, `continue`, `shift`, `getopts`, `trap`

Utilities:
- `seq`, `date`, `sleep`, `basename`, `dirname`
- `which`, `env`, `printenv`, `hostname`
- `xargs`, `tee`

[Unreleased]: https://github.com/elixir-ai-tools/just_bash/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/elixir-ai-tools/just_bash/releases/tag/v0.1.0
