#include "JTSPinnedTLS.h"
#include <openssl/ssl.h>
#include <openssl/crypto.h>
#include <openssl/core_names.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>
#include <string.h>

#define JTS_TLS_BUFFER_LIMIT (128 * 1024)
#define JTS_TLS_CHUNK_LIMIT (64 * 1024)
static const unsigned char jts_alpn[] = {12, 'j','t','s','-','r','e','l','a','y','-','v','1'};

struct JTSPinnedTLS {
    SSL_CTX *context;
    SSL *ssl;
    BIO *incoming;
    BIO *outgoing;
    unsigned char peer_pin[32];
    int authenticated;
    int failed;
};

static int is_p256(EVP_PKEY *key) {
    char group[80];
    size_t length = 0;
    return key && EVP_PKEY_is_a(key, "EC") &&
        EVP_PKEY_get_utf8_string_param(key, OSSL_PKEY_PARAM_GROUP_NAME, group, sizeof(group), &length) == 1 &&
        (strcmp(group, "prime256v1") == 0 || strcmp(group, "P-256") == 0);
}

static int verify_pinned_peer(int preverified, X509_STORE_CTX *store) {
    (void)preverified;
    SSL *ssl = X509_STORE_CTX_get_ex_data(store, SSL_get_ex_data_X509_STORE_CTX_idx());
    JTSPinnedTLS *tls = ssl ? SSL_get_app_data(ssl) : NULL;
    if (!tls) return 0;
    if (X509_STORE_CTX_get_error_depth(store) != 0) return 1;
    X509 *certificate = X509_STORE_CTX_get_current_cert(store);
    EVP_PKEY *key = certificate ? X509_get_pubkey(certificate) : NULL;
    unsigned char *spki = NULL, digest[32];
    unsigned int digest_length = 0;
    int length = key ? i2d_PUBKEY(key, &spki) : 0;
    int valid = certificate && is_p256(key) && length > 0 &&
        X509_cmp_current_time(X509_get0_notBefore(certificate)) < 0 &&
        X509_cmp_current_time(X509_get0_notAfter(certificate)) > 0 &&
        EVP_Digest(spki, (size_t)length, digest, &digest_length, EVP_sha256(), NULL) == 1 &&
        digest_length == sizeof(digest) && CRYPTO_memcmp(digest, tls->peer_pin, sizeof(digest)) == 0;
    OPENSSL_free(spki);
    EVP_PKEY_free(key);
    X509_STORE_CTX_set_error(store, valid ? X509_V_OK : X509_V_ERR_APPLICATION_VERIFICATION);
    return valid;
}

static int select_alpn(SSL *ssl, const unsigned char **out, unsigned char *out_length,
                       const unsigned char *input, unsigned int input_length, void *argument) {
    (void)ssl; (void)argument;
    return SSL_select_next_proto((unsigned char **)out, out_length, jts_alpn, sizeof(jts_alpn),
                                 input, input_length) == OPENSSL_NPN_NEGOTIATED
        ? SSL_TLSEXT_ERR_OK : SSL_TLSEXT_ERR_ALERT_FATAL;
}

static int certificate_extension(X509 *certificate, int nid, const char *value) {
    X509_EXTENSION *extension = X509V3_EXT_conf_nid(NULL, NULL, nid, value);
    if (!extension) return 0;
    int result = X509_add_ext(certificate, extension, -1);
    X509_EXTENSION_free(extension);
    return result;
}

static X509 *identity_certificate(EVP_PKEY *key) {
    X509 *certificate = X509_new();
    if (!certificate) return NULL;
    X509_NAME *subject = X509_get_subject_name(certificate);
    if (X509_set_version(certificate, 2) != 1 ||
        ASN1_INTEGER_set(X509_get_serialNumber(certificate), 1) != 1 ||
        !X509_gmtime_adj(X509_getm_notBefore(certificate), -300) ||
        !X509_gmtime_adj(X509_getm_notAfter(certificate), 24 * 60 * 60) ||
        X509_set_pubkey(certificate, key) != 1 ||
        X509_NAME_add_entry_by_txt(subject, "CN", MBSTRING_ASC,
                                  (const unsigned char *)"JTS paired device", -1, -1, 0) != 1 ||
        X509_set_issuer_name(certificate, subject) != 1 ||
        !certificate_extension(certificate, NID_basic_constraints, "critical,CA:FALSE") ||
        !certificate_extension(certificate, NID_key_usage, "critical,digitalSignature") ||
        !certificate_extension(certificate, NID_ext_key_usage, "serverAuth,clientAuth") ||
        X509_sign(certificate, key, EVP_sha256()) <= 0) {
        X509_free(certificate);
        return NULL;
    }
    return certificate;
}

JTSPinnedTLS *jts_tls_create(const uint8_t *private_der, size_t private_length,
                           const uint8_t peer_spki_sha256[32], int allow_tls12, int server) {
    if (!private_der || !peer_spki_sha256 || private_length == 0 || private_length > 4096) return NULL;
    const unsigned char *cursor = private_der;
    EVP_PKEY *key = d2i_AutoPrivateKey(NULL, &cursor, (long)private_length);
    if (!is_p256(key) || cursor != private_der + private_length) { EVP_PKEY_free(key); return NULL; }
    X509 *certificate = identity_certificate(key);
    JTSPinnedTLS *tls = OPENSSL_zalloc(sizeof(*tls));
    if (!certificate || !tls) goto fail;
    memcpy(tls->peer_pin, peer_spki_sha256, 32);
    tls->context = SSL_CTX_new(TLS_method());
    if (!tls->context ||
        SSL_CTX_set_min_proto_version(tls->context, allow_tls12 ? TLS1_2_VERSION : TLS1_3_VERSION) != 1 ||
        SSL_CTX_set_max_proto_version(tls->context, TLS1_3_VERSION) != 1 ||
        SSL_CTX_set_cipher_list(tls->context, "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256") != 1 ||
        SSL_CTX_set_ciphersuites(tls->context, "TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256") != 1 ||
        SSL_CTX_set1_groups_list(tls->context, "P-256:X25519") != 1 ||
        SSL_CTX_set_max_early_data(tls->context, 0) != 1 ||
        SSL_CTX_use_certificate(tls->context, certificate) != 1 ||
        SSL_CTX_use_PrivateKey(tls->context, key) != 1 || SSL_CTX_check_private_key(tls->context) != 1) goto fail;
    SSL_CTX_set_options(tls->context, SSL_OP_NO_COMPRESSION | SSL_OP_NO_TICKET | SSL_OP_NO_RENEGOTIATION);
    SSL_CTX_set_session_cache_mode(tls->context, SSL_SESS_CACHE_OFF);
    SSL_CTX_set_num_tickets(tls->context, 0);
    SSL_CTX_set_verify(tls->context, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, verify_pinned_peer);
    SSL_CTX_set_verify_depth(tls->context, 2);
    if (server) SSL_CTX_set_alpn_select_cb(tls->context, select_alpn, NULL);
    tls->ssl = SSL_new(tls->context);
    tls->incoming = BIO_new(BIO_s_mem());
    tls->outgoing = BIO_new(BIO_s_mem());
    if (!tls->ssl || !tls->incoming || !tls->outgoing) goto fail;
    BIO_set_mem_eof_return(tls->incoming, -1);
    BIO_set_mem_eof_return(tls->outgoing, -1);
    SSL_set_bio(tls->ssl, tls->incoming, tls->outgoing);
    SSL_set_app_data(tls->ssl, tls);
    SSL_set_mode(tls->ssl, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    if (server) SSL_set_accept_state(tls->ssl);
    else {
        SSL_set_connect_state(tls->ssl);
        if (SSL_set_alpn_protos(tls->ssl, jts_alpn, sizeof(jts_alpn)) != 0) goto fail;
    }
    X509_free(certificate);
    EVP_PKEY_free(key);
    return tls;
fail:
    X509_free(certificate);
    EVP_PKEY_free(key);
    jts_tls_free(tls);
    return NULL;
}

void jts_tls_free(JTSPinnedTLS *tls) {
    if (!tls) return;
    if (tls->ssl && SSL_get_rbio(tls->ssl)) SSL_free(tls->ssl);
    else { SSL_free(tls->ssl); BIO_free(tls->incoming); BIO_free(tls->outgoing); }
    SSL_CTX_free(tls->context);
    OPENSSL_clear_free(tls, sizeof(*tls));
}

static int result(JTSPinnedTLS *tls, int value) {
    if (value > 0) return 1;
    int code = SSL_get_error(tls->ssl, value);
    if (code == SSL_ERROR_WANT_READ || code == SSL_ERROR_WANT_WRITE) return 0;
    tls->failed = 1;
    return code == SSL_ERROR_ZERO_RETURN ? -2 : -1;
}

int jts_tls_handshake(JTSPinnedTLS *tls) {
    if (!tls || tls->failed) return -1;
    if (tls->authenticated) return 1;
    ERR_clear_error();
    int value = SSL_do_handshake(tls->ssl);
    int status = result(tls, value);
    if (status == 1) {
        const unsigned char *alpn = NULL;
        unsigned int length = 0;
        SSL_get0_alpn_selected(tls->ssl, &alpn, &length);
        X509 *peer = SSL_get1_peer_certificate(tls->ssl);
        int accepted = peer && SSL_get_verify_result(tls->ssl) == X509_V_OK &&
            length == sizeof(jts_alpn) - 1 && CRYPTO_memcmp(alpn, jts_alpn + 1, length) == 0;
        X509_free(peer);
        if (!accepted) { tls->failed = 1; return -1; }
        tls->authenticated = 1;
    }
    return status;
}

int jts_tls_feed(JTSPinnedTLS *tls, const uint8_t *bytes, size_t count) {
    if (!tls || tls->failed || !bytes || !count || count > JTS_TLS_CHUNK_LIMIT ||
        BIO_ctrl_pending(tls->incoming) + count > JTS_TLS_BUFFER_LIMIT) return -1;
    return BIO_write(tls->incoming, bytes, (int)count) == (int)count ? 1 : -1;
}

int jts_tls_drain(JTSPinnedTLS *tls, uint8_t *bytes, size_t capacity, size_t *written) {
    if (written) *written = 0;
    if (!tls || !bytes || !written || !capacity || capacity > JTS_TLS_CHUNK_LIMIT) return -1;
    size_t pending = BIO_ctrl_pending(tls->outgoing);
    if (pending > JTS_TLS_BUFFER_LIMIT) { tls->failed = 1; return -1; }
    if (!pending) return 0;
    int count = BIO_read(tls->outgoing, bytes, (int)capacity);
    if (count <= 0) return -1;
    *written = (size_t)count;
    return 1;
}

int jts_tls_read(JTSPinnedTLS *tls, uint8_t *bytes, size_t capacity, size_t *written) {
    if (written) *written = 0;
    if (!tls || tls->failed || !tls->authenticated || !bytes || !written || !capacity || capacity > JTS_TLS_CHUNK_LIMIT) return -1;
    ERR_clear_error();
    return result(tls, SSL_read_ex(tls->ssl, bytes, capacity, written));
}

int jts_tls_write(JTSPinnedTLS *tls, const uint8_t *bytes, size_t count, size_t *written) {
    if (written) *written = 0;
    if (!tls || tls->failed || !tls->authenticated || !bytes || !written || !count || count > JTS_TLS_CHUNK_LIMIT ||
        BIO_ctrl_pending(tls->outgoing) + count > JTS_TLS_BUFFER_LIMIT - 4096) return -1;
    ERR_clear_error();
    return result(tls, SSL_write_ex(tls->ssl, bytes, count, written));
}

int jts_tls_is_authenticated(const JTSPinnedTLS *tls) { return tls && tls->authenticated && !tls->failed; }
