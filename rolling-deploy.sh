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
read -r CF_API_ENDPOINT CF_BUILDPACK CF_USER CF_PASSWORD CF_ORG CF_SPACE CF_INTERNAL_APPS_DOMAIN CF_EXTERNAL_APPS_DOMAIN <<<$(jq -r '.cf | "\(.api_endpoint) \(.buildpack) \(.user) \(.password) \(.org) \(.space) \(.apps_domain.internal) \(.apps_domain.external)"' "${json_file}")
read -r APP_NAME APP_MEMORY ARTIFACT_PATH BUILD_NUMBER EXTERNAL_APP_HOSTNAME PUSH_OPTIONS <<<$(jq -r '. | "\(.app_name) \(.app_memory) \(.artifact_path) \(.build_number) \(.external_app_hostname) \(.push_options)"' "${json_file}")
# readarray -t CF_SERVICES <<<"$(jq -r '.cf.services[]' "${json_file}")"

if [[ ${DEBUG} == true ]]; then
	echo "${CF_API_ENDPOINT}"
    echo "${CF_BUILDPACK}"
	echo "${CF_USER}"
	echo "${CF_PASSWORD}"
	echo "${CF_ORG}"
	echo "${CF_SPACE}"
	echo "${CF_SERVICES[@]}"
	echo "${CF_INTERNAL_APPS_DOMAIN}"
	echo "${CF_EXTERNAL_APPS_DOMAIN}"
	echo "${APP_NAME}"
	echo "${APP_MEMORY}"
	echo "${ARTIFACT_PATH}"
	echo "${BUILD_NUMBER}"
	echo "${EXTERNAL_APP_HOSTNAME}"
	echo "${PUSH_OPTIONS}"
fi

cf api --skip-ssl-validation "${CF_API_ENDPOINT}"
cf login -u "${CF_USER}" -p "${CF_PASSWORD}" -o "${CF_ORG}" -s "${CF_SPACE}"

DEPLOYED_APP="${APP_NAME}"
space_guid=$(cf space "${CF_SPACE}" --guid)
declare -i DEPLOYED_APP_INSTANCES=$(cf curl /v2/apps -X GET -H 'Content-Type: application/x-www-form-urlencoded' -d "q=name:${APP_NAME}" | jq -r --arg DEPLOYED_APP "${DEPLOYED_APP}" \
  ".resources[] | select(.entity.space_guid == \"${space_guid}\") | select(.entity.name == \"${DEPLOYED_APP}\") | .entity.instances | numbers")

[[ ${DEBUG} == true ]] && echo "DEPLOYED APP: ${DEPLOYED_APP} DEPLOYED APP INSTANCES: ${DEPLOYED_APP_INSTANCES}"

[[ -d ${ARTIFACT_PATH} ]] || (echo "exiting before deploy. ${ARTIFACT_PATH} does not exist" && exit 1)

cf push "${APP_NAME}-${BUILD_NUMBER}" -i 1 -m ${APP_MEMORY} \
  -n "${APP_NAME}-${BUILD_NUMBER}" -d "${CF_INTERNAL_APPS_DOMAIN}" \
  -b "${CF_BUILDPACK}" \
  -p "${ARTIFACT_PATH}/${APP_NAME}"-*.jar ${PUSH_OPTIONS}

for CF_SERVICE in "${CF_SERVICES[@]}"; do
  if [ -n "${CF_SERVICE}" ]; then
    echo "Binding service ${CF_SERVICE}"
    cf bind-service "${APP_NAME}-${BUILD_NUMBER}" "${CF_SERVICE}"
  fi
done

cf start "${APP_NAME}-${BUILD_NUMBER}"

echo "Performing zero-downtime cutover to ${APP_NAME}-${BUILD_NUMBER}"
if [[ $CF_SPACE =~ .*dev.* ]]; then
    cf map-route "${APP_NAME}-${BUILD_NUMBER}" "${CF_EXTERNAL_APPS_DOMAIN}" -n "${EXTERNAL_APP_HOSTNAME}";
elif [[ $CF_SPACE =~ .*stage.* ]]; then
    cf map-route "${APP_NAME}-${BUILD_NUMBER}" "${CF_EXTERNAL_APPS_DOMAIN}" -n "${EXTERNAL_APP_HOSTNAME}-stage";
elif [[ $CF_SPACE =~ .*prod.* ]]; then
    cf map-route "${APP_NAME}-${BUILD_NUMBER}" "${CF_EXTERNAL_APPS_DOMAIN}" -n "${EXTERNAL_APP_HOSTNAME}-prod";
fi


echo "A/B deployment"
if [[ ! -z "${DEPLOYED_APP}" && "${DEPLOYED_APP}" != "" ]]; then

    declare -i instances=0
    declare -i old_app_instances=${DEPLOYED_APP_INSTANCES}
    echo "begin scaling down from: ${DEPLOYED_APP_INSTANCES}"

    while (( ${instances} != ${DEPLOYED_APP_INSTANCES} )); do
      	declare -i instances=${instances}+1
		declare -i old_app_instances=${old_app_instances}-1
      	echo "Scaling up ${APP_NAME}-${BUILD_NUMBER} to ${instances}.."
      	cf scale -i ${instances} "${APP_NAME}-${BUILD_NUMBER}"

		  echo "Scaling down ${DEPLOYED_APP} to ${old_app_instances}.."
		  cf scale -i ${old_app_instances} "${DEPLOYED_APP}"
    done

    echo "Unmapping the external route from the application ${DEPLOYED_APP}"
    if [[ $CF_SPACE =~ .*dev.* ]]; then
        cf unmap-route "${DEPLOYED_APP}" "${CF_EXTERNAL_APPS_DOMAIN}" -n "${EXTERNAL_APP_HOSTNAME}";
    elif [[ $CF_SPACE =~ .*stage.* ]]; then
        cf unmap-route "${DEPLOYED_APP}" "${CF_EXTERNAL_APPS_DOMAIN}" -n "${EXTERNAL_APP_HOSTNAME}-stage";
    elif [[ $CF_SPACE =~ .*prod.* ]]; then
        cf unmap-route "${DEPLOYED_APP}" "${CF_EXTERNAL_APPS_DOMAIN}" -n "${EXTERNAL_APP_HOSTNAME}-prod";
    fi
    echo "Deleting the application ${DEPLOYED_APP}"
    cf delete "${DEPLOYED_APP}" -f
fi

# TODO: move rename into replace delete old app to keep metrics
#echo "Renaming ${APP_NAME} to ${APP_NAME}-old"
#cf rename "${APP_NAME}" "${APP_NAME}-old"
#
echo "Renaming ${APP_NAME}-${BUILD_NUMBER} to ${APP_NAME}"
cf rename "${APP_NAME}-${BUILD_NUMBER}" "${APP_NAME}"

echo "Deleting the orphaned routes"
cf delete-orphaned-routes -f
