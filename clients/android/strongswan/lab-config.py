import sys,json,base64
p,host,rekey=sys.argv[1],sys.argv[2],int(sys.argv[3]); b=lambda f: base64.b64encode(open(p+'/'+f,'rb').read()).decode()
print(base64.b64encode(json.dumps({"host":host,"port":4500,"gatewayID":"gw.lattice.lab","clientID":"device1.lattice.lab","caDER":b("ca.der"),"clientCertDER":b("client.der"),"clientKeyPKCS8":b("client.key.der"),"rekeySeconds":rekey}).encode()).decode())
