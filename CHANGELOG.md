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
- Variable expansion: `$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR:=default}`, `${VAR:+alt}`, `${#VAR}`
- Command substitution: `$(cmd)` and backticks
- Arithmetic expansion: `$((expr))` with full operator support
- Control flow: `if/elif/else/fi`, `for x in ...; do; done`, `while/until`
- Logical operators: `&&`, `||`, `!` with short-circuit evaluation
- Pipes with stdin/stdout flow
- Redirections: `>`, `>>`
- Test command: `[ ]` and `test`

### Commands

File operations:
- `cat`, `ls`, `cp`, `mv`, `rm`, `mkdir`, `touch`

Text processing:
- `grep`, `sort`, `uniq`, `head`, `tail`, `wc`, `tr`

Utilities:
- `echo`, `printf`, `pwd`, `cd`, `export`, `unset`
- `test`, `[`, `true`, `false`, `:`
- `seq`, `date`, `sleep`, `basename`, `dirname`
- `read`, `exit`

[Unreleased]: https://github.com/ivarvong/just_bash/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ivarvong/just_bash/releases/tag/v0.1.0
