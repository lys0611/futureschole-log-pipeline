FROM python:3.11-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY api_full_setup.sh /tmp/api_full_setup.sh
COPY materialize_app.py /tmp/materialize_app.py
RUN python /tmp/materialize_app.py

COPY nginx.conf /etc/nginx/nginx.conf
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
    && mkdir -p /var/log/nginx \
    && touch /var/log/nginx/flask_app_access.log /var/log/nginx/flask_app_error.log

EXPOSE 80

CMD ["/usr/local/bin/docker-entrypoint.sh"]
