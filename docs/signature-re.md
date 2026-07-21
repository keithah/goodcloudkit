# GoodCloud web app — request `signature` / `token` reverse engineering

**Target:** `https://api.goodcloud.xyz` (`/cloud-api/...`, `/cloud-basic/...`)
**Bundles analyzed:** `index.BjjMhIwv.js` (main), `deviceDetailPage.BE9r2L5V.js` (route chunk — contains **no** signing code; it reuses the shared axios service from the main bundle).

## TL;DR

The `signature` header is **NOT** an HMAC or a hash. It is the current millisecond timestamp (`Date.now().toString()`) **RSA-encrypted** with a hardcoded **512-bit RSA public key** using **PKCS#1 v1.5 (type-2) padding**, then hex→base64 encoded. Because PKCS#1 v1.5 uses random padding bytes, **the signature is non-deterministic** — a fresh, different 88-character base64 string every request, even for the same timestamp. The server decrypts it with the matching private key to recover the timestamp (freshness/anti-replay check).

The `token` header is simply the `FE_TOKEN` cookie value, passed through verbatim.

There is **no `timestamp` or `nonce` header** — the timestamp is *inside* the encrypted signature only. No `appId`/`appSecret`/shared-secret string is involved.

## The request interceptor (the source of truth)

Found via search `interceptors.request` (2nd hit) in `index.BjjMhIwv.js`. The axios factory `woe(e=true)`:

```js
const n=XB.create({baseURL:"/",timeout:3e4});
return n.interceptors.request.use(r=>{
  if(e&&s2e(r),
     r.headers.token=V7()||"",
     r.headers.signature=hoe(Date.now().toString()),
     r.formData){ ...FormData... }
  const{apiPrefix:a}=r;
  return r.baseURL=`${H2e}${a||""}`,r
}, ...);
```

- `r.headers.token = V7() || ""`
- `r.headers.signature = hoe(Date.now().toString())`  ← the only signature computation

`s2e(r)` / `QB(r)` are **request de-duplication only** (AbortController map keyed by
`foe = e=>[e.method,e.url, params, data].join("&")`). They do **not** feed the signature. This rules out the "canonical string of method+path+params+body" hypothesis — that string exists in the code but is used solely to cancel duplicate in-flight requests.

## `signature` = `hoe(timestamp)` — RSA encrypt

Found via search `hoe=` in `index.BjjMhIwv.js`:

```js
const hoe=function(e){
  const t="MFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAItoR8lrBZ/ZaJZ3XvvgP8I31ImaTwbEPzPElmIZAasWoAzw3InqMVyeL7rTlFS3TFz3HMKBnrFlr463Bu19Tz0CAwEAAQ==",
  n=new o2e;             // JSEncrypt instance
  return n.setPublicKey(t),n.encrypt(e)
};
```

- Input `e` = `Date.now().toString()` (decimal ms epoch, e.g. `"1753100000000"`).
- `o2e` is **JSEncrypt** (its class shape — `setPublicKey`/`encrypt`/`decrypt`/`sign`/`signSha256`, `default_key_size`, `default_public_exponent="010001"` — matches JSEncrypt exactly).

### The hardcoded RSA public key (SPKI, base64 DER) — verbatim

```
MFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAItoR8lrBZ/ZaJZ3XvvgP8I31ImaTwbEPzPElmIZAasWoAzw3InqMVyeL7rTlFS3TFz3HMKBnrFlr463Bu19Tz0CAwEAAQ==
```

Decoded (verified with `openssl rsa -pubin -text`):
- **Key size: 512 bits**
- **Modulus (n):** `8b6847c96b059fd96896775efbe03fc237d4899a4f06c43f33c496621901ab16a00cf0dc89ea315c9e2fbad39454b74c5cf71cc2819eb165af8eb706ed7d4f3d`
- **Exponent (e):** `65537` (0x10001)

PEM form:
```
-----BEGIN PUBLIC KEY-----
MFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAItoR8lrBZ/ZaJZ3XvvgP8I31ImaTwbEPzP
ElmIZAasWoAzw3InqMVyeL7rTlFS3TFz3HMKBnrFlr463Bu19Tz0CAwEAAQ==
-----END PUBLIC KEY-----
```

### JSEncrypt `.encrypt()` — encoding & padding

`o2e.prototype.encrypt` (search `.setPublicKey=`):
```js
e.prototype.encrypt=function(t){try{return I1(this.getKey().encrypt(t))}catch(n){return!1}};
```
- `getKey().encrypt(t)` is `RSAKey.encrypt` (search `.prototype.encrypt=`), returns a **hex** string, zero-left-padded to `i = (n.bitLength()+7)>>3` bytes → for a 512-bit key, 64 bytes = **128 hex chars**.
  ```js
  e.prototype.encrypt=function(t,n){typeof n>"u"&&(n=wCe);var i=this.n.bitLength()+7>>3,r=n(t,i);...var a=this.doPublic(r);...for(var o=a.toString(16),s=o.length,l=0;l<i*2-s;l++)o="0"+o;return o};
  ```
- Padding `wCe` (default) is **PKCS#1 v1.5 EME (type 2)** with **random** bytes (search `function wCe`): `...n[--t]=2,n[--t]=0,...` and fills with `WB` (SecureRandom) nonzero bytes. → **non-deterministic ciphertext**.
- `I1` is JSEncrypt's `hex2b64` (search `I1(`): converts the 128-hex string to **base64** → 88 chars (`Vv` = standard base64 alphabet, `loe = "="` padding).

**Net: `signature = base64( RSA_PKCS1v1_5_encrypt( pubkey_512, timestamp_ms_string ) )`, 88 chars.**

Verified live with openssl: `echo -n <ms-timestamp> | openssl rsautl -encrypt -pubin -inkey pub.pem -pkcs | base64` → an 88-char base64 string, matching the expected format.

## `token` = `V7()` — the FE_TOKEN cookie

Found via search `function V7` in `index.BjjMhIwv.js`:
```js
const mIe="FE_TOKEN", gIe="FE_TOKEN_CUSTOM", noe=window.location.hostname;
function ioe(){return Op()?mIe:gIe}
function V7(){return D1.get(ioe())}          // D1 = js-cookie
function Dst(e){D1.set(ioe(),e,{domain:noe})}
```
- `D1` is **js-cookie** (`Lc(pIe)`).
- `Op()` (search `Op=`) returns true when the locale is English, Chinese, or localhost:
  `Op=function(){const{isEn,isZh,isLocalhost}=I7();return!!(isEn||isZh||isLocalhost)}`.
  For `goodcloud.xyz` (English/overseas) this is **true**, so the cookie name is **`FE_TOKEN`**.
- **`token` header = the raw `FE_TOKEN` cookie string, unchanged** (no transform, hashing, or prefix). It is set at login via `Dst` on domain `.goodcloud.xyz` and read back verbatim.

## timestamp / nonce

- **No separate `timestamp` header, no `nonce` header.** Grep of the interceptor confirms only `token` and `signature` are set (plus `Content-Type`/`Accept` that axios adds for POST bodies).
- The only "timestamp" is the ms-epoch string that is the *plaintext inside* the RSA signature. There is no client-side nonce field; the randomness comes from PKCS#1 v1.5 padding.

## Not the signature (ruled out)

- CryptoJS `HmacSHA256` / `HmacMD5` in the bundle are just the **library definitions** (`r.HmacSHA256=s._createHmacHelper(m)`), never invoked for API signing.
- The single `.MD5(...)` call is `iat()` — MD5 of a browser/arch fingerprint object (`Wrt()` → arm/aarch64/unk), used for telemetry/device-id, **not** the request signature.
- `foe(...).join("&")` (method/url/params/data) is only the AbortController dedup key.

## Reference implementation (Python)

```python
import base64, time
# pip install pycryptodome
from Crypto.PublicKey import RSA
from Crypto.Cipher import PKCS1_v1_5

# Hardcoded GoodCloud web-client RSA public key (SPKI DER, base64), 512-bit, e=65537.
_PUBKEY_DER_B64 = (
    "MFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAItoR8lrBZ/ZaJZ3XvvgP8I31ImaTwbEPzP"
    "ElmIZAasWoAzw3InqMVyeL7rTlFS3TFz3HMKBnrFlr463Bu19Tz0CAwEAAQ=="
)
_PUBKEY = RSA.import_key(base64.b64decode(_PUBKEY_DER_B64))
_CIPHER = PKCS1_v1_5.new(_PUBKEY)

def make_signature(timestamp_ms: int | None = None) -> str:
    """Reproduce hoe(Date.now().toString()): RSA/PKCS1v1.5-encrypt the ms
    timestamp string, hex->base64. Non-deterministic (random padding)."""
    if timestamp_ms is None:
        timestamp_ms = int(time.time() * 1000)
    ct = _CIPHER.encrypt(str(timestamp_ms).encode("ascii"))  # 64 bytes
    return base64.b64encode(ct).decode("ascii")              # 88 chars

def auth_headers(fe_token: str) -> dict:
    """Headers every GoodCloud API request carries."""
    return {"token": fe_token, "signature": make_signature()}

# Full signature builder matching the task's requested shape. Note: only the
# timestamp actually affects the signature; method/path/query/body/token/nonce
# are IGNORED by the real client (kept here for interface parity).
def sign(method=None, path=None, query=None, body=None,
         token=None, timestamp=None, nonce=None) -> str:
    return make_signature(timestamp)
```

Equivalent one-liner check with the shell (openssl):
```sh
echo -n "$(python3 -c 'import time;print(int(time.time()*1000))')" \
  | openssl rsautl -encrypt -pubin -inkey pub.pem -pkcs | base64 | tr -d '\n'
```
where `pub.pem` is the PEM above.

## Confidence & assumptions

**Confidence: HIGH.**
- The interceptor, `hoe`, `V7`, the JSEncrypt class, padding, and hex2b64 were all read directly and cross-checked; the public key was decoded and validated with openssl (512-bit, e=65537); the output length (88 b64 chars) was reproduced.

Assumptions / caveats:
- The signature is intentionally **non-deterministic** (PKCS#1 v1.5 random padding), so you cannot byte-match a captured value — you can only produce a *valid* one. Server-side validation must be RSA-decrypt-then-check-timestamp; I could not observe the server's freshness window (likely a few minutes).
- I did not observe the exact `FE_TOKEN` transform at login beyond `Dst`/`V7` (set/get verbatim). The value stored in the cookie is whatever the login endpoint returned; the header sends it unchanged.
- Locale gate `Op()` selects `FE_TOKEN` vs `FE_TOKEN_CUSTOM`; on goodcloud.xyz it is `FE_TOKEN`.
