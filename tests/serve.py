"""Local static server that mimics Cloudflare Pages: /index.html redirects (308) to /.
Serves the repo root on http://127.0.0.1:8766/"""
import http.server, functools, os
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.split('?')[0].endswith('/index.html'):
            self.send_response(308); self.send_header('Location', self.path.replace('index.html','')); self.end_headers(); return
        return super().do_GET()
    def log_message(self,*a): pass
http.server.ThreadingHTTPServer(('127.0.0.1',8766), functools.partial(H, directory=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))).serve_forever()
