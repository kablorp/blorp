// tls_ffi.h - OpenSSL TLS wrapper for blorp FFI
// Provides: connect, read, write, set_timeout, close
// Requires: -lssl -lcrypto (OpenSSL)

#ifndef BLORP_TLS_FFI_H
#define BLORP_TLS_FFI_H

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>

// Opaque TLS connection handle
typedef struct {
    SSL_CTX *ctx;
    SSL *ssl;
    int fd;
} blorp_tls_conn;

// Forward declarations from blorp runtime (available via runtime_decl.c)
extern blorp_Result* blorp_result_ok(void* value);
extern blorp_Result* blorp_result_err(void* value);
extern blorp_String* blorp_string_create(const char* cstr);
extern blorp_Bytes* blorp_bytes_new(long capacity);

// Helper: create an Err(String) result from a message
static inline blorp_Result* tls_error(const char* prefix) {
    char buf[512];
    unsigned long err = ERR_get_error();
    if (err) {
        char ssl_buf[256];
        ERR_error_string_n(err, ssl_buf, sizeof(ssl_buf));
        snprintf(buf, sizeof(buf), "%s: %s", prefix, ssl_buf);
    } else if (errno) {
        snprintf(buf, sizeof(buf), "%s: %s", prefix, strerror(errno));
    } else {
        snprintf(buf, sizeof(buf), "%s", prefix);
    }
    return blorp_result_err((void*)blorp_string_create(buf));
}

// TCP connect helper with 5-second timeout
static inline int tls_tcp_connect(const char* host, long port) {
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%ld", port);

    struct addrinfo hints, *res, *rp;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    int rc = getaddrinfo(host, port_str, &hints, &res);
    if (rc != 0) return -1;

    int fd = -1;
    for (rp = res; rp != NULL; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) continue;

        // Set non-blocking for connect with timeout
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);

        int ret = connect(fd, rp->ai_addr, rp->ai_addrlen);
        if (ret == 0) {
            // Connected immediately
            fcntl(fd, F_SETFL, flags); // restore blocking
            break;
        }
        if (errno == EINPROGRESS) {
            struct pollfd pfd = { .fd = fd, .events = POLLOUT };
            int pr = poll(&pfd, 1, 5000); // 5 second timeout
            if (pr > 0 && (pfd.revents & POLLOUT)) {
                int err = 0;
                socklen_t len = sizeof(err);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
                if (err == 0) {
                    fcntl(fd, F_SETFL, flags); // restore blocking
                    break;
                }
            }
        }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

// Connect to host:port over TLS. Returns Ok(Ptr) or Err(String).
static inline blorp_Result* blorp_tls_connect(const char* host, long port) {
    // TCP connect
    int fd = tls_tcp_connect(host, port);
    if (fd < 0) {
        return tls_error("TLS TCP connect failed");
    }

    // Create SSL context
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) {
        close(fd);
        return tls_error("SSL_CTX_new failed");
    }

    // Enforce TLS 1.2 minimum — reject SSLv3, TLS 1.0, TLS 1.1
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);

    // Load system CA certificates
    if (!SSL_CTX_set_default_verify_paths(ctx)) {
        SSL_CTX_free(ctx);
        close(fd);
        return tls_error("SSL_CTX_set_default_verify_paths failed");
    }

    // Require valid peer certificate
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);

    // Create SSL connection
    SSL *ssl = SSL_new(ctx);
    if (!ssl) {
        SSL_CTX_free(ctx);
        close(fd);
        return tls_error("SSL_new failed");
    }

    // Set SNI hostname (required by most servers)
    SSL_set_tlsext_host_name(ssl, host);
    // Enable hostname verification
    SSL_set1_host(ssl, host);

    // Attach socket
    SSL_set_fd(ssl, fd);

    // Perform TLS handshake
    int ret = SSL_connect(ssl);
    if (ret != 1) {
        SSL_free(ssl);
        SSL_CTX_free(ctx);
        close(fd);
        return tls_error("TLS handshake failed");
    }

    // Allocate connection handle
    blorp_tls_conn *conn = (blorp_tls_conn*)malloc(sizeof(blorp_tls_conn));
    conn->ctx = ctx;
    conn->ssl = ssl;
    conn->fd = fd;

    return blorp_result_ok((void*)conn);
}

// Read up to max_bytes from TLS connection. Returns Ok(Bytes) or Err(String).
static inline blorp_Result* blorp_tls_read(void* conn_ptr, long max_bytes) {
    blorp_tls_conn *conn = (blorp_tls_conn*)conn_ptr;
    blorp_Bytes *buf = blorp_bytes_new(max_bytes);

    int n = SSL_read(conn->ssl, buf->data, (int)max_bytes);
    if (n < 0) {
        int ssl_err = SSL_get_error(conn->ssl, n);
        blorp_release((void*)buf);
        if (ssl_err == SSL_ERROR_WANT_READ || ssl_err == SSL_ERROR_WANT_WRITE) {
            // Non-blocking would retry; for blocking sockets treat as temporary
            blorp_Bytes *empty = blorp_bytes_new(0);
            empty->len = 0;
            return blorp_result_ok((void*)empty);
        }
        return tls_error("TLS read failed");
    }
    if (n == 0) {
        // Clean close — return empty Bytes (same as TCP convention)
        buf->len = 0;
        return blorp_result_ok((void*)buf);
    }
    buf->len = n;
    return blorp_result_ok((void*)buf);
}

// Write data to TLS connection. Returns Ok(Int) bytes written or Err(String).
static inline blorp_Result* blorp_tls_write(void* conn_ptr, blorp_Bytes* data) {
    blorp_tls_conn *conn = (blorp_tls_conn*)conn_ptr;
    if (data->len == 0) {
        return blorp_result_ok((void*)0L);
    }

    long total = 0;
    while (total < data->len) {
        int n = SSL_write(conn->ssl, data->data + total, (int)(data->len - total));
        if (n <= 0) {
            return tls_error("TLS write failed");
        }
        total += n;
    }
    return blorp_result_ok((void*)total);
}

// Set send/receive timeout in milliseconds. Returns Ok(0) or Err(String).
static inline blorp_Result* blorp_tls_set_timeout(void* conn_ptr, long ms) {
    blorp_tls_conn *conn = (blorp_tls_conn*)conn_ptr;
    struct timeval tv;
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;

    if (setsockopt(conn->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) {
        return tls_error("setsockopt SO_RCVTIMEO failed");
    }
    if (setsockopt(conn->fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) < 0) {
        return tls_error("setsockopt SO_SNDTIMEO failed");
    }
    return blorp_result_ok((void*)0L);
}

// Close TLS connection and free all resources.
static inline void blorp_tls_close(void* conn_ptr) {
    if (!conn_ptr) return;
    blorp_tls_conn *conn = (blorp_tls_conn*)conn_ptr;
    // Set a brief timeout so SSL_shutdown doesn't block waiting for peer's close_notify
    struct timeval tv = { .tv_sec = 0, .tv_usec = 200000 };
    setsockopt(conn->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(conn->fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    // Unidirectional shutdown — send our close_notify, don't wait for peer's
    SSL_shutdown(conn->ssl);
    SSL_free(conn->ssl);
    SSL_CTX_free(conn->ctx);
    close(conn->fd);
    free(conn);
}

#endif
