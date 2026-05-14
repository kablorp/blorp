// crypto_ffi.h - AES-256-CBC + HMAC-SHA256 authenticated encryption for blorp FFI
// Provides: encrypt, decrypt, derive_key (PBKDF2)
// Uses: CommonCrypto (macOS) / OpenSSL (Linux)
// Pattern: Encrypt-then-MAC with sub-key derivation
//
// Wire format: IV (16 bytes) || ciphertext || HMAC-SHA256 tag (32 bytes)
// Sub-keys: enc_key = HMAC-SHA256(key, "blorp-enc"), mac_key = HMAC-SHA256(key, "blorp-mac")

#ifndef BLORP_CRYPTO_FFI_H
#define BLORP_CRYPTO_FFI_H

#ifdef __APPLE__
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <CommonCrypto/CommonHMAC.h>
#else
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#endif

#include <string.h>
#include <stdlib.h>
#include <stdint.h>

// Forward declarations from blorp runtime
extern blorp_Result* blorp_result_ok(void* value);
extern blorp_Result* blorp_result_err(void* value);
extern blorp_String* blorp_string_create(const char* cstr);
extern blorp_Bytes* blorp_bytes_new(long capacity);
extern void* blorp_retain(void* obj);

#define CRYPTO_IV_LEN   16  // AES block size
#define CRYPTO_KEY_LEN  32  // AES-256
#define CRYPTO_TAG_LEN  32  // HMAC-SHA256 output
#define CRYPTO_MIN_CIPHERTEXT (CRYPTO_IV_LEN + 16 + CRYPTO_TAG_LEN)  // IV + 1 block + tag

// Secure zeroing: use explicit_bzero (macOS/Linux) or memset_s to prevent
// the compiler from optimizing away zeroization of sensitive key material.
static inline void crypto_secure_zero(void* buf, size_t len) {
#ifdef __APPLE__
    memset_s(buf, len, 0, len);
#elif defined(__GLIBC__) || defined(__linux__)
    explicit_bzero(buf, len);
#else
    volatile unsigned char* p = (volatile unsigned char*)buf;
    for (size_t i = 0; i < len; i++) p[i] = 0;
#endif
}

// Helper: create Result with release_mask for RC inner values
// (inner Bytes/String is ARC-managed and must be released when the Result is freed)
static inline blorp_Result* crypto_result_ok(void* value) {
    blorp_Result* r = blorp_result_ok(value);
    r->release_mask = 1UL;
    return r;
}

static inline blorp_Result* crypto_result_err(const char* msg) {
    blorp_Result* r = blorp_result_err((void*)blorp_string_create(msg));
    r->release_mask = 1UL;
    return r;
}

// Helper: create Bytes from raw data
static inline blorp_Bytes* crypto_bytes_from_raw(const unsigned char* data, long len) {
    blorp_Bytes* b = blorp_bytes_new(len);
    if (len > 0 && data) {
        memcpy(b->data, data, (size_t)len);
    }
    return b;
}

// Helper: HMAC-SHA256 (raw bytes output, not hex)
static inline void crypto_hmac_sha256(const unsigned char* key, size_t key_len,
                                       const unsigned char* data, size_t data_len,
                                       unsigned char out[32]) {
#ifdef __APPLE__
    CCHmac(kCCHmacAlgSHA256, key, key_len, data, data_len, out);
#else
    unsigned int len = 32;
    HMAC(EVP_sha256(), key, (int)key_len, data, data_len, out, &len);
#endif
}

// Helper: derive sub-keys from master key
static inline void crypto_derive_subkeys(const unsigned char* key, size_t key_len,
                                          unsigned char enc_key[32],
                                          unsigned char mac_key[32]) {
    crypto_hmac_sha256(key, key_len,
                       (const unsigned char*)"blorp-enc", 9, enc_key);
    crypto_hmac_sha256(key, key_len,
                       (const unsigned char*)"blorp-mac", 9, mac_key);
}

// Helper: constant-time comparison
static inline int crypto_ct_equal(const unsigned char* a, const unsigned char* b, size_t len) {
    unsigned char diff = 0;
    for (size_t i = 0; i < len; i++) {
        diff |= a[i] ^ b[i];
    }
    return diff == 0;
}

// Helper: generate random bytes
static inline int crypto_random_fill(unsigned char* buf, size_t len) {
#ifdef __APPLE__
    arc4random_buf(buf, len);
    return 1;  // always succeeds
#else
    return RAND_bytes(buf, (int)len);  // returns 1 on success
#endif
}

// encrypt(plaintext: Bytes, key: Bytes) -> Result[Bytes, String]
// Output: IV (16) || ciphertext (padded) || HMAC-SHA256 tag (32)
static inline blorp_Result* blorp_crypto_encrypt(blorp_Bytes* plaintext, blorp_Bytes* key) {
    if (!key || key->len < 1) {
        return crypto_result_err("key must not be empty");
    }

    unsigned char enc_key[CRYPTO_KEY_LEN];
    unsigned char mac_key[CRYPTO_KEY_LEN];
    crypto_derive_subkeys(key->data, (size_t)key->len, enc_key, mac_key);

    // Generate random IV
    unsigned char iv[CRYPTO_IV_LEN];
    if (crypto_random_fill(iv, CRYPTO_IV_LEN) != 1) {
        crypto_secure_zero(enc_key, sizeof(enc_key));
        crypto_secure_zero(mac_key, sizeof(mac_key));
        return crypto_result_err("random generation failed");
    }

    // Encrypt with AES-256-CBC + PKCS7 padding
    size_t pt_len = plaintext ? (size_t)plaintext->len : 0;
    size_t padded_len = ((pt_len / 16) + 1) * 16;  // PKCS7 always adds padding
    size_t max_out_len = CRYPTO_IV_LEN + padded_len + CRYPTO_TAG_LEN;

    unsigned char* output = (unsigned char*)malloc(max_out_len);
    if (!output) {
        crypto_secure_zero(enc_key, sizeof(enc_key));
        crypto_secure_zero(mac_key, sizeof(mac_key));
        return crypto_result_err("out of memory");
    }

    // Write IV
    memcpy(output, iv, CRYPTO_IV_LEN);

    size_t ct_written = 0;
#ifdef __APPLE__
    CCCryptorStatus status = CCCrypt(
        kCCEncrypt,
        kCCAlgorithmAES,
        kCCOptionPKCS7Padding,
        enc_key, CRYPTO_KEY_LEN,
        iv,
        plaintext ? plaintext->data : (unsigned char*)"",
        pt_len,
        output + CRYPTO_IV_LEN,
        padded_len,
        &ct_written
    );
    if (status != kCCSuccess) {
        free(output);
        crypto_secure_zero(enc_key, sizeof(enc_key));
        crypto_secure_zero(mac_key, sizeof(mac_key));
        return crypto_result_err("encryption failed");
    }
#else
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        free(output);
        crypto_secure_zero(enc_key, sizeof(enc_key));
        crypto_secure_zero(mac_key, sizeof(mac_key));
        return crypto_result_err("encryption init failed");
    }
    EVP_EncryptInit_ex(ctx, EVP_aes_256_cbc(), NULL, enc_key, iv);
    int update_len = 0, final_len = 0;
    EVP_EncryptUpdate(ctx, output + CRYPTO_IV_LEN, &update_len,
                      plaintext ? plaintext->data : (unsigned char*)"", (int)pt_len);
    EVP_EncryptFinal_ex(ctx, output + CRYPTO_IV_LEN + update_len, &final_len);
    ct_written = (size_t)(update_len + final_len);
    EVP_CIPHER_CTX_free(ctx);
#endif

    // Use actual ct_written for HMAC and output size
    size_t out_len = CRYPTO_IV_LEN + ct_written + CRYPTO_TAG_LEN;

    // Compute HMAC-SHA256 over IV + ciphertext
    crypto_hmac_sha256(mac_key, CRYPTO_KEY_LEN,
                       output, CRYPTO_IV_LEN + ct_written,
                       output + CRYPTO_IV_LEN + ct_written);

    blorp_Bytes* result = crypto_bytes_from_raw(output, (long)out_len);
    free(output);

    crypto_secure_zero(enc_key, sizeof(enc_key));
    crypto_secure_zero(mac_key, sizeof(mac_key));

    return crypto_result_ok((void*)result);
}

// decrypt(ciphertext: Bytes, key: Bytes) -> Result[Bytes, String]
static inline blorp_Result* blorp_crypto_decrypt(blorp_Bytes* ciphertext, blorp_Bytes* key) {
    if (!key || key->len < 1) {
        return crypto_result_err("key must not be empty");
    }
    if (!ciphertext || ciphertext->len < CRYPTO_MIN_CIPHERTEXT) {
        return crypto_result_err("ciphertext too short");
    }

    size_t total = (size_t)ciphertext->len;
    size_t ct_len = total - CRYPTO_IV_LEN - CRYPTO_TAG_LEN;

    // ct_len must be multiple of 16 (AES block size)
    if (ct_len % 16 != 0) {
        return crypto_result_err("invalid ciphertext length");
    }

    unsigned char enc_key[CRYPTO_KEY_LEN];
    unsigned char mac_key[CRYPTO_KEY_LEN];
    crypto_derive_subkeys(key->data, (size_t)key->len, enc_key, mac_key);

    // Verify HMAC-SHA256 tag (constant-time)
    unsigned char expected_tag[CRYPTO_TAG_LEN];
    crypto_hmac_sha256(mac_key, CRYPTO_KEY_LEN,
                       ciphertext->data, CRYPTO_IV_LEN + ct_len,
                       expected_tag);

    const unsigned char* actual_tag = ciphertext->data + CRYPTO_IV_LEN + ct_len;
    if (!crypto_ct_equal(expected_tag, actual_tag, CRYPTO_TAG_LEN)) {
        crypto_secure_zero(enc_key, sizeof(enc_key));
        crypto_secure_zero(mac_key, sizeof(mac_key));
        return crypto_result_err("authentication failed");
    }

    // Extract IV
    const unsigned char* iv = ciphertext->data;
    const unsigned char* ct = ciphertext->data + CRYPTO_IV_LEN;

    // Decrypt
    unsigned char* plaintext = (unsigned char*)malloc(ct_len);
    if (!plaintext) {
        crypto_secure_zero(enc_key, sizeof(enc_key));
        crypto_secure_zero(mac_key, sizeof(mac_key));
        return crypto_result_err("out of memory");
    }

    size_t pt_written = 0;
#ifdef __APPLE__
    CCCryptorStatus status = CCCrypt(
        kCCDecrypt,
        kCCAlgorithmAES,
        kCCOptionPKCS7Padding,
        enc_key, CRYPTO_KEY_LEN,
        iv,
        ct, ct_len,
        plaintext,
        ct_len,  // plaintext <= ciphertext for CBC
        &pt_written
    );
    if (status != kCCSuccess) {
        free(plaintext);
        crypto_secure_zero(enc_key, sizeof(enc_key));
        crypto_secure_zero(mac_key, sizeof(mac_key));
        return crypto_result_err("decryption failed");
    }
#else
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        free(plaintext);
        crypto_secure_zero(enc_key, sizeof(enc_key));
        crypto_secure_zero(mac_key, sizeof(mac_key));
        return crypto_result_err("decryption init failed");
    }
    EVP_DecryptInit_ex(ctx, EVP_aes_256_cbc(), NULL, enc_key, iv);
    int update_len = 0, final_len = 0;
    EVP_DecryptUpdate(ctx, plaintext, &update_len, ct, (int)ct_len);
    int rc = EVP_DecryptFinal_ex(ctx, plaintext + update_len, &final_len);
    EVP_CIPHER_CTX_free(ctx);
    if (rc != 1) {
        free(plaintext);
        crypto_secure_zero(enc_key, sizeof(enc_key));
        crypto_secure_zero(mac_key, sizeof(mac_key));
        return crypto_result_err("decryption failed (padding)");
    }
    pt_written = (size_t)(update_len + final_len);
#endif

    blorp_Bytes* result = crypto_bytes_from_raw(plaintext, (long)pt_written);
    free(plaintext);
    crypto_secure_zero(enc_key, sizeof(enc_key));
    crypto_secure_zero(mac_key, sizeof(mac_key));

    return crypto_result_ok((void*)result);
}

// derive_key(password: String, salt: Bytes, iterations: Int) -> Bytes
// PBKDF2-SHA256, returns 32-byte key. Defaults to 100000 iterations if <= 0.
static inline blorp_Bytes* blorp_crypto_derive_key(const char* password, blorp_Bytes* salt, long iterations) {
    unsigned char derived[CRYPTO_KEY_LEN];
    size_t pw_len = strlen(password);
    const unsigned char* salt_data = (salt && salt->len > 0) ? salt->data : (const unsigned char*)"";
    size_t salt_len = (salt && salt->len > 0) ? (size_t)salt->len : 0;
    if (iterations <= 0) iterations = 100000;
    if (iterations > (long)UINT32_MAX) iterations = (long)UINT32_MAX;
    unsigned int rounds = (unsigned int)iterations;

#ifdef __APPLE__
    CCKeyDerivationPBKDF(
        kCCPBKDF2,
        password, pw_len,
        salt_data, salt_len,
        kCCPRFHmacAlgSHA256,
        rounds,
        derived, CRYPTO_KEY_LEN
    );
#else
    PKCS5_PBKDF2_HMAC(
        password, (int)pw_len,
        salt_data, (int)salt_len,
        rounds,
        EVP_sha256(),
        CRYPTO_KEY_LEN, derived
    );
#endif

    blorp_Bytes* result = crypto_bytes_from_raw(derived, CRYPTO_KEY_LEN);
    crypto_secure_zero(derived, sizeof(derived));
    return result;
}

#endif // BLORP_CRYPTO_FFI_H
