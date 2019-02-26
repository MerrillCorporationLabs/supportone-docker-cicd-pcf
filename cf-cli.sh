#!/usr/bin/env bash
set -o errexit
set -o nounset

declare is_debug=false
usage() {
    cat <<END
rolling-deploy.sh [-d] jsonFile

Rolling deploy for pcf with reasonable scaling
jsonFile: jsonFile with all the vars needed to run the script. see: example
	-d: (optional) debug will print details
    -h: show this help message
END
}

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
read -r CF_API_ENDPOINT CF_BUILDPACK CF_USERNAME CF_PASSWORD CF_ORGANIZATION CF_SPACE CF_INTERNAL_APP_DOMAIN CF_EXTERNAL_APP_DOMAIN <<<$(jq -r '. | "\(.api_endpoint) \(.buildpack) \(.username) \(.password) \(.organization) \(.space) \(.internal_app_domain) \(.external_app_domain)"' "${json_file}")
read -r APP_NAME APP_MEMORY APP_DISK TIMEOUT INSTANCES ARTIFACT_PATH ARTIFACT_TYPE EXTERNAL_APP_HOSTNAME PUSH_OPTIONS <<<$(jq -r '. | "\(.app_name) \(.app_memory) \(.app_disk) \(.timeout) \(.instances) \(.artifact_path) \(.artifact_type) \(.external_app_hostname) \(.push_options)"' "${json_file}")
readarray -t CF_SERVICES <<<"$(jq -r '.services[]' "${json_file}")"

cf api --skip-ssl-validation $CF_API_ENDPOINT
cf login -u "${CF_USERNAME}" -p "${CF_PASSWORD}" -o "${CF_ORGANIZATION}" -s "${CF_SPACE}"

shift

cf "$@"

