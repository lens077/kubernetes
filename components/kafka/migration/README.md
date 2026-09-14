# Kafka/Connect migration staging

These manifests are the parallel migration staging resources. They use an internal Strimzi Kafka listener and a dedicated KafkaConnect build image; they do not change or stop the node3 Kafka/Connect pipeline. Before cutover, replace the example connector configuration with Secret-backed production configuration, run snapshot/lag/CDC verification, and remove any temporary NodePort or external listener.
