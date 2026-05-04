FROM confluentinc/cp-kafka-connect:7.5.3

RUN confluent-hub install --no-prompt confluentinc/kafka-connect-s3:10.5.13 \
    && confluent-hub install --no-prompt debezium/debezium-connector-mysql:2.4.2
