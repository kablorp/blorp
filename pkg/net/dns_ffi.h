// dns_ffi.h - DNS resolution for blorp package FFI.
//
// This package resolver intentionally uses the platform blocking resolver.
// The networking resource roadmap tracks a future std DNS operation backed by
// a bounded runtime resolver service or a true nonblocking resolver.

#ifndef BLORP_DNS_FFI_H
#define BLORP_DNS_FFI_H

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Forward declarations from blorp runtime.
extern blorp_Result* blorp_result_ok(void* value);
extern blorp_Result* blorp_result_err(void* value);
extern blorp_String* blorp_string_create(const char* cstr);
extern blorp_List* blorp_list_new(long initial_capacity);
extern blorp_List* blorp_list_append(blorp_List* list, void* element);
extern void blorp_list_init_elem_release(
    blorp_List* list,
    void (*release_fn)(void*)
);
extern void blorp_elem_release_fn(void* p);
extern void blorp_release(void* obj);

static inline blorp_Result* dns_result_ok(void* value) {
    blorp_Result* result = blorp_result_ok(value);
    result->release_mask = 1UL;
    return result;
}

static inline blorp_Result* dns_result_err(const char* msg) {
    blorp_Result* result = blorp_result_err((void*)blorp_string_create(msg));
    result->release_mask = 1UL;
    return result;
}

// Resolve a hostname to a deduplicated list of IPv4 and IPv6 address strings.
static inline blorp_Result* blorp_dns_resolve(const char* hostname) {
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo* res = NULL;
    int rc = getaddrinfo(hostname, NULL, &hints, &res);
    if (rc != 0) {
        char err_buf[256];
        snprintf(err_buf, sizeof(err_buf), "dns resolve: %s", gai_strerror(rc));
        return dns_result_err(err_buf);
    }

    blorp_List* list = blorp_list_new(4);
    blorp_list_init_elem_release(list, blorp_elem_release_fn);

    for (struct addrinfo* p = res; p != NULL; p = p->ai_next) {
        char ip_buf[INET6_ADDRSTRLEN];
        const char* ip = NULL;
        if (p->ai_family == AF_INET) {
            ip = inet_ntop(
                AF_INET,
                &((struct sockaddr_in*)p->ai_addr)->sin_addr,
                ip_buf,
                sizeof(ip_buf));
        } else if (p->ai_family == AF_INET6) {
            ip = inet_ntop(
                AF_INET6,
                &((struct sockaddr_in6*)p->ai_addr)->sin6_addr,
                ip_buf,
                sizeof(ip_buf));
        }

        if (ip) {
            int duplicate = 0;
            size_t ip_len = strlen(ip);
            for (long i = 0; i < list->len; i++) {
                blorp_String* existing = (blorp_String*)list->data[i];
                if (existing->len == (long)ip_len &&
                    memcmp(existing->data, ip, ip_len) == 0) {
                    duplicate = 1;
                    break;
                }
            }
            if (!duplicate) {
                blorp_String* address = blorp_string_create(ip);
                list = blorp_list_append(list, address);
                blorp_release(address);
            }
        }
    }

    freeaddrinfo(res);
    return dns_result_ok((void*)list);
}

#endif // BLORP_DNS_FFI_H
