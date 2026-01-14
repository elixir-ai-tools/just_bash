#!/usr/bin/env elixir
# Daily Weather Report Generator
# Demonstrates: curl, jq, sqlite3, liquid templating, and bash pipelines
#
# This script:
# 1. Fetches hourly forecast from weather.gov API
# 2. Loads data into SQLite for analysis
# 3. Runs SQL queries to extract insights
# 4. Renders a beautiful report using Liquid templates

Mix.install([{:just_bash, path: "."}])

# HTML template for the weather report
report_template = ~S"""
<!DOCTYPE html>
<html>
<head>
  <title>NYC Daily Weather Report</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 800px; margin: 40px auto; padding: 20px; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh; }
    .card { background: white; border-radius: 16px; padding: 32px; margin-bottom: 24px; box-shadow: 0 10px 40px rgba(0,0,0,0.2); }
    h1 { margin: 0 0 8px 0; color: #1a1a2e; font-size: 2.5em; }
    .subtitle { color: #666; margin-bottom: 24px; font-size: 1.1em; }
    .summary { font-size: 1.3em; line-height: 1.6; color: #333; border-left: 4px solid #667eea; padding-left: 20px; margin: 24px 0; }
    .stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; margin: 24px 0; }
    .stat { text-align: center; padding: 20px; background: #f8f9fa; border-radius: 12px; }
    .stat-value { font-size: 2.5em; font-weight: bold; color: #667eea; }
    .stat-label { color: #666; margin-top: 8px; font-size: 0.9em; text-transform: uppercase; letter-spacing: 1px; }
    .hourly { margin-top: 24px; }
    .hourly h2 { color: #1a1a2e; border-bottom: 2px solid #eee; padding-bottom: 12px; }
    .hour-row { display: flex; align-items: center; padding: 12px 0; border-bottom: 1px solid #f0f0f0; }
    .hour-time { width: 80px; font-weight: 600; color: #333; }
    .hour-temp { width: 60px; font-size: 1.2em; color: #667eea; font-weight: bold; }
    .hour-desc { flex: 1; color: #666; }
    .hour-wind { width: 100px; color: #888; font-size: 0.9em; text-align: right; }
    .alert { background: #fff3cd; border: 1px solid #ffc107; border-radius: 8px; padding: 16px; margin-bottom: 24px; }
    .alert-title { font-weight: bold; color: #856404; }
    .insights { background: #e8f4fd; border-radius: 12px; padding: 20px; margin-top: 24px; }
    .insights h3 { margin-top: 0; color: #0066cc; }
    .insights ul { margin: 0; padding-left: 20px; }
    .insights li { margin: 8px 0; color: #333; }
    .footer { text-align: center; color: rgba(255,255,255,0.8); margin-top: 24px; font-size: 0.9em; }
  </style>
</head>
<body>
  <div class="card">
    <h1>{{ location }}</h1>
    <div class="subtitle">{{ generated_at }}</div>
    
    {% if alert %}
    <div class="alert">
      <div class="alert-title">Weather Alert</div>
      {{ alert }}
    </div>
    {% endif %}
    
    <div class="summary">{{ summary }}</div>
    
    <div class="stats">
      <div class="stat">
        <div class="stat-value">{{ temp_high }}°</div>
        <div class="stat-label">High</div>
      </div>
      <div class="stat">
        <div class="stat-value">{{ temp_low }}°</div>
        <div class="stat-label">Low</div>
      </div>
      <div class="stat">
        <div class="stat-value">{{ temp_avg }}°</div>
        <div class="stat-label">Average</div>
      </div>
    </div>
    
    <div class="insights">
      <h3>Today's Insights</h3>
      <ul>
        <li><strong>Temperature Range:</strong> {{ temp_range }}° swing throughout the day</li>
        <li><strong>Best Time Outside:</strong> {{ best_hour }} ({{ best_temp }}°F, {{ best_conditions }})</li>
        <li><strong>Wind:</strong> {{ wind_summary }}</li>
        <li><strong>Conditions:</strong> {{ condition_summary }}</li>
      </ul>
    </div>
    
    <div class="hourly">
      <h2>Hourly Breakdown</h2>
      {% for hour in hours %}
      <div class="hour-row">
        <div class="hour-time">{{ hour.time }}</div>
        <div class="hour-temp">{{ hour.temp }}°</div>
        <div class="hour-desc">{{ hour.description }}</div>
        <div class="hour-wind">{{ hour.wind }}</div>
      </div>
      {% endfor %}
    </div>
  </div>
  
  <div class="footer">
    Generated with JustBash | Data from weather.gov API<br>
    curl → jq → sqlite3 → liquid | Pure Elixir, Zero System Access
  </div>
</body>
</html>
"""

# The main bash script that does all the work
weather_script = ~S"""
# ============================================================
# NYC Daily Weather Report Generator
# ============================================================
# This script demonstrates the full power of JustBash:
# - HTTP requests with curl
# - JSON processing with jq  
# - SQL analytics with sqlite3
# - Template rendering with liquid
# ============================================================

set -e

echo "Fetching NYC weather data from weather.gov..." >&2

# Step 1: Fetch hourly forecast for NYC (Central Park)
# First get the forecast URL from the points endpoint
FORECAST_URL=$(curl -s "https://api.weather.gov/points/40.7128,-74.0060" \
  | jq -r '.properties.forecastHourly')

echo "Forecast URL: $FORECAST_URL" >&2

# Fetch the hourly forecast
curl -s "$FORECAST_URL" > /tmp/forecast.json

echo "Processing forecast data..." >&2

# Step 2: Extract and transform hourly data with jq
cat /tmp/forecast.json | jq -c '
  .properties.periods[:24] | 
  .[] | 
  {
    hour: (.startTime | split("T")[1] | split("-")[0] | split(":")[0]),
    temp: .temperature,
    wind_speed: (.windSpeed | split(" ")[0] | tonumber),
    wind_dir: .windDirection,
    description: .shortForecast,
    detailed: .detailedForecast
  }
' > /tmp/hourly.jsonl

# Step 3: Load into SQLite for analysis
echo "Loading data into SQLite..." >&2

sqlite3 weather "CREATE TABLE IF NOT EXISTS hourly (
  hour TEXT,
  temp INTEGER,
  wind_speed INTEGER,
  wind_dir TEXT,
  description TEXT,
  detailed TEXT
)"

# Import each JSON line
while read -r line; do
  hour=$(echo "$line" | jq -r '.hour')
  temp=$(echo "$line" | jq -r '.temp')
  wind_speed=$(echo "$line" | jq -r '.wind_speed')
  wind_dir=$(echo "$line" | jq -r '.wind_dir')
  description=$(echo "$line" | jq -r '.description' | sed "s/'/''/g")
  detailed=$(echo "$line" | jq -r '.detailed' | sed "s/'/''/g")
  
  sqlite3 weather "INSERT INTO hourly VALUES ('$hour', $temp, $wind_speed, '$wind_dir', '$description', '$detailed')"
done < /tmp/hourly.jsonl

echo "Running analytics queries..." >&2

# Step 4: Run analytics queries
TEMP_HIGH=$(sqlite3 weather "SELECT MAX(temp) FROM hourly")
TEMP_LOW=$(sqlite3 weather "SELECT MIN(temp) FROM hourly")
TEMP_AVG=$(sqlite3 weather "SELECT ROUND(AVG(temp)) FROM hourly")
TEMP_RANGE=$((TEMP_HIGH - TEMP_LOW))

# Find the best hour to be outside (moderate temp, low wind)
BEST_HOUR_DATA=$(sqlite3 weather "
  SELECT hour, temp, description 
  FROM hourly 
  WHERE temp BETWEEN 60 AND 80 
  ORDER BY wind_speed ASC, ABS(temp - 72) ASC 
  LIMIT 1
")

if [ -z "$BEST_HOUR_DATA" ]; then
  BEST_HOUR_DATA=$(sqlite3 weather "
    SELECT hour, temp, description 
    FROM hourly 
    ORDER BY ABS(temp - 72) ASC, wind_speed ASC 
    LIMIT 1
  ")
fi

BEST_HOUR=$(echo "$BEST_HOUR_DATA" | cut -d'|' -f1)
BEST_TEMP=$(echo "$BEST_HOUR_DATA" | cut -d'|' -f2)
BEST_CONDITIONS=$(echo "$BEST_HOUR_DATA" | cut -d'|' -f3)

# Format best hour for display
if [ "$BEST_HOUR" -lt 12 ]; then
  if [ "$BEST_HOUR" = "00" ]; then
    BEST_HOUR_FMT="12 AM"
  else
    BEST_HOUR_FMT="$((10#$BEST_HOUR)) AM"
  fi
elif [ "$BEST_HOUR" = "12" ]; then
  BEST_HOUR_FMT="12 PM"
else
  BEST_HOUR_FMT="$((10#$BEST_HOUR - 12)) PM"
fi

# Wind summary
AVG_WIND=$(sqlite3 weather "SELECT ROUND(AVG(wind_speed)) FROM hourly")
MAX_WIND=$(sqlite3 weather "SELECT MAX(wind_speed) FROM hourly")
WIND_SUMMARY="Average ${AVG_WIND} mph, gusts up to ${MAX_WIND} mph"

# Most common condition
COMMON_CONDITION=$(sqlite3 weather "
  SELECT description, COUNT(*) as cnt 
  FROM hourly 
  GROUP BY description 
  ORDER BY cnt DESC 
  LIMIT 1
" | cut -d'|' -f1)

CONDITION_COUNT=$(sqlite3 weather "SELECT COUNT(DISTINCT description) FROM hourly")
CONDITION_SUMMARY="Mostly $COMMON_CONDITION ($CONDITION_COUNT different conditions today)"

# Generate summary based on conditions
if [ "$TEMP_HIGH" -ge 85 ]; then
  SUMMARY="Hot day ahead! Temperatures will reach ${TEMP_HIGH}°F. Stay hydrated and seek shade during peak hours."
elif [ "$TEMP_HIGH" -ge 75 ]; then
  SUMMARY="A pleasant warm day with temperatures up to ${TEMP_HIGH}°F. Great weather for outdoor activities."
elif [ "$TEMP_HIGH" -ge 60 ]; then
  SUMMARY="Mild temperatures today, ranging from ${TEMP_LOW}°F to ${TEMP_HIGH}°F. A light jacket might be useful."
elif [ "$TEMP_HIGH" -ge 45 ]; then
  SUMMARY="Cool day ahead with highs around ${TEMP_HIGH}°F. Dress in layers for comfort."
else
  SUMMARY="Bundle up! Cold temperatures expected with a high of only ${TEMP_HIGH}°F."
fi

# Check for rain/snow in forecast
if sqlite3 weather "SELECT 1 FROM hourly WHERE description LIKE '%Rain%' OR description LIKE '%Shower%' LIMIT 1" | grep -q 1; then
  SUMMARY="$SUMMARY Bring an umbrella - rain is expected."
  ALERT="Rain in the forecast. Check hourly breakdown for timing."
elif sqlite3 weather "SELECT 1 FROM hourly WHERE description LIKE '%Snow%' LIMIT 1" | grep -q 1; then
  SUMMARY="$SUMMARY Snow is in the forecast - plan accordingly."
  ALERT="Snow expected. Travel may be affected."
else
  ALERT=""
fi

echo "Generating hourly data for template..." >&2

# Step 5: Generate hourly data for template
HOURS_JSON=$(sqlite3 weather "SELECT hour, temp, description, wind_speed || ' mph ' || wind_dir as wind FROM hourly" | while read -r row; do
  hour=$(echo "$row" | cut -d'|' -f1)
  temp=$(echo "$row" | cut -d'|' -f2)
  desc=$(echo "$row" | cut -d'|' -f3)
  wind=$(echo "$row" | cut -d'|' -f4)
  
  # Format hour
  if [ "$hour" -lt 12 ]; then
    if [ "$hour" = "00" ]; then
      hour_fmt="12 AM"
    else
      hour_fmt="$((10#$hour)) AM"
    fi
  elif [ "$hour" = "12" ]; then
    hour_fmt="12 PM"
  else
    hour_fmt="$((10#$hour - 12)) PM"
  fi
  
  echo "{\"time\":\"$hour_fmt\",\"temp\":$temp,\"description\":\"$desc\",\"wind\":\"$wind\"}"
done | jq -s '.')

# Step 6: Build the template data
GENERATED_AT=$(date "+%A, %B %d, %Y at %I:%M %p")

cat << TEMPLATE_DATA
{
  "location": "New York City Weather Report",
  "generated_at": "$GENERATED_AT",
  "summary": "$SUMMARY",
  "alert": "$ALERT",
  "temp_high": $TEMP_HIGH,
  "temp_low": $TEMP_LOW,
  "temp_avg": $TEMP_AVG,
  "temp_range": $TEMP_RANGE,
  "best_hour": "$BEST_HOUR_FMT",
  "best_temp": $BEST_TEMP,
  "best_conditions": "$BEST_CONDITIONS",
  "wind_summary": "$WIND_SUMMARY",
  "condition_summary": "$CONDITION_SUMMARY",
  "hours": $HOURS_JSON
}
TEMPLATE_DATA
"""

# Create the JustBash environment
bash =
  JustBash.new(
    network: %{enabled: true, allow_list: ["api.weather.gov"]},
    files: %{
      "/templates/report.html" => report_template
    }
  )

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("   NYC Daily Weather Report Generator")
IO.puts("   Powered by JustBash - Pure Elixir Bash Interpreter")
IO.puts(String.duplicate("=", 60) <> "\n")

# Run the weather script to get template data
IO.puts("Running weather pipeline: curl → jq → sqlite3 → liquid\n")

{result, bash} = JustBash.exec(bash, weather_script)

if result.exit_code != 0 do
  IO.puts("Error running weather script:")
  IO.puts(result.stderr)
  System.halt(1)
end

# The script outputs JSON data for the template
template_data = String.trim(result.stdout)

IO.puts(result.stderr)
IO.puts("\nRendering HTML report with Liquid template...\n")

# Render the final HTML report using liquid
render_script = """
cat << 'JSON_DATA' | liquid -d /dev/stdin /templates/report.html
#{template_data}
JSON_DATA
"""

{final_result, _} = JustBash.exec(bash, render_script)

if final_result.exit_code != 0 do
  IO.puts("Error rendering template:")
  IO.puts(final_result.stderr)
  System.halt(1)
end

# Write the report to a file
report_path = "weather_report.html"
File.write!(report_path, final_result.stdout)

IO.puts(String.duplicate("=", 60))
IO.puts("   Report generated successfully!")
IO.puts(String.duplicate("=", 60))
IO.puts("\nOutput: #{report_path}")
IO.puts("Open in browser: open #{report_path}\n")

# Also print a text summary
summary_script = """
cat << 'JSON_DATA' | jq -r '"
TODAY\\'S FORECAST
================
High: \\(.temp_high)°F | Low: \\(.temp_low)°F | Avg: \\(.temp_avg)°F

\\(.summary)

Best time outside: \\(.best_hour) (\\(.best_temp)°F, \\(.best_conditions))
Wind: \\(.wind_summary)

Hourly Preview:
" + (.hours[:6] | map("  \\(.time): \\(.temp)°F - \\(.description)") | join("\\n"))'
#{template_data}
JSON_DATA
"""

{summary_result, _} = JustBash.exec(bash, summary_script)
IO.puts(summary_result.stdout)
