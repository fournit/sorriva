"""
Sorriva — Passione product
Serves app.sorriva.app via Cloudflare Tunnel
Port: 8082
"""

import os
import time
from datetime import datetime
from pathlib import Path

from flask import Flask, jsonify
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__, static_folder="static")

PORT = int(os.getenv("PORT", 8082))
SERVER_START_TIME = time.time()


@app.route("/api/health")
def health():
    version_data = {}
    try:
        import json
        with open(Path(__file__).parent / "version.json") as f:
            version_data = json.load(f)
    except Exception:
        pass

    uptime_secs = int(time.time() - SERVER_START_TIME)
    return jsonify({
        "status":      "ok",
        "app":         "sorriva",
        "version":     version_data.get("version", "0.1.0"),
        "uptime_secs": uptime_secs,
        "timestamp":   datetime.utcnow().isoformat() + "Z",
        "pid":         os.getpid(),
    })


@app.route("/")
def index():
    return jsonify({"app": "Sorriva", "status": "scaffold — no frontend yet"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT, debug=(os.getenv("FLASK_ENV") == "development"))
