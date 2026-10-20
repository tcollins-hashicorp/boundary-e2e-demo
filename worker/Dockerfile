# Custom worker image.
#
# The stock boundary-enterprise image runs as a non-root user. Under `podman
# compose` driven by the external docker-compose provider, neither the `:U`
# volume flag nor a compose `user:` override is reliably applied, so the worker
# could not write its recording/log volumes (integrity violation #108 on
# /boundary/recordings/.validate). Building our own image pins the user to root
# and makes the mounted paths writable before Boundary starts, so it no longer
# depends on how the compose provider treats mount flags or user overrides.
# Local demo convenience, not a production pattern.
ARG BOUNDARY_VERSION=0.20.1-ent
FROM docker.io/hashicorp/boundary-enterprise:${BOUNDARY_VERSION}

USER root

COPY entrypoint.sh /usr/local/bin/worker-entrypoint.sh
RUN chmod +x /usr/local/bin/worker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/worker-entrypoint.sh"]
