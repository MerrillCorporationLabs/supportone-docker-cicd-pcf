#!/usr/bin/env bash
set -o errexit
set -o pipefail
set -o nounset
export DEBUG=true
[[ ${DEBUG:-} == true ]] && set -o xtrace

usage() {
    cat <<END
rolling-deploy.sh [-d] jsonFile

Rolling deploy for pcf with reasonable scaling
jsonFile: jsonFile with all the vars needed to run the script. see: example
	-d: (optional) debug will print details
    -h: show this help message
END
}

error () {
    echo "Error: $1"
    exit "$2"
} >&2

while getopts ":hd" opt; do
    case $opt in
        d)
            is_debug=true
            ;;
        h)
            usage
            exit 0
            ;;
        :)
            error "Option -${OPTARG} is missing an argument" 2
            ;;
        \?)
            error "unkown option: -${OPTARG}" 3
            ;;
    esac
done

shift $(( OPTIND -1 ))
[[ -f ${1} ]] || { echo "missing an argument. first argument must be location of json file with vars" >&2; exit 1; }
declare json_file="${1}"

# set cf vars
read -r CF_API_ENDPOINT CF_BUILDPACK CF_USERNAME CF_PASSWORD CF_ORGANIZATION CF_SPACE CF_APP_DOMAIN <<<$(jq -r '. | "\(.api_endpoint) \(.buildpack) \(.username) \(.password) \(.organization) \(.space) \(.app_domain)"' "${json_file}")
read -r APP_NAME APP_MEMORY APP_DISK TIMEOUT INSTANCES ARTIFACT_PATH ARTIFACT_TYPE PUSH_OPTIONS <<<$(jq -r '. | "\(.app_name) \(.app_memory) \(.app_disk) \(.timeout) \(.instances) \(.artifact_path) \(.artifact_type) \(.push_options)"' "${json_file}")
read -r APP_SUFFIX <<<$(jq -r '. | "\(.app_suffix)"' "${json_file}")
readarray -t CF_SERVICES <<<"$(jq -r '.services[]' "${json_file}")"
readarray -t CUSTOM_ROUTES <<<"$(jq -r '.custom_routes[]' "${json_file}")"

if [[ $ARTIFACT_TYPE == "directory" && ! -d ${ARTIFACT_PATH} ]]; then
    echo "Exiting before deploy because artifact path directory ${ARTIFACT_PATH} not found"
    exit 1
fi
if [[ $ARTIFACT_TYPE == "file" && ! -f ${ARTIFACT_PATH} ]]; then
    echo "Exiting before deploy because artifact path file ${ARTIFACT_PATH} not found"
    exit 1
fi

if [[ ${DEBUG} == true ]]; then
	echo "CF_API_ENDPOINT => ${CF_API_ENDPOINT}"
	echo "CF_BUILDPACK => ${CF_BUILDPACK}"
	echo "CF_ORGANIZATION => ${CF_ORGANIZATION}"
	echo "CF_SPACE => ${CF_SPACE}"
	echo "CF_APP_DOMAIN => ${CF_APP_DOMAIN}"
	echo "APP_NAME => ${APP_NAME}"
	echo "APP_SUFFIX => ${APP_SUFFIX}"
	echo "APP_MEMORY => ${APP_MEMORY}"
	echo "APP_DISK => ${APP_DISK}"
	echo "TIMEOUT => ${TIMEOUT}"
	echo "INSTANCES => ${INSTANCES}"
	echo "ARTIFACT_PATH => ${ARTIFACT_PATH}"
	echo "ARTIFACT_TYPE => ${ARTIFACT_TYPE}"
	echo "PUSH_OPTIONS => ${PUSH_OPTIONS}"
	echo "CF_SERVICES => ${CF_SERVICES[@]}"
	echo "CUSTOM_ROUTES => ${CUSTOM_ROUTES[@]}"
fi

cf api --skip-ssl-validation "${CF_API_ENDPOINT}"
cf login -u "${CF_USERNAME}" -p "${CF_PASSWORD}" -o "${CF_ORGANIZATION}" -s "${CF_SPACE}"

RANDOM_NUMBER=$((1 + RANDOM * 100))
NEW_APP="${APP_NAME}-${RANDOM_NUMBER}"
DEPLOYED_APP="${APP_NAME}"

SPACE_GUID=$(cf space "${CF_SPACE}" --guid)
DEPLOYED_INSTANCES=$(cf curl /v2/apps -X GET -H 'Content-Type: application/x-www-form-urlencoded' -d "q=name:${APP_NAME}" | jq -r --arg DEPLOYED_APP "${DEPLOYED_APP}" \
  ".resources[] | select(.entity.space_guid == \"${SPACE_GUID}\") | select(.entity.name == \"${DEPLOYED_APP}\") | .entity.instances | numbers")

if [[ -z "$DEPLOYED_INSTANCES" ]]; then
echo "Deployed app ${DEPLOYED_APP} not found so doing normal deployment instead"

cf push "${DEPLOYED_APP}" -i "${INSTANCES}" -m "${APP_MEMORY}" -k "${APP_DISK}" -t "${TIMEOUT}" -b "${CF_BUILDPACK}" \
  -n "${DEPLOYED_APP}${APP_SUFFIX}" -d "${CF_APP_DOMAIN}" -p "${ARTIFACT_PATH}" ${PUSH_OPTIONS}

for CF_SERVICE in "${CF_SERVICES[@]}"; do
  if [ -n "${CF_SERVICE}" ]; then
    echo "Binding service ${CF_SERVICE} to deployed app ${DEPLOYED_APP}"
    cf bind-service "${DEPLOYED_APP}" "${CF_SERVICE}"
  fi
done

for CUSTOM_ROUTE in "${CUSTOM_ROUTES[@]}"; do
  if [ -n "${CUSTOM_ROUTE}" ]; then
    ROUTE=($CUSTOM_ROUTE)
    HOST="${ROUTE[0]}"
    DOMAIN="${ROUTE[1]}"
    echo "Mapping route ${HOST}.${DOMAIN} to deployed app ${DEPLOYED_APP}"
    cf map-route "${DEPLOYED_APP}" "${DOMAIN}" -n "${HOST}"
  fi
done

cf start "${DEPLOYED_APP}"

exit 0
fi

cf push "${NEW_APP}" -i 1 -m "${APP_MEMORY}" -k "${APP_DISK}" -t "${TIMEOUT}" -b "${CF_BUILDPACK}" \
  -n "${NEW_APP}" -d "${CF_APP_DOMAIN}" -p "${ARTIFACT_PATH}" ${PUSH_OPTIONS}

for CF_SERVICE in "${CF_SERVICES[@]}"; do
  if [ -n "${CF_SERVICE}" ]; then
    echo "Binding service ${CF_SERVICE} to new app ${NEW_APP}"
    cf bind-service "${NEW_APP}" "${CF_SERVICE}"
  fi
done

cf start "${NEW_APP}"

echo "Performing cutover to new app ${NEW_APP}"

echo "Mapping route ${DEPLOYED_APP}${APP_SUFFIX}.${CF_APP_DOMAIN} to new app ${NEW_APP}"
cf map-route "${NEW_APP}" "${CF_APP_DOMAIN}" -n "${DEPLOYED_APP}${APP_SUFFIX}"

for CUSTOM_ROUTE in "${CUSTOM_ROUTES[@]}"; do
  if [ -n "${CUSTOM_ROUTE}" ]; then
    ROUTE=($CUSTOM_ROUTE)
    HOST="${ROUTE[0]}"
    DOMAIN="${ROUTE[1]}"
    echo "Mapping route ${HOST}.${DOMAIN} to new app ${NEW_APP}"
    cf map-route "${NEW_APP}" "${DOMAIN}" -n "${HOST}"
  fi
done

if [[ ! -z "${DEPLOYED_APP}" && "${DEPLOYED_APP}" != "" ]]; then

    declare -i instances=0
    declare -i old_app_instances=${INSTANCES}
    echo "Begin scaling down deployed app ${DEPLOYED_APP} from ${INSTANCES} instances"

    while (( ${instances} != ${INSTANCES} )); do
      	declare -i instances=${instances}+1
		declare -i old_app_instances=${old_app_instances}-1
      	echo "Scaling up new app ${NEW_APP} to ${instances} instances"
      	cf scale -i ${instances} "${NEW_APP}"
        echo "Scaling down deployed app ${DEPLOYED_APP} to ${old_app_instances} instances"
        cf scale -i ${old_app_instances} "${DEPLOYED_APP}"
    done

    echo "Unmapping external route from deployed app ${DEPLOYED_APP}"
    cf unmap-route "${DEPLOYED_APP}" "${CF_APP_DOMAIN}" -n "${DEPLOYED_APP}${APP_SUFFIX}"

    echo "Deleting deployed app ${DEPLOYED_APP}"
    cf delete "${DEPLOYED_APP}" -f
fi

echo "Unmapping test deploy route from new app ${NEW_APP}"
cf unmap-route "${NEW_APP}" "${CF_APP_DOMAIN}" -n "${NEW_APP}"

echo "Renaming new app ${NEW_APP} to ${DEPLOYED_APP}"
cf rename "${NEW_APP}" "${DEPLOYED_APP}"
