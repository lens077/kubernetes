# Elasticsearch

k8s parallel migration target for the node3 Docker CDC Elasticsearch. The node3 instance remains the read-path source until snapshot, API-key, alias and CDC validation complete. Credentials are supplied by the `elasticsearch-auth` Secret and are not stored here.
