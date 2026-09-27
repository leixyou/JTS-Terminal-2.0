#ifndef JTS_PINNED_TLS_H
#define JTS_PINNED_TLS_H
#include <stddef.h>
#include <stdint.h>

typedef struct JTSPinnedTLS JTSPinnedTLS;
/* Identity DER is copied into OpenSSL-owned key storage, never retained as a raw buffer. */
JTSPinnedTLS *jts_tls_create(const uint8_t *private_der, size_t private_length,
                           const uint8_t peer_spki_sha256[32], int allow_tls12, int server);
void jts_tls_free(JTSPinnedTLS *tls);
/* Results: 1 success, 0 needs more input/output, -1 terminal failure, -2 clean EOF. */
int jts_tls_handshake(JTSPinnedTLS *tls);
int jts_tls_feed(JTSPinnedTLS *tls, const uint8_t *bytes, size_t count);
int jts_tls_drain(JTSPinnedTLS *tls, uint8_t *bytes, size_t capacity, size_t *written);
int jts_tls_read(JTSPinnedTLS *tls, uint8_t *bytes, size_t capacity, size_t *written);
int jts_tls_write(JTSPinnedTLS *tls, const uint8_t *bytes, size_t count, size_t *written);
int jts_tls_is_authenticated(const JTSPinnedTLS *tls);
#endif
