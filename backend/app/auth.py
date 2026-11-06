"""Firebase ID token verification → current user's uid (FastAPI dependency)."""

from fastapi import Header, HTTPException, status
from firebase_admin import auth

from app.config import settings

LOCAL_UID = "local-user"


def get_current_uid(authorization: str | None = Header(None)) -> str:
    if not settings.use_firebase:
        return LOCAL_UID  # local prototype mode: everyone is the same user
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Missing bearer token", {"WWW-Authenticate": "Bearer"})
    try:
        return auth.verify_id_token(token)["uid"]
    except Exception as e:  # invalid, expired, revoked or wrong-project tokens
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid token", {"WWW-Authenticate": "Bearer"}) from e
