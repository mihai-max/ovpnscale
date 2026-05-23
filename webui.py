#!/usr/bin/env python3
"""First-run setup web UI for ovpnscale.

Serves a small page where you upload an OpenVPN .ovpn profile and enter the
Headscale URL + credentials, then persists them to $DATA_DIR (a Docker volume):

    $DATA_DIR/client.ovpn   the uploaded profile
    $DATA_DIR/config.env    KEY=VALUE settings (parsed by entrypoint.sh, never sourced)

The entrypoint waits for these to exist, then starts the VPN + Tailscale exit
node. Stdlib only — no pip dependencies.

Optional HTTP Basic Auth: set WEBUI_USER (default "admin") and WEBUI_PASSWORD.
If WEBUI_PASSWORD is empty the UI is unauthenticated — only expose the port on a
trusted network or behind an SSH tunnel / reverse proxy.
"""
import base64
import html
import hmac
import os
from email.parser import BytesParser
from email.policy import default as email_default
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA_DIR = os.environ.get("DATA_DIR", "/data")
OVPN_PATH = os.path.join(DATA_DIR, "client.ovpn")
CONF_PATH = os.path.join(DATA_DIR, "config.env")
PORT = int(os.environ.get("WEBUI_PORT", "8080"))
AUTH_USER = os.environ.get("WEBUI_USER", "admin")
AUTH_PASS = os.environ.get("WEBUI_PASSWORD", "")

# Fields persisted to config.env. Secrets are not echoed back to the page.
FIELDS = ["HEADSCALE_URL", "TS_AUTHKEY", "TS_HOSTNAME", "TS_EXTRA_ARGS",
          "OVPN_AUTH_USER", "OVPN_AUTH_PASS", "OVPN_AUTH_FILE"]
SECRETS = {"TS_AUTHKEY", "OVPN_AUTH_PASS"}


def read_conf():
    data = {}
    try:
        with open(CONF_PATH) as f:
            for line in f:
                line = line.rstrip("\n")
                if "=" in line:
                    k, v = line.split("=", 1)
                    data[k] = v
    except FileNotFoundError:
        pass
    return data


def write_conf(values):
    os.makedirs(DATA_DIR, exist_ok=True)
    # Strict KEY=VALUE, one per line, single-line values. entrypoint.sh parses
    # this with `IFS='=' read` (no shell evaluation), so values are safe verbatim.
    body = "".join(
        "{}={}\n".format(k, values.get(k, "").replace("\r", "").replace("\n", " "))
        for k in FIELDS
    )
    tmp = CONF_PATH + ".tmp"
    with open(tmp, "w") as f:
        f.write(body)
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONF_PATH)


def is_configured():
    return os.path.exists(OVPN_PATH) and bool(read_conf().get("HEADSCALE_URL"))


def parse_multipart(ctype, body):
    """Parse multipart/form-data with the stdlib email module (no `cgi`).

    Returns (fields: name->str, files: name->bytes). Works on all Python 3.x.
    """
    fields, files = {}, {}
    if not ctype.lower().startswith("multipart/"):
        return fields, files
    msg = BytesParser(policy=email_default).parsebytes(
        b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + body)
    if not msg.is_multipart():
        return fields, files
    for part in msg.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if not name:
            continue
        filename = part.get_param("filename", header="content-disposition")
        payload = part.get_payload(decode=True) or b""
        if filename:
            files[name] = payload
        else:
            fields[name] = payload.decode("utf-8", "replace").strip()
    return fields, files


PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ovpnscale setup</title>
<style>
 body{{font-family:system-ui,-apple-system,sans-serif;max-width:640px;margin:2rem auto;padding:0 1rem;color:#111}}
 h1{{font-size:1.4rem}} label{{display:block;margin:.9rem 0 .25rem;font-weight:600}}
 input{{width:100%;padding:.5rem;border:1px solid #bbb;border-radius:6px;font-size:1rem;box-sizing:border-box}}
 .hint{{color:#666;font-weight:400;font-size:.85rem}}
 button{{margin-top:1.3rem;padding:.6rem 1.3rem;border:0;border-radius:6px;background:#2962ff;color:#fff;font-size:1rem;cursor:pointer}}
 .status{{padding:.6rem .8rem;border-radius:6px;margin-bottom:1rem;font-size:.95rem}}
 .ok{{background:#e6f4ea;color:#137333}} .warn{{background:#fef7e0;color:#8a6d00}}
</style></head><body>
<h1>ovpnscale &mdash; setup</h1>
<div class="status {scls}">{stext}</div>
<form method="POST" action="/save" enctype="multipart/form-data">
 <label>OpenVPN profile (.ovpn) <span class="hint">{ovpn_hint}</span></label>
 <input type="file" name="ovpn" accept=".ovpn,.conf,text/plain">
 <label>Headscale URL <span class="hint">e.g. https://headscale.example.com</span></label>
 <input name="HEADSCALE_URL" value="{HEADSCALE_URL}" placeholder="https://headscale.example.com">
 <label>Tailscale pre-auth key <span class="hint">optional &mdash; blank = interactive login (URL appears in container logs)</span></label>
 <input name="TS_AUTHKEY" value="" placeholder="{authkey_ph}">
 <label>Node hostname</label>
 <input name="TS_HOSTNAME" value="{TS_HOSTNAME}" placeholder="ovpn-exit">
 <label>VPN username <span class="hint">if your provider uses username/password auth</span></label>
 <input name="OVPN_AUTH_USER" value="{OVPN_AUTH_USER}">
 <label>VPN password</label>
 <input type="password" name="OVPN_AUTH_PASS" value="" placeholder="{pass_ph}">
 <label>Extra <code>tailscale up</code> args <span class="hint">optional</span></label>
 <input name="TS_EXTRA_ARGS" value="{TS_EXTRA_ARGS}">
 <button type="submit">Save &amp; start</button>
</form>
</body></html>"""

RESULT = """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ovpnscale setup</title>
<style>
 body{{font-family:system-ui,-apple-system,sans-serif;max-width:640px;margin:2rem auto;padding:0 1rem;color:#111}}
 .status{{padding:.8rem 1rem;border-radius:6px;margin-bottom:1rem}}
 .ok{{background:#e6f4ea;color:#137333}} .warn{{background:#fef7e0;color:#8a6d00}}
 a{{color:#2962ff}}
</style></head><body>
<div class="status {cls}">{msg}</div>
<p><a href="/">&larr; back to setup</a></p>
</body></html>"""


def render_form():
    conf = read_conf()
    configured = is_configured()
    if configured:
        scls, stext = "ok", "Configured. The tunnel is starting/running. Re-submit to change settings, then restart the container to apply."
    else:
        scls, stext = "warn", "Not configured yet. Upload your .ovpn and enter your Headscale URL to start."
    return PAGE.format(
        scls=scls, stext=stext,
        ovpn_hint=("a profile is already saved — choose a file only to replace it"
                   if os.path.exists(OVPN_PATH) else "required"),
        HEADSCALE_URL=html.escape(conf.get("HEADSCALE_URL", ""), quote=True),
        TS_HOSTNAME=html.escape(conf.get("TS_HOSTNAME", "") or "ovpn-exit", quote=True),
        OVPN_AUTH_USER=html.escape(conf.get("OVPN_AUTH_USER", ""), quote=True),
        TS_EXTRA_ARGS=html.escape(conf.get("TS_EXTRA_ARGS", ""), quote=True),
        authkey_ph=("(unchanged)" if conf.get("TS_AUTHKEY") else "(optional)"),
        pass_ph=("(unchanged)" if conf.get("OVPN_AUTH_PASS") else ""),
    ).encode()


class Handler(BaseHTTPRequestHandler):
    server_version = "ovpnscale-setup"

    def log_message(self, fmt, *args):
        print("[webui] " + (fmt % args))

    def _auth_ok(self):
        if not AUTH_PASS:
            return True
        hdr = self.headers.get("Authorization", "")
        if hdr.startswith("Basic "):
            try:
                user, _, pw = base64.b64decode(hdr[6:]).decode().partition(":")
            except Exception:
                return False
            return hmac.compare_digest(user, AUTH_USER) and hmac.compare_digest(pw, AUTH_PASS)
        return False

    def _challenge(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="ovpnscale"')
        self.end_headers()

    def _send(self, body, code=200, ctype="text/html; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self._auth_ok():
            return self._challenge()
        if self.path.split("?", 1)[0] in ("/", "/index.html"):
            return self._send(render_form())
        self._send(b"not found", 404, "text/plain")

    def do_POST(self):
        if not self._auth_ok():
            return self._challenge()
        if self.path != "/save":
            return self._send(b"not found", 404, "text/plain")

        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        fields, files = parse_multipart(self.headers.get("Content-Type", ""), body)

        existing = read_conf()
        values = {}
        for k in FIELDS:
            v = (fields.get(k, "") or "").strip()
            if not v and k in SECRETS:        # keep previous secret if left blank
                v = existing.get(k, "")
            values[k] = v

        # Save uploaded profile (if a new, non-empty one was provided).
        if files.get("ovpn"):
            os.makedirs(DATA_DIR, exist_ok=True)
            tmp = OVPN_PATH + ".tmp"
            with open(tmp, "wb") as f:
                f.write(files["ovpn"])
            os.chmod(tmp, 0o600)
            os.replace(tmp, OVPN_PATH)

        write_conf(values)

        if not values.get("HEADSCALE_URL"):
            return self._send(RESULT.format(cls="warn",
                msg="Saved, but <b>Headscale URL is required</b> before the tunnel can start.").encode())
        if not os.path.exists(OVPN_PATH):
            return self._send(RESULT.format(cls="warn",
                msg="Settings saved, but <b>no .ovpn profile</b> is present yet — upload one to start.").encode())
        self._send(RESULT.format(cls="ok",
            msg="Saved. The container will now bring up the VPN + Tailscale exit node. "
                "Check the container logs (interactive login prints an auth URL there).").encode())


def main():
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    if not AUTH_PASS:
        print("[webui] WARNING: no WEBUI_PASSWORD set — the setup UI is UNAUTHENTICATED. "
              "Only expose this port on a trusted network.")
    print("[webui] setup UI listening on http://0.0.0.0:%d" % PORT)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
