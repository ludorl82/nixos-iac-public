## Trust the homelab's private root CA, `pki.example.com`.
##
## It issues the `*.lab.example` wildcard cert Traefik serves for the private
## services (kuma.lab.example, frigate.lab.example, grafana.lab.example,
## traefik.lab.example, unifi.lab.example). Without this a host can't talk HTTPS
## to any of them: `curl` fails with `unable to get local issuer
## certificate (20)`. The standing rule for this fleet is real CA trust,
## never `--insecure` / `verify=False` / `ignoreTls`.
##
## On the pre-NixOS (Debian/Ubuntu) hosts this was a manual step -
## drop the cert in /usr/local/share/ca-certificates/ and run
## `update-ca-certificates` - which meant it silently did NOT survive a
## host's conversion to NixOS, and had to be redone by hand every time a
## node joined. Declaring it here makes it part of the closure instead.
##
## The file is the CA's *public* certificate (self-signed root, subject =
## issuer = CN=pki.example.com, valid to 2039-04-30, SHA256
## 12:D8:25:B9:...:6A:4B). No private key material is in this repo.
##
## 2026-07-25: this root was RE-ISSUED. The 2024 cert (SHA256
## 8F:69:AD:52:...:76:65, kept as pki.example.com.crt.pre-critical-20260725
## in the CA store) had two RFC 5280 defects: `basicConstraints CA:TRUE` was
## not marked *critical*, and it carried no `keyUsage` extension at all.
## curl/OpenSSL-default/Node accept that; **Python 3.13+ does not**, because
## `ssl.create_default_context()` now sets `VERIFY_X509_STRICT` by default:
##
##   [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed:
##   Basic Constraints of CA cert not marked critical
##
## The symptom is confusing - the same https://*.lab.example URL works from curl
## and fails from Python *on the same host* - and it looks exactly like a
## missing-CA-trust problem, so it invites pointless `update-ca-certificates`
## debugging. It is not a trust problem.
##
## The fix re-signed the root from the SAME private key with the SAME subject
## DER (via `openssl x509 -x509toreq`, so leaf.issuer still matches
## root.subject byte-for-byte) and the same expiry. Because the public key is
## unchanged, the Subject Key Identifier is unchanged (34:D5:A2:E9:...), so
## every existing leaf's keyid-only Authority Key Identifier still matches and
## **all previously issued certs remain valid** - this was a root-cert reissue,
## not a PKI rotation. Nothing had to be re-imported on phones/laptops: they
## keep the old root, which still validates the same leaves.
##
## Deliberately REPLACING rather than trusting both roots: with both in the
## store, chain building may pick the malformed one as the anchor and fail
## strict verification anyway, which would defeat the point.
##
## NB: this covers the *system* trust store. Container runtimes keep their
## own cached view, so k3s needs a restart after this first lands on a node
## for containerd to pick it up. Language runtimes that ship their own
## bundle (Python/certifi, Node) still need pointing at the system bundle
## explicitly - see the private-ca-trust notes for SSL_CERT_FILE /
## REQUESTS_CA_BUNDLE / NODE_EXTRA_CA_CERTS.
{ ... }:
{
  security.pki.certificateFiles = [ ./pki.example.com.crt ];
}
