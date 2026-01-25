#!/bin/bash
# Generate hacker-style HTML weather briefing
# Usage: ./weather_html.sh [morning_commute_hour] [evening_commute_hour]
# Example: ./weather_html.sh 8 18

MORNING_COMMUTE=${1:-8}
EVENING_COMMUTE=${2:-18}

echo "Fetching weather data..." >&2
curl -s "https://api.weather.gov/points/40.7128,-74.0060" > /tmp/points.json

# Get hourly forecast URL
FORECAST_URL=$(cat /tmp/points.json | jq -r '.properties.forecastHourly')
curl -s "$FORECAST_URL" > /tmp/forecast.json

# Extract 24 hours of data
cat /tmp/forecast.json | jq -r '.properties.periods[:24] | .[] | .temperature' > /tmp/temps.txt
cat /tmp/forecast.json | jq -r '.properties.periods[:24] | .[] | .shortForecast' > /tmp/conds.txt
cat /tmp/forecast.json | jq -r '.properties.periods[:24] | .[] | .windSpeed' > /tmp/wind.txt
cat /tmp/forecast.json | jq -r '.properties.periods[:24] | .[] | .relativeHumidity.value // "N/A"' > /tmp/humidity.txt
cat /tmp/forecast.json | jq -r '.properties.periods[:24] | .[] | .startTime' > /tmp/times.txt

# Get current hour to calculate offsets
CURRENT_HOUR=$(date '+%H' | sed 's/^0//')

# Calculate stats
HIGH=$(sort -rn /tmp/temps.txt | head -1)
LOW=$(sort -n /tmp/temps.txt | head -1)
AVG=$(awk '{ sum += $1; n++ } END { printf "%.0f", sum/n }' /tmp/temps.txt)

# Get current conditions (first entry)
CURRENT_TEMP=$(head -1 /tmp/temps.txt)
CURRENT_COND=$(head -1 /tmp/conds.txt)
CURRENT_WIND=$(head -1 /tmp/wind.txt)
CURRENT_HUMIDITY=$(head -1 /tmp/humidity.txt)

# Calculate commute hours offset from now
MORNING_OFFSET=$((MORNING_COMMUTE - CURRENT_HOUR))
if [ $MORNING_OFFSET -lt 0 ]; then MORNING_OFFSET=$((MORNING_OFFSET + 24)); fi
EVENING_OFFSET=$((EVENING_COMMUTE - CURRENT_HOUR))
if [ $EVENING_OFFSET -lt 0 ]; then EVENING_OFFSET=$((EVENING_OFFSET + 24)); fi

# Get commute conditions
MORNING_TEMP=$(sed -n "$((MORNING_OFFSET + 1))p" /tmp/temps.txt)
MORNING_COND=$(sed -n "$((MORNING_OFFSET + 1))p" /tmp/conds.txt)
MORNING_WIND=$(sed -n "$((MORNING_OFFSET + 1))p" /tmp/wind.txt)

EVENING_TEMP=$(sed -n "$((EVENING_OFFSET + 1))p" /tmp/temps.txt)
EVENING_COND=$(sed -n "$((EVENING_OFFSET + 1))p" /tmp/conds.txt)
EVENING_WIND=$(sed -n "$((EVENING_OFFSET + 1))p" /tmp/wind.txt)

# Check for rain and snow
RAIN_HOUR=""
SNOW_HOUR=""
i=0
while read cond; do
  if echo "$cond" | grep -qi rain; then
    if [ -z "$RAIN_HOUR" ]; then RAIN_HOUR=$i; fi
  fi
  if echo "$cond" | grep -qi snow; then
    if [ -z "$SNOW_HOUR" ]; then SNOW_HOUR=$i; fi
  fi
  i=$((i + 1))
done < /tmp/conds.txt

# Clothing recommendation logic
get_clothing_rec() {
  local temp=$1
  local cond=$2
  local wind=$3
  
  # Extract wind speed number
  local wind_mph=$(echo "$wind" | grep -o '[0-9]*' | head -1)
  wind_mph=${wind_mph:-0}
  
  local layers=""
  local accessories=""
  local footwear=""
  
  # Base layer by temperature
  if [ "$temp" -le 32 ]; then
    layers="Heavy winter coat, thermal base layer, sweater"
    footwear="Insulated waterproof boots"
  elif [ "$temp" -le 45 ]; then
    layers="Winter jacket, long sleeves, light sweater"
    footwear="Closed-toe shoes or boots"
  elif [ "$temp" -le 55 ]; then
    layers="Light jacket or heavy sweater"
    footwear="Comfortable closed shoes"
  elif [ "$temp" -le 65 ]; then
    layers="Light sweater or long-sleeve shirt"
    footwear="Sneakers or casual shoes"
  elif [ "$temp" -le 75 ]; then
    layers="T-shirt or light blouse"
    footwear="Breathable shoes or sandals"
  else
    layers="Light, breathable clothing"
    footwear="Sandals or breathable sneakers"
  fi
  
  # Accessories based on conditions
  accessories=""
  if echo "$cond" | grep -qi "rain\|shower"; then
    accessories="$accessories Umbrella, waterproof jacket."
    footwear="Waterproof shoes or boots"
  fi
  if echo "$cond" | grep -qi "snow"; then
    accessories="$accessories Warm hat, insulated gloves, scarf."
    footwear="Insulated waterproof boots"
  fi
  if [ "$wind_mph" -ge 15 ]; then
    accessories="$accessories Windbreaker layer."
  fi
  if [ "$wind_mph" -ge 25 ]; then
    accessories="$accessories Secure hat, zip pockets."
  fi
  if echo "$cond" | grep -qi "sunny\|clear" && [ "$temp" -ge 70 ]; then
    accessories="$accessories Sunglasses, sunscreen."
  fi
  
  echo "LAYERS: $layers"
  echo "FEET: $footwear"
  if [ -n "$accessories" ]; then
    echo "GEAR:$accessories"
  fi
}

# Get clothing for each commute
MORNING_CLOTHING=$(get_clothing_rec "$MORNING_TEMP" "$MORNING_COND" "$MORNING_WIND")
EVENING_CLOTHING=$(get_clothing_rec "$EVENING_TEMP" "$EVENING_COND" "$EVENING_WIND")

# Start HTML output
cat << 'HEADER'
<!DOCTYPE html>
<html>
<head>
  <title>NYC WEATHER TERMINAL</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: #0a0a0a;
      color: #00ff00;
      font-family: 'Courier New', monospace;
      padding: 20px;
      min-height: 100vh;
    }
    .scanline {
      position: fixed;
      top: 0; left: 0; right: 0; bottom: 0;
      background: repeating-linear-gradient(0deg,
        rgba(0,0,0,0.15), rgba(0,0,0,0.15) 1px,
        transparent 1px, transparent 2px);
      pointer-events: none;
      z-index: 1000;
    }
    .crt { animation: flicker 0.15s infinite; }
    @keyframes flicker { 0% { opacity: 0.97; } 50% { opacity: 1; } 100% { opacity: 0.98; } }
    .terminal {
      border: 1px solid #00ff00;
      padding: 20px;
      max-width: 900px;
      margin: 0 auto;
      box-shadow: 0 0 20px rgba(0,255,0,0.3), inset 0 0 20px rgba(0,255,0,0.1);
    }
    .header { text-align: center; border-bottom: 1px solid #00ff00; padding-bottom: 15px; margin-bottom: 20px; }
    .header h1 { font-size: 24px; text-shadow: 0 0 10px #00ff00; letter-spacing: 4px; }
    .header .subtitle { color: #00aa00; font-size: 12px; margin-top: 5px; }
    .blink { animation: blink 1s infinite; }
    @keyframes blink { 0%, 50% { opacity: 1; } 51%, 100% { opacity: 0; } }
    .section { margin: 20px 0; padding: 15px; border: 1px solid #004400; background: rgba(0,255,0,0.02); }
    .section-title { color: #00ffaa; font-size: 14px; margin-bottom: 10px; text-transform: uppercase; letter-spacing: 2px; }
    .stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; text-align: center; }
    .stat-box { border: 1px solid #003300; padding: 15px; }
    .stat-value { font-size: 36px; text-shadow: 0 0 15px #00ff00; }
    .stat-label { color: #006600; font-size: 11px; margin-top: 5px; }
    .stat-sub { color: #005500; font-size: 10px; margin-top: 3px; }
    .hourly { display: grid; grid-template-columns: repeat(6, 1fr); gap: 8px; }
    .hour-block { border: 1px solid #003300; padding: 8px; text-align: center; font-size: 11px; }
    .hour-block .temp { font-size: 18px; color: #00ff00; }
    .hour-block .time { color: #006600; font-size: 10px; }
    .hour-block .cond { color: #00aa00; font-size: 8px; margin-top: 3px; }
    .hour-block .wind { color: #004400; font-size: 8px; }
    .hour-block.rain { border-color: #ff6600; }
    .hour-block.rain .temp, .hour-block.rain .time, .hour-block.rain .cond { color: #ff6600; }
    .hour-block.commute { border-color: #00ffff; border-width: 2px; background: rgba(0,255,255,0.05); }
    .hour-block.commute .time { color: #00ffff; font-weight: bold; }
    .rain-alert { background: rgba(255,100,0,0.1); border: 1px solid #ff6600; color: #ff6600; padding: 15px; text-align: center; margin: 20px 0; }
    .rain-alert .icon { font-size: 24px; }
    .commute-section { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
    .commute-box { border: 1px solid #00aaaa; padding: 15px; background: rgba(0,255,255,0.02); }
    .commute-box h3 { color: #00ffff; font-size: 14px; margin-bottom: 10px; letter-spacing: 2px; }
    .commute-box .weather { margin-bottom: 15px; }
    .commute-box .temp-big { font-size: 32px; color: #00ffff; text-shadow: 0 0 10px #00ffff; }
    .commute-box .details { color: #008888; font-size: 11px; }
    .clothing { border-top: 1px solid #004444; margin-top: 10px; padding-top: 10px; font-size: 11px; }
    .clothing div { margin: 4px 0; color: #00aa88; }
    .clothing span { color: #006666; }
    .prompt { margin-top: 20px; color: #00aa00; }
    .cursor { display: inline-block; width: 10px; height: 16px; background: #00ff00; animation: blink 0.7s infinite; vertical-align: middle; }
    .log { font-size: 11px; color: #005500; margin-top: 20px; border-top: 1px solid #003300; padding-top: 10px; }
    .log .ts { color: #003300; }
  </style>
</head>
<body>
<div class="scanline"></div>
<div class="crt">
<div class="terminal">
  <div class="header">
    <h1>▓▓▓ NYC WEATHER GRID ▓▓▓</h1>
    <div class="subtitle">NATIONAL WEATHER SERVICE // CLASSIFIED FEED</div>
    <div class="subtitle">LAT: 40.7128 // LON: -74.0060 // GRID: OKX/33,35</div>
    <div class="subtitle" style="margin-top:10px"><span class="blink">●</span> LIVE UPLINK ESTABLISHED</div>
  </div>
HEADER

# Stats section
DATE_STR=$(date '+%Y-%m-%d %H:%M:%S')
cat << EOF
  <div class="section">
    <div class="section-title">► CURRENT CONDITIONS // ${DATE_STR}</div>
    <div class="stats">
      <div class="stat-box">
        <div class="stat-value">${CURRENT_TEMP}°</div>
        <div class="stat-label">CURRENT [F]</div>
        <div class="stat-sub">${CURRENT_COND}</div>
      </div>
      <div class="stat-box">
        <div class="stat-value">${HIGH}°/${LOW}°</div>
        <div class="stat-label">HIGH / LOW</div>
        <div class="stat-sub">24-hour range</div>
      </div>
      <div class="stat-box">
        <div class="stat-value">${CURRENT_WIND}</div>
        <div class="stat-label">WIND</div>
        <div class="stat-sub">Humidity: ${CURRENT_HUMIDITY}%</div>
      </div>
    </div>
  </div>
EOF

# Rain/Snow alert if applicable
if [ -n "$RAIN_HOUR" ] || [ -n "$SNOW_HOUR" ]; then
  echo '  <div class="rain-alert">'
  if [ -n "$SNOW_HOUR" ]; then
    cat << EOF
    <div class="icon">⚠ ❄ ⚠</div>
    <div style="margin-top:10px">
      <strong>WINTER WEATHER ADVISORY</strong><br>
      <span style="font-size:12px">SNOW DETECTED // T+${SNOW_HOUR}H ONWARDS</span><br>
      <span style="font-size:10px;color:#aa4400">RECOMMEND: WINTER GEAR, ALLOW EXTRA TRAVEL TIME</span>
    </div>
EOF
  elif [ -n "$RAIN_HOUR" ]; then
    cat << EOF
    <div class="icon">⚠ ☔ ⚠</div>
    <div style="margin-top:10px">
      <strong>PRECIPITATION ADVISORY</strong><br>
      <span style="font-size:12px">RAIN SHOWERS DETECTED // T+${RAIN_HOUR}H ONWARDS</span><br>
      <span style="font-size:10px;color:#aa4400">RECOMMEND: UMBRELLA, WATERPROOF LAYER</span>
    </div>
EOF
  fi
  echo '  </div>'
fi

# Commute Planner Section
format_hour() {
  local h=$1
  if [ $h -eq 0 ]; then echo "12AM"
  elif [ $h -lt 12 ]; then echo "${h}AM"
  elif [ $h -eq 12 ]; then echo "12PM"
  else echo "$((h-12))PM"
  fi
}

MORNING_LABEL=$(format_hour $MORNING_COMMUTE)
EVENING_LABEL=$(format_hour $EVENING_COMMUTE)

cat << EOF
  <div class="section">
    <div class="section-title">► COMMUTE PLANNER</div>
    <div class="commute-section">
      <div class="commute-box">
        <h3>☀ MORNING // ${MORNING_LABEL}</h3>
        <div class="weather">
          <span class="temp-big">${MORNING_TEMP}°F</span>
          <div class="details">${MORNING_COND}</div>
          <div class="details">Wind: ${MORNING_WIND}</div>
        </div>
        <div class="clothing">
          <div><span>▸</span> $(echo "$MORNING_CLOTHING" | grep "LAYERS:" | sed 's/LAYERS: //')</div>
          <div><span>▸</span> $(echo "$MORNING_CLOTHING" | grep "FEET:" | sed 's/FEET: //')</div>
EOF
MORNING_GEAR=$(echo "$MORNING_CLOTHING" | grep "GEAR:" | sed 's/GEAR: //')
if [ -n "$MORNING_GEAR" ]; then
  echo "          <div><span>▸</span> ${MORNING_GEAR}</div>"
fi
cat << EOF
        </div>
      </div>
      <div class="commute-box">
        <h3>☽ EVENING // ${EVENING_LABEL}</h3>
        <div class="weather">
          <span class="temp-big">${EVENING_TEMP}°F</span>
          <div class="details">${EVENING_COND}</div>
          <div class="details">Wind: ${EVENING_WIND}</div>
        </div>
        <div class="clothing">
          <div><span>▸</span> $(echo "$EVENING_CLOTHING" | grep "LAYERS:" | sed 's/LAYERS: //')</div>
          <div><span>▸</span> $(echo "$EVENING_CLOTHING" | grep "FEET:" | sed 's/FEET: //')</div>
EOF
EVENING_GEAR=$(echo "$EVENING_CLOTHING" | grep "GEAR:" | sed 's/GEAR: //')
if [ -n "$EVENING_GEAR" ]; then
  echo "          <div><span>▸</span> ${EVENING_GEAR}</div>"
fi
cat << EOF
        </div>
      </div>
    </div>
  </div>
EOF

# Hourly forecast - show 24 hours
echo '  <div class="section">'
echo '    <div class="section-title">► 24-HOUR PROJECTION MATRIX</div>'
echo '    <div class="hourly">'

# Read temps and conditions together
i=0
while read temp; do
  cond=$(sed -n "$((i+1))p" /tmp/conds.txt)
  wind=$(sed -n "$((i+1))p" /tmp/wind.txt | grep -o '[0-9]*' | head -1)
  
  # Calculate actual hour
  actual_hour=$(( (CURRENT_HOUR + i) % 24 ))
  if [ $actual_hour -eq 0 ]; then
    hour_label="12a"
  elif [ $actual_hour -lt 12 ]; then
    hour_label="${actual_hour}a"
  elif [ $actual_hour -eq 12 ]; then
    hour_label="12p"
  else
    hour_label="$((actual_hour-12))p"
  fi
  
  # Shorten condition text
  short_cond=$(echo "$cond" | sed 's/Slight Chance //' | sed 's/Chance //' | cut -c1-10)
  
  # Determine classes
  classes="hour-block"
  icon=""
  
  if echo "$cond" | grep -qi snow; then
    classes="$classes rain"
    icon="❄"
  elif echo "$cond" | grep -qi rain; then
    classes="$classes rain"
    icon="☔"
  fi
  
  # Highlight commute hours
  if [ $actual_hour -eq $MORNING_COMMUTE ] || [ $actual_hour -eq $EVENING_COMMUTE ]; then
    classes="$classes commute"
  fi
  
  echo "      <div class=\"${classes}\">"
  echo "        <div class=\"time\">${hour_label}</div>"
  echo "        <div class=\"temp\">${temp}°</div>"
  echo "        <div class=\"cond\">${icon} ${short_cond}</div>"
  echo "        <div class=\"wind\">${wind}mph</div>"
  echo "      </div>"
  
  i=$((i + 1))
  # Stop at 24 hours
  if [ $i -ge 24 ]; then break; fi
done < /tmp/temps.txt

echo '    </div>'
echo '  </div>'

# Daily summary
get_day_summary() {
  local high=$1
  local low=$2
  local has_rain=$3
  local has_snow=$4
  
  local temp_desc=""
  local precip_desc=""
  local advice=""
  
  # Temperature description
  if [ $high -ge 90 ]; then
    temp_desc="HOT"
    advice="Stay hydrated, seek shade, avoid midday sun"
  elif [ $high -ge 80 ]; then
    temp_desc="WARM"
    advice="Great for outdoor activities"
  elif [ $high -ge 65 ]; then
    temp_desc="PLEASANT"
    advice="Ideal conditions for most activities"
  elif [ $high -ge 50 ]; then
    temp_desc="COOL"
    advice="Layer up, bring a jacket"
  elif [ $high -ge 32 ]; then
    temp_desc="COLD"
    advice="Dress warmly, limit exposure"
  else
    temp_desc="FREEZING"
    advice="Bundle up, watch for ice"
  fi
  
  # Precipitation
  if [ -n "$has_snow" ]; then
    precip_desc="SNOW EXPECTED"
    advice="$advice. Allow extra travel time"
  elif [ -n "$has_rain" ]; then
    precip_desc="RAIN LIKELY"
    advice="$advice. Carry umbrella"
  else
    precip_desc="DRY"
  fi
  
  echo "TEMP_DESC=$temp_desc"
  echo "PRECIP_DESC=$precip_desc"
  echo "ADVICE=$advice"
}

eval $(get_day_summary $HIGH $LOW "$RAIN_HOUR" "$SNOW_HOUR")

cat << EOF
  <div class="section">
    <div class="section-title">► DAILY BRIEFING</div>
    <pre style="color:#00aa00;font-size:12px">
┌─────────────────────────────────────────────────────────────┐
│  CONDITIONS: ${TEMP_DESC} // ${PRECIP_DESC}
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Temperature Range: ${LOW}°F - ${HIGH}°F (Δ$((HIGH-LOW))°)
│  Current: ${CURRENT_TEMP}°F, ${CURRENT_COND}
│  Wind: ${CURRENT_WIND}, Humidity: ${CURRENT_HUMIDITY}%
│                                                             │
├─────────────────────────────────────────────────────────────┤
│  ADVICE: ${ADVICE}
└─────────────────────────────────────────────────────────────┘
    </pre>
  </div>
EOF

# Log section
TS=$(date '+%H:%M:%S')
cat << EOF
  <div class="log">
    <div><span class="ts">[${TS}]</span> Uplink to api.weather.gov established</div>
    <div><span class="ts">[${TS}]</span> Grid coordinates verified: OKX/33,35</div>
    <div><span class="ts">[${TS}]</span> Forecast data parsed via jq processor</div>
    <div><span class="ts">[${TS}]</span> Report generated // END TRANSMISSION</div>
  </div>
  <div class="prompt">root@weather-grid:~# <span class="cursor"></span></div>
</div>
</div>
</body>
</html>
EOF
