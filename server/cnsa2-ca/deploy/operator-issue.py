import base64, json, sys, urllib.request
kind, name = sys.argv[1], sys.argv[2]
token = [l.split("=",1)[1].strip() for l in open("/etc/cloakvpn/api.env") if l.startswith("CNSA2_SIGNER_TOKEN=")][0]
req = base64.b64encode(sys.stdin.buffer.read()).decode()
r = urllib.request.Request("http://10.200.0.2:8087/v1/issue", data=json.dumps({"kind": kind, "name": name, "request": req}).encode(), headers={"Authorization": "Bearer " + token})
out = json.loads(urllib.request.urlopen(r, timeout=40).read())
sys.stderr.write("issued %s %s serial %s until %s\n" % (kind, name, out["serial"], out["notAfter"]))
print(json.dumps({k: out[k] for k in ("certificate", "issuing", "root")}))
