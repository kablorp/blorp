# Packages

Optional native bindings and third-party integrations live here instead of in
`std/`. Package imports are explicit:

```blorp
import:
    pkg/sqlite as DB
```

`std/` remains the portable, always-available library. Packages may use
`foreign` declarations, native headers, and link flags for optional system
dependencies. The compiler rejects `std/` modules that import `pkg/` modules or
declare `foreign` functions directly.

Current native packages:

| Package | Description |
|---------|-------------|
| `pkg/compress` | gzip/deflate compression via zlib |
| `pkg/crypto` | AES-256-CBC + HMAC-SHA256 encryption and PBKDF2 key derivation |
| `pkg/net/dns` | DNS resolution via system resolver |
| `pkg/net/http_client` | HTTP client over scoped TCP; HTTPS targets `std/net/tls` and is pending native TLS |
| `pkg/net/smtp` | SMTP client over scoped TCP; STARTTLS targets `std/net/tls` and is pending native TLS |
| `pkg/net/tls` | TLS resource API placeholder; raw pointer API removed |
| `pkg/net/udp` | UDP resource API placeholder; raw descriptor API removed |
| `pkg/net/websocket` | WebSocket frame and handshake helpers; scoped native sessions live under `std/net/websocket` |
| `pkg/sqlite` | SQLite bindings via sqlite3 |
