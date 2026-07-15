#!/bin/bash

rm -rf layer && mkdir -p layer

docker image build -t python-requests-layer .

docker run --rm -v "$PWD"/layer:/layer python-requests-layer \
     zip -r /layer/layer.zip /opt
