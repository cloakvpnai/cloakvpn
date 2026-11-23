"""Builds the base64 config for Cnsa2LabActivity.

  lab-config.py <pki dir> <gateway host> <rekey seconds>            lab client key and certificate from the pki dir
  lab-config.py <pki dir> <gateway host> <rekey seconds> <name>     the phone's own enrolled identity <name>
"""
import sys, json, base64
p, host, rekey = sys.argv[1], sys.argv[2], int(sys.argv[3])
b = lambda f: base64.b64encode(open(p + '/' + f, 'rb').read()).decode()
c = {"host": host, "port": 4500, "gatewayID": "gw.lattice.lab", "caDER": b("ca.der"), "rekeySeconds": rekey}
if len(sys.argv) > 4:
    c["clientID"] = sys.argv[4]
else:
    c.update(clientID="device1.lattice.lab", clientCertDER=b("client.der"), clientKeyPKCS8=b("client.key.der"))
print(base64.b64encode(json.dumps(c).encode()).decode())
