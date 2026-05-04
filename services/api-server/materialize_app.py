from pathlib import Path

source = Path("/tmp/api_app_source.sh").read_text()
start = "cat > $APP_DIR/app.py <<EOL\n"
start_idx = source.index(start) + len(start)
end_idx = source.index("\nEOL\n", start_idx)
text = source[start_idx:end_idx]

text = text.replace(
    "from flask import Flask, request, make_response\n",
    "import os\nfrom flask import Flask, request, make_response\n",
    1,
)
text = text.replace(
    "'host': '${MYSQL_HOST}',",
    "'host': os.environ.get('MYSQL_HOST', 'mysql'),",
    1,
)
text = text.replace(
    "if __name__ == '__main__':",
    "@app.route('/health')\ndef health():\n    return {'status': 'ok'}, 200\n\nif __name__ == '__main__':",
    1,
)

Path("/app/app.py").write_text(text)
