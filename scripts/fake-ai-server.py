# Faux serveur d'IA pour les essais de Prism : compatible Anthropic (/v1/messages) et OpenAI (/v1/chat/completions).
# Flux : « Bonjour depuis le serveur. » en morceaux. Sans flux : un appel de l'outil current_date_time, puis la réponse finale.
# Usage : python3 scripts/fake-ai-server.py 8765
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

WORDS = ["Bonjour ", "depuis ", "le ", "serveur."]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def stream(self, events):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for event in events:
            self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path.endswith("/v1/messages"):
            self.anthropic(body)
        elif self.path.endswith("/chat/completions"):
            self.openai(body)
        else:
            self.send_error(404)

    def anthropic(self, body):
        if body.get("stream"):
            events = [{"type": "content_block_delta", "delta": {"type": "text_delta", "text": word}} for word in WORDS]
            self.stream(events + [{"type": "message_stop"}])
            return
        results = [part for message in body["messages"] if isinstance(message.get("content"), list)
                   for part in message["content"] if part.get("type") == "tool_result"]
        if results:
            content = results[-1]["content"]
            text = content if isinstance(content, str) else " ".join(part.get("text", "") for part in content)
            self.send_json({"content": [{"type": "text", "text": "Réponse finale avec l’outil : " + text}], "stop_reason": "end_turn"})
        else:
            self.send_json({"content": [{"type": "tool_use", "id": "toolu_1", "name": "current_date_time", "input": {}}], "stop_reason": "tool_use"})

    def openai(self, body):
        if body.get("stream"):
            events = [{"choices": [{"delta": {"content": word}}]} for word in WORDS]
            self.stream(events)
            self.wfile.write(b"data: [DONE]\n\n")
            return
        results = [m for m in body["messages"] if m.get("role") == "tool"]
        if results:
            message = {"role": "assistant", "content": "Réponse finale avec l’outil : " + results[-1]["content"]}
        else:
            message = {"role": "assistant", "content": None, "tool_calls": [
                {"id": "call_1", "type": "function", "function": {"name": "current_date_time", "arguments": "{}"}}]}
        self.send_json({"choices": [{"message": message}]})


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
