#!/bin/bash
# Fetch NYC hourly forecast from NWS API and load into SQLite

# Fetch hourly forecast, convert to CSV, load into SQLite
curl -s "https://api.weather.gov/gridpoints/OKX/33,37/forecast/hourly" \
  -H "User-Agent: JustBash/1.0" \
  | jq -r '["time","temp","humidity","wind","condition"],
           (.properties.periods[] | [.startTime, .temperature, .relativeHumidity.value, .windSpeed, .shortForecast])
           | @csv' \
  | sqlite3 weather ".import /dev/stdin forecast"

# Queries
echo "=== Next 12 Hours ==="
sqlite3 weather "SELECT substr(time, 12, 5) as hour, temp || '°F' as temp, condition FROM forecast LIMIT 12"

echo ""
echo "=== Temperature Range ==="
sqlite3 weather "SELECT min(temp) || '°F - ' || max(temp) || '°F' as range FROM forecast"

echo ""
echo "=== Hours Above 40°F ==="
sqlite3 weather "SELECT count(*) || ' hours' FROM forecast WHERE temp > 40"

# Show the table
echo "=== Next 12 Hours ==="
sqlite3 weather "SELECT substr(time, 12, 5) as hour, temp || '°F' as temp, condition FROM forecast LIMIT 12"

echo ""
echo "=== Temperature Range ==="
sqlite3 weather "SELECT min(temp) || '°F - ' || max(temp) || '°F' as range FROM forecast"

echo ""
echo "=== Hours Above 40°F ==="
sqlite3 weather "SELECT count(*) || ' hours' FROM forecast WHERE temp > 40"
