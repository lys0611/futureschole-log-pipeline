FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir requests PyYAML

COPY config.py config.yml traffic_generator.py ./

CMD ["python", "traffic_generator.py", "--mode", "once"]
