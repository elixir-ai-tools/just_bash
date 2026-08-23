# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0](https://github.com/elixir-ai-tools/just_bash/compare/v0.3.0...v1.0.0) (2026-08-23)


### ⚠ BREAKING CHANGES

* JustBash.Fs and JustBash.Fs.InMemoryFs are replaced by JustBash.FS / JustBash.FS.Memory with vfs-shaped returns ({:ok, payload, fs} on reads, %VFS.Error{} on failure, %VFS.Stat{} from stat). Bash-level script behavior is unchanged.

### Features

* add JustBash.CLI for namespaced subcommand tools ([#39](https://github.com/elixir-ai-tools/just_bash/issues/39)) ([2761adf](https://github.com/elixir-ai-tools/just_bash/commit/2761adf6ba25a46b4c294f5cc75b663de45bb5b4))
* add put_context/3 and get_context/3 accessors ([#41](https://github.com/elixir-ai-tools/just_bash/issues/41)) ([2c6e6b7](https://github.com/elixir-ai-tools/just_bash/commit/2c6e6b70ea914b66f3f620ed25d69abb7887c4ec))
* **cli:** address consumer feedback from issue [#38](https://github.com/elixir-ai-tools/just_bash/issues/38) ([#43](https://github.com/elixir-ai-tools/just_bash/issues/43)) ([7d84244](https://github.com/elixir-ai-tools/just_bash/commit/7d84244af91435d0b3a9c1419ae68d55019222fc))
* replace the filesystem layer with the vfs library ([#44](https://github.com/elixir-ai-tools/just_bash/issues/44)) ([1da1db8](https://github.com/elixir-ai-tools/just_bash/commit/1da1db8a99491e9d0b7810fc9f84570be4e71c2f))


### Bug Fixes

* /dev/null exists as a filesystem node so operands agree with redirects ([#78](https://github.com/elixir-ai-tools/just_bash/issues/78)) ([#93](https://github.com/elixir-ai-tools/just_bash/issues/93)) ([8619ada](https://github.com/elixir-ai-tools/just_bash/commit/8619ada80d20d406e179279246e35d6c82a23fd9))
* a CLI flag rejects unknown spec keys and accepts extra long spellings ([#71](https://github.com/elixir-ai-tools/just_bash/issues/71)) ([83af599](https://github.com/elixir-ai-tools/just_bash/commit/83af5993b90e21cb09fcd72738e5d78e948a0c8b))
* a command whose redirect fails does not run at all ([#60](https://github.com/elixir-ai-tools/just_bash/issues/60)) ([025673c](https://github.com/elixir-ai-tools/just_bash/commit/025673c2bdc5f594766eaec33df461c309925a0c))
* a flag a command does not implement is an error, not a filename ([#72](https://github.com/elixir-ai-tools/just_bash/issues/72)) ([9aab27a](https://github.com/elixir-ai-tools/just_bash/commit/9aab27adeff8a50ce31c678a11d5b685aafe4037))
* a trailing slash on a destination requires a directory instead of overwriting the file it names ([#75](https://github.com/elixir-ai-tools/just_bash/issues/75)) ([5de39ef](https://github.com/elixir-ai-tools/just_bash/commit/5de39ef62dafd69837c5eeb05ecf766d739f6ca6))
* awk's empty for(;;) condition is true, matching gawk ([#87](https://github.com/elixir-ai-tools/just_bash/issues/87)) ([ca5c918](https://github.com/elixir-ai-tools/just_bash/commit/ca5c9182af690f48b75ad813c4dd99499298297f))
* bound ${v//pat/rep} so global replace cannot OOM ([#97](https://github.com/elixir-ai-tools/just_bash/issues/97)) ([f2beeb9](https://github.com/elixir-ai-tools/just_bash/commit/f2beeb9951a02f83ace7408dda1ac4b2cb4c9d67))
* bound value size so doubling cannot blow past max_wall_ms ([#85](https://github.com/elixir-ai-tools/just_bash/issues/85)) ([55c0f50](https://github.com/elixir-ai-tools/just_bash/commit/55c0f50551b094fe5a995699a0a665cb7bb4973c)), closes [#77](https://github.com/elixir-ai-tools/just_bash/issues/77)
* cp into a directory, and make cp -r actually copy ([#57](https://github.com/elixir-ai-tools/just_bash/issues/57)) ([7d73837](https://github.com/elixir-ai-tools/just_bash/commit/7d738370c306188e90baa6da56ca77c71b24c22e))
* date implements %F and -I instead of emitting them literally ([#63](https://github.com/elixir-ai-tools/just_bash/issues/63)) ([274e86b](https://github.com/elixir-ai-tools/just_bash/commit/274e86b476613d8c20a0a5e8cece190237d1f30a))
* date rejects unknown arguments instead of returning today at exit 0 ([#66](https://github.com/elixir-ai-tools/just_bash/issues/66)) ([fd2bb2c](https://github.com/elixir-ai-tools/just_bash/commit/fd2bb2c2bb4bae18412dfa65f39db1fd08bf8362))
* empty path operands are ENOENT, not the current directory ([#95](https://github.com/elixir-ai-tools/just_bash/issues/95)) ([2e73917](https://github.com/elixir-ai-tools/just_bash/commit/2e73917931996a33e52b82115960b4c1b4fa7df8))
* exec/2 returns a shell result instead of raising, and always terminates ([#73](https://github.com/elixir-ai-tools/just_bash/issues/73)) ([3b9be0d](https://github.com/elixir-ai-tools/just_bash/commit/3b9be0d73a78cd6b14abddfa30f7f7730b2a9cc3))
* find and jq honour `--` as end-of-options ([#90](https://github.com/elixir-ai-tools/just_bash/issues/90)) ([#98](https://github.com/elixir-ai-tools/just_bash/issues/98)) ([0077d63](https://github.com/elixir-ai-tools/just_bash/commit/0077d63a92f16a2a10288ac8deba7937a0df0bd2))
* grep BRE alternation, missing-path exit code, and flag-level did-you-mean ([#84](https://github.com/elixir-ai-tools/just_bash/issues/84)) ([3d2c625](https://github.com/elixir-ai-tools/just_bash/commit/3d2c625ca78027118f9fb118c8ca4ec1ab03fbd6))
* head default line count no longer emits a trailing blank line ([#91](https://github.com/elixir-ai-tools/just_bash/issues/91)) ([1bcda6b](https://github.com/elixir-ai-tools/just_bash/commit/1bcda6b2587d4ec889176a9c2b6968517a0328d8))
* honour `--` as end-of-options for file-operand commands ([#89](https://github.com/elixir-ai-tools/just_bash/issues/89)) ([b5477c3](https://github.com/elixir-ai-tools/just_bash/commit/b5477c3d4a2d61d7fa06d81b721b785e1299ae13))
* mkdir and rm report backend errors instead of crashing the exec ([#48](https://github.com/elixir-ai-tools/just_bash/issues/48)) ([dffd5dd](https://github.com/elixir-ai-tools/just_bash/commit/dffd5dd78be24dc96598fa4ca2d91955fddfe809))
* printf %b support and no-progress guard against format-recycle hangs ([#50](https://github.com/elixir-ai-tools/just_bash/issues/50)) ([56c74b8](https://github.com/elixir-ai-tools/just_bash/commit/56c74b82dae9bb72008c62cb47d530a284a30191))
* replace retired earmark runtime dependency with mdex ([#55](https://github.com/elixir-ai-tools/just_bash/issues/55)) ([ce86847](https://github.com/elixir-ai-tools/just_bash/commit/ce8684706d5b04cbacdebea1f8c860d729584ebc)), closes [#54](https://github.com/elixir-ai-tools/just_bash/issues/54)
* shasum -c and sha256sum -c read checksums from stdin ([#88](https://github.com/elixir-ai-tools/just_bash/issues/88)) ([cdddddc](https://github.com/elixir-ai-tools/just_bash/commit/cdddddc093b4fd6dee8be63739ae047dec7295b5))
* Special table owns readdir merge and write-redirect paths ([#99](https://github.com/elixir-ai-tools/just_bash/issues/99)) ([05a26b2](https://github.com/elixir-ai-tools/just_bash/commit/05a26b2f3bde1c21fa1345672e5785f48f5b30e0))
* tac does not invent a newline on an unterminated last record ([#92](https://github.com/elixir-ai-tools/just_bash/issues/92)) ([6c92a44](https://github.com/elixir-ai-tools/just_bash/commit/6c92a4406d08dacf2f1de8452b9cbbc318b69304))
* writing through a regular file is ENOTDIR, not unreachable state ([#56](https://github.com/elixir-ai-tools/just_bash/issues/56)) ([1633cdc](https://github.com/elixir-ai-tools/just_bash/commit/1633cdcf48919756123da7d3e1198093596d4037))

## [0.3.0](https://github.com/elixir-ai-tools/just_bash/compare/v0.2.0...v0.3.0) (2026-04-14)


### Features

* add context option to justbash struct for custom commands ([#34](https://github.com/elixir-ai-tools/just_bash/issues/34)) ([8824fd9](https://github.com/elixir-ai-tools/just_bash/commit/8824fd96db0863f2c7d07dc2925df6a280be4281))
* add xxd/od, curl flags, grep -P, awk crash guard ([#32](https://github.com/elixir-ai-tools/just_bash/issues/32)) ([4afdb3b](https://github.com/elixir-ai-tools/just_bash/commit/4afdb3b))
* add production resource limits and execution stats ([#28](https://github.com/elixir-ai-tools/just_bash/issues/28)) ([9c7a36d](https://github.com/elixir-ai-tools/just_bash/commit/9c7a36d))
* add missing command flags, stdin support, and bash comparison fixtures ([#31](https://github.com/elixir-ai-tools/just_bash/issues/31)) ([67de3b0](https://github.com/elixir-ai-tools/just_bash/commit/67de3b0))
* replace NimbleParsec lexer with hand-written state machine ([#30](https://github.com/elixir-ai-tools/just_bash/issues/30)) ([bc05d36](https://github.com/elixir-ai-tools/just_bash/commit/bc05d36))
* add telemetry instrumentation for script execution ([#29](https://github.com/elixir-ai-tools/just_bash/issues/29)) ([b8cac23](https://github.com/elixir-ai-tools/just_bash/commit/b8cac23))


### Bug Fixes

* jq parser failing to resolve builtin function names to atoms ([144cbe8](https://github.com/elixir-ai-tools/just_bash/commit/144cbe8))

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

### Bug Fixes

* `${v//pat/rep}` / `${v/pat/rep}` refuse before allocating a result that would exceed `:max_value_bytes` ([#86](https://github.com/elixir-ai-tools/just_bash/issues/86))
* empty-string path operands are `ENOENT`, not the current directory ([#79](https://github.com/elixir-ai-tools/just_bash/issues/79))
* honour `--` as end-of-options for file-operand commands ([#83](https://github.com/elixir-ai-tools/just_bash/issues/83))
* find and jq honour `--` as end-of-options: `find -- -foo` is a path, `jq -- .` is the filter ([#90](https://github.com/elixir-ai-tools/just_bash/issues/90))
* head default line count no longer emits a trailing blank line ([#80](https://github.com/elixir-ai-tools/just_bash/issues/80))
* tac no longer invents a newline on an unterminated last record ([#82](https://github.com/elixir-ai-tools/just_bash/issues/82))
* `/dev/null` exists as a filesystem node, so operands agree with redirects ([#78](https://github.com/elixir-ai-tools/just_bash/issues/78))
* `FS.readdir/2` only uniq-sorts directories that contribute special children, and write redirects to `/dev/./null` skip the file-size cap ([#94](https://github.com/elixir-ai-tools/just_bash/issues/94))

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
