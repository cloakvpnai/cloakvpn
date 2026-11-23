"""Gateway settings for the app's CNSA 2.0 mode, as base64 JSON for Cnsa2LabActivity.

  lab-config.py <ca.pem or ca.der> <gateway host> <rekey seconds> [gateway name] [port]

Holds no secrets: the device key never leaves the phone.
"""
import sys, json, base64, ssl
raw = open(sys.argv[1], 'rb').read()
der = ssl.PEM_cert_to_DER_cert(raw.decode()) if raw.startswith(b'-----') else raw
c = {"host": sys.argv[2], "port": int(sys.argv[5]) if len(sys.argv) > 5 else 1194,
     "gatewayID": sys.argv[4] if len(sys.argv) > 4 else "gateway.tls.lattice.lab",
     "clientID": "", "caDER": base64.b64encode(der).decode(), "rekeySeconds": int(sys.argv[3])}
print(base64.b64encode(json.dumps(c).encode()).decode())
