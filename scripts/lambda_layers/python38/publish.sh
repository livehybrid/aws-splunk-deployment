#!/bin/bash

LAYER_NAME=python-requests-lambda

REGIONS=eu-west-2

for region in $REGIONS; do
  aws lambda add-layer-version-permission --region $region --layer-name $LAYER_NAME \
    --statement-id sid1 --action lambda:GetLayerVersion --principal '*' \
    --version-number $(aws lambda publish-layer-version --region $region --layer-name $LAYER_NAME \
      --zip-file fileb://layer/layer.zip --cli-read-timeout 0 --cli-connect-timeout 0 \
      --description "Python Requests library for python3.8" --query Version --output text)
done
