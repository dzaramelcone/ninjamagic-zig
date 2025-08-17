import requests
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import RedirectResponse
from pydantic import BaseModel
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    provider: str = "http://oauth:8000"
    provider_redirect: str = "http://localhost:8000"
    redirect_uri: str = "http://localhost:8001/callback"
    client_id: str
    client_secret: str

settings = Settings()
app = FastAPI()

# A simple in-memory store for our tokens
# In a real app, this would be a persistent store
tokens = {}

class TokenResponse(BaseModel):
    access_token: str
    token_type: str
    expires_in: int
    refresh_token: str
    scope: str

class UserInfoResponse(BaseModel):
    sub: str
    name: str | None = None
    picture: str | None = None
    email: str | None = None

class AuthorizationRequest(BaseModel):
    response_type: str
    client_id: str
    redirect_uri: str
    scope: str
    state: str

class TokenExchangeRequest(BaseModel):
    grant_type: str
    code: str
    redirect_uri: str
    client_id: str
    client_secret: str
    state: str

class RefreshTokenRequest(BaseModel):
    grant_type: str
    refresh_token: str

@app.get("/")
def home():
    """
    Simulates the client's homepage. Redirects to the authorization server to start the flow.
    """

    auth_params = AuthorizationRequest(
        response_type="code",
        client_id=settings.client_id,
        redirect_uri=settings.redirect_uri,
        scope="openid profile email",
        state="a-unique-state-for-csrf-prevention"
    )
    auth_url = requests.Request(
        'GET',
        f"{settings.provider_redirect}/authorize",
        params=auth_params.model_dump()
    ).prepare().url
    print(f"redirect to {auth_url}")
    return RedirectResponse(auth_url)

@app.get("/callback")
async def callback(request: Request):
    """
    Receives the authorization code and exchanges it for a token.
    This is the core of the client's authentication logic.
    """
    query_params = request.query_params
    auth_code = query_params.get("code")
    received_state = query_params.get("state")

    if not auth_code:
        raise HTTPException(status_code=400, detail="Authorization code missing.")

    token_data = TokenExchangeRequest(
        grant_type="authorization_code",
        code=auth_code,
        redirect_uri=settings.redirect_uri,
        client_id=settings.client_id,
        client_secret=settings.client_secret,
        state=received_state
    )

    try:
        response = requests.post(f"{settings.provider}/token", data=token_data.model_dump())
        response.raise_for_status()
        token_info = TokenResponse.model_validate(response.json())
        
        # Store the tokens for later use
        tokens["access_token"] = token_info.access_token
        tokens["refresh_token"] = token_info.refresh_token
        
        # Access a protected resource to show the access token works
        userinfo_response = requests.get(
            f"{settings.provider}/userinfo",
            headers={"Authorization": f"Bearer {tokens['access_token']}"}
        )
        userinfo_response.raise_for_status()
        user_data = UserInfoResponse.model_validate(userinfo_response.json())
        
        return {
            "message": "Authentication successful!",
            "user_info": user_data,
            "tokens": token_info
        }

    except requests.exceptions.RequestException as e:
        raise HTTPException(status_code=500, detail=f"Token exchange failed: {e}")

@app.post("/refresh")
def refresh_token_endpoint():
    """
    An endpoint to manually test the refresh token flow.
    """
    if not tokens.get("refresh_token"):
        raise HTTPException(status_code=400, detail="No refresh token available.")

    refresh_data = RefreshTokenRequest(
        grant_type="refresh_token",
        refresh_token=tokens["refresh_token"]
    )

    try:
        response = requests.post(f"{settings.provider}/token", data=refresh_data.model_dump())
        response.raise_for_status()
        new_token_info = TokenResponse.model_validate(response.json())
        tokens["access_token"] = new_token_info.access_token
        tokens["refresh_token"] = new_token_info.refresh_token
        
        return {
            "message": "Token refreshed successfully!",
            "new_access_token": new_token_info.access_token
        }
    except requests.exceptions.RequestException as e:
        raise HTTPException(status_code=500, detail=f"Token refresh failed: {e}")

if __name__ == "__main__":
    import uvicorn


    uvicorn.run(app, host="0.0.0.0", port=8001)
