"""Local weather from Open-Meteo (free, no API key) and the spray / disease-pressure facts derived from it.

The facts are computed here with simple agronomy rules, so the LLM is given conclusions ("no spray window,
rain tomorrow") rather than having to reason over 48 hourly numbers, which small models do badly.
"""

import logging
from datetime import date

import httpx

from app.config import settings

log = logging.getLogger("uvicorn.error")

HOURLY = "temperature_2m,relative_humidity_2m,precipitation_probability,precipitation,wind_speed_10m,is_day"
CURRENT = "temperature_2m,relative_humidity_2m,precipitation,wind_speed_10m"

# Spray window: dry, calm, mild daylight hours.
SPRAY_MAX_RAIN_PROB = 30
SPRAY_MAX_WIND_KMH = 15
SPRAY_TEMP_RANGE_C = (10, 30)
SPRAY_MIN_HOURS = 4
# Leaf spot: leaf wetness (very humid or rain). Powdery mildew: warm, moderately humid, dry leaves.
WET_RH = 90
WET_RAIN_MM = 0.1
MILDEW_TEMP_C = (15, 28)
MILDEW_RH = (50, 90)


FORECAST_DAYS = 7
# Daily risk score (0–100) = favourable hours that day / these hours, capped. ≥ 67 high, ≥ 34 medium.
LEAF_SPOT_FULL_RISK_HOURS = 8  # hours of leaf wetness
MILDEW_FULL_RISK_HOURS = 12  # warm, moderately humid, dry hours
# Trend: mean risk of the later days vs the first three, in score points.
TREND_THRESHOLD = 15


def fetch_weather(lat: float, lon: float) -> dict | None:
    """Current conditions + 7-day hourly forecast in the location's timezone, or None if unavailable."""
    params = {
        "latitude": lat,
        "longitude": lon,
        "current": CURRENT,
        "hourly": HOURLY,
        "forecast_days": FORECAST_DAYS,
        "timezone": "auto",
        "wind_speed_unit": "kmh",
    }
    try:
        res = httpx.get(settings.weather_api_url, params=params, timeout=settings.weather_timeout_s)
        res.raise_for_status()
        return res.json()
    except (httpx.HTTPError, ValueError) as e:
        log.warning("Weather lookup failed for %.2f,%.2f: %s", lat, lon, e)
        return None


def _num(values: list, i: int, default: float = 0.0) -> float:
    v = values[i] if i < len(values) else None
    return default if v is None else float(v)


def _pressure(hours: int, medium: int, high: int) -> str:
    return "high" if hours >= high else "medium" if hours >= medium else "low"


def _day_label(day: str, today: str) -> str:
    delta = (date.fromisoformat(day) - date.fromisoformat(today)).days
    return {0: "Today", 1: "Tomorrow"}.get(delta, date.fromisoformat(day).strftime("%a %d %b"))


class _Hours:
    """Hourly Open-Meteo series with the per-hour agronomy rules. Missing values never count as favourable."""

    def __init__(self, weather: dict):
        hourly = weather.get("hourly") or {}
        self.times: list[str] = hourly.get("time") or []
        self.temp = hourly.get("temperature_2m") or []
        self.rh = hourly.get("relative_humidity_2m") or []
        self.prob = hourly.get("precipitation_probability") or []
        self.rain = hourly.get("precipitation") or []
        self.wind = hourly.get("wind_speed_10m") or []
        self.is_day = hourly.get("is_day") or []

    def sprayable(self, i: int) -> bool:
        return (
            _num(self.prob, i, 100) < SPRAY_MAX_RAIN_PROB
            and _num(self.wind, i, 99) < SPRAY_MAX_WIND_KMH
            and SPRAY_TEMP_RANGE_C[0] <= _num(self.temp, i, -99) <= SPRAY_TEMP_RANGE_C[1]
            and _num(self.is_day, i, 1) == 1
        )

    def leaf_wet(self, i: int) -> bool:
        return _num(self.rh, i) >= WET_RH or _num(self.rain, i) >= WET_RAIN_MM

    def mildew_favourable(self, i: int) -> bool:
        return (
            MILDEW_TEMP_C[0] <= _num(self.temp, i, -99) <= MILDEW_TEMP_C[1]
            and MILDEW_RH[0] <= _num(self.rh, i) <= MILDEW_RH[1]
            and _num(self.rain, i) < WET_RAIN_MM
        )

    def spray_runs(self, hours) -> list[list[int]]:
        """Runs of ≥ SPRAY_MIN_HOURS consecutive sprayable hours, in order."""
        runs, run = [], []
        for i in [*hours, None]:  # trailing None flushes the last run
            if i is not None and self.sprayable(i):
                run.append(i)
                continue
            if len(run) >= SPRAY_MIN_HOURS:
                runs.append(run)
            run = []
        return runs


def derive_conditions(weather: dict) -> dict:
    """WeatherSummary fields from an Open-Meteo response, looking 48 h ahead from the current hour."""
    current = weather.get("current") or {}
    h = _Hours(weather)
    times = h.times

    # Hourly data starts at local midnight; start from the current hour.
    now = current.get("time") or (times[0] if times else "")
    start = next((i for i, t in enumerate(times) if t[:13] >= now[:13]), 0)
    next_24 = range(start, min(start + 24, len(times)))
    next_48 = range(start, min(start + 48, len(times)))

    rain_mm_24h = round(sum(_num(h.rain, i) for i in next_24), 1)
    rain_expected_24h = rain_mm_24h >= 1.0 or any(_num(h.prob, i) >= 50 for i in next_24)
    max_wind = max((_num(h.wind, i) for i in next_24), default=None)

    spray_window = None
    runs = h.spray_runs(next_48)
    if runs:
        first, last = times[runs[0][0]], times[runs[0][-1]]
        end_hour = (int(last[11:13]) + 1) % 24
        spray_window = f"{_day_label(first[:10], now[:10])} {first[11:16]}–{end_hour:02d}:00"

    wet_hours = sum(1 for i in next_48 if h.leaf_wet(i))
    mildew_hours = sum(1 for i in next_48 if h.mildew_favourable(i))

    return {
        "temperature_c": current.get("temperature_2m"),
        "humidity_pct": current.get("relative_humidity_2m"),
        "wind_kmh": current.get("wind_speed_10m"),
        "rain_expected_24h": rain_expected_24h,
        "rain_mm_24h": rain_mm_24h,
        "max_wind_kmh_24h": max_wind,
        "spray_window": spray_window,
        "leaf_spot_pressure": _pressure(wet_hours, medium=6, high=12),
        "powdery_mildew_pressure": _pressure(mildew_hours, medium=10, high=24),
    }


def _risk_score(hours: int, full: int) -> int:
    return min(100, round(100 * hours / full))


def risk_level(score: float) -> str:
    return "high" if score >= 67 else "medium" if score >= 34 else "low"


def _trend(scores: list[int]) -> str:
    """Later days vs the first three: is the weather getting more or less favourable for the disease?"""
    if len(scores) < 4:
        return "steady"
    diff = sum(scores[3:]) / len(scores[3:]) - sum(scores[:3]) / 3
    return "rising" if diff >= TREND_THRESHOLD else "falling" if diff <= -TREND_THRESHOLD else "steady"


def risk_forecast(weather: dict) -> dict:
    """Day-by-day weather risk of each disease spreading, for the next FORECAST_DAYS days (RiskForecast fields).

    Risk is about the weather only (does it favour infection and spread?), not about how much disease there is:
    - leaf spot: hours of leaf wetness (RH ≥ 90 % or rain); LEAF_SPOT_FULL_RISK_HOURS a day = 100.
    - powdery mildew: warm (15–28 °C), moderately humid (50–90 %), dry hours; MILDEW_FULL_RISK_HOURS a day = 100.
    """
    h = _Hours(weather)
    today = ((weather.get("current") or {}).get("time") or (h.times[0] if h.times else ""))[:10]
    by_day: dict[str, list[int]] = {}
    for i, t in enumerate(h.times):
        if t[:10] >= today:
            by_day.setdefault(t[:10], []).append(i)

    days = []
    for day, hours in list(by_day.items())[:FORECAST_DAYS]:
        temps = [_num(h.temp, i) for i in hours if i < len(h.temp) and h.temp[i] is not None]
        rhs = [_num(h.rh, i) for i in hours if i < len(h.rh) and h.rh[i] is not None]
        leaf = _risk_score(sum(1 for i in hours if h.leaf_wet(i)), LEAF_SPOT_FULL_RISK_HOURS)
        mildew = _risk_score(sum(1 for i in hours if h.mildew_favourable(i)), MILDEW_FULL_RISK_HOURS)
        days.append(
            {
                "date": day,
                "label": {0: "Today", 1: "Tomorrow"}.get(
                    (date.fromisoformat(day) - date.fromisoformat(today)).days, date.fromisoformat(day).strftime("%a")
                ),
                "weekday": date.fromisoformat(day).strftime("%a"),
                "powdery_mildew_risk": mildew,
                "powdery_mildew_level": risk_level(mildew),
                "leaf_spot_risk": leaf,
                "leaf_spot_level": risk_level(leaf),
                "rain_mm": round(sum(_num(h.rain, i) for i in hours), 1),
                "rain_probability_max": round(max((_num(h.prob, i) for i in hours), default=0)),
                "temp_min_c": round(min(temps), 1) if temps else None,
                "temp_max_c": round(max(temps), 1) if temps else None,
                "humidity_mean_pct": round(sum(rhs) / len(rhs)) if rhs else None,
                "spray_ok": bool(h.spray_runs(hours)),
            }
        )

    trends = {}
    for disease in ("powdery_mildew", "leaf_spot"):
        scores = [d[f"{disease}_risk"] for d in days]
        peak = max(days, key=lambda d: d[f"{disease}_risk"]) if days else None
        trends[disease] = {
            "direction": _trend(scores),
            "peak_day": peak["label"] if peak and peak[f"{disease}_risk"] > 0 else None,
            "peak_risk": peak[f"{disease}_risk"] if peak else 0,
            "high_risk_days": [d["label"] for d in days if d[f"{disease}_level"] == "high"],
        }
    return {"days": days, "trends": trends}
