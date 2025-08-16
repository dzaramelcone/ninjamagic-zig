from datetime import datetime, timedelta
from typing import Dict, Set
from uuid import uuid4

from fastapi import FastAPI, Form, Header, HTTPException
from fastapi.responses import RedirectResponse
from faker import Faker

app = FastAPI()
fake = Faker()

auth_codes: Dict[str, Dict] = {}
tokens: Dict[str, Dict] = {}

VALID_SCOPES = {"openid", "profile", "email"}


@app.get("/authorize")
def authorize(
    response_type: str,
    client_id: str,
    redirect_uri: str,
    scope: str,
    state: str = "",
):
    if response_type != "code":
        raise HTTPException(status_code=400, detail="unsupported_response_type")
    scopes = set(scope.split()) if scope else set()
    invalid_scopes = scopes - VALID_SCOPES
    if invalid_scopes:
        raise HTTPException(
            status_code=400, detail=f"invalid_scope: {' '.join(invalid_scopes)}"
        )
    user = {
        "sub": fake.uuid4(),
        "name": fake.name(),
        "email": fake.email(),
        "picture": fake.image_url(),
    }
    code = uuid4().hex
    auth_codes[code] = {"scopes": scopes, "user": user}
    redirect = f"{redirect_uri}?code={code}"
    if state:
        redirect += f"&state={state}"
    return RedirectResponse(redirect)


@app.post("/token")
async def token(
    grant_type: str = Form(...),
    code: str = Form(...),
    redirect_uri: str = Form(...),
    client_id: str = Form(...),
    client_secret: str = Form(...),
):
    if grant_type != "authorization_code" or code not in auth_codes:
        raise HTTPException(status_code=400, detail="invalid_grant")
    data = auth_codes.pop(code)
    access_token = uuid4().hex
    refresh_token = uuid4().hex
    tokens[access_token] = {
        "scopes": data["scopes"],
        "user": data["user"],
        "expires": datetime.utcnow() + timedelta(hours=1),
    }
    return {
        "access_token": access_token,
        "token_type": "bearer",
        "expires_in": 3600,
        "refresh_token": refresh_token,
        "scope": " ".join(data["scopes"]),
    }


@app.get("/userinfo")
def userinfo(authorization: str = Header(...)):
    try:
        scheme, token = authorization.split()
    except ValueError:
        raise HTTPException(status_code=401, detail="invalid_request")
    if scheme.lower() != "bearer" or token not in tokens:
        raise HTTPException(status_code=401, detail="invalid_token")
    data = tokens[token]
    user = {"sub": data["user"]["sub"]}
    scopes: Set[str] = data["scopes"]
    if "profile" in scopes:
        user.update({
            "name": data["user"]["name"],
            "picture": data["user"]["picture"],
        })
    if "email" in scopes:
        user["email"] = data["user"]["email"]
    return user


@app.get("/")
def root():
    return {"message": "Mock OAuth2 Provider"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
