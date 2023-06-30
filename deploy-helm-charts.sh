#!/bin/bash
# Author: Dang Thanh Phat
# Description:
# + Tools need to install: helm, helm plugin push and helm s3
# helm plugin install https://github.com/chartmuseum/helm-push.git
# helm plugin install https://github.com/hypnoglow/helm-s3.git
#
# Cautions:
# - No allow to override current version of helm package

####################
# Global variables #
####################

# Action: plan will have people know what will happen
# Method: will help script to choose method to connect Helm Repo: web http or aws s3 bucket
ACTION="${1:-plan}"
METHOD="${2:-s3}" #valid value: http / s3

# Directory contains template charts
DIR_CHARTS="$PWD/charts"
PRIVATE_HELM_REPO_NAME="${PRIVATE_HELM_REPO_NAME:-helm-charts}"
S3_BUCKET_NAME="${S3_BUCKET_NAME:-none}" #set this variable if you use S3 storage for Helm Charts
LIST_IGNORE_LINT="${DIR_CHARTS}/list-ignore-lint.txt"
TMPFILE=$(mktemp /tmp/tempfile-XXXXXXXX)
TMPFILE_LIST_CHARTS=$(mktemp /tmp/tempfile-list-charts-XXXXXXXX)
TMPFILE_CHART_INFO_REPO=$(mktemp /tmp/tempfile-chart-info-repo-XXXXXXXX)
TMPDIR_PACKAGE_CHARTS=$(mktemp -d /tmp/tmpdir-helm-charts-package-XXXXXX)

# Functions
pre_checking()
{
    echo "[+] ACTION: ${ACTION}"
    echo "[+] METHOD: ${METHOD}"

    # Check if we miss credentials for AWS Helm S3 Plugin
    if [[ "${METHOD}" == "s3" ]];then
        FLAG_FOUND_AWS_CREDS="false"

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
        if [[ "$(env | grep -i "HOSTED_HELM_REPO_URL" | awk -F'=' '{print $2}')" == "" ]];then
            echo ""
            echo "[x] CHECKING: cannot find env variable [HOSTED_HELM_REPO_URL] when you want to use Helm authenticate HTTP Web App"
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

cleanup()
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
    if [[ "$(helm repo list | grep -i "${PRIVATE_HELM_REPO_NAME}")" ]];then
        # Remove current setting Helm Repo to add new
        helm repo remove ${PRIVATE_HELM_REPO_NAME}
    fi
}

# Setting shell
set -e

# Pre-checking
pre_checking

# Find list chart repository
echo ""
echo "[*] List Helm Chart Configurations are found :"
find ${DIR_CHARTS} -type f -name 'Chart.yaml' > ${TMPFILE}
cat ${TMPFILE}
echo ""


###################################
# Connect Private Helm Repository #
###################################
echo "[+] Connect Private Helm Repository: ${PRIVATE_HELM_REPO_NAME}"
if [[ $(helm repo list | grep -i ${PRIVATE_HELM_REPO_NAME} | awk '{print $1}') == ${PRIVATE_HELM_REPO_NAME} ]];then
    # Remove current setting Helm Repo to add new
    helm repo remove ${PRIVATE_HELM_REPO_NAME} 2> /dev/null
fi

if [[ "${METHOD}" == "s3" ]];then
    # Connect to Helm Chart Service with S3 Plugin - S3 Bucket AWS
    helm repo add ${PRIVATE_HELM_REPO_NAME} ${S3_BUCKET_NAME}

elif [[ "${METHOD}" == "http" ]];then
    # Connect to Helm Chart Service with Web HTTP Method
    helm repo add ${PRIVATE_HELM_REPO_NAME} ${HOSTED_HELM_REPO_URL}

fi

# Update list helm chart repositories
helm repo update

# List active Helm Repositories
echo ""
echo "[+] List active Helm Repositories"
helm repo list

# List Helm Charts in specific Hosted Private Helm Repository
echo ""
echo "[+] List Helm Charts in Private Helm Repository: ${PRIVATE_HELM_REPO_NAME}"
helm search repo ${PRIVATE_HELM_REPO_NAME} --versions > ${TMPFILE_LIST_CHARTS}
cat ${TMPFILE_LIST_CHARTS}
echo ""


################################
# Loop process each chart repo #
################################
while read chart
do
    DIR_CHART_REPO="$(dirname $chart)"
    CHART_NAME=$(cat ${DIR_CHART_REPO}/Chart.yaml | grep -i "^name" | awk -F':' '{print $2}' | tr -d ' ')
    CHART_PACKAGE_VERSION=$(cat ${DIR_CHART_REPO}/Chart.yaml | grep -i "^version" | awk -F':' '{print $2}' | tr -d ' ')

    echo ""
    echo "**"
    echo "** Chart: ${CHART_NAME} **"
    echo "**"
    echo "[+] Creating package for chart name: ${CHART_NAME}"
    echo "[+] Chart path: ${DIR_CHART_REPO}"
    echo "[+] Chart version: ${CHART_PACKAGE_VERSION}"

    echo ""
    echo "[?] Check helm chart version exists on Helm Repository [${PRIVATE_HELM_REPO_NAME}] or NOT ?"

    # Check if helm chart package exists on private helm repository
    grep "\b${PRIVATE_HELM_REPO_NAME}/${CHART_NAME}\b" ${TMPFILE_LIST_CHARTS} | tee ${TMPFILE_CHART_INFO_REPO}
    echo ""
    
    ## Use awk support -v arg | Old method
    #awk -v chartname="${PRIVATE_HELM_REPO_NAME}/${CHART_NAME}" '$1==chartname {print $i}' ${TMPFILE_LIST_CHARTS} | tee ${TMPFILE_CHART_INFO_REPO}

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

        echo "[-] Helm push: ${CHART_NAME} => repo: ${PRIVATE_HELM_REPO_NAME}"

        if [[ "${METHOD}" == "s3" ]];then
            # We need to package chart first then push with S3 plugin
            helm package --dependency-update --destination ${TMPDIR_PACKAGE_CHARTS} ${DIR_CHART_REPO}
            PACKAGE_PATH="${TMPDIR_PACKAGE_CHARTS}/${CHART_NAME}-${CHART_PACKAGE_VERSION}.tgz"
            if [[ $(cat ${TMPFILE_CHART_INFO_REPO} | wc -l) -ne 0 ]];then
              helm s3 push --force ${PACKAGE_PATH} ${PRIVATE_HELM_REPO_NAME}
            else
              helm s3 push ${PACKAGE_PATH} ${PRIVATE_HELM_REPO_NAME}
            fi

        elif [[ "${METHOD}" == "http" ]];then
            helm push ${DIR_CHART_REPO} ${PRIVATE_HELM_REPO_NAME}
        fi

        echo ""
    else
        echo "[+] ACTION: ${ACTION}"
        echo "[-] Stop processing upload Helm Chart: $CHART_NAME"
    fi

done < ${TMPFILE}

# Cleanup
cleanup

exit 0