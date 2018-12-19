#!/bin/bash

##
# Allow the parent script to run as is. This, assumes that the current environment has all the necessary dependencies
##
: ${RUN_LOCAL:="false"}
##
# The base Docker image to wrap the script with
##
: ${DOCKER_RUN_IMAGE:="debian:jessie-slim"}

##
# Function to detect if we are running in a container.
# Credit: a bunch of different stackoverflow posts and others. Eg https://tuhrig.de/how-to-know-you-are-inside-a-docker-container/ and https://stackoverflow.com/questions/23513045/how-to-check-if-a-process-is-running-inside-docker-container
##
function is_container () {
  grep -qE '/docker/|/lxc/' /proc/1/cgroup
  echo "$?"
}

##
# Magic time:
# * capture the current running context. In this example we capture the docker GID so we can run docker inside the container. (this is not docker-in-docker though).
# * build a docker image with:
# ** any necessary dependencies,
# ** user, groups and home directory that matches the parent runtime.
# * runs Docker:
# ** passing in all environment variables,
# ** mapping the current working directory into the container at the same location
# * replace the current running program using `exec`.
#
# The uid and gid setup ensure that any files written outside of the container are created with the correct uid & gid.
#  see - https://medium.com/redbubble/running-a-docker-container-as-a-non-root-user-7d2e00f8ee15
#
##
function docker_run () {

  ##
  # Capture the current uid, gid, username and docker gid.
  ##
  local LOCAL_UID=$(id -u)
  local LOCAL_GID=$(id -g)
  local LOCAL_USERNAME="${USER}"
  local DOCKER_GID=$(getent group docker | cut -d: -f3)

  ##
  # create a temporary Dockerfile with....
  ##
  local t_dockerfile=$(mktemp /tmp/Dockerfile.XXXXXXXXX)
  cat <<-EOF > "${t_dockerfile}"

    ##
    # Set the base image
    ##
    FROM ${DOCKER_RUN_IMAGE}

    ###
    # Add any dependencies necessary to run your tests, build, or deploy.
    ##
    #ENV DEBIAN_FRONTEND noninteractive
    #RUN apt-get update && \
    #   DEBIAN_FRONTEND=noninteractive apt-get install -y \
    #	docker  \
    #	jq  \
    #	build-essential  \
    #	--no-install-recommends \
    #   --no-install-suggests \
    #	&& rm -rf /root/.cache /tmp/* /var/lib/apt/lists/* /var/tmp/*
    # RUN
    ##


    ##
    # This next section create all the necessary groups and users with the correct uid and gids
    #  NOTE: The commands run may be base image dependent! (eg useradd vs adduser)
    ##
    RUN addgroup --gid ${DOCKER_GID} docker
    RUN addgroup --gid ${LOCAL_GID} ${LOCAL_USERNAME}
    RUN useradd --create-home -g ${LOCAL_GID} -G docker,${DOCKER_GID}  -u ${LOCAL_UID} ${LOCAL_USERNAME}
    RUN if [ "x$(getent group docker | cut -d: -f3)" != "x${DOCKER_GID}" ]; then \\
          addgroup --gid ${DOCKER_GID} docker2 2>&1 ; \\
          addgroup ${LOCAL_USERNAME} docker2 2>&1 ; \\
      fi

    ##
    # Run the container as the same calling user
    ##
    USER ${LOCAL_USERNAME}
EOF

    ##
    # Build the container. Remember, Docker is smart about caching layers so the above will likely only be built once!
    #
    # NOTE: This example "scopes" the container to the calling script name. This could easily be changed to APP_NAME or the
    # calling directory name to prevent a new container being created for each shell script
    ##
    docker build -t "${SCRIPT}_docker:latest"  -f "${t_dockerfile}" .

    ##
    # Run docker and call the parent script..
    ##
    exec docker run -it \
      -v "${DIR}:${DIR}" \
      --env-file <( env| cut -f1 -d= ) \
      --workdir "${PWD}" \
      "${SCRIPT}_docker:latest" \
      "${DIR}/${SCRIPT}" \
      "$@"
}

##
# If we are not in a container, and we have been ask to run in local mode,
# run the calling script in docker
##
if [ "x${RUN_LOCAL}" = "xfalse" ] && [ "x$(is_container)" = "x1" ]; then
  docker_run "$@"
fi