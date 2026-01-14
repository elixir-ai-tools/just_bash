#!/bin/bash
# NYC Daily Weather Report
# Demonstrates: curl → jq → sqlite3 pipeline
#
# Run with real bash:  bash examples/daily_weather_report.sh
# Run with JustBash:   mix run examples/run_weather.exs

echo "=== NYC Daily Weather Report ===" >&2
echo "" >&2

# Step 1: Fetch weather data
echo "[1/3] Fetching from weather.gov..." >&2
curl -s "https://api.weather.gov/points/40.7128,-74.0060" > /tmp/points.json

# Check for API errors
if cat /tmp/points.json | jq -e '.type' 2>/dev/null | grep -q "problems"; then
  echo "ERROR: Weather API unavailable. Try again later." >&2
  echo "Response: $(cat /tmp/points.json | jq -r '.title // .detail // "Unknown error"')" >&2
  exit 1
fi

FORECAST_URL=$(cat /tmp/points.json | jq -r '.properties.forecastHourly')
if [ -z "$FORECAST_URL" ] || [ "$FORECAST_URL" = "null" ]; then
  echo "ERROR: Could not get forecast URL from API response." >&2
  exit 1
fi

curl -s "$FORECAST_URL" > /tmp/forecast.json

# Check for forecast API errors
if cat /tmp/forecast.json | jq -e '.type' 2>/dev/null | grep -q "problems"; then
  echo "ERROR: Forecast API unavailable. Try again later." >&2
  echo "Response: $(cat /tmp/forecast.json | jq -r '.title // .detail // "Unknown error"')" >&2
  exit 1
fi

# Step 2: Extract with jq - simpler approach
echo "[2/3] Processing with jq..." >&2
cat /tmp/forecast.json | jq -r '.properties.periods[:12] | .[] | .temperature' > /tmp/temps.txt
cat /tmp/forecast.json | jq -r '.properties.periods[:12] | .[] | .shortForecast' > /tmp/conds.txt

# Check if we got valid data
if [ ! -s /tmp/temps.txt ]; then
  echo "ERROR: No temperature data received from API." >&2
  exit 1
fi

# Step 3: Load into SQLite
echo "[3/3] Analyzing with sqlite3..." >&2

# Build SQL script to load and query data
SQL="CREATE TABLE w (temp INT, cond TEXT);"
i=1
while [ $i -le 12 ]; do
  temp=$(sed -n "${i}p" /tmp/temps.txt)
  cond=$(sed -n "${i}p" /tmp/conds.txt | sed "s/'/''/g")
  SQL="$SQL INSERT INTO w VALUES ($temp, '$cond');"
  i=$((i + 1))
done

HIGH=$(echo "$SQL SELECT MAX(temp) FROM w;" | sqlite3)
LOW=$(echo "$SQL SELECT MIN(temp) FROM w;" | sqlite3)
AVG=$(echo "$SQL SELECT CAST(AVG(temp) AS INT) FROM w;" | sqlite3)
COND=$(echo "$SQL SELECT cond FROM w GROUP BY cond ORDER BY COUNT(*) DESC LIMIT 1;" | sqlite3)

echo "" >&2

# Generate summary
if [ "$HIGH" -ge 80 ]; then
  SUM="Hot day! Stay cool and hydrated."
elif [ "$HIGH" -ge 65 ]; then
  SUM="Pleasant weather for outdoor activities!"
else
  SUM="Cool day ahead. Layer up!"
fi

# Output
echo "========================================"
echo "   NEW YORK CITY WEATHER"
date "+   %B %d, %Y"
echo "========================================"
echo ""
echo "   HIGH: ${HIGH}F    LOW: ${LOW}F    AVG: ${AVG}F"
echo ""
echo "   $SUM"
echo ""
echo "   Conditions: Mostly $COND"
echo ""
echo "   HOURLY FORECAST"
echo "   ----------------------------"
i=0
cat /tmp/temps.txt | while read t; do
  hour=$((i % 12))
  if [ $hour -eq 0 ]; then
    suffix="am"
    display=12
  elif [ $hour -lt 12 ]; then
    suffix="am"
    display=$hour
  else
    suffix="pm"
    display=$((hour - 12))
    if [ $display -eq 0 ]; then display=12; fi
  fi
  printf "   +%2dh: %s°F\n" "$i" "$t"
  i=$((i + 1))
done
echo ""
echo "========================================"
echo "   Pipeline: curl -> jq -> sqlite3"
echo "========================================"
