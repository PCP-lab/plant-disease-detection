"""Management tips: weather rules, LLM reply grounding, and the /scans/{id}/advice endpoint (no network)."""

import base64
import json
from datetime import datetime, timedelta

import httpx
import pytest

from app import advice, weather
from app.advice import parse_reply
from app.config import settings

START = datetime(2026, 11, 5, 0, 0)


def forecast(hours=72, now="2026-11-05T08:15", **overrides) -> dict:
    """Open-Meteo-shaped response: dry, calm, 20 °C / 60 % daytime (06–18) hours unless overridden.
    Each override is a function hour_index -> value for that hourly variable."""
    times = [(START + timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M") for h in range(hours)]
    series = {
        "temperature_2m": lambda h: 20.0,
        "relative_humidity_2m": lambda h: 60.0,
        "precipitation_probability": lambda h: 0,
        "precipitation": lambda h: 0.0,
        "wind_speed_10m": lambda h: 5.0,
        "is_day": lambda h: 1 if 6 <= h % 24 < 18 else 0,
        **overrides,
    }
    return {
        "current": {"time": now, "temperature_2m": 19.5, "relative_humidity_2m": 62, "wind_speed_10m": 4.0},
        "hourly": {"time": times, **{k: [f(h) for h in range(hours)] for k, f in series.items()}},
    }


def test_spray_window_starts_at_current_hour():
    c = weather.derive_conditions(forecast())
    assert c["spray_window"] == "Today 08:00–18:00"
    assert c["rain_expected_24h"] is False
    assert c["temperature_c"] == 19.5


def test_rain_today_pushes_window_to_tomorrow():
    rainy_today = lambda h: 80 if h < 24 else 0  # noqa: E731
    c = weather.derive_conditions(forecast(precipitation_probability=rainy_today))
    assert c["rain_expected_24h"] is True
    assert c["spray_window"] == "Tomorrow 06:00–18:00"


def test_no_window_when_always_windy():
    c = weather.derive_conditions(forecast(wind_speed_10m=lambda h: 25.0))
    assert c["spray_window"] is None
    assert c["max_wind_kmh_24h"] == 25.0


def test_humid_weather_raises_leaf_spot_pressure():
    assert weather.derive_conditions(forecast())["leaf_spot_pressure"] == "low"
    humid = weather.derive_conditions(forecast(relative_humidity_2m=lambda h: 95.0))
    assert humid["leaf_spot_pressure"] == "high"
    # Wet leaves (RH > 90 %) are outside the mildew band.
    assert humid["powdery_mildew_pressure"] == "low"
    assert weather.derive_conditions(forecast())["powdery_mildew_pressure"] == "high"


def test_risk_forecast_daily_scores():
    out = weather.risk_forecast(forecast(hours=168))
    days = out["days"]
    assert [d["label"] for d in days[:3]] == ["Today", "Tomorrow", "Sat"]  # 2026-11-05 is a Thursday
    assert len(days) == 7
    # Dry, 20 °C, 60 % all day: ideal for mildew, no leaf wetness.
    assert days[0]["powdery_mildew_risk"] == 100 and days[0]["powdery_mildew_level"] == "high"
    assert days[0]["leaf_spot_risk"] == 0 and days[0]["leaf_spot_level"] == "low"
    assert days[0]["spray_ok"] is True and days[0]["temp_max_c"] == 20.0
    assert out["trends"]["powdery_mildew"]["direction"] == "steady"
    assert out["trends"]["leaf_spot"]["peak_day"] is None


def test_risk_forecast_trend_when_wet_spell_arrives():
    # From day 3 on: humid and rainy → leaf spot rises, mildew falls, no spraying.
    wet_later = dict(
        relative_humidity_2m=lambda h: 95.0 if h >= 72 else 60.0,
        precipitation=lambda h: 1.0 if h >= 72 else 0.0,
        precipitation_probability=lambda h: 90 if h >= 72 else 0,
    )
    out = weather.risk_forecast(forecast(hours=168, **wet_later))
    assert out["trends"]["leaf_spot"]["direction"] == "rising"
    assert out["trends"]["powdery_mildew"]["direction"] == "falling"
    assert out["trends"]["leaf_spot"]["high_risk_days"] == ["Sun", "Mon", "Tue", "Wed"]
    assert out["days"][3]["rain_mm"] == 24.0 and out["days"][3]["spray_ok"] is False


def test_risk_forecast_endpoint(client, monkeypatch):
    monkeypatch.setattr(weather, "fetch_weather", lambda lat, lon: forecast(hours=168))
    res = client.get("/risk-forecast", params={"lat": 17.4, "lon": 78.5})
    assert res.status_code == 200, res.text
    assert len(res.json()["days"]) == 7

    monkeypatch.setattr(weather, "fetch_weather", lambda lat, lon: None)
    assert client.get("/risk-forecast", params={"lat": 17.4, "lon": 78.5}).status_code == 503
    assert client.get("/risk-forecast", params={"lat": 17.4}).status_code == 422


def test_risk_forecast_requires_token(firebase_mode, anon_client):
    assert anon_client.get("/risk-forecast", params={"lat": 1, "lon": 1}).status_code == 401


def test_derive_conditions_tolerates_missing_data():
    c = weather.derive_conditions({})
    assert c["spray_window"] is None and c["leaf_spot_pressure"] == "low"


SCAN = {
    "id": "scan0",
    "status": "ok",
    "primary": {
        "powdery_mildew_pct": 12.0,
        "leaf_spot_pct": 0.0,
        "healthy_pct": 88.0,
        "severity": {"powdery_mildew": "moderate", "leaf_spot": "none"},
    },
    "leaves": [],
}

LLM_REPLY = {
    "summary": "Moderate powdery mildew; warm dry weather favours it.",
    "urgency": "high",
    "actions": ["Remove the worst leaves", "Spray sulfur in the morning window"],
    "treatments": [
        {"name": "Wettable sulphur", "type": "organic", "how": "Spray early morning", "frac_group": "99"},
        {"name": "Myclobutanil 10% WP", "type": "conventional", "how": "If it spreads"},
        {"name": "Miracle-Cure 3000", "type": "conventional", "how": "Invented product"},
        {"name": "Copper hydroxide", "type": "organic", "how": "Not for mildew"},
        {"name": "Prune for air flow", "type": "cultural", "how": "Open the canopy"},
    ],
    "spray_timing": "Spray today 08:00–18:00.",
    "prevention": ["Avoid excess nitrogen"],
}


def test_parse_reply_keeps_only_grounded_products():
    tips = parse_reply("```json\n" + json.dumps(LLM_REPLY) + "\n```", SCAN)
    names = [(t["name"], t["type"], t["frac_group"]) for t in tips["treatments"]]
    assert names == [
        ("Sulfur (wettable)", "organic", "M2"),  # FRAC from the guide, not the model
        ("Myclobutanil", "conventional", "3"),
        ("Prune for air flow", "cultural", None),
    ]  # invented product and the leaf-spot-only copper are dropped
    assert tips["urgency"] == "high"


def test_parse_reply_rejects_garbage():
    with pytest.raises(ValueError):
        parse_reply("I think you should spray something.", SCAN)
    with pytest.raises(ValueError):
        parse_reply('{"urgency": "high"}', SCAN)


def test_parse_reply_falls_back_on_bad_urgency():
    assert parse_reply(json.dumps({**LLM_REPLY, "urgency": "very"}), SCAN)["urgency"] == "high"


def test_healthy_scan_prompt_offers_both_diseases():
    healthy = {**SCAN, "primary": {**SCAN["primary"], "severity": {"powdery_mildew": "none", "leaf_spot": "none"}}}
    context = json.loads(advice.build_messages(healthy, None, None)[1]["content"])
    assert len(context["allowed_treatments"]) == 2
    assert context["weather"].startswith("unavailable")


# --- endpoint ---------------------------------------------------------------------------------


VISION_REPLY = {
    "crop_guess": "tomato",
    "symptoms": "Small brown circular spots with yellow halos on the upper leaf.",
    "other_issues": "none",
    "image_quality": "good",
}


def chat_reply(content: dict) -> httpx.Response:
    return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(content)}}]})


@pytest.fixture
def fake_llm(monkeypatch):
    """Replaces both LLM calls (vision model → VISION_REPLY, text model → LLM_REPLY); records request bodies."""
    calls = []

    def post(url, json, headers, timeout):
        calls.append(json)
        return chat_reply(VISION_REPLY if json["model"] == settings.llm_vision_model else LLM_REPLY)

    monkeypatch.setattr(advice.httpx, "post", post)
    return calls


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


@pytest.fixture
def scan_id(client, jpeg_bytes):
    return client.post("/scans", files={"image": ("leaf.jpg", jpeg_bytes, "image/jpeg")}).json()["id"]


def test_advice_with_weather(client, scan_id, fake_llm, monkeypatch):
    monkeypatch.setattr(weather, "fetch_weather", lambda lat, lon: forecast())
    res = client.post(f"/scans/{scan_id}/advice", json={"lat": 17.4, "lon": 78.5, "crop": " tomato "})
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["weather"]["spray_window"] == "Today 08:00–18:00"
    assert body["disclaimer"] and body["model"]
    # The prompt carries the crop, the scan and the derived weather facts.
    context = json.loads(fake_llm[0]["messages"][1]["content"])
    assert context["crop"] == "tomato"
    assert context["weather"]["leaf_spot_pressure"] == "low"
    assert context["scan"]["largest_leaf"]["leaf_spot_pct"] == 1.0


def test_advice_uses_photo_results_and_weather(client, scan_id, fake_llm, monkeypatch, jpeg_bytes):
    """Photo → vision model; its observations + scan results + weather → text model."""
    monkeypatch.setattr(weather, "fetch_weather", lambda lat, lon: forecast())
    res = client.post(
        f"/scans/{scan_id}/advice", json={"lat": 17.4, "lon": 78.5, "image_jpeg_b64": b64(jpeg_bytes)}
    )
    assert res.status_code == 200, res.text
    body = res.json()

    vision_call, text_call = fake_llm
    assert vision_call["model"] == settings.llm_vision_model
    image_part = vision_call["messages"][0]["content"][1]
    assert image_part["image_url"]["url"].startswith("data:image/jpeg;base64,/9j/")  # a JPEG

    context = json.loads(text_call["messages"][1]["content"])
    assert context["photo_observations"]["symptoms"] == VISION_REPLY["symptoms"]
    assert context["scan"]["largest_leaf"]["leaf_spot_pct"] == 1.0
    assert context["weather"]["spray_window"] == "Today 08:00–18:00"
    assert context["crop"].startswith("probably tomato")  # guessed from the photo when not given
    assert context["week_outlook"]["days"][0].startswith("Today: mildew high, leaf spot low")

    assert body["photo_observations"] == VISION_REPLY["symptoms"]
    assert body["photo_note"] is None
    assert body["vision_model"] == settings.llm_vision_model


def test_advice_vision_model_missing_still_gives_tips(client, scan_id, monkeypatch, jpeg_bytes):
    def post(url, json, headers, timeout):
        if json["model"] == settings.llm_vision_model:
            return httpx.Response(404, text="model not found")
        return chat_reply(LLM_REPLY)

    monkeypatch.setattr(advice.httpx, "post", post)
    body = client.post(f"/scans/{scan_id}/advice", json={"image_jpeg_b64": b64(jpeg_bytes)}).json()
    assert body["summary"] and body["photo_observations"] is None
    assert "ollama pull" in body["photo_note"]


def test_advice_without_photo(client, scan_id, fake_llm):
    body = client.post(f"/scans/{scan_id}/advice", json={}).json()
    assert len(fake_llm) == 1  # text model only
    assert body["photo_note"].startswith("No photo")


def test_advice_rejects_bad_photo(client, scan_id, fake_llm):
    assert client.post(f"/scans/{scan_id}/advice", json={"image_jpeg_b64": "@@@"}).status_code == 400
    assert client.post(f"/scans/{scan_id}/advice", json={"image_jpeg_b64": b64(b"not a jpeg")}).status_code == 400


def test_photo_summary():
    assert advice.photo_summary(VISION_REPLY) == VISION_REPLY["symptoms"]
    extra = {**VISION_REPLY, "other_issues": "Aphids on the underside.", "image_quality": "blurry"}
    assert advice.photo_summary(extra).endswith("Also seen: Aphids on the underside. Image quality: blurry.")


def test_advice_without_weather(client, scan_id, fake_llm, monkeypatch):
    monkeypatch.setattr(weather, "fetch_weather", lambda lat, lon: None)  # Open-Meteo down
    res = client.post(f"/scans/{scan_id}/advice", json={"lat": 17.4, "lon": 78.5})
    assert res.status_code == 200 and res.json()["weather"] is None
    # No location at all (permission denied).
    assert client.post(f"/scans/{scan_id}/advice", json={}).json()["weather"] is None


def test_advice_llm_down(client, scan_id, monkeypatch):
    def post(*args, **kwargs):
        raise httpx.ConnectError("refused")

    monkeypatch.setattr(advice.httpx, "post", post)
    res = client.post(f"/scans/{scan_id}/advice", json={})
    assert res.status_code == 503


def test_advice_llm_error_status(client, scan_id, monkeypatch):
    monkeypatch.setattr(advice.httpx, "post", lambda *a, **k: httpx.Response(404, text="model not found"))
    res = client.post(f"/scans/{scan_id}/advice", json={})
    assert res.status_code == 502 and "ollama pull" in res.json()["detail"]
    monkeypatch.setattr(advice.httpx, "post", lambda *a, **k: httpx.Response(500, text="boom"))
    assert client.post(f"/scans/{scan_id}/advice", json={}).json()["detail"] == "Advice service error (500)"


def test_advice_unknown_scan_and_bad_coords(client, fake_llm):
    assert client.post("/scans/nope/advice", json={}).status_code == 404
    assert client.post("/scans/nope/advice", json={"lat": 200, "lon": 0}).status_code == 422


def test_advice_no_leaf(client, fake_storage, fake_llm):
    fake_storage.scans["empty"] = {"id": "empty", "status": "no_leaf_detected", "primary": None, "leaves": []}
    assert client.post("/scans/empty/advice", json={}).status_code == 400
