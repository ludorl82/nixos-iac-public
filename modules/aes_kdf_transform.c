/*
 * aes_kdf_transform — the AES-KDF key-transform loop of a KDBX header, in C.
 *
 * pykeepass's aes_kdf() runs the transform_rounds loop (600k for this DB) as
 * one Python-level cipher.encrypt() per round: ~9.4us/round of interpreter +
 * cffi overhead, ~5.5s total, even though the AES work itself is trivial.
 * Doing the same loop inside one process via OpenSSL costs ~1us/round.
 *
 * Called by /opt/scripts/process_keepass{,_family}.py, which monkey-patch
 * pykeepass to shell out here and fall back to the pure-Python loop on any
 * error — so a bad build degrades to "slow", never to "broken".
 *
 *   usage: aes_kdf_transform <key-hex> <composite-hex> <rounds>
 *
 * <key-hex>       transform seed, 16/24/32 bytes hex-encoded
 * <composite-hex> the composite key, 32 bytes hex-encoded
 * <rounds>        number of ECB encryptions to chain
 *
 * Prints the transformed key as lowercase hex. The caller does the trailing
 * sha256 itself, matching pykeepass's return value.
 */
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define COMPOSITE_LEN 32

static int hex2bin(const char *hex, unsigned char *out, size_t outlen)
{
    if (strlen(hex) != outlen * 2)
        return -1;
    for (size_t i = 0; i < outlen; i++) {
        unsigned int byte;
        if (sscanf(hex + 2 * i, "%2x", &byte) != 1)
            return -1;
        out[i] = (unsigned char)byte;
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s <key-hex> <composite-hex> <rounds>\n", argv[0]);
        return 2;
    }

    /* Key length picks the cipher, exactly as pycryptodome's AES.new() does. */
    size_t keylen = strlen(argv[1]) / 2;
    const EVP_CIPHER *cipher;
    switch (keylen) {
    case 16: cipher = EVP_aes_128_ecb(); break;
    case 24: cipher = EVP_aes_192_ecb(); break;
    case 32: cipher = EVP_aes_256_ecb(); break;
    default:
        fprintf(stderr, "key must be 16, 24 or 32 bytes of hex\n");
        return 2;
    }

    unsigned char key[32];
    unsigned char buf[COMPOSITE_LEN];
    if (hex2bin(argv[1], key, keylen) != 0) {
        fprintf(stderr, "key is not valid hex\n");
        return 2;
    }
    if (hex2bin(argv[2], buf, COMPOSITE_LEN) != 0) {
        fprintf(stderr, "composite must be %d bytes of hex\n", COMPOSITE_LEN);
        return 2;
    }

    char *end;
    unsigned long long rounds = strtoull(argv[3], &end, 10);
    if (*argv[3] == '\0' || *end != '\0') {
        fprintf(stderr, "rounds is not a number\n");
        return 2;
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (ctx == NULL) {
        fprintf(stderr, "EVP_CIPHER_CTX_new failed\n");
        return 1;
    }
    if (EVP_EncryptInit_ex(ctx, cipher, NULL, key, NULL) != 1) {
        fprintf(stderr, "EVP_EncryptInit_ex failed\n");
        return 1;
    }
    /* No padding: 32 bytes in, 32 bytes out, every round. */
    EVP_CIPHER_CTX_set_padding(ctx, 0);

    unsigned char out[COMPOSITE_LEN];
    int outlen;
    for (unsigned long long i = 0; i < rounds; i++) {
        if (EVP_EncryptUpdate(ctx, out, &outlen, buf, COMPOSITE_LEN) != 1 ||
            outlen != COMPOSITE_LEN) {
            fprintf(stderr, "EVP_EncryptUpdate failed at round %llu\n", i);
            return 1;
        }
        memcpy(buf, out, COMPOSITE_LEN);
    }
    EVP_CIPHER_CTX_free(ctx);

    for (int i = 0; i < COMPOSITE_LEN; i++)
        printf("%02x", buf[i]);
    printf("\n");
    return 0;
}
