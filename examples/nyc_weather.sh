#!/bin/bash
# Fetch NYC (Central Park) weather from NWS API
# https://api.weather.gov

curl -s "https://api.weather.gov/gridpoints/OKX/33,37/forecast" -H "User-Agent: JustBash/1.0" \
  | jq -r '.properties.periods[0] | "NYC Weather (\(.name)): \(.shortForecast), \(.temperature)°\(.temperatureUnit), wind \(.windSpeed) \(.windDirection)"'
