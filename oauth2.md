The OAuth 2.0 PKCE Flow

Step 1: Authorization Request
The User sends a request to the Client to start the login process.

The Client redirects the User's browser to the Server's authorization page. The code_challenge and redirect_uri are stored in the query parameters of the redirect URL. The Server stores the code_challenge for later use.

Step 2: Authorization Code Grant
The Server authenticates the User and gets their consent.

The Server then redirects the User's browser back to the Client with an authorization_code. The authorization_code is stored in the query parameters of the redirect URL.

Step 3: Token Exchange
The Client receives the authorization_code and makes a direct POST request to the Server's /token endpoint. This is a server-to-server request.

The Client sends the authorization_code and the original code_verifier (its secret) in the body of the POST request.

Step 4: Token Response
The Server hashes the code_verifier and validates it against the code_challenge it stored earlier.

If the validation is successful, the Server sends the access_token and refresh_token to the Client in a JSON response.

Step 5: Resource Access
The Client sends a request to the Server's /userinfo endpoint with the access_token in the Authorization header.

The Server validates the access_token and sends the requested user information back to the Client.

Step 6: Token Refresh (Optional)
When the access_token expires, the Client sends a request to the Server's /token endpoint with the refresh_token in the body.

The Server validates the refresh_token and issues a new access_token and refresh_token.
