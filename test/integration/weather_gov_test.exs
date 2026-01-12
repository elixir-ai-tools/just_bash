defmodule JustBash.Integration.WeatherGovTest do
  @moduledoc """
  Integration tests for Weather.gov API workflows.

  Tests demonstrate realistic two-step API workflows where:
  1. First call to /points/{lat},{lon} returns grid coordinates
  2. Second call to /gridpoints/{office}/{x},{y}/forecast returns weather data

  Mock data is based on real Weather.gov API responses for Central Park, NYC (40.7699, -73.9710).
  """
  use ExUnit.Case, async: true

  defmodule TestHttpClient do
    @moduledoc """
    Test HTTP client that returns canned responses based on URL.
    """
    @behaviour JustBash.HttpClient

    @impl true
    def request(%{url: url} = req) do
      responses = Process.get(:http_responses, %{})

      case Map.get(responses, url) do
        nil ->
          {:error, %{reason: "no response configured for #{url}"}}

        response when is_function(response) ->
          {:ok, response.(req)}

        response when is_map(response) ->
          {:ok,
           %{
             status: Map.get(response, :status, 200),
             headers: Map.get(response, :headers, []),
             body: Map.get(response, :body, "")
           }}
      end
    end
  end

  @points_response Jason.encode!(%{
                     "@context" => ["https://geojson.org/geojson-ld/geojson-context.jsonld"],
                     "id" => "https://api.weather.gov/points/40.7699,-73.971",
                     "type" => "Feature",
                     "geometry" => %{
                       "type" => "Point",
                       "coordinates" => [-73.971, 40.7699]
                     },
                     "properties" => %{
                       "@id" => "https://api.weather.gov/points/40.7699,-73.971",
                       "cwa" => "OKX",
                       "gridId" => "OKX",
                       "gridX" => 34,
                       "gridY" => 38,
                       "forecast" => "https://api.weather.gov/gridpoints/OKX/34,38/forecast",
                       "forecastHourly" =>
                         "https://api.weather.gov/gridpoints/OKX/34,38/forecast/hourly",
                       "relativeLocation" => %{
                         "type" => "Feature",
                         "geometry" => %{
                           "type" => "Point",
                           "coordinates" => [-74.009507, 40.786032]
                         },
                         "properties" => %{
                           "city" => "West New York",
                           "state" => "NJ"
                         }
                       },
                       "timeZone" => "America/New_York"
                     }
                   })

  @forecast_response Jason.encode!(%{
                       "@context" => ["https://geojson.org/geojson-ld/geojson-context.jsonld"],
                       "type" => "Feature",
                       "geometry" => %{
                         "type" => "Polygon",
                         "coordinates" => [
                           [
                             [-73.9589, 40.7636],
                             [-73.9544, 40.7853],
                             [-73.9831, 40.7887],
                             [-73.9876, 40.767],
                             [-73.9589, 40.7636]
                           ]
                         ]
                       },
                       "properties" => %{
                         "units" => "us",
                         "forecastGenerator" => "BaselineForecastGenerator",
                         "generatedAt" => "2026-01-12T16:08:41+00:00",
                         "updateTime" => "2026-01-12T10:36:45+00:00",
                         "periods" => [
                           %{
                             "number" => 1,
                             "name" => "Today",
                             "startTime" => "2026-01-12T11:00:00-05:00",
                             "endTime" => "2026-01-12T18:00:00-05:00",
                             "isDaytime" => true,
                             "temperature" => 42,
                             "temperatureUnit" => "F",
                             "temperatureTrend" => nil,
                             "probabilityOfPrecipitation" => %{
                               "unitCode" => "wmoUnit:percent",
                               "value" => 1
                             },
                             "windSpeed" => "10 mph",
                             "windDirection" => "W",
                             "icon" => "https://api.weather.gov/icons/land/day/few?size=medium",
                             "shortForecast" => "Sunny",
                             "detailedForecast" =>
                               "Sunny. High near 42, with temperatures falling to around 40 in the afternoon. West wind around 10 mph."
                           },
                           %{
                             "number" => 2,
                             "name" => "Tonight",
                             "startTime" => "2026-01-12T18:00:00-05:00",
                             "endTime" => "2026-01-13T06:00:00-05:00",
                             "isDaytime" => false,
                             "temperature" => 34,
                             "temperatureUnit" => "F",
                             "temperatureTrend" => nil,
                             "probabilityOfPrecipitation" => %{
                               "unitCode" => "wmoUnit:percent",
                               "value" => 1
                             },
                             "windSpeed" => "8 mph",
                             "windDirection" => "SW",
                             "icon" => "https://api.weather.gov/icons/land/night/few?size=medium",
                             "shortForecast" => "Mostly Clear",
                             "detailedForecast" =>
                               "Mostly clear, with a low around 34. Southwest wind around 8 mph."
                           },
                           %{
                             "number" => 3,
                             "name" => "Tuesday",
                             "startTime" => "2026-01-13T06:00:00-05:00",
                             "endTime" => "2026-01-13T18:00:00-05:00",
                             "isDaytime" => true,
                             "temperature" => 46,
                             "temperatureUnit" => "F",
                             "temperatureTrend" => nil,
                             "probabilityOfPrecipitation" => %{
                               "unitCode" => "wmoUnit:percent",
                               "value" => 1
                             },
                             "windSpeed" => "7 mph",
                             "windDirection" => "SW",
                             "icon" => "https://api.weather.gov/icons/land/day/sct?size=medium",
                             "shortForecast" => "Mostly Sunny",
                             "detailedForecast" =>
                               "Mostly sunny. High near 46, with temperatures falling to around 44 in the afternoon. Southwest wind around 7 mph."
                           },
                           %{
                             "number" => 4,
                             "name" => "Tuesday Night",
                             "startTime" => "2026-01-13T18:00:00-05:00",
                             "endTime" => "2026-01-14T06:00:00-05:00",
                             "isDaytime" => false,
                             "temperature" => 40,
                             "temperatureUnit" => "F",
                             "temperatureTrend" => nil,
                             "probabilityOfPrecipitation" => %{
                               "unitCode" => "wmoUnit:percent",
                               "value" => 9
                             },
                             "windSpeed" => "7 mph",
                             "windDirection" => "S",
                             "icon" => "https://api.weather.gov/icons/land/night/bkn?size=medium",
                             "shortForecast" => "Mostly Cloudy",
                             "detailedForecast" =>
                               "Mostly cloudy. Low around 40, with temperatures rising to around 42 overnight. South wind around 7 mph."
                           },
                           %{
                             "number" => 5,
                             "name" => "Wednesday",
                             "startTime" => "2026-01-14T06:00:00-05:00",
                             "endTime" => "2026-01-14T18:00:00-05:00",
                             "isDaytime" => true,
                             "temperature" => 49,
                             "temperatureUnit" => "F",
                             "temperatureTrend" => nil,
                             "probabilityOfPrecipitation" => %{
                               "unitCode" => "wmoUnit:percent",
                               "value" => 31
                             },
                             "windSpeed" => "6 mph",
                             "windDirection" => "SW",
                             "icon" =>
                               "https://api.weather.gov/icons/land/day/rain_showers,30?size=medium",
                             "shortForecast" => "Chance Rain Showers",
                             "detailedForecast" =>
                               "A chance of rain showers after 7am. Cloudy. High near 49, with temperatures falling to around 46 in the afternoon. Southwest wind around 6 mph. Chance of precipitation is 30%."
                           },
                           %{
                             "number" => 6,
                             "name" => "Wednesday Night",
                             "startTime" => "2026-01-14T18:00:00-05:00",
                             "endTime" => "2026-01-15T06:00:00-05:00",
                             "isDaytime" => false,
                             "temperature" => 39,
                             "temperatureUnit" => "F",
                             "temperatureTrend" => nil,
                             "probabilityOfPrecipitation" => %{
                               "unitCode" => "wmoUnit:percent",
                               "value" => 44
                             },
                             "windSpeed" => "2 mph",
                             "windDirection" => "W",
                             "icon" =>
                               "https://api.weather.gov/icons/land/night/rain_showers,30/rain_showers,40?size=medium",
                             "shortForecast" => "Chance Rain Showers",
                             "detailedForecast" =>
                               "A chance of rain showers. Cloudy. Low around 39, with temperatures rising to around 42 overnight. Chance of precipitation is 40%."
                           }
                         ]
                       }
                     })

  defp bash_with_responses(responses) do
    Process.put(:http_responses, responses)
    JustBash.new(network: %{enabled: true}, http_client: TestHttpClient)
  end

  defp bash_with_responses_and_files(responses, files) do
    Process.put(:http_responses, responses)
    JustBash.new(network: %{enabled: true}, http_client: TestHttpClient, files: files)
  end

  defp standard_responses do
    %{
      "https://api.weather.gov/points/40.7699,-73.9710" => %{
        status: 200,
        body: @points_response
      },
      "https://api.weather.gov/gridpoints/OKX/34,38/forecast" => %{
        status: 200,
        body: @forecast_response
      }
    }
  end

  describe "Weather.gov API workflows" do
    test "get today's weather from forecast endpoint directly" do
      bash = bash_with_responses(standard_responses())

      {result, _} =
        JustBash.exec(bash, ~S"""
        FORECAST=$(curl -s https://api.weather.gov/gridpoints/OKX/34,38/forecast)
        TODAY=$(echo "$FORECAST" | jq '.properties.periods[0]')
        NAME=$(echo "$TODAY" | jq -r '.name')
        TEMP=$(echo "$TODAY" | jq -r '.temperature')
        UNIT=$(echo "$TODAY" | jq -r '.temperatureUnit')
        COND=$(echo "$TODAY" | jq -r '.shortForecast')
        echo "$NAME: $TEMP $UNIT, $COND"
        """)

      assert result.exit_code == 0
      assert result.stdout == "Today: 42 F, Sunny\n"
    end

    test "two-step workflow: points endpoint to forecast" do
      bash = bash_with_responses(standard_responses())

      {result, _} =
        JustBash.exec(bash, ~S"""
        POINTS=$(curl -s "https://api.weather.gov/points/40.7699,-73.9710")
        FORECAST_URL=$(echo "$POINTS" | jq -r '.properties.forecast')
        curl -s "$FORECAST_URL" | jq -r '.properties.periods[0].shortForecast'
        """)

      assert result.exit_code == 0
      assert result.stdout == "Sunny\n"
    end

    test "get temperature for next 3 periods" do
      bash = bash_with_responses(standard_responses())

      {result, _} =
        JustBash.exec(bash, ~S"""
        FORECAST=$(curl -s https://api.weather.gov/gridpoints/OKX/34,38/forecast)
        echo "$FORECAST" | jq -r '.properties.periods[0] | .name + ": " + (.temperature | tostring) + " F"'
        echo "$FORECAST" | jq -r '.properties.periods[1] | .name + ": " + (.temperature | tostring) + " F"'
        echo "$FORECAST" | jq -r '.properties.periods[2] | .name + ": " + (.temperature | tostring) + " F"'
        """)

      assert result.exit_code == 0
      assert result.stdout == "Today: 42 F\nTonight: 34 F\nTuesday: 46 F\n"
    end

    test "get detailed forecast for today" do
      bash = bash_with_responses(standard_responses())

      {result, _} =
        JustBash.exec(bash, ~S"""
        curl -s https://api.weather.gov/gridpoints/OKX/34,38/forecast | \
          jq -r '.properties.periods[0].detailedForecast'
        """)

      assert result.exit_code == 0

      assert result.stdout ==
               "Sunny. High near 42, with temperatures falling to around 40 in the afternoon. West wind around 10 mph.\n"
    end

    test "get wind information for today" do
      bash = bash_with_responses(standard_responses())

      {result, _} =
        JustBash.exec(bash, ~S"""
        FORECAST=$(curl -s https://api.weather.gov/gridpoints/OKX/34,38/forecast)
        TODAY=$(echo "$FORECAST" | jq '.properties.periods[0]')
        SPEED=$(echo "$TODAY" | jq -r '.windSpeed')
        DIR=$(echo "$TODAY" | jq -r '.windDirection')
        echo "Wind: $SPEED $DIR"
        """)

      assert result.exit_code == 0
      assert result.stdout == "Wind: 10 mph W\n"
    end

    test "full workflow: coordinates to formatted forecast" do
      bash = bash_with_responses(standard_responses())

      {result, _} =
        JustBash.exec(bash, ~S"""
        LAT=40.7699
        LON=-73.9710

        POINTS=$(curl -s "https://api.weather.gov/points/${LAT},${LON}")
        CITY=$(echo "$POINTS" | jq -r '.properties.relativeLocation.properties.city')
        STATE=$(echo "$POINTS" | jq -r '.properties.relativeLocation.properties.state')
        LOCATION="$CITY, $STATE"
        FORECAST_URL=$(echo "$POINTS" | jq -r '.properties.forecast')

        FORECAST=$(curl -s "$FORECAST_URL")
        TODAY=$(echo "$FORECAST" | jq '.properties.periods[0]')

        NAME=$(echo "$TODAY" | jq -r '.name')
        TEMP=$(echo "$TODAY" | jq -r '.temperature')
        UNIT=$(echo "$TODAY" | jq -r '.temperatureUnit')
        COND=$(echo "$TODAY" | jq -r '.shortForecast')

        echo "Weather for $LOCATION"
        echo "$NAME: $TEMP $UNIT, $COND"
        """)

      assert result.exit_code == 0
      assert result.stdout == "Weather for West New York, NJ\nToday: 42 F, Sunny\n"
    end

    test "find periods with rain in forecast" do
      bash = bash_with_responses(standard_responses())

      {result, _} =
        JustBash.exec(bash, ~S"""
        FORECAST=$(curl -s https://api.weather.gov/gridpoints/OKX/34,38/forecast)
        RAINY=$(echo "$FORECAST" | jq '[.properties.periods[] | select(.shortForecast | contains("Rain"))]')
        COUNT=$(echo "$RAINY" | jq 'length')
        i=0
        while [ $i -lt $COUNT ]; do
          NAME=$(echo "$RAINY" | jq -r ".[$i].name")
          COND=$(echo "$RAINY" | jq -r ".[$i].shortForecast")
          echo "$NAME: $COND"
          i=$((i + 1))
        done
        """)

      assert result.exit_code == 0

      expected = """
      Wednesday: Chance Rain Showers
      Wednesday Night: Chance Rain Showers
      """

      assert result.stdout == expected
    end

    test "write weather report to file" do
      bash = bash_with_responses_and_files(standard_responses(), %{})

      script = ~S"""
      LAT=40.7699
      LON=-73.9710

      POINTS=$(curl -s "https://api.weather.gov/points/${LAT},${LON}")
      CITY=$(echo "$POINTS" | jq -r '.properties.relativeLocation.properties.city')
      STATE=$(echo "$POINTS" | jq -r '.properties.relativeLocation.properties.state')
      LOCATION="$CITY, $STATE"
      FORECAST_URL=$(echo "$POINTS" | jq -r '.properties.forecast')

      FORECAST=$(curl -s "$FORECAST_URL")
      TODAY=$(echo "$FORECAST" | jq '.properties.periods[0]')

      TEMP=$(echo "$TODAY" | jq -r '.temperature')
      UNIT=$(echo "$TODAY" | jq -r '.temperatureUnit')
      COND=$(echo "$TODAY" | jq -r '.shortForecast')
      WIND_SPEED=$(echo "$TODAY" | jq -r '.windSpeed')
      WIND_DIR=$(echo "$TODAY" | jq -r '.windDirection')

      echo "Central Park Weather Report" > ~/weather_report.txt
      echo "===========================" >> ~/weather_report.txt
      echo "Location: $LOCATION" >> ~/weather_report.txt
      echo "" >> ~/weather_report.txt
      echo "Today's Forecast:" >> ~/weather_report.txt
      echo "  Temperature: $TEMP $UNIT" >> ~/weather_report.txt
      echo "  Conditions: $COND" >> ~/weather_report.txt
      echo "  Wind: $WIND_SPEED $WIND_DIR" >> ~/weather_report.txt

      echo "Weather report saved to ~/weather_report.txt"
      cat ~/weather_report.txt
      """

      {result, bash} = JustBash.exec(bash, script)

      assert result.exit_code == 0

      expected_report = """
      Central Park Weather Report
      ===========================
      Location: West New York, NJ

      Today's Forecast:
        Temperature: 42 F
        Conditions: Sunny
        Wind: 10 mph W
      """

      assert result.stdout == "Weather report saved to ~/weather_report.txt\n" <> expected_report

      {file_result, _} = JustBash.exec(bash, "cat ~/weather_report.txt")
      assert file_result.exit_code == 0
      assert file_result.stdout == expected_report
    end
  end
end
