#!/bin/bash
# Fetch NYC (Central Park) weather from NWS API
# https://api.weather.gov

curl -s "https://api.weather.gov/gridpoints/OKX/33,37/forecast" -H "User-Agent: JustBash/1.0" > /tmp/forecast.json

name=$(jq -r '.properties.periods[0].name' /tmp/forecast.json)
condition=$(jq -r '.properties.periods[0].shortForecast' /tmp/forecast.json)
temp=$(jq -r '.properties.periods[0].temperature' /tmp/forecast.json)
unit=$(jq -r '.properties.periods[0].temperatureUnit' /tmp/forecast.json)
wind=$(jq -r '.properties.periods[0].windSpeed' /tmp/forecast.json)
wind_dir=$(jq -r '.properties.periods[0].windDirection' /tmp/forecast.json)

echo "NYC Weather ($name): $condition, $temp°$unit, wind $wind $wind_dir"
