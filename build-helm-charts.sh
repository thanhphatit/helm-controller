#!/bin/bash
## Author: Dang Thanh Phat
## Email: thanhphatit95@gmail.com
## Web/blogs: www.itblognote.com
## Description:
## + Tools need to install: helm 
## + Helm plugin: helm push and helm s3
##         helm plugin install https://github.com/chartmuseum/helm-push.git
##         helm plugin install https://github.com/hypnoglow/helm-s3.git
##
## Cautions:
## - No allow to override current version of helm package

##### SHELL SETTINGS
set -o pipefail
set +x; ## Use flag -x with set to debug and show log command, and +x to hide
## set -e ### When you use -e it will export error when logic function fail, example grep "yml" if yml not found

##### GLOBAL VARIABLES
ACTION="${1:-plan}" ## Default with `plan` will have people know what will happen
METHOD="${2:-http}" ## Will help script to choose method to connect Helm Repo: web http or aws s3 bucket, acr of azure. Valid value: http / s3 / acr

# Directory contains template charts
DIR_CHARTS="${PWD}/charts"

HTTP_USER="${HTTP_USER:-none}"
HTTP_PASSWORD="${HTTP_PASSWORD:-none}"

HELM_PRIVATE_REPO_NAME="${HELM_PRIVATE_REPO_NAME:-helm-charts}"
S3_BUCKET_NAME="${S3_BUCKET_NAME:-none}" #set this variable if you use S3 storage for Helm Charts

ACR_NAME="${ACR_NAME:-none}" # Set this variable if you use ACR for Helm Charts
ACR_ARTIFACT_NAME="oci://${ACR_NAME}.azurecr.io/helm"

LIST_IGNORE_LINT="${DIR_CHARTS}/list-ignore-lint.txt"
TMPFILE=$(mktemp /tmp/tempfile-XXXXXXXX)
TMPFILE_LIST_CHARTS=$(mktemp /tmp/tempfile-list-charts-XXXXXXXX)
TMPFILE_CHART_INFO_REPO=$(mktemp /tmp/tempfile-chart-info-repo-XXXXXXXX)
TMPDIR_PACKAGE_CHARTS=$(mktemp -d /tmp/tmpdir-helm-charts-package-XXXXXX)

### Used with echo have flag -e
RLC="\033[1;31m"    ## Use redlight color
GC="\033[0;32m"     ## Use green color
YC="\033[0;33m"     ## Use yellow color
BC="\033[0;34m"     ## Use blue color
EC="\033[0m"        ## End color with no color

#### FUNCTIONS

function check_var(){
    local VAR_LIST=(${1})

    for var in ${VAR_LIST[@]}; do
        if [[ -z "$(eval echo $(echo $`eval echo "${var}"`))" ]];then
            echo -e "${YC}[CAUTIONS] Variable [${var}] not found!"
            exit 1
        fi
    done

    #### Example: check_var "DEVOPS THANHPHATIT"
}

function pre_check_dependencies(){
    ## All tools used in this script
    local TOOLS_LIST=(${1})

    for tools in ${TOOLS_LIST[@]}; do
        # If not found tools => exit
        if [[ ! $(command -v ${tools}) ]];then
cat << ALERTS
[x] Not found tool [${tools}] on machine.

Exit.
ALERTS
            exit 1
        fi
    done

    #### Example: pre_check_dependencies "helm" 
}

function check_plugin(){
    local COMMAND_PLUGIN_LIST="${1}"
    local PLUGIN_LIST=(${2})

    local TOOLS_NAME="$(echo "${COMMAND_PLUGIN_LIST}" | awk '{print $1}')"

    for plugin in ${PLUGIN_LIST[@]}; do
        # If not found tools => exit
        if [[ ! $(${COMMAND_PLUGIN_LIST} 2>/dev/null | grep -i "^${plugin}") ]];then
cat << ALERTS
[x] Not found this ${TOOLS_NAME} plugin [${plugin}] on machine.

Exit.
ALERTS
            exit 1
        fi
    done

    #### Example: check_plugin "helm plugin list" "cm-push diff s3" 
}

function compare_versions() {
    local VERSION_01=${1}
    local VERSION_02=${2}

    if [[ ${VERSION_01} == ${VERSION_02} ]]; then
        echo "equal"
    else
        local IFS=.
        local ver1=(${VERSION_01})
        local ver2=(${VERSION_02})

        local len=${#ver1[@]}
        for ((i=0; i<len; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            ver2[i]=0
        fi

        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            echo "less"
            return
        fi

        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            echo "greater"
            return
        fi
        done

        echo "equal"
    fi
}

function about(){
cat <<ABOUT

******************************************
* Author: DANG THANH PHAT                *
* Email: thanhphat@itblognote.com        *
* Blog: www.itblognote.com               *
* Version: 1.3                           *
* Purpose: Tools to deploy helm charts.  *
******************************************

Use --help or -h to check syntax, please !

ABOUT
    exit 1
}

function help(){
cat <<HELP

Usage: helm-charts [options...] [method...] [debug...]

[*] OPTIONS:
    -h, --help            Show help
    -v, --version         Show info and version
    apply                 Start deploy helm charts to ACR, HTTP, S3,...
    plan                  (This is default value) - plan will have people know what will happen

[*] METHOD:
    http                  You can create a server helm with 'chartmuseum' to deploy
    s3                    Deploy helm to S3 Bucket service AWS
    acr                   Deploy helm to ACR service Azure

[*] DEBUG: (Support for DevOps code, default value is +x)
    -x, +x                Use flag -x with set to debug and show log command contrary +x to hide

HELP
    exit 1
}

function pre_checking()
{
    echo "[+] ACTION: ${ACTION}"
    echo "[+] METHOD: ${METHOD}"
    
    local HELM_VERSION_CURRENT=$(helm version --short --client 2>/dev/null | awk -F'+' '{print $1}' | awk -F'v' '{print $2}')
    local HELM_VERSION_LIMMIT="3.8.0"

    local RESULT_COMPARE_HELM_VERSION=$(compare_versions "${HELM_VERSION_CURRENT}" "${HELM_VERSION_LIMMIT}")
    
    local RESULT_CHECK_PLUGIN_HELM_DIFF=$(check_plugin "helm plugin list" "diff")
    local RESULT_CHECK_PLUGIN_HELM_PUSH=$(check_plugin "helm plugin list" "cm-push")

    if [[ "${RESULT_CHECK_PLUGIN_HELM_DIFF}" != "" ]];then
        helm plugin install https://github.com/databus23/helm-diff &>/dev/null
    fi

    if [[ "${RESULT_CHECK_PLUGIN_HELM_PUSH}" != "" ]];then
        helm plugin install https://github.com/chartmuseum/helm-push.git &>/dev/null
    fi

    if [[ ${RESULT_COMPARE_HELM_VERSION} == "less" ]];then
        echo -e "${YC}[WARNING] Because helm version current less than 3.8.0, so we will add variable [HELM_EXPERIMENTAL_OCI=1]"
        export HELM_EXPERIMENTAL_OCI=1
    fi

    # Check if we miss credentials for AWS Helm S3 Plugin
    if [[ "${METHOD}" == "s3" ]];then
        local FLAG_FOUND_AWS_CREDS="false"

        # We need to check available AWS Credentials
        if [[ "$(env | grep -i AWS_PROFILE | awk -F'=' '{print $2}')" != "" ]];then
            FLAG_FOUND_AWS_CREDS="true"
        elif [[ "$(env | grep -i DEFAULT_AWS_PROFILE | awk -F'=' '{print $2}')" != "" ]];then
            FLAG_FOUND_AWS_CREDS="true"
        elif [[ "$(env | grep -wE "AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_DEFAULT_REGION" | wc -l | tr -d ' ')" == "3" ]];then
            FLAG_FOUND_AWS_CREDS="true"
        fi

        if [[ "${FLAG_FOUND_AWS_CREDS}" == "false" ]];then
            echo ""
            echo "[x] CHECKING: cannot find AWS Credentials when you want to use Helm S3 Plugin"
            exit 1
        fi

        # We need to check plugin S3 Helm
        if [[ ! "$(helm plugin list | grep -i "^s3")" ]];then
            echo ""
            echo "[x] CHECKING: cannot find Helm S3 Plugin to use S3 Method"
            exit 1
        fi

        # Check if we get S3 Bucket Environment
        if [[ ! $(echo "${S3_BUCKET_NAME}" | grep -i "^s3://" ) || "${S3_BUCKET_NAME}" == "none" ]];then
            echo ""
            echo "[x] CHECKING: cannot find Environment Variable [S3_BUCKET_NAME]"
            exit 1
        fi

    elif [[ "${METHOD}" == "http" ]];then
        # Check if we miss credentials for http with cregs
        FLAG_FOUND_HTTP_CREDS="false"

        if [[ ${HTTP_USER} != "none" && ${HTTP_PASSWORD} != "none" ]];then
            FLAG_FOUND_HTTP_CREDS="true"
        fi

        if [[ "$(env | grep -i "HELM_HOSTED_REPO_URL" | awk -F'=' '{print $2}')" == "" ]];then
            echo ""
            echo -e "${YC}[x] CHECKING: cannot find env variable [HELM_HOSTED_REPO_URL] when you want to use Helm authenticate HTTP Web App"
            exit 1
        fi 

    elif [[ "${METHOD}" == "acr" ]];then
        # Check if we miss credentials for http with cregs
        FLAG_FOUND_AZ_CREDS="false"

        if [[ ${AZ_USER} != "" && ${AZ_PASSWORD} != "" ]];then
            FLAG_FOUND_AZ_CREDS="true"
        fi

        if [[ "${FLAG_FOUND_AZ_CREDS}" == "false" ]];then
            echo ""
            echo -e "${YC}[x] CHECKING: cannot find AZ Credentials when you want to use Helm Azure ACR"
            exit 1
        fi

        # Check if we get ACR name Environment
        if [[ ! $(echo "${ACR_ARTIFACT_NAME}" | grep -i "^oci://" ) ]];then
            echo ""
            echo "[x] CHECKING: cannot find Environment Variable [ACR_ARTIFACT_NAME]"
            exit 1
        fi
    fi

    # Check tempfile
    if [[ ! -f ${TMPFILE} ]];then
        touch ${TMPFILE}
    fi

    if [[ ! -f ${TMPFILE_LIST_CHARTS} ]];then
        touch ${TMPFILE_LIST_CHARTS}
    fi

    if [[ ! -f ${TMPFILE_CHART_INFO_REPO} ]];then
        touch ${TMPFILE_CHART_INFO_REPO}
    fi

    if [[ ! -d ${TMPDIR_PACKAGE_CHARTS} ]];then
        mkdir -p ${TMPDIR_PACKAGE_CHARTS}
    fi

    if [[ ! -f ${LIST_IGNORE_LINT} ]];then
        touch ${LIST_IGNORE_LINT}
    fi
}

function cleanup()
{
    # Cleanup
    echo ""
    echo "---------------------------------------------------------"
    echo "[+] Cleaning....."
    if [[ -f ${TMPFILE} ]];then
        rm -f ${TMPFILE}
    fi

    if [[ -f ${TMPFILE_LIST_CHARTS} ]];then
        rm -f ${TMPFILE_LIST_CHARTS}
    fi

    if [[ -f ${TMPFILE_CHART_INFO_REPO} ]];then
        rm -f ${TMPFILE_CHART_INFO_REPO}
    fi

    if [[ -d ${TMPDIR_PACKAGE_CHARTS} ]];then
        rm -rf ${TMPDIR_PACKAGE_CHARTS}
    fi

    # Helm remove repo after work
    if [[ "$(helm repo list | grep -i "${HELM_PRIVATE_REPO_NAME}")" ]];then
        # Remove current setting Helm Repo to add new
        helm repo remove ${HELM_PRIVATE_REPO_NAME}
    fi
}

function find_charts_list(){
    # Find list chart repository
    echo ""
    echo "[*] List Helm Chart Configurations are found :"
    find ${DIR_CHARTS} -type f -name 'Chart.yaml' > ${TMPFILE}
    cat ${TMPFILE}
    echo ""
}

function connect_helm_repo(){
    ###################################
    # Connect Private Helm Repository #
    ###################################
    echo "[+] Connect Private Helm Repository: ${HELM_PRIVATE_REPO_NAME}"
    if [[ $(helm repo list 2> /dev/null | grep -i ${HELM_PRIVATE_REPO_NAME} | awk '{print $1}') == ${HELM_PRIVATE_REPO_NAME} ]];then
        # Remove current setting Helm Repo to add new
        helm repo remove ${HELM_PRIVATE_REPO_NAME} 2> /dev/null
    fi

    if [[ "${METHOD}" == "s3" ]];then
        # Connect to Helm Chart Service with S3 Plugin - S3 Bucket AWS
        helm repo add ${HELM_PRIVATE_REPO_NAME} ${S3_BUCKET_NAME}

    elif [[ "${METHOD}" == "acr" ]];then
        # Connect to Helm Chart Service with ACR Method
        helm repo add ${HELM_PRIVATE_REPO_NAME} https://${ACR_NAME}.azurecr.io/helm/v1/repo --username ${AZ_USER} --password ${AZ_PASSWORD}
        helm registry login ${ACR_NAME}.azurecr.io --username ${AZ_USER} --password ${AZ_PASSWORD}
        az acr login --name ${ACR_NAME} -u ${AZ_USER} -p ${AZ_PASSWORD} &>/dev/null

    elif [[ "${METHOD}" == "http" ]];then
        if [[ ${HTTP_USER} == "none" && ${HTTP_PASSWORD} == "none" ]];then
            # Connect to Helm Chart Service with Web HTTP Method
            helm repo add ${HELM_PRIVATE_REPO_NAME} ${HELM_HOSTED_REPO_URL}
        else
            helm repo add ${HELM_PRIVATE_REPO_NAME} ${HELM_HOSTED_REPO_URL} --username ${HTTP_USER} --password ${HTTP_PASSWORD}
        fi

    fi

    # Update list helm chart repositories
    helm repo update

    # List active Helm Repositories
    echo ""
    echo "[+] List active Helm Repositories"
    helm repo list

    # List Helm Charts in specific Hosted Private Helm Repository
    echo ""
    echo "[+] List Helm Charts in Private Helm Repository: ${HELM_PRIVATE_REPO_NAME}"
    helm search repo ${HELM_PRIVATE_REPO_NAME} --versions > ${TMPFILE_LIST_CHARTS}
    cat ${TMPFILE_LIST_CHARTS}
    echo ""
}

function build_helm_charts(){
    ################################
    # Loop process each chart repo #
    ################################
    CHART_COMMITID_VERSION_ENABLE="${CHART_COMMITID_VERSION_ENABLE:-false}"

    while read chart
    do
        DIR_CHART_REPO="$(dirname $chart)"
        CHART_NAME=$(cat ${DIR_CHART_REPO}/Chart.yaml | grep -i "^name" | awk -F':' '{print $2}' | tr -d ' ')
        if [[ ${CHART_COMMITID_VERSION_ENABLE} == "true" ]];then
            check_var 'CHART_COMMITID_VERSION'
            CHART_PACKAGE_VERSION=${CHART_COMMITID_VERSION}
        else
            CHART_PACKAGE_VERSION=$(cat ${DIR_CHART_REPO}/Chart.yaml | grep -i "^version" | awk -F':' '{print $2}' | tr -d ' ')
        fi

        echo ""
        echo "**"
        echo "** Chart: ${CHART_NAME} **"
        echo "**"
        echo "[+] Creating package for chart name: ${CHART_NAME}"
        echo "[+] Chart path: ${DIR_CHART_REPO}"
        echo "[+] Chart version: ${CHART_PACKAGE_VERSION}"

        echo ""
        echo "[?] Check helm chart version exists on Helm Repository [${HELM_PRIVATE_REPO_NAME}] or NOT ?"

        # Check if helm chart package exists on private helm repository
        grep "\b${HELM_PRIVATE_REPO_NAME}/${CHART_NAME}\b" ${TMPFILE_LIST_CHARTS} | tee ${TMPFILE_CHART_INFO_REPO}
        echo ""
        
        ## Use awk support -v arg | Old method
        #awk -v chartname="${HELM_PRIVATE_REPO_NAME}/${CHART_NAME}" '$1==chartname {print $i}' ${TMPFILE_LIST_CHARTS} | tee ${TMPFILE_CHART_INFO_REPO}

        if [[ $(cat ${TMPFILE_CHART_INFO_REPO} | wc -l) -ne 0 ]];then
            # Check if version in current helm package <dir>/Chart.yaml
            # already exists on private helm repository
            #CHART_INFO_VERSION_ON_REPO="$(head -n 1 ${TMPFILE_CHART_INFO_REPO} | awk '{print $2}')"
            if [[ $(cat ${TMPFILE_CHART_INFO_REPO} | grep -i "$CHART_PACKAGE_VERSION" | awk '{print $2}' | head -n1) == $CHART_PACKAGE_VERSION ]];then
                echo "Helm release version in file [Chart.yaml]: $CHART_PACKAGE_VERSION"
                echo "Helm release all versions on Private Repository:"
                cat $TMPFILE_CHART_INFO_REPO | awk '{print $1,$2}'
                echo ""
                echo "[-] RESULT: this version [$CHART_PACKAGE_VERSION] exist in repository"
                echo "[>] DECISION: bypass proceeding this version helm package anymore"
                continue

            else
                echo "Helm release version in file [Chart.yaml]: $CHART_PACKAGE_VERSION"
                echo "Helm release all versions on Private Repository:"
                cat $TMPFILE_CHART_INFO_REPO | awk '{print $1,$2}'
                echo ""
                echo "[-] RESULT: this version [$CHART_PACKAGE_VERSION] does not exist on repository"
                echo "[>] DECISION: continue to proceed this version helm package"

            fi
        else
            echo "[-] RESULT: this helm release does not exists on Private Repository"
            echo "[>] DECISION: continue to proceed this version helm package"
        fi

        # Ignore helm lint if in list
        if [[ $(grep "^$CHART_NAME" $LIST_IGNORE_LINT) ]];then
            echo ""
            echo "[-] Helm lint : $CHART_NAME"
            helm lint $DIR_CHART_REPO
            continue
        fi

        # Upload package to Helm repo only when ACTION="apply"
        if [[ ${ACTION} == "apply" ]];then
            echo ""
            echo "[+] ACTION: ${ACTION}"
            echo "[+] METHOD: ${METHOD}"
            echo "[-] Helm dep update : $CHART_NAME"
            helm dep update $DIR_CHART_REPO

            echo "[-] Helm push: ${CHART_NAME} => repo: ${HELM_PRIVATE_REPO_NAME}"

            # We need to package chart first then push with S3 plugin
            if [[ ${CHART_COMMITID_VERSION_ENABLE} == "true" ]];then
                HELM_COMMAND_VERSION="--version ${CHART_PACKAGE_VERSION}"
            fi

            helm package --dependency-update ${HELM_COMMAND_VERSION} --destination ${TMPDIR_PACKAGE_CHARTS} ${DIR_CHART_REPO}
            PACKAGE_PATH="${TMPDIR_PACKAGE_CHARTS}/${CHART_NAME}-${CHART_PACKAGE_VERSION}.tgz"

            if [[ "${METHOD}" == "s3" ]];then
                if [[ $(cat ${TMPFILE_CHART_INFO_REPO} | wc -l) -ne 0 ]];then
                    helm s3 push --force ${PACKAGE_PATH} ${HELM_PRIVATE_REPO_NAME}
                else
                    helm s3 push ${PACKAGE_PATH} ${HELM_PRIVATE_REPO_NAME}
                fi

            elif [[ "${METHOD}" == "http" ]];then
                check_plugin "helm plugin list" "cm-push"
                
                if [[ ${FLAG_FOUND_HTTP_CREDS} == "false" ]];then 
                    helm push ${DIR_CHART_REPO} ${PRIVATE_HELM_REPO_NAME}
                else
                    if [[ $(cat ${TMPFILE_CHART_INFO_REPO} | wc -l) -ne 0 ]];then
                        helm cm-push --force ${PACKAGE_PATH} ${HELM_PRIVATE_REPO_NAME} --username ${HTTP_USER} --password ${HTTP_PASSWORD}
                    else
                        helm cm-push ${PACKAGE_PATH} ${HELM_PRIVATE_REPO_NAME} --username ${HTTP_USER} --password ${HTTP_PASSWORD}
                    fi
                    
                fi

            elif [[ "${METHOD}" == "acr" ]];then
                check_var "ACR_NAME AZ_USER AZ_PASSWORD"
                pre_check_dependencies "az"

                if [[ $(helm push ${PACKAGE_PATH} ${ACR_ARTIFACT_NAME}) ]];then
                    if [[ $(cat ${TMPFILE_CHART_INFO_REPO} | wc -l) -ne 0 ]];then
                        az acr helm push --force -n ${ACR_NAME} -u ${AZ_USER} -p ${AZ_PASSWORD} ${PACKAGE_PATH}
                    else
                        az acr helm push -n ${ACR_NAME} -u ${AZ_USER} -p ${AZ_PASSWORD} ${PACKAGE_PATH}
                    fi
                fi
            fi

            echo ""
        else
            echo "[+] ACTION: ${ACTION}"
            echo "[-] Stop processing upload Helm Chart: ${CHART_NAME}"
        fi

    done < ${TMPFILE}
}


###### START
function main(){
    # Action based on ${ACTION} arg
    case ${ACTION} in
    "-v" | "--version")
        about
        ;;
    "-h" | "--help")
        help
        ;;
    *)
        # Checking supported tool & plugin on local machine
        pre_check_dependencies "helm"

        # Pre-checking
        pre_checking
        
        # Find chart list in source
        find_charts_list

        # Connect to helm private repo
        connect_helm_repo

        build_helm_charts
        ;;
    esac

    # Clean trash of service
    cleanup
}

main "${@}"

exit 0