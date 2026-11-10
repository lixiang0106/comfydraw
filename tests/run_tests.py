import base64
import http.server
import json
import os
import pathlib
import subprocess
import tempfile
import threading
import time
import struct
import zlib

ROOT = pathlib.Path(__file__).resolve().parent
APP = ROOT.parent / 'main.swift'
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)

PNG = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\x00' + bytes([255, 0, 0, 0, 255, 0]) + b'\x00' + bytes([0, 0, 255, 255, 255, 255]))) + chunk(b'IEND', b'')

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, obj, status=200, mime='application/json'):
        body = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self):
        path = self.path.split('?')[0]
        self.server.events.append(('GET', path))
        if path == '/system_stats': return self.reply({'system': {'comfyui_version': 'mock'}})
        if path.startswith('/object_info/'):
            node = path.rsplit('/', 1)[-1]
            models = {'UnetLoaderGGUF': ('unet_name', 'qwen-image-2.1-UC-Q6_K.gguf'), 'CLIPLoader': ('clip_name', 'qwen3vl_8b_bf16.safetensors'), 'VAELoader': ('vae_name', 'qwen_image_2.1_vae_bf16.safetensors')}
            if node not in models: return self.reply({}, 404)
            key, name = models[node]
            return self.reply({node: {'input': {'required': {key: [[name]]}}}})
        if path.startswith('/history/'):
            if self.server.scenario in ('history_cancel', 'history_failure_cancel'):
                (self.server.data / 'request-marker').touch()
                time.sleep(2)
            if self.server.scenario in ('fail_history', 'history_failure_cancel'): return self.reply({}, 503)
            if self.server.scenario in ('cancel', 'queue_stall'): return self.reply({})
            return self.reply({'test-id': {'status': {'status_str': 'success'}, 'outputs': {'9': {'images': [{'filename': 'result.png', 'subfolder': '', 'type': 'output'}]}}}})
        if path == '/queue':
            if self.server.scenario == 'queue_cancel':
                (self.server.data / 'request-marker').touch()
                time.sleep(2)
            if self.server.scenario == 'queue_stall': time.sleep(20)
            return self.reply({'queue_running': [[0, 'another-id']], 'queue_pending': [[1, 'test-id'], [2, 'another-id']]})
        if path == '/view':
            if self.server.scenario == 'image_cancel':
                (self.server.data / 'request-marker').touch()
                time.sleep(4)
            return self.reply(b'invalid' if self.server.scenario == 'bad_image' else PNG, 200, 'image/png')
        return self.reply({}, 404)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        try: obj = json.loads(body)
        except ValueError: obj = None
        self.server.events.append(('POST', self.path, obj))
        if self.path == '/upload/image':
            self.server.upload = (self.headers.get('Content-Type'), body)
            return self.reply({'name': 'mock-reference.png', 'subfolder': 'isolated'})
        if self.path == '/prompt':
            if self.server.scenario == 'redirect':
                self.send_response(307)
                self.send_header('Location', f'http://127.0.0.1:{self.server.target.server_port}/capture')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            return self.reply({'prompt_id': 'test-id'})
        if self.path == '/queue': return self.reply({})
        return self.reply({}, 404)

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

def run_in_temp(temp_root):
    exe = pathlib.Path(temp_root) / 'generator-tests'
    subprocess.run(['swiftc', '-parse-as-library', '-D', 'APP_TESTING', str(APP), str(ROOT / 'GeneratorTests.swift'), '-o', str(exe)], check=True)
    failed = []
    for scenario in ['success', 'img2img', 'redirect', 'bad_image', 'corrupt', 'save_error', 'cancel', 'fail_history', 'image_cancel', 'history_cancel', 'history_failure_cancel', 'queue_cancel', 'queue_stall', 'history_conflict']:
        with tempfile.TemporaryDirectory(prefix='data-', dir=temp_root) as temp:
            data = pathlib.Path(temp)
            if scenario == 'img2img': (data / 'input.png').write_bytes(PNG)
            if scenario == 'corrupt': (data / 'history.json').write_text('{invalid')
            if scenario == 'save_error': (data / 'archive').write_text('not a directory')
            server = Server(('127.0.0.1', 0), Handler)
            server.scenario, server.events, server.data = scenario, [], data
            target = Server(('127.0.0.1', 0), Handler)
            target.scenario, target.events, target.data = 'capture', [], data
            server.target = target
            target_thread = threading.Thread(target=target.serve_forever, daemon=True)
            target_thread.start()
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            env = dict(os.environ, COMFYUI_BASE_URL=f'http://127.0.0.1:{server.server_port}', ALT_BASE_URL=f'http://127.0.0.1:{target.server_port}', APP_DATA_DIR=temp)
            try:
                result = subprocess.run([str(exe), scenario], env=env, capture_output=True, text=True, timeout=22)
                print(result.stdout.strip(), flush=True)
                if result.stderr: print(result.stderr.strip(), flush=True)
                issues = []
                if result.returncode: issues.append(f'exit={result.returncode}')
                posts = [e for e in server.events if e[0] == 'POST']
                if any(e[1] == '/interrupt' for e in posts): issues.append('global interrupt called')
                if target.events: issues.append('second endpoint received requests')
                if scenario == 'redirect' and not any(e[1] == '/prompt' for e in posts): issues.append('redirect prompt missing')
                if scenario in ('cancel', 'history_cancel', 'history_failure_cancel', 'queue_cancel', 'queue_stall') and [e[2] for e in posts if e[1] == '/queue'] != [{'delete': ['test-id']}]: issues.append('incorrect queue deletion')
                if scenario in ('history_cancel', 'history_failure_cancel', 'queue_cancel') and any(e[0] == 'GET' and e[1] == '/view' for e in server.events): issues.append('entered saving after cancellation')
                if scenario == 'success':
                    prompts = [e[2] for e in posts if e[1] == '/prompt']
                    if len(prompts) != 1 or prompts[0]['prompt']['6']['inputs'] != {'width': 512, 'height': 768, 'batch_size': 2}: issues.append('wrong workflow')
                    if len(prompts) != 1 or prompts[0]['prompt']['9']['inputs']['filename_prefix'] != 'comfydraw': issues.append('wrong output prefix')
                if scenario == 'img2img':
                    content_type, body = getattr(server, 'upload', ('', b''))
                    prompts = [e[2] for e in posts if e[1] == '/prompt']
                    if not content_type.startswith('multipart/form-data; boundary=') or b'filename="ref_' not in body or b'\x89PNG\r\n\x1a\n' not in body: issues.append('invalid uploaded PNG multipart')
                    if len(prompts) != 1 or prompts[0]['prompt']['10']['inputs']['image'] != 'isolated/mock-reference.png' or prompts[0]['prompt']['11']['inputs']['pixels'] != ['10', 0] or prompts[0]['prompt']['7']['inputs']['latent_image'] != ['11', 0]: issues.append('incorrect img2img workflow')
                if scenario == 'corrupt' and (data / 'history.json').read_text() != '{invalid': issues.append('corrupt history overwritten')
                if issues:
                    failed.append((scenario, issues))
                    print('FAIL', scenario, issues, flush=True)
                else: print('PASS', scenario, flush=True)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
                target.shutdown()
                target.server_close()
                target_thread.join()
    print('FAILURES', failed, flush=True)
    return bool(failed)

if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='comfydraw-tests-') as temp_root:
        raise SystemExit(run_in_temp(temp_root))
