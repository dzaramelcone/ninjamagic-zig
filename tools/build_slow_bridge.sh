docker network create \
  --driver bridge \
  --opt com.docker.network.bridge.name=br_slow \
  slow-net
