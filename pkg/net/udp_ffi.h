// udp_ffi.h - UDP socket and DNS resolution for blorp FFI
// Provides: UDP send/recv, DNS resolve
// Note: String params auto-convert to char* by blorp FFI codegen.

#ifndef BLORP_UDP_FFI_H
#define BLORP_UDP_FFI_H

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

// Forward declarations from blorp runtime
extern blorp_Result* blorp_result_ok(void* value);
extern blorp_Result* blorp_result_err(void* value);
extern blorp_String* blorp_string_create(const char* cstr);
extern blorp_String* blorp_string_from_buf(const char* buf, long len);
extern blorp_Bytes* blorp_bytes_new(long capacity);
extern blorp_List* blorp_list_new(long initial_capacity);
extern blorp_List* blorp_list_append(blorp_List* list, void* element);
extern void blorp_list_init_elem_release(blorp_List* list, void (*release_fn)(void*));
extern void blorp_elem_release_fn(void* p);
extern void blorp_release(void* obj);

// Helper: create Result with release_mask for RC inner values
static inline blorp_Result* udp_result_ok(void* value) {
    blorp_Result* r = blorp_result_ok(value);
    r->release_mask = 1UL;
    return r;
}

static inline blorp_Result* udp_result_err(const char* msg) {
    blorp_Result* r = blorp_result_err((void*)blorp_string_create(msg));
    r->release_mask = 1UL;
    return r;
}

static inline blorp_Result* udp_result_ok_int(long value) {
    // Int doesn't need release_mask
    return blorp_result_ok((void*)value);
}

// udp_socket() -> Result[Int, String]
// Create a UDP socket
static inline blorp_Result* blorp_udp_socket(void) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        return udp_result_err("udp: socket creation failed");
    }
    return udp_result_ok_int((long)fd);
}

// udp_bind(fd, host, port) -> Result[Void, String]
static inline blorp_Result* blorp_udp_bind(long fd, const char* host, long port) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (host[0] == '0' && host[1] == '\0') {
        addr.sin_addr.s_addr = INADDR_ANY;
    } else {
        if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
            return udp_result_err("udp bind: invalid address");
        }
    }
    if (bind((int)fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        return udp_result_err("udp bind failed");
    }
    return blorp_result_ok(NULL);
}

// udp_sendto(fd, data, host, port) -> Result[Int, String]
// Returns number of bytes sent
static inline blorp_Result* blorp_udp_sendto(long fd, blorp_Bytes* data, const char* host, long port) {
    if (!data) return udp_result_err("udp sendto: null data");

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);

    // Try numeric address first, then DNS
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        struct addrinfo hints = {0};
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_DGRAM;
        struct addrinfo* res;
        if (getaddrinfo(host, NULL, &hints, &res) != 0) {
            return udp_result_err("udp sendto: DNS resolution failed");
        }
        addr.sin_addr = ((struct sockaddr_in*)res->ai_addr)->sin_addr;
        freeaddrinfo(res);
    }

    ssize_t sent = sendto((int)fd, data->data, (size_t)data->len, 0,
                          (struct sockaddr*)&addr, sizeof(addr));
    if (sent < 0) {
        return udp_result_err("udp sendto failed");
    }
    return udp_result_ok_int((long)sent);
}

// udp_recvfrom(fd, max_bytes) -> Result[(Bytes, String, Int), String]
// Returns (data, sender_ip, sender_port) as a tuple
// Note: blorp tuples are not easy to construct from C, so we return
// just the data bytes. Use a separate function for sender info if needed.
static inline blorp_Result* blorp_udp_recvfrom(long fd, long max_bytes) {
    if (max_bytes <= 0) max_bytes = 65535;
    unsigned char* buf = (unsigned char*)malloc((size_t)max_bytes);
    if (!buf) return udp_result_err("udp recvfrom: out of memory");

    struct sockaddr_in sender;
    socklen_t sender_len = sizeof(sender);
    ssize_t received = recvfrom((int)fd, buf, (size_t)max_bytes, 0,
                                (struct sockaddr*)&sender, &sender_len);
    if (received < 0) {
        free(buf);
        return udp_result_err("udp recvfrom failed");
    }

    blorp_Bytes* result = blorp_bytes_new(received);
    if (received > 0) {
        memcpy(result->data, buf, (size_t)received);
    }
    free(buf);
    return udp_result_ok((void*)result);
}

// udp_close(fd) -> Void
static inline void blorp_udp_close(long fd) {
    close((int)fd);
}

// dns_resolve(hostname) -> Result[List[String], String]
// Resolve a hostname to a list of IP addresses
static inline blorp_Result* blorp_dns_resolve(const char* hostname) {
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;  // Both IPv4 and IPv6
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo* res;
    int rc = getaddrinfo(hostname, NULL, &hints, &res);
    if (rc != 0) {
        char err_buf[256];
        snprintf(err_buf, sizeof(err_buf), "dns resolve: %s", gai_strerror(rc));
        return udp_result_err(err_buf);
    }

    blorp_List* list = blorp_list_new(4);
    blorp_list_init_elem_release(list, blorp_elem_release_fn);

    for (struct addrinfo* p = res; p != NULL; p = p->ai_next) {
        char ip_buf[INET6_ADDRSTRLEN];
        const char* ip = NULL;
        if (p->ai_family == AF_INET) {
            ip = inet_ntop(AF_INET, &((struct sockaddr_in*)p->ai_addr)->sin_addr,
                          ip_buf, sizeof(ip_buf));
        } else if (p->ai_family == AF_INET6) {
            ip = inet_ntop(AF_INET6, &((struct sockaddr_in6*)p->ai_addr)->sin6_addr,
                          ip_buf, sizeof(ip_buf));
        }
        if (ip) {
            // Check for duplicates (same IP from different socket types)
            int dup = 0;
            for (long i = 0; i < list->len; i++) {
                blorp_String* existing = (blorp_String*)list->data[i];
                if (existing->len == (long)strlen(ip) &&
                    memcmp(existing->data, ip, strlen(ip)) == 0) {
                    dup = 1;
                    break;
                }
            }
            if (!dup) {
                blorp_String* s = blorp_string_create(ip);
                list = blorp_list_append(list, s);
                blorp_release(s);  // list_append retains
            }
        }
    }

    freeaddrinfo(res);
    return udp_result_ok((void*)list);
}

#endif // BLORP_UDP_FFI_H
