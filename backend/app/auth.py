"""Firebase ID token verification → current user's uid (FastAPI dependency)."""

from fastapi import Header


def get_current_uid(authorization: str = Header(...)) -> str:
    # TODO: strip "Bearer ", firebase_admin.auth.verify_id_token(token)["uid"]; raise 401 on failure
    raise NotImplementedError
