#!/usr/bin/env elixir
# Run NYC Weather Report with JustBash
#
# Usage: mix run examples/run_weather.exs

script = File.read!("examples/daily_weather_report.sh")

bash = JustBash.new(network: %{enabled: true, allow_list: ["api.weather.gov"]})

{result, _bash} = JustBash.exec(bash, script)

IO.puts(result.stderr)
IO.puts(result.stdout)

if result.exit_code != 0 do
  IO.puts("Exit code: #{result.exit_code}")
end
