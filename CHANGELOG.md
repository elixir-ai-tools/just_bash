# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0](https://github.com/elixir-ai-tools/just_bash/compare/v0.1.0...v0.2.0) (2026-03-23)


### Features

* add 12 new evals covering uncovered commands and shell features ([2c21f75](https://github.com/elixir-ai-tools/just_bash/commit/2c21f757a9307c2cac494f4e0fa736698af5915f))
* add custom command eval with KV store ([840ba00](https://github.com/elixir-ai-tools/just_bash/commit/840ba00db53fc8b4628b203568e75c2b06af943a))
* add eval system and fix 5 bugs exposed by LLM agent evals ([39e4637](https://github.com/elixir-ai-tools/just_bash/commit/39e463757092b8732f7523d2f6d86dbeea93ee2d))
* expand evals to 28 tasks and fix 8 additional bugs ([5ba37c5](https://github.com/elixir-ai-tools/just_bash/commit/5ba37c51d723cedf8797505ecf5f132db548795d))
* major expansion - 15 new commands, jq overhaul, test infrastructure ([a5efb73](https://github.com/elixir-ai-tools/just_bash/commit/a5efb73bda8409fa59aab1cb9752ace0d4bedeba))
* test infrastructure, new commands, jq overhaul ([13749d2](https://github.com/elixir-ai-tools/just_bash/commit/13749d2aa7c8b752acb3e52b3f9f53a5c1cd98c9))


### Bug Fixes

* 8 AWK bugs, jq -e exit status, declare -A keys, printf redirect parsing ([cb57e64](https://github.com/elixir-ai-tools/just_bash/commit/cb57e646e01de36eb67bb92eedbf79e2e8cf412b))
* capture bash state between exec calls in README example ([09b2039](https://github.com/elixir-ai-tools/just_bash/commit/09b2039fd2940fe8e5db95410317250ee5830d01))
* correct GitHub URLs in CHANGELOG ([a4cf791](https://github.com/elixir-ai-tools/just_bash/commit/a4cf791d4c281529ee795e4b200515e10bbec3dd))
* correct GitHub URLs in CHANGELOG ([5b29c7e](https://github.com/elixir-ai-tools/just_bash/commit/5b29c7e8748afc4cadbb22bd2b8e9893dd9cb431))
* heredoc in compound commands, assoc array subscripts, which/type builtins, jq [@tsv](https://github.com/tsv) ([99aab44](https://github.com/elixir-ai-tools/just_bash/commit/99aab442ef02edef740b72c56792ef017724b9e8))
* implement AWK field assignment ($N = value) with $0 reconstruction ([e760cad](https://github.com/elixir-ai-tools/just_bash/commit/e760cad327acd2d7af737dcb79bc5c64a8f82cae))
* read IFS splitting, wc/head/tail multi-file, and improve eval robustness ([7d96af7](https://github.com/elixir-ai-tools/just_bash/commit/7d96af70bc5ee081a6c4f9bf4e688b8fa277849e))
* remove deprecated package-name from release-please workflow ([d1d7ab7](https://github.com/elixir-ai-tools/just_bash/commit/d1d7ab7794c3c022cb49703c1eda3e2b2413fb04))
* **tests:** use variable instead of module attribute for spec tests ([#18](https://github.com/elixir-ai-tools/just_bash/issues/18)) ([f583911](https://github.com/elixir-ai-tools/just_bash/commit/f583911576329333ae17c8174e3a975df81a8ccb))

## [Unreleased]

### Added

- Centralized security policy system (`JustBash.Security.Policy`) with 25 configurable resource limits
- Three built-in presets: `:default`, `:strict`, `:relaxed` — configurable via `JustBash.new(security: ...)`
- Structured violation metadata (`JustBash.Security.Violation`) returned in `result.violation`
- Per-run execution budgets tracking output bytes, step count, and sticky violations
- Resource limits enforced across parsing, expansion, execution, output, filesystem, environment, regex, glob, network, and jq operations
- Internal interpreter state isolation — `__STDIN__`, `__locals__`, `__assoc__` moved out of `bash.env` to prevent script observation or corruption
- `BannedCallTracer` static analysis preventing real-filesystem escapes from command modules
- Network security: HTTPS-only by default, manual redirect validation, allow-list inversion (`empty = deny all`)
- Atom exhaustion fix in `FlagParser` — unknown flags no longer create atoms
- `SECURITY.md` documenting the threat model, guarantees, and non-goals

### Changed

- **BREAKING**: `max_iterations` and `max_call_depth` are no longer accepted as top-level options in `JustBash.new/1`. Use `security: [max_iterations: N, max_call_depth: N]` instead. Passing the old options raises `ArgumentError` with migration guidance.
- `Policy.new/1` now validates unknown keys and non-positive-integer values
- `Policy.get/2` raises `ArgumentError` (not `KeyError`) on unknown keys
- Curl `-k`/`--insecure` flag removed from argument parser

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
