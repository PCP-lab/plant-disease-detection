"""Disease-risk forecast: day-by-day weather risk of powdery mildew and leaf spot spreading, for the next week."""

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app import weather
from app.auth import get_current_uid
from app.schemas import RiskForecast

router = APIRouter(tags=["forecast"])


# Plain `def`: the weather call blocks, so FastAPI runs this in a worker thread.
@router.get("/risk-forecast", response_model=RiskForecast)
def risk_forecast(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
    _uid: str = Depends(get_current_uid),
):
    forecast = weather.fetch_weather(lat, lon)
    if forecast is None:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Weather forecast unavailable. Try again later.")
    return weather.risk_forecast(forecast)
