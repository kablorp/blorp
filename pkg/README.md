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
| `pkg/audio/neural_amp` | Neural amp modeling helpers with native fast NAM weight parsing |
| `pkg/compress` | gzip/deflate compression via zlib |
| `pkg/crypto` | AES-256-CBC + HMAC-SHA256 encryption and PBKDF2 key derivation |
| `pkg/net/dns` | DNS resolution via system resolver |
| `pkg/net/http_client` | HTTP client with optional TLS |
| `pkg/net/smtp` | SMTP client with optional STARTTLS |
| `pkg/net/tls` | TLS sockets via OpenSSL |
| `pkg/net/udp` | UDP sockets |
| `pkg/net/websocket` | WebSocket client over TCP/TLS |
| `pkg/sqlite` | SQLite bindings via sqlite3 |
| `pkg/tui` | Terminal UI runtime via POSIX termios/ioctl |
