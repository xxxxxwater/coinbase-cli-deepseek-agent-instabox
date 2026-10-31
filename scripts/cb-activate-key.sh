#!/usr/bin/env bash
# Re-point the Coinbase CLI at a CDP API key file, then verify read-only access.
#
#   ./cb-activate-key.sh /path/to/cdp_api_key.json
#
# The key MUST be ECDSA (ES256). An Ed25519 key is rejected by Coinbase with
# HTTP 401 "Coinbase Advanced Trade requires an ECDSA key".
set -uo pipefail

KEY="${1:-}"
if [[ -z "$KEY" ]]; then
  echo "usage: $0 /path/to/cdp_api_key.json" >&2
  exit 2
fi
if [[ ! -r "$KEY" ]]; then
  echo "error: cannot read $KEY" >&2
  exit 2
fi

# Refuse an Ed25519 key up front instead of letting the API return 401.
KIND=$(node -e '
const fs=require("fs"),crypto=require("crypto");
let d;
try { d=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); } catch(e){ console.log("UNREADABLE"); process.exit(0); }
const pk=d.privateKey||d.private_key||d.secret;
if(!pk){ console.log("NO_SECRET"); process.exit(0); }
const raw=Buffer.from(pk,"base64");
if(raw.length===32){ console.log("ECDSA"); process.exit(0); }
if(raw.length===64){
  const seed=raw.subarray(0,32), pub=raw.subarray(32,64);
  try{
    const der=Buffer.concat([Buffer.from("302e020100300506032b657004220420","hex"),seed]);
    const spki=crypto.createPublicKey(crypto.createPrivateKey({key:der,format:"der",type:"pkcs8"})).export({format:"der",type:"spki"});
    if(spki.subarray(spki.length-32).equals(pub)){ console.log("ED25519"); process.exit(0); }
  }catch(e){}
  console.log("UNKNOWN64"); process.exit(0);
}
console.log("UNKNOWN");
' "$KEY" 2>/dev/null)

echo "key file : $KEY"
echo "key type : $KIND"
case "$KIND" in
  ED25519)
    echo
    echo "REFUSING: this is an Ed25519 key. Coinbase App / Advanced Trade / Agents API"
    echo "requires ECDSA (ES256). Recreate the key in the CDP portal with"
    echo "'Signature algorithm = ECDSA' (step 6), then retry."
    exit 1
    ;;
  ECDSA) : ;;
  *)
    echo "warning: could not determine key type; continuing anyway" >&2
    ;;
esac

set -e
coinbase env live --key-file "$KEY" --allow-plaintext-secrets
chmod 600 "$HOME/.config/coinbase/config.json"

echo
echo "=== coinbase env ==="
coinbase env
echo
echo "=== read-only smoke test ==="
echo "--- api-key permissions ---"
coinbase api-key permissions || echo "FAILED"
echo "--- balance ---"
coinbase balance || echo "FAILED"
echo "--- portfolios list ---"
coinbase portfolios list || echo "FAILED"
echo "--- fees ---"
coinbase fees || echo "FAILED"
echo "--- products get BTC-USD ---"
coinbase products get BTC-USD --jq '{product_id, price, base_currency_id, quote_currency_id}' || echo "FAILED"
echo "--- products list symbol==USD (count) ---"
coinbase products list symbol==USD --jq 'length' || echo "FAILED"
