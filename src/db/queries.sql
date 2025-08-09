-- name: GetUsers :many
SELECT * FROM users;

-- name: GetUser :one
SELECT * FROM users WHERE id = ? LIMIT 1;
-- name: GetUserByEmail :one
-- If you want case-insensitive lookups, add "COLLATE NOCASE" to the WHERE or to the column definition.
SELECT * FROM users WHERE email = ? LIMIT 1;

-- name: GetUserByIdentity :one
SELECT u.* FROM users u
JOIN user_identities i ON i.user_id = u.id
WHERE i.provider = ? AND i.provider_user_id = ?
LIMIT 1;

-- name: CreateUserFromOAuth :exec
INSERT INTO users (email, email_verified, name, role, ip_address)
VALUES (?, ?, ?, ?, ?);

-- name: LinkIdentity :exec
INSERT INTO user_identities (user_id, provider, provider_user_id)
VALUES (?, ?, ?)
ON CONFLICT(provider, provider_user_id) DO NOTHING;

-- name: TouchLastLogin :exec
UPDATE users SET last_login_at = CURRENT_TIMESTAMP, last_login_ip = ?
WHERE id = ?;
