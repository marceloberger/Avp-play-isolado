import Foundation

/// Cryptographic integrity is separate from publisher identity and ownership.
public struct AndroidAPKSignature: Codable, Sendable, Equatable {
    public var state: String
    public var subject: String?
    public var fingerprint: String?
    public var detail: String
    public var verified: Bool { state == "verified" }

    public static func inspect(_ apk: URL) throws -> Self {
        let result = try ApkUnpacker.run(["/usr/bin/python3", "-c", script, apk.path])
        return try JSONDecoder().decode(Self.self, from: result.data)
    }

    // No network, no extraction of executable payloads, no private credentials. Prefer the official
    // Android verifier when installed (v1/v2/v3). The dependency-free fallback verifies complete v1 JARs.
    static let script = #"""
import sys, os, glob, subprocess, zipfile, hashlib, base64, json, tempfile
def emit(state, detail, subject=None, fingerprint=None):
    print(json.dumps(dict(state=state, detail=detail, subject=subject, fingerprint=fingerprint)))
def attrs(data):
    out={}; key=None
    for line in data.decode('utf-8').replace('\r\n','\n').split('\n'):
        if line.startswith(' ') and key: out[key]+=line[1:]
        elif ': ' in line: key,value=line.split(': ',1); out[key]=value
    return out
def digest(data, record, suffix):
    for name, alg in [('SHA-256','sha256'),('SHA-512','sha512'),('SHA1','sha1'),('SHA-1','sha1')]:
        key=name+'-Digest'+suffix
        if key in record:
            if base64.b64encode(hashlib.new(alg,data).digest()).decode()!=record[key]: raise ValueError('Digest mismatch')
            return
    raise ValueError('No supported digest')
try:
    apk=sys.argv[1]
    with zipfile.ZipFile(apk) as z:
        names=z.namelist()
        if len(names)!=len(set(names)): raise ValueError('Duplicate ZIP entries')
        if any(n.startswith('/') or '\\' in n or '..' in n.split('/') for n in names): raise ValueError('Unsafe ZIP path')
        if z.testzip() is not None: raise ValueError('ZIP CRC mismatch')
        tools=sorted(glob.glob(os.path.expanduser('~/Library/Android/sdk/build-tools/*/apksigner')),reverse=True)
        if tools:
            p=subprocess.run([tools[0],'verify','--verbose','--print-certs',apk],capture_output=True,text=True)
            if p.returncode==0:
                subject=next((s.split(': ',1)[1] for s in p.stdout.splitlines() if 'certificate DN:' in s),None)
                fp=next((s.split(': ',1)[1] for s in p.stdout.splitlines() if 'certificate SHA-256 digest:' in s),None)
                emit('verified','Android apksigner verification; authenticity and licence not established',subject,fp)
                sys.exit(0)
            # A missing Java runtime permits the v1 fallback; a verifier rejection does not.
            if 'Java Runtime' not in p.stderr and 'JAVA_HOME' not in p.stderr:
                raise ValueError('Android apksigner rejected this APK')
        signers=[n for n in names if n.startswith('META-INF/') and n.upper().endswith(('.RSA','.DSA','.EC'))]
        if not signers:
            emit('unsupported','No v1 signature. Install Android SDK apksigner and Java to validate v2/v3 or unsigned APKs.')
            sys.exit(0)
        manifest=z.read('META-INF/MANIFEST.MF'); covered=set()
        for section in manifest.replace(b'\r\n',b'\n').split(b'\n\n'):
            a=attrs(section)
            if 'Name' in a:
                n=a['Name']; digest(z.read(n),a,''); covered.add(n)
        payload={n for n in names if not n.endswith('/') and not n.startswith('META-INF/')}
        if payload-covered: raise ValueError('Unsigned APK payload entries')
        subjects=[]; fingerprints=[]
        with tempfile.TemporaryDirectory(prefix='avp-signature-') as d:
            for signer in signers:
                sf=z.read(signer.rsplit('.',1)[0]+'.SF')
                digest(manifest,attrs(sf.split(b'\r\n\r\n')[0]),'-Manifest')
                sig=os.path.join(d,'signature.der'); content=os.path.join(d,'signature.sf')
                with open(sig,'wb') as f: f.write(z.read(signer))
                with open(content,'wb') as f: f.write(sf)
                p=subprocess.run(['/usr/bin/openssl','smime','-verify','-binary','-inform','DER','-in',sig,'-content',content,'-noverify','-out','/dev/null'],capture_output=True)
                if p.returncode: raise ValueError('Invalid Android v1 cryptographic signature')
                cert=subprocess.run(['/usr/bin/openssl','pkcs7','-inform','DER','-in',sig,'-print_certs'],capture_output=True,check=True).stdout
                info=subprocess.run(['/usr/bin/openssl','x509','-noout','-subject','-fingerprint','-sha256'],input=cert,capture_output=True,check=True).stdout.decode()
                subjects.append(next((s for s in info.splitlines() if s.startswith('subject=')),''))
                fingerprints.append(next((s.split('=',1)[1] for s in info.splitlines() if 'Fingerprint=' in s),''))
        emit('verified','Complete v1 JAR signature verified; v2/v3 and publisher authenticity not established', '; '.join(subjects), '; '.join(fingerprints))
except Exception as e:
    emit('invalid',str(e))
"""#
}
