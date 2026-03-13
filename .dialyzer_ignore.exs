[
  # AWK parser/evaluator type specs use internal types
  {"lib/just_bash/commands/awk/evaluator.ex", :invalid_contract},
  {"lib/just_bash/commands/awk/evaluator.ex", :unknown_type},
  {"lib/just_bash/commands/awk/parser.ex", :unknown_type},
  # jq AST node types: parser produces :module_directives and :def tuples that
  # dialyzer can't infer from its analysis of the parser return type
  {"lib/just_bash/commands/jq/evaluator.ex", :pattern_match},
  # valid_path_expr? catch-all returns false, but dialyzer infers callers only
  # pass values that match earlier (true-returning) clauses — defensive by design
  {"lib/just_bash/commands/jq/evaluator/functions.ex", :pattern_match},
  # format_redirection_error handles multiple POSIX error atoms defensively,
  # but InMemoryFs.write_file currently only returns :eisdir
  {"lib/just_bash/interpreter/executor/redirection.ex", :pattern_match},
  {"lib/just_bash/interpreter/executor/redirection.ex", :pattern_match_cov}
]
