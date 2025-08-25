-- name: GetUserByName :one
SELECT * FROM users WHERE name = ? LIMIT 1;

-- name: CreateUser :one
INSERT INTO users (name, secret)
VALUES (?, ?)
RETURNING id, name, secret;

-- name: DeleteUser :exec
DELETE FROM users WHERE id = ?;
