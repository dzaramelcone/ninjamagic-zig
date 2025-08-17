from datetime import datetime, timedelta, timezone
from typing import Annotated, Set
from uuid import uuid4
from enum import StrEnum

from fastapi import Depends, FastAPI, Form, HTTPException, Query, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, HttpUrl
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """
    Settings for the application. Set these via environment variables or a .env file.
    """
    client_id: str = "my-client-id"
    client_secret: str = "my-client-secret"
    permitted_redirect_uri: HttpUrl | None = None
    app_url: str = "http://localhost:8000"


class TokenRequest(BaseModel):
    grant_type: str
    code: str | None = None
    redirect_uri: str | None = None
    client_id: str | None = None
    client_secret: str | None = None
    refresh_token: str | None = None


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
    refresh_token: str
    scope: str


class Scope(StrEnum):
    openid = "openid"
    profile = "profile"
    email = "email"


class UserInfo(BaseModel):
    sub: str
    name: str = ""
    picture: str = ""
    email: str = ""

    def from_scopes(self, scopes: set[Scope]):
        visible = {"sub": self.sub}

        if Scope.profile in scopes:
            visible["name"] = self.name
            visible["picture"] = self.picture
        
        if Scope.email in scopes:
            visible["email"] = self.email
            
        return UserInfo(**visible)


class TokenInfo(BaseModel):
    user: UserInfo
    scopes: set[Scope]
    expires_at: datetime
    iss: str
    aud: str


class AuthCode(BaseModel):
    """
    A Pydantic model for an OAuth 2.0 authorization code.
    This is a temporary, single-use credential.
    """
    scopes: set[str]
    user: UserInfo
    redirect_uri: str
    client_id: str
    expires_at: datetime
    state: str


class RefreshTokenInfo(BaseModel):
    user: UserInfo
    scopes: set[Scope]
    expires_at: datetime
    client_id: str


settings = Settings()
app = FastAPI()

auth_codes: dict[str, AuthCode] = {}
tokens: dict[str, TokenInfo] = {
    "valid_token_1": TokenInfo(
        user=UserInfo(
            sub="bobby123",
            name="Bob Builder",
            picture="http://example.com/bob.jpg",
            email="bob.builder@example.com",
        ),
        scopes={Scope.profile, Scope.email, Scope.openid},
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        iss=settings.app_url,
        aud=settings.client_id
    ),
    "valid_token_2": TokenInfo(
        user=UserInfo(
            sub="xoalicexo",
            name="Alice Adventure",
            picture="http://example.com/alice.jpg",
            email="alice@wonderland.com",
        ),
        scopes={Scope.profile, Scope.openid},
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        iss=settings.app_url,
        aud=settings.client_id
    ),
    "valid_token_3": TokenInfo(
        user=UserInfo(
            sub="magneto-incognito",
        ),
        scopes={Scope.openid},
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        iss=settings.app_url,
        aud=settings.client_id
    )
}

refresh_tokens: dict[str, RefreshTokenInfo] = {}
security = HTTPBearer()

def get_session_data(
    authorization: Annotated[HTTPAuthorizationCredentials, Depends(security)],
) -> TokenInfo:
    token_str = authorization.credentials
    if authorization.scheme.lower() != "bearer" or token_str not in tokens:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid_token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    
    token_info = tokens[token_str]

    # Check for token expiration
    if token_info.expires_at < datetime.now(datetime.timezone.utc):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="expired_token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    # Validate audience and issuer
    if token_info.aud != settings.client_id or token_info.iss != settings.app_url:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid_token_claims",
            headers={"WWW-Authenticate": "Bearer"},
        )

    return token_info


@app.get("/")
def root() -> str:
    return "Hello world!\n"


@app.get("/authorize")
def authorize(
    response_type: Annotated[str, Query()],
    client_id: Annotated[str, Query()],
    redirect_uri: Annotated[str, Query()],
    scope: Annotated[str, Query()],
    state: Annotated[str, Query()]
) -> RedirectResponse:
    if response_type != "code":
        raise HTTPException(
            status_code=400,
            detail="unsupported_response_type"
        )
    
    scopes = set(scope.split()) if scope else set()
    valid_scopes = set(Scope.__members__.values())
    if invalid_scopes := scopes - valid_scopes:
        raise HTTPException(
            status_code=400,
            detail=f"invalid_scope: {' '.join(invalid_scopes)}"
        )
    
    code = uuid4().hex
    auth_codes[code] = AuthCode(
        scopes=scopes,
        user=UserInfo(
            sub="charlesincharge",
            name="Charlie von Charge",
            email="chazzychef@example.com",
            picture="https://placehold.co/chaz-kills-it.png",
        ),
        redirect_uri=redirect_uri,
        client_id=client_id,
        expires_at=datetime.now(datetime.timezone.utc) + timedelta(minutes=5),
        state=state
    )
    redirect = f"{redirect_uri}?code={code}"
    if state:
        redirect += f"&state={state}"
    return RedirectResponse(redirect)


@app.post("/token")
async def token(
    grant_type: Annotated[str, Form()],
    code: Annotated[str, Form()],
    redirect_uri: Annotated[str, Form()],
    client_id: Annotated[str, Form()],
    client_secret: Annotated[str, Form()],
    refresh_token: Annotated[str | None, Form()] = None,
    state: Annotated[str | None, Form()] = None
) -> TokenResponse:
    if grant_type == "authorization_code":
            
        if code not in auth_codes:
            raise HTTPException(status_code=400, detail="invalid_grant")

        data = auth_codes.pop(code)
        
        if client_id != data.client_id:
            raise HTTPException(status_code=400, detail="invalid_client")
        if client_secret != settings.client_secret:
            raise HTTPException(status_code=401, detail="invalid_client_secret")
        if data.redirect_uri != redirect_uri:
            raise HTTPException(status_code=400, detail="invalid_redirect")
        if state and data.state != state:
            raise HTTPException(status_code=400, detail="invalid_state")
            
        if data.expires_at < datetime.now(datetime.timezone.utc):
            raise HTTPException(status_code=400, detail="expired_code")
        
        access_token = uuid4().hex
        new_refresh_token = uuid4().hex

        tokens[access_token] = TokenInfo(
            scopes={Scope(s) for s in data.scopes},
            user=data.user,
            expires_at=datetime.now(datetime.timezone.utc) + timedelta(hours=1),
            iss=settings.app_url,
            aud=client_id
        )

        refresh_tokens[new_refresh_token] = RefreshTokenInfo(
            user=data.user,
            scopes={Scope(s) for s in data.scopes},
            expires_at=datetime.now(datetime.timezone.utc) + timedelta(days=7),
            client_id=client_id
        )

        return TokenResponse(
            access_token=access_token,
            token_type="bearer",
            expires_in=3600,
            refresh_token=new_refresh_token,
            scope=" ".join(data.scopes),
        )

    elif grant_type == "refresh_token":
        if not refresh_token:
            raise HTTPException(status_code=400, detail="missing_refresh_token")

        if refresh_token not in refresh_tokens:
            raise HTTPException(status_code=400, detail="invalid_refresh_token")
        
        refresh_token_data = refresh_tokens[refresh_token]

        if refresh_token_data.expires_at < datetime.now(datetime.timezone.utc):
            raise HTTPException(status_code=400, detail="expired_refresh_token")
        
        # Invalidate old refresh token
        del refresh_tokens[refresh_token]

        access_token = uuid4().hex
        new_refresh_token = uuid4().hex

        tokens[access_token] = TokenInfo(
            scopes=refresh_token_data.scopes,
            user=refresh_token_data.user,
            expires_at=datetime.now(datetime.timezone.utc) + timedelta(hours=1),
            iss=settings.app_url,
            aud=refresh_token_data.client_id
        )

        refresh_tokens[new_refresh_token] = RefreshTokenInfo(
            user=refresh_token_data.user,
            scopes=refresh_token_data.scopes,
            expires_at=datetime.now(datetime.timezone.utc) + timedelta(days=7),
            client_id=refresh_token_data.client_id
        )

        return TokenResponse(
            access_token=access_token,
            token_type="bearer",
            expires_in=3600,
            refresh_token=new_refresh_token,
            scope=" ".join(refresh_token_data.scopes),
        )

    else:
        raise HTTPException(status_code=400, detail="unsupported_grant_type")


@app.get("/userinfo")
def userinfo(token: Annotated[TokenInfo, Depends(get_session_data)]) -> UserInfo:
    return token.user.from_scopes(token.scopes)


if __name__ == "__main__":
    import uvicorn


    uvicorn.run(app, host="0.0.0.0", port=8000)
