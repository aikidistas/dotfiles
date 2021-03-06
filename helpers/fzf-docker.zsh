#!/bin/bash

# https://github.com/MartinRamm/fzf-docker/blob/master/docker-fzf

# $1 (Optionally) - if present (value doesn't matter), this test checks if any containers exist. Else, if active (running) containers exis
__docker_pre_test() {
  if [[ -z "$1" ]] && [[ $(docker ps --format '{{.Names}}') ]]; then
    return 0;
  fi

  if [[ ! -z "$1" ]] && [[ $(docker ps -a --format '{{.Names}}') ]]; then
    return 0;
  fi

  echo "No containers found";
  return 1;
}

__docker_images_pre_test() {
  if [[ $(docker images -qa) ]]; then
    return 0;
  fi
  echo "No images found"
  return 1;
}

#1 (Optional) path to `docker-compose.yml` file
__docker_compose_pre_test() {
  if [ -z "$1" ]; then
    if [[ $(docker-compose config --services) ]]; then
      return 0;
    fi
    echo "No docker-compose.yml found (or it contains errors). You can pass as the first argument a path to the service declaration file."
    return 1;
  fi

  if [[ $(docker-compose --file $1 config --services) ]]; then
    return 0;
  fi
  echo "Invalid service declaration file $1."
  return 1;
}

# $1: time interval - e.g.: `1m` for 1 minute
# $2: names of container(s) to display logs from
__docker_logs() (
  local since=""
  if [ ! -z "$1" ]; then
    since="--since $1 "
  fi

  local count=$(wc -l <<< $2)
  if [[ -z "$2" ]]; then
    return 1
  fi
  if [[ "$count" -eq "1" ]]; then
    eval "docker logs -f $since$2"
    return 0
  fi

  local resetColor="\x1b[39m\x1b[49m"
  #list of 48 distinct colors
  local allColors="\x1b[90m\n\x1b[92m\n\x1b[93m\n\x1b[94m\n\x1b[95m\n\x1b[96m\n\x1b[97m\n\x1b[30m\n\x1b[31m\n\x1b[32m\n\x1b[33m\n\x1b[34m\n\x1b[35m\n\x1b[36m\n\x1b[40m\x1b[90m\n\x1b[40m\x1b[91m\n\x1b[40m\x1b[92m\n\x1b[40m\x1b[94m\n\x1b[40m\x1b[95m\n\x1b[40m\x1b[96m\n\x1b[40m\x1b[97m\n\x1b[41m\x1b[90m\n\x1b[41m\x1b[93m\n\x1b[41m\x1b[95m\n\x1b[41m\x1b[97m\n\x1b[42m\x1b[90m\n\x1b[42m\x1b[93m\n\x1b[42m\x1b[97m\n\x1b[43m\x1b[90m\n\x1b[43m\x1b[93m\n\x1b[43m\x1b[97m\n\x1b[44m\x1b[91m\n\x1b[44m\x1b[92m\n\x1b[44m\x1b[93m\n\x1b[44m\x1b[95m\n\x1b[44m\x1b[97m\n\x1b[45m\x1b[93m\n\x1b[45m\x1b[97m\n\x1b[46m\x1b[90m\n\x1b[46m\x1b[91m\n\x1b[46m\x1b[92m\n\x1b[46m\x1b[93m\n\x1b[46m\x1b[96m\n\x1b[46m\x1b[97m\n\x1b[47m\x1b[90m\n\x1b[47m\x1b[95m\n\x1b[47m\x1b[96m\n"
  #list of `$count` number of distinct colors
  local colors=$(echo -e "$allColors" | shuf -n $count)

  local allPids=()
  local writeToTmpFilePids=()
  local tmpFile="/tmp/fzf-docker-logs-$(date +'%s')"

  function _exit {
    for pid in "${allPids[@]}"; do
      # ignore if process is not alive anymore
      kill -9 $pid > /dev/null 2> /dev/null
    done

    test -e $tmpFile && rm -f $tmpFile
  }
  trap _exit INT TERM SIGTERM

  while read -r name; do
    # last color from list
    local color=$(echo -e "$colors" | tail -n 1)
    # update list - remove last color from list
    colors=$(echo -e "$colors" | head -n -1)

    # in bash, to get the pid for `docker logs` (so we can kill it in _exit), use `command1 > >(command2)` instead of `command1 | command2` - see https://stackoverflow.com/a/8048493/2732818
    # sed -u needed as explained in https://superuser.com/a/792051
    eval "docker logs --timestamps -f $since\"$name\" 2>&1 > >(sed -u -e \"s/^/${color}[${name}]${resetColor} /\" >> $tmpFile) &"
    local pid=($!)

    allPids+=($pid)
    writeToTmpFilePids+=($pid)
  done <<< "$2" # bash executes while loops in pipe in subshell, meaning pids will not be available outside of loop when using `echo -e "$2" | while...`

  #wait for all historc logs being written into $tmpFile
  sleep 2

  local removeTimestamp='sed -r -u "s/((\x1b\[[0-9]{2}m){0,2}\[.*\]\x1b\[39m\x1b\[49m )[^ ]+ /\1/"'

  #sort historic logs
  local numOfLines=$(wc -l < $tmpFile)
  eval "head -n $numOfLines $tmpFile | sort --stable --key=2 | $removeTimestamp"

  #show new logs
  local numOfLines=$((numOfLines+1))
  #2>/dev/null because "tail: /tmp/fzf-docker-logs: file truncated" is outputed every time $tmpFile is emptied
  eval "tail -f -n +$numOfLines $tmpFile > >($removeTimestamp) 2>/dev/null &"
  allPids+=($!)

  #we don't really need to keep the logs on the hdd in $tmpFile so every minute empty it. But keep one line, so the "tail -f" can keep track
  eval "while true; do tail -n 1 $tmpFile > $tmpFile; sleep 10s; done &"
  allPids+=($!)

  #wait for all docker containers have stoped, i.e. no more logs can be generated
  for pid in "${writeToTmpFilePids[@]}"; do
    wait $pid
  done

  #this also kills the `tail -f $tmpFile` process
  _exit
)

__docker_compose_fileref_generator() {
  if [ ! -z "$1" ]; then
    echo "--file $1"
  fi
}

#1 (Optional) path to `docker-compose.yml` file
#2 A regexp that needs to be present in the docker-compose.yml file for this command to return it
__docker_compose_parse_services_config() {
  local fileref=$(__docker_compose_fileref_generator $1)

  # `docker-compose config` normalizes the indentation and format, no matter what the actual file is...
  local config=$(eval "docker-compose $fileref config")

  local inServicesBlock='false'
  local service=''

  echo -e "$config" \
    | while IFS= read -r line; do
        if [[ "$line" == "services:" ]]; then
          inServicesBlock='true'
        elif [[ "$line" =~ ^[^:" "]+:.*$ ]]; then
          inServicesBlock='false'
        fi

        if [[ "$inServicesBlock" == "true" ]]; then
          if [[ "$line" =~ ^" "{2}[^:" "]+:$ ]]; then
            local service=$(echo -e "$line" | grep -o '[^: ]\+')
          fi

          if [[ "$line" =~ $2 ]] && [[ ! -z "service" ]]; then
            echo "$service"
            service=''
          fi
        fi
      done
}

#docker restart
dr() {
  __docker_pre_test
  if [ $? -eq 0 ]; then
    local containers=$(docker ps --format '{{.Names}}' | fzf -m)

    echo -e "$containers" \
      | while read -r name; do
          echo "Restarting $name..."
          docker restart $name
        done

    __docker_logs "1m" "$containers"
  fi
}
alias dck_restart='dr'

#docker logs
dl() {
  __docker_pre_test "all"
  if [ $? -eq 0 ]; then
    local containers=$(docker ps -a --format '{{.Names}}' | fzf -m)
    __docker_logs "$1" "$containers"
  fi
}
alias dck_logs='dl'

#docker logs all
dla() {
  __docker_pre_test "all"
  if [ $? -eq 0 ]; then
    local containers=$(docker ps -a --format '{{.Names}}')
    __docker_logs "$1" "$containers"
  fi
}
alias dck_logs_all='dla'

#docker exec
de() {
  __docker_pre_test
  if [ $? -eq 0 ]; then
    local name=$(docker ps --format '{{.Names}}' | fzf)

    if [ ! -z "$name" ]; then
      local command="$1"

      if [ -z "$command" ] && [ -f "$HOME/.docker-fuzzy-search-exec" ]; then
        command=$($HOME/.docker-fuzzy-search-exec "$name")
      fi

      if [ -z "$command" ]; then
        local imageName=$(docker inspect --format '{{.Config.Image}}' $name | sed -e 's/:.*$//g') #without version
        case "$imageName" in
          "mysql" | "bitnami/mysql" | "mysql/mysql-server" | "percona" | centos/mysql*)
            command='mysql -uroot -p$MYSQL_ROOT_PASSWORD'
          ;;

          "mongo" | "circleci/mongo")
            command='if [ -z "$MONGO_INITDB_ROOT_USERNAME" ]; then mongo; else mongo -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD"; fi'
          ;;
          "bitnami/mongodb")
            command='if [ -z "$MONGODB_USERNAME" ]; then mongo; else mongo -u "$MONGODB_USERNAME" -p "$MONGODB_PASSWORD" "$MONGODB_DATABASE"; fi'
          ;;
          centos/mongodb*)
            command='mongo -u "admin" -p "$MONGODB_ADMIN_PASSWORD" --authenticationDatabase admin'
          ;;

          "redis" | "circleci/redis" | "bitnami/redis" | centos/redis*)
            command='echo -n "Enter DB Number to connect to (^[1-9][0-9]?$): " && read dbNum && redis-cli -n $dbNum'
            if [[ "$imageName" == "bitnami/redis" ]] || [[ "$imageName" == "centos/redis"* ]]; then
              command="if [ -z \$REDIS_PASSWORD ]; then $command; else $command -a \"\$REDIS_PASSWORD\"; fi"
            fi
          ;;

          *)
            command='sh'
            command=" ash; if [ \"\$?\" -eq \"127\" ]; then $command; fi"
            command="bash; if [ \"\$?\" -eq \"127\" ]; then $command; fi"
            command=" zsh; if [ \"\$?\" -eq \"127\" ]; then $command; fi"
        esac

        command="sh -c '$command'"
      fi

      eval "docker exec -it $name $command"
    fi
  fi
}
alias dck_exec='de'

#docker remove
drm() {
  __docker_pre_test "all" \
    && docker ps -aq --format "{{.Names}}" \
      | fzf -m \
      | while read -r name; do
          docker rm -f $name
        done
}
alias dck_remove='drm'

#docker remove all
drma() {
  __docker_pre_test "all" \
    && docker rm $(docker ps -aq) -f
}
alias dck_removeall='drma'

#docker stop
ds() {
  __docker_pre_test \
    && docker ps --format '{{.Names}}' \
      | fzf -m  \
      | while read -r name; do
          docker update --restart=no $name
          docker stop $name
        done
}
alias dck_stop='ds'

#docker stop all
dsa() {
  __docker_pre_test
  if [ $? -eq 0 ]; then
    docker update --restart=no $(docker ps -q)
    docker stop $(docker ps -q)
  fi
}
alias dck_stopall='dsa'

#docker stop
dsrm() {
  __docker_pre_test \
    && docker ps --format '{{.Names}}' \
      | fzf -m  \
      | while read -r name; do
          docker update --restart=no $name
          docker stop $name
          docker rm -f $name
        done
}
alias dck_stop_remove='dsrm'

#docker stop all
dsrma() {
  dsa

  drma
}

#docker kill
dk() {
  __docker_pre_test \
    && docker ps --format '{{.Names}}' | fzf -m --print0 \
      | fzf -m \
      | while read -r name; do
          docker update --restart=no $name
          docker kill $name
        done
}

#docker kill
dka() {
  __docker_pre_test
  if [ $? -eq 0 ]; then
    docker update --restart=no $(docker ps -q)
    docker kill $(docker ps -q)
  fi
}

#docker kill
dkrm() {
  __docker_pre_test \
    && docker ps --format '{{.Names}}' \
      | fzf -m \
      | while read -r name; do
          docker update --restart=no $name
          docker kill $name
          docker rm -f $name
        done
}

#docker kill
dkrma() {
  dka

  drma
}

#docker remove image
alias dck_remove_image='drmi'
drmi() {
  __docker_images_pre_test \
    && docker images --format "{{.Repository}}:{{.Tag}}" --filter "dangling=false" \
      | fzf -m \
      | while read -r ref; do
          local id=$(docker images --filter "reference=$ref" --format "{{.ID}}")
          docker rmi $id -f
        done
}

#docker remove all images

drmia() {
  __docker_images_pre_test \
    && docker rmi $(docker images -qa) -f
}
alias dck_remove_imageall='drmia'
#docker clean
dclean() {
  dsrma
  drmia
}

fzf-docker-debug-info() {
  location="${BASH_SOURCE[0]}"
  if [ -z "$location" ]; then #fzf
    location=$(type -a $0 | sed "s/$0 is a shell function from //g")
  fi;
  gitRepo="$(dirname $location)/.git"
  commitHash=$(eval "git --git-dir $gitRepo rev-parse HEAD")
  latestTag=$(eval "git --git-dir $gitRepo describe --tags")
  fzfDockerVersion="$latestTag ($commitHash)"

  shellEnvironment=$(ps p "$$" o cmd=)

  shell=$(echo $shellEnvironment | grep -oE "^\S+")
  shellVersion=$(eval "$shell --version")
  fzfVersion=$(fzf --version)

  dockerVersion=$(docker --version)
  dockerComposeVersion=$(docker-compose --version)

  dockerExecCustomDefaults=$(test -f "$HOME/.docker-fuzzy-search-exec" && cat "$HOME/.docker-fuzzy-search-exec" || echo "N.A.")

  for v in "fzfDockerVersion" "shellEnvironment" "shellVersion" "fzfVersion" "dockerVersion" "dockerComposeVersion" "dockerExecCustomDefaults"; do
    echo -e "${v}:"
    v=$(eval "echo -e \"\$$v\"" | sed 's/^/\t/g')
    echo -e "$v"
  done;
}
