#!/usr/bin/env bash
source $(dirname $BASH_SOURCE[0])/common.sh
echo "This script installs the Entando Sample project on the Wildfly 12 QuickStart image with a persistent embedded Derby database"
validate_environment
APPLICATION_NAME=${APPLICATION_NAME:-"entando-wildfly-quickstart"}
recreate_project ${APPLICATION_NAME}
ensure_image_stream "entando-wildfly12-quickstart-openshift"
ensure_image_stream "appbuilder"

oc process -f $ENTANDO_OPS_HOME/Openshift/templates/entando-wildfly12-quickstart.yml \
        -p APPLICATION_NAME="${APPLICATION_NAME}" \
        -p IMAGE_STREAM_NAMESPACE="${IMAGE_STREAM_NAMESPACE}" \
        -p ENTANDO_IMAGE_STREAM_TAG="${ENTANDO_IMAGE_STREAM_TAG}" \
        -p SOURCE_REPOSITORY_REF="${SOURCE_REPOSITORY_REF}" \
        -p SOURCE_REPOSITORY_URL="https://github.com/entando/entando-sample-minimal.git" \
        -p ENTANDO_ENGINE_HOSTNAME="${APPLICATION_NAME}-engine.${OPENSHIFT_DOMAIN_SUFFIX}" \
        -p ENTANDO_APP_BUILDER_HOSTNAME="${APPLICATION_NAME}-appbuilder.${OPENSHIFT_DOMAIN_SUFFIX}" \
        -p ENTANDO_ENGINE_WEB_CONTEXT="/entando-sample-minimal" \
    | oc replace --force -f -
