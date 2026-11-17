"""Account endpoints: delete the signed-in user's account and everything stored for them."""

import logging
from types import ModuleType

from fastapi import APIRouter, Depends, Response
from firebase_admin import auth

from app.auth import get_current_uid
from app.config import settings
from app.routes.scans import get_store

log = logging.getLogger(__name__)
router = APIRouter(prefix="/account", tags=["account"])


@router.delete("", status_code=204)
def delete_account(uid: str = Depends(get_current_uid), store: ModuleType = Depends(get_store)):
    """Deletes all of the user's scans (results and any stored images), then their Firebase login.

    Done here with the Admin SDK rather than in the app: a client-side delete fails with "requires recent login"
    when the user signed in a while ago. Photos kept on the phone are deleted by the app.
    """
    deleted = store.delete_all_scans(uid)
    if settings.use_firebase:
        try:
            auth.delete_user(uid)
        except auth.UserNotFoundError:
            pass  # already gone: deleting again is fine
    log.info("Deleted account %s (%d scans)", uid, deleted)
    return Response(status_code=204)
