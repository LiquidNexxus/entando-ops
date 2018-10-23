#!/usr/bin/env bash
#export ENTANDO_OPS_HOME=/home/lulu/Code/entando/entando-ops
#export ENTANDO_OPS_HOME="https://raw.githubusercontent.com/entando/entando-ops/EN-2085"
export ENTANDO_OPS_HOME=../../..
IMAGE_STREAM_NAMESPACE=entando
function create_projects(){
    echo "Creating projects for ${APPLICATION_NAME}"
    oc new-project $APPLICATION_NAME
    oc new-project $APPLICATION_NAME-build
    oc new-project $APPLICATION_NAME-stage
    oc new-project $APPLICATION_NAME-prod
    oc policy add-role-to-group system:image-puller system:serviceaccounts:$APPLICATION_NAME-build -n $IMAGE_STREAM_NAMESPACE
    oc policy add-role-to-group system:image-builder system:serviceaccounts:$APPLICATION_NAME-build -n $APPLICATION_NAME
    oc policy add-role-to-user edit system:serviceaccount:$APPLICATION_NAME-build:jenkins -n $APPLICATION_NAME-stage
    oc policy add-role-to-user edit system:serviceaccount:$APPLICATION_NAME-build:jenkins -n $APPLICATION_NAME-prod
    oc policy add-role-to-user edit system:serviceaccount:$APPLICATION_NAME-build:jenkins -n $APPLICATION_NAME
    oc policy add-role-to-user edit system:serviceaccount:$APPLICATION_NAME-build:jenkins -n $IMAGE_STREAM_NAMESPACE
    oc policy add-role-to-group system:image-puller system:serviceaccounts:$APPLICATION_NAME-stage -n $IMAGE_STREAM_NAMESPACE
    oc policy add-role-to-group system:image-puller system:serviceaccounts:$APPLICATION_NAME-stage -n $APPLICATION_NAME
    oc policy add-role-to-group system:image-puller system:serviceaccounts:$APPLICATION_NAME-prod -n $IMAGE_STREAM_NAMESPACE
    oc policy add-role-to-group system:image-puller system:serviceaccounts:$APPLICATION_NAME-prod -n $APPLICATION_NAME
    oc project $APPLICATION_NAME-build
    oc new-app --template=jenkins-persistent \
        -p JENKINS_IMAGE_STREAM_TAG=jenkins:2\
        -p NAMESPACE=openshift \
        -p MEMORY_LIMIT=2048Mi \
        -p ENABLE_OAUTH=true
}
function install_imagick_image(){
  echo "Installing required images"
  oc create -f $ENTANDO_OPS_HOME/Openshift/images-streams/entando-postgresql-jenkins-slave-openshift39.json 2> /dev/null
  oc create -f $ENTANDO_OPS_HOME/Openshift/images-streams/entando-maven-jenkins-slave-openshift39.json 2> /dev/null
  oc create -f $ENTANDO_OPS_HOME/Openshift/images-streams/entando-postgresql95-openshift.json 2> /dev/null
  oc create -f $ENTANDO_OPS_HOME/Openshift/image-streams/appbuilder.json 2> /dev/null
  echo "Installing the Entando Imagick Image stream."
  if [ -f $(dirname $0)/build.conf ]; then
    source $(dirname $0)/build.conf
  else
    echo "Build config file not found. Expected file: $(dirname $0)/build.conf.sample)"
    exit -1
  fi
  if [ -n "${REDHAT_REGISTRY_USERNAME}" ]; then
    oc delete secret base-image-registry-secret -n ${APPLICATION_NAME}-build 2>/dev/null
    oc create secret docker-registry base-image-registry-secret \
        --docker-server=registry.connect.redhat.com \
        --docker-username=${REDHAT_REGISTRY_USERNAME} \
        --docker-password=${REDHAT_REGISTRY_PASSWORD} \
        --docker-email=${REDHAT_REGISTRY_USERNAME} \
        -n ${APPLICATION_NAME}-build
    oc delete secret base-image-registry-secret -n $IMAGE_STREAM_NAMESPACE 2>/dev/null
    oc create secret docker-registry base-image-registry-secret \
        --docker-server=registry.connect.redhat.com \
        --docker-username=${REDHAT_REGISTRY_USERNAME} \
        --docker-password=${REDHAT_REGISTRY_PASSWORD} \
        --docker-email=${REDHAT_REGISTRY_USERNAME} \
        -n $IMAGE_STREAM_NAMESPACE
#    oc label secret base-image-registry-secret application=entando-central
  else
    echo "Please set the REDHAT_REGISTRY_USERNAME and REDHAT_REGISTRY_PASSWORD variables so that the image can be retrieved from the secure Red Hat registry"
    exit -1
  fi
  oc replace --force -f $ENTANDO_OPS_HOME/Openshift/image-streams/entando-eap71-openshift.json -n $IMAGE_STREAM_NAMESPACE
}

function prepare_source_secret(){
    echo "Creating the SCM source secret."
    if [ -n "${SCM_USERNAME}" ] && [ -n "${SCM_PASSWORD}" ]; then
      cat <<EOF | oc replace --force --grace-period 60 -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${APPLICATION_NAME}-source-secret
  labels:
    application: "${APPLICATION_NAME}"
    credential.sync.jenkins.openshift.io: "true"
stringData:
  username: ${SCM_USERNAME}
  password: ${SCM_PASSWORD}
EOF
  fi
}
function prepare_pam_secret(){
    echo "Creating the RedHat PAM secret."
    if [ -n "${KIE_SERVER_USERNAME}" ] && [ -n "${KIE_SERVER_PASSWORD}" ] && [ -n "${KIE_SERVER_BASE_URL}" ] ; then
       cat <<EOF | oc replace --force --grace-period 60 -f -
apiVersion: v1
kind: Secret
metadata:
  name: entando-pam-secret
  labels:
    application: "${APPLICATION_NAME}"
stringData:
  username: ${KIE_SERVER_USERNAME}
  password: ${KIE_SERVER_PASSWORD}
  url: ${KIE_SERVER_BASE_URL}
EOF
    else
       cat <<EOF | oc replace --force --grace-period 60 -f -
apiVersion: v1
kind: Secret
metadata:
  name: entando-pam-secret
  labels:
    application: "${APPLICATION_NAME}"
stringData:
  username: dummy
  password: dummy
  url: dummy
EOF
    fi
}


function populate_build_project(){
  echo "Populating the build project." 2> /dev/null
  if [ -f $(dirname $0)/build.conf ]; then
    source $(dirname $0)/build.conf
  else
    echo "Build config file not found. Expected file: $(dirname $0)/build.conf.sample)"
    exit -1
  fi
  oc project $APPLICATION_NAME-build
  prepare_source_secret
  install_imagick_image
  prepare_db_secret stage
  prepare_db_secret prod
  oc process -f $ENTANDO_OPS_HOME/Openshift/templates/reference-pipeline/entando-build.yml \
            -p APPLICATION_NAME="${APPLICATION_NAME}" \
            -p ENTANDO_IMAGE_STREAM_NAMESPACE="entando" \
            -p ENTANDO_IMAGE_TAG="5.0.1-SNAPSHOT" \
            -p SOURCE_SECRET="${APPLICATION_NAME}-source-secret" \
            -p SOURCE_REPOSITORY_URL=${SOURCE_REPOSITORY_URL:-https://github.com/ampie/entando-sample.git} \
            -p SOURCE_REPOSITORY_REF=${SOURCE_REPOSITORY_REF:-master} \
            -p ENTANDO_DB_SECRET_STAGE="${APPLICATION_NAME}-db-secret-stage" \
            -p ENTANDO_DB_SECRET_PROD="${APPLICATION_NAME}-db-secret-prod" \
          |  oc replace --force --grace-period 60  -f -
}
function populate_image_project(){
  echo "Populating the image project." 2> /dev/null
  oc project $APPLICATION_NAME
  oc process -f $ENTANDO_OPS_HOME/Openshift/templates/reference-pipeline/entando-output-image-streams.yml \
            -p APPLICATION_NAME="${APPLICATION_NAME}" \
            | oc replace --force --grace-period 60  -f -
}
function prepare_db_secret(){
  echo "Creating the Entando DB Secret for the $1 environment."
  if [ -f $(dirname $0)/$1.conf ]; then
    source $(dirname $0)/$1.conf
  else
    echo "Config file for $1 not found. Expected file: $(dirname $0)/$1.conf)"
    exit -1
  fi

  if [ "${DEPLOY_POSTGRESQL}" = "true" ]; then
  # specifiy the service
      DB_SERVICE_HOST="${APPLICATION_NAME}-postgresql.${APPLICATION_NAME}-$1.svc"
      DB_SERVICE_PORT="5432"
  # generate passwords and save to passwords file
    if [ -f $1-passwords.txt ]; then
      source $1-passwords.txt
    else
      DB_PASSWORD=$(openssl rand -base64 24)
      DB_ADMIN_PASSWORD=$(openssl rand -base64 24)
      cat <<EOF > $1-passwords.txt
DB_PASSWORD=${DB_PASSWORD}
DB_ADMIN_PASSWORD=${DB_ADMIN_PASSWORD}
EOF
    fi
  fi
  oc process -f $ENTANDO_OPS_HOME/Openshift/templates/reference-pipeline/entando-db-secret.yml \
            -p APPLICATION_NAME="${APPLICATION_NAME}" \
            -p SECRET_NAME="${APPLICATION_NAME}-db-secret-$1" \
            -p USERNAME="${DB_USERNAME}" \
            -p PASSWORD="${DB_PASSWORD}" \
            -p DB_HOSTNAME="${DB_SERVICE_HOST}" \
            -p DB_PORT="${DB_SERVICE_PORT}" \
            -p ADMIN_PASSWORD="${DB_ADMIN_PASSWORD}" \
            -p ADMIN_USERNAME="postgres" \
          |  oc replace --force --grace-period 60  -f -

  oc process -f $ENTANDO_OPS_HOME/Openshift/templates/reference-pipeline/entando-db-file-secret.yml \
            -p APPLICATION_NAME="${APPLICATION_NAME}" \
            -p SECRET_NAME="${APPLICATION_NAME}-db-file-secret-$1" \
            -p USERNAME="${DB_USERNAME}" \
            -p PASSWORD="${DB_PASSWORD}" \
            -p DB_HOSTNAME="${DB_SERVICE_HOST}" \
            -p DB_PORT="${DB_SERVICE_PORT}" \
            -p ADMIN_PASSWORD="${DB_ADMIN_PASSWORD}" \
            -p ADMIN_USERNAME="postgres" \
          |  oc replace --force --grace-period 60  -f -
}


function populate_deployment_project(){
  echo "Populating the $1 project." 2> /dev/null
  source $(dirname $0)/clear-vars.sh
  if [ -f $(dirname $0)/$1.conf ]; then
    source $(dirname $0)/$1.conf
  else
    echo "Config file for $1 not found. Expected file: $(dirname $0)/$1.conf)"
    exit -1
  fi
  oc project $APPLICATION_NAME-$1
  prepare_db_secret $1
  prepare_pam_secret $1
  oc process -f $ENTANDO_OPS_HOME/Openshift/templates/reference-pipeline/sample-jgroups-secret.yml \
            -p APPLICATION_NAME="${APPLICATION_NAME}" \
            -p SECRET_NAME="entando-app-secret" \
            | oc replace --force --grace-period 60  -f -
  if [ -n "$OIDC_AUTH_LOCATION" ] && [ -n "$OIDC_TOKEN_LOCATION" ] && [ -n "$OIDC_CLIENT_ID" ] && [ -n "$OIDC_REDIRECT_BASE_URL" ]; then
    oc process -f $ENTANDO_OPS_HOME/Openshift/templates/reference-pipeline/entando-eap71-deployment.yml \
            -p APPLICATION_NAME="${APPLICATION_NAME}" \
            -p ENVIRONMENT_TAG=$1 \
            -p ENTANDO_DB_SECRET="${APPLICATION_NAME}-db-secret-$1" \
            -p IMAGE_STREAM_NAMESPACE="${APPLICATION_NAME}" \
            -p APP_BUILDER_DOMAIN="${APP_BUILDER_DOMAIN}" \
            -p ENGINE_API_DOMAIN="${ENGINE_API_DOMAIN}" \
            -p ENTANDO_OIDC_ACTIVE="true" \
            -p ENTANDO_OIDC_AUTH_LOCATION="$OIDC_AUTH_LOCATION" \
            -p ENTANDO_OIDC_TOKEN_LOCATION="$OIDC_TOKEN_LOCATION" \
            -p ENTANDO_OIDC_CLIENT_ID="$OIDC_CLIENT_ID" \
            -p ENTANDO_OIDC_REDIRECT_BASE_URL="$OIDC_REDIRECT_BASE_URL" \
            | oc replace --force --grace-period 60  -f -
  else
    oc process -f $ENTANDO_OPS_HOME/Openshift/templates/reference-pipeline/entando-eap71-deployment.yml \
            -p APPLICATION_NAME="${APPLICATION_NAME}" \
            -p ENVIRONMENT_TAG=$1 \
            -p ENTANDO_DB_SECRET="${APPLICATION_NAME}-db-secret-$1" \
            -p IMAGE_STREAM_NAMESPACE="${APPLICATION_NAME}" \
            -p APP_BUILDER_DOMAIN="${APP_BUILDER_DOMAIN}" \
            -p ENGINE_API_DOMAIN="${ENGINE_API_DOMAIN}" \
            -p ENTANDO_OIDC_ACTIVE="false" \
            | oc replace --force --grace-period 60  -f -
  fi
  if [ "${DEPLOY_POSTGRESQL}" = "true" ]; then
      oc process -f $ENTANDO_OPS_HOME/Openshift/templates/reference-pipeline/entando-postgresql95-deployment.yml \
            -p APPLICATION_NAME="${APPLICATION_NAME}" \
            -p ENTANDO_IMAGE_STREAM_NAMESPACE="entando" \
            -p ENTANDO_IMAGE_TAG="5.0.1-SNAPSHOT" \
            -p ENTANDO_DB_SECRET="${APPLICATION_NAME}-db-secret-$1" \
            | oc replace --force --grace-period 60  -f -
  fi
}

function populate_projects(){
    populate_build_project
    populate_image_project
    populate_deployment_project stage
    populate_deployment_project prod
    COUNTER=0
    oc get pods -n ${APPLICATION_NAME}-build --selector name=jenkins
    until oc get pods -n ${APPLICATION_NAME}-build --selector name=jenkins | grep  '1/1\s*Running' ;
    do
       if [ $COUNTER -gt 100 ]; then
         echo "Timeout waiting for Jenkins pod"
         exit -1
       fi
        echo "waiting for Jenkins:"
       sleep 10
    done   
    until oc get pods -n ${APPLICATION_NAME}-stage --selector deploymentConfig=${APPLICATION_NAME}-postgresql | grep '1/1\s*Running' ; 
    do
       if [ $COUNTER -gt 100 ]; then
       	 echo "Timeout	waiting	for PostgreSQL pod"
       	 exit -1
       fi
       echo "waiting for PostgreSQL:"
       sleep 10 
    done
    echo "running oc adm pod-network join-projects --to=${APPLICATION_NAME}-stage ${APPLICATION_NAME}-build ${APPLICATION_NAME}-prod"
    oc adm pod-network join-projects --to=${APPLICATION_NAME}-stage ${APPLICATION_NAME}-build ${APPLICATION_NAME}-prod
}
function clear_projects(){
    echo "Deleting all elements with the label application=$APPLICATION_NAME"
    oc delete all -l application=$APPLICATION_NAME -n $APPLICATION_NAME
    oc delete all -l application=$APPLICATION_NAME -n $APPLICATION_NAME-build
    oc delete all -l application=$APPLICATION_NAME -n $APPLICATION_NAME-stage
    oc delete all -l application=$APPLICATION_NAME -n  $APPLICATION_NAME-prod
    oc delete secret -l application=$APPLICATION_NAME -n $APPLICATION_NAME
    oc delete secret -l application=$APPLICATION_NAME -n $APPLICATION_NAME-build
    oc delete secret -l application=$APPLICATION_NAME -n $APPLICATION_NAME-stage
    oc delete secret -l application=$APPLICATION_NAME -n  $APPLICATION_NAME-prod
    oc delete pvc -l application=$APPLICATION_NAME -n $APPLICATION_NAME-build
    oc delete pvc -l application=$APPLICATION_NAME -n $APPLICATION_NAME-stage
    oc delete pvc -l application=$APPLICATION_NAME -n  $APPLICATION_NAME-prod

}


function delete_projects(){
    echo "Deleting projects for ${APPLICATION_NAME}"
    oc delete project $APPLICATION_NAME
    oc delete project $APPLICATION_NAME-build
    oc delete project $APPLICATION_NAME-stage
    oc delete  project $APPLICATION_NAME-prod
}

if [[ $1 =~ -.* ]]; then
  echo "The first argument should be one of create/delete"
  exit -1
else
  COMMAND=$1
  shift
fi
for i in "$@"
do
case $i in
    -an=*|--application-name=*)
      APPLICATION_NAME="${i#*=}"
      shift # past argument=value
    ;;
    -isn=*|--image-stream-namespace=*)
      IMAGE_STREAM_NAMESPACE="${i#*=}"
      shift # past argument=value
    ;;
    *)
    echo "Unknown option: $i"
    exit -1
esac
done
IMAGE_STREAM_NAMESPACE=${IMAGE_STREAM_NAMESPACE:-openshift}
case $COMMAND in
  create)
    create_projects
  ;;
  delete)
    delete_projects
  ;;
  populate)
    populate_projects
  ;;
  clear)
    clear_projects
  ;;
  *)
    echo "Unknown command: $COMMAND"
    exit -1
esac