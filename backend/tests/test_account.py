"""DELETE /account."""

from firebase_admin import auth

from tests.conftest import UID


def test_delete_account_removes_scans_and_the_login(client, fake_storage, jpeg_bytes, firebase_mode, monkeypatch):
    deleted_users = []
    monkeypatch.setattr(auth, "delete_user", deleted_users.append)
    for _ in range(2):
        client.post("/scans", files={"image": ("leaf.jpg", jpeg_bytes, "image/jpeg")})

    assert client.delete("/account").status_code == 204
    assert fake_storage.scans == {}
    assert client.get("/scans").json() == []
    assert deleted_users == [UID]


def test_delete_account_twice_is_fine(client, firebase_mode, monkeypatch):
    def gone(uid):
        raise auth.UserNotFoundError("no such user")

    monkeypatch.setattr(auth, "delete_user", gone)
    assert client.delete("/account").status_code == 204


def test_delete_account_needs_a_token(firebase_mode, anon_client):
    assert anon_client.delete("/account").status_code == 401


def test_delete_account_local_mode(local_mode, jpeg_bytes):
    scan = local_mode.post("/scans", files={"image": ("leaf.jpg", jpeg_bytes, "image/jpeg")}).json()
    assert local_mode.delete("/account").status_code == 204
    assert local_mode.get("/scans").json() == []
    assert local_mode.get(scan["image_url"]).status_code == 404
