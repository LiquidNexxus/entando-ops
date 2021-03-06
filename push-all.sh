#!/usr/bin/env bash
export VERSION=${1:-5.0.3-SNAPSHOT}
IMAGE_GROUPS_IN_SEQUENCE=$(cat IMAGE_GROUPS_IN_SEQUENCE)
for D in ${IMAGE_GROUPS_IN_SEQUENCE[@]}; do
    pushd $D
    echo "################## Pushing $D ###################"
    ./push-all.sh $VERSION || exit 1
    popd
done
