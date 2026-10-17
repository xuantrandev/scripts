#!/usr/bin/env bash

# Replace <YOUR_DOCKER_IMAGE_NAME> with your actual Docker image name
# DOCKER_IMAGE="xuantrandev/rathole"

DOCKER_IMAGE=$1.
CHECK_TAG=$2
# Get an authentication token
TOKEN_URI="https://auth.docker.io/token"
DATA=("service=registry.docker.io" "scope=repository:$DOCKER_IMAGE:pull")
TOKEN=$(curl --silent --get --data-urlencode "${DATA[0]}" --data-urlencode "${DATA[1]}" "$TOKEN_URI" | jq --raw-output '.token')

# Fetch the list of tags
LIST_URI="https://registry-1.docker.io/v2/$DOCKER_IMAGE/tags/list"
RESULT=$(curl --silent --get -H "Accept: application/json" -H "Authorization: Bearer $TOKEN" "$LIST_URI" | jq --raw-output '.')
echo "$RESULT"