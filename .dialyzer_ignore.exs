[
  # Control flow signals (__break__, __continue__, __return__) are dynamically added to results
  {"lib/just_bash/interpreter/executor.ex", :guard_fail},
  {"lib/just_bash/interpreter/executor.ex", :pattern_match},
  {"lib/just_bash/commands/break.ex", :callback_type_mismatch},
  {"lib/just_bash/commands/continue.ex", :callback_type_mismatch},
  {"lib/just_bash/commands/return.ex", :callback_type_mismatch},
  # Printf pattern match issue
  {"lib/just_bash/commands/printf.ex", :pattern_match},
  # AWK parser/evaluator type specs use internal types
  {"lib/just_bash/commands/awk/evaluator.ex", :invalid_contract},
  {"lib/just_bash/commands/awk/evaluator.ex", :unknown_type},
  {"lib/just_bash/commands/awk/parser.ex", :unknown_type}
]
