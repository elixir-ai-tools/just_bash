[
  # AWK parser/evaluator type specs use internal types
  {"lib/just_bash/commands/awk/evaluator.ex", :unknown_type},
  # file_outputs key is always present in initial state (line 52) but dialyzer
  # can't infer it through all execute_statement clause paths
  {"lib/just_bash/commands/awk/evaluator.ex", :map_update},
  {"lib/just_bash/commands/awk/parser.ex", :unknown_type},
  # jq AST node types: parser produces :module_directives and :def tuples that
  # dialyzer can't infer from its analysis of the parser return type
  {"lib/just_bash/commands/jq/evaluator.ex", :pattern_match},
  # valid_path_expr? catch-all returns false, but dialyzer infers callers only
  # pass values that match earlier (true-returning) clauses — defensive by design
  {"lib/just_bash/commands/jq/evaluator/functions.ex", :pattern_match},

  # format_array_key catch-all handles any type defensively, but dialyzer infers
  # callers only pass float/integer/binary values covered by earlier clauses
  {"lib/just_bash/commands/awk/evaluator.ex", :pattern_match_cov},
  # MapSet.t() is opaque — dialyzer warns when it appears inside struct types
  # that are used in specs.  State.t() contains MapSet fields for locals and
  # assoc_arrays, which propagates opaque warnings through JustBash.t() and
  # every function that accepts/returns it.  These are false positives.
  {"lib/just_bash/interpreter/state.ex", :contract_with_opaque},
  {"lib/just_bash.ex", :contract_with_opaque},
  {"lib/just_bash/sigil.ex", :call_without_opaque},
  {"lib/just_bash/fs/overlay_fs.ex", :contract_with_opaque}
]
