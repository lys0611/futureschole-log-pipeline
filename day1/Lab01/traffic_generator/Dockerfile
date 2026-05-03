FROM python:3.11-slim

WORKDIR /workspace/day1

RUN pip install --no-cache-dir requests PyYAML

COPY Lab01/traffic_generator ./Lab01/traffic_generator
COPY Lab02/pubsub/traffic_generator.py ./Lab02/pubsub/traffic_generator.py

CMD ["python", "Lab02/pubsub/traffic_generator.py", "--mode", "once"]
