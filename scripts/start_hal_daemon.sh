#!/bin/sh -ex
## Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
## SPDX-License-Identifier: MIT-0

docker run -p 8084:8084 -p 9000:9000 \
    --name halyard --rm \
    -v $(pwd)/.hal:/home/spinnaker/.hal \
    -v ~/.kube:/home/spinnaker/.kube \
    -v ~/.aws:/home/spinnaker/.aws \
    -it \
    gcr.io/spinnaker-marketplace/halyard:stable &
